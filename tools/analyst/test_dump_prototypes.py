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
print("test_dump_prototypes: ok")
