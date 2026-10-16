import QtQuick
import qs.modules.robo as C

// Lives inside Ambxst's shell panel (one per display, patched into
// UnifiedShellPanel.qml) for the desktop mascot:
//   * tells RoboDesktop where the notch is on this display (the home zone);
//   * while the notch is open with the keyboard (Exclusive), Hyprland sends
//     every pointer event to this panel ("exclusive layer surfaces are forced
//     above all"), so his own window never gets the press: a 120 px area over
//     him here hands presses on his body to his page (poke, double-click home,
//     right-click wardrobe, drag — the drag then follows the global cursor).
//     It may sit outside this panel when he is on another display: Hyprland
//     still sends the forced events here, in this panel's coordinates.
Item {
    id: root

    /** The RoboDesktop instance (RoboShell.desktop). */
    property var desktop: null
    property string screenName: ""
    /** The notch's hitbox item (NotchContent.notchHitbox). */
    property Item notchItem: null
    /** This panel has the keyboard exclusively (it then gets every pointer event). */
    property bool exclusive: false

    /** The notch, panel-local (= display-local; the panel covers its display). */
    function notchRect() {
        const n = root.notchItem;
        if (!n || !n.visible || n.width <= 0 || n.height <= 0) return null;
        const p = n.mapToItem(null, 0, 0);
        return { x: p.x, y: p.y, w: n.width, h: n.height };
    }

    Component.onCompleted: if (desktop && screenName) desktop.registerNotch(screenName, root)
    Component.onDestruction: if (desktop) desktop.unregisterNotch(screenName, root)
    onScreenNameChanged: if (desktop && screenName) desktop.registerNotch(screenName, root)
    onDesktopChanged: if (desktop && screenName) desktop.registerNotch(screenName, root)

    readonly property var page: desktop ? desktop.page : null
    readonly property var view: desktop && desktop.rev >= 0 && desktop.win ? desktop.win.view(screenName) : null
    /** He sits on the desktop (or is being dragged from here). */
    readonly property bool live: !!view && !!desktop.win && desktop.win.shown && (desktop.win.landed || desktop.win.dragging) && !desktop.win.carry

    // Port (his ask): a file dragged over the closed notch opens Robo on
    // the chat page with its drop look (island.ts onDragDrop); once it is open
    // the island's own DropArea takes the drag over.
    DropArea {
        id: notchDrop
        readonly property Item n: root.notchItem
        readonly property bool closedRobo: C.Robo.rev >= 0 && !!C.Robo.island && C.Robo.state.mode !== "expanded"
        x: { void root.width; if (!n) return 0; void n.x; void n.width; return n.mapToItem(root, 0, 0).x; }
        y: { if (!n) return 0; void n.y; void n.height; return n.mapToItem(root, 0, 0).y; }
        width: n ? n.width : 0
        height: n ? Math.max(n.height, 8) : 0
        enabled: closedRobo || containsDrag
        keys: ["text/uri-list"]
        onEntered: drag => {
            drag.accept(Qt.CopyAction);
            C.Robo.openTabRequested();
            C.Robo.fileDrag("enter");
        }
        onPositionChanged: C.Robo.fileDrag("over")
        // (Robo.fileDrag lets a leave settle first: when the notch opened
        // under the drag, the island's own DropArea takes it over at once.
        // Not reported at all, the drop look stayed on after the drag left.)
        onExited: C.Robo.fileDrag("leave")
        onDropped: drop => {
            drop.accept(Qt.CopyAction);
            C.Robo.fileDrag("drop", drop.hasUrls ? drop.urls : []);
        }
    }

    MouseArea {
        id: area
        // His small window's box, in this panel (frozen during a drag, like that window).
        x: root.view ? root.view.smallX : 0
        y: root.view ? root.view.smallY : 0
        width: 120
        height: 120
        enabled: root.exclusive && (root.live || pressed)
        visible: enabled
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        property point dbl: Qt.point(-1, -1)
        property bool dblPending: false

        // Off his body: not his, so the panel's own click-outside still works.
        onPressed: m => {
            const pg = root.page;
            if (!pg || !pg.hit(m.x, m.y)) { m.accepted = false; return; }
            if (m.button === Qt.RightButton) {
                pg.pointerDown(m.x, m.y, 2, 0, 0);
                pg.contextMenu(m.x, m.y);
                return;
            }
            pg.pointerDown(m.x, m.y, 0, 0, 0);
        }
        onPositionChanged: m => { if (root.page) root.page.pointerMove(m.x, m.y); }
        onReleased: m => {
            if (!root.page || m.button !== Qt.LeftButton) return;
            root.page.pointerUp(m.x, m.y);
            if (dblPending) {
                dblPending = false;
                root.page.doubleClick(dbl.x, dbl.y);
            }
        }
        onCanceled: if (root.page) root.page.cancelDrag()
        onDoubleClicked: m => {
            if (m.button !== Qt.LeftButton) return;
            dbl = Qt.point(m.x, m.y);
            dblPending = true;
        }
    }
}
