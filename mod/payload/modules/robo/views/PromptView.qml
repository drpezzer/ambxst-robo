pragma ComponentBehavior: Bound

import QtQuick
import qs.modules.robo as C

// views/chat.ts buildPrompt(): the chat card (indigo wash), the mascot on its left.
// The card's inside is ChatPanel.qml (shared with the Robo tab's home chat);
// the decisions (send flow, picker, streaming) are lib/views/chat.ts.
Item {
    id: root
    property bool viewOn: false

    Component.onCompleted: C.Robo.registerView("prompt", root)
    Component.onDestruction: C.Robo.unregisterView("prompt", root)

    /** ViewHost.focus(): the field takes the keyboard, its text selected. */
    function focusIn() { panel.focusIn(); }

    Card {
        anchors.fill: parent
        // Port (his ask): the chat's own colour (Robo.chatWash).
        wash: C.Robo.chatWash
        ChatPanel {
            id: panel
            anchors.fill: parent
            leftPad: 84
            where: "prompt"
        }
    }
}
