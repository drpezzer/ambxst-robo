import QtQuick
import qs.modules.robo as C

// style.css .card (+ .card.wash::after): radius 20, var(--card), 1px hairline,
// optional radial wash `radial-gradient(280px 280px at 50% 130%, wash 0%, transparent 70%)`.
Rectangle {
    id: card
    property string wash: ""
    radius: 20
    color: C.RoboTheme.card
    border.width: 1
    // CSS paints the border over the card's own background.
    border.color: Qt.tint(C.RoboTheme.card, C.RoboTheme.hairline)
    clip: true

    // Port (his ask): a wash may be a colour ("#rrggbb", a chat's, at the
    // indigo wash's 0.5); a change of wash flows over 300 ms.
    readonly property color washTarget: {
        if (!card.wash) return "transparent";
        if (card.wash.charAt(0) === "#") { const c = Qt.color(card.wash); return Qt.rgba(c.r, c.g, c.b, 0.5); }
        return C.RoboTheme.css(C.Robo.lib.Layout.washRGBA(card.wash));
    }
    property color washNow: washTarget
    Behavior on washNow { ColorAnimation { duration: 300; easing.type: Easing.BezierSpline; easing.bezierCurve: C.RoboTheme.ease } }

    Canvas {
        anchors.fill: parent
        visible: card.wash !== ""
        property color w: card.washNow
        onWChanged: requestPaint()
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
        onPaint: {
            const ctx = getContext("2d");
            ctx.reset();
            if (!card.wash) return;
            const col = w;
            const cx = width / 2, cy = height * 1.3;
            // An ellipse 280×280 radius: a circle of radius 280, colour to 70 %.
            const g = ctx.createRadialGradient(cx, cy, 0, cx, cy, 280);
            g.addColorStop(0, col);
            g.addColorStop(0.7, Qt.rgba(col.r, col.g, col.b, 0));
            g.addColorStop(1, Qt.rgba(col.r, col.g, col.b, 0));
            ctx.fillStyle = g;
            ctx.fillRect(0, 0, width, height);
        }
    }
}
