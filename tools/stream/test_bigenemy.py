#!/usr/bin/env python3
"""Big enemies coming in, a follow that ends with its battle, and loss insets that must score (operator task
14:45; Nick 14:44: "The demolisher approaching should be good in a PIP camera ... Otherwise we are just watching Sol
for a while as it waits"; 14:47: "camera fixed on Sol for a while after fight is over"; 14:50: insets of "empty
fields"): python3 tools/stream/test_bigenemy.py

The timeline is Sol's round 2 (14:17-14:21): Sol on Vulcanus behind gun turrets at (-236, 68), a small demolisher
coming from ~300 tiles at ~2.5 tiles/s, the field killing it in ~5 s.

1. The inset follows the demolisher while it closes and the program is on Sol (an operator follow here), labelled
   "Small demolisher · N tiles from Sol's gun turrets", the distance updating, panning with it; gone at contact,
   when it turns away, or when the program is on something else; never for one far off (ETA over enemy_eta).
2. POST /follow {until_battle}: the follow ends follow_after_battle after the battle with Sol is over (not at its
   1200 s), and the follow file says so too (a restart keeps it short).
3. Loss insets pass the threat score: 1-3 pipes burned by our own flamers get their toast only.
4. live.py reads big_enemies_live from a runtime that lists it; model.py labels each one.
"""
import json, os, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from follow import FollowControl  # noqa: E402
from test_onecam import agent, world  # noqa: E402

V = "vulcanus"
TURRETS = {"x": -236, "y": 68, "name": "gun-turret"}


def demolisher(k, closing=True, d0=300.0, speed=2.5):
    d = max(0.0, d0 - speed * k) if closing else d0 + speed * k
    return {"id": 77, "name": "small-demolisher", "surface": V, "position": {"x": round(-236 - d, 1), "y": 68},
            "speed": speed, "closing": closing, "nearest": TURRETS, "nearest_distance": round(d),
            "eta_s": round(d / speed) if closing else None, "character": {"x": -240, "y": 70, "player": None},
            "character_distance": round(d - 4), "label": f"Small demolisher · {round(d)} tiles from Sol's gun turrets"}


def team():
    sol = agent("sol", -240, 70, 1)
    sol["surface"] = V
    return [sol, agent("astra", 0, 0, 6), agent("luna", 300, 0, 1)]


def snap(tm, big=(), fights=(), alerts=()):
    return {"agents": tm, "alerts": list(alerts), "fights": list(fights), "big_enemies": list(big)}


def inset_follows():
    d, sent = world(map_every=0, platform_every=0)
    tm, t = team(), 100000
    d.set_follow("sol", t + 1200, "Sol vs the Demolisher · round 2", "nick", t)
    for k in range(4):
        d.step(snap(tm), t + k)
    assert d.public(t + 3)["main"]["agents"] == ["sol"]
    # far off: 300 tiles at 2.5 tiles/s is 120 s away, under enemy_eta (180 s): the inset comes up
    d.step(snap(tm, [demolisher(0)]), t + 4)
    ins = d.public(t + 4).get("inset") or {}
    assert ins.get("enemy") == "Small demolisher · 300 tiles from Sol's gun turrets", ins
    assert d.public(t + 4)["main"]["agents"] == ["sol"]  # the story on air stays
    pans = 0
    for k in range(1, 40):
        n = len(sent)
        d.step(snap(tm, [demolisher(k)]), t + 4 + k)
        pans += any(b.get("smooth") and b.get("zoom") == 0.6 for b in sent[n:])
        assert d.inset and d.inset["why"] == "enemy", (k, d.inset)
    assert pans >= 15, pans  # (2.5 tiles/s; a pan once it has moved over 3 tiles)
    assert d.public(t + 43)["inset"]["enemy"] == "Small demolisher · 202 tiles from Sol's gun turrets"
    # it turns away: gone after enemy_away
    for k in range(40, 60):
        d.step(snap(tm, [demolisher(k - 40, closing=False, d0=202)]), t + 4 + k)
    assert not d.inset, d.inset
    # it comes back; contact: gone (the battle hold takes it from there)
    for k in range(60, 200):
        d.step(snap(tm, [demolisher(k - 60, d0=250)]), t + 4 + k)
        if (demolisher(k - 60, d0=250)["nearest_distance"]) <= 20:
            break
    d.step(snap(tm, [demolisher(k - 59, d0=250)]), t + 5 + k)
    assert not d.inset or d.inset.get("why") != "enemy", d.inset
    print(f"inset follows: ok ({pans} pans; turned away; contact)")


def inset_rules():
    # the program on Astra on Nauvis (nothing near the turrets on air): no inset
    d, _ = world(map_every=0, platform_every=0)
    tm, t = team(), 110000
    for k in range(4):
        d.step(snap(tm), t + k)
    assert d.public(t + 3)["main"]["agents"] == ["astra"]
    d.step(snap(tm, [demolisher(0)]), t + 4)
    assert not d.inset
    # Sol on air, the demolisher 600 tiles away (ETA 240 s, over enemy_eta): no inset yet
    d2, _ = world(map_every=0, platform_every=0)
    d2.set_follow("sol", t + 600, None, "nick", t)
    for k in range(4):
        d2.step(snap(tm), t + k)
    d2.step(snap(tm, [demolisher(0, d0=600)]), t + 4)
    assert not d2.inset
    d2.step(snap(tm, [demolisher(0, d0=400)]), t + 5)
    assert d2.inset and d2.inset["why"] == "enemy"
    # the follow ends; once the program has gone to Astra the inset goes too
    d2.set_follow(None, 0)
    for k in range(6, 160):
        d2.step(snap(tm, [demolisher(k - 6, d0=400, speed=1.0)]), t + k)
        if d2.public(t + k)["main"]["agents"] == ["astra"]:
            break
    d2.step(snap(tm, [demolisher(k - 5, d0=400, speed=1.0)]), t + k + 1)
    assert d2.public(t + k + 1)["main"]["agents"] == ["astra"] and (not d2.inset or d2.inset.get("why") != "enemy"), d2.inset
    print("inset rules: ok (not when the program is elsewhere; not too far; goes with the story)")


def follow_until_battle():
    path = os.path.join(tempfile.mkdtemp(), "director-follow.json")
    d, _ = world(map_every=0, platform_every=0)
    fc = FollowControl(d, path, [("sol", "Sol"), ("astra", "Astra")])
    tm, t = team(), 120000
    code, r = fc.request({"agent": "sol", "until_battle": True, "seconds": 1200, "label": "Sol vs the Demolisher"}, t)
    assert code == 200 and json.load(open(path))["until_battle"] is True, r
    for k in range(5):
        d.step(snap(tm), t + k)
        fc.sync(t + k)
    assert d.public(t + 4)["main"]["agents"] == ["sol"]
    # the battle: a demolisher loss at the turrets at +10 (15 turrets), Sol in combat for 5 s
    text = "16 lost near (-230, 78): 15 gun turret, 1 character (by small demolishers)"
    end = None
    for k in range(5, 200):
        tt = t + k
        tm[0]["combat"] = 10 <= k < 15
        fights = [{"key": "loss:-230,78", "kind": "loss", "text": text, "first": t + 10, "last": tt, "losses": [t + 10],
                   "position": {"x": -230, "y": 78, "surface": V, "extent": 16}}] if 10 <= k < 130 else []
        alerts = [{"id": "l1", "kind": "loss", "t": tt, "text": text, "key": "loss:-230,78",
                   "position": {"x": -230, "y": 78, "surface": V, "extent": 16}}] if k == 10 else []
        d.step(snap(tm, fights=fights, alerts=alerts), tt)
        fc.sync(tt)
        if d.battle is None and d.battles and end is None:
            end = tt
        if end and d.follow_info(tt) is None:
            break
    over = tt
    assert d.battles and end, d.battles
    assert 14 <= over - end <= 16, (end - t, over - t)  # follow_after_battle (15 s) after the battle
    assert json.load(open(path))["until"] <= end + 15.5, json.load(open(path))  # the file is short too
    print(f"follow until its battle: ok (battle over at +{end - t} s, the follow at +{over - t} s, not +1200 s)")


def loss_insets():
    d, _ = world(map_every=0, platform_every=0)
    tm, t = team(), 130000
    for k in range(4):
        d.step(snap(tm), t + k)
    burn = {"id": "f1", "kind": "loss", "t": t + 10, "text": "3 lost near (94, 87): 3 pipe (by friendly fire from flamethrower turrets)",
            "position": {"x": 94, "y": 87, "extent": 8}, "key": "loss:94,87"}
    d.step(snap(tm, alerts=[burn]), t + 10)
    assert not d.inset and not d.pending, d.inset
    raid = {"id": "r1", "kind": "loss", "t": t + 80, "text": "3 lost near (-124, -102): 3 stone wall (by big spitters)",
            "position": {"x": -124, "y": -102, "extent": 8}, "key": "loss:-124,-102"}
    d.step(snap(tm, alerts=[raid]), t + 80)  # big spitters, a tier over the usual: the inset
    assert d.inset and (d.public(t + 80).get("inset") or {}).get("attack") == raid["text"], d.public(t + 80)
    print("loss insets: ok (friendly-fire pipes: toast only; big spitters at the wall: the inset)")


def live_and_model():
    import live
    from model import Model
    src = live.LiveSource.__new__(live.LiveSource)

    class H:
        def operator_read(self, action, args):
            assert action == "big_enemies_live"
            return {"enemies": [dict(demolisher(0), label=None)]}, 1

    src.h, src.has_groups, src.has_big, src.groups_every, src.next_groups = H(), False, True, 2.0, 0
    obs = {}
    src.observe_groups(obs, {})
    assert obs["big_enemies"][0]["name"] == "small-demolisher"
    m = Model({"agents": {"sol": {"display_name": "Sol"}}})
    m.ingest({"agents": [{"name": "sol", "position": {"x": -240, "y": 70}}], "big_enemies": obs["big_enemies"]}, now=10)
    big = m.snapshot(11)["big_enemies"]
    assert big[0]["label"] == "Small demolisher · 300 tiles from Sol's gun turrets", big
    print("live and model: ok")


if __name__ == "__main__":
    inset_follows()
    inset_rules()
    follow_until_battle()
    loss_insets()
    live_and_model()
