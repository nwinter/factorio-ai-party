#!/usr/bin/env python3
"""Live check for vehicles (eng/coverage2: vehicle enter/exit/drive/go_to and the seated guard) on a test world.

  POG_WORLD=live python3 tools/live_check_vehicles.py [--bot lv1] [--keep]

Deploy the eng/coverage2 runtime on that world first (POG_WORLD=live bin/fh deploy from that branch); main's runtime
has no vehicle action and the check stops at once. Same method as tools/live_check_coverage.py: a test bot acts
through bin/fh, operator Lua stages and reads back, ok/FAIL per step, cleanup at the end. Refuses a, b, c, n.

Steps: a car with coal: get in (the game seats the bot), a seated move_to is refused and a seated say works, drive 20
tiles east (arrived; the car is there), get out (the bot is on foot); a locomotive on a short track: get in, get out;
a spidertron sent 10 tiles with go_to (moved: informational, it may need fuel or legs room).
"""
import argparse, os, sys, time

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import live_check_coverage as L  # noqa: E402

ITEMS = {"car": 1, "coal": 50, "rail": 6, "locomotive": 1, "spidertron": 1, "rocket-fuel": 4}


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--bot", default="lv1")
    ap.add_argument("--keep", action="store_true")
    ap.add_argument("--out", default=os.path.join(L.ROOT, "runs", "live-check-vehicles"))
    L.add_site_arg(ap)
    a = ap.parse_args()
    world = os.environ.get("POG_WORLD", "live")
    if world in ("a", "b", "c", "n"):
        sys.exit(f"refusing: {world} is a run world; this check builds and deletes things")
    c = L.Check(world, a.bot, a.out)
    ok, desc = c.fh("describe")
    if not c.record("runtime has vehicle", ok and "vehicle" in ((desc.get("result") or {}).get("actions") or {}), None):
        sys.exit(f"deploy the eng/coverage2 runtime first: POG_WORLD={world} bin/fh deploy (from that branch)")
    if not c.game_running():
        sys.exit(L.PAUSED_HINT)
    created = c.lua(f'rcon.print(remote.call("agent_harness","bot_create","{a.bot}"))')
    bot_unit = ((created or {}).get("bot") or {}).get("unit_number")
    if not c.record("bot_create", bot_unit is not None, created):
        sys.exit(1)
    ok, st = c.fh("status")
    pos = (st.get("result") or {}).get("position")
    if not c.record("bot status", ok and pos is not None, pos):
        sys.exit(1)
    stage = c.lua(L.stage_lua(pos, ITEMS, L.parse_site(a.site)))
    if not c.record("stage: site and items", "site" in stage, stage):
        sys.exit(1)
    ox, oy = stage["site"]["x"], stage["site"]["y"]
    c.here = (ox + 4, oy - 2)

    # Read back by unit number: a character seated in a vehicle is not found by an area search (live check 00:40).
    def body_lua(expr):
        return c.lua(f"""
          local body = game.get_entity_by_unit_number({bot_unit})
          rcon.print(helpers.table_to_json({expr}))
        """)

    def vehicle_lua(unit):
        """The vehicle as the game holds it: position, speed, and who sits in it (unit numbers)."""
        return c.lua(f"""
          local v = game.get_entity_by_unit_number({unit or 0})
          local function who(x) if not x then return nil end if x.object_name == "LuaPlayer" then return x.character and x.character.unit_number end return x.unit_number end
          local d = v and who(v.get_driver())
          local ok, pa = pcall(function() return v and who(v.get_passenger()) end)
          rcon.print(helpers.table_to_json{{name = v and v.name, x = v and v.position.x, y = v and v.position.y,
            speed = v and v.speed, driver = d, passenger = ok and pa or nil}})
        """)

    # Car: in, seated guard, drive, out.
    car = c.build("car", "car", ox + 6.5, oy + 2.5, "east")
    if car:
        c.step("fuel the car", "transfer", {"position": car["position"], "item": "coal", "count": 20, "direction": "to_entity"})
        seat = c.step("vehicle enter car", "vehicle", {"position": car["position"], "enter": True})
        got = vehicle_lua(car.get("unit_number"))
        c.record("game: the bot sits in the car (its driver)", seat is not None and got.get("driver") == bot_unit,
                 {"car": got, "bot": bot_unit, "reply": seat})
        ok, reply = c.fh("move_to", {"position": {"x": ox, "y": oy}})
        msg = ((reply.get("error") or {}).get("message") or "")
        c.record("seated move_to refused, pointing to exit", not ok and "vehicle {exit: true}" in msg, msg[:200])
        ok, _ = c.fh("say", {"text": "live check: talking from the car"})
        c.record("seated say works", ok, None)
        target = {"x": car["position"]["x"] + 20, "y": car["position"]["y"]}
        drive = c.step("vehicle drive 20 tiles east", "vehicle", {"drive": target})
        # Wait with fh wait (every CLI has it; a CLI older than eng/coverage2 returns from vehicle at once, and the
        # 03:5x run read the car while it was starting, then got out: live-check-vehicles-2.jsonl).
        ok, waited = c.fh_command(["wait", "--wait-timeout", "90000"])
        last = (waited.get("result") or {}).get("last") or {}
        got = vehicle_lua(car.get("unit_number"))
        there = got.get("x") is not None and abs(got["x"] - target["x"]) < 5 and abs(got["y"] - target["y"]) < 5
        c.record("game: the car got there", there, {"car": got, "target": target, "outcome": last.get("outcome"),
                                                     "reply": drive})
        out = c.step("vehicle exit", "vehicle", {"exit": True})
        got = body_lua('{vehicle = body and body.vehicle ~= nil, x = body and body.position.x}')
        c.record("game: the bot is on foot", out is not None and got.get("vehicle") is False, got)
        if got.get("x") is not None:
            c.here = (got["x"], oy)
    # Locomotive on three straight rails: in and out.
    rails = [c.build(f"rail {k + 1}", "rail", ox + 1 + 2 * k, oy + 9, "east") for k in range(3)]
    if all(rails):
        loco = c.build("locomotive", "locomotive", rails[1]["position"]["x"], rails[1]["position"]["y"], "east")
        if loco:
            seat = c.step("vehicle enter locomotive", "vehicle", {"position": loco["position"], "enter": True})
            got = vehicle_lua(loco.get("unit_number"))
            c.record("game: the bot sits in the locomotive", seat is not None and got.get("driver") == bot_unit, got)
            c.step("vehicle exit locomotive", "vehicle", {"exit": True})
    # Spidertron fuelled, then sent 10 tiles by go_to (whether it walks: informational, it needs room for its legs).
    spider = c.build("spidertron", "spidertron", ox + 20.5, oy + 4.5)
    if spider:
        c.step("fuel the spidertron", "transfer", {"position": spider["position"], "item": "rocket-fuel", "count": 2,
                                                    "direction": "to_entity"})
        dest = {"x": spider["position"]["x"] + 10, "y": spider["position"]["y"]}
        sent = c.step("vehicle go_to spidertron", "vehicle", {"position": spider["position"], "go_to": dest})
        c.record("spidertron destination accepted", sent is not None, sent)
        time.sleep(15)
        # What the game holds for it, so a spidertron that stays put says why (destinations, fuel, speed).
        got = c.lua(f"""
          local e = game.get_entity_by_unit_number({spider.get('unit_number') or 0})
          local out = {{x = e and e.position.x, y = e and e.position.y}}
          if e then
            pcall(function() out.destinations = #(e.autopilot_destinations or {{}}) end)
            pcall(function() out.destination = e.autopilot_destination end)
            pcall(function() out.speed = e.speed end)
            pcall(function() out.burning = e.burner and e.burner.currently_burning and e.burner.currently_burning.name.name end)
            pcall(function() local f = e.get_fuel_inventory(); out.fuel = f and f.get_item_count() end)
            pcall(function() out.driver = e.get_driver() ~= nil end)
          end
          rcon.print(helpers.table_to_json(out))
        """)
        moved = got.get("x") is not None and abs(got["x"] - spider["position"]["x"]) > 3
        c.record("spidertron moved (informational)", True, {"moved": moved, "now": got})

    if a.keep:
        print(f"--keep: left the site at ({ox},{oy}) and bot {a.bot}")
    else:
        gone = c.lua(L.cleanup_lua(c.built, ox, oy, ["car", "spidertron", "locomotive", "straight-rail"]))
        c.record("cleanup: built entities removed", "removed" in gone, gone)
        c.record("cleanup: bot removed", True, c.lua(f'rcon.print(remote.call("agent_harness","bot_remove","{a.bot}"))'))
    fails = [s for s, ok in c.results if not ok]
    print(f"\n{len(c.results) - len(fails)} ok, {len(fails)} failed" + (": " + "; ".join(fails) if fails else ""))
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
