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
-- three push alert kinds (pushalerts.lua): power_high (draw at 85% of
-- capacity or more for 2 minutes), robots_busy (no idle logistic robot for 10
-- minutes) and boiler_fuel (boilers under 20 minutes of their own fuel at the
-- draw that no feeder can bring more to, told
-- again at 10 and 5, with the fuel in chests and on belts nearby and what feeds them).
-- Draw comes from the network's statistics, sampled every 5 s (the 5-second
-- average, J per tick as handlers.power reads it): the game's own windows are
-- 5 s, 1 min and 10 min.
return function(api)
  local M = {}
  local SAMPLE, MAP_TICKS, WATCH_TICKS, WINDOW = 300, 18000, 1800, 18000
  local HIGH, HIGH_TICKS = 0.85, 7200
  local BUSY_TICKS, FUEL_LOW, UNFILLED_TICKS = 36000, 10, 3600
  -- boiler_fuel steps (Haiku, shift09: 10 minutes left was too late to feed by hand): told at 20, again at 10 and 5.
  local FUEL_STEPS, FUEL_RADIUS = {20, 10, 5}, 64
  -- Haiku, 01:53: the alert fired for hours ('lowest 0 min') on 13 boilers holding 4-26 coal each, all working, fed by
  -- inserters from a belt and a requester chest with 150+ coal. Haiku and Astra, 03:20: still 'under 5 min' for 12
  -- working boilers on full fuel belts (an inserter keeps a boiler's own fuel low; a belt's stock is a flow, not a
  -- store). A boiler is low only when its own fuel is under a step and nothing refills it: none of its feeders can
  -- bring more (no fuel in the inserter's hand, at its source; a belt: up to BELT_WALK tiles upstream, else what
  -- loads that run), or its own fuel fell by DRAIN or more of what it burns at its share of the draw since the last
  -- look at least DRAIN_MIN_TICKS before (shift10 03:36-03:38: boiler (-15,42) went from 8 to 6 min on a 64-tile
  -- belt with 4 solid-fuel on it). An inserter-kept buffer swings by a few items: a few coal is a quarter of a
  -- minute's burn, a few solid-fuel nearly a minute's, so the look compared is 2 minutes back or more.
  local BELT_WALK, DRAIN, DRAIN_MIN_TICKS, OWN_TICKS = 64, 0.8, 7200, 18000
  local FUEL_SCAN = 300   -- chests and belt tiles read per alert (00:26 rule: bounded reads on the live world)
  local FUELS = {'coal', 'solid-fuel', 'wood', 'rocket-fuel', 'nuclear-fuel'}
  local MAX_SCAN, MAX_GHOSTS, VIEW_TICKS, NEAR_BOILER = 20000, 4000, 3600, 12   -- the view: kept 60 s (task-statuscost)
  local GENERATORS = {'generator', 'burner-generator', 'solar-panel', 'accumulator', 'fusion-generator', 'electric-energy-interface'}
  local MACHINES = {'assembling-machine', 'furnace', 'mining-drill', 'lab', 'inserter', 'beacon', 'radar', 'roboport', 'pump',
    'electric-turret', 'rocket-silo', 'agricultural-tower', 'asteroid-collector', 'lamp', 'loader', 'loader-1x1', 'offshore-pump'}
  local TURRETS = {'ammo-turret', 'electric-turret', 'fluid-turret', 'artillery-turret'}
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
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
  local function map_poles(n)
    local map = {}
    for _, f in ipairs(forces()) do
      for _, surface in ipairs(surfaces()) do
        local poles = try(function() return surface.find_entities_filtered{type='electric-pole', force=f, limit=MAX_SCAN} end) or {}
        for _, e in ipairs(poles) do
          local id = e.valid and try(function() return e.electric_network_id end)
          if id then
            local m = map[id]
            if not m then m = {id=id, pole=e, poles=0, sx=0, sy=0, surface=surface.name, force=f.name}; map[id] = m end
            m.poles, m.sx, m.sy = m.poles + 1, m.sx + e.position.x, m.sy + e.position.y
          end
        end
      end
    end
    n.map, n.map_tick = map, game.tick
    for id in pairs(n.samples) do if not map[id] then n.samples[id] = nil end end
  end
  local function sample(n)
    for id, m in pairs(n.map) do
      local stats = m.pole.valid and try(function() return m.pole.electric_network_statistics end)
      if stats then
        local by, kw = {}, 0
        for name in pairs(try(function() return stats.output_counts end) or {}) do
          local v = try(function() return stats.get_flow_count{name=name, category='output', precision_index=defines.flow_precision_index.five_seconds} end)
          if v and v > 0 then by[name] = v * 60 / 1000; kw = kw + by[name] end
        end
        local list = n.samples[id] or {}
        n.samples[id] = list
        list[#list+1] = {tick=game.tick, kw=kw, by=by}
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
          if missing > 0 then out[#out+1] = {key=unit .. '|' .. name .. '|' .. quality, name=name, missing=missing} end
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
  -- task-statuscost: the requests are looked at every 30 s (unfilled for 60 s,
  -- no idle robot for 10 min); the poles are mapped again every 5 min in the
  -- background, and by the view when its map is older than the view's age.
  function M.tick(tick)
    if tick % SAMPLE ~= 0 then return end
    local n = store()
    if not n.map_tick or tick - n.map_tick >= MAP_TICKS then map_poles(n) end
    if not n.watch_tick or tick - n.watch_tick >= WATCH_TICKS then watch_logistics(n); n.watch_tick = tick end
    sample(n)
  end

  local function mw(kw)
    if kw >= 1000 then return string.format('%.1f MW', kw / 1000) end
    return string.format('%d kW', math.floor(kw + 0.5))
  end
  local function at(x, y) return string.format('(%d,%d)', math.floor(x + 0.5), math.floor(y + 0.5)) end
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
    return {avg=sum / #list, now=list[#list].kw, by=by, samples=#list, span_s=math.floor((list[#list].tick - list[1].tick) / 60) + 5}
  end
  local function max_output(e)
    local q = try(function() return e.quality end)
    local proto = e.prototype
    return try(function() return proto.get_max_power_output(q) end) or try(function() return proto.get_max_energy_production(q) end) or 0
  end
  local function solar_peak(e)
    local v = try(function() return e.prototype.get_max_energy_production(e.quality) end) or 0
    local scale = try(function()
      return e.surface.solar_power_multiplier * e.surface.get_property('solar-power') / prototypes.surface_property['solar-power'].default_value
    end) or 1
    return v * scale
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
  local function electric(n, f, surface)
    local nets = {}
    for id, m in pairs(n.map) do
      if m.surface == surface.name and m.force == f.name then
        nets[id] = {id=id, poles=m.poles, center={x=m.sx / m.poles, y=m.sy / m.poles}, cap_kw=0, solar_peak_kw=0, solar=0,
          acc=0, acc_j=0, acc_buf=0, machines=0, low=0, none=0, boilers={}, gens=0}
      end
    end
    local seg_net, steam = {}, {}
    for _, e in ipairs(try(function() return surface.find_entities_filtered{type=GENERATORS, force=f, limit=MAX_SCAN} end) or {}) do
      local net = e.valid and nets[try(function() return e.electric_network_id end) or -1]
      if net then
        net.gens = net.gens + 1
        if e.type == 'solar-panel' then net.solar = net.solar + 1; net.solar_peak_kw = net.solar_peak_kw + solar_peak(e) * 60 / 1000
        elseif e.type == 'accumulator' then
          net.acc = net.acc + 1
          net.acc_j = net.acc_j + (try(function() return e.energy end) or 0)
          net.acc_buf = net.acc_buf + (try(function() return e.electric_buffer_size end) or 0)
        elseif e.type ~= 'electric-energy-interface' then
          net.cap_kw = net.cap_kw + max_output(e) * 60 / 1000
          if e.type == 'generator' then
            local sid = segment(e, 1)
            if sid then seg_net[sid] = {net=net, gen=e.name} end
            steam[#steam+1] = {net=net, gen=e.name, x=e.position.x, y=e.position.y}
          end
        end
      end
    end
    local low, none = defines.entity_status and defines.entity_status.low_power, defines.entity_status and defines.entity_status.no_power
    for _, e in ipairs(try(function() return surface.find_entities_filtered{type=MACHINES, force=f, limit=MAX_SCAN} end) or {}) do
      local net = e.valid and nets[try(function() return e.electric_network_id end) or -1]
      if net then
        net.machines = net.machines + 1
        if e.status == low then net.low = net.low + 1 elseif e.status == none then net.none = net.none + 1 end
      end
    end
    -- A boiler feeds the generators whose steam it shares (its output's fluid
    -- segment), else the nearest generator within NEAR_BOILER tiles.
    for _, e in ipairs(try(function() return surface.find_entities_filtered{type='boiler', force=f, limit=MAX_SCAN} end) or {}) do
      local j = e.valid and fuel_energy(e)
      if j then
        local sid = segment(e, try(function() return #e.fluidbox end) or 2)
        local to = sid and seg_net[sid]
        if not to then
          local best = NEAR_BOILER * NEAR_BOILER
          for _, g in ipairs(steam) do
            local d = (g.x - e.position.x) ^ 2 + (g.y - e.position.y) ^ 2
            if d <= best then best, to = d, g end
          end
        end
        if to then to.net.boilers[#to.net.boilers+1] = {e=e, j=j, gen=to.gen} end
      end
    end
    local rows = {}
    for _, net in pairs(nets) do
      if net.poles > 2 or net.gens > 0 then
        local d = draw(n, net.id)
        net.draw = d
        local solar_now = d and d.by['solar-panel'] or 0
        net.capacity_kw = net.cap_kw + solar_now
        -- Boilers: their fuel at the draw of the generators they feed, shared evenly.
        if #net.boilers > 0 and d then
          local fed_kw, names = 0, {}
          for _, b in ipairs(net.boilers) do names[b.gen] = true end
          for name in pairs(names) do fed_kw = fed_kw + (d.by[name] or 0) end
          local under, low = {}, {}
          if fed_kw > 0 then
            -- Each boiler's own fuel in minutes at an even share of the draw;
            -- low: under the first step and not refilled (no feeder able to
            -- bring more, M.boiler_supply: b.fed; or draining: its own fuel
            -- fell by DRAIN of its burn since the last look).
            M.boiler_supply(net.boilers, surface, f)
            local each, own = fed_kw * 1000 / #net.boilers, 0
            net.fed = 0
            local st = store()
            st.boiler_prev = nil   -- (the running-down rule's memory, before 03:25)
            st.boiler_own = st.boiler_own or {}
            for _, b in ipairs(net.boilers) do
              b.min = b.j / each / 60
              own = own + b.j
              local unit = try(function() return b.e.unit_number end)
              local prev = unit and st.boiler_own[unit]
              local dt = prev and (game.tick - prev.tick) / 60
              if dt and dt * 60 >= DRAIN_MIN_TICKS and prev.j - b.j >= DRAIN * each * dt then
                b.drop = string.format('down from %d min %d s before', math.floor(prev.j / each / 60), math.floor(dt))
              end
              if unit and (not prev or game.tick - prev.tick >= DRAIN_MIN_TICKS) then st.boiler_own[unit] = {tick=game.tick, j=b.j} end
              if b.fed then net.fed = net.fed + 1 end
              local refilled = b.fed and not b.drop
              if b.min < FUEL_LOW and not refilled then under[#under+1] = b.e end
              if b.min < FUEL_STEPS[1] and not refilled then low[#low+1] = b end
              if not net.lowest_min or b.min < net.lowest_min then net.lowest_min = b.min end
            end
            for unit, v in pairs(st.boiler_own) do if game.tick - v.tick > OWN_TICKS then st.boiler_own[unit] = nil end end
            net.fuel_min = own / (fed_kw * 1000) / 60
          end
          net.fuel_under = under
          table.sort(low, function(a, b) return a.min < b.min end)
          net.fuel_low = low
        end
        local parts = {string.format('%s electric #%d (%d poles near %s)', surface.name, net.id, net.poles, at(net.center.x, net.center.y))}
        if d then
          parts[#parts+1] = string.format('draw %s avg over %s (now %s) of %s capacity%s', mw(d.avg), d.span_s >= 300 and '5 min' or d.span_s .. ' s',
            mw(d.now), mw(net.capacity_kw), net.capacity_kw > 0 and string.format(' (%d%%)', math.floor(100 * d.avg / net.capacity_kw + 0.5)) or '')
        else parts[#parts+1] = string.format('capacity %s; no draw sample yet', mw(net.capacity_kw)) end
        if net.solar > 0 then parts[#parts+1] = string.format('solar %d panels, %s now, %s peak', net.solar, mw(solar_now), mw(net.solar_peak_kw)) end
        if net.acc > 0 then parts[#parts+1] = string.format('accumulators %d at %d%%', net.acc, net.acc_buf > 0 and math.floor(100 * net.acc_j / net.acc_buf + 0.5) or 0) end
        parts[#parts+1] = string.format('machines %d: %d low power, %d no power', net.machines, net.low, net.none)
        if #net.boilers > 0 then
          parts[#parts+1] = string.format('boilers %d: their own fuel %s at this draw%s%s', #net.boilers,
            net.fuel_min and string.format('%d min', math.floor(net.fuel_min)) or 'n/a (no draw)',
            net.fed and string.format(', %d with fuel at their feeders', net.fed) or '',
            net.fuel_low and #net.fuel_low > 0 and string.format(', %d under %d min not refilled (lowest %d min)', #net.fuel_low, FUEL_STEPS[1],
              math.floor(net.fuel_low[1].min)) or '')
        end
        net.line = table.remove(parts, 1) .. ': ' .. table.concat(parts, '; ')
        rows[#rows+1] = net
      end
    end
    table.sort(rows, function(a, b) return a.poles > b.poles or (a.poles == b.poles and a.id < b.id) end)
    return rows
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
  local function logistic(n, f, surface)
    local rows, by_id = {}, {}
    for _, ln in ipairs(logistic_networks(f, surface)) do
      local id = try(function() return ln.network_id end)
      if id then
        local v = M.logistic_view(ln)
        local r = {id=id, roboports=v.roboports, personal=v.personal, center=v.center, view=v,
          logistic=v.logistic.total, logistic_idle=v.logistic.idle, construction=v.construction.total, construction_idle=v.construction.idle,
          ghosts=0, unfilled=0, items={}}
        for _, x in ipairs(shortfalls(ln)) do
          local since = n.unfilled[x.key]
          if since and game.tick - since >= UNFILLED_TICKS then r.unfilled = r.unfilled + 1; r.items[x.name] = (r.items[x.name] or 0) + x.missing end
        end
        r.busy_since = n.busy[id]
        rows[#rows+1] = r; by_id[id] = r
      end
    end
    if #rows == 0 then return rows end
    -- Ghosts: one bounded count per network over its construction area's bounding box (00:26 rule: a lookup per
    -- ghost, up to 4000, was the costliest part of this view).
    for _, r in ipairs(rows) do
      local b = r.view.construction_area
      if b then
        r.ghosts = try(function()
          return surface.count_entities_filtered{area={{b.x0, b.y0}, {b.x1, b.y1}}, type='entity-ghost', force=f, limit=MAX_GHOSTS}
        end) or 0
      end
    end
    for _, r in ipairs(rows) do
      local items, kinds = top_items(r.items, 3)
      r.line = string.format('%s logistic #%d: %s%s; requests unfilled 60+ s: %d%s; ghosts in its construction area: %d%s',
        surface.name, r.id, r.view.text,
        r.busy_since and game.tick - r.busy_since >= 600 and string.format('; no idle logistic robot for %d min', math.floor((game.tick - r.busy_since) / 3600)) or '',
        r.unfilled, kinds > 0 and ' (' .. items .. (kinds > 3 and ', ...' or '') .. ' missing)' or '',
        r.ghosts, r.ghosts >= MAX_GHOSTS and ' (counted up to ' .. MAX_GHOSTS .. ')' or '')
    end
    table.sort(rows, function(a, b) return a.roboports > b.roboports or (a.roboports == b.roboports and a.id < b.id) end)
    return rows
  end

  local function turrets(f, surface)
    local by = {}
    for _, e in ipairs(try(function() return surface.find_entities_filtered{type=TURRETS, force=f, limit=MAX_SCAN} end) or {}) do
      if e.valid then by[e.name] = (by[e.name] or 0) + 1 end
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

  -- Everything for one force, kept 60 s so every peer and reply sees the same.
  local function view(f)
    local n = store()
    local v = n.views[f.name]
    if v and game.tick - v.tick < VIEW_TICKS then return v end
    if not n.map_tick then map_poles(n); watch_logistics(n); n.watch_tick = game.tick; sample(n)
    elseif game.tick - n.map_tick >= VIEW_TICKS then map_poles(n); sample(n) end
    v = {tick=game.tick, surfaces={}}
    for _, surface in ipairs(surfaces()) do
      local e, l, t = electric(n, f, surface), logistic(n, f, surface), turrets(f, surface)
      if #e > 0 or #l > 0 or t then v.surfaces[#v.surfaces+1] = {name=surface.name, electric=e, logistic=l, turrets=t} end
    end
    n.views[f.name] = v
    return v
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
    return {id=best.id, capacity_kw=best.capacity_kw, draw_kw=best.draw and best.draw.avg or nil, boilers=#best.boilers,
      fed=best.fed, low=best.fuel_low and #best.fuel_low or 0, low_min=best.fuel_low and best.fuel_low[1] and best.fuel_low[1].min or nil}
  end
  -- The lines, the agent's surface first; at most `max` (the rest counted).
  function M.lines(f, here, max)
    local v = view(f)
    local list = {}
    local function add(s)
      for _, r in ipairs(s.electric) do list[#list+1] = r.line end
      for _, r in ipairs(s.logistic) do list[#list+1] = r.line end
      if s.turrets then list[#list+1] = s.turrets.line end
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
  function M.read(p, a)
    local v = view(p.force)
    local out = {}
    for _, s in ipairs(v.surfaces) do
      if a.surface == nil or a.surface == s.name then
        local row = {surface=s.name, electric={}, logistic={}, turrets=s.turrets and {by_name=s.turrets.by, ammo_used_1h=s.turrets.used, line=s.turrets.line} or nil}
        for _, r in ipairs(s.electric) do
          local x = plain(r, {'id', 'poles', 'machines', 'low', 'none', 'acc', 'solar', 'line'})
          x.center = {x=math.floor(r.center.x + 0.5), y=math.floor(r.center.y + 0.5)}
          x.capacity_kw = math.floor(r.capacity_kw + 0.5)
          x.generators_kw, x.solar_peak_kw = math.floor(r.cap_kw + 0.5), math.floor(r.solar_peak_kw + 0.5)
          if r.draw then x.draw_kw = {avg=math.floor(r.draw.avg + 0.5), now=math.floor(r.draw.now + 0.5), over_s=r.draw.span_s} end
          x.boilers = #r.boilers > 0 and #r.boilers or nil
          x.fuel_min = r.fuel_min and math.floor(r.fuel_min) or nil
          x.boilers_fed = r.fed
          x.boilers_under_10_min = r.fuel_under and #r.fuel_under or nil
          x.boilers_under_20_min = r.fuel_low and #r.fuel_low or nil
          x.lowest_boiler_min = r.lowest_min and math.floor(r.lowest_min) or nil
          row.electric[#row.electric+1] = x
        end
        for _, r in ipairs(s.logistic) do
          local x = plain(r, {'id', 'roboports', 'center', 'logistic', 'logistic_idle', 'construction', 'construction_idle', 'unfilled', 'ghosts', 'line'})
          x.unfilled_items = next(r.items) and r.items or nil
          x.none_idle_s = r.busy_since and math.floor((game.tick - r.busy_since) / 60) or nil
          x.personal = r.personal > 0 and r.personal or nil
          x.logistic_area, x.construction_area = r.view.logistic_area, r.view.construction_area
          x.logistic_robots, x.construction_robots = r.view.logistic, r.view.construction
          x.charging, x.waiting = r.view.charging, r.view.waiting
          row.logistic[#row.logistic+1] = x
        end
        out[#out+1] = row
      end
    end
    return {surfaces=out, as_of=string.format('%ds ago', math.floor((game.tick - v.tick) / 60)),
      note='draw: the network\'s production statistics sampled every 5 s; capacity: generators at their maximum plus solar at its output now; '
        .. 'boiler fuel: the boilers\' own fuel in minutes at the draw of the generators they feed, shared evenly over the boilers; '
        .. 'boilers_fed: boilers an inserter can bring fuel to now (fuel in its hand, at its source, on its belt within 64 tiles upstream or at what loads that belt); '
        .. 'boilers_under_N_min: under N min of their own fuel and not refilled (no fuel at their feeders, or their own fuel fell by 80% or more of their burn over the last 2+ min); requests unfilled: '
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
    local parts = {}
    for _, name in ipairs(names) do
      local n = inv and (try(function() return inv.get_item_count(name) end) or 0) or (try(function() return src.get_item_count(name) end) or 0)
      if n > 0 then parts[#parts+1] = n .. ' ' .. name end
    end
    return #parts > 0 and table.concat(parts, ', ') or nil
  end
  -- Whether a feeder's source can bring fuel, {has, text}. A belt: its tile
  -- and up to BELT_WALK tiles upstream (an underground's entrance followed);
  -- when those hold none, the inserters within 3 tiles of the run that drop
  -- onto it and what they take from (one bounded find, 00:26 rule).
  local function source_fuel(src, names, surface, f)
    local pos = at(src.position.x, src.position.y)
    if not BELTS[src.type] then
      local held = held_of(src, names)
      return {has=held ~= nil, text=string.format('%s %s holding %s', src.name, pos, held or 'no fuel')}
    end
    local by, tiles, queue, seen, run = {}, 0, {src}, {}, {}
    local x0, y0, x1, y1 = src.position.x, src.position.y, src.position.x, src.position.y
    while #queue > 0 and tiles < BELT_WALK do
      local e = table.remove(queue, 1)
      local id = try(function() return e.unit_number end) or tostring(e)
      if e.valid and not seen[id] then
        seen[id] = true; tiles = tiles + 1; run[id] = true
        x0, y0, x1, y1 = math.min(x0, e.position.x), math.min(y0, e.position.y), math.max(x1, e.position.x), math.max(y1, e.position.y)
        for i = 1, try(function() return e.get_max_transport_line_index() end) or 0 do
          local line = try(function() return e.get_transport_line(i) end)
          for _, name in ipairs(names) do
            local n = line and try(function() return line.get_item_count(name) end) or 0
            if n > 0 then by[name] = (by[name] or 0) + n end
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
  -- fuel list in a look (several boilers take from one chest or belt tile).
  function M.boiler_supply(boilers, surface, f)
    local walked = {}
    for _, b in ipairs(boilers) do
      b.fed, b.feeder = false, nil
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
            if in_hand or (s and s.has) then b.fed, b.feeder = true, text
            else b.feeder = b.feeder or text end
          end
        end
      end
      b.feeder = b.feeder or 'no inserter feeds it'
    end
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
  function M.alert_groups(f)
    local v = view(f)
    local n = store()
    local out = {}
    for _, s in ipairs(v.surfaces) do
      for _, r in ipairs(s.electric) do
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
      end
      for _, r in ipairs(s.logistic) do
        if r.busy_since and game.tick - r.busy_since >= BUSY_TICKS and r.center then
          out[#out+1] = {key='robots_busy|' .. s.name .. '|' .. r.id, kind='robots_busy', surface=s.name, n=1, names={}, by={}, at={},
            center={x=math.floor(r.center.x + 0.5), y=math.floor(r.center.y + 0.5)},
            line=string.format('logistic #%d: no idle logistic robot for %d min (%d robots; %d requests unfilled 60+ s)',
              r.id, math.floor((game.tick - r.busy_since) / 3600), r.logistic, r.unfilled)}
        end
      end
    end
    return out
  end
  M.schema = {
    networks = {surface='optional surface name',
      returns='surfaces [{surface, electric [{id, poles, center, draw_kw {avg, now, over_s}, capacity_kw, generators_kw, solar, solar_peak_kw, '
        .. 'acc, machines, low, none, boilers, fuel_min, boilers_fed, boilers_under_20_min, boilers_under_10_min, lowest_boiler_min, line}], logistic [{id, roboports, personal, center, '
        .. 'logistic_area and construction_area {x0, y0, x1, y1}, logistic_robots and construction_robots {total, idle, working, '
        .. 'charging, waiting}, logistic, logistic_idle, none_idle_s, construction, construction_idle, unfilled, unfilled_items, '
        .. 'ghosts, line}], turrets {by_name, '
        .. 'ammo_used_1h, line}}]; as_of (kept 60 s); note (how each number is counted). Electric networks over 2 poles or with '
        .. 'a generator. Read only'},
  }
  return M
end
