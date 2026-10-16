# Changelog

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
