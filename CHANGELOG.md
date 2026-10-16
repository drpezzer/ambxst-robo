# Changelog

## 1.1.0 — installs itself

Installing or updating the mod in Ambxst is now all there is to do: no Rust,
no build, no service to set up.

- **The mod sets up its daemon**: on shell start it checks `ambxst-robo` and,
  when it is missing or not the mod's version, downloads the matching
  release build (x86_64 or aarch64), checks its SHA-256, installs it in
  `~/.local/bin`, writes and enables the user service and starts it. Where no
  ready-made build fits, it builds the release's sources with `cargo` if it
  can. The notch and Robo's tab show "Setting up Robo…", "Updating Robo's
  core…" or what went wrong, with **Retry**.
- **Updates follow the mod**: after a mod update the daemon is replaced by the
  same version, restarted once no chat reply is under way. Until then Robo's
  tab says the update is waiting, and the island takes the new daemon's
  settings as soon as it answers.
- **Claude Code in one click**: the first time, Robo's tab offers to connect
  Claude Code (its hooks, with a backup of `~/.claude/settings.json`).
  Installed hooks and the hook relay now follow the daemon's version on their
  own.
- The daemon answers a new `version` request; the user service refreshes the
  hook relay on every start (`AMBXST_ROBO_INSTALL_RELAY=1`).
- Releases are built by GitHub Actions (`.github/workflows/release.yml`) and
  attached to each tag's release with `SHA256SUMS`.
- The manifest no longer requires `ambxst-robo` on `PATH` (a fresh system
  could not enable the mod), and declares that the mod installs its daemon.
  This update therefore asks for a review in Ambxst.

Upgrading from 1.0.0: the update replaces the daemon you built in
`~/.local/bin` and rewrites `~/.config/systemd/user/ambxst-robo.service`
(keep your own changes in a drop-in). Developers: `touch
~/.config/ambxst-robo/dev` keeps the mod off your own builds.

## 1.0.0 — first public release

Ambxst Robo puts Coucou's island in Ambxst's notch, with a Rust daemon in
place of Coucou's Tauri backend.

- **Agents in the notch**: Claude Code, Codex, Gemini CLI, Cursor Agent,
  GitHub Copilot CLI and others, hooked through a small relay; one pill per
  session, with what it is doing and when it finished.
- **Approve and answer without switching windows**: permission requests
  (with their diffs) and agents' questions open the notch on their own,
  without taking the keyboard; Allow / Deny or pick an answer from there.
- **Chat**: with Claude through the Claude Code CLI (in a folder you choose,
  asking before each tool or in read-only, edit or auto mode), the API, or a
  local OpenAI-compatible server (Ollama, LM Studio, your own); saved chats
  and history.
- **Drop files** on the notch or the bar to hand them to the chat.
- **Two mascots**: Axenide (the Ambxst logo come to life, the default) and
  Robo, a TV-headed robot whose shape, antenna and colours you pick in
  Settings → Style; they react to what your agents do, greet you, sleep and
  can live on the desktop.
- **Integrations and pills**: GitHub, Vercel, Resend, n8n, Spotify and other
  media, Claude and Codex plan usage, a weekly recap you can share.
- **Settings inside Ambxst** (its AI tab): agents and hooks, chat providers
  and keys (kept in the Secret Service), integrations, shortcuts, sounds and
  style, in the languages Coucou ships.
- `ambxst-robo --migrate-from-coucou` copies settings, chats, keys and hooks
  over from Coucou on Linux.

Tested on Ambxst 1.3.12 (Hyprland).
