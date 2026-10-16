pragma ComponentBehavior: Bound

import QtQuick
import qs.modules.robo as C

// views/integrations.ts renderIntegrationCard() + views/github.ts: the card an
// integration pill shows in the overview's left card — idle, Vercel (list +
// detail), Resend, Stripe, Notion, Cal.com, n8n (+ detail), GitHub (stars, or
// the pulse card, its lists and the contribution grid). What each card shows
// comes from lib/views/integrations.ts (C.Robo.lib.IntCards).
// style.css .int-*, .gh-*.
Item {
    id: root
    property var task: null
    property bool detailOpen: false
    readonly property var lib: C.Robo.lib
    readonly property var ic: lib.IntCards
    readonly property int rev: C.Robo.rev
    readonly property var st: C.Robo.state
    readonly property var info: rev >= 0 && task ? st.integrations[task.id] : undefined
    readonly property var def: task ? lib.Pills.pillDefinition(task.id) : null
    readonly property string kind: rev >= 0 && task ? ic.cardKind(task, detailOpen) : ""

    // A new pill in front closes the detail (views.ts sync: lastFocus).
    property string lastFocus: ""
    onTaskChanged: {
        const id = task ? task.id : "";
        if (id !== lastFocus) {
            lastFocus = id;
            detailOpen = false;
        }
    }

    // Arabic: `html[data-dir=rtl] .int-card { direction: rtl }` — the card's
    // box keeps its padding, its rows read right to left (cardLoader mirrors;
    // IntFlexRow follows; items a Column would put on the left anchor left,
    // which mirrors). The contribution grid stays left to right.
    readonly property bool rtl: rev >= 0 && lib.I18n.isRtl()
    function hexA(hex, a) { const c = Qt.color(hex); return Qt.rgba(c.r, c.g, c.b, a); }
    function t(s, v) { void root.rev; return root.lib.I18n.t(s, v); }
    function openDetail() { detailOpen = true; st.notify(); }
    function closeDetail() { detailOpen = false; st.notify(); }

    // ── Ctrl+↓ Ctrl+↑ Ctrl+O on the GitHub list (cardItemCount / cardSelection) ──
    readonly property var listRows: kind === "githubDetail" && cardLoader.item && cardLoader.item.rows ? cardLoader.item.rows : []
    readonly property var selection: rev >= 0 ? st.cardSelection : null
    onListRowsChanged: syncSelection()
    Component.onCompleted: syncSelection()
    Component.onDestruction: if (st) st.cardItemCount = 0
    function syncSelection() {
        st.cardItemCount = listRows.length;
        if (st.cardSelection != null && st.cardSelection >= listRows.length) st.cardSelection = null;
    }
    function command(c) {
        // What a click on the card's buttons does, for scenarios (tools/sc/int-*.js):
        // "openDetail" (⋯ / the n8n pill), "closeDetail" (‹), "section:<myPRs|toReview|mainCI|activity>".
        if (c === "openDetail") return openDetail();
        if (c === "closeDetail") return closeDetail();
        if (typeof c === "string" && c.indexOf("section:") === 0) return ic.showSection(c.slice(8), openDetail);
        if (c !== "openSelection") return;
        if (st.cardSelection == null) return;
        const r = listRows[st.cardSelection];
        if (r) r.open();
    }

    Loader {
        id: cardLoader
        // The card's 1 px border, then .int-card's padding (10 12 0 108; 8 in a detail).
        x: 1 + 108
        y: 1 + (root.kind === "vercelDetail" || root.kind === "n8nDetail" ? 8 : 10)
        width: parent.width - 2 - 108 - 12
        LayoutMirroring.enabled: root.rtl
        LayoutMirroring.childrenInherit: true
        sourceComponent: ({
            idle: idleCard, vercel: vercelCard, vercelDetail: vercelDetailCard, resend: resendCard,
            github: githubCard, githubPulse: pulseCard, githubDetail: ghDetailCard, stripe: stripeCard,
            notion: notionCard, calcom: calcomCard, n8n: n8nCard, n8nDetail: n8nDetailCard
        })[root.kind] || null
    }

    // ── Shared pieces ─────────────────────────────────────────────────────────

    // .int-head: dot 7, name (600 12), kind (11 dim-2), extra; gap 6, padding-right 24.
    component IntHead: IntFlexRow {
        id: head
        property string color: "white"
        property string name: ""
        property string sub: ""
        width: parent ? parent.width - 24 : 0
        spacing: 6
        Dot { size: 7; color: head.color }
        C.CText { text: head.name; size: 12; cssWeight: 600; elide: Text.ElideNone }
        C.CText { visible: head.sub !== ""; text: head.sub; size: 11; color: C.RoboTheme.dim2; elide: Text.ElideNone }
    }

    // .int-row: dot + cells, gap 5, padding 3 8, radius 5; the first row tinted.
    component IntRow: Rectangle {
        id: r
        property string accent: "#22C55E"
        property bool first: false
        property real dotSize: 5
        default property alias cells: lay.data
        width: parent ? parent.width : 0
        height: lay.height + 6
        radius: 5
        color: first ? root.hexA(accent, 0x14 / 255) : "transparent"
        IntFlexRow {
            id: lay
            x: 8
            y: 3
            width: parent.width - 16
            spacing: 5
            Dot { size: r.dotSize; color: r.accent }
        }
    }

    // .int-name: 500 11 #9398a1 (first row #c5c8cd), gives way with an ellipsis.
    component IntName: BidiText {
        property bool first: false
        property bool shrink: true
        size: 11
        cssWeight: 500
        color: first ? "#c5c8cd" : "#9398a1"
    }
    component IntAgo: C.CText { size: 10; color: C.RoboTheme.dim3; elide: Text.ElideNone }

    // .int-detail-head: back (28×28, chevron 10), dot 6, name, badge right; gap 7.
    component DetailHead: IntFlexRow {
        id: dh
        property string accent: "#22C55E"
        property string name: ""
        property string badge: ""
        width: parent ? parent.width : 0
        spacing: 7
        Item {
            implicitWidth: 28; implicitHeight: 28
            C.Icon { anchors.centerIn: parent; path: root.lib.ICONS.chevronLeft; size: 10; stroke: 2.4; color: C.RoboTheme.dim3 }
            MouseArea { anchors.fill: parent; onClicked: root.closeDetail() }
        }
        Dot { size: 6; color: dh.accent }
        BidiText { property bool shrink: true; raw: dh.name; size: 11; cssWeight: 600 }
        Rectangle {
            property bool push: true
            implicitWidth: bt.implicitWidth + 12
            implicitHeight: bt.implicitHeight + 4
            radius: height / 2
            color: root.hexA(dh.accent, 0x24 / 255)
            C.CText { id: bt; anchors.centerIn: parent; text: dh.badge; size: 10; cssWeight: 500; color: dh.accent; elide: Text.ElideNone }
        }
    }

    // .int-stat: icon box 14 (svg 10), label (11 dim-3), value right (600 12 #c5c8cd, tabular); gap 7.
    component StatRow: IntFlexRow {
        id: sr
        property string icon: ""
        property real stroke: 0
        property bool evenOdd: false
        property string color: "white"
        property string label: ""
        property string value: ""
        property bool clickable: false
        signal clicked()
        width: parent ? parent.width : 0
        spacing: 7
        Item {
            implicitWidth: 14; implicitHeight: 10
            C.Icon { anchors.centerIn: parent; path: sr.icon; size: 10; stroke: sr.stroke; evenOdd: sr.evenOdd; color: sr.color }
        }
        C.CText { text: sr.label; size: 11; color: C.RoboTheme.dim3; elide: Text.ElideNone }
        C.CText {
            property bool push: true
            text: sr.value; size: 12; cssWeight: 600; color: "#c5c8cd"; elide: Text.ElideNone
            font.features: { "tnum": 1 }
        }
        TapHandler { enabled: sr.clickable; onTapped: sr.clicked() }
    }

    // ── Idle ──────────────────────────────────────────────────────────────────

    Component {
        id: idleCard
        Column {
            id: idc
            readonly property var status: root.rev >= 0 && root.task ? C.RoboViews.idleStatus(root.task.id, root.info, root.st.settings.model) : ({ label: "", color: "#000" })
            IntHead {
                color: root.task ? root.task.color : "white"
                name: root.task ? root.task.name : ""
                sub: root.t(root.def && root.def.subtitle ? root.def.subtitle : "Integration")
            }
            // .int-status: padding-top 4, gap 5
            Item { width: 1; height: 4 }
            Row {
                anchors.left: parent.left
                spacing: 5
                Dot { size: 5; color: idc.status.color; anchors.verticalCenter: parent.verticalCenter }
                BidiText { raw: idc.status.label; size: 11; color: C.RoboTheme.dim3 }
            }
            // .int-actions: padding-top 6, gap 8
            Item { width: 1; height: 6 }
            Row {
                anchors.left: parent.left
                spacing: 8
                Repeater {
                    model: root.rev >= 0 && root.task ? C.RoboViews.idleActions(root.task, root.info) : []
                    delegate: LinkBtn {
                        required property var modelData
                        text: modelData.label
                        color: modelData.color
                        onClicked: modelData.run()
                    }
                }
                // Port: a fresh Claude Code card (no session yet) says how it fills.
                C.CText {
                    visible: root.rev >= 0 && !!root.task && root.task.id === "integration_claude" && !root.task.sessionId
                    text: "Start talking to see Claude's work here"
                    size: 11
                    color: C.RoboTheme.dim3
                }
            }
        }
    }

    // ── Vercel ────────────────────────────────────────────────────────────────

    Component {
        id: vercelCard
        Column {
            IntHead { color: "#7C5CFF"; name: "Vercel"; sub: root.t("Deployments") }
            // .int-rows: gap 3, padding-top 5
            Item { width: 1; height: 5 }
            Column {
                width: parent.width
                spacing: 3
                Repeater {
                    model: root.rev >= 0 ? root.ic.vercelRows() : []
                    delegate: IntRow {
                        id: vr
                        required property var modelData
                        required property int index
                        accent: modelData.accent
                        first: index === 0
                        IntName { raw: vr.modelData.name; first: vr.first }
                        IntAgo { text: vr.modelData.ago }
                        // .int-more: 18×18, ellipsis 8, opens the detail.
                        Item {
                            visible: vr.first
                            implicitWidth: 18; implicitHeight: 18
                            C.Icon { anchors.centerIn: parent; path: root.lib.ICONS.ellipsis; size: 8; color: C.RoboTheme.dim3 }
                            MouseArea { anchors.fill: parent; onClicked: root.openDetail() }
                        }
                    }
                }
            }
        }
    }

    Component {
        id: vercelDetailCard
        Column {
            id: vd
            readonly property var d: root.rev >= 0 ? root.ic.vercelDetail() : ({})
            DetailHead { accent: vd.d.accent; name: vd.d.name; badge: vd.d.status }
            // .int-detail-body: gap 4, padding-top 8
            Item { width: 1; height: 8 }
            Column {
                width: parent.width
                spacing: 4
                BidiText {
                    visible: raw !== ""
                    width: parent.width
                    raw: vd.d.commit
                    size: 10.5; color: "#c5c8cd"
                    wrapMode: Text.Wrap; maximumLineCount: 2
                    // line-height: normal for 10.5 px (Qt's own leading is a px taller).
                    lineHeightMode: Text.FixedHeight; lineHeight: 12.5
                }
                Row {
                    anchors.left: parent.left
                    spacing: 8
                    C.CText { visible: text !== ""; text: vd.d.branch; size: 10; color: C.RoboTheme.dim3 }
                    C.CText { text: vd.d.ago; size: 10; color: C.RoboTheme.dim3 }
                }
                C.CText {
                    visible: text !== ""
                    anchors.left: parent.left
                    width: Math.min(implicitWidth, parent.width)
                    text: vd.d.url
                    size: 10
                    font.family: C.RoboTheme.mono
                    color: C.RoboViews.cssHex("#7c5cffd9")
                    MouseArea { anchors.fill: parent; onClicked: vd.d.open() }
                }
            }
        }
    }

    // ── Resend ────────────────────────────────────────────────────────────────

    Component {
        id: resendCard
        Column {
            id: rc
            readonly property var d: root.rev >= 0 ? root.ic.resend() : ({ rows: [] })
            IntHead {
                color: "#22C55E"; name: "Resend"; sub: root.t("Emails")
                // .int-total: margin-left 2, gap 4, pulse 4 + count (500 11 #c5c8cd)
                Row {
                    visible: rc.d.hasTotal
                    spacing: 4
                    leftPadding: 2
                    Rectangle {
                        id: pulseDot
                        width: 4; height: 4; radius: 2
                        anchors.verticalCenter: parent.verticalCenter
                        color: C.RoboTheme.green
                        opacity: 0.2
                        // @keyframes pulse: 0.2 → 1 → 0.2 over 1.8 s, ease-in-out.
                        // (Only while it shows: it made the notch redraw every vsync.)
                        SequentialAnimation on opacity {
                            running: pulseDot.visible && rc.d.hasTotal
                            loops: Animation.Infinite
                            NumberAnimation { from: 0.2; to: 1; duration: 900; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.42, 0, 0.58, 1, 1, 1] }
                            NumberAnimation { from: 1; to: 0.2; duration: 900; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.42, 0, 0.58, 1, 1, 1] }
                        }
                    }
                    C.CText { text: rc.d.total; size: 11; cssWeight: 500; color: "#c5c8cd"; elide: Text.ElideNone; font.features: { "tnum": 1 } }
                }
            }
            Item { width: 1; height: 5 }
            Column {
                width: parent.width
                spacing: 3
                Repeater {
                    model: rc.d.rows
                    delegate: IntRow {
                        id: rr
                        required property var modelData
                        required property int index
                        accent: modelData.accent
                        first: index === 0
                        IntName { raw: rr.modelData.name; first: rr.first }
                        IntAgo { text: rr.modelData.ago }
                        // .int-sub: 10 #4d5159, gives way too.
                        BidiText {
                            property bool shrink: true
                            visible: rr.modelData.sub !== ""
                            raw: rr.modelData.sub
                            size: 10; color: "#4d5159"
                        }
                    }
                }
            }
        }
    }

    // ── GitHub (stars + repositories) ─────────────────────────────────────────

    Component {
        id: githubCard
        Column {
            id: ghs
            readonly property var d: root.rev >= 0 ? root.ic.githubStats() : ({ stats: [] })
            IntHead { color: "#F4505E"; name: "GitHub"; sub: root.t("Overview") }
            // .int-stats: gap 5, padding-top 8, padding-right 12
            Item { width: 1; height: 8 }
            Column {
                width: parent.width - 12
                spacing: 5
                Repeater {
                    model: ghs.d.stats
                    delegate: StatRow {
                        required property var modelData
                        icon: modelData.icon; color: modelData.color; label: modelData.label; value: modelData.value
                    }
                }
            }
        }
    }

    // ── GitHub pulse ──────────────────────────────────────────────────────────

    Component {
        id: pulseCard
        Column {
            id: pc
            readonly property var d: root.rev >= 0 ? root.ic.githubPulse() : ({ stats: [], mini: [] })
            IntHead {
                color: "#F4505E"; name: pc.d.title; sub: pc.d.spark ? "" : pc.d.overview
                // .gh-spark: ★ count + the last week, gap 4; opens the grid.
                Row {
                    visible: pc.d.spark
                    spacing: 4
                    C.CText { visible: text !== ""; text: pc.d.stars; size: 11; color: C.RoboTheme.dim2; elide: Text.ElideNone; anchors.verticalCenter: parent.verticalCenter }
                    // .gh-mini: seven 7 px squares, 2 apart.
                    Row {
                        spacing: 2
                        anchors.verticalCenter: parent.verticalCenter
                        Repeater {
                            model: pc.d.mini
                            delegate: Rectangle {
                                required property var modelData
                                width: 7; height: 7; radius: 1.5
                                color: C.RoboTheme.css(modelData)
                            }
                        }
                    }
                    TapHandler { onTapped: root.ic.showSection("activity", root.openDetail) }
                }
            }
            // .int-stats.gh-rows: gap 4, padding-top 6, padding-right 12
            Item { width: 1; height: 6 }
            Column {
                width: parent.width - 12
                spacing: 4
                Repeater {
                    model: pc.d.stats
                    delegate: StatRow {
                        required property var modelData
                        icon: modelData.icon; stroke: modelData.stroke; evenOdd: modelData.evenOdd
                        color: modelData.color; label: modelData.label; value: modelData.value
                        clickable: true
                        onClicked: root.ic.showSection(modelData.section, root.openDetail)
                    }
                }
            }
        }
    }

    // ── GitHub detail: lists and contribution grid ────────────────────────────

    Component {
        id: ghDetailCard
        Column {
            id: ghd
            readonly property var d: root.rev >= 0 ? root.ic.githubDetail() : ({ rows: [], weeks: [] })
            readonly property var rows: d.rows
            property var picked: null
            width: parent ? parent.width : 0
            // .gh-detail-head: back (chevron 9 + 600 12 title, gap 3), right text; gap 6.
            IntFlexRow {
                width: parent.width
                spacing: 6
                Row {
                    spacing: 3
                    C.Icon { anchors.verticalCenter: parent.verticalCenter; path: root.lib.ICONS.chevronLeft; size: 9; stroke: 2.6; color: C.RoboTheme.ink }
                    C.CText { text: ghd.d.title; size: 12; cssWeight: 600; elide: Text.ElideNone }
                    TapHandler { onTapped: root.closeDetail() }
                }
                // .gh-head-right: margin-left auto, 11 dim-2, opens the profile.
                BidiText {
                    property bool push: true
                    property bool shrink: true
                    visible: ghd.d.hasActivity
                    raw: ghd.d.header(ghd.picked)
                    size: 11; color: C.RoboTheme.dim2
                    TapHandler { onTapped: ghd.d.openProfile() }
                }
            }
            // .gh-empty
            C.CText {
                visible: ghd.d.empty !== ""
                anchors.left: parent.left
                topPadding: 8
                text: ghd.d.empty
                size: 10.5; color: C.RoboTheme.dim3
            }
            // .gh-list: margin-top 4, three 20 px rows, the rest scrolls; fades out when longer.
            Item { visible: ghd.rows.length > 0; width: 1; height: 4 }
            Item {
                visible: ghd.rows.length > 0
                width: parent.width
                height: Math.min(60, ghd.rows.length * 20)
                Flickable {
                    id: flick
                    anchors.fill: parent
                    clip: true
                    contentHeight: ghd.rows.length * 20
                    boundsBehavior: Flickable.StopAtBounds
                    // scrollIntoView({ block: "nearest" }) when the highlight moves.
                    property var sel: root.selection
                    onSelChanged: {
                        if (sel == null) return;
                        const top = sel * 20;
                        if (top < contentY) contentY = top;
                        else if (top + 20 > contentY + height) contentY = top + 20 - height;
                    }
                    Column {
                        width: flick.width
                        Repeater {
                            model: ghd.rows
                            // .gh-row: 20 px, gap 5, padding-right 4, radius 4; hover 5 %, selected 12 %.
                            delegate: Rectangle {
                                id: gr
                                required property var modelData
                                required property int index
                                width: flick.width
                                height: 20
                                radius: 4
                                color: root.selection === index ? Qt.rgba(1, 1, 1, 0.12)
                                     : grMa.containsMouse ? Qt.rgba(1, 1, 1, 0.05) : "transparent"
                                MouseArea { id: grMa; anchors.fill: parent; hoverEnabled: true; onClicked: gr.modelData.open() }
                                IntFlexRow {
                                    width: parent.width - 4
                                    anchors.verticalCenter: parent.verticalCenter
                                    spacing: 5
                                    Item {
                                        implicitWidth: 5; implicitHeight: 5
                                        Dot { size: 5; color: gr.modelData.dot; opacity: gr.modelData.dotOpacity; visible: !gr.modelData.gap }
                                    }
                                    C.CText { text: gr.modelData.ref; size: 10.5; color: "#9398a1"; elide: Text.ElideNone }
                                    BidiText { property bool shrink: true; raw: gr.modelData.title; size: 11; color: "#c5c8cd" }
                                    C.CText { visible: gr.modelData.draft !== ""; text: gr.modelData.draft; size: 9.5; color: C.RoboTheme.dim3; elide: Text.ElideNone }
                                    C.CText {
                                        property bool push: true
                                        visible: gr.modelData.word !== ""
                                        leftPadding: 4
                                        text: gr.modelData.word; size: 10; color: gr.modelData.wordColor || "white"; elide: Text.ElideNone
                                    }
                                }
                            }
                        }
                    }
                }
                // mask-image: linear-gradient(#000 80%, transparent) — on the card's solid colour.
                Rectangle {
                    visible: ghd.d.fade
                    anchors.fill: parent
                    gradient: Gradient {
                        GradientStop { position: 0.8; color: Qt.rgba(0x14 / 255, 0x15 / 255, 0x18 / 255, 0) }
                        GradientStop { position: 1.0; color: C.RoboTheme.card }
                    }
                }
            }
            // .gh-grid: weeks of 7 squares 7 px, 1.5 px apart, padding-top 5.
            Item { visible: ghd.d.hasActivity; width: 1; height: 5 }
            Row {
                visible: ghd.d.hasActivity
                // .gh-grid stays left to right in Arabic.
                LayoutMirroring.enabled: false
                LayoutMirroring.childrenInherit: true
                spacing: 1.5
                Repeater {
                    model: ghd.d.weeks
                    delegate: Column {
                        id: wk
                        required property var modelData
                        spacing: 1.5
                        Repeater {
                            model: wk.modelData
                            delegate: Rectangle {
                                id: cell
                                required property var modelData
                                width: 7; height: 7; radius: 1.5
                                color: modelData ? C.RoboTheme.css(modelData.color) : "transparent"
                                // Hover shows the day in the header; a click pins / unpins it.
                                MouseArea {
                                    anchors.fill: parent
                                    enabled: !!cell.modelData
                                    hoverEnabled: true
                                    onEntered: ghd.picked = cell.modelData.day
                                    onExited: ghd.picked = null
                                    onClicked: ghd.picked = ghd.picked && ghd.picked.date === cell.modelData.day.date ? null : cell.modelData.day
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // ── Stripe ────────────────────────────────────────────────────────────────

    Component {
        id: stripeCard
        Column {
            id: sc
            readonly property var d: root.rev >= 0 ? root.ic.stripe() : ({ rows: [] })
            IntHead { color: "#0570DE"; name: "Stripe"; sub: root.t("Payments") }
            // .int-balance: baseline, gap 3, padding-top 4; 700 20 mono + 600 9 currency.
            Item { width: 1; height: 4 }
            Item {
                id: balBox
                anchors.left: parent.left
                readonly property bool mirrored: LayoutMirroring.enabled
                width: bal.implicitWidth + 3 + cur.implicitWidth
                height: bal.implicitHeight
                C.CText { id: bal; x: balBox.mirrored ? cur.implicitWidth + 3 : 0; text: sc.d.balance; size: 20; cssWeight: 700; font.family: C.RoboTheme.mono; elide: Text.ElideNone }
                C.CText {
                    id: cur
                    x: balBox.mirrored ? 0 : bal.implicitWidth + 3
                    anchors.baseline: bal.baseline
                    text: sc.d.currency; size: 9; cssWeight: 600; color: C.RoboTheme.dim3; elide: Text.ElideNone
                }
            }
            // .int-rows.tight: gap 2, padding-top 4
            Item { width: 1; height: 4 }
            Column {
                width: parent.width
                spacing: 2
                Repeater {
                    model: sc.d.rows
                    delegate: IntRow {
                        id: sr
                        required property var modelData
                        accent: modelData.accent
                        IntName { raw: sr.modelData.name }
                        C.CText { property bool push: true; text: sr.modelData.amount; size: 11; cssWeight: 500; font.family: C.RoboTheme.mono; color: "#22c55e"; elide: Text.ElideNone }
                        IntAgo { text: sr.modelData.ago }
                    }
                }
            }
        }
    }

    // ── Notion ────────────────────────────────────────────────────────────────

    Component {
        id: notionCard
        Column {
            IntHead { color: "#E8E8E8"; name: "Notion"; sub: root.t("Recent") }
            Item { width: 1; height: 4 }
            Column {
                width: parent.width
                spacing: 2
                Repeater {
                    model: root.rev >= 0 ? root.ic.notion() : []
                    // .int-page: gap 6, padding 4 6, hover white 5 %.
                    delegate: Rectangle {
                        id: np
                        required property var modelData
                        anchors.left: parent.left
                        width: Math.min(parent.width, pl.implicitWidth + 12)
                        height: pl.height + 8
                        radius: 5
                        color: npMa.containsMouse ? Qt.rgba(1, 1, 1, 0.05) : "transparent"
                        MouseArea { id: npMa; anchors.fill: parent; hoverEnabled: true; onClicked: np.modelData.open() }
                        IntFlexRow {
                            id: pl
                            x: 6
                            y: 4
                            width: parent.width - 12
                            spacing: 6
                            // .int-emoji: 14 wide, 10 px, or the doc glyph 9.
                            Item {
                                implicitWidth: 14
                                implicitHeight: np.modelData.emoji !== "" ? em.implicitHeight : 9
                                C.CText { id: em; anchors.centerIn: parent; visible: np.modelData.emoji !== ""; text: np.modelData.emoji; size: 10; color: C.RoboTheme.dim3; elide: Text.ElideNone }
                                C.Icon { anchors.centerIn: parent; visible: np.modelData.emoji === ""; path: root.lib.ICONS.doc; size: 9; color: C.RoboTheme.dim3 }
                            }
                            IntName { raw: np.modelData.title }
                            IntAgo { text: np.modelData.ago }
                        }
                    }
                }
            }
        }
    }

    // ── Cal.com ───────────────────────────────────────────────────────────────

    Component {
        id: calcomCard
        Column {
            id: cc
            readonly property var d: root.rev >= 0 ? root.ic.calcom() : ({ rows: [], empty: "" })
            IntHead { color: "#C9956A"; name: "Cal.com"; sub: root.t("Schedule") }
            Item { width: 1; height: 4 }
            Column {
                width: parent.width
                spacing: 2
                // .int-empty: 11 dim-3, padding-left 8.
                C.CText { visible: cc.d.empty !== ""; anchors.left: parent.left; leftPadding: 8; text: cc.d.empty; size: 11; color: C.RoboTheme.dim3 }
                Repeater {
                    model: cc.d.rows
                    delegate: IntRow {
                        id: cr
                        required property var modelData
                        accent: "#C9956A"
                        dotSize: 4
                        // .int-time: 500 10 mono #c9956a
                        C.CText { text: cr.modelData.time; size: 10; cssWeight: 500; font.family: C.RoboTheme.mono; color: "#c9956a"; elide: Text.ElideNone }
                        IntName { raw: cr.modelData.name }
                    }
                }
            }
        }
    }

    // ── n8n ───────────────────────────────────────────────────────────────────

    Component {
        id: n8nCard
        Column {
            id: nc
            readonly property var d: root.rev >= 0 && root.task ? root.ic.n8n(root.task) : ({})
            IntHead { color: "#F29B38"; name: "n8n"; sub: root.t("Workflow") }
            // .int-actions: padding-top 6
            Item { width: 1; height: 6 }
            // .int-pill: gap 5, padding 3 8, pill, accent wash + border; opens the detail.
            Rectangle {
                anchors.left: parent.left
                width: Math.min(parent.width, il.implicitWidth + 18)
                height: il.height + 8
                radius: height / 2
                color: root.hexA(nc.d.accent || "#000000", 0x1a / 255)
                border.width: 1
                border.color: root.hexA(nc.d.accent || "#000000", 0x38 / 255)
                MouseArea { anchors.fill: parent; onClicked: root.openDetail() }
                IntFlexRow {
                    id: il
                    x: 9
                    y: 4
                    width: parent.width - 18
                    spacing: 5
                    Dot { size: 5; color: nc.d.accent || "white" }
                    IntName { raw: nc.d.name || "" }
                    C.Icon { path: root.lib.ICONS.ellipsis; size: 8; color: C.RoboTheme.dim3 }
                }
            }
        }
    }

    Component {
        id: n8nDetailCard
        Column {
            id: nd
            readonly property var d: root.rev >= 0 && root.task ? root.ic.n8n(root.task) : ({})
            DetailHead { accent: nd.d.accent || "white"; name: nd.d.name || ""; badge: nd.d.badge || "" }
            // pre.int-detail-text: mono 10.5/1.5 dim, margin-top 8, max 88 px, scrolls.
            Item { visible: nd.d.detail !== ""; width: 1; height: 8 }
            Flickable {
                visible: nd.d.detail !== ""
                width: parent.width
                height: Math.min(88, dt.implicitHeight)
                contentHeight: dt.implicitHeight
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                BidiText {
                    id: dt
                    width: parent.width
                    raw: nd.d.detail || ""
                    size: 10.5
                    font.family: C.RoboTheme.mono
                    color: C.RoboTheme.dim
                    wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                    maximumLineCount: 1000
                    elide: Text.ElideNone
                    lineHeightMode: Text.FixedHeight
                    lineHeight: 10.5 * 1.5
                }
            }
            // .int-status (padding-top 4) when there is no detail.
            C.CText {
                visible: nd.d.detail === ""
                anchors.left: parent.left
                topPadding: 4
                text: nd.d.status || ""
                size: 11; color: C.RoboTheme.dim3
            }
        }
    }
}
