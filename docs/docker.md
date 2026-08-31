# Docker inside the box

The box is its own Docker host. `docker run` works from your first login, with
no socket to mount and nothing to configure:

```
$ agentbox-dockerd status
own daemon: running (pid 143, log /var/lib/agentbox/log/dockerd.log)
  client 29.7.2  server 29.7.2
```

Two things pay for that, and both are worth knowing about: a `privileged`
container, and a 192 MB engine that is *not* in the image.

## Where the engine lives

The daemon is `docker-ce` plus `containerd.io` — 192 MB installed. Baking that
into the image would charge it to everyone who pulls agentbox, including the
boxes that never run a container.

So the box installs it on the first boot instead, and from there the same
machinery that remembers your `apt install`s remembers this one:

```
$ agentbox-persist status
packages:     2
  - containerd.io
  - docker-ce
```

Every later boot replays it from the state volume's own `.deb` cache, offline
and in seconds. Only the very first boot of a box ever downloads anything, and
`docker compose down && up` does not count as first — the volumes are what
"first" is measured against. See [persistence.md](persistence.md).

The install runs in the background, after the package replay and before your
provision script, so a first boot still gives you a login immediately. Docker
shows up a couple of minutes later; `agentbox-dockerd status` says where it is.

**Want it in the image anyway** — for a box that must run containers the second
it boots, or one with no network:

```bash
# .env
INSTALL_DOCKER_ENGINE=true
```

`AGENTBOX_DOCKER` decides what the box does at boot: `install` (default: fetch
it when missing, then run it), `auto` (run it only if something already
installed it), `on` (a box without a working daemon refuses to boot — and it
waits for the install *before* sshd, so a first boot takes minutes longer
instead of handing you a box that may or may not get a daemon), `off`.

## Why privileged, and why there is no lighter version

A daemon does not just need to *start* — it needs to unshare namespaces, mount
filesystems and write cgroups for every container it runs. An ordinary
container may do none of those: Docker's default seccomp profile refuses
`unshare` outright unless the container has `CAP_SYS_ADMIN`, and the default
capability set does not include it.

Without that, `dockerd` still comes up if you push it hard enough with
`--iptables=false --bridge=none --storage-driver=vfs`. It answers `docker
version`. It cannot unpack an image:

```
docker: failed to register layer: unshare: operation not permitted
```

That half-working daemon is why the boot checks `CAP_SYS_ADMIN` *before*
downloading anything — an engine that could never run is a bad way to spend
192 MB of someone's first boot — and refuses out loud instead of leaving a
dockerd crash-looping into a log nobody reads. Rootless mode does not rescue
this either: it needs user namespaces, which is the very thing being denied.

So: privileged, or no daemon. And privileged means the container can take over
the machine under it. That is the trade the default makes;
[security.md](security.md) is the rest of the argument.

The other required line is the volume:

```yaml
      - agentbox-docker:/var/lib/docker
```

Without it Docker's data directory lands on the container's own overlayfs,
where overlay cannot stack. Docker 29 defaults to the containerd snapshotter,
which does not work around that on its own — it pulls an image happily and then
fails every `docker run` with `failed to mount ... err: invalid argument`. The
boot notices the filesystem first and asks for the old graphdriver with `vfs`
instead, which works and copies every image layer in full: gigabytes and
minutes for what should be seconds, and gone on the next recreate anyway. Mount
the volume.

## Turning it off

Two levels, depending on how far you want to go.

**No daemon, nothing downloaded** — one environment variable, no rebuild:

```yaml
    AGENTBOX_DOCKER: "off"
```

**No privileges either** — delete the `privileged: true` line and recreate. The
container goes back to being a sandbox, which is what the rest of
[security.md](security.md) assumes.

## Borrowing a daemon instead

**The host's**, by mounting its socket:

```yaml
      - /var/run/docker.sock:/var/run/docker.sock
```

The daemon inside notices the socket at boot and steps aside, so the two never
fight over the path. Your containers become siblings of the box, sharing the
host's images and networks, and the entrypoint puts `dev` in the group that
owns the socket.

Note this is *also* root-equivalent access to the host — not the safer option,
just a different road to the same place. And containers started this way run
next to the box, not in it: a `-v $PWD:/app` points at a path that exists in
the box and not on the host, which is exactly the shape `docker compose up` in
one of your repositories takes.

**Another machine's**, over SSH — no socket, no privileges, no download:

```bash
docker context create dev-host --docker host=ssh://you@another-machine
docker context use dev-host
```

The blast radius moves to that machine. When it is a throwaway VM, this is the
safest of the three by a wide margin, with the same bind-mount caveat.

## Troubleshooting

**`docker` says nothing is running, right after a boot** — on a recreated box
the engine comes back with the package replay, which runs in the background.
`agentbox-dockerd status` and `/var/lib/agentbox/log/replay.log` say how far
along it is.

**The boot log says `no CAP_SYS_ADMIN`** — the host did not grant privileges.
Check that it survived into the running container
(`docker inspect -f '{{.HostConfig.Privileged}}' agentbox`) and recreate;
`restart` is not enough, capabilities are fixed when a container is created.
Some managed platforms strip it — Kubernetes-based ones usually do, plain
`docker compose` ones (Coolify, Dokploy) usually do not.

**The install fails on the first boot** — the box has no route to
`download.docker.com`, or the apt repository is missing because the image was
built with `INSTALL_DOCKER_CLI=false`. The tail of
`/var/lib/agentbox/log/dockerd.log` has the apt output.

**`permission denied while trying to connect to the Docker API`** — normally
handled: the image puts `dev` in the `docker` group at build time. It comes
back if you bind-mount a *host* socket that appeared after boot, so `dev` never
joined its group — recreate the container, or `sudo usermod -aG docker dev` and
log in again.

**The boot warns about `vfs`, and pulls are slow** — the `agentbox-docker`
volume is not mounted, so Docker is running on the fallback driver. See above.
