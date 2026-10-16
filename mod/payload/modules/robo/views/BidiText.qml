import QtQuick
import qs.modules.robo as C

// A C.CText that reads the way upstream's text does inside a `direction: rtl`
// block (html[data-dir=rtl], style.css "Arabic: right to left"). It takes its
// direction from the layout mirroring it inherits (the RTL blocks of the views
// set LayoutMirroring with childrenInherit; the LTR exceptions turn it off):
// - the paragraph reads right to left (an RLM as the first strong character),
//   so its punctuation sits where the browser puts it and it aligns right;
// - a one-line text that overflows: the browser clips it on the left, the end
//   of the line. For a left-to-right line (an English step, a path) that cuts
//   its start, which Qt does with ElideLeft on the plain text.
// Use it for the text of an RTL block whose direction matters (sentences,
// mixed scripts); the views' plain labels just mirror their position.
C.CText {
    id: bt
    property string raw: ""
    readonly property bool rtl: LayoutMirroring.enabled
    readonly property bool clipStart: rtl && maximumLineCount === 1 && !bt.startsRtl(raw) && tm.advanceWidth > width + 0.5
    // (Its trailing punctuation belongs to the right-to-left paragraph: it goes to
    // the far left, where the clip takes it.)
    text: !rtl || raw === "" ? raw : clipStart ? raw.replace(/[\s.,;:!?\u2026]+$/, "") : "\u200F" + raw
    elide: clipStart ? Text.ElideLeft : Text.ElideRight
    /** First strong character right to left (Hebrew / Arabic blocks)? */
    function startsRtl(s) {
        const m = /[A-Za-zÀ-ɏͰ-ϿЀ-ӿऀ-෿぀-鿿가-힯]|[֐-ࣿיִ-﷿ﹰ-﻿]/.exec(s || "");
        return !!m && /[֐-ࣿיִ-﷿ﹰ-﻿]/.test(m[0]);
    }
    TextMetrics { id: tm; font: bt.font; text: bt.raw }
}
