## MODIFIED Requirements

### Requirement: The mobile web interface ships in the image

The box SHALL ship the mobile web interface as part of the image, installed
under a system prefix outside the home volume, with its command on the PATH of
interactive shells. It SHALL NOT be fetched at boot, and a box with no network
access SHALL still have it.

The installed version SHALL be selectable at build time through a version
argument, so an image can be pinned and rebuilt reproducibly.

Because the install lives under the system prefix, it SHALL fall under the
box's existing system-layer persistence contract: an in-place update performed
from inside the box SHALL survive a container recreate, and SHALL keep winning
until the image ships a version newer than it. When it does, the box SHALL run
the version the image ships, and an operator who wants a newer one SHALL be
able to update in place again from there.

An in-place update SHALL NOT be blocked by a release the image already
carries. Where the box cannot let the interface move such a release aside, the
box SHALL resolve it rather than leaving the interface to fail the same way on
every attempt.

The box SHALL prune the interface's release tree: after boot and before each
periodic save, at most the current release and its immediate predecessor
SHALL remain under the system prefix, and the saved system layer SHALL hold
no other release. The current release, and any release staged newer than it
since the box booted, SHALL never be removed by the box.

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

#### Scenario: The image catches up with the in-place update

- **WHEN** a box carrying an in-place update to version N is recreated from a
  newly built image that ships version N+1
- **THEN** the box reports N+1

#### Scenario: Updating in place from a box the image just caught up with

- **WHEN** an operator runs the interface's in-place update on that box and a
  version newer than the image's is available
- **THEN** the update completes and the box reports the newer version, with no
  error about the release the image carries

#### Scenario: Old releases do not accumulate

- **WHEN** the interface has been updated in place several times and the
  container is then restarted
- **THEN** only the current release and the one before it remain installed,
  and the saved system layer holds no other release
