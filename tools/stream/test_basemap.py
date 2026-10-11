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
  if e.force ~= "player" then return false end
  for _, t in ipairs(f.type) do if t == e.type then return true end end
  return false
end
local all = {}
for _, e in ipairs(OURS) do e.force = "player"; all[#all+1] = e end
for _, e in ipairs(ENEMY) do e.force = "enemy"; all[#all+1] = e end
game = {tick = 600, forces = {player = {}}, surfaces = {nauvis = {find_entities_filtered = function(f)
  local out = {}
  for _, e in ipairs(all) do if want(e, f) then out[#out+1] = e end end
  return out
end}}}
"""


def lua_list(items):
    return "{" + ",".join("{name=%s,type=%s,position={x=%s,y=%s}}" % (json.dumps(n), json.dumps(t), x, y)
                          for n, t, x, y in items) + "}"


def run(entities, nests=(), cell=4, max_cells=128):
    src = STUB.replace("ENTITIES", lua_list(entities)).replace("NESTS", lua_list(nests)) + one_line(basemap_lua(cell, max_cells))
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

wide = run([("lab", "lab", 0, 0), ("lab", "lab", 2000, 10)], max_cells=128)
check("a wide base doubles the cell until it fits", wide["cell"] >= 16 and wide["w"] <= 128)

empty = run([])
check("no buildings: an empty grid", empty["rows"] == [] and empty["w"] == 0 and empty["nests"] == [])
print("all passed")
