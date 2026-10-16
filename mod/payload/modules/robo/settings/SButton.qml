import QtQuick
import QtQuick.Controls

// settings.css button / .primary / .danger: 500 12.5px, padding 7 14, pill;
// hover rgba .15 (primary #fff), :active scale(.96), disabled opacity .45;
// transition background .14s, transform .08s.
Rectangle {
    id: b
    property string text: ""
    property string kind: ""
    property bool enabled2: true
    property string tooltip: ""
    signal clicked()
    readonly property bool live: enabled2
    readonly property color baseColor: kind === "primary" ? SettingsTheme.ink
        : kind === "danger" ? Qt.rgba(244 / 255, 80 / 255, 94 / 255, 0.16) : Qt.rgba(1, 1, 1, 0.09)
    readonly property color hoverColor: kind === "primary" ? "#ffffff"
        : Qt.rgba(1, 1, 1, 0.15)
    implicitWidth: Math.ceil(label.implicitWidth) + 28
    implicitHeight: label.lineH + 14
    width: implicitWidth
    height: implicitHeight
    radius: height / 2
    opacity: live ? 1 : 0.45
    color: live && ma.containsMouse ? hoverColor : baseColor
    scale: live && ma.pressed ? 0.96 : 1
    Behavior on color { ColorAnimation { duration: 140; easing.type: Easing.BezierSpline; easing.bezierCurve: SettingsTheme.ease } }
    Behavior on scale { NumberAnimation { duration: 80; easing.type: Easing.BezierSpline; easing.bezierCurve: SettingsTheme.ease } }
    SText {
        id: label
        x: 14
        y: 7
        text: b.text
        size: 12.5
        cssWeight: 500
        wrapMode: Text.NoWrap
        color: b.kind === "primary" ? "#0b0c0e" : b.kind === "danger" ? "#ff8d97" : SettingsTheme.ink
    }
    MouseArea {
        id: ma
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: b.live ? Qt.PointingHandCursor : Qt.ArrowCursor
        onClicked: if (b.live) b.clicked()
    }
    // The `title` attribute (shown on a disabled button too).
    ToolTip.visible: b.tooltip !== "" && ma.containsMouse
    ToolTip.delay: 600
    ToolTip.text: b.tooltip
}
