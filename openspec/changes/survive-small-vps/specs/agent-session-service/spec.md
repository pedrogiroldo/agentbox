## MODIFIED Requirements

### Requirement: The multiplexer runs as a box service

The box SHALL start the multiplexer's server at boot, before it begins accepting
SSH connections, so that a session exists independently of any login.

The server SHALL run as the box's user, not as root, so that the sessions it
hosts and the sessions a login would create are indistinguishable in ownership
and environment.

The server SHALL run as part of the box's control plane: in the control group
the box weights ahead of its workload, and with an out-of-memory score that
makes it the kernel's last choice. The panes it opens SHALL NOT inherit that
position: each pane SHALL be placed in the workload group before the user's
shell starts in it, and the shell SHALL be the user's login shell with
`SHELL` naming that shell.

#### Scenario: A session exists before anyone logs in

- **WHEN** the box has finished booting and no SSH connection has been made
- **THEN** the multiplexer server is running and reachable through its control
  socket

#### Scenario: The server runs as the box user

- **WHEN** the multiplexer server is running after boot
- **THEN** it runs as the box's non-root user

#### Scenario: The server is control plane

- **WHEN** the multiplexer server is running after boot with isolation in
  effect
- **THEN** it is in the control group and its out-of-memory score is at the
  minimum

#### Scenario: A pane is workload

- **WHEN** a pane opens in the boot-started server
- **THEN** the shell in it is the user's login shell, `SHELL` names that
  shell, and the shell and its descendants are in the workload group
