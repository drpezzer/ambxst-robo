import QtQuick
import qs.modules.robo as C

// settings.css text: `size` in CSS px, CSS weight, `lh` = CSS line-height
// (0 = normal, as every `font:` shorthand in settings.css resets it). Lines
// are laid out at Chrome's pixel heights (ascent and descent rounded apart).
// Qt rounds a font's pixel size to an integer, so a fractional CSS size
// (12.5px, 11.5px, 10.5px) is drawn at twice the size and scaled by ½: the
// advances then match Chrome's to the pixel (a 50-character path at 11.5px is
// 345 px in both, against 330 at Qt's rounded 11px).
Item {
    id: st
    property string text: ""
    property real size: 13
    property int cssWeight: 400
    property real lh: 0
    property bool mono: false
    property color color: SettingsTheme.ink
    property int wrapMode: Text.Wrap
    property int elide: Text.ElideNone
    property real letterSpacing: 0
    /** white-space: pre (diffs). Otherwise runs of white space collapse as in CSS. */
    property bool pre: false
    /** CSS line-height: normal (ascent + descent, each rounded, as Chrome). */
    readonly property real normalH: mono ? Math.round(size * 1.069) + Math.round(size * 0.293)
                                         : Math.round(size * 0.969) + Math.round(size * 0.242)
    readonly property real lineH: lh > 0 ? size * lh : normalH
    /** ½ for a fractional size, else 1. */
    readonly property real k: Math.round(size) === size ? 1 : 0.5
    readonly property int lineCount: t.lineCount
    implicitWidth: t.implicitWidth * k
    implicitHeight: t.text === "" ? 0 : t.lineCount * lineH
    baselineOffset: t.baselineOffset * k
    height: implicitHeight
    Text {
        id: t
        width: st.width / st.k
        // Chrome puts half the leading above the text (Qt puts it all below).
        y: (st.lineH - st.normalH) / 2
        text: st.pre ? st.text : st.text.replace(/[ \t\n\r]+/g, " ")
        color: st.color
        font.family: st.mono ? C.RoboTheme.mono : C.RoboTheme.font
        font.pixelSize: Math.round(st.size / st.k)
        font.weight: C.RoboTheme.weight(st.cssWeight)
        font.letterSpacing: st.letterSpacing / st.k
        renderType: Text.NativeRendering
        textFormat: Text.PlainText
        wrapMode: st.wrapMode
        elide: st.elide
        lineHeightMode: Text.FixedHeight
        lineHeight: st.lineH / st.k
        transform: Scale { xScale: st.k; yScale: st.k }
    }
}
