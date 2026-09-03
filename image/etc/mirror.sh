#!/usr/bin/env bash
# agentbox-mirror — puts a project in this box onto your own machine, live.
#
# Port forwarding brings a server running in here out to your browser. It does
# nothing for the opposite problem: code that cannot *run* in here at all. An
# Android build needs the SDK, the emulator needs hardware acceleration and adb
# needs a USB cable, none of which a VPS has. What that needs is the same tree
# on both sides, and Mutagen already does that well over the SSH connection you
# already have.
#
# So this command does not mirror anything. It prints the command that does.
# Mutagen is a client-side tool: the daemon, the session list and the config
# all live on your laptop, and the box is only ever the far end of a session it
# does not own and cannot enumerate. A box-side `status` would be a lie. What
# the box *can* do is the part that is annoying to get right by hand — the URL
# syntax, the published port, an absolute remote path, and an ignore set that
# does not ship a 400 MB Gradle build directory down your uplink.
#
# Nothing is installed here for this. Mutagen copies its own agent binary in
# over SFTP on the first connection, into ~/.mutagen, which is already in the
# home volume — so it survives a recreate and the image stays the same size.
#
#   agentbox-mirror                what a mirror is for, and what you can mirror
#   agentbox-mirror <project>      the command to paste on your own machine
#   agentbox-mirror project <name> the same session as a mutagen.yml, on stdout
#   agentbox-mirror check          is this box actually ready to be mirrored
#
# AGENTBOX_SSH_HOST  what a client outside dials to reach this box. Unknowable
#                    from in here (the port mapping and any proxy are out
#                    there), so unset means a visible placeholder.
# AGENTBOX_SSH_PORT  the published port, not the container's 22 (default 2222).
set -uo pipefail

DOCS_URL="https://github.com/pedrogiroldo/agentbox/blob/main/docs/mirror.md"
HOST_PLACEHOLDER="<your-server>"
LOCAL_PLACEHOLDER="~/path/to"
SESSION_PREFIX="agentbox-"

# Who you log in as, and where that user's home is. Read from passwd rather
# than $HOME so the answer is the same whether this runs in your SSH session or
# under `docker exec` as root — the endpoint is about the login user either way.
BOX_USER="${AGENTBOX_USER:-$(id -un)}"
[ "$BOX_USER" != "root" ] || BOX_USER=dev     # PermitRootLogin no; nobody dials root
BOX_HOME="$(getent passwd "$BOX_USER" | cut -d: -f6)"
BOX_HOME="${BOX_HOME:-/home/$BOX_USER}"
PROJECTS_DIR="$BOX_HOME/projects"

# `ssh box agentbox-mirror myapp` — asking from a phone for a command to paste
# on the laptop later — is a non-interactive session: sshd runs the command
# directly, so /etc/profile.d never happens and the endpoint would be missing
# from exactly the call that most wants it. Read what the profile would have.
# The file assigns in `${VAR:-value}` form, so anything already set still wins.
if [ -z "${AGENTBOX_SSH_HOST:-}" ] && [ -r /etc/agentbox/config.env ]; then
    # shellcheck disable=SC1091
    . /etc/agentbox/config.env
fi

SSH_HOST="${AGENTBOX_SSH_HOST:-}"
SSH_PORT="${AGENTBOX_SSH_PORT:-2222}"

# Build output, dependency trees and per-machine settings. Everything here is
# large, regenerated constantly on both sides, and machine-specific — mirroring
# any of it is how a mirror becomes useless.
#
# `build/`, `.gradle/`, `.cxx/` and `local.properties` are the Android half: a
# Gradle build directory is hundreds of megabytes of output, and
# local.properties holds the *local* SDK path, which must differ on the two
# sides by definition.
#
# .git is deliberately NOT here, and --ignore-vcs is deliberately not passed:
# the whole point is running the code on your machine, which means running git
# on your machine, and a mirror without .git is not the same repository.
IGNORES='node_modules/,.venv/,__pycache__/,target/,build/,.gradle/,.cxx/,local.properties,dist/,.next/,.DS_Store,*.swp'

if [ -t 1 ]; then
    c_head=$'\033[36m'; c_ok=$'\033[32m'; c_warn=$'\033[33m'
    c_err=$'\033[31m'; c_dim=$'\033[2m'; c_off=$'\033[0m'
else
    c_head=''; c_ok=''; c_warn=''; c_err=''; c_dim=''; c_off=''
fi

die() { printf '%sagentbox-mirror:%s %s\n' "$c_err" "$c_off" "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Endpoint and naming
# ---------------------------------------------------------------------------

# A bare name is a project under ~/projects; anything with a slash is a path,
# relative to where you are or absolute. Always answers with an absolute path:
# Mutagen resolves a relative remote path against the remote home, which is
# right today and quietly wrong the day AGENTBOX_USER changes.
resolve_project() {
    local arg="$1" path
    case "$arg" in
        */*|.|..|~) path="${arg/#\~/$BOX_HOME}" ;;
        *)          path="$PROJECTS_DIR/$arg" ;;
    esac

    if [ ! -d "$path" ]; then
        die "no such project: $path
       'agentbox-mirror' with no arguments lists what you can mirror."
    fi
    (cd "$path" && pwd -P)
}

# Mutagen takes [a-zA-Z0-9_-] in a session name and wants a letter or a digit
# first — which the prefix guarantees, whatever the directory is called.
session_name() {
    local name
    name="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' \
            | sed -e 's/[^a-z0-9_-]\+/-/g' -e 's/-\+/-/g' -e 's/^-//' -e 's/-$//')"
    printf '%s%s' "$SESSION_PREFIX" "${name:-project}"
}

# Mutagen's SCP-like form: [<user>@]<host>[:<port>]:<path>.
endpoint() {
    printf '%s@%s:%s:%s' "$BOX_USER" "${SSH_HOST:-$HOST_PLACEHOLDER}" "$SSH_PORT" "$1"
}

# Directory names are allowed spaces, quotes and the odd '&'; a printed command
# that has to be edited before it runs is not a printed command. Quote only
# when it is needed, so the ninety percent case stays a plain readable line.
shell_quote() {
    case "$1" in
        *[!A-Za-z0-9@:./_-]*)
            printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")" ;;
        *)  printf '%s' "$1" ;;
    esac
}

host_note() {
    [ -n "$SSH_HOST" ] && return 0
    printf '%s\n' \
      "" \
      "  ${c_warn}$HOST_PLACEHOLDER is a placeholder${c_off} — this box does not know the address you" \
      "  reach it at, because the port mapping and any proxy live outside it." \
      "  Replace it with your server's hostname, or set AGENTBOX_SSH_HOST on the" \
      "  container to have it filled in for you from now on."
}

# ---------------------------------------------------------------------------
# agentbox-mirror <project>
# ---------------------------------------------------------------------------
print_command() {
    local path base name local_path
    path="$(resolve_project "$1")" || exit 1
    base="$(basename "$path")"
    name="$(session_name "$base")"
    # The tilde stays outside the quotes or the shell would not expand it.
    local_path="$LOCAL_PLACEHOLDER/$(shell_quote "$base")"

    printf '%sMirror %s onto your own machine%s\n\n' "$c_head" "$path" "$c_off"
    printf '  Run this %swhere you want the copy%s — your laptop, not in here:\n\n' \
        "$c_head" "$c_off"
    printf "    mutagen sync create \\\\\n"
    printf "      --name=%s \\\\\n" "$name"
    printf "      --ignore='%s' \\\\\n" "$IGNORES"
    printf "      %s \\\\\n" "$local_path"
    printf "      %s\n" "$(shell_quote "$(endpoint "$path")")"
    printf '\n'
    printf '  %s%s is yours to choose%s — it is where the mirror lands locally,\n' \
        "$c_dim" "$local_path" "$c_off"
    printf '  %sand this box has no way to guess it. Everything else is ready to paste.%s\n' \
        "$c_dim" "$c_off"
    host_note
    printf '\n'
    printf '  %smutagen sync monitor %s%s   watch the first sync\n' "$c_dim" "$name" "$c_off"
    printf '  %smutagen sync terminate %s%s stop mirroring (both copies stay)\n' "$c_dim" "$name" "$c_off"
    printf '  %s%s%s\n' "$c_dim" "$DOCS_URL" "$c_off"
}

# ---------------------------------------------------------------------------
# agentbox-mirror project <name> — stdout is the file, and nothing else
# ---------------------------------------------------------------------------
print_project_file() {
    [ -n "${1:-}" ] || die "usage: agentbox-mirror project <name>  (redirect it to mutagen.yml)"
    local path name base
    path="$(resolve_project "$1")" || exit 1
    base="$(basename "$path")"
    name="$(session_name "$base")"

    printf '# mutagen.yml — generated by agentbox-mirror on %s\n' "$(hostname)"
    printf '# Save this next to the project on your own machine and run:\n'
    printf '#\n'
    printf '#     mutagen project start\n'
    printf '#\n'
    printf '# Set alpha to where you want the copy to live locally. Everything else is\n'
    printf '# what agentbox-mirror would have printed as a one-off command.\n'
    printf 'sync:\n'
    printf '  %s:\n' "$name"
    printf '    alpha: "%s/%s"\n' "$LOCAL_PLACEHOLDER" "$base"
    printf '    beta: "%s"\n' "$(endpoint "$path")"
    printf '    mode: "two-way-safe"\n'
    printf '    ignore:\n'
    # Not "vcs: true": .git has to cross, or the copy is not the repository.
    printf '      vcs: false\n'
    printf '      paths:\n'
    printf '%s\n' "$IGNORES" | tr ',' '\n' | while read -r pattern; do
        [ -n "$pattern" ] || continue
        printf '        - "%s"\n' "$pattern"
    done
}

# ---------------------------------------------------------------------------
# agentbox-mirror check
# ---------------------------------------------------------------------------
ok()      { printf '  %sok%s    %s\n' "$c_ok" "$c_off" "$*"; }
bad()     { printf '  %sFAIL%s  %s\n' "$c_err" "$c_off" "$*"; }
warning() { printf '  %swarn%s  %s\n' "$c_warn" "$c_off" "$*"; }

# Mutagen copies its agent in over scp, which on OpenSSH 9 is the SFTP
# subsystem. Without it Mutagen fails at connection time talking about a remote
# agent, which tells you nothing about what to fix in here.
sftp_server() {
    local line
    # `sshd -T` is the running configuration, drop-ins included — but it needs
    # root. As the login user, read the same files sshd reads.
    if line="$(/usr/sbin/sshd -T -f /etc/ssh/sshd_config 2>/dev/null \
               | grep -iE '^subsystem[[:space:]]+sftp[[:space:]]')"; then
        :
    else
        line="$(grep -hiE '^[[:space:]]*Subsystem[[:space:]]+sftp[[:space:]]' \
                /etc/agentbox/sshd.d/*.conf /etc/ssh/sshd_config 2>/dev/null | head -1)"
    fi
    [ -n "$line" ] || return 1
    printf '%s' "$line" | awk '{print $3}'
}

check() {
    local failures=0 binary agent_dir

    printf '%sIs this box ready to be mirrored?%s\n\n' "$c_head" "$c_off"

    if binary="$(sftp_server)" && [ -n "$binary" ]; then
        if [ -x "$binary" ]; then
            ok "sftp subsystem: $binary"
        else
            bad "sftp subsystem points at $binary, which is not executable here.
        Mutagen copies its agent in over sftp and cannot connect without it."
            failures=$((failures + 1))
        fi
    else
        bad "no sftp subsystem in the sshd configuration. Mutagen installs its
        agent over sftp, so no mirror can connect. Restore the
        'Subsystem sftp' line in /etc/ssh/sshd_config."
        failures=$((failures + 1))
    fi

    # Mutagen unpacks its agent into ~/.mutagen/agents/<version>/. On a first
    # connection that directory does not exist yet, so the question is whether
    # the home it would be created in is writable.
    agent_dir="$BOX_HOME/.mutagen"
    [ -d "$agent_dir" ] || agent_dir="$BOX_HOME"
    if sudo -n -u "$BOX_USER" test -w "$agent_dir" 2>/dev/null \
       || { [ "$(id -un)" = "$BOX_USER" ] && [ -w "$agent_dir" ]; }; then
        ok "mutagen agent directory: $agent_dir is writable by $BOX_USER"
    else
        bad "$agent_dir is not writable by $BOX_USER, so Mutagen cannot install
        its agent. Check the ownership of $BOX_HOME."
        failures=$((failures + 1))
    fi

    if [ -n "$SSH_HOST" ]; then
        ok "endpoint: $(endpoint "$PROJECTS_DIR/<project>")"
    else
        # A warning, not a failure: the box cannot test whether an address
        # outside it resolves, and someone who knows their own address does not
        # need this set to mirror. Refusing here would be the box asserting
        # something it has no way to know.
        warning "AGENTBOX_SSH_HOST is not set, so printed commands carry
        $HOST_PLACEHOLDER instead of an address. Set it on the container to
        fill it in. Port $SSH_PORT is what will be dialed."
        if [ -n "${SSH_CONNECTION:-}" ]; then
            printf '        %sthis session came in on %s — which may be a proxy or the\n' \
                "$c_dim" "$(printf '%s' "$SSH_CONNECTION" | awk '{print $3}')"
            printf '        docker bridge rather than the address you dial%s\n' "$c_off"
        fi
    fi

    printf '\n'
    if [ "$failures" -eq 0 ]; then
        printf '  %sready%s — %s\n' "$c_ok" "$c_off" "$DOCS_URL"
        return 0
    fi
    printf '  %s%d thing(s) would stop a mirror from connecting%s\n' \
        "$c_err" "$failures" "$c_off"
    return 1
}

# ---------------------------------------------------------------------------
# agentbox-mirror
# ---------------------------------------------------------------------------
overview() {
    printf '%sagentbox-mirror — the same project on both sides%s\n\n' "$c_head" "$c_off"
    cat <<EOF
  Agents write code in here. Some of it cannot run in here: an Android build
  needs the SDK and a real emulator, adb needs a USB cable, CUDA needs a GPU.
  A mirror keeps a project in this box and a directory on your own machine in
  sync over the SSH connection you already have, so you edit and build in the
  place that suits each.

  This command prints the command to paste on your own machine — Mutagen runs
  there, not here. Install it first: $DOCS_URL

    agentbox-mirror <project>      the command to paste
    agentbox-mirror project <name> the same thing as a mutagen.yml
    agentbox-mirror check          is this box ready to be mirrored

EOF
    printf '  %sProjects in %s:%s\n' "$c_head" "$PROJECTS_DIR" "$c_off"
    local found=0 entry
    if [ -d "$PROJECTS_DIR" ]; then
        for entry in "$PROJECTS_DIR"/*/; do
            [ -d "$entry" ] || continue
            entry="$(basename "$entry")"
            printf '    agentbox-mirror %s\n' "$entry"
            found=1
        done
    fi
    if [ "$found" -eq 0 ]; then
        printf '    %snothing yet — clone a repository in there and come back%s\n' \
            "$c_dim" "$c_off"
    fi
    printf '\n  %sAny other directory works too: agentbox-mirror ~/work/thing%s\n' \
        "$c_dim" "$c_off"
}

# ---------------------------------------------------------------------------
# Dispatch: the first argument is a verb only when it is not also a project.
# A project genuinely called `check` is the likelier thing to have meant, so it
# wins — and the note says how to reach the verb anyway.
# ---------------------------------------------------------------------------
case "${1:-}" in
    '')             overview; exit 0 ;;
    -h|--help|help) overview; exit 0 ;;
    --check)        check; exit $? ;;
    --project)      shift; print_project_file "${1:-}"; exit $? ;;
esac

if [ "$1" = "check" ] || [ "$1" = "project" ]; then
    if [ -d "$PROJECTS_DIR/$1" ]; then
        printf '%snote:%s you have a project called '\''%s'\'', so that is what this is.\n' \
            "$c_warn" "$c_off" "$1" >&2
        printf '      For the command itself, run: agentbox-mirror --%s\n\n' "$1" >&2
    else
        case "$1" in
            check)   check; exit $? ;;
            project) shift; print_project_file "${1:-}"; exit $? ;;
        esac
    fi
fi

print_command "$1"
