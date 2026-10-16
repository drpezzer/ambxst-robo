// Port only (his ask): Robo drawn flat, styled to look like robot-heads' 3D
// head — the same shapes, faces, motion and lights (tv/geometry, tv/faces,
// tv/sim, tv/light), but a handful of gradient-filled paths a frame instead of
// ~2 000 lit quads and off-screen textures. On Qt every canvas-to-canvas copy
// is a pixel snapshot the GC doesn't count (they ran to gigabytes), and the
// meshes cost a core: this draws straight onto the canvas, no images at all.
//
// The turn is a card with thickness, projected as the 3D head is: the face
// plate in its own plane, the shell as slices of the outline from the far face
// to the near one, the ears and the antenna's collar as domes at their real
// spots (mid-height on the sides, the middle of the top), so the face hides
// what is behind it.

import { HEAD, INSET, type Shape } from "./tv/geometry";
import { COLS, FACES, LIGHTS, ROWS, makeGrid, type Grid } from "./tv/faces";
import { css, radiance, type Material } from "./tv/light";
import type { RobotPose, RobotSim } from "./tv/sim";
import type { Frame, Palette, RenderOptions } from "./tv/render";
import type { RobotHeadState } from "./types";

type RGB = [number, number, number];
const mix = (a: RGB, b: RGB, t: number): RGB => [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t];
const smooth = (a: number, b: number, x: number) => {
  const t = Math.min(1, Math.max(0, (x - a) / (b - a)));
  return t * t * (3 - 2 * t);
};
const rgba = (c: RGB, a: number) => `rgba(${Math.round(c[0])},${Math.round(c[1])},${Math.round(c[2])},${a})`;
/** A material lit from a normal (the 3D renderer's light model, sampled). */
const lit = (m: Material, nx: number, ny: number, nz: number) => {
  const l = Math.hypot(nx, ny, nz) || 1;
  return css(radiance(m, nx / l, ny / l, nz / l));
};

const glassOf = (s: Shape) => ({ hx: s.hx - INSET.glass, hy: s.hy - INSET.glass });
const EAR_R = 0.084;
const VENTS = [-0.12, -0.065, -0.01, 0.045, 0.1];
/**
 * ctx.transform(a…f), built from translate, rotate and scale: Qt's transform()
 * multiplies on the wrong side (the new matrix goes before the current one, so
 * it scales the head's own placement). The linear part split as Rot · Scale · Rot.
 */
function affine(ctx: CanvasRenderingContext2D, a: number, b: number, c: number, d: number, e: number, f: number) {
  const E = (a + d) / 2, F = (a - d) / 2, G = (b + c) / 2, H = (b - c) / 2;
  const Q = Math.hypot(E, H), R = Math.hypot(F, G);
  const a1 = Math.atan2(G, F), a2 = Math.atan2(H, E);
  ctx.translate(e, f);
  ctx.rotate((a2 + a1) / 2);
  ctx.scale(Q + R, Q - R);
  ctx.rotate((a2 - a1) / 2);
}
/**
 * Port (his ask): a file dragged over Robo. `drop` (0–1) sinks the antenna
 * until its bulb is flush with the top of the head; `slot` (0–1) opens a
 * glowing slot there: the bulb (or, with no antenna, a dot from nothing)
 * stretched sideways into a slit.
 */
export interface DropOptions {
  drop?: number;
  slot?: number;
  /** The slot's glow (the upload's green by default). */
  slotColor?: RGB;
}
type Proj = (x: number, y: number, z: number) => { x: number; y: number; w: number };
type V3 = [number, number, number];
type Dome = (b: V3, a: V3, u: V3, v: V3, r: number) => void;

export class FlatRobotRenderer {
  /** (The 3D renderer's detail hint; unused here.) */
  unitPerBox = 1;
  private grid: Grid = makeGrid(COLS, ROWS);
  private gridPrev: Grid = makeGrid(COLS, ROWS);
  private gridFor: Shape | null = null;

  /** The LED matrix for this frame (render.ts compose, unchanged). */
  private compose(sim: RobotSim | null, state: RobotHeadState, shape: Shape): Grid {
    if (this.gridFor !== shape) {
      const gl = glassOf(shape);
      this.grid = makeGrid(Math.ceil((gl.hx * 2) / shape.pitch), Math.ceil((gl.hy * 2) / shape.pitch));
      this.gridPrev = makeGrid(this.grid.cols, this.grid.rows);
      this.gridFor = shape;
    }
    const grid = this.grid;
    const g = grid.v;
    const { cols, rows } = grid;
    g.fill(0);
    if (!sim) {
      FACES[state](grid, { lookX: 0, lookY: 0, blink: 0, time: 0.4, side: 1, seed: 0 });
      return grid;
    }
    FACES[sim.shown](grid, sim.face);
    if (sim.switched < 0.3) {
      const p = this.gridPrev;
      p.v.fill(0);
      FACES[sim.previous](p, { ...sim.face, time: sim.face.time + 10 });
      const k = sim.switched / 0.3;
      for (let i = 0; i < g.length; i++) g[i] = g[i] * k + p.v[i] * (1 - k);
      if (sim.switched < 0.13) {
        const seed = Math.floor(sim.time * 30);
        for (let r = 0; r < rows; r++) {
          const shift = Math.floor((Math.sin(seed * 12.9 + r * 78.2) * 0.5 + 0.5) * 3) - 1;
          if (!shift) continue;
          const row = g.slice(r * cols, (r + 1) * cols);
          for (let c = 0; c < cols; c++) g[r * cols + c] = row[(c - shift + cols) % cols];
        }
        for (let i = 0; i < g.length; i++) if (Math.sin(i * 91.7 + seed * 3.1) > 0.93) g[i] = Math.max(g[i], 0.3);
      }
    }
    if (sim.age < 0.55) {
      const open = smooth(0.08, 0.5, sim.age) * (rows / 2 + 0.5);
      for (let r = 0; r < rows; r++) {
        const d = Math.abs(r - (rows - 1) / 2);
        for (let c = 0; c < cols; c++) {
          const i = r * cols + c;
          if (d > open) g[i] = 0;
          else if (d > open - 1.2) g[i] = Math.max(g[i], 0.85 * (1 - sim.age / 0.55));
        }
      }
    }
    return grid;
  }

  draw(ctx: CanvasRenderingContext2D, frame: Frame, dpr: number, pose: RobotPose, sim: RobotSim | null,
    state: RobotHeadState, shape: Shape, palette: Palette, opts: RenderOptions & DropOptions) {
    const U = frame.unit * dpr;
    const small = U < 70; // minis: no screws, no LED grid lines
    const shown = sim ? sim.shown : state;
    const lightNow = LIGHTS[shown];
    let led: RGB = (lightNow.screen ?? palette.led) as RGB;
    if (sim && sim.switched < 0.3) {
      const was = (LIGHTS[sim.previous].screen ?? palette.led) as RGB;
      led = mix(was, led, sim.switched / 0.3);
    }

    // The turn, projected as robot-heads does (Yaw · Pitch; roll is the canvas's).
    // (Never quite edge-on: a plane squashed to nothing draws nothing.)
    const cy0 = Math.cos(pose.yaw), sy = Math.sin(pose.yaw);
    const cy = cy0 < 0 ? Math.min(cy0, -0.02) : Math.max(cy0, 0.02);
    const cp = Math.cos(pose.pitch), sp = Math.sin(pose.pitch);
    /** A head point on screen (head units), and how near it is. */
    const P = (x: number, y: number, z: number) => ({ x: cy * x + sy * sp * y + sy * cp * z, y: cp * y - sp * z, w: -sy * x + cy * sp * y + cy * cp * z });
    /** Draws in the plane z of the head (a face, or a slice of the shell). */
    const plane = (z: number) => affine(ctx, cy, 0, sy * sp, cp, z * sy * cp, -z * sp);
    const D = shape.depth / 2;
    const front = cy * cp >= 0;
    const near = front ? D : -D;

    // Where the head is: its centre, lifted, scaled about its bottom, rolled.
    const cxPx = frame.cx * dpr + pose.x * U;
    const cyPx = frame.cy * dpr - pose.lift * U;
    ctx.save();
    ctx.translate(cxPx, cyPx + shape.hy * U);
    ctx.scale(pose.sx, pose.sy);
    ctx.translate(0, -shape.hy * U);
    ctx.rotate(pose.roll);
    ctx.scale(U, U);

    const trimLit = lit(palette.trim, 0, -0.3, 1);
    const trimDark = lit(palette.trim, 0, 0.6, 0.6);

    /** A dome of trim on the shell (an ear, the antenna's collar): base centre
     *  b, pointing along a (a unit axis), radius r. Seen as its sphere's disc,
     *  cut to the half outside the shell, plus its base disc. */
    const dome = (b: [number, number, number], a: [number, number, number], u: [number, number, number], v: [number, number, number], r: number) => {
      const c = P(b[0], b[1], b[2]);
      const o = P(a[0], a[1], a[2]);
      const pu = P(u[0], u[1], u[2]), pv = P(v[0], v[1], v[2]);
      ctx.save();
      ctx.beginPath();
      for (let i = 0; i <= 24; i++) {
        const t = (i / 24) * Math.PI * 2;
        const x = c.x + r * (Math.cos(t) * pu.x + Math.sin(t) * pv.x), y = c.y + r * (Math.cos(t) * pu.y + Math.sin(t) * pv.y);
        if (i) ctx.lineTo(x, y); else ctx.moveTo(x, y);
      }
      ctx.closePath();
      const ol = Math.hypot(o.x, o.y);
      if (ol > 0.04) {
        const nx = o.x / ol, ny = o.y / ol, k = r * 3;
        ctx.moveTo(c.x - ny * k, c.y + nx * k);
        ctx.lineTo(c.x - ny * k + nx * k, c.y + nx * k + ny * k);
        ctx.lineTo(c.x + ny * k + nx * k, c.y - nx * k + ny * k);
        ctx.lineTo(c.x + ny * k, c.y - nx * k);
        ctx.closePath();
      }
      ctx.clip();
      const g = ctx.createRadialGradient(c.x - r * 0.35, c.y - r * 0.45, r * 0.08, c.x, c.y, r * 1.05);
      g.addColorStop(0, trimLit);
      g.addColorStop(1, trimDark);
      ctx.beginPath();
      ctx.arc(c.x, c.y, r, 0, Math.PI * 2);
      ctx.fillStyle = g;
      ctx.fill();
      ctx.restore();
    };
    // Ears: on the sides at mid-height, halfway through the depth.
    const ear = (dir: number) => dome([dir * shape.earX, HEAD.earY, 0], [dir, 0, 0], [0, 0, 1], [0, 1, 0], EAR_R);
    const farEar = sy >= 0 ? 1 : -1;
    ear(farEar);

    // The shell: the outline in slices from the far face to the near one, lit
    // as the side that shows.
    const turn = Math.max(Math.abs(sy), Math.abs(sp));
    if (turn > 0.01) {
      const sgn = sy >= 0 ? 1 : -1;
      ctx.fillStyle = lit(palette.shell, -cy * sgn, -0.1 + sp * 0.5, Math.abs(sy) + 0.2);
      const steps = Math.max(2, Math.min(small ? 6 : 12, Math.ceil((shape.depth * turn) / (small ? 0.02 : 0.012))));
      for (let i = 0; i < steps; i++) {
        ctx.save();
        plane(-near + ((2 * near) * i) / steps);
        ctx.beginPath();
        shape.path(ctx, 0);
        ctx.fill();
        ctx.restore();
      }
    }
    ear(-farEar);

    // The antenna stands in the middle of the top: behind the face, unless
    // its bulb leans out past it.
    const drop = opts.antenna ? Math.min(1, Math.max(0, opts.drop ?? 0)) : 0;
    const slot = Math.min(1, Math.max(0, opts.slot ?? 0));
    // The slot on top, then (unless it has taken its place) the antenna.
    this.slotRect = null;
    if (slot > 0.001) this.slot(ctx, shape, P, opts.antenna, slot, opts.slotColor ?? [52, 212, 153], cxPx, cyPx, U, pose, dpr);
    const showAntenna = !(opts.antenna && slot > 0.001);
    const bulbOut = showAntenna && drop < 0.01 && this.bulbDepth(pose, shape, P) > Math.abs(cy * cp) * D + 0.02;
    if (showAntenna && !bulbOut) this.antenna(ctx, pose, sim, shown, lightNow, shape, palette, opts.antenna, P, dome, drop);

    // The face (or the back), in its plane.
    ctx.save();
    plane(near);
    const nx = sy * cp * (front ? 1 : -1);
    const vg = ctx.createLinearGradient(0, -shape.hy, 0, shape.hy);
    vg.addColorStop(0, lit(palette.shell, nx, -0.55, 0.85));
    vg.addColorStop(0.45, lit(palette.shell, nx, -0.15, 1));
    vg.addColorStop(1, lit(palette.shell, nx, 0.6, 0.8));
    ctx.beginPath();
    shape.path(ctx, 0);
    ctx.fillStyle = vg;
    ctx.fill();
    // The rolled edge: a lighter rim inside the outline, darker at the bottom.
    const rimW = HEAD.bevel * 0.55;
    const rg = ctx.createLinearGradient(0, -shape.hy, 0, shape.hy);
    rg.addColorStop(0, "rgba(255,255,255,0.32)");
    rg.addColorStop(0.5, "rgba(255,255,255,0.06)");
    rg.addColorStop(1, "rgba(0,0,0,0.22)");
    ctx.beginPath();
    shape.path(ctx, rimW * 0.5);
    ctx.lineWidth = rimW;
    ctx.strokeStyle = rg;
    ctx.stroke();
    // A soft highlight on the upper left, the key light's window.
    const hl = ctx.createRadialGradient(-shape.hx * 0.45, -shape.hy * 0.6, 0, -shape.hx * 0.45, -shape.hy * 0.6, shape.hx * 0.9);
    hl.addColorStop(0, "rgba(255,255,255,0.22)");
    hl.addColorStop(1, "rgba(255,255,255,0)");
    // (Filled as the outline itself, not a clipped square: a clip didn't
    // always hold on the island's canvas, and the square's corner showed.)
    ctx.beginPath();
    shape.path(ctx, 0);
    ctx.fillStyle = hl;
    ctx.fill();

    if (front) this.face(ctx, shape, sim, state, led, small, pose);
    else this.back(ctx, shape, palette, small);
    ctx.restore();

    if (bulbOut) this.antenna(ctx, pose, sim, shown, lightNow, shape, palette, opts.antenna, P, dome, 0);
    ctx.restore();
  }

  /** Port: the open slot on the canvas (CSS px), for a file to aim at; null when shut. */
  slotRect: { x: number; y: number; w: number; h: number } | null = null;

  /** The slot in the top of the head (DropOptions), lit from inside. */
  private slot(ctx: CanvasRenderingContext2D, shape: Shape, P: Proj, antenna: boolean, k: number, glow: RGB,
    cxPx: number, cyPx: number, U: number, pose: RobotPose, dpr: number) {
    const r0 = HEAD.ball;
    const wide = Math.min(0.22, shape.hx * 0.55);
    let a: number, b: number;
    if (antenna) {
      // The bulb, flush, stretched into a slit.
      const w = smooth(0, 1, k);
      a = r0 + (wide - r0) * w;
      b = r0 * (1 - 0.55 * w);
    } else {
      // A dot opening from nothing, then stretched.
      const o = smooth(0, 0.35, k), w = smooth(0.35, 1, k);
      a = (r0 + (wide - r0) * w) * o;
      b = r0 * (1 - 0.55 * w) * o;
    }
    if (a < 0.002) return;
    /* the top of the outline at x (the shell's surface there) */
    const topAt = (x: number) => {
      let lo = -shape.hy - 0.02, hi = 0;
      for (let i = 0; i < 14; i++) {
        const m = (lo + hi) / 2;
        if (shape.sd(x, m, 0) > 0) lo = m; else hi = m;
      }
      return hi;
    };
    const pts: Array<{ x: number; y: number }> = [];
    const N = 28;
    for (let i = 0; i < N; i++) {
      const t = (i / N) * Math.PI * 2, c = Math.cos(t), s = Math.sin(t);
      const x = a * Math.sign(c) * Math.pow(Math.abs(c), 0.5);
      const z = b * Math.sign(s) * Math.pow(Math.abs(s), 0.5);
      pts.push(P(x, topAt(x) + 0.002, z));
    }
    const path = () => {
      ctx.beginPath();
      pts.forEach((p, i) => (i ? ctx.lineTo(p.x, p.y) : ctx.moveTo(p.x, p.y)));
      ctx.closePath();
    };
    const c = P(0, topAt(0), 0);
    // The glow it throws on the shell round it.
    ctx.globalCompositeOperation = "lighter";
    ctx.save();
    ctx.translate(c.x, c.y);
    ctx.scale(1, 0.45);
    const R = a * 1.9 + 0.04;
    const g = ctx.createRadialGradient(0, 0, 0, 0, 0, R);
    g.addColorStop(0, rgba(glow, 0.5));
    g.addColorStop(1, rgba(glow, 0));
    ctx.fillStyle = g;
    ctx.fillRect(-R, -R, 2 * R, 2 * R);
    ctx.restore();
    ctx.globalCompositeOperation = "source-over";
    // The opening: dark, lit from inside, a bright lip.
    path();
    ctx.fillStyle = "#040506";
    ctx.fill();
    ctx.globalCompositeOperation = "lighter";
    path();
    ctx.fillStyle = rgba(glow, 0.55);
    ctx.fill();
    ctx.globalCompositeOperation = "source-over";
    path();
    ctx.lineWidth = 0.01;
    ctx.strokeStyle = rgba(mix(glow, [255, 255, 255], 0.55), 0.95);
    ctx.stroke();
    // Where it is on the canvas (the head's transforms, by hand).
    const cr = Math.cos(pose.roll), sr = Math.sin(pose.roll);
    let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
    for (const p of pts) {
      const X = cxPx + pose.sx * (p.x * cr - p.y * sr) * U;
      const Y = cyPx + shape.hy * U + pose.sy * (-shape.hy * U + (p.x * sr + p.y * cr) * U);
      x0 = Math.min(x0, X); x1 = Math.max(x1, X); y0 = Math.min(y0, Y); y1 = Math.max(y1, Y);
    }
    this.slotRect = { x: x0 / dpr, y: y0 / dpr, w: (x1 - x0) / dpr, h: (y1 - y0) / dpr };
  }

  /** How near the antenna's bulb is (to know whether the face hides it). */
  private bulbDepth(pose: RobotPose, shape: Shape, P: Proj) {
    const top = -shape.hy - 0.028, k = HEAD.stem + HEAD.ball * 0.8;
    const ax = pose.antennaX, az = pose.antennaZ;
    return P(Math.sin(ax) * k, top - Math.cos(ax) * Math.cos(az) * k, Math.sin(az) * k).w;
  }

  /** The screen: the hole, the dark glass, the LED matrix, its glow, the glass's sheen. */
  private face(ctx: CanvasRenderingContext2D, shape: Shape, sim: RobotSim | null, state: RobotHeadState, led: RGB, small: boolean, pose: RobotPose) {
    ctx.beginPath();
    shape.path(ctx, INSET.hole);
    ctx.fillStyle = "#060709";
    ctx.fill();
    ctx.save();
    ctx.beginPath();
    shape.path(ctx, INSET.glass);
    ctx.clip();
    const gl = glassOf(shape);
    const bg = ctx.createLinearGradient(0, -gl.hy, 0, gl.hy);
    bg.addColorStop(0, "#10141b");
    bg.addColorStop(1, "#07090d");
    ctx.fillStyle = bg;
    ctx.beginPath();
    shape.path(ctx, INSET.glass);
    ctx.fill();

    const grid = this.compose(sim, state, shape);
    const { cols, rows, v: g } = grid;
    const pitch = shape.pitch;
    const x0 = -(cols * pitch) / 2, y0 = -(rows * pitch) / 2;
    // The LED wells: a faint grid (lines, not cells: a few dozen strokes).
    if (!small) {
      ctx.strokeStyle = "rgba(255,255,255,0.045)";
      ctx.lineWidth = pitch * 0.18;
      ctx.beginPath();
      for (let c = 0; c <= cols; c++) { ctx.moveTo(x0 + c * pitch, y0); ctx.lineTo(x0 + c * pitch, y0 + rows * pitch); }
      for (let r = 0; r <= rows; r++) { ctx.moveTo(x0, y0 + r * pitch); ctx.lineTo(x0 + cols * pitch, y0 + r * pitch); }
      ctx.stroke();
    }
    // The lit LEDs, then their glow (the same cells, bigger and faint, added).
    const core = mix(led, [255, 255, 255], 0.6);
    const cell = pitch * 0.8, off = (pitch - cell) / 2;
    for (let r = 0; r < rows; r++) {
      for (let c = 0; c < cols; c++) {
        const v = g[r * cols + c];
        if (v < 0.01) continue;
        ctx.fillStyle = rgba(led, Math.min(1, v * 0.45));
        ctx.fillRect(x0 + c * pitch + off * 0.4, y0 + r * pitch + off * 0.4, pitch - off * 0.8, pitch - off * 0.8);
        ctx.fillStyle = rgba(core, Math.min(1, v));
        ctx.fillRect(x0 + c * pitch + off, y0 + r * pitch + off, cell, cell);
      }
    }
    ctx.globalCompositeOperation = "lighter";
    for (let r = 0; r < rows; r++) {
      for (let c = 0; c < cols; c++) {
        const v = g[r * cols + c];
        if (v < 0.05) continue;
        ctx.fillStyle = rgba(led, Math.min(0.35, v * 0.22));
        ctx.fillRect(x0 + (c - 0.7) * pitch, y0 + (r - 0.7) * pitch, pitch * 2.4, pitch * 2.4);
      }
    }
    ctx.globalCompositeOperation = "source-over";
    // A reflection sliding over the glass as the head turns.
    const s = -0.05 - pose.yaw * 0.9 + pose.pitch * 0.5;
    const sg = ctx.createLinearGradient(-0.55 + s, -0.35, 0.15 + s, 0.35);
    sg.addColorStop(0, "rgba(255,255,255,0)");
    sg.addColorStop(0.36, "rgba(255,255,255,0)");
    sg.addColorStop(0.43, "rgba(220,232,255,0.08)");
    sg.addColorStop(0.5, "rgba(255,255,255,0)");
    sg.addColorStop(0.58, "rgba(255,255,255,0)");
    sg.addColorStop(0.61, "rgba(220,232,255,0.045)");
    sg.addColorStop(0.65, "rgba(255,255,255,0)");
    ctx.fillStyle = sg;
    ctx.beginPath();
    shape.path(ctx, INSET.glass);
    ctx.fill();
    ctx.restore();
    // The gasket's edge, and the screws (big heads only).
    ctx.beginPath();
    shape.path(ctx, INSET.glass);
    ctx.lineWidth = 0.008;
    ctx.strokeStyle = "rgba(255,255,255,0.08)";
    ctx.stroke();
    if (!small) this.screws(ctx, shape.screws);
  }

  /** The back: a panel line, vents, screws. */
  private back(ctx: CanvasRenderingContext2D, shape: Shape, palette: Palette, small: boolean) {
    ctx.beginPath();
    shape.path(ctx, INSET.plate + 0.03);
    ctx.lineWidth = 0.008;
    ctx.strokeStyle = "rgba(0,0,0,0.3)";
    ctx.stroke();
    ctx.fillStyle = "rgba(0,0,0,0.45)";
    for (const vy of VENTS) {
      ctx.beginPath();
      ctx.roundRect(-0.196, vy - 0.014, 0.392, 0.028, 0.014);
      ctx.fill();
    }
    if (!small) this.screws(ctx, shape.backScrews);
  }

  private screws(ctx: CanvasRenderingContext2D, at: Array<[number, number, number]>) {
    for (const [x, y, a] of at) {
      ctx.beginPath();
      ctx.arc(x, y, 0.016, 0, Math.PI * 2);
      ctx.fillStyle = "rgba(20,22,28,0.55)";
      ctx.fill();
      ctx.beginPath();
      ctx.moveTo(x - Math.cos(a) * 0.011, y - Math.sin(a) * 0.011);
      ctx.lineTo(x + Math.cos(a) * 0.011, y + Math.sin(a) * 0.011);
      ctx.lineWidth = 0.004;
      ctx.strokeStyle = "rgba(255,255,255,0.25)";
      ctx.stroke();
    }
  }

  /** The collar on top; with the antenna on, the springy stem and the lit bulb. */
  private antenna(ctx: CanvasRenderingContext2D, pose: RobotPose, sim: RobotSim | null, shown: RobotHeadState,
    lightNow: (typeof LIGHTS)[RobotHeadState], shape: Shape, palette: Palette, stem: boolean, P: Proj, dome: Dome, drop = 0) {
    // (Port: `drop` sinks it, the collar shrinking away, the bulb coming down flush.)
    if (drop < 0.97) dome([0, -shape.hy, 0], [0, -1, 0], [1, 0, 0], [0, 0, 1], 0.05 * (1 - drop));
    if (!stem) return;
    const e = drop * drop * (3 - 2 * drop);
    const top = -shape.hy - 0.028 * (1 - e);
    const L = HEAD.stem * (1 - e);
    const ax = pose.antennaX, az = pose.antennaZ;
    const dir = [Math.sin(ax), -Math.cos(ax) * Math.cos(az), Math.sin(az)];
    const base = P(0, top, 0), ctrl = P(0, top - L * 0.55, 0), tip = P(dir[0] * L, top + dir[1] * L, dir[2] * L);
    if (L > 0.01) {
      ctx.lineCap = "round";
      ctx.beginPath();
      ctx.moveTo(base.x, base.y);
      ctx.quadraticCurveTo(ctrl.x, ctrl.y, tip.x, tip.y);
      ctx.lineWidth = 0.02;
      ctx.strokeStyle = "#4a5260";
      ctx.stroke();
      ctx.lineWidth = 0.009;
      ctx.strokeStyle = "#9aa3b1";
      ctx.stroke();
    }
    // The bulb: frosted glass lit from inside by the state's light.
    let colour: RGB = lightNow.ball as RGB;
    let level = lightNow.pulse(sim ? sim.face.time : 0.3);
    if (sim && sim.switched < 0.3) {
      const was = LIGHTS[sim.previous];
      const k = sim.switched / 0.3;
      colour = mix(was.ball as RGB, colour, k);
      level = was.pulse(sim.face.time + 10) * (1 - k) + level * k;
    }
    if (sim && sim.age < 0.55) level *= smooth(0.1, 0.5, sim.age);
    const r = HEAD.ball;
    const kb = L + r * 0.8 * (1 - e);
    const ball = P(dir[0] * kb, top + dir[1] * kb, dir[2] * kb);
    const bx = ball.x, by = ball.y;
    if (level > 0.02) {
      ctx.globalCompositeOperation = "lighter";
      const glow = ctx.createRadialGradient(bx, by, r * 0.6, bx, by, r * 4.2);
      glow.addColorStop(0, rgba(colour, 0.35 * level));
      glow.addColorStop(1, rgba(colour, 0));
      ctx.fillStyle = glow;
      ctx.fillRect(bx - r * 4.2, by - r * 4.2, r * 8.4, r * 8.4);
      ctx.globalCompositeOperation = "source-over";
    }
    const dim: RGB = [150, 150, 158];
    const body = mix(dim, colour, Math.min(1, 0.25 + level));
    const g = ctx.createRadialGradient(bx - r * 0.18, by - r * 0.22, r * 0.05, bx, by, r);
    g.addColorStop(0, rgba(mix(body, [255, 255, 255], 0.55), 1));
    g.addColorStop(0.6, rgba(body, 1));
    g.addColorStop(1, rgba(mix(body, [40, 40, 50], 0.5), 1));
    ctx.beginPath();
    ctx.arc(bx, by, r, 0, Math.PI * 2);
    ctx.fillStyle = g;
    ctx.fill();
    // A pin of light.
    ctx.beginPath();
    ctx.arc(bx - r * 0.38, by - r * 0.42, r * 0.22, 0, Math.PI * 2);
    ctx.fillStyle = "rgba(255,255,255,0.7)";
    ctx.fill();
  }
}
