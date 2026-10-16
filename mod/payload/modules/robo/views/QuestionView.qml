pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import qs.modules.robo as C

// views/views.ts buildQuestion(): cyan card, `.stack` (padding 4 16 4 116,
// centred column, gap 5) with the who row ("is asking (i of N)"), the question
// (`.title.question-text`: 600 15 px, two lines at most) and `.actions.options`
// (wrapping, gap 6, centred): one button per option, "Done" on a pick-several
// question, the grey "Answer in terminal" link. The ⌃ fold only while a request
// waits. The stepping lives in lib/views/approval.ts (QuestionCard).
Item {
    id: root
    property bool viewOn: false
    readonly property var lib: C.Robo.lib
    readonly property var card: lib.Approval.questionCard
    readonly property int rev: C.Robo.rev
    property var task: null
    property var m: null
    // The buttons are only rebuilt when what they show changes (rowKey):
    // rebuilding them between a mouse-down and a mouse-up would swallow the click.
    property string rowKey: ""
    property var options: []
    // Arabic: upstream's `html[data-dir=rtl] .stack { direction: rtl }` — the
    // stack's box keeps its physical padding, its contents read right to left.
    readonly property bool rtl: C.Robo.rev >= 0 && C.Robo.lib.I18n.isRtl()
    /** direction: rtl sets the paragraph direction (an RLM as the first strong character). */
    function bidi(s) { return rtl && s ? "\u200F" + s : s; }

    function sync() {
        if (!viewOn) return;
        const next = card.sync();
        task = C.Robo.state.focusTask;
        m = next;
        const key = next.mode === "terminal" ? "terminal" : next.key;
        if (key !== rowKey) {
            // Another question (or request): the typed answer was for the last one.
            const q = k => k.split(":").slice(0, 2).join(":");
            if (q(key) !== q(rowKey)) other.text = "";
            rowKey = key;
            options = next.mode === "pick" ? next.options : [];
        }
    }
    onRevChanged: sync()
    onViewOnChanged: sync()
    Component.onCompleted: sync()

    function answer(a) { if (C.Robo.island) C.Robo.island.actions.answer(a); }
    /** The "Other…" field's text answers the question on screen (joins the picks on a pick-several one). */
    function submitOther() {
        if (root.card.other(other.text, a => root.answer(a))) other.text = "";
    }

    Card {
        anchors.fill: parent
        wash: "cyan"

        Column {
            id: stack
            // Inside the card's 1 px border.
            x: 1 + 116
            width: parent.width - 2 - 116 - 16
            anchors.verticalCenter: parent.verticalCenter
            spacing: 5
            LayoutMirroring.enabled: root.rtl
            LayoutMirroring.childrenInherit: true

            ApprovalWho { anchors.left: parent.left; task: root.task; label: root.bidi(root.m ? root.m.who : "") }

            C.CText {
                id: title
                width: parent.width
                text: root.bidi(root.m ? root.m.title : "")
                size: 15
                cssWeight: 600
                wrapMode: Text.Wrap
                maximumLineCount: 2
                HoverHandler { id: titleHover }
                ToolTip.visible: titleHover.hovered && !!root.m && root.m.tooltip !== ""
                ToolTip.delay: 700
                ToolTip.text: root.m ? root.m.tooltip : ""
            }

            // A question that arrived as a notification: `.sub` "Answer it in your terminal."
            C.CText {
                visible: !!root.m && root.m.mode === "terminal"
                anchors.left: parent.left
                text: root.m && root.m.mode === "terminal" ? root.m.terminalText : ""
                size: 13
                color: C.RoboTheme.dim
            }

            Flow {
                id: row
                visible: !!root.m && root.m.mode === "pick"
                width: parent.width
                spacing: 6

                Repeater {
                    model: root.options
                    delegate: Btn {
                        id: opt
                        required property var modelData
                        label: modelData.label
                        kind: modelData.on ? "primary" : "secondary"
                        onClicked: root.card.pick(modelData.label, a => root.answer(a))
                        HoverHandler { id: optHover }
                        ToolTip.visible: optHover.hovered && opt.modelData.description !== ""
                        ToolTip.delay: 700
                        ToolTip.text: opt.modelData.description
                    }
                }
                Btn {
                    id: done
                    // Same key as the option buttons: rebuilt (no fade) when the picks change.
                    visible: !!root.m && root.m.mode === "pick" && root.m.multi
                    label: root.m && root.m.mode === "pick" ? root.m.doneLabel : ""
                    kind: "primary"
                    off: !!root.m && root.m.mode === "pick" && root.m.doneOff
                    onClicked: root.card.done(a => root.answer(a))
                }
            }

            // Port: the "Other…" field (Claude Code's AskUserQuestion lets the
            // user type an answer of their own), then the grey "Answer in
            // terminal" / "Skip" link that upstream ends the options row with.
            Row {
                id: otherRow
                visible: !!root.m && root.m.mode === "pick"
                anchors.left: parent.left
                spacing: 10

                // .chat-bar look, card-sized: rgba(255,255,255,.07), the chat
                // input's 13 px ink text, a small ink send disc once typed into.
                Rectangle {
                    id: otherBar
                    width: Math.min(280, stack.width - link.implicitWidth - otherRow.spacing)
                    height: 29
                    radius: 10
                    color: other.activeFocus ? Qt.rgba(1, 1, 1, 0.1) : Qt.rgba(1, 1, 1, 0.07)
                    border.width: 1
                    border.color: other.activeFocus ? Qt.rgba(1, 1, 1, 0.14) : Qt.rgba(1, 1, 1, 0.04)
                    Behavior on color { ColorAnimation { duration: 120 } }

                    TextInput {
                        id: other
                        x: 10
                        width: parent.width - 20 - (otherSend.visible ? 22 + 6 : 0)
                        anchors.verticalCenter: parent.verticalCenter
                        color: C.RoboTheme.ink
                        selectionColor: Qt.rgba(0.38, 0.65, 0.98, 0.35)
                        selectedTextColor: color
                        selectByMouse: true
                        clip: true
                        maximumLength: root.lib.Approval.OTHER_MAX
                        font.family: C.RoboTheme.font
                        font.pointSize: C.RoboTheme.px(13)
                        renderType: Text.NativeRendering
                        // Enter answers; Escape leaves the field (the island keeps
                        // the card). Ctrl keys the field does not use reach the island.
                        Keys.onPressed: event => {
                            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                                event.accepted = true;
                                root.submitOther();
                            } else if (event.key === Qt.Key_Escape) {
                                event.accepted = true;
                                other.focus = false;
                            } else if ((event.modifiers & Qt.ControlModifier) && C.Robo.dispatchKey(event)) {
                                event.accepted = true;
                            }
                        }
                        // Typing into the card takes the keyboard for good, like the
                        // chat does (a passive notch becomes an ordinary one).
                        onActiveFocusChanged: {
                            C.Robo.focusedTextField = activeFocus;
                            if (activeFocus) C.Robo.keyboardWanted(true);
                        }
                        C.CText {
                            visible: other.text === "" && !other.preeditText
                            anchors.verticalCenter: parent.verticalCenter
                            width: parent.width
                            horizontalAlignment: Text.AlignLeft
                            text: root.m && root.m.mode === "pick" ? root.m.otherPlaceholder : ""
                            size: 13
                            color: C.RoboTheme.dim3
                        }
                        HoverHandler { cursorShape: Qt.IBeamCursor }
                    }

                    Rectangle {
                        id: otherSend
                        visible: other.text.trim() !== ""
                        x: parent.width - 4 - width
                        anchors.verticalCenter: parent.verticalCenter
                        width: 22; height: 22; radius: 11
                        color: C.RoboTheme.ink
                        scale: otherSendMa.pressed ? 0.94 : 1
                        Behavior on scale { NumberAnimation { duration: 80; easing.type: Easing.BezierSpline; easing.bezierCurve: C.RoboTheme.easeOut } }
                        C.Icon {
                            anchors.centerIn: parent
                            path: root.lib.ICONS.arrowUp
                            size: 10
                            color: "#0b0c0e"
                        }
                        MouseArea { id: otherSendMa; anchors.fill: parent; onClicked: root.submitOther() }
                    }
                }

                // .link-btn, colour #8e939c.
                LinkBtn {
                    id: link
                    anchors.verticalCenter: otherBar.verticalCenter
                    text: root.m && root.m.mode === "pick" ? root.m.terminalLabel : ""
                    color: C.RoboTheme.dim2
                    onClicked: C.Robo.island && C.Robo.island.actions.answerInTerminal()
                }
            }
        }

        ApprovalFold { visible: !!root.m && root.m.fold }
    }
}
