import QtQuick
import QtQuick.Controls
import qs.modules.robo as C

// Coucou's Settings window content (upstream windows/settings.html +
// src/settings/main.ts): ONE scrolling page of sections, same order as
// render() (main.ts:1363-1380); the Android phone section is not ported.
// The logic lives in lib/views/settings.ts (C.Robo.lib.SettingsWin); every
// backend call goes through C.Robo.lib.Bridge, like upstream.
Rectangle {
    id: page
    /** Port: inside Ambxst's settings window (AI tab), on its background. */
    property bool embedded: false
    /**
     * Port (his ask): the AI tab's tabs — "agents" (Claude Code, other agents
     * and CLIs, their keys, the chat's providers), "integrations" (websites),
     * "general" (pills, general, shortcuts), "style" (theme colours, mascot).
     * "" shows every section (upstream's own window).
     */
    property string pane: ""
    function shows(which) { return pane === "" || pane === which; }
    /** The tab a section is on (open(section) links). */
    function paneFor(section) {
        return ({ claude: "agents", agents: "agents", plan: "agents", api: "agents", chat: "agents", local: "agents",
                  integrations: "integrations", pills: "general", general: "general", shortcuts: "general",
                  style: "style" })[section] || "";
    }
    /** Port: more for the Agents tab from the host (Ambxst's own AI providers). */
    property Component agentsExtra: null
    color: embedded ? "transparent" : SettingsTheme.bg

    readonly property var lib: C.Robo.lib
    /** Texts and static tables; re-read on a language change. */
    readonly property var xL: langRev >= 0 ? fresh(lib.SettingsWin) : null
    /** A new object reading through to `o`: bindings that read texts from it
     *  re-run when it changes (a language change). */
    function fresh(o) { return Object.create(o); }
    /** The window's own copy of Settings (upstream `settings`), mutated in place: bump `rev`. */
    property var settings: Object.assign({}, lib.DEFAULT_SETTINGS)
    property int rev: 0
    property int langRev: 0
    property var info: null
    property var agents: null
    property string version: ""
    property bool loaded: false
    /** The FloatingWindow, for its `active` (recording ends on blur). */
    property var window: null
    /** True while a shortcut is being recorded (the shell may want to drop its binds). */
    readonly property bool recordingShortcut: shortcutsSec.recordingId !== ""
    readonly property alias flick: flick
    /** Arabic: the page reads right to left (main.ts applyDirection). */
    readonly property bool rtl: langRev >= 0 && lib.SettingsWin.isRtl()
    LayoutMirroring.enabled: rtl
    LayoutMirroring.childrenInherit: true

    function save() {
        rev++;
        return lib.Bridge.saveSettings(settings);
    }
    /** main.ts declaredChanged: every view of the declared pills redraws, then save. */
    function declaredChanged() { return save(); }
    /** A colour was picked for a pill's mascot (colors.ts → main.ts pickColor). */
    function pickColor(next) {
        settings.pillColors = next;
        save();
    }
    function keyChanged(key, on) {
        if (!info) return;
        xL.keyChanged(info.connected, key, on);
        rev++;
    }
    /** Re-reads hooks_status (the sections' rebuild()). */
    function refreshStatus() {
        return lib.Bridge.hooksStatus().then(s => {
            // A new object: the sections' `st` bindings only notify when the
            // object changes, so mutating it in place left "Install hooks…".
            if (s && info) info.status = Object.assign({}, info.status, s);
            rev++;
        });
    }
    /** render(): reads everything the sections show. */
    property bool rendering: false
    property bool renderAgain: false
    function rerender() {
        if (rendering) { renderAgain = true; return Promise.resolve(); }
        rendering = true;
        return xL.gather(settings).then(d => {
            Object.assign(settings, d.declared);
            agents = d.agents;
            info = d;
            rev++;
            loaded = true;
        }, e => console.warn("ambxst-robo settings: render failed", e)).then(() => {
            rendering = false;
            if (renderAgain) { renderAgain = false; return rerender(); }
        });
    }
    function boot() {
        return xL.boot().then(b => {
            settings = b.settings;
            version = b.version;
            rev++;
            return rerender();
        });
    }
    property bool listening: false
    function listen() {
        if (listening) return;
        listening = true;
        // Port (his bug): the lib keeps these listeners after the settings
        // window closes, and the page's own names are gone by then
        // ("xL is not defined" on every settings change): each goes through
        // a captured `pg` and stops once the page is.
        const pg = page;
        const alive = () => { try { return !!pg && !!pg.xL; } catch (e) { return false; } };
        xL.onEvent("settings-changed", s => {
            if (!alive()) return;
            Object.assign(pg.settings, s);
            pg.rev++;
            pg.xL.applyLanguage(pg.settings);
        });
        xL.onEvent("shortcuts-status", r => { if (alive() && pg.info) { pg.info.shortcutReport = r; pg.rev++; } });
        xL.onLanguageChange(() => { if (alive()) pg.langRev++; });
    }
    /** Shows the window's data fresh (upstream reads it once; the shell's window is reused). */
    function reload() {
        listen();
        return loaded ? lib.Bridge.boot().then(b => {
            if (b) { Object.assign(settings, b.settings); version = b.version; }
            return rerender();
        }) : boot();
    }

    // ── Sections (ids for open(section)) ──
    readonly property var sectionItems: ({
        claude: claudeSec, agents: agentsSec, plan: planSec, api: apiSec, chat: chatSec, local: localSec,
        pills: pillsSec, integrations: integrationsSec, general: generalSec, shortcuts: shortcutsSec,
        style: styleSec,
    })
    /** [name, y, height] of each section in the page (harness comparisons). */
    function sectionRects() {
        const out = [["H1", col.y, 20]];
        for (const k of Object.keys(sectionItems)) out.push([k, col.y + sectionItems[k].y, sectionItems[k].height]);
        return out;
    }
    function scrollTo(section) {
        const it = sectionItems[section];
        if (!it) return;
        // Port: a section on another tab: that tab first.
        if (pane !== "" && paneFor(section) && paneFor(section) !== pane) pane = paneFor(section);
        flick.contentY = Math.max(0, Math.min(it.y + col.y - 18, flick.contentHeight - flick.height));
    }

    Flickable {
        id: flick
        anchors.fill: parent
        contentWidth: width
        contentHeight: col.y + col.implicitHeight + 32
        boundsBehavior: Flickable.StopAtBounds
        clip: true
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        // #settings-root: padding 22 24 32, column gap 18, max-width 720 centred.
        Column {
            id: col
            visible: page.loaded
            x: Math.max(24, (page.width - 720) / 2 + 24)
            y: 22
            width: Math.min(720, page.width) - 48
            spacing: 18

            // h1: 600 17px "Coucou" + .version 400 12px --dim-2, margin-left 8.
            Item {
                visible: page.pane === "" || page.pane === "general"
                width: col.width
                height: 20
                SText { id: h1; anchors.left: parent.left; width: implicitWidth; text: "Ambxst Robo"; size: 17; cssWeight: 600; wrapMode: Text.NoWrap }
                SText {
                    anchors.left: h1.right
                    anchors.leftMargin: 8
                    anchors.baseline: h1.baseline
                    text: page.version
                    size: 12
                    color: SettingsTheme.dim2
                    wrapMode: Text.NoWrap
                }
            }
            SecClaude { id: claudeSec; width: col.width; page: page; visible: page.shows("agents") }
            SecAgents { id: agentsSec; width: col.width; page: page; visible: page.shows("agents") }
            SecPlan { id: planSec; width: col.width; page: page; visible: page.shows("agents") }
            SecApi { id: apiSec; width: col.width; page: page; visible: page.shows("agents") }
            SecChat { id: chatSec; width: col.width; page: page; visible: page.shows("agents") }
            SecLocal { id: localSec; width: col.width; page: page; visible: page.shows("agents") }
            Loader {
                width: col.width
                active: page.agentsExtra !== null && page.pane === "agents"
                visible: active
                sourceComponent: page.agentsExtra
            }
            SecIntegrations { id: integrationsSec; width: col.width; page: page; visible: page.shows("integrations") }
            SecPills { id: pillsSec; width: col.width; page: page; visible: page.shows("general") }
            SecGeneral { id: generalSec; width: col.width; page: page; visible: page.shows("general") }
            SecShortcuts { id: shortcutsSec; width: col.width; page: page; visible: page.shows("general") }
            SecStyle { id: styleSec; width: col.width; page: page; visible: page.shows("style") }
            SHint { width: col.width; text: page.xL.GENERAL_TEXT.footer; visible: page.shows("general") }
        }
    }
    SText {
        visible: !page.loaded
        x: 24
        y: 24
        text: "Loading…"
        size: 13
        lh: 1.45
    }
    SPalette { id: palette; page: page }
    function openPalette(dot) { palette.show(dot); }
    function togglePalette(dot) { if (palette.open) palette.close(); else palette.show(dot); }
    onWidthChanged: palette.close()
}
