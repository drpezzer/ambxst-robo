import QtQuick

// settings.css .keycap — a <button> (or a span when `static`): 500 11.5px mono,
// min-width 118, padding 5 10, radius 8, rgba .07 + hairline border; centred.
// .recording: border rgba .4, --dim text. .static: transparent, --dim.
// The button also takes button:hover (.15), :active scale .96, :disabled .45.
Rectangle {
    id: k
    property string text: ""
    property bool isStatic: false
    property bool recording: false
    property bool enabled2: true
    signal clicked()
    readonly property bool live: !isStatic && enabled2
    implicitWidth: Math.max(118, Math.ceil(t.implicitWidth) + 22)
    implicitHeight: t.lineH + 12
    width: implicitWidth
    height: implicitHeight
    radius: 8
    opacity: !isStatic && !enabled2 ? 0.45 : 1
    color: isStatic ? "transparent" : live && ma.containsMouse ? Qt.rgba(1, 1, 1, 0.15) : Qt.rgba(1, 1, 1, 0.07)
    border.width: 1
    border.color: isStatic ? SettingsTheme.hairline : recording ? Qt.rgba(1, 1, 1, 0.442) : SettingsTheme.fieldBorder
    scale: live && ma.pressed ? 0.96 : 1
    Behavior on color { ColorAnimation { duration: 140; easing.type: Easing.BezierSpline; easing.bezierCurve: SettingsTheme.ease } }
    Behavior on scale { NumberAnimation { duration: 80; easing.type: Easing.BezierSpline; easing.bezierCurve: SettingsTheme.ease } }
    SText {
        id: t
        anchors.horizontalCenter: parent.horizontalCenter
        y: 6
        size: 11.5
        cssWeight: 500
        mono: true
        wrapMode: Text.NoWrap
        text: k.text
        color: k.isStatic || k.recording ? SettingsTheme.dim : SettingsTheme.ink
    }
    MouseArea {
        id: ma
        anchors.fill: parent
        enabled: !k.isStatic
        hoverEnabled: true
        cursorShape: k.live ? Qt.PointingHandCursor : Qt.ArrowCursor
        onClicked: if (k.live) k.clicked()
    }
}
