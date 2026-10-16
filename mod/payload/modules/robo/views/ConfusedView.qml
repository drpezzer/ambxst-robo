import QtQuick
import qs.modules.robo as C

// views/views.ts buildConfused(): pink card, `.stack` (padding 0 18 0 128,
// column centred, gap 5): title + sub. The header hides itself (Header.qml).
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
        wash: "pink"
        Column {
            x: 1 + 128
            width: parent.width - 2 - 128 - 18
            anchors.verticalCenter: parent.verticalCenter
            spacing: 5
            C.CText {
                width: parent.width
                text: root.bidi(root.m.confusedTitle || "")
                size: 15; cssWeight: 600
                wrapMode: Text.Wrap
                maximumLineCount: 100
                elide: Text.ElideNone
            }
            C.CText {
                width: parent.width
                text: root.bidi(root.m.confusedSub || "")
                size: 13
                color: C.RoboTheme.dim
                wrapMode: Text.Wrap
                maximumLineCount: 100
                elide: Text.ElideNone
            }
        }
    }
}
