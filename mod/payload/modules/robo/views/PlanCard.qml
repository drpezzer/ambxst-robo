pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.modules.robo as C

// views/usage.ts PlanCard: stands in for the overview's left card while a plan
// pill is open — Claude (5 hours + week) or Codex (5 hours if any, week,
// resets). The countdowns move every 30 s while it is open (views.ts
// syncPlanTimer). What it shows: lib/views/plan.ts (C.Robo.lib.PlanView).
// style.css .plan-card, .plan-head, .plan-rows, .plan-row…
Item {
    id: root
    property var task: null
    readonly property bool detailOpen: false
    readonly property var lib: C.Robo.lib
    readonly property int rev: C.Robo.rev
    property real nowMs: Date.now()
    readonly property var d: rev >= 0 ? lib.PlanView.card(nowMs) : ({ rows: [] })
    onRevChanged: nowMs = Date.now()
    // Arabic: `html[data-dir=rtl] .plan-card { direction: rtl }` — head and rows
    // run right to left inside the card's physical padding.
    readonly property bool rtl: rev >= 0 && lib.I18n.isRtl()
    LayoutMirroring.enabled: rtl
    LayoutMirroring.childrenInherit: true
    Timer {
        interval: 30000
        repeat: true
        running: root.visible
        onTriggered: if (root.lib.Usage.planCardOpen() && C.Robo.state.mode === "expanded") C.Robo.state.notify()
    }

    // .plan-head: padding 0 36 0 108, gap 6 (inside the card's 1 px border, padding-top 10).
    RowLayout {
        x: 1 + 108
        y: 1 + 10
        width: parent.width - 2 - 108 - 36
        spacing: 6
        Dot { size: 7; color: root.d.color || "#6B7079" }
        C.CText { text: root.d.title || ""; size: 12; cssWeight: 600; elide: Text.ElideNone; Layout.minimumWidth: implicitWidth }
        C.CText { text: root.d.sub || ""; size: 11; color: C.RoboTheme.dim2; Layout.minimumWidth: 0 }
        Item { Layout.fillWidth: true }
    }

    // .plan-rows: gap 5, padding 8 12 0 108.
    Column {
        id: rows
        x: 1 + 108
        y: 1 + 10 + 15 + 8
        width: parent.width - 2 - 108 - 12
        spacing: 5
        Repeater {
            model: root.d.rows
            delegate: Row {
                id: pr
                required property var modelData
                anchors.left: parent.left
                spacing: 5
                height: 15
                BidiText { width: 40; anchors.verticalCenter: parent.verticalCenter; raw: pr.modelData.label; size: 11; color: C.RoboTheme.dim3; elide: rtl ? Text.ElideNone : Text.ElideRight }
                // .plan-bar 50×4, rgba(255,255,255,.08); .plan-fill in planColor.
                Rectangle {
                    visible: pr.modelData.kind === "gauge"
                    width: 50; height: 4; radius: 2
                    anchors.verticalCenter: parent.verticalCenter
                    color: Qt.rgba(1, 1, 1, 0.08)
                    Rectangle {
                        // A block: from the right edge, right to left.
                        anchors.left: parent.left
                        width: parent.width * pr.modelData.pct / 100
                        height: parent.height; radius: 2
                        color: pr.modelData.color || "transparent"
                    }
                }
                C.CText {
                    visible: pr.modelData.kind === "gauge"
                    width: 30
                    anchors.verticalCenter: parent.verticalCenter
                    horizontalAlignment: Text.AlignRight
                    // text-align: right is physical.
                    LayoutMirroring.enabled: false
                    text: pr.modelData.pctText; size: 11; cssWeight: 600; color: "#c5c8cd"; elide: Text.ElideNone
                    font.features: { "tnum": 1 }
                }
                C.Icon {
                    visible: pr.modelData.kind === "gauge"
                    anchors.verticalCenter: parent.verticalCenter
                    path: root.lib.PlanView.resetIcon; size: 8; stroke: 2.6; color: C.RoboTheme.dim3
                }
                C.CText {
                    visible: pr.modelData.kind === "gauge"
                    anchors.verticalCenter: parent.verticalCenter
                    text: pr.modelData.reset; size: 10; color: C.RoboTheme.dim3; elide: Text.ElideNone
                }
                // .plan-none / .plan-credits
                C.CText {
                    visible: pr.modelData.kind !== "gauge"
                    anchors.verticalCenter: parent.verticalCenter
                    text: pr.modelData.text; size: 11
                    cssWeight: pr.modelData.kind === "credits" ? 600 : 400
                    color: pr.modelData.kind === "credits" ? "#c5c8cd" : C.RoboTheme.dim3
                    elide: Text.ElideNone
                }
            }
        }
    }
}
