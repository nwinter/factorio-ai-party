/**
 * `fh say --look`: a camera hint for the stream while the line is read out (chat.lua checks it in the game).
 *   platform:Sunward | agent:sol | 120,-40 | 120,-40@vulcanus | 100,-60,140,-20[@surface]
 */
export function parseLook(value: string): Record<string, unknown> {
  const v = value.trim();
  const named = v.match(/^(platform|agent):(.+)$/i);
  if (named) return { [named[1]!.toLowerCase()]: named[2]!.trim() };
  const [coords, surface] = v.split('@');
  const n = (coords ?? '').split(',').map(s => Number(s.trim()));
  if (n.every(Number.isFinite) && (n.length === 2 || n.length === 4)) {
    const at = surface ? { surface: surface.trim() } : {};
    if (n.length === 2) return { position: { x: n[0], y: n[1] }, ...at };
    return { area: { left_top: { x: Math.min(n[0]!, n[2]!), y: Math.min(n[1]!, n[3]!) },
      right_bottom: { x: Math.max(n[0]!, n[2]!), y: Math.max(n[1]!, n[3]!) } }, ...at };
  }
  throw new Error('--look must be platform:NAME, agent:NAME, X,Y[@SURFACE] or X1,Y1,X2,Y2[@SURFACE]');
}
