import QtQuick
import qs.modules.robo as C

// style.css .switch: 32×18 pill, rgba(255,255,255,0.15) / green when on,
// 14 px white knob at 2,2 sliding 14 px; background and knob 0.18 s ease.
Rectangle {
    id: sw
    property bool on: false
    signal toggled()
    width: 32
    height: 18
    radius: 9
    color: on ? C.RoboTheme.green : Qt.rgba(1, 1, 1, 0.15)
    Behavior on color { ColorAnimation { duration: 180; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.25, 0.1, 0.25, 1, 1, 1] } }
    Rectangle {
        x: sw.on ? 16 : 2
        y: 2
        width: 14
        height: 14
        radius: 7
        color: "#ffffff"
        Behavior on x { NumberAnimation { duration: 180; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.25, 0.1, 0.25, 1, 1, 1] } }
    }
    MouseArea { anchors.fill: parent; onClicked: sw.toggled() }
}
