pragma Singleton

import QtQuick
import Quickshell

// Thin QML front for lib/viewlogic.ts, plus colour helpers the views share.
Singleton {
    readonly property var vl: Robo.lib.ViewLogic
    function hasSessionTicker(task) { return vl.hasSessionTicker(task); }
    function idleStatus(id, info, model) { return vl.idleStatus(id, info, model); }
    function timeAgo(v) { return vl.timeAgo(v); }
    function idleActions(task, info) {
        return vl.idleActions(task, () => Robo.island && Robo.island.actions.openSettingsWindow())
            .map(a => ({ label: a.label, color: cssHex(a.color), run: a.run }));
    }
    /** "#rrggbbaa" (CSS order) → Qt colour (Qt reads #aarrggbb). */
    function cssHex(s) {
        if (typeof s === "string" && /^#[0-9a-fA-F]{8}$/.test(s)) return "#" + s.slice(7, 9) + s.slice(1, 7);
        return s;
    }
}
