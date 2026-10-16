import QtQuick

// A `.row > label` holding an accent dot (`i.dot`, inline-block, margin-right
// 8, sitting on the text's baseline) and a name — chat providers and local
// models (main.ts:576-579, 645-648).
Item {
    id: al
    property color accent: "white"
    property string text: ""
    readonly property real flexBasis: Math.max(132, 16 + nm.implicitWidth)
    implicitWidth: flexBasis
    implicitHeight: nm.lineH
    Rectangle {
        id: adot
        anchors.left: parent.left
        width: 8
        height: 8
        radius: 4
        color: al.accent
        y: Math.round(nm.baselineOffset) - 8
    }
    SText {
        id: nm
        anchors.left: adot.right
        anchors.leftMargin: 8
        text: al.text
        size: 12.5
        lh: 1.45
        color: SettingsTheme.dim
        wrapMode: Text.NoWrap
    }
}
