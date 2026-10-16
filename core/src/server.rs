// The client socket: `$XDG_RUNTIME_DIR/ambxst-robo-core.sock`, newline-delimited JSON.
//
//   → {"id":<n>,"cmd":"<name>","args":{...}}
//   ← {"id":<n>,"ok":true,"result":<json>}  |  {"id":<n>,"ok":false,"error":"<msg>"}
//   ← {"event":"<name>","payload":<json>,"target":<label or null>}   (broadcast)
//
// Every request runs as its own task, so a long one (chat_send streaming, a
// slow integration) never holds up the others. Replies and events share the
// connection's single writer, so lines are never interleaved.

use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::sync::LazyLock;

use serde_json::{json, Value};
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::{UnixListener, UnixStream};
use tokio::sync::{mpsc, Notify};

use crate::host::AppHandle;

/// One request line may carry a chat turn or a settings object, not more.
const MAX_LINE: usize = 4 << 20;

static SHUTDOWN: LazyLock<Notify> = LazyLock::new(Notify::new);

/// quit_app, SIGTERM, SIGINT: the daemon stops serving and exits.
pub fn shutdown() {
    SHUTDOWN.notify_one();
}

pub async fn wait_for_shutdown() {
    SHUTDOWN.notified().await;
}

/// `$XDG_RUNTIME_DIR/ambxst-robo-core.sock`, next to ambxst-robo-hook's socket. Only in a
/// private runtime directory of ours (the same check as the relay socket).
pub fn socket_path() -> Option<PathBuf> {
    crate::platform::relay_socket_path().map(|p| p.with_file_name("ambxst-robo-core.sock"))
}

/// Binds the client socket. Refuses when another live ambxst-robo answers on
/// it; a stale file from a crash is removed.
pub fn bind() -> Result<(UnixListener, PathBuf), String> {
    let path = socket_path().ok_or("no private runtime directory ($XDG_RUNTIME_DIR)")?;
    if path.exists() || std::fs::symlink_metadata(&path).is_ok() {
        if std::os::unix::net::UnixStream::connect(&path).is_ok() {
            return Err(format!("another ambxst-robo is already running on {}", path.display()));
        }
        std::fs::remove_file(&path).map_err(|e| format!("cannot remove stale {}: {e}", path.display()))?;
    }
    // Created closed to everyone else from the start, then made exactly 0600.
    let old = unsafe { libc::umask(0o177) };
    let bound = std::os::unix::net::UnixListener::bind(&path);
    unsafe { libc::umask(old) };
    let std_listener = bound.map_err(|e| format!("cannot bind {}: {e}", path.display()))?;
    let _ = std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600));
    std_listener.set_nonblocking(true).map_err(|e| e.to_string())?;
    let listener = UnixListener::from_std(std_listener).map_err(|e| e.to_string())?;
    Ok((listener, path))
}

pub async fn serve(app: AppHandle, listener: UnixListener) {
    let uid = unsafe { libc::getuid() };
    loop {
        let stream = match listener.accept().await {
            Ok((stream, _)) => stream,
            Err(_) => {
                tokio::time::sleep(std::time::Duration::from_millis(200)).await;
                continue;
            }
        };
        if !matches!(stream.peer_cred(), Ok(c) if c.uid() == uid) {
            crate::log::line("refused a client connection from another user");
            continue;
        }
        let app = app.clone();
        tokio::spawn(async move { client(app, stream).await });
    }
}

async fn client(app: AppHandle, stream: UnixStream) {
    let (read, mut write) = stream.into_split();
    let (tx, mut rx) = mpsc::unbounded_channel::<String>();
    let id = app.add_client(tx.clone());
    crate::log::line(format!("client {id} connected"));

    let writer = tokio::spawn(async move {
        while let Some(mut line) = rx.recv().await {
            line.push('\n');
            if write.write_all(line.as_bytes()).await.is_err() {
                break;
            }
        }
    });

    let mut reader = BufReader::new(read);
    let mut buf = Vec::new();
    loop {
        buf.clear();
        // Bounded read of one line.
        let n = match (&mut reader).take(MAX_LINE as u64 + 1).read_until(b'\n', &mut buf).await {
            Ok(n) => n,
            Err(_) => break,
        };
        if n == 0 {
            break;
        }
        if buf.len() > MAX_LINE {
            let _ = tx.send(reply(Value::Null, Err("request too large".into())));
            break;
        }
        let text = String::from_utf8_lossy(&buf);
        let text = text.trim();
        if text.is_empty() {
            continue;
        }
        let request: Value = match serde_json::from_str(text) {
            Ok(v) => v,
            Err(e) => {
                let _ = tx.send(reply(Value::Null, Err(format!("bad request: {e}"))));
                continue;
            }
        };
        let req_id = request.get("id").cloned().unwrap_or(Value::Null);
        let Some(cmd) = request.get("cmd").and_then(Value::as_str).map(str::to_string) else {
            let _ = tx.send(reply(req_id, Err("bad request: no cmd".into())));
            continue;
        };
        let args = match request.get("args") {
            None | Some(Value::Null) => json!({}),
            Some(v) if v.is_object() => v.clone(),
            Some(_) => {
                let _ = tx.send(reply(req_id, Err("bad request: args must be an object".into())));
                continue;
            }
        };
        if cmd == "files_dropped" {
            // Applied before the next line is read: the shell sends files_dropped
            // and ingest_file back to back, and a spawned files_dropped could lose
            // the race (ingest refused as "not dropped", ~1 drop in 5).
            let result = crate::dispatch(app.clone(), id, cmd, args).await;
            let _ = tx.send(reply(req_id, result));
            continue;
        }
        let app = app.clone();
        let tx = tx.clone();
        tokio::spawn(async move {
            // A panicking command answers with an error instead of silence.
            let result = tokio::spawn(crate::dispatch(app, id, cmd, args))
                .await
                .unwrap_or_else(|e| Err(format!("command panicked: {e}")));
            let _ = tx.send(reply(req_id, result));
        });
    }

    let remaining = app.remove_client(id);
    crate::log::line(format!("client {id} disconnected ({remaining} left)"));
    crate::client_gone(&app, id, remaining);
    drop(tx);
    // The writer ends once the last in-flight reply is sent (or the peer is gone).
    let _ = writer.await;
}

fn reply(id: Value, result: Result<Value, String>) -> String {
    match result {
        Ok(result) => json!({ "id": id, "ok": true, "result": result }),
        Err(error) => json!({ "id": id, "ok": false, "error": error }),
    }
    .to_string()
}
