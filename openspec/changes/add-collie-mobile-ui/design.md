## Context

See `proposal.md — Why` for motivation.

This design replaces an earlier one that was built on a wrong premise, and the
correction is worth recording because it is the whole shape of the change.

**What the first design assumed.** Collie binds loopback and expects
`tailscale serve` on the same machine; a container's loopback is its own and its
ingress lives on the host; therefore Collie had to be reshaped — bound to
`0.0.0.0`, told to skip serve, handed a public hostname and an allowed origin —
and reached through a published port with `tailscale serve` on the *host*.

**What is actually true.** `tailscaled --tun=userspace-networking` needs no TUN
device and no `NET_ADMIN`, and `tailscale serve` terminates inside the process
that runs it. Both run inside this container today. So Collie's default
deployment works here verbatim: loopback bind, serve managed by Collie, TLS and
`Tailscale-User-Login` handled on the tailnet, nothing published.

That deletes five environment variables, a published port, a compose edit in two
files, and the paragraph that existed to justify `COLLIE_ALLOW_NON_LOOPBACK_BIND`.
The remaining design is smaller and strictly safer, which is the tell that the
premise was the problem rather than the plan built on it.

What the box already provides, and what this leans on:

```
  image                                 volumes
  +-------------------------------+     +---------------------+
  | herdr        (herdr.dev)      |     | home  /home/dev     |
  | bun, node, nvim               |     |   agent creds, repos|
  | claude / codex / opencode     |     |   collie's own state|
  |                               |     +---------------------+
  | + collie      /opt/collie  <--+-----+ state /var/lib/     |
  | + tailscale   (apt)           |     |   agentbox          |
  +-------------------------------+     |   apt + /opt /etc   |
                                        |   + tailscale node  |
                                        +---------------------+
```

And the runtime shape, which has no arrow crossing the container boundary except
the tailnet itself:

```
   phone, on the tailnet
        |  https://box.your-tailnet.ts.net
        v
   +--------------------------------------------+
   |  agentbox container                        |
   |                                            |
   |   tailscaled --tun=userspace-networking    |
   |      tailscale serve: TLS + identity       |
   |         |  http 127.0.0.1:8787             |
   |         v                                  |
   |   collie  (loopback only)                  |
   |         |  herdr control socket            |
   |   herdr server                             |
   |         |                                  |
   |   claude / codex / opencode                |
   +--------------------------------------------+

   ports:  2222 -> 22.  That is the whole list.
```

## Goals / Non-Goals

**Goals:**

- Collie and Tailscale both present on a box that has never had network access
  after build.
- Two variables (`AGENTBOX_COLLIE`, `AGENTBOX_TAILSCALE`) decide what runs,
  using the vocabulary `AGENTBOX_DOCKER` already taught the operator.
- Collie configured as its authors intended, with the box supplying only the
  facts it alone knows.
- A tailnet identity that survives a recreate, and a first boot that can join
  with nobody watching.
- herdr running before anything tries to talk to it.
- Every failure path ends with SSH still working.

**Non-Goals:**

- No published port for Collie, in any documented configuration.
- No reverse proxy, and no support for Collie's other four deployment variants.
  They work; `docs/collie.md` points at Collie's documentation for them and the
  box tests one path.
- No `tailscale funnel`, ever, and no documentation that mentions it except to
  forbid it.
- No exit node, no subnet routing, no MagicDNS-for-the-container games. The box
  joins a tailnet to be *reachable*, not to route.
- No packs, no multi-instance, no voice input.
- Not making Collie the recommended way to use the box.

## Decisions

### Tailscale in userspace networking, in the container

`--tun=userspace-networking` is the decision the whole design rests on. It means
tailscaled does its own TCP/IP in userspace instead of asking the kernel for a
TUN interface, so the box needs neither `/dev/net/tun` nor `NET_ADMIN` — and
`tailscale serve`, which terminates connections inside tailscaled, works
regardless.

The box happens to run privileged today for its Docker daemon, so it *could*
have a TUN device. Depending on that would tie this feature to a privilege it
does not need, and would break the box for anyone who followed
`docs/security.md` and dropped `privileged: true`. Userspace mode costs some
throughput on bulk transfers, which is irrelevant for a web UI and a terminal.

*Alternative considered — `tailscale serve` on the host.* The first design.
Works, and it needs the operator to run and maintain Tailscale on the host, plus
a published port, plus four Collie variables to bridge the two. Strictly more
moving parts for strictly less isolation.

### From apt, not from the static tarball

Tailscale's apt repository means `agentbox-persist` replays the package after a
recreate like every other package, and `apt` upgrades it with the rest of the
box. The static binaries would have to be re-fetched or version-pinned by hand.

### Node state moves into the state volume

`tailscaled` defaults to `/var/lib/tailscale/tailscaled.state`. `/var/lib` is
not in `AGENTBOX_PERSIST_PATHS` (`/usr/local /opt /etc /root /srv`) and is not a
volume, so a recreate loses the node identity: the box comes back needing to be
authenticated again, under a new name, with the old node left dangling in the
admin console.

So the daemon is started with `--state=/var/lib/agentbox/tailscale/tailscaled.state`.
The state volume already exists and is already the box's answer to "durable, but
not the user's home".

This is a genuine bug in the setup that exists on the operator's box today, not
a hypothetical.

### `--operator=dev`, so Collie can drive its own front door

Collie manages `tailscale serve` itself, as the user it runs as. Without an
operator set, that needs root. `tailscale up --operator=dev` delegates it once,
and it is recorded in the node state, so it survives with everything else.

This is also what makes `tailscale status` work in a plain shell, which is worth
having on its own.

### Auth keys for the headless first boot, with a visible fallback

A box first booted by Dokploy has nobody watching a login URL. `TS_AUTHKEY` in
the environment covers that: `tailscale up --authkey` joins without interaction.

When there is no key and the box is not already a member, `tailscale up` prints
a login URL. The box captures the daemon's output to a log under the state
volume and says where it is, rather than failing with nothing to act on. The
operator can also just run `tailscale up` from a shell.

The key is never written to `/etc/agentbox/config.env` — that file is read by
every interactive shell and is captured by the persistence layer. It is passed
to the one `tailscale up` call and nowhere else.

### Both services default to `off`

Two reasons, and they are different.

`AGENTBOX_COLLIE=off` because a running Collie is shell access with open reads
in a privileged container.

`AGENTBOX_TAILSCALE=off` for a plainer reason: joining a tailnet is joining
*someone's* tailnet, and a box that phoned home to a control plane because it
was the default would be doing something the operator did not ask for.

### `agentbox-collie` delegates to `collie`, and preflights the front door

Collie's herdr plugin gives herdr its own start/stop buttons, which call Collie's
control script. If the box launched the bridge itself there would be two managers
with two ideas of what is running. So `agentbox-collie start` runs `collie start`
with the environment assembled, and `stop` runs `collie stop` (idempotent —
verified: exit 0 twice).

Its preflight checks two things, and names which one failed: a herdr server to
mirror, and tailnet membership to be reached through. The second is the one the
first design did not need, and it is the one that stops an operator from ending
up with a service listening on a loopback nothing can reach.

### The environment the box supplies

Only what the box alone knows:

| variable | value | why |
| --- | --- | --- |
| `COLLIE_MUX` | `herdr` | the box has exactly one multiplexer |
| `COLLIE_PORT` | `8787` unless set | Collie's own default, no conflict here |

Everything else is the operator's, passed through untouched:
`COLLIE_TRUSTED_USER` and `COLLIE_PUBLIC_URL`. Nothing else is needed, because
Collie discovers its own tailnet name.

`COLLIE_HOST`, `COLLIE_ALLOW_NON_LOOPBACK_BIND`, `COLLIE_SKIP_SERVE`,
`COLLIE_PUBLIC_HOSTS` and `COLLIE_ALLOWED_ORIGINS` are all deliberately **not**
set: each one existed only to undo a default that turns out to be right here.
`COLLIE_ALLOW_ANY_HOST` is not set either, and never will be.

### Register with herdr as a plugin, after starting the herdr server

Collie's documentation describes `herdr plugin link <tree>` as the correct wiring
for a packaged install, since herdr does not scan `/opt`. It also makes herdr's
`update` action correctly refuse and defer to the packager, which here is
`make update`.

The ordering matters: `herdr plugin link` talks to the herdr server over its
control socket, and today's entrypoint has no server at boot. So the server has
to start before the link — which is the strongest technical argument for the
herdr-server-at-boot decision, independent of Collie needing a multiplexer.

### herdr becomes a boot service, unconditionally

Tying it to `AGENTBOX_COLLIE` would make the box's behaviour depend on which
front door is enabled, and would leave the plugin link with no server on a
default box. Starting it always is simpler to explain: the box hosts sessions
the way it hosts sshd. The user-visible surface is unchanged — `herdr` from a
shell attaches to the running server — and `AGENTBOX_HERDR_SERVER=0` restores
today's behaviour exactly.

### What the spike found (task group 1, Collie 1.6.0 / herdr 0.8.2)

Verified by hand before any of the above was built on it:

- **The link target is `/opt/collie/current`, not `/opt/collie`.** The manifest
  is `herdr-plugin.toml` inside the release tree; linking the parent fails with
  `plugin_manifest_not_found`.
- **herdr resolves the symlink** when it records the plugin
  (`plugin_root: /opt/collie/versions/1.6.0`), so an in-place `collie update`
  leaves it pointing at the previous version. Re-linking on every boot fixes it
  and is idempotent.
- **The herdr floor is enforced by Collie's own manifest**
  (`min_herdr_version = "0.7.0"`), checked by herdr at link time. The box does
  not reimplement it; it just must not swallow the error.
- **Collie's config home moves when linked as a plugin**, to
  `~/.config/herdr/plugins/config/herdr.collie/`. Still in the home volume, so
  persistence is unaffected, but the docs must name the right path.
- The release tarball unpacks `versions/` mode `0777` with files owned by uid
  1001; the Dockerfile normalises ownership and modes.
- The compiled binary is ~84 MB; the built image grew from 885 MB to 922 MB.
- **`herdr status server` and `collie status` both exit 0 either way**, so
  liveness has to be read from their text. Both are checked that way.

Two more that cost real time, and are the reason the supervisors look the way
they do:

- **`setsid cmd &` is not a way to daemonise.** Plain `setsid` *execs* when the
  caller is not already a process-group leader and *forks* when it is, so
  whether the server outlives the script that started it depends on how that
  script was invoked. It survived by hand and died at boot. `setsid --fork`
  always forks, the parent returns, and tini adopts the orphan.
- **The redirect has to happen on the root side of `runuser`.**
  `/var/lib/agentbox` is a root-owned volume, so
  `runuser -u dev -- bash -c 'exec herdr server >>$LOG'` cannot open the log at
  all — the daemon dies instantly with `Permission denied`. Writing it as
  `runuser -u dev -- setsid --fork herdr server >>"$LOG" 2>&1` lets root open
  the file and the child simply inherit the descriptor. This only reproduces
  with the state volume mounted, which is why an ad-hoc container looked fine.

## Risks / Trade-offs

- **Userspace networking is slower than a TUN device on bulk transfers** →
  irrelevant for a web UI and a terminal, and the alternative is a privilege the
  feature does not need.
- **The box now talks to a third-party control plane when enabled** → off by
  default, and it is the same trade the operator already made by putting the
  host on a tailnet, moved one layer in. `docs/security.md` states it.
- **An auth key in `.env` is a credential on disk** → the box never copies it
  into its own config or persisted state, and Tailscale keys are expiring and
  revocable. Documented as the reason to prefer an ephemeral key.
- **Read access is open to the whole tailnet** → mitigated, not solved:
  `COLLIE_TRUSTED_USER` narrows it to one login, and pairing gates writes.
  Anyone on the tailnet who reaches the URL and passes that check reads panes.
  Documented as a property of the tool.
- **Starting the herdr server at boot changes a default** → escape hatch ships in
  the same change, interactive `herdr` behaves identically, and a failed server
  cannot block sshd.
- **Collie tracks herdr's API and herdr is installed as "latest"** →
  `tests/collie.sh` asserts the plugin links, which is herdr enforcing Collie's
  floor, so a mismatch fails in CI rather than on a phone.
- **Two mobile front doors invite "which one do I use?"** → `docs/mobile.md`
  answers it in one paragraph up front.

## Migration Plan

Nothing to migrate. A box that pulls the new image and changes no configuration
gets two idle binaries, a herdr server at boot, and identical SSH behaviour.

Enabling is: set `AGENTBOX_TAILSCALE=auto` and `TS_AUTHKEY`, set
`AGENTBOX_COLLIE=auto` and `COLLIE_TRUSTED_USER`, restart, then `collie pair`
and enter the code on the phone. No compose edit, no port, no proxy.

Rolling back is unsetting the two variables and restarting.
`AGENTBOX_HERDR_SERVER=0` reverts the one changed default independently.

An operator who already set this up by hand — tailscaled started with
`sudo nohup`, state in `/var/lib/tailscale`, Collie in `~/.local/share/collie` —
keeps working. `docs/tailscale.md` describes moving the node state into the
state volume so the next recreate does not cost them their node.

## Open Questions

- **Whether `docs/collie.md` should also document the public-domain ingress**
  (a reverse proxy, no tailnet) as a secondary path, or only link to Collie's
  deployment documentation for it. Either way the recommended path is unchanged.
