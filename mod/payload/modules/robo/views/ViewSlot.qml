import QtQuick
import qs.modules.robo as C

// One upstream `.view`: absolutely placed, fades/scales in when it is the
// island's view (style.css .view / .view.on transitions). The view itself is
// <Name>View.qml in this folder, loaded while it is on (or fading out).
Item {
    id: slot
    property string viewName: ""
    readonly property bool on: C.Robo.rev >= 0 && C.Robo.state.view === viewName
    readonly property string fileName: viewName.charAt(0).toUpperCase() + viewName.slice(1) + "View.qml"

    opacity: on ? 1 : 0
    scale: on ? 1 : 0.97
    enabled: on
    visible: opacity > 0 || on

    // .view.on: opacity 0.3 s ease-out AFTER 0.16 s; leaving: 0.16 s ease-in at once.
    Behavior on opacity {
        SequentialAnimation {
            PauseAnimation { duration: slot.on ? 160 : 0 }
            NumberAnimation {
                duration: slot.on ? 300 : 160
                easing.type: Easing.BezierSpline
                easing.bezierCurve: slot.on ? C.RoboTheme.easeOut : C.RoboTheme.easeIn
            }
        }
    }
    Behavior on scale {
        SequentialAnimation {
            PauseAnimation { duration: slot.on ? 160 : 0 }
            NumberAnimation {
                duration: slot.on ? 300 : 0
                // cubic-bezier(0.3, 1.2, 0.4, 1)
                easing.type: Easing.BezierSpline
                easing.bezierCurve: [0.3, 1.2, 0.4, 1, 1, 1]
            }
        }
    }

    Loader {
        id: loader
        anchors.fill: parent
        active: slot.visible
        source: slot.fileName
        onStatusChanged: if (status === Loader.Error) console.warn("ambxst-robo: no view", slot.fileName)
    }
    Binding {
        target: loader.item
        property: "viewOn"
        value: slot.on
        when: loader.item !== null && loader.item.hasOwnProperty("viewOn")
    }
}
