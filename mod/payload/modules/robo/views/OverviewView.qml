pragma ComponentBehavior: Bound

import QtQuick
import qs.modules.robo as C

// views/views.ts buildOverview(): left card (ticker / integration card / plan /
// diff / Spotify) 322 wide, gap 10, right card with the pills of the other tasks.
Item {
    id: root
    property bool viewOn: false
    readonly property var st: C.Robo.state
    readonly property var lib: C.Robo.lib
    readonly property int rev: C.Robo.rev
    readonly property var task: rev >= 0 ? st.focusTask : null
    // Port (his ask): every other pill, not upstream's first 4; the grid scrolls
    // once there are more than its three rows hold.
    readonly property var others: rev >= 0 ? st.otherTasks : []
    readonly property string pillKey: others.map(t => t.id + ":" + t.color + ":" + (t.pillBadge || "")).join("|")

    /** Which left body upstream would show for the focused task. */
    readonly property string mode: {
        void rev;
        if (lib.Usage.planCardOpen()) return "plan";
        if (task && leftLoader.diffId !== null && st.findDiff(task.id, leftLoader.diffId)) return "diff";
        if (task && C.RoboViews.hasSessionTicker(task)) return "ticker";
        if (task && task.id === lib.Spotify.SPOTIFY_ID) return "spotify";
        if (task) return "card";
        return "";
    }

    Component.onCompleted: C.Robo.registerView("overview", root)
    Component.onDestruction: C.Robo.unregisterView("overview", root)
    function tick(nowMs) { return leftLoader.item && leftLoader.item.tick ? leftLoader.item.tick(nowMs) : false; }
    function command(c) {
        // Ctrl+E (toggleDiff): closes the open diff, else opens the focused pill's latest edit.
        if (c === "toggleDiff") {
            if (leftLoader.diffId !== null) { closeDiff(); return; }
            const id = lib.Status.latestDiffId(st.focusTask);
            if (id !== null) openDiff(id);
            return;
        }
        if (leftLoader.item && leftLoader.item.command) leftLoader.item.command(c);
    }
    // The diff open in the left card (activeDiffId upstream): TickerCard / DiffCard drive it.
    function openDiff(id) { leftLoader.diffId = id; st.notify(); }
    function closeDiff() { if (leftLoader.diffId === null) return; leftLoader.diffId = null; st.notify(); }
    /** Escape steps back out of the diff before it closes the island; true = handled. */
    function keyDown(ev) { return leftLoader.item && leftLoader.item.keyDown ? leftLoader.item.keyDown(ev) === true : false; }
    // A new focus, leaving the overview or folding the island closes the diff.
    property string diffTaskId: ""
    readonly property var diffId: leftLoader.diffId
    onRevChanged: {
        const fid = task ? task.id : "";
        if (fid !== diffTaskId) { diffTaskId = fid; leftLoader.diffId = null; }
        if (leftLoader.diffId !== null && (st.view !== "overview" || st.mode !== "expanded")) leftLoader.diffId = null;
    }

    Card {
        id: left
        width: 322
        height: parent.height
        Loader {
            id: leftLoader
            // Port: the launch reveal lifts the card's text in (RoboTab).
            opacity: C.Robo.introText
            transform: Translate { y: 12 * (1 - C.Robo.introText) }
            property var diffId: null
            anchors.fill: parent
            source: root.mode === "card" ? "IntegrationCard.qml"
                  : root.mode === "ticker" ? "TickerCard.qml"
                  : root.mode === "plan" ? "PlanCard.qml"
                  : root.mode === "diff" ? "DiffCard.qml"
                  : root.mode === "spotify" ? "SpotifyCard.qml" : ""
            onLoaded: {
                if (item.hasOwnProperty("overview")) item.overview = root;
                if (item.hasOwnProperty("task")) item.task = Qt.binding(() => root.task);
            }
        }
        // .jump: ↗ in the corner (hidden in a detail, plan or diff).
        Rectangle {
            visible: !(leftLoader.item && leftLoader.item.detailOpen) && root.mode !== "plan" && root.mode !== "diff"
            x: parent.width - 10 - width
            y: 8
            z: 2
            width: 16; height: 16; radius: 8
            color: Qt.rgba(1, 1, 1, 0.07)
            C.Icon { anchors.centerIn: parent; path: root.lib.ICONS.arrowUpRight; size: 8; color: C.RoboTheme.dim4 }
            MouseArea { anchors.fill: parent; onClicked: C.Robo.island && C.Robo.island.actions.openTarget() }
        }
    }

    Card {
        x: 322 + 10
        width: parent.width - x
        height: parent.height
        // Port: the launch reveal slides it in from the right (RoboTab).
        opacity: C.Robo.introBoxes
        transform: Translate { x: 30 * (1 - C.Robo.introBoxes) }
        // .pills: 2 columns, 28 px rows, gap 4, padding 0 8 (inside the card's
        // 1 px border), centred vertically.
        // Port (his ask): minis grow in and shrink away, the others slide to
        // their new place. Same layout as the Grid it replaces; the model is
        // kept in step with pillKey item by item, so only what changed moves
        // (a changed colour or badge still reloads its pill, replaying its
        // entry animation as upstream's rebuild does).
        ListModel { id: pillModel }
        function syncPills() {
            const keys = root.pillKey ? root.pillKey.split("|") : [];
            const ids = keys.map(k => k.split(":")[0]);
            for (let i = pillModel.count - 1; i >= 0; i--) {
                if (ids.indexOf(pillModel.get(i).taskId) < 0) pillModel.remove(i);
            }
            for (let i = 0; i < keys.length; i++) {
                let at = -1;
                for (let j = i; j < pillModel.count; j++) if (pillModel.get(j).taskId === ids[i]) { at = j; break; }
                if (at < 0) pillModel.insert(i, { taskId: ids[i], key: keys[i] });
                else {
                    if (at !== i) pillModel.move(at, i, 1);
                    if (pillModel.get(i).key !== keys[i]) pillModel.setProperty(i, "key", keys[i]);
                }
            }
        }
        Connections {
            target: root
            function onPillKeyChanged() { grid.parent.syncPills(); }
        }
        Component.onCompleted: syncPills()

        GridView {
            id: grid
            x: 1 + 8
            // The cells carry the 4 px gap on their right: the last one's falls outside.
            width: parent.width - 2 - 16 + 4
            readonly property int rows: Math.max(1, Math.ceil(pillModel.count / 2))
            readonly property real fullHeight: rows * 28 + (rows - 1) * 4
            // Up to the card's inside (its 1 px border and 6 px of air each side).
            readonly property real maxHeight: parent.height - 2 - 12
            height: Math.min(fullHeight, maxHeight)
            clip: fullHeight > maxHeight
            boundsBehavior: Flickable.StopAtBounds
            anchors.verticalCenter: parent.verticalCenter
            Behavior on height { NumberAnimation { duration: 260; easing.type: Easing.BezierSpline; easing.bezierCurve: C.RoboTheme.easeInOut } }
            interactive: fullHeight > maxHeight
            cellWidth: width / 2
            cellHeight: 28 + 4
            model: pillModel
            delegate: Item {
                id: cell
                required property string taskId
                required property string key
                width: grid.cellWidth - 4
                height: 28
                Loader {
                    id: pillLoader
                    anchors.fill: parent
                    source: cell.taskId === root.lib.Spotify.SPOTIFY_ID ? "SpotifyPill.qml" : "Pill.qml"
                    onLoaded: item.task = root.others.find(t => t.id === cell.taskId) || null
                }
                // Colour or badge changed: a fresh pill, as upstream rebuilds it.
                onKeyChanged: {
                    pillLoader.active = false;
                    pillLoader.active = true;
                }
            }
            add: Transition {
                NumberAnimation { property: "scale"; from: 0.4; to: 1; duration: 280; easing.type: Easing.OutBack; easing.overshoot: 1.4 }
                NumberAnimation { property: "opacity"; from: 0; to: 1; duration: 200; easing.type: Easing.BezierSpline; easing.bezierCurve: C.RoboTheme.easeOut }
            }
            remove: Transition {
                NumberAnimation { property: "scale"; to: 0.3; duration: 220; easing.type: Easing.BezierSpline; easing.bezierCurve: C.RoboTheme.easeIn }
                NumberAnimation { property: "opacity"; to: 0; duration: 200; easing.type: Easing.BezierSpline; easing.bezierCurve: C.RoboTheme.easeIn }
            }
            displaced: Transition {
                NumberAnimation { properties: "x,y"; duration: 260; easing.type: Easing.BezierSpline; easing.bezierCurve: C.RoboTheme.easeInOut }
                // A cell caught mid-add or mid-remove ends up whole.
                NumberAnimation { property: "scale"; to: 1; duration: 200 }
                NumberAnimation { property: "opacity"; to: 1; duration: 200 }
            }
            move: Transition {
                NumberAnimation { properties: "x,y"; duration: 260; easing.type: Easing.BezierSpline; easing.bezierCurve: C.RoboTheme.easeInOut }
                // Moved mid-grow-in: it still ends whole.
                NumberAnimation { property: "scale"; to: 1; duration: 200 }
                NumberAnimation { property: "opacity"; to: 1; duration: 200 }
            }
            // No longer scrolling: back to the top row.
            onInteractiveChanged: if (!interactive) positionViewAtBeginning()
        }
    }
}
