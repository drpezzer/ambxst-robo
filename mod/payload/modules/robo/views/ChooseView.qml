import QtQuick
import qs.modules.robo as C

// views/upload.ts buildChoose(): "<b>name</b> is ready." / "What do you want
// to do with it?" / Ask a question · Cancel (stack padding 0 18 0 98).
// Only seen when the drop sequence is not running; with it, UploadLayer.qml
// paints this card and its buttons.
Item {
    id: root
    property bool viewOn: false
    readonly property var lib: C.Robo.lib
    readonly property int rev: C.Robo.rev
    function t(s, v) { void rev; return lib.I18n.t(s, v); }
    function act() { return C.Robo.island ? C.Robo.island.actions : null; }
    readonly property string fileName: {
        void rev;
        const f = C.Robo.state.droppedFile;
        return f ? f.name : lib.I18n.t("file");
    }
    // Arabic: `html[data-dir=rtl] .stack { direction: rtl }`.
    readonly property bool rtl: rev >= 0 && lib.I18n.isRtl()
    function esc(s) { return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;"); }

    Card {
        anchors.fill: parent
        Column {
            x: 1 + 98
            width: parent.width - 2 - 98 - 18
            anchors.verticalCenter: parent.verticalCenter
            spacing: 5
            LayoutMirroring.enabled: root.rtl
            LayoutMirroring.childrenInherit: true
            // .title with a <b> (bolder than 600 = 700).
            C.CText {
                width: parent.width
                textFormat: Text.StyledText
                text: (root.rtl ? "\u200F" : "") + "<b>" + root.esc(root.fileName) + "</b>" + root.esc(root.t(" is ready."))
                size: 15
                cssWeight: 600
            }
            C.CText {
                width: parent.width
                text: (root.rtl ? "\u200F" : "") + root.t("What do you want to do with it?")
                size: 13
                color: C.RoboTheme.dim
            }
            Row {
                anchors.left: parent.left
                spacing: 8
                Btn {
                    label: root.t("Ask a question")
                    kind: "primary"
                    onClicked: { const a = root.act(); if (a) a.setView("prompt"); }
                }
                Btn {
                    label: root.t("Cancel")
                    kind: "secondary"
                    onClicked: { const a = root.act(); if (a) a.cancelDrop(); }
                }
            }
        }
    }
}
