#!/usr/bin/env python3
"""Bot travel, live on world `sa` (docs/SPACEAGE.md section 3): a bot rides a rocket to a platform, the platform
flies to Vulcanus, the bot lands in a cargo pod, then mines and builds there.

Test setup is operator Lua on `sa` only (refuses a, b, c, n, live): research marked done, a powered rocket silo with
a ready rocket next to the bot, a platform from a starter pack, and (if the platform does not reach Vulcanus within
--fly-minutes on its schedule) the platform moved there by script. Everything the bot does goes through the harness.
Last, an engine probe: does `launch_rocket(dest, character)` take a character with no player, and where does it end?

Needs: the `sa` server running with a client joined (no client: the world stays paused), the RCON tunnel, the runtime
deployed (`POG_WORLD=sa bin/fh deploy`). Usage: tools/sa_travel.py [--bot traveler] [--out runs/sa-travel]
"""
import argparse, json, os, sys, time

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sa_smoke import Smoke, find  # noqa: E402

# Lua below is joined into one line: no comments inside.
SETUP_LUA = r"""
local f = game.forces.player
local s = game.surfaces.nauvis
local out = {researched = {}}
for _, n in ipairs({"rocket-silo", "space-platform", "space-science-pack", "planet-discovery-vulcanus"}) do
  local t = f.technologies[n]
  if t then t.researched = true; out.researched[#out.researched+1] = n end
end
pcall(function() f.unlock_space_location("vulcanus") end)
local at = {x = AT_X, y = AT_Y}
local silo = s.find_entities_filtered{name = "rocket-silo", force = f, limit = 1}[1]
if not silo then
  local pos = s.find_non_colliding_position("rocket-silo", {at.x + 12, at.y}, 40, 1)
  silo = s.create_entity{name = "rocket-silo", position = pos, force = f}
  local sub = s.create_entity{name = "substation", position = {pos.x - 6, pos.y - 6}, force = f}
  local eei = s.create_entity{name = "electric-energy-interface", position = {pos.x - 8, pos.y - 6}, force = f}
  out.power = {substation = sub and true or false, eei = eei and true or false}
end
silo.rocket_parts = silo.prototype.rocket_parts_required
out.silo = silo.position
local pl
for _, p in pairs(f.platforms) do if p.valid and p.name == "travel-test" then pl = p end end
if not pl then
  pl = f.create_space_platform{name = "travel-test", planet = "nauvis", starter_pack = "space-platform-starter-pack"}
  pl.apply_starter_pack()
end
out.platform = {name = pl.name, state = pl.state, at = pl.space_location and pl.space_location.name or nil}
rcon.print(helpers.table_to_json(out))
"""

READY_LUA = r"""
local silo = game.surfaces.nauvis.find_entities_filtered{name = "rocket-silo", force = "player", limit = 1}[1]
local pl
for _, p in pairs(game.forces.player.platforms) do if p.valid and p.name == "travel-test" then pl = p end end
rcon.print(helpers.table_to_json{tick = game.tick, paused = game.tick_paused, silo = silo and silo.rocket_silo_status or nil,
  ready = silo and silo.rocket_silo_status == defines.rocket_silo_status.rocket_ready or false,
  hub = pl and pl.hub and pl.hub.valid or false, at = pl and pl.space_location and pl.space_location.name or nil,
  state = pl and pl.state or nil})
"""

# Move the platform to Vulcanus by script (test setup), trying what the API allows.
MOVE_LUA = r"""
local pl
for _, p in pairs(game.forces.player.platforms) do if p.valid and p.name == "travel-test" then pl = p end end
local tried = {}
local ok, err = pcall(function() pl.space_location = prototypes.space_location.vulcanus end)
tried[#tried+1] = {how = "space_location", ok = ok, err = err and tostring(err) or nil}
if not (pl.space_location and pl.space_location.name == "vulcanus") then
  ok, err = pcall(function()
    pl.space_connection = prototypes.space_connection["nauvis-vulcanus"]
    pl.distance = 0.995
    pl.speed = 0.05
    pl.schedule = {current = 1, records = {{station = "vulcanus"}}}
    pl.paused = false
  end)
  tried[#tried+1] = {how = "connection+distance", ok = ok, err = err and tostring(err) or nil}
end
rcon.print(helpers.table_to_json{tick = game.tick, at = pl.space_location and pl.space_location.name or nil, tried = tried})
"""

# The engine probe: a character with no player as the rocket's rider.
ENGINE_PROBE_LUA = r"""
local f = game.forces.player
local s = game.surfaces.nauvis
local silo = s.find_entities_filtered{name = "rocket-silo", force = f, limit = 1}[1]
local pl
for _, p in pairs(f.platforms) do if p.valid and p.name == "travel-test" then pl = p end end
local out = {tick = game.tick, status = silo.rocket_silo_status}
if silo.rocket_silo_status ~= defines.rocket_silo_status.rocket_ready then out.error = "rocket not ready" rcon.print(helpers.table_to_json(out)) return end
local ch = s.create_entity{name = "character", position = s.find_non_colliding_position("character", silo.position, 20, 1), force = f}
storage.travel_probe = ch
local dest = pl.space_location and pl.space_location.name == "nauvis" and {type = defines.cargo_destination.surface, surface = pl.surface} or {type = defines.cargo_destination.orbit}
local ok, res = pcall(function() return silo.launch_rocket(dest, ch) end)
out.launch_ok = ok
out.launch_result = tostring(res)
out.dest = dest.type == defines.cargo_destination.orbit and "orbit" or "platform"
out.character_valid = ch.valid
rcon.print(helpers.table_to_json(out))
"""

PROBE_WATCH_LUA = r"""
local ch = storage.travel_probe
local out = {tick = game.tick}
if ch and ch.valid then
  out.valid = true
  out.surface = ch.surface.name
  out.position = ch.position
  local ok, v = pcall(function() return ch.vehicle and ch.vehicle.name end)
  out.vehicle = ok and v or nil
else out.valid = false end
rcon.print(helpers.table_to_json(out))
"""


def tick_of(value):
    t = find(value, "tick")
    return t if isinstance(t, int) else None


def poll(s, step, fn, ok, seconds, every=2.0):
    """Call fn() until ok(value) or the time runs out; record the last value."""
    end = time.time() + seconds
    value = None
    while time.time() < end:
        value = fn()
        if value is not None and ok(value):
            s.record(step, True, value)
            return value
        time.sleep(every)
    s.record(step, False, value)
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--world", default="sa")
    ap.add_argument("--bot", default="traveler")
    ap.add_argument("--out", default=os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "runs", "sa-travel"))
    ap.add_argument("--fly-minutes", type=float, default=3.0, help="wall minutes to let the platform fly on its schedule")
    ap.add_argument("--no-engine-probe", action="store_true")
    a = ap.parse_args()
    if a.world in ("a", "b", "c", "n", "live"):
        sys.exit("refusing: test setup runs operator Lua; use world sa")
    s = Smoke(a.world, a.bot, a.out)
    quiet = lambda code: json.loads(s.rcon.command("/silent-command " + " ".join(l.strip() for l in code.strip().splitlines())))

    # 0. The world runs only while a client is joined.
    r = quiet(READY_LUA)
    s.record("world running", not r.get("paused"), r)

    # 1. The bot, standing somewhere on Nauvis; setup next to it.
    s.lua("bot_create", f'local ok,r=pcall(remote.call,"agent_harness","bot_create","{a.bot}") rcon.print(helpers.table_to_json({{ok=ok,r=r}}))')
    st = s.fh("status", "status")
    pos = (st or {}).get("position") or {"x": 0, "y": 0}
    setup = s.lua("setup (operator)", SETUP_LUA.replace("AT_X", str(pos["x"])).replace("AT_Y", str(pos["y"])))
    poll(s, "rocket ready, hub built", lambda: quiet(READY_LUA), lambda v: v.get("ready") and v.get("hub"), 120)
    silo = (setup or {}).get("silo")
    if not silo:
        print(f"{s.fails} failed steps (no silo); log: {os.path.join(a.out, 'smoke.jsonl')}")
        sys.exit(1)

    # 2. Ride up: same payload rule as a player. The bot puts down ammo and inventory first (into a chest it builds).
    s.fh("move_to silo", "move_to", {"position": {"x": silo["x"] - 6, "y": silo["y"]}, "tolerance": 2}, wait=True)
    s.lua("chest for the rest (operator)", f'''
      local s = game.surfaces.nauvis
      local c = s.create_entity{{name = "wooden-chest", position = s.find_non_colliding_position("wooden-chest", {{{silo["x"] - 8}, {silo["y"]}}}, 8, 1), force = "player"}}
      rcon.print(helpers.table_to_json{{chest = c.position}})''')
    chest = find(s.fh("nearest chest", "nearest", {"name": "wooden-chest", "radius": 16, "limit": 1}), "entities")
    inv = s.fh("inventory", "inventory") or {}
    for key in ("inventory", "ammo"):
        for item in (inv.get(key) or []):
            if chest and isinstance(item, dict) and item.get("name"):
                s.fh(f"put down {item['name']}", "transfer", {"position": chest[0]["position"], "item": item["name"],
                                                             "count": item.get("count", 1), "direction": "to_entity"}, wait=True)
    s.fh("launch ride (bot)", "launch", {"position": silo, "platform": "travel-test", "ride": True})
    t0 = tick_of(s.fh("status after launch", "status"))
    up = poll(s, "aboard travel-test", lambda: s.fh("status (riding)", "status"),
              lambda v: (find(v, "travel") or {}).get("state") == "aboard", 180, 3)
    s.record("ascent ticks", up is not None, {"launch_tick": t0, "aboard_tick": tick_of(up)})
    s.fh("platforms (aboard)", "platforms", {"platform": "travel-test"})
    s.fh("move_to aboard (refused)", "move_to", {"position": {"x": 0, "y": 0}})

    # 3. Fly to Vulcanus on the platform's schedule (the bot sets it by remote view); else move it by script.
    s.fh("platform_schedule vulcanus", "platform_schedule",
         {"platform": "travel-test", "stops": [{"station": "vulcanus"}], "paused": False})
    at_v = lambda v: (find(v, "at") == "vulcanus")
    if not poll(s, "platform at vulcanus (flying)", lambda: quiet(READY_LUA), at_v, a.fly_minutes * 60, 5):
        s.lua("move platform (operator)", MOVE_LUA)
        poll(s, "platform at vulcanus (moved)", lambda: quiet(READY_LUA), at_v, 120, 3)

    # 4. Cargo first: the hub holds a furnace and coal (loaded by the operator here; in play a rocket brings them),
    #    the bot drops them to Vulcanus from remote view. Then it lands: a hub cargo pod; the body is made where it lands.
    s.lua("hub cargo (operator)", '''
      local pl
      for _, p in pairs(game.forces.player.platforms) do if p.valid and p.name == "travel-test" then pl = p end end
      local inv = pl.hub.get_inventory(defines.inventory.hub_main)
      rcon.print(helpers.table_to_json{furnace = inv.insert{name = "stone-furnace", count = 1}, coal = inv.insert{name = "coal", count = 10}})''')
    s.fh("drop furnace and coal (aboard)", "drop", {"items": [{"item": "stone-furnace", "count": 1}, {"item": "coal", "count": 10}]})
    land = s.fh("land", "land")
    t1 = tick_of(s.fh("status after land", "status"))
    down = poll(s, "standing on vulcanus", lambda: s.fh("status (landing)", "status"),
                lambda v: v.get("surface") == "vulcanus" and v.get("alive") is True, 180, 3)
    s.record("descent ticks", down is not None, {"land_tick": t1, "standing_tick": tick_of(down), "landed": find(down, "landed"), "at": find(land, "at")})
    s.fh("inventory on vulcanus", "inventory")

    # 5. Unpack the dropped container, mine and build on Vulcanus.
    box = find(s.fh("nearest cargo-pod-container", "nearest", {"name": "cargo-pod-container", "radius": 48, "limit": 1}), "entities")
    if box:
        s.fh("move_to container", "move_to", {"position": box[0]["position"], "tolerance": 2}, wait=True)
        s.fh("take the cargo", "transfer", {"position": box[0]["position"], "direction": "to_player", "inventory": "chest"}, wait=True)
    for res in ("coal", "calcite"):
        rows = find(s.fh(f"nearest {res}", "nearest", {"name": res, "radius": 64, "limit": 1}), "entities")
        if rows:
            s.fh(f"move_to {res}", "move_to", {"position": rows[0]["position"], "tolerance": 1.5}, wait=True)
            s.fh(f"mine {res}", "mine", {"position": rows[0]["position"], "ticks": 300}, wait=True)
    inv = s.fh("inventory before build", "inventory") or {}
    if not any(isinstance(i, dict) and i.get("name") == "stone-furnace" for i in inv.get("inventory") or []):
        s.record("furnace arrived by drop", False, inv)
        s.lua("give stone-furnace (operator fallback)", '''
          local n = 0
          for _, e in pairs(game.surfaces.vulcanus.find_entities_filtered{name = "character", force = "player"}) do n = n + e.insert{name = "stone-furnace", count = 1} end
          rcon.print(helpers.table_to_json{given = n})''')
    me = s.fh("status before build", "status") or {}
    p = me.get("position") or {"x": 0, "y": 0}
    s.fh("build stone-furnace on vulcanus", "build", {"item": "stone-furnace", "position": {"x": round(p["x"]) + 3, "y": round(p["y"])}})
    s.fh("refuel", "refuel", {"radius": 8}, wait=True)
    s.fh("map on vulcanus", "map", {"radius": 16})
    s.fh("final status", "status")
    s.lua("score", __import__("pog").SCORE_LUA)

    # 6. The engine probe (last: if the engine misbehaves, the run above is already logged).
    if not a.no_engine_probe:
        s.lua("rocket parts again (operator)", 'local silo = game.surfaces.nauvis.find_entities_filtered{name = "rocket-silo", force = "player", limit = 1}[1] silo.rocket_parts = silo.prototype.rocket_parts_required rcon.print(helpers.table_to_json{ok = true})')
        poll(s, "rocket ready again", lambda: quiet(READY_LUA), lambda v: v.get("ready"), 120)
        s.lua("engine probe: launch_rocket(dest, playerless character)", ENGINE_PROBE_LUA)
        for i in range(12):
            time.sleep(5)
            s.lua(f"engine probe +{(i + 1) * 5}s", PROBE_WATCH_LUA)
    print(f"{s.fails} failed steps; log: {os.path.join(a.out, 'smoke.jsonl')}")
    sys.exit(1 if s.fails else 0)


if __name__ == "__main__":
    main()
