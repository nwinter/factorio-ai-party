#!/usr/bin/env python3
"""One unlocks table for the hosts and the agents: python3 tools/stream/test_unlocks.py

- model.UNLOCKS is read from the harness's unlocks.lua (the agents' shift block, "researched, none built"): every row
  parses, in file order, with the rows the hosts had before.
- Every building in it is one tools/pog.py's score counts (a building the score never counts would always read as
  "none built").
- unused_unlocks still works from it.
"""
import os
import re
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(ROOT, "tools"))
import model  # noqa: E402
import pog  # noqa: E402


def main():
    lua = open(model.UNLOCKS_LUA).read()
    rows = [l for l in lua.splitlines() if l.strip().startswith("{'")]
    assert len(rows) == len(model.UNLOCKS) == 23, (len(rows), len(model.UNLOCKS))
    assert list(model.UNLOCKS)[:3] == ["logistic-robotics", "construction-robotics", "logistic-system"]
    assert model.UNLOCKS["logistic-system"] == (("requester-chest", "buffer-chest"), "requester chests")
    assert model.UNLOCKS["oil-processing"] == (("pumpjack", "oil-refinery"), "pumpjacks or refineries")
    counted = set(re.findall(r'"([a-z0-9-]+)"', pog.SCORE_LUA.split("local counts, counted", 1)[1].split("}) do", 1)[0]))
    for tech, (buildings, _) in model.UNLOCKS.items():
        for b in buildings:
            assert b in counted, f"{tech}: {b} is not counted by the score"
    m = model.Model({"agents": {"astra": {}}})
    m.ingest({"research": {"done": ["logistic-robotics", "solar-energy"], "current": None},
              "entities": {"solar-panel": 4}, "entities_counted": sorted(counted)})
    uu = m.unused_unlocks(time.time())
    assert [u["unlocks"] for u in uu] == ["roboports"], uu
    print("unlocks: ok (one table in unlocks.lua, %d rows, all counted by the score)" % len(model.UNLOCKS))


if __name__ == "__main__":
    main()
