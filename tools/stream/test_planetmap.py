#!/usr/bin/env python3
"""The other planets' coarse maps on the live page (viewers craigNZ830 and Foobator, d15 07:05: the map showed Nauvis
only): python3 tools/stream/test_planetmap.py

1. harness.planet_read_lua: the census operator read for the list (part planets) and for one planet's map (part basemap
   with surface), one line with no comments (the stream service joins the lines), the planet's name quoted safely.
2. Run under a stub `remote` in the local lua: a ready census answer is printed whole; no harness or no census yet
   prints {}.
3. model.Model keeps the planet maps by surface across reads (one read a minute, in turn); a planet the census stops
   listing keeps its last map (d20 batch50 D1: the site labels it with its age); the snapshot carries planet_maps.
"""
import json, os, shutil, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.dont_write_bytecode = True
import harness  # noqa: E402
from model import Model  # noqa: E402

failed = []


def check(name, ok, detail=""):
    print(("ok   " if ok else "FAIL ") + name + ("" if ok else ": " + str(detail)))
    if not ok:
        failed.append(name)


# 1. the reads
lst, one = harness.planet_read_lua(), harness.planet_read_lua('vul"canus')
check("the list asks part planets", '{part = "planets"}' in lst, lst)
check("one planet asks part basemap with its surface, quoted", 'part = "basemap", surface = ' in one and 'vul"canus' in one, one)
check("no comments inside (one_line joins the lines)", "--" not in lst and "--" not in one)

# 2. under a stub remote
STUB = r"""
local function enc(v)
  local t = type(v)
  if t == "number" then return tostring(v) end
  if t == "string" then return string.format("%q", v) end
  if t == "boolean" then return tostring(v) end
  local parts, arr = {}, #v > 0
  for k, x in pairs(v) do parts[#parts+1] = (arr and "" or string.format("%q", k) .. ":") .. enc(x) end
  return (arr and "[" or "{") .. table.concat(parts, ",") .. (arr and "]" or "}")
end
local asked
helpers = {table_to_json = function(v) asked = asked or v; return enc(v) end, json_to_table = function(s) return REPLY end}
game = {tick = 7}
rcon = {print = function(s) io.write(s) end}
remote = {interfaces = {agent_harness = HAS and {dispatch = true} or nil}, call = function(_, _, req) return req end}
"""


def run(lua, reply, has=True):
    src = STUB.replace("REPLY", reply).replace("HAS", "true" if has else "false") + harness.one_line(lua)
    r = subprocess.run(["lua", "-"], input=src, capture_output=True, text=True, timeout=20)
    return r.returncode, r.stdout, r.stderr


if shutil.which("lua"):
    code, out, err = run(lst, '{ok = true, result = {ready = true, planets = {{name = "gleba", buildings = 40}}}}')
    check("a ready census answer is printed", code == 0 and '"planets"' in out and '"gleba"' in out, (code, out, err))
    code, out, err = run(lst, '{ok = true, result = {ready = false}}')
    check("no pass yet: {}", code == 0 and out == "{}", (out, err))
    code, out, err = run(lst, 'nil', has=False)
    check("no harness: {}", code == 0 and out == "{}", (out, err))
else:
    print("skip the lua runs (no lua on PATH)")

# 3. the model
m = Model({"agents": {"sol": {"display_name": "Sol"}}})
v = {"surface": "vulcanus", "tick": 5, "cell": 8, "x0": 0, "y0": 0, "w": 2, "h": 1, "rows": ["AS"], "buildings": 2}
g = dict(v, surface="gleba", tick=9)
m.ingest({"tick": 10, "agents": [], "planet_names": ["gleba", "vulcanus"], "planet_map": v}, now=1000)
m.ingest({"tick": 20, "agents": [], "planet_names": ["gleba", "vulcanus"], "planet_map": g}, now=1060)
snap = m.snapshot(1060)
check("both maps kept across reads", sorted(snap["planet_maps"]) == ["gleba", "vulcanus"], sorted(snap.get("planet_maps") or {}))
m.ingest({"tick": 30, "agents": [], "planet_names": ["gleba"]}, now=1120)
check("a planet no longer listed keeps its last map", sorted(m.snapshot(1120)["planet_maps"]) == ["gleba", "vulcanus"]
      and m.planet_maps["vulcanus"]["tick"] == 5, m.planet_maps)
m.ingest({"tick": 40, "agents": []}, now=1180)
check("a read with no planet list keeps them", sorted(m.snapshot(1180)["planet_maps"]) == ["gleba", "vulcanus"])
json.dumps(snap)  # the state is JSON

if failed:
    print("FAILED: " + ", ".join(failed))
    sys.exit(1)
print("all passed")
