// robot-heads (github.com/fayazara/robot-heads, MIT, see LICENSE) types,
// without React: the port draws the heads itself (lib/robot/mascot.ts).
export type RobotHeadState =
  | 'idle' | 'thinking' | 'searching' | 'listening' | 'speaking'
  | 'working' | 'happy' | 'error' | 'sleeping'
  /* Port (his ask): heart eyes, a reaction only (hovered a while), never a state */
  | 'love'
  /* Port (his ask): a file, while one is dragged over him (a reaction too) */
  | 'file'
  /* Port (his ask): Claude Code compacting the conversation (held while it runs) */
  | 'compacting';
export type RobotHeadModel = 'tv';
export type RobotHeadShape = 'rectangle' | 'square' | 'circle' | 'hexagon';
