import QtQuick

// settings.css `.row > label` — min-width 132, --dim, 12.5px (line-height 1.45).
SText {
    property real minW: 132
    size: 12.5
    lh: 1.45
    color: SettingsTheme.dim
    wrapMode: Text.NoWrap
    // A flex item: never narrower than min-width.
    readonly property real flexBasis: Math.max(minW, implicitWidth)
}
