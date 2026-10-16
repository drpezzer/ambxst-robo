pragma Singleton

import QtQuick
import Quickshell

// settings.css :root — the Settings window's own palette (not style.css's).
Singleton {
    readonly property color ink: "#f5f6f8"
    readonly property color dim: "#9398a1"
    readonly property color dim2: "#6b7079"
    readonly property color bg: "#0b0c0e"
    readonly property color card: "#141518"
    readonly property color hairline: Qt.rgba(1, 1, 1, 0.07)
    /** A CSS border paints over the element's own background (background-clip:
     *  border-box); a Qt border does not: these are the colours CSS ends up with. */
    readonly property color cardBorder: Qt.tint(card, hairline)
    /** hairline over a rgba(255,255,255,.07) field. */
    readonly property color fieldBorder: Qt.rgba(1, 1, 1, 0.1351)
    readonly property color green: "#22c55e"
    readonly property color red: "#f4505e"
    readonly property color amber: "#f5a524"
    /** CSS `transition: background 0.14s` / `transform 0.08s` / `.switch::after 0.18s` (ease). */
    readonly property var ease: [0.25, 0.1, 0.25, 1, 1, 1]
}
