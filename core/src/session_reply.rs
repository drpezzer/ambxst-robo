// Port only (his ask): the "Claude Code finished" popup shows Claude's whole
// last answer and takes a reply, without opening the terminal.
//
// - The answer comes from the session's own transcript
//   (~/.claude/projects/<project>/<id>.jsonl): the Stop hook's
//   last_assistant_message is capped by the relay (2 000 characters).
// - A reply to a session running in kitty is typed into that very window
//   (kitty remote control, `allow_remote_control socket-only`): the session
//   reads it as if typed there. The window is the one the session's own
//   process says it runs in (KITTY_LISTEN_ON / KITTY_WINDOW_ID).

use std::io::{Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use serde_json::Value;

/// How much of a transcript's end is read for its last answer.
const TAIL: u64 = 6 * 1024 * 1024;
/// The longest answer handed to the island.
const MAX_REPLY: usize = 60_000;

/// `id` as a Claude Code session id (a UUID): nothing else reaches a path.
fn valid_id(id: &str) -> bool {
    !id.is_empty() && id.len() <= 64 && id.chars().all(|c| c.is_ascii_hexdigit() || c == '-')
}

/// The session's transcript, in whichever project it lives.
pub fn transcript(id: &str) -> Option<PathBuf> {
    if !valid_id(id) {
        return None;
    }
    let name = format!("{id}.jsonl");
    std::fs::read_dir(crate::history::projects_dir())
        .ok()?
        .flatten()
        .map(|d| d.path().join(&name))
        .find(|p| p.is_file())
}

/// The text of a transcript line's message content (text blocks only).
fn texts(content: &Value) -> Vec<String> {
    match content {
        Value::String(s) => vec![s.clone()],
        Value::Array(blocks) => blocks
            .iter()
            .filter(|b| b.get("type").and_then(Value::as_str) == Some("text"))
            .filter_map(|b| b.get("text").and_then(Value::as_str).map(str::to_string))
            .collect(),
        _ => Vec::new(),
    }
}

/// The last answer in transcript `text`: the assistant's text after the last
/// user line (a prompt or a tool result), in order. None when it ends on the user.
pub fn last_reply_in(text: &str) -> Option<String> {
    let mut parts: Vec<String> = Vec::new();
    for line in text.lines().rev() {
        let Ok(v) = serde_json::from_str::<Value>(line) else { continue };
        match v.get("type").and_then(Value::as_str) {
            Some("assistant") => {
                let mut t = texts(v.pointer("/message/content").unwrap_or(&Value::Null));
                t.reverse();
                parts.extend(t.into_iter().filter(|s| !s.trim().is_empty()));
            }
            Some("user") => {
                if v.get("isMeta").and_then(Value::as_bool) == Some(true) {
                    continue;
                }
                break;
            }
            _ => {}
        }
    }
    if parts.is_empty() {
        return None;
    }
    parts.reverse();
    let mut joined = parts.join("\n\n");
    if joined.len() > MAX_REPLY {
        let mut cut = MAX_REPLY;
        while !joined.is_char_boundary(cut) {
            cut -= 1;
        }
        joined.truncate(cut);
        joined.push('…');
    }
    Some(joined)
}

fn read_tail(path: &Path) -> Option<String> {
    let mut f = std::fs::File::open(path).ok()?;
    let len = f.metadata().ok()?.len();
    let start = len.saturating_sub(TAIL);
    f.seek(SeekFrom::Start(start)).ok()?;
    let mut buf = Vec::new();
    f.read_to_end(&mut buf).ok()?;
    let text = String::from_utf8_lossy(&buf).into_owned();
    // A cut first line is not JSON: skip it.
    Some(if start > 0 { text.split_once('\n').map(|(_, rest)| rest.to_string()).unwrap_or_default() } else { text })
}

/// Session `id`'s last answer, whole.
pub fn last_reply(id: &str) -> Option<String> {
    last_reply_in(&read_tail(&transcript(id)?)?)
}

/// KITTY_LISTEN_ON and KITTY_WINDOW_ID of process `pid`.
fn kitty_window(pid: u32) -> Option<(String, String)> {
    let env = std::fs::read(format!("/proc/{pid}/environ")).ok()?;
    let (mut to, mut wid) = (None, None);
    for kv in env.split(|b| *b == 0) {
        let kv = String::from_utf8_lossy(kv);
        if let Some(v) = kv.strip_prefix("KITTY_LISTEN_ON=") {
            to = Some(v.to_string());
        } else if let Some(v) = kv.strip_prefix("KITTY_WINDOW_ID=") {
            wid = Some(v.to_string());
        }
    }
    let wid = wid.filter(|w| !w.is_empty() && w.chars().all(|c| c.is_ascii_digit()))?;
    Some((to.filter(|t| t.starts_with("unix:"))?, wid))
}

fn kitty_send(to: &str, wid: &str, stdin_text: Option<&str>, arg_text: Option<&str>) -> Result<(), String> {
    let mut cmd = Command::new("kitty");
    cmd.args(["@", "--to", to, "send-text", "--match", &format!("id:{wid}")]);
    if stdin_text.is_some() {
        cmd.args(["--stdin", "--bracketed-paste=enable"]);
    }
    if let Some(t) = arg_text {
        cmd.args(["--", t]);
    }
    cmd.stdin(if stdin_text.is_some() { Stdio::piped() } else { Stdio::null() })
        .stdout(Stdio::null())
        .stderr(Stdio::piped());
    let mut child = cmd.spawn().map_err(|e| format!("kitty: {e}"))?;
    if let Some(t) = stdin_text {
        if let Some(mut si) = child.stdin.take() {
            si.write_all(t.as_bytes()).map_err(|e| format!("kitty: {e}"))?;
        }
    }
    let out = child.wait_with_output().map_err(|e| format!("kitty: {e}"))?;
    if !out.status.success() {
        return Err(format!("kitty: {}", String::from_utf8_lossy(&out.stderr).trim()));
    }
    Ok(())
}

/// Types `text` into the kitty window session `id` runs in, then Enter.
/// Err when the session runs nowhere Coucou can type into.
pub fn send_to_terminal(id: &str, text: &str) -> Result<(), String> {
    let text = text.trim();
    if text.is_empty() {
        return Err("Nothing to send.".into());
    }
    if !valid_id(id) {
        return Err("Unknown session.".into());
    }
    let pid = crate::platform::claude_session_process(id).ok_or("That session isn't running any more.")?;
    let (to, wid) = kitty_window(pid).ok_or("That session isn't in a kitty window Robo can type into.")?;
    // Pasted (newlines stay in the message), then submitted.
    kitty_send(&to, &wid, Some(text), None)?;
    std::thread::sleep(std::time::Duration::from_millis(60));
    kitty_send(&to, &wid, None, Some("\r"))?;
    crate::log::line(format!("session reply: {} chars into kitty window {wid}", text.chars().count()));
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_last_reply_is_the_text_after_the_last_user_line() {
        let t = [
            r#"{"type":"user","message":{"role":"user","content":"first"}}"#,
            r#"{"type":"assistant","message":{"content":[{"type":"text","text":"old answer"}]}}"#,
            r#"{"type":"user","message":{"role":"user","content":"do it"}}"#,
            r#"{"type":"assistant","message":{"content":[{"type":"text","text":"Looking."},{"type":"tool_use","id":"t","name":"Bash","input":{}}]}}"#,
            r#"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t","content":"ok"}]}}"#,
            r#"{"type":"assistant","message":{"content":[{"type":"text","text":"Done: **all good**."}]}}"#,
            r#"{"type":"assistant","message":{"content":[{"type":"text","text":"Second part."}]}}"#,
            r#"{"type":"system","subtype":"stop"}"#,
        ]
        .join("\n");
        assert_eq!(last_reply_in(&t).as_deref(), Some("Done: **all good**.\n\nSecond part."));
        assert_eq!(last_reply_in(r#"{"type":"user","message":{"content":"hi"}}"#), None);
    }

    #[test]
    fn only_session_ids_reach_a_path() {
        assert!(valid_id("33145e73-1aea-443c-85a1-03089c56cf52"));
        assert!(!valid_id("../../etc/passwd"));
        assert!(!valid_id(""));
        assert!(transcript("not/a/session").is_none());
    }
}
