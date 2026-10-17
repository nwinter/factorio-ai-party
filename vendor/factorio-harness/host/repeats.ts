/**
 * Reply lines that repeat (d17 audit: the standing orders line was the same as the last one shown on 55% of replies,
 * the lessons lines on 63%): in compact output each is shown when its text changed since this workspace last showed
 * it, and at least every SHOWN_EVERY_MS; between those the reply leaves it out. JSON output keeps every field.
 *
 * - orders: the runtime's standing orders line (orders.lua M.line, a string "orders: ..."); an `orders` action's own
 *   reply (a table) is not touched.
 * - lessons: the lessons a call's keys match (board.lua lessons_for: strings "lesson #N ..."); a `lessons` action's
 *   rows are not touched.
 */
export const SHOWN_EVERY_MS = 10 * 60 * 1000;
export interface ShownState { [key: string]: { text: string; at: number } | undefined }
type Json = Record<string, unknown>;
function record(value: unknown): value is Json {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}
/** The text a repeating field is compared by, or undefined when the field is not the repeating line. */
function repeating(key: string, value: unknown): string | undefined {
  if (key === 'orders') return typeof value === 'string' && value.startsWith('orders: ') ? value : undefined;
  if (key === 'lessons') {
    return Array.isArray(value) && value.length > 0 && value.every(line => typeof line === 'string' && line.startsWith('lesson #'))
      ? value.join('\n') : undefined;
  }
  return undefined;
}
/** The reply with each repeating field left out when it was shown with the same text less than SHOWN_EVERY_MS ago,
 * and the state after this reply (changed: whether it needs saving). */
export function trimRepeats(reply: unknown, state: ShownState, now: number): { reply: unknown; state: ShownState; changed: boolean } {
  if (!record(reply) || !record(reply.result)) return { reply, state, changed: false };
  const result: Json = { ...reply.result };
  const next: ShownState = { ...state };
  let changed = false, trimmed = false;
  for (const key of ['orders', 'lessons']) {
    const text = repeating(key, result[key]);
    if (text === undefined) continue;
    const last = state[key];
    if (last && last.text === text && now - last.at < SHOWN_EVERY_MS) { delete result[key]; trimmed = true; continue; }
    next[key] = { text, at: now };
    changed = true;
  }
  return { reply: trimmed ? { ...reply, result } : reply, state: next, changed };
}
