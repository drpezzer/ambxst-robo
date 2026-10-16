// views/usage.ts buildPlanPill / PlanCard without the DOM: what the header's
// plan pills and the plan card show, and the pill's click. PlanPills.qml and
// PlanCard.qml render it.

import {
  PLAN_TEXT, claudeSubtitle, codexResetsLabel, codexSubtitle, dominantPct, effectivePct, pillLabel,
  planColor, resetLabel, type PlanWindow,
} from "@coucou/core/plan";
import { onEvent } from "@coucou/core/bridge";
import { State } from "@coucou/core/state";
import { claudePillVisible, codexPillVisible, refreshCodexPlanUsage } from "@coucou/views/usage";
import { ICONS } from "@coucou/views/icons";

const claudeColor = (now: number) => planColor(dominantPct(State.planUsage, now));
const codexColor = (now: number) => planColor(dominantPct(State.codexPlanUsage, now));

// ── Port: the context window of the latest Claude Code session ──────────────
// The status line relay (ambxst-robo-hook --statusline) passes the session's
// context_window.used_percentage along with the plan limits; the newest one
// wins (the session Claude Code updated last).

let ctxPct: number | null = null;
let ctxListening = false;
function listenContext() {
  if (ctxListening) return;
  ctxListening = true;
  void onEvent<{ hook_event_name?: string; context_window?: { used_percentage?: unknown } }>("hook", (p) => {
    if (p?.hook_event_name !== "StatusLine") return;
    const pct = p.context_window?.used_percentage;
    if (typeof pct !== "number" || !isFinite(pct)) return;
    const next = Math.min(100, Math.max(0, pct));
    if (ctxPct !== null && Math.round(ctxPct) === Math.round(next)) {
      ctxPct = next;
      return;
    }
    ctxPct = next;
    State.notify();
  });
}

/** Port: "Claude ctx 42% · 5h 35%" — the context window, then the 5-hour window. */
export function claudeLabel(now = Date.now()): string {
  const u = State.planUsage;
  const five = u?.fiveHour ? `${Math.round(effectivePct(u.fiveHour, now))}%` : null;
  if (ctxPct === null && five === null) return pillLabel("Claude", u, now);
  const parts: string[] = [];
  if (ctxPct !== null) parts.push(`ctx ${Math.round(ctxPct)}%`);
  parts.push(`5h ${five ?? PLAN_TEXT.none}`);
  return `Claude ${parts.join(" · ")}`;
}

/** The header's syncPlanPills(): which pills show, their colour, label and lit state. */
export function pills(now = Date.now()) {
  listenContext();
  const claudeOn = claudePillVisible();
  const codexOn = codexPillVisible();
  const isOpen = (codex: boolean) => State.showingPlanDetail && State.planDetailIsCodex === codex;
  return {
    claudeOn, codexOn, any: claudeOn || codexOn, both: claudeOn && codexOn,
    claude: { color: claudeColor(now), label: claudeLabel(now), active: isOpen(false), title: PLAN_TEXT.claudePillTitle },
    codex: { color: codexColor(now), label: pillLabel("Codex", State.codexPlanUsage, now), active: isOpen(true), title: PLAN_TEXT.codexPillTitle },
  };
}

/** buildPlanPill's onclick. */
export function clickPill(codex: boolean) {
  const open = State.showingPlanDetail && State.planDetailIsCodex === codex;
  State.planDetailIsCodex = codex;
  State.showingPlanDetail = !open;
  if (codex) refreshCodexPlanUsage();
  State.notify();
}

/** Codex is asked when its pill comes into view (stale answers only). */
let codexShown = false;
export function syncCodexShown() {
  const shown = codexPillVisible() && State.mode === "expanded";
  if (shown && !codexShown) refreshCodexPlanUsage();
  codexShown = shown;
}

export interface GaugeRow {
  label: string;
  /** "gauge" | "none" | "credits" */
  kind: string;
  pct: number;
  pctText: string;
  color: string;
  reset: string;
  text: string;
}

function gaugeRow(label: string, w: PlanWindow | undefined, weekly: boolean, now: number): GaugeRow {
  if (!w) return { label, kind: "none", pct: 0, pctText: "", color: "", reset: "", text: PLAN_TEXT.none };
  const pct = effectivePct(w, now);
  return {
    label, kind: "gauge", pct, pctText: `${Math.round(pct)}%`, color: planColor(pct),
    reset: resetLabel(w, weekly, now), text: "",
  };
}

/** PlanCard.sync(): the open card's head and rows. */
export function card(now = Date.now()) {
  if (State.planDetailIsCodex) {
    const u = State.codexPlanUsage;
    const rows: GaugeRow[] = [];
    if (u?.fiveHour) rows.push(gaugeRow(PLAN_TEXT.fiveHours, u.fiveHour, false, now));
    rows.push(gaugeRow(PLAN_TEXT.week, u?.sevenDay, true, now));
    rows.push({ label: PLAN_TEXT.resets, kind: "credits", pct: 0, pctText: "", color: "", reset: "", text: codexResetsLabel(u) });
    return { color: codexColor(now), title: PLAN_TEXT.codexTitle, sub: codexSubtitle(u, now), rows };
  }
  const u = State.planUsage;
  return {
    color: claudeColor(now), title: PLAN_TEXT.claudeTitle, sub: claudeSubtitle(u, now),
    rows: [gaugeRow(PLAN_TEXT.fiveHours, u?.fiveHour, false, now), gaugeRow(PLAN_TEXT.week, u?.sevenDay, true, now)],
  };
}

export const resetIcon = ICONS.arrowClockwise;
