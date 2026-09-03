# Mirroring a project onto your own machine

The agents write code in the box. Some of that code cannot *run* in the box.
An Android build wants the SDK and an emulator with hardware acceleration,
`adb` wants a USB cable, CUDA wants a GPU — and a VPS has none of them.

Port forwarding solves the opposite problem. It brings a server that is already
running inside the box out to your browser (`ssh -L 3000:localhost:3000`), and
it does nothing at all for a Gradle build that has to happen on your desk.

A **mirror** is the answer to this one: the same tree, live, on both sides.
Agents edit in the box, you build and flash on your laptop, and neither of you
copies anything by hand.

```
$ agentbox-mirror myapp
Mirror /home/dev/projects/myapp onto your own machine

  Run this where you want the copy — your laptop, not in here:

    mutagen sync create \
      --name=agentbox-myapp \
      --ignore='node_modules/,.venv/,__pycache__/,target/,build/,...' \
      ~/path/to/myapp \
      dev@box.example.com:2222:/home/dev/projects/myapp
```

## 1. Install Mutagen — on your machine, not in the box

[Mutagen](https://mutagen.io) is a client-side tool. The daemon, the session
list and the configuration all live where you run it; the box is only ever the
far end of a session it does not own. Nothing is installed in the box for this,
and nothing needs to be.

| Platform | Install |
| --- | --- |
| macOS | `brew install mutagen-io/mutagen/mutagen` |
| Linux | Untar the release for your architecture from [the releases page](https://github.com/mutagen-io/mutagen/releases) into `~/.local/bin` |
| Windows | `scoop install mutagen` |

Check it with `mutagen version`. The daemon starts by itself the first time you
create a session.

The box needs nothing: on the first connection Mutagen copies its own agent
binary in over SFTP, into `~/.mutagen`, which is inside the home volume. It
survives a `docker compose down && up` and is copied once, not every boot.

## 2. Tell the box where it lives

The box cannot work out the address you reach it at — the port mapping, and any
reverse proxy in front of it, are on the host, outside the container. So give
it one:

```sh
# .env
AGENTBOX_SSH_HOST=box.example.com
AGENTBOX_SSH_PORT=2222        # the published port, not the container's 22
```

Then `make up`. Without `AGENTBOX_SSH_HOST` everything still works — the
printed command just carries a `<your-server>` placeholder for you to replace.

Check the box is ready before you find out from a Mutagen error:

```
$ agentbox-mirror check
Is this box ready to be mirrored?

  ok    sftp subsystem: /usr/lib/openssh/sftp-server
  ok    mutagen agent directory: /home/dev/.mutagen is writable by dev
  ok    endpoint: dev@box.example.com:2222:/home/dev/projects/<project>

  ready
```

The first two are what Mutagen needs to install its agent, and a failure in
either is what would otherwise surface as an unhelpful "unable to connect to
agent" on your laptop. A missing host is a warning, not a failure: the box
cannot test whether an address outside it resolves, and if you know your own
address you can mirror without setting it.

## 3. Start the mirror

Inside the box, ask for the command:

```sh
agentbox-mirror myapp
```

Paste it on your machine, replacing `~/path/to/myapp` with where you want the
copy. That path is the one thing the box cannot guess, and a plausible wrong
default would silently mirror into the wrong directory.

Then watch the first sync — it is the one that moves real data:

```sh
mutagen sync monitor agentbox-myapp
```

**If you cloned this repository**, you already have the endpoint in `.env` and
can skip the paste:

```sh
make mirror PROJECT=myapp              # lands in ./mirrors/myapp
make mirror PROJECT=myapp LOCAL=~/src/myapp
make mirror-status                     # the mirrors this repo created
make unmirror PROJECT=myapp            # stop; neither copy is deleted
```

`make mirror-status` filters `mutagen sync list` down to sessions named
`agentbox-*`. Rename a session by hand and it drops out of that view —
`mutagen sync list` is the whole truth, always.

`agentbox-mirror` runs anywhere you have a shell in the box, phone included:
`ssh box agentbox-mirror myapp` prints the command on the phone, and you paste
it on the laptop whenever you get to it.

## 4. Android, end to end

This is the workflow the whole thing exists for.

**In the box**, an agent works on the app as usual — edits sources, writes
tests, commits. It cannot build: there is no SDK and no emulator.

**On your laptop**, mirror the project and build there:

```sh
agentbox-mirror android-app          # in the box: prints the command
```

```sh
# on the laptop, after pasting it
cd ~/src/android-app
./gradlew assembleDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

Gradle writes `local.properties` on first use, pointing at *your* SDK
(`sdk.dir=/Users/you/Library/Android/sdk`). That file is in the ignore set, and
has to be: the path is meaningless on the other side, and syncing it back and
forth would break both builds. `build/`, `.gradle/` and `.cxx/` are ignored for
the same family of reasons — hundreds of megabytes of machine-specific output,
regenerated constantly, and a spectacular waste of an uplink.

`.git` is **not** ignored. You are going to run `git` on this copy, and a
mirror without `.git` is not the same repository.

The loop from there:

1. The agent edits in the box; the change is on your laptop a second later.
2. `./gradlew installDebug` on the laptop, on real hardware.
3. You fix a build error locally; the fix is back in the box a second later,
   and the agent sees it.
4. Commit from whichever side you like — it is one repository.

**When the agent and your build race.** A Gradle build reads hundreds of files
while an agent may be rewriting them, and the build can pick up a half-written
tree. Nothing is corrupted — the sync is transactional per file — but the build
output is meaningless. Before a large local refactor or a release build, pause
the agent, or pause the session:

```sh
mutagen sync pause agentbox-android-app
# ... build ...
mutagen sync resume agentbox-android-app
```

## 5. What is ignored, and how to change it

Every command the box prints carries this set:

```
node_modules/  .venv/  __pycache__/  target/  build/  .gradle/  .cxx/
local.properties  dist/  .next/  .DS_Store  *.swp
```

Build output and dependency trees: large, machine-specific, and rebuilt on both
sides anyway. Version control metadata is deliberately absent — the box never
passes `--ignore-vcs`.

To add to it for one session, add another `--ignore`:

```sh
mutagen sync create --name=agentbox-myapp \
  --ignore='node_modules/,build/,...' --ignore='*.apk' \
  ~/src/myapp dev@box.example.com:2222:/home/dev/projects/myapp
```

For a project you mirror more than once, or share with a teammate, keep the
list next to the code instead:

```sh
# in the box
agentbox-mirror project myapp > mutagen.yml
```

Edit `alpha` to your local path, then on your machine:

```sh
mutagen project start
```

A `mutagen.yml` is also the only place an ignore can belong to the *project*
rather than to whoever typed the command — worth committing next to the code
once more than one person mirrors it.

## 6. When both sides change the same file

Sessions are created in `two-way-safe` mode. Both ends legitimately write here
— the agent in the box, you fixing a build error locally — so anything one-way
would silently discard one of them.

`two-way-safe` propagates in both directions and **refuses to resolve a
conflict in a way that loses data**. When the same file changed on both sides
since the last sync, neither version wins: the file is flagged and the session
tells you.

```sh
mutagen sync list          # lists the conflicting paths
mutagen sync monitor agentbox-myapp
```

There is no "pick a winner" switch, and that is deliberate: you resolve a
conflict by making one side the one you want. Delete or overwrite the copy you
are discarding — on either machine — and the surviving version propagates on
the next sync (`mutagen sync flush agentbox-myapp` to wait for it).

The failure mode is "you must look at this", which is the correct one when an
autonomous agent is one of the two writers. Deleting a file counts as a change:
a deletion in the box propagates, so do not treat the mirror as a backup.

## 7. When to forward a port instead

Mirroring is for code that must **run** on your hardware. If what you want is
to *see* something that already runs in the box, forward the port — it is
simpler and moves nothing:

```sh
ssh -p 2222 -L 3000:localhost:3000 dev@box.example.com
```

A web app the agent is developing, a database console, a preview server: all
forwarding. An emulator, a USB device, a GPU, an iOS build: mirroring.

## 8. Security

A mirror puts the box's code on your laptop, including whatever an agent
checked out. That is the point, and it is also a widening of what is at stake —
[security.md](security.md) has the rest.
