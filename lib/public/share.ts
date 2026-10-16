// Port (public build): the weekly recap image's mascot. Upstream's
// recap/share.ts draws the mascot there; lib/build.mjs (--public) has it call this
// instead: the mascot Settings choose, Robo or Axenide, still.

import { BotEngine } from "./engine";
import { Robot } from "../robot/mascot";
import { isRobo, mainLook } from "../robot/config";
import { island as islandNow } from "../main";

/** The mascot in a `size` square whose top is `top`, centred on `cx` (upstream's mascot box). */
export function drawShareMascot(x: CanvasRenderingContext2D, cx: number, top: number, size: number) {
  if (isRobo()) {
    // His head as big as the engine's body would be (0.6 of the box), at its centre.
    const box = size * 0.6;
    const robot = new Robot(mainLook(), box, 0.37);
    robot.setState("idle");
    robot.drawAt(x, cx - box / 2, top + (size - box) / 2 + size * 0.018, false);
    return;
  }
  const engine = new BotEngine();
  engine.bodyColor = islandNow?.engine.bodyColor ?? null;
  engine.setState("idle", true);
  engine.update(1 / 60);
  x.save();
  x.translate(cx - size / 2, top);
  engine.draw(x, size, size);
  x.restore();
}
