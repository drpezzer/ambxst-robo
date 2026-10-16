import QtQuick
import qs.modules.robo as C

// mascot/minibots.ts createMiniBot(): a slot `bodySize` across with a canvas
// bodySize / 0.6 centred on it, overflowing so hands and badges show.
Item {
    id: root
    property var task: null
    property real bodySize: 13
    property var dancing: null
    /** Port: always the Coucou mascot, whatever Settings say (Settings' card for him; Axenide in the public build). */
    property bool coucouOnly: false
    /** Port: this mascot whatever Settings say ("coucou", "ambxst"; Settings' cards). */
    property string mascot: coucouOnly ? (C.Robo.lib.PUBLIC ? "ambxst" : "coucou") : ""
    property var mb: null
    /**
     * Port (performance): painted by its owner (the bar: paintIfChanged() on
     * the bar's own tick, with its Robo, so one step is one frame of its
     * screen-sized surface), and sharing its engine with the other screens'
     * bars. Not repainted on its own.
     */
    property bool driven: false
    width: bodySize
    height: bodySize

    property int drawnVersion: -1
    /** The bar's tick: repaints if the mini has moved since it last drew. */
    function paintIfChanged() {
        if (!mb || mb.version === drawnVersion) return;
        drawnVersion = mb.version;
        canvas.requestPaint();
    }
    function paintNow() {
        if (mb) drawnVersion = mb.version;
        canvas.requestPaint();
    }

    function make() {
        release();
        if (!task) return;
        if (driven) {
            mb = C.Robo.lib.Minibots.shareMiniBot(task, bodySize);
            paintNow();
            return;
        }
        mb = C.Robo.lib.Minibots.createMiniBot(task, bodySize, dancing || undefined);
        mb.coucouOnly = root.coucouOnly || root.mascot !== "";
        if (root.mascot !== "") mb.engine.mascotOverride = root.mascot;
        // At most ~15 repaints a second (a 13–24 px mascot shows no more), and
        // the last one always lands (pending flushes it).
        // Port: a helper's blob (lib/blob.ts) ripples: ~30 a second. (Read
        // each time: a helper can turn into its blob after its mini is made.)
        mb.paint = () => {
            const gap = root.mb && root.mb.blob ? 30 : 62;
            flush.interval = gap + 3;
            const now = Date.now();
            if (now - root.lastPaint >= gap) { root.lastPaint = now; canvas.requestPaint(); }
            else if (!flush.running) flush.start();
        };
        canvas.requestPaint();
    }
    function release() {
        if (mb) C.Robo.lib.Minibots.releaseMiniBot(mb);
        mb = null;
    }
    property real lastPaint: 0
    Timer { id: flush; interval: 66; onTriggered: { root.lastPaint = Date.now(); canvas.requestPaint(); } }
    onTaskChanged: make()
    Component.onCompleted: make()
    Component.onDestruction: release()

    Canvas {
        id: canvas
        property var wrap: null
        width: root.bodySize / 0.6
        height: width
        anchors.centerIn: parent
        // Port (performance): rasterised off the GUI thread; in the bar, at
        // once, so that its Robo and minis land in the same frame (a threaded
        // canvas shows its texture a frame or more after the others).
        renderStrategy: root.driven ? Canvas.Immediate : Canvas.Threaded
        onPaint: {
            if (!root.mb) return;
            const ctx = getContext("2d");
            if (!wrap) wrap = new C.Robo.lib.CtxWrap(ctx, canvas);
            wrap.setTransform(1, 0, 0, 1, 0, 0);
            wrap.clearRect(0, 0, width, height);
            C.Robo.lib.Minibots.drawMiniBot(root.mb, wrap);
        }
    }
}
