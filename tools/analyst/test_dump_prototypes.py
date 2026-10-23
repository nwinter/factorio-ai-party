#!/usr/bin/env python3
"""dump_prototypes.py's commands, offline: python3 tools/analyst/test_dump_prototypes.py

2026-10-13 15:25 the entities page failed live ("end expected near <eof>"): a "--" comment in its Lua commented out the
rest of the one-line command. Here every category's command, as sent, (1) holds no "--", (2) is no longer than the
longest that ran live (MAX_COMMAND), (3) compiles in a real Lua (`lua`), and (4) the asteroids pages run against fake
prototypes shaped like the game's (LuaObjects that error on keys they lack) and give each route's and orbit's spawn
definitions and the asteroid entities, paged, as JSON.
"""
import json, os, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
sys.dont_write_bytecode = True
import dump_prototypes as dp  # noqa: E402

LUA_BIN = shutil.which("lua")

PRELUDE = r"""
local out = {}
rcon = {print = function(s) out[#out + 1] = s end}
local function enc(v)
  local t = type(v)
  if t == 'nil' then return 'null' end
  if t == 'boolean' or t == 'number' then return tostring(v) end
  if t == 'string' then return '"' .. v:gsub('[%c"\\]', function(c) return string.format('\\u%04x', c:byte()) end) .. '"' end
  if t == 'table' then
    local parts = {}
    if #v > 0 then
      for i = 1, #v do parts[i] = enc(v[i]) end
      return '[' .. table.concat(parts, ',') .. ']'
    end
    for k, x in pairs(v) do parts[#parts + 1] = enc(tostring(k)) .. ':' .. enc(x) end
    return '{' .. table.concat(parts, ',') .. '}'
  end
  error('cannot encode a ' .. t)
end
helpers = {table_to_json = enc}
local function obj(t)
  return setmetatable({}, {__index = function(_, k)
    local v = t[k]
    if v == nil then error("LuaObject doesn't contain key " .. k) end
    return v
  end})
end
local metallic = obj{name = 'medium-metallic-asteroid', get_max_health = function() return 400 end,
  resistances = {physical = {decrease = 0, percent = 0.1}, explosion = {decrease = 0, percent = 0.1}}}
prototypes = {
  space_connection = {
    ['nauvis-vulcanus'] = obj{name = 'nauvis-vulcanus', from = obj{name = 'nauvis'}, to = obj{name = 'vulcanus'}, length = 15000,
      asteroid_spawn_definitions = {
        {type = 'entity', asteroid = obj{name = 'medium-metallic-asteroid'}, quality = obj{name = 'normal'},
          spawn_points = {{distance = 0.1, probability = 0.002, speed = 0.016}, {distance = 0.9, probability = 0.004, speed = 0.016}}},
        {type = 'asteroid-chunk', asteroid = 'metallic-asteroid-chunk', spawn_points = {{distance = 0.5, probability = 0.01, speed = 0.02}}}}},
    ['nauvis-gleba'] = obj{name = 'nauvis-gleba', from = obj{name = 'nauvis'}, to = obj{name = 'gleba'}, length = 15000,
      asteroid_spawn_definitions = {}}},
  space_location = {
    nauvis = obj{name = 'nauvis', asteroid_spawn_definitions = {{type = 'asteroid-chunk', asteroid = 'metallic-asteroid-chunk', probability = 0.0125, speed = 0.008}}},
    ['space-location-unknown'] = obj{name = 'space-location-unknown'}},
  get_entity_filtered = function(f)
    if f[1].type == 'asteroid' then return {['medium-metallic-asteroid'] = metallic} end
    return {}
  end}
local code = CODE
local fn = assert(load(code))
fn()
io.write(table.concat(out, '\n'))
"""


def lua_string(text):
    level = 0
    while f"]{'=' * level}]" in text:
        level += 1
    return f"[{'=' * level}[{text}]{'=' * level}]"


def run_lua(source):
    with tempfile.TemporaryDirectory() as d:
        path = os.path.join(d, "page.lua")
        with open(path, "w") as f:
            f.write(source)
        r = subprocess.run([LUA_BIN, path], capture_output=True, text=True, timeout=30)
    return r.returncode, r.stdout, r.stderr


def check(cond, msg):
    if not cond:
        raise AssertionError(msg)


# 1-3: every category's command as sent
for cat in dp.LUA:
    cmd = dp.command(cat, 1)
    check(cmd.startswith("/silent-command ") and "--" not in cmd, f"{cat}: '--' in the one-line command")
    check(len(cmd.encode()) <= dp.MAX_COMMAND, f"{cat}: {len(cmd.encode())} bytes")
    if LUA_BIN:
        code = cmd[len("/silent-command "):]
        rc, out, err = run_lua(f"local f, e = load({lua_string(code)}) if not f then io.write('COMPILE: ' .. e) os.exit(1) end")
        check(rc == 0, f"{cat}: does not compile as one line: {out} {err}")

# The 15:25 failure: a comment inside a page is refused before anything is sent.
saved = dp.LUA["fluids"]
dp.LUA["fluids"] = saved + "\n-- a note\n"
try:
    dp.command("fluids", 1)
    raise AssertionError("a '--' comment was not refused")
except SystemExit as e:
    check("--" in str(e), e)
finally:
    dp.LUA["fluids"] = saved

# 4: the asteroids pages, run, paged as dump() pages them
if LUA_BIN:
    rows, start, total = [], 1, None
    while total is None or start <= total:
        code = dp.command("asteroids", start)[len("/silent-command "):]
        rc, out, err = run_lua(PRELUDE.replace("CODE", lua_string(code)))
        check(rc == 0, f"asteroids page {start}: {err}")
        data = json.loads(out)
        total = data["total"]
        rows += data["items"]
        start += dp.PAGE["asteroids"]
    check(total == 5 and len(rows) == 5, rows)
    by = {(r["kind"], r["name"]): r for r in rows}
    nv = by[("route", "nauvis-vulcanus")]
    check(nv["from"] == "nauvis" and nv["to"] == "vulcanus" and nv["length"] == 15000, nv)
    a0 = nv["asteroids"][0]
    check(a0["asteroid"] == "medium-metallic-asteroid" and a0["type"] == "entity" and a0["quality"] == "normal", a0)
    check(a0["spawn_points"][1] == {"distance": 0.9, "probability": 0.004, "speed": 0.016}, a0)
    check(nv["asteroids"][1]["asteroid"] == "metallic-asteroid-chunk", nv["asteroids"][1])
    orbit = by[("orbit", "nauvis")]["asteroids"][0]
    check(orbit == {"asteroid": "metallic-asteroid-chunk", "type": "asteroid-chunk", "probability": 0.0125, "speed": 0.008}, orbit)
    check(by[("orbit", "space-location-unknown")]["asteroids"] in ([], {}), "a location without definitions: empty")
    ast = by[("asteroid", "medium-metallic-asteroid")]
    check(ast["max_health"] == 400 and {r["type"] for r in ast["resistances"]} == {"physical", "explosion"}, ast)
else:
    print("lua not found: the compile and run checks were skipped")

# 5: the fluid_energy page (Sol, d15 19:05), run against fake prototypes, and its merge into entities.json by name
FLUID_PROTOS = r"""
local function box(t) return obj{production_type = t.p, filter = t.f and obj{name = t.f} or nil, minimum_temperature = t.min,
  maximum_temperature = t.max, volume = t.v, pipe_connections = t.c} end
prototypes = {entity = {
  ['fusion-reactor'] = obj{name = 'fusion-reactor', type = 'fusion-reactor', get_fluid_usage_per_tick = function() return 4 / 60 end, neighbour_bonus = 1, two_direction_only = true,
    fluidbox_prototypes = {box{p = 'input', f = 'fluoroketone-cold', v = 1000, c = {1, 2}}, box{p = 'output', f = 'fusion-plasma', v = 1000, c = {1, 2, 3}}}},
  ['fusion-generator'] = obj{name = 'fusion-generator', type = 'fusion-generator', get_fluid_usage_per_tick = function() return 2 / 60 end, effectivity = 1,
    fluidbox_prototypes = {box{p = 'input', f = 'fusion-plasma', min = 1000000, v = 100, c = {1}}}},
  ['steam-turbine'] = obj{name = 'steam-turbine', type = 'generator', fluid_usage_per_tick = 1, effectivity = 1, maximum_temperature = 500,
    fluidbox_prototypes = {box{p = 'input-output', f = 'steam', min = 15, v = 200, c = {1, 2}}}},
  ['iron-chest'] = obj{name = 'iron-chest', type = 'container'}}}
"""
if LUA_BIN:
    prelude = PRELUDE[:PRELUDE.index("local metallic")] + FLUID_PROTOS + PRELUDE[PRELUDE.index("local code = CODE"):]
    code = dp.command("fluid_energy", 1)[len("/silent-command "):]
    rc, out, err = run_lua(prelude.replace("CODE", lua_string(code)))
    check(rc == 0, f"fluid_energy: {err}")
    data = json.loads(out)
    check(data["total"] == 3, data)
    by = {r["name"]: r for r in data["items"]}
    fr = by["fusion-reactor"]
    check(abs(fr["max_fluid_usage_per_s"] - 4) < 1e-9 and fr["neighbour_bonus"] == 1 and fr["two_direction_only"] is True, fr)
    check(fr["fluid_boxes"][0] == {"production_type": "input", "filter": "fluoroketone-cold", "volume": 1000, "connections": 2}, fr)
    check(fr["fluid_boxes"][1]["filter"] == "fusion-plasma", fr)
    fg = by["fusion-generator"]
    check(abs(fg["max_fluid_usage_per_s"] - 2) < 1e-9 and fg["effectivity"] == 1 and fg["fluid_boxes"][0]["minimum_temperature"] == 1000000, fg)
    st = by["steam-turbine"]
    check(st["max_fluid_usage_per_s"] == 60 and st["maximum_temperature"] == 500 and st["fluid_boxes"][0]["production_type"] == "input-output", st)
    # the merge: each entity's "fluid", by name; an entity the page did not read has none
    with tempfile.TemporaryDirectory() as d:
        with open(os.path.join(d, "entities.json"), "w") as f:
            json.dump([{"name": "fusion-reactor", "type": "fusion-reactor", "max_energy_usage_kw": 10000},
                       {"name": "iron-chest", "type": "container", "fluid": {"stale": 1}}], f)
        line = dp.merge_fluid_energy(d, data["items"])
        check("3 read, 1 merged" in line, line)
        ents = {e["name"]: e for e in json.load(open(os.path.join(d, "entities.json")))}
        check(ents["fusion-reactor"]["fluid"]["neighbour_bonus"] == 1 and ents["fusion-reactor"]["max_energy_usage_kw"] == 10000, ents)
        check("fluid" not in ents["iron-chest"], ents)
print("test_dump_prototypes: ok")

# (d22 batch102 BL1, Sol #1919: "gamedata recipes omit extra_count_fraction ...; module item records omit effects and
# machine built-in productivity") the new pages fit, and a module's effects by quality follow the game's rule, checked
# on a copy of world n's save against entity.effects of a machine holding each module at each quality (60 of 60)
for cat in ("recipes", "items", "qualities", "effects"):
    cmd = dp.command(cat, 1)
    check("--" not in cmd and len(cmd.encode()) <= dp.MAX_COMMAND, (cat, len(cmd.encode())))
check("extra_count_fraction" in dp.command("recipes", 1) and "module_effects" in dp.command("items", 1), "the new fields read")
check("effect_receiver" in dp.command("effects", 1) and "get_crafting_speed(q)" in dp.command("effects", 1), "the machines' effects read")
me = dp.module_effect
check(me("speed", 0.5, 2.5) == 1.25 and me("consumption", 0.7, 2.5) == 0.7, "speed 3 legendary: speed x2.5, its consumption penalty unchanged")
check(me("consumption", -0.5, 1.3) == -0.65 and me("pollution", -0.05, 1.6) == -0.08, "efficiency: the reduction scales (cut to 0.01)")
check(me("quality", 0.25, 2.5) == 0.62 and me("speed", -0.05, 2.5) == -0.05, "quality 3 legendary: 0.625 read 0.62; speed penalty unchanged")
check(me("productivity", 0.1, 1.6) == 0.16 and me("quality", -0.1, 1.9) == -0.1, "productivity scales; a quality penalty does not")
with tempfile.TemporaryDirectory() as d:
    with open(os.path.join(d, "items.json"), "w") as f:
        json.dump([{"name": "speed-module-3", "type": "module", "module_effects": {"speed": 0.5, "consumption": 0.70000001, "quality": -0.25}},
                   {"name": "iron-plate", "type": "item", "effects_by_quality": {"stale": {}}}], f)
    with open(os.path.join(d, "qualities.json"), "w") as f:
        json.dump([{"name": "legendary", "level": 5, "default_multiplier": 2.5}, {"name": "normal", "level": 0, "default_multiplier": 1},
                   {"name": "quality-unknown", "level": 0, "hidden": True, "default_multiplier": 1}], f)
    line = dp.add_module_qualities(d)
    check("1 with effects_by_quality (normal, legendary)" in line, line)
    its = {e["name"]: e for e in json.load(open(os.path.join(d, "items.json")))}
    eq_ = its["speed-module-3"]["effects_by_quality"]
    check(eq_["legendary"] == {"speed": 1.25, "consumption": 0.7, "quality": -0.25} and eq_["normal"]["speed"] == 0.5, eq_)
    check(its["speed-module-3"]["module_effects"]["consumption"] == 0.7 and "effects_by_quality" not in its["iron-plate"], its)
    with open(os.path.join(d, "entities.json"), "w") as f:
        json.dump([{"name": "electromagnetic-plant", "type": "assembling-machine"}, {"name": "iron-chest", "type": "container", "effects": {"stale": 1}}], f)
    line = dp.merge_effects(d, [{"name": "electromagnetic-plant", "type": "assembling-machine", "base_effect": {"productivity": 0.5},
                                 "crafting_speed_by_quality": {"normal": 2, "legendary": 5.000001}, "allowed_module_categories": None}])
    ents = {e["name"]: e for e in json.load(open(os.path.join(d, "entities.json")))}
    check(ents["electromagnetic-plant"]["effects"] == {"base_effect": {"productivity": 0.5}, "crafting_speed_by_quality": {"normal": 2, "legendary": 5.0}}, ents)
    check("effects" not in ents["iron-chest"] and "1 read, 1 merged" in line, (ents, line))
# the kb as dumped from the copy (d22 15:08 save): the cases Sol named
kb = os.path.join(os.path.dirname(os.path.abspath(__file__)), "kb", "space-age-2.0.77")
rec = {r["name"]: r for r in json.load(open(os.path.join(kb, "recipes.json")))}
check(rec["electromagnetic-plant-recycling"]["products"][0] == {"amount": 37, "extra_count_fraction": 0.5, "name": "holmium-plate", "type": "item"}, "EM plant recycler: 37.5 holmium")
check(rec["supercapacitor-recycling"]["products"][0]["extra_count_fraction"] == 0.5, "supercapacitor recycler: 0.5 holmium")
ents = {e["name"]: e for e in json.load(open(os.path.join(kb, "entities.json")))}
check(ents["electromagnetic-plant"]["effects"]["base_effect"] == {"productivity": 0.5}, "EM plant built-in productivity")
check(ents["electromagnetic-plant"]["effects"]["crafting_speed_by_quality"]["legendary"] == 5, "EM plant legendary speed")
qs = {q["name"]: q for q in json.load(open(os.path.join(kb, "qualities.json")))}
check(qs["legendary"]["default_multiplier"] == 2.5 and qs["rare"]["next"] == "epic", qs.get("legendary"))
print("test_dump_prototypes: BL1 ok (fractions, module effects by quality, machine effects, qualities)")
