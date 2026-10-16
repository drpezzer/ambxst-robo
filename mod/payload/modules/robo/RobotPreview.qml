import QtQuick
import qs.modules.robo as C

// Port only (his ask): a live Robo for Settings (the mascot card, the
// customiser's preview): a Robot (lib/robot) with the look given, idling.
Canvas {
    id: root
    /** lib/robot RobotLook: shape, antenna, speed, shell, trim, screen. */
    property var look: null
    property string state: "idle"
    /** The box the head rests in (the antenna included). */
    property real box: 80
    property var robot: null
    property var wrap: null
    readonly property bool running: visible && look !== null
    onLookChanged: if (robot && look) robot.setLook(look)
    onStateChanged: if (robot) robot.setState(state)
    onPaint: {
        if (!look) return;
        const lib = C.Robo.lib;
        if (!robot) {
            robot = new lib.Robot.Robot(look, box, 0.5);
            robot.setState(state);
        }
        robot.setBox(box);
        const ctx = getContext("2d");
        ctx.reset();
        if (!wrap) wrap = new lib.CtxWrap(ctx, root);
        robot.drawAt(wrap, (width - box) / 2, (height - box) / 2);
    }
    Timer {
        interval: 40
        repeat: true
        running: root.running
        onTriggered: {
            if (root.robot) root.robot.update(0.04);
            root.requestPaint();
        }
    }
}
