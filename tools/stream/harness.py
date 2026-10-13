"""Read-only access to a pog world for the stream service.

Talks RCON directly (one persistent connection) and sends the same
`remote.call("agent_harness", "dispatch", json)` that `bin/fh` sends, so a poll
costs one round trip instead of a node process. Only whitelisted read actions
can be dispatched: a failed non-read call stops that player's current action.
"""
import json, os, sys, threading, uuid

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.dont_write_bytecode = True  # tools/__pycache__ is tracked in git; do not rewrite it
import pog  # noqa: E402  (tools/pog.py: Rcon client, ports, SCORE_LUA)

# Never add a gameplay action here. `profiles` is read-only per docs/BOTS-API.md, but a runtime that does not
# know it yet treats it as a failed mutation and stops player 1, so callers gate it on `has_bots_runtime()`.
# `board` and `board_events` (docs/BOARD-API.md) are only sent once `describe` (read-only) lists them.
# `platforms` (Space Age) is a read in the runtime; the overlay sends it only once the score lists a platform.
READ_ACTIONS = {"status", "profiles", "chat", "power", "cameras", "describe", "board", "board_events", "platforms"}
# Operator reads (eng/board audience.lua): every agent's `confess` lines, for viewers only. Gated on `describe`.
OPERATOR_READS = {"confessions", "tells", "operator_requests", "attack_groups_live"}
# Operator drawing for the camera clients only (highlights.lua): rings and labels on what agents act on, seen by the
# director camera players alone; nothing in the game changes. A runtime without it refuses the operator request,
# which stops nobody.
OPERATOR_DRAWS = {"highlights"}

# Extra operator reads for the overlay (same privilege level as `pog.py score`): research progress, the costliest
# finished technologies (to seed "recent milestones" on start), machines starved of power, and how dark it is
# (LuaSurface.darkness, 0 at noon; drives the night lift on the camera captures, nightlift.py).
STREAM_LUA = r"""
local f = game.forces.player
local cur = f.current_research
local done = {}
for name, t in pairs(f.technologies) do
  if t.researched and t.enabled and t.research_unit_count > 0 and not t.prototype.hidden then
    done[#done+1] = {name = name, cost = t.research_unit_count * #t.research_unit_ingredients}
  end
end
table.sort(done, function(a, b) return a.cost > b.cost end)
local top = {}
for i = 1, math.min(4, #done) do top[i] = done[i].name end
local machines, starved = 0, 0
for _, s in pairs(game.surfaces) do
  for _, e in pairs(s.find_entities_filtered{force = f, type = {"assembling-machine", "lab", "mining-drill", "furnace", "inserter"}}) do
    if e.prototype.electric_energy_source_prototype then
      machines = machines + 1
      local st = e.status
      if st == defines.entity_status.low_power or st == defines.entity_status.no_power then starved = starved + 1 end
    end
  end
end
local home = game.surfaces.nauvis
rcon.print(helpers.table_to_json{tick = game.tick, paused = game.tick_paused, research = cur and cur.name or nil,
  progress = cur and f.research_progress or nil, top_done = top, electric_machines = machines, starved = starved,
  darkness = home.darkness, daytime = home.daytime})
"""

# Production history for sparklines: item counts in the last hour, 2-minute buckets (one_hour precision has
# 300 samples of 12 s; sample 1 is the newest). Summed over every surface (Space Age planets and platforms).
FLOW_LUA = r"""
local all = {}
for _, s in pairs(game.surfaces) do all[#all+1] = game.forces.player.get_item_production_statistics(s) end
local out = {}
for _, n in ipairs(ITEMS) do
  local made = 0
  if prototypes.item[n] then for _, stats in ipairs(all) do made = made + stats.get_input_count(n) end end
  if made > 0 then
  local series = {}
  for b = 30, 1, -1 do
    local c = 0
    for _, stats in ipairs(all) do
      for k = (b - 1) * 10 + 1, b * 10 do
        c = c + stats.get_flow_count{name = n, category = "input", precision_index = defines.flow_precision_index.one_hour, sample_index = k, count = true}
      end
    end
    series[#series+1] = c
  end
  out[n] = series
  end
end
rcon.print(helpers.table_to_json(out))
"""

# The base for the site's live map: every building of ours on nauvis (poles left out), from one
# find_entities_filtered, in two grids of category letters. Each cell takes its most telling building (defence > labs >
# oil > assembly > smelting > mining > power > logistics > inserters > belts > rails > pipes).
# - rows: the whole base in CELL-tile cells (doubled until it fits MAXC cells a side), for the overview and outposts.
# - core: the dense core at 1 or 2 tiles a cell (doubled until it fits CMAX), each building's whole footprint filled.
#   The core is the biggest 8-connected group of 32-tile blocks holding at least a fifth of the busiest block's
#   buildings (pipes, belts, inserters and rails not counted, so a long pipeline or rail line does not stretch it),
#   plus 8 tiles. Fewer than 12 such buildings: the whole base.
# Plus enemy spawners and worms near the base, our turrets with their range ([x, y, range], at most 600; artillery left
# out: the site's turret-range layer), and with ore the resource under and around it. Read once a minute
# (live.py), no per-tick work (time it on a world with tools/stream/basemap_time.py). Types the game does not know
# (no Space Age or Elevated Rails) make the read fall back to the base list. No comments inside: one_line() joins
# the lines.
BASEMAP_LUA = r"""
local s = game.surfaces.nauvis
local f = game.forces.player
local CAT = {["ammo-turret"]="D",["electric-turret"]="D",["fluid-turret"]="D",["artillery-turret"]="D",["wall"]="D",["gate"]="D",
  ["lab"]="R",["assembling-machine"]="A",["rocket-silo"]="A",["furnace"]="S",["mining-drill"]="M",["offshore-pump"]="M",
  ["boiler"]="E",["generator"]="E",["solar-panel"]="E",["accumulator"]="E",["reactor"]="E",["burner-generator"]="E",
  ["container"]="L",["logistic-container"]="L",["roboport"]="L",["train-stop"]="L",["transport-belt"]="B",
  ["underground-belt"]="B",["splitter"]="B",["loader"]="B",["loader-1x1"]="B",["inserter"]="I",["pipe"]="P",
  ["pipe-to-ground"]="P",["pump"]="P",["storage-tank"]="P",["straight-rail"]="T",["curved-rail-a"]="T",
  ["curved-rail-b"]="T",["half-diagonal-rail"]="T",["rail-signal"]="T",["rail-chain-signal"]="T"}
local EXTRA = {["lane-splitter"]="B",["cargo-landing-pad"]="L",["agricultural-tower"]="M",["fusion-reactor"]="E",
  ["fusion-generator"]="E",["lightning-attractor"]="E",["rail-ramp"]="T",["rail-support"]="T",
  ["elevated-straight-rail"]="T",["elevated-curved-rail-a"]="T",["elevated-curved-rail-b"]="T",["elevated-half-diagonal-rail"]="T"}
local OIL = {["oil-refinery"]=true,["chemical-plant"]=true,["pumpjack"]=true}
local RANK = {D=12,R=11,O=10,A=9,S=8,M=7,E=6,L=5,I=4,B=3,T=2,P=1}
local LINE = {P=true,B=true,I=true,T=true}
local types, all = {}, {}
for t, c in pairs(CAT) do types[#types+1] = t all[t] = c end
local base = #types
for t, c in pairs(EXTRA) do types[#types+1] = t all[t] = c end
local ok, found = pcall(s.find_entities_filtered, {force = f, type = types})
if not ok then
  local bt = {}
  for i = 1, base do bt[i] = types[i] end
  found = s.find_entities_filtered{force = f, type = bt}
end
local pts = {}
for _, e in pairs(found) do
  local p = e.position
  pts[#pts+1] = {p.x, p.y, OIL[e.name] and "O" or all[e.type], e}
end
local C, MAXC = CELL, MAXCELLS
local cells, x0, y0, x1, y1
while true do
  cells, x0, y0, x1, y1 = {}, nil, nil, nil, nil
  for _, q in ipairs(pts) do
    local cx, cy = math.floor(q[1] / C), math.floor(q[2] / C)
    local row = cells[cy]
    if not row then row = {} cells[cy] = row end
    local old = row[cx]
    if not old or RANK[q[3]] > RANK[old] then row[cx] = q[3] end
    if not x0 or cx < x0 then x0 = cx end
    if not x1 or cx > x1 then x1 = cx end
    if not y0 or cy < y0 then y0 = cy end
    if not y1 or cy > y1 then y1 = cy end
  end
  if not x0 or (x1 - x0 < MAXC and y1 - y0 < MAXC) then break end
  C = C * 2
end
local rows = {}
if x0 then
  for cy = y0, y1 do
    local row, buf = cells[cy] or {}, {}
    for cx = x0, x1 do buf[#buf+1] = row[cx] or "." end
    rows[#rows+1] = (table.concat(buf):gsub("%.+$", ""))
  end
end
local core = nil
if x0 then
  local blocks, top, n = {}, 0, 0
  for _, q in ipairs(pts) do
    if not LINE[q[3]] then
      local k = math.floor(q[1] / 32) .. "," .. math.floor(q[2] / 32)
      blocks[k] = (blocks[k] or 0) + 1
      if blocks[k] > top then top = blocks[k] end
      n = n + 1
    end
  end
  local bx0, by0, bx1, by1 = x0 * C, y0 * C, (x1 + 1) * C, (y1 + 1) * C
  if n >= 12 then
    local lim, dense, seen, best, bestn = math.max(2, top / 5), {}, {}, nil, -1
    for k, v in pairs(blocks) do if v >= lim then dense[k] = v end end
    for k in pairs(dense) do
      if not seen[k] then
        seen[k] = true
        local stack, group, total = {k}, {}, 0
        while #stack > 0 do
          local cur = table.remove(stack)
          local bx, by = cur:match("^(-?%d+),(-?%d+)$")
          bx, by = tonumber(bx), tonumber(by)
          group[#group+1] = {bx, by}
          total = total + dense[cur]
          for dx = -1, 1 do for dy = -1, 1 do
            local nk = (bx + dx) .. "," .. (by + dy)
            if dense[nk] and not seen[nk] then seen[nk] = true stack[#stack+1] = nk end
          end end
        end
        if total > bestn then best, bestn = group, total end
      end
    end
    bx0, by0, bx1, by1 = math.huge, math.huge, -math.huge, -math.huge
    for _, b in ipairs(best) do
      bx0, by0 = math.min(bx0, b[1] * 32 - 8), math.min(by0, b[2] * 32 - 8)
      bx1, by1 = math.max(bx1, b[1] * 32 + 40), math.max(by1, b[2] * 32 + 40)
    end
  end
  local CC = 1
  while (bx1 - bx0) / CC > CMAX or (by1 - by0) / CC > CMAX do CC = CC * 2 end
  local cx0, cy0, cx1, cy1 = math.floor(bx0 / CC), math.floor(by0 / CC), math.floor((bx1 - 1) / CC), math.floor((by1 - 1) / CC)
  local PE = prototypes and prototypes.entity
  local size, fine = {}, {}
  for _, q in ipairs(pts) do
    if q[1] >= bx0 - 8 and q[1] <= bx1 + 8 and q[2] >= by0 - 8 and q[2] <= by1 + 8 then
      local e = q[4]
      local sz = size[e.name]
      if not sz then
        local pr = PE and PE[e.name]
        sz = {pr and pr.tile_width or 1, pr and pr.tile_height or 1}
        size[e.name] = sz
      end
      local w, h = sz[1], sz[2]
      if w ~= h and (e.direction == 4 or e.direction == 12) then w, h = h, w end
      local tx, ty = math.floor(q[1] - w / 2 + 0.01), math.floor(q[2] - h / 2 + 0.01)
      for cy = math.max(cy0, math.floor(ty / CC)), math.min(cy1, math.floor((ty + h - 1) / CC)) do
        local row = fine[cy]
        if not row then row = {} fine[cy] = row end
        for cx = math.max(cx0, math.floor(tx / CC)), math.min(cx1, math.floor((tx + w - 1) / CC)) do
          local old = row[cx]
          if not old or RANK[q[3]] > RANK[old] then row[cx] = q[3] end
        end
      end
    end
  end
  local crows = {}
  for cy = cy0, cy1 do
    local row, buf = fine[cy] or {}, {}
    for cx = cx0, cx1 do buf[#buf+1] = row[cx] or "." end
    crows[#crows+1] = (table.concat(buf):gsub("%.+$", ""))
  end
  core = {cell = CC, x0 = cx0 * CC, y0 = cy0 * CC, w = cx1 - cx0 + 1, h = cy1 - cy0 + 1, rows = crows}
end
local nests = {}
if x0 then
  local m = 96
  for _, e in pairs(s.find_entities_filtered{force = "enemy", type = {"unit-spawner", "turret"},
      area = {{x0 * C - m, y0 * C - m}, {(x1 + 1) * C + m, (y1 + 1) * C + m}}, limit = 200}) do
    nests[#nests+1] = {math.floor(e.position.x), math.floor(e.position.y), e.type == "unit-spawner" and "s" or "w"}
  end
end
local turrets = {}
if x0 then
  local RANGE = {}
  for _, q in ipairs(pts) do
    local e = q[4]
    if q[3] == "D" and #turrets < 600 and (e.type == "ammo-turret" or e.type == "electric-turret" or e.type == "fluid-turret") then
      local r = RANGE[e.name]
      if r == nil then
        r = 0
        pcall(function() local ap = prototypes.entity[e.name].attack_parameters r = ap and ap.range or 0 end)
        RANGE[e.name] = r
      end
      if r > 0 then turrets[#turrets+1] = {math.floor(q[1]), math.floor(q[2]), r} end
    end
  end
end
local ore = nil
if WITHORE and x0 then
  local m = 64
  local ax0, ay0, ax1, ay1 = x0 * C - m, y0 * C - m, (x1 + 1) * C + m, (y1 + 1) * C + m
  local OL = {["iron-ore"]="i",["copper-ore"]="c",["coal"]="k",["stone"]="s",["crude-oil"]="o",["uranium-ore"]="u"}
  local cnt = {}
  for _, e in pairs(s.find_entities_filtered{area = {{ax0, ay0}, {ax1, ay1}}, type = "resource"}) do
    local cx, cy = math.floor(e.position.x / C), math.floor(e.position.y / C)
    local row = cnt[cy]
    if not row then row = {} cnt[cy] = row end
    local cell = row[cx]
    if not cell then cell = {} row[cx] = cell end
    local l = OL[e.name] or "x"
    cell[l] = (cell[l] or 0) + 1
  end
  local ox0, oy0, ox1, oy1 = math.floor(ax0 / C), math.floor(ay0 / C), math.floor(ax1 / C), math.floor(ay1 / C)
  local orows = {}
  for cy = oy0, oy1 do
    local row, buf = cnt[cy] or {}, {}
    for cx = ox0, ox1 do
      local best, bn = ".", 0
      for l, n in pairs(row[cx] or {}) do if n > bn or (n == bn and l < best) then best, bn = l, n end end
      buf[#buf+1] = best
    end
    orows[#orows+1] = (table.concat(buf):gsub("%.+$", ""))
  end
  ore = {cell = C, x0 = ox0 * C, y0 = oy0 * C, w = ox1 - ox0 + 1, rows = orows}
end
rcon.print(helpers.table_to_json{tick = game.tick, cell = C, x0 = x0 and x0 * C or 0, y0 = y0 and y0 * C or 0,
  w = x0 and (x1 - x0 + 1) or 0, h = y0 and (y1 - y0 + 1) or 0, rows = rows, nests = nests, buildings = #pts, ore = ore,
  core = core, turrets = turrets})
"""

CAMERA_LUA = r"""
local i = remote.interfaces.agent_harness
if not (i and i.camera) then rcon.print('{"ok":false,"stub":true}') return end
local r = remote.call("agent_harness", "camera", BODY)
rcon.print(type(r) == "string" and r or helpers.table_to_json({ok = true, result = r}))
"""

# Space Age: where a camera can show each platform (read-only, operator level like SCORE_LUA): its surface name (the
# camera call takes surfaces, the `platforms` read gives none), the hub (the runtime builds remote work around it) and
# the bounds of our entities there, so a fixed view fits the whole platform, and the hub's health in % (onecam.py's
# platform label says it when the hub is hurt). A platform still waiting for its starter
# pack has no surface and is skipped.
PLATFORM_LUA = r"""
local f = game.forces.player
local out = {}
for _, pl in pairs(f.platforms) do
  local ok, s = pcall(function() return pl.valid and pl.surface end)
  if ok and s and s.valid then
    local hub = (pl.hub and pl.hub.valid) and pl.hub.position or {x = 0, y = 0}
    local x0, y0, x1, y1 = hub.x - 6, hub.y - 6, hub.x + 6, hub.y + 6
    for _, e in pairs(s.find_entities_filtered{force = f, limit = 4000}) do
      local p = e.position
      x0, y0, x1, y1 = math.min(x0, p.x), math.min(y0, p.y), math.max(x1, p.x), math.max(y1, p.y)
    end
    local hp = nil
    pcall(function() if pl.hub and pl.hub.valid and pl.hub.max_health > 0 then hp = math.floor(100 * pl.hub.health / pl.hub.max_health) end end)
    out[#out + 1] = {name = pl.name, surface = s.name, hub = {x = hub.x, y = hub.y},
      bounds = {left = x0, top = y0, right = x1, bottom = y1}, hub_health = hp}
  end
end
rcon.print(helpers.table_to_json{platforms = out})
"""

PROBE_LUA = r"""
local i = remote.interfaces.agent_harness
rcon.print(helpers.table_to_json{harness = i ~= nil, camera = (i and i.camera) ~= nil, cameras = (i and i.cameras) ~= nil})
"""


def basemap_lua(cell=4, max_cells=128, ore=False, core_max=160):
    return (BASEMAP_LUA.replace("MAXCELLS", str(int(max_cells))).replace("CMAX", str(int(core_max)))
            .replace("CELL", str(int(cell)))
            .replace("WITHORE", "true" if ore else "false"))


def lua_string(text):
    level = 0
    while f"]{'=' * level}]" in text:
        level += 1
    eq = "=" * level
    return f"[{eq}[{text}]{eq}]"


def one_line(lua):
    return " ".join(l.strip() for l in lua.strip().splitlines() if l.strip())


class Harness:
    def __init__(self, world):
        self.world = world
        self.port = pog.PORTS.get(world) or int(os.environ["POG_RCON_PORT"])
        self.password = open(os.path.expanduser(f"~/.config/pog/rcon-{world}.pw")).read().strip()
        self.lock = threading.Lock()
        self.rcon = None

    def command(self, cmd):
        with self.lock:
            for attempt in (0, 1):
                try:
                    if self.rcon is None:
                        self.rcon = pog.Rcon("127.0.0.1", self.port, self.password, timeout=10)
                    return self.rcon.command(cmd)
                except (OSError, ConnectionError):
                    self.rcon = None
                    if attempt:
                        raise

    def lua(self, lua):
        out = self.command("/silent-command " + one_line(lua))
        return json.loads(out)

    def dispatch(self, action, args=None, player=None, bot=None):
        if action not in READ_ACTIONS:
            raise ValueError(f"{action} is not a read action; the stream service never sends gameplay actions")
        if action == "chat" and not (args or {}).get("peek"):
            raise ValueError("chat must be read with peek:true")
        req = {"id": "stream-" + uuid.uuid4().hex[:12], "action": action, "args": args or {}}
        if bot:
            req["bot"] = bot
        else:
            req["player"] = player or 1
        raw = self.command(f'/silent-command rcon.print(remote.call("agent_harness", "dispatch", {lua_string(json.dumps(req))}))')
        reply = json.loads(raw)
        if not reply.get("ok"):
            raise RuntimeError(f"{action}: {reply.get('error', {}).get('message', raw)}")
        return reply.get("result", {}), reply.get("tick")

    def operator_read(self, action, args=None):
        """Operator reads (`operator: true`, no player): a failure stops nobody on a runtime that knows them, but an
        older runtime treats the request as player 1's unknown action, so callers gate on `describe` first."""
        if action not in OPERATOR_READS:
            raise ValueError(f"{action} is not an operator read")
        req = {"id": "stream-" + uuid.uuid4().hex[:12], "action": action, "args": args or {}, "operator": True}
        raw = self.command(f'/silent-command rcon.print(remote.call("agent_harness", "dispatch", {lua_string(json.dumps(req))}))')
        reply = json.loads(raw)
        if not reply.get("ok"):
            raise RuntimeError(f"{action}: {reply.get('error', {}).get('message', raw)}")
        return reply.get("result", {}), reply.get("tick")

    def operator_draw(self, action, args=None):
        """Camera-only drawing (OPERATOR_DRAWS) through the same operator dispatch; returns the reply."""
        if action not in OPERATOR_DRAWS:
            raise ValueError(f"{action} is not an operator draw")
        req = {"id": "stream-" + uuid.uuid4().hex[:12], "action": action, "args": args or {}, "operator": True}
        return json.loads(self.command(f'/silent-command rcon.print(remote.call("agent_harness", "dispatch", {lua_string(json.dumps(req))}))'))

    def score(self):
        return self.lua(pog.SCORE_LUA)

    def extras(self):
        return self.lua(STREAM_LUA)

    def flows(self, items):
        lua = FLOW_LUA.replace("ITEMS", "{" + ",".join(json.dumps(i) for i in items) + "}")
        return self.lua(lua)

    def basemap(self, cell=4, max_cells=128, ore=False):
        """The base as grids of category letters (BASEMAP_LUA: the whole base, and its dense core at 1-2 tiles a cell);
        read-only, for the site's live map. With ore, also the resource under and around it (64 tiles out), one letter
        per cell for the commonest resource there."""
        m = self.lua(basemap_lua(cell, max_cells, ore))
        for key in ("rows", "nests"):  # table_to_json writes an empty table as {}
            if not isinstance(m.get(key), list):
                m[key] = []
        for key in ("ore", "core"):
            if isinstance(m.get(key), dict) and not isinstance(m[key].get("rows"), list):
                m[key]["rows"] = []
        return m

    def probe(self):
        return self.lua(PROBE_LUA)

    def platform_views(self):
        """{platform name: {surface, hub, bounds}} for the platforms that have a surface (PLATFORM_LUA)."""
        rows = self.lua(PLATFORM_LUA).get("platforms")
        return {r["name"]: r for r in (rows if isinstance(rows, list) else [])}

    def camera(self, body):
        return json.loads(self.command("/silent-command " + one_line(CAMERA_LUA.replace("BODY", lua_string(json.dumps(body))))))
