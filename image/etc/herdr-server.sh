#!/usr/bin/env bash
#
# agentbox-herdr — runs the herdr server as a service of the box.
#
# Until now herdr existed only after you logged in over SSH and typed `herdr`.
# That is fine when a terminal is the only way in, and it is exactly what makes
# "open the phone and see the agents" impossible: Collie mirrors a multiplexer,
# and `herdr plugin link` talks to a running server, so both need one before
# anyone connects. Hence a server at boot.
#
# Nothing about the interactive experience changes. `herdr` from a shell
# attaches to this server the same way it attaches to a session you started
# yourself, and detaching still leaves the agents running.
#
#   start   launch the server as the box user and wait for its socket
#   stop    ask it to shut down
#   status  whether the socket is answering
#
# AGENTBOX_HERDR_SERVER=0 turns it off and gives you exactly today's behaviour.
#
# Starting this can never be fatal. SSH is the box's recovery path, and a
# multiplexer that will not start is precisely when that path is needed.

set -uo pipefail

USER_NAME="${AGENTBOX_USER:-dev}"
HOME_DIR="$(getent passwd "$USER_NAME" | cut -d: -f6)"
HOME_DIR="${HOME_DIR:-/home/$USER_NAME}"

SOCKET="$HOME_DIR/.config/herdr/herdr.sock"
LOG_DIR="${AGENTBOX_PERSIST_DIR:-/var/lib/agentbox}/log"
LOG="$LOG_DIR/herdr-server.log"
START_TIMEOUT="${AGENTBOX_HERDR_TIMEOUT:-45}"

c_info=$'\033[36m'; c_warn=$'\033[33m'; c_off=$'\033[0m'
log()  { printf '%s[agentbox]%s %s\n' "$c_info" "$c_off" "$*"; }
warn() { printf '%s[agentbox]%s %s\n' "$c_warn" "$c_off" "$*" >&2; }

as_user() {
    if [ "$(id -un)" = "$USER_NAME" ]; then
        "$@"
    else
        runuser -u "$USER_NAME" -- "$@"
    fi
}

# The socket answering is the only definition of "running" that matters here:
# it is what `herdr plugin link` and Collie's bridge both dial. `herdr status
# server` exits 0 either way, so the word is the signal.
#
# Captured into a variable rather than piped into `grep -q`, and that is not
# style. Under `set -o pipefail` the pipeline takes the *worst* exit status in
# it: grep -q returns the moment it matches, the writer upstream gets SIGPIPE
# (141) for the rest of its output, and the pipeline reports failure on a
# server that is plainly running. It happens perhaps one time in six, entirely
# on buffering -- which reads as flakiness in the infrastructure right up until
# you look.
running() {
    [ -S "$SOCKET" ] || return 1
    local out
    out="$(as_user herdr status server 2>/dev/null)" || return 1
    case "$out" in
        *"status: running"*) return 0 ;;
        *) return 1 ;;
    esac
}

start() {
    if running; then
        log "herdr server is already running"
        return 0
    fi

    if [ "${AGENTBOX_HERDR_SERVER:-1}" = "0" ]; then
        return 0
    fi

    mkdir -p "$LOG_DIR" 2>/dev/null || true
    log "starting the herdr server"

    # Owned by the user, not by root: the panes it hosts and the agent
    # credentials they read are theirs, and a session started here has to be
    # indistinguishable from one an SSH login would have created.
    #
    # `setsid --fork`, not `setsid ... &`. Plain setsid *execs* when the caller
    # is not already a process-group leader and *forks* when it is -- so
    # whether the server outlives this script depends on how this script was
    # called. It does not always, which is exactly the kind of intermittent
    # that costs an afternoon. --fork always forks, the parent returns, and
    # tini adopts the orphan.
    # The redirect stays out here, on the root side: /var/lib/agentbox is a
    # root-owned volume, so a `bash -c "... >>$LOG"` running as dev cannot open
    # the file at all. Opened here, the fd is simply inherited.
    as_user setsid --fork herdr server >>"$LOG" 2>&1

    local waited=0
    while [ "$waited" -lt "$START_TIMEOUT" ] && ! running; do
        sleep 1
        waited=$((waited + 1))
    done

    if ! running; then
        warn "the herdr server did not come up in ${START_TIMEOUT}s — check $LOG"
        return 1
    fi

    log "herdr server is up — sessions survive between logins"
}

stop() {
    running || return 0
    as_user herdr server stop >/dev/null 2>&1 || true
}

status() {
    if running; then
        echo "herdr server: running (socket $SOCKET)"
        return 0
    fi
    if [ "${AGENTBOX_HERDR_SERVER:-1}" = "0" ]; then
        echo "herdr server: not started by the box (AGENTBOX_HERDR_SERVER=0)"
        echo "  run 'herdr' from a shell to start one yourself"
        return 0
    fi
    echo "herdr server: not running — check $LOG"
    return 1
}

case "${1:-status}" in
    start)  start ;;
    stop)   stop ;;
    status) status ;;
    *) echo "usage: agentbox-herdr {start|stop|status}" >&2; exit 2 ;;
esac
