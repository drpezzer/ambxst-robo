import QtQuick
import qs.modules.robo as C

// views/views.ts buildSettings(): the in-island settings card. Stack padding
// 14 16 14 84, three .settings-row rows 10 apart: sound switch + volume
// (0–0.2), auto-close segmented control, hook badges + "Settings…".
Item {
    id: root
    property bool viewOn: false
    readonly property var lib: C.Robo.lib
    readonly property int rev: C.Robo.rev
    readonly property bool soundOn: rev >= 0 && C.Robo.state.settings.soundEnabled
    readonly property real volume: rev >= 0 ? C.Robo.state.settings.soundVolume : 0
    readonly property real autoClose: rev >= 0 ? C.Robo.state.settings.autoCloseInterval : 15
    readonly property bool hooksInstalled: rev >= 0 && !!C.Robo.state.settings.hooksInstalled
    function t(s, v) { void rev; return lib.I18n.t(s, v); }
    function act() { return C.Robo.island ? C.Robo.island.actions : null; }

    readonly property color rowColor: "#c5c8cd"
    // Arabic: `html[data-dir=rtl] .stack { direction: rtl }` — the rows run right
    // to left inside the stack's physical padding (anchors and Rows mirror; the
    // hand-placed items go through mx), and the volume range runs from the right.
    readonly property bool rtl: rev >= 0 && lib.I18n.isRtl()
    function mx(x, w, pw) { return rtl ? pw - x - w : x; }

    Card {
        anchors.fill: parent

        Column {
            id: rows
            // The card's 1 px border sits outside the stack's padding box.
            x: 1 + 84
            width: parent.width - 2 - 84 - 16
            anchors.verticalCenter: parent.verticalCenter
            spacing: 10
            LayoutMirroring.enabled: root.rtl
            LayoutMirroring.childrenInherit: true

            // Row 1: .switch, "Sound", input[type=range] (72 wide, margin 2).
            Item {
                width: rows.width
                height: 18
                SettingsSwitch {
                    id: sw
                    x: root.mx(0, width, parent.width)
                    on: root.soundOn
                    anchors.verticalCenter: parent.verticalCenter
                    onToggled: { const a = root.act(); if (a) a.toggleSound(); }
                }
                C.CText {
                    id: soundLabel
                    x: root.mx(sw.width + 10, implicitWidth, parent.width)
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.t("Sound")
                    size: 12.5
                    color: root.rowColor
                }
                // The range input: 3 px track, 11 px white thumb.
                Item {
                    id: range
                    x: root.mx(sw.width + 10 + soundLabel.implicitWidth + 10 - 1, width, parent.width)
                    width: 72
                    height: 11
                    anchors.verticalCenter: parent.verticalCenter
                    opacity: root.soundOn ? 1 : 0.4
                    readonly property real frac: Math.max(0, Math.min(1, root.volume / 0.2))
                    Rectangle {
                        width: parent.width
                        height: 3
                        radius: 2
                        anchors.verticalCenter: parent.verticalCenter
                        color: Qt.rgba(1, 1, 1, 0.2)
                    }
                    Rectangle {
                        width: 11
                        height: 11
                        radius: 5.5
                        color: "#ffffff"
                        x: (root.rtl ? 1 - range.frac : range.frac) * (range.width - 11)
                    }
                    MouseArea {
                        anchors.fill: parent
                        anchors.topMargin: -4
                        anchors.bottomMargin: -4
                        function set(mx) {
                            const p = Math.max(0, Math.min(1, (mx - 5.5) / (range.width - 11)));
                            const f = root.rtl ? 1 - p : p;
                            // step 0.005, like the input.
                            const v = Math.round(f * 0.2 / 0.005) * 0.005;
                            const a = root.act();
                            if (a && Math.abs(v - root.volume) > 1e-9) a.setVolume(Number(v.toFixed(3)));
                        }
                        onPressed: mouse => set(mouse.x)
                        onPositionChanged: mouse => { if (pressed) set(mouse.x); }
                    }
                }
            }

            // Row 2: timer icon, "Auto-close · Ns", .seg (margin-left: auto).
            Item {
                width: rows.width
                height: 20
                C.Icon {
                    id: timerIcon
                    x: root.mx(0, width, parent.width)
                    path: root.lib.ICONS.timer
                    size: 12
                    color: root.rowColor
                    anchors.verticalCenter: parent.verticalCenter
                }
                C.CText {
                    id: autoLabel
                    x: root.mx(timerIcon.width + 10, implicitWidth, parent.width)
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.t("Auto-close · {seconds}s", { seconds: Math.round(root.autoClose) })
                    size: 12.5
                    color: root.rowColor
                }
                Row {
                    // .seg's margin-left: auto is physical: right to left the free
                    // space stays on its left, so it follows the label.
                    anchors.right: root.rtl ? undefined : parent.right
                    x: root.rtl ? autoLabel.x - 10 - width : 0
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 6
                    Repeater {
                        model: [10, 15, 30]
                        delegate: Rectangle {
                            id: segBtn
                            required property int modelData
                            readonly property bool on: root.autoClose === modelData
                            // padding 3 7, font 400 11px, pill.
                            width: segText.implicitWidth + 14
                            height: 20
                            radius: height / 2
                            color: on ? "#252830" : "transparent"
                            C.CText {
                                id: segText
                                anchors.centerIn: parent
                                text: segBtn.modelData + "s"
                                size: 11
                                color: segBtn.on ? C.RoboTheme.ink : C.RoboTheme.dim3
                            }
                            MouseArea {
                                anchors.fill: parent
                                onClicked: { const a = root.act(); if (a) a.setAutoClose(segBtn.modelData); }
                            }
                        }
                    }
                }
            }

            // Row 3 (gap 14): Claude Code + API badges, grow, "Settings…" link.
            Item {
                width: rows.width
                height: 14
                Row {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 14
                    Repeater {
                        model: [
                            { label: "Claude Code", color: root.hooksInstalled ? "#22C55E" : "#F4505E" },
                            { label: "API", color: "#F4505E" }
                        ]
                        // .status-badge: dot 6 + 4 + 400 11px dim-2.
                        delegate: Row {
                            required property var modelData
                            spacing: 4
                            Dot {
                                size: 6
                                color: parent.modelData.color
                                anchors.verticalCenter: parent.verticalCenter
                            }
                            C.CText {
                                text: parent.modelData.label
                                size: 11
                                color: C.RoboTheme.dim2
                                anchors.verticalCenter: parent.verticalCenter
                            }
                        }
                    }
                }
                // .link-btn: the browser button padding leaves its text ~2.5 px off the edge (measured).
                LinkBtn {
                    anchors.right: parent.right
                    anchors.rightMargin: 2.5
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.t("Settings…")
                    size: 11.5
                    color: C.RoboTheme.dim2
                    onClicked: { const a = root.act(); if (a) a.openSettingsWindow(); }
                }
            }
        }
    }
}
