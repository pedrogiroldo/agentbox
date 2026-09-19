## MODIFIED Requirements

### Requirement: Release trees the box manages are pruned by the box

Where the box installs software as a versioned tree with a pointer to the
current release, and lets that software update itself in place, the box SHALL
remove superseded releases so that at most the current release and its
immediate predecessor remain. Pruning SHALL run at boot and before each
periodic save of the system layer, SHALL never remove the current release,
SHALL refuse to act when the tree's layout is not the one it expects, logging
one line, and SHALL remove a partial staging directory left behind by an
update that did not finish.

A release newer than the current pointer SHALL be treated by where it came
from, not by its version alone:

- A release the **image** ships that is newer than the current pointer SHALL
  be adopted: the box points current at it and logs one line. The superseded
  pointer SHALL be dropped from the saved system layer, so the adoption holds
  across a recreate rather than being undone at the next boot.
- A release staged **after the box booted**, newer than the current pointer,
  SHALL be left exactly as it is: it is an update caught between staging and
  the pointer flip, and it is not the box's to touch.

The system-layer persistence SHALL NOT retain a superseded release: one that
was saved before it was superseded SHALL be dropped from the saved layer once
pruned, rather than restored on the next boot. The system layer SHALL NOT
retain a staging directory at all.

#### Scenario: Leftovers after several updates

- **WHEN** the box boots with five releases in a managed tree, the current
  one pointing at the newest
- **THEN** after boot only the newest and the one before it remain, and the
  saved system layer holds no others

#### Scenario: The image ships a newer release than the saved pointer

- **WHEN** a box whose saved system layer pins the current pointer at an
  older release boots from an image that ships a newer one
- **THEN** the box points current at the release the image ships, says so in
  one line, and the saved layer no longer pins the older pointer

#### Scenario: An update caught mid-flight

- **WHEN** pruning runs while a release newer than the current pointer has
  been staged since boot but not yet pointed at
- **THEN** the staged release is left in place

#### Scenario: A failed update leaves a staging directory

- **WHEN** an in-place update fails partway and leaves a partial download in
  the tree's staging directory
- **THEN** the next prune removes it, and no part of it reaches the saved
  system layer

#### Scenario: An unexpected layout

- **WHEN** the current pointer does not resolve into the versions directory
- **THEN** nothing is removed and the box logs one line saying why
