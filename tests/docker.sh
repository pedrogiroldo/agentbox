#!/usr/bin/env bash
# Does the box get a working Docker daemon — and does it fail honestly when it
# cannot?
#
# The engine is not in the image: the box installs it on the first boot and
# agentbox-persist keeps it in the state volume. So the questions are
#
#   1. a box told not to have Docker still boots, and downloads nothing
#   2. an engine that could not run is not downloaded at all, and its absence
#      does not take the boot down — while AGENTBOX_DOCKER=on turns that same
#      situation into a refusal to boot
#   3. privileged, the daemon installs, comes up, and runs a real container
#   4. a recreated box gets it back from the volume, without the network
#
# 3 and 4 need a host that allows --privileged, and 3 needs the network.
#
#     make build && tests/docker.sh agentbox:local
set -euo pipefail

IMAGE="${1:-agentbox:local}"
NAME="agentbox-dockertest-$$"
HOME_VOL="$NAME-home"
STATE_VOL="$NAME-state"
DOCKER_VOL="$NAME-docker"
TMP="$(mktemp -d)"

pass() { printf '  \033[32mok\033[0m   %s\n' "$*"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; failures=$((failures + 1)); }
skip() { printf '  \033[33mskip\033[0m %s\n' "$*"; }
step() { printf '\n\033[36m==>\033[0m %s\n' "$*"; }
failures=0

cleanup() {
    docker rm -f "$NAME" >/dev/null 2>&1 || true
    docker volume rm "$HOME_VOL" "$STATE_VOL" "$DOCKER_VOL" >/dev/null 2>&1 || true
    rm -rf "$TMP"
}
trap cleanup EXIT

ssh-keygen -q -t ed25519 -N '' -f "$TMP/key" -C test
PUBKEY="$(cat "$TMP/key.pub")"

# $@: extra docker run arguments (--privileged, -e AGENTBOX_DOCKER=...).
boot() {
    docker run -d --name "$NAME" \
        -e SSH_PUBLIC_KEY="$PUBKEY" \
        -v "$HOME_VOL":/home/dev \
        -v "$STATE_VOL":/var/lib/agentbox \
        -v "$DOCKER_VOL":/var/lib/docker \
        "$@" "$IMAGE" >/dev/null

    for _ in $(seq 90); do
        docker logs "$NAME" 2>&1 | grep -q "sshd is listening" && return 0
        docker inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null | grep -q false && return 1
        sleep 1
    done
    return 1
}

in_box() { docker exec "$NAME" bash -lc "$1"; }
reset_box() { docker rm -f "$NAME" >/dev/null 2>&1 || true; }

# The engine arrives in the background, after the apt replay: sshd being up is
# not the same thing as Docker being ready.
wait_for_docker() {
    for _ in $(seq "${1:-420}"); do
        in_box 'docker version >/dev/null 2>&1' && return 0
        docker inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null | grep -q false && return 1
        sleep 1
    done
    return 1
}

step "AGENTBOX_DOCKER=off: the box boots and stays out of it"
if boot -e AGENTBOX_DOCKER=off; then
    pass "booted"
    in_box 'test ! -x /usr/bin/dockerd' \
        && pass "downloaded nothing" || fail "it installed an engine it was told not to"
else
    fail "AGENTBOX_DOCKER=off kept the box from booting"
    docker logs "$NAME" 2>&1 | tail -20
fi
reset_box

# The interesting failure: no privileges is what every ordinary host gives you.
step "unprivileged: refused before the download, and the box lives"
if boot -e AGENTBOX_DOCKER=install; then
    pass "booted without privileges"
    docker logs "$NAME" 2>&1 | grep -qi 'CAP_SYS_ADMIN' \
        && pass "the log says why (missing CAP_SYS_ADMIN)" \
        || fail "the log does not explain the refusal"
    # Checking capabilities before apt is the whole point: 192 MB for a daemon
    # that could never have run is a bad way to spend someone's first boot.
    sleep 20
    in_box 'test ! -x /usr/bin/dockerd' \
        && pass "did not download an engine it cannot run" \
        || fail "it downloaded the engine anyway"
    in_box 'test ! -S /var/run/docker.sock' \
        && pass "no half-started daemon left behind" \
        || fail "something is listening on the socket"
else
    fail "an engine it could not run took the whole boot down"
    docker logs "$NAME" 2>&1 | tail -20
fi
reset_box

step "unprivileged + AGENTBOX_DOCKER=on: refuse to boot"
if boot -e AGENTBOX_DOCKER=on; then
    fail "AGENTBOX_DOCKER=on booted anyway, without a daemon"
else
    docker logs "$NAME" 2>&1 | grep -qi 'fatal' \
        && pass "refused, with a fatal in the log" \
        || fail "it died, but not with the message we promise"
fi
reset_box

if ! docker run --rm --privileged --entrypoint true "$IMAGE" 2>/dev/null; then
    step "the rest needs a host that allows --privileged"
    skip "this one does not"
    echo
    [ "$failures" -eq 0 ] && { printf '\033[32mall good (partial run)\033[0m\n'; exit 0; }
    printf '\033[31m%d check(s) failed\033[0m\n' "$failures"; exit 1
fi

step "privileged: the engine installs itself and runs a container"
if boot --privileged -e AGENTBOX_DOCKER=install; then
    pass "booted privileged"
    if wait_for_docker; then
        pass "the daemon answers"
        in_box 'agentbox-dockerd status'
        in_box 'docker run --rm hello-world' >/dev/null 2>&1 \
            && pass "ran a container inside the box" \
            || fail "the daemon is up but cannot run a container"
        # Without sudo: the image puts dev in the docker group up front, so a
        # daemon appearing mid-session does not need a second login.
        docker exec -u dev "$NAME" docker ps >/dev/null 2>&1 \
            && pass "dev reaches the socket without sudo" \
            || fail "dev needs sudo to talk to the daemon"
        in_box 'agentbox-persist status | grep -q docker-ce' \
            && pass "the engine is recorded for the next boot" \
            || fail "nothing was recorded — a recreate would download it again"
    else
        fail "the daemon never came up"
        in_box 'tail -25 /var/lib/agentbox/log/dockerd.log' || true
    fi
else
    fail "privileged boot failed"
    docker logs "$NAME" 2>&1 | tail -20
fi

# The claim that justifies keeping the engine out of the image: it comes back
# from the volume, so only the very first boot of a box ever downloads it.
step "recreated on the same volumes: it comes back offline"
reset_box
if boot --privileged -e AGENTBOX_DOCKER=auto; then   # auto: never installs
    if wait_for_docker; then
        pass "docker is back without installing anything"
        in_box 'docker run --rm hello-world' >/dev/null 2>&1 \
            && pass "and still runs containers" \
            || fail "the daemon is up but containers do not run"
    else
        fail "the engine did not survive the recreate"
        in_box 'tail -25 /var/lib/agentbox/log/replay.log' || true
    fi
else
    fail "the recreated box did not boot"
    docker logs "$NAME" 2>&1 | tail -20
fi

echo
if [ "$failures" -eq 0 ]; then
    printf '\033[32mall good\033[0m\n'
else
    printf '\033[31m%d check(s) failed\033[0m\n' "$failures"
    exit 1
fi
