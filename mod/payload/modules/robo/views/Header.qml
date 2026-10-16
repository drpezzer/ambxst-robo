import QtQuick
import qs.modules.robo as C

// views/views.ts buildHeader(): tabs (overview / ask / drop) on the left, plan
// pills, gear and sound on the right. style.css #header, .tabs, .tab, .header-actions.
Item {
    id: root
    readonly property var st: C.Robo.state
    readonly property var icons: C.Robo.lib.ICONS
    readonly property string view: C.Robo.rev >= 0 ? st.view : ""
    readonly property bool soundOn: C.Robo.rev >= 0 && st.settings.soundEnabled
    opacity: view === "confused" ? 0 : 1
    Behavior on opacity { NumberAnimation { duration: 200; easing.type: Easing.BezierSpline; easing.bezierCurve: C.RoboTheme.easeInOut } }

    function go(v) {
        const i = C.Robo.island;
        if (!i) return;
        i.actions.blip();
        i.actions.setView(v);
    }

    component Tab: Rectangle {
        id: tab
        property string icon: ""
        property bool on: false
        signal clicked()
        width: 30
        height: 22
        radius: 11
        color: on ? C.RoboTheme.tabOn : (ma.containsMouse ? Qt.rgba(1, 1, 1, 0.07) : "transparent")
        C.Icon {
            anchors.centerIn: parent
            path: tab.icon
            size: 13
            color: tab.on ? C.RoboTheme.ink : (ma.containsMouse ? "#b0b5be" : C.RoboTheme.dim2)
        }
        MouseArea { id: ma; anchors.fill: parent; hoverEnabled: true; onClicked: tab.clicked() }
    }

    Row {
        x: 14
        anchors.verticalCenter: parent.verticalCenter
        spacing: 5
        Tab { icon: root.icons.house; on: root.view === "overview" || root.view === "empty"; onClicked: root.go("overview") }
        Tab { icon: root.icons.bubble; on: root.view === "prompt"; onClicked: root.go("prompt") }
        // Port (his ask): no separate drop page; files are dropped on the chat page.
    }

    Row {
        anchors.right: parent.right
        // .header-actions.both-plans: gap 10, padding-right 8 with both plan pills.
        anchors.rightMargin: planPills.both ? 8 : 16
        anchors.verticalCenter: parent.verticalCenter
        spacing: planPills.both ? 10 : 14
        PlanPills { id: planPills; anchors.verticalCenter: parent.verticalCenter }
        // Port (his ask): Claude Code's Remote Control for the open chat (lib/remote.ts):
        // a phone, lit green while on, breathing while it comes up.
        Item {
            id: rc
            width: 14; height: 14
            anchors.verticalCenter: parent.verticalCenter
            // (Made once: chat() notifies the first time, which a binding would re-enter.)
            property var chat: null
            Component.onCompleted: chat = C.Robo.lib.ChatView.chat()
            readonly property string conv: C.Robo.rev >= 0 && chat ? chat.conv : ""
            visible: C.Robo.rev >= 0 && !!chat && chat.remoteAvailable()
            readonly property bool on: C.Robo.rev >= 0 && conv !== "" && C.Robo.lib.Remote.isOn(conv)
            readonly property bool starting: C.Robo.rev >= 0 && conv !== "" && C.Robo.lib.Remote.isStarting(conv)
            C.Icon {
                id: rcIcon
                anchors.centerIn: parent
                path: "M8 2h8a2 2 0 0 1 2 2v16a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2zM12 18h.01"
                size: 14
                stroke: 2
                color: rc.on ? "#34D399" : (rcMa.containsMouse ? "#b0b5be" : C.RoboTheme.dim2)
                SequentialAnimation on opacity {
                    running: rc.starting && rcIcon.visible
                    loops: Animation.Infinite
                    onRunningChanged: if (!running) rcIcon.opacity = 1
                    NumberAnimation { to: 0.35; duration: 500; easing.type: Easing.InOutSine }
                    NumberAnimation { to: 1; duration: 500; easing.type: Easing.InOutSine }
                }
            }
            // The live dot.
            Rectangle {
                visible: rc.on
                width: 5; height: 5; radius: 2.5
                x: parent.width - 2; y: -2
                color: "#34D399"
            }
            MouseArea { id: rcMa; anchors.fill: parent; anchors.margins: -4; hoverEnabled: true; onClicked: void rc.chat.toggleRemote() }
        }
        // Port (his ask): a new conversation, from any page (Ctrl+K's newChat).
        Item {
            width: 14; height: 14
            anchors.verticalCenter: parent.verticalCenter
            // (Never refused, even while an answer comes: no dimmed look, his ask.)
            C.Icon {
                anchors.centerIn: parent
                path: "M12 3H5a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2v-7M18.4 2.6a1.8 1.8 0 0 1 3 3l-9 9-3.8 1 1-3.8z"
                size: 14
                stroke: 2
                color: newMa.containsMouse ? "#b0b5be" : C.RoboTheme.dim2
            }
            MouseArea { id: newMa; anchors.fill: parent; anchors.margins: -4; hoverEnabled: true; onClicked: C.Robo.lib.ChatView.newConversation() }
        }
        Item {
            width: 14; height: 14
            anchors.verticalCenter: parent.verticalCenter
            C.Icon {
                anchors.centerIn: parent
                path: root.view === "settings" ? root.icons.gearFill : root.icons.gear
                size: 14
                color: root.view === "settings" ? C.RoboTheme.ink : C.RoboTheme.dim2
            }
            // Port (his ask): Robo's settings are in Ambxst's settings window,
            // AI tab (settings/RoboSettings.qml open()).
            MouseArea { anchors.fill: parent; anchors.margins: -4; onClicked: C.Robo.lib.Bridge.openSettingsWindow() }
        }
        Item {
            width: 14; height: 14
            anchors.verticalCenter: parent.verticalCenter
            C.Icon {
                anchors.centerIn: parent
                path: root.soundOn ? root.icons.speakerOn : root.icons.speakerOff
                size: 14
                color: C.RoboTheme.dim2
            }
            MouseArea { anchors.fill: parent; anchors.margins: -4; onClicked: C.Robo.island && C.Robo.island.actions.toggleSound() }
        }
    }
}
