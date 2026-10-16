import QtQuick
import Quickshell

// Coucou's Settings window (upstream lib.rs create_settings_window): 560×680,
// at least 460×480, resizable, centred; closing only hides it, and it is
// reused (RoboSettings keeps it). Ambxst's own settings window trick for
// floating at map: the size is fixed until the compositor has placed it.
FloatingWindow {
    id: win
    title: "Ambxst Robo Settings"
    implicitWidth: 560
    implicitHeight: 680
    color: SettingsTheme.bg

    property bool floatLocked: true
    minimumSize: floatLocked ? Qt.size(560, 680) : Qt.size(460, 480)
    maximumSize: floatLocked ? Qt.size(560, 680) : Qt.size(16777215, 16777215)
    Timer { id: release; interval: 400; onTriggered: win.floatLocked = false }

    readonly property alias page: page
    readonly property bool recordingShortcut: page.recordingShortcut

    /** upstream show_settings_window: show (un-minimised) and focus; `section` scrolls to it. */
    function open(section) {
        if (!visible) {
            floatLocked = true;
            visible = true;
            release.restart();
        }
        page.reload().then(() => { if (section) Qt.callLater(() => page.scrollTo(section)); });
    }

    RoboSettingsPage {
        id: page
        anchors.fill: parent
        window: win
        focus: true
    }
}
