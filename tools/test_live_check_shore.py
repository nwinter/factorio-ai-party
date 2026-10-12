#!/usr/bin/env python3
"""Offline check for tools/live_check_shore.py: every Lua snippet compiles (luac -p), and with a fake harness and game
answering as a working world, the check runs to the end with every step ok. python3 tools/test_live_check_shore.py"""
import json, os, re, subprocess, sys, tempfile

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import live_check_coverage as L  # noqa: E402
import live_check_shore as S  # noqa: E402

PUMPS = [(122, 206.5, "east"), (122, 207.5, "east"), (122, 205.5, "east")]
BOILERS = [(119.5, 211, "north"), (119.5, 210, "north"), (119.5, 212, "north")]
DIRS = {"north": 0, "east": 4, "south": 8, "west": 12}
state = {"water": 0, "units": {}}
compiled, calls = [], []


def fake_lua(self, code):
    code = L.one_line(code)
    p = subprocess.run(["luac", "-p", "-"], input=code, capture_output=True, text=True)
    assert p.returncode == 0, (p.stderr, code[:300])
    compiled.append(code)
    if "connected_players" in code:
        fake_lua.tick = getattr(fake_lua, "tick", 0) + 600
        return {"tick": fake_lua.tick, "paused": False, "players": 1}
    if "bot_create" in code:
        return {"ok": True, "bot": {"name": "ls1", "unit_number": 700}}
    if "bot_remove" in code:
        return {"ok": True}
    if "teleport" in code:
        return {"site": {"x": 100, "y": 200}, "given": {"offshore-pump": 2, "boiler": 1}}
    if "s.get_tile" in code:
        state["water"] = 100
        return {"old": [[x, y, "grass-1"] for x in range(122, 132) for y in range(202, 212)], "water": 100}
    if "s.set_tiles{" in code:
        state["water"] = 0
        return {"water": 0}
    if "can_place_entity" in code:
        return {"ok": [True] * 3}
    m = re.search(r'find_entity\("([^"]+)", \{(-?[\d.]+), (-?[\d.]+)\}\)', code)
    if m:
        for unit, e in state["units"].items():
            if (e["name"], e["x"], e["y"]) == (m.group(1), float(m.group(2)), float(m.group(3))):
                return dict(e, unit=unit)
        return {}
    if "removed" in code:
        state["built"] = [int(u) for u in code.split("ipairs{")[1].split("}")[0].split(",") if u]
        return {"removed": 2}
    return {}


def fake_fh(self, action, args=None, wait=False):
    calls.append((action, args, wait))
    if action == "describe":
        return True, {"result": {"actions": {"placements": {"name": "..."}}}}
    if action == "status":
        return True, {"result": {"position": {"x": 0, "y": 0}}}
    if action == "move_to":
        return True, {"result": {"position": args["position"]}}
    if action == "placements":
        return True, {"result": {"placements": [{"position": {"x": x, "y": y}, "direction": d} for x, y, d in PUMPS], "checked": 40}}
    if action == "build":
        x, y = args["position"]["x"], args["position"]["y"]
        item = args["item"]
        if item == "offshore-pump" and (x, y) == (116.5, 207):
            text = ", ".join(f"({x:g},{y:g}) {d}" for x, y, d in PUMPS)
            return False, {"error": {"message": "placement blocked (nothing found in the footprint: check the position is a valid "
                                                "centre for a offshore-pump and the direction); nearest valid offshore-pump placements "
                                                f"(game build check, within 12 tiles): {text}"}}
        if item == "boiler" and (x, y) == (122.5, 211):
            text = ", ".join(f"({x:g},{y:g}) {d}" for x, y, d in BOILERS)
            return False, {"error": {"message": "placement blocked by tiles: water (needs landfill, or a shore position: scan "
                                                "fields=fluids / grid ~ marks water); nearest positions where boiler fits facing north "
                                                f"(game build check, within 6 tiles): {text}"}}
        unit = 800 + len(state["units"])
        state["units"][unit] = {"name": item, "x": x, "y": y, "direction": DIRS[args.get("direction", "north")]}
        entity = {"name": item, "position": args["position"], "unit_number": unit}
        # The bot on the footprint (live 11:56): it steps aside first; the entity is in last.result only.
        assert wait
        return True, {"result": {"aside": {"from": {}, "to": {}},
                                 "completion": {"last": {"outcome": "fed", "result": {"entity": entity}}}}}
    return True, {"result": {}}


class FakeRcon:
    def __init__(self, *a, **k):
        pass


def main():
    L.Check.lua, L.Check.fh = fake_lua, fake_fh
    L.pog.Rcon = FakeRcon
    L.time.sleep = lambda s: None
    out = tempfile.mkdtemp()
    pwfile = os.path.join(out, "pw")
    open(pwfile, "w").write("x")
    L.os.path.expanduser = lambda p: pwfile if "rcon-" in p else p
    os.environ["POG_WORLD"] = "live"
    sys.argv = ["live_check_shore.py", "--out", out]
    code = None
    try:
        S.main()
    except SystemExit as e:
        code = e.code
    lines = [json.loads(l) for l in open(os.path.join(out, "check.jsonl"))]
    fails = [l["step"] for l in lines if not l["ok"]]
    assert code == 0 and not fails, (code, fails)
    steps = [l["step"] for l in lines]
    for want in ("game clock runs (a client connected, not auto-paused)", "stage: 10x10 water at (122,202)",
                 "offshore pump on dry land: refused with up to 3 placements", "placements nearest first, within 12 tiles",
                 "game: can_place_entity (manual) accepts each", "placements read: the same list",
                 "build offshore pump at the first placement", "game: the pump stands there, facing that way", "boiler on water: refused by water, with positions facing north",
                 "game: the boiler stands there", "cleanup: the old tiles are back", "cleanup: bot removed"):
        assert want in steps, (want, steps)
    # Cleanup gets the units the game reported, whatever the build replied.
    assert sorted(state["built"]) == [800, 801], state["built"]
    built = [a for act, a, _ in calls if act == "build"]
    assert built[1] == {"item": "offshore-pump", "position": {"x": 122, "y": 206.5}, "direction": "east"}, built
    # The suggestions parse from the refusal text, after the hint only.
    assert S.spots("blocked by tree (1,2); nearest valid offshore-pump placements (game build check, within 12 tiles): "
                   "(-3.5,4) west, (-3.5,5) west") == [(-3.5, 4.0, "west"), (-3.5, 5.0, "west")]
    assert not S.nearest_first((0, 0), [(5, 0, "east"), (1, 0, "east")], 12)
    # Run worlds are refused.
    os.environ["POG_WORLD"] = "n"
    try:
        S.main()
        raise AssertionError("world n was not refused")
    except SystemExit as e:
        assert "refusing" in str(e.code), e.code
    print(f"live_check_shore: ok ({len(steps)} steps, {len(compiled)} Lua snippets compiled)")


if __name__ == "__main__":
    main()
