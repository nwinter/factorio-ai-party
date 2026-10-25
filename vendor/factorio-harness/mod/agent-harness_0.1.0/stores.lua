-- where_is: where an item is stored on a surface, nearest first, as a player
-- could find by looking (the science study, shift 5: 18 labs lacked red packs
-- for three hours while Gemini moved 1,118 of them out of one chest; `labs`
-- showed stock only at each lab's feeders). Read only. Chests, labs, machines,
-- vehicles, landing pads and platform hubs by entity; belts and inserter hands
-- as totals; the team's characters by name.
local qflow = require('qflow')   -- (d24 batch152 PX1) statistics read at every quality
return function(api)
  local M = {}
  local MAX_LIMIT = 50
  -- Entity types that hold items, and how where_is calls them.
  local KIND = {container='chest', ['logistic-container']='chest', ['linked-container']='chest',
    ['infinity-container']='chest', ['temporary-container']='pod', lab='lab', ['assembling-machine']='machine', furnace='machine',
    ['rocket-silo']='machine', car='vehicle', ['cargo-wagon']='vehicle', ['spider-vehicle']='vehicle',
    ['cargo-landing-pad']='pad', ['space-platform-hub']='hub', roboport='roboport',
    -- (d18 batch39 D2, Opus: speed-module-2 917 read with no place for the most of it) module slots: beacons and drills
    beacon='beacon', ['mining-drill']='drill'}
  local BELTS = {'transport-belt', 'underground-belt', 'splitter', 'loader', 'loader-1x1', 'linked-belt'}
  local TYPES = {}
  for t in pairs(KIND) do TYPES[#TYPES+1] = t end
  table.sort(TYPES)
  local function count_in(e, item)
    -- (d19 batch44 A1) no closure a call: 1987 holders a Nauvis call
    local ok, n = pcall(e.get_item_count, item)
    return ok and type(n) == 'number' and n or 0
  end
  -- How many of a spoilable item in an entity's inventories spoil within `ticks` (d17 batch12 C7, Grok: yumako mash read
  -- 559, then 167 minutes later; a total read as a reserve): each stack's own spoil tick.
  M.SOON_TICKS, M.SOON_PLACES = 7200, 400
  function M.spoils_soon(e, item, ticks)
    local n = 0
    local max = (pcall(function() return e.get_max_inventory_index() end)) and e.get_max_inventory_index() or 0
    for i = 1, max do
      local inv = (pcall(function() return e.get_inventory(i) end)) and e.get_inventory(i) or nil
      if inv then
        for k = 1, #inv do
          local st = inv[k]
          if st.valid_for_read and st.name == item then
            local ok, t = pcall(function() return st.spoil_tick end)
            if ok and type(t) == 'number' and t > 0 and t - game.tick <= ticks then n = n + st.count end
          end
        end
      end
    end
    return n
  end
  -- (d17 batch14 B2, Sol: a cargo pad's overflow spilled landed hardware and where_is and stock read 0) an item's stacks
  -- lying on the ground, as a player sees them: in chunks our force sees now. {count, stacks, cells [{position (the
  -- cell's first stack), count, stacks}] by 32-tile cell, most first}; MAX_GROUND stacks read.
  -- (d25 batch198 QK2, Astra #2325: stock {item: iron-plate, quality: legendary, position, radius: 3} counted 3 stacks
  -- of normal iron, every stack of the 32-tile cell) opts: quality (only stacks of that quality: each stack on the ground
  -- is one item of one quality), position and radius (only the stacks within it, found there). A cell's position is its
  -- nearest stack's then.
  M.MAX_GROUND = 20000
  function M.on_ground(force, surface, item, opts)
    opts = opts or {}
    local f = {type='item-entity', limit=M.MAX_GROUND}
    if opts.position then f.position, f.radius = opts.position, opts.radius end
    local list = surface.find_entities_filtered(f)
    local seen, cells, order, count, stacks = {}, {}, {}, 0, 0
    local function d2(q) return opts.position and (q.x - opts.position.x) ^ 2 + (q.y - opts.position.y) ^ 2 or 0 end
    for _, e in ipairs(list) do
      local ok, st = pcall(function() return e.stack end)
      local okq, sq = true, nil
      if opts.quality and ok and st and st.valid_for_read and st.name == item then okq, sq = pcall(function() return st.quality.name end) end
      if ok and st and st.valid_for_read and st.name == item and (not opts.quality or okq and (sq or 'normal') == opts.quality) then
        local q = e.position
        local cx, cy = math.floor(q.x / 32), math.floor(q.y / 32)
        local k = cx .. ',' .. cy
        if seen[k] == nil then
          local okv, v = pcall(function() return force.is_chunk_visible(surface, {x=cx, y=cy}) end)
          seen[k] = okv and v == true
        end
        if seen[k] then
          count, stacks = count + st.count, stacks + 1
          local c = cells[k]
          if not c then c = {position={x=q.x, y=q.y}, count=0, stacks=0}; cells[k] = c; order[#order+1] = c
          elseif d2(q) < d2(c.position) then c.position = {x=q.x, y=q.y} end
          c.count, c.stacks = c.count + st.count, c.stacks + 1
        end
      end
    end
    table.sort(order, function(x, y) return x.count > y.count end)
    return {count=count, stacks=stacks, cells=order, capped=#list >= M.MAX_GROUND or nil}
  end
  -- (d17 batch33 B1, Grok 09:22: the last pentapod eggs were in an inserter's hand, then a robot's cargo, while where_is
  -- read 0) what our logistic and construction robots on a surface carry of an item: each logistic network's robots'
  -- cargo, at most MAX_ROBOTS robots read a call. Returns count, robots carrying it, robots read, capped.
  -- (world n, 11:15: about 1 us a robot after the ~3 ms list build: 2048 read 4.7 ms)
  -- (d19 batch44 A1) 1024 a call: 2115 robots were 3.5 ms on the private copy's Nauvis
  M.MAX_ROBOTS = 1024
  function M.robot_cargo(force, surface, item)
    local n, carrying, read, capped = 0, 0, 0, false
    local cargo = defines.inventory.robot_cargo
    for _, ln in ipairs((force.logistic_networks or {})[surface.name] or {}) do
      for _, list in ipairs({'logistic_robots', 'construction_robots'}) do
        local ok, robots = pcall(function() return ln[list] end)
        for _, r in ipairs(ok and robots or {}) do
          if read >= M.MAX_ROBOTS then capped = true; break end
          read = read + 1
          local okc, k = pcall(function() return r.get_inventory(cargo).get_item_count(item) end)
          if okc and type(k) == 'number' and k > 0 then n = n + k; carrying = carrying + 1 end
        end
      end
    end
    return n, carrying, read, capped
  end
  -- (d24 batch164 QG1, viewer Aurora 13:15: stock and where_is count items in inventories; a spidertron placed is an
  -- entity, so zero stored with two placed read as none) an item that places a vehicle: our vehicles of that name on
  -- every surface. count is the engine's (LuaForce.get_entity_count); places from game.get_vehicles (cars, tanks,
  -- spidertrons and rolling stock; world n 13:30: 28 vehicles in 0.036 ms), the first PLACED_LIST. nil for any other item.
  local VEHICLE = {car=true, ['spider-vehicle']=true, locomotive=true, ['cargo-wagon']=true, ['fluid-wagon']=true, ['artillery-wagon']=true}
  local READ_WITH = {['spider-vehicle']='vehicle {position} (or remote: true, vehicle: its unit_number) reads its route; inspect {position} reads it in sight',
    car='inspect {position} reads it in sight (32 tiles)'}
  M.PLACED_LIST = 8
  function M.placed(force, item)
    local okp, pr = pcall(function() return prototypes.item[item].place_result end)
    if not (okp and pr and VEHICLE[pr.type]) then return nil end
    local name, kind = pr.name, pr.type
    local okc, count = pcall(function() return force.get_entity_count(name) end)
    count = okc and type(count) == 'number' and count or 0
    local found, by_surface = {}, {}
    local okv, list = false, nil
    if count > 0 then okv, list = pcall(function() return game.get_vehicles{force=force} end) end
    for _, e in ipairs(okv and list or {}) do
      if e.valid and e.name == name then
        local s = e.surface.name
        by_surface[s] = (by_surface[s] or 0) + 1
        found[#found+1] = {surface=s, position={x=math.floor(e.position.x * 10 + 0.5) / 10, y=math.floor(e.position.y * 10 + 0.5) / 10}, unit_number=e.unit_number}
      end
    end
    table.sort(found, function(x, y)
      if x.surface ~= y.surface then return x.surface < y.surface end
      if x.position.x ~= y.position.x then return x.position.x < y.position.x end
      return x.position.y < y.position.y
    end)
    local places, bits = {}, {}
    for i, f in ipairs(found) do
      if i <= M.PLACED_LIST then
        places[i] = f
        bits[i] = string.format('%s (%g,%g)%s', f.surface, f.position.x, f.position.y, f.unit_number and ' #' .. f.unit_number or '')
      end
    end
    local read_with = READ_WITH[kind] or 'train {all, surface} lists its train'
    local note = count > #found and string.format('%d not listed (%s)', count - #found, okv and 'not among the vehicles the game lists' or 'the vehicle list could not be read') or nil
    return {entity=name, type=kind, count=count, by_surface=by_surface, places=places, more=#found > M.PLACED_LIST and #found - M.PLACED_LIST or nil,
      not_listed=note, read_with=read_with,
      line=string.format('%d placed (as vehicles: %s entities, not items)%s%s%s', count, name,
        #bits > 0 and ': ' .. table.concat(bits, ', ') or '', #found > M.PLACED_LIST and string.format(' and %d more', #found - M.PLACED_LIST) or '',
        note and '; ' .. note or '') .. (count > 0 and '; ' .. read_with or '')}
  end
  -- The scope line of a vehicle item's read: stored (as items) and placed (as vehicles) side by side; nil for other items.
  function M.scope_line(force, item, stored, where)
    local okp, pl = pcall(M.placed, force, item)
    if not (okp and pl) then return nil end
    return string.format('%s: %d stored (as items%s), %s', item, stored, where and ', ' .. where or '', pl.line), pl
  end
  -- stock's reply for an item (runtime.lua stock_one): a vehicle item's total is what is stored; the scope line leads its
  -- summary (or line), placed beside it.
  function M.stock_scope(force, item, out)
    if type(out) ~= 'table' or type(item) ~= 'string' or type(out.total) ~= 'number' then return out end
    local ok, line, pl = pcall(M.scope_line, force, item, out.total, 'this read\'s total')
    if not (ok and line) then return out end
    out.placed, out.scope_line = pl, line
    if out.summary then out.summary = line .. '; stored: ' .. out.summary
    elseif out.line then out.line = line .. '; stored: ' .. out.line
    else out.summary = line end
    return out
  end
  M.CENSUS_PLACES = 120
  local HOLDER ={pad='landing pads', lab='labs', machine='machines', pod='landed cargo pods', hub='platform hubs', vehicle='vehicles',
    roboport='roboports', character='characters', ground='on the ground', beacon='beacons', drill='drills'}
  local mode_of = {}
  function M.census_of(p, surface, item, places, ent_of, totals)
    local sp = api.spoil and api.spoil()
    local spoils = sp and sp.spoils(item)
    local by, order = {}, {}
    local function row(name)
      local r = by[name]
      if not r then r = {holder=name, count=0, places=0, acc={}}; by[name] = r; order[#order+1] = r end
      return r
    end
    local list = {}
    for _, pl in ipairs(places) do list[#list+1] = pl end
    table.sort(list, function(x, y) return x.count > y.count end)
    local read = 0
    for i, pl in ipairs(list) do
      local e = ent_of[pl]
      local name = HOLDER[pl.kind] or pl.kind
      if pl.kind == 'chest' and e then
        if e.type == 'logistic-container' then
          local m = mode_of[e.name]
          if m == nil then m = select(2, pcall(function() return e.prototype.logistic_mode end)) or 'logistic'; mode_of[e.name] = m end
          name = (m == 'active-provider' or m == 'passive-provider') and 'provider chests' or m .. ' chests'
        else name = 'plain chests' end
      end
      local r = row(name)
      r.count, r.places = r.count + pl.count, r.places + 1
      if spoils and e and i <= M.CENSUS_PLACES then
        read = read + 1
        local okm, max = pcall(function() return e.get_max_inventory_index() end)
        for k = 1, okm and max or 0 do
          local okv, inv = pcall(e.get_inventory, k)
          if okv and inv and (select(2, pcall(inv.get_item_count, item)) or 0) > 0 then pcall(sp.inventory, inv, r.acc) end
        end
      end
    end
    for _, k in ipairs({'belts', 'inserter_hands', 'robot_cargo', 'in_flight'}) do
      if (totals[k] or 0) > 0 then local r = row(k:gsub('_', ' ')); r.count = totals[k]; r.unread = true end
    end
    local rows, lines = {}, {}
    local ru = 0
    for _, r in ipairs(order) do
      local x = r.acc[item] or r.acc[1]
      local research = x and sp.research_value and select(2, pcall(sp.research_value, x, p.force))
      if type(research) ~= 'table' then research = nil end
      if research then ru = ru + research.now end
      local spread = x and select(2, pcall(sp.spread, x))
      if type(spread) ~= 'table' then spread = nil end
      rows[#rows+1] = {holder=r.holder, count=r.count, places=r.places > 0 and r.places or nil, spread=spread,
        research_units=research and math.floor(research.now * 100 + 0.5) / 100 or nil}
      lines[#lines+1] = string.format('%s %d%s%s%s', r.holder, r.count, r.places > 0 and string.format(' in %d place%s', r.places, r.places == 1 and '' or 's') or '',
        spread and string.format(', %d%% spoiled by count (%d-%d%%), %d spoil within 10 min', spread.mean, spread.min, spread.max, spread.within['10min']) or
          (spoils and (r.unread and ', spoil not read (counted only)' or (x == nil and r.places > 0 and ', spoil not read (past the largest ' .. M.CENSUS_PLACES .. ' places)' or '')) or ''),
        research and string.format(', %.1f research units', research.now) or '')
    end
    table.sort(rows, function(x, y) return x.count > y.count end)
    local stats = select(2, pcall(function() return p.force.get_item_production_statistics(surface) end))
    local function per_min(cat)
      local ok, n = pcall(function() return qflow.flow(stats, item, cat, defines.flow_precision_index.ten_minutes, true) end)
      return ok and type(n) == 'number' and math.floor(n / 10 + 0.5) or nil
    end
    return {rows=rows, lines=lines, research_units=ru > 0 and math.floor(ru * 100 + 0.5) / 100 or nil,
      made_per_min=per_min('input'), used_per_min=per_min('output'), tick=game.tick,
      spoil_read=spoils and string.format('the largest %d of %d places read for spoil', math.min(read, M.CENSUS_PLACES), #list) or nil,
      note='made and used a minute: the production statistics over the last 10 minutes (used: what labs, machines and launches consumed, and fuel burned; spoiling counts in neither)'}
  end
  function M.where_is(p, a)
    local item = a.item
    assert(type(item) == 'string' and item ~= '', 'item is required (an item name, e.g. automation-science-pack)')
    local ok_proto, known = pcall(function() return prototypes.item[item] ~= nil end)
    assert(not ok_proto or known, 'unknown item ' .. item)
    local limit = a.limit or 15
    assert(type(limit) == 'number' and limit >= 1 and limit <= MAX_LIMIT, 'limit must be 1..' .. MAX_LIMIT)
    assert(a.sort == nil or a.sort == 'largest' or a.sort == 'nearest', 'sort is "largest" (default) or "nearest"')
    assert(a.census == nil or type(a.census) == 'boolean', 'census must be true or false')
    assert(a.page == nil or (type(a.page) == 'number' and a.page >= 1 and a.page == math.floor(a.page)), 'page is a whole number from 1')
    local surface = p.surface
    if a.surface ~= nil then
      assert(type(a.surface) == 'string', 'surface must be a surface or platform surface name')
      surface = game.get_surface and game.get_surface(a.surface) or nil
      assert(surface, 'unknown surface ' .. a.surface)
    end
    local here = (surface == p.surface) and p.position or nil
    local function dist(pos)
      if not (here and pos) then return nil end
      return math.floor(math.sqrt((pos.x - here.x) ^ 2 + (pos.y - here.y) ^ 2) + 0.5)
    end
    local places, totals = {}, {}
    local function add(kind, n)
      totals[kind] = (totals[kind] or 0) + n
    end
    -- (d19 batch44 A1: 111 ms for one Nauvis call on the private copy: every holder, belt, inserter, cargo pod and ground
    -- stack found and read each call) the holders, and what belts and inserter hands carry, from the census's last pass
    -- (census.lua where_index, every 30 s), and the ground from the ground watch's last pass; a call reads the holders'
    -- counts now. Before a pass, the reads as before.
    local okx, idx = pcall(function() return api.where_index and api.where_index(p.force, surface) end)
    idx = okx and idx or nil
    local holders = idx and idx.holders or surface.find_entities_filtered{force=p.force, type=TYPES}
    local ent_of = {}
    for _, e in ipairs(holders) do
      local n = count_in(e, item)
      if n > 0 then
        local kind = KIND[e.type] or 'other'
        add(kind, n)
        -- what of it sits in the module slots (a machine, beacon, drill or lab)
        local mods = (kind == 'machine' or kind == 'beacon' or kind == 'drill' or kind == 'lab') and
          (pcall(function() return e.get_module_inventory() end) and e.get_module_inventory()) or nil
        local in_mods = mods and select(2, pcall(function() return mods.get_item_count(item) end)) or 0
        if type(in_mods) ~= 'number' then in_mods = 0 end
        places[#places+1] = {kind=kind, entity=e.name, position={x=e.position.x, y=e.position.y}, count=n,
          in_module_slots=in_mods > 0 and in_mods or nil, distance=dist(e.position)}
        ent_of[places[#places]] = e
        if in_mods > 0 then totals.module_slots = (totals.module_slots or 0) + in_mods; totals[kind] = totals[kind] - in_mods end
      end
    end
    -- Landed cargo pods of any force (batch28 B3, Muse: unclaimed cargo with no positions), each once.
    local seen_pod = {}
    for _, pl in ipairs(places) do seen_pod[pl.entity .. '@' .. pl.position.x .. ',' .. pl.position.y] = true end
    for _, e in ipairs(idx and {} or surface.find_entities_filtered{name='cargo-pod-container'}) do
      local n = count_in(e, item)
      if n > 0 and not seen_pod[e.name .. '@' .. e.position.x .. ',' .. e.position.y] then
        add('pod', n)
        places[#places+1] = {kind='pod', entity=e.name, position={x=e.position.x, y=e.position.y}, count=n, distance=dist(e.position)}
      end
    end
    -- Belts and inserter hands: totals only (thousands of segments).
    local on_belts = idx and (idx.belts[item] or 0) or 0
    for _, e in ipairs(idx and {} or surface.find_entities_filtered{force=p.force, type=BELTS}) do
      local ok, lines = pcall(function() return e.get_max_transport_line_index() end)
      for i = 1, ok and lines or 0 do
        local ok2, n = pcall(function() return e.get_transport_line(i).get_item_count(item) end)
        if ok2 and type(n) == 'number' then on_belts = on_belts + n end
      end
    end
    if on_belts > 0 then add('belts', on_belts) end
    local held = idx and (idx.hands[item] or 0) or 0
    for _, e in ipairs(idx and {} or surface.find_entities_filtered{force=p.force, type='inserter'}) do
      local ok, n = pcall(function()
        local s = e.held_stack
        return s and s.valid_for_read and s.name == item and s.count or 0
      end)
      if ok and type(n) == 'number' then held = held + n end
    end
    if held > 0 then add('inserter_hands', held) end
    local okr, robot_n, carriers, robots_read, capped = pcall(M.robot_cargo, p.force, surface, item)
    if okr and robot_n > 0 then add('robot_cargo', robot_n) end
    local robot_note = okr and capped and string.format('robot cargo: the first %d robots read', robots_read) or nil
    -- The team's characters on this surface, by agent name.
    for _, ag in ipairs(api.agents()) do
      local c = api.character(ag.index)
      if c and c.valid and c.surface == surface then
        local n = count_in(c, item)
        if n > 0 then
          add('characters', n)
          places[#places+1] = {kind='character', agent=ag.name, position={x=c.position.x, y=c.position.y}, count=n,
            distance=dist(c.position)}
          ent_of[places[#places]] = c
        end
      end
    end
    table.sort(places, function(x, y)
      if x.distance and y.distance and x.distance ~= y.distance then return x.distance < y.distance end
      if x.count ~= y.count then return x.count > y.count end
      return x.position.x < y.position.x
    end)
    -- Cargo pods from our platforms still in the air toward this surface (pods.lua; Grok, shift13: 519 packs were in
    -- the air while where_is and the pad showed none): each with its platform, state, count and where it lands.
    local flying = {}
    for _, r in ipairs(api.pods and api.pods.in_flight(p.force.name, surface.name) or {}) do
      local n = 0
      for k, v in pairs(r.items) do if k == item or k:match('^([^@]+)') == item then n = n + v end end
      if n > 0 then
        add('in_flight', n)
        flying[#flying+1] = {platform=r.platform, state=r.state, count=n,
          lands=r.pad and string.format('landing pad (%g,%g)%s', r.pad.x, r.pad.y,
            r.guessed and string.format(' (%s\'s pad: pods from a platform land in it; this one names no station yet)', surface.name) or '')
            or string.format('the ground (no landing pad of ours on %s)', surface.name)}
      end
    end
    -- on the ground (B2): a place per 32-tile cell
    local okgi, gi = pcall(function() return api.ground_index and api.ground_index(p.force, surface, item) end)
    gi = okgi and gi or nil
    local okg, g = true, gi
    if not gi then okg, g = pcall(M.on_ground, p.force, surface, item) end
    if okg and g.count > 0 then
      add('on_ground', g.count)
      for _, c in ipairs(g.cells) do
        places[#places+1] = {kind='ground', entity=string.format('%d stack%s on the ground', c.stacks, c.stacks == 1 and '' or 's'), position=c.position, count=c.count,
          distance=dist(c.position)}
      end
      table.sort(places, function(x, y)
        if x.distance and y.distance and x.distance ~= y.distance then return x.distance < y.distance end
        if x.count ~= y.count then return x.count > y.count end
        return x.position.x < y.position.x
      end)
    end
    local total = 0
    for _, n in pairs(totals) do total = total + n end
    -- A spoilable item: what of it spoils within 2 minutes in the places read (the first SOON_PLACES, the most held first).
    local soon
    local spoils = pcall(function() return prototypes.item[item].get_spoil_ticks() end) and prototypes.item[item].get_spoil_ticks() > 0
    if spoils then
      local order = {}
      for _, e in ipairs(places) do order[#order+1] = e end
      table.sort(order, function(x, y) return x.count > y.count end)
      soon = 0
      for i, pl in ipairs(order) do
        if i > M.SOON_PLACES then break end
        local e = ent_of[pl]
        if e then local n = M.spoils_soon(e, item, M.SOON_TICKS); soon = soon + n; if n > 0 then pl.spoils_within_2_min = n end end
      end
    end
    -- (D2) the places largest first by default (nearest with sort: "nearest"), a page of limit; and each kind's share
    if a.sort ~= 'nearest' then
      table.sort(places, function(x, y)
        if x.count ~= y.count then return x.count > y.count end
        if x.distance and y.distance and x.distance ~= y.distance then return x.distance < y.distance end
        return x.position.x < y.position.x
      end)
    end
    local nkind = {}
    for _, pl in ipairs(places) do
      local k = pl.in_module_slots and 'module_slots' or pl.kind == 'character' and 'characters' or pl.kind == 'ground' and 'on_ground' or pl.kind
      nkind[k] = (nkind[k] or 0) + 1
    end
    local words = {}
    for k, n in pairs(totals) do
      if n > 0 then words[#words+1] = {k=k, n=n} end
    end
    table.sort(words, function(x, y) if x.n ~= y.n then return x.n > y.n end return x.k < y.k end)
    for i, w in ipairs(words) do
      words[i] = string.format('%d %s%s', w.n, w.k == 'module_slots' and 'in module slots' or (w.k:gsub('_', ' ')), nkind[w.k] and string.format(' (%d place%s)', nkind[w.k], nkind[w.k] == 1 and '' or 's') or '')
    end
    local page = a.page or 1
    local out = {item=item, surface=surface.name, total=total, by_kind=totals, places={}, more=0, in_flight=#flying > 0 and flying or nil,
      kinds_line=#words > 0 and string.format('%d %s: %s', total, item, table.concat(words, ', ')) or nil, sort=a.sort or 'largest', page=page,
      pages=math.max(1, math.ceil(#places / limit)),
      spoils_within_2_min=soon, spoil_note=soon and string.format('%d of the %d spoil within 2 minutes (chests, machines and the like; belts, hands and robot cargo not read)', soon, total) or nil,
      robot_cargo=okr and robot_n > 0 and string.format('%d carried by %d robot%s now', robot_n, carriers, carriers == 1 and '' or 's') or nil, robot_note=robot_note}
    local first = (page - 1) * limit + 1
    for i, e in ipairs(places) do
      if i >= first and i < first + limit then out.places[#out.places+1] = e elseif i >= first + limit then out.more = out.more + 1 end
    end
    if out.more == 0 then out.more = nil end
    -- (d17 batch34 A2, Astra, Luna) drops of it into a landing pad here, with what the pad showed after they landed
    local drops = api.drops_taken and api.drops_taken({item=item, surface=surface.name}) or {}
    if #drops > 0 then
      out.drops = {}
      for i, d in ipairs(drops) do out.drops[i] = d.verdict and d.verdict .. ': ' .. d.line or d.line end
    end
    -- (d18 batch37 D3, Astra) robots' deconstructions of it on that surface: the robot, where it carried it, the ghost it built
    local went = api.deconstructed and api.deconstructed(item, surface.name) or {}
    if #went > 0 then out.deconstructed = went end
    -- (QG1) a vehicle item: stored (the counts here, as items) and placed (as vehicles) side by side
    local scope, pl = M.scope_line(p.force, item, total, 'in inventories on ' .. surface.name)
    if scope then
      out.scope, out.placed = 'stored: items in inventories, chests, trunks, belts and hands (total, by_kind, places); placed: vehicles standing in the world, on every surface (placed)', pl
      out.scope_line = scope
      if out.kinds_line then out.kinds_line = scope .. '; stored: ' .. out.kinds_line end
    end
    if total == 0 then out.note = (pl and pl.count > 0 and string.format('none stored as items on this surface; %d placed as vehicles (placed)', pl.count) or 'none on this surface') ..
      ' (surface=NAME looks on another planet or platform)' end
    -- (d19 batch45, batch40 B1, Luna: stock read 66 just after a pod while supply said 194 in circulation) census: the
    -- count by holder, each with its spoil spread and, for a science pack, its effective research units (spoil.lua), the
    -- largest CENSUS_PLACES places read for spoil; belts, inserter hands, robots' cargo and pods in the air by count;
    -- made and used a minute over the last 10 minutes; the read's tick
    if a.census then out.census = M.census_of(p, surface, item, places, ent_of, totals) end
    -- (A1) what the call read from the passes, and how old they are
    local function ago(t) return t and string.format('%ds ago, tick %d', math.floor((game.tick - t) / 60), t) or '?' end
    if idx then
      out.read_from = string.format('chests, machines and the other places as the census found them (%s; places built since are not in it, gone ones are left out), their counts now; belts and inserter hands as that pass read them; landed cargo pods of other forces not read%s',
        ago(idx.as_of), idx.capped and '; the census keeps the first 30000 places of a surface' or '')
    end
    if gi then out.ground_read_from = 'the stacks on the ground as the ground watch last binned them (' .. ago(gi.as_of) .. ')' end
    return out
  end
  M.schema = {
    where_is = {item='item name', limit='1..50 places a page (default 15)', surface='optional surface name (default yours)',
      sort='optional "largest" (default: the most held first) or "nearest"',
      census='optional true: census {rows [{holder (landing pads, provider, storage, requester, buffer and plain chests, labs, machines, characters, belts, inserter hands, robot cargo, in flight ...), count, places, spread (a spoilable item: spoiled share, range, quarters, within 10/30/60 min), research_units (a science pack: effective units now, before lab bonuses)}], lines, research_units, made_per_min, used_per_min (production statistics, last 10 min), tick, spoil_read (how many places were read for spoil: the largest 120)}', page='optional page of places (default 1; pages says how many)',
      returns='scope, scope_line and placed (an item that places a vehicle: spidertron, car, tank, locomotive, wagons): stored (as items, the counts here) and placed (as vehicles: the engine\'s count on every surface, by_surface, places {surface, position, unit_number} the first 8, not_listed, read_with: the read that reads one) side by side; read_from and ground_read_from: what the call took from the census and ground watch passes (every 30 s) and how old they are; deconstructed: robots\' deconstructions of it (or of an entity of that name) on that surface, newest first (6): the robot that took it, then each step seen: the ghost it built (and who placed the ghost), the storage chest it went into, the construction robot that took it from there and what that one built, or that it left no trace seen; drops: recent drops of it into a landing pad on that surface (the last 4), each with what the pad showed: landed, then taken by construction robots (and how many, with the first orders they flew to), as the drops read\'s pad line; total and by_kind (a spoilable item: spoils_within_2_min and spoil_note, each place its own spoils_within_2_min; chest, lab, machine, beacon, drill, module_slots (what sits in machines\', beacons\', drills\' and labs\' module slots), vehicle, pad, hub, roboport, pod (a landed cargo pod\'s container, of any force), belts, inserter_hands, robot_cargo (what our logistic and construction robots carry now, up to 1024 robots read: robot_note when capped), characters, in_flight, on_ground: stacks lying on the ground in chunks our force sees now); kinds_line (each kind\'s count and places, the most first); places: each chest, lab, machine, beacon, drill, vehicle, pad, hub and teammate holding it {kind, entity or agent, position, count, in_module_slots, distance} (kind ground: the stacks on the ground in one 32-tile cell, entity says how many), the most held first (sort: nearest), limit a page (belts and inserter hands as totals only); more: places past this page; page, pages; in_flight: cargo pods from our platforms still in the air toward this surface {platform, state (awaiting_launch, ascending, descending, parking), count, lands}. Read only'},
  }
  return M
end
