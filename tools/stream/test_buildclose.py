#!/usr/bin/env python3
"""Build shots on large ships: the whole ship, then the changed machines (d28 batch312 A, viewer Aurora 10:47: "Could
repair/build shots on large ships use a brief overview followed by a close-up of the actual changed machines or feeders?
... a first platform visit can use the whole-ship view despite an exact work position. Please use the position/extent,
keep orientation with a short caption, and check that the change is readable at 1080p."): python3 tools/stream/test_buildclose.py

On main a build's spot was used only when the platform had aired within work_repeat: a first visit framed the whole
ship however exactly the work named its place.
1. work_close: the close-up fits the request's box (its entries or area) with work_close_margin, from work_close_min
   (a box too big for it: "part of it") to work_spot_zoom (a position alone); the caption names who, what the request
   names and where on the ship (thirds of the hull, bow north).
2. A first visit: the whole ship, its caption saying where the work is, then after work_overview_s on air the camera glides to the
   work (its centre and zoom sent), the caption naming it; the shot's time is unchanged.
3. A shot replaced within work_overview_s gets no close-up; a repeat goes to the close-up at once.
4. work.py: a request's box and what it names (place_ghosts entries, a deconstruct area, a position); model.py's work
   item carries them.
"""
import json, os, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from test_onecam import agent, world  # noqa: E402
from test_platformcam import VIEW, plat, snap, main_row  # noqa: E402
from test_buildcam import item  # noqa: E402
import work as W  # noqa: E402

T = 1000
# a long ship: 60 tiles across, 200 from bow (top) to stern
BIG = {"surface": "platform-1", "hub": {"x": 0, "y": 0}, "bounds": {"left": -30, "top": -100, "right": 30, "bottom": 100},
       "hub_health": 100}
GHOSTS = [{"name": "assembling-machine-2", "position": {"x": 20.5 + 4 * k, "y": 70.5}} for k in range(3)] + \
         [{"name": "inserter", "position": {"x": 20.5 + 4 * k, "y": 73.5}} for k in range(2)]


def build(agent_name, at, view=BIG, entities=GHOSTS):
    args = {"platform": "Starling", "entities": entities}
    plat_, pos = W.target_of(args)
    return item(agent_name, at, "place_ghosts", position=pos, view=view, extent=W.extent_of(args), what=W.what_of(args))


def close():
    d, _ = world(map_every=0, platform_every=0)
    w = build("sol", T)
    c = d.work_close(w, BIG, "Sol", "Starling")
    assert c["position"] == {"x": 24.5, "y": 72.0}, c
    # box 9 x 4 tiles + 10: 60/19 and 34/14 both over work_spot_zoom: that zoom
    assert c["zoom"] == d.cfg["work_spot_zoom"], c
    assert c["caption"] == "Sol placing 5 ghosts (3 assembling machine 2, 2 inserter) on Starling · near the stern, starboard side", c
    # a box across most of the hull: work_close_min, part of it
    wide = [{"name": "solar-panel", "position": {"x": x, "y": y}} for x in (-25, 25) for y in (-80, 80)]
    c = d.work_close(build("sol", T, entities=wide), BIG, "Sol", "Starling")
    assert c["zoom"] == d.cfg["work_close_min"] and c["caption"].endswith("midships, on the centre line (part of it)"), c
    # a box between: fitted to its height (1 x 31 tiles + 10: 60/11 across, 34/41 = 0.83 up and down)
    mid = [{"name": "pipe", "position": {"x": -20.0, "y": y}} for y in (-90, -60)]
    c = d.work_close(build("sol", T, entities=mid), BIG, "Sol", "Starling")
    assert c["zoom"] == round(34.0 / 41.0, 2) and "near the bow, port side" in c["caption"], c
    # a position alone (a paste): work_spot_zoom there, the verb as the work says it
    c = d.work_close(dict(item("sol", T, position={"x": -5.0, "y": 0.0}), verb="pasting a blueprint", action="paste"), BIG, "Sol", "Starling")
    assert c == {"position": {"x": -5.0, "y": 0.0}, "zoom": d.cfg["work_spot_zoom"],
                 "caption": "Sol pasting a blueprint on Starling · midships, on the centre line",
                 "overview": "Sol pasting a blueprint on Starling · whole ship, the work midships, on the centre line"}, c
    print("1. the close-up fits the request's box (0.6 to 0.9), a position alone at 0.9; the caption: who, what, where on the ship: ok")


def first_visit():
    d, sent = world(map_every=0, platform_every=0)
    a = [agent("astra", 0, 0, 5), agent("sol", 300, 0, 1)]
    for k in range(0, 22):
        d.step(snap(a, [plat(view=BIG)]), T + k)
    w = build("sol", T + 22)
    rows, on = [], None
    for k in range(22, 80):
        d.step(snap(a, [plat(view=BIG)], work=[w]), T + k)
        r = main_row(d, T + k)
        if (r.get("platform") or {}).get("why") == "work":
            on = on if on is not None else k
            rows.append((k, r.get("work"), r.get("zoom"), (d.state[d.onair].get("position") or {}).copy()))
    assert on is not None, d.cuts[-3:]
    k0, cap0, z0, p0 = rows[0]
    assert cap0 == "Sol placing 5 ghosts (3 assembling machine 2, 2 inserter) on Starling · whole ship, the work near the stern, starboard side", rows[0]
    assert z0 < d.cfg["work_close_min"] and abs(p0["x"]) < 1, rows[0]  # the whole ship (200 tiles tall: under 0.3-0.6)
    moved = next(r for r in rows if r[1] != cap0)
    assert moved[0] - k0 in (d.cfg["work_overview_s"], d.cfg["work_overview_s"] + 1), (moved, rows[:3])
    assert moved[2] == d.cfg["work_spot_zoom"] and moved[3] == {"x": 24.5, "y": 72.0}, moved
    assert moved[1] == "Sol placing 5 ghosts (3 assembling machine 2, 2 inserter) on Starling · near the stern, starboard side", moved
    cmd = [b for b in sent if b.get("position") == {"x": 24.5, "y": 72.0}]
    assert cmd and cmd[0]["zoom"] == d.cfg["work_spot_zoom"] and cmd[0]["smooth"] is True and cmd[0]["speed"] >= 2, cmd[:1]  # glides there
    # once: no further close-up commands; the shot ends when it would have
    assert len(cmd) == 1, len(cmd)
    end = rows[-1][0]
    assert end - k0 <= d.cfg["work_fresh"] + d.cfg["work_hold"] + d.cfg["ready_s"] + 2, (k0, end)  # held while its request is fresh, as before
    print(f"2. a first visit: the whole ship (zoom {z0}) {moved[0] - k0} s, then the work at {moved[2]}, captioned; "
          f"{end - k0 + 1} s in all: ok")


def replaced_and_repeat():
    d, sent = world(map_every=0, platform_every=0)
    a = [agent("astra", 0, 0, 5), agent("sol", 300, 0, 1)]
    for k in range(0, 22):
        d.step(snap(a, [plat(view=BIG)]), T + k)
    w = build("sol", T + 22)
    k = 22
    while (main_row(d, T + k).get("platform") or {}).get("why") != "work":
        d.step(snap(a, [plat(view=BIG)], work=[w]), T + k)
        k += 1
    t = d.state[d.onair]
    assert t.get("closeup") and not t["closeup"].get("done")
    d.state[d.onair] = {"subject": "astra", "agents": ["astra"], "follow": "astra", "zoom": 1.0, "until": T + k + 60}
    n = len(sent)
    d.closeup_step(T + k + 10)
    assert len(sent) == n, sent[n:]
    # a repeat (the platform's work aired within work_repeat): the close-up at once
    d, _ = world(map_every=0, platform_every=0)
    for k in range(0, 22):
        d.step(snap(a, [plat(view=BIG)]), T + k)
    d.plat_work_shown["Starling"] = T - 100
    w = build("sol", T + 22)
    for k in range(22, 60):
        d.step(snap(a, [plat(view=BIG)], work=[w]), T + k)
        r = main_row(d, T + k)
        if (r.get("platform") or {}).get("why") == "work":
            break
    assert r.get("zoom") == d.cfg["work_spot_zoom"] and r["work"].endswith("starboard side") and not d.state[d.onair].get("closeup"), r
    print("3. a shot replaced in its overview: no close-up; a repeat: the close-up at once: ok")


def rows():
    assert W.extent_of({"entities": GHOSTS}) == {"left": 20.0, "top": 70.0, "right": 29.0, "bottom": 74.0}
    assert W.what_of({"entities": GHOSTS}) == [["assembling-machine-2", 3], ["inserter", 2]]
    area = {"left_top": {"x": -4, "y": 10}, "right_bottom": {"x": 6, "y": 18}}
    assert W.extent_of({"area": area}) == {"left": -4.0, "top": 10.0, "right": 6.0, "bottom": 18.0}
    assert W.extent_of({"position": {"x": 3, "y": 4}}) == {"left": 2.5, "top": 3.5, "right": 3.5, "bottom": 4.5}
    assert W.extent_of({}) is None and W.what_of({"area": area}) is None
    # the journal -> WorkFeed -> model.py's item
    from model import Model
    with tempfile.TemporaryDirectory() as d:
        os.makedirs(os.path.join(d, "sol"))
        j = os.path.join(d, "sol", "journal.jsonl")
        open(j, "w").write("")
        feed = W.WorkFeed(d, ["sol"])
        feed.poll()
        with open(j, "a") as f:
            f.write(json.dumps({"event": "request", "at": "2026-10-28T11:00:00", "request": {"id": 1, "action": "place_ghosts",
                                "args": {"platform": "Starling", "entities": GHOSTS}}}) + "\n")
        got = feed.poll()
        assert len(got) == 1 and got[0]["extent"] == W.extent_of({"entities": GHOSTS}) and got[0]["what"][0] == ["assembling-machine-2", 3], got
        m = Model({"agents": {"sol": {}}})
        m.platform_view = lambda name: BIG
        m._ingest_work(dict(got[0], agent="sol"), T)
        it = m.work[-1]
        assert it["extent"] == got[0]["extent"] and it["what"] == got[0]["what"] and it["verb"] == "building", it
    print("4. work rows: the request's box (entries, area, position) and what it names, through to the service's item: ok")


if __name__ == "__main__":
    close()
    first_visit()
    replaced_and_repeat()
    rows()
    print("buildclose: ok")
