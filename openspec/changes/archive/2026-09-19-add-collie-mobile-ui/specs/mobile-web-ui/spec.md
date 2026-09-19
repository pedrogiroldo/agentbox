## Purpose

Reaching the box's running agents from a phone browser instead of a phone
terminal — seeing which agent is waiting on you, reading its output and
answering it by tapping and typing normally, rather than by driving a terminal
multiplexer through chorded keys on a soft keyboard.

## ADDED Requirements

### Requirement: The mobile web interface ships in the image

The box SHALL ship the mobile web interface as part of the image, installed
under a system prefix outside the home volume, with its command on the PATH of
interactive shells. It SHALL NOT be fetched at boot, and a box with no network
access SHALL still have it.

The installed version SHALL be selectable at build time through a version
argument, so an image can be pinned and rebuilt reproducibly.

Because the install lives under the system prefix, it SHALL fall under the
box's existing system-layer persistence contract: an in-place update performed
from inside the box SHALL survive a container recreate.

#### Scenario: A freshly built box has it

- **WHEN** an interactive shell opens in a box built from the shipped image
- **THEN** the mobile interface's command is on the PATH and reports its version

#### Scenario: The version is pinned at build time

- **WHEN** the image is built with the version argument set to a specific
  released version
- **THEN** the installed command reports that version

#### Scenario: An in-place update outlives a recreate

- **WHEN** the interface is updated in place inside the box, and the container
  is then recreated from the same image
- **THEN** the updated version is what the box reports, not the version the
  image shipped

### Requirement: The multiplexer exposes the interface's controls

The box SHALL register the shipped install with the multiplexer on every boot,
so the interface's own lifecycle controls appear inside the multiplexer
alongside the agent integrations the box already installs.

Registration SHALL be idempotent: registering an already-registered install
SHALL leave the box in the same state and SHALL NOT be reported as an error.

A failure to register SHALL be a warning and SHALL NOT prevent the box from
booting or from serving SSH.

#### Scenario: Registration on a normal boot

- **WHEN** the box boots with the multiplexer available
- **THEN** the shipped install is registered with it, and its controls are
  listed among the multiplexer's plugin actions

#### Scenario: Registration repeated across boots

- **WHEN** the box is restarted after a boot that already registered the install
- **THEN** the box boots normally and the install is registered exactly once

#### Scenario: Registration fails

- **WHEN** registration cannot complete
- **THEN** the box logs a warning naming what failed
- **AND** SSH still becomes available

### Requirement: The box decides whether the interface runs

Running the interface SHALL be a decision the operator makes, not a consequence
of installing it. The box SHALL read a single environment variable,
`AGENTBOX_COLLIE`, with three states:

- `off` — never start it. This SHALL be the default.
- `auto` — start it, and treat a failure to start as a warning.
- `on` — start it, and treat a failure to start as a boot failure.

The default of `off` is normative, not an implementation preference: a running
interface grants keystroke-level access to live panes, and its read surface is
open to anything that reaches its address.

#### Scenario: The shipped default

- **WHEN** a box boots with no `AGENTBOX_COLLIE` set
- **THEN** no interface process is listening
- **AND** the command is still installed and runnable by hand

#### Scenario: Started on request

- **WHEN** a box boots with `AGENTBOX_COLLIE=auto`
- **THEN** the interface is listening on its configured port once boot completes

#### Scenario: Required but unavailable

- **WHEN** a box boots with `AGENTBOX_COLLIE=on` and the interface cannot start
- **THEN** the box reports the failure and does not present itself as ready

#### Scenario: Requested but unavailable

- **WHEN** a box boots with `AGENTBOX_COLLIE=auto` and the interface cannot start
- **THEN** the box logs a warning naming the reason
- **AND** SSH still becomes available

### Requirement: The box provides a lifecycle command for the interface

The box SHALL provide a command, `agentbox-collie`, that manages the interface
from inside the box and is usable both by the boot sequence and by hand from an
interactive shell.

It SHALL support, at minimum: starting the interface, stopping it, reporting
whether it is running, and reporting the address it is reachable at.

The status output SHALL distinguish *not configured to run*, *configured but not
running*, *running but with no way in*, and *running*, so that
`AGENTBOX_COLLIE=off` is never mistaken for a crash and a box with no front door
is never mistaken for a working one.

#### Scenario: Status on a default box

- **WHEN** `agentbox-collie status` runs on a box with `AGENTBOX_COLLIE` unset
- **THEN** it reports that the interface is installed and deliberately not
  running, and names the variable that would start it

#### Scenario: Start and stop by hand

- **WHEN** the interface is started with `agentbox-collie start` and then stopped
  with `agentbox-collie stop`
- **THEN** status reports running between the two, and not running after

#### Scenario: Status names the address

- **WHEN** status runs while the interface is running on a box that has joined a
  tailnet
- **THEN** the output names the tailnet address a phone would open

#### Scenario: Status with no front door

- **WHEN** status runs while the interface is running on a box that has not
  joined a tailnet
- **THEN** the output says the interface is reachable from nowhere, and names
  what would change that

### Requirement: The interface keeps its own defaults

The interface's default deployment — bound to loopback, with the tailnet client
on the same machine terminating TLS and injecting the caller's identity — works
inside this container as written. The box SHALL therefore run it that way rather
than reshaping it.

Specifically, the box SHALL NOT bind the interface to any address beyond
loopback, SHALL NOT publish a port for it, and SHALL NOT prevent it from
managing its own tailnet front door.

The box SHALL NOT disable host-header validation or the same-origin check on the
operator's behalf.

The box SHALL name the multiplexer for it, since the box has exactly one, and
SHALL pass the operator's identity and port settings through unchanged.

#### Scenario: Nothing is published

- **WHEN** the interface is running on a box brought up from the shipped compose
  file
- **THEN** no port other than the SSH port is published
- **AND** the interface is not reachable from the container's own address

#### Scenario: Reachable on the tailnet

- **WHEN** the box has joined a tailnet and the interface is running
- **THEN** another node on that tailnet reaches it over TLS on the box's tailnet
  name

#### Scenario: Validation is not silently disabled

- **WHEN** the box configures the interface
- **THEN** it does not turn off host-header validation or the same-origin check

#### Scenario: The identity check is the operator's

- **WHEN** the operator sets the trusted identity
- **THEN** that value reaches the interface unchanged, and a request from a
  different identity on the same tailnet is refused

### Requirement: The interface depends on a front door and says so

The interface has no way in of its own. The box SHALL treat tailnet membership
as a precondition for running it: when the box has not joined, the box SHALL
refuse to report the interface as ready and SHALL name the missing piece rather
than leaving the operator with a service nothing can reach.

#### Scenario: Enabled without a tailnet

- **WHEN** the operator enables the interface on a box that has not joined a
  tailnet
- **THEN** the box says that the interface has no front door, and names the
  variable that would give it one

#### Scenario: Enabled with a tailnet

- **WHEN** the operator enables both
- **THEN** the interface comes up and the box reports the tailnet address it is
  reachable at

### Requirement: Push notifications are ready without being asked for

Being told that an agent is waiting on you is most of the reason to reach for a
phone at all, so the box SHALL prepare push notifications as part of starting
the interface rather than leaving them as a later step.

Before the interface starts, the box SHALL ensure a push keypair exists. It
SHALL generate one only when none exists: an existing keypair SHALL NOT be
replaced, because replacing it silently unsubscribes every device that had
already accepted notifications.

The keypair SHALL live where the box already persists user state, so that
devices stay subscribed across a container recreate.

The box SHALL NOT attempt to grant the browser's notification permission on the
operator's behalf; that decision belongs to the person holding the phone, and
the box SHALL say that this step remains.

The contact address published to the push provider SHALL be taken only from an
explicit setting. The box SHALL NOT derive it from any other identity it holds.

An operator SHALL be able to turn the whole behaviour off.

#### Scenario: A first start prepares push

- **WHEN** the interface is started on a box that has never had a push keypair
- **THEN** a keypair exists before the interface begins serving

#### Scenario: A later start leaves subscriptions alone

- **WHEN** the interface is started again on a box that already has a keypair
- **THEN** the existing keypair is unchanged
- **AND** devices already subscribed remain subscribed

#### Scenario: Subscriptions outlive a recreate

- **WHEN** a device has accepted notifications and the container is recreated
  from the same image
- **THEN** the keypair is the same one and the device is still subscribed

#### Scenario: The remaining step is named

- **WHEN** the operator asks the box for the interface's status while it runs
- **THEN** the output says push keys are ready and that permission is granted on
  the phone

#### Scenario: The contact is not invented

- **WHEN** no contact address has been configured
- **THEN** the box passes none, and no address it holds for another purpose is
  used

#### Scenario: Turned off

- **WHEN** the operator disables the behaviour
- **THEN** starting the interface generates no keypair, and the status output
  says so

### Requirement: The box states the interface's security posture

The box SHALL document, in its own security documentation and not only by
reference, that:

- the interface sends arbitrary keystrokes into live panes, in a container that
  runs privileged, and is therefore equivalent to shell access to the box;
- its device gates protect writes only, and read access — pane output, source
  code, environment values, agent output — is open to anything that passes the
  origin check;
- the write gate is inactive until the operator pairs a first device, so an
  unpaired interface accepts writes from any reader.

#### Scenario: The security documentation covers it

- **WHEN** the box's security documentation is read
- **THEN** it names all three of the above in its own words, and states the
  shipped default of not running

### Requirement: The interface's state survives a recreate

Everything the interface accumulates that represents a decision the operator
made — its configuration, the credentials of paired devices, and the transcript
history it keeps beyond terminal scrollback — SHALL live where the box already
persists user state, and SHALL survive a container recreate without extra
configuration.

#### Scenario: A paired phone stays paired

- **WHEN** a phone is paired, and the container is then recreated from the same
  image
- **THEN** the phone still holds a valid credential and is not asked to pair
  again

#### Scenario: History outlives the container

- **WHEN** the container is recreated
- **THEN** conversation history the interface had recorded is still readable
