import QtQuick

// settings.css section: --card, hairline border, radius 14, padding 16 18,
// column gap 12; `section > h2`: 600 13px, dot gap 8.
Rectangle {
    id: sec
    property string title: ""
    /** null = no dot in the heading; true/false = parts.ts statusDot. */
    property var dot: null
    default property alias content: body.data
    readonly property real innerWidth: width - 38
    implicitHeight: body.implicitHeight + 34
    radius: 14
    color: SettingsTheme.card
    border.width: 1
    border.color: SettingsTheme.cardBorder
    Column {
        id: body
        x: 19
        y: 17
        width: sec.width - 38
        spacing: 12
        Row {
            spacing: 8
            height: 16
            SDot {
                visible: sec.dot !== null
                ok: sec.dot === true
                anchors.verticalCenter: parent.verticalCenter
            }
            SText { text: sec.title; size: 13; cssWeight: 600; wrapMode: Text.NoWrap }
        }
    }
}
