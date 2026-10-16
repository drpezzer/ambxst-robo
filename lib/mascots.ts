// Port: which mascot the shell shows, and whether this is the public build.
//
// lib/build.mjs defines __PUBLIC__: false for the personal build (the Coucou mascot, Robo
// and Axenide), true for the public one ("--public": Robo and Axenide only, no
// Coucou mascot code or art in the bundle). Every "which mascot" question goes through
// mascotOf(): in the public build an unset or "coucou" setting means Axenide.

import { State } from "@coucou/core/state";

declare const __PUBLIC__: boolean;

/** True in the public build (no Coucou mascot). */
export const PUBLIC: boolean = __PUBLIC__;

export type MascotName = "coucou" | "robo" | "ambxst";

/** The mascot when Settings have none: the Coucou mascot (personal), Axenide (public). */
export function defaultMascot(): MascotName {
  return PUBLIC ? "ambxst" : "coucou";
}

/** A settings value (or a card's override) → the mascot actually shown. */
export function mascotOf(m: string | null | undefined): MascotName {
  if (m === "robo" || m === "ambxst") return m;
  if (!PUBLIC && m === "coucou") return "coucou";
  return defaultMascot();
}

/** Settings → Style's mascot, resolved. */
export function currentMascot(): MascotName {
  return mascotOf((State.settings as { mascot?: string }).mascot);
}
