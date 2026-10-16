import QtQuick

// A text node styled the CSS way: size in CSS px, CSS weight.
Text {
    property real size: 12
    property int cssWeight: 400
    color: RoboTheme.ink
    font.family: RoboTheme.font
    font.pointSize: RoboTheme.px(size)
    font.weight: RoboTheme.weight(cssWeight)
    // Qt draws text at whole pixel sizes (12.5 → 13); tightening each letter
    // by the difference brings line widths back to the CSS size (±0.4 px).
    font.letterSpacing: (size - Math.round(size)) * 0.55
    renderType: Text.NativeRendering
    elide: Text.ElideRight
    maximumLineCount: 1
    textFormat: Text.PlainText
}
