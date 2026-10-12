#!/usr/bin/env python3
"""Offline check for tools/live_check_coverage.py: every Lua snippet it sends compiles (luac -p), and with a fake
harness and a fake game answering as a working world, the whole check runs to the end with every step ok and cleans
up. python3 tools/test_live_check_coverage.py"""
import json, os, re, subprocess, sys, tempfile

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import live_check_coverage as L  # noqa: E402

compiled, calls, units = [], [], [100]
where = {"pos": None}


def fake_lua(self, code):
    code = L.one_line(code)
    p = subprocess.run(["luac", "-p", "-"], input=code, capture_output=True, text=True)
    assert p.returncode == 0, (p.stderr, code[:300])
    compiled.append(code)
    if "bot_create" in code or "bot_remove" in code:
        return {"ok": True}
    if "teleport" in code:
        return {"site": {"x": 100, "y": 200}, "given": {"rail": 60}}
    if "circuit_red" in code and "inserter" in code:
        return {"wired": True, "enable": True, "signal": "iron-plate", "comparator": "<", "constant": 10}
    if "constant-combinator" in code and "get_section" in code:
        return {"signal": "signal-A", "count": 1, "wired": True, "enable": True, "lamp_signal": "signal-A",
                "comparator": ">", "constant": 0}
    if "records" in code:
        return {"records": ["LC-East", "LC-West"], "manual": False, "carriages": 2, "stop_name": "LC-East",
                "stop_limit": 1}
    if "train_state" in code:
        return {"state": "on_the_path", "speed": 0.1}
    if "removed" in code:
        return {"removed": len(units) - 1}
    return {}


def fake_fh(self, action, args=None, wait=False):
    calls.append((action, args))
    if action == "describe":
        return True, {"result": {"actions": {"circuit": {}, "train": {}, "wire": {"color": "red|green"}}}}
    if action == "status":
        return True, {"result": {"position": {"x": 3.2, "y": 4.1}}}
    if action == "build":
        units.append(units[-1] + 1)
        name = args.get("entity") or {"rail": "straight-rail"}.get(args["item"], args["item"])
        return True, {"result": {"consumed": 1, "entity": {"name": name, "position": args["position"],
                                                          "unit_number": units[-1]}}}
    if action == "move_to":
        where["pos"] = args["position"]
        return True, {"result": {"position": args["position"]}}
    if action == "train":
        # As the game: the stop or locomotive must be within reach of where the bot stands (live check 01:31).
        here, at = where["pos"], args["position"]
        if here is None or abs(here["x"] - at["x"]) > 6 or abs(here["y"] - at["y"]) > 6:
            return False, {"error": {"message": f"entity is out of reach (bot at {here}, target {at})"}}
        if "name" in args:  # as the runtime: name is the entity-name filter, not a stop name (live check 00:30)
            return False, {"error": {"message": "unknown argument name for train"}}
        return True, {"result": {"stop": args.get("station"), "automatic": args.get("automatic")}}
    return True, {"result": {}}


class FakeRcon:
    def __init__(self, *a, **k):
        pass


def main():
    L.Check.lua, L.Check.fh = fake_lua, fake_fh
    L.pog.Rcon = FakeRcon
    out = tempfile.mkdtemp()
    os.environ["POG_WORLD"] = "live"
    real_open = open
    pwfile = os.path.join(out, "pw")
    real_open(pwfile, "w").write("x")
    L.os.path.expanduser = lambda p: pwfile if "rcon-" in p else p
    sys.argv = ["live_check_coverage.py", "--out", out]
    try:
        L.main()
    except SystemExit as e:
        code = e.code
    lines = [json.loads(l) for l in real_open(os.path.join(out, "check.jsonl"))]
    fails = [l["step"] for l in lines if not l["ok"]]
    assert code == 0 and not fails, (code, fails)
    steps = [l["step"] for l in lines]
    for want in ("game: chest and inserter wired red", "game: inserter enable iron-plate < 10",
                 "game: combinator sends signal-A=1", "game: lamp enable signal-A > 0", "rails: 16 straight pieces",
                 "game: schedule LC-East, LC-West", "game: train automatic", "game: stop LC-East named, limit 1",
                 "rails: curved-rail-a placed", "cleanup: built entities removed", "cleanup: bot removed"):
        assert want in steps, (want, steps)
    builds = [a for act, a in calls if act == "build"]
    assert sum(1 for b in builds if b["item"] == "rail") == 17  # 16 straight, 1 curved
    assert any(b.get("entity") == "curved-rail-a" for b in builds)
    moves = [a for act, a in calls if act == "move_to"]
    assert len(moves) >= 3, moves  # the bot walks along the site
    wires = [a for act, a in calls if act == "wire"]
    assert all(w["color"] == "red" for w in wires) and len(wires) == 2
    assert any("get_entity_by_unit_number" in c for c in compiled)
    # Run worlds are refused.
    os.environ["POG_WORLD"] = "n"
    try:
        L.main()
        raise AssertionError("world n was not refused")
    except SystemExit as e:
        assert "refusing" in str(e.code), e.code
    print(f"live_check_coverage: ok ({len(steps)} steps, {len(compiled)} Lua snippets compiled)")


if __name__ == "__main__":
    main()
