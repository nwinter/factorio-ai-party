#!/usr/bin/env python3
"""Flare barrages and spider raids on air (d26 batch224 AY and VS, viewer Aurora 05:29 site:4974/4976: "Could batch222
show remote Spidertron movement/combat and artillery firing/impacts automatically? Opus's shelling is off-screen. Follow
the vehicle or target area while the action lasts."): python3 tools/stream/test_raidcam.py

1. A flare's shell (artillery_live: flare, eta 23 s) is kept until arty_pre before it lands, then cut to: "Opus's
   flare → big spitter nest"; more shells of the barrage hold the shot (to arty_max), its frame glides to the impacts
   due next, it ends arty_after past the last; the next shot waits arty_gap from that end. At 1 and 3 cameras.
2. A shell landing while the shot is still framed on its standby joins it.
3. A remote spidertron walking (a go_to reply with no speed: led at vehicle_speed), fighting (a fight within
   fight_near of it, from a read minutes old) or firing (status vehicle_fire) keeps its agent active and shown on it.
4. keep_vehicle's switch is framed on its standby and cut to as framed (shift79 03:56:42 aired Sol instead), and does
   not flip back within vehicle_flip.
5. The service: a journal flare request (WorkFeed.flare_at) cuts the artillery poller's wait short; the poller follows
   the read's `every` down to 0.1 s.
6. director_replay.py: attack alerts from the journals' team blocks as fights; shells modelled from flares.
"""
import json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from test_onecam import agent  # noqa: E402
from test_freshcam import world  # noqa: E402
import airtime, director_replay, work  # noqa: E402


def snap(agents, shells=(), read_at=None, fights=()):
    out = {"agents": agents, "alerts": [], "fights": list(fights)}
    if shells:
        out["artillery"] = {"shells": list(shells), "read_at": read_at, "every": 0.2}
    return out


def flare_shell(key, eta_s, x, y, nest="big-spitter-nest", by="opus"):
    return {"key": key, "surface": "nauvis", "from": {"x": -273.5, "y": -558.5}, "at": {"x": -290.0, "y": -556.0},
            "piece": {"name": "artillery-turret", "position": {"x": -273.5, "y": -558.5}, "surface": "nauvis", "by": "astra"},
            "target": {"name": nest, "position": {"x": x, "y": y}, "around": "2 medium-worm-turret" if nest else None},
            "flare": {"by": by, "tick": 1}, "distance": 1300, "eta_ticks": round(eta_s * 60), "by": by}


def team():
    return [agent("luna", 0, 0, 5), agent("opus", 10, 10, 1, activity="thinking", active=False), agent("sol", 300, 0, 1)]


def barrage(cams):
    d, sent = world(cams)
    t = 1000.0
    for k in range(3):
        d.step(snap(team()), t + k)
    t += 3
    # a burst: the first shell read now lands in 23 s; the others land 2-40 s after it within 40 tiles
    first = flare_shell("a", 23.0, -1392.0, 48.0)
    d.step(snap(team(), [first], read_at=t), t)
    assert not d.artys and d.arty_queue, "kept until arty_pre before it lands"
    later = [flare_shell(f"b{i}", 23.0 + 2 + 3 * i, -1392.0 + (i % 4) * 10, 48.0 + (i % 3) * 12) for i in range(13)]
    d.step(snap(team(), later, read_at=t + 1), t + 1)
    cut_at = None
    for k in range(2, 120):
        d.step(snap(team()), t + k)
        if cut_at is None and d.artys and d.artys[-1][1] == "cut":
            cut_at = k
            label = d.artys[-1][3]
            assert label == ("💥 Artillery · Opus's flare → big spitter nest (-1392, 48), with 2 medium worm turret · "
                             "artillery turret (-274, -558), 1300 tiles"), label
            assert 23.0 - d.cfg["arty_pre"] - 1 <= k <= 23.0 - d.cfg["arty_lead"], k
        cur = d.state.get(d.onair) or {}
        if cut_at is not None and k == 40:
            shot = cur.get("artillery")
            assert shot and shot["shells"] >= 6, (cams, cur)
            assert cur["work"].endswith(f"· {shot['shells']} shells"), cur["work"]
    # held through the barrage: the last shell lands at t + 1 + 25 + 36 = t + 62; arty_after past it, then the story
    last_lands = t + 1 + 23.0 + 2 + 3 * 12
    ends = d.arty_end
    assert abs(ends - (last_lands + d.cfg["arty_after"])) < 1.5, (ends, last_lands)
    assert ends - (t + cut_at) <= d.cfg["arty_max"] + 0.01
    # it framed the impacts: some reframe moved the shot after the cut (a glide on the client on air)
    moved = [b for b in sent if b.get("position") and b.get("position", {}).get("x", 0) != -1392.0 and
             abs(b["position"]["x"] + 1392) < 60 and abs(b["position"]["y"] - 48) < 60]
    assert moved, "the frame followed the impacts"
    z = [b.get("zoom") for b in moved]
    assert all(zz is None or zz >= d.cfg["arty_zoom_min"] * 0.5 for zz in z), z
    cur = d.state.get(d.onair) or {}
    assert not cur.get("artillery") or (t + 119) >= cur.get("until", 0), cur
    # the next burst within arty_gap of that end: dropped for spacing; after it: a cut
    tn = t + 120
    d.step(snap(team(), [flare_shell("c", 3.0, -900, -50)], read_at=tn), tn)
    assert d.artys[-1][1] == "drop" and d.artys[-1][2].startswith("spacing: the last artillery shot ended"), d.artys[-1]
    tn = ends + d.cfg["arty_gap"] + 1
    d.step(snap(team(), [flare_shell("d", 3.0, -900, -50)], read_at=tn), tn)
    assert d.artys[-1][1] == "cut", d.artys[-1]
    print(f"1. a flare barrage at {cams} camera(s): kept until arty_pre, cut, held over its impacts, then spaced: ok")


def joins_while_framed():
    d, _ = world(3)
    t = 1000.0
    for k in range(3):
        d.step(snap(team()), t + k)
    t += 3
    d.step(snap(team(), [flare_shell("a", 4.0, -1392.0, 48.0), flare_shell("b", 5.0, -1380.0, 52.0)], read_at=t), t)
    assert d.pending and d.state[d.pending["slot"]]["artillery"]["shells"] == 2
    # a third shell read while the shot is still framed on the standby (not on air yet)
    d.step(snap(team(), [flare_shell("c", 4.5, -1385.0, 44.0)], read_at=t + 0.5), t + 0.5)
    assert [a[1] for a in d.artys] == ["cut"], d.artys
    shot = d.state[d.pending["slot"]]["artillery"] if d.pending else d.state[d.onair]["artillery"]
    assert shot["shells"] == 3, shot
    print("2. a shell landing while its shot is framed on the standby joins it: ok")


def opus_with(v=None, fire=None):
    a = agent("opus", 10, 10, 5, activity="thinking", active=False)
    a["remote_vehicle"] = v
    a["vehicle_fire"] = fire
    return a


def raid():
    d, _ = world(3)
    t = 2000.0
    # walking: a go_to reply (no speed read) 520 tiles to its target: led at vehicle_speed, walking until it is there
    v = {"vehicle": "spidertron", "unit_number": 7, "position": {"x": -600.0, "y": -560.0}, "speed": None,
         "target": {"x": -1100.0, "y": -700.0}, "t": t}
    a = opus_with(v)
    assert d.vehicle_activity(a, t + 10) == "walking"
    spot = d.vehicle_spot(a, t + 10)
    assert spot and abs(spot["x"] - (-600 - 125 * 500 / 519.2)) < 2, spot  # 12.5 tiles/s for 10 s along the line
    eta = 519.2 / (d.cfg["vehicle_speed"] / 3.6)
    assert d.vehicle_activity(a, t + eta + 2) is None, "arrived: standing"
    # its agent counts as acting while it walks: not standing still
    for k in range(0, 40, 2):
        d.step(snap([a, agent("luna", 0, 0, 5)]), t + k)
    assert d.still_s("opus", t + 38) < 1.0 and d.stale_s("opus", t + 38) < 1.0
    # fighting: a read five minutes old of it standing at (-1300,-850), an attack reported 10 tiles from it
    d2, _ = world(1)
    old = {"vehicle": "spidertron", "unit_number": 7, "position": {"x": -1300.0, "y": -850.0}, "speed": 0, "target": None,
           "t": t - 300}
    b = opus_with(old)
    fight = {"key": "attack:16888", "kind": "attack", "text": "attack #16888", "first": t - 5, "last": t, "losses": [],
             "position": {"x": -1310.0, "y": -845.0, "surface": "nauvis"}}
    d2.fight_list = [fight]
    assert d2.vehicle_activity(b, t) == "fighting"
    assert d2.vehicle_spot(b, t)["label"] == "Opus · spidertron by remote view", "shown from a read 300 s old"
    d2.fight_list = []
    assert d2.vehicle_activity(b, t) is None and d2.vehicle_spot(b, t) is None, "no fight, a stale read: the character"
    d2.fight_list = [fight]
    s_fight = d2.scores([b, agent("luna", 0, 0, 5)], t)
    d2.fight_list = []
    s_calm = d2.scores([b, agent("luna", 0, 0, 5)], t)
    assert s_fight["opus"] > 1.8 * s_calm["opus"], (s_fight, s_calm)
    # firing: seated in a spidertron with enemies in its guns' reach
    c = opus_with(None, {"vehicle": "spidertron", "targets": 3, "ammo": 40, "range": 36, "farthest": 20})
    assert d2.vehicle_activity(c, t) == "firing"
    print("3. a remote spidertron walking, fighting or firing keeps its agent active and shown on it: ok")


def swap_framed():
    """shift79 03:56:39: keep_vehicle framed Opus's spidertron on cam2 and direct() then framed the next story (Sol) on
    the same standby; 03:56:42 cut to cam2 aired Sol."""
    d, _ = world(3)
    t = 3000.0
    opus = opus_with(None)
    opus["activity"], opus["active"], opus["interest"] = "acting", "walk", 9
    others = [agent("sol", 300, 0, 4), agent("luna", -300, 0, 3)]
    for k in range(4):
        opus["position"] = {"x": 10 + 3 * k, "y": 10}
        d.step({"agents": [opus] + others, "alerts": []}, t + k)
    assert d.state[d.onair]["subject"] == "opus", d.state[d.onair]
    v = {"vehicle": "spidertron", "unit_number": 7, "position": {"x": -1500.0, "y": -650.0}, "speed": 40,
         "target": {"x": -1600.0, "y": -700.0}, "t": t + 4}
    opus["remote_vehicle"] = v
    for k in range(4, 9):
        d.step({"agents": [opus] + others, "alerts": []}, t + k)
    cur = d.state[d.onair]
    assert cur["subject"] == "opus" and cur.get("vehicle") == "Opus · spidertron by remote view", cur
    assert d.cuts[-1][2].startswith("vehicle: Opus"), d.cuts[-1]
    swapped = d.vehicle_swapped["opus"]
    # the read goes away at once: no flip back within vehicle_flip
    opus["remote_vehicle"] = None
    n = len(d.cuts)
    for k in range(9, 9 + int(d.cfg["vehicle_flip"]) - 6):
        d.step({"agents": [opus] + others, "alerts": []}, t + k)
    assert len(d.cuts) == n and d.state[d.onair].get("vehicle"), (d.cuts[n:], d.state[d.onair])
    for k in range(int(swapped - t) + int(d.cfg["vehicle_flip"]) + 1, int(swapped - t) + int(d.cfg["vehicle_flip"]) + 6):
        d.step({"agents": [opus] + others, "alerts": []}, t + k)
    assert not d.state[d.onair].get("vehicle") and "back to the character" in d.cuts[-1][2], d.cuts[-1]
    print("4. a vehicle switch is cut to as framed on its standby, and does not flip back within vehicle_flip: ok")


def service():
    import tempfile
    root = tempfile.mkdtemp()
    os.makedirs(os.path.join(root, "opus"))
    p = os.path.join(root, "opus", "journal.jsonl")
    open(p, "w").close()
    feed = work.WorkFeed(root, ["opus"])
    feed.poll()  # (the file's end: rows from now on)
    with open(p, "a") as f:
        f.write(json.dumps({"at": "2026-10-26T09:31:00Z", "event": "request", "request": {
            "id": "x", "action": "use_item", "args": {"item": "artillery-targeting-remote", "position": {"x": -1392, "y": 48}}}}) + "\n")
    assert feed.flare_at == 0.0
    feed.poll()
    assert feed.flare_at > 0.0, "a flare request seen"
    src = open(os.path.join(HERE, "serve.py")).read()
    assert 'getattr(work, "flare_at", 0.0) > read_t' in src and 'every = max(0.1, float(res.get("every") or 10.0))' in src
    import shutil
    shutil.rmtree(root, True)
    print("5. a journal flare wakes the artillery poller; it follows `every` down to 0.1 s: ok")


def replay_inputs():
    t0 = airtime.iso_t("2026-10-26T09:05:30Z")
    j = airtime.Journal("opus")
    j.requests = [
        (t0, "observe", {}, {"team": {"alerts": ["attack #16888 at (-865,-584): 3 attackers seen (3 behemoth-worm-turret); "
                                                 "spidertron x21 hit 21 times, 394 damage, first 32s ago, last 29s ago"]}}, True),
        (t0 + 10, "observe", {}, {"team": {"alerts": ["attack #16888 at (-865,-584): spidertron x30 hit, first 42s ago, "
                                                      "last 2s ago"]}}, True),
        (t0 + 20, "use_item", {"item": "artillery-targeting-remote", "position": {"x": -1182.5, "y": -725.3}},
         {"in_range": ["artillery-turret (-273.5,-558.5) 924.2 tiles, in its manual range only (1568; automatic 627.2), 5 shells",
                       "artillery-turret (-165.5,-565.5) 1029.5 tiles, in its manual range only (1568; automatic 627.2), 5 shells"]}, True),
        (t0 + 20.5, "use_item", {"item": "artillery-targeting-remote", "position": {"x": -1180.0, "y": -720.0}},
         {"in_range": ["artillery-turret (-273.5,-558.5) 921.0 tiles, in its manual range only (1568; automatic 627.2), 5 shells"]}, True)]
    fights = director_replay.fights_of({"opus": j})
    assert len(fights) == 1 and fights[0]["first"] == t0 - 32 and fights[0]["last"] == t0 + 8, fights
    assert fights[0]["position"] == {"x": -865.0, "y": -584.0, "surface": "nauvis"}
    shells = director_replay.flare_shells({"opus": j})
    assert len(shells) == 2, shells
    (a1, s1), (a2, s2) = shells
    assert a1 == t0 + 21 and abs(s1["land_t"] - (a1 + 924.2 / 60)) < 0.01 and s1["flare"]["by"] == "opus"
    # the second flare's only piece in range is cooling down from the first shot: it fires COOLDOWN_S later
    assert abs(a2 - (a1 + director_replay.COOLDOWN_S)) < 1e-6, (a1, a2)
    print("6. director_replay: attacks from the team blocks as fights, shells modelled from flares: ok")


def main():
    barrage(3)
    barrage(1)
    joins_while_framed()
    raid()
    swap_framed()
    service()
    replay_inputs()
    print("raidcam: ok (flare barrages held over their impacts at 1 and 3 cameras; a remote spidertron walking, fighting "
          "or firing kept on air; the vehicle switch framed as cut; the service and the replay's inputs)")


if __name__ == "__main__":
    main()
