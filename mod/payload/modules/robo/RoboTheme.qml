pragma Singleton

import QtQuick
import Quickshell

// windows/src/style.css :root, verbatim. `px(n)` turns a CSS pixel font size
// into the point size Qt needs for the same pixels (CSS allows fractions).
Singleton {
    readonly property string font: "Adwaita Sans"
    readonly property string mono: "monospace"

    readonly property color ink: "#f5f6f8"
    readonly property color ink2: "#f1f2f4"
    readonly property color dim: "#9398a1"
    readonly property color dim2: "#8e939c"
    readonly property color dim3: "#6b7079"
    readonly property color dim4: "#5f646d"
    readonly property color dim5: "#4b5563"
    readonly property color card: "#141518"
    readonly property color cardFlat: "#0e0f11"
    readonly property color tabOn: "#1d1f23"
    readonly property color hairline: Qt.rgba(1, 1, 1, 0.035)
    readonly property color red: "#f4505e"
    readonly property color redText: "#ff8d97"
    readonly property color green: "#22c55e"
    readonly property color green2: "#34d399"
    readonly property color amber: "#f5a524"
    readonly property color cyan: "#22d3ee"
    readonly property color indigo: "#6366f1"
    readonly property color pink: "#f472b6"

    // CSS's named timing functions, exactly (Qt's Quad/Cubic curves are not them).
    readonly property var ease: [0.25, 0.1, 0.25, 1, 1, 1]
    readonly property var easeIn: [0.42, 0, 1, 1, 1, 1]
    readonly property var easeOut: [0, 0, 0.58, 1, 1, 1]
    readonly property var easeInOut: [0.42, 0, 0.58, 1, 1, 1]
    /** CSS cubic-bezier(x1, y1, x2, y2) at progress x (0..1): for loops a timer drives. */
    function cubicBezier(x1, y1, x2, y2, x) {
        if (x <= 0) return 0;
        if (x >= 1) return 1;
        const bx = t => ((1 - 3 * x2 + 3 * x1) * t + (3 * x2 - 6 * x1)) * t * t + 3 * x1 * t;
        const by = t => ((1 - 3 * y2 + 3 * y1) * t + (3 * y2 - 6 * y1)) * t * t + 3 * y1 * t;
        let lo = 0, hi = 1, t = x;
        for (let i = 0; i < 20; i++) {
            const v = bx(t);
            if (Math.abs(v - x) < 1e-4) break;
            if (v < x) lo = t; else hi = t;
            t = (lo + hi) / 2;
        }
        return by(t);
    }
    /** ease-in-out (0.42, 0, 0.58, 1). */
    function easeInOutAt(x) { return cubicBezier(0.42, 0, 0.58, 1, x); }

    function px(n) { return n * 0.75; }
    // CSS weights → Qt.
    function weight(w) {
        return w >= 700 ? Font.Bold : w >= 600 ? Font.DemiBold : w >= 500 ? Font.Medium : Font.Normal;
    }
    /** "rgba(r,g,b,a)" / "#hex" strings from upstream code → color. */
    function css(c) {
        if (!c) return "transparent";
        const m = /^rgba?\(([^)]+)\)$/.exec(String(c).trim());
        if (!m) return c;
        const p = m[1].split(",").map(s => parseFloat(s));
        return Qt.rgba(p[0] / 255, p[1] / 255, p[2] / 255, p.length > 3 ? p[3] : 1);
    }
}
