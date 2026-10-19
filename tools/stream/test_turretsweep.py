#!/usr/bin/env python3
"""The turrets past the basemap's 600 (turretsweep.py; d19 batch42 B2, viewer Aurora: southern defenses missing from
the map): the areas a pass reads are the defence cells' runs; a capped basemap starts a pass, its commands read AREAS
areas each, and the finished pass replaces the list (merged within 2 tiles) and says what was read; a basemap under the
cap is left alone. python3 tools/stream/test_turretsweep.py"""
import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import turretsweep as T  # noqa: E402


class FakeH:
    """Answers SWEEP_LUA with the turrets inside its areas."""

    def __init__(self, turrets):
        self.turrets, self.calls = turrets, []

    def lua(self, lua):
        self.calls.append(lua)
        import json
        boxes = json.loads(lua.split("helpers.json_to_table([=[", 1)[1].split("]=])", 1)[0])
        got = [t for t in self.turrets if any(b[0] <= t[0] < b[2] and b[1] <= t[1] < b[3] for b in boxes)]
        return {"tick": 1000 + len(self.calls), "turrets": got or {}}


def main():
    bm = {"cell": 16, "x0": -64, "y0": -32, "rows": ["..DDD.D", "", "D"], "turrets": []}
    assert T.areas(bm) == [[-32, -32, 16, -16], [32, -32, 48, -16], [-64, 0, -48, 16]], T.areas(bm)
    # merge: same place once; a gun turret 2 tiles from a kept one of its range or more is left out, a farther one stays
    kept, n = T.merge([[0, 0, 18], [0, 0, 18], [2, 1, 18], [5, 0, 18], [1, 1, 24], [40, 40, 18]])
    assert n == 5 and sorted(kept) == [[1, 1, 24], [5, 0, 18], [40, 40, 18]], (n, kept)
    # under the cap: nothing to do
    s = T.TurretSweep(cap=3, per=2)
    small = dict(bm, turrets=[[0, 0, 18]])
    s.seen(small)
    assert not s.todo and s.apply(small) is small
    # capped: a pass of 2 commands (3 areas, 2 a command); before it finishes the basemap says capped
    south = [[-30, -30, 18], [-20, -25, 18], [0, -20, 24], [40, -30, 18], [-60, 5, 18], [100, 100, 18]]
    capped = dict(bm, turrets=[[-30, -30, 18], [-20, -25, 18], [0, -20, 24]])
    s.seen(capped)
    assert len(s.todo) == 3
    assert s.apply(capped)["turrets_read"] == {"turrets": 3, "capped": True}
    h = FakeH(south)
    s.step(h)
    assert s.done is None and len(s.todo) == 1
    s.step(h)
    assert not s.todo and len(h.calls) == 2 and s.step(h) is None
    out = s.apply(capped)
    assert sorted(out["turrets"]) == sorted(south[:5]), out["turrets"]  # (100,100) is in no defence cell
    assert out["turrets_read"] == {"turrets": 5, "drawn": 5, "as_of": 1002, "complete": True}, out["turrets_read"]
    # a new capped basemap while a pass runs does not restart it; after it, the next pass starts
    s.seen(capped)
    assert len(s.todo) == 3
    # the command is one line of Lua without comments
    assert "--" not in T.sweep_lua(T.areas(bm)) and "[=[[[-32,-32,16,-16],[32," in T.sweep_lua(T.areas(bm))
    # the console audit knows the command as the operator's (its areas are a long string, blanked in the shape)
    sys.path.insert(0, os.path.dirname(HERE))
    import console_audit as A
    import harness
    key = A.shape("silent-command", harness.one_line(T.sweep_lua(T.areas(bm))))
    assert A.label({"command": "silent-command", "shape": key}, A.operator_shapes()) == "operator", key
    print("turret sweep: ok (defence cells' runs, capped basemap read in commands of 40 areas, merged list, under the cap untouched)")


if __name__ == "__main__":
    main()
