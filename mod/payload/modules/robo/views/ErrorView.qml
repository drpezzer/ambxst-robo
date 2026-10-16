import QtQuick
import qs.modules.robo as C

// views/views.ts buildError(): red card, `.stack` (padding 4 16 4 116, column
// centred, gap 5): who row, .title (600 15px), .detail (400 12px --red-text,
// the last text step), Retry / Open in n8n.
Item {
    id: root
    property bool viewOn: false
    readonly property var lib: C.Robo.lib
    readonly property int rev: C.Robo.rev
    property var task: null
    property var m: ({ who: "", title: "", detail: "", retry: "", openN8n: "" })
    // Arabic: upstream's `html[data-dir=rtl] .stack { direction: rtl }` — the
    // stack's box keeps its physical padding, its contents read right to left.
    readonly property bool rtl: C.Robo.rev >= 0 && C.Robo.lib.I18n.isRtl()
    /** direction: rtl sets the paragraph direction (an RLM as the first strong character). */
    function bidi(s) { return rtl && s ? "\u200F" + s : s; }

    function sync() {
        if (!viewOn) return;
        task = C.Robo.state.focusTask;
        m = lib.Status.error(task);
    }
    onRevChanged: sync()
    onViewOnChanged: sync()
    Component.onCompleted: sync()

    Card {
        anchors.fill: parent
        wash: "red"
        Column {
            x: 1 + 116
            width: parent.width - 2 - 116 - 16
            anchors.verticalCenter: parent.verticalCenter
            spacing: 5
            LayoutMirroring.enabled: root.rtl
            LayoutMirroring.childrenInherit: true
            ApprovalWho { anchors.left: parent.left; task: root.task; label: root.bidi(root.m.who) }
            C.CText {
                width: parent.width
                text: root.bidi(root.m.title)
                size: 15; cssWeight: 600
                wrapMode: Text.Wrap
                maximumLineCount: 100
                elide: Text.ElideNone
            }
            C.CText {
                width: parent.width
                text: root.bidi(root.m.detail)
                size: 12
                color: C.RoboTheme.redText
                wrapMode: Text.Wrap
                maximumLineCount: 100
                elide: Text.ElideNone
            }
            Row {
                anchors.left: parent.left
                spacing: 8
                Btn {
                    label: root.m.retry; kind: "primary"
                    onClicked: C.Robo.island && C.Robo.island.actions.setView(root.lib.Status.defaultView())
                }
                Btn {
                    label: root.m.openN8n; kind: "secondary"
                    onClicked: C.Robo.island && C.Robo.island.actions.openUrl("")
                }
            }
        }
    }
}
