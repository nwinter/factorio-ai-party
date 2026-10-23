#!/usr/bin/env python3
"""Platform shots framed by gun range, detail pans in flight (d20 batch50, Nick 07:30): python3 tools/stream/test_platformpan.py

A1. With the view's guns read (harness.py platform_views: each turret's position and its range from the prototypes with
    quality, read once per kind and cached), a platform in flight is framed as the ship and the box its turrets reach,
    never more than the ship plus its longest range all round; a ship without turrets is its bounds plus a 2-tile margin.
    A view without a guns read frames as before (32 tiles ahead).
A2. In flight with turrets, the shot is a closer detail view (model.DETAIL_ZOOM) that rests on the bow (the top of the
    guns' reach) and pans slowly to the stern (`pan` with speed and bow_s); docked ships keep a still shot. OneCam moves
    it in small steps with a glide speed (cameras.lua `speed`), no cut, the label kept. (d23 batch124 CG2) Each leg
    eased; each step glides to where the pan will be 1.5 step intervals on, so the view never stops between steps.
"""
import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from test_onecam import world  # noqa: E402
from test_platformcam import plat, snap, team, main_row  # noqa: E402
import model  # noqa: E402
from model import platform_shot, gun_reach  # noqa: E402

# Swiftlet as world n read it on 2026-10-20 07:50: bounds and its 10 gun turrets (range 18, normal quality)
GUNS = [(-18, -24), (-10, -6), (-8, -30), (0, -30), (2, -18), (5, -7), (8, -17), (8, -12), (20, -24), (1, 6)]
SWIFTLET = {"surface": "platform-6", "hub": {"x": 0, "y": 0},
            "bounds": {"left": -18.5, "top": -32.5, "right": 20.5, "bottom": 17.5}, "hub_health": 100,
            "guns": [{"x": x, "y": y, "range": 18} for x, y in GUNS]}


def frame(shot, frac):
    """(left, top, right, bottom) a shot shows: ~60 x 34 tiles at zoom 1, the width cut to frac."""
    w, h = 60.0 * frac / shot["zoom"], 34.0 / shot["zoom"]
    x, y = shot["position"]["x"], shot["position"]["y"]
    return x - w / 2, y - h / 2, x + w / 2, y + h / 2


def cap():
    frac = 0.658
    whole = platform_shot(SWIFTLET, travelling=True, frac=frac)
    reach = gun_reach(SWIFTLET)
    assert reach == (-36, -48, 38, 24), reach
    # the whole-ship zoom fits the reach (ship and guns) with the 2-tile margin, no more
    w, h = max(38, 20.5) - min(-36, -18.5) + 4, max(24, 17.5) - min(-48, -32.5) + 4
    assert whole["fit_zoom"] == round(min(60 * frac / w, 34 / h), 2) == 0.45, whole
    old = platform_shot({k: v for k, v in SWIFTLET.items() if k != "guns"}, travelling=True, frac=frac)
    assert old["zoom"] == 0.34 and "fit_zoom" not in old, old  # 07:16:26 "main: zoom 0.34 <- platform departure: Swiftlet"
    # never more than the ship plus its longest range all round: the fit zoom shows at most that box's larger side
    longest = 18
    bw, bh = 39 + 2 * longest + 4, 50 + 2 * longest + 4
    assert whole["fit_zoom"] >= round(min(60 * frac / bw, 34 / bh), 2)
    # a rocket turret (range 36) on the bow reaches further ahead: the box grows with it
    far = dict(SWIFTLET, guns=SWIFTLET["guns"] + [{"x": 0, "y": -30, "range": 36}])
    assert gun_reach(far)[1] == -66 and platform_shot(far, travelling=True, frac=frac)["fit_zoom"] < whole["fit_zoom"]
    # no turrets: the bounds plus the margin, in flight too (no 32 tiles ahead)
    bare = dict(SWIFTLET, guns=[])
    fly, dock = platform_shot(bare, travelling=True, frac=frac), platform_shot(bare, frac=frac)
    assert fly["zoom"] == round(min(60 * frac / 43, 34 / 54), 2) and "pan" not in fly and fly["position"] == {"x": 1.0, "y": -7.5}, fly
    assert dock["zoom"] == round(min(60 * frac / 49, 34 / 60), 2), dock  # docked: as before (bounds and the 10-tile margin)


def detail():
    frac = 0.658
    fly = platform_shot(SWIFTLET, travelling=True, frac=frac)
    p = fly["pan"]
    assert p.get("detail") and fly["zoom"] == model.DETAIL_ZOOM[0] and fly["zoom"] > fly["fit_zoom"], fly
    left, top, right, bottom = frame(dict(fly, position={"x": fly["position"]["x"], "y": p["y0"]}), frac)
    assert abs(top - (-48 - 2)) < 0.2, top  # at the bow the view's top edge is the guns' reach ahead (and half the margin)
    assert fly["position"]["y"] == p["y0"], fly  # a camera without the pan shows the bow
    _, _, _, bottom = frame(dict(fly, position={"x": 0, "y": p["y1"]}), frac)
    assert abs(bottom - (17.5 + 2)) < 0.2, bottom  # at the stern its bottom edge is the hull's
    assert p["speed"] == round(34 / fly["zoom"] / model.DETAIL_CROSS_S, 2) and p["bow_s"] == model.DETAIL_BOW_S
    # 1080p: the on-air hole is 1032 px high for 34/zoom tiles, a gun turret (2 tiles) at least 30 px, a small asteroid
    # (about 1 tile) at least 15
    px = 1032 / (34 / fly["zoom"])
    assert 2 * px >= 30 and px >= 15, px
    assert "pan" not in platform_shot(SWIFTLET, frac=frac)  # docked: a still shot
    # a small ship whose whole frame is about as close as a detail view keeps the whole frame
    tiny = {"surface": "platform-9", "hub": {"x": 0, "y": 0}, "bounds": {"left": -4, "top": -4, "right": 4, "bottom": 4},
            "guns": [{"x": 0, "y": -3, "range": 8}]}
    assert "pan" not in platform_shot(tiny, travelling=True, frac=frac)


def pan_y(d):
    t0 = {"pan": {"y0": -20.0, "y1": 20.0, "speed": 4.0, "bow_s": 8.0}, "since": 0.0, "until": 60.0}
    assert d.pan_y(t0, 7.9) == -20.0 and d.pan_y(t0, 13.0) == 0.0 and d.pan_y(t0, 18.0) == 20.0
    assert d.pan_y(t0, 18.0 + d.PAN_END_S) == 20.0 and d.pan_y(t0, 18.0 + d.PAN_END_S + 5) == 0.0
    assert d.pan_y(t0, 28.0 + d.PAN_END_S + 0.5) == -20.0  # back on the bow, then the cycle again
    # a short visit: the bow and part of the hull, at the same pace (CG2: eased, 40% of the leg is 35% of the way)
    short = dict(t0, until=12.0)
    assert d.pan_y(short, 12.0) == -5.9
    # (CG2) eased legs: slow off the bow, fastest mid-ship, slow onto the stern
    ys = [d.pan_y(t0, 8.0 + k) for k in range(11)]
    moves = [b - a for a, b in zip(ys, ys[1:])]
    assert moves[0] < moves[4] and moves[-1] < moves[5] and max(moves) <= 1.5 * 4.0 + 0.1, moves


def onair():
    d, sent = world(map_every=0)
    a, t = team(), 1000
    rows = [plat("Swiftlet", at="nauvis->vulcanus 20%", view=SWIFTLET, toward="vulcanus")]
    d.cfg["platform_hold"] = 40
    for k in range(0, 60):
        d.step(snap(a, rows), t + k)
        if (d.state.get(d.onair) or {}).get("platform"):
            break
    assert d.platforms, "no platform shot"
    target = next(v for v in d.state.values() if v and (v.get("pan") or {}).get("detail"))
    on = d.onair
    first = len(sent)
    bodies = []
    for k2 in range(k + 1, k + 36):
        d.step(snap(a, rows), t + k2)
        assert d.onair == on, "a cut during the pan"
    bodies = [b for b in sent if b.get("surface") == "platform-6"]
    ys = [b["position"]["y"] for b in bodies]
    p = target["pan"]
    assert ys[0] == p["y0"] and p["y1"] in ys, ys  # framed on the bow, on to the stern
    assert all(b["zoom"] == target["zoom"] for b in bodies), bodies  # the detail zoom all along
    moving = [b for b in sent[first:] if b.get("surface") == "platform-6" and b["position"]["y"] != p["y0"]]
    assert moving and all(b.get("smooth") and b.get("speed") for b in moving), moving
    # (CG2) each step glides to a point 1.5 step intervals (1 s here) on, at the speed that takes that long: the next
    # step comes while it still moves (the 1.15x glide stopped about 0.1-0.5 s each step on world n)
    glides = [(abs(b2["position"]["y"] - y1), b2["speed"]) for y1, b2 in zip(ys, bodies[1:]) if b2["position"]["y"] != y1]
    assert glides and all(abs(g / 1.5 - v) <= 0.02 or v == 0.5 for g, v in glides), glides
    steps = [y2 - y1 for y1, y2 in zip(ys, ys[1:]) if y2 != y1]
    assert steps and all(0 < abs(s) <= 1.5 * p["speed"] * 1.5 + 0.11 for s in steps), steps  # at most 1.5 s at the eased peak
    row = main_row(d, t + k2)
    assert row["platform"]["name"] == "Swiftlet" and "Swiftlet" in row["platform"]["label"], row  # the label kept


def harness():
    import harness as hmod
    calls = []

    class H(hmod.Harness):
        def __init__(self):
            pass

        def lua(self, lua):
            calls.append(lua)
            if "prototypes.entity" in lua:
                return {"ranges": [{"n": "gun-turret", "q": "normal", "range": 18},
                                   {"n": "rocket-turret", "q": "legendary", "range": 54}]}
            return {"platforms": [{"name": "Swiftlet", "surface": "platform-6", "hub": {"x": 0, "y": 0},
                                   "bounds": SWIFTLET["bounds"], "turrets": [
                                       {"n": "gun-turret", "q": "normal", "x": 1, "y": 6},
                                       {"n": "rocket-turret", "q": "legendary", "x": 0, "y": -30}]},
                                  {"name": "Chalk", "surface": "platform-10", "hub": {"x": 0, "y": 0},
                                   "bounds": SWIFTLET["bounds"], "turrets": []}]}

    h = H()
    v = h.platform_views()
    assert v["Swiftlet"]["guns"] == [{"x": 1, "y": 6, "range": 18}, {"x": 0, "y": -30, "range": 54}], v
    assert v["Chalk"]["guns"] == [] and "turrets" not in v["Swiftlet"], v
    assert sum("prototypes.entity" in c for c in calls) == 1
    h.platform_views()
    assert sum("prototypes.entity" in c for c in calls) == 1, "ranges read again"  # cached per (name, quality)

    class Broken(H):
        def turret_ranges(self, keys):
            raise RuntimeError("rcon")
    v = Broken().platform_views()
    assert "guns" not in v["Swiftlet"] and "turrets" not in v["Swiftlet"], v  # no read: framed as before
    for c in (hmod.PLATFORM_LUA, hmod.TURRET_RANGE_LUA):
        assert "--" not in c


def main():
    cap()
    detail()
    d, _ = world(map_every=0)
    pan_y(d)
    onair()
    harness()
    print("platform pan: ok (framed by gun range; in flight a detail view pans bow to stern at an even pace)")


if __name__ == "__main__":
    main()
