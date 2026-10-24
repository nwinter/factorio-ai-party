#!/usr/bin/env python3
"""The tour's camera and voice timing in the service (d23 batch128 CK1: lookcam.py, onecam.py, serve.py AudioHub).
Offline: python3 tools/stream/test_tourcam.py

1. POST /look cut_at: a standby frames the spot at once, the program cuts at that moment (next_wake wakes the
   director for it), the shot on air keeps its label until then; one client moves only then; look.aired says when.
2. POST /look {platform}: a whole ship as the director frames it, no chart read; an unknown ship is 409.
3. POST /look/extend: the look's end moves, no chart read; another id is refused; cut_at out of range is 400.
4. (CK2) A look with a move: its spot is the move's first point; every point's frame is chart-checked (a refusal names
   the point); a standby frames the first point without the move, the cut sends it (cameras.lua plays it); a game
   whose camera reply has no move gets the director's steps (glides every MOVE_STEP s); a tall ship's "pan" is a move
   bow to stern, a short ship's none.
5. AudioHub: a clip with `at` is kept until its moment; /audio/status lists the queue; the page's start report sets
   `started` (started_at); /audio/cancel takes a clip back (a control event for the page) and off the queue.
"""
import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from test_onecam import world  # noqa: E402
from test_platformcam import plat, snap, team, main_row  # noqa: E402
from test_look import Chart  # noqa: E402
from onecam import OneCam  # noqa: E402
from lookcam import LookControl  # noqa: E402
from serve import AudioHub  # noqa: E402


def cut_at():
    d, sent = world(map_every=0, platform_every=0)
    a = team()
    for t in range(1000, 1004):
        d.step(snap(a), t)
    lc = LookControl(d, None, Chart())
    code, r = lc.request({"surface": "nauvis", "x": -180, "y": 40, "zoom": 0.5, "seconds": 30, "label": "Wall",
                          "by": "tour", "cut_at": 1010.0, "id": "wall"}, 1004)
    assert code == 200 and r["cut_at"] == 1010.0 and r["until"] == 1040.0 and r["id"] == "wall", r
    d.step(snap(a), 1004)
    assert sent[-1]["position"] == {"x": -180.0, "y": 40.0} and sent[-1]["smooth"] is False, "framed on a standby now"
    for t in range(1005, 1010):
        d.step(snap(a), t)
        assert main_row(d, t)["agents"] == ["luna"] and not main_row(d, t).get("look"), t
    assert d.look_info(1009)["id"] == "wall" and "aired" not in d.look_info(1009)
    assert abs(d.next_wake(1009.5) - 0.5) < 1e-9 and abs(d.next_wake(1009.996) - 0.005) < 1e-9
    d.step(snap(a), 1010.02)
    row = main_row(d, 1010.02)
    assert row["look"]["label"] == "Wall" and row["look"]["id"] == "wall", row
    assert d.look_info(1011)["aired"] == 1010.02 and d.next_wake(1011) is None
    # the next stop at the same spot: its label waits for its cut
    n = len(sent)
    lc.request({"surface": "nauvis", "x": -180, "y": 40, "zoom": 0.5, "seconds": 30, "label": "Wall, again",
                "by": "tour", "cut_at": 1020.0, "id": "wall2"}, 1016)
    for t in range(1016, 1020):
        d.step(snap(a), t)
        assert main_row(d, t)["look"]["label"] == "Wall", t
    d.step(snap(a), 1020)
    assert main_row(d, 1020)["look"]["label"] == "Wall, again" and d.look_info(1020)["aired"] == 1020
    assert len(sent) == n, "the same spot: no camera command"
    # one client: nothing moves before the cut, then it moves on air
    sent1 = []
    d1 = OneCam([{"slot": "main", "player": 3}], lambda b: sent1.append(b) or {"ok": True}, None)
    d1.step(snap(a), 1000)
    LookControl(d1, None, Chart()).request({"surface": "vulcanus", "x": 120, "y": -40, "cut_at": 1005.0, "id": "v"},
                                           1001)
    n = len(sent1)
    for t in range(1001, 1005):
        d1.step(snap(a), t)
    assert not any(b.get("surface") == "vulcanus" for b in sent1[n:]) and not main_row(d1, 1004).get("look")
    d1.step(snap(a), 1005)
    assert sent1[-1]["surface"] == "vulcanus" and main_row(d1, 1005)["look"]["id"] == "v"
    assert d1.look_info(1006)["aired"] == 1005
    # cut_at: epoch seconds, now to 30 s ahead
    assert lc.request({"surface": "nauvis", "x": 0, "y": 0, "cut_at": 1100}, 1030)[0] == 400
    assert lc.request({"surface": "nauvis", "x": 0, "y": 0, "cut_at": 900}, 1030)[0] == 400


def ship_look():
    d, sent = world(map_every=0, platform_every=0)
    a, ships = team(), [plat("Starling")]
    for t in range(1000, 1004):
        d.step(snap(a, ships), t)
    ch = Chart()
    lc = LookControl(d, None, ch)
    code, r = lc.request({"platform": "starling", "seconds": 20, "label": "Starling", "by": "tour", "cut_at": 1006,
                          "id": "s"}, 1004)
    assert code == 200 and r["surface"] == "platform-1" and r["platform"] == "Starling" and not ch.reads, (r, ch.reads)
    assert 0.3 <= r["zoom"] <= 3 and r["visible"] is True
    for t in range(1004, 1008):
        d.step(snap(a, ships), t)
    row = main_row(d, 1007)
    assert row["look"]["id"] == "s" and row["frame"]["surface"] == "platform-1", row
    assert row.get("ship"), "the ship card goes with it"
    code, r = lc.request({"platform": "Nowhere", "by": "tour"}, 1008)
    assert code == 409 and "no camera view for a platform named 'Nowhere'" in r["error"] and r["platforms"] == ["Starling"]
    # a spot on its deck (platform with x, y): chart-checked as a spot on the ship's surface
    code, r = lc.request({"platform": "Starling", "x": 5, "y": -3, "zoom": 1.2}, 1008)
    assert code == 200 and r["surface"] == "platform-1" and r["position"] == {"x": 5.0, "y": -3.0} and ch.reads


def extend():
    d, _ = world(map_every=0, platform_every=0)
    ch = Chart()
    lc = LookControl(d, None, ch)
    assert lc.extend({"seconds": 30}, 1000)[0] == 409
    lc.request({"surface": "nauvis", "x": 0, "y": 0, "seconds": 20, "id": "x", "cut_at": 1002}, 1000)
    reads = len(ch.reads)
    code, r = lc.extend({"seconds": 50, "id": "x"}, 1010)
    assert code == 200 and r["until"] == 1060 and d.look_hold["until"] == 1060 and len(ch.reads) == reads
    assert lc.extend({"seconds": 500}, 1011)[1]["until"] == 1071, "at most 60 s"
    assert lc.extend({"seconds": 10, "id": "y"}, 1012)[0] == 409


def audio_queue():
    hub = AudioHub()
    a = hub.push({"channel": "agent", "speaker": "Sol", "duration": 6.0, "expires_in": 20}, b"x", "audio/mpeg")
    n = hub.push({"channel": "narrator", "speaker": "Narrator", "duration": 30.0, "at": a["t"] + 60, "expires_in": 30},
                 b"y", "audio/mpeg")
    assert n["expires"] >= n["at"] + 5, "a timed clip lives to its moment"
    q = hub.status()["queued"]
    assert [c["id"] for c in q] == [a["id"], n["id"]] and q[0]["duration"] == 6.0 and q[1]["at"] == n["at"], q
    hub.played({"id": a["id"], "state": "start", "duration": 6.0, "started_at": a["t"] + 0.5}, now=a["t"] + 0.6)
    st = hub.status()
    assert [c["id"] for c in st["queued"]] == [n["id"]] and st["playing"][0]["started"] == round(a["t"] + 0.5, 3)
    seq = hub.seq
    assert hub.cancel(n["id"]) and not hub.cancel(n["id"]) and not hub.cancel("nope")
    _, new = hub.wait(seq, 0)
    assert len(new) == 1 and new[0]["cancel"] == n["id"] and new[0]["channel"] == "control"
    assert hub.status()["queued"] == [], "cancelled clips and control events are not queued"


MOVE = {"segments": [{"pts": [{"x": 0, "y": 0, "zoom": 0.5}, {"x": 60, "y": 0, "zoom": 0.8}], "t0": 1, "t1": 9}]}


def moves():
    sent = []
    reply = {"camera": {"move": {"start_tick": 1, "end_tick": 2}}}
    d, _ = world(map_every=0, platform_every=0)
    d.sender = lambda b: sent.append(b) or {"ok": True, "result": dict(reply, ok=True)}
    a = team()
    for t in range(1000, 1003):
        d.step(snap(a), t)
    ch = Chart()
    lc = LookControl(d, None, ch)
    code, r = lc.request({"surface": "nauvis", "x": 999, "y": 999, "zoom": 2, "move": MOVE, "cut_at": 1006,
                          "id": "m"}, 1003)
    assert code == 200 and r["position"] == {"x": 0.0, "y": 0.0} and r["zoom"] == 0.5 and r["move"]["segments"], r
    assert len(ch.reads) == 2 and ch.reads[1][1:3] == (60.0, 0.0), "each point's frame is read"
    d.step(snap(a), 1003)
    assert sent[-1]["position"] == {"x": 0.0, "y": 0.0} and "move" not in sent[-1], "the standby frames the start"
    for t in range(1004, 1006):
        d.step(snap(a), t)
    n = len(sent)
    d.step(snap(a), 1006)
    assert len(sent) == n + 1 and sent[-1]["move"] == r["move"] and sent[-1]["smooth"] is False, sent[n:]
    assert d.look_info(1006)["move"] == r["move"] and d.look_info(1006)["aired"] == 1006
    for t in range(1007, 1012):
        d.step(snap(a), t)
    assert len(sent) == n + 1 and d.next_wake(1012) is None, "the game plays it: no more commands"
    # an uncharted point
    blind = Chart(charted={("nauvis", cx, cy) for cx in range(-3, 3) for cy in range(-3, 3)})
    code, r2 = LookControl(d, None, blind).request({"surface": "nauvis", "x": 0, "y": 0, "move": {"segments": [
        {"pts": [{"x": 0, "y": 0, "zoom": 1}, {"x": 900, "y": 0, "zoom": 1}], "t0": 0, "t1": 5}]}}, 1012)
    assert code == 409 and r2["error"].startswith("move point 2: "), r2
    assert lc.request({"surface": "nauvis", "x": 0, "y": 0, "move": {"segments": []}}, 1012)[0] == 400
    # an older cameras.lua (no camera.move in its reply): the director steps the move itself
    sent1 = []
    d1 = OneCam([{"slot": "main", "player": 3}], lambda b: sent1.append(b) or {"ok": True}, None)
    d1.step(snap(a), 1000)
    LookControl(d1, None, Chart()).request({"surface": "nauvis", "x": 0, "y": 0, "move": MOVE, "cut_at": 1001}, 1000)
    d1.step(snap(a), 1001)
    assert sent1[-1].get("move") and d1.next_wake(1001.1) == d1.MOVE_STEP
    xs = []
    for k in range(1, 20):
        t = 1001 + k * 0.5
        d1.step(snap(a), t)
        xs.append(sent1[-1]["position"]["x"])
        assert "move" not in sent1[-1] and sent1[-1].get("speed"), sent1[-1]
    assert xs == sorted(xs) and 0 < xs[2] < 5 and abs(xs[-1] - 60) < 1e-6, xs
    # a tall ship pans bow to stern; a short one is still
    tall = dict(plat("Long", view={"surface": "platform-9", "hub": {"x": 0, "y": 0},
                                   "bounds": {"left": -14, "top": -150, "right": 14, "bottom": 150}}))
    d2, _ = world(map_every=0, platform_every=0)
    for t in range(1000, 1003):
        d2.step(snap(a, [tall, plat("Starling")]), t)
    lc2 = LookControl(d2, None, Chart())
    code, r = lc2.request({"platform": "Long", "move": "pan", "move_s": 40, "seconds": 50}, 1003)
    seg = r["move"]["segments"][0]
    assert code == 200 and seg["pts"][0]["y"] < seg["pts"][1]["y"] and seg["t0"] == 3.0 and seg["t1"] == 37.0, r
    assert r["position"]["y"] == seg["pts"][0]["y"], "the look starts at the bow"
    code, r = lc2.request({"platform": "Starling", "move": "pan", "move_s": 40}, 1003)
    assert code == 200 and "move" not in r


if __name__ == "__main__":
    for f in (cut_at, ship_look, extend, moves, audio_queue):
        f()
        print("ok", f.__name__)
    print("test_tourcam: all ok")
