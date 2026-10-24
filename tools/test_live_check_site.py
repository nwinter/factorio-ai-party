#!/usr/bin/env python3
"""d24 batch158 (the harness review's bug 8): the live checks' clear site from --site or a wider search, the shore
check's placements compared with ties allowed, and sa_smoke charting first and failing the early-game steps it skips.
Runs with no arguments and no world."""
import json, os, sys

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import live_check_coverage as L  # noqa: E402
import live_check_shore as S  # noqa: E402
import sa_smoke  # noqa: E402


def main():
    # --site: parsed, and the search starts there with the bot found at its own position
    assert L.parse_site(None) is None
    assert L.parse_site("705,-12.5") == {"x": 705.0, "y": -12.5}
    try:
        L.parse_site("705")
        raise AssertionError("one number taken")
    except SystemExit as e:
        assert "--site takes X,Y" in str(e)
    lua = L.stage_lua({"x": 0, "y": -4}, {"rail": 60}, {"x": 705, "y": 705})
    assert "local bx, by = 0, -4" in lua and "local sx, sy = 705, 705" in lua, lua[:300]
    assert f"for r = 0, {L.RINGS} do" in lua and L.RINGS >= 24
    assert "--site X,Y starts the search elsewhere" in lua
    lua = L.stage_lua({"x": 3, "y": 4}, {"rail": 60})
    assert "local sx, sy = 3, 4" in lua

    # the shore check: the same spots, two equally near ones in either order; a farther one is not the same
    want = (742.5, 717.0)
    found = [(747.5, 716.5, "east"), (747.5, 717.5, "east"), (748.5, 712.5, "north")]
    assert S.same_spots(want, found, [(747.5, 717.5, "east"), (747.5, 716.5, "east"), (748.5, 712.5, "north")])
    assert not S.same_spots(want, found, [(747.5, 716.5, "east"), (747.5, 717.5, "east"), (750.5, 712.5, "north")])
    assert not S.same_spots(want, found, found[:2])

    # sa_smoke: chart first (waits while chunks are uncharted), and a skipped step fails
    class FakeRcon:
        def __init__(self):
            self.n = 0

        def command(self, cmd):
            if "f.chart(" in cmd:
                return json.dumps({"spawn": {"x": 0, "y": 0}, "tick": 10})
            self.n += 1
            return json.dumps({"charted": 25 if self.n >= 3 else 9, "total": 25, "tick": 10 + self.n})

    class FakeSmoke(sa_smoke.Smoke):
        def __init__(self):
            self.fails, self.rows, self.rcon = 0, [], FakeRcon()

        def record(self, step, ok, reply):
            self.fails += 0 if ok else 1
            self.rows.append((step, ok))

        def fh(self, step, action, args=None, wait=False, timeout_ms=None):
            self.rows.append((step, True))
            return {"result": {"entities": []}}

    s = FakeSmoke()
    sa_smoke.chart(s, sleep=lambda _: None)
    assert ("chunks round spawn charted", True) in s.rows and s.rcon.n == 3, s.rows
    assert sa_smoke.gather(s, "stone", 600) is False
    assert ("gather stone: skipped", False) in s.rows and s.fails == 1, s.rows
    s2 = FakeSmoke()
    s2.rcon.n = -100
    sa_smoke.chart(s2, sleep=lambda _: None, tries=3)
    assert ("chunks round spawn charted", False) in s2.rows, s2.rows
    print("test_live_check_site: ok")


if __name__ == "__main__":
    main()
