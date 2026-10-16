// Port only (his ask): the drop with Robo. Upstream's upload/canvas.ts is
// patched at build time (lib/build.mjs) to call roboUpload() where it draws
// the Coucou mascot; the choreography (upload/sequence.ts) is untouched and drives Robo:
//
// - the file over the island: his antenna sinks until its bulb is flush with
//   the top of his head, which opens into a glowing slot (no antenna: a dot
//   opening from the middle), the head tipped forward to show it; his screen
//   shows a file, bobbing;
// - the drop: the file is pulled into the slot (the slot is the "mouth" the
//   sheet funnels into) while the icon sinks out of his screen; the slot shuts,
//   the antenna comes back up, a happy face;
// - the upload: a tiny Robo rides the bar, and grows back by the choose card.

import { USC, type UploadFrame } from "@coucou/upload/sequence";
import { Robot } from "./mascot";
import { uploadAmbxst } from "../ambxst/scenes";
import { isRobo, mainLook } from "./config";
import { getShape } from "./tv/geometry";
import { FILE_FACE } from "./tv/faces";

let robot: Robot | null = null;
let last = 0;

/** Draws Robo for upload frame `f` (and aims the file at his slot): false for the Coucou mascot. */
export function roboUpload(ctx: CanvasRenderingContext2D, f: UploadFrame): boolean {
  // (The Ambxst mascot too: ambxst/scenes.ts.)
  if (uploadAmbxst(ctx, f)) return true;
  if (!isRobo()) {
    robot = null;
    return false;
  }
  const look = mainLook();
  // A new drop (the overlay was off a moment ago) starts him afresh.
  const fresh = !robot || performance.now() - last > 500;
  if (!robot) {
    robot = new Robot(look, 100, 0.61);
    robot.faceFromOpen = false;
    // Already awake: no screen boot-up as he takes over from the island's Robo.
    robot.sim.age = 10;
  }
  const r = robot;
  r.setLook(look);
  // His head as wide as the mascot's body (f.d), as in the greeting.
  const unitPerBox = r.frame.unit / Math.max(1, r.frame.box);
  r.setBox(Math.max(4, f.d / (2 * getShape(look.shape).hx * unitPerBox)));

  // The mouth's opening drives the slot: ajar (0.2) on entry has the antenna
  // down, open (0.42) once the file is close has the slot wide.
  // From the drop until the file is in, wide open: the island's Robo had
  // it open already while the file hovered (the overlay starts at the drop).
  const mc = Math.max(0, Math.min(1, f.morph));
  const swallowing = f.t >= USC.T_DROP && f.t < USC.T_SUCK_END;
  r.openness = swallowing ? 1 : Math.max(0, Math.min(1, f.mouth / USC.MOUTH_OPEN)) * mc;

  // The face: the file while it waits and goes in, happy once it is in and
  // once it has uploaded, his own otherwise.
  const t = f.t;
  const happy = (t >= USC.T_SUCK_END && t < USC.T_CHEW_END + 0.1) || (t >= f.progEnd && t < f.growEnd + 0.3);
  r.sim.held = f.fileVisible && f.zoneOver ? "file" : happy ? "happy" : null;
  FILE_FACE.sink = f.suck;
  if (fresh) {
    // He takes over from the island's Robo mid-drop: on that face already, no crossfade.
    const face = r.sim.held ?? "idle";
    r.sim.shown = r.sim.previous = face;
    r.sim.switched = 1;
  }

  r.look_at({ x: f.lookX * 240, y: f.lookY * 180 });
  r.poseExtra = { roll: f.tilt, sx: f.sx, sy: f.sy, x: 0, lift: 0 };
  const now = performance.now();
  const dt = last ? Math.min(0.1, (now - last) / 1000) : 0;
  last = now;
  if (dt > 0.001) r.update(dt);

  const fr = r.frame;
  ctx.save();
  r.drawAt(ctx, f.x - (fr.cx - fr.padSide), f.y + f.hop - (fr.cy - fr.padTop));
  ctx.restore();
  FILE_FACE.sink = 0;

  // The sheet funnels into the slot (upstream aims it at the mascot's mouth).
  const s = r.slotRect;
  if (s) f.mouthRect = { x: s.x, y: s.y, w: s.w, h: Math.max(2, s.h) };
  return true;
}
