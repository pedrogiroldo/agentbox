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

## The Docker socket

`docker-compose.yml` has a commented line that bind-mounts
`/var/run/docker.sock`. It is convenient — the box can run databases,
`docker compose` for your project, anything.

It is also **root-equivalent access to the host**. Anyone (or any agent) inside
the container can start a privileged container that mounts `/` from the host.
There is no partial version of this: mounting the socket means the box is as
trusted as the host. Mount it only on a machine where that is already true.

## Agents and blast radius

Coding agents run commands. That is the point of them. Inside agentbox they can
do anything the `dev` user can do, which is everything in the container.

- The container **is** the sandbox. Keep it that way: no socket mount, no
  `privileged`, no bind mount of host paths you care about.
- Agent credentials sit in the volume in plaintext (they are session tokens or
  API keys). Anyone with the volume, or a backup of it, has your accounts.
  Treat `make backup` output like a password file.
- The agents can push to any repository your keys reach. Consider a dedicated
  SSH key or a scoped GitHub token for the box instead of copying your main
  key in.

## What agentbox does not do

No fail2ban, no automatic security updates, no secret manager, no audit log.
Those belong to the host, and every host does them differently. If the box is
on the public internet, `fail2ban` on the host watching the container's SSH
logs is a reasonable next step.
