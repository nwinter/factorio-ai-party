#!/usr/bin/env python3
"""Python port of tools/stream/static/avatar.js (agent pixel-art avatars), for static site builds.

The part lists and pixel art are read from avatar.js itself (the JSON between /*@parts*/ and /*@end*/), so only
the drawing logic is duplicated here. Output is byte-identical to the JS module; tools/stream/test_avatar.py checks
that against node.

    from avatar import svg, resolve
    svg({"name": "astra", "color": "#9977ff", "avatar": {"base": "robot"}}, 48)

CLI:
    python3 tools/stream/avatar.py NAME [--color '#9977ff'] [--avatar '{"base":"robot"}'] [--size 64] > astra.svg
    python3 tools/stream/avatar.py --profiles profiles.json --out DIR      # one NAME.svg per `profiles` row
    python3 tools/stream/avatar.py --casters --out DIR                     # the stream hosts (static/casters.js)
"""
import json
import math
import os
import re
import sys

SIZE = 24
M32 = 0xFFFFFFFF
JS_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "static", "avatar.js")


def _load_parts(path=JS_PATH):
    with open(path, encoding="utf-8") as f:
        text = f.read()
    body = text.split("/*@parts*/", 1)[1].split("/*@end*/", 1)[0]
    body = body[body.index("{"): body.rindex("}") + 1]
    return json.loads(body)


PARTS = _load_parts()
_HEX = re.compile(r"#[0-9a-fA-F]{6}")


def _hash(text):
    h = 0x811C9DC5
    for b in str(text).encode("utf-8", "surrogatepass"):
        h = ((h ^ b) * 0x01000193) & M32
    return h


def _rng(seed):
    state = [seed & M32]

    def nxt():
        state[0] = (state[0] + 0x6D2B79F5) & M32
        t = state[0]
        t = ((t ^ (t >> 15)) * (t | 1)) & M32
        t = (t ^ ((t + (((t ^ (t >> 7)) * (t | 61)) & M32)) & M32)) & M32
        return ((t ^ (t >> 14)) & M32) % 1000003

    return nxt


def _is_hex(v):
    return isinstance(v, str) and _HEX.fullmatch(v) is not None


def _parse(h):
    if not isinstance(h, str):
        return None
    m = re.fullmatch(r"#?([0-9a-fA-F]{6})", h)
    if not m:
        return None
    n = int(m.group(1), 16)
    return [(n >> 16) & 255, (n >> 8) & 255, n & 255]


def _hex(c):
    return "#" + "".join("%02x" % v for v in c)


def _mix(a, b, t):
    return [int(math.floor(a[i] + (b[i] - a[i]) * t + 0.5)) for i in range(3)]


def _luma(c):
    return (c[0] * 299 + c[1] * 587 + c[2] * 114) / 255000


def _dist(a, b):
    return abs(a[0] - b[0]) + abs(a[1] - b[1]) + abs(a[2] - b[2])


BLACK, WHITE = [0, 0, 0], [255, 255, 255]


def _name(profile):
    return str(profile.get("name") or profile.get("display_name") or "agent")


def validate(avatar):
    """Errors as the harness words them; [] when valid. None or False (no avatar) is valid."""
    if avatar is None or avatar is False:
        return []
    if not isinstance(avatar, dict):
        return ["avatar must be an object"]
    errors = []
    for k, v in avatar.items():
        if k == "accent":
            if not _is_hex(v):
                errors.append('avatar.accent must be "#rrggbb"')
        elif k not in PARTS["options"]:
            errors.append("avatar: unknown field " + k)
        elif v not in PARTS["options"][k]:
            errors.append("avatar." + k + " must be one of " + "|".join(PARTS["options"][k]))
    return errors


def resolve(profile):
    """The full spec drawn for a `profiles` row: parts, color and accent (unset parts follow from the name)."""
    profile = profile or {}
    av = profile.get("avatar") if isinstance(profile.get("avatar"), dict) else {}
    nxt = _rng(_hash(_name(profile)))
    out = {}
    for f in PARTS["fields"]:
        options, r = PARTS["options"][f], nxt()
        pool = PARTS["picks"].get(f, options)  # parts added later are choosable but not drawn by default
        v = av.get(f)
        out[f] = v if isinstance(v, str) and v in options else pool[r % len(pool)]
    color_pick, accent_pick = nxt(), nxt()
    suit = _parse(profile.get("color") if _is_hex(profile.get("color")) else None) or \
        _parse(PARTS["colors"][color_pick % len(PARTS["colors"])])
    out["color"] = _hex(suit)
    accent = _parse(av["accent"]) if _is_hex(av.get("accent")) else None
    if not accent:
        n = len(PARTS["accents"])
        for i in range(n):
            c = _parse(PARTS["accents"][(accent_pick + i) % n])
            if _dist(c, suit) >= 180:
                accent = c
                break
        accent = accent or _parse(PARTS["accents"][accent_pick % n])
    out["accent"] = _hex(accent)
    return out


def _palette(spec):
    suit, accent = _parse(spec["color"]), _parse(spec["accent"])
    p = dict(PARTS["fixed"])
    dark = _luma(suit) < 0.16
    p["o"] = _hex(_mix(suit, WHITE, 0.42)) if dark else PARTS["fixed"]["o"]
    p["s"] = _hex(_mix(suit, WHITE, 0.1) if dark else suit)
    p["S"] = _hex(_mix(suit, WHITE, 0.04) if dark else _mix(suit, BLACK, 0.32))
    p["h"] = _hex(_mix(suit, WHITE, 0.26 if dark else 0.38))
    p["a"] = _hex(accent)
    p["A"] = _hex(_mix(accent, BLACK, 0.3))
    p["b"] = _hex(_mix(accent, WHITE, 0.4))
    p["g"] = _hex(_mix(accent, WHITE, 0.2))
    p["G"] = _hex(_mix(accent, WHITE, 0.72))
    p["V"] = _hex(_mix(accent, WHITE, 0.62))
    return p


def _stamp(grid, rows, x0, y0, mirror, pal):
    for j, row in enumerate(rows):
        if mirror:
            row = row + row[::-1]
        for i, ch in enumerate(row):
            x, y = x0 + i, y0 + j
            if ch == "." or x < 0 or y < 0 or x >= SIZE or y >= SIZE:
                continue
            grid[y][x] = pal[ch]


def _backdrop(grid, spec, h):
    bd = PARTS["backdrops"][spec["backdrop"]]
    for y in range(SIZE):
        for x in range(SIZE):
            grid[y][x] = bd["bg"]
    kind = spec["backdrop"]
    if kind == "dark":
        for x in range(SIZE):
            grid[0][x] = bd["edge"]
        for y in range(SIZE):
            grid[y][0] = bd["edge"]
    elif kind == "grid":
        for y in range(SIZE):
            for x in range(SIZE):
                if x % 6 == 2 or y % 6 == 2:
                    grid[y][x] = bd["line"]
    elif kind == "hazard":
        for y in range(SIZE):
            for x in range(SIZE):
                if (x + y) % 8 < 3:
                    grid[y][x] = bd["stripe"]
                if y < 2:
                    grid[y][x] = bd["band"][((x + y) // 3) % 2]
    elif kind == "glow":
        suit, base = _parse(spec["color"]), _parse(bd["bg"])
        for y in range(SIZE):
            for x in range(SIZE):
                d = max(abs(2 * x - 23), abs(2 * y - 19)) >> 1
                t = 0.34 if d < 4 else 0.24 if d < 7 else 0.14 if d < 10 else 0.06
                grid[y][x] = _hex(_mix(base, suit, t))
    elif kind == "night":
        for i, (sx, sy) in enumerate(bd["stars"]):
            if ((h >> i) & 1) == 0 or i < 4:
                grid[sy][sx] = "#d8dcef"


def pixels(profile):
    """24 rows of 24 '#rrggbb' strings."""
    profile = profile or {}
    spec = resolve(profile)
    pal = _palette(spec)
    grid = [[None] * SIZE for _ in range(SIZE)]
    base = PARTS["bases"][spec["base"]]
    _backdrop(grid, spec, _hash(_name(profile)))
    acc = PARTS["accessories"][spec["accessory"]] if spec["accessory"] != "none" else None
    if acc and acc["layer"] == "back":
        _stamp(grid, acc["rows"], 0, base["top"] + acc["dy"], False, pal)
    _stamp(grid, base["rows"], 0, 0, base["mirror"], pal)
    if spec["emblem"] != "none":
        _stamp(grid, PARTS["emblems"][spec["emblem"]], base["chest"][0], base["chest"][1], False, pal)
    if spec["helmet"] != "none":
        hm = PARTS["helmets"][spec["helmet"]]
        _stamp(grid, hm["rows"], hm["x"], base["top"] + hm["dy"], hm["mirror"], pal)
    if spec["visor"] != "none":
        vs = PARTS["visors"][spec["visor"]]
        _stamp(grid, vs["rows"], vs["x"], base["eye"] + vs["dy"], vs["mirror"], pal)
    if acc and acc["layer"] == "front":
        _stamp(grid, acc["rows"], 0, base["top"] + acc["dy"], False, pal)
    return grid


def _esc(s):
    return str(s).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;")


def svg(profile, size=48, title=None):
    """SVG string; profile is a `profiles` row ({name, display_name, color, avatar})."""
    profile = profile or {}
    grid = pixels(profile)
    order, runs = [], {}
    for y in range(SIZE):
        x = 0
        while x < SIZE:
            c, w = grid[y][x], 1
            while x + w < SIZE and grid[y][x + w] == c:
                w += 1
            if c:
                if c not in runs:
                    runs[c] = []
                    order.append(c)
                runs[c].append("M%d %dh%dv1h-%dz" % (x, y, w, w))
            x += w
    label = title if title is not None else (profile.get("display_name") or profile.get("name") or "agent") + " avatar"
    out = ['<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="%s" height="%s" '
           'shape-rendering="crispEdges" role="img" aria-label="%s">' % (size, size, _esc(label))]
    for c in order:
        out.append('<path fill="%s" d="%s"/>' % (c, "".join(runs[c])))
    out.append("</svg>")
    return "".join(out)


def random(seed):
    """A random valid avatar spec."""
    nxt = _rng(_hash("random:" + str(seed)))
    out = {}
    for f in PARTS["fields"]:
        options = PARTS["options"][f]
        out[f] = options[nxt() % len(options)]
    if nxt() % 3 == 0:
        out["accent"] = PARTS["accents"][nxt() % len(PARTS["accents"])]
    return out


CASTERS_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "static", "casters.js")


def casters(path=CASTERS_PATH):
    """The stream hosts as profiles-style rows, keyed like caster.py ("pbp", "color"), from static/casters.js."""
    with open(path, encoding="utf-8") as f:
        text = f.read()
    body = text.split("/*@casters*/", 1)[1].split("/*@end*/", 1)[0]
    data = json.loads(body[body.index("{"): body.rindex("}") + 1])
    return {k: {"name": c["name"], "display_name": c["name"], "color": c["color"], "avatar": c["avatar"],
                "role": c["role"], "kind": "caster"} for k, c in data.items()}


def main(argv):
    import argparse
    ap = argparse.ArgumentParser(description="Render agent avatars as SVG")
    ap.add_argument("name", nargs="?")
    ap.add_argument("--color")
    ap.add_argument("--avatar", help="JSON avatar spec")
    ap.add_argument("--size", type=int, default=64)
    ap.add_argument("--profiles", help="JSON file: a `profiles` reply or a list of rows")
    ap.add_argument("--casters", action="store_true", help="render the stream hosts from static/casters.js")
    ap.add_argument("--out", help="directory for --profiles/--casters output")
    a = ap.parse_args(argv)
    if a.profiles or a.casters:
        if a.casters:
            rows = list(casters().values())
        else:
            with open(a.profiles, encoding="utf-8") as f:
                data = json.load(f)
            rows = data.get("profiles", []) if isinstance(data, dict) else data
        os.makedirs(a.out or ".", exist_ok=True)
        for row in rows:
            path = os.path.join(a.out or ".", re.sub(r"[^A-Za-z0-9_.-]", "_", str(row.get("name", "agent"))) + ".svg")
            with open(path, "w", encoding="utf-8") as f:
                f.write(svg(row, a.size))
            print(path)
        return 0
    if not a.name:
        ap.error("NAME or --profiles is required")
    profile = {"name": a.name}
    if a.color:
        profile["color"] = a.color
    if a.avatar:
        profile["avatar"] = json.loads(a.avatar)
        errors = validate(profile["avatar"])
        if errors:
            print("; ".join(errors), file=sys.stderr)
            return 2
    sys.stdout.write(svg(profile, a.size) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
