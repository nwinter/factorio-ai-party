-- The base's networks as a player's GUIs show them (operator, task-selfview:
-- Nauvis at 29 game hours ran steam only, about 21 MW capacity and 10.8 MW
-- drawn, with nuclear and solar researched; 147 logistic robots, none idle;
-- 0 laser turrets). One line per network, numbers only:
-- - electric networks over 2 poles (or with a generator): draw over the last
--   5 minutes against the generators' capacity, solar now and at peak,
--   accumulators, machines on low or no power, and the boilers feeding the
--   network with their fuel in minutes at that draw;
-- - logistic networks: logistic and construction robots, all and idle;
--   requests unfilled for 60 s or more; ghosts in its construction area;
-- - turrets by name, and ammo used on the surface in the last hour.
-- In the first reply of a shift (team.shift.networks) and the networks read;
-- push alert kinds (pushalerts.lua): power_high (draw at 85% of
-- capacity or more for 2 minutes), robots_busy (no idle logistic robot for 10
-- minutes), boiler_fuel (boilers under 20 minutes of their own fuel at the
-- draw that no feeder can bring more to, told
-- again at 10 and 5, with the fuel in chests and on belts nearby and what feeds them),
-- accumulators_draining (accumulators empty within 10 minutes at their net flow; ACC_LOOK) and others below.
-- Draw comes from the network's statistics, sampled every 5 s (the 5-second
-- average, J per tick as handlers.power reads it): the game's own windows are
-- 5 s, 1 min and 10 min.
return function(api)
  local M = {}
  local SAMPLE, WATCH_TICKS, WINDOW = 300, 1800, 18000
  local HIGH, HIGH_TICKS = 0.85, 7200
  local BUSY_TICKS, FUEL_LOW, UNFILLED_TICKS = 36000, 10, 3600
  -- boiler_fuel steps (Haiku, shift09: 10 minutes left was too late to feed by hand): told at 20, again at 10 and 5.
  local FUEL_STEPS, FUEL_RADIUS = {20, 10, 5}, 64
  -- Haiku, 01:53: the alert fired for hours ('lowest 0 min') on 13 boilers holding 4-26 coal each, all working, fed by
  -- inserters from a belt and a requester chest with 150+ coal. Haiku and Astra, 03:20: still 'under 5 min' for 12
  -- working boilers on full fuel belts (an inserter keeps a boiler's own fuel low; a belt's stock is a flow, not a
  -- store). A boiler is low only when its own fuel is under a step and nothing refills it: none of its feeders can
  -- bring more (no fuel in the inserter's hand, at its source; a belt: up to BELT_WALK tiles upstream, else what
  -- loads that run), or its own fuel is draining: per DRAINS {share, ticks}, it fell by that share or more of what
  -- it burns at its share of the draw since its newest look that many ticks back (shift10: boiler (-15,42) on a
  -- 64-tile belt with 0-4 solid-fuel went from 8 min at 03:36 to 6 at 03:38 and 3 at 03:47: fast, then slow). An
  -- inserter-kept buffer swings by a few items and has no trend: a few coal is a quarter of a minute's burn, a few
  -- solid-fuel nearly a minute's, so the looks compared are 2 and 4 minutes back or more.
  local BELT_WALK, OWN_TICKS, OWN_LOOKS = 64, 21600, 30
  local DRAINS = {{0.8, 7200}, {0.25, 14400}}
  local FUEL_SCAN = 300   -- chests and belt tiles read per alert (00:26 rule: bounded reads on the live world)
  local FUELS = {'coal', 'solid-fuel', 'wood', 'rocket-fuel', 'nuclear-fuel'}
  local MAX_SCAN, MAX_GHOSTS, VIEW_TICKS, NEAR_BOILER = 20000, 4000, 3600, 12   -- the view: kept 60 s (task-statuscost)
  local ITEMS_TOP = 6   -- items named on a logistic network's line, held and asked (Gemini, 12:20)
  -- Entities read a step by the background view and pole map, and boilers whose feeders are read a step (operator
  -- 04:00: 1500 a tick, and every boiler's feeders and belts in one tick, burst in single game seconds).
  local SLICE, BOILER_SLICE = 150, 2
  -- Accumulators running down (Gemini, shift12 15:10: Fulgora's daylight lull between storms): the net flow out of a
  -- network's accumulators over the last ACC_LOOK ticks (a Fulgora day is 3 min: 90 s of storm, 90 s of daylight, so
  -- minutes of average would net the storm's charge against the lull's drain) against what they hold now, told under
  -- ACC_WARN seconds (again at 5 and 2 min); a network told keeps its group ACC_HOLD ticks after it last fell under
  -- ACC_WARN, at the worst step it reached, so a storm between lulls is not news every Fulgora day. Their energy is
  -- read when the alert scan runs (up to ACC_READ accumulators a network; the view's sum is gathered over a minute).
  local ACC_LOOK, ACC_MIN_SAMPLES, ACC_WARN, ACC_HOLD, ACC_READ = 1800, 4, 600, 36000, 1000
  local walk = api.walk or require('walk'){state=api.state}
  local GENERATORS = {'generator', 'burner-generator', 'solar-panel', 'accumulator', 'fusion-generator', 'electric-energy-interface'}
  local MACHINES = {'assembling-machine', 'furnace', 'mining-drill', 'lab', 'inserter', 'beacon', 'radar', 'roboport', 'pump',
    'electric-turret', 'rocket-silo', 'agricultural-tower', 'asteroid-collector', 'lamp', 'loader', 'loader-1x1', 'offshore-pump'}
  local TURRETS = {'ammo-turret', 'electric-turret', 'fluid-turret', 'artillery-turret'}
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local slots = require('slots')()
  local ACC_NAMES
  local function acc_names()
    if not ACC_NAMES then
      ACC_NAMES = {}
      for name, proto in pairs(prototypes.entity or {}) do if proto.type == 'accumulator' then ACC_NAMES[name] = true end end
    end
    return ACC_NAMES
  end
  local function store()
    local s = api.state()
    s.networks = s.networks or {map={}, samples={}, busy={}, unfilled={}, views={}}
    return s.networks
  end
  local function forces()
    local out = {}
    for _, f in pairs(game.forces or {}) do if f.players and #f.players > 0 then out[#out+1] = f end end
    return out
  end
  local function surfaces()
    local out = {}
    for _, s in pairs(game.surfaces or {}) do out[#out+1] = s end
    table.sort(out, function(a, b) return a.index < b.index end)
    return out
  end

  -- Every 30 s: which pole stands for each electric network (one per network
  -- id), how many poles it has and where; and the logistic networks' robots
  -- and requests. Every 5 s: each network's draw.
  local function pole_into(map, e, surface, f)
    local id = e.valid and try(function() return e.electric_network_id end)
    if id then
      local m = map[id]
      if not m then m = {id=id, pole=e, poles=0, sx=0, sy=0, surface=surface.name, force=f.name}; map[id] = m end
      m.poles, m.sx, m.sy = m.poles + 1, m.sx + e.position.x, m.sy + e.position.y
    end
  end
  local function map_poles(n)
    local map = {}
    for _, f in ipairs(forces()) do
      for _, surface in ipairs(surfaces()) do
        local poles = try(function() return surface.find_entities_filtered{type='electric-pole', force=f, limit=MAX_SCAN} end) or {}
        for _, e in ipairs(poles) do pole_into(map, e, surface, f) end
      end
    end
    n.map, n.map_tick = map, game.tick
    for id in pairs(n.samples) do if not map[id] then n.samples[id] = nil end end
    for id in pairs(n.acc_refs or {}) do if not map[id] then n.acc_refs[id] = nil end end
  end
  -- The pole map in the background (operator 04:00: the view's map step found
  -- every pole on every surface at once each minute, 122 ms in one game
  -- second): per force and surface a walk of the poles (walk.lua), a band or
  -- SLICE poles a step, the steps spread over VIEW_TICKS; the map is replaced
  -- when the walk ends.
  local function map_step(n, tick)
    n.map_bg = true
    local job = n.map_job
    if not job then
      if n.map_tick and tick - n.map_tick < VIEW_TICKS then return end
      local todo = {}
      for _, f in ipairs(forces()) do for _, s in ipairs(surfaces()) do todo[#todo+1] = {force=f.name, surface=s.index} end end
      n.map_job = {start=tick, todo=todo, i=1, map={}, steps=0, every=walk.every(n.map_steps, VIEW_TICKS)}
      return
    end
    if not walk.due(job, tick, VIEW_TICKS) then return end
    job.steps = job.steps + 1
    local pr = job.todo[job.i]
    if not pr then
      n.map, n.map_tick, n.map_steps, n.map_job = job.map, job.start, job.steps, nil
      for id in pairs(n.samples) do if not n.map[id] then n.samples[id] = nil end end
      return
    end
    local f, s = game.forces[pr.force], game.get_surface(pr.surface)
    if not (f and s) then job.i, job.walk, job.list = job.i + 1, nil, nil
    elseif job.list then
      local last = math.min(#job.list, job.at + SLICE - 1)
      for k = job.at, last do pole_into(job.map, job.list[k], s, f) end
      job.at = last + 1
      if job.at > #job.list then job.list = nil end
    else
      job.walk = job.walk or walk.start(s)
      local list = walk.band(job.walk, s, {type='electric-pole', force=f, limit=MAX_SCAN})
      if list then job.list, job.at = list, 1 else job.i, job.walk = job.i + 1, nil end
    end
  end
  local function sample(n)
    for id, m in pairs(n.map) do
      local stats = m.pole.valid and try(function() return m.pole.electric_network_statistics end)
      if stats then
        local by, kw = {}, 0
        local accs, acc = acc_names(), 0
        for name in pairs(try(function() return stats.output_counts end) or {}) do
          local v = try(function() return stats.get_flow_count{name=name, category='output', precision_index=defines.flow_precision_index.five_seconds} end)
          if v and v > 0 then
            by[name] = v * 60 / 1000; kw = kw + by[name]
            if accs[name] then acc = acc + by[name] end
          end
        end
        -- (accumulators are counted as producers while they discharge and as consumers while they charge)
        for name in pairs(accs) do
          local v = try(function() return stats.get_flow_count{name=name, category='input', precision_index=defines.flow_precision_index.five_seconds} end)
          if v and v > 0 then acc = acc - v * 60 / 1000 end
        end
        local list = n.samples[id] or {}
        n.samples[id] = list
        -- What the network's accumulators hold at this sample (Astra, shift14 22:50: a series over a Fulgora day took
        -- ~15 single reads): the ones the last view found, read now (plain reads of valid accumulators: 0.09 ms for
        -- Fulgora's 203 on a copy of world n, 0.2-0.6 ms with a pcall each).
        local refs = n.acc_refs and n.acc_refs[id]
        local acc_j, acc_buf
        if refs then
          acc_j, acc_buf = 0, 0
          for _, e in ipairs(refs) do
            if e.valid then acc_j, acc_buf = acc_j + e.energy, acc_buf + e.electric_buffer_size end
          end
        end
        list[#list+1] = {tick=game.tick, kw=kw, by=by, acc=acc, acc_j=acc_j, acc_buf=acc_buf}
        while list[1] and list[1].tick <= game.tick - WINDOW do table.remove(list, 1) end
      end
    end
  end
  local function logistic_networks(f, surface)
    return try(function() return f.logistic_networks[surface.name] end) or {}
  end
  -- Requests a network has not filled: per requester point and item, how much
  -- is missing (wanted minus held minus on the way).
  local function shortfalls(ln)
    local out = {}
    local points = try(function() return ln.requester_points end)
    if not points then
      points = {}
      for _, e in ipairs(try(function() return ln.requesters end) or {}) do
        local pt = try(function() return e.get_logistic_point(defines.logistic_member_index.logistic_container) end)
        if pt then points[#points+1] = pt end
      end
    end
    for _, pt in ipairs(points) do
      local owner = try(function() return pt.owner end)
      local unit = owner and try(function() return owner.unit_number end)
      local coming = try(function() return pt.targeted_items_deliver end) or {}
      for _, f in ipairs(try(function() return pt.filters end) or {}) do
        local name = type(f.name) == 'table' and f.name.name or f.name
        local quality = type(f.quality) == 'table' and f.quality.name or f.quality or 'normal'
        if name and (f.count or 0) > 0 and unit then
          local have = try(function() return owner.get_item_count{name=name, quality=quality} end) or 0
          local on_way = 0
          if type(coming[name]) == 'number' then on_way = coming[name]
          else for _, c in pairs(coming) do if type(c) == 'table' and c.name == name then on_way = on_way + (c.count or 0) end end end
          local missing = f.count - have - on_way
          if missing > 0 then out[#out+1] = {key=unit .. '|' .. name .. '|' .. quality, name=name, missing=missing, e=owner} end
        end
      end
    end
    return out
  end
  local function watch_logistics(n)
    local busy, unfilled = {}, {}
    for _, f in ipairs(forces()) do
      for _, surface in ipairs(surfaces()) do
        for _, ln in ipairs(logistic_networks(f, surface)) do
          local id = try(function() return ln.network_id end)
          if id then
            local all, idle = try(function() return ln.all_logistic_robots end) or 0, try(function() return ln.available_logistic_robots end) or 0
            if all > 0 and idle == 0 then busy[id] = n.busy[id] or game.tick end
            for _, x in ipairs(shortfalls(ln)) do unfilled[x.key] = n.unfilled[x.key] or game.tick end
          end
        end
      end
    end
    n.busy, n.unfilled = busy, unfilled
  end
  -- Stock per logistic network every 5 min, the last 8 kept (35 min), for the look-ahead (lookahead.lua, Nick 12:35):
  -- items whose stock falls at the last 30 min's rate to zero within 2 hours (all game time).
  local STOCK_EVERY, STOCK_KEEP, STOCK_LOOK, STOCK_HORIZON = 18000, 8, 108000, 432000
  local function sample_stock(n)
    n.stock = n.stock or {}
    local seen = {}
    for _, f in ipairs(forces()) do
      for _, surface in ipairs(surfaces()) do
        for _, ln in ipairs(logistic_networks(f, surface)) do
          local id = try(function() return ln.network_id end)
          if id then
            local key = f.name .. '|' .. id
            seen[key] = true
            local counts = {}
            for _, x in ipairs(try(function() return ln.get_contents() end) or {}) do
              local name = type(x.name) == 'table' and x.name.name or x.name
              if name then counts[name] = (counts[name] or 0) + (x.count or 0) end
            end
            local h = n.stock[key] or {force=f.name, id=id, samples={}}
            h.surface = surface.name
            h.samples[#h.samples+1] = {tick=game.tick, counts=counts}
            while #h.samples > STOCK_KEEP do table.remove(h.samples, 1) end
            n.stock[key] = h
          end
        end
      end
    end
    for key in pairs(n.stock) do if not seen[key] then n.stock[key] = nil end end
  end
  -- Rows {name, id, surface, ticks (to zero), left}, soonest first, at most max; and whether any network has 30 min
  -- of samples yet.
  function M.running_out(f, max)
    local n = store()
    local rows, enough = {}, false
    for _, h in pairs(n.stock or {}) do
      local now = h.force == f.name and h.samples[#h.samples]
      local old
      for i = #h.samples - 1, 1, -1 do
        if now and now.tick - h.samples[i].tick >= STOCK_LOOK then old = h.samples[i]; break end
      end
      if old then
        enough = true
        local dt = now.tick - old.tick
        for name, before in pairs(old.counts) do
          local left = now.counts[name] or 0
          if left > 0 and left < before then
            local ticks = left / ((before - left) / dt)
            if ticks <= STOCK_HORIZON then rows[#rows+1] = {name=name, id=h.id, surface=h.surface, ticks=ticks, left=left} end
          end
        end
      end
    end
    table.sort(rows, function(a, b) return a.ticks < b.ticks or (a.ticks == b.ticks and a.name < b.name) end)
    while max and #rows > max do table.remove(rows) end
    return rows, enough
  end
  -- task-statuscost: the requests are looked at every 30 s (unfilled for 60 s,
  -- no idle robot for 10 min); the poles are mapped again by map_step, a walk
  -- spread over each VIEW_TICKS (at once only when there is no map yet).
  function M.tick(tick)
    M.view_tick(tick)
    local n = store()
    local ok, err = pcall(map_step, n, tick)
    if not ok then
      n.map_job = nil
      n.map_errors = {count=((n.map_errors or {}).count or 0) + 1, last=tostring(err), tick=tick}
      n.map_tick = tick   -- the last map is kept another VIEW_TICKS
    end
    if tick % SAMPLE ~= 0 then return end
    if not n.map_tick then map_poles(n) end
    if not n.watch_tick or tick - n.watch_tick >= WATCH_TICKS then watch_logistics(n); n.watch_tick = tick end
    if not n.stock_tick or tick - n.stock_tick >= STOCK_EVERY then pcall(sample_stock, n); n.stock_tick = tick end
    sample(n)
  end

  local function mw(kw)
    if kw >= 1000 then return string.format('%.1f MW', kw / 1000) end
    return string.format('%d kW', math.floor(kw + 0.5))
  end
  local function at(x, y) return string.format('(%d,%d)', math.floor(x + 0.5), math.floor(y + 0.5)) end
  -- Joules as MJ (one decimal under 100 MJ), GJ from 1000 MJ.
  local function mj(j)
    local m = j / 1e6
    if m >= 1000 then return string.format('%.1f GJ', m / 1000) end
    if m >= 100 then return string.format('%d MJ', math.floor(m + 0.5)) end
    return string.format('%.1f MJ', m)
  end
  -- '17s', '4m50s'.
  local function span(sec)
    sec = math.max(0, math.floor(sec + 0.5))
    return sec >= 60 and string.format('%dm%02ds', math.floor(sec / 60), sec % 60) or sec .. 's'
  end
  -- The accumulators' net flow out of a network (kW; below 0: they charge), averaged over the samples of the last
  -- ACC_LOOK ticks; nil with fewer than ACC_MIN_SAMPLES of them.
  local function acc_flow(n, id)
    local list = n.samples[id] or {}
    local sum, k = 0, 0
    for i = #list, 1, -1 do
      local x = list[i]
      if x.tick <= game.tick - ACC_LOOK then break end
      if x.acc then sum, k = sum + x.acc, k + 1 end
    end
    if k < ACC_MIN_SAMPLES then return nil end
    return sum / k
  end
  -- What a network row's accumulators hold now (J), read from them (scaled up when the row keeps fewer than it has);
  -- the view's sum when it kept none.
  local function acc_stored(r)
    local list = r.accs
    if not list or #list == 0 then return r.acc_j end
    local j, k = 0, 0
    for _, e in ipairs(list) do
      if e.valid then j, k = j + e.energy, k + 1 end
    end
    if k == 0 then return r.acc_j end
    return k < r.acc and j * r.acc / k or j
  end
  M.acc_flow, M.acc_stored = acc_flow, acc_stored
  -- The accumulator part of an electric row's line: how many, what they hold now of their maximum, and the trend over
  -- the last ACC_LOOK ticks with the time to empty at that rate. The view writes it, and a read writes it again from
  -- what they hold at the read.
  local function acc_part(n, id, count, j, buf)
    local flow = acc_flow(n, id)
    local trend = ''
    if flow and flow > 1 then
      trend = string.format(', falling %s net over the last %d s: empty in about %s at that rate', mw(flow), ACC_LOOK / 60, span(j / (flow * 1000)))
    elseif flow and flow < -1 then trend = string.format(', rising %s net over the last %d s', mw(-flow), ACC_LOOK / 60) end
    return string.format('accumulators %d at %d%% (%s of %s)%s', count, buf > 0 and math.floor(100 * j / buf + 0.5) or 0, mj(j), mj(buf), trend)
  end
  -- What a network's accumulators held at its samples: one value every 15 s over the last 3 min, oldest first.
  local function acc_series(n, id)
    local list = n.samples[id] or {}
    local out, last = {}, nil
    for _, x in ipairs(list) do
      if x.acc_j and x.acc_buf and x.acc_buf > 0 and x.tick > game.tick - 10800 and (not last or x.tick - last >= 900) then
        out[#out+1] = math.floor(100 * x.acc_j / x.acc_buf + 0.5) .. '%'
        last = x.tick
      end
    end
    return #out >= 2 and out or nil
  end
  -- The draw over the window: average, now (last sample), and by producer name (averages).
  local function draw(n, id)
    local list = n.samples[id] or {}
    if #list == 0 then return nil end
    local sum, by = 0, {}
    for _, s in ipairs(list) do
      sum = sum + s.kw
      for name, kw in pairs(s.by) do by[name] = (by[name] or 0) + kw end
    end
    for name, kw in pairs(by) do by[name] = kw / #list end
    return {avg=sum / #list, now=list[#list].kw, by=by, samples=#list, span_s=math.min(WINDOW / 60, math.floor((list[#list].tick - list[1].tick) / 60) + 5)}
  end
  local function max_output(e)
    local q = try(function() return e.quality end)
    local proto = e.prototype
    return try(function() return proto.get_max_power_output(q) end) or try(function() return proto.get_max_energy_production(q) end) or 0
  end
  -- The solar power where a surface is, in percent (100 is a solar panel's nameplate output; Astra, 13:10): a planet's
  -- solar-power property against its default; on a platform, the solar power in space of the location it stops at,
  -- or, flying, of the two ends of its connection weighted by how far along it is (pl.distance, from the connection's
  -- own first end). Times the surface's solar_power_multiplier (1 unless a script changed it). {percent, text, platform}.
  local function pct(v) return math.floor(v + 0.5) end
  function M.solar(surface)
    local mult = try(function() return surface.solar_power_multiplier end) or 1
    local def = try(function() return prototypes.surface_property['solar-power'].default_value end) or 100
    if def <= 0 then def = 100 end
    local pl = try(function() return surface.platform end)
    if pl then
      local loc = try(function() return pl.space_location end)
      local here = loc and try(function() return loc.solar_power_in_space end)
      if here then
        local v = here / def * 100 * mult
        return {percent=v, platform=pl.name, text=string.format('solar power %d%% at %s', pct(v), loc.name)}
      end
      local c = try(function() return pl.space_connection end)
      local a, b = c and try(function() return c.from.solar_power_in_space end), c and try(function() return c.to.solar_power_in_space end)
      if a and b then
        local d = try(function() return pl.distance end) or 0
        local v = (a * (1 - d) + b * d) / def * 100 * mult
        return {percent=v, platform=pl.name, text=string.format('solar power %d%% between %s (%d%%) and %s (%d%%), %d%% of the way from %s',
          pct(v), c.from.name, pct(a / def * 100 * mult), c.to.name, pct(b / def * 100 * mult), pct(d * 100), c.from.name)}
      end
    end
    local prop = try(function() return surface.get_property('solar-power') end)
    if prop then
      local v = prop / def * 100 * mult
      return {percent=v, platform=pl and pl.name or nil, text=string.format('solar power %d%%', pct(v))}
    end
    return {percent=100 * mult, platform=pl and pl.name or nil, text=string.format('solar power %d%% (no solar property read)', pct(100 * mult))}
  end
  -- A surface by its name for people: a platform's name, else the surface's.
  local function label(surface)
    local pl = try(function() return surface.platform end)
    return pl and pl.name or surface.name
  end
  M.label = label
  local solar_cache = {}
  local function solar_peak(e)
    local v = try(function() return e.prototype.get_max_energy_production(e.quality) end) or 0
    local index = try(function() return e.surface.index end) or 0
    local s = solar_cache[index]
    if not s or s.tick ~= game.tick then s = {tick=game.tick, scale=M.solar(e.surface).percent / 100}; solar_cache[index] = s end
    return v * s.scale
  end
  local function fuel_energy(e)
    local burner = try(function() return e.burner end)
    if not burner then return nil end
    local j = try(function() return burner.remaining_burning_fuel end) or 0
    local inv = try(function() return burner.inventory end)
    for i = 1, inv and #inv or 0 do
      local st = inv[i]
      if st and st.valid_for_read then j = j + st.count * (try(function() return st.prototype.fuel_value end) or 0) end
    end
    local eff = try(function() return e.prototype.burner_prototype.effectivity end) or 1
    return j * eff
  end
  local function segment(e, i) return try(function() return e.fluidbox.get_fluid_segment_id(i) end) end

  -- One surface's electric networks: rows with the numbers and the line.
  -- A surface's electric networks in four steps (one a tick in the background
  -- view: task-statuscost, 01:15 on world n: networks.alert_groups 55 ms when
  -- one call rebuilt the view): the generators, the machines, the boilers,
  -- the rows. Between steps ctx holds plain data and entities, linked by id.
  local function new_net(id, poles, cx, cy)
    return {id=id, poles=poles, center={x=cx, y=cy}, cap_kw=0, solar_peak_kw=0, solar=0,
      acc=0, acc_j=0, acc_buf=0, machines=0, low=0, none=0, powerless={names={}, by={}, at={}}, boilers={}, gens=0}
  end
  local function e_ctx(n, f, surface)
    -- A platform (Astra, 14:05: Starling's network 475, 5 solar panels and assemblers on low power, was not found): its
    -- poles are found at once each view (a platform is small), so the pole map has them and their statistics are
    -- sampled; and a network seen on a generator or machine with no pole mapped gets a row of its own (on_entity).
    local plat = try(function() return surface.platform end)
    if plat then
      local pm = {}
      for _, e in ipairs(try(function() return surface.find_entities_filtered{type='electric-pole', force=f, limit=MAX_SCAN} end) or {}) do pole_into(pm, e, surface, f) end
      for id, m in pairs(n.map) do if m.surface == surface.name and m.force == f.name and not pm[id] then n.map[id] = nil end end
      for id, m in pairs(pm) do n.map[id] = m end
    end
    local nets = {}
    for id, m in pairs(n.map) do
      if m.surface == surface.name and m.force == f.name then nets[id] = new_net(id, m.poles, m.sx / m.poles, m.sy / m.poles) end
    end
    return {nets=nets, seg_net={}, steam={}, platform=plat and true or nil}
  end
  -- The network of an entity; on a platform one with no pole mapped is made from the entity.
  local function on_entity(ctx, e)
    local id = e.valid and try(function() return e.electric_network_id end)
    if not id then return nil end
    local net = ctx.nets[id]
    if not net and ctx.platform then net = new_net(id, 0, e.position.x, e.position.y); ctx.nets[id] = net end
    return net
  end
  -- One generator, solar panel or accumulator into its network.
  local function e_gen(ctx, e)
    local net = on_entity(ctx, e)
    if net then
      net.gens = net.gens + 1
      if e.type == 'solar-panel' then net.solar = net.solar + 1; net.solar_peak_kw = net.solar_peak_kw + solar_peak(e) * 60 / 1000
      elseif e.type == 'accumulator' then
        net.acc = net.acc + 1
        net.acc_j = net.acc_j + (try(function() return e.energy end) or 0)
        net.acc_buf = net.acc_buf + (try(function() return e.electric_buffer_size end) or 0)
        net.accs = net.accs or {}
        if #net.accs < ACC_READ then net.accs[#net.accs+1] = e end
      elseif e.type ~= 'electric-energy-interface' then
        net.cap_kw = net.cap_kw + max_output(e) * 60 / 1000
        if e.type == 'generator' then
          local sid = segment(e, 1)
          if sid then ctx.seg_net[sid] = {id=net.id, gen=e.name} end
          ctx.steam[#ctx.steam+1] = {id=net.id, gen=e.name, x=e.position.x, y=e.position.y}
        end
      end
    end
  end
  local function e_begin(n, f, surface)
    local ctx = e_ctx(n, f, surface)
    for _, e in ipairs(try(function() return surface.find_entities_filtered{type=GENERATORS, force=f, limit=MAX_SCAN} end) or {}) do e_gen(ctx, e) end
    return ctx
  end
  -- One machine into its network.
  local function e_machine(ctx, e)
    local net = on_entity(ctx, e)
    if net then
      local st = defines.entity_status or {}
      net.machines = net.machines + 1
      if e.status == st.low_power then net.low = net.low + 1 elseif e.status == st.no_power then
        net.none = net.none + 1
        local g = net.powerless
        g.names[e.name] = (g.names[e.name] or 0) + 1
        local who = try(function() return e.last_user.name end)
        if who then g.by[who] = (g.by[who] or 0) + 1 end
        if #g.at < 8 then g.at[#g.at+1] = {x=e.position.x, y=e.position.y} end
      end
    end
  end
  local function e_machines(ctx, f, surface)
    for _, e in ipairs(try(function() return surface.find_entities_filtered{type=MACHINES, force=f, limit=MAX_SCAN} end) or {}) do e_machine(ctx, e) end
  end
  -- One boiler to its network: the generators whose steam it shares (its
  -- output's fluid segment), else the nearest generator within NEAR_BOILER
  -- tiles. The generators must all be read first.
  local function e_boiler(ctx, e)
    local j = e.valid and fuel_energy(e)
    if j then
      local sid = segment(e, try(function() return #e.fluidbox end) or 2)
      local to = sid and ctx.seg_net[sid]
      if not to then
        local best = NEAR_BOILER * NEAR_BOILER
        for _, g in ipairs(ctx.steam) do
          local d = (g.x - e.position.x) ^ 2 + (g.y - e.position.y) ^ 2
          if d <= best then best, to = d, g end
        end
      end
      local net = to and ctx.nets[to.id]
      if net then net.boilers[#net.boilers+1] = {e=e, j=j, gen=to.gen} end
    end
  end
  local function e_boilers(ctx, f, surface)
    for _, e in ipairs(try(function() return surface.find_entities_filtered{type='boiler', force=f, limit=MAX_SCAN} end) or {}) do e_boiler(ctx, e) end
  end
  -- A burner's fuel by name: what it burns now, else its first fuel stack; nil when none.
  local function burner_fuel(e)
    local burner = try(function() return e.burner end)
    if not burner then return nil end
    local cur = try(function() return burner.currently_burning end)
    local name = cur and (try(function() return type(cur.name) == 'string' and cur.name or cur.name.name end))
    if name then return name end
    local inv = try(function() return burner.inventory end)
    for i = 1, inv and #inv or 0 do
      local st = inv[i]
      if st and st.valid_for_read then return st.name end
    end
    return nil
  end
  local function e_rows(ctx, n, surface, f)
    local nets = ctx.nets
    local rows = {}
    for _, net in pairs(nets) do
      -- (on a platform every network with a machine or a pole: a platform is small and Astra's Starling had 1)
      if net.poles > 2 or net.gens > 0 or net.none > 0 or (ctx.platform and (net.machines > 0 or net.poles > 0)) then
        local d = draw(n, net.id)
        net.draw = d
        local solar_now = d and d.by['solar-panel'] or 0
        net.capacity_kw = net.cap_kw + solar_now
        -- A platform (Astra, 13:10): no night in space, so its panels make their output at the solar power where it
        -- is; that counts in its capacity (their output now is what the network draws of them).
        local plat = try(function() return surface.platform end)
        local sun = (plat or net.solar > 0) and M.solar(surface) or nil
        if plat then net.platform, net.capacity_kw = plat.name, net.cap_kw + net.solar_peak_kw end
        net.solar_power, net.solar_power_text = sun and sun.percent, sun and sun.text
        -- Boilers: their fuel at the draw of the generators they feed, shared evenly.
        if #net.boilers > 0 and d then
          local fed_kw, names = 0, {}
          for _, b in ipairs(net.boilers) do names[b.gen] = true end
          for name in pairs(names) do fed_kw = fed_kw + (d.by[name] or 0) end
          local under, low = {}, {}
          if fed_kw > 0 then
            -- Each boiler's own fuel in minutes at an even share of the draw;
            -- low: under the first step and not refilled (no feeder able to
            -- bring more, M.boiler_supply: b.fed; or draining, DRAINS).
            if not ctx.supplied then M.boiler_supply(net.boilers, surface, f) end   -- (the background view reads it in slices)
            local each, own = fed_kw * 1000 / #net.boilers, 0
            net.fed = 0
            local st = store()
            st.boiler_prev = nil   -- (the running-down rule's memory, before 03:25)
            st.boiler_own = st.boiler_own or {}
            for _, b in ipairs(net.boilers) do
              b.min = b.j / each / 60
              own = own + b.j
              -- Its looks of the last OWN_TICKS, oldest first; each DRAINS row compares with the newest look that old or
              -- older, so consecutive looks say the same (one sample kept and replaced would not).
              local unit = try(function() return b.e.unit_number end)
              local hist = unit and st.boiler_own[unit] or {}
              while hist[1] and game.tick - hist[1].tick > OWN_TICKS do table.remove(hist, 1) end
              for _, rule in ipairs(DRAINS) do
                local prev
                for _, x in ipairs(hist) do if game.tick - x.tick >= rule[2] then prev = x end end
                local dt = prev and (game.tick - prev.tick) / 60
                if not b.drop and dt and prev.j - b.j >= rule[1] * each * dt then
                  b.drop = string.format('down from %d min %d s before', math.floor(prev.j / each / 60), math.floor(dt))
                end
              end
              if unit and (not hist[#hist] or hist[#hist].tick < game.tick) then
                hist[#hist+1] = {tick=game.tick, j=b.j}
                if #hist > OWN_LOOKS then table.remove(hist, 1) end
                st.boiler_own[unit] = hist
              end
              if b.fed then net.fed = net.fed + 1 end
              local refilled = b.fed and not b.drop
              if b.min < FUEL_LOW and not refilled then under[#under+1] = b.e end
              if b.min < FUEL_STEPS[1] and not refilled then low[#low+1] = b end
              if not net.lowest_min or b.min < net.lowest_min then net.lowest_min = b.min; net.lowest_b = b end
            end
            for unit, hist in pairs(st.boiler_own) do
              local last = hist[#hist]
              if not last or game.tick - last.tick > OWN_TICKS then st.boiler_own[unit] = nil end
            end
            net.fuel_min = own / (fed_kw * 1000) / 60
            net.feed_low = M.feed_chests(net.boilers, surface, f)
          end
          net.fuel_under = under
          table.sort(low, function(a, b) return a.min < b.min end)
          net.fuel_low = low
        end
        local parts = {string.format('%s electric #%d (%s near %s)', plat and plat.name .. ' (platform)' or surface.name, net.id,
          net.poles > 0 and net.poles .. ' poles' or 'no pole of ours found', at(net.center.x, net.center.y))}
        if d then
          parts[#parts+1] = string.format('draw %s avg over %s (now %s) of %s capacity%s', mw(d.avg), d.span_s >= 300 and '5 min' or d.span_s .. ' s',
            mw(d.now), mw(net.capacity_kw), net.capacity_kw > 0 and string.format(' (%d%%)', math.floor(100 * d.avg / net.capacity_kw + 0.5)) or '')
        elseif net.poles == 0 then
          parts[#parts+1] = string.format('capacity %s; no draw figures (the game gives a network\'s statistics through its poles)', mw(net.capacity_kw))
        else parts[#parts+1] = string.format('capacity %s; no draw sample yet', mw(net.capacity_kw)) end
        if plat then
          parts[#parts+1] = net.solar > 0 and string.format('solar %d panels, %s now, %s at this solar power (%s)', net.solar, mw(solar_now), mw(net.solar_peak_kw), sun.text)
            or string.format('no solar panels (%s)', sun.text)
        elseif net.solar > 0 then parts[#parts+1] = string.format('solar %d panels, %s now, %s peak', net.solar, mw(solar_now), mw(net.solar_peak_kw)) end
        -- Stored energy against the maximum (Gemini, 07:55, Fulgora: lightning charges the accumulators), read now,
        -- and its trend over the last ACC_LOOK ticks: the time to empty at that rate (Gemini, 15:10).
        if net.acc > 0 then
          net.acc_j = acc_stored(net) or net.acc_j
          parts[#parts+1] = acc_part(n, net.id, net.acc, net.acc_j, net.acc_buf)
          -- (the samples read these accumulators from now on)
          n.acc_refs = n.acc_refs or {}
          n.acc_refs[net.id] = net.accs
        end
        parts[#parts+1] = string.format('machines %d: %d low power, %d no power', net.machines, net.low, net.none)
        if #net.boilers > 0 then
          parts[#parts+1] = string.format('boilers %d: their own fuel %s at this draw%s%s', #net.boilers,
            net.fuel_min and string.format('%d min', math.floor(net.fuel_min)) or 'n/a (no draw)',
            net.fed and string.format(', %d with fuel at their feeders', net.fed) or '',
            net.fuel_low and #net.fuel_low > 0 and string.format(', %d under %d min not refilled (lowest %d min)', #net.fuel_low, FUEL_STEPS[1],
              math.floor(net.fuel_low[1].min)) or '')
          -- The lowest boiler named (Haiku, 07:55): where, its minutes of which fuel, and its feeder; the lowest of those
          -- not refilled when there are any (the under-20-min count's), else the lowest of all.
          if net.fuel_low and net.fuel_low[1] then net.lowest_b = net.fuel_low[1] end
          local lb = net.lowest_b
          if lb and lb.e.valid then
            net.lowest_text = string.format('lowest boiler %s: %d min of %s; %s', at(lb.e.position.x, lb.e.position.y), math.floor(lb.min),
              burner_fuel(lb.e) or 'no fuel', lb.feeder or 'no inserter feeds it')
            parts[#parts+1] = net.lowest_text
          end
          -- Feed chests (Haiku, 12:20): each chest the boilers' feeders take from, its fuel and rate over the last 10 min;
          -- the 2 with the fewest minutes left at that rate (falling ones first) on the line, all in net.feed_rates.
          local seen, rates = {}, {}
          for _, b in ipairs(net.boilers) do
            local c = b.chest
            local unit = c and c.e.valid and try(function() return c.e.unit_number end)
            if unit and not seen[unit] then
              seen[unit] = true
              local r = M.feed_rate(c.e, c.count)
              rates[#rates+1] = {chest=c.e.name, position={x=c.e.position.x, y=c.e.position.y}, count=c.count, held=c.held or 'no fuel',
                per_min=r and r.per_min, minutes_left=r and r.minutes_left, rate=r and r.text or 'rate not measured yet'}
            end
          end
          table.sort(rates, function(x, y)
            local lx, ly = x.minutes_left or math.huge, y.minutes_left or math.huge
            if lx ~= ly then return lx < ly end
            return x.count < y.count
          end)
          net.feed_rates = #rates > 0 and rates or nil
          if #rates > 0 then
            local shown = {}
            for i = 1, math.min(2, #rates) do
              local x = rates[i]
              shown[i] = string.format('%s %s %s, %s', x.chest, at(x.position.x, x.position.y), x.held, x.rate)
            end
            parts[#parts+1] = 'feed chests: ' .. table.concat(shown, '; ') .. (#rates > 2 and string.format(' (+%d more)', #rates - 2) or '')
          end
        end
        net.line = table.remove(parts, 1) .. ': ' .. table.concat(parts, '; ')
        rows[#rows+1] = net
      end
    end
    table.sort(rows, function(a, b) return a.poles > b.poles or (a.poles == b.poles and a.id < b.id) end)
    return rows
  end
  local function electric(n, f, surface)
    local ctx = e_begin(n, f, surface)
    e_machines(ctx, f, surface); e_boilers(ctx, f, surface)
    return e_rows(ctx, n, surface, f)
  end

  local function top_items(map, k)
    local list = {}
    for name, v in pairs(map) do list[#list+1] = {name=name, v=v} end
    table.sort(list, function(a, b) return a.v > b.v or (a.v == b.v and a.name < b.name) end)
    local out = {}
    for i = 1, math.min(k, #list) do out[i] = list[i].name .. ' ' .. math.floor(list[i].v) end
    return table.concat(out, ', '), #list
  end
  -- A logistic network as its GUI shows it (Luna, 22:53: a coverage gap told
  -- apart from a busy fleet): roboports (and personal roboports), the areas
  -- they cover (bounding boxes of the roboports' squares), and per robot kind
  -- the total, idle (stationed in a roboport), charging and waiting to charge
  -- at a roboport, and working (the rest: out on a job or flying).
  local function box_add(box, x, y, r)
    if not box then return {x0=x - r, y0=y - r, x1=x + r, y1=y + r} end
    box.x0, box.y0, box.x1, box.y1 = math.min(box.x0, x - r), math.min(box.y0, y - r), math.max(box.x1, x + r), math.max(box.y1, y + r)
    return box
  end
  local function box_text(b) return b and string.format('(%d,%d)-(%d,%d)', math.floor(b.x0), math.floor(b.y0), math.ceil(b.x1), math.ceil(b.y1)) or 'none' end
  local KINDS = {['logistic-robot']='logistic', ['construction-robot']='construction'}
  -- Charging and waiting robots of one cell by kind; nil when the cell does not list them.
  local function cell_robots(c)
    local out = {charging={logistic=0, construction=0}, waiting={logistic=0, construction=0}}
    for key, field in pairs({charging='charging_robots', waiting='to_charge_robots'}) do
      local list = try(function() return c[field] end)
      if type(list) ~= 'table' then return nil end
      for _, r in ipairs(list) do
        local k = KINDS[try(function() return r.type end) or '']
        if k then out[key][k] = out[key][k] + 1 end
      end
    end
    return out
  end
  local function robots_text(kind, k)
    local t = string.format('%s robots %d: %d idle, %d working', kind, k.total, k.idle, k.working)
    if k.charging then t = t .. string.format(', %d charging, %d waiting to charge', k.charging, k.waiting) end
    return t
  end
  function M.logistic_view(ln)
    local v = {id=try(function() return ln.network_id end), roboports=0, personal=0,
      logistic={total=try(function() return ln.all_logistic_robots end) or 0, idle=try(function() return ln.available_logistic_robots end) or 0, charging=0, waiting=0},
      construction={total=try(function() return ln.all_construction_robots end) or 0, idle=try(function() return ln.available_construction_robots end) or 0, charging=0, waiting=0}}
    local typed, any_charging, any_waiting = true, 0, 0
    for _, c in ipairs(try(function() return ln.cells end) or {}) do
      any_charging = any_charging + (try(function() return c.charging_robot_count end) or 0)
      any_waiting = any_waiting + (try(function() return c.to_charge_robot_count end) or 0)
      local by = cell_robots(c)
      if by then
        for _, k in ipairs({'logistic', 'construction'}) do
          v[k].charging, v[k].waiting = v[k].charging + by.charging[k], v[k].waiting + by.waiting[k]
        end
      else typed = false end
      local o = try(function() return c.owner end)
      if try(function() return c.mobile end) then v.personal = v.personal + 1
      elseif o and o.valid then
        v.roboports = v.roboports + 1
        v.center = v.center or {x=o.position.x, y=o.position.y}
        v.logistic_area = box_add(v.logistic_area, o.position.x, o.position.y, try(function() return c.logistic_radius end) or 0)
        v.construction_area = box_add(v.construction_area, o.position.x, o.position.y, try(function() return c.construction_radius end) or 0)
      end
    end
    for _, k in ipairs({'logistic', 'construction'}) do
      local r = v[k]
      if not typed then r.charging, r.waiting = nil, nil end
      r.working = math.max(0, r.total - r.idle - (r.charging or 0) - (r.waiting or 0))
    end
    if not typed then v.charging, v.waiting = any_charging, any_waiting end
    v.text = string.format('%d roboport%s%s, logistic area %s, construction area %s; %s; %s%s', v.roboports, v.roboports == 1 and '' or 's',
      v.personal > 0 and string.format(' (+%d personal)', v.personal) or '', box_text(v.logistic_area), box_text(v.construction_area),
      robots_text('logistic', v.logistic), robots_text('construction', v.construction),
      not typed and string.format('; %d robots charging, %d waiting to charge', any_charging, any_waiting) or '')
    return v
  end
  -- A logistic chest is in a logistic network only inside a roboport's
  -- logistic area (Sonnet, shift10: 8 chests with 31k copper sat outside
  -- roboport range for hours). 2.0.77 on a private server: the area is a
  -- square, its edges in (25.00 tiles from a roboport in, 25.01 out), and an
  -- unpowered roboport has one too. pos: the chest's position; planned:
  -- {{x, y, r}} roboports planned in the same call. nil when a roboport (built,
  -- a ghost, or planned) covers it; else the line, with the nearest roboport.
  local COVER_SEARCH = 200
  function M.coverage(surface, force, pos, planned)
    local best, bd
    local function near(x, y, r, label)
      local dx, dy = math.abs(pos.x-x)-r, math.abs(pos.y-y)-r
      if dx <= 0 and dy <= 0 then return true end
      local d = (math.max(dx, 0)^2+math.max(dy, 0)^2)^0.5
      if not bd or d < bd then best, bd = label, d end
    end
    for _, r in ipairs(planned or {}) do
      if near(r.x, r.y, r.r, string.format('roboport (%g,%g), planned', r.x, r.y)) then return nil end
    end
    for _, e in ipairs(try(function() return surface.find_entities_filtered{type='roboport', force=force, position=pos, radius=COVER_SEARCH} end) or {}) do
      local r = try(function() return e.logistic_cell.logistic_radius end) or try(function() return e.prototype.logistic_radius end) or 0
      if e.valid and near(e.position.x, e.position.y, r, string.format('%s (%g,%g)', e.name, e.position.x, e.position.y)) then return nil end
    end
    for _, g in ipairs(try(function() return surface.find_entities_filtered{ghost_type='roboport', force=force, position=pos, radius=COVER_SEARCH} end) or {}) do
      local r = try(function() return g.ghost_prototype.logistic_radius end) or 0
      if g.valid and near(g.position.x, g.position.y, r, string.format('roboport ghost (%g,%g)', g.position.x, g.position.y)) then return nil end
    end
    if not best then return string.format('outside logistic coverage: no roboport of ours within %d tiles', COVER_SEARCH) end
    return string.format('outside logistic coverage: nearest %s, %g tiles from its area', best, math.floor(bd*10+0.5)/10)
  end
  -- What inspect shows on a roboport or a logistic chest: its network (or that
  -- it has none) and, for a roboport, its own cell.
  function M.of_entity(e)
    local ln = try(function() return e.logistic_network end)
    local cell = e.type == 'roboport' and try(function() return e.logistic_cell end)
    ln = ln or (cell and try(function() return cell.logistic_network end))
    local out
    if ln then
      local v = M.logistic_view(ln)
      out = {id=v.id, roboports=v.roboports, personal=v.personal > 0 and v.personal or nil, logistic_area=v.logistic_area,
        construction_area=v.construction_area, logistic_robots=v.logistic, construction_robots=v.construction,
        charging=v.charging, waiting=v.waiting, line=string.format('logistic #%s: %s', tostring(v.id), v.text)}
    else
      out = {none=e.type == 'roboport' and 'this roboport is in no logistic network'
        or 'in no logistic network: no roboport\'s logistic area covers it'}
    end
    if cell then
      local x, y = e.position.x, e.position.y
      local lr, cr = try(function() return cell.logistic_radius end) or 0, try(function() return cell.construction_radius end) or 0
      local by = cell_robots(cell)
      out.port = {logistic_area=box_add(nil, x, y, lr), construction_area=box_add(nil, x, y, cr),
        stationed={logistic=try(function() return cell.stationed_logistic_robot_count end) or 0,
          construction=try(function() return cell.stationed_construction_robot_count end) or 0},
        charging=try(function() return cell.charging_robot_count end) or 0, waiting=try(function() return cell.to_charge_robot_count end) or 0,
        charging_by_kind=by and by.charging or nil, waiting_by_kind=by and by.waiting or nil}
      local function split(t) return t and string.format(' (%d logistic, %d construction)', t.logistic, t.construction) or '' end
      out.port.line = string.format('this roboport: logistic area %s, construction area %s; stationed: %d logistic, %d construction robots; %d charging%s, %d waiting to charge%s',
        box_text(out.port.logistic_area), box_text(out.port.construction_area), out.port.stationed.logistic, out.port.stationed.construction,
        out.port.charging, split(out.port.charging_by_kind), out.port.waiting, split(out.port.waiting_by_kind))
    end
    return out
  end
  -- Robot delays (Nick 12:35: world n had 1 construction robot against 325 logistic robots while Astra's 75-entity
  -- layout waited as ghosts). Construction backlog: the ghosts, deconstruction and upgrade orders in a network's
  -- construction area (its bounding box; at most MAX_GHOSTS), each remembered with the tick a view first saw it
  -- (n.orders per force, kept while seen), so the wait is from then; the cause of the oldest waits (up to CAUSE_LOOK):
  -- outside every roboport's construction area, no construction robots, items missing in this network (and where
  -- another network holds them), all robots busy (jobs per robot), else not seen. Deliveries: requests unfilled for
  -- 5+ min while providers or storage hold the item free (the engine's supply counts, net of pickups robots have
  -- reserved), with what the robots are doing.
  local ORDER_WAIT, CAUSE_LOOK = 18000, 16
  local function order_key(e)
    local u = try(function() return e.unit_number end)
    return u and tostring(u) or (e.name .. '@' .. e.position.x .. ',' .. e.position.y)
  end
  local function order_item(e, kind)
    local proto = kind == 'ghost' and try(function() return e.ghost_prototype end)
      or kind == 'upgrade' and try(function() return e.get_upgrade_target() end) or nil
    local items = proto and try(function() return proto.items_to_place_this end)
    local first = items and items[1]
    return first and (type(first) == 'string' and first or first.name) or nil
  end
  local function plural(n, word) return n .. ' ' .. word .. (n == 1 and '' or 's') end
  -- The finds of one network's orders: {kind, filter}; the background view makes one a step.
  local function order_finds(f, b)
    local area = {{b.x0, b.y0}, {b.x1, b.y1}}
    return {{kind='ghost', q={area=area, type='entity-ghost', force=f, limit=MAX_GHOSTS}},
      {kind='deconstruct', q={area=area, to_be_deconstructed=true, limit=MAX_GHOSTS}},
      {kind='upgrade', q={area=area, to_be_upgraded=true, force=f, limit=MAX_GHOSTS}}}
  end
  -- found: {ghost=list, deconstruct=list, upgrade=list} from those finds (nil: made here).
  local function backlog(n, ln, f, surface, b, v, others, found)
    if not found then
      found = {}
      for _, x in ipairs(order_finds(f, b)) do found[x.kind] = try(function() return surface.find_entities_filtered(x.q) end) or {} end
    end
    local seen, next_seen = n.orders[f.name] or {}, n.orders_next[f.name]
    local list, counts = {}, {ghost=0, deconstruct=0, upgrade=0}
    local function take(kind, found)
      for _, e in ipairs(found or {}) do
        if e.valid and #list < MAX_GHOSTS then
          local k = order_key(e)
          local first = seen[k] or game.tick
          next_seen[k] = first
          counts[kind] = counts[kind] + 1
          list[#list+1] = {e=e, kind=kind, first=first}
        end
      end
    end
    take('ghost', found.ghost); take('deconstruct', found.deconstruct); take('upgrade', found.upgrade)
    table.sort(list, function(x, y) return x.first < y.first end)
    local waited, waited_ghosts = 0, 0
    for _, o in ipairs(list) do
      if game.tick - o.first >= ORDER_WAIT then waited = waited + 1; if o.kind == 'ghost' then waited_ghosts = waited_ghosts + 1 end end
    end
    local R = v.construction
    local out = {ghosts=counts.ghost, deconstruct=counts.deconstruct, upgrade=counts.upgrade, total=#list, waited=waited,
      waited_ghosts=waited_ghosts, oldest_min=#list > 0 and math.floor((game.tick - list[1].first) / 3600) or nil,
      robots=R.total, idle=R.idle, capped=#list >= MAX_GHOSTS or nil}
    if waited == 0 then return out end
    local look = {}
    for i = 1, math.min(CAUSE_LOOK, waited) do look[i] = list[i] end
    local cells = try(function() return ln.cells end) or {}
    local inside = 0
    for _, o in ipairs(look) do
      for _, c in ipairs(cells) do
        if try(function() return c.is_in_construction_range(o.e.position) end) then inside = inside + 1; break end
      end
    end
    local missing, missing_set, present = {}, {}, 0
    for _, o in ipairs(look) do
      local item = o.kind ~= 'deconstruct' and o.e.valid and order_item(o.e, o.kind)
      if item then
        if (try(function() return ln.get_item_count(item) end) or 0) > 0 then present = present + 1
        elseif not missing_set[item] then missing_set[item] = true; missing[#missing+1] = item end
      end
    end
    -- (the items present: every item the oldest orders need is in the network, and they lie in its construction area)
    out.items_present = #missing == 0 and present > 0 and inside > 0
    if inside == 0 then out.cause = 'outside every roboport construction area'
    elseif R.total == 0 then out.cause = 'no construction robots'
    elseif #missing > 0 then
      local parts = {}
      for i = 1, math.min(4, #missing) do
        local item, where = missing[i], 'in no other network'
        for _, o in ipairs(others) do
          if o.id ~= v.id and (try(function() return o.ln.get_item_count(item) end) or 0) > 0 then
            where = string.format('held in network #%d near (%d,%d)%s', o.id, o.x, o.y, o.surface ~= surface.name and ' on ' .. o.surface or '')
            break
          end
        end
        parts[#parts+1] = item .. ' (' .. where .. ')'
      end
      out.cause = 'items missing in this network: ' .. table.concat(parts, ', ')
    elseif R.idle == 0 then
      out.cause = string.format('all %s busy (%d jobs per robot)', plural(R.total, 'construction robot'), math.ceil(#list / math.max(1, R.total)))
    else
      out.cause = string.format('not seen: %d idle construction robots and the items in the network', R.idle)
    end
    return out
  end
  local function backlog_text(k)
    if not k or k.total == 0 then return 'construction backlog: none' end
    return string.format('construction backlog: %s, %d to deconstruct, %d to upgrade%s; %d waited 5+ min, oldest %d min%s',
      plural(k.ghosts, 'ghost'), k.deconstruct, k.upgrade, k.capped and ' (counted up to ' .. MAX_GHOSTS .. ')' or '', k.waited,
      k.oldest_min or 0, k.cause and '; cause: ' .. k.cause or '')
  end
  local DELIVERY_WAIT = 18000
  -- Requester chests with every slot taken while a request of theirs has been short 60+ s (Sol, 22:08: (48.5,34.5)
  -- on Gleba, 48 slots, 494 spoilage among them; robots could not deliver bioflux). At most FULL_LOOK looked at.
  local FULL_LOOK, FULL_SHOW = 32, 3
  local function full_requesters(n, short)
    local out, seen, looked = {}, {}, 0
    for _, x in ipairs(short) do
      local since = n.unfilled[x.key]
      local e = x.e
      if since and game.tick - since >= UNFILLED_TICKS and e and looked < FULL_LOOK and not seen[x.key:match('^[^|]+')] then
        seen[x.key:match('^[^|]+')] = true
        looked = looked + 1
        local ok, f = pcall(slots.full_of, e, x.name)
        if ok and f and e.valid then
          out[#out+1] = {e=e, item=x.name, text=f.text, spoilage=f.spoilage}
        end
      end
    end
    return #out > 0 and out or nil
  end
  local function deliveries(n, ln, v, short)
    local stuck, items = 0, {}
    for _, x in ipairs(short) do
      local since = n.unfilled[x.key]
      if since and game.tick - since >= DELIVERY_WAIT then
        local s = try(function() return ln.get_supply_counts(x.name) end) or {}
        local free = math.max(0, (s['active-provider'] or 0) + (s['passive-provider'] or 0)) + math.max(0, s.storage or 0)
        if free > 0 then stuck = stuck + 1; items[x.name] = free end
      end
    end
    if stuck == 0 then return nil end
    local L, causes = v.logistic, {}
    local waiting, ports, charging = 0, 0, 0
    for _, c in ipairs(try(function() return ln.cells end) or {}) do
      local w = try(function() return c.to_charge_robot_count end) or 0
      charging = charging + (try(function() return c.charging_robot_count end) or 0)
      if w > 0 then waiting, ports = waiting + w, ports + 1 end
    end
    -- (charging and waiting robots by kind where the cells list them, else every robot at the roboports)
    if L.charging then charging, waiting = L.charging, L.waiting end
    local carrying = math.max(0, L.total - L.idle - charging - waiting)
    if L.total == 0 then causes[#causes+1] = 'no logistic robots'
    elseif L.idle == 0 then causes[#causes+1] = 'no idle logistic robots' end
    if waiting > 0 then causes[#causes+1] = string.format('%s waiting to charge at %s', plural(waiting, 'robot'), plural(ports, 'roboport')) end
    if L.total > 0 and L.idle == 0 and carrying > 0 then causes[#causes+1] = string.format('%d carrying for other requests', carrying) end
    if L.total > 0 and L.idle > 0 then causes[#causes+1] = string.format('%d idle logistic robots', L.idle) end
    local list, kinds = top_items(items, 3)
    return {stuck=stuck, items=items, cause=table.concat(causes, '; '),
      text=string.format('deliveries waiting 5+ min with the item free in the network: %d (%s free%s); %s', stuck, list, kinds > 3 and ', ...' or '',
        table.concat(causes, '; '))}
  end
  -- Every network of the force, for where a missing item is held.
  local function other_networks(f)
    local others = {}
    for _, s in ipairs(surfaces()) do
      for _, ln in ipairs(logistic_networks(f, s)) do
        local id = try(function() return ln.network_id end)
        local c = try(function() local cell = ln.cells[1]; return cell and cell.owner and cell.owner.position end)
        if id then others[#others+1] = {id=id, ln=ln, surface=s.name, x=c and math.floor(c.x + 0.5) or 0, y=c and math.floor(c.y + 0.5) or 0} end
      end
    end
    return others
  end
  local function logistic_line(surface, r)
    local items, kinds = top_items(r.items, 3)
    r.line = string.format('%s logistic #%d: %s%s; requests unfilled 60+ s: %d%s; %s%s',
      surface.name, r.id, r.view.text,
      r.busy_since and game.tick - r.busy_since >= 600 and string.format('; no idle logistic robot for %d min', math.floor((game.tick - r.busy_since) / 3600)) or '',
      r.unfilled, kinds > 0 and ' (' .. items .. (kinds > 3 and ', ...' or '') .. ' missing)' or '',
      backlog_text(r.backlog), r.deliveries and '; ' .. r.deliveries.text or '')
    local held, kinds_held = top_items(r.stock or {}, ITEMS_TOP)
    if kinds_held > 0 then r.line = r.line .. string.format('; holds %s%s', held, kinds_held > ITEMS_TOP and string.format(' (+%d kinds)', kinds_held - ITEMS_TOP) or '') end
    local asks, kinds_asked = top_items(r.asked or {}, ITEMS_TOP)
    if kinds_asked > 0 then
      local parts = {}
      for each in asks:gmatch('[^,]+') do
        local part = each:gsub('^%s+', '')
        local name = part:match('^(.-) %d+$')
        parts[#parts+1] = part .. (name and ((r.short_now or {})[name] or 0) > 0 and string.format(' (%d short)', r.short_now[name]) or '')
      end
      r.line = r.line .. string.format('; requesters ask %s%s', table.concat(parts, ', '), kinds_asked > ITEMS_TOP and string.format(' (+%d kinds)', kinds_asked - ITEMS_TOP) or '')
    end
  end
  local function orders_store(n, f)
    n.orders = n.orders or {}
    n.orders_next = n.orders_next or {}
    n.orders_next[f.name] = n.orders_next[f.name] or {}
  end
  -- The backlog of rows the background view deferred (their finds made one a step): found_by[id][kind] = list.
  local function finish_orders(n, f, surface, rows, found_by)
    orders_store(n, f)
    local others = other_networks(f)
    for _, r in ipairs(rows) do
      if r.orders_area then
        local ln
        for _, o in ipairs(others) do if o.id == r.id then ln = o.ln end end
        if ln then
          r.backlog = backlog(n, ln, f, surface, r.orders_area, r.view, others, found_by[r.id] or {})
          r.ghosts = r.backlog.ghosts
        end
        r.orders_area = nil
        logistic_line(surface, r)
      end
    end
  end
  M.order_finds = order_finds
  -- One logistic network's row (nil: no id); its line is made by logistic_done, with every row of the surface.
  local function logistic_row(n, f, surface, ln, defer, others)
      local id = try(function() return ln.network_id end)
      if not id then return nil end
        local v = M.logistic_view(ln)
        local r = {id=id, roboports=v.roboports, personal=v.personal, center=v.center, view=v,
          logistic=v.logistic.total, logistic_idle=v.logistic.idle, construction=v.construction.total, construction_idle=v.construction.idle,
          ghosts=0, unfilled=0, items={}}
        local short, short_now = shortfalls(ln), {}
        for _, x in ipairs(short) do
          local since = n.unfilled[x.key]
          if since and game.tick - since >= UNFILLED_TICKS then r.unfilled = r.unfilled + 1; r.items[x.name] = (r.items[x.name] or 0) + x.missing end
          short_now[x.name] = (short_now[x.name] or 0) + x.missing
        end
        -- The items it holds and what its requesters ask (Gemini, 12:20): the network's contents (provider, storage and
        -- buffer chests, as its GUI lists them) and the requests summed over its requester points, with what is short now.
        local stock = {}
        for k, v in pairs(try(function() return ln.get_contents() end) or {}) do
          local name, c = type(v) == 'table' and v.name or k, type(v) == 'table' and v.count or v
          if type(name) == 'table' then name = name.name end
          if type(name) == 'string' and type(c) == 'number' and c > 0 then stock[name] = (stock[name] or 0) + c end
        end
        local asked = {}
        for _, pt in ipairs(try(function() return ln.requester_points end) or {}) do
          for _, flt in ipairs(try(function() return pt.filters end) or {}) do
            local name = type(flt.name) == 'table' and flt.name.name or flt.name
            if name and (flt.count or 0) > 0 then asked[name] = (asked[name] or 0) + flt.count end
          end
        end
        r.stock, r.asked, r.short_now = stock, asked, short_now
        r.busy_since = n.busy[id]
        local b = v.construction_area
        if b and defer then r.orders_area = b
        elseif b then
          r.backlog = backlog(n, ln, f, surface, b, v, others)
          r.ghosts = r.backlog.ghosts
        end
        r.deliveries = deliveries(n, ln, v, short)
        r.full = full_requesters(n, short)
        return r
  end
  local function logistic_done(surface, rows)
    for _, r in ipairs(rows) do logistic_line(surface, r) end
    table.sort(rows, function(a, b) return a.roboports > b.roboports or (a.roboports == b.roboports and a.id < b.id) end)
    return rows
  end
  local function logistic(n, f, surface, defer)
    local rows = {}
    orders_store(n, f)
    local others = not defer and other_networks(f) or nil
    for _, ln in ipairs(logistic_networks(f, surface)) do
      local r = logistic_row(n, f, surface, ln, defer, others)
      if r then rows[#rows+1] = r end
    end
    return logistic_done(surface, rows)
  end
  -- A view that has read every network: the orders it saw are the ones remembered (gone ones are dropped).
  local function orders_seen(n, f)
    if n.orders_next and n.orders_next[f.name] then
      n.orders = n.orders or {}
      n.orders[f.name] = n.orders_next[f.name]
      n.orders_next[f.name] = nil
    end
  end

  -- The turrets by name (by: counted already by the background view) and ammo used in the last hour.
  local function turrets(f, surface, by)
    if not by then
      by = {}
      for _, e in ipairs(try(function() return surface.find_entities_filtered{type=TURRETS, force=f, limit=MAX_SCAN} end) or {}) do
        if e.valid then by[e.name] = (by[e.name] or 0) + 1 end
      end
    end
    local used = {}
    local stats = try(function() return f.get_item_production_statistics(surface) end)
    for name in pairs(stats and try(function() return stats.output_counts end) or {}) do
      local item = prototypes.item[name]
      if item and item.type == 'ammo' then
        local v = try(function() return stats.get_flow_count{name=name, category='output', precision_index=defines.flow_precision_index.one_hour, count=true} end)
        if v and v >= 1 then used[name] = v end
      end
    end
    if not next(by) and not next(used) then return nil end
    local t = top_items(by, 8)
    local u = top_items(used, 4)
    return {by=by, used=used, line=string.format('%s turrets: %s; ammo used in the last hour: %s', surface.name, t ~= '' and t or 'none', u ~= '' and u or 'none')}
  end

  local function fresh_map(n)
    if not n.map_tick then map_poles(n); watch_logistics(n); n.watch_tick = game.tick; sample(n)
    elseif game.tick - n.map_tick >= VIEW_TICKS then map_poles(n); sample(n) end
  end
  -- Everything for one force, kept 60 s so every peer and reply sees the same.
  -- With the background job running (M.view_tick) a reply only reads the last
  -- finished view; a force's very first view (and tests without the job) is
  -- built here at once.
  local function view(f)
    local n = store()
    local v = n.views[f.name]
    if v and (n.view_bg or game.tick - v.tick < VIEW_TICKS) then return v end
    fresh_map(n)
    v = {tick=game.tick, surfaces={}}
    for _, surface in ipairs(surfaces()) do
      local e, l, t = electric(n, f, surface), logistic(n, f, surface), turrets(f, surface)
      if #e > 0 or #l > 0 or t then v.surfaces[#v.surfaces+1] = {name=surface.name, platform=try(function() return surface.platform.name end), electric=e, logistic=l, turrets=t} end
    end
    orders_seen(n, f)
    n.views[f.name] = v
    return v
  end
  -- The background view, started when the view is VIEW_TICKS old, one step
  -- every few ticks so it spreads over that (walk.every). Per surface: one
  -- walk of generators, machines, boilers and turrets together, a band or
  -- SLICE entities a step (operator 04:00: a whole-surface find a step burst
  -- in single game seconds); the boilers to their networks; their feeders,
  -- BOILER_SLICE boilers a step; the rows; the logistic networks; the turret
  -- line. The pole map is its own job (map_step).
  local VIEW_TYPES, IS_GEN, IS_MACHINE, IS_TURRET = {}, {}, {}, {}
  for _, list in ipairs({{GENERATORS, IS_GEN}, {MACHINES, IS_MACHINE}, {{'boiler'}, {}}, {TURRETS, IS_TURRET}}) do
    for _, t in ipairs(list[1]) do
      list[2][t] = true
      local seen = false
      for _, x in ipairs(VIEW_TYPES) do if x == t then seen = true end end
      if not seen then VIEW_TYPES[#VIEW_TYPES+1] = t end
    end
  end
  local function view_entity(ctx, e)
    if not e.valid then return end
    local t = e.type
    if IS_GEN[t] then e_gen(ctx, e) end
    if IS_MACHINE[t] then e_machine(ctx, e) end
    if t == 'boiler' then ctx.boiler_list[#ctx.boiler_list+1] = e end
    if IS_TURRET[t] then ctx.turrets[e.name] = (ctx.turrets[e.name] or 0) + 1 end
  end
  function M.view_tick(tick)
    local n = store()
    n.view_bg = true
    n.view_jobs = n.view_jobs or {}
    for _, f in ipairs(forces()) do
      -- A step that fails ends its job (noted in view_errors); the view is kept another VIEW_TICKS.
      local ok, err = pcall(M.view_step, n, f, tick)
      if not ok then
        n.view_jobs[f.name] = nil
        n.view_errors = {count=((n.view_errors or {}).count or 0) + 1, last=tostring(err), tick=tick}
        if n.views[f.name] then n.views[f.name].tick = tick end
      end
    end
  end
  -- A call timed as its own profile part while the operator profile runs (runtime M.timed); else just the call.
  local function timed(label, fn, ...)
    if api.timed then return api.timed(label, fn, ...) end
    return fn(...)
  end
  local view_do
  function M.view_step(n, f, tick)
    local job = n.view_jobs[f.name]
    local v = n.views[f.name]
    if not job and (not v or tick - v.tick >= VIEW_TICKS) then
      -- (with no pole map yet the first is made here at once)
      if not n.map_tick then fresh_map(n) end
      local steps = {}
      for _, s in ipairs(surfaces()) do
        for _, step in ipairs({'walk', 'boilers', 'supply', 'rows', 'logistic', 'orders', 'turrets'}) do steps[#steps+1] = {step=step, surface=s.name} end
      end
      steps[#steps+1] = {step='done'}
      n.view_steps = n.view_steps or {}
      n.view_jobs[f.name] = {start=tick, steps=steps, i=1, out={}, ctx={}, n=0, every=walk.every(n.view_steps[f.name], VIEW_TICKS)}
      return
    end
    if not job or not walk.due(job, tick, VIEW_TICKS) then return end
    job.n = job.n + 1
    local step = job.steps[job.i]
    -- (each kind of step its own profile part, networks.view.<step>: operator 18:12, networks.view_tick 186 ms in one
    -- game second at 17:53 with no part to say which step)
    local kind = step.step == 'walk' and (job.list and 'walk_slice' or 'walk_band') or step.step
    return timed('networks.view.' .. kind, view_do, n, f, tick, job, step)
  end
  view_do = function(n, f, tick, job, step)
    if step.step == 'done' then
      local v2 = {tick=job.start, surfaces={}}
      for _, s in ipairs(surfaces()) do
        local r = job.out[s.name]
        if r and ((r.electric and #r.electric > 0) or #r.logistic > 0 or r.turrets) then
          r.electric = r.electric or {}
          v2.surfaces[#v2.surfaces+1] = r
        end
      end
      orders_seen(n, f)
      n.views[f.name] = v2
      n.view_steps[f.name] = job.n
      n.view_jobs[f.name] = nil
      return
    end
    local surface
    for _, s in ipairs(surfaces()) do if s.name == step.surface then surface = s end end
    if not surface then job.i, job.walk, job.list = job.i + 1, nil, nil; job.ctx[step.surface] = nil; return end  -- the surface is gone
    local row = job.out[step.surface] or {name=surface.name, platform=try(function() return surface.platform.name end), logistic={}}
    job.out[step.surface] = row
    local ctx = job.ctx[step.surface]
    if step.step == 'walk' then
      if not ctx then ctx = e_ctx(n, f, surface); ctx.boiler_list, ctx.turrets = {}, {}; job.ctx[step.surface] = ctx end
      if job.list then
        local last = math.min(#job.list, job.at + SLICE - 1)
        for k = job.at, last do view_entity(ctx, job.list[k]) end
        job.at = last + 1
        if job.at > #job.list then job.list = nil end
      else
        job.walk = job.walk or walk.start(surface)
        local list = walk.band(job.walk, surface, {type=VIEW_TYPES, force=f, limit=MAX_SCAN})
        if list then job.list, job.at = list, 1 else job.i, job.walk = job.i + 1, nil end
      end
      return
    end
    job.i = job.i + 1
    -- The construction backlog's finds, one a step (ghosts, deconstruction, upgrades of each network), then each
    -- network's backlog from them.
    if step.step == 'orders' then
      local q = job.orders
      if not q then
        q = {list={}, i=1, found={}}
        for _, r in ipairs(row.logistic or {}) do
          if r.orders_area then for _, x in ipairs(order_finds(f, r.orders_area)) do q.list[#q.list+1] = {id=r.id, kind=x.kind, q=x.q} end end
        end
        job.orders = q
      end
      local x = q.list[q.i]
      if x then
        q.found[x.id] = q.found[x.id] or {}
        q.found[x.id][x.kind] = try(function() return surface.find_entities_filtered(x.q) end) or {}
        q.i = q.i + 1
      end
      if q.i <= #q.list then job.i = job.i - 1   -- (the step repeats until every find is made)
      else finish_orders(n, f, surface, row.logistic or {}, q.found); job.orders = nil end
      return
    end
    -- The logistic networks one a step (by id: found again each step), then their lines.
    if step.step == 'logistic' then
      local q = job.logi
      if not q then
        q = {ids={}, i=1, rows={}}
        for _, ln in ipairs(logistic_networks(f, surface)) do
          local id = try(function() return ln.network_id end)
          if id then q.ids[#q.ids+1] = id end
        end
        orders_store(n, f)
        job.logi = q
      end
      local id = q.ids[q.i]
      if id then
        for _, ln in ipairs(logistic_networks(f, surface)) do
          if try(function() return ln.network_id end) == id then
            local r = logistic_row(n, f, surface, ln, true)
            if r then q.rows[#q.rows+1] = r end
          end
        end
        q.i = q.i + 1
      end
      if q.i <= #q.ids then job.i = job.i - 1   -- (the step repeats until every network is read)
      else row.logistic = logistic_done(surface, q.rows); job.logi = nil end
      return
    end
    if not ctx then
      if step.step == 'turrets' then row.turrets = turrets(f, surface, {}) end
    elseif step.step == 'boilers' then
      for _, e in ipairs(ctx.boiler_list) do e_boiler(ctx, e) end
      ctx.boiler_list = nil
      -- Feeders are read for the boilers of networks with a draw sample (the rows use them only there).
      ctx.supply, ctx.supply_at, ctx.walked = {}, 1, {}
      for id, net in pairs(ctx.nets) do
        if draw(n, id) then for _, b in ipairs(net.boilers) do ctx.supply[#ctx.supply+1] = b end end
      end
    elseif step.step == 'supply' then
      local last = math.min(#ctx.supply, ctx.supply_at + BOILER_SLICE - 1)
      if ctx.supply_at <= last then M.boiler_supply(ctx.supply, surface, f, ctx.walked, ctx.supply_at, last) end
      ctx.supply_at = last + 1
      if ctx.supply_at <= #ctx.supply then job.i = job.i - 1   -- (the step repeats until every boiler is read)
      else ctx.supplied, ctx.supply, ctx.walked = true, nil, nil end
    elseif step.step == 'rows' then row.electric = e_rows(ctx, n, surface, f)
    elseif step.step == 'turrets' then row.turrets = turrets(f, surface, ctx.turrets); job.ctx[step.surface] = nil end
  end
  -- Plain rows (no entities) for the read.
  local function plain(r, keys)
    local out = {}
    for _, k in ipairs(keys) do out[k] = r[k] end
    return out
  end
  -- One surface's largest electric network by capacity, as plain numbers
  -- (scienceline.lua): {id, capacity_kw, draw_kw (5 min avg), boilers, fed,
  -- low (boilers under 20 min of their own fuel not refilled), low_min (the lowest of them)}.
  function M.power_row(f, surface_name)
    local best
    for _, s in ipairs(view(f).surfaces) do
      if s.name == surface_name then
        for _, r in ipairs(s.electric) do if not best or r.capacity_kw > best.capacity_kw then best = r end end
      end
    end
    if not best then return nil end
    -- The falling feed chest with the fewest minutes left (Haiku, 12:20), for status's science line.
    local x = best.feed_rates and best.feed_rates[1]
    local feed = x and x.minutes_left and {min=x.minutes_left, line=string.format('%s %s %s, %s', x.chest, at(x.position.x, x.position.y), x.held, x.rate)} or nil
    return {id=best.id, capacity_kw=best.capacity_kw, draw_kw=best.draw and best.draw.avg or nil, boilers=#best.boilers,
      fed=best.fed, low=best.fuel_low and #best.fuel_low or 0, low_min=best.fuel_low and best.fuel_low[1] and best.fuel_low[1].min or nil,
      feed=feed}
  end
  -- The lines, the agent's surface first; at most `max` (the rest counted).
  -- While Nauvis is the only planet in play (runtime one_planet; Nick 12:35, item 4) a line names no planet.
  local function plain_line(f, line)
    if api.one_planet and try(function() return api.one_planet(f) end) then return (line:gsub('^nauvis ', '')) end
    return line
  end
  function M.lines(f, here, max)
    local v = view(f)
    local list = {}
    local function add(s)
      for _, r in ipairs(s.electric) do list[#list+1] = plain_line(f, r.line) end
      for _, r in ipairs(s.logistic) do list[#list+1] = plain_line(f, r.line) end
      if s.turrets then list[#list+1] = plain_line(f, s.turrets.line) end
    end
    for _, s in ipairs(v.surfaces) do if s.name == here then add(s) end end
    for _, s in ipairs(v.surfaces) do if s.name ~= here then add(s) end end
    if max and #list > max then
      local more = #list - max + 1
      while #list >= max do table.remove(list) end
      list[#list+1] = string.format('+%d more networks: fh call networks', more)
    end
    return list
  end
  -- The surface a read names: platform (a name or index) or surface (a planet or surface name, or a platform's name;
  -- Astra, 13:10: networks {surface: "Starling"} matched nothing, a platform's surface being platform-N).
  function M.surface_named(f, a)
    local want = a.platform ~= nil and a.platform or a.surface
    if want == nil then return nil end
    assert(a.platform == nil or a.surface == nil, 'give platform or surface, not both')
    local names = {}
    for _, pl in pairs(try(function() return f.platforms end) or {}) do
      if pl.valid then
        local s = try(function() return pl.surface end)
        if (pl.name == want or pl.index == want or (s and s.name == want)) and s then return s end
        names[#names+1] = pl.name
      end
    end
    if a.platform == nil then
      local s = game.get_surface(want)
      if s then return s end
    end
    table.sort(names)
    local planets = {}
    for _, s in ipairs(surfaces()) do if not try(function() return s.platform end) then planets[#planets+1] = s.name end end
    error(string.format('no %s named %s; platforms: %s; planets and surfaces: %s', a.platform ~= nil and 'platform of ours' or 'surface or platform',
      tostring(want), #names > 0 and table.concat(names, ', ') or 'none', table.concat(planets, ', ')), 0)
  end
  -- The network's draw now: its statistics' production over the last 5 s, from one of its poles (fresh: true).
  local function draw_now(n, id)
    local m = n.map and n.map[id]
    local stats = m and m.pole and m.pole.valid and try(function() return m.pole.electric_network_statistics end)
    if not stats then return nil end
    local kw = 0
    for name in pairs(try(function() return stats.output_counts end) or {}) do
      local f = try(function() return stats.get_flow_count{name=name, category='output', precision_index=defines.flow_precision_index.five_seconds} end)
      if f and f > 0 then kw = kw + f * 60 / 1000 end
    end
    return kw
  end
  function M.read(p, a)
    assert(a.fresh == nil or type(a.fresh) == 'boolean', 'fresh must be true or false')
    local v = view(p.force)
    local n = store()
    local named = M.surface_named(p.force, a)
    local out = {}
    for _, s in ipairs(v.surfaces) do
      if named == nil or named.name == s.name then
        local row = {surface=s.name, platform=s.platform, electric={}, logistic={}, turrets=s.turrets and {by_name=s.turrets.by, ammo_used_1h=s.turrets.used, line=plain_line(p.force, s.turrets.line)} or nil}
        for _, r in ipairs(s.electric) do
          local x = plain(r, {'id', 'poles', 'machines', 'low', 'none', 'acc', 'solar', 'line'})
          x.line = plain_line(p.force, x.line)
          x.center = {x=math.floor(r.center.x + 0.5), y=math.floor(r.center.y + 0.5)}
          x.capacity_kw = math.floor(r.capacity_kw + 0.5)
          x.generators_kw, x.solar_peak_kw = math.floor(r.cap_kw + 0.5), math.floor(r.solar_peak_kw + 0.5)
          x.solar_power, x.solar_power_text = r.solar_power and math.floor(r.solar_power + 0.5), r.solar_power_text
          if r.draw then x.draw_kw = {avg=math.floor(r.draw.avg + 0.5), now=math.floor(r.draw.now + 0.5), over_s=r.draw.span_s} end
          x.boilers = #r.boilers > 0 and #r.boilers or nil
          x.fuel_min = r.fuel_min and math.floor(r.fuel_min) or nil
          x.boilers_fed = r.fed
          x.feed_chests = r.feed_rates
          x.boilers_under_10_min = r.fuel_under and #r.fuel_under or nil
          x.boilers_under_20_min = r.fuel_low and #r.fuel_low or nil
          x.lowest_boiler_min = r.lowest_min and math.floor(r.lowest_min) or nil
          local lb = r.lowest_b
          if lb and lb.e.valid then
            x.lowest_boiler = {position={x=lb.e.position.x, y=lb.e.position.y}, min=math.floor(lb.min), fuel=burner_fuel(lb.e),
              feeder=lb.feeder or 'no inserter feeds it', feeder_has_fuel=lb.fed}
          end
          -- Accumulators read now, whatever the view's age (Astra, shift14 22:50: the view's sum stayed put while an
          -- accumulator's inspect moved), the line's part too, and what they held every 15 s over the last 3 min.
          if r.acc > 0 then
            local j = acc_stored(r) or r.acc_j
            x.acc_mj, x.acc_max_mj = math.floor(j / 1e5 + 0.5) / 10, math.floor(r.acc_buf / 1e5 + 0.5) / 10
            x.acc_pct = r.acc_buf > 0 and math.floor(100 * j / r.acc_buf + 0.5) or nil
            local series = acc_series(n, r.id)
            x.acc_series = series and table.concat(series, ' ') .. ' (every 15 s over the last 3 min, oldest first)' or nil
            local live = acc_part(n, r.id, r.acc, j, r.acc_buf)
            x.line = x.line:gsub('accumulators %d+ at %d+%% %b()[^;]*', function() return live end, 1)
          end
          if a.fresh then
            local kw = draw_now(n, r.id)
            x.draw_now_kw = kw and math.floor(kw + 0.5) or nil
          end
          row.electric[#row.electric+1] = x
        end
        for _, r in ipairs(s.logistic) do
          local x = plain(r, {'id', 'roboports', 'center', 'logistic', 'logistic_idle', 'construction', 'construction_idle', 'unfilled', 'ghosts', 'line'})
          x.line = plain_line(p.force, x.line)
          x.unfilled_items = next(r.items) and r.items or nil
          x.none_idle_s = r.busy_since and math.floor((game.tick - r.busy_since) / 60) or nil
          x.personal = r.personal > 0 and r.personal or nil
          x.logistic_area, x.construction_area = r.view.logistic_area, r.view.construction_area
          -- Its items (Gemini, 12:20): the 20 most held, and every item its requesters ask for with what is short now.
          local held = {}
          for name, c in pairs(r.stock or {}) do held[#held+1] = {name=name, count=c} end
          table.sort(held, function(p, q) return p.count > q.count or (p.count == q.count and p.name < q.name) end)
          while #held > 20 do table.remove(held) end
          x.holds = #held > 0 and held or nil
          local asks = {}
          for name, c in pairs(r.asked or {}) do asks[#asks+1] = {name=name, asked=c, short=(r.short_now or {})[name] or 0} end
          table.sort(asks, function(p, q) return p.asked > q.asked or (p.asked == q.asked and p.name < q.name) end)
          x.requests = #asks > 0 and asks or nil
          x.logistic_robots, x.construction_robots = r.view.logistic, r.view.construction
          x.charging, x.waiting = r.view.charging, r.view.waiting
          -- Robot delays (Nick 12:35): the construction backlog and deliveries stuck with the item free.
          x.backlog = r.backlog
          x.deliveries = r.deliveries and {stuck=r.deliveries.stuck, free=r.deliveries.items, cause=r.deliveries.cause} or nil
          row.logistic[#row.logistic+1] = x
        end
        out[#out+1] = row
      end
    end
    -- A surface named with nothing in the view: said, with when the view looked (a new network shows within about 3 min).
    local none = named and #out == 0 and string.format('no electric network over 2 poles or with a generator, no logistic network and no turret of ours on %s as of %ds ago',
      label(named) .. (try(function() return named.platform end) and ' (' .. named.name .. ')' or ''), math.floor((game.tick - v.tick) / 60)) or nil
    return {surfaces=out, none=none, as_of=string.format('%ds ago', math.floor((game.tick - v.tick) / 60)),
      read_now=a.fresh and 'accumulators (acc_mj, acc_pct, the line\'s part) and draw_now_kw (the last 5 s of each network\'s statistics); the rest as of the view' or 'accumulators (acc_mj, acc_pct, the line\'s part); the rest as of the view, rebuilt every 60 s (fresh: true reads the draw now too)',
      note='draw: the network\'s production statistics sampled every 5 s; capacity: generators at their maximum plus solar at its output now '
        .. '(on a platform, solar at the solar power where it is: no night in space); solar power: a planet\'s solar-power against 100%, '
        .. 'a platform\'s the solar power in space of where it stops, or flying, of both ends of its connection by how far along it is; '
        .. 'boiler fuel: the boilers\' own fuel in minutes at the draw of the generators they feed, shared evenly over the boilers; '
        .. 'boilers_fed: boilers an inserter can bring fuel to now (fuel in its hand, at its source, on its belt within 64 tiles upstream or at what loads that belt); '
        .. 'boilers_under_N_min: under N min of their own fuel and not refilled (no fuel at their feeders, or their own fuel fell by 80% or more of their burn over 2+ min, or 25% over 4+ min); requests unfilled: '
        .. 'held plus on the way below the request for 60 s or more; ammo: consumed on the surface (items statistics); '
        .. 'logistic areas: bounding boxes of the roboports\' logistic and construction squares (a gap inside one is not shown); '
        .. 'robots: idle are stationed in a roboport, charging and waiting to charge are at a roboport, working are the rest (out on a job or flying)'}
  end

  -- boiler_fuel: the fuel its boilers burn (burning now or in the fuel slots;
  -- the usual fuels when they hold none), where that fuel sits nearby
  -- (chests and belts within FUEL_RADIUS tiles), and what feeds each low
  -- boiler now (inserters dropping into it and what they take from).
  local function name_of(v)
    if type(v) == 'string' then return v end
    if type(v) == 'table' or type(v) == 'userdata' then
      local n = try(function() return v.name end)
      if type(n) == 'string' then return n end
      return n and try(function() return n.name end)
    end
  end
  local function fuels_of(boilers)
    local seen, out = {}, {}
    local function add(n) if n and not seen[n] then seen[n] = true; out[#out+1] = n end end
    for _, b in ipairs(boilers) do
      local burner = b.e.valid and try(function() return b.e.burner end)
      if burner then
        add(name_of(try(function() return burner.currently_burning end)))
        local inv = try(function() return burner.inventory end)
        for i = 1, inv and #inv or 0 do
          local st = inv[i]
          if st and st.valid_for_read then add(st.name) end
        end
      end
    end
    return out, #out == 0
  end
  local function same(a, b)
    if not (a and b) then return false end
    local ua, ub = try(function() return a.unit_number end), try(function() return b.unit_number end)
    if ua and ub then return ua == ub end
    return a == b
  end
  local BELTS = {['transport-belt']=true, ['underground-belt']=true, splitter=true}
  -- What an entity holds of the fuels, as 'N coal, M solid-fuel' (nil: none).
  -- A boiler in a chain: its fuel slot; a chest or machine: all it holds.
  local function held_of(src, names)
    local inv = src.type == 'boiler' and try(function() return src.burner.inventory end)
    local parts, total = {}, 0
    for _, name in ipairs(names) do
      local n = inv and (try(function() return inv.get_item_count(name) end) or 0) or (try(function() return src.get_item_count(name) end) or 0)
      if n > 0 then parts[#parts+1] = n .. ' ' .. name; total = total + n end
    end
    return #parts > 0 and table.concat(parts, ', ') or nil, total
  end
  local CHESTS = {container=true, ['logistic-container']=true}
  -- Whether a feeder's source can bring fuel, {has, text}. A belt: its tile
  -- and up to BELT_WALK tiles upstream (an underground's entrance followed);
  -- when those hold none, the inserters within 3 tiles of the run that drop
  -- onto it and what they take from (one bounded find, 00:26 rule).
  local function source_fuel(src, names, surface, f)
    local pos = at(src.position.x, src.position.y)
    if not BELTS[src.type] then
      local held, total = held_of(src, names)
      return {has=held ~= nil, text=string.format('%s %s holding %s', src.name, pos, held or 'no fuel'), count=total, held=held,
        chest=CHESTS[src.type] and src or nil}
    end
    local by, tiles, queue, seen, run, want = {}, 0, {src}, {}, {}, {}
    for _, name in ipairs(names) do want[name] = true end
    local x0, y0, x1, y1 = src.position.x, src.position.y, src.position.x, src.position.y
    while #queue > 0 and tiles < BELT_WALK do
      local e = table.remove(queue, 1)
      local id = try(function() return e.unit_number end) or tostring(e)
      if e.valid and not seen[id] then
        seen[id] = true; tiles = tiles + 1; run[id] = true
        x0, y0, x1, y1 = math.min(x0, e.position.x), math.min(y0, e.position.y), math.max(x1, e.position.x), math.max(y1, e.position.y)
        for i = 1, try(function() return e.get_max_transport_line_index() end) or 0 do
          local line = try(function() return e.get_transport_line(i) end)
          -- One read of the lane (operator 04:00: a count per fuel per lane per tile was 640 reads a belt walk).
          local contents = line and try(function() return line.get_contents() end)
          if contents then
            for k, v in pairs(contents) do
              local name, n = type(v) == 'table' and v.name or k, type(v) == 'table' and v.count or v
              if want[name] and type(n) == 'number' and n > 0 then by[name] = (by[name] or 0) + n end
            end
          else
            for _, name in ipairs(names) do
              local n = line and try(function() return line.get_item_count(name) end) or 0
              if n > 0 then by[name] = (by[name] or 0) + n end
            end
          end
        end
        for _, nb in ipairs(try(function() return e.belt_neighbours.inputs end) or {}) do queue[#queue+1] = nb end
        if e.type == 'underground-belt' and try(function() return e.belt_to_ground_type end) == 'output' then
          local pair = try(function() return e.neighbours end)
          if pair and try(function() return pair.valid end) then queue[#queue+1] = pair end
        end
      end
    end
    local parts = {}
    for _, name in ipairs(names) do if by[name] then parts[#parts+1] = by[name] .. ' ' .. name end end
    local text = string.format('%s %s (with %d belt tiles up to it holding %s)', src.name, pos, tiles, #parts > 0 and table.concat(parts, ', ') or 'no fuel')
    if #parts > 0 then return {has=true, text=text} end
    local loads = {}
    for _, ins in ipairs(try(function() return surface.find_entities_filtered{type='inserter', force=f, area={{x0 - 3, y0 - 3}, {x1 + 3, y1 + 3}}, limit=200} end) or {}) do
      local to = ins.valid and try(function() return ins.drop_target end)
      local id = to and (try(function() return to.unit_number end) or tostring(to))
      local from = id and run[id] and try(function() return ins.pickup_target end)
      if from and from.valid and not BELTS[from.type] then
        local held = held_of(from, names)
        loads[#loads+1] = string.format('%s %s from %s %s holding %s', ins.name, at(ins.position.x, ins.position.y), from.name, at(from.position.x, from.position.y), held or 'no fuel')
        if held then return {has=true, text=text .. '; loaded by ' .. loads[#loads]} end
      end
    end
    return {has=false, text=text .. (#loads > 0 and '; loaded by ' .. loads[1] or '')}
  end
  -- The fuels a boiler's feeders count: those it burns or holds, then the usual ones.
  local function fuel_names(b)
    local names = fuels_of({b})
    local seen = {}
    for _, n in ipairs(names) do seen[n] = true end
    for _, n in ipairs(FUELS) do if not seen[n] then names[#names+1] = n end end
    return names
  end
  -- Per boiler, b.fed: a feeder can bring more fuel now (fuel in its hand,
  -- or at its source); b.feeder names the feeder that can (else the first)
  -- and its source, or that no inserter feeds it. One read per source and
  -- fuel list in a look (several boilers take from one chest or belt tile);
  -- walked: that memo, when boilers are read a few at a time (from..to).
  function M.boiler_supply(boilers, surface, f, walked, from, to)
    walked = walked or {}
    for i = from or 1, to or #boilers do
      local b = boilers[i]
      b.fed, b.feeder, b.chest = false, nil, nil
      local e = b.e
      local names = fuel_names(b)
      local key = table.concat(names, ',')
      if e.valid then
        for _, ins in ipairs(try(function() return surface.find_entities_filtered{type='inserter', force=f, position=e.position, radius=4} end) or {}) do
          if not b.fed and ins.valid and same(try(function() return ins.drop_target end), e) then
            local where = at(ins.position.x, ins.position.y)
            local hand = try(function() local h = ins.held_stack; return h.valid_for_read and h.name end)
            local in_hand
            for _, n in ipairs(hand and names or {}) do if n == hand then in_hand = true end end
            local src = try(function() return ins.pickup_target end)
            local memo = src and src.valid and tostring(try(function() return src.unit_number end) or at(src.position.x, src.position.y)) .. '|' .. key
            local s = memo and (walked[memo] or source_fuel(src, names, surface, f))
            if memo then walked[memo] = s end
            local text = s and string.format('%s %s from %s', ins.name, where, s.text) or string.format('%s %s with no pickup target', ins.name, where)
            if in_hand then text = string.format('%s %s holding %s in hand', ins.name, where, hand) end
            -- The chest it takes from, for the feed chest check (M.feed_chests).
            if s and s.chest and not b.chest then b.chest = {e=s.chest, count=s.count, held=s.held, feeder=ins.name .. ' ' .. where, names=names, tick=game.tick} end
            if in_hand or (s and s.has) then b.fed, b.feeder = true, text
            else b.feeder = b.feeder or text end
          end
        end
      end
      b.feeder = b.feeder or 'no inserter feeds it'
    end
  end
  -- Feed chests running out (Haiku, 10:50: the north row's chests ran low about every 20 min): a boiler whose feeder
  -- takes from a chest holding under FEED_LOW of its fuels, with nothing put into that chest for FEED_TICKS: its count
  -- never rose between the looks of that time (storage feed_hist, one count per look, kept FEED_TICKS and a minute),
  -- no robot is on the way to it with a fuel, and no inserter dropping into it holds a fuel. Returns the boilers so,
  -- each {e, chest, count, held, feeder}.
  local FEED_LOW, FEED_TICKS, RATE_TICKS = 20, 18000, 36000
  -- A feed chest's fuel rate (Haiku, 12:20): its net change per minute from its look RATE_TICKS ago or the oldest
  -- since (one at least a minute old), and the minutes left at that rate while it falls. {per_min (negative: falling),
  -- minutes_left, over_min, text} or nil before two looks a minute apart.
  function M.feed_rate(chest, count)
    local unit = chest and chest.valid and try(function() return chest.unit_number end)
    local hist = unit and (store().feed_hist or {})[unit]
    local old
    for _, x in ipairs(hist or {}) do
      if game.tick - x.tick <= RATE_TICKS and game.tick - x.tick >= 3600 and not old then old = x end
    end
    if not old then return nil end
    local mins = (game.tick - old.tick) / 3600
    local per_min = (count - old.n) / mins
    local left = per_min < 0 and count / -per_min or nil
    local text = per_min < 0 and string.format('uses %.1f/min over %d min, %d min left', -per_min, math.floor(mins + 0.5), math.floor(left))
      or per_min > 0 and string.format('gains %.1f/min over %d min', per_min, math.floor(mins + 0.5))
      or string.format('unchanged over %d min', math.floor(mins + 0.5))
    return {per_min=math.floor(per_min * 10 + 0.5) / 10, minutes_left=left and math.floor(left) or nil, over_min=math.floor(mins + 0.5), text=text}
  end
  function M.feed_chests(boilers, surface, f)
    local st = store()
    st.feed_hist = st.feed_hist or {}
    local out, judged = {}, {}
    for _, b in ipairs(boilers) do
      local c = b.chest
      local chest = c and c.e
      local unit = chest and chest.valid and try(function() return chest.unit_number end)
      if unit then
        local hist = st.feed_hist[unit] or {}
        st.feed_hist[unit] = hist
        -- Each count at the tick it was read (the background view reads feeders some steps before its rows), in order.
        local at_tick, known = c.tick or game.tick, false
        for _, x in ipairs(hist) do if x.tick == at_tick then known = true end end
        if not known then
          local i = #hist + 1
          while i > 1 and hist[i - 1].tick > at_tick do i = i - 1 end
          table.insert(hist, i, {tick=at_tick, n=c.count})
        end
        while hist[1] and game.tick - hist[1].tick > RATE_TICKS + 3600 do table.remove(hist, 1) end
        if judged[unit] == nil then
          local quiet = c.count < FEED_LOW
          -- Looks covering FEED_TICKS: the oldest kept is that old.
          local first
          for _, x in ipairs(hist) do if game.tick - x.tick >= FEED_TICKS then first = x end end
          if quiet and not first then quiet = false end
          for i = 2, #hist do
            if quiet and hist[i].n > hist[i - 1].n and game.tick - hist[i].tick <= FEED_TICKS then quiet = false end
          end
          if quiet then
            local pt = try(function() return chest.get_logistic_point(defines.logistic_member_index.logistic_container) end)
            local coming = pt and try(function() return pt.targeted_items_deliver end) or {}
            for k, v in pairs(coming) do
              local name, n = type(v) == 'table' and v.name or k, type(v) == 'table' and v.count or v
              if type(name) == 'table' then name = name.name end
              for _, fuel in ipairs(c.names) do if name == fuel and (n or 0) > 0 then quiet = false end end
            end
          end
          if quiet then
            for _, ins in ipairs(try(function() return surface.find_entities_filtered{type='inserter', force=f, position=chest.position, radius=3, limit=32} end) or {}) do
              if ins.valid and same(try(function() return ins.drop_target end), chest) then
                local hand = try(function() local h = ins.held_stack; return h.valid_for_read and h.name end)
                for _, fuel in ipairs(c.names) do if hand == fuel then quiet = false end end
              end
            end
          end
          judged[unit] = quiet
        end
        if judged[unit] then out[#out+1] = {e=b.e, chest=chest, count=c.count, held=c.held, feeder=c.feeder} end
      end
    end
    for unit, hist in pairs(st.feed_hist) do
      if not hist[#hist] or game.tick - hist[#hist].tick > RATE_TICKS + 3600 then st.feed_hist[unit] = nil end
    end
    return out
  end
  function M.fuel_sources(surface, f, center, names)
    local chests, belts = {}, {tiles=0, by={}, near={}}
    local function dist(p) return (p.x - center.x) ^ 2 + (p.y - center.y) ^ 2 end
    for _, e in ipairs(try(function() return surface.find_entities_filtered{type={'container', 'logistic-container'}, force=f, position=center, radius=FUEL_RADIUS, limit=FUEL_SCAN} end) or {}) do
      local inv = e.valid and try(function() return e.get_inventory(defines.inventory.chest) end)
      if inv then
        local parts = {}
        for _, name in ipairs(names) do
          local n = try(function() return inv.get_item_count(name) end) or 0
          if n > 0 then parts[#parts+1] = name .. ' ' .. n end
        end
        if #parts > 0 then chests[#chests+1] = {text=string.format('%s %s %s', e.name, at(e.position.x, e.position.y), table.concat(parts, ', ')), d=dist(e.position)} end
      end
    end
    table.sort(chests, function(a, b) return a.d < b.d end)
    local tiles = {}
    for _, e in ipairs(try(function() return surface.find_entities_filtered{type={'transport-belt', 'underground-belt', 'splitter'}, force=f, position=center, radius=FUEL_RADIUS, limit=FUEL_SCAN} end) or {}) do
      local held = 0
      for i = 1, e.valid and (try(function() return e.get_max_transport_line_index() end) or 0) or 0 do
        local line = try(function() return e.get_transport_line(i) end)
        for _, name in ipairs(names) do
          local n = line and try(function() return line.get_item_count(name) end) or 0
          if n > 0 then belts.by[name] = (belts.by[name] or 0) + n; held = held + n end
        end
      end
      if held > 0 then belts.tiles = belts.tiles + 1; tiles[#tiles+1] = {p=e.position, d=dist(e.position)} end
    end
    table.sort(tiles, function(a, b) return a.d < b.d end)
    for i = 1, math.min(2, #tiles) do belts.near[i] = at(tiles[i].p.x, tiles[i].p.y) end
    return chests, belts
  end
  function M.fuel_group(s, r, f)
    local low = r.fuel_low
    local surface
    for _, x in ipairs(surfaces()) do if x.name == s.name then surface = x end end
    local g = {key='boiler_fuel|' .. s.name .. '|' .. r.id, kind='boiler_fuel', surface=s.name, n=#low, names={boiler=#low}, by={}, at={}}
    local sx, sy, counts = 0, 0, {0, 0, 0}
    for _, b in ipairs(low) do
      local e = b.e
      if e.valid then
        sx, sy = sx + e.position.x, sy + e.position.y
        if #g.at < 4 then g.at[#g.at+1] = {x=e.position.x, y=e.position.y} end
        local u = try(function() return e.last_user and e.last_user.name end)
        if u then g.by[u] = (g.by[u] or 0) + 1 end
      end
      for k, step in ipairs(FUEL_STEPS) do if b.min < step then counts[k] = counts[k] + 1 end end
    end
    g.center = {x=math.floor(sx / #low + 0.5), y=math.floor(sy / #low + 0.5)}
    local level = counts[3] > 0 and 3 or counts[2] > 0 and 2 or 1
    -- Worse: a lower step reached, or more boilers under 20 minutes.
    g.rank = level * 10000 + counts[1]
    local steps = {string.format('%d boiler%s under %d min of their own fuel at this draw', counts[1], counts[1] == 1 and '' or 's', FUEL_STEPS[1])}
    for k = 2, 3 do if counts[k] > 0 then steps[#steps+1] = string.format('%d under %d', counts[k], FUEL_STEPS[k]) end end
    g.now_text = table.concat(steps, ', ') .. string.format(', lowest %d min', math.floor(low[1].min))
    local names, guessed = fuels_of(r.boilers)
    if guessed then names = FUELS end
    local chests, belts = {}, {tiles=0, by={}, near={}}
    if surface and f then chests, belts = M.fuel_sources(surface, f, g.center, names) end
    local src = {}
    for i = 1, math.min(3, #chests) do src[i] = chests[i].text end
    local held = {}
    for _, name in ipairs(names) do if belts.by[name] then held[#held+1] = name .. ' ' .. belts.by[name] end end
    local fuel_text = string.format('fuel within %d tiles%s: %s%s', FUEL_RADIUS, guessed and ' (the boilers hold none; looked for ' .. table.concat(FUELS, ', ') .. ')' or '',
      #src > 0 and table.concat(src, ', ') .. (#chests > 3 and string.format(' (+%d chests)', #chests - 3) or '') or 'no chest',
      belts.tiles > 0 and string.format('; belts: %s on %d tiles, nearest %s', table.concat(held, ', '), belts.tiles, table.concat(belts.near, ', ')) or '; no belt')
    -- The lowest three: each boiler, its minutes, its feeder and that feeder's source (or that no inserter feeds it).
    local which = {}
    for i = 1, math.min(3, #low) do
      local b = low[i]
      local pos = b.e.valid and at(b.e.position.x, b.e.position.y) or '?'
      which[i] = string.format('boiler %s %d min%s: %s', pos, math.floor(b.min), b.drop and ', ' .. b.drop or '', b.feeder or 'no inserter feeds it')
    end
    g.line = string.format('%s, not refilled, near %s (electric #%d: %d boiler%s, %s); %s%s; %s', table.concat(steps, ', '),
      at(g.center.x, g.center.y), r.id, #r.boilers, #r.boilers == 1 and '' or 's',
      r.fed and string.format('%d with fuel at their feeders', r.fed) or 'no draw',
      table.concat(which, '; '), #low > 3 and string.format('; +%d more', #low - 3) or '', fuel_text)
    return g
  end
  -- Push alert groups (pushalerts.lua scan): plain data, worst first there.
  -- Fulgora's sky for an accumulator line (lightning.lua M.sky, round1220a): the next storm in daylight, else dawn.
  local function sky_text(name)
    local surface = try(function() return game.get_surface(name) end)
    local sky = surface and api.sky and try(function() return api.sky(surface) end)
    if not (sky and sky.dusk_in_s) then return '' end
    if sky.phase == 'day' then return string.format('; Fulgora: day, no lightning; next storm (dusk) in %s', span(sky.dusk_in_s)) end
    return string.format('; Fulgora: storm (%s); dawn (clear) in %s', sky.phase, span(sky.dawn_in_s))
  end
  -- Accumulators that empty within ACC_WARN seconds at their net flow of the last ACC_LOOK ticks (one group a
  -- network, kept ACC_HOLD ticks after, at the worst step: under 10, 5, 2 minutes).
  local function acc_group(n, s, r)
    n.acc_watch = n.acc_watch or {}
    local w = n.acc_watch[r.id]
    local flow = acc_flow(n, r.id)
    local stored = acc_stored(r) or 0
    local t = flow and flow > 1 and stored / (flow * 1000) or nil
    local empty = (r.acc_buf > 0 and stored <= 0.005 * r.acc_buf) or (t ~= nil and t < 1)
    if t and t < ACC_WARN then
      w = w or {since=game.tick, rank=0}
      w.last, w.t, w.flow = game.tick, t, flow
      if empty then w.empty = game.tick end
      local step = t < 120 and 3 or t < 300 and 2 or 1
      if step > w.rank then w.rank = step end
      n.acc_watch[r.id] = w
    end
    if not w or game.tick - w.last > ACC_HOLD then return nil end
    local center = {x=math.floor(r.center.x + 0.5), y=math.floor(r.center.y + 0.5)}
    local pct = r.acc_buf > 0 and math.floor(100 * stored / r.acc_buf + 0.5) or 0
    local line
    if w.last == game.tick and empty then
      line = string.format('electric #%d near %s: its %d accumulators are empty (%s of %s; %s net flowed out over the last %d s)',
        r.id, at(center.x, center.y), r.acc, mj(stored), mj(r.acc_buf), mw(flow), ACC_LOOK / 60)
    elseif w.last == game.tick then
      line = string.format('electric #%d near %s: its %d accumulators at %d%% (%s of %s) fall %s net over the last %d s: empty in about %s at that rate',
        r.id, at(center.x, center.y), r.acc, pct, mj(stored), mj(r.acc_buf), mw(flow), ACC_LOOK / 60, span(t))
    else
      local was = w.empty and string.format('ran empty %s ago', span((game.tick - w.empty) / 60))
        or string.format('were %s from empty %s ago (falling %s net)', span(w.t), span((game.tick - w.last) / 60), mw(w.flow))
      line = string.format('electric #%d near %s: its %d accumulators %s; now at %d%% (%s of %s)%s',
        r.id, at(center.x, center.y), r.acc, was, pct, mj(stored), mj(r.acc_buf),
        flow and flow < -1 and string.format(', rising %s net', mw(-flow)) or flow and flow > 1 and string.format(', falling %s net', mw(flow)) or '')
    end
    return {key='accumulators_draining|' .. s.name .. '|' .. r.id, kind='accumulators_draining', surface=s.name,
      n=100 - math.floor(math.min(w.t, ACC_WARN) / 6), rank=w.rank, names={accumulator=r.acc}, by={}, at={}, center=center,
      now_text=w.empty and w.last == game.tick and 'empty' or span(w.t) .. ' from empty', line=line .. sky_text(s.name)}
  end
  -- The alert groups of the networks, in steps (operator 18:12: pushalerts' networks stage ran them all in one tick,
  -- networks.alert_groups 58-60 ms on world n at 17:53). alert_cursor lists the view's networks; alert_step does up to
  -- `max` of them (each network's groups as alert_groups made them) and returns true when all are done, the groups in
  -- cur.out. alert_groups runs every step at once (replies, scan, tests).
  local function electric_groups(out, n, f, s, r)
        if r.acc and r.acc > 0 and r.center then
          local g = acc_group(n, s, r)
          if g then out[#out+1] = g end
        end
        local list = n.samples[r.id] or {}
        local held, first = true, nil
        for i = #list, 1, -1 do
          local x = list[i]
          if x.tick < game.tick - HIGH_TICKS then break end
          first = x.tick
          local cap = r.cap_kw + (x.by['solar-panel'] or 0)
          if cap <= 0 or x.kw < HIGH * cap then held = false; break end
        end
        if held and first and first <= game.tick - HIGH_TICKS + SAMPLE then
          local pct = r.capacity_kw > 0 and math.floor(100 * r.draw.now / r.capacity_kw) or 100
          out[#out+1] = {key='power_high|' .. s.name .. '|' .. r.id, kind='power_high', surface=s.name, n=math.floor(math.min(pct, 100) / 5) * 5,
            unit='%', names={}, by={}, at={}, center={x=math.floor(r.center.x + 0.5), y=math.floor(r.center.y + 0.5)},
            line=string.format('electric #%d draw at or above %d%% of capacity for 2 min: %s of %s now; %d machines on low power',
              r.id, math.floor(HIGH * 100), mw(r.draw.now), mw(r.capacity_kw), r.low)}
        end
        local g = r.fuel_low and #r.fuel_low > 0 and M.fuel_group(s, r, f)
        if g then out[#out+1] = g end
        -- A boiler's feed chest low with nothing put into it (M.feed_chests): one group per boiler; worse under 10, then empty.
        for _, x in ipairs(r.feed_low or {}) do
          if x.e.valid and x.chest.valid then
            local unit = try(function() return x.e.unit_number end) or 0
            local u = try(function() return x.e.last_user and x.e.last_user.name end)
            out[#out+1] = {key='feed_chest_low|' .. s.name .. '|' .. unit, kind='feed_chest_low', surface=s.name, n=1,
              rank=x.count == 0 and 3 or x.count < 10 and 2 or 1, names={boiler=1}, by=u and {[u]=1} or {},
              at={{x=x.e.position.x, y=x.e.position.y}}, center={x=math.floor(x.e.position.x + 0.5), y=math.floor(x.e.position.y + 0.5)},
              now_text=string.format('%s holding %s', x.chest.name, x.held or 'no fuel'),
              line=string.format('boiler %s: its feed chest %s %s holds %s, nothing put into it for %d+ min (feeder %s)',
                at(x.e.position.x, x.e.position.y), x.chest.name, at(x.chest.position.x, x.chest.position.y), x.held or 'no fuel',
                math.floor(FEED_TICKS / 3600), x.feeder)}
          end
        end
        if (r.none or 0) > 0 then
          local g = r.powerless or {names={}, by={}, at={}}
          local names = {}
          for name, count in pairs(g.names) do names[#names+1] = count .. ' ' .. name end
          table.sort(names)
          local generation = r.draw and r.draw.now
          out[#out+1] = {key='no_power.network|' .. s.name .. '|' .. r.id, kind='no_power.network', surface=s.name,
            n=r.none, names=g.names, by=g.by, at=g.at, center=r.center,
            line=string.format('electric #%d near %s: %d machines report no_power (%s); %d poles%s',
              r.id, at(r.center.x, r.center.y), r.none, table.concat(names, ', '), r.poles,
              generation ~= nil and string.format('; supplied %s (5 s average)%s', mw(generation), generation == 0 and ', no generation in that sample' or '') or '; generation sample unavailable')}
        end
  end
  local function logistic_groups(out, s, r)
        local center = r.center and {x=math.floor(r.center.x + 0.5), y=math.floor(r.center.y + 0.5)}
        -- Ghosts waiting 5+ min on robots with their items in the network (Nick 12:35).
        local k = r.backlog
        if k and center and (k.waited_ghosts or 0) > 0 and k.items_present then
          local state = k.robots == 0 and 'none' or k.idle == 0 and 'busy' or k.idle .. ' idle'
          out[#out+1] = {key='construction_wait|' .. s.name .. '|' .. r.id, kind='construction_wait', surface=s.name, n=k.waited_ghosts,
            names={}, by={}, at={}, center=center,
            line=string.format('ghosts waiting on robots: %d in network %d near (%d,%d), oldest %d min, %s (%s); the items are in the network',
              k.waited_ghosts, r.id, center.x, center.y, k.oldest_min or 0, plural(k.robots, 'construction robot'), state)}
        end
        -- Requests unfilled 5+ min while the item is free in the network, and what the robots are doing.
        local d = r.deliveries
        if d and center then
          local list, kinds = top_items(d.items, 3)
          out[#out+1] = {key='deliveries_wait|' .. s.name .. '|' .. r.id, kind='deliveries_wait', surface=s.name, n=d.stuck,
            names={}, by={}, at={}, center=center,
            line=string.format('deliveries waiting on robots: %s unfilled 5+ min in network %d near (%d,%d) while providers or storage hold the item free (%s%s): %s',
              plural(d.stuck, 'request'), r.id, center.x, center.y, list, kinds > 3 and ', ...' or '', d.cause)}
        end
        -- Requester chests with every slot taken while a request is short (full_requesters).
        if r.full and #r.full > 0 then
          local parts, sp = {}, 0
          for i, x in ipairs(r.full) do
            sp = sp + (x.spoilage or 0)
            if i <= FULL_SHOW then
              parts[#parts+1] = string.format('%s (%g,%g) asks %s: %s', x.e.name, x.e.position.x, x.e.position.y, x.item, x.text)
            end
          end
          local first = r.full[1].e.position
          out[#out+1] = {key='requester_full|' .. s.name .. '|' .. r.id, kind='requester_full', surface=s.name, n=#r.full,
            names={}, by={}, at={{x=first.x, y=first.y}}, center={x=math.floor(first.x + 0.5), y=math.floor(first.y + 0.5)},
            line=string.format('requester chests with every slot taken while a request is short 60+ s: %d in network %d%s: %s%s',
              #r.full, r.id, sp > 0 and string.format(' (spoilage %d among their slots)', sp) or '', table.concat(parts, '; '),
              #r.full > FULL_SHOW and string.format('; +%d more', #r.full - FULL_SHOW) or '')}
        end
        if r.busy_since and game.tick - r.busy_since >= BUSY_TICKS and r.center then
          out[#out+1] = {key='robots_busy|' .. s.name .. '|' .. r.id, kind='robots_busy', surface=s.name, n=1, names={}, by={}, at={},
            center={x=math.floor(r.center.x + 0.5), y=math.floor(r.center.y + 0.5)},
            line=string.format('logistic #%d: no idle logistic robot for %d min (%d robots; %d requests unfilled 60+ s)',
              r.id, math.floor((game.tick - r.busy_since) / 3600), r.logistic, r.unfilled)}
        end
  end
  function M.alert_cursor(f)
    local v = view(f)
    local rows = {}
    for _, s in ipairs(v.surfaces) do
      for _, r in ipairs(s.electric) do rows[#rows+1] = {s=s, r=r, electric=true} end
      for _, r in ipairs(s.logistic) do rows[#rows+1] = {s=s, r=r} end
    end
    return {force=f.name, rows=rows, i=1, out={}}
  end
  function M.alert_step(cur, max)
    local n = store()
    local f = game.forces[cur.force]
    local last = math.min(#cur.rows, cur.i + (max or #cur.rows) - 1)
    for i = cur.i, last do
      local row = cur.rows[i]
      if row.electric then electric_groups(cur.out, n, f, row.s, row.r) else logistic_groups(cur.out, row.s, row.r) end
    end
    cur.i = last + 1
    if cur.i <= #cur.rows then return false end
    for id, w in pairs(n.acc_watch or {}) do if game.tick - w.last > ACC_HOLD then n.acc_watch[id] = nil end end
    return true
  end
  function M.alert_groups(f)
    local cur = M.alert_cursor(f)
    M.alert_step(cur)
    return cur.out
  end
  -- boilers (Haiku, 06:20: "a 'boilers' read that lists each boiler's position, state and fuel (and its feeder), so
  -- the no_fuel one is named. I hit this every 3-4 min"): every boiler on a surface as its GUI and a look at it show,
  -- grouped by the electric network its steam feeds (as the networks read maps them: the generators on its steam's
  -- fluid segment, else the nearest within NEAR_BOILER tiles), the networks with boilers not working first and
  -- within each those boilers first. Feeders as boiler_fuel reads them (M.boiler_supply).
  local BOILERS_MAX = 64
  local STATE = {working='working', no_fuel='no fuel', full_output='output full', no_input_fluid='no water',
    low_input_fluid='low water', low_temperature='low temperature', disabled_by_control_behavior='disabled by circuit',
    disabled_by_script='disabled', marked_for_deconstruction='marked for deconstruction'}
  local function status_name(e)
    local st = try(function() return e.status end)
    for k, v in pairs(defines.entity_status or {}) do if v == st then return k end end
    return nil
  end
  local function stacks(inv)
    local parts = {}
    for _, s in ipairs(inv and (try(function() return inv.get_contents() end) or {}) or {}) do
      parts[#parts+1] = s.name .. (s.quality and s.quality ~= 'normal' and '@' .. s.quality or '') .. '*' .. s.count
    end
    return #parts > 0 and table.concat(parts, ' ') or 'empty'
  end
  local function fluid_text(e, i)
    local box = try(function() return e.fluidbox[i] end)
    if not box then return 'empty' end
    local cap = try(function() return e.fluidbox.get_capacity(i) end)
    return string.format('%s %d%s', box.name, math.floor(box.amount + 0.5), cap and '/' .. math.floor(cap + 0.5) or '')
  end
  function M.boilers(p, a)
    assert(a.surface == nil or type(a.surface) == 'string', 'surface must be a surface name')
    local surface = p.surface
    if a.surface then
      surface = nil
      for _, s in ipairs(surfaces()) do if s.name == a.surface then surface = s end end
      assert(surface, 'unknown surface ' .. a.surface)
    end
    local f = p.force
    local ctx = e_begin(store(), f, surface)
    local found = try(function() return surface.find_entities_filtered{type='boiler', force=f, limit=MAX_SCAN} end) or {}
    local rows, walked = {}, {}
    for _, e in ipairs(found) do
      if e.valid then
        local status = status_name(e)
        local burner = try(function() return e.burner end)
        local sid = segment(e, try(function() return #e.fluidbox end) or 2)
        local to = sid and ctx.seg_net[sid]
        if not to then
          local best = NEAR_BOILER * NEAR_BOILER
          for _, g in ipairs(ctx.steam) do
            local d = (g.x - e.position.x) ^ 2 + (g.y - e.position.y) ^ 2
            if d <= best then best, to = d, g end
          end
        end
        local burning = burner and name_of(try(function() return burner.currently_burning end))
        rows[#rows+1] = {position={x=e.position.x, y=e.position.y}, name=e.name, status=status,
          state=STATE[status or ''] or (status and status:gsub('_', ' ')) or 'unknown', working=status == 'working',
          fuel=burner and stacks(try(function() return burner.inventory end)) or nil, burning=burning,
          water=fluid_text(e, 1), steam=fluid_text(e, try(function() return #e.fluidbox end) or 2),
          network=to and to.id or nil, _e=burner and e or nil}
      end
    end
    local groups, by = {}, {}
    for _, r in ipairs(rows) do
      local key = r.network or -1
      local g = by[key]
      if not g then g = {network=r.network, boilers={}, not_working=0}; by[key] = g; groups[#groups+1] = g end
      g.boilers[#g.boilers+1] = r
      if not r.working then g.not_working = g.not_working + 1 end
    end
    local shown = 0
    for _, g in ipairs(groups) do
      table.sort(g.boilers, function(x, y)
        if x.working ~= y.working then return not x.working end
        if x.position.x ~= y.position.x then return x.position.x < y.position.x end
        return x.position.y < y.position.y
      end)
      g.total = #g.boilers
      local counts = {}
      for _, r in ipairs(g.boilers) do counts[r.state] = (counts[r.state] or 0) + 1 end
      local parts = {}
      for state, n in pairs(counts) do parts[#parts+1] = n .. ' ' .. state end
      table.sort(parts)
      g.line = string.format('%s: %d boiler%s: %s', g.network and 'electric #' .. g.network or 'no electric network found',
        g.total, g.total == 1 and '' or 's', table.concat(parts, ', '))
    end
    table.sort(groups, function(x, y)
      if (x.not_working > 0) ~= (y.not_working > 0) then return x.not_working > 0 end
      if x.total ~= y.total then return x.total > y.total end
      return (x.network or math.huge) < (y.network or math.huge)
    end)
    -- At most BOILERS_MAX rows, the not-working ones first across groups.
    local left = BOILERS_MAX
    for _, g in ipairs(groups) do
      local keep = {}
      for _, r in ipairs(g.boilers) do
        if left > 0 and (not r.working or g.not_working == 0 or #keep < g.not_working + 4) then
          keep[#keep+1] = r; left = left - 1
        end
      end
      g.more = #g.boilers > #keep and #g.boilers - #keep or nil
      g.boilers = keep
      shown = shown + #keep
      -- Feeders only for the rows shown (an inserter find and a belt walk each: bounded, 00:26 rule).
      for _, r in ipairs(keep) do
        if r._e then
          local b = {e=r._e}
          M.boiler_supply({b}, surface, f, walked)
          r.feeder, r.feeder_has_fuel = b.feeder, b.fed
          -- Its feed chest: fuel, and the rate over the last 10 min from the networks view's looks (Haiku, 12:20).
          local c = b.chest
          if c and c.e.valid then
            local rate = M.feed_rate(c.e, c.count)
            r.feed_chest = {name=c.e.name, position={x=c.e.position.x, y=c.e.position.y}, holds=c.held or 'no fuel', count=c.count,
              per_min=rate and rate.per_min, minutes_left=rate and rate.minutes_left,
              line=string.format('%s %s %s, %s', c.e.name, at(c.e.position.x, c.e.position.y), c.held or 'no fuel', rate and rate.text or 'rate not measured yet')}
          end
        end
        r._e = nil
      end
      g.not_working = g.not_working > 0 and g.not_working or nil
    end
    local not_working = 0
    for _, r in ipairs(rows) do
      r._e = nil
      if not r.working then not_working = not_working + 1 end
    end
    return {surface=surface.name, boilers=#rows, not_working=not_working, networks=groups,
      note=#rows == 0 and 'no boiler of ours on ' .. surface.name or nil}
  end
  -- One producer's or consumer's power for inspect's `electricity` (Astra, 13:10: inspect on solar panels and machines showed no
  -- maximum): its maximum from the prototype at its quality (a machine's with its modules' consumption bonus, and its
  -- drain), a solar panel's at the solar power where it is, an accumulator's stored energy and flow limits; then now,
  -- from its network's statistics (the 5-second average, as power reads it): what all of its name on that network make
  -- or draw, since the game counts power by prototype, not by entity. nil for an entity with no electric part.
  local function kw(j) return math.floor(j * 60 / 1000 * 10 + 0.5) / 10 end
  function M.entity_power(e)
    if not (e and e.valid) then return nil end
    local proto, q = e.prototype, try(function() return e.quality end)
    local src = try(function() return proto.electric_energy_source_prototype end)
    local out, category = {}, nil
    if e.type == 'solar-panel' then
      local max = try(function() return proto.get_max_energy_production(q) end) or 0
      local s = M.solar(e.surface)
      out.max_kw, out.at_solar_power_kw, out.solar_power = kw(max), kw(max * s.percent / 100), s.text
      category = 'output'
    elseif e.type == 'accumulator' then
      out.stored_mj = math.floor((try(function() return e.energy end) or 0) / 1e5 + 0.5) / 10
      out.capacity_mj = math.floor((try(function() return e.electric_buffer_size end) or 0) / 1e5 + 0.5) / 10
      out.charge_kw = src and try(function() return kw(src.input_flow_limit) end) or nil
      out.discharge_kw = src and try(function() return kw(src.output_flow_limit) end) or nil
      category = 'output'
    elseif e.type == 'generator' or e.type == 'burner-generator' or e.type == 'fusion-generator' then
      out.max_kw = kw(max_output(e))
      category = 'output'
    elseif src then
      local use = try(function() return proto.get_max_energy_usage(q) end) or try(function() return proto.max_energy_usage end)
      if use and use > 0 then
        local bonus = try(function() return e.consumption_bonus end) or 0
        out.max_kw = kw(use * math.max(0.2, 1 + bonus))
        if bonus ~= 0 then out.consumption_bonus = string.format('%+d%%', math.floor(bonus * 100 + 0.5)) end
      end
      local drain = try(function() return src.drain end)
      if drain and drain > 0 then out.drain_kw = kw(drain) end
      category = 'input'
    else return nil end
    local id = try(function() return e.electric_network_id end)
    if not id then out.now = 'no electric network: no pole reaches it'; return out end
    local m = store().map[id]
    local pole = e.type == 'electric-pole' and e or (m and m.pole and m.pole.valid and m.pole)
    -- Not in the pole map (Astra, 14:05: an assembler on Starling): a pole of that network within 64 tiles.
    if not pole then
      for _, x in ipairs(try(function() return e.surface.find_entities_filtered{type='electric-pole', position=e.position, radius=64, force=e.force, limit=200} end) or {}) do
        if x.valid and try(function() return x.electric_network_id end) == id then pole = x; break end
      end
    end
    local stats = pole and try(function() return pole.electric_network_statistics end)
    local v = stats and try(function() return stats.get_flow_count{name=e.name, category=category, precision_index=defines.flow_precision_index.five_seconds} end)
    if v then
      out.now_kw_all_of_name = kw(v)
      out.now = string.format('all %s on electric network #%d %s %s now (5 s average); the game counts power by prototype, not per entity',
        e.name, id, category == 'output' and 'make' or 'draw', mw(v * 60 / 1000))
    elseif not pole then
      out.now = string.format('electric network #%d: no pole of ours in it within 64 tiles, and the game gives a network\'s statistics through its poles', id)
    else out.now = string.format('electric network #%d: its pole gave no statistics', id) end
    return out
  end
  M.schema = {
    boilers = {surface='optional surface name (default yours)',
      returns='boilers (count), not_working, networks [{network (electric network id its steam feeds, or none found), line, total, not_working, '
        .. 'boilers [{position, name, state (working, no fuel, output full, no water, low water, ...), status (the game\'s name), working, '
        .. 'fuel (its fuel slots, e.g. coal*5), burning, water and steam (amount/capacity), feeder (the inserter dropping into it and '
        .. 'what it takes from, with the fuel there, or no inserter feeds it), feeder_has_fuel}], more}], networks with a boiler not '
        .. 'working first, and those boilers first in each; at most 64 rows (more: rows left out, all working). Read only'},
    networks = {surface='optional planet or surface name, or a platform\'s name',platform='optional platform name or index (its surface\'s networks)',fresh='optional boolean: read each electric network\'s draw now too (draw_now_kw, the last 5 s of its statistics); accumulators are read now always; the rest is the view of as_of (rebuilt every 60 s)',
      returns='surfaces [{surface, platform (on a platform surface), electric [{id, poles, center, draw_kw {avg, now, over_s}, capacity_kw, generators_kw, solar, solar_peak_kw (on a platform: at the solar power where it is), solar_power (percent), solar_power_text, '
        .. 'acc, acc_mj, acc_max_mj, acc_pct (accumulators read now), acc_series (what they held every 15 s over the last 3 min, from the 5 s samples), draw_now_kw (fresh), machines, low, none, boilers, fuel_min, boilers_fed, boilers_under_20_min, boilers_under_10_min, lowest_boiler_min, line (its accumulator part read now)}], logistic [{id, roboports, personal, center, '
        .. 'logistic_area and construction_area {x0, y0, x1, y1}, logistic_robots and construction_robots {total, idle, working, '
        .. 'charging, waiting}, logistic, logistic_idle, none_idle_s, construction, construction_idle, unfilled, unfilled_items, '
        .. 'ghosts, line}], turrets {by_name, '
        .. 'ammo_used_1h, line}, storm (Fulgora, read now: state storm while dark (lightning strikes in the dark, none in daylight; the API has no storm property), else clear; '
        .. 'phase day|darkening|full dark|brightening, darkness, dusk_in_s, evening_in_s, morning_in_s, dawn_in_s, day_s, line)}]; none (a surface or platform named with none of these); as_of (kept 60 s); note (how each number is counted). Electric networks over 2 poles or with '
        .. 'a generator. Read only'},
  }
  return M
end
