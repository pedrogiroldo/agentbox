## Why

agentbox was built to live on a VPS someone already pays for, next to a
Coolify or Dokploy. On that kind of machine — two vCPUs, eight gigabytes,
a hundred gigabytes of disk shared with everything else — a box with a dozen
agents open freezes: Collie reports the herd as disconnected, the herdr TUI
stops drawing, and an SSH login never reaches a prompt. And the disk fills
without anyone installing anything.

Measured on exactly such a box, three things are going on, and none of them
is the daemons agentbox starts: those cost 230 MB and five percent of a core.

**The freeze is CPU starvation of the wrong processes.** Twelve Claude
sessions, ten of them resumed by herdr at boot, bring 450 forks per second of
status lines and hooks, 47% of CPU in kernel time, 15% stolen by the host,
and a pressure-stall figure saying that half the time some runnable task is
waiting. Memory pressure is near zero; no OOM kill has ever fired. In that
queue, `sshd`, the herdr server, Collie and the agents all sit at the same
priority in the same cgroup. Herdr's socket times out, Collie gives up after
five seconds, and the fifteen forks an SSH login needs never get scheduled
before the client quits. The operator wants every agent there after a
restart, so the fix is not fewer agents: it is making sure the handful of
processes needed to *see and act* never compete with the load. The container
is already privileged for its Docker daemon; the writable cgroup v2 tree that
comes with that is the primitive, unused.

**The box keeps every Collie it ever updated to, twice.** `collie update`
stages the new release beside the old one and tries to remove the old one by
renaming it into a trash directory. That fails with `EXDEV` on the version
the image shipped, because overlayfs cannot rename a directory out of the
image layer, and the leftovers are never revisited. Eight releases at 84 MB
each sit in `/opt/collie/versions`. Seven of them are newer than the image
build stamp, so `agentbox-persist` copies all 588 MB into the state volume
and rsyncs them back over the rootfs on every boot. The disk pays twice and
the boot pays in I/O, for a feature the docs promise as "the update survives
a recreate".

**Nine of the home's fourteen gigabytes are caches nobody asked to keep.**
npm, bun, uv and pnpm stores, npx leftovers from MCP servers, downloaded
browsers, and half a gigabyte of superseded plugin versions. Every one of
them is rebuildable and every tool has its own prune verb; the box just never
says so, and a VPS has no `make clean` to reach for.

## What Changes

### Control-plane isolation

- **Two cgroups under the container's root, created by the entrypoint before
  anything else starts.** `control` holds what the operator needs to get in
  and look around: tini, the entrypoint, `sshd`, the herdr server, Collie,
  `tailscaled`. `work` holds everything born inside a herdr pane: agents,
  their hooks and status lines, builds and tests. The Docker daemon keeps its
  own group so it can manage its containers' cgroups as it does today.
- **CPU: `control` outweighs `work` ten to one.** Under saturation the control
  plane gets the little it needs the moment it needs it; the agents slow down
  instead of the box going dark.
- **Memory: `control` has a floor, `work` has a ceiling.** `memory.min` keeps
  the control plane's pages from being reclaimed; `memory.high` on `work`
  throttles the agents before the whole box thrashes. Neither kills anything.
- **OOM ordering.** The herdr server gets an `oom_score_adj` as low as `sshd`
  already gives itself; Collie and `tailscaled` sit just above it. If the
  kernel ever has to kill something, it takes an agent, not the multiplexer
  that owns every pane.
- **Panes land in `work` through the shell herdr opens.** `agentbox-herdr`
  already sets the `SHELL` the server hands to new panes; it now points at a
  small wrapper that moves itself into `work` and `exec`s the user's real
  shell. Nothing about the interactive experience changes.
- **Two knobs, in the vocabulary `AGENTBOX_DOCKER` established.**
  `AGENTBOX_ISOLATION` picks the mechanism: `auto` (default: cgroups when the
  tree allows, `nice` otherwise), `cgroup`, `nice`, `off`.
  `AGENTBOX_CONTROL_RESERVE` is the memory kept for the control plane; its
  default is derived from the box's total memory, and `0` keeps only the CPU
  weights and OOM ordering.
- **Graceful degradation.** A container whose cgroup tree refuses
  `subtree_control` (no privileges, an unusual platform) boots exactly as
  today plus `nice` priorities and OOM ordering, with one warning that says
  why. `agentbox-cgroup status` reports which protections are actually in
  effect, not which were asked for.
- **The deploy docs ask the host for swap.** The box cannot add swap to a VPS
  that has none, but a 2 GB swapfile is what turns a freeze into a slowdown
  when the memory ceiling is reached. `docs/deploy.md` says so.

### Collie release pruning

- **The box keeps the current Collie and the one before it, and removes the
  rest.** It runs at boot, where the entrypoint already relinks the Collie
  plugin into herdr, and again from `agentbox-persist save`, so an update
  made from the phone is pruned before the next periodic save copies it.
  `rm -rf` succeeds where Collie's `rename` fails: overlayfs handles removal
  with a whiteout.
- **`agentbox-persist` stops copying superseded releases.** The pruned set
  is excluded from the overlay scan, so the state volume holds one or two
  Collies, not eight, and the boot restore is proportionally lighter.
- **Upstream is told.** An issue against Collie for the `EXDEV` fallback is
  filed alongside; the box's pruning does not depend on it landing.

### Disk hygiene: `agentbox-clean`

- **A new box command, `agentbox-clean`, that says before it does.** With no
  verb it prints a report: what is on the home and the state volume, how much
  each tier would free, and the size of what is *yours* and will never be
  touched — projects, worktrees, agent transcripts, credentials.
- **`agentbox-clean caches`** runs each tool's own prune (`npm cache clean`,
  `bun pm cache rm`, `uv cache prune`, `pnpm store prune`, `pip cache purge`),
  drops npx entries older than a week, superseded plugin versions, temp
  leftovers and the trash.
- **`agentbox-clean browsers`** and **`agentbox-clean docker`** are explicit
  verbs, because each breaks something until it is reinstalled or re-pulled.
  `agentbox-clean all` is the three together.
- **`make clean`** from the laptop runs the same report and verbs.
- **Nothing is deleted automatically.** When the home crosses a threshold,
  the motd gains one line naming the reclaimable amount and the command.
  `AGENTBOX_CLEAN_INTERVAL` exists for an operator who wants the `caches`
  tier on a timer, and defaults to off.

## Capabilities

### New Capabilities

- `control-plane-isolation`: the box keeps its control plane (SSH, the herdr
  server, Collie, the tailnet daemon) responsive under CPU and memory
  saturation caused by the workload running in its panes, using cgroup v2
  weights, memory floors and ceilings, and OOM ordering; and it reports which
  protections are in effect.
- `disk-hygiene`: the box reports what occupies its volumes, distinguishes
  rebuildable caches from the operator's data, reclaims the former only when
  asked, and prunes the release trees it manages itself so that its own
  persistence mechanism does not multiply them.

### Modified Capabilities

- `agent-session-service` (from `add-collie-mobile-ui`): the herdr server
  starts with the pane shell set to the isolation wrapper rather than the
  user's shell directly, and the server process itself runs inside the control
  cgroup with a protected OOM score. The observable requirement — panes open
  in the user's shell — is unchanged; the delta records where the shell comes
  from.
- `mobile-web-ui` (from `add-collie-mobile-ui`): an in-place `collie update`
  still survives a recreate, and now leaves at most the current release and
  its predecessor behind; the state volume never carries more than that.

## Impact

- `image/entrypoint.sh`: creates the cgroups and moves itself into `control`
  before starting any service; applies OOM scores after each service starts;
  prunes Collie releases where it already relinks the plugin.
- New `image/etc/cgroup.sh` (`agentbox-cgroup`): `setup`, `enter <group>`,
  `status`. The entrypoint and the pane wrapper both call it.
- New `image/etc/pane-shell.sh` (`agentbox-pane-shell`): the `SHELL` herdr
  opens panes with.
- New `image/etc/clean.sh` (`agentbox-clean`): report and verbs.
- `image/etc/herdr-server.sh`: hands `agentbox-pane-shell` to the server as
  `SHELL`, carrying the user's real shell alongside.
- `image/etc/dockerd.sh`: starts the daemon in its own cgroup.
- `image/etc/persist.sh`: prunes Collie releases before a save; excludes
  superseded ones from the overlay scan; moves its watcher into `work`.
- `image/etc/collie.sh`: a `prune` verb the entrypoint and persist call.
- `image/etc/sshrc` (new) and `image/etc/env.sh`: move an SSH session into `work`
  once the login is complete.
- `image/etc/make-motd.sh`, `image/etc/greet.sh`: the disk line.
- `Makefile`: `make clean`; `make shell` may need to enter `work` itself if
  `docker exec` cannot land in a root that has controllers enabled (the
  design's first spike).
- `docker-compose.yml`, `deploy/docker-compose.ghcr.yml`, `.env.example`:
  `AGENTBOX_ISOLATION`, `AGENTBOX_CONTROL_RESERVE`, `AGENTBOX_CLEAN_INTERVAL`.
- `docs/deploy.md`, `docs/security.md`, `docs/persistence.md`,
  `docs/collie.md`, new `docs/small-vps.md`: what is protected, what is not,
  the measured cost per agent session, why the host needs swap, what
  `agentbox-clean` will and will not touch, and what changes when the
  container is not privileged.
- `tests/`: a smoke test that saturates `work` and checks that an SSH login
  and a herdr status call still complete within a bound; a test that stages
  fake Collie releases and checks the prune and the overlay exclusion; a test
  that `agentbox-clean` with no verb deletes nothing.
- Interaction with the open `herdr-pane-shell` branch: both touch how the
  server receives `SHELL`. This change builds on that branch's mechanism
  rather than replacing it.
