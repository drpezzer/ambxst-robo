import QtQuick
import qs.modules.robo as C

// island.ts #upload-layer + upload/canvas.ts UploadCanvas: while a dropped (or
// dragged-in) file's sequence runs, this 640×176 canvas draws the whole island
// body — card, dashed frame, drop text, progress bar, choose card, box-mascot
// and the file being swallowed — from UploadSeq.frame() every frame. It
// cross-fades in and out over 0.22 s (ease-in-out) and keeps its last frame
// while fading out. The two choose buttons are painted; invisible hit areas
// at canvas.ts's ASK_BTN / CANCEL_BTN catch the clicks once chooseAlpha > 0.5.
//
// Placement (the lead): in RoboIsland, x = 0, y = 0, ABOVE the views and
// the mascot's canvas but UNDER the header; while `on`, the views fade out
// (#views.hidden-by-upload: opacity 0, 0.22 s ease-in-out, not interactive).
Item {
    id: layer
    width: 640
    height: 176

    readonly property var island: C.Robo.island
    readonly property var hits: C.Robo.lib.Misc.UPLOAD_HITS
    /** island.ts uploadActive: expanded, UploadSeq active, an upload view on. */
    readonly property bool on: island !== null && (C.Robo.rev + C.Robo.frameTick) >= 0 && island.uploadActive
    /** canvas.ts draw(): the overlay shows once the choose card has faded in. */
    property bool buttonsLive: false

    opacity: on ? 1 : 0
    visible: opacity > 0
    Behavior on opacity {
        NumberAnimation { duration: 220; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.42, 0, 0.58, 1, 1, 1] }
    }

    onOnChanged: {
        if (on) canvas.requestPaint();
        else buttonsLive = false;
    }
    Connections {
        target: C.Robo
        function onFrameTickChanged() { if (layer.on) canvas.requestPaint(); }
    }

    Canvas {
        id: canvas
        anchors.fill: parent
        property var wrap: null
        renderStrategy: Canvas.Cooperative
        onPaint: {
            if (!layer.on) return;
            const ctx = getContext("2d");
            if (!wrap) wrap = new C.Robo.lib.Misc.TextCtx(ctx, canvas);
            wrap.setTransform(1, 0, 0, 1, 0, 0);
            wrap.clearRect(0, 0, width, height);
            // wallTime drives the marching dashes, like the macOS timeline.
            layer.buttonsLive = C.Robo.lib.Misc.drawUpload(wrap, Date.now() / 1000);
        }
    }

    // .upload-hit: invisible, radius 13, over the painted buttons.
    MouseArea {
        x: layer.hits.ask.x
        y: layer.hits.y
        width: layer.hits.ask.w
        height: layer.hits.h
        visible: layer.on && layer.buttonsLive
        onClicked: if (layer.island) layer.island.actions.askAboutDrop()
    }
    MouseArea {
        x: layer.hits.cancel.x
        y: layer.hits.y
        width: layer.hits.cancel.w
        height: layer.hits.h
        visible: layer.on && layer.buttonsLive
        onClicked: if (layer.island) layer.island.actions.cancelDrop()
    }

    // Port (his ask): a dropped folder gets a third choice, "Use as working
    // directory" (chat.ts useDropAsWorkDir), painted like Cancel after it
    // (canvas.ts CANCEL_BTN's fill, text and size), within the card's text column.
    Rectangle {
        id: dirChoice
        readonly property string label: (C.Robo.rev + C.Robo.frameTick) >= 0 && layer.on ? C.Robo.lib.ChatView.chat().dropOffer() : ""
        x: layer.hits.cancel.x + layer.hits.cancel.w + 8
        y: layer.hits.y
        width: Math.min(614 - x, dirChoiceText.implicitWidth + 28)
        height: layer.hits.h
        radius: 13
        color: Qt.rgba(1, 1, 1, 0.09)
        visible: label !== "" && opacity > 0
        opacity: layer.buttonsLive ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 220; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.42, 0, 0.58, 1, 1, 1] } }
        C.CText {
            id: dirChoiceText
            anchors.centerIn: parent
            width: Math.min(implicitWidth, dirChoice.width - 14)
            elide: Text.ElideRight
            text: dirChoice.label
            size: 12.5
            cssWeight: 500
            color: "#F1F2F4"
        }
        MouseArea {
            anchors.fill: parent
            enabled: layer.buttonsLive
            onClicked: C.Robo.lib.ChatView.chat().useDropAsWorkDir()
        }
    }
}
