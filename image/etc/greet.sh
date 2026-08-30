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

agentbox-banner

# Everything below belongs to the shell you land in over SSH. A herdr pane
# gets the wordmark and nothing else — you already know where you are.
shopt -q login_shell 2>/dev/null || return 0

# The summary is 10 lines. On a phone that is half the screen on top of the
# wordmark, so only wide-and-tall terminals get it.
if [ -r /etc/motd ] \
   && [ "$(tput cols 2>/dev/null || echo 0)" -ge 70 ] \
   && [ "$(tput lines 2>/dev/null || echo 0)" -ge 26 ]; then
    cat /etc/motd
else
    printf '  run \033[1mherdr\033[0m to start or reattach\n\n'
fi
