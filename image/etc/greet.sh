# Sourced from /etc/bash.bashrc for interactive shells.
#
# AGENTBOX_BANNER decides where the wordmark shows up:
#   always  (default) every interactive shell, including each herdr pane
#   login   only the shell you land in over SSH
#   off     never
case $- in
    *i*) ;;
    *) return 0 ;;
esac

case "${AGENTBOX_BANNER:-always}" in
    off|0|no|false) return 0 ;;
    login) shopt -q login_shell 2>/dev/null || return 0 ;;
esac

# bash measured this terminal itself and keeps COLUMNS/LINES to itself — they
# are shell variables, never exported — so the banner, a separate process, has
# to be handed them. Without this it is left guessing from terminfo, and a
# terminal that answers "80" out of habit gets the six-line wordmark on a
# four-inch screen.
AGENTBOX_BANNER_COLS="${COLUMNS:-}" agentbox-banner

# Everything below belongs to the shell you land in over SSH. A herdr pane
# gets the wordmark and nothing else — you already know where you are.
shopt -q login_shell 2>/dev/null || return 0

# The summary is 10 lines. On a phone that is half the screen on top of the
# wordmark, so only wide-and-tall terminals get it. Same rule as the banner:
# ask bash first, the tty second, and assume a phone when nobody answers.
_agentbox_cols="${COLUMNS:-$(tput cols 2>/dev/null || echo 0)}"
_agentbox_lines="${LINES:-$(tput lines 2>/dev/null || echo 0)}"
if [ -r /etc/motd ] \
   && [ "${_agentbox_cols:-0}" -ge 70 ] 2>/dev/null \
   && [ "${_agentbox_lines:-0}" -ge 26 ] 2>/dev/null; then
    cat /etc/motd
else
    printf '  run \033[1mherdr\033[0m to start or reattach\n\n'
fi
unset _agentbox_cols _agentbox_lines

# One line about the disk, only when it is worth one. The figures come from a
# file the persist watcher refreshes (a du of the home at every login would be
# the opposite of what a small box needs), so they can be a while stale; the
# command they name measures live. Above AGENTBOX_CLEAN_WARN, or when more
# than half of the home is cache, say so. Otherwise say nothing.
_agentbox_disk="${AGENTBOX_PERSIST_DIR:-/var/lib/agentbox}/.disk"
if [ -r "$_agentbox_disk" ]; then
    read -r _agentbox_home _agentbox_cache < "$_agentbox_disk" 2>/dev/null
    _agentbox_warn="${AGENTBOX_CLEAN_WARN:-20G}"
    case "$_agentbox_warn" in
        *G|*g) _agentbox_warn=$(( ${_agentbox_warn%[Gg]} * 1048576 )) ;;
        *M|*m) _agentbox_warn=$(( ${_agentbox_warn%[Mm]} * 1024 )) ;;
        *)     _agentbox_warn=$(( _agentbox_warn / 1024 )) ;;
    esac 2>/dev/null
    if [ "${_agentbox_home:-0}" -gt "${_agentbox_warn:-0}" ] 2>/dev/null \
       || { [ "${_agentbox_cache:-0}" -gt 0 ] && [ $(( ${_agentbox_cache:-0} * 2 )) -gt "${_agentbox_home:-0}" ]; } 2>/dev/null; then
        printf '  home %d.%d GB, %d.%d GB of it rebuildable \342\200\224 \033[1magentbox-clean\033[0m shows what\n\n' \
            $(( _agentbox_home / 1048576 )) $(( (_agentbox_home % 1048576) * 10 / 1048576 )) \
            $(( _agentbox_cache / 1048576 )) $(( (_agentbox_cache % 1048576) * 10 / 1048576 ))
    fi
    unset _agentbox_home _agentbox_cache _agentbox_warn
fi
unset _agentbox_disk
