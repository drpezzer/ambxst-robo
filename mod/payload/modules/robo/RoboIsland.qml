pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Window
import qs.modules.robo as C
import qs.modules.robo.views as V

// The open island (upstream #island in expanded mode), 640 wide, as tall as
// the island's own animated height. Geometry, the mascot, glow and countdown come
// from lib/island.ts each frame; the views are QML ports of views/*.ts.
Item {
    id: root

    readonly property var island: C.Robo.island
    readonly property var lib: C.Robo.lib
    readonly property var st: C.Robo.state
    /** Visible on screen: steps the frame loop. */
    property bool live: visible
    property real islandH: 160
    /** Port: the tab's launch staging fades the header and views in (RoboTab). */
    property real introFade: 1
    /** Port: the tab stages the greeting: no clip, a canvas grown by these pads. */
    property bool greetStage: false
    /** The greeting's two body off-whites, as the engine's own body gradient in the mascot's colour. */
    function greetTint(col) {
        const body = root.island ? root.island.engine.bodyColor : null;
        if (!body) return col;
        const c = String(col).replace(/\s/g, "");
        const css = v => "rgb(" + v.map(n => Math.round(n * 255)).join(",") + ")";
        if (c === "rgb(251,251,252)") return css(body.map(n => n + (1 - n) * 0.35));
        if (c === "rgb(231,233,236)") return css(body);
        return col;
    }
    property real greetPadX: 0
    property real greetPadY: 0

    width: 640
    height: islandH
    clip: false

    // ── Frame loop ──────────────────────────────────────────────────────────
    // Port (performance): every display frame only while the island itself
    // moves (shape, greeting, drop, view transitions); the mascot alone at 60 fps
    // on a timer, which (unlike a FrameAnimation) doesn't make the notch's
    // screen-sized surface redraw at 165 Hz to show nothing new.
    readonly property bool fullRate: C.Robo.frameTick >= 0 && root.island !== null && root.island.fullRate
    FrameAnimation {
        id: frames
        running: root.live && C.Robo.frameWanted && root.island !== null && root.fullRate
        onTriggered: C.Robo.stepFrame(Date.now())
    }
    Timer {
        // The mascot's own loops (breathing, working) at ~30 fps: a frame of him
        // costs ~3 ms of main-thread JS to draw.
        interval: 33
        repeat: true
        running: root.live && C.Robo.frameWanted && root.island !== null && !root.fullRate
        onTriggered: C.Robo.stepFrame(Date.now())
    }
    // Whoever stepped the island this frame (this tab or a bar), draw it.
    Connections {
        target: C.Robo
        function onFrameTickChanged() { if (root.live) root.applyFrame(); }
    }
    onLiveChanged: {
        C.Robo.frameSources += live ? 1 : -1;
        C.Robo.fullRateSources += live ? 1 : -1;
        if (live && island) island.ensureRunning();
    }
    Component.onCompleted: if (live) { C.Robo.frameSources += 1; C.Robo.fullRateSources += 1; }
    Component.onDestruction: if (live) { C.Robo.frameSources -= 1; C.Robo.fullRateSources -= 1; }

    property real islandW: 640
    function applyFrame() {
        const i = island;
        if (!i) return;
        islandW = i.width.value;
        islandH = i.height.value;
        const b = i.bot;
        // Island coordinates are relative to the island's own left edge, which
        // upstream centres in the panel; here the island is a fixed 640 slot.
        const dx = (640 - islandW) / 2;
        botCanvas.x = dx + b.left;
        botCanvas.y = b.top;
        botCanvas.width = b.w;
        botCanvas.height = b.h;
        botCanvas.visible = b.visible;
        if (b.visible) botCanvas.requestPaint();
        const g = i.glow;
        // Port: a glow coming back (the mascot home from the desktop, the greeting
        // or a drop over) fades and grows in; one going fades out where it was.
        if (g && !glow.present) glow.comeBack();
        glow.present = g !== null;
        if (!g) glow.targetOpacity = 0;
        if (g) {
            glow.x = dx + g.x;
            glow.y = g.y;
            glow.width = g.d;
            glow.height = g.d;
            glow.glowColor = g.color;
            glow.targetOpacity = g.opacity;
        }
        countdown.width = i.countdownW;
        greeting.visible = i.greetingActive;
        if (i.greetingActive) greeting.requestPaint();
        content.opacity = i.content.opacity;
        content.enabled = i.content.interactive;
    }

    // ── Pointer → island (cursor, clicks on the mascot, drag out) ───────────────
    function panelX(x) { return x + (720 - 640) / 2; }
    /** The global cursor (Hyprland, logical px) → island.onCursor, while live. */
    function feedGlobalCursor(gx, gy) {
        if (!live || !island) return;
        const p = mapFromItem(null, gx - Screen.virtualX, gy - Screen.virtualY);
        island.onCursor(panelX(p.x), p.y);
    }
    HoverHandler {
        id: hover
        onPointChanged: if (root.island) root.island.onCursor(root.panelX(point.position.x), point.position.y)
        onHoveredChanged: if (!hovered && root.island) root.island.setPointerInside(false)
    }

    C.RoboDropArea {
        anchors.fill: parent
        // While a file is dragged over, the cursor drives the mascot and the sheet.
        toIsland: (x, y) => { if (root.island) root.island.onCursor(root.panelX(x), y); }
    }

    // Presses anywhere on the island (upstream's mousedown on #island): a click
    // on the mascot slaps him, a right click is the wardrobe, a drag carries him out
    // to the desktop. Passive: buttons under it keep their clicks.
    function islandX(x) { return x - (640 - islandW) / 2; }
    PointHandler {
        id: press
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        property bool leftDown: false
        property real lastX: 0
        property real lastY: 0
        onActiveChanged: {
            const i = root.island;
            if (!i) return;
            const p = point.position;
            if (active) {
                leftDown = point.pressedButtons & Qt.LeftButton;
                lastX = p.x;
                lastY = p.y;
                i.pointerDown(root.islandX(p.x), p.y, leftDown ? "left" : "right");
            } else {
                // The release position is not trustworthy (reset); the last move's is.
                i.pointerUp(root.islandX(lastX), lastY);
                leftDown = false;
            }
        }
        // Only a move with the left button still down is a drag: on release Qt
        // resets the point (position 0,0) before `active` turns false, which
        // read as a 60+ px drag and carried the mascot out on a plain click.
        onPointChanged: {
            if (!active || !root.island) return;
            if (!(point.pressedButtons & Qt.LeftButton)) return;
            if (point.position.x === 0 && point.position.y === 0) return; // the reset point
            lastX = point.position.x;
            lastY = point.position.y;
            root.island.pointerMove(root.islandX(lastX), lastY, true);
        }
    }

    // #island-clip: the greeting, the drop sequence and the content are cut to
    // the island's own animated shape, so opening reveals them as it springs
    // (the glow, the mascot and the countdown overflow it, as upstream).
    Item {
        id: islandClip
        // Port: not while the tab stages the greeting (its burst fills the tab).
        clip: !root.greetStage
        x: (640 - root.islandW) / 2
        y: 0
        width: root.islandW
        height: root.islandH

        // The launch greeting (#greeting-canvas, 640×150).
        Canvas {
            id: greeting
            property var wrap: null
            property var stageWrap: null
            property var tintWrap: null
            x: (root.islandW - 640) / 2 - root.greetPadX
            y: -root.greetPadY
            width: 640 + 2 * root.greetPadX
            height: 150 + 2 * root.greetPadY
            visible: false
            onPaint: {
                const i = root.island;
                if (!i) return;
                const ctx = getContext("2d");
                if (!wrap) wrap = new C.Robo.lib.CtxWrap(ctx, greeting);
                wrap.setTransform(1, 0, 0, 1, 0, 0);
                wrap.clearRect(0, 0, width, height);
                // Port: staged in the tab, the greeting's own 620×104 card and
                // the clip to it are left out (the tab's card is the box), and
                // its 640×150 space sits in the middle of this bigger canvas.
                if (root.greetStage) {
                    if (!stageWrap) {
                        stageWrap = Object.create(wrap);
                        stageWrap.clip = function () { this.beginPath(); };
                        // (The real one, for what clips itself: Axenide's lighting.)
                        stageWrap.realClip = function (p, r) { return wrap.clip.call(this, p, r); };
                        // His body in his own colour (the greeting paints it
                        // in two fixed off-whites).
                        stageWrap.createLinearGradient = function (a, b, c, d) {
                            const g = wrap.createLinearGradient(a, b, c, d);
                            const add = g.addColorStop.bind(g);
                            g.addColorStop = function (o, col) { add(o, root.greetTint(col)); };
                            return g;
                        };
                        stageWrap.fill = function () {
                            if (String(this.fillStyle).toLowerCase() === "#141518") { this.beginPath(); return; }
                            return wrap.fill.apply(wrap, arguments);
                        };
                    }
                    wrap.setTransform(1, 0, 0, 1, root.greetPadX, root.greetPadY);
                    i.greeting.draw(stageWrap);
                } else {
                    // Still in his colour (its last frames, once the tab's
                    // staging has let go, flashed white).
                    if (!tintWrap) {
                        tintWrap = Object.create(wrap);
                        tintWrap.createLinearGradient = function (a, b, c, d) {
                            const g = wrap.createLinearGradient(a, b, c, d);
                            const add = g.addColorStop.bind(g);
                            g.addColorStop = function (o, col) { add(o, root.greetTint(col)); };
                            return g;
                        };
                    }
                    i.greeting.draw(tintWrap);
                }
            }
        }

        // The drop sequence (upstream #upload-layer): under the content, which
        // hides its views while it plays; the header stays on top of it.
        V.UploadLayer { x: (root.islandW - 640) / 2; y: 0 }

        // Content: header + views (#content, padding 8 10 10).
        Item {
            id: content
            anchors.fill: parent
            opacity: 0
            Behavior on opacity { NumberAnimation { duration: 200; easing.type: Easing.BezierSpline; easing.bezierCurve: C.RoboTheme.easeInOut } }

            // Port: the tab's launch reveal brings the header down from the top
            // (on a wrapper: the header's own opacity is its confused-view fade).
            Item {
                anchors.fill: parent
                opacity: root.introFade * C.Robo.introBoxes
                transform: Translate { y: -14 * (1 - C.Robo.introBoxes) }
                V.Header {
                    id: header
                    x: 0
                    y: 8
                    width: parent.width
                    height: 34
                }
            }

            Item {
                id: viewsArea
                readonly property bool uploadOn: C.Robo.rev + C.Robo.frameTick >= 0 && root.island !== null && root.island.uploadActive
                opacity: (uploadOn ? 0 : 1) * root.introFade
                enabled: !uploadOn
                Behavior on opacity { NumberAnimation { duration: 220; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.42, 0, 0.58, 1, 1, 1] } }
                x: 10
                y: 42
                width: parent.width - 20
                // (His ask: the chat page filling the tab reaches its bottom,
                // level with the chats column beside it: no 10 px under it.)
                readonly property bool fillsTab: C.Robo.rev >= 0 && root.island !== null && root.island.chatFillHeight > 0
                    && C.Robo.state.mode === "expanded" && C.Robo.state.view === "prompt"
                height: Math.max(0, parent.height - 42 - (fillsTab ? 0 : 10))

                Repeater {
                    model: ["overview", "empty", "approval", "question", "error", "finished", "confused",
                            "upload", "uploading", "choose", "mail", "prompt", "searching", "result", "note",
                            "settings", "recap", "wardrobe"]
                    delegate: V.ViewSlot {
                        required property string modelData
                        viewName: modelData
                        width: viewsArea.width
                        height: viewsArea.height
                    }
                }
            }
        }

    }

    // Glow behind the mascot — above the cards, under the mascot, as upstream #bot-glow (#bot-glow: radial gradient, blur 6px, 0.4 s fades).
    Item {
        id: glow
        property color glowColor: "white"
        // #bot-glow: transition background 0.4 s ease-in-out.
        Behavior on glowColor { ColorAnimation { duration: 400; easing.type: Easing.BezierSpline; easing.bezierCurve: C.RoboTheme.easeInOut } }
        // The reference (Chromium) shows a ~100 ms white disc on the very first
        // open of a launch, a first-paint artefact of the never-styled element,
        // not a designed motion; the port fades the glow in instead.
        property real targetOpacity: 0
        property bool present: false
        property real appear: 1
        visible: present || opacity > 0.01
        opacity: targetOpacity * appear
        scale: 0.7 + 0.3 * appear
        Behavior on opacity { NumberAnimation { duration: 400; easing.type: Easing.BezierSpline; easing.bezierCurve: C.RoboTheme.easeInOut } }
        function comeBack() { appearAnim.restart(); }
        NumberAnimation {
            id: appearAnim
            target: glow; property: "appear"; from: 0; to: 1
            duration: 520; easing.type: Easing.BezierSpline; easing.bezierCurve: C.RoboTheme.easeOut
        }
        Canvas {
            id: glowCanvas
            anchors.fill: parent
            anchors.margins: -8
            property color c: glow.glowColor
            onCChanged: requestPaint()
            onWidthChanged: requestPaint()
            onPaint: {
                const ctx = getContext("2d");
                ctx.reset();
                const r = glow.width / 2;
                const cx = width / 2, cy = height / 2;
                const g = ctx.createRadialGradient(cx, cy, 0, cx, cy, r * 0.62 * 1.414);
                // radial-gradient(circle …) sizes to the farthest corner: r·√2.
                g.addColorStop(0, Qt.rgba(c.r, c.g, c.b, 1));
                g.addColorStop(1, Qt.rgba(c.r, c.g, c.b, 0));
                ctx.fillStyle = g;
                ctx.beginPath();
                ctx.ellipse(cx - r, cy - r, r * 2, r * 2);
                ctx.fill();
            }
            layer.enabled: true
            layer.effect: null
        }
    }

    // The mascot (#bot-canvas): drawn by the island's own engine.
    Canvas {
        id: botCanvas
        property var wrap: null
        // Port (performance): rasterised off the GUI thread.
        renderStrategy: Canvas.Threaded
        onPaint: {
            const i = root.island;
            if (!i) return;
            const ctx = getContext("2d");
            if (!wrap) wrap = new C.Robo.lib.CtxWrap(ctx, botCanvas);
            wrap.setTransform(1, 0, 0, 1, 0, 0);
            wrap.clearRect(0, 0, width, height);
            i.drawBot(wrap);
        }
    }

    // Auto-close countdown (#countdown): 2 px, centred at the bottom.
    Rectangle {
        id: countdown
        height: 2
        radius: 2
        width: 0
        color: Qt.rgba(1, 1, 1, 0.35)
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        visible: width > 0
    }
}
