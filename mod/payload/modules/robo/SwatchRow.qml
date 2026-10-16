import QtQuick
import qs.modules.robo as C

// Port only (his ask): a row of colour swatches, the chosen one ringed, as
// the robot-heads playground draws them (.swatch 20 px, hover 1.15, ringed
// 0 0 0 2px bg + 0 0 0 3px ink); the last one is the rainbow "custom" dot
// (.swatch-custom: a conic hue gradient), showing the colour once it is a
// custom one, that asks for the colour wheel. An optional first swatch is
// the agent's own colour ("" when picked).
Row {
    id: row
    property var colors: []
    /** The colour now ("" = the agent's). */
    property string current: ""
    /** Shown first when set: "the agent's colour" (picked as ""). */
    property string agentColor: ""
    property real size: 20
    property color ring: "#f2f3f5"
    property color bg: "#141518"
    signal picked(string color)
    /** The custom dot was clicked: open the wheel (its centre, in `row`). */
    signal custom(real cx, real cy)
    spacing: 8

    readonly property bool isCustom: current !== ""
        && !colors.some(c => c.toLowerCase() === current.toLowerCase())

    component Swatch: Item {
        id: sw
        property color fill: "transparent"
        property bool on: false
        property bool agent: false
        signal clicked()
        width: row.size; height: row.size
        scale: ma.containsMouse ? 1.15 : 1
        Behavior on scale { NumberAnimation { duration: 150; easing.type: Easing.BezierSpline; easing.bezierCurve: C.RoboTheme.ease } }
        // The ring (0 0 0 2px bg, 0 0 0 3px ink).
        Rectangle {
            anchors.centerIn: parent
            width: parent.width + 6; height: width; radius: width / 2
            color: "transparent"
            border.width: 1.5
            border.color: row.ring
            visible: sw.on
        }
        Rectangle {
            anchors.fill: parent
            radius: width / 2
            color: sw.fill
            border.width: 1
            border.color: Qt.rgba(1, 1, 1, 0.16)
        }
        // The agent's colour: a small "A" mark.
        C.CText {
            visible: sw.agent
            anchors.centerIn: parent
            text: "A"
            size: 10; cssWeight: 700
            color: Qt.rgba(0, 0, 0, 0.55)
        }
        MouseArea { id: ma; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: sw.clicked() }
    }

    Swatch {
        visible: row.agentColor !== ""
        fill: row.agentColor || "transparent"
        agent: true
        on: row.current === ""
        onClicked: row.picked("")
    }
    Repeater {
        model: row.colors
        Swatch {
            required property string modelData
            fill: modelData
            on: row.current.toLowerCase() === modelData.toLowerCase()
            onClicked: row.picked(modelData)
        }
    }
    // .swatch-custom
    Swatch {
        id: customDot
        fill: row.isCustom ? row.current : "transparent"
        on: row.isCustom
        onClicked: {
            const p = customDot.mapToItem(row, customDot.width / 2, customDot.height / 2);
            row.custom(p.x, p.y);
        }
        Canvas {
            anchors.fill: parent
            visible: !row.isCustom
            onPaint: {
                const ctx = getContext("2d");
                ctx.reset();
                const g = ctx.createConicalGradient(width / 2, height / 2, 0);
                const stops = ["#ff6b6b", "#ff6bd0", "#8a6bff", "#6bd6ff", "#7dff9a", "#ffd36b", "#ff6b6b"];
                stops.forEach((c, i) => g.addColorStop(i / (stops.length - 1), c));
                ctx.fillStyle = g;
                ctx.beginPath();
                ctx.arc(width / 2, height / 2, width / 2, 0, Math.PI * 2);
                ctx.fill();
            }
        }
    }
}
