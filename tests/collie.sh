#!/usr/bin/env bash
# Does the box ship Collie without running it — and does it tell the truth
# about which of those two it is doing?
#
# Collie is the one thing in this image that is deliberately installed and
# deliberately dead. Almost every question here is about that gap:
#
#   1. the binary is there, linked, owned by the box's user so that it can
#      update itself in place, and writable by nobody else
#   2. the herdr server is up before anyone logs in, and off when asked
#   3. the plugin is linked into herdr -- which is also herdr enforcing
#      Collie's own min_herdr_version, so a herdr that fell below Collie's
#      floor fails here rather than on a phone
#   4. a default box is not listening, and says so as a decision rather than
#      as a failure
#   5. enabled with no tailnet, Collie refuses to start and names the missing
#      precondition, instead of listening where nothing can reach it
#   6. the tailnet client is installed, agentbox-tailscaled is honest about a
#      box that has joined nothing, `login` escalates and reaches a real login
#      URL, and TS_AUTHKEY is never written down
#   7. the push keypair is idempotent, lands in the home volume, and borrows
#      no address the box holds for another purpose
#   8. none of the variables that existed to reshape Collie for a network it
#      does not have are set anywhere
#
# What is NOT here: joining a real tailnet. That needs an account and a key.
# This suite checks everything up to the tailnet boundary; crossing it is done
# by hand.
#
#     make build && tests/collie.sh agentbox:local
set -euo pipefail

IMAGE="${1:-agentbox:local}"
NAME="agentbox-collietest-$$"
HOME_VOL="$NAME-home"
STATE_VOL="$NAME-state"
TMP="$(mktemp -d)"
PORT=8787

pass() { printf '  \033[32mok\033[0m   %s\n' "$*"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; failures=$((failures + 1)); }
skip() { printf '  \033[33mskip\033[0m %s\n' "$*"; }
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

# $@: extra docker run arguments (-e AGENTBOX_COLLIE=..., and friends).
boot() {
    docker rm -f "$NAME" >/dev/null 2>&1 || true
    docker run -d --name "$NAME" \
        -e SSH_PUBLIC_KEY="$PUBKEY" \
        -e AGENTBOX_DOCKER=off \
        -e GIT_USER_EMAIL=test@agentbox.invalid \
        -e AGENTBOX_COLLIE_PUSH=1 \
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

# ---------------------------------------------------------------------------
step "1. Collie is in the image, and is not the user's to rewrite"
# ---------------------------------------------------------------------------
boot || { echo "the box did not boot"; docker logs "$NAME" | tail -30; exit 1; }

if in_box 'command -v collie >/dev/null && collie version' >/dev/null 2>&1; then
    pass "collie is installed: $(in_box 'collie version' 2>/dev/null | head -1)"
else
    fail "collie is not on the PATH"
fi

if in_box 'test -e /opt/collie/current/herdr-plugin.toml'; then
    pass "the herdr plugin manifest is where the link expects it"
else
    fail "/opt/collie/current/herdr-plugin.toml is missing — the plugin link will fail"
fi

# The release tarball unpacks versions/ as 0777 and owned by uid 1001. The
# Dockerfile normalises that; this says it stayed normalised. Symlinks are
# always mode 777 and are not the question.
writable="$(in_box 'find /opt/collie ! -type l -perm /022 -print -quit' 2>/dev/null || true)"
if [ -z "$writable" ]; then
    pass "nothing under /opt/collie is group- or world-writable"
else
    fail "world- or group-writable under a system prefix: $writable"
fi

# `collie update` stages the next release beside the current one, as the user
# the bridge runs as. A tree that user cannot write makes every in-place update
# fail on its first mkdir, and the docs promise that path works.
foreign="$(as_dev 'find /opt/collie ! -type l ! -user "$(id -un)" -print -quit' 2>/dev/null || true)"
if [ -z "$foreign" ]; then
    pass "/opt/collie belongs to the user, so 'collie update' can write it"
else
    fail "not owned by the user, so an in-place update will hit EACCES: $foreign"
fi

# ---------------------------------------------------------------------------
step "2. The herdr server is up before anyone logs in"
# ---------------------------------------------------------------------------
if as_dev 'herdr status server' 2>/dev/null | grep -q '^status: running'; then
    pass "the herdr server is running on a box nobody has SSHed into"
else
    fail "no herdr server after boot — Collie would have nothing to mirror"
fi

# Single attempt, on purpose. This used to retry, to work around what looked
# like a loaded host -- it was actually `set -o pipefail` plus `grep -q` inside
# running(), reporting SIGPIPE as failure on a live server. With that fixed, a
# retry here would only hide the regression coming back.
herdr_status="$(in_box 'agentbox-herdr status' 2>&1 || true)"
if printf '%s' "$herdr_status" | grep -q 'server: running'; then
    pass "agentbox-herdr status agrees"
else
    fail "agentbox-herdr status disagrees with herdr itself: $(printf '%s' "$herdr_status" | head -2)"
fi

# The server spawns every pane, so its environment decides the shell. Started
# by root at boot there is no $SHELL to inherit, and herdr then falls back to
# /bin/sh -- a terminal that is not the user's, on a box that set bash for them.
# Read as the user: in an unprivileged container root has no CAP_SYS_PTRACE,
# and /proc/<pid>/environ of someone else's process is Permission denied.
server_shell="$(as_dev 'tr "\\0" "\\n" < /proc/$(pgrep -f "herdr server" | head -1)/environ | sed -n "s/^SHELL=//p"' 2>/dev/null || true)"
user_shell="$(in_box 'getent passwd dev | cut -d: -f7' 2>/dev/null || true)"
if [ -n "$server_shell" ] && [ "$server_shell" = "$user_shell" ]; then
    pass "the herdr server carries SHELL=$server_shell, so panes open the user's shell"
else
    fail "the herdr server has SHELL='${server_shell:-unset}' (user's is $user_shell) — panes will open /bin/sh"
    as_dev 'ps -o pid,ppid,lstart,args -C herdr; for p in $(pgrep -f "herdr server"); do echo "--- $p"; tr "\\0" "\\n" < /proc/$p/environ | cut -d= -f1 | tr "\\n" " "; echo; done' 2>&1 | sed 's/^/      /'
    docker logs "$NAME" 2>&1 | grep -i herdr | sed 's/^/      /'
fi

# ---------------------------------------------------------------------------
step "3. The plugin is linked into herdr — which enforces Collie's herdr floor"
# ---------------------------------------------------------------------------
if as_dev 'herdr plugin list' 2>/dev/null | grep -q 'herdr.collie'; then
    pass "collie is linked as a herdr plugin on a clean boot"
else
    fail "collie is not linked — either the link failed, or this herdr is below Collie's min_herdr_version"
fi

if as_dev 'herdr plugin action list' 2>/dev/null | grep -q '"plugin_id":"herdr.collie"'; then
    pass "its actions are listed"
else
    fail "the plugin is linked but exposes no actions"
fi

# ---------------------------------------------------------------------------
step "4. A default box is installed and deliberately dead"
# ---------------------------------------------------------------------------
status="$(in_box 'agentbox-collie status' 2>&1 || true)"
if printf '%s' "$status" | grep -q 'not running'; then
    pass "status says it is not running"
else
    fail "status on a default box should say not running: $status"
fi

if printf '%s' "$status" | grep -q 'AGENTBOX_COLLIE'; then
    pass "and names the variable that would start it"
else
    fail "status does not tell the reader which variable to set: $status"
fi

if in_box "curl -s --max-time 3 -o /dev/null http://127.0.0.1:$PORT/" 2>/dev/null; then
    fail "something is listening on $PORT with AGENTBOX_COLLIE unset"
else
    pass "nothing is listening on $PORT"
fi

# ---------------------------------------------------------------------------
step "5. Enabled with no front door, it refuses — and says which one is missing"
# ---------------------------------------------------------------------------
# AGENTBOX_TAILSCALE is unset here, so this box has joined nothing. Collie must
# not come up listening on a loopback that nothing on earth can reach.
boot -e AGENTBOX_COLLIE=auto \
    || { echo "the box did not boot with collie enabled"; docker logs "$NAME" | tail -30; exit 1; }

# `ensure` runs in the boot's background chain, so it lands *after* sshd is
# listening -- which is the point of putting it there. Wait for its verdict
# rather than for a fixed number of seconds.
said=0
for _ in $(seq 40); do
    docker logs "$NAME" 2>&1 | grep -q "has not joined a tailnet" && { said=1; break; }
    sleep 1
done

if in_box "curl -s --max-time 3 -o /dev/null http://127.0.0.1:$PORT/" 2>/dev/null; then
    fail "collie started on a box that has joined no tailnet"
else
    pass "collie did not start without a front door"
fi

if [ "$said" = 1 ]; then
    pass "and the boot log names the missing precondition"
else
    fail "the boot log never named the missing tailnet"
fi

start_out="$(in_box 'agentbox-collie start' 2>&1 || true)"
if printf '%s' "$start_out" | grep -q 'AGENTBOX_TAILSCALE'; then
    pass "a hand-run start names the variable that would fix it"
else
    fail "a hand-run start does not name AGENTBOX_TAILSCALE: $start_out"
fi

# ---------------------------------------------------------------------------
step "6. The tailnet client is there, and honest about having joined nothing"
# ---------------------------------------------------------------------------
if in_box 'tailscale version >/dev/null && tailscaled --version >/dev/null' 2>/dev/null; then
    pass "tailscale and tailscaled are installed"
else
    fail "the tailnet client is not in this image"
fi

ts="$(in_box 'agentbox-tailscaled status' 2>&1 || true)"
if printf '%s' "$ts" | grep -q 'not joined'; then
    pass "status says the box has joined nothing"
else
    fail "status on a box with no tailnet should say not joined: $ts"
fi

if printf '%s' "$ts" | grep -q 'AGENTBOX_TAILSCALE'; then
    pass "and names the variable that would change that"
else
    fail "status does not tell the reader which variable to set: $ts"
fi

# `joined` is the one question another service asks of it, and it must not
# answer yes merely because being off is a deliberate state.
if in_box 'agentbox-tailscaled joined' >/dev/null 2>&1; then
    fail "agentbox-tailscaled joined exits 0 on a box that has joined nothing"
else
    pass "agentbox-tailscaled joined is false when the box is not a member"
fi

# The login verb is the normal way in, so it has to be discoverable and it has
# to work as `dev`. Actually completing a login needs an account, so this only
# checks that it gets as far as printing a URL -- then gives up on it.
if in_box 'agentbox-tailscaled 2>&1 | grep -q login' \
   || in_box 'agentbox-tailscaled bogusverb 2>&1 | grep -q "login|ensure"'; then
    pass "the login verb is in the usage line"
else
    fail "agentbox-tailscaled does not advertise a login verb"
fi

login_out="$(as_dev 'timeout 25 agentbox-tailscaled login 2>&1' || true)"
if printf '%s' "$login_out" | grep -q 'sudo'; then
    pass "login run as dev says it is escalating"
else
    fail "login as dev did not mention re-running under sudo: $(printf '%s' "$login_out" | head -3)"
fi
if printf '%s' "$login_out" | grep -qE 'https://login\.tailscale\.com|To (authenticate|approve)'; then
    pass "and got as far as a login URL"
else
    fail "login never reached a URL: $(printf '%s' "$login_out" | tail -5)"
fi

# The motd is where an operator finds this without reading any docs.
if in_box 'grep -q "agentbox-tailscaled login" /etc/motd'; then
    pass "the login command is named in the motd"
else
    fail "the motd does not name the login command"
fi

# The auth key is a credential; the box must not write it down.
boot -e AGENTBOX_TAILSCALE=off -e TS_AUTHKEY="tskey-auth-notarealkey-000" \
    || { echo "the box did not boot with a key set"; exit 1; }
if in_box 'grep -rq "tskey-auth-notarealkey" /etc/agentbox/ /var/lib/agentbox/ 2>/dev/null'; then
    fail "TS_AUTHKEY was written into the box's config or persisted state"
else
    pass "TS_AUTHKEY is not written into config.env or the state volume"
fi

# ---------------------------------------------------------------------------
step "7. Push notifications come armed, and stay that way"
# ---------------------------------------------------------------------------
# Generating the keypair happens inside `agentbox-collie start`, which needs a
# tailnet this suite does not have. What is checkable here is the contract the
# generation relies on: that the command is idempotent, that the keys land in
# the home volume, and that the box never invents a contact address.
as_dev 'collie push-keys' >/dev/null 2>&1 || true
keyfile=/home/dev/.config/herdr/plugins/config/herdr.collie/.env
if in_box "grep -q COLLIE_VAPID_PRIVATE $keyfile" 2>/dev/null; then
    pass "push keys are written into the home volume"
else
    fail "push keys did not land in $keyfile"
fi

before="$(in_box "grep COLLIE_VAPID_PUBLIC $keyfile" 2>/dev/null || true)"
as_dev 'collie push-keys' >/dev/null 2>&1 || true
after="$(in_box "grep COLLIE_VAPID_PUBLIC $keyfile" 2>/dev/null || true)"
if [ -n "$before" ] && [ "$before" = "$after" ]; then
    pass "running it again leaves the keypair untouched"
else
    fail "the keypair changed on a second run — every subscribed device would go silent"
fi

# The contact is handed to Mozilla's and Google's push services. It must come
# from COLLIE_PUSH_SUBJECT or not at all -- never from an address the box holds
# for some other reason.
if in_box "grep -q 'test@agentbox.invalid' $keyfile" 2>/dev/null; then
    fail "an address the box holds for another purpose was used as the push contact"
else
    pass "no borrowed address ended up as the push contact"
fi

# The entrypoint publishes a variable only when it is actually set -- an unset
# one keeps the default the script itself carries. So this boots with it set,
# which is what makes it a test of the publishing path rather than of a default.
if in_box 'grep -q AGENTBOX_COLLIE_PUSH /etc/agentbox/config.env' 2>/dev/null; then
    pass "AGENTBOX_COLLIE_PUSH reaches interactive shells when set"
else
    fail "AGENTBOX_COLLIE_PUSH was set on the container but is not in config.env"
fi

# ---------------------------------------------------------------------------
step "8. Liveness checks survive their own plumbing"
# ---------------------------------------------------------------------------
# `set -o pipefail` plus `grep -q` reports SIGPIPE as failure on a command that
# was still writing, so running() said "no" about a live server roughly one
# time in six. Ten runs is enough to catch it coming back; one is not.
flapped=0
for _ in $(seq 10); do
    in_box 'agentbox-herdr status' 2>/dev/null | grep -q 'server: running' || flapped=1
done
if [ "$flapped" = 0 ]; then
    pass "agentbox-herdr status is stable over ten consecutive calls"
else
    fail "agentbox-herdr status flapped — check for a pipefail/grep -q pipeline in running()"
fi

# Comment lines excluded: the comments in those scripts explain this very bug,
# so a naive search for the string matches the explanation of why it is gone.
if in_box "grep -qE '^[^#]*\| *grep -q' /usr/local/bin/agentbox-herdr /usr/local/bin/agentbox-collie" 2>/dev/null; then
    fail "a grep -q pipeline is back in one of the supervisors"
else
    pass "no grep -q pipeline in either supervisor"
fi

# ---------------------------------------------------------------------------
step "9. The box never buys itself an easier life"
# ---------------------------------------------------------------------------
# These six exist only to undo Collie defaults that are correct here. None of
# them may reappear in a shipped file.
undone=0
for var in COLLIE_HOST COLLIE_ALLOW_NON_LOOPBACK_BIND COLLIE_SKIP_SERVE \
           COLLIE_PUBLIC_HOSTS COLLIE_ALLOWED_ORIGINS COLLIE_ALLOW_ANY_HOST; do
    if in_box "grep -rqE '^[^#]*${var}=' /usr/local/bin/agentbox-collie /etc/agentbox/ 2>/dev/null"; then
        fail "$var is set in the box's own configuration"
        undone=1
    fi
done
[ "$undone" = 0 ] && pass "none of the six undone variables are set anywhere"

# ---------------------------------------------------------------------------
step "10. AGENTBOX_HERDR_SERVER=0 gives back today's behaviour"
# ---------------------------------------------------------------------------
boot -e AGENTBOX_HERDR_SERVER=0 \
    || { echo "the box did not boot with the herdr server disabled"; docker logs "$NAME" | tail -30; exit 1; }

server_status="$(as_dev 'herdr status server' 2>&1 || true)"
if printf '%s' "$server_status" | grep -q '^status: not running'; then
    pass "no herdr server when the operator says no"
else
    fail "the herdr server started despite AGENTBOX_HERDR_SERVER=0: $(printf '%s' "$server_status" | head -2)"
fi

# The home volume carries over between boots here, so a leftover socket file
# proves nothing — a running server would.
if in_box 'pgrep -u dev -f "herdr server" >/dev/null 2>&1'; then
    fail "a herdr server process is running anyway"
else
    pass "and no server process was started"
fi

printf '\n'
if [ "$failures" -eq 0 ]; then
    printf '\033[32mall collie checks passed\033[0m\n'
else
    printf '\033[31m%d check(s) failed\033[0m\n' "$failures"
    exit 1
fi
