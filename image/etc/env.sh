# Sourced by every login shell (/etc/profile.d) and every interactive bash
# (/etc/bash.bashrc). Keep it POSIX-ish and side-effect free.

# sshd builds a session environment from scratch: variables set on the
# container (LANG, TZ, AGENTBOX_*) never reach an SSH login on their own. The
# entrypoint writes them here on boot so both logins and herdr panes see them.
[ -r /etc/agentbox/config.env ] && . /etc/agentbox/config.env

# Tools the agents install into the home volume win over the ones baked into
# the image, so `claude update` (and friends) actually take effect.
case ":${PATH}:" in
    *":${HOME}/.local/bin:"*) ;;
    *) PATH="${HOME}/.local/bin:${HOME}/.bun/bin:${PATH}" ;;
esac
export PATH

# SSH forwards the client's TERM verbatim, and terminals that ship their own
# terminfo (ghostty, a kitty newer than the image's entry) name something the
# box has never heard of -- every ncurses program then dies with "unknown
# terminal type". Look the name up by hand instead of shelling out to infocmp:
# this file runs for every shell, herdr panes included.
if [ -n "${TERM:-}" ] && [ "${TERM}" != "dumb" ]; then
    _agentbox_initial=${TERM%"${TERM#?}"}
    _agentbox_terminfo=""
    for _agentbox_dir in ${TERMINFO:+"${TERMINFO}"} "${HOME}/.terminfo" \
                         /etc/terminfo /lib/terminfo /usr/share/terminfo; do
        if [ -e "${_agentbox_dir}/${_agentbox_initial}/${TERM}" ]; then
            _agentbox_terminfo=1
            break
        fi
    done
    [ -n "${_agentbox_terminfo}" ] || export TERM=xterm-256color
    unset _agentbox_initial _agentbox_terminfo _agentbox_dir
fi

# Neovim reads this to enable 24-bit color over SSH/mosh.
export COLORTERM="${COLORTERM:-truecolor}"
export EDITOR="${EDITOR:-nvim}"
export VISUAL="${VISUAL:-nvim}"
export PAGER="${PAGER:-less}"

# npm global installs go to the home volume instead of /usr/local, so
# `npm i -g something` survives an image rebuild. Not for root: `sudo npm i -g`
# would land in /root/.local, which is on nobody's PATH.
if [ "$(id -u)" != "0" ]; then
    export NPM_CONFIG_PREFIX="${NPM_CONFIG_PREFIX:-$HOME/.local}"
fi

if [ -n "${BASH_VERSION:-}" ]; then
    alias vi='nvim'
    alias vim='nvim'
    alias ll='ls -alF'
    alias la='ls -A'
    alias l='ls -CF'
fi
