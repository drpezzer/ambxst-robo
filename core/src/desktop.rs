// The mascot on the desktop, ambxst-robo edition.
//
// The Tauri app owned a second window for the desktop mascot (layer surface on
// Wayland, ordinary window on X11) and flew it around from Rust. In the Ambxst
// port that window is a QML layer window, so everything window-shaped is gone.
// What is kept is the part that is plain state: whether he was on the desktop
// when the app quit, and the spot where the user last left him, both stored in
// settings.json under `desktopMascot` exactly as Coucou stores them.

use serde::Serialize;
use serde_json::Value;

use crate::platform::DesktopMode;
use crate::settings::{self, DesktopMascotPref, DesktopSpot};
use crate::Shared;

const MODE: DesktopMode = DesktopMode::Layer;

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DesktopInfo {
    /// Always "layer": the shell's window is a layer surface.
    mode: &'static str,
    /// He was on the desktop when the app last quit.
    on_desktop: bool,
    /// Top-left corner where the user last left him, in logical pixels from
    /// the top-left corner of the island's display; null when never placed.
    spot: Option<DesktopSpot>,
}

pub fn desktop_mascot_info(shared: &Shared) -> DesktopInfo {
    let pref = shared.settings.lock().unwrap().desktop_mascot.clone();
    // A spot saved under another kind of session (X11 "screen" space) is not trusted.
    let spot = pref.spot.filter(|s| s.space == MODE.space());
    DesktopInfo { mode: MODE.as_str(), on_desktop: pref.on_desktop, spot }
}

/// Saves what changed about him. `on_desktop`: absent leaves it; `spot`:
/// absent leaves it, null forgets it, `{x, y}` stores it.
pub fn desktop_mascot_remember(shared: &Shared, on_desktop: Option<bool>, spot: Option<Value>) -> Result<DesktopInfo, String> {
    let spot = match spot {
        None => None,
        Some(Value::Null) => Some(None),
        Some(v) => {
            let x = v.get("x").and_then(Value::as_f64).ok_or("spot.x missing")?;
            let y = v.get("y").and_then(Value::as_f64).ok_or("spot.y missing")?;
            if !(x.is_finite() && y.is_finite()) {
                return Err("spot must be finite".into());
            }
            Some(Some(DesktopSpot { x, y, space: MODE.space().to_string() }))
        }
    };
    let snapshot = {
        let mut s = shared.settings.lock().unwrap();
        let p: &mut DesktopMascotPref = &mut s.desktop_mascot;
        if let Some(on) = on_desktop {
            p.on_desktop = on;
        }
        if let Some(spot) = spot {
            p.spot = spot;
        }
        s.clone()
    };
    if let Err(err) = settings::save(&snapshot) {
        crate::log::line(format!("could not save settings: {err}"));
    }
    Ok(desktop_mascot_info(shared))
}
