#!/usr/bin/env bash
# Does the box actually remember what you install?
#
# Boots the image, installs a package and drops a couple of files outside the
# home, throws the container away, boots a new one on the same volumes, and
# checks that everything came back. Run it after a build:
#
#     make build && tests/persistence.sh agentbox:local
set -euo pipefail

IMAGE="${1:-agentbox:local}"
NAME="agentbox-test-$$"
HOME_VOL="$NAME-home"
STATE_VOL="$NAME-state"
TMP="$(mktemp -d)"

pass() { printf '  \033[32mok\033[0m   %s\n' "$*"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; failures=$((failures + 1)); }
step() { printf '\n\033[36m==>\033[0m %s\n' "$*"; }
failures=0

cleanup() {
    docker rm -f "$NAME" >/dev/null 2>&1 || true
    docker volume rm "$HOME_VOL" "$STATE_VOL" >/dev/null 2>&1 || true
    rm -rf "$TMP"
}
trap cleanup EXIT

ssh-keygen -q -t ed25519 -N '' -f "$TMP/key" -C test
PUBKEY="$(cat "$TMP/key.pub")"

# $1: seconds between automatic saves. 0 (the default here) keeps the test
# deterministic; the shutdown case below wants the saver running.
boot() {
    docker run -d --name "$NAME" \
        -e SSH_PUBLIC_KEY="$PUBKEY" \
        -e AGENTBOX_PERSIST_INTERVAL="${1:-0}" \
        -v "$HOME_VOL":/home/dev \
        -v "$STATE_VOL":/var/lib/agentbox \
        "$IMAGE" >/dev/null

    for _ in $(seq 60); do
        if docker logs "$NAME" 2>&1 | grep -q "sshd is listening"; then return 0; fi
        sleep 1
    done
    echo "container did not become ready:"; docker logs "$NAME" 2>&1 | tail -20
    return 1
}

in_box() { docker exec "$NAME" bash -lc "$1"; }

step "first boot ($IMAGE)"
boot
pass "booted"

step "installing things the way you would"
in_box 'apt-get update -qq && apt-get install -y -qq whois' >/dev/null
in_box 'printf "#!/bin/sh\necho hello\n" > /usr/local/bin/hello && chmod +x /usr/local/bin/hello'
in_box 'echo "answer = 42" > /etc/agentbox-test.conf'
in_box 'agentbox-persist save' >/dev/null
in_box 'agentbox-persist status'

step "throwing the container away, keeping the volumes"
docker rm -f "$NAME" >/dev/null
boot
pass "second boot"

step "checking what came back"
in_box 'test -x /usr/local/bin/hello' && pass "/usr/local/bin/hello" || fail "/usr/local/bin/hello is gone"
in_box 'grep -q "answer = 42" /etc/agentbox-test.conf' && pass "/etc/agentbox-test.conf" || fail "/etc file is gone"

# The package replay runs in the background, after sshd is up.
for _ in $(seq 90); do
    in_box 'dpkg-query -W -f="\${Status}" whois 2>/dev/null | grep -q "ok installed"' && break
    sleep 1
done
in_box 'command -v whois >/dev/null' && pass "apt package 'whois' reinstalled" || {
    fail "apt package 'whois' did not come back"
    docker exec "$NAME" cat /var/lib/agentbox/log/replay.log 2>/dev/null | tail -20
}

# Volatile files must NOT be dragged along from the previous container.
in_box 'test "$(cat /etc/hostname)" = "$(hostname)"' \
    && pass "/etc/hostname belongs to the new container" \
    || fail "/etc/hostname was restored from the old container"

# The terminfo fix, while we have a box running.
in_box 'infocmp -1 xterm-kitty >/dev/null 2>&1' && pass "xterm-kitty terminfo" || fail "xterm-kitty terminfo missing"

step "a graceful stop saves without being asked"
docker rm -f "$NAME" >/dev/null
boot 300
in_box 'printf "#!/bin/sh\necho bye\n" > /usr/local/bin/bye && chmod +x /usr/local/bin/bye'
docker stop "$NAME" >/dev/null          # SIGTERM -> tini -g -> the saver's trap
docker rm -f "$NAME" >/dev/null
boot 300
in_box 'test -x /usr/local/bin/bye' && pass "shutdown save" || {
    fail "a graceful stop did not save"
    docker logs "$NAME" 2>&1 | grep -i persist | tail -5
}

step "fresh start forgets everything"
in_box 'agentbox-persist reset' >/dev/null
docker rm -f "$NAME" >/dev/null
boot
in_box 'test ! -e /usr/local/bin/hello' && pass "reset dropped the file" || fail "reset kept the file"

echo
if [ "$failures" -eq 0 ]; then
    printf '\033[32mall good\033[0m\n'
else
    printf '\033[31m%d check(s) failed\033[0m\n' "$failures"
    exit 1
fi
