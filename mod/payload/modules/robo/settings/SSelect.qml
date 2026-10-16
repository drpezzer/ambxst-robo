import QtQuick
import QtQuick.Controls

// settings.css select: 400 12.5px, rgba .07, hairline border, radius 8,
// padding 5 8, Chrome's dark menulist arrow; as wide as its widest option
// (Chrome sizes a <select> that way). The popup is the OS's list upstream
// (`select option`: #1a1c20 / --ink): here a Popup under the field.
Rectangle {
    id: s
    property var options: []          // [{ value, text }]
    property string value: ""
    signal activated(string value)
    function openPopup() { pop.open(); }
    readonly property int index: {
        for (let i = 0; i < options.length; i++) if (options[i].value === value) return i;
        return -1;
    }
    readonly property string shown: index >= 0 ? options[index].text : ""
    implicitWidth: Math.round(widest.implicitWidth + 38.6)
    implicitHeight: 29
    width: implicitWidth
    height: 29
    radius: 8
    color: Qt.rgba(1, 1, 1, 0.07)
    border.width: 1
    border.color: pop.visible ? Qt.rgba(1, 1, 1, 0.3304) : SettingsTheme.fieldBorder
    Column {
        id: widest
        visible: false
        Repeater {
            model: s.options
            SText { required property var modelData; text: modelData.text; size: 12.5; wrapMode: Text.NoWrap }
        }
    }
    SText {
        x: 13
        y: 7
        width: s.width - 38
        text: s.shown
        size: 12.5
        wrapMode: Text.NoWrap
        elide: Text.ElideRight
    }
    // Chrome's chevron (color-scheme: dark).
    Canvas {
        width: 11
        height: 7
        x: s.width - 14.5
        y: 11.5
        onPaint: {
            const c = getContext("2d");
            c.reset();
            c.strokeStyle = "#f5f6f8";
            c.lineWidth = 2;
            c.lineCap = "round";
            c.lineJoin = "round";
            c.beginPath();
            c.moveTo(1.5, 1.5);
            c.lineTo(5.5, 5.5);
            c.lineTo(9.5, 1.5);
            c.stroke();
        }
    }
    MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: pop.visible ? pop.close() : pop.open()
    }
    Popup {
        id: pop
        y: s.height + 2
        width: Math.max(s.width, list.implicitWidth + 2)
        padding: 1
        background: Rectangle { color: "#1a1c20"; radius: 6; border.width: 1; border.color: Qt.rgba(1, 1, 1, 0.12) }
        contentItem: Column {
            id: list
            Repeater {
                model: s.options
                Rectangle {
                    id: opt
                    required property var modelData
                    required property int index
                    width: Math.max(pop.width - 2, ot.implicitWidth + 18)
                    implicitWidth: ot.implicitWidth + 18
                    height: 22
                    color: om.containsMouse ? Qt.rgba(1, 1, 1, 0.12) : opt.index === s.index ? Qt.rgba(1, 1, 1, 0.06) : "transparent"
                    SText { id: ot; x: 9; y: 3.5; text: opt.modelData.text; size: 12.5; wrapMode: Text.NoWrap }
                    MouseArea {
                        id: om
                        anchors.fill: parent
                        hoverEnabled: true
                        onClicked: {
                            pop.close();
                            if (opt.modelData.value !== s.value) s.activated(opt.modelData.value);
                        }
                    }
                }
            }
        }
    }
}
