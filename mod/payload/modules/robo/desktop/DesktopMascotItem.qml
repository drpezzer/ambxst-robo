import QtQuick
import qs.modules.robo as C

// The desktop mascot's page (upstream the desktop page + desktop/main.ts): a 120 px
// canvas (#mascot), drawn by his own BotEngine through lib DesktopMascot.DesktopPage,
// and the mouse — poke, double-click home, right-click wardrobe, drag.
// RoboDesktop puts one in each of his windows (his small window and the
// full-display ones he crosses displays in); the canvas sits at (drawX, drawY).
Item {
    id: root

    /** lib DesktopMascot.DesktopPage. */
    property var page: null
    /** Bumped by the owner whenever the page says something changed. */
    property int rev: 0
    /** False in the offscreen harness (its synthetic hover would move his eyes) and in windows that draw only. */
    property bool interactive: true
    /** The owner steps the page and bumps frameNo (several items draw one mascot); else this item's own timer does. */
    property bool external: false
    property int frameNo: 0
    /** Where his 120 px box is in this item. */
    property real drawX: 0
    property real drawY: 0
    /** This item draws him (the owner hands him between windows). */
    property bool draws: true
    /** His drawing's scale about his box's centre (flights to / from the island's mascot). */
    property real drawScale: 1
    /** desktop-flight "out" fade (0 → 1). */
    property real fade: 1
    /**
     * He has been on screen here for a few frames since he last started
     * drawing in this item: the owner may take him out of another window.
     */
    property bool presentedOnce: false

    readonly property real canvasOpacity: canvas.opacity
    /** He is drawn in this item right now. */
    readonly property bool drawing: canvas.visible
    readonly property bool pageVisible: rev >= 0 && page !== null && page.visible
    readonly property real frameInterval: rev >= 0 && page ? page.frameInterval : 250

    /** desktop-flight "out": opacity 0 → 1 (#mascot transition: opacity 0.45s ease-in-out). */
    function fadeIn() {
        fadeAnim.stop();
        root.fade = 0;
        fadeAnim.start();
    }

    /** One frame now (setVisible / a harness step). */
    function frame() {
        if (external) {
            if (canvas.visible) canvas.requestPaint();
            return;
        }
        if (page && page.step(Date.now())) canvas.requestPaint();
    }
    onFrameNoChanged: if (external && canvas.visible) canvas.requestPaint()

    Canvas {
        id: canvas
        property var wrap: null
        // Port (his ask): 40 px more above and below his 120 px box (Robo's
        // antenna glow reaches past it), the box still centred: the scale
        // below turns about his centre, as before.
        readonly property int extra: 40
        x: root.drawX
        y: root.drawY - extra
        width: 120
        height: 120 + 2 * extra
        // Off this window (a full-display window on another display): nothing to draw.
        visible: root.draws && root.pageVisible && x > -width && y > -height && x < root.width && y < root.height
        opacity: root.fade
        scale: root.drawScale
        transformOrigin: Item.Center
        renderStrategy: Canvas.Cooperative
        onVisibleChanged: {
            if (visible) requestPaint();
            else { root.presentedOnce = false; shownTimer.stop(); }
        }
        onPaint: {
            if (!root.page) return;
            const ctx = getContext("2d");
            if (!wrap) wrap = new (C.Robo.lib.CtxWrap)(ctx, canvas);
            wrap.setTransform(1, 0, 0, 1, 0, 0);
            root.page.paint(wrap, canvas.extra);
        }
        // A painted frame reaches the screen within a few frames (a new
        // surface also waits for its first configure, which comes before any paint).
        onPainted: if (visible && !root.presentedOnce && !shownTimer.running) shownTimer.start()
    }
    Timer {
        id: shownTimer
        interval: 50
        onTriggered: if (canvas.visible) root.presentedOnce = true
    }

    NumberAnimation {
        id: fadeAnim
        target: root
        property: "fade"
        from: 0
        to: 1
        duration: 450
        easing.type: Easing.BezierSpline
        easing.bezierCurve: [0.42, 0, 0.58, 1, 1, 1]
    }

    // Upstream: 30 fps awake, 4 fps asleep, only while on screen.
    Timer {
        interval: root.frameInterval
        repeat: true
        running: !root.external && root.pageVisible
        triggeredOnStart: true
        onTriggered: root.frame()
    }

    MouseArea {
        id: mouse
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        enabled: root.interactive
        hoverEnabled: true
        /** A double-click's second press: home once it is released (dblclick follows pointerup). */
        property point dbl: Qt.point(-1, -1)
        property bool dblPending: false
        // The page works in his box's coordinates.
        function bx(m) { return m.x - canvas.x; }
        function by(m) { return m.y - canvas.y; }

        onPressed: m => {
            if (!root.page) return;
            if (m.button === Qt.RightButton) {
                // contextmenu (fires on press on Linux).
                root.page.pointerDown(bx(m), by(m), 2, 0, 0);
                root.page.contextMenu(bx(m), by(m));
                return;
            }
            root.page.pointerDown(bx(m), by(m), 0, 0, 0);
        }
        onPositionChanged: m => { if (root.page) root.page.pointerMove(bx(m), by(m)); }
        onReleased: m => {
            if (!root.page || m.button !== Qt.LeftButton) return;
            root.page.pointerUp(bx(m), by(m));
            if (dblPending) {
                dblPending = false;
                root.page.doubleClick(dbl.x, dbl.y);
            }
        }
        // The grab was taken away before a drag began: forget the press. A
        // drag goes on (the global cursor moves him; RoboDesktop catches the drop).
        onCanceled: if (root.page && !root.page.dragging) root.page.cancelDrag()
        onDoubleClicked: m => {
            if (m.button !== Qt.LeftButton) return;
            dbl = Qt.point(bx(m), by(m));
            dblPending = true;
        }
        onExited: if (root.page) root.page.pointerLeave()
    }
}
