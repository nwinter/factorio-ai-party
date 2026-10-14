#!/usr/bin/env python3
"""Under attack only when hit (viewer Joonazan, 13:36 on 2026-10-14: "I'm pretty sure biters are not hitting anyone on
Gleba. What's going on with all the incorrect attack reports?"; operator 13:40): python3 tools/stream/test_attackflag.py

model.combat_state reads status combat (target, fired_tick, kills_10s) and hurt (the last hit on the character or its
vehicle, eng/attackflag's runtime):
1. A guard (shoot auto, nothing in range): no fight, no alert, "on guard", action "guard" (no fight kind for the
   director), no interest bump poll after poll. Sol by the egg breeders on Gleba, 13:00-13:40.
2. Fighting (a target in range, a shot in the last 10 s, a kill): a fight of kind "fight" ("Sol is fighting a small
   biter"), an alert of kind "fight" (a toast, an info line for the hosts; no urgent cut), a smaller bump.
3. Hit in the last 15 s: "Sol is under attack by a small biter" (the attack alert, the director's urgent rules, the
   hosts' attack event); 16 s later no more.
4. A runtime from before these fields: a shoot at a position fights, an auto shoot guards; the mock's True is a hit.
5. The director: a guard makes no attack inset or cut; a hit does.
6. An incoming group's "aimed at an agent" counts agents on the group's surface only (Sol on Gleba at (46, 51) made
   Nauvis groups heading for (47, 34) count).
"""
import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from model import Model, combat_state  # noqa: E402
from test_onecam import world  # noqa: E402
from threats import Threats  # noqa: E402

TICK = 9_300_000
GUARD = {"auto": True, "radius": 24, "until_tick": TICK + 400, "kills_10s": 0}


def model_with(sol_row, tick=TICK):
    m = Model({"agents": {"sol": {"display_name": "Sol"}}})
    m.ingest({"tick": tick, "agents": [dict({"name": "sol", "display_name": "Sol", "alive": True, "surface": "gleba",
                                             "position": {"x": 46, "y": 51}}, **sol_row)]}, now=1000)
    return m


def sol_of(snap):
    return next(a for a in snap["agents"] if a["name"] == "sol")


def classify():
    assert combat_state(GUARD, None, TICK) == ("guard", {})
    assert combat_state(dict(GUARD, fired_tick=TICK - 3600), None, TICK)[0] == "guard"  # fired a minute ago
    assert combat_state(dict(GUARD, fired_tick=TICK - 300), None, TICK)[0] == "fighting"
    assert combat_state(dict(GUARD, kills_10s=1), None, TICK)[0] == "fighting"
    st = combat_state(dict(GUARD, target={"name": "small-wriggler-pentapod", "position": {"x": 60, "y": 50}}), None, TICK)
    assert st == ("fighting", {"target": "small-wriggler-pentapod", "position": {"x": 60, "y": 50}}), st
    hurt = {"tick": TICK - 600, "by": "small-biter", "damage": 12}
    assert combat_state(GUARD, hurt, TICK) == ("hurt", {"by": "small-biter", "what": None})
    assert combat_state(False, hurt, TICK)[0] == "hurt"  # hit with no shoot running: still under attack
    assert combat_state(GUARD, dict(hurt, tick=TICK - 16 * 60), TICK)[0] == "guard"  # 16 s ago: over
    assert combat_state(GUARD, dict(hurt, by="acid"), TICK)[1]["by"] is None  # a damage type names no attacker
    assert combat_state(dict(GUARD, hurt=hurt), None, TICK)[0] == "hurt"  # combat.hurt alone (status combat)
    # a runtime from before eng/attackflag: no kills_10s, no target, no hurt
    assert combat_state({"auto": True, "until_tick": 5}, None, TICK)[0] == "guard"
    assert combat_state({"position": {"x": 1, "y": 1}, "until_tick": 5}, None, TICK)[0] == "fighting"
    assert combat_state(True, None, TICK)[0] == "hurt" and combat_state(False, None, TICK)[0] is None
    print("classify: ok")


def model():
    # 1. a guard: nothing on stream, poll after poll
    m = model_with({"active": "shoot", "combat": GUARD, "auto": {"name": "guard", "step": 1, "steps": 1}})
    interest = None
    for k in range(5):
        m.ingest({"tick": TICK + k * 120, "agents": [{"name": "sol", "alive": True, "active": "shoot", "combat": GUARD,
                                                      "auto": {"name": "guard"}}]}, now=1000 + k * 2)
        s = sol_of(m.snapshot(1000 + k * 2))
        interest = s["interest"] if interest is None else interest
    snap = m.snapshot(1010)
    s = sol_of(snap)
    assert not snap["alerts"] and not snap["fights"], (snap["alerts"], snap["fights"])
    assert s["combat"] is False and s["combat_state"] == "guard" and s["action"] == "on guard" and s["active"] == "guard", s
    # interest stays small: a guard weighs 0.3 (a shoot weighed 6 on every new read)
    assert s["plan"] is None and interest < 1 and s["interest"] < 1, s
    # 2. a pentapod comes in range: a fight of its own, a toast, no attack
    m.ingest({"tick": TICK + 700, "agents": [{"name": "sol", "alive": True, "active": "shoot", "combat": dict(
        GUARD, target={"name": "small-wriggler-pentapod", "position": {"x": 60, "y": 50}}, fired_tick=TICK + 700)}]}, now=1012)
    snap = m.snapshot(1012)
    s = sol_of(snap)
    assert [(a["kind"], a["text"]) for a in snap["alerts"]] == [("fight", "Sol is fighting a small wriggler pentapod")], snap["alerts"]
    assert [(f["kind"], f["key"]) for f in snap["fights"]] == [("fight", "fight:sol")] and s["combat"] is True, snap["fights"]
    assert s["combat_state"] == "fighting" and s["action"] == "fighting" and s["active"] == "shoot", s
    # 3. hit: under attack, by what
    hurt = {"tick": TICK + 760, "ago_s": 0, "by": "small-wriggler-pentapod", "damage": 20}
    m.ingest({"tick": TICK + 770, "agents": [{"name": "sol", "alive": True, "active": "shoot", "combat": GUARD, "hurt": hurt}]}, now=1014)
    snap = m.snapshot(1014)
    att = [a for a in snap["alerts"] if a["kind"] == "attack"]
    assert [a["text"] for a in att] == ["Sol is under attack by a small wriggler pentapod"], snap["alerts"]
    assert any(f["kind"] == "attack" and f["key"] == "attack:sol" for f in snap["fights"])
    # ... 16 s after the hit (the status read again): no longer
    m.ingest({"tick": TICK + 760 + 16 * 60, "agents": [{"name": "sol", "alive": True, "active": "shoot", "combat": GUARD,
                                                         "hurt": hurt}]}, now=1030)
    s = sol_of(m.snapshot(1030))
    assert s["combat_state"] == "guard" and s["combat"] is False, s
    print("model: ok")


def director():
    """The director's urgent rules come from the alerts: a guard gives none, a hit one."""
    d, sent = world()
    t = 1000.0
    m = model_with({"active": "shoot", "combat": GUARD})
    for k in range(3):
        snap = m.snapshot(t + k)
        snap["agents"].append({"name": "astra", "display_name": "Astra", "alive": True, "position": {"x": 0, "y": 0},
                               "activity": "acting", "active": "mine", "interest": 3, "seen": True})
        d.step(snap, t + k)
    reasons = [c[2] for c in d.cuts]
    assert not any("under attack" in str(r) for r in reasons) and d.inset is None and not d.last_attack_alert, reasons
    m.ingest({"tick": TICK + 60, "agents": [{"name": "sol", "alive": True, "active": "shoot", "combat": GUARD,
                                             "hurt": {"tick": TICK + 30, "by": "small-biter"}}]}, now=t + 5)
    snap = m.snapshot(t + 5)
    snap["agents"].append({"name": "astra", "display_name": "Astra", "alive": True, "position": {"x": 0, "y": 0},
                           "activity": "acting", "active": "mine", "interest": 3, "seen": True})
    d.step(snap, t + 5)
    assert d.last_attack_alert and "Sol is under attack" in d.last_attack_alert.get("text", ""), d.last_attack_alert
    print("director: ok")


def groups():
    th = Threats()
    sol_gleba = {"name": "sol", "surface": "gleba", "position": {"x": 46, "y": 51}}
    sol_nauvis = dict(sol_gleba, surface="nauvis")
    g = {"size": 20, "kinds": "20 big-biter", "surface": "nauvis", "position": {"x": 200, "y": 40}, "target": {"x": 47, "y": 34}}
    d, _ = world()
    # onecam's call: agents on the group's surface only
    from director import surface_of
    near = [a for a in (sol_gleba,) if surface_of(a) == (g.get("surface") or "nauvis")]
    assert "agent" not in th.score_group(g, agents=near)[1]
    near = [a for a in (sol_nauvis,) if surface_of(a) == (g.get("surface") or "nauvis")]
    assert "agent" in th.score_group(g, agents=near)[1]
    src = open(os.path.join(HERE, "onecam.py")).read()
    assert "agents=near" in src and "surface_of(a) == (g.get(\"surface\") or \"nauvis\")" in src
    print("groups: ok")


if __name__ == "__main__":
    classify()
    model()
    director()
    groups()
    print("test_attackflag: ok")
