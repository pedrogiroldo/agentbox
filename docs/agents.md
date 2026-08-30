# The agents

The image ships three coding agents, all installed globally:

| Agent | Command | Login |
| --- | --- | --- |
| [Claude Code](https://claude.com/claude-code) | `claude` | `claude` then `/login` |
| [Codex CLI](https://developers.openai.com/codex/cli) | `codex` | `codex login` |
| [opencode](https://opencode.ai) | `opencode` | `opencode auth login` |

## Logging in

Every agent stores its credentials under your home directory, so **you log in
once** and it survives restarts, recreates and image rebuilds.

The browser-based login flows print a URL. Open it on whatever device you are
holding — the callback is a code you paste back into the terminal, so nothing
needs to reach the container. If an agent insists on a localhost callback,
forward the port from your laptop:

```sh
ssh -p 2222 -L 1455:localhost:1455 dev@your-server
```

API-key auth works too and is often simpler on a headless box: set the key in
the agent's own config, or export it from `~/.agentbox/provision.sh`.

## Herdr integrations

On every boot agentbox runs `herdr integration install` for claude, codex and
opencode. Those integrations are small hooks in each agent's config that report
the agent's state back to the pane it runs in — that is what makes the Herdr
sidebar show which agent is working and which one is waiting for your answer.
It is the single most useful thing when you have five panes and a phone screen.

Turn it off with `AGENTBOX_HERDR_INTEGRATIONS=0` if you manage those configs
yourself.

## Running several agents at once

This is where Herdr earns its place:

- `Ctrl+b` `Shift+n` — a **workspace** per project.
- `Ctrl+b` `c` — a **tab** per task inside the project.
- `Ctrl+b` `Shift+g` — a **git worktree** per agent, so two agents can work on
  the same repository at the same time without stepping on each other's files.
- `<leader>gw` in Neovim jumps between those worktrees while keeping the file
  you were looking at.

Detach with `Ctrl+b` `q`, close your laptop, and check back from your phone.

## Updating the agents

They are installed from npm into the image, so the clean way is:

```sh
make update     # rebuilds with the latest versions
```

To pin exact versions, set `CLAUDE_CODE_VERSION`, `CODEX_VERSION` and
`OPENCODE_VERSION` in `.env` before building.

You can also update in place — `npm` inside the box installs into `~/.local`,
which is persistent and takes precedence over the image's copy:

```sh
npm install -g @anthropic-ai/claude-code@latest
```

## Adding another agent

Anything installable with `npm`, `curl | sh` or `apt` works. Put it in
`~/.agentbox/provision.sh` to keep it across recreates, or add it to the
`Dockerfile` to bake it into the image. Herdr recognizes many agents beyond
these three — `herdr integration` lists what it can hook into.
