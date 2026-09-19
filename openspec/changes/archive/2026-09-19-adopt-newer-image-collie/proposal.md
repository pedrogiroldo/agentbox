## Why

The image now ships a Collie release newer than the one the state volume pins,
and the box has no rule for that case. On a live box today the result was a
permanent deadlock: the image carries `versions/1.10.2` in the read-only
overlayfs layer, `agentbox-persist restore` lays `current -> versions/1.10.1`
over it, and every `collie update` then aborts with
`EXDEV: cross-device link not permitted` — the updater tries to clear its
destination path by renaming the image-layer `versions/1.10.2` into `.trash`,
and overlayfs refuses a rename of a lower-layer directory. The box stays on
the older release, and no amount of retrying moves it.

Two smaller defects came with it. The failed update left 123 MB of root-owned
`/opt/collie/.staging`, which `agentbox-persist save` then copied into the
state volume — garbage that persists and that, being root-owned, fails the
next update as the box's user with `EACCES`. And `docs/collie.md` promises the
in-place update "keeps winning until the next image rebuild", which the code
does not implement: the overlay wins unconditionally, rebuild or not.

## What Changes

- The prune learns the case it currently walks past: a release **from the
  image** that sorts newer than `current`. The box adopts it — points
  `current` at it and drops the stale pointer from the saved layer — instead
  of leaving it in place forever. A release staged *after boot* (an update
  caught between staging and the pointer flip) keeps its current protection;
  the build stamp the persistence layer already keeps separates the two.
- The prune learns about the staging directory: a partial download left by a
  failed update is removed with the superseded releases.
- The system layer stops saving the staging directory, so a failed update
  cannot leave root-owned garbage in the state volume for the next boot to lay
  back down.
- `docs/collie.md` stops promising behaviour the box does not have; it
  describes adoption as implemented.

## Capabilities

### New Capabilities

<!-- none -->

### Modified Capabilities

- `disk-hygiene`: the managed-release prune gains adoption of an image-shipped
  release newer than the current pointer, and gains the staging directory as
  something it removes; the persistence clause gains the staging directory as
  something it never retains.
- `mobile-web-ui`: the shipped-in-the-image requirement states which version
  wins after an image rebuild, and that an in-place update from inside the box
  is never blocked by what the image already carries.

## Impact

- `image/etc/collie.sh` — `prune()`: adoption branch, `.staging` in the doomed
  set, one log line per action.
- `image/etc/persist.sh` — `PRUNED` (or the equivalent exclusion) gains
  `/opt/collie/.staging`; `prune_managed` already runs before the scan and on
  the overlay copy, so adoption reaches the saved layer through it.
- `image/entrypoint.sh` — no new call site: the prune already runs where the
  Collie plugin is relinked, which is the moment a fresh image's release
  becomes visible.
- `docs/collie.md` (the "Updating it" section), `docs/persistence.md`.
- `tests/collie.sh` — a case that stages an image-side release newer than
  `current` and expects adoption, and a case for `.staging`.
- No change to Collie itself: the upstream `EXDEV` fallback stays filed and
  unowned by this box.
