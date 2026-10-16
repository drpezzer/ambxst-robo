// Relay server for ambxst-robo-hook.
//
// Windows: the named pipe `\\.\pipe\ambxst-robo-<sid>`, one instance per connection.
// Linux: the Unix socket `$XDG_RUNTIME_DIR/ambxst-robo.sock`. Every hook event is
// forwarded to the island as a `hook` event. `PermissionRequest` is the only one
// that keeps its connection open: it waits for the island's decision and writes
// it back on the same connection, which is how approving from the island works.
//
// Claude Code is never blocked by us. Three things guarantee it:
//   * ambxst-robo-hook gives the connection 300 ms and exits cleanly if we are closed;
//   * we only wait for a human once the island has *confirmed* the card is on
//     screen, so a paused island or a webview that is not listening costs a few
//     hundred milliseconds, not two minutes;
//   * whatever happens we drop the connection after the decision timeout, and
//     the terminal takes over.
//
// What we write back is the bare word `allow` or `deny` — or, when the request
// was Claude Code asking a question, `{"answers":{…}}` with what was picked on
// the island. Turning either into the documented hookSpecificOutput JSON is
// ambxst-robo-hook's job, so the wire format Claude Code expects lives in exactly
// one place.

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;
use std::time::Duration;

use serde_json::{json, Value};
use crate::host::{AppHandle, WINDOW_LABEL};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::sync::mpsc;

use crate::log;
use crate::session_window;

/// Slightly under ambxst-robo-hook's own 110 s wait, so we always answer first.
const DECISION_TIMEOUT: Duration = Duration::from_secs(108);
/// How long the island gets to say "the card is up". This is the whole of B4:
/// without it, an island that is paused, hidden behind a crashed webview or
/// simply not listening would leave Claude Code staring at a prompt nobody can
/// see for nearly two minutes.
const ACK_TIMEOUT: Duration = Duration::from_millis(800);
const MAX_PAYLOAD: usize = 1 << 20;

/// What the island can say about a permission request.
pub enum Reply {
    /// The card is on screen and a human can act on it.
    Ack,
    /// A human clicked: `allow` or `deny`.
    Decision(String),
    /// Nobody can act on it — paused, or another request already holds the card.
    Decline,
}

/// One permission request the island has been told about.
pub struct Waiting {
    tx: mpsc::Sender<Reply>,
    /// ambxst-robo: the client that acknowledged it (put the card up). If that
    /// client goes away, nobody can answer any more and the request is
    /// released to the terminal at once.
    owner: Option<u64>,
}

/// Permission requests the island has been told about.
#[derive(Default)]
pub struct Pending(pub Mutex<HashMap<String, Waiting>>);

static COUNTER: AtomicU64 = AtomicU64::new(1);

/// ambxst-robo: whether we serve `$XDG_RUNTIME_DIR/ambxst-robo.sock` (false when
/// the Tauri Coucou already does, or it could not be opened). `boot` reports it.
pub static SERVING: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

pub fn start(app: AppHandle) {
    use std::os::unix::fs::PermissionsExt;
    use tokio::net::UnixListener;

    crate::host::async_runtime::spawn(async move {
        let Some(path) = crate::platform::relay_socket_path() else {
            log::line("no private runtime directory ($XDG_RUNTIME_DIR) — Claude Code hooks are inactive");
            return;
        };
        // A socket file left behind by a crash answers nothing and can go. One
        // that answers belongs to a Robo that is still running: like
        // first_pipe_instance on Windows, we refuse to serve on top of it.
        if path.exists() {
            if std::os::unix::net::UnixStream::connect(&path).is_ok() {
                log::line("another Ambxst Robo already serves the relay socket");
                return;
            }
            let _ = std::fs::remove_file(&path);
        }
        let listener = match UnixListener::bind(&path) {
            Ok(l) => l,
            Err(err) => {
                log::line(format!("cannot open the relay socket: {err}"));
                return;
            }
        };
        // The runtime directory is already 0700; this is belt and braces.
        let _ = std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600));
        SERVING.store(true, Ordering::Relaxed);
        let uid = unsafe { libc::getuid() };
        loop {
            let stream = match listener.accept().await {
                Ok((stream, _)) => stream,
                Err(_) => {
                    tokio::time::sleep(Duration::from_millis(200)).await;
                    continue;
                }
            };
            // Only the relay run by our own user may drive the island.
            if !matches!(stream.peer_cred(), Ok(c) if c.uid() == uid) {
                log::line("refused a relay connection from another user");
                continue;
            }
            let app = app.clone();
            crate::host::async_runtime::spawn(async move { handle(app, stream).await });
        }
    });
}

/// One accepted relay connection, whatever carries it.
trait Relay: AsyncRead + AsyncWrite + Unpin {
    /// Ends the conversation once everything has been written.
    fn finish(&mut self) {}
    /// The relay process on the other end, where the OS says.
    fn client_pid(&self) -> Option<u32> {
        None
    }
}

/// Dropping the stream closes it; the relay reads up to our newline first.
impl Relay for tokio::net::UnixStream {
    /// SO_PEERCRED: the process that connected, as the kernel saw it.
    fn client_pid(&self) -> Option<u32> {
        let pid = self.peer_cred().ok()?.pid()?;
        u32::try_from(pid).ok().filter(|pid| *pid > 1)
    }
}

async fn handle(app: AppHandle, mut pipe: impl Relay) {
    let mut buf = Vec::new();
    let mut chunk = [0u8; 4096];
    loop {
        match pipe.read(&mut chunk).await {
            Ok(0) => break,
            Ok(n) => {
                buf.extend_from_slice(&chunk[..n]);
                if buf.contains(&b'\n') || buf.len() > MAX_PAYLOAD {
                    break;
                }
            }
            Err(_) => return,
        }
    }
    let line = match buf.iter().position(|b| *b == b'\n') {
        Some(i) => &buf[..i],
        None => &buf[..],
    };
    let Ok(mut payload) = serde_json::from_slice::<Value>(line) else { return };
    if !payload.is_object() {
        return;
    }

    let event = payload
        .get("hook_event_name")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string();

    note_session_window(&pipe, &payload, &event);
    // Counts for the weekly recap — never the command, path or prompt itself.
    crate::recap::observe(&app, &payload);

    if event != "PermissionRequest" {
        // Port: a session that a chat conversation holds (opened from the chats
        // column, or one of its own turns) is that conversation's mini, not
        // a second "Claude Code" pill named after its folder. While ambxst-robo
        // runs the turn itself, its own feed (claude_code.rs HookFeed) already
        // says all this: the relay's copy is dropped.
        let sid = payload.get("session_id").and_then(Value::as_str).unwrap_or_default().to_string();
        if event != "StatusLine" && !sid.is_empty() {
            if let Some((conv, running)) = app.state::<crate::chat::Chats>().conv_for_session(&sid) {
                if running {
                    pipe.finish();
                    return;
                }
                tag_helper(&mut payload, &event);
                if let Some(m) = payload.as_object_mut() {
                    m.insert("coucou_conv".into(), json!(conv));
                    if !m.contains_key("coucou_agent") {
                        // The conversation's own events. Its mini lives as long
                        // as the conversation (until retired): the island
                        // would drop an agent's pill after its Stop or at
                        // SessionEnd (the terminal closing), so Stop ends a turn
                        // the way the chat's own turns end, and SessionEnd goes.
                        if event == "SessionEnd" {
                            pipe.finish();
                            return;
                        }
                        if event == "Stop" {
                            m.insert("hook_event_name".into(), json!("ChatTurnDone"));
                        }
                        m.insert("coucou_agent".into(), json!(conv));
                    }
                }
                log::line(format!("hook {event} (conversation {conv})"));
                let _ = app.emit_to(WINDOW_LABEL, "hook", payload);
                pipe.finish();
                return;
            }
        }
        // Port: a terminal session's helpers (subagents) get pills of their own.
        tag_helper(&mut payload, &event);
        // The status line relay calls in with every Claude Code update: not log-worthy.
        if event != "StatusLine" {
            log::line(format!("hook {event}"));
        }
        let _ = app.emit_to(WINDOW_LABEL, "hook", payload);
        pipe.finish();
        return;
    }

    let id = format!("{}-{}", std::process::id(), COUNTER.fetch_add(1, Ordering::Relaxed));
    let (tx, mut rx) = mpsc::channel::<Reply>(4);
    {
        let pending = app.state::<Pending>();
        pending.0.lock().unwrap().insert(id.clone(), Waiting { tx, owner: None });
    }
    crate::recap::note_request(&app, &id, &payload);
    payload["request_id"] = json!(id);
    log::line(format!("hook PermissionRequest id={id}"));
    let _ = app.emit_to(WINDOW_LABEL, "hook", payload);

    // ambxst-robo: with no client connected nobody can even see the card, so
    // Claude Code must not wait the ack timeout either — release it now.
    let decision = if app.client_count() == 0 {
        log::line(format!("hook id={id} no client connected — terminal takes over"));
        None
    } else {
        wait_for_decision(&id, &mut rx).await
    };
    app.state::<Pending>().0.lock().unwrap().remove(&id);

    // No decision: say nothing at all. ambxst-robo-hook then writes nothing to stdout
    // and Claude Code asks in the terminal, exactly as if Coucou were closed.
    if let Some(d) = decision {
        let _ = pipe.write_all(format!("{d}\n").as_bytes()).await;
        let _ = pipe.flush().await;
    }
    pipe.finish();
}

// ── ambxst-robo: permission requests from the chat's own Claude Code runs ─────
//
// claude_code.rs runs `claude -p` with `--permission-prompt-tool stdio`: a
// tool call that needs approval (and every AskUserQuestion) comes back to it
// as a control request on the CLI's stdout, never through a hook or the relay
// socket. It is put in front of the island here, through the same pending
// table, ack window and timeouts as a relay request, but as a
// `chat-permission` event (the island's hook handler never sees the chat: no
// pill, no session). Their ids start with CHAT_PREFIX so the recap skips them.

const CHAT_PREFIX: &str = "chat-";

/// True for a request a chat run made (not a Claude Code session's).
pub fn is_chat_request(request_id: &str) -> bool {
    request_id.starts_with(CHAT_PREFIX)
}

/// Takes a chat request out of the pending table however its wait ends —
/// including the run being dropped mid-wait (timeout, error, New chat) — and
/// then tells the island the card is moot (`chat-permission-gone`), unless a
/// human already answered it.
struct ChatRequest {
    app: AppHandle,
    id: String,
    answered: bool,
}

impl Drop for ChatRequest {
    fn drop(&mut self) {
        self.app.state::<Pending>().0.lock().unwrap().remove(&self.id);
        if !self.answered {
            let _ = self.app.emit_to(WINDOW_LABEL, "chat-permission-gone", json!({ "request_id": self.id }));
        }
    }
}

/// Shows a chat run's permission request or question on the island and waits
/// for the click: `allow` / `deny`, `{"answers":{…}}` for a question, or None
/// (nobody could answer: no client, not acknowledged, declined, timed out).
/// `payload` carries `tool_name`, `tool_input` (shortened for display),
/// `session_id`, `cwd`.
///
/// An acknowledged card nobody answers is given up after DECISION_TIMEOUT (as
/// a session's): the run is told no and `chat-permission-gone` takes the card
/// down. (The island also drops it by itself a little later, in case that
/// event is lost: lib/views/chat.ts CARD_TIMEOUT_MS.)
/// Port (his bug): a chat's own card (its turn waits on it; no terminal takes
/// over) stays up this long, not 108 s.
pub const CHAT_DECISION_TIMEOUT: Duration = Duration::from_secs(30 * 60);

pub async fn ask_island_chat(app: &AppHandle, payload: Value) -> Option<String> {
    ask_island_within(app, payload, ACK_TIMEOUT, CHAT_DECISION_TIMEOUT).await
}


async fn ask_island_within(app: &AppHandle, mut payload: Value, ack: Duration, decide: Duration) -> Option<String> {
    let id = format!("{CHAT_PREFIX}{}-{}", std::process::id(), COUNTER.fetch_add(1, Ordering::Relaxed));
    let (tx, mut rx) = mpsc::channel::<Reply>(4);
    app.state::<Pending>().0.lock().unwrap().insert(id.clone(), Waiting { tx, owner: None });
    let mut guard = ChatRequest { app: app.clone(), id: id.clone(), answered: false };
    payload["request_id"] = json!(id);
    log::line(format!("chat permission request id={id}"));
    let _ = app.emit_to(WINDOW_LABEL, "chat-permission", payload);
    let decision = if app.client_count() == 0 {
        log::line(format!("chat id={id} no client connected — refused"));
        None
    } else {
        wait_within(&id, &mut rx, ack, decide).await
    };
    guard.answered = decision.is_some();
    decision
}

/// Finds, once per session, the window it runs in — see session_window.rs.
///
/// Only while the session is unknown, so the process snapshot is not taken on
/// every event. The relay must still be running for its parents to be found:
/// a permission request always is (it waits for us), a quick event may already
/// have exited, and then a later event of the session tries again.
fn note_session_window(pipe: &impl Relay, payload: &Value, event: &str) {
    let Some(session) = payload.get("session_id").and_then(Value::as_str) else { return };
    if event == "SessionEnd" {
        session_window::forget(session);
        return;
    }
    if session_window::known(session) {
        return;
    }
    let Some(relay) = pipe.client_pid() else { return };
    let ancestors = crate::platform::process_ancestors(relay);
    // No ancestors: the relay was already gone, so try again next time. Some,
    // but none with a window (a classic console): settled, VS Code it is.
    if !ancestors.is_empty() {
        session_window::remember(session, crate::platform::window_owners(&ancestors));
    }
}

// ── Port: helpers (subagents) of a terminal session ──────────────────────────

/// Per session, the descriptions of the Agent calls not yet matched to the
/// SubagentStart that follows them (that event names no task, the call does).
static HELPER_NAMES: std::sync::Mutex<Vec<(String, std::collections::VecDeque<String>)>> = std::sync::Mutex::new(Vec::new());

/// A subagent's events carry `agent_id`: tag them with a helper agent
/// (`coucou_agent`, as the chat's own helpers are, see claude_code.rs) so the
/// island gives each helper a pill and keeps its steps off the session's.
/// SubagentStart / SubagentStop become that pill's UserPromptSubmit / Stop.
/// Payloads another agent already tagged are left alone.
fn tag_helper(payload: &mut Value, event: &str) {
    let Some(map) = payload.as_object_mut() else { return };
    if map.contains_key("coucou_agent") {
        return;
    }
    let session = map.get("session_id").and_then(Value::as_str).unwrap_or_default().to_string();
    let agent = map.get("agent_id").and_then(Value::as_str).filter(|a| !a.is_empty()).map(str::to_string);
    let tool = map.get("tool_name").and_then(Value::as_str).unwrap_or_default().to_string();
    let mut names = HELPER_NAMES.lock().unwrap_or_else(|e| e.into_inner());
    let is_agent_call = tool == "Agent" || tool == "Task";
    // Every Agent call names the SubagentStart that follows, a helper's own
    // (nested) ones included; one refused never starts, so its name goes.
    if event == "PreToolUse" && is_agent_call {
        let desc = map.get("tool_input").and_then(|i| i.get("description")).and_then(Value::as_str).unwrap_or("Helper").to_string();
        match names.iter_mut().find(|(s, _)| *s == session) {
            Some((_, q)) => q.push_back(desc),
            None => names.push((session.clone(), std::collections::VecDeque::from([desc]))),
        }
        let excess = names.len().saturating_sub(32);
        names.drain(..excess);
    } else if event == "PostToolUseFailure" && is_agent_call {
        if let Some((_, q)) = names.iter_mut().find(|(s, _)| *s == session) {
            q.pop_back();
        }
    }
    let Some(agent) = agent else {
        // A new prompt or the end of the turn: no Agent call is still waiting.
        if event == "UserPromptSubmit" || event == "Stop" {
            names.retain(|(s, _)| *s != session);
        }
        return;
    };
    map.insert("coucou_agent".into(), json!(crate::claude_code::helper_tag(&agent)));
    match event {
        "SubagentStart" => {
            let kind = map.get("agent_type").and_then(Value::as_str).unwrap_or_default().to_string();
            let name = names
                .iter_mut()
                .find(|(s, _)| *s == session)
                .and_then(|(_, q)| q.pop_front())
                .unwrap_or_else(|| if kind.is_empty() { "Helper".into() } else { kind.clone() });
            map.insert("hook_event_name".into(), json!("UserPromptSubmit"));
            map.insert("prompt".into(), json!(name));
            map.insert("coucou_helper".into(), json!({ "name": name, "type": kind }));
        }
        "SubagentStop" => {
            map.insert("hook_event_name".into(), json!("Stop"));
        }
        _ => {}
    }
}

#[cfg(test)]
mod helper_tests {
    use super::*;

    #[test]
    fn a_terminal_sessions_subagent_gets_a_helper_pill() {
        // Shapes from a real 2.1.285 session's hooks.
        let mut call = json!({"hook_event_name":"PreToolUse","session_id":"s-helper-test","tool_name":"Agent","tool_input":{"description":"read hostname","subagent_type":"general-purpose"}});
        tag_helper(&mut call, "PreToolUse");
        assert!(call.get("coucou_agent").is_none());
        let mut start = json!({"hook_event_name":"SubagentStart","session_id":"s-helper-test","agent_id":"a80e27e067c5993d6","agent_type":"general-purpose"});
        tag_helper(&mut start, "SubagentStart");
        assert_eq!(start["hook_event_name"], "UserPromptSubmit");
        assert_eq!(start["prompt"], "read hostname");
        assert_eq!(start["coucou_agent"], "h-7c5993d6");
        assert_eq!(start["coucou_helper"]["name"], "read hostname");
        let mut step = json!({"hook_event_name":"PreToolUse","session_id":"s-helper-test","agent_id":"a80e27e067c5993d6","tool_name":"Read"});
        tag_helper(&mut step, "PreToolUse");
        assert_eq!(step["coucou_agent"], "h-7c5993d6");
        assert_eq!(step["hook_event_name"], "PreToolUse");
        let mut stop = json!({"hook_event_name":"SubagentStop","session_id":"s-helper-test","agent_id":"a80e27e067c5993d6"});
        tag_helper(&mut stop, "SubagentStop");
        assert_eq!(stop["hook_event_name"], "Stop");
        // Another agent's payload keeps its own tag.
        let mut codex = json!({"hook_event_name":"PreToolUse","coucou_agent":"codex","agent_id":"x"});
        tag_helper(&mut codex, "PreToolUse");
        assert_eq!(codex["coucou_agent"], "codex");
        // The session's own events are untouched.
        let mut own = json!({"hook_event_name":"PreToolUse","session_id":"s-helper-test","tool_name":"Read"});
        tag_helper(&mut own, "PreToolUse");
        assert!(own.get("coucou_agent").is_none());
    }
}

/// Two waits: a short one for "the card is up", then the long one for a human.
async fn wait_for_decision(id: &str, rx: &mut mpsc::Receiver<Reply>) -> Option<String> {
    wait_within(id, rx, ACK_TIMEOUT, DECISION_TIMEOUT).await
}

async fn wait_within(id: &str, rx: &mut mpsc::Receiver<Reply>, ack: Duration, decide: Duration) -> Option<String> {
    match tokio::time::timeout(ack, rx.recv()).await {
        Ok(Some(Reply::Ack)) => {}
        // A click that beats the ack is still a click.
        Ok(Some(Reply::Decision(d))) => {
            log::line(format!("hook id={id} answered {}", loggable(&d)));
            return Some(d);
        }
        Ok(Some(Reply::Decline)) => {
            log::line(format!("hook id={id} not shown — terminal takes over"));
            return None;
        }
        Ok(None) => return None,
        Err(_) => {
            log::line(format!("hook id={id} island never acknowledged — terminal takes over"));
            return None;
        }
    }

    match tokio::time::timeout(decide, rx.recv()).await {
        Ok(Some(Reply::Decision(d))) => {
            log::line(format!("hook id={id} answered {}", loggable(&d)));
            Some(d)
        }
        Ok(Some(Reply::Decline)) => {
            log::line(format!("hook id={id} released without a decision"));
            None
        }
        _ => {
            log::line(format!("hook id={id} timed out — terminal takes over"));
            None
        }
    }
}

/// The log says a question was answered, never with what.
fn loggable(decision: &str) -> &str {
    if decision.starts_with('{') { "a question" } else { decision }
}

fn send(app: &AppHandle, request_id: &str, reply: Reply, keep: bool, owner: Option<u64>) {
    let sender = {
        let pending = app.state::<Pending>();
        let mut map = pending.0.lock().unwrap();
        if keep {
            map.get_mut(request_id).map(|w| {
                if owner.is_some() {
                    w.owner = owner;
                }
                w.tx.clone()
            })
        } else {
            map.remove(request_id).map(|w| w.tx)
        }
    };
    match sender {
        Some(tx) => {
            let _ = tx.try_send(reply);
        }
        None => log::line(format!("reply for id={request_id} — no pending request")),
    }
}

/// The island has the card on screen; the long wait may begin.
/// `client`: the ambxst-robo client that put the card up.
pub fn acknowledge(app: &AppHandle, request_id: &str, client: u64) {
    send(app, request_id, Reply::Ack, true, Some(client));
}

/// ambxst-robo: a client went away. Every request it acknowledged — and every
/// request at all when no client is left — goes back to the terminal now.
pub fn client_gone(app: &AppHandle, client: u64, remaining: usize) {
    let released: Vec<(String, mpsc::Sender<Reply>)> = {
        let pending = app.state::<Pending>();
        let mut map = pending.0.lock().unwrap();
        let ids: Vec<String> = map
            .iter()
            .filter(|(_, w)| remaining == 0 || w.owner == Some(client))
            .map(|(id, _)| id.clone())
            .collect();
        ids.into_iter().filter_map(|id| map.remove(&id).map(|w| (id, w.tx))).collect()
    };
    for (id, tx) in released {
        log::line(format!("hook id={id} client gone — terminal takes over"));
        crate::recap::forget_request(app, &id);
        let _ = tx.try_send(Reply::Decline);
    }
}

/// Nobody can act on this one — paused, or another card already holds the view.
pub fn decline(app: &AppHandle, request_id: &str) {
    log::line(format!("decline id={request_id}"));
    send(app, request_id, Reply::Decline, false, None);
}

/// Called by the island's Allow / Deny buttons. Only ever a bare word: turning
/// it into Claude Code's JSON is ambxst-robo-hook's job.
pub fn answer(app: &AppHandle, request_id: &str, decision: &str) {
    let word = match decision {
        "allow" | "always" => "allow",
        _ => "deny",
    };
    log::line(format!("decision id={request_id} {word}"));
    send(app, request_id, Reply::Decision(word.to_string()), false, None);
}

/// Called when an option is picked for a question Claude Code asked. `answers`
/// maps each question's text to the chosen label, which is the shape
/// AskUserQuestion takes them in.
pub fn answer_question(app: &AppHandle, request_id: &str, answers: &HashMap<String, serde_json::Value>) {
    log::line(format!("decision id={request_id} answered a question"));
    // One line: the relay reads up to the first newline.
    let line = json!({ "answers": answers }).to_string();
    send(app, request_id, Reply::Decision(line), false, None);
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A client connected to `app`: its id and the lines it receives.
    fn client(app: &AppHandle) -> (u64, tokio::sync::mpsc::UnboundedReceiver<String>) {
        let (tx, rx) = tokio::sync::mpsc::unbounded_channel();
        (app.add_client(tx), rx)
    }

    /// The next event line named `name` (skipping others), within 2 s.
    async fn next_event(rx: &mut tokio::sync::mpsc::UnboundedReceiver<String>, name: &str) -> Value {
        let found = tokio::time::timeout(Duration::from_secs(2), async {
            loop {
                let line = rx.recv().await.expect("client channel open");
                let v: Value = serde_json::from_str(&line).unwrap();
                if v["event"] == name {
                    return v["payload"].clone();
                }
            }
        });
        found.await.unwrap_or_else(|_| panic!("no {name} event"))
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn an_acknowledged_chat_card_nobody_answers_times_out_and_goes() {
        let app = AppHandle::new();
        app.manage(Pending::default());
        let (me, mut rx) = client(&app);
        let ask = {
            let app = app.clone();
            tokio::spawn(async move {
                ask_island_within(&app, json!({"tool_name": "Bash"}), Duration::from_millis(800), Duration::from_millis(300)).await
            })
        };
        let card = next_event(&mut rx, "chat-permission").await;
        let id = card["request_id"].as_str().unwrap().to_string();
        assert!(is_chat_request(&id));
        acknowledge(&app, &id, me);
        // Nobody clicks: no decision (the run is told no), the card is moot.
        assert_eq!(ask.await.unwrap(), None);
        assert_eq!(next_event(&mut rx, "chat-permission-gone").await["request_id"], json!(id));
        assert!(app.state::<Pending>().0.lock().unwrap().is_empty());
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn an_answered_chat_card_gives_the_click_and_no_gone_event() {
        let app = AppHandle::new();
        app.manage(Pending::default());
        let (me, mut rx) = client(&app);
        let ask = {
            let app = app.clone();
            tokio::spawn(async move {
                ask_island_within(&app, json!({"tool_name": "AskUserQuestion"}), Duration::from_millis(800), Duration::from_secs(5)).await
            })
        };
        let id = next_event(&mut rx, "chat-permission").await["request_id"].as_str().unwrap().to_string();
        acknowledge(&app, &id, me);
        let mut answers = HashMap::new();
        answers.insert("Which one?".to_string(), json!("my own answer"));
        answer_question(&app, &id, &answers);
        let got = ask.await.unwrap().expect("answered");
        assert_eq!(serde_json::from_str::<Value>(&got).unwrap(), json!({"answers": {"Which one?": "my own answer"}}));
        // Answered: no chat-permission-gone follows.
        let gone = tokio::time::timeout(Duration::from_millis(200), async {
            while let Some(line) = rx.recv().await {
                if line.contains("chat-permission-gone") {
                    return true;
                }
            }
            false
        });
        assert!(!gone.await.unwrap_or(false));
    }
}
