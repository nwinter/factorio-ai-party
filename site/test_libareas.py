#!/usr/bin/env python3
"""Placed library blueprints on every planet's live map (d21 batch68 AD2, viewer Aurora: "could installed blueprint areas
show tested revision, required hookups and last check, with failed or unverified hookups on every planet's map?"):
python3 site/test_libareas.py

push_live.public_library_areas: the stream's library_areas read shaped for the site (known keys only), newest first, the
oldest left out past LIBRARY_AREAS_BYTES. static/mapview.js under node: prepare() keeps the areas of the surface shown,
areaMark() says each one's state (bad: an open hookup or a failed check; unverified: no passing check or hookups not
read; ok) and its facts in words (who placed it and when, the save placed against the entry's save now, its retire
mark, its check, its hookups and the open ones).
"""
import json, os, shutil, subprocess, sys, tempfile

SITE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SITE)
import push_live  # noqa: E402

JS = r"""
const fx = JSON.parse(require('fs').readFileSync(process.argv[3], 'utf8'));
global.window = global;
require(process.argv[2]);
const M = global.PogMap;
const id = (v) => v;
const out = {};
const areas = fx.areas;
out.marks = areas.map((a) => { const m = M.areaMark(a, fx.now, id, id); return { state: m.state, text: m.text, box: [m.x0, m.y0, m.x1, m.y1] }; });
out.aquilo = M.prepare({ surface: 'aquilo', planets: {}, library_areas: areas, now_tick: fx.now }).areas.map((a) => a.name);
out.nauvis = M.prepare({ library_areas: areas, now_tick: fx.now }).areas.map((a) => a.name);
process.stdout.write(JSON.stringify(out));
"""


def check(name, ok, detail=""):
    if not ok:
        raise SystemExit(f"FAIL {name}: {detail}")


def area(name, surface, tick, **kw):
    a = {"name": name, "surface": surface, "box": [0, 0, 10, 10], "tick": tick, "by": "astra", "entities": 9}
    a.update(kw)
    return a


def main():
    now = 1_000_000
    hk_open = {"b": [0, 1, 1, 1], "p": [0, 1], "i": [0, 1, 0, 0], "e": [1, 1, 1, 0], "g": 1,
               "open": [[9.5, 7.5, "belt out: ends at the edge"], [0.5, 2.5, "belt in: no belt outside feeds it"]], "t": now - 600, "junk": 1}
    hk_ok = {"b": [1, 0, 1, 0], "p": [2, 0], "i": [0, 0, 0, 0], "e": [2, 2, 0, 0], "g": 0, "open": [], "t": now - 120}
    raw = {"tick": now, "age_s": 30, "placements": 3, "areas": [
        area("aq-cell", "aquilo", now - 216000, hookups=hk_open, saved_tick=now - 108000, placed_save=now - 300000,
             retired={"by": "sol", "reason": "leaks heat", "replaced_by": "aq-cell2", "tick": now - 60, "x": 1},
             check={"id": 3, "name": "aq check", "state": "fail", "tick": now - 54000}, description="Aquilo heat cell"),
        area("smelt-row", "nauvis", now - 7200, hookups=hk_ok, saved_tick=now - 9000, placed_save=now - 9000,
             check={"id": 4, "name": "row", "state": "pass", "tick": now - 300}),
        area("old", None, now - 9999, deleted=True),
        {"name": "broken", "box": [1, 2]}]}
    pub = push_live.public_library_areas(raw)
    check("rows", [a["name"] for a in pub["areas"]] == ["aq-cell", "smelt-row", "old"], pub)
    check("known keys only", "junk" not in pub["areas"][0]["hookups"] and "x" not in pub["areas"][0]["retired"], pub["areas"][0])
    check("top keys", pub["tick"] == now and pub["placements"] == 3 and pub["left_out"] == 1, pub)
    check("none", push_live.public_library_areas(None) is None and push_live.public_library_areas({"areas": "x"}) is None)
    big = {"areas": [area(f"bp-{i:03d}", "nauvis", now - i, description="d" * 80, hookups=hk_open) for i in range(200)]}
    pb = push_live.public_library_areas(big)
    check("byte cap", len(json.dumps(pb["areas"], separators=(",", ":"))) <= push_live.LIBRARY_AREAS_BYTES and pb["areas"][0]["name"] == "bp-000"
          and pb["left_out"] == 200 - len(pb["areas"]), (len(pb["areas"]), pb.get("left_out")))
    # in the public state, beside the rest
    st = push_live.public_state({"library_areas": raw})
    check("public state", [a["name"] for a in st["library_areas"]["areas"]] == ["aq-cell", "smelt-row", "old"], st.get("library_areas"))

    if not shutil.which("node"):
        print("library areas: push_live ok; mapview skipped (no node)")
        return
    with tempfile.TemporaryDirectory() as d:
        fx = os.path.join(d, "fx.json")
        json.dump({"areas": pub["areas"], "now": now}, open(fx, "w"))
        js = os.path.join(d, "t.js")
        open(js, "w").write(JS)
        r = subprocess.run(["node", js, os.path.join(SITE, "static", "mapview.js"), fx], capture_output=True, text=True, timeout=30)
        check("node", r.returncode == 0, r.stderr)
        o = json.loads(r.stdout)
    m0, m1, m2 = o["marks"]
    check("bad", m0["state"] == "bad", m0)
    for part in ("Blueprint aq-cell", "placed by astra 60 min ago", "the entry was saved again since (30 min ago)",
                 "retired by sol: leaks heat; replaced by aq-cell2", 'check "aq check": fail, last run 15 min ago',
                 "hookups: belts in 0 joined, 1 open, belts out 1 joined, 1 open, pipes 0 joined, 1 open, inserters in 0 joined, 1 open, power: 1 pole, 1 wired out, 1 machine with no power, 1 still a ghost",
                 "open: belt out: ends at the edge at (9.5, 7.5); belt in: no belt outside feeds it at (0.5, 2.5) (read 10 s ago)", "Aquilo heat cell"):
        check("bad text: " + part, part in m0["text"], m0["text"])
    check("ok", m1["state"] == "ok" and "the entry as saved then" in m1["text"] and "power: 2 poles, 2 wired out" in m1["text"], m1)
    check("unverified", m2["state"] == "unverified" and "no library entry of that name now" in m2["text"] and "hookups not read yet" in m2["text"]
          and "no check of it" in m2["text"], m2)
    check("box", m0["box"] == [0, 0, 10, 10], m0)
    check("the surface shown", o["aquilo"] == ["aq-cell"] and o["nauvis"] == ["smelt-row", "old"], o)
    print("library areas: ok (placed library areas per surface with the save placed, retire mark, check and hookups)")


if __name__ == "__main__":
    main()
