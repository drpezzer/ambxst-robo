import QtQuick
import qs.modules.robo as C

// views/views.ts buildPlaceholder(title, sub): a plain card, a .stack
// (padding 0 18 0 118, centred column, gap 5) with .title (600 15px) and an
// empty .sub (400 13px dim) — an empty div has no height, the gap still counts.
Card {
    id: ph
    property string title: ""
    property string sub: ""
    // Arabic: upstream's `html[data-dir=rtl] .stack { direction: rtl }` — the
    // stack's box keeps its physical padding, its contents read right to left.
    readonly property bool rtl: C.Robo.rev >= 0 && C.Robo.lib.I18n.isRtl()
    /** direction: rtl sets the paragraph direction (an RLM as the first strong character). */
    function bidi(s) { return rtl && s ? "\u200F" + s : s; }
    Column {
        x: 1 + 118
        width: parent.width - 2 - 118 - 18
        anchors.verticalCenter: parent.verticalCenter
        spacing: 5
        // Positioners skip a 0-high item (and its gap): the empty .sub's gap kept here.
        bottomPadding: ph.sub === "" ? 5 : 0
        C.CText { width: parent.width; text: ph.bidi(ph.title); size: 15; cssWeight: 600; wrapMode: Text.Wrap; maximumLineCount: 99; elide: Text.ElideNone }
        C.CText {
            width: parent.width
            height: ph.sub === "" ? 0 : implicitHeight
            text: ph.bidi(ph.sub)
            size: 13
            color: C.RoboTheme.dim
            wrapMode: Text.Wrap; maximumLineCount: 99; elide: Text.ElideNone
        }
    }
}
