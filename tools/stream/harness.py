"""Read-only access to a pog world for the stream service.

Talks RCON directly (one persistent connection) and sends the same
`remote.call("agent_harness", "dispatch", json)` that `bin/fh` sends, so a poll
costs one round trip instead of a node process. Only whitelisted read actions
can be dispatched: a failed non-read call stops that player's current action.
"""
import json, os, sys, threading, time, uuid

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.dont_write_bytecode = True  # tools/__pycache__ is tracked in git; do not rewrite it
import pog  # noqa: E402  (tools/pog.py: Rcon client, ports, SCORE_LUA)

# Never add a gameplay action here. `profiles` is read-only per docs/BOTS-API.md, but a runtime that does not
# know it yet treats it as a failed mutation and stops player 1, so callers gate it on `has_bots_runtime()`.
# `board` and `board_events` (docs/BOARD-API.md) are only sent once `describe` (read-only) lists them.
# `platforms` (Space Age) is a read in the runtime; the overlay sends it only once the score lists a platform.
# `reminders` (reminders.lua) is a read in the runtime; live.py stops asking a runtime that refuses it.
# `board_focus` with no id is a read (each agent's focus rows, d20 batch54 N3); with an id it sets a focus, so it is refused.
# `board_progress` with no arguments reads the stored checks (progress.lua; d22 batch75 AK11: the projects' stall facts on
# the site); with owner or id it reads the game again (388 ms for the whole board on world n), so those are refused.
READ_ACTIONS = {"status", "profiles", "chat", "power", "cameras", "describe", "board", "board_events", "platforms", "reminders",
                "board_focus", "board_progress"}
# Operator reads (eng/board audience.lua): every agent's `confess` lines, for viewers only. Gated on `describe`.
OPERATOR_READS = {"confessions", "tells", "operator_requests", "attack_groups_live", "big_enemies_live", "hauling", "loadout", "clouds",
                  "efficiency", "chronicle", "artillery_live",
                  "library_areas",  # (d21 batch68 AD2) the library's placed areas and their hookups, for the live map
                  "net_map",  # (d21 batch68 AD3) a planet's electric and logistic networks and items' sources and consumers
                  "chart"}  # (d22 batch97 BG3) the site's chart: chunks' tiles and entities, the dirty set (chart.lua)
# Operator drawing for the camera clients only (highlights.lua): rings and labels on what agents act on, seen by the
# director camera players alone; nothing in the game changes. A runtime without it refuses the operator request,
# which stops nobody.
OPERATOR_DRAWS = {"highlights"}

# Extra operator reads for the overlay (same privilege level as `pog.py score`): research progress, the costliest
# finished technologies (to seed "recent milestones" on start), the infinite technologies researched at least once
# (repeating: name, level reached, next level as the tech tree names it, researching; d20 batch57 S4, viewer Foobator;
# inside the loop over the technologies this read already made: about 2 ms for the loop alone on the private copy), machines starved of power, and how dark it is
# (LuaSurface.darkness, 0 at noon; drives the night lift on the camera captures, nightlift.py). The machine counts come
# from the harness census when it has a pass (pog.CENSUS_FN; the find over every surface was 25-27 ms of this read's
# 32 ms on world n, 2026-10-14 22:00, every 3 s), else from that find.
STREAM_LUA = pog.CENSUS_FN + r"""
local f = game.forces.player
local cur = f.current_research
local done = {}
local rep = {}
for name, t in pairs(f.technologies) do
  if t.researched and t.enabled and t.research_unit_count > 0 and not t.prototype.hidden then
    done[#done+1] = {name = name, cost = t.research_unit_count * #t.research_unit_ingredients}
  end
  local p = t.prototype
  local now = cur ~= nil and cur.name == name
  if p.max_level >= 4294967295 and (t.level > p.level or now) and not p.hidden then
    rep[#rep+1] = {name = name, level = t.level - 1, next = t.level, researching = now or nil}
  end
end
table.sort(done, function(a, b) return a.cost > b.cost end)
local top = {}
for i = 1, math.min(4, #done) do top[i] = done[i].name end
local machines, starved = 0, 0
local counted = census("extras")
if counted then machines, starved = counted.electric_machines, counted.starved
else
  for _, s in pairs(game.surfaces) do
    for _, e in pairs(s.find_entities_filtered{force = f, type = {"assembling-machine", "lab", "mining-drill", "furnace", "inserter"}}) do
      if e.prototype.electric_energy_source_prototype then
        machines = machines + 1
        local st = e.status
        if st == defines.entity_status.low_power or st == defines.entity_status.no_power then starved = starved + 1 end
      end
    end
  end
end
local home = game.surfaces.nauvis
local connected = {}
for _, pl in pairs(game.connected_players or {}) do connected[#connected + 1] = pl.name end
rcon.print(helpers.table_to_json{tick = game.tick, paused = game.tick_paused, research = cur and cur.name or nil,
  progress = cur and f.research_progress or nil, top_done = top, repeating = rep, electric_machines = machines, starved = starved,
  darkness = home.darkness, daytime = home.daytime, connected = connected})
"""

# Production history for sparklines: item counts in the last hour, 30 two-minute buckets, oldest first, summed over
# every surface (Space Age planets and platforms). The ten-hour precision's samples are two minutes each (sample 1 the
# newest), so a bucket is one read; only surfaces where the item was ever made are read (d16 perf: the one-hour form,
# ten samples a bucket on all 9 surfaces for 38 items, was about 118 ms in one tick every 30 s on world n, 342
# item-surface pairs at 0.35 ms; 141 of them had ever made anything). (d24 batch152 PX1) A read by name counts normal
# quality only, {name, quality} that quality, and input_counts and output_counts every quality's total: each quality
# the item was ever counted at on a surface is read and summed; one other than normal only with any in the last hour
# (one read; 106 item-surface-quality pairs had a count on a copy of world n, d24 08:50, and reading each one's 30
# buckets took the read from 40 to 46 ms). (No Lua comments: one_line joins the lines.)
# (d24 batch184 QAA2, operator-todo 09:55: about 10 ms a read on world n, every 30 s) On a copy of world n (18:11 save)
# the surfaces took about 23 ms and table_to_json 34.6 ms for its 5.5 KB (1230 float counts): the reply's text is now
# built with string.format("%d") on each count rounded to a whole number (FLOW_JSON), and a read covers one part of the
# surfaces (SPLIT: parts, part): the planets dealt out in turn (nauvis, vulcanus, fulgora, gleba, aquilo: parts 0, 1, 2,
# 0, 1; by index the three heaviest, nauvis, fulgora and aquilo, fell in one part), a platform by its index mod parts;
# live.py reads one part a poll.
FLOW_JSON = r"""
local parts = {}
for n, series in pairs(out) do
  local nums = {}
  for i = 1, 30 do nums[i] = string.format("%d", math.floor((series[i] or 0) + 0.5)) end
  parts[#parts + 1] = "\"" .. n .. "\":[" .. table.concat(nums, ",") .. "]"
end
rcon.print("{" .. table.concat(parts, ",") .. "}")
"""
FLOW_LUA = r"""
local f = game.forces.player
local out = {}
local PARTS, PART = SPLIT
local QS = {"normal"}
for name, q in pairs(prototypes.quality) do if name ~= "normal" and not q.hidden then QS[#QS+1] = name end end
local k = 0
for _, s in pairs(game.surfaces) do
  local slot = s.index
  if s.planet then slot = k k = k + 1 end
  if slot % PARTS == PART then
  local st = f.get_item_production_statistics(s)
  local totals = st.input_counts
  for _, n in ipairs(ITEMS) do
    local all = totals[n]
    local normal = all and all > 0 and prototypes.item[n] and st.get_input_count(n) or 0
    for _, q in ipairs(all and all > 0 and QS or {}) do
      local id = q == "normal" and n or {name = n, quality = q}
      if (q == "normal" and normal > 0) or (q ~= "normal" and all > normal and prototypes.item[n] and st.get_input_count(id) > 0
          and st.get_flow_count{name = id, category = "input", precision_index = defines.flow_precision_index.one_hour, count = true} > 0) then
        local series = out[n] or {}
        for b = 30, 1, -1 do
          local c = st.get_flow_count{name = id, category = "input", precision_index = defines.flow_precision_index.ten_hours, sample_index = b, count = true}
          series[31 - b] = (series[31 - b] or 0) + c
        end
        out[n] = series
      end
    end
  end
  end
end
""" + FLOW_JSON

# Science packs the labs used, as FLOW_LUA's 30 two-minute buckets over the last hour, oldest first (the production
# statistics' consumption side: labs are what consume science packs), read the same way. Only surfaces where a pack
# was ever consumed are read. Both sum every quality the item was ever counted at there (d24 batch152 PX1).
USED_FLOW_LUA = r"""
local f = game.forces.player
local out = {}
local QS = {"normal"}
for name, q in pairs(prototypes.quality) do if name ~= "normal" and not q.hidden then QS[#QS+1] = name end end
for _, s in pairs(game.surfaces) do
  local st = f.get_item_production_statistics(s)
  local totals = st.output_counts
  for _, n in ipairs(ITEMS) do
    local all = totals[n]
    local normal = all and all > 0 and prototypes.item[n] and st.get_output_count(n) or 0
    for _, q in ipairs(all and all > 0 and QS or {}) do
      local id = q == "normal" and n or {name = n, quality = q}
      if (q == "normal" and normal > 0) or (q ~= "normal" and all > normal and prototypes.item[n] and st.get_output_count(id) > 0
          and st.get_flow_count{name = id, category = "output", precision_index = defines.flow_precision_index.one_hour, count = true} > 0) then
        local series = out[n] or {}
        for b = 30, 1, -1 do
          local c = st.get_flow_count{name = id, category = "output", precision_index = defines.flow_precision_index.ten_hours, sample_index = b, count = true}
          series[31 - b] = (series[31 - b] or 0) + c
        end
        out[n] = series
      end
    end
  end
end
rcon.print(helpers.table_to_json(out))
"""

# The base for the site's live map: every building of ours on nauvis (poles left out), from one
# find_entities_filtered, in two grids of category letters. Each cell takes its most telling building (defence (turrets)
# > walls and gates (W, d22 batch75 AK4) > labs > oil > assembly > smelting > mining > power > logistics > inserters >
# belts > rails > pipes).
# - rows: the whole base in CELL-tile cells (doubled until it fits MAXC cells a side), for the overview and outposts.
# - core: the dense core at 1 or 2 tiles a cell (doubled until it fits CMAX), each building's whole footprint filled.
#   The core is the biggest 8-connected group of 32-tile blocks holding at least a fifth of the busiest block's
#   buildings (pipes, belts, inserters and rails not counted, so a long pipeline or rail line does not stretch it),
#   plus 8 tiles. Fewer than 12 such buildings: the whole base.
# Plus enemy spawners and worms near the base, our turrets with their range ([x, y, range], at most 600; artillery left
# out: the site's turret-range layer), and with ore the resource under and around it. Read once a minute
# (live.py), no per-tick work (time it on a world with tools/stream/basemap_time.py). Types the game does not know
# (no Space Age or Elevated Rails) make the read fall back to the base list. No comments inside: one_line() joins
# the lines. With the stream's sizes (cell 4, 128 cells, core 160) the harness census's last pass answers instead
# (pog.CENSUS_FN; this read took 134 ms on world n, 169 ms with ore, 2026-10-14 22:00): the same map, its tick the
# pass's; asked with ore before the census has an ore grid, it comes without ore (the census reads it next pass).
BASEMAP_LUA = pog.CENSUS_FN + r"""
if CELL == 4 and MAXCELLS == 128 and CMAX == 160 then
  local counted = census("basemap", WITHORE)
  if counted and type(counted.basemap) == "table" then
    rcon.print(helpers.table_to_json(counted.basemap))
    return
  end
end
local s = game.surfaces.nauvis
local f = game.forces.player
local CAT = {["ammo-turret"]="D",["electric-turret"]="D",["fluid-turret"]="D",["artillery-turret"]="D",["wall"]="W",["gate"]="W",
  ["lab"]="R",["assembling-machine"]="A",["rocket-silo"]="A",["furnace"]="S",["mining-drill"]="M",["offshore-pump"]="M",
  ["boiler"]="E",["generator"]="E",["solar-panel"]="E",["accumulator"]="E",["reactor"]="E",["burner-generator"]="E",
  ["container"]="L",["logistic-container"]="L",["roboport"]="L",["train-stop"]="L",["transport-belt"]="B",
  ["underground-belt"]="B",["splitter"]="B",["loader"]="B",["loader-1x1"]="B",["inserter"]="I",["pipe"]="P",
  ["pipe-to-ground"]="P",["pump"]="P",["storage-tank"]="P",["straight-rail"]="T",["curved-rail-a"]="T",
  ["curved-rail-b"]="T",["half-diagonal-rail"]="T",["rail-signal"]="T",["rail-chain-signal"]="T",["heat-pipe"]="E"}
local EXTRA = {["lane-splitter"]="B",["cargo-landing-pad"]="L",["agricultural-tower"]="M",["fusion-reactor"]="E",
  ["fusion-generator"]="E",["lightning-attractor"]="E",["rail-ramp"]="T",["rail-support"]="T",
  ["elevated-straight-rail"]="T",["elevated-curved-rail-a"]="T",["elevated-curved-rail-b"]="T",["elevated-half-diagonal-rail"]="T"}
local OIL = {["oil-refinery"]=true,["chemical-plant"]=true,["pumpjack"]=true}
local RANK = {D=13,W=12,R=11,O=10,A=9,S=8,M=7,E=6,L=5,I=4,B=3,T=2,P=1}
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
local states = {}
for k, v in pairs(defines.space_platform_state) do states[v] = k end
for _, pl in pairs(f.platforms) do
  local ok, s = pcall(function() return pl.valid and pl.surface end)
  if ok and s and s.valid then
    local w = {}
    pcall(function()
      w.state, w.paused, w.speed = states[pl.state], pl.paused, pl.speed
      local c = pl.space_connection
      if c then w.at = c.from.name .. "->" .. c.to.name .. " " .. math.floor((pl.distance or 0) * 100 + 0.5) .. "%"
      elseif pl.space_location then w.at = pl.space_location.name else w.at = "in transit" end
    end)
    local hub = (pl.hub and pl.hub.valid) and pl.hub.position or {x = 0, y = 0}
    local x0, y0, x1, y1 = hub.x - 6, hub.y - 6, hub.x + 6, hub.y + 6
    for _, e in pairs(s.find_entities_filtered{force = f, limit = 4000}) do
      local p = e.position
      x0, y0, x1, y1 = math.min(x0, p.x), math.min(y0, p.y), math.max(x1, p.x), math.max(y1, p.y)
    end
    local hp = nil
    pcall(function() if pl.hub and pl.hub.valid and pl.hub.max_health > 0 then hp = math.floor(100 * pl.hub.health / pl.hub.max_health) end end)
    local guns = {}
    for _, e in pairs(s.find_entities_filtered{force = f, type = {"ammo-turret", "electric-turret", "fluid-turret", "turret"}, limit = 300}) do
      guns[#guns + 1] = {n = e.name, q = e.quality and e.quality.name or "normal", x = e.position.x, y = e.position.y}
    end
    out[#out + 1] = {name = pl.name, surface = s.name, hub = {x = hub.x, y = hub.y},
      bounds = {left = x0, top = y0, right = x1, bottom = y1}, hub_health = hp, turrets = guns, where = w}
  end
end
rcon.print(helpers.table_to_json{platforms = out})
"""

# (d20 batch50 A1) A turret's range as its tooltip shows it: the prototype's range times its quality's range_multiplier,
# for the (name, quality) pairs NAMES lists; read once per pair (Harness.turret_ranges caches them).
TURRET_RANGE_LUA = r"""
local out = {}
for _, k in pairs(NAMES) do
  local r = nil
  pcall(function()
    local p = prototypes.entity[k.n]
    r = p.turret_range or (p.attack_parameters and p.attack_parameters.range)
    local q = prototypes.quality[k.q]
    if r and q and q.range_multiplier then r = r * q.range_multiplier end
  end)
  out[#out + 1] = {n = k.n, q = k.q, range = r}
end
rcon.print(helpers.table_to_json{ranges = out})
"""

# (d24 batch170 QM1, viewer Caleb: "show a view of the front of Asterion when it is in flight") The hull's box from its
# foundation tiles, as the harness's asteroid watch finds it (asteroidwatch.lua M.hull: the chunks holding foundation,
# narrowed to the first and last row and column that hold any), and the bow: the x extent of the foundation in the
# hull's first ROWS rows. NAMES: {[name] = true} for the platforms to read. Read-only; a few count_tiles_filtered calls
# per platform, most of them stopping at the first tile (Harness.platform_hulls reads a platform at most every
# HULL_EVERY s).
PLATFORM_HULL_LUA = r"""
local want = NAMES
local F = "space-platform-foundation"
local out = {}
for _, pl in pairs(game.forces.player.platforms) do
  local ok, s = pcall(function() return pl.valid and want[pl.name] and pl.surface end)
  if ok and s and s.valid then
    local x0, y0, x1, y1
    for ch in s.get_chunks() do
      local a = ch.area
      if s.count_tiles_filtered{area = a, name = F, limit = 1} > 0 then
        x0, y0 = math.min(x0 or a.left_top.x, a.left_top.x), math.min(y0 or a.left_top.y, a.left_top.y)
        x1, y1 = math.max(x1 or a.right_bottom.x, a.right_bottom.x), math.max(y1 or a.right_bottom.y, a.right_bottom.y)
      end
    end
    if x0 then
      local function any(ax, ay, bx, by) return s.count_tiles_filtered{area = {{ax, ay}, {bx, by}}, name = F, limit = 1} > 0 end
      local function lowest(lo, hi, has)
        while lo < hi do
          local mid = math.floor((lo + hi) / 2)
          if has(mid) then hi = mid else lo = mid + 1 end
        end
        return lo
      end
      local top = lowest(y0 + 1, y1, function(b) return any(x0, y0, x1, b) end) - 1
      local bottom = y1 - lowest(1, y1 - y0, function(k) return any(x0, y1 - k, x1, y1) end)
      local left = lowest(x0 + 1, x1, function(b) return any(x0, y0, b, y1) end) - 1
      local right = x1 - lowest(1, x1 - x0, function(k) return any(x1 - k, y0, x1, y1) end)
      local by = math.min(bottom + 1, top + ROWS)
      local bl = lowest(left + 1, right + 1, function(b) return any(left, top, b, by) end) - 1
      local br = right + 1 - lowest(1, right + 1 - left, function(k) return any(right + 1 - k, top, right + 1, by) end)
      out[#out + 1] = {name = pl.name, surface = s.name, hull = {left = left, top = top, right = right + 1, bottom = bottom + 1},
        bow = {left = bl, top = top, right = br + 1, bottom = by}}
    end
  end
end
rcon.print(helpers.table_to_json{hulls = out})
"""

# The other planets' coarse maps (viewers craigNZ830 and Foobator, d15 07:05: the live map showed Nauvis only): the
# harness census's last pass (census.lua: every planet but Nauvis, each building's centre and category, a grid made in
# steps after the walk), read as an operator census read: part planets lists them (name, buildings, cell, size), part
# basemap with surface gives one. Both answer from storage, no find; nil (no harness, no census yet) prints {}.
PLANET_READ_LUA = r"""
local ok, r = pcall(function()
  local i = remote.interfaces.agent_harness
  if not (i and i.dispatch) then return nil end
  local req = helpers.table_to_json{id = "census-planet-" .. game.tick .. "-" .. math.random(1, 1000000000), operator = true,
    action = "census", args = ARGS}
  return helpers.json_to_table(remote.call("agent_harness", "dispatch", req))
end)
if ok and type(r) == "table" and r.ok and type(r.result) == "table" and r.result.ready then rcon.print(helpers.table_to_json(r.result))
else rcon.print("{}") end
"""


def planet_read_lua(surface=None):
    """PLANET_READ_LUA asking for the list (surface None) or one planet's map."""
    args = '{part = "planets"}' if surface is None else '{part = "basemap", surface = ' + lua_string(str(surface)) + '}'
    return PLANET_READ_LUA.replace("ARGS", args)


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


SLOW_RCON_S = float(os.environ.get("POG_SLOW_RCON_S", 0.4))  # log game calls slower than this (stderr)


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
                    t0 = time.monotonic()
                    out = self.rcon.command(cmd)
                    took = time.monotonic() - t0
                    if took > SLOW_RCON_S:  # 21:40 2026-10-14: the game stalled ~450 ms every 3 s while this service ran
                        print(f"[slow-rcon] {took:.2f}s {len(out)} B: {cmd[:160]}", file=sys.stderr, flush=True)
                    return out
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
        if action == "board_focus" and set(args or {}) - {"peek"}:
            raise ValueError("board_focus is read with no arguments (with an id it sets a focus)")
        if action == "board_progress" and set(args or {}) - {"peek"}:
            raise ValueError("board_progress is read with no arguments (owner or id reads the game again)")
        # (d24 batch148 PT1, Astra #2159) reader: a read made as an agent by this service, never the agent's own call (the
        # harness never pauses its queue or stops its character for it); an older runtime ignores the field
        req = {"id": "stream-" + uuid.uuid4().hex[:12], "action": action, "args": args or {}, "reader": "stream"}
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

    def flows(self, items, part=0, parts=1):
        """{item: 30 two-minute counts, oldest first} over one part of the surfaces (FLOW_LUA: the planets in turn, a
        platform by its index mod parts)."""
        lua = FLOW_LUA.replace("ITEMS", "{" + ",".join(json.dumps(i) for i in items) + "}").replace("SPLIT", f"{int(parts)}, {int(part)}")
        return self.lua(lua)

    def used_flows(self, items):
        """{pack: 30 two-minute counts the labs used, oldest first} (USED_FLOW_LUA)."""
        lua = USED_FLOW_LUA.replace("ITEMS", "{" + ",".join(json.dumps(i) for i in items) + "}")
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

    def planets(self):
        """[{name, buildings, cell, w, h}] of the other planets the census has a coarse map of ([] before its first pass)."""
        r = self.lua(planet_read_lua())
        return r.get("planets") if isinstance(r, dict) and isinstance(r.get("planets"), list) else []

    def planet_map(self, surface):
        """One other planet's coarse map {tick, cell, x0, y0, w, h, rows, buildings, core (its dense core as Nauvis's: the
        footprints at 1-2 tiles a cell, census.lua)}, or None."""
        r = self.lua(planet_read_lua(surface))
        m = r.get("basemap") if isinstance(r, dict) else None
        if not isinstance(m, dict):
            return None
        if not isinstance(m.get("rows"), list):  # table_to_json writes an empty table as {}
            m["rows"] = []
        if isinstance(m.get("core"), dict) and not isinstance(m["core"].get("rows"), list):  # (d21 batch68 AD1) its dense core
            m["core"]["rows"] = []
        return dict(m, surface=surface)

    def vehicles(self):
        """(d26 batch233 VM, viewer Aurora site:5019) the census's vehicles part: our spidertrons, each where our force last
        saw it (census.lua vehicles): {tick, rows [{unit_number, name, type, surface, position, seen_tick, age_s, visible,
        unseen, driver, remote, remote_target, sent_by, sent_tick, destination, route_targets}], total}, or None (no
        harness, no census pass yet, or a runtime without the part). From storage and the kept entities: 0.07-0.12 ms on
        world n for its 3 spidertrons (d26)."""
        r = self.lua(PLANET_READ_LUA.replace("ARGS", '{part = "vehicles"}'))
        if not isinstance(r, dict) or r.get("part") != "vehicles":
            return None
        rows = r.get("vehicles") if isinstance(r.get("vehicles"), list) else []  # table_to_json writes an empty table as {}
        return {"tick": r.get("tick"), "rows": [x for x in rows if isinstance(x, dict)], "total": r.get("vehicles_total") or len(rows)}

    def probe(self):
        return self.lua(PROBE_LUA)

    def platform_views(self):
        """{platform name: {surface, hub, bounds, guns, where}} for the platforms that have a surface (PLATFORM_LUA). guns
        (d20 batch50 A1): each turret's position and range, the range from turret_ranges. where (d22 batch75 AK2, viewer
        Foobator: only the first 2 in transit had a progress bar): {state, paused, speed, at} for every platform, `at` as
        the platforms read gives it ("from->to N%" on a space connection, N from `from`; a location; "in transit")."""
        rows = self.lua(PLATFORM_LUA).get("platforms")
        rows = rows if isinstance(rows, list) else []
        turrets = [t for r in rows for t in (r.get("turrets") if isinstance(r.get("turrets"), list) else [])]
        try:
            ranges = self.turret_ranges({(t.get("n"), t.get("q") or "normal") for t in turrets if t.get("n")})
        except Exception as e:  # no ranges: no guns key, the shot frames the ship as before
            print(f"[harness] turret ranges failed: {e}", flush=True)
            ranges = None
        for r in rows:
            if ranges is None:
                r.pop("turrets", None)
            elif isinstance(r.get("turrets"), list):
                r["guns"] = [{"x": t["x"], "y": t["y"], "range": ranges[(t["n"], t.get("q") or "normal")]}
                             for t in r.pop("turrets") if ranges.get((t.get("n"), t.get("q") or "normal"))]
        return {r["name"]: r for r in rows}

    BOW_ROWS = 24      # the bow: the foundation's x extent in the hull's first this many rows
    HULL_EVERY = 600.0  # seconds a platform's hull read stands (agents build in flight; the read is not free)

    def platform_hulls(self, names, now=None):
        """(d24 batch170 QM1) {name: {surface, hull, bow}} for these platforms (PLATFORM_HULL_LUA: the foundation
        tiles' box, as the asteroid watch finds it, and the bow's x extent in its first BOW_ROWS rows), each read
        again after HULL_EVERY s; at most two read per call. A platform without foundation (or gone) is left out."""
        now = time.time() if now is None else now
        cache = self.__dict__.setdefault("_hulls", {})  # name -> (read at, row or None)
        due = sorted(n for n in names if n not in cache or now - cache[n][0] >= self.HULL_EVERY)[:2]
        if due:
            want = "{" + ", ".join(f"[ {lua_string(n)} ] = true" for n in due) + "}"
            rows = self.lua(PLATFORM_HULL_LUA.replace("NAMES", want).replace("ROWS", str(int(self.BOW_ROWS)))).get("hulls")
            got = {r.get("name"): r for r in (rows if isinstance(rows, list) else []) if isinstance(r, dict)}
            for n in due:
                cache[n] = (now, got.get(n))
        return {n: cache[n][1] for n in names if n in cache and cache[n][1]}

    def turret_ranges(self, keys):
        """{(name, quality): range} for these turret kinds; each pair read from the prototypes once (TURRET_RANGE_LUA)
        and cached, so a platforms read asks only for kinds it has not seen."""
        cache = self.__dict__.setdefault("_turret_ranges", {})
        new = sorted(k for k in keys if k not in cache)
        if new:
            names = "{" + ", ".join("{n = %s, q = %s}" % (lua_string(n), lua_string(q)) for n, q in new) + "}"
            for row in self.lua(TURRET_RANGE_LUA.replace("NAMES", names)).get("ranges") or []:
                cache[(row.get("n"), row.get("q"))] = row.get("range")
            for k in new:
                cache.setdefault(k, None)
        return {k: cache.get(k) for k in keys}

    def camera(self, body):
        return json.loads(self.command("/silent-command " + one_line(CAMERA_LUA.replace("BODY", lua_string(json.dumps(body))))))
