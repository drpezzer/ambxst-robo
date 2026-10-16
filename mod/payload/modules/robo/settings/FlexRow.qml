import QtQuick

// A CSS flex row (`display:flex; flex-wrap: wrap; gap; align-items`), which
// settings.css `.row` is and which QML's Row/Flow/RowLayout are not: items are
// placed at their flex-basis (a child's `flexBasis`, else its implicitWidth),
// wrap to a new line when they don't fit, then `flexGrow` children share what
// is left of their line; a line too narrow for one item shrinks the children
// that have `flexShrink` (wrapping text). Lines are as tall as their tallest
// item; items are centred in them (`align: "start"` = flex-start).
Item {
    id: fr
    property real gap: 12
    property real rowGap: gap
    property bool wrap: true
    property string align: "center"
    property real _h: 0
    implicitHeight: _h
    implicitWidth: {
        let w = 0, n = 0;
        for (let i = 0; i < children.length; i++) {
            const c = children[i];
            if (!c.visible || fr.skip(c)) continue;
            w += fr.basis(c) + (n++ ? gap : 0);
        }
        return w;
    }

    function skip(c) { return c.delegate !== undefined && c.model !== undefined; }
    function basis(c) { return c.flexBasis !== undefined ? c.flexBasis : c.implicitWidth; }

    readonly property string _deps: {
        let s = width + ":" + LayoutMirroring.enabled + ":";
        for (let i = 0; i < children.length; i++) {
            const c = children[i];
            s += (c.visible ? 1 : 0) + "," + c.implicitWidth + "," + c.implicitHeight + "," + (c.flexBasis !== undefined ? c.flexBasis : "") + ";";
        }
        return s;
    }
    on_DepsChanged: layout()
    property bool _busy: false
    function layout() {
        if (_busy) return;
        _busy = true;
        const items = [];
        for (let i = 0; i < children.length; i++) {
            const c = children[i];
            if (!c.visible || skip(c)) continue;
            items.push({ c: c, basis: basis(c), grow: c.flexGrow || 0, shrink: c.flexShrink || 0, min: c.minW || 0 });
        }
        const lines = [];
        let line = [], used = 0;
        for (const it of items) {
            const need = line.length ? used + gap + it.basis : it.basis;
            if (wrap && line.length && need > width + 0.01) {
                lines.push(line);
                line = [it];
                used = it.basis;
            } else {
                line.push(it);
                used = need;
            }
        }
        if (line.length) lines.push(line);
        let y = 0;
        for (const ln of lines) {
            let sum = 0;
            for (const it of ln) { it.size = it.basis; sum += it.basis; }
            let free = width - sum - gap * (ln.length - 1);
            if (free > 0) {
                let g = 0;
                for (const it of ln) g += it.grow;
                if (g > 0) for (const it of ln) it.size += free * it.grow / g;
            } else if (free < 0) {
                let s = 0;
                for (const it of ln) s += it.shrink * it.basis;
                if (s > 0) for (const it of ln) it.size = Math.max(it.min, it.basis + free * it.shrink * it.basis / s);
            }
            let x = 0, lineH = 0;
            const mirror = LayoutMirroring.enabled;
            for (const it of ln) {
                it.c.width = it.size;
                it.c.x = mirror ? width - x - it.size : x;
                x += it.size + gap;
                lineH = Math.max(lineH, it.c.height);
            }
            for (const it of ln) it.c.y = y + (align === "start" ? 0 : (lineH - it.c.height) / 2);
            y += lineH + rowGap;
        }
        _h = lines.length ? y - rowGap : 0;
        _busy = false;
    }
    Component.onCompleted: layout()
}
