import QtQuick
import qs.modules.robo as C
import qs.modules.robo.views as V

// Port only: what the Robo tab adds around Robo's island (his extras for
// the tab's spare room). The island sits at the top-left (640 wide); below it
// the home chat, while it shows its home; on its right, the chats column, the
// tab's full height. Fills the tab's content area.
Item {
    id: root
    /** The tab's C.RoboIsland (its animated height places the home chat). */
    property Item islandItem: null
    /** Where the home chat's Escape hands the keyboard back. */
    property Item keyTarget: null

    // Over the extras counts as over the island (its auto-close waits).
    HoverHandler {
        onHoveredChanged: if (root.islandItem && root.islandItem.island) root.islandItem.island.setExtraHover(hovered)
    }
    Component.onDestruction: if (root.islandItem && root.islandItem.island) root.islandItem.island.setExtraHover(false)

    readonly property real islandH: islandItem ? islandItem.islandH : 160
    /** The height the island's spring is heading for (the home chat settles under it). */
    readonly property real islandTargetH: islandItem ? islandItem.targetH : 160
    // The island's cards are 10 px in from its edges and end 10 px above its
    // bottom: the home chat keeps those gaps, the column starts level with
    // the header.
    // Port: the launch reveal (RoboTab) brings the home chat up from the
    // bottom and the column in from the right. On wrappers: the home chat's
    // own opacity is its show/hide fade with the island's views.
    Item {
        anchors.fill: parent
        opacity: C.Robo.introBoxes
        transform: Translate { y: 34 * (1 - C.Robo.introBoxes) }
        V.HomeChat {
            x: 10
            y: root.islandH
            width: 640 - 20
            height: Math.max(0, root.height - y)
            settledHeight: Math.max(0, root.height - root.islandTargetH)
            keyTarget: root.keyTarget
        }
    }
    Item {
        anchors.fill: parent
        opacity: C.Robo.introBoxes
        transform: Translate { x: 34 * (1 - C.Robo.introBoxes) }
        V.HistoryColumn {
            x: 640
            y: 8
            width: Math.max(0, root.width - x)
            height: Math.max(0, root.height - y)
            visible: width >= 120
        }
    }
}
