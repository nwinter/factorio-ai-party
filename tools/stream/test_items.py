#!/usr/bin/env python3
"""Item icon checks: python3 tools/stream/test_items.py

- The Python port (items.py) and the JS module (static/items.js, run under node) give identical SVG, labels and
  colours for every drawn item and for unknown names (crate fallback).
- Every template is 16x16 and every letter it uses resolves for every item drawn with it (no missing colour).
- Every item the stream model can put in the production widget has its own icon.
- items.js holds what tools/stream/items_art.js generates (the JSON was not edited by hand).
"""
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import items  # noqa: E402

JS = os.path.join(HERE, "static", "items.js")
UNKNOWN = ["assembling-machine-1", "some_modded--thing", "", "---", "ñandú-ore", "👩‍🚀 crate", "a&b<c>\"d", "x" * 60]


def node_render(names):
    script = ("const I=require(%s);let s='';process.stdin.on('data',d=>s+=d);process.stdin.on('end',()=>{"
              "const n=JSON.parse(s);process.stdout.write(JSON.stringify({names:I.names,"
              "svg:n.map(x=>I.svg(x,40)),label:n.map(I.label),color:n.map(I.color),has:n.map(I.has)}));});") % json.dumps(JS)
    r = subprocess.run(["node", "-e", script], input=json.dumps(names), capture_output=True, text=True, check=True)
    return json.loads(r.stdout)


def main():
    fails = []
    names = items.NAMES + UNKNOWN
    js = node_render(names)
    if js["names"] != items.NAMES:
        fails.append("item order differs between JS and Python")
    for i, n in enumerate(names):
        for key, py in (("svg", items.svg(n, 40)), ("label", items.label(n)), ("color", items.color(n)),
                        ("has", items.has(n))):
            if js[key][i] != py:
                fails.append("%s %r: JS %r != Python %r" % (key, n, str(js[key][i])[:80], str(py)[:80]))

    for t, rows in items.ITEMS["templates"].items():
        if len(rows) != items.SIZE or any(len(r) != items.SIZE for r in rows):
            fails.append("template %s is not %dx%d" % (t, items.SIZE, items.SIZE))
    for n in names:
        it = items._item(n)
        pal = items._palette(it)
        used = {ch for r in items.ITEMS["templates"][it["t"]] for ch in r if ch != "."}
        missing = sorted(used - set(pal))
        if missing:
            fails.append("%s: template %s uses %s but the item has no colour for it" % (n or "''", it["t"], "".join(missing)))
        if sum(1 for row in items.pixels(n) for c in row if c) < 40:
            fails.append("%s: almost empty icon" % n)

    import model  # the production widget's item list
    for n in model.SPARK_ITEMS:
        if not items.has(n):
            fails.append("production widget item %s has no icon" % n)

    gen = subprocess.run(["node", os.path.join(HERE, "items_art.js"), "--json"], capture_output=True, text=True, check=True)
    if json.loads(gen.stdout) != items.ITEMS:
        fails.append("static/items.js differs from what items_art.js generates (run: node tools/stream/items_art.js)")

    if fails:
        print("\n".join(fails))
        print("items: %d failures" % len(fails))
        return 1
    print("items: ok (%d icons + %d fallbacks, JS and Python identical)" % (len(items.NAMES), len(UNKNOWN)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
