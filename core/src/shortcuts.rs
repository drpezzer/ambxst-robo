// Global keyboard shortcuts in ambxst-robo: the configuration only.
//
// In the Tauri app the shortcuts were registered from Rust (X11 key grabs, the
// XDG GlobalShortcuts portal on Wayland). In the Ambxst port the shell owns the
// keyboard: it binds the keys itself (Hyprland binds / the mod), and hands a
// press to the island with the `shortcut_dispatch` command, or
// `ambxst-robo --shortcut <action id>` from a compositor bind. What is kept here
// is the action table (ids, defaults), the stored bindings type and a status
// report Settings can show.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use crate::host::{AppHandle, WINDOW_LABEL};

/// One global action, as on the Mac (`ShortcutAction`). The ids are the Mac's
/// raw values and are stored in settings.json: never rename one.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ActionDef {
    pub id: &'static str,
    pub default_keys: &'static str,
    pub enabled_by_default: bool,
    /// False for the Mac actions this version cannot do yet. Their ids and
    /// defaults stay reserved so a later port lands on the same keys.
    pub ported: bool,
}

const fn action(id: &'static str, keys: &'static str, on: bool, ported: bool) -> ActionDef {
    ActionDef { id, default_keys: keys, enabled_by_default: on, ported }
}

/// Same order as `ShortcutAction.allCases`.
pub const ACTIONS: &[ActionDef] = &[
    action("toggleIsland", "Ctrl+Alt+N", false, true),
    action("openChat", "Ctrl+Alt+Space", true, true),
    action("goToAlert", "Ctrl+Alt+A", true, true),
    action("jumpToTerminal", "Ctrl+Alt+T", true, true),
    // Dragging the mascot onto a window is not in this version.
    action("attachFrontWindow", "Ctrl+Alt+F", true, false),
    action("nextPill", "Ctrl+Alt+Right", true, true),
    action("prevPill", "Ctrl+Alt+Left", true, true),
    action("muteToggle", "Ctrl+Alt+S", true, true),
    action("desktopToggle", "Ctrl+Alt+D", true, true),
    action("wardrobeToggle", "Ctrl+Alt+G", true, true),
];

pub fn find(id: &str) -> Option<&'static ActionDef> {
    ACTIONS.iter().find(|a| a.id == id)
}

/// What the user chose for one action. An action missing from settings.json
/// uses its default; `keys` empty means no key at all.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Binding {
    pub keys: String,
    pub enabled: bool,
}

impl Default for Binding {
    fn default() -> Self {
        Self { keys: String::new(), enabled: true }
    }
}

/// `settings.shortcuts`: only the actions the user changed.
pub type Bindings = BTreeMap<String, Binding>;

/// The binding in force for `def`: the stored one, or the default.
pub fn effective(def: &ActionDef, stored: &Bindings) -> Binding {
    stored.get(def.id).cloned().unwrap_or_else(|| Binding {
        keys: def.default_keys.to_string(),
        enabled: def.enabled_by_default,
    })
}

// ── Status shown in Settings ──────────────────────────────────────────────────

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Status {
    /// Turned off, or no key.
    Off,
    /// Enabled: the shell binds it (ambxst-robo registers nothing itself).
    Unsupported,
    /// The action itself isn't in this version.
    NotPorted,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ActionStatus {
    pub id: &'static str,
    pub status: Status,
    /// The keys stored for it (or its default), for the shell to bind.
    pub keys: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Report {
    pub actions: Vec<ActionStatus>,
    /// Always "shell": nothing is registered by ambxst-robo.
    pub blocked: Option<String>,
    /// `ambxst-robo --shortcut`: append an action id for a compositor bind.
    pub command: String,
    pub portal: Option<String>,
}

pub fn status(stored: &Bindings) -> Report {
    let actions = ACTIONS
        .iter()
        .map(|def| {
            let b = effective(def, stored);
            let status = if !def.ported {
                Status::NotPorted
            } else if !b.enabled || b.keys.is_empty() {
                Status::Off
            } else {
                Status::Unsupported
            };
            ActionStatus { id: def.id, status, keys: b.keys }
        })
        .collect();
    let exe = std::env::current_exe()
        .map(|p| p.to_string_lossy().to_string())
        .unwrap_or_else(|_| "ambxst-robo".into());
    Report { actions, blocked: Some("shell".into()), command: format!("{exe} --shortcut"), portal: None }
}

/// `--shortcut <id>` → the action id, when it names a ported one.
pub fn from_args(args: &[String]) -> Option<&'static str> {
    let at = args.iter().position(|a| a == "--shortcut")?;
    let def = find(args.get(at + 1)?)?;
    def.ported.then_some(def.id)
}

/// Hands an action to the island, exactly as the Tauri app did.
pub fn dispatch(app: &AppHandle, action: &str) {
    crate::log::line(format!("shortcut {action}"));
    if action == "wardrobeToggle" {
        let _ = app.emit_to(WINDOW_LABEL, "open-wardrobe", ());
    } else {
        let _ = app.emit_to(WINDOW_LABEL, "shortcut", action.to_string());
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const MAC_IDS: [&str; 10] = [
        "toggleIsland", "openChat", "goToAlert", "jumpToTerminal", "attachFrontWindow",
        "nextPill", "prevPill", "muteToggle", "desktopToggle", "wardrobeToggle",
    ];

    #[test]
    fn every_mac_action_has_a_default_and_keeps_its_id() {
        let ids: Vec<_> = ACTIONS.iter().map(|a| a.id).collect();
        assert_eq!(ids, MAC_IDS);
    }

    #[test]
    fn only_the_island_toggle_is_off_by_default() {
        for def in ACTIONS {
            assert_eq!(def.enabled_by_default, def.id != "toggleIsland", "{}", def.id);
        }
    }

    #[test]
    fn shortcut_args_name_a_ported_action() {
        let args = |v: &[&str]| v.iter().map(|s| s.to_string()).collect::<Vec<_>>();
        assert_eq!(from_args(&args(&["x", "--shortcut", "openChat"])), Some("openChat"));
        assert_eq!(from_args(&args(&["x", "--shortcut", "attachFrontWindow"])), None);
        assert_eq!(from_args(&args(&["x", "--shortcut", "nope"])), None);
        assert_eq!(from_args(&args(&["x"])), None);
    }
}
