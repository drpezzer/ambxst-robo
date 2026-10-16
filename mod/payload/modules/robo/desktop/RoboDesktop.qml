pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.modules.robo as C

// The mascot on the desktop: the window side of upstream's src-tauri/src/desktop.rs
// (layer-shell mode) plus his page (desktop/main.ts), both ported in
// lib/views/desktop.ts, extended to every display (see "The window" there).
//
// Per display, two layer surfaces (namespace "ambxst-robo-mascot"):
//   * his small window (120 px, upstream's): where he sits and takes the
//     mouse (his disc; the whole window while he sleeps). Top layer while he
//     sits, so a fullscreen app covers him as upstream; overlay layer while
//     he moves (flights), above the notch (Hyprland draws a surface moved to
//     a layer after the ones already there — set_layer, no remap).
//   * a full-display window on the overlay layer, up only while he may cross
//     displays (a drag, a carry out of the notch, a flight between displays):
//     it draws him wherever he is; during a drag it also catches the drop if
//     the pointer grab gets lost.
// Handing him between them never leaves a frame without him: the window he
// goes to draws first (presentedOnce), then the other stops.
// Drags and carries follow the global cursor (Hyprland), whichever surface
// holds the grab. While the notch is open with the keyboard, Hyprland sends
// every pointer event to Ambxst's panel: NotchMascotProxy (inside that panel)
// hands the presses on him to his page.
//
// The island's DesktopLink (upstream, in the bundle) talks to it through
// C.Robo.desktopHandler (desktop_mascot_* calls) and windowCommand
// "emit:mascot:<event>"; it answers with C.Robo.emitLocal.
//
// Instantiate once, at shell start (before the island boots, so
// desktop_mascot_info finds the handler set). Each surface gets a fresh item
// (Loader) per mapping: a Canvas in a layer surface that was unmapped and
// mapped again never draws again.
Scope {
    id: root

    /** The screen the island (the notch Robo shows in) is on. */
    property var islandScreen: Quickshell.screens.length > 0 ? Quickshell.screens[0] : null
    /**
     * Island-window client coordinates (upstream's 720-wide panel, the ones
     * island.pointerMove/pointerUp turn into px/py) → display-local logical px.
     * Only the pick-up point uses it: the carry follows the global cursor.
     */
    property var islandToDisplay: function (x, y, d) { return { x: (d.w - 720) / 2 + x, y: y }; }
    /** The island's top-centre on its display: where flights start and end. */
    property var islandAnchor: function (d) { return { cx: d.w / 2, top: 0 }; }
    /** A drag came near the notch (true) / left it (false): the owner may open / close the notch. */
    property var notchNear: function (near) {}
    /**
     * Test hook: function (cb) calling cb(x, y) with the global cursor
     * (asynchronously). Null: Hyprland's request socket.
     */
    property var cursorSource: null
    /**
     * Where the island's own mascot is drawn now: { x, y (his body's centre,
     * global), size (body box) } or null. Flights home end there, out start there.
     */
    property var homeTarget: function () { return null; }
    /** Settings → "Keep the mascot above fullscreen apps". */
    property bool keepAbove: false
    onKeepAboveChanged: if (win) win.setKeepAbove(keepAbove)

    property var ctl: null
    property int rev: 0

    readonly property var win: ctl ? ctl.win : null
    readonly property var page: ctl ? ctl.page : null
    readonly property bool shown: rev >= 0 && win !== null && win.shown
    readonly property bool spread: rev >= 0 && win !== null && win.spread
    readonly property bool following: rev >= 0 && win !== null && win.following
    readonly property bool cursorActive: rev >= 0 && win !== null && win.cursorActive
    /** Port: the cursor reaches his eyes (Robo's, in flight too). */
    readonly property bool eyesActive: rev >= 0 && win !== null && win.eyesActive
    readonly property bool hasCursor: !!cursorSource || !!Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE")

    /** desktop-flight "out" fade, shared by every window. */
    property real fade: 1
    /** Bumped once per engine step: every visible canvas repaints. */
    property int frameNo: 0

    // ── Handing him between the small and the full windows ──────────────────
    /** The full windows stay up after spreading ends, until his small window shows him. */
    property bool fullHold: false
    /** The full window under him has shown him (his small window may stop drawing). */
    property bool fullReady: false
    readonly property bool fullUp: shown && (spread || fullHold)
    onSpreadChanged: {
        if (spread) { fullHold = false; return; }
        if (shown) { fullHold = true; holdTimer.restart(); }
    }
    onShownChanged: if (!shown) { fullHold = false; fullReady = false; }
    onFullUpChanged: if (!fullUp) fullReady = false
    Timer { id: holdTimer; interval: 250; onTriggered: root.fullHold = false }

    /** NotchMascotProxy items, by screen name (notch geometry for the home zone). */
    property var notchProxies: ({})
    function registerNotch(name, proxy) { const m = notchProxies; m[name] = proxy; }
    function unregisterNotch(name, proxy) { if (notchProxies[name] === proxy) delete notchProxies[name]; }

    /** Quickshell.screens as plain data (index loop: array methods on a QML list crash V4 here). */
    function screensData() {
        const list = Quickshell.screens;
        const out = [];
        for (let i = 0; i < list.length; i++) out.push(screenData(list[i]));
        return out;
    }
    function screenData(s) {
        return { name: s.name, frame: { x: s.x, y: s.y, w: s.width, h: s.height } };
    }
    function viewOf(name) {
        void root.rev;
        return root.win ? root.win.view(name) : null;
    }

    function make() {
        const lib = C.Robo.lib.DesktopMascot;
        ctl = lib.create({
            core: (cmd, args) => new Promise((resolve, reject) => C.Robo.sendCore(cmd, args, resolve, reject)),
            emitIsland: (name, payload) => C.Robo.emitLocal(name, payload === undefined ? null : payload),
            screens: () => root.screensData(),
            islandScreen: () => root.islandScreen ? root.screenData(root.islandScreen) : null,
            islandAnchor: d => root.islandAnchor(d),
            fromIslandClient: (x, y, d) => root.islandToDisplay(x, y, d),
            follow: on => root.hasCursor,
            cursorNow: () => new Promise(resolve => cursor.ask(resolve)),
            notchRect: name => {
                const p = root.notchProxies[name];
                return p ? p.notchRect() : null;
            },
            nearNotch: near => root.notchNear(near),
            homeTarget: () => root.homeTarget(),
            changed: () => root.rev++,
        }, {
            emitIsland: (name, payload) => C.Robo.emitLocal(name, payload === undefined ? null : payload),
            windowWidth: () => 120,
            changed: () => root.rev++,
            fadeIn: () => { fadeAnim.stop(); root.fade = 0; fadeAnim.start(); },
        });
        C.Robo.desktopHandler = (cmd, args) => root.win.command(cmd, args);
        ctl.win.setKeepAbove(root.keepAbove);
        ctl.page.start("layer");
    }
    Component.onCompleted: make()
    Component.onDestruction: {
        if (C.Robo.desktopHandler && ctl) C.Robo.desktopHandler = null;
    }

    // Island → his page (emitToWindow("mascot", …)).
    Connections {
        target: C.Robo
        function onWindowCommand(cmd, args) {
            const prefix = "emit:mascot:";
            if (!root.page || cmd.indexOf(prefix) !== 0) return;
            root.page.onEvent(cmd.slice(prefix.length), args);
        }
    }
    // A display came or went: if his is gone he moves to the island's.
    Connections {
        target: Quickshell
        function onScreensChanged() { if (root.win) Qt.callLater(() => root.win.screensChanged()); }
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

    // One engine step per frame for every window (upstream: 30 fps awake, 4 asleep).
    Timer {
        interval: root.rev >= 0 && root.page ? root.page.frameInterval : 250
        repeat: true
        running: root.rev >= 0 && root.page !== null && root.page.visible
        triggeredOnStart: true
        onTriggered: if (root.page.step(Date.now())) root.frameNo++
    }

    // ── The windows, per display ────────────────────────────────────────────
    Variants {
        model: Quickshell.screens

        Scope {
            id: perScreen
            required property ShellScreen modelData
            readonly property string name: modelData.name
            readonly property var v: root.viewOf(name)

            // His small window.
            PanelWindow {
                id: small
                screen: perScreen.modelData
                visible: !!perScreen.v && perScreen.v.small
                color: "transparent"
                WlrLayershell.layer: perScreen.v && perScreen.v.smallLayer === "top" ? WlrLayer.Top : WlrLayer.Overlay
                WlrLayershell.namespace: "ambxst-robo-mascot"
                WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
                exclusionMode: ExclusionMode.Ignore
                anchors {
                    top: true
                    left: true
                }
                // Port (his ask): room above his 120 px square (as much as the
                // display has, up to 40 px), so Robo's antenna glow is not cut
                // off; he is drawn where he always was, input is unchanged.
                readonly property int room: perScreen.v ? Math.max(0, Math.min(40, Math.round(perScreen.v.smallY))) : 0
                margins {
                    left: perScreen.v ? perScreen.v.smallX : 0
                    top: perScreen.v ? perScreen.v.smallY - small.room : 0
                }
                implicitWidth: 120
                implicitHeight: 120 + small.room
                mask: !perScreen.v ? emptyRegion : perScreen.v.smallShape === "disc" ? discRegion : perScreen.v.smallShape === "whole" ? wholeRegion : emptyRegion

                // body_disc(): centre (60, 60), radius 0.24 × 120 = 28.8.
                Region { id: discRegion; shape: RegionShape.Ellipse; x: 31; y: 31 + small.room; width: 58; height: 58 }
                Region { id: wholeRegion; x: 0; y: small.room; width: 120; height: 120 }
                Region { id: emptyRegion; x: 0; y: 0; width: 0; height: 0 }

                Loader {
                    id: smallLoader
                    x: 0
                    y: small.room
                    width: 120
                    height: 120
                    active: small.visible
                    sourceComponent: DesktopMascotItem {
                        page: root.page
                        rev: root.rev
                        external: true
                        frameNo: root.frameNo
                        fade: root.fade
                        drawScale: perScreen.v ? perScreen.v.scale : 1
                        // Spread: he stays here until the full window under him shows him.
                        draws: !!perScreen.v && perScreen.v.small && (perScreen.v.smallDraws || !root.fullReady)
                        onPresentedOnceChanged: if (presentedOnce && perScreen.v && perScreen.v.smallDraws && root.fullHold) root.fullHold = false
                    }
                }
            }

            // The full-display window (crossing displays).
            PanelWindow {
                id: full
                screen: perScreen.modelData
                visible: root.fullUp
                color: "transparent"
                WlrLayershell.layer: WlrLayer.Overlay
                WlrLayershell.namespace: "ambxst-robo-mascot"
                WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
                exclusionMode: ExclusionMode.Ignore
                anchors {
                    top: true
                    left: true
                    right: true
                    bottom: true
                }
                mask: perScreen.v && perScreen.v.fullShape === "whole" && root.spread ? fullWhole : fullEmpty
                Region { id: fullWhole; x: 0; y: 0; width: full.width; height: full.height }
                Region { id: fullEmpty; x: 0; y: 0; width: 0; height: 0 }

                Loader {
                    anchors.fill: parent
                    active: full.visible
                    sourceComponent: Item {
                        DesktopMascotItem {
                            anchors.fill: parent
                            page: root.page
                            rev: root.rev
                            interactive: false
                            external: true
                            frameNo: root.frameNo
                            fade: root.fade
                            drawX: perScreen.v ? perScreen.v.x : 0
                            drawY: perScreen.v ? perScreen.v.y : 0
                            drawScale: perScreen.v ? perScreen.v.scale : 1
                            onPresentedOnceChanged: if (presentedOnce && root.win && root.win.screen === perScreen.name) root.fullReady = true
                        }
                        // The pointer grab left his small window (Hyprland keeps it
                        // only while some surface has the keyboard), or a carry's
                        // left the notch (another display, the notch closed): the
                        // drop lands here. A release seen as a move without the
                        // button (only once Qt has shown it held here), or a new press.
                        MouseArea {
                            anchors.fill: parent
                            enabled: !!perScreen.v && perScreen.v.fullShape === "whole"
                            hoverEnabled: true
                            acceptedButtons: Qt.LeftButton | Qt.RightButton
                            property bool sawHeld: false
                            onPositionChanged: m => {
                                if (m.buttons & Qt.LeftButton) sawHeld = true;
                                else if (sawHeld) { sawHeld = false; root.strayDrop(); }
                                // A loose carry: the press's surface (the notch) keeps the
                                // pointer until the button goes up, so any move reaching this
                                // window without it is after the release (lost with the island).
                                else if (root.win && root.win.carry && !(root.page && root.page.dragging)) root.strayDrop();
                            }
                            onPressed: root.strayDrop()
                        }
                    }
                }
            }
        }
    }

    /** The release of a drag / carry went to another surface: drop him where the cursor is. */
    function strayDrop() {
        if (root.page && root.page.dragging) root.page.cancelDrag();
        else if (root.win && root.win.carry) root.win.carryEnd(NaN, NaN);
    }
    // Safety: a drag or carry whose cursor stood still for 10 s lost its release.
    Timer {
        interval: 1000
        repeat: true
        running: root.following
        onTriggered: if (root.win && root.win.stalled(Date.now())) root.strayDrop()
    }

    // ── Global cursor ───────────────────────────────────────────────────────
    // Upstream polls the cursor on Windows only; Hyprland has it too: his eyes
    // while he is awake on the desktop (~10 Hz), and his position during drags
    // and carries (~60 Hz). Asleep, nothing polls: the little window wakes him.
    QtObject {
        id: cursor
        property var waiters: []
        property bool busy: false
        function ask(resolve) {
            waiters.push(resolve);
            askTimeout.restart();
            request();
        }
        function request() {
            if (root.cursorSource) {
                if (busy) return;
                busy = true;
                root.cursorSource((x, y) => { cursor.busy = false; cursor.deliver(x, y); });
                return;
            }
            if (!root.hasCursor) { deliver(NaN, NaN); return; }
            if (!hypr.connected) hypr.connected = true;
        }
        function deliver(x, y) {
            const ok = isFinite(x) && isFinite(y);
            const w = waiters;
            waiters = [];
            if (w.length) askTimeout.stop();
            for (let i = 0; i < w.length; i++) w[i](ok ? { x: x, y: y } : null);
            if (!ok || !root.win) return;
            if (root.win.following) root.win.followTo({ x: x, y: y });
            else if (root.win.eyesActive) root.win.cursorAt({ x: x, y: y });
        }
    }
    // A cursor read that never answers: the drop is where he is.
    Timer { id: askTimeout; interval: 150; onTriggered: cursor.deliver(NaN, NaN) }
    Socket {
        id: hypr
        property real cx: 0
        property real cy: 0
        path: (Quickshell.env("XDG_RUNTIME_DIR") || "") + "/hypr/" + (Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE") || "") + "/.socket.sock"
        parser: SplitParser {
            onRead: line => {
                const m = /"([xy])":\s*(-?[\d.]+)/.exec(line);
                if (m) {
                    if (m[1] === "x") hypr.cx = +m[2];
                    else hypr.cy = +m[2];
                    return;
                }
                if (line.trim() !== "}") return;
                // Close before Hyprland does (no PeerClosed warning per poll).
                hypr.connected = false;
                cursor.deliver(hypr.cx, hypr.cy);
            }
        }
        onConnectionStateChanged: if (connected) { write("j/cursorpos"); flush(); }
    }
    Timer {
        // (In flight 33 ms: his eyes follow along as he flies.)
        interval: root.following ? 16 : root.cursorActive ? 100 : 33
        repeat: true
        running: (root.eyesActive || root.following) && root.hasCursor
        onTriggered: cursor.request()
    }

    function debugState() {
        const pg = root.page, w = root.win;
        const views = {};
        const list = root.screensData();
        for (let i = 0; i < list.length; i++) views[list[i].name] = w ? w.view(list[i].name) : null;
        return JSON.stringify({
            shown: root.shown, spread: root.spread, following: root.following, landed: w ? w.landed : null,
            dragging: w ? w.dragging : null, flying: w ? w.flying : null, near: w ? w.near : null,
            pos: w ? w.pos : null, screen: w ? w.screen : null, smallScreen: w ? w.smallScreen : null,
            island: root.islandScreen ? root.islandScreen.name : null,
            fullHold: root.fullHold, fullReady: root.fullReady, views: views,
            notches: Object.keys(root.notchProxies),
            pageVisible: pg ? pg.visible : null, frameInterval: pg ? pg.frameInterval : null,
            fade: root.fade, asleep: pg ? pg.asleep : null,
        });
    }
}
