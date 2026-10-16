import QtQuick
import qs.modules.robo as C
// style.css .link-btn: borderless, 500 11px, colour given inline upstream.
C.CText {
    id: l
    signal clicked()
    size: 11
    cssWeight: 500
    MouseArea { anchors.fill: parent; onClicked: l.clicked() }
}
