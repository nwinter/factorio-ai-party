#!/usr/bin/env python3
"""The camera cuts to a platform in danger (viewer joonazan, d15 10:45: "show the ship only when something happens, e.g.
ammo running dry"): python3 tools/stream/test_platdanger.py

- model.ammo_runout / platform_danger: the platforms read's ammo_rates line that runs out before the arrival; a hub hit
  in the last minute (status alerts' platform_hits) or buildings lost on the platform in the last 2 minutes (loss
  events naming it) -> fire, labelled "Wayfarer under fire: 3 buildings lost; hub hit, hub 62%"; else ammo -> "Wayfarer
  ammo for 2 min"; loss events re-reported every poll keep their time until the count grows;
- onecam maybe_danger: the whole-platform view, labelled with the reason, why "danger"; under fire it holds while hits
  continue (danger_hold after the latest), at most danger_max, then the story comes back; the same platform again
  only after danger_gap unless worse; ammo holds ammo_hold; it takes over a platform visit, never an operator follow or
  an urgent attack shot.
"""
import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import model  # noqa: E402
from test_onecam import agent, world  # noqa: E402
from test_platformcam import VIEW, plat, snap, team, main_row  # noqa: E402

AMMO = ["firearm-magazine: made 0/min, used 35/min over this leg nauvis->gleba (3m46s so far); hub 70, turrets 12; runs out in 2m05s at that rate, before the arrival at gleba in 75m00s",
        "piercing-rounds-magazine: made 54/min, used 35/min over this leg nauvis->gleba (3m46s so far); hub 751, turrets 194; at the arrival at gleba in 2m09s about 985 at that rate"]


def model_tests():
    assert model.ammo_runout(AMMO) == (125, "firearm-magazine")
    assert model.ammo_runout(AMMO[1:]) is None and model.ammo_runout(None) is None
    assert model.ammo_runout(["x: ...; runs out in 1h02m at that rate, before the arrival at aquilo in 2h"]) == (3720, "x")
    now, tick = 5000.0, 600000
    hits = {"platform": "Wayfarer", "hits": 40, "entities": "space-platform-hub 300, gun-turret 80", "last_tick": tick - 600}
    d = model.platform_danger("Wayfarer", hits, {"k": (3, now - 30)}, AMMO, tick, now, hub_pct=62)
    assert d["kind"] == "fire" and d["reason"] == "Wayfarer under fire: 3 buildings lost; hub hit, hub 62%" and d["last"] == now - 10, d
    assert d["level"] == 3038, d
    # the hub hit two minutes ago, losses five minutes ago: not under fire any more; the ammo is
    old = dict(hits, last_tick=tick - 7200)
    d = model.platform_danger("Wayfarer", old, {"k": (3, now - 300)}, AMMO, tick, now)
    assert d == {"kind": "ammo", "reason": "Wayfarer ammo for 3 min", "runs_out_s": 125, "ammo": "firearm-magazine", "level": -125}, d
    assert model.platform_danger("W", {"entities": "gun-turret 80", "last_tick": tick}, {}, None, tick, now) is None  # no hub hit
    assert model.platform_danger("W", None, {}, ["a: ...; runs out in 40s at that rate, before the arrival at x in 9m"], tick, now)["reason"] == "W ammo for under a minute"
    # loss events naming a platform: the time moves only when the count grows
    m = model.Model({"agents": {"sol": {}}})
    ev = {"kind": "loss", "text": "2 lost near (1, 2): gun turret", "key": "loss:platform-1:#7", "platform": "Wayfarer",
          "position": {"x": 1, "y": 2, "surface": "platform-1", "extent": 16}}
    m._ingest_event(dict(ev), 100.0)
    m._ingest_event(dict(ev), 130.0)
    assert m.platform_losses["Wayfarer"] == {"loss:platform-1:#7": (2, 100.0)}, m.platform_losses
    m._ingest_event(dict(ev, text="3 lost near (1, 2): gun turret"), 160.0)
    assert m.platform_losses["Wayfarer"]["loss:platform-1:#7"] == (3, 160.0)
    # the Space snapshot's card carries it (the director reads space.platforms)
    m.space = {"rockets": 0, "planets": ["nauvis"], "platforms": [{"name": "Wayfarer", "at": "nauvis->gleba 20%", "ammo_rates": AMMO, "view": VIEW}]}
    m.tick = 10000
    card = m.space_snapshot({}, 200.0)["platforms"][0]
    assert card["danger"]["kind"] == "fire" and card["danger"]["reason"] == "Wayfarer under fire: 3 buildings lost", card
    card = m.space_snapshot({}, 500.0)["platforms"][0]  # the losses are 340 s old: the ammo
    assert card["danger"]["reason"] == "Wayfarer ammo for 3 min", card


def danger_plat(name="Wayfarer", surface="platform-2", **danger):
    p = plat(name, view=dict(VIEW, surface=surface))
    if danger:
        p["danger"] = danger
    return p


def on(d, t):
    return (main_row(d, t).get("platform") or {})


def fire_tests():
    d, sent = world(map_every=0, platform_every=0)
    a, t = team(), 1000
    d.step(snap(a), t)
    # hits keep coming for 60 s: on the platform, labelled, held; then they stop and it ends danger_hold later
    k = 1
    while k < 200:
        hitting = k < 61
        last = t + min(k, 60)
        p = danger_plat(kind="fire", reason="Wayfarer under fire: 3 buildings lost", last=last, level=3000)
        d.step(snap(a, [p]), t + k)
        if k == 10:
            row = on(d, t + k)
            assert row.get("why") == "danger" and row.get("label") == "Wayfarer under fire: 3 buildings lost", main_row(d, t + k)
            assert main_row(d, t + k)["surface"] == "platform-2"
        if not hitting and on(d, t + k).get("why") != "danger":
            break
        k += 1
    assert 60 + d.cfg["danger_hold"] - 1 <= k <= 60 + d.cfg["danger_hold"] + d.cfg["ready_s"] + 3, k
    # the same danger again: not within danger_gap; worse: at once
    p = danger_plat(kind="fire", reason="Wayfarer under fire: 3 buildings lost", last=t + k, level=3000)
    for j in range(k, k + 10):
        d.step(snap(a, [p]), t + j)
    assert on(d, t + j).get("why") != "danger", main_row(d, t + j)
    worse = danger_plat(kind="fire", reason="Wayfarer under fire: 5 buildings lost", last=t + j + 1, level=5000)
    for j2 in range(j + 1, j + 12):
        worse["danger"]["last"] = t + j2
        d.step(snap(a, [worse]), t + j2)
    assert on(d, t + j2).get("label") == "Wayfarer under fire: 5 buildings lost", main_row(d, t + j2)
    # hits that never stop: at most danger_max
    start = j2
    for j3 in range(j2 + 1, j2 + 400):
        worse["danger"]["last"] = t + j3
        d.step(snap(a, [worse]), t + j3)
        if on(d, t + j3).get("why") != "danger":
            break
    assert j3 - start <= d.cfg["danger_max"] + d.cfg["ready_s"] + 3, j3 - start


def ammo_and_priority_tests():
    # ammo: a short shot with its reason
    d, _ = world(map_every=0, platform_every=0)
    a, t = team(), 1000
    p = danger_plat(kind="ammo", reason="Wayfarer ammo for 2 min", runs_out_s=125, level=-125)
    seen = None
    for k in range(0, 60):
        d.step(snap(a, [p]), t + k)
        if on(d, t + k).get("why") == "danger":
            seen = seen or k
        elif seen:
            break
    assert seen is not None and d.cfg["ammo_hold"] - 1 <= k - seen <= d.cfg["ammo_hold"] + 3, (seen, k)
    # an operator follow: no danger shot
    d, _ = world(map_every=0, platform_every=0)
    d.step(snap(a), t)
    d.set_follow("sol", t + 600, now=t)
    fire = danger_plat(kind="fire", reason="Wayfarer under fire: hub hit", last=t, level=10)
    for k in range(1, 30):
        fire["danger"]["last"] = t + k
        d.step(snap(a, [fire]), t + k)
        assert on(d, t + k).get("why") != "danger", main_row(d, t + k)
    # an urgent attack shot on air: the danger waits until it is over
    d, _ = world(map_every=0, platform_every=0)
    d.step(snap(a), t)
    for k in range(1, 4):
        d.step(snap(a), t + k)
    cur = d.state[d.onair]
    cur.update(subject="@attack", until=t + 30)
    for k in range(4, 25):
        fire["danger"]["last"] = t + k
        d.step(snap(a, [fire]), t + k)
        assert on(d, t + k).get("why") != "danger", (k, main_row(d, t + k))
    for k in range(25, 45):
        fire["danger"]["last"] = t + k
        d.step(snap(a, [fire]), t + k)
    assert on(d, t + 44).get("why") == "danger", main_row(d, t + 44)
    # a platform visit on air: the danger takes over
    d, _ = world(map_every=0)
    starling = plat()
    for k in range(0, 40):
        d.step(snap(a, [starling]), t + k)
        if on(d, t + k).get("why") == "visit":
            break
    assert on(d, t + k).get("why") == "visit", main_row(d, t + k)
    for k2 in range(k + 1, k + 10):
        fire["danger"]["last"] = t + k2
        d.step(snap(a, [starling, fire]), t + k2)
    assert on(d, t + k2).get("why") == "danger" and on(d, t + k2).get("name") == "Wayfarer", main_row(d, t + k2)


def main():
    model_tests()
    fire_tests()
    ammo_and_priority_tests()
    print("platform danger: ok (ammo run-out and hub hits and losses as danger facts; the whole-platform view labelled, held"
          " while hits continue up to danger_max, again only if worse; ammo shot; not over an operator follow or an urgent"
          " attack shot; over a visit)")


if __name__ == "__main__":
    main()
