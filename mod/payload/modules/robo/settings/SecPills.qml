import QtQuick

// main.ts:412-485 activePillsSection — the main tool and the declared pills
// (agents and chat providers; services are declared under Integrations).
SSection {
    id: sec
    property var page
    readonly property var xL: page.xL
    readonly property var xT: page.fresh(xL.PILLS_TEXT)
    readonly property int used: page.rev >= 0 ? page.settings.activeIntegrations.length : 0
    title: xT.title

    SHint { width: sec.innerWidth; text: sec.xT.intro }
    SHint { width: sec.innerWidth; text: sec.xT.slots(sec.used); full: sec.used >= sec.xL.MAX_ACTIVE }
    FlexRow {
        width: sec.innerWidth
        SLabel { text: sec.xT.mainTool }
        SSelect {
            options: sec.xL.mainOptions()
            value: sec.page.rev >= 0 ? sec.page.settings.mainPill : ""
            onActivated: v => {
                const next = sec.xL.chooseMain(sec.page.settings, v);
                if (!next) return;
                sec.page.settings.mainPill = next.mainPill;
                sec.page.settings.activeIntegrations = next.activeIntegrations;
                sec.page.declaredChanged();
            }
        }
    }
    Column {
        width: sec.innerWidth
        spacing: 12
        Repeater {
            model: sec.page.rev >= 0 && sec.page.info ? sec.xL.pillGroups(sec.page.settings, sec.page.info.connected) : []
            // .pill-group: border-top hairline, padding-top 10, gap 8.
            Item {
                id: grpBox
                required property var modelData
                width: sec.innerWidth
                height: grp.implicitHeight
                Rectangle { width: parent.width; height: 1; color: SettingsTheme.hairline }
            Column {
                id: grp
                readonly property var modelData: grpBox.modelData
                width: sec.innerWidth
                topPadding: 11
                spacing: 8
                SText { text: grp.modelData.title; size: 11; cssWeight: 600; color: SettingsTheme.dim; wrapMode: Text.NoWrap }
                Repeater {
                    model: grp.modelData.rows
                    // .pill-row: flex, centred, gap 8, min-height 24.
                    Item {
                        id: prow
                        required property var modelData
                        width: grp.width
                        height: Math.max(24, nm.height)
                        SColorDot {
                            id: cdot
                            anchors.left: parent.left
                            page: sec.page
                            pillId: prow.modelData.id
                            pillName: prow.modelData.name
                            catalog: prow.modelData.color
                            size: 10
                            anchors.verticalCenter: parent.verticalCenter
                        }
                        SText {
                            id: nm
                            anchors.left: cdot.right
                            anchors.leftMargin: 8
                            anchors.verticalCenter: parent.verticalCenter
                            text: prow.modelData.name
                            size: 12.5
                            lh: 1.45
                            wrapMode: Text.NoWrap
                            color: prow.modelData.full ? SettingsTheme.dim2 : SettingsTheme.ink
                        }
                        SText {
                            anchors.right: sw.visible ? sw.left : parent.right
                            anchors.rightMargin: sw.visible ? 8 : 0
                            anchors.verticalCenter: parent.verticalCenter
                            text: prow.modelData.state
                            size: 11.5
                            color: SettingsTheme.dim
                            wrapMode: Text.NoWrap
                        }
                        SSwitch {
                            id: sw
                            visible: !prow.modelData.isMain
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            on: prow.modelData.on
                            enabled2: !prow.modelData.full
                            onToggled: {
                                const next = sec.xL.togglePill(sec.page.settings, prow.modelData.id);
                                if (!next) return;
                                sec.page.settings.activeIntegrations = next;
                                sec.page.declaredChanged();
                            }
                        }
                    }
                }
            }
            }
        }
    }
}
