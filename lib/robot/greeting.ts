// Port only (his ask): the greeting with Robo. Upstream's greeting.ts is
// patched at build time (lib/build.mjs) to call these: Robo's head where
// the Coucou mascot's body and eyes go, and the hands, the same shape and size, in Robo's
// trim (metal, lit from above) instead of the mascot's white.

import { Robot, palette } from "./mascot";
import { greetAmbxst } from "../ambxst/scenes";
import { coloursFor, isAmbxst } from "../ambxst/engine";
import { island as islandNow } from "../main";
import { isRobo, mainLook } from "./config";
import { css, radiance } from "./tv/light";
import { getShape } from "./tv/geometry";
import type { RobotHeadShape } from "./types";

let robot: Robot | null = null;
let last = 0;

/**
 * Draws Robo where the mascot's body is (the context at its centre, tilted and
 * squashed by the greeting): false when the mascot is the mascot.
 */
export function greetRobo(x: CanvasRenderingContext2D, hw: number, p: { lookX: number; lookY: number; eye?: string; open?: number }): boolean {
  // (The Ambxst mascot too: ambxst/scenes.ts.)
  if (greetAmbxst(x, hw, p)) return true;
  if (!isRobo()) {
    robot = null;
    return false;
  }
  // Robo's head as wide as the mascot's body, so the hands wave beside it.
  const look = mainLook();
  if (!robot) robot = new Robot(look, 100, 0.37);
  robot.setLook(look);
  const unitPerBox = robot.frame.unit / Math.max(1, robot.frame.box);
  robot.setBox(Math.max(8, (2 * hw) / (2 * getShape(look.shape).hx * unitPerBox)));
  robot.look_at({ x: p.lookX * 240, y: p.lookY * 180 });
  // Drawn twice a frame (the stage and its tint pass): stepped once.
  const now = performance.now();
  const dt = last ? Math.min(0.1, (now - last) / 1000) : 0;
  last = now;
  if (dt > 0.001) robot.update(dt);
  const f = robot.frame;
  robot.drawAt(x, -(f.cx - f.padSide), -(f.cy - f.padTop));
  return true;
}

/** A hand's fill from (x0, y0), the lit side, to (x1, y1): Robo's trim, lit
 *  like his ears (a metal sphere's shading), or null for the Coucou mascot's white. */
export function greetMetal(x: CanvasRenderingContext2D, x0: number, y0: number, x1: number, y1: number): CanvasGradient | null {
  // His ask: the hands wear the mascot's colour. Axenide: his body's (the
  // island's colour, lib/ambxst/engine.ts coloursFor), lit like the mascot's.
  if (isAmbxst()) {
    const c = coloursFor(islandNow?.engine.bodyColor as number[] | null);
    const g = x.createLinearGradient(x0, y0, x1, y1);
    g.addColorStop(0, `rgb(${c.top.map(Math.round).join(",")})`);
    g.addColorStop(1, `rgb(${c.mid.map(Math.round).join(",")})`);
    return g;
  }
  if (!isRobo()) return null;
  const look = mainLook();
  // Robo: his shell's colour (it was his trim), lit like his ears.
  const trim = palette(look.shell, look.trim, look.screen).shell;
  const lit = (ny: number, nz: number) => {
    const l = Math.hypot(ny, nz);
    return css(radiance(trim, 0, ny / l, nz / l));
  };
  const g = x.createLinearGradient(x0, y0, x1, y1);
  g.addColorStop(0, lit(-0.75, 0.65));
  g.addColorStop(0.4, lit(-0.2, 1));
  g.addColorStop(0.7, lit(0.35, 0.95));
  g.addColorStop(1, lit(0.75, 0.55));
  return g;
}

/** How the greeting draws the mascot's arms and hands (lib/public/greeting.ts). */
export type GreetArms =
  | {
    kind: "robo";
    /** Settings → Style's head shape: the arms' corners follow it. */
    shape: RobotHeadShape;
    /** His shell, lit at a normal (x right, y down, z toward the viewer). */
    shell: (nx: number, ny: number, nz: number) => string;
    /** His trim (the ears' metal), the same way. */
    trim: (nx: number, ny: number, nz: number) => string;
  }
  | { kind: "ambxst"; top: string; mid: string; bottom: string };

/** Robo's or Axenide's arm style, or null for neither (the plain mittens). */
export function greetArms(): GreetArms | null {
  if (isAmbxst()) {
    const c = coloursFor(islandNow?.engine.bodyColor as number[] | null);
    const rgb = (v: number[]) => `rgb(${v.map(Math.round).join(",")})`;
    return { kind: "ambxst", top: rgb(c.top), mid: rgb(c.mid), bottom: rgb(c.bottom) };
  }
  if (!isRobo()) return null;
  const look = mainLook();
  const pal = palette(look.shell, look.trim, look.screen);
  const lit = (m: typeof pal.shell) => (nx: number, ny: number, nz: number) => {
    const l = Math.hypot(nx, ny, nz) || 1;
    return css(radiance(m, nx / l, ny / l, nz / l));
  };
  return { kind: "robo", shape: look.shape, shell: lit(pal.shell), trim: lit(pal.trim) };
}
