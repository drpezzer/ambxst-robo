# Ambxst Robo

![Robo in the notch: it opens on a chat, works through a turn and answers](docs/media/notch-open.gif)

Version 1.0.0 — see the [changelog](CHANGELOG.md).

Ambxst Robo puts a small robot in [Ambxst](https://github.com/Axenide/Ambxst)'s
notch. It keeps an eye on your AI coding agents (Claude Code, Codex, Gemini
CLI, Cursor Agent, GitHub Copilot CLI and others) and lets you deal with them
without leaving what you are doing:

- approve or deny permission requests and answer agents' questions from the notch;
- see what each session is doing, when it finished, and a recap of your day;
- chat with Claude (the Claude Code CLI, the API, or a local OpenAI-compatible model);
- drop files on the notch to hand them to the chat;
- keep an eye on your services (GitHub, Spotify and more) from the island.

The mascot is either **Axenide** (the Ambxst logo come to life, the default) or
**Robo**, a little TV-headed robot, in the colours and shapes you pick in
Settings → Style.

It is a port of [Coucou](https://github.com/Louis-CFM/coucou) by Louis Raillé
to Linux and Ambxst: Coucou's island logic runs inside Ambxst's QML shell, and
its backend is reimplemented as a small Rust daemon.

## Gallery

Rendered with demo data (made-up projects and chats).

| | |
| --- | --- |
| ![A chat at work: the working line and the folder chip](docs/media/chat-working.png) | ![A message typed during a turn waits under the working line](docs/media/chat-queued.png) |
| The chat at work: "✻ verb…" while Claude Code runs, the working directory's chip beside the model. | A message sent mid-turn waits under the working line, with its caption. |
| ![The home view with the chats column](docs/media/home.png) | ![Settings](docs/media/settings.png) |
| Home: the session in front, the other agents' minis, the home chat and the chats column. | Settings: agents' hooks, and Style (Robo or Axenide, Robo's shape, antenna, colours). |

Robo through a turn: thinking, working while a tool runs, talking while the answer streams in, happy when done.

![Robo thinking, working, then talking during a turn](docs/media/robo-turn.gif)

The bar: Robo in place of the Ambxst logo, the other sessions as minis beside him. A
session's helpers (subagents) show up as liquid blobs that pop when they finish.

![The bar with minis](docs/media/bar.png)

![Helper blobs appearing in the bar](docs/media/bar-helpers.gif)

Drag a chat's mini onto the chats column to put it away: it melts into a ball of its colour and pops.

![Dragging a mini onto the chats column](docs/media/drag-to-chats.gif)

The chats column on its own, and the greeting the first time the notch opens (Axenide, the default mascot):

<img src="docs/media/chats-column.png" alt="The chats column" width="215"> <img src="docs/media/greeting.gif" alt="The launch greeting" width="600">

The two mascots and their moods:

![Robo and Axenide expressions](docs/media/mascots.png)

## How it fits together

| Part | What it is |
| --- | --- |
| `core/` | `ambxst-robo`, a user daemon (hooks, approvals, chat, integrations, settings), and `ambxst-robo-hook`, the relay your agents' hooks call. Rust. |
| `mod/` | The Ambxst mod (`drpezzer.ambxst-robo`): the QML payload, the built library `modules/robo/robo-lib.js`, Robo's sounds, and a patch to Ambxst. |
| `lib/` | TypeScript sources of `robo-lib.js`: Coucou's island code (vendored in `lib/vendor/coucou`) plus the QML host shims and the mascots. |

The shell talks to the daemon over `$XDG_RUNTIME_DIR/ambxst-robo-core.sock`;
agents' hooks reach it through the relay on `$XDG_RUNTIME_DIR/ambxst-robo.sock`.
`core/PROTOCOL.md` describes the protocol.

## Requirements

- [Ambxst](https://github.com/Axenide/Ambxst) 1.3.10 or newer, below 2.0.0,
  with mod support (`ambxst mods`). Ambxst Robo 1.0.0 is tested on Ambxst
  1.3.12, on Hyprland (the shell reads the cursor and windows through
  `hyprctl`).
- Git, and Rust (stable) with Cargo, to build the daemon.
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) (the `claude`
  CLI on your `PATH`) for Claude Code sessions in the notch and for the chat's
  Claude Code mode. Other agents (Codex, Gemini CLI, Cursor Agent, GitHub
  Copilot CLI…) are optional.
- The Secret Service (GNOME Keyring, KWallet…) if you want to store API keys.
- Node.js 18+ and npm, only to rebuild `robo-lib.js` (the built file is in the
  repo).

## Install

1. Get the sources:

   ```sh
   git clone https://github.com/drpezzer/ambxst-robo.git
   cd ambxst-robo
   ```

2. Build the daemon and its hook relay, and install both:

   ```sh
   (cd core && cargo build --release)
   install -Dm755 core/target/release/ambxst-robo ~/.local/bin/ambxst-robo
   install -Dm755 core/target/release/ambxst-robo-hook ~/.local/bin/ambxst-robo-hook
   ```

   On its first start the daemon copies the relay to
   `~/.local/share/ambxst-robo/bin/ambxst-robo-hook`, the path the agents'
   hooks call.

3. Run the daemon as a user service:

   ```sh
   install -Dm644 core/ambxst-robo.service ~/.config/systemd/user/ambxst-robo.service
   systemctl --user daemon-reload
   systemctl --user enable --now ambxst-robo.service
   ```

   To let it refresh the relay from the binary in `~/.local/bin` on each start
   (after an update), uncomment `Environment=AMBXST_ROBO_INSTALL_RELAY=1` in
   the unit.

4. Install the mod, enable it and restart Ambxst:

   ```sh
   ambxst mods install "$PWD/mod"
   ambxst mods enable drpezzer.ambxst-robo
   ambxst reload
   ```

   Ambxst keeps the path it installed from: leave the clone where it is, so
   `ambxst mods update` can find it. (You can also install the mod straight
   from GitHub with
   `ambxst mods install https://github.com/drpezzer/ambxst-robo/tree/main/mod`;
   you still need the clone for the daemon. Use that `/tree/main/mod` form:
   with the bare repository URL the install works but `mods update` does not.)

   The mod takes over `SUPER+A` (`ambxst run assistant`) and the bar's logo,
   and opens the notch on its own for permission requests and questions.

5. Hook up your agents: open Robo's settings (Ambxst's settings, AI tab, or
   *Settings…* in the menu you get with a middle click on Robo in the bar),
   and in **Agents** install the hooks for Claude Code and for the other
   agents you use. Restart sessions that were already running so they pick the hooks
   up.

### Where things live

| What | Where |
| --- | --- |
| Settings | `~/.config/ambxst-robo/settings.json` (edited from Robo's settings) |
| Your own sounds | `~/.config/ambxst-robo/sounds` (see [Sounds](#sounds)) |
| Saved chats, recap, log (`ambxst-robo.log`) | `~/.local/share/ambxst-robo` |
| Hook relay | `~/.local/share/ambxst-robo/bin/ambxst-robo-hook` |
| Sockets | `$XDG_RUNTIME_DIR/ambxst-robo-core.sock` (shell), `$XDG_RUNTIME_DIR/ambxst-robo.sock` (relay) |

### Update

```sh
git pull
(cd core && cargo build --release)
tools/ambxst-robo-update          # installs both binaries, restarts the service once no chat turn runs
ambxst mods update drpezzer.ambxst-robo
ambxst reload
```

If `mods update` asks you to review the changes (a release changed the mod's
permissions or commands), run `ambxst mods check-updates drpezzer.ambxst-robo`
and then `ambxst mods apply-updates <plan>` as it says.

### Uninstall

```sh
ambxst mods disable drpezzer.ambxst-robo && ambxst mods remove drpezzer.ambxst-robo && ambxst reload
systemctl --user disable --now ambxst-robo.service
rm ~/.config/systemd/user/ambxst-robo.service ~/.local/bin/ambxst-robo ~/.local/bin/ambxst-robo-hook
```

Remove the agents' hooks first (Robo's settings, Agents) if you installed them.
Your settings and chats stay in `~/.config/ambxst-robo` and
`~/.local/share/ambxst-robo`.

Coming from Coucou on Linux? `ambxst-robo --migrate-from-coucou --dry-run`
shows what it would copy over (settings, saved chats, keys, hooks); run it
again without `--dry-run` to do it. It copies and never deletes.

## Build

The library the mod loads, `mod/payload/modules/robo/robo-lib.js`, is built
from `lib/` with esbuild:

```sh
npm ci
node lib/build.mjs            # → mod/payload/modules/robo/robo-lib.js
```

After adding or removing payload files, regenerate the manifest's overlay list
(`git add` the files first; it lists tracked files only):

```sh
python3 tools/gen-manifest.py
```

The daemon: `cd core && cargo build --release`, tests with `cargo test`
(they write under `$XDG_DATA_HOME`; point it at a temporary directory).
`core/smoke.py` starts an isolated daemon and feeds it fake hook events.

## Sounds

Robo's sounds are in `mod/payload/assets/robo/sounds`. To use your own, put
a file with the same name (`finish.wav`, `approval.mp3`, `greet.m4a`…) in
`~/.config/ambxst-robo/sounds` and use *Reload sounds* in Robo's settings
(General).

## Credits

- [Coucou](https://github.com/Louis-CFM/coucou) by Louis Raillé (MIT): Ambxst
  Robo is a port of it, and most of the island's behaviour, views and
  translations are Coucou's. The name "Coucou", Coucou's mascot character and
  Coucou's sounds and artwork are Coucou's author's and are not part of this
  project.
- [Ambxst](https://github.com/Axenide/Ambxst) by Axenide: the shell this runs
  in, and the logo that Axenide, the default mascot, is drawn from.
- [robot-heads](https://github.com/fayazara/robot-heads) by Fayaz Ahmed (MIT):
  Robo's head and its renderer (`lib/robot/tv`).

## License

Copyright (C) 2026 drpezzer. Ambxst Robo is free software under the
[GNU Affero General Public License v3.0 or later](LICENSE)
(`AGPL-3.0-or-later`), like Ambxst itself.

Parts of it come from Coucou, by Louis Raillé, under the MIT License; that
code keeps its MIT notice (`lib/vendor/coucou/LICENSE`). [NOTICE](NOTICE) lists
those parts and the others under their own licences.
