#!/usr/bin/env python3
"""The harness census (mod census.lua, task-slowreads) against the reads it stands in for, on one stub world in the
local lua: BASEMAP_LUA (with and without ore), STREAM_LUA's electric machines and starved, MACHINES_LUA, and the
snapshot's per-surface building counts. The census walks in bands over ticks; its parts must equal the one-tick reads.
Needs `lua` on PATH.  python3 tools/stream/test_census.py"""
import json, os, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
MOD = os.path.join(ROOT, "vendor", "factorio-harness", "mod", "agent-harness_0.1.0")
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(ROOT, "tools", "analyst"))
sys.dont_write_bytecode = True
from harness import basemap_lua, one_line, STREAM_LUA  # noqa: E402
import game as analyst_game  # noqa: E402

PROGRAM = r"""
package.path = MOD .. '/?.lua;' .. package.path
local function enc(v)
  local t = type(v)
  if t == "number" then return (v == math.floor(v)) and string.format("%d", v) or tostring(v) end
  if t == "string" then return string.format("%q", v) end
  if t == "boolean" then return tostring(v) end
  if t == "nil" then return "null" end
  if #v > 0 or next(v) == nil then
    local out = {}
    for i = 1, #v do out[i] = enc(v[i]) end
    return "[" .. table.concat(out, ",") .. "]"
  end
  local keys = {}
  for k in pairs(v) do keys[#keys+1] = tostring(k) end
  table.sort(keys)
  local out = {}
  for _, k in ipairs(keys) do out[#out+1] = string.format("%q", k) .. ":" .. enc(v[k] ~= nil and v[k] or v[tonumber(k)]) end
  return "{" .. table.concat(out, ",") .. "}"
end
helpers = {table_to_json = enc}
defines = {entity_status = {working = 1, low_power = 2, no_power = 3, normal = 4, no_input_fluid = 5}}
local SA = {["lane-splitter"]=true,["cargo-landing-pad"]=true,["agricultural-tower"]=true,["fusion-reactor"]=true,["fusion-generator"]=true,
  ["lightning-attractor"]=true,["rail-ramp"]=true,["rail-support"]=true,["elevated-straight-rail"]=true,["elevated-curved-rail-a"]=true,
  ["elevated-curved-rail-b"]=true,["elevated-half-diagonal-rail"]=true,["asteroid-collector"]=true,["thruster"]=true,["space-platform-hub"]=true}
local P = {
  ["assembling-machine-2"] = {type="assembling-machine", tile_width = 3, tile_height = 3, electric_energy_source_prototype = {}},
  ["stone-furnace"] = {type="furnace", tile_width = 2, tile_height = 2},
  ["electric-furnace"] = {type="furnace", tile_width = 3, tile_height = 3, electric_energy_source_prototype = {}},
  ["boiler"] = {type="boiler", tile_width = 3, tile_height = 2},
  ["gun-turret"] = {type="ammo-turret", tile_width = 2, tile_height = 2, attack_parameters = {range = 18}},
  ["flamethrower-turret"] = {type="fluid-turret", tile_width = 2, tile_height = 3, attack_parameters = {range = 30}},
  ["oil-refinery"] = {type="assembling-machine", tile_width = 5, tile_height = 5, electric_energy_source_prototype = {}},
  ["pumpjack"] = {type="mining-drill", tile_width = 3, tile_height = 3, electric_energy_source_prototype = {}},
  ["electric-mining-drill"] = {type="mining-drill", tile_width = 3, tile_height = 3, electric_energy_source_prototype = {}},
  ["burner-inserter"] = {type="inserter", tile_width = 1, tile_height = 1},
  ["inserter"] = {type="inserter", tile_width = 1, tile_height = 1, electric_energy_source_prototype = {}},
  ["lab"] = {type="lab", tile_width = 3, tile_height = 3, electric_energy_source_prototype = {}},
  ["biochamber"] = {type="assembling-machine", tile_width = 3, tile_height = 3},
  ["transport-belt"] = {type="transport-belt"}, ["pipe"] = {type="pipe"}, ["stone-wall"] = {type="wall"},
  ["small-electric-pole"] = {type="electric-pole"}, ["logistic-robot"] = {type="logistic-robot"},
  ["iron-chest"] = {type="container"}}
prototypes = {entity = P, get_entity_filtered = function(f)
  if STRICT and SA[f[1].type] then error("Unknown entity type") end
  return {}
end}
local forces = {player = {name = "player"}, enemy = {name = "enemy"}, neutral = {name = "neutral"}}
local function new_surface(name, index)
  local s = {name = name, index = index, list = {}, darkness = 0.2, daytime = 0.4}
  s.find_entities_filtered = function(f)
    if STRICT and f.type and type(f.type) == "table" then for _, t in ipairs(f.type) do if SA[t] then error("Unknown entity type") end end end
    local types = f.type and (type(f.type) == "table" and f.type or {f.type}) or nil
    local tset = types and {} or nil
    if types then for _, t in ipairs(types) do tset[t] = true end end
    local fname = f.force and (type(f.force) == "table" and f.force.name or f.force) or nil
    local out = {}
    for _, e in ipairs(s.list) do
      local p, ok = e.position, true
      if f.area then ok = p.x >= f.area[1][1] and p.y >= f.area[1][2] and p.x <= f.area[2][1] and p.y <= f.area[2][2] end
      if ok and fname and e.force.name ~= fname then ok = false end
      if ok and tset and not tset[e.type] then ok = false end
      if ok then out[#out+1] = e; if f.limit and #out >= f.limit then break end end
    end
    return out
  end
  return s
end
local nauvis, gleba = new_surface("nauvis", 1), new_surface("gleba", 2)
game = {tick = 0, forces = forces, surfaces = {nauvis = nauvis, gleba = gleba}, players = {}}
game.get_surface = function(i) if i == 1 or i == "nauvis" then return nauvis elseif i == 2 or i == "gleba" then return gleba end end
local function put(s, row, force)
  local name, typ, x, y, dir, extra = row[1], row[2], row[3], row[4], row[5] or 0, row[6] or {}
  local e = {valid = true, name = name, type = typ, position = {x = x, y = y}, direction = dir, force = forces[force],
    prototype = P[name] or {}, status = extra.status}
  e.get_recipe = function() return extra.recipe and {name = extra.recipe} or nil end
  e.mining_target = extra.ore and {name = extra.ore} or nil
  s.list[#s.list+1] = e
end
for _, r in ipairs(OURS) do put(nauvis, r, "player") end
for _, r in ipairs(NESTS) do put(nauvis, r, "enemy") end
for _, r in ipairs(ORE) do put(nauvis, r, "neutral") end
for _, r in ipairs(GLEBA) do put(gleba, r, "player") end
forces.player.get_entity_count = function(name)
  local n = 0
  for _, s in ipairs({nauvis, gleba}) do for _, e in ipairs(s.list) do if e.force == forces.player and e.name == name then n = n + 1 end end end
  return n
end
local printed
rcon = {print = function(x) printed = x end}
local function run(code) printed = nil; assert(load(code))(); return printed end
local out = {}
out.basemap_read = run(BASEMAP)
out.basemap_ore_read = run(BASEMAP_ORE)
out.machines_read = run(MACHINES)
out.stream_read = run(STREAM)
local S = {}
local census = dofile(MOD .. "/census.lua"){state = function() return S end}
census.read({part = "basemap", ore = true})
local ticks = 0
while not (S.census and S.census.done and S.census.ore) and ticks < 100000 do ticks = ticks + 1; game.tick = ticks; census.tick(ticks) end
out.ticks = ticks
local function part(p, ore) return enc(census.read({part = p, ore = ore})) end
out.basemap_census = part("basemap")
out.basemap_ore_census = part("basemap", true)
out.extras_census = part("extras")
out.machines_census = part("machines")
out.snapshot_census = part("snapshot")
out.ore_start = S.census.ore and S.census.ore.start
game.tick = ticks + 40000
out.basemap_ore_late = part("basemap", true)
game.tick = ticks
-- The reads with a harness that answers census (pog.CENSUS_FN): they print what the census says, with no find.
local last_req
remote = {interfaces = {agent_harness = {dispatch = true}}, call = function(_, _, req) last_req = req return "reply" end}
helpers.json_to_table = function()
  return {ok = true, result = census.read({part = last_req:match('"part":"(%a+)"'), ore = last_req:find('"ore":true', 1, true) ~= nil})}
end
local finds = 0
for _, s in ipairs({nauvis, gleba}) do local f0 = s.find_entities_filtered; s.find_entities_filtered = function(f) finds = finds + 1 return f0(f) end end
out.basemap_via = run(BASEMAP)
out.basemap_ore_via = run(BASEMAP_ORE)
out.stream_via = run(STREAM)
out.machines_via = run(MACHINES)
out.finds_via = finds
io.write(enc(out))
"""


def lua_rows(rows):
    def one(r):
        extra = r[5] if len(r) > 5 else {}
        ex = "{" + ",".join(f"{k}={json.dumps(v)}" for k, v in extra.items()) + "}"
        return "{%s,%s,%s,%s,%s,%s}" % (json.dumps(r[0]), json.dumps(r[1]), r[2], r[3], r[4] if len(r) > 4 else 0, ex)
    return "{" + ",".join(one(r) for r in rows) + "}"


def run(ours, nests=(), ore=(), gleba=(), strict=False):
    lua_str = lambda s: "[==[" + s + "]==]"
    src = (("STRICT = true " if strict else "STRICT = false ") + "MOD = " + json.dumps(MOD) + " "
           + "OURS = " + lua_rows(ours) + " NESTS = " + lua_rows(nests) + " ORE = " + lua_rows(ore) + " GLEBA = " + lua_rows(gleba) + " "
           + "BASEMAP = " + lua_str(one_line(basemap_lua())) + " BASEMAP_ORE = " + lua_str(one_line(basemap_lua(ore=True))) + " "
           + "MACHINES = " + lua_str(one_line(analyst_game.MACHINES_LUA.replace("SURFACE", '"all"'))) + " "
           + "STREAM = " + lua_str(one_line(STREAM_LUA.replace("pairs(f.technologies)", "pairs({})")
                                            .replace("f.current_research", "nil"))) + " "
           + PROGRAM)
    out = subprocess.run(["lua", "-e", src], capture_output=True, text=True, timeout=120)
    assert out.returncode == 0, out.stderr
    res = json.loads(out.stdout)
    return {k: (json.loads(v) if isinstance(v, str) and v[:1] in "{[" else v) for k, v in res.items()}


def check(name, ok, detail=""):
    print(("ok   " if ok else "FAIL ") + name + ("" if ok else ": " + str(detail)[:2000]))
    if not ok:
        sys.exit(1)


def same_map(read, census):
    a = dict(read)
    b = dict(census["basemap"])
    a.pop("tick", None)
    b.pop("tick", None)
    if isinstance(b.get("ore"), dict):  # (d22 batch97 BG3) the census's ore says when its pass started
        b["ore"] = {k: v for k, v in b["ore"].items() if k != "tick"}
    # (nests come in the find's order in the read and in band order in the census: the same set)
    for m in (a, b):
        m["nests"] = sorted(m.get("nests") or [])
    # (table_to_json in the stub writes an empty list as [] either way)
    diff = {}
    for k in sorted(set(a) | set(b)):
        if a.get(k) != b.get(k):
            x, y = a.get(k), b.get(k)
            if isinstance(x, dict) and isinstance(y, dict):
                diff[k] = {kk: (x.get(kk), y.get(kk)) for kk in set(x) | set(y) if x.get(kk) != y.get(kk)}
            else:
                diff[k] = (x, y)
    return not diff, diff


base = [("assembling-machine-2", "assembling-machine", 4.5 + 4 * i, 4.5 + 4 * j, 0, {"status": 1, "recipe": "iron-gear-wheel"})
        for i in range(6) for j in range(4)] + \
       [("stone-furnace", "furnace", 40 + 2 * i, 2, 0, {"status": 1, "recipe": "iron-plate"}) for i in range(5)] + \
       [("boiler", "boiler", 50.5, 20, 4, {"status": 1}), ("transport-belt", "transport-belt", 2.5, 2.5),
        ("gun-turret", "ammo-turret", 9, 9), ("flamethrower-turret", "fluid-turret", 70.5, 4), ("stone-wall", "wall", 3, 3),
        ("oil-refinery", "assembling-machine", -6.5, 2.5, 0, {"status": 3, "recipe": "basic-oil-processing"}),
        ("inserter", "inserter", 7.5, 2.5, 0, {"status": 2}), ("burner-inserter", "inserter", 8.5, 2.5, 0, {"status": 1}),
        ("small-electric-pole", "electric-pole", 30, 30), ("iron-chest", "container", 12.5, 12.5),
        ("logistic-robot", "logistic-robot", 20.5, 20.5), ("heat-pipe", "heat-pipe", 90.5, 40.5)]
line = [("pipe", "pipe", 0.5, -0.5 - k) for k in range(400)] + \
       [("pumpjack", "mining-drill", 0.5 + 3 * i, -405.5, 0, {"status": 1, "ore": "crude-oil"}) for i in range(3)]
nests = [("biter-spawner", "unit-spawner", 60, 60), ("small-worm-turret", "turret", 40, -20), ("biter-spawner", "unit-spawner", 900, 900),
         ("medium-worm-turret", "turret", -100, -480)]
ore = [("iron-ore", "resource", 0.5 + dx, 0.5 + dy) for dx in range(3) for dy in range(3)] + \
      [("copper-ore", "resource", 1.5, 2.5), ("copper-ore", "resource", 2.5, 2.5),
       ("coal", "resource", 20.5, 20.5), ("crude-oil", "resource", -30.5, 8.5), ("stone", "resource", 500, 500),
       ("stone", "resource", 2.5, -460.5)]
gleba = [("biochamber", "assembling-machine", 10.5, 10.5, 0, {"status": 1, "recipe": "nutrients-from-spoilage"}),
         ("electric-mining-drill", "mining-drill", 30.5, 0.5, 0, {"status": 2, "ore": "stone"}),
         ("electric-furnace", "furnace", 40.5, 0.5, 0, {"status": 3}), ("lab", "lab", 50.5, 0.5, 0, {"status": 1})]

r = run(base + line, nests, ore, gleba)
ok, detail = same_map(r["basemap_read"], r["basemap_census"])
check("the live map: the census equals BASEMAP_LUA (rows, core, nests, turrets, buildings)", ok, detail)
ok, detail = same_map(r["basemap_ore_read"], r["basemap_ore_census"])
check("the live map with ore: equal, the ore grid too", ok and "ore" in r["basemap_ore_census"]["basemap"], detail)
check("the census's map without ore has no ore", "ore" not in r["basemap_census"]["basemap"])
bm = r["basemap_census"]["basemap"]
hp = bm["rows"][(40 - bm["y0"]) // bm["cell"]][(90 - bm["x0"]) // bm["cell"]]
check("(BG3) a heat pipe is drawn as power (E) on the live map, in the census and the read alike", hp == "E", (hp, bm["rows"]))
late = r["basemap_ore_late"]
check("(BG3) its last ore grid is served 40,000 ticks after its pass started (a pass takes 35-41k on world n), "
      "with that start as ore.tick", late["basemap"].get("ore", {}).get("tick") == r["ore_start"] and not late.get("ore_pending")
      and late["basemap"]["ore"]["rows"] == r["basemap_ore_census"]["basemap"]["ore"]["rows"], late)
s, c = r["stream_read"], r["extras_census"]
check("extras: electric machines and starved equal STREAM_LUA's", (s["electric_machines"], s["starved"]) == (c["electric_machines"], c["starved"]),
      (s, c))
check("extras counts electric machines on every surface (5 on nauvis's list, 3 on gleba; burner ones left out)",
      c["electric_machines"] == 24 + 1 + 1 + 3 + 3 and c["starved"] == 2 + 2, c)
check("machines: equal MACHINES_LUA's", r["machines_read"] == r["machines_census"]["machines"], (r["machines_read"], r["machines_census"]))
snap = r["snapshot_census"]
check("snapshot: buildings per surface as SNAPSHOT_LUA counts them (its types only: no chest, pipe or belt-less types)",
      # 24 assemblers, 5 furnaces, boiler, belt, gun, flamer, wall, refinery, 2 inserters, pole, robot, 3 pumpjacks
      snap["surfaces_with_buildings"] == {"nauvis": 24 + 5 + 1 + 1 + 1 + 1 + 1 + 1 + 2 + 1 + 1 + 3, "gleba": 4}, snap["surfaces_with_buildings"])
check("snapshot: per name the force's engine counts", snap["entities"].get("assembling-machine-2") == 24 and snap["entities"].get("pumpjack") == 3
      and "iron-chest" not in snap["entities"], snap["entities"])
check("the pass spread over ticks", r["ticks"] > 40, r["ticks"])
check("every part says when its pass started", all(r[k].get("as_of") is not None for k in ("extras_census", "machines_census", "basemap_census")))

check("with the census in the harness, the live map read prints the census's map", r["basemap_via"] == r["basemap_census"]["basemap"],
      (r["basemap_via"], r["basemap_census"]))
check("and with ore, its ore grid", r["basemap_ore_via"].get("ore") == r["basemap_ore_census"]["basemap"]["ore"])
check("the stream read's machine counts are the census's", (r["stream_via"]["electric_machines"], r["stream_via"]["starved"])
      == (r["extras_census"]["electric_machines"], r["extras_census"]["starved"]))
check("the analyst's machines read prints the census's", r["machines_via"] == r["machines_census"]["machines"])
check("none of them finds anything in the game", r["finds_via"] == 0, r["finds_via"])

fb = run(base + line, nests, ore, gleba, strict=True)
ok, detail = same_map(fb["basemap_read"], fb["basemap_census"])
check("a game without the Space Age types: the census walks the base types, equal to the read's fallback", ok, detail)

empty = run([], [], [], [])
ok, detail = same_map(empty["basemap_read"], empty["basemap_census"])
check("no buildings: equal (an empty grid, no core)", ok, detail)
print("all passed")
