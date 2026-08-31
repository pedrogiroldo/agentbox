#!/usr/bin/env bash
# agentbox-dockerd — runs the box's own Docker daemon.
#
# The engine is not in the image: it is 192 MB that everyone pulling agentbox
# would pay for whether or not they want containers. Instead the box installs
# it on first boot, and agentbox-persist keeps it in the state volume like any
# other package you install — so it comes back on every boot after that, from
# the volume's own .deb cache, offline.
#
# The other half is that a daemon inside a container needs namespaces, and an
# ordinary container is not allowed to create any. That is checked *before*
# downloading anything, and said out loud, instead of leaving a dockerd
# crash-looping into a log nobody reads.
#
#   ensure  install the engine if it is missing, then start it (boot, in the
#           background — a first boot must not wait on a 192 MB download)
#   start   preflight, then launch dockerd and wait for it to answer
#   stop    ask it to shut down and give the containers time to stop
#   status  what the box is talking to, if anything
#
# AGENTBOX_DOCKER=install  install it when missing, then run it (default)
#                 =auto    run it only if something already installed it
#                 =on      like install, but any failure is fatal — for deploys
#                          where a box without Docker is not worth booting
#                 =off     never
set -uo pipefail

SOCKET=/var/run/docker.sock
PIDFILE=/run/agentbox-dockerd.pid
DATA_ROOT=/var/lib/docker
LOG_DIR="${AGENTBOX_PERSIST_DIR:-/var/lib/agentbox}/log"
LOG="$LOG_DIR/dockerd.log"
MODE="${AGENTBOX_DOCKER:-install}"
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
    has_sys_admin || give_up "this container may not create namespaces (no CAP_SYS_ADMIN), so a
       docker daemon cannot run in it. Add 'privileged: true' to the agentbox
       service in docker-compose.yml and recreate the container — a restart
       will not do, capabilities are fixed when a container is created. Read
       docs/security.md first: privileged is root-equivalent on the host."

    # Under an unprivileged container this is read-only, and containerd fails
    # the moment it tries to place a container in a cgroup.
    if [ ! -w /sys/fs/cgroup ]; then
        give_up "/sys/fs/cgroup is read-only, so the daemon could not limit or even
       place a container. This is the same missing 'privileged: true'."
    fi
}

# /var/lib/docker on the container's own overlayfs means overlay cannot stack
# there. Docker 29 defaults to the containerd snapshotter, which does *not*
# fall back on its own -- it takes the image fine and then dies on every
# `docker run` with
#
#     failed to mount ... fstype: overlay ... err: invalid argument
#
# so the fallback has to be asked for: the older graphdriver, with vfs. That
# works, and it copies every layer in full -- gigabytes and minutes for what
# should be seconds. Mounting a volume is the actual fix, and this says so.
# Prints the extra dockerd arguments, if any.
storage_args() {
    local fstype
    fstype="$(stat -f -c %T "$DATA_ROOT" 2>/dev/null)" || return 0
    [ "$fstype" = "overlayfs" ] || return 0

    warn "$DATA_ROOT is on the container filesystem, where overlay cannot stack.
       Falling back to the vfs storage driver: it works, but every image layer
       is copied in full and nothing survives a recreate. Mount a volume there
       — 'agentbox-docker:/var/lib/docker' in docker-compose.yml."
    printf '%s' "--feature containerd-snapshotter=false --storage-driver=vfs"
}

# Only ever runs on a box that does not have the engine yet: after this, the
# dpkg hook has recorded both packages and agentbox-persist replays them from
# the state volume's .deb cache on every later boot, without the network.
install_engine() {
    if [ ! -f /etc/apt/sources.list.d/docker.list ]; then
        give_up "the docker apt repository is not configured in this image, so the
       engine cannot be installed. Rebuild with INSTALL_DOCKER_CLI=true."
    fi

    log "installing the docker engine (~192 MB) — first boot only, the state"
    log "volume keeps it from here on"

    if ! DEBIAN_FRONTEND=noninteractive apt-get update -qq >>"$LOG" 2>&1 \
       || ! DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
              --no-install-recommends docker-ce containerd.io >>"$LOG" 2>&1; then
        give_up "could not install the docker engine. Last lines of $LOG:
$(tail -n 15 "$LOG" 2>/dev/null | sed 's/^/       /')"
    fi

    # Write it into the state volume now rather than waiting for the periodic
    # save: a box stopped in its first five minutes would install it twice.
    if [ "${AGENTBOX_PERSIST:-1}" != "0" ]; then
        agentbox-persist save >/dev/null 2>&1 \
            || warn "the engine is installed but was not recorded for the next boot"
    fi
}

# Boot path: everything start() does, plus the install when it is missing.
ensure() {
    [ "$MODE" != "off" ] || { log "AGENTBOX_DOCKER=off — not starting a daemon"; exit 0; }
    running && exit 0
    [ ! -S "$SOCKET" ] || exit 0   # the host lent us one; start() explains

    if ! installed; then
        case "$MODE" in
            install|on)
                install -d -m 0755 "$LOG_DIR"
                preflight          # before the download, not after
                install_engine ;;
            *)
                log "no docker engine installed (AGENTBOX_DOCKER=$MODE)"
                exit 0 ;;
        esac
    fi
    start
}

start() {
    [ "$MODE" != "off" ] || { log "AGENTBOX_DOCKER=off — not starting a daemon"; exit 0; }

    # Nothing to start yet, and nothing to complain about: on a box that has
    # not installed the engine, `ensure` is the one that gets to have opinions.
    installed || exit 0

    running && { log "the daemon is already running"; exit 0; }

    # A bind-mounted host socket wins: it is what the user mounted, it already
    # answers on the path our daemon would claim, and running both would leave
    # `docker ps` meaning two different things depending on the day.
    if [ -S "$SOCKET" ]; then
        log "a docker socket is already mounted here — using it instead of starting a daemon"
        exit 0
    fi

    preflight

    install -d -m 0755 "$LOG_DIR"
    # Word-split on purpose: storage_args prints zero or two flags.
    read -r -a extra_args <<< "$(storage_args)"
    log "starting the docker daemon (log: $LOG)"

    dockerd "${extra_args[@]}" >>"$LOG" 2>&1 &
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
        echo "no docker engine here yet (AGENTBOX_DOCKER=$MODE), and no socket mounted"
        echo "  the first boot installs it in the background — check $LOG"
        return 1
    fi
    docker version --format '  client {{.Client.Version}}  server {{.Server.Version}}' 2>/dev/null || true
}

case "${1:-status}" in
    ensure) ensure ;;
    start)  start ;;
    stop)   stop ;;
    status) status ;;
    *) echo "usage: agentbox-dockerd {ensure|start|stop|status}" >&2; exit 2 ;;
esac
