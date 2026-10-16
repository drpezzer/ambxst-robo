import QtQuick
import qs.modules.robo as C

// Port only (his ask): the Style tab — the theme colours switch (moved here
// from General), the mascot (the Coucou mascot, Robo or Axenide), and, for Robo, how the island's
// head looks: shape, antenna, speed, and colours (the operator AI's brand
// colours unless custom ones are switched on). Minis pick their own shape and
// antenna once, at random, and keep them.
SSection {
    id: sec
    property var page
    readonly property var xL: page.xL
    readonly property var xG: page.fresh(xL.GENERAL_TEXT)
    readonly property var s: page.rev >= 0 && page.settings ? Object.assign({}, page.settings) : ({})
    /** Port: the mascot shown (lib/mascots.ts: no Coucou mascot in the public build, Axenide by default). */
    readonly property string mascot: page.lib.Looks.mascotOf(s.mascot)
    readonly property bool robo: mascot === "robo"
    readonly property var rp: Object.assign({ shape: "rectangle", antenna: true, speed: 1, customColors: false,
        shell: "#2b49a3", trim: "#93a6c8", screen: "#e8f2ff" }, s.robot || {})
    /** The look the island's head has now (brand colours: Claude's orange shown here). */
    readonly property var look: {
        const lib = page.lib;
        const colors = rp.customColors ? { shell: rp.shell, trim: rp.trim, screen: rp.screen } : lib.Robot.brandLook("#D97757");
        return Object.assign({ shape: rp.shape, antenna: rp.antenna, speed: rp.speed }, colors);
    }
    title: "Style"

    function setMascot(m) {
        if (sec.mascot === m && sec.s.mascot === m) return;
        sec.page.settings.mascot = m;
        sec.page.save();
    }
    // Port (his ask): these are the DEFAULTS of new chats (lib/looks.ts);
    // each can be drawn at random per new chat instead.
    readonly property var lr: s.lookRandom || ({})
    function setRandom(key, on) {
        const r = Object.assign({}, sec.lr);
        r[key] = on;
        sec.page.settings.lookRandom = r;
        sec.page.save();
    }
    function setKey(key, value) {
        sec.page.settings[key] = value;
        sec.page.save();
    }
    /** The custom swatch the wheel edits ("coucouColor", "ambxstColor", "shell", "trim", "screen"), or "". */
    property string wheelFor: ""
    function wheelValue(which) {
        if (which === "coucouColor" || which === "ambxstColor") return sec.s[which] || "#D97757";
        return sec.rp[which] || "#D97757";
    }
    function setColour(which, hex) {
        if (which === "coucouColor" || which === "ambxstColor") sec.setKey(which, hex);
        else sec.setRobot(which, hex);
    }
    function openWheel(which, row, cx, cy) {
        const p = row.mapToItem(sec, cx, cy);
        wheel.x = Math.max(0, Math.min(p.x + 18, sec.width - wheel.width));
        wheel.y = Math.max(0, p.y - wheel.height / 2);
        sec.wheelFor = which;
    }
    function setRobot(key, value) {
        const r = Object.assign({}, sec.rp);
        r[key] = value;
        sec.page.settings.robot = r;
        sec.page.save();
    }

    FlexRow {
        width: sec.innerWidth
        SLabel { text: sec.xG.matugenColors }
        SSwitch { on: !!sec.s.processColorsMatugen; onToggled: next => { sec.page.settings.processColorsMatugen = next; sec.page.save(); } }
    }
    SHint { width: sec.innerWidth; text: sec.xG.matugenColorsHint }

    // .subhead: 600 11px, --dim-2, uppercase.
    SText { text: "MASCOT"; size: 11; cssWeight: 600; color: SettingsTheme.dim2 }
    Row {
        spacing: 10
        // One card per mascot; the chosen one is ringed.
        Rectangle {
            // (Not in the public build.)
            visible: !sec.page.lib.PUBLIC
            width: 112; height: 112; radius: 14
            color: coucouMa.containsMouse ? Qt.rgba(1, 1, 1, 0.06) : Qt.rgba(1, 1, 1, 0.04)
            readonly property bool on: sec.mascot === "coucou"
            border.width: on ? 2 : 1
            border.color: on ? "#D97757" : SettingsTheme.cardBorder
            C.MiniBot {
                anchors.horizontalCenter: parent.horizontalCenter
                y: 22
                bodySize: 40
                coucouOnly: true
                task: ({ id: "mascot-preview-coucou", name: sec.page.lib.COUCOU_MASCOT, color: sec.s.coucouColor || "#D97757", state: "idle", steps: [], stepIndex: 0 })
            }
            SText { anchors.horizontalCenter: parent.horizontalCenter; y: 112 - 28; text: sec.page.lib.COUCOU_MASCOT; size: 12; cssWeight: 600; wrapMode: Text.NoWrap }
            MouseArea { id: coucouMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: sec.setMascot("coucou") }
        }
        Rectangle {
            width: 112; height: 112; radius: 14
            color: roboMa.containsMouse ? Qt.rgba(1, 1, 1, 0.06) : Qt.rgba(1, 1, 1, 0.04)
            border.width: sec.robo ? 2 : 1
            border.color: sec.robo ? "#D97757" : SettingsTheme.cardBorder
            C.RobotPreview {
                anchors.horizontalCenter: parent.horizontalCenter
                y: 8
                width: 96; height: 78
                box: 52
                look: sec.look
            }
            SText { anchors.horizontalCenter: parent.horizontalCenter; y: 112 - 28; text: "Robo"; size: 12; cssWeight: 600; wrapMode: Text.NoWrap }
            MouseArea { id: roboMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: sec.setMascot("robo") }
        }
        // Axenide: the Ambxst logo, in the Coucou mascot's style (lib/ambxst).
        Rectangle {
            readonly property bool on: sec.mascot === "ambxst"
            width: 112; height: 112; radius: 14
            color: ambMa.containsMouse ? Qt.rgba(1, 1, 1, 0.06) : Qt.rgba(1, 1, 1, 0.04)
            border.width: on ? 2 : 1
            border.color: on ? "#D97757" : SettingsTheme.cardBorder
            C.MiniBot {
                anchors.horizontalCenter: parent.horizontalCenter
                y: 22
                bodySize: 40
                mascot: "ambxst"
                task: ({ id: "mascot-preview-ambxst", name: "Axenide", color: sec.s.ambxstColor || "#D97757", state: "idle", steps: [], stepIndex: 0 })
            }
            SText { anchors.horizontalCenter: parent.horizontalCenter; y: 112 - 28; text: "Axenide"; size: 12; cssWeight: 600; wrapMode: Text.NoWrap }
            MouseArea { id: ambMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: sec.setMascot("ambxst") }
        }
    }

    // ── The mascot's defaults: colour and outfit ──
    Column {
        visible: sec.mascot === "coucou" && !sec.page.lib.PUBLIC
        width: sec.innerWidth
        spacing: 12
        SText { text: "COLOUR"; size: 11; cssWeight: 600; color: SettingsTheme.dim2 }
        C.SwatchRow {
            id: coucouRow
            colors: sec.page.lib.Looks.BODY.slice(1)
            agentColor: "#D97757"
            current: sec.s.coucouColor || ""
            ring: SettingsTheme.ink
            onPicked: c => sec.setKey("coucouColor", c)
            onCustom: (cx, cy) => sec.openWheel("coucouColor", coucouRow, cx, cy)
        }
        RandomRow { key: "coucouColor" }
        SText { text: "OUTFIT"; size: 11; cssWeight: 600; color: SettingsTheme.dim2 }
        Flow {
            width: sec.innerWidth
            spacing: 5
            Repeater {
                model: sec.page.lib.Wardrobe.OUTFIT_SELECTIONS
                Rectangle {
                    id: ob
                    required property string modelData
                    readonly property bool on: (sec.s.mascotOutfit || "auto") === modelData
                    width: 30; height: 30; radius: 7
                    color: obMa.containsMouse ? Qt.rgba(1, 1, 1, 0.1) : Qt.rgba(1, 1, 1, 0.06)
                    border.width: 1
                    border.color: on ? Qt.rgba(1, 1, 1, 0.4) : Qt.rgba(1, 1, 1, 0.08)
                    Canvas {
                        id: obIcon
                        property var wrap: null
                        x: 1; y: 1; width: 28; height: 28
                        onPaint: {
                            const ctx = getContext("2d");
                            if (!wrap) wrap = new C.Robo.lib.Misc.TextCtx(ctx, obIcon);
                            wrap.setTransform(1, 0, 0, 1, 0, 0);
                            wrap.clearRect(0, 0, width, height);
                            C.Robo.lib.Misc.drawWardrobeButton(wrap, ob.modelData);
                        }
                    }
                    MouseArea { id: obMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: sec.setKey("mascotOutfit", ob.modelData) }
                }
            }
        }
        RandomRow { key: "mascotOutfit" }
    }

    // ── Axenide's default colour ──
    Column {
        visible: sec.mascot === "ambxst"
        width: sec.innerWidth
        spacing: 12
        SText { text: "COLOUR"; size: 11; cssWeight: 600; color: SettingsTheme.dim2 }
        C.SwatchRow {
            id: ambRow
            colors: sec.page.lib.Looks.BODY.slice(1)
            agentColor: "#D97757"
            current: sec.s.ambxstColor || ""
            ring: SettingsTheme.ink
            onPicked: c => sec.setKey("ambxstColor", c)
            onCustom: (cx, cy) => sec.openWheel("ambxstColor", ambRow, cx, cy)
        }
        RandomRow { key: "ambxstColor" }
    }

    // ── Robo's customiser (the robot-heads playground's controls) ──
    Column {
        visible: sec.robo
        width: sec.innerWidth
        spacing: 12

        SText { text: "SHAPE"; size: 11; cssWeight: 600; color: SettingsTheme.dim2 }
        Row {
            spacing: 8
            Repeater {
                model: ["rectangle", "square", "circle", "hexagon"]
                Rectangle {
                    required property string modelData
                    readonly property bool on: sec.rp.shape === modelData
                    width: 76; height: 76; radius: 12
                    color: shapeMa.containsMouse ? Qt.rgba(1, 1, 1, 0.06) : Qt.rgba(1, 1, 1, 0.03)
                    border.width: on ? 2 : 1
                    border.color: on ? "#D97757" : SettingsTheme.cardBorder
                    C.RobotPreview {
                        anchors.centerIn: parent
                        width: 72; height: 72
                        box: 46
                        look: Object.assign({}, sec.look, { shape: parent.modelData })
                    }
                    MouseArea { id: shapeMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: sec.setRobot("shape", parent.modelData) }
                }
            }
        }
        RandomRow { key: "roboShape" }

        SText { text: "ANTENNA"; size: 11; cssWeight: 600; color: SettingsTheme.dim2 }
        Segmented {
            options: [{ label: "On", value: true }, { label: "Off", value: false }]
            current: sec.rp.antenna
            onPicked: v => sec.setRobot("antenna", v)
        }
        RandomRow { key: "roboAntenna" }

        SText { text: "ANIMATION SPEED"; size: 11; cssWeight: 600; color: SettingsTheme.dim2 }
        Segmented {
            options: [{ label: "0.5×", value: 0.5 }, { label: "1×", value: 1 }, { label: "1.5×", value: 1.5 }, { label: "2×", value: 2 }]
            current: sec.rp.speed
            onPicked: v => sec.setRobot("speed", v)
        }

        FlexRow {
            width: sec.innerWidth
            SLabel { text: "Custom colours" }
            SSwitch { on: !!sec.rp.customColors; onToggled: next => sec.setRobot("customColors", next) }
        }
        SHint {
            width: sec.innerWidth
            text: sec.rp.customColors ? "Your colours, whatever the AI at work."
                : "Robo wears the brand colours of the AI at work: Claude's orange, GitHub's red…"
        }
        Column {
            visible: !!sec.rp.customColors
            width: sec.innerWidth
            spacing: 10
            SText { text: "Shell"; size: 12; color: SettingsTheme.dim }
            C.SwatchRow {
                id: shellRow
                colors: ["#2b49a3", "#c8382f", "#e0782a", "#e3b22b", "#2f8f57", "#1f8a8a", "#6c4bc4", "#d9558c", "#3a3d44", "#e6e8ec"]
                current: sec.rp.shell
                ring: SettingsTheme.ink
                onPicked: c => sec.setRobot("shell", c)
                onCustom: (cx, cy) => sec.openWheel("shell", shellRow, cx, cy)
            }
            SText { text: "Trim"; size: 12; color: SettingsTheme.dim }
            C.SwatchRow {
                id: trimRow
                colors: ["#93a6c8", "#c9ccd2", "#c9a24e", "#c27a52", "#2b2d31"]
                current: sec.rp.trim
                ring: SettingsTheme.ink
                onPicked: c => sec.setRobot("trim", c)
                onCustom: (cx, cy) => sec.openWheel("trim", trimRow, cx, cy)
            }
            SText { text: "Screen"; size: 12; color: SettingsTheme.dim }
            C.SwatchRow {
                id: screenRow
                colors: ["#e8f2ff", "#7fe7ff", "#8cff9e", "#ffc46b", "#ff8fc8"]
                current: sec.rp.screen
                ring: SettingsTheme.ink
                onPicked: c => sec.setRobot("screen", c)
                onCustom: (cx, cy) => sec.openWheel("screen", screenRow, cx, cy)
            }
        }
    }

    FlexRow {
        visible: sec.robo
        width: sec.innerWidth
        SLabel { text: "Random colours for each new chat" }
        SSwitch { on: !!sec.lr.roboColors; onToggled: next => sec.setRandom("roboColors", next) }
    }

    // A switch: this customisation drawn at random for each new chat.
    component RandomRow: FlexRow {
        id: rr
        property string key: ""
        width: sec.innerWidth
        SLabel { text: "Random for each new chat" }
        SSwitch { on: !!sec.lr[rr.key]; onToggled: next => sec.setRandom(rr.key, next) }
    }

    // The colour wheel of a custom swatch; a press outside closes it.
    MouseArea {
        parent: sec
        anchors.fill: parent
        z: 50
        visible: sec.wheelFor !== ""
        onPressed: sec.wheelFor = ""
    }
    C.ColorWheel {
        id: wheel
        parent: sec
        z: 51
        visible: sec.wheelFor !== ""
        value: sec.wheelFor ? sec.wheelValue(sec.wheelFor) : "#D97757"
        onPicked: c => sec.setColour(sec.wheelFor, c)
        onClosed: sec.wheelFor = ""
    }

    // A row of choices, one lit (the playground's segmented control).
    component Segmented: Row {
        id: seg
        property var options: []
        property var current
        signal picked(var value)
        spacing: 4
        Repeater {
            model: seg.options
            Rectangle {
                required property var modelData
                readonly property bool on: seg.current === modelData.value
                width: Math.max(56, segLabel.implicitWidth + 24)
                height: 28
                radius: 8
                color: on ? Qt.rgba(1, 1, 1, 0.14) : (segMa.containsMouse ? Qt.rgba(1, 1, 1, 0.07) : Qt.rgba(1, 1, 1, 0.03))
                SText { id: segLabel; anchors.centerIn: parent; text: parent.modelData.label; size: 12; cssWeight: parent.on ? 600 : 400; wrapMode: Text.NoWrap; color: parent.on ? SettingsTheme.ink : SettingsTheme.dim }
                MouseArea { id: segMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: seg.picked(parent.modelData.value) }
            }
        }
    }

    // A labelled row of colour swatches, the chosen one ringed.
    component Swatches: Column {
        id: sw
        property string title: ""
        property var colors: []
        property string current: ""
        signal picked(string color)
        spacing: 6
        SText { text: sw.title; size: 12; color: SettingsTheme.dim }
        Row {
            spacing: 8
            Repeater {
                model: sw.colors
                Rectangle {
                    required property string modelData
                    readonly property bool on: sw.current.toLowerCase() === modelData.toLowerCase()
                    width: 24; height: 24; radius: 12
                    color: "transparent"
                    border.width: on ? 2 : 0
                    border.color: SettingsTheme.ink
                    Rectangle { anchors.centerIn: parent; width: 18; height: 18; radius: 9; color: parent.modelData }
                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: sw.picked(parent.modelData) }
                }
            }
        }
    }
}
