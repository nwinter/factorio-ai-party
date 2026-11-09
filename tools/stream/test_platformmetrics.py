#!/usr/bin/env python3
"""Attempt telemetry: bounded reads, leg isolation, rates, missing data and DOM updates; no live services."""
import copy
from pathlib import Path
import subprocess
import sys

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from platformmetrics import Metrics, card, selected, view_area
from harness import Harness, OPERATOR_READS


def snapshot():
    return {"featured_platform": {"name": "Resolute", "status": "active"},
            "onair": {"platform": {"name": "Resolute"}},
            "space": {"platforms": [{"name": "Resolute", "route_ids": ["solar-system-edge", "shattered-planet"],
                "route": {"pct": 20}, "view": {"surface": "platform-1"}}]},
            "cameras": {"main": {"ship": {"name": "Resolute"}, "frame": {
                "surface": "platform-1", "position": {"x": 0, "y": -50}, "zoom": .5, "frac": .8}}}}


def raw():
    return {"platform": "Resolute", "surface": "platform-1", "tick": 10000, "speed_kms": 100, "paused": False,
            "leg": {"from": "solar-system-edge", "to": "shattered-planet", "connection": "deep", "back": False,
                    "start_tick": 5000, "km": 4000000, "left_km": 3200000, "flown_km": 800000, "pct": 20},
            "tallies": {"units": [7], "kills": 100, "damage": 1000}, "hits_total": 40, "damage_total": 900,
            "ammo": [{"name": "rocket", "hub": 300, "turrets": 100, "made": 500, "used": 100}],
            "turrets": {"rocket-turret": {"count": 1, "empty": 0, "targeting": 1}},
            "fuel": {"thruster-fuel": 6000, "thruster-oxidizer": 9000}, "repair_packs": 30,
            "asteroids": {"small": 20, "medium": 5, "big": 3, "huge": 1}, "losses_leg": 0}


def main():
    s = snapshot()
    assert selected(s)["name"] == "Resolute"
    assert view_area(s, selected(s)) == [[-48, -83.75], [48, -16.25]]
    s["onair"] = {"host": {"label": "Nick"}}
    assert selected(s) is None
    s = snapshot(); s["onair"] = {}; s["cameras"] = {}
    assert selected(s) is None
    s["featured_platform"]["status"] = "ended"
    assert selected(s) is None
    old, new = raw(), raw()
    new.update(tick=10600, hits_total=44, damage_total=930)
    new["tallies"].update(kills=110, damage=1600)
    new["ammo"][0].update(made=510, used=130)
    c = card(new, old, 20)
    assert c["kills_min"] == 30 and c["damage_dealt_min"] == 1800 and c["hits_min"] == 12
    assert c["damage_taken"] == 30 and c["eta_wall_s"] == 64000  # 30 UPS, not 60
    assert c["ammo"][0]["made_min"] == 30 and c["ammo"][0]["used_min"] == 90
    assert c["ammo"][0]["net_min"] == -60 and c["ammo"][0]["buffer_min"] == 6.7
    assert "eta_wall_s" not in card(new, None, 20)
    assert "eta_wall_s" not in card(dict(new, platform_paused=True), old, 20)
    assert "hits_min" not in card(dict(new, at="shattered-planet"), old, 20)
    for change in ({"paused": True}, {"tick": 9999}, {"tick": 10000}):
        assert "eta_wall_s" not in card(dict(new, **change), old, 20)
    for key, value in (("from", "aquilo"), ("back", True), ("start_tick", 9000), ("connection", "different")):
        changed = copy.deepcopy(new); changed["leg"][key] = value
        assert "kills_min" not in card(changed, old, 20)
    changed = copy.deepcopy(new); changed["leg"] = None; changed["at"] = "shattered-planet"
    assert "hits_min" not in card(changed, old, 20)
    changed = copy.deepcopy(new); changed["tallies"] = {"units": [8], "kills": 999, "damage": 999}
    assert "kills_min" not in card(changed, old, 20)
    changed = copy.deepcopy(new); changed["tallies"]["kills"] = 0
    assert "kills_min" not in card(changed, old, 20)
    changed = copy.deepcopy(new); changed["ammo"][0].update(made=600, used=110)
    assert "buffer_min" not in card(changed, old, 20)["ammo"][0]
    changed["ammo"][0].update(hub=None, made=510, used=130)
    assert "buffer_min" not in card(changed, old, 20)["ammo"][0]
    assert card(new, old, 100)["kills_min"] == 6  # long camera cuts retain honest wall averages
    for seconds in (0, -1, float("inf"), float("nan")):
        assert "window_s" not in card(new, old, seconds)
    m, s, reads = Metrics(), snapshot(), []
    def read(action, args):
        reads.append((action, args)); return (old if len(reads) == 1 else new), new["tick"]
    first = m.step(s, read, 100)
    assert first["platform"] == "Resolute" and "kills_min" not in first and len(reads) == 1
    for t in range(101, 120):
        assert m.step(s, read, t)["tick"] == old["tick"]
    assert len(reads) == 1
    assert m.step(s, read, 120)["kills_min"] == 30 and len(reads) == 2
    pm, ps, paused_reads = copy.deepcopy(m), copy.deepcopy(s), []
    def pause_read(*args):
        paused_reads.append(args); return new, new["tick"]
    ps["paused"] = True
    paused = pm.step(ps, pause_read, 121)
    assert paused["paused"] and "kills_min" not in paused and "eta_wall_s" not in paused
    assert "net_min" not in paused["ammo"][0] and not paused_reads
    assert pm.step(ps, pause_read, 166) is None and not paused_reads  # cached facts expire; no paused polling
    ps["paused"] = False
    assert "kills_min" not in pm.step(ps, pause_read, 167) and len(paused_reads) == 1
    s["onair"] = {}; s["cameras"] = {}
    assert m.step(s, read, 121) is None
    s["cameras"] = snapshot()["cameras"]
    s["space"]["platforms"][0].update(route_ids=["shattered-planet", "solar-system-edge"])
    assert m.step(s, read, 122) is None and len(reads) == 2
    assert "kills_min" not in m.step(s, read, 140)
    def fail(*args):
        raise RuntimeError("private test failure")
    try:
        m.step(s, fail, 160)
        assert False
    except RuntimeError:
        pass
    assert m.step(s, read, 161) is None
    assert m.step(s, read, 180, supported=False) is None
    # Featured collection survives every kind of cut, but never publishes an offscreen card or camera area.
    for change in ({"cameras": {}}, {"cameras": {"main": {"frame": {"surface": None}}}},
                   {"hostview": True}, {"show": {"title": "Map"}}, {"replay": {"playing": True}},
                   {"cameras": {"main": {"map": "nauvis"}}}):
        collector, calls = Metrics(), []
        def collect(action, args):
            calls.append(args)
            return (old if len(calls) == 1 else new), new["tick"]
        collector.step(snapshot(), collect, 0)
        away = dict(snapshot(), **change)
        assert collector.step(away, collect, 20) is None
        assert len(calls) == 2 and calls[-1] == {"platform": "Resolute"}
        returned = collector.step(snapshot(), collect, 21)
        assert returned["kills_min"] == 30 and returned["ammo"][0]["made_min"] == 30
        assert "asteroids" not in returned and returned["eta_wall_s"] == 64000
        assert len(calls) == 2
    # Non-featured baselines survive gaps and other ships; the one-read budget is shared.
    collector, calls = Metrics(), []
    home = snapshot(); home["featured_platform"] = {}
    petrel = dict(home["space"]["platforms"][0], name="Petrel", view={"surface": "platform-2"})
    home["space"]["platforms"].append(petrel)
    def collect(action, args):
        calls.append(args)
        value = copy.deepcopy(old if len(calls) == 1 else new)
        value["platform"] = args["platform"]
        return value, value["tick"]
    collector.step(home, collect, 0)
    away = dict(home, cameras={})
    assert collector.step(away, collect, 20) is None and len(calls) == 1
    other = dict(home, cameras={"main": {"ship": {"name": "Petrel"}}})
    assert "kills_min" not in collector.step(other, collect, 21)
    assert collector.step(home, collect, 22)["platform"] == "Resolute" and len(calls) == 2
    assert collector.step(home, collect, 60)["kills_min"] == 10
    # Active featured target wins even if another ship is on camera; never add a second read.
    active = copy.deepcopy(other); active["featured_platform"] = snapshot()["featured_platform"]
    collector.step(active, collect, 80)
    assert calls[-1]["platform"] == "Resolute" and len(calls) == 4
    # Observe offscreen route changes and global pauses, including an out-and-back route between reads.
    for pause in (False, True):
        collector, reset_reads = Metrics(), []
        def reset_read(action, args):
            reset_reads.append(args)
            return (old if len(reset_reads) == 1 else new), new["tick"]
        collector.step(home, reset_read, 0)
        changed = copy.deepcopy(away)
        if pause:
            changed["paused"] = True
        else:
            changed["space"]["platforms"][0]["route_ids"].reverse()
        assert collector.step(changed, reset_read, 10) is None
        assert "kills_min" not in collector.step(home, reset_read, 20)
        assert len(reset_reads) == 2
    assert "platform_metrics" in OPERATOR_READS
    h = object.__new__(Harness)
    sent = []
    h.command = lambda cmd: sent.append(cmd) or '{"ok":true,"tick":10,"result":{"platform":"Resolute"}}'
    assert h.operator_read("platform_metrics", {"platform": "Resolute"})[0]["platform"] == "Resolute"
    assert 'platform_metrics' in sent[0] and 'operator' in sent[0]
    subprocess.run(["node", str(HERE / "platformmetrics_dom_test.cjs")], check=True)
    print("platform metrics: selection, viewport, wall rates, ETA, leg/reset isolation, cap cadence, failures and real client allowlist ok")


if __name__ == "__main__":
    main()
