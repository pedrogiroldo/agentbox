#!/usr/bin/env bash
# agentbox-dockerd — runs the box's own Docker daemon, when the image was
# built with INSTALL_DOCKER_ENGINE=true.
#
# A daemon inside a container is not a matter of installing it: it needs
# namespaces, and an ordinary container is not allowed to create any. So this
# checks first and says exactly what is missing, instead of leaving a dockerd
# crash-looping into a log nobody reads.
#
#   start   preflight, then launch dockerd in the background and wait for it
#   stop    ask it to shut down and give the containers time to stop
#   status  what the box is talking to, if anything
#
# AGENTBOX_DOCKER=auto   start it if the engine is there and the box may (default)
#                 =on    same, but a failed preflight is fatal — for deploys
#                        where a box without Docker is not worth booting
#                 =off   never
set -uo pipefail

SOCKET=/var/run/docker.sock
PIDFILE=/run/agentbox-dockerd.pid
DATA_ROOT=/var/lib/docker
LOG_DIR="${AGENTBOX_PERSIST_DIR:-/var/lib/agentbox}/log"
LOG="$LOG_DIR/dockerd.log"
MODE="${AGENTBOX_DOCKER:-auto}"
START_TIMEOUT="${AGENTBOX_DOCKER_TIMEOUT:-60}"
STOP_TIMEOUT="${AGENTBOX_DOCKER_STOP_TIMEOUT:-20}"

c_info=$'\033[36m'; c_warn=$'\033[33m'; c_off=$'\033[0m'
log()  { printf '%s[agentbox]%s %s\n' "$c_info" "$c_off" "$*"; }
warn() { printf '%s[agentbox]%s %s\n' "$c_warn" "$c_off" "$*" >&2; }

# Fatal only when the user asked for the daemon explicitly (AGENTBOX_DOCKER=on).
# In `auto` the box still boots — you get an SSH session and a clear reason.
give_up() {
    if [ "$MODE" = "on" ]; then
        printf '%s[agentbox] fatal:%s %s\n' $'\033[31m' "$c_off" "$1" >&2
        exit 1
    fi
    warn "$1"
    exit 0
}

installed() { command -v dockerd >/dev/null 2>&1; }

running() {
    [ -f "$PIDFILE" ] || return 1
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null)" || return 1
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

# CAP_SYS_ADMIN (capability 21) is the one that decides this. Without it the
# daemon cannot unshare a namespace, and every container it tries to start
# dies in the runtime. The host grants it with `privileged: true`.
has_sys_admin() {
    local eff
    eff="$(awk '/^CapEff:/ {print $2}' /proc/self/status)"
    [ -n "$eff" ] || return 1
    (( 0x$eff & (1 << 21) ))
}

preflight() {
    has_sys_admin || give_up "the engine is installed but this container may not create namespaces
       (no CAP_SYS_ADMIN). Add 'privileged: true' to the agentbox service in
       docker-compose.yml and recreate the container. Read docs/security.md
       first: privileged is root-equivalent access to the host."

    # Under an unprivileged container this is read-only, and containerd fails
    # the moment it tries to place a container in a cgroup.
    if [ ! -w /sys/fs/cgroup ]; then
        give_up "/sys/fs/cgroup is read-only, so the daemon could not limit or even
       place a container. This is the same missing 'privileged: true'."
    fi
}

# /var/lib/docker on the container's own overlayfs means overlay2 is out and
# the daemon silently falls back to vfs: every layer copied in full, gigabytes
# and minutes for what should be seconds. A named volume is a real filesystem.
check_storage() {
    local fstype
    fstype="$(stat -f -c %T "$DATA_ROOT" 2>/dev/null)" || return 0
    if [ "$fstype" = "overlayfs" ]; then
        warn "$DATA_ROOT sits on the container filesystem, so Docker will fall back
       to the vfs storage driver (slow, and it eats disk). Mount a volume there:
       'agentbox-docker:/var/lib/docker' in docker-compose.yml. Images also
       survive a recreate that way."
    fi
}

start() {
    [ "$MODE" != "off" ] || { log "AGENTBOX_DOCKER=off — not starting a daemon"; exit 0; }

    if ! installed; then
        [ "$MODE" != "on" ] || give_up "AGENTBOX_DOCKER=on but this image has no daemon. Rebuild with
       --build-arg INSTALL_DOCKER_ENGINE=true (or INSTALL_DOCKER_ENGINE=true in .env)."
        exit 0
    fi

    running && { log "the daemon is already running"; exit 0; }

    # A bind-mounted host socket wins: it is what the user mounted, it already
    # answers on the path our daemon would claim, and running both would leave
    # `docker ps` meaning two different things depending on the day.
    if [ -S "$SOCKET" ]; then
        log "a docker socket is already mounted here — using it instead of starting a daemon"
        exit 0
    fi

    preflight
    check_storage

    install -d -m 0755 "$LOG_DIR"
    log "starting the docker daemon (log: $LOG)"

    dockerd >>"$LOG" 2>&1 &
    echo $! > "$PIDFILE"

    local waited=0
    while [ "$waited" -lt "$START_TIMEOUT" ]; do
        if [ -S "$SOCKET" ] && docker version >/dev/null 2>&1; then
            log "docker is ready ($(docker version --format '{{.Server.Version}}' 2>/dev/null || echo 'server up'))"
            return 0
        fi
        running || break
        sleep 1
        waited=$((waited + 1))
    done

    rm -f "$PIDFILE"
    give_up "the docker daemon did not come up in ${START_TIMEOUT}s. Last lines of $LOG:
$(tail -n 15 "$LOG" 2>/dev/null | sed 's/^/       /')"
}

# Containers hold data too. Give the daemon its own window to stop them before
# the entrypoint's shutdown budget (stop_grace_period) runs out on all of us.
stop() {
    running || return 0
    local pid; pid="$(cat "$PIDFILE")"
    log "stopping the docker daemon"
    kill -TERM "$pid" 2>/dev/null || true

    local waited=0
    while [ "$waited" -lt "$STOP_TIMEOUT" ] && kill -0 "$pid" 2>/dev/null; do
        sleep 1
        waited=$((waited + 1))
    done

    if kill -0 "$pid" 2>/dev/null; then
        warn "the daemon did not stop in ${STOP_TIMEOUT}s — killing it"
        kill -KILL "$pid" 2>/dev/null || true
    fi
    rm -f "$PIDFILE"
}

status() {
    if running; then
        echo "own daemon: running (pid $(cat "$PIDFILE"), log $LOG)"
    elif [ -S "$SOCKET" ]; then
        echo "socket: $SOCKET (not started by this box — bind-mounted from the host)"
    elif [ -n "${DOCKER_HOST:-}" ]; then
        echo "remote: DOCKER_HOST=$DOCKER_HOST"
    elif installed; then
        echo "engine installed, not running (AGENTBOX_DOCKER=$MODE)"
    else
        echo "no docker: the image was built without the engine and no socket is mounted"
        return 1
    fi
    docker version --format '  client {{.Client.Version}}  server {{.Server.Version}}' 2>/dev/null || true
}

case "${1:-status}" in
    start)  start ;;
    stop)   stop ;;
    status) status ;;
    *) echo "usage: agentbox-dockerd {start|stop|status}" >&2; exit 2 ;;
esac
