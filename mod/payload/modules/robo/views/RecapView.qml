pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import qs.modules.robo as C

// views/recap.ts buildRecap(): the Monday weekly recap card (indigo wash).
// Summary: header, stat chips, two "Label value · …" lines, Share image / OK.
// Share mode flips the card in place: thumbnail of the 1080×1920 image
// (recap/share.ts renderShareImage), "Hide project names", Save / Copy / Back.
Item {
    id: root
    property bool viewOn: false
    readonly property var lib: C.Robo.lib
    readonly property int rev: C.Robo.rev
    function t(s, v) { void rev; return lib.I18n.t(s, v); }
    function act() { return C.Robo.island ? C.Robo.island.actions : null; }
    // Arabic: `.stack.recap-stack` / `.stack.recap-share` read right to left inside
    // the stack's physical padding (the share row starts at the right).
    readonly property bool rtl: rev >= 0 && lib.I18n.isRtl()
    function bidi(s) { return rtl && s ? "\u200F" + s : s; }

    /** summaryBody(): rebuilt when the recap is (re)loaded or the language changes. */
    // Registered for the harness/lead (no tick or command: recap.ts has none).
    Component.onCompleted: C.Robo.registerView("recap", root)
    Component.onDestruction: C.Robo.unregisterView("recap", root)

    readonly property var model: { void rev; return lib.Misc.recapModel(); }
    /** sync(): a new load leaves share mode (only then, never on every state change). */
    property int built: -1
    property bool sharing: false
    onModelChanged: if (model.version !== built) { built = model.version; sharing = false; }

    Card {
        id: card
        anchors.fill: parent
        wash: "indigo"

        // ── Summary (.stack.recap-stack: padding 4 16 4 116, gap 4) ────────
        Column {
            id: summary
            visible: !root.sharing && !root.model.empty
            x: 1 + 116
            width: parent.width - 2 - 116 - 16
            anchors.verticalCenter: parent.verticalCenter
            spacing: 4
            LayoutMirroring.enabled: root.rtl
            LayoutMirroring.childrenInherit: true

            // .recap-head: title, grow, range (baseline).
            Item {
                width: summary.width
                height: recapTitle.implicitHeight
                C.CText {
                    id: recapTitle
                    anchors.left: parent.left
                    text: root.model.title
                    size: 11
                    cssWeight: 600
                    color: "#818cf8"
                }
                C.CText {
                    anchors.right: parent.right
                    anchors.baseline: recapTitle.baseline
                    text: root.model.range
                    size: 10
                    color: C.RoboTheme.dim2
                    elide: Text.ElideNone
                }
            }

            // .recap-chips: gap 14, value 700 17 over label 400 9.
            Row {
                anchors.left: parent.left
                spacing: 14
                Repeater {
                    model: root.model.chips
                    delegate: Column {
                        id: chip
                        required property var modelData
                        C.CText {
                            anchors.left: parent.left
                            // Chromium's normal line box for 700 17px is 1 px shorter than Qt's (measured).
                            height: implicitHeight - 1
                            text: chip.modelData.v
                            size: 17
                            cssWeight: 700
                            color: C.RoboTheme.ink2
                            elide: Text.ElideNone
                        }
                        C.CText {
                            anchors.left: parent.left
                            text: chip.modelData.l
                            size: 9
                            color: C.RoboTheme.dim2
                            elide: Text.ElideNone
                        }
                    }
                }
            }

            // .recap-meta lines: "Label value · Label value", clipped at the card.
            Repeater {
                model: root.model.meta
                delegate: Item {
                    id: metaLine
                    required property var modelData
                    width: summary.width
                    height: metaRow.implicitHeight
                    clip: true
                    Row {
                        id: metaRow
                        anchors.left: parent.left
                        spacing: 5
                        Repeater {
                            model: metaLine.modelData
                            delegate: Row {
                                id: pair
                                required property var modelData
                                required property int index
                                spacing: 5
                                C.CText {
                                    visible: pair.index > 0
                                    text: "·"
                                    size: 11
                                    color: C.RoboTheme.dim4
                                    elide: Text.ElideNone
                                }
                                C.CText {
                                    text: pair.modelData[0]
                                    size: 11
                                    color: C.RoboTheme.dim2
                                    elide: Text.ElideNone
                                }
                                C.CText {
                                    text: pair.modelData[1]
                                    size: 11
                                    cssWeight: 600
                                    color: C.RoboTheme.ink2
                                    elide: Text.ElideNone
                                }
                            }
                        }
                    }
                }
            }

            // .recap-stack .actions: margin-top 3.
            Item {
                anchors.left: parent.left
                width: actionsRow.implicitWidth
                height: actionsRow.implicitHeight + 3
                Row {
                    id: actionsRow
                    y: 3
                    spacing: 8
                    Btn {
                        label: root.t("Share image")
                        kind: "primary"
                        onClicked: root.openShare()
                    }
                    Btn {
                        label: root.t("OK")
                        kind: "secondary"
                        onClicked: { const a = root.act(); if (a) a.collapse(); }
                    }
                }
            }
        }

        // ── emptyBody(): title, sub, OK ─────────────────────────────────────
        Column {
            id: emptyBody
            visible: !root.sharing && root.model.empty
            x: 1 + 116
            width: parent.width - 2 - 116 - 16
            anchors.verticalCenter: parent.verticalCenter
            spacing: 4
            LayoutMirroring.enabled: root.rtl
            LayoutMirroring.childrenInherit: true
            C.CText {
                width: parent.width
                text: root.bidi(root.t("No activity last week"))
                size: 15
                cssWeight: 600
            }
            C.CText {
                width: parent.width
                text: root.bidi(root.t("Robo counts your agent sessions as they happen — check back next Monday."))
                size: 13
                color: C.RoboTheme.dim
                wrapMode: Text.WordWrap
                maximumLineCount: 2
            }
            Btn {
                anchors.left: parent.left
                label: root.t("OK")
                kind: "secondary"
                onClicked: { const a = root.act(); if (a) a.collapse(); }
            }
        }

        // ── Share mode (.stack.recap-share: row, gap 16, padding 8 16 8 116) ─
        Row {
            id: shareRow
            visible: root.sharing
            x: root.rtl ? parent.width - 1 - 16 - width : 1 + 116
            anchors.verticalCenter: parent.verticalCenter
            spacing: 16
            LayoutMirroring.enabled: root.rtl
            LayoutMirroring.childrenInherit: true

            // .recap-thumb: 64×114, radius 8, shadow 0 4 12 rgba(0,0,0,.3).
            Item {
                width: 64
                height: 114
                anchors.verticalCenter: parent.verticalCenter
                Rectangle {
                    anchors.fill: parent
                    anchors.topMargin: 4
                    anchors.bottomMargin: -4
                    radius: 8
                    color: Qt.rgba(0, 0, 0, 0.18)
                }
                // The 1080×1920 canvas, scaled down through a mipmapped
                // texture. Corners stay square: a rounded mask (MultiEffect,
                // ShapePath.fillItem) came out empty in the offscreen harness.
                Item {
                    anchors.fill: parent
                    clip: true
                    ShaderEffectSource {
                        anchors.fill: parent
                        sourceItem: shareCanvas
                        hideSource: true
                        mipmap: true
                        smooth: true
                    }
                }
            }

            Column {
                anchors.verticalCenter: parent.verticalCenter
                spacing: 8
                C.CText {
                    anchors.left: parent.left
                    text: root.t("Share your week")
                    size: 11
                    cssWeight: 600
                    color: "#818cf8"
                }
                Row {
                    anchors.left: parent.left
                    spacing: 10
                    SettingsSwitch {
                        id: hideSwitch
                        anchors.verticalCenter: parent.verticalCenter
                        onToggled: {
                            const next = !on;
                            on = next;
                            void root.lib.Recap.setHideProjects(next);
                            root.drawShare();
                            root.status = "";
                            root.statusLink = false;
                        }
                    }
                    C.CText {
                        anchors.verticalCenter: parent.verticalCenter
                        text: root.t("Hide project names")
                        size: 12.5
                        color: "#c5c8cd"
                    }
                }
                Row {
                    anchors.left: parent.left
                    spacing: 8
                    Btn {
                        id: saveBtn
                        label: root.t("Save image")
                        kind: "primary"
                        onClicked: if (!off) root.save()
                    }
                    Btn {
                        label: root.t("Copy")
                        kind: "secondary"
                        onClicked: root.copy()
                    }
                    Btn {
                        label: root.t("Back")
                        kind: "secondary"
                        onClicked: root.sharing = false
                    }
                }
                // .recap-status: min-height 14, 400 11 dim; "Show in folder" link.
                Row {
                    anchors.left: parent.left
                    // Sized even when empty: a Column skips zero-width children.
                    width: Math.max(1, implicitWidth)
                    height: Math.max(14, implicitHeight)
                    spacing: 8
                    C.CText {
                        id: statusText
                        text: root.status
                        size: 11
                        color: C.RoboTheme.dim
                    }
                    LinkBtn {
                        visible: root.statusLink
                        anchors.baseline: statusText.baseline
                        text: root.t("Show in folder")
                        color: "#818cf8"
                        onClicked: void root.lib.Bridge.recapRevealSaved()
                    }
                }
            }
        }
    }

    // ── The 1080×1920 image, drawn once per share open / privacy toggle ──────
    property string status: ""
    property bool statusLink: false
    property bool imageReady: false
    readonly property string tmpPng: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/ambxst-robo-recap-share.png"

    function openShare() {
        if (model.empty) return;
        hideSwitch.on = !!lib.Recap.prefs.hideProjects;
        status = "";
        statusLink = false;
        sharing = true;
        drawShare();
    }
    function drawShare() {
        imageReady = false;
        shareCanvas.requestPaint();
    }
    // onLanguageChange: share mode redraws only the image.
    property string lang: { void rev; return lib.I18n.language(); }
    onLangChanged: if (sharing) drawShare()

    function save() {
        if (!imageReady) return;
        saveBtn.off = true;
        status = t("Saving…");
        statusLink = false;
        const s = lib.Recap.summary;
        lib.Bridge.recapSavePng(shareCanvas.toDataURL("image/png"), lib.Misc.dayKey(s.weekStart))
            .then(path => {
                const name = String(path).split(/[\\/]/).pop() || path;
                status = t("Saved as {name}", { name: name });
                statusLink = true;
            }, err => {
                status = String(err).replace(/^Error:\s*/, "");
            })
            .then(() => { saveBtn.off = false; });
    }
    /**
     * copyImage(): upstream goes through the web Clipboard API and says it is
     * unavailable where WebKitGTK has no image clipboard. Here the PNG goes to
     * the Wayland clipboard with wl-copy.
     */
    function copy() {
        if (!imageReady) return;
        if (!shareCanvas.save(tmpPng)) { status = t("Copying images isn't available here — use Save image."); return; }
        Quickshell.execDetached(["sh", "-c", 'wl-copy --type image/png < "$1"', "sh", tmpPng]);
        status = t("Copied — paste it anywhere.");
        statusLink = false;
    }

    Canvas {
        id: shareCanvas
        property var wrap: null
        // Never seen itself: the thumbnail samples it (hideSource).
        width: 1080
        height: 1920
        visible: root.sharing
        renderTarget: Canvas.Image
        renderStrategy: Canvas.Immediate
        onPaint: {
            const ctx = getContext("2d");
            if (!wrap) wrap = new C.Robo.lib.Misc.TextCtx(ctx, shareCanvas);
            wrap.setTransform(1, 0, 0, 1, 0, 0);
            wrap.clearRect(0, 0, width, height);
            root.lib.Misc.drawShareImage(ctx, shareCanvas, hideSwitch.on);
        }
        onPainted: if (root.sharing) root.imageReady = true
    }
}
