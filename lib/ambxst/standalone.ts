// Port (public build): Axenide drawn on his own, for lib/public/engine.ts.
// Everything here is his: the figure (figure.ts), his own expressions (simple
// geometric glyphs: chevrons, crosses, rings, sparkles; none of the Coucou mascot's eye shapes),
// his badge (a ring on his upper right), his particles, his slot when he is the
// file drop's box, and his compacting loop. The personal build keeps drawing
// him on the Coucou mascot's engine (personal-patch.ts).

import * as F from "./figure";
import { colours, widthFor } from "./engine";
import { AX_CYCLE, axenidePhase } from "../compaction-anim";

type RGB = readonly [number, number, number];

/** What the drawing reads from the engine (lib/public/engine.ts BotEngine). */
export interface AxEngine {
  isMini: boolean;
  bodyColor: RGB | null;
  yaw: number; pitch: number; roll: number; tilt: number; open: number;
  sx: number; sy: number; oy: number; ox: number;
  tint: number; morph: number; blush: number; es: number; badgeS: number;
  particleOverhang: number;
  isDancing: boolean; dancingLevel: number;
  slotH: number; slotHTarget: number; isChewing: boolean;
  col: RGB;
  state: string;
  cfg: { eye: string };
  eyeOverride: string | null;
  badge: { kind: string; color: RGB } | null;
  particles: Array<{ kind: string; x: number; y: number; vx: number; vy: number; age: number; life: number; spin: number; size: number }>;
  /** Claude Code compacting (set by the island). */
  __ambCompact?: boolean;
  drawBadge(x: CanvasRenderingContext2D, badge: { kind: string; color: RGB }, R: number, cx: number, cy: number): void;
}

const now = () => performance.now() / 1000;
const rgb = (c: RGB | number[], a = 1) => `rgba(${Math.round(c[0] * 255)},${Math.round(c[1] * 255)},${Math.round(c[2] * 255)},${a})`;
const FONT = `system-ui, "Adwaita Sans", sans-serif`;

// ── Expressions ───────────────────────────────────────────────────────────────

const LOVE = "#FF5C8A";
const GOLD = "#FFC93C";

/** A four-point sparkle, radius r, waist k·r. */
function sparklePath(x: CanvasRenderingContext2D, r: number, k = 0.28) {
  x.beginPath();
  for (let i = 0; i < 8; i++) {
    const a = (i * Math.PI) / 4 - Math.PI / 2;
    const d = i % 2 ? r * k : r;
    if (i === 0) x.moveTo(Math.cos(a) * d, Math.sin(a) * d);
    else x.lineTo(Math.cos(a) * d, Math.sin(a) * d);
  }
  x.closePath();
}

/**
 * One eye in an expression, centred at (0, 0) in a w × h box, in the current
 * fill and stroke (figure.ts punches it out of the body, or paints it on his
 * sphere). `sd` −1 for the hole side, 1 for the sphere side.
 */
export function glyph(x: CanvasRenderingContext2D, shape: string, w: number, h: number, sd: number, open = 1) {
  const t = now();
  const u = Math.min(w, h);
  x.lineCap = "round";
  x.lineJoin = "round";
  switch (shape) {
    case "happy":
      // A chevron up.
      x.lineWidth = u * 0.3;
      x.beginPath();
      x.moveTo(-u * 0.5, u * 0.16);
      x.lineTo(0, -u * 0.22);
      x.lineTo(u * 0.5, u * 0.16);
      x.stroke();
      break;
    case "closed":
      // A chevron down, thin.
      x.lineWidth = u * 0.26;
      x.beginPath();
      x.moveTo(-u * 0.5, -u * 0.08);
      x.lineTo(0, u * 0.16);
      x.lineTo(u * 0.5, -u * 0.08);
      x.stroke();
      break;
    case "line": {
      // Annoyed: squeezed shut, > <.
      const k = -sd;
      x.lineWidth = u * 0.22;
      x.beginPath();
      x.moveTo(-k * u * 0.3, -u * 0.26);
      x.lineTo(k * u * 0.3, 0);
      x.lineTo(-k * u * 0.3, u * 0.26);
      x.stroke();
      break;
    }
    case "flat":
      // Error: a cross.
      x.lineWidth = u * 0.2;
      x.beginPath();
      x.moveTo(-u * 0.3, -u * 0.3);
      x.lineTo(u * 0.3, u * 0.3);
      x.moveTo(u * 0.3, -u * 0.3);
      x.lineTo(-u * 0.3, u * 0.3);
      x.stroke();
      break;
    case "spiral": {
      // Dizzy: a broken ring, turning, a dot orbiting it.
      // (Kept within one turn: Qt's arc() draws nothing for huge angles.)
      const a = ((t * 7) % (Math.PI * 2)) * sd;
      x.lineWidth = u * 0.14;
      x.beginPath();
      x.arc(0, 0, u * 0.36, a, a + Math.PI * 1.55);
      x.stroke();
      x.beginPath();
      x.arc(Math.cos(a - 0.5) * u * 0.36, Math.sin(a - 0.5) * u * 0.36, u * 0.1, 0, Math.PI * 2);
      x.fill();
      break;
    }
    case "heart": {
      // Love: a glowing pink orb, beating.
      const r = u * 0.4 * (1 + 0.1 * Math.max(0, Math.sin(t * 8)));
      x.fillStyle = LOVE;
      x.beginPath();
      x.arc(0, 0, r, 0, Math.PI * 2);
      x.fill();
      x.fillStyle = "rgba(255,255,255,0.55)";
      x.beginPath();
      x.arc(-r * 0.32, -r * 0.32, r * 0.24, 0, Math.PI * 2);
      x.fill();
      break;
    }
    case "star":
      // Proud: a gold sparkle, twinkling.
      x.fillStyle = GOLD;
      x.save();
      x.scale(1 + 0.1 * Math.sin(t * 6), 1 + 0.1 * Math.sin(t * 6));
      sparklePath(x, u * 0.55);
      x.fill();
      x.restore();
      break;
    case "tired":
      // Half shut: the lower half.
      x.beginPath();
      x.arc(0, -u * 0.04, u * 0.36, 0, Math.PI);
      x.closePath();
      x.fill();
      break;
    case "wink":
      if (sd < 0) {
        x.save();
        x.scale(1, Math.max(0.12, open));
        x.beginPath();
        x.arc(0, 0, u * 0.38, 0, Math.PI * 2);
        x.fill();
        x.restore();
      } else glyph(x, "happy", w, h, sd, open);
      break;
    default:
      x.beginPath();
      x.arc(0, 0, u * 0.38, 0, Math.PI * 2);
      x.fill();
  }
}

// ── The figure ────────────────────────────────────────────────────────────────

/** His expression now: the engine's, the dance's, the drop's. */
function shapeOf(e: AxEngine): string {
  let shape = e.eyeOverride ?? e.cfg.eye;
  if (e.isDancing && e.dancingLevel > 0.15 && !e.isMini && (e.state === "idle" || e.state === "finished")) shape = "happy";
  if (e.morph > 0.5) {
    if (e.isChewing) shape = "happy";
    else if (e.slotHTarget > 0.05 || e.slotH > 0.1) shape = "cup";
  }
  return shape;
}

/** Compacting: holding his breath (puffed, squinting, shaking), then letting it out. */
function compactPose(e: AxEngine): { sx: number; sy: number; turn: F.Turn | null; eye: { shape: string; open: number } | null } {
  const p = axenidePhase();
  if (p < 0.6) {
    const k = Math.sin(((p / 0.6) * Math.PI) / 2);
    return {
      sx: 1 + 0.07 * k, sy: 1 + 0.05 * k,
      turn: { x: Math.sin(p * AX_CYCLE * 30) * (0.15 + 0.45 * (p / 0.6)), y: 0.15 },
      eye: { shape: "pill", open: 0.32 - 0.12 * (p / 0.6) },
    };
  }
  if (p < 0.75) {
    const k = 1 - Math.pow(1 - (p - 0.6) / 0.15, 3);
    return { sx: 1.07 - 0.11 * k, sy: 1.05 - 0.12 * k, turn: { x: 0, y: -0.25 * k }, eye: { shape: "closed", open: 1 } };
  }
  const k0 = (p - 0.75) / 0.25;
  const k = k0 * k0 * (3 - 2 * k0);
  return { sx: 0.96 + 0.04 * k, sy: 0.93 + 0.07 * k, turn: { x: 0, y: -0.25 * (1 - k) }, eye: k0 < 0.55 ? { shape: "closed", open: 1 } : null };
}

/** His slot, as the file drop's box: a dark opening near the top, lit along its upper edge. */
export function drawSlot(x: CanvasRenderingContext2D, R: number, m: number, h: number) {
  if (h < 0.6 || m < 0.05) return;
  const w = R * 1.3 * m;
  const top = -R * 0.94 * m + R * 0.16 * m;
  const r = Math.min(w / 2, h / 2);
  const g = x.createLinearGradient(0, top, 0, top + h);
  g.addColorStop(0, "rgb(2,2,3)");
  g.addColorStop(1, "rgb(26,28,34)");
  x.beginPath();
  x.roundRect(-w / 2, top, w, h, r);
  x.fillStyle = g;
  x.fill();
  if (h > 3) {
    x.beginPath();
    x.moveTo(-w / 2 + r, top - 0.8);
    x.lineTo(w / 2 - r, top - 0.8);
    x.strokeStyle = `rgba(255,255,255,${0.4 * m})`;
    x.lineWidth = 1;
    x.lineCap = "round";
    x.stroke();
  }
}

/** The engine's draw(): Axenide in a W × H canvas, the body where the engine centres it. */
export function drawAxenide(e: AxEngine, x: CanvasRenderingContext2D, W: number, H: number) {
  const R = W * 0.3;
  const rx = R * 1.14;
  const cx = W / 2 + e.ox * R;
  const cy = H / 2 + e.particleOverhang / 2 + e.oy * R + R * 0.06;
  const c = colours({ bodyColor: e.bodyColor as number[] | null });
  let turn: F.Turn = { x: Math.sin(e.yaw) / 0.55, y: -Math.sin(e.pitch) / 0.35 };
  let sx = e.sx, sy = e.sy;
  let eye: { shape: string; open: number } | null = null;
  if (e.__ambCompact) {
    const cp = compactPose(e);
    sx *= cp.sx;
    sy *= cp.sy;
    if (cp.turn) turn = cp.turn;
    eye = cp.eye;
  }
  const pose: F.Pose = { s: widthFor(rx), m: e.morph, R, turn };

  x.save();
  x.translate(cx, cy);
  if (Math.abs(e.roll) > 0.001) x.rotate(e.roll);
  if (e.tilt !== 0) x.rotate(e.tilt);
  x.scale(sx, sy);

  F.drawBody(x, pose, c.top, c.bottom, !e.isMini || pose.s > 30);
  // The state's colour, washed up from the bottom.
  const wash = e.tint * (1 - e.morph);
  const washRgb = e.col.map((v) => Math.round(v * 255)).join(",");
  if (wash > 0.01) {
    const h = pose.s * F.ASPECT;
    const tg = x.createLinearGradient(0, h / 2, 0, -h / 2);
    tg.addColorStop(0, `rgba(${washRgb},${0.72 * wash})`);
    tg.addColorStop(1, `rgba(${washRgb},0)`);
    x.fillStyle = tg;
    x.fill(F.bodyPath(pose));
  }
  if (e.morph > 0.05) drawSlot(x, R, Math.min(1, e.morph), e.slotH * R * Math.min(1, e.morph));

  const shape = eye ? eye.shape : shapeOf(e);
  F.drawEyes(x, pose, c.mid, {
    lookX: eye ? 0 : turn.x,
    lookY: eye ? 0 : turn.y,
    shape,
    open: eye ? Math.min(e.open, eye.open) : e.open,
    scale: e.es * (e.isMini ? 1.25 : 1),
    blush: e.blush * (1 - e.morph),
    wash: { rgb: washRgb, alpha: wash },
    shapeFn: (sh, w, h, sd) => glyph(x, sh, w, h, sd, e.open),
  });
  x.restore();

  if (e.badge && e.badgeS > 0.01 && e.morph < 0.25) e.drawBadge(x, e.badge, R, cx, cy);
  drawAxenideParticles(e, x, R, cx, cy);
}

// ── Badge ─────────────────────────────────────────────────────────────────────

/** The state badge on his upper right: a ring (busy: a dot runs round it), a diamond (! / ?), a dot. */
export function drawAxenideBadge(e: AxEngine, x: CanvasRenderingContext2D, badge: { kind: string; color: RGB }, R: number, cx: number, cy: number) {
  const s = e.badgeS * (e.isMini ? 1.3 : 1);
  const t = now();
  const col = rgb(badge.color);
  x.save();
  x.translate(cx + R * 0.8 * e.sx, cy - R * 0.66 * e.sy);
  x.scale(s, s);
  if (badge.kind === "dots") {
    const r = R * 0.2;
    x.fillStyle = "rgba(0,0,0,0.85)";
    x.beginPath();
    x.arc(0, 0, r + R * 0.07, 0, Math.PI * 2);
    x.fill();
    x.strokeStyle = col;
    x.lineWidth = R * 0.07;
    x.beginPath();
    x.arc(0, 0, r, 0, Math.PI * 2);
    x.stroke();
    const a = (t * 5) % (Math.PI * 2);
    x.fillStyle = "#fff";
    x.beginPath();
    x.arc(Math.cos(a) * r, Math.sin(a) * r, R * 0.055, 0, Math.PI * 2);
    x.fill();
  } else if (badge.kind === "bang" || badge.kind === "question") {
    const d = R * 0.3;
    x.save();
    x.rotate(Math.PI / 4);
    x.fillStyle = "rgba(0,0,0,0.85)";
    x.beginPath();
    x.roundRect(-d / 2 - R * 0.06, -d / 2 - R * 0.06, d + R * 0.12, d + R * 0.12, R * 0.08);
    x.fill();
    x.fillStyle = col;
    x.beginPath();
    x.roundRect(-d / 2, -d / 2, d, d, R * 0.05);
    x.fill();
    x.restore();
    if (!e.isMini) {
      x.fillStyle = "#fff";
      x.font = `800 ${R * 0.28}px ${FONT}`;
      x.textAlign = "center";
      x.textBaseline = "middle";
      x.fillText(badge.kind === "bang" ? "!" : "?", 0, R * 0.02);
    }
  } else {
    x.fillStyle = "rgba(0,0,0,0.85)";
    x.beginPath();
    x.arc(0, 0, R * 0.19, 0, Math.PI * 2);
    x.fill();
    x.strokeStyle = col;
    x.lineWidth = R * 0.05;
    x.beginPath();
    x.arc(0, 0, R * 0.12, 0, Math.PI * 2);
    x.stroke();
    x.fillStyle = col;
    x.beginPath();
    x.arc(0, 0, R * 0.05, 0, Math.PI * 2);
    x.fill();
  }
  x.restore();
}

// ── Particles ─────────────────────────────────────────────────────────────────

/** Love bubbles, gold sparkles, white sparks, sweat drops, sleep bubbles. */
export function drawAxenideParticles(e: AxEngine, x: CanvasRenderingContext2D, R: number, cx: number, cy: number) {
  for (const p of e.particles) {
    if (p.age <= 0) continue;
    const k = p.age / p.life;
    const a = Math.min(1, Math.max(0, k < 0.2 ? k / 0.2 : 1 - (k - 0.2) / 0.8));
    const px = cx + (p.x + p.vx * p.age) * R * 1.3;
    const py = cy + (p.y + p.vy * p.age) * R * 1.3;
    const sz = R * p.size * (1 + k * 0.4);
    x.save();
    x.translate(px, py);
    x.globalAlpha = a;
    switch (p.kind) {
      case "love":
        x.fillStyle = LOVE;
        x.beginPath();
        x.arc(0, 0, sz * 0.7, 0, Math.PI * 2);
        x.fill();
        x.fillStyle = "rgba(255,255,255,0.6)";
        x.beginPath();
        x.arc(-sz * 0.22, -sz * 0.22, sz * 0.18, 0, Math.PI * 2);
        x.fill();
        break;
      case "sparkle":
        x.rotate(p.spin * 0.2);
        x.fillStyle = GOLD;
        sparklePath(x, sz);
        x.fill();
        break;
      case "spark":
        x.rotate(p.spin);
        x.strokeStyle = "#fff";
        x.lineWidth = sz * 0.22;
        x.lineCap = "round";
        x.beginPath();
        x.moveTo(-sz * 0.6, 0);
        x.lineTo(sz * 0.6, 0);
        x.moveTo(0, -sz * 0.6);
        x.lineTo(0, sz * 0.6);
        x.stroke();
        break;
      case "drop":
        x.fillStyle = "#7CC7FF";
        x.beginPath();
        x.ellipse(0, 0, sz * 0.38, sz * 0.55, 0, 0, Math.PI * 2);
        x.fill();
        break;
      case "sleep":
        x.strokeStyle = "rgb(205,214,235)";
        x.lineWidth = Math.max(1, sz * 0.16);
        x.beginPath();
        x.arc(0, 0, sz * 0.55, 0, Math.PI * 2);
        x.stroke();
        break;
    }
    x.restore();
  }
}
