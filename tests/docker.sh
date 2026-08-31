#!/usr/bin/env bash
# Does the box's own Docker daemon work — and does it fail honestly when it
# cannot?
#
# Three questions, in order of how much they need from the host:
#   1. a box with no engine still boots, and says so plainly
#   2. an engine that cannot run (unprivileged) does not take the boot down,
#      and AGENTBOX_DOCKER=on turns that into a refusal to boot
#   3. privileged, the daemon comes up and actually runs a container
#
# 2 and 3 are skipped when the image was built with INSTALL_DOCKER_ENGINE=false.
#
#     make build && tests/docker.sh agentbox:local
set -euo pipefail

IMAGE="${1:-agentbox:local}"
NAME="agentbox-dockertest-$$"
TMP="$(mktemp -d)"

pass() { printf '  \033[32mok\033[0m   %s\n' "$*"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; failures=$((failures + 1)); }
skip() { printf '  \033[33mskip\033[0m %s\n' "$*"; }
step() { printf '\n\033[36m==>\033[0m %s\n' "$*"; }
failures=0

cleanup() {
    docker rm -f "$NAME" >/dev/null 2>&1 || true
    rm -rf "$TMP"
}
trap cleanup EXIT

ssh-keygen -q -t ed25519 -N '' -f "$TMP/key" -C test
PUBKEY="$(cat "$TMP/key.pub")"

# $@: extra docker run arguments (--privileged, -e AGENTBOX_DOCKER=...).
boot() {
    docker run -d --name "$NAME" \
        -e SSH_PUBLIC_KEY="$PUBKEY" \
        -e AGENTBOX_PERSIST=0 \
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

engine_in_image() {
    docker run --rm --entrypoint sh "$IMAGE" -c 'command -v dockerd >/dev/null'
}

step "a box with the engine off still boots"
if boot -e AGENTBOX_DOCKER=off; then
    pass "booted with AGENTBOX_DOCKER=off"
    in_box 'agentbox-dockerd status' || true
else
    fail "AGENTBOX_DOCKER=off kept the box from booting"
    docker logs "$NAME" 2>&1 | tail -20
fi
reset_box

if ! engine_in_image; then
    step "the rest needs an image built with INSTALL_DOCKER_ENGINE=true"
    skip "no dockerd in $IMAGE — it was built with INSTALL_DOCKER_ENGINE=false"
    echo
    [ "$failures" -eq 0 ] && { printf '\033[32mall good (partial run)\033[0m\n'; exit 0; }
    printf '\033[31m%d check(s) failed\033[0m\n' "$failures"; exit 1
fi

# An engine that cannot create namespaces is the interesting failure: it is
# what every unprivileged host gives you, and the box has to survive it.
step "unprivileged: the daemon is refused, the box lives"
if boot; then
    pass "booted without privileges"
    docker logs "$NAME" 2>&1 | grep -qi 'CAP_SYS_ADMIN' \
        && pass "the log says why (missing CAP_SYS_ADMIN)" \
        || fail "the log does not explain the refusal"
    in_box 'test ! -S /var/run/docker.sock' \
        && pass "no half-started daemon left behind" \
        || fail "something is listening on the socket"
else
    fail "an unusable engine took the whole boot down"
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

step "privileged: the daemon runs, and so do containers"
if ! docker run --rm --privileged --entrypoint true "$IMAGE" 2>/dev/null; then
    skip "this host does not allow --privileged"
elif boot --privileged; then
    pass "booted privileged"
    in_box 'agentbox-dockerd status'
    in_box 'docker version --format "{{.Server.Version}}"' >/dev/null \
        && pass "the daemon answers" || fail "the daemon does not answer"
    # The whole point: a container, end to end, inside the box.
    if in_box 'docker run --rm hello-world' >/dev/null 2>&1; then
        pass "ran a container inside the box"
    else
        fail "the daemon is up but cannot run a container"
        in_box 'tail -20 /var/lib/agentbox/log/dockerd.log' || true
    fi
    in_box 'id dev | grep -q "(docker)"' \
        && pass "dev is in the docker group" \
        || fail "dev cannot reach the socket without sudo"
else
    fail "privileged boot failed"
    docker logs "$NAME" 2>&1 | tail -20
fi

echo
if [ "$failures" -eq 0 ]; then
    printf '\033[32mall good\033[0m\n'
else
    printf '\033[31m%d check(s) failed\033[0m\n' "$failures"
    exit 1
fi
