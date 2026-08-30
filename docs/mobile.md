# Using agentbox from a phone

The whole point of this box is that a phone is enough to check on your agents,
read their diffs and unblock them. This is what that actually looks like.

## 1. An SSH client

Anything that speaks SSH works. Known-good options:

| Platform | Client | Notes |
| --- | --- | --- |
| iOS | [Termius](https://termius.com) | Free tier is enough; has a customizable extra key row |
| iOS | [Blink Shell](https://blink.sh) | Paid, best-in-class, supports mosh |
| Android | [Termius](https://termius.com) | Same account syncs with the iOS app |
| Android | [Termux](https://termux.dev) + `ssh` | A real terminal; `pkg install openssh` |

Set up a host with:

- **Hostname**: your server's IP or domain
- **Port**: whatever you mapped (`2222` by default)
- **Username**: `dev`
- **Key**: the private key whose public half you put in `SSH_PUBLIC_KEY`

Generate the key **on the phone** (Termius and Blink both do this), then paste
its public half into `SSH_PUBLIC_KEY` alongside your laptop's key — one per
line. Never copy a private key between devices.

## 2. Client settings that matter

- **Terminal type**: `xterm-256color`.
- **True color**: on. The box exports `COLORTERM=truecolor` for you, but the
  client has to be willing.
- **Font size**: 10–12pt. Herdr and Neovim both adapt to the width they get,
  and mobile mode in Neovim triggers below 90 columns.
- **Extra key row**: enable it and make sure it has `Esc`, `Ctrl`, `Tab` and
  the arrow keys. Herdr's prefix is `Ctrl+b`; without a `Ctrl` key you are
  stuck.
- **Keep alive**: the server already sends keepalives every 30s. If your client
  offers its own, match it.

## 3. The banner

Every terminal you open prints the agentbox wordmark — the SSH login and each
herdr pane. It comes in three sizes and picks by terminal width, so a phone
gets the compact one instead of six wrapped lines of confetti.
`AGENTBOX_BANNER=login` limits it to the SSH login, `off` turns it off, and
`AGENTBOX_BANNER_BY` sets the line underneath.

The full block letters need 90 columns. They are only 69 wide, but 80 columns
on a phone means a font too small to read, and 80 is also what a client that
never measured its window reports out of habit — so the big one is reserved
for terminals that are genuinely wide. Check what yours claims with
`tput cols`, and try any width without resizing anything:

```sh
AGENTBOX_BANNER_COLS=45 agentbox-banner
```

Only the SSH login gets more than the wordmark: a one-screen summary of
versions and paths, and even that needs a terminal at least 70 columns wide and
26 rows tall. On a phone you get the banner plus a `run herdr to start` line,
and a herdr pane gets the banner alone.

## 4. Herdr in one minute

`herdr` is the first thing to run after logging in. It is a terminal
multiplexer built for coding agents: it keeps everything running when you
disconnect, and it labels each pane with the agent inside it and whether that
agent is working or waiting for you.

Everything is `Ctrl+b` (the *prefix*) followed by a key:

| Keys | Does |
| --- | --- |
| `Ctrl+b` `?` | Help — the authoritative list, always start here |
| `Ctrl+b` `q` | Detach. Close the app; agents keep running |
| `Ctrl+b` `c` | New tab |
| `Ctrl+b` `n` / `p` | Next / previous tab |
| `Ctrl+b` `1`…`9` | Jump to tab N |
| `Ctrl+b` `w` | Workspace picker |
| `Ctrl+b` `Shift+n` | New workspace (one per project) |
| `Ctrl+b` `Shift+g` | New git worktree — parallel agents, no conflicts |
| `Ctrl+b` `v` / `-` | Split the pane vertically / horizontally |
| `Ctrl+b` `z` | Zoom the current pane full screen |
| `Ctrl+b` `b` | Toggle the sidebar (more screen for the pane) |
| `Ctrl+b` `x` | Close the pane |

On a phone, `Ctrl+b` `z` and `Ctrl+b` `b` are the two you will use constantly:
one screen, one thing.

Reconnecting is just `ssh` again and `herdr` — it reattaches to the running
session with every agent exactly where you left it.

## 5. Neovim on a 6-inch screen

The config in this image is the LazyVim starter plus a **mobile mode** that
turns on by itself when the terminal is narrower than 90 columns (force it with
`NVIM_MOBILE=1 nvim`). It is inert on a desktop-sized terminal.

What changes:

- Relative numbers, sign column, fold column and the status line are gone —
  every column goes to the text.
- Soft wrapping is on, so long lines are readable instead of scrolling.
- `jk` in insert mode is `Esc`. Reaching for `Esc` on a software keyboard is
  worse than it sounds.
- The file explorer and the picker open full screen with the preview stacked
  vertically instead of fighting for columns.
- Scroll animation, indent guides, the dashboard, `noice`, `bufferline`, inlay
  hints and codelens are off — each of them repaints many cells per keystroke,
  which is the dominant cost over a mobile link.
- Mouse support is on: taps and drags from the SSH client move the cursor.
- Yanks go to your phone's clipboard through OSC 52 (any SSH session, not just
  mobile).

`<leader>gw` (space, g, w) opens a git worktree switcher — handy when several
agents work on the same repo in different worktrees.

## 6. mosh (optional)

`mosh` is installed. It survives switching between Wi-Fi and mobile data and
hides latency while you type, which is a real difference on a train.

It needs UDP ports 60000–60010, which most managed proxies do not forward. If
your host allows it, uncomment the UDP range in `docker-compose.yml`, open the
same range in your firewall, and connect with:

```sh
mosh --ssh="ssh -p 2222" dev@your-server
```

If UDP is not an option, plain SSH is fine — the box already keeps agents alive
across disconnects, which is what mattered anyway.
