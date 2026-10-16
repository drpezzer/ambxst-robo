// Port (public build): stands in for lib/personal-only.ts. No Coucou mascot here:
// Axenide's compacting loop is drawn by ambxst/standalone.ts and Robo's is his
// "compacting" face; the drop draws Robo or Axenide in their own colours.

/** No "coucou" mascot here (Settings → Style shows no card for it). */
export const COUCOU_MASCOT = "";
/** No older key to read the desktop spot's display from. */
export const LEGACY_PLACE_KEY: string | null = null;

export function compactStep(_e: unknown) {}
export function compactReset() {}
export function tintUpload(ctx: CanvasRenderingContext2D, _body: readonly number[] | null): CanvasRenderingContext2D {
  return ctx;
}
