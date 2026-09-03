## Why

The box is where the agents write code, but some code cannot be *run* there.
Android is the clearest case: the build needs the SDK, the emulator needs
hardware acceleration, and `adb` needs a USB cable plugged into a machine that
is not a VPS. Port forwarding solves the opposite problem — reaching a server
inside the box from outside — and does nothing for a Gradle build that has to
happen on the developer's own machine.

What is missing is a mirror: the same tree, live, on both sides. Mutagen already
does this well over plain SSH, which the box already speaks. The gap is not
capability, it is friction — knowing the URL syntax, the port, the right ignore
patterns for a Gradle project, and that the agent binary installs itself. Today
every user has to work that out alone.

## What Changes

- A new box command, `agentbox-mirror`, that turns "I want this project on my
  laptop" into one copy-pasteable command. It knows the box's SSH endpoint, the
  project's absolute path, and a curated ignore set, and it prints the exact
  `mutagen sync create` invocation to run locally.
- `agentbox-mirror check` reports whether the box is actually mirror-ready
  (SFTP subsystem, writable agent directory, a known endpoint) instead of
  letting the user discover it through a Mutagen error.
- `agentbox-mirror project` emits a ready-to-save `mutagen.yml` for people who
  prefer Mutagen's project files over ad-hoc sessions.
- Two new environment variables, `AGENTBOX_SSH_HOST` and `AGENTBOX_SSH_PORT`,
  so the box can name the endpoint a client outside it must dial. Published to
  interactive shells the same way `TZ` and `LANG` already are.
- `make mirror`, `make mirror-status` and `make unmirror` on the local side, for
  users who cloned this repository: they read the endpoint out of `.env` and
  drive the local Mutagen daemon directly.
- Documentation: a new `docs/mirror.md` covering the local install, the Android
  workflow specifically, ignores, and conflict behaviour; plus entries in both
  READMEs, the motd, `.env.example` and `docker-compose.yml`.
- A `tests/mirror.sh` smoke test in the style of `tests/docker.sh`.

Nothing is installed into the image. Mutagen's agent binary is copied *from* the
client at first connection and lands in `~/.mutagen`, which is already inside
the persistent home volume — so the box stays the same size and the agent
survives a recreate for free.

**No breaking changes.** Every new variable has a working default, and a box
that never mirrors behaves exactly as it does today.

## Capabilities

### New Capabilities

- `file-mirroring`: mirroring a project directory in the box onto a developer's
  own machine over SSH, so code written by agents in the cloud can be built and
  run against local hardware. Covers endpoint advertisement, the paste-ready
  command the box generates, readiness diagnostics, ignore defaults, and the
  local-side `make` targets.

### Modified Capabilities

<!-- None. This is the first capability spec in this repository, and no existing
     documented behaviour changes. -->

## Impact

- **New files**: `image/etc/mirror.sh` (installed as
  `/usr/local/bin/agentbox-mirror`), `docs/mirror.md`, `tests/mirror.sh`.
- **Modified files**: `Dockerfile` (copy + chmod the script), `image/entrypoint.sh`
  (publish the two new variables to `/etc/agentbox/config.env`),
  `image/etc/make-motd.sh` (one line), `docker-compose.yml`,
  `deploy/docker-compose.ghcr.yml`, `.env.example`, `Makefile`, `README.md`,
  `README.en.md`.
- **Dependencies**: none added to the image. Mutagen is a client-side
  prerequisite on the developer's machine, and `docs/mirror.md` covers
  installing it there.
- **Security**: no new listening port and no new privilege. A mirror runs over
  the SSH connection the user already has, as the user they already are.
  `docs/security.md` needs a sentence noting that a mirror puts the box's code
  on the laptop too.
- **Persistence**: none required. `~/.mutagen` lives in the home volume.
