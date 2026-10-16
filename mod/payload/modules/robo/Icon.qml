import QtQuick
import QtQuick.Shapes

// views/dom.ts svg(): a 24×24 path drawn at `size`, filled, or stroked when
// `stroke` > 0 (round caps and joins), in `color` (CSS currentColor).
Item {
    id: root
    property string path: ""
    property real size: 14
    property real stroke: 0
    property bool evenOdd: false
    property color color: RoboTheme.ink
    width: size
    height: size

    Shape {
        width: 24
        height: 24
        scale: root.size / 24
        transformOrigin: Item.TopLeft
        preferredRendererType: Shape.CurveRenderer
        ShapePath {
            fillColor: root.stroke > 0 ? "transparent" : root.color
            fillRule: root.evenOdd ? ShapePath.OddEvenFill : ShapePath.WindingFill
            strokeColor: root.stroke > 0 ? root.color : "transparent"
            strokeWidth: root.stroke > 0 ? root.stroke : 0
            capStyle: ShapePath.RoundCap
            joinStyle: ShapePath.RoundJoin
            PathSvg { path: root.path }
        }
    }
}
