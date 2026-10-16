import QtQuick
import qs.modules.robo as C

// style.css .btn (.primary / .secondary): 500 12.5px, padding 7 13, pill,
// :active scale(0.94), optional .kbd hint.
Rectangle {
    id: b
    property string label: ""
    property string kind: "secondary"
    property string kbd: ""
    property bool off: false
    signal clicked()
    implicitWidth: row.implicitWidth + 26
    // 7 + 7 px padding around a 12.5 px line (15 px in Chromium); Qt's 13 px
    // line would make every button 1 px taller.
    implicitHeight: 29
    width: implicitWidth
    height: implicitHeight
    radius: height / 2
    opacity: off ? 0.4 : 1
    color: kind === "primary" ? C.RoboTheme.ink
         : (ma.containsMouse ? Qt.rgba(1, 1, 1, 0.15) : Qt.rgba(1, 1, 1, 0.09))
    scale: ma.pressed ? 0.94 : 1
    Behavior on scale { NumberAnimation { duration: 80; easing.type: Easing.BezierSpline; easing.bezierCurve: C.RoboTheme.easeOut } }
    Behavior on color { ColorAnimation { duration: 120; easing.type: Easing.BezierSpline; easing.bezierCurve: C.RoboTheme.easeOut } }
    Row {
        id: row
        anchors.centerIn: parent
        spacing: 7
        C.CText {
            text: b.label
            size: 12.5
            cssWeight: 500
            color: b.kind === "primary" ? "#0b0c0e" : C.RoboTheme.ink2
            anchors.verticalCenter: parent.verticalCenter
        }
        Rectangle {
            visible: b.kbd !== ""
            anchors.verticalCenter: parent.verticalCenter
            width: kt.implicitWidth + 8
            height: kt.implicitHeight
            radius: 4
            color: "transparent"
            opacity: 0.55
            border.width: 1
            border.color: b.kind === "primary" ? Qt.rgba(0, 0, 0, 0.4) : Qt.rgba(1, 1, 1, 0.4)
            C.CText {
                id: kt
                anchors.centerIn: parent
                text: b.kbd
                size: 10.5
                color: b.kind === "primary" ? "#0b0c0e" : C.RoboTheme.ink2
            }
        }
    }
    MouseArea { id: ma; anchors.fill: parent; hoverEnabled: true; onClicked: b.clicked() }
}
