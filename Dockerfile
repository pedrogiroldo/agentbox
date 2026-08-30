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

ARG INSTALL_DOCKER_CLI=true
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
        bash-completion man-db mosh tmux \
        libssl-dev zlib1g-dev \
    && ln -sf /usr/bin/fdfind /usr/local/bin/fd \
    && sed -i -e '/^# *en_US.UTF-8 UTF-8/s/^# *//' -e '/^# *pt_BR.UTF-8 UTF-8/s/^# *//' /etc/locale.gen \
    && locale-gen \
    && rm -rf /var/lib/apt/lists/*

ENV LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8

# GitHub CLI (official apt repository)
RUN install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
         -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
         > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# Docker CLI — only useful when you bind-mount the host's docker socket.
# The daemon is NOT installed; see docs/security.md before mounting the socket.
RUN if [ "$INSTALL_DOCKER_CLI" = "true" ]; then \
        install -m 0755 -d /etc/apt/keyrings \
        && curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
             -o /etc/apt/keyrings/docker.asc \
        && chmod a+r /etc/apt/keyrings/docker.asc \
        && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu noble stable" \
             > /etc/apt/sources.list.d/docker.list \
        && apt-get update \
        && apt-get install -y --no-install-recommends docker-ce-cli docker-buildx-plugin docker-compose-plugin \
        && rm -rf /var/lib/apt/lists/*; \
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
COPY image/entrypoint.sh /usr/local/bin/agentbox-entrypoint
COPY image/skel/ /opt/agentbox/skel/

RUN set -eux; \
    chmod +x /usr/local/bin/agentbox-entrypoint /usr/local/bin/agentbox-make-motd \
        /usr/local/bin/agentbox-banner; \
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

EXPOSE 22

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD nc -z 127.0.0.1 22 || exit 1

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/agentbox-entrypoint"]
CMD ["/usr/sbin/sshd", "-D", "-e"]
