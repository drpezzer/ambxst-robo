import QtQuick
import qs.modules.robo as C

// views/views.ts buildEmpty(): plain card, `.stack` laid out as a row
// (padding 0 18 0 118, centred, gap 16): title + sub (gap 5), then Ask Claude.
Item {
    id: root
    property bool viewOn: false
    readonly property var m: C.Robo.rev >= 0 ? C.Robo.lib.Status.texts() : ({})
    // Arabic: upstream's `html[data-dir=rtl] .stack { direction: rtl }` — the
    // stack's box keeps its physical padding, its contents read right to left.
    readonly property bool rtl: C.Robo.rev >= 0 && C.Robo.lib.I18n.isRtl()
    /** direction: rtl sets the paragraph direction (an RLM as the first strong character). */
    function bidi(s) { return rtl && s ? "\u200F" + s : s; }

    Card {
        anchors.fill: parent
        Column {
            // Right to left the row flips: Ask Claude after the 118 px padding, the texts at the right.
            x: root.rtl ? ask.x + ask.width + 16 : 1 + 118
            width: Math.max(0, root.rtl ? parent.width - 1 - 18 - x : ask.x - 16 - x)
            anchors.verticalCenter: parent.verticalCenter
            spacing: 5
            C.CText {
                width: parent.width
                text: root.bidi(root.m.emptyTitle || "")
                size: 15; cssWeight: 600
                wrapMode: Text.Wrap
                maximumLineCount: 100
                elide: Text.ElideNone
            }
            C.CText {
                width: parent.width
                text: root.bidi(root.m.emptySub || "")
                size: 13
                color: C.RoboTheme.dim
                wrapMode: Text.Wrap
                maximumLineCount: 100
                elide: Text.ElideNone
            }
        }
        Btn {
            id: ask
            x: root.rtl ? 1 + 118 : parent.width - 1 - 18 - width
            LayoutMirroring.enabled: root.rtl
            LayoutMirroring.childrenInherit: true
            anchors.verticalCenter: parent.verticalCenter
            label: root.m.askClaude || ""
            kind: "primary"
            onClicked: C.Robo.island && C.Robo.island.actions.setView("prompt")
        }
    }
}
