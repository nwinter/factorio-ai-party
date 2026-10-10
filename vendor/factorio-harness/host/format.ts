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
    const { ok, id, result, ...rest } = value;
    if (!ok) render({ error: value.error, id, ...rest, error_result: result }, '', 0);
    else {
      render(rest, '', 0);
      if (record(result)) render(result, '', 0);
      else if (!empty(result)) render(result, 'result', 0);
    }
  } else render(value, '', 0);
  return lines.join('\n') + '\n';
}
