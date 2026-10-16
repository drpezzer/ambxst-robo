import QtQuick

// main.ts:525-592 chatProvidersSection — Google AI, OpenAI, OpenRouter keys.
SSection {
    id: sec
    property var page
    readonly property var xL: page.xL
    readonly property var xC: page.fresh(xL.CHAT_STRINGS)
    title: xC.providersTitle

    SHint { width: sec.innerWidth; text: sec.xC.providersHint }
    Column {
        width: sec.innerWidth
        spacing: 8
        Repeater {
            model: sec.xL.cloudRows()
            Column {
                id: prow
                required property var modelData
                property bool present: false
                property bool failed: false
                width: sec.innerWidth
                spacing: 4
                Connections {
                    target: sec.page
                    function onInfoChanged() { if (sec.page.info) prow.present = !!sec.page.info.chatKeys[prow.modelData.key]; }
                }
                Component.onCompleted: if (sec.page.info) present = !!sec.page.info.chatKeys[modelData.key]
                FlexRow {
                    width: parent.width
                    AccentLabel { accent: prow.modelData.accent; text: prow.modelData.name }
                    SInput {
                        id: input
                        secret: true
                        placeholder: prow.present ? sec.xC.stored : prow.modelData.placeholder
                    }
                    SButton {
                        text: sec.xC.save
                        onClicked: {
                            const value = input.text.trim();
                            if (!value) return;
                            sec.page.lib.Bridge.secretSet(prow.modelData.key, value).then(() => {
                                prow.present = true;
                                prow.failed = false;
                                input.text = "";
                                sec.page.keyChanged(prow.modelData.key, true);
                            }, () => { prow.failed = true; });
                        }
                    }
                    SButton {
                        visible: prow.present
                        kind: "danger"
                        text: sec.xC.remove
                        onClicked: sec.page.lib.Bridge.secretClear(prow.modelData.key).then(() => {
                            prow.present = false;
                            prow.failed = false;
                            sec.page.keyChanged(prow.modelData.key, false);
                        }, () => { prow.failed = true; })
                    }
                    SDot { dotColor: prow.failed ? SettingsTheme.amber : prow.present ? SettingsTheme.green : SettingsTheme.red }
                }
                SHint { anchors.left: parent.left; anchors.leftMargin: 144; width: parent.width - 144; text: sec.xC.keyFrom(prow.modelData.where) }
            }
        }
    }
}
