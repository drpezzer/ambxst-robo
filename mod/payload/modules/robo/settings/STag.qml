import QtQuick

// settings.css .tag (.warn / .err) — 500 10.5px, padding 2 8, pill.
Rectangle {
    id: tg
    property string kind: ""
    property string text: ""
    implicitWidth: Math.ceil(t.implicitWidth) + 16
    implicitHeight: t.lineH + 4
    width: implicitWidth
    height: implicitHeight
    radius: height / 2
    color: kind === "warn" ? Qt.rgba(245 / 255, 165 / 255, 36 / 255, 0.13)
         : kind === "err" ? Qt.rgba(244 / 255, 80 / 255, 94 / 255, 0.14) : Qt.rgba(1, 1, 1, 0.08)
    SText {
        id: t
        x: 8
        y: 2
        size: 10.5
        cssWeight: 500
        wrapMode: Text.NoWrap
        text: tg.text
        color: tg.kind === "warn" ? "#fbc06a" : tg.kind === "err" ? "#ff8d97" : SettingsTheme.dim
    }
}
