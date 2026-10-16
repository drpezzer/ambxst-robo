import QtQuick

// A CSS flex row (align-items: center) for the integration cards: children
// keep their implicit width; one with `property bool shrink: true` gives way
// when the row is too narrow (flex-shrink, in proportion to its width, text
// elides); one with `property bool push: true` takes the free space before it
// (margin-left: auto; the right side when mirrored). Qt's RowLayout only shrinks fillWidth items and then
// also grows them, which is not what the cards do.
Item {
    id: fr
    property real spacing: 5
    implicitWidth: 0
    implicitHeight: 0
    height: implicitHeight
    property var hooked: []
    // Inside an upstream `direction: rtl` block (Arabic) the row runs right to
    // left: the inherited LayoutMirroring places it from its right edge.
    readonly property bool mirrored: LayoutMirroring.enabled
    onMirroredChanged: schedule()

    function schedule() { if (!lay.running) lay.start(); }
    Timer { id: lay; interval: 0; onTriggered: fr.relayout() }
    function base(k) { return k.implicitWidth > 0 ? k.implicitWidth : k.width; }
    function relayout() {
        const kids = [];
        for (let i = 0; i < children.length; i++) if (children[i].visible) kids.push(children[i]);
        let total = 0, shrinkBase = 0, h = 0;
        for (const k of kids) {
            const w = base(k);
            total += w;
            if (k.shrink === true) shrinkBase += w;
            h = Math.max(h, k.implicitHeight > 0 ? k.implicitHeight : k.height);
        }
        total += Math.max(0, kids.length - 1) * spacing;
        implicitWidth = total;
        implicitHeight = h;
        const over = Math.max(0, total - width);
        const free = Math.max(0, width - total);
        let x = 0, pushed = false;
        for (const k of kids) {
            let w = base(k);
            if (k.shrink === true && over > 0 && shrinkBase > 0) w = Math.max(0, w - over * base(k) / shrinkBase);
            // margin-left is physical: mirrored, the free space is on the far side of the item.
            const push = k.push === true && !pushed;
            if (push) pushed = true;
            if (push && !mirrored) x += free;
            k.x = mirrored ? width - x - w : x;
            if (k.shrink === true) k.width = w;
            k.y = (height - (k.implicitHeight > 0 ? k.implicitHeight : k.height)) / 2;
            x += w + spacing;
            if (push && mirrored) x += free;
        }
    }
    onWidthChanged: schedule()
    onHeightChanged: schedule()
    onChildrenChanged: {
        for (let i = 0; i < children.length; i++) {
            const k = children[i];
            if (hooked.indexOf(k) >= 0) continue;
            hooked.push(k);
            k.implicitWidthChanged.connect(fr.schedule);
            k.implicitHeightChanged.connect(fr.schedule);
            k.visibleChanged.connect(fr.schedule);
        }
        schedule();
    }
    Component.onCompleted: relayout()
}
