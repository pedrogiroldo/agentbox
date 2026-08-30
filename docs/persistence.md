# What survives, and what does not

The rule is one line long:

> **`/home/dev` is a volume on your server. Everything else is the image.**

Understanding that line is the difference between "my container is a pet I am
afraid to touch" and "I rebuild it whenever I want".

## Persistent (in the `agentbox-home` volume)

| Path | What it holds |
| --- | --- |
| `~/projects` | Your repositories |
| `~/.claude`, `~/.codex`, `~/.config/opencode` | Agent credentials, settings, history |
| `~/.config/herdr`, `~/.config/nvim` | Multiplexer session and editor config |
| `~/.local/share/nvim` | Plugins, LSP servers installed by Mason, treesitter parsers |
| `~/.local/bin`, `~/.local/lib` | `npm i -g` installs (npm's prefix is `~/.local`) |
| `~/.ssh` | Your keys, `known_hosts`, extra authorized keys |
| `~/.agentbox/ssh` | The box's own SSH host keys |
| `~/.bash_history`, `~/.gitconfig`, everything else in the home | Exactly what you would expect |

The host keys living in the volume is not a detail: without it, every
`docker compose up --force-recreate` would change the box's fingerprint and
your phone would refuse to connect with a scary warning.

## Not persistent (rebuilt from the image every time)

Anything outside the home: `/usr`, `/etc`, `/opt`, and packages you install
with `sudo apt install`. A container recreate resets all of it.

That is a feature — it is what makes the box disposable — but it means a
`sudo apt install` you want to keep needs a home for the instruction.

## Three ways to install things

**1. Just install it.** `sudo apt install postgresql-client`. Works
immediately, gone on the next recreate. Right for one-offs.

**2. Put it in `~/.agentbox/provision.sh`.** agentbox runs this file in the
background on every boot, as `dev`, with passwordless sudo. Survives
recreates, no rebuild needed. Right for "I always want this".

```sh
cp ~/.agentbox/provision.example.sh ~/.agentbox/provision.sh
nvim ~/.agentbox/provision.sh
```

Keep it idempotent and fast — it runs on every boot, and its output goes to
`~/.agentbox/provision.log`.

**3. Add it to the `Dockerfile` and rebuild.** Right for anything heavy, or
anything you want baked into the image you deploy elsewhere. `make update`
rebuilds and recreates the container; the home volume is untouched.

Rule of thumb: try it with (1), keep it with (2), and promote it to (3) when
waiting for it on boot starts annoying you.

## What a restart costs you

Files survive a restart; *running processes* do not. Restarting the container
kills the agents and the shells inside them — Herdr restores the workspace and
tab layout from `~/.config/herdr/session.json`, but the agent sessions
themselves start fresh. Detaching (`Ctrl+b` `q`) and losing your connection are
free; `docker compose restart` is not.

## Updating the image without losing anything

```sh
git pull
make update
```

`make update` rebuilds, recreates the container and keeps the volume. Config
files that came from the image (`~/.config/nvim`, `~/.config/herdr`) are only
*added* if missing — your edits are never overwritten. To deliberately restore
the shipped versions, boot once with `AGENTBOX_RESEED=force`.

## Backups

The volume is the only thing worth backing up:

```sh
make backup                                   # -> ./backups/agentbox-home-<timestamp>.tar.gz
make restore FILE=backups/agentbox-home-....tar.gz
```

Both work through a throwaway container, so they do not care whether the box is
a Docker volume on your laptop or on a VPS.

If you would rather have the home as a plain directory on the host — easier to
back up with your existing tooling, easier to poke at — swap the volume in
`docker-compose.yml`:

```yaml
volumes:
  - ./data/home:/home/dev
```

and set `PUID`/`PGID` in `.env` to your host user's ids (`id -u`, `id -g`) so
the files belong to you on both sides.
