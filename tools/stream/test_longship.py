#!/usr/bin/env python3
"""A long ship framed bow to stern: python3 tools/stream/test_longship.py

d22 batch99 BI4 (viewer Foobator site:4332: "the camera up and down on ships does not show enough north and south for
large ships like asterion"). Before, Asterion in flight (60 x 275 tiles of hull, guns reaching 37 ahead) was a 0.55
detail view 62 tiles high panning 254 tiles at 4.1 tiles/s: 70 s bow to stern, so a 20 s visit showed the bow and a
quarter of the hull. Checks: a detail pan longer than model.LONG_VIEWS view heights gives way to the whole-frame shot
at the zoom that fits (at least 0.3: 200 x 113 tiles), its pan from the guns' reach ahead to the reach aft; a shorter
ship (Kestrel II, 136 long) keeps its detail pan; a visit holds until the pan has gone bow to stern at one view height
in PAN_VIEW_S; on air the camera reaches the stern within the shot, gliding between its steps.
"""
import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from test_onecam import world  # noqa: E402
from test_platformcam import plat, snap, team  # noqa: E402
from test_platformpan import frame  # noqa: E402
import model  # noqa: E402
from model import platform_shot, gun_reach  # noqa: E402

# Asterion as the stream read it on 2026-10-22 16:50 (bounds; its bow, side and stern guns among its 97)
ASTERION = {"surface": "platform-16", "hub": {"x": 0, "y": 0},
            "bounds": {"left": -53.5, "top": -45.5, "right": 6, "bottom": 229.5}, "hub_health": 100,
            "guns": [{"x": -48.5, "y": -42.5, "range": 40}, {"x": -33.5, "y": -42.5, "range": 40},
                     {"x": -48.5, "y": 20.5, "range": 40}, {"x": 0, "y": 100, "range": 36},
                     {"x": -42.5, "y": 226.5, "range": 36}, {"x": 0.5, "y": 0.5, "range": 18}]}
KESTREL = {"surface": "platform-3", "hub": {"x": 0, "y": 0},
           "bounds": {"left": -29, "top": -30, "right": 29, "bottom": 106}, "hub_health": 100,
           "guns": [{"x": 0, "y": -28, "range": 18}, {"x": -20, "y": 50, "range": 18}, {"x": 20, "y": 100, "range": 18}]}


def framing():
    reach = gun_reach(ASTERION)
    fly = platform_shot(ASTERION, travelling=True)
    p = fly["pan"]
    assert not p.get("speed") and not p.get("detail") and fly["zoom"] == 0.3, fly
    left, top, right, bottom = frame(dict(fly, position={"x": fly["position"]["x"], "y": p["y0"]}), 1.0)
    assert abs(top - (reach[1] - 2)) < 0.2, (top, reach)  # at the bow: the guns' reach ahead
    assert left <= reach[0] and right >= reach[2], (left, right, reach)  # the guns' reach across, whole
    _, _, _, bottom = frame(dict(fly, position={"x": 0, "y": p["y1"]}), 1.0)
    assert abs(bottom - (reach[3] + 2)) < 0.2, (bottom, reach)  # at the stern: the reach aft
    vh = 34 / fly["zoom"]
    assert round(vh) == 113 and abs(p["y1"] - p["y0"]) / vh > 2, (vh, p)
    # the detail pan it replaced: at 0.55, 62 tiles high, more than LONG_VIEWS of them from bow to stern
    detail_vh = 34 / model.DETAIL_ZOOM[0]
    assert (ASTERION["bounds"]["bottom"] + 2) - (reach[1] - 2) - detail_vh > model.LONG_VIEWS * detail_vh
    # a shorter ship keeps the detail pan (d20 batch50 A2)
    k = platform_shot(KESTREL, travelling=True)
    assert k["pan"].get("detail") and k["zoom"] >= model.DETAIL_ZOOM[0], k
    # docked: as before, the whole frame at the least zoom with a pan over the shot
    dock = platform_shot(ASTERION)
    assert dock["zoom"] == 0.3 and "speed" not in dock["pan"], dock


def holds(d):
    fly = dict(platform_shot(ASTERION, travelling=True), since=0.0, until=20.0)
    need = d.pan_hold(fly)
    vh = 34 / fly["zoom"]
    assert abs(need - (2 * d.PAN_END_S + abs(fly["pan"]["y1"] - fly["pan"]["y0"]) * d.PAN_VIEW_S / vh)) < 0.01, need
    assert 20 < need <= d.PAN_HOLD_MAX, need
    assert d.pan_hold(dict(platform_shot(KESTREL, travelling=True), since=0, until=20)) == 0.0, "a detail pan: its own pace"
    fly["until"] = need
    assert d.pan_y(fly, need - d.PAN_END_S) == fly["pan"]["y1"], "the stern within the shot"
    assert abs(d.pan_speed(fly) * (need - 2 * d.PAN_END_S) - abs(fly["pan"]["y1"] - fly["pan"]["y0"])) < 0.5


def onair():
    d, sent = world(map_every=0)
    a, t = team(), 1000
    rows = [plat("Asterion", at="aquilo->solar-system-edge 7%", view=ASTERION, toward="solar-system-edge")]
    d.cfg["platform_hold"] = 20
    for k in range(0, 80):
        d.step(snap(a, rows), t + k)
        if (d.state.get(d.onair) or {}).get("platform"):
            break
    assert d.platforms, "no platform shot"
    shot = d.state[d.onair]
    p = shot["pan"]
    assert shot["zoom"] == 0.3 and not p.get("speed"), shot
    assert shot["until"] - (t + k) > 20, (shot["until"], t + k)  # held past platform_hold for the length
    end, on = int(shot["until"]), d.onair
    for k2 in range(k + 1, end - t):
        d.step(snap(a, rows), t + k2)
        if d.onair != on:
            break
    bodies = [b for b in sent if b.get("surface") == "platform-16"]
    ys = [b["position"]["y"] for b in bodies]
    assert ys[0] == p["y0"] and p["y1"] in ys, (ys[:3], ys[-3:], p)  # bow to stern on air
    moving = [b for b in bodies if b["position"]["y"] != p["y0"]]
    assert moving and all(b.get("speed") and b.get("smooth") for b in moving), moving[:2]  # gliding between steps


def main():
    framing()
    d, _ = world(map_every=0)
    holds(d)
    onair()
    print("long ship: ok (past LONG_VIEWS the whole frame at 0.3 pans bow to stern; a visit held for its length; "
          "gliding)")


if __name__ == "__main__":
    main()
