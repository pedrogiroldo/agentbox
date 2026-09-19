# A small VPS

agentbox was built for a machine you already pay for: two vCPUs, a few
gigabytes, a disk shared with a Coolify or a Dokploy. This page is what it
does to fit there, what it deliberately does not do, and the numbers behind
both — measured on exactly that machine, with twelve Claude sessions open.

## Where the resources actually go

The services agentbox itself starts are cheap. The panes are not, and most of
their cost is not agents thinking:

```
  RSS on a 2 vCPU / 8 GB box, twelve Claude sessions open
  +---------------------------------------------------------------+
  | claude x12  (ten of them resumed by herdr at boot)   4.2 GB   |
  | per-session hook servers and workers                 1.6 GB   |
  | your own dev servers and MCPs                        0.5 GB   |
  | tini, sshd, herdr server, collie, tailscaled,                 |
  |   dockerd, containerd, persist watcher               0.23 GB  |
  +---------------------------------------------------------------+

  forks per second                453   (status lines at 1 s, hooks per tool call)
  CPU in kernel time              47%
  CPU stolen by the host          12-17%
  memory pressure                 ~0     no OOM kill, ever
```

An idle Claude session costs 340 to 460 MB and one to four percent of a core.
A per-session memory plugin adds about 120 MB and two more processes. A
status line that refreshes every second adds a shell, two `git` calls and
their subshells, every second, per session. None of that is the box's to
change; all of it decides how many sessions fit.

## What the box does about it

### It keeps itself reachable

The freeze on that machine was not memory. It was scheduling: `sshd`, the
herdr server and Collie sat in the same run queue as four hundred forks a
second, and an SSH login — fifteen forks from `sshd` to a prompt — never got
its turn before the client gave up. Collie reported the herd disconnected;
the TUI stopped drawing; nobody could get in to close anything.

So the box splits itself in two, using the cgroup v2 tree its Docker daemon
already requires it to have:

```
  control/   cpu.weight 1000   memory.min <reserve>
             tini, the entrypoint, sshd, the herdr server, collie, tailscaled
             what you need in order to SEE and ACT

  work/      cpu.weight 100    memory.high <total - reserve>   pids.max 4096
             everything born inside a herdr pane, and your SSH shell once
             the login is done: agents, hooks, status lines, builds, tests

  docker/    defaults
             dockerd, containerd, and the containers you run
```

Weights only matter under saturation. An idle control plane yields
everything; a full box slows the agents down and keeps answering. The memory
floor keeps the control plane's pages from being reclaimed; the ceiling
throttles the workload before the whole box thrashes, and never kills
anything on its own. If the kernel does have to kill something, the herdr
server is its last choice, `sshd` and the tailnet daemon just above it, and
any agent before all of them.

```sh
agentbox-cgroup status       # which of this is actually in effect
make isolation               # the same, from your laptop
```

Two variables, in `.env`:

| | |
| --- | --- |
| `AGENTBOX_ISOLATION` | `auto` (default): cgroups when the container allows, process priorities otherwise. `cgroup`: cgroups or refuse to boot. `nice`: priorities only. `off`. |
| `AGENTBOX_CONTROL_RESERVE` | Memory kept for the control plane, e.g. `512M`. Empty derives it: 10% of the box, between 384M and 1G. `0` keeps the CPU weighting and drops the memory limits. |

**When the container is not privileged**, the cgroup tree is read-only and
`auto` falls back to priorities: `sshd`, the herdr server and Collie run at
`nice -10`, the workload at 0. That protects CPU, not memory; `agentbox-cgroup
status` says so.

**A service restarted by hand goes back to being workload.** Placement is
inherited, so only what the entrypoint starts inherits `control/`. Restart
something from a pane — or let Collie's own updater restart it, which is what
taking an update from the phone does — and it comes back in `work/`, weighted
behind the agents it exists to let you watch and ahead of them in the queue to
be killed. `agentbox-collie start` puts the bridge back itself; for anything
else, `status` names the drift and `protect` is the repair:

```
agentbox-cgroup status
  plane:  herdr server  /control oom -1000
          collie        /work oom 0  <- workload: restarted outside the box's own start — `agentbox-cgroup protect` puts it back
          tailscaled    /control oom -900
```

### It prunes what it manages

`collie update` stages the new release beside the old one and tries to move
the old one into a trash directory. That fails for the release the image
shipped — overlayfs cannot rename a directory out of the image layer — and
Collie stops there. The box that this was measured on had eight releases in
`/opt/collie/versions`, and because seven of them postdated the image, the
persistence layer had copied all 588 MB into the state volume and was laying
them back down on every boot.

The box now keeps the current release and the one before it, removes the
rest at boot and before each periodic save, and drops the removed ones from
the state volume too. An in-place update still survives a recreate.

### It tells you what is cache

Nine of the fourteen gigabytes in that home were caches nobody asked to
keep. `agentbox-clean` says so:

```
$ agentbox-clean
home   14.2 GB at /home/dev
state  1.0 GB at /var/lib/agentbox

agentbox-clean caches
  npm content store                                  3.1 GB   npm cache clean --force
  npx leftovers older than 7d                      680 MB     npx-age
  bun package cache                                  2.2 GB   bun pm cache rm
  uv cache                                           1.3 GB   uv cache clean
  pnpm store (unreferenced)                          1.0 GB   pnpm store prune
  superseded plugin versions                       474 MB     plugin-old
  would free about                                   8.7 GB

agentbox-clean browsers
  Playwright browsers                              658 MB     rm
  reinstall with: npx playwright install

yours — never touched by this command
  repositories                                       3.7 GB
  herdr worktrees (git worktree list / remove)       1.5 GB
  Claude transcripts (what --resume reads)         321 MB
  agent memory                                     248 MB
```

The report deletes nothing. A verb does, and so does the box itself for the
first tier once the disk is actually tight (below):

```sh
agentbox-clean caches        # each tool's own prune; nothing breaks
agentbox-clean browsers      # tests break until you reinstall
agentbox-clean docker        # unreferenced images, stopped containers
agentbox-clean all
agentbox-clean --dry-run caches
make clean VERB=caches       # the same, from your laptop
```

Each cache is reclaimed by its own tool where the tool has a verb for it, so
what is still referenced stays. The list of what counts as *yours* is fixed
and short: repositories, worktrees, transcripts, agent state, credentials,
and the apt archive in the state volume (it is the offline replay cache).
Nothing outside the two lists is touched, however large.

**The `caches` tier runs on its own when it matters.** Once the home passes
`AGENTBOX_CLEAN_AT` (default `20G`), or the disk under it has less than
`AGENTBOX_CLEAN_MIN_FREE` (default `2G`) left, the box runs `agentbox-clean
caches` itself, logs what it freed to `/var/lib/agentbox/log/clean.log`, and
the login greeting says where the home stands. Below both lines it does
nothing, so a box with room keeps its warm caches. The other tiers are never
automatic. Set a trigger to `0` to turn it off; `AGENTBOX_CLEAN_INTERVAL`
adds a plain timer for operators who want one.

## What the host has to do

**Give it swap.** The memory ceiling throttles the workload by reclaiming
page cache. With nowhere to push anonymous memory, a workload that keeps
growing still ends at the OOM killer — later, and with the right victim, but
it ends there. A 2 GB swapfile turns that into a slowdown:

```sh
fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab
```

The box cannot do this for you: swap is the host's.

**Know what steal means.** Two vCPUs with 15% steal are 1.7. That is the
provider's overcommit, and nothing in the container changes it.

## What you decide

The box protects its control plane. It does not decide how much workload you
run. These are the levers that actually move the numbers above, and they are
yours:

- **How many sessions herdr resumes at boot.** herdr's default is to resume
  every agent pane after a server restart. Ten idle sessions are four
  gigabytes and a boot storm; if you want them back, the box now stays
  responsive through it. If you do not, herdr's `resume_agents_on_restore` is
  the setting.
- **The status line interval.** Once a second, times twelve sessions, was
  most of the four hundred forks. Five seconds is not noticeably different
  on a phone.
- **Per-tool-call hooks.** A plugin that runs a shell and a node process on
  every tool call multiplies with every session that has it enabled.
- **Docker.** `AGENTBOX_DOCKER=off` saves 85 MB of daemon and 340 MB of disk
  on a box that never runs a container, and lets you drop `privileged`.
- **The image.** `PREINSTALL_NVIM_PLUGINS=false`, `INSTALL_DOCKER_CLI=false`
  and `INSTALL_TAILSCALE=false` each remove something from the build.
  Pulling the prebuilt image instead of building on the VPS avoids the
  build's memory entirely ([deploy.md](deploy.md)).

A rough budget: an idle agent session is half a gigabyte; a working one can
be more than one. Subtract the reserve and the host's own needs, divide, and
that is how many the box can hold before it has to start slowing them down.
