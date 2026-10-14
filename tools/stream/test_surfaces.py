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
    assert d.surface_log["target"] == {"fulgora": 50, "vulcanus": 25}, d.surface_log
    d.surface_seen["vulcanus"] = 4 * 3600  # both new: 50% each, scaled to 75% together
    d.surface_factors(agents, {a["name"]: 1.0 for a in agents}, 4 * 3600)
    assert d.surface_log["target"] == {"fulgora": 38, "vulcanus": 38}, d.surface_log
    d.surface_seen["vulcanus"] = 0
    assert f["gemini"] > 2.4 and f["sol"] > 2.4 and f["astra"] == 0.85, f  # nothing aired yet: both well under
    # once a surface has its share, no bonus; Nauvis no penalty when nobody is under
    d.surface_air = [(4 * 3600, "fulgora", 500.0), (4 * 3600, "vulcanus", 260.0), (4 * 3600, "nauvis", 240.0)]
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
    new_planet()
    surfaces_read()
    surface_memory()
    print("surfaces: ok (Fulgora and Vulcanus get their share, newer planets more, urgent first, dwell kept, logged; "
          "a new planet's floor beats any score; aboard, riding and remote view read right)")


def gleba_team():
    """shift09 23:37: Astra on Nauvis scoring 33.48 took the camera from Sol, just landed on Gleba, at 3.603."""
    out = [{"name": n, "display_name": n.title(), "alive": True, "position": {"x": 40 * i, "y": 0}, "surface": "nauvis",
            "activity": "acting", "active": "walk", "interest": 33.0 if n == "astra" else 6.0, "seen": True}
           for i, n in enumerate(NAUVIS)]
    out.append({"name": "sol", "display_name": "Sol", "alive": True, "position": {"x": 9, "y": 9}, "surface": "gleba",
                "activity": "acting", "active": "walk", "interest": 3.6, "seen": True})
    return out


def run_team(agents, minutes, alerts_at=None, follow_at=None, **cfg):
    d = OneCam(SLOTS, lambda body: {"ok": True}, None, **dict({"trio": False, "map_every": 0, "platform_every": 0,
                                                               "attention": False}, **cfg))
    d.started = 0
    by = {a["name"]: a for a in agents}
    air, t0 = {}, 1000.0
    for k in range(int(minutes * 60)):
        now = t0 + k
        for a in agents:
            a["position"] = {"x": a["position"]["x"] + (0.5 if k % 2 else -0.5), "y": a["position"]["y"]}
        if follow_at and k == follow_at[0]:
            d.set_follow(follow_at[1], now + follow_at[2], "the operator's follow", "nick", now)
        d.step({"agents": agents, "alerts": (alerts_at or {}).get(k, [])}, now)
        s = d.onair_surface(by)
        if s:
            air[s] = air.get(s, 0) + 1
    total = sum(air.values()) or 1
    return d, {s: round(v / total, 3) for s, v in air.items()}


def new_planet():
    """A planet new to the run under surface_new_floor (0.5) of its target gets the story whatever the scores; the cut
    says so; past the floor the factor applies as before (task-newplanet, viewer awoo3391 23:46)."""
    old, share_old = run_team(gleba_team(), 30, surface_new_floor=0)
    d, share = run_team(gleba_team(), 30)
    print("Gleba's air share, floor off:", share_old.get("gleba", 0), " floor on:", share.get("gleba", 0))
    # without the floor, 3.6 x at most 2.5 never beats 33: Gleba gets only what rotation after onair_max gives it
    # (here one 90 s turn in each long Astra stretch, about 10%; on shift09 the rotation went to other Nauvis agents)
    assert share_old.get("gleba", 0) <= 0.12, share_old
    assert not any("new planet" in r for _, _, r in old.cuts)
    # with it: the story goes to Sol, the cut says why, as "new planet gleba 0% of 50%" (Gleba alone is new: 25% + 25%)
    floor_cuts = [(t, r) for t, _, r in d.cuts if r.startswith("new planet gleba")]
    assert floor_cuts and floor_cuts[0][1] == "new planet gleba 0% of 50%", floor_cuts[:3]
    # Gleba holds about the floor (half its 50% target) over the run, after the warmup on Nauvis
    assert share.get("gleba", 0) >= 0.2 and share["gleba"] >= share_old.get("gleba", 0) + 0.1, (share, share_old)
    # past the floor the normal factor applies again: Astra's 33 beats Sol, so the program comes back to Nauvis
    later = [r for t, _, r in d.cuts if t > floor_cuts[0][0]]
    assert any(r.startswith("astra ") and " beats sol " in r for r in later), later[:6]
    # the dwell rules hold for these cuts too: story cuts at least onair_dwell apart
    story = [t for t, _, r in d.cuts if " beats " in r or r.startswith(("rotate", "new planet"))]
    assert all(b - a >= d.cfg["onair_dwell"] for a, b in zip(story, story[1:])), story
    # urgent shots come first: a loss on Nauvis while the floor holds the story on Gleba cuts at once
    loss = {"id": "l9", "kind": "loss", "t": 0, "text": "26 lost near (-128, 38): 14 transport belt, 7 inserter",
            "position": {"x": -128, "y": 38, "extent": 20, "surface": "nauvis"}, "key": "loss:-128,38"}
    k = 600  # 10 minutes in: well past warmup, Gleba under its floor again or on air
    u, _ = run_team(gleba_team(), 11, alerts_at={k: [dict(loss, t=1000.0 + k)]})
    assert any(r.startswith("loss:") and abs(t - (1000.0 + k)) <= 3 for t, _, r in u.cuts), u.cuts[-6:]
    # an operator follow pins its agent while the floor would want Gleba
    f, share_f = run_team(gleba_team(), 12, follow_at=(300, "luna", 400))
    pinned = [r for t, _, r in f.cuts if 1300 <= t <= 1700]
    assert not any(r.startswith("new planet") for r in pinned), pinned
    # a planet known for hours (novelty 0) is due its base share only: no floor
    h = OneCam(SLOTS, lambda body: {"ok": True}, None, trio=False)
    h.cfg["surface_warmup"] = 0
    agents = gleba_team()
    h.surface_air = [(4 * 3600, "nauvis", 600.0)]
    h.surface_seen = {"nauvis": 0, "gleba": 0}  # Gleba seen 4 h ago (surface_new_hours 3)
    h.surface_factors(agents, {a["name"]: 1.0 for a in agents}, 4 * 3600)
    assert h.surface_due is None and h.surface_log["target"] == {"gleba": 25}, (h.surface_due, h.surface_log)
    h.surface_seen["gleba"] = 4 * 3600 - 600  # landed 10 minutes ago
    h.surface_factors(agents, {a["name"]: 1.0 for a in agents}, 4 * 3600)
    assert h.surface_due == {"surface": "gleba", "share": 0, "target": 49}, h.surface_due
    assert h.surface_log["due"] == "gleba", h.surface_log  # the director log's entries carry it


def surfaces_read():
    """The balance reads the planet an agent's body stands on: the harness reports the body's surface, not a remote
    view; aboard a platform or riding a cargo pod there is no body on a planet (a platform has its own shots)."""
    b = OneCam.balance_surface
    assert b({"surface": "gleba"}) == "gleba" and b({}) == "nauvis"
    # remote view: an agent on Nauvis working on Gleba (attention, platform= calls) still counts for Nauvis
    assert b({"surface": "nauvis", "attention": {"surface": "gleba", "kind": "place_ghosts"}}) == "nauvis"
    assert b({"surface": "platform-1", "platform": "Sunward", "on_platform": True, "travel": "aboard"}) is None
    assert b({"surface": "platform-3", "on_platform": True}) is None  # a player standing on a platform
    assert b({"surface": "gleba", "travel": "descending"}) is None and b({"surface": "nauvis", "travel": "ascending"}) is None
    # a platform never becomes a "new planet": the only agent off Nauvis is aboard Sunward
    d = OneCam(SLOTS, lambda body: {"ok": True}, None, trio=False)
    d.cfg["surface_warmup"] = 0
    agents = gleba_team()[:-1] + [{"name": "sol", "display_name": "Sol", "alive": True, "position": {"x": 0, "y": 0},
                                   "surface": "platform-1", "on_platform": True, "travel": "aboard",
                                   "activity": "acting", "active": "walk", "interest": 3.6, "seen": True}]
    d.surface_air = [(4 * 3600, "nauvis", 600.0)]
    d.account_surface({a["name"]: a for a in agents}, 4 * 3600)
    assert "platform-1" not in d.surface_seen, d.surface_seen
    f = d.surface_factors(agents, {a["name"]: 1.0 for a in agents}, 4 * 3600)
    assert d.surface_due is None and f == {} and d.surface_log is None, (d.surface_due, f, d.surface_log)



def surface_memory():
    """When an agent first stood on each planet, in game ticks, kept in the run folder (surface-seen.json) and read up
    the resumed-from chain: a restart or the next shift does not make every planet new again; a planet the run reached
    before ticks were kept (space-memory.json) is not new; novelty counts game time."""
    import json, tempfile
    root = tempfile.mkdtemp()
    a, b = os.path.join(root, "shiftA"), os.path.join(root, "shiftB")
    os.makedirs(a), os.makedirs(b)
    with open(os.path.join(a, "surface-seen.json"), "w") as f:
        json.dump({"vulcanus": 1000}, f)
    with open(os.path.join(a, "space-memory.json"), "w") as f:
        json.dump({"visited": {}, "reached": ["fulgora", "nauvis", "vulcanus"]}, f)
    with open(os.path.join(b, "resumed-from"), "w") as f:
        f.write("shiftA\n")
    path = os.path.join(b, "surface-seen.json")
    d = OneCam(SLOTS, lambda body: {"ok": True}, None, trio=False)
    d.set_surface_memory(path)
    assert d.surface_ticks == {"vulcanus": 1000} and {"fulgora", "vulcanus"} <= d.surface_known, (d.surface_ticks, d.surface_known)
    agents = gleba_team() + [
        {"name": "gemini", "display_name": "Gemini", "alive": True, "position": {"x": 5, "y": 5}, "surface": "fulgora",
         "activity": "acting", "active": "walk", "interest": 1.0, "seen": True},
        {"name": "luna2", "display_name": "Luna2", "alive": True, "position": {"x": 7, "y": 7}, "surface": "vulcanus",
         "activity": "acting", "active": "walk", "interest": 1.0, "seen": True}]
    by = {x["name"]: x for x in agents}
    now = 5000.0
    d.game_tick = 1000 + 216000 * 4  # four game hours after Vulcanus
    d.account_surface(by, now)
    assert d.surface_ticks["gleba"] == d.game_tick and "fulgora" not in d.surface_ticks, d.surface_ticks
    with open(path) as f:
        assert json.load(f) == {"gleba": d.game_tick, "vulcanus": 1000}
    assert d.novelty("gleba", now) == 1.0 and d.novelty("vulcanus", now) == 0.0 and d.novelty("fulgora", now) == 0.0
    # novelty counts game time (the game does not run between shifts), not this service's clock
    d.game_tick += int(216000 * 1.5)
    assert abs(d.novelty("gleba", now + 10) - 0.5) < 1e-9, d.novelty("gleba", now + 10)
    # a restart in the same run keeps Gleba's first tick; only the new planet gets a new planet's floor
    d2 = OneCam(SLOTS, lambda body: {"ok": True}, None, trio=False)
    d2.set_surface_memory(path)
    d2.cfg["surface_warmup"] = 0
    d2.game_tick = d.game_tick
    d2.surface_air = [(now, "nauvis", 600.0)]
    d2.account_surface(by, now)
    assert d2.surface_ticks["gleba"] == 1000 + 216000 * 4
    d2.surface_factors(agents, {x["name"]: 1.0 for x in agents}, now)
    # Gleba half new: 25% + 25% x 0.5; Fulgora and Vulcanus 25%; together 87.5%, scaled to 75%
    assert d2.surface_log["target"] == {"fulgora": 21, "gleba": 32, "vulcanus": 21}, d2.surface_log
    # Gleba (new, 0% of 32%) is due; Fulgora, at 0% too but known, is not
    assert d2.surface_due == {"surface": "gleba", "share": 0, "target": 32}, d2.surface_due
    print("surface memory: ok")


if __name__ == "__main__":
    main()
