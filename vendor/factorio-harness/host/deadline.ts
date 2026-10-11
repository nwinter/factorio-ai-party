/**
 * Time left until the workspace deadline, for the `clock:` line. The file holds
 * one line such as `2026-10-10 22:48 PDT` (tools/new-run.sh writes it with
 * `date "+%Y-%m-%d %H:%M %Z"`); without a known zone it is local time.
 */
const ZONES: Record<string, number> = { UTC: 0, GMT: 0, Z: 0, PST: -8, PDT: -7, MST: -7, MDT: -6, CST: -6, CDT: -5,
  EST: -5, EDT: -4, AKST: -9, AKDT: -8, HST: -10, BST: 1, CET: 1, CEST: 2, EET: 2, EEST: 3, IST: 5.5, JST: 9, AEST: 10, AEDT: 11 };
export function parseDeadline(text: string): number | undefined {
  const line = text.trim().split('\n')[0]!.trim();
  const match = line.match(/^(\d{4})-(\d{2})-(\d{2})[ T](\d{1,2}):(\d{2})(?::(\d{2}))?\s*(Z|[A-Za-z]{2,5}|[+-]\d{2}:?\d{2})?$/);
  if (!match) {
    const parsed = Date.parse(line);
    return Number.isNaN(parsed) ? undefined : parsed;
  }
  const [, y, mo, d, h, mi, s, zone] = match;
  const parts = [Number(y), Number(mo) - 1, Number(d), Number(h), Number(mi), Number(s ?? 0)] as const;
  let offset: number | undefined;
  if (zone && /^[+-]/.test(zone)) {
    const digits = zone.replace(':', '');
    offset = (zone[0] === '-' ? -1 : 1) * (Number(digits.slice(1, 3)) + Number(digits.slice(3, 5)) / 60);
  } else if (zone) offset = ZONES[zone.toUpperCase()];
  if (offset === undefined) return new Date(...parts).getTime();
  return Date.UTC(...parts) - offset * 3600000;
}
function span(ms: number): string {
  const minutes = Math.floor(ms / 60000);
  if (minutes >= 60) return `${Math.floor(minutes / 60)}h${String(minutes % 60).padStart(2, '0')}m`;
  return minutes < 1 ? `${Math.max(0, Math.floor(ms / 1000))}s` : `${minutes}m`;
}
export function deadlineText(at: number, now = Date.now()): string {
  return at >= now ? `deadline in ${span(at - now)}` : `deadline passed ${span(now - at)} ago`;
}
