import QtQuick

// settings.css .switch — a <button>: 36×20, radius 10, rgba .15 / green when
// .on, 16 px knob at 2,2 sliding 16 px in .18s. As a button it also takes
// `button:hover` (rgba .15, which wins over the green: upstream specificity),
// :active scale(.96) and disabled opacity .45. Controlled: `toggled(next)`.
Rectangle {
    id: sw
    property bool on: false
    property bool enabled2: true
    signal toggled(bool next)
    implicitWidth: 36
    implicitHeight: 20
    width: 36
    height: 20
    radius: 10
    opacity: enabled2 ? 1 : 0.45
    color: enabled2 && ma.containsMouse ? Qt.rgba(1, 1, 1, 0.15) : on ? SettingsTheme.green : Qt.rgba(1, 1, 1, 0.15)
    scale: enabled2 && ma.pressed ? 0.96 : 1
    Behavior on color { ColorAnimation { duration: 140; easing.type: Easing.BezierSpline; easing.bezierCurve: SettingsTheme.ease } }
    Behavior on scale { NumberAnimation { duration: 80; easing.type: Easing.BezierSpline; easing.bezierCurve: SettingsTheme.ease } }
    Rectangle {
        x: sw.on ? 18 : 2
        y: 2
        width: 16
        height: 16
        radius: 8
        color: "#ffffff"
        Behavior on x { NumberAnimation { duration: 180; easing.type: Easing.BezierSpline; easing.bezierCurve: SettingsTheme.ease } }
    }
    MouseArea {
        id: ma
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: sw.enabled2 ? Qt.PointingHandCursor : Qt.ArrowCursor
        onClicked: if (sw.enabled2) sw.toggled(!sw.on)
    }
}
