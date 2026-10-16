pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Shapes
import qs.modules.robo as C

// views/upload.ts buildUpload(): the drop zone. .card.drop-card (card-flat,
// no border) with a dashed 1.5 px frame (6 5 dashes marching 11 px / 1.1 s,
// stroke breathing .11–.15 over 7 s; green and still-marching when a file is
// over), "Drop your files here" and the four chips, from x = 196.
// Only seen without a drag in progress: once a file is dragged in, the
// sequence (UploadLayer.qml) draws the whole body instead.
Item {
    id: root
    property bool viewOn: false
    readonly property var lib: C.Robo.lib
    readonly property int rev: C.Robo.rev
    readonly property bool over: rev >= 0 && C.Robo.state.fileDragOver
    function t(s) { void rev; return lib.I18n.t(s); }
    // Arabic: `.drop-body { direction: rtl }` — its padding-left stays, so the
    // title and chips sit against the card's right edge, the chips from the right.
    readonly property bool rtl: rev >= 0 && lib.I18n.isRtl()

    Rectangle {
        id: card
        anchors.fill: parent
        radius: 20
        color: C.RoboTheme.cardFlat

        // .drop-card.over: radial-gradient(200px 200px at 50% 100%, rgba(34,197,94,.13), transparent 70%).
        Canvas {
            anchors.fill: parent
            visible: root.over
            onWidthChanged: requestPaint()
            onHeightChanged: requestPaint()
            onPaint: {
                const ctx = getContext("2d");
                ctx.reset();
                const cx = width / 2, cy = height;
                const g = ctx.createRadialGradient(cx, cy, 0, cx, cy, 200);
                g.addColorStop(0, Qt.rgba(34 / 255, 197 / 255, 94 / 255, 0.13));
                g.addColorStop(0.7, Qt.rgba(34 / 255, 197 / 255, 94 / 255, 0));
                g.addColorStop(1, Qt.rgba(34 / 255, 197 / 255, 94 / 255, 0));
                ctx.fillStyle = g;
                ctx.beginPath();
                ctx.roundedRect(0, 0, width, height, 20, 20);
                ctx.fill();
            }
        }

        // .drop-frame rect: x/y .75, rx 20, stroke-width 1.5, dasharray 6 5.
        Shape {
            anchors.fill: parent
            preferredRendererType: Shape.CurveRenderer
            ShapePath {
                id: frame
                property real breathe: 0.11
                fillColor: "transparent"
                strokeWidth: 1.5
                strokeColor: root.over ? Qt.rgba(34 / 255, 197 / 255, 94 / 255, 0.65) : Qt.rgba(1, 1, 1, breathe)
                strokeStyle: ShapePath.DashLine
                // In stroke widths: 6 / 1.5, 5 / 1.5.
                dashPattern: [4, 10 / 3]
                property real march: 0
                dashOffset: march / 1.5
                PathRectangle {
                    x: 0.75
                    y: 0.75
                    width: card.width - 1.5
                    height: card.height - 1.5
                    radius: 20
                }
            }
        }
        // @keyframes dash-march: stroke-dashoffset 0 → -11, 1.1 s linear, forever.
        NumberAnimation {
            target: frame
            property: "march"
            from: 0
            to: -11
            duration: 1100
            loops: Animation.Infinite
            running: root.viewOn
        }
        // @keyframes dash-breathe: .11 → .15 → .11 over 7 s, ease-in-out.
        SequentialAnimation {
            running: root.viewOn && !root.over
            loops: Animation.Infinite
            NumberAnimation { target: frame; property: "breathe"; from: 0.11; to: 0.15; duration: 3500; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.42, 0, 0.58, 1, 1, 1] }
            NumberAnimation { target: frame; property: "breathe"; from: 0.15; to: 0.11; duration: 3500; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.42, 0, 0.58, 1, 1, 1] }
        }

        // .drop-body: column, centred, gap 8, padding-left 196.
        Column {
            x: root.rtl ? parent.width - width : 196
            anchors.verticalCenter: parent.verticalCenter
            spacing: 8
            LayoutMirroring.enabled: root.rtl
            LayoutMirroring.childrenInherit: true
            C.CText {
                anchors.left: parent.left
                text: root.t("Drop your files here")
                size: 13
                cssWeight: 500
                color: root.over ? C.RoboTheme.green2 : "#d5d7db"
                Behavior on color { ColorAnimation { duration: 200; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.25, 0.1, 0.25, 1, 1, 1] } }
            }
            Row {
                anchors.left: parent.left
                spacing: 6
                Repeater {
                    model: ["PDF", "Images", "Code", "Docs"]
                    // .drop-tags span: 400 11px, padding 3 8, pill, white .07.
                    delegate: Rectangle {
                        id: chip
                        required property string modelData
                        width: chipText.implicitWidth + 16
                        height: chipText.implicitHeight + 6
                        radius: height / 2
                        color: Qt.rgba(1, 1, 1, 0.07)
                        C.CText {
                            id: chipText
                            anchors.centerIn: parent
                            text: root.t(chip.modelData)
                            size: 11
                            color: "#b9bdc4"
                        }
                    }
                }
            }
        }
    }
}
