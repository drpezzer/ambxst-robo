import QtQuick
import qs.modules.robo as C
import qs.modules.robo.shell
import qs.modules.robo.views as V

// The dashboard's Robo tab (layout A): Robo's open island at the top-left
// of the tab's content area, his extras around it (RoboTabExtras).
FocusScope {
    id: root
    implicitWidth: 640

    // Clicks nothing in the island takes (the mascot, empty card space) would fall
    // through to Ambxst's click-outside backdrop and close the notch. This
    // catches them under the island; the island's passive press handler still
    // sees every press (slaps, dizzy, drag out).
    MouseArea {
        anchors.fill: parent
        z: -1
        acceptedButtons: Qt.AllButtons
    }

    // Port (his ask): the launch greeting, staged over the whole tab. While it
    // plays a card fills the tab, the island centred on it (the greeting and
    // the mascot in the middle) and everything else hidden. When it ends the card
    // shrinks into the mascot card's place and the island glides back to its
    // corner (the mascot to his spot); then the header, the cards, the home chat and
    // the chats column fade in and the stand-in card goes.
    readonly property bool greeting: C.Robo.rev >= 0 && C.Robo.state.mode === "expanded" && C.Robo.state.view === "greeting"
    /** "" | "greet" | "settle" | "reveal" */
    property string intro: ""
    onGreetingChanged: {
        if (greeting) {
            intro = "greet";
            revealAnim.stop();
            C.Robo.introBoxes = 0;
            C.Robo.introText = 0;
        } else if (intro === "greet") {
            intro = "settle";
            settleTimer.restart();
        }
    }
    onIntroChanged: {
        if (intro === "") { C.Robo.introBoxes = 1; C.Robo.introText = 1; }
    }
    Timer { id: settleTimer; interval: 320; onTriggered: { root.intro = "reveal"; revealTimer.restart(); revealAnim.restart(); } }
    Timer { id: revealTimer; interval: 620; onTriggered: root.intro = "" }
    // The reveal: the boxes slide in from their sides and fade in together,
    // then the text lifts in with a little bounce (Coucou's own reveal
    // values: C.Robo.introBoxes / introText, read by the views).
    ParallelAnimation {
        id: revealAnim
        NumberAnimation { target: C.Robo; property: "introBoxes"; from: 0; to: 1; duration: 420; easing.type: Easing.BezierSpline; easing.bezierCurve: C.RoboTheme.easeOut }
        SequentialAnimation {
            PauseAnimation { duration: 80 }
            NumberAnimation { target: C.Robo; property: "introText"; from: 0; to: 1; duration: 480; easing.type: Easing.OutBack; easing.overshoot: 1.6 }
        }
    }
    readonly property bool staged: intro === "greet" || intro === "settle"
    /** The mascot card (OverviewView's left card) in the tab, island at its corner. */
    // A fixed target (the overview island is 160 tall): bound to the island's
    // animating height it restarted its shrink every frame and hardly moved.
    readonly property rect mascotCard: Qt.rect(10, 42, 322, 160 - 52)

    Rectangle {
        id: stage
        z: 1
        visible: opacity > 0
        opacity: root.intro === "" ? 0 : 1
        x: root.intro === "greet" ? 0 : root.mascotCard.x
        y: root.intro === "greet" ? 0 : root.mascotCard.y
        width: root.intro === "greet" ? root.width : root.mascotCard.width
        height: root.intro === "greet" ? root.height : root.mascotCard.height
        // style.css .card, as the card it becomes.
        radius: 20
        color: C.RoboTheme.card
        border.width: 1
        border.color: Qt.tint(C.RoboTheme.card, C.RoboTheme.hairline)
        Behavior on x { enabled: root.intro !== "greet"; NumberAnimation { duration: 300; easing.type: Easing.BezierSpline; easing.bezierCurve: C.RoboTheme.easeInOut } }
        Behavior on y { enabled: root.intro !== "greet"; NumberAnimation { duration: 300; easing.type: Easing.BezierSpline; easing.bezierCurve: C.RoboTheme.easeInOut } }
        Behavior on width { enabled: root.intro !== "greet"; NumberAnimation { duration: 300; easing.type: Easing.BezierSpline; easing.bezierCurve: C.RoboTheme.easeInOut } }
        Behavior on height { enabled: root.intro !== "greet"; NumberAnimation { duration: 300; easing.type: Easing.BezierSpline; easing.bezierCurve: C.RoboTheme.easeInOut } }
        Behavior on opacity { enabled: root.intro !== "greet"; NumberAnimation { duration: 260; easing.type: Easing.BezierSpline; easing.bezierCurve: C.RoboTheme.easeOut } }
    }

    C.RoboIsland {
        id: isl
        z: 2
        // The greeting canvas (640 x 150 at the island's top) centred on the tab.
        x: root.intro === "greet" ? Math.max(0, Math.round((root.width - 640) / 2)) : 0
        y: root.intro === "greet" ? Math.max(0, Math.round((root.height - 150) / 2)) : 0
        // The greeting's burst fills the whole tab: its canvas grows by the
        // island's offset on each side, unclipped (RoboIsland).
        greetStage: root.intro === "greet"
        greetPadX: root.intro === "greet" ? x : 0
        greetPadY: root.intro === "greet" ? y : 0
        introFade: root.staged ? 0 : 1
        Behavior on x {
            enabled: root.intro !== "greet"
            NumberAnimation { duration: 300; easing.type: Easing.BezierSpline; easing.bezierCurve: C.RoboTheme.easeInOut }
        }
        Behavior on y {
            enabled: root.intro !== "greet"
            NumberAnimation { duration: 300; easing.type: Easing.BezierSpline; easing.bezierCurve: C.RoboTheme.easeInOut }
        }
        live: root.visible
        /**
         * The island mascot's body: centre (global, like feedGlobalCursor) and
         * body box (bot.size), where the desktop mascot lands when he flies home.
         */
        function mascotCentre() {
            const i = isl.island;
            if (!i || !i.bot) return null;
            const b = i.bot;
            const over = C.Robo.lib ? C.Robo.lib.BOT_OVERHANG : 40;
            const p = isl.mapToItem(null, (640 - isl.islandW) / 2 + b.left + b.w / 2, b.top + over + b.size / 2);
            return { x: p.x + Screen.virtualX, y: p.y + Screen.virtualY, size: b.size, screen: Screen.name };
        }
        // The pointer over the island: a passive notch takes the keyboard meanwhile.
        HoverHandler { id: keysHover }
        Component.onCompleted: RoboShell.islands.push(isl)
        Component.onDestruction: {
            const i = RoboShell.islands.indexOf(isl);
            if (i >= 0) RoboShell.islands.splice(i, 1);
        }
    }

    // His extras in the spare room: the home chat under the island, the chats
    // column on its right (the tab keeps the dashboard's own size).
    C.RoboTabExtras {
        anchors.fill: parent
        islandItem: isl
        keyTarget: root
        // Port (his ask): an alert Robo raised itself shows just the island
        // (RoboShell.compact); opened into the whole tab, these fade in.
        opacity: root.compact ? 0 : 1
        visible: opacity > 0
        Behavior on opacity { NumberAnimation { duration: 220; easing.type: Easing.BezierSpline; easing.bezierCurve: C.RoboTheme.easeOut } }
    }

    // Port (zero-touch install): the daemon's setup or update, and the
    // one-time offer to connect Claude Code, over the top of the home chat.
    Item {
        x: 10
        y: Math.round(isl.islandH) + 4
        width: 640 - 20
        height: banner.implicitHeight
        z: 11
        visible: !root.compact && !root.staged
        V.CoreBanner { id: banner; width: parent.width }
    }

    /** Port: the notch shows only the island (RoboShell.compact). */
    readonly property bool compact: RoboShell.compactShown
    // Port (his ask): there, a click on the mascot opens the whole tab.
    function syncBotClick() {
        if (isl.island) isl.island.botClickOpens = root.compact ? () => RoboShell.open() : null;
    }
    onCompactChanged: syncBotClick()
    Item {
        Component.onCompleted: root.syncBotClick()
        Component.onDestruction: if (isl.island) isl.island.botClickOpens = null
    }
    Connections {
        target: isl
        function onIslandChanged() { root.syncBotClick(); }
    }
    // The notch follows the island's height while compact (DashboardView).
    Binding {
        target: RoboShell
        property: "compactHeight"
        value: Math.max(60, Math.ceil(C.Robo.compactTargetH > 0 ? C.Robo.compactTargetH : isl.islandH))
        when: root.visible
    }

    // Port (his ask): the whole open tab takes a dragged file (the island's
    // own DropArea, on top, where it is): the chat's drop look stays on
    // across the home chat and the chats column, and a drop there counts.
    C.RoboDropArea {
        anchors.fill: parent
        z: -1
    }

    // Port (his ask: multitasking): a conversation's mini carried over the tab.
    V.ConvDrag {
        anchors.fill: parent
        z: 10
    }

    // Keys typed into the island go to upstream's window listeners (shortcuts,
    // the diff's Escape…), then to the island's own Escape handling.
    focus: true
    Keys.onPressed: event => {
        if (C.Robo.dispatchKey(event)) event.accepted = true;
    }
    onVisibleChanged: {
        if (visible && !RoboShell.passive) forceActiveFocus();
        if (visible) reclaimWindow.restart();
        if (visible) greetIfPending();
    }
    // His first open of the tab since the shell started: the launch greeting,
    // started only once the tab is on screen (started while it was still
    // hidden it got no frames and showed nothing).
    function greetIfPending() {
        const st = C.Robo.state;
        if (!C.Robo.greetPending || !C.Robo.island || RoboShell.passive || st.mascotOnDesktop || st.pendingApproval) return;
        C.Robo.greetPending = false;
        Qt.callLater(() => { if (root.visible && C.Robo.island) C.Robo.island.launchInTab(); });
    }

    // Hovering the island counts towards RoboShell.hoverKeys (the passive
    // notch's keyboard); the keys then land here, in Keys.onPressed.
    readonly property bool hoverWants: keysHover.hovered && visible
    property bool hoverCounted: false
    onHoverWantsChanged: {
        if (hoverWants === hoverCounted) return;
        hoverCounted = hoverWants;
        RoboShell.hoverCount += hoverWants ? 1 : -1;
        if (hoverWants && !activeFocus) forceActiveFocus();
    }
    Component.onDestruction: {
        // A reveal cut short (the notch closed) must not leave the views hidden.
        C.Robo.introBoxes = 1;
        C.Robo.introText = 1;
        if (hoverCounted) RoboShell.hoverCount -= 1;
        if (liveCounted) RoboShell.liveTabs -= 1;
    }
    // On screen: RoboShell polls the cursor meanwhile (the mascot's eyes, the loop's wake-up).
    property bool liveCounted: false
    readonly property bool liveWants: visible
    onLiveWantsChanged: {
        if (liveWants === liveCounted) return;
        liveCounted = liveWants;
        RoboShell.liveTabs += liveWants ? 1 : -1;
    }
    Component.onCompleted: {
        if (liveWants && !liveCounted) { liveCounted = true; RoboShell.liveTabs += 1; }
        // The greeting may have started before this tab was built.
        if (greeting) {
            intro = "greet";
            C.Robo.introBoxes = 0;
            C.Robo.introText = 0;
        }
        if (visible) greetIfPending();
    }
    readonly property var winFocus: Window.activeFocusItem
    // The dashboard takes the keyboard back when the notch opens (its own
    // view gets focus after this tab did): while Robo is the tab showing,
    // keys belong to the island, as in Coucou's own window.
    // Only just after the tab shows: a press on a dashboard tab button takes the
    // focus too, and taking it back cancelled that button's click.
    function holds(it) { for (let i = it; i; i = i.parent) if (i === root) return true; return false; }
    onWinFocusChanged: {
        if (visible && reclaimWindow.running && winFocus && !holds(winFocus)) Qt.callLater(() => { if (root.visible && !root.holds(root.winFocus)) root.forceActiveFocus(); });
    }
    Timer { id: reclaimWindow; interval: 400 }
    readonly property bool winActiveNow: Window.active
    onWinActiveNowChanged: if (winActiveNow && visible) reclaimWindow.restart()
    Connections {
        target: RoboShell
        function onPassiveChanged() { if (root.visible && !RoboShell.passive) root.forceActiveFocus(); }
    }
}
