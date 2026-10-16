// The live-session ticker and the status cards (finished / error / note…),
// without the DOM. Mirrors views/ticker.ts (Ticker) and the builders of
// views/views.ts (buildOverview's `who` row, buildFinished, buildError,
// buildEmpty, buildConfused, buildNote): the QML views only render what this
// decides.

import { cubicBezier, clamp, lerp } from "@coucou/core/anim";
import { parseDiffStep, lastTextStep, fileName, type DiffStep, type FileDiff } from "@coucou/core/diff";
import { sessionSubtitle } from "@coucou/core/pills";
import { State, type AgentTask } from "@coucou/core/state";
import { t } from "@coucou/i18n/i18n";

// ── Ticker (views/ticker.ts) ──────────────────────────────────────────────────

export const ROW_H = 22;
const DURATION = 380;
const MAX_QUEUE = 4;
const COMPLETED_SCALE = 11.5 / 13;
const EASE = cubicBezier(0.4, 0, 0.2, 1);
export const STILL_CURRENT = "#c9cdd4";
export const DIM = "#6b7079";

/** One row as the QML draws it: what makeRow/setText/place set on the DOM. */
export interface TickerRow {
  text: string;
  /** Shown text: the file name for a diff step. */
  shown: string;
  diff: DiffStep | null;
  /** " +N" / " −M" (setText), empty when zero. */
  plus: string;
  minus: string;
  x: number;
  y: number;
  scale: number;
  opacity: number;
  chevron: number;
  check: number;
  shimmer: number;
  dim: number;
  dimColor: string;
  /** animationPlayState paused. */
  still: boolean;
}

function makeRow(): TickerRow {
  return {
    text: "", shown: "", diff: null, plus: "", minus: "",
    x: 0, y: 0, scale: 1, opacity: 1, chevron: 1, check: 0, shimmer: 1, dim: 0, dimColor: DIM, still: false,
  };
}

function setText(row: TickerRow, text: string) {
  if (row.text === text) return;
  row.text = text;
  const diff = parseDiffStep(text);
  row.diff = diff;
  row.shown = diff ? diff.filename : text;
  row.plus = diff && diff.added > 0 ? ` +${diff.added}` : "";
  row.minus = diff && diff.removed > 0 ? ` −${diff.removed}` : "";
}

function place(row: TickerRow, y: number, phase: number, opacity: number, still: boolean) {
  row.scale = 1 - phase * (1 - COMPLETED_SCALE);
  row.x = -phase * 10;
  row.y = y;
  row.opacity = opacity;
  if (still) {
    row.chevron = 0;
    row.check = 1;
    row.shimmer = 0;
    row.dim = 1;
    row.dimColor = phase < 0.5 ? STILL_CURRENT : DIM;
  } else {
    row.chevron = clamp(1 - phase * 2, 0, 1);
    row.check = clamp(phase * 2 - 1, 0, 1);
    row.shimmer = clamp(1 - phase * 1.6, 0, 1);
    row.dim = clamp(phase * 2 - 0.4, 0, 1);
    row.dimColor = DIM;
  }
  row.still = still;
}

/** views/ticker.ts Ticker, rows as data. `rows` = [completed, current, incoming]. */
export class TickerModel {
  readonly rows: TickerRow[];
  private a = makeRow();
  private b = makeRow();
  private c = makeRow();
  private queue: string[] = [];
  private startMs: number | null = null;
  private displayIndex = -1;
  private still = false;

  constructor() {
    this.rows = [this.a, this.b, this.c];
    this.rest();
  }

  private rest() {
    place(this.a, 0, 1, 1, this.still);
    place(this.b, ROW_H, 0, 1, this.still);
    place(this.c, ROW_H * 2, 0, 0, this.still);
  }

  get animating(): boolean {
    return this.startMs != null || this.queue.length > 0;
  }

  sync(task: AgentTask | null) {
    const steps = task?.steps ?? [];
    const newest = steps.length === 0 ? -1 : (task?.stepSeq ?? steps.length - 1);

    const still = !!task?.finalLine;
    if (still !== this.still) {
      this.still = still;
      if (this.startMs == null) this.rest();
    }

    if (this.displayIndex < 0 || newest < this.displayIndex) {
      this.queue = [];
      this.startMs = null;
      this.displayIndex = newest;
      setText(this.a, steps.length >= 2 ? steps[steps.length - 2] : "…");
      setText(this.b, steps.length >= 1 ? steps[steps.length - 1] : "…");
      this.rest();
      return;
    }

    const fresh = Math.min(newest - this.displayIndex, steps.length);
    if (fresh > 0) this.queue.push(...steps.slice(-fresh));
    this.displayIndex = newest;
    if (this.queue.length > MAX_QUEUE) {
      this.queue = this.queue.slice(-MAX_QUEUE);
    }
  }

  tick(nowMs: number) {
    if (this.startMs == null) {
      if (this.queue.length === 0) return;
      setText(this.c, this.queue[0]);
      place(this.c, ROW_H * 2, 0, 0, this.still);
      this.startMs = nowMs;
    }

    const p = clamp((nowMs - this.startMs) / DURATION, 0, 1);
    const e = EASE(p);

    place(this.a, lerp(0, -ROW_H, e), 1, clamp(1 - p * 1.35, 0, 1), this.still);
    place(this.b, lerp(ROW_H, 0, e), e, 1, this.still);
    place(this.c, lerp(ROW_H * 2, ROW_H, e), 0, e, this.still);

    if (p < 1) return;

    setText(this.a, this.b.text);
    setText(this.b, this.c.text);
    this.queue.shift();
    this.startMs = null;
    this.rest();
  }

  /** Clickable rows: the completed and the current one (constructor). */
  diffIdAt(index: number): number | null {
    const row = index === 0 ? this.a : index === 1 ? this.b : null;
    return row?.diff ? row.diff.diffId : null;
  }
}

/** Upstream builds one Ticker per overview, kept for the app's lifetime. */
export const overviewTicker = new TickerModel();

// ── Overview `who` row (buildOverview sync) ───────────────────────────────────

export function sessionWho(task: AgentTask): { name: string; tool: string; count: string } {
  return {
    name: task.name,
    // Port: a chat conversation's pill (chat.ts convPillId) is a chat, not an agent.
    tool: (task as AgentTask & { conv?: string }).conv ? t("Chat") : t(sessionSubtitle(task.id)),
    count: task.steps.length > 1
      ? `${Math.min(task.stepIndex + 1, task.steps.length)}/${task.steps.length}`
      : "",
  };
}

/** Ctrl+E (buildOverview command "toggleDiff") with no diff open: the latest edit. */
export function latestDiffId(task: AgentTask | null): number | null {
  const diffs = task ? State.sessionDiffs.get(task.id) : undefined;
  const last = diffs ? diffs[diffs.length - 1] : undefined;
  return last?.id ?? null;
}

// ── Diff card (views/diff.ts buildDiffCard) ───────────────────────────────────

const SYMBOLS: Record<string, string> = { added: "+", removed: "−", context: " " };

export function diffCard(diff: FileDiff) {
  const lines = diff.hunks.reduce((all, hunk) => all.concat(hunk.lines), [] as FileDiff["hunks"][number]["lines"]);
  return {
    name: fileName(diff.path),
    path: diff.path,
    plus: diff.added > 0 ? `+${diff.added}` : "",
    minus: diff.removed > 0 ? `−${diff.removed}` : "",
    backTitle: t("Back"),
    openTitle: t("Open in VS Code"),
    note: diff.tooLarge ? t("Diff too large") : lines.length === 0 ? t("No changes") : "",
    lines: diff.tooLarge ? [] : lines.map((l) => ({ kind: l.kind, sym: SYMBOLS[l.kind], text: l.text })),
  };
}

// ── Status cards ──────────────────────────────────────────────────────────────

/** buildFinished sync. */
export function finished(task: AgentTask | null) {
  const agent = task?.source === "agent";
  return {
    who: agent ? t("finished") : t("Claude Code finished"),
    title: task?.finalLine || (task && lastTextStep(task.steps)) || t("Session finished"),
    openLabel: task?.id === "agent_claude-desktop" ? t("Open Claude") : t("Open terminal"),
    okLabel: t("OK"),
  };
}

/** buildError sync. */
export function error(task: AgentTask | null) {
  return {
    who: task?.source === "n8n" ? "n8n" : task?.source === "agent" ? t("Agent") : "Claude Code",
    title: task?.source === "n8n" ? t("Workflow stopped.") : t("Session stopped on an error."),
    detail: (task && lastTextStep(task.steps)) ?? t("No detail available."),
    retry: t("Retry"),
    openN8n: t("Open in n8n"),
  };
}

/** Retry on the error card: setView(State.defaultView()). */
export function defaultView(): string {
  return State.defaultView();
}

/** buildEmpty / buildConfused texts. */
export function texts() {
  return {
    emptyTitle: t("Nothing running right now."),
    emptySub: t("Drop a file or window, or ask me anything."),
    askClaude: t("Ask Claude"),
    confusedTitle: t("Too many hits at once."),
    confusedSub: t("Give me a sec — back to work in three seconds."),
  };
}

/** Test scenarios (tools/compare.sh) run without a global setTimeout in QML. */
export function later(fn: () => void, ms: number) {
  window.setTimeout(fn, ms);
}
