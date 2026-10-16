import QtQuick

// colors.ts colorDot — the pill's colour dot (`.dot.color-dot`, looks like a
// status dot), clickable: opens the page's palette under it. Enter/Space too.
Rectangle {
    id: dot
    property var page
    property string pillId: ""
    property string pillName: ""
    property string catalog: "#ffffff"
    property real size: 8
    readonly property string current: page && page.rev >= 0 ? page.xL.currentColor(pillId, catalog, page.settings.pillColors) : catalog
    implicitWidth: size
    implicitHeight: size
    width: size
    height: size
    radius: size / 2
    color: current
    activeFocusOnTab: true
    Accessible.role: Accessible.Button
    Accessible.name: pillName + " · " + (page ? page.xL.PILLS_TEXT.color : "Color")
    Rectangle {
        anchors.centerIn: parent
        width: parent.width + 8
        height: parent.height + 8
        radius: width / 2
        color: "transparent"
        border.width: 2
        border.color: Qt.rgba(1, 1, 1, 0.5)
        visible: dot.activeFocus
    }
    MouseArea {
        anchors.fill: parent
        anchors.margins: -2
        cursorShape: Qt.PointingHandCursor
        onClicked: dot.page.togglePalette(dot)
    }
    Keys.onPressed: event => {
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
            event.accepted = true;
            dot.page.openPalette(dot);
        }
    }
}
