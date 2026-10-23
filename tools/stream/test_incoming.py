#!/usr/bin/env python3
"""Incoming groups and dynamic threat scores (threats.py, onecam.py watch_incoming, live.py, model.py; Nick 13:40:
"Can we follow biter attacks as they approach a base?", 13:45: "Shouldn't the attack group size/threshold be dynamic
..."): python3 tools/stream/test_incoming.py

1. Scores: a group's size against the run's last groups (the same 37 is notable early and ordinary once 37s are
   usual), a tier above the usual mix (more the first times), aimed at an agent, an outpost, a new direction.
2. The budget: rare candidates meet the floor; frequent ones a bar near the budget's share; a spent budget passes
   nothing; the history survives a restart (the run folder's file).
3. The director: a group that passes is followed (a cut to a fixed view on it, labelled), the view pans with it
   (smooth moves), and at contact the battle hold takes over at the same place, no cut; within incoming_spacing or
   while a battle holds, the next group is logged and skipped; every score and decision goes to the director log.
4. live.py reads attack_groups_live only from a runtime that lists it (describe operator_reads); model.py labels
   each group "37 biters and spitters heading for ...".
5. (d23 batch124 CG1, Nick 10:00) calibrated to how attacks go now: each group tracked to its end with contact and
   the real losses near it; routine waves the defenses hold (none destroyed anything) score about 1.2 lower, a run
   of damaging ones lifts it; a target inside the base map that no turret reaches adds no_cover. The followed group's
   view aims ahead of it (its velocity over the last 6 s, 4 s on) and the follow ends 12 s after it stops.
"""
import json, os, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from threats import Threats, tier_of, percentile  # noqa: E402
from test_onecam import agent, world  # noqa: E402

# shift06's gathered groups as the agents' status replies recorded them (runs/shift06/*/journal.jsonl)
RECORDED = [
    {"size": 13, "kinds": "5 medium-biter, 4 medium-spitter, 2 small-biter, 2 small-spitter", "position": {"x": 154, "y": 115}, "target": {"x": -21, "y": 38}},
    {"size": 21, "kinds": "7 medium-biter, 7 small-spitter, 4 medium-spitter, 2 big-biter", "position": {"x": 155, "y": 120}, "target": {"x": 0, "y": 42}},
    {"size": 5, "kinds": "3 medium-biter, 1 medium-spitter, 1 small-spitter", "position": {"x": 160, "y": -142}, "target": {"x": 66, "y": -54}},
    {"size": 37, "kinds": "16 small-spitter, 11 medium-spitter, 7 medium-biter, 2 big-spitter", "position": {"x": 140, "y": 114}, "target": {"x": 47, "y": 2}},
    {"size": 37, "kinds": "16 small-spitter, 9 medium-biter, 7 medium-spitter, 4 big-spitter", "position": {"x": 139, "y": 115}, "target": {"x": 46, "y": 34}},
    {"size": 16, "kinds": "9 small-spitter, 4 medium-spitter, 2 medium-biter, 1 big-biter", "position": {"x": 143, "y": 114}, "target": {"x": 46, "y": 34}},
    {"size": 22, "kinds": "9 small-spitter, 6 medium-spitter, 4 medium-biter, 2 big-spitter", "position": {"x": 150, "y": 120}, "target": {"x": 0, "y": 42}},
]
CENTRE = {"x": 0, "y": 0}


def scores():
    assert tier_of(RECORDED[0]["kinds"]) == 2 and tier_of(RECORDED[3]["kinds"]) == 3 and tier_of("(by small demolishers)") == 5
    assert tier_of("3 behemoth-biter") == 4 and percentile([], 9) == 0.5
    th = Threats()
    for g in RECORDED[:3]:
        th.learn_group(g, CENTRE)
    big_early, parts = th.score_group(RECORDED[3], CENTRE)
    small, _ = th.score_group(RECORDED[2], CENTRE)
    assert big_early > small and parts["size"] == 2.0, (big_early, small, parts)  # 37 above every group seen
    for _ in range(12):  # 37s become the usual size: the same group is ordinary now
        th.learn_group(RECORDED[4], CENTRE)
    big_late, parts_late = th.score_group(RECORDED[3], CENTRE)
    assert parts_late["size"] < 1.0 and big_late < big_early, (parts_late, big_late)
    # tier: big is the usual mix now; behemoths count, double the first times
    beh = dict(RECORDED[3], kinds="20 behemoth-biter, 17 big-spitter")
    s1, p1 = th.score_group(beh, CENTRE)
    assert p1["tier"] == 1.5 * (4 - 3) * 2, p1
    for _ in range(3):
        th.learn_group(beh, CENTRE)
    _, p2 = th.score_group(beh, CENTRE)
    assert "tier" not in p2 or p2["tier"] < p1["tier"], p2
    # target: near an agent, an outpost (outside the core), a new direction
    core = {"x0": -60, "y0": -60, "x1": 60, "y1": 60}
    far_west = dict(RECORDED[0], target={"x": -300, "y": 0})
    _, p = th.score_group(far_west, CENTRE, agents=[{"position": {"x": -290, "y": 5}}], core=core)
    assert {"agent", "outpost", "new_dir"} <= set(p), p
    _, p = th.score_group(RECORDED[5], CENTRE, agents=[], core=core)
    assert "agent" not in p and "outpost" not in p and "new_dir" not in p, p
    print(f"scores: ok (37 early {big_early}, after twelve 37s {big_late}; behemoths first {s1})")


def budget():
    th = Threats(budget=4, floor=1.5)
    t = 100000.0
    # rare: one candidate an hour or so meets the floor
    assert th.bar(t)[0] == 1.5
    assert th.decide("group", "a", 1.6, {}, t) and not th.decide("group", "b", 1.4, {}, t + 60)
    # constant: 40 candidates in the hour, scores 0..3.9: the bar is about the budget's share from the top
    th2 = Threats(budget=4, floor=0.5)
    for i in range(40):
        th2.h["candidates"].append([t - 3000 + i * 60, i / 10])
    bar, ctx = th2.bar(t)
    assert 3.4 <= bar <= 3.6 and ctx["candidates_h"] == 40, (bar, ctx)
    assert not th2.decide("battle", "c", 3.0, {}, t) and th2.decide("battle", "d", 3.8, {}, t)
    # spent: four taken in the hour, nothing passes
    th3 = Threats(budget=4)
    th3.h["taken"] = [t - 100, t - 200, t - 300, t - 400]
    assert th3.bar(t)[0] == float("inf") and not th3.decide("group", "e", 99, {}, t)
    assert th3.bar(t + 3600)[0] == 1.0  # an hour later: open again
    # blocked: logged and counted, never taken
    log = []
    th4 = Threats(log=log.append)
    assert not th4.decide("group", "f", 9, {"size": 2}, t, blocked="spacing (30 s since the last followed group)")
    assert log[-1]["decision"] == "skip" and log[-1]["why"].startswith("spacing") and log[-1]["parts"] == {"size": 2}
    # the run folder's history survives a restart
    path = os.path.join(tempfile.mkdtemp(), "threat-history.json")
    a = Threats(path)
    for g in RECORDED:
        a.learn_group(g, CENTRE)
    a.decide("group", "g", 5, {}, t)
    b = Threats(path)
    assert b.h["sizes"] == [g["size"] for g in RECORDED] and b.h["taken"] == [t] and json.load(open(path))["tiers_seen"]
    print(f"budget: ok (rare: floor; 40 an hour: bar {bar}; spent: none; kept across a restart)")


def live_row(g, gid, pos, state="moving", near=None, t=0):
    return dict(g, id=gid, surface="nauvis", position=pos, state=state, nearest_distance=near, label=f"{g['size']} biters and spitters heading for the base")


def director():
    logs = []
    d, sent = world(map_every=0, platform_every=0)
    d.log_path = os.path.join(tempfile.mkdtemp(), "director.jsonl")
    team = [agent("astra", 0, 0, 5), agent("luna", 300, 0, 1), agent("sol", -300, 0, 1)]
    t0 = 70000
    for k in range(3):
        d.step({"agents": team, "alerts": []}, t0 + k)
    assert (d.public(t0 + 2).get("main") or {}).get("agents") == ["astra"]
    g = RECORDED[3]
    path = [(140 - 3 * k, 114 - 3.5 * k) for k in range(40)]  # from the gathering spot toward (47, 2)
    rows = []
    cuts0 = None
    for k in range(40):
        t = t0 + 10 + k
        state, near = ("moving", 60 - k) if k < 32 else ("attacking_target", 5)
        inc = [live_row(g, 7, {"x": path[k][0], "y": path[k][1]}, state, near)]
        if k == 20:  # a second group: inside the spacing, skipped and logged
            inc.append(live_row(RECORDED[4], 8, {"x": 139, "y": 115}))
        pub = d.step({"agents": team, "alerts": [], "incoming": inc}, t)
        rows.append((k, pub.get("main") or {}))
        if k == 3:
            cuts0 = len(d.cuts)
    on = [r for k, r in rows if 3 <= k < 32]
    assert all(r.get("incoming", "").startswith("Incoming · 37 biters and spitters") for r in on), on[:2]
    assert d.cuts[cuts0 - 1][2].startswith("incoming: 37"), d.cuts
    pans = [b for b in sent if b.get("position") and b.get("smooth") and b.get("zoom") == 0.7]
    assert len(pans) >= 8, len(pans)  # smooth pans with the group
    xs = [b["position"]["x"] for b in pans]
    assert xs == sorted(xs, reverse=True), xs  # westward, as it goes
    # (CG1) ahead of it: 3 and 3.5 tiles a second (4.6), 4 s on: about 18 tiles along its way, not behind it
    by_t = {k: path[k] for k in range(40)}
    late = [b for b in pans][-3:]
    for b in late:
        k = min(by_t, key=lambda k: abs(by_t[k][0] - b["position"]["x"] - 12))  # the read it was aimed from
        assert b["position"]["x"] < path[min(k, 31)][0] and b["position"]["y"] < path[min(k, 31)][1], (b, path[k])
    import onecam
    aim = onecam.lead_point([(0, {"x": 140, "y": 114}), (3, {"x": 131, "y": 103.5}), (6, {"x": 122, "y": 93})], d.cfg)
    assert abs(aim["x"] - (122 - 3 / 4.61 * 18.44)) < 0.2 and abs(aim["y"] - (93 - 3.5 / 4.61 * 18.44)) < 0.2, aim
    assert onecam.lead_point([(0, {"x": 5, "y": 5}), (6, {"x": 6, "y": 5})], d.cfg) == {"x": 6, "y": 5}  # crawling: as is
    assert onecam.lead_point([(0, {"x": 0, "y": 0}), (2, {"x": 60, "y": 0})], d.cfg)["x"] == 108  # capped 48 ahead
    # contact at k=32: the battle hold, same place, no cut
    assert d.battles and d.battles[-1][2].startswith("incoming (score"), d.battles
    assert len(d.cuts) == cuts0, d.cuts[cuts0:]
    assert rows[-1][1].get("battle", "").startswith("Battle · 37 biters"), rows[-1][1]
    entries = [json.loads(l) for l in open(d.log_path)]
    th = [e["threat"] for e in entries if e.get("threat")]
    assert th[0]["key"] == "group:7" and th[0]["decision"] == "take", th[0]
    assert any(e["key"] == "group:8" and e["decision"] == "skip" and "held" in e["why"] for e in th), th
    print(f"director: ok (followed from +3 s, {len(pans)} smooth pans, battle at contact without a cut; the second "
          f"group skipped: {next(e['why'] for e in th if e['key'] == 'group:8')})")


def live_and_model():
    import live
    from model import Model
    src = live.LiveSource.__new__(live.LiveSource)

    class H:
        calls = 0

        def operator_read(self, action, args):
            H.calls += 1
            assert action == "attack_groups_live"
            return {"groups": [dict(RECORDED[3], id=1, surface="nauvis", state="moving")]}, 1

    src.h, src.has_groups, src.groups_every, src.next_groups = H(), False, 2.0, 0
    obs, errors = {}, {}
    src.observe_groups(obs, errors)
    assert "attack_groups" not in obs and H.calls == 0  # an older runtime: never asked
    src.has_groups = True
    src.observe_groups(obs, errors)
    assert obs["attack_groups"][0]["size"] == 37 and H.calls == 1
    obs2 = {}
    src.observe_groups(obs2, errors)
    assert "attack_groups" not in obs2  # not before groups_every
    m = Model({"agents": {}, "landmarks": [{"name": "the oil field", "x": 47, "y": 0, "r": 20}]})
    m.ingest({"agents": [], "attack_groups": obs["attack_groups"]}, now=500)
    inc = m.snapshot(505)["incoming"]
    assert inc[0]["label"] == "37 biters and spitters heading for the oil field" and inc[0]["age_s"] == 5, inc
    m.ingest({"agents": [], "attack_groups": [dict(RECORDED[0], id=2, surface="nauvis", target={"x": 300, "y": 0})]}, now=510)
    inc = m.snapshot(510)["incoming"]
    assert [g["id"] for g in inc] == [2] and inc[0]["label"] == "13 biters and spitters heading for the base, 300 m E of spawn", inc
    print("live and model: ok")


def turned_back_or_stopped():
    """Nick d20 07:14: a followed group came toward Nauvis, went back to the wilderness and sat there, and the camera
    stayed on it until incoming_max (240 s). Turned back (incoming_away from its closest approach) or stopped
    (under incoming_still_tiles in incoming_still s, not while gathering): the follow ends, back to the story."""
    g = RECORDED[3]
    for case in ("back", "still", "gathering"):
        d, sent = world(map_every=0, platform_every=0)
        d.log_path = os.path.join(tempfile.mkdtemp(), "director.jsonl")
        team = [agent("astra", 0, 0, 5), agent("luna", 300, 0, 1), agent("sol", -300, 0, 1)]
        t0 = 70000
        for k in range(3):
            d.step({"agents": team, "alerts": []}, t0 + k)
        ended = None
        for k in range(150):
            t = t0 + 10 + k
            if case == "back":  # 20 s in, 3 tiles a second, then back the way it came
                j = k if k < 20 else 40 - k
                pos, near, state = {"x": 140 - 3 * j, "y": 114 - 3.5 * j}, 120 - 4 * j, "moving"
            else:  # 10 s in, then it sits at its target
                j = min(k, 10)
                pos, near = {"x": 140 - 3 * j, "y": 114 - 3.5 * j}, 120 - 4 * j
                state = "gathering" if case == "gathering" else "moving"
            pub = d.step({"agents": team, "alerts": [], "incoming": [live_row(g, 7, pos, state, near)]}, t)
            on = (pub.get("main") or {}).get("incoming", "")
            if k == 5:
                assert on.startswith("Incoming · 37"), pub.get("main")
            if k > 5 and not on and ended is None:
                ended = k
        if case == "back":  # closest 40 at k=20; 40 tiles farther at k=30
            assert ended is not None and 30 <= ended <= 34, ended
        elif case == "still":  # still from k=10; 0.8 x 12 s later (CG1: it was 45 s, and the 09:53 group stood 44 s)
            assert ended is not None and 19 <= ended <= 24, ended
        else:  # a gathering group is kept (until incoming_max, 240 s)
            assert ended is None, ended
        assert d.incoming is None or case == "gathering"
    print("turned back or stopped: ok (turned back: ends 40 tiles past its closest approach; stopped: ends after "
          "about 10-12 s still; a gathering group is kept)")


def calibrated():
    """(CG1) shift62-63: 176 groups in 6.3 h, every followed one stopped or turned back short, 3 real losses on Nauvis."""
    th = Threats()
    for g in RECORDED[:6]:
        th.learn_group(g, centre=CENTRE)
    g = dict(RECORDED[3], target={"x": -540, "y": 329})
    base, parts = th.score_group(g, centre=CENTRE)
    assert "routine" not in parts, parts  # under outcomes_min ended groups: no calibration yet
    # groups tracked to their end: 10 that came and stood off (no contact, nothing lost)
    t = 1000.0
    for k in range(10):
        th.observe([{"id": k, "surface": "nauvis", "position": {"x": -500, "y": 300}, "target": {"x": -540, "y": 329}, "contact": False}], [], t)
        t += 30
    th.observe([], [], t + 61)
    assert len(th.h["outcomes"]) == 10 and th.harm_share() == 0, th.h["outcomes"]
    s2, parts2 = th.score_group(g, centre=CENTRE)
    assert parts2["routine"] == -1.2 and abs(s2 - (base - 1.2)) < 1e-9, parts2
    # one that reached our buildings and destroyed 3 turrets near its target: counted once, harm share rises
    t += 100
    rows = [{"id": 50, "surface": "nauvis", "position": {"x": -530, "y": 320}, "target": {"x": -540, "y": 329}, "contact": True}]
    loss = [{"key": "loss:nauvis:#9:1", "surface": "nauvis", "x": -545, "y": 331, "pieces": 3, "t": t + 5}]
    th.observe(rows, [], t)
    th.observe(rows, loss, t + 5)
    th.observe([], loss, t + 10)  # the same loss again: not counted twice
    th.observe([], [{"key": "far", "surface": "nauvis", "x": 400, "y": 400, "pieces": 9, "t": t + 12}], t + 12)
    th.observe([], [], t + 80)
    assert th.h["outcomes"][-1][1:] == [1, 3], th.h["outcomes"][-1]
    assert abs(th.harm_share() - 1 / 11) < 1e-9
    assert th.score_group(g, centre=CENTRE)[1]["routine"] == round(-1.2 * 10 / 11, 3)
    # cover where it is aimed, inside the base map's box: no drawn turret reaching (-540, 329), one, several; outside the
    # box (the 09:53 group stood about 190 tiles west of the map's edge) nothing is said
    box = {"x0": -600, "y0": 0, "x1": 0, "y1": 600}
    assert th.score_group(g, centre=CENTRE, turrets=[[-700, 0, 30]], box=box)[1]["no_cover"] == 1.0
    assert "no_cover" not in th.score_group(g, centre=CENTRE, turrets=[[-560, 340, 24]], box=box)[1]
    assert "no_cover" not in th.score_group(g, centre=CENTRE, turrets=[], box={"x0": -352, "y0": -608, "x1": 624, "y1": 592})[1]
    assert "no_cover" not in th.score_group(g, centre=CENTRE, turrets=[], box=None)[1]
    assert "no_cover" not in th.score_group(dict(g, target=None), centre=CENTRE, turrets=[], box=box)[1]  # nowhere to aim
    assert th.score_group(dict(g, target=None, nearest={"x": -300, "y": 300}), centre=CENTRE, turrets=[], box=box)[1]["no_cover"] == 1.0
    print(f"calibrated: ok (routine {parts2['routine']} after 10 groups held off; a damaging one counted once; "
          "no turret reaching its target inside the map +1.0)")


if __name__ == "__main__":
    scores()
    budget()
    director()
    turned_back_or_stopped()
    live_and_model()
    calibrated()
