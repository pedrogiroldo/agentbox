## 1. The endpoint the box advertises

- [x] 1.1 Add `AGENTBOX_SSH_HOST` and `AGENTBOX_SSH_PORT` to the `for var in ...`
  loop in `image/entrypoint.sh` (§2b, around line 93) so both reach interactive
  shells; verify by booting the image with both set and reading them back in a
  shell opened over SSH, not just with `docker exec`.
- [x] 1.2 Default `AGENTBOX_SSH_PORT` to `2222` in `docker-compose.yml` and
  `deploy/docker-compose.ghcr.yml`, and pass `AGENTBOX_SSH_HOST` through
  unset-by-default; verify `docker compose config` renders both with no `.env`
  present.
- [x] 1.3 Document both variables in `.env.example` under a new mirroring
  section, explaining that the host is what a client outside dials and that the
  port must match the published one; verify `make init` still produces a `.env`
  that boots.

## 2. `agentbox-mirror`

- [x] 2.1 Create `image/etc/mirror.sh` with the house header comment (why the
  box only prints, why nothing is installed, what the four calls do) and the
  argument dispatch: verb when the first argument matches a reserved word and is
  not a directory under `~/projects`, project otherwise; verify by running each
  of the four forms in a booted container.
- [x] 2.2 Implement project resolution — bare name against `~/projects`, else a
  path relative to the working directory, else absolute — always emitting an
  absolute remote path; verify `agentbox-mirror myapp` and
  `agentbox-mirror ~/work/other` both print the correct absolute path, and a
  nonexistent project exits non-zero naming the path it looked for.
- [x] 2.3 Implement endpoint assembly in Mutagen's SCP-like form
  `dev@<host>:<port>:<abs-path>`, substituting `<your-server>` and printing the
  variable name to set when `AGENTBOX_SSH_HOST` is unset; verify both the
  configured and unconfigured outputs by diffing them.
- [x] 2.4 Define the ignore list as a single constant (`node_modules/`, `.venv/`,
  `__pycache__/`, `target/`, `build/`, `.gradle/`, `.cxx/`, `local.properties`,
  `dist/`, `.next/`, `.DS_Store`, `*.swp`) rendered as one `--ignore=` argument,
  with `--ignore-vcs` deliberately absent; verify the printed command contains
  the Gradle entries and no VCS-ignore flag.
- [x] 2.5 Implement deterministic session naming: `agentbox-<project>` sanitised
  to Mutagen's accepted character set; verify a project directory with dots,
  spaces or uppercase in its name still yields a name Mutagen accepts by pasting
  the printed command against a real box.
- [x] 2.6 Implement the no-argument overview: what a mirror is for, the projects
  under `~/projects`, and a pointer to `docs/mirror.md`; verify it exits zero on
  a box with no projects at all.
- [x] 2.7 Implement `agentbox-mirror check` — SFTP subsystem present in the
  running sshd config (failure), agent directory writable by the login user
  (failure), host configured (warning) — with per-condition output; verify exit
  status is non-zero with the subsystem removed and zero with only the host
  unset.
- [x] 2.8 Implement `agentbox-mirror project <name>` emitting a valid
  `mutagen.yml` on stdout with the same endpoint and ignores, and nothing else
  on stdout; verify `agentbox-mirror project myapp > mutagen.yml &&
  mutagen project start` works from a real client.

## 3. Wiring the script into the image

- [x] 3.1 `COPY image/etc/mirror.sh /usr/local/bin/agentbox-mirror` in the
  `Dockerfile` alongside its siblings, and add it to the `chmod +x` list in the
  following `RUN`; verify `agentbox-mirror` is executable and on `PATH` for
  `dev` in a fresh container.
- [x] 3.2 Add a line naming `agentbox-mirror` to `image/etc/make-motd.sh`,
  keeping the summary within the height budget the greeter enforces; verify the
  motd still fits by logging in at 70x26 and confirming it is not truncated.

## 4. The local side

- [x] 4.1 Add `AGENTBOX_SSH_HOST` to the `env_value` reads at the top of the
  `Makefile`, defaulting to `SSH_HOST`; verify `make help` prints without error
  with and without a `.env`.
- [x] 4.2 Add `make mirror PROJECT=<name> [LOCAL=<path>]` creating the session
  against the configured host and port; verify it creates a session visible in
  `mutagen sync list` and that files written in the box appear locally.
- [x] 4.3 Add `make mirror-status` filtering `mutagen sync list` to this box's
  session prefix, and `make unmirror PROJECT=<name>` terminating one session;
  verify unmirror leaves both copies of the files intact.
- [x] 4.4 Guard all three targets with a `command -v mutagen` check that fails
  with per-platform install instructions; verify the message appears by running
  a target with `PATH` stripped of Mutagen.
- [x] 4.5 Add the three targets to `.PHONY` and confirm they carry `##` help
  text; verify they appear in `make help`.

## 5. Documentation

- [x] 5.1 Write `docs/mirror.md` in English matching its siblings: why mirroring
  rather than forwarding, installing Mutagen per platform, the box command, the
  `make` targets, the ignore defaults and how to extend them, conflict behaviour
  under `two-way-safe`; verify every command in it runs as written against a
  real box.
- [x] 5.2 Add the Android walkthrough to `docs/mirror.md` end to end — agent
  edits in the box, Gradle and `adb` on the laptop, why `local.properties` and
  `build/` are ignored, what to do when the agent and a local build race;
  verify against an actual Gradle project mirrored out of a box.
- [x] 5.3 Add a mirroring section to `README.md` (pt-BR) and `README.en.md`, and
  a `docs/mirror.md` row to both documentation indexes; verify the links resolve.
- [x] 5.4 Add the sentence to `docs/security.md` noting that a mirror puts the
  box's code — including whatever an agent checked out — on the laptop, widening
  the blast radius; verify it sits in the existing exposure discussion rather
  than as an orphan section.

## 6. Tests and CI

- [x] 6.1 Write `tests/mirror.sh` in the shape of `tests/docker.sh`: boot the
  image with a known host and port, assert `agentbox-mirror check` exits zero,
  assert the printed command carries the expected endpoint, session name and
  Gradle ignores and carries no VCS-ignore flag, and assert a nonexistent
  project exits non-zero; verify the script passes locally and fails when an
  assertion is deliberately broken.
- [x] 6.2 Assert in `tests/mirror.sh` that the unconfigured-host path prints the
  placeholder and still exits zero; verify by booting a second container with
  `AGENTBOX_SSH_HOST` unset.
- [x] 6.3 Add a `test-mirror` target to the `Makefile` next to `test-docker` and
  add the script to `.github/workflows/docker-image.yml` alongside the existing
  smoke tests; verify the workflow passes on a branch push.
