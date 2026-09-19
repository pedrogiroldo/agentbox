## 1. Control groups and priorities

- [x] 1.1 Write `image/etc/cgroup.sh` (`agentbox-cgroup`) with `setup`, `enter <group> [pid]` and `status`: setup creates `control`, `work` and `docker` under the container root, writes `cpu.weight` 1000/100/100, moves pid 1 and the caller into `control`, enables `+cpu +memory +pids` on the root, and undoes everything on any refusal while naming the file; verify by running it in a privileged test container and reading the resulting tree
- [x] 1.2 Derive the memory reserve in `agentbox-cgroup setup` from `AGENTBOX_CONTROL_RESERVE` (10% of `memory.max` or `MemTotal`, clamped to 384M..1G; `0` skips), write `memory.min` on `control` and `memory.high` on `work`, and set `pids.max` on `work`; verify the three values read back as written and that `0` leaves them at defaults
- [x] 1.3 Implement the `nice` fallback and `AGENTBOX_ISOLATION` handling (`auto`, `cgroup`, `nice`, `off`) in `agentbox-cgroup setup`, including the fatal path for `cgroup`; verify each mode's outcome in a test container with the tree made read-only for the fallback cases
- [x] 1.4 Add the OOM ordering to the entrypoint after each control-plane service starts (`-1000` herdr server, `-900` collie and tailscaled), applied in every mode; verify by reading `/proc/<pid>/oom_score_adj` of each after boot
- [x] 1.5 Call `agentbox-cgroup setup` as the entrypoint's first step and make `agentbox-dockerd start` enter `docker` and `agentbox-persist watch` enter `work` before their daemons start; verify `cat /proc/<pid>/cgroup` for dockerd, containerd and the watcher after boot

## 2. Panes and shells

- [x] 2.1 Write `image/etc/pane-shell.sh` (`agentbox-pane-shell`): enter `work` through `sudo -n agentbox-cgroup enter work $$`, restore `SHELL` from `AGENTBOX_PANE_SHELL`, `exec` that shell with all arguments; fall through to the exec when the enter fails; verify with a manual pane that `$SHELL`, `$0` and `/proc/self/cgroup` are as specified
- [x] 2.2 Make `agentbox-herdr start` launch the server with `SHELL=agentbox-pane-shell` and `AGENTBOX_PANE_SHELL=<passwd shell>`; verify `herdr` opens a pane in the user's shell and the pane's cgroup is `work`
- [x] 2.3 Move the box user's interactive SSH shell into `work` from `env.sh` after login, leaving root shells alone; verify `/proc/self/cgroup` in an SSH session and in `make root`

## 3. Status and documentation of isolation

- [x] 3.1 Implement `agentbox-cgroup status` reporting mode, live CPU weights, live memory floor and ceiling, OOM scores, and the refusing file in fallback modes; verify its output in `cgroup`, `nice` and `off` boots
- [x] 3.2 Add `AGENTBOX_ISOLATION` and `AGENTBOX_CONTROL_RESERVE` to `docker-compose.yml`, `deploy/docker-compose.ghcr.yml` and `.env.example` with the same voice as the existing variables; verify `docker compose config` renders them
- [x] 3.3 Write `docs/small-vps.md` (what is protected, what is not, the measured cost per agent session, why the host needs swap, what changes unprivileged) and link it from `docs/deploy.md`, `docs/security.md` and both READMEs; verify the links resolve

## 4. Collie release pruning

- [x] 4.1 Add `agentbox-collie prune` that keeps the release `current` resolves to plus the newest older one, removes the rest and `.trash`, refuses on an unexpected layout with one log line; verify with a staged fake tree of five releases and one staged-newer directory
- [x] 4.2 Call the prune from the entrypoint where the plugin is relinked and from `agentbox-persist save` before the scan, and make `agentbox-persist` drop superseded releases from the overlay instead of restoring them; verify a persistence test that stages releases, saves, recreates and finds only two in `/opt/collie/versions` and in the overlay
- [x] 4.3 Update `docs/collie.md` (updating section) and `docs/persistence.md` (the one place the overlay is edited) to describe the pruning; verify the text matches the behaviour of 4.1 and 4.2

## 5. Disk hygiene

- [x] 5.1 Write `image/etc/clean.sh` (`agentbox-clean`) with the tier table (path, measure, reclaim) driving both the report and the verbs, the fixed "yours" list, `--dry-run`, and the no-verb report that deletes nothing; verify the report on a populated home and that a file count before and after is identical
- [x] 5.2 Implement the `caches` verb: each tool's own prune with a timeout and a skip message, npx entries older than seven days, superseded plugin cache versions, `~/.claude.json.tmp.*`, Trash; verify on a home with seeded caches that each is reduced and the "yours" paths are untouched
- [x] 5.3 Implement the `browsers`, `docker` and `all` verbs; verify `caches` leaves browsers in place, `browsers` names the reinstall command, and `docker` removes only unreferenced images
- [x] 5.4 Add `AGENTBOX_CLEAN_INTERVAL` (default off) as a timer the entrypoint starts in `work`, logging to the state volume; verify it runs the `caches` tier at the interval when set and never when unset
- [x] 5.5 Add the motd line: the persist watcher caches home size and rebuildable share on its pass, `greet.sh` prints the line above `AGENTBOX_CLEAN_WARN` (default `20G`) or above a half rebuildable share; verify by seeding the cache file with values on both sides of the threshold
- [x] 5.6 Add `make clean` (report and verbs) to the Makefile and document `agentbox-clean` in `docs/small-vps.md` and `docs/persistence.md`; verify `make clean` prints the in-box report

## 6. Tests and CI

- [x] 6.1 Write `tests/isolation.sh`: boots privileged, asserts the cgroup tree and OOM scores, opens a shell via `docker exec` (the rescue-path check), saturates `work` with busy loops, and asserts an SSH login and `agentbox-herdr status` complete within a bound; then boots with `AGENTBOX_ISOLATION=off` and `nice` and asserts the status output; verify it passes locally against a built image
- [x] 6.2 Extend `tests/collie.sh` with the pane-shell assertions (`$SHELL` is the passwd shell, the pane is in `work`) and the prune scenario from 4.1; verify it passes locally
- [x] 6.3 Extend `tests/persistence.sh` with the superseded-release drop from 4.2; verify it passes locally
- [x] 6.4 Write `tests/clean.sh`: seeds caches and "yours" paths, asserts the report deletes nothing, `caches` reduces caches and leaves the rest, `browsers` is separate; verify it passes locally
- [ ] 6.5 Add the new tests to `.github/workflows/docker-image.yml` and to the Makefile's `test-*` targets; verify the workflow runs them on a pull request and the run is green
