import QtQuick
import QtQuick.Controls
import qs.modules.robo as C

// views/views.ts foldButton(): `.icon-btn.fold` — 16 px disc rgba(255,255,255,.07)
// at top 8 / right 10, ⌃ (chevronUp 8 px, stroke 2.4, dim-4). Folds the waiting
// card to the compact island without answering it (Mac #290).
Rectangle {
    id: f
    // Absolutely placed in the card's padding box: 1 px inside its border.
    x: parent.width - 1 - 10 - width
    y: 1 + 8
    z: 2
    width: 16
    height: 16
    radius: 8
    color: Qt.rgba(1, 1, 1, 0.07)
    C.Icon {
        anchors.centerIn: parent
        path: C.Robo.lib.ICONS.chevronUp
        size: 8
        stroke: 2.4
        color: C.RoboTheme.dim4
    }
    MouseArea {
        id: ma
        anchors.fill: parent
        hoverEnabled: true
        onClicked: C.Robo.island && C.Robo.island.actions.foldApproval()
    }
    ToolTip.visible: ma.containsMouse
    ToolTip.delay: 700
    ToolTip.text: C.Robo.rev >= 0 ? C.Robo.lib.I18n.t("Later — keep it waiting") : ""
}
