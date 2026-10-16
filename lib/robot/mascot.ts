// Port only (his ask): Robo, the second mascot — fayazara/robot-heads (MIT,
// see LICENSE; vendored in tv/, its renderer drawing on Qt Quick through
// offscreen.js) driven the way its React component (RobotHead.tsx) drives it.
// One Robot per head on screen: the island's, the desktop's, each mini.

import { getShape } from "./tv/geometry";
import { RobotSim, restPose } from "./tv/sim";
import { BOX_INSET, HEAD_TRAVEL, RobotRenderer, type Frame, type Palette } from "./tv/render";
import type { Shape } from "./tv/geometry";
import { FlatRobotRenderer, type DropOptions } from "./flat";
import type { RobotPose } from "./tv/sim";
import { linear } from "./tv/light";
import { parseColor } from "./color";
import type { RobotHeadShape, RobotHeadState } from "./types";
import { ensureScratch } from "./offscreen.js";

let lastGc = Date.now();
declare const gc: undefined | (() => void);

export const SHAPES: RobotHeadShape[] = ["rectangle", "square", "circle", "hexagon"];
export const SPEEDS = [0.5, 1, 1.5, 2];

/** RobotHead.tsx palette(): shell, trim, LEDs. */
export function palette(color: string, trim: string, screen: string): Palette {
  const shell = parseColor(color) ?? [48, 80, 172];
  const metal = parseColor(trim) ?? [150, 168, 200];
  const led = parseColor(screen) ?? [232, 242, 255];
  return {
    shell: { albedo: linear(shell), f0: 0.05, metal: 0.15, spec: 0.55, shininess: 70, rim: 0.9 },
    trim: { albedo: linear(metal), f0: 0.2, metal: 0.65, spec: 0.8, shininess: 45, rim: 0.7 },
    led,
  };
}

/** A head's look: what Settings → Style chooses (the island's), or a mini's own. */
export interface RobotLook {
  shape: RobotHeadShape;
  antenna: boolean;
  speed: number;
  shell: string;
  trim: string;
  screen: string;
}

/** A trim and screen that go with a shell colour (the "brand colours" default). */
export function brandLook(shell: string): { shell: string; trim: string; screen: string } {
  const rgb = parseColor(shell) ?? [48, 80, 172];
  // Trim: the shell's hue, washed pale like the stock steel; LEDs: near white, a touch of it.
  const mix = (c: number, to: number, t: number) => Math.round(c + (to - c) * t);
  const hex = (r: number, g: number, b: number) => "#" + [r, g, b].map((v) => v.toString(16).padStart(2, "0")).join("");
  const trim = hex(mix(rgb[0], 200, 0.62), mix(rgb[1], 208, 0.62), mix(rgb[2], 220, 0.62));
  const screen = hex(mix(rgb[0], 255, 0.88), mix(rgb[1], 255, 0.88), mix(rgb[2], 255, 0.88));
  return { shell, trim, screen };
}

/** A stable 0–1 from a string (RobotHead.tsx hashSeed): a mini's own blink timing, shape, antenna. */
export function hashSeed(id: string): number {
  let h = 2166136261;
  for (let i = 0; i < id.length; i++) h = Math.imul(h ^ id.charCodeAt(i), 16777619);
  return ((h >>> 0) % 1000) / 1000;
}

/** His ask: a mini's shape and antenna are picked at random once, by its id, and kept. */
export function miniLook(id: string): { shape: RobotHeadShape; antenna: boolean } {
  let h = 2166136261;
  for (let i = 0; i < id.length; i++) h = Math.imul(h ^ id.charCodeAt(i), 16777619);
  const u = h >>> 0;
  return { shape: SHAPES[u % 4], antenna: ((u >>> 4) & 1) === 0 };
}

/** Port: the flat renderer (flat.ts) by default; the 3D one stays for comparisons. */
export const RENDER = { flat: true };

/**
 * Port (his ask): where a head sits in its box, as a mascot. robot-heads'
 * frameFor() centres the whole robot, antenna included, so a head with an
 * antenna sat lower and smaller, and each shape differently. Here the HEAD is
 * centred in the box (where the mascot's body is) at a size the antenna doesn't
 * change; the antenna simply reaches up past it.
 */
export function mascotFrame(shape: Shape, antenna: boolean, box: number): Frame {
  const tall = 2 * shape.hy + HEAD_TRAVEL.knob;
  const wide = 2 * (shape.earX + HEAD_TRAVEL.ear);
  const inner = box * (1 - 2 * BOX_INSET);
  const unit = Math.min(inner / tall, inner / wide);
  const centreY = box / 2;
  const up = antenna ? HEAD_TRAVEL.antenna + HEAD_TRAVEL.glow + HEAD_TRAVEL.hop : HEAD_TRAVEL.knob + HEAD_TRAVEL.hop + HEAD_TRAVEL.overshoot;
  const reachUp = (shape.hy + up) * unit;
  const reachDown = centreY + (shape.hy + HEAD_TRAVEL.shadow) * unit;
  const reachSide = box / 2 + (shape.earX + HEAD_TRAVEL.ear + HEAD_TRAVEL.side) * unit;
  const padTop = Math.ceil(Math.max(0, reachUp - centreY) + 1);
  const padBottom = Math.ceil(Math.max(0, reachDown - box) + 1);
  const padSide = Math.ceil(Math.max(0, reachSide - box) + 1);
  return { box, padTop, padBottom, padSide, unit, cx: padSide + box / 2, cy: padTop + centreY };
}

export class Robot {
  sim: RobotSim;
  renderer: RobotRenderer | FlatRobotRenderer = RENDER.flat ? new FlatRobotRenderer() : new RobotRenderer();
  look: RobotLook;
  state: RobotHeadState = "idle";
  pal: Palette;
  /** The box the head rests in (CSS px) and where it sits in its canvas. */
  frame: Frame;

  constructor(look: RobotLook, box: number, seed = 0.3) {
    this.look = { ...look };
    this.sim = new RobotSim(seed, "idle");
    this.pal = palette(look.shell, look.trim, look.screen);
    this.frame = mascotFrame(getShape(look.shape), look.antenna, box);
  }

  setLook(look: RobotLook) {
    const shapeChanged = look.shape !== this.look.shape || look.antenna !== this.look.antenna;
    this.look = { ...look };
    this.pal = palette(look.shell, look.trim, look.screen);
    if (shapeChanged) this.frame = mascotFrame(getShape(look.shape), look.antenna, this.frame.box);
  }

  setBox(box: number) {
    if (Math.round(box) === Math.round(this.frame.box)) return;
    this.frame = mascotFrame(getShape(this.look.shape), this.look.antenna, box);
  }

  setState(s: RobotHeadState) {
    if (s === this.state) return;
    this.state = s;
    this.sim.setState(s);
  }

  /** The eyes and head follow a point, relative to the head's centre (px), or nothing. */
  look_at(p: { x: number; y: number } | null) {
    this.sim.pointer = p && Math.hypot(p.x, p.y) < 700 ? p : null;
  }

  /** A click: a hop with a spin and a happy face. */
  poke() { this.sim.poke(); }

  /** Port (his ask): a click on the island's head: a little bounce, at once. */
  click() { this.sim.bounce(0.13, 0); }

  /** Port (his ask): hovered a while: heart eyes, as the mascot's love. */
  love() { if (this.state !== "error") this.sim.react("love", 2.2); }

  /** Port (his ask): the third click in a row: a spin, the error face at once. */
  dizzy() {
    this.state = "error";
    this.sim.showNow("error");
    this.sim.bounce(0.22, Math.random() < 0.5 ? 1 : -1);
  }

  update(dt: number) {
    // The slot eases open over ~0.45 s and shut a little faster.
    if (this.faceFromOpen) {
      const rate = this.openTarget > this.openness ? 2.2 : 3;
      this.openness += Math.max(-rate * dt, Math.min(rate * dt, this.openTarget - this.openness));
      if (this.openTarget > 0) this.sim.held = "file";
      else if (this.sim.held === "file") this.sim.held = null;
    }
    this.sim.update(dt * this.look.speed);
    // Port: the pixel buffers a frame still makes (patterns of the LED image)
    // are native memory V4's GC doesn't count; a collection now and then while
    // heads are on screen keeps them from piling up.
    const now = Date.now();
    if (now - lastGc > 20000) {
      lastGc = now;
      if (typeof gc === "function") gc();
    }
  }

  /** The canvas size the head needs, with room for its motion (CSS px). */
  canvasSize(): { w: number; h: number } {
    const f = this.frame;
    return { w: Math.round(f.box + 2 * f.padSide), h: Math.round(f.box + f.padTop + f.padBottom) };
  }

  /**
   * Draws with the resting head's box at (x, y) in `ctx` (box × box): the
   * island draws it where the mascot's body sits, the antenna, hops and glow
   * reaching past the box as the canvas allows.
   */
  drawAt(ctx: CanvasRenderingContext2D, x: number, y: number, animated = true) {
    if (!(this.renderer instanceof FlatRobotRenderer) && !ensureScratch(ctx)) return;
    const f = this.frame;
    const shifted = { ...f, cx: f.cx + x - f.padSide, cy: f.cy + y - f.padTop };
    this.renderer.unitPerBox = f.unit / Math.max(1, f.box);
    this.renderer.draw(ctx, shifted, 1, animated ? this.pose() : restPose(this.state), animated ? this.sim : null,
      this.state, getShape(this.look.shape), this.pal, this.options());
  }

  // ── Port (his ask): a file dragged over him ─────────────────────────────

  /** 0 shut … 1 open: the antenna sinks flush (the first half, with one), then the slot opens. */
  openness = 0;
  private openTarget = 0;
  /** The slot's glow (the upload's green unless set). */
  slotColor: [number, number, number] | undefined;
  /** Placement set from outside each frame (the upload's lean and squash), over the sim's. */
  poseExtra: Partial<RobotPose> | null = null;

  /** Whether the open slot holds the file face (the upload sets faces itself). */
  faceFromOpen = true;

  /** Opens (a file over him) or shuts the slot; update() eases there and shows the file face meanwhile. */
  setOpen(open: boolean) {
    this.openTarget = open ? 1 : 0;
  }

  /** Where the open slot is on the canvas (CSS px), null when shut. */
  get slotRect(): { x: number; y: number; w: number; h: number } | null {
    return this.renderer instanceof FlatRobotRenderer ? this.renderer.slotRect : null;
  }

  /** The renderer's options, the drop's included. */
  private options(): { floorShadow: boolean; antenna: boolean } & DropOptions {
    const o = this.openness;
    const ant = this.look.antenna;
    return {
      floorShadow: false,
      antenna: ant,
      drop: ant ? Math.min(1, o / 0.45) : 0,
      slot: ant ? Math.max(0, (o - 0.45) / 0.55) : o,
      slotColor: this.slotColor,
    };
  }

  /** The sim's pose, tipped forward to show the slot while it is open, and poseExtra. */
  private pose(): RobotPose {
    const p = { ...this.sim.pose };
    const o = this.openness;
    if (o > 0) {
      const k = o * o * (3 - 2 * o);
      p.pitch = p.pitch + (-0.42 - p.pitch) * k;
      p.yaw *= 1 - 0.7 * k;
      p.roll *= 1 - 0.7 * k;
    }
    return this.poseExtra ? Object.assign(p, this.poseExtra) : p;
  }

  /** Draws into `ctx` (a CtxWrap the size of canvasSize(), cleared). */
  draw(ctx: CanvasRenderingContext2D, animated = true) {
    if (!(this.renderer instanceof FlatRobotRenderer) && !ensureScratch(ctx)) return;
    this.renderer.unitPerBox = this.frame.unit / Math.max(1, this.frame.box);
    this.renderer.draw(ctx, this.frame, 1, animated ? this.pose() : restPose(this.state), animated ? this.sim : null,
      this.state, getShape(this.look.shape), this.pal, this.options());
  }
}
