#!/usr/bin/env bash
# Does agentbox-clean say before it does — and touch only what it said?
#
#   1. the report on a seeded home deletes nothing, and lists both the caches
#      and the things it will never touch
#   2. `caches` reduces the caches, leaves projects and browsers alone, and
#      keeps the plugin version that is installed
#   3. `browsers` is its own verb and names the reinstall
#   4. the login greeting mentions the command only above the threshold
#   5. nothing runs on a timer unless AGENTBOX_CLEAN_INTERVAL says so
#
#     make build && tests/clean.sh agentbox:local
set -euo pipefail

IMAGE="${1:-agentbox:local}"
NAME="agentbox-cleantest-$$"
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

boot() {
    docker rm -f "$NAME" >/dev/null 2>&1 || true
    docker run -d --name "$NAME" \
        -e SSH_PUBLIC_KEY="$PUBKEY" \
        -e AGENTBOX_DOCKER=off \
        -v "$HOME_VOL":/home/dev \
        -v "$STATE_VOL":/var/lib/agentbox \
        "$@" "$IMAGE" >/dev/null
    for _ in $(seq 90); do
        docker logs "$NAME" 2>&1 | grep -q "sshd is listening" && return 0
        docker inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null | grep -q false && return 1
        sleep 1
    done
    return 1
}

in_box()  { docker exec "$NAME" bash -lc "$1"; }
as_dev()  { docker exec -u dev "$NAME" bash -lc "$1"; }

seed() {
    as_dev '
        set -e
        mkdir -p ~/.npm/_cacache ~/.npm/_npx/old ~/.npm/_npx/new ~/.bun/install/cache \
                 ~/.cache/uv ~/.cache/ms-playwright/chromium ~/projects/repo \
                 ~/.claude/plugins/cache/mk/plug/1.0.0 ~/.claude/plugins/cache/mk/plug/2.0.0 \
                 ~/.local/share/Trash
        dd if=/dev/urandom of=~/.npm/_cacache/blob bs=1M count=5 status=none
        dd if=/dev/urandom of=~/.npm/_npx/old/blob bs=1M count=3 status=none
        touch -d "10 days ago" ~/.npm/_npx/old
        dd if=/dev/urandom of=~/.npm/_npx/new/blob bs=1M count=2 status=none
        dd if=/dev/urandom of=~/.cache/ms-playwright/chromium/bin bs=1M count=4 status=none
        dd if=/dev/urandom of=~/.claude/plugins/cache/mk/plug/1.0.0/big bs=1M count=6 status=none
        echo x > ~/.claude/plugins/cache/mk/plug/2.0.0/small
        echo "{\"plugins\":{\"plug@mk\":{\"version\":\"2.0.0\"}}}" > ~/.claude/plugins/installed_plugins.json
        dd if=/dev/urandom of=~/projects/repo/data bs=1M count=7 status=none
        touch ~/.claude.json.tmp.1 ~/.local/share/Trash/f
    '
}

step "1. the report deletes nothing"
boot || { echo "the box did not boot"; docker logs "$NAME" | tail -30; exit 1; }
seed
before="$(as_dev 'find ~ | wc -l')"
report="$(as_dev 'agentbox-clean' 2>&1 || true)"
after="$(as_dev 'find ~ | wc -l')"
[ "$before" = "$after" ] && pass "file count unchanged ($before)" || fail "the report changed the file count: $before -> $after"
printf '%s' "$report" | grep -q 'npm content store' && pass "lists the npm store" || fail "no npm store in the report"
printf '%s' "$report" | grep -q 'superseded plugin versions' && pass "lists superseded plugin versions" || fail "no plugin line in the report"
printf '%s' "$report" | grep -q 'never touched' && pass "has a section for what is yours" || fail "no 'yours' section"
printf '%s' "$report" | grep -q 'repositories' && pass "and names the repositories in it" || fail "repositories are not listed as yours"
printf '%s' "$report" | grep -q 'Playwright' && pass "browsers are listed under their own verb" || fail "no browsers in the report"

step "2. caches: reduces caches, leaves the rest"
out="$(as_dev 'agentbox-clean caches' 2>&1 || true)"
as_dev 'test ! -e ~/.npm/_npx/old' && pass "old npx entry removed" || fail "old npx entry survived"
as_dev 'test -e ~/.npm/_npx/new' && pass "recent npx entry kept" || fail "recent npx entry removed"
as_dev 'test ! -e ~/.claude/plugins/cache/mk/plug/1.0.0' && pass "superseded plugin version removed" || fail "superseded plugin version survived"
as_dev 'test -e ~/.claude/plugins/cache/mk/plug/2.0.0/small' && pass "installed plugin version kept" || fail "the installed plugin version was removed"
as_dev 'test ! -e ~/.claude.json.tmp.1' && pass "temp leftover removed" || fail "temp leftover survived"
as_dev 'test ! -e ~/.local/share/Trash/f' && pass "trash emptied" || fail "trash survived"
as_dev 'test -e ~/projects/repo/data' && pass "projects untouched" || fail "a project file is gone"
as_dev 'test -e ~/.cache/ms-playwright/chromium/bin' && pass "browsers untouched by caches" || fail "caches removed the browsers"
# npm's own verb is used when npm is there; in the image it is.
as_dev 'test ! -e ~/.npm/_cacache/blob' && pass "npm's store was cleaned by npm" || fail "npm content store survived: $(printf '%s' "$out" | grep npm)"
printf '%s' "$out" | grep -q '^freed' && pass "reports what it freed" || fail "no freed total: $out"

step "3. browsers: separate, and names the reinstall"
out="$(as_dev 'agentbox-clean browsers' 2>&1 || true)"
as_dev 'test ! -e ~/.cache/ms-playwright' && pass "browsers removed" || fail "browsers survived"
as_dev 'mkdir -p ~/.cache/ms-playwright/x && dd if=/dev/urandom of=~/.cache/ms-playwright/x/b bs=1M count=1 status=none'
# Captured, not piped into grep -q: under pipefail the report keeps writing
# after the match, takes SIGPIPE, and the pipeline reports a failure.
report="$(as_dev 'agentbox-clean' 2>&1 || true)"
printf '%s' "$report" | grep -q 'playwright install' && pass "the report names the reinstall command" || fail "no reinstall hint: $(printf '%s' "$report" | grep -i playwright)"

step "4. the greeting says so only above the threshold"
in_box "printf '%s %s\n' $((25 * 1048576)) $((9 * 1048576)) > /var/lib/agentbox/.disk && chmod 644 /var/lib/agentbox/.disk"
as_dev 'true' >/dev/null
greet="$(docker exec -u dev "$NAME" bash -lic 'true' 2>&1 || true)"
printf '%s' "$greet" | grep -q 'agentbox-clean' && pass "above 20G the greeting names agentbox-clean" || fail "no disk line above the threshold: $greet"
in_box "printf '%s %s\n' $((5 * 1048576)) $((1 * 1048576)) > /var/lib/agentbox/.disk"
greet="$(docker exec -u dev "$NAME" bash -lic 'true' 2>&1 || true)"
printf '%s' "$greet" | grep -q 'agentbox-clean' && fail "the greeting mentions cleaning on a small home" || pass "below the threshold it says nothing"
in_box "printf '%s %s\n' $((5 * 1048576)) $((3 * 1048576)) > /var/lib/agentbox/.disk"
greet="$(docker exec -u dev "$NAME" bash -lic 'true' 2>&1 || true)"
printf '%s' "$greet" | grep -q 'agentbox-clean' && pass "more than half cache also earns the line" || fail "half-cache home got no line: $greet"

step "5. the box cleans caches on its own only past the line"
# A fast measurement period so this does not take an hour; the seeded home is
# a few megabytes, far below the shipped 20G line.
boot -e AGENTBOX_CLEAN_CHECK=3 || { echo "the box did not boot"; exit 1; }
seed
sleep 12
as_dev 'test -e ~/.npm/_npx/old' && pass "under the line, nothing was cleaned" || fail "something cleaned a home that had room"
in_box 'test ! -e /var/lib/agentbox/log/clean.log' && pass "and no clean log exists" || fail "a clean log appeared under the line"
in_box 'test -s /var/lib/agentbox/.disk' && pass "but the figures for the greeting were written" || fail "the watcher wrote no figures"

# Over the line: a home of a few megabytes against a 1M threshold.
boot -e AGENTBOX_CLEAN_CHECK=3 -e AGENTBOX_CLEAN_AT=1M || { echo "the box did not boot over the line"; exit 1; }
seed
for _ in $(seq 40); do
    in_box 'test -e /var/lib/agentbox/log/clean.log' 2>/dev/null && break
    sleep 1
done
sleep 3
in_box 'test -e /var/lib/agentbox/log/clean.log' && pass "over the line, the caches tier ran and logged" || fail "no clean log over the line"
in_box 'grep -q "over 1 MB" /var/lib/agentbox/log/clean.log' && pass "and the log says why" || fail "the log does not name the trigger: $(in_box 'head -3 /var/lib/agentbox/log/clean.log')"
as_dev 'test ! -e ~/.npm/_npx/old' && pass "and it cleaned the caches" || fail "the watcher did not clean"
as_dev 'test -e ~/projects/repo/data' && pass "and only the caches" || fail "the watcher touched a project"
as_dev 'test -e ~/.cache/ms-playwright/chromium/bin' && pass "and never the browsers" || fail "the watcher removed the browsers"

# Turned off: the same full home, no triggers.
boot -e AGENTBOX_CLEAN_CHECK=3 -e AGENTBOX_CLEAN_AT=0 -e AGENTBOX_CLEAN_MIN_FREE=0 || { echo "the box did not boot with cleaning off"; exit 1; }
seed
sleep 12
as_dev 'test -e ~/.npm/_npx/old' && pass "with both triggers at 0, nothing is cleaned" || fail "cleaning ran with the triggers off"

echo
if [ "$failures" -eq 0 ]; then
    printf '\033[32mall clean checks passed\033[0m\n'
else
    printf '\033[31m%d check(s) failed\033[0m\n' "$failures"
    exit 1
fi
