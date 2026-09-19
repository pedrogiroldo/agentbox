## Purpose

Keeping the terminal multiplexer that hosts the agents running as a service of
the box itself, started at boot, so that agents and their panes exist before
anyone connects — and can therefore be reached by something other than an
interactive SSH login.

## ADDED Requirements

### Requirement: The multiplexer runs as a box service

The box SHALL start the multiplexer's server at boot, before it begins accepting
SSH connections, so that a session exists independently of any login.

The server SHALL run as the box's user, not as root, so that the sessions it
hosts and the sessions a login would create are indistinguishable in ownership
and environment.

#### Scenario: A session exists before anyone logs in

- **WHEN** the box has finished booting and no SSH connection has been made
- **THEN** the multiplexer server is running and reachable through its control
  socket

#### Scenario: The server runs as the box user

- **WHEN** the multiplexer server is running after boot
- **THEN** it runs as the box's non-root user

### Requirement: An interactive session attaches to the running server

Running the multiplexer command from an interactive shell SHALL attach to the
server the box started, rather than starting a second, competing server.

A user who has never heard of this change SHALL see the behaviour they see
today: they log in, they run the command, and they get their session.

#### Scenario: The familiar workflow is unchanged

- **WHEN** a user logs in over SSH and runs the multiplexer command
- **THEN** they are attached to a session, exactly as before this change

#### Scenario: No second server

- **WHEN** the multiplexer command is run interactively while the boot-started
  server is running
- **THEN** exactly one server process is serving the control socket

#### Scenario: Work outlives the connection

- **WHEN** a user detaches or their connection drops
- **THEN** the panes and the agents inside them keep running, and are still
  there on the next connection

### Requirement: The service can be turned off

The box SHALL read an environment variable, `AGENTBOX_HERDR_SERVER`, that
disables starting the multiplexer at boot. When disabled, the box SHALL behave
as it does today: nothing runs until a user starts it from a shell.

The default SHALL be enabled.

#### Scenario: The shipped default

- **WHEN** the box boots with `AGENTBOX_HERDR_SERVER` unset
- **THEN** the multiplexer server is running once boot completes

#### Scenario: Disabled by the operator

- **WHEN** the box boots with `AGENTBOX_HERDR_SERVER=0`
- **THEN** no multiplexer server is running until a user starts one
- **AND** running the multiplexer command from a shell still works

### Requirement: A failed multiplexer never blocks access to the box

Starting the multiplexer SHALL NOT be able to prevent the box from serving SSH.
If the server cannot be started, the box SHALL log a warning naming the failure
and SHALL continue booting.

This is deliberate: SSH is the box's recovery path, and a multiplexer that
cannot start is exactly when that path is needed.

#### Scenario: The server cannot start

- **WHEN** the multiplexer server fails to start during boot
- **THEN** the box logs a warning naming the failure
- **AND** SSH becomes available and accepts a login

### Requirement: Shutdown does not destroy running work

A graceful stop of the box SHALL NOT deliberately tear down the multiplexer's
sessions before the box's existing shutdown work has run.

Sessions are not required to survive the container's own stop — the process
tree ends with it — but the box SHALL NOT add a step that kills them earlier
than the container itself would.

#### Scenario: A graceful stop

- **WHEN** the box is stopped gracefully
- **THEN** the box's existing shutdown work completes
- **AND** no step of the shutdown sequence has explicitly killed the
  multiplexer's sessions ahead of it
