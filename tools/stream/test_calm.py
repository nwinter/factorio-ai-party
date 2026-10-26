#!/usr/bin/env python3
"""Calmer cuts and staying on a fight (onecam.py; operator 16:56: a cut about every 30 s live; a viewer at 16:45:
"dont move 'on air' away from agents under attack"): python3 tools/stream/test_calm.py

1. Defaults: still_cut 30, still_min 60, plan_after 20, attack_hold 30.
2. A fight shot (a loss or an attack where nobody is) holds past attack_hold while its fight is still reported, and
   goes back to the story once it has been quiet fight_quiet (15 s).
3. The agent on air shooting or under attack: no stand-still, look-ahead or beat cut away from it, however still.
4. An agent under attack is a strong pick (fight_boost).
5. The base map never within map_gap (30 s) of another cut, nor while a fight is reported anywhere.
"""
import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from test_onecam import agent, world  # noqa: E402
from test_mapcam import BASEMAP  # noqa: E402


def snap(agents, alerts=(), fights=(), basemap=None):
    return {"agents": agents, "alerts": list(alerts), "fights": list(fights), "basemap": basemap}


def onair(d):
    return ((d.public().get("main") or {}).get("agents") or [None])[0]


def defaults():
    d, _ = world()
    assert (d.cfg["still_cut"], d.cfg["still_min"], d.cfg["plan_after"], d.cfg["attack_hold"]) == (30, 60, 20, 30), d.cfg


def fight_holds():
    d, _ = world()
    team = [agent("luna", 0, 0, 5), agent("sol", 300, 0, 2)]
    t = 1000
    for k in range(0, 5):
        d.step(snap(team), t + k)
    assert onair(d) == "luna"
    pos = {"x": -128, "y": 38, "extent": 20}
    loss = {"id": "l1", "kind": "loss", "t": t + 10, "text": "26 lost near (-128, 38): 14 transport belt, 7 inserter",
            "position": pos, "key": "loss:-128,38"}
    attack = lambda now, last: {"key": "area:-128,38", "kind": "attack", "last": last, "position": pos}  # noqa: E731
    d.step(snap(team, [loss], [attack(t + 10, t + 10)]), t + 10)
    for k in range(11, 14):
        d.step(snap(team, fights=[attack(t + k, t + k)]), t + k)
    assert d.public(t + 13)["main"].get("attack") and d.public(t + 13)["main"]["agents"] == []
    # the fight goes on until t + 80: the shot stays on it, well past attack_hold (30 s)
    for k in range(14, 80):
        d.step(snap(team, fights=[attack(t + k, t + k)]), t + k)
        assert (d.public(t + k).get("main") or {}).get("agents") == [], (k, d.cuts)
    # quiet from t + 80: back to the story about fight_quiet later
    back = None
    for k in range(80, 120):
        d.step(snap(team, fights=[attack(t + k, t + 79)]), t + k)
        if onair(d) == "luna":
            back = k
            break
    assert back is not None and 80 + d.cfg["fight_quiet"] - 1 <= back <= 80 + d.cfg["fight_quiet"] + 3, (back, d.cuts)
    assert d.cuts[-1][2] == "back to luna", d.cuts


def losses_keep_it():
    """shift01 16:44: the loss alert near (-85, -110) re-reported, new losses every few seconds (4, 8, ... 31 pieces):
    the shot stays while losses keep coming, and leaves fight_quiet after the last one (not after attack_hold)."""
    d, _ = world()
    team = [agent("grok", 0, 0, 5), agent("sol", 300, 0, 2)]
    t = 1000
    for k in range(0, 5):
        d.step(snap(team), t + k)
    pos = {"x": -85, "y": -110, "extent": 16}
    alert = {"id": "l1", "kind": "loss", "t": t + 10, "text": "4 lost near (-85, -110): 4 pipe (by small biters)",
             "position": pos, "key": "loss:-85,-110"}
    losses = [t + 10, t + 18, t + 25, t + 31, t + 40, t + 47, t + 55]
    entry = lambda now: {"key": "loss:-85,-110", "kind": "loss", "last": now, "position": pos,  # noqa: E731
                         "losses": [x for x in losses if x <= now], "text": alert["text"]}  # (as model.py reports it)
    d.step(snap(team, [alert], [entry(t + 10)]), t + 10)
    back, away = None, None
    for k in range(11, 120):
        d.step(snap(team, fights=[entry(t + k)]), t + k)
        if away is None and onair(d) != "grok":
            away = k  # the cut to the loss
        elif away is not None and onair(d) == "grok":
            back = k
            break
    assert away is not None and away <= 13, (away, d.cuts)
    # (batch245: a real loss is a battle, held battle_loss_after past its last loss)
    assert back is not None and 55 + d.cfg["fight_quiet"] - 1 <= back <= 55 + d.cfg["battle_loss_after"] + 3, (back, d.cuts)


def no_cut_from_a_fight():
    d, _ = world()
    luna = agent("luna", 0, 0, 9, activity="thinking", active=False)
    sol = agent("sol", 300, 0, 4, active="move_to")
    team = [luna, sol]
    for k in range(0, 5):
        d.step(snap(team), 1000 + k)
    assert onair(d) == "luna"
    luna["combat"] = True  # under attack, standing there
    for k in range(5, 400):
        sol["position"] = {"x": 300 + k, "y": 0}
        d.step(snap(team), 1000 + k)
        assert onair(d) == "luna", (k, d.cuts)
    s = d.scores(team, 1400)
    assert s["luna"] > s["sol"], s  # fight_boost


def map_spacing():
    d, _ = world(map_every=600, map_first=10_000)  # no map in the first minutes
    d.started = 0
    team = [agent("luna", 0, 0, 5), agent("sol", 300, 0, 2)]
    t = 1000
    for k in range(0, 5):
        d.step(snap(team, basemap=BASEMAP), t + k)
    assert d.cuts and not d.maps
    # a map is due now, and a cut has just happened (16:44:05 came 2 s after one)
    d.last_map = t - 600
    d.last_program_cut = t + 5
    for k in range(5, 34):
        d.step(snap(team, basemap=BASEMAP), t + k)
    assert not d.maps, d.maps  # inside map_gap
    # a fight reported somewhere: no map while it goes on, nor until it has been quiet fight_quiet
    d.last_program_cut = t + 34
    fight = {"key": "area:900,900", "kind": "attack", "last": t + 70, "position": {"x": 900, "y": 900}}
    for k in range(34, 140):  # (batch245: the fight is a battle, held battle_after past it, then back to the story)
        d.step(snap(team, fights=[dict(fight, last=t + k)] if k < 70 else [fight], basemap=BASEMAP), t + k)
        if d.maps:
            break
    assert d.maps and d.maps[0][0] >= t + 70 + d.cfg["fight_quiet"], d.maps


def main():
    defaults()
    fight_holds()
    losses_keep_it()
    no_cut_from_a_fight()
    map_spacing()
    print("calm: ok (60 s before a stand-still cut, 30 s still; a fight shot holds until 15 s quiet; no cut away from "
          "an agent in a fight; fighters score up; base map 30 s clear of cuts and fights)")


if __name__ == "__main__":
    main()
