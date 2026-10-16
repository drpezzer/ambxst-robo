import QtQuick

// main.ts:248-320 planSection — plan usage in the island's header. The relay
// has to be Claude Code's status line first: turning the switch on without it
// starts the install, and it only stays on once that has been confirmed.
SSection {
    id: sec
    property var page
    readonly property var xL: page.xL
    readonly property var xP: page.fresh(xL.PLAN_SETTINGS_TEXT)
    readonly property var st: page.rev >= 0 && page.info ? page.info.status : ({ planRelayInstalled: false })
    // A fresh copy per change: the same object would not notify, and switches
    // reading it would keep showing the old value (saved, but drawn wrong).
    readonly property var s: page.rev >= 0 && page.settings ? Object.assign({}, page.settings) : ({})
    property var review: null
    property var onReviewBack: null
    property var onReviewApplied: null
    title: xP.title

    function rebuild() {
        return sec.page.refreshStatus().then(() => {
            const S = sec.page.settings;
            S.planRelayInstalled = sec.page.info.status.planRelayInstalled;
            // Cancelled or failed: a switch that was waiting for the install falls back.
            if (!sec.page.info.status.planRelayInstalled) S.showPlanInNotch = false;
            sec.review = null;
            sec.page.rev++;
        });
    }
    function startReview(change, back, applied) {
        onReviewBack = back;
        onReviewApplied = applied;
        review = change;
    }

    Column {
        width: sec.innerWidth
        spacing: 12
        Column {
            visible: !sec.review
            width: parent.width
            spacing: 12
            SHint { width: parent.width; text: sec.xP.claude }
            SHint { width: parent.width; text: sec.xP.claudeCli }
            FlexRow {
                width: parent.width
                SLabel { text: sec.xP.showClaude }
                SSwitch {
                    on: !!sec.s.showPlanInNotch
                    onToggled: next => {
                        const S = sec.page.settings;
                        if (!next) {
                            S.showPlanInNotch = false;
                            sec.page.save();
                        } else if (sec.st.planRelayInstalled) {
                            S.showPlanInNotch = true;
                            sec.page.save();
                        } else {
                            // Turned on before the relay is in: install it first.
                            sec.startReview(sec.xL.statusLineChange(true), () => sec.rebuild(), () => {
                                S.planRelayInstalled = true;
                                S.showPlanInNotch = true;
                                sec.page.save().then(() => sec.rebuild());
                            });
                        }
                    }
                }
            }
            FlexRow {
                width: parent.width
                SLabel { text: sec.xP.relay }
                SDot { ok: sec.st.planRelayInstalled }
                SHint { text: sec.xP.relayState(sec.st.planRelayInstalled); wrapMode: Text.NoWrap }
                SButton {
                    kind: sec.st.planRelayInstalled ? "danger" : "primary"
                    text: sec.st.planRelayInstalled ? sec.xP.uninstallRelay : sec.xP.installRelay
                    onClicked: sec.startReview(sec.xL.statusLineChange(!sec.st.planRelayInstalled),
                        () => { sec.review = null; }, () => sec.rebuild())
                }
            }
            SHint { width: parent.width; text: sec.xP.codex }
            FlexRow {
                width: parent.width
                SLabel { text: sec.xP.showCodex }
                SSwitch {
                    on: !!sec.s.showCodexPlanInNotch
                    onToggled: next => { sec.page.settings.showCodexPlanInNotch = next; sec.page.save(); }
                }
            }
        }
        ReviewBody {
            visible: !!sec.review
            width: parent.width
            page: sec.page
            change: sec.review
            onBack: if (sec.onReviewBack) sec.onReviewBack()
            onApplied: if (sec.onReviewApplied) sec.onReviewApplied()
        }
    }
}
