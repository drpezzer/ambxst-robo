# ambxst-robo protocol

The contract between `ambxst-robo` (this daemon) and the QML side of the Ambxst port.
It mirrors `windows/src/core/bridge.ts` 1:1: same command names, same camelCase argument
keys, same result shapes, same event names and payloads as the Tauri app. Differences are
marked **(core)**.

## Transport

- Socket: `$XDG_RUNTIME_DIR/ambxst-robo-core.sock`, mode 0600. Only clients with the same uid
  are accepted. A private runtime directory is required (same check as Coucou's relay socket).
- Single instance: on start, if the socket answers, the daemon prints
  `another ambxst-robo is already running on …` and exits 1. A stale file is removed.
- Newline-delimited JSON, UTF-8, one object per line, max 4 MiB per request line.

Request:

```json
{"id": 7, "cmd": "approval_decision", "args": {"requestId": "1234-5", "decision": "allow"}}
```

Reply (same `id`, any JSON value is echoed back):

```json
{"id": 7, "ok": true, "result": null}
{"id": 7, "ok": false, "error": "invalid args for key requestId: invalid type: null, expected a string"}
```

Event (broadcast to every connected client, unsolicited, interleaved with replies):

```json
{"event": "hook", "payload": {...}, "target": "island"}
```

`target` is the Tauri window label the event was sent to (`"island"` for `emit_to(island, …)`),
or `null` for a broadcast `emit`. There is no subscribe step: every connected client gets
every event. Nothing is buffered for clients that are not connected.

Every request runs as its own task: a slow command (`chat_send`, `codex_plan_usage`,
`refresh_integration`, Spotify D-Bus calls) never delays other requests. Replies can
therefore arrive out of order; match them by `id`.

Arguments: a missing key reads as `null`, so optional arguments may be left out (as with
Tauri). A required argument that is missing or of the wrong type gives `ok:false`.

## Permission requests and questions (safety)

A `PermissionRequest` from the relay (Claude Code's tool approval, and `AskUserQuestion`,
which arrives as a `PermissionRequest` with `tool_name: "AskUserQuestion"`) is emitted as a
`hook` event whose payload carries `request_id`. Then:

1. **No client connected** → released at once (the relay prints nothing, Claude Code asks
   in the terminal). **(core)**
2. A client must send `approval_ack {requestId}` within **800 ms** (Coucou's ACK_TIMEOUT),
   meaning "the card is on screen". Without it the request is released.
3. After the ack the daemon waits up to 108 s for `approval_decision` /
   `approval_answer` / `approval_decline`.
4. **The acking client disconnects** (or the last client disconnects) → every request it
   acked is released at once. **(core)**

The QML side should ack only when it really shows the card, and `approval_decline` when it
can't (paused, another card up), exactly like the island.

**(core)** The chat's own Claude Code runs (provider `claudecode`, modes other than "Read
only") ask the same way, without the relay: ambxst-robo gets the CLI's `can_use_tool`
control request and emits a `chat-permission` event (not `hook`) with `request_id`
(`chat-…`), `tool_name`, `tool_input` (strings capped at 2000), `description`,
`session_id`, `cwd`. The same ack / decision / answer / decline commands and timeouts
apply; no click means the CLI is told no (after the ack, within 108 s; the island also drops the card by itself at 110 s). `chat-permission-gone {request_id}` says the run
stopped waiting (card moot). Chat requests are never recorded in the weekly recap.

## Commands

All results are JSON. `null` = Tauri's `()`.

### App and settings

| cmd | args | result |
|---|---|---|
| `version` | – | `{version, protocol}` **(core, 1.1.0)**: the daemon's version (the mod compares it with its own and updates the daemon when they differ) and the protocol revision (1). Older daemons answer `unknown command`. |
| `boot` | – | `{settings, screen, version, hookPath, cursorPoll, relaySocket}` — `settings` is the full Settings object (settings.json, camelCase), with `hooksInstalled`/`planRelayInstalled` taken from ~/.claude/settings.json. **(core)** `screen` is a placeholder `{x:0,y:0,width:0,height:0,scale:1}`, `cursorPoll` is always `false`, `relaySocket` (new) is whether this daemon serves `ambxst-robo.sock` (false if the Tauri Coucou holds it). |
| `save_settings` | `settings: Settings` | `null`. Saves settings.json, emits `settings-changed`. `desktopMascot` and every `phone*` field are kept from the stored settings (not taken from the client). **(core)** `screen` and `autostart` are stored but not acted on. |
| `set_system_languages` | `languages: string[]` | `null` (Rust-side strings follow "System" language). |
| `set_paused` | `paused: bool` | `null`. Paused = integration pollers make no network calls. |
| `log_line` | `message: string` | `null`. Appends `ui  <message>` to `~/.local/share/ambxst-robo/ambxst-robo.log`. |
| `quit_app` | – | `null`. **(core)** The daemon exits (sockets removed). With the systemd unit's `Restart=on-failure` it stays down (clean exit). |
| `ping` | – | `"pong"` **(core, new)** |

### Opening things

| cmd | args | result |
|---|---|---|
| `open_url` | `url: string` | `null`; only http(s), via xdg-open. |
| `open_in_vscode` | `path: string\|null` | `bool`; `code <folder>` or the folder in the file manager. Only an existing absolute folder. |
| `open_session` | `sessionId: string\|null, path: string\|null` | `bool`; raises the session's terminal/editor window (linux_focus: KWin / EWMH / kitty) found from the relay's process tree, else `open_in_vscode`. |
| `open_file_in_vscode` | `path: string` | `bool`; an existing absolute file in `code`, else its folder. Never opened by type. |
| `open_claude_desktop` | – | `false` (no Claude desktop app on Linux). |
| `open_n8n` | – | `null`; opens the stored `n8n-url`. |

### Claude Code hooks, other agents, plan usage

Never call the `*_apply` commands except from an explicit user click on a preview: they
write `~/.claude/settings.json` (or the agent's config) — with a backup and only if the file
still matches the previewed `fingerprint`.

| cmd | args | result |
|---|---|---|
| `hooks_status` | – | `{installed, planRelayInstalled, settingsPath, hookPath, hookReady}` |
| `hooks_preview` | `install: bool` | `{diff, backup, settingsPath, fingerprint}` or error |
| `hooks_apply` | `install: bool, fingerprint: string` | backup path `string`; emits `settings-changed` |
| `agent_hooks_status` | – | `{[pillId]: bool}` (e.g. `integration_claude`, `agent_cursor`) |
| `agent_hooks_list` | – | `[{id, name, installed, path, hookReady, approvals, note}]` |
| `agent_hooks_preview` | `agent: string, install: bool` | `{diff, backup, path, fingerprint}` |
| `agent_hooks_apply` | `agent, install, fingerprint` | backups `string` |
| `status_line_preview` | `install: bool` | same shape as `hooks_preview` |
| `status_line_apply` | `install: bool, fingerprint: string` | backup `string`; turning it off also sets `showPlanInNotch=false`; emits `settings-changed` |
| `codex_plan_usage` | – | raw `account/rateLimits/read` JSON from `codex app-server`, or `null` (missing / not signed in / slow, 15 s) |

Claude plan usage itself arrives through the status line relay as `hook` events with
`hook_event_name: "StatusLine"` (unchanged from Coucou). **(core)** The relay also passes
`context_window: {used_percentage, context_window_size}` (numbers or null) of the session
that ran the status line, for the plan pill's "ctx" figure.

### Approvals and questions

| cmd | args | result |
|---|---|---|
| `approval_ack` | `requestId: string` | `null`. The card is up; the long wait begins. The sending client becomes the request's owner. |
| `approval_decision` | `requestId: string, decision: "allow"\|"always"\|"deny"` | `null`. `always` is sent as `allow`. Recorded for the weekly recap. |
| `approval_answer` | `requestId: string, answers: {[questionText]: string \| string[]}` | `null`. Must answer every question (single-select = a label or the user's own typed answer, multiSelect = non-empty list of distinct labels plus at most one typed answer; a typed answer is non-blank, at most 4000 characters — Claude Code's "Other"), or the relay prints nothing (terminal asks) / the chat run is told no. |
| `approval_decline` | `requestId: string` | `null`. Nobody can act on it: released at once. |

### Chat, files, secrets

| cmd | args | result |
|---|---|---|
| `chat_send` | `query: string, context: ChatContext\|null` | `{text}`; local servers stream `chat-delta` events meanwhile. Provider/model from settings (Claude Code: also `claudeCodeChatMode` = `ask` / `readonly` / `edit` / `auto`, default `ask`; and the working directory, see `chat_work_dir`: one that is gone falls back to Coucou's own, the setting is cleared and a `chat-note` says so). `ChatContext` = `{kind:"file", name, path}` (path must be in the inbox) or `{kind:"window", appName, title, url?}`. |
| `chat_models` | `provider: string` | `[{id, label}]` |
| `chat_work_dir` | `conv?: string` | **(core, new, his ask)** the working directory of conversation `conv` (current by default): `WorkDir = {path, name, isDefault, missing, moved: false}`. Claude Code's turns run there: a reopened Claude Code session's own folder, else the folder the conversation was given (its first Claude Code turn, a reopen, the chip), else the `chatWorkDir` setting, else Coucou's own `~/.local/share/ambxst-robo/chat-claudecode` (`isDefault`, `name` = ""). |
| `chat_set_work_dir` | `path: string, conv?: string` | **(core, new)** `WorkDir`: `path` (absolute, an existing folder, stored as its real path; `""` = back to Coucou's own) becomes the `chatWorkDir` setting (new chats; `settings-changed` follows) and conversation `conv`'s working directory. `moved: true` = the conversation's Claude Code session lives in another folder (Claude Code resumes a session only from its own folder): its next turn starts a new session in the new folder, with the earlier turns as a transcript. A reopened Claude Code session moved out of its folder becomes a Coucou chat. Errors for a relative path or a non-folder. |
| `chat_pick_work_dir` | `conv?: string` | **(core, new)** opens the desktop's folder chooser (xdg-desktop-portal `FileChooser.OpenFile`, `directory: true`; without a portal, `zenity` / `kdialog`), on the folder in use; resolves when it closes: `WorkDir` + `picked` (false = cancelled, nothing changed; true = applied as `chat_set_work_dir`). One chooser at a time. |
| `chat_reset` | – | `null` (forget the conversation) |
| `chat_stop` | – | **(core, new)** stops the running chat turn: Claude Code gets an interrupt (killed after 3 s), other providers' requests are dropped. The turn's `chat_send` then resolves `{text, stopped: true}` (`text` = what Claude Code had said so far, recorded in the conversation; empty for the others). `false` when no turn runs. |
| `chat_inject` | `text` | **(core, new)** a message typed while a turn runs: Claude Code folds it into the running turn (it is recorded with the question). `false` when no turn runs or the provider can't take one mid-answer: the island sends it as the next turn. |
| `chat_current` | – | **(core, new)** the conversation core holds now (it outlives shell reloads): `{turns: [{role, content}], current: {kind, id}\|null}`; a starting island shows these turns again. |
| `chat_history_list` | – | **(core, new)** the tab's chats column: `{items: [{kind: "claude"\|"coucou", id, title, project, provider, model, updated}], current: {kind, id}\|null}`, newest first. `claude` = a Claude Code session from `~/.claude/projects/*/*.jsonl` (every project; title exactly as `claude --resume`'s picker names it; `project` = its folder name; sessions the picker hides are left out). `coucou` = a chat started in Coucou (`~/.local/share/ambxst-robo/chats/<id>.json`, saved after every successful turn; `title` = first message), or `cc:<sessionId>` for an older Coucou Claude Code session no saved chat claims. Files are read again only when their size/mtime changed; nothing under `~/.claude` is written. `current` = the conversation in the chat now. |
| `chat_open` | `kind: string, id: string` | **(core, new)** `{kind, id, turns: [{role, content}], provider, model, title, project}`: the conversation is replaced by that chat (user/assistant text only, last 80 turns). A Claude Code session is continued with `claude -p --resume <id>` **in its own cwd** (hooks off, no MCP, the chat mode's tools / permission mode / stdio cards as usual, no mascot prompt, no --safe-mode) and stays the CLI's session (not saved as a Coucou chat) until another provider answers in it. A Coucou chat gets its turns, provider/model and Claude Code session back, and its working directory (the chat file records `workDir` and, for sessions started outside Coucou's own folder, `cliDirs` = session id → folder: the session is resumed in its folder, and such sessions are listed and trashed with the chat, never as Claude Code sessions of their own). |
| `local_connect` | `provider: "ollama"\|"lmstudio"\|"custom", url: string` | `{url, models, loopback}` |
| `local_set_key` | `url: string, key: string` | `null` (custom server's key, bound to that address) |
| `files_dropped` | `paths: string[]` | `{dirs: string[]}` (the paths that are folders: the chat offers "Use as working directory" for them). **(core, new)** What Tauri's window drag-drop event did: the shell's DropArea must report the paths of a real drop here before calling `ingest_file` (each path is accepted once, for 2 minutes). |
| `ingest_file` | `path: string` | `{name, path, size}` — copied into `~/.local/share/ambxst-robo/inbox` |
| `secret_present` | `key: string` | `bool` (never the value) |
| `secret_set` | `key: string, value: string` | `null`; empty value deletes. `openai-compatible-key` is refused (use `local_set_key`). |
| `secret_clear` | `key: string` | `null` |

Secrets live in the Secret Service under service `ambxst-robo`, account = key (Coucou's
`fr.louisraille.coucou` entries are only read by `--migrate-from-coucou`, which copies
them). Known keys: `anthropic-api-key`, `openai-api-key`,
`google-api-key`, `openrouter-api-key`, `openai-compatible-key`, `n8n-url`, `n8n-api-key`,
`vercel-token`, `github-token`, `stripe-api-key`, `resend-api-key`, `notion-api-key`,
`calcom-api-key`.

### Integrations

| cmd | args | result |
|---|---|---|
| `refresh_integration` | `id: string` (`integration_stripe`, `_github`, `_vercel`, `_n8n`, `_resend`, `_notion`, `_calcom`) | `null` after one poll (result comes as `integration` event) |
| `github_refresh` | `section: "pulse"\|"activity"` | `null`; refetch if stale |

Pollers only call out for integrations listed in `settings.activeIntegrations`, with a
stored key, while not paused (same cadence as Coucou: n8n 15 s, Vercel/Stripe 30 s, Resend
60 s, GitHub/Cal.com/Notion 5 min, GitHub pulse 1–5 min, activity 30 min).

### Spotify (MPRIS)

| cmd | args | result |
|---|---|---|
| `spotify_refresh` | – | `PlayerState\|null` (also emitted) |
| `spotify_control` | `action: "playPause"\|"next"\|"previous"\|"seek"\|"shuffle"\|"repeat"\|"volume", value: number\|null` | `bool` |
| `spotify_open` | – | `bool` |
| `spotify_installed` | – | `bool` |

The listener runs only while `integration_spotify` is in `activeIntegrations`.

### Sounds (playback is the shell's)

| cmd | args | result |
|---|---|---|
| `custom_sounds` | `names: string[]` | the subset that has a user file in `~/.config/ambxst-robo/sounds` |
| `custom_sound` | `name: string` | **(core)** the file's absolute **path** (string) instead of raw bytes |
| `reveal_sounds_folder` | – | `null` (creates and opens the folder) |
| `reload_sounds` | – | `null`; emits `sounds-changed` |

### Weekly recap

| cmd | args | result |
|---|---|---|
| `recap_history` | `since: integer` (Unix seconds) | `{turns, decisions, prefs}` |
| `recap_prefs` | – | `{enabled, hideProjects, lastShownWeek}` |
| `recap_set_enabled` | `enabled: bool` | `null` |
| `recap_set_hide_projects` | `hide: bool` | `null` |
| `recap_mark_shown` | `week: "YYYY-MM-DD"` | `null` |
| `recap_clear` | – | `null` |
| `recap_save_png` | `data: string` (PNG data URL / base64), `week: string` | saved path `string` (Pictures, else Downloads, else home) |
| `recap_save_png_file` | `path: string` (a PNG file, e.g. from `grabToImage().saveToFile()`), `week: string` | saved path `string` **(core, new)** — same checks (PNG signature, size limit); avoids base64 in QML |
| `recap_reveal_saved` | – | `null`; opens the folder of the last saved image |

Rendering the recap image is the shell's job (the Tauri app drew it on a canvas); the daemon
only writes the PNG it is given.

### Desktop the mascot (state only)

| cmd | args | result |
|---|---|---|
| `desktop_mascot_info` | – | `{mode: "layer", onDesktop: bool, spot: {x, y, space} \| null}` (spot = top-left corner, logical px from the top-left of the island's display; only `space:"layer"` spots are returned) |
| `desktop_mascot_remember` | `onDesktop?: bool, spot?: {x, y} \| null` | same as `desktop_mascot_info`. **(core, new)** Absent key = unchanged, `spot: null` forgets the spot. Saved in settings.json `desktopMascot` like Coucou. |

### Shortcuts (configuration only)

| cmd | args | result |
|---|---|---|
| `shortcuts_status` | – | `{actions: [{id, status, keys}], blocked: "shell", command, portal: null}` **(core)** `status` is `off` (disabled / no key), `notPorted` (`attachFrontWindow`) or `unsupported` (enabled — the shell binds it); `keys` = stored or default accelerator. `command` = `<path>/ambxst-robo --shortcut`. |
| `shortcuts_suspend` | `suspended: bool` | `null` (no-op: nothing is registered) |
| `shortcut_dispatch` | `action: string` | `null`; emits `shortcut` (or `open-wardrobe` for `wardrobeToggle`) like a key press did. **(core, new)** Also: `ambxst-robo --shortcut <id>` from a compositor bind. |

Action ids: `toggleIsland` (default off), `openChat`, `goToAlert`, `jumpToTerminal`,
`attachFrontWindow` (not ported), `nextPill`, `prevPill`, `muteToggle`, `desktopToggle`,
`wardrobeToggle`.

### Client to client

| cmd | args | result |
|---|---|---|
| `emit` | `event: string, payload?: any, target?: string\|null` | `null`; broadcasts the event to every client (the webviews' `emitTo`). **(core, new)** |

## Events

| event | target | payload |
|---|---|---|
| `hook` | island | the hook JSON from ambxst-robo-hook (Claude Code field names: `hook_event_name`, `session_id`, `cwd`, `tool_name`, `tool_input`, `prompt`, `coucou_agent`, `term_*`, `session_pid`, …). `PermissionRequest` adds `request_id`. `StatusLine` carries the plan usage. |
| `recap-check` | island | `null` — on `SessionStart` / `UserPromptSubmit`: the Monday recap may show |
| `settings-changed` | null | the full Settings object |
| `integration` | island | `{id, data: {...}, error: string\|null, event: {success, label, detail\|null}\|null}` |
| `github-alerts` | island | `[{kind:"ciFailed"\|"ciPassed"\|"reviewRequested", prId} \| {kind:"mainFailed", repo}]` |
| `chat-delta` | island | `string` — the visible streamed text so far (local model servers) |
| `chat-note` | island | **(core, his ask)** `{conv, text}` — a line for that conversation's log, not a turn (its working directory is gone) |
| `chat-permission` | island | **(core)** a chat run's permission request or AskUserQuestion: `{request_id, tool_name, tool_input, description, session_id, cwd}` (see Permission requests) |
| `chat-permission-gone` | island | **(core)** `{request_id}` — that chat request is no longer waiting |
| `spotify` | island | `PlayerState {running, installed, track: {id, title, artist, album, duration, artUrl}\|null, playing, position, positionAt, shuffle, repeat, volume}` |
| `spotify-artwork` | island | `{artUrl, dataUrl}` |
| `sounds-changed` | null | `null` |
| `shortcut` | island | action id `string` |
| `open-wardrobe` | island | `null` |

Events the Tauri app emitted that no longer exist (window things): `cursor`,
`pointer-inside`, `screen-changed`, `tray`, `file-drag`, `desktop-visible`,
`desktop-flight`, `desktop-cursor`, `desktop-mascot-dropped`, `shortcuts-status`, and every
`phone-link-*` event.

## Dropped (and why)

Calling one of these gives `ok:false` with a `dropped in ambxst-robo: …` message.

| Tauri command(s) | why |
|---|---|
| `set_collapsed`, `set_island_rect`, `focus_window`, `reposition`, `list_monitors` (island.rs) | the shell owns the island surface, input region, focus and monitor choice |
| `open_settings_window` | the shell owns the settings window |
| `desktop_mascot_pick_up/carry/carry_end/drag_begin/drag_move/drag_end/fly_out/fly_home/set_asleep` (desktop.rs) | the desktop mascot is a QML layer window; flights and drags are animated there. Only the saved state survives (`desktop_mascot_info` / `desktop_mascot_remember`). |
| every `phone_*` / `phone_link_*` command (phone_link/) | Android phone link not wanted. Its settings fields are preserved untouched in settings.json. |
| tray.rs (tray menu → `tray` event) | the shell has its own UI; Pause = `set_paused`, Quit = `quit_app` |
| global key grabs / XDG GlobalShortcuts portal (shortcuts.rs, portal.rs) | the shell binds keys; `shortcuts_status` reports the configuration |
| webview_drop.rs, Tauri drag-drop window event | the shell's DropArea → `files_dropped` |
| autostart plugin | systemd user unit (`ambxst-robo.service`) |
| single-instance plugin's "second launch opens the island" | a second `ambxst-robo` exits 1; use `shortcut_dispatch` / `--shortcut` |

## Not changed (but renamed)

- `$XDG_RUNTIME_DIR/ambxst-robo.sock` (hook relay; Coucou's is `coucou.sock`), wire format
  and timeouts as Coucou's (the `coucou_*` payload fields keep their names). Hooks point at
  `~/.local/share/ambxst-robo/bin/ambxst-robo-hook`.
  The daemon installs that relay only if it is missing (never replaces it), unless
  `AMBXST_ROBO_INSTALL_RELAY=1` (then it updates it from a `ambxst-robo-hook` next to the
  `ambxst-robo` binary, like Coucou at launch).
- Files: `~/.config/ambxst-robo/settings.json`, `~/.config/ambxst-robo/sounds/`,
  `~/.local/share/ambxst-robo/{ambxst-robo.log, recap.json, inbox/, chats/, chat-claudecode/}`
  — Robo's own, not shared with Coucou (`~/.config/coucou`, `~/.local/share/coucou`), so the
  two can run at once.
- `ambxst-robo --migrate-from-coucou [--dry-run] [--keep-coucou-hooks | --replace-coucou-hooks]`
  copies (never moves or deletes) Coucou's config, data, saved chats and their Claude Code
  sessions, Secret Service keys and the Claude Code / Codex hook entries that run
  `~/.local/share/coucou/bin/coucou-hook` over to Robo's names. With the Coucou app
  installed, Robo's hook entries are added beside Coucou's instead of replacing them.
  Idempotent: run it again and only what is missing is done.
