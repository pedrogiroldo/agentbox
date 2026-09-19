#!/usr/bin/env bash
#
# agentbox-cgroup — keeps the box reachable when the agents saturate it.
#
# A box with a dozen agents open does not die of memory. It dies of
# scheduling: status lines and hooks fork hundreds of times a second, the
# herdr server, sshd and Collie wait in the same run queue as all of that, and
# an SSH login -- fifteen forks from sshd to a prompt -- never gets its turn
# before the client gives up. The operator cannot see what is happening and
# cannot get in to act.
#
# So the box splits itself in two, using the cgroup v2 tree it already has
# (a side effect of the `privileged: true` its Docker daemon needs):
#
#   control/  cpu.weight 1000   memory.min <reserve>
#             tini, the entrypoint, sshd, the herdr server, collie, tailscaled:
#             what you need in order to SEE and ACT
#   work/     cpu.weight 100    memory.high <total - reserve>   pids.max
#             everything born inside a herdr pane: agents, hooks, builds
#   docker/   defaults
#             dockerd, containerd and the cgroups dockerd makes for containers
#
# Weights only matter under saturation: an idle control plane yields
# everything. When the box is full, the agents are what slows down -- and the
# operator is the one who asked for that order.
#
#   setup            create the tree and move the caller into control/. The
#                    entrypoint runs it first, before any service, so every
#                    service inherits control/. Never fatal in `auto`.
#   enter <group>    move a pid (default: the caller's parent, since this runs
#     [pid]          as a child of the shell that wants to move) into a group
#   protect          set the OOM scores of the control-plane services
#   status           which protections are actually in effect, not which
#                    were asked for
#
# AGENTBOX_ISOLATION=auto    cgroups when the tree allows, nice otherwise (default)
#                  =cgroup  cgroups, or a fatal error
#                  =nice    priorities only
#                  =off     nothing beyond the OOM ordering the entrypoint sets
# AGENTBOX_CONTROL_RESERVE   memory kept for the control plane. Default: 10% of
#                            the box's memory, clamped to 384M..1G. 0 skips the
#                            memory floor and ceiling and keeps the CPU weights.
#
# The one rule that shapes the code: cgroup v2 lets a cgroup hand controllers
# to its children only while it holds no processes itself. The container's
# root is such a cgroup (on the host it is a child of docker's), so everything
# in it has to leave before subtree_control is written -- and everything is
# just tini and the entrypoint, because this runs before anything else starts.
#
# What it degrades to when the tree refuses: `nice -10` on the control plane
# and nothing else. Weaker (no memory protection), risk-free, and the same
# thing AGENTBOX_ISOLATION=nice asks for on purpose.
set -uo pipefail

# Both overridable so the test suite can drive the flow against a directory
# of plain files instead of a kernel.
ROOT="${AGENTBOX_CGROUP_ROOT:-/sys/fs/cgroup}"
MODE="${AGENTBOX_ISOLATION:-auto}"
STATE_FILE="${AGENTBOX_ISOLATION_STATE:-/run/agentbox-isolation}"
CONTROL_WEIGHT=1000
WORK_WEIGHT=100
WORK_PIDS_MAX="${AGENTBOX_WORK_PIDS_MAX:-4096}"
NICE_CONTROL=-10

c_info=$'\033[36m'; c_warn=$'\033[33m'; c_off=$'\033[0m'
log()  { printf '%s[agentbox]%s %s\n' "$c_info" "$c_off" "$*"; }
warn() { printf '%s[agentbox]%s %s\n' "$c_warn" "$c_off" "$*" >&2; }

# Fatal only when the operator asked for cgroups explicitly.
give_up() {
    if [ "$MODE" = "cgroup" ]; then
        printf '%s[agentbox] fatal:%s %s\n' $'\033[31m' "$c_off" "$1" >&2
        exit 1
    fi
    warn "$1"
    return 1
}

# ---------------------------------------------------------------------------
# Sizes
# ---------------------------------------------------------------------------

# Bytes from a human figure: 512M, 1G, 786432000. Empty on garbage.
to_bytes() {
    local v="${1^^}" n unit
    n="${v%[KMGT]}"; unit="${v#"$n"}"
    [[ "$n" =~ ^[0-9]+$ ]] || return 1
    case "$unit" in
        "")  echo "$n" ;;
        K)   echo $((n * 1024)) ;;
        M)   echo $((n * 1024 * 1024)) ;;
        G)   echo $((n * 1024 * 1024 * 1024)) ;;
        T)   echo $((n * 1024 * 1024 * 1024 * 1024)) ;;
        *)   return 1 ;;
    esac
}

human() {
    local b="$1"
    if   [ "$b" -ge $((1024 * 1024 * 1024)) ]; then printf '%d.%dG' $((b / 1073741824)) $(( (b % 1073741824) * 10 / 1073741824 ))
    elif [ "$b" -ge $((1024 * 1024)) ]; then printf '%dM' $((b / 1048576))
    else printf '%dK' $((b / 1024)); fi
}

# The box's memory: the container's own limit when the host set one, the
# machine's total otherwise.
box_memory() {
    local max
    max="$(cat "$ROOT/memory.max" 2>/dev/null || echo max)"
    if [ "$max" != "max" ] && [[ "$max" =~ ^[0-9]+$ ]]; then
        echo "$max"
    else
        awk '/^MemTotal:/ {print $2 * 1024}' /proc/meminfo
    fi
}

# The reserve in bytes, or 0 when the operator turned the memory limits off.
reserve_bytes() {
    local total setting
    setting="${AGENTBOX_CONTROL_RESERVE:-}"
    if [ -n "$setting" ]; then
        if [ "$setting" = "0" ]; then echo 0; return 0; fi
        to_bytes "$setting" && return 0
        warn "AGENTBOX_CONTROL_RESERVE='$setting' is not a size (try 512M) — using the default"
    fi
    total="$(box_memory)"
    local r=$((total / 10))
    local lo=$((384 * 1024 * 1024)) hi=$((1024 * 1024 * 1024))
    [ "$r" -lt "$lo" ] && r=$lo
    [ "$r" -gt "$hi" ] && r=$hi
    # A box smaller than twice the floor cannot afford the floor.
    [ "$r" -gt $((total / 2)) ] && r=$((total / 4))
    echo "$r"
}

# ---------------------------------------------------------------------------
# The tree
# ---------------------------------------------------------------------------

record() { printf '%s\n' "$1" > "$STATE_FILE" 2>/dev/null || true; }

usable_tree() {
    [ -d "$ROOT" ] && [ -w "$ROOT" ] && [ -f "$ROOT/cgroup.controllers" ] \
        && [ -w "$ROOT/cgroup.subtree_control" ]
}

# Which of the controllers we want does the tree offer.
offered() {
    local want="$1"
    tr ' ' '\n' < "$ROOT/cgroup.controllers" 2>/dev/null | grep -qx "$want"
}

# Move every pid in the root into control/. At this point that is tini and
# this script's own ancestry -- the entrypoint runs setup before any service.
drain_root() {
    local pids pid rc=0
    # Snapshot first: the file shrinks as pids are moved out of it.
    mapfile -t pids < "$ROOT/cgroup.procs"
    for pid in "${pids[@]}"; do
        [ -n "$pid" ] || continue
        echo "$pid" > "$ROOT/control/cgroup.procs" 2>/dev/null || rc=1
    done
    return $rc
}

# ---------------------------------------------------------------------------
# protect: the OOM ordering. Independent of cgroups, applied in every mode,
# idempotent, and called by the entrypoint after the control-plane services
# have started (twice: the herdr server comes up before sshd, the tailnet and
# Collie in the background chain after it).
#
# Killing the herdr server kills every pane at once; killing one agent loses
# one conversation. This says which the kernel should prefer. sshd sets its
# own -1000; nothing in work/ is touched.
# ---------------------------------------------------------------------------
protect() {
    local pid
    for pid in $(pgrep -f 'herdr server' 2>/dev/null); do
        echo -1000 > "/proc/$pid/oom_score_adj" 2>/dev/null || true
    done
    for pid in $(pgrep -f 'collie _exec-bridge' 2>/dev/null) $(pgrep -x tailscaled 2>/dev/null); do
        echo -900 > "/proc/$pid/oom_score_adj" 2>/dev/null || true
    done
    return 0
}

undo_tree() {
    local g
    for g in control work docker; do
        [ -d "$ROOT/$g" ] || continue
        # Give the processes back to the root before removing the group.
        while read -r pid; do
            [ -n "$pid" ] && echo "$pid" > "$ROOT/cgroup.procs" 2>/dev/null
        done < "$ROOT/$g/cgroup.procs" 2>/dev/null
        rmdir "$ROOT/$g" 2>/dev/null || true
    done
}

# The one-shot nice fallback: raise the caller's priority so every service
# started afterwards inherits it. Panes and SSH shells put themselves back to
# 0 in the pane wrapper and env.sh, which is the mirror image of `enter work`.
#
# Lowering a nice value needs CAP_SYS_NICE, which Docker's default set does
# not include: an unprivileged container cannot do even this. Say so rather
# than report a protection that is not there.
apply_nice() {
    renice -n "$NICE_CONTROL" -p 1 >/dev/null 2>&1 || true
    renice -n "$NICE_CONTROL" -p $$ >/dev/null 2>&1 || true
    renice -n "$NICE_CONTROL" -p "$PPID" >/dev/null 2>&1 || true
    local got
    got="$(ps -o ni= -p "$PPID" 2>/dev/null | tr -d ' ')"
    [ "${got:-0}" -le "$NICE_CONTROL" ] 2>/dev/null
}

setup_cgroups() {
    local reason
    usable_tree || { reason="$ROOT is not a writable cgroup v2 tree"; give_up "$reason"; record "nice:$reason"; return 1; }

    local enable="" c
    for c in cpu memory pids; do
        offered "$c" && enable="$enable +$c"
    done
    if ! offered cpu; then
        reason="the cgroup tree offers no cpu controller (has: $(cat "$ROOT/cgroup.controllers"))"
        give_up "$reason"; record "nice:$reason"; return 1
    fi

    if ! mkdir -p "$ROOT/control" "$ROOT/work" "$ROOT/docker" 2>/dev/null; then
        reason="could not create groups under $ROOT"
        give_up "$reason"; record "nice:$reason"; return 1
    fi

    if ! drain_root; then
        reason="could not move the root's processes into $ROOT/control/cgroup.procs"
        undo_tree; give_up "$reason"; record "nice:$reason"; return 1
    fi

    # shellcheck disable=SC2086
    if ! echo $enable > "$ROOT/cgroup.subtree_control" 2>/dev/null; then
        reason="$ROOT/cgroup.subtree_control refused '$enable'"
        undo_tree; give_up "$reason"; record "nice:$reason"; return 1
    fi

    echo "$CONTROL_WEIGHT" > "$ROOT/control/cpu.weight" 2>/dev/null || warn "could not set control/cpu.weight"
    echo "$WORK_WEIGHT"    > "$ROOT/work/cpu.weight"    2>/dev/null || warn "could not set work/cpu.weight"

    local reserve total ceiling
    reserve="$(reserve_bytes)"
    if [ "$reserve" -gt 0 ] && offered memory; then
        total="$(box_memory)"
        ceiling=$((total - reserve))
        echo "$reserve" > "$ROOT/control/memory.min" 2>/dev/null || warn "could not set control/memory.min"
        echo "$ceiling" > "$ROOT/work/memory.high"   2>/dev/null || warn "could not set work/memory.high"
    fi
    if offered pids; then
        echo "$WORK_PIDS_MAX" > "$ROOT/work/pids.max" 2>/dev/null || warn "could not set work/pids.max"
    fi

    record "cgroup"
    return 0
}

setup() {
    case "$MODE" in
        off)
            log "isolation is off (AGENTBOX_ISOLATION=off)"
            record "off"
            exit 0 ;;
        nice)
            if apply_nice; then
                log "isolation: process priorities only (AGENTBOX_ISOLATION=nice)"
                record "nice:asked for"
            else
                warn "AGENTBOX_ISOLATION=nice, but this container may not raise priorities (no CAP_SYS_NICE) — only the OOM ordering applies"
                record "none:asked for nice, but the container has no CAP_SYS_NICE"
            fi
            exit 0 ;;
        auto|cgroup) ;;
        *)
            warn "AGENTBOX_ISOLATION=$MODE is not one of auto|cgroup|nice|off — treating it as auto"
            MODE=auto ;;
    esac

    if setup_cgroups; then
        local r; r="$(reserve_bytes)"
        if [ "$r" -gt 0 ] && offered memory; then
            log "isolation: cgroups — control plane weighted ${CONTROL_WEIGHT}:${WORK_WEIGHT}, $(human "$r") reserved for it"
        else
            log "isolation: cgroups — control plane weighted ${CONTROL_WEIGHT}:${WORK_WEIGHT}, no memory limits"
        fi
        exit 0
    fi

    # give_up already exited under =cgroup; this is the auto fallback. The
    # reason setup_cgroups recorded is kept; only the mode word changes.
    local why; why="$(cat "$STATE_FILE" 2>/dev/null)"; why="${why#*:}"
    if apply_nice; then
        warn "falling back to process priorities (AGENTBOX_ISOLATION=auto)"
        record "nice:$why"
    else
        warn "falling back to nothing: cgroups refused and the container may not raise priorities either (no CAP_SYS_NICE) — only the OOM ordering applies"
        record "none:$why; and no CAP_SYS_NICE for priorities"
    fi
    exit 0
}

# ---------------------------------------------------------------------------
# enter
# ---------------------------------------------------------------------------

mode_in_effect() {
    local s
    s="$(cat "$STATE_FILE" 2>/dev/null || echo unset)"
    echo "${s%%:*}"
}

enter() {
    local group="${1:-}" pid="${2:-$PPID}"
    case "$group" in
        control|work|docker) ;;
        *) echo "usage: agentbox-cgroup enter {control|work|docker} [pid]" >&2; return 2 ;;
    esac
    [[ "$pid" =~ ^[0-9]+$ ]] || { echo "not a pid: $pid" >&2; return 2; }

    case "$(mode_in_effect)" in
        cgroup)
            [ -d "$ROOT/$group" ] || return 1
            echo "$pid" > "$ROOT/$group/cgroup.procs" 2>/dev/null ;;
        nice)
            # The nice-mode mirror of the same move: control raises, work and
            # docker sit at the default.
            if [ "$group" = control ]; then
                renice -n "$NICE_CONTROL" -p "$pid" >/dev/null 2>&1
            else
                renice -n 0 -p "$pid" >/dev/null 2>&1
            fi ;;
        *)  return 0 ;;
    esac
}

# ---------------------------------------------------------------------------
# status
# ---------------------------------------------------------------------------

status() {
    local s mode reason
    s="$(cat "$STATE_FILE" 2>/dev/null || echo "unset")"
    mode="${s%%:*}"; reason="${s#*:}"; [ "$reason" = "$s" ] && reason=""

    case "$mode" in
        cgroup)
            echo "isolation: cgroups (AGENTBOX_ISOLATION=${AGENTBOX_ISOLATION:-auto})"
            if [ -f "$ROOT/control/cpu.weight" ]; then
                echo "  cpu:    control $(cat "$ROOT/control/cpu.weight")  work $(cat "$ROOT/work/cpu.weight")  docker $(cat "$ROOT/docker/cpu.weight" 2>/dev/null || echo '?')"
            else
                echo "  cpu:    the groups are gone — the tree was changed after boot"
            fi
            local mn mh
            mn="$(cat "$ROOT/control/memory.min" 2>/dev/null || echo 0)"
            mh="$(cat "$ROOT/work/memory.high" 2>/dev/null || echo max)"
            if [ "$mn" != "0" ] && [ "$mh" != "max" ]; then
                echo "  memory: control keeps $(human "$mn"), work is throttled above $(human "$mh")"
            else
                echo "  memory: no floor or ceiling (AGENTBOX_CONTROL_RESERVE=0, or no memory controller)"
            fi
            echo "  pids:   work is capped at $(cat "$ROOT/work/pids.max" 2>/dev/null || echo '?')"
            ;;
        nice)
            echo "isolation: process priorities only (${AGENTBOX_ISOLATION:-auto})"
            [ -n "$reason" ] && [ "$reason" != "asked for" ] && echo "  cgroups refused: $reason"
            echo "  cpu:    control plane at nice $NICE_CONTROL, workload at 0"
            echo "  memory: not protected — no floor, no ceiling"
            ;;
        none)
            echo "isolation: none possible in this container (${AGENTBOX_ISOLATION:-auto})"
            echo "  cgroups refused: $reason"
            echo "  cpu:    not protected (an unprivileged container may neither write its cgroup tree nor raise priorities)"
            echo "  memory: not protected"
            ;;
        off)
            echo "isolation: off (AGENTBOX_ISOLATION=off)"
            echo "  cpu:    not protected"
            echo "  memory: not protected"
            ;;
        *)
            echo "isolation: not set up — the entrypoint has not run agentbox-cgroup setup"
            return 1 ;;
    esac

    # The OOM ordering is the entrypoint's job and applies in every mode.
    local hp; hp="$(pgrep -f 'herdr server' 2>/dev/null | head -1)"
    if [ -n "$hp" ]; then
        echo "  oom:    herdr server $(cat "/proc/$hp/oom_score_adj" 2>/dev/null || echo '?'), sshd $(cat "/proc/$(pgrep -x sshd | head -1)/oom_score_adj" 2>/dev/null || echo '?') (lower is killed last)"
    else
        echo "  oom:    sshd $(cat "/proc/$(pgrep -x sshd | head -1)/oom_score_adj" 2>/dev/null || echo '?') (no herdr server running)"
    fi
    return 0
}

case "${1:-status}" in
    setup)   setup ;;
    enter)   shift; enter "$@" ;;
    protect) protect ;;
    status)  status ;;
    *) echo "usage: agentbox-cgroup {setup|enter <group> [pid]|protect|status}" >&2; exit 2 ;;
esac
