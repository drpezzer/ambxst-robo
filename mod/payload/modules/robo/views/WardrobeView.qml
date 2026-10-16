pragma ComponentBehavior: Bound

import QtQuick
import qs.modules.robo as C

// views/wardrobe.ts buildWardrobe(): .card > .stack.wardrobe-stack (padding
// 12 16 12 104, gap 10): header (title + grey note), then one 30 px button per
// outfit (gap 5). Hover tries the outfit on the mascot, a click keeps it.
Item {
    id: root
    property bool viewOn: false
    readonly property var lib: C.Robo.lib
    readonly property var misc: lib.Misc
    readonly property int rev: C.Robo.rev
    /** The button under the pointer (wardrobe.ts `hovered`). */
    property string hovered: ""
    readonly property string current: rev >= 0 ? misc.wardrobeCurrent() : "auto"
    readonly property string note: { void rev; return misc.wardrobeNote(hovered || null); }
    /** "auto"'s icon follows the season and its badge's language. */
    readonly property string autoKey: { void rev; return misc.wardrobeIconKey(); }
    function act() { return C.Robo.island ? C.Robo.island.actions : null; }
    // Arabic: `.stack.wardrobe-stack` reads right to left — the title at the right,
    // the note right after it (its margin-left: auto leaves the space on the left),
    // the outfits from the right.
    readonly property bool rtl: rev >= 0 && lib.I18n.isRtl()

    // Port (his ask): the wardrobe of the chat in front (lib/looks.ts): the mascot
    // its outfits and colour, Robo its shape, antenna and colours, Axenide its
    // colour. Changes are that chat's alone.
    readonly property var looks: lib.Looks
    // (lib/mascots.ts: the public build has no Coucou mascot, so no outfit grid.)
    readonly property string mascot: { void rev; return looks.mascotOf(C.Robo.state.settings.mascot); }
    readonly property string conv: { void rev; return looks.frontConv() || ""; }
    readonly property var look: { void rev; return conv ? looks.of(conv) : null; }
    readonly property string agentColor: { void rev; const f = C.Robo.state.focusTask; return f && f.color ? f.color : "#D97757"; }
    readonly property var brand: { void rev; return lib.Robot.brandLook(agentColor); }
    readonly property var roboColors: look && look.robo.colors ? look.robo.colors : null
    function editLook(fn) { if (root.conv) root.looks.edit(root.conv, fn); }
    /** The custom swatch being edited ("coucou", "ambxst", "shell", "trim", "screen"), or "". */
    property string wheelFor: ""
    function setColour(which, hex) {
        root.editLook(l => {
            if (which === "coucou") l.coucou.color = hex;
            else if (which === "ambxst") l.ambxst.color = hex;
            else if (hex === "" && (!l.robo.colors || which === "shell")) l.robo.colors = null;
            else {
                if (hex === "") hex = root.brand[which];
                // A part picked while it wears the brand: its other parts stay as they were.
                const c = l.robo.colors || { shell: root.brand.shell, trim: root.brand.trim, screen: root.brand.screen };
                c[which] = hex;
                l.robo.colors = c;
            }
        });
    }
    function colourOf(which) {
        if (!root.look) return "";
        if (which === "coucou") return root.look.coucou.color;
        if (which === "ambxst") return root.look.ambxst.color;
        // Brand colours read as the agent's swatch ("").
        if (!root.roboColors) return "";
        const v = root.roboColors[which];
        return v && v.toLowerCase() === String(root.brand[which]).toLowerCase() ? "" : v;
    }
    function openWheel(which, row, cx, cy) {
        const p = row.mapToItem(root, cx, cy);
        wheel.x = Math.max(8, Math.min(p.x - wheel.width / 2, root.width - wheel.width - 8));
        wheel.y = Math.max(4, Math.min(p.y - wheel.height / 2, root.height - wheel.height - 4));
        root.wheelFor = which;
    }
    onConvChanged: wheelFor = ""
    onViewOnChanged: if (!viewOn) wheelFor = ""

    // sync(): the island drops the preview when the view closes, so does the hover.
    onRevChanged: if (C.Robo.state.wardrobePreview == null) hovered = ""

    Card {
        anchors.fill: parent

        Column {
            id: stack
            x: 1 + 104
            width: parent.width - 2 - 104 - 16
            anchors.verticalCenter: parent.verticalCenter
            spacing: root.mascot === "robo" ? 6 : 10
            LayoutMirroring.enabled: root.rtl
            LayoutMirroring.childrenInherit: true

            // .wardrobe-head: baseline-aligned title and note (margin-left: auto).
            Item {
                width: stack.width
                height: titleText.implicitHeight
                C.CText {
                    id: titleText
                    anchors.left: parent.left
                    text: { void root.rev; return root.lib.I18n.t("Wardrobe"); }
                    size: 12
                    cssWeight: 600
                    color: C.RoboTheme.ink
                }
                C.CText {
                    id: noteText
                    anchors.right: root.rtl ? undefined : parent.right
                    x: root.rtl ? titleText.x - 6 - width : 0
                    anchors.baseline: titleText.baseline
                    width: Math.min(implicitWidth, parent.width - titleText.implicitWidth - 6)
                    horizontalAlignment: Text.AlignRight
                    text: root.mascot === "coucou" ? root.note : (C.Robo.state.focusTask ? C.Robo.state.focusTask.name : "")
                    size: 11
                    color: C.RoboTheme.dim2
                }
            }

            Flow {
                id: grid
                visible: root.mascot === "coucou" && !root.lib.PUBLIC
                width: stack.width
                spacing: 5
                Repeater {
                    model: root.lib.Wardrobe.OUTFIT_SELECTIONS
                    delegate: Rectangle {
                        id: item
                        required property string modelData
                        readonly property string sel: modelData
                        readonly property bool hovering: ma.containsMouse
                        width: 30
                        height: 30
                        radius: 7
                        color: ma.containsMouse ? Qt.rgba(1, 1, 1, 0.1) : Qt.rgba(1, 1, 1, 0.06)
                        border.width: 1
                        border.color: root.current === sel ? Qt.rgba(1, 1, 1, 0.4) : Qt.rgba(1, 1, 1, 0.08)
                        Behavior on color { ColorAnimation { duration: 120; easing.type: Easing.BezierSpline; easing.bezierCurve: C.RoboTheme.easeOut } }
                        Behavior on border.color { ColorAnimation { duration: 120; easing.type: Easing.BezierSpline; easing.bezierCurve: C.RoboTheme.easeOut } }

                        Canvas {
                            id: icon
                            property var wrap: null
                            x: 1
                            y: 1
                            width: 28
                            height: 28
                            property string key: item.sel === "auto" ? root.autoKey : "fixed"
                            onKeyChanged: requestPaint()
                            onPaint: {
                                const ctx = getContext("2d");
                                if (!wrap) wrap = new C.Robo.lib.Misc.TextCtx(ctx, icon);
                                wrap.setTransform(1, 0, 0, 1, 0, 0);
                                wrap.clearRect(0, 0, width, height);
                                root.misc.drawWardrobeButton(wrap, item.sel);
                            }
                        }

                        MouseArea {
                            id: ma
                            anchors.fill: parent
                            hoverEnabled: true
                            onContainsMouseChanged: {
                                const a = root.act();
                                if (containsMouse) {
                                    root.hovered = item.sel;
                                    if (a) a.previewOutfit(root.misc.wardrobePreviewFor(item.sel));
                                } else if (root.hovered === item.sel) {
                                    root.hovered = "";
                                    if (a) a.previewOutfit(null);
                                }
                            }
                            onClicked: { const a = root.act(); if (a) a.chooseOutfit(item.sel); }
                        }
                    }
                }
            }

            // The mascot's / Axenide's colour.
            Row {
                visible: root.mascot !== "robo"
                spacing: 10
                C.CText { width: 44; anchors.verticalCenter: parent.verticalCenter; text: "Colour"; size: 11; color: C.RoboTheme.dim2 }
                C.SwatchRow {
                    id: bodyRow
                    readonly property string which: root.mascot === "ambxst" ? "ambxst" : "coucou"
                    colors: root.looks.BODY.slice(1)
                    agentColor: root.agentColor
                    current: root.colourOf(which)
                    onPicked: c => root.setColour(which, c)
                    onCustom: (cx, cy) => root.openWheel(which, bodyRow, cx, cy)
                }
            }

            // Robo: shape and antenna, then his colours.
            Row {
                visible: root.mascot === "robo"
                spacing: 6
                Repeater {
                    model: ["rectangle", "square", "circle", "hexagon"]
                    Rectangle {
                        required property string modelData
                        readonly property bool on: root.look ? root.look.robo.shape === modelData : false
                        width: 26; height: 26; radius: 7
                        color: shapeMa.containsMouse ? Qt.rgba(1, 1, 1, 0.1) : Qt.rgba(1, 1, 1, 0.05)
                        border.width: 1
                        border.color: on ? Qt.rgba(1, 1, 1, 0.4) : Qt.rgba(1, 1, 1, 0.08)
                        C.RobotPreview {
                            anchors.centerIn: parent
                            width: 26; height: 26
                            box: 16
                            look: root.look ? Object.assign({}, root.lib.Looks.roboLook(root.conv, root.agentColor), { shape: parent.modelData }) : null
                        }
                        MouseArea { id: shapeMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.editLook(l => { l.robo.shape = parent.modelData; }) }
                    }
                }
                Item { width: 10; height: 1 }
                Rectangle {
                    readonly property bool on: root.look ? root.look.robo.antenna : true
                    anchors.verticalCenter: parent.verticalCenter
                    width: antLabel.implicitWidth + 18; height: 22; radius: 7
                    color: on ? Qt.rgba(1, 1, 1, 0.14) : (antMa.containsMouse ? Qt.rgba(1, 1, 1, 0.08) : Qt.rgba(1, 1, 1, 0.04))
                    C.CText { id: antLabel; anchors.centerIn: parent; text: parent.on ? "Antenna on" : "Antenna off"; size: 11; color: C.RoboTheme.ink }
                    MouseArea { id: antMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.editLook(l => { l.robo.antenna = !l.robo.antenna; }) }
                }
            }
            Row {
                visible: root.mascot === "robo"
                spacing: 10
                C.CText { width: 44; anchors.verticalCenter: parent.verticalCenter; text: "Shell"; size: 11; color: C.RoboTheme.dim2 }
                C.SwatchRow {
                    id: shellRow
                    size: 18
                    spacing: 7
                    colors: root.looks.SHELL
                    agentColor: root.brand.shell
                    current: root.colourOf("shell")
                    onPicked: c => root.setColour("shell", c)
                    onCustom: (cx, cy) => root.openWheel("shell", shellRow, cx, cy)
                }
            }
            Row {
                visible: root.mascot === "robo"
                spacing: 10
                C.CText { width: 44; anchors.verticalCenter: parent.verticalCenter; text: "Trim"; size: 11; color: C.RoboTheme.dim2 }
                C.SwatchRow {
                    id: trimRow
                    size: 18
                    spacing: 7
                    colors: root.looks.TRIM
                    agentColor: root.brand.trim
                    current: root.colourOf("trim")
                    onPicked: c => root.setColour("trim", c)
                    onCustom: (cx, cy) => root.openWheel("trim", trimRow, cx, cy)
                }
                Item { width: 8; height: 1 }
                C.CText { anchors.verticalCenter: parent.verticalCenter; text: "Screen"; size: 11; color: C.RoboTheme.dim2 }
                C.SwatchRow {
                    id: screenRow
                    size: 18
                    spacing: 7
                    colors: root.looks.SCREEN
                    agentColor: root.brand.screen
                    current: root.colourOf("screen")
                    onPicked: c => root.setColour("screen", c)
                    onCustom: (cx, cy) => root.openWheel("screen", screenRow, cx, cy)
                }
            }
        }
    }

    // A press outside the wheel closes it.
    MouseArea {
        anchors.fill: parent
        visible: root.wheelFor !== ""
        onPressed: root.wheelFor = ""
    }
    C.ColorWheel {
        id: wheel
        // (Side by side and smaller: the card is short, the island clips it.)
        wide: true
        ringOuter: Math.min(42, (root.height - 24) / 2 - 2)
        visible: root.wheelFor !== ""
        value: { const v = root.colourOf(root.wheelFor); return v || root.agentColor; }
        onPicked: c => root.setColour(root.wheelFor, c)
        onClosed: root.wheelFor = ""
    }
}
