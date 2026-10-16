// Linux (ambxst-robo): XDG directories for files, xdg-open for links and
// folders, the runtime directory for the relay socket. The GTK / layer-shell
// window code of the Tauri app is gone: the QML shell owns every window.

use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Command;

use super::{home_dir, LocalTime};

/// File name of the Claude Code relay.
pub const HOOK_EXE: &str = "ambxst-robo-hook";

/// Name of the config and data folders, and the relay socket's stem.
pub const APP_DIR: &str = "ambxst-robo";

/// What the coucou-core port used (and the upstream Coucou app, which shares
/// them on Linux). Only `--migrate-from-coucou` (migrate.rs) and the chats
/// column's de-duplication (history.rs) look at these.
pub const LEGACY_APP_DIR: &str = "coucou";
pub const LEGACY_HOOK_EXE: &str = "coucou-hook";

/// Environment variable holding the home directory.
pub const HOME_VAR: &str = "HOME";

// ── Files ─────────────────────────────────────────────────────────────────────

/// An XDG base directory (`$XDG_CONFIG_HOME` …), or its fallback under the home
/// directory when it is unset or not absolute.
fn xdg(var: &str, fallback: &str) -> PathBuf {
    std::env::var_os(var)
        .map(PathBuf::from)
        .filter(|p| p.is_absolute())
        .unwrap_or_else(|| home_dir().join(fallback))
}

/// ~/.config/ambxst-robo — preferences.
pub fn config_dir() -> PathBuf {
    xdg("XDG_CONFIG_HOME", ".config").join(APP_DIR)
}

/// ~/.config/coucou — the coucou-core port's (and upstream Coucou's) preferences.
pub fn legacy_config_dir() -> PathBuf {
    xdg("XDG_CONFIG_HOME", ".config").join(LEGACY_APP_DIR)
}

/// ~/.local/share/ambxst-robo — where ambxst-robo-hook, the inbox and the log live. The
/// relay has to sit at a stable path: an AppImage is mounted somewhere new on
/// every launch.
pub fn local_dir() -> PathBuf {
    xdg("XDG_DATA_HOME", ".local/share").join(APP_DIR)
}

/// ~/.local/share/coucou — the coucou-core port's (and upstream Coucou's) data.
pub fn legacy_local_dir() -> PathBuf {
    xdg("XDG_DATA_HOME", ".local/share").join(LEGACY_APP_DIR)
}

/// Where a saved image goes, best first: the XDG pictures folder named in
/// ~/.config/user-dirs.dirs, then ~/Pictures, ~/Downloads and the home folder.
/// The caller takes the first one that exists.
pub fn picture_dirs() -> Vec<PathBuf> {
    let home = home_dir();
    let mut dirs = Vec::new();
    let user_dirs = xdg("XDG_CONFIG_HOME", ".config").join("user-dirs.dirs");
    if let Ok(text) = std::fs::read_to_string(user_dirs) {
        if let Some(dir) = xdg_user_dir(&text, "XDG_PICTURES_DIR", &home) {
            dirs.push(dir);
        }
    }
    dirs.push(home.join("Pictures"));
    dirs.push(home.join("Downloads"));
    dirs.push(home);
    dirs
}

/// `XDG_PICTURES_DIR="$HOME/Pictures"` → /home/me/Pictures. Only the two forms
/// xdg-user-dirs writes are understood: "$HOME/…" and an absolute path.
fn xdg_user_dir(text: &str, key: &str, home: &Path) -> Option<PathBuf> {
    let line = text.lines().map(str::trim).find(|l| l.starts_with(key))?;
    let value = line.strip_prefix(key)?.trim_start().strip_prefix('=')?.trim();
    let value = value.strip_prefix('"')?.strip_suffix('"')?;
    let path = match value.strip_prefix("$HOME") {
        Some(rest) => home.join(rest.trim_start_matches('/')),
        None => PathBuf::from(value),
    };
    // "$HOME/" alone means "no pictures folder", by the spec.
    (path.is_absolute() && path != home).then_some(path)
}

pub fn local_time() -> LocalTime {
    let mut tm: libc::tm = unsafe { std::mem::zeroed() };
    unsafe {
        let now = libc::time(std::ptr::null_mut());
        libc::localtime_r(&now, &mut tm);
    }
    LocalTime {
        year: (tm.tm_year + 1900) as u32,
        month: (tm.tm_mon + 1) as u32,
        day: tm.tm_mday as u32,
        hour: tm.tm_hour as u32,
        minute: tm.tm_min as u32,
        second: tm.tm_sec as u32,
    }
}

/// Creates `dir` and closes it to other users. The log, the inbox of dropped
/// files and the relay binary live under these directories; with the default
/// umask they would come out 0755 and readable by anyone on the machine.
pub fn ensure_private_dir(dir: &Path) -> std::io::Result<()> {
    std::fs::create_dir_all(dir)?;
    std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700))
}

/// True when `dir` is a real directory (not a symlink), owned by us, with no
/// access for group or others: what `$XDG_RUNTIME_DIR` promises, checked
/// rather than assumed, since the socket in it decides who can answer a
/// permission request.
fn is_private_dir(dir: &Path) -> bool {
    use std::os::unix::fs::MetadataExt;
    std::fs::symlink_metadata(dir)
        .map(|m| {
            m.file_type().is_dir() && m.uid() == unsafe { libc::getuid() } && m.mode() & 0o077 == 0
        })
        .unwrap_or(false)
}

/// Where ambxst-robo-hook finds us: `$XDG_RUNTIME_DIR/ambxst-robo.sock`, or
/// `/run/user/<uid>/ambxst-robo.sock` when the variable is missing. A directory
/// that is not ours and private means no relay at all — never a fallback to a
/// shared place like /tmp. Must match `socket_path()` in hook/src/unix.rs
/// exactly.
pub fn relay_socket_path() -> Option<PathBuf> {
    let dir = std::env::var_os("XDG_RUNTIME_DIR")
        .map(PathBuf::from)
        .filter(|p| p.is_absolute())
        .unwrap_or_else(|| PathBuf::from(format!("/run/user/{}", unsafe { libc::getuid() })));
    is_private_dir(&dir).then(|| dir.join(format!("{APP_DIR}.sock")))
}

// ── Who we are ────────────────────────────────────────────────────────────────

/// The account's full name: the first field of the passwd GECOS entry
/// ("Louis Raille,,,"), or nothing when it is unset.
pub fn user_full_name() -> Option<String> {
    unsafe {
        let mut pwd: libc::passwd = std::mem::zeroed();
        let mut result: *mut libc::passwd = std::ptr::null_mut();
        let mut buf = vec![0 as libc::c_char; 16 * 1024];
        let rc = libc::getpwuid_r(libc::getuid(), &mut pwd, buf.as_mut_ptr(), buf.len(), &mut result);
        if rc != 0 || result.is_null() || pwd.pw_gecos.is_null() {
            return None;
        }
        let gecos = std::ffi::CStr::from_ptr(pwd.pw_gecos).to_string_lossy().into_owned();
        let name = gecos.split(',').next().unwrap_or("").trim().to_string();
        (!name.is_empty()).then_some(name)
    }
}

// ── Processes ─────────────────────────────────────────────────────────────────

/// Nothing to hide: a spawned process only gets a terminal if it asks for one.
pub fn no_console(cmd: &mut Command) -> &mut Command {
    cmd
}

pub fn open_url(url: &str) {
    spawn_reaped(Command::new("xdg-open").arg(url));
}

pub fn reveal_folder(path: &str) {
    spawn_reaped(Command::new("xdg-open").arg(path));
}

/// Port: starts `cmd` and waits for it on a thread of its own, so a finished
/// helper (xdg-open, an editor, a terminal) never lingers as our zombie child
/// (ambxst-robo-update waits for ambxst-robo to have no running child).
pub fn spawn_reaped(cmd: &mut Command) -> bool {
    match cmd.spawn() {
        Ok(mut child) => {
            let _ = std::thread::Builder::new().name("robo-reap".into()).spawn(move || {
                let _ = child.wait();
            });
            true
        }
        Err(_) => false,
    }
}

/// Our own `which`: the first executable file named `stem` on $PATH.
pub fn find_on_path(stem: &str) -> Option<PathBuf> {
    let dirs = std::env::var_os("PATH")?;
    std::env::split_paths(&dirs)
        .map(|dir| dir.join(stem))
        .find(|p| {
            std::fs::metadata(p)
                .map(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
                .unwrap_or(false)
        })
}

// ── Session windows ("Open terminal") ─────────────────────────────────────────
//
// Finding and raising a session's window lives in linux_focus.rs. There is no
// Claude desktop app for Linux.

pub fn open_claude_desktop() -> bool {
    false
}

/// Where the Codex CLI may be, best first: $PATH, then the usual per-user
/// install folders, which a desktop launch often leaves out of $PATH (npm's
/// global prefix, Volta, Bun, pnpm, and nvm with its newest Node first).
pub fn codex_candidates() -> Vec<PathBuf> {
    let home = home_dir();
    let mut out: Vec<PathBuf> = find_on_path("codex").into_iter().collect();
    for dir in [".local/bin", ".npm-global/bin", ".volta/bin", ".bun/bin", ".local/share/pnpm"] {
        out.push(home.join(dir).join("codex"));
    }
    out.push(PathBuf::from("/usr/local/bin/codex"));
    out.push(PathBuf::from("/usr/bin/codex"));
    let nvm = home.join(".nvm/versions/node");
    if let Ok(entries) = std::fs::read_dir(&nvm) {
        let mut versions: Vec<String> =
            entries.filter_map(|e| e.ok()?.file_name().into_string().ok()).collect();
        versions.sort_by(|a, b| crate::codex_plan::compare_versions(b, a));
        out.extend(versions.iter().map(|v| nvm.join(v).join("bin/codex")));
    }
    out.retain(|p| {
        std::fs::metadata(p)
            .map(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
            .unwrap_or(false)
    });
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_a_private_directory_of_ours_can_hold_the_relay_socket() {
        let base = std::env::temp_dir().join(format!("robo-rt-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&base);
        let dir = base.join("runtime");
        std::fs::create_dir_all(&dir).unwrap();
        let set = |mode| std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(mode)).unwrap();

        set(0o700);
        assert!(is_private_dir(&dir));

        // Readable or reachable by group or others: no.
        for open in [0o750, 0o705, 0o755, 0o777, 0o1777] {
            set(open);
            assert!(!is_private_dir(&dir), "{open:o} must be refused");
        }

        // A symlink to a private directory: no, the link itself is what we got.
        set(0o700);
        let link = base.join("link");
        std::os::unix::fs::symlink(&dir, &link).unwrap();
        assert!(!is_private_dir(&link));

        // Missing: no.
        assert!(!is_private_dir(&base.join("missing")));

        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn private_dirs_are_closed_to_everyone_else() {
        use std::os::unix::fs::MetadataExt;
        let dir = std::env::temp_dir().join(format!("robo-priv-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o755)).unwrap();
        ensure_private_dir(&dir).unwrap();
        assert_eq!(std::fs::metadata(&dir).unwrap().mode() & 0o777, 0o700);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn the_pictures_folder_comes_from_user_dirs() {
        let home = Path::new("/home/me");
        let text = "# written by xdg-user-dirs-update\nXDG_DESKTOP_DIR=\"$HOME/Desktop\"\nXDG_PICTURES_DIR=\"$HOME/Images\"\n";
        assert_eq!(xdg_user_dir(text, "XDG_PICTURES_DIR", home), Some(PathBuf::from("/home/me/Images")));
        let absolute = "XDG_PICTURES_DIR=\"/data/pics\"";
        assert_eq!(xdg_user_dir(absolute, "XDG_PICTURES_DIR", home), Some(PathBuf::from("/data/pics")));
        // "$HOME/" means the folder is disabled; relative paths are not paths.
        assert_eq!(xdg_user_dir("XDG_PICTURES_DIR=\"$HOME/\"", "XDG_PICTURES_DIR", home), None);
        assert_eq!(xdg_user_dir("XDG_PICTURES_DIR=\"pics\"", "XDG_PICTURES_DIR", home), None);
        assert_eq!(xdg_user_dir("", "XDG_PICTURES_DIR", home), None);
    }
}
