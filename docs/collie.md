# Collie — the herd, in a browser

`docs/mobile.md` gets you a terminal on your phone. This gets you an interface
someone designed for a phone: the agent that is waiting on you floats to the
top, its permission prompt becomes buttons you tap, and you answer with the
normal keyboard instead of finding `Esc` in an extra key row.

[Collie](https://github.com/AltanS/collie) is not part of agentbox — it is a
separate project that mirrors a terminal multiplexer, and herdr is the one it
supports best. The box ships it, wires it into herdr, and stays out of the way.

**It does not run until you say so.** Read the next section before you change
that.

## What you are turning on

A running Collie sends arbitrary keystrokes into a live pane. That is the whole
point of it, and it means the URL is shell access to this box — a box that runs
`privileged: true` so it can host your Docker daemon. Three specifics, none of
which are a criticism of Collie; they are how it is designed and it says so
itself:

- **Reads are open.** Anything that reaches the URL and passes the same-origin
  check can read every pane: your source, your agents' output, the values in
  your environment. Neither of Collie's device gates changes this — both of them
  gate *writes*.
- **The write gate does not exist until you pair.** No device is paired on a
  fresh install, and Collie leaves writes open until the first one is, so that
  you cannot lock yourself out. Pairing your phone is a step, not an option.
- **There is no sandbox and no command allow-list.** Adding one would defeat the
  thing it exists to do.

So the network in front of it is the boundary. That is the tailnet, and it is
why Collie needs [docs/tailscale.md](tailscale.md) before it needs anything else.

## How it is reached

Collie binds loopback and manages its own `tailscale serve` mapping. The box
joins a tailnet from inside the container, so all of that happens in one network
namespace and nothing is published anywhere:

```
   your phone (same tailnet)
        |  https://box.your-tailnet.ts.net
        v
   +--------------------------------------------+
   |  agentbox container                        |
   |                                            |
   |   tailscaled --tun=userspace-networking    |
   |      tailscale serve: TLS + your identity  |
   |         |  http 127.0.0.1:8787             |
   |         v                                  |
   |   collie  (loopback only)                  |
   |         |  herdr control socket            |
   |   herdr server                             |
   |         |                                  |
   |   claude / codex / opencode                |
   +--------------------------------------------+

   published ports:  2222 -> 22.  That is the whole list.
```

This is Collie's own default deployment, unmodified. The box sets no
`COLLIE_HOST`, no `COLLIE_ALLOW_NON_LOOPBACK_BIND`, no `COLLIE_SKIP_SERVE`, no
`COLLIE_PUBLIC_HOSTS` and no `COLLIE_ALLOWED_ORIGINS` — every one of those exists
to undo a default that is correct here. It never sets `COLLIE_ALLOW_ANY_HOST`
either.

Collie's documentation describes four other deployments, including a public
domain behind a reverse proxy. They work; the box does not document or test
them, because they end with a read-open remote shell on a name the internet can
resolve.

## Turning it on

### 1. Join a tailnet

[docs/tailscale.md](tailscale.md) has the whole of it. The short version:
`AGENTBOX_TAILSCALE=auto` in `.env`, then from a shell in the box

```sh
agentbox-tailscaled login
```

which prints a URL and a QR code and waits. Scan it with the phone you are
about to use Collie on.

### 2. Turn Collie on

```sh
AGENTBOX_COLLIE=auto
COLLIE_TRUSTED_USER=you@example.com    # your tailnet login
```

`COLLIE_TRUSTED_USER` is checked against the header `tailscale serve` injects,
so nobody else on your tailnet gets in even if they have the URL. Set it.

### 3. Restart and pair your phone

```sh
docker compose up -d
docker compose exec agentbox agentbox-collie status   # prints the URL to open
docker compose exec agentbox collie pair
```

`collie pair` prints an 8-character code and a QR code, good for ten minutes.
Open the URL on the phone, go to **Settings → Paired devices**, and enter it.
From then on every write needs that device's token, and
`collie devices revoke <label>` takes it back with no restart.

Pair the phone you are holding first. Until at least one device is paired, the
write gate is off.

### 4. Say yes to notifications

While you are in Settings, turn notifications on. Being told that an agent is
waiting on you is most of the reason to have this on a phone at all — Collie
sends one when an agent goes **blocked** or **done**, with the agent's own
message in the body, and tapping it opens that agent.

The box has already done the part it can: it generates the push keypair before
starting Collie, so there is nothing to run first. Granting permission is the
browser asking you, and no box can answer that for you.

```sh
collie push-test            # once the phone has said yes
collie push list            # which devices are subscribed
```

Two things worth knowing:

- **The keys are generated once and never replaced.** Replacing them
  unsubscribes every device silently — they keep looking subscribed and receive
  nothing. The box never passes `--force`, and neither should you unless that is
  what you want.
- **They live in the home volume**, so a recreate does not cost you your
  subscriptions.

`AGENTBOX_COLLIE_PUSH=0` skips generating them. `COLLIE_PUSH_SUBJECT` sets the
contact address handed to Mozilla's and Google's push services — it is optional,
and the box deliberately does not fill it in from your git identity or anything
else it happens to know.

## Day to day

Inside the box:

| | |
| --- | --- |
| `agentbox-collie status` | what the box is doing about Collie, and the URL |
| `agentbox-collie start` / `stop` | drive it by hand |
| `collie status` | Collie's own account of itself |
| `collie pair` | a code for a new device |
| `collie devices list` / `revoke <label>` | what holds a credential |
| `collie push-test` / `push list` | notifications: send one, see who is subscribed |

Inside herdr, Collie's own buttons are there too — the box links it as a plugin
on every boot, so `Start Collie`, `Collie status` and the rest show up in the
plugin actions. They drive the same process `agentbox-collie` does.

`AGENTBOX_COLLIE` has three settings: `off` (the default — installed, never
started), `auto` (start it at boot; a failure is a warning) and `on` (start it
at boot; a failure stops the box).

## Updating it

Two paths, and they do different things:

```sh
make update        # rebuild the image with the newest Collie
collie update      # update in place, from inside the box
```

The in-place update lands in `/opt/collie`, which the box's persistence contract
captures, so it survives a recreate and keeps winning until the next image
rebuild. That tree belongs to the box's user for exactly this reason: the
update stages the next release beside the current one as the user the bridge
runs as, and a root-owned `/opt/collie` fails it on the first `mkdir`. One
wrinkle: herdr records the plugin by its resolved path, so after an in-place
update the buttons still point at the previous version until the box restarts
and re-links. The `collie` command itself is correct immediately.

To pin a version at build time, set `COLLIE_VERSION=v1.6.0` in `.env`. That also
skips the GitHub API call the build otherwise makes to find the newest tag.

## When it does not work

**`agentbox-collie status` says the box has not joined a tailnet.** That is the
front door, and Collie refuses to start without one rather than listening on a
loopback nothing can reach. See [docs/tailscale.md](tailscale.md).

**It says there is no herdr server.** Collie mirrors a multiplexer; without one
it has nothing to show. The box starts `herdr server` at boot — check
`AGENTBOX_HERDR_SERVER` is not `0`, and look in
`/var/lib/agentbox/log/herdr-server.log`.

**The page loads but nothing works.** Open the network tab: `/api/*` requests
answering `403` mean a check is refusing you — usually `COLLIE_TRUSTED_USER` not
matching your tailnet login. The app shell itself is served regardless because
it holds no data, so a page that renders is not proof the configuration is right.

**Where the state lives.** Because Collie is linked into herdr, its `.env`,
paired devices and transcripts live under
`~/.config/herdr/plugins/config/herdr.collie/` — inside the home volume, so a
recreate does not touch them.

## Where to read more

Collie carries its own documentation in the box, with no network:

```sh
collie docs      # every page
collie skill     # a brief written for an agent in your terminal
```

`/opt/collie/current/docs/security.md` is the one to read before you widen
anything past what this page describes.
