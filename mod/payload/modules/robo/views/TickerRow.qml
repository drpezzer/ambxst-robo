import QtQuick
import qs.modules.robo as C

// views/ticker.ts makeRow() + place(): one 22 px .ticker-row — tick icon
// (chevron / ✓ crossfade), the shimmering text, its dim copy on top, and the
// +N −M of a diff step right after the file name. Placement comes from
// lib/views/status.ts TickerModel (x, y, scale, opacities), re-read on `frame`.
Item {
    id: r
    property var row: null
    property int frame: 0
    property real rowW: 200
    /** The model's row, copied on every frame (the object itself never changes). */
    readonly property var s: frame >= 0 && row ? ({
        shown: row.shown, diff: !!row.diff, plus: row.plus, minus: row.minus,
        x: row.x, y: row.y, scale: row.scale, opacity: row.opacity,
        chevron: row.chevron, check: row.check, shimmer: row.shimmer, dim: row.dim,
        dimColor: row.dimColor, still: row.still
    }) : null

    width: rowW
    height: 22
    x: s ? s.x : 0
    y: s ? s.y : 0
    scale: s ? s.scale : 1
    opacity: s ? s.opacity : 0
    transformOrigin: Item.Left

    // .tick-icon: 12 wide, colour --dim-2; chevron 9 (stroke 2.4), ✓ 8 (stroke 2.2, #454850).
    C.Icon {
        x: 6 - size / 2
        y: 11 - size / 2
        path: C.Robo.lib.ICONS.chevronRight
        size: 9
        stroke: 2.4
        color: C.RoboTheme.dim2
        opacity: r.s ? r.s.chevron : 0
    }
    C.Icon {
        x: 6 - size / 2
        y: 11 - size / 2
        path: C.Robo.lib.ICONS.check
        size: 8
        stroke: 2.2
        color: "#454850"
        opacity: r.s ? r.s.check : 0
    }

    // Body: flex 1 1 auto; a diff step is 0 1 auto (the name, then the counts).
    readonly property real bodyMax: rowW - 18
    readonly property real bodyW: s && s.diff ? Math.min(measure.implicitWidth, bodyMax - counts.implicitWidth) : bodyMax

    C.CText {
        id: measure
        visible: false
        text: r.s ? r.s.shown : ""
        size: 13; cssWeight: 500
        elide: Text.ElideNone
    }

    // .shimmer: the text filled with a moving gradient (#7c818a → #f2f3f5 40 % →
    // #7c818a 70 %, background-size 260 % of the text, repeating, position
    // 130 % → −130 % in 2.2 s, linear). Drawn without a shader: each character
    // takes the gradient's colour at its centre (the ramps span ~100 px, a
    // character ~7), as styled text.
    FontMetrics { id: fm; font: measure.font }
    readonly property var chars: Array.from(measure.text)
    readonly property var centres: {
        const out = [];
        let acc = "";
        for (const ch of chars) {
            const w = fm.advanceWidth(ch);
            out.push(fm.advanceWidth(acc) + w / 2);
            acc += ch;
        }
        return out;
    }
    function mix(a, b, t) {
        return Qt.rgba(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t, 1);
    }
    readonly property color grey: "#7c818a"
    readonly property color bright: "#f2f3f5"
    function hex2(v) { const h = Math.round(v * 255).toString(16); return h.length < 2 ? "0" + h : h; }
    function shimmerHtml(pos) {
        const W = measure.implicitWidth;
        if (W <= 0) return "";
        const T = W * 2.6;
        const x0 = (W - T) * pos;
        let html = "";
        for (let i = 0; i < chars.length; i++) {
            let u = ((centres[i] - x0) % T + T) % T / T;
            const c = u < 0.4 ? mix(grey, bright, u / 0.4) : u < 0.7 ? mix(bright, grey, (u - 0.4) / 0.3) : grey;
            const ch = chars[i] === "&" ? "&amp;" : chars[i] === "<" ? "&lt;" : chars[i] === ">" ? "&gt;" : chars[i] === " " ? "&nbsp;" : chars[i];
            html += "<font color=\"#" + hex2(c.r) + hex2(c.g) + hex2(c.b) + "\">" + ch + "</font>";
        }
        return html;
    }
    C.CText {
        id: shim
        x: 18
        anchors.verticalCenter: parent.verticalCenter
        size: 13; cssWeight: 500
        elide: Text.ElideNone
        textFormat: Text.StyledText
        property real pos: 1.3
        text: visible ? r.shimmerHtml(pos) : ""
        opacity: r.s ? r.s.shimmer : 0
        visible: opacity > 0
        // Port (performance): stepped ~30 times a second, not every vsync
        // (each step rebuilds the styled text; at 165 Hz the notch's
        // screen-sized surface redrew for it the whole time it showed).
        C.AnimClock {
            id: shimClock
            running: shim.visible && !(r.s && r.s.still)
            onTick: ms => shim.pos = 1.3 - 2.6 * ((ms - shimClock.startMs) % 2200) / 2200
        }
    }

    // The dim copy (position:absolute; top 0; left 0; right 0), ellipsised.
    C.CText {
        x: 18
        width: r.bodyW
        anchors.verticalCenter: parent.verticalCenter
        text: measure.text
        size: 13; cssWeight: 500
        color: r.s ? r.s.dimColor : C.RoboTheme.dim3
        opacity: r.s ? r.s.dim : 0
    }

    // .tick-count: 500 10px mono, white-space pre, right after the name.
    Row {
        id: counts
        visible: r.s ? r.s.diff : false
        x: 18 + r.bodyW
        anchors.verticalCenter: parent.verticalCenter
        C.CText {
            text: r.s ? r.s.plus : ""
            size: 10; cssWeight: 500
            font.family: C.RoboTheme.mono
            color: C.RoboTheme.green
            elide: Text.ElideNone
        }
        C.CText {
            text: r.s ? r.s.minus : ""
            size: 10; cssWeight: 500
            font.family: C.RoboTheme.mono
            color: C.RoboTheme.red
            elide: Text.ElideNone
        }
    }
}
