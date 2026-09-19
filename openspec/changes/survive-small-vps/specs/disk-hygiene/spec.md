## Purpose

Telling the operator what occupies the box's volumes, reclaiming the parts
that are rebuildable caches only when asked, and keeping the release trees the
box manages itself from multiplying through its own persistence.

## ADDED Requirements

### Requirement: The box reports what occupies its disk

The box SHALL provide a command, `agentbox-clean`, that with no verb prints a
report and deletes nothing. The report SHALL list, with sizes: each
rebuildable cache the box knows about; the total each cleaning verb would
free; and the operator's own data — repositories, worktrees, agent
transcripts, agent configuration and memory stores, credentials, and the
package cache in the state volume — as items the command will never touch.

A path the command does not know SHALL NOT be reported as reclaimable.

#### Scenario: The report deletes nothing

- **WHEN** `agentbox-clean` runs with no verb
- **THEN** every file that existed before still exists afterwards
- **AND** the output lists the rebuildable caches, the amount each verb would
  free, and the operator's data marked as untouched

#### Scenario: A dry run for one verb

- **WHEN** `agentbox-clean --dry-run caches` runs
- **THEN** the output lists what that verb would remove and its size, and
  nothing is removed

### Requirement: Rebuildable caches are reclaimed on request, by their owners

`agentbox-clean caches` SHALL reclaim the package-manager and tool caches in
the home volume — at minimum those of npm, bun, uv, pnpm and pip — by
invoking each tool's own cache-cleaning facility where one exists, so that
entries the tool still references are kept. Where a tool has no such
facility, the rule the box applies SHALL be stated in the report: temporary
package-runner entries older than a fixed age, superseded versions in the
agent's plugin cache, leftover temporary files, and the desktop trash.

A tool that is busy or absent SHALL be skipped with a message, and SHALL NOT
stop the remaining caches from being handled.

#### Scenario: Cleaning caches

- **WHEN** `agentbox-clean caches` runs on a box with populated caches
- **THEN** the caches listed in the report are reduced, the operator's data
  is unchanged, and the output says how much was freed

#### Scenario: A busy tool

- **WHEN** one tool's cache cannot be cleaned because the tool is in use
- **THEN** the output says that tool was skipped and why
- **AND** the other caches are still cleaned

### Requirement: Cleaning that breaks something is a separate, explicit verb

Reclaiming downloaded browser binaries, and pruning unused images and
containers from the box's own container daemon, SHALL each require their own
verb (`browsers`, `docker`), because each leaves something to reinstall or
re-pull. A combined verb (`all`) SHALL run the three tiers. The container
verb SHALL remove only unreferenced images and stopped containers, never
images that a running or stopped container still uses.

#### Scenario: Browsers are not part of caches

- **WHEN** `agentbox-clean caches` runs on a box with downloaded browsers
- **THEN** the browsers are still present

#### Scenario: Browsers on request

- **WHEN** `agentbox-clean browsers` runs
- **THEN** the downloaded browser binaries are removed and the output names
  the command that reinstalls them

#### Scenario: The daemon's leftovers

- **WHEN** `agentbox-clean docker` runs on a box whose daemon holds an image
  no container uses and an image a stopped container uses
- **THEN** the unused image is removed and the other is kept

### Requirement: Nothing is cleaned automatically by default

The box SHALL NOT delete any cache on its own unless the operator sets
`AGENTBOX_CLEAN_INTERVAL` to a number of seconds, in which case it SHALL run
the `caches` tier at that interval and log what it did to the state volume.
The default SHALL be off.

#### Scenario: The shipped default

- **WHEN** a box runs for longer than any interval with
  `AGENTBOX_CLEAN_INTERVAL` unset
- **THEN** no cache has been removed by the box

#### Scenario: Opted in

- **WHEN** the box runs with `AGENTBOX_CLEAN_INTERVAL` set
- **THEN** the `caches` tier runs at that interval and its result is logged

### Requirement: The login greeting says when cleaning is worth it

When the home volume exceeds a threshold, `AGENTBOX_CLEAN_WARN`, or when the
rebuildable share exceeds half of the home, the greeting shown at login SHALL
add one line giving the home's size, the rebuildable amount and the command
to run. Below the threshold it SHALL add nothing. The figures MAY be up to one
save interval stale; the command itself SHALL measure live.

#### Scenario: Below the threshold

- **WHEN** a user logs in on a box whose home is below the threshold and
  whose rebuildable share is under half
- **THEN** the greeting has no line about disk

#### Scenario: Above the threshold

- **WHEN** a user logs in on a box whose home exceeds the threshold
- **THEN** the greeting includes the home's size, the rebuildable amount and
  the name of the cleaning command

### Requirement: The cleaning command is reachable from the laptop

The project's `make` wrapper SHALL expose the report and the verbs
(`make clean`, and the verbs as arguments), running the same command inside
the box.

#### Scenario: From outside

- **WHEN** `make clean` runs on the machine that hosts the box
- **THEN** the same report the in-box command prints is shown

### Requirement: Release trees the box manages are pruned by the box

Where the box installs software as a versioned tree with a pointer to the
current release, and lets that software update itself in place, the box SHALL
remove superseded releases so that at most the current release and its
immediate predecessor remain. Pruning SHALL run at boot and before each
periodic save of the system layer, SHALL never remove the current release or
a release newer than it, and SHALL refuse to act when the tree's layout is
not the one it expects, logging one line.

The system-layer persistence SHALL NOT retain a superseded release: one that
was saved before it was superseded SHALL be dropped from the saved layer once
pruned, rather than restored on the next boot.

#### Scenario: Leftovers after several updates

- **WHEN** the box boots with five releases in a managed tree, the current
  one pointing at the newest
- **THEN** after boot only the newest and the one before it remain, and the
  saved system layer holds no others

#### Scenario: An update caught mid-flight

- **WHEN** pruning runs while a release newer than the current pointer has
  been staged but not yet pointed at
- **THEN** the staged release is left in place

#### Scenario: An unexpected layout

- **WHEN** the current pointer does not resolve into the versions directory
- **THEN** nothing is removed and the box logs one line saying why
