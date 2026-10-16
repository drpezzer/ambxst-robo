pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects
import QtQuick.Layouts
import qs.modules.robo as C

// views/spotify.ts buildSpotifyCard(): now playing (artwork, title, progress
// that runs on, controls, volume) or the idle card (not playing / not
// installed). The controls are lib/views/spotify.ts (C.Robo.lib.SpotifyCtl).
// style.css .np-*.
Item {
    id: root
    property var task: null
    readonly property bool detailOpen: false
    readonly property var lib: C.Robo.lib
    readonly property var sc: lib.SpotifyCtl
    readonly property int rev: C.Robo.rev
    readonly property var d: rev >= 0 ? sc.card() : ({ hasTrack: false })
    readonly property string green: "#1DB954"

    readonly property bool rtl: rev >= 0 && lib.I18n.isRtl()
    /** First strong character right to left (Hebrew / Arabic blocks)? */
    function startsRtl(s) {
        const m = /[A-Za-z\u00C0-\u024F\u0370-\u03FF\u0400-\u04FF\u0900-\u0DFF\u3040-\u9FFF\uAC00-\uD7AF]|[\u0590-\u08FF\uFB1D-\uFDFF\uFE70-\uFEFF]/.exec(s || "");
        return !!m && /[\u0590-\u08FF\uFB1D-\uFDFF\uFE70-\uFEFF]/.test(m[0]);
    }
    function hexA(hex, a) { const c = Qt.color(hex); return Qt.rgba(c.r, c.g, c.b, a); }
    function bright(col, k) { const c = Qt.color(col); return Qt.rgba(Math.min(1, c.r * k), Math.min(1, c.g * k), Math.min(1, c.b * k), c.a); }

    // The position runs on its own clock, twice a second, only while it plays on screen.
    property real nowMs: Date.now()
    property var dragFraction: null
    readonly property var prog: rev >= 0 ? sc.progress(nowMs, dragFraction) : ({ fraction: 0, elapsed: "", remaining: "" })
    Timer {
        interval: 500
        repeat: true
        running: root.rev >= 0 && root.sc.clockRuns()
        onTriggered: root.nowMs = Date.now()
    }
    onRevChanged: nowMs = Date.now()

    // NowPlayingBar: grey track, fill turns green and grows a knob under the
    // pointer; drag or click anywhere on it.
    component NpBar: Item {
        id: bar
        property real fraction: 0
        property bool enabled2: true
        readonly property bool active: enabled2 && (ma.containsMouse || ma.pressed)
        signal changed(real f)
        signal committed(real f)
        height: 10
        function at(x) { return Math.min(1, Math.max(0, x / Math.max(1, width))); }
        Rectangle {
            width: parent.width
            height: bar.active ? 4 : 3
            anchors.verticalCenter: parent.verticalCenter
            radius: height / 2
            color: Qt.rgba(1, 1, 1, 0.12)
        }
        Rectangle {
            width: parent.width * bar.fraction
            height: bar.active ? 4 : 3
            anchors.verticalCenter: parent.verticalCenter
            radius: height / 2
            color: bar.active ? root.green : "#C5C8CD"
        }
        Rectangle {
            x: Math.min(Math.max(0, parent.width * bar.fraction - 4.5), parent.width - 9)
            width: 9; height: 9; radius: 4.5
            anchors.verticalCenter: parent.verticalCenter
            color: C.RoboTheme.ink
            opacity: bar.active ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 120; easing.type: Easing.BezierSpline; easing.bezierCurve: C.RoboTheme.easeOut } }
        }
        MouseArea {
            id: ma
            anchors.fill: parent
            hoverEnabled: true
            preventStealing: true
            onPressed: m => { if (bar.enabled2) bar.changed(bar.at(m.x)); }
            onPositionChanged: m => { if (pressed && bar.enabled2) bar.changed(bar.at(m.x)); }
            onReleased: m => { if (bar.enabled2) bar.committed(bar.at(m.x)); }
        }
    }

    // NowPlayingIconButton: brightens under the pointer, 0.9 when pressed.
    component NpIcon: Item {
        id: nb
        property string icon: ""
        property real iconSize: 11
        property real stroke: 0
        property color color: "#C5C8CD"
        signal clicked()
        width: 16; height: 18
        scale: nma.pressed ? 0.9 : 1
        Behavior on scale { NumberAnimation { duration: 200; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.3, 1.2, 0.4, 1, 1, 1] } }
        C.Icon { anchors.centerIn: parent; path: nb.icon; size: nb.iconSize; stroke: nb.stroke; color: nma.containsMouse ? root.bright(nb.color, 1.3) : nb.color }
        MouseArea { id: nma; anchors.fill: parent; hoverEnabled: true; onClicked: nb.clicked() }
    }

    // ── Now playing ───────────────────────────────────────────────────────────
    Column {
        visible: root.d.hasTrack
        x: 1 + 108   // the card's 1 px border + .np-card padding
        y: 1 + 10
        width: parent.width - 2 - 108 - 12

        // .np-head: art 36, text; gap 9, padding-right 24.
        Row {
            width: parent.width - 24
            spacing: 9
            Item {
                id: art
                width: 36; height: 36
                // box-shadow 0 2px 4px rgba(0,0,0,.35)
                Rectangle {
                    id: artShadowSrc
                    anchors.fill: parent; radius: 6; color: Qt.rgba(0, 0, 0, 0.35); visible: false
                }
                MultiEffect {
                    source: artShadowSrc
                    anchors.fill: parent
                    anchors.topMargin: 2; anchors.bottomMargin: -2
                    blurEnabled: true; blur: 0.25; blurMax: 8
                }
                Rectangle { anchors.fill: parent; radius: 6; color: C.RoboTheme.card }
                Rectangle { anchors.fill: parent; radius: 6; color: Qt.rgba(1, 1, 1, 0.06) }
                C.Icon {
                    anchors.centerIn: parent
                    path: root.lib.ICONS.musicNote; size: 16
                    color: root.hexA(root.green, 0xb3 / 255)
                    opacity: cover.status === Image.Ready && root.d.cover ? 0 : 1
                }
                Image {
                    id: cover
                    anchors.fill: parent
                    source: root.d.cover || ""
                    fillMode: Image.PreserveAspectCrop
                    visible: false
                    asynchronous: true
                }
                Rectangle { id: artMask; anchors.fill: parent; radius: 6; visible: false; layer.enabled: true }
                MultiEffect {
                    anchors.fill: parent
                    source: cover
                    maskEnabled: true
                    maskSource: artMask
                    opacity: cover.status === Image.Ready && root.d.cover ? 1 : 0
                    Behavior on opacity { NumberAnimation { duration: 250; easing.type: Easing.BezierSpline; easing.bezierCurve: C.RoboTheme.easeInOut } }
                }
                // ::after inset ring
                Rectangle { anchors.fill: parent; radius: 6; color: "transparent"; border.width: 1; border.color: Qt.rgba(1, 1, 1, 0.08) }
                MouseArea { anchors.fill: parent; onClicked: root.sc.openSpotify() }
            }
            Column {
                width: parent.width - 36 - 9
                anchors.verticalCenter: parent.verticalCenter
                spacing: 2
                Row {
                    width: parent.width
                    spacing: 5
                    Dot { size: 6; color: root.green; anchors.verticalCenter: parent.verticalCenter }
                    C.CText { width: Math.min(implicitWidth, parent.width - 11); text: root.d.title || ""; size: 12; cssWeight: 600 }
                }
                // Arabic: .np-title / .np-sub take `unicode-bidi: plaintext; text-align: start` —
                // a right-to-left subtitle (a block) aligns right; the title span is only
                // as wide as its text (Qt elides right-to-left text on the left by itself).
                C.CText {
                    visible: text !== ""
                    anchors.right: root.rtl && root.startsRtl(text) ? parent.right : undefined
                    width: Math.min(implicitWidth, parent.width)
                    text: root.d.sub || ""; size: 11; color: C.RoboTheme.dim2
                }
            }
        }

        // .np-progress: gap 6, padding-top 7, 9.5 px tabular, dim-3.
        Item { width: 1; height: 7 }
        RowLayout {
            width: parent.width
            spacing: 6
            C.CText {
                Layout.minimumWidth: 26
                horizontalAlignment: Text.AlignRight
                text: root.prog.elapsed; size: 9.5; color: C.RoboTheme.dim3; elide: Text.ElideNone
                font.features: { "tnum": 1 }
            }
            NpBar {
                Layout.fillWidth: true
                Layout.preferredHeight: 10
                fraction: root.prog.fraction
                enabled2: !!root.d.seekable
                onChanged: f => root.dragFraction = f
                onCommitted: f => { root.dragFraction = null; root.sc.seek(f * (root.d.duration || 0)); }
            }
            C.CText {
                Layout.minimumWidth: 28
                text: root.prog.remaining; size: 9.5; color: C.RoboTheme.dim3; elide: Text.ElideNone
                font.features: { "tnum": 1 }
            }
        }

        // .np-controls: buttons (gap 10), grow, volume; padding-top 4.
        Item { width: 1; height: 4 }
        RowLayout {
            width: parent.width
            spacing: 0
            Row {
                spacing: 10
                NpIcon { icon: root.lib.ICONS.shuffle; iconSize: 10; stroke: 2.2; color: root.d.shuffleColor || "#6B7079"; onClicked: root.sc.setFlag("shuffle", !root.d.shuffle) }
                NpIcon { icon: root.lib.ICONS.backward; onClicked: root.sc.previous() }
                Rectangle {
                    width: 20; height: 20; radius: 10
                    anchors.verticalCenter: parent.verticalCenter
                    color: C.RoboTheme.ink
                    scale: pma.pressed ? 0.9 : 1
                    Behavior on scale { NumberAnimation { duration: 200; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.3, 1.2, 0.4, 1, 1, 1] } }
                    C.Icon {
                        anchors.centerIn: parent
                        anchors.horizontalCenterOffset: root.d.playing ? 0 : 1
                        path: root.d.playing ? root.lib.ICONS.pause : root.lib.ICONS.play
                        size: 9
                        color: C.RoboTheme.cardFlat
                    }
                    MouseArea { id: pma; anchors.fill: parent; onClicked: root.sc.togglePlay() }
                }
                NpIcon { icon: root.lib.ICONS.forward; onClicked: root.sc.next() }
                NpIcon { icon: root.lib.ICONS.repeat; iconSize: 10; stroke: 2.2; color: root.d.repeatColor || "#6B7079"; onClicked: root.sc.setFlag("repeat", !root.d.repeat) }
            }
            Item { Layout.fillWidth: true; Layout.minimumWidth: 8 }
            // .np-volume: icon box 13 (right-aligned), bar 44; gap 5.
            Row {
                spacing: 5
                Item {
                    width: 13; height: 10
                    anchors.verticalCenter: parent.verticalCenter
                    C.Icon { anchors.right: parent.right; path: root.d.volumeIcon || ""; size: 10; stroke: 2.2; color: C.RoboTheme.dim3 }
                }
                NpBar {
                    width: 44
                    anchors.verticalCenter: parent.verticalCenter
                    fraction: (root.d.volume || 0) / 100
                    onChanged: f => root.sc.setVolume(f * 100)
                    onCommitted: f => root.sc.setVolume(f * 100)
                }
            }
        }
    }

    // ── Idle: the same layout as the other idle cards ─────────────────────────
    Column {
        visible: !root.d.hasTrack
        x: 1 + 108   // the card's 1 px border + .np-card padding
        y: 1 + 10
        width: parent.width - 2 - 108 - 12
        // Arabic: the idle card is an `.int-card` — it reads right to left.
        LayoutMirroring.enabled: root.rtl
        LayoutMirroring.childrenInherit: true
        Row {
            anchors.left: parent.left
            // .int-head's padding-right 24 (clear of the ↗): it only shows right to left.
            anchors.leftMargin: root.rtl ? 24 : 0
            spacing: 6
            Dot { size: 7; color: root.green; anchors.verticalCenter: parent.verticalCenter }
            // Port: the active player's name (lib/media.ts), any MPRIS player.
            C.CText { anchors.verticalCenter: parent.verticalCenter; text: root.d.name || "Media"; size: 12; cssWeight: 600 }
            C.CText { anchors.verticalCenter: parent.verticalCenter; text: root.d.subtitle || ""; size: 11; color: C.RoboTheme.dim2 }
        }
        Item { width: 1; height: 4 }
        Row {
            anchors.left: parent.left
            spacing: 5
            Dot { size: 5; color: root.d.idleColor || "#22C55E"; anchors.verticalCenter: parent.verticalCenter }
            C.CText { text: root.d.idleText || ""; size: 11; color: C.RoboTheme.dim3 }
        }
        Item { width: 1; height: 6 }
        LinkBtn {
            anchors.left: parent.left
            visible: !!root.d.idleAction
            text: root.d.idleAction || ""
            color: root.hexA(root.green, 0xd9 / 255)
            onClicked: root.sc.openSpotify()
        }
    }
}
