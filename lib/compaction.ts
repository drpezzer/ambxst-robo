// Port only (his ask): Claude Code compacting a conversation, made visible.
// ambxst-robo turns the chat's stream into PreCompact / PostCompact (and a
// terminal session's hooks are the same events): the chat log shows a bar
// under the latest line while it runs and a "Compacted conversation" marker
// where it happened; the mascot plays its compacting animation meanwhile.
//
// Claude Code says when compaction starts and ends, not how far along it is:
// the bar runs on an estimate from the conversation's size, slowing as it nears
// the end, held short of full until the end really comes.

import { State } from "@coucou/core/state";
import { processColor } from "./palette";

interface Run {
  started: number;
  /** Expected seconds. */
  est: number;
  /** When it ended (the bar fills, then goes), or null. */
  ended: number | null;
}

const runs = new Map<string, Run>();
export const FILL_MS = 600;
const GIVE_UP_MS = 10 * 60 * 1000;
let listeners: Array<() => void> = [];

/** Seconds a compaction of `tokens` takes, roughly (150k ≈ 45 s). */
function estimate(tokens: number): number {
  return Math.max(15, Math.min(120, 15 + tokens / 5000));
}

export function start(key: string, tokens: number) {
  if (!key) return;
  const r: Run = { started: performance.now(), est: estimate(tokens || 120000), ended: null };
  runs.set(key, r);
  changed();
  // An end that never came (a lost PostCompact): it stops anyway, so the
  // mascot never loops forever.
  setTimeout(() => {
    if (runs.get(key) === r && r.ended === null) finish(key);
  }, GIVE_UP_MS);
}


/** It ended: the bar fills and fades over FILL_MS. False when none was running. */
export function finish(key: string): boolean {
  const r = runs.get(key);
  if (!r) return false;
  r.ended = performance.now();
  changed();
  setTimeout(() => {
    if (runs.get(key) === r) {
      runs.delete(key);
      changed();
    }
  }, FILL_MS + 50);
  return true;
}

/** How far along (0–1) the compaction of `key` is, or -1 when none is shown. */
export function progress(key: string): number {
  const r = runs.get(key);
  if (!r) return -1;
  const now = performance.now();
  const t = (now - r.started) / 1000;
  // Toward 0.95 by the estimate, slowing (it never claims to be done).
  const run = 0.95 * (1 - Math.exp((-2.3 * t) / r.est));
  if (r.ended === null) return run;
  const k = Math.min(1, (now - r.ended) / FILL_MS);
  return run + (1 - run) * (1 - Math.pow(1 - k, 3));
}

/** Whether the compaction of `key` is still running (not just filling up). */
export function running(key: string): boolean {
  const r = runs.get(key);
  return !!r && r.ended === null;
}

/** Whether any conversation of the user's is compacting now (the main mascot's animation). */
export function anyRunning(): boolean {
  for (const r of runs.values()) if (r.ended === null) return true;
  return false;
}

/** The bar's colour: the finished green, or matugen's when Settings say so. */
export function color(): string {
  return processColor("finished") ?? "#34D399";
}

export function onChange(fn: () => void) {
  listeners.push(fn);
}

function changed() {
  for (let i = 0; i < listeners.length; i++) listeners[i]();
  State.notify();
}
