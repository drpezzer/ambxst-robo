import QtQuick

// settings.css .notice (.ok / .err / .warn) — 12px, radius 10, padding 8 12.
Rectangle {
    id: n
    property string kind: ""
    property string text: ""
    implicitWidth: t.implicitWidth + 24
    implicitHeight: t.height + 16
    radius: 10
    color: kind === "ok" ? Qt.rgba(34 / 255, 197 / 255, 94 / 255, 0.12)
         : kind === "err" ? Qt.rgba(244 / 255, 80 / 255, 94 / 255, 0.14)
         : kind === "warn" ? Qt.rgba(245 / 255, 165 / 255, 36 / 255, 0.13) : "transparent"
    SText {
        id: t
        x: 12
        y: 8
        width: n.width - 24
        size: 12
        text: n.text
        color: n.kind === "ok" ? "#86efac" : n.kind === "err" ? "#ff8d97" : n.kind === "warn" ? "#fbc06a" : SettingsTheme.ink
    }
}
