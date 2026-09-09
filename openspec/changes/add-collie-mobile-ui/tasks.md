## 1. Prove the assumptions the rest is built on

- [x] 1.1 In a booted box, start the herdr server by hand, install Collie into
  `/opt/collie` by hand, and run `herdr plugin link` against it; verify the
  plugin's actions appear in `herdr plugin action list`, and note both the
  correct link target and whether the link requires a running server, since that
  fixes the boot ordering in §5.
- [x] 1.2 With Collie running against that hand-made setup, confirm the bridge
  reaches the herdr control socket and the dashboard lists the box's panes;
  verify by opening the URL from another machine and seeing a pane a shell
  created.
- [x] 1.3 Record the installed herdr version and confirm it is at or above
  Collie's floor of 0.7.0; verify with `herdr --version`.
- [ ] 1.4 In a container with no `/dev/net/tun` and no added capability, run
  `tailscaled --tun=userspace-networking`, join a tailnet, and `tailscale serve`
  a loopback port; verify another node on the tailnet reaches it over TLS —
  this is the premise the whole design replaced the old one for, so it is
  checked before anything is built on it.

## 2. Collie in the image

- [x] 2.1 Add a `COLLIE_VERSION` build argument to the `Dockerfile` next to the
  other pinned versions, defaulting to `latest`; verify
  `docker build --build-arg COLLIE_VERSION=<a released tag>` produces an image
  whose `collie version` reports that tag.
- [x] 2.2 Add the Collie install layer after the herdr layer, running the
  release install script with `COLLIE_DIR=/opt/collie`, linking the binary into
  `/usr/local/bin/collie`, and normalising ownership and modes afterwards (the
  tarball unpacks `versions/` world-writable and owned by uid 1001); verify
  `collie version` answers in a fresh container with networking disabled, and
  that nothing under `/opt/collie` is group- or world-writable.
- [x] 2.3 Add a `COLLIE_CACHEBUST` argument alongside `AGENTS_CACHEBUST` and
  wire it into `make update`, so `latest` actually re-resolves; verify
  `make update` passes both.
- [ ] 2.4 Confirm `/opt/collie` is captured by the system-layer persistence
  contract; verify by touching a file under `/opt/collie` inside a box,
  recreating the container from the same image, and finding it still present.

## 3. Tailscale in the image

- [x] 3.1 Add an `INSTALL_TAILSCALE` build argument (default true) and install
  the `tailscale` package from its own apt repository, in the style of the
  existing GitHub CLI and Docker repository blocks; verify `tailscale version`
  and `tailscaled --version` both answer in a fresh container.
- [ ] 3.2 Confirm the package is recorded by the apt baseline the image writes
  last, so `agentbox-persist` does not try to reinstall what the image already
  ships; verify by booting and reading the replay log.

## 4. `agentbox-tailscaled`

- [x] 4.1 Create `image/etc/tailscaled.sh` with the house header comment — why
  userspace networking rather than a TUN device, why the state lives in the
  state volume, and the `AGENTBOX_TAILSCALE` states — and the verb dispatch for
  `ensure`, `start`, `stop`, `status`; verify each verb runs and exits zero in a
  booted container with `AGENTBOX_TAILSCALE` unset.
- [x] 4.2 Implement `start`: launch `tailscaled --tun=userspace-networking` with
  `--statedir=/var/lib/agentbox/tailscale` — the directory, not just the state
  file, so the `serve` certificates and profile data land on the volume too —
  and its log beside the box's other logs, then wait for the daemon's socket to
  answer; verify the state directory is created on the volume, that nothing is
  written under `/var/lib/tailscale`, and that `certs/` appears there once
  `serve` has run.
- [x] 4.3 Implement the unattended join: when the box is not already a member
  and `TS_AUTHKEY` is set, run `tailscale up --authkey --operator=<box user>`
  (plus `--hostname` from `TS_HOSTNAME`); with no key, do not block the boot and
  do not launch a blocking `tailscale up` into the background — log the `login`
  command instead. Verify a first boot with a valid key comes up as an online
  node with no interaction, and that a boot without one names the command.
- [x] 4.8 Implement `login`: start the daemon if needed, re-run under `sudo`
  when not root (saying so), refuse to re-authenticate a box that has already
  joined, then run `tailscale up --qr --operator=<box user>` in the foreground
  so the URL and QR code reach the terminal, and report the tailnet name on
  success; verify the QR renders, that a second run on a joined box changes
  nothing, and that the non-root path works as `dev`.
- [x] 4.4 Confirm `TS_AUTHKEY` never reaches `/etc/agentbox/config.env` or the
  persisted state; verify by joining with a key and then grepping both for it.
- [x] 4.5 Implement `status` with the four outcomes the spec requires — not
  configured, configured but not running, running but not authenticated, and
  joined with its tailnet address; verify all four by driving the variable and
  the daemon, and diffing the outputs.
- [x] 4.6 Implement `stop` idempotently and `ensure` as the boot path (`off`
  returns quietly, `auto` warns on failure, `on` is fatal); verify each by
  booting with the variable set and reading the boot log.
- [ ] 4.7 Verify the operator delegation works: on a joined box, `tailscale
  status` and `tailscale serve` both succeed as the box user with no `sudo`.

## 5. `agentbox-collie`, `agentbox-herdr` and the boot sequence

- [x] 5.1 Create `image/etc/collie.sh` with the house header comment and the
  verb dispatch for `ensure`, `start`, `stop`, `status`; verify each verb runs
  and exits zero in a booted container with `AGENTBOX_COLLIE` unset.
- [x] 5.2 Implement the environment contract from `design.md — The environment
  the box supplies`: the box sets only `COLLIE_MUX` and `COLLIE_PORT`, and
  passes `COLLIE_TRUSTED_USER` and `COLLIE_PUBLIC_URL` through untouched; verify
  by reading the running bridge's own environment and confirming that
  `COLLIE_HOST`, `COLLIE_ALLOW_NON_LOOPBACK_BIND`, `COLLIE_SKIP_SERVE`,
  `COLLIE_PUBLIC_HOSTS`, `COLLIE_ALLOWED_ORIGINS` and `COLLIE_ALLOW_ANY_HOST`
  are all absent.
- [x] 5.3 Implement `start`: preflight both a running herdr server and tailnet
  membership, naming which one is missing, then delegate to `collie start`;
  verify a start with no herdr server and a start with no tailnet each exit
  non-zero naming the right missing piece.
- [x] 5.4 Implement `stop` by delegating to `collie stop`; verify `stop` twice in
  a row exits zero both times and `status` reports not running after each.
- [x] 5.5 Implement `status` with the four outcomes the spec requires, the first
  naming `AGENTBOX_COLLIE` and the joined one naming the tailnet URL a phone
  would open; verify all four by driving the variables and the process.
- [x] 5.6 Implement `ensure` as the boot path: quiet on `off`, warn on `auto`,
  fatal on `on`; verify each by booting and reading the boot log.
- [x] 5.13 Generate the push keypair before starting Collie, gated on
  `AGENTBOX_COLLIE_PUSH` (default on) and passing `COLLIE_PUSH_SUBJECT` when
  set, never `--force`; verify the keys land in the home volume, that a second
  start leaves them byte-identical, and that no address the box holds for
  another purpose is used as the contact.
- [x] 5.7 Create `image/etc/herdr-server.sh` with `start`, `stop` and `status`,
  running the server as the box user and never as root; verify with `ps -o
  user=` that the running server is owned by `dev`.
- [x] 5.8 Add the herdr server to `image/entrypoint.sh` ahead of the existing
  step 9, gated on `AGENTBOX_HERDR_SERVER`, with a failure logged as a warning
  that does not abort the boot; verify a box boots and accepts SSH with the
  server deliberately sabotaged.
- [x] 5.9 Add `herdr plugin link /opt/collie/current` to step 9 beside the
  existing integrations loop, gated on the server actually being up and
  non-fatal on failure; verify the plugin's actions are listed after a clean
  boot with no manual steps, and that a second boot does not double-register.
- [x] 5.10 Add `agentbox-tailscaled ensure` and then `agentbox-collie ensure` to
  the background chain in step 10, in that order; verify with both set to `auto`
  that sshd accepts connections before either finishes, and that Collie starts
  only after the tailnet is up.
- [x] 5.11 Publish `AGENTBOX_COLLIE`, `AGENTBOX_TAILSCALE`,
  `AGENTBOX_HERDR_SERVER`, `COLLIE_PORT`, `COLLIE_TRUSTED_USER` and
  `COLLIE_PUBLIC_URL` to `/etc/agentbox/config.env` — and `TS_AUTHKEY`
  deliberately not; verify by reading them back in a shell opened over SSH, not
  with `docker exec`.
- [ ] 5.12 Confirm the shutdown path does not kill herdr sessions ahead of the
  existing persistence save; verify by stopping a box gracefully with a pane
  running and checking the save completes in the log.

## 6. Compose, environment and defaults

- [x] 6.1 Undo the earlier design's networking changes: remove the Collie port
  publish from both compose files, and remove `COLLIE_HOST`,
  `COLLIE_ALLOW_NON_LOOPBACK_BIND`, `COLLIE_SKIP_SERVE`, `COLLIE_PUBLIC_HOSTS`
  and `COLLIE_ALLOWED_ORIGINS` wherever they were added; verify no file in the
  repository mentions any of them except as something deliberately not set.
- [x] 6.2 Add `AGENTBOX_COLLIE` (default `off`), `AGENTBOX_TAILSCALE` (default
  `off`), `AGENTBOX_HERDR_SERVER` (default `1`), `TS_AUTHKEY`, `TS_HOSTNAME`,
  `COLLIE_PORT`, `COLLIE_TRUSTED_USER` and `COLLIE_PUBLIC_URL` to the
  `environment:` block of both compose files; verify `docker compose config`
  renders them all with no `.env` present.
- [x] 6.3 Confirm the shipped compose files publish nothing but the SSH port,
  and add a comment saying that reaching Collie deliberately needs no publish;
  verify by bringing a box up unedited and listing its published ports.
- [x] 6.4 Rewrite the Collie section of `.env.example` for the tailnet design —
  the two enable switches, the auth key, the trusted user, and a pointer to
  `docs/collie.md` before enabling; verify `make init` still produces a `.env`
  that boots.
- [x] 6.5 Add `COLLIE_VERSION` and `INSTALL_TAILSCALE` to the pinning block in
  `.env.example` and to the `build.args` of `docker-compose.yml`; verify
  `docker compose build` honours both.

## 7. End to end

- [ ] 7.1 On a box with `AGENTBOX_TAILSCALE=auto` and a valid `TS_AUTHKEY` and
  `AGENTBOX_COLLIE=auto`, verify from a phone on the same tailnet that the
  dashboard opens over TLS on the box's tailnet name with no port published
  anywhere.
- [ ] 7.2 With `COLLIE_TRUSTED_USER` set, verify the interface is reachable for
  that identity and refused for another login on the same tailnet.
- [ ] 7.3 Pair a phone with `collie pair`, then recreate the container from the
  same image; verify the phone is still paired, its history is readable, and the
  box came back as the same tailnet node without re-authenticating.
- [ ] 7.4 Verify nothing is reachable off the tailnet: from the host, confirm the
  container's own address answers on no Collie port.

## 8. Documentation

- [x] 8.1 Write `docs/tailscale.md`: what the box joins and why, userspace
  networking and the privileges it does not need, auth keys versus an
  interactive login, where the node state lives and why that matters at recreate
  time, the operator delegation, and that `funnel` is never to be used; verify
  every command in it runs as written on a booted box.
- [x] 8.2 Rewrite `docs/collie.md` for the tailnet design — no published port,
  no proxy, Collie on its own defaults — keeping the security framing, pairing,
  updating and troubleshooting sections; verify every command in it runs as
  written.
- [x] 8.3 Update the Collie section of `docs/security.md` to describe the tailnet
  as the boundary and drop the removed variables, keeping the three claims about
  reads being open, writes being gated, and the gate not existing until pairing;
  verify each claim against Collie's own security documentation.
- [x] 8.4 Add a note to `docs/persistence.md` that the tailnet node state lives
  in the state volume, and what deleting that volume costs; verify it matches
  what `agentbox-tailscaled` actually does.
- [x] 8.5 Add the two-front-doors section to `docs/mobile.md` and the
  herdr-at-boot note to `docs/agents.md`; verify they do not contradict each
  other.
- [x] 8.6 Update the Collie entries in `README.md` and `README.en.md` for the
  tailnet design, keeping the two files in step; verify by diffing their
  structure.

## 9. Tests

- [x] 9.1 Update `tests/collie.sh` for the tailnet design: drop the
  reachability-from-the-container's-address and foreign-`Host` checks, and add
  one asserting Collie is bound to loopback only and that nothing answers on the
  container's own address; verify the suite passes against a locally built image.
- [x] 9.2 Assert that `herdr plugin list` shows the Collie plugin linked, which
  is herdr enforcing the `min_herdr_version` in Collie's own manifest; verify
  against a box built from the Dockerfile.
- [x] 9.3 Assert the herdr server is running after boot with the default
  configuration, and not running with `AGENTBOX_HERDR_SERVER=0`; verify both
  branches.
- [x] 9.4 Add assertions that `COLLIE_ALLOW_ANY_HOST` and the four other undone
  variables appear in no shipped configuration and in no running process; verify
  by reading the bridge's environment as the user that owns it.
- [x] 9.5 Add tailnet assertions that do not need a real tailnet: the client and
  daemon are installed, `agentbox-tailscaled status` gives the right one of its
  four outcomes for each `AGENTBOX_TAILSCALE` state, and a box with
  `AGENTBOX_COLLIE=auto` but no tailnet refuses to report Collie as ready and
  says why; verify all three.
- [x] 9.6 Add a Collie smoke step to `.github/workflows/docker-image.yml`
  alongside the existing Docker daemon smoke test; verify the workflow passes on
  a branch push.
