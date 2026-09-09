# The tailnet — the box's own front door

The box can join a [Tailscale](https://tailscale.com) network as a node of its
own, from inside the container. That gives it a name, a TLS certificate and an
address that only your devices can reach — without publishing a port, without a
reverse proxy, and without anything on the host.

It is off by default. Joining a tailnet is joining *somebody's* tailnet, and a
box that phoned home to a control plane because that was the default would be
doing something you did not ask for.

## Why you would

- **[Collie](collie.md) has no other way in.** It binds loopback on purpose;
  `tailscale serve` reaching it from inside this same container is the whole
  design.
- **SSH gets better than an open port.** `docs/security.md` already recommends
  putting the box behind a private network. This is that, one layer in: nothing
  on 2222 for the internet to knock on.
- **Your phone is already there.** Install the Tailscale app once and every box
  you run is reachable by name.

## What it costs, and what it does not

It does **not** cost a privilege. The daemon runs with
`--tun=userspace-networking`: instead of asking the kernel for a TUN interface
— which a container may not have and which needs `NET_ADMIN` — it does its own
TCP/IP in userspace. `tailscale serve` terminates connections inside the daemon,
so it works the same either way.

The box does run `privileged: true` today for its Docker daemon, so it *could*
have a TUN device. Depending on that would break the box for anyone who followed
`docs/security.md` and dropped the privilege, so nothing here does.

What it costs is bulk throughput — userspace networking is slower than a kernel
TUN for large transfers. A web UI and a terminal never notice.

## Turning it on

Two steps, and the second one is a command you run — not a credential you
manage.

In `.env`:

```sh
AGENTBOX_TAILSCALE=auto
```

Then, from a shell in the box:

```sh
agentbox-tailscaled login
```

It starts the daemon, prints a login URL **and a QR code**, and waits. Scan the
code with the phone you are about to use — that is the device you are
authorising for, and a URL in a terminal is no use to it. When you finish the
login in the browser, the command reports the box's tailnet name and exits.

It re-runs itself under `sudo` if you did not (`tailscale up` needs root until
the operator is delegated, which is what this same command does), and it says so
when it does. On a box that has already joined it tells you so and changes
nothing.

`AGENTBOX_TAILSCALE` has the same three settings the rest of the box uses:
`off` (default), `auto` (join at boot; a failure is a warning) and `on` (join at
boot; a failure stops the box).

`TS_HOSTNAME` sets the name this box takes; without it Tailscale picks one.

## Joining with nobody watching

The command above needs a person. A deploy platform starting a container at 3am
does not have one, and that — only that — is what `TS_AUTHKEY` is for:

```sh
TS_AUTHKEY=tskey-auth-...       # generated in the admin console
```

With a key set, the box joins during boot with no interaction. Without one, the
boot does not block and does not fail; it logs the `login` command and carries
on, and you finish the join whenever you next log in.

**Use a non-ephemeral key.** Tailscale's *ephemeral* keys mark the node for
automatic removal shortly after it goes offline, which is precisely the opposite
of what the state volume in this box exists to buy you — a box you restart would
be deleted from your tailnet. Ephemeral keys are for CI runners. For an
agentbox, a single-use non-ephemeral key is right (reusable if you deploy
several boxes from one `.env`).

Auth keys expire between 1 and 90 days, defaulting to 90. That expiry applies to
*joining*: a box that already joined keeps working from its own node key, so a
stale key in `.env` only bites on a fresh join.

It is a credential in a file, and the box treats it as one. It is passed to
exactly one `tailscale up` call and is **not** written into
`/etc/agentbox/config.env` (which every interactive shell reads, and which the
persistence layer captures) or into anything the box saves.

## Where the identity lives

```
/var/lib/agentbox/tailscale/
```

Not `/var/lib/tailscale`, which is where the daemon puts it by default. That
matters: `/var/lib` is neither a volume nor one of the paths `agentbox-persist`
watches, so the default location loses the node identity on every recreate — the
box comes back asking to be authenticated again, under a new name, with the old
node left dangling in your admin console.

The whole directory, not just `tailscaled.state`. Beside the state file sit the
TLS certificates `tailscale serve` fetches and the profile data; leaving those
behind would mean re-fetching certificates against Let's Encrypt rate limits on
every recreate. The daemon runs with `--statedir` pointed here, which covers all
of it.

In the state volume, a recreated box is the same node, with the same name and
address, and nothing to re-authenticate. Deleting that volume is what "leave the
tailnet" means.

### Migrating a hand-rolled install

If you set Tailscale up in a box by hand before this existed, your state is in
the old place. Copy it across — **copy, not move**, and do it while the daemon
is still running, so nothing goes down and you keep a fallback:

```sh
sudo mkdir -p /var/lib/agentbox/tailscale
sudo chmod 0700 /var/lib/agentbox/tailscale
sudo cp -a /var/lib/tailscale/. /var/lib/agentbox/tailscale/
```

Then set `AGENTBOX_TAILSCALE=auto` and restart the box. The supervised daemon
picks the copy up and comes back as the same node — no login, same name, same
address. Your hand-started `tailscaled` dies with the old container, which is
the point.

If the copy turns out to be stale, `agentbox-tailscaled login` once puts it
right; you lose nothing but the node's identity, and the old node can be deleted
from the admin console.

## The operator

The box joins with `--operator=dev`, which delegates tailnet operation to the
user you log in as. That is what lets `tailscale status` work in a plain shell,
and what lets Collie publish its own `tailscale serve` mapping without `sudo`.

## Serving something on it

Collie does this for itself. For anything else you run in the box:

```sh
tailscale serve --bg --https 443 http://127.0.0.1:3000
tailscale serve status
```

The service is reachable at `https://<your box>.<your tailnet>.ts.net` from your
devices, and from nowhere else.

> **Never `tailscale funnel`.** Funnel publishes to the public internet. Serve
> stays on your tailnet. Nothing in this box uses funnel, and nothing should:
> the box is a privileged container full of coding agents.

## Commands

| | |
| --- | --- |
| `agentbox-tailscaled login` | join: prints a URL and a QR code, and waits |
| `agentbox-tailscaled status` | what the box joined, or why it did not |
| `agentbox-tailscaled start` / `stop` | drive the daemon by hand |
| `tailscale status` | Tailscale's own view, as `dev`, no sudo |
| `tailscale serve status` | what this box publishes on the tailnet |

## When it does not work

**`status` says the daemon is running but not authenticated.** Nobody completed
a login. Run `agentbox-tailscaled login`.

**`status` says the auth key was refused.** Keys expire and are single-use
unless you made them reusable. Make a new one.

**The box joined but came back as a new node after a recreate.** Its state was
not on the volume — see [Where the identity lives](#where-the-identity-lives).

**`tailscale serve` re-fetches its certificate after every recreate.** The
`certs/` directory was left behind: the daemon needs `--statedir` on the volume,
not just `--state`.

**Something else on the tailnet cannot reach the box.** Check your tailnet ACLs
in the admin console. Userspace networking changes nothing about ACLs.
