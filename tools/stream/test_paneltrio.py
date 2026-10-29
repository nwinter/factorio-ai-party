#!/usr/bin/env python3
"""The trio with one client: the main view plus both camera panels at once (d28 batch324 SF2, viewer Aurora 17:00,
site:5416: "Please include main plus two simultaneous GUI insets in 324. Public code still gates trio on three clients.
Keep main free of GUI strips, test one-client framing and show it live."): python3 tools/stream/test_paneltrio.py

1. One client and two panels (the live slots, tools/cams.py): after trio_gap, two other agents doing notable things
   far apart go into the two panels (framed off air, as panels: player 1, panel 1 and 2) and the layout switches; the
   main client is not moved; program() names the tiles and the panel trio's holes; public() has the three tiles; the
   main view's frame keeps its own crop (view_frac); it ends after trio_hold, and an urgent cut ends it at once.
2. One client without panels: no trio. Three clients: as before (test_trio.py).
3. cuts.py with the program's holes: cam1 (2880x1620) stays in layout.json's main hole with its crop (492 px a side:
   the panels' strips out of the picture), the panel scenes in their two holes; back to one camera after.
"""
import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from onecam import OneCam  # noqa: E402
from test_onecam import agent, snap  # noqa: E402
import cuts  # noqa: E402
from test_cuts import FakeOBS, LAYOUT  # noqa: E402
from test_trio import until_trio, team  # noqa: E402

PANELS = [{"slot": "main", "player": 1},
          {"slot": "cam2", "player": 1, "panel": 1, "rect": [2388, 0, 492, 277], "scale": 0.171},
          {"slot": "cam3", "player": 1, "panel": 2, "rect": [0, 0, 492, 277], "scale": 0.171}]


def director(slots, **cfg):
    sent = []
    d = OneCam(slots, lambda body: sent.append(body) or {"ok": True}, None,
               **dict({"map_every": 0, "platform_every": 0, "bow": False, "view_frac": 0.658}, **cfg))
    return d, sent


def panel_trio():
    d, sent = director(PANELS)
    a = team()
    t = 1000
    d.started = t
    gap = int(d.cfg["trio_gap"])
    assert until_trio(d, a, t, t + gap - 1) is None, d.layouts
    on, subj = d.onair, d.state[d.onair]["subject"]
    n_main = len([b for b in sent if "panel" not in b])
    start = until_trio(d, a, t + gap - 1, t + gap + 60)
    assert start is not None and d.layouts[-1][2].startswith("busy: ") and d.trio.get("panels"), d.layouts
    subj = d.state[d.onair]["subject"]
    others = {"luna", "sol", "astra"} - {subj}
    tiles = [b for b in sent if b.get("panel") and b.get("follow") in others]  # (one may hold its agent already)
    assert tiles and all(b["player"] == 1 for b in tiles), tiles
    assert {d.state["cam2"]["subject"], d.state["cam3"]["subject"]} == others, (d.state["cam2"], d.state["cam3"])
    prog = d.program()
    assert prog["layout"] == "trio" and prog["tiles"] == {"main": "main", "cam2": "cam2", "cam3": "cam3"}, prog
    assert prog["holes"]["main"] == [24, 24, 1208, 1032] and prog["holes"]["cam2"] != prog["holes"]["cam3"], prog
    assert d.onair == on and not [c for c in d.cuts if c[0] >= start - 2], d.cuts  # no cut, the main client stays
    assert d.onair_frac() == 0.658  # the main view keeps its own crop
    pub = d.public(start)
    assert set(pub) == {"main", "cam2", "cam3"} and {pub["cam2"]["agents"][0], pub["cam3"]["agents"][0]} == others, pub
    for k in range(1, 95):
        d.step(snap(a), start + k)
        if d.mode != "trio":
            break
    assert d.mode == "onecam" and 89 <= k <= 91 and d.onair == on and "holes" not in d.program(), (k, d.layouts)
    # an urgent cut ends a panel trio at once: one camera, the one client moved
    d2, _ = director(PANELS, trio_gap=0)
    d2.started = t
    s = until_trio(d2, a, t, t + 200)
    assert s is not None
    al = {"id": "d1", "kind": "death", "text": "Sol died", "agent": "sol", "t": s + 1}
    d2.step(dict(snap(a), alerts=[al]), s + 1)
    assert d2.mode == "onecam", d2.layouts
    print(f"1. one client, two panels: the trio puts {sorted(others)} in the panels, main unmoved and cropped as before; "
          "ends after trio_hold, and at an urgent cut: ok")


def lively_only():
    """(cp3) Only over a lively story; out when it stands still; at most every panel_trio_gap."""
    d, _ = director(PANELS)
    d.started = 1000
    gap = int(d.cfg["trio_gap"])
    still = [dict(x, activity="idle", active=None) for x in team()]
    assert until_trio(d, still, 1000, 1000 + gap + 120) is None, d.layouts  # a still story: no trio
    d, _ = director(PANELS)
    d.started = 1000
    a = team()
    s = until_trio(d, a, 1000, 1000 + gap + 60)
    assert s is not None
    subj = d.state[d.onair]["subject"]
    calm = [dict(x, activity="idle", active=None) if x["name"] == subj else x for x in a]
    for k in range(1, 60):
        d.step(snap(calm), s + k)
        if d.mode != "trio":
            break
    assert d.mode == "onecam" and "still" in d.layouts[-1][2] and k <= d.cfg["still_cut"] + 2, (k, d.layouts[-1])
    nxt = until_trio(d, a, s + k + 1, s + k + 1700)
    assert nxt is None, nxt  # within panel_trio_gap (30 min): none
    assert until_trio(d, a, s + k + 1700, s + 1800 + 200) is not None
    print(f"1b. only over a lively story, out after {k} s once it stands still, the next after panel_trio_gap: ok")


def no_panels():
    d, _ = director(PANELS[:1], trio=True)
    d.started = 1000
    assert until_trio(d, team(), 1000, 1000 + int(d.cfg["trio_gap"]) + 60) is None
    d, _ = director(PANELS, panel_trio=False)
    d.started = 1000
    assert until_trio(d, team(), 1000, 1000 + int(d.cfg["trio_gap"]) + 60) is None
    print("2. one client without panels, or panel_trio off: no trio: ok")


def obs():
    o = FakeOBS()
    o.sizes[o.ids["stream cam1"]] = (2880, 1620)  # cam1's window; cam2 and cam3 are the 1920x1080 panel scenes
    c = cuts.Cuts(o, LAYOUT, log=lambda *a: None, start=False, vertical=None)
    c.set({"onair": "main", "inset": None, "layout": "onecam"})
    c.work()
    before = dict(o.tf("stream cam1"))
    holes = {"main": [24, 24, 1208, 1032], "cam2": [40, 40, 408, 230], "cam3": [808, 40, 408, 230]}
    c.set({"onair": "main", "inset": None, "layout": "trio", "tiles": {"main": "main", "cam2": "cam2", "cam3": "cam3"},
           "holes": holes})
    c.work()
    m, p2, p3 = o.tf("stream cam1"), o.tf("stream cam2"), o.tf("stream cam3")
    assert (m["positionX"], m["positionY"], m["boundsWidth"], m["boundsHeight"], m["cropLeft"], m["cropRight"]) == \
        (24, 24, 1208, 1032, 492, 492) and m["cropLeft"] == before["cropLeft"], m  # the panels' 492 px strips stay out
    assert (p2["positionX"], p2["positionY"], p2["boundsWidth"]) == (40, 40, 408) and (p3["positionX"], p3["boundsWidth"]) == (808, 408), (p2, p3)
    st = o.scenes["stream"]
    assert st[-1] == "stream overlay" and set(st[-3:-1]) == {"stream cam2", "stream cam3"} and st[-4] == "stream cam1", st  # panels on top
    c.set({"onair": "main", "inset": None, "layout": "onecam"})
    c.work()
    assert all(o.tf(n)["boundsWidth"] == 1208 for n in ("stream cam1", "stream cam2", "stream cam3"))
    print("3. cuts.py: cam1 keeps its main hole and crop (492 px a side), the panels in their holes; back after: ok")


def main():
    panel_trio()
    lively_only()
    no_panels()
    obs()
    print("paneltrio: ok")


if __name__ == "__main__":
    main()
