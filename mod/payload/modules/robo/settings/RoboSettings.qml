import QtQuick
import Quickshell
import qs.modules.globals
import qs.modules.services
import qs.modules.robo as C

// Opens Robo's Settings window. The island asks through
// Bridge.openSettingsWindow() → Robo.windowCommand("open_settings_window");
// the shell (tray menu, bar) calls open(section). The window is created on
// the first open and then only shown and hidden, like upstream's.
// Instantiate once in the shell: `RoboSettings { id: roboSettings }`.
// Sections: claude, agents, plan, api, chat, local, pills, integrations,
// general, shortcuts.
Scope {
    id: root
    /** The window, once it exists. */
    readonly property var window: loader.item
    /** True while a shortcut is being recorded in Settings: the shell may drop
     *  its Hyprland binds meanwhile (upstream suspends its grabs). */
    readonly property bool recordingShortcut: (loader.item ? loader.item.recordingShortcut : false)
        || (C.Robo.settingsPage ? C.Robo.settingsPage.recordingShortcut : false)

    /** Ambxst's settings window: the AI tab (SettingsTab panel 3). */
    readonly property int aiSettingsTab: 3

    // Port (his ask): Robo's settings are in Ambxst's settings window, AI tab
    // (its Robo pane, the AiPanel patch), not a window of their own.
    function open(section) {
        if (!GlobalStates.settingsWindowVisible)
            GlobalShortcuts.toggleSettings();
        GlobalStates.settingsCurrentTab = root.aiSettingsTab;
        C.Robo.settingsRequest = { section: section || "", n: C.Robo.settingsRequest.n + 1 };
        // A window opened just now builds its tab list after this and goes
        // back to the first tab (SettingsTab onFilteredSectionsChanged): ask
        // again once it has.
        reselect.tries = 0;
        reselect.restart();
    }
    Timer {
        id: reselect
        property int tries: 0
        // Up to ~2 s: from the chat page the notch first gives back the
        // keyboard and the window builds later than from home, after the old
        // 0.5 s of retries had run out (so it stayed on its first tab).
        interval: 100
        repeat: true
        onTriggered: {
            if (GlobalStates.settingsWindowVisible) GlobalStates.settingsCurrentTab = root.aiSettingsTab;
            if (++tries >= 20) stop();
        }
    }
    /** Upstream's own window, kept for a host without Ambxst's settings. */
    function openWindow(section) {
        pendingSection = section || "";
        if (loader.item) { loader.item.open(pendingSection); return; }
        loader.active = true;
    }
    function close() { if (loader.item) loader.item.visible = false; }
    property string pendingSection: ""

    LazyLoader {
        id: loader
        active: false
        RoboSettingsWindow { visible: false }
        onItemChanged: if (item) item.open(root.pendingSection)
    }

    Connections {
        target: C.Robo
        function onWindowCommand(cmd, args) {
            if (cmd === "open_settings_window") root.open(args && args.section ? args.section : "");
        }
    }
}
