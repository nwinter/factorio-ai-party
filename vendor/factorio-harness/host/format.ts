/**
 * Human/agent display only; JSON remains the machine-readable protocol.
 *
 * The compact format spends tokens only on information:
 * - successful replies drop `ok` and `id`; failures print `error` and keep `id`
 *   for recovery;
 * - `false`, `null`, and empty containers inside records are omitted, so an
 *   absent field means false/empty;
 * - `{x,y}` records print as `x,y`; item stacks print as `name*count`
 *   (`name@quality*count` for non-normal quality);
 * - scalar-only records print inline as `key=value` pairs; arrays of records
 *   print as tables with shared headers; numbers are rounded to 2 decimals.
 */
type Json = Record<string, unknown>;
function record(value: unknown): value is Json {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}
function isPosition(value: unknown): value is { x: number; y: number } {
  if (!record(value)) return false;
  const keys = Object.keys(value);
  return keys.length === 2 && typeof value.x === 'number' && typeof value.y === 'number';
}
function isStack(value: unknown): value is { name: string; count: number; quality?: string } {
  if (!record(value) || typeof value.name !== 'string' || typeof value.count !== 'number') return false;
  return Object.keys(value).every(key => key === 'name' || key === 'count' || (key === 'quality' && typeof value.quality === 'string'));
}
function empty(value: unknown): boolean {
  return value === null || value === undefined || value === false
    || (Array.isArray(value) && value.length === 0) || (record(value) && Object.values(value).every(empty));
}
function number(value: number): string {
  return Number.isInteger(value) ? String(value) : String(Math.round(value * 100) / 100);
}
function text(value: string): string {
  return /^[A-Za-z_][A-Za-z0-9_./:@*-]*$/.test(value) && !['true', 'false', 'null'].includes(value) ? value : JSON.stringify(value);
}
function keyLabel(key: string): string {
  return /^[A-Za-z_][A-Za-z0-9_-]*$/.test(key) ? key : JSON.stringify(key);
}
/** Scalar rendering, or undefined when the value needs structural layout. */
function inline(value: unknown, nested = false): string | undefined {
  if (typeof value === 'number') return number(value);
  if (typeof value === 'string') return text(value);
  if (typeof value === 'boolean' || value === null || value === undefined) return String(value ?? null);
  if (isPosition(value)) return `${number(value.x)},${number(value.y)}`;
  if (isStack(value)) return `${text(value.name)}${value.quality && value.quality !== 'normal' ? '@' + text(value.quality) : ''}*${number(value.count)}`;
  if (Array.isArray(value)) {
    if (value.length === 0) return '[]';
    const parts = value.map(item => inline(item, true));
    if (parts.every(part => part !== undefined) && value.every(item => !record(item) || isPosition(item) || isStack(item))) {
      return value.every(isStack) && !nested ? parts.join(' ') : '[' + parts.join(', ') + ']';
    }
    return undefined;
  }
  if (record(value)) {
    const entries = Object.entries(value).filter(([, entry]) => !empty(entry));
    if (entries.length === 0) return '{}';
    if (entries.length > 8) return undefined;
    const parts = entries.map(([key, entry]) => [key, inline(entry, true)] as const);
    if (parts.every(([, part]) => part !== undefined && !part.includes('\n'))
        && entries.every(([, entry]) => !record(entry) || isPosition(entry) || isStack(entry))) {
      return parts.map(([key, part]) => `${keyLabel(key)}=${part}`).join(' ');
    }
  }
  return undefined;
}
function flatten(value: Json, prefix = ''): Json {
  const cells: Json = Object.create(null);
  for (const [key, entry] of Object.entries(value)) {
    const path = prefix ? `${prefix}.${keyLabel(key)}` : keyLabel(key);
    if (record(entry) && !isPosition(entry) && !isStack(entry) && Object.keys(entry).length) Object.assign(cells, flatten(entry, path));
    else cells[path] = entry;
  }
  return cells;
}
export function formatCompact(value: unknown): string {
  const lines: string[] = [];
  function render(entry: unknown, label: string, depth: number) {
    const indent = '  '.repeat(depth);
    const prefix = label ? `${label}: ` : '';
    // A reply's lines (inspect compact: one per entity) print one to a line, as they read (Muse, shift13).
    if (label === 'lines' && depth === 0 && Array.isArray(entry) && entry.length > 0 && entry.every(item => typeof item === 'string')) {
      lines.push(`lines[${entry.length}]:`);
      for (const item of entry) lines.push(`  ${item}`);
      return;
    }
    // The top level always lists one field per line.
    const simple = label || !record(entry) ? inline(entry) : undefined;
    if (simple !== undefined) { lines.push(indent + prefix + simple); return; }
    if (Array.isArray(entry) && entry.length > 1 && entry.every(record)) {
      const rows = entry.map(row => flatten(row));
      const columns = [...new Set(rows.flatMap(row => Object.keys(row).filter(key => !empty(row[key]))))];
      // Very heterogeneous records are clearer as individually labelled objects.
      if (columns.length && columns.length <= 24 && rows.every(row => Object.keys(row).length >= columns.length / 2)) {
        lines.push(`${indent}${label}[${rows.length}]: ${columns.join(' | ')}`);
        for (const row of rows) {
          lines.push(`${indent}  ${columns.map(key => empty(row[key]) ? '-' : inline(row[key]) ?? JSON.stringify(row[key])).join(' | ')}`);
        }
        return;
      }
    }
    if (record(entry)) {
      if (label) lines.push(`${indent}${label}:`);
      for (const [key, child] of Object.entries(entry)) {
        if (!empty(child)) render(child, keyLabel(key), depth + (label ? 1 : 0));
      }
    } else if (Array.isArray(entry)) {
      lines.push(`${indent}${label}[${entry.length}]:`);
      entry.forEach((child, index) => render(child, String(index), depth + 1));
    }
  }
  if (record(value) && typeof value.ok === 'boolean') {
    const { ok, id, result, error, ...rest } = value;
    const { body, notes } = lift(record(result) && typeof result.clock === 'string' ? { ...result, clock: shortClock(result.clock) } : result);
    if (!ok) {
      render({ id, ...rest, error_result: body }, '', 0);
      lines.push(`error: ${errorText(error)}${notes.length ? '; ' + notes.join('; ') : ''}`);
    } else {
      render(rest, '', 0);
      if (record(body)) render(byClock(tallyLast(body)), '', 0);
      else if (!empty(body)) render(body, 'result', 0);
      if (notes.length) lines.push(`warning: ${notes.join('; ')}`);
    }
  } else render(value, '', 0);
  return lines.join('\n') + '\n';
}
/**
 * The first line of a walk's --wait reply (d17 batch34 C3, Haiku: `fh call move_to ... --wait && next` stopped at exit 3
 * and the next step ran only after a manual fh wait): whether it arrived. Exit 3 is a wait that ended while the walk goes
 * on: a tell, a mention or an urgent alert ended it, or the wait's own time ran out.
 */
export function walkLine(action: string, value: unknown, exit: number): string | undefined {
  if (action !== 'move_to' || !record(value)) return undefined;
  const r: Json = record(value.result) ? value.result : {};
  const completion: Json = record(r.completion) ? r.completion : {};
  const last: Json = record(r.last) ? r.last : record(completion.last) ? completion.last : {};
  const outcome = [r.outcome, last.outcome, completion.outcome].find(v => typeof v === 'string') as string | undefined;
  if (exit === 3) {
    const sr = r.still_running;
    const what = typeof sr === 'string' ? sr : record(sr) && typeof sr.kind === 'string' ? sr.kind : 'move_to';
    const by = outcome === 'mentioned' ? 'a mention' : outcome === 'urgent' ? 'an urgent alert' : 'a tell';
    const why = r.timed_out === true ? 'the wait timed out' : typeof r.from === 'string' ? `${by} from ${r.from} ended the wait` : 'the wait ended';
    const [kind, ...more] = what.split(', ');
    return `walk: not arrived: ${kind} goes on${more.length ? ', ' + more.join(', ') : ''}; ${why} (exit 3: fh wait waits for it again; --wait-through-tells: a tell or mention does not end the wait)`;
  }
  const pos = [last.position, r.position, completion.position].find(isPosition);
  const at = pos ? ` at (${number(pos.x)},${number(pos.y)})` : '';
  if (value.ok === true) return `walk: arrived${outcome && outcome !== 'arrived' ? ` (${outcome})` : ''}${at}`;
  const err = record(value.error) && typeof value.error.code === 'string' ? value.error.code : undefined;
  return `walk: not arrived: ${outcome ?? err ?? 'failed'}${at}`;
}
/** The error: or warning: line compact output ends with (none for a clean success). */
export function finalLine(value: unknown): string | undefined {
  if (!record(value) || typeof value.ok !== 'boolean') return undefined;
  const { notes } = lift(value.result);
  if (!value.ok) return `error: ${errorText(value.error)}${notes.length ? '; ' + notes.join('; ') : ''}`;
  return notes.length ? `warning: ${notes.join('; ')}` : undefined;
}
/**
 * `fh help ACTION`: one action's arguments from describe, about 1 KB (agents grepped describe.json 52-75 times a
 * shift). Each argument's text is cut to a line; an unknown name lists the actions it resembles.
 */
/** An object with its keys sorted, as the runtime writes calls (aliases.lua encode). */
function sortKeys(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(sortKeys);
  if (!record(value)) return value;
  const out: Record<string, unknown> = {};
  for (const key of Object.keys(value).sort()) out[key] = sortKeys(value[key]);
  return out;
}
export function actionHelp(describe: unknown, action: string, max = 1400): string {
  const actions = record(describe) && record(describe.actions) ? describe.actions : {};
  // An alias (the runtime's M.ALIASES, d17 lean D1) prints the action it runs as.
  const aliases = record(describe) && record(describe.aliases) ? describe.aliases : {};
  const real = aliases[action];
  if (!record(actions[action]) && typeof real === 'string' && record(actions[real])) {
    return `${action} is ${real}: the call runs as ${real}\n` + actionHelp(describe, real, max);
  }
  const schema = actions[action];
  if (!record(schema)) {
    const names = Object.keys(actions).sort();
    const near = names.filter(n => n.includes(action) || action.includes(n) || n.split('_').some(w => w.length > 2 && action.includes(w)));
    return `unknown action ${action}${near.length ? '; did you mean: ' + near.slice(0, 8).join(', ') : ''} (${names.length} actions: fh help ACTION)\n`;
  }
  const cut = (s: string, n: number) => s.length > n ? s.slice(0, n - 3).trimEnd() + '...' : s;
  const doc = new Set(['returns', 'note', 'reports', 'outcomes', 'usage', 'examples']);
  const args = Object.keys(schema).filter(k => !doc.has(k)).sort((a, b) => (a === 'position' ? -1 : b === 'position' ? 1 : a.localeCompare(b)));
  const lines = [`${action}: fh call ${action} --args '{...}'`];
  // Calls that work as written (the runtime's examples; Luna, shift11: fh help launch / transfer), first, whole.
  const examples = Array.isArray(schema.examples) ? schema.examples : [];
  for (const example of examples) lines.push(`example: fh call ${action} --args '${JSON.stringify(sortKeys(example))}'`);
  for (const key of args) lines.push(`  ${key}: ${cut(String(schema[key]), 150)}`);
  for (const key of ['returns', 'note', 'outcomes']) if (typeof schema[key] === 'string') lines.push(`${key}: ${cut(schema[key] as string, 220)}`);
  let out = '';
  for (const line of lines) {
    if (out.length + line.length + 1 > max) { out += `... (${lines.length - out.split('\n').length + 1} more lines: fh call describe)\n`; break; }
    out += line + '\n';
  }
  return out;
}
/**
 * A long compact reply in pages (agent-minds study: Codex drops the middle of output past about 40 KB, agy keeps the
 * last 8 KB): the first `page` bytes at a line boundary, a line saying what is left and how to see it, and the final
 * error:/warning: line again so `| tail -1` still finds it; `rest` is what `fh more` prints next. Text that fits, as it is.
 */
export function paginate(text: string, page = 8000, slack = 2000): { shown: string; rest?: string } {
  if (Buffer.byteLength(text) <= page + slack) return { shown: text };
  const lines = text.replace(/\n$/, '').split('\n');
  const tail = lines[lines.length - 1] ?? '';
  const last = /^(error|warning): /.test(tail) ? tail : undefined;
  const body = last ? lines.slice(0, -1) : lines;
  let used = 0, n = 0;
  while (n < body.length) {
    const size = Buffer.byteLength(body[n] ?? '') + 1;
    if (n > 0 && used + size > page) break;
    used += size; n++;
  }
  const restLines = body.slice(n);
  const rest = restLines.join('\n') + '\n' + (last ? last + '\n' : '');
  const kb = Math.max(1, Math.round(Buffer.byteLength(rest) / 1024));
  const shown = body.slice(0, n).join('\n') + '\n' + `[${restLines.length} more lines, ${kb} KB: ./fh more]\n` + (last ? last + '\n' : '');
  return { shown, rest };
}
/** Full status's teammates line and the standing orders line go right after the clock line. */
function byClock(body: Json): Json {
  if (typeof body.clock !== 'string' || (typeof body.teammates !== 'string' && typeof body.orders !== 'string')) return body;
  const { teammates, orders, ...rest } = body;
  const out: Json = {};
  for (const [key, entry] of Object.entries(rest)) {
    out[key] = entry;
    if (key === 'clock') {
      if (typeof orders === 'string') out.orders = orders;
      if (typeof teammates === 'string') out.teammates = teammates;
    }
  }
  if (orders !== undefined && typeof orders !== 'string') out.orders = orders;
  if (teammates !== undefined && typeof teammates !== 'string') out.teammates = teammates;
  return out;
}
/**
 * A transfer or collect over several targets closes with its total line (Muse): `tally` goes after the action's own
 * fields, before the reply's trailer (team, chat, clock and the like). An item move's inventory line after the move
 * (`inv`, Muse 06:27) closes the whole reply, after the trailer.
 */
const TRAILER = new Set(['team', 'chat', 'clock', 'orders', 'teammates', 'inbox', 'tells']);
function tallyLast(body: Json): Json {
  if (typeof body.tally !== 'string' && typeof body.inv !== 'string') return body;
  const { tally, inv, ...rest } = body;
  const out: Json = {};
  for (const [key, entry] of Object.entries(rest)) if (!TRAILER.has(key)) out[key] = entry;
  if (tally !== undefined) out.tally = tally;
  for (const [key, entry] of Object.entries(rest)) if (TRAILER.has(key)) out[key] = entry;
  if (inv !== undefined) out.inv = inv;
  return out;
}
/** One line, whatever the value. */
function oneLine(value: unknown): string {
  const shown = typeof value === 'string' ? value : inline(value) ?? JSON.stringify(value);
  return shown.replace(/\s*\n\s*/g, ' ');
}
function errorText(error: unknown): string {
  if (!record(error)) return oneLine(error ?? 'failed');
  const { code, message, ...more } = error;
  const extra = Object.entries(more).filter(([, entry]) => !empty(entry)).map(([key, entry]) => `${keyLabel(key)}: ${oneLine(entry)}`);
  return [[code, message].filter(part => !empty(part)).map(oneLine).join(': '), ...extra].join('; ');
}
// Partial results agents must not miss: what a craft or transfer could not do.
// They move from the body to the final error/warning line, so `| tail -1`
// still shows them; copies nested in a --wait reply are reported too.
const NOTES: Record<string, string> = { short: 'short', awaiting_craft: 'awaiting_craft', errors: 'not done',
  none_held: 'none held', tiles_refused: 'tiles refused', extent_warning: 'fluid', corrected: 'corrected',
  nothing_moved: 'nothing moved', turrets_skipped: 'turrets skipped', repeated: 'repeated', stays_disabled: 'stays disabled', condition_ignored: 'condition ignored', unwired: 'unwired', pump_circuits: 'pump circuits', held_blocked: 'held item blocked', closed_in: 'closed in', closes_in: 'closes in', pockets: 'walkable pockets' };
function lift(result: unknown): { body: unknown; notes: string[] } {
  if (!record(result)) return { body: result, notes: [] };
  const notes: string[] = [];
  const body: Json = {};
  for (const [key, entry] of Object.entries(result)) {
    // (a count of 0 is no warning: deconstruct's tiles_refused 0 was a 'warning:' line on every tile call)
    if (NOTES[key] && !empty(entry) && entry !== 0) notes.push(`${NOTES[key]}: ${oneLine(entry)}`);
    else body[key] = entry;
  }
  for (const nested of [result.accepted, result.completion]) {
    if (!record(nested)) continue;
    for (const [key, entry] of Object.entries(nested)) {
      if (NOTES[key] && !empty(entry) && entry !== 0) notes.push(`${NOTES[key]}: ${oneLine(entry)}`);
    }
  }
  return { body, notes };
}
/**
 * The clock line as compact output shows it (d17 lean C3: 133 bytes on every reply, 1 MB a shift): the game time first,
 * then the time since the last request and the idle share, without the words that never change, and hand crafting only
 * when some is queued; what follows (the deadline, a slow game) as it is. The JSON reply keeps the runtime's line
 * (tools/idle_report.py, tools/handover.py and tools/analysis/sleep_share.py read it from the journals).
 *   game 98h40m; +1s since your last request, character idle 0s of it (10%, 0s of that in sleep); hand crafting 0s
 *   queued; deadline in 3h43m  ->  game 98h40m; +1s, idle 0s (10%, 0s in sleep); deadline in 3h43m
 * A line of another shape is shown as it is.
 */
const CLOCK = /^game (\S+); \+(\S+) since your last request, character idle (\S+) of it \((\d+)%(?:, (\S+) of that in ([^),]+))?(?:, on watch: (.+?) for (\S+) of that)?\)(?:, waiting on hand crafting (\S+) of it \((\d+)%\))?; hand crafting (\S+) queued(.*)$/s;
export function shortClock(line: string): string {
  const m = CLOCK.exec(line);
  if (!m) return line;
  const [, game, since, idle, share, inWaits, kinds, watchNames, watched, waited, waitShare, queued, rest] = m;
  return `game ${game}; +${since}, idle ${idle} (${share}%${inWaits ? `, ${inWaits} in ${kinds}` : ''}${watchNames ? `, on watch: ${watchNames} for ${watched}` : ''})`
    + (waited ? `, waiting on hand crafting ${waited} (${waitShare}%)` : '')
    + (queued !== '0s' ? `; hand crafting ${queued} queued` : '') + rest;
}
