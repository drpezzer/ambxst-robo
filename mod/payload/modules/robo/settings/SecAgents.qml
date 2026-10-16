import QtQuick

// agents.ts agentsSection — one block per agent other than Claude Code.
SSection {
    id: sec
    property var page
    readonly property var xL: page.xL
    title: xL.AGENT_TEXT.title

    SHint { width: sec.innerWidth; text: sec.xL.AGENT_TEXT.intro }
    Column {
        width: sec.innerWidth
        spacing: 14
        SHint {
            visible: !sec.page.agents || sec.page.agents.length === 0
            width: parent.width
            text: sec.xL.AGENT_TEXT.none
        }
        Repeater {
            model: sec.page.agents || []
            Column {
                id: blk
                required property var modelData
                property var status: modelData
                property var review: null
                width: sec.innerWidth
                spacing: 8
                function refresh() {
                    sec.page.lib.Bridge.agentHooksList().then(list => {
                        const fresh = (list || []).find(a => a.id === blk.status.id);
                        if (fresh) blk.status = fresh;
                        blk.review = null;
                    });
                }
                FlexRow {
                    width: parent.width
                    Item {
                        readonly property real flexBasis: Math.max(132, nameRow.implicitWidth)
                        implicitWidth: flexBasis
                        implicitHeight: nameRow.implicitHeight
                        Row {
                            id: nameRow
                            spacing: 8
                            SDot { ok: blk.status.installed; anchors.verticalCenter: parent.verticalCenter }
                            SText { text: blk.status.name; size: 12.5; lh: 1.45; wrapMode: Text.NoWrap }
                        }
                    }
                    SHint { text: blk.status.approvals ? sec.xL.AGENT_TEXT.approvals : sec.xL.AGENT_TEXT.displayOnly; readonly property real flexShrink: 1 }
                    Spacer {}
                    SButton {
                        kind: "primary"
                        text: blk.status.installed ? sec.xL.AGENT_TEXT.reinstall : sec.xL.AGENT_TEXT.install
                        enabled2: blk.status.hookReady
                        tooltip: blk.status.hookReady ? "" : sec.xL.AGENT_TEXT.relayMissing
                        onClicked: blk.review = sec.xL.agentChange(blk.status, true)
                    }
                    SButton {
                        visible: blk.status.installed
                        kind: "danger"
                        text: sec.xL.AGENT_TEXT.uninstall
                        onClicked: blk.review = sec.xL.agentChange(blk.status, false)
                    }
                }
                Column {
                    width: parent.width
                    spacing: 10
                    SPath { visible: !blk.review; width: parent.width; text: blk.status.path }
                    ReviewBody {
                        visible: !!blk.review
                        width: parent.width
                        gapSize: 10
                        page: sec.page
                        change: blk.review
                        onBack: blk.review = null
                        onApplied: blk.refresh()
                    }
                }
            }
        }
    }
}
