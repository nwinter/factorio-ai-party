#!/usr/bin/env python3
"""One camera on air (onecam.py): python3 tools/stream/test_onecam.py

1. The subject on air holds at least 90 s whatever the scores do, and never pairs on air; the next subject is framed
   on a standby client (a jump) before the cut.
2. A stronger subject after the dwell, or a rotation after onair_max, cuts; a quiet hour cuts about every few minutes.
3. Urgent: a death or a real loss cuts within ready_s; an attack or one cheap building far away is a small inset for
   its length; near the subject on air it is only labelled.
4. A segment's shot cuts in and hands back when it ends.
5. snapshot["onair"]: the agent, and what it is doing (plan line, claim, action).
"""
import os, random, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from onecam import OneCam, onair_info  # noqa: E402

SLOTS = [{"slot": "main", "player": 3}, {"slot": "cam2", "player": 4}, {"slot": "cam3", "player": 5}]


def agent(name, x, y, interest=1.0, activity="acting", active="walk"):
    return {"name": name, "display_name": name.title(), "alive": True, "position": {"x": x, "y": y},
            "activity": activity, "active": active, "interest": interest, "seen": True}


def world(**cfg):
    sent = []
    # the trio (test_trio.py) off unless asked: these rules are one camera's
    d = OneCam(SLOTS, lambda body: sent.append(body) or {"ok": True}, None, **dict({"trio": False}, **cfg))
    d.started = 0  # the airtime bonus counts from here (the tests' clock)
    return d, sent


def snap(agents, alerts=()):
    return {"agents": agents, "alerts": list(alerts)}


def onair_agent(d):
    return (d.public().get("main") or {}).get("agents")


def dwell_and_standby():
    d, sent = world()
    team = [agent("luna", 0, 0, 5), agent("sol", 10, 0, 1), agent("astra", 300, 0, 1)]
    t = 1000
    d.step(snap(team), t)
    assert d.public() == {} and d.pending is None
    framed = [b for b in sent if b["player"] == 4]
    assert framed and framed[-1]["follow"] == "luna" and framed[-1]["smooth"] is False, sent  # standby jumps there
    d.step(snap(team), t + 1)
    assert d.onair == "main" and not d.cuts
    d.step(snap(team), t + 2)
    assert d.onair == "cam2" and onair_agent(d) == ["luna"] and d.cuts[-1][2] == "initial", d.cuts
    # sol is 10 tiles from luna: never paired on air; astra suddenly far more interesting: no cut inside 90 s
    team[2]["interest"] = 40
    for k in range(3, 90):
        d.step(snap(team), t + k)
        assert onair_agent(d) == ["luna"], (k, d.public())
    nxt = d.state["main"]
    assert nxt["subject"] == "astra", nxt  # the next subject is already framed on the standby
    for k in range(90, 95):
        d.step(snap(team), t + k)
    assert onair_agent(d) == ["astra"] and d.onair == "main" and len(d.cuts) == 2, d.cuts
    assert all(not b.get("release") for b in sent)


def quiet_hour():
    """Scores wander like a calm stream: cuts every few minutes, none under 90 s apart."""
    d, _ = world()
    rnd = random.Random(7)
    team = [agent(n, i * 100, 0, 1 + rnd.random()) for i, n in enumerate(["a", "b", "c", "d", "e", "f", "g", "h", "i"])]
    t0 = 5000
    for k in range(3600):
        if k % 20 == 0:
            for a in team:
                a["interest"] = max(0.2, a["interest"] + rnd.uniform(-1, 1))
        d.step(snap(team), t0 + k)
    gaps = [b[0] - a[0] for a, b in zip(d.cuts, d.cuts[1:])]
    assert gaps and min(gaps) >= 90, gaps
    assert 8 <= len(d.cuts) <= 40, len(d.cuts)  # roughly one story every 1.5 to 4 minutes
    assert sum(gaps) / len(gaps) >= 120, sum(gaps) / len(gaps)


def urgent():
    d, sent = world()
    team = [agent("luna", 0, 0, 5), agent("sol", 400, 0, 1), agent("astra", -400, 0, 1)]
    t = 1000
    for k in range(3):
        d.step(snap(team), t + k)
    assert onair_agent(d) == ["luna"]
    # an attack far away with nothing lost yet: its toast only, no inset and no cut
    att = {"id": "a1", "kind": "attack", "t": t + 10, "text": "Base under attack near (200, 200): gun turret",
           "position": {"x": 200, "y": 200, "extent": 32}, "key": "area:200,200"}
    d.step(snap(team, [att]), t + 10)
    assert onair_agent(d) == ["luna"] and "inset" not in d.public(t + 10) and d.last_attack_cut < t + 10
    # one cheap building lost far away: an inset for 20 s, the story on air stays (a running segment too)
    pipe = {"id": "l1", "kind": "loss", "t": t + 80, "text": "1 lost near (200, 200): 1 pipe (by small biters)",
            "position": {"x": 200, "y": 200, "extent": 16}, "key": "loss:200,200"}
    d.step(snap(team, [pipe]), t + 80)
    pub = d.public(t + 80)
    assert pub["inset"]["attack"] == pipe["text"] and onair_agent(d) == ["luna"] and d.program()["inset"], pub
    assert d.last_attack_cut < t + 80
    for k in range(81, 101):
        d.step(snap(team), t + k)
    assert "inset" not in d.public(t + 101) and d.program()["inset"] is None
    # a real loss (after the 45 s alert spacing): framed on the free standby, cut within ready_s
    loss = {"id": "l2", "kind": "loss", "t": t + 130, "text": "26 lost near (-128, 38): 14 transport belt, 7 inserter",
            "position": {"x": -128, "y": 38, "extent": 20}, "key": "loss:-128,38"}
    on = d.onair
    d.step(snap(team, [loss]), t + 130)
    assert d.pending and d.onair == on and d.last_attack_cut == t + 130
    d.step(snap(team), t + 131)
    d.step(snap(team), t + 132)
    pub = d.public(t + 132)
    assert d.onair != on and pub["main"]["attack"] == loss["text"] and pub["main"]["agents"] == [], pub
    for k in range(133, 175):  # attack_hold 30 s (no fight reported around it: no longer)
        d.step(snap(team), t + k)
    assert onair_agent(d) == ["luna"] and d.cuts[-1][2] == "back to luna", d.cuts  # the story it interrupted
    # another real loss inside 3 minutes: an inset this time
    loss2 = {"id": "l3", "kind": "loss", "t": t + 200, "text": "6 lost near (300, 300): 2 gun turret, 4 stone wall",
             "position": {"x": 300, "y": 300, "extent": 20}, "key": "loss:300,300"}
    d.step(snap(team, [loss2]), t + 200)
    assert d.pending is None and d.public(t + 200)["inset"]["attack"] == loss2["text"]
    # a death: cut at once (no spacing)
    team[1]["alive"] = True
    death = {"id": "d1", "kind": "death", "t": t + 205, "text": "Sol died", "agent": "sol"}
    d.step(snap(team, [death]), t + 205)
    d.step(snap(team), t + 207)
    assert d.public(t + 207)["main"]["alert"] == "death", d.public(t + 207)
    # what counts as a minor loss (an inset) and a real one (a cut)
    from onecam import minor_loss
    assert minor_loss("2 lost near (10, -66): 2 transport belt (by medium spitters)")
    assert minor_loss("3 lost near (38, 84): 2 pipe to ground, 1 pipe (by flamethrower turrets)")
    assert minor_loss("2 lost near (-95, -30): 2 wooden chest (by flamethrower turrets)")
    assert not minor_loss("1 lost near (-101, -7): 1 gun turret (by big spitters)")
    assert not minor_loss("1 lost near (-325, 64): 1 character (by medium worm turrets)")
    assert not minor_loss("5 lost near (10, -64): 3 transport belt, 2 lab (by medium spitters)")
    assert not minor_loss("4 lost near (10, -68): 4 transport belt (by medium spitters)")
    # an attack on the agent on air: labelled, no inset
    d2, _ = world()
    for k in range(3):
        d2.step(snap(team), t + k)
    near = {"id": "a2", "kind": "attack", "t": t + 5, "text": "Luna is under attack", "agent": "luna",
            "position": {"x": 0, "y": 0}}
    d2.step(snap(team, [near]), t + 5)
    assert d2.inset is None and d2.public(t + 5)["main"]["attack"] == "Luna is under attack"


def segment_shot():
    d, _ = world()
    team = [agent("luna", 0, 0, 5), agent("sol", 400, 0, 1)]
    t = 1000
    for k in range(3):
        d.step(snap(team), t + k)
    seg = {"id": "seg-1", "follow": "sol", "zoom": 0.9, "until": t + 40, "label": "Spotlight: Sol"}
    d.step(snap(team), t + 10, seg)
    d.step(snap(team), t + 12, seg)
    pub = d.public(t + 12)
    assert pub["main"]["agents"] == ["sol"] and pub["main"]["segment"] == "Spotlight: Sol", pub
    for k in range(13, 45):
        d.step(snap(team), t + k, seg if k < 40 else None)
    assert onair_agent(d) == ["luna"], d.public()  # back to the story


def onair_label():
    s = {"agents": [agent("luna", 0, 0)], "board": {"plan": {"doing": [{"agent": "luna", "name": "Luna",
                                                                        "text": "fixing the north wall"}]},
                                                   "claims": [{"agent": "luna", "title": "ammo to the wall"}]}}
    cams = {"main": {"agents": ["luna"], "since": 5, "client": "cam2"}}
    info = onair_info(s, cams)
    assert info["agent"] == "luna" and info["display_name"] == "Luna" and info["doing"] == "fixing the north wall", info
    s["board"]["plan"] = None
    assert onair_info(s, cams)["doing"] == "ammo to the wall"
    s["board"] = {}
    s["agents"][0].update(action="build_blueprint at (3, 4)")
    assert onair_info(s, cams)["doing"] == "build blueprint at (3, 4)"
    assert onair_info(s, {"main": {"agents": [], "attack": "Base under attack"}})["agent"] is None


def hosts():
    """The hosts' regular beats get the agent on air first (caster.facts_for: on_air, busy_agents order)."""
    import caster
    team = [dict(agent("luna", 0, 0), action="build_blueprint at (3, 4)"), dict(agent("sol", 9, 9), action="mine coal")]
    s = {"agents": team, "onair": {"agent": "sol", "display_name": "Sol", "doing": "fixing the north wall"}}
    f = caster.facts_for({"kind": "lull", "angle": "explain", "t": 0}, s)
    assert f["on_air"]["name"] == "Sol" and f["on_air"]["shown_as"] == "fixing the north wall", f.get("on_air")
    assert [b["name"] for b in f["busy_agents"]][:1] == ["Sol"], f["busy_agents"]
    assert "on_air" not in caster.facts_for({"kind": "lull", "angle": "explain", "t": 0}, dict(s, onair=None))
    assert "on_air" not in caster.facts_for({"kind": "attack", "text": "Base under attack", "t": 0}, s)


def main():
    hosts()
    dwell_and_standby()
    quiet_hour()
    urgent()
    segment_shot()
    onair_label()
    print("onecam: ok (90 s dwell, standby framed before the cut, no pairs on air, urgent cuts, insets, segments, "
          "on-air label)")


if __name__ == "__main__":
    main()
