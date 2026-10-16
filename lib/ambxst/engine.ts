// Port only (his ask): the Ambxst mascot, Axenide: the Coucou mascot's engine (every
// state, blink, glance, squash, emote, mini and desktop behaviour) drawing the
// Ambxst logo (figure.ts) instead of the Coucou mascot's body and eyes. The personal build
// installs that over BotEngine's own drawing (personal-patch.ts); the public one
// has no Coucou mascot: its engine (lib/public/engine.ts) draws Axenide on his own
// (standalone.ts). The Coucou mascot and Robo are untouched.

import { State } from "@coucou/core/state";
import * as F from "./figure";
import { mascotOf } from "../mascots";
// (Personal build only: lib/build.mjs resolves it to nothing for --public.)
import "./personal-patch";

export type RGB = [number, number, number];
/** The logo's default body colours (a soft white), 0–255. */
const BASE_TOP: RGB = [237, 237, 239];
const BASE_BOTTOM: RGB = [196, 197, 202];

/** Whether `engine` draws the Ambxst logo: Settings' mascot, or its own (a Settings card). */
export function isAmbxst(engine?: { mascotOverride?: string } | null): boolean {
  const m = engine?.mascotOverride ?? (State.settings as { mascot?: string }).mascot;
  return mascotOf(m) === "ambxst";
}

/* the logo's width for the engine's body half-width rx */
export const widthFor = (rx: number) => 2 * rx * 1.06;

/** What the figure's colours and pose read from an engine. */
export interface ColourSource { bodyColor: number[] | null; morph?: number; __ambTurn?: { x: number; y: number } }

/** The logo's colours for a body colour (0–1, the mascot's engine.bodyColor), or the Coucou mascot's white. */
export function coloursFor(bodyColor: number[] | null | undefined): { top: RGB; bottom: RGB; mid: RGB } {
  return colours({ bodyColor: bodyColor ?? null });
}

export function colours(e: ColourSource): { top: RGB; bottom: RGB; mid: RGB } {
  if (!e.bodyColor) return { top: BASE_TOP, bottom: BASE_BOTTOM, mid: [216, 217, 221] };
  const c = e.bodyColor.map((v) => v * 255) as RGB;
  return {
    top: c.map((v) => v + (255 - v) * 0.3) as RGB,
    bottom: c.map((v) => v * 0.82) as RGB,
    mid: c,
  };
}

/** The figure's pose for the mascot's body half-width rx and size R: his box at morph 1, his turn. */
export function poseOf(e: ColourSource, rx: number, R: number): F.Pose {
  return { s: widthFor(rx), m: e.morph, R, turn: e.__ambTurn };
}
