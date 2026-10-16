pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import qs.modules.robo as C

// views/markdown.ts renderMarkdown(): an answer's blocks (upstream's own
// parser, parseMarkdown / parseInline) drawn as .reply's children —
// headings, paragraphs, fenced code with a copy button, list items, quotes
// and rules (style.css .md-*). Inline runs become escaped rich text: model
// text never becomes markup; links open only when they are http(s).
Column {
    id: md
    property string markdown: ""
    /** Room in the row. .reply is a flex item of its row: it is as wide as its
     *  widest block (max-content), never wider than the row. */
    property real maxWidth: 0
    width: Math.min(maxWidth, Math.ceil(natural))
    property real natural: 0
    function measure() {
        let w = 0;
        for (let i = 0; i < rep.count; i++) {
            const l = rep.itemAt(i);
            if (l && l.item) w = Math.max(w, l.item.natural || 0);
        }
        natural = w;
    }
    readonly property var lib: C.Robo.lib
    readonly property var blocks: lib.ChatView.parseMarkdown(markdown)
    spacing: 6

    function esc(s) {
        return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
    }
    readonly property string codePad: "<span style=\"background-color:#27282b; font-size:"
        + C.RoboTheme.px(11.5) + "pt\">\u2004</span>"
    /** parseInline nodes → rich text (.reply strong, .md-code, .md-link, em). */
    function inl(nodes) {
        let out = "";
        for (const n of nodes) {
            switch (n.kind) {
            case "text": out += esc(n.text); break;
            case "code":
                // .md-code: padding 1 4, radius 4, rgba(255,255,255,.08), 400 11.5px mono #c8cdd4.
                // Opaque (#141518 + 8 % white): rich-text spans overlap by a pixel.
                // The 4 px padding: third-em spaces in the text font at the code's size
                // (a mono space is 0.6 em).
                out += codePad
                    + "<span style=\"background-color:#27282b; font-family:'" + C.RoboTheme.mono
                    + "'; font-size:" + C.RoboTheme.px(11.5) + "pt; color:#c8cdd4\">" + esc(n.text) + "</span>"
                    + codePad;
                break;
            case "strong": out += "<span style=\"color:#e8e9ec; font-weight:600\">" + inl(n.children) + "</span>"; break;
            case "em": out += "<i>" + inl(n.children) + "</i>"; break;
            case "link":
                if (!n.url) { out += inl(n.children); break; }
                out += "<a href=\"" + esc(n.url) + "\" style=\"color:#60a5fa; text-decoration:underline\">" + inl(n.children) + "</a>";
                break;
            }
        }
        return out;
    }
    /** Qt rounds a 12.5 px font up to 13 px: its line keeps Chromium's 15 px. */
    function lineFor(size) { return size === 12.5 ? 15 : 0; }
    function rich(text, size) {
        const lh = lineFor(size);
        return "<div style=\"white-space:pre-wrap" + (lh ? "; line-height:" + lh + "px; -qt-line-height-type:fixed" : "") + "\">"
            + inl(lib.ChatView.parseInline(text)) + "</div>";
    }

    /** .md-p: 400 12.5px #b0b5be, pre-wrap, wraps anywhere; selectable (user-select: text). */
    component MdText: TextEdit {
        property string source: ""
        property real size: 12.5
        property int cssWeight: 400
        readOnly: true
        selectByMouse: true
        persistentSelection: true
        textFormat: TextEdit.RichText
        text: md.rich(source, size)
        wrapMode: TextEdit.WrapAtWordBoundaryOrAnywhere
        color: "#b0b5be"
        selectionColor: Qt.rgba(0.38, 0.65, 0.98, 0.35)
        selectedTextColor: color
        font.family: C.RoboTheme.font
        font.pointSize: C.RoboTheme.px(size)
        font.weight: C.RoboTheme.weight(cssWeight)
        renderType: Text.NativeRendering
        onLinkActivated: link => void C.Robo.lib.Bridge.openUrl(link)
        HoverHandler { cursorShape: parent.hoveredLink ? Qt.PointingHandCursor : Qt.IBeamCursor }
    }

    Repeater {
        id: rep
        model: md.blocks
        delegate: Loader {
            id: blk
            required property var modelData
            width: md.width
            onLoaded: md.measure()
            Connections {
                target: blk.item
                ignoreUnknownSignals: true
                function onNaturalChanged() { md.measure(); }
            }
            sourceComponent: modelData.kind === "heading" ? heading
                : modelData.kind === "paragraph" ? paragraph
                : modelData.kind === "code" ? code
                : modelData.kind === "item" ? item
                : modelData.kind === "quote" ? quote
                : rule

            Component {
                id: heading
                // .md-h: 600 13px ink-2; .md-h1 (levels 1–2): 700 14px.
                MdText {
                    readonly property real natural: implicitWidth
                    width: blk.width
                    source: blk.modelData.text
                    size: blk.modelData.level <= 2 ? 14 : 13
                    cssWeight: blk.modelData.level <= 2 ? 700 : 600
                    color: C.RoboTheme.ink2
                }
            }
            Component {
                id: paragraph
                MdText { readonly property real natural: implicitWidth; width: blk.width; source: blk.modelData.text }
            }
            Component {
                id: item
                // .md-item: bullet (min-width 10, dim-3) + text, gap 6; nested by 12 px a level.
                Item {
                    readonly property real natural: bullet.x + bullet.width + 6 + itemText.implicitWidth
                    width: blk.width
                    implicitHeight: Math.max(bullet.implicitHeight, itemText.implicitHeight)
                    C.CText {
                        id: bullet
                        x: blk.modelData.indent * 12
                        width: Math.max(10, implicitWidth)
                        text: blk.modelData.prefix
                        size: 12.5
                        color: C.RoboTheme.dim3
                        elide: Text.ElideNone
                        lineHeightMode: Text.FixedHeight
                        lineHeight: 15
                    }
                    MdText {
                        id: itemText
                        x: bullet.x + bullet.width + 6
                        width: parent.width - x
                        source: blk.modelData.text
                    }
                }
            }
            Component {
                id: quote
                // .md-quote: a 2 px dim-5 bar, gap 8, text #8a8f98.
                Item {
                    readonly property real natural: 10 + quoteText.implicitWidth
                    width: blk.width
                    implicitHeight: quoteText.implicitHeight
                    Rectangle { width: 2; height: parent.height; radius: 1; color: C.RoboTheme.dim5 }
                    MdText {
                        id: quoteText
                        x: 10
                        width: parent.width - 10
                        source: blk.modelData.text
                        color: "#8a8f98"
                    }
                }
            }
            Component {
                id: rule
                // hr.md-rule: a 1 px rgba(255,255,255,.3) top border at opacity .3,
                // as wide as the reply.
                Item {
                    readonly property real natural: 0
                    width: blk.width
                    implicitHeight: 1
                    Rectangle { width: parent.width; height: 1; color: Qt.rgba(1, 1, 1, 0.3); opacity: 0.3 }
                }
            }
            Component {
                id: code
                // .md-pre: padding 10, 1px rgba(255,255,255,.08), radius 8, #0d0e12;
                // pre 400 11px mono #c8cdd4 + .md-copy (22, radius 4).
                Rectangle {
                    id: pre
                    property bool done: false
                    readonly property real natural: preText.implicitWidth + 2 + 20 + 8 + 22
                    width: blk.width
                    implicitHeight: Math.max(preText.implicitHeight, 22) + 20 + 2
                    radius: 8
                    color: "#0d0e12"
                    border.width: 1
                    // rgba(255,255,255,.08) over the block's own background (CSS
                    // paints the background under the border; Qt does not).
                    border.color: "#202125"
                    TextEdit {
                        id: preText
                        x: 11
                        y: 11
                        width: parent.width - 22 - 22 - 8
                        readOnly: true
                        selectByMouse: true
                        persistentSelection: true
                        textFormat: TextEdit.PlainText
                        text: blk.modelData.code
                        wrapMode: TextEdit.WrapAtWordBoundaryOrAnywhere
                        color: "#c8cdd4"
                        selectionColor: Qt.rgba(0.38, 0.65, 0.98, 0.35)
                        selectedTextColor: color
                        font.family: C.RoboTheme.mono
                        font.pointSize: C.RoboTheme.px(11)
                        renderType: Text.NativeRendering
                    }
                    Rectangle {
                        x: parent.width - 11 - 22
                        y: 11
                        width: 22; height: 22; radius: 4
                        color: Qt.rgba(1, 1, 1, 0.06)
                        C.Icon {
                            anchors.centerIn: parent
                            size: 11
                            path: pre.done ? C.Robo.lib.ICONS.check : C.Robo.lib.ICONS.copy
                            stroke: pre.done ? 2.2 : 0
                            color: pre.done ? C.RoboTheme.green : (copyMa.containsMouse ? C.RoboTheme.dim : C.RoboTheme.dim3)
                        }
                        MouseArea {
                            id: copyMa
                            /** Port: ChatPanel's selection layer passes clicks to this. */
                            readonly property bool mdCopyButton: true
                            anchors.fill: parent
                            hoverEnabled: true
                            onClicked: {
                                Quickshell.clipboardText = blk.modelData.code;
                                pre.done = true;
                                doneTimer.restart();
                            }
                        }
                        Timer { id: doneTimer; interval: 1500; onTriggered: pre.done = false }
                    }
                }
            }
        }
    }
}
