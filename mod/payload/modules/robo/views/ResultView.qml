import QtQuick
import qs.modules.robo as C

// views/views.ts buildViews(): "result" is a placeholder in the Windows/Linux
// build (not in v1) — buildPlaceholder(tl("Result"), "").
Item {
    property bool viewOn: false
    ChatPlaceholder {
        anchors.fill: parent
        title: C.Robo.rev >= 0 ? C.Robo.lib.I18n.t("Result") : ""
    }
}
