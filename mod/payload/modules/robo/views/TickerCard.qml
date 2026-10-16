pragma ComponentBehavior: Bound

import QtQuick
import qs.modules.robo as C

// views/views.ts buildOverview() ticker body (.card-body: the `who` row +
// views/ticker.ts Ticker). The ticker's decisions live in lib/views/status.ts
// (TickerModel, one per overview as upstream); this file draws its rows.
Item {
    id: root
    property var task: null
    /** OverviewView, set on load: openDiff(id) / closeDiff(). */
    property var overview: null
    readonly property var lib: C.Robo.lib
    readonly property var model: lib.Status.overviewTicker
    readonly property var who: C.Robo.rev >= 0 && task ? lib.Status.sessionWho(task) : ({ name: "", tool: "", count: "" })
    /**
     * Port: the session's helpers (subagents with a pill of their own, see
     * lib/main.ts) — "Working with N helpers" under the who row; on a helper's
     * own card, whose helper it is.
     */
    readonly property var helpers: C.Robo.rev >= 0 && task ? C.Robo.state.tasks.filter(t => t.helperOf === task.id) : []
    readonly property var helperParent: C.Robo.rev >= 0 && task && task.helperOf ? C.Robo.state.tasks.find(t => t.id === task.helperOf) || null : null
    readonly property string helperLine: helpers.length === 1 ? "Working with 1 helper"
        : helpers.length > 1 ? "Working with " + helpers.length + " helpers"
        : helperParent ? "Helper of " + helperParent.name : ""
    /** Bumped whenever the model's rows moved (sync or tick). */
    property int frame: 0

    function sync() {
        if (!task) return;
        model.sync(task);
        frame++;
        if (model.animating && C.Robo.island) C.Robo.island.ensureRunning();
    }
    function tick(nowMs) {
        model.tick(nowMs);
        frame++;
        return model.animating;
    }
    onTaskChanged: sync()
    Component.onCompleted: sync()
    Connections {
        target: C.Robo
        function onRevChanged() { root.sync(); }
    }

    // .card-body: padding-top 10 (inside the card's 1 px border).
    // .who: padding 0 36 0 108, gap 6, centred.
    Item {
        id: whoRow
        x: 1 + 108
        y: 1 + 10
        width: parent.width - 2 - 108 - 36
        height: Math.max(nameT.implicitHeight, toolT.implicitHeight)
        Dot {
            id: dot
            size: 7
            color: root.task ? root.task.color : "white"
            anchors.verticalCenter: parent.verticalCenter
        }
        C.CText {
            id: nameT
            x: dot.width + 6
            anchors.verticalCenter: parent.verticalCenter
            text: root.who.name
            size: 12; cssWeight: 600
            width: Math.min(implicitWidth, Math.max(0, whoRow.width - x - 6 - toolT.implicitWidth - (countT.text ? 6 + countT.implicitWidth : 0)))
        }
        C.CText {
            id: toolT
            x: nameT.x + nameT.width + 6
            anchors.verticalCenter: parent.verticalCenter
            text: root.who.tool
            size: 11
            color: C.RoboTheme.dim2
            elide: Text.ElideNone
        }
        C.CText {
            id: countT
            x: whoRow.width - implicitWidth
            anchors.verticalCenter: parent.verticalCenter
            visible: text !== ""
            text: root.who.count
            size: 11
            color: C.RoboTheme.dim3
        }
    }

    // Port: the helpers line, between the who row and the ticker (his layout).
    C.CText {
        id: helperT
        x: whoRow.x + dot.width + 6
        y: whoRow.y + whoRow.height + 4
        visible: root.helperLine !== ""
        text: root.helperLine
        size: 11
        color: root.task ? root.task.color : C.RoboTheme.dim2
        opacity: 0.85
    }

    // .ticker: height 44, margin 6 12 0 108, clipped, faded top and bottom
    // (mask: transparent 0 %, #000 12 %, #000 85 %, transparent 100 %).
    Item {
        id: tickerBox
        x: 1 + 108
        y: whoRow.y + whoRow.height + 6 + (helperT.visible ? helperT.implicitHeight + 2 : 0)
        width: parent.width - 2 - 108 - 12
        height: 44

        Item {
            id: rowsLayer
            anchors.fill: parent
            clip: true
            // Shape's curve renderer ignores the scissor clip (the ✓ of the
            // completed row showed left of the ticker): a layer clips for sure.
            layer.enabled: true
            Repeater {
                model: 3
                delegate: TickerRow {
                    required property int index
                    rowW: tickerBox.width
                    row: root.frame >= 0 ? root.model.rows[index] : null
                    frame: root.frame
                }
            }
        }
        // The mask's fades, drawn in the card's (flat) colour over the rows:
        // the same pixels as masking them, without a shader pass.
        Rectangle {
            width: parent.width
            height: parent.height * 0.12
            gradient: Gradient {
                GradientStop { position: 0.0; color: C.RoboTheme.card }
                GradientStop { position: 1.0; color: Qt.rgba(C.RoboTheme.card.r, C.RoboTheme.card.g, C.RoboTheme.card.b, 0) }
            }
        }
        Rectangle {
            y: parent.height * 0.85
            width: parent.width
            height: parent.height * 0.15
            gradient: Gradient {
                GradientStop { position: 0.0; color: Qt.rgba(C.RoboTheme.card.r, C.RoboTheme.card.g, C.RoboTheme.card.b, 0) }
                GradientStop { position: 1.0; color: C.RoboTheme.card }
            }
        }
        // Click targets for the completed and the current row.
        Repeater {
            model: 2
            delegate: MouseArea {
                required property int index
                readonly property var row: root.frame >= 0 ? root.model.rows[index] : null
                x: 0
                y: row ? row.y : 0
                width: tickerBox.width
                height: 22
                enabled: !!row && !!row.diff
                onClicked: {
                    if (!root.overview) return;
                    const id = root.model.diffIdAt(index);
                    if (id === null) return;
                    if (C.Robo.island) C.Robo.island.actions.blip();
                    root.overview.openDiff(id);
                }
            }
        }
    }
}
