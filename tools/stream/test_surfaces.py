"""onecam's surface balance (viewer awoo3391 19:34, "the camera feed needs a real priority system"): with 7 agents on
Nauvis, Gemini on Fulgora and Sol on Vulcanus, the story rotation gives the two newer planets their share of air time;
urgent shots and the dwell rules come first; the score line says why. Run: python3 tools/stream/test_surfaces.py"""
import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.dont_write_bytecode = True
from onecam import OneCam  # noqa: E402

SLOTS = [{"slot": "main", "player": 3}, {"slot": "cam2", "player": 4}, {"slot": "cam3", "player": 5}]
NAUVIS = ["astra", "luna", "opus", "sonnet", "haiku", "grok", "muse"]


def team():
    out = [{"name": n, "display_name": n.title(), "alive": True, "position": {"x": 40 * i, "y": 0}, "surface": "nauvis",
            "activity": "acting", "active": "walk", "interest": 1.0, "seen": True} for i, n in enumerate(NAUVIS)]
    out.append({"name": "gemini", "display_name": "Gemini", "alive": True, "position": {"x": 5, "y": 5}, "surface": "fulgora",
                "activity": "acting", "active": "walk", "interest": 1.0, "seen": True})
    out.append({"name": "sol", "display_name": "Sol", "alive": True, "position": {"x": 9, "y": 9}, "surface": "vulcanus",
                "activity": "acting", "active": "walk", "interest": 1.0, "seen": True})
    return out


def run(minutes=30, **cfg):
    d = OneCam(SLOTS, lambda body: {"ok": True}, None, **dict({"trio": False, "map_every": 0, "platform_every": 0,
                                                               "attention": False}, **cfg))
    d.started = 0
    agents = team()
    by = {a["name"]: a for a in agents}
    air = {}
    t0 = 1000.0
    for k in range(int(minutes * 60)):
        now = t0 + k
        # agents keep walking (positions change a little), so nobody reads as standing still
        for a in agents:
            a["position"] = {"x": a["position"]["x"] + (0.5 if k % 2 else -0.5), "y": a["position"]["y"]}
        d.step({"agents": agents, "alerts": []}, now)
        s = d.onair_surface(by)
        if s:
            air[s] = air.get(s, 0) + 1
    total = sum(air.values()) or 1
    return d, {s: round(v / total, 3) for s, v in air.items()}


def main():
    off, share_off = run(surface_bonus=0)
    on, share_on = run()
    print("air share, balance off:", share_off)
    print("air share, balance on: ", share_on)
    # the two newer planets get their share (target 25% plus up to 25% while new; together at most 75%), Nauvis keeps
    # the rest, about 25% while both are new (without the balance, equal scores broke ties in list order and Nauvis
    # had all of it)
    assert share_on.get("fulgora", 0) >= 0.2 and share_on.get("vulcanus", 0) >= 0.2, share_on
    assert share_on.get("fulgora", 0) + share_on.get("vulcanus", 0) > share_off.get("fulgora", 0) + share_off.get("vulcanus", 0) + 0.15
    assert 0.2 <= share_on.get("nauvis", 0) <= 0.6, share_on
    # the score line says why: the cut reason and the director's log entry
    helped = [r for _, _, r in on.cuts if "(surface " in r]
    assert helped and any("fulgora" in r or "vulcanus" in r for r in helped), on.cuts[-8:]
    assert on.surface_log and set(on.surface_log["target"]) == {"fulgora", "vulcanus"}
    assert not any("(surface " in r for _, _, r in off.cuts) and off.surface_log is None
    # the dwell rules hold: story cuts (beats or rotate) come at least onair_dwell apart
    story = [t for t, _, r in on.cuts if " beats " in r or r.startswith("rotate")]
    assert all(b - a >= on.cfg["onair_dwell"] for a, b in zip(story, story[1:])), story
    # a planet the run has known for hours is due the base share only; a new one more
    d = OneCam(SLOTS, lambda body: {"ok": True}, None, trio=False)
    agents = team()
    # no balance before surface_warmup seconds of air history (a restart does not swing the first pick)
    assert d.surface_factors(agents, {a["name"]: 1.0 for a in agents}, 4 * 3600) == {} and d.surface_log is None
    d.cfg["surface_warmup"] = 0
    d.surface_seen = {"nauvis": 0, "vulcanus": 0, "fulgora": 4 * 3600}  # Vulcanus known 4 h, Fulgora just landed
    f = d.surface_factors(agents, {a["name"]: 1.0 for a in agents}, 4 * 3600)
    assert d.surface_log["target"] == {"fulgora": 35, "vulcanus": 25}, d.surface_log
    d.surface_seen["vulcanus"] = 4 * 3600  # both new: 35% each, scaled to 60% together
    d.surface_factors(agents, {a["name"]: 1.0 for a in agents}, 4 * 3600)
    assert d.surface_log["target"] == {"fulgora": 30, "vulcanus": 30}, d.surface_log
    d.surface_seen["vulcanus"] = 0
    assert f["gemini"] > 2.4 and f["sol"] > 2.4 and f["astra"] == 0.85, f  # nothing aired yet: both well under
    # once a surface has its share, no bonus; Nauvis no penalty when nobody is under
    d.surface_air = [(4 * 3600, "fulgora", 400.0), (4 * 3600, "vulcanus", 300.0), (4 * 3600, "nauvis", 300.0)]
    f = d.surface_factors(agents, {a["name"]: 1.0 for a in agents}, 4 * 3600)
    assert f == {}, f
    # urgent shots come first: a loss on Nauvis while the story is on Fulgora cuts at once
    d2, _ = run(minutes=3)
    agents = team()
    t = 1000.0 + 180
    loss = {"id": "l1", "kind": "loss", "t": t, "text": "26 lost near (-128, 38): 14 transport belt, 7 inserter",
            "position": {"x": -128, "y": 38, "extent": 20, "surface": "nauvis"}, "key": "loss:-128,38"}
    d2.step({"agents": agents, "alerts": [loss]}, t)
    for k in range(1, 4):
        d2.step({"agents": agents, "alerts": []}, t + k)
    assert any(r.startswith("loss:") for _, _, r in d2.cuts), d2.cuts[-3:]
    print("surfaces: ok (Fulgora and Vulcanus get their share, newer planets more, urgent first, dwell kept, logged)")


if __name__ == "__main__":
    main()
