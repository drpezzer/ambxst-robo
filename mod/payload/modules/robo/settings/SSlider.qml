import QtQuick

// settings.css input[type=range]: 140×4 track rgba .2 radius 2, 13 px white
// thumb; `moved(value)` on every change like the `input` event.
Item {
    id: s
    property real from: 0
    property real to: 1
    property real step: 0.01
    property real value: 0
    signal moved(real value)
    implicitWidth: 140
    implicitHeight: 4
    width: 140
    height: 4
    Rectangle { anchors.fill: parent; radius: 2; color: Qt.rgba(1, 1, 1, 0.2) }
    Rectangle {
        width: 13
        height: 13
        radius: 6.5
        color: "#ffffff"
        x: (s.to > s.from ? (s.value - s.from) / (s.to - s.from) : 0) * (s.width - 13)
        y: (s.height - 13) / 2
    }
    MouseArea {
        anchors.fill: parent
        anchors.topMargin: -6
        anchors.bottomMargin: -6
        function set(mx) {
            const f = Math.max(0, Math.min(1, (mx - 6.5) / (s.width - 13)));
            let v = s.from + f * (s.to - s.from);
            v = Math.round(v / s.step) * s.step;
            v = Math.max(s.from, Math.min(s.to, Number(v.toFixed(6))));
            if (v !== s.value) s.moved(v);
        }
        onPressed: mouse => set(mouse.x)
        onPositionChanged: mouse => { if (pressed) set(mouse.x); }
    }
}
