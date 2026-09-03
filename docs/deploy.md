# Deploying agentbox on a server

agentbox is a single container with one volume and one exposed port. Anything
that runs Docker can host it.

## Plain VPS with Docker

```sh
git clone https://github.com/pedrogiroldo/agentbox.git
cd agentbox
make init          # writes .env with this machine's public key
$EDITOR .env       # add your phone's key, set SSH_PORT, timezone, git identity
make up
```

Then, from anywhere:

```sh
ssh -p 2222 dev@your-server
herdr
```

Open the port in your firewall (`ufw allow 2222/tcp`), and see
[security.md](security.md) before pointing it at the open internet.

## Coolify / Dokploy

This is the case the project was designed for: you already pay for a VPS
running a PaaS, and you want a dev box on it without provisioning a second
machine.

1. Create a new resource of type **Docker Compose**.
2. Point it at this repository (it will build the image), or paste
   [`deploy/docker-compose.ghcr.yml`](../deploy/docker-compose.ghcr.yml) to pull
   the prebuilt image instead. On a small VPS, prefer the prebuilt image — the
   build compiles Neovim plugins and is not free.
3. Set the environment variables: `SSH_PUBLIC_KEY` (required), `GIT_USER_NAME`,
   `GIT_USER_EMAIL`, `TZ`.
4. Publish the port. SSH is raw TCP, so the platform's HTTP proxy (Traefik) is
   not involved — you need a real host port mapping, `2222:22`, and that port
   open in the server's firewall.
5. Deploy, then check the logs. A healthy boot ends with
   `[agentbox] ready — sshd is listening on port 22`.

Two named volumes come with it: `agentbox-home` (your repos, credentials and
config) and `agentbox-state` (the packages you install and the files you change
outside the home). Both platforms let you see and snapshot them; deleting both
is what "start over" means. See [persistence.md](persistence.md).

### Updating a deployed box

Pulling a newer image is safe: neither volume is ever mounted over the image,
so an update brings you newer tooling while your packages and files are
replayed on top.

The catch is getting the new image at all. `docker compose up` pulls a tag only
when the daemon does not already have it, so the second deploy of `:latest`
reuses the image from the first -- and because the image id never changed,
compose leaves the running container alone. The deploy succeeds and nothing is
new. Dokploy runs `up -d --build`, which does not help: with no `build:` in the
service, `--build` has nothing to build.

`deploy/docker-compose.ghcr.yml` ships `pull_policy: always` for exactly this.
If you pasted the file before that line existed, add it, or pin an immutable
`:sha-xxxxxxx` tag so each deploy names a different image. In Coolify, *Pull
latest image on deploy* does the same thing from the UI.

To confirm what a box is actually running:

```sh
docker inspect -f '{{index .RepoDigests 0}} {{.Created}}' agentbox
```

Compare the digest with the one on the package page. If it lags, force the
issue once by hand:

```sh
docker compose -f docker-compose.yml pull
docker compose -f docker-compose.yml up -d --force-recreate
```

### Building on the server vs. pulling an image

| | Build from the repo | Pull `ghcr.io/...` |
| --- | --- | --- |
| First deploy | Slow (5–15 min), needs RAM | Fast |
| Customization | Edit the `Dockerfile`, redeploy | Fork and let CI build it |
| Small VPS | Can OOM during the Neovim plugin step | Fine |

If you build on a constrained server, set `PREINSTALL_NVIM_PLUGINS=false` to
skip the heaviest step; plugins then install the first time you open Neovim.

> Packages pushed to GHCR start out **private**. If you forked this repo and
> want to pull the image without logging in, open the package on GitHub
> (Profile → Packages → agentbox) and set its visibility to public.

## Several boxes on one host

Give each one its own name, port and volume:

```sh
AGENTBOX_NAME=box-work AGENTBOX_HOSTNAME=box-work \
AGENTBOX_VOLUME=box-work-home SSH_PORT=2223 \
docker compose -p box-work up -d
```

## Health and logs

- `docker compose ps` shows the healthcheck (it probes port 22).
- `docker compose logs -f` shows the boot sequence and your provision script's
  output.
- `make shell` opens a shell inside the box without SSH — the rescue hatch when
  you locked yourself out.
