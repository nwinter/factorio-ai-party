// (d27 batch277 RT, Nick d27 11:25: "a soft deadline, so the agents keep being reminded they are trying to reach the
// Shattered Planet by Friday night; the run's end is not decided") The run's target the operator sets, pog's
// runs/RUN/target.json (tools/run_target.py; start-team carries it to the next shift): one line on every status reply,
// "Target (Nick, soft): the Shattered Planet by Fri Oct 30 23:59 PDT, 81 h 30 m from now; the run's end is not
// fixed.", the time left computed at each read. At 11:15 shift87's fresh sessions had it only from an operator tell.
import { parseDeadline } from './deadline.js';

const DAYS = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/** "2026-10-30 23:59 PDT" as "Fri Oct 30 23:59 PDT" (its own date and zone); another form as written. */
export function whenText(at: string): string {
  const m = at.trim().match(/^(\d{4})-(\d{2})-(\d{2})[ T](\d{1,2}:\d{2})(?::\d{2})?\s*(.*)$/);
  if (!m) return at.trim();
  const [, y, mo, d, hm, zone] = m;
  const day = new Date(Date.UTC(Number(y), Number(mo) - 1, Number(d))).getUTCDay();
  return `${DAYS[day]} ${MONTHS[Number(mo) - 1]} ${Number(d)} ${hm!.padStart(5, '0')}${zone ? ' ' + zone.trim() : ''}`;
}

function hours(ms: number): string {
  const minutes = Math.floor(ms / 60000);
  return minutes >= 60 ? `${Math.floor(minutes / 60)} h ${minutes % 60} m` : `${minutes} m`;
}

/** The status line for target.json's text, or undefined (no goal, or a time that does not parse). */
export function targetLine(raw: string, now = Date.now()): string | undefined {
  let t: Record<string, unknown>;
  try { t = JSON.parse(raw); } catch { return undefined; }
  if (!t || typeof t !== 'object' || typeof t.goal !== 'string' || !t.goal.trim() || typeof t.at !== 'string') return undefined;
  const at = parseDeadline(t.at);
  if (at === undefined || Number.isNaN(at)) return undefined;
  const who = [typeof t.by === 'string' && t.by.trim() ? t.by.trim() : undefined, t.kind === 'hard' ? 'hard' : 'soft']
    .filter(Boolean).join(', ');
  const left = at >= now ? `${hours(at - now)} from now` : `passed ${hours(now - at)} ago`;
  const note = typeof t.note === 'string' && t.note.trim() ? `; ${t.note.trim().replace(/[.]$/, '')}` : '';
  return `Target (${who}): ${t.goal.trim()} by ${whenText(t.at)}, ${left}${note}.`;
}
