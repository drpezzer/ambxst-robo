pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import qs.modules.globals
import qs.modules.services
import qs.modules.theme
import qs.modules.robo
import qs.modules.robo.desktop as Dk
import qs.modules.robo.settings as CS

// Robo ↔ Ambxst: the island's "expanded" mode is the notch's dashboard
// open on the Robo tab. Opening it is mirrored both ways:
// - Robo expands on its own (a permission request, a question, a finished
//   task…) → the notch opens on the tab, PASSIVELY: no keyboard, no click-
//   outside catcher, the windows underneath keep working, exactly as Coucou's
//   own island never takes the keyboard (only the chat does).
// - The user opens the tab (SUPER+A, the bar's Robo, a click on the tab) →
//   Robo opens as from its tray's "Open", and the notch behaves as Ambxst's
//   dashboard always does (keyboard, click outside closes).
// - Robo folds (auto-close, Esc, an answered card) → the notch closes; the
//   notch closes or leaves the tab → Robo folds (a waiting card only folds).
Singleton {
    id: root

    /** The tab's index in the dashboard, taken at runtime (-1 until a dashboard exists). */
    property int dashboardTab: -1
    property bool openPending: false
    /** The notch is open on the tab because Robo asked, not the user. */
    property bool passive: false
    /** Set while a user action makes Robo expand, so the notch opens actively. */
    property bool userOpening: false

    /**
     * Port (his ask): what Robo opens by itself — a session finished, a
     * permission, a question — shows just the island (the mascot box) in the
     * notch, not the dashboard with its tabs, the home chat and the chats
     * column. Opening Robo yourself (SUPER+A, the tray, the tab) shows the
     * whole tab, and grows a compact one into it. The dashboard's patched
     * DashboardView sizes the notch from these.
     */
    property bool compact: false
    readonly property bool compactShown: compact && shown
    Binding { target: Robo; property: "compactNotch"; value: root.compactShown }
    /** The island's slot and its live height (RoboTab, while compact). */
    readonly property real compactWidth: 640
    property real compactHeight: 150
    // Kept through the notch's closing animation (it would jump to the
    // dashboard's size), then forgotten for whatever opens the dashboard next.
    Timer { id: compactForget; interval: 600; onTriggered: if (!root.shown) root.compact = false }
    // A card answered in the compact notch (allow, deny, an answer, "answer in
    // terminal"): the popup has done its job and goes at once (the answer's
    // sound plays on; waiting showed the home view and its minis flash past).
    // Upstream goes home and waits for the pointer to leave first, which in a
    // popup the pointer may never have entered: it stayed open.
    property bool hadCard: false
    function watchCard() {
        const has = !!(st && st.pendingApproval);
        if (hadCard && !has && compactShown) compactDone.restart();
        if (has) compactDone.stop();
        hadCard = has;
    }
    Timer {
        id: compactDone
        interval: 0
        onTriggered: {
            if (root.compactShown && root.island && !(root.st && root.st.pendingApproval) && root.st.mode === "expanded")
                root.island.collapse();
        }
    }

    /**
     * Pointers over an open island (RoboTab counts them). A passive notch
     * takes the keyboard while the island is hovered (Y / N on a permission
     * card, typing an answer) and gives it back when the pointer leaves:
     * UnifiedShellPanel's keyboardFocus (mod patch) reads `hoverKeys`. The
     * release waits a moment so the focus change's own pointer leave/enter
     * cannot make it flap.
     */
    property int hoverCount: 0
    property bool hoverKeys: false
    onHoverCountChanged: {
        if (hoverCount > 0) { hoverRelease.stop(); hoverKeys = true; }
        else hoverRelease.restart();
        // Back over the tab: an ordinary notch again (see reachThrough).
        if (hoverCount > 0) { reachThrough = false; overFileManager = false; }
        else if (shown && !windowsQuery.running) windowsQuery.running = true;
    }
    Timer { id: hoverRelease; interval: 120; onTriggered: root.hoverKeys = root.hoverCount > 0 }

    /**
     * The drop page (+ tab and the upload sequence): clicking another window
     * (Thunar, to drag a file from it) must not close the notch, so it behaves
     * like a passive notch there — no click-outside catcher, no focus grab.
     */
    // (His ask, 2026-10-13: the chat page is no longer held open: a click
    // outside closes it like any notch page, and Escape always reaches it.
    // Files still go in by dropping them on the bar's mascot, notch closed.)
    // Port (his bug, 2026-10-15): …except while the pointer is over a file
    // manager (reachThrough, below), so a file can be dragged in from it.
    readonly property bool holdOpen: shown && Robo.rev >= 0 && !!st
        && (st.view === "upload" || st.view === "uploading" || st.view === "choose" || reachThrough)

    /**
     * Port (his bug, 2026-10-15): a file dragged in from Thunar closed the open
     * tab (the drag then reopened it on the notch). Not the island's
     * auto-close: an open notch has the keyboard Exclusive, and Hyprland then
     * sends EVERY pointer event to Ambxst's panel ("forced above all",
     * InputManager::mouseMoveUnified, 0.56), so the press meant for Thunar
     * lands on the panel's full-screen click-outside catcher, which closes
     * the notch on release; Thunar never sees it, no drag starts. A click and
     * the start of a drag can't be told apart before the press reaches the
     * window (Hyprland reports neither), so: while the pointer is over a file
     * manager's window, the open tab lets the pointer through, as `holdOpen`
     * does (no catcher, no focus grab, keyboard on demand), and waits for the
     * file — no click-outside, no auto-close countdown — until the pointer is
     * back over the tab. A click anywhere else still closes it (his
     * 2026-10-13 ask). The cursor comes from the poll below (the mascot's eyes).
     */
    property bool reachThrough: false
    property bool overFileManager: false
    function isFileManager(cls) {
        return /^(thunar|nautilus|org\.gnome\.nautilus|nemo|dolphin|org\.kde\.dolphin|pcmanfm|pcmanfm-qt|caja|spacefm|krusader|org\.kde\.krusader|doublecmd|xfe)$/i.test(String(cls || ""));
    }
    /** Windows on screen, topmost first: { x, y, w, h, fm }. */
    property var screenWindows: []
    Process {
        id: windowsQuery
        command: ["hyprctl", "-j", "--batch", "monitors; clients"]
        stdout: StdioCollector { onStreamFinished: root.readWindows(text) }
    }
    // Refreshed while the pointer is off the tab (windows open and move).
    Timer {
        interval: 1500
        repeat: true
        running: root.shown && root.hoverCount === 0 && !root.reachThrough
        onTriggered: if (!windowsQuery.running) windowsQuery.running = true
    }
    function readWindows(text) {
        try {
            // Two JSON arrays, blank lines between (no raw newline inside a JSON string).
            const parts = String(text).split(/\n\s*\n(?=\[)/);
            const mons = JSON.parse(parts[0]);
            const clients = JSON.parse(parts[1]);
            const onScreen = {};
            for (const m of mons) {
                if (m.activeWorkspace) onScreen[m.activeWorkspace.id] = 1;
                if (m.specialWorkspace && m.specialWorkspace.id) onScreen[m.specialWorkspace.id] = 2;
            }
            const list = [];
            for (const c of clients) {
                const vis = c.workspace ? onScreen[c.workspace.id] : undefined;
                if (!vis || c.hidden || c.mapped === false || !c.at || !c.size) continue;
                list.push({ x: c.at[0], y: c.at[1], w: c.size[0], h: c.size[1], fm: isFileManager(c.class),
                            layer: (vis === 2 ? 4 : 0) + (c.pinned ? 2 : 0) + (c.floating ? 1 : 0),
                            recent: Number(c.focusHistoryID) || 0 });
            }
            list.sort((a, b) => b.layer - a.layer || a.recent - b.recent);
            screenWindows = list;
        } catch (e) {
            screenWindows = [];
        }
    }
    function fileManagerAt(gx, gy) {
        for (const w of screenWindows)
            if (gx >= w.x && gx < w.x + w.w && gy >= w.y && gy < w.y + w.h) return w.fm;
        return false;
    }
    function trackReach(gx, gy) {
        const over = shown && hoverCount === 0 && fileManagerAt(gx, gy);
        if (over === overFileManager) return;
        overFileManager = over;
        if (over) {
            reachThrough = true;
            if (island) island.fsm.cancelTimers();
        } else if (reachThrough && island && !island.wasInIsland && st.mode === "expanded") {
            // Off the file manager (and not on the tab): the auto-close counts
            // again (a drag reaching the island stops it, island.ts).
            island.fsm.mouseLeft();
        }
    }

    readonly property bool shown: Visibilities.currentActiveModule === "dashboard"
        && dashboardTab >= 0 && GlobalStates.dashboardCurrentTab === dashboardTab

    /**
     * Port (performance): the dashboard is open on this screen (Visibilities'
     * own per-screen flag). Dashboard.qml builds the Robo tab only there
     * (ambxst-robo.patch): its open flag is the same on every screen.
     */
    function dashboardOn(screenName) {
        const s = screenName ? Visibilities.getForScreen(screenName) : null;
        return !s || s.dashboard === true;
    }

    readonly property var island: Robo.island
    readonly property var st: Robo.state

    /**
     * Settings → "Island lives on": a saved `at:<x>,<y>|<name>|<w>x<h>` display,
     * matched like island.rs (same origin + name, same name + size, the name if
     * unique, same origin). "primary"/"cursor"/unplugged → the focused screen
     * (Hyprland has no primary output; Ambxst's notch follows focus).
     */
    function islandScreenName() {
        const saved = st && st.settings ? String(st.settings.screen || "") : "";
        if (!saved.startsWith("at:")) return "";
        const [place, name, size] = saved.split("|");
        const list = Quickshell.screens;
        const all = [];
        for (let i = 0; i < list.length; i++) all.push(list[i]);
        const origin = s => "at:" + s.x + "," + s.y;
        const dims = s => s.width + "x" + s.height;
        let hit = all.find(s => origin(s) === place && s.name === name)
            || all.find(s => s.name === name && dims(s) === size);
        if (!hit) {
            const named = all.filter(s => s.name === name);
            if (named.length === 1) hit = named[0];
        }
        if (!hit) hit = all.find(s => origin(s) === place);
        return hit ? hit.name : "";
    }
    function showTab(isPassive) {
        passive = isPassive;
        // Compact only when Robo opens the notch by itself; never shrinks a
        // tab the user already has open.
        compactForget.stop();
        if (!isPassive) compact = false;
        else if (Visibilities.currentActiveModule !== "dashboard") compact = true;
        if (dashboardTab >= 0) GlobalStates.dashboardCurrentTab = dashboardTab;
        else openPending = true;
        if (Visibilities.currentActiveModule === "dashboard") return;
        const target = islandScreenName();
        const focused = Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : "";
        if (target && target !== focused) {
            Visibilities.clearAll();
            Visibilities.currentActiveModule = "dashboard";
            Visibilities.applyActiveModuleToScreen(target);
            Visibilities.lastFocusedScreen = target;
        } else {
            Visibilities.setActiveModule("dashboard");
        }
    }
    function hideTab() {
        if (shown) Visibilities.setActiveModule("");
        passive = false;
        compactForget.restart();
    }

    /**
     * Quit (tray): Robo is gone until started again — ambxst-robo stops, the
     * bar shows the Ambxst logo again. SUPER+A / `ambxst run ambxst-robo` starts it.
     */
    property bool quitted: false
    /** Temporary (bar slide investigation): takes Robo's bar slot out, nothing else. */
    property bool barTestHidden: false
    function quit() {
        hideTab();
        quitted = true;
        Robo.lib.Bridge.quit();
    }
    Process { id: startCore; command: ["systemctl", "--user", "start", "ambxst-robo.service"] }

    /** SUPER+A / `ambxst run ambxst-robo`: open on Robo, or fold it. */
    function toggle() {
        if (quitted) {
            quitted = false;
            startCore.running = true;
            return;
        }
        if (!island) return;
        // A compact alert: SUPER+A opens the whole tab around it.
        if (shown && compact) {
            open();
            return;
        }
        if (shown) {
            // Folds Robo (a waiting card is only folded); the mode change closes the notch.
            island.collapse();
            if (shown) hideTab();
            return;
        }
        open();
    }
    function open() {
        if (!island) return;
        // Port (his ask): from the finished popup the whole tab opens on that
        // session's chat, with a reply already being typed in its field.
        const toChat = compactShown && st.view === "finished" && Robo.finishedSession !== "";
        userOpening = true;
        if (st.paused) { st.paused = false; Robo.lib.Bridge.setPaused(false); }
        // His ask: with a chat going (its mini up), straight to its page.
        const chat = Robo.lib.ChatView.chat();
        const chatOn = chat.conv !== "" && st.tasks.some(x => x.id === "agent_" + chat.conv);
        if (st.mode === "expanded") showTab(false);
        else island.alert(chatOn && !st.pendingApproval ? "prompt" : st.defaultView());
        userOpening = false;
        showTab(false);
        if (toChat) openFinishedChat();
    }
    function openFinishedChat() {
        const sid = Robo.finishedSession;
        const draft = Robo.finishedDraft;
        Robo.finishedDraft = "";
        if (draft.trim() !== "") Robo.chatDrafts["chat"] = draft;
        const show = () => {
            if (!island) return;
            island.setView("prompt");
            Qt.callLater(() => Robo.lib.ChatView.chat().focusViews());
        };
        // A chat conversation's popup goes back to that conversation.
        const conv = Robo.lib.Finished.convOf(sid);
        if (conv !== "") Robo.lib.ChatView.chat().openConv(conv).then(show, show);
        else Robo.lib.ChatHistory.history().open("claude", sid).then(show, show);
    }
    /** Right-click on the bar's mascot: upstream's wardrobe toggle. */
    function wardrobe() {
        if (!island) return;
        userOpening = true;
        if (st.mode === "hidden") island.wardrobeAnywhere();
        else island.toggleWardrobe();
        userOpening = false;
        if (st.mode === "expanded") showTab(false);
    }

    Connections {
        target: Robo
        function onRevChanged() { root.watchCard(); }
        // A file dragged over the closed notch: the whole tab, as SUPER+A opens it.
        function onOpenTabRequested() { if (!root.shown || root.compact || root.passive) root.open(); }
        function onModeChanged(mode, prev) {
            if (mode === "expanded") {
                if (!root.shown) root.showTab(!root.userOpening);
            } else if (prev === "expanded") {
                root.hideTab();
            }
        }
        function onWindowCommand(cmd, args) {
            if (cmd === "shortcuts_suspend") { root.suspended = !!(args && args.suspended); root.lastBindKey = ""; bindLater.restart(); }
        }
        // The chat takes the keyboard: a passive notch becomes an ordinary one.
        function onKeyboardWanted(on) {
            if (on && root.passive) root.passive = false;
        }
    }

    // The notch closed or moved to another tab/module while Robo was open.
    onShownChanged: {
        // A carry out of the notch loses its pointer grab with the notch.
        if (!shown && desktopMascot.win) desktopMascot.win.grabLost();
        // Where the windows are, before the pointer goes to fetch a file (reachThrough).
        if (shown && !windowsQuery.running) windowsQuery.running = true;
        if (!island) return;
        if (shown && quitted) {
            // The tab is the way back after Quit, like launching Robo again.
            quitted = false;
            startCore.running = true;
        }
        if (shown) {
            // His first open of the tab since the shell started: the launch
            // greeting (RoboTab stages it over the whole tab).
            // (RoboTab starts it once it is actually on screen.)
            if (Robo.greetPending && !passive && !st.mascotOnDesktop && !st.pendingApproval) return;
            // Opened by a click on the tab: Robo opens as from the tray.
            if (st.mode !== "expanded") {
                userOpening = true;
                island.alert(st.defaultView());
                userOpening = false;
            }
        } else {
            passive = false;
            reachThrough = false;
            overFileManager = false;
            compactForget.restart();
            if (st.mode === "expanded") island.collapse();
        }
    }

    // ── Coucou's global shortcuts (upstream registers them at launch; Rust
    // shortcuts.rs) as Hyprland binds that run `ambxst-robo --shortcut <id>`,
    // which emits the same `shortcut` event a key press did. Rebuilt from
    // settings.shortcuts whenever they change, and after a Hyprland reload.
    property var boundKeys: []
    property string lastBindKey: ""
    // Upstream's accelerator ("Ctrl+Alt+PageUp") → a Hyprland bind ("CTRL + ALT + Page_Up"):
    // parsed by upstream's parseKeys, key names mapped like portal.rs keysym().
    readonly property var keysyms: ({
        Space: "space", Enter: "Return", Tab: "Tab", Backspace: "BackSpace", Delete: "Delete",
        Insert: "Insert", Home: "Home", End: "End", PageUp: "Page_Up", PageDown: "Page_Down",
        Up: "Up", Down: "Down", Left: "Left", Right: "Right", Comma: "comma", Period: "period",
        Slash: "slash", Semicolon: "semicolon", Quote: "apostrophe", Backquote: "grave",
        BracketLeft: "bracketleft", BracketRight: "bracketright", Backslash: "backslash",
        Minus: "minus", Equal: "equal",
    })
    function hyprKeys(accel) {
        const c = Robo.lib.Shortcuts.parseKeys(String(accel));
        if (!c) return "";
        const out = [];
        if (c.ctrl) out.push("CTRL");
        if (c.alt) out.push("ALT");
        if (c.shift) out.push("SHIFT");
        if (c.meta) out.push("SUPER");
        out.push(keysyms[c.key] || (c.key.length === 1 ? c.key.toLowerCase() : c.key));
        return out.join(" + ");
    }
    /** shortcuts_suspend (Settings is recording a new combo): let go of every bind. */
    property bool suspended: false
    function applyShortcuts() {
        if (!st || !Robo.lib) return;
        const defs = Robo.lib.Shortcuts.SHORTCUTS;
        const stored = st.settings.shortcuts || {};
        const want = [];
        const taken = {};
        for (const d of defs) {
            if (!d.ported || roboSettings.recordingShortcut || root.suspended) continue;
            const b = Robo.lib.Shortcuts.effective(d, stored);
            if (!b.enabled || !b.keys) continue;
            const keys = hyprKeys(b.keys);
            // Invalid, or the same keys as an earlier action ("Used twice"): upstream registers the first only.
            if (!keys || taken[keys]) continue;
            taken[keys] = true;
            want.push({ id: d.id, keys: keys });
        }
        const key = JSON.stringify(want);
        if (key === lastBindKey) return;
        lastBindKey = key;
        // The desktop mascot's own flights and fades must not fight a layer open animation.
        let lua = 'hl.layer_rule({ no_anim = true, match = { namespace = "ambxst-robo-mascot" } });';
        for (const k of boundKeys) lua += "pcall(hl.unbind, " + JSON.stringify(k) + ");";
        for (const w of want)
            lua += "hl.bind(" + JSON.stringify(w.keys) + ", hl.dsp.exec_cmd(" + JSON.stringify("ambxst-robo --shortcut " + w.id) + "));";
        boundKeys = want.map(w => w.keys);
        bindProc.command = ["hyprctl", "eval", lua];
        bindProc.running = true;
    }
    Process { id: bindProc }
    Timer { id: bindLater; interval: 300; onTriggered: root.applyShortcuts() }
    Connections {
        target: Robo
        function onRevChanged() { if (!bindLater.running) bindLater.start(); }
    }
    Connections {
        target: Hyprland
        function onRawEvent(event) {
            if (event.name === "configreloaded") { root.lastBindKey = ""; root.boundKeys = []; bindLater.restart(); }
        }
    }
    Component.onCompleted: bindLater.start()

    // Robo's Settings window (opened from the island's "Settings…" link).
    // Port (his ask): the music pill follows Ambxst's media player.
    RoboMedia {}

    CS.RoboSettings {
        id: roboSettings
        // Upstream lets go of its key grabs while a new shortcut is recorded.
        onRecordingShortcutChanged: { root.lastBindKey = ""; bindLater.restart(); }
    }

    // The mascot on the desktop: his windows on every display; flights start and end
    // at the notch's display (the focused monitor), created at start so the
    // island finds it at boot.
    Dk.RoboDesktop {
        id: desktopMascot
        islandScreen: {
            void Robo.rev;
            const name = root.islandScreenName() || (Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : "");
            // Index loop: array methods on a QML list crash V4 on this Qt.
            const list = Quickshell.screens;
            for (let i = 0; i < list.length; i++) if (list[i].name === name) return list[i];
            return list.length ? list[0] : null;
        }
        notchNear: near => root.mascotNearNotch(near)
        homeTarget: () => root.mascotHomeTarget()
        keepAbove: {
            void Robo.rev;
            return !!(root.st && root.st.settings && root.st.settings.keepMascotAboveFullscreen);
        }
    }
    // Port (his ask, a switch in Settings, off by default): the mascot's state
    // colours and their glow from the matugen palette (Colors), kept in step
    // with wallpaper changes. Keyed as a string so it re-applies only when a
    // colour (or the switch) really changes.
    readonly property string processPaletteKey: {
        void Robo.rev;
        if (!(st && st.settings && st.settings.processColorsMatugen)) return "";
        const hex = c => { const s = String(c); return s.length === 9 ? "#" + s.slice(3) : s; };
        return JSON.stringify({
            working: hex(Colors.blue), thinking: hex(Colors.magenta), searching: hex(Colors.primary),
            approval: hex(Colors.yellow), question: hex(Colors.cyan), error: hex(Colors.red),
            finished: hex(Colors.green), ratelimit: hex(Colors.lightYellow), sleeping: hex(Colors.outline),
            dizzy: hex(Colors.lightMagenta),
        });
    }
    onProcessPaletteKeyChanged: applyProcessPalette()
    function applyProcessPalette() {
        if (!Robo.lib) return;
        Robo.lib.Palette.setProcessPalette(processPaletteKey ? JSON.parse(processPaletteKey) : null);
        if (island) { island.dirty = true; island.ensureRunning(); }
        Robo.rev++;
    }

    /**
     * Where the island's mascot is drawn now, for the desktop mascot's flights:
     * the open Robo tab's, else the bar's on the notch's display (any bar's).
     */
    function mascotHomeTarget() {
        const ok = c => c && isFinite(c.x) && isFinite(c.y) && c.size > 0;
        if (shown) {
            for (let i = 0; i < islands.length; i++) {
                const isl = islands[i];
                if (!isl || !isl.live || typeof isl.mascotCentre !== "function") continue;
                const c = isl.mascotCentre();
                if (ok(c)) return c;
            }
        }
        const scr = desktopMascot.islandScreen ? desktopMascot.islandScreen.name : "";
        let any = null;
        for (let i = 0; i < bars.length; i++) {
            const b = bars[i];
            if (!b || !b.visible) continue;
            const c = b.mascotCentre();
            if (!ok(c)) continue;
            if (c.screen === scr) return c;
            if (!any) any = c;
        }
        return any;
    }
    /** For NotchMascotProxy (patched into Ambxst's shell panel). */
    readonly property var desktop: desktopMascot

    // A drag of the desktop mascot near the notch opens it, passively (the
    // keyboard stays where it is), so he can be dropped in to go home; it folds
    // again when he is taken away, or once he is home.
    property bool openedForMascot: false
    function mascotNearNotch(near) {
        if (near) {
            mascotFold.stop();
            if (!island || quitted || shown || st.mode === "expanded") return;
            openedForMascot = true;
            island.alert(st.defaultView());
            return;
        }
        if (openedForMascot) mascotFold.restart();
    }
    Timer {
        id: mascotFold
        interval: 1200
        onTriggered: {
            const w = desktopMascot.win;
            if (w && w.shown && !w.landed) { restart(); return; } // still flying home
            if (root.openedForMascot && root.shown && root.passive && root.island) root.island.collapse();
            root.openedForMascot = false;
        }
    }

    // `qs ipc call ambxst-robo <fn>`: scripts (and checks) can drive Robo.
    IpcHandler {
        target: "ambxst-robo"
        function toggle(): void { root.toggle(); }
        function open(): void { root.open(); }
        function wardrobe(): void { root.wardrobe(); }
        function tray(what: string): void { Robo.lib.tray(what); }
        function view(name: string): void { if (root.island) root.island.setView(name); }
        function emote(name: string): void { if (root.island) root.island.emote(name); }
        function decide(d: string): void { if (root.island) root.island.actions.decide(d); }
        function answer(json: string): void { if (root.island) root.island.actions.answer(JSON.parse(json)); }
        function settingsWindow(section: string): void { roboSettings.open(section); }
        // Port: the island's pills (id, name, state, conversation), for diagnosis.
        function pills(): string { return JSON.stringify({ focus: Robo.lib.State.focusId, tasks: Robo.lib.State.tasks.map(t => ({ id: t.id, name: t.name, state: t.state, conv: t.conv || null, convKey: t.convKey || null, session: t.sessionId || null, cwd: t.sessionCwd || null })) }); }
        // Port: what the music pill sees (shell/RoboMedia.qml → lib/media.ts).
        function media(): string { return JSON.stringify({ player: Robo.lib.Media.playerName, state: Robo.lib.Spotify.Spotify.state, pillOn: Robo.lib.State.settings.activeIntegrations.indexOf("integration_spotify") >= 0 }); }
        function openTerminal(): void { if (root.island) root.island.actions.openTerminal(); }
        function desktopState(): string { return desktopMascot.debugState(); }
        function barTest(hide: bool): void { root.barTestHidden = hide; }
        function debugCarry(phase: string, x: real, y: real): void {
            const d = root.island ? root.island.desktop : null;
            if (!d) return;
            if (phase === "pick") d.pickUp(x, y); else if (phase === "carry") d.carry(x, y); else d.carryEnd(x, y);
        }
        function pressEscape(): void { if (root.island) root.island.escape(); }
        function state(): string {
            const s = root.st;
            if (!s) return "{}";
            return JSON.stringify({
                mode: s.mode, view: s.view, fsm: root.island ? root.island.fsm.state : null,
                shown: root.shown, passive: root.passive, pinned: s.isPinned, paused: s.paused,
                focus: s.focusId, effectiveState: s.effectiveState, mascotOnDesktop: s.mascotOnDesktop,
                pending: s.pendingApproval, core: Robo.coreConnected,
                tasks: s.tasks.map(t => ({ id: t.id, name: t.name, state: t.state, steps: t.steps.length, last: t.steps[t.steps.length - 1] || null, badge: t.pillBadge || null })),
            });
        }
    }

    // ── Global cursor (Hyprland) for the mascot's eyes ─────────────────────────────
    // Upstream's Linux build only knows the cursor over the island, so off it
    // the mascot stares up-left; Mac/Windows follow the cursor everywhere. Hyprland
    // tells us, so: polled ~30 times a second, only while the mascot animates.
    property var islands: []
    property var bars: []
    Socket {
        id: hyprCursor
        property real cx: 0
        property real cy: 0
        path: (Quickshell.env("XDG_RUNTIME_DIR") || "") + "/hypr/" + (Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE") || "") + "/.socket.sock"
        parser: SplitParser {
            onRead: line => {
                const m = /"([xy])":\s*(-?[\d.]+)/.exec(line);
                if (m) {
                    if (m[1] === "x") hyprCursor.cx = +m[2];
                    else hyprCursor.cy = +m[2];
                    return;
                }
                if (line.trim() !== "}") return;
                hyprCursor.connected = false;
                root.cursorAt(hyprCursor.cx, hyprCursor.cy);
            }
        }
        onConnectionStateChanged: if (connected) { write("j/cursorpos"); flush(); }
    }
    /** A Robo tab is on screen (its notch open): the poll wakes the loop on cursor moves. */
    property int liveTabs: 0
    readonly property bool tabLive: liveTabs > 0
    /**
     * Port (performance): the bar's mascot wants the cursor: the loop runs, a
     * bar draws it (RoboBar `lead`: the focused screen's, in place), and he
     * follows the pointer now (Robo asleep, working or thinking does not).
     * (Read again each frame step: the mascot's state is the lib's.)
     */
    readonly property bool barLooks: Robo.frameTick >= 0 && Robo.frameWanted && Robo.barSources > 0
        && !!island && island.wantsPointer()
    Timer {
        // 30 Hz for the open tab's mascot; the bar's tiny one only needs 10.
        interval: root.tabLive ? 33 : 100
        repeat: true
        running: !!Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE") && !!island && !!st
            && ((!st.mascotOnDesktop && st.mode !== "hidden" && (root.tabLive || root.barLooks))
                || ((Robo.frameWanted || root.tabLive) && root.shown && root.hoverCount === 0)) // (or reachThrough's)
        onTriggered: if (!hyprCursor.connected) hyprCursor.connected = true
        onRunningChanged: if (!running && root.island) root.island.lookOverride = null
    }

    // ── Which screen's bar animates (RoboBar `lead`) ──────────────────────────
    // Port (performance): every bar repaint redraws (and Hyprland re-blurs) its
    // screen-sized surface: only the focused monitor's bar moves; the others
    // hold their last frame (redrawn when the state changes).
    readonly property string focusedScreen: Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : ""
    /** Screens with a bar in place: { name: true }. */
    /** The bars in place, each by its own key (two per screen, one of them hidden): { key: screen }. */
    property var steadyBars: ({})
    property int barKeys: 0
    function newBarKey() { return "bar" + (++barKeys); }
    function setBarSteady(key, name, on) {
        if (!key || (on ? steadyBars[key] === name : !(key in steadyBars))) return;
        const s = Object.assign({}, steadyBars);
        if (on && name) s[key] = name;
        else delete s[key];
        steadyBars = s;
    }
    readonly property string leadBarScreen: {
        const s = steadyBars, f = focusedScreen;
        if (f) return f;
        const k = Object.values(s).sort();
        return k.length ? k[0] : "";
    }
    property real lastGx: NaN
    property real lastGy: NaN
    function cursorAt(gx, gy) {
        if (!island) return;
        // While the loop sleeps, only a real move wakes it (the poll goes on
        // while a tab shows; upstream's webview gets mousemoves the same way).
        const moved = gx !== lastGx || gy !== lastGy;
        lastGx = gx; lastGy = gy;
        if (moved) trackReach(gx, gy);
        if (st.mascotOnDesktop) return; // (polled for trackReach only)
        if (!moved && !Robo.frameWanted) return;
        // The open island (the Robo tab on screen) reads it as upstream does.
        let fed = false;
        for (let i = 0; i < islands.length; i++) {
            const isl = islands[i];
            if (isl && isl.live) { isl.feedGlobalCursor(gx, gy); fed = true; }
        }
        if (fed && st.mode === "expanded") { island.lookOverride = null; return; }
        // Otherwise the bar's mascot: from the bar on the cursor's screen.
        const mon = Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : "";
        let bar = null;
        for (let i = 0; i < bars.length; i++) {
            const b = bars[i];
            if (!b || !b.visible) continue;
            if (!bar) bar = b;
            if (b.mascotCentre().screen === mon) { bar = b; break; }
        }
        if (!bar) { island.lookOverride = null; return; }
        const c = bar.mascotCentre();
        island.lookOverride = { x: Math.tanh((gx - c.x) / 260), y: -Math.tanh((gy - c.y) / 200) };
    }
}
