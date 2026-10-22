#!/usr/bin/env python3
"""BASEMAP_LUA (tools/stream/harness.py) run under a stub `game` in the local lua, as the stream service sends it
(one line). Needs `lua` on PATH.  python3 tools/stream/test_basemap.py"""
import json, os, subprocess, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.dont_write_bytecode = True
from harness import basemap_lua, one_line  # noqa: E402

STUB = r"""
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
  local out = {}
  for k, x in pairs(v) do out[#out+1] = string.format("%q", k) .. ":" .. enc(x) end
  return "{" .. table.concat(out, ",") .. "}"
end
helpers = {table_to_json = enc}
rcon = {print = function(s) io.write(s) end}
local OURS, ENEMY = ENTITIES, NESTS
local function want(e, f)
  if f.area then
    local a, p = f.area, e.position
    if p.x < a[1][1] or p.y < a[1][2] or p.x > a[2][1] or p.y > a[2][2] then return false end
  end
  if f.force == "enemy" then return e.force == "enemy" end
  if f.force == nil then return e.force == "neutral" and f.type == e.type end
  if e.force ~= "player" then return false end
  for _, t in ipairs(f.type) do if t == e.type then return true end end
  return false
end
local all = {}
for _, e in ipairs(OURS) do e.force = "player"; all[#all+1] = e end
for _, e in ipairs(ENEMY) do e.force = "enemy"; all[#all+1] = e end
for _, e in ipairs(ORE) do e.force = "neutral"; all[#all+1] = e end
prototypes = {entity = {["assembling-machine-2"] = {tile_width = 3, tile_height = 3},
  ["boiler"] = {tile_width = 3, tile_height = 2}, ["gun-turret"] = {tile_width = 2, tile_height = 2, attack_parameters = {range = 18}},
  ["flamethrower-turret"] = {tile_width = 2, tile_height = 3, attack_parameters = {range = 30}}}}
game = {tick = 600, forces = {player = {}}, surfaces = {nauvis = {find_entities_filtered = function(f)
  if STRICT and f.type then for _, t in ipairs(f.type) do if t == "lane-splitter" then error("Unknown entity type") end end end
  local out = {}
  for _, e in ipairs(all) do if want(e, f) then out[#out+1] = e end end
  return out
end}}}
"""


def lua_list(items):
    return "{" + ",".join("{name=%s,type=%s,position={x=%s,y=%s},direction=%s}" % (json.dumps(i[0]), json.dumps(i[1]), i[2], i[3],
                          i[4] if len(i) > 4 else 0) for i in items) + "}"


def run(entities, nests=(), cell=4, max_cells=128, ore=(), strict=False):
    src = ("STRICT = true " if strict else "") + STUB.replace("ENTITIES", lua_list(entities)).replace("NESTS", lua_list(nests)).replace("local OURS, ENEMY", "local ORE = " + lua_list(ore) + " local OURS, ENEMY") + \
        one_line(basemap_lua(cell, max_cells, ore=bool(ore)))
    out = subprocess.run(["lua", "-e", src], capture_output=True, text=True, timeout=30)
    assert out.returncode == 0, out.stderr
    return json.loads(out.stdout)


def check(name, ok):
    print(("ok   " if ok else "FAIL ") + name)
    if not ok:
        sys.exit(1)


m = run([("stone-furnace", "furnace", 0.5, 0.5), ("transport-belt", "transport-belt", 1.5, 0.5),
         ("gun-turret", "ammo-turret", 9, 9), ("oil-refinery", "assembling-machine", -6.5, 2.5),
         ("assembling-machine-2", "assembling-machine", 5.5, -3.5), ("pipe", "pipe", 13.5, 0.5),
         ("small-electric-pole", "electric-pole", 30, 30)],
        nests=[("biter-spawner", "unit-spawner", 60, 60), ("small-worm-turret", "turret", 40, -20),
               ("biter-spawner", "unit-spawner", 900, 900)])
check("cell 4, origin at the lowest cell", m["cell"] == 4 and m["x0"] == -8 and m["y0"] == -4)
check("width and height in cells", m["w"] == 6 and m["h"] == 4)
check("a smelting cell beats a belt in the same cell", m["rows"][1][2] == "S")
check("an oil refinery is O, an assembler A, a turret D, a pipe P",
      m["rows"][1][0] == "O" and m["rows"][0][3] == "A" and m["rows"][3][4] == "D" and m["rows"][1][5] == "P")
check("poles are left out (no cell at 30,30) and trailing empty cells trimmed", all(len(r) <= 6 for r in m["rows"]))
check("nests near the base only", sorted(n[2] for n in m["nests"]) == ["s", "w"])
check("buildings counted without poles", m["buildings"] == 6)
check("turrets with their range for the site's turret-range layer", m["turrets"] == [[9, 9, 18]])
t = run([("gun-turret", "ammo-turret", 0, 0), ("flamethrower-turret", "fluid-turret", 10.5, 4), ("laser-turret", "electric-turret", 20, 0),
         ("stone-wall", "wall", 3, 3)])
check("a flamer's range from its prototype; a turret the game gives no range to (here: no prototype) and walls left out",
      sorted(map(tuple, t["turrets"])) == [(0, 0, 18), (10, 4, 30)])

# (d22 batch75 AK4, viewer Foobator: "can walls be a separate item?") walls and gates W; a turret's cell stays D
w = run([("stone-wall", "wall", 0.5, 0.5), ("gate", "gate", 4.5, 0.5), ("gun-turret", "ammo-turret", 9, 1), ("stone-wall", "wall", 8.5, 0.5),
         ("lab", "lab", 13.5, 1.5), ("stone-wall", "wall", 12.5, 0.5), ("transport-belt", "transport-belt", 17.5, 0.5), ("stone-wall", "wall", 16.5, 0.5)])
check("walls and gates W, under a turret in its cell, over a lab and a belt", w["rows"][0] == "WWDWW")

wide = run([("lab", "lab", 0, 0), ("lab", "lab", 2000, 10)], max_cells=128)
check("a wide base doubles the cell until it fits", wide["cell"] >= 16 and wide["w"] <= 128)

empty = run([])
check("no buildings: an empty grid", empty["rows"] == [] and empty["w"] == 0 and empty["nests"] == [])

check("no ore unless asked", "ore" not in m)
ores = [("iron-ore", "resource", 0.5 + dx, 0.5 + dy) for dx in range(3) for dy in range(3)] + \
       [("copper-ore", "resource", 1.5, 2.5), ("copper-ore", "resource", 2.5, 2.5),
        ("coal", "resource", 20.5, 20.5), ("crude-oil", "resource", -30.5, 8.5), ("stone", "resource", 500, 500)]
o = run([("stone-furnace", "furnace", 0.5, 0.5)], ore=ores)["ore"]
check("ore grid starts 64 tiles out from the base", o["cell"] == 4 and o["x0"] == -64 and o["y0"] == -64)
row0 = o["rows"][16]  # tile y 0..3
check("the commonest resource in a cell wins (iron 9 over copper 2)", row0[16] == "i")
check("coal and crude oil get their own letters", o["rows"][21][21] == "k" and o["rows"][18][8] == "o")
check("ore beyond the margin is left out", all("s" not in r for r in o["rows"]))
# the core: a dense block of assemblers and furnaces, a 400-tile pipeline north to pumpjacks
base = [("assembling-machine-2", "assembling-machine", 4.5 + 4 * i, 4.5 + 4 * j) for i in range(6) for j in range(4)] + \
       [("stone-furnace", "furnace", 40 + 2 * i, 2) for i in range(5)] + \
       [("boiler", "boiler", 50.5, 20, 4), ("transport-belt", "transport-belt", 2.5, 2.5)]
line = [("pipe", "pipe", 0.5, -0.5 - k) for k in range(400)] + [("pumpjack", "mining-drill", 0.5 + 3 * i, -405.5) for i in range(3)]
c = run(base + line)
core = c["core"]
check("the coarse grid still spans the pipeline", c["h"] * c["cell"] >= 400)
check("the core is the dense block at 1 tile a cell, the pipeline left out",
      core["cell"] == 1 and core["y0"] >= -40 and core["x0"] == -8 and core["w"] <= 120)
row = lambda y: core["rows"][y - core["y0"]].ljust(core["w"], ".")
x = lambda x: x - core["x0"]
check("an assembler fills its 3x3 footprint", all(row(y)[x(3):x(6)] == "AAA" for y in (3, 4, 5)) and row(6)[x(3)] == ".")
check("a belt cell under nothing else is B", row(2)[x(2)] == "B")
check("a boiler facing east is 2 wide and 3 tall", row(19)[x(49):x(52)] == "EE." and row(18)[x(50)] == "E" and row(20)[x(50)] == "E" and row(21)[x(50)] == ".")
small = run([("lab", "lab", 0, 0), ("pipe", "pipe", 300, 0)])
check("under 12 buildings: the core is the whole base", small["core"]["x0"] <= 0 and small["core"]["x0"] + small["core"]["w"] * small["core"]["cell"] >= 300)
check("a core wider than 160 cells doubles its cell", small["core"]["cell"] == 2)
fb = run(base, strict=True)
check("a game without the Space Age types falls back to the base list", fb["buildings"] == len(base) and fb["core"]["cell"] == 1)
check("no core without buildings", "core" not in empty)
print("all passed")
