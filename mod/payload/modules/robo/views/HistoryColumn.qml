pragma ComponentBehavior: Bound

import QtQuick
import qs.modules.robo as C

// Port only: the Robo tab's chats column (lib/views/history.ts). Earlier
// chats, most recently used first: Claude Code sessions of every project
// ("Claude Code" + the project folder, named as `claude --resume` names
// them) and chats started in Robo ("Robo · <model>"). A click reopens one
// in the chat to continue it. Listed by ambxst-robo (cached on file mtimes):
// asked when the column shows, then every 20 s while it stays on screen.
// A .card holding pill-like rows (cardFlat, the provider's colour on hover).
Item {
    id: root
    /** Port: the card a first right-click armed for removal ("kind:id"), for a few seconds. */
    property string armedKey: ""
    Timer { id: disarm; interval: 3200; onTriggered: root.armedKey = "" }
    readonly property var lib: C.Robo.lib
    readonly property var hist: lib.ChatHistory.history()
    readonly property var str: lib.ChatHistory.strings()
    property int hrev: 0
    readonly property int rev: C.Robo.rev + hrev
    // Only a new list redraws the cards (not every island notify).
    readonly property var cards: hrev >= 0 ? hist.cards : []
    /** An answer is on its way (read on each notify: chat.ts is plain JS). */
    property bool sending: false
    onRevChanged: sending = lib.ChatView.chat().sending

    function hexA(hex, a) { const c = Qt.color(hex); return Qt.rgba(c.r, c.g, c.b, a); }

    // ── Port (his ask: multitasking): a conversation's mini hovered or carried ──
    /** Its card ("kind:id"): scrolled into view, quickly and smoothly, and glowing. */
    readonly property string focusKey: C.Robo.convFocusKey
    function rowFor(key) {
        if (!key) return null;
        for (let i = 0; i < rows.count; i++) {
            const r = rows.itemAt(i);
            if (r && r.modelData.kind + ":" + r.modelData.id === key) return r;
        }
        return null;
    }
    /** The whole column in `item`'s coordinates (a carried mini dropped on it retires). */
    function columnRect(item) {
        if (!visible || width <= 0) return null;
        const p = mapToItem(item, 0, 0);
        return Qt.rect(p.x, p.y, width, height);
    }
    /** Card `key` in `item`'s coordinates, clipped to the list (null: not shown). */
    function cardRect(key, item) {
        const r = rowFor(key);
        if (!r || !visible) return null;
        const p = r.mapToItem(item, 0, 0);
        const top = list.mapToItem(item, 0, 0);
        const y0 = Math.max(p.y, top.y), y1 = Math.min(p.y + r.height, top.y + list.height);
        return y1 > y0 ? Qt.rect(p.x, y0, r.width, y1 - y0) : null;
    }
    onFocusKeyChanged: {
        const r = rowFor(focusKey);
        if (!r) return;
        // Centred in the list when it can be.
        const want = Math.max(0, Math.min(list.contentHeight - list.height, r.y + r.height / 2 - list.height / 2));
        scrollTo.to = want;
        scrollTo.restart();
    }
    NumberAnimation { id: scrollTo; target: list; property: "contentY"; duration: 240; easing.type: Easing.OutCubic }

    readonly property var hooks: ({ changed: () => { root.hrev++; } })
    Component.onCompleted: {
        C.Robo.historyView = root;
        C.Robo.historyViews = C.Robo.historyViews.concat([root]);
        hist.addHooks(hooks);
        if (visible) refreshSoon.restart();
    }
    Component.onDestruction: {
        hist.removeHooks(hooks);
        if (C.Robo.historyView === root) C.Robo.historyView = null;
        C.Robo.historyViews = C.Robo.historyViews.filter(x => x !== root);
    }
    // Port (performance): on showing, once the notch has opened: a list that
    // changed meanwhile rebuilds the column's cards, which held up the
    // opening animation when the answer came back during it.
    onVisibleChanged: if (visible) refreshSoon.restart()
    Timer { id: refreshSoon; interval: 400; onTriggered: if (root.visible) root.hist.refresh() }
    // A finished answer moves its chat to the top.
    onSendingChanged: if (!sending && visible) hist.refresh()
    Timer {
        interval: 20000
        repeat: true
        running: root.visible
        onTriggered: root.hist.refresh()
    }

    Card {
        anchors.fill: parent

        C.CText {
            id: title
            x: 1 + 14
            y: 1 + 11
            text: root.str.title
            size: 12
            cssWeight: 600
            color: C.RoboTheme.ink2
        }
        C.CText {
            id: errorLine
            visible: root.hrev >= 0 && root.hist.error !== ""
            x: title.x
            y: title.y + title.height + 2
            width: parent.width - 2 * x
            text: root.hrev >= 0 ? root.hist.error : ""
            size: 10.5
            color: C.RoboTheme.redText
            wrapMode: Text.Wrap
            maximumLineCount: 3
        }

        Flickable {
            id: list
            x: 1 + 8
            y: (errorLine.visible ? errorLine.y + errorLine.height : title.y + title.height) + 8
            width: parent.width - 2 - 16
            height: parent.height - 1 - 8 - y
            clip: true
            contentWidth: width
            contentHeight: col.implicitHeight
            boundsBehavior: Flickable.StopAtBounds

            Column {
                id: col
                width: list.width - bar.width - (bar.width > 0 ? 3 : 0)
                spacing: 6

                C.CText {
                    visible: root.hrev >= 0 && root.hist.loaded && root.cards.length === 0
                    x: 6
                    text: root.str.empty
                    size: 11
                    color: C.RoboTheme.dim3
                }

                Repeater {
                    id: rows
                    model: root.cards
                    delegate: Item {
                        id: row
                        required property var modelData
                        readonly property bool hovered: ma.containsMouse
                        readonly property bool lit: hovered || modelData.current || beckoned
                        // Port: one right-click arms the card (red), a second one removes it.
                        readonly property bool armed: root.armedKey === modelData.kind + ":" + modelData.id
                        readonly property bool opening: root.hrev >= 0 && root.hist.opening === modelData.kind + ":" + modelData.id
                        width: col.width
                        height: inner.implicitHeight + 16
                        opacity: opening ? 0.6 : 1
                        // Port: its conversation's mini is hovered or carried.
                        // Port (his ask): a chat's card wears its chat's colour (lib/looks.ts),
                        // so the one lit by hovering a mini glows like that mini.
                        readonly property string accent: { void C.Robo.rev; return C.Robo.lib.Looks.colorForKey(modelData.kind + ":" + modelData.id, modelData.accent); }
                        readonly property bool beckoned: root.focusKey !== "" && root.focusKey === modelData.kind + ":" + modelData.id

                        Rectangle {
                            id: bg
                            anchors.fill: parent
                            radius: 12
                            color: row.armed ? Qt.rgba(0.94, 0.27, 0.32, 0.22)
                                 : row.lit ? Qt.lighter(root.hexA(row.accent, 0x2e / 255), 1.06) : C.RoboTheme.cardFlat
                            border.width: 1
                            border.color: row.armed ? Qt.rgba(0.94, 0.27, 0.32, 0.75)
                                        : root.hexA(row.accent, row.lit ? 0x8c / 255 : 0x24 / 255)
                            Behavior on color { ColorAnimation { duration: 180; easing.type: Easing.BezierSpline; easing.bezierCurve: C.RoboTheme.ease } }
                            Behavior on border.color { ColorAnimation { duration: 180; easing.type: Easing.BezierSpline; easing.bezierCurve: C.RoboTheme.ease } }
                        }
                        // A glowing ring on the card, pulsing while it is wanted (the list clips
                        // anything outside the card).
                        Rectangle {
                            id: glow
                            anchors.fill: parent
                            radius: 12
                            color: root.hexA(row.accent, 0.12 * pulse)
                            border.width: 2
                            border.color: root.hexA(row.accent, 0.45 + 0.5 * pulse)
                            property real pulse: 0
                            opacity: row.beckoned ? 1 : 0
                            Behavior on opacity { NumberAnimation { duration: 180 } }
                            SequentialAnimation on pulse {
                                running: row.beckoned && glow.visible
                                loops: Animation.Infinite
                                NumberAnimation { to: 1; duration: 520; easing.type: Easing.InOutSine }
                                NumberAnimation { to: 0; duration: 520; easing.type: Easing.InOutSine }
                            }
                        }

                        Column {
                            id: inner
                            x: 10
                            y: 8
                            width: row.width - 20
                            spacing: 3
                            Item {
                                width: parent.width
                                height: top.height
                                C.CText {
                                    id: top
                                    width: Math.min(implicitWidth, parent.width - (corner.text ? corner.implicitWidth + 8 : 0))
                                    text: row.modelData.top
                                    size: 10
                                    cssWeight: 500
                                    color: row.lit ? C.RoboTheme.dim : C.RoboTheme.dim3
                                }
                                C.CText {
                                    id: corner
                                    x: parent.width - width
                                    width: Math.min(implicitWidth, parent.width * 0.55)
                                    text: row.modelData.corner
                                    size: 10
                                    cssWeight: 500
                                    color: row.lit ? C.RoboTheme.dim : C.RoboTheme.dim3
                                    horizontalAlignment: Text.AlignRight
                                }
                            }
                            C.CText {
                                width: parent.width
                                text: row.armed ? "Right-click again to delete" : row.modelData.title
                                size: 12
                                color: row.armed ? C.RoboTheme.redText : C.RoboTheme.ink2
                                wrapMode: Text.Wrap
                                maximumLineCount: 1000
                                elide: Text.ElideNone
                            }
                        }
                        MouseArea {
                            id: ma
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            acceptedButtons: Qt.LeftButton | Qt.RightButton
                            onClicked: m => {
                                const key = row.modelData.kind + ":" + row.modelData.id;
                                if (m.button === Qt.RightButton) {
                                    if (row.armed) {
                                        root.armedKey = "";
                                        root.hist.remove(row.modelData.kind, row.modelData.id);
                                    } else {
                                        root.armedKey = key;
                                        disarm.restart();
                                    }
                                    return;
                                }
                                root.armedKey = "";
                                if (!row.modelData.current) root.hist.open(row.modelData.kind, row.modelData.id);
                            }
                        }
                    }
                }
            }
        }
        // A carried mini is over the column: letting go retires it.
        Rectangle {
            anchors.fill: parent
            radius: 20
            color: "transparent"
            border.width: 2
            border.color: Qt.rgba(0.85, 0.47, 0.34, 0.8)
            opacity: C.Robo.convDropOver ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 160 } }
        }
        ChatScrollbar {
            id: bar
            flick: list
            x: list.x + list.width - width
            y: list.y
            height: list.height
        }
    }
}
