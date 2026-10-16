import QtQuick

// settings.css .dot — 8 px status dot (parts.ts statusDot: green ok / red missing).
Rectangle {
    property bool ok: false
    property color dotColor: ok ? SettingsTheme.green : SettingsTheme.red
    implicitWidth: 8
    implicitHeight: 8
    width: implicitWidth
    height: implicitHeight
    radius: width / 2
    color: dotColor
}
