// Port (public build): stands in for lib/ambxst/personal-patch.ts (Axenide on
// the Coucou mascot's engine, personal build). Nothing is patched: lib/public/engine.ts
// draws Axenide itself. The greeting and the drop take his own eye glyphs
// and, in the drop, his own slot.

import type { UploadFrame } from "@coucou/upload/sequence";
import { drawSlot, glyph } from "../ambxst/standalone";

/** His expressions in the greeting and the drop (ambxst/scenes.ts). */
export function eyeGlyph(ctx: CanvasRenderingContext2D, shape: string, w: number, h: number, sd = 1) {
  glyph(ctx, shape, w, h, sd);
}

/** The drop's slot on his box, and where the file goes in (upstream's mouthRect, aimed at it). */
export function uploadSlot(ctx: CanvasRenderingContext2D, f: UploadFrame, R: number, mc: number) {
  const mh = f.mouth * R * mc;
  drawSlot(ctx, R, mc, mh);
  const w = R * 1.3 * mc;
  const top = -R * 0.94 * mc + R * 0.16 * mc;
  f.mouthRect = { x: f.x - (w / 2) * f.sx, y: f.y + f.hop + top * f.sy, w: w * f.sx, h: mh * f.sy };
}
