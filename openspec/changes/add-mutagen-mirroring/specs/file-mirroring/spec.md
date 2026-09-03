## Purpose

Mirroring a project directory inside the box onto a developer's own machine over
the SSH connection that already exists, so code the agents write in the cloud
can be built and run against local hardware — an Android emulator, a USB device,
a GPU — instead of only inside a container.

## ADDED Requirements

### Requirement: The box advertises the endpoint a mirror must dial

A mirror is created from outside the box, so the box SHALL be able to state the
address a client must connect to. That address is not derivable from inside a
container — port publishing and reverse proxies happen on the host — so it SHALL
be configurable through the environment, as `AGENTBOX_SSH_HOST` and
`AGENTBOX_SSH_PORT`.

`AGENTBOX_SSH_PORT` SHALL default to `2222`, matching the port the shipped
compose file publishes. `AGENTBOX_SSH_HOST` has no safe default and SHALL be
unset by default.

Both values SHALL be visible to interactive shells inside the box, including
sessions opened over SSH and panes opened by the multiplexer.

#### Scenario: The host is configured

- **WHEN** the box runs with `AGENTBOX_SSH_HOST=box.example.com` and
  `AGENTBOX_SSH_PORT=2200`
- **THEN** a command run in an interactive SSH session inside the box reads back
  those two values

#### Scenario: The host is not configured

- **WHEN** the box runs with no `AGENTBOX_SSH_HOST` set
- **THEN** any endpoint the box prints uses a clearly non-real placeholder in
  place of the host
- **AND** the output states that setting `AGENTBOX_SSH_HOST` replaces the
  placeholder

#### Scenario: The port falls back to the shipped default

- **WHEN** the box runs with no `AGENTBOX_SSH_PORT` set
- **THEN** the endpoint the box prints uses port `2222`

### Requirement: The box prints a paste-ready mirror command

The box SHALL provide a command, `agentbox-mirror`, that takes a project and
prints a single shell command the developer can paste into a terminal on their
own machine to start mirroring that project.

The printed command SHALL be complete: it SHALL name the session, name both
endpoints, and carry the ignore set, so that no editing is required beyond
choosing where the mirror lands locally.

The remote endpoint SHALL be expressed in Mutagen's SCP-like URL form,
`[<user>@]<host>[:<port>]:<path>`, with an absolute remote path — a relative
path would resolve against a home directory the developer cannot see.

The session SHALL be named deterministically from the project name, prefixed so
that every session this box creates is recognisable as one of its own, and
sanitised to whatever character set Mutagen accepts for session names.

#### Scenario: Printing the command for a project

- **WHEN** the developer runs `agentbox-mirror myapp` in a box configured with
  host `box.example.com` and port `2200`, and `~/projects/myapp` exists
- **THEN** the output contains a `mutagen sync create` command
- **AND** that command's remote endpoint is `dev@box.example.com:2200:/home/dev/projects/myapp`
- **AND** that command carries a session name derived from `myapp`
- **AND** that command carries the default ignore set

#### Scenario: The local path is left for the developer to choose

- **WHEN** the box prints a mirror command
- **THEN** the local side of the command is a placeholder the developer replaces
  with a path on their own machine
- **AND** the output says so in words, not only by convention

#### Scenario: A project name that is not a valid session name

- **WHEN** the project directory name contains characters Mutagen does not
  accept in a session name
- **THEN** the printed session name is sanitised into an accepted form
- **AND** the command is still valid as printed

### Requirement: Project arguments resolve against the projects directory

Projects in the box live under `~/projects`. `agentbox-mirror` SHALL accept a
bare project name and resolve it there, and SHALL also accept a path — absolute,
or relative to the current directory — for anything living elsewhere.

Running the command with no project at all SHALL be useful rather than an error:
it SHALL explain what mirroring is for and list the projects available to mirror.

#### Scenario: A bare project name

- **WHEN** the developer runs `agentbox-mirror myapp` and `~/projects/myapp` is
  a directory
- **THEN** the remote path in the printed command is `/home/dev/projects/myapp`

#### Scenario: A path outside the projects directory

- **WHEN** the developer runs `agentbox-mirror ~/work/other` and that directory
  exists
- **THEN** the remote path in the printed command is the absolute path of that
  directory

#### Scenario: The project does not exist

- **WHEN** the developer names a project that is not a directory in the box
- **THEN** the command fails with a non-zero exit status
- **AND** the message names the path it looked for
- **AND** no mirror command is printed

#### Scenario: No argument at all

- **WHEN** the developer runs `agentbox-mirror` with no arguments
- **THEN** the output explains what a mirror is for
- **AND** lists the directories under `~/projects` that can be mirrored
- **AND** exits with status zero

### Requirement: The default ignore set excludes build output, not source

Mirroring a build directory is the fastest way to make a mirror useless: build
output is large, machine-specific, and regenerated constantly on both sides. The
box SHALL therefore include a default ignore set in every command it prints.

That set SHALL cover, at minimum, the build and dependency directories of the
ecosystems this box is used for, including Gradle and Android output
(`build/`, `.gradle/`, `.cxx/`, `local.properties`), Node (`node_modules/`),
Python (`.venv/`, `__pycache__/`), and Rust (`target/`).

The ignore set SHALL NOT exclude version-control metadata. The developer is
expected to run `git` on the mirrored copy, and a mirror without `.git` is not
the same repository.

#### Scenario: Gradle output is ignored

- **WHEN** the box prints a mirror command
- **THEN** the ignore set includes the Gradle and Android build directories

#### Scenario: Version control metadata is kept

- **WHEN** the box prints a mirror command
- **THEN** the ignore set does not exclude `.git`
- **AND** the command does not pass Mutagen's VCS-ignore option

### Requirement: The box reports whether it is ready to be mirrored

Mutagen installs its own agent binary into the box on first connection, over
SFTP. When something in that path is broken, Mutagen fails at connection time
with a message about a remote agent, which does not tell the developer what to
fix in the box.

`agentbox-mirror check` SHALL therefore verify, from inside the box, the
conditions a mirror depends on, and SHALL report each one individually: that the
SSH server offers an SFTP subsystem, that the directory Mutagen installs its
agent into is writable by the login user, and that an endpoint host is
configured.

It SHALL exit non-zero when a condition that would break mirroring is not met.
A missing `AGENTBOX_SSH_HOST` SHALL be reported as a warning rather than a
failure — the box cannot verify what the host is reachable as, and a developer
who knows their own address can mirror without setting it.

#### Scenario: Everything is in place

- **WHEN** `agentbox-mirror check` runs in a box with the SFTP subsystem
  enabled, a writable agent directory and a configured host
- **THEN** each condition is reported as met
- **AND** the command exits with status zero

#### Scenario: The SFTP subsystem is missing

- **WHEN** the SSH server is configured without an SFTP subsystem
- **THEN** `agentbox-mirror check` reports that condition as failed
- **AND** exits with a non-zero status

#### Scenario: The host is not configured

- **WHEN** `AGENTBOX_SSH_HOST` is unset and every other condition is met
- **THEN** `agentbox-mirror check` reports the host as a warning, naming the
  variable to set
- **AND** exits with status zero

### Requirement: The box can emit a Mutagen project file

For a project mirrored more than once, or shared with a teammate, an ad-hoc
session command is worse than a file kept next to the code. `agentbox-mirror`
SHALL therefore also emit a `mutagen.yml` describing the same session it would
otherwise print as a command.

The emitted file SHALL be valid Mutagen project configuration, SHALL carry the
same endpoint and the same ignore set as the printed command, and SHALL be
written to standard output so it can be redirected to a file on the machine that
will use it.

#### Scenario: Emitting a project file

- **WHEN** the developer asks `agentbox-mirror` for a project file for `myapp`
- **THEN** the output is YAML defining a synchronization session
- **AND** its remote endpoint and ignore set match what the printed command
  would have used
- **AND** the output carries no log lines or decoration that would corrupt the
  file when redirected

### Requirement: Mirroring adds no privilege, no port and no image weight

A mirror runs over the SSH connection that already exists, as the user that
already logs in. Adding one SHALL NOT require the box to listen on a new port,
hold a new capability, or run a new long-lived process.

Mutagen's agent binary SHALL NOT be baked into the image: it is copied from the
client on first connection, and the version that arrives is the one that matches
the client. The box SHALL keep it in the persistent home volume so that it
survives a container recreate and is copied once, not on every boot.

#### Scenario: No new surface

- **WHEN** a box is compared before and after this capability exists
- **THEN** it publishes the same ports, holds the same capabilities, and runs
  the same daemons

#### Scenario: The agent survives a recreate

- **WHEN** a mirror has been established and the container is recreated with its
  volumes intact
- **THEN** the Mutagen agent installed by the earlier connection is still present
- **AND** reconnecting does not reinstall it

### Requirement: The repository drives a mirror from the local side

A developer who cloned this repository already has the endpoint in their `.env`.
For them the box printing a command is a step too many, so the repository's
`make` interface SHALL be able to create, inspect and remove a mirror directly.

There SHALL be targets to start a mirror for a named project, to show the state
of the mirrors this repository created, and to remove one. They SHALL read the
port and host from the same `.env` the rest of the interface reads.

When Mutagen is not installed on the machine running `make`, the target SHALL
fail with a message that says how to install it, rather than with a shell
"command not found".

#### Scenario: Starting a mirror from the repository

- **WHEN** the developer runs the mirror target naming a project and a local
  directory, with Mutagen installed and the box reachable
- **THEN** a Mutagen session is created between that local directory and the
  project inside the box
- **AND** the session uses the port configured in `.env`

#### Scenario: Mutagen is not installed locally

- **WHEN** the developer runs the mirror target on a machine without Mutagen
- **THEN** the target fails with a non-zero exit status
- **AND** the message names how to install Mutagen

#### Scenario: Removing a mirror

- **WHEN** the developer runs the unmirror target for a project that is
  currently mirrored
- **THEN** that project's session is terminated
- **AND** neither copy of the files is deleted

### Requirement: Mirroring is discoverable without reading the source

A capability nobody finds is not a capability. The box SHALL mention mirroring
where a developer already looks: the login summary SHALL name the command, and
the repository documentation SHALL cover it.

Documentation SHALL include the workflow this capability exists for — editing in
the box while building and running on local hardware — with the Android case
covered explicitly, since that is the case port forwarding cannot serve.

#### Scenario: Named at login

- **WHEN** a developer logs in over SSH to a terminal wide enough for the
  summary
- **THEN** the summary names `agentbox-mirror`

#### Scenario: Documented

- **WHEN** a developer opens the repository documentation index
- **THEN** it links a page covering mirroring
- **AND** that page covers installing Mutagen locally, the Android workflow,
  the ignore defaults, and what happens when both sides change the same file
