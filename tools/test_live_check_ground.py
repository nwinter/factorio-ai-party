#!/usr/bin/env python3
"""Offline check for tools/live_check_ground.py: every Lua snippet compiles (luac -p), and with a fake harness and
game answering as a working world, the check runs to the end with every step ok. python3 tools/test_live_check_ground.py"""
import json, os, subprocess, sys, tempfile

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import live_check_coverage as L  # noqa: E402
import live_check_ground as G  # noqa: E402

state = {"tick": 1000, "stacks": 0, "marked": 0, "plates": 0, "pad": False, "seen": set()}
compiled, calls = [], []
PILE = ("items on the ground at (114,202)-(121,204) on nauvis, near our buildings: entities 160 (each an item stack on the ground); "
        "items 1600: 1600 iron-plate; storage slots they fill 16 (at each item's stack size)")
PAD = ("cargo landing pad at (105,207) on nauvis is full (80/80 slots) and pods spill within 40 tiles: entities 30 (each an item stack on "
       "the ground); items 600: 600 coal; storage slots they fill 12 (at each item's stack size)")


def fake_lua(self, code):
    code = L.one_line(code)
    p = subprocess.run(["luac", "-p", "-"], input=code, capture_output=True, text=True)
    assert p.returncode == 0, (p.stderr, code[:300])
    compiled.append(code)
    state["tick"] += 600
    if "connected_players" in code:
        return {"tick": state["tick"], "paused": False, "players": 1}
    if "bot_create" in code:
        return {"ok": True, "bot": {"name": "lg1", "unit_number": 700}}
    if "bot_remove" in code:
        return {"ok": True}
    if "teleport" in code:
        return {"site": {"x": 100, "y": 200}, "given": {"iron-chest": 1}}
    if "cargo_landing_pad_main" in code:
        state["pad"] = True
        return {"unit": 900, "x": 105, "y": 207, "slots": 80, "empty": 0, "spilled": 30, "tick": state["tick"]}
    if "laid" in code:
        state["stacks"] = 160
        return {"laid": 160, "tick": state["tick"]}
    if "removed" in code:
        return {"removed": 3}
    if 'get_item_count("iron-plate")' in code:
        return {"plates": state["plates"]}
    if "get_entity_by_unit_number" in code and "to_be_deconstructed" in code:
        return {"marked": False}
    if "to_be_deconstructed" in code:
        return {"stacks": state["stacks"], "marked": state["marked"], "plates": state["stacks"] * 10}
    if "game.tick" in code:
        return {"tick": state["tick"]}
    return {}


def alerts():
    lines = []
    if state["stacks"]:
        lines.append(PILE)
    if state["pad"]:
        lines.append(PAD)
    team = [l for l in lines if l not in state["seen"]]
    state["seen"].update(lines)
    return {"alerts": {"ground_items": lines} if lines else None, "team": {"alerts": team} if team else None}


def fake_fh(self, action, args=None, wait=False):
    calls.append((action, args, wait))
    if action == "describe":
        return True, {"result": {"actions": {"pickup": {"area": "..."}, "deconstruct": {"items_on_ground": "..."}}}}
    if action == "status":
        return True, {"result": {"position": {"x": 0, "y": 0}, **alerts()}}
    if action == "build":
        return True, {"result": {"entity": {"name": args["item"], "position": args["position"], "unit_number": 800}}}
    if action == "scan":
        if args.get("type") == "item-entity":
            return True, {"result": {"entities": [{"name": "item-on-ground"}] * args["limit"]}}
        return True, {"result": {"entities": [], "ground_items": {"stacks": state["stacks"], "items": [{"name": "iron-plate", "count": state["stacks"] * 10}]}}}
    if action == "observe":
        return True, {"result": {"entities": [], "ground_items": {"stacks": state["stacks"]}}}
    if action == "deconstruct":
        state["marked"] = state["stacks"]
        return True, {"result": {"item_stacks": state["stacks"]}}
    if action == "cancel_deconstruction":
        n, state["marked"] = state["marked"], 0
        return True, {"result": {"item_stacks_cancelled": n}}
    if action == "pickup":
        if not state["stacks"]:
            return False, {"error": {"message": "no items on the ground in (113,200)-(124,206)"}}
        assert wait and args["area"]["right_bottom"]["x"] - args["area"]["left_top"]["x"] <= 64
        state["plates"] += state["stacks"] * 10
        state["stacks"] = 0
        return True, {"result": {"accepted": {"item_stacks": 160}, "completion": {"last": {"kind": "pickup", "outcome": "picked_up"}}}}
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
    sys.argv = ["live_check_ground.py", "--out", out]
    code = None
    try:
        G.main()
    except SystemExit as e:
        code = e.code
    lines = [json.loads(l) for l in open(os.path.join(out, "check.jsonl"))]
    fails = [l["step"] for l in lines if not l["ok"]]
    assert code == 0 and not fails, (code, fails)
    steps = [l["step"] for l in lines]
    for want in ("game clock runs (a client connected, not auto-paused)", "status alerts.ground_items names the pile",
                 "the reply's team.alerts carries it once", "not repeated on the next reply",
                 "scan: ground_items 160 stacks, 1600 iron-plate, no rows", "game: all 160 stacks marked for deconstruction",
                 "game: no stack marked after cancel", "pickup area: picked_up, area empty, bot holds the plates",
                 "pickup on an empty area is refused", "status alerts.ground_items names the full pad and the spill",
                 "cleanup: bot removed"):
        assert want in steps, (want, steps)
    # The pile lies in one 64-tile cell.
    assert G.widest(112, 135) == (112, 128) and G.widest(140, 153) == (140, 153), (G.widest(112, 135), G.widest(140, 153))
    # Run worlds are refused.
    os.environ["POG_WORLD"] = "n"
    try:
        G.main()
        raise AssertionError("world n was not refused")
    except SystemExit as e:
        assert "refusing" in str(e.code), e.code
    print(f"live_check_ground: ok ({len(steps)} steps, {len(compiled)} Lua snippets compiled)")


if __name__ == "__main__":
    main()
