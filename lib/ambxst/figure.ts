// Port only (his ask): the third mascot, Axenide: the Ambxst logo (its two lobes and
// the channel between them) drawn in the mascot's style: lit and puffed up like
// his body, the eye in the body a hole punched through it, the other eye a
// sphere of the body's colour sitting in the channel. Both eyes look around,
// blink and take the mascot's expressions, each kept to its own side of the curve
// that divides them.
//
// Geometry: the Ambxst icon SVG (its outline flattened below; the two
// eyes are its two 3.5-unit circles).

type RGB = [number, number, number];

/* the logo's outline: start point, then relative cubic segments (dx1 dy1 dx2 dy2 dx dy) */
const START: [number, number] = [156.79095, 117.19853];
const CUBICS = [
  -4.89824, 0.25259, -11.04449, 9.64748, -15.98766, 9.68571, -4.52052, -0.27272, -3.40363, -8.06894, -6.99027, -7.54785,
  -5.99291, 1.33732, -2.48077, 11.9217, -3.96978, 13.58521, -1.36997, 1.53053, -5.43253, -0.66601, -6.7076, 1.76114,
  -1.86817, 3.55617, 4.90849, 6.02938, 5.69681, 9.34103, 0.63306, 2.65946, -2.55931, 4.78592, -1.37666, 7.3241,
  0.2357, 0.50584, 0.67102, 0.93142, 1.38337, 1.21646, 6.30801, 0.88795, 9.45855, -3.36269, 11.8861, -8.73487,
  1.61065, -3.78124, 8.22244, -18.92421, 11.70988, -16.89871, 2.47548, 1.43768, -1.28347, 4.8099, 0.29972, 6.2544,
  1.22957, 1.12185, 4.26137, -1.81865, 5.425, -0.10645, 0.89239, 1.31314, -3.09239, 3.60396, -3.01119, 6.67349,
  0.0249, 0.94167, 1.58497, 1.7074, 1.69085, 2.56057, 0.3692, 2.97505, -6.70276, 2.22446, -6.46937, 6.03891,
  4.28287, -3.84931, 12.57479, -1.38901, 12.80749, -4.83433, 0.17861, -2.64438, -3.71806, -2.88969, -4.13567, -4.8395,
  -0.62786, -2.93152, 6.47149, -5.82398, 5.02037, -8.83977, -1.50182, -3.12115, -5.67109, -0.11317, -6.56446, -1.29553,
  -1.52337, -2.01618, 4.90809, -8.428, 1.30896, -10.83861, -0.64166, -0.39099, -1.31615, -0.54148, -2.01589, -0.5054,
];
const LOGO = { x0: 122.81127, y0: 117.19335, w: 41.447163, h: 35.488789 };
/* the eyes: the hole in the body (left) and the dot in the channel (right) */
const HOLE = { x: 135.45168, y: 141.26113 };
const DOT = { x: 147.89847, y: 139.75062 };
const EYE_R = 3.5;

/** The outline as points, the logo's centre at 0, 1 unit = its width. */
const POLY: Array<[number, number]> = (() => {
  const cx = LOGO.x0 + LOGO.w / 2, cy = LOGO.y0 + LOGO.h / 2;
  const pts: Array<[number, number]> = [];
  let [x, y] = START;
  pts.push([x, y]);
  for (let i = 0; i < CUBICS.length; i += 6) {
    const [a, b, c, d, e, f] = CUBICS.slice(i, i + 6);
    const p1 = [x + a, y + b], p2 = [x + c, y + d], p3 = [x + e, y + f];
    for (let k = 1; k <= 10; k++) {
      const t = k / 10, u = 1 - t;
      pts.push([
        u * u * u * x + 3 * u * u * t * p1[0] + 3 * u * t * t * p2[0] + t * t * t * p3[0],
        u * u * u * y + 3 * u * u * t * p1[1] + 3 * u * t * t * p2[1] + t * t * t * p3[1],
      ]);
    }
    [x, y] = p3;
  }
  return pts.map(([px, py]) => [(px - cx) / LOGO.w, (py - cy) / LOGO.w]);
})();
const unit = (p: { x: number; y: number }) => ({ x: (p.x - (LOGO.x0 + LOGO.w / 2)) / LOGO.w, y: (p.y - (LOGO.y0 + LOGO.h / 2)) / LOGO.w });
/* (his ask: the eyes a little further apart than the logo's: each 0.03 out,
   which also leaves each more room from the curve between them) */
const SPREAD = 0.03;
const HOLE_U = { x: unit(HOLE).x - SPREAD, y: unit(HOLE).y }, DOT_U = { x: unit(DOT).x + SPREAD, y: unit(DOT).y };
const EYE_RU = EYE_R / LOGO.w;
/** The logo's height for a width of 1. */
export const ASPECT = LOGO.h / LOGO.w;

/** Signed distance to the outline (logo units, negative inside). */
function sd(px: number, py: number): number {
  let inside = false, d = Infinity;
  for (let i = 0, j = POLY.length - 1; i < POLY.length; j = i++) {
    const [xi, yi] = POLY[i], [xj, yj] = POLY[j];
    if ((yi > py) !== (yj > py) && px < ((xj - xi) * (py - yi)) / (yj - yi) + xi) inside = !inside;
    const ex = xj - xi, ey = yj - yi;
    const t = Math.max(0, Math.min(1, ((px - xi) * ex + (py - yi) * ey) / (ex * ex + ey * ey || 1)));
    d = Math.min(d, Math.hypot(px - xi - ex * t, py - yi - ey * t));
  }
  return inside ? -d : d;
}

/* each eye's room at rest: how far its edge may come to the dividing curve */
const HOLE_CLEAR = Math.min(EYE_RU + 0.012, -sd(HOLE_U.x, HOLE_U.y));
const DOT_CLEAR = Math.min(EYE_RU + 0.012, sd(DOT_U.x, DOT_U.y));

/**
 * Where an eye can be looking toward `want` (offset from rest, logo units):
 * as far along the way as it can go and stay its own side of the curve.
 */
function reach(rest: { x: number; y: number }, want: { x: number; y: number }, hole: boolean, r: number) {
  const ok = (x: number, y: number) => {
    const d = sd(x, y);
    return hole ? -d >= Math.min(HOLE_CLEAR, r + 0.012) : d >= Math.min(DOT_CLEAR, r + 0.012);
  };
  if (ok(rest.x + want.x, rest.y + want.y)) return { x: rest.x + want.x, y: rest.y + want.y };
  let lo = 0, hi = 1;
  for (let i = 0; i < 8; i++) {
    const m = (lo + hi) / 2;
    if (ok(rest.x + want.x * m, rest.y + want.y * m)) lo = m; else hi = m;
  }
  return { x: rest.x + want.x * lo, y: rest.y + want.y * lo };
}

/* the eyes' own reach (the head turns too: TURN), a share of the logo's width */
const LOOK = { x: 0.035, y: 0.025 };
/* the head's turn toward where it looks: a shift, the side squashed, the eyes
   (on its front) moving a little further than the body */
const TURN = { x: 0.03, y: 0.022, squash: 0.07, eyes: 0.018 };

export interface Turn { x: number; y: number }
const NO_TURN: Turn = { x: 0, y: 0 };
const clamp1 = (v: number) => Math.max(-1, Math.min(1, v));

/* ── the box (his ask: a file over him, he turns into the mascot's box) ── */

const N = 120;
/** The outline resampled to N points evenly along it, from its rightmost point. */
const LOGO_N: Array<[number, number]> = (() => {
  const len: number[] = [0];
  for (let i = 1; i <= POLY.length; i++) {
    const [ax, ay] = POLY[i - 1], [bx, by] = POLY[i % POLY.length];
    len.push(len[i - 1] + Math.hypot(bx - ax, by - ay));
  }
  let start = 0;
  for (let i = 1; i < POLY.length; i++) if (POLY[i][0] > POLY[start][0]) start = i;
  const total = len[POLY.length], s0 = len[start];
  const out: Array<[number, number]> = [];
  let j = 0;
  for (let k = 0; k < N; k++) {
    const want = (s0 + (k / N) * total) % total;
    j = 0;
    while (len[j + 1] < want) j++;
    const t = (want - len[j]) / (len[j + 1] - len[j] || 1);
    const [ax, ay] = POLY[j], [bx, by] = POLY[(j + 1) % POLY.length];
    out.push([ax + (bx - ax) * t, ay + (by - ay) * t]);
  }
  return out;
})();
/** Which way round the outline goes (the box is sampled the same way). */
const WINDING = (() => {
  let a = 0;
  for (let i = 0; i < POLY.length; i++) {
    const [x0, y0] = POLY[i], [x1, y1] = POLY[(i + 1) % POLY.length];
    a += x0 * y1 - x1 * y0;
  }
  return a >= 0 ? 1 : -1;
})();
/** The mascot's box (upload/canvas.ts at morph 1: a superellipse, n 5.5), half-sizes rx × ry, N points evenly along it from (rx, 0). */
function boxPoints(rx: number, ry: number): Array<[number, number]> {
  const fine: Array<[number, number]> = [];
  for (let i = 0; i <= 720; i++) {
    const a = WINDING * (i / 720) * Math.PI * 2, c = Math.cos(a), si = Math.sin(a);
    fine.push([rx * Math.sign(c) * Math.pow(Math.abs(c), 2 / 5.5), ry * Math.sign(si) * Math.pow(Math.abs(si), 2 / 5.5)]);
  }
  const len: number[] = [0];
  for (let i = 1; i < fine.length; i++) len.push(len[i - 1] + Math.hypot(fine[i][0] - fine[i - 1][0], fine[i][1] - fine[i - 1][1]));
  const total = len[len.length - 1];
  const out: Array<[number, number]> = [];
  let j = 0;
  for (let k = 0; k < N; k++) {
    const want = (k / N) * total;
    while (len[j + 1] < want) j++;
    const t = (want - len[j]) / (len[j + 1] - len[j] || 1);
    out.push([fine[j][0] + (fine[j + 1][0] - fine[j][0]) * t, fine[j][1] + (fine[j + 1][1] - fine[j][1]) * t]);
  }
  return out;
}
const boxCache = new Map<string, Array<[number, number]>>();

/** How the figure is posed: width `s` px; `m` 0 the logo … 1 the mascot's box (half-sizes R × 0.94R); the head's turn. */
export interface Pose { s: number; m?: number; R?: number; turn?: Turn }

const smooth = (a: number, b: number, x: number) => {
  const t = Math.min(1, Math.max(0, (x - a) / (b - a)));
  return t * t * (3 - 2 * t);
};

/** The figure's outline points, px, its centre at 0. */
function points(p: Pose): Array<[number, number]> {
  const s = p.s, m = Math.max(0, Math.min(1.08, p.m ?? 0)), t = p.turn ?? NO_TURN;
  const dx = clamp1(t.x) * TURN.x * s, dy = clamp1(t.y) * TURN.y * s, kx = 1 - TURN.squash * Math.abs(clamp1(t.x));
  let src: Array<[number, number]>;
  if (m < 0.001) src = POLY.map(([x, y]) => [x * s, y * s]);
  else {
    const R = p.R ?? s / 2.417;
    const key = `${Math.round(R * 10)}`;
    let box = boxCache.get(key);
    if (!box) {
      box = boxPoints(R, R * 0.94);
      if (boxCache.size > 40) boxCache.clear();
      boxCache.set(key, box);
    }
    src = LOGO_N.map(([x, y], i) => [x * s + (box![i][0] - x * s) * m, y * s + (box![i][1] - y * s) * m]);
  }
  return src.map(([x, y]) => [x * kx + dx, y + dy]);
}

function trace(ctx: CanvasRenderingContext2D, pts: Array<[number, number]>, dx = 0, dy = 0) {
  ctx.moveTo(pts[0][0] + dx, pts[0][1] + dy);
  for (let i = 1; i < pts.length; i++) ctx.lineTo(pts[i][0] + dx, pts[i][1] + dy);
  ctx.closePath();
}

/** A real clip: the greeting's staged canvas turns clip() off (its card's), and offers realClip(). */
function clipTo(ctx: CanvasRenderingContext2D) {
  const c = ctx as unknown as { realClip?: () => void };
  if (typeof c.realClip === "function") c.realClip();
  else ctx.clip();
}

/** The outline as a Path2D (the engine clips and fills with it). */
export function bodyPath(p: Pose): Path2D {
  const path = new Path2D();
  trace(path as unknown as CanvasRenderingContext2D, points(p));
  return path;
}

const mix = (a: RGB, b: RGB, t: number): RGB => [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t];
const css = (c: RGB, a = 1) => `rgba(${Math.round(c[0])},${Math.round(c[1])},${Math.round(c[2])},${a})`;

/**
 * The body, centred on the origin: lit from the upper left, darker toward its
 * edges (puffed up), a lit rim where an edge faces the light, a shadowed one
 * where it faces away, a gloss on each lobe. `top`/`bottom`: its colour, 0–255.
 */
export function drawBody(ctx: CanvasRenderingContext2D, p: Pose, top: RGB, bottom: RGB, light = true) {
  const s = p.s, pts = points(p);
  const hgt = s * ASPECT;
  const g = ctx.createLinearGradient(-s * 0.35, -hgt * 0.5, s * 0.4, hgt * 0.5);
  g.addColorStop(0, css(top));
  g.addColorStop(1, css(bottom));
  ctx.beginPath();
  trace(ctx, pts);
  ctx.fillStyle = g;
  ctx.fill();
  if (!light) return;
  ctx.save();
  ctx.beginPath();
  trace(ctx, pts);
  clipTo(ctx);
  // Puffed: each band nearer the edge a little darker.
  ctx.lineJoin = "round";
  for (let k = 4; k >= 1; k--) {
    ctx.beginPath();
    trace(ctx, pts);
    ctx.lineWidth = s * 0.05 * k;
    ctx.strokeStyle = "rgba(0,0,0,0.05)";
    ctx.stroke();
  }
  // The rim facing the light (the body less itself moved away from the
  // light), then the one facing away, in soft steps.
  const big = s * 2;
  for (let i = 1; i <= 4; i++) {
    const d = s * 0.011 * i;
    ctx.beginPath();
    ctx.rect(-big, -big, 2 * big, 2 * big);
    trace(ctx, pts, d, d * 1.2);
    ctx.fillStyle = "rgba(255,255,255,0.085)";
    ctx.fill("evenodd");
    ctx.beginPath();
    ctx.rect(-big, -big, 2 * big, 2 * big);
    trace(ctx, pts, -d * 0.8, -d);
    ctx.fillStyle = "rgba(0,0,0,0.06)";
    ctx.fill("evenodd");
  }
  // A gloss on each lobe (one, on the box).
  const m = Math.min(1, p.m ?? 0);
  for (const [gx, gy, gr, a] of [[-0.2, -0.16, 0.2, 0.42], [0.26, -0.26, 0.12, 0.3 * (1 - m)]] as const) {
    if (a < 0.01) continue;
    const hl = ctx.createRadialGradient(gx * s, gy * s, 0, gx * s, gy * s, gr * s);
    hl.addColorStop(0, `rgba(255,255,255,${a})`);
    hl.addColorStop(1, "rgba(255,255,255,0)");
    ctx.fillStyle = hl;
    ctx.fillRect(-big, -big, 2 * big, 2 * big);
  }
  ctx.restore();
}

/** How an eye is drawn: the mascot's eye shape names (round ones become the logo's circles). */
export interface EyeOpts {
  /** Where they look, −1…1 each way (screen y down). */
  lookX: number;
  lookY: number;
  /** The mascot's eye shape. */
  shape: string;
  /** Open, 0–1 (the blink). */
  open: number;
  /** Eye size, ×1 the logo's. */
  scale: number;
  /** The mascot's blush, 0–1: a pink flush under each eye. */
  blush?: number;
  /** The state's colour wash (engine.ts drawBody's tint), laid over the sphere eye as over the body. */
  wash?: { rgb: string; alpha: number };
  /** What shows through a hole when it is drawn on the same canvas as what is
   *  behind him (the greeting's halo): a fill, in the figure's coordinates. */
  behind?: (ctx: CanvasRenderingContext2D, ox?: number, oy?: number) => CanvasGradient | string | null;
  /** Draws any other shape (the mascot's drawEyeShape) in the current fill/stroke at (0, 0), w × h. */
  shapeFn?: (shape: string, w: number, h: number, sd: number) => void;
}

const ROUND = new Set(["pill", "wide", "dot", "cup"]);

/** Where the two eyes are (px, centres) and how big, for pose `p`: the logo's, or the box's two. */
function eyesAt(p: Pose, o: { lookX: number; lookY: number; scale: number }) {
  const s = p.s, m = Math.min(1, Math.max(0, p.m ?? 0)), t = p.turn ?? NO_TURN;
  const r = EYE_RU * o.scale;
  const want = { x: clamp1(o.lookX) * LOOK.x, y: clamp1(o.lookY) * LOOK.y };
  const hole = reach(HOLE_U, want, true, r);
  const dot = reach(DOT_U, want, false, r);
  // On the box: the Coucou mascot's two eyes (engine.ts drawEyes at morph 1), looking freely.
  const R = p.R ?? s / 2.417;
  const bx = 0.41 * R, by = 0.2 * R, br = 0.15 * R;
  const lx = clamp1(o.lookX) * 0.12 * R, ly = clamp1(o.lookY) * 0.08 * R;
  const kx = 1 - TURN.squash * Math.abs(clamp1(t.x));
  const sx = clamp1(t.x) * (TURN.x + TURN.eyes) * s, sy = clamp1(t.y) * (TURN.y + TURN.eyes) * s;
  const at = (u: { x: number; y: number }, side: number) => ({
    x: (u.x * s + (side * bx + lx - u.x * s) * m) * kx + sx,
    y: u.y * s + (by + ly - u.y * s) * m + sy,
  });
  return { hole: at(hole, -1), dot: at(dot, 1), r: (r * s + (br * o.scale - r * s) * m), m };
}

/**
 * The eyes, after drawBody: the hole punched through the body (the canvas
 * shows what is behind), the sphere in the channel. On the box (m), the
 * sphere becomes a second hole.
 */
export function drawEyes(ctx: CanvasRenderingContext2D, p: Pose, color: RGB, o: EyeOpts) {
  const { hole, dot, r: R, m } = eyesAt(p, o);
  const round = ROUND.has(o.shape);
  const open = Math.max(0.08, Math.min(1, o.open));
  const k = smooth(0.15, 0.6, m);

  // The blush: under each eye, on the body only.
  if ((o.blush ?? 0) > 0.01) {
    ctx.save();
    ctx.beginPath();
    trace(ctx, points(p));
    clipTo(ctx);
    for (const e of [hole, dot]) {
      const bx = e.x, by = e.y + R * 1.35;
      const g = ctx.createRadialGradient(bx, by, 0, bx, by, R * 1.1);
      g.addColorStop(0, `rgba(255,120,150,${0.5 * (o.blush ?? 0)})`);
      g.addColorStop(1, "rgba(255,120,150,0)");
      ctx.fillStyle = g;
      ctx.fillRect(bx - R * 1.2, by - R * 1.2, R * 2.4, R * 2.4);
    }
    ctx.restore();
  }

  // A hole: punched out, its rim bevelled (shade where the surface dips away
  // from the light, light where it rises toward it).
  const punch = (x: number, y: number, hr: number, side: number) => {
    if (hr < 0.3) return;
    ctx.save();
    // What was behind him, back under the punched hole (drawn under it,
    // in the figure's own coordinates, where its gradient was made).
    const back = round && o.behind ? o.behind(ctx) : null;
    if (back) {
      ctx.save();
      ctx.globalCompositeOperation = "destination-out";
      ctx.beginPath();
      ctx.ellipse(x, y, hr, hr * open, 0, 0, Math.PI * 2);
      ctx.fillStyle = "#000";
      ctx.fill();
      ctx.globalCompositeOperation = "destination-over";
      ctx.fillStyle = back;
      ctx.fill();
      ctx.restore();
    }
    ctx.translate(x, y);
    if (round) {
      ctx.scale(1, open);
      if (!back) {
        ctx.globalCompositeOperation = "destination-out";
        ctx.beginPath();
        ctx.arc(0, 0, hr, 0, Math.PI * 2);
        ctx.fillStyle = "#000";
        ctx.fill();
        ctx.globalCompositeOperation = "source-over";
      }
      const rim = ctx.createLinearGradient(-hr, -hr, hr, hr);
      rim.addColorStop(0, "rgba(0,0,0,0.32)");
      rim.addColorStop(0.5, "rgba(0,0,0,0.05)");
      rim.addColorStop(1, "rgba(255,255,255,0.35)");
      ctx.beginPath();
      ctx.arc(0, 0, hr + hr * 0.14, 0, Math.PI * 2);
      ctx.lineWidth = hr * 0.28;
      ctx.strokeStyle = rim;
      ctx.stroke();
    } else if (o.shapeFn) {
      ctx.globalCompositeOperation = "destination-out";
      ctx.fillStyle = "#000";
      ctx.strokeStyle = "#000";
      o.shapeFn(o.shape, hr * 1.6, hr * 1.8, side);
      // The halo back in the cut (only the cut is clear round here: the
      // halo fills everything around his eye).
      // (The very same strokes, under: the halo is see-through, so only the cut takes it.)
      const behind = o.behind ? o.behind(ctx, -x, -y) : null;
      if (behind) {
        ctx.globalCompositeOperation = "destination-over";
        ctx.fillStyle = behind;
        ctx.strokeStyle = behind;
        o.shapeFn(o.shape, hr * 1.6, hr * 1.8, side);
      }
      ctx.globalCompositeOperation = "source-over";
    }
    ctx.restore();
  };
  punch(hole.x, hole.y, R, -1);
  punch(dot.x, dot.y, R * k, 1);

  // The sphere: the body's colour, softly lit (his ask: not glaring), a small glint.
  const SR = R * (1 - k);
  if (SR < 0.3) return;
  ctx.save();
  ctx.translate(dot.x, dot.y);
  const lit = mix(color, [255, 255, 255], 0.22), dark = mix(color, [0, 0, 0], 0.18);
  const g = ctx.createRadialGradient(-SR * 0.3, -SR * 0.35 * open, SR * 0.1, 0, 0, SR * 1.05);
  g.addColorStop(0, css(lit));
  g.addColorStop(0.6, css(color));
  g.addColorStop(1, css(dark));
  if (round) {
    ctx.scale(1, open);
    ctx.beginPath();
    ctx.arc(0, 0, SR, 0, Math.PI * 2);
    ctx.fillStyle = g;
    ctx.fill();
    if (o.wash && o.wash.alpha > 0.01) {
      // The same wash as the body under it, from the figure's bottom up
      // (here moved to the eye and squashed by the blink).
      const h = p.s * ASPECT;
      const wg = ctx.createLinearGradient(0, (h / 2 - dot.y) / open, 0, (-h / 2 - dot.y) / open);
      wg.addColorStop(0, `rgba(${o.wash.rgb},${0.72 * o.wash.alpha})`);
      wg.addColorStop(1, `rgba(${o.wash.rgb},0)`);
      ctx.fillStyle = wg;
      ctx.fill();
    }
    if (open > 0.5) {
      ctx.beginPath();
      ctx.arc(-SR * 0.34, -SR * 0.36, SR * 0.13, 0, Math.PI * 2);
      ctx.fillStyle = "rgba(255,255,255,0.32)";
      ctx.fill();
    }
  } else if (o.shapeFn) {
    ctx.fillStyle = g;
    ctx.strokeStyle = g;
    o.shapeFn(o.shape, SR * 1.6, SR * 1.8, 1);
    // The state's wash over it too (finished's happy arcs, error's flat eye…).
    if (o.wash && o.wash.alpha > 0.01) {
      const h = p.s * ASPECT;
      const wg = ctx.createLinearGradient(0, h / 2 - dot.y, 0, -h / 2 - dot.y);
      wg.addColorStop(0, `rgba(${o.wash.rgb},${0.72 * o.wash.alpha})`);
      wg.addColorStop(1, `rgba(${o.wash.rgb},0)`);
      ctx.fillStyle = wg;
      ctx.strokeStyle = wg;
      o.shapeFn(o.shape, SR * 1.6, SR * 1.8, 1);
    }
  }
  ctx.restore();
}
