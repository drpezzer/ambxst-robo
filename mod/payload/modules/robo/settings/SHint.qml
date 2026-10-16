import QtQuick

// settings.css .hint — 400 12px, --dim (`.hint.full` → amber).
SText {
    property bool full: false
    size: 12
    color: full ? SettingsTheme.amber : SettingsTheme.dim
}
