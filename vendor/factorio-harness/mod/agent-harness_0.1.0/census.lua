-- The census: what the host services' periodic reads counted with one find over every surface in a single tick
-- (operator 22:00, task-slowreads: the stream service's extras read 32 ms every 3 s, the live map 134 ms every minute
-- (169 ms with ore), the analyst's snapshot 96 ms and machines 36 ms every 90 s, on world n; a find costs about every
-- entity in its area, ours or not). A background pass walks every surface in bands (walk.lua), SLICE entities read a
-- step, the steps spread over PERIOD; the operator read `census` returns the last complete pass:
-- - extras: our assembling machines, labs, drills, furnaces and inserters with an electric energy source, and those
--   low on or out of power (tools/stream/harness.py STREAM_LUA's electric_machines and starved);
-- - snapshot: per surface the count of the analyst's building types (tools/analyst/game.py SNAPSHOT_LUA's
--   surfaces_with_buildings), and per name the force's count of each of them (LuaForce.get_entity_count, read when
--   asked: an engine count);
-- - machines: name|recipe (or a drill's ore) -> status -> count (MACHINES_LUA);
-- - basemap: Nauvis as the site's live map draws it (BASEMAP_LUA: rows, core, nests, turrets, and ore when it was
--   asked for in the last ORE_WANT ticks), its grids made in steps after the walk.
-- Each part says as_of (the tick its pass started). Robots and vehicles move during a pass: one may count twice or
-- not at all in a surface's count. Storage only; nothing in the game changes.
local snapfail = require('snapfail')
local pair = require('numtext').pair
return function(api)
  local M = {operator={}}
  local walk = api.walk or require('walk'){state=api.state}
  -- SLICE: entities read a step. d16 perf: at 200 a Nauvis slice took 8-13 ms on world n with the memory hooks, and with
  -- 770 steps a pass walk.every gives a step every tick, so the Nauvis walk ran 245 ticks at 22-44 ticks/s; at 100
  -- a step is half that and the pass spreads over more of its period. GRID: points a step in the grid stages.
  local SLICE, GRID, PERIOD, NEST_BAND, ORE_BAND, ORE_WANT, ORE_EVERY = 100, 800, 1800, 32, 2, 36000, 18000
  -- (d21 batch73 AI: census.step took 7.2 ms a tick on world n, d21 19:55, a step every tick and each pass begun as the
  -- last ended) the pass is paced by work: WORK units a tick, an entity read (with its sighting for the fog and belt
  -- memory) one unit, an entity a band's find returns FIND_COST, a resource the ore grid counts ORE_COST, a find of a
  -- band BAND_COST, a point of a coarse grid GRID_COST, of a dense core FINE_COST; measured on the private copy of
  -- world n (docs/usage.md d21 batch73)
  local WORK, WORK_CAP, FIND_COST, ORE_COST, BAND_COST, GRID_COST, FINE_COST = 8, 32, 0.2, 0.2, 5, 0.05, 0.2
  local function set(list) local t = {} for _, x in ipairs(list) do t[x] = true end return t end
  local STREAM = set{'assembling-machine', 'lab', 'mining-drill', 'furnace', 'inserter'}
  local SNAP_LIST = {'assembling-machine', 'furnace', 'mining-drill', 'lab', 'boiler', 'generator', 'solar-panel', 'accumulator',
    'reactor', 'offshore-pump', 'rocket-silo', 'roboport', 'ammo-turret', 'electric-turret', 'fluid-turret', 'artillery-turret', 'radar',
    'inserter', 'transport-belt', 'wall', 'electric-pole', 'construction-robot', 'logistic-robot', 'beacon', 'car', 'locomotive',
    'cargo-wagon', 'asteroid-collector', 'thruster', 'space-platform-hub', 'agricultural-tower', 'cargo-landing-pad'}
  local SNAP = set(SNAP_LIST)
  local MACH = set{'assembling-machine', 'furnace', 'lab', 'mining-drill', 'rocket-silo', 'boiler', 'generator'}
  local GATE = set{'inserter', 'pump', 'offshore-pump', 'assembling-machine', 'furnace', 'mining-drill', 'lamp', 'power-switch',
    'transport-belt', 'train-stop', 'rail-signal', 'rail-chain-signal', 'agricultural-tower', 'asteroid-collector', 'loader', 'loader-1x1'}
  local GATES_MAX = 1024
  -- The live map's categories (BASEMAP_LUA's CAT and EXTRA, OIL, RANK, LINE). (d22 batch75 AK4, viewer Foobator:
  -- "can walls be a separate item?") walls and gates W, under turrets (D) where both share a cell.
  local CAT = {['ammo-turret']='D', ['electric-turret']='D', ['fluid-turret']='D', ['artillery-turret']='D', wall='W', gate='W',
    lab='R', ['assembling-machine']='A', ['rocket-silo']='A', furnace='S', ['mining-drill']='M', ['offshore-pump']='M',
    boiler='E', generator='E', ['solar-panel']='E', accumulator='E', reactor='E', ['burner-generator']='E',
    container='L', ['logistic-container']='L', roboport='L', ['train-stop']='L', ['transport-belt']='B',
    ['underground-belt']='B', splitter='B', loader='B', ['loader-1x1']='B', inserter='I', pipe='P',
    ['pipe-to-ground']='P', pump='P', ['storage-tank']='P', ['straight-rail']='T', ['curved-rail-a']='T',
    ['curved-rail-b']='T', ['half-diagonal-rail']='T', ['rail-signal']='T', ['rail-chain-signal']='T',
    ['lane-splitter']='B', ['cargo-landing-pad']='L', ['agricultural-tower']='M', ['fusion-reactor']='E',
    ['fusion-generator']='E', ['lightning-attractor']='E', ['rail-ramp']='T', ['rail-support']='T',
    ['elevated-straight-rail']='T', ['elevated-curved-rail-a']='T', ['elevated-curved-rail-b']='T', ['elevated-half-diagonal-rail']='T',
    ['heat-pipe']='E'}
  local OIL = {['oil-refinery']=true, ['chemical-plant']=true, pumpjack=true}
  local RANK = {D=13, W=12, R=11, O=10, A=9, S=8, M=7, E=6, L=5, I=4, B=3, T=2, P=1}
  local LINE = {P=true, B=true, I=true, T=true}
  local RANGED = {['ammo-turret']=true, ['electric-turret']=true, ['fluid-turret']=true}
  local ORE_LETTER = {['iron-ore']='i', ['copper-ore']='c', coal='k', stone='s', ['crude-oil']='o', ['uranium-ore']='u'}
  -- The live map read as the stream service sends it (harness.py basemap_lua defaults).
  local CELL, MAXC, CMAX = 4, 128, 160
  local function try(fn) local ok, v = pcall(fn) if ok then return v end end
  local function store()
    local s = api.state()
    s.census = s.census or {}
    return s.census
  end
  local function timed(label, fn, ...)
    if api.timed then return api.timed(label, fn, ...) end
    return fn(...)
  end
  -- Types this game knows (no Space Age or Elevated Rails: their types are left out, as BASEMAP_LUA's fallback does).
  local TYPES
  local function types()
    if TYPES then return TYPES end
    local all, seen = {}, {}
    for _, list in ipairs({SNAP_LIST, {'rocket-silo', 'boiler', 'generator', 'entity-ghost'}}) do
      for _, t in ipairs(list) do if not seen[t] then seen[t] = true; all[#all+1] = t end end
    end
    for t in pairs(CAT) do if not seen[t] then seen[t] = true; all[#all+1] = t end end
    -- (d19 batch44 A1) where_is's other holders: landed cargo pods, spidertrons, linked and infinity chests, linked belts
    for _, t in ipairs({'temporary-container', 'spider-vehicle', 'linked-container', 'infinity-container', 'linked-belt', 'artillery-wagon'}) do
      if not seen[t] then seen[t] = true; all[#all+1] = t end
    end
    table.sort(all)
    local known = {}
    for _, t in ipairs(all) do
      if try(function() return prototypes.get_entity_filtered{{filter='type', type=t}} end) ~= nil then known[#known+1] = t end
    end
    TYPES = known
    return TYPES
  end
  local ELECTRIC = {}
  local function electric(name)
    local v = ELECTRIC[name]
    if v == nil then
      v = try(function() return prototypes.entity[name].electric_energy_source_prototype ~= nil end) or false
      ELECTRIC[name] = v
    end
    return v
  end
  local SIZE, RANGE = {}, {}
  local function size(name)
    local sz = SIZE[name]
    if not sz then
      local pr = prototypes and prototypes.entity and prototypes.entity[name]
      sz = {pr and pr.tile_width or 1, pr and pr.tile_height or 1}
      SIZE[name] = sz
    end
    return sz
  end
  local function range(name)
    local r = RANGE[name]
    if r == nil then
      r = 0
      pcall(function() local ap = prototypes.entity[name].attack_parameters r = ap and ap.range or 0 end)
      RANGE[name] = r
    end
    return r
  end
  local STATUS
  local function status_names()
    if not STATUS then STATUS = {} for k, v in pairs(defines.entity_status or {}) do STATUS[v] = k end end
    return STATUS
  end
  local function surfaces()
    local out = {}
    for _, s in pairs(game.surfaces or {}) do out[#out+1] = s end
    table.sort(out, function(a, b) return a.index < b.index end)
    return out
  end

  -- Where the bots stand on a surface: a bot is no player, so the walk's box takes them as it takes the players
  -- (an outpost a bot builds far from the rest is walked).
  local function bot_spots(s)
    local out = {}
    for _, b in pairs(((api.state().bots or {}).by_index) or {}) do
      local c = b.character
      local ok, here = pcall(function() return c and c.valid and c.surface.index == s.index and c.position end)
      if ok and here then out[#out+1] = here end
    end
    return out
  end
  -- One entity into the pass.
  -- Fuel users for the fuel budget (fuelbudget.lua; Opus, d15 06:20 and 07:50): entities with a burner (boilers, stone
  -- and steel furnaces, burner drills and inserters, heating towers, burner generators), and machines whose recipe
  -- takes a fuel item as an ingredient (plastic from coal, ...). Entity references only, at most FUEL_MAX a surface.
  local FUEL_MAX, CRAFTERS_MAX = 4096, 8192
  local burner_of, fuel_item = {}, {}
  local function has_burner(name)
    local b = burner_of[name]
    if b == nil then b = try(function() return prototypes.entity[name].burner_prototype ~= nil end) == true; burner_of[name] = b end
    return b
  end
  local function is_fuel(item)
    local f = fuel_item[item]
    if f == nil then f = (try(function() return prototypes.item[item].fuel_value end) or 0) > 0; fuel_item[item] = f end
    return f
  end
  local function behavior(e) local ok, v = pcall(e.get_control_behavior) return ok and v end
  -- (d22 batch110 BT1: census.walk made 15.4 KB of garbage a call on the private copy, every method read a new function
  -- and every closure a new object) an assembler's or furnace's recipe read once an entity, for the fuel list and the
  -- machines' counts both; the reads that may fail go through pcall with the entity as argument, no closure a call
  local function recipe_of(e) local ok, r = pcall(e.get_recipe) if ok then return r end end
  local function previous_recipe(e) return e.previous_recipe end
  local function pump_fluid(e) local f = e.fluidbox[1]; return f and f.name end
  local function pump_filter(e) local f = e.fluidbox.get_filter(1); return f and f.name end
  local function same_line(line, partner, i) return line.line_equals(partner.get_transport_line(i)) end
  local fuel_recipe = {}
  local function takes_fuel(r)
    if not r then return false end
    local v = fuel_recipe[r.name]
    if v == nil then
      v = false
      for _, ing in ipairs(r.ingredients or {}) do
        if (ing.type == nil or ing.type == 'item') and is_fuel(ing.name) then v = true break end
      end
      fuel_recipe[r.name] = v
    end
    return v
  end
  local PLANET_MAX, PLANET_CELLS = 60000, 128
  local planet_of = {}
  local function is_planet(s, i)
    i = i or s.index
    local v = planet_of[i]
    if v == nil then v = try(function() return s.planet ~= nil end) == true; planet_of[i] = v end
    return v
  end
  -- Our crafters, drills and offshore pumps by recipe, resource or fluid (chain.lua; d17 batch31 A1): entity references,
  -- at most MAKERS_MAX a surface.
  local MAKERS_MAX = 8192
  -- (d19 batch44 A1) where_is's holder types (stores.lua KIND) and belt types; at most HOLDERS_MAX holders a surface
  local WHERE = set{'container', 'logistic-container', 'linked-container', 'infinity-container', 'temporary-container', 'lab',
    'assembling-machine', 'furnace', 'rocket-silo', 'car', 'cargo-wagon', 'spider-vehicle', 'cargo-landing-pad', 'space-platform-hub',
    'roboport', 'beacon', 'mining-drill'}
  local BELT = set{'transport-belt', 'underground-belt', 'splitter', 'lane-splitter', 'loader', 'loader-1x1', 'linked-belt'}
  -- (d19 batch44 A2: a whole-surface find costs about 10.5 ms on the private copy's Nauvis whatever the type, and silo,
  -- shipment, artillery, freight_audit and trace each made one or more a call) kept by type with the holders: our
  -- turrets, artillery and radars too
  local KEEP = set{'container', 'logistic-container', 'linked-container', 'infinity-container', 'temporary-container', 'lab',
    'assembling-machine', 'furnace', 'rocket-silo', 'car', 'cargo-wagon', 'spider-vehicle', 'cargo-landing-pad', 'space-platform-hub',
    'roboport', 'beacon', 'mining-drill', 'ammo-turret', 'electric-turret', 'fluid-turret', 'artillery-turret', 'artillery-wagon', 'radar'}
  local HOLDERS_MAX = 30000
  -- (d21 batch68 AD3) our poles, entity references for the live map's electric networks (netmap.lua), at most POLES_MAX a surface
  local POLES_MAX = 20000
  local function add_maker(job, s, kind, key, e)
    local c = job.makers[s.index]
    if not c then c = {n=0, craft={}, mine={}, pump={}}; job.makers[s.index] = c end
    if c.n >= MAKERS_MAX then return end
    local list = c[kind][key]
    if not list then list = {}; c[kind][key] = list end
    list[#list+1] = e; c.n = c.n + 1
  end
  -- name|recipe keys of the machines' counts, made once
  local MKEY = {}
  local function mkey(name, r)
    local a = MKEY[name]
    if not a then a = {}; MKEY[name] = a end
    local k = a[r]
    if not k then k = name .. '|' .. r; a[r] = k end
    return k
  end
  -- Types whose entities move: their position is read when the entity is read, never the one its band's find read.
  local MOVES = set{'car', 'locomotive', 'cargo-wagon', 'fluid-wagon', 'artillery-wagon', 'spider-vehicle', 'construction-robot',
    'logistic-robot', 'combat-robot', 'capture-robot', 'character', 'unit', 'spider-unit', 'segmented-unit'}
  -- ctx: the step's lookups for one surface (observe_seen; never in storage)
  -- band_pos: the entity's position as its band's find read it this session, or nil (BT1: one position table an
  -- entity, not two; a building does not move between its band's find and its read)
  local function read_entity(job, s, e, ctx, band_pos)
    if not e.valid then return end
    local t, name = e.type, e.name
    local pos = band_pos and not MOVES[t] and band_pos or e.position
    local si, sn = ctx.si, ctx.surface_name
    local rec = (t == 'assembling-machine' or t == 'furnace' or t == 'rocket-silo') and recipe_of(e) or nil
    if job.fuel and t ~= 'car' and t ~= 'locomotive' and t ~= 'spider-vehicle' and t ~= 'character' then
      local list = job.fuel[si]
      if (not list or #list < FUEL_MAX) and (has_burner(name) or ((t == 'assembling-machine' or t == 'furnace') and takes_fuel(rec))) then
        if not list then list = {}; job.fuel[si] = list end
        list[#list+1] = e
      end
    end
    if api.observe_seen then api.observe_seen(e, t, pos, ctx) end
    -- A pass already running before this index was installed stays incomplete for silo discovery.
    if (t == 'agricultural-tower' or (t == 'entity-ghost' and e.ghost_type == 'agricultural-tower')) and job.towers then
      job.towers[si] = job.towers[si] or {}
      job.towers[si][#job.towers[si]+1] = e
    end
    -- (d17 batch22 B3, Muse) entities that may carry a circuit or logistic condition: those with a control behavior,
    -- for the gates read (at most GATES_MAX a surface)
    if GATE[t] and job.gated then
      local list = job.gated[si]
      if (not list or #list < GATES_MAX) and behavior(e) then
        if not list then list = {}; job.gated[si] = list end
        list[#list+1] = e
      end
    end
    if t == 'offshore-pump' and job.makers then
      local ok, fl = pcall(pump_fluid, e)
      if not (ok and fl) then ok, fl = pcall(pump_filter, e); if not ok then fl = nil end end
      if fl then add_maker(job, s, 'pump', fl, e) end
    end
    if t == 'rocket-silo' and job.silos then
      job.silos[si] = job.silos[si] or {}
      job.silos[si][#job.silos[si]+1] = e
    end
    if STREAM[t] and electric(name) then
      job.machines = job.machines + 1
      local st = e.status
      if st == defines.entity_status.low_power or st == defines.entity_status.no_power then job.starved = job.starved + 1 end
    end
    if SNAP[t] then job.where[sn] = (job.where[sn] or 0) + 1 end
    -- Per-prototype planetary counts use this same pass, never a second find. Old in-flight jobs have no map.
    local counts=job.building_counts and job.building_counts[si]
    if counts and SNAP[t] then counts.entities[name]=(counts.entities[name] or 0)+1 end
    -- (d18 batch37 B1) our chests, entity references (elsewhere.lua counts an item in them without a search: a whole-
    -- surface find of chests took 14-16 ms on Nauvis, world n), at most CRAFTERS_MAX a surface
    if t == 'electric-pole' and job.poles then
      local list = job.poles[si]
      if not list then list = {}; job.poles[si] = list end
      if #list < POLES_MAX then list[#list+1] = e end
    end
    if (t == 'container' or t == 'logistic-container') and job.chests then
      local list = job.chests[si]
      if not list then list = {}; job.chests[si] = list end
      if #list < CRAFTERS_MAX then list[#list+1] = e end
    end
    -- (d19 batch44 A1, where_is: 111 ms for one Nauvis call on the private copy, every holder, belt and inserter found and
    -- read each call) where_is's holders as entity references, and what our belts and inserters' hands carry by item, as
    -- this pass reads them (the belts' get_contents were 42 ms for 10,552 belts there, spread over the pass's steps)
    if KEEP[t] and job.by_type then
      local by = job.by_type[si]
      if not by then by = {n=0}; job.by_type[si] = by end
      if by.n < HOLDERS_MAX then
        local list = by[t]
        if not list then list = {}; by[t] = list end
        list[#list+1] = e; by.n = by.n + 1
      end
    elseif BELT[t] and job.belt_items then
      local tot = job.belt_items[si]
      if not tot then tot = {}; job.belt_items[si] = tot end
      local ok, lines = pcall(e.get_max_transport_line_index)
      -- (d22 batch96 BF1) an underground exit's buried lines (3 and 4) are its entrance's: counted there once, as
      -- freight.lua stock_places counts them
      local partner = t == 'underground-belt' and e.belt_to_ground_type == 'output' and e.neighbours
      if partner and not partner.valid then partner = nil end
      local n = ok and lines or 0
      local get_line = n >= 1 and e.get_transport_line or nil  -- (BT1) the method read once a belt, not once a line
      for i = 1, n do
        local ok2, line = pcall(get_line, i)
        local same = ok2 and line and partner and i > 2 and select(2, pcall(same_line, line, partner, i)) == true
        if ok2 and line and not same then
          for _, c in ipairs(line.get_contents()) do tot[c.name] = (tot[c.name] or 0) + c.count end
        end
      end
    elseif t == 'inserter' and job.hand_items then
      local hs = e.held_stack
      if hs and hs.valid_for_read then
        local tot = job.hand_items[si]
        if not tot then tot = {}; job.hand_items[si] = tot end
        tot[hs.name] = (tot[hs.name] or 0) + hs.count
      end
    end
    -- (d17 batch30 B2) our assemblers and furnaces, entity references (supply requesters reads their recipes now), at
    -- most CRAFTERS_MAX a surface
    if (t == 'assembling-machine' or t == 'furnace') and job.crafters then
      local list = job.crafters[si]
      if not list then list = {}; job.crafters[si] = list end
      if #list < CRAFTERS_MAX then list[#list+1] = e end
    end
    if MACH[t] then
      local r
      if t == 'assembling-machine' or t == 'furnace' or t == 'rocket-silo' then
        if rec then r = rec.name
        elseif t == 'furnace' then
          local ok2, pr = pcall(previous_recipe, e)
          if ok2 and pr then r = type(pr.name) == 'string' and pr.name or pr.name.name end
        end
      elseif t == 'mining-drill' then
        local target = e.mining_target
        r = target and target.name or nil
      end
      -- (d17 batch31 A1) entity references by recipe (a drill's by the resource it mines), for the chain read
      if r and job.makers and t ~= 'lab' and t ~= 'boiler' and t ~= 'generator' then add_maker(job, s, t == 'mining-drill' and 'mine' or 'craft', r, e) end
      local key = mkey(name, r or '-')
      local st = status_names()[e.status or -1] or 'unknown'
      local row = job.mach[key] or {}
      job.mach[key] = row
      row[st] = (row[st] or 0) + 1
    end
    -- Another planet's buildings, for its coarse map (viewers craigNZ830 and Foobator, d15 07:05: the live map showed
    -- Nauvis only): each one's centre and category, at most PLANET_MAX a planet. (d21 batch68 AD1, viewer Aurora:
    -- "Could Aquilo get a detailed base map using the Nauvis approach?") and its footprint and 32-tile block, for a
    -- dense core as Nauvis's
    if sn ~= 'nauvis' and CAT[t] and job.planets and is_planet(s, si) then
      local P = job.planets[sn]
      if not P then P = {x={}, y={}, c={}, w={}, h={}, blocks={}, top=0, n=0, minx=math.huge, miny=math.huge, maxx=-math.huge, maxy=-math.huge}; job.planets[sn] = P end
      if #P.x < PLANET_MAX then
        local p = pos
        local i = #P.x + 1
        local cat = OIL[name] and 'O' or CAT[t]
        P.x[i], P.y[i], P.c[i] = p.x, p.y, cat
        local sz = size(name)
        local w, h = sz[1], sz[2]
        if w ~= h and (e.direction == 4 or e.direction == 12) then w, h = h, w end
        P.w[i], P.h[i] = w, h
        if not LINE[cat] then
          local k = pair(math.floor(p.x / 32), math.floor(p.y / 32))
          P.blocks[k] = (P.blocks[k] or 0) + 1
          if P.blocks[k] > P.top then P.top = P.blocks[k] end
          P.n = P.n + 1
        end
        if p.x < P.minx then P.minx = p.x end
        if p.x > P.maxx then P.maxx = p.x end
        if p.y < P.miny then P.miny = p.y end
        if p.y > P.maxy then P.maxy = p.y end
      end
    end
    if sn == 'nauvis' and CAT[t] then
      local p = pos
      local cat = OIL[name] and 'O' or CAT[t]
      local b = job.base
      local i = #b.x + 1
      b.x[i], b.y[i], b.c[i] = p.x, p.y, cat
      if b.box then
        if p.x < b.minx then b.minx = p.x end
        if p.x > b.maxx then b.maxx = p.x end
        if p.y < b.miny then b.miny = p.y end
        if p.y > b.maxy then b.maxy = p.y end
      end
      local sz = size(name)
      local w, h = sz[1], sz[2]
      if w ~= h and (e.direction == 4 or e.direction == 12) then w, h = h, w end
      b.w[i], b.h[i] = w, h
      if cat == 'D' and RANGED[t] and #b.turrets < 600 then
        local r = range(name)
        if r > 0 then b.turrets[#b.turrets+1] = {math.floor(p.x), math.floor(p.y), r} end
      end
      if not LINE[cat] then
        local k = pair(math.floor(p.x / 32), math.floor(p.y / 32))
        b.blocks[k] = (b.blocks[k] or 0) + 1
        if b.blocks[k] > b.top then b.top = b.blocks[k] end
        b.n = b.n + 1
      end
    end
  end

  -- The live map's grids from the pass's points, in steps (BASEMAP_LUA's arithmetic, step by step).
  local function base_extent(b)
    local C = CELL
    local n = #b.x
    if n == 0 then return C end
    local minx, maxx, miny, maxy = b.minx, b.maxx, b.miny, b.maxy
    if not b.box then
      -- (a pass begun before the walk kept its box)
      minx, maxx, miny, maxy = math.huge, -math.huge, math.huge, -math.huge
      for i = 1, n do
        local x, y = b.x[i], b.y[i]
        if x < minx then minx = x end
        if x > maxx then maxx = x end
        if y < miny then miny = y end
        if y > maxy then maxy = y end
      end
      b.minx, b.maxx, b.miny, b.maxy = minx, maxx, miny, maxy
    end
    while true do
      local x0, x1, y0, y1 = math.floor(minx / C), math.floor(maxx / C), math.floor(miny / C), math.floor(maxy / C)
      if x1 - x0 < MAXC and y1 - y0 < MAXC then b.x0, b.x1, b.y0, b.y1 = x0, x1, y0, y1; break end
      C = C * 2
    end
    return C
  end
  local function rows_of(grid, x0, x1, y0, y1)
    local rows = {}
    for cy = y0, y1 do
      local row, buf = grid[cy] or {}, {}
      for cx = x0, x1 do buf[#buf+1] = row[cx] or '.' end
      rows[#rows+1] = (table.concat(buf):gsub('%.+$', ''))
    end
    return rows
  end
  local function core_box(b, C)
    local bx0, by0, bx1, by1 = b.x0 * C, b.y0 * C, (b.x1 + 1) * C, (b.y1 + 1) * C
    if b.n >= 12 then
      local lim, dense, seen, best, bestn = math.max(2, b.top / 5), {}, {}, nil, -1
      for k, v in pairs(b.blocks) do if v >= lim then dense[k] = v end end
      local keys = {}
      for k in pairs(dense) do keys[#keys+1] = k end
      table.sort(keys)
      for _, k in ipairs(keys) do
        if not seen[k] then
          seen[k] = true
          local stack, group, total = {k}, {}, 0
          while #stack > 0 do
            local cur = table.remove(stack)
            local bx, by = cur:match('^(-?%d+),(-?%d+)$')
            bx, by = tonumber(bx), tonumber(by)
            group[#group+1] = {bx, by}
            total = total + dense[cur]
            for dx = -1, 1 do for dy = -1, 1 do
              local nk = pair(bx + dx, by + dy)
              if dense[nk] and not seen[nk] then seen[nk] = true stack[#stack+1] = nk end
            end end
          end
          if total > bestn then best, bestn = group, total end
        end
      end
      bx0, by0, bx1, by1 = math.huge, math.huge, -math.huge, -math.huge
      for _, q in ipairs(best) do
        bx0, by0 = math.min(bx0, q[1] * 32 - 8), math.min(by0, q[2] * 32 - 8)
        bx1, by1 = math.max(bx1, q[1] * 32 + 40), math.max(by1, q[2] * 32 + 40)
      end
    end
    local CC = 1
    while (bx1 - bx0) / CC > CMAX or (by1 - by0) / CC > CMAX do CC = CC * 2 end
    return {bx0=bx0, by0=by0, bx1=bx1, by1=by1, CC=CC, cx0=math.floor(bx0 / CC), cy0=math.floor(by0 / CC),
      cx1=math.floor((bx1 - 1) / CC), cy1=math.floor((by1 - 1) / CC), fine={}}
  end
  -- Points i0..i1 of b (x, y, w, h, c) on core k's fine grid: each building's footprint, the most telling one a cell.
  local function fine_fill(k, b, i0, i1)
    local fine, CC = k.fine, k.CC
    for i = i0, i1 do
      local x, y = b.x[i], b.y[i]
      if x >= k.bx0 - 8 and x <= k.bx1 + 8 and y >= k.by0 - 8 and y <= k.by1 + 8 then
        local w, h = b.w[i], b.h[i]
        local tx, ty = math.floor(x - w / 2 + 0.01), math.floor(y - h / 2 + 0.01)
        for cy = math.max(k.cy0, math.floor(ty / CC)), math.min(k.cy1, math.floor((ty + h - 1) / CC)) do
          local row = fine[cy]
          if not row then row = {} fine[cy] = row end
          for cx = math.max(k.cx0, math.floor(tx / CC)), math.min(k.cx1, math.floor((tx + w - 1) / CC)) do
            local old = row[cx]
            if not old or RANK[b.c[i]] > RANK[old] then row[cx] = b.c[i] end
          end
        end
      end
    end
  end
  local function core_out(k)
    return {cell=k.CC, x0=k.cx0 * k.CC, y0=k.cy0 * k.CC, w=k.cx1 - k.cx0 + 1, h=k.cy1 - k.cy0 + 1, rows=rows_of(k.fine, k.cx0, k.cx1, k.cy0, k.cy1)}
  end
  local function new_job(tick, st)
    local list = {}
    for _, s in ipairs(surfaces()) do list[#list+1] = s.index end
    local want_ore = st.ore_asked and tick - st.ore_asked <= ORE_WANT and (not st.ore_tick or tick - st.ore_tick >= ORE_EVERY)
    return {start=tick, surfaces=list, si=1, steps=0,
      machines=0, starved=0, where={}, mach={}, silos={}, towers={}, gated={}, crafters={}, chests={}, makers={}, building_counts={}, fuel={}, planets={},
      by_type={}, walked={}, belt_items={}, hand_items={}, poles={},
      base={x={}, y={}, c={}, w={}, h={}, turrets={}, blocks={}, top=0, n=0, box=true, minx=math.huge, miny=math.huge, maxx=-math.huge, maxy=-math.huge},
      want_ore=want_ore or nil, stage='walk', credit=0, paced=tick}
  end
  -- Bands of chunk rows over a tile box, at most `width` chunks a band: {X0, Y0, X1, Y1, first_x, last_x, first_y, last_y}.
  local function bands(ax0, ay0, ax1, ay1, width)
    local out = {}
    local cx0, cy0, cx1, cy1 = math.floor(ax0 / 32), math.floor(ay0 / 32), math.floor(ax1 / 32), math.floor(ay1 / 32)
    for cy = cy0, cy1 do
      local cx = cx0
      while cx <= cx1 do
        local last = math.min(cx1, cx + width - 1)
        out[#out+1] = {math.max(ax0, cx * 32), math.max(ay0, cy * 32), math.min(ax1, (last + 1) * 32), math.min(ay1, (cy + 1) * 32),
          cx == cx0, last == cx1, cy == cy0, cy == cy1}
        cx = last + 1
      end
    end
    return out
  end
  -- Whether a found entity's position puts it in this band (bands partition the box; the box's outer bands take what
  -- lies beyond its edges, as a find over the whole box returns what only overlaps it).
  local function in_band(p, b)
    return (p.x >= b[1] or b[5]) and (p.x < b[3] or b[6]) and (p.y >= b[2] or b[7]) and (p.y < b[4] or b[8])
  end

  -- Grid points a step from the job's work (GRID at most).
  local function points(job) return math.max(1, math.min(GRID, math.floor(job.credit / GRID_COST))) end
  local STAGE = {walk='census.walk', cells='census.cells', fill='census.fill', rows='census.rows', fine='census.fine',
    crows='census.crows', nests='census.nests', ore='census.ore', done='census.done'}
  local stage
  M.read_entity = read_entity  -- (tests: one entity into a pass's job)
  -- (d22 batch110 BT1: census.step made 14.8 KB of garbage a tick on the private copy) what a step made anew each tick,
  -- kept between steps: the player force and each surface (read again once not valid), the step's ctx (its fields set
  -- each step; each lookup a new table only when the last step put something in it, so each step starts with none),
  -- the band's filter, and the positions the band's find read (band_pos[i] for band_list[i]; never in storage, so after
  -- a load each entity's position is read again)
  local FORCE, SURFACE = nil, {}
  local function player_force()
    if FORCE and FORCE.valid then return FORCE end
    FORCE = game.forces.player
    return FORCE
  end
  local function surface_at(i)
    local s = SURFACE[i]
    if s and s.valid then return s end
    s = game.get_surface(i)
    SURFACE[i] = s
    return s
  end
  local CTX = {p={}, vis={}, fog={}, belt={}}
  local function ctx_of(f, s)
    local fname, sname = f.name, s.name
    CTX.p.force, CTX.p.surface = f, s
    CTX.force, CTX.surface, CTX.si = f, s, s.index
    if CTX.force_name ~= fname or CTX.surface_name ~= sname then
      CTX.force_name, CTX.surface_name, CTX.fog_prefix = fname, sname, fname .. '|' .. sname .. '|'
    end
    if next(CTX.vis) then CTX.vis = {} end
    if next(CTX.fog) then CTX.fog = {} end
    if next(CTX.belt) then CTX.belt = {} end
    return CTX
  end
  local BANDF, band_pos, band_list = {}, {}, nil
  function M.step(st, tick)
    local job = st.job
    if not job then
      if st.done and tick - snapfail.since(st.done.start, st.done.refresh_failed) < PERIOD then return end
      st.job = new_job(tick, st)
      return
    end
    -- (d21 batch73 AI) paced by work, never by the pass's period: WORK units a tick, kept up to WORK_CAP; a step runs
    -- while the job has any and spends what it did (a pass begun before this pacing starts with none)
    job.credit = math.min(WORK_CAP, (job.credit or 0) + WORK * math.max(0, tick - (job.paced or tick)))
    job.paced = tick
    if job.credit <= 0 then return end
    job.steps = job.steps + 1
    local f = player_force()
    if not f then st.job = nil return end
    -- each stage a part of its own in the operator profiler (census.walk, census.fine, census.planets, ...)
    local label = job.stage == 'done' and job.planets and next(job.planets) and not job.planets_done and 'census.planets' or STAGE[job.stage] or 'census.other'
    return timed(label, stage, st, job, f)
  end
  function stage(st, job, f)
    if job.stage == 'walk' then
      if job.si > #job.surfaces then job.stage = 'cells' return end
      local s = surface_at(job.surfaces[job.si])
      if not s then job.si = job.si + 1; job.walk, job.list = nil, nil return end
      if job.building_counts and not job.building_counts[s.index] and not s.platform then
        job.building_counts[s.index]={surface=s.name,entities={}}
      end
      if job.list then
        local last = math.min(#job.list, job.at + math.min(SLICE, math.max(1, math.floor(job.credit))) - 1)
        local ctx = ctx_of(f, s)
        local list = job.list
        local known = band_list == list
        for i = job.at, last do read_entity(job, s, list[i], ctx, known and band_pos[i] or nil) end
        job.credit = job.credit - (last - job.at + 1)
        job.at = last + 1
        if job.at > #list then job.list = nil; band_list = nil end
        return
      end
      -- (d21 batch73 AI) one chunk a band: a band grown over sparse chunks to 32 found about 30,000 entities in one tick
      -- on the private copy of world n (460 ms of census.step in that second)
      job.walk = job.walk or walk.start(s, bot_spots(s), {max_chunks=1})
      BANDF.force, BANDF.type = f, types()
      local list, pos = walk.band(job.walk, s, BANDF, band_pos)
      band_list = pos == band_pos and list or nil
      if list then job.list, job.at = list, 1; job.credit = job.credit - 1 - #list * FIND_COST
      else job.walk = nil; if job.walked then job.walked[s.index] = true end; job.si = job.si + 1 end
      return
    end
    local b = job.base
    if job.stage == 'cells' then
      job.C = base_extent(b)
      b.cells, b.i = {}, 1
      job.stage = #b.x > 0 and 'fill' or 'done'
    elseif job.stage == 'fill' then
      local C, cells = job.C, b.cells
      local last = math.min(#b.x, b.i + points(job) - 1)
      job.credit = job.credit - (last - b.i + 1) * GRID_COST
      for i = b.i, last do
        local cx, cy = math.floor(b.x[i] / C), math.floor(b.y[i] / C)
        local row = cells[cy]
        if not row then row = {} cells[cy] = row end
        local old = row[cx]
        if not old or RANK[b.c[i]] > RANK[old] then row[cx] = b.c[i] end
      end
      b.i = last + 1
      if b.i > #b.x then job.stage = 'rows' end
    elseif job.stage == 'rows' then
      b.rows = rows_of(b.cells, b.x0, b.x1, b.y0, b.y1)
      b.cells = nil
      b.core = core_box(b, job.C)
      b.i = 1
      job.stage = 'fine'
    elseif job.stage == 'fine' then
      local last = math.min(#b.x, b.i + points(job) - 1)
      job.credit = job.credit - (last - b.i + 1) * FINE_COST
      fine_fill(b.core, b, b.i, last)
      b.i = last + 1
      if b.i > #b.x then job.stage = 'crows' end
    elseif job.stage == 'crows' then
      b.core_out = core_out(b.core)
      b.core = nil
      local C, m = job.C, 96
      b.nest_bands, b.nests, b.ni = bands(b.x0 * C - m, b.y0 * C - m, (b.x1 + 1) * C + m, (b.y1 + 1) * C + m, NEST_BAND), {}, 1
      job.stage = 'nests'
    elseif job.stage == 'nests' then
      local band = b.nest_bands[b.ni]
      local s = game.surfaces.nauvis
      if band and s and #b.nests < 200 then
        local found = s.find_entities_filtered{force='enemy', type={'unit-spawner', 'turret'}, area={{band[1], band[2]}, {band[3], band[4]}}}
        job.credit = job.credit - BAND_COST - #found * FIND_COST
        for _, e in pairs(found) do
          if #b.nests < 200 then
            local p = e.position  -- (BT1) one position read an entity, not three
            if in_band(p, band) then b.nests[#b.nests+1] = {math.floor(p.x), math.floor(p.y), e.type == 'unit-spawner' and 's' or 'w'} end
          end
        end
        b.ni = b.ni + 1
      else
        b.nest_bands = nil
        if job.want_ore then
          local C, m = job.C, 64
          local ax0, ay0, ax1, ay1 = b.x0 * C - m, b.y0 * C - m, (b.x1 + 1) * C + m, (b.y1 + 1) * C + m
          b.ore_box = {ax0, ay0, ax1, ay1}
          b.ore_bands, b.ore_cnt, b.oi = bands(ax0, ay0, ax1, ay1, ORE_BAND), {}, 1
          job.stage = 'ore'
        else job.stage = 'done' end
      end
    elseif job.stage == 'ore' then
      local band = b.ore_bands[b.oi]
      local s = game.surfaces.nauvis
      if band and s then
        local C, cnt = job.C, b.ore_cnt
        local found = s.find_entities_filtered{area={{band[1], band[2]}, {band[3], band[4]}}, type='resource'}
        job.credit = job.credit - BAND_COST - #found * ORE_COST
        for _, e in pairs(found) do
          local p = e.position  -- (BT1) one position read a resource, not three
          if in_band(p, band) then
            local cx, cy = math.floor(p.x / C), math.floor(p.y / C)
            local row = cnt[cy]
            if not row then row = {} cnt[cy] = row end
            local cell = row[cx]
            if not cell then cell = {} row[cx] = cell end
            local l = ORE_LETTER[e.name] or 'x'
            cell[l] = (cell[l] or 0) + 1
          end
        end
        b.oi = b.oi + 1
      else
        local C, a = job.C, b.ore_box
        local ox0, oy0, ox1, oy1 = math.floor(a[1] / C), math.floor(a[2] / C), math.floor(a[3] / C), math.floor(a[4] / C)
        local orows = {}
        for cy = oy0, oy1 do
          local row, buf = b.ore_cnt[cy] or {}, {}
          for cx = ox0, ox1 do
            local best, bn = '.', 0
            for l, n in pairs(row[cx] or {}) do if n > bn or (n == bn and l < best) then best, bn = l, n end end
            buf[#buf+1] = best
          end
          orows[#orows+1] = (table.concat(buf):gsub('%.+$', ''))
        end
        b.ore = {cell=C, x0=ox0 * C, y0=oy0 * C, w=ox1 - ox0 + 1, rows=orows}
        b.ore_cnt, b.ore_bands = nil, nil
        job.stage = 'done'
      end
    elseif job.planets and next(job.planets) and not job.planets_done then
      -- Each other planet's coarse grid, in steps (GRID points a step): its cell doubled from CELL until the
      -- planet's buildings fit PLANET_CELLS cells a side; a cell takes its most telling building, as Nauvis's.
      job.plist = job.plist or (function() local l = {} for k in pairs(job.planets) do l[#l+1] = k end table.sort(l) return l end)()
      job.pi = job.pi or 1
      local name = job.plist[job.pi]
      if not name then job.planets_done = true; return end
      local P = job.planets[name]
      if not P.cell then
        local C = CELL
        while (P.maxx - P.minx) / C + 1 > PLANET_CELLS or (P.maxy - P.miny) / C + 1 > PLANET_CELLS do C = C * 2 end
        P.cell = C
        P.cx0, P.cy0 = math.floor(P.minx / C), math.floor(P.miny / C)
        P.cx1, P.cy1 = math.floor(P.maxx / C), math.floor(P.maxy / C)
        P.grid, P.i = {}, 1
      end
      local C, grid = P.cell, P.grid
      local last = math.min(#P.x, P.i + points(job) - 1)
      job.credit = job.credit - (last - P.i + 1) * (P.core and FINE_COST or GRID_COST)
      if not P.core then
        for i = P.i, last do
          local cx, cy = math.floor(P.x[i] / C), math.floor(P.y[i] / C)
          local row = grid[cy]
          if not row then row = {} grid[cy] = row end
          local old = row[cx]
          if not old or RANK[P.c[i]] > RANK[old] then row[cx] = P.c[i] end
        end
        P.i = last + 1
        if P.i > #P.x then
          -- (AD1) then its dense core, as Nauvis's: the box round its densest blocks at 1-2 tiles a cell, up to CMAX cells
          P.rows, P.grid, P.i = rows_of(grid, P.cx0, P.cx1, P.cy0, P.cy1), nil, 1
          P.core = core_box({x0=P.cx0, x1=P.cx1, y0=P.cy0, y1=P.cy1, n=P.n, top=P.top, blocks=P.blocks}, C)
        end
      else
        fine_fill(P.core, P, P.i, last)
        P.i = last + 1
        if P.i > #P.x then
          P.out = {tick=game.tick, cell=C, x0=P.cx0 * C, y0=P.cy0 * C, w=P.cx1 - P.cx0 + 1, h=P.cy1 - P.cy0 + 1,
            rows=P.rows, buildings=#P.x, capped=#P.x >= PLANET_MAX or nil, core=core_out(P.core)}
          P.x, P.y, P.c, P.w, P.h, P.blocks, P.rows, P.core = nil, nil, nil, nil, nil, nil, nil, nil
          job.pi = job.pi + 1
        end
      end
    else
      -- The pass is complete: its parts replace the last ones.
      local C, has = job.C or CELL, #b.x > 0
      local map = {tick=game.tick, cell=C, x0=has and b.x0 * C or 0, y0=has and b.y0 * C or 0,
        w=has and (b.x1 - b.x0 + 1) or 0, h=has and (b.y1 - b.y0 + 1) or 0, rows=b.rows or {}, nests=b.nests or {},
        buildings=#b.x, core=b.core_out, turrets=has and b.turrets or {}}
      st.done = {start=job.start, tick=game.tick, steps=job.steps, extras={electric_machines=job.machines, starved=job.starved},
        building_counts=job.building_counts,building_counts_as_of=job.building_counts and job.start or nil,
        where=job.where, machines=job.mach, basemap=map, silos=job.silos, silos_as_of=job.start, towers=job.towers, fuel=job.fuel, gated=job.gated, crafters=job.crafters, chests=job.chests, makers=job.makers,
        by_type=job.by_type, walked=job.walked, belt_items=job.belt_items, hand_items=job.hand_items, poles=job.poles,
        planets=(function() local out = {} for k, P in pairs(job.planets or {}) do if P.out then out[k] = P.out end end return out end)()}
      if b.ore then st.ore = {start=job.start, ore=b.ore}; st.ore_tick = job.start end
      st.steps = job.steps
      st.job = nil
    end
  end
  function M.tick(tick)
    local st = store()
    local ok, err = pcall(timed, 'census.step', M.step, st, tick)
    if not ok then
      st.job = nil
      st.errors = {count=((st.errors or {}).count or 0) + 1, last=tostring(err), tick=tick}
      -- (the last pass keeps the tick it started at, its as_of; the next starts PERIOD after the failure, snapfail.lua)
      if st.done then st.done.refresh_failed = snapfail.failed(err, tick) end
    end
  end

  -- (d19 batch44 A1-A2) the last pass's entities of these types on a surface, still valid (the pass reads the player force
  -- only), and the tick it started; nil before a pass that keeps them, for another force, or a surface it did not walk.
  function M.typed(force, surface, types)
    local d = (api.state().census or {}).done
    if not (d and d.by_type and d.walked and d.walked[surface.index]) or force.name ~= 'player' then return nil end
    local by = d.by_type[surface.index] or {}
    local out = {}
    for _, t in ipairs(type(types) == 'table' and types or {types}) do
      for _, e in ipairs(by[t] or {}) do if e.valid then out[#out+1] = e end end
    end
    return out, d.start, (by.n or 0) >= HOLDERS_MAX
  end
  -- where_is's index of a surface: {holders (the WHERE types), belts and hands ({item=count} as the pass read them),
  -- as_of, capped}; nil as typed is, and for a surface where the pass listed no holder (where_is reads it live).
  local WHERE_LIST = {}
  for t in pairs(WHERE) do WHERE_LIST[#WHERE_LIST+1] = t end
  table.sort(WHERE_LIST)
  function M.where_index(force, surface)
    local out, as_of, capped = M.typed(force, surface, WHERE_LIST)
    if not out or #out == 0 then return nil end
    local d = api.state().census.done
    return {holders=out, belts=(d.belt_items or {})[surface.index] or {}, hands=(d.hand_items or {})[surface.index] or {}, as_of=as_of,
      capped=capped or nil, refresh_failed=snapfail.line('the census pass', d.start, d.refresh_failed)}
  end
  local function same_force(e, force, fi)
    local efi = e.force_index
    if efi ~= nil and fi ~= nil then return efi == fi end
    return e.force == force
  end
  -- (d18 batch37 B1) the chests of a force on a surface the last pass found (nil before a pass lists them).
  function M.chests_on(force, surface)
    local d = (api.state().census or {}).done
    if not (d and d.chests) then return nil end
    local out = {}
    -- (d25 batch206 QS) by force_index: e.force == force made a LuaForce an entity (9 ms of Nauvis's 3716 chests, 3.8 so)
    local fi = force.index
    for _, e in ipairs(d.chests[surface.index] or {}) do if e.valid and same_force(e, force, fi) then out[#out+1] = e end end
    return out
  end
  -- Only entity references are cached; preflight reads their current rocket/cargo state.
  function M.silos(p)
    local d = (api.state().census or {}).done
    local out = {}
    for _, e in ipairs(d and d.silos and d.silos[p.surface.index] or {}) do
      if e.valid and e.surface == p.surface and e.force == p.force then out[#out+1] = e end
    end
    return out, d and d.silos and (d.silos_as_of or d.start) or nil
  end

  -- (d18 batch36 A2, D1) the silos of a force on any surface the last pass found (nil before a pass).
  function M.silos_on(force, surface)
    local d = (api.state().census or {}).done
    if not (d and d.silos) then return nil end
    local out = {}
    for _, e in ipairs(d.silos[surface.index] or {}) do if e.valid and e.force == force then out[#out+1] = e end end
    return out
  end
  -- The entities of ours with a control behavior the last pass found on a surface (gates.lua), and its tick.
  function M.gated(force, surface)
    local d = (api.state().census or {}).done
    local out = {}
    for _, e in ipairs(d and d.gated and d.gated[surface.index] or {}) do if e.valid and e.force == force then out[#out+1] = e end end
    return out, d and d.gated and d.start or nil
  end
  -- Our crafters, drills and pumps by recipe, resource or fluid the last pass found on a surface ({n, craft, mine, pump}),
  -- and its tick (chain.lua).
  function M.makers(surface)
    local d = (api.state().census or {}).done
    return d and d.makers and d.makers[surface.index] or nil, d and d.makers and d.start or nil
  end
  -- Our assemblers and furnaces the last pass found on a surface (supply requesters), still valid, and its tick; nil
  -- before a pass that kept them.
  function M.crafters(force, surface)
    local d = (api.state().census or {}).done
    if not (d and d.crafters) then return nil end
    local out = {}
    local fi = force.index
    for _, e in ipairs(d.crafters[surface.index] or {}) do if e.valid and same_force(e, force, fi) then out[#out+1] = e end end
    return out, d.start
  end
  -- (d21 batch68 AD3) our poles the last pass found on a surface, still valid, its tick and whether it hit POLES_MAX; nil
  -- before a pass that kept them or for a surface it did not walk.
  function M.poles(force, surface)
    local d = (api.state().census or {}).done
    if not (d and d.poles and d.walked and d.walked[surface.index]) or force.name ~= 'player' then return nil end
    local out = {}
    for _, e in ipairs(d.poles[surface.index] or {}) do if e.valid then out[#out+1] = e end end
    return out, d.start, #(d.poles[surface.index] or {}) >= POLES_MAX
  end
  function M.towers(force, surface)
    local d = (api.state().census or {}).done
    return d and d.towers and d.towers[surface.index] or {}, d and d.towers and d.start or nil
  end

  -- The fuel users the last pass found on a surface (entity references; fuelbudget.lua reads their state now).
  function M.fuel_users(surface)
    local d = (api.state().census or {}).done
    return d and d.fuel and d.fuel[surface.index] or nil, d and d.fuel and d.start or nil
  end
  -- (d26 batch230) the last pass's count of the snapshot's building types of ours on a surface, and its tick; nil
  -- before a pass or for a surface it has not counted (supply stock's size limit)
  function M.surface_buildings(surface)
    local d = (api.state().census or {}).done
    local n = d and d.where and d.where[surface.name]
    return n, n and d.start or nil
  end
  function M.buildings(force)
    local d=(api.state().census or {}).done
    if force.name~='player' or not d then return nil end
    return d.building_counts,d.building_counts_as_of
  end

  -- (d26 batch233 VM, viewer Aurora site:5019: "Could vehicle maps start with Spidertrons? ... Show ID, position age,
  -- controller and destination.") part vehicles: ours of VEHICLE_TYPES the last pass kept (KEEP), each where our force
  -- last saw it: its position now when its chunk is visible to our force (radar coverage or a character's sight), else
  -- the one it had when this read last saw it so (seen_tick); who sits in its driver seat, who drives it by remote view
  -- (api.vehicle_people), who last sent it a route by remote view and when (spiderroute.lua); its destination (the first
  -- target of its route) and how many targets the route holds. One never seen since the census began keeping them:
  -- unseen, no position. Reads the kept entities only (no find); writes only the last-seen table.
  -- (cp2) cars and tanks too (type car): a remote drive's target is their destination
  local VEHICLE_TYPES, VEHICLES_MAX = {'spider-vehicle', 'car'}, 64
  M.VEHICLE_TYPES, M.VEHICLES_MAX = VEHICLE_TYPES, VEHICLES_MAX
  local function r1(v) return math.floor(v * 10 + 0.5) / 10 end
  local function vehicles(d)
    local st = store()
    st.vehicles_seen = st.vehicles_seen or {}
    local seen = st.vehicles_seen
    local f = game.forces.player
    local people = api.vehicle_people and try(api.vehicle_people) or {}
    local by_char, remote = people.by_character or {}, people.remote or {}
    local routes = (api.state().spiderroute or {}).spiders or {}
    local rows, units, total = {}, {}, 0
    local surfaces = {}
    for si in pairs(d.walked or {}) do surfaces[#surfaces+1] = si end
    table.sort(surfaces)
    for _, si in ipairs(surfaces) do
      local by = d.by_type and d.by_type[si]
      for _, t in ipairs(VEHICLE_TYPES) do
        for _, e in ipairs(by and by[t] or {}) do
          local unit = e.valid and e.unit_number
          if unit and not units[unit] then
            units[unit] = true
            total = total + 1
            if #rows < VEHICLES_MAX then
              local s = e.surface
              local pos = e.position
              local visible = try(function() return f.is_chunk_visible(s, {math.floor(pos.x / 32), math.floor(pos.y / 32)}) end) == true
              if visible then seen[unit] = {x=r1(pos.x), y=r1(pos.y), surface=s.name, tick=game.tick} end
              local last = seen[unit]
              local row = {unit_number=unit, name=e.name, type=e.type, surface=last and last.surface or s.name}
              if last then row.position, row.seen_tick, row.age_s = {x=last.x, y=last.y}, last.tick, math.floor((game.tick - last.tick) / 60)
              else row.unseen = true end
              row.visible = visible
              local drv = try(function() return e.get_driver() end)
              if drv then
                local cu = try(function() return drv.unit_number end)
                row.driver = cu and by_char[cu] or 'a player'
              end
              local rm = remote[unit]
              if rm then row.remote = rm.name; row.remote_target = rm.target and {x=r1(rm.target.x), y=r1(rm.target.y)} or nil end
              local sent = routes[unit]
              if sent and sent.by then row.sent_by, row.sent_tick = sent.by, sent.tick end
              local dests = try(function() return e.autopilot_destinations end) or {}
              local first = dests[1] and (dests[1].position or dests[1]) or try(function() return e.autopilot_destination end)
              if first and first.x then row.destination, row.route_targets = {x=r1(first.x), y=r1(first.y)}, math.max(#dests, 1)
              elseif row.remote_target then row.destination = row.remote_target end
              rows[#rows+1] = row
            end
          end
        end
      end
    end
    table.sort(rows, function(a, b) return a.unit_number < b.unit_number end)
    return rows, total
  end
  M.vehicles = vehicles

  -- The operator read: {part = extras | snapshot | machines | basemap, ore = true (basemap)}. Nothing yet: {ready=false}.
  -- basemap with ore: the last finished ore grid on the same cell size, its pass's start as ore.tick, else none
  -- (ore_pending: the next pass reads it). (d22 batch97 BG3) It was served only within ORE_EVERY + PERIOD (19,800
  -- ticks) of its pass's start, and a pass takes 35-41k on world n, so the map never had ore.
  local SNAP_NAMES
  function M.read(args)
    args = type(args) == 'table' and args or {}
    local st = store()
    local d = st.done
    local part = args.part
    assert(part == 'extras' or part == 'snapshot' or part == 'machines' or part == 'basemap' or part == 'planets' or part == 'vehicles', 'part must be extras, snapshot, machines, basemap, planets or vehicles')
    assert(args.surface == nil or (type(args.surface) == 'string' and part == 'basemap'), 'surface goes with part basemap: another planet\'s coarse map')
    if part == 'basemap' and args.ore then st.ore_asked = game.tick end
    if not d then return {ready=false, part=part, pass_running=st.job ~= nil} end
    local out = {ready=true, part=part, as_of=d.start, pass_ticks=d.tick - d.start, age_s=math.floor((game.tick - d.start) / 60),
      refresh_failed=snapfail.line('the census pass', d.start, d.refresh_failed)}
    if part == 'extras' then
      out.electric_machines, out.starved = d.extras.electric_machines, d.extras.starved
    elseif part == 'snapshot' then
      if not SNAP_NAMES then
        SNAP_NAMES = {}
        local want = SNAP
        for name, p in pairs(prototypes.entity) do if want[p.type] then SNAP_NAMES[#SNAP_NAMES+1] = name end end
        table.sort(SNAP_NAMES)
      end
      local f, counts = game.forces.player, {}
      for _, name in ipairs(SNAP_NAMES) do
        local c = f.get_entity_count(name)
        if c > 0 then counts[name] = c end
      end
      out.entities, out.surfaces_with_buildings = counts, d.where
    elseif part == 'machines' then
      out.machines = d.machines
    elseif part == 'vehicles' then
      out.vehicles, out.vehicles_total = vehicles(d)
      out.tick = game.tick
    elseif part == 'planets' then
      -- The other planets with a coarse map: name, building count, cell, size (the maps themselves: basemap surface=).
      local list = {}
      for name, m in pairs(d.planets or {}) do list[#list+1] = {name=name, buildings=m.buildings, cell=m.cell, w=m.w, h=m.h, capped=m.capped} end
      table.sort(list, function(a, b) return a.name < b.name end)
      out.planets = list
    elseif args.surface ~= nil and args.surface ~= 'nauvis' then
      local m = (d.planets or {})[args.surface]
      out.surface = args.surface
      if m then out.basemap = m else out.basemap = nil; out.none = 'no buildings of ours on ' .. args.surface .. ' in the last pass' end
    else
      local map = {}
      for k, v in pairs(d.basemap) do map[k] = v end
      if args.ore then
        if st.ore and st.ore.ore.cell == map.cell then
          local o = {}
          for k, v in pairs(st.ore.ore) do o[k] = v end
          o.tick = st.ore.start
          map.ore = o
        else out.ore_pending = true end
      end
      out.basemap = map
    end
    return out
  end
  M.operator.census = M.read
  return M
end
