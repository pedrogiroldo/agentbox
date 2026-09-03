#!/usr/bin/env bash
# Builds /etc/motd at image build time, so logging in tells you what you got.
set -euo pipefail

ver() { "$@" 2>/dev/null | head -1 | tr -d '\r' || echo "?"; }

cat > /etc/motd <<EOF

  agentbox — your personal agent VM
  $(. /etc/os-release; echo "$PRETTY_NAME")  ·  $(uname -m)

  herdr $(ver herdr --version | awk '{print $NF}')      start here: keeps agents running after you disconnect
  claude $(ver claude --version | awk '{print $1}')     codex $(ver codex --version | awk '{print $NF}')     opencode $(ver opencode --version)
  nvim $(ver nvim --version | awk '{print $2}')      node $(ver node --version)   bun $(ver bun --version)   uv $(ver uv --version | awk '{print $2}')

  agentbox-mirror            same project here and on your laptop
  ~/projects                 your repositories (persistent)
  ~/.agentbox/provision.sh   packages that must survive a rebuild
  ~/.agentbox/provision.log  what it printed last boot

  Neovim switches to mobile mode by itself on narrow screens (or NVIM_MOBILE=1).
  Docs: https://github.com/pedrogiroldo/agentbox

EOF
