// Port only (his ask): the mascots while Claude Code compacts the
// conversation (lib/compaction.ts), looped until it is done.
// - The mascot: squeezes himself small, strains with a shake, then springs back
//   out like dough (an overshoot and a wobble), squinting then wide-eyed
//   (personal-only.ts; personal build only).
// - Robo: his "compacting" face (tv/faces.ts): data squeezed between two bars.
// - Axenide: holds his breath (puffs, squints, shakes his head), then lets it
//   go and relaxes (ambxst/personal-patch.ts, ambxst/standalone.ts read axenidePhase()).

/**
 * Axenide's loop: 0 → 1 over AX_CYCLE. strain (0–0.6): puffing up, squinting,
 * the shake building; release (0.6–0.75): out goes the breath, eyes shut;
 * rest (0.75–1): back to himself.
 */
export const AX_CYCLE = 3.2;
export function axenidePhase(): number {
  return ((performance.now() / 1000) % AX_CYCLE) / AX_CYCLE;
}
