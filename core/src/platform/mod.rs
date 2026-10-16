// Everything that differs between operating systems, behind one set of names.
//
// The rest of the app calls `platform::…` and never touches Win32 or a Linux
// API directly. Each OS file exposes the same functions; the compiler picks one.

use std::path::PathBuf;

#[cfg(target_os = "linux")]
mod linux;
#[cfg(target_os = "linux")]
pub use self::linux::*;
// "Open terminal" on Linux: the process tree from /proc, then KWin, EWMH, kitty.
#[cfg(target_os = "linux")]
mod linux_focus;
#[cfg(target_os = "linux")]
pub use self::linux_focus::{claude_session_process, focus_session_window, is_our_descendant, process_ancestors, window_owners};

/// Wall-clock time in the user's time zone, for log lines and backup names.
pub struct LocalTime {
    pub year: u32,
    pub month: u32,
    pub day: u32,
    pub hour: u32,
    pub minute: u32,
    pub second: u32,
}

/// The user's home directory, where `.claude/settings.json` lives.
pub fn home_dir() -> PathBuf {
    std::env::var_os(HOME_VAR)
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."))
}

/// How the desktop mascot's window is placed. In ambxst-robo the QML shell owns
/// that window, always a layer surface, so only `Layer` is ever reported.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum DesktopMode {
    Layer,
}

impl DesktopMode {
    pub fn as_str(self) -> &'static str {
        "layer"
    }

    /// The space a saved spot is measured in (logical pixels from the top-left
    /// corner of the island's display).
    pub fn space(self) -> &'static str {
        "layer"
    }
}
