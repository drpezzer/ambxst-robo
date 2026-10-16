// ambxst-robo — Ambxst Robo's daemon: Coucou's backend (windows/src-tauri) with Tauri removed.
//
// The commands keep their Tauri names and their camelCase argument keys, so the
// QML side mirrors src/core/bridge.ts one for one. They are served on
// `$XDG_RUNTIME_DIR/ambxst-robo-core.sock` (server.rs); every event the Tauri app
// emitted is broadcast to the connected clients (host.rs). The hook relay
// socket is `$XDG_RUNTIME_DIR/ambxst-robo.sock` (pipe.rs), not Coucou's coucou.sock.
//
// What the Tauri app did with windows (island geometry, click-through, the
// settings window, the desktop mascot window, the tray, global key grabs) and the
// Android phone link are gone: the Ambxst shell owns all of that. See
// PROTOCOL.md for the full contract and the list of what was dropped.

mod agent_hooks;
mod agents;
mod chat;
mod claude;
mod claude_code;
mod codex_plan;
mod config_file;
mod desktop;
mod files;
mod folder_picker;
mod github;
mod history;
pub mod host;
mod hooks;
mod i18n;
mod identity;
mod integrations;
mod local_chat;
mod log;
pub mod migrate;
mod net;
mod openai_compat;
mod pipe;
mod platform;
mod recap;
mod secrets;
pub mod server;
mod session_window;
mod session_reply;
pub(crate) mod remote;
mod settings;
mod shortcuts;
mod sounds;
mod spotify;

use std::collections::HashMap;
use std::process::Command;
use std::sync::Mutex;

use serde::de::DeserializeOwned;
use serde::Serialize;
use serde_json::{json, Value};

use chat::{Chat, ChatContext, Chats};
use host::AppHandle;
use pipe::Pending;
use settings::Settings;

pub use shortcuts::from_args as shortcut_from_args;

pub struct Shared {
    pub settings: Mutex<Settings>,
}

/// The Tauri app's `ScreenInfo`. The shell owns the screen, so this is a
/// placeholder kept only for the shape of `boot`'s answer.
#[derive(Serialize)]
struct ScreenPlaceholder {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
    scale: f64,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct BootInfo {
    settings: Settings,
    screen: ScreenPlaceholder,
    version: String,
    hook_path: String,
    cursor_poll: bool,
    /// ambxst-robo: whether this daemon serves the hook relay socket. False
    /// while another Ambxst Robo holds the socket, or on error.
    relay_socket: bool,
}

fn boot(shared: &Shared) -> BootInfo {
    let mut settings = shared.settings.lock().unwrap().clone();
    // The real state of ~/.claude/settings.json wins over whatever we stored.
    let hooks_status = hooks::status();
    settings.hooks_installed = hooks_status.installed;
    settings.plan_relay_installed = hooks_status.plan_relay_installed;
    BootInfo {
        settings,
        screen: ScreenPlaceholder { x: 0.0, y: 0.0, width: 0.0, height: 0.0, scale: 1.0 },
        version: env!("CARGO_PKG_VERSION").to_string(),
        hook_path: settings::hook_exe_path().to_string_lossy().to_string(),
        cursor_poll: false,
        relay_socket: pipe::SERVING.load(std::sync::atomic::Ordering::Relaxed),
    }
}

fn save_settings(app: &AppHandle, shared: &Shared, settings: Settings) {
    {
        let mut current = shared.settings.lock().unwrap();
        let mut settings = settings;
        // Where the mascot sits on the desktop is desktop_mascot_remember's to say.
        settings.desktop_mascot = current.desktop_mascot.clone();
        // The phone link is gone from ambxst-robo: its stored switches are kept
        // as they are, so the Tauri Coucou finds them unchanged.
        settings.phone_link = current.phone_link;
        settings.phone_chat = current.phone_chat;
        settings.phone_details = current.phone_details;
        settings.phone_answers = current.phone_answers;
        settings.phone_diffs = current.phone_diffs;
        settings.phone_usage = current.phone_usage;
        settings.phone_services = current.phone_services.clone();
        settings.phone_relay = current.phone_relay;
        settings.phone_relay_url = current.phone_relay_url.clone();
        settings.phone_chat_models = current.phone_chat_models.clone();
        // Port (his ask): the chat's working folder is chat_set_work_dir's to say.
        settings.chat_work_dir = current.chat_work_dir.clone();
        *current = settings;
    }
    let settings = shared.settings.lock().unwrap().clone();
    if let Err(err) = settings::save(&settings) {
        log::line(format!("could not save settings: {err}"));
    }
    // `screen` and `autostart` are stored but not acted on: the shell owns the
    // screen, and the systemd user unit is what starts the daemon.
    integrations::settings_saved(app, &settings.active_integrations);
    spotify::sync(app, &settings.active_integrations);
    i18n::set_picked(&settings.language);
    let _ = app.emit("settings-changed", settings);
}

fn open_url(url: String) {
    if !(url.starts_with("http://") || url.starts_with("https://")) {
        return;
    }
    platform::open_url(&url);
}

/// "Open terminal" opens the working folder in VS Code when `code` is on PATH,
/// and falls back to the file manager otherwise.
fn open_in_vscode(path: Option<String>) -> bool {
    // No shell anywhere near this: the path is handed over as an argument.
    let path = path.filter(|p| !p.is_empty());
    // Only an existing folder, given by its full path, goes any further.
    if let Some(p) = path.as_deref() {
        let p = std::path::Path::new(p);
        if !(p.is_absolute() && p.is_dir()) {
            return false;
        }
    }
    if let Some(code) = platform::find_on_path("code") {
        let mut cmd = Command::new(code);
        if let Some(p) = path.as_deref() {
            cmd.arg(p);
        }
        if platform::spawn_reaped(platform::no_console(&mut cmd)) {
            return true;
        }
    }
    if let Some(p) = path.as_deref() {
        platform::reveal_folder(p);
    }
    false
}

/// "Open terminal": brings forward the terminal or editor window the session
/// runs in, when it was found (session_window.rs, linux_focus.rs); otherwise
/// opens the folder in VS Code. Off the request path: it can take a moment.
///
/// Port: the relay's snapshot is only kept in memory, so a session is also
/// found from Claude Code's own record after a ambxst-robo restart; a session
/// Coucou's chat runs, or no process runs any more, is resumed in a new kitty
/// in its folder (the island's home chat when kitty is missing).
fn open_session(app: &AppHandle, session_id: Option<String>, path: Option<String>) -> bool {
    let sid = session_id.filter(|s| session_window::valid_session(s));
    // His call: a session Coucou's chat runs opens in a terminal too (the
    // same session continued there), not just the island's home chat.
    if let Some(id) = sid.as_deref() {
        if app.state::<Chats>().holds_session(id) {
            let id = id.to_string();
            let app = app.clone();
            std::thread::spawn(move || {
                if !resume_in_terminal(&id, path.as_deref()) {
                    let _ = app.emit("show-chat", ());
                }
            });
            return true;
        }
    }
    let app = app.clone();
    std::thread::spawn(move || {
        let folder = path.as_deref().map(session_window::folder_name).unwrap_or_default().to_string();
        if let Some(owners) = sid.as_deref().and_then(session_window::lookup) {
            if platform::focus_session_window(&owners, &folder) {
                return;
            }
        }
        let Some(id) = sid else {
            open_in_vscode(path);
            return;
        };
        match platform::claude_session_process(&id) {
            Some(pid) if platform::is_our_descendant(pid) => {
                if !resume_in_terminal(&id, path.as_deref()) {
                    let _ = app.emit("show-chat", ());
                }
            }
            Some(pid) => {
                let owners = platform::process_ancestors(pid);
                if !platform::focus_session_window(&owners, &folder) {
                    open_in_vscode(path);
                }
            }
            None => {
                if !resume_in_terminal(&id, path.as_deref()) {
                    open_in_vscode(path);
                }
            }
        }
    });
    true
}

/// Port: a session no process runs any more, continued in a new kitty window
/// in its folder (`claude --resume <id>`). Arguments one by one, no shell; the
/// id passed valid_session, the folder must exist.
fn resume_in_terminal(id: &str, path: Option<&str>) -> bool {
    let ok = claude_in_kitty(&["--resume", id], path);
    if ok {
        crate::log::line("open terminal: resumed the session in a new kitty");
    }
    ok
}

/// Port: `claude <args>` in a new kitty window, in `path` (home when it is
/// not an existing absolute folder). Arguments one by one, no shell.
fn claude_in_kitty(args: &[&str], path: Option<&str>) -> bool {
    let (Some(kitty), Some(claude)) = (platform::find_on_path("kitty"), platform::find_on_path("claude")) else {
        return false;
    };
    let dir = path
        .map(std::path::Path::new)
        .filter(|p| p.is_absolute() && p.is_dir())
        .map(|p| p.to_path_buf())
        .or_else(|| std::env::var_os("HOME").map(std::path::PathBuf::from));
    let mut cmd = Command::new(kitty);
    if let Some(d) = dir.as_ref() {
        cmd.arg("--directory").arg(d).current_dir(d);
    }
    cmd.arg(claude).args(args);
    platform::spawn_reaped(platform::no_console(&mut cmd))
}

/// The file behind a live diff, if it may be handed to the editor: an existing
/// regular file given by its full path.
fn diff_file(path: &str) -> Option<&std::path::Path> {
    let p = std::path::Path::new(path);
    (p.is_absolute() && p.is_file()).then_some(p)
}

/// The diff card's ↗: the edited file in VS Code, otherwise its folder. Never
/// opened by its type.
fn open_file_in_vscode(path: String) -> bool {
    let Some(file) = diff_file(&path) else { return false };
    if let Some(code) = platform::find_on_path("code") {
        let mut cmd = Command::new(code);
        cmd.arg(file);
        if platform::spawn_reaped(platform::no_console(&mut cmd)) {
            return true;
        }
    }
    if let Some(folder) = file.parent().filter(|d| d.is_dir()) {
        platform::reveal_folder(&folder.to_string_lossy());
    }
    false
}

fn hooks_apply(app: &AppHandle, shared: &Shared, install: bool, fingerprint: String) -> Result<String, String> {
    // The fingerprint comes from the preview the user looked at, so a
    // settings.json that changed in between is refused rather than overwritten.
    let backup = hooks::write(install, &fingerprint)?;
    let updated = {
        let mut current = shared.settings.lock().unwrap();
        current.hooks_installed = install;
        if let Err(err) = settings::save(&current) {
            log::line(format!("could not save settings: {err}"));
        }
        current.clone()
    };
    let _ = app.emit("settings-changed", updated);
    Ok(backup)
}

fn agent_hooks_apply(agent: String, install: bool, fingerprint: String) -> Result<String, String> {
    let backups = agents::apply(&agent, install, &fingerprint)?;
    let done = if install { "installed" } else { "removed" };
    log::line(format!("agent hooks {done} for {agent}"));
    Ok(backups)
}

fn status_line_apply(app: &AppHandle, shared: &Shared, install: bool, fingerprint: String) -> Result<String, String> {
    let backup = hooks::status_line_write(install, &fingerprint)?;
    let updated = {
        let mut current = shared.settings.lock().unwrap();
        current.plan_relay_installed = install;
        // As on the Mac: taking the relay out turns the pill off with it.
        if !install {
            current.show_plan_in_notch = false;
        }
        if let Err(err) = settings::save(&current) {
            log::line(format!("could not save settings: {err}"));
        }
        current.clone()
    };
    let _ = app.emit("settings-changed", updated);
    Ok(backup)
}

fn secret_set(app: &AppHandle, key: String, value: String) -> Result<(), String> {
    // Bound to its server's address: only local_set_key may store it.
    if key == local_chat::CUSTOM_KEY {
        return Err("use local_set_key".into());
    }
    let before = (key == "github-token").then(|| secrets::get(&key));
    secrets::set(&key, &value)?;
    if let Some(before) = before {
        if secrets::get(&key) != before {
            integrations::github_token_changed(app);
        }
    }
    Ok(())
}

fn secret_clear(app: &AppHandle, key: String) -> Result<(), String> {
    let had = key == "github-token" && secrets::present(&key);
    secrets::clear(&key)?;
    if had {
        integrations::github_token_changed(app);
    }
    Ok(())
}

// ── Dispatch ──────────────────────────────────────────────────────────────────

/// One argument, by the camelCase key the TS sends. A missing key reads as
/// null, so an `Option` parameter is `None`, as with Tauri.
fn arg<T: DeserializeOwned>(args: &Value, key: &str) -> Result<T, String> {
    let v = args.get(key).cloned().unwrap_or(Value::Null);
    serde_json::from_value(v).map_err(|e| format!("invalid args for key {key}: {e}"))
}

fn ok<T: Serialize>(value: T) -> Result<Value, String> {
    serde_json::to_value(value).map_err(|e| e.to_string())
}

/// What a dropped command answers: the Tauri name still resolves, so a mirror
/// of bridge.ts gets a clear error instead of "unknown command".
fn dropped(cmd: &str) -> Option<&'static str> {
    Some(match cmd {
        "set_collapsed" | "set_island_rect" | "focus_window" | "reposition" | "list_monitors" => {
            "dropped in ambxst-robo: the shell owns the island window"
        }
        "open_settings_window" => "dropped in ambxst-robo: the shell owns the settings window",
        "desktop_mascot_pick_up" | "desktop_mascot_carry" | "desktop_mascot_carry_end" | "desktop_mascot_drag_begin"
        | "desktop_mascot_drag_move" | "desktop_mascot_drag_end" | "desktop_mascot_fly_out" | "desktop_mascot_fly_home"
        | "desktop_mascot_set_asleep" => {
            "dropped in ambxst-robo: the shell owns the desktop mascot window (use desktop_mascot_remember)"
        }
        c if c.starts_with("phone_") => "dropped in ambxst-robo: no phone link",
        _ => return None,
    })
}

/// Runs one command. `client` is the id of the connection that sent it.
pub async fn dispatch(app: AppHandle, client: u64, cmd: String, args: Value) -> Result<Value, String> {
    let shared = app.state::<Shared>();
    match cmd.as_str() {
        // ── Async in Tauri: never block the others ───────────────────────────
        // Port (his ask): Claude Code's Remote Control for a chat (remote.rs).
        "remote_start" => {
            let conv: String = arg(&args, "conv")?;
            ok(remote::start(&app, &conv).await?)
        }
        "remote_send" => {
            let conv: String = arg(&args, "conv")?;
            let text: String = arg(&args, "text")?;
            if text.chars().count() > 20_000 {
                return Err("That message is too long.".into());
            }
            remote::send(&conv, &text).await?;
            ok(true)
        }
        "chat_send" => {
            let query: String = arg(&args, "query")?;
            let context: Option<ChatContext> = arg(&args, "context")?;
            // Port: the conversation it goes to (`conv`), the current one by
            // default; it keeps answering there if another becomes current.
            let conv: Option<String> = arg(&args, "conv")?;
            // Port (his ask): a working folder that is gone stops being the
            // setting (the conversation that had it says so, claude_code.rs).
            let chat = app.state::<Chats>().get(conv.as_deref())?;
            let gone = {
                let s = shared.settings.lock().unwrap();
                Some(s.chat_work_dir.clone()).filter(|d| !d.is_empty() && claude_code::setting_dir(d).is_none())
            };
            if let Some(gone) = gone {
                log::line("chat: the working directory is gone, back to Robo's own folder");
                // A conversation that was following the setting keeps it for
                // this turn, so its Claude Code turn falls back with the note.
                if chat.work_dir().is_none() {
                    let _ = chat.set_work_dir(std::path::Path::new(&gone));
                }
                set_work_dir_setting(&app, &shared, String::new());
            }
            let settings = shared.settings.lock().unwrap().clone();
            app.state::<Chats>().talked(chat.id());
            let reply = chat::send(&app, &chat, &settings, query, context).await;
            app.state::<Chats>().remember_current();
            ok(reply?)
        }
        // Port: the running turn's stop button, and a message typed while it
        // works (true = folded into the turn; false = send it afterwards).
        "chat_stop" => {
            let conv = conv_or_current(&app, &args)?;
            ok(chat::control(&conv, chat::TurnControl::Stop))
        }
        "chat_inject" => {
            let conv = conv_or_current(&app, &args)?;
            let text: String = arg(&args, "text")?;
            let text = text.trim().to_string();
            if text.is_empty() || text.chars().count() > 20_000 {
                return ok(false);
            }
            ok(chat::control(&conv, chat::TurnControl::Inject(text)))
        }
        // Port (his ask): the chat's working folder (its folder chip).
        "chat_work_dir" => {
            let conv: Option<String> = arg(&args, "conv")?;
            let chat = app.state::<Chats>().get(conv.as_deref())?;
            let setting = shared.settings.lock().unwrap().chat_work_dir.clone();
            ok(work_dir_info(&chat, &setting))
        }
        "chat_set_work_dir" => {
            let conv: Option<String> = arg(&args, "conv")?;
            let path: String = arg(&args, "path")?;
            let chat = app.state::<Chats>().get(conv.as_deref())?;
            ok(apply_work_dir(&app, &shared, &chat, &path)?)
        }
        "chat_pick_work_dir" => {
            let conv: Option<String> = arg(&args, "conv")?;
            let chat = app.state::<Chats>().get(conv.as_deref())?;
            let setting = shared.settings.lock().unwrap().chat_work_dir.clone();
            // The chooser opens on the folder in use (home for Coucou's own).
            let start = chat
                .work_dir()
                .or_else(|| claude_code::setting_dir(&setting))
                .filter(|d| d.is_dir() && *d != claude_code::default_dir());
            let title = i18n::t("Working directory");
            let picked = host::async_runtime::spawn_blocking(move || folder_picker::pick(&title, start.as_deref()))
                .await
                .map_err(|e| e.to_string())??;
            let was_picked = picked.is_some();
            let mut info = match picked {
                Some(dir) => apply_work_dir(&app, &shared, &chat, &dir.display().to_string())?,
                None => {
                    let setting = shared.settings.lock().unwrap().chat_work_dir.clone();
                    work_dir_info(&chat, &setting)
                }
            };
            info["picked"] = json!(was_picked);
            ok(info)
        }
        "chat_models" => {
            let provider: String = arg(&args, "provider")?;
            let settings = shared.settings.lock().unwrap().clone();
            ok(chat::models(&settings, &provider).await?)
        }
        "local_connect" => {
            let provider: String = arg(&args, "provider")?;
            let url: String = arg(&args, "url")?;
            ok(local_chat::connect(&provider, &url).await?)
        }
        "codex_plan_usage" => {
            ok(host::async_runtime::spawn_blocking(codex_plan::read).await.ok().flatten())
        }
        "refresh_integration" => {
            let id: String = arg(&args, "id")?;
            integrations::poll_once(app.clone(), &id).await;
            ok(())
        }
        "spotify_refresh" => ok(spotify::spotify_refresh(app.clone()).await),
        "spotify_control" => {
            let action: String = arg(&args, "action")?;
            let value: Option<f64> = arg(&args, "value")?;
            ok(spotify::spotify_control(app.clone(), action, value).await)
        }
        "spotify_open" => ok(spotify::spotify_open().await),
        // ── Everything else is quick but may touch D-Bus or the disk ─────────
        _ => {
            let app = app.clone();
            host::async_runtime::spawn_blocking(move || dispatch_sync(&app, client, &cmd, &args))
                .await
                .map_err(|e| format!("command failed: {e}"))?
        }
    }
}

fn dispatch_sync(app: &AppHandle, client: u64, cmd: &str, args: &Value) -> Result<Value, String> {
    let shared = app.state::<Shared>();
    let shared = &*shared;
    match cmd {
        "ping" => ok("pong"),
        // ambxst-robo: the mod checks that the daemon running is its own version.
        "version" => ok(serde_json::json!({ "version": env!("CARGO_PKG_VERSION"), "protocol": 1 })),
        "boot" => ok(boot(shared)),
        "save_settings" => {
            save_settings(app, shared, arg(args, "settings")?);
            ok(())
        }
        "set_system_languages" => {
            i18n::set_system(arg(args, "languages")?);
            ok(())
        }
        "open_url" => {
            open_url(arg(args, "url")?);
            ok(())
        }
        "open_in_vscode" => ok(open_in_vscode(arg(args, "path")?)),
        // Port: the Claude Code card's link (this is no VS Code setup): a new
        // Claude Code in kitty, in the card's folder.
        "open_claude_code" => {
            let path: Option<String> = arg(args, "path")?;
            ok(claude_in_kitty(&[], path.as_deref()) || open_in_vscode(path))
        }
        "open_session" => ok(open_session(&app, arg(args, "sessionId")?, arg(args, "path")?)),
        // Port (his ask): the finished popup reads the session's whole last
        // answer and replies into its terminal (session_reply.rs).
        "session_last_reply" => {
            let id: String = arg(args, "sessionId")?;
            ok(session_reply::last_reply(&id))
        }
        "remote_stop" => {
            let conv: String = arg(args, "conv")?;
            let was = remote::stop(&conv);
            if was {
                let _ = app.emit_to(crate::host::WINDOW_LABEL, "remote-changed", serde_json::json!({ "conv": conv, "on": false }));
            }
            ok(was)
        }
        "remote_list" => ok(remote::list()),
        "remote_qr" => {
            let text: String = arg(args, "text")?;
            ok(remote::qr(&text)?)
        }
        "session_reply" => {
            let id: String = arg(args, "sessionId")?;
            let text: String = arg(args, "text")?;
            if text.chars().count() > 20_000 {
                return Err("That reply is too long.".into());
            }
            session_reply::send_to_terminal(&id, &text)?;
            ok(true)
        }
        "open_claude_desktop" => ok(platform::open_claude_desktop()),
        "open_file_in_vscode" => ok(open_file_in_vscode(arg(args, "path")?)),
        "quit_app" => {
            log::line("quit_app: ambxst-robo exits");
            remote::stop_all();
            server::shutdown();
            ok(())
        }
        "set_paused" => {
            integrations::set_paused(arg(args, "paused")?);
            ok(())
        }
        "log_line" => {
            let message: String = arg(args, "message")?;
            log::line(format!("ui  {message}"));
            ok(())
        }

        // ── Claude Code hooks, other agents, plan usage ───────────────────────
        "hooks_status" => ok(hooks::status()),
        "agent_hooks_status" => ok(agent_hooks::status()),
        "hooks_preview" => ok(hooks::preview(arg(args, "install")?)?),
        "hooks_apply" => ok(hooks_apply(app, shared, arg(args, "install")?, arg(args, "fingerprint")?)?),
        "agent_hooks_list" => ok(agents::list()),
        "agent_hooks_preview" => {
            let agent: String = arg(args, "agent")?;
            ok(agents::preview(&agent, arg(args, "install")?)?)
        }
        "agent_hooks_apply" => {
            ok(agent_hooks_apply(arg(args, "agent")?, arg(args, "install")?, arg(args, "fingerprint")?)?)
        }
        "status_line_preview" => ok(hooks::status_line_preview(arg(args, "install")?)?),
        "status_line_apply" => {
            ok(status_line_apply(app, shared, arg(args, "install")?, arg(args, "fingerprint")?)?)
        }

        // ── Approvals and questions ───────────────────────────────────────────
        "approval_decision" => {
            let request_id: String = arg(args, "requestId")?;
            let decision: String = arg(args, "decision")?;
            // The chat's own requests (pipe::ask_island) are not a session's.
            if !pipe::is_chat_request(&request_id) {
                recap::record_decision(app, &request_id, &decision);
            }
            pipe::answer(app, &request_id, &decision);
            ok(())
        }
        "approval_answer" => {
            let request_id: String = arg(args, "requestId")?;
            let answers: HashMap<String, Value> = arg(args, "answers")?;
            // An answered question is not an Allow / Deny: nothing for the recap.
            recap::forget_request(app, &request_id);
            pipe::answer_question(app, &request_id, &answers);
            ok(())
        }
        "approval_ack" => {
            let request_id: String = arg(args, "requestId")?;
            pipe::acknowledge(app, &request_id, client);
            ok(())
        }
        "approval_decline" => {
            let request_id: String = arg(args, "requestId")?;
            recap::forget_request(app, &request_id);
            pipe::decline(app, &request_id);
            ok(())
        }

        // ── Chat, files, secrets ──────────────────────────────────────────────
        "local_set_key" => {
            let url: String = arg(args, "url")?;
            let key: String = arg(args, "key")?;
            ok(local_chat::set_custom_key(&url, &key)?)
        }
        // Port: "New chat" starts another conversation; the one left keeps
        // running (and its mini) if it was talked in. Returns the new one's id.
        "chat_reset" => {
            let chats = app.state::<Chats>();
            let conv = chats.new_conversation();
            chats.remember_current();
            ok(json!({ "conv": conv }))
        }
        // Port: a conversation's mini was clicked: it becomes current.
        "chat_switch" => {
            let conv: String = arg(args, "conv")?;
            let chats = app.state::<Chats>();
            if !chats.switch(&conv) {
                return Err("That conversation is closed.".into());
            }
            chats.remember_current();
            ok(describe(&chats.current()))
        }
        // Port: a mini dragged onto its card: its turn stops, it closes.
        "chat_retire" => {
            let conv: String = arg(args, "conv")?;
            let chats = app.state::<Chats>();
            let current = chats.retire(&conv);
            chats.remember_current();
            ok(json!({ "current": current }))
        }
        // Port: a message went into a conversation's session another way (typed
        // into its terminal, session_reply.rs): it is talked in, its mini shows.
        "chat_talked" => {
            let conv: String = arg(args, "conv")?;
            app.state::<Chats>().talked(&conv);
            ok(json!({ "convs": app.state::<Chats>().list() }))
        }
        // Port: the open conversations (their minis).
        "chat_conversations" => ok(json!({ "convs": app.state::<Chats>().list(), "current": app.state::<Chats>().current().id() })),
        // Port: the conversation core still holds (it outlives shell reloads),
        // for a freshly started island to show again.
        "chat_current" => {
            let chats = app.state::<Chats>();
            let mut out = describe(&chats.current());
            out["convs"] = json!(chats.list());
            ok(out)
        }
        // Port: a chat removed from the column (moved to Coucou's trash). The
        // conversation open in the chat, if it was this one, starts afresh.
        "chat_delete" => {
            let kind: String = arg(args, "kind")?;
            let id: String = arg(args, "id")?;
            history::trash(&kind, &id)?;
            // Port: the open conversation holding it closes (its mini goes).
            let chats = app.state::<Chats>();
            let holder = chats.holding(&kind, &id);
            let was_open = holder.as_deref() == Some(chats.current().id());
            if let Some(conv) = &holder {
                chats.retire(conv);
                chats.remember_current();
            }
            ok(json!({ "wasOpen": was_open, "conv": holder, "current": chats.current().id() }))
        }
        // Port: the tab's chats column (history.rs).
        "chat_history_list" => {
            let items = history::list();
            let current = app.state::<Chats>().current().current_key().map(|(kind, id)| json!({ "kind": kind, "id": id }));
            ok(json!({ "items": items, "current": current }))
        }
        "chat_open" => {
            let kind: String = arg(args, "kind")?;
            let id: String = arg(args, "id")?;
            let opened = history::open(&kind, &id)?;
            let chats = app.state::<Chats>();
            let chat = chats.open(&kind, &id, &opened);
            chats.remember_current();
            ok(json!({
                "conv": chat.id(),
                "pending": chat.pending(),
                "kind": kind,
                "id": id,
                "turns": chat.plain_turns(),
                "provider": opened.provider,
                "model": opened.model,
                "title": opened.title,
                "project": opened.external.as_ref().map(|e| e.project.clone()),
            }))
        }
        "files_dropped" => {
            // ambxst-robo: what Tauri's drag-drop window event did — the shell's
            // DropArea reports the paths of a real drop before ingest_file.
            let paths: Vec<String> = arg(args, "paths")?;
            // Port (his ask): which of them are folders (one may become the
            // chat's working directory instead of being copied in).
            let dirs: Vec<String> =
                paths.iter().filter(|p| std::path::Path::new(p.as_str()).is_absolute() && std::path::Path::new(p.as_str()).is_dir()).cloned().collect();
            files::allow_dropped(paths);
            ok(json!({ "dirs": dirs }))
        }
        "ingest_file" => {
            let path: String = arg(args, "path")?;
            ok(files::ingest(&path)?)
        }
        "secret_present" => {
            let key: String = arg(args, "key")?;
            ok(secrets::present(&key))
        }
        "secret_set" => ok(secret_set(app, arg(args, "key")?, arg(args, "value")?)?),
        "secret_clear" => ok(secret_clear(app, arg(args, "key")?)?),

        // ── Integrations ──────────────────────────────────────────────────────
        "github_refresh" => {
            let section: String = arg(args, "section")?;
            integrations::github_refresh_if_stale(&section);
            ok(())
        }
        "open_n8n" => {
            if let Some(url) = secrets::get("n8n-url") {
                open_url(url);
            }
            ok(())
        }

        // ── Shortcuts (configuration only; the shell binds the keys) ──────────
        "shortcuts_status" => {
            let stored = shared.settings.lock().unwrap().shortcuts.clone();
            ok(shortcuts::status(&stored))
        }
        "shortcuts_suspend" => ok(()),
        "shortcut_dispatch" => {
            let action: String = arg(args, "action")?;
            let def = shortcuts::find(&action).filter(|d| d.ported).ok_or_else(|| format!("unknown shortcut {action}"))?;
            shortcuts::dispatch(app, def.id);
            ok(())
        }

        // ── Weekly recap ──────────────────────────────────────────────────────
        "recap_history" => ok(recap::recap_history(&app.state::<recap::Store>(), arg(args, "since")?)),
        "recap_prefs" => ok(recap::recap_prefs(&app.state::<recap::Store>())),
        "recap_set_enabled" => {
            recap::recap_set_enabled(&app.state::<recap::Store>(), arg(args, "enabled")?);
            ok(())
        }
        "recap_set_hide_projects" => {
            recap::recap_set_hide_projects(&app.state::<recap::Store>(), arg(args, "hide")?);
            ok(())
        }
        "recap_mark_shown" => {
            recap::recap_mark_shown(&app.state::<recap::Store>(), arg(args, "week")?);
            ok(())
        }
        "recap_clear" => {
            recap::recap_clear(&app.state::<recap::Store>());
            ok(())
        }
        "recap_save_png" => {
            ok(recap::recap_save_png(&app.state::<recap::Store>(), arg(args, "data")?, arg(args, "week")?)?)
        }
        "recap_save_png_file" => {
            ok(recap::recap_save_png_file(&app.state::<recap::Store>(), arg(args, "path")?, arg(args, "week")?)?)
        }
        "recap_reveal_saved" => {
            recap::recap_reveal_saved(&app.state::<recap::Store>());
            ok(())
        }

        // ── Desktop the mascot: state only ─────────────────────────────────────────
        "desktop_mascot_info" => ok(desktop::desktop_mascot_info(shared)),
        "desktop_mascot_remember" => {
            let on_desktop: Option<bool> = arg(args, "onDesktop")?;
            let spot = args.get("spot").cloned();
            ok(desktop::desktop_mascot_remember(shared, on_desktop, spot)?)
        }

        // ── Sounds (playback is the shell's) ──────────────────────────────────
        "custom_sounds" => ok(sounds::custom_sounds(arg(args, "names")?)),
        "custom_sound" => ok(sounds::custom_sound(arg(args, "name")?)?),
        "reveal_sounds_folder" => {
            sounds::reveal_sounds_folder();
            ok(())
        }
        "reload_sounds" => {
            sounds::reload_sounds(app.clone());
            ok(())
        }

        "spotify_installed" => ok(spotify::spotify_installed()),

        // ── Client to client (the webviews' emitTo) ───────────────────────────
        "emit" => {
            let event: String = arg(args, "event")?;
            let target: Option<String> = arg(args, "target")?;
            let payload = args.get("payload").cloned().unwrap_or(Value::Null);
            match target {
                Some(t) => app.emit_to(&t, &event, payload)?,
                None => app.emit(&event, payload)?,
            }
            ok(())
        }

        other => Err(match dropped(other) {
            Some(why) => why.to_string(),
            None => format!("unknown command {other}"),
        }),
    }
}

/// Port: `conv` from the island, or the current conversation's id.
fn conv_or_current(app: &AppHandle, args: &Value) -> Result<String, String> {
    let conv: Option<String> = arg(args, "conv")?;
    Ok(conv.unwrap_or_else(|| app.state::<Chats>().current().id().to_string()))
}

/// Port (his ask): what the chat's folder chip shows for `chat`: its working
/// folder (`path`; `name` = the folder's name, "" for Coucou's own), whether it
/// is Coucou's own (`isDefault`), whether it is gone (`missing`).
fn work_dir_info(chat: &Chat, setting: &str) -> Value {
    let own = claude_code::default_dir();
    let dir = chat.work_dir().or_else(|| claude_code::setting_dir(setting)).unwrap_or_else(|| own.clone());
    let is_default = dir == own;
    let name = if is_default {
        String::new()
    } else {
        dir.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_else(|| dir.display().to_string())
    };
    json!({
        "path": dir.display().to_string(),
        "name": name,
        "isDefault": is_default,
        "missing": !is_default && !dir.is_dir(),
        "moved": false,
    })
}

/// Port (his ask): `path` ("" = Coucou's own folder) becomes the chat's
/// working folder: the setting (new chats) and conversation `chat`'s.
/// `moved` = its Claude Code session can't follow (a new one starts there).
fn apply_work_dir(app: &AppHandle, shared: &Shared, chat: &Chat, path: &str) -> Result<Value, String> {
    let own = claude_code::default_dir();
    let dir = if path.trim().is_empty() { own.clone() } else { claude_code::checked_dir(path)? };
    let setting = if dir == own { String::new() } else { dir.display().to_string() };
    set_work_dir_setting(app, shared, setting.clone());
    let moved = chat.set_work_dir(&dir);
    log::line(format!("chat: working directory {}", if setting.is_empty() { "Robo's own" } else { setting.as_str() }));
    let mut info = work_dir_info(chat, &setting);
    info["moved"] = json!(moved);
    Ok(info)
}

/// Port (his ask): stores `chatWorkDir` (Rust-owned: save_settings keeps it).
fn set_work_dir_setting(app: &AppHandle, shared: &Shared, value: String) {
    let settings = {
        let mut current = shared.settings.lock().unwrap();
        current.chat_work_dir = value;
        current.clone()
    };
    save_settings(app, shared, settings);
}

/// Port: what the island shows of a conversation (chat_current, chat_switch).
fn describe(chat: &Chat) -> Value {
    let current = chat.current_key().map(|(kind, id)| json!({ "kind": kind, "id": id }));
    // The model it last ran on, as a reopen from the column applies.
    let (provider, model) = chat
        .current_key()
        .and_then(|(kind, id)| history::open(kind, &id).ok())
        .map(|o| (o.provider, o.model))
        .unwrap_or_default();
    json!({ "conv": chat.id(), "turns": chat.plain_turns(), "current": current, "provider": provider, "model": model, "pending": chat.pending() })
}

// ── Startup ───────────────────────────────────────────────────────────────────

/// Builds the state the Tauri `setup` built, and starts the background work.
/// Must run inside the Tokio runtime.
pub fn start(app: &AppHandle) {
    let loaded = settings::load();
    i18n::set_picked(&loaded.language);
    app.manage(Shared { settings: Mutex::new(loaded.clone()) });
    app.manage(Pending::default());
    app.manage(Chats::default());
    app.state::<Chats>().reopen_saved();
    app.manage(recap::load());

    log::line(format!("--- ambxst-robo {} started ---", env!("CARGO_PKG_VERSION")));
    hooks::ensure_hook_exe();
    hooks::refresh_installed();
    pipe::start(app.clone());
    integrations::start(app.clone());
    spotify::sync(app, &loaded.active_integrations);
}

/// A client went away: what it held goes back to the terminal.
pub fn client_gone(app: &AppHandle, client: u64, remaining: usize) {
    pipe::client_gone(app, client, remaining);
}

/// The hook relay socket, when this daemon serves it (for cleanup on exit).
pub fn relay_socket_if_serving() -> Option<std::path::PathBuf> {
    pipe::SERVING
        .load(std::sync::atomic::Ordering::Relaxed)
        .then(platform::relay_socket_path)
        .flatten()
}

pub fn log_line(message: impl AsRef<str>) {
    log::line(message);
}

#[cfg(test)]
mod tests {
    use super::diff_file;

    #[test]
    fn only_an_existing_file_by_its_full_path_reaches_the_editor() {
        let dir = std::env::temp_dir().join(format!("robo-diff-file-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("edited.ts");
        std::fs::write(&file, "x").unwrap();

        assert!(diff_file(&file.to_string_lossy()).is_some());
        assert!(diff_file(&dir.to_string_lossy()).is_none());
        assert!(diff_file(&dir.join("missing.ts").to_string_lossy()).is_none());
        assert!(diff_file("edited.ts").is_none());
        assert!(diff_file("--help").is_none());
        assert!(diff_file("").is_none());

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn camel_case_keys_and_missing_options() {
        let args = serde_json::json!({ "requestId": "1-2", "value": null });
        assert_eq!(super::arg::<String>(&args, "requestId").unwrap(), "1-2");
        assert_eq!(super::arg::<Option<f64>>(&args, "value").unwrap(), None);
        assert_eq!(super::arg::<Option<String>>(&args, "path").unwrap(), None);
        assert!(super::arg::<String>(&args, "missing").is_err());
    }
}
