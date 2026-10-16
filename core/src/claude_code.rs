// Chat through the user's own Claude Code CLI and subscription (port only, no
// upstream equivalent): no API key, the `claude` command answers.
//
// Each turn runs `claude -p` once, in a private folder, with the prompt on
// stdin and the answer read as stream-json. The first turn starts a session;
// later turns `--resume` it, so the CLI keeps the conversation. "New chat"
// forgets the session (Chat::reset).
//
// The run is fenced in: hooks off (Coucou's own hooks must never see the chat,
// --settings disableAllHooks plus --safe-mode, which also skips CLAUDE.md,
// plugins and MCP servers) and no MCP servers. What it may do is the chat
// mode picked in the chat view (settings `claudeCodeChatMode`, ChatMode):
// "Read only" keeps the read-only tools and dontAsk (anything outside the
// working folders is refused rather than asked); "Ask", "Edit files" and
// "Auto" give it the everyday tools and `--permission-prompt-tool stdio`:
// whatever needs approval — and every AskUserQuestion, which print mode only
// offers when someone can answer — comes back on the CLI's stdout as a
// `can_use_tool` control request, goes up as the island's Allow/Deny or
// question card (pipe::ask_island), and the click goes back on stdin. No hook
// and no relay are involved, so nothing of the chat reaches the island's
// sessions. The working folder is the private chat folder unless the user
// picked another (port, his ask: settings `chatWorkDir`, the chat's folder
// chip); each conversation keeps the folder its session lives in (Claude Code
// resumes a session only from its own folder: a conversation moved to another
// one starts a new session there, the earlier turns going along as a
// transcript). A dropped file is reached by adding the inbox as a working
// folder and naming the copy's path in the message.
//
// The streamed text goes to the island as `chat-delta` events exactly like
// local_chat.rs; the reply is the finished text. The process is killed with
// its whole group on timeout, on error, and when the request is dropped; it
// also dies with ambxst-robo (PR_SET_PDEATHSIG).

use std::future::Future;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::{Duration, Instant};

use serde_json::{json, Value};
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};

use crate::chat::{self, Chat, ChatContext, ChatReply, ModelInfo, TurnControl};
use crate::host::{AppHandle, WINDOW_LABEL};
use crate::i18n::t;

pub const ID: &str = "claudecode";
pub const DEFAULT_MODEL: &str = "claude-sonnet-5-5";

/// The models the picker lists: exact ids (the only ones that reach --model).
const MODELS: &[(&str, &str)] = &[
    ("claude-fable-5-1", "Claude Fable 5.1"),
    ("claude-opus-5-5", "Claude Opus 5.5"),
    ("claude-sonnet-5-5", "Claude Sonnet 5.5"),
    ("claude-haiku-4-5-20251001", "Claude Haiku 4.5"),
];

/// The CLI's bare aliases an earlier build saved, and the exact id each now is.
const LEGACY_ALIASES: &[(&str, &str)] = &[
    ("sonnet", "claude-sonnet-5-5"),
    ("opus", "claude-opus-5-5"),
    ("haiku", "claude-haiku-4-5-20251001"),
    ("fable", "claude-fable-5-1"),
];

/// One whole turn, tool calls and the island's permission cards (up to 108 s
/// each) included.
// Port: long agentic turns (he works with Claude through this chat) ran
// past upstream's 10 min and were cut off; the stop button ends a turn now.
const TIMEOUT: Duration = Duration::from_secs(4 * 3600);
/// The island is told about new text at most this often (as local_chat.rs).
const DELTA_INTERVAL: Duration = Duration::from_millis(1000 / 15);
const MAX_LINE: usize = 4 * 1024 * 1024;
const MAX_ANSWER: usize = 4 * 1024 * 1024;
const MAX_STDERR: usize = 16 * 1024;

/// "Read only": the tools that cannot change anything. No Bash, Edit, Write, WebFetch.
const READ_TOOLS: &str = "Read,Glob,Grep";
/// The other modes: the everyday tools, each gated by the permission mode
/// (and the island's card), plus AskUserQuestion and (port, his call) Agent:
/// helpers work in the chat too, each on a pill of its own (HookFeed), their
/// requests on the same cards. No MCP.
const FULL_TOOLS: &str = "Read,Glob,Grep,Bash,Edit,Write,WebFetch,WebSearch,AskUserQuestion,Agent";

pub const DEFAULT_MODE: &str = "ask";

/// What the chat's runs may do (settings `claudeCodeChatMode`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ChatMode {
    /// Read-only tools, `dontAsk`: what needs approval is refused (the chat
    /// as it first shipped).
    ReadOnly,
    /// `default` permissions: reads in the working folders run, everything
    /// else comes up as the island's Allow/Deny card.
    Ask,
    /// `acceptEdits`: edits (and mkdir/touch/mv/cp…) in the working folders
    /// run without asking; the rest comes up as the card.
    Edit,
    /// Claude Code's own auto mode: its safety classifier approves routine
    /// actions and blocks risky ones; questions still come up as the card.
    /// Never bypassPermissions.
    Auto,
}

impl ChatMode {
    /// The stored value; anything unknown is the safest mode.
    pub fn from_setting(value: &str) -> Self {
        match value.trim() {
            "ask" => Self::Ask,
            "edit" => Self::Edit,
            "auto" => Self::Auto,
            _ => Self::ReadOnly,
        }
    }

    fn permission_mode(self) -> &'static str {
        match self {
            Self::ReadOnly => "dontAsk",
            // "default" is the config value of what the CLI now calls Manual;
            // every version accepts it.
            Self::Ask => "default",
            Self::Edit => "acceptEdits",
            Self::Auto => "auto",
        }
    }

    fn tools(self) -> &'static str {
        if self == Self::ReadOnly { READ_TOOLS } else { FULL_TOOLS }
    }

    /// Requests that need a human reach the island (`--permission-prompt-tool stdio`).
    fn prompts(self) -> bool {
        self != Self::ReadOnly
    }
}

/// Environment of the session that may have started ambxst-robo (a terminal
/// inside Claude Code): none of it must leak into the chat's own runs. And
/// an API key in the environment would bill it instead of the subscription.
const SCRUB_ENV: &[&str] = &[
    "CLAUDECODE",
    "CLAUDE_PID",
    "CLAUDE_EFFORT",
    "AI_AGENT",
    "CLAUDE_CODE_ENTRYPOINT",
    "CLAUDE_CODE_SESSION_ID",
    "CLAUDE_CODE_CHILD_SESSION",
    "CLAUDE_CODE_BRIDGE_SESSION_ID",
    "CLAUDE_CODE_SESSION_ATTENDED",
    "CLAUDE_CODE_MESSAGING_SOCKET",
    "CLAUDE_CODE_MESSAGING_TOKEN",
    "CLAUDE_CODE_EXECPATH",
    "CLAUDE_CODE_SSE_PORT",
    "ANTHROPIC_API_KEY",
    "ANTHROPIC_AUTH_TOKEN",
];

pub fn models() -> Vec<ModelInfo> {
    MODELS.iter().map(|(id, label)| ModelInfo { id: (*id).into(), label: (*label).into() }).collect()
}

/// The exact id a saved bare alias ("sonnet") stands for, if it is one.
pub fn migrate_model(model: &str) -> Option<&'static str> {
    LEGACY_ALIASES.iter().find(|(alias, _)| *alias == model.trim()).map(|(_, id)| *id)
}

/// A listed id (or a legacy alias, as its id), else the default: only the
/// listed ids ever reach the command line.
fn model_arg(model: &str) -> &'static str {
    let model = migrate_model(model).unwrap_or(model.trim());
    MODELS.iter().find(|(id, _)| *id == model).map(|(id, _)| *id).unwrap_or(DEFAULT_MODEL)
}

/// Port (his ask): Coucou's own working folder for the chat, as a path
/// (`work_dir` makes it).
pub(crate) fn default_dir() -> PathBuf {
    crate::history::own_cli_dir()
}

/// Port (his ask): the `chatWorkDir` setting as a folder; None = Coucou's own
/// (empty, not absolute, or a folder that is gone).
pub(crate) fn setting_dir(setting: &str) -> Option<PathBuf> {
    let s = setting.trim();
    if s.is_empty() {
        return None;
    }
    let p = PathBuf::from(s);
    (p.is_absolute() && p.is_dir()).then_some(p)
}

/// Port (his ask): a folder the user picked, checked: an existing folder,
/// given as an absolute path; its real path (what Claude Code names its
/// project after).
pub(crate) fn checked_dir(path: &str) -> Result<PathBuf, String> {
    let p = Path::new(path.trim());
    if !p.is_absolute() {
        return Err(t("Pick a folder by its full path."));
    }
    let real = std::fs::canonicalize(p).map_err(|e| format!("{}: {e}", p.display()))?;
    if !real.is_dir() {
        return Err(t("That is not a folder."));
    }
    Ok(real)
}

/// ~/.local/share/ambxst-robo/chat-claudecode, private to the user.
pub(crate) fn work_dir() -> Result<PathBuf, String> {
    let dir = default_dir();
    let mut builder = std::fs::DirBuilder::new();
    builder.recursive(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::DirBuilderExt;
        builder.mode(0o700);
    }
    builder.create(&dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700));
    }
    Ok(dir)
}

/// The `claude` command: on PATH, else where its installers put it (the
/// systemd user unit's PATH often lacks ~/.local/bin).
pub(crate) fn find_binary() -> Option<PathBuf> {
    let is_exec = |p: &Path| {
        use std::os::unix::fs::PermissionsExt;
        std::fs::metadata(p).map(|m| m.is_file() && m.permissions().mode() & 0o111 != 0).unwrap_or(false)
    };
    if let Some(path) = std::env::var_os("PATH") {
        for dir in std::env::split_paths(&path) {
            let candidate = dir.join("claude");
            if is_exec(&candidate) {
                return Some(candidate);
            }
        }
    }
    let home = crate::platform::home_dir();
    [".local/bin/claude", ".claude/local/claude"]
        .iter()
        .map(|rel| home.join(rel))
        .find(|p| is_exec(p))
}

fn not_installed() -> String {
    t("Claude Code isn't installed: the claude command was not found.")
}

// ── The message ───────────────────────────────────────────────────────────────

fn system_prompt(mode: ChatMode) -> String {
    let tools = match mode {
        ChatMode::ReadOnly => "You can read a file the user dropped on the island with the Read tool; you cannot run commands, edit files or browse the web.",
        _ => "You can use your tools (read, search, run commands, edit files, fetch web pages). Anything that needs the user's approval appears as a permission card on the island and waits for their click; if they deny it, accept that and carry on without it. When the user should choose between options, ask with the AskUserQuestion tool: the island shows the choices as a card.",
    };
    format!("{} {tools}", chat::system_prompt(false))
}

/// What goes on stdin for one turn. The file or window context rides along
/// with the first question (as for every provider); a file by its path, for
/// the Read tool. `transcript` = earlier turns another provider answered,
/// when no session can be resumed.
fn prompt_text(first: bool, context: Option<&ChatContext>, transcript: &[Value], query: &str) -> String {
    let mut out = String::new();
    if !transcript.is_empty() {
        out.push_str("Earlier in this conversation:\n\n");
        for m in transcript {
            let who = if m["role"] == "assistant" { "Assistant" } else { "User" };
            let text = m["content"].as_str().unwrap_or_default();
            out.push_str(&format!("{who}: {text}\n\n"));
        }
        out.push_str("Now the user asks:\n\n");
    }
    // Port: a file dropped into an ongoing chat (his ask) goes with whichever
    // message comes next; a window's context stays the first message's.
    let context = context.filter(|c| first || matches!(c, ChatContext::File { .. }));
    match context {
        Some(ChatContext::File { name, path }) if std::path::Path::new(path).is_dir() => out.push_str(&format!(
            "Folder: {name}\nThe folder is at {path} — look through it with the Glob, Grep and Read tools when the question needs it.\n\n{query}"
        )),
        Some(ChatContext::File { name, path }) => out.push_str(&format!(
            "File: {name}\nThe file is at {path} — read it with the Read tool when the question needs it.\n\n{query}"
        )),
        Some(ChatContext::Window { app_name, title, url }) => {
            out.push_str(&format!("{}\n\n{query}", chat::window_line(app_name, title, url.as_deref())))
        }
        None => out.push_str(query),
    }
    out
}

fn command_args(model: &str, mode: ChatMode, resume: Option<&str>, extra_dir: Option<&Path>) -> Vec<String> {
    let mut args: Vec<String> = [
        "-p",
        "--input-format",
        "stream-json",
        "--output-format",
        "stream-json",
        "--verbose",
        "--include-partial-messages",
        // Port: each user message is echoed back once Claude Code takes it
        // in, so a message typed mid-turn is shown as sent only then.
        "--replay-user-messages",
        "--safe-mode",
        "--settings",
        r#"{"disableAllHooks":true}"#,
        "--strict-mcp-config",
        "--permission-mode",
        mode.permission_mode(),
        "--tools",
        mode.tools(),
        "--model",
    ]
    .iter()
    .map(|s| s.to_string())
    .collect();
    args.push(model_arg(model).to_string());
    if mode.prompts() {
        args.push("--permission-prompt-tool".into());
        args.push("stdio".into());
    }
    args.push("--system-prompt".into());
    args.push(system_prompt(mode));
    // The mode can change between turns of one conversation: its system
    // prompt must follow, not the one recorded on the first turn.
    args.push("--system-prompt-snapshot".into());
    args.push("off".into());
    if let Some(dir) = extra_dir {
        args.push("--add-dir".into());
        args.push(dir.display().to_string());
    }
    if let Some(id) = resume {
        args.push("--resume".into());
        args.push(id.to_string());
    }
    args
}

/// Port: what a reopened session is told about the island (appended to its
/// own system prompt, which stays the CLI's).
fn session_note(mode: ChatMode) -> &'static str {
    match mode {
        ChatMode::ReadOnly => "The user is continuing this session from Robo's chat in their notch, in read-only mode: you can read and search files but not run commands or edit.",
        _ => "The user is continuing this session from Robo's chat in their notch. Anything that needs their approval appears as a permission card there and waits for their click; if they deny it, accept that and carry on. When they should choose between options, ask with the AskUserQuestion tool.",
    }
}

/// Port: the arguments that continue one of the user's own Claude Code
/// sessions (`--resume`, run in its folder). Fenced like the chat's own runs
/// (hooks off, so Coucou never sees it twice; no MCP; the chat mode's tools
/// and permission mode, cards through stdio) but without --safe-mode or the
/// mascot prompt: it stays that project's session.
fn session_args(model: &str, mode: ChatMode, session: &str, extra_dir: Option<&Path>) -> Vec<String> {
    let mut args: Vec<String> = [
        "-p",
        "--input-format",
        "stream-json",
        "--output-format",
        "stream-json",
        "--verbose",
        "--include-partial-messages",
        // Port: each user message is echoed back once Claude Code takes it
        // in, so a message typed mid-turn is shown as sent only then.
        "--replay-user-messages",
        "--settings",
        r#"{"disableAllHooks":true}"#,
        "--strict-mcp-config",
        "--permission-mode",
        mode.permission_mode(),
        "--tools",
        mode.tools(),
        "--model",
    ]
    .iter()
    .map(|s| s.to_string())
    .collect();
    args.push(model_arg(model).to_string());
    if mode.prompts() {
        args.push("--permission-prompt-tool".into());
        args.push("stdio".into());
    }
    args.push("--append-system-prompt".into());
    args.push(session_note(mode).into());
    if let Some(dir) = extra_dir {
        args.push("--add-dir".into());
        args.push(dir.display().to_string());
    }
    args.push("--resume".into());
    args.push(session.to_string());
    args
}

// ── The stream ────────────────────────────────────────────────────────────────

#[derive(Debug, PartialEq)]
enum Line {
    /// `system/init`: the session this run belongs to.
    Session(String),
    /// A new assistant message begins (after a tool call, say).
    MessageStart,
    TextDelta(String),
    /// The run is over: the final text, or the error.
    Result { error: bool, text: String, session: Option<String> },
    Other,
}

fn parse_line(line: &str) -> Line {
    let Ok(v) = serde_json::from_str::<Value>(line) else { return Line::Other };
    let session = v.get("session_id").and_then(Value::as_str).map(str::to_string);
    match v.get("type").and_then(Value::as_str) {
        Some("system") if v.get("subtype").and_then(Value::as_str) == Some("init") => {
            session.map(Line::Session).unwrap_or(Line::Other)
        }
        Some("stream_event") => {
            let event = &v["event"];
            match event.get("type").and_then(Value::as_str) {
                Some("message_start") => Line::MessageStart,
                Some("content_block_delta") if event.pointer("/delta/type").and_then(Value::as_str) == Some("text_delta") => {
                    Line::TextDelta(event.pointer("/delta/text").and_then(Value::as_str).unwrap_or_default().to_string())
                }
                _ => Line::Other,
            }
        }
        Some("result") => {
            let error = v.get("is_error").and_then(Value::as_bool).unwrap_or(false)
                || v.get("subtype").and_then(Value::as_str).is_some_and(|s| s != "success");
            let mut text = v.get("result").and_then(Value::as_str).unwrap_or_default().to_string();
            if text.is_empty() {
                if let Some(errors) = v.get("errors").and_then(Value::as_array) {
                    text = errors.iter().filter_map(Value::as_str).collect::<Vec<_>>().join("\n");
                }
            }
            Line::Result { error, text, session }
        }
        _ => Line::Other,
    }
}

/// The error the island shows for what the CLI reported.
fn friendly_error(raw: &str) -> String {
    let text = raw.trim();
    let lower = text.to_lowercase();
    if lower.contains("/login") || lower.contains("not logged in") || lower.contains("invalid api key") || lower.contains("oauth token") {
        return t("Claude Code isn't logged in. Run claude in a terminal and log in, then try again.");
    }
    if text.is_empty() {
        return t("Claude Code stopped without answering.");
    }
    // Rate limits ("You've hit your limit · resets 5pm", "usage limit reached")
    // and everything else read fine as they are.
    format!("Claude Code: {text}")
}

/// What one run produced, read from its stdout lines.
#[derive(Default)]
struct Reader {
    session: Option<String>,
    /// The current assistant message's text, as streamed.
    current: String,
    /// `current` is what the last result already gave (no message began since).
    answered: bool,
    result: Option<Result<String, String>>,
}

impl Reader {
    /// Returns true when the visible text changed.
    fn feed(&mut self, line: &str) -> bool {
        match parse_line(line) {
            Line::Session(id) => {
                self.session = Some(id);
                false
            }
            Line::MessageStart => {
                // Text before a tool call is replaced by what follows it, so the
                // streamed text always ends as the final answer.
                self.current.clear();
                self.answered = false;
                false
            }
            Line::TextDelta(text) => {
                self.current.push_str(&text);
                !text.is_empty()
            }
            Line::Result { error, text, session } => {
                if session.is_some() {
                    self.session = session;
                }
                self.answered = true;
                self.result = Some(if error {
                    Err(friendly_error(&text))
                } else if text.trim().is_empty() {
                    Ok(self.current.trim().to_string())
                } else {
                    Ok(text.trim().to_string())
                });
                false
            }
            Line::Other => false,
        }
    }
}

// ── Permission requests (control protocol on stdin/stdout) ────────────────────

/// The one line on stdin that asks the question (stream-json input).
fn user_message(prompt: &str) -> String {
    json!({
        "type": "user",
        "message": { "role": "user", "content": prompt },
        "parent_tool_use_id": null,
        "session_id": "",
    })
    .to_string()
}

/// Port: the text of a user message Claude Code echoes back as it takes it
/// in (`--replay-user-messages`): a `user` line with `isReplay`, its content a
/// string or text blocks. None for anything else (tool results included).
fn replayed_text(line: &str) -> Option<String> {
    if !line.contains("\"isReplay\"") {
        return None;
    }
    let v = serde_json::from_str::<Value>(line).ok()?;
    if v.get("type").and_then(Value::as_str) != Some("user") || v.get("isReplay").and_then(Value::as_bool) != Some(true) {
        return None;
    }
    match v.pointer("/message/content")? {
        Value::String(s) => Some(s.clone()),
        Value::Array(blocks) => {
            let texts: Vec<&str> = blocks
                .iter()
                .filter(|b| b.get("type").and_then(Value::as_str) == Some("text"))
                .filter_map(|b| b.get("text").and_then(Value::as_str))
                .collect();
            (!texts.is_empty()).then(|| texts.join("\n\n"))
        }
        _ => None,
    }
}

/// A `control_request` line: its id and request, else None.
fn control_request(v: &Value) -> Option<(String, &Value)> {
    if v.get("type").and_then(Value::as_str) != Some("control_request") {
        return None;
    }
    let id = v.get("request_id").and_then(Value::as_str)?.to_string();
    Some((id, v.get("request")?))
}

/// The line that answers control request `id` with `response`.
fn control_response(id: &str, response: Value) -> String {
    json!({ "type": "control_response", "response": { "subtype": "success", "request_id": id, "response": response } })
        .to_string()
}

fn control_error(id: &str, error: &str) -> String {
    json!({ "type": "control_response", "response": { "subtype": "error", "request_id": id, "error": error } }).to_string()
}

/// Longest string the island is shown for a request (as ambxst-robo-hook caps them).
const MAX_SHOWN: usize = 2_000;

/// A copy of a tool's input for the card: every string capped. What goes
/// back to the CLI is always the input as it came.
fn shown(value: &Value) -> Value {
    match value {
        Value::String(s) if s.len() > MAX_SHOWN => {
            let mut end = MAX_SHOWN;
            while !s.is_char_boundary(end) {
                end -= 1;
            }
            Value::String(format!("{}…", &s[..end]))
        }
        Value::Array(items) => Value::Array(items.iter().map(shown).collect()),
        Value::Object(map) => Value::Object(map.iter().map(|(k, v)| (k.clone(), shown(v))).collect()),
        other => other.clone(),
    }
}

const DENIED: &str = "The user denied this from Robo's island.";
const UNANSWERED: &str = "Nobody answered on Robo's island, so this was not allowed.";
const NOT_ANSWERED: &str = "The user did not answer the question.";

/// What the CLI is told for a `can_use_tool` request, given the island's
/// click (`allow` / `deny` / `{"answers":{…}}`, None = nobody answered).
/// Nothing is ever allowed without a click, and a question is answered only
/// with answers that fit exactly what was asked (ambxst-robo-hook's rule).
fn permission_response(tool: &str, input: &Value, decision: Option<&str>) -> Value {
    let deny = |message: &str| json!({ "behavior": "deny", "message": message });
    let Some(decision) = decision.map(str::trim) else {
        return deny(if tool == "AskUserQuestion" { NOT_ANSWERED } else { UNANSWERED });
    };
    if tool == "AskUserQuestion" {
        let answers = serde_json::from_str::<Value>(decision)
            .ok()
            .and_then(|v| v.get("answers").and_then(Value::as_object).cloned());
        return match (answers, input.as_object()) {
            (Some(answers), Some(asked)) if answers_fit(input, &answers) => {
                let mut updated = asked.clone();
                updated.insert("answers".into(), Value::Object(answers));
                json!({ "behavior": "allow", "updatedInput": updated })
            }
            _ => deny(NOT_ANSWERED),
        };
    }
    match decision {
        "allow" | "always" => json!({ "behavior": "allow", "updatedInput": input }),
        "deny" => deny(DENIED),
        _ => deny(UNANSWERED),
    }
}

/// True when `answers` answers exactly the questions Claude Code asked: one entry
/// per question, keyed by its text. A single-select answer is one of its option
/// labels or the user's own typed answer (Claude Code's "Other"); a multi-select
/// answer is a non-empty list of distinct strings, all option labels except at
/// most one typed answer (Claude Code 2.1.136+ takes the list, as the Mac sends
/// it). Claude Code's own validator takes any string up to 8192 characters and
/// at most options + 1 entries per list. Mirrored in ambxst-robo-hook reply.rs.
fn answers_fit(question: &Value, answers: &serde_json::Map<String, Value>) -> bool {
    let Some(items) = question.get("questions").and_then(Value::as_array) else { return false };
    if items.is_empty() || items.len() != answers.len() {
        return false;
    }
    items.iter().all(|item| {
        let Some(text) = item.get("question").and_then(Value::as_str) else { return false };
        let labels: Vec<&str> = item
            .get("options")
            .and_then(Value::as_array)
            .map(|opts| opts.iter().filter_map(|o| o.get("label").and_then(Value::as_str)).collect())
            .unwrap_or_default();
        let multi = item.get("multiSelect").and_then(Value::as_bool).unwrap_or(false);
        match answers.get(text) {
            Some(Value::String(pick)) if !multi => labels.contains(&pick.as_str()) || typed_answer_fits(pick),
            Some(Value::Array(raw)) if multi => {
                let picks: Vec<&str> = raw.iter().filter_map(Value::as_str).collect();
                let mut seen = picks.clone();
                seen.sort_unstable();
                seen.dedup();
                let typed: Vec<&&str> = picks.iter().filter(|p| !labels.contains(p)).collect();
                !picks.is_empty()
                    && picks.len() == raw.len()
                    && seen.len() == picks.len()
                    && picks.len() <= labels.len() + 1
                    && typed.len() <= 1
                    && typed.iter().all(|p| typed_answer_fits(p))
            }
            _ => false,
        }
    })
}

/// Longest typed ("Other") answer passed on, in characters (Claude Code takes 8192 UTF-16 units).
const MAX_TYPED_ANSWER: usize = 4_000;

/// A typed answer: something to read (not blank) and not too long.
fn typed_answer_fits(answer: &str) -> bool {
    !answer.trim().is_empty() && answer.chars().count() <= MAX_TYPED_ANSWER
}

/// Kills the run's whole process group unless it was reaped.
struct GroupGuard {
    pgid: i32,
    done: bool,
}

impl Drop for GroupGuard {
    fn drop(&mut self) {
        if !self.done && self.pgid > 0 {
            unsafe {
                libc::killpg(self.pgid, libc::SIGKILL);
            }
        }
    }
}

// ── One turn ──────────────────────────────────────────────────────────────────

pub async fn send(
    app: &AppHandle,
    chat: &Chat,
    model: &str,
    mode: ChatMode,
    query: String,
    context: Option<ChatContext>,
    work_dir_setting: &str,
    control: tokio::sync::mpsc::UnboundedReceiver<TurnControl>,
) -> Result<ChatReply, String> {
    let bin = find_binary().ok_or_else(not_installed)?;
    let turn = chat.begin(ID);
    let conv = chat.id().to_string();
    // Port: a Claude Code session reopened from the chats column runs in its
    // own folder, as itself (no mascot prompt, its project's CLAUDE.md).
    let external = chat.external(&turn);
    let dir = match &external {
        Some(ext) if !ext.cwd.is_dir() => return Err(t("This session's folder is gone, so it can't be continued.")),
        Some(ext) => ext.cwd.clone(),
        // Port (his ask): the conversation's own working folder, else the
        // setting's; one that is gone falls back to Coucou's, with a note.
        None => {
            let wanted = chat.work_dir().or_else(|| setting_dir(work_dir_setting)).unwrap_or_else(default_dir);
            if wanted == default_dir() {
                work_dir()?
            } else if wanted.is_dir() {
                wanted
            } else {
                let own = work_dir()?;
                let _ = chat.set_work_dir(&own);
                let note = crate::i18n::tf(
                    "The working directory {path} is gone: this chat continues in Robo's own folder.",
                    &[("path", &wanted.display().to_string())],
                );
                let _ = app.emit_to(WINDOW_LABEL, "chat-note", json!({ "conv": conv, "text": note }));
                own
            }
        }
    };
    // Port (his ask): Claude Code finds a session only from the folder it
    // lives in: a conversation moved to another one starts a new session
    // there, its earlier turns going along as a transcript.
    let resume = chat.cli_session(&turn).filter(|_| external.is_some() || chat.cli_dir() == dir);
    let transcript: &[Value] = if resume.is_none() { &turn.history } else { &[] };
    let prompt = prompt_text(turn.first, context.as_ref(), transcript, &query);
    let inbox = match &context {
        Some(ChatContext::File { .. }) => Some(crate::files::inbox_dir()),
        _ => None,
    };
    let args = match &external {
        Some(ext) => session_args(model, mode, &ext.session, inbox.as_deref()),
        None => command_args(model, mode, resume.as_deref(), inbox.as_deref()),
    };

    // Port: which conversation this is (chat.rs Chats): its text, hooks and
    // cards say so, so the island keeps each on its own mini (`conv`, above).
    let ran = run(
        &bin,
        &dir,
        &args,
        &prompt,
        &query,
        control,
        |visible| {
            let _ = app.emit_to(WINDOW_LABEL, "chat-delta", json!({ "conv": conv, "text": visible }));
        },
        // Port: a message typed meanwhile was taken in: the island moves it
        // from the queue into the log (the answer so far stays above it).
        |text| {
            let _ = app.emit_to(WINDOW_LABEL, "chat-injected", json!({ "conv": conv, "text": text }));
        },
        |hook| {
            // Port: a compaction's place is kept with the conversation.
            if hook["hook_event_name"] == "PostCompact" && hook.get("coucou_compact_error").is_none() {
                chat.note_compaction();
            }
            let _ = app.emit_to(WINDOW_LABEL, "hook", tag_conv(hook, &conv));
        },
        |mut card| {
            card["coucou_conv"] = json!(conv);
            let app = app.clone();
            async move { crate::pipe::ask_island_chat(&app, card).await }
        },
    )
    .await?;
    let Ran { answer, session, segments, unacked, stopped, compacted } = ran;
    if !unacked.is_empty() {
        crate::log::line(format!("chat: {} typed message(s) not taken in by the turn: the island sends them next", unacked.len()));
    }
    if answer.is_empty() && segments.is_empty() {
        // A `/compact` turn: the conversation goes on as it was (the marker
        // is kept by note_compaction), nothing to answer.
        if stopped || compacted {
            return Ok(ChatReply { text: String::new(), stopped: true, conv: String::new() });
        }
        return Err(t("No response text."));
    }
    // Port: messages typed while it worked that it took in are turns of
    // their own, where they came (as the log shows them); one it never took
    // in is not part of it: it is still in the island's queue, which sends
    // it as the next turn.
    let plain = chat::plain_question(turn.first, context.as_ref(), &query);
    let mut turns = vec![("user", plain)];
    for (before, typed) in segments {
        turns.push(("assistant", before));
        turns.push(("user", typed));
    }
    turns.push(("assistant", answer.clone()));
    chat.commit_turns(&turn, &turns);
    if let Some(id) = session {
        chat.set_cli_session(&turn, &id, &dir);
    }
    Ok(ChatReply { text: answer.clone(), stopped: stopped || answer.is_empty(), conv: String::new() })
}

// ── Port: the chat's activity, as hook events ────────────────────────────────

/// The chat's turns run with hooks off (no permission card twice), so the
/// island hears nothing of their work. This turns the CLI's stream into the
/// payloads Claude Code's own hooks send (UserPromptSubmit, PreToolUse,
/// PostToolUse / PostToolUseFailure), for the Claude Code pill as a terminal
/// session would. No PermissionRequest (the chat's stdio cards do that) and no
/// Stop: the chat ends its turn itself (`chat-turn-done`, without a second
/// sound or the "finished" alert over the chat).
#[derive(Debug, Default)]
struct HookFeed {
    prompt: String,
    cwd: String,
    session: Option<String>,
    prompted: bool,
    /// tool_use id → (name, input, helper tag), for the PostToolUse that answers it.
    tools: std::collections::HashMap<String, (String, Value, Option<String>)>,
    /// Port: the helpers (subagents) of this turn: Agent tool_use id → still running.
    helpers: std::collections::HashMap<String, bool>,
    /// Port: the conversation's size as of the last answer (its tokens in),
    /// for how long a compaction will take; whether one is under way.
    context: u64,
    compacting: bool,
    /// Port (his ask): the conversation was compacted this turn (a `/compact`
    /// turn has no answer: it is not an error, nor a finished one).
    compacted: bool,
}

/// Longest tool output passed on (the relay caps its fields too).
const MAX_HOOK_FIELD: usize = 4_000;

fn capped(v: &Value) -> Value {
    match v {
        Value::String(s) if s.chars().count() > MAX_HOOK_FIELD => Value::String(s.chars().take(MAX_HOOK_FIELD).collect()),
        Value::Array(a) => Value::Array(a.iter().map(capped).collect()),
        Value::Object(m) => Value::Object(m.iter().map(|(k, v)| (k.clone(), capped(v))).collect()),
        other => other.clone(),
    }
}

/// Port: a chat hook, tagged with its conversation: `coucou_conv`, and the
/// conversation's own agent tag (its pill, the mini) unless it is a helper's.
fn tag_conv(mut hook: Value, conv: &str) -> Value {
    if conv.is_empty() {
        return hook;
    }
    if let Some(m) = hook.as_object_mut() {
        m.insert("coucou_conv".into(), json!(conv));
        if !m.contains_key("coucou_agent") {
            m.insert("coucou_agent".into(), json!(conv));
        }
    }
    hook
}

/// Port: the agent tag a helper's events carry (`coucou_agent`, so the island
/// gives it a pill of its own, as it does any other agent): `h-` and the last
/// 8 characters of the id that names it, lowercased (validateAgent's rule).
pub fn helper_tag(id: &str) -> String {
    let tail: String = id.chars().rev().filter(char::is_ascii_alphanumeric).take(8).collect::<Vec<_>>().into_iter().rev().collect();
    format!("h-{}", tail.to_ascii_lowercase())
}

/// The text of a tool_result's content (a string, or text blocks).
fn result_text(content: &Value) -> String {
    match content {
        Value::String(s) => s.clone(),
        Value::Array(a) => a.iter().filter_map(|b| b.get("text").and_then(Value::as_str)).collect::<Vec<_>>().join("\n"),
        _ => String::new(),
    }
}

impl HookFeed {
    fn new(prompt: &str, cwd: &Path) -> Self {
        HookFeed { prompt: prompt.to_string(), cwd: cwd.display().to_string(), ..Default::default() }
    }

    fn payload(&self, event: &str) -> serde_json::Map<String, Value> {
        let mut m = serde_json::Map::new();
        m.insert("hook_event_name".into(), json!(event));
        m.insert("session_id".into(), json!(self.session.clone().unwrap_or_default()));
        m.insert("cwd".into(), json!(self.cwd));
        m.insert("coucou_chat".into(), json!(true));
        m
    }

    /// A helper's event: tagged with its agent, so its own pill takes it.
    fn helper_payload(&self, event: &str, helper: &str) -> serde_json::Map<String, Value> {
        let mut m = self.payload(event);
        m.insert("coucou_agent".into(), json!(helper_tag(helper)));
        m
    }

    /// A helper starts: its pill, named after the task it was given.
    fn helper_started(&mut self, id: &str, name: &str, kind: &str) -> Option<Value> {
        if self.helpers.contains_key(id) {
            return None;
        }
        self.helpers.insert(id.to_string(), true);
        let mut p = self.helper_payload("UserPromptSubmit", id);
        p.insert("prompt".into(), json!(name));
        p.insert("coucou_helper".into(), json!({ "name": name, "type": kind }));
        Some(Value::Object(p))
    }

    /// A helper is done: Stop on its pill (which then goes, as an agent's does).
    fn helper_done(&mut self, id: &str, summary: &str) -> Option<Value> {
        if self.helpers.get(id) != Some(&true) {
            return None;
        }
        self.helpers.insert(id.to_string(), false);
        let mut p = self.helper_payload("Stop", id);
        p.insert("last_assistant_message".into(), json!(summary.chars().take(MAX_HOOK_FIELD).collect::<String>()));
        Some(Value::Object(p))
    }

    /// The hook payloads one stream line stands for.
    fn feed(&mut self, line: &str) -> Vec<Value> {
        let Ok(v) = serde_json::from_str::<Value>(line) else { return Vec::new() };
        let mut out = Vec::new();
        if let Some(sid) = v.get("session_id").and_then(Value::as_str) {
            if self.session.is_none() {
                self.session = Some(sid.to_string());
            }
        }
        if self.session.is_some() && !self.prompted {
            self.prompted = true;
            let mut p = self.payload("UserPromptSubmit");
            p.insert("prompt".into(), json!(self.prompt.chars().take(MAX_HOOK_FIELD).collect::<String>()));
            out.push(Value::Object(p));
        }
        // A helper's own messages name the Agent call that started it.
        let parent = v.get("parent_tool_use_id").and_then(Value::as_str).map(str::to_string);
        let blocks = v.pointer("/message/content").and_then(Value::as_array).cloned().unwrap_or_default();
        let str_of = |k: &str| v.get(k).and_then(Value::as_str).unwrap_or_default().to_string();
        match v.get("type").and_then(Value::as_str) {
            Some("system") => match v.get("subtype").and_then(Value::as_str) {
                // Port (his ask): Claude Code compacting the conversation, as
                // the PreCompact / PostCompact hooks a terminal session sends.
                Some("status") => {
                    let status = v.get("status").and_then(Value::as_str);
                    if status == Some("compacting") && !self.compacting {
                        self.compacting = true;
                        let mut p = self.payload("PreCompact");
                        p.insert("trigger".into(), json!("auto"));
                        p.insert("coucou_context_tokens".into(), json!(self.context));
                        out.push(Value::Object(p));
                    } else if status != Some("compacting") && self.compacting && v.get("compact_error").is_some() {
                        self.compacting = false;
                        let mut p = self.payload("PostCompact");
                        p.insert("coucou_compact_error".into(), json!(str_of("compact_error")));
                        out.push(Value::Object(p));
                    }
                }
                Some("compact_boundary") => {
                    self.compacting = false;
                    self.compacted = true;
                    let mut p = self.payload("PostCompact");
                    let meta = v.get("compact_metadata").cloned().unwrap_or(Value::Null);
                    p.insert("trigger".into(), meta.get("trigger").cloned().unwrap_or(json!("auto")));
                    p.insert("coucou_pre_tokens".into(), meta.get("pre_tokens").cloned().unwrap_or(Value::Null));
                    out.push(Value::Object(p));
                }
                Some("task_started") => {
                    let id = str_of("tool_use_id");
                    if !id.is_empty() {
                        let name = str_of("description");
                        out.extend(self.helper_started(&id, &name, &str_of("subagent_type")));
                    }
                }
                Some("task_notification") => {
                    let id = str_of("tool_use_id");
                    out.extend(self.helper_done(&id, &str_of("summary")));
                }
                _ => {}
            },
            Some("assistant") => {
                // The conversation's size: what this answer was given to read.
                if parent.is_none() {
                    if let Some(u) = v.pointer("/message/usage") {
                        let n = |k: &str| u.get(k).and_then(Value::as_u64).unwrap_or(0);
                        let total = n("input_tokens") + n("cache_read_input_tokens") + n("cache_creation_input_tokens");
                        if total > 0 {
                            self.context = total;
                        }
                    }
                }
                for b in &blocks {
                    if b.get("type").and_then(Value::as_str) != Some("tool_use") {
                        continue;
                    }
                    let name = b.get("name").and_then(Value::as_str).unwrap_or("Tool").to_string();
                    let input = b.get("input").cloned().unwrap_or_else(|| json!({}));
                    if let Some(id) = b.get("id").and_then(Value::as_str) {
                        self.tools.insert(id.to_string(), (name.clone(), input.clone(), parent.clone()));
                        // A helper (synchronous, or before its task_started line);
                        // a helper's own helpers too.
                        if name == "Agent" || name == "Task" {
                            let desc = input.get("description").and_then(Value::as_str).unwrap_or("Helper").to_string();
                            let kind = input.get("subagent_type").and_then(Value::as_str).unwrap_or_default().to_string();
                            out.extend(self.helper_started(id, &desc, &kind));
                        }
                    }
                    let mut p = match &parent {
                        Some(h) => self.helper_payload("PreToolUse", h),
                        None => self.payload("PreToolUse"),
                    };
                    p.insert("tool_name".into(), json!(name));
                    p.insert("tool_input".into(), capped(&input));
                    out.push(Value::Object(p));
                }
            }
            Some("user") => {
                for b in &blocks {
                    if b.get("type").and_then(Value::as_str) != Some("tool_result") {
                        continue;
                    }
                    let Some(use_id) = b.get("tool_use_id").and_then(Value::as_str).map(str::to_string) else { continue };
                    let Some((name, input, helper)) = self.tools.remove(&use_id) else { continue };
                    let failed = b.get("is_error").and_then(Value::as_bool).unwrap_or(false);
                    let mut p = match &helper {
                        Some(h) => self.helper_payload(if failed { "PostToolUseFailure" } else { "PostToolUse" }, h),
                        None => self.payload(if failed { "PostToolUseFailure" } else { "PostToolUse" }),
                    };
                    p.insert("tool_name".into(), json!(name));
                    // The live diff needs an edit's strings whole (as the relay keeps them).
                    p.insert("tool_input".into(), input);
                    p.insert("tool_response".into(), capped(b.get("content").unwrap_or(&Value::Null)));
                    out.push(Value::Object(p));
                    // A synchronous helper's answer is its Agent call's result
                    // (a background one only says it was launched).
                    if name == "Agent" || name == "Task" {
                        let text = result_text(b.get("content").unwrap_or(&Value::Null));
                        if !text.starts_with("Async agent launched") {
                            out.extend(self.helper_done(&use_id, &text));
                        }
                    }
                }
            }
            _ => {}
        }
        out
    }

    /// The turn is over: the pill shows the answer's last line, quietly.
    /// The turn ends (or was stopped): helpers still shown as running finish.
    fn close_helpers(&mut self) -> Vec<Value> {
        let open: Vec<String> = self.helpers.iter().filter(|(_, running)| **running).map(|(id, _)| id.clone()).collect();
        open.iter().filter_map(|id| self.helper_done(id, "")).collect()
    }

    fn done(&self, answer: &str) -> Option<Value> {
        self.session.as_ref()?;
        let mut p = self.payload("ChatTurnDone");
        p.insert("last_assistant_message".into(), json!(answer.chars().take(MAX_HOOK_FIELD).collect::<String>()));
        Some(Value::Object(p))
    }
}

/// What one run of the CLI gave.
#[derive(Debug)]
struct Ran {
    answer: String,
    session: Option<String>,
    /// Port: messages typed while it worked that Claude Code took in, in
    /// order, each with what it had answered since the previous one (or the
    /// question): the turn goes q / a1 / m1 / a2 … / `answer`.
    segments: Vec<(String, String)>,
    /// Port: messages typed while it worked that it never took in (the turn
    /// was stopped, or ended first): the island sends them as the next turn.
    unacked: Vec<String>,
    /// Port: the user stopped it; `answer` is what came so far.
    stopped: bool,
    /// Port: the conversation was compacted during the turn.
    compacted: bool,
}

/// Port: how long the CLI may stay silent after its result while a typed
/// message is still unacknowledged (it takes it in about a second later).
const INJECTED_WAIT: Duration = Duration::from_secs(10);

/// How long a stopped CLI gets to end its turn by itself before it is killed.
const STOP_GRACE: Duration = Duration::from_secs(3);

/// Runs the CLI once: the answer and the session id, or the error to show.
/// `ask` puts a permission request or question in front of the user (the
/// card payload: tool_name, tool_input, description, session_id, cwd) and
/// gives the click back, None when nobody answered.
async fn run<A, F>(
    bin: &Path,
    dir: &Path,
    args: &[String],
    prompt: &str,
    hook_prompt: &str,
    mut control: tokio::sync::mpsc::UnboundedReceiver<TurnControl>,
    mut on_delta: impl FnMut(String),
    mut on_injected: impl FnMut(String),
    mut on_hook: impl FnMut(Value),
    mut ask: A,
) -> Result<Ran, String>
where
    A: FnMut(Value) -> F,
    F: Future<Output = Option<String>>,
{
    let mut cmd = tokio::process::Command::new(bin);
    cmd.args(args)
        .current_dir(dir)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true)
        .process_group(0);
    for var in SCRUB_ENV {
        cmd.env_remove(var);
    }
    unsafe {
        cmd.pre_exec(|| {
            // Dies with ambxst-robo, whatever way it goes.
            libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGKILL);
            Ok(())
        });
    }
    let mut child = cmd.spawn().map_err(|e| match e.kind() {
        std::io::ErrorKind::NotFound => not_installed(),
        _ => format!("Claude Code: {e}"),
    })?;
    let mut guard = GroupGuard { pgid: child.id().map(|p| p as i32).unwrap_or(0), done: false };

    let mut stdin = child.stdin.take().ok_or("no stdin")?;
    let stdout = child.stdout.take().ok_or("no stdout")?;
    let mut stderr = child.stderr.take().ok_or("no stderr")?;
    // stdin stays open for the whole turn: the answers to permission requests
    // go there. Closing it after the result is what ends the CLI.
    let first = format!("{}\n", user_message(prompt));
    stdin.write_all(first.as_bytes()).await.map_err(|e| format!("Claude Code: {e}"))?;
    stdin.flush().await.map_err(|e| format!("Claude Code: {e}"))?;
    let errors = tokio::spawn(async move {
        let mut buf = Vec::new();
        let _ = (&mut stderr).take(MAX_STDERR as u64).read_to_end(&mut buf).await;
        // Drain the rest so the CLI never blocks on a full pipe.
        let _ = tokio::io::copy(&mut stderr, &mut tokio::io::sink()).await;
        String::from_utf8_lossy(&buf).into_owned()
    });

    // Port: typed messages written to the CLI and not echoed back yet, and
    // the ones it took in (see Ran::segments).
    let mut unacked: std::collections::VecDeque<String> = std::collections::VecDeque::new();
    let mut segments: Vec<(String, String)> = Vec::new();
    let mut prompt_echoed = false;
    let mut stopping: Option<tokio::time::Instant> = None;
    // Port: answers given before background helpers finished (see the loop).
    let mut interim: Vec<String> = Vec::new();
    let mut hooks = HookFeed::new(hook_prompt, dir);
    let read = async {
        let mut reader = Reader::default();
        let mut lines = BufReader::new(stdout);
        let mut line = Vec::new();
        let mut last = Instant::now().checked_sub(DELTA_INTERVAL).unwrap_or_else(Instant::now);
        let mut sent_len = 0usize;
        let mut controls_open = true;
        let mut background = 0usize;
        // Helpers' completion notices, and the turns the CLI started after its
        // first: each notice brings a turn that answers it.
        let mut notices = 0usize;
        let mut turns_after_first = 0usize;
        let mut seen_init = false;
        let mut linger: Option<tokio::time::Instant> = None;
        loop {
            // Port: a line from the CLI, or the island's stop / typed message.
            // read_until keeps a partly read line in `line` if the other
            // branch wins, so it is only cleared once a line was handled.
            let grace = async {
                match stopping.or(linger) {
                    Some(at) => tokio::time::sleep_until(at).await,
                    None => std::future::pending::<()>().await,
                }
            };
            let n = tokio::select! {
                // No per-read cap here (a fresh Take each time would drop a partial
                // line on cancel); the size is checked once the line is in.
                r = lines.read_until(b'\n', &mut line) => r.map_err(|e| e.to_string())?,
                c = control.recv(), if controls_open => {
                    match c {
                        Some(TurnControl::Inject(text)) if stopping.is_none() => {
                            stdin.write_all(format!("{}\n", user_message(&text)).as_bytes()).await.map_err(|e| e.to_string())?;
                            stdin.flush().await.map_err(|e| e.to_string())?;
                            unacked.push_back(text);
                        }
                        Some(TurnControl::Stop) if stopping.is_none() => {
                            let req = json!({ "type": "control_request", "request_id": "robo-stop", "request": { "subtype": "interrupt" } });
                            stdin.write_all(format!("{req}\n").as_bytes()).await.map_err(|e| e.to_string())?;
                            stdin.flush().await.map_err(|e| e.to_string())?;
                            stopping = Some(tokio::time::Instant::now() + STOP_GRACE);
                        }
                        Some(_) => {}
                        None => controls_open = false,
                    }
                    continue;
                }
                _ = grace => break,
            };
            if n == 0 {
                break;
            }
            if line.len() > MAX_LINE {
                return Err(t("The server's answer is too large."));
            }
            let owned = String::from_utf8_lossy(&line).into_owned();
            line.clear();
            let text = owned.trim_end();
            if text.contains("\"control_request\"") {
                if let Ok(v) = serde_json::from_str::<Value>(text) {
                    if let Some((id, request)) = control_request(&v) {
                        let reply = if request.get("subtype").and_then(Value::as_str) == Some("can_use_tool") {
                            let tool = request.get("tool_name").and_then(Value::as_str).unwrap_or("Tool").to_string();
                            let input = request.get("input").cloned().unwrap_or_else(|| json!({}));
                            let card = json!({
                                "tool_name": tool,
                                "tool_input": shown(&input),
                                "description": request.get("description").and_then(Value::as_str).map(|d| shown(&json!(d))),
                                "session_id": reader.session.clone().unwrap_or_default(),
                                "cwd": dir.display().to_string(),
                            });
                            let decision = ask(card).await;
                            control_response(&id, permission_response(&tool, &input, decision.as_deref()))
                        } else {
                            control_error(&id, "not supported by Robo")
                        };
                        stdin.write_all(format!("{reply}\n").as_bytes()).await.map_err(|e| e.to_string())?;
                        stdin.flush().await.map_err(|e| e.to_string())?;
                        continue;
                    }
                }
            }
            for h in hooks.feed(text) {
                on_hook(h);
            }
            // Port: Claude Code took a typed message in (between two steps
            // of its turn, or as a turn of its own after its result): what it
            // had answered so far stays above it, and the answer starts over.
            if let Some(echo) = replayed_text(text) {
                let echo = echo.trim();
                let matches_next = unacked.front().is_some_and(|m| m.trim() == echo);
                // The first echo is the question's; after it, only the next
                // typed message's own text counts (it comes back as written).
                let is_prompt = !prompt_echoed && (echo == prompt.trim() || !matches_next);
                if is_prompt {
                    prompt_echoed = true;
                } else if let Some(taken) = matches_next.then(|| unacked.pop_front()).flatten() {
                    let mut before: Vec<String> = interim.drain(..).collect();
                    let current = reader.current.trim();
                    if !reader.answered && !current.is_empty() {
                        before.push(current.to_string());
                    }
                    reader.current.clear();
                    reader.answered = true;
                    reader.result = None;
                    sent_len = 0;
                    segments.push((before.join("\n\n"), taken.clone()));
                    on_injected(taken);
                }
                linger = None;
                continue;
            }
            let changed = reader.feed(text);
            if reader.current.len() > MAX_ANSWER {
                return Err(t("The server's answer is too large."));
            }
            // Port: also as soon as the stream moves on to something else (the
            // message's end, a tool call): the last characters of a sentence
            // used to wait out the whole tool run ("Okay I'll writ").
            let flush = !changed && !reader.current.is_empty() && reader.current.len() != sent_len;
            if (changed && last.elapsed() >= DELTA_INTERVAL) || flush {
                last = Instant::now();
                sent_len = reader.current.len();
                on_delta(reader.current.clone());
            }
            // Port: helpers running in the background end this result with
            // "I'll be notified"; the CLI answers again once they are done.
            // Closing stdin here killed them mid-task: keep reading until the
            // result that comes with none left, and keep the earlier answers.
            if text.contains("\"background_tasks_changed\"") {
                if let Ok(v) = serde_json::from_str::<Value>(text) {
                    background = v.get("tasks").and_then(Value::as_array).map_or(0, Vec::len);
                }
            }
            // Anything the CLI prints means it is still at it.
            linger = None;
            if text.starts_with("{\"type\":\"system\"") || text.contains("\"type\":\"system\"") {
                if let Ok(v) = serde_json::from_str::<Value>(text) {
                    if v.get("type").and_then(Value::as_str) == Some("system") {
                        match v.get("subtype").and_then(Value::as_str) {
                            Some("task_notification") => notices += 1,
                            Some("init") => {
                                if seen_init {
                                    turns_after_first += 1;
                                }
                                seen_init = true;
                            }
                            _ => {}
                        }
                    }
                }
            }
            if reader.result.is_some() {
                // A notice the CLI has not answered yet: its turn is coming (a
                // few notices may share one turn, so it is only waited for a while).
                let unanswered = notices > turns_after_first;
                // Port: so is a typed message it has not taken in yet (it
                // answers it as a turn of its own right after this result).
                let waiting = !unacked.is_empty();
                if (background > 0 || unanswered || waiting) && stopping.is_none() {
                    let wait = if waiting { INJECTED_WAIT } else { Duration::from_secs(5) };
                    linger = if background == 0 { Some(tokio::time::Instant::now() + wait) } else { None };
                    if let Some(Ok(t)) = reader.result.take() {
                        if !t.trim().is_empty() {
                            interim.push(t);
                        }
                    }
                    continue;
                }
                break;
            }
        }
        if reader.current.len() != sent_len && !reader.current.is_empty() {
            on_delta(reader.current.clone());
        }
        Ok::<_, String>(reader)
    };

    let reader = match tokio::time::timeout(TIMEOUT, read).await {
        Ok(r) => r?,
        Err(_) => return Err(t("Claude Code took too long to answer.")),
    };
    let stopped = stopping.is_some();
    for h in hooks.close_helpers() {
        on_hook(h);
    }
    let last = reader.result.as_ref().and_then(|r| r.as_ref().ok()).map(String::as_str).unwrap_or(reader.current.as_str());
    // A compaction with nothing said after it: no finished turn (his ask).
    let quiet = hooks.compacted && last.trim().is_empty() && interim.is_empty();
    if !quiet {
        if let Some(h) = hooks.done(last) {
            on_hook(h);
        }
    }
    let compacted = hooks.compacted;
    // End of input: the CLI exits after its result.
    let _ = stdin.shutdown().await;
    drop(stdin);
    // The result line is the last thing the CLI prints: give it a moment to
    // exit by itself, then the guard kills whatever is left of the group.
    let status = tokio::time::timeout(Duration::from_secs(5), child.wait()).await;
    if let Ok(Ok(_)) = status {
        guard.done = true;
        // Anything it left behind in its group goes too.
        unsafe {
            libc::killpg(guard.pgid, libc::SIGKILL);
        }
    }
    let stderr_text = tokio::time::timeout(Duration::from_secs(1), errors).await.ok().and_then(|r| r.ok()).unwrap_or_default();

    if stopped {
        // Whatever the CLI ended with (an interrupted turn reports an error),
        // the answer is the text that had come.
        // and the answers given before it (a helper's follow-up turn stopped).
        let mut parts = interim.clone();
        if !reader.current.trim().is_empty() {
            parts.push(reader.current.trim().to_string());
        }
        let answer = parts.join("\n\n");
        return Ok(Ran { answer, session: reader.session, segments, unacked: unacked.into(), stopped: true, compacted });
    }
    match reader.result {
        Some(Ok(text)) => {
            interim.push(text);
            let answer = interim.join("\n\n");
            Ok(Ran { answer, session: reader.session, segments, unacked: unacked.into(), stopped: false, compacted })
        }
        Some(Err(e)) => Err(e),
        // Waited for a helper's follow-up turn that did not come: the answers so far.
        None if !interim.is_empty() => Ok(Ran { answer: interim.join("\n\n"), session: reader.session, segments, unacked: unacked.into(), stopped: false, compacted }),
        None => {
            let last = stderr_text.lines().rev().find(|l| !l.trim().is_empty()).unwrap_or_default();
            crate::log::line(format!("chat: claude code ended without a result: {}", last.chars().take(300).collect::<String>()));
            Err(friendly_error(last))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const INIT: &str = r#"{"type":"system","subtype":"init","cwd":"/x","session_id":"5e1d-aa","tools":["Read","Glob","Grep"],"model":"claude-haiku-4-5"}"#;

    fn delta(text: &str) -> String {
        json!({"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":text}},"session_id":"5e1d-aa"}).to_string()
    }

    #[test]
    fn the_stream_parser_takes_session_text_and_result() {
        assert_eq!(parse_line(INIT), Line::Session("5e1d-aa".into()));
        assert_eq!(parse_line(&delta("Hi")), Line::TextDelta("Hi".into()));
        assert_eq!(
            parse_line(r#"{"type":"stream_event","event":{"type":"message_start","message":{}}}"#),
            Line::MessageStart
        );
        assert_eq!(
            parse_line(r#"{"type":"stream_event","event":{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"file"}}}"#),
            Line::Other
        );
        assert_eq!(
            parse_line(r#"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"hmm"}}}"#),
            Line::Other
        );
        assert_eq!(parse_line(r#"{"type":"assistant","message":{"content":[{"type":"text","text":"Hi"}]}}"#), Line::Other);
        assert_eq!(parse_line("not json"), Line::Other);
        assert_eq!(parse_line(""), Line::Other);
        assert_eq!(
            parse_line(r#"{"type":"result","subtype":"success","is_error":false,"result":"Hi there!","session_id":"5e1d-aa"}"#),
            Line::Result { error: false, text: "Hi there!".into(), session: Some("5e1d-aa".into()) }
        );
        assert_eq!(
            parse_line(r#"{"type":"result","subtype":"error_during_execution","is_error":true,"errors":["boom"],"session_id":"s"}"#),
            Line::Result { error: true, text: "boom".into(), session: Some("s".into()) }
        );
    }

    #[test]
    fn the_reader_streams_the_current_message_and_ends_on_the_result() {
        let mut r = Reader::default();
        let mut seen = Vec::new();
        let lines = [
            INIT.to_string(),
            r#"{"type":"stream_event","event":{"type":"message_start","message":{}}}"#.to_string(),
            delta("Let me read it."),
            r#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read"}]}}"#.to_string(),
            r#"{"type":"user","message":{"content":[{"type":"tool_result"}]}}"#.to_string(),
            r#"{"type":"stream_event","event":{"type":"message_start","message":{}}}"#.to_string(),
            delta("The codeword "),
            delta(""),
            delta("is **plum**."),
            r#"{"type":"result","subtype":"success","is_error":false,"result":"The codeword is **plum**.","session_id":"5e1d-aa"}"#.to_string(),
        ];
        for l in &lines {
            if r.feed(l) {
                seen.push(r.current.clone());
            }
        }
        assert_eq!(seen, vec!["Let me read it.", "The codeword ", "The codeword is **plum**."]);
        assert_eq!(r.session.as_deref(), Some("5e1d-aa"));
        assert_eq!(r.result, Some(Ok("The codeword is **plum**.".into())));
    }

    #[test]
    fn errors_say_what_happened() {
        let mut r = Reader::default();
        r.feed(r#"{"type":"result","subtype":"success","is_error":true,"result":"Not logged in · Please run /login","session_id":"s"}"#);
        assert!(r.result.unwrap().unwrap_err().contains("isn't logged in"));
        let mut r = Reader::default();
        r.feed(r#"{"type":"result","subtype":"success","is_error":true,"result":"You've hit your limit · resets 5pm"}"#);
        assert_eq!(r.result.unwrap().unwrap_err(), "Claude Code: You've hit your limit · resets 5pm");
        assert_eq!(friendly_error(""), "Claude Code stopped without answering.");
        // A result without text falls back to what was streamed.
        let mut r = Reader::default();
        r.feed(&delta("streamed"));
        r.feed(r#"{"type":"result","subtype":"success","is_error":false,"result":""}"#);
        assert_eq!(r.result, Some(Ok("streamed".into())));
    }

    #[test]
    fn the_command_is_fenced_in() {
        let args = command_args("claude-haiku-4-5-20251001", ChatMode::ReadOnly, Some("abc"), Some(Path::new("/inbox")));
        let joined = args.join(" ");
        for needle in [
            "-p --input-format stream-json --output-format stream-json --verbose --include-partial-messages --replay-user-messages",
            r#"--settings {"disableAllHooks":true}"#,
            "--safe-mode",
            "--strict-mcp-config",
            "--permission-mode dontAsk",
            "--tools Read,Glob,Grep",
            "--model claude-haiku-4-5-20251001",
            "--add-dir /inbox",
            "--resume abc",
            "--system-prompt-snapshot off",
        ] {
            assert!(joined.contains(needle), "{needle} missing from {joined}");
        }
        assert!(!joined.contains("Bash") && !joined.contains("WebFetch") && !joined.contains("Edit"));
        assert!(!joined.contains("--permission-prompt-tool"));
        // Only listed ids reach the command line; old aliases become their id.
        assert!(command_args("--dangerously-skip-permissions", ChatMode::Ask, None, None).contains(&DEFAULT_MODEL.to_string()));
        assert!(command_args("opus", ChatMode::Ask, None, None).contains(&"claude-opus-5-5".to_string()));
        assert!(command_args("claude-fable-5-1", ChatMode::Ask, None, None).contains(&"claude-fable-5-1".to_string()));
        assert!(!command_args("claude-opus-5-5", ChatMode::Ask, None, None).iter().any(|a| a == "--resume" || a == "--add-dir"));
        assert_eq!(
            models().iter().map(|m| m.label.as_str()).collect::<Vec<_>>(),
            ["Claude Fable 5.1", "Claude Opus 5.5", "Claude Sonnet 5.5", "Claude Haiku 4.5"]
        );
        assert_eq!(migrate_model("sonnet"), Some("claude-sonnet-5-5"));
        assert_eq!(migrate_model("haiku"), Some("claude-haiku-4-5-20251001"));
        assert_eq!(migrate_model("claude-opus-5-5"), None);
    }

    #[test]
    fn each_mode_maps_to_its_flags_and_never_bypasses() {
        let flags = |mode| command_args("claude-sonnet-5-5", mode, None, None).join(" ");
        let ask = flags(ChatMode::Ask);
        assert!(ask.contains("--permission-mode default") && ask.contains("--permission-prompt-tool stdio"), "{ask}");
        assert!(ask.contains(&format!("--tools {FULL_TOOLS}")) && FULL_TOOLS.contains("AskUserQuestion"));
        assert!(flags(ChatMode::Edit).contains("--permission-mode acceptEdits --tools"));
        assert!(flags(ChatMode::Auto).contains("--permission-mode auto --tools"));
        for mode in [ChatMode::ReadOnly, ChatMode::Ask, ChatMode::Edit, ChatMode::Auto] {
            let f = flags(mode);
            assert!(!f.contains("bypassPermissions") && !f.contains("dangerously"), "{f}");
            assert!(f.contains("--safe-mode") && f.contains(r#"{"disableAllHooks":true}"#), "{f}");
        }
        assert_eq!(ChatMode::from_setting("ask"), ChatMode::Ask);
        assert_eq!(ChatMode::from_setting("edit"), ChatMode::Edit);
        assert_eq!(ChatMode::from_setting("auto"), ChatMode::Auto);
        assert_eq!(ChatMode::from_setting("readonly"), ChatMode::ReadOnly);
        // Anything unknown is the safest mode.
        assert_eq!(ChatMode::from_setting("bypassPermissions"), ChatMode::ReadOnly);
        assert_eq!(ChatMode::from_setting(DEFAULT_MODE), ChatMode::Ask);
    }

    #[test]
    fn permission_answers_need_a_click_and_questions_need_fitting_answers() {
        let bash = json!({"command": "true"});
        assert_eq!(permission_response("Bash", &bash, Some("allow")), json!({"behavior": "allow", "updatedInput": bash}));
        assert_eq!(permission_response("Bash", &bash, Some("always"))["behavior"], "allow");
        assert_eq!(permission_response("Bash", &bash, Some("deny")), json!({"behavior": "deny", "message": DENIED}));
        assert_eq!(permission_response("Bash", &bash, None), json!({"behavior": "deny", "message": UNANSWERED}));
        assert_eq!(permission_response("Bash", &bash, Some("maybe"))["behavior"], "deny");
        let q = json!({"questions": [
            {"question": "A or B?", "header": "Pick", "options": [{"label": "A"}, {"label": "B"}], "multiSelect": false},
            {"question": "Which extras?", "options": [{"label": "X"}, {"label": "Y"}], "multiSelect": true},
        ]});
        let ok = permission_response("AskUserQuestion", &q, Some(r#"{"answers":{"A or B?":"B","Which extras?":["X","Y"]}}"#));
        assert_eq!(ok["behavior"], "allow");
        assert_eq!(ok["updatedInput"]["answers"], json!({"A or B?": "B", "Which extras?": ["X", "Y"]}));
        assert_eq!(ok["updatedInput"]["questions"], q["questions"]);
        // A typed ("Other") answer stands in for an option, and joins the picks.
        let typed = permission_response("AskUserQuestion", &q, Some(r#"{"answers":{"A or B?":"Neither, use C","Which extras?":["X","and Z"]}}"#));
        assert_eq!(typed["behavior"], "allow");
        assert_eq!(typed["updatedInput"]["answers"], json!({"A or B?": "Neither, use C", "Which extras?": ["X", "and Z"]}));
        for bad in [
            r#"{"answers":{"A or B?":" ","Which extras?":["X"]}}"#,
            r#"{"answers":{"A or B?":"B","Which extras?":["X","mine","also mine"]}}"#,
            r#"{"answers":{"A or B?":"B","Which extras?":["X",1]}}"#,
            r#"{"answers":{"A or B?":"B"}}"#,
            r#"{"answers":{"A or B?":"B","Which extras?":[]}}"#,
            r#"{"answers":{"A or B?":"B","Which extras?":["X","X"]}}"#,
            "allow",
        ] {
            assert_eq!(permission_response("AskUserQuestion", &q, Some(bad)), json!({"behavior": "deny", "message": NOT_ANSWERED}), "{bad}");
        }
        assert_eq!(permission_response("AskUserQuestion", &q, None)["message"], NOT_ANSWERED);
        let long = "x".repeat(MAX_SHOWN + 10);
        let cut = shown(&json!({"command": long, "n": 3}));
        assert!(cut["command"].as_str().unwrap().ends_with('…'));
        assert_eq!(cut["n"], 3);
    }

    #[test]
    fn the_prompt_carries_context_and_a_transcript_when_needed() {
        let file = ChatContext::File { name: "a.txt".into(), path: "/inbox/a.txt".into() };
        let p = prompt_text(true, Some(&file), &[], "what?");
        assert!(p.starts_with("File: a.txt\nThe file is at /inbox/a.txt"), "{p}");
        assert!(p.ends_with("\n\nwhat?"));
        // A file dropped later in the chat goes with that message (port).
        assert!(prompt_text(false, Some(&file), &[], "more").starts_with("File: a.txt"));
        let win = ChatContext::Window { app_name: "Zen".into(), title: "x".into(), url: None };
        assert_eq!(prompt_text(false, Some(&win), &[], "more"), "more");
        let history = vec![json!({"role":"user","content":"q"}), json!({"role":"assistant","content":"a"})];
        let p = prompt_text(false, None, &history, "next");
        assert_eq!(p, "Earlier in this conversation:\n\nUser: q\n\nAssistant: a\n\nNow the user asks:\n\nnext");
    }

    #[test]
    fn the_stream_becomes_the_hooks_a_terminal_session_sends() {
        let mut f = HookFeed::new("fix the bug", Path::new("/home/x/proj"));
        let init = f.feed(INIT);
        assert_eq!(init.len(), 1);
        assert_eq!(init[0]["hook_event_name"], "UserPromptSubmit");
        assert_eq!(init[0]["prompt"], "fix the bug");
        assert_eq!(init[0]["session_id"], "5e1d-aa");
        assert_eq!(init[0]["cwd"], "/home/x/proj");
        let tool = r#"{"type":"assistant","message":{"content":[{"type":"text","text":"Let me look."},{"type":"tool_use","id":"t1","name":"Edit","input":{"file_path":"/home/x/proj/a.rs","old_string":"a","new_string":"b"}}]},"session_id":"5e1d-aa"}"#;
        let pre = f.feed(tool);
        assert_eq!(pre.len(), 1);
        assert_eq!(pre[0]["hook_event_name"], "PreToolUse");
        assert_eq!(pre[0]["tool_name"], "Edit");
        assert_eq!(pre[0]["tool_input"]["new_string"], "b");
        let result = r#"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]},"session_id":"5e1d-aa"}"#;
        let post = f.feed(result);
        assert_eq!(post[0]["hook_event_name"], "PostToolUse");
        assert_eq!(post[0]["tool_name"], "Edit");
        assert_eq!(post[0]["tool_input"]["old_string"], "a");
        assert_eq!(post[0]["tool_response"], "ok");
        // A result for an unknown tool call, or the same one twice: nothing.
        assert!(f.feed(result).is_empty());
        let failed = r#"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t2","name":"Bash","input":{"command":"false"}}]}}"#;
        f.feed(failed);
        let post = f.feed(r#"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t2","content":"exit 1","is_error":true}]}}"#);
        assert_eq!(post[0]["hook_event_name"], "PostToolUseFailure");
        // Never a permission request or a Stop: the chat does those itself.
        let done = f.done("All fixed.").unwrap();
        assert_eq!(done["hook_event_name"], "ChatTurnDone");
        assert_eq!(done["last_assistant_message"], "All fixed.");
        assert!(HookFeed::new("q", Path::new("/x")).done("a").is_none());
    }

    #[test]
    fn compaction_comes_as_pre_and_post_compact() {
        let mut f = HookFeed::new("q", Path::new("/p"));
        f.feed(INIT);
        f.feed(r#"{"type":"assistant","message":{"content":[{"type":"text","text":"hi"}],"usage":{"input_tokens":12,"cache_read_input_tokens":150000,"cache_creation_input_tokens":988}},"parent_tool_use_id":null}"#);
        let pre = f.feed(r#"{"type":"system","subtype":"status","status":"compacting","session_id":"5e1d-aa"}"#);
        let pre = pre.iter().find(|e| e["hook_event_name"] == "PreCompact").expect("PreCompact");
        assert_eq!(pre["coucou_context_tokens"], 151000);
        // Said again while it runs: once.
        assert!(f.feed(r#"{"type":"system","subtype":"status","status":"compacting"}"#).iter().all(|e| e["hook_event_name"] != "PreCompact"));
        let post = f.feed(r#"{"type":"system","subtype":"compact_boundary","session_id":"5e1d-aa","compact_metadata":{"trigger":"auto","pre_tokens":151000}}"#);
        assert_eq!(post[0]["hook_event_name"], "PostCompact");
        assert_eq!(post[0]["coucou_pre_tokens"], 151000);
    }

    #[test]
    fn a_helper_gets_its_own_tagged_events_off_the_main_pill() {
        // Shapes from a real 2.1.285 stream with one background helper.
        let mut f = HookFeed::new("q", Path::new("/p"));
        f.feed(INIT);
        let call = r#"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_01CCrKrjSrbN8dEtZQr6apBc","name":"Agent","input":{"subagent_type":"general-purpose","description":"read hostname","prompt":"..."}}]},"parent_tool_use_id":null,"session_id":"5e1d-aa"}"#;
        let ev = f.feed(call);
        let tag = helper_tag("toolu_01CCrKrjSrbN8dEtZQr6apBc");
        assert_eq!(tag, "h-r6apbc".replace("r6apbc", &"KrjSrbN8dEtZQr6apBc"[11..].to_ascii_lowercase()));
        assert_eq!(ev[0]["hook_event_name"], "UserPromptSubmit");
        assert_eq!(ev[0]["coucou_agent"], tag);
        assert_eq!(ev[0]["coucou_helper"]["name"], "read hostname");
        assert_eq!(ev[1]["hook_event_name"], "PreToolUse");
        assert!(ev[1].get("coucou_agent").is_none(), "the Agent call itself is the session's step");
        // task_started for the same call: no second start.
        assert!(f.feed(r#"{"type":"system","subtype":"task_started","task_id":"a80e","tool_use_id":"toolu_01CCrKrjSrbN8dEtZQr6apBc","description":"read hostname","subagent_type":"general-purpose"}"#).is_empty());
        // Launched in the background: its Agent result is no answer yet.
        let launched = f.feed(r#"{"type":"user","message":{"content":[{"tool_use_id":"toolu_01CCrKrjSrbN8dEtZQr6apBc","type":"tool_result","content":[{"type":"text","text":"Async agent launched successfully."}]}]},"parent_tool_use_id":null}"#);
        assert_eq!(launched.len(), 1);
        assert_eq!(launched[0]["hook_event_name"], "PostToolUse");
        // The helper's own tool call goes on its pill.
        let read = f.feed(r#"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_r1","name":"Read","input":{"file_path":"/etc/hostname"}}]},"parent_tool_use_id":"toolu_01CCrKrjSrbN8dEtZQr6apBc"}"#);
        assert_eq!(read[0]["hook_event_name"], "PreToolUse");
        assert_eq!(read[0]["coucou_agent"], tag);
        let post = f.feed(r#"{"type":"user","message":{"content":[{"tool_use_id":"toolu_r1","type":"tool_result","content":"SULLY"}]},"parent_tool_use_id":"toolu_01CCrKrjSrbN8dEtZQr6apBc"}"#);
        assert_eq!(post[0]["coucou_agent"], tag);
        // Done: Stop on its pill, with its summary; once.
        let done = f.feed(r#"{"type":"system","subtype":"task_notification","task_id":"a80e","tool_use_id":"toolu_01CCrKrjSrbN8dEtZQr6apBc","status":"completed","summary":"The hostname is SULLY"}"#);
        assert_eq!(done[0]["hook_event_name"], "Stop");
        assert_eq!(done[0]["coucou_agent"], tag);
        assert_eq!(done[0]["last_assistant_message"], "The hostname is SULLY");
        assert!(f.close_helpers().is_empty());
        // A helper still running when the turn ends is closed.
        f.feed(r#"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_b2","name":"Agent","input":{"description":"second"}}]}}"#);
        let closed = f.close_helpers();
        assert_eq!(closed.len(), 1);
        assert_eq!(closed[0]["hook_event_name"], "Stop");
    }

    #[test]
    fn a_run_streams_and_returns_the_answer_from_a_fake_cli() {
        // A stand-in for `claude`: checks the prompt arrives on stdin as a
        // stream-json user message, asks one permission, reads the answer,
        // prints canned lines.
        let dir = std::env::temp_dir().join(format!("robo-claudecode-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let script = dir.join("claude");
        let body = format!(
            "#!/bin/sh\nread -r q\ncase \"$q\" in *'\"content\":\"ping\"'*) ;; *) echo bad prompt >&2; exit 3;; esac\necho '{INIT}'\necho '{}'\necho '{{\"type\":\"control_request\",\"request_id\":\"r1\",\"request\":{{\"subtype\":\"can_use_tool\",\"tool_name\":\"Bash\",\"input\":{{\"command\":\"true\"}}}}}}'\nread -r a\ncase \"$a\" in *'\"request_id\":\"r1\"'*'\"behavior\":\"allow\"'*) ;; *) echo \"bad answer $a\" >&2; exit 4;; esac\necho '{}'\necho '{{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"result\":\"pong!\",\"session_id\":\"5e1d-aa\"}}'\nread -r rest || exit 0\n",
            delta("pon"),
            delta("g!")
        );
        std::fs::write(&script, body).unwrap();
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();
        let rt = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
        let mut seen = Vec::new();
        let mut cards = Vec::new();
        let none = || tokio::sync::mpsc::unbounded_channel::<TurnControl>().1;
        let Ran { answer: text, session, .. } = rt
            .block_on(run(&script, &dir, &[], "ping", "ping", none(), |v| seen.push(v), |_| {}, |_| {}, |card| {
                cards.push(card);
                async { Some("allow".to_string()) }
            }))
            .unwrap();
        assert_eq!(text, "pong!");
        assert_eq!(session.as_deref(), Some("5e1d-aa"));
        assert_eq!(seen.last().map(String::as_str), Some("pong!"));
        assert_eq!(cards.len(), 1);
        assert_eq!(cards[0]["tool_name"], "Bash");
        assert_eq!(cards[0]["tool_input"]["command"], "true");
        assert_eq!(cards[0]["session_id"], "5e1d-aa");
        // Nobody answers: the CLI is told no, and says so.
        let err = rt
            .block_on(run(&script, &dir, &[], "ping", "ping", none(), |_| {}, |_| {}, |_| {}, |_| async { None }))
            .unwrap_err();
        assert!(err.contains("bad answer") || err.contains("stopped"), "{err}");
        // No result line: stderr becomes the error.
        std::fs::write(&script, "#!/bin/sh\necho 'Error: something broke' >&2\nexit 1\n").unwrap();
        let err = rt.block_on(run(&script, &dir, &[], "x", "x", none(), |_| {}, |_| {}, |_| {}, |_| async { None })).unwrap_err();
        assert_eq!(err, "Claude Code: Error: something broke");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn replayed_user_messages_are_recognised() {
        assert_eq!(
            replayed_text(r#"{"type":"user","message":{"role":"user","content":"Also BANANA."},"session_id":"s","isReplay":true}"#).as_deref(),
            Some("Also BANANA.")
        );
        assert_eq!(
            replayed_text(r#"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"a"},{"type":"text","text":"b"}]},"isReplay":true}"#).as_deref(),
            Some("a\n\nb")
        );
        // A tool result is no echo, nor is a user line without the flag.
        assert_eq!(replayed_text(r#"{"type":"user","message":{"content":[{"type":"tool_result","content":"x"}]}}"#), None);
        assert_eq!(replayed_text(r#"{"type":"user","message":{"content":"hi"},"isReplay":false}"#), None);
    }

    /// A fake `claude` from `body` (sh), in a fresh temp dir.
    fn fake_cli(name: &str, body: &str) -> (PathBuf, PathBuf) {
        let dir = std::env::temp_dir().join(format!("robo-claudecode-{name}-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let script = dir.join("claude");
        std::fs::write(&script, body).unwrap();
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();
        (dir, script)
    }

    fn replay(text: &str) -> String {
        json!({"type":"user","message":{"role":"user","content":text},"session_id":"5e1d-aa","parent_tool_use_id":null,"isReplay":true}).to_string()
    }

    const START: &str = r#"{"type":"stream_event","event":{"type":"message_start","message":{}}}"#;

    fn result(text: &str) -> String {
        json!({"type":"result","subtype":"success","is_error":false,"result":text,"session_id":"5e1d-aa"}).to_string()
    }

    fn run_with_injection(script: &Path, dir: &Path, typed: &str) -> (Ran, Vec<String>, Vec<String>) {
        let rt = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
        let (tx, rx) = tokio::sync::mpsc::unbounded_channel::<TurnControl>();
        tx.send(TurnControl::Inject(typed.to_string())).unwrap();
        let mut deltas = Vec::new();
        let mut taken = Vec::new();
        let ran = rt
            .block_on(run(script, dir, &[], "ping", "ping", rx, |v| deltas.push(v), |m| taken.push(m), |_| {}, |_| async { None }))
            .unwrap();
        (ran, deltas, taken)
    }

    #[test]
    fn a_message_taken_in_between_two_steps_splits_the_turn() {
        // As observed with claude 2.1.285: the echo comes right after the
        // running tool's result, before the next request; the final result
        // is the last message only.
        let body = format!(
            "#!/bin/sh\nread -r q\necho '{INIT}'\necho '{}'\necho '{START}'\necho '{}'\nread -r m\necho '{}'\necho '{}'\necho '{}'\necho '{START}'\necho '{}'\necho '{}'\nread -r rest || exit 0\n",
            replay("ping"),
            delta("Working on it."),
            r#"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":""}]}}"#,
            // Some other echoed line is not the typed message.
            replay("<task-notification>done</task-notification>"),
            replay("and BANANA"),
            delta("DONE. BANANA"),
            result("DONE. BANANA"),
        );
        let (dir, script) = fake_cli("split", &body);
        let (ran, deltas, taken) = run_with_injection(&script, &dir, "and BANANA");
        assert_eq!(taken, vec!["and BANANA"]);
        assert_eq!(ran.segments, vec![("Working on it.".to_string(), "and BANANA".to_string())]);
        assert!(ran.unacked.is_empty());
        assert_eq!(ran.answer, "DONE. BANANA");
        assert_eq!(deltas.last().map(String::as_str), Some("DONE. BANANA"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_message_taken_in_after_the_result_gets_its_own_answer() {
        // Typed during a reply with no tool left: the CLI answers first, then
        // takes it in as a turn of its own. The run waits for that one.
        let body = format!(
            "#!/bin/sh\nread -r q\necho '{INIT}'\necho '{}'\necho '{START}'\necho '{}'\necho '{}'\nread -r m\necho '{INIT}'\necho '{}'\necho '{START}'\necho '{}'\necho '{}'\nread -r rest || exit 0\n",
            replay("ping"),
            delta("A story."),
            result("A story."),
            replay("and BANANA"),
            delta("BANANA"),
            result("BANANA"),
        );
        let (dir, script) = fake_cli("after", &body);
        let (ran, _, taken) = run_with_injection(&script, &dir, "and BANANA");
        assert_eq!(taken, vec!["and BANANA"]);
        assert_eq!(ran.segments, vec![("A story.".to_string(), "and BANANA".to_string())]);
        assert_eq!(ran.answer, "BANANA");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_message_never_taken_in_is_handed_back() {
        let body = format!(
            "#!/bin/sh\nread -r q\necho '{INIT}'\necho '{}'\necho '{START}'\necho '{}'\nread -r m\necho '{}'\nexit 0\n",
            replay("ping"),
            delta("Hi."),
            result("Hi."),
        );
        let (dir, script) = fake_cli("never", &body);
        let (ran, _, taken) = run_with_injection(&script, &dir, "later");
        assert!(taken.is_empty());
        assert!(ran.segments.is_empty());
        assert_eq!(ran.unacked, vec!["later"]);
        assert_eq!(ran.answer, "Hi.");
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Live check against the installed `claude` (costs a few cents of
    /// haiku): `cargo test -- --ignored a_real_cli`.
    #[test]
    #[ignore]
    fn a_real_cli_takes_a_typed_message_in() {
        let Some(bin) = find_binary() else { return };
        let dir = std::env::temp_dir().join(format!("robo-claudecode-live-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let args: Vec<String> = [
            "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
            "--include-partial-messages", "--replay-user-messages", "--model", "haiku",
            "--tools", "Bash", "--allowedTools", "Bash", "--permission-mode", "bypassPermissions",
        ]
        .iter()
        .map(|s| s.to_string())
        .collect();
        let rt = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
        for (prompt, after) in [
            // Typed during a tool: taken in right after its result.
            ("Run `sleep 8` with the Bash tool, then reply with just the word DONE.", 4),
            // Typed during a plain reply: answered as a turn of its own.
            ("Write a 200-word story about a cat. Do not use any tools.", 2),
        ] {
            let (tx, rx) = tokio::sync::mpsc::unbounded_channel::<TurnControl>();
            std::thread::spawn(move || {
                std::thread::sleep(Duration::from_secs(after));
                let _ = tx.send(TurnControl::Inject("Also, after that, reply with the word BANANA.".into()));
            });
            let mut taken = Vec::new();
            let ran = rt
                .block_on(run(&bin, &dir, &args, prompt, prompt, rx, |_| {}, |m| taken.push(m), |_| {}, |_| async { None }))
                .unwrap();
            eprintln!("segments={:?}\nanswer={:?}\nunacked={:?}", ran.segments, ran.answer, ran.unacked);
            assert_eq!(taken.len(), 1, "{prompt}");
            assert!(ran.unacked.is_empty());
            assert!(ran.answer.contains("BANANA"), "{}", ran.answer);
        }
        let _ = std::fs::remove_dir_all(&dir);
    }
}
