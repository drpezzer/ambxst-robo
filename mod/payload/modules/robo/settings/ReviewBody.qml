import QtQuick

// main.ts reviewChange / agents.ts showPreview: the exact diff of a change to
// someone else's file, written only after an explicit click on the confirm
// button, and only for the file the diff was made from (fingerprint).
// `change` is a lib ChangeView (SettingsWin.hooksChange / statusLineChange /
// agentChange). Emits back() (Cancel / Back) and applied() 2.6 s after a write.
Column {
    id: r
    property var page
    property var change: null
    property real gapSize: 12
    signal back()
    signal applied()
    spacing: gapSize
    width: parent ? parent.width : 0

    property string phase: "loading"   // loading | error | preview | done
    property var preview: null
    property string message: ""
    property var errors: []
    property bool busy: false

    function start() {
        phase = "loading";
        errors = [];
        const ch = change;
        ch.preview().then(p => {
            if (r.change !== ch) return;
            if (!p) { r.back(); return; }
            r.preview = p;
            r.phase = "preview";
        }, err => {
            if (r.change !== ch) return;
            r.message = r.page.xL.errorText(err);
            r.phase = "error";
        });
    }
    onChangeChanged: if (change) start()

    function confirm() {
        busy = true;
        change.apply(preview.fingerprint).then(backup => {
            r.message = r.change.doneText(backup || "");
            r.phase = "done";
            doneTimer.start();
        }, err => {
            r.busy = false;
            r.errors = r.errors.concat([r.change.failedText(err)]);
        });
    }
    Timer { id: doneTimer; interval: 2600; onTriggered: r.applied() }

    // Preview failed: the file is never treated as empty.
    SNotice { visible: r.phase === "error"; width: r.width; kind: "err"; text: r.message }
    FlexRow {
        visible: r.phase === "error"
        width: r.width
        SButton { text: r.change ? r.change.backText : ""; onClicked: r.back() }
    }

    SHint { visible: r.phase === "preview"; width: r.width; text: r.change ? r.change.intro : "" }
    SDiff {
        visible: r.phase === "preview"
        width: r.width
        lines: r.preview ? r.page.xL.diffLines(r.preview.diff) : []
    }
    FlexRow {
        visible: r.phase === "preview"
        width: r.width
        SPath {
            text: r.preview && r.change ? r.change.backupText(r.preview.backup || "") : ""
            readonly property real flexShrink: 1
        }
    }
    FlexRow {
        visible: r.phase === "preview"
        width: r.width
        SButton {
            text: r.change ? r.change.confirmText : ""
            kind: r.change ? r.change.confirmKind : "primary"
            enabled2: !r.busy
            onClicked: r.confirm()
        }
        SButton { text: r.change ? r.change.cancelText : ""; onClicked: r.back() }
    }
    Repeater {
        model: r.phase === "preview" ? r.errors : []
        SNotice { required property var modelData; width: r.width; kind: "err"; text: modelData }
    }

    SNotice { visible: r.phase === "done"; width: r.width; kind: "ok"; text: r.message }
}
