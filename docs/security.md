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

## Collie, the tailnet, and what a browser front door costs

The box ships [Collie](collie.md), a mobile web UI for the herd, and **does not
run it**. `AGENTBOX_COLLIE` defaults to `off`, and so does `AGENTBOX_TAILSCALE`,
which it depends on. Those defaults are part of the feature, not timidity.

**A running Collie is shell access to this box.** A single API call sends
arbitrary keystrokes into a live pane. There is no sandbox and no command
allow-list, because either one would defeat what it is for. Since this container
runs `privileged: true`, that is the same blast radius as the SSH port, reached
by whoever can open a URL.

**Its device gates protect writes only.** Pairing a phone answers "may this
device drive an agent?". It does not gate reading. Anything that reaches the URL
and passes the same-origin check can read every pane: source, agent output, the
values in your environment.

**The write gate does not exist until you pair.** Collie leaves writes open
until at least one device holds a credential, deliberately, so that you cannot
lock yourself out. A Collie you turned on and did not pair accepts writes from
any reader. Pairing your phone is the last step of turning it on, not an extra.

So the network in front of it is the boundary — and here that network is a
tailnet the box joins itself, with nothing published. Two things follow, and
both are better than the alternatives:

- **Nothing is exposed.** Collie binds loopback and `tailscale serve` reaches it
  inside the same container. No port is added to `ports:`, no proxy is involved,
  and the box's own `COLLIE_ALLOW_ANY_HOST` is never set — host validation stays
  on.
- **Identity is checked, not assumed.** `tailscale serve` injects the caller's
  tailnet login and `COLLIE_TRUSTED_USER` refuses anyone else. Set it: without
  it, everyone on your tailnet can read every pane.

`tailscale funnel` publishes to the public internet. Nothing here uses it, and
nothing should.

**Joining a tailnet is itself a decision.** The box talks to Tailscale's control
plane and becomes reachable by every node on your tailnet, subject to your ACLs.
It runs in userspace networking, so it needs no TUN device and no `NET_ADMIN` —
this adds no privilege to the container — but it does add a network the box is a
member of. The normal way to join is `agentbox-tailscaled login`, which leaves no
credential anywhere; `TS_AUTHKEY` exists for unattended deploys and is a
credential in a file, so treat it as one. [docs/tailscale.md](tailscale.md)
covers both, where the node identity is stored, and why that matters at recreate
time.

## What agentbox does not do

No fail2ban, no automatic security updates, no secret manager, no audit log.
Those belong to the host, and every host does them differently. If the box is
on the public internet, `fail2ban` on the host watching the container's SSH
logs is a reasonable next step.
