# agentbox

**Your personal coding-agent VM, in a container.** Ubuntu + Herdr + Claude
Code, Codex and opencode + a Neovim setup that actually fits a phone screen.
Bring it up with one `docker compose up`, SSH in from anywhere, and the agents
keep working after you disconnect.

[![build image](https://github.com/pedrogiroldo/agentbox/actions/workflows/docker-image.yml/badge.svg)](https://github.com/pedrogiroldo/agentbox/actions/workflows/docker-image.yml)

🇧🇷 [Versão em português](README.md)

---

## Why this exists

I wanted coding agents running around the clock and a way to check on them from
anywhere — including from a phone, standing in a queue. Three things were in
the way:

1. **Closing the laptop kills the agent.** A plain SSH session dies with the
   connection, and the agent dies with it.
2. **Not everyone has a spare VM.** But plenty of us already pay for a VPS
   running Coolify or Dokploy. If the environment is a container, it goes up
   next to everything else — no new machine to provision.
3. **Terminals on phones are hostile.** A status line, relative numbers, a sign
   column, scroll animation — at 45 columns those stop being features.

agentbox is my answer to all three. It is not a per-project devcontainer: it is
a **development machine** that behaves like an ordinary VM — `sudo apt install`
whatever you want, clone repos, install runtimes — except it is disposable,
described by a Dockerfile, and all of your data lives in a volume on your own
server.

## How it works

```
        your phone / laptop
                │  ssh -p 2222 dev@server
                ▼
   ┌────────────────────────────────────────────┐
   │  agentbox container (Ubuntu 24.04)         │
   │                                            │
   │   sshd ──► herdr  (multiplexer)            │
   │              ├─ pane: claude               │
   │              ├─ pane: codex                │
   │              ├─ pane: opencode             │
   │              └─ pane: nvim / shell         │
   │                                            │
   │   /home/dev  ───────────────────────────┐  │
   └─────────────────────────────────────────┼──┘
                                             ▼
                              persistent volume on the server
                    (repos, agent credentials, config, history)
```

**Herdr** is the centerpiece: a terminal multiplexer built for coding agents.
It keeps everything alive across disconnects and labels each pane with the
agent inside it and whether that agent is working or waiting on you. That is
what makes "open a terminal on your phone" a reasonable thing to do.

## What's inside

| | |
| --- | --- |
| **Base** | Ubuntu 24.04, SSH (keys only), passwordless sudo, mosh, `en_US` + `pt_BR` locales |
| **Agents** | Claude Code, Codex CLI, opencode — Herdr integrations pre-wired |
| **Multiplexer** | [Herdr](https://herdr.dev) (tmux too, if you prefer) |
| **Editor** | Neovim + LazyVim with an automatic **mobile mode** |
| **Theme** | [Vesper](https://github.com/datsfilipe/vesper.nvim) in both Herdr and Neovim |
| **Runtimes** | Node.js, Bun, uv, Python 3 |
| **Tools** | git, git-lfs, gh, ripgrep, fd, fzf, jq, build-essential, Docker CLI |

## Getting started

You need Docker and Docker Compose on whatever will host it — your server, your
VPS, or your own machine.

```sh
git clone https://github.com/pedrogiroldo/agentbox.git
cd agentbox

make init        # writes .env with this machine's public key
$EDITOR .env     # add your phone's key, set the port, timezone, git identity

make up          # builds the image and starts the box
```

The first build takes a while (it warms up the Neovim plugin cache so the first
`nvim` on a phone is instant). Then:

```sh
ssh -p 2222 dev@your-server
herdr
```

That's it. `Ctrl+b` `?` lists the keybindings, `Ctrl+b` `q` detaches and leaves
everything running.

### The commands you'll actually use

```sh
make key       # print your public key (creates one if you have none)
make up        # start
make ssh       # connect from this machine
make logs      # watch the boot and your provision script
make shell     # get a shell without SSH (when you locked yourself out)
make update    # rebuild the image, recreate the container, keep the volume
make backup    # tar the volume into ./backups
```

`make` on its own lists everything.

## From a phone

Install an SSH client ([Termius](https://termius.com),
[Blink](https://blink.sh), Termux), **generate the key on the phone itself**,
and add its public half to `SSH_PUBLIC_KEY` (one per line).

Once connected, run `herdr`. The two shortcuts that matter on a small screen
are `Ctrl+b` `z` (zoom one pane full screen) and `Ctrl+b` `b` (hide the
sidebar).

Neovim switches to **mobile mode** by itself below 90 columns: no status line,
no relative numbers, no sign column, soft wrapping, `jk` to leave insert mode, a
full-screen file explorer, and every animation off — repainted cells are the
dominant cost over a mobile link. On a wide terminal nothing changes.

The full walkthrough, including the client settings that matter, is in
[docs/mobile.md](docs/mobile.md).

## Your data stays on your server

Two volumes cover it:

> **`/home/dev` is yours** — repositories, agent credentials, Neovim config and
> plugins, shell history, Herdr sessions and even the SSH host keys live in the
> `agentbox-home` volume. Recreating the container loses nothing, not even the
> fingerprint your phone already trusted.
>
> **What you install on top of the image is remembered and replayed.** A
> `sudo apt install postgresql-client`, a binary in `/usr/local/bin`, an edited
> file in `/etc`: recorded into the `agentbox-state` volume and put back on the
> next boot.

No volume is ever mounted over the image, so updating agentbox still brings you
a newer node, nvim, herdr and agents. `agentbox-persist status` shows what is
being kept; starting over means deleting both volumes (`make destroy`). Details
and backups in [docs/persistence.md](docs/persistence.md).

## Running it on Coolify or Dokploy

This is the case it was built for. Create a **Docker Compose** resource, point
it at this repository (or paste
[`deploy/docker-compose.ghcr.yml`](deploy/docker-compose.ghcr.yml) to pull the
prebuilt image — much faster on a small VPS), set `SSH_PUBLIC_KEY`, and publish
port `2222:22`. SSH is raw TCP, so the platform's HTTP proxy is not involved.

Step by step in [docs/deploy.md](docs/deploy.md).

## Security

The container refuses to boot with no key configured, accepts key
authentication only, and denies root login. You are still putting an SSH server
on the internet, though: the default port is `2222`, restrict the source in
your firewall, and if you can, expose nothing at all — put the host on a
Tailscale/WireGuard network and bind the port to the private address.

Two things deserve a read first: mounting the Docker socket grants
root-equivalent access **to the host**, and agent credentials sit in the volume
in plaintext. [docs/security.md](docs/security.md) has the rest.

## Customizing

- **Neovim config**: `image/skel/.config/nvim`. Your home always wins; a new
  image only adds files you don't have yet.
- **Herdr config**: `image/skel/.config/herdr/config.toml`
  (`herdr --default-config` prints every option).
- **Welcome banner**: `AGENTBOX_BANNER` in `.env` — `always` (default: every
  terminal and every herdr pane), `login` (only when you connect) or `off`;
  `AGENTBOX_BANNER_BY` changes the signature. The wordmark has three sizes and
  picks the one that fits — the big block letters need 90 columns, so a phone
  never gets a screenful of them.
- **More tools in the image**: edit the `Dockerfile`, run `make update`.
- **More tools without a rebuild**: `~/.agentbox/provision.sh`.
- **Pinned versions**: `NODE_VERSION`, `NVIM_VERSION`, `CLAUDE_CODE_VERSION`,
  `CODEX_VERSION`, `OPENCODE_VERSION` in `.env`.

## Documentation

- [Mobile use](docs/mobile.md) — SSH client, Herdr, Neovim on a small screen
- [Persistence](docs/persistence.md) — what survives, provisioning, backups
- [Deploy](docs/deploy.md) — VPS, Coolify, Dokploy, multiple boxes
- [Agents](docs/agents.md) — logging in, integrations, running several at once
- [Security](docs/security.md) — exposure, the Docker socket, blast radius

## Credits

[Herdr](https://herdr.dev) · [LazyVim](https://lazyvim.github.io) ·
[Claude Code](https://claude.com/claude-code) ·
[Codex](https://developers.openai.com/codex/cli) ·
[opencode](https://opencode.ai)

## License

MIT — see [LICENSE](LICENSE).
