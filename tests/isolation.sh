#!/usr/bin/env bash
# Does the box stay reachable when the agents saturate it?
#
# The failure this guards against: a dozen agents fork a few hundred times a
# second, sshd and the herdr server wait in the same run queue, and an SSH
# login never reaches a prompt. The box splits itself into a control group and
# a workload group so that cannot happen (docs/small-vps.md). So:
#
#   1. privileged, the tree comes up: sshd and the herdr server are control,
#      the workload group has its weight and limits, the OOM ordering is set,
#      and `docker exec` -- the rescue hatch -- still works once the root has
#      controllers enabled (the one thing the design could not prove on paper)
#   2. a pane's shell is the user's shell and lands in the workload group; so
#      does an SSH shell, once the login is done
#   3. with the workload group saturated, a real SSH login and a herdr status
#      call still complete within a bound
#   4. unprivileged, the box falls back to priorities, says so, and boots
#   5. AGENTBOX_ISOLATION=off and =nice do what they say
#
#     make build && tests/isolation.sh agentbox:local
set -euo pipefail

IMAGE="${1:-agentbox:local}"
NAME="agentbox-isotest-$$"
HOME_VOL="$NAME-home"
STATE_VOL="$NAME-state"
TMP="$(mktemp -d)"
SSH_PORT=$((20000 + RANDOM % 10000))
LOGIN_BOUND=20      # seconds for an SSH login under saturation
STATUS_BOUND=15     # seconds for a herdr status call under saturation

pass() { printf '  \033[32mok\033[0m   %s\n' "$*"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; failures=$((failures + 1)); }
skip() { printf '  \033[33mskip\033[0m %s\n' "$*"; }
step() { printf '\n\033[36m==>\033[0m %s\n' "$*"; }
failures=0

cleanup() {
    docker rm -f "$NAME" >/dev/null 2>&1 || true
    docker volume rm "$HOME_VOL" "$STATE_VOL" >/dev/null 2>&1 || true
    rm -rf "$TMP"
}
trap cleanup EXIT

ssh-keygen -q -t ed25519 -N '' -f "$TMP/key" -C test
PUBKEY="$(cat "$TMP/key.pub")"

# $@: extra docker run arguments (--privileged, -e AGENTBOX_ISOLATION=...).
boot() {
    docker rm -f "$NAME" >/dev/null 2>&1 || true
    docker run -d --name "$NAME" \
        -e SSH_PUBLIC_KEY="$PUBKEY" \
        -e AGENTBOX_DOCKER=off \
        -e AGENTBOX_PERSIST_INTERVAL=0 \
        -p "127.0.0.1:$SSH_PORT:22" \
        -v "$HOME_VOL":/home/dev \
        -v "$STATE_VOL":/var/lib/agentbox \
        "$@" "$IMAGE" >/dev/null

    for _ in $(seq 90); do
        docker logs "$NAME" 2>&1 | grep -q "sshd is listening" && return 0
        docker inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null | grep -q false && return 1
        sleep 1
    done
    return 1
}

in_box()  { docker exec "$NAME" bash -lc "$1"; }
as_dev()  { docker exec -u dev "$NAME" bash -lc "$1"; }
over_ssh() {
    ssh -q -i "$TMP/key" -p "$SSH_PORT" \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=10 -o BatchMode=yes \
        dev@127.0.0.1 "$@"
}
# The cgroup a pid is in, relative to the container's root ("/control").
cgroup_of() { in_box "sed 's/^0:://' /proc/$1/cgroup" 2>/dev/null || true; }

privileged=true
docker run --rm --privileged --entrypoint true "$IMAGE" 2>/dev/null || privileged=false

if $privileged; then
    # -----------------------------------------------------------------------
    step "1. privileged: the tree comes up, and the rescue hatch still opens"
    # -----------------------------------------------------------------------
    boot --privileged || { echo "the box did not boot"; docker logs "$NAME" | tail -30; exit 1; }

    # This is the first docker exec after boot, and it is the test: a root
    # with controllers enabled in subtree_control may not accept processes,
    # and docker exec has no way to choose another cgroup.
    if docker exec "$NAME" true 2>"$TMP/exec.err"; then
        pass "docker exec works with controllers enabled on the container's root"
    else
        fail "docker exec is broken once isolation is set up: $(cat "$TMP/exec.err")"
        exit 1
    fi

    if docker logs "$NAME" 2>&1 | grep -q 'isolation: cgroups'; then
        pass "the boot log says isolation is by cgroups"
    else
        fail "the boot log does not report cgroup isolation: $(docker logs "$NAME" 2>&1 | grep -i isolation)"
    fi

    st="$(in_box 'agentbox-cgroup status' 2>&1 || true)"
    printf '%s' "$st" | grep -q '^isolation: cgroups' \
        && pass "agentbox-cgroup status agrees" \
        || fail "status does not say cgroups: $st"
    printf '%s' "$st" | grep -q 'control 1000  work 100' \
        && pass "the weights are 1000:100" \
        || fail "unexpected weights: $st"
    printf '%s' "$st" | grep -q 'control keeps' \
        && pass "a memory floor and ceiling are live" \
        || fail "no memory limits reported: $st"

    sshd_pid="$(in_box 'pgrep -x sshd | head -1')"
    herdr_pid="$(in_box 'pgrep -f "herdr server" | head -1')"
    [ "$(cgroup_of "$sshd_pid")" = "/control" ] \
        && pass "sshd is in control/" \
        || fail "sshd is in '$(cgroup_of "$sshd_pid")'"
    [ "$(cgroup_of "$herdr_pid")" = "/control" ] \
        && pass "the herdr server is in control/" \
        || fail "the herdr server is in '$(cgroup_of "$herdr_pid")'"
    [ "$(in_box "cat /proc/$herdr_pid/oom_score_adj")" = "-1000" ] \
        && pass "the herdr server has oom_score_adj -1000" \
        || fail "the herdr server's oom_score_adj is $(in_box "cat /proc/$herdr_pid/oom_score_adj")"
    [ "$(in_box 'cat /proc/1/cgroup | sed s/^0:://')" = "/control" ] \
        && pass "pid 1 left the root" \
        || fail "pid 1 is still in the root cgroup"
    in_box 'grep -q cpu /sys/fs/cgroup/cgroup.subtree_control' \
        && pass "the root delegates cpu to its children" \
        || fail "cgroup.subtree_control has no cpu: $(in_box 'cat /sys/fs/cgroup/cgroup.subtree_control')"

    # -----------------------------------------------------------------------
    step "2. panes and shells are workload; the shell is still the user's"
    # -----------------------------------------------------------------------
    user_shell="$(in_box 'getent passwd dev | cut -d: -f7')"
    server_shell="$(as_dev "tr '\\0' '\\n' < /proc/$herdr_pid/environ | sed -n 's/^SHELL=//p'")"
    pane_shell="$(as_dev "tr '\\0' '\\n' < /proc/$herdr_pid/environ | sed -n 's/^AGENTBOX_PANE_SHELL=//p'")"
    [ "$server_shell" = "/usr/local/bin/agentbox-pane-shell" ] \
        && pass "the herdr server opens panes through the wrapper" \
        || fail "the herdr server's SHELL is '$server_shell'"
    [ "$pane_shell" = "$user_shell" ] \
        && pass "and carries the user's real shell ($user_shell) for it" \
        || fail "AGENTBOX_PANE_SHELL is '$pane_shell', expected $user_shell"

    # What a pane sees, without needing a terminal: run the wrapper the way
    # herdr would, as dev, with an argument, and ask the shell it execs.
    seen="$(docker exec -u dev -e AGENTBOX_PANE_SHELL="$user_shell" "$NAME" \
        /usr/local/bin/agentbox-pane-shell -c 'echo "$SHELL|$0|$(sed s/^0::// /proc/self/cgroup)|${AGENTBOX_PANE_SHELL:-unset}"' 2>/dev/null || true)"
    IFS='|' read -r s_shell s_zero s_cg s_leak <<< "$seen"
    [ "$s_shell" = "$user_shell" ] && pass "inside the pane, SHELL is $user_shell" || fail "inside the pane SHELL is '$s_shell'"
    [ "$s_zero" = "$user_shell" ] && pass "and the process is that shell" || fail "the pane's \$0 is '$s_zero'"
    [ "$s_cg" = "/work" ] && pass "and it is in work/" || fail "the pane is in '$s_cg'"
    [ "$s_leak" = "unset" ] && pass "the wrapper's variable does not leak into the pane" || fail "AGENTBOX_PANE_SHELL leaked: $s_leak"

    # A backgrounded, detached process stays in work/.
    detached="$(docker exec -u dev -e AGENTBOX_PANE_SHELL="$user_shell" "$NAME" \
        /usr/local/bin/agentbox-pane-shell -c 'setsid nohup bash -c "sed s/^0::// /proc/self/cgroup" 2>/dev/null' 2>/dev/null || true)"
    [ "$detached" = "/work" ] && pass "setsid+nohup does not escape work/" || fail "a detached process landed in '$detached'"

    # An SSH session: the login runs in control/, what it starts is work/ --
    # a one-shot command (sshrc moves it) and a login shell (env.sh would too).
    ssh_cg="$(over_ssh 'sed s/^0::// /proc/self/cgroup' 2>/dev/null || true)"
    [ "$ssh_cg" = "/work" ] && pass "a non-interactive SSH command runs in work/" || fail "an SSH command is in '${ssh_cg:-nothing}'"
    ssh_cg="$(over_ssh 'bash -lc "sed s/^0::// /proc/self/cgroup"' 2>/dev/null || true)"
    [ "$ssh_cg" = "/work" ] && pass "an SSH login shell runs in work/" || fail "an SSH login shell is in '${ssh_cg:-nothing}'"
    root_cg="$(in_box 'sed s/^0::// /proc/self/cgroup')"
    [ "$root_cg" = "/control" ] && pass "a root shell stays in control/" || fail "a root shell is in '$root_cg'"

    # -----------------------------------------------------------------------
    step "3. saturated, the box still answers"
    # -----------------------------------------------------------------------
    ncpu="$(in_box 'nproc')"
    spinners=$(( ncpu * 4 ))
    # Busy loops in work/, as dev, detached from this exec. `agentbox-cgroup
    # enter` needs root; the wrapper does the sudo for us.
    docker exec -d -u dev -e AGENTBOX_PANE_SHELL=/bin/bash "$NAME" \
        /usr/local/bin/agentbox-pane-shell -c "for i in \$(seq $spinners); do (while :; do :; done) & done; wait"
    sleep 3
    load="$(in_box 'cut -d" " -f1 /proc/loadavg')"
    pass "started $spinners busy loops in work/ (load now $load)"

    t0=$(date +%s)
    if timeout "$LOGIN_BOUND" ssh -q -i "$TMP/key" -p "$SSH_PORT" \
         -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes \
         dev@127.0.0.1 true 2>/dev/null; then
        pass "an SSH login completed in $(( $(date +%s) - t0 ))s (bound ${LOGIN_BOUND}s)"
    else
        fail "an SSH login did not complete within ${LOGIN_BOUND}s under saturation"
    fi

    t0=$(date +%s)
    if timeout "$STATUS_BOUND" docker exec "$NAME" agentbox-herdr status 2>/dev/null | grep -q 'server: running'; then
        pass "agentbox-herdr status answered in $(( $(date +%s) - t0 ))s (bound ${STATUS_BOUND}s)"
    else
        fail "the herdr server did not answer within ${STATUS_BOUND}s under saturation"
    fi

    in_box 'pkill -u dev -f "while :" || true' >/dev/null 2>&1 || true
    in_box 'pkill -u dev bash || true' >/dev/null 2>&1 || true

    # -----------------------------------------------------------------------
    step "5. =off and =nice do what they say"
    # -----------------------------------------------------------------------
    boot --privileged -e AGENTBOX_ISOLATION=off || { echo "did not boot with =off"; exit 1; }
    st="$(in_box 'agentbox-cgroup status' 2>&1 || true)"
    printf '%s' "$st" | grep -q '^isolation: off' && pass "=off: status says off" || fail "=off status: $st"
    in_box 'test ! -d /sys/fs/cgroup/control' && pass "=off: no groups were created" || fail "=off created groups anyway"
    herdr_pid="$(in_box 'pgrep -f "herdr server" | head -1')"
    [ "$(in_box "cat /proc/$herdr_pid/oom_score_adj")" = "-1000" ] \
        && pass "=off: the OOM ordering still applies" \
        || fail "=off: the herdr server's oom_score_adj is $(in_box "cat /proc/$herdr_pid/oom_score_adj")"

    boot --privileged -e AGENTBOX_ISOLATION=nice || { echo "did not boot with =nice"; exit 1; }
    st="$(in_box 'agentbox-cgroup status' 2>&1 || true)"
    printf '%s' "$st" | grep -q 'priorities only' && pass "=nice: status says priorities only" || fail "=nice status: $st"
    sshd_ni="$(in_box 'ps -o ni= -p $(pgrep -x sshd | head -1) | tr -d " "')"
    [ "$sshd_ni" = "-10" ] && pass "=nice: sshd runs at nice -10" || fail "=nice: sshd is at nice '$sshd_ni'"
    ssh_ni="$(over_ssh 'nice' 2>/dev/null || true)"
    [ "$ssh_ni" = "0" ] && pass "=nice: an SSH shell is back at nice 0" || fail "=nice: an SSH shell is at nice '$ssh_ni'"
else
    step "1-3, 5 need a host that allows --privileged"
    skip "this one does not"
fi

# ---------------------------------------------------------------------------
step "4. unprivileged: falls back, says so, boots"
# ---------------------------------------------------------------------------
boot || { echo "the box did not boot unprivileged"; docker logs "$NAME" | tail -30; exit 1; }
pass "booted"
# Unprivileged, Docker grants neither a writable cgroup tree nor CAP_SYS_NICE,
# so the honest answer is "nothing", and the box must say that rather than
# claim priorities it could not set.
# The warning goes to stderr and "sshd is listening" to stdout; the log driver
# copies the two streams independently, so the earlier line can land after
# the later one. Wait for it rather than reading the log the instant boot
# returns.
said=false
for _ in $(seq 20); do
    if docker logs "$NAME" 2>&1 | grep -qE 'falling back to (process priorities|nothing)'; then said=true; break; fi
    sleep 1
done
if $said; then
    pass "the boot log names the fallback"
else
    fail "no fallback warning in the log: $(docker logs "$NAME" 2>&1 | grep -iE 'isolation|cgroup')"
fi
st="$(in_box 'agentbox-cgroup status' 2>&1 || true)"
printf '%s' "$st" | grep -q 'cgroups refused' \
    && pass "status names what refused" \
    || fail "status does not say what refused: $st"
over_ssh true 2>/dev/null && pass "SSH accepts a login" || fail "SSH login failed on the unprivileged box"

boot -e AGENTBOX_ISOLATION=cgroup && { fail "=cgroup booted on a tree it could not write"; } || {
    docker logs "$NAME" 2>&1 | grep -qi 'fatal' \
        && pass "=cgroup on an unwritable tree refuses to boot, with a fatal" \
        || fail "=cgroup died without the message we promise"
}

printf '\n'
if [ "$failures" -eq 0 ]; then
    printf '\033[32mall isolation checks passed\033[0m\n'
else
    printf '\033[31m%d check(s) failed\033[0m\n' "$failures"
    exit 1
fi
