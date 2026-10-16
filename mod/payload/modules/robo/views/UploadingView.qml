import QtQuick
import qs.modules.robo as C

// views/upload.ts buildUploading(): the progress card. .card.up-card (green
// radial wash .14, .28 once done), name + percentage at 26,36 over a 526 px
// track at 26,58 (6 px, fill #1fa87a → #34d399, a blurred glow at its head).
// Only seen when the drop sequence is not running; with it, UploadLayer.qml
// draws the bar.
Item {
    id: root
    property bool viewOn: false
    readonly property var lib: C.Robo.lib
    readonly property int rev: C.Robo.rev
    readonly property real progress: rev >= 0 ? C.Robo.state.uploadProgress : 0
    readonly property var label: { void rev; return lib.Misc.uploadingLabel(); }
    // Arabic: `.up-card { direction: rtl }` — the name at the right of the row,
    // the percentage at its left, the fill a block from the track's right end.
    // (The glow is placed with left: 0 + translateX upstream: it stays physical.)
    readonly property bool rtl: rev >= 0 && lib.I18n.isRtl()

    Card {
        id: card
        anchors.fill: parent

        // radial-gradient(260px 260px at 50% 140%, rgba(52,211,153,a), transparent 70%)
        Canvas {
            anchors.fill: parent
            property bool done: root.label.done
            onDoneChanged: requestPaint()
            onWidthChanged: requestPaint()
            onHeightChanged: requestPaint()
            onPaint: {
                const ctx = getContext("2d");
                ctx.reset();
                const a = done ? 0.28 : 0.14;
                const cx = width / 2, cy = height * 1.4;
                const g = ctx.createRadialGradient(cx, cy, 0, cx, cy, 260);
                g.addColorStop(0, Qt.rgba(52 / 255, 211 / 255, 153 / 255, a));
                g.addColorStop(0.7, Qt.rgba(52 / 255, 211 / 255, 153 / 255, 0));
                g.addColorStop(1, Qt.rgba(52 / 255, 211 / 255, 153 / 255, 0));
                ctx.fillStyle = g;
                ctx.fillRect(0, 0, width, height);
            }
        }

        // .up-row (absolute inside the 1 px border).
        Item {
            x: 1 + 26
            y: 1 + 36
            width: 526
            LayoutMirroring.enabled: root.rtl
            LayoutMirroring.childrenInherit: true
            height: nameText.implicitHeight
            BidiText {
                id: nameText
                x: root.rtl ? parent.width - width : 0
                width: Math.min(implicitWidth, parent.width - pct.implicitWidth - 8)
                raw: root.label.name
                size: 12.5
                cssWeight: root.label.done ? 600 : 400
                color: root.label.done ? C.RoboTheme.green2 : "#a9adb5"
            }
            BidiText {
                id: pct
                x: root.rtl ? 0 : parent.width - implicitWidth
                raw: root.label.pct
                size: 12.5
                cssWeight: 500
                color: "#a9adb5"
                font.features: { "tnum": 1 }
            }
        }

        // .up-track / .up-fill / .up-glow
        Rectangle {
            x: 1 + 26
            y: 1 + 58
            width: 526
            height: 6
            radius: 3
            color: Qt.rgba(1, 1, 1, 0.09)
            Rectangle {
                x: root.rtl ? parent.width - width : 0
                width: root.progress * 526
                height: 6
                radius: 3
                visible: width > 0
                gradient: Gradient {
                    orientation: Gradient.Horizontal
                    GradientStop { position: 0; color: "#1fa87a" }
                    GradientStop { position: 1; color: "#34d399" }
                }
            }
            // 28×12 ellipse, rgba(110,231,183,.45), blur(5px): a soft radial blob.
            Canvas {
                x: Math.max(0, root.progress * 526 - 14) - 10
                y: -3 - 10
                width: 48
                height: 32
                opacity: root.progress > 0.01 ? 1 : 0
                onPaint: {
                    const ctx = getContext("2d");
                    ctx.reset();
                    ctx.save();
                    ctx.translate(24, 16);
                    ctx.scale(1, 12 / 28);
                    const g = ctx.createRadialGradient(0, 0, 0, 0, 0, 24);
                    g.addColorStop(0, Qt.rgba(110 / 255, 231 / 255, 183 / 255, 0.45));
                    g.addColorStop(0.45, Qt.rgba(110 / 255, 231 / 255, 183 / 255, 0.36));
                    g.addColorStop(1, Qt.rgba(110 / 255, 231 / 255, 183 / 255, 0));
                    ctx.fillStyle = g;
                    ctx.fillRect(-24, -40, 48, 80);
                    ctx.restore();
                }
            }
        }
    }
}
