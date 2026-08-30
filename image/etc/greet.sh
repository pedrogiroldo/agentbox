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
