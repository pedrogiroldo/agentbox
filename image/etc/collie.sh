#!/usr/bin/env bash
#
# agentbox-collie — runs Collie, the mobile web UI for the herd.
#
# Collie is in the image (/opt/collie) and is never started by default. That is
# not caution for its own sake: a running Collie hands arbitrary keystrokes to a
# live pane in a container this project runs privileged, and its *reads* — pane
# output, source, environment values — are open to anything that reaches the
# URL. The write gate does not even exist until you pair a first device. So the
# box installs it and waits to be asked. See docs/collie.md and docs/security.md.
#
# The rest of it is that Collie's default deployment already fits: it binds
# loopback, and `tailscale serve` -- which this box runs, in this same
# container -- reaches it there and hands it TLS plus the caller's tailnet
# identity. So the box does not reshape Collie. It sets the two things it alone
# knows (which multiplexer, which port), passes your own values through, and
# stops. No published port, no proxy, no bind beyond loopback.
#
# Deliberately not set, and none of them ever should be: COLLIE_HOST,
# COLLIE_ALLOW_NON_LOOPBACK_BIND, COLLIE_SKIP_SERVE, COLLIE_PUBLIC_HOSTS,
# COLLIE_ALLOWED_ORIGINS -- each one exists to undo a default that is right
# here -- and COLLIE_ALLOW_ANY_HOST, which would buy less configuration by
# re-opening DNS rebinding.
#
#   ensure  the boot path: start it if the box is configured to run it
#   start   preflight herdr, then hand off to `collie start`
#   stop    hand off to `collie stop`
#   status  what the box is doing about Collie, if anything
#
# start/stop delegate rather than launching the bridge themselves, because
# herdr's own Collie buttons call Collie's control script. Two managers with two
# ideas of what is running is worse than one indirection.
#
# Web Push is on: the box generates the VAPID keypair before starting, so a
# phone that grants permission gets a notification the moment an agent blocks
# on you -- which is most of why you would want this on a phone at all. The
# keypair is generated once and never regenerated, because replacing it
# silently unsubscribes every device that had already said yes. Browsers ask
# the human for permission, so the last step is always theirs.
#
# AGENTBOX_COLLIE=off   never start it (default)
#                =auto  start it; a failure is a warning and the box still boots
#                =on    start it; a failure is fatal
# AGENTBOX_COLLIE_PUSH=0 skips generating the push keys
# COLLIE_PUSH_SUBJECT   the RFC 8292 contact for your push provider, e.g.
#                       mailto:you@example.com. Optional, and not derived from
#                       anything: it is handed to Mozilla's and Google's push
#                       services, so it is yours to volunteer.

set -uo pipefail

USER_NAME="${AGENTBOX_USER:-dev}"
HOME_DIR="$(getent passwd "$USER_NAME" | cut -d: -f6)"
HOME_DIR="${HOME_DIR:-/home/$USER_NAME}"

MODE="${AGENTBOX_COLLIE:-off}"
PORT="${COLLIE_PORT:-8787}"
HERDR_SOCKET="$HOME_DIR/.config/herdr/herdr.sock"
START_TIMEOUT="${AGENTBOX_COLLIE_TIMEOUT:-30}"

c_info=$'\033[36m'; c_warn=$'\033[33m'; c_off=$'\033[0m'
log()  { printf '%s[agentbox]%s %s\n' "$c_info" "$c_off" "$*"; }
warn() { printf '%s[agentbox]%s %s\n' "$c_warn" "$c_off" "$*" >&2; }

# Fatal only when the operator asked for Collie explicitly (AGENTBOX_COLLIE=on).
# In `auto` the box still boots — you get an SSH session and a clear reason.
give_up() {
    if [ "$MODE" = "on" ]; then
        printf '%s[agentbox] fatal:%s %s\n' $'\033[31m' "$c_off" "$1" >&2
        exit 1
    fi
    warn "$1"
    exit 0
}

installed() { command -v collie >/dev/null 2>&1; }

# Only what the box alone knows. Collie discovers its own tailnet name, so
# there is nothing to tell it about the network it is on.
collie_env() {
    printf '%s\n' "COLLIE_MUX=herdr" "COLLIE_PORT=$PORT"
    for var in COLLIE_TRUSTED_USER COLLIE_PUBLIC_URL; do
        [ -n "${!var:-}" ] && printf '%s=%s\n' "$var" "${!var}"
    done
    return 0
}

# Root at boot, the user themselves from a shell. Either way Collie runs as the
# user, because the panes it drives and the credentials it reads are theirs.
as_user() {
    local env_args=()
    local line
    while IFS= read -r line; do env_args+=("$line"); done < <(collie_env)

    if [ "$(id -un)" = "$USER_NAME" ]; then
        env "${env_args[@]}" "$@"
    else
        # A login shell so /etc/agentbox/env.sh puts ~/.local/bin on the PATH,
        # exactly as it does for the sessions Collie will be showing.
        runuser -u "$USER_NAME" -- env "${env_args[@]}" "$@"
    fi
}

# `collie status` exits 0 whether or not the bridge is up, so the text is the
# signal. Its pidfile would be more precise and lives inside Collie's config
# home, which moves depending on whether it was linked into herdr — a version
# detail this box has no business depending on.
#
# Captured, not piped into `grep -q`: under `set -o pipefail` grep returns as
# soon as it matches, the writer takes SIGPIPE on the rest of its output, and
# the pipeline reports failure on a bridge that is up. Here that is not
# cosmetic -- the wait loop below would run out and give_up, which under
# AGENTBOX_COLLIE=on refuses the boot over a Collie that started fine.
running() {
    local out
    out="$(as_user collie status 2>/dev/null)" || return 1
    case "$out" in
        *"is running"*) return 0 ;;
        *) return 1 ;;
    esac
}

# Two preconditions, and naming which one is missing is the whole point of
# checking them separately. Collie mirrors a multiplexer, so without a herdr
# server it has nothing to show; and it has no way in of its own, so without a
# tailnet it would listen on a loopback that nothing can reach.
preflight() {
    installed || give_up "collie is not installed in this image"

    if [ ! -S "$HERDR_SOCKET" ]; then
        give_up "no herdr server is running ($HERDR_SOCKET is not there), so Collie has nothing to mirror — check AGENTBOX_HERDR_SERVER"
    fi

    if ! agentbox-tailscaled joined >/dev/null 2>&1; then
        give_up "this box has not joined a tailnet, so nothing could reach Collie — set AGENTBOX_TAILSCALE (docs/tailscale.md)"
    fi
}

start() {
    if running; then
        log "collie is already running"
        return 0
    fi

    preflight

    # Before the start, so the bridge reads the keys as it comes up. Running
    # this on a box that already has keys is a no-op that exits 0 -- it refuses
    # to overwrite, which is exactly the behaviour we want, because replacing
    # them makes every subscribed device silently stop receiving anything.
    if [ "${AGENTBOX_COLLIE_PUSH:-1}" != "0" ]; then
        if [ -n "${COLLIE_PUSH_SUBJECT:-}" ]; then
            as_user collie push-keys "$COLLIE_PUSH_SUBJECT" >/dev/null 2>&1 || true
        else
            as_user collie push-keys >/dev/null 2>&1 || true
        fi
    fi

    log "starting collie on port $PORT"
    as_user collie start >/dev/null 2>&1

    local waited=0
    while [ "$waited" -lt "$START_TIMEOUT" ] && ! running; do
        sleep 1
        waited=$((waited + 1))
    done

    if ! running; then
        give_up "collie did not come up in ${START_TIMEOUT}s — run 'collie status' for its own account of why"
    fi

    log "collie is up — $(tailnet_url)"
}

stop() {
    installed || return 0
    # `collie stop` is idempotent and exits 0 on a bridge that is already down.
    as_user collie stop >/dev/null 2>&1 || true
}

# What a phone would actually open, when there is one.
tailnet_url() {
    local name
    name="$(tailscale status --json 2>/dev/null \
        | sed -n 's/.*"DNSName"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
        | head -1 | sed 's/\.$//')"
    if [ -n "$name" ]; then
        echo "https://$name"
    else
        echo "reachable from nowhere — this box has not joined a tailnet"
    fi
}

# Four outcomes, deliberately distinct: with a default of off, the most common
# reader of this is someone who has not enabled it yet and needs to be told
# which variable to set — not someone debugging a crash. And a Collie running
# with no front door looks identical to a working one unless it is said out loud.
status() {
    if ! installed; then
        echo "collie is not installed in this image"
        return 1
    fi

    if running; then
        echo "collie: running on port $PORT (loopback only, by design)"
        echo "  open: $(tailnet_url)"
        [ -n "${COLLIE_TRUSTED_USER:-}" ] \
            && echo "  identity check: COLLIE_TRUSTED_USER=${COLLIE_TRUSTED_USER}" \
            || echo "  no identity check — anyone on the tailnet who opens it reads every pane"
        if [ "${AGENTBOX_COLLIE_PUSH:-1}" = "0" ]; then
            echo "  push notifications: keys not generated (AGENTBOX_COLLIE_PUSH=0)"
        else
            echo "  push notifications: keys ready — enable them on the phone in Settings"
        fi
        agentbox-tailscaled joined >/dev/null 2>&1 || return 1
        return 0
    fi

    if [ "$MODE" = "off" ]; then
        echo "collie: installed, not running (AGENTBOX_COLLIE=off, which is the default)"
        echo "  set AGENTBOX_COLLIE=auto to start it at boot — read docs/security.md first"
        return 0
    fi

    echo "collie: configured to run (AGENTBOX_COLLIE=$MODE) but not running"
    echo "  run 'agentbox-collie start', or 'collie status' for its own account"
    return 1
}

# Boot path. `off` is a decision, not a failure, so it says nothing and leaves.
ensure() {
    case "$MODE" in
        off) exit 0 ;;
        auto|on) start ;;
        *) warn "AGENTBOX_COLLIE=$MODE is not one of off|auto|on — treating it as off"; exit 0 ;;
    esac
}

case "${1:-status}" in
    ensure) ensure ;;
    start)  start ;;
    stop)   stop ;;
    status) status ;;
    *) echo "usage: agentbox-collie {ensure|start|stop|status}" >&2; exit 2 ;;
esac
