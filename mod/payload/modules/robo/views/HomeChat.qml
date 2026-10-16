pragma ComponentBehavior: Bound

import QtQuick
import qs.modules.robo as C

// Port only: the Robo tab's home chat, under the island while it shows its
// home (overview / empty). The chat view's card (indigo wash) without the mascot,
// as tall as the room left: the same conversation as the chat view (both
// draw lib/views/chat.ts's one chat), its field, model button and picker;
// permission and question cards still come up in the island. Shown and
// hidden like an island view (style.css .view / .view.on).
Item {
    id: root
    readonly property var st: C.Robo.state
    readonly property string view: C.Robo.rev >= 0 ? st.view : ""
    readonly property bool on: C.Robo.rev >= 0 && st.mode === "expanded" && (view === "overview" || view === "empty")
    /** Where Escape hands the keyboard back (the tab). */
    property Item keyTarget: null
    /** The field has the keyboard. */
    readonly property bool typing: panelLoader.item ? panelLoader.item.typing : false
    // The chat (plain JS) is made before its panel: making it notifies, which
    // would re-enter the panel's own bindings while they are first evaluated.
    property bool chatReady: false
    Component.onCompleted: {
        C.Robo.lib.ChatView.chat();
        chatReady = true;
    }

    opacity: on ? 1 : 0
    scale: on ? 1 : 0.97
    enabled: on
    visible: opacity > 0 || on
    // .view.on: opacity 0.3 s ease-out AFTER 0.16 s; leaving: 0.16 s ease-in at once.
    // Port: during the tab's launch reveal (C.Robo.introBoxes < 1) it shows
    // at once: the reveal's own slide brings it in, with the other boxes.
    readonly property bool inReveal: C.Robo.introBoxes < 1
    Behavior on opacity {
        SequentialAnimation {
            PauseAnimation { duration: root.on && !root.inReveal ? 160 : 0 }
            NumberAnimation {
                duration: root.inReveal ? 0 : root.on ? 300 : 160
                easing.type: Easing.BezierSpline
                easing.bezierCurve: root.on ? C.RoboTheme.easeOut : C.RoboTheme.easeIn
            }
        }
    }
    Behavior on scale {
        SequentialAnimation {
            PauseAnimation { duration: root.on && !root.inReveal ? 160 : 0 }
            NumberAnimation {
                duration: root.on && !root.inReveal ? 300 : 0
                easing.type: Easing.BezierSpline
                easing.bezierCurve: [0.3, 1.2, 0.4, 1, 1, 1]
            }
        }
    }
    // Leaving home with the field focused: the keyboard goes back to the tab
    // (its keys reach the island again).
    onOnChanged: if (!on && typing && keyTarget) keyTarget.forceActiveFocus()

    Card {
        anchors.fill: parent
        // Port (his ask): the chat's own colour (Robo.chatWash).
        wash: C.Robo.chatWash
        Loader {
            id: panelLoader
            anchors.fill: parent
            active: root.chatReady
            sourceComponent: ChatPanel {
                leftPad: 16
                // The picker belongs to the home view it was opened in.
                where: root.view === "empty" ? "empty" : "overview"
                onEscaped: if (root.keyTarget) root.keyTarget.forceActiveFocus()
            }
        }
    }
}
