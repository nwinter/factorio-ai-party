"""File-only target/geometry checks for recap details. Never steer a camera."""
import math
import re

# Coordinates alone are not a component identity. Ambiguous prose stays an overview.
NAME = re.compile(r"\b(?:(?:front|rear|aft|bow|stern)[ -](?:left|right)\s+)?(?:[a-z]+[ -])?(?:turret|thruster|engine|crusher|collector|inserter|belt|assembler|reactor|silo|hub|pipe|tank|explosion|impact|breach)\b", re.I)
COORD = re.compile(r"\(\s*(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)\s*\)|\bx\s*[=:]\s*(-?\d+(?:\.\d+)?)\s*[,; ]+y\s*[=:]\s*(-?\d+(?:\.\d+)?)", re.I)
MAX_AGE = 300


def finite(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v)


def target(line, refs):
    text = line.get('title', '') + ' ' + line.get('text', '')
    names = list(NAME.finditer(text))
    if not names:
        return None
    name = names[-1][0]
    positions = {tuple(float(v) for v in (m.groups()[:2] if m[1] else m.groups()[2:])) for m in COORD.finditer(text)}
    if not positions:
        # A cited row may resolve shorthand only when it names this same component.
        for row in refs:
            if name.casefold() in row.get('text', '').casefold():
                positions.update(tuple(float(v) for v in (m.groups()[:2] if m[1] else m.groups()[2:]))
                                 for m in COORD.finditer(row['text']))
    phase = 'before' if re.search(r'\bbefore\b', text, re.I) else 'after' if re.search(r'\bafter\b', text, re.I) else 'near'
    position = list(next(iter(positions))) if len(positions) == 1 else None
    matched = [r for r in refs if name.casefold() in r.get('text', '').casefold() and position and
               any([float(v) for v in (m.groups()[:2] if m[1] else m.groups()[2:])] == position
                   for m in COORD.finditer(r['text'])) and finite(r.get('t'))]
    return {'name': name, 'position': position, 'phase': phase,
            'record_t': max(r['t'] for r in matched) if matched else None}


def capture_view(receipt, px):
    """Full physical source (not the compositor crop); only stationary world views.

    Moving/follow/map requests do not establish a settled camera centre. Keep their
    receipts for audit, but never manufacture detail geometry from them.
    """
    shot = receipt.get('on_air') or {}
    frame = (receipt.get('frame') or {}).get('frame') or {}
    if any(shot.get(k) for k in ('move', 'glide', 'follow', 'map')) or frame.get('follow'):
        return None
    pos, zoom = frame.get('position'), frame.get('zoom')
    if pos != shot.get('position') or zoom != shot.get('game_zoom'):
        return None
    if not isinstance(pos, dict) or not all(finite(pos.get(k)) for k in ('x', 'y')) or not finite(zoom) or zoom <= 0:
        return None
    if len(px) != 2 or not all(finite(v) and v > 0 for v in px):
        return None
    h = 1080 / (32 * zoom)
    w = h * px[0] / px[1]
    return {'box': [pos['x'] - w / 2, pos['y'] - h / 2, w, h], 'px': list(px),
            'zoom': zoom, 'surface': frame.get('surface'), 'kind': 'world', 'basis': 'settled camera receipts'}


def view(row):
    v = row.get('view')
    if not isinstance(v, dict):
        # Legacy batch395 stills retained both receipts, though preparation used to discard them.
        a, b = row.get('receipt') or {}, row.get('after_receipt') or {}
        av, bv = capture_view(a, row.get('px') or []), capture_view(b, row.get('px') or [])
        v = av if av and av == bv else None
    if not v or v.get('kind') not in ('world', 'map'):
        return None
    box, px = v.get('box'), v.get('px')
    if not isinstance(box, list) or len(box) != 4 or not all(finite(n) for n in box) or min(box[2:]) <= 0:
        return None
    if not isinstance(px, list) or len(px) != 2 or not all(finite(n) and n > 0 for n in px):
        return None
    if v.get('surface') and row.get('surface') and v['surface'] != row['surface']:
        return None
    return {k: v[k] for k in ('box', 'px', 'kind', 'zoom', 'surface') if k in v}


def anchor(media, wanted, stamp):
    v, p = media.get('view'), wanted['position']
    if not v or v['kind'] != 'world' or not p or media['kind'] != 'image' or abs(media['t'] - stamp) > MAX_AGE:
        return None
    if wanted['phase'] == 'before' and media['t'] > stamp or wanted['phase'] == 'after' and media['t'] < stamp:
        return None
    x, y, w, h = v['box']
    # Three-tile margin contains the component and highlight, not just its centre.
    if not (x + 3 <= p[0] <= x + w - 3 and y + 3 <= p[1] <= y + h - 3):
        return None
    pw, ph = v['px']
    sx, sy = pw / w, ph / h
    if min(sx, sy) * 6 < 12:  # too small to resolve a detail
        return None
    cx, cy = (p[0] - x) * sx, (p[1] - y) * sy
    cw, ch = min(pw, 24 * sx), min(ph, 18 * sy)
    left, top = max(0, min(pw - cw, cx - cw / 2)), max(0, min(ph - ch, cy - ch / 2))
    return {'crop': [left, top, cw, ch], 'point': [cx, cy], 'radius': [3 * sx, 3 * sy],
            'px': v['px'], 'name': wanted['name'], 'context_seconds': 2,
            'timing': 'at record time' if media['t'] == stamp else ('before record' if media['t'] < stamp else 'after record'),
            'delta_seconds': round(media['t'] - stamp, 1)}
