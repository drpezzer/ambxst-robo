// The tab's chats column (port only, no upstream equivalent): earlier chats,
// most recently used first, and what it takes to continue one.
//
// Two sources:
// - Claude Code's own sessions, every project: ~/.claude/projects/*/*.jsonl.
//   Each is named exactly as `claude --resume`'s picker names it. The picker
//   (CLI 2.1.285) reads a "lite" view of each file — its first and last 64 KiB
//   — and titles a row with `agentName || customTitle || aiTitle || summary ||
//   firstPrompt || sessionId[..8]`, tags stripped, where customTitle is the
//   last `custom-title` record in the tail (else the side file
//   `<sid>/custom-title.json`, else the head), aiTitle the last `ai-title`
//   (tail, else head), summary the last `summary` record of the tail, and
//   firstPrompt the tail's last `lastPrompt` (else the head's first real
//   prompt). Sessions the picker hides are hidden here too (sidechains, team
//   and daemon sessions, `claude -p` runs, /loop sessions, files with no
//   message). Read only: nothing under ~/.claude is ever written here.
// - Chats started in Coucou (any provider), saved by chat.rs after every turn
//   in ~/.local/share/ambxst-robo/chats/<id>.json. Coucou's own Claude Code runs
//   live in the CLI's project folder for ~/.local/share/ambxst-robo/chat-claudecode:
//   they show once, as the Coucou chat that made them (an older one that no
//   saved chat claims shows as a Coucou chat of its own). Port (his ask): a
//   chat given another working folder (chatWorkDir) runs its sessions in that
//   folder's project; the chat records them (`cliDirs`), so they show (and
//   are trashed) with it too, and it resumes them there.
//
// Listing is cheap: a file is read again only when its size or mtime changed.

use std::collections::HashMap;
use std::fs::File;
use std::io::{BufRead, BufReader, Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};
use std::time::UNIX_EPOCH;

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

/// What the picker reads of each end of a session file.
const LITE: usize = 64 * 1024;
/// A file with no message line in its two ends is scanned this far for one.
const BOOKKEEPING_SCAN: u64 = 16 * 1024 * 1024;
/// The most turns a reopened chat brings back.
const MAX_TURNS: usize = 80;
/// Longest title kept for a Coucou chat (its first message).
const MAX_TITLE: usize = 200;
/// Entrypoints of SDK / `claude -p` runs, which the interactive picker hides.
const SDK_ENTRYPOINTS: &[&str] = &["sdk-cli", "sdk-ts", "sdk-py"];
/// Slash commands the picker never takes as a session's prompt.
const BUILTIN_COMMANDS: &[&str] = &[
    "add-dir", "agents", "bug", "clear", "compact", "config", "context", "cost", "doctor", "exit", "export",
    "feedback", "help", "hooks", "ide", "init", "install-github-app", "login", "logout", "mcp", "memory",
    "model", "output-style", "permissions", "plugin", "pr-comments", "release-notes", "rename", "resume",
    "review", "rewind", "security-review", "status", "statusline", "terminal-setup", "todos", "upgrade",
    "usage", "vim",
];

// ── Paths ─────────────────────────────────────────────────────────────────────

/// Claude Code's config folder ($CLAUDE_CONFIG_DIR, else ~/.claude).
fn claude_dir() -> PathBuf {
    std::env::var_os("CLAUDE_CONFIG_DIR")
        .filter(|v| !v.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| crate::platform::home_dir().join(".claude"))
}

pub fn projects_dir() -> PathBuf {
    claude_dir().join("projects")
}

/// ~/.local/share/ambxst-robo/chats
pub fn store_dir() -> PathBuf {
    crate::settings::local_dir().join("chats")
}

/// The CLI's folder name for a working directory (sanitizePath).
fn project_slug(cwd: &str) -> String {
    cwd.chars().map(|c| if c.is_ascii_alphanumeric() { c } else { '-' }).collect()
}

/// The working folder of the chat's own Claude Code runs (claude_code.rs).
pub fn own_cli_dir() -> PathBuf {
    crate::settings::local_dir().join("chat-claudecode")
}

/// The coucou-core port's (and upstream Coucou's) chat folder,
/// ~/.local/share/coucou/chat-claudecode. `--migrate-from-coucou` copies its
/// Claude Code sessions into ours; the originals are left where they are.
pub fn legacy_cli_dir() -> PathBuf {
    crate::platform::legacy_local_dir().join("chat-claudecode")
}

/// The CLI's project folder for a working directory.
pub fn project_dir_for(cwd: &Path) -> PathBuf {
    projects_dir().join(project_slug(&cwd.display().to_string()))
}

/// What `--migrate-from-coucou` copied (migrate.rs writes it).
pub fn migrated_record_path() -> PathBuf {
    crate::settings::local_dir().join("migrated-from-coucou.json")
}

/// Ids of the sessions copied out of Coucou's chat folder: their originals
/// there are not listed (or opened, or trashed), only our copies are.
pub fn migrated_sessions() -> std::collections::HashSet<String> {
    std::fs::read(migrated_record_path())
        .ok()
        .and_then(|b| serde_json::from_slice::<Value>(&b).ok())
        .and_then(|v| v.get("sessions").and_then(Value::as_array).cloned())
        .map(|list| list.iter().filter_map(Value::as_str).map(str::to_string).collect())
        .unwrap_or_default()
}

fn mtime_ms(meta: &std::fs::Metadata) -> i64 {
    meta.modified()
        .ok()
        .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

pub fn now_ms() -> i64 {
    std::time::SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as i64).unwrap_or(0)
}

// ── The picker's text scanning (exact ports) ──────────────────────────────────

/// A JSON string's raw (still escaped) body, unescaped.
fn unescape(raw: &str) -> String {
    serde_json::from_str::<String>(&format!("\"{raw}\"")).unwrap_or_else(|_| raw.to_string())
}

/// End of a JSON string body starting at `start` (index of its closing quote).
fn string_end(text: &[u8], start: usize) -> Option<usize> {
    let mut i = start;
    while i < text.len() {
        match text[i] {
            b'\\' => i += 2,
            b'"' => return Some(i),
            _ => i += 1,
        }
    }
    None
}

/// `"key":"…"` — the first occurrence (CLI `wbe`).
fn first_value(text: &str, key: &str) -> Option<String> {
    for pat in [format!("\"{key}\":\""), format!("\"{key}\": \"")] {
        if let Some(i) = text.find(&pat) {
            let start = i + pat.len();
            let end = string_end(text.as_bytes(), start)?;
            return Some(unescape(&text[start..end]));
        }
    }
    None
}

/// `"key":"…"` — the last complete occurrence (CLI `q2`).
fn last_value(text: &str, key: &str) -> Option<String> {
    let bytes = text.as_bytes();
    let mut best: Option<(usize, String)> = None;
    for pat in [format!("\"{key}\":\""), format!("\"{key}\": \"")] {
        let mut from = 0;
        while let Some(off) = text[from..].find(&pat) {
            let at = from + off;
            let start = at + pat.len();
            let Some(end) = string_end(bytes, start) else { break };
            if best.as_ref().map_or(true, |(b, _)| at > *b) {
                best = Some((at, unescape(&text[start..end])));
            }
            from = end + 1;
            if from >= text.len() {
                break;
            }
        }
    }
    best.map(|(_, v)| v)
}

/// The first line holding `"key":` that parses and has a string there (CLI `vbe`).
fn first_line_value(text: &str, key: &str) -> Option<String> {
    let pat = format!("\"{key}\":");
    text.lines()
        .filter(|l| l.contains(&pat))
        .find_map(|l| serde_json::from_str::<Value>(l).ok()?.get(key)?.as_str().map(str::to_string))
}

/// From the end: the last line of `type` holding `"key":` (CLI `$hr` / `q`).
fn last_typed_value(text: &str, kind: &str, key: &str, parse: bool) -> Option<String> {
    let tpat = format!("\"type\":\"{kind}\"");
    let kpat = format!("\"{key}\":");
    for line in text.lines().rev() {
        if !(line.contains(&tpat) && line.contains(&kpat)) {
            continue;
        }
        if parse {
            if let Ok(v) = serde_json::from_str::<Value>(line) {
                if v.get("type").and_then(Value::as_str) == Some(kind) {
                    if let Some(s) = v.get(key).and_then(Value::as_str) {
                        return Some(s.to_string());
                    }
                }
            }
        } else if let Some(v) = first_value(line, key) {
            return Some(v);
        }
    }
    None
}

/// `"key":"…"` raw, at most `max` characters (escapes count as one), `\n`/`\t`
/// spelled out as spaces (CLI `dcn`).
fn raw_prefix(text: &str, key: &str, max: usize) -> String {
    for pat in [format!("\"{key}\":\""), format!("\"{key}\": \"")] {
        let Some(i) = text.find(&pat) else { continue };
        let start = i + pat.len();
        let b = text.as_bytes();
        let (mut j, mut n) = (start, 0);
        while j < b.len() && n < max {
            if b[j] == b'\\' {
                j += 2;
                n += 1;
                continue;
            }
            if b[j] == b'"' {
                break;
            }
            j += 1;
            n += 1;
        }
        let j = j.min(b.len());
        let mut end = j;
        while end > start && !text.is_char_boundary(end) {
            end -= 1;
        }
        return text[start..end].replace("\\n", " ").replace("\\t", " ").trim().to_string();
    }
    String::new()
}

/// `<name …>…</name>` blocks (and one newline after) removed, as the CLI's
/// `/<([a-z][\w-]*)(?:\s[^>]*)?>[\s\S]*?<\/\1>\n?/g`.
pub fn strip_tags(text: &str) -> String {
    let b = text.as_bytes();
    let mut out = String::with_capacity(text.len());
    let mut i = 0;
    let mut kept = 0;
    while i < b.len() {
        if b[i] == b'<' && i + 1 < b.len() && b[i + 1].is_ascii_lowercase() {
            // name
            let mut j = i + 2;
            while j < b.len() && (b[j].is_ascii_alphanumeric() || b[j] == b'_' || b[j] == b'-') {
                j += 1;
            }
            let name = &text[i + 1..j];
            // (?:\s[^>]*)?>
            let mut k = j;
            if k < b.len() && b[k].is_ascii_whitespace() {
                while k < b.len() && b[k] != b'>' {
                    k += 1;
                }
            }
            if k < b.len() && b[k] == b'>' {
                let close = format!("</{name}>");
                if let Some(off) = text[k + 1..].find(&close) {
                    let mut end = k + 1 + off + close.len();
                    if end < b.len() && b[end] == b'\n' {
                        end += 1;
                    }
                    out.push_str(&text[kept..i]);
                    i = end;
                    kept = end;
                    continue;
                }
            }
        }
        i += 1;
    }
    out.push_str(&text[kept..]);
    out
}

/// `<tag>…</tag>`'s content, if the text has one.
fn tag_content(text: &str, tag: &str) -> Option<String> {
    let open = format!("<{tag}>");
    let close = format!("</{tag}>");
    let i = text.find(&open)? + open.len();
    let j = text[i..].find(&close)? + i;
    Some(text[i..j].to_string())
}

/// The CLI's `Ecn`: text that starts with a tag, or an interruption marker.
fn is_harness_text(text: &str) -> bool {
    let t = text.trim_start();
    if t.starts_with("[Request interrupted by user") {
        return true;
    }
    let b = t.as_bytes();
    if b.len() >= 2 && b[0] == b'<' && b[1].is_ascii_lowercase() {
        let mut j = 2;
        while j < b.len() && (b[j].is_ascii_alphanumeric() || b[j] == b'_' || b[j] == b'-') {
            j += 1;
        }
        return j < b.len() && (b[j].is_ascii_whitespace() || b[j] == b'>');
    }
    false
}

fn cut(text: &str, max: usize) -> String {
    if text.chars().count() <= max {
        return text.to_string();
    }
    let s: String = text.chars().take(max).collect();
    format!("{}…", s.trim())
}

/// The texts of a user record's message (string or text blocks), None for a
/// tool result.
fn user_texts(v: &Value) -> Option<Vec<String>> {
    let content = v.pointer("/message/content")?;
    match content {
        Value::String(s) => Some(vec![s.clone()]),
        Value::Array(items) => {
            let mut out = Vec::new();
            for item in items {
                match item.get("type").and_then(Value::as_str) {
                    Some("tool_result") => return None,
                    Some("text") => {
                        if let Some(t) = item.get("text").and_then(Value::as_str) {
                            out.push(t.to_string());
                        }
                    }
                    _ => {}
                }
            }
            Some(out)
        }
        _ => None,
    }
}

/// The head's first real prompt (CLI `Fhr`).
fn first_prompt(head: &str) -> String {
    let mut command = String::new();
    let mut tick = false;
    for line in head.lines() {
        if !(line.contains("\"type\":\"user\"") || line.contains("\"type\": \"user\"")) {
            continue;
        }
        if line.contains("\"tool_result\"") || line.contains("\"isMeta\":true") || line.contains("\"isMeta\": true") {
            continue;
        }
        let Ok(v) = serde_json::from_str::<Value>(line) else { continue };
        if v.get("type").and_then(Value::as_str) != Some("user") {
            continue;
        }
        let Some(texts) = user_texts(&v) else { continue };
        for t in texts {
            if t.is_empty() {
                continue;
            }
            let k = t.replace('\n', " ").trim().to_string();
            if let Some(name) = tag_content(&k, "command-name") {
                let bare = name.trim_start_matches('/');
                let args = tag_content(&k, "command-args").map(|a| a.trim().to_string()).unwrap_or_default();
                if BUILTIN_COMMANDS.contains(&bare) || args.is_empty() {
                    if command.is_empty() {
                        command = name;
                    }
                    continue;
                }
                return format!("{name} {args}");
            }
            if let Some(cmd) = tag_content(&k, "bash-input") {
                return format!("! {cmd}");
            }
            if is_harness_text(&k) {
                if k.starts_with("<tick>") {
                    tick = true;
                }
                continue;
            }
            return cut(&k, 200);
        }
    }
    if !command.is_empty() {
        return command;
    }
    if tick {
        return "Proactive session".into();
    }
    String::new()
}

// ── One session file ──────────────────────────────────────────────────────────

#[derive(Debug, Default, Clone)]
struct Lite {
    cwd: Option<String>,
    hidden: bool,
    sdk: bool,
    first_prompt: String,
    /// The head's first real prompt (a Coucou CLI session's title).
    head_prompt: String,
    title: String,
    model: Option<String>,
}

fn read_ends(path: &Path, size: u64) -> std::io::Result<(String, String)> {
    let mut f = File::open(path)?;
    let mut head = vec![0u8; LITE.min(size as usize)];
    f.read_exact(&mut head)?;
    let head = String::from_utf8_lossy(&head).into_owned();
    if size as usize <= LITE {
        return Ok((head.clone(), head));
    }
    f.seek(SeekFrom::Start(size - LITE as u64))?;
    let mut tail = vec![0u8; LITE];
    f.read_exact(&mut tail)?;
    Ok((head, String::from_utf8_lossy(&tail).into_owned()))
}

/// True when some line of the file is a message (has a parentUuid).
fn has_message(path: &Path, head: &str, tail: &str, size: u64) -> bool {
    const MARK: &[u8] = b"\"parentUuid\":";
    if head.contains("\"parentUuid\":") || tail.contains("\"parentUuid\":") {
        return true;
    }
    if size as usize <= LITE {
        return false;
    }
    let Ok(f) = File::open(path) else { return false };
    let mut r = BufReader::new(f.take(BOOKKEEPING_SCAN));
    let mut carry: Vec<u8> = Vec::new();
    let mut buf = vec![0u8; 1 << 20];
    loop {
        let n = match r.read(&mut buf) {
            Ok(0) => return false,
            Ok(n) => n,
            Err(_) => return false,
        };
        carry.extend_from_slice(&buf[..n]);
        if carry.windows(MARK.len()).any(|w| w == MARK) {
            return true;
        }
        let keep = carry.len().min(MARK.len());
        carry.drain(..carry.len() - keep);
        if r.get_ref().limit() == 0 {
            // Past the scan limit without an answer: the CLI keeps it.
            return true;
        }
    }
}

/// /loop sessions (CLI `Lhr`): the head's first prompt line is a /loop command.
fn is_loop(head: &str) -> bool {
    for line in head.lines() {
        if !(line.contains("\"type\":\"user\"") || line.contains("\"type\": \"user\"")) || line.contains("\"tool_result\"") {
            continue;
        }
        let Ok(v) = serde_json::from_str::<Value>(line) else { continue };
        if v.get("type").and_then(Value::as_str) != Some("user") {
            continue;
        }
        if v.get("isMeta") == Some(&Value::Bool(true)) || v.get("isCompactSummary") == Some(&Value::Bool(true)) {
            continue;
        }
        let Some(texts) = user_texts(&v) else { continue };
        return texts.iter().any(|t| t.contains("<command-name>/loop</command-name>"));
    }
    false
}

fn side_custom_title(path: &Path, sid: &str) -> Option<String> {
    let file = path.parent()?.join(sid).join("custom-title.json");
    let v: Value = serde_json::from_slice(&std::fs::read(file).ok()?).ok()?;
    v.get("customTitle")?.as_str().filter(|s| !s.is_empty()).map(str::to_string)
}

/// The picker's title for a session (CLI `nG`).
fn picker_title(custom: Option<&str>, ai: Option<&str>, summary: Option<&str>, prompt: &str, sid: &str) -> String {
    let tick = prompt.starts_with("<tick>");
    let stripped = if prompt.is_empty() { String::new() } else { strip_tags(prompt).trim().to_string() };
    let usable = !stripped.is_empty() && !tick;
    let pick = [custom, ai, summary]
        .into_iter()
        .flatten()
        .find(|s| !s.is_empty())
        .map(str::to_string)
        .or_else(|| usable.then(|| stripped.clone()))
        .or_else(|| tick.then(|| "Autonomous session".to_string()))
        .unwrap_or_else(|| sid.chars().take(8).collect());
    let out = strip_tags(&pick).trim().to_string();
    if out.is_empty() { pick.trim().to_string() } else { out }
}

fn read_lite(path: &Path, size: u64, sid: &str) -> Option<Lite> {
    let (head, tail) = read_ends(path, size).ok()?;
    if head.is_empty() {
        return None;
    }
    let mut lite = Lite::default();
    let sidechain = head.contains("\"isSidechain\":true") || head.contains("\"isSidechain\": true");
    let team = first_value(&head, "teamName");
    let kind_line = head.lines().find(|l| l.contains("\"parentUuid\":")).unwrap_or(&head);
    let kind = first_value(kind_line, "sessionKind");
    let entrypoint = first_value(&head, "entrypoint").or_else(|| last_value(&tail, "entrypoint"));
    lite.sdk = entrypoint.as_deref().is_some_and(|e| SDK_ENTRYPOINTS.contains(&e));
    lite.hidden = sidechain
        || team.as_deref().is_some_and(|t| !t.is_empty())
        || matches!(kind.as_deref(), Some("daemon") | Some("daemon-worker"))
        || is_loop(&head)
        || !has_message(path, &head, &tail, size);
    lite.cwd = last_typed_value(&tail, "relocated", "relocatedCwd", true).or_else(|| first_line_value(&head, "cwd"));
    lite.head_prompt = first_prompt(&head);
    lite.first_prompt = last_value(&tail, "lastPrompt")
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| {
            let p = lite.head_prompt.clone();
            if !p.is_empty() { return p; }
            let p = raw_prefix(&head, "content", 200);
            if !p.is_empty() { return p; }
            raw_prefix(&head, "text", 200)
        });
    let custom = match last_value(&tail, "customTitle") {
        Some(t) => Some(t),
        None => side_custom_title(path, sid).or_else(|| last_value(&head, "customTitle")),
    };
    let ai = last_value(&tail, "aiTitle").or_else(|| last_value(&head, "aiTitle"));
    let summary = last_typed_value(&tail, "summary", "summary", false);
    let mut prompt = lite.first_prompt.clone();
    if prompt.is_empty() && custom.as_deref().map_or(true, str::is_empty) && ai.as_deref().map_or(true, str::is_empty) {
        prompt = "(session)".into();
    }
    lite.title = picker_title(custom.as_deref(), ai.as_deref(), summary.as_deref(), &prompt, sid);
    lite.model = last_value(&tail, "model").filter(|m| m.starts_with("claude"));
    Some(lite)
}

// ── Listing ───────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Item {
    /// "claude" (a Claude Code session) or "coucou" (a chat started in Coucou).
    pub kind: &'static str,
    pub id: String,
    pub title: String,
    /// Claude Code: the session's project folder name.
    pub project: String,
    /// Coucou: the provider and model that answered last.
    pub provider: String,
    pub model: String,
    /// Last use, ms since the epoch.
    pub updated: i64,
}

#[derive(Clone)]
struct Cached {
    mtime: i64,
    size: u64,
    lite: Option<Lite>,
}

fn cache() -> &'static Mutex<HashMap<PathBuf, Cached>> {
    static C: OnceLock<Mutex<HashMap<PathBuf, Cached>>> = OnceLock::new();
    C.get_or_init(|| Mutex::new(HashMap::new()))
}

/// One session file through the cache.
fn lite_for(path: &Path, sid: &str) -> Option<(Lite, i64)> {
    let meta = std::fs::metadata(path).ok()?;
    let (mtime, size) = (mtime_ms(&meta), meta.len());
    if let Some(c) = cache().lock().unwrap().get(path) {
        if c.mtime == mtime && c.size == size {
            return c.lite.clone().map(|l| (l, mtime));
        }
    }
    let lite = read_lite(path, size, sid);
    cache().lock().unwrap().insert(path.to_path_buf(), Cached { mtime, size, lite: lite.clone() });
    lite.map(|l| (l, mtime))
}

/// Every session file: (session id, path).
fn session_files() -> Vec<(String, PathBuf)> {
    let mut out = Vec::new();
    let Ok(dirs) = std::fs::read_dir(projects_dir()) else { return out };
    // Sessions copied out of Coucou's chat folder show once: as our copy.
    let legacy = project_slug(&legacy_cli_dir().display().to_string());
    let migrated = migrated_sessions();
    for dir in dirs.flatten() {
        if !dir.file_type().map(|t| t.is_dir()).unwrap_or(false) {
            continue;
        }
        let skip_migrated = !migrated.is_empty() && dir.file_name().to_str() == Some(legacy.as_str());
        let Ok(files) = std::fs::read_dir(dir.path()) else { continue };
        for f in files.flatten() {
            let p = f.path();
            if p.extension().and_then(|e| e.to_str()) != Some("jsonl") {
                continue;
            }
            if !f.file_type().map(|t| t.is_file()).unwrap_or(false) {
                continue;
            }
            if let Some(sid) = p.file_stem().and_then(|s| s.to_str()) {
                if skip_migrated && migrated.contains(sid) {
                    continue;
                }
                out.push((sid.to_string(), p.clone()));
            }
        }
    }
    out
}

fn is_own_session(path: &Path, cwd: Option<&str>) -> bool {
    let own = own_cli_dir();
    let own_str = own.display().to_string();
    cwd == Some(own_str.as_str())
        || path.parent().and_then(|p| p.file_name()).and_then(|n| n.to_str()) == Some(project_slug(&own_str).as_str())
}

fn folder_name(cwd: &str) -> String {
    Path::new(cwd).file_name().and_then(|n| n.to_str()).map(str::to_string).unwrap_or_else(|| cwd.to_string())
}

/// The chats column: Claude Code sessions and Coucou chats, newest first.
pub fn list() -> Vec<Item> {
    let stored = stored_chats();
    let claimed: std::collections::HashSet<String> =
        stored.iter().flat_map(|c| c.cli_ids.iter().cloned().chain(c.cli_session.clone())).collect();
    // Port (his ask): sessions a Coucou chat started in another working folder.
    let elsewhere: std::collections::HashSet<String> = stored.iter().flat_map(|c| c.cli_dirs.keys().cloned()).collect();
    let mut items: Vec<Item> = stored
        .into_iter()
        .map(|c| Item {
            kind: "coucou",
            id: c.id,
            title: c.title,
            project: String::new(),
            provider: c.provider,
            model: c.model,
            updated: c.updated,
        })
        .collect();
    let mut seen_paths = std::collections::HashSet::new();
    for (sid, path) in session_files() {
        seen_paths.insert(path.clone());
        if elsewhere.contains(&sid) {
            continue;
        }
        let Some((lite, mtime)) = lite_for(&path, &sid) else { continue };
        if is_own_session(&path, lite.cwd.as_deref()) {
            if claimed.contains(&sid) || lite.hidden {
                continue;
            }
            items.push(Item {
                kind: "coucou",
                id: format!("cc:{sid}"),
                title: title_of(if lite.head_prompt.is_empty() { &lite.title } else { &lite.head_prompt }),
                project: String::new(),
                provider: crate::claude_code::ID.into(),
                model: lite.model.clone().unwrap_or_default(),
                updated: mtime,
            });
            continue;
        }
        if lite.hidden || lite.sdk {
            continue;
        }
        let project = lite.cwd.as_deref().map(folder_name).unwrap_or_default();
        items.push(Item {
            kind: "claude",
            id: sid,
            title: lite.title,
            project,
            provider: crate::claude_code::ID.into(),
            model: String::new(),
            updated: mtime,
        });
    }
    // Forget files that are gone.
    cache().lock().unwrap().retain(|p, _| seen_paths.contains(p));
    items.sort_by(|a, b| b.updated.cmp(&a.updated));
    items
}

fn collapse(text: &str) -> String {
    text.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// A session's file by id, if it is listed (never a path from the client).
fn session_path(sid: &str) -> Option<PathBuf> {
    session_files().into_iter().find(|(id, _)| id == sid).map(|(_, p)| p)
}

// ── A session's turns ─────────────────────────────────────────────────────────

/// The user / assistant text of a session file, oldest first, the last
/// MAX_TURNS of them (`max` = how many at most), starting with the user.
pub fn read_turns(path: &Path, max: usize) -> std::io::Result<Vec<Value>> {
    let r = BufReader::new(File::open(path)?);
    let mut turns: Vec<(String, String)> = Vec::new();
    for line in r.split(b'\n') {
        let Ok(line) = line else { break };
        let is_user = memfind(&line, b"\"type\":\"user\"");
        let is_assistant = memfind(&line, b"\"type\":\"assistant\"");
        // Port (his ask): where Claude Code compacted the conversation.
        if !is_user && !is_assistant && memfind(&line, b"\"subtype\":\"compact_boundary\"") {
            turns.push(("compact".to_string(), String::new()));
            continue;
        }
        if !is_user && !is_assistant {
            continue;
        }
        let Ok(v) = serde_json::from_slice::<Value>(&line) else { continue };
        let t = v.get("type").and_then(Value::as_str).unwrap_or_default();
        let flag = |k: &str| v.get(k) == Some(&Value::Bool(true));
        if flag("isSidechain") || flag("isMeta") || flag("isCompactSummary") {
            continue;
        }
        match t {
            "user" => {
                let Some(texts) = user_texts(&v) else { continue };
                let text = texts
                    .iter()
                    .filter(|t| !is_harness_text(t))
                    .map(|t| strip_tags(t).trim().to_string())
                    .filter(|t| !t.is_empty())
                    .collect::<Vec<_>>()
                    .join("\n\n");
                if !text.is_empty() {
                    push_turn(&mut turns, "user", text);
                }
            }
            "assistant" => {
                let Some(blocks) = v.pointer("/message/content").and_then(Value::as_array) else { continue };
                let text = blocks
                    .iter()
                    .filter(|b| b.get("type").and_then(Value::as_str) == Some("text"))
                    .filter_map(|b| b.get("text").and_then(Value::as_str))
                    .map(str::trim)
                    .filter(|t| !t.is_empty())
                    .collect::<Vec<_>>()
                    .join("\n\n");
                if !text.is_empty() {
                    push_turn(&mut turns, "assistant", text);
                }
            }
            _ => {}
        }
    }
    let start = turns.len().saturating_sub(max);
    let mut out: Vec<Value> = turns[start..].iter().map(|(r, c)| json!({ "role": r, "content": c })).collect();
    while out.first().is_some_and(|t| t["role"] != "user") {
        out.remove(0);
    }
    Ok(out)
}

fn push_turn(turns: &mut Vec<(String, String)>, role: &str, text: String) {
    match turns.last_mut() {
        Some((r, c)) if r == role => {
            c.push_str("\n\n");
            c.push_str(&text);
        }
        _ => turns.push((role.to_string(), text)),
    }
}

fn memfind(hay: &[u8], needle: &[u8]) -> bool {
    hay.windows(needle.len()).any(|w| w == needle)
}

// ── Coucou's own chats ────────────────────────────────────────────────────────

/// A chat started in Coucou, as saved after each turn.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Stored {
    pub id: String,
    pub title: String,
    pub provider: String,
    pub model: String,
    pub created: i64,
    pub updated: i64,
    /// Plain `{role, content}` turns.
    pub turns: Vec<Value>,
    /// The Claude Code session that saw every turn, if the last ones were its.
    pub cli_session: Option<String>,
    /// Every Claude Code session this chat ran in (they are its, not listed apart).
    pub cli_ids: Vec<String>,
    /// Port (his ask): the chat's working folder (absolute; None = it never
    /// ran Claude Code, or did before this was recorded: Coucou's own folder).
    pub work_dir: Option<String>,
    /// Port (his ask): the sessions it started outside Coucou's own folder,
    /// by id: the folder each lives in (Claude Code resumes it only there).
    pub cli_dirs: std::collections::BTreeMap<String, String>,
}

/// Port (his ask): a chat removed from the column (right-click twice). Its file
/// is moved into Coucou's trash folder, not deleted: a Claude Code session's
/// transcript is his own data, and a misclick should be recoverable
/// (~/.local/share/ambxst-robo/trash/). A session a process is still running is
/// left alone.
pub fn trash(kind: &str, id: &str) -> Result<(), String> {
    // Port (his bug): a Coucou chat hides the Claude Code sessions it ran on
    // (Coucou's own folder): trashed alone, they came back as a card of
    // their own, so a chat took two deletes. They go with it.
    let owned: Vec<PathBuf> = if kind == "coucou" && !id.starts_with("cc:") {
        let chat = load_stored(id);
        // Port (his ask): and those it started in another working folder.
        let elsewhere: std::collections::HashSet<String> = chat.as_ref().map(|c| c.cli_dirs.keys().cloned().collect()).unwrap_or_default();
        chat.map(|c| c.cli_ids.iter().cloned().chain(c.cli_session.clone()).collect::<std::collections::HashSet<_>>())
            .unwrap_or_default()
            .into_iter()
            .filter_map(|sid| session_path(&sid).map(|p| (sid, p)))
            .filter(|(sid, p)| is_own_session(p, None) || elsewhere.contains(sid))
            .map(|(_, p)| p)
            .collect()
    } else {
        Vec::new()
    };
    trash_one(kind, id)?;
    for p in owned {
        let sid = p.file_stem().and_then(|s| s.to_str()).unwrap_or_default().to_string();
        if let Err(e) = trash_one("claude", &sid) {
            crate::log::line(format!("chat history: kept session {sid} of a deleted chat: {e}"));
        }
    }
    Ok(())
}

fn trash_one(kind: &str, id: &str) -> Result<(), String> {
    let gone = || crate::i18n::t("This chat is no longer there.");
    let (from, sub) = match kind {
        "claude" => (session_path(id).ok_or_else(gone)?, "claude"),
        "coucou" => {
            if let Some(sid) = id.strip_prefix("cc:") {
                (session_path(sid).ok_or_else(gone)?, "claude")
            } else {
                if !valid_id(id) {
                    return Err(gone());
                }
                let p = store_dir().join(format!("{id}.json"));
                if !p.is_file() {
                    return Err(gone());
                }
                (p, "coucou")
            }
        }
        _ => return Err(gone()),
    };
    if sub == "claude" {
        let sid = from.file_stem().and_then(|s| s.to_str()).unwrap_or_default().to_string();
        if crate::platform::claude_session_process(&sid).is_some() {
            return Err(crate::i18n::t("This session is still running. Close it first."));
        }
    }
    let dir = crate::settings::local_dir().join("trash").join(sub);
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let name = from.file_name().map(|n| n.to_os_string()).ok_or_else(gone)?;
    let to = dir.join(format!("{}-{}", now_ms(), name.to_string_lossy()));
    if std::fs::rename(&from, &to).is_err() {
        // Another filesystem: copy, then remove.
        std::fs::copy(&from, &to).map_err(|e| e.to_string())?;
        std::fs::remove_file(&from).map_err(|e| e.to_string())?;
    }
    crate::log::line(format!("chat history: moved {} to the trash", name.to_string_lossy()));
    Ok(())
}

fn valid_id(id: &str) -> bool {
    !id.is_empty() && id.len() <= 64 && id.chars().all(|c| c.is_ascii_alphanumeric() || c == '-')
}

pub fn new_id() -> String {
    use std::sync::atomic::{AtomicU32, Ordering};
    static N: AtomicU32 = AtomicU32::new(0);
    format!("{}-{}", now_ms(), N.fetch_add(1, Ordering::Relaxed))
}

fn stored_cache() -> &'static Mutex<HashMap<PathBuf, (i64, u64, Option<Stored>)>> {
    static C: OnceLock<Mutex<HashMap<PathBuf, (i64, u64, Option<Stored>)>>> = OnceLock::new();
    C.get_or_init(|| Mutex::new(HashMap::new()))
}

fn stored_chats() -> Vec<Stored> {
    let mut out = Vec::new();
    let Ok(files) = std::fs::read_dir(store_dir()) else { return out };
    let mut cache = stored_cache().lock().unwrap();
    let mut seen = std::collections::HashSet::new();
    for f in files.flatten() {
        let p = f.path();
        if p.extension().and_then(|e| e.to_str()) != Some("json") {
            continue;
        }
        let Ok(meta) = f.metadata() else { continue };
        let key = (mtime_ms(&meta), meta.len());
        seen.insert(p.clone());
        let chat = match cache.get(&p) {
            Some((m, s, c)) if (*m, *s) == key => c.clone(),
            _ => {
                let c = std::fs::read(&p).ok().and_then(|b| serde_json::from_slice::<Stored>(&b).ok()).filter(|c| valid_id(&c.id));
                cache.insert(p.clone(), (key.0, key.1, c.clone()));
                c
            }
        };
        if let Some(c) = chat {
            out.push(c);
        }
    }
    cache.retain(|p, _| seen.contains(p));
    out
}

pub fn load_stored(id: &str) -> Option<Stored> {
    if !valid_id(id) {
        return None;
    }
    let bytes = std::fs::read(store_dir().join(format!("{id}.json"))).ok()?;
    serde_json::from_slice(&bytes).ok()
}

/// Writes a chat (private folder, file replaced atomically).
pub fn save_stored(chat: &Stored) -> Result<(), String> {
    if !valid_id(&chat.id) {
        return Err("bad chat id".into());
    }
    let dir = store_dir();
    let mut builder = std::fs::DirBuilder::new();
    builder.recursive(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::DirBuilderExt;
        builder.mode(0o700);
    }
    builder.create(&dir).map_err(|e| e.to_string())?;
    let path = dir.join(format!("{}.json", chat.id));
    let tmp = dir.join(format!(".{}.json.tmp", chat.id));
    let bytes = serde_json::to_vec(chat).map_err(|e| e.to_string())?;
    {
        use std::io::Write;
        let mut opts = std::fs::OpenOptions::new();
        opts.write(true).create(true).truncate(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            opts.mode(0o600);
        }
        let mut f = opts.open(&tmp).map_err(|e| e.to_string())?;
        f.write_all(&bytes).map_err(|e| e.to_string())?;
    }
    std::fs::rename(&tmp, &path).map_err(|e| e.to_string())
}

/// A Coucou chat's title: its first message, on one line, trimmed.
pub fn title_of(text: &str) -> String {
    cut(&collapse(text), MAX_TITLE)
}

// ── Opening ───────────────────────────────────────────────────────────────────

/// What `chat_open` hands chat.rs and the island.
pub struct Opened {
    pub turns: Vec<Value>,
    pub provider: String,
    pub model: String,
    pub title: String,
    /// Set for a Claude Code session: resumed in its own folder.
    pub external: Option<crate::chat::External>,
    /// The CLI session the conversation continues (Claude Code), if any.
    pub cli_session: Option<String>,
    /// A saved Coucou chat's record.
    pub stored: Option<Stored>,
    /// An unclaimed Coucou CLI session ("cc:<sid>").
    pub import_key: Option<String>,
    /// Port (his ask): the conversation's working folder (None = the setting's).
    pub work_dir: Option<PathBuf>,
    /// Port (his ask): the folder `cli_session` lives in (None = Coucou's own).
    pub cli_dir: Option<PathBuf>,
}

pub fn open(kind: &str, id: &str) -> Result<Opened, String> {
    let gone = || crate::i18n::t("This chat is no longer there.");
    match kind {
        "claude" => {
            let path = session_path(id).ok_or_else(gone)?;
            let (lite, _) = lite_for(&path, id).ok_or_else(gone)?;
            let cwd = lite.cwd.clone().ok_or_else(gone)?;
            let turns = read_turns(&path, MAX_TURNS).map_err(|e| e.to_string())?;
            Ok(Opened {
                turns,
                provider: crate::claude_code::ID.into(),
                model: String::new(),
                title: lite.title.clone(),
                external: Some(crate::chat::External {
                    session: id.to_string(),
                    project: folder_name(&cwd),
                    cwd: PathBuf::from(&cwd),
                }),
                cli_session: Some(id.to_string()),
                stored: None,
                import_key: None,
                work_dir: Some(PathBuf::from(&cwd)),
                cli_dir: Some(PathBuf::from(&cwd)),
            })
        }
        "coucou" => {
            if let Some(sid) = id.strip_prefix("cc:") {
                let path = session_path(sid).ok_or_else(gone)?;
                let (lite, _) = lite_for(&path, sid).ok_or_else(gone)?;
                if !is_own_session(&path, lite.cwd.as_deref()) {
                    return Err(gone());
                }
                let turns = read_turns(&path, MAX_TURNS).map_err(|e| e.to_string())?;
                let title = turns.iter().find(|t| t["role"] == "user").and_then(|t| t["content"].as_str()).map(title_of).unwrap_or_default();
                return Ok(Opened {
                    turns,
                    provider: crate::claude_code::ID.into(),
                    model: lite.model.unwrap_or_default(),
                    title,
                    external: None,
                    cli_session: Some(sid.to_string()),
                    stored: None,
                    import_key: Some(id.to_string()),
                    work_dir: Some(own_cli_dir()),
                    cli_dir: None,
                });
            }
            let chat = load_stored(id).ok_or_else(gone)?;
            // Port (his ask): it goes on in its own folder; one saved before
            // folders were recorded ran its Claude Code turns in Coucou's.
            let cli_dir = chat.cli_session.as_ref().and_then(|sid| chat.cli_dirs.get(sid)).map(PathBuf::from);
            let work_dir = chat
                .work_dir
                .as_ref()
                .map(PathBuf::from)
                .or_else(|| chat.cli_session.as_ref().map(|_| cli_dir.clone().unwrap_or_else(own_cli_dir)));
            Ok(Opened {
                turns: chat.turns.clone(),
                provider: chat.provider.clone(),
                model: chat.model.clone(),
                title: chat.title.clone(),
                external: None,
                cli_session: chat.cli_session.clone(),
                stored: Some(chat),
                import_key: None,
                work_dir,
                cli_dir,
            })
        }
        _ => Err(format!("unknown chat kind: {kind}")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn values_are_found_first_and_last_and_unescaped() {
        let t = r#"{"type":"ai-title","aiTitle":"One"}
{"type":"x","aiTitle": "Two \"q\""}
{"type":"ai-title","aiTitle":"Thr"#;
        assert_eq!(first_value(t, "aiTitle").as_deref(), Some("One"));
        // The cut last line has no closing quote: the last complete one wins.
        assert_eq!(last_value(t, "aiTitle").as_deref(), Some("Two \"q\""));
        assert_eq!(last_value(t, "nope"), None);
    }

    #[test]
    fn tags_are_stripped_like_the_cli() {
        assert_eq!(strip_tags("<system-reminder>x</system-reminder>\nHello"), "Hello");
        assert_eq!(strip_tags("a <b c=\"d\">x</b> e"), "a  e");
        assert_eq!(strip_tags("1 < 2 and <b>open"), "1 < 2 and <b>open");
        assert_eq!(strip_tags("<A>caps</A>"), "<A>caps</A>");
    }

    #[test]
    fn the_title_follows_the_pickers_order() {
        assert_eq!(picker_title(Some("Mine"), Some("AI"), None, "p", "abcdef123"), "Mine");
        assert_eq!(picker_title(Some(""), Some("AI"), None, "p", "abcdef123"), "AI");
        assert_eq!(picker_title(None, None, Some("Sum"), "p", "abcdef123"), "Sum");
        assert_eq!(picker_title(None, None, None, "fix <x>y</x>the bug", "abcdef123"), "fix the bug");
        assert_eq!(picker_title(None, None, None, "<tick>t</tick>", "abcdef123"), "Autonomous session");
        assert_eq!(picker_title(None, None, None, "", "abcdef123"), "abcdef12");
    }

    #[test]
    fn the_first_prompt_skips_harness_text_and_builtins() {
        let head = [
            r#"{"type":"user","isMeta":true,"message":{"content":"meta"}}"#,
            r#"{"type":"user","message":{"content":"<command-name>/clear</command-name>"}}"#,
            r#"{"type":"user","message":{"content":[{"type":"tool_result","content":"x"}]}}"#,
            r#"{"type":"user","message":{"content":"<local-command-stdout>x</local-command-stdout>"}}"#,
            r#"{"type":"user","message":{"content":[{"type":"text","text":"Fix the\nbar"}]}}"#,
        ]
        .join("\n");
        assert_eq!(first_prompt(&head), "Fix the bar");
        let only_cmd = r#"{"type":"user","message":{"content":"<command-name>/clear</command-name>"}}"#;
        assert_eq!(first_prompt(only_cmd), "/clear");
    }

    #[test]
    fn a_session_reads_as_its_text_turns() {
        let dir = std::env::temp_dir().join(format!("robo-hist-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let p = dir.join("s.jsonl");
        let lines = [
            r#"{"type":"user","parentUuid":null,"cwd":"/w/proj","message":{"role":"user","content":"Hi <system-reminder>r</system-reminder>"}}"#,
            r#"{"type":"assistant","message":{"content":[{"type":"thinking","thinking":"h"},{"type":"text","text":"Hello"}]}}"#,
            r#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read"}]}}"#,
            r#"{"type":"user","message":{"content":[{"type":"tool_result","content":"file"}]}}"#,
            r#"{"type":"assistant","message":{"content":[{"type":"text","text":"Done."}]}}"#,
            r#"{"type":"user","isMeta":true,"message":{"content":"meta"}}"#,
            r#"{"type":"user","message":{"content":"[Request interrupted by user]"}}"#,
            r#"{"type":"ai-title","aiTitle":"Greeting","sessionId":"s"}"#,
            r#"{"type":"last-prompt","lastPrompt":"Hi","sessionId":"s"}"#,
        ];
        std::fs::write(&p, lines.join("\n")).unwrap();
        let turns = read_turns(&p, 80).unwrap();
        assert_eq!(turns, vec![json!({"role":"user","content":"Hi"}), json!({"role":"assistant","content":"Hello\n\nDone."})]);
        let lite = read_lite(&p, std::fs::metadata(&p).unwrap().len(), "s").unwrap();
        assert_eq!(lite.title, "Greeting");
        assert_eq!(lite.cwd.as_deref(), Some("/w/proj"));
        assert!(!lite.hidden);
        // A sidechain anywhere in the head hides the file, as in the picker.
        std::fs::write(&p, format!("{}\n{}", lines.join("\n"), r#"{"type":"user","isSidechain":true,"message":{"content":"side"}}"#)).unwrap();
        assert!(read_lite(&p, std::fs::metadata(&p).unwrap().len(), "s").unwrap().hidden);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
