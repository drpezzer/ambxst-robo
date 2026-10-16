//! Port only (his ask): Claude Code's Remote Control for a chat. The chat's
//! own turns are one `claude -p` each, which Remote Control can't serve: while
//! it is on, an interactive `claude --resume <session> --remote-control` runs
//! in a pseudo-terminal (util-linux `script`), the phone and claude.ai/code
//! drive it, and the chat's messages are typed into it (send). Its hooks reach
//! the island as the conversation's (pipe.rs tags a session a chat holds), so
//! its mini and log follow whatever is said from either side.

use std::collections::HashMap;
use std::process::Stdio;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

use serde_json::{json, Value};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::process::{Child, ChildStdin, Command};

use crate::host::{AppHandle, WINDOW_LABEL};

struct Running {
    pid: i32,
    session: String,
    url: Option<String>,
    stdin: Arc<tokio::sync::Mutex<ChildStdin>>,
}

fn running() -> &'static Mutex<HashMap<String, Running>> {
    static R: OnceLock<Mutex<HashMap<String, Running>>> = OnceLock::new();
    R.get_or_init(|| Mutex::new(HashMap::new()))
}

/// How long the session gets to come up (its URL) before it is given up.
const START_TIMEOUT: Duration = Duration::from_secs(45);
/// The last screen kept to read (bytes): enough for a few redraws.
const SCREEN_KEEP: usize = 64 * 1024;

/// The terminal's text without its escape sequences, and without spaces (the
/// TUI moves the cursor instead of writing them).
fn plain(raw: &str) -> String {
    let mut out = String::with_capacity(raw.len());
    let b = raw.as_bytes();
    let mut i = 0;
    while i < b.len() {
        if b[i] == 0x1b {
            i += 1;
            match b.get(i) {
                Some(b'[') => {
                    i += 1;
                    while i < b.len() && !(0x40..=0x7e).contains(&b[i]) {
                        i += 1;
                    }
                    i += 1;
                }
                Some(b']') => {
                    while i < b.len() && b[i] != 0x07 && !(b[i] == 0x1b && b.get(i + 1) == Some(&b'\\')) {
                        i += 1;
                    }
                    i += if b.get(i) == Some(&0x07) { 1 } else { 2 };
                }
                Some(b'(') | Some(b')') => i += 2,
                _ => i += 1,
            }
            continue;
        }
        // (Multi-byte characters stay whole: only ASCII is looked at.)
        let ch_len = match b[i] {
            0x00..=0x7f => 1,
            0xc0..=0xdf => 2,
            0xe0..=0xef => 3,
            _ => 4,
        };
        let end = (i + ch_len).min(b.len());
        if let Ok(s) = std::str::from_utf8(&b[i..end]) {
            if !s.chars().all(char::is_whitespace) {
                out.push_str(s);
            }
        }
        i = end;
    }
    out
}

/// The session's URL on claude.ai, once the TUI shows it.
fn find_url(text: &str) -> Option<String> {
    let at = text.find("https://claude.ai/code/session_")?;
    let rest = &text[at..];
    let end = rest.find(|c: char| !(c.is_ascii_alphanumeric() || "_-/:.?=&".contains(c))).unwrap_or(rest.len());
    Some(rest[..end].trim_end_matches(['.', '?']).to_string())
}

/// What stops Remote Control, said as the TUI says it, or None.
fn find_error(text: &str) -> Option<String> {
    const KNOWN: [(&str, &str); 6] = [
        ("requiresaclaude.aisubscription", "Remote Control needs a claude.ai subscription login. Run `claude auth login` and choose claude.ai."),
        ("mustbeloggedin", "Remote Control needs a claude.ai login. Run `claude auth login` and choose claude.ai."),
        ("requiresafull-scopelogintoken", "Remote Control needs a full claude.ai login, not a setup token. Run `claude auth login`."),
        ("disabledbyyourorganization", "Remote Control is turned off for your organization."),
        ("RemoteControlfailed", "Remote Control failed to start."),
        ("Previoussessionisunavailable", "Claude Code couldn't bring this chat's Remote Control session back."),
    ];
    KNOWN.iter().find(|(k, _)| text.contains(k)).map(|(_, m)| m.to_string())
}

fn status(conv: &str) -> Value {
    let r = running().lock().unwrap();
    match r.get(conv) {
        Some(x) => json!({ "conv": conv, "on": true, "url": x.url, "sessionId": x.session }),
        None => json!({ "conv": conv, "on": false }),
    }
}

/// Every chat with Remote Control on.
pub fn list() -> Value {
    let r = running().lock().unwrap();
    Value::Array(r.iter().map(|(c, x)| json!({ "conv": c, "on": true, "url": x.url, "sessionId": x.session })).collect())
}

/// A shell-safe session name: letters, digits, spaces, a few marks.
fn name_of(title: &str) -> String {
    let n: String = title.chars().filter(|c| c.is_alphanumeric() || " -_.,".contains(*c)).take(60).collect();
    let n = n.trim().to_string();
    if n.is_empty() { "Robo chat".into() } else { n }
}

/// Turns Remote Control on for `conv`: its URL once it is up.
pub async fn start(app: &AppHandle, conv: &str) -> Result<Value, String> {
    if running().lock().unwrap().contains_key(conv) {
        return Ok(status(conv));
    }
    let chats = app.state::<crate::chat::Chats>();
    // A turn of its own running now (claude -p on the same session): not two at once.
    if chats.get(Some(conv)).map(|c| c.pending().is_some()).unwrap_or(false) {
        return Err("Wait for this chat's answer to finish, then turn Remote Control on.".into());
    }
    let (session, cwd, title) = chats
        .remote_target(conv)
        .ok_or_else(|| "Send this chat a message with Claude Code first: Remote Control continues its session.".to_string())?;
    let dir = match cwd {
        Some(d) if d.is_dir() => d,
        Some(_) => return Err("This session's folder is gone.".into()),
        None => crate::claude_code::work_dir()?,
    };
    let bin = crate::claude_code::find_binary().ok_or("Claude Code isn't installed.")?;
    // The TUI wants a size; the session id is a uuid (no quoting needed).
    if !session.chars().all(|c| c.is_ascii_alphanumeric() || c == '-') {
        return Err("Unexpected session id.".into());
    }
    let inner = format!(
        "stty cols 120 rows 40 2>/dev/null; exec '{}' --resume {} --remote-control '{}'",
        bin.display().to_string().replace('\'', ""),
        session,
        name_of(&title)
    );
    let mut cmd = Command::new("script");
    cmd.args(["-qfec", &inner, "/dev/null"])
        .current_dir(&dir)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .env("TERM", "xterm-256color")
        .process_group(0)
        .kill_on_drop(true);
    // Not a child session of whatever started ambxst-robo.
    for (k, _) in std::env::vars() {
        if k.starts_with("CLAUDE_CODE_") || k == "CLAUDECODE" {
            cmd.env_remove(k);
        }
    }
    let mut child: Child = cmd.spawn().map_err(|e| format!("Couldn't start Claude Code: {e}"))?;
    let pid = child.id().ok_or("Claude Code exited at once.")? as i32;
    let stdin = Arc::new(tokio::sync::Mutex::new(child.stdin.take().ok_or("no stdin")?));
    let mut stdout = child.stdout.take().ok_or("no stdout")?;
    running().lock().unwrap().insert(conv.to_string(), Running { pid, session: session.clone(), url: None, stdin: stdin.clone() });
    crate::log::line(format!("remote: {conv} starts (session {session})"));

    let (tx, rx) = tokio::sync::oneshot::channel::<Result<String, String>>();
    let conv_owned = conv.to_string();
    let app2 = app.clone();
    let stdin2 = stdin.clone();
    tokio::spawn(async move {
        let mut tx = Some(tx);
        let mut screen: Vec<u8> = Vec::new();
        let mut buf = vec![0u8; 16384];
        let mut trusted = false;
        loop {
            let n = match stdout.read(&mut buf).await {
                Ok(0) | Err(_) => break,
                Ok(n) => n,
            };
            screen.extend_from_slice(&buf[..n]);
            if screen.len() > SCREEN_KEEP {
                let cut = screen.len() - SCREEN_KEEP;
                screen.drain(..cut);
            }
            if tx.is_none() {
                continue;
            }
            let text = plain(&String::from_utf8_lossy(&screen));
            // A folder Claude Code hasn't been told to trust asks first: the
            // chat's own folder (or the session's, which it already ran in).
            if !trusted && text.contains("Itrustthisfolder") {
                trusted = true;
                let s = stdin2.clone();
                tokio::spawn(async move {
                    tokio::time::sleep(Duration::from_millis(900)).await;
                    let mut w = s.lock().await;
                    let _ = w.write_all(b"\x1b[B").await;
                    let _ = w.flush().await;
                    drop(w);
                    tokio::time::sleep(Duration::from_millis(900)).await;
                    let mut w = s.lock().await;
                    let _ = w.write_all(b"\r").await;
                    let _ = w.flush().await;
                });
            }
            if let Some(url) = find_url(&text) {
                if let Some(x) = running().lock().unwrap().get_mut(&conv_owned) {
                    x.url = Some(url.clone());
                }
                if let Some(t) = tx.take() {
                    let _ = t.send(Ok(url));
                }
            } else if let Some(err) = find_error(&text) {
                if let Some(t) = tx.take() {
                    let _ = t.send(Err(err));
                }
            }
        }
        // It ended (stopped, or by itself).
        let _ = child.wait().await;
        let was = running().lock().unwrap().remove(&conv_owned).is_some();
        if let Some(t) = tx.take() {
            let tail = plain(&String::from_utf8_lossy(&screen));
            let tail: String = tail.chars().rev().take(160).collect::<Vec<_>>().into_iter().rev().collect();
            let _ = t.send(Err(format!("Claude Code ended before Remote Control came up. {tail}")));
        }
        crate::log::line(format!("remote: {conv_owned} ended"));
        if was {
            let _ = app2.emit_to(WINDOW_LABEL, "remote-changed", json!({ "conv": conv_owned, "on": false }));
        }
    });

    match tokio::time::timeout(START_TIMEOUT, rx).await {
        Ok(Ok(Ok(url))) => {
            let s = status(conv);
            let _ = app.emit_to(WINDOW_LABEL, "remote-changed", &s);
            crate::log::line(format!("remote: {conv} is up at {url}"));
            Ok(s)
        }
        Ok(Ok(Err(e))) => {
            stop(conv);
            Err(e)
        }
        _ => {
            stop(conv);
            Err("Remote Control didn't come up in time.".into())
        }
    }
}

/// Turns Remote Control off for `conv` (the session goes offline on the phone).
pub fn stop(conv: &str) -> bool {
    let Some(x) = running().lock().unwrap().remove(conv) else { return false };
    unsafe {
        libc::killpg(x.pid, libc::SIGTERM);
    }
    let pid = x.pid;
    tokio::spawn(async move {
        tokio::time::sleep(Duration::from_secs(3)).await;
        unsafe {
            libc::killpg(pid, libc::SIGKILL);
        }
    });
    crate::log::line(format!("remote: {conv} stopped"));
    true
}

/// Every Remote Control goes with ambxst-robo.
pub fn stop_all() {
    let convs: Vec<String> = running().lock().unwrap().keys().cloned().collect();
    for c in convs {
        stop(&c);
    }
}

/// Types `text` into `conv`'s Remote Control session (pasted, then sent).
pub async fn send(conv: &str, text: &str) -> Result<(), String> {
    let stdin = running().lock().unwrap().get(conv).map(|x| x.stdin.clone()).ok_or("Remote Control is off for this chat.")?;
    let mut w = stdin.lock().await;
    let mut bytes = b"\x1b[200~".to_vec();
    bytes.extend_from_slice(text.replace('\r', "").as_bytes());
    bytes.extend_from_slice(b"\x1b[201~");
    w.write_all(&bytes).await.map_err(|e| e.to_string())?;
    w.flush().await.map_err(|e| e.to_string())?;
    drop(w);
    // (The paste lands before Enter does.)
    tokio::time::sleep(Duration::from_millis(250)).await;
    let mut w = stdin.lock().await;
    w.write_all(b"\r").await.map_err(|e| e.to_string())?;
    w.flush().await.map_err(|e| e.to_string())?;
    Ok(())
}

/// The QR code of `text`, as rows of "1" (dark) and "0" (light), quiet zone included.
pub fn qr(text: &str) -> Result<Vec<String>, String> {
    let code = qrcode::QrCode::new(text.as_bytes()).map_err(|e| e.to_string())?;
    let w = code.width();
    let colors = code.to_colors();
    let q = 2;
    let mut rows = Vec::with_capacity(w + 2 * q);
    let blank = "0".repeat(w + 2 * q);
    for _ in 0..q {
        rows.push(blank.clone());
    }
    for y in 0..w {
        let mut r = "0".repeat(q);
        for x in 0..w {
            r.push(if colors[y * w + x] == qrcode::Color::Dark { '1' } else { '0' });
        }
        r.push_str(&"0".repeat(q));
        rows.push(r);
    }
    for _ in 0..q {
        rows.push(blank.clone());
    }
    Ok(rows)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_url_is_read_through_the_terminal_noise() {
        let raw = "\x1b[2K/rc\x1b[1C/remote-control is active · Continue here, on your phone, or at https://claude.ai/code/session_01PAc6wcD5jLv4gz6hjusb5k\x1b[0m";
        assert_eq!(find_url(&plain(raw)).as_deref(), Some("https://claude.ai/code/session_01PAc6wcD5jLv4gz6hjusb5k"));
    }

    #[test]
    fn the_trust_question_is_seen() {
        assert!(plain("\x1b[3m❯ No, exit\x1b[0m\r\n  Yes, I trust this folder").contains("Itrustthisfolder"));
    }

    #[test]
    fn a_login_problem_is_named() {
        assert!(find_error(&plain("Remote Control requires a claude.ai subscription.")).unwrap().contains("claude auth login"));
    }

    #[test]
    fn a_qr_is_square_with_its_quiet_zone() {
        let rows = qr("https://claude.ai/mobile").unwrap();
        assert!(rows.iter().all(|r| r.len() == rows.len()));
        assert!(rows[0].chars().all(|c| c == '0'));
    }
}
