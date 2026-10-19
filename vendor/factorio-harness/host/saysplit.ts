// A long say in numbered parts (d19 batch42 A1, viewer Aurora: "Muse's reply was cut mid-word at 500 characters").
// The runtime's say keeps 500 bytes of a line and drops the rest (chat.lua MAX_LEN), so fh posts a longer line as
// "(1/3) ...", "(2/3) ...": each part ends at a sentence end (else a word end), within 500 bytes, and repeats the
// line's leading @names, so every part reaches the same people in the game chat and stays in a viewer's thread on the
// site (tools/stream/viewer_replies.py).

export const SAY_BYTES = 500;
export const SAY_PARTS = 6;
// (d19 batch43 A1, A3) the runtime cuts these without a word past their limit (audience.lua confess, chronicle.lua) or
// with one (tells.lua tell): a tell goes in parts like a say; a confession or a chronicle entry, rate-limited, is refused
export const KEEP: Record<string, Record<string, number>> = {confess:{text:300}, chronicle:{text:600, title:80}};

const bytes = (s: string) => Buffer.byteLength(s, 'utf8');
/** The bytes the runtime counts: control characters as spaces, trimmed. */
export const flatBytes = (s: string) => bytes(s.replace(/[\x00-\x1f\x7f]+/g, ' ').trim());

/** Why a confess or chronicle text would be cut (the field, its bytes and the limit), or undefined. */
export function overLimit(action: string, args: Record<string, unknown>): string | undefined {
  for (const [field, max] of Object.entries(KEEP[action] ?? {})) {
    const v = args[field];
    if (typeof v === 'string' && flatBytes(v) > max) return `${action} ${field} is ${flatBytes(v)} bytes; the limit is ${max}: shorten it; nothing was sent`;
  }
  return undefined;
}

/** The longest prefix of `s` within `max` bytes, never inside a character. */
function headBytes(s: string, max: number): string {
  let out = '', n = 0;
  for (const ch of s) {
    const b = bytes(ch);
    if (n + b > max) break;
    out += ch; n += b;
  }
  return out;
}

/** Pieces of `s` within `max` bytes, cut at spaces (a word longer than `max` alone is cut between characters). */
function byWords(s: string, max: number): string[] {
  const out: string[] = [];
  let rest = s.trim();
  while (bytes(rest) > max) {
    const head = headBytes(rest, max + 1);
    const at = head.lastIndexOf(' ');
    const piece = at > 0 ? rest.slice(0, at) : headBytes(rest, max);
    out.push(piece.trimEnd());
    rest = rest.slice(piece.length).trimStart();
  }
  if (rest) out.push(rest);
  return out;
}

/**
 * The parts fh posts for one say text: [text] when it fits in `max` bytes (newlines read as spaces, as the runtime
 * posts them), else "ADDRESS(k/n) sentence. sentence." parts in order, each within `max` bytes.
 */
export function splitSay(text: string, max = SAY_BYTES): string[] {
  const flat = text.replace(/[\r\n]+/g, ' ').trim();
  if (bytes(flat) <= max) return [flat];
  // the leading addresses ("@Foobator ", "@sol, @luna: ") go on every part
  const lead = /^(?:@[^\s,:]+[,:]?\s+)+/.exec(flat)?.[0] ?? '';
  // (a lead of more than half a part is posted once, as text)
  const address = lead && bytes(lead) <= max / 2 ? lead.trim() + ' ' : '';
  const body = address ? flat.slice(lead.length) : flat;
  // a sentence: up to . ! ? or … (with closing quotes or brackets) and the space after it
  const sentences = body.split(/(?<=[.!?…]["'”’)\]]*)\s+/).filter(s => s);
  const room = max - bytes(address) - bytes('(99/99) ');
  const pieces = sentences.flatMap(s => byWords(s, room));
  const parts: string[] = [];
  for (const p of pieces) {
    const last = parts.length - 1;
    if (last >= 0 && bytes(parts[last]! + ' ' + p) <= room) parts[last] += ' ' + p;
    else parts.push(p);
  }
  return parts.map((p, i) => `${address}(${i + 1}/${parts.length}) ${p}`);
}
