pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import Quickshell
import qs.modules.robo as C

// The chat card's inside (views/chat.ts buildPrompt()), shared by the chat
// view (PromptView, the mascot on the left) and the Robo tab's home chat: from
// the top, the dropped file's chip, the log (user bubbles, Markdown answers,
// the streamed answer, typing dots), the model picker (in place of log and
// chip while open), the model button, and the field with its send button.
// Both draw lib/views/chat.ts's one chat, so they always show the same
// conversation. style.css .chat-*, .chip*, .bubble, .reply, .typing, .model-*,
// .picker*, .send-btn.
Item {
    id: root
    /** Port: a file is being dragged over Robo (the chat page shows the drop). */
    readonly property bool dragOver: C.Robo.rev >= 0 && C.Robo.state.fileDragOver === true

    // The drop zone: a dotted border round the chat, where the field was a hint.
    Item {
        id: dropZone
        anchors.fill: parent
        z: 5
        opacity: root.dragOver ? 1 : 0
        visible: opacity > 0
        Behavior on opacity { NumberAnimation { duration: 180; easing.type: Easing.BezierSpline; easing.bezierCurve: C.RoboTheme.ease } }
        Canvas {
            id: dash
            anchors.fill: parent
            onWidthChanged: requestPaint()
            onHeightChanged: requestPaint()
            onVisibleChanged: if (visible) requestPaint()
            onPaint: {
                const ctx = getContext("2d");
                ctx.reset();
                ctx.strokeStyle = Qt.rgba(1, 1, 1, 0.32);
                ctx.lineWidth = 1.5;
                ctx.setLineDash([6, 5]);
                const r = 12, x = 1, y = 1, w = width - 2, h = height - 2;
                ctx.beginPath();
                ctx.moveTo(x + r, y);
                ctx.arcTo(x + w, y, x + w, y + h, r);
                ctx.arcTo(x + w, y + h, x, y + h, r);
                ctx.arcTo(x, y + h, x, y, r);
                ctx.arcTo(x, y, x + w, y, r);
                ctx.closePath();
                ctx.stroke();
            }
        }
        C.CText {
            anchors.horizontalCenter: parent.horizontalCenter
            y: parent.height - 20 - implicitHeight / 2
            text: C.Robo.state.chatHistory.length > 0 ? "Drop to attach it to this chat" : "Drop your file here"
            size: 12.5
            color: C.RoboTheme.dim2
        }
    }
    /** Room kept on the left (the mascot's, in the chat view). */
    property real leftPad: 84
    /** The island view this panel is drawn in (the picker folds when it is left). */
    property string where: "prompt"
    readonly property var lib: C.Robo.lib
    readonly property var chat: lib.ChatView.chat()
    readonly property var str: lib.ChatView.strings()
    /** Bumped when the chat controller redraws (its own state is plain JS). */
    property int crev: 0
    readonly property int rev: C.Robo.rev + crev

    // sync(): the log is redrawn only when its length (or the dots) change,
    // or while an answer streams in (or another chat was reopened).
    // Port: the history's rows change only with its length (or a reopen); the
    // streamed answer / dots are `tail`, drawn by one row of their own, so a
    // delta no longer rebuilds every row of the log.
    /**
     * Port (performance): the drawn rows in four parts, oldest first: rows
     * loaded further up, 9, 9, and the newest 12 (enough to fill the log).
     * A panel built while the notch opens (the tab is made at every open)
     * or a chat just reopened draws the newest part only; the others follow
     * one at a time once the notch has finished opening (partsTimer), each
     * built without rebuilding the ones already there. Making and laying out
     * all 30 rows at once held up the opening animation.
     */
    property var parts: [[], [], [], []]
    /** How many parts, from the newest, are drawn. */
    property int partsShown: 1
    Timer {
        id: partsTimer
        // Config.animDuration (300 ms) after the push, which comes a turn after
        // the build; counted from when the panel shows (a hidden one waits).
        interval: 380
        running: root.partsShown < 4 && root.visible
        repeat: true
        onTriggered: {
            interval = 48;
            root.partsShown++;
        }
    }
    property string rowsKey: ""
    property var tail: null
    property string tailKey: ""
    // Port: only the latest `shown` rows are drawn (a long chat made every
    // showing of the tab spend its first frame laying out all of them); older
    // ones come in as the log is scrolled to its top.
    property int shown: 30
    readonly property int hiddenRows: Math.max(0, C.Robo.rev >= 0 ? C.Robo.state.chatHistory.length - shown : 0)
    function syncRows() {
        const r = chat.rows();
        const n = C.Robo.state.chatHistory.length;
        const key = chat.generation + "|" + n + "|" + shown;
        if (key !== rowsKey) {
            // A reopened chat starts at its end again (its older rows a moment later).
            if (rowsKey.split("|")[0] !== String(chat.generation)) {
                shown = 30;
                partsTimer.interval = 380;
                partsShown = 1;
            }
            rowsKey = key;
            const from = Math.max(0, n - shown);
            const at = k => Math.max(from, n - k);
            parts = [r.slice(from, at(30)), r.slice(at(30), at(21)), r.slice(at(21), at(12)), r.slice(at(12), n)];
            // The rebuilt rows lost any selection.
            hasLogSelection = false;
        }
        const t = r.length > n ? r[r.length - 1] : null;
        const tk = t === null ? "" : (t.typing ? "\u0001dots" : t.content);
        if (tk !== tailKey || (t === null) !== (tail === null)) {
            tailKey = tk;
            tail = t;
        }
    }
    // Port (his ask): and the working directory's chip asks again when it is stale.
    onRevChanged: {
        syncRows();
        chat.syncWorkDir();
    }
    readonly property string chipLabel: rev >= 0 ? chat.chipLabel() : ""
    // Port: a file dropped into an ongoing chat: its chip waits by the field.
    readonly property bool chipInChat: rev >= 0 && chat.chipInChat()
    readonly property var modelBtn: rev >= 0 ? chat.modelButton() : ({ accent: "#000", name: "", open: false, disabled: false })
    readonly property bool picking: rev >= 0 && chat.pickerOpen && chat.pickerView === where
    readonly property bool sending: rev >= 0 && chat.sending
    // Port (his ask): the working directory's chip (chat.ts workDirChip) and a
    // dropped folder's "Use as working directory" (chat.ts dropOffer).
    readonly property var workDirChip: rev >= 0 ? chat.workDirChip() : ({ show: false, label: "", tooltip: "", isDefault: true, disabled: true })
    readonly property string dropOffer: rev >= 0 ? chat.dropOffer() : ""
    /** A folder outline (24×24, stroked), for the working directory's chip. */
    readonly property string folderIcon: "M3.5 6.5A1.5 1.5 0 0 1 5 5h4.2l2 2.2H19a1.5 1.5 0 0 1 1.5 1.5v9.3A1.5 1.5 0 0 1 19 19.5H5A1.5 1.5 0 0 1 3.5 18z"
    /**
     * Port (his ask): the folder chooser (ambxst-robo, the desktop's portal)
     * may take the notch's focus away: once it closes, picked or not, the
     * tab is on screen again, on this chat.
     */
    function pickWorkDir() {
        const back = () => {
            C.Robo.openTabRequested();
            Qt.callLater(() => {
                const isl = C.Robo.island;
                if (isl && C.Robo.state.view !== root.where) isl.actions.setView(root.where);
            });
        };
        root.chat.pickWorkDir().then(back, back);
    }
    // Port (his ask): a fresh Claude-style verb for every turn.
    readonly property var workVerbs: ["Accomplishing", "Actioning", "Actualizing", "Baking", "Brewing",
        "Calculating", "Cerebrating", "Churning", "Clauding", "Coalescing", "Cogitating", "Computing",
        "Conjuring", "Considering", "Contemplating", "Cooking", "Crafting", "Creating", "Crunching",
        "Deliberating", "Determining", "Doing", "Effecting", "Finagling", "Forging", "Forming",
        "Generating", "Hatching", "Herding", "Honking", "Hustling", "Ideating", "Inferring",
        "Manifesting", "Marinating", "Moseying", "Mulling", "Mustering", "Musing", "Noodling",
        "Percolating", "Pondering", "Processing", "Puttering", "Reticulating", "Ruminating",
        "Schlepping", "Shucking", "Simmering", "Smooshing", "Spinning", "Stewing", "Synthesizing",
        "Thinking", "Transmuting", "Vibing", "Working", "Whirring", "Wibbling", "Wrangling"]
    property string workVerb: "Noodling"
    function pickWorkVerb() {
        let v = workVerb;
        while (v === workVerb) v = workVerbs[Math.floor(Math.random() * workVerbs.length)];
        workVerb = v;
    }
    onSendingChanged: if (sending) pickWorkVerb()
    /** The field has the keyboard. */
    readonly property bool typing: field.activeFocus

    function hexA(hex, a) { const c = Qt.color(hex); return Qt.rgba(c.r, c.g, c.b, a); }

    readonly property var hooks: ({
        changed: () => { root.crev++; },
        // The turn's end (chat.ts) hands the keyboard back: never selecting,
        // so a draft typed meanwhile survives the next keystroke.
        focusInput: () => root.refocus(),
    })
    Component.onCompleted: {
        // Port (his ask): the working directory's chip writes $HOME as ~.
        chat.setHome(Quickshell.env("HOME") || "");
        chat.addHooks(hooks);
        syncRows();
        chat.syncWorkDir();
    }
    Component.onDestruction: chat.removeHooks(hooks)

    // ── Port: selection across the log (selMa) ──
    property bool hasLogSelection: false
    /** The log's TextEdits, in reading order, with their rect in logCol and their message. */
    function logTexts() {
        const out = [];
        const walk = (it, row) => {
            if (!it || !it.visible) return;
            if (it.isChatRow === true) row = it;
            if (typeof it.positionAt === "function" && typeof it.select === "function" && it.selectedText !== undefined) {
                const p = it.mapToItem(logCol, 0, 0);
                out.push({ te: it, row: row, x: p.x, y: p.y, w: it.width, h: it.height });
                return;
            }
            const kids = it.children;
            for (let i = 0; i < kids.length; i++) walk(kids[i], row);
        };
        walk(logCol, null);
        return out;
    }
    /** Where point `p` (logCol) falls in reading order: {i, pos}. */
    function locate(list, p) {
        for (let i = 0; i < list.length; i++) {
            const t = list[i];
            if (p.y < t.y) return { i: i, pos: 0 };
            if (p.y <= t.y + t.h) {
                if (p.x < t.x && t.te.length !== undefined) return { i: i, pos: t.te.positionAt(0, p.y - t.y) };
                return { i: i, pos: t.te.positionAt(p.x - t.x, p.y - t.y) };
            }
        }
        const lastT = list[list.length - 1];
        return { i: list.length - 1, pos: lastT ? lastT.te.length : 0 };
    }
    function selectSpan(a, b) {
        const list = logTexts();
        if (!list.length) return;
        let s = locate(list, a), e = locate(list, b);
        if (e.i < s.i || (e.i === s.i && e.pos < s.pos)) { const t = s; s = e; e = t; }
        let any = false;
        for (let k = 0; k < list.length; k++) {
            const te = list[k].te;
            if (k < s.i || k > e.i) { te.deselect(); continue; }
            const from = k === s.i ? s.pos : 0;
            const to = k === e.i ? e.pos : te.length;
            if (to > from) { te.select(from, to); any = true; } else te.deselect();
        }
        hasLogSelection = any;
    }
    function clearLogSelection() {
        if (!hasLogSelection) return;
        const list = logTexts();
        for (let k = 0; k < list.length; k++) list[k].te.deselect();
        hasLogSelection = false;
    }
    function copyLogSelection() {
        const list = logTexts();
        let text = "", prevRow = null;
        for (let k = 0; k < list.length; k++) {
            const sel = String(list[k].te.selectedText || "").replace(/[\u2028\u2029]/g, "\n");
            if (!sel) continue;
            if (text) text += list[k].row !== prevRow ? "\n\n" : "\n";
            text += sel;
            prevRow = list[k].row;
        }
        if (text) Quickshell.clipboardText = text;
    }
    function textAt(x, y) {
        const list = logTexts();
        for (let k = 0; k < list.length; k++) {
            const t = list[k];
            if (x >= t.x && x <= t.x + t.w && y >= t.y && y <= t.y + t.h) return t;
        }
        return null;
    }
    /** A click (no drag): a link opens, a code block's copy button copies. */
    function clickThrough(x, y) {
        const t = textAt(x, y);
        if (t && typeof t.te.linkAt === "function") {
            const link = t.te.linkAt(x - t.x, y - t.y);
            if (link) { C.Robo.lib.Bridge.openUrl(link); return; }
        }
        const hit = logCol.childAt(x, y);
        const deep = hit ? findButton(hit, logCol, x, y) : null;
        if (deep) deep.clicked(null);
    }
    function findButton(it, ref, x, y) {
        if (!it || !it.visible) return null;
        const p = it.mapFromItem(ref, x, y);
        if (p.x < 0 || p.y < 0 || p.x > it.width || p.y > it.height) return null;
        const kids = it.children;
        for (let i = kids.length - 1; i >= 0; i--) {
            const f = findButton(kids[i], ref, x, y);
            if (f) return f;
        }
        return it.mdCopyButton === true ? it : null;
    }
    function selectWordAt(x, y) {
        const t = textAt(x, y);
        if (!t) return;
        clearLogSelection();
        t.te.cursorPosition = t.te.positionAt(x - t.x, y - t.y);
        t.te.selectWord();
        hasLogSelection = t.te.selectedText !== "";
    }
    Shortcut {
        sequences: [StandardKey.Copy]
        // Not over the field's own copy.
        enabled: root.hasLogSelection && !field.activeFocus
        onActivated: root.copyLogSelection()
    }

    /** ViewHost.focus(): the field takes the keyboard, its text selected. */
    // Port: the field is typed in while an answer comes, so the draft must
    // survive every automatic focus. A field that already has the keyboard,
    // or a chat field the user was typing in, is never selected (a keystroke
    // would replace the whole draft); a stale hidden field first catches up
    // with the one shared draft.
    function syncDraft() {
        const d = C.Robo.chatDrafts["chat"] || "";
        if (!field.activeFocus && field.text !== d) field.text = d;
    }
    function focusIn() {
        const wasTyping = field.activeFocus || C.Robo.focusedTextField;
        syncDraft();
        field.forceActiveFocus();
        if (!wasTyping) field.selectAll();
    }
    /** After an answer: the keyboard back to the field, its text untouched. */
    function refocus() {
        if (field.activeFocus || !root.visible) return;
        // Typing in another field (a question's, a reply's): leave it there.
        if (C.Robo.focusedTextField) return;
        syncDraft();
        field.forceActiveFocus();
        field.cursorPosition = field.text.length;
    }
    function submit() {
        if (root.chat.submit(field.text, root.hooks, root.where)) field.text = "";
    }
    /** Escape in the field, after the picker: the home chat lets go of the keyboard. */
    signal escaped()

    // .chat-body: column, gap 6, padding 12 16 14 84 (inside the 1 px border;
    // the home chat has no mascot on its left: 16).
    Item {
        id: body
        x: 1 + root.leftPad
        y: 1 + 12
        width: parent.width - 2 - root.leftPad - 16
        height: parent.height - 2 - 12 - 14

        // .chip-row > .chip: the dropped file. Its white ring fades and it
        // settles from scale 1.06 after 0.45 s (0.3 s ease-out).
        Item {
            id: chipRow
            visible: root.chipLabel !== "" && !root.picking
            x: root.chipInChat ? 10 : 0
            y: root.chipInChat ? modelRow.y + (modelRow.height - chip.height) / 2 : 0
            z: 2
            width: root.chipInChat ? chip.width : parent.width
            height: visible ? chip.height : 0
            Rectangle {
                id: chip
                property bool settled: false
                width: chipInner.implicitWidth + 20 + 3 + (root.chipInChat ? 14 : 0)
                // 1.5 + 4 + line-height normal of 11.5px (14 in Chromium) + 4 + 1.5.
                height: 25
                radius: height / 2
                color: Qt.rgba(1, 1, 1, 0.1)
                border.width: 1.5
                border.color: Qt.rgba(1, 1, 1, settled ? 0 : 0.75)
                scale: settled ? 1 : 1.06
                Behavior on border.color { SequentialAnimation { PauseAnimation { duration: 450 } ColorAnimation { duration: 300; easing.type: Easing.BezierSpline; easing.bezierCurve: C.RoboTheme.easeOut } } }
                Behavior on scale { SequentialAnimation { PauseAnimation { duration: 450 } NumberAnimation { duration: 300; easing.type: Easing.BezierSpline; easing.bezierCurve: C.RoboTheme.easeOut } } }
                Row {
                    id: chipInner
                    x: 10 + 1.5
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 6
                    // .chip-dot: 7 px, linear-gradient(135deg, …) corner to corner.
                    Canvas {
                        width: 7; height: 7
                        anchors.verticalCenter: parent.verticalCenter
                        onPaint: {
                            const ctx = getContext("2d");
                            ctx.reset();
                            const g = ctx.createLinearGradient(0, 0, 7, 7);
                            const stops = ["#ff6b5b", "#f7b32b", "#2dd4a7", "#38bdf8", "#a78bfa"];
                            stops.forEach((c, i) => g.addColorStop(i / 4, c));
                            ctx.fillStyle = g;
                            ctx.beginPath();
                            ctx.arc(3.5, 3.5, 3.5, 0, Math.PI * 2);
                            ctx.fill();
                        }
                    }
                    C.CText {
                        text: root.chipLabel
                        size: 11.5
                        color: C.RoboTheme.ink2
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }
                // Port: the in-chat chip's ×, it takes the file back off.
                C.CText {
                    visible: root.chipInChat
                    x: parent.width - 10 - width
                    anchors.verticalCenter: parent.verticalCenter
                    text: "\u00d7"
                    size: 13
                    color: xMa.containsMouse ? C.RoboTheme.ink : C.RoboTheme.dim3
                    MouseArea { id: xMa; anchors.fill: parent; anchors.margins: -5; hoverEnabled: true; onClicked: root.chat.detachFile() }
                }
                // A new label is a new chip: it settles again.
                Connections {
                    target: root
                    function onChipLabelChanged() { chip.settled = false; settleTimer.restart(); }
                }
                Timer { id: settleTimer; interval: 16; running: true; onTriggered: chip.settled = true }
            }
        }

        // Port (his ask): a dropped folder may become the working directory
        // instead: beside its chip by the field (or alone there when it was
        // too big to copy), styled as the model button's row.
        Rectangle {
            id: offerBtn
            visible: root.dropOffer !== "" && !root.picking && (root.chipInChat || !chipRow.visible)
            x: root.chipInChat && chipRow.visible ? chipRow.x + chip.width + 6 : 10
            y: modelRow.y + (modelRow.height - height) / 2
            z: 2
            width: offerRow.implicitWidth + 16
            height: 21
            radius: height / 2
            opacity: root.sending ? 0.6 : 1
            color: offerMa.containsMouse && !root.sending ? Qt.rgba(1, 1, 1, 0.1) : Qt.rgba(1, 1, 1, 0.06)
            border.width: 1
            border.color: Qt.rgba(1, 1, 1, 0.1)
            Row {
                id: offerRow
                x: 8
                anchors.verticalCenter: parent.verticalCenter
                spacing: 5
                C.Icon {
                    path: root.folderIcon
                    size: 10
                    stroke: 2
                    color: "#7b8089"
                    anchors.verticalCenter: parent.verticalCenter
                }
                C.CText {
                    text: root.dropOffer
                    size: 10.5
                    cssWeight: 500
                    color: "#c8cdd4"
                    anchors.verticalCenter: parent.verticalCenter
                }
            }
            MouseArea { id: offerMa; anchors.fill: parent; hoverEnabled: true; onClicked: if (!root.sending) root.chat.useDropAsWorkDir() }
        }

        // .chat-log: scrolls, rows 6 apart, padding 2 0.
        Flickable {
            id: log
            visible: !root.picking
            y: chipRow.visible && !root.chipInChat ? chipRow.height + 6 : 0
            width: parent.width
            height: modelRow.y - 6 - y
            clip: true
            contentWidth: width
            contentHeight: logCol.implicitHeight + 4
            boundsBehavior: Flickable.StopAtBounds
            function toBottom() { contentY = Math.max(0, contentHeight - height); atEnd = true; }
            // Port: older rows load when the top is reached; the view stays on
            // the row it showed (the content grows above it).
            property real keepFromBottom: -1
            // Scrolling of his own only: while the log lays out it sits at the
            // top for a moment, which would load everything.
            property double settledAt: 0
            // The log follows new text only while it is at its end (not while
            // he reads further up, or selects).
            property bool atEnd: true
            property double keepUntil: 0
            onContentYChanged: {
                if (Date.now() > keepUntil) atEnd = contentY >= contentHeight - height - 24;
                if (Date.now() - settledAt < 600 || contentHeight <= height + 40) return;
                if (selMa.pressed) return;
                if (contentY < 40 && root.hiddenRows > 0 && Date.now() > keepUntil) {
                    keepFromBottom = contentHeight - contentY;
                    keepUntil = Date.now() + 400;
                    root.shown += 30;
                    root.syncRows();
                }
            }
            onContentHeightChanged: {
                settledAt = Date.now();
                // Older rows lay out over a few frames: hold the view on the
                // same row for all of them.
                if (Date.now() < keepUntil) {
                    contentY = Math.max(0, contentHeight - keepFromBottom);
                    return;
                }
                if (atEnd && !selMa.pressed) toBottom();
            }
            onHeightChanged: toBottom()

            Column {
                id: logCol
                y: 2
                width: log.width - logBar.width
                spacing: 6
                Repeater {
                    model: 4
                    delegate: Column {
                        id: part
                        required property int index
                        // Its own flag: only this part's model changes when it comes in.
                        readonly property bool drawn: index >= 4 - root.partsShown
                        width: logCol.width
                        spacing: 6
                        visible: partRows.count > 0
                        Repeater {
                            id: partRows
                            model: part.drawn ? root.parts[part.index] : []
                            delegate: ChatRow {
                                // (ChatRow has its own modelData: marked required, not redeclared.)
                                required modelData
                                width: logCol.width
                            }
                        }
                    }
                }
                // The streamed answer, or the dots (rows() ends with it while a turn runs).
                ChatRow {
                    // Port (his ask): while a turn runs the working line stands in for the dots.
                    visible: root.tail !== null && !(root.tail.typing && root.sending)
                    width: logCol.width
                    modelData: root.tail !== null ? root.tail : ({ role: "assistant", content: "" })
                }
                // Port (his ask): Claude Code's spinner line under the latest
                // message for as long as the turn runs (*Noodling…), shimmering
                // like the compacting line; it gives way to that line.
                ChatRow {
                    visible: root.sending && !(root.tail !== null && root.tail.role === "compacting")
                    width: logCol.width
                    modelData: ({ role: "working", content: "\u273b " + root.workVerb + "\u2026" })
                }
                // Port: typed during the answer, dimmed under the working line until
                // Claude Code takes it in (or, if it never does, sent once it is done).
                Repeater {
                    model: root.rev >= 0 ? root.chat.queuedRows() : []
                    delegate: ChatRow {
                        // (ChatRow has its own modelData: marked required, not redeclared.)
                        required modelData
                        width: logCol.width
                        opacity: 0.5
                    }
                }
            }

            // Port (his ask): one selection across the whole log. Every
            // paragraph, list item, code block and message is a TextEdit of its
            // own, and a selection can't leave one; the Flickable also took
            // vertical drags. This layer owns the drag (no stealing), selects
            // the span in each TextEdit it crosses (persistentSelection keeps
            // them lit), and Ctrl+C copies them as one text. A plain click
            // still opens a link or presses a code block's copy button.
            MouseArea {
                id: selMa
                anchors.fill: logCol
                z: 10
                preventStealing: true
                cursorShape: Qt.IBeamCursor
                property point anchor: Qt.point(0, 0)
                property point last: Qt.point(0, 0)
                property bool dragging: false

                onPressed: m => {
                    anchor = Qt.point(m.x, m.y);
                    last = anchor;
                    dragging = false;
                    root.clearLogSelection();
                }
                onPositionChanged: m => {
                    last = Qt.point(m.x, m.y);
                    if (!dragging && Math.abs(m.x - anchor.x) + Math.abs(m.y - anchor.y) < 4) return;
                    dragging = true;
                    root.selectSpan(anchor, last);
                }
                onReleased: m => {
                    if (!dragging) root.clickThrough(m.x, m.y);
                    dragging = false;
                }
                onDoubleClicked: m => root.selectWordAt(m.x, m.y)
                // Dragging past the log's edge scrolls it, and the selection follows.
                Timer {
                    interval: 30
                    repeat: true
                    running: selMa.dragging && selMa.pressed
                    onTriggered: {
                        const y = selMa.last.y - log.contentY + logCol.y;
                        let dy = 0;
                        if (y < 14) dy = -10;
                        else if (y > log.height - 14) dy = 10;
                        if (!dy) return;
                        const before = log.contentY;
                        log.contentY = Math.max(0, Math.min(log.contentHeight - log.height, log.contentY + dy));
                        selMa.last = Qt.point(selMa.last.x, selMa.last.y + (log.contentY - before));
                        root.selectSpan(selMa.anchor, selMa.last);
                    }
                }
            }
        }

        ChatScrollbar {
            id: logBar
            flick: log
            visible: log.visible && needed
            x: log.x + log.width - width
            y: log.y
            height: log.height
        }

        // .picker: provider chips, a rule, the chosen provider's models.
        Rectangle {
            id: picker
            visible: root.picking
            width: parent.width
            height: modelRow.y - 6
            radius: 12
            color: "#16171b"
            border.width: 1
            border.color: Qt.rgba(1, 1, 1, 0.06)

            Flow {
                id: chips
                x: 11; y: 11
                width: parent.width - 22
                spacing: 6
                Repeater {
                    model: root.rev >= 0 && root.picking ? root.chat.chips() : []
                    delegate: Rectangle {
                        id: pchip
                        required property var modelData
                        width: pchipRow.implicitWidth + 22
                        height: pchipRow.implicitHeight + 10
                        radius: height / 2
                        color: modelData.on ? root.hexA(modelData.accent, 0.18) : Qt.rgba(1, 1, 1, 0.06)
                        border.width: 1
                        border.color: modelData.on ? root.hexA(modelData.accent, 0.5) : Qt.rgba(1, 1, 1, 0.1)
                        Row {
                            id: pchipRow
                            anchors.centerIn: parent
                            spacing: 5
                            Rectangle {
                                width: 7; height: 7; radius: 3.5
                                color: pchip.modelData.accent
                                anchors.verticalCenter: parent.verticalCenter
                            }
                            C.CText {
                                text: pchip.modelData.name
                                size: 11.5
                                cssWeight: pchip.modelData.on ? 600 : 400
                                color: pchip.modelData.on ? C.RoboTheme.ink2 : "#c8cdd4"
                                anchors.verticalCenter: parent.verticalCenter
                            }
                        }
                        MouseArea { anchors.fill: parent; onClicked: root.chat.chipClicked(pchip.modelData.id) }
                    }
                }
            }
            // .picker-rule
            Rectangle {
                id: pickerRule
                x: 11
                y: chips.y + chips.height + 8
                width: parent.width - 22
                height: 1
                color: Qt.rgba(1, 1, 1, 0.2)
                opacity: 0.4
            }
            ChatScrollbar {
                id: plistBar
                flick: plist
                x: plist.x + plist.width - width
                y: plist.y
                height: plist.height
                z: 2
            }
            // .picker-list / .picker-status
            Flickable {
                id: plist
                x: 11
                y: pickerRule.y + 1 + 8
                width: parent.width - 22
                height: parent.height - 11 - y
                clip: true
                contentHeight: plistCol.implicitHeight
                // scrollIntoView({ block: "nearest" }) for the chosen model. Kept
                // until the list has a height: while the picker opens it is still
                // negative, which scrolled the list to its end.
                property Item chosenRow: null
                function reveal() {
                    if (!chosenRow || height <= 0) return;
                    const bottom = chosenRow.y + chosenRow.height;
                    if (bottom > contentY + height) contentY = Math.max(0, bottom - height);
                    else if (chosenRow.y < contentY) contentY = chosenRow.y;
                }
                onHeightChanged: reveal()
                boundsBehavior: Flickable.StopAtBounds
                Column {
                    id: plistCol
                    width: plist.width - plistBar.width
                    spacing: 2
                    // .picker-status: padding 4 0, gap 10, 400 11px #8a8f98.
                    Row {
                        visible: root.rev >= 0 && root.chat.pickerStatus !== null
                        topPadding: 4
                        bottomPadding: 4
                        spacing: 10
                        C.CText {
                            text: root.rev >= 0 && root.chat.pickerStatus ? root.chat.pickerStatus.text : ""
                            size: 11
                            color: "#8a8f98"
                            maximumLineCount: 3
                            wrapMode: Text.Wrap
                            width: Math.min(implicitWidth, plist.width)
                        }
                        LinkBtn {
                            visible: root.rev >= 0 && !!root.chat.pickerStatus && root.chat.pickerStatus.withSettings
                            text: root.str.openSettings
                            cssWeight: 400
                            color: "#60a5fa"
                            onClicked: root.chat.openSettings()
                        }
                    }
                    Repeater {
                        model: root.rev >= 0 && root.picking ? root.chat.pickerModels : []
                        delegate: Rectangle {
                            id: mrow
                            required property var modelData
                            width: plistCol.width
                            height: mname.implicitHeight + 12
                            radius: 6
                            readonly property color accent: root.rev >= 0 ? root.chat.pickerAccent : "white"
                            color: modelData.on ? root.hexA(accent, 0.1)
                                 : (mma.containsMouse ? Qt.rgba(1, 1, 1, 0.05) : "transparent")
                            C.CText {
                                id: mname
                                x: 8
                                width: parent.width - 16 - (modelData.on ? 11 + 8 : 0)
                                anchors.verticalCenter: parent.verticalCenter
                                text: mrow.modelData.label
                                size: 12
                                color: mrow.modelData.on ? mrow.accent : "#c8cdd4"
                            }
                            // Shape (CurveRenderer) ignores the list's clip once its row is
                            // scrolled out: shown only while the row is in view.
                            C.Icon {
                                visible: mrow.modelData.on && mrow.y + mrow.height > plist.contentY
                                         && mrow.y < plist.contentY + plist.height
                                x: parent.width - 8 - 11
                                anchors.verticalCenter: parent.verticalCenter
                                path: root.lib.ICONS.check
                                size: 11
                                stroke: 2.2
                                color: mrow.accent
                            }
                            MouseArea { id: mma; anchors.fill: parent; hoverEnabled: true; onClicked: root.chat.modelClicked(mrow.modelData.id) }
                            Component.onCompleted: if (modelData.on) {
                                plist.chosenRow = mrow;
                                Qt.callLater(plist.reveal);
                            }
                        }
                    }
                    // Port: the provider's note under its models (Claude Code:
                    // "Uses your Claude Code subscription"), styled as .picker-status.
                    C.CText {
                        visible: text !== ""
                        topPadding: 4
                        bottomPadding: 4
                        leftPadding: 8
                        width: plistCol.width
                        text: root.rev >= 0 && root.picking && root.chat.pickerStatus === null ? root.chat.pickerNote : ""
                        size: 11
                        color: "#8a8f98"
                        wrapMode: Text.Wrap
                    }
                    // Port: what the chosen permission mode does (the chips are
                    // in the model row below), styled as the note above.
                    C.CText {
                        visible: text !== ""
                        topPadding: 2
                        bottomPadding: 4
                        leftPadding: 8
                        width: plistCol.width
                        text: root.rev >= 0 && root.picking ? root.chat.pickerModeHint : ""
                        size: 11
                        color: "#8a8f98"
                        wrapMode: Text.Wrap
                    }
                }
            }
        }

        // .model-row > .model-btn: right-aligned, 10 px in.
        Item {
            id: modelRow
            width: parent.width
            height: modelBtn.height
            y: bar.y - 6 - height
            // Port: Claude Code's permission modes (chat.ts pickerModes), while
            // the picker is open: chips like the provider chips, at the
            // model button's size, on the row's free left side.
            Row {
                id: modeChips
                x: 10
                visible: root.picking && modeRepeater.count > 0
                anchors.verticalCenter: parent.verticalCenter
                spacing: 5
                C.CText {
                    text: root.rev >= 0 && root.picking ? root.chat.pickerModesTitle : ""
                    size: 10.5
                    color: "#5c6370"
                    anchors.verticalCenter: parent.verticalCenter
                }
                Repeater {
                    id: modeRepeater
                    model: root.rev >= 0 && root.picking ? root.chat.pickerModes : []
                    delegate: Rectangle {
                        id: mchip
                        required property var modelData
                        readonly property color accent: root.rev >= 0 ? root.chat.pickerAccent : "white"
                        width: mchipText.implicitWidth + 16
                        height: 21
                        radius: height / 2
                        color: modelData.on ? root.hexA(accent, 0.18)
                             : (mchipMa.containsMouse && !root.sending ? Qt.rgba(1, 1, 1, 0.1) : Qt.rgba(1, 1, 1, 0.06))
                        border.width: 1
                        border.color: modelData.on ? root.hexA(accent, 0.5) : Qt.rgba(1, 1, 1, 0.1)
                        C.CText {
                            id: mchipText
                            anchors.centerIn: parent
                            text: mchip.modelData.label
                            size: 10.5
                            cssWeight: mchip.modelData.on ? 600 : 500
                            color: mchip.modelData.on ? C.RoboTheme.ink2 : "#c8cdd4"
                        }
                        MouseArea { id: mchipMa; anchors.fill: parent; hoverEnabled: true; onClicked: root.chat.modeClicked(mchip.modelData.id) }
                    }
                }
            }
            // Port (his ask): the working directory, left of the model button,
            // as that button: click = the desktop's folder chooser, right-click
            // = back to the default (Robo's own folder), middle-click = copy
            // its full path (a check and "Copied" for a moment). Claude Code only.
            Rectangle {
                id: dirBtn
                readonly property bool disabled: root.workDirChip.disabled
                property bool copied: false
                Timer { id: dirCopied; interval: 1400; onTriggered: dirBtn.copied = false }
                // What the row's left side holds now (the mode chips, a chip by the field, the offer).
                readonly property real leftEnd: Math.max(modeChips.visible ? modeChips.x + modeChips.width : 0,
                                                         chipRow.visible && root.chipInChat ? chipRow.x + chip.width : 0,
                                                         offerBtn.visible ? offerBtn.x + offerBtn.width : 0)
                readonly property real room: modelBtn.x - 6 - Math.max(10, leftEnd + 6)
                visible: root.workDirChip.show && room >= 44
                x: modelBtn.x - 6 - width
                width: Math.min(room, dirRow.implicitWidth + 16)
                height: 21
                radius: height / 2
                opacity: disabled ? 0.6 : 1
                color: (dirMa.containsMouse && !disabled) ? Qt.rgba(1, 1, 1, 0.1) : Qt.rgba(1, 1, 1, 0.06)
                clip: true
                Row {
                    id: dirRow
                    x: 8
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 5
                    C.Icon {
                        path: dirBtn.copied ? root.lib.ICONS.check : root.folderIcon
                        size: 10
                        stroke: dirBtn.copied ? 2.2 : 2
                        color: dirBtn.copied ? C.RoboTheme.green : root.workDirChip.isDefault ? "#5c6370" : "#7b8089"
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    C.CText {
                        text: dirBtn.copied ? root.str.copied : root.workDirChip.label
                        size: 10.5
                        cssWeight: 500
                        color: "#7b8089"
                        // (chat.ts workDirLabel already keeps it short: ~/first/…/last.)
                        elide: Text.ElideMiddle
                        width: Math.min(implicitWidth, Math.max(0, dirBtn.room - 16 - 10 - 5))
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }
                MouseArea {
                    id: dirMa
                    anchors.fill: parent
                    hoverEnabled: true
                    acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
                    onClicked: mouse => {
                        if (mouse.button === Qt.MiddleButton) {
                            const path = root.workDirChip.path;
                            if (!path) return;
                            Quickshell.clipboardText = path;
                            dirBtn.copied = true;
                            dirCopied.restart();
                            return;
                        }
                        if (dirBtn.disabled) return;
                        if (mouse.button === Qt.RightButton) root.chat.resetWorkDir();
                        else root.pickWorkDir();
                    }
                }
                ToolTip.visible: dirMa.containsMouse
                ToolTip.delay: 700
                ToolTip.text: root.workDirChip.tooltip
            }
            Rectangle {
                id: modelBtn
                x: parent.width - 10 - width
                width: Math.min(parent.width - 20, mbRow.implicitWidth + 16)
                // 4 + line-height normal of 500 10.5px (13 in Chromium) + 4.
                height: 21
                radius: height / 2
                opacity: root.modelBtn.disabled ? 0.6 : 1
                color: (root.modelBtn.open || (mbMa.containsMouse && !root.modelBtn.disabled)) ? Qt.rgba(1, 1, 1, 0.1) : Qt.rgba(1, 1, 1, 0.06)
                Row {
                    id: mbRow
                    x: 8
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 5
                    Rectangle {
                        width: 6; height: 6; radius: 3
                        color: root.modelBtn.accent
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    C.CText {
                        id: mbName
                        text: root.modelBtn.name
                        size: 10.5
                        cssWeight: 500
                        color: "#7b8089"
                        width: Math.min(implicitWidth, modelRow.width - 20 - 16 - 6 - 9 - 10)
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    C.Icon {
                        path: root.lib.ICONS.chevronUpDown
                        size: 9
                        stroke: 2
                        color: "#5c6370"
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }
                MouseArea { id: mbMa; anchors.fill: parent; hoverEnabled: true; onClicked: root.chat.modelButtonClicked(root.where) }
            }
        }

        // .chat-bar: the field and the send button.
        Rectangle {
            id: bar
            width: parent.width
            height: 28 + 12
            y: parent.height - height
            // Port (his ask): its right end is round around the round send
            // button; while the button stops an answer (a rounded square),
            // that end squares off like the left one, both morphing together.
            readonly property bool squared: send.stops
            property real endRadius: squared ? 12 : height / 2
            Behavior on endRadius { NumberAnimation { duration: 260; easing.type: Easing.BezierSpline; easing.bezierCurve: C.RoboTheme.ease } }
            topLeftRadius: 12
            bottomLeftRadius: 12
            topRightRadius: endRadius
            bottomRightRadius: endRadius
            color: Qt.rgba(1, 1, 1, 0.07)
            // Port (his ask): a file over the chat page takes the field's place.
            opacity: root.dragOver ? 0 : 1
            visible: opacity > 0
            Behavior on opacity { NumberAnimation { duration: 180; easing.type: Easing.BezierSpline; easing.bezierCurve: C.RoboTheme.ease } }

            TextInput {
                id: field
                x: 10
                width: parent.width - 10 - 6 - 28 - 8
                anchors.verticalCenter: parent.verticalCenter
                // Port: typing stays open while an answer comes (sent into it, or after it).
                color: C.RoboTheme.ink
                selectionColor: Qt.rgba(0.38, 0.65, 0.98, 0.35)
                selectedTextColor: color
                selectByMouse: true
                clip: true
                font.family: C.RoboTheme.font
                font.pointSize: C.RoboTheme.px(13)
                renderType: Text.NativeRendering
                // Enter sends (Ctrl+Enter too); Escape folds the picker. Escape
                // never leaves the field (upstream stops its propagation:
                // it closes the island only from outside the chat). Other
                // Ctrl keys the field does not use reach the island's keys.
                Keys.onPressed: event => {
                    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                        event.accepted = true;
                        root.submit();
                    } else if (event.key === Qt.Key_Escape) {
                        event.accepted = true;
                        if (root.chat.pickerOpen) root.chat.closePicker();
                        else {
                            root.escaped();
                            // His ask: Escape closes the notch from the field too.
                            if (C.Robo.island) C.Robo.island.escape();
                        }
                    } else if ((event.modifiers & Qt.ControlModifier) && C.Robo.dispatchKey(event)) {
                        // Upstream's capture-phase island keys run before the
                        // input sees them (Ctrl+K new chat, Ctrl+P, Ctrl+1–9…);
                        // TextInput would otherwise eat Ctrl+K (delete to end).
                        event.accepted = true;
                    }
                }
                // upstream inTextField(): Ctrl+←/→ move by word here, not between pills.
                onActiveFocusChanged: C.Robo.focusedTextField = activeFocus
                // The draft outlives the tab (the notch unloads it when it closes).
                // His ask: ONE draft for every chat field (the home card's, empty
                // or not, and the chat page's): the notch may reopen on another
                // view than the one it was typed in, and kept per view it was lost.
                Component.onCompleted: text = C.Robo.chatDrafts["chat"] || ""
                // (A field kept loaded while another was typed in catches up when shown.)
                onVisibleChanged: if (visible && !activeFocus && text !== (C.Robo.chatDrafts["chat"] || "")) text = C.Robo.chatDrafts["chat"] || ""
                onTextChanged: {
                    C.Robo.chatDrafts["chat"] = text;
                    if (activeFocus && C.Robo.island) C.Robo.island.typingActivity();
                }
                C.CText {
                    visible: field.text === ""
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width
                    // Arabic: .chat-input is `unicode-bidi: plaintext; text-align: start`;
                    // an empty field reads left to right, so its placeholder stays left.
                    horizontalAlignment: Text.AlignLeft
                    text: root.rev >= 0 ? root.chat.placeholder() : ""
                    size: 13
                    color: C.RoboTheme.dim3
                }
                HoverHandler { cursorShape: Qt.IBeamCursor }
            }

            // .send-btn: 28 px ink disc, arrow up 11, :active scale .94.
            // Port (his ask): 6 px in from the bar's round end, so the two are
            // concentric; a stop button is a square rounded as the bar's corners.
            Rectangle {
                id: send
                x: parent.width - 6 - 28
                anchors.verticalCenter: parent.verticalCenter
                width: 28; height: 28
                radius: bar.endRadius - 6
                color: C.RoboTheme.ink
                scale: sendMa.pressed ? 0.94 : 1
                Behavior on scale { NumberAnimation { duration: 80; easing.type: Easing.BezierSpline; easing.bezierCurve: C.RoboTheme.easeOut } }
                // Port: while an answer comes and nothing is typed, it stops it.
                readonly property bool stops: root.sending && field.text.trim() === ""
                C.Icon {
                    anchors.centerIn: parent
                    opacity: send.stops ? 0 : 1
                    scale: send.stops ? 0.6 : 1
                    visible: opacity > 0
                    Behavior on opacity { NumberAnimation { duration: 180; easing.type: Easing.BezierSpline; easing.bezierCurve: C.RoboTheme.ease } }
                    Behavior on scale { NumberAnimation { duration: 260; easing.type: Easing.BezierSpline; easing.bezierCurve: C.RoboTheme.ease } }
                    path: root.lib.ICONS.arrowUp
                    size: 11
                    color: "#0b0c0e"
                }
                Rectangle {
                    anchors.centerIn: parent
                    opacity: send.stops ? 1 : 0
                    scale: send.stops ? 1 : 0.6
                    visible: opacity > 0
                    Behavior on opacity { NumberAnimation { duration: 180; easing.type: Easing.BezierSpline; easing.bezierCurve: C.RoboTheme.ease } }
                    Behavior on scale { NumberAnimation { duration: 260; easing.type: Easing.BezierSpline; easing.bezierCurve: C.RoboTheme.ease } }
                    width: 9; height: 9; radius: 2
                    color: "#0b0c0e"
                }
                MouseArea { id: sendMa; anchors.fill: parent; onClicked: send.stops ? root.chat.stop() : root.submit() }
            }
        }
    }
}
