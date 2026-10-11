/** Shrinks Lua source for deployment without changing what it does: drops
 * comments, indentation and trailing spaces, and keeps every line break, so
 * error line numbers still point at the same lines of the bundle. Strings
 * (short and long) are copied untouched. */
export function compactLua(source: string): string {
  const out: string[] = [];
  let i = 0, lineStart = true;
  const n = source.length;
  // A long bracket opening at i ([[, [=[, ...): its level, or -1.
  function longOpen(at: number): number {
    if (source[at] !== '[') return -1;
    let j = at + 1;
    while (source[j] === '=') j++;
    return source[j] === '[' ? j - at - 1 : -1;
  }
  function longEnd(from: number, level: number): number {
    const close = ']' + '='.repeat(level) + ']';
    const end = source.indexOf(close, from);
    if (end < 0) throw new Error('unfinished long string or comment');
    return end + close.length;
  }
  function trimTrailing() {
    while (out.length && (out[out.length - 1] === ' ' || out[out.length - 1] === '\t')) out.pop();
  }
  while (i < n) {
    const c = source[i]!;
    if (c === '\n') { trimTrailing(); out.push('\n'); i++; lineStart = true; continue; }
    if ((c === ' ' || c === '\t' || c === '\r') && lineStart) { i++; continue; }
    if (c === '-' && source[i + 1] === '-') {
      const level = longOpen(i + 2);
      if (level >= 0) {
        // A long comment becomes its line breaks, or one space between tokens.
        const end = longEnd(i + 4 + level, level);
        const breaks = source.slice(i, end).split('\n').length - 1;
        if (breaks) { trimTrailing(); out.push('\n'.repeat(breaks)); lineStart = true; }
        else out.push(' ');
        i = end;
      } else {
        while (i < n && source[i] !== '\n') i++;
      }
      continue;
    }
    lineStart = false;
    if (c === '"' || c === "'") {
      let j = i + 1;
      while (j < n && source[j] !== c) {
        if (source[j] === '\\') j++;
        else if (source[j] === '\n') throw new Error('unfinished string');
        j++;
      }
      if (j >= n) throw new Error('unfinished string');
      out.push(source.slice(i, j + 1));
      i = j + 1;
      continue;
    }
    const level = longOpen(i);
    if (level >= 0) {
      const end = longEnd(i + 2 + level, level);
      const text = source.slice(i, end);
      out.push(text);
      if (text.includes('\n')) lineStart = false;
      i = end;
      continue;
    }
    // Runs of spaces inside a line shrink to one.
    if (c === ' ' || c === '\t' || c === '\r') {
      if (out[out.length - 1] !== ' ') out.push(' ');
      i++;
      continue;
    }
    out.push(c);
    i++;
  }
  trimTrailing();
  return out.join('');
}
