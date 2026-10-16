import QtQuick

// main.ts:157-230 claudeSection — the Claude Code hooks.
SSection {
    id: sec
    property var page
    readonly property var xL: page.xL
    readonly property var st: page.rev >= 0 && page.info ? page.info.status
        : ({ installed: false, planRelayInstalled: false, settingsPath: "", hookPath: "", hookReady: false })
    property var review: null
    title: "Claude Code"
    dot: st.installed

    Column {
        width: sec.innerWidth
        spacing: 12
        Column {
            visible: !sec.review
            width: parent.width
            spacing: 12
            SHint { width: parent.width; text: sec.xL.CLAUDE_TEXT.hint(sec.st.installed) }
            FlexRow {
                width: parent.width
                SLabel { text: "settings.json" }
                SPath { text: sec.st.settingsPath; readonly property real flexShrink: 1 }
            }
            FlexRow {
                width: parent.width
                SLabel { text: sec.xL.CLAUDE_TEXT.relay }
                SPath { text: sec.st.hookPath; readonly property real flexShrink: 1 }
                SDot { ok: sec.st.hookReady }
            }
            SNotice { visible: !sec.st.hookReady; width: parent.width; kind: "warn"; text: sec.xL.CLAUDE_TEXT.relayWarn }
            FlexRow {
                width: parent.width
                SButton {
                    kind: "primary"
                    text: sec.xL.CLAUDE_TEXT.install(sec.st.installed)
                    // A hook pointing at a relay that isn't there would break every session.
                    enabled2: sec.st.hookReady
                    tooltip: sec.st.hookReady ? "" : sec.xL.CLAUDE_TEXT.relayTitle
                    onClicked: sec.review = sec.xL.hooksChange(true)
                }
                SButton {
                    visible: sec.st.installed
                    kind: "danger"
                    text: sec.xL.CLAUDE_TEXT.uninstall
                    onClicked: sec.review = sec.xL.hooksChange(false)
                }
            }
        }
        ReviewBody {
            visible: !!sec.review
            width: parent.width
            page: sec.page
            change: sec.review
            onBack: sec.review = null
            onApplied: { sec.review = null; sec.page.refreshStatus(); }
        }
    }
}
