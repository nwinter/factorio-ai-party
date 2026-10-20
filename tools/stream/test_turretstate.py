#!/usr/bin/env python3
"""Each turret's readiness for the site's map (d20 batch50 G1, viewer Aurora 09:09): python3 tools/stream/test_turretstate.py

turretstate.TurretState over a fake world (no RCON): the basemap's defence areas cut to 32-tile pieces; a pass of
commands that stop at MAX_TURRETS (the rest go to the next command); a pass at most every EVERY s; armed, empty and no
power as read; a turret on the map never read, or not read since the last finished pass, is unknown with its age; a
turret gone is dropped after a pass; model.py puts the state on the basemap the site gets.
"""
import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import turretstate  # noqa: E402
from turretstate import TurretState, pieces, state_lua  # noqa: E402

# one row of defence cells (cell 8) from x=0 to x=80: three pieces (32, 32, 16 wide)
BASEMAP = {"cell": 8, "x0": 0, "y0": 0, "rows": ["DDDDDDDDDD", "..........", "D........."],
           "turrets": [[2, 2, 18], [40, 3, 18], [70, 4, 24], [3, 17, 18], [60, 60, 18]]}  # (60,60): drawn, never read


class World:
    """h.lua for STATE_LUA: the turrets in each area of the command's BODY, stopping after the area that reaches MAX."""

    def __init__(self, turrets, cap=None):
        self.turrets, self.tick, self.cap, self.calls = dict(turrets), 1000, cap, []

    def lua(self, lua):
        import json, re
        body = re.search(r"json_to_table\(\[(=*)\[(.*?)\]\1\]\)", lua, re.S).group(2)
        cap = self.cap or int(re.search(r"#out >= (\d+)", lua).group(1))
        out, done = [], 0
        for i, (x0, y0, x1, y1) in enumerate(json.loads(body), 1):
            if len(out) >= cap:
                break
            done = i
            out += [[x, y, st, name] for (x, y), (st, name) in sorted(self.turrets.items()) if x0 <= x < x1 and y0 <= y < y1]
        self.calls.append(done)
        self.tick += 60
        return {"tick": self.tick, "done": done, "turrets": out if out else {}}


def main():
    assert pieces([[0, 0, 80, 8]]) == [[0, 0, 32, 8], [32, 0, 64, 8], [64, 0, 80, 8]]
    lua = state_lua([[0, 0, 32, 8]])
    assert "--" not in lua and f"#out >= {turretstate.MAX_TURRETS}" in lua and "artillery_turret_ammo" in lua
    w = World({(2, 2): ("a", "gun-turret"), (40, 3): ("e", "gun-turret"), (70, 4): ("p", "laser-turret"),
               (3, 17): ("a", "flamethrower-turret")})
    st = TurretState(per=2)
    assert st.public() is None and not st.due(0)
    st.seen(BASEMAP)
    assert len(st.areas) == 4 and st.due(0)
    while st.step(w, 0.0) is not None and st.todo:
        pass
    p = st.public()
    assert p["counts"] == {"armed": 2, "empty": 1, "no_power": 1, "unknown": 1}, p
    assert p["flagged"] == [[40, 3, "e", "gun-turret", 1], [70, 4, "p", "laser-turret", 0], [60, 60, "u", None, None]], p
    assert p["every_s"] == 60 and p["as_of"] == w.tick
    # not due before EVERY; due after
    assert not st.due(30.0) and st.step(w, 30.0) is None and st.due(61.0)
    # the second pass: the empty gun is refilled, the laser turret is gone; after the first command of the pass the
    # rest still count from the last finished pass, then the laser turret (not drawn there: the basemap lists (70,4))
    w.turrets[(40, 3)] = ("a", "gun-turret")
    del w.turrets[(70, 4)]
    st.step(w, 61.0)
    mid = st.public()
    assert mid["counts"]["empty"] == 0 and mid["counts"]["no_power"] == 1, mid  # (70,4) not read yet in this pass
    while st.step(w, 61.0) is not None and st.todo:
        pass
    end = st.public()
    # (70,4) is still on the map (the basemap draws it) and was not read in the pass: unknown, with its last reading's age
    assert end["counts"] == {"armed": 3, "empty": 0, "no_power": 0, "unknown": 2}, end
    u = [f for f in end["flagged"] if f[:2] == [70, 4]][0]
    assert u[2] == "u" and u[3] == "laser-turret" and u[4] > 0, u
    # the map no longer lists it: dropped after the next pass
    st.seen(dict(BASEMAP, turrets=[t for t in BASEMAP["turrets"] if t[:2] != [70, 4]]))
    while st.step(w, 200.0) is not None and st.todo:
        pass
    assert (70, 4) not in st.readings and st.public()["counts"]["unknown"] == 1
    # a command stops at MAX_TURRETS: the areas it did not finish go to the next one
    many = {(x, 2): ("a", "gun-turret") for x in range(0, 80, 2)}
    w2 = World(many, cap=10)
    st2 = TurretState(per=4)
    st2.seen(BASEMAP)
    st2.step(w2, 0.0)
    assert w2.calls == [1] and len(st2.todo) == 3, (w2.calls, st2.todo)  # 16 turrets in the first piece: stopped there
    while st2.step(w2, 0.0) is not None and st2.todo:
        pass
    assert st2.public()["counts"]["armed"] == 40
    # the model: the basemap the site gets carries it
    import model
    m = model.Model({"agents": {"sol": {}}})
    m.ingest({"tick": 10, "agents": [], "basemap": dict(BASEMAP)}, now=1000)
    m.ingest({"tick": 20, "agents": [], "turret_state": p}, now=1001)
    assert m.snapshot(1002)["basemap"]["turret_state"]["counts"]["empty"] == 1
    print("turret state: ok (paged by area and turret count, once a minute, armed/empty/no power, unknown when stale)")


if __name__ == "__main__":
    main()
