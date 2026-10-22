#!/usr/bin/env python3
"""One place, one inset a while (d22 batch89 AY5, review AU1): python3 tools/stream/test_inset_area.py

"Base under attack near (-144, -560): laser turret" went up as an inset 38 times in shift55 and 38 in shift56, a median
322 s apart, each a new alert key. An alert within inset_area (64) tiles of an inset shown less than inset_area_gap
(600 s) ago is skipped unless it is worse: a loss after an attack, more pieces lost, a death. Elsewhere, or 10
minutes on, the inset goes up again.
"""
import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from test_onecam import agent, onair_agent, snap, world  # noqa: E402

TEXT = "Base under attack near (-144, -560): laser turret"


def attack(i, t, x=-144, y=-560, text=TEXT):
    return {"id": f"a{i}", "kind": "attack", "t": t, "text": text, "position": {"x": x, "y": y, "extent": 16},
            "key": f"area:{x},{y}:{i}"}


def shown(d, al, t):
    d.step(snap(TEAM, [al]), t)
    pub = d.public(t)
    up = (pub.get("inset") or {}).get("attack") == al["text"] and (d.inset or {}).get("t") == t
    for k in range(1, 31):  # the inset times out (inset_hold 20 s)
        d.step(snap(TEAM), t + k)
    return up


TEAM = [agent("luna", 0, 0, 5), agent("sol", 400, 0, 1), agent("astra", -400, 0, 1)]


def main():
    d, _ = world()
    t = 1000
    for k in range(3):
        d.step(snap(TEAM), t + k)
    assert onair_agent(d) == ["luna"]
    assert shown(d, attack(1, t + 10), t + 10), "the first inset"
    assert not shown(d, attack(2, t + 332), t + 332), "322 s later, the same place, no worse: skipped"
    assert not shown(d, attack(3, t + 400, x=-120, y=-530), t + 400), "within 64 tiles: skipped"
    assert shown(d, attack(4, t + 450, x=300, y=300, text="Base under attack near (300, 300): gun turret"), t + 450), \
        "elsewhere: shown"
    loss = {"id": "l1", "kind": "loss", "t": t + 500, "text": "1 lost near (-140, -556): 1 pipe (by medium biters)",
            "position": {"x": -140, "y": -556, "extent": 16}, "key": "loss:-140,-556"}
    assert shown(d, loss, t + 500), "worse (a minor loss after attacks): an inset again"
    assert not shown(d, attack(5, t + 560), t + 560), "an attack after that loss: no worse, skipped"
    assert shown(d, attack(6, t + 1200), t + 1200), "more than 600 s after the last inset there: shown again"
    print("inset by area: ok (the same place no worse within 10 min skipped; elsewhere, worse, or later shown)")


if __name__ == "__main__":
    main()
