pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Window
import qs.modules.components
import qs.modules.theme
import qs.config
import qs.modules.robo as C
import qs.modules.robo.shell

// Robo's compact island in the bar, in place of the Ambxst logo: the mascot
// (drawn by the island's own engine, at the compact size: a 20 px body) and,
// beside him (horizontal bar) or below him (vertical bar), the 2×2 grid of
// the other pills' mini mascots (13 px, 3 px apart), as upstream #mini-grid.
// Left click opens Robo in the notch, right click on the mascot is the wardrobe;
// hovering wakes him like Coucou's hover strip.
Item {
    id: root

    property bool vertical: false
    property real startRadius: 0
    property real endRadius: 0
    property bool enableShadow: true

    readonly property var island: C.Robo.island
    readonly property int rev: C.Robo.rev
    readonly property var others: rev >= 0 && C.Robo.state ? C.Robo.state.otherTasks.slice(0, 4) : []
    readonly property bool hasGrid: others.length > 0
    // The grid is rebuilt only when its ids change (island.ts syncDom's
    // dataset.key): a fresh mini replays its state's entry animation.
    readonly property string othersKey: others.map(t => t.id).join("|")
    readonly property bool away: rev >= 0 && C.Robo.state && C.Robo.state.mascotOnDesktop

    readonly property real cell: 36
    readonly property real gridSlot: hasGrid ? 33 : 0

    implicitWidth: vertical ? cell : cell + gridSlot
    implicitHeight: vertical ? cell + gridSlot : cell

    StyledRect {
        id: bg
        anchors.fill: parent
        variant: "bg"
        enableShadow: root.enableShadow && Config.showBackground
        topLeftRadius: root.startRadius
        topRightRadius: root.vertical ? root.startRadius : root.endRadius
        bottomLeftRadius: root.vertical ? root.endRadius : root.startRadius
        bottomRightRadius: root.endRadius

        Rectangle {
            anchors.fill: parent
            color: parent.item || "transparent"
            opacity: ma.pressed ? 0.5 : (ma.containsMouse ? 0.25 : 0)
            topLeftRadius: parent.topLeftRadius
            topRightRadius: parent.topRightRadius
            bottomLeftRadius: parent.bottomLeftRadius
            bottomRightRadius: parent.bottomRightRadius
            Behavior on opacity {
                enabled: (Config.animDuration ?? 0) > 0
                NumberAnimation { duration: (Config.animDuration ?? 0) / 2 }
            }
        }
    }

    // The mascot: compact botPosition diameter 20 → engine box 20 / 0.6.
    readonly property real botBox: 20 / 0.6
    Canvas {
        id: mascotCanvas
        property var wrap: null
        readonly property real side: C.Robo.lib ? C.Robo.lib.BOT_SIDE : 24
        readonly property real overhang: C.Robo.lib ? C.Robo.lib.BOT_OVERHANG : 40
        width: root.botBox + side * 2
        height: root.botBox + overhang
        // The body sits centred in the first 36×36 cell (the engine puts it in
        // the box's middle, the overhang above it is for hats and particles).
        x: root.cell / 2 - width / 2
        y: root.cell / 2 - overhang / 2 - height / 2
        visible: !root.away
        // Port (performance): rasterised at once (a ~80 px canvas), with the
        // minis (MiniBot `driven`): one step is one frame of the bar's
        // screen-sized surface. Threaded, each canvas's texture landed in a
        // frame of its own.
        renderStrategy: Canvas.Immediate
        onPaint: {
            const i = root.island;
            const ctx = getContext("2d");
            if (!wrap) wrap = new C.Robo.lib.CtxWrap(ctx, mascotCanvas);
            wrap.setTransform(1, 0, 0, 1, 0, 0);
            wrap.clearRect(0, 0, width, height);
            if (i) i.drawBot(wrap, root.botBox);
        }
    }

    Grid {
        id: grid
        visible: root.hasGrid
        columns: 2
        spacing: 3
        width: 29
        height: 29
        x: root.vertical ? (root.cell - 29) / 2 : root.cell + (root.gridSlot - 29) / 2 - 2
        y: root.vertical ? root.cell + (root.gridSlot - 29) / 2 - 2 : (root.cell - 29) / 2
        Repeater {
            id: minis
            model: root.othersKey ? root.othersKey.split("|") : []
            delegate: C.MiniBot {
                required property string modelData
                task: root.others.find(t => t.id === modelData) || null
                bodySize: 13
                // Painted with the bar's Robo, its engine shared with the other screens' bars.
                driven: true
            }
        }
    }

    /**
     * Port (performance): the bar's slide (BarContent fsProgress, 1 = in place).
     * The mascot and the minis draw only while the bar is in place: not while it is
     * away, and not while it slides (the slide had to share the GUI thread).
     */
    property real barShown: 1
    readonly property bool steady: visible && barShown >= 0.999
    /** The screen it is on (the harness, whose displays all say the same, sets it). */
    property string screenName: Screen.name
    /**
     * Port (performance): each repaint redraws (and Hyprland re-blurs) the
     * bar's screen-sized surface: only the focused screen's bar animates
     * (RoboShell.leadBarScreen); the others hold their last frame, redrawn
     * when the state changes.
     */
    readonly property bool lead: steady && RoboShell.leadBarScreen === screenName
    onSteadyChanged: {
        register();
        if (steady) paintAll();
    }
    onScreenNameChanged: register()
    /** RoboShell.steadyBars: this bar's screen while it is in place. */
    property string barKey: "" // (set once made)
    function register() { RoboShell.setBarSteady(barKey, screenName, steady); }
    onLeadChanged: {
        countSource(lead);
        if (lead && island) island.ensureRunning();
        if (steady) paintAll();
    }

    // Frames: the island's loop, stepped ~10 times a second for the bars by
    // C.Robo (one timer for every screen; the open notch steps it faster
    // itself, RoboIsland). Each step, the leading bar repaints its Robo and
    // whichever minis moved, all in the same turn: one frame of the surface.
    property bool counted: false
    function countSource(on) {
        if (on === counted) return;
        counted = on;
        C.Robo.frameSources += on ? 1 : -1;
        C.Robo.barSources += on ? 1 : -1;
    }
    function paintMinis(all) {
        for (let i = 0; i < minis.count; i++) {
            const m = minis.itemAt(i);
            if (!m) continue;
            if (all) m.paintNow();
            else m.paintIfChanged();
        }
    }
    function paintAll() {
        root.lastPaint = Date.now();
        mascotCanvas.requestPaint();
        paintMinis(true);
    }
    property real lastPaint: 0
    Connections {
        target: C.Robo
        // ~10 repaints a second here, whatever rate the loop runs at (the
        // open notch steps it at up to the display's rate).
        function onFrameTickChanged() {
            if (!root.lead) return;
            const now = Date.now();
            if (now - root.lastPaint < 90) return;
            root.lastPaint = now;
            mascotCanvas.requestPaint();
            root.paintMinis(false);
        }
        function onIslandChanged() { mascotCanvas.requestPaint(); }
        // A bar that holds still shows the state as it changes (a pill's
        // face, a mini come or gone), at most twice a second.
        function onRevChanged() { if (root.steady && !root.lead && !stillPaint.running) stillPaint.start(); }
    }
    Timer { id: stillPaint; interval: 500; onTriggered: if (root.steady && !root.lead) root.paintAll() }
    /** The mascot's centre in global (Hyprland) logical coordinates. */
    function mascotCentre() {
        const p = mascotCanvas.mapToItem(null, mascotCanvas.width / 2, mascotCanvas.overhang / 2 + mascotCanvas.height / 2);
        return { x: p.x + Screen.virtualX, y: p.y + Screen.virtualY, screen: Screen.name, size: root.botBox };
    }
    Component.onDestruction: {
        const i = RoboShell.bars.indexOf(root);
        if (i >= 0) RoboShell.bars.splice(i, 1);
        countSource(false);
        RoboShell.setBarSteady(barKey, "", false);
    }
    Component.onCompleted: {
        RoboShell.bars.push(root);
        barKey = RoboShell.newBarKey();
        register();
        countSource(lead);
        void RoboShell.dashboardTab; // brings up the shell glue (shortcuts) at start
    }

    C.RoboDropArea { anchors.fill: parent }

    // Coucou's tray menu (tray.rs), from a right click beside the mascot: there is
    // no tray icon in this port, the bar's Robo is where it lives.
    OptionsMenu {
        id: trayMenu
        function show(x, y) {
            const t = s => C.Robo.lib.I18n.t(s);
            const go = what => () => {
                trayMenu.close();
                if (what === "quit") { RoboShell.quit(); return; }
                // tray.rs opens the Settings window itself (main.ts's case is never reached).
                if (what === "settings") { C.Robo.lib.Bridge.openSettingsWindow(); return; }
                if (what !== "pause") RoboShell.userOpening = true;
                C.Robo.lib.tray(what);
                RoboShell.userOpening = false;
            };
            // tray.rs: open, recap | wardrobe, settings, pause | quit.
            items = [
                { text: t("Open Ambxst Robo"), onTriggered: go("open") },
                { text: t("Weekly recap"), onTriggered: go("recap") },
                { isSeparator: true },
                // (The wardrobe is the Coucou mascot's: not there for Robo.)
                ...(!C.Robo.lib.RoboCfg.hasWardrobe() ? [] : [{ text: t("Wardrobe…"), onTriggered: go("wardrobe") }]),
                { text: t("Settings…"), onTriggered: go("settings") },
                { text: t("Pause"), onTriggered: go("pause") },
                { isSeparator: true },
                { text: t("Quit"), onTriggered: go("quit") },
            ];
            popup(root, x, y);
        }
    }

    MouseArea {
        id: ma
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
        // Hover wakes a hidden island and keeps a compact one up (the wake strip).
        onContainsMouseChanged: {
            const i = root.island;
            if (!i || C.Robo.state.mode === "expanded") return;
            if (containsMouse) i.fsm.mouseEntered();
            else i.fsm.mouseLeft();
        }
        onClicked: mouse => {
            const onMascot = mouse.x < root.cell && mouse.y < root.cell;
            // The tray menu: a middle click anywhere, or a right click beside the mascot.
            if (mouse.button === Qt.MiddleButton) { trayMenu.show(mouse.x, mouse.y); return; }
            if (mouse.button === Qt.RightButton) {
                if (onMascot) RoboShell.wardrobe();
                else trayMenu.show(mouse.x, mouse.y);
                return;
            }
            RoboShell.toggle();
        }
    }
}
