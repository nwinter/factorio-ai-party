/**
 * The game's pace as an agent's calls see it, kept in a small file beside the journal (FH_PACE_FILE, default
 * .fh-pace.json): the last tick and when it was read, the game speed measured between calls, and an outage in course.
 * World n, 13:41: the server crashed and was restarted from the 13:35 autosave (about 5 game minutes rolled back);
 * with no camera client it ran at 7-10 ticks/s for ten minutes, sleeps ended timed_out and calls outcome_unknown.
 * - Speed: game ticks against real time between two replies 5 s to 10 min apart (none across an outage); a sleep or
 *   wait measures it as it polls. The clock line names it under SLOW ticks/s.
 * - Rollback: a reply's tick more than ROLLBACK ticks under the last one seen. Said once, with what the agent's
 *   journal shows it did after the new tick (those calls are gone with the rolled-back game).
 * - Outage: calls that could not reach the game (the broker or RCON down) say since when; the first reply after says
 *   how long it lasted.
 */
import { readFileSync, writeFileSync } from 'node:fs';

export const NORMAL = 60, SLOW = 55, ROLLBACK = 600;

export interface PaceState {
  tick?: number; at?: number;           // the newest reply's tick and when it came (ms)
  base_tick?: number; base_at?: number; // the speed's starting look (moved on once 5 s or more have passed)
  speed?: number; speed_at?: number;    // ticks per second, and when measured
  down_since?: number; down_last?: number; down_error?: string;
}
export function loadPace(file?: string): PaceState {
  if (!file) return {};
  try { const s = JSON.parse(readFileSync(file, 'utf8')); return s && typeof s === 'object' ? s : {}; } catch { return {}; }
}
export function savePace(file: string | undefined, state: PaceState): void {
  if (!file) return;
  try { writeFileSync(file, JSON.stringify(state) + '\n'); } catch { /* the pace is a convenience */ }
}

export function clockTime(ms: number): string {
  const d = new Date(ms);
  return `${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}:${String(d.getSeconds()).padStart(2, '0')}`;
}
export function span(ms: number): string {
  const s = Math.max(0, Math.round(ms / 1000));
  return s >= 60 ? `${Math.floor(s / 60)}m${String(s % 60).padStart(2, '0')}s` : `${s}s`;
}
/** "18 ticks/s, 30% of normal" */
export function speedText(speed: number): string {
  return `${Math.round(speed)} ticks/s, ${Math.round(speed / NORMAL * 100)}% of normal`;
}

export interface Seen { rollback?: { from: number; to: number; lastAt?: number }; outage?: string }
/** A reply with this tick came at `now`: update the state; a rollback or the end of an outage, once. */
export function seeTick(state: PaceState, tick: number, now: number): Seen {
  const seen: Seen = {};
  if (state.down_since !== undefined) {
    seen.outage = `the game was unreachable from ${clockTime(state.down_since)} to about ${clockTime(now)} (${span(now - state.down_since)}; `
      + `the last failed call at ${clockTime(state.down_last ?? state.down_since)}${state.down_error ? `: ${state.down_error}` : ''})`;
    state.down_since = state.down_last = state.down_error = undefined;
    state.base_tick = tick; state.base_at = now;   // no speed across an outage
  } else if (state.base_tick === undefined || state.base_at === undefined || tick < state.base_tick) {
    state.base_tick = tick; state.base_at = now;
  } else {
    const dt = (now - state.base_at) / 1000;
    if (dt >= 5) {
      if (dt <= 600) { state.speed = (tick - state.base_tick) / dt; state.speed_at = now; }
      state.base_tick = tick; state.base_at = now;
    }
  }
  if (state.tick !== undefined && tick < state.tick - ROLLBACK) seen.rollback = { from: state.tick, to: tick, lastAt: state.at };
  state.tick = tick; state.at = now;
  return seen;
}
/** A call that could not reach the game. Returns the "game unreachable since ..." prefix for its error. */
export function seeDown(state: PaceState, now: number, error: string): string {
  if (state.down_since === undefined) state.down_since = now;
  state.down_last = now; state.down_error = error.slice(0, 160);
  return `game unreachable since ${clockTime(state.down_since)} (${span(now - state.down_since)})`;
}
/** The speed for the clock line: measured within the last 3 minutes and under SLOW. */
export function slowNote(state: PaceState, now: number): string | undefined {
  if (state.speed === undefined || state.speed_at === undefined || now - state.speed_at > 180000 || state.speed >= SLOW) return undefined;
  return `game speed ${speedText(state.speed)}`;
}

/** Ticks against real time over a moving window, for one wait's polls. */
export class Pacer {
  private looks: { at: number; tick: number }[] = [];
  constructor(readonly windowMs = 20000) {}
  see(tick: number | undefined, at = Date.now()): void {
    if (typeof tick !== 'number') return;
    this.looks.push({ at, tick });
    while (this.looks.length > 2 && at - this.looks[1]!.at >= this.windowMs) this.looks.shift();
  }
  /** Ticks per second over the window (at least 3 s of looks), else undefined. */
  speed(): number | undefined {
    const a = this.looks[0], b = this.looks[this.looks.length - 1];
    if (!a || !b || b.at - a.at < 3000) return undefined;
    return Math.max(0, (b.tick - a.tick) / ((b.at - a.at) / 1000));
  }
  /** How long the tick has not moved (ms), by the looks. */
  stalledFor(at = Date.now()): number {
    const last = this.looks[this.looks.length - 1];
    if (!last || this.looks.length < 2) return 0;
    let since = last.at;
    for (let i = this.looks.length - 1; i >= 0 && this.looks[i]!.tick === last.tick; i--) since = this.looks[i]!.at;
    return at - since;
  }
}
/** A wait's end, pushed while the game runs slow: past `end`, keep going while the tick moved in the last
 * STALL_MS, up to `cap`. 'go' (keep waiting), 'paused' (no tick for STALL_MS), 'cap' or 'end' (normal end). */
export const STALL_MS = 20000;
export function overtime(pacer: Pacer, end: number, cap: number, now = Date.now()): 'go' | 'end' | 'paused' | 'cap' {
  if (now < end) return 'go';
  if (pacer.stalledFor(now) >= STALL_MS) return 'paused';
  if (now >= cap) return 'cap';
  const speed = pacer.speed();
  return speed !== undefined && speed < SLOW ? 'go' : 'end';
}
export function slowGame(pacer: Pacer): string | undefined {
  const s = pacer.speed();
  return s !== undefined && s < SLOW ? speedText(s) : undefined;
}

// Calls that change the world: after a rollback they are gone, so they are listed for the agent to redo.
const CHANGES = new Set(['build', 'build_path', 'place_ghosts', 'paste', 'blueprint_place', 'craft', 'mine', 'deconstruct',
  'cancel_deconstruction', 'remove_ghosts', 'configure', 'rotate', 'transfer', 'collect', 'feed', 'refuel', 'rearm', 'construct', 'pickup',
  'repair', 'launch', 'load_silo', 'drop', 'platform_schedule', 'platform_create', 'wire', 'circuit_set', 'research', 'research_next',
  'queue_submit', 'flush', 'train', 'vehicle', 'board_post', 'board_update', 'board_plan', 'equip', 'insert', 'take',
  'land', 'ride']);   // (walks leave nothing to redo)
function changes(action: string, args: Record<string, unknown> | undefined): boolean {
  if (action === 'requests') return !!args && (args.set !== undefined || args.clear !== undefined || args.clear_all !== undefined || args.active !== undefined);
  if (action === 'queue_submit' && args?.dry_run === true) return false;   // queues nothing
  if (action === 'remove_ghosts' && args?.dry_run === true) return false;   // removes nothing
  return CHANGES.has(action);
}
function argsText(args: Record<string, unknown> | undefined): string {
  if (!args) return '';
  const text = JSON.stringify(args);
  return text === '{}' ? '' : ' ' + (text.length > 120 ? text.slice(0, 117) + '...' : text);
}
/** From the journal: the real time the game was last at or under tick `to` before the rollback, and the calls
 * applied with a tick above it (their reply's tick), oldest first, as "HH:MM:SS action {args}". */
export function rolledBack(journal: string | undefined, to: number, before: number, limit = 20): { lastAt?: string; redo: string[]; more: number } {
  const out = { redo: [] as string[], more: 0 } as { lastAt?: string; redo: string[]; more: number };
  if (!journal) return out;
  let text = '';
  try { text = readFileSync(journal, 'utf8'); } catch { return out; }
  const requests = new Map<string, { action: string; args?: Record<string, unknown> }>();
  let lastAtMs: number | undefined;
  for (const line of text.split('\n')) {
    if (!line) continue;
    let e: any;
    try { e = JSON.parse(line); } catch { continue; }
    const at = Date.parse(e.at);
    if (!Number.isFinite(at) || at >= before) continue;   // only what came before this reply
    if (e.event === 'request' && e.request?.id) requests.set(e.request.id, { action: String(e.request.action), args: e.request.args });
    else if (e.event === 'response' && e.response && typeof e.response.tick === 'number') {
      const tick = e.response.tick;
      if (tick <= to) { lastAtMs = at; continue; }
      const req = requests.get(e.response.id);
      if (!req || e.response.ok !== true || !changes(req.action, req.args)) continue;
      if (out.redo.length < limit) out.redo.push(`${clockTime(at)} ${req.action}${argsText(req.args)}`);
      else out.more++;
    }
  }
  if (lastAtMs !== undefined) out.lastAt = clockTime(lastAtMs).slice(0, 5);
  return out;
}
