import QtQuick
import qs.modules.robo as C

// views/views.ts buildNote(): plain card, `.stack` (padding 0 18 0 98, column
// centred): State.noteMessage as a .title.
Item {
    id: root
    property bool viewOn: false
    property string message: ""
    // Arabic: upstream's `html[data-dir=rtl] .stack { direction: rtl }` — the
    // stack's box keeps its physical padding, its contents read right to left.
    readonly property bool rtl: C.Robo.rev >= 0 && C.Robo.lib.I18n.isRtl()
    /** direction: rtl sets the paragraph direction (an RLM as the first strong character). */
    function bidi(s) { return rtl && s ? "\u200F" + s : s; }
    function sync() { if (viewOn) message = C.Robo.state.noteMessage || ""; }
    readonly property int rev: C.Robo.rev
    onRevChanged: sync()
    onViewOnChanged: sync()
    Component.onCompleted: sync()

    Card {
        anchors.fill: parent
        C.CText {
            x: 1 + 98
            width: parent.width - 2 - 98 - 18
            anchors.verticalCenter: parent.verticalCenter
            text: root.bidi(root.message)
            size: 15; cssWeight: 600
            wrapMode: Text.Wrap
            maximumLineCount: 100
            elide: Text.ElideNone
        }
    }
}
