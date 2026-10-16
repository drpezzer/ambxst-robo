// Port only (his ask): the chat's folder chooser, for its working directory
// (settings `chatWorkDir`, chat_pick_work_dir). Through the desktop's own
// chooser: xdg-desktop-portal's FileChooser.OpenFile with `directory`, whose
// answer comes back as the Request object's Response signal. Without a portal
// (or one with no FileChooser), `zenity` or `kdialog` instead. One chooser at
// a time; it blocks, so it runs on a blocking thread.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::time::{Duration, Instant};

use crate::i18n::t;

const PORTAL: &str = "org.freedesktop.portal.Desktop";
const PORTAL_PATH: &str = "/org/freedesktop/portal/desktop";
/// How long a chooser may stay open before it is given up (closed).
const PICK_TIMEOUT: Duration = Duration::from_secs(30 * 60);

static OPEN: AtomicBool = AtomicBool::new(false);

/// Asks for a folder, starting in `start`. Ok(None) = cancelled.
pub fn pick(title: &str, start: Option<&Path>) -> Result<Option<PathBuf>, String> {
    if OPEN.swap(true, Ordering::SeqCst) {
        return Err(t("A folder chooser is already open."));
    }
    struct Done;
    impl Drop for Done {
        fn drop(&mut self) {
            OPEN.store(false, Ordering::SeqCst);
        }
    }
    let _done = Done;
    match portal(title, start) {
        Ok(picked) => Ok(picked),
        Err(e) => {
            crate::log::line(format!("folder chooser: no portal ({e}), trying zenity / kdialog"));
            fallback(title, start)
        }
    }
}

/// FileChooser.OpenFile (directory = true). Err = no usable portal.
fn portal(title: &str, start: Option<&Path>) -> Result<Option<PathBuf>, String> {
    use dbus::arg::{PropMap, Variant};
    use dbus::blocking::Connection;
    use dbus::message::MessageType;

    static N: AtomicU32 = AtomicU32::new(0);
    let conn = Connection::new_session().map_err(|e| e.to_string())?;
    // The Request's path is known before the call (portal spec), so its
    // Response can't be missed; the path the call returns is taken too.
    let sender = conn.unique_name().trim_start_matches(':').replace('.', "_");
    let token = format!("robo_{}_{}", std::process::id(), N.fetch_add(1, Ordering::Relaxed));
    let expected = format!("{PORTAL_PATH}/request/{sender}/{token}");
    conn.add_match_no_cb("type='signal',interface='org.freedesktop.portal.Request',member='Response'")
        .map_err(|e| e.to_string())?;

    let mut options = PropMap::new();
    options.insert("handle_token".into(), Variant(Box::new(token)));
    options.insert("directory".into(), Variant(Box::new(true)));
    options.insert("modal".into(), Variant(Box::new(true)));
    if let Some(dir) = start {
        use std::os::unix::ffi::OsStrExt;
        let mut bytes = dir.as_os_str().as_bytes().to_vec();
        bytes.push(0);
        options.insert("current_folder".into(), Variant(Box::new(bytes)));
    }
    let proxy = conn.with_proxy(PORTAL, PORTAL_PATH, Duration::from_secs(30));
    let (handle,): (dbus::Path<'static>,) = proxy
        .method_call("org.freedesktop.portal.FileChooser", "OpenFile", ("", title, options))
        .map_err(|e| e.to_string())?;
    let handle = handle.to_string();

    let deadline = Instant::now() + PICK_TIMEOUT;
    loop {
        if Instant::now() > deadline {
            let close = conn.with_proxy(PORTAL, handle.as_str(), Duration::from_secs(2));
            let _: Result<(), _> = close.method_call("org.freedesktop.portal.Request", "Close", ());
            crate::log::line("folder chooser: given up after 30 minutes");
            return Ok(None);
        }
        let msg = match conn.channel().blocking_pop_message(Duration::from_millis(500)) {
            Ok(Some(m)) => m,
            Ok(None) => continue,
            // The bus went away mid-choice: nothing was picked.
            Err(e) => {
                crate::log::line(format!("folder chooser: the bus went away: {e}"));
                return Ok(None);
            }
        };
        if msg.msg_type() != MessageType::Signal || msg.member().as_deref() != Some("Response") {
            continue;
        }
        let path = msg.path().map(|p| p.to_string()).unwrap_or_default();
        if path != handle && path != expected {
            continue;
        }
        let (code, results): (u32, PropMap) = msg.read2().map_err(|e| e.to_string())?;
        // 0 = picked, 1 = cancelled, 2 = ended some other way.
        return Ok(if code == 0 { first_uri(&results).and_then(|u| path_of_uri(&u)) } else { None });
    }
}

fn first_uri(results: &dbus::arg::PropMap) -> Option<String> {
    let uris = results.get("uris")?;
    let mut items = uris.0.as_iter()?;
    items.next().and_then(|u| u.as_str()).map(str::to_string)
}

/// A local `file://` URI's path (percent-decoded); None for anything else.
fn path_of_uri(uri: &str) -> Option<PathBuf> {
    use std::os::unix::ffi::OsStringExt;
    let rest = uri.strip_prefix("file://")?;
    // `file://localhost/…` or `file:///…`.
    let rest = rest.strip_prefix("localhost").unwrap_or(rest);
    if !rest.starts_with('/') {
        return None;
    }
    let raw = rest.as_bytes();
    let mut out = Vec::with_capacity(raw.len());
    let mut i = 0;
    while i < raw.len() {
        if raw[i] == b'%' && i + 2 < raw.len() {
            let hex = std::str::from_utf8(&raw[i + 1..i + 3]).ok().and_then(|h| u8::from_str_radix(h, 16).ok());
            if let Some(b) = hex {
                out.push(b);
                i += 3;
                continue;
            }
        }
        out.push(raw[i]);
        i += 1;
    }
    Some(PathBuf::from(std::ffi::OsString::from_vec(out)))
}

/// zenity, else kdialog. Err = neither is installed.
fn fallback(title: &str, start: Option<&Path>) -> Result<Option<PathBuf>, String> {
    if let Some(zenity) = crate::platform::find_on_path("zenity") {
        let mut cmd = std::process::Command::new(zenity);
        cmd.arg("--file-selection").arg("--directory").arg(format!("--title={title}"));
        if let Some(dir) = start {
            cmd.arg(format!("--filename={}/", dir.display()));
        }
        return run_dialog(cmd);
    }
    if let Some(kdialog) = crate::platform::find_on_path("kdialog") {
        let mut cmd = std::process::Command::new(kdialog);
        let from = start.map(Path::to_path_buf).unwrap_or_else(crate::platform::home_dir);
        cmd.arg("--getexistingdirectory").arg(from).arg("--title").arg(title);
        return run_dialog(cmd);
    }
    Err(t("No folder chooser was found (xdg-desktop-portal, zenity or kdialog)."))
}

/// The dialog's answer: its first line when it exits with success.
fn run_dialog(mut cmd: std::process::Command) -> Result<Option<PathBuf>, String> {
    let out = cmd
        .stdin(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .output()
        .map_err(|e| e.to_string())?;
    if !out.status.success() {
        return Ok(None);
    }
    let text = String::from_utf8_lossy(&out.stdout);
    let line = text.lines().next().unwrap_or_default().trim_end();
    Ok((!line.is_empty()).then(|| PathBuf::from(line)))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_portal_uri_reads_as_its_path() {
        assert_eq!(path_of_uri("file:///home/me/My%20Project"), Some(PathBuf::from("/home/me/My Project")));
        assert_eq!(path_of_uri("file://localhost/tmp/x"), Some(PathBuf::from("/tmp/x")));
        assert_eq!(path_of_uri("file:///tmp/%C3%A9t%C3%A9"), Some(PathBuf::from("/tmp/été")));
        assert_eq!(path_of_uri("file:///tmp/100%"), Some(PathBuf::from("/tmp/100%")));
        assert_eq!(path_of_uri("https://example.com/x"), None);
        assert_eq!(path_of_uri("file://host/x"), None);
    }
}
