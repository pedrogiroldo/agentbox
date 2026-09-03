# Security

agentbox puts an SSH server and three coding agents on a machine you own.
That is a real attack surface. None of this is exotic — it is the same care any
internet-facing SSH box needs — but read it once before exposing the port.

## The defaults

- **Key-based login only.** `PasswordAuthentication no`, `PermitRootLogin no`,
  `PermitEmptyPasswords no`.
- **The container refuses to start** if no public key and no password were
  configured — an unreachable box beats an open one.
- **Host keys are persistent**, so a fingerprint change is a real signal rather
  than routine noise you have trained yourself to ignore.
- **Environment-managed keys are separate** (`~/.ssh/authorized_keys.d/agentbox`,
  rewritten every boot) from keys you add by hand (`~/.ssh/authorized_keys`,
  never touched by agentbox).
- The `dev` user has **passwordless sudo inside the container**. That is
  deliberate — it is your VM — and it does not grant anything on the host.

## Things you should do

**Do not use port 22 on the host.** The default mapping is `2222`. It is not
security, but it removes most of the background noise.

**Restrict the source.** If you always connect from known networks, say so in
the firewall:

```sh
ufw allow from 203.0.113.0/24 to any port 2222 proto tcp
```

**Better: do not expose it at all.** Put the host on a
[Tailscale](https://tailscale.com) or WireGuard network and bind the port to
the private interface:

```yaml
ports:
  - "100.x.y.z:2222:22"     # tailscale IP of the host
```

Your phone joins the same network and nothing is reachable from the public
internet. This is the recommended setup if you are not sure.

**Watch the logs.** `docker compose logs` shows every failed authentication —
sshd runs with `-e`, so it logs to stderr.

**Rotate keys by editing `SSH_PUBLIC_KEY` and restarting.** The managed file is
rewritten from the environment on every boot, so removing a key there actually
removes it.

## Docker, and the privileged container

**Read this one.** The box runs its own Docker daemon — installed on the first
boot, not shipped in the image — and a daemon inside a container only runs if
that container is privileged, so `docker-compose.yml` sets `privileged: true`.

That is **root-equivalent access to the host**. A privileged container can
mount the host's disk, load kernel modules and step out of its own isolation;
anyone with a shell in the box, agents included, can do it. Mounting
`/var/run/docker.sock` instead lands in exactly the same place by a different
road. There is no partial version of either: the box is as trusted as the
machine under it, so run it on a machine where that is already true — your own
VPS, not a host shared with anything you would not hand over.

[docker.md](docker.md) has the why (no smaller capability set works, and
rootless mode needs the same namespaces) and, if this is not a trade you want,
the two ways to give it up:

- `INSTALL_DOCKER_ENGINE=false` plus deleting the `privileged: true` line —
  the container goes back to being the sandbox
- `DOCKER_HOST` pointed at a daemon on another machine, ideally a throwaway VM,
  which keeps containers available and the blast radius elsewhere

## Agents and blast radius

Coding agents run commands. That is the point of them. Inside agentbox they can
do anything the `dev` user can do, which is everything in the container.

- The container is only a sandbox while it is unprivileged, and by default it
  is not (see above). If you want it to be one, turn Docker off — and then keep
  it that way: no socket mount, no bind mount of host paths you care about.
- Agent credentials sit in the volume in plaintext (they are session tokens or
  API keys). Anyone with the volume, or a backup of it, has your accounts.
  Treat `make backup` output like a password file.
- The agents can push to any repository your keys reach. Consider a dedicated
  SSH key or a scoped GitHub token for the box instead of copying your main
  key in.
- A mirror ([mirror.md](mirror.md)) copies a project out of the box and onto
  your laptop, live — including whatever an agent checked out into it. The
  laptop is then part of the same blast radius, and a deletion in the box
  propagates to it, so a mirror is not a backup.

## What agentbox does not do

No fail2ban, no automatic security updates, no secret manager, no audit log.
Those belong to the host, and every host does them differently. If the box is
on the public internet, `fail2ban` on the host watching the container's SSH
logs is a reasonable next step.
