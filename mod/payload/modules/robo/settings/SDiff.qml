import QtQuick
import qs.modules.robo as C

// settings.css .diff + parts.ts renderDiff: 400 11.5px/1.5 mono, #08090b,
// hairline border, radius 10, padding 10 12, max-height 260, scrolls both
// ways, white-space: pre; + lines #86efac, - lines #ff8d97, others --dim-2.
Rectangle {
    id: d
    property var lines: []
    implicitHeight: Math.min(260, col.implicitHeight + 22)
    implicitWidth: 100
    radius: 10
    color: "#08090b"
    border.width: 1
    border.color: Qt.tint("#08090b", SettingsTheme.hairline)
    clip: true
    // overflow: auto clips at the padding box (inside the border): the
    // padding scrolls with the lines.
    Flickable {
        id: fl
        x: 1
        y: 1
        width: d.width - 2
        height: d.height - 2
        contentWidth: col.implicitWidth + 24
        contentHeight: col.implicitHeight + 20
        boundsBehavior: Flickable.StopAtBounds
        clip: true
        Column {
            id: col
            x: 12
            y: 10
            Repeater {
                model: d.lines
                SText {
                    required property var modelData
                    text: modelData.text
                    size: 11.5
                    lh: 1.5
                    mono: true
                    pre: true
                    wrapMode: Text.NoWrap
                    color: modelData.cls === "add" ? "#86efac" : modelData.cls === "del" ? "#ff8d97" : SettingsTheme.dim2
                }
            }
        }
    }
}
