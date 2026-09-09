## Purpose

The box joining a private mesh network as a node of its own, and serving things
on it, so that a phone or a laptop already on that network can reach the box
without any port being published to the internet and without a proxy in front.

## ADDED Requirements

### Requirement: The box can join a tailnet from inside the container

The box SHALL ship the tailnet client and daemon in the image, and SHALL be able
to join a tailnet as its own node without a published port.

The daemon SHALL run in **userspace networking** mode. This is normative, not an
implementation detail: it is what makes membership possible without a TUN device
and without granting the container `NET_ADMIN`, so joining a tailnet SHALL NOT
require any privilege the box does not already need for its other features.

#### Scenario: A box with no TUN device joins

- **WHEN** the box runs in a container with no `/dev/net/tun` and no added
  network capability, and is given valid credentials
- **THEN** it appears as an online node on the tailnet

#### Scenario: The client is present regardless

- **WHEN** an interactive shell opens in a box built from the shipped image
- **THEN** the tailnet client is on the PATH and reports its version, whether or
  not the box has joined anything

### Requirement: The box decides whether it joins

Joining SHALL be a decision the operator makes. The box SHALL read a single
environment variable, `AGENTBOX_TAILSCALE`, with three states:

- `off` — never start the daemon. This SHALL be the default.
- `auto` — start it, and treat a failure as a warning.
- `on` — start it, and treat a failure as a boot failure.

#### Scenario: The shipped default

- **WHEN** a box boots with no `AGENTBOX_TAILSCALE` set
- **THEN** no daemon is running and the box has joined nothing

#### Scenario: Required but unavailable

- **WHEN** a box boots with `AGENTBOX_TAILSCALE=on` and the daemon cannot start
  or cannot authenticate
- **THEN** the box reports the failure and does not present itself as ready

#### Scenario: Requested but unavailable

- **WHEN** a box boots with `AGENTBOX_TAILSCALE=auto` and the daemon cannot start
- **THEN** the box logs a warning naming the reason
- **AND** SSH still becomes available

### Requirement: Joining is a command, and the box says so

The normal way to join SHALL be a command the operator runs from a shell:
`agentbox-tailscaled login`. It SHALL print the login URL **and** a scannable
code, and SHALL wait until the login completes rather than returning and
leaving the operator to find out whether it worked.

Printing a scannable code is normative rather than decorative: the device the
operator is authenticating for is usually the phone in their hand, and a URL in
a terminal cannot be opened there.

On success it SHALL name the address other devices reach the box at. On a box
that has already joined it SHALL say so and SHALL NOT re-authenticate silently.

The command SHALL acquire the privilege it needs rather than failing with a
permissions error, and SHALL say when it does so.

#### Scenario: Joining from a shell

- **WHEN** the operator runs the login command on a box that has joined nothing
- **THEN** a login URL and a scannable code are printed, and the command waits
- **AND** when the login is completed elsewhere, the command reports the box's
  tailnet address and exits successfully

#### Scenario: Already a member

- **WHEN** the login command runs on a box that has already joined
- **THEN** it reports the tailnet it is on and changes nothing
- **AND** it names how to re-authenticate or move to a different tailnet

#### Scenario: Run without privilege

- **WHEN** the login command is run by the box's ordinary user
- **THEN** it obtains the privilege it needs, states that it is doing so, and
  proceeds

### Requirement: An unattended boot can join without a person

A deploy platform may start the box with nobody watching, so joining SHALL also
be possible entirely from configuration: when the box is not already a member
and an auth key is supplied through the environment, the box SHALL use it to
join without interaction.

An auth key SHALL NOT be written anywhere that outlives the boot that used it.

When no auth key is supplied and the box is not already a member, the boot SHALL
NOT block waiting for a human and SHALL NOT fail silently: it SHALL name the
command that completes the join.

#### Scenario: First boot with an auth key

- **WHEN** a box that has never joined boots with the tailnet enabled and a
  valid auth key in the environment
- **THEN** it is an online node on the tailnet once boot completes, with no
  interaction

#### Scenario: First boot without an auth key

- **WHEN** a box that has never joined boots with the tailnet enabled and no
  auth key
- **THEN** the boot completes without waiting, SSH is available, and the log
  names the command that would complete the join

#### Scenario: The key is not left behind

- **WHEN** a box has joined using an auth key
- **THEN** the key is not present in the box's persisted state or in the
  environment file the box writes for interactive shells

### Requirement: The box's tailnet identity survives a recreate

The daemon's node state SHALL be stored where the box's other durable state
lives, not on the container filesystem. A container recreated from the same
image SHALL come back as the same tailnet node, with the same name and address,
without being authenticated again.

#### Scenario: Recreate keeps the node

- **WHEN** a box has joined a tailnet, and the container is recreated from the
  same image with its volumes intact
- **THEN** the box is the same node, with the same tailnet name, and no auth key
  or login is needed

#### Scenario: Wiping the volumes is a fresh node

- **WHEN** the box's state volume is deleted and the box boots again
- **THEN** it behaves as a box that has never joined

### Requirement: The box's user can drive the tailnet without sudo

Programs the user runs — a mobile web UI managing its own front door among them
— need to read tailnet status and publish a service. The box SHALL delegate
tailnet operation to its own user, so those programs work as that user without
`sudo`.

#### Scenario: Status as the box user

- **WHEN** the box has joined and the box's user runs the client's status command
- **THEN** it succeeds without `sudo`

#### Scenario: Publishing a service as the box user

- **WHEN** the box's user asks the client to serve a local port on the tailnet
- **THEN** it succeeds without `sudo`, and the service is reachable from another
  node on the tailnet

### Requirement: The box reports what it has joined

The box SHALL provide a command, `agentbox-tailscaled`, that manages the daemon
from inside the box and is usable by the boot sequence and by hand alike.

Its status output SHALL distinguish *not configured to join*, *configured but not
running*, *running but not authenticated*, and *joined*, and when joined SHALL
name the address other nodes reach the box at.

#### Scenario: Status on a default box

- **WHEN** status runs on a box with `AGENTBOX_TAILSCALE` unset
- **THEN** it reports that the client is installed and the box has deliberately
  not joined, and names the variable that would change that

#### Scenario: Status on a joined box

- **WHEN** status runs on a box that has joined
- **THEN** it names the box's tailnet name or address

#### Scenario: Status when authentication is outstanding

- **WHEN** status runs on a box whose daemon is running but which has not
  completed a login
- **THEN** it says so, and says where the login URL can be read

### Requirement: The box never exposes the tailnet to the public internet

The box SHALL NOT enable, or document as an option, any mode that publishes a
tailnet service to the public internet.

#### Scenario: No public exposure is configured

- **WHEN** the box brings up the tailnet daemon and any service on it
- **THEN** nothing it configures is reachable from outside the tailnet

#### Scenario: The documentation says so

- **WHEN** the box's tailnet documentation is read
- **THEN** it states that the public-exposure mode is never to be used here, and
  why
