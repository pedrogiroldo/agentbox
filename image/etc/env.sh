# Sourced by every login shell (/etc/profile.d) and every interactive bash
# (/etc/bash.bashrc). Keep it POSIX-ish and side-effect free.

# Tools the agents install into the home volume win over the ones baked into
# the image, so `claude update` (and friends) actually take effect.
case ":${PATH}:" in
    *":${HOME}/.local/bin:"*) ;;
    *) PATH="${HOME}/.local/bin:${HOME}/.bun/bin:${PATH}" ;;
esac
export PATH

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
