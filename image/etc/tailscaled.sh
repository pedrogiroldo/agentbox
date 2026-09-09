#!/usr/bin/env bash
#
# agentbox-tailscaled — the box's own front door onto a private network.
#
# This is what makes a phone able to reach anything in here without a port
# published to the internet and without a proxy in front. Collie has no other
# way in at all; SSH gets a better one than an open 2222.
#
# Two things about it are worth knowing before reading the code.
#
# 1. --tun=userspace-networking. tailscaled normally asks the kernel for a TUN
#    interface, which a container may not have and which needs NET_ADMIN. In
#    userspace mode it does its own TCP/IP instead, and `tailscale serve` --
#    which terminates connections inside tailscaled itself -- works either way.
#    So the box joins a tailnet with no /dev/net/tun and no added capability.
#    It costs some throughput on bulk transfers, which a web UI and a terminal
#    do not notice. This box does run privileged for its Docker daemon, but
#    depending on that here would break the box for anyone who dropped it.
#
# 2. The state lives in the state volume, not /var/lib/tailscale. /var/lib is
#    not in AGENTBOX_PERSIST_PATHS and is not a volume, so the default location
#    loses the node identity on every recreate: the box comes back asking to be
#    authenticated again, under a new name, with the old node left dangling in
#    the admin console.
#
#   login   join interactively: prints the URL and a QR code and waits. This
#           is the normal way in -- you are already in a shell, and it leaves
#           no credential anywhere
#   ensure  the boot path: join if the box is configured to
#   start   run the daemon, then join if it is not a member yet
#   stop    shut the daemon down
#   status  what the box has joined, if anything
#   joined  exit 0 only if this box is actually a member -- the one question
#           another service needs answered, and `status` cannot answer it with
#           an exit code because "deliberately off" is not a failure
#
# AGENTBOX_TAILSCALE=off   never join (default)
#                  =auto   join; a failure is a warning and the box still boots
#                  =on     join; a failure is fatal
#
# TS_AUTHKEY exists for the one case `login` cannot serve: a deploy platform
# starting a container at 3am with nobody watching. It is a credential in a
# file, so it is the exception, not the path. Use a *non-ephemeral* key --
# an ephemeral node is removed from the tailnet shortly after it goes offline,
# which is the opposite of what the state volume is here to buy. The key is
# used once, in join(), and is never written anywhere that outlives this boot:
# not into /etc/agentbox/config.env, not into the persisted state.
#
# `tailscale funnel` is never used and never will be: funnel is the public
# internet, serve is the tailnet. See docs/tailscale.md.

set -uo pipefail

USER_NAME="${AGENTBOX_USER:-dev}"
MODE="${AGENTBOX_TAILSCALE:-off}"

STATE_DIR="${AGENTBOX_PERSIST_DIR:-/var/lib/agentbox}/tailscale"
STATE="$STATE_DIR/tailscaled.state"
SOCKET=/var/run/tailscale/tailscaled.sock
LOG_DIR="${AGENTBOX_PERSIST_DIR:-/var/lib/agentbox}/log"
LOG="$LOG_DIR/tailscaled.log"
START_TIMEOUT="${AGENTBOX_TAILSCALE_TIMEOUT:-30}"

c_info=$'\033[36m'; c_warn=$'\033[33m'; c_off=$'\033[0m'
log()  { printf '%s[agentbox]%s %s\n' "$c_info" "$c_off" "$*"; }
warn() { printf '%s[agentbox]%s %s\n' "$c_warn" "$c_off" "$*" >&2; }

# Fatal only when the operator asked for the tailnet explicitly (=on).
give_up() {
    if [ "$MODE" = "on" ]; then
        printf '%s[agentbox] fatal:%s %s\n' $'\033[31m' "$c_off" "$1" >&2
        exit 1
    fi
    warn "$1"
    exit 0
}

installed() { command -v tailscaled >/dev/null 2>&1; }

daemon_running() {
    [ -S "$SOCKET" ] && tailscale status --json >/dev/null 2>&1
}

# Three states worth telling apart: no daemon, a daemon nobody has logged in
# on, and a member. `tailscale status` says "Logged out." for the middle one.
backend_state() {
    tailscale status --json 2>/dev/null \
        | sed -n 's/.*"BackendState"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
        | head -1
}

joined() { [ "$(backend_state)" = "Running" ]; }

tailnet_name() {
    tailscale status --json 2>/dev/null \
        | sed -n 's/.*"DNSName"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
        | head -1 | sed 's/\.$//'
}

start_daemon() {
    daemon_running && return 0

    mkdir -p "$STATE_DIR" "$LOG_DIR" /var/run/tailscale 2>/dev/null || true
    chmod 0700 "$STATE_DIR" 2>/dev/null || true

    log "starting tailscaled (userspace networking)"
    # `setsid --fork` rather than `setsid ... &`: plain setsid execs instead of
    # forking when the caller is not already a process-group leader, so whether
    # the daemon outlives this script would depend on how the script was
    # called. --fork always forks and tini adopts the orphan.
    setsid --fork tailscaled \
        --tun=userspace-networking \
        --state="$STATE" \
        --socket="$SOCKET" \
        >>"$LOG" 2>&1

    local waited=0
    while [ "$waited" -lt "$START_TIMEOUT" ] && ! daemon_running; do
        sleep 1
        waited=$((waited + 1))
    done

    daemon_running
}

# Only ever runs on a box that is not a member yet. An existing node comes back
# from the state file with no call to the control plane's login flow at all.
join() {
    joined && return 0

    local args=(--operator="$USER_NAME")
    [ -n "${TS_HOSTNAME:-}" ] && args+=(--hostname="$TS_HOSTNAME")

    # No key means a human has to open a URL, and a boot must never wait on a
    # human. Rather than launching a blocking `tailscale up` into the
    # background and burying its URL in a log nobody reads, say the one thing
    # that gets the operator unstuck.
    if [ -z "${TS_AUTHKEY:-}" ]; then
        log "no TS_AUTHKEY — run 'agentbox-tailscaled login' from a shell to join"
        return 0
    fi

    log "joining the tailnet with the auth key from the environment"
    # The key reaches exactly this call. Nothing writes it down.
    tailscale up --authkey="$TS_AUTHKEY" "${args[@]}" >>"$LOG" 2>&1

    if joined; then
        log "joined the tailnet as $(tailnet_name)"
        return 0
    fi

    return 1
}

# Interactive join. `tailscale up` blocks until somebody completes the login,
# which is exactly right for a person at a terminal and exactly wrong for a
# boot -- so this is a verb you run, never something ensure() calls.
login() {
    if ! installed; then
        echo "tailscale is not installed in this image (INSTALL_TAILSCALE=false)" >&2
        return 1
    fi

    # `tailscale up` needs root until --operator is set, which is what this
    # command is about to do. Passwordless sudo is a given in this box, so
    # re-run rather than failing with a permissions error -- but say so.
    if [ "$(id -u)" != 0 ]; then
        log "re-running under sudo: tailscale up needs root until the operator is set"
        exec sudo -E "$0" login
    fi

    if joined; then
        echo "this box is already on a tailnet, as $(tailnet_name)"
        echo "  a different tailnet:  sudo tailscale logout, then $0 login"
        echo "  re-authenticate:      sudo tailscale up --force-reauth --qr"
        return 0
    fi

    start_daemon || {
        warn "tailscaled did not come up in ${START_TIMEOUT}s — check $LOG"
        return 1
    }

    local args=(--operator="$USER_NAME" --qr)
    [ -n "${TS_HOSTNAME:-}" ] && args+=(--hostname="$TS_HOSTNAME")

    echo
    echo "  Open the URL below, or scan the code with the phone you are going"
    echo "  to use. This waits until you are done."
    echo

    # Foreground, unredirected: the URL and the QR code it prints are the
    # entire point of this verb.
    tailscale up "${args[@]}" || {
        warn "the login did not complete"
        return 1
    }

    if ! joined; then
        warn "tailscale up returned but this box is still not a member — 'tailscale status' knows more"
        return 1
    fi

    echo
    log "joined as $(tailnet_name)"
    echo "  this box is now reachable at https://$(tailnet_name) from your other devices"
    if [ "${AGENTBOX_COLLIE:-off}" != "off" ]; then
        echo "  starting collie:  agentbox-collie start"
    else
        echo "  the herd in a browser:  set AGENTBOX_COLLIE=auto (docs/collie.md)"
    fi
    return 0
}

start() {
    installed || give_up "tailscale is not installed in this image (INSTALL_TAILSCALE=false)"

    start_daemon || give_up "tailscaled did not come up in ${START_TIMEOUT}s — check $LOG"
    join || give_up "the auth key was refused — check $LOG"
}

# --fork means the pid is not ours to record, so match on the command line --
# which is unambiguous here: nothing else in this box runs tailscaled.
stop() {
    installed || return 0
    pkill -f 'tailscaled --tun=userspace-networking' 2>/dev/null || true
    return 0
}

# Four outcomes, because "not joined" has three quite different causes and the
# reader needs to know which one they have.
status() {
    if ! installed; then
        echo "tailscale is not installed in this image"
        return 1
    fi

    if joined; then
        echo "tailnet: joined as $(tailnet_name)"
        echo "  state: $STATE (in the state volume, so a recreate keeps this node)"
        return 0
    fi

    if daemon_running; then
        echo "tailnet: daemon running, not authenticated ($(backend_state))"
        echo "  run 'agentbox-tailscaled login' — it prints a URL and a QR code"
        return 1
    fi

    if [ "$MODE" = "off" ]; then
        echo "tailnet: not joined (AGENTBOX_TAILSCALE=off, which is the default)"
        echo "  set AGENTBOX_TAILSCALE=auto, then run 'agentbox-tailscaled login'"
        return 0
    fi

    echo "tailnet: configured to join (AGENTBOX_TAILSCALE=$MODE) but no daemon is running"
    echo "  check $LOG"
    return 1
}

ensure() {
    case "$MODE" in
        off) exit 0 ;;
        auto|on) start ;;
        *) warn "AGENTBOX_TAILSCALE=$MODE is not one of off|auto|on — treating it as off"; exit 0 ;;
    esac
}

case "${1:-status}" in
    login)  login ;;
    ensure) ensure ;;
    start)  start ;;
    stop)   stop ;;
    status) status ;;
    joined) joined ;;
    *) echo "usage: agentbox-tailscaled {login|ensure|start|stop|status|joined}" >&2; exit 2 ;;
esac
