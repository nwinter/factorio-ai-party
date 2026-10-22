#!/usr/bin/env python3
"""Artillery impacts on air (onecam maybe_artillery; viewer Foobator 2026-10-17 12:48: "if there is only one arty shell
in flight and nothing else interesting has happened, can you show the impact on screen"). Offline:
python3 tools/stream/test_artycam.py

1. A shell in flight (snapshot artillery: artillery_live's read) with nothing more interesting on: a standby jumps to
   its target, the cut comes in time for the impact (next_wake), the label names who fired and the target, and the
   story comes back after the impact.
2. A shell landing soon gets a shorter standby wait; one landing in under arty_lead is let go; a shell is judged once.
3. At most one artillery shot per arty_gap; more shells landing at the shot's target hold it longer (up to arty_max).
4. Never over a fight, an urgent shot, an operator look, a segment or the trio.
5. One client (POG_CAMS=1): the client on air moves to the target at once.
6. The service: harness.py knows the operator read; serve.py reads it on its own pace and wakes the director.
"""
import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from test_onecam import agent, world  # noqa: E402
from onecam import OneCam  # noqa: E402


def snap(agents, shells=(), read_at=None, fights=()):
    out = {"agents": agents, "alerts": [], "fights": list(fights)}
    if shells:
        out["artillery"] = {"shells": list(shells), "read_at": read_at, "every": 0.5}
    return out


def shell(key="7|398,-320|1", eta=150, x=398.5, y=-320.5, by="opus", around="1 medium-worm-turret"):
    return {"key": key, "surface": "nauvis", "from": {"x": 298.5, "y": -320.5}, "at": {"x": 318.5, "y": -320.5},
            "piece": {"name": "artillery-turret", "position": {"x": 298.5, "y": -320.5}, "surface": "nauvis", "by": by},
            "target": {"name": "big-spitter-nest", "position": {"x": x, "y": y}, "around": around},
            "distance": 100, "eta_ticks": eta, "by": by}


def team():
    return [agent("luna", 0, 0, 5), agent("opus", 300, -300, 1), agent("sol", -200, 0, 1)]


def settled(d, t):
    for k in range(3):
        d.step(snap(team()), t + k)
    assert (d.public().get("main") or {}).get("agents") == ["luna"], d.public()
    return t + 3


def cut_and_back():
    d, sent = world(map_every=0)
    t = settled(d, 1000)
    d.step(snap(team(), [shell(eta=150)], read_at=t), t)  # lands at t + 2.5
    assert d.artys[-1][1] == "cut", d.artys
    framed = d.state[d.pending["slot"]]
    assert framed["position"] == {"x": 398.5, "y": -320.5} and framed["surface"] == "nauvis", framed
    assert framed["zoom"] == 0.8 and framed["exact_zoom"], framed
    assert d.pending["ready_s"] == 1.5, d.pending  # (lands in 2.5 s: the usual wait still cuts a second before)
    w = d.next_wake(t)
    assert abs(w - 1.5) < 1e-6, w
    d.step(snap(team()), t + w)
    row = d.public(t + w).get("main") or {}
    assert row.get("work") == ("💥 Artillery · Opus's artillery turret (298, -320) → big spitter nest (398, -320), "
                               "100 tiles, with 1 medium worm turret"), row
    assert d.next_wake(t + w) is None
    # held through the impact (t + 2.5) and arty_after past it, then the story again
    for k in range(2, 7):
        d.step(snap(team()), t + k)
        assert (d.public(t + k).get("main") or {}).get("work", "").startswith("💥"), (k, d.public(t + k))
    for k in range(7, 12):
        d.step(snap(team()), t + k)
    assert (d.public(t + 11).get("main") or {}).get("agents") == ["luna"], d.public(t + 11)
    print("1. a shell's target on air before it lands, then the story: ok")


def lead_and_once():
    d, _ = world(map_every=0)
    t = settled(d, 1000)
    d.step(snap(team(), [shell(key="a", eta=24)], read_at=t), t)  # lands in 0.4 s: too late
    assert d.artys[-1][1] == "drop" and d.pending is None, d.artys
    d.step(snap(team(), [shell(key="a", eta=24)], read_at=t), t + 0.1)
    assert len(d.artys) == 1, "a shell is judged once"
    d.step(snap(team(), [shell(key="b", eta=60)], read_at=t + 1), t + 1)  # lands in 1 s
    assert d.artys[-1][1] == "cut" and abs(d.pending["ready_s"] - 0.5) < 1e-6, d.pending
    print("2. a near landing gets a shorter wait, a too-near one is let go, a shell judged once: ok")


def spacing_and_more_shells():
    d, _ = world(map_every=0)
    t = settled(d, 1000)
    d.step(snap(team(), [shell(key="a", eta=150)], read_at=t), t)
    d.step(snap(team()), t + 1.5)
    cur = d.state[d.onair]
    first_until = cur["until"]
    # the turret fires again at a nest beside it: the shot holds for that impact too
    d.step(snap(team(), [shell(key="b", eta=200, x=410.5, y=-325.5)], read_at=t + 2), t + 2)
    assert cur["until"] > first_until and cur["artillery"]["shells"] == 2, cur
    assert cur["until"] <= t + 20, cur["until"]
    # another target far off while the shot is on air: no new cut
    d.step(snap(team(), [shell(key="c", eta=200, x=900, y=900)], read_at=t + 3), t + 3)
    assert d.state[d.onair] is cur
    for k in range(4, 30):
        d.step(snap(team()), t + k)
    # 60 s later: spacing; 200 s later: a cut again
    d.step(snap(team(), [shell(key="d", eta=150)], read_at=t + 60), t + 60)
    assert d.artys[-1][1] == "drop" and d.artys[-1][2].startswith("spacing"), d.artys[-1]
    d.step(snap(team(), [shell(key="e", eta=150)], read_at=t + 200), t + 200)
    assert d.artys[-1][1] == "cut", d.artys[-1]
    print("3. once per arty_gap; more shells at its target hold it longer: ok")


def two_shells_one_read():
    """(d22 batch89 AY5) two shells in one read: the first cuts, the second (beside it) holds that shot; shift57
    07:50:12 raised KeyError 'until' on the state that had been on air."""
    d, _ = world(map_every=0)
    t = settled(d, 1000)
    d.state[d.onair].pop("until", None)  # the state on air has no until (shift57's)
    d.step(snap(team(), [shell(key="a", eta=150), shell(key="b", eta=240, x=410.5, y=-325.5)], read_at=t), t)
    assert [a[1] for a in d.artys] == ["cut"], d.artys
    framed = d.state[d.pending["slot"]]
    assert framed["artillery"]["shells"] == 2 and framed["until"] >= t + 4 + 0.5, framed
    print("7. two shells in one read: the second holds the new shot: ok")


def outranked():
    d, _ = world(map_every=0)
    t = settled(d, 1000)
    fight = {"key": "attack:base", "kind": "attack", "text": "Gun turrets under attack", "first": t, "last": t,
             "position": {"x": 50, "y": 50}, "surface": "nauvis"}
    d.step(snap(team(), [shell(key="f", eta=150)], read_at=t, fights=[fight]), t)
    assert d.artys[-1][1] == "drop" and d.artys[-1][2] in ("a fight", "a battle", "an urgent shot"), d.artys
    assert d.state[d.onair].get("artillery") is None
    d.set_look({"surface": "nauvis", "position": {"x": 0, "y": 0}, "zoom": 0.75, "until": t + 60, "label": "x", "by": "operator"}, t)
    d.step(snap(team(), [shell(key="g", eta=150)], read_at=t + 1), t + 1)
    assert d.artys[-1][1:3] == ("drop", "an operator look"), d.artys
    d.set_look(None, t + 2)
    seg = {"id": 9, "label": "Rocket launch", "zoom": 0.5, "until": t + 60, "position": {"x": 5, "y": 5}, "surface": "nauvis"}
    d.step(snap(team(), [shell(key="h", eta=150)], read_at=t + 3), t + 3, seg)
    assert d.artys[-1][1:3] == ("drop", "a segment"), d.artys
    print("4. never over a fight, an operator look or a segment: ok")


def one_client():
    d = OneCam([{"slot": "main", "player": 3}], lambda b: {"ok": True}, None, trio=False, map_every=0)
    d.started = 0
    t = 1000
    for k in range(3):
        d.step(snap(team()), t + k)
    t += 3
    d.step(snap(team(), [shell(eta=150)], read_at=t), t)
    cur = d.state["main"]
    assert cur.get("artillery") and cur["position"] == {"x": 398.5, "y": -320.5}, cur
    assert d.next_wake(t) is None
    print("5. one client: moved to the target at once: ok")


def service():
    import harness
    assert "artillery_live" in harness.OPERATOR_READS
    src = open(os.path.join(HERE, "serve.py")).read()
    assert 'operator_read("artillery_live"' in src and "wake.wait(" in src and 'snap["artillery"] = arty["res"]' in src
    print("6. the service reads artillery_live on its own pace and wakes the director: ok")


def main():
    cut_and_back()
    lead_and_once()
    spacing_and_more_shells()
    two_shells_one_read()
    outranked()
    one_client()
    service()
    print("test_artycam: ok")


if __name__ == "__main__":
    main()
