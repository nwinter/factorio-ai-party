#!/usr/bin/env python3
"""Battles on air, enemy groups in the inset, walk loops by the queue (d26 batch245 MB, shift81's review: 5 of 5
battles and 14 of 16 enemy groups never on air; Grok's walk loops 33.0 of 86.1 idle minutes):
python3 tools/stream/test_battlecam.py

shift81's battles all scored about 0.70 (an outpost, no loss) against a bar of 2.09 and were skipped; two were Opus's
spidertron hit by worms, two walls and one laser turret hit by behemoths. Grok's "ag-tour" loop (66 x 32 tiles) passed
loop_span 64 whenever two polls caught its ends, so batch240's stale rules saw it as moving.

1. Every fight where enemies hit our buildings, vehicles or an agent on a planet is a battle on the program within
   seconds, whatever its score (logged; no group budget spent); not an agent's own firing, friendly fire, a few cheap
   pieces or a platform's asteroid damage.
2. An operator look holds the camera (the battle airs after it); a tour's look gives way.
3. Against flapping: a fight elsewhere during a battle waits and follows on at its end; one begun after waits
   battle_gap of the story; the same area within battle_resume resumes it; within battle_repeat with nothing lost it
   is only an inset, with a loss it airs.
4. A spidertron's fight: the battle is its vehicle shot, and ends once the vehicle has walked on from the fight.
5. An enemy group the program does not follow goes in the inset, panned with it, until contact; the director log
   keeps the group's place.
6. A repeating body queue walking (status queues.body.repeating) is a loop whatever its size; one that mines is not.
7. The hourly piece ends when a battle takes the program.
8. director_replay reads shift81's alert texts; vx_review counts a battle the program framed, an inset apart, a
   repeat by design, and another battle is no repeated shot.
"""
import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from test_onecam import agent, SLOTS  # noqa: E402
from onecam import OneCam  # noqa: E402
import airtime, director_replay, hourly, vx_review  # noqa: E402

T0 = 1793044134.0  # shift81 12:48:54


def director(cams=3):
    d = OneCam(SLOTS[:cams], lambda body: {"ok": True}, None, trio=False, map_every=0, platform_every=0, bow=False)
    d.started = d.onair_since = T0 - 300
    d.logged = []
    d.threats.log = d.log_threat = d.logged.append  # every threat row the director log would get
    return d


def area(x, y, first, last, what="stone wall", kind="attack", surface="nauvis"):
    return {"key": f"area:{x},{y}", "kind": kind, "text": f"Base under attack near ({x}, {y}): {what}", "first": first,
            "last": last, "losses": [], "agent": None, "position": {"x": x, "y": y, "surface": surface, "extent": 32}}


def team():
    return [agent("astra", 0, 0, 20, activity="thinking", active=False),
            agent("luna", 300, 0, 2, activity="thinking", active=False)]


def run(d, t0, t1, fights_at, agents=None, extra=None):
    """One step a second; fights_at(t) -> the fights reported at t (live.py reports one until 30 s after its last
    hit); -> {t: (subject on air, battle key on air or None)}."""
    out = {}
    for t in range(int(t0), int(t1)):
        snap = {"agents": agents(t) if agents else team(), "alerts": [], "fights": fights_at(t)}
        if extra:
            snap.update(extra(t))
        d.step(snap, t)
        cur = d.state.get(d.onair) or {}
        out[t] = (cur.get("subject"), cur.get("battle") if d.battle and cur.get("battle") == d.battle["key"] else None)
    return out


def reported(f, hit_last):
    """A fight as the snapshot has it at t: from its first hit to 30 s after its last."""
    return lambda t: [dict(f, last=min(t, hit_last + 30))] if f["first"] <= t <= hit_last + 30 else []


def every_battle():
    d = director()
    f = area(-144, -592, T0, T0)
    seen = run(d, T0 - 60, T0 + 90, reported(f, T0 + 5))
    on = [t for t, (s, b) in seen.items() if b]
    assert on and on[0] - T0 <= 4, (on[:3], d.cuts[-3:])
    take = [e for e in d.logged if e["threat"] == "battle"]
    assert take and take[0]["decision"] == "take" and take[0]["why"].startswith("our defenses fight") and \
        take[0]["score"] < 1.5, take
    assert d.threats.h["taken"] == [], "a battle spends none of the group budget"
    assert seen[int(T0 + 89)][0] == "astra" and on[-1] - T0 <= 5 + 30 + d.cfg["battle_after"] + 3, (on[-1] - T0, d.cuts[-2:])
    for f2 in (dict(area(-144, -592, T0, T0), text="friendly fire: 2 pipe"),
               area(0, 40, T0, T0, surface="platform-9"), dict(area(10, 10, T0, T0), kind="fight", agent="astra"),
               dict(area(-144, -592, T0, T0), kind="loss", text="2 lost near (-144, -592): 2 transport belt (by small biters)")):
        d = director()
        seen = run(d, T0 - 30, T0 + 20, reported(f2, T0))
        assert not d.battles, (f2, d.battles)
    print(f"1. every attack on our side is a battle on air at +{on[0] - T0:.0f} s, back to the story after; no agent's "
          "own firing, friendly fire, cheap loss or platform: ok")


def looks():
    for by, holds in (("operator", True), ("tour", False)):
        d = director()
        d.set_look({"surface": "nauvis", "position": {"x": 0, "y": 0}, "zoom": 0.5, "until": T0 + 40, "label": "x",
                    "by": by}, T0 - 30)
        f = area(-144, -592, T0, T0)
        seen = run(d, T0 - 30, T0 + 30, reported(f, T0 + 40))
        on = [t for t, (s, b) in seen.items() if b]
        if holds:
            assert not on and d.battle, (on[:2], d.cuts[-3:])
            d.set_look(None, T0 + 30)
            seen = run(d, T0 + 30, T0 + 40, reported(f, T0 + 40))
            on = [t for t, (s, b) in seen.items() if b]
            assert on and on[0] - (T0 + 30) <= 4, d.cuts[-3:]
        else:
            assert on and on[0] - T0 <= 4, d.cuts[-3:]
    print("2. an operator look holds the camera (the battle airs after it); a tour's look gives way: ok")


def flapping():
    # a fight 500 tiles away while the first is on: it waits, then follows on at once
    d = director()
    a, b = area(-144, -592, T0, T0), area(356, -592, T0 + 10, T0 + 10)
    seen = run(d, T0 - 30, T0 + 120, lambda t: reported(a, T0 + 5)(t) + reported(b, T0 + 60)(t))
    waits = [e for e in d.logged if e["decision"] == "wait"]
    assert waits and waits[0]["why"] == "a battle is on", d.logged
    keys = [k for t, (s, k) in sorted(seen.items()) if k]
    assert keys and keys[0] == a["key"] and b["key"] in keys, set(keys)
    start_b = min(t for t, (s, k) in seen.items() if k == b["key"])
    assert all(s == "@battle" for t, (s, k) in seen.items() if T0 + 5 <= t <= start_b), "no story between the two"
    # one begun after the battle ended waits battle_gap of the story
    d = director()
    c = area(856, -592, T0 + 60, T0 + 60)
    seen = run(d, T0 - 30, T0 + 140, lambda t: reported(a, T0)(t) + reported(c, T0 + 70)(t))
    end = d.battles and max(t for t, (s, k) in seen.items() if k == a["key"])
    start_c = min((t for t, (s, k) in seen.items() if k == c["key"]), default=None)
    assert start_c and start_c - end >= d.cfg["battle_gap"], (end - T0, start_c and start_c - T0)
    # the same area: resumed within battle_resume; within battle_repeat with nothing lost only its inset; a loss airs
    d = director()
    seen = run(d, T0 - 30, T0 + 400, lambda t: reported(a, T0)(t) + reported(area(-144, -592, T0 + 100, T0 + 100), T0 + 100)(t)
               + reported(area(-150, -580, T0 + 250, T0 + 250), T0 + 250)(t))
    assert [w for _, _, w, _ in d.battles][:2] == [d.battles[0][2], "resume"], d.battles
    rep = [e for e in d.logged if e["why"].startswith("repeat:")]
    assert rep and len(d.battles) == 2, (d.battles, d.logged[-2:])
    lost = dict(area(-150, -580, T0 + 250, T0 + 250), kind="loss", losses=[T0 + 250],
                text="3 lost near (-150, -580): 3 gun turret (by big spitters)")
    d = director()
    run(d, T0 - 30, T0 + 300, lambda t: reported(a, T0)(t) + reported(lost, T0 + 250)(t))
    assert len(d.battles) == 2, d.battles
    print("3. a fight elsewhere follows on at the battle's end; a new one waits battle_gap; the same area resumes, "
          "repeats only in the inset unless something is lost: ok")


def spidertron():
    d = director()
    spot = {"x": 944.0, "y": -784.0}

    def agents(t):
        opus = agent("opus", 0, 0, 5, activity="thinking", active=False)
        p = spot if t < T0 + 20 else {"x": 944.0 - 12 * (t - T0 - 20), "y": -784.0}  # walks on west after +20
        opus["remote_vehicle"] = {"vehicle": "spidertron", "unit_number": 7, "position": dict(p), "speed": 0, "t": t,
                                  "seen_t": t}
        return team() + [opus]
    f = area(944, -784, T0, T0, what="spidertron")
    seen = run(d, T0 - 30, T0 + 200, reported(f, T0 + 10), agents)
    on = [t for t, (s, k) in seen.items() if k]
    cur_at = [t for t, (s, k) in seen.items() if s == "opus" and k]
    assert on and on[0] - T0 <= 4 and cur_at, (on[:2], d.cuts[-3:])
    assert d.battles and on[-1] - T0 <= 10 + 30 + d.cfg["battle_after"] + 3, on[-1] - T0  # not battle_max
    print(f"4. a spidertron's fight: its vehicle shot, over at +{on[-1] - T0:.0f} s once it walked on: ok")


def groups():
    d = director()
    d.last_incoming = T0  # spacing: not followed on the program

    def extra(t):
        x = 900 - 5 * (t - T0)
        near = 200 if t < T0 + 30 else 5
        return {"incoming": [{"id": 25755, "position": {"x": x, "y": -800}, "target": {"x": 100, "y": -500},
                              "surface": "nauvis", "size": 18, "label": "18 biters and spitters heading for the base",
                              "kinds": "small-biter", "nearest_distance": near, "state": "moving"}]}
    seen, insets = {}, []
    for t in range(int(T0), int(T0 + 40)):
        d.step(dict({"agents": team(), "alerts": [], "fights": []}, **extra(t)), t)
        insets.append((t, dict(d.inset) if d.inset else None, dict(d.state.get((d.inset or {}).get("slot")) or {})))
    up = [(t, i, s) for t, i, s in insets if i and i.get("why") == "group"]
    assert up and up[0][0] - T0 <= 3 and up[0][2].get("enemy", "").startswith("Incoming · 18 biters"), insets[:3]
    assert up[-1][2]["position"]["x"] < up[0][2]["position"]["x"] - 50, "panned with it"
    assert not insets[-1][1] or insets[-1][1].get("why") != "group", "over at contact"
    g = [e for e in d.logged if e["threat"] == "group"]
    assert g and g[0]["where"]["position"] == {"x": 900.0, "y": -800.0} and g[0]["where"]["size"] == 18, g
    print("5. a group not followed: the inset, panned with it, over at contact; its place in the log: ok")


def queue_loops():
    def walker(t, action="move_to", lap=66):
        a = agent("grok", 8 + (lap * ((t // 5) % 2)), 30, 3, active=action)
        a["queues"] = {"body": {"repeating": True, "paused": False, "active": {"action": action}}}
        return a
    for on, action, lap, looping in ((True, "move_to", 66, True), (False, "move_to", 66, False), (True, "mine", 66, False)):
        d = director()
        d.cfg["loop_queue"] = on
        for t in range(int(T0), int(T0 + 120)):
            d.track([walker(t, action, lap)], t)
        assert (d.loop_s("grok", T0 + 119) > 0) == looping, (on, action, d.loop_s("grok", T0 + 119))
    print("6. a repeating body queue walking is a loop whatever its size (66 tiles); one that mines is not: ok")


def hourly_piece():
    class Svc:
        def __init__(self, st):
            self.st = st

        def state(self):
            return self.st
    a = hourly.Airing(Svc({"onair": {"battle": "Battle · Base under attack"}, "cameras": {"main": 1, "cam2": 2, "cam3": 3}}),
                      clock=lambda: T0)
    a.started = T0 - 10
    assert a.interrupt() == "a battle took the camera"
    a = hourly.Airing(Svc({"onair": {}, "cameras": {"main": 1, "cam2": 2}}), clock=lambda: T0)
    a.started = T0 - 10
    assert a.interrupt() is None
    print("7. the hourly piece ends when a battle takes the program: ok")


def replay_and_review():
    j = airtime.Journal("opus")
    j.requests = [(T0, "observe", {}, {"team": {"alerts": [
        "attack #16959 at (-150,-585): a group of 5 (4 big-spitter, 1 medium-spitter) that gathered at (1001,-726); no "
        "charted nest within 384 tiles; stone-wall x2 hit 2 times, 139 damage, first 1m41s ago, last 1m40s ago",
        "attack #16960 at (-47,-458): 1 attacker seen (1 behemoth-biter); no charted nest within 384 tiles; stone-wall "
        "x1 hit 1 times, 70 damage, 0s ago (new since your wait began)"]}}, True)]
    fs = {f["key"]: f for f in director_replay.fights_of({"opus": j})}
    assert fs["attack:16959"]["first"] == T0 - 101 and fs["attack:16959"]["last"] == T0 - 100 + 30, fs
    assert fs["attack:16960"]["first"] == T0 and fs["attack:16959"]["text"] == "attack #16959: stone-wall", fs
    # the review: the program's camera 49 tiles from the battle 3 s on is on air; one only in the inset is missed
    rows = [{"t": T0 - 5, "slot": "main", "reason": "standby: sol", "cmd": {"follow": "sol"}, "target": {"agents": ["sol"]},
             "result": {"camera": {"position": {"x": 191, "y": 35}, "surface": "vulcanus"}}},
            {"t": T0 - 4, "slot": "program", "reason": "cut to main: initial"},
            {"t": T0 + 1, "slot": "program", "reason": "threat battle take", "threat": {"threat": "battle", "key": "area:-144,-592@1", "decision": "skip", "why": "score 0.7 < bar 2.09"}},
            {"t": T0 + 2, "slot": "cam2", "reason": "standby: haiku (haiku · spidertron by remote view)", "target": {"agents": ["haiku"]},
             "result": {"camera": {"position": {"x": -148, "y": -543}, "surface": "nauvis"}}},
            {"t": T0 + 3, "slot": "program", "reason": "cut to cam2: haiku fresh: spidertron fighting"},
            {"t": T0 + 30, "slot": "program", "reason": "threat battle skip", "threat": {"threat": "battle", "key": "area:-48,-464@2", "decision": "skip", "why": "score 0.7 < bar 2.09"}},
            {"t": T0 + 30, "slot": "cam3", "reason": "inset: Base under attack near (-48, -464): stone wall", "target": {"agents": []},
             "result": {"camera": {"position": {"x": -48, "y": -464}, "surface": "nauvis"}}},
            {"t": T0 + 40, "slot": "program", "reason": "cut to main: back to sol"},
            {"t": T0 + 60, "slot": "program", "reason": "threat battle skip", "threat": {"threat": "battle", "key": "area:-144,-592@3", "decision": "skip", "why": "repeat: a battle here aired 100 s ago, nothing lost"}},
            {"t": T0 + 900, "slot": "program", "reason": "cut to main: back to sol"}]
    prog = vx_review.Program(rows)
    evs = vx_review.events({}, [], prog.rows, T0 - 10, T0 + 900)
    cov = vx_review.coverage(prog, evs, T0 + 900)["battle"]
    assert (cov["n"], cov["at_once"], cov["missed"], cov.get("inset_only"), cov.get("not_shown_by_design")) == (3, 1, 1, 1, 1), cov
    # a standby's shot is named by what it shows; another battle is no repeated shot
    assert airtime.owner({"reason": "standby: battle area:-144,-592"}) == "@battle" and \
        airtime.owner({"reason": "standby: look Loom, Sol's new platform"}) == "@look"
    shots = [{"t": T0 + k, "slot": "program", "reason": f"cut to {'main' if k % 120 else 'cam2'}: x"} for k in range(0, 600, 60)]
    shots += [{"t": T0 + k - 1, "slot": "main" if k % 120 else "cam2", "reason": f"standby: battle area:{k},0",
               "target": {"agents": []}} for k in range(0, 600, 60)]
    assert vx_review.idle(vx_review.Program(shots), {}, T0, T0 + 600)["repeat_min"] == 0.0
    print("8. director_replay reads shift81's alerts; vx_review counts a framed battle, an inset apart, a repeat by "
          "design: ok")


def main():
    every_battle()
    looks()
    flapping()
    spidertron()
    groups()
    queue_loops()
    hourly_piece()
    replay_and_review()
    print("battlecam: ok")


if __name__ == "__main__":
    main()
