import QtQuick
import QtQuick.Effects
import qs.modules.robo as C

// views/views.ts buildPill(): a 28 px pill with a mini mascot (24) and the
// label; hover tints it in the task's colour; badge in the corner.
Item {
    id: p
    property var task: null
    readonly property var icons: C.Robo.lib.ICONS
    // Port (his ask): a chat's pill glows in its chat's colour (lib/looks.ts).
    readonly property string color: {
        void C.Robo.rev;
        if (!task) return "#ffffff";
        const c = C.Robo.lib.Looks.convOfTask(task);
        return c ? C.Robo.lib.Looks.chatColor(c, task.color) : task.color;
    }
    readonly property bool hovered: ma.containsMouse
    /** Port (his ask: multitasking): a chat conversation's pill (chat.ts convPillId). */
    readonly property string conv: C.Robo.rev >= 0 && task && task.conv ? task.conv : ""
    height: 28
    // Carried away (views/ConvDrag.qml): its place stays, empty.
    opacity: conv !== "" && C.Robo.dragConv === conv ? 0 : 1
    scale: hovered ? 1.04 : 1
    Behavior on scale { NumberAnimation { duration: 200; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.3, 1.2, 0.4, 1, 1, 1] } }

    function hexA(hex, a) { const c = Qt.color(hex); return Qt.rgba(c.r, c.g, c.b, a); }
    function lighten(hex, amount) {
        const c = Qt.color(hex);
        return Qt.rgba(Math.min(1, c.r + amount), Math.min(1, c.g + amount), Math.min(1, c.b + amount), 1);
    }

    // box-shadow 0 2px 10px color/0.35 on hover.
    Rectangle {
        id: shadowSrc
        anchors.fill: bg
        radius: bg.radius
        color: p.hexA(p.color, 0.35)
        visible: false
    }
    MultiEffect {
        source: shadowSrc
        anchors.fill: bg
        anchors.topMargin: 2
        anchors.bottomMargin: -2
        blurEnabled: true
        blur: 0.6
        blurMax: 20
        opacity: p.hovered ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 180; easing.type: Easing.BezierSpline; easing.bezierCurve: C.RoboTheme.ease } }
    }
    Rectangle {
        id: bg
        anchors.fill: parent
        radius: height / 2
        color: p.hovered ? Qt.lighter(p.hexA(p.color, 0x2e / 255), 1.06) : C.RoboTheme.cardFlat
        border.width: 1
        border.color: p.hovered ? p.hexA(p.color, 0x8c / 255) : p.hexA(p.color, 0x24 / 255)
        Behavior on color { ColorAnimation { duration: 180; easing.type: Easing.BezierSpline; easing.bezierCurve: C.RoboTheme.ease } }
        Behavior on border.color { ColorAnimation { duration: 180; easing.type: Easing.BezierSpline; easing.bezierCurve: C.RoboTheme.ease } }
    }
    C.MiniBot {
        x: 7
        anchors.verticalCenter: parent.verticalCenter
        task: p.task
        bodySize: 24
    }
    C.CText {
        anchors.left: parent.left
        anchors.right: parent.right
        // Port: a helper's name is its task, usually long: it starts right of
        // the mini instead of running over it.
        // Port: a conversation's title is long too.
        anchors.leftMargin: C.Robo.rev >= 0 && p.task && (p.task.helperOf || p.conv) ? 7 + 24 + 10 : 6
        anchors.rightMargin: 6
        anchors.verticalCenter: parent.verticalCenter
        horizontalAlignment: Text.AlignHCenter
        // .lbl: white-space nowrap, text-overflow ellipsis.
        elide: Text.ElideRight
        text: p.task ? p.task.name : ""
        size: 10
        cssWeight: 600
        color: p.hovered ? p.lighten(p.color, 0.3) : C.RoboTheme.dim3
    }
    // .pill-badge glow: box-shadow 0 0 4px <badge colour, alpha 0x99>.
    RectangularShadow {
        visible: badge.visible
        anchors.fill: badge
        radius: 7
        blur: 4
        spread: 0
        color: Qt.rgba(Qt.color(badge.badgeColor).r, Qt.color(badge.badgeColor).g, Qt.color(badge.badgeColor).b, 0x99 / 255)
    }
    // .pill-badge
    Rectangle {
        id: badge
        visible: p.task && !!p.task.pillBadge
        readonly property string kind: p.task && p.task.pillBadge ? p.task.pillBadge : ""
        readonly property string badgeColor: ({ approval: "#F5A524", finished: "#22C55E", error: "#F4505E" })[kind] || "#000"
        x: parent.width - 3 - width
        y: -3
        width: 14; height: 14; radius: 7
        color: "#0b0c0e"
        Rectangle {
            anchors.centerIn: parent
            width: 12; height: 12; radius: 6
            color: parent.badgeColor
            C.Icon {
                anchors.centerIn: parent
                size: 6
                color: "#000"
                path: ({ approval: p.icons.bang, finished: p.icons.check, error: p.icons.xmark })[parent.parent.kind] || ""
                stroke: parent.parent.kind === "finished" ? 3 : 0
            }
        }
    }
    MouseArea {
        id: ma
        anchors.fill: parent
        hoverEnabled: true
        // Port: a conversation's pill can be carried (the minis box must not flick).
        preventStealing: p.conv !== ""
        property point start: Qt.point(0, 0)
        property bool carrying: false
        /** This press carried the pill: its release is no click. */
        property bool carried: false
        // Port (his ask): hovering a conversation's mini brings its card into view.
        onContainsMouseChanged: {
            if (!p.conv || C.Robo.dragConv !== "") return;
            // (And its chat's glow, his ask.)
            if (containsMouse) C.Robo.hoverConv = p.conv;
            else if (C.Robo.hoverConv === p.conv) C.Robo.hoverConv = "";
            if (containsMouse) C.Robo.convFocusKey = p.task.convKey || "";
            else if (C.Robo.convFocusKey === (p.task.convKey || "")) C.Robo.convFocusKey = "";
        }
        // Port (his bug): carried on the overlay of this pill's own tab
        // (one per screen), not whichever tab was made last.
        property Item dragger: null
        onPressed: m => { start = Qt.point(m.x, m.y); carrying = false; carried = false; dragger = C.Robo.convDragFor(p); }
        onPositionChanged: m => {
            if (!p.conv || !pressed || !dragger) return;
            if (!carrying && Math.hypot(m.x - start.x, m.y - start.y) > 5 && C.Robo.dragConv === "") {
                carrying = dragger.begin(p.task, p, start.x, start.y);
                carried = carrying;
            }
            if (carrying) dragger.move(p, m.x, m.y);
        }
        onReleased: m => {
            if (!carrying) return;
            carrying = false;
            if (dragger) dragger.end(p, m.x, m.y);
        }
        onCanceled: if (carrying) { carrying = false; if (dragger) dragger.cancel(); }
        onClicked: {
            if (carried || !C.Robo.island || !p.task) return;
            // Port (his ask): a conversation's mini opens its chat.
            if (p.conv) C.Robo.lib.ChatView.chat().openConv(p.conv);
            else C.Robo.island.actions.setFocus(p.task.id);
        }
    }
}
