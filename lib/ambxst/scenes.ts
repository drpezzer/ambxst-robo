// Port only (his ask): Axenide (the Ambxst logo mascot) where Coucou draws
// the Coucou mascot by hand rather than through his engine: the greeting (patched
// greeting.ts, through robot/greeting.ts) and the drop (patched
// upload/canvas.ts, through robot/upload.ts). In the drop he turns into
// the Coucou mascot's box with its slot, his eyes two round holes.

import type { UploadFrame } from "@coucou/upload/sequence";
import * as F from "./figure";
import { coloursFor, isAmbxst } from "./engine";
import { island as islandNow } from "../main";
// (the Coucou mascot's arcs and slot; the public build's own: lib/public/personal-patch.ts.)
import { eyeGlyph, uploadSlot } from "./personal-patch";

/** Port: the greeting's and the drop's eye glyphs. */
const eyeShape = (x: CanvasRenderingContext2D) => (sh: string, w: number, h: number, sd: number) => eyeGlyph(x, sh, w, h, sd);

const WIDTH_PER_HW = 2 * 1.06;

/** The greeting: the logo where the mascot's body and eyes go (context at his centre). */
export function greetAmbxst(x: CanvasRenderingContext2D, hw: number,
  p: { lookX: number; lookY: number; eye?: string; open?: number; halo?: number; haloBlue?: number }): boolean {
  if (!isAmbxst()) return false;
  const pose: F.Pose = { s: hw * WIDTH_PER_HW, turn: { x: p.lookX, y: -p.lookY } };
  // His colour, as the hands wear it (the island's: Settings, the operator's brand).
  const c = coloursFor(islandNow?.engine.bodyColor as number[] | null);
  F.drawBody(x, pose, c.top, c.bottom);
  const shape = p.eye === "happy" ? "happy" : p.eye === "content" ? "closed" : "pill";
  F.drawEyes(x, pose, c.mid, {
    lookX: p.lookX, lookY: -p.lookY, shape, open: p.open ?? 1, scale: 1,
    shapeFn: eyeShape(x),
    // The halo (drawn by the greeting) is on this canvas, under him: punched
    // out with him, it is put back in the hole (else it shows the card, black).
    behind: (ctx, ox = 0, oy = 0) => {
      const halo = p.halo ?? 0;
      if (halo <= 0) return null;
      const bl = p.haloBlue ?? 0;
      const r = Math.round(232 + (59 - 232) * bl), g = Math.round(195 + (158 - 195) * bl), b = Math.round(154 + (255 - 154) * bl);
      const R = hw * 2.6;
      const grad = ctx.createRadialGradient(ox, oy, 0, ox, oy, R);
      grad.addColorStop(0, `rgba(${r},${g},${b},${0.18 * halo + 0.07 * halo})`);
      grad.addColorStop(1, `rgba(${r},${g},${b},${0.07 * halo * 0.4})`);
      return grad;
    },
  });
  return true;
}

/** The drop: the mascot's part of upload/canvas.ts, with Axenide's figure. */
export function uploadAmbxst(ctx: CanvasRenderingContext2D, f: UploadFrame): boolean {
  if (!isAmbxst()) return false;
  const R = f.d / 2 / 1.04;
  const mc = Math.max(0, Math.min(f.morph, 1));
  // Upstream's body is 2.08 R wide; the logo is drawn that wide.
  const pose: F.Pose = { s: 2.08 * R * 1.06, m: f.morph, R, turn: { x: f.lookX * 0.6, y: f.lookY * 0.6 } };
  const c = coloursFor(islandNow?.engine.bodyColor as number[] | null);
  ctx.save();
  ctx.translate(f.x, f.y + f.hop);
  ctx.rotate(f.tilt);
  ctx.scale(f.sx, f.sy);
  F.drawBody(ctx, pose, c.top, c.bottom, pose.s > 30);

  // The slot (personal-patch.ts: the Coucou mascot's, as upstream cuts it; the public build: his own).
  uploadSlot(ctx, f, R, mc);
  const shape = f.eye === "content" ? "closed" : "pill";
  F.drawEyes(ctx, pose, c.mid, {
    lookX: f.lookX, lookY: f.lookY, shape, open: f.eye === "cup" ? 0.75 : 1, scale: 1,
    shapeFn: eyeShape(ctx),
  });
  ctx.restore();
  return true;
}
