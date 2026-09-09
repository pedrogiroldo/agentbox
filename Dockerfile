# syntax=docker/dockerfile:1
#
# agentbox — an Ubuntu container that behaves like a personal dev VM for
# coding agents, reachable over SSH (including from a phone).
#
# Everything that is *software* lives in the image (/usr, /opt).
# Everything that is *yours* lives in /home/dev, which is a persistent volume.
# See docs/persistence.md for the reasoning.

FROM ubuntu:24.04

# ---------------------------------------------------------------------------
# Build arguments — override them with `--build-arg` or in docker-compose.yml
# ---------------------------------------------------------------------------
ARG USERNAME=dev
ARG USER_UID=1000
ARG USER_GID=1000

# Pin these to get reproducible images; "latest"/"stable" always tracks upstream.
ARG NODE_VERSION=24.13.0
ARG NVIM_VERSION=stable
ARG CLAUDE_CODE_VERSION=latest
ARG CODEX_VERSION=latest
ARG OPENCODE_VERSION=latest
# "latest" takes the newest release tag; a v-prefixed tag (v1.6.0) pins it and
# skips the tag lookup entirely.
ARG COLLIE_VERSION=latest

# Tailscale: how the box gets a front door of its own. It runs in userspace
# networking, so it needs no TUN device and no NET_ADMIN -- see docs/tailscale.md.
# Collie has no other way in, so turning this off makes Collie unreachable.
ARG INSTALL_TAILSCALE=true

ARG INSTALL_DOCKER_CLI=true
# Bake the daemon into the image. Off by default -- not because the box does
# not want one, but because it installs it on first boot instead, into the
# state volume, so that 192 MB is paid by the boxes that run containers rather
# than by everyone who pulls agentbox. Turn it on for an image that is ready
# to run containers the second it boots, with no network. See docs/docker.md.
ARG INSTALL_DOCKER_ENGINE=false
ARG PREINSTALL_NVIM_PLUGINS=true

ENV DEBIAN_FRONTEND=noninteractive \
    AGENTBOX_USER=${USERNAME}

# ---------------------------------------------------------------------------
# Base system
# ---------------------------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl wget gnupg openssh-server openssh-client sudo tini \
        locales tzdata git git-lfs \
        build-essential pkg-config make cmake \
        unzip zip xz-utils tar gzip \
        ripgrep fd-find fzf jq less nano tree htop procps psmisc lsof strace \
        python3 python3-venv \
        rsync socat netcat-openbsd iputils-ping dnsutils net-tools \
        bash-completion man-db mosh tmux ncurses-term \
        libssl-dev zlib1g-dev \
    && ln -sf /usr/bin/fdfind /usr/local/bin/fd \
    && sed -i -e '/^# *en_US.UTF-8 UTF-8/s/^# *//' -e '/^# *pt_BR.UTF-8 UTF-8/s/^# *//' /etc/locale.gen \
    && locale-gen \
    && rm -rf /var/lib/apt/lists/*

ENV LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8

# Terminal emulators ship their own terminfo and SSH hands us that TERM name;
# without an entry every ncurses program dies with "unknown terminal type".
# ncurses-term covers alacritty/wezterm/foot/rio/tmux-256color. kitty is in
# there as `kitty`, but what kitty actually exports is `xterm-kitty`, so alias
# the one onto the other. Anything still missing (ghostty) falls back to
# xterm-256color in /etc/agentbox/env.sh.
RUN infocmp kitty | sed 's/^kitty|/xterm-kitty|kitty|/' | tic -x -o /usr/share/terminfo -

# GitHub CLI (official apt repository)
RUN install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
         -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
         > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# Docker — two shapes, and the build arg picks one.
#
#   INSTALL_DOCKER_CLI     the client only. Useless on its own: it needs a
#                          daemon somewhere, either the host's socket
#                          bind-mounted in or a remote one in DOCKER_HOST.
#   INSTALL_DOCKER_ENGINE  the daemon too, so the box is its own Docker host.
#                          Implies the CLI. Costs ~400 MB and, at run time, a
#                          privileged container -- read docs/security.md first.
RUN if [ "$INSTALL_DOCKER_CLI" = "true" ] || [ "$INSTALL_DOCKER_ENGINE" = "true" ]; then \
        install -m 0755 -d /etc/apt/keyrings \
        && curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
             -o /etc/apt/keyrings/docker.asc \
        && chmod a+r /etc/apt/keyrings/docker.asc \
        && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu noble stable" \
             > /etc/apt/sources.list.d/docker.list \
        && apt-get update \
        && if [ "$INSTALL_DOCKER_ENGINE" = "true" ]; then \
               apt-get install -y --no-install-recommends \
                   docker-ce docker-ce-cli containerd.io \
                   docker-buildx-plugin docker-compose-plugin \
                   iptables uidmap; \
           else \
               apt-get install -y --no-install-recommends \
                   docker-ce-cli docker-buildx-plugin docker-compose-plugin; \
           fi \
        && rm -rf /var/lib/apt/lists/*; \
    fi

# Tailscale (official apt repository). Installed, never started: the box joins
# nothing unless AGENTBOX_TAILSCALE says so, because joining a tailnet is
# joining somebody's tailnet.
RUN if [ "$INSTALL_TAILSCALE" = "true" ]; then \
        install -m 0755 -d /etc/apt/keyrings \
        && curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/noble.noarmor.gpg \
             -o /etc/apt/keyrings/tailscale-archive-keyring.gpg \
        && chmod go+r /etc/apt/keyrings/tailscale-archive-keyring.gpg \
        && echo "deb [signed-by=/etc/apt/keyrings/tailscale-archive-keyring.gpg] https://pkgs.tailscale.com/stable/ubuntu noble main" \
             > /etc/apt/sources.list.d/tailscale.list \
        && apt-get update && apt-get install -y --no-install-recommends tailscale \
        && rm -rf /var/lib/apt/lists/* \
        && tailscale version; \
    fi

# ---------------------------------------------------------------------------
# Runtimes: Node.js, Bun, uv — installed into /usr/local so they survive
# a wiped home volume and are shared by every user.
# ---------------------------------------------------------------------------
RUN set -eux; \
    case "$(dpkg --print-architecture)" in \
        amd64) node_arch=x64 ;; \
        arm64) node_arch=arm64 ;; \
        *) echo "unsupported architecture" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${node_arch}.tar.xz" \
      | tar -xJ -C /usr/local --strip-components=1 --no-same-owner \
        --exclude='*/CHANGELOG.md' --exclude='*/LICENSE' --exclude='*/README.md'; \
    node --version; npm --version

RUN BUN_INSTALL=/usr/local bash -c 'curl -fsSL https://bun.sh/install | bash' \
    && bun --version

RUN curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh \
    && uv --version

# ---------------------------------------------------------------------------
# Neovim (official release tarball, not the distro package: LazyVim needs 0.9+)
# ---------------------------------------------------------------------------
RUN set -eux; \
    case "$(dpkg --print-architecture)" in \
        amd64) nvim_arch=linux-x86_64 ;; \
        arm64) nvim_arch=linux-arm64 ;; \
        *) echo "unsupported architecture" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://github.com/neovim/neovim/releases/download/${NVIM_VERSION}/nvim-${nvim_arch}.tar.gz" \
      | tar -xz -C /opt; \
    mv "/opt/nvim-${nvim_arch}" /opt/nvim; \
    ln -s /opt/nvim/bin/nvim /usr/local/bin/nvim; \
    nvim --version | head -1

# ---------------------------------------------------------------------------
# Herdr — the terminal multiplexer that keeps agents alive between SSH sessions
# ---------------------------------------------------------------------------
RUN HERDR_INSTALL_DIR=/usr/local/bin bash -c 'curl -fsSL https://herdr.dev/install.sh | sh' \
    && herdr --version

# ---------------------------------------------------------------------------
# Collie — the mobile web UI for the herd (docs/collie.md)
# ---------------------------------------------------------------------------
# Installed, never started: AGENTBOX_COLLIE decides that, and it defaults to
# off. A running Collie hands keystrokes to live panes in a privileged
# container, and its reads are open to whatever reaches the URL.
#
# Baked in rather than fetched on first boot -- the trade that defers the
# Docker engine (192 MB nobody asked for) does not apply to 84 MB that is the
# whole feature. /opt is inside the persistence contract, so a `collie update`
# from the phone survives a recreate.
#
# COLLIE_VERSION=latest asks api.github.com for the newest tag, which is rate
# limited per network address; pin a tag (v1.6.0) for a build that never calls it.
ARG COLLIE_CACHEBUST=0
RUN set -eux; \
    echo "cachebust ${COLLIE_CACHEBUST}" > /dev/null; \
    export COLLIE_DIR=/opt/collie; \
    if [ "${COLLIE_VERSION}" != "latest" ]; then export COLLIE_TAG="${COLLIE_VERSION}"; fi; \
    curl -fsSL https://colliepwa.dev/install.sh | sh; \
    # The manifest herdr links against lives inside the release tree, so both
    # the symlink and `herdr plugin link` target `current`, not the directory
    # above it -- linking the parent fails with plugin_manifest_not_found.
    ln -s /opt/collie/current/bin/collie /usr/local/bin/collie; \
    # The release tarball unpacks versions/ world-writable and owned by uid
    # 1001. It goes to the box's user, by uid because the user is created a
    # few layers down: `collie update` runs as that user and stages the new
    # release next to the old one, so a root-owned tree makes the in-place
    # update docs/collie.md promises fail with EACCES on the first mkdir. Only
    # the owner may write, so it still is not a world-writable system prefix.
    chown -R "${USER_UID}:${USER_GID}" /opt/collie; \
    chmod -R u+w,go-w /opt/collie; \
    # `collie link` at the end of the installer publishes into /root/.local/bin,
    # which is on nobody's PATH. The symlink above is the one that counts.
    rm -rf /root/.local/share/collie /root/.local/bin; \
    collie version

# ---------------------------------------------------------------------------
# Coding agents
# ---------------------------------------------------------------------------
# Bump AGENTS_CACHEBUST (make update does it for you) to reinstall the agents
# instead of reusing this layer — "latest" alone never invalidates a cache.
ARG AGENTS_CACHEBUST=0
RUN echo "cachebust ${AGENTS_CACHEBUST}" > /dev/null \
    && npm install -g --no-fund --no-audit \
        "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
        "@openai/codex@${CODEX_VERSION}" \
        "opencode-ai@${OPENCODE_VERSION}" \
    && npm cache clean --force \
    && claude --version && codex --version && opencode --version

# ---------------------------------------------------------------------------
# The user you actually log in as
# ---------------------------------------------------------------------------
RUN set -eux; \
    # Ubuntu 24.04 ships an "ubuntu" user squatting on uid 1000.
    if id ubuntu >/dev/null 2>&1 && [ "$(id -u ubuntu)" = "1000" ]; then userdel -r ubuntu; fi; \
    if ! getent group "${USER_GID}" >/dev/null; then groupadd -g "${USER_GID}" "${USERNAME}"; fi; \
    useradd -m -u "${USER_UID}" -g "${USER_GID}" -s /bin/bash "${USERNAME}"; \
    # The docker group up front, even though the engine arrives later (on first
    # boot, into the state volume). dockerd hands its socket to this group, so
    # being in it already is what keeps `docker ps` from needing sudo -- and
    # from needing a second login after the daemon appears mid-session.
    groupadd -f docker; \
    usermod -aG docker "${USERNAME}"; \
    echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/90-agentbox; \
    chmod 0440 /etc/sudoers.d/90-agentbox; \
    mkdir -p /run/sshd /etc/agentbox/sshd.d

# ---------------------------------------------------------------------------
# agentbox files: shell environment, sshd config, entrypoint and the home skel
# ---------------------------------------------------------------------------
COPY image/etc/env.sh /etc/agentbox/env.sh
COPY image/etc/sshd_config /etc/ssh/sshd_config
COPY image/etc/make-motd.sh /usr/local/bin/agentbox-make-motd
COPY image/etc/banner.sh /usr/local/bin/agentbox-banner
COPY image/etc/greet.sh /etc/agentbox/greet.sh
COPY image/etc/persist.sh /usr/local/bin/agentbox-persist
COPY image/etc/dockerd.sh /usr/local/bin/agentbox-dockerd
COPY image/etc/mirror.sh /usr/local/bin/agentbox-mirror
COPY image/etc/collie.sh /usr/local/bin/agentbox-collie
COPY image/etc/tailscaled.sh /usr/local/bin/agentbox-tailscaled
COPY image/etc/herdr-server.sh /usr/local/bin/agentbox-herdr
COPY image/entrypoint.sh /usr/local/bin/agentbox-entrypoint
COPY image/skel/ /opt/agentbox/skel/

RUN set -eux; \
    chmod +x /usr/local/bin/agentbox-entrypoint /usr/local/bin/agentbox-make-motd \
        /usr/local/bin/agentbox-banner /usr/local/bin/agentbox-persist \
        /usr/local/bin/agentbox-dockerd /usr/local/bin/agentbox-mirror \
        /usr/local/bin/agentbox-collie /usr/local/bin/agentbox-herdr \
        /usr/local/bin/agentbox-tailscaled; \
    # /etc/agentbox/greet.sh prints the banner and the motd, in that order.
    # PAM would print the motd first (plus Ubuntu's motd-news noise), so mute it.
    sed -i 's/^session\s*optional\s*pam_motd/# &/' /etc/pam.d/sshd; \
    agentbox-make-motd; \
    # Load the agentbox environment in login shells (ssh) and in every
    # interactive bash (herdr panes open non-login shells).
    ln -sf /etc/agentbox/env.sh /etc/profile.d/00-agentbox.sh; \
    printf '\n# agentbox\n[ -r /etc/agentbox/env.sh ] && . /etc/agentbox/env.sh\n[ -r /etc/agentbox/greet.sh ] && . /etc/agentbox/greet.sh\n' >> /etc/bash.bashrc; \
    # The home skel is copied into the volume on first boot by the entrypoint.
    cp /etc/skel/.bashrc /etc/skel/.profile /opt/agentbox/skel/; \
    chown -R "${USER_UID}:${USER_GID}" /opt/agentbox/skel

# Warm up the Neovim plugin cache inside the skel so the first `nvim` on a
# phone is instant instead of a five-minute plugin install over a 4G link.
RUN if [ "$PREINSTALL_NVIM_PLUGINS" = "true" ]; then \
        su "${USERNAME}" -s /bin/bash -c \
            'HOME=/opt/agentbox/skel nvim --headless "+Lazy! install" "+Lazy! restore" +qa' \
        || echo ">> warning: Neovim plugin pre-install failed; plugins will install on first run"; \
    fi

# ---------------------------------------------------------------------------
# Persistence contract (see docs/persistence.md)
#
# Two records the runtime diffs against, both written *last* so they describe
# the finished image:
#   apt-baseline  the packages this image ships. Anything marked manual on top
#                 of it is yours, and agentbox-persist reinstalls it on boot.
#   build-stamp   the moment the image was sealed. Every file newer than this
#                 was put there by you, and gets copied into the state volume.
#
# The apt drop-ins move the .deb cache and the package lists into that volume,
# so replaying your packages after a recreate is usually offline and instant.
# ---------------------------------------------------------------------------
RUN set -eux; \
    install -d -m 0755 /usr/share/agentbox /var/lib/agentbox; \
    apt-mark showmanual | LC_ALL=C sort > /usr/share/agentbox/apt-baseline; \
    printf 'Dir::Cache::archives "/var/lib/agentbox/apt/archives/";\n\
Dir::State::lists "/var/lib/agentbox/apt/lists/";\n\
Binary::apt::APT::Keep-Downloaded-Packages "true";\n' \
        > /etc/apt/apt.conf.d/99-agentbox-cache; \
    printf 'DPkg::Post-Invoke { "/usr/local/bin/agentbox-persist record-apt >/dev/null 2>&1 || true"; };\n' \
        > /etc/apt/apt.conf.d/99-agentbox-record; \
    touch /usr/share/agentbox/build-stamp

EXPOSE 22

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD nc -z 127.0.0.1 22 || exit 1

# No -g on purpose: a group-wide TERM kills sshd and ends the container before
# the entrypoint can write out your last changes. It handles the sequence.
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/agentbox-entrypoint"]
CMD ["/usr/sbin/sshd", "-D", "-e"]
