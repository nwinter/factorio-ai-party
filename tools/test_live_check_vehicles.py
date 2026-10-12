#!/usr/bin/env python3
"""Offline check for tools/live_check_vehicles.py: every Lua snippet compiles, and with a fake harness and game the
check runs to the end with every step ok. python3 tools/test_live_check_vehicles.py"""
import json, os, subprocess, sys, tempfile

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import live_check_coverage as L  # noqa: E402
import live_check_vehicles as V  # noqa: E402

state = {"seat": None, "car": None}
compiled, calls, units = [], [], [200]


def fake_lua(self, code):
    code = L.one_line(code)
    p = subprocess.run(["luac", "-p", "-"], input=code, capture_output=True, text=True)
    assert p.returncode == 0, (p.stderr, code[:300])
    compiled.append(code)
    if "bot_create" in code or "bot_remove" in code:
        return {"ok": True}
    if "teleport" in code:
        return {"site": {"x": 100, "y": 200}, "given": {"car": 1}}
    if "removed" in code:
        return {"removed": 6}
    if "body.vehicle.position" in code:
        return {"x": state["car"]["x"], "y": state["car"]["y"]}
    if "body.vehicle ~= nil" in code:
        return {"vehicle": state["seat"] is not None, "x": 128}
    if "body.vehicle.name" in code:
        return {"vehicle": state["seat"]} if state["seat"] else {}
    if "get_entity_by_unit_number" in code and "removed" not in code:
        return {"x": 132.5, "y": 204.5}
    return {}


def fake_fh(self, action, args=None, wait=False):
    calls.append((action, args, wait))
    if action == "describe":
        return True, {"result": {"actions": {"vehicle": {}}}}
    if action == "status":
        return True, {"result": {"position": {"x": 0, "y": 0}}}
    if action == "build":
        units.append(units[-1] + 1)
        name = {"rail": "straight-rail"}.get(args["item"], args["item"])
        if name == "car":
            state["car"] = dict(args["position"])
        return True, {"result": {"entity": {"name": name, "position": args["position"], "unit_number": units[-1]}}}
    if action == "vehicle":
        if args.get("enter"):
            state["seat"] = "car" if state["car"] and args["position"] == state["car"] and state.get("left_car") is None else "locomotive"
            return True, {"result": {"vehicle": {"name": state["seat"]}}}
        if args.get("exit"):
            if state["seat"] == "car":
                state["left_car"] = True
            state["seat"] = None
            return True, {"result": {"vehicle": False}}
        if args.get("drive"):
            assert wait, "drive is waited for"
            state["car"] = dict(args["drive"])
            return True, {"result": {"outcome": "arrived"}}
        if args.get("go_to"):
            return True, {"result": {"go_to": args["go_to"]}}
    if action == "move_to" and state["seat"]:
        return False, {"error": {"message": "the character is in a vehicle: vehicle {exit: true} gets out"}}
    return True, {"result": {}}


class FakeRcon:
    def __init__(self, *a, **k):
        pass


def main():
    L.Check.lua, L.Check.fh = fake_lua, fake_fh
    L.pog.Rcon = FakeRcon
    V.time.sleep = lambda s: None
    out = tempfile.mkdtemp()
    pwfile = os.path.join(out, "pw")
    open(pwfile, "w").write("x")
    L.os.path.expanduser = lambda p: pwfile if "rcon-" in p else p
    os.environ["POG_WORLD"] = "live"
    sys.argv = ["live_check_vehicles.py", "--out", out]
    code = None
    try:
        V.main()
    except SystemExit as e:
        code = e.code
    lines = [json.loads(l) for l in open(os.path.join(out, "check.jsonl"))]
    fails = [l["step"] for l in lines if not l["ok"]]
    assert code == 0 and not fails, (code, fails)
    steps = [l["step"] for l in lines]
    for want in ("game: the bot sits in the car", "seated move_to refused, pointing to exit", "seated say works",
                 "game: the car got there", "game: the bot is on foot", "game: the bot sits in the locomotive",
                 "spidertron destination accepted", "cleanup: bot removed"):
        assert want in steps, (want, steps)
    print(f"live_check_vehicles: ok ({len(steps)} steps, {len(compiled)} Lua snippets compiled)")


if __name__ == "__main__":
    main()
