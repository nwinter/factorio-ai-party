#!/usr/bin/env python3
"""Offline check for tools/live_check_vehicles.py: every Lua snippet compiles, and with a fake harness and game the
check runs to the end with every step ok. python3 tools/test_live_check_vehicles.py"""
import json, os, re, subprocess, sys, tempfile

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import live_check_coverage as L  # noqa: E402
import live_check_vehicles as V  # noqa: E402

state = {"seat": None, "car": None, "units": {}}
compiled, calls, units = [], [], [200]


def fake_lua(self, code):
    code = L.one_line(code)
    p = subprocess.run(["luac", "-p", "-"], input=code, capture_output=True, text=True)
    assert p.returncode == 0, (p.stderr, code[:300])
    compiled.append(code)
    if "bot_create" in code:
        return {"ok": True, "bot": {"name": "lv1", "unit_number": 655}}
    if "bot_remove" in code:
        return {"ok": True}
    if "get_driver" in code:
        unit = int(re.search(r"get_entity_by_unit_number\((\d+)\)", code).group(1))
        name = state["units"].get(unit)
        pos = state["car"] if name == "car" else {"x": 0, "y": 0}
        return {"name": name, "x": pos["x"], "y": pos["y"], "driver": 655 if state["seat"] == name else None}
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
        state["units"][units[-1]] = name
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
            # As main's CLI: vehicle returns at once; the car gets there while the bot waits (fh wait).
            state["pending"] = dict(args["drive"])
            return True, {"result": {"until_tick": 999, "target": args["drive"]}}
        if args.get("go_to"):
            return True, {"result": {"go_to": args["go_to"]}}
    if action == "move_to" and state["seat"]:
        return False, {"error": {"message": "the character is in a vehicle: vehicle {exit: true} gets out"}}
    return True, {"result": {}}


def fake_fh_command(self, words):
    calls.append((words[0], {}, False))
    if words[0] == "wait" and state.get("pending"):
        state["car"], state["pending"] = state["pending"], None
        return True, {"result": {"idle": True, "last": {"kind": "drive", "outcome": "arrived"}}}
    return True, {"result": {"idle": True}}


class FakeRcon:
    def __init__(self, *a, **k):
        pass


def main():
    L.Check.lua, L.Check.fh, L.Check.fh_command = fake_lua, fake_fh, fake_fh_command
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
    assert any(act == "transfer" and a.get("item") == "rocket-fuel" for act, a, _ in calls), "the spidertron is fuelled"
    drive_at = next(i for i, (act, a, _) in enumerate(calls) if act == "vehicle" and a.get("drive"))
    assert calls[drive_at + 1][0] == "wait", "the drive is waited for with fh wait before the car is read"
    for want in ("game: the bot sits in the car (its driver)", "seated move_to refused, pointing to exit", "seated say works",
                 "game: the car got there", "game: the bot is on foot", "game: the bot sits in the locomotive",
                 "spidertron destination accepted", "cleanup: bot removed"):
        assert want in steps, (want, steps)
    print(f"live_check_vehicles: ok ({len(steps)} steps, {len(compiled)} Lua snippets compiled)")


if __name__ == "__main__":
    main()
