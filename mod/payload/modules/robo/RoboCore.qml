pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Ambxst Robo (zero-touch install): keeps ambxst-robo, the daemon, at the
// mod's own version, so installing or updating the mod in Ambxst is all a
// user ever does.
//
// On shell start (a mod update or reload is a shell start too) it asks the
// bundled installer (core/robo-core-install.sh check) how the daemon on disk
// is, and asks the running daemon its version (`version`; daemons before
// 1.1.0 do not know it). Missing, another version, a stale unit, a stopped
// service: the installer runs detached under systemd-run (download from the
// GitHub release, sha256 check, ~/.local/bin, the user unit, a restart once
// no chat turn runs) and reports through its status file, shown here as the
// island's notes and the tab's banner (views/CoreBanner.qml). Until the new
// daemon answers, the banner says the core is being updated; when it does,
// the island takes its settings again.
//
// Developer setups are never touched: a personal build (core/RELEASE
// build=personal), AMBXST_ROBO_DEV=1, or ~/.config/ambxst-robo/dev.
//
// It also offers, once, to connect Claude Code (its hooks need the user's
// click, as in Settings → Agents): one click writes them, with a backup.
Singleton {
    id: root

    readonly property string dir: Quickshell.shellDir + "/modules/robo/core"
    readonly property string script: dir + "/robo-core-install.sh"
    readonly property string statusPath: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/ambxst-robo-install.status"
    /** The version the mod expects (core/RELEASE). */
    property string want: ""
    property string build: ""
    /**
     * idle | checking | setup | update | quiet (a stale unit, a stopped
     * service: no notice) | waiting (for a chat turn to end) | ready (just
     * installed, the notice stays a moment) | ok | error | dev
     */
    property string phase: "idle"
    /** The installer's error code (robo-core-install.sh fail) and its detail. */
    property string error: ""
    property string detail: ""
    /** The running daemon's version: "" not connected or not asked yet, "old" before 1.1.0. */
    property string running: ""
    property string runId: ""
    property bool began: false
    readonly property bool busy: phase === "setup" || phase === "update" || phase === "quiet" || phase === "waiting" || phase === "checking"
    /** The daemon answering is the mod's own: every command the mod sends exists. */
    readonly property bool matched: running !== "" && (running === want || phase === "dev" || want === "")

    onPhaseChanged: console.info("ambxst-robo: core", phase, error ? error + " " + detail : "", "(want " + want + ", running " + (running || "none") + ")")

    function t(s, vars) {
        const lib = Robo.lib;
        return lib && lib.I18n ? lib.I18n.t(s, vars || {}) : s;
    }

    // ── The texts (every one in core/i18n/extra.json) ────────────────────────
    readonly property string headline: {
        void Robo.rev;
        switch (phase) {
        case "setup": return t("Setting up Robo…");
        case "update": return t("Updating Robo's core…");
        case "waiting": return t("Robo's core will update when the current reply finishes.");
        case "ready": return t("Robo's core is up to date.");
        case "error": return errorText(error);
        }
        return "";
    }
    function errorText(code) {
        switch (code) {
        case "arch": return t("There is no ready-made Robo core for this computer. Install Rust (cargo) and retry: Robo will build it here.");
        case "notrun": return t("Robo's ready-made core does not run on this system. Install Rust (cargo) and retry: Robo will build it here.");
        case "download": return t("Robo's core could not be downloaded. Check your connection and retry.");
        case "checksum": return t("Robo's core download did not match its checksum, so nothing was installed. Retry later.");
        case "build": return t("Building Robo's core failed. Its log is in ~/.local/state/ambxst-robo/core-install.log.");
        case "systemd": return t("Robo's core could not be started as a user service (systemctl --user).");
        case "tools": return t("Robo needs curl, tar and sha256sum to install its core.");
        case "start": return t("Robo's core was installed but did not start. Its log is in ~/.local/state/ambxst-robo/.");
        }
        return t("Robo's core could not be installed. Its log is in ~/.local/state/ambxst-robo/core-install.log.");
    }

    // ── Start ───────────────────────────────────────────────────────────────
    FileView { id: releaseFile; path: root.dir + "/RELEASE"; blockLoading: true; printErrors: false }

    /** Robo.start(): once per shell start. */
    function begin() {
        if (began) return;
        began = true;
        const text = releaseFile.text() || "";
        for (const line of text.split("\n")) {
            const i = line.indexOf("=");
            if (i < 0) continue;
            const k = line.slice(0, i).trim(), v = line.slice(i + 1).trim();
            if (k === "version") want = v;
            else if (k === "build") build = v;
        }
        // (The render harnesses never install anything, but tools/test-core-shell.sh.)
        const harness = Quickshell.env("ROBO_HARNESS") && Quickshell.env("ROBO_CORE_TEST") !== "1";
        if (!want || build === "personal" || Quickshell.env("AMBXST_ROBO_DEV") === "1" || harness) {
            phase = "dev";
            return;
        }
        // A daemon already up has a moment to connect before the check runs.
        phase = "checking";
        firstCheck.start();
    }
    Timer { id: firstCheck; interval: 2500; onTriggered: root.check() }

    function check() {
        firstCheck.stop();
        if (phase === "dev" || checker.running || launcher.running || poll.running) return;
        // (A "ready" notice stays up its few seconds.)
        if (phase === "idle" || phase === "ok" || phase === "error") phase = "checking";
        checker.running = true;
    }
    Process {
        id: checker
        command: ["bash", root.script, "check", "--version", root.want]
        stdout: StdioCollector {
            onStreamFinished: root.checked(text)
        }
    }
    function checked(text) {
        const info = {};
        for (const part of String(text || "").trim().split(/\s+/)) {
            const i = part.indexOf("=");
            if (i > 0) info[part.slice(0, i)] = part.slice(i + 1);
        }
        const st = info.state || "";
        if (st === "dev") { phase = "dev"; return; }
        if (st === "missing") return install("setup");
        if (st === "outdated") return install("update");
        if (st === "unit") return install(running && running !== want ? "update" : "quiet");
        if (st !== "ok") {
            console.warn("ambxst-robo: core check said", text);
            error = "internal"; detail = String(text || "").trim(); phase = "error";
            return;
        }
        // The right binary and unit: the daemon itself may still be off or old.
        if (info.active !== "active") return install("quiet");
        if (running && running !== want) return install("update");
        if (!running) {
            // Up but not answering yet: wait for the socket.
            phase = "checking";
            noAnswer.restart();
            return;
        }
        if (phase !== "ready") phase = "ok";
    }
    // Active but silent for this long: restart it the installer's way.
    Timer { id: noAnswer; interval: 8000; onTriggered: if (root.phase === "checking" && !Robo.coreConnected) root.install("quiet") }

    // ── The daemon's own answer ─────────────────────────────────────────────
    /** Robo.qml: the socket connected. */
    function coreUp() {
        Robo.sendCore("version", {}, v => root.answered(v && v.version ? String(v.version) : "old"), () => root.answered("old"));
    }
    /** Robo.qml: the socket went away (a restart, Quit). */
    function coreDown() { running = ""; }
    function answered(version) {
        running = version;
        if (phase === "dev" || !began) return;
        if (version === want) {
            const was = phase;
            if (was === "setup" || was === "update" || was === "waiting" || was === "quiet" || was === "error" || was === "installed") {
                poll.stop();
                startTimeout.stop();
                // The island booted against the old daemon (or none): it takes
                // the new one's settings, as after a change in Settings.
                Robo.sendCore("boot", {}, b => { if (b && b.settings) Robo.emitLocal("settings-changed", b.settings); }, () => {});
                if (was === "setup" || was === "update" || was === "waiting" || shownNotice) {
                    phase = "ready";
                    if (was === "setup") note(t("Robo is ready."));
                    readyFade.restart();
                } else {
                    phase = "ok";
                }
                shownNotice = false;
            } else if (phase === "checking") {
                phase = "ok";
            }
            hooks.consider();
            return;
        }
        // Another version answers: unless an install is under way already, check.
        if (phase === "ok" || phase === "checking" || phase === "ready") check();
    }
    Timer { id: readyFade; interval: 6000; onTriggered: if (root.phase === "ready") root.phase = "ok" }

    // ── Installing ──────────────────────────────────────────────────────────
    property bool shownNotice: false
    function install(kind) {
        if (launcher.running || poll.running) return;
        runId = String(Date.now());
        phase = kind;
        error = "";
        detail = "";
        if (kind === "setup") { note(t("Setting up Robo…")); shownNotice = true; }
        else if (kind === "update") { note(t("Updating Robo's core…")); shownNotice = true; }
        const env = ["--setenv=AMBXST_ROBO_STATUS=" + statusPath];
        for (const k of ["AMBXST_ROBO_RELEASE_BASE", "AMBXST_ROBO_SOURCE_URL", "AMBXST_ROBO_BIN_DIR", "AMBXST_ROBO_NO_WAIT"]) {
            const v = Quickshell.env(k);
            if (v) env.push("--setenv=" + k + "=" + v);
        }
        launcher.command = ["systemd-run", "--user", "--collect", "--quiet", "--unit=ambxst-robo-install"]
            .concat(env, ["--", "bash", script, "install", "--version", want, "--run", runId]);
        launcher.running = true;
        poll.restart();
    }
    Process {
        id: launcher
        onExited: (code, status) => {
            if (code === 0) return;
            // An install from before a shell reload is still running (the unit
            // name is taken): follow it. Else no systemd-run: run it here.
            unitProbe.running = true;
        }
    }
    Process {
        id: unitProbe
        command: ["systemctl", "--user", "is-active", "ambxst-robo-install.service"]
        stdout: StdioCollector {
            onStreamFinished: {
                const s = text.trim();
                if (s === "active" || s === "activating") { root.runId = ""; return; }
                direct.command = ["bash", root.script, "install", "--version", root.want, "--run", root.runId];
                direct.environment = ({ AMBXST_ROBO_STATUS: root.statusPath });
                direct.running = true;
            }
        }
    }
    Process { id: direct }

    FileView { id: statusFile; path: root.statusPath; blockLoading: true; printErrors: false }
    Timer {
        id: poll
        interval: 800
        repeat: true
        onTriggered: root.readStatus()
    }
    function readStatus() {
        statusFile.reload();
        const s = {};
        for (const line of (statusFile.text() || "").split("\n")) {
            const i = line.indexOf("=");
            if (i > 0) s[line.slice(0, i)] = line.slice(i + 1);
        }
        // An older run's file (runId "" follows whichever run is going).
        if (!s.phase || (runId && s.run !== runId)) return;
        if (s.phase === "waiting") {
            if (phase !== "waiting") phase = "waiting";
        } else if (s.phase === "error") {
            poll.stop();
            error = s.error || "internal";
            detail = s.detail || "";
            phase = "error";
            console.warn("ambxst-robo: core install failed:", error, detail);
            note(errorText(error));
            if (error === "download") retryLater.restart();
        } else if (s.phase === "skipped") {
            poll.stop();
            phase = "dev";
        } else if (s.phase === "done") {
            poll.stop();
            if (running === want) answered(running);
            else {
                if (phase === "waiting") phase = "update";
                startTimeout.restart();
                // The restarted daemon answers on the socket (Robo.qml reconnects).
                if (Robo.coreConnected && running === "") coreUp();
            }
        }
    }
    Timer {
        id: startTimeout
        interval: 20000
        onTriggered: if (root.running !== root.want && root.phase !== "dev") { root.error = "start"; root.detail = ""; root.phase = "error"; }
    }
    // Offline, or the release not published yet: try again later.
    Timer { id: retryLater; interval: 30 * 60 * 1000; onTriggered: if (root.phase === "error") root.retry() }

    /** The banner's Retry. */
    function retry() {
        if (phase === "dev" || launcher.running || poll.running) return;
        retryLater.stop();
        install(running && running !== want ? "update" : "setup");
    }

    // ── The island's note (only when the notch is not in use) ───────────────
    property string pendingNote: ""
    function note(msg) {
        pendingNote = msg;
        noteTry.tries = 0;
        noteTry.restart();
    }
    Timer {
        id: noteTry
        property int tries: 0
        interval: 500
        onTriggered: {
            const isl = Robo.island, st = Robo.state;
            if (!isl) { if (++tries < 20) restart(); return; }
            if (!root.pendingNote || st.mode === "expanded" || st.pendingApproval) return;
            st.noteMessage = root.pendingNote;
            isl.alert("note");
            noteOff.msg = root.pendingNote;
            root.pendingNote = "";
            noteOff.restart();
        }
    }
    Timer {
        id: noteOff
        property string msg: ""
        interval: 4500
        onTriggered: {
            const isl = Robo.island, st = Robo.state;
            if (isl && st.mode === "expanded" && st.view === "note" && st.noteMessage === msg) isl.collapse();
        }
    }

    // ── Claude Code's hooks: offered once ───────────────────────────────────
    readonly property QtObject hooks: QtObject {
        id: hooks
        /** "" | "offer" | "working" | "done" | "error" */
        property string state: ""
        property string message: ""
        readonly property string key: "robo.hooksOffered"
        function consider() {
            if (state !== "" || root.phase === "dev") return;
            const store = Robo.host && Robo.host.storage;
            if (!store || store[key]) return;
            Robo.sendCore("hooks_status", {}, s => {
                if (!s || s.installed) return;
                claudeProbe.running = true;
            }, () => {});
        }
        function dismiss() {
            Robo.host.storage[key] = true;
            Robo.host.saveStorage();
            state = "";
        }
        function connect() {
            state = "working";
            Robo.sendCore("hooks_preview", { install: true }, p => {
                Robo.sendCore("hooks_apply", { install: true, fingerprint: p.fingerprint }, () => {
                    Robo.host.storage[hooks.key] = true;
                    Robo.host.saveStorage();
                    hooks.message = root.t("Done. Open a new Claude Code session to pick the hooks up.");
                    hooks.state = "done";
                    hooksDoneFade.restart();
                }, e => hooks.failed(e));
            }, e => hooks.failed(e));
        }
        function failed(e) {
            message = root.t("Could not write: {error}", { error: String(e && e.message ? e.message : e) });
            state = "error";
        }
    }
    Timer { id: hooksDoneFade; interval: 8000; onTriggered: if (root.hooks.state === "done") root.hooks.state = "" }
    // Only for people who use Claude Code: ~/.claude or `claude` on PATH.
    Process {
        id: claudeProbe
        command: ["sh", "-c", "test -d \"$HOME/.claude\" || command -v claude >/dev/null"]
        onExited: (code, status) => { if (code === 0 && root.hooks.state === "") root.hooks.state = "offer"; }
    }
}
