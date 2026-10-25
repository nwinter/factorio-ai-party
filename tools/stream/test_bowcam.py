#!/usr/bin/env python3
"""A ship's bow on a long flight, a few seconds each round (d24 batch170 QM1, viewer Caleb, site 14:51-14:52: "show a
view of the front of Asterion when it is in flight for a few seconds"): python3 tools/stream/test_bowcam.py

1. harness PLATFORM_HULL_LUA: one line, no comments; Harness.platform_hulls asks for at most two platforms a call
   (names as Lua long strings), keeps each answer HULL_EVERY s, leaves out a platform without foundation.
2. live.py add_hulls: only a platform on a leg to or from the solar system edge or the shattered planet gets `hull`
   and `bow` in its view (Asterion "solar-system-edge->aquilo 1%"); a leg between planets or a docked ship does not.
3. onecam bow_turn, three clients: at a story turn (the rotation) the bow goes on air instead, a fixed view labelled
   "Asterion · the bow · travelling to Aquilo (1%) · 120 km/s", the bow's width fitted across and its north edge
   bow_ahead down the frame, for ready_s + bow_hold; then the story goes to the agent the turn was for ("after the
   bow: sol"). Not again before the round is over (every agent on air lately had a story since) and bow_gap; not in
   the first bow_first; not for a docked ship or one without a bow read.
4. It never takes the camera from a segment or a replay; a danger shot takes the bow over.
5. One camera (POG_CAMS=1): the one client moves to the bow and back.
6. (d24 batch188 QAD1, viewer Caleb 19:15: "when showing Asterion's bow can you zoom out enough to see the asteroids in
   range?") With the guns read: the space ahead covers the turrets' reach ahead of the bow plus 4 tiles, and the frame
   its width (reach 36 and 40 ahead: zoom 0.34 and 0.30); a reach past what 0.3 shows keeps 0.3; a reach shorter than
   the bow's own frame keeps the bow's zoom.
"""
import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, ".."))
import cams  # noqa: E402
import harness  # noqa: E402
from live import LiveSource  # noqa: E402
from onecam import OneCam  # noqa: E402
from test_onecam import agent, world  # noqa: E402
from test_platformcam import VIEW, plat, snap, main_row  # noqa: E402

BOW = {"left": -51, "top": -50, "right": 51, "bottom": -26}
HULL = {"left": -51, "top": -50, "right": 71, "bottom": 230}  # Asterion on the d24 shift70 copy (PLATFORM_HULL_LUA)
BOW_VIEW = dict(VIEW, surface="platform-16", bounds={"left": -49.5, "top": -46, "right": 6, "bottom": 229.5},
                hull=HULL, bow=BOW)
FAST = dict(map_every=0, platform_every=0, onair_dwell=20, onair_max=30, rotate_ratio=0.1)


def ship(at="solar-system-edge->aquilo 1%", view=BOW_VIEW, **kw):
    return plat("Asterion", at=at, view=view, toward="aquilo", **kw)


def team():
    return [agent("luna", 0, 0, 5), agent("sol", 300, 0, 5), agent("astra", -300, 0, 5)]


def hull_read():
    assert "--" not in harness.PLATFORM_HULL_LUA and "NAMES" in harness.PLATFORM_HULL_LUA
    h = harness.Harness.__new__(harness.Harness)
    calls = []

    def lua(src):
        calls.append(src)
        names = [n for n in ("Asterion", "Kestrel II", "Bare") if f"[ [[{n}]] ] = true" in src]
        return {"hulls": [{"name": n, "surface": "platform-16", "hull": HULL, "bow": BOW} for n in names if n != "Bare"]}
    h.lua = lua
    got = h.platform_hulls(["Asterion", "Kestrel II", "Bare"], now=1000)
    assert len(calls) == 1 and set(got) == {"Asterion"}, (got, calls)  # Asterion and Bare (sorted; Bare: no foundation)
    assert "ROWS" not in calls[0] and f"top + {h.BOW_ROWS}" in calls[0], calls[0][-400:]
    got = h.platform_hulls(["Asterion", "Kestrel II", "Bare"], now=1001)  # the third one now; the first two kept
    assert len(calls) == 2 and set(got) == {"Asterion", "Kestrel II"}, (got, len(calls))
    h.platform_hulls(["Asterion"], now=1000 + h.HULL_EVERY - 1)
    assert len(calls) == 2
    h.platform_hulls(["Asterion"], now=1000 + h.HULL_EVERY)
    assert len(calls) == 3 and "[ [[Asterion]] ] = true" in calls[-1]


def live_hulls():
    class H:
        asked = None

        def platform_hulls(self, names):
            H.asked = sorted(names)
            return {n: {"surface": "platform-16" if n == "Asterion" else "platform-9", "hull": HULL, "bow": BOW}
                    for n in names}
    src = LiveSource.__new__(LiveSource)
    src.h = H()
    views = {"Asterion": {"surface": "platform-16", "where": {"at": "solar-system-edge->aquilo 1%"}},
             "Probe": {"surface": "platform-20", "where": {"at": "solar-system-edge->shattered-planet 40%"}},
             "Anvil": {"surface": "platform-7", "where": {"at": "nauvis->fulgora 20%"}},
             "Docked": {"surface": "platform-8", "where": {"at": "solar-system-edge"}}}
    errors = {}
    src.add_hulls(views, errors)
    assert H.asked == ["Asterion", "Probe"] and not errors, (H.asked, errors)
    assert views["Asterion"]["bow"] == BOW and views["Asterion"]["hull"] == HULL
    assert "bow" not in views["Probe"]  # the read named another surface: not this ship's
    assert "bow" not in views["Anvil"] and "bow" not in views["Docked"]


def run(d, a, rows, t0, secs, seg=None, hold=None):
    """Step d for secs seconds; -> [(t, main row)] for each step."""
    out = []
    for k in range(secs):
        now = t0 + k
        if hold:
            d.hold_layout = hold(now)
        d.step(snap(a, rows(now) if callable(rows) else rows), now, seg(now) if seg else None)
        out.append((now, main_row(d, now)))
    return out


def bows(rows):
    """The (start, end) of each stretch the bow was on air."""
    spans, start = [], None
    for now, r in rows:
        on = (r.get("platform") or {}).get("why") == "bow"
        if on and start is None:
            start = now
        if not on and start is not None:
            spans.append((start, now))
            start = None
    return spans


def three_clients():
    d, sent = world(**FAST)
    a, t = team(), 1000
    rows = run(d, a, [ship()], t, 900)
    spans = bows(rows)
    assert len(spans) >= 2, (spans, d.bows)
    s0, e0 = spans[0]
    cfg = d.cfg
    assert cfg["bow_hold"] <= e0 - s0 <= cfg["ready_s"] + cfg["bow_hold"] + 2, spans
    r = dict(rows)[s0 + 1]
    p = r["platform"]
    assert p["name"] == "Asterion" and p["label"] == "Asterion · the bow · travelling to Aquilo (1%) · 72 km/s", p
    assert r["agents"] == [] and r["surface"] == "platform-16", r
    shot = [b for b in sent if b.get("surface") == "platform-16"]
    zoom = round(60.0 / (102 + 12), 2)
    assert shot[0]["position"] == {"x": 0.0, "y": round(-50 + (0.5 - cfg["bow_ahead"]) * 34.0 / zoom, 1)}, shot[0]
    assert shot[0]["zoom"] == zoom and shot[0]["smooth"] is False, shot[0]
    # it came in at a story turn, and the story went to the agent that turn was for
    before = dict(rows)[s0 - 1]["agents"]
    after_cut = next(c for c in d.cuts if c[0] >= e0 - 1)
    turn = d.bows[0]
    assert after_cut[2].startswith("after the bow: "), d.cuts
    assert dict(rows)[e0 + 1]["agents"] == [after_cut[2].split(": ")[1]] != before, (before, after_cut)
    # the next one after bow_gap, once every agent on air had a story since (a round)
    s1 = spans[1][0]
    assert s1 - s0 >= cfg["bow_gap"], spans
    seen = {n for now, r in rows if s0 < now < s1 for n in r.get("agents") or []}
    assert seen == {"luna", "sol", "astra"}, seen
    assert turn[2] == "the first" and d.bows[1][2].startswith("round over (3 agents"), d.bows


def not_first():
    d, _ = world(**FAST)
    a, t = team(), 1000
    d.started = t
    rows = run(d, a, [ship()], t, int(d.cfg["bow_first"]) + 40)
    first = bows(rows)
    assert first and first[0][0] >= t + d.cfg["bow_first"], first


def no_bow():
    a, t = team(), 1000
    for rows in ([ship(at="solar-system-edge")], [ship(view=dict(BOW_VIEW, bow=None))], []):
        d, _ = world(**FAST)
        assert not bows(run(d, a, rows, t, 300)) and not d.bows, rows


def holds():
    # a segment holds the camera the whole time: no bow
    d, _ = world(**FAST)
    a, t = team(), 1000
    seg = {"id": "seg-1", "follow": "sol", "zoom": 0.9, "until": t + 400, "label": "Spotlight: Sol"}
    rows = run(d, a, [ship()], t, 300, seg=lambda now: seg if now >= t + 5 else None)
    assert not [s for s in bows(rows) if s[0] >= t + 7], (bows(rows), d.bows)
    # a replay on air (serve.py hold_layout): no bow while it is
    d, _ = world(**FAST)
    rows = run(d, a, [ship()], t, 300, hold=lambda now: True)
    assert not bows(rows), bows(rows)
    # a danger shot takes the bow over
    d, _ = world(**FAST)
    rows = run(d, a, [ship()], t, 200)
    s0 = bows(rows)[0][0]
    d2, _ = world(**FAST)
    rows = run(d2, a, [ship()], t, s0 - t + 2)
    assert (rows[-1][1].get("platform") or {}).get("why") == "bow", rows[-1]
    hurt = dict(ship(), danger={"kind": "fire", "reason": "Asterion under fire: 3 buildings lost", "last": s0 + 2,
                                "level": 3})
    rows = run(d2, a, [hurt], s0 + 2, 6)
    assert (rows[-1][1].get("platform") or {}).get("why") == "danger", rows[-1]


def one_camera():
    sent = []
    d = OneCam(cams.slots("1"), lambda b: sent.append(b) or {"ok": True}, None, **FAST)
    d.started = 0
    a, t = team(), 1000
    rows = run(d, a, [ship()], t, 700)
    spans = bows(rows)
    assert len(spans) >= 2, (spans, d.cuts[-5:])
    shot = [b for b in sent if b.get("surface") == "platform-16"]
    assert shot and all(b["player"] == 1 for b in shot), shot[:2]
    s0, e0 = spans[0]
    assert e0 - s0 <= d.cfg["ready_s"] + d.cfg["bow_hold"] + 2, spans
    assert any(c[2].startswith("after the bow: ") for c in d.cuts), d.cuts


def guns(ahead, half=40, side=36):
    """Turrets on the bow's top row: at x -half and +half with range `side`, and one in the middle reaching `ahead`."""
    return [{"x": -half, "y": BOW["top"], "range": side}, {"x": half, "y": BOW["top"], "range": side},
            {"x": 0, "y": BOW["top"], "range": ahead}]


def bow_shot(view):
    """The bow shot sent for a ship with this view, and the world's on-air width share."""
    d, sent = world(**FAST)
    rows = run(d, team(), [ship(view=view)], 1000, 400)
    assert bows(rows), d.bows
    shot = [b for b in sent if b.get("surface") == "platform-16"][0]
    return shot, d.onair_frac(), d.cfg["bow_ahead"]


def reach_frame():
    for ahead, zoom in ((36, 0.34), (40, 0.30), (60, 0.30)):
        shot, frac, bow_ahead = bow_shot(dict(BOW_VIEW, guns=guns(ahead)))
        assert shot["zoom"] == zoom, (ahead, shot)
        vh, vw = 34.0 / zoom, 60.0 * frac / zoom
        top = shot["position"]["y"] - vh / 2
        assert abs(top - (BOW["top"] - bow_ahead * vh)) < 0.1, (top, shot)  # the bow's edge still bow_ahead down
        shown = BOW["top"] - top
        if ahead <= 40:  # the reach and 4 tiles ahead, and across: -76..76 and 4 each side
            assert shown >= ahead + 4 and vw >= 152 + 8, (ahead, shown, vw)
            assert shot["position"]["x"] == 0.0, shot
        else:  # past what 0.3 shows: 0.3 (45 tiles ahead, 200 across), the reach's top out of frame
            assert abs(shown - bow_ahead * 34.0 / 0.3) < 0.1 and shown < ahead + 4, shown
    # a reach the bow's own frame covers: its zoom as without guns (60 / (102 + 12)), centred on the bow
    shot, _, _ = bow_shot(dict(BOW_VIEW, guns=guns(5, half=20, side=10)))
    assert shot["zoom"] == round(60.0 / 114, 2) and shot["position"]["x"] == 0.0, shot
    # the mock's Asterion leg (its guns as world n's Asterion at 19:30: x -88.5..88.5, top 32.5 ahead of the bow): on the
    # live layout's crop (view_frac 0.658) the width wants 0.21, so 0.3: 45.3 tiles ahead, 131.6 across (the reach's
    # top in, the outer 23 tiles of each side out); full width (the trio's 0.999) fits it at 0.32
    import types, mock
    obs = {}
    mock.MockSource.long_flight_step(types.SimpleNamespace(t0=0), 600, obs)
    mview = obs["space"]["platforms"][0]["view"]
    for frac, zoom in ((0.658, 0.3), (1.0, 0.32)):
        d, sent = world(**dict(FAST, view_frac=frac))
        rows = run(d, team(), [ship(view=dict(BOW_VIEW, **{k: mview[k] for k in ("bow", "hull", "guns")}))], 1000, 400)
        shot = [b for b in sent if b.get("surface") == "platform-16"][0]
        assert shot["zoom"] == zoom and shot["position"]["x"] == 0.0, (frac, shot)
        assert 0.4 * 34.0 / zoom >= 36.5, zoom  # the reach's top and 4 tiles more in frame
    # a ship whose reach is off-centre: centred on the bow and the reach together
    shot, _, _ = bow_shot(dict(BOW_VIEW, guns=[{"x": 60, "y": -50, "range": 30}]))
    assert shot["position"]["x"] == round((-51 + 90) / 2, 1), shot


def main():
    hull_read()
    live_hulls()
    three_clients()
    not_first()
    no_bow()
    holds()
    one_camera()
    reach_frame()
    print("test_bowcam: ok")


if __name__ == "__main__":
    main()
