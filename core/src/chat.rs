// The chat, whoever answers it: the conversation, the system prompt, and which
// provider a turn goes to. Each provider's own wire format lives in its module:
// claude.rs (Anthropic), openai_compat.rs (OpenAI, Google AI, OpenRouter),
// local_chat.rs (Ollama, LM Studio, any OpenAI-compatible server) and
// claude_code.rs (the user's own Claude Code CLI and subscription — port only).
//
// API keys never leave the credential store and file bytes never cross the IPC
// boundary: the island sends the question and gets the answer's text back.

use std::sync::Mutex;

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use crate::host::AppHandle;

use crate::settings::Settings;
use crate::{claude, claude_code, local_chat, openai_compat, secrets};

pub const ANTHROPIC: &str = "anthropic";

#[derive(Debug, Clone, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum ChatContext {
    File { name: String, path: String },
    Window { app_name: String, title: String, url: Option<String> },
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ChatReply {
    pub text: String,
    /// Port: the user stopped the turn (chat_stop); `text` is what came so far.
    pub stopped: bool,
    /// Port: the conversation (`Chats`) that answered.
    pub conv: String,
}

// ── Port: the running turn's controls (chat_stop / chat_inject) ──────────────

/// What the island may do to the turn that is running.
pub enum TurnControl {
    /// A message typed while it works: Claude Code folds it into the turn.
    Inject(String),
    Stop,
}

/// The running turns' controls by conversation, and whether each takes
/// injected messages (port: conversations run side by side, see `Chats`).
static CONTROL: Mutex<Vec<(String, bool, tokio::sync::mpsc::UnboundedSender<TurnControl>)>> = Mutex::new(Vec::new());

/// Hands `c` to the turn running in conversation `conv`. False when none
/// runs, or for an injected message the provider can't take mid-answer (the
/// island then sends it as the next turn).
pub fn control(conv: &str, c: TurnControl) -> bool {
    let slots = CONTROL.lock().unwrap_or_else(|e| e.into_inner());
    match (slots.iter().find(|(id, ..)| id == conv), &c) {
        (None, _) => false,
        (Some((_, false, _)), TurnControl::Inject(_)) => false,
        (Some((_, _, tx)), _) => tx.send(c).is_ok(),
    }
}

/// Clears a conversation's controls when its turn ends.
struct ControlGuard(String);

impl Drop for ControlGuard {
    fn drop(&mut self) {
        CONTROL.lock().unwrap_or_else(|e| e.into_inner()).retain(|(id, ..)| *id != self.0);
    }
}

/// A model a provider offers, for the picker in the chat view.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ModelInfo {
    pub id: String,
    pub label: String,
}

// ── Conversation ──────────────────────────────────────────────────────────────

/// The conversation is kept twice: in the wire format of the provider that
/// answered last (Claude's carries web search blocks no other provider would
/// understand), and as plain text turns. Switching provider mid-conversation
/// rebuilds the history from the plain turns, so nothing in one provider's
/// format is ever sent to another.
#[derive(Default)]
pub struct Chat {
    inner: Mutex<Conversation>,
    /// Port: which of `Chats` this is: its events and hooks carry it.
    id: String,
}

#[derive(Default)]
struct Conversation {
    /// Bumped by every reset, so an answer that lands after "New chat" is dropped.
    epoch: u64,
    /// The provider `native` belongs to.
    owner: Option<String>,
    native: Vec<Value>,
    /// `{"role", "content": text}` turns, the same whoever answered.
    plain: Vec<Value>,
    /// Claude Code's session id (claude_code.rs) and how many plain turns it
    /// had seen: it is resumed only while no other provider answered since.
    cli_session: Option<(String, usize)>,
    /// Port (his ask): the folder `cli_session` lives in (Claude Code keeps a
    /// session per working folder; `--resume` finds it only there). None =
    /// Coucou's own folder (claude_code::work_dir).
    cli_dir: Option<std::path::PathBuf>,
    /// Port: where the conversation is kept (history.rs).
    meta: Meta,
    /// Port: the message a turn is answering right now, so an island started
    /// meanwhile (a shell reload) shows it with the dots (chat_current).
    pending: Option<String>,
    /// Port (his ask): where Claude Code compacted the conversation, as how
    /// many plain turns came before each: the island marks the spot.
    compactions: Vec<usize>,
}

/// Port: a Claude Code session from ~/.claude/projects reopened in the chat.
/// Its turns are resumed in its own folder; it stays the CLI's session (not
/// saved as a Coucou chat) until another provider answers in it.
#[derive(Debug, Clone, PartialEq)]
pub struct External {
    pub session: String,
    pub cwd: std::path::PathBuf,
    pub project: String,
}

/// Port: which saved chat this conversation is (history.rs).
#[derive(Debug, Default, Clone)]
struct Meta {
    /// The Coucou chat's id once it has been saved.
    id: Option<String>,
    created: i64,
    title: String,
    external: Option<External>,
    /// Every Claude Code session that answered in this chat.
    cli_ids: Vec<String>,
    /// An unclaimed Coucou CLI session this conversation was opened from.
    import_key: Option<String>,
    /// Port (his ask): the working folder this conversation's Claude Code
    /// turns run in, once it has one (its first Claude Code turn, a reopen,
    /// the folder chip); None = the `chatWorkDir` setting.
    work_dir: Option<std::path::PathBuf>,
    /// Port (his ask): the Claude Code sessions this chat started outside
    /// Coucou's own folder, and their folders (history.rs lists and trashes
    /// them with the chat).
    cli_dirs: std::collections::BTreeMap<String, String>,
}

/// What a provider needs to build one turn.
pub struct Turn {
    epoch: u64,
    provider: String,
    /// No earlier turn: the file or window context rides along with this one.
    pub first: bool,
    /// The earlier turns, in this provider's format.
    pub history: Vec<Value>,
}

impl Chat {
    /// Port: a conversation of `Chats`, named `id`.
    pub fn with_id(id: &str) -> Chat {
        Chat { inner: Mutex::default(), id: id.to_string() }
    }

    /// Port: its id in `Chats` ("" outside of it).
    pub fn id(&self) -> &str {
        &self.id
    }

    /// Port: nothing said in it and nothing on its way.
    pub fn is_blank(&self) -> bool {
        let c = self.inner.lock().unwrap();
        c.plain.is_empty() && c.pending.is_none() && c.meta.external.is_none() && c.meta.id.is_none() && c.meta.import_key.is_none()
    }

    /// Port: what its mini is called: the saved title, else its first question.
    pub fn title(&self) -> String {
        let c = self.inner.lock().unwrap();
        if !c.meta.title.is_empty() {
            return c.meta.title.clone();
        }
        let first = c.plain.iter().find(|t| t["role"] == "user").and_then(|t| t["content"].as_str()).map(str::to_string);
        first.or_else(|| c.pending.clone()).map(|q| crate::history::title_of(&q)).unwrap_or_default()
    }

    pub fn reset(&self) {
        let mut c = self.inner.lock().unwrap();
        let epoch = c.epoch + 1;
        *c = Conversation { epoch, ..Default::default() };
    }

    /// Port: a handle on the current conversation (its epoch), taken before a
    /// turn so the chat is saved only if no reset or reopen came in between.
    pub fn begin_probe(&self) -> Turn {
        let c = self.inner.lock().unwrap();
        Turn { epoch: c.epoch, provider: String::new(), first: c.plain.is_empty(), history: Vec::new() }
    }

    /// Starts a turn with `provider`, converting the history if another
    /// provider answered the previous turns.
    pub fn begin(&self, provider: &str) -> Turn {
        let mut c = self.inner.lock().unwrap();
        if c.owner.as_deref() != Some(provider) {
            c.native = c.plain.clone();
            c.owner = Some(provider.to_string());
        }
        Turn {
            epoch: c.epoch,
            provider: provider.to_string(),
            first: c.plain.is_empty(),
            history: c.native.clone(),
        }
    }

    /// Port: records a finished turn made of several messages (`role`,
    /// text): the question, then what was typed while it worked and the
    /// answers around it. Empty ones are skipped and neighbours of one role
    /// are joined, so the history keeps alternating (the format here is the
    /// plain one in both records, as Claude Code's own is).
    pub fn commit_turns(&self, turn: &Turn, turns: &[(&str, String)]) {
        let mut c = self.inner.lock().unwrap();
        if c.epoch != turn.epoch || c.owner.as_deref() != Some(turn.provider.as_str()) {
            return;
        }
        let c = &mut *c;
        for (role, text) in turns {
            let text = text.trim();
            if text.is_empty() {
                continue;
            }
            for list in [&mut c.native, &mut c.plain] {
                match list.last_mut() {
                    Some(last) if last["role"] == *role => {
                        let joined = format!("{}\n\n{text}", last["content"].as_str().unwrap_or_default());
                        last["content"] = json!(joined);
                    }
                    _ => list.push(json!({ "role": role, "content": text })),
                }
            }
        }
        if c.meta.external.is_some() && turn.provider != crate::claude_code::ID {
            c.meta.external = None;
        }
    }

    /// Records a finished turn: the user message and the answer in the
    /// provider's format, and their plain text. Only a successful turn is
    /// recorded, so the history always matches what the model saw.
    pub fn commit(&self, turn: &Turn, user: Value, assistant: Value, user_text: &str, answer: &str) {
        let mut c = self.inner.lock().unwrap();
        if c.epoch != turn.epoch || c.owner.as_deref() != Some(turn.provider.as_str()) {
            return;
        }
        c.native.push(user);
        c.native.push(assistant);
        c.plain.push(json!({ "role": "user", "content": user_text }));
        c.plain.push(json!({ "role": "assistant", "content": answer }));
        // Port: another provider answered in a reopened Claude Code session:
        // from now on it is a Coucou chat (saved, with every turn so far).
        if c.meta.external.is_some() && turn.provider != crate::claude_code::ID {
            c.meta.external = None;
        }
    }

    /// The Claude Code session to resume for `turn`: the one that answered the
    /// conversation so far, None when there is none or another provider
    /// answered after it (its turns then go along as a transcript).
    pub fn cli_session(&self, turn: &Turn) -> Option<String> {
        let c = self.inner.lock().unwrap();
        match &c.cli_session {
            Some((id, seen)) if c.epoch == turn.epoch && *seen == c.plain.len() => Some(id.clone()),
            _ => None,
        }
    }

    /// Records the session that answered `turn` (call after `commit`), and
    /// the folder it ran in.
    pub fn set_cli_session(&self, turn: &Turn, id: &str, dir: &std::path::Path) {
        let mut c = self.inner.lock().unwrap();
        if c.epoch != turn.epoch || c.owner.as_deref() != Some(turn.provider.as_str()) {
            return;
        }
        let seen = c.plain.len();
        c.cli_session = Some((id.to_string(), seen));
        if !c.meta.cli_ids.iter().any(|x| x == id) {
            c.meta.cli_ids.push(id.to_string());
        }
        // Port (his ask): the conversation goes on in this folder; a session
        // Coucou started outside its own folder is remembered with it.
        c.cli_dir = Some(dir.to_path_buf());
        if c.meta.external.is_none() {
            c.meta.work_dir = Some(dir.to_path_buf());
            if dir != crate::claude_code::default_dir() {
                c.meta.cli_dirs.insert(id.to_string(), dir.display().to_string());
            }
        }
        // A resumed session that came back under a new id is that id now.
        if let Some(ext) = c.meta.external.as_mut() {
            ext.session = id.to_string();
        }
    }

    /// Port (his ask): the folder the Claude Code session `turn` would resume
    /// lives in (Coucou's own folder when none was recorded).
    pub fn cli_dir(&self) -> std::path::PathBuf {
        let c = self.inner.lock().unwrap();
        c.cli_dir.clone().unwrap_or_else(crate::claude_code::default_dir)
    }

    /// Port (his ask): this conversation's working folder: a reopened Claude
    /// Code session's own, else the one it was given (None = the setting's).
    pub fn work_dir(&self) -> Option<std::path::PathBuf> {
        let c = self.inner.lock().unwrap();
        c.meta.external.as_ref().map(|e| e.cwd.clone()).or_else(|| c.meta.work_dir.clone())
    }

    /// Port (his ask): the folder chip moved this conversation to `dir`. Its
    /// next Claude Code turn runs there; true when that can't be its current
    /// session (Claude Code keeps sessions per folder): a new one starts
    /// there, with the earlier turns as a transcript. A reopened Claude Code
    /// session moved out of its folder becomes a Coucou chat, as when
    /// another provider answers in it.
    pub fn set_work_dir(&self, dir: &std::path::Path) -> bool {
        let mut c = self.inner.lock().unwrap();
        if let Some(ext) = &c.meta.external {
            if ext.cwd == dir {
                return false;
            }
            c.meta.external = None;
        }
        c.meta.work_dir = Some(dir.to_path_buf());
        let session_dir = c.cli_session.as_ref().map(|_| c.cli_dir.clone().unwrap_or_else(crate::claude_code::default_dir));
        session_dir.is_some_and(|d| d != dir)
    }

    // ── Port: the chats column (history.rs) ──

    /// The reopened Claude Code session `turn` resumes, if it does: its turns
    /// then run in the session's own folder.
    pub fn external(&self, turn: &Turn) -> Option<External> {
        let c = self.inner.lock().unwrap();
        let ext = c.meta.external.clone()?;
        match &c.cli_session {
            Some((id, seen)) if c.epoch == turn.epoch && *seen == c.plain.len() && *id == ext.session => Some(ext),
            _ => None,
        }
    }

    /// Replaces the conversation with a reopened chat. `turns` are plain
    /// `{role, content}` turns; they are evened out (user first, roles
    /// alternating) so every provider can take them.
    pub fn open(&self, opened: &crate::history::Opened) {
        let mut plain: Vec<Value> = Vec::new();
        let mut compactions: Vec<usize> = Vec::new();
        for t in &opened.turns {
            // A compaction's marker (history.rs read_turns): its place, not a turn.
            if t["role"] == "compact" {
                if compactions.last() != Some(&plain.len()) {
                    compactions.push(plain.len());
                }
                continue;
            }
            let role = if t["role"] == "assistant" { "assistant" } else { "user" };
            let text = t["content"].as_str().unwrap_or_default();
            if text.is_empty() || (plain.is_empty() && role == "assistant") {
                continue;
            }
            match plain.last_mut() {
                Some(last) if last["role"] == role => {
                    let joined = format!("{}\n\n{text}", last["content"].as_str().unwrap_or_default());
                    last["content"] = json!(joined);
                }
                _ => plain.push(json!({ "role": role, "content": text })),
            }
        }
        // A conversation ends on an answer: a trailing question was never answered.
        if plain.last().is_some_and(|t| t["role"] == "user") {
            plain.pop();
        }
        let mut c = self.inner.lock().unwrap();
        let epoch = c.epoch + 1;
        let seen = plain.len();
        let stored = opened.stored.as_ref();
        *c = Conversation {
            epoch,
            owner: None,
            native: Vec::new(),
            plain,
            cli_session: opened.cli_session.clone().map(|id| (id, seen)),
            cli_dir: opened.cli_dir.clone(),
            meta: Meta {
                id: stored.map(|s| s.id.clone()),
                created: stored.map(|s| s.created).unwrap_or_else(crate::history::now_ms),
                title: opened.title.clone(),
                external: opened.external.clone(),
                cli_ids: stored
                    .map(|s| s.cli_ids.clone())
                    .unwrap_or_else(|| opened.cli_session.clone().into_iter().collect()),
                import_key: opened.import_key.clone(),
                work_dir: opened.work_dir.clone(),
                cli_dirs: stored.map(|s| s.cli_dirs.clone()).unwrap_or_default(),
            },
            pending: None,
            compactions: compactions.into_iter().filter(|&n| n <= seen).collect(),
        };
    }

    /// The turns the island should show for the current conversation, with
    /// `{"role": "compact"}` where Claude Code compacted it.
    pub fn plain_turns(&self) -> Vec<Value> {
        let c = self.inner.lock().unwrap();
        let mut out = Vec::with_capacity(c.plain.len() + c.compactions.len());
        for (i, t) in c.plain.iter().enumerate() {
            for _ in c.compactions.iter().filter(|&&n| n == i) {
                out.push(json!({ "role": "compact", "content": "" }));
            }
            out.push(t.clone());
        }
        for _ in c.compactions.iter().filter(|&&n| n >= c.plain.len()) {
            out.push(json!({ "role": "compact", "content": "" }));
        }
        out
    }

    /// Port: Claude Code compacted the conversation just now (its turn's
    /// question is not in `plain` yet: the marker goes after it, as shown live).
    pub fn note_compaction(&self) {
        let mut c = self.inner.lock().unwrap();
        let at = c.plain.len() + usize::from(c.pending.is_some());
        if c.compactions.last() != Some(&at) {
            c.compactions.push(at);
        }
    }

    /// Port: the message being answered now, if a turn runs.
    pub fn pending(&self) -> Option<String> {
        self.inner.lock().unwrap().pending.clone()
    }

    /// Port: marks `text` as being answered until the guard drops (the turn
    /// ended, failed or was abandoned).
    pub fn pending_guard<'a>(&'a self, text: &str) -> PendingGuard<'a> {
        let mut c = self.inner.lock().unwrap();
        c.pending = Some(text.to_string());
        PendingGuard { chat: self, epoch: c.epoch }
    }

    /// Port: the Claude Code session `id` is this conversation's (reopened from
    /// the chats column, or one of its own turns): "Open terminal" shows the chat.
    pub fn holds_session(&self, id: &str) -> bool {
        let c = self.inner.lock().unwrap();
        c.meta.external.as_ref().is_some_and(|e| e.session == id) || c.meta.cli_ids.iter().any(|s| s == id)
    }

    /// Port: writes which conversation is open (`current-chat.json`), so a
    /// restarted ambxst-robo opens it again (see `reopen_saved`); none: removed.
    pub fn remember_current(&self) {
        let path = crate::settings::local_dir().join("current-chat.json");
        match self.current_key() {
            Some((kind, id)) => {
                let _ = std::fs::create_dir_all(crate::settings::local_dir());
                let _ = std::fs::write(&path, json!({ "kind": kind, "id": id }).to_string());
            }
            None => {
                let _ = std::fs::remove_file(&path);
            }
        }
    }

    /// Port: at start, the conversation open when ambxst-robo last stopped.
    pub fn reopen_saved(&self) {
        let path = crate::settings::local_dir().join("current-chat.json");
        let Ok(text) = std::fs::read_to_string(&path) else { return };
        let Ok(v) = serde_json::from_str::<Value>(&text) else { return };
        let (Some(kind), Some(id)) = (v["kind"].as_str(), v["id"].as_str()) else { return };
        match crate::history::open(kind, id) {
            Ok(opened) => self.open(&opened),
            Err(e) => crate::log::line(format!("chat: could not reopen the last chat: {e}")),
        }
    }

    /// The chats column's key of the current conversation: `(kind, id)`.
    pub fn current_key(&self) -> Option<(&'static str, String)> {
        let c = self.inner.lock().unwrap();
        if let Some(ext) = &c.meta.external {
            return Some(("claude", ext.session.clone()));
        }
        if let Some(id) = &c.meta.id {
            return Some(("coucou", id.clone()));
        }
        c.meta.import_key.clone().map(|k| ("coucou", k))
    }

    /// After a successful turn: the record to save for a Coucou chat (None
    /// for a reopened Claude Code session, which the CLI keeps). Gives the
    /// chat its id on its first save; `query` titles a new chat.
    pub fn snapshot(&self, turn: &Turn, provider: &str, model: &str, query: &str) -> Option<crate::history::Stored> {
        let mut c = self.inner.lock().unwrap();
        if c.epoch != turn.epoch || c.meta.external.is_some() || c.plain.is_empty() {
            return None;
        }
        if c.meta.id.is_none() {
            c.meta.id = Some(crate::history::new_id());
            if c.meta.created == 0 {
                c.meta.created = crate::history::now_ms();
            }
        }
        if c.meta.title.is_empty() {
            c.meta.title = crate::history::title_of(query);
        }
        c.meta.import_key = None;
        let cli_session = match &c.cli_session {
            Some((id, seen)) if *seen == c.plain.len() => Some(id.clone()),
            _ => None,
        };
        Some(crate::history::Stored {
            id: c.meta.id.clone().unwrap_or_default(),
            title: c.meta.title.clone(),
            provider: provider.to_string(),
            model: model.to_string(),
            created: c.meta.created,
            updated: crate::history::now_ms(),
            turns: c.plain.clone(),
            cli_session,
            cli_ids: c.meta.cli_ids.clone(),
            work_dir: c.meta.work_dir.as_ref().map(|d| d.display().to_string()),
            cli_dirs: c.meta.cli_dirs.clone(),
        })
    }
}

// ── Port: conversations side by side (his ask: multitasking) ─────────────────

/// Every conversation open since ambxst-robo started, each its own `Chat`
/// with its own turn running or not; one is current (the chat page's). A
/// conversation the user has talked in stays until it is retired (its mini
/// in the island); one only looked at goes when another becomes current.
pub struct Chats {
    inner: Mutex<Slots>,
}

struct Slots {
    list: Vec<Slot>,
    current: String,
    next: u64,
}

struct Slot {
    chat: std::sync::Arc<Chat>,
    /// A message was sent in it since ambxst-robo started.
    talked: bool,
}

impl Default for Chats {
    fn default() -> Self {
        let mut slots = Slots { list: Vec::new(), current: String::new(), next: 0 };
        let id = slots.fresh_id();
        slots.list.push(Slot { chat: std::sync::Arc::new(Chat::with_id(&id)), talked: false });
        slots.current = id;
        Chats { inner: Mutex::new(slots) }
    }
}

impl Slots {
    /// Unique for this run and unlikely to meet an island's leftover from the
    /// last one: a valid agent tag (`[a-z0-9-]`, ≤ 24) for its pill.
    fn fresh_id(&mut self) -> String {
        self.next += 1;
        let stamp = (crate::history::now_ms() as u64) & 0xff_ffff;
        format!("c-{stamp:x}{:x}", self.next)
    }

    fn find(&self, id: &str) -> Option<&Slot> {
        self.list.iter().find(|s| s.chat.id() == id)
    }

    fn current(&self) -> std::sync::Arc<Chat> {
        self.find(&self.current).map(|s| s.chat.clone()).expect("the current conversation is in the list")
    }

    /// Makes `id` current; the one left goes if nobody talked in it and
    /// nothing runs in it.
    fn make_current(&mut self, id: String) {
        let left = std::mem::replace(&mut self.current, id);
        if left != self.current {
            self.list.retain(|s| s.chat.id() != left || s.talked || s.chat.pending().is_some());
        }
    }

    fn add(&mut self) -> std::sync::Arc<Chat> {
        let id = self.fresh_id();
        let chat = std::sync::Arc::new(Chat::with_id(&id));
        self.list.push(Slot { chat: chat.clone(), talked: false });
        self.make_current(id);
        chat
    }
}

impl Chats {
    /// The current conversation.
    pub fn current(&self) -> std::sync::Arc<Chat> {
        self.inner.lock().unwrap().current()
    }

    /// The conversation `id`, or the current one when `id` is None.
    pub fn get(&self, id: Option<&str>) -> Result<std::sync::Arc<Chat>, String> {
        let s = self.inner.lock().unwrap();
        match id {
            None => Ok(s.current()),
            Some(id) => s.find(id).map(|x| x.chat.clone()).ok_or_else(|| "That conversation is closed.".to_string()),
        }
    }

    /// A message goes into `id`: it is open for good now (until retired).
    pub fn talked(&self, id: &str) {
        let mut s = self.inner.lock().unwrap();
        if let Some(slot) = s.list.iter_mut().find(|x| x.chat.id() == id) {
            slot.talked = true;
        }
    }

    /// "New chat": a fresh conversation becomes current (the current one is
    /// reused when it is still blank). Returns its id.
    pub fn new_conversation(&self) -> String {
        let mut s = self.inner.lock().unwrap();
        let cur = s.current();
        if cur.is_blank() {
            cur.reset();
            return cur.id().to_string();
        }
        s.add().id().to_string()
    }

    /// Makes `id` current. False when it isn't open.
    pub fn switch(&self, id: &str) -> bool {
        let mut s = self.inner.lock().unwrap();
        if s.find(id).is_none() {
            return false;
        }
        s.make_current(id.to_string());
        true
    }

    /// A chat from the column: the open conversation holding it becomes
    /// current; otherwise it opens in the current one if that one is unused
    /// (blank, or only looked at), else in a new one. Returns the conversation.
    pub fn open(&self, kind: &str, id: &str, opened: &crate::history::Opened) -> std::sync::Arc<Chat> {
        let mut s = self.inner.lock().unwrap();
        let holder = s
            .list
            .iter()
            .find(|x| x.chat.current_key().is_some_and(|(k, i)| k == kind && i == id) || (kind == "claude" && x.chat.holds_session(id)))
            .map(|x| x.chat.clone());
        if let Some(chat) = holder {
            s.make_current(chat.id().to_string());
            return chat;
        }
        let cur = s.current();
        let unused = s.find(cur.id()).is_some_and(|x| !x.talked) && cur.pending().is_none();
        let chat = if unused { cur } else { s.add() };
        chat.open(opened);
        chat
    }

    /// Retires `id`: its turn is stopped and it closes (the chat stays in the
    /// column). Retiring the current one leaves a fresh conversation current.
    /// Returns the current conversation's id after.
    pub fn retire(&self, id: &str) -> String {
        // Port: a retired chat's Remote Control goes with it.
        crate::remote::stop(id);
        control(id, TurnControl::Stop);
        let mut s = self.inner.lock().unwrap();
        s.list.retain(|x| x.chat.id() != id);
        if s.current == id {
            let fresh = s.fresh_id();
            s.list.push(Slot { chat: std::sync::Arc::new(Chat::with_id(&fresh)), talked: false });
            s.current = fresh;
        }
        s.current.clone()
    }

    /// The open conversation holding chat `(kind, id)`, if one does.
    pub fn holding(&self, kind: &str, id: &str) -> Option<String> {
        let s = self.inner.lock().unwrap();
        s.list
            .iter()
            .find(|x| x.chat.current_key().is_some_and(|(k, i)| k == kind && i == id) || (kind == "claude" && x.chat.holds_session(id)))
            .map(|x| x.chat.id().to_string())
    }

    /// Port: the conversation with a mini (talked in, or answering) that holds
    /// Claude Code session `id`, and whether ambxst-robo is running a turn in
    /// it right now. A session only opened in the chat has no mini: its
    /// terminal's activity stays on the Claude Code pill.
    pub fn conv_for_session(&self, id: &str) -> Option<(String, bool)> {
        let s = self.inner.lock().unwrap();
        s.list
            .iter()
            .filter(|x| x.talked || x.chat.pending().is_some())
            .find(|x| x.chat.holds_session(id))
            .map(|x| (x.chat.id().to_string(), x.chat.pending().is_some()))
    }

    /// Port (his ask): what Remote Control resumes for conversation `id`: its
    /// Claude Code session, the folder it runs in (None = the chat's own), its title.
    pub fn remote_target(&self, id: &str) -> Option<(String, Option<std::path::PathBuf>, String)> {
        let s = self.inner.lock().unwrap();
        let x = s.list.iter().find(|x| x.chat.id() == id)?;
        let c = x.chat.inner.lock().unwrap();
        let (sid, _) = c.cli_session.clone()?;
        // Port (his ask): a chat's session may live in the folder it was given.
        let cwd = c.meta.external.as_ref().map(|e| e.cwd.clone()).or_else(|| c.cli_dir.clone());
        drop(c);
        Some((sid, cwd, x.chat.title()))
    }

    /// Some open conversation runs (or ran) the Claude Code session `id`.
    pub fn holds_session(&self, id: &str) -> bool {
        self.inner.lock().unwrap().list.iter().any(|x| x.chat.holds_session(id))
    }

    /// The conversations with a mini: talked in, or answering right now.
    pub fn list(&self) -> Vec<Value> {
        let s = self.inner.lock().unwrap();
        s.list
            .iter()
            .filter(|x| x.talked || x.chat.pending().is_some())
            .map(|x| {
                let key = x.chat.current_key().map(|(kind, id)| json!({ "kind": kind, "id": id }));
                json!({
                    "conv": x.chat.id(),
                    "title": x.chat.title(),
                    "key": key,
                    "pending": x.chat.pending(),
                    "current": x.chat.id() == s.current,
                })
            })
            .collect()
    }

    /// The current conversation is remembered across ambxst-robo restarts.
    pub fn remember_current(&self) {
        self.current().remember_current();
    }

    pub fn reopen_saved(&self) {
        self.current().reopen_saved();
    }
}

// ── System prompt ─────────────────────────────────────────────────────────────

/// The mascot's instructions. Greets the user by their first name when the account
/// has one worth using (identity.rs), and only claims web search where the
/// provider runs it (Claude).
pub fn system_prompt(web_search: bool) -> String {
    system_prompt_for(crate::identity::first_name(), web_search)
}

fn system_prompt_for(first_name: Option<&str>, web_search: bool) -> String {
    let opening = match first_name {
        Some(name) => format!("You are Robo, {name}'s personal AI assistant living at the top of their screen."),
        None => "You are Robo, a personal AI assistant living at the top of the user's screen.".to_string(),
    };
    let abilities = if web_search {
        "You have web search access and can help with absolutely anything — research, coding, finding places, recommendations, tasks, questions."
    } else {
        "You can help with absolutely anything — research, coding, recommendations, tasks, questions. You have no web access: say so when something needs current information."
    };
    format!(
        "{opening} {abilities} \
Respond in the user's language. Be thorough and complete — use as much detail as the task requires. \
Use light Markdown when it helps: short paragraphs, bullet lists, **bold**, `inline code` and fenced code blocks. Avoid tables and big headings: the chat window is small."
    )
}

/// The window context line, as ClaudeService.chat() writes it.
pub fn window_line(app_name: &str, title: &str, url: Option<&str>) -> String {
    let mut text = format!("Context — App: {app_name}, Window: {title}");
    if let Some(url) = url {
        text.push_str(&format!(", URL: {url}"));
    }
    text
}

/// The plain-text record of what the user asked, context included.
pub fn plain_question(first: bool, context: Option<&ChatContext>, query: &str) -> String {
    match context.filter(|_| first) {
        Some(ChatContext::File { name, .. }) => format!("File: {name}\n\n{query}"),
        Some(ChatContext::Window { app_name, title, url }) => {
            format!("{}\n\n{query}", window_line(app_name, title, url.as_deref()))
        }
        None => query.to_string(),
    }
}

// ── Which provider ────────────────────────────────────────────────────────────

/// The model chosen for `provider`, or its default.
pub fn model_for(settings: &Settings, provider: &str) -> String {
    if provider == ANTHROPIC {
        let m = settings.model.trim();
        return if m.is_empty() { claude::DEFAULT_MODEL.to_string() } else { m.to_string() };
    }
    settings
        .chat_models
        .get(provider)
        .map(|m| m.trim().to_string())
        .filter(|m| !m.is_empty())
        .or_else(|| openai_compat::provider(provider).map(|p| p.default_model.to_string()))
        .or_else(|| (provider == claude_code::ID).then(|| claude_code::DEFAULT_MODEL.to_string()))
        .unwrap_or_default()
}

/// A file rides along only if it is one of Coucou's own copies of a dropped
/// file (files.rs puts them in the inbox). The page names the path, so without
/// this any file the user can read could be sent to a chat provider.
/// Port: a dropped folder is copied into the inbox too (files::ingest_folder),
/// so a folder there rides along as well.
fn checked_context(context: ChatContext) -> Result<ChatContext, String> {
    match context {
        ChatContext::File { name, path } => {
            let inbox = crate::files::inbox_dir();
            if !is_inside(&inbox, std::path::Path::new(&path)) {
                return Err(crate::i18n::t("Only a file dropped on the island can be sent with a question."));
            }
            Ok(ChatContext::File { name, path })
        }
        other => Ok(other),
    }
}

/// True when `path` is a regular file or a folder directly inside `dir`, both
/// resolved (no `..`, no symlink pointing out of it).
fn is_inside(dir: &std::path::Path, path: &std::path::Path) -> bool {
    let (Ok(dir), Ok(file)) = (dir.canonicalize(), path.canonicalize()) else { return false };
    file.parent() == Some(dir.as_path())
        && std::fs::symlink_metadata(&file).map(|m| m.is_file() || m.is_dir()).unwrap_or(false)
}

/// Port: clears Chat's pending message when a turn ends (see pending_guard).
pub struct PendingGuard<'a> {
    chat: &'a Chat,
    epoch: u64,
}

impl Drop for PendingGuard<'_> {
    fn drop(&mut self) {
        let mut c = self.chat.inner.lock().unwrap_or_else(|e| e.into_inner());
        if c.epoch == self.epoch {
            c.pending = None;
        }
    }
}

/// One chat turn with the provider chosen in the settings.
pub async fn send(
    app: &AppHandle,
    chat: &Chat,
    settings: &Settings,
    query: String,
    context: Option<ChatContext>,
) -> Result<ChatReply, String> {
    let context = context.map(checked_context).transpose()?;
    let provider = settings.chat_provider.as_str();
    let model = model_for(settings, provider);
    // Port: the turn this send makes, to save the chat once it succeeded.
    let probe = chat.begin_probe();
    let title = query.clone();
    let _pending = chat.pending_guard(&query);
    let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
    {
        let mut slots = CONTROL.lock().unwrap_or_else(|e| e.into_inner());
        slots.retain(|(id, ..)| id != chat.id());
        slots.push((chat.id().to_string(), provider == claude_code::ID, tx));
    }
    let _control = ControlGuard(chat.id().to_string());
    let reply = if provider == claude_code::ID {
        let mode = claude_code::ChatMode::from_setting(&settings.claude_code_chat_mode);
        claude_code::send(app, chat, &model, mode, query, context, &settings.chat_work_dir, rx).await
    } else {
        let answer = async {
            if provider == ANTHROPIC || provider.is_empty() {
                claude::send(chat, &model, query, context).await
            } else if let Some(p) = openai_compat::provider(provider) {
                openai_compat::send(chat, p, &model, query, context).await
            } else if let Some(server) = local_chat::server(settings, provider) {
                local_chat::send(app, chat, &server, &model, query, context).await
            } else {
                Err(format!("Unknown chat provider: {provider}"))
            }
        };
        // Stop drops the request; the island keeps what streamed so far
        // (nothing is recorded, so the next turn doesn't see it).
        let stop = async {
            while let Some(c) = rx.recv().await {
                if matches!(c, TurnControl::Stop) {
                    return;
                }
            }
            std::future::pending::<()>().await
        };
        tokio::select! {
            r = answer => r,
            _ = stop => return Ok(ChatReply { text: String::new(), stopped: true, conv: chat.id().to_string() }),
        }
    }?;
    let saved_as = if provider.is_empty() { ANTHROPIC } else { provider };
    if let Some(record) = chat.snapshot(&probe, saved_as, &model, &title) {
        if let Err(e) = crate::history::save_stored(&record) {
            crate::log::line(format!("chat: could not save the chat: {e}"));
        }
    }
    Ok(ChatReply { conv: chat.id().to_string(), ..reply })
}

/// The models `provider` offers. Asked only when the user opens the picker on
/// that provider, and only once it has a key (or, for a local server, an
/// address): nothing is sent anywhere before that.
pub async fn models(settings: &Settings, provider: &str) -> Result<Vec<ModelInfo>, String> {
    let no_key = || crate::i18n::t("No API key — add it in Settings.");
    if provider == ANTHROPIC {
        let key = secrets::get(claude::KEY).ok_or_else(no_key)?;
        return claude::models(&key).await;
    }
    if provider == claude_code::ID {
        return Ok(claude_code::models());
    }
    if let Some(p) = openai_compat::provider(provider) {
        let key = secrets::get(p.key).ok_or_else(no_key)?;
        return openai_compat::models(p, &key).await;
    }
    if let Some(server) = local_chat::server(settings, provider) {
        return local_chat::models(&server).await;
    }
    Err(format!("Unknown chat provider: {provider}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn turn_texts(history: &[Value]) -> Vec<(String, Value)> {
        history
            .iter()
            .map(|m| (m["role"].as_str().unwrap().to_string(), m["content"].clone()))
            .collect()
    }

    #[test]
    fn a_turn_is_recorded_only_once_it_succeeds() {
        let chat = Chat::default();
        let t = chat.begin("anthropic");
        assert!(t.first);
        assert!(t.history.is_empty());
        // A failed turn records nothing: the next one is still the first.
        let t = chat.begin("anthropic");
        assert!(t.first);
        chat.commit(&t, json!({"role":"user","content":[{"type":"text","text":"hi"}]}), json!({"role":"assistant","content":[{"type":"text","text":"hello"}]}), "hi", "hello");
        let t = chat.begin("anthropic");
        assert!(!t.first);
        assert_eq!(t.history.len(), 2);
        assert!(t.history[0]["content"].is_array());
    }

    #[test]
    fn switching_provider_never_sends_claude_blocks_to_another_one() {
        let chat = Chat::default();
        let t = chat.begin("anthropic");
        let blocks = json!([
            {"type":"server_tool_use","id":"srvtoolu_1","name":"web_search","input":{"query":"x"}},
            {"type":"web_search_tool_result","tool_use_id":"srvtoolu_1","content":[]},
            {"type":"text","text":"Found it."}
        ]);
        chat.commit(&t, json!({"role":"user","content":[{"type":"text","text":"look"}]}), json!({"role":"assistant","content":blocks}), "look", "Found it.");

        let t = chat.begin("openai");
        assert!(!t.first);
        assert_eq!(
            turn_texts(&t.history),
            vec![("user".into(), json!("look")), ("assistant".into(), json!("Found it."))]
        );
        let raw = serde_json::to_string(&t.history).unwrap();
        assert!(!raw.contains("web_search"), "{raw}");

        // And back: Claude gets the plain turns too, including OpenAI's answer.
        chat.commit(&t, json!({"role":"user","content":"more"}), json!({"role":"assistant","content":"Sure."}), "more", "Sure.");
        let t = chat.begin("anthropic");
        assert_eq!(t.history.len(), 4);
        assert_eq!(t.history[3], json!({"role":"assistant","content":"Sure."}));
        assert!(!serde_json::to_string(&t.history).unwrap().contains("web_search"));
    }

    #[test]
    fn an_answer_that_lands_after_a_reset_or_a_switch_is_dropped() {
        let chat = Chat::default();
        let t = chat.begin("openai");
        chat.reset();
        chat.commit(&t, json!({"role":"user","content":"q"}), json!({"role":"assistant","content":"a"}), "q", "a");
        assert!(chat.begin("openai").first);

        let t = chat.begin("openai");
        let _other = chat.begin("google");
        chat.commit(&t, json!({"role":"user","content":"q"}), json!({"role":"assistant","content":"a"}), "q", "a");
        assert!(chat.begin("google").first);
    }

    #[test]
    fn a_turn_with_messages_typed_meanwhile_is_recorded_as_shown() {
        let chat = Chat::default();
        let t = chat.begin("claudecode");
        let turns = |v: &[(&'static str, &str)]| v.iter().map(|(r, s)| (*r, s.to_string())).collect::<Vec<_>>();
        chat.commit_turns(&t, &turns(&[("user", "q"), ("assistant", "a1"), ("user", "m"), ("assistant", "a2")]));
        let roles: Vec<_> = chat.plain_turns().iter().map(|x| format!("{}:{}", x["role"].as_str().unwrap(), x["content"].as_str().unwrap())).collect();
        assert_eq!(roles, ["user:q", "assistant:a1", "user:m", "assistant:a2"]);
        // Taken in before anything was said: one question, roles still alternate.
        let t = chat.begin("claudecode");
        chat.commit_turns(&t, &turns(&[("user", "q2"), ("assistant", " "), ("user", "m2"), ("assistant", "a3")]));
        let plain = chat.plain_turns();
        assert_eq!(plain.len(), 6);
        assert_eq!(plain[4]["content"], "q2\n\nm2");
        assert_eq!(chat.begin("claudecode").history.len(), 6);
    }

    #[test]
    fn the_claude_code_session_is_resumed_only_while_it_saw_every_turn() {
        let chat = Chat::default();
        let t = chat.begin("claudecode");
        assert_eq!(chat.cli_session(&t), None);
        chat.commit(&t, json!({"role":"user","content":"q"}), json!({"role":"assistant","content":"a"}), "q", "a");
        chat.set_cli_session(&t, "s-1", &crate::claude_code::default_dir());
        let t = chat.begin("claudecode");
        assert_eq!(chat.cli_session(&t).as_deref(), Some("s-1"));
        // Another provider answers: the session missed that turn.
        let o = chat.begin("openai");
        chat.commit(&o, json!({"role":"user","content":"q2"}), json!({"role":"assistant","content":"a2"}), "q2", "a2");
        let t = chat.begin("claudecode");
        assert_eq!(chat.cli_session(&t), None);
        assert_eq!(t.history.len(), 4);
        // New chat forgets it.
        chat.commit(&t, json!({"role":"user","content":"q3"}), json!({"role":"assistant","content":"a3"}), "q3", "a3");
        chat.set_cli_session(&t, "s-2", &crate::claude_code::default_dir());
        assert_eq!(chat.cli_session(&chat.begin("claudecode")).as_deref(), Some("s-2"));
        chat.reset();
        assert_eq!(chat.cli_session(&chat.begin("claudecode")), None);
    }

    #[test]
    fn a_conversation_keeps_its_folder_and_moving_it_starts_a_session_there() {
        let chat = Chat::default();
        let own = crate::claude_code::default_dir();
        let proj = std::path::PathBuf::from("/tmp/some-project");
        // Not pinned yet: it follows the setting.
        assert_eq!(chat.work_dir(), None);
        let t = chat.begin("claudecode");
        chat.commit(&t, json!({"role":"user","content":"q"}), json!({"role":"assistant","content":"a"}), "q", "a");
        chat.set_cli_session(&t, "s-1", &own);
        assert_eq!(chat.work_dir().as_deref(), Some(own.as_path()));
        assert_eq!(chat.cli_dir(), own);
        // The same folder again: nothing moves.
        assert!(!chat.set_work_dir(&own));
        // Another folder: the session can't follow (a new one starts there).
        assert!(chat.set_work_dir(&proj));
        assert_eq!(chat.work_dir().as_deref(), Some(proj.as_path()));
        let t = chat.begin("claudecode");
        chat.commit(&t, json!({"role":"user","content":"q2"}), json!({"role":"assistant","content":"a2"}), "q2", "a2");
        chat.set_cli_session(&t, "s-2", &proj);
        assert_eq!(chat.cli_dir(), proj);
        // Saved with the chat: its folder, and where its outside session lives.
        let saved = chat.snapshot(&t, "claudecode", "m", "q").unwrap();
        assert_eq!(saved.work_dir.as_deref(), Some("/tmp/some-project"));
        assert_eq!(saved.cli_dirs.get("s-2").map(String::as_str), Some("/tmp/some-project"));
        assert!(!saved.cli_dirs.contains_key("s-1"));
        assert_eq!(saved.cli_session.as_deref(), Some("s-2"));
    }

    #[test]
    fn a_reopened_session_moved_out_of_its_folder_becomes_a_coucou_chat() {
        let chat = Chat::default();
        let cwd = std::path::PathBuf::from("/tmp/their-project");
        chat.open(&crate::history::Opened {
            turns: vec![json!({"role":"user","content":"q"}), json!({"role":"assistant","content":"a"})],
            provider: "claudecode".into(),
            model: String::new(),
            title: "t".into(),
            external: Some(External { session: "x-1".into(), cwd: cwd.clone(), project: "their-project".into() }),
            cli_session: Some("x-1".into()),
            stored: None,
            import_key: None,
            work_dir: Some(cwd.clone()),
            cli_dir: Some(cwd.clone()),
        });
        assert!(chat.external(&chat.begin("claudecode")).is_some());
        assert!(!chat.set_work_dir(&cwd));
        assert!(chat.external(&chat.begin("claudecode")).is_some());
        assert!(chat.set_work_dir(std::path::Path::new("/tmp/elsewhere")));
        assert!(chat.external(&chat.begin("claudecode")).is_none());
        assert_eq!(chat.current_key(), None);
    }

    fn talk(chats: &Chats, q: &str) -> String {
        let chat = chats.current();
        chats.talked(chat.id());
        let t = chat.begin("openai");
        chat.commit(&t, json!({"role":"user","content":q}), json!({"role":"assistant","content":"a"}), q, "a");
        chat.id().to_string()
    }

    #[test]
    fn conversations_talked_in_stay_open_side_by_side() {
        let chats = Chats::default();
        let first = chats.current().id().to_string();
        assert!(first.starts_with("c-") && first.len() <= 24);
        assert!(chats.list().is_empty(), "nothing said yet: no mini");
        // New chat on a blank one reuses it.
        assert_eq!(chats.new_conversation(), first);
        let a = talk(&chats, "about apples");
        let b_id = chats.new_conversation();
        assert_ne!(a, b_id);
        let b = talk(&chats, "about bees");
        assert_eq!(b, b_id);
        let list = chats.list();
        assert_eq!(list.len(), 2);
        assert_eq!(list[0]["title"], "about apples");
        assert_eq!(list[1]["current"], true);
        // Each keeps its own turns.
        assert!(chats.switch(&a));
        assert_eq!(chats.current().plain_turns()[0]["content"], "about apples");
        assert_eq!(chats.get(Some(&b)).unwrap().plain_turns()[0]["content"], "about bees");
        // A blank one only looked at goes when another becomes current.
        let blank = chats.new_conversation();
        assert!(chats.switch(&b));
        assert!(chats.get(Some(&blank)).is_err());
        assert_eq!(chats.list().len(), 2);
    }

    #[test]
    fn retiring_closes_a_conversation_and_never_leaves_none_current() {
        let chats = Chats::default();
        let a = talk(&chats, "one");
        chats.new_conversation();
        let b = talk(&chats, "two");
        assert_eq!(chats.retire(&a), b);
        assert!(chats.get(Some(&a)).is_err());
        let now = chats.retire(&b);
        assert_ne!(now, b);
        assert_eq!(chats.current().id(), now);
        assert!(chats.current().is_blank());
        assert!(chats.list().is_empty());
        assert!(!control(&b, TurnControl::Stop), "no turn runs there");
    }

    #[test]
    fn the_prompt_greets_by_first_name_and_claims_web_search_only_for_claude() {
        let p = system_prompt_for(Some("Louis"), true);
        assert!(p.starts_with("You are Robo, Louis's personal AI assistant living at the top of their screen."));
        assert!(p.contains("web search access"));
        assert!(p.contains("light Markdown"));
        let p = system_prompt_for(None, false);
        assert!(p.starts_with("You are Robo, a personal AI assistant living at the top of the user's screen."));
        assert!(!p.contains("web search"));
        assert!(p.contains("no web access"));
    }

    #[test]
    fn context_goes_with_the_first_question_only() {
        let file = ChatContext::File { name: "a.txt".into(), path: "/x/a.txt".into() };
        assert_eq!(plain_question(true, Some(&file), "why?"), "File: a.txt\n\nwhy?");
        assert_eq!(plain_question(false, Some(&file), "why?"), "why?");
        let win = ChatContext::Window { app_name: "Code".into(), title: "main.rs".into(), url: None };
        assert_eq!(plain_question(true, Some(&win), "q"), "Context — App: Code, Window: main.rs\n\nq");
        assert_eq!(window_line("Edge", "Docs", Some("https://x.dev")), "Context — App: Edge, Window: Docs, URL: https://x.dev");
    }

    #[test]
    fn the_model_comes_from_the_settings_or_the_provider_default() {
        let mut s = Settings::default();
        assert_eq!(model_for(&s, "anthropic"), claude::DEFAULT_MODEL);
        assert_eq!(model_for(&s, "openai"), openai_compat::provider("openai").unwrap().default_model);
        assert_eq!(model_for(&s, "ollama"), "");
        assert_eq!(model_for(&s, "claudecode"), claude_code::DEFAULT_MODEL);
        s.chat_models.insert("openai".into(), " gpt-x ".into());
        s.chat_models.insert("ollama".into(), "llama3.2".into());
        s.model = "claude-haiku-4-5".into();
        assert_eq!(model_for(&s, "openai"), "gpt-x");
        assert_eq!(model_for(&s, "ollama"), "llama3.2");
        assert_eq!(model_for(&s, "anthropic"), "claude-haiku-4-5");
    }

    #[test]
    fn only_files_in_the_inbox_ride_along() {
        let base = std::env::temp_dir().join(format!("robo-chat-ctx-{}", std::process::id()));
        let inbox = base.join("inbox");
        std::fs::create_dir_all(inbox.join("sub")).unwrap();
        std::fs::write(inbox.join("a.txt"), b"a").unwrap();
        std::fs::write(base.join("secret.txt"), b"s").unwrap();
        std::fs::write(inbox.join("sub").join("b.txt"), b"b").unwrap();
        assert!(is_inside(&inbox, &inbox.join("a.txt")));
        assert!(!is_inside(&inbox, &base.join("secret.txt")));
        assert!(!is_inside(&inbox, &inbox.join("..").join("secret.txt")));
        assert!(!is_inside(&inbox, &inbox.join("sub").join("b.txt")));
        assert!(!is_inside(&inbox, &inbox.join("missing.txt")));
        assert!(!is_inside(&inbox, &inbox));
        // A dropped folder (copied whole into the inbox) rides along too.
        assert!(is_inside(&inbox, &inbox.join("sub")));
        assert!(!is_inside(&inbox, &base));
        #[cfg(unix)]
        {
            std::os::unix::fs::symlink(base.join("secret.txt"), inbox.join("link.txt")).unwrap();
            assert!(!is_inside(&inbox, &inbox.join("link.txt")));
            std::fs::create_dir_all(base.join("private")).unwrap();
            std::os::unix::fs::symlink(base.join("private"), inbox.join("linkdir")).unwrap();
            assert!(!is_inside(&inbox, &inbox.join("linkdir")));
        }
        let _ = std::fs::remove_dir_all(&base);
    }
}
