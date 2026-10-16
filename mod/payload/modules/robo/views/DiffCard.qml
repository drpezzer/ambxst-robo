pragma ComponentBehavior: Bound

import QtQuick
import qs.modules.robo as C

// views/diff.ts buildDiffCard(): the overview's left card while a diff step of
// the ticker is open — head (‹ file name, +N −M, ↗ open in VS Code), then the
// scrolling lines (.diff-card padding 4 10 4 108, inside the card's 1 px border).
// Escape steps back out (keyDown, wired by the lead); Ctrl+E lives in
// OverviewView.command("toggleDiff").
Item {
    id: root
    property var task: null
    property var overview: null
    readonly property var lib: C.Robo.lib
    readonly property var diff: C.Robo.rev >= 0 && task && overview && overview.diffId !== null
        ? C.Robo.state.findDiff(task.id, overview.diffId) : null
    readonly property real k: 10.5 / 11
    readonly property var d: diff ? lib.Status.diffCard(diff) : null

    function dismiss() {
        if (C.Robo.island) C.Robo.island.actions.blip();
        if (overview) overview.closeDiff();
    }
    /** Escape → back to the ticker (upstream: a capturing window keydown listener). */
    function keyDown(ev) {
        const key = ev ? ev.key : null;
        if (key !== "Escape" && key !== Qt.Key_Escape) return false;
        if (overview) overview.closeDiff();
        return true;
    }

    // .diff-head: padding 6 0 3, gap 6, centred.
    Item {
        id: head
        x: 1 + 108
        y: 1 + 4 + 6
        width: parent.width - 2 - 108 - 10
        height: Math.max(nameT.implicitHeight, 14)

        // .diff-back: chevron 9 (stroke 2.4) + <b> 600 12px, gap 3.
        Item {
            id: back
            height: parent.height
            width: nameT.x + nameT.width
            C.Icon {
                id: chev
                anchors.verticalCenter: parent.verticalCenter
                path: root.lib.ICONS.chevronLeft
                size: 9
                stroke: 2.4
                color: C.RoboTheme.ink
            }
            C.CText {
                id: nameT
                x: chev.width + 3
                anchors.verticalCenter: parent.verticalCenter
                text: root.d ? root.d.name : ""
                size: 12; cssWeight: 600
                width: Math.min(implicitWidth, Math.max(0, head.width - x - tail.width - 6))
            }
            MouseArea { anchors.fill: parent; onClicked: root.dismiss() }
        }

        Row {
            id: tail
            spacing: 6
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            C.CText {
                visible: text !== ""
                anchors.verticalCenter: parent.verticalCenter
                text: root.d ? root.d.plus : ""
                size: 10; cssWeight: 500
                font.family: C.RoboTheme.mono
                color: C.RoboTheme.green
                elide: Text.ElideNone
            }
            C.CText {
                visible: text !== ""
                anchors.verticalCenter: parent.verticalCenter
                text: root.d ? root.d.minus : ""
                size: 10; cssWeight: 500
                font.family: C.RoboTheme.mono
                color: C.RoboTheme.red
                elide: Text.ElideNone
            }
            // .icon-btn 14×14: ↗ opens the file in VS Code.
            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: 14; height: 14; radius: 7
                color: Qt.rgba(1, 1, 1, 0.07)
                C.Icon { anchors.centerIn: parent; path: root.lib.ICONS.arrowUpRight; size: 8; color: C.RoboTheme.dim4 }
                MouseArea {
                    anchors.fill: parent
                    onClicked: if (root.d) root.lib.Bridge.openFileInVSCode(root.d.path)
                }
            }
        }
    }

    // .diff-note: 400 10.5px, --dim-3.
    C.CText {
        visible: !!root.d && root.d.note !== ""
        x: head.x
        y: head.y + head.height + 3
        width: head.width
        text: root.d ? root.d.note : ""
        size: 10.5
        color: C.RoboTheme.dim3
    }

    // .diff-lines: fills the rest, scrolls, no scrollbar.
    Flickable {
        id: flick
        visible: !!root.d && root.d.note === ""
        x: head.x
        y: head.y + head.height + 3
        width: head.width
        height: parent.height - 1 - 4 - y
        clip: true
        contentWidth: width
        contentHeight: Math.round(lines.count * 14.175)
        boundsBehavior: Flickable.StopAtBounds
        // Rows of 14.175 px (line-height 1.35), snapped to whole pixels as
        // Chromium paints their backgrounds.
        Item {
            id: col
            width: flick.width
            Repeater {
                id: lines
                model: root.d ? root.d.lines : []
                delegate: Rectangle {
                    id: line
                    required property var modelData
                    required property int index
                    readonly property string kind: modelData.kind
                    width: col.width
                    // font 400 10.5px/1.35, min-height 14.
                    y: Math.round(index * 14.175)
                    height: Math.round((index + 1) * 14.175) - y
                    color: kind === "added" ? Qt.rgba(34 / 255, 197 / 255, 94 / 255, 0.12)
                         : kind === "removed" ? Qt.rgba(244 / 255, 80 / 255, 94 / 255, 0.12) : "transparent"
                    // Qt rounds a 10.5 px font to 11 px: drawn at 11 and scaled
                    // by 10.5/11 so the columns line up as in Chromium.
                    C.CText {
                        width: 12 / root.k
                        height: parent.height / root.k
                        scale: root.k
                        transformOrigin: Item.TopLeft
                        verticalAlignment: Text.AlignVCenter
                        text: line.modelData.sym
                        size: 11
                        font.family: C.RoboTheme.mono
                        elide: Text.ElideNone
                        color: line.kind === "added" ? C.RoboTheme.green
                             : line.kind === "removed" ? C.RoboTheme.red : "#454850"
                    }
                    C.CText {
                        x: 12
                        width: (parent.width - 12) / root.k
                        height: parent.height / root.k
                        scale: root.k
                        transformOrigin: Item.TopLeft
                        verticalAlignment: Text.AlignVCenter
                        text: line.modelData.text
                        size: 11
                        font.family: C.RoboTheme.mono
                        color: line.kind === "added" ? "#86efac"
                             : line.kind === "removed" ? "#fca5a5" : C.RoboTheme.dim3
                    }
                }
            }
        }
    }
}
