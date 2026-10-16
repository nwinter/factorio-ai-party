-- Burner machines that no inserter brings fuel to (fed by hand or by a standing order), projected to run dry within 10
-- minutes (Opus, d15 shifts 19-20: a column of 30 stone furnaces ran out of coal and copper fell from 1000 to 560 a
-- minute, found only through bottleneck). What a player sees: each machine's fuel slot and its burning bar, the
-- inserters next to it and what they hold or read.
-- A background pass over the census's fuel users (census.lua; furnaces, burner drills, burner assemblers, heating
-- towers, burner generators; boilers have their own alert in the networks view, burner inserters are left out), STEP
-- machines a check: its fuel (the fuel slots' fuel value plus what is left of the item burning) over its burn at full
-- use (its energy use with its consumption bonus, over the burner's effectivity) is its minutes left while it works.
-- Fed by an inserter: an inserter dropping into it holds a fuel item, or reads a belt, chest or machine output holding
-- one, or is filtered to one (read again every FED_TTL ticks). Machines no inserter feeds that work and have under
-- LIMIT minutes, or that are out of fuel after the pass saw them working with fuel, are grouped by name and 64-tile cell; each group under LIMIT is one line in
-- team.alerts, told once, again after AGAIN ticks if still so.
return function(api)
  local M = {}
  local STEP, EVERY, LIMIT, FED_TTL, AGAIN, MAX_LINES, KEEP = 24, 60, 10, 18000, 36000, 3, 36000
  local SKIP = {boiler=true, inserter=true, car=true, locomotive=true, ['spider-vehicle']=true}
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function at(q) return string.format('(%d,%d)', math.floor(q.x + 0.5), math.floor(q.y + 0.5)) end
  local fuel_cache = {}
  local function fuel_value(item)
    if type(item) ~= 'string' then return 0 end
    local v = fuel_cache[item]
    if v == nil then v = try(function() return prototypes.item[item].fuel_value end) or 0; fuel_cache[item] = v end
    return v
  end
  local function name_of(v)
    if type(v) == 'string' then return v end
    local n = v ~= nil and try(function() return v.name end)
    if type(n) == 'string' then return n end
    n = n ~= nil and try(function() return n.name end)
    return type(n) == 'string' and n or nil
  end
  local function store()
    local s = api.state()
    s.burnerfuel = s.burnerfuel or {surface=1, i=0, rows={}, fed={}, alerts={}, told={}, seq=0}
    return s.burnerfuel
  end
  local function has_fuel(list)
    for _, c in ipairs(list or {}) do if fuel_value(name_of(c.name)) > 0 then return name_of(c.name) end end
  end
  -- Whether an inserter brings e fuel (see the header); inserters near it found once per FED_TTL.
  local function fed_by_inserter(e)
    local r = 3 + math.max(1, (try(function() return e.bounding_box.right_bottom.x - e.bounding_box.left_top.x end) or 1) / 2)
    for _, i in ipairs(try(function() return e.surface.find_entities_filtered{type='inserter', force=e.force, position=e.position, radius=r} end) or {}) do
      if try(function() return i.drop_target end) == e then
        local h = try(function() return i.held_stack end)
        if h and h.valid_for_read and fuel_value(h.name) > 0 then return true end
        for k = 1, try(function() return i.filter_slot_count end) or 0 do
          if fuel_value(name_of(try(function() return i.get_filter(k) end))) > 0 then return true end
        end
        local src = try(function() return i.pickup_target end)
        if src and src.valid then
          local t = src.type
          if t == 'transport-belt' or t == 'underground-belt' or t == 'splitter' then
            for k = 1, try(function() return src.get_max_transport_line_index() end) or 0 do
              if has_fuel(try(function() return src.get_transport_line(k).get_contents() end)) then return true end
            end
          else
            local inv = try(function() return src.get_output_inventory() end) or try(function() return src.get_inventory(defines.inventory.chest) end)
            if has_fuel(inv and try(function() return inv.get_contents() end)) then return true end
          end
        end
      end
    end
    return false
  end
  -- Minutes of fuel a burner machine has at full use, the fuel it holds most of, and whether it is out.
  function M.minutes(e)
    local burner = try(function() return e.burner end)
    if not burner then return nil end
    local joules, top, topn = try(function() return burner.remaining_burning_fuel end) or 0, nil, 0
    local inv = try(function() return e.get_fuel_inventory() end)
    for _, c in ipairs(inv and try(function() return inv.get_contents() end) or {}) do
      local n = name_of(c.name)
      joules = joules + fuel_value(n) * (c.count or 0)
      if (c.count or 0) > topn then top, topn = n, c.count end
    end
    if not top then top = name_of(try(function() return burner.currently_burning end)) end
    local q = try(function() return e.quality end)
    local usage = try(function() return e.prototype.get_max_energy_usage(q) end) or try(function() return e.prototype.max_energy_usage end) or 0
    local bonus = try(function() return e.consumption_bonus end) or 0
    local eff = try(function() return e.prototype.burner_prototype.effectivity end) or 1
    if eff <= 0 then eff = 1 end
    local per_tick = usage * math.max(0.2, 1 + bonus) / eff
    if per_tick <= 0 then return nil end
    return joules / per_tick / 3600, top, joules <= 0
  end
  local function working(e)
    local st = try(function() return e.status end)
    return st ~= nil and (st == defines.entity_status.working or st == defines.entity_status.low_power)
  end
  local function no_fuel(e)
    local st = try(function() return e.status end)
    return st ~= nil and st == defines.entity_status.no_fuel
  end

  -- One step: the next STEP fuel users of the current surface; at the end of a surface, its groups.
  local function step(st)
    local surfaces = {}
    for _, s in pairs(game.surfaces) do surfaces[#surfaces+1] = s end
    table.sort(surfaces, function(x, y) return x.index < y.index end)
    if #surfaces == 0 then return end
    if st.surface > #surfaces then st.surface = 1 end
    local s = surfaces[st.surface]
    local list = api.fuel_users and api.fuel_users(s) or {}
    local n = 0
    while n < STEP and st.i < #list do
      st.i = st.i + 1
      local e = list[st.i]
      if e and e.valid and not SKIP[e.type] and e.unit_number then
        n = n + 1
        local u = e.unit_number
        local f = st.fed[u]
        if not f or game.tick - f.tick >= FED_TTL then f = {tick=game.tick, fed=fed_by_inserter(e), had=f and f.had}; st.fed[u] = f end
        if not f.fed then
          local mins, item, out = M.minutes(e)
          local on = working(e)
          -- Out of fuel counts only for a machine seen working with fuel before (an abandoned one is not news).
          local dry = out and no_fuel(e) and f.had
          if on and not out then f.had = true end
          if mins and (dry or on and mins < LIMIT) then
            st.rows[u] = {e=e, name=e.name, pos={x=e.position.x, y=e.position.y}, mins=mins, item=item, out=dry or nil, force=e.force.name, surface=s.name}
          else st.rows[u] = nil end
        else st.rows[u] = nil end
      end
    end
    if st.i >= #list then
      M.groups(st, s.name)
      st.i = 0
      st.surface = st.surface + 1
    end
  end
  -- Groups of a surface's rows by name and 64-tile cell; a group under LIMIT is an alert (once, again after AGAIN).
  function M.groups(st, surface)
    local groups = {}
    for u, r in pairs(st.rows) do
      if not (r.e and r.e.valid) then st.rows[u] = nil; st.fed[u] = nil
      elseif r.surface == surface then
        local key = r.force .. '|' .. surface .. '|' .. r.name .. '|' .. math.floor(r.pos.x / 64) .. ',' .. math.floor(r.pos.y / 64)
        local g = groups[key]
        if not g then g = {key=key, name=r.name, surface=surface, force=r.force, n=0, out=0, low=0, first=nil, item=nil, x=0, y=0}; groups[key] = g end
        g.n = g.n + 1; g.x = g.x + r.pos.x; g.y = g.y + r.pos.y
        if r.out then g.out = g.out + 1 else g.low = g.low + 1; if not g.first or r.mins < g.first then g.first = r.mins end end
        g.item = g.item or r.item
      end
    end
    local keys = {}
    for key in pairs(groups) do keys[#keys+1] = key end
    table.sort(keys)
    for _, key in ipairs(keys) do
      local g = groups[key]
      if not st.told[key] or game.tick - st.told[key] >= AGAIN then
        st.told[key] = game.tick
        st.seq = st.seq + 1
        local parts = {}
        if g.low > 0 then parts[#parts+1] = string.format('%d run%s dry within %d min at full use (%s; the first in about %d min)', g.low, g.low == 1 and 's' or '',
          LIMIT, g.item or 'fuel', math.max(0, math.floor(g.first or 0))) end
        if g.out > 0 then parts[#parts+1] = string.format('%d %s out of fuel now', g.out, g.out == 1 and 'is' or 'are') end
        table.insert(st.alerts, {seq=st.seq, tick=game.tick, surface=g.surface, force=g.force,
          line=string.format('%s near %s%s, fed by hand or by order (no inserter brings them fuel): %s', g.name, at({x=g.x / g.n, y=g.y / g.n}),
            g.surface ~= 'nauvis' and ' on ' .. g.surface or '', table.concat(parts, '; '))})
      end
    end
    while #st.alerts > 0 and game.tick - st.alerts[1].tick > KEEP do table.remove(st.alerts, 1) end
    for key, t in pairs(st.told) do if game.tick - t > 2 * AGAIN then st.told[key] = nil end end
    for u, f in pairs(st.fed) do if game.tick - f.tick > 2 * FED_TTL then st.fed[u] = nil end end
  end
  function M.tick(tick)
    if tick % EVERY ~= 0 then return end
    local ok = pcall(step, store())
    return ok
  end
  -- team.alerts: lines after the last one this agent saw, for its force (its first reply: the last 2 minutes).
  function M.lines(p, h)
    local st = api.state().burnerfuel
    if not st or #st.alerts == 0 then return nil end
    local first = h.burnerfuel_seq == nil
    local out = {}
    for _, a in ipairs(st.alerts) do
      if a.force == p.force.name and #out < MAX_LINES and (first and game.tick - a.tick <= 7200 or not first and a.seq > h.burnerfuel_seq) then
        out[#out+1] = a.line
      end
    end
    h.burnerfuel_seq = st.seq
    return #out > 0 and out or nil
  end
  return M
end
