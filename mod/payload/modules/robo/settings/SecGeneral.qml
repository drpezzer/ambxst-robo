import QtQuick

// main.ts:878-989 generalSection + 1207-1249 recapRows.
SSection {
    id: sec
    property var page
    readonly property var xL: page.xL
    readonly property var xG: page.fresh(xL.GENERAL_TEXT)
    // A fresh copy per change: the same object would not notify, and switches
    // reading it would keep showing the old value (saved, but drawn wrong).
    readonly property var s: page.rev >= 0 && page.settings ? Object.assign({}, page.settings) : ({})
    property int customCount: 0
    property bool recapOn: true
    property string recapFeedback: ""
    property bool clearing: false
    property var monitors: []
    title: xG.title

    function countCustom() {
        sec.page.lib.Bridge.customSounds(sec.xL.SOUND_NAMES).then(own => { sec.customCount = own ? own.length : 0; });
    }
    function load() {
        countCustom();
        sec.page.lib.Bridge.recapPrefs().then(p => { if (p) sec.recapOn = p.enabled; });
        sec.page.lib.Bridge.listMonitors().then(list => { sec.monitors = list || []; });
    }
    Connections {
        target: sec.page
        function onInfoChanged() { sec.load(); }
    }
    Timer { id: recount; interval: 300; onTriggered: sec.countCustom() }
    Timer { id: clearDone; interval: 2400; onTriggered: { sec.clearing = false; sec.recapFeedback = ""; } }

    FlexRow {
        width: sec.innerWidth
        SLabel { text: sec.xG.sound }
        SSwitch { on: !!sec.s.soundEnabled; onToggled: next => { sec.page.settings.soundEnabled = next; sec.page.save(); } }
        SSlider {
            from: 0; to: 0.2; step: 0.005
            value: sec.s.soundVolume ?? 0
            onMoved: v => { sec.page.settings.soundVolume = v; sec.page.save(); }
        }
    }
    FlexRow {
        width: sec.innerWidth
        SButton { text: sec.xG.openFolder; onClicked: sec.page.lib.Bridge.revealSoundsFolder() }
        SButton { text: sec.xG.reload; onClicked: sec.page.lib.Bridge.reloadSounds().then(() => recount.start()) }
        SHint { text: sec.xG.custom(sec.customCount); wrapMode: Text.NoWrap; visible: true }
    }
    SHint { width: sec.innerWidth; text: sec.xG.soundsHint }
    FlexRow {
        width: sec.innerWidth
        SLabel { text: sec.xG.openOnHover }
        SSwitch { on: !!sec.s.openOnHover; onToggled: next => { sec.page.settings.openOnHover = next; sec.page.save(); } }
    }
    SHint { width: sec.innerWidth; text: sec.xG.hoverHint }
    FlexRow {
        width: sec.innerWidth
        SLabel { text: sec.xG.keepMascotAbove }
        SSwitch { on: !!sec.s.keepMascotAboveFullscreen; onToggled: next => { sec.page.settings.keepMascotAboveFullscreen = next; sec.page.save(); } }
    }
    SHint { width: sec.innerWidth; text: sec.xG.keepMascotAboveHint }
    // (Theme colours: the Style tab, SecStyle.qml.)
    FlexRow {
        width: sec.innerWidth
        SLabel { text: sec.xG.autoClose }
        SInput {
            id: autoClose
            fixedWidth: 72
            text: String(Math.round(sec.s.autoCloseInterval ?? 15))
            onCommitted: {
                const v = sec.xL.clampAutoClose(autoClose.text);
                sec.page.settings.autoCloseInterval = v;
                autoClose.text = String(v);
                sec.page.save();
            }
        }
        SHint { text: sec.xG.autoCloseUnit; readonly property real flexShrink: 1 }
    }
    FlexRow {
        width: sec.innerWidth
        SLabel { text: sec.xG.livesOn }
        SSelect {
            options: [{ value: "primary", text: sec.xG.mainDisplay }, { value: "cursor", text: sec.xG.underCursor }]
                .concat(sec.monitors.map(m => ({ value: m.key, text: m.label })))
            value: sec.xL.pickScreen(sec.s.screen || "primary", sec.monitors.map(m => m.key))
            onActivated: v => { sec.page.settings.screen = v; sec.page.save(); }
        }
    }
    FlexRow {
        width: sec.innerWidth
        SLabel { text: sec.xG.autostart }
        SSwitch { on: !!sec.s.autostart; onToggled: next => { sec.page.settings.autostart = next; sec.page.save(); } }
    }
    // Weekly recap: the prefs live with the history in ambxst-robo.
    FlexRow {
        width: sec.innerWidth
        SLabel { text: sec.xG.recapLabel }
        SSwitch { on: sec.recapOn; onToggled: next => { sec.recapOn = next; sec.page.lib.Bridge.recapSetEnabled(next); } }
        SHint { text: sec.xG.recapKeep; readonly property real flexShrink: 1 }
    }
    FlexRow {
        width: sec.innerWidth
        Item { readonly property real flexBasis: 132; implicitWidth: 132; implicitHeight: 0 }
        SButton {
            kind: "danger"
            text: sec.xG.recapClear
            enabled2: !sec.clearing
            onClicked: {
                sec.clearing = true;
                sec.page.lib.Bridge.recapClear().then(() => { sec.recapFeedback = sec.xG.recapCleared; clearDone.start(); });
            }
        }
        SHint { text: sec.recapFeedback; wrapMode: Text.NoWrap }
    }
    FlexRow {
        width: sec.innerWidth
        Item { readonly property real flexBasis: 132; implicitWidth: 132; implicitHeight: 0 }
        // flex: 1 1 0; min-width: 0
        SHint { text: sec.xG.recapAbout; readonly property real flexBasis: 0; readonly property real flexGrow: 1 }
    }
    FlexRow {
        width: sec.innerWidth
        SLabel { text: sec.xG.language }
        SSelect {
            options: sec.xL.languageOptions()
            value: sec.page.rev >= 0 ? sec.xL.languageValue(sec.page.settings) : ""
            onActivated: v => {
                sec.page.settings.language = v;
                sec.page.save();
                sec.xL.applyLanguage(sec.page.settings);
            }
        }
    }
}
