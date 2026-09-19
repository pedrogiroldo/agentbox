## Context

See proposal.md — Why. Three facts shape the approach:

- `/opt/collie` is an image path under overlayfs. `rename(2)` of a directory
  that exists only in the lower layer returns `EXDEV`; `rm -rf` works, because
  overlayfs covers a removal with a whiteout. That asymmetry is why the box
  prunes on Collie's behalf at all (survive-small-vps, D8), and it is why
  Collie's updater cannot clear a destination path the image occupies.
- `agentbox-persist` keeps a *delta*: `changed_files()` copies what is newer
  than `/usr/share/agentbox/build-stamp`, and `restore` rsyncs the overlay
  over the fresh image. Nothing compares versions, so an older saved pointer
  beats a newer image release by construction.
- `prune()` in `image/etc/collie.sh` already runs in both the live tree and
  the overlay copy (`prune_managed` in `image/etc/persist.sh` calls it twice),
  at boot and before every save. This change needs no new call site.

## Goals / Non-Goals

**Goals:**

- One rule decides which release runs after a recreate, and it matches what
  `docs/collie.md` has been promising.
- A box that is already stuck unsticks itself on the next boot, with no
  operator action.
- A failed update leaves nothing behind that costs disk or breaks the next
  update.

**Non-Goals:**

- Fixing Collie's updater. The upstream `EXDEV` fallback stays filed and
  unowned here; the box must work against released Collie either way.
- A general "adopt the image's version" mechanism for every managed tree.
  Collie is the only tree that updates itself in place today; the prune stays
  generic in shape, but only Collie gets a version record.
- Deciding *which* Collie version an operator wants. `COLLIE_VERSION` at build
  time and an in-place update from inside the box remain the two levers.

## Decisions

### D1. The image records the release it shipped; mtimes do not decide

The prune must tell an image-shipped release from one staged since boot,
because the first should be adopted and the second must be left alone. The
build writes the version it installed to `/usr/share/agentbox/collie-version`
(the Dockerfile already runs `collie version` on the last line of that layer).
The prune reads it: the release named there is the image's, everything else
newer than `current` is a staged update.

*Alternatives considered.* Comparing each release directory's mtime against
`/usr/share/agentbox/build-stamp`, the test `agentbox-persist` already uses:
no new build artifact, but it misreads a case that actually happens — a
release staged mid-flight on an older image, restored into a box built later,
predates the new stamp and would be adopted as if the image shipped it.
Reading Collie's own `package.json` under each release: tells the version, not
the provenance, which is the thing in question.

When the record is missing — a box running an image built before this change —
the prune behaves exactly as it does today: it leaves anything newer than
`current` alone and says nothing. No adoption, no new failure mode.

### D2. Adoption is a pointer flip, and it is verified before it happens

Adopt when all of: the record exists; the release it names sorts newer than
`current`; that release tree is present; and it looks usable —
`bin/collie` is executable and `herdr-plugin.toml` is there, the two paths the
box itself depends on (`/usr/local/bin/collie` resolves through the first,
`herdr plugin link` through the second). Then `current` is repointed and one
line is logged saying which version was adopted and which it replaced.

A tree that fails the check is left untouched with one line, rather than
adopted into a box that then has no working `collie` command.

The release that was current becomes the immediate predecessor and is kept by
the existing rule — the 85 MB rollback survive-small-vps chose deliberately.

### D3. The overlay's pointer is dropped, not rewritten

Adoption must also stop the state volume from re-pinning the old release at
the next boot. The live flip alone would do it, since `save` copies the new
symlink (its mtime postdates the stamp) — but only once a save has run, and a
box that is recreated in between would restore the stale pointer and need a
second boot to settle.

So the adoption path removes `current` from the overlay when it points at the
release being superseded. A recreate then finds no pointer in the saved layer
and the image's own `current` shows through, which is the same answer. This
widens the existing exception in `image/etc/persist.sh` — the overlay is
edited by nothing but `save`, `forget` and the managed prune — from
`versions/` to `versions/` plus the pointer beside it. It stays confined to
`/opt/collie`.

### D4. Ordering at boot: adopt, then relink the plugin

herdr records a plugin by its resolved path, so the relink must see the
adopted release or the phone's buttons keep pointing at the superseded tree
until the boot after. The entrypoint already calls the prune and
`herdr plugin link` in the same block; the change keeps the prune first and
makes the ordering explicit in a comment, since it is now load-bearing.

### D5. `.staging` is prune's to remove and persist's never to keep

`prune` removes `$base/.staging` on the same footing as `.trash`: it is
Collie's scratch space, it means nothing between runs, and a failed update
leaves it full. It runs as root, so a directory the updater left owned by
another user is still removable.

`/opt/collie/.staging` also joins `PRUNED` in `image/etc/persist.sh`, so the
five-minute scan never walks a partial download at all. Both, not one: the
exclusion keeps it out of the saved layer and off the scan's hot path, and the
removal reclaims the disk the failed update took.

## Risks / Trade-offs

- **An operator wanted the older release.** → The image is the floor by
  documented contract, and the way to sit above it is the same as before: an
  in-place update, whose result sorts newer than the image's record and is
  therefore never adopted away. A build-time pin (`COLLIE_VERSION`) still
  decides the floor itself.
- **Adoption flips a release the operator has not tested.** → It is the
  release the image they just deployed carries, and the predecessor stays on
  disk for a rollback. The log line names both versions.
- **The version record drifts from what is installed** (a hand-edited box, a
  future installer change). → The check in D2 makes a wrong record
  non-destructive: adoption is refused rather than pointing `current` at a
  tree that is not there.
- **Removing `current` from the overlay is a write outside `save`.** → It is
  the same exception the prune already holds, and it only ever removes a
  pointer at a release the live tree has just superseded.
- **A release stays that no longer needs to.** Adopting the image's release
  keeps one predecessor, so a box can hold 170 MB of Collie plus the image's
  copy. → Unchanged from today's rule; the alternative costs the rollback.

## Migration Plan

No state migration. The first boot on the new image adopts, logs one line,
and drops the stale pointer. A box already deadlocked — the one this change
came from — takes the same path with no operator action; the manual sequence
applied by hand today (remove `.staging`, repoint `current`, prune, forget the
saved tree) is exactly what the code will do.

Rollback is the previous image: nothing in the state volume changes shape, and
an older `agentbox-collie` simply stops adopting.
