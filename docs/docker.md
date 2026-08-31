# Docker inside the box

The box is its own Docker host. `docker run` works the moment you log in, with
no socket to mount and nothing to configure:

```
$ agentbox-dockerd status
own daemon: running (pid 143, log /var/lib/agentbox/log/dockerd.log)
  client 29.7.2  server 29.7.2
```

That is the default, and it is not free: it costs ~400 MB of image and a
`privileged: true` container. This page is about what that means, and what to
do when you do not want it.

## What makes it work

Three lines in `docker-compose.yml`, and they only make sense together:

```yaml
    privileged: true
    volumes:
      - agentbox-docker:/var/lib/docker
```

plus `INSTALL_DOCKER_ENGINE=true` at build time, which puts `docker-ce` and
`containerd.io` in the image.

`agentbox-dockerd` starts the daemon during boot, before sshd, and stops it on
the way out — the container's `stop_grace_period` is 90s so your containers get
a chance to flush before the box saves its own system layer. `AGENTBOX_DOCKER`
picks the policy: `auto` (default: start it when the host allows it), `on` (a
box without a daemon refuses to boot — for deploys where a silent degradation
is worse than a failure), `off`.

The `agentbox-docker` volume is what keeps images and containers across a
recreate. It is also the one volume of the three you can delete without losing
work: everything in it is rebuildable.

### Why privileged, and why there is no lighter version

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

That half-working daemon is why the boot checks `CAP_SYS_ADMIN` first and
refuses loudly instead of starting one. Rootless mode does not rescue this
either — it needs user namespaces, which is the very thing being denied.

So: privileged, or no daemon. And privileged means the container can take over
the machine under it. That is the trade the default makes; [security.md](
security.md) is the rest of the argument.

## Turning it off

Two levels, depending on how far you want to go.

**Keep the engine, do not start it** — one environment variable, no rebuild:

```yaml
    AGENTBOX_DOCKER: "off"
```

**Take the privileges away too** — the box can no longer touch the host:

```bash
# .env
INSTALL_DOCKER_ENGINE=false
```

and delete the `privileged: true` line, then `make build && make up`. You get
the client without a daemon, which is the right shape for the next two options.

## Borrowing a daemon instead

**The host's**, by mounting its socket:

```yaml
      - /var/run/docker.sock:/var/run/docker.sock
```

The daemon inside notices the socket at boot and steps aside, so the two never
fight over the path. Your containers become siblings of the box, sharing the
host's images and networks. The entrypoint finds the group that owns the socket
and puts `dev` in it, so `docker ps` works without `sudo`.

Note this is *also* root-equivalent access to the host — it is not the safer
option, just a different road to the same place.

**Another machine's**, over SSH — no socket, no privileges, no rebuild:

```bash
docker context create dev-host --docker host=ssh://you@another-machine
docker context use dev-host
```

The blast radius moves to that machine. When it is a throwaway VM, this is the
safest of the three by a wide margin.

## Troubleshooting

**The boot log says `no CAP_SYS_ADMIN`** — the host did not grant privileges.
Check that `privileged: true` survived into the running container
(`docker inspect -f '{{.HostConfig.Privileged}}' agentbox`) and recreate;
`restart` is not enough, capabilities are fixed when a container is created.
Some managed platforms strip it — Kubernetes-based ones usually do, plain
`docker compose` ones (Coolify, Dokploy) usually do not.

**`Cannot connect to the Docker daemon`** — `agentbox-dockerd status` says
which of the three shapes you are in, if any.

**`permission denied while trying to connect to the Docker API`** — the socket
appeared after boot, so `dev` never joined its group. Recreate the container,
or `sudo usermod -aG docker dev` and log in again.

**Docker is using the `vfs` storage driver** — `/var/lib/docker` is on the
container filesystem, so overlay2 refused to stack there. Every layer gets
copied in full: gigabytes and minutes for what should be seconds. Mount the
`agentbox-docker` volume. The boot warns about this.

**The daemon did not come up in 60s** — the tail of
`/var/lib/agentbox/log/dockerd.log` is printed in the boot log; the whole file
lives in the state volume.
