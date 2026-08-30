# What survives, and what does not

Two volumes, and a rule that is now two lines long:

> **`/home/dev` is yours.** Everything in it is kept, verbatim.
>
> **What you install on top of the image is remembered and replayed.** The
> image itself is never mounted over, so an update still brings you a newer
> node, nvim, herdr and agents.

Understanding those two lines is the difference between "my container is a pet
I am afraid to touch" and "I rebuild it whenever I want".

| Volume | Mounted at | Holds |
| --- | --- | --- |
| `agentbox-home` | `/home/dev` | your repos, agent credentials, shell history, editor state |
| `agentbox-state` | `/var/lib/agentbox` | the packages you installed and the files you changed outside the home |

A fresh start is deleting both. `make destroy` does exactly that.

## 1. The home volume

| Path | What it holds |
| --- | --- |
| `~/projects` | Your repositories |
| `~/.claude`, `~/.codex`, `~/.config/opencode` | Agent credentials, settings, history |
| `~/.config/herdr`, `~/.config/nvim` | Multiplexer session and editor config |
| `~/.local/share/nvim` | Plugins, LSP servers installed by Mason, treesitter parsers |
| `~/.local/bin`, `~/.local/lib` | `npm i -g` installs (npm's prefix is `~/.local`) |
| `~/.cache` | npm, uv, pip, cargo caches — your builds stay warm |
| `~/.ssh` | Your keys, `known_hosts`, extra authorized keys |
| `~/.agentbox/ssh` | The box's own SSH host keys |
| `~/.bash_history`, `~/.gitconfig`, everything else in the home | Exactly what you would expect |

The host keys living in the volume is not a detail: without it, every
`docker compose up --force-recreate` would change the box's fingerprint and
your phone would refuse to connect with a scary warning.

## 2. The system layer

`sudo apt install postgresql-client` used to vanish on the next recreate. It
does not any more.

**Packages.** A dpkg hook records every package you mark as manually
installed, on top of the list the image ships. On boot, agentbox reinstalls
whatever is missing. The `.deb` cache and the package lists live in the state
volume too, so the replay is usually offline and takes seconds.

**Files.** Anything under `/usr/local`, `/opt`, `/etc`, `/root` and `/srv`
that is *newer than the image build stamp* is yours by definition — you put it
there. It gets copied into the state volume (every 5 minutes, on a graceful
stop, and whenever you ask) and rsynced back over the rootfs at boot, before
sshd starts.

```sh
agentbox-persist status        # what is being kept right now
sudo agentbox-persist save     # capture this second, do not wait for the timer
sudo agentbox-persist forget /usr/local/bin/oops
sudo agentbox-persist forget some-package
sudo agentbox-persist reset    # forget everything: back to a plain image
```

`make persist` prints the same status from your laptop.

### Why not simply mount `/usr` as a volume

Because a named volume is only ever populated **once**, when it is created.
Mount one over `/usr/local` and the node, bun, uv, nvim, herdr and agents that
the image installs there freeze at the version of your first deploy — forever,
including bug fixes. You would be trading "my installs vanish" for "my updates
never arrive", which is the worse of the two.

Recording the delta keeps both: the image stays the source of truth for what it
ships, and the volume owns what you added.

## Not kept

- **Deletions.** Removing a file the image ships brings it back on the next
  boot. Remove the *package* instead, or use `agentbox-persist forget`.
- **Anything under `/usr` outside `/usr/local`, and `/var`.** That is dpkg's
  territory, and the package replay covers it.
- **`/etc/ssh/sshd_config`.** The image owns it. Put your changes in a drop-in
  at `/etc/agentbox/sshd.d/*.conf` — those *are* kept, and they win over the
  defaults.
- **Root's caches** (`/root/.cache`, `/root/.npm`, `/root/.bun`) and files
  generated on every boot (`/etc/hostname`, `/etc/resolv.conf`, the timezone,
  the user database).
- **Running processes.** Restarting kills the agents and the shells inside
  them. Herdr restores the workspace and tab layout from
  `~/.config/herdr/session.json`, but the agent sessions themselves start
  fresh. Detaching (`Ctrl+b` `q`) and losing your connection are free;
  `docker compose restart` is not.

Turn the whole system layer off with `AGENTBOX_PERSIST=0` if you want the old
"only the home survives" behaviour back.

## Three ways to install things

**1. Just install it.** `sudo apt install postgresql-client`. It is recorded
and comes back after a recreate. Right for almost everything.

**2. Put it in `~/.agentbox/provision.sh`.** agentbox runs this file in the
background on every boot, as `dev`, with passwordless sudo. Right when the
install needs *steps* — a repo to add, a config to write, a service to enable.

```sh
cp ~/.agentbox/provision.example.sh ~/.agentbox/provision.sh
nvim ~/.agentbox/provision.sh
```

Keep it idempotent and fast — it runs on every boot, after the package replay,
and its output goes to `~/.agentbox/provision.log`.

**3. Add it to the `Dockerfile` and rebuild.** Right for anything heavy, or
anything you want baked into the image you deploy elsewhere — including onto a
second box, which (2) and (1) will not do for you.

## Updating the image without losing anything

```sh
git pull
make update
```

`make update` rebuilds, recreates the container and keeps both volumes. Config
files that came from the image (`~/.config/nvim`, `~/.config/herdr`) are only
*added* if missing — your edits are never overwritten. To deliberately restore
the shipped versions, boot once with `AGENTBOX_RESEED=force`.

One sharp edge worth knowing: if you edited a file the image also ships and a
newer image changes that same file, your version wins — it is in the state
volume, and the state volume is laid down last. `agentbox-persist forget <path>`
hands the file back to the image.

## Fresh start

```sh
make destroy      # container + both volumes, after typing the volume name
make up
```

Or, without touching the home: `sudo agentbox-persist reset` drops the packages
and files you accumulated, and the next recreate boots the plain image.

## Backups

Both volumes are worth backing up; the home is the one you cannot rebuild.

```sh
make backup                                    # -> ./backups/agentbox-{home,state}-<timestamp>.tar.gz
make restore FILE=backups/agentbox-home-....tar.gz
make restore FILE=backups/agentbox-state-....tar.gz VOLUME=agentbox-state
```

Both work through a throwaway container, so they do not care whether the volume
lives on your laptop or on a VPS.

If you would rather have the home as a plain directory on the host — easier to
back up with your existing tooling, easier to poke at — swap the volume in
`docker-compose.yml`:

```yaml
volumes:
  - ./data/home:/home/dev
```

and set `PUID`/`PGID` in `.env` to your host user's ids (`id -u`, `id -g`) so
the files belong to you on both sides.
