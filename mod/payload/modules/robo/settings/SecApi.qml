import QtQuick

// main.ts:330-403 apiSection — the Anthropic API key and the chat model.
SSection {
    id: sec
    property var page
    readonly property var xL: page.xL
    readonly property var xA: page.fresh(xL.API_TEXT)
    property bool present: false
    property var feedback: null   // { kind, text }
    title: "Claude"
    dot: present
    Connections {
        target: sec.page
        function onInfoChanged() { if (sec.page.info) sec.present = sec.page.info.hasKey; }
    }
    function refresh() {
        return sec.page.lib.Bridge.secretPresent("anthropic-api-key").then(p => { sec.present = p ?? false; });
    }

    SHint { width: sec.innerWidth; text: sec.xA.state(sec.present) }
    FlexRow {
        width: sec.innerWidth
        SLabel { text: sec.xA.apiKey }
        SInput {
            id: field
            secret: true
            placeholder: sec.xA.placeholder(sec.present)
            onCommitted: {}
        }
        SButton {
            kind: "primary"
            text: sec.xA.save
            onClicked: {
                const value = field.text.trim();
                if (!value) return;
                sec.feedback = null;
                sec.page.lib.Bridge.secretSet("anthropic-api-key", value).then(() => {
                    field.text = "";
                    sec.feedback = { kind: "ok", text: sec.xA.saved };
                    return sec.refresh();
                }, err => { sec.feedback = { kind: "err", text: sec.xA.couldNotSave(err) }; });
            }
        }
        SButton {
            visible: sec.present
            kind: "danger"
            text: sec.xA.remove
            onClicked: {
                sec.feedback = null;
                sec.page.lib.Bridge.secretClear("anthropic-api-key").then(() => {
                    sec.feedback = { kind: "ok", text: sec.xA.removed };
                    return sec.refresh();
                }, err => { sec.feedback = { kind: "err", text: sec.xA.couldNotRemove(err) }; });
            }
        }
    }
    FlexRow {
        width: sec.innerWidth
        SLabel { text: sec.xA.model }
        SSelect {
            options: sec.page.rev >= 0 ? sec.xL.modelOptions(sec.page.settings.model) : []
            value: sec.page.rev >= 0 ? sec.page.settings.model : ""
            onActivated: v => { sec.page.settings.model = v; sec.page.save(); }
        }
    }
    // The feedback <div>: always there (its gap too), empty until a click.
    Item {
        width: sec.innerWidth
        height: fb.visible ? fb.height : 0.01
        SNotice { id: fb; visible: !!sec.feedback; width: parent.width; kind: sec.feedback ? sec.feedback.kind : ""; text: sec.feedback ? sec.feedback.text : "" }
    }
}
