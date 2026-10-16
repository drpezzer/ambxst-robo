import QtQuick
import qs.config
import qs.modules.robo as C

// views/views.ts buildFinished(): green card, `.stack` (padding 4 16 4 116,
// column centred, gap 5): who row, Claude's final line (.title.one-line),
// Open terminal / OK.
//
// Port (his ask): in the compact notch (an alert Robo raised itself) the
// card grows over hover to Claude's whole last answer, scrolling past a
// height that stays well under the full tab's, and a Reply button on the
// right opens a field: the reply is typed into the session's own terminal
// (lib/views/finished.ts). A reply being typed keeps it open, and goes with
// it into the chat page when the full tab opens (SUPER+A, a click on the mascot).
Item {
    id: root
    property bool viewOn: false
    readonly property var lib: C.Robo.lib
    readonly property int rev: C.Robo.rev
    property var task: null
    property var m: ({ who: "", title: "", openLabel: "", okLabel: "" })
    readonly property var fs: lib.Finished.strings()
    // Arabic: upstream's `html[data-dir=rtl] .stack { direction: rtl }` — the
    // stack's box keeps its physical padding, its contents read right to left.
    readonly property bool rtl: C.Robo.rev >= 0 && C.Robo.lib.I18n.isRtl()
    /** direction: rtl sets the paragraph direction (an RLM as the first strong character). */
    function bidi(s) { return rtl && s ? "‏" + s : s; }

    // ── Port: the whole answer and the reply ──
    readonly property string session: task ? (task.sessionId || "") : ""
    property string full: ""
    property string fullFor: ""
    property bool writing: false
    property string error: ""
    property bool sending: false
    readonly property bool hovered: hover.hovered
    // Shrinks a moment after the pointer leaves (no flicker on the edge).
    property bool hoverHeld: false
    onHoveredChanged: {
        if (hovered) { unhover.stop(); hoverHeld = true; }
        else unhover.restart();
    }
    Timer { id: unhover; interval: 350; onTriggered: root.hoverHeld = root.hovered }
    readonly property bool grown: viewOn && C.Robo.compactNotch && root.session !== ""
        && (hoverHeld || writing || field.text !== "")
    // 0 → 1 as it grows: the line fades into the whole answer, the stack
    // rises from centred to the top; the answer's own height follows the
    // card's (the island's spring) frame by frame, so nothing jumps.
    property real g: grown ? 1 : 0
    Behavior on g { NumberAnimation { duration: 280; easing.type: Easing.BezierSpline; easing.bezierCurve: C.RoboTheme.easeInOut } }
    // Island height: 52 around the card (header 42, gap 10); the card is
    // 14 + who + 6 + answer + 8 + buttons + 14. At most 290 (the full tab is 344).
    readonly property real maxIsland: 290
    readonly property real chrome: 52 + 14 + who.height + 6 + 2 + 8 + 28 + 14
    readonly property real bodyMax: maxIsland - chrome
    readonly property real bodyH: Math.min(Math.max(answer.height, 20), bodyMax)
    readonly property real wantH: Math.max(160, Math.min(maxIsland, chrome + bodyH))
    onGrownChanged: syncHeight()
    onWantHChanged: if (grown) syncHeight()
    // In the compact notch the island and the notch move as one: the notch is
    // handed the final height once (its own Behavior: Config.animDuration,
    // OutBack 1.2 while open) and the island follows the very same curve,
    // frame by frame. Bound live to the island, the notch restarted its
    // animation every frame and trailed it both ways.
    // (The target is worked out inside syncHeight: read from a binding, it
    // could still hold the value from before `grown` changed.)
    property real ih: 160
    function syncHeight() {
        const i = C.Robo.island;
        if (!i) return;
        if (!viewOn || !C.Robo.compactNotch || Config.animDuration <= 0) {
            ihAnim.stop();
            C.Robo.compactTargetH = 0;
            i.releaseHeight(grown ? wantH : 0);
            i.setFinishedHeight(grown ? wantH : 0);
            return;
        }
        const to = grown ? wantH : 160;
        C.Robo.compactTargetH = to;
        i.holdHeight(grown ? to : 0);
        ihAnim.stop();
        ihAnim.from = i.height.value;
        ihAnim.to = to;
        ihAnim.start();
    }
    NumberAnimation {
        id: ihAnim
        target: root
        property: "ih"
        duration: Config.animDuration
        easing.type: Easing.OutBack
        easing.overshoot: 1.2
        onFinished: {
            const i = C.Robo.island;
            if (!i) return;
            i.jumpHeight(ihAnim.to);
            if (!root.grown) {
                // Back to upstream's card: the island and the notch own it again.
                i.releaseHeight(0);
                C.Robo.compactTargetH = 0;
            }
        }
    }
    onIhChanged: if (ihAnim.running && C.Robo.island) C.Robo.island.jumpHeight(ih)

    function fetchFull() {
        const key = root.session + "|" + (task && task.finalLine ? task.finalLine : "");
        if (!root.session || key === root.fullFor) return;
        root.fullFor = key;
        const want = key;
        lib.Finished.lastReply(root.session).then(t => {
            if (root.fullFor === want) root.full = t || root.standIn();
        });
        root.full = root.standIn();
    }

    /** Until the transcript has it: the Stop hook's copy (2 000 characters), else the last line. */
    function standIn() {
        return lib.Finished.hookReply(root.session) || (root.task && root.task.finalLine) || root.m.title;
    }

    function send() {
        const text = field.text.trim();
        if (!text || sending) return;
        sending = true;
        error = "";
        lib.Finished.reply(root.session, text).then(err => {
            sending = false;
            if (err) {
                error = err;
                errorClear.restart();
                return;
            }
            field.text = "";
            writing = false;
            C.Robo.finishedDraft = "";
            // Sent: the session works on it; the popup has done its job.
            if (C.Robo.island) C.Robo.island.collapse();
        });
    }
    Timer { id: errorClear; interval: 5000; onTriggered: root.error = "" }

    // Upstream syncs only the view that is on; a fading-out card keeps its text.
    function sync() {
        if (!viewOn) return;
        task = C.Robo.state.focusTask;
        m = lib.Status.finished(task);
        C.Robo.finishedSession = root.session;
        fetchFull();
    }
    onRevChanged: sync()
    onViewOnChanged: {
        sync();
        // Each card starts small: nothing from the last one carries over (it
        // could close under the pointer — OK clicked — leaving `hoverHeld`
        // set with no hover change to clear it, so the next one opened grown).
        unhover.stop();
        hoverHeld = viewOn && hover.hovered;
        if (!viewOn) {
            field.text = "";
            C.Robo.finishedDraft = "";
            // Gone (OK, a new alert, the notch closed): back to upstream's card.
            writing = false;
            error = "";
            ihAnim.stop();
            C.Robo.compactTargetH = 0;
            if (C.Robo.island) {
                C.Robo.island.releaseHeight(0);
                C.Robo.island.setFinishedHeight(0);
            }
        }
    }
    Component.onCompleted: sync()

    HoverHandler { id: hover; enabled: C.Robo.compactNotch && root.viewOn }

    Card {
        anchors.fill: parent
        wash: "green"
        Column {
            x: 1 + 116
            width: parent.width - 2 - 116 - 16
            // Upstream centres the stack; grown, it reads from the top.
            y: 14 * root.g + (1 - root.g) * (parent.height - height) / 2
            spacing: 5 + root.g
            LayoutMirroring.enabled: root.rtl
            LayoutMirroring.childrenInherit: true
            ApprovalWho { id: who; anchors.left: parent.left; task: root.task; label: root.bidi(root.m.who) }
            // .title.one-line (600 15px, one line) and, grown, the whole answer
            // in its place: cross-faded, the space between them eased.
            Item {
                id: mid
                width: parent.width
                // The answer's room: what the card has now (it grows on the
                // island's spring) under the rest of the stack.
                readonly property real room: Math.max(0, Math.min(root.bodyH, root.height - (14 + who.height + 6 + 2 + 8 + 28 + 14)))
                height: line.height + (room - line.height) * root.g
                BidiText {
                    id: line
                    width: parent.width
                    raw: root.m.title
                    size: 15; cssWeight: 600
                    opacity: 1 - Math.min(1, root.g * 2)
                    visible: opacity > 0
                }
            // Port: the whole answer, scrolling past bodyMax.
            Flickable {
                id: body
                visible: root.g > 0
                opacity: Math.max(0, root.g * 2 - 1)
                // The scrollbar sits beside the answer (as the chat log's), not in it.
                width: parent.width - (bar.needed ? bar.width + 3 : 0)
                height: mid.height
                clip: true
                contentWidth: width
                contentHeight: answer.height
                boundsBehavior: Flickable.StopAtBounds
                interactive: contentHeight > height
                ChatMarkdown {
                    id: answer
                    width: body.width
                    maxWidth: width
                    markdown: root.full !== "" ? root.full : root.m.title
                }
            }
            ChatScrollbar {
                id: bar
                flick: body
                x: mid.width - width
                height: mid.height
                opacity: body.opacity
                visible: body.visible
            }
            }
            Item { width: 1; height: 2 * root.g }
            Item {
                width: parent.width
                height: 28
                Row {
                    id: btns
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 8
                    Btn { label: root.m.openLabel; kind: "primary"; onClicked: C.Robo.island && C.Robo.island.actions.openTerminal() }
                    Btn { label: root.m.okLabel; kind: "secondary"; onClicked: C.Robo.island && C.Robo.island.actions.collapse() }
                }
                // Port: Reply — a pill on the right that opens into the field.
                Rectangle {
                    id: reply
                    visible: C.Robo.compactNotch && root.session !== ""
                    readonly property real closedW: replyRow.implicitWidth + 22
                    readonly property real openW: parent.width - btns.width - 10
                    width: root.writing ? openW : closedW
                    Behavior on width { NumberAnimation { duration: 220; easing.type: Easing.BezierSpline; easing.bezierCurve: C.RoboTheme.easeOut } }
                    height: 28
                    radius: 14
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    color: root.writing ? Qt.rgba(1, 1, 1, 0.08) : (replyMa.containsMouse ? Qt.rgba(1, 1, 1, 0.12) : Qt.rgba(1, 1, 1, 0.07))
                    border.width: root.error !== "" ? 1 : 0
                    border.color: Qt.rgba(0.96, 0.31, 0.37, 0.8)
                    Row {
                        id: replyRow
                        visible: !root.writing
                        anchors.centerIn: parent
                        spacing: 6
                        C.Icon {
                            anchors.verticalCenter: parent.verticalCenter
                            path: "M12 3H5a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2v-7M18.4 2.6a1.8 1.8 0 0 1 3 3l-9 9-3.8 1 1-3.8z"
                            size: 12
                            stroke: 2
                            color: C.RoboTheme.ink2
                        }
                        C.CText { text: root.fs.reply; size: 12; cssWeight: 600; color: C.RoboTheme.ink2; anchors.verticalCenter: parent.verticalCenter }
                    }
                    MouseArea {
                        id: replyMa
                        anchors.fill: parent
                        visible: !root.writing
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            root.writing = true;
                            field.forceActiveFocus();
                        }
                    }
                    TextInput {
                        id: field
                        visible: root.writing
                        x: 12
                        width: parent.width - 12 - 28 - 4
                        anchors.verticalCenter: parent.verticalCenter
                        color: C.RoboTheme.ink
                        selectionColor: Qt.rgba(0.38, 0.65, 0.98, 0.35)
                        selectedTextColor: color
                        selectByMouse: true
                        clip: true
                        font.family: C.RoboTheme.font
                        font.pointSize: C.RoboTheme.px(12)
                        renderType: Text.NativeRendering
                        readOnly: root.sending
                        onTextChanged: {
                            C.Robo.finishedDraft = text;
                            // Typing keeps the popup open (the auto-close waits).
                            if (activeFocus && C.Robo.island) C.Robo.island.typingActivity();
                        }
                        onActiveFocusChanged: C.Robo.focusedTextField = activeFocus
                        Keys.onPressed: event => {
                            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                                event.accepted = true;
                                root.send();
                            } else if (event.key === Qt.Key_Escape) {
                                event.accepted = true;
                                if (field.text === "") root.writing = false;
                                else field.text = "";
                            }
                        }
                        C.CText {
                            visible: field.text === ""
                            anchors.verticalCenter: parent.verticalCenter
                            width: parent.width
                            elide: Text.ElideRight
                            text: root.error !== "" ? root.error : root.fs.placeholder
                            size: 12
                            color: root.error !== "" ? C.RoboTheme.redText : C.RoboTheme.dim3
                        }
                    }
                    // Send: the chat's ink disc, arrow up.
                    Rectangle {
                        visible: root.writing
                        x: parent.width - 4 - 22
                        anchors.verticalCenter: parent.verticalCenter
                        width: 22; height: 22; radius: 11
                        color: C.RoboTheme.ink
                        opacity: field.text.trim() !== "" && !root.sending ? 1 : 0.35
                        C.Icon { anchors.centerIn: parent; path: root.lib.ICONS.arrowUp; size: 10; color: "#0b0c0e" }
                        MouseArea { anchors.fill: parent; anchors.margins: -3; onClicked: root.send() }
                    }
                }
            }
        }
    }
}
