import QtQuick
import qs.modules.robo as C

// views/views.ts buildApproval(): amber card, `.stack` (padding 4 16 4 116,
// column centred, gap 5) with the who row, the `.code` line (what Allow
// authorises) and Deny / Allow; the ⌃ fold button in the corner.
// Y / N: upstream shows them as hints only (core/shortcuts.ts binds nothing);
// the port answers them (keyDown), through the same click guard.
Item {
    id: root
    property bool viewOn: false
    readonly property var lib: C.Robo.lib
    readonly property var card: lib.Approval.approvalCard
    readonly property int rev: C.Robo.rev
    property var task: null
    property string who: ""
    property string code: ""
    // Arabic: upstream's `html[data-dir=rtl] .stack { direction: rtl }` — the
    // stack's box keeps its physical padding, its contents read right to left.
    readonly property bool rtl: C.Robo.rev >= 0 && C.Robo.lib.I18n.isRtl()
    /** direction: rtl sets the paragraph direction (an RLM as the first strong character). */
    function bidi(s) { return rtl && s ? "\u200F" + s : s; }

    // Upstream syncs only the view that is on; a fading-out card keeps its text.
    function sync() {
        if (!viewOn) return;
        const m = card.sync();
        task = C.Robo.state.focusTask;
        who = m.who;
        code = m.code;
    }
    onRevChanged: sync()
    onViewOnChanged: sync()

    function decide(d) {
        root.card.decide(d, x => C.Robo.island && C.Robo.island.actions.decide(x));
    }

    // Port: Y = Allow, N = Deny while this card is the view (C.Robo.dispatchKey
    // gives keys to the current view first). Never with a modifier, never typed
    // into a field, never a held key's repeats.
    function keyDown(ev) {
        if (!viewOn || ev.ctrlKey || ev.altKey || ev.metaKey || ev.shiftKey || ev.repeat) return false;
        if (ev.target && ev.target.tagName === "INPUT") return false;
        const st = C.Robo.state;
        if (!st || st.mode !== "expanded" || st.view !== "approval" || !st.pendingApproval) return false;
        if (ev.key === "y") { decide("allow"); return true; }
        if (ev.key === "n") { decide("deny"); return true; }
        return false;
    }
    Component.onCompleted: { C.Robo.registerView("approval", root); sync(); }
    Component.onDestruction: C.Robo.unregisterView("approval", root)

    Card {
        id: cardBg
        anchors.fill: parent
        wash: "amber"

        Column {
            // Inside the card's 1 px border.
            x: 1 + 116
            width: parent.width - 2 - 116 - 16
            anchors.verticalCenter: parent.verticalCenter
            spacing: 5
            LayoutMirroring.enabled: root.rtl
            LayoutMirroring.childrenInherit: true

            ApprovalWho { anchors.left: parent.left; task: root.task; label: root.bidi(root.who) }

            // .code: mono 12 #e8e9ec, rgba(255,255,255,.07), 1 px rgba(255,255,255,.06),
            // radius 10, padding 5 10, one line, ellipsis, selectable.
            Rectangle {
                width: parent.width
                height: codeText.implicitHeight + 12
                radius: 10
                color: Qt.rgba(1, 1, 1, 0.07)
                border.width: 1
                // CSS paints the border over the background: 0.06 over 0.07.
                border.color: Qt.rgba(1, 1, 1, 1 - 0.93 * 0.94)
                // .code stays left to right in Arabic.
                LayoutMirroring.enabled: false
                LayoutMirroring.childrenInherit: true
                C.CText {
                    id: codeText
                    x: 11
                    y: 6
                    width: parent.width - 22
                    text: root.code
                    horizontalAlignment: Text.AlignLeft
                    size: 12
                    color: "#e8e9ec"
                    font.family: C.RoboTheme.mono
                }
                // user-select: text — a read-only field over the elided line:
                // its own glyphs are invisible until selected.
                TextInput {
                    x: codeText.x
                    y: codeText.y
                    width: codeText.width
                    clip: true
                    readOnly: true
                    selectByMouse: true
                    text: root.code
                    color: "transparent"
                    selectedTextColor: "#e8e9ec"
                    selectionColor: Qt.rgba(0.38, 0.55, 0.95, 0.45)
                    font: codeText.font
                }
            }

            // .actions: gap 8. Built once upstream (a rebuild would swallow a click).
            Row {
                anchors.left: parent.left
                spacing: 8
                // C.Robo.rev: relabel on a live language switch (upstream tl()).
                Btn { label: C.Robo.rev >= 0 ? root.lib.I18n.t("Deny") : ""; kind: "secondary"; kbd: "N"; onClicked: root.decide("deny") }
                Btn { label: C.Robo.rev >= 0 ? root.lib.I18n.t("Allow") : ""; kind: "primary"; kbd: "Y"; onClicked: root.decide("allow") }
            }
        }

        ApprovalFold { }
    }
}
