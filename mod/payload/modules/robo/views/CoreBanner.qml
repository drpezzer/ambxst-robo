import QtQuick
import qs.modules.robo as C

// Port (zero-touch install): the Robo tab's banner for the daemon's setup
// and updates (RoboCore.qml) — "Setting up Robo…", "Updating Robo's core…",
// an error with Retry — and, once, the offer to connect Claude Code.
// Width from the parent; it sizes its own height, 0 when there is nothing to say.
Item {
    id: root
    readonly property var core: C.RoboCore
    readonly property var hooks: C.RoboCore.hooks
    readonly property int rev: C.Robo.rev
    readonly property bool rtl: rev >= 0 && C.Robo.lib.I18n.isRtl()
    function t(s, vars) { void rev; return C.RoboCore.t(s, vars); }
    /** direction: rtl sets the paragraph direction (an RLM as the first strong character). */
    function bidi(s) { return rtl && s ? "\u200F" + s : s; }

    /** "core" | "hooks" | "" */
    readonly property string kind: {
        const p = core.phase;
        if (p === "setup" || p === "update" || p === "waiting" || p === "ready" || p === "error") return "core";
        const h = hooks.state;
        if (h === "offer" || h === "working" || h === "done" || h === "error") return "hooks";
        return "";
    }
    readonly property bool canRetry: kind === "core" && core.phase === "error"
    readonly property bool canConnect: kind === "hooks" && (hooks.state === "offer" || hooks.state === "working" || hooks.state === "error")
    readonly property bool canDismiss: kind === "hooks" && (hooks.state === "offer" || hooks.state === "error")
    readonly property bool working: kind === "core" ? core.busy : hooks.state === "working"
    readonly property bool bad: kind === "core" ? core.phase === "error" : hooks.state === "error"
    readonly property string title: kind === "core" ? core.headline
        : hooks.state === "done" || hooks.state === "error" ? hooks.message
        : kind === "hooks" ? t("Let Robo see your Claude Code sessions?") : ""
    readonly property string body: {
        if (kind === "core") {
            if (core.phase === "error" && core.detail) return core.detail;
            // The mod is newer than the daemon still answering: some of Robo waits for it.
            if (core.busy && core.running !== "" && core.running !== core.want)
                return t("Some of Robo waits for its new core (version {version}).", { version: core.want });
            return "";
        }
        if (hooks.state === "offer" || hooks.state === "working")
            return t("Robo adds its hooks to ~/.claude/settings.json (it keeps a backup, your own hooks stay). New sessions pick them up.");
        return "";
    }

    visible: kind !== "" && opacity > 0
    opacity: kind !== "" ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: 220; easing.type: Easing.BezierSpline; easing.bezierCurve: C.RoboTheme.easeOut } }
    implicitHeight: kind !== "" ? box.height : 0

    Rectangle {
        id: box
        width: root.width
        height: col.implicitHeight + 20
        radius: 16
        color: C.RoboTheme.card
        border.width: 1
        border.color: root.bad ? Qt.rgba(1, 0.35, 0.35, 0.55) : Qt.tint(C.RoboTheme.card, C.RoboTheme.hairline)

        Column {
            id: col
            x: 14
            y: 10
            width: parent.width - 28
            spacing: 6
            LayoutMirroring.enabled: root.rtl
            LayoutMirroring.childrenInherit: true
            Row {
                width: parent.width
                spacing: 8
                // A small pulse while something is under way.
                Rectangle {
                    id: dot
                    width: 8; height: 8; radius: 4
                    anchors.verticalCenter: parent.verticalCenter
                    visible: root.working || root.bad || C.RoboCore.phase === "ready" || root.hooks.state === "done"
                    color: root.bad ? "#ff6b6b" : root.working ? C.RoboTheme.ink2 : "#5fd38d"
                    SequentialAnimation on opacity {
                        running: root.working && root.visible
                        loops: Animation.Infinite
                        NumberAnimation { to: 0.25; duration: 600 }
                        NumberAnimation { to: 1; duration: 600 }
                    }
                }
                C.CText {
                    width: parent.width - (dot.visible ? dot.width + parent.spacing : 0)
                    text: root.bidi(root.title)
                    size: 13
                    cssWeight: 600
                    wrapMode: Text.Wrap
                    maximumLineCount: 4
                    // LayoutMirroring turns it to the right in RTL.
                    horizontalAlignment: Text.AlignLeft
                }
            }
            C.CText {
                visible: text !== ""
                width: parent.width
                text: root.bidi(root.body)
                size: 11.5
                color: C.RoboTheme.ink2
                wrapMode: Text.Wrap
                maximumLineCount: 4
                horizontalAlignment: Text.AlignLeft
            }
            Row {
                spacing: 8
                // (Not the buttons' own `visible`: it reads false while this row is hidden.)
                visible: root.canRetry || root.canConnect || root.canDismiss
                Btn {
                    id: retryBtn
                    visible: root.canRetry
                    kind: "primary"
                    label: root.t("Retry")
                    onClicked: C.RoboCore.retry()
                }
                Btn {
                    id: connectBtn
                    visible: root.canConnect
                    off: root.hooks.state === "working"
                    kind: "primary"
                    label: root.t("Connect")
                    onClicked: if (root.hooks.state !== "working") root.hooks.connect()
                }
                Btn {
                    id: laterBtn
                    visible: root.canDismiss
                    label: root.t("Not now")
                    onClicked: root.hooks.dismiss()
                }
            }
        }
    }
}
