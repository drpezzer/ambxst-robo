// Port only (his ask): the mascot's state colours from the shell's matugen palette,
// behind a setting (processColorsMatugen, off by default).
//
// Upstream keeps the state colours in mascot/engine.ts's private `C` table; every
// state's config (tint, badge) refers to those same arrays, so they are
// recoloured in place — every engine (the island's, the minis', the desktop's)
// follows — and put back when the switch goes off. The glow colour is
// core/layout.ts botGlowColor(), which island.ts asks through glowColor() here.

import { BotEngine } from "@coucou/mascot/engine";
import { botGlowColor } from "@coucou/core/layout";
import type { BotStateName } from "@coucou/core/layout";

type RGB = [number, number, number];
const STATES: BotStateName[] = [
  "idle", "working", "thinking", "searching", "approval", "question", "error", "finished", "ratelimit", "sleeping", "dizzy",
] as BotStateName[];

/** state → the shared colour arrays its config uses, and their upstream values. */
let shared: Map<string, { arrays: RGB[]; original: RGB }> | null = null;
let palette: Record<string, string> | null = null;

function collect() {
  if (shared) return shared;
  shared = new Map();
  const e = new BotEngine() as unknown as { cfg: { color: RGB; badge: { color: RGB } | null }; setState(s: string, instant?: boolean): void };
  for (const s of STATES) {
    e.setState(s, true);
    const arrays: RGB[] = [e.cfg.color];
    if (e.cfg.badge && e.cfg.badge.color !== e.cfg.color) arrays.push(e.cfg.badge.color);
    shared.set(s, { arrays, original: [...e.cfg.color] as RGB });
  }
  return shared;
}

function hexRGB(hex: string): RGB | null {
  const m = /^#?([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})/i.exec(hex.trim());
  return m ? [parseInt(m[1], 16) / 255, parseInt(m[2], 16) / 255, parseInt(m[3], 16) / 255] : null;
}

/** `p`: state → "#rrggbb" (from the shell's Colors), or null for upstream's own. */
export function setProcessPalette(p: Record<string, string> | null) {
  const all = collect();
  palette = p;
  for (const [s, entry] of all) {
    const c = (p && p[s] && hexRGB(p[s])) || entry.original;
    for (const a of entry.arrays) { a[0] = c[0]; a[1] = c[1]; a[2] = c[2]; }
  }
}

/** botGlowColor(), or the palette's colour while it is on (idle keeps its white). */
export function glowColor(s: BotStateName): string {
  if (palette && s !== "idle" && palette[s]) return palette[s];
  return botGlowColor(s);
}

/** Port: a state's matugen colour (hex) while the switch is on, else null. */
export function processColor(s: string): string | null {
  return palette && palette[s] ? palette[s] : null;
}
