import QtQuick

// colors.ts palette + settings.css .palette: fixed under the dot (left =
// dot.left − 10, kept 8 px inside the window), card, hairline, radius 12,
// padding 8 10, gap 7, shadow 0 8 24 rgba(0,0,0,.45); 18 px swatches, the
// current one ringed (0 0 0 2px card, 0 0 0 3.5px ink); "Default" once changed.
// Closes on a press outside, Escape, or a resize.
Item {
    id: p
    property var page
    property var dot: null
    readonly property bool open: dot !== null
    anchors.fill: parent
    visible: open
    z: 10

    readonly property var pal: open && page.rev >= 0 ? page.xL.paletteFor(dot.pillId, dot.catalog, page.settings.pillColors) : null

    function show(d) {
        dot = d;
        place();
        Qt.callLater(() => { if (box.children.length) focusFirst(); });
    }
    /** `refocus`: Escape and a pick give the focus back to the dot (colors.ts). */
    function close(refocus) { if (dot) { const d = dot; dot = null; if (refocus) d.forceActiveFocus(); } }
    function place() {
        if (!dot) return;
        const at = dot.mapToItem(p, 0, 0);
        box.x = Math.max(8, Math.min(at.x - 10, p.width - box.width - 8));
        box.y = at.y + dot.height + 8;
    }
    function focusFirst() { p.forceActiveFocus(); }
    function choose(hex) {
        page.pickColor(page.xL.pickColor(page.settings.pillColors, dot.pillId, hex, dot.catalog));
        close(true);
    }
    onWidthChanged: close()
    onHeightChanged: close()

    // A press anywhere else closes it, and still reaches what was pressed.
    MouseArea {
        anchors.fill: parent
        enabled: p.open
        onPressed: mouse => {
            const inBox = mouse.x >= box.x && mouse.x < box.x + box.width && mouse.y >= box.y && mouse.y < box.y + box.height;
            if (!inBox) {
                const at = p.dot ? p.dot.mapToItem(p, 0, 0) : null;
                const onDot = at && mouse.x >= at.x - 2 && mouse.x < at.x + p.dot.width + 2 && mouse.y >= at.y - 2 && mouse.y < at.y + p.dot.height + 2;
                if (!onDot) p.close();
            }
            mouse.accepted = false;
        }
    }
    Keys.onEscapePressed: p.close(true)

    // Shadow, then the box.
    Rectangle {
        x: box.x - 6; y: box.y + 2; width: box.width + 12; height: box.height + 12
        radius: 16
        color: Qt.rgba(0, 0, 0, 0.18)
        visible: p.open
    }
    Rectangle {
        id: box
        width: row.implicitWidth + 20
        height: row.implicitHeight + 16
        radius: 12
        color: SettingsTheme.card
        border.width: 1
        border.color: SettingsTheme.cardBorder
        Row {
            id: row
            x: 10
            y: 8
            spacing: 7
            Repeater {
                model: p.pal ? p.pal.swatches : []
                Item {
                    required property var modelData
                    width: 18
                    height: 18
                    anchors.verticalCenter: parent.verticalCenter
                    Rectangle {
                        anchors.centerIn: parent
                        width: 25; height: 25; radius: 12.5
                        color: SettingsTheme.ink
                        visible: modelData.on
                        Rectangle { anchors.centerIn: parent; width: 22; height: 22; radius: 11; color: SettingsTheme.card }
                    }
                    Rectangle {
                        anchors.fill: parent
                        radius: 9
                        color: modelData.hex
                        scale: sm.pressed ? 0.96 : 1
                    }
                    MouseArea { id: sm; anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: p.choose(modelData.hex) }
                }
            }
            // `.palette .reset`: a button, padding 3 10, 11.5px.
            Rectangle {
                visible: p.pal ? p.pal.reset : false
                anchors.verticalCenter: parent.verticalCenter
                width: rt.implicitWidth + 20
                height: rt.lineH + 6
                radius: height / 2
                color: rm.containsMouse ? Qt.rgba(1, 1, 1, 0.15) : Qt.rgba(1, 1, 1, 0.09)
                SText { id: rt; x: 10; y: 3; size: 11.5; cssWeight: 500; wrapMode: Text.NoWrap; text: p.page ? p.page.xL.PILLS_TEXT.reset : "" }
                MouseArea { id: rm; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: p.choose(null) }
            }
        }
    }
}
