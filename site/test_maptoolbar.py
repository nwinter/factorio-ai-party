#!/usr/bin/env python3
"""The map toolbar's layout in a browser (d22 batch75 AK5, viewer Aurora 08:57: "Please compact the toolbar: Terrain +
Networks in one row, Combat + Team below. Narrow the item picker, use Power/Logistics labels, keep planets separate and
wrap groups on small screens."; AK7, site:4183: "Could you put category labels beside the buttons and tighten the gaps
between groups, rows and the planet selector?"): python3 site/test_maptoolbar.py

static/mapview.js with static/style.css in headless Chromium (Playwright from the npx cache, as tools/site_shots.js
finds it; skipped when there is none), the toolbar 595 px wide (the live map card on a desktop) and 364 px (a 400 px
phone). Wide: the planet row on its own; Terrain and Networks side by side, Combat and Team side by side below; the
picker at most 6.5rem, its label ("Item: -", or an item's name) whole beside its arrow. Narrow: one group a row. At both: each label at the left of its buttons, on their first line, and
the gaps tight (the planet row within 12 px above the groups, the pairs within 6 px). On both, every control
sits at the same place on Nauvis, Gleba and Aquilo, and nothing is wider than the toolbar.
"""
import glob, json, os, shutil, subprocess, sys, tempfile

SITE = os.path.dirname(os.path.abspath(__file__))

PAGE = """<!doctype html><meta charset="utf-8"><style>%s</style><body style="margin:0;background:#222;color:#ddd;font:16px sans-serif">
<div id="host" style="width:%dpx"></div><script>%s</script><script>
window.addEventListener('error', function (e) { document.title = 'ERR ' + e.message; });
</script>"""

JS = r"""
const pw = require(process.argv[2]);
const [exe, pageFile, fxFile] = process.argv.slice(3);
const fx = JSON.parse(require('fs').readFileSync(fxFile, 'utf8'));
(async () => {
  const b = await pw.chromium.launch(exe ? { executablePath: exe } : {});
  const out = {};
  for (const [name, w] of [['wide', 595], ['narrow', 364]]) {
    const page = await b.newPage({ viewport: { width: w + 20, height: 900 } });
    await page.goto('file://' + pageFile.replace('WIDTH', w));
    out[name] = {};
    for (const planet of ['nauvis', 'gleba', 'aquilo']) {
      out[name][planet] = await page.evaluate(([data, planet]) => {
        if (!window.view) { window.view = PogMap.create(document.getElementById('host'), { storeKey: 't' }); window.view.set(data); }
        const v = window.view;
        if (planet !== v.surface) v.onClick({ target: { closest: () => ({ dataset: { surface: planet } }) } });
        const host = document.getElementById('host').getBoundingClientRect();
        const r = (e) => { const b = e.getBoundingClientRect(); return [Math.round(b.left - host.left), Math.round(b.top - host.top), Math.round(b.width), Math.round(b.height)]; };
        const q = (s) => [...document.querySelectorAll(s)];
        return { title: document.title,
          planets: r(document.querySelector('.mapview-planets')),
          boxes: q('.mapview-gbox').map((g) => [g.querySelector('.mapview-group-label').textContent, r(g), r(g.querySelector('.mapview-group-label'))]),
          controls: q('.mapview-group > *').map((e) => [e.dataset.layer || 'item', r(e)]),
          widest: Math.max(...q('.mapview-layers *').map((e) => e.getBoundingClientRect().right - host.left)),
          // (AK7) the picker's shown label against the room beside its arrow (about 20 px)
          pick: (function () {
            const s = document.querySelector('.mapview-item'), cs = getComputedStyle(s), c = document.createElement('canvas').getContext('2d');
            c.font = cs.font;
            const label = s.options[s.selectedIndex].text;
            return { label, text: Math.ceil(c.measureText(label).width), room: Math.floor(s.clientWidth - parseFloat(cs.paddingLeft) - parseFloat(cs.paddingRight) - 20) };
          })() };
      }, [fx, planet]);
    }
    await page.close();
  }
  await b.close();
  process.stdout.write(JSON.stringify(out));
})().catch((e) => { console.error(e); process.exit(1); });
"""


def check(name, ok, detail=""):
    if not ok:
        raise SystemExit(f"FAIL {name}: {detail}")


def playwright():
    """(playwright module dir, a Chromium the cache has) or None."""
    mods = [os.environ.get("PLAYWRIGHT")] + glob.glob(os.path.expanduser("~/.npm/_npx/*/node_modules/playwright"))
    mod = next((m for m in mods if m and os.path.isdir(m)), None)
    exes = sorted(glob.glob(os.path.expanduser("~/Library/Caches/ms-playwright/chromium_headless_shell-*/chrome-headless-shell-*/chrome-headless-shell"))
                  + glob.glob(os.path.expanduser("~/.cache/ms-playwright/chromium_headless_shell-*/chrome-headless-shell-*/chrome-headless-shell")))
    return (mod, exes[-1]) if mod and exes and shutil.which("node") else None


def grid(surface, tick, rows):
    return {"surface": surface, "tick": tick, "cell": 8, "x0": 0, "y0": 0, "w": len(rows[0]), "h": len(rows), "rows": rows, "buildings": 4}


def net(surface, tick, items):
    return {"surface": surface, "tick": tick, "electric": {"poles": 2, "nets": "7,A,2", "cell": 4, "x0": 0, "y0": 0, "w": 4, "h": 1, "rows": ["AAAA"]},
            "logistic": [{"id": 3, "lr": 25, "cr": 55, "n": 1, "ports": "4,4"}], "items": [[i, "A,3,1,0,0,4,4", "Q,3,1,5,0,8,8"] for i in items]}


def main():
    found = playwright()
    if not found:
        print("map toolbar: skipped (no Playwright or no cached Chromium)")
        return
    t0 = 46_000_000
    cloud = {"surface": "gleba", "label": "Gleba spores", "pollutant": "spores", "color": {"r": 0.6, "g": 0.2, "b": 0.6, "a": 1}, "cells": [[0, 0, 12.5]], "max": 12.5}
    data = {"base": dict(grid("nauvis", t0, ["AA"]), cell=16), "nests": [[40, 40, "s"]], "turrets": [[1, 1, 18]],
            "agents": [{"name": "sol", "position": {"x": 1, "y": 1}, "alive": True, "attention": {"position": {"x": 5, "y": 5}, "text": "x"}}],
            "clouds": [cloud], "now_tick": t0 + 60, "pins": [{"position": {"x": 3, "y": 3}, "text": "a"}],
            "planets": {"gleba": grid("gleba", t0, ["AS"]), "aquilo": grid("aquilo", t0, ["SS"])},
            "net_maps": {"nauvis": net("nauvis", t0, ["iron-plate", "a-very-long-item-name-for-the-picker-to-cut"]), "gleba": net("gleba", t0, ["bioflux"])},
            "library_areas": [{"name": "x", "surface": "nauvis", "box": [0, 0, 4, 4]}]}
    css = open(os.path.join(SITE, "static", "style.css")).read()
    js_src = open(os.path.join(SITE, "static", "mapview.js")).read()
    with tempfile.TemporaryDirectory() as d:
        for w in (595, 364):
            open(os.path.join(d, f"p{w}.html"), "w").write(PAGE % (css, w, js_src))
        js, fx = os.path.join(d, "t.js"), os.path.join(d, "fx.json")
        open(js, "w").write(JS)
        json.dump(data, open(fx, "w"))
        r = subprocess.run(["node", js, found[0], found[1], os.path.join(d, "pWIDTH.html"), fx], capture_output=True, text=True, timeout=90)
    check("browser", r.returncode == 0, r.stderr[-2000:])
    o = json.loads(r.stdout)
    for width, w in (("wide", 595), ("narrow", 364)):
        pages = o[width]
        for planet, p in pages.items():
            check(f"{width} {planet}: no error", not p["title"].startswith("ERR"), p["title"])
            check(f"{width} {planet}: nothing wider than the toolbar", p["widest"] <= w + 1, p["widest"])
            check(f"{width} {planet}: the planet row above the groups", p["planets"][1] + p["planets"][3] <= min(b[1][1] for b in p["boxes"]), p)
        for planet, p in pages.items():
            check(f"{width} {planet}: the picker's label fits", p["pick"]["text"] <= p["pick"]["room"], p["pick"])
        check(f"{width}: the label", {p["pick"]["label"] for p in pages.values()} == {"Item: -"}, [p["pick"] for p in pages.values()])
        n = pages["nauvis"]
        # each control at the same place (only the pollution toggle's width differs: "Spores" on Gleba, the last in its group)
        place = lambda p: [(k, x, y) + (() if k == "cloud" else (w,)) for k, (x, y, w, h) in p["controls"]]  # noqa: E731
        check(f"{width}: the same places on every planet", all(place(pages[k]) == place(n) and pages[k]["boxes"] == n["boxes"] for k in pages),
              {k: v["controls"] for k, v in pages.items()})
        box = {b[0]: b[1] for b in n["boxes"]}
        label = {b[0]: b[2] for b in n["boxes"]}
        check(f"{width}: the groups", list(box) == ["Terrain", "Networks", "Combat", "Team"], list(box))
        item = dict(n["controls"])["item"]
        check(f"{width}: the picker narrow", item[2] <= 6.5 * 16 + 1, item)
        # (d22 batch75 AK7) each label at the left of its buttons, at every width
        mine = lambda g: [c[1] for c in n["controls"] if box[g][0] <= c[1][0] < box[g][0] + box[g][2] and box[g][1] <= c[1][1] < box[g][1] + box[g][3]]  # noqa: E731
        check(f"{width}: each label at the left of its buttons", all(label[g][0] + label[g][2] <= min(c[0] for c in mine(g)) for g in box), (label, box))
        check(f"{width}: each label on its buttons' first line", all(min(c[1] for c in mine(g)) <= label[g][1] + label[g][3] / 2 <= min(c[1] + c[3] for c in mine(g)) for g in box), label)
        check(f"{width}: the planet row close above", min(b[1][1] for b in n["boxes"]) - (n["planets"][1] + n["planets"][3]) <= 12, (n["planets"], n["boxes"]))
        if width == "wide":
            check("wide: Terrain and Networks one row", box["Terrain"][1] == box["Networks"][1] and box["Networks"][0] > box["Terrain"][0] + box["Terrain"][2], box)
            check("wide: Combat and Team the next", box["Combat"][1] == box["Team"][1] > box["Terrain"][1] and box["Team"][0] > box["Combat"][0] + box["Combat"][2], box)
            check("wide: two rows, tight", box["Combat"][1] - (box["Terrain"][1] + box["Terrain"][3]) <= 6, box)
        else:
            tops = [box[g][1] for g in ("Terrain", "Networks", "Combat", "Team")]
            check("narrow: one group a row", tops == sorted(tops) and len(set(tops)) == 4 and len({box[g][0] for g in box}) == 1, box)
            check("narrow: each label at its left", all(label[g][0] + label[g][2] <= dict(n["controls"])["item"][0] for g in box), label)
    print("map toolbar: ok (wide: Terrain + Networks, Combat + Team; narrow: a group a row; labels at the left of their buttons, "
          "gaps tight; the same places on every planet; the picker narrow; nothing wider than the toolbar)")


if __name__ == "__main__":
    main()
