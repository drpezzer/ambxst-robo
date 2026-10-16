import QtQuick
import QtQuick.Effects
import qs.modules.robo as C

// views/spotify.ts buildSpotifyPill(): the agent pill's look, a mini mascot that
// dances while Spotify plays, and play/pause + next on hover once a track is
// loaded (MusicControlButton). style.css .pill, .np-pill*.
Item {
    id: p
    property var task: null
    readonly property var lib: C.Robo.lib
    readonly property var icons: lib.ICONS
    readonly property string color: task ? task.color : "#1DB954"
    readonly property bool hovered: ma.containsMouse || playMa.containsMouse || nextMa.containsMouse
    readonly property var d: C.Robo.rev >= 0 ? lib.SpotifyCtl.pill() : ({ hasTrack: false, playing: false })
    readonly property bool controls: hovered && d.hasTrack
    readonly property string name: {
        void C.Robo.rev;
        if (!task) return "";
        const cur = C.Robo.state.tasks.find(x => x.id === task.id);
        return cur ? cur.name : task.name;
    }
    height: 28
    scale: hovered ? 1.04 : 1
    Behavior on scale { NumberAnimation { duration: 200; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.3, 1.2, 0.4, 1, 1, 1] } }

    function hexA(hex, a) { const c = Qt.color(hex); return Qt.rgba(c.r, c.g, c.b, a); }
    function lighten(hex, amount) {
        const c = Qt.color(hex);
        return Qt.rgba(Math.min(1, c.r + amount), Math.min(1, c.g + amount), Math.min(1, c.b + amount), 1);
    }

    // box-shadow 0 2px 10px color/0.35 on hover.
    Rectangle { id: shadowSrc; anchors.fill: bg; radius: bg.radius; color: p.hexA(p.color, 0x59 / 255); visible: false }
    MultiEffect {
        source: shadowSrc
        anchors.fill: bg
        anchors.topMargin: 2
        anchors.bottomMargin: -2
        blurEnabled: true; blur: 0.6; blurMax: 20
        opacity: p.hovered ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 180; easing.type: Easing.BezierSpline; easing.bezierCurve: C.RoboTheme.ease } }
    }
    Rectangle {
        id: bg
        anchors.fill: parent
        radius: height / 2
        color: p.hovered ? p.hexA(p.color, 0x2e / 255) : C.RoboTheme.cardFlat
        border.width: 1
        border.color: p.hovered ? p.hexA(p.color, 0x8c / 255) : p.hexA(p.color, 0x24 / 255)
        Behavior on color { ColorAnimation { duration: 180; easing.type: Easing.BezierSpline; easing.bezierCurve: C.RoboTheme.ease } }
        Behavior on border.color { ColorAnimation { duration: 180; easing.type: Easing.BezierSpline; easing.bezierCurve: C.RoboTheme.ease } }
    }
    MouseArea {
        id: ma
        anchors.fill: parent
        hoverEnabled: true
        onClicked: if (C.Robo.island && p.task) C.Robo.island.actions.setFocus(p.task.id)
    }
    C.MiniBot {
        x: 7
        anchors.verticalCenter: parent.verticalCenter
        task: p.task
        bodySize: 24
        dancing: p.lib.SpotifyCtl.dancing
    }
    // .lbl; .np-pill.controls .lbl: padding 0 52 0 34.
    C.CText {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        leftPadding: p.controls ? 34 : 6
        rightPadding: p.controls ? 52 : 6
        Behavior on leftPadding { NumberAnimation { duration: 200; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.3, 1.2, 0.4, 1, 1, 1] } }
        Behavior on rightPadding { NumberAnimation { duration: 200; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.3, 1.2, 0.4, 1, 1, 1] } }
        horizontalAlignment: Text.AlignHCenter
        text: p.name
        size: 10
        cssWeight: 600
        color: p.hovered ? p.lighten(p.color, 0.3) : C.RoboTheme.dim3
    }

    // MusicControlButton: 20 px, card-flat, border colour/14 %; hover tints it.
    component PillBtn: Item {
        id: b
        property string icon: ""
        property bool hot: false
        width: 20; height: 20
        scale: hot ? 1.1 : 1
        Behavior on scale { NumberAnimation { duration: 200; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.3, 1.2, 0.4, 1, 1, 1] } }
        Rectangle { id: glowSrc; anchors.fill: parent; radius: 10; color: p.hexA(p.color, 0x59 / 255); visible: false }
        MultiEffect {
            source: glowSrc; anchors.fill: parent
            blurEnabled: true; blur: 0.4; blurMax: 12
            opacity: b.hot ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 180; easing.type: Easing.BezierSpline; easing.bezierCurve: C.RoboTheme.ease } }
        }
        Rectangle {
            anchors.fill: parent
            radius: 10
            color: b.hot ? p.hexA(p.color, 0x2e / 255) : C.RoboTheme.cardFlat
            border.width: 1
            border.color: b.hot ? p.hexA(p.color, 0x8c / 255) : p.hexA(p.color, 0x24 / 255)
            Behavior on color { ColorAnimation { duration: 180; easing.type: Easing.BezierSpline; easing.bezierCurve: C.RoboTheme.ease } }
        }
        C.Icon { anchors.centerIn: parent; path: b.icon; size: 8; color: b.hot ? p.lighten(p.color, 0.3) : C.RoboTheme.dim3 }
    }

    Row {
        anchors.right: parent.right
        anchors.rightMargin: 4
        anchors.verticalCenter: parent.verticalCenter
        spacing: 2
        opacity: p.controls ? 1 : 0
        scale: p.controls ? 1 : 0.85
        transformOrigin: Item.Right
        enabled: p.controls
        Behavior on opacity { NumberAnimation { duration: 180; easing.type: Easing.BezierSpline; easing.bezierCurve: C.RoboTheme.ease } }
        Behavior on scale { NumberAnimation { duration: 200; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.3, 1.2, 0.4, 1, 1, 1] } }
        PillBtn {
            icon: p.d.playing ? p.icons.pause : p.icons.play
            hot: playMa.containsMouse
            MouseArea { id: playMa; anchors.fill: parent; hoverEnabled: true; onClicked: p.lib.SpotifyCtl.togglePlay() }
        }
        PillBtn {
            icon: p.icons.forward
            hot: nextMa.containsMouse
            MouseArea { id: nextMa; anchors.fill: parent; hoverEnabled: true; onClicked: p.lib.SpotifyCtl.next() }
        }
    }
}
