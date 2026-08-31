#!/usr/bin/env bash
# agentbox entrypoint — runs as root, ends with `exec sshd -D -e`.
#
# Order matters: everything a login depends on (home, host keys, authorized
# keys) happens before sshd starts. Anything slow (your provision script) runs
# in the background so you can log in while it works.
set -euo pipefail

USER_NAME="${AGENTBOX_USER:-dev}"
SKEL_DIR="/opt/agentbox/skel"

c_info=$'\033[36m'; c_warn=$'\033[33m'; c_err=$'\033[31m'; c_off=$'\033[0m'
log()  { printf '%s[agentbox]%s %s\n' "$c_info" "$c_off" "$*"; }
warn() { printf '%s[agentbox]%s %s\n' "$c_warn" "$c_off" "$*"; }
die()  { printf '%s[agentbox] fatal:%s %s\n' "$c_err" "$c_off" "$*" >&2; exit 1; }

id "$USER_NAME" >/dev/null 2>&1 || die "user '$USER_NAME' does not exist in this image"

# ---------------------------------------------------------------------------
# 1. Match the host's uid/gid — only needed when the home is a bind mount
# ---------------------------------------------------------------------------
ids_changed=0
if [ -n "${PGID:-}" ] && [ "$PGID" != "$(id -g "$USER_NAME")" ]; then
    log "changing group id of $USER_NAME to $PGID"
    groupmod -o -g "$PGID" "$(id -gn "$USER_NAME")"
    ids_changed=1
fi
if [ -n "${PUID:-}" ] && [ "$PUID" != "$(id -u "$USER_NAME")" ]; then
    log "changing user id of $USER_NAME to $PUID"
    usermod -o -u "$PUID" "$USER_NAME"
    ids_changed=1
fi

HOME_DIR="$(getent passwd "$USER_NAME" | cut -d: -f6)"
STATE_DIR="$HOME_DIR/.agentbox"
USER_GROUP="$(id -gn "$USER_NAME")"
OWNER="${USER_NAME}:${USER_GROUP}"

# Run a command as the login user with a sane environment. `runuser` alone
# keeps root's HOME, which would scatter agent config into /root.
as_user() {
    runuser -u "$USER_NAME" -- env \
        HOME="$HOME_DIR" USER="$USER_NAME" LOGNAME="$USER_NAME" \
        PATH="$HOME_DIR/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
        "$@"
}

# The image ships sshd_config pointing at /home/dev; follow the real home.
# Only when it actually differs: an unconditional sed -i would touch the file
# on every boot, and agentbox-persist would then treat it as one of your edits.
if ! grep -q "^HostKey ${STATE_DIR}/" /etc/ssh/sshd_config; then
    sed -i "s#^HostKey /home/[^/]*/\.agentbox#HostKey ${STATE_DIR}#" /etc/ssh/sshd_config
fi

# ---------------------------------------------------------------------------
# 1b. Persistent system layer
#
# /home/dev is not the only thing you change: packages, /usr/local, /opt and
# /etc matter too. They are not volumes -- mounting over them would freeze the
# node, nvim, herdr and agents the image ships. Instead the state volume keeps
# the *delta* and we lay it back down here, before anything else reads /etc.
# See docs/persistence.md; `agentbox-persist status` shows what is kept.
# ---------------------------------------------------------------------------
PERSIST_DIR="${AGENTBOX_PERSIST_DIR:-/var/lib/agentbox}"
install -d -m 0755 "$PERSIST_DIR" "$PERSIST_DIR/overlay" "$PERSIST_DIR/log" \
    "$PERSIST_DIR/apt/archives/partial" "$PERSIST_DIR/apt/lists/partial"

if [ "${AGENTBOX_PERSIST:-1}" != "0" ]; then
    agentbox-persist restore || warn "could not restore the persistent layer"
else
    log "persistence is off (AGENTBOX_PERSIST=0): only /home/dev survives"
fi

# ---------------------------------------------------------------------------
# 2. Timezone
# ---------------------------------------------------------------------------
if [ -n "${TZ:-}" ] && [ -f "/usr/share/zoneinfo/$TZ" ]; then
    ln -snf "/usr/share/zoneinfo/$TZ" /etc/localtime
    echo "$TZ" > /etc/timezone
    log "timezone set to $TZ"
fi

# ---------------------------------------------------------------------------
# 2b. Publish the container's environment to interactive shells
#
# sshd does not pass the container's environment to a session — it builds a
# fresh one. So anything set in docker-compose.yml (LANG, TZ, AGENTBOX_BANNER)
# would be invisible over SSH. Write it where /etc/agentbox/env.sh can find it.
# `${VAR:-value}` form, so a client that forwards its own LANG still wins.
# ---------------------------------------------------------------------------
config_env=/etc/agentbox/config.env
: > "$config_env"
for var in LANG LC_ALL TZ AGENTBOX_BANNER AGENTBOX_BANNER_BY; do
    eval "value=\${$var:-}"
    [ -n "$value" ] || continue
    # Escape any embedded double quote; these values are short and tame.
    escaped=$(printf '%s' "$value" | sed 's/"/\\"/g')
    printf 'export %s="${%s:-%s}"\n' "$var" "$var" "$escaped" >> "$config_env"
done
chmod 0644 "$config_env"

# ---------------------------------------------------------------------------
# 3. Home volume: seed it from the image skel
#
# --ignore-existing means your edits always win; a newer image only adds files
# you do not have yet. AGENTBOX_RESEED=force restores the shipped versions.
# ---------------------------------------------------------------------------
install -d -o "$USER_NAME" -g "$USER_GROUP" -m 0755 "$HOME_DIR"

if [ "$ids_changed" = "1" ]; then
    log "re-owning $HOME_DIR (this can take a moment)"
    chown -R "$OWNER" "$HOME_DIR"
fi

if [ ! -e "$STATE_DIR/.seeded" ]; then
    log "first boot: seeding $HOME_DIR from the image"
    rsync -a --ignore-existing --chown="$OWNER" "$SKEL_DIR/" "$HOME_DIR/"
    install -d -o "$USER_NAME" -g "$USER_GROUP" -m 0700 "$STATE_DIR"
    date -Is > "$STATE_DIR/.seeded"
    chown "$OWNER" "$STATE_DIR/.seeded"
elif [ "${AGENTBOX_RESEED:-}" = "force" ]; then
    warn "AGENTBOX_RESEED=force: restoring the files shipped in the image"
    rsync -a --chown="$OWNER" "$SKEL_DIR/" "$HOME_DIR/"
else
    rsync -a --ignore-existing --chown="$OWNER" "$SKEL_DIR/" "$HOME_DIR/"
fi

install -d -o "$USER_NAME" -g "$USER_GROUP" -m 0700 \
    "$STATE_DIR" "$HOME_DIR/.ssh" "$HOME_DIR/.ssh/authorized_keys.d"

# Directories herdr and the agents expect to exist.
install -d -o "$USER_NAME" -g "$USER_GROUP" -m 0755 \
    "$HOME_DIR/.claude" "$HOME_DIR/.codex" "$HOME_DIR/.config/opencode" \
    "$HOME_DIR/.config/herdr" "$HOME_DIR/.local/bin" "$HOME_DIR/projects"

# ---------------------------------------------------------------------------
# 4. SSH host keys — persistent, so the fingerprint your phone trusted survives
#    a `docker compose down && up`
# ---------------------------------------------------------------------------
install -d -o root -g root -m 0700 "$STATE_DIR/ssh"
for type in ed25519 rsa; do
    key="$STATE_DIR/ssh/ssh_host_${type}_key"
    if [ ! -f "$key" ]; then
        log "generating persistent $type host key"
        ssh-keygen -q -t "$type" -N '' -C "agentbox" -f "$key"
    fi
    chown root:root "$key" "$key.pub"
    chmod 600 "$key"
    chmod 644 "$key.pub"
done

# ---------------------------------------------------------------------------
# 5. Authorized keys from the environment
#
# They go to .ssh/authorized_keys.d/agentbox, which agentbox rewrites on every
# boot. Keys you add to .ssh/authorized_keys by hand are never touched.
# ---------------------------------------------------------------------------
managed_keys="$HOME_DIR/.ssh/authorized_keys.d/agentbox"
manual_keys="$HOME_DIR/.ssh/authorized_keys"
: > "$managed_keys"
[ -f "$manual_keys" ] || : > "$manual_keys"

append_keys() {
    # Accepts real newlines and the literal "\n" that .env files often produce.
    printf '%s\n' "$1" | sed 's/\\n/\n/g' | grep -E '^(ssh-|ecdsa-|sk-)' >> "$managed_keys" || true
}

if [ -n "${SSH_PUBLIC_KEY:-}" ]; then append_keys "$SSH_PUBLIC_KEY"; fi
if [ -n "${SSH_PUBLIC_KEYS:-}" ]; then append_keys "$SSH_PUBLIC_KEYS"; fi
if [ -n "${SSH_PUBLIC_KEY_FILE:-}" ] && [ -f "${SSH_PUBLIC_KEY_FILE}" ]; then
    append_keys "$(cat "$SSH_PUBLIC_KEY_FILE")"
fi
# Convention: bind-mount your public key(s) here instead of using the env.
if [ -f /etc/agentbox/authorized_keys ]; then
    append_keys "$(cat /etc/agentbox/authorized_keys)"
fi

chown -R "$OWNER" "$HOME_DIR/.ssh"
chmod 700 "$HOME_DIR/.ssh" "$HOME_DIR/.ssh/authorized_keys.d"
chmod 600 "$managed_keys" "$manual_keys"

key_count=$(cat "$managed_keys" "$manual_keys" | grep -cE '^(ssh-|ecdsa-|sk-)' || true)

# ---------------------------------------------------------------------------
# 6. Optional password login (off unless you ask for it)
# ---------------------------------------------------------------------------
rm -f /etc/agentbox/sshd.d/10-password.conf
if [ -n "${AGENTBOX_PASSWORD:-}" ]; then
    warn "password authentication is ENABLED — prefer SSH keys on a public port"
    echo "${USER_NAME}:${AGENTBOX_PASSWORD}" | chpasswd
    printf 'PasswordAuthentication yes\nKbdInteractiveAuthentication yes\n' \
        > /etc/agentbox/sshd.d/10-password.conf
elif [ "$key_count" -eq 0 ]; then
    die "no SSH public key and no password configured — nobody could log in.
       Set SSH_PUBLIC_KEY (see .env.example), bind-mount your key at
       /etc/agentbox/authorized_keys, or set AGENTBOX_PASSWORD.
       'make key' prints the public key of this machine."
fi
log "$key_count authorized key(s) installed"

# ---------------------------------------------------------------------------
# 7. Git identity
# ---------------------------------------------------------------------------
if [ -n "${GIT_USER_NAME:-}" ];  then as_user git config --global user.name  "$GIT_USER_NAME"; fi
if [ -n "${GIT_USER_EMAIL:-}" ]; then as_user git config --global user.email "$GIT_USER_EMAIL"; fi

# ---------------------------------------------------------------------------
# 8. Docker
#
# The box gets a daemon one of two ways: a socket bind-mounted from the host,
# or its own engine, which is not in the image -- it is installed on the first
# boot and then replayed from the state volume like any other package you
# install (see docs/docker.md). Both need a privileged container.
#
# Only the fast path is here: an engine that is already installed starts before
# sshd, so it is up by the time you log in. Installing it, and the apt replay
# that brings it back on a recreated box, are minutes of work -- those happen
# in the background chain further down, so a first boot is still a fast login.
# ---------------------------------------------------------------------------
if [ "${AGENTBOX_DOCKER:-install}" = "on" ]; then
    # This box is not worth booting without Docker, so it waits here for the
    # whole thing -- install included -- rather than letting you log into a box
    # that may or may not get a daemon a few minutes from now.
    agentbox-dockerd ensure \
        || die "AGENTBOX_DOCKER=on but docker is not available (reason above)"
elif ! agentbox-dockerd start; then
    warn "no docker in this box yet (reason above) — the rest of the boot continues"
fi

# A socket from the host is owned by a group that only exists out there; the
# image's own `docker` group already covers the daemon we start ourselves.
if [ -S /var/run/docker.sock ]; then
    sock_gid="$(stat -c %g /var/run/docker.sock)"
    if ! getent group "$sock_gid" >/dev/null; then
        groupadd -g "$sock_gid" dockerhost
    fi
    usermod -aG "$(getent group "$sock_gid" | cut -d: -f1)" "$USER_NAME"
    log "docker socket ready — $USER_NAME can use it"
fi

# ---------------------------------------------------------------------------
# 9. Herdr agent integrations: they report each agent's state to the pane, so
#    the sidebar shows which agent is working and which one is waiting on you.
# ---------------------------------------------------------------------------
if [ "${AGENTBOX_HERDR_INTEGRATIONS:-1}" = "1" ]; then
    for integration in claude codex opencode; do
        as_user herdr integration install "$integration" >/dev/null 2>&1 \
            || warn "could not install the herdr $integration integration"
    done
fi

# ---------------------------------------------------------------------------
# 10. Bring your world back: packages, Docker, then your provisioning script
#
# All of it in one background chain so they never fight over the dpkg lock, and
# in this order because a provision script usually assumes its packages exist —
# and `docker compose up` in one of them assumes a daemon.
# ---------------------------------------------------------------------------
provision="$STATE_DIR/provision.sh"

if [ -f "$provision" ]; then
    log "running $provision in the background (log: $STATE_DIR/provision.log)"
    touch "$STATE_DIR/provision.log"
    chown "$OWNER" "$STATE_DIR/provision.log"
fi

(
    if [ "${AGENTBOX_PERSIST:-1}" != "0" ]; then
        agentbox-persist replay-apt 2>&1 | tee -a "$PERSIST_DIR/log/replay.log"
    fi

    # After the replay, because on a recreated box that is what puts the engine
    # back. On a first boot there is nothing to replay and this installs it.
    # AGENTBOX_DOCKER=on already did all of it, in the foreground, above.
    if [ "${AGENTBOX_DOCKER:-install}" != "on" ]; then
        agentbox-dockerd ensure || warn "docker is not available in this box"
    fi

    if [ -f "$provision" ]; then
        {
            echo "=== $(date -Is) provision start ==="
            as_user bash "$provision" 2>&1 || echo "!!! provision exited with an error"
            echo "=== $(date -Is) provision finished ==="
        } | tee -a "$STATE_DIR/provision.log"
    fi
) &

# Keep capturing what you install from here on. The shutdown save is handled
# below, by this script, so this is only the periodic pass.
if [ "${AGENTBOX_PERSIST:-1}" != "0" ] && [ "${AGENTBOX_PERSIST_INTERVAL:-300}" != "0" ]; then
    agentbox-persist watch &
fi

# ---------------------------------------------------------------------------
# 11. Hand over to sshd
#
# Deliberately not `exec`: the box has one last job when it is told to stop --
# writing out what you installed since the last save. The container lives as
# long as this script does, so staying around as sshd's parent is what buys the
# time for it (stop_grace_period, 30s by default).
# ---------------------------------------------------------------------------
mkdir -p /run/sshd
/usr/sbin/sshd -t -f /etc/ssh/sshd_config || die "sshd configuration is invalid"
log "ready — sshd is listening on port 22 (log in as $USER_NAME)"

"$@" &
sshd_pid=$!

on_shutdown() {
    trap '' TERM INT
    kill -TERM "$sshd_pid" 2>/dev/null || true
    # Before the state save: containers are writing too, and a daemon killed
    # with the container is a daemon that never flushed them.
    agentbox-dockerd stop || warn "the docker daemon did not stop cleanly"
    if [ "${AGENTBOX_PERSIST:-1}" != "0" ]; then
        log "saving what changed since the last pass"
        agentbox-persist save || warn "the final save did not finish"
    fi
    wait "$sshd_pid" 2>/dev/null || true
    exit 0
}
trap on_shutdown TERM INT

wait "$sshd_pid" || sshd_status=$?
exit "${sshd_status:-0}"
