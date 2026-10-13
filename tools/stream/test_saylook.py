#!/usr/bin/env python3
"""An agent's spoken line can point the camera (onecam.py maybe_cue; Nick 14:11: "I'd loved to have seen the space
platform while that was narrated"): python3 tools/stream/test_saylook.py

1. Inferred looks: a line naming one of our platforms looks at it (Sol's 14:09 line about Sunward); one "(x, y)" looks
   there; two platforms or two spots, no look.
2. When the line starts playing (snapshot voiced, the page's start report) and nothing more interesting is on: a cut
   to the look for the line plus cue_after, labelled with the speaker, then back to the story.
3. Below the rest: an agent fighting on air, a battle, a follow: the look in the inset; a replay: dropped. Spacing: one
   cue per agent per cue_agent_gap, cues together cue_gap apart; a line that started long ago is no cue.
4. say look= (explicit): a spot (framed like attention) or another agent; the model keeps it on the chat line.
5. Every decision is in the director log.
"""
import json, os, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from onecam import infer_look  # noqa: E402
from test_onecam import agent, world  # noqa: E402
from test_platformcam import plat  # noqa: E402

# runs/shift06/sol/journal.jsonl 2026-10-13T21:08:53Z (14:08:53 local), voiced
SOL_1409 = ("The local ammo line is flowing again, and Sunward has the new cargo. I am aiming to turn this next "
            "tungsten attempt into continuous metallurgy production, rather than another handful of rocks.")


def inferred():
    plats = ["Sunward", "Starling"]
    assert infer_look(SOL_1409, plats) == {"platform": "Sunward", "inferred": True}
    assert infer_look("Sunward and Starling are both home", plats) is None
    assert infer_look("New smelter block at (120, -40) is up", plats) == {"position": {"x": 120.0, "y": -40.0}, "inferred": True}
    assert infer_look("Moved belts from (1, 2) to (3, 4)", plats) is None
    assert infer_look("Sunwardly we go", plats) is None and infer_look("all good here", plats) is None
    print("inferred: ok")


def team():
    return [agent("astra", 0, 0, 5), agent("sol", 300, 0, 1), agent("luna", -300, 0, 1)]


def snap(agents, voiced=(), fights=()):
    return {"agents": agents, "alerts": [], "voiced": list(voiced), "fights": list(fights),
            "space": {"platforms": [plat("Sunward", "vulcanus")]}}


def clip(cid, who, t, said, look=None, duration=11.0):
    return {"id": cid, "channel": "agent", "agent": who, "speaker": who.title(), "said": said, "text": said,
            "look": look, "started": t, "duration": duration}


def setup():
    d, sent = world(map_every=0, platform_every=0)
    d.log_path = os.path.join(tempfile.mkdtemp(), "director.jsonl")
    tm = team()
    t0 = 80000
    for k in range(3):
        d.step(snap(tm), t0 + k)
    assert (d.public(t0 + 2).get("main") or {}).get("agents") == ["astra"]
    return d, sent, tm, t0 + 3


def cut_and_back():
    d, sent, tm, t = setup()
    c = clip("c1", "sol", t, SOL_1409)
    d.step(snap(tm, [c]), t)
    for k in range(1, 4):
        d.step(snap(tm, [c]), t + k)
    main = d.public(t + 3)["main"]
    assert main.get("platform", {}).get("label") == "Sol · Sunward · in orbit of Vulcanus", main
    assert d.cuts[-1][2] == "cue: Sol · Sunward · in orbit of Vulcanus", d.cuts[-1]
    for k in range(4, 15):  # the line (11 s) plus cue_after (4 s)
        d.step(snap(tm), t + k)
        assert (d.public(t + k)["main"] or {}).get("platform"), k
    for k in range(15, 20):
        d.step(snap(tm), t + k)
    assert d.public(t + 19)["main"]["agents"] == ["astra"] and "back to astra" in d.cuts[-1][2], d.cuts[-2:]
    entry = [json.loads(l) for l in open(d.log_path) if '"cue"' in l][0]["cue"]
    assert entry["decision"] == "cut" and entry["look"] == {"platform": "Sunward", "inferred": True}, entry
    print(f"cut and back: ok ({d.cuts[-2][2]})")


def lower_priority():
    # astra fighting on air: the inset instead
    d, sent, tm, t = setup()
    tm[0]["combat"] = True
    d.step(snap(tm, [clip("c2", "sol", t, SOL_1409)]), t)
    assert d.inset and d.inset["why"] == "cue" and d.public(t)["main"]["agents"] == ["astra"], (d.inset, d.public(t))
    assert d.cues[-1][2] == "inset", d.cues
    tm[0]["combat"] = False
    # spacing: Sol again 60 s later, dropped; Luna within 45 s of the last cue, dropped
    d.step(snap(tm, [clip("c3", "sol", t + 60, "Sunward is leaving")]), t + 60)
    assert d.cues[-1][2] == "drop" and "sol's last cue" in [l for l in open(d.log_path)][-1], d.cues
    d.step(snap(tm, [clip("c4", "luna", t + 30, "Sunward is leaving")]), t + 30)  # (out of order on purpose)
    assert d.cues[-1][1:3] == ("luna", "drop") and "the last cue 30 s ago" in [l for l in open(d.log_path)][-1]
    # a line that started 10 s ago (a missed tick, a restart): no cue
    d2, _, tm2, t2 = setup()
    d2.step(snap(tm2, [clip("c5", "sol", t2 - 10, SOL_1409)]), t2)
    assert d2.cues[-1][2] == "drop" and not d2.pending and not d2.inset, d2.cues
    # a battle on: the inset; a replay on air: dropped
    d3, _, tm3, t3 = setup()
    d3.battle = {"key": "k", "label": "Battle", "position": {"x": 0, "y": 0}, "surface": "nauvis", "extent": 0, "agent": None}
    d3.maybe_cue(snap(tm3, [clip("c6", "sol", t3, SOL_1409)]), {a["name"]: a for a in tm3}, {}, t3)
    assert d3.cues[-1][2] == "inset" and '"why": "a battle"' in [l for l in open(d3.log_path)][-1], d3.cues
    d4, _, tm4, t4 = setup()
    d4.hold_layout = True
    d4.step(snap(tm4, [clip("c7", "sol", t4, SOL_1409)]), t4)
    assert d4.cues[-1][2] == "drop", d4.cues
    print("lower priority: ok (inset when astra fights or a battle is on; spacing; late line; replay)")


def explicit():
    d, sent, tm, t = setup()
    c = clip("c8", "sol", t, "Look at the new smelter row", look={"position": {"x": 120, "y": -40}, "surface": "nauvis", "extent": 30})
    for k in range(3):
        d.step(snap(tm, [c]), t + k)
    main = d.public(t + 2)["main"]
    assert main["agents"] == ["sol"] and main["work"] == "Sol at (120, -40)" and main["frame"]["position"] == {"x": 120, "y": -40}, main
    d2, _, tm2, t2 = setup()
    c = clip("c9", "sol", t2, "Luna is fixing the wall", look={"agent": "luna"})
    for k in range(3):
        d2.step(snap(tm2, [c]), t2 + k)
    main = d2.public(t2 + 2)["main"]
    assert main["agents"] == ["luna"] and main["work"] == "Luna (Sol on the mic)", main
    # the model keeps say look= on the chat line (caster.py pushes it with the clip)
    from model import Model
    m = Model({"agents": {"sol": {}}})
    m.ingest({"agents": [{"name": "sol"}], "chat": [{"seq": 9, "tick": 1, "from": "sol", "text": SOL_1409, "aloud": True,
                                                    "look": {"platform": "Sunward"}}]}, now=10)
    line = next(c for c in m.snapshot(11)["chat"] if c.get("seq") == 9)
    assert line["look"] == {"platform": "Sunward"}, line
    print("explicit: ok (a spot, another agent; the chat line keeps look)")


if __name__ == "__main__":
    inferred()
    cut_and_back()
    lower_priority()
    explicit()
