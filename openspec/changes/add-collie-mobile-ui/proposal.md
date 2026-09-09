## Why

`docs/mobile.md` sells the box on a single promise: a phone is enough to check
on your agents. What it actually ships is a terminal on a phone — herdr driven
through `Ctrl+b` chords typed on a soft keyboard, with `Esc` hiding behind an
extra key row. It works, and it is the reason the box exists, but nobody would
design that interface on purpose for a six-inch screen.

[Collie](https://github.com/AltanS/collie) is the interface someone did design
on purpose: a mobile web UI that mirrors a multiplexer, sorts agents by *who is
waiting on you* rather than by recent output, turns an agent's own permission
prompt into tappable buttons, and pushes a notification when an agent blocks.
Herdr is its primary supported backend in 1.0 — the same herdr this image
already installs.

The other half of the reason is that Collie's default deployment turns out to
work *unchanged* inside this container: `tailscaled` in userspace-networking
mode needs no TUN device, and `tailscale serve` terminates inside the container
that runs it. So the box can offer Collie exactly as its authors intended —
bound to loopback, no published port, TLS and identity handled on the tailnet —
rather than as a thing bolted onto a network shape it was not built for.

What is missing is that every one of those pieces is currently the user's to
discover, install by hand, and start with `sudo nohup`. Nothing puts them back
after a recreate.

## What Changes

- **Collie ships in the image**, installed into `/opt/collie` with the binary
  linked onto the PATH, the same way herdr, Neovim and the three agents are
  baked in rather than fetched at boot. `COLLIE_VERSION` pins it.
- **Tailscale ships in the image too**, because without a tailnet Collie has no
  front door and this box has no other one to offer it. `tailscaled` runs in
  **userspace networking**: no TUN device, no `NET_ADMIN`, nothing added to what
  the container already needs.
- **A new box service, `agentbox-tailscaled`**, modelled on `agentbox-dockerd`:
  `ensure`, `start`, `stop`, `status`. It brings the daemon up, authenticates
  from `TS_AUTHKEY` when the box is not already a member, and sets `dev` as the
  tailnet operator so Collie can manage `tailscale serve` without sudo.
- **The tailnet identity survives a recreate.** Tailscale's state goes into the
  box's state volume rather than `/var/lib/tailscale` on the container
  filesystem, so a recreated box comes back as the same node instead of asking
  to be authenticated again.
- **Herdr learns about Collie on boot.** The entrypoint runs
  `herdr plugin link /opt/collie/current` alongside the existing
  `herdr integration install` loop, so Collie's start/stop/status buttons show
  up inside herdr, and `make update` becomes the update path exactly as it
  already is for the agents.
- **A new box service, `agentbox-collie`**, with the same four verbs, delegating
  to `collie start` / `collie stop` so that the box and herdr's own plugin
  buttons drive one process rather than two.
- **`AGENTBOX_COLLIE` decides whether it runs**, borrowing the vocabulary
  `AGENTBOX_DOCKER` already established: `off` (default), `auto`, `on`.
  Installed always, started never, until the operator asks — because a running
  Collie is remote shell access, and its read surface is open to anything on the
  tailnet that reaches the URL.
- **Herdr becomes a service that starts at boot**, not a program you start after
  logging in over SSH. Without a running herdr server there is no multiplexer
  for Collie to mirror, and `herdr plugin link` has no socket to talk to.
  `AGENTBOX_HERDR_SERVER` can turn it off.
- **No new published port, and no compose changes for networking.** Collie stays
  on loopback and `tailscale serve` reaches it from inside the same container.
  This is the shape the box already recommends for SSH in `docs/security.md`,
  arrived at from the other direction.
- **Documentation**: a new `docs/collie.md`; a new `docs/tailscale.md`; a section
  in `docs/mobile.md` framing the two mobile front doors; and a section in
  `docs/security.md` stating plainly that Collie's device gates protect writes
  only, that reads are open to the tailnet, and that the write gate does not
  exist until the first device is paired.
- **`tests/collie.sh`**, in the style of `tests/docker.sh`.

**No breaking changes.** `AGENTBOX_COLLIE` and `AGENTBOX_TAILSCALE` both default
to `off`, so a box that ignores this feature gains two idle binaries and nothing
else. The herdr server at boot is the one behavioural change to an existing
default, and it is additive: a session started by the service is the same session
`herdr` would have created.

## Capabilities

### New Capabilities

- `mobile-web-ui`: reaching the box's agents from a phone browser instead of a
  phone terminal. Covers Collie's presence in the image, the herdr plugin link,
  the `agentbox-collie` service and its lifecycle states, the front door it
  depends on, and the security posture the box commits to.
- `tailnet-membership`: the box joining a private network as a node of its own,
  and serving things on it, without a published port and without privileges
  beyond what it already has. Covers the daemon's lifecycle, headless
  authentication, operator delegation, state that survives a recreate, and the
  escape hatch.
- `agent-session-service`: herdr running as a box service from boot rather than
  as a program started by an SSH login, so agents and the panes that host them
  exist before anyone connects.

### Modified Capabilities

<!-- None. This repository has no archived capability specs yet, and no
     documented behaviour of an existing capability changes. -->

## Impact

- **New files**: `image/etc/collie.sh` (as `/usr/local/bin/agentbox-collie`),
  `image/etc/tailscaled.sh` (as `/usr/local/bin/agentbox-tailscaled`),
  `image/etc/herdr-server.sh` (as `/usr/local/bin/agentbox-herdr`),
  `docs/collie.md`, `docs/tailscale.md`, `tests/collie.sh`.
- **Modified files**: `Dockerfile` (`COLLIE_VERSION` and `INSTALL_TAILSCALE`
  args, the two installs, copy + chmod the three scripts), `image/entrypoint.sh`
  (tailscaled, the herdr server, the plugin link, the Collie step, and the new
  variables published to `/etc/agentbox/config.env`), `docker-compose.yml`,
  `deploy/docker-compose.ghcr.yml`, `.env.example`, `Makefile`,
  `docs/mobile.md`, `docs/security.md`, `docs/persistence.md`, `README.md`,
  `README.en.md`, `.github/workflows/docker-image.yml`.
- **Dependencies**: Collie and Tailscale are added to the image. Collie's
  release ships a compiled binary and prebuilt web assets and needs no
  toolchain; Tailscale comes from its own apt repository, which means
  `agentbox-persist` replays it after a recreate like any other package.
- **No new listening port and no new capability.** This is the change's best
  property and the reason to prefer it: Collie binds loopback, `tailscale serve`
  reaches it inside the same network namespace, and userspace networking needs
  neither `/dev/net/tun` nor `NET_ADMIN`. Nothing is added to `ports:`.
- **A new outbound relationship.** The box talks to Tailscale's control plane
  and becomes reachable by every node on the tailnet. That is the boundary the
  whole design rests on, and `docs/security.md` says so.
- **Security**: Collie hands arbitrary keystrokes to a live pane in a box that
  runs `privileged: true`. `docs/security.md` gains a section, and the default
  of `off` for both services is part of the change, not an afterthought.
- **Persistence**: `/opt/collie` falls under the existing system-layer contract.
  Tailscale's node state does not — `/var/lib` is not watched — so it moves into
  the state volume, which is a change `docs/persistence.md` has to describe.
  Collie's own state lives in the home volume and needs no new arrangement.
