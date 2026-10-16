pragma ComponentBehavior: Bound

import QtQuick
import qs.modules.robo as C

// views/usage.ts buildPlanPill() ×2 in views.ts buildHeader(): the Claude and
// Codex plan pills before the gear (off by default). .plan-pills (gap 5,
// margin-right -6, or -5 with both: the gear then sits 8 / 5 px away),
// .plan-pill (4 8 padding, 600 10/12, lit while hovered or while its card is open).
Item {
    id: root
    readonly property var lib: C.Robo.lib
    readonly property var pv: lib.PlanView
    readonly property int rev: C.Robo.rev
    // Recomputed every 30 s too: the label follows a window that has reset.
    property real nowMs: Date.now()
    readonly property var d: rev >= 0 ? pv.pills(nowMs) : ({ any: false, both: false, claudeOn: false, codexOn: false })
    /** Both pills: the header tightens its right side (.header-actions.both-plans). */
    readonly property bool both: d.both
    visible: d.any
    implicitWidth: row.implicitWidth - (d.both ? 5 : 6)
    implicitHeight: row.implicitHeight
    width: implicitWidth
    height: implicitHeight

    onRevChanged: { nowMs = Date.now(); pv.syncCodexShown(); }
    Timer { interval: 30000; repeat: true; running: root.d.any; onTriggered: root.nowMs = Date.now() }

    component PlanPill: Rectangle {
        id: pp
        property var info: ({ color: "#6b7079", label: "", active: false })
        property bool codex: false
        readonly property color plan: info.color
        readonly property bool lit: ma.containsMouse || info.active
        implicitWidth: r.implicitWidth + 18
        implicitHeight: 22
        radius: 11
        color: lit ? Qt.rgba(plan.r, plan.g, plan.b, 0.18) : C.RoboTheme.cardFlat
        border.width: 1
        border.color: Qt.rgba(plan.r, plan.g, plan.b, lit ? 0.55 : 0.14)
        Behavior on color { ColorAnimation { duration: 180; easing.type: Easing.BezierSpline; easing.bezierCurve: C.RoboTheme.ease } }
        Behavior on border.color { ColorAnimation { duration: 180; easing.type: Easing.BezierSpline; easing.bezierCurve: C.RoboTheme.ease } }
        Row {
            id: r
            anchors.centerIn: parent
            spacing: 4
            Dot { size: 6; color: pp.info.color; anchors.verticalCenter: parent.verticalCenter }
            C.CText {
                anchors.verticalCenter: parent.verticalCenter
                text: pp.info.label
                size: 10
                cssWeight: 600
                elide: Text.ElideNone
                color: pp.lit ? Qt.rgba(pp.plan.r * 0.7 + 0.3, pp.plan.g * 0.7 + 0.3, pp.plan.b * 0.7 + 0.3, 1) : C.RoboTheme.dim3
                Behavior on color { ColorAnimation { duration: 180; easing.type: Easing.BezierSpline; easing.bezierCurve: C.RoboTheme.ease } }
            }
        }
        MouseArea { id: ma; anchors.fill: parent; hoverEnabled: true; onClicked: root.pv.clickPill(pp.codex) }
    }

    Row {
        id: row
        spacing: 5
        PlanPill { visible: root.d.claudeOn; info: root.d.claude || ({ color: "#6b7079", label: "", active: false }) }
        PlanPill { visible: root.d.codexOn; codex: true; info: root.d.codex || ({ color: "#6b7079", label: "", active: false }) }
    }
}
