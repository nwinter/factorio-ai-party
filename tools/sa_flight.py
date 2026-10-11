#!/usr/bin/env python3
"""A real flight on world `sa` (docs/SPACEAGE.md section 5): a bot rides a rocket to the test platform at Nauvis, sets
its schedule to Vulcanus, and the platform flies there on its own thrusters; then the bot lands. A director camera
follows the bot the whole way (Nauvis, the pod up, the platform in flight, the pod down, Vulcanus) and the director
client takes a screenshot at each stage.

Test setup is operator Lua on `sa` only (refuses a, b, c, n, live): the platform `travel-test` put back at Nauvis,
foundation, two thrusters kept fuelled by script (no fuel production on a test platform), four gun turrets with
ammo, the hub repaired, a ready rocket. Everything the bot does goes through the harness; the camera goes through
the harness `camera` remote call, as tools/stream/director.py sends it.

Needs: sa running with the director client (pog-sa) joined, the RCON tunnel, the runtime deployed. Screenshots land in
the director client's script-output/pog/sa-flight/. Usage: tools/sa_flight.py [--bot flyer] [--director pog-sa]
"""
import argparse, json, os, sys, time

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sa_smoke import Smoke, find  # noqa: E402

# Lua below is joined into one line: no comments inside.
PLATFORM = r"""
local pl
for _, p in pairs(game.forces.player.platforms) do if p.valid and p.name == "travel-test" then pl = p end end
"""

SETUP_LUA = PLATFORM + r"""
local f = game.forces.player
local out = {tick = game.tick}
pl.schedule = nil
pl.paused = true
if not (pl.space_location and pl.space_location.name == "nauvis") then
  local ok, err = pcall(function() pl.space_location = prototypes.space_location.nauvis end)
  out.moved = {ok = ok, err = err and tostring(err) or nil}
end
local s = pl.surface
local hub = pl.hub
out.hub_before = hub.health
hub.health = hub.max_health
out.hub_max = hub.max_health
local tiles = {}
for x = -16, 15 do for y = -16, 23 do
  if s.get_tile(x, y).name ~= "space-platform-foundation" then tiles[#tiles+1] = {name = "space-platform-foundation", position = {x, y}} end
end end
s.set_tiles(tiles)
out.tiles = #tiles
local th = s.find_entities_filtered{name = "thruster"}
for _, x in ipairs({-6, 6}) do
  if #th < 2 then
    local pos = s.find_non_colliding_position("thruster", {x, 16}, 8, 1)
    local e = pos and s.create_entity{name = "thruster", position = pos, force = f}
    if e then th[#th+1] = e end
  end
end
out.thrusters = {}
for _, e in ipairs(th) do
  local fuel = e.insert_fluid{name = "thruster-fuel", amount = 100000}
  local ox = e.insert_fluid{name = "thruster-oxidizer", amount = 100000}
  out.thrusters[#out.thrusters+1] = {position = e.position, fuel = fuel, oxidizer = ox}
end
local guns = s.find_entities_filtered{name = "gun-turret"}
for _, p in ipairs({{-12, -12}, {12, -12}, {-12, 2}, {12, 2}}) do
  if #guns < 4 then
    local pos = s.find_non_colliding_position("gun-turret", p, 6, 1)
    local e = pos and s.create_entity{name = "gun-turret", position = pos, force = f}
    if e then guns[#guns+1] = e end
  end
end
out.turrets = {}
for _, e in ipairs(guns) do out.turrets[#out.turrets+1] = {position = e.position, ammo = e.insert{name = "piercing-rounds-magazine", count = 200}} end
local silo = game.surfaces.nauvis.find_entities_filtered{name = "rocket-silo", force = f, limit = 1}[1]
silo.rocket_parts = silo.prototype.rocket_parts_required
out.silo = silo.position
out.state = pl.state
out.at = pl.space_location and pl.space_location.name or nil
rcon.print(helpers.table_to_json(out))
"""

# One sample: the platform, its damage, the thrusters (refilled here: the operator's fuel), the director, the tags.
SAMPLE_LUA = PLATFORM + r"""
local states = {}
for k, v in pairs(defines.space_platform_state) do states[v] = k end
local s = pl.surface
local out = {tick = game.tick, state = states[pl.state], at = pl.space_location and pl.space_location.name or nil,
  connection = pl.space_connection and pl.space_connection.name or nil, distance = pl.distance, speed = pl.speed,
  hub = pl.hub and pl.hub.valid and pl.hub.health or nil, damaged = {}, refill = 0, ammo = 0, entities = 0}
for _, e in pairs(s.find_entities_filtered{force = "player"}) do
  out.entities = out.entities + 1
  if e.max_health and e.max_health > 0 and e.health and e.health < e.max_health then out.damaged[#out.damaged+1] = {name = e.name, health = e.health, max = e.max_health} end
end
for _, e in pairs(s.find_entities_filtered{name = "thruster"}) do
  out.refill = out.refill + e.insert_fluid{name = "thruster-fuel", amount = 100000} + e.insert_fluid{name = "thruster-oxidizer", amount = 100000}
end
for _, e in pairs(s.find_entities_filtered{name = "gun-turret"}) do out.ammo = out.ammo + e.get_item_count("piercing-rounds-magazine") end
out.asteroids = #s.find_entities_filtered{type = "asteroid"}
local d = game.get_player("DIRECTOR")
if d then out.director = {index = d.index, surface = d.surface.name, position = d.position, controller = d.controller_type, connected = d.connected, zoom = d.zoom} end
out.tags = {}
local ok, objs = pcall(rendering.get_all_objects, "agent-harness")
if ok then for _, o in pairs(objs) do
  if o.valid and o.type == "text" then
    local tgt = o.target
    out.tags[#out.tags+1] = {text = o.text, surface = o.surface.name, on = tgt and tgt.entity and tgt.entity.valid and tgt.entity.name or nil}
  end
end end
local sprites = 0
if ok then for _, o in pairs(objs) do if o.valid and o.type == "sprite" then sprites = sprites + 1 end end end
out.sprites = sprites
rcon.print(helpers.table_to_json(out))
"""

CAMERA_LUA = r"""
local r = remote.call("agent_harness", "camera", [[BODY]])
local l = remote.call("agent_harness", "cameras")
rcon.print(helpers.table_to_json{set = type(r) == "string" and helpers.json_to_table(r) or r, list = type(l) == "string" and helpers.json_to_table(l) or l})
"""

SHOT_LUA = r"""
local d = game.get_player("DIRECTOR")
game.take_screenshot{player = d, by_player = d, path = "pog/sa-flight/NAME.png", resolution = {x = 1280, y = 720}, show_entity_info = true}
rcon.print(helpers.table_to_json{tick = game.tick, path = "pog/sa-flight/NAME.png", surface = d.surface.name, position = d.position})
"""

MOVE_LUA = PLATFORM + r"""
local ok, err = pcall(function() pl.space_location = prototypes.space_location.vulcanus end)
rcon.print(helpers.table_to_json{tick = game.tick, ok = ok, err = err and tostring(err) or nil, at = pl.space_location and pl.space_location.name or nil})
"""


def R(reply):
    """The result of an fh reply ({id, ok, tick, result})."""
    return reply.get("result") or {} if isinstance(reply, dict) else {}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--world", default="sa")
    ap.add_argument("--bot", default="flyer")
    ap.add_argument("--director", default="pog-sa")
    ap.add_argument("--out", default=os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "runs", "sa-flight"))
    ap.add_argument("--fly-minutes", type=float, default=15.0, help="wall minutes to wait for the platform to reach Vulcanus")
    ap.add_argument("--resume-aboard", action="store_true", help="the bot is already aboard travel-test at Nauvis: fly, land")
    a = ap.parse_args()
    if a.world in ("a", "b", "c", "n", "live"):
        sys.exit("refusing: test setup runs operator Lua; use world sa")
    s = Smoke(a.world, a.bot, a.out)
    one = lambda code: " ".join(l.strip() for l in code.strip().splitlines())
    raw = lambda code: json.loads(s.rcon.command("/silent-command " + one(code)))
    sample_lua = SAMPLE_LUA.replace("DIRECTOR", a.director)

    def sample(step):
        return s.lua(step, sample_lua)

    def camera(step, body):
        return s.lua(step, CAMERA_LUA.replace("BODY", json.dumps(dict(body, player=director_index))))

    def shot(name):
        return s.lua(f"screenshot {name}", SHOT_LUA.replace("DIRECTOR", a.director).replace("NAME", name))

    def poll(step, fn, ok, seconds, every=3.0, each=None):
        end, value, n = time.time() + seconds, None, 0
        while time.time() < end:
            value = fn()
            n += 1
            if each:
                each(n, value)
            if value is not None and ok(value):
                s.record(step, True, value)
                return value
            time.sleep(every)
        s.record(step, False, value)
        return None

    first = sample("world and director")
    director_index = (first or {}).get("director", {}).get("index")
    if not director_index:
        print(f"no director named {a.director} is connected; log: {os.path.join(a.out, 'smoke.jsonl')}")
        sys.exit(1)

    if not a.resume_aboard:
        # 1. Test setup: the platform back at Nauvis with thrusters, fuel, turrets; a ready rocket.
        s.lua("bot_create", f'local ok,r=pcall(remote.call,"agent_harness","bot_create","{a.bot}") rcon.print(helpers.table_to_json({{ok=ok,r=r}}))')
        setup = s.lua("flight setup (operator)", SETUP_LUA)
        silo = (setup or {}).get("silo")
        if not silo:
            print(f"{s.fails} failed steps (no silo); log: {os.path.join(a.out, 'smoke.jsonl')}")
            sys.exit(1)
        camera("camera follow (nauvis)", {"follow": a.bot, "zoom": 1})
        time.sleep(2)
        sample("camera on nauvis")
        shot("1-nauvis")

        # 2. Ride up: the bot sets down everything but armor and guns, then rides.
        s.fh("move_to silo", "move_to", {"position": {"x": silo["x"] - 6, "y": silo["y"]}, "tolerance": 2}, wait=True)
        s.lua("chest for the rest (operator)", f'''
          local s = game.surfaces.nauvis
          local c = s.create_entity{{name = "wooden-chest", position = s.find_non_colliding_position("wooden-chest", {{{silo["x"] - 8}, {silo["y"] + 3}}}, 8, 1), force = "player"}}
          rcon.print(helpers.table_to_json{{chest = c.position}})''')
        chest = find(s.fh("nearest chest", "nearest", {"name": "wooden-chest", "radius": 16, "limit": 1}), "entities")
        inv = R(s.fh("inventory", "inventory"))
        for key in ("inventory", "ammo"):
            for item in (inv.get(key) or []):
                if chest and isinstance(item, dict) and item.get("name"):
                    s.fh(f"put down {item['name']}", "transfer", {"position": chest[0]["position"], "item": item["name"],
                                                                 "count": item.get("count", 1), "direction": "to_entity"}, wait=True)
        poll("rocket ready", lambda: raw(PLATFORM + 'local silo = game.surfaces.nauvis.find_entities_filtered{name = "rocket-silo", force = "player", limit = 1}[1] rcon.print(helpers.table_to_json{tick = game.tick, ready = silo.rocket_silo_status == defines.rocket_silo_status.rocket_ready, hub = pl.hub and pl.hub.valid or false})'),
             lambda v: v.get("ready") and v.get("hub"), 120)
        launch = s.fh("launch ride (bot)", "launch", {"position": silo, "platform": "travel-test", "ride": True})
        t_launch = (launch or {}).get("tick")
        pod_seen = {}

        def during_ascent(n, v):
            tr = R(v).get("travel") or {}
            if tr.get("state") == "ascending" and n in (3, 6):
                sample(f"camera on the pod going up ({n})")
                if not pod_seen:
                    pod_seen["shot"] = shot("2-pod-up")
        up = poll("aboard travel-test", lambda: s.fh("status (riding)", "status"),
                  lambda v: (R(v).get("travel") or {}).get("state") == "aboard", 180, 3, during_ascent)
        s.record("ascent ticks", up is not None, {"launch_tick": t_launch, "aboard_tick": (up or {}).get("tick")})
        time.sleep(3)
        sample("camera aboard (at nauvis)")
        shot("3-aboard-nauvis")

    # 3. The flight: the bot sets the schedule by remote view; the platform flies on its thrusters.
    sched = s.fh("platform_schedule vulcanus (bot)", "platform_schedule",
                 {"platform": "travel-test", "stops": [{"station": "vulcanus"}], "paused": False})
    t_sched = (sched or {}).get("tick")
    marks = {}

    def during_flight(n, v):
        if not v:
            return
        if "departed" not in marks and v.get("at") is None:
            marks["departed"] = v["tick"]
            s.record("departed", True, v)
        if v.get("damaged"):
            marks.setdefault("first_damage", v["tick"])
        if "departed" in marks and "mid" not in marks and (v.get("distance") or 0) >= 0.4:
            marks["mid"] = v["tick"]
            s.lua("camera list (in flight)", CAMERA_LUA.replace("BODY", json.dumps({"player": director_index, "follow": a.bot, "zoom": 0.5})))
            shot("4-in-flight")
    arrived = poll("platform at vulcanus (own thrusters)", lambda: s.lua("flight sample", sample_lua),
                   lambda v: v.get("at") == "vulcanus", a.fly_minutes * 60, 5, during_flight)
    s.record("flight ticks", arrived is not None, {"schedule_tick": t_sched, "departed_tick": marks.get("departed"),
                                                   "first_damage_tick": marks.get("first_damage"), "mid_tick": marks.get("mid"),
                                                   "arrived_tick": (arrived or {}).get("tick"),
                                                   "hub": (arrived or {}).get("hub"), "damaged": (arrived or {}).get("damaged")})
    if not arrived:
        s.lua("move platform (operator fallback)", MOVE_LUA)
    camera("camera follow (zoom 1, at vulcanus)", {"follow": a.bot, "zoom": 1})
    time.sleep(2)
    shot("5-aboard-vulcanus")

    # 4. Land: a hub cargo pod down; the camera follows the pod, then the new body.
    land = s.fh("land (bot)", "land")
    t_land = (land or {}).get("tick")
    shots = {}

    def during_descent(n, v):
        tr = R(v).get("travel") or {}
        if tr.get("state") == "descending" and n in (3, 5):
            sample(f"camera on the pod going down ({n})")
            if not shots:
                shots["down"] = shot("6-pod-down")
    down = poll("standing on vulcanus", lambda: s.fh("status (landing)", "status"),
                lambda v: R(v).get("surface") == "vulcanus" and R(v).get("alive") is True and not R(v).get("travel"), 180, 3, during_descent)
    s.record("descent ticks", down is not None, {"land_tick": t_land, "standing_tick": (down or {}).get("tick"), "landed": find(down, "landed")})
    time.sleep(6)  # name tags are redrawn on the 300-tick recheck
    sample("camera and tags on vulcanus")
    shot("7-vulcanus")
    s.fh("final status", "status")
    print(f"{s.fails} failed steps; log: {os.path.join(a.out, 'smoke.jsonl')}")
    sys.exit(1 if s.fails else 0)


if __name__ == "__main__":
    main()
