#!/usr/bin/env python3
"""The trio: one big tile and two small ones, sometimes (onecam.py; operator task 2026-10-12, Nick liked the old
layout because each tile said who was doing what): python3 tools/stream/test_trio.py

1. Never in the first trio_gap (480 s) of one camera; then, when two other agents do notable things far apart from
   the story on air and each other, the two standbys are framed on them off air and the layout switches once both
   are there. The client on air stays on air (no cut); program() names the layout and which client is in which hole;
   public() has the big tile and the two small ones, each with its frame (for replays.py).
2. It lasts trio_hold (90 s), then one camera again (same client on air), and at least trio_gap before the next one.
3. Agents close together are no trio (the tiles would show one spot); a check-in after trio_every takes quieter ones.
4. No layout change while a replay is on air (hold_layout); an urgent alert ends a trio at once and cuts.
5. cuts.py moves the captures into layout-3cam.json's holes over the websocket, and back; the vertical scene keeps
   one camera (the big tile's client in front).
6. snapshot["onair"]["layout"] for the hosts and the page; the caster's facts say three tiles.
"""
import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from test_onecam import agent, snap, world  # noqa: E402
import cuts  # noqa: E402
from test_cuts import FakeOBS, LAYOUT  # noqa: E402

TRIO_HOLES = {"main": [24, 24, 1208, 680], "cam2": [24, 720, 596, 336], "cam3": [636, 720, 596, 336]}


def team(spread=200):
    return [agent("luna", 0, 0, 5), agent("sol", spread, 0, 4), agent("astra", -spread, 0, 4)]


def until_trio(d, agents, t0, t1, hold=False):
    for t in range(t0, t1):
        d.hold_layout = hold
        d.step(snap(agents), t)
        if d.mode == "trio":
            return t
    return None


def busy():
    d, sent = world(trio=True)
    a = team()
    t = 1000
    d.started = t  # one camera from here
    gap = int(d.cfg["trio_gap"])
    assert until_trio(d, a, t, t + gap - 1) is None, d.layouts  # rule 1: not inside trio_gap
    on = d.onair
    subj = d.state[on]["subject"]
    others = {"luna", "sol", "astra"} - {subj}
    start = until_trio(d, a, t + gap - 1, t + gap + 20)
    assert start is not None and d.layouts[-1][2].startswith("busy: "), d.layouts
    assert d.onair == on and not [c for c in d.cuts if c[0] >= t + 299], d.cuts  # the same client on air: no cut
    framed = [b for b in sent[-6:] if b.get("follow") in others]
    assert {b["follow"] for b in framed} == others and all(b["smooth"] is False for b in framed), sent[-6:]  # jumps
    prog = d.program()
    assert prog["layout"] == "trio" and prog["tiles"]["main"] == on and set(prog["tiles"]) == {"main", "cam2", "cam3"}
    assert len(set(prog["tiles"].values())) == 3, prog
    pub = d.public(start)
    assert set(pub) == {"main", "cam2", "cam3"} and pub["main"]["agents"] == [subj], pub
    assert {pub["cam2"]["agents"][0], pub["cam3"]["agents"][0]} == others and pub["cam2"]["frame"], pub
    assert d.layout_info()["mode"] == "trio" and set(d.layout_info()["agents"]) == others
    # rule 2: 90 s, then one camera again, same client on air
    for k in range(1, 95):
        d.step(snap(a), start + k)
        if d.mode != "trio":
            break
    assert d.mode == "onecam" and 89 <= k <= 91 and d.onair == on, (k, d.layouts)
    assert not [c for c in d.cuts if start <= c[0] <= start + k], d.cuts  # back to one camera: no cut either
    assert set(d.public(start + k)) <= {"main", "inset"} and d.program()["layout"] == "onecam"
    assert until_trio(d, a, start + k + 1, start + k + gap - 10) is None  # trio_gap again
    return d


def close_together():
    d, _ = world(trio=True)
    d.started = 0
    a = team(spread=15)
    assert until_trio(d, a, 1000, 1700) is None, d.layouts  # 15 tiles apart: no busy trio, no check-in yet
    # a check-in after trio_every (900 s) needs them only trio_near (20 tiles) apart
    a = team(spread=25)
    for x in a[1:]:
        x["interest"] = 0.2  # quiet: not a busy trio
    d2, _ = world(trio=True, trio_ratio=5.0)  # no agent beats that: only a check-in can start one
    d2.started = 0
    t = until_trio(d2, a, 1000, 1000 + 1000)
    assert t is not None and d2.layouts[-1][2].startswith("check-in"), (t, d2.layouts)


def holds_and_urgent():
    d, _ = world(trio=True)
    d.started = 0
    a = team()
    assert until_trio(d, a, 1000, 1100, hold=True) is None and d.trio_pending is None  # a replay on air: no switch
    t = until_trio(d, a, 1100, 1120)  # started = 0: the gap is long over
    assert t is not None
    death = {"id": "d1", "kind": "death", "t": t + 5, "text": "Sol died", "agent": "sol"}
    a[1]["alive"] = False
    d.step(snap(a, [death]), t + 5)
    assert d.mode == "onecam" and d.layouts[-1][2].startswith("death"), d.layouts
    d.step(snap(a), t + 7)
    assert d.public(t + 7)["main"].get("alert") == "death", d.public(t + 7)  # cut to it within ready_s


def obs_moves():
    o = FakeOBS(vertical=True)
    c = cuts.Cuts(o, LAYOUT, log=lambda *a: None, start=False, trio=TRIO_HOLES)
    c.set({"onair": "cam2", "inset": None, "layout": "onecam"})
    c.work()
    c.set({"onair": "cam2", "inset": None, "layout": "trio", "tiles": {"main": "cam2", "cam2": "main", "cam3": "cam3"}})
    c.work()
    big, s1, s2 = o.tf("stream cam2"), o.tf("stream cam1"), o.tf("stream cam3")
    assert (big["positionX"], big["positionY"], big["boundsWidth"], big["boundsHeight"]) == (24, 24, 1208, 680), big
    assert big["cropLeft"] == 0  # 16:9: no crop in the big tile
    assert (s1["positionX"], s1["positionY"], s1["boundsWidth"]) == (24, 720, 596) and s2["positionX"] == 636, (s1, s2)
    assert "CreateScene" not in o.calls and "CreateSceneItem" not in o.calls  # transforms only: no rebuild
    assert o.scenes["V"][-2] == "stream cam2"  # vertical: one camera, the big tile's client in front
    assert o.tf("stream cam1", "V")["boundsWidth"] == 1032  # its captures stay in the portrait hole
    assert c.status["layout"] == "trio"
    c.set({"onair": "cam2", "inset": None, "layout": "onecam"})
    c.work()
    assert all(o.tf(n)["boundsWidth"] == 1208 and o.tf(n)["boundsHeight"] == 1032
               for n in ("stream cam1", "stream cam2", "stream cam3"))
    assert o.scenes["stream"][-2] == "stream cam2"


def hosts():
    import caster
    s = {"agents": [{"name": "luna", "display_name": "Luna", "activity": "acting"}],
         "onair": {"agent": "luna", "display_name": "Luna", "doing": "",
                   "layout": {"mode": "trio", "agents": ["sol", "astra"]}}}
    f = caster.facts_for({"kind": "lull", "angle": "explain"}, s)
    assert f["on_screen"]["layout"] == "three tiles" and f["on_screen"]["small_tiles"] == ["sol", "astra"], f
    s["onair"]["layout"] = {"mode": "onecam"}
    assert "on_screen" not in caster.facts_for({"kind": "lull", "angle": "explain"}, s)


def see_through():
    """The overlay sits above the captures in OBS: a camera frame with a fill hides its camera (main 78c94e3: the
    inset's black background made a blank PIP). The inset and the trio's tiles stay transparent (?preview aside)."""
    import re
    css = open(os.path.join(HERE, "static", "overlay.css")).read()
    css = re.sub(r"/\*.*?\*/", "", css, flags=re.S)
    for sel, body in re.findall(r"([^{}]+)\{([^{}]*)\}", css):
        for s in sel.split(","):
            s = s.strip()
            frame = re.search(r"#cam-(inset|cam2|cam3|main)$|^\.cam$|body\.trio #cam-cam[23]$", s)
            if frame and "preview" not in s:
                assert "background" not in body, (s, body)


def hint_bars():
    """The cam clients keep a stale "Press Tab to skip cutscene" at the bottom centre (2026-10-12, spectators already):
    every view on the program has a full-width bottom bar at least the main bar's share of its height (44/1032)."""
    import json
    css = open(os.path.join(HERE, "static", "overlay.css")).read()
    js = open(os.path.join(HERE, "static", "overlay.js")).read()
    assert 'for (const id of ["cam-main", "cam-cam2", "cam-cam3", "cam-inset"])' in js and '"cam-bar"' in js
    trio = json.load(open(os.path.join(HERE, "static", "layout-3cam.json")))["cams"]
    inset = json.load(open(os.path.join(HERE, "static", "layout.json")))["cams"]["inset"]
    share = 44 / 1032
    assert "body.onecam #cam-cam2 .cam-bar, body.onecam #cam-cam3 .cam-bar, body.onecam #cam-inset .cam-bar" in css
    assert "left: 0; right: 0; bottom: 0; height: 32px;" in css and "body.onecam #cam-inset .cam-bar { height: 26px; }" in css
    assert 32 / trio["cam2"][3] >= share and 32 / trio["cam3"][3] >= share and 26 / inset[3] >= share


def main():
    see_through()
    hint_bars()
    busy()
    close_together()
    holds_and_urgent()
    obs_moves()
    hosts()
    print("trio: ok (busy or check-in, after 480 s of one camera, 90 s, framed off air, no cut; none while a replay is "
          "on air; urgent ends it; OBS transforms only; vertical stays one camera; hosts told)")


if __name__ == "__main__":
    main()
