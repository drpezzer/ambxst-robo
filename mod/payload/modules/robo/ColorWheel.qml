import QtQuick
import qs.modules.robo as C

// Port only (his ask): the colour wheel behind a custom swatch: a hue ring
// (drag or click on it; the colour keeps its saturation and lightness, a
// grey taking a lively one) with the colour in its middle, and a field for
// typing a hex value. A card of its own, closed by a press outside, Escape
// or Enter in the field.
Rectangle {
    id: wheel
    /** The colour edited ("#rrggbb"). */
    property string value: "#d97757"
    signal picked(string color)
    signal closed()
    /** Side by side (the ring, the field at its right): for short places (the wardrobe). */
    property bool wide: false
    width: wide ? ring.width + 20 + 92 : Math.max(ring.width + 20, 116)
    height: wide ? ring.height + 16 : ring.y + ring.height + 48
    radius: 14
    color: "#1b1c20"
    border.width: 1
    border.color: Qt.rgba(1, 1, 1, 0.12)

    property real ringOuter: 42
    readonly property real ringInner: ringOuter - 13

    function hslOf(hex) {
        const c = Qt.color(hex);
        return { h: Math.max(0, c.hslHue), s: c.hslSaturation, l: c.hslLightness };
    }
    function hex(c) {
        const h2 = v => { const s = Math.round(v * 255).toString(16); return s.length < 2 ? "0" + s : s; };
        return "#" + h2(c.r) + h2(c.g) + h2(c.b);
    }
    function pickAt(x, y) {
        const dx = x - ring.width / 2, dy = y - ring.height / 2;
        let a = Math.atan2(dy, dx) / (Math.PI * 2);
        // The conical gradient runs counter-clockwise from 3 o'clock.
        const hue = ((-a) % 1 + 1) % 1;
        const cur = hslOf(wheel.value);
        const s = cur.s < 0.15 ? 0.65 : cur.s;
        const l = cur.l < 0.15 || cur.l > 0.9 ? 0.55 : cur.l;
        wheel.picked(hex(Qt.hsla(hue, s, l, 1)));
    }

    Keys.onEscapePressed: wheel.closed()

    Canvas {
        id: ring
        x: wheel.wide ? 10 : (parent.width - width) / 2
        y: wheel.wide ? 8 : 10
        width: wheel.ringOuter * 2 + 4
        height: width
        onPaint: {
            const ctx = getContext("2d");
            ctx.reset();
            const cx = width / 2, cy = height / 2;
            const g = ctx.createConicalGradient(cx, cy, 0);
            for (let i = 0; i <= 12; i++) g.addColorStop(i / 12, Qt.hsla(i / 12, 0.85, 0.58, 1));
            ctx.fillStyle = g;
            ctx.beginPath();
            ctx.arc(cx, cy, wheel.ringOuter, 0, Math.PI * 2, false);
            ctx.arc(cx, cy, wheel.ringInner, 0, Math.PI * 2, true);
            ctx.fill();
        }
        // The colour now, in the middle.
        Rectangle {
            anchors.centerIn: parent
            width: wheel.ringInner * 2 - 14; height: width; radius: width / 2
            color: wheel.value
            border.width: 1
            border.color: Qt.rgba(1, 1, 1, 0.2)
        }
        // Where its hue sits on the ring.
        Rectangle {
            readonly property real hue: wheel.hslOf(wheel.value).h
            readonly property real r: (wheel.ringOuter + wheel.ringInner) / 2
            width: 12; height: 12; radius: 6
            x: ring.width / 2 + Math.cos(-hue * Math.PI * 2) * r - 6
            y: ring.height / 2 + Math.sin(-hue * Math.PI * 2) * r - 6
            color: "transparent"
            border.width: 2
            border.color: "white"
        }
        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            function inRing(m) {
                const d = Math.hypot(m.x - ring.width / 2, m.y - ring.height / 2);
                return d >= wheel.ringInner - 6 && d <= wheel.ringOuter + 6;
            }
            property bool dragging: false
            onPressed: m => { dragging = inRing(m); if (dragging) wheel.pickAt(m.x, m.y); }
            onPositionChanged: m => { if (dragging) wheel.pickAt(m.x, m.y); }
            onReleased: dragging = false
        }
    }

    // The hex field.
    Rectangle {
        x: wheel.wide ? ring.x + ring.width + 10 : 12
        y: wheel.wide ? (wheel.height - height) / 2 : ring.y + ring.height + 10
        width: wheel.wide ? 82 : parent.width - 24
        height: 28
        radius: 8
        color: Qt.rgba(1, 1, 1, 0.07)
        border.width: hexField.activeFocus ? 1 : 0
        border.color: Qt.rgba(1, 1, 1, 0.3)
        C.CText {
            x: 9
            anchors.verticalCenter: parent.verticalCenter
            text: "#"
            size: 12
            color: C.RoboTheme.dim3
        }
        TextInput {
            id: hexField
            x: 20
            width: parent.width - 28
            anchors.verticalCenter: parent.verticalCenter
            color: C.RoboTheme.ink
            font.family: C.RoboTheme.font
            font.pointSize: C.RoboTheme.px(12)
            selectByMouse: true
            maximumLength: 6
            validator: RegularExpressionValidator { regularExpression: /[0-9a-fA-F]{0,6}/ }
            text: wheel.value.replace("#", "")
            // Every complete value applies at once.
            onTextEdited: if (/^[0-9a-fA-F]{6}$/.test(text)) wheel.picked("#" + text.toLowerCase())
            Keys.onReturnPressed: wheel.closed()
            Keys.onEnterPressed: wheel.closed()
            Keys.onEscapePressed: wheel.closed()
            // (Kept in step with picks from the ring while not typed in.)
            Connections {
                target: wheel
                function onValueChanged() { if (!hexField.activeFocus) hexField.text = wheel.value.replace("#", ""); }
            }
        }
    }
}
