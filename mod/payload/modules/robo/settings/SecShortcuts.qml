import QtQuick
import qs.modules.robo as C

// main.ts:1027-1204 shortcutsSection. On Ambxst the "From anywhere" keys are
// Hyprland binds made by the shell from settings.shortcuts (RoboShell
// applyShortcuts → `ambxst-robo --shortcut <id>`); ambxst-robo reports them as
// `blocked: "shell"`. Recording a new key works as upstream.
SSection {
    id: sec
    property var page
    readonly property var xL: page.xL
    readonly property var xU: page.fresh(xL.SHORTCUTS_UI)
    readonly property var report: page.rev >= 0 && page.info ? page.info.shortcutReport : null
    readonly property var note: page.langRev >= 0 ? xL.shortcutNote(report) : null
    property string recordingId: ""
    property var recordingBinding: null
    property string feedback: ""
    title: xU.title

    function store(id, binding) {
        const S = sec.page.settings;
        const next = Object.assign({}, S.shortcuts || {});
        next[id] = binding;
        S.shortcuts = next;
        sec.page.save();
    }
    function record(row) {
        stop();
        feedback = "";
        recordingId = row.id;
        recordingBinding = { keys: row.keys, enabled: row.enabled };
        sec.page.lib.Bridge.shortcutsSuspend(true);
        catcher.forceActiveFocus();
    }
    function stop() {
        if (!recordingId) return;
        recordingId = "";
        // Takes the global shortcuts back, from what is saved by now.
        sec.page.lib.Bridge.shortcutsSuspend(false);
    }
    /** A QML key event → the parts of a KeyboardEvent the recorder reads. */
    function keyPress(e) {
        const k = e.key;
        let key = "", code = "";
        if (k >= Qt.Key_A && k <= Qt.Key_Z) {
            const ch = String.fromCharCode(97 + k - Qt.Key_A);
            key = e.text && e.text.length === 1 && !(e.modifiers & Qt.ControlModifier) ? e.text : ch;
            code = "Key" + ch.toUpperCase();
        } else if (k >= Qt.Key_0 && k <= Qt.Key_9) {
            key = e.text || String(k - Qt.Key_0);
            code = "Digit" + (k - Qt.Key_0);
        } else if (k >= Qt.Key_F1 && k <= Qt.Key_F24) {
            key = code = "F" + (k - Qt.Key_F1 + 1);
        } else {
            const named = {
                [Qt.Key_Control]: ["Control", "ControlLeft"], [Qt.Key_Alt]: ["Alt", "AltLeft"],
                [Qt.Key_AltGr]: ["AltGraph", "AltRight"], [Qt.Key_Shift]: ["Shift", "ShiftLeft"],
                [Qt.Key_Meta]: ["Meta", "MetaLeft"], [Qt.Key_Super_L]: ["Meta", "MetaLeft"], [Qt.Key_Super_R]: ["Meta", "MetaRight"],
                [Qt.Key_Escape]: ["Escape", "Escape"], [Qt.Key_Backspace]: ["Backspace", "Backspace"],
                [Qt.Key_Delete]: ["Delete", "Delete"], [Qt.Key_Insert]: ["Insert", "Insert"],
                [Qt.Key_Home]: ["Home", "Home"], [Qt.Key_End]: ["End", "End"],
                [Qt.Key_PageUp]: ["PageUp", "PageUp"], [Qt.Key_PageDown]: ["PageDown", "PageDown"],
                [Qt.Key_Up]: ["ArrowUp", "ArrowUp"], [Qt.Key_Down]: ["ArrowDown", "ArrowDown"],
                [Qt.Key_Left]: ["ArrowLeft", "ArrowLeft"], [Qt.Key_Right]: ["ArrowRight", "ArrowRight"],
                [Qt.Key_Space]: [" ", "Space"], [Qt.Key_Return]: ["Enter", "Enter"], [Qt.Key_Enter]: ["Enter", "NumpadEnter"],
                [Qt.Key_Tab]: ["Tab", "Tab"], [Qt.Key_Comma]: [",", "Comma"], [Qt.Key_Period]: [".", "Period"],
                [Qt.Key_Slash]: ["/", "Slash"], [Qt.Key_Semicolon]: [";", "Semicolon"], [Qt.Key_Apostrophe]: ["'", "Quote"],
                [Qt.Key_QuoteLeft]: ["`", "Backquote"], [Qt.Key_BracketLeft]: ["[", "BracketLeft"],
                [Qt.Key_BracketRight]: ["]", "BracketRight"], [Qt.Key_Backslash]: ["\\", "Backslash"],
                [Qt.Key_Minus]: ["-", "Minus"], [Qt.Key_Equal]: ["=", "Equal"], [Qt.Key_Dead_Acute]: ["Dead", ""],
            }[k];
            if (named) { key = named[0]; code = named[1]; }
            else { key = e.text || "Unidentified"; code = ""; }
            // Ctrl+Alt (AltGr on some layouts) typing a character.
            if (e.text && e.text.length === 1 && (e.modifiers & Qt.ControlModifier) && (e.modifiers & Qt.AltModifier) && e.text.charCodeAt(0) > 32) key = e.text;
        }
        return {
            key, code,
            ctrlKey: !!(e.modifiers & Qt.ControlModifier),
            altKey: !!(e.modifiers & Qt.AltModifier),
            shiftKey: !!(e.modifiers & Qt.ShiftModifier),
            metaKey: !!(e.modifiers & Qt.MetaModifier),
        };
    }
    // Captures the keyboard while recording (window keydown, capture phase).
    Item {
        id: catcher
        width: 0
        height: 0
        focus: false
        Keys.onPressed: event => {
            if (!sec.recordingId) return;
            event.accepted = true;
            const r = sec.xL.recordKey(sec.keyPress(event), sec.recordingBinding);
            const id = sec.recordingId;
            if (r.kind === "pending") return;
            if (r.kind === "store") { sec.stop(); sec.store(id, r.binding); return; }
            if (r.kind === "finish") { sec.stop(); return; }
            if (r.kind === "feedback") {
                if (r.finish) sec.stop();
                sec.feedback = r.feedback;
            }
        }
        onActiveFocusChanged: if (!activeFocus) sec.stop()
    }
    SHint { width: sec.innerWidth; text: sec.xU.hint }
    // .subhead: 600 11px, --dim-2, uppercase, letter-spacing .04em, margin-top 4.
    Item {
        width: sec.innerWidth
        height: sub1.height + 4
        SText { id: sub1; y: 4; text: sec.xU.global.toUpperCase(); size: 11; cssWeight: 600; color: SettingsTheme.dim2; letterSpacing: 0.44; wrapMode: Text.NoWrap }
    }
    Column {
        width: sec.innerWidth
        spacing: 8
        Repeater {
            model: sec.page.rev >= 0 && sec.page.langRev >= 0 ? sec.xL.shortcutRows(sec.page.settings, sec.report) : []
            // .row.shortcut: nowrap, gap 10, centred.
            Item {
                id: srow
                required property var modelData
                readonly property bool rec: sec.recordingId === modelData.id
                width: sec.innerWidth
                height: Math.max(cap.height, nm.height, 20)
                SSwitch {
                    id: sw
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    on: srow.modelData.enabled
                    onToggled: next => sec.store(srow.modelData.id, { keys: srow.modelData.keys, enabled: next })
                }
                SText {
                    id: nm
                    anchors.left: sw.right
                    anchors.leftMargin: 10
                    width: srow.width - 46 - 10 - cap.width - (tag.visible ? tag.width + 10 : 0)
                    anchors.verticalCenter: parent.verticalCenter
                    text: srow.modelData.name
                    size: 12.5
                    lh: 1.45
                    color: srow.modelData.enabled ? SettingsTheme.ink : SettingsTheme.dim2
                }
                STag {
                    id: tag
                    visible: !!srow.modelData.tag
                    anchors.right: cap.left
                    anchors.rightMargin: 10
                    anchors.verticalCenter: parent.verticalCenter
                    kind: srow.modelData.tag ? srow.modelData.tag.cls : ""
                    text: srow.modelData.tag ? srow.modelData.tag.text : ""
                }
                SKeycap {
                    id: cap
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    text: srow.rec ? sec.xU.recording : srow.modelData.keycap
                    recording: srow.rec
                    enabled2: srow.modelData.enabled
                    onClicked: sec.record(srow.modelData)
                }
            }
        }
    }
    // The note under the list (blockedNote): on Ambxst, the shell's binds.
    Column {
        width: sec.innerWidth
        spacing: 0
        // An empty <div> still takes its gap in the section.
        Item { width: 1; height: 0.01 }
        SNotice { visible: !!sec.note && !!sec.note.notice; width: parent.width; kind: sec.note && sec.note.notice ? sec.note.notice.cls : ""; text: sec.note && sec.note.notice ? sec.note.notice.text : "" }
        SHint { visible: !!sec.note && sec.note.hint !== ""; width: parent.width; text: sec.note ? sec.note.hint : "" }
        SDiff {
            visible: !!sec.note && sec.note.commands.length > 0
            width: parent.width
            lines: sec.note ? sec.note.commands.map(c => ({ cls: "ctx", text: c })) : []
        }
    }
    Item {
        width: sec.innerWidth
        height: fb.visible ? fb.height : 0.01
        SNotice { id: fb; visible: sec.feedback !== ""; width: parent.width; kind: "warn"; text: sec.feedback }
    }
    FlexRow {
        width: sec.innerWidth
        SButton {
            text: sec.xU.reset
            onClicked: {
                sec.stop();
                sec.page.settings.shortcuts = {};
                sec.feedback = "";
                sec.page.save();
            }
        }
    }
    Item {
        width: sec.innerWidth
        height: sub2.height + 4
        SText { id: sub2; y: 4; text: sec.xU.island.toUpperCase(); size: 11; cssWeight: 600; color: SettingsTheme.dim2; letterSpacing: 0.44; wrapMode: Text.NoWrap }
    }
    Column {
        width: sec.innerWidth
        spacing: 8
        Repeater {
            model: sec.page.langRev >= 0 ? sec.xL.islandShortcuts() : []
            Item {
                id: irow
                required property var modelData
                width: sec.innerWidth
                height: Math.max(kc.height, inm.height)
                SText {
                    id: inm
                    anchors.left: parent.left
                    width: irow.width - kc.width - 10
                    anchors.verticalCenter: parent.verticalCenter
                    text: irow.modelData.text
                    size: 12.5
                    lh: 1.45
                }
                SKeycap { id: kc; isStatic: true; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; text: irow.modelData.keys }
            }
        }
    }
}
