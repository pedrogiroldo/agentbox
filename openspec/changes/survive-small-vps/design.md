## Context

See `proposal.md — Why` for motivation. The numbers below are from the box
this was diagnosed on, and they shape every decision that follows.

**What the box costs, and what the load costs.** The services agentbox starts
are cheap; the panes are not, and their cost is mostly invisible background
work rather than agents thinking:

```
  RSS on a 2 vCPU / 8 GB box, twelve Claude sessions open
  +---------------------------------------------------------------+
  | claude x12  (ten of them resumed by herdr at boot)   4.2 GB   |
  | per-session hook servers and workers                 1.6 GB   |
  | user's own dev servers and MCPs                      0.5 GB   |
  | tini, sshd, herdr server, collie, tailscaled,                 |
  |   dockerd, containerd, persist watcher               0.23 GB  |
  +---------------------------------------------------------------+

  CPU on the same box
    forks/s                          453   (status lines at 1 s, hooks per tool call)
    kernel time                      47%
    stolen by the host               12-17%
    PSI cpu "some", 60 s average     45%   (half the time a runnable task waits)
    PSI memory "some"                0.3%
    OOM kills, ever                  0

  Disk on the same box
    rootfs (image + writable layer)  3.6 GB   of which /opt/collie 672 MB, eight releases
    state volume                     1.0 GB   overlay 632 MB (588 MB of it Collie), apt 358 MB
    home                             14 GB    ~9 GB rebuildable caches, ~5 GB the operator's
```

The freeze is scheduling, not memory: the herdr server logs
`api connection failed err=timed out reading api request`, Collie logs
`herdr session.snapshot: timed out after 5000ms` and marks itself
disconnected, and an SSH login — a chain of roughly fifteen forks through
`sshd`, PAM, bash, `env.sh`, `greet.sh`, the banner and `tput` — never gets
its turn before the client gives up.

**What the container already has.** Inside the box, `/sys/fs/cgroup` is a
writable cgroup v2 tree with `cpu`, `memory`, `io` and `pids` in
`cgroup.controllers` and nothing in `cgroup.subtree_control`. All 67 processes
sit in its root at nice 0. `sshd` gives itself `oom_score_adj -1000`; the herdr
server, Collie and `tailscaled` sit at 0. The writable tree is a side effect of
`privileged: true`, which the box already requires for its Docker daemon
(`docs/docker.md`). So the primitive exists, unused, at no new privilege.

**Where panes come from.** `agentbox-herdr` launches the server with an
explicit `SHELL` (the passwd shell of the box user; the `herdr-pane-shell`
branch). The server opens every pane with that shell. That single variable is
the seam through which every pane process can be routed.

**How Collie releases pile up.** `/opt/collie/current` is a symlink into
`/opt/collie/versions/<v>`. `collie update` stages the next release beside
the current one and moves the old one into `/opt/collie/.trash` with
`rename(2)`. The release the image shipped is a directory in the overlayfs
lower layer; renaming such a directory needs `redirect_dir`, which Docker's
overlay does not enable, so it fails with `EXDEV`. Collie logs "it is
harmless where it is" and never revisits. Whether its cleanup then skips the
newer leftovers or only ever targets the oldest cannot be read from a
compiled binary; either way, seven superseded releases remained here. All
seven postdate the image build stamp, which is `agentbox-persist`'s sole
criterion for "yours", so all seven are in the overlay and are rsynced back
at every boot.

**What the home holds.** Every large cache has an owner with a prune verb:
npm (`_cacache`, and `_npx` entries keyed by hash with a mtime), bun
(`~/.bun/install/cache`), uv (`~/.cache/uv`), pnpm (`~/.local/share/pnpm`),
pip, Playwright's browsers (`~/.cache/ms-playwright`), and Claude Code's
plugin cache, which keeps one directory per installed version and here holds
a 474 MB superseded one next to an 11 MB current one. None of that is
recorded anywhere the operator can see without `du`. The things that are
*not* cache — `~/projects`, `~/.herdr/worktrees`, `~/.claude/projects`
(the transcripts `--resume` and herdr's resume read), `~/.claude-mem`,
credentials — sit in the same tree.

**Constraints that shape the approach.**

- The operator wants every agent resumed after a restart. Reducing the load is
  out; making the box survive it is in.
- cgroup v2's *no internal processes* rule: a non-root cgroup may enable
  controllers for its children only while it holds no processes itself. The
  container's root is a non-root cgroup on the host, so the rule applies to
  it. Everything must leave the root before `subtree_control` is written.
- Anything that lands in the root later — most importantly `docker exec`, the
  box's `make shell` rescue hatch — has to be shown to still work once the
  root has controllers enabled. This is the one thing the design cannot prove
  from the armchair.
- `tini` is pid 1 and stays wherever it is put; the entrypoint is pid 7 and
  spawns everything else, so cgroup membership is inherited from it.
- The box must keep booting, unchanged, on a host that refuses any of this.
- `docs/collie.md` promises that an in-place `collie update` survives a
  recreate. Pruning must keep that promise.
- The box's verbs say what they are doing and never act on the operator's
  data without being asked (`agentbox-persist forget`, `make destroy` typing
  the volume name). `agentbox-clean` inherits that stance.

## Goals / Non-Goals

**Goals:**

- Under CPU saturation caused by pane workload, an SSH login, a `herdr`
  attach and a Collie snapshot complete within a bounded time.
- Under memory pressure, the workload is throttled before the control plane
  is reclaimed, and the OOM killer's first choice is never `sshd`, the herdr
  server, Collie or `tailscaled`.
- The interactive experience inside a pane is unchanged: same shell, same
  `$SHELL`, same environment, same herdr integrations.
- One command answers "which protections are on, and why not".
- A container that cannot do this boots as it does today.
- `/opt/collie` holds at most two releases, the state volume mirrors that,
  and an in-place update still survives a recreate.
- One command answers "what is on this disk, what of it is mine, and what can
  go", and reclaims the rebuildable part only when told to.

**Non-Goals:**

- Reducing the workload. Status-line intervals, hook plugins, how many agents
  herdr resumes and how many sessions fit in a vCPU are the operator's
  choices; `docs/small-vps.md` states the measured cost per session and
  stops there.
- I/O weighting. Nothing measured points at I/O; `io.weight` stays default
  and can be added later without touching the structure.
- Per-pane or per-agent limits. One `work` group is the unit; splitting it
  further is a later change if one pane ever starves the others.
- Protecting the container from the *host*: steal time and a host without
  swap are outside the box. The deploy docs ask for swap; they cannot add it.
- Non-privileged containers. They get the `nice` fallback and a warning;
  making cgroups work without `CAP_SYS_ADMIN` is not attempted.
- Shrinking the image. The toolchain, the three agents and the Docker
  engine are separate trade-offs with their own build args; a slim image
  profile is a different change.
- Touching the operator's data, ever. Projects, worktrees, transcripts,
  memory databases and credentials are reported by size and left alone.
  The apt archive in the state volume stays too: it is the offline replay
  cache, and `autoclean` would free one `.deb` of 168.
- Fixing Collie's updater. An upstream issue is filed; the box does not wait.

## Decisions

### D1. cgroup v2 weights, not `nice`, as the primary mechanism

`nice` only shapes CPU, and it is per process: anything that resets its own
priority, or that is started by a path the box does not control, escapes it.
A cgroup is inherited by every descendant, survives `setsid` and `exec`, and
carries memory and pid limits in the same structure. The measured freeze is
CPU today, but the box has no swap, so the memory ceiling is what keeps the
next freeze from being a thrash instead.

`nice` is kept as the **fallback** for a tree that refuses `subtree_control`:
`sshd`, the herdr server, Collie and `tailscaled` get `nice -10` and the
OOM scores still apply. Weaker, structurally risk-free, and the same code
path answers `AGENTBOX_ISOLATION=nice` for an operator who wants it.

*Alternatives considered.* A watcher that renices processes named `claude`,
`node`, `bun` every few seconds: fights the workload rather than shaping it,
misses everything it does not know the name of, and adds forks to a box that
is dying of forks. Compose-level `deploy.resources.limits`: caps the whole
container, `sshd` included, which is the opposite of the goal.

### D2. Three groups: `control`, `work`, `docker`

```
  /sys/fs/cgroup                         subtree_control: +cpu +memory +pids
  |
  +-- control/   cpu.weight 1000   memory.min <reserve>    pids.max max
  |     tini, entrypoint, sshd (and every login's fork chain), herdr server,
  |     collie, tailscaled
  |
  +-- work/      cpu.weight 100    memory.high <total - reserve>   pids.max <cap>
  |     every herdr pane and everything it spawns; the persist watcher;
  |     interactive SSH shells once they are up
  |
  +-- docker/    cpu.weight 100    (defaults otherwise)
        dockerd, containerd, and the cgroups dockerd creates for containers
```

Two groups would do for CPU. The third exists because `dockerd` creates and
manages cgroups for the containers it runs, under its own position in the
tree; starting it inside `work` would put user containers under `work`'s
memory ceiling with no way to reason about which of the two is being
throttled, and starting it inside `control` would let a container run at the
control plane's weight. Its own sibling with default weights keeps today's
behaviour for containers exactly.

`memory.min` on `control` rather than `memory.low`: `min` is a hard floor the
kernel will not reclaim below; `low` is best effort. The control plane's
working set is small and the whole point is that it is never paged out.

`memory.high` on `work` rather than `memory.max`: `high` throttles by forcing
reclaim in the offending group; `max` invokes the OOM killer inside it. An
agent slowed down still finishes; an agent killed loses its conversation. The
OOM ordering (D5) covers the case `high` cannot.

### D3. The entrypoint leaves the root first, then enables controllers

Order at boot, before any service starts:

1. `agentbox-cgroup setup` creates the three groups, writes the weights and
   limits, moves pid 1 (`tini`) and itself (the entrypoint) into `control`,
   then writes `+cpu +memory +pids` to the root's `subtree_control`.
2. Every service the entrypoint starts afterwards inherits `control`.
3. `agentbox-dockerd start` moves itself into `docker` before launching the
   daemon; the daemon and its containers descend from there.
4. `agentbox-persist watch` moves itself into `work`: it is housekeeping, and
   its five-minute `find` over `/usr/local` and `/opt` is exactly the kind of
   burst the control plane should not carry.

If step 1 fails at any point — `mkdir` refused, `subtree_control` rejected
with `EBUSY` or `EACCES` — it undoes what it did, prints one warning naming
the file that refused, and the entrypoint continues in `nice` mode. The box
never fails to boot over this.

### D4. Panes enter `work` through the shell herdr opens

`agentbox-herdr` launches the server with `SHELL=/usr/local/bin/agentbox-pane-shell`
and `AGENTBOX_PANE_SHELL=<the user's passwd shell>`. The wrapper:

1. moves its own pid into `work` (`agentbox-cgroup enter work`),
2. restores `SHELL` to the real shell so nothing inside the pane sees the
   wrapper,
3. `exec`s that shell with whatever arguments herdr passed.

Cgroup membership survives `exec`, so the shell and every process it starts
are in `work` with no further cooperation. `setsid`, `nohup` and daemonising
do not escape a cgroup.

Moving a process between cgroups needs write access to the destination's
`cgroup.procs` and to the common ancestor's, which here is the root. Rather
than hand the box user write access to the root's `cgroup.procs`, the wrapper
calls `agentbox-cgroup enter` through the passwordless `sudo` the box already
grants. One `sudo` per pane open is noise next to what a pane does next. When
`sudo` is unavailable or the enter fails, the wrapper still `exec`s the shell:
a pane that opens in the wrong group beats a pane that does not open.

Interactive SSH shells take the same route, from `env.sh`, for the box user
only: the login's fork chain runs in `control` and is fast, and the shell moves
to `work` as its first act, so a build started over SSH is workload, not
control plane. Root shells (`make root`, `docker exec`) are left where they
are.

*Alternatives considered.* A herdr-side hook or per-pane command prefix: herdr
has no such option today, and depending on one couples the box to a herdr
release. `chown` on the cgroup files: gives the user the ability to move
anything into `control`, which is a way to defeat the feature by accident. A
PAM session module (`pam_cgroup` style): only covers SSH, not panes, and adds
a dependency for the smaller half of the problem.

### D5. OOM ordering for the control plane

After each service starts, the entrypoint sets `oom_score_adj`: `-1000` on the
herdr server (it already is on `sshd`, by `sshd`'s own hand), `-900` on Collie
and `tailscaled`, and nothing on anything in `work`. Killing the herdr server
kills every pane at once; killing one agent loses one conversation. The
ordering says which the kernel should prefer. This is independent of cgroups
and applies in every mode, including `nice`.

### D6. Isolation knobs, same vocabulary as `AGENTBOX_DOCKER`

- `AGENTBOX_ISOLATION`: `auto` (default: cgroups when the tree allows, `nice`
  otherwise), `cgroup` (cgroups or a fatal error, for deploys that must have
  it), `nice`, `off`.
- `AGENTBOX_CONTROL_RESERVE`: memory kept for the control plane, e.g. `512M`.
  Default is derived: 10% of the box's memory, clamped to `[384M, 1G]`, where
  the box's memory is `memory.max` of the container when set and `MemTotal`
  otherwise. `0` disables the memory floor and ceiling and keeps the CPU
  weights. The control plane measured 230 MB RSS; the reserve also covers
  login shells, a herdr client and the page cache its binaries live in.

The CPU weights are not knobs. 10:1 is the ratio at which the control plane's
latency is protected without making the workload feel throttled when the box
is idle, and there is no measured reason to expose it.

### D7. `agentbox-cgroup status` reports the truth, not the intent

Four lines: mode in effect, whether the CPU weights are live, whether the
memory floor and ceiling are live and what they are, and whether the OOM
scores are set. In `nice` mode it says which file refused and why. The
existing `agentbox-*` status verbs each say what the box is doing, not what
it was told to do; this one follows.

### D8. The box prunes Collie releases; Collie is not asked to

The rule: keep the release `current` resolves to and the newest one older
than it, remove every other directory under `/opt/collie/versions` and
whatever is in `/opt/collie/.trash`. `rm -rf`, as root, which overlayfs
honours with a whiteout where `rename` refused. Two places call it:

- the entrypoint, right where it already relinks the Collie plugin into herdr
  after a boot — the same moment an in-place update from the previous
  session becomes visible to the box;
- `agentbox-persist save`, before the scan, so an update made from the phone
  at 14:02 is pruned by the 14:05 save rather than copied into the overlay
  and pruned at the next boot.

Keeping one predecessor costs 84 MB and is the rollback an operator would
want after an update that broke something on the phone. Keeping none would
save that and cost the option.

`agentbox-persist` learns to exclude the pruned set from its scan, and its
`restore` learns that a release present in the overlay but no longer in
`/opt/collie/versions` after the prune is stale: it is removed from the
overlay rather than laid back down. That is the only place the overlay is
ever edited by anything other than `save` and `forget`, and it is confined
to `/opt/collie/versions`.

*Alternatives considered.* Excluding non-current versions from the overlay
only: the state volume gets small, the rootfs keeps 600 MB of dead releases
until the next recreate. Adding `/opt/collie/versions` to `PRUNED` outright:
breaks the promise in `docs/collie.md`, since the in-place update would no
longer survive a recreate. Waiting for Collie to fall back to `rm -rf` on
`EXDEV`: correct upstream, and filed, but the box cannot depend on a release
schedule it does not own, and the persist-side doubling would remain even
with the fix.

### D9. `agentbox-clean`: report by default, verbs to act, tiers by blast radius

```
  agentbox-clean                what is where, what each verb would free,
                                what is yours and stays
  agentbox-clean caches         rebuildable, nothing breaks
  agentbox-clean browsers       rebuildable, tests break until reinstalled
  agentbox-clean docker         dangling images/containers in the box's daemon
  agentbox-clean all            the three above
  agentbox-clean --dry-run <v>  the report for one verb
```

Each tier is a list of `(path, how to measure, how to reclaim)` and the
report is generated from the same list the verbs run, so the two cannot
drift. `caches` prefers each tool's own verb (`npm cache clean --force`,
`bun pm cache rm`, `uv cache prune`, `pnpm store prune`, `pip cache purge`)
because the tool knows which entries are still referenced; where a tool has
none, the rule is written down: `~/.npm/_npx/*` older than seven days by
mtime, plugin cache directories whose version is not the one
`installed_plugins.json` names, `~/.claude.json.tmp.*`,
`~/.local/share/Trash`.

The "yours" section is a fixed list, reported and never acted on:
`~/projects`, `~/.herdr/worktrees` (with `git worktree list` output so the
operator can prune with git), `~/.claude/projects`, `~/.codex`,
`~/.config/opencode`, `~/.claude-mem`, `~/.ssh`, and the state volume's apt
archive. A path not on either list is not touched and not reported beyond
the home's total; the tiers grow by adding entries, not by heuristics.

`make clean` on the laptop is `docker exec` into the same command, so the
VPS operator and the local one see one report.

*Alternatives considered.* A size-threshold auto-clean at boot: silently
deleting a cache the operator is mid-build on, on the one machine they
cannot watch, is the wrong default for a box whose other verbs all say
before they do. A cron inside the box: same objection; offered as
`AGENTBOX_CLEAN_INTERVAL`, default off, `caches` tier only, log in the
state volume. `docker system prune` for the box's daemon by default: those
are the operator's images, and a `-a` would delete the ones their compose
files are about to use.

### D10. The motd says when it is time

`greet.sh` already decides whether the terminal is wide enough for the
summary. It gains one conditional line, computed from a cached figure the
persist watcher refreshes on its five-minute pass rather than by a `du` at
every login: when the home exceeds `AGENTBOX_CLEAN_WARN` (default `20G`)
or the rebuildable share exceeds half of it, the line reads

```
  home 14 GB, 9 GB of it rebuildable — agentbox-clean shows what
```

and nothing otherwise. The threshold is a knob because a 40 GB VPS and a
400 GB one have different ideas of "full".

## Risks / Trade-offs

- **`docker exec` may fail with `EBUSY` once the root has `subtree_control`**
  → This is the spike that has to happen before anything else is built:
  enable the controllers by hand in a test container, `docker exec` into it.
  Recent `runc` handles the systemd-in-a-container case, which is the same
  shape, but this design does not assume it. If it fails, `make shell` moves
  its process into `work` first (`docker exec` cannot pick a cgroup, but the
  command it runs can), and the CI smoke test guards it either way.

- **The shell wrapper changes what `$SHELL` looks like to herdr** → herdr
  reads `$SHELL` to decide what to spawn; if it also inspects the basename to
  choose login flags or a prompt integration, the wrapper's name hides that.
  Mitigation: the wrapper passes every argument through untouched, restores
  `SHELL` before `exec`, and the Collie and herdr smoke tests assert that a
  pane's shell is the passwd shell and lands in `work`.

- **A workload that is *supposed* to be fast now waits behind the control
  plane** → Weights only matter under saturation; an idle control plane
  yields everything. The trade is explicit: when the box is full, the agents
  are what slows down. That is the order the operator asked for.

- **`memory.high` with no swap on the host still ends in the OOM killer** →
  Reclaim under `high` throttles by evicting page cache; with nothing to swap
  anonymous memory to, a workload that keeps growing eventually hits the
  container's `memory.max` (or the host's). D5 decides who dies then, and
  `docs/deploy.md` asks the host for a swapfile so `high` has somewhere to
  push.

- **Platforms with a partially delegated cgroup tree** (Kubernetes-based
  PaaS, rootless Docker) → `setup` checks `cgroup.controllers` for each
  controller it needs and enables only those present; a tree with `cpu` but
  no `memory` gets weights without a ceiling, reported as such by `status`.
  A tree with nothing usable falls back to `nice`.

- **The open `herdr-pane-shell` branch touches the same seam** → This change
  is built on top of that branch's `SHELL` handoff rather than beside it; the
  wrapper is what that variable points at. Landing order: that branch first.

- **A pane that opened before `setup` ran** → None can: the server starts
  after `setup` and every pane is the server's child. A herdr server the
  operator starts by hand with `AGENTBOX_HERDR_SERVER=0` from an SSH shell
  inherits `work` from that shell, which is the right place for it when the
  box is not the one running it.

- **The prune runs while `collie update` is mid-flight** → An update stages
  into a new directory and flips `current` last. A prune that runs between
  the two sees a directory newer than `current` and would not touch it (the
  rule keeps `current` and one *older*; anything newer is left alone), so a
  half-staged release survives. A prune that runs right after the flip
  removes the release two behind, which is the intent.

- **Collie's own layout changes** (`current` stops being a symlink,
  `versions/` moves) → The prune verb resolves `current` and refuses to act
  if it does not resolve into `versions/`, logging one line. The Collie
  smoke test stages a fake tree in the layout the installer produces today,
  so a layout change fails CI before it fails a phone.

- **A cache verb hangs on a lock** (`npm cache clean` while an install runs)
  → Each tool call has a timeout and reports "skipped: <tool> busy"; the
  report never blocks on a verb, and `all` continues past a skipped tier.

- **The rebuildable figure in the motd is stale by up to five minutes** →
  Acceptable for a hint whose job is to name a command; the command itself
  measures live.

## Migration Plan

No data moves. The cgroup tree is created fresh on every container start,
so `docker compose restart` (or a redeploy) is enough; nothing in either
volume changes shape. The first boot after the update prunes Collie releases
and drops the stale ones from the overlay; the log says how many and how
much.

Rollback is `AGENTBOX_ISOLATION=off` and a restart: the entrypoint skips
`setup`, every process lands in the root as today, and the OOM scores are
the only remnant, which is harmless. The Collie prune has no rollback and
needs none: what it removes is by definition two or more releases behind,
and `collie update` fetches any release again.

Order of landing: the `herdr-pane-shell` branch, then this change. Inside
this change the three fronts are independent and can be reviewed as three
commits: isolation, Collie pruning, `agentbox-clean`.

## Open Questions

- The `pids.max` value for `work`. Something generous enough that a test
  runner with worker processes never notices, small enough that a runaway
  fork loop cannot exhaust the pid space `sshd` needs. A starting figure is
  in the thousands; the smoke test that saturates `work` is where it gets
  tuned.
- Whether `io.weight` deserves the same 10:1 once a box with a slow disk is
  measured. Nothing here depends on the answer.
- The npx age cutoff. Seven days matches how MCP servers are re-fetched by
  `npx` anyway; a box that runs the same MCP daily keeps it warm, one that
  ran it once loses 170 MB a week later. Tunable without touching the
  structure.
