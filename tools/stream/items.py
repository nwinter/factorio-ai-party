#!/usr/bin/env python3
"""Python port of tools/stream/static/items.js (pixel-art item icons), for static site builds.

The templates, palettes and item table are read from items.js itself (the JSON between /*@items*/ and /*@end*/),
so only the drawing logic is duplicated here. Output is byte-identical to the JS module; tools/stream/test_items.py
checks that against node.

    from items import svg, label, color
    svg("electronic-circuit", 32)

CLI:
    python3 tools/stream/items.py iron-plate [--size 64] > iron-plate.svg
    python3 tools/stream/items.py --all --out DIR [--size 32]     # one NAME.svg per drawn item
"""
import json
import math
import os
import re
import sys

M32 = 0xFFFFFFFF
JS_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "static", "items.js")


def _load_items(path=JS_PATH):
    with open(path, encoding="utf-8") as f:
        text = f.read()
    body = text.split("/*@items*/", 1)[1].split("/*@end*/", 1)[0]
    body = body[body.index("{"): body.rindex("}") + 1]
    return json.loads(body)


ITEMS = _load_items()
SIZE = ITEMS["size"]
NAMES = list(ITEMS["items"])
BLACK, WHITE = [0, 0, 0], [255, 255, 255]


def _hash(text):
    h = 0x811C9DC5
    for b in str(text).encode("utf-8", "surrogatepass"):
        h = ((h ^ b) * 0x01000193) & M32
    return h


def _parse(h):
    n = int(h[1:], 16)
    return [(n >> 16) & 255, (n >> 8) & 255, n & 255]


def _hex(c):
    return "#" + "".join("%02x" % v for v in c)


def _mix(a, b, t):
    return [int(math.floor(a[i] + (b[i] - a[i]) * t + 0.5)) for i in range(3)]


def _luma(c):
    return (c[0] * 299 + c[1] * 587 + c[2] * 114) / 255000


def _ramp(color):
    c = _parse(color)
    dark = _luma(c) < 0.2
    return [
        _hex(_mix(c, WHITE, 0.22) if dark else _mix(c, BLACK, 0.62)),
        _hex(_mix(c, BLACK, 0.25) if dark else _mix(c, BLACK, 0.3)),
        _hex(c),
        _hex(_mix(c, WHITE, 0.2 if dark else 0.32)),
        _hex(_mix(c, WHITE, 0.45 if dark else 0.64)),
    ]


def _humanize(name):
    s = re.sub(r"[-_]+", " ", str(name or "item")).strip()
    return s[:1].upper() + s[1:]


def _item(name):
    it = ITEMS["items"].get(name)
    if it is not None:
        return it
    f = ITEMS["fallback"]
    c = f["colors"][_hash(str(name)) % len(f["colors"])]
    return {"label": _humanize(name), "t": f["t"], "c": c, "color": c}


def has(name):
    return name in ITEMS["items"]


def label(name):
    return _item(name)["label"]


def color(name):
    it = _item(name)
    return it.get("color") or it["c"]


def _palette(it):
    p = dict(ITEMS["fixed"])
    for key in ("c", "c2", "c3"):
        if it.get(key):
            for letter, shade in zip(ITEMS["letters"][key], _ramp(it[key])):
                p[letter] = shade
    return p


def pixels(name):
    it = _item(name)
    pal = _palette(it)
    rows = ITEMS["templates"][it["t"]]
    return [[None if ch == "." else pal.get(ch) for ch in rows[y][:SIZE]] for y in range(SIZE)]


def _esc(s):
    return str(s).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;")


def svg(name, size=32, title=None):
    grid = pixels(name)
    order, runs = [], {}
    for y in range(SIZE):
        x = 0
        while x < SIZE:
            c, w = grid[y][x], 1
            while x + w < SIZE and grid[y][x + w] == c:
                w += 1
            if c:
                if c not in runs:
                    runs[c] = ""
                    order.append(c)
                runs[c] += "M%d %dh%dv1h-%dz" % (x, y, w, w)
            x += w
    lab = title if title is not None else label(name)
    out = ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 %d %d" width="%s" height="%s" '
           'shape-rendering="crispEdges" role="img" aria-label="%s">') % (SIZE, SIZE, size, size, _esc(lab))
    return out + "".join('<path fill="%s" d="%s"/>' % (c, runs[c]) for c in order) + "</svg>"


def main(argv):
    import argparse
    ap = argparse.ArgumentParser(description="Render item icons as SVG.")
    ap.add_argument("name", nargs="?", help="item name, e.g. iron-plate")
    ap.add_argument("--size", type=int, default=32)
    ap.add_argument("--all", action="store_true", help="write every drawn item to --out")
    ap.add_argument("--out", help="output directory for --all")
    a = ap.parse_args(argv)
    if a.all:
        if not a.out:
            ap.error("--all needs --out DIR")
        os.makedirs(a.out, exist_ok=True)
        for n in NAMES:
            with open(os.path.join(a.out, n + ".svg"), "w", encoding="utf-8") as f:
                f.write(svg(n, a.size))
        print("%d icons -> %s" % (len(NAMES), a.out))
        return 0
    if not a.name:
        ap.error("give an item name or --all")
    sys.stdout.write(svg(a.name, a.size) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
