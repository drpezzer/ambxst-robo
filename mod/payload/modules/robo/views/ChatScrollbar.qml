import QtQuick
import qs.modules.robo as C

// The chat log's and the model list's scrollbar as the reference draws it
// (`scrollbar-width: thin; scrollbar-color: rgba(255,255,255,.18) transparent`):
// an 11 px gutter taken from the content while it overflows, arrow buttons
// 11 px tall at both ends, a 6 px rounded thumb 2 px in.
Item {
    id: sb
    property Flickable flick: null
    readonly property bool needed: flick !== null && flick.contentHeight > flick.height + 0.5
    readonly property color ink: Qt.rgba(1, 1, 1, 0.18)
    width: needed ? 11 : 0
    visible: needed

    readonly property real track: Math.max(0, height - 22)
    readonly property real thumbLen: needed ? Math.max(12, track * flick.height / flick.contentHeight) : 0
    readonly property real thumbPos: needed ? 11 + (track - thumbLen) * Math.min(1, Math.max(0, flick.contentY / (flick.contentHeight - flick.height))) : 0

    function step(dir) {
        flick.contentY = Math.min(flick.contentHeight - flick.height, Math.max(0, flick.contentY + dir * 40));
    }

    // ▲ / ▼: rows of 2, 4, 6 px.
    component Arrow: Item {
        property bool down: false
        width: 11; height: 11
        Repeater {
            model: 3
            delegate: Rectangle {
                required property int index
                readonly property int row: parent.down ? 2 - index : index
                x: 4 - row
                y: 4 + index
                width: 2 + row * 2
                height: 1
                color: sb.ink
            }
        }
    }
    Arrow {
        y: 0
        MouseArea { anchors.fill: parent; onClicked: sb.step(-1) }
    }
    Arrow {
        y: sb.height - 11
        down: true
        MouseArea { anchors.fill: parent; onClicked: sb.step(1) }
    }
    Rectangle {
        x: 2
        y: sb.thumbPos
        width: 6
        height: sb.thumbLen
        radius: 3
        color: sb.ink
        MouseArea {
            anchors.fill: parent
            property real grabY: 0
            property real startY: 0
            onPressed: m => { grabY = mapToItem(sb, m.x, m.y).y; startY = sb.flick.contentY; }
            onPositionChanged: m => {
                const dy = mapToItem(sb, m.x, m.y).y - grabY;
                const range = sb.flick.contentHeight - sb.flick.height;
                sb.flick.contentY = Math.min(range, Math.max(0, startY + dy * range / Math.max(1, sb.track - sb.thumbLen)));
            }
        }
    }
}
