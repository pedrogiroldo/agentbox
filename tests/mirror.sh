#!/usr/bin/env bash
# Does the box tell you the truth about mirroring?
#
# Nothing here runs Mutagen: Mutagen is a client-side tool and the box only
# ever prints the command that drives it. So what is actually testable from
# here is everything up to the paste —
#
#   1. the endpoint reaches an SSH session, not just the container environment
#   2. the printed command carries the right endpoint, name and ignores, and
#      does not quietly drop .git on the floor
#   3. `check` passes on a healthy box and fails when sftp is gone
#   4. a box with no AGENTBOX_SSH_HOST still prints something useful
#   5. a project that does not exist is an error, not an empty command
#
#     make build && tests/mirror.sh agentbox:local
set -euo pipefail

IMAGE="${1:-agentbox:local}"
NAME="agentbox-mirrortest-$$"
HOME_VOL="$NAME-home"
STATE_VOL="$NAME-state"
TMP="$(mktemp -d)"

HOST=box.example.com
PORT=2200
ENDPOINT="dev@$HOST:$PORT:/home/dev/projects/demo"

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

# $@: extra docker run arguments (the environment under test).
boot() {
    docker run -d --name "$NAME" \
        -e SSH_PUBLIC_KEY="$PUBKEY" \
        -p 127.0.0.1::22 \
        -v "$HOME_VOL":/home/dev \
        -v "$STATE_VOL":/var/lib/agentbox \
        -e AGENTBOX_DOCKER=off \
        "$@" "$IMAGE" >/dev/null

    for _ in $(seq 90); do
        docker logs "$NAME" 2>&1 | grep -q "sshd is listening" && return 0
        docker inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null | grep -q false && return 1
        sleep 1
    done
    return 1
}

# As the login user: this command is never run as root in real life, and the
# endpoint it prints depends on who is asking.
mirror()  { docker exec -u dev "$NAME" agentbox-mirror "$@"; }
as_root() { docker exec "$NAME" bash -lc "$1"; }

# A real SSH session, because that is the environment that matters: sshd builds
# a fresh one and `docker exec` proves nothing about it.
over_ssh() {
    local port
    port="$(docker port "$NAME" 22/tcp | head -1 | sed 's/.*://')"
    ssh -q -i "$TMP/key" -p "$port" \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR -o ConnectTimeout=10 \
        dev@127.0.0.1 "$1"
}

# ---------------------------------------------------------------------------
step "a configured box: $HOST:$PORT"
# ---------------------------------------------------------------------------
if ! boot -e AGENTBOX_SSH_HOST="$HOST" -e AGENTBOX_SSH_PORT="$PORT"; then
    fail "the box did not boot"
    docker logs "$NAME" 2>&1 | tail -20
    exit 1
fi
pass "booted"

as_root 'install -d -o dev -g dev /home/dev/projects/demo'

docker exec -u dev "$NAME" bash -lc 'command -v agentbox-mirror >/dev/null' \
    && pass "agentbox-mirror is on dev's PATH" \
    || fail "agentbox-mirror is not on dev's PATH"

# The two variables have to survive sshd building a session from scratch --
# they are set on the container, and only the entrypoint's config.env carries
# them across.
ssh_env="$(over_ssh 'bash -lc "echo \"\$AGENTBOX_SSH_HOST|\$AGENTBOX_SSH_PORT\""' 2>/dev/null || true)"
if [ "$ssh_env" = "$HOST|$PORT" ]; then
    pass "a login shell over SSH reads back both variables"
else
    fail "a login shell over SSH saw '$ssh_env', not '$HOST|$PORT'"
fi

# The phone case: ask from anywhere for a command to paste on the laptop later.
# sshd runs this without a profile, so it is a genuinely different path.
if over_ssh 'agentbox-mirror demo' 2>/dev/null | grep -qF "$ENDPOINT"; then
    pass "'ssh box agentbox-mirror demo' prints the real endpoint"
else
    fail "a non-interactive ssh command lost the endpoint"
fi

step "the printed command"
out="$(mirror demo)"
printf '%s\n' "$out" | grep -q "mutagen sync create" \
    && pass "it is a mutagen sync create" || fail "no mutagen sync create in the output"
printf '%s\n' "$out" | grep -qF "$ENDPOINT" \
    && pass "endpoint: $ENDPOINT" || { fail "wrong endpoint"; printf '%s\n' "$out"; }
printf '%s\n' "$out" | grep -q -- "--name=agentbox-demo" \
    && pass "session name derived from the project" || fail "no agentbox-demo session name"

ignores="$(printf '%s\n' "$out" | grep -- '--ignore=')"
for pattern in 'build/' '\.gradle/' '\.cxx/' 'local\.properties' 'node_modules/'; do
    printf '%s\n' "$ignores" | grep -q -- "$pattern" \
        && pass "ignored: ${pattern//\\/}" || fail "not ignored: ${pattern//\\/}"
done

# The one thing that must cross: you are going to run git on the copy.
printf '%s\n' "$out" | grep -q -- '--ignore-vcs' \
    && fail "it passes --ignore-vcs, which would leave .git behind" \
    || pass "no --ignore-vcs"
printf '%s\n' "$ignores" | grep -qE "[=,']\.git[,']" \
    && fail ".git is in the ignore set" || pass ".git is not ignored"

# A local path the box invented would silently mirror into the wrong directory.
printf '%s\n' "$out" | grep -q 'path/to' \
    && pass "the local side is a placeholder" || fail "no local placeholder to replace"

step "a project that does not exist"
if err="$(mirror nosuchproject 2>&1)"; then
    fail "a missing project printed a command instead of failing"
else
    pass "exits non-zero"
    printf '%s\n' "$err" | grep -q '/home/dev/projects/nosuchproject' \
        && pass "it names the path it looked for" || fail "the error does not name the path"
    printf '%s\n' "$err" | grep -q 'mutagen sync create' \
        && fail "it printed a command anyway" || pass "and prints no command"
fi

step "no arguments at all"
if out="$(mirror)"; then
    pass "exits zero"
    printf '%s\n' "$out" | grep -q 'demo' \
        && pass "lists what can be mirrored" || fail "it does not list the projects"
else
    fail "the overview exited non-zero"
fi

step "the mutagen.yml"
yaml="$(mirror project demo)"
printf '%s\n' "$yaml" | grep -qF "beta: \"$ENDPOINT\"" \
    && pass "same endpoint as the printed command" || fail "the project file has a different endpoint"
printf '%s\n' "$yaml" | grep -q '"local.properties"' \
    && pass "same ignores" || fail "the project file has different ignores"
printf '%s\n' "$yaml" | grep -q 'vcs: false' \
    && pass "vcs ignores off here too" || fail "the project file would drop .git"
# Nothing but the file on stdout, or a redirect produces something Mutagen
# cannot read.
if docker exec -u dev "$NAME" bash -lc \
      'agentbox-mirror project demo | python3 -c "import sys,yaml; d=yaml.safe_load(sys.stdin); sys.exit(0 if \"agentbox-demo\" in d[\"sync\"] else 1)"' \
      2>/dev/null; then
    pass "parses as YAML with the session in it"
else
    if docker exec "$NAME" python3 -c 'import yaml' 2>/dev/null; then
        fail "the project file does not parse as the YAML Mutagen expects"
    else
        skip "no pyyaml in the box to parse it with"
    fi
fi

step "check, on a healthy box"
if out="$(mirror check)"; then
    pass "exits zero"
    printf '%s\n' "$out" | grep -qi 'sftp' && pass "reports the sftp subsystem" \
        || fail "says nothing about sftp"
    printf '%s\n' "$out" | grep -qF "$HOST" && pass "reports the endpoint" \
        || fail "says nothing about the endpoint"
else
    fail "check failed on a box where nothing is wrong"
    printf '%s\n' "$out"
fi

step "check, with the sftp subsystem taken away"
as_root "sed -i '/^Subsystem[[:space:]]*sftp/d' /etc/ssh/sshd_config"
if out="$(mirror check 2>&1)"; then
    fail "check still passed without an sftp subsystem"
else
    pass "exits non-zero"
    printf '%s\n' "$out" | grep -qi 'sftp' \
        && pass "and says it is the sftp subsystem" || fail "the reason is not in the output"
fi

# ---------------------------------------------------------------------------
step "a box with no AGENTBOX_SSH_HOST"
# ---------------------------------------------------------------------------
docker rm -f "$NAME" >/dev/null 2>&1 || true
docker volume rm "$HOME_VOL" "$STATE_VOL" >/dev/null 2>&1 || true
if boot; then
    pass "booted"

    # Before there is anything to mirror: a fresh box is the first place this
    # gets run, and an empty ~/projects is not an error.
    if out="$(mirror)"; then
        pass "the overview exits zero on a box with no projects"
    else
        fail "the overview failed on an empty ~/projects"
    fi

    as_root 'install -d -o dev -g dev /home/dev/projects/demo'

    out="$(mirror demo)"
    printf '%s\n' "$out" | grep -q '<your-server>' \
        && pass "the host is a visible placeholder" || fail "no placeholder in the endpoint"
    printf '%s\n' "$out" | grep -q 'AGENTBOX_SSH_HOST' \
        && pass "and it names the variable to set" || fail "it does not say how to fix it"
    # The shipped compose file publishes 2222; that is what a client dials.
    printf '%s\n' "$out" | grep -q ':2222:/home/dev/projects/demo' \
        && pass "the port falls back to 2222" || fail "wrong default port"

    if mirror demo >/dev/null; then
        pass "printing still exits zero"
    else
        fail "an unset host made the command fail"
    fi

    if out="$(mirror check)"; then
        pass "check still exits zero"
        printf '%s\n' "$out" | grep -qi 'warn' \
            && pass "with the host as a warning" || fail "the host is not reported as a warning"
    else
        fail "check failed over an unset host, which it cannot verify anyway"
        printf '%s\n' "$out"
    fi
else
    fail "a box with no AGENTBOX_SSH_HOST did not boot"
    docker logs "$NAME" 2>&1 | tail -20
fi

step "the login summary names it"
motd="$(docker exec "$NAME" cat /etc/motd)"
printf '%s\n' "$motd" | grep -q 'agentbox-mirror' \
    && pass "the motd names agentbox-mirror" || fail "nothing in the motd mentions mirroring"
printf '%s\n' "$motd" | grep 'agentbox-mirror' | awk '{ exit length > 70 }' \
    && pass "and that line fits the 70 columns the greeter asks for" \
    || fail "the agentbox-mirror line is wider than 70 columns and would wrap"

# The greeter shows the summary at 70x26 and nothing bigger has to fit, so the
# whole greeting -- wordmark included -- has to come in under 26 rows.
greeting="$(docker exec -e COLUMNS=70 -e LINES=26 -u dev "$NAME" \
            bash -lic 'true' 2>/dev/null | grep -c '' || true)"
if [ "${greeting:-0}" -gt 1 ]; then
    [ "$greeting" -le 26 ] \
        && pass "the whole 70x26 greeting is $greeting lines" \
        || fail "the greeting is $greeting lines and would scroll off a 26-row screen"
else
    skip "no greeting without a tty to measure it against"
fi

echo
if [ "$failures" -eq 0 ]; then
    printf '\033[32mall good\033[0m\n'
else
    printf '\033[31m%d check(s) failed\033[0m\n' "$failures"
    exit 1
fi
