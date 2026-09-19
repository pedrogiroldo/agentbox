## Purpose

Keeping the box reachable and observable — SSH, the multiplexer server, the
mobile interface and the tailnet daemon — when the agents and builds running
inside its panes saturate the CPU or the memory of a small machine.

## ADDED Requirements

### Requirement: The control plane is scheduled ahead of the workload

The box SHALL place the processes an operator needs in order to reach it and
see it — the init process, the boot script, the SSH daemon, the multiplexer
server, the mobile interface and the tailnet daemon — in a control group that
is weighted for CPU an order of magnitude above the group that holds the
workload, so that under CPU saturation the control plane's latency is bounded
and the workload is what slows down.

Everything that runs inside a multiplexer pane, and everything such a process
starts, SHALL belong to the workload group. Membership SHALL be inherited:
detaching from a terminal, creating a new session or daemonising SHALL NOT
move a process out of the workload group.

#### Scenario: A login completes under saturation

- **WHEN** the workload group is saturating every CPU the box has
- **THEN** an SSH login reaches a shell prompt within a bounded time
- **AND** a status query to the multiplexer server is answered within a
  bounded time

#### Scenario: A pane's processes are workload

- **WHEN** a command is run inside a multiplexer pane, including one that
  backgrounds itself and detaches from the terminal
- **THEN** that command and its descendants are in the workload group

#### Scenario: The control plane is control

- **WHEN** the box has finished booting
- **THEN** the SSH daemon, the multiplexer server, and the mobile interface
  and tailnet daemon when they run, are in the control group

### Requirement: The control plane keeps a memory floor, the workload a ceiling

The box SHALL reserve an amount of memory for the control group that the
kernel does not reclaim from it, and SHALL cap the workload group at the
box's memory minus that reserve, such that the workload is throttled before
the control plane is paged out. Reaching the ceiling SHALL slow the workload;
it SHALL NOT kill anything by itself.

The reserve SHALL be configurable through `AGENTBOX_CONTROL_RESERVE`. Unset,
it SHALL be derived from the box's total memory. Set to `0`, the memory floor
and ceiling SHALL be disabled while the CPU weighting and the OOM ordering
remain.

#### Scenario: The default reserve

- **WHEN** the box boots with `AGENTBOX_CONTROL_RESERVE` unset
- **THEN** the control group has a memory floor derived from the box's total
  memory, and the workload group has a ceiling of the total minus that floor

#### Scenario: An explicit reserve

- **WHEN** the box boots with `AGENTBOX_CONTROL_RESERVE=512M`
- **THEN** the control group's floor is 512 MB and the workload's ceiling is
  the box's total memory minus 512 MB

#### Scenario: Memory limits turned off

- **WHEN** the box boots with `AGENTBOX_CONTROL_RESERVE=0`
- **THEN** neither group has a memory floor or ceiling
- **AND** the CPU weighting and the OOM ordering are still in effect

### Requirement: The kernel's out-of-memory killer prefers the workload

The box SHALL set the out-of-memory score of the multiplexer server so that it
is never the kernel's first choice, at the same level the SSH daemon already
sets for itself, and SHALL set the mobile interface's and the tailnet daemon's
scores just above it. Processes in the workload group SHALL keep the default
score.

This SHALL hold in every isolation mode, including the one that uses no
control groups.

#### Scenario: Scores after boot

- **WHEN** the box has finished booting
- **THEN** the multiplexer server's out-of-memory score is at the minimum, and
  the mobile interface's and tailnet daemon's scores are below the default
  when they run
- **AND** a process started inside a pane has the default score

### Requirement: The interactive experience inside a pane is unchanged

Placing panes in the workload group SHALL NOT change what a user sees or
gets inside one: the shell SHALL be the user's login shell, `SHELL` SHALL
name that shell and not any intermediary, the arguments the multiplexer
passes to the shell SHALL reach it unchanged, and the multiplexer's agent
integrations SHALL keep working.

#### Scenario: The shell in a pane

- **WHEN** a new pane opens
- **THEN** the process in it is the user's login shell as recorded in the
  user database, and `SHELL` inside it names that shell

#### Scenario: Arguments pass through

- **WHEN** the multiplexer opens a pane with shell arguments
- **THEN** the shell receives exactly those arguments

### Requirement: Isolation degrades, and never blocks the boot

The box SHALL read `AGENTBOX_ISOLATION` with four states:

- `auto` — use control groups when the container's tree allows it; otherwise
  fall back to process priorities. This SHALL be the default.
- `cgroup` — use control groups; treat a tree that refuses as a boot failure.
- `nice` — use process priorities only.
- `off` — apply nothing beyond the OOM ordering.

In the priority fallback, the control plane's processes SHALL run at a
higher scheduling priority than the default; no memory floor or ceiling
SHALL be claimed.

When control groups cannot be set up in `auto`, the box SHALL log one warning
naming what refused and SHALL continue booting. A partially usable tree (some
controllers present, others absent) SHALL yield the protections the present
controllers allow, not none.

#### Scenario: The shipped default on a privileged container

- **WHEN** the box boots with `AGENTBOX_ISOLATION` unset in a container whose
  control-group tree is writable
- **THEN** the control and workload groups exist with their weights and
  limits, and the box reports the mode as control groups

#### Scenario: A tree that refuses

- **WHEN** the box boots with `AGENTBOX_ISOLATION` unset in a container whose
  control-group tree cannot be written
- **THEN** the box logs one warning naming what refused
- **AND** the control plane runs at a raised priority
- **AND** SSH becomes available and accepts a login

#### Scenario: Required and refused

- **WHEN** the box boots with `AGENTBOX_ISOLATION=cgroup` in a container whose
  tree cannot be written
- **THEN** the box reports the failure and does not present itself as ready

#### Scenario: Turned off

- **WHEN** the box boots with `AGENTBOX_ISOLATION=off`
- **THEN** no group is created and no priority is changed
- **AND** the OOM ordering is still applied

### Requirement: The box reports which protections are in effect

The box SHALL provide a status command that reports the isolation mode
actually in effect, whether the CPU weighting is live, whether the memory
floor and ceiling are live and what their values are, and whether the OOM
ordering is set. In the fallback modes it SHALL name what prevented control
groups.

The report SHALL describe the running state, not the configured intent.

#### Scenario: Status on a protected box

- **WHEN** the status command runs on a box where control groups were set up
- **THEN** it names the mode, the CPU weights, the memory floor and ceiling
  values, and that the OOM scores are set

#### Scenario: Status after a fallback

- **WHEN** the status command runs on a box that fell back to priorities
- **THEN** it names the fallback mode and the file or condition that refused

### Requirement: The rescue path is verified, not assumed

Opening a shell inside the box without SSH — the box's documented rescue
hatch — SHALL keep working when control groups are set up, and the box's
test suite SHALL exercise it on every build.

#### Scenario: A shell without SSH

- **WHEN** a shell is opened in a booted box through the container runtime
  rather than SSH, with control groups set up
- **THEN** the shell opens and runs commands
