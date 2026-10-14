/**
 * When the look-ahead block is due (Nick 12:35): about every 45 real minutes per agent (the real clock holds when the
 * game runs slow), offset by the agent's name so agents do not all get it at once, never in the first 20 minutes after
 * the workspace's first call (its shift block's time).
 */
export const LOOKAHEAD_MS = 45 * 60000, LOOKAHEAD_QUIET_MS = 20 * 60000;
export function lookaheadOffset(name: string): number {
  let h = 0;
  for (const c of name) h = (h * 31 + c.charCodeAt(0)) >>> 0;
  return h % LOOKAHEAD_MS;
}
/** When the block is due next, from the saved state (started: the first call, last: when it was last shown), in ms. */
export function lookaheadDue(state: {started: number; last?: number}, name: string): number {
  return state.last !== undefined ? state.last + LOOKAHEAD_MS : state.started + LOOKAHEAD_QUIET_MS + lookaheadOffset(name);
}
