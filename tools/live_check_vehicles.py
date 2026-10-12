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

ITEMS = {"car": 1, "coal": 50, "rail": 6, "locomotive": 1, "spidertron": 1}


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--bot", default="lv1")
    ap.add_argument("--keep", action="store_true")
    ap.add_argument("--out", default=os.path.join(L.ROOT, "runs", "live-check-vehicles"))
    a = ap.parse_args()
    world = os.environ.get("POG_WORLD", "live")
    if world in ("a", "b", "c", "n"):
        sys.exit(f"refusing: {world} is a run world; this check builds and deletes things")
    c = L.Check(world, a.bot, a.out)
    ok, desc = c.fh("describe")
    if not c.record("runtime has vehicle", ok and "vehicle" in ((desc.get("result") or {}).get("actions") or {}), None):
        sys.exit(f"deploy the eng/coverage2 runtime first: POG_WORLD={world} bin/fh deploy (from that branch)")
    c.record("bot_create", True, c.lua(f'rcon.print(remote.call("agent_harness","bot_create","{a.bot}"))'))
    ok, st = c.fh("status")
    pos = (st.get("result") or {}).get("position")
    if not c.record("bot status", ok and pos is not None, pos):
        sys.exit(1)
    stage = c.lua(L.stage_lua(pos, ITEMS))
    if not c.record("stage: site and items", "site" in stage, stage):
        sys.exit(1)
    ox, oy = stage["site"]["x"], stage["site"]["y"]
    c.here = (ox + 4, oy - 2)

    def body_lua(expr):
        return c.lua(f"""
          local s = game.surfaces.nauvis
          local body
          for _, e in pairs(s.find_entities_filtered{{type="character", area={{{{{ox - 10}, {oy - 10}}}, {{{ox + 60}, {oy + 30}}}}}}}) do
            if not e.player then body = e end
          end
          rcon.print(helpers.table_to_json({expr}))
        """)

    # Car: in, seated guard, drive, out.
    car = c.build("car", "car", ox + 6.5, oy + 2.5, "east")
    if car:
        c.step("fuel the car", "transfer", {"position": car["position"], "item": "coal", "count": 20, "direction": "to_entity"})
        seat = c.step("vehicle enter car", "vehicle", {"position": car["position"], "enter": True})
        got = body_lua('{vehicle = body and body.vehicle and body.vehicle.name, driving = body and body.driving}')
        c.record("game: the bot sits in the car", seat is not None and got.get("vehicle") == "car", got)
        ok, reply = c.fh("move_to", {"position": {"x": ox, "y": oy}})
        msg = ((reply.get("error") or {}).get("message") or "")
        c.record("seated move_to refused, pointing to exit", not ok and "vehicle {exit: true}" in msg, msg[:200])
        ok, _ = c.fh("say", {"text": "live check: talking from the car"})
        c.record("seated say works", ok, None)
        target = {"x": car["position"]["x"] + 20, "y": car["position"]["y"]}
        drive = c.step("vehicle drive 20 tiles east (--wait)", "vehicle", {"drive": target}, wait=True)
        got = body_lua('{x = body and body.vehicle and body.vehicle.position.x, y = body and body.vehicle and body.vehicle.position.y}')
        there = got.get("x") is not None and abs(got["x"] - target["x"]) < 5 and abs(got["y"] - target["y"]) < 5
        c.record("game: the car got there", there, {"car": got, "target": target, "reply": drive})
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
            got = body_lua('{vehicle = body and body.vehicle and body.vehicle.name}')
            c.record("game: the bot sits in the locomotive", seat is not None and got.get("vehicle") == "locomotive", got)
            c.step("vehicle exit locomotive", "vehicle", {"exit": True})
    # Spidertron sent 10 tiles by go_to (informational: it walks only with room and, in some versions, fuel).
    spider = c.build("spidertron", "spidertron", ox + 20.5, oy + 4.5)
    if spider:
        dest = {"x": spider["position"]["x"] + 10, "y": spider["position"]["y"]}
        sent = c.step("vehicle go_to spidertron", "vehicle", {"position": spider["position"], "go_to": dest})
        c.record("spidertron destination accepted", sent is not None, sent)
        time.sleep(8)
        got = c.lua(f"""
          local e = game.get_entity_by_unit_number({spider.get('unit_number') or 0})
          rcon.print(helpers.table_to_json{{x = e and e.position.x, y = e and e.position.y}})
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
