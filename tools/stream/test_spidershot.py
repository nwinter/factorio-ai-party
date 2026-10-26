#!/usr/bin/env python3
"""A remote vehicle's shot (d26 batch245 SP, viewer Aurora 14:53: "In shift82, Opus's spider shot panned without
catching it before a cut ... frame the vehicle promptly, then track smoothly and start dwell once it is visible ...
Shorten an unchanged stuck scene unless recovery or combat is active, and return when progress resumes"):
python3 tools/stream/test_spidershot.py

shift82 14:59:54: "back to opus" cut to a client whose last frame was 230 tiles behind the spider (left there at
14:59:32 when a platform visit took the program) and panned on air; at 15:00:00 a quiet view took it ("opus still
1779 s": Opus's clocks count the character, idle while it drives). 14:41:56-14:56:04: the spider stood stuck while
Opus kept calling it; 14:41:57-14:42:01 the view ran 30 tiles ahead on a read with speed, then snapped back.

1. A standby on a vehicle follows it off air and is framed anew when far off, before the cut: the cut frames it.
2. Dwell counts only while the vehicle is in the frame.
3. A read with speed and no progress (stuck legs): no lead, no walking.
4. A stop inside the frame's inner box keeps the frame still; the lead stays inside that box.
5. Stuck vehicle_stuck s (not fighting): its shot has served its dwell, scores like standing, a quiet view may come
   sooner, a call to it is no news; with a fight near it, none of that; moving on again is news.
6. The clocks' idle seconds count from when its vehicle last walked, not from the character.
"""
import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from test_onecam import agent, SLOTS  # noqa: E402
from onecam import OneCam, dist  # noqa: E402

T0 = 1793051994.0  # shift82 14:59:54
UNIT = 27069154


def director(cams=3):
    d = OneCam(SLOTS[:cams], lambda body: {"ok": True}, None, trio=False, map_every=0, platform_every=0, bow=False)
    d.started = d.onair_since = T0 - 300
    return d


def opus(x, y, t, speed=47.0, target=None, seen_t=None, idle=None):
    a = agent("opus", -160, -542, 5, activity="thinking", active=False)
    a["remote_vehicle"] = {"vehicle": "spidertron", "unit_number": UNIT, "position": {"x": x, "y": y}, "speed": speed,
                           "target": target, "t": t, "seen_t": t if seen_t is None else seen_t, "live": True}
    a["idle_s"] = idle
    return a


def framed_before_cut():
    d = director()
    luna = agent("luna", 300, 0, 2, activity="thinking", active=False)
    # the spider walks west 13 tiles a second; a segment holds the program 20 s, then the story is Opus again
    pos = lambda t: (7.0 - 13.0 * (t - (T0 - 22)), -887.0)  # noqa: E731
    seg = {"id": 1, "label": "platform visit", "zoom": 0.5, "until": T0 - 1, "position": {"x": 0, "y": 0},
           "surface": "platform-9"}
    cut_at = None
    for t in range(int(T0 - 60), int(T0 + 10)):
        x, y = pos(max(t, T0 - 22)) if t >= T0 - 22 else (7.0, -887.0)
        a = opus(x, y, t, target={"x": -228, "y": -748})
        d.step({"agents": [a, luna], "alerts": []}, t, seg if T0 - 22 <= t < T0 - 1 else None)
        cur = d.state.get(d.onair) or {}
        if t >= T0 - 1 and cut_at is None and cur.get("vehicle"):
            cut_at = t
            off = dist(cur["position"], {"x": x, "y": y})
            assert off <= min(d.frame_half(cur.get("game_zoom") or cur["zoom"])), (t - T0, off, cur["position"], x)
    assert cut_at is not None and cut_at - T0 <= 4, (cut_at, d.cuts[-3:])
    print(f"1. back from a segment: the standby followed the spider and framed it before the cut (+{cut_at - T0:.0f} s): ok")


def dwell_in_frame():
    d = director()
    t = T0
    a = opus(-200, -760, t, speed=0)
    for k in range(5):
        d.step({"agents": [a], "alerts": []}, t + k)
    assert (d.state.get(d.onair) or {}).get("vehicle")
    since = d.onair_since
    far = opus(-200, -560, t + 5, speed=0)  # a read 200 tiles off the frame
    d.step({"agents": [far], "alerts": []}, t + 5)
    d.step({"agents": [far], "alerts": []}, t + 6)
    assert d.onair_since > since, (d.onair_since - since)
    print("2. dwell held while the vehicle is out of the frame: ok")


def stuck_legs():
    d = director()
    t = T0
    for k, x in enumerate((73.2, 73.2, 73.3)):  # three reads 3 s apart, speed 47, no progress (shift82 14:41:56)
        a = opus(x, -620.7, t + 3 * k, target={"x": 73, "y": -500})
        d.track([a], t + 3 * k)
    a = opus(73.3, -620.7, t + 6, target={"x": 73, "y": -500})
    spot = d.vehicle_spot(a, t + 8, held=True, ahead=1.0)
    assert abs(spot["y"] + 620.7) < 0.5, spot
    assert d.vehicle_activity(a, t + 8) is None
    print("3. a read with speed and no progress: no lead, not walking: ok")


def stops():
    d = director()
    t = T0
    for k in range(4):
        d.step({"agents": [opus(100 - 13 * k, -620, t + k, target={"x": 40, "y": -620})]}, t + k)
    cur = d.state[d.onair]
    hw, hh = d.frame_half(cur.get("game_zoom") or cur["zoom"])
    assert dist(cur["position"], {"x": 61, "y": -620}) <= d.cfg["vehicle_still_box"] * min(hw, hh) + 0.5, cur["position"]
    aim = dict(cur["position"])
    for k in range(4, 10):  # stopped short of its target, inside the inner box
        d.step({"agents": [opus(55, -620, t + k, speed=0, target=None)]}, t + k)
    assert d.state[d.onair]["position"] == aim, (aim, d.state[d.onair]["position"])
    print("4. the lead stays inside the inner box; a stop inside it keeps the frame still: ok")


def stuck_scene():
    d = director()
    luna = agent("luna", 300, 0, 2, activity="thinking", active=False)
    t = T0
    for k in range(75):  # Opus calls it every 16 s; it stands at (151, -554) (shift82 14:46:11-14:56:04)
        a = opus(151, -553.9, t + k, speed=0, seen_t=t + 16 * (k // 16), target={"x": 0, "y": -480}, idle=900)
        d.step({"agents": [a, luna], "alerts": []}, t + k)
    assert d.vehicle_stuck_s("opus", t + 74) >= 45, d.vehicle_anchor
    s = d.scores([a, luna], t + 74)["opus"]
    since = d.vehicle_anchor["opus"][2]
    d.vehicle_anchor["opus"][2] = t + 74  # (the same read, not stuck)
    s2 = d.scores([a, luna], t + 74)["opus"]
    d.vehicle_anchor["opus"][2] = since
    assert abs(s - s2 * d.cfg["still_factor"] / d.cfg["move_boost"]) < 0.02, (s, s2)
    assert not d.newsworthy("opus", t + 74)
    cur = d.state.get(d.onair) or {}
    assert cur.get("subject") != "opus" or not cur.get("vehicle") or t + 74 - d.onair_since >= d.cfg["onair_dwell"], d.cuts
    # a fight at it: not stuck
    d.fight_list = [{"key": "area:151,-554", "kind": "attack", "text": "Base under attack near (151, -554): spidertron",
                     "last": t + 74, "position": {"x": 151, "y": -554, "surface": "nauvis"}}]
    assert d.vehicle_stuck_s("opus", t + 74) == 0
    d.fight_list = []
    # on its way again: news
    for k in range(75, 79):
        a = opus(151 - 13 * (k - 74), -553.9, t + k, target={"x": 0, "y": -480})
        d.step({"agents": [a, luna], "alerts": []}, t + k)
    assert "on its way again" in d.fresh["opus"][1], d.fresh.get("opus")
    print("5. a stuck spider: dwell served, scored as standing, no news from calls; a fight keeps it; moving on is news: ok")


def clocks_floor():
    d = director()
    t = T0
    for k in range(10):  # walking until +9
        d.track([opus(-190 - 13 * k, -777, t + k, target={"x": -320, "y": -777}, idle=1770 + k)], t + k)
    for k in range(10, 16):  # arrived and stands; its clocks say the character has been idle 1779 s and more
        d.track([opus(-320, -777, t + k, speed=0, idle=1770 + k)], t + k)
    assert d.still_s("opus", t + 15) <= 8, d.still_s("opus", t + 15)
    print("6. idle clocks count from the vehicle's last walk: ok")


def main():
    framed_before_cut()
    dwell_in_frame()
    stuck_legs()
    stops()
    stuck_scene()
    clocks_floor()
    print("spidershot: ok")


if __name__ == "__main__":
    main()
