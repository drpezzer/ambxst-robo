// Port only (his ask): a helper (subagent) of a Claude Code session, chat or
// terminal, is drawn in the minis as a floating liquid blob, not a mascot:
// its colour flows with its state, its surface a little wavy while it works,
// very wavy while it thinks, a sphere once it is done; then it shrinks and
// pops, and its pill goes with it. No badge.

import { hexToRGB } from "@coucou/mascot/engine";
import { State, type AgentTask } from "@coucou/core/state";
import { processColor } from "./palette";

type RGB = [number, number, number];

/** engine.ts's state colours (C), matugen's when that setting is on. */
const STATE_RGB: Record<string, RGB> = {
  working: [0.231, 0.62, 1],
  thinking: [0.545, 0.361, 0.965],
  searching: [0.388, 0.396, 0.949],
  approval: [0.961, 0.647, 0.141],
  question: [0.133, 0.827, 0.933],
  error: [0.957, 0.314, 0.369],
  finished: [0.204, 0.831, 0.6],
  ratelimit: [0.984, 0.573, 0.235],
};

/** How wavy the surface is (of its radius) and how fast the waves run, per state. */
const WAVE: Record<string, { amp: number; speed: number }> = {
  idle: { amp: 0.025, speed: 0.6 },
  working: { amp: 0.07, speed: 1 },
  searching: { amp: 0.07, speed: 1.1 },
  thinking: { amp: 0.17, speed: 1.6 },
  approval: { amp: 0.05, speed: 1.4 },
  question: { amp: 0.05, speed: 1.2 },
  ratelimit: { amp: 0.04, speed: 0.5 },
  error: { amp: 0.035, speed: 0.4 },
  finished: { amp: 0, speed: 0.6 },
};

/** Done: a sphere this long, then it shrinks, then the pop. */
const HOLD = 0.9;
const SHRINK = 0.28;
const POP = 0.32;

export interface Blob {
  col: RGB;
  amp: number;
  speed: number;
  /** Wave phase (advances with the state's speed, so a change of pace never jumps). */
  phase: number;
  time: number;
  /** Seconds since it finished (−1 while not), for the hold → shrink → pop. */
  doneFor: number;
  popped: boolean;
  seed: number;
}

export function isHelper(task: AgentTask | undefined | null): boolean {
  return !!(task as (AgentTask & { helperOf?: string }) | null | undefined)?.helperOf;
}

function target(task: AgentTask): RGB {
  const s = task.state as string;
  const m = processColor(s);
  if (m) return hexToRGB(m) as RGB;
  return STATE_RGB[s] ?? (hexToRGB(task.color) as RGB);
}

export function createBlob(task: AgentTask, seed: number): Blob {
  const w = WAVE[task.state as string] ?? WAVE.idle;
  return { col: target(task), amp: w.amp, speed: w.speed, phase: 0, time: 0, doneFor: -1, popped: false, seed };
}

/** One frame; true while it still moves (to be repainted). */
export function updateBlob(b: Blob, task: AgentTask, dt: number): boolean {
  if (b.popped) return false;
  dt = Math.min(dt, 0.1);
  b.time += dt;
  const w = WAVE[task.state as string] ?? WAVE.idle;
  const k = 1 - Math.pow(0.004, dt);
  const t = target(task);
  b.col = b.col.map((v, i) => v + (t[i] - v) * k) as RGB;
  b.amp += (w.amp - b.amp) * k;
  b.speed += (w.speed - b.speed) * k;
  b.phase += dt * b.speed;
  if (task.state === "finished") {
    b.doneFor = b.doneFor < 0 ? 0 : b.doneFor + dt;
    if (b.doneFor >= HOLD + SHRINK + POP) {
      b.popped = true;
      // Its pill goes with it (upstream would take it away after 5.2 s).
      if (State.tasks.some((x) => x.id === task.id)) {
        State.removeTask(task.id);
        State.notify();
      }
      return true;
    }
  } else {
    b.doneFor = -1;
  }
  return true;
}

const rgb = (c: RGB, a = 1, lift = 0) =>
  `rgba(${c.map((v) => Math.round(Math.min(1, v + (1 - v) * lift) * 255)).join(",")},${a})`;
const dark = (c: RGB, f: number): RGB => c.map((v) => v * f) as RGB;

/** Draws the blob centred in a `size`-px canvas, its body `body` across. */
export function drawBlob(b: Blob, ctx: CanvasRenderingContext2D, size: number, body: number) {
  if (b.popped) return;
  const cx = size / 2;
  // Floating: a slow bob.
  const cy = size / 2 + Math.sin(b.time * 1.7 + b.seed) * body * 0.05;
  let r = body * 0.46;
  let shrink = 1;
  let pop = -1;
  if (b.doneFor >= HOLD) {
    const s = Math.min(1, (b.doneFor - HOLD) / SHRINK);
    // A little swell before it goes (ease in, back).
    shrink = 1 + 0.12 * Math.sin(Math.min(s * 2.2, 1) * Math.PI) * (s < 0.45 ? 1 : 0) - Math.pow(s, 2.2) * 0.85;
    if (b.doneFor >= HOLD + SHRINK) pop = Math.min(1, (b.doneFor - HOLD - SHRINK) / POP);
  }
  r *= Math.max(0, shrink);

  if (pop >= 0) {
    // The pop: a thin ring flying out and a few droplets, fading.
    const e = 1 - Math.pow(1 - pop, 3);
    const a = 1 - pop;
    ctx.beginPath();
    ctx.arc(cx, cy, body * (0.12 + 0.42 * e), 0, Math.PI * 2);
    ctx.strokeStyle = rgb(b.col, 0.85 * a, 0.25);
    ctx.lineWidth = Math.max(0.6, body * 0.07 * a);
    ctx.stroke();
    for (let i = 0; i < 6; i++) {
      const ang = (i / 6) * Math.PI * 2 + b.seed;
      const d = body * (0.1 + 0.55 * e);
      ctx.beginPath();
      ctx.arc(cx + Math.cos(ang) * d, cy + Math.sin(ang) * d, Math.max(0.4, body * 0.06 * a), 0, Math.PI * 2);
      ctx.fillStyle = rgb(b.col, a, 0.15);
      ctx.fill();
    }
    return;
  }
  if (r < 0.3) return;

  // A soft glow under it, in its colour.
  const glow = ctx.createRadialGradient(cx, cy, r * 0.6, cx, cy, r * 1.55);
  glow.addColorStop(0, rgb(b.col, 0.35));
  glow.addColorStop(1, rgb(b.col, 0));
  ctx.fillStyle = glow;
  ctx.fillRect(0, 0, size, size);

  // The surface: a few travelling waves round the edge.
  const N = 48;
  const p = b.phase * Math.PI * 2;
  ctx.beginPath();
  for (let i = 0; i <= N; i++) {
    const th = (i / N) * Math.PI * 2;
    const wv = 0.55 * Math.sin(3 * th + p * 0.9 + b.seed)
      + 0.3 * Math.sin(5 * th - p * 1.3 + 1.7 + b.seed)
      + 0.15 * Math.sin(2 * th + p * 0.6 + 4.1);
    const rr = r * (1 + b.amp * wv);
    const x = cx + Math.cos(th) * rr, y = cy + Math.sin(th) * rr;
    if (i === 0) ctx.moveTo(x, y);
    else ctx.lineTo(x, y);
  }
  ctx.closePath();
  // Liquid: lit from the top left, deeper at the bottom right.
  const fill = ctx.createRadialGradient(cx - r * 0.35, cy - r * 0.4, r * 0.1, cx, cy, r * 1.15);
  fill.addColorStop(0, rgb(b.col, 1, 0.45));
  fill.addColorStop(0.55, rgb(b.col, 1));
  fill.addColorStop(1, rgb(dark(b.col, 0.62)));
  ctx.fillStyle = fill;
  ctx.fill();

  // Its shine.
  ctx.beginPath();
  ctx.ellipse(cx - r * 0.32, cy - r * 0.42, r * 0.26, r * 0.15, -0.5, 0, Math.PI * 2);
  ctx.fillStyle = "rgba(255,255,255,0.55)";
  ctx.fill();
}
