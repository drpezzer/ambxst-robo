import QtQuick
import qs.modules.robo as C

// Port (performance): a ~30 Hz clock for the views' endless loops (the
// shimmering step, the typing dots), instead of an Animation, which makes
// the notch's screen-sized surface redraw at the display's rate (165 Hz) for
// a few pixels of text. Every loop on screen steps on the same tick
// (C.Robo.clockMs), and while the open island steps its mascot that tick is
// the island's own: one frame for all of them. Only while `running`.
QtObject {
    id: clk
    property bool running: false
    /** When it (last) started running (ms, Date.now()): the loop's time zero. */
    property real startMs: 0
    /** Each tick: `ms`, Date.now() of the tick. */
    signal tick(real ms)

    property bool counted: false
    function sync() {
        if (running === counted) return;
        counted = running;
        C.Robo.clockUsers += running ? 1 : -1;
        if (running) {
            startMs = Date.now();
            tick(startMs);
        }
    }
    onRunningChanged: sync()
    Component.onCompleted: sync()
    Component.onDestruction: if (counted) { counted = false; C.Robo.clockUsers -= 1; }
    readonly property Connections link: Connections {
        target: C.Robo
        enabled: clk.running
        function onClockMsChanged() { clk.tick(C.Robo.clockMs); }
    }
}
