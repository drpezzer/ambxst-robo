import QtQuick

// main.ts:793-874 integrationsSection — services: switch, colour, keys.
SSection {
    id: sec
    property var page
    readonly property var xL: page.xL
    readonly property var xT: page.fresh(xL.INTEGRATIONS_TEXT)
    title: xT.title

    SHint { width: sec.innerWidth; text: sec.xT.note(sec.page.rev >= 0 ? sec.page.settings.activeIntegrations.length : 0) }

    // ── Port (his ask): one box for every key ──
    // Paste any key: its prefix says which service it is for (GitHub, Stripe,
    // Notion, Resend, Cal.com, or an AI provider); it is saved there and that
    // service's pill turns on. A key that doesn't say asks which service.
    property string keyNote: ""
    property bool keyNoteBad: false
    property string pendingKey: ""
    function addKey(raw) {
        const key = (raw || "").trim();
        if (!key) return;
        const target = sec.xL.detectKey(key);
        if (!target) {
            sec.pendingKey = key;
            sec.keyNote = "";
            return;
        }
        sec.storeKey(key, target);
    }
    function storeKey(key, target) {
        sec.page.lib.Bridge.secretSet(target.secret, key).then(() => {
            keyBox.text = "";
            sec.pendingKey = "";
            sec.keyNoteBad = false;
            if (target.kind === "ai") {
                sec.keyNote = "Saved your " + target.name + " key (Agents → API keys).";
            } else if (sec.page.settings.activeIntegrations.includes(target.id)) {
                sec.keyNote = "Saved your " + target.name + " key.";
            } else {
                const next = sec.xL.toggleIntegration(sec.page.settings, target.id);
                if (next) {
                    sec.page.settings.activeIntegrations = next;
                    sec.page.declaredChanged();
                    sec.keyNote = "Added " + target.name + " — its pill is on.";
                } else {
                    sec.keyNote = "Saved your " + target.name + " key. Turn it on below (the pills are full).";
                }
            }
            sec.page.rerender();
        }, e => {
            sec.keyNoteBad = true;
            sec.keyNote = String(e).replace(/^Error:\s*/, "");
        });
    }
    FlexRow {
        width: sec.innerWidth
        SInput {
            id: keyBox
            secret: true
            placeholder: "Paste a key: GitHub, Stripe, Vercel, Notion, Cal.com, Resend, n8n, or an AI provider"
            onCommitted: sec.addKey(keyBox.text)
        }
        SButton { text: "Add"; kind: "primary"; onClicked: sec.addKey(keyBox.text) }
    }
    SText {
        visible: sec.keyNote !== ""
        width: sec.innerWidth
        text: sec.keyNote
        size: 12
        color: sec.keyNoteBad ? SettingsTheme.red : SettingsTheme.green
    }
    Column {
        visible: sec.pendingKey !== ""
        width: sec.innerWidth
        spacing: 8
        SText { text: "Which service is this key for?"; size: 12; color: SettingsTheme.dim }
        Flow {
            width: sec.innerWidth
            spacing: 6
            Repeater {
                model: sec.xL.unprefixedTargets()
                SButton { required property var modelData; text: modelData.name; onClicked: sec.storeKey(sec.pendingKey, modelData) }
            }
            SButton { text: "Cancel"; onClicked: { sec.pendingKey = ""; keyBox.text = ""; } }
        }
    }
    Column {
        width: sec.innerWidth
        spacing: 14
        Repeater {
            model: sec.xL.integrationRows()
            // display:flex; gap:12px; align-items:flex-start
            Item {
                id: irow
                required property var modelData
                readonly property bool active: sec.page.rev >= 0 && sec.page.settings.activeIntegrations.includes(modelData.id)
                width: sec.innerWidth
                height: Math.max(left.height, rows.height)
                // min-width 132, padding-top 4, centred, gap 8.
                Item {
                    id: left
                    anchors.left: parent.left
                    width: Math.max(132, lrow.implicitWidth)
                    height: lrow.implicitHeight + 4
                    Row {
                        id: lrow
                        y: 4
                        spacing: 8
                        SSwitch {
                            anchors.verticalCenter: parent.verticalCenter
                            on: irow.active
                            onToggled: {
                                const next = sec.xL.toggleIntegration(sec.page.settings, irow.modelData.id);
                                if (!next) return;
                                sec.page.settings.activeIntegrations = next;
                                sec.page.declaredChanged();
                            }
                        }
                        SColorDot {
                            anchors.verticalCenter: parent.verticalCenter
                            page: sec.page
                            pillId: irow.modelData.id
                            pillName: irow.modelData.name
                            catalog: irow.modelData.color
                        }
                        SText { anchors.verticalCenter: parent.verticalCenter; text: irow.modelData.name; size: 12.5; lh: 1.45; wrapMode: Text.NoWrap }
                    }
                }
                Column {
                    id: rows
                    anchors.left: left.right
                    anchors.leftMargin: 12
                    width: irow.width - left.width - 12
                    spacing: 6
                    Repeater {
                        model: irow.modelData.fields
                        FlexRow {
                            id: frow
                            required property var modelData
                            property bool present: false
                            property bool failed: false
                            width: rows.width
                            Component.onCompleted: if (sec.page.info) present = !!sec.page.info.present[modelData.key]
                            Connections {
                                target: sec.page
                                function onInfoChanged() { if (sec.page.info) frow.present = !!sec.page.info.present[frow.modelData.key]; }
                            }
                            SLabel { minW: 104; text: frow.modelData.label }
                            // Port (his ask): keys go in the box above; a key
                            // field says whether one is saved, and can remove it.
                            SText {
                                visible: frow.modelData.secret
                                text: frow.present ? "Saved" : "Paste it in the box above"
                                size: 12
                                color: frow.present ? SettingsTheme.ink : SettingsTheme.dim2
                                wrapMode: Text.NoWrap
                            }
                            SButton {
                                visible: frow.modelData.secret && frow.present
                                text: "Remove"
                                onClicked: sec.page.lib.Bridge.secretSet(frow.modelData.key, "").then(() => { frow.present = false; sec.page.rerender(); })
                            }
                            SInput {
                                id: input
                                visible: !frow.modelData.secret
                                secret: frow.modelData.secret
                                placeholder: frow.present ? sec.xL.CHAT_STRINGS.stored : frow.modelData.placeholder
                            }
                            SButton {
                                visible: !frow.modelData.secret
                                text: sec.xT.save
                                onClicked: {
                                    const value = input.text.trim();
                                    // An empty value deletes the key (secrets.rs).
                                    sec.page.lib.Bridge.secretSet(frow.modelData.key, value).then(() => {
                                        frow.present = value.length > 0;
                                        frow.failed = false;
                                        input.text = "";
                                    }, () => { frow.failed = true; });
                                }
                            }
                            SDot { dotColor: frow.failed ? SettingsTheme.amber : frow.present ? SettingsTheme.green : SettingsTheme.red }
                        }
                    }
                    SHint { visible: !!irow.modelData.hint; width: rows.width; text: irow.modelData.hint || "" }
                    // Spotify: said only when there is no Spotify to launch.
                    Item {
                        visible: irow.modelData.id === "integration_spotify"
                        width: rows.width
                        height: spHint.text ? spHint.height + 5 : 5
                        property bool missing: false
                        Component.onCompleted: if (irow.modelData.id === "integration_spotify") sec.page.lib.Bridge.spotifyInstalled().then(ok => { missing = ok === false; })
                        SHint { id: spHint; y: 5; width: parent.width; text: parent.missing ? sec.xT.notInstalled : "" }
                    }
                }
            }
        }
    }
}
