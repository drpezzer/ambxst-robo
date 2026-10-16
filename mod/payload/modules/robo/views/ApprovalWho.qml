import QtQuick
import qs.modules.robo as C

// views/views.ts agentWho() + style.css .who-row: 8 px dot in the task's
// colour, the task name (600 12 px ink), the grey label (400 12 px dim-2), gap 7.
Row {
    id: w
    property var task: null
    property string label: ""
    spacing: 7
    height: lbl.implicitHeight
    Dot {
        visible: !!w.task
        size: 8
        color: w.task ? w.task.color : "white"
        anchors.verticalCenter: parent.verticalCenter
    }
    C.CText {
        visible: !!w.task
        anchors.verticalCenter: parent.verticalCenter
        text: w.task ? w.task.name : ""
        size: 12
        cssWeight: 600
    }
    C.CText {
        id: lbl
        anchors.verticalCenter: parent.verticalCenter
        text: w.label
        size: 12
        color: C.RoboTheme.dim2
    }
}
