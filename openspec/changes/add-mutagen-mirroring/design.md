## Context

See `proposal.md` for motivation. The constraints that shape the approach:

- **Mutagen is a client-side tool.** The daemon, the session registry and the
  configuration all live on the developer's machine. The box is only ever the
  *beta* endpoint of a session it does not own and cannot enumerate. Nothing
  inside the box can list, pause or terminate a session.
- **The remote side needs nothing installed.** Mutagen copies its own agent
  binary over `scp` — which on OpenSSH 9.x means the SFTP subsystem — into
  `~/.mutagen/agents/<version>/`. The image already enables that subsystem
  (`image/etc/sshd_config:42`), and `~/.mutagen` lands inside the `agentbox-home`
  volume, so the persistence contract covers it with no work.
- **The box cannot know its own address.** Port publishing, Coolify's proxy and
  any Tailscale address all happen on the host. This is the one fact the box
  needs and cannot derive.
- **sshd builds a fresh environment.** Anything set in `docker-compose.yml` is
  invisible over SSH unless the entrypoint writes it to
  `/etc/agentbox/config.env` — the existing mechanism at
  `image/entrypoint.sh:91-100`.
- **House style.** Box-side helpers are single bash scripts named
  `agentbox-<thing>`, installed into `/usr/local/bin`, with a verb as `$1` and a
  header comment that explains the reasoning rather than the API. See
  `image/etc/dockerd.sh` and `image/etc/persist.sh`.

## Goals / Non-Goals

**Goals:**

- One command in the box turns "I want this on my laptop" into one command to
  paste on the laptop, correct on the first try.
- The box says out loud what a developer would otherwise learn from a Mutagen
  error: missing SFTP, unwritable agent directory, unknown host.
- Zero bytes added to the image and zero new runtime surface.
- Sensible ignores by default, with Android specifically covered.

**Non-Goals:**

- Managing sessions from inside the box. Mutagen's own architecture puts them on
  the client; a box-side `agentbox-mirror status` would be a lie it cannot tell
  honestly.
- Bundling or vendoring the Mutagen CLI or its agent binary. Version skew
  between a baked agent and a client CLI is a support burden that buys nothing —
  the client installs a matching agent in seconds.
- Replacing SSH port forwarding. Mirroring and forwarding solve opposite
  problems and both stay documented.
- Any alternative sync engine (Syncthing, `unison`, `rsync` loops). One tool,
  chosen deliberately below.

## Decisions

### The box generates commands; it does not run Mutagen

`agentbox-mirror` prints; the developer pastes. No Mutagen binary is installed
in the image, no daemon runs in the box, and the box never tries to reach out to
the laptop.

*Why:* it matches how Mutagen actually works — the session is created and owned
by the client — and it means the feature costs the image nothing. It also works
from a phone: `ssh box agentbox-mirror myapp` prints the command, which is then
pasted on the laptop later.

*Alternative considered:* installing the Mutagen CLI in the box and having it
create sessions in reverse (box as alpha, laptop as beta). Rejected: it requires
the box to SSH *into* the laptop, which means the laptop needs a reachable SSH
server and a key the box holds. That is a much larger security story for a
strictly worse ergonomic one.

### The endpoint comes from two new environment variables

`AGENTBOX_SSH_HOST` (no default) and `AGENTBOX_SSH_PORT` (default `2222`),
published to interactive shells through the existing `config.env` loop.

*Why:* the host is genuinely unknowable from inside; the port is knowable but
only as `22`, which is the wrong answer — what a client dials is the published
port. `2222` matches the shipped compose file and `.env.example`, so the default
is right for the default deployment.

When the host is unset the printed command carries a visible placeholder
(`<your-server>`) plus a line naming the variable. Refusing to print at all
would be worse: a developer who knows their own address just wants the rest of
the command.

*Alternative considered:* deriving the host from `SSH_CONNECTION` in the current
session. Tempting, and it works when you SSH in directly — but it yields the
proxy's or the Docker bridge's address behind Coolify, silently, which is worse
than a placeholder that is obviously a placeholder. It may be used as a *hint*
in the check output, never as the printed endpoint.

### One script, `agentbox-mirror`, with a verb-or-project first argument

```
agentbox-mirror                overview + the projects available to mirror
agentbox-mirror <project>      the paste-ready `mutagen sync create` command
agentbox-mirror project <name> a mutagen.yml on stdout
agentbox-mirror check          readiness diagnostics
```

The first argument is a verb when it matches one of the reserved words, and a
project otherwise. Reserved words are checked against the projects directory
first, so a project genuinely named `check` still resolves — with a note.

*Why:* `agentbox-mirror myapp` is the shortest thing that can work, and it is
the call that will be made ninety percent of the time. The verbs are rare enough
to accept the collision handling.

### Remote paths are absolute, local paths are a placeholder

The remote endpoint is always `dev@<host>:<port>:/absolute/path`. The local side
is printed as `~/path/to/myapp` with a line telling the developer to replace it.

*Why:* Mutagen's SCP-like syntax (`[<user>@]<host>[:<port>]:<path>`) resolves a
relative remote path against the remote home, which is right here but fragile if
`AGENTBOX_USER` is ever changed; absolute is unambiguous. The local path cannot
be guessed at all, and a placeholder that must be edited is better than a
plausible wrong default that silently mirrors into the wrong directory.

### Ignores are a curated list in the script, VCS explicitly included

A single list constant, passed as one `--ignore=a,b,c` argument, covering at
minimum: `node_modules/`, `.venv/`, `__pycache__/`, `target/`, `build/`,
`.gradle/`, `.cxx/`, `local.properties`, `dist/`, `.next/`, `.DS_Store`,
`*.swp`.

`--ignore-vcs` is deliberately **not** passed.

*Why:* the whole point is running the code locally, which means `git` locally,
which means `.git` must cross. Mutagen's own guidance to ignore VCS directories
targets the case where both ends run independent git operations — not this one.
`build/` and `.gradle/` are the Android-specific half: a Gradle build directory
is hundreds of megabytes of machine-specific output, and `local.properties`
holds the *local* SDK path, which must differ on the two sides by definition.

*Trade-off:* the list is a guess for any given project. `docs/mirror.md` shows
how to add to it, and the `mutagen.yml` output exists precisely so a project can
own its own list.

### `check` verifies what it can and warns about what it cannot

Three checks: the SFTP subsystem is configured in the running sshd config; the
agent directory (`~/.mutagen`, or its parent if absent) is writable by the login
user; a host is configured. The first two are failures, the third a warning.

*Why:* the first two make a mirror impossible and are cheaply verifiable from
inside. The third is unverifiable — the box cannot test whether an address
outside it resolves — so failing on it would be the box asserting something it
does not know.

### The local side is `make`, not a shipped script

`make mirror PROJECT=<name> LOCAL=<path>`, `make mirror-status`,
`make unmirror PROJECT=<name>`, reading `SSH_PORT` and a new `AGENTBOX_SSH_HOST`
out of `.env` with the existing `env_value` helper (`Makefile:8`).

*Why:* the Makefile is already the local-side surface of this repository and
already parses `.env`. A separate `scripts/mirror.sh` would duplicate that for
no gain. `make mirror-status` filters `mutagen sync list` to sessions whose name
carries the box's prefix, so it reports on this box rather than every session on
the machine.

The targets check `command -v mutagen` first and print the install line for the
platform on failure.

### Documentation lands in a new `docs/mirror.md`

English, matching its siblings, linked from both READMEs' documentation index
and named in the motd. It carries: installing Mutagen per platform, the Android
walkthrough end to end, the ignore defaults and how to extend them, conflict
behaviour under `two-way-safe`, and when to prefer port forwarding instead.

`docs/security.md` gains a sentence: a mirror copies the box's code — including
anything an agent checked out — onto the laptop, and the laptop is now part of
the box's blast radius.

### Sync mode stays Mutagen's default, `two-way-safe`

*Why:* both sides legitimately write — the agent in the box, the developer
locally fixing a build error. `two-way-safe` propagates both directions and
refuses to resolve a conflict in a way that loses data, leaving the file flagged
instead. `one-way-replica` from the box would silently discard local fixes;
`two-way-resolved` would silently pick a winner. The safe default is the one
whose failure mode is "you must look at this", which is correct when an
autonomous agent is one of the two writers.

## Risks / Trade-offs

- **A developer mirrors a huge tree and saturates the link** → the ignore
  defaults remove the usual offenders; `docs/mirror.md` tells them to check with
  `mutagen sync monitor` on the first sync and to add ignores before, not after.
- **The two sides conflict while an agent is mid-edit** → `two-way-safe` flags
  rather than resolves. Documented, with the "stop the agent before a large
  local refactor" advice that follows from it.
- **`AGENTBOX_SSH_HOST` goes stale after the box moves** → it is only ever used
  to *print* a command; a wrong value produces a connection error at paste time,
  not a silent mis-sync.
- **Mutagen version skew between laptops sharing a box** → each client installs
  its own agent version side by side under `~/.mutagen/agents/`. Costs a few
  megabytes in the home volume and nothing else.
- **A collision between a verb and a project name** → resolved toward the
  project, with a note printed. Worst case a developer with a project called
  `check` types one extra `./` to disambiguate.
- **`make mirror-status` depends on the session-name prefix** → a developer who
  renames a session by hand drops out of that view. It is a convenience filter,
  not bookkeeping; `mutagen sync list` remains the source of truth and the docs
  say so.
- **Mutagen is a third-party dependency the developer must install** → it is
  client-side only, so a broken or unavailable Mutagen affects nobody's box. If
  the tool is ever abandoned, `agentbox-mirror` is one script to retarget at a
  successor, and nothing in the image has to change.

## Migration Plan

Additive. No migration, no rollback procedure beyond reverting the commit.

- Existing boxes gain the command on their next image update. A box that never
  sets `AGENTBOX_SSH_HOST` behaves exactly as before and prints a placeholder if
  the command is ever run.
- The two new variables have no effect on boot; a box that ignores them boots
  identically.
- `tests/mirror.sh` runs in the same shape as `tests/docker.sh`: boot the image,
  assert `check` passes, assert the printed command contains the expected
  endpoint and ignores, assert a missing project exits non-zero. Wired into the
  CI workflow alongside the existing smoke tests.
