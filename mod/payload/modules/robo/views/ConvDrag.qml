import QtQuick
import qs.modules.robo as C

// Port only (his ask: multitasking): a chat conversation's pill carried out
// of the minis box, over the whole tab. Its card in the chats column comes
// into view, glowing (HistoryColumn). Let go anywhere on the column (his
// call: aiming for its own card was arbitrary): the conversation retires —
// the mascot falls (or rises) to its card's centre (where he was let go when the
// card isn't showing), saddens,
// turns into a ball, and pill and ball shrink away in a pop of little lines.
// Its answer, if one was coming, stops; the chat stays in the column. Let go
// anywhere else: it flies back to its place. The mascot is all surprise while held.
Item {
    id: root
    /** The carried pill's task (a State task with `conv`), null when none. */
    property var task: null
    property Item source: null
    /** Where the pointer holds the pill, in the pill. */
    property point grip: Qt.point(0, 0)
    /** The pointer is over the chats column: letting go there retires it. */
    property bool overCard: false
    onOverCardChanged: C.Robo.convDropOver = overCard
    /** Where the pointer let go, in this item. */
    property point dropAt: Qt.point(0, 0)
    property bool busy: false
    readonly property string conv: task && task.conv ? task.conv : ""
    /** The mini's own colour (its Robo's shell, Axenide's or the Coucou mascot's body, as
     *  Pill.qml: lib/looks.ts chatColor), taken at the pickup so the ball keeps
     *  it once the conversation retires. The agent's colour when it has none. */
    property color tint: "#D97757"

    function colorOf(t) {
        if (!t) return "#D97757";
        const fallback = t.color || "#D97757";
        const L = C.Robo.lib.Looks;
        const c = L ? L.convOfTask(t) : null;
        return c ? (L.chatColor(c, fallback) || fallback) : fallback;
    }

    Component.onCompleted: {
        C.Robo.convDrag = root;
        C.Robo.convDrags = C.Robo.convDrags.concat([root]);
    }
    Component.onDestruction: {
        if (C.Robo.convDrag === root) C.Robo.convDrag = null;
        C.Robo.convDrags = C.Robo.convDrags.filter(x => x !== root);
    }
    /** Port (his bug): the chats column of this tab's own screen. */
    function history() { return C.Robo.historyViewFor(root); }

    function hexA(hex, a) { const c = Qt.color(hex); return Qt.rgba(c.r, c.g, c.b, a); }
    function engine() { return mini.mb ? mini.mb.engine : null; }
    function keepTicking() { if (C.Robo.island) C.Robo.island.ensureRunning(); }

    /** The conversation's card, in this item's coordinates (null: not in the column). */
    function cardRect() {
        const h = history();
        return h && task ? h.cardRect(task.convKey || "", root) : null;
    }

    /** A press on `pill` moved far enough: it is picked up. False if it can't be. */
    function begin(t, pill, gx, gy) {
        if (busy || !t || !t.conv) return false;
        const at = pill.mapToItem(root, 0, 0);
        task = t;
        tint = colorOf(t);
        source = pill;
        grip = Qt.point(gx, gy);
        ghost.width = pill.width;
        ghost.x = at.x;
        ghost.y = at.y;
        ghost.fold = 0;
        ghost.phase = "held";
        foldIn.restart();
        overCard = false;
        C.Robo.dragConv = t.conv;
        C.Robo.convFocusKey = t.convKey || "";
        // Picked up: a start, then wide-eyed for as long as he is held.
        const e = engine();
        if (e) {
            e.squash();
            e.triggerEmote("surprised", 3600);
        }
        C.Robo.lib.Sound.play("blip");
        keepTicking();
        return true;
    }

    function move(pill, mx, my) {
        if (!task || ghost.phase !== "held") return;
        const p = pill.mapToItem(root, mx, my);
        ghost.x = p.x - grip.x;
        ghost.y = p.y - grip.y;
        dropAt = p;
        const h = history();
        const r = h ? h.columnRect(root) : null;
        overCard = !!r && p.x >= r.x && p.x <= r.x + r.width && p.y >= r.y && p.y <= r.y + r.height;
        keepTicking();
    }

    function end(pill, mx, my) {
        if (!task || ghost.phase !== "held") return;
        move(pill, mx, my);
        if (!overCard) {
            flyBack();
            return;
        }
        // To its own card when it shows, else right where he was let go.
        const r = cardRect() || Qt.rect(dropAt.x - 1, dropAt.y - 1, 2, 2);
        overCard = false;
        retire(r);
    }

    function cancel() { if (task && ghost.phase === "held") flyBack(); }

    function flyBack() {
        foldIn.stop();
        ghost.phase = "back";
        const e = engine();
        if (e) { e.eyeOverride = null; e.eyeOverrideUntil = 0; }
        const home = source ? source.mapToItem(root, 0, 0) : Qt.point(ghost.x, ghost.y);
        // The pill unfolds around him on the way home (where it was taken).
        backX.to = home.x;
        backY.to = home.y;
        back.restart();
    }

    function retire(r) {
        busy = true;
        ghost.phase = "retiring";
        // Sad: droopy eyes, for good.
        const e = engine();
        if (e) {
            e.permanentEye = "tired";
            e.eyeOverride = "tired";
            e.eyeOverrideUntil = Number.POSITIVE_INFINITY;
        }
        foldIn.stop();
        // The mascot himself (fully folded by the landing) ends on the card's centre.
        const cxFolded = Math.max(19, Math.min(ghost.width - 19, grip.x));
        fallX.to = r.x + r.width / 2 - cxFolded;
        fallY.to = r.y + r.height / 2 - ghost.height / 2;
        retireAnim.restart();
        keepTicking();
    }

    function finish() {
        C.Robo.dragConv = "";
        if (C.Robo.convFocusKey === (task ? task.convKey || "" : "")) C.Robo.convFocusKey = "";
        task = null;
        source = null;
        busy = false;
        overCard = false;
        ghost.phase = "";
    }

    // ── The carried pill ──
    Item {
        id: ghost
        property string phase: ""
        visible: phase !== ""
        height: 28
        z: 1
        // His ask: a moment after the pickup the pill and its title fold away
        // behind the mini, which comes under the pointer: you hold the mascot alone.
        // 0 = the pill, 1 = just the mini (unfolds again on the way back).
        property real fold: 0
        // 0 = the mascot, 1 = a ball.
        property real ball: 0
        property real shrink: 1
        property real wobble: 0
        property real lift: phase === "held" ? 1.1 : 1
        Behavior on lift { NumberAnimation { duration: 160; easing.type: Easing.OutBack } }
        /** The mascot's centre in the ghost: from his place in the pill to the grip. */
        readonly property real cx: 7 + 12 + (Math.max(19, Math.min(width - 19, root.grip.x)) - 19) * fold
        // Grows, shrinks and wriggles around the mascot, wherever he is in it.
        transform: [
            Rotation { origin.x: ghost.cx; origin.y: ghost.height / 2; angle: ghost.phase === "held" ? ghost.wobble : 0 },
            Scale { origin.x: ghost.cx; origin.y: ghost.height / 2; xScale: ghost.lift * ghost.shrink; yScale: ghost.lift * ghost.shrink }
        ]

        // Wriggling while held.
        SequentialAnimation on wobble {
            running: ghost.phase === "held"
            loops: Animation.Infinite
            NumberAnimation { to: 5; duration: 120; easing.type: Easing.InOutSine }
            NumberAnimation { to: -5; duration: 240; easing.type: Easing.InOutSine }
            NumberAnimation { to: 0; duration: 120; easing.type: Easing.InOutSine }
            PauseAnimation { duration: 260 }
        }

        readonly property color tint: root.tint
        // The pill's body: folds into a disc behind the mascot and fades out.
        Rectangle {
            id: body
            width: ghost.width - (ghost.width - ghost.height) * ghost.fold
            height: ghost.height
            x: (ghost.cx - ghost.height / 2) * ghost.fold
            radius: height / 2
            color: Qt.lighter(root.hexA(ghost.tint, 0x2e / 255), 1.06)
            border.width: 1
            border.color: root.hexA(ghost.tint, root.overCard ? 0.95 : 0x8c / 255)
            opacity: 1 - ghost.fold
        }
        C.CText {
            // As the pill: right of the mini.
            x: 7 + 24 + 10
            width: ghost.width - x - 6
            anchors.verticalCenter: parent.verticalCenter
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
            text: root.task ? root.task.name : ""
            size: 10
            cssWeight: 600
            color: Qt.lighter(ghost.tint, 1.3)
            // Tucks in behind the mascot as the pill folds.
            opacity: 1 - Math.min(1, ghost.fold * 1.6)
            transform: Scale { origin.x: ghost.cx - 7 - 24 - 10; origin.y: 7; xScale: 1 - 0.6 * ghost.fold; yScale: 1 - 0.3 * ghost.fold }
        }
        C.MiniBot {
            id: mini
            // He comes under the pointer as the pill folds behind him.
            x: ghost.cx - 12
            z: 1
            anchors.verticalCenter: parent.verticalCenter
            task: root.task
            bodySize: 24
            // Melts into the ball: shrinks as it fades (crossfaded, so there's
            // never a gap with neither showing).
            opacity: 1 - Math.max(0, (ghost.ball - 0.25) / 0.75)
            scale: 1 - 0.35 * ghost.ball
        }
        // The ball he turns into, in his colour: grows out of him.
        Rectangle {
            z: 1
            x: ghost.cx - width / 2
            anchors.verticalCenter: parent.verticalCenter
            width: 22
            height: width
            radius: width / 2
            color: ghost.tint
            opacity: Math.min(1, ghost.ball / 0.6)
            scale: 0.45 + 0.55 * ghost.ball
        }
    }

    // ── Back to its place ──
    // A moment after the pickup: the pill folds away behind him.
    SequentialAnimation {
        id: foldIn
        PauseAnimation { duration: 140 }
        NumberAnimation { target: ghost; property: "fold"; to: 1; duration: 260; easing.type: Easing.InOutCubic }
    }

    ParallelAnimation {
        id: back
        NumberAnimation { target: ghost; property: "fold"; to: 0; duration: 220; easing.type: Easing.OutCubic }
        NumberAnimation { id: backX; target: ghost; property: "x"; duration: 220; easing.type: Easing.OutBack; easing.overshoot: 1.2 }
        NumberAnimation { id: backY; target: ghost; property: "y"; duration: 220; easing.type: Easing.OutBack; easing.overshoot: 1.2 }
        onFinished: root.finish()
    }

    // ── Retired ──
    SequentialAnimation {
        id: retireAnim
        // Falls (or rises) onto the card's centre, a little bounce on landing.
        ParallelAnimation {
            // Let go before the fold was done: it finishes on the way down.
            NumberAnimation { target: ghost; property: "fold"; to: 1; duration: 140; easing.type: Easing.OutCubic }
            NumberAnimation { id: fallX; target: ghost; property: "x"; duration: 240; easing.type: Easing.OutCubic }
            NumberAnimation { id: fallY; target: ghost; property: "y"; duration: 240; easing.type: Easing.OutBounce }
        }
        PauseAnimation { duration: 110 }
        // Into a ball.
        NumberAnimation { target: ghost; property: "ball"; to: 1; duration: 260; easing.type: Easing.BezierSpline; easing.bezierCurve: C.RoboTheme.ease }
        PauseAnimation { duration: 40 }
        ScriptAction {
            script: {
                // The conversation closes now (its answer stops); its cell goes.
                if (root.conv) C.Robo.lib.ChatView.chat().retire(root.conv);
            }
        }
        // Shrinks away…
        NumberAnimation { target: ghost; property: "shrink"; to: 0; duration: 120; easing.type: Easing.InBack; easing.overshoot: 2 }
        // …pop.
        ScriptAction {
            script: {
                const c = ghost.mapToItem(root, ghost.cx, ghost.height / 2);
                pop.x = c.x - pop.width / 2;
                pop.y = c.y - pop.height / 2;
                pop.tint = ghost.tint;
                ghost.phase = "";
                pop.play();
                C.Robo.lib.Sound.play("pop");
            }
        }
        PauseAnimation { duration: 260 }
        ScriptAction {
            script: {
                ghost.ball = 0;
                ghost.shrink = 1;
                ghost.fold = 0;
                root.finish();
            }
        }
    }

    // ── The pop: little lines bursting out of where the ball was ──
    Item {
        id: pop
        width: 90; height: 90
        z: 2
        property color tint: "#ffffff"
        property real t: 0
        visible: t > 0 && t < 1
        function play() { t = 0.001; burst.restart(); }
        NumberAnimation on t { id: burst; running: false; from: 0.001; to: 1; duration: 260; easing.type: Easing.OutQuad }
        Repeater {
            model: 8
            Rectangle {
                required property int index
                readonly property real angle: index * 45 + 22.5
                // Each line starts at the ball's edge and flies out as it shortens.
                readonly property real dist: 9 + 22 * pop.t
                width: 2.5
                height: 10 * (1 - pop.t) + 2
                radius: 1.25
                color: Qt.lighter(pop.tint, 1.15)
                opacity: 1 - pop.t * pop.t
                x: pop.width / 2 - width / 2 + Math.sin(angle * Math.PI / 180) * dist
                y: pop.height / 2 - height / 2 - Math.cos(angle * Math.PI / 180) * dist
                rotation: angle
            }
        }
    }
}
