import QtQuick
import qs.modules.robo as C

// Files dragged over Robo (the bar's compact island or the open notch).
DropArea {
    keys: ["text/uri-list"]
    /** (x, y) in this item → the island's cursor, while dragging. */
    property var toIsland: null
    onEntered: drag => { drag.accept(Qt.CopyAction); C.Robo.fileDrag("enter"); }
    onPositionChanged: drag => {
        if (toIsland) toIsland(drag.x, drag.y);
        C.Robo.fileDrag("over");
    }
    onExited: C.Robo.fileDrag("leave")
    onDropped: drop => {
        drop.accept(Qt.CopyAction);
        C.Robo.fileDrag("drop", drop.hasUrls ? drop.urls : []);
    }
}
