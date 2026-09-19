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
#   start   preflight herdr, hand off to `collie start`, then put the bridge
#           in the control-plane cgroup if it came up outside it
#   stop    hand off to `collie stop`
#   status  what the box is doing about Collie, if anything
#   prune   remove the releases an in-place update left behind (keeps the
#           current one and its predecessor), adopt a release the image ships
#           that is newer than the current pointer, and clear the scratch
#           space a failed update left; [dir] prunes another copy of the tree,
#           which is how the state volume gets the same treatment
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

    # Collie is control plane, and a bridge only inherits that from the process
    # that started it. From the entrypoint this is already true and the call is
    # a no-op; from a pane or an SSH shell the bridge just came up as workload
    # -- weighted behind the agents it exists to let you watch, and ahead of
    # them in the queue to be killed. Placing another process needs root, and
    # the box already grants the user passwordless sudo for exactly this move;
    # agentbox-pane-shell does the mirror image of it. Quiet either way: a
    # Collie that is up but badly placed beats one that refused to start.
    if [ "$(id -u)" = 0 ]; then
        agentbox-cgroup protect >/dev/null 2>&1 || true
    else
        sudo -n agentbox-cgroup protect >/dev/null 2>&1 || true
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

# Where the image writes the Collie release it installed. The prune reads it
# to tell a release the image brought from one a running box staged, which is
# the difference between "adopt this" and "leave it alone". Overridable so the
# test suite can point it at a fixture.
IMAGE_VERSION_FILE="${AGENTBOX_COLLIE_IMAGE_VERSION:-/usr/share/agentbox/collie-version}"
OVERLAY_ROOT="${AGENTBOX_PERSIST_DIR:-/var/lib/agentbox}/overlay"

# The tree the version record describes. Adoption is about the live install
# only: the state volume's copy is pruned with the same code, but the image's
# release was never copied into it, so asking it to adopt would refuse once
# per pass and say so in the log for no reason. Overridable for the tests.
LIVE_BASE="${AGENTBOX_COLLIE_DIR:-/opt/collie}"

# Is $1 strictly newer than $2, by version sort? `sort -V` decides, so the
# comparison matches the ordering the prune already uses everywhere else.
newer_than() {
    [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$1" ]
}

# A release tree is usable if the two paths this box resolves through are
# there: /usr/local/bin/collie points into bin/collie, and `herdr plugin link`
# wants the manifest. Adopting a tree missing either leaves the box with no
# working `collie` command at all, which is worse than the stale pointer.
usable_release() {
    [ -x "$1/bin/collie" ] && [ -e "$1/herdr-plugin.toml" ]
}

# Old releases. `collie update` stages the next release beside the current one
# and moves the old one into .trash with rename(2). The release the image
# shipped is a directory in the overlayfs lower layer, and renaming one of
# those out needs a mount option Docker does not set, so it fails with EXDEV;
# Collie logs "harmless where it is" and never comes back for it -- or for
# the ones after it. Eight releases at 84 MB each, on the box this was found
# on, and every one of them newer than the image stamp, so the persistence
# layer copied them all into the state volume and laid them back down at
# every boot.
#
# rm -rf works where rename does not: overlayfs covers a removal with a
# whiteout. Keep the release `current` points at and the newest one older
# than it (a rollback costs 84 MB) and remove the rest. Refuse on a layout
# that is not the installer's, and say so once.
#
# A release *newer* than current is one of two things, and they get opposite
# treatment:
#
#   the image's   the pointer in the state volume is older than what this
#                 image ships. Collie can never resolve that itself -- its
#                 updater has to rename the image's copy aside and overlayfs
#                 returns EXDEV -- so it deadlocks on every attempt. The box
#                 adopts instead: repoint current, and drop the superseded
#                 pointer from the saved layer so a recreate does not put it
#                 back. The version record says which release is the image's.
#   staged here   an update caught between unpacking and flipping the link.
#                 Not ours to touch, exactly as before.
#
# With no version record -- a box running an image built before this existed
# -- nothing is the image's, so nothing is adopted and nothing is said.
#
# The optional argument is the tree to prune; agentbox-persist passes its own
# copy of /opt/collie, so the state volume gets the same treatment.
prune() {
    local base="${1:-$LIVE_BASE}" versions cur cur_name
    versions="$base/versions"
    [ -d "$versions" ] || return 0

    cur="$(readlink -f "$base/current" 2>/dev/null)" || cur=""
    case "$cur" in
        "$versions"/*) cur_name="${cur#"$versions"/}"; cur_name="${cur_name%%/*}" ;;
        *) log "not pruning $base: 'current' does not resolve into versions/ (${cur:-missing})"; return 0 ;;
    esac
    [ -d "$versions/$cur_name" ] || { log "not pruning $base: current points at a missing release ($cur_name)"; return 0; }

    # Adoption comes first: it decides which release `current` names, and
    # everything below splits the list on that name. Not a command
    # substitution -- that is a subshell, and it would swallow the line the
    # adoption logs into the variable instead of printing it.
    adopt_image_release "$base" "$versions" "$cur_name"
    cur_name="$CURRENT_RELEASE"

    # Oldest first, by version. `current` splits the list: everything after it
    # was staged more recently and is not ours to touch. Both initialised:
    # under `set -u` a declared-but-never-assigned array makes ${#older[@]}
    # below a fatal unbound reference, which is reachable whenever current is
    # the oldest release and something else is doomed.
    local -a all=() older=()
    mapfile -t all < <(find "$versions" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort -V)
    local v seen=0
    for v in "${all[@]}"; do
        if [ "$v" = "$cur_name" ]; then seen=1; continue; fi
        [ "$seen" = 0 ] && older+=("$v")
    done

    local -a doomed=()
    if [ "${#older[@]}" -gt 1 ]; then
        doomed=("${older[@]:0:${#older[@]}-1}")
    fi
    [ -d "$base/.trash" ] && [ -n "$(ls -A "$base/.trash" 2>/dev/null)" ] && doomed+=(".trash")
    # .staging is Collie's scratch space for a download in flight. It means
    # nothing between runs, and a failed update leaves it full -- 123 MB on
    # the box this was found on, root-owned, which then fails the *next*
    # update with EACCES. At boot and from `save` this runs as root, so whose
    # it is does not matter there; a by-hand run that cannot unlink it says so
    # below rather than passing over it in silence.
    [ -d "$base/.staging" ] && doomed+=(".staging")

    [ "${#doomed[@]}" -gt 0 ] || return 0

    local removed=() refused=()
    for v in "${doomed[@]}"; do
        case "$v" in
            .trash|.staging) rm -rf -- "$base/$v" 2>/dev/null && removed+=("$v") || refused+=("$v") ;;
            *) rm -rf -- "${versions:?}/$v" 2>/dev/null && removed+=("$v") || refused+=("$v") ;;
        esac
    done
    # Every removal above is silenced, and a refusal leaves `removed` empty --
    # so without this the run prints nothing at all and still exits 0, and the
    # entrypoint's `|| warn` never fires. The case that reaches it is the
    # documented by-hand one: `agentbox-collie prune` as the box's user, against
    # the root-owned .staging a restore laid back down. Say so instead.
    [ "${#refused[@]}" -eq 0 ] \
        || warn "could not remove from $base: ${refused[*]} — not yours to unlink? try sudo"
    [ "${#removed[@]}" -gt 0 ] || return 0
    log "pruned ${#removed[@]} old collie release(s) from $base: ${removed[*]} (keeping $cur_name${older[*]:+ and ${older[-1]}})"
    return 0
}

# Point `current` at the release the image ships, when that is newer than the
# one it points at now. Leaves CURRENT_RELEASE holding the release name
# `current` carries afterwards -- the adopted one, or the one it came in with
# -- because the caller splits the version list on it. A global rather than a
# printed value on purpose: this function logs, and a command substitution
# would capture those lines instead of showing them.
#
# Nothing here touches a release the image did not ship: the record names one
# version, and anything else newer than current is an update staged since boot.
adopt_image_release() {
    local base="$1" versions="$2" cur_name="$3" shipped=""
    CURRENT_RELEASE="$cur_name"

    [ "$base" = "$LIVE_BASE" ] || return 0
    [ -r "$IMAGE_VERSION_FILE" ] || return 0
    # `read` returns 1 at EOF even when it assigned: a record written without a
    # trailing newline holds a whole version, and bailing on that exit status
    # would skip the adoption silently. Emptiness is the test that matters.
    read -r shipped < "$IMAGE_VERSION_FILE" 2>/dev/null || true
    [ -n "$shipped" ] || return 0
    newer_than "$shipped" "$cur_name" || return 0

    if [ ! -d "$versions/$shipped" ]; then
        log "not adopting collie $shipped in $base: the image records it but $versions/$shipped is not there"
        return 0
    fi
    if ! usable_release "$versions/$shipped"; then
        log "not adopting collie $shipped in $base: that release tree has no executable bin/collie or no herdr-plugin.toml"
        return 0
    fi

    ln -sfn "versions/$shipped" "$base/current.adopting" 2>/dev/null \
        && mv -Tf "$base/current.adopting" "$base/current" 2>/dev/null || {
        rm -f "$base/current.adopting" 2>/dev/null
        log "could not adopt collie $shipped in $base: 'current' would not move"
        return 0
    }

    # The live flip alone settles only once a save has run. A recreate before
    # that would restore the saved pointer at the old release and need a
    # second boot to come right, so the stale pointer goes now. A recreate
    # then finds no pointer in the saved layer and the image's own shows
    # through -- the same answer. This widens the prune's existing exception
    # (the one path that edits the overlay outside save and forget) from
    # versions/ to the pointer beside it, and no further.
    drop_superseded_overlay_pointer "$cur_name"

    log "adopted collie $shipped from the image in $base, replacing $cur_name (keeping it for rollback)"
    CURRENT_RELEASE="$shipped"
    return 0
}

# Remove the overlay's `current` when it still pins the release just
# superseded. Only ever called from the live tree's adoption, and only ever
# removes a pointer -- never a release.
drop_superseded_overlay_pointer() {
    # Mirrored under the overlay at the tree's own absolute path, so the
    # knob that moves the live tree moves this with it rather than leaving
    # adoption editing /opt/collie's pointer on a box configured elsewhere.
    local superseded="$1" overlay_ptr="$OVERLAY_ROOT$LIVE_BASE/current" target

    [ -L "$overlay_ptr" ] || return 0
    target="$(readlink "$overlay_ptr" 2>/dev/null)" || return 0
    # Relative ("versions/1.10.1") or absolute, both end in the release name;
    # a bare name is covered too. Anything else is a pointer at some other
    # release and is not this adoption's business.
    case "$target" in
        *"/$superseded"|"$superseded") rm -f "$overlay_ptr" 2>/dev/null ;;
    esac
    return 0
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
    prune)  shift; prune "$@" ;;
    *) echo "usage: agentbox-collie {ensure|start|stop|status|prune [dir]}" >&2; exit 2 ;;
esac
