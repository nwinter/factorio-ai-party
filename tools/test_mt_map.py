#!/usr/bin/env python3
"""mt274 (private): tools/mt/mt_map.py's layout. Starts equally far apart and from the middle; every team's own
patches the same amounts at the same distances from its start; shared sites between neighbours and in the middle;
a spawn per team on every planet; map-gen-settings with each start a starting point."""
import math, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "mt"))
sys.dont_write_bytecode = True
import mt_map as M  # noqa: E402

FAILS = []


def check(name, cond, detail=""):
    print(("ok   " if cond else "FAIL ") + name + ("" if cond else f"  {detail}"))
    if not cond:
        FAILS.append(name)


for n in (2, 3, 4, 6):
    lay = M.layout(n, 1000)
    starts = [t["spawns"]["nauvis"] for t in lay["teams"]]
    check(f"{n} teams: {n} starts", len(starts) == n)
    near = [min(math.dist(a, b) for j, b in enumerate(starts) if j != i) for i, a in enumerate(starts)]
    check(f"{n} teams: each start's nearest other start about 1000 tiles away", all(abs(d - 1000) <= 2 for d in near), near)
    mid = [math.dist(s, (0, 0)) for s in starts]
    check(f"{n} teams: every start as far from the middle", max(mid) - min(mid) <= 2, mid)
    by = {}
    for p in lay["patches"]:
        if p["site"].startswith("start "):
            t = p["site"][6:]
            s = next(x["spawns"]["nauvis"] for x in lay["teams"] if x["name"] == t)
            by.setdefault(t, []).append((p["name"], p["amount"], round(math.dist(s, (p["x"], p["y"])))))
    rows = list(by.values())
    check(f"{n} teams: each start the same patches, amounts and distances (within 2 tiles)",
          all(len(r) == 5 and all(a[0] == b[0] and a[1] == b[1] and abs(a[2] - b[2]) <= 2 for a, b in zip(r, rows[0])) for r in rows), by)
    names = {p["name"] for p in lay["patches"] if p["site"].startswith("start ")}
    check(f"{n} teams: iron, copper, coal, stone and oil at each start", names == {"iron-ore", "copper-ore", "coal", "stone", "crude-oil"}, names)
    seconds = [s for s in lay["sites"] if s["kind"] == "second"]
    check(f"{n} teams: a second site between each pair of neighbours", len(seconds) == (n if n > 2 else 1), seconds)
    for s in seconds:
        d = sorted(math.dist((s["x"], s["y"]), st) for st in starts)
        check(f"{n} teams: {s['name']} halfway between its two starts", abs(d[0] - d[1]) <= 2 and abs(d[0] - 500) <= 2, d[:2])
    thirds = [s for s in lay["sites"] if s["kind"] == "third"]
    check(f"{n} teams: third sites", len(thirds) == (1 if n > 2 else 2), thirds)
    for t in lay["teams"]:
        check(f"{n} teams: {t['name']} has a spawn on every planet", set(t["spawns"]) == {"nauvis"} | set(M.PLANETS), t["spawns"])
    for p in M.PLANETS:
        sp = [t["spawns"][p] for t in lay["teams"]]
        check(f"{n} teams: spawns on {p} apart", min(math.dist(a, b) for i, a in enumerate(sp) for b in sp[i + 1:]) > 500, sp)
    clear = lay["clear"]
    starts_clear = [c for c in clear if c["r"] == M.CLEAR_START]
    check(f"{n} teams: the cleared circles round two starts do not meet",
          all(math.dist((a["x"], a["y"]), (b["x"], b["y"])) > a["r"] + b["r"] for i, a in enumerate(starts_clear) for b in starts_clear[i + 1:]))

base = {"autoplace_controls": {"iron-ore": {"frequency": 1, "size": 1, "richness": 1}}, "_comment": "x", "seed": 1}
mgs = M.map_gen_settings(M.layout(4, 1000), base, 7, 2, 1.5)
check("map-gen-settings: each start a starting point", len(mgs["starting_points"]) == 4 and mgs["starting_points"][0]["x"] == 500.5,
      mgs["starting_points"])
check("map-gen-settings: natural ore less frequent, enemy bases as asked",
      mgs["autoplace_controls"]["iron-ore"]["frequency"] == M.NATURAL["iron-ore"] and mgs["autoplace_controls"]["enemy-base"] == {"frequency": 2, "size": 1.5})
check("map-gen-settings: the seed, and no comment keys", mgs["seed"] == 7 and "_comment" not in mgs)
sys.exit(1 if FAILS else 0)
