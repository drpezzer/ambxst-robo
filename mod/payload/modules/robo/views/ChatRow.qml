pragma ComponentBehavior: Bound

import QtQuick
import qs.modules.robo as C

// One row of the chat log (.chat-row): a user bubble, a Markdown answer, or
// the typing dots. ChatPanel draws the history's rows in a Repeater and the
// streamed answer / dots in one more of these after it, so a streamed delta
// redraws that row only (not every turn of the log).
Item {
    id: row
    /** {role, content, typing?, queued?, caption?} */
    property var modelData: ({ role: "assistant", content: "" })
    /** Port: the log's selection (ChatPanel) tells messages apart by this. */
    readonly property bool isChatRow: true
    implicitHeight: modelData.role === "user" ? bubble.y + bubble.height
        : modelData.role === "compacting" || modelData.role === "working" ? 22
        : modelData.role === "remote" ? (remoteCard.item ? remoteCard.item.height : 0)
        : modelData.role === "compact" ? 22
        : modelData.role === "note" ? (noteText.item ? noteText.item.implicitHeight : 0) + 6
        : modelData.typing ? 13 : reply.implicitHeight
    readonly property bool special: modelData.role === "compact" || modelData.role === "compacting" || modelData.role === "working" || modelData.role === "remote" || modelData.role === "note"

    // Port (his ask): a message typed while Claude Code works waits under the
    // working line (ChatPanel dims it) with a small caption at its top-left
    // ("waiting politely…") until Claude Code takes it in.
    readonly property bool queued: modelData.role === "user" && !!modelData.queued
    Loader {
        id: caption
        active: row.queued
        x: Math.max(0, Math.min(bubble.x + 4, row.width - (item ? item.implicitWidth : 0)))
        sourceComponent: C.CText {
            text: row.modelData.caption || ""
            font.italic: true
            size: 10
            color: C.RoboTheme.dim3
        }
    }

    // .chat-row.user > .bubble: right-aligned, 32 px kept on the left.
    Rectangle {
        id: bubble
        visible: row.modelData.role === "user"
        width: visible ? Math.min(bubbleText.implicitWidth, row.width - 32 - 20) + 20 : 0
        height: visible ? bubbleText.implicitHeight + 12 : 0
        x: row.width - width
        y: row.queued && caption.item ? caption.item.implicitHeight + 2 : 0
        radius: 12
        color: Qt.rgba(1, 1, 1, 0.13)
        TextEdit {
            id: bubbleText
            persistentSelection: true
            x: 10
            y: 6
            width: Math.min(implicitWidth, row.width - 32 - 20)
            readOnly: true
            selectByMouse: true
            // pre-wrap text, its line kept at Chromium's 15 px (see ChatMarkdown).
            textFormat: TextEdit.RichText
            text: row.modelData.role === "user"
                ? "<div style=\"white-space:pre-wrap; line-height:15px; -qt-line-height-type:fixed\">" + reply.esc(row.modelData.content) + "</div>" : ""
            wrapMode: TextEdit.Wrap
            color: C.RoboTheme.ink2
            selectionColor: Qt.rgba(0.38, 0.65, 0.98, 0.35)
            selectedTextColor: color
            font.family: C.RoboTheme.font
            font.pointSize: C.RoboTheme.px(12.5)
            renderType: Text.NativeRendering
        }
    }
    // .reply: Markdown, padding-right 8.
    ChatMarkdown {
        id: reply
        visible: row.modelData.role !== "user" && !row.modelData.typing && !row.special
        maxWidth: row.width - 8
        markdown: visible ? row.modelData.content : ""
    }
    // .typing: three 5 px dots, 4 apart, padding 4 2.
    // Port (performance): this row's other kinds (dots, the compacting /
    // working line, the Remote Control card, the compaction mark, a note)
    // are made only for a row of that kind: built for every row of the log,
    // they were most of the cost of opening the tab onto a long chat.
    Loader {
        active: !!row.modelData.typing
        x: 2
        y: 4
        sourceComponent: Row {
            id: dots
            spacing: 4
            // Port (performance): stepped ~30 times a second while on screen,
            // not every vsync (an Animation makes the notch's screen-sized
            // surface redraw at the display's rate).
            readonly property real t0: Date.now()
            property real t: 0
            C.AnimClock {
                running: dots.visible && row.modelData.typing === true
                onTick: ms => dots.t = ms - dots.t0
            }
            Repeater {
                model: 3
                delegate: Rectangle {
                    id: d
                    required property int index
                    width: 5; height: 5; radius: 2.5
                    color: C.RoboTheme.dim3
                    // @keyframes typing: 0.6 → 1.2 → 0.6 over 0.9 s, 0.14 s apart.
                    // During its animation-delay a dot keeps its own style
                    // (no transform = scale 1), as in CSS.
                    scale: {
                        const t = dots.t - d.index * 140;
                        if (t < 0) return 1;
                        const p = t % 900;
                        return p < 450 ? 0.6 + 0.6 * C.RoboTheme.easeInOutAt(p / 450)
                            : 1.2 - 0.6 * C.RoboTheme.easeInOutAt((p - 450) / 450);
                    }
                }
            }
        }
    }

    // Port (his ask): Claude Code compacting the conversation: the line
    // shimmers as a running step does in the pill (TickerRow's .shimmer: the
    // gradient #7c818a → #f2f3f5 40 % → #7c818a 70 %, 260 % of the text wide,
    // 130 % → −130 % in 2.2 s, each character taking its centre's colour).
    Loader {
        // Port (his ask): also the turn's "working" line (*Noodling…), its
        // text the verb ChatPanel picked for the turn.
        active: row.modelData.role === "compacting" || row.modelData.role === "working"
        sourceComponent: Item {
            id: compacting
            width: row.width - 8
            height: 22
            C.CText {
                id: compactMeasure
                visible: false
                text: row.modelData.role === "working" ? row.modelData.content : "Compacting conversation…"
                size: 13; cssWeight: 500
            }
            FontMetrics { id: compactFm; font: compactMeasure.font }
            readonly property var chars: Array.from(compactMeasure.text)
            readonly property var centres: {
                const out = [];
                let acc = "";
                for (let i = 0; i < chars.length; i++) {
                    const w = compactFm.advanceWidth(chars[i]);
                    out.push(compactFm.advanceWidth(acc) + w / 2);
                    acc += chars[i];
                }
                return out;
            }
            function mix(a, b, t) {
                return Qt.rgba(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t, 1);
            }
            function hex2(v) { const h = Math.round(v * 255).toString(16); return h.length < 2 ? "0" + h : h; }
            function shimmerHtml(pos) {
                const W = compactMeasure.implicitWidth;
                if (W <= 0) return "";
                const grey = Qt.color("#7c818a"), bright = Qt.color("#f2f3f5");
                const T = W * 2.6;
                const x0 = (W - T) * pos;
                let html = "";
                for (let i = 0; i < chars.length; i++) {
                    const u = ((centres[i] - x0) % T + T) % T / T;
                    const c = u < 0.4 ? mix(grey, bright, u / 0.4) : u < 0.7 ? mix(bright, grey, (u - 0.4) / 0.3) : grey;
                    const ch = chars[i] === " " ? "&nbsp;" : chars[i];
                    html += "<font color=\"#" + hex2(c.r) + hex2(c.g) + hex2(c.b) + "\">" + ch + "</font>";
                }
                return html;
            }
            C.CText {
                id: compactText
                anchors.verticalCenter: parent.verticalCenter
                size: 13; cssWeight: 500
                textFormat: Text.StyledText
                property real pos: 1.3
                text: compacting.visible ? compacting.shimmerHtml(pos) : ""
                // Port (performance): ~30 steps a second, not every vsync (AnimClock).
                C.AnimClock {
                    id: compactClock
                    running: compacting.visible
                    onTick: ms => compactText.pos = 1.3 - 2.6 * ((ms - compactClock.startMs) % 2200) / 2200
                }
            }
        }
    }
    // Port (his ask): Remote Control came on: the session's QR and link; the
    // first time, the app's too (claude.ai/mobile) and how to sign in.
    component QrCode: Canvas {
        id: qrc
        property string text: ""
        property var rows: []
        onRowsChanged: requestPaint()
        onTextChanged: if (text) C.Robo.lib.Remote.qr(text, r => { qrc.rows = r; })
        Component.onCompleted: if (text) C.Robo.lib.Remote.qr(text, r => { qrc.rows = r; })
        width: 104; height: 104
        onPaint: {
            const ctx = getContext("2d");
            ctx.reset();
            ctx.fillStyle = "#ffffff";
            ctx.beginPath();
            ctx.roundedRect(0, 0, width, height, 10, 10);
            ctx.fill();
            const n = rows.length;
            if (!n) return;
            const cell = Math.floor(width / n * 100) / 100;
            const off = (width - cell * n) / 2;
            ctx.fillStyle = "#0b0c0e";
            for (let y = 0; y < n; y++) {
                const r = rows[y];
                for (let x = 0; x < r.length; x++) if (r.charAt(x) === "1") ctx.fillRect(off + x * cell, off + y * cell, cell + 0.35, cell + 0.35);
            }
        }
    }
    Loader {
        id: remoteCard
        active: row.modelData.role === "remote"
        sourceComponent: Rectangle {
            id: remoteBox
            width: row.width - 8
            height: remoteCol.height + 24
            radius: 14
            color: Qt.rgba(1, 1, 1, 0.05)
            border.width: 1
            border.color: Qt.rgba(0.2, 0.83, 0.6, 0.35)
            readonly property string url: row.modelData.content || ""
            Column {
                id: remoteCol
                x: 12; y: 12
                width: parent.width - 24
                spacing: 10
                Row {
                    spacing: 14
                    QrCode { text: remoteBox.visible ? remoteBox.url : "" }
                    Column {
                        width: remoteCol.width - 104 - 14
                        spacing: 6
                        C.CText { text: "Remote Control is on"; size: 13; cssWeight: 600; color: C.RoboTheme.ink }
                        C.CText {
                            width: parent.width
                            wrapMode: Text.Wrap
                            elide: Text.ElideNone
                            maximumLineCount: 6
                            text: "Scan with your phone to continue this chat in the Claude app, or open it at claude.ai/code. Messages from either side land here too."
                            size: 12
                            color: C.RoboTheme.dim
                        }
                        C.CText {
                            width: parent.width
                            elide: Text.ElideMiddle
                            text: remoteBox.url
                            size: 11
                            color: "#34D399"
                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: C.Robo.lib.Bridge.openUrl(remoteBox.url) }
                        }
                    }
                }
                // The first time: the app, and the account to use.
                Row {
                    visible: !!row.modelData.intro
                    spacing: 14
                    QrCode { text: parent.visible ? "https://claude.ai/mobile" : "" }
                    Column {
                        width: remoteCol.width - 104 - 14
                        spacing: 6
                        C.CText { text: "No Claude app yet?"; size: 13; cssWeight: 600; color: C.RoboTheme.ink }
                        C.CText {
                            width: parent.width
                            wrapMode: Text.Wrap
                            elide: Text.ElideNone
                            maximumLineCount: 6
                            text: "Scan this to get it for iPhone or Android, then sign in with the same claude.ai account Claude Code uses here. Turn Remote Control off with the phone button above."
                            size: 12
                            color: C.RoboTheme.dim
                        }
                    }
                }
            }
        }
    }

    // …and where it happened, once it has: *Compacted conversation*.
    Loader {
        active: row.modelData.role === "compact"
        sourceComponent: Item {
            width: row.width - 8
            height: 22
            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                x: 0
                width: (parent.width - mark.implicitWidth) / 2 - 10
                height: 1
                color: Qt.rgba(1, 1, 1, 0.1)
            }
            C.CText {
                id: mark
                anchors.centerIn: parent
                text: "Compacted conversation"
                font.italic: true
                size: 11
                color: C.RoboTheme.dim3
            }
            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                x: (parent.width + mark.implicitWidth) / 2 + 10
                width: (parent.width - mark.implicitWidth) / 2 - 10
                height: 1
                color: Qt.rgba(1, 1, 1, 0.1)
            }
        }
    }

    // Port (his ask): a note from the chat itself (the working directory
    // changed, or is gone), centred like the compaction's mark.
    Loader {
        id: noteText
        active: row.modelData.role === "note"
        y: 3
        sourceComponent: C.CText {
            width: row.width - 8
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            // (CText is one line by default: a note wraps instead.)
            maximumLineCount: 6
            text: row.modelData.content
            font.italic: true
            size: 11
            color: C.RoboTheme.dim3
        }
    }
}
