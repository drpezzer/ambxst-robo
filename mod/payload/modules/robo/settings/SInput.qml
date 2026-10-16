import QtQuick
import qs.modules.robo as C

// settings.css input[type=text|password|number]: 400 12.5px, rgba .07, hairline
// border, radius 8, padding 5 8; focus border rgba .28; placeholder --dim-2.
// As a flex item: basis 213 (Chrome's default <input> width at this font),
// flex 1 1 auto, min-width 0 — unless `fixedWidth` (the auto-close field).
Rectangle {
    id: f
    property alias text: ti.text
    property string placeholder: ""
    property bool secret: false
    property real fixedWidth: 0
    readonly property alias field: ti
    signal edited()
    signal committed()
    readonly property real flexBasis: fixedWidth > 0 ? fixedWidth : 213
    readonly property real flexGrow: fixedWidth > 0 ? 0 : 1
    readonly property real flexShrink: fixedWidth > 0 ? 0 : 1
    implicitWidth: flexBasis
    implicitHeight: 27
    height: 27
    radius: 8
    color: Qt.rgba(1, 1, 1, 0.07)
    border.width: 1
    border.color: ti.activeFocus ? Qt.rgba(1, 1, 1, 0.3304) : SettingsTheme.fieldBorder
    SText {
        x: 9
        y: 6
        width: f.width - 18
        visible: ti.text === ""
        text: f.placeholder
        size: 12.5
        color: SettingsTheme.dim2
        wrapMode: Text.NoWrap
        elide: Text.ElideRight
    }
    TextInput {
        id: ti
        x: 9
        y: 6
        width: (f.width - 18) * 2
        height: 30
        transform: Scale { xScale: 0.5; yScale: 0.5 }
        clip: true
        color: SettingsTheme.ink
        selectionColor: Qt.rgba(1, 1, 1, 0.28)
        font.family: C.RoboTheme.font
        font.pixelSize: 25
        renderType: Text.NativeRendering
        echoMode: f.secret ? TextInput.Password : TextInput.Normal
        passwordCharacter: "•"
        selectByMouse: true
        onTextEdited: f.edited()
        onEditingFinished: f.committed()
        Keys.onReturnPressed: event => { f.committed(); event.accepted = false; }
    }
    MouseArea {
        anchors.fill: parent
        cursorShape: Qt.IBeamCursor
        acceptedButtons: Qt.NoButton
    }
}
