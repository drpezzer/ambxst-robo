import QtQuick

// main.ts:624-746 localSection — Ollama, LM Studio, any OpenAI-compatible server.
SSection {
    id: sec
    property var page
    readonly property var xL: page.xL
    readonly property var xC: page.fresh(xL.CHAT_STRINGS)
    property bool customKey: false
    title: xC.localTitle
    Connections {
        target: sec.page
        function onInfoChanged() { if (sec.page.info) sec.customKey = sec.page.info.customKey; }
    }

    SHint { width: sec.innerWidth; text: sec.xC.localHint }
    Column {
        width: sec.innerWidth
        spacing: 14
        Repeater {
            model: sec.xL.localRows()
            Column {
                id: blk
                required property var modelData
                readonly property string url: sec.page.rev >= 0 ? (sec.page.settings[modelData.field] || "") : ""
                readonly property bool connected: url !== ""
                readonly property bool inUse: sec.page.rev >= 0 && sec.page.settings.chatProvider === modelData.id
                property var status: null        // { kind: "hint" | "err", text }
                property bool connecting: false
                property int typed: 0            // bumps on input, for the exposure line
                width: sec.innerWidth
                spacing: 6
                readonly property var exposure: {
                    blk.typed;
                    if (connected) return sec.xL.exposure(url, modelData.id === "custom" && sec.customKey);
                    const withKey = modelData.id === "custom" && (sec.customKey || key.text.trim() !== "");
                    return sec.xL.exposure(input.text || modelData.usual, withKey);
                }

                // Connected: the address, "Use in chat" / "In use", Disconnect.
                FlexRow {
                    visible: blk.connected
                    width: parent.width
                    AccentLabel { accent: blk.modelData.accent; text: blk.modelData.name }
                    SPath { text: blk.url; readonly property real flexShrink: 1 }
                    SDot { ok: true }
                    SButton {
                        kind: blk.inUse ? "" : "primary"
                        text: blk.inUse ? sec.xC.inUse : sec.xC.useInChat
                        enabled2: !blk.inUse
                        onClicked: { sec.page.settings.chatProvider = blk.modelData.id; sec.page.save(); }
                    }
                    SButton {
                        kind: "danger"
                        text: sec.xC.disconnect
                        onClicked: sec.xL.disconnectLocal(sec.page.settings, blk.modelData.id).then(next => {
                            if (blk.modelData.id === "custom") sec.customKey = false;
                            Object.assign(sec.page.settings, next);
                            blk.status = null;
                            sec.page.save();
                        })
                    }
                }
                // Not connected: address (+ key for a custom server) and Connect.
                FlexRow {
                    visible: !blk.connected
                    width: parent.width
                    AccentLabel { accent: blk.modelData.accent; text: blk.modelData.name }
                    SInput { id: input; placeholder: blk.modelData.placeholder; onEdited: blk.typed++ }
                    SButton {
                        kind: "primary"
                        text: sec.xC.connect
                        enabled2: !blk.connecting
                        onClicked: {
                            blk.connecting = true;
                            blk.status = { kind: "hint", text: sec.xC.connecting };
                            sec.xL.connectLocal(sec.page.settings, blk.modelData.id, input.text, key.text).then(r => {
                                if (r.customKey) { key.text = ""; sec.customKey = true; }
                                blk.connecting = false;
                                if (!r.ok) { blk.status = { kind: "err", text: r.error }; return; }
                                Object.assign(sec.page.settings, r.settings);
                                blk.status = null;
                                input.text = "";
                                sec.page.save();
                            });
                        }
                    }
                }
                FlexRow {
                    visible: !blk.connected && blk.modelData.id === "custom"
                    width: parent.width
                    Item { readonly property real flexBasis: 132; implicitWidth: 132; implicitHeight: 0 }
                    SInput { id: key; secret: true; placeholder: sec.customKey ? sec.xC.stored : sec.xC.keyOptional; onEdited: blk.typed++ }
                }
                // The status <div>, then the exposure <div>: always there.
                Item {
                    width: parent.width
                    height: !blk.status ? 0.01 : blk.status.kind === "hint" ? stHint.height : stErr.height
                    SHint { id: stHint; visible: !!blk.status && blk.status.kind === "hint"; width: parent.width; text: visible ? blk.status.text : "" }
                    SNotice { id: stErr; visible: !!blk.status && blk.status.kind === "err"; width: parent.width; kind: "err"; text: visible ? blk.status.text : "" }
                }
                Item {
                    width: parent.width
                    height: blk.exposure ? (blk.exposure.cls === "hint" ? exHint.height : exNote.height) : 0.01
                    SHint { id: exHint; visible: !!blk.exposure && blk.exposure.cls === "hint"; width: parent.width; text: blk.exposure ? blk.exposure.text : "" }
                    SNotice { id: exNote; visible: !!blk.exposure && blk.exposure.cls !== "hint"; width: parent.width; kind: blk.exposure ? blk.exposure.cls : ""; text: blk.exposure ? blk.exposure.text : "" }
                }
            }
        }
    }
}
