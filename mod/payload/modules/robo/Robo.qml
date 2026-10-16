pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import QtMultimedia
import Quickshell
import Quickshell.Io
import "robo-lib.js" as L

// Ambxst Robo: hosts Coucou's island logic (robo-lib.js, bundled
// from upstream windows/src untouched) and connects it to ambxst-robo, the
// headless Rust backend, over $XDG_RUNTIME_DIR/ambxst-robo-core.sock.
//
// QML reads `lib.State` / `island` directly; `rev` bumps on every
// State.notify() so bindings that read State can depend on it.
Singleton {
    id: root

    readonly property var lib: L.RoboLib
    readonly property var host: L.__host
    property var island: null
    /** Port: the launch greeting waits for his first open of the Robo tab. */
    property bool greetPending: false
    /**
     * Port: the tab's launch reveal (RoboTab), 0 → 1: `introBoxes` slides the
     * boxes in from their sides, `introText` lifts the text in after them.
     * 1 outside of it.
     */
    property real introBoxes: 1
    property real introText: 1
    /** Port: the chat fields' unsent text per view ("prompt", "home"), kept across tab unloads. */
    property var chatDrafts: ({})
    /**
     * Port (his ask: multitasking): a conversation's mini hovered or carried
     * brings its card in the chats column into view, glowing ("kind:id").
     */
    property string convFocusKey: ""
    /** Port (his ask): something wants the whole tab open (a file dragged over the notch); RoboShell does it. */
    signal openTabRequested()
    /** Port (his ask): the conversation whose mini is under the pointer (its glow shows). */
    property string hoverConv: ""
    /** Port (his ask): the chat card's glow: the hovered mini's chat, else the open chat's colour. */
    readonly property string chatWash: {
        void rev;
        if (!lib || !state) return "indigo";
        const c = hoverConv || lib.Looks.frontConv();
        if (!c) return "indigo";
        const t = state.tasks.find(x => x.id === "agent_" + c);
        return lib.Looks.chatColor(c, t && t.color ? t.color : "#D97757");
    }
    /**
     * Port (his ask): Robo's settings live in Ambxst's settings window, AI
     * tab (the AiPanel patch embeds settings/RoboSettingsPage). `settingsPage`
     * is that page while it exists; `settingsRequest` asks it to show a section.
     */
    property var settingsPage: null
    property var settingsRequest: ({ section: "", n: 0 })
    /** Port: the notch shows just the island (RoboShell.compactShown, mirrored for the views). */
    property bool compactNotch: false
    /** Port: the height the compact notch is handed while a view moves the island itself (0: the island's own). */
    property real compactTargetH: 0
    /** Port: a reply being typed in the finished popup, carried into the chat page. */
    property string finishedDraft: ""
    /** Port: the finished popup's session, for opening it on the chat page. */
    property string finishedSession: ""
    /** Port: the music pill follows Ambxst's media player (shell/RoboMedia.qml). */
    property bool mediaFromShell: false
    /** The conversation whose mini is being carried (its cell hides meanwhile). */
    property string dragConv: ""
    /** A carried mini is over the chats column (letting go retires it). */
    property bool convDropOver: false
    /** The tab's overlay a mini is carried on (views/ConvDrag.qml), and the column. */
    property Item convDrag: null
    property Item historyView: null
    // Port (his bug): one tab per screen, each with its own overlay and
    // column; the singletons above held whichever was made last, so a mini
    // picked up on another screen was carried (unseen) in that tab. Every
    // instance registers here and is looked up by the window it is in.
    property var convDrags: []
    property var historyViews: []
    /** The top of `item`'s tree: items in the same window share it. */
    function windowRoot(item) {
        let it = item;
        while (it && it.parent) it = it.parent;
        return it;
    }
    function sameWindowAs(list, item, fallback) {
        const r = windowRoot(item);
        for (const x of list) if (x && windowRoot(x) === r) return x;
        return fallback;
    }
    function convDragFor(item) { return sameWindowAs(convDrags, item, convDrag); }
    function historyViewFor(item) { return sameWindowAs(historyViews, item, historyView); }
    readonly property var state: lib.State
    property int rev: 0
    property bool started: false

    /** True while the island's frame loop wants frames. */
    property bool frameWanted: false
    /** Bumps once per frame stepped (the views' animated bits follow it). */
    property int frameTick: 0

    readonly property string socketPath: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/ambxst-robo-core.sock"
    readonly property string assetsDir: Quickshell.shellDir + "/assets/robo"
    readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")) + "/ambxst-robo"
    property bool coreConnected: false

    /** Fires for every island mode change (hidden / compact / expanded). */
    signal modeChanged(string mode, string prev)
    /** The island wants the keyboard (chat) or gives it back. */
    signal keyboardWanted(bool on)
    /** Upstream window calls the shell has to act on (settings window, desktop…). */
    signal windowCommand(string cmd, var args)

    // Views register themselves here: name → { tick(nowMs), command(c), focusIn() }.
    property var views: ({})
    function registerView(name, obj) { views[name] = obj; }
    function unregisterView(name, obj) { if (views[name] === obj) delete views[name]; }

    // ── Timers (setTimeout / setInterval for the bundled code) ──────────────
    property var timers: ({})
    property int nextTimerId: 1
    Component {
        id: timerComp
        Timer {
            property var fn: null
            property bool once: true
            onTriggered: {
                const f = fn;
                if (once) destroy();
                if (f) f();
            }
        }
    }

    // ── Sounds ──────────────────────────────────────────────────────────────
    // Upstream plays decoded buffers through a WebAudio gain (volume 0–0.2),
    // several at once. Here: one SoundEffect per playing copy, from the
    // mod's copy of Coucou's WAVs, or the user's file in ~/.config/ambxst-robo/sounds.
    property var customSounds: ({})
    property var playing: ({})
    Component {
        id: effectComp
        SoundEffect {
            property string soundName: ""
            onPlayingChanged: if (!playing) destroy(50)
        }
    }
    Component {
        id: playerComp
        MediaPlayer {
            property string soundName: ""
            audioOutput: AudioOutput {}
            onPlaybackStateChanged: if (playbackState === MediaPlayer.StoppedState) destroy(50)
        }
    }
    function soundUrl(name) {
        const own = customSounds[name];
        if (own) return "file://" + own;
        return "file://" + assetsDir + "/sounds/" + name + ".wav";
    }
    // quickshell-git 0.3.0.r20 built against Qt 6.11 crashes on Qt 6.12
    // whenever a PipeWire node appears (stock Audio.qml), and every sound is a
    // new stream: sounds stay off while that build is installed.
    property bool soundSafe: false
    Process {
        running: true
        command: ["pacman", "-Q", "quickshell-git"]
        stdout: StdioCollector {
            onStreamFinished: {
                root.soundSafe = text.indexOf("0.3.0.r20.g28771c7") < 0 && text.trim() !== "";
                if (!root.soundSafe) console.warn("ambxst-robo: sounds off until quickshell-git is rebuilt for this Qt");
            }
        }
    }
    function playSound(name, volume) {
        if (!soundSafe) return;
        const own = customSounds[name];
        let obj;
        if (own && !own.toLowerCase().endsWith(".wav")) {
            obj = playerComp.createObject(root, { soundName: name, source: soundUrl(name) });
            obj.audioOutput.volume = volume;
            obj.play();
        } else {
            obj = effectComp.createObject(root, { soundName: name, source: soundUrl(name), volume: volume });
            obj.play();
        }
        (playing[name] = playing[name] || []).push(obj);
        playingCleanup.restart();
    }
    function fadeSound(name, seconds) {
        const list = playing[name] || [];
        for (const o of list) {
            if (!o) continue;
            // A MediaPlayer (non-WAV custom sound) fades through its audio output.
            const t = o.audioOutput ? o.audioOutput : o;
            fadeComp.createObject(root, { target: t, duration: Math.max(1, seconds * 1000), player: o }).start();
        }
    }
    Component {
        id: fadeComp
        NumberAnimation {
            property var player: null
            property: "volume"
            to: 0
            onFinished: { if (player) player.stop(); destroy(); }
        }
    }
    Timer {
        id: playingCleanup
        interval: 3000
        onTriggered: {
            for (const k of Object.keys(root.playing))
                root.playing[k] = root.playing[k].filter(o => { try { return o && (o.playing || o.playbackState === 1); } catch (e) { return false; } });
        }
    }
    /**
     * The user's own sounds, as ambxst-robo picks them (sounds.rs: one file per
     * name, known formats, size cap): `own` lists the names, `custom_sound`
     * answers each one's path. Resolves once every path is known.
     */
    function loadCustomSounds(own) {
        const names = own || [];
        return Promise.all(names.map(n => new Promise(resolve => {
            sendCore("custom_sound", { name: n }, path => resolve([n, path]), () => resolve([n, null]));
        }))).then(pairs => {
            const map = {};
            for (const [n, path] of pairs) if (typeof path === "string" && path) map[n] = path;
            root.customSounds = map;
        });
    }

    // ── localStorage (views/usage.ts keeps the last plan usage there) ───────
    FileView {
        id: storageFile
        path: root.stateDir + "/storage.json"
        blockLoading: true
        printErrors: false
    }
    Timer {
        id: storageSave
        interval: 400
        onTriggered: {
            Quickshell.execDetached(["mkdir", "-p", root.stateDir]);
            storageFile.setText(JSON.stringify(root.host.storage));
        }
    }

    // ── ambxst-robo ─────────────────────────────────────────────────────────
    property var pending: ({})
    property int nextId: 1
    property var queue: []
    property var listeners: ({})

    function emitLocal(name, payload) {
        const l = listeners[name];
        if (!l) return;
        for (const cb of l.slice()) {
            try { cb(payload); } catch (e) { console.warn("ambxst-robo: listener", name, "failed:", e, e && e.stack); }
        }
    }

    function sendCore(cmd, args, resolve, reject) {
        const id = nextId++;
        pending[id] = { resolve, reject, cmd };
        const msg = JSON.stringify({ id, cmd, args: args || {} });
        if (core.connected) {
            core.write(msg + "\n");
            core.flush();
        } else {
            queue.push(msg);
            coreProbe.running = true;
            if (!failQueued.running) failQueued.start();
        }
    }

    Socket {
        id: core
        path: root.socketPath
        connected: false
        parser: SplitParser {
            onRead: data => {
                if (!data) return;
                let msg;
                try { msg = JSON.parse(data); } catch (e) { console.warn("ambxst-robo: bad line from core", e); return; }
                if (msg.event !== undefined) {
                    // Port: the shell reports the media player (shell/RoboMedia.qml):
                    // ambxst-robo's Spotify-only reports would fight it.
                    if (root.mediaFromShell && (msg.event === "spotify" || msg.event === "spotify-artwork")) return;
                    root.emitLocal(msg.event, msg.payload);
                    return;
                }
                const p = root.pending[msg.id];
                if (!p) return;
                delete root.pending[msg.id];
                if (msg.ok) p.resolve(msg.result === undefined ? null : msg.result);
                else p.reject(new Error(msg.error || (p.cmd + " failed")));
            }
        }
        onConnectionStateChanged: {
            root.coreConnected = connected;
            if (connected) {
                coreProbe.running = false;
                // A restarted core starts unpaused: tell it ours.
                if (root.island) root.lib.Bridge.setPaused(root.state.paused);
                // Port (his bug): a restarted core gave the chats new ids.
                if (root.island) Qt.callLater(() => root.lib.ChatView.chat().resync());
                while (root.queue.length > 0) core.write(root.queue.shift() + "\n");
                core.flush();
                // Zero-touch install: is this daemon the mod's own version? (RoboCore)
                RoboCore.coreUp();
            } else {
                RoboCore.coreDown();
                // Requests in flight will never get an answer.
                for (const id of Object.keys(root.pending)) {
                    const p = root.pending[id];
                    delete root.pending[id];
                    p.reject(new Error("ambxst-robo went away"));
                }
                coreProbe.running = true;
            }
        }
        onError: error => { root.coreConnected = false; coreProbe.running = true; }
    }
    Timer {
        id: coreProbe
        interval: 700
        repeat: true
        running: true
        onTriggered: if (!core.connected) core.connected = true
    }
    // Requests sent while the core is down fail after a while instead of hanging.
    Timer {
        id: failQueued
        interval: 1500
        onTriggered: {
            if (root.coreConnected) return;
            root.queue = [];
            for (const id of Object.keys(root.pending)) {
                const p = root.pending[id];
                delete root.pending[id];
                p.reject(new Error("ambxst-robo is not running"));
            }
        }
    }

    // ── Commands the shell answers itself (Tauri window API) ────────────────
    function localInvoke(cmd, args) {
        switch (cmd) {
        case "set_collapsed":
        case "set_island_rect":
        case "reposition":
            return { handled: true, value: null };
        case "focus_window":
            root.keyboardWanted(!!args.focused);
            return { handled: true, value: null };
        case "list_monitors":
            const out = [];
            const list = Quickshell.screens;
            // island.rs monitor_choices: key `at:<x>,<y>|<name>|<w>x<h>`, translated label.
            for (let i = 0; i < list.length; i++) {
                const m = list[i];
                out.push({
                    key: "at:" + m.x + "," + m.y + "|" + String(m.name).replace(/\|/g, " ") + "|" + m.width + "x" + m.height,
                    label: lib.I18n.t("{name} — {width}×{height} at {x},{y}", { name: m.name, width: m.width, height: m.height, x: m.x, y: m.y }),
                });
            }
            return { handled: true, value: out };
        case "open_settings_window":
        case "shortcuts_suspend":
            root.windowCommand(cmd, args);
            return { handled: true, value: null };
        }
        if (cmd.indexOf("desktop_mascot_") === 0) {
            // Before the desktop window exists, its persistence still lives in ambxst-robo.
            if (!root.desktopHandler && (cmd === "desktop_mascot_info" || cmd === "desktop_mascot_remember"))
                return { handled: false };
            const r = root.desktopHandler ? root.desktopHandler(cmd, args) : null;
            return { handled: true, value: r === undefined ? null : r };
        }
        return { handled: false };
    }
    /** Set by the desktop mascot window: (cmd, args) → result. */
    property var desktopHandler: null

    function installHost() {
        const h = host;
        h.setTimeout = function (f, ms) {
            const id = root.nextTimerId++;
            const t = timerComp.createObject(root, { interval: Math.max(1, ms | 0), fn: function () { delete root.timers[id]; f(); } });
            root.timers[id] = t;
            t.start();
            return id;
        };
        h.clearTimeout = function (id) {
            const t = root.timers[id];
            if (!t) return;
            t.stop();
            t.destroy();
            delete root.timers[id];
        };
        h.setInterval = function (f, ms) {
            const id = root.nextTimerId++;
            const t = timerComp.createObject(root, { interval: Math.max(1, ms | 0), repeat: true, once: false, fn: f });
            root.timers[id] = t;
            t.start();
            return id;
        };
        h.clearInterval = h.clearTimeout;
        h.listen = function (name, cb) {
            (root.listeners[name] = root.listeners[name] || []).push(cb);
            return function () {
                const l = root.listeners[name];
                if (!l) return;
                const i = l.indexOf(cb);
                if (i >= 0) l.splice(i, 1);
            };
        };
        h.emitTo = function (target, name, payload) {
            if (target && target !== "main") root.windowCommand("emit:" + target + ":" + name, payload);
            else root.emitLocal(name, payload);
        };
        h.invoke = function (cmd, args, resolve, reject) {
            const local = root.localInvoke(cmd, args || {});
            if (local.handled) { resolve(local.value); return; }
            root.sendCore(cmd, args, resolve, reject);
        };
        h.sound = {
            load: function (names, own) { return root.loadCustomSounds(own); },
            play: function (name, volume) { root.playSound(name, volume); },
            fadeOut: function (name, seconds) { root.fadeSound(name, seconds); },
        };
        try { h.storage = JSON.parse(storageFile.text() || "{}"); } catch (e) { h.storage = {}; }
        h.saveStorage = function () { storageSave.restart(); };
        h.languages = Qt.locale().uiLanguages.length ? Qt.locale().uiLanguages : ["en"];
        h.layerCanvas = function (ctx, w, hgt) { return root.layerCanvas(ctx, w, hgt); };
        h.robotScratch = function (item) { return root.robotScratch(item); };
    }
    /**
     * Port (his ask, Robo): the hidden canvas robot-heads' off-screen canvases
     * draw on (lib/robot/offscreen.js), made beside the first canvas that draws
     * a robot (a Canvas has a context only in a window). Null until ready.
     */
    property var robotScratchWindow: null
    function robotScratch(item) {
        // Its own hidden window, made once and kept: beside a drawing canvas
        // it went with that canvas (a mini rebuilt, the tab unloaded), and a
        // canvas drawn after its window went crashed Quickshell.
        if (!robotScratchWindow) {
            try {
                robotScratchWindow = Qt.createQmlObject('import QtQuick; import QtQuick.Window; Window { visible: false; width: 512; height: 512; Canvas { width: 512; height: 512; renderStrategy: Canvas.Immediate; renderTarget: Canvas.Image } }', root);
            } catch (e) { return null; }
        }
        const c = robotScratchWindow.contentItem.children[0];
        if (!c || !c.available) return null;
        return { ctx: c.getContext("2d"), w: 512, h: 512, alive: () => true };
    }
    /**
     * outfits.ts withLayer(): a fading outfit is drawn on a scratch canvas and
     * laid down as ONE image, so its overlapping parts don't show through each
     * other. One hidden Canvas per drawing canvas, created beside it on first
     * use; it draws immediately, so its pixels are ready within the frame.
     */
    function layerCanvas(ctx, w, hgt) {
        const item = ctx && ctx.canvas;
        if (!item || !item.parent || typeof item.requestPaint !== "function") return null;
        let l = ctx.__layer;
        if (!l) {
            let c;
            try {
                c = Qt.createQmlObject('import QtQuick; Canvas { opacity: 0; enabled: false; renderStrategy: Canvas.Immediate; renderTarget: Canvas.Image }', item.parent);
            } catch (e) { return null; }
            l = { item: c, ctx: null, image: null };
            ctx.__layer = l;
        }
        // A new Canvas gets its context a frame later: plain fade until then.
        if (!l.ctx) {
            if (!l.item.available) return null;
            const q = l.item.getContext("2d");
            if (!q) return null;
            l.ctx = new root.lib.CtxWrap(q, l.item);
            l.image = (W, H) => q.getImageData(0, 0, W, H);
        }
        if (l.item.width < w) l.item.width = Math.ceil(w);
        if (l.item.height < hgt) l.item.height = Math.ceil(hgt);
        return l;
    }

    // ── Frame loop ──────────────────────────────────────────────────────────
    // Upstream drives everything from requestAnimationFrame while the island
    // has something moving; the views that are on screen step it here.
    // Several frame sources (the notch tab, each screen's bar) may tick in the
    // same vsync: the island steps once. With only the bar on screen it steps
    // ~10 times a second (barSources' timer, below) — the bar lives in a
    // screen-sized surface and every repaint redraws all of it.
    property real lastStepMs: 0
    property int fullRateSources: 0
    function stepFrame(nowMs) {
        if (!island) return false;
        // Bars alone: 60 fps (upstream's rAF on a 60 Hz panel), not the
        // display's 165 Hz, since every bar repaint redraws a screen-sized surface.
        const minGap = fullRateSources > 0 && island.fullRate ? 4 : 30;
        if (nowMs - lastStepMs < minGap) return false;
        lastStepMs = nowMs;
        const busy = island.frame(nowMs);
        frameTick++;
        if (!busy) frameWanted = false;
        return true;
    }
    // Nothing on screen to step it (notch shut): the timers still run, and
    // the state machine needs no frames, but `running` must not stick.
    Timer {
        interval: 250
        repeat: true
        running: root.frameWanted && !root.anyFrameSource
        onTriggered: root.stepFrame(Date.now())
    }
    /**
     * Port (performance): the bars that draw Robo (RoboBar `lead`: the focused
     * screen's, in place). One timer steps the island for all of them, ~10
     * times a second: each step repaints a bar's screen-sized surface, and
     * one step at a time keeps its Robo and its minis to one frame.
     */
    property int barSources: 0
    Timer {
        interval: 100
        repeat: true
        running: root.frameWanted && root.barSources > 0 && root.island !== null
        onTriggered: root.stepFrame(Date.now())
    }
    /**
     * Port (performance): the views' loops' clock (AnimClock: the shimmering
     * step, the typing dots), ~30 Hz while any runs. While the open island
     * steps its mascot (at 30 Hz or more) it ticks with it, so the loops and
     * the mascot share their frames; otherwise on its own timer.
     */
    property int clockUsers: 0
    property real clockMs: 0
    readonly property bool clockOnFrames: frameWanted && fullRateSources > 0
    Timer {
        interval: 33
        repeat: true
        running: root.clockUsers > 0 && !root.clockOnFrames
        onTriggered: root.clockMs = Date.now()
    }
    onFrameTickChanged: {
        if (clockUsers <= 0 || !clockOnFrames) return;
        const now = Date.now();
        if (now - clockMs >= 28) clockMs = now;
    }
    /** True while some visible item steps frames itself (FrameAnimation). */
    property int frameSources: 0
    readonly property bool anyFrameSource: frameSources > 0

    // ── File drag and drop (upstream: Tauri's drag-drop event → island) ─────
    /** type: enter | over | leave | drop; urls: the drop's file URLs. */
    function fileDrag(type, urls) {
        if (!island) return;
        // Port (his ask): several DropAreas take turns under one drag (the
        // notch's, the whole tab's, the island's on top, the bar's), and the
        // notch growing under the cursor moves them: each hand-over is a leave
        // then an enter. A leave only counts once no DropArea has had the drag
        // for a moment, so the drop look (and the mascot's open mouth) never blinks.
        if (type === "leave") {
            fileDragLeave.restart();
            return;
        }
        fileDragLeave.stop();
        if (type === "drop") {
            const paths = (urls || []).map(u => decodeURIComponent(String(u).replace(/^file:\/\//, ""))).filter(p => p);
            // ambxst-robo only ingests a path the shell reported as really dropped.
            // Port (his ask): its answer names the folders among them (a folder
            // may become the chat's working directory, lib/views/chat.ts).
            if (paths.length) sendCore("files_dropped", { paths: paths }, r => {
                if (r && r.dirs && r.dirs.length) lib.ChatView.chat().droppedDirs(r.dirs);
            }, () => {});
            island.onDragDrop({ type: "drop", paths: paths });
            return;
        }
        island.onDragDrop({ type: type });
    }

    Timer {
        id: fileDragLeave
        interval: 150
        onTriggered: if (root.island) root.island.onDragDrop({ type: "leave" })
    }

    // ── Keyboard ────────────────────────────────────────────────────────────
    /** A QML key event → upstream's window keydown listeners, then Escape. True if handled. */
    function dispatchKey(e) {
        if (!island) return false;
        const keyName = keyNames[e.key] || (e.text && e.text.length === 1 ? e.text : "");
        let stopped = false, prevented = false;
        const ev = {
            type: "keydown",
            key: keyName,
            code: /^[0-9]$/.test(keyName) ? "Digit" + keyName : keyName === "," ? "Comma" : keyName === " " ? "Space" : keyName.length === 1 ? "Key" + keyName.toUpperCase() : keyName,
            ctrlKey: !!(e.modifiers & Qt.ControlModifier),
            altKey: !!(e.modifiers & Qt.AltModifier),
            shiftKey: !!(e.modifiers & Qt.ShiftModifier),
            metaKey: !!(e.modifiers & Qt.MetaModifier),
            repeat: e.isAutoRepeat,
            target: focusedTextField ? { tagName: "INPUT", isContentEditable: false } : { tagName: "DIV", isContentEditable: false },
            preventDefault() { prevented = true; },
            stopPropagation() { stopped = true; },
            stopImmediatePropagation() { stopped = true; },
        };
        // Views with keys of their own (the diff's Escape) go first, as their
        // capture listeners were registered before the shortcuts' upstream.
        const v = views[state.view];
        if (v && v.keyDown && v.keyDown(ev)) return true;
        lib.dispatchWindowEvent("keydown", ev, () => stopped);
        if (!stopped && keyName === "Escape") { island.escape(); return true; }
        return stopped || prevented;
    }
    /** Set by the chat field while it has focus (upstream inTextField). */
    property bool focusedTextField: false
    readonly property var keyNames: ({
        [Qt.Key_Escape]: "Escape", [Qt.Key_Return]: "Enter", [Qt.Key_Enter]: "Enter",
        [Qt.Key_Left]: "ArrowLeft", [Qt.Key_Right]: "ArrowRight", [Qt.Key_Up]: "ArrowUp", [Qt.Key_Down]: "ArrowDown",
        [Qt.Key_Tab]: "Tab", [Qt.Key_Backspace]: "Backspace", [Qt.Key_Space]: " ", [Qt.Key_Comma]: ",",
        [Qt.Key_1]: "1", [Qt.Key_2]: "2", [Qt.Key_3]: "3", [Qt.Key_4]: "4", [Qt.Key_5]: "5",
        [Qt.Key_6]: "6", [Qt.Key_7]: "7", [Qt.Key_8]: "8", [Qt.Key_9]: "9",
        [Qt.Key_A]: "a", [Qt.Key_B]: "b", [Qt.Key_C]: "c", [Qt.Key_D]: "d", [Qt.Key_E]: "e", [Qt.Key_F]: "f",
        [Qt.Key_G]: "g", [Qt.Key_H]: "h", [Qt.Key_I]: "i", [Qt.Key_J]: "j", [Qt.Key_K]: "k", [Qt.Key_L]: "l",
        [Qt.Key_M]: "m", [Qt.Key_N]: "n", [Qt.Key_O]: "o", [Qt.Key_P]: "p", [Qt.Key_Q]: "q", [Qt.Key_R]: "r",
        [Qt.Key_S]: "s", [Qt.Key_T]: "t", [Qt.Key_U]: "u", [Qt.Key_V]: "v", [Qt.Key_W]: "w", [Qt.Key_X]: "x",
        [Qt.Key_Y]: "y", [Qt.Key_Z]: "z",
    })

    // ── Boot ────────────────────────────────────────────────────────────────

    Timer {
        id: greetLater
        interval: 2500
        onTriggered: if (root.island) root.island.launch()
    }

    function start() {
        if (started) return;
        started = true;
        installHost();
        // The daemon is the mod's to install and keep at its version (RoboCore.qml).
        RoboCore.begin();
        // text() blocks until the flag file is read; `loaded` alone was still
        // false here, which made every shell reload greet.
        // His call: Robo's launch greeting plays after every shell start, the
        // first time he opens the Robo tab (RoboShell); the start itself is
        // quiet (the mascot back where he was, the desktop included).
        root.greetPending = !Quickshell.env("ROBO_NO_GREET");
        const greet = false;
        state.subscribe(() => { root.rev++; });
        lib.start({
            wake: function () { root.frameWanted = true; },
            modeChanged: function (mode, prev) { root.modeChanged(mode, prev); },
            focus: function (on) { root.keyboardWanted(on); },
            viewCommand: function (view, command) { const v = root.views[view]; if (v && v.command) v.command(command); },
            viewTick: function (view, nowMs) { const v = root.views[view]; return v && v.tick ? v.tick(nowMs) === true : false; },
            viewFocus: function (view) { const v = root.views[view]; if (v && v.focusIn) v.focusIn(); },
        }, { greet: false, greetLater: greet }).then(isl => {
            root.island = isl;
            root.rev++;
            // The launch greeting waits for the shell to settle: opening the
            // notch while Ambxst is still loading its config crashed it.
            if (greet) greetLater.start();
        }, e => console.warn("ambxst-robo: start failed:", e, e && e.stack));
    }

    Component.onCompleted: start()
}
