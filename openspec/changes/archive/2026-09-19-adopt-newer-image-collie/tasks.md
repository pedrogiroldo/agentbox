## 1. The image says what it shipped

- [x] 1.1 Write the installed Collie version to `/usr/share/agentbox/collie-version` in the Collie layer of the `Dockerfile`, from the same `collie version` call that already ends it (bare version, no build suffix); verify a freshly built image has the file and that its contents match `basename "$(readlink -f /opt/collie/current)"`
- [x] 1.2 Document the file beside the build stamp wherever `/usr/share/agentbox` is described, so a future installer change knows it is load-bearing; verify by grepping the docs for the path

## 2. Adoption in the prune

- [x] 2.1 Teach `prune()` in `image/etc/collie.sh` to read the version record and classify a release newer than `current` as image-shipped or staged-since-boot, treating a missing or unreadable record as "everything newer is staged" (today's behaviour, silent); verify with a unit-style run against a fixture tree with and without the record
- [x] 2.2 Implement the adoption branch: when the recorded release sorts newer than `current`, its tree exists, `bin/collie` is executable and `herdr-plugin.toml` is present, repoint `current` at it and log one line naming both versions; refuse with one line when the usability check fails; verify both paths in a fixture tree (`sort -V` ordering, a deliberately gutted tree for the refusal)
- [x] 2.3 Make the adoption path drop `current` from the overlay copy when it points at the release just superseded, and leave the overlay alone otherwise; verify in a fixture that the overlay pointer is gone after adoption and untouched when nothing was adopted
- [x] 2.4 Add `.staging` to the doomed set beside `.trash`, removed as root regardless of its owner; verify a root-owned staging directory full of files is gone after one prune run
- [x] 2.5 Confirm the prune still refuses an unexpected layout and still leaves a release staged since boot alone, now that a second "newer than current" case exists; verify with the existing layout fixture plus one where the staged release is not the recorded one

## 3. The saved layer stops carrying scratch space

- [x] 3.1 Add `/opt/collie/.staging` to `PRUNED` in `image/etc/persist.sh`; verify `agentbox-persist save` with a populated staging directory copies none of it into the overlay and that the scan does not descend into it
- [x] 3.2 Confirm `prune_managed` reaches both trees in the new code path (live tree adopts, overlay copy loses the stale pointer) and that `restore`'s pre-prune does not undo an adoption; verify by a save/recreate/restore cycle in the persistence test

## 4. Boot ordering

- [x] 4.1 Keep the prune ahead of `herdr plugin link` in `image/entrypoint.sh` and say in a comment why the order is now load-bearing; verify after a boot that adopted the release that `herdr plugin list` resolves to the adopted tree, not the superseded one

## 5. Tests

- [x] 5.1 Extend `tests/collie.sh` with the adoption case: stage an older `current` plus a newer release named by a written version record, run the prune, and expect `current` repointed, one log line, the predecessor kept and the overlay pointer dropped
- [x] 5.2 Add the refusal case (record names a release whose tree is gutted) and the staged-mid-flight case (a newer release the record does not name) to `tests/collie.sh`; expect no adoption in either and the tree intact
- [x] 5.3 Add the `.staging` case: a root-owned staging directory is removed by the prune and never appears under `/var/lib/agentbox/overlay`; verify in the same smoke test
- [x] 5.4 Run the full smoke suite (`tests/`) against a locally built image and confirm the Collie, Persistence, Clean and Isolation tests pass together

## 6. Documentation

- [x] 6.1 Rewrite the "Updating it" section of `docs/collie.md`: the image is the floor, an in-place update wins until the image ships something newer, and what the box logs when it adopts; remove the promise the code did not keep; verify the section matches the shipped behaviour line by line
- [x] 6.2 Note in `docs/persistence.md` that the managed prune may drop the Collie pointer from the saved layer, extending the existing exception, and that staging directories are never saved; verify the file's exception list reads as one rule
