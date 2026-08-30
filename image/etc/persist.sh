#!/usr/bin/env bash
# agentbox-persist — keeps what you install alive across container recreates.
#
# The image is never mounted over, so it stays the source of truth: a newer
# agentbox still ships a newer node, nvim, herdr and agents. What this keeps is
# the *delta* -- what you added on top of the image -- and replays it on boot:
#
#   packages   a dpkg hook records every `apt install` you make; boot
#              reinstalls the list from a .deb cache that lives in the volume
#   files      anything under the watched paths that is newer than the image
#              build stamp is copied into the volume and rsynced back at boot
#
# Deletions are not tracked: removing a file the image ships brings it back on
# the next boot. `forget` and `reset` are the escape hatches.
#
# Runs as root. `save` is safe to run by hand at any time:
#     sudo agentbox-persist save
set -uo pipefail

STATE_ROOT="${AGENTBOX_PERSIST_DIR:-/var/lib/agentbox}"
OVERLAY="$STATE_ROOT/overlay"
APT_DIR="$STATE_ROOT/apt"
PKG_LIST="$APT_DIR/packages"
LOG_DIR="$STATE_ROOT/log"
LOCK="$STATE_ROOT/.lock"

# The image drops both of these on its last build step; overridable so the
# test suite can point them somewhere writable.
STAMP="${AGENTBOX_PERSIST_STAMP:-/usr/share/agentbox/build-stamp}"
BASELINE="${AGENTBOX_PERSIST_BASELINE:-/usr/share/agentbox/apt-baseline}"

# Where a `make install`, a curl|sh installer or an edited config file lands.
# /usr and /var are deliberately absent: that is dpkg's territory, and the
# package list replays it.
read -r -a WATCHED <<< "${AGENTBOX_PERSIST_PATHS:-/usr/local /opt /etc /root /srv}"

# Directories that are big, rebuilt from the image, or pure cache. Pruned from
# the scan entirely, which is also what keeps `save` fast.
PRUNED=(
    /opt/agentbox
    /var/lib/agentbox
    /root/.cache
    /root/.npm
    /root/.bun
)

# Files that change on their own every boot. Persisting them would fight the
# entrypoint (or Docker) for ownership of the value.
VOLATILE=(
    /etc/agentbox/config.env
    /etc/agentbox/sshd.d/10-password.conf
    /etc/ssh/sshd_config
    /etc/hostname
    /etc/hosts
    /etc/resolv.conf
    /etc/mtab
    /etc/localtime
    /etc/timezone
    /etc/machine-id
    /etc/ld.so.cache
    /etc/.pwd.lock
    /etc/passwd
    /etc/passwd-
    /etc/shadow
    /etc/shadow-
    /etc/group
    /etc/group-
    /etc/gshadow
    /etc/gshadow-
    /etc/subuid
    /etc/subuid-
    /etc/subgid
    /etc/subgid-
)

log()  { printf '[agentbox-persist] %s\n' "$*"; }
warn() { printf '[agentbox-persist] %s\n' "$*" >&2; }

enabled() { [ "${AGENTBOX_PERSIST:-1}" != "0" ]; }

need_root() {
    [ "$(id -u)" = "0" ] || { warn "must run as root (try: sudo agentbox-persist $*)"; exit 1; }
}

ensure_dirs() {
    install -d -m 0755 "$STATE_ROOT" "$OVERLAY" "$APT_DIR" "$LOG_DIR" \
        "$APT_DIR/archives/partial" "$APT_DIR/lists/partial"
    [ -e "$PKG_LIST" ] || : > "$PKG_LIST"
}

# Serialise saves: the boot save, the watcher and a hand-run one can collide.
# The watcher lives for the life of the container, so the lock has to be given
# back at the end of each pass rather than held until the process exits.
with_lock() {
    exec 9>"$LOCK"
    flock -w 60 9 || { warn "another agentbox-persist run holds the lock"; return 1; }
}
release_lock() { exec 9>&-; }

# ---------------------------------------------------------------------------
# Files
# ---------------------------------------------------------------------------

# Everything under the watched paths that postdates the image build.
changed_files() {
    local prune=() first=1 dir p
    for dir in "${PRUNED[@]}"; do
        [ $first = 1 ] || prune+=( -o )
        prune+=( -path "$dir" )
        first=0
    done

    for p in "${WATCHED[@]}"; do
        [ -e "$p" ] || continue
        find "$p" -xdev \( "${prune[@]}" \) -prune -o \
            \( -type f -o -type l \) -newer "$STAMP" -print 2>/dev/null
    done
}

cmd_save() {
    need_root save
    enabled || { log "persistence is off (AGENTBOX_PERSIST=0)"; return 0; }
    [ -e "$STAMP" ] || { warn "no build stamp at $STAMP — is this an agentbox image?"; return 1; }
    ensure_dirs
    with_lock || return 1

    local list volatile
    list="$(mktemp)"; volatile="$(mktemp)"
    printf '%s\n' "${VOLATILE[@]}" > "$volatile"

    # rsync wants paths relative to the transfer root, which is /.
    changed_files | grep -Fxvf "$volatile" | sed 's|^/||' > "$list"

    local count
    count="$(wc -l < "$list")"
    if [ "$count" -gt 0 ]; then
        rsync -a --files-from="$list" / "$OVERLAY/" 2>/dev/null \
            || warn "rsync could not copy every file into the state volume"
    fi
    date -Is > "$STATE_ROOT/.last-save"
    rm -f "$list" "$volatile"
    release_lock
    log "kept $count file(s) from ${WATCHED[*]}"
}

cmd_restore() {
    need_root restore
    enabled || { log "persistence is off (AGENTBOX_PERSIST=0)"; return 0; }
    ensure_dirs
    [ -n "$(ls -A "$OVERLAY" 2>/dev/null)" ] || return 0

    # Count the files, not the directories rsync walks through. Keep the two
    # steps apart: pipefail would turn an rsync warning into a count of zero.
    local out restored
    out="$(rsync -a --out-format='%n' "$OVERLAY/" / 2>/dev/null)" \
        || warn "rsync hit errors while restoring; some files may be missing"
    restored="$(printf '%s\n' "$out" | awk 'NF && !/\/$/' | wc -l)"
    log "restored $restored file(s) you added on top of the image"
}

# ---------------------------------------------------------------------------
# Packages
# ---------------------------------------------------------------------------

# Manually installed packages minus the ones the image already had.
cmd_record_apt() {
    enabled || return 0
    [ "$(id -u)" = "0" ] || return 0
    [ -r "$BASELINE" ] || return 0
    ensure_dirs

    # LC_ALL=C on both sides: comm compares line by line and a locale-aware
    # sort orders package names differently (punctuation is weighted apart).
    local now; now="$(mktemp)"
    apt-mark showmanual 2>/dev/null | LC_ALL=C sort > "$now" || { rm -f "$now"; return 0; }
    # A truncated list would silently drop your packages; refuse to write one.
    [ -s "$now" ] || { rm -f "$now"; return 0; }

    LC_ALL=C comm -13 "$BASELINE" "$now" > "$PKG_LIST.tmp" && mv "$PKG_LIST.tmp" "$PKG_LIST"
    rm -f "$now" "$PKG_LIST.tmp"
}

cmd_replay_apt() {
    need_root replay-apt
    enabled || return 0
    ensure_dirs
    [ -s "$PKG_LIST" ] || return 0

    local missing=() pkg
    while read -r pkg; do
        [ -n "$pkg" ] || continue
        dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'ok installed' \
            || missing+=("$pkg")
    done < "$PKG_LIST"

    [ "${#missing[@]}" -gt 0 ] || { log "all recorded packages are already installed"; return 0; }

    log "reinstalling ${#missing[@]} package(s): ${missing[*]}"
    export DEBIAN_FRONTEND=noninteractive
    # The .deb cache and the package lists live in the volume, so this is
    # usually offline and fast. Refresh the lists only if it is not.
    if ! apt-get install -y --no-install-recommends "${missing[@]}"; then
        log "retrying after apt-get update"
        apt-get update || true
        if ! apt-get install -y --no-install-recommends "${missing[@]}"; then
            # One package that no longer exists would otherwise take the whole
            # list with it. Fall back to one at a time and report the losers.
            local failed=()
            for pkg in "${missing[@]}"; do
                apt-get install -y --no-install-recommends "$pkg" >/dev/null 2>&1 \
                    || failed+=("$pkg")
            done
            [ "${#failed[@]}" -eq 0 ] \
                || warn "could not reinstall: ${failed[*]} (agentbox-persist forget <pkg> to stop trying)"
        fi
    fi
}

# ---------------------------------------------------------------------------
# Housekeeping
# ---------------------------------------------------------------------------

cmd_status() {
    ensure_dirs 2>/dev/null || true
    local pkgs files size last
    pkgs="$(grep -c . "$PKG_LIST" 2>/dev/null)" || pkgs=0
    files="$(find "$OVERLAY" \( -type f -o -type l \) 2>/dev/null | wc -l)"
    size="$(du -sh "$OVERLAY" 2>/dev/null | cut -f1)"
    last="$(cat "$STATE_ROOT/.last-save" 2>/dev/null || echo never)"

    enabled || echo "persistence: OFF (AGENTBOX_PERSIST=0)"
    echo "state volume: $STATE_ROOT"
    echo "last save:    $last"
    echo "packages:     $pkgs"
    [ "$pkgs" = "0" ] || sed 's/^/  - /' "$PKG_LIST"
    echo "files:        $files (${size:-0})"
    echo "watching:     ${WATCHED[*]}"
}

cmd_forget() {
    need_root forget
    [ "$#" -gt 0 ] || { warn "usage: agentbox-persist forget <path|package>..."; return 1; }
    ensure_dirs
    local target
    for target in "$@"; do
        if [ -e "$OVERLAY/${target#/}" ]; then
            rm -rf "${OVERLAY:?}/${target#/}"
            log "forgot file $target (it stays until the next recreate)"
        elif grep -qxF "$target" "$PKG_LIST" 2>/dev/null; then
            grep -vxF "$target" "$PKG_LIST" > "$PKG_LIST.tmp" && mv "$PKG_LIST.tmp" "$PKG_LIST"
            log "forgot package $target (still installed; gone after a recreate)"
        else
            warn "not tracked: $target"
        fi
    done
}

cmd_reset() {
    need_root reset
    ensure_dirs
    rm -rf "${OVERLAY:?}"/* "${OVERLAY:?}"/.[!.]* 2>/dev/null
    : > "$PKG_LIST"
    rm -f "$STATE_ROOT/.last-save"
    log "state cleared — the next recreate boots the plain image"
}

# Periodic save, started by the entrypoint. Shutdown is not this loop's job:
# the entrypoint runs a final save itself, in a place where the container is
# guaranteed to still be alive.
cmd_watch() {
    need_root watch
    enabled || return 0
    local interval="${AGENTBOX_PERSIST_INTERVAL:-300}"
    [ "$interval" -gt 0 ] 2>/dev/null || return 0

    while true; do
        sleep "$interval"
        cmd_save >>"$LOG_DIR/persist.log" 2>&1
    done
}

usage() {
    cat <<'USAGE'
agentbox-persist — keep installs and edits across container recreates

  status              what is being kept right now
  save                capture changes made since the image was built
  restore             re-apply them on top of the image (runs at boot)
  replay-apt          reinstall the recorded packages (runs at boot)
  record-apt          refresh the package list (the dpkg hook calls this)
  forget <path|pkg>   stop keeping something
  reset               forget everything, back to a plain image
  watch               save periodically (the entrypoint runs this)
USAGE
}

case "${1:-status}" in
    status)     shift || true; cmd_status "$@" ;;
    save)       shift || true; cmd_save "$@" ;;
    restore)    shift || true; cmd_restore "$@" ;;
    replay-apt) shift || true; cmd_replay_apt "$@" ;;
    record-apt) shift || true; cmd_record_apt "$@" ;;
    forget)     shift || true; cmd_forget "$@" ;;
    reset)      shift || true; cmd_reset "$@" ;;
    watch)      shift || true; cmd_watch "$@" ;;
    -h|--help|help) usage ;;
    *) warn "unknown command: $1"; usage; exit 1 ;;
esac
