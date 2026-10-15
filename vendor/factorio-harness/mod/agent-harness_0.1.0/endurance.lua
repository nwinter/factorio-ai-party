-- platform_endurance (d15 trajectory analysis: Wayfarer was lost at Aquilo at 11:02 after its rockets, fuel and repair
-- packs ran out; nothing projected the trip before it left): for a planned route, each leg's length and time at the
-- platform's speed, and what its ammunition, repair packs, thruster fuel and oxidizer, power and hub space come to over
-- it at the rates the platform shows now. Facts the platform GUI and the production statistics give: no advice.
-- Rates: the platform surface's production statistics, last 10 minutes (made and used per minute, items and fluids);
-- stock: the hub's main inventory and the turrets (ammunition), the thrusters' and storage tanks' fluid (fuel,
-- oxidizer). Speed: the platform's now while it flies, else the average of its last finished leg (freight.lua's
-- record), else none (times unknown, said). Route: the stops given, else the schedule's from the current one round to
-- it again; a leg with no space connection between its ends is named.
return function(api)
  local M = {}
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function round(x, d) if d == 0 then return math.floor(x + 0.5) end local m = 10 ^ (d or 1); return math.floor(x * m + 0.5) / m end
  local function mins(m)
    if not m then return 'unknown' end
    if m >= 60 then return string.format('%dh%02dm', math.floor(m / 60), math.floor(m % 60)) end
    return string.format('%dm%02ds', math.floor(m), math.floor((m % 1) * 60))
  end
  -- The space connection between two locations: its length (km), or nil.
  local function connection(a, b)
    for _, c in pairs(try(function() return prototypes.space_connection end) or {}) do
      local f, t = try(function() return c.from.name end), try(function() return c.to.name end)
      if (f == a and t == b) or (f == b and t == a) then return try(function() return c.length end) end
    end
  end
  -- km per minute: flying now, else the last finished leg's average.
  local function speed(pl)
    local v = try(function() return pl.speed end)
    if type(v) == 'number' and v > 0 and try(function() return pl.space_connection end) then return v * 3600, 'now' end
    local segs = api.segments and api.segments(pl) or {}
    for i = #segs, 1, -1 do
      local s = segs[i]
      if s.kind == 'leg' and not s.partial and s['end'] and s.from and s.to and s['end'] > s.start then
        local len = connection(s.from, s.to)
        if len then return len / ((s['end'] - s.start) / 3600), string.format('the last leg %s->%s', s.from, s.to) end
      end
    end
    return nil, nil
  end
  -- The route as stops: given, else the schedule from its current record round to it.
  local function route_of(pl, given)
    if given ~= nil then
      assert(type(given) == 'table' and #given >= 1 and #given <= 12, 'route is a list of 1..12 space locations (planet names)')
      for _, n in ipairs(given) do assert(type(n) == 'string' and prototypes.space_location[n], 'route: unknown space location ' .. tostring(n)) end
      return given, 'given'
    end
    local sch = try(function() return pl.schedule end)
    local recs = sch and sch.records or {}
    local out = {}
    local cur = sch and sch.current or 1
    for k = 0, #recs - 1 do
      local r = recs[(cur - 1 + k) % #recs + 1]
      if r and r.station then out[#out+1] = r.station end
    end
    if #recs > 0 then out[#out+1] = out[1] end
    return out, 'schedule'
  end
  local function fluid_stock(pl, names)
    local out = {}
    for _, e in ipairs(try(function() return pl.surface.find_entities_filtered{type={'thruster', 'storage-tank'}, force=pl.force} end) or {}) do
      for i = 1, try(function() return #e.fluidbox end) or 0 do
        local f = try(function() return e.fluidbox[i] end)
        if f and names[f.name] then out[f.name] = (out[f.name] or 0) + f.amount end
      end
    end
    return out
  end
  function M.read(p, a)
    assert(type(a.platform) == 'string', 'platform is required (a platform name)')
    local pl = api.platform(p, a.platform)
    assert(pl.surface, 'platform ' .. pl.name .. ' has no surface yet')
    local stops, route_by = route_of(pl, a.route)
    local v, v_by = speed(pl)
    -- Legs: from where it is (the rest of the leg it flies), then stop to stop.
    local legs, total_km = {}, 0
    local leg_now = api.leg and api.leg(pl)
    local here = try(function() return pl.space_location.name end)
    local start = here
    if leg_now then
      legs[#legs+1] = {from=leg_now.from, to=leg_now.to, km=round(leg_now.left_km, 0), now=true}
      total_km = total_km + leg_now.left_km
      start = leg_now.to
      if stops[1] == start then table.remove(stops, 1) end
    elseif here and stops[1] == here then table.remove(stops, 1) end
    local from = start
    for _, to in ipairs(stops) do
      if from and to ~= from then
        local len = connection(from, to)
        legs[#legs+1] = {from=from, to=to, km=len and round(len, 0) or nil, none=len == nil or nil}
        total_km = total_km + (len or 0)
      end
      from = to
    end
    local total_min = v and v > 0 and total_km / v or nil
    for _, l in ipairs(legs) do l.minutes = v and v > 0 and l.km and round(l.km / v, 1) or nil end
    -- Rates and stock.
    local items_stats = try(function() return pl.force.get_item_production_statistics(pl.surface) end)
    local fluid_stats = try(function() return pl.force.get_fluid_production_statistics(pl.surface) end)
    local P = defines.flow_precision_index or {}
    local function rate(stats, name, cat) return stats and P.ten_minutes and (try(function() return stats.get_flow_count{name=name, category=cat, precision_index=P.ten_minutes, count=true} end) or 0) / 10 or 0 end
    local hub = try(function() return pl.hub.get_inventory(defines.inventory.hub_main) end)
    local held = {}
    for _, r in ipairs(hub and try(function() return hub.get_contents() end) or {}) do held[r.name] = (held[r.name] or 0) + r.count end
    for _, t in ipairs(try(function() return pl.surface.find_entities_filtered{type='ammo-turret', force=pl.force} end) or {}) do
      local inv = try(function() return t.get_inventory(defines.inventory.turret_ammo) end)
      for _, r in ipairs(inv and try(function() return inv.get_contents() end) or {}) do held[r.name] = (held[r.name] or 0) + r.count end
    end
    local rows = {}
    -- What the machines aboard can still make of an item from the ingredients aboard (Astra, d15 15:39: parked Aegis
    -- projected rockets 1030 + 36/min to 2650 while about 500 explosives' worth of ingredients were left): the
    -- assemblers whose recipe makes it, their recipe's item ingredients in the hub and in those machines' inputs, one
    -- level down (an ingredient made aboard too is named with its rate, not counted ahead).
    local makers
    local function ceiling(name)
      makers = makers or try(function() return pl.surface.find_entities_filtered{type='assembling-machine', force=pl.force} end) or {}
      local rec, per, inputs = nil, 0, {}
      for _, m in ipairs(makers) do
        local r = try(function() return m.get_recipe() end)
        local made_here = 0
        for _, pr in ipairs(r and try(function() return r.products end) or {}) do
          if pr.name == name then made_here = (pr.amount or ((pr.amount_min or 0) + (pr.amount_max or 0)) / 2) * (pr.probability or 1) end
        end
        if made_here > 0 then
          rec, per = r, made_here
          local inv = try(function() return m.get_inventory(defines.inventory.assembling_machine_input) end)
          for _, c in ipairs(inv and try(function() return inv.get_contents() end) or {}) do inputs[c.name] = (inputs[c.name] or 0) + c.count end
        end
      end
      if not rec then return nil end
      local best
      for _, ing in ipairs(try(function() return rec.ingredients end) or {}) do
        if ing.type ~= 'fluid' and (ing.amount or 0) > 0 then
          local have = (held[ing.name] or 0) + (inputs[ing.name] or 0)
          local more = math.floor(have / ing.amount) * per
          if not best or more < best.more then best = {more=math.floor(more), item=ing.name, have=have, per_craft=ing.amount} end
        end
      end
      if best then best.ingredient_made_per_min = round(rate(items_stats, best.item, 'input'), 1) end
      return best
    end
    -- A rate measured where it is now: flying, the last 10 minutes; stopped, the last finished leg's (ammunition, from
    -- freight.lua's counts at its ends), else unknown (Astra, d15 15:39: parked, thruster fuel read 0 made and 0 used,
    -- which read as lasting for ever): a stop's rate is not a flight's.
    local flying = leg_now ~= nil
    local last_leg
    if not flying then
      local segs = api.segments and api.segments(pl) or {}
      for k = #segs, 1, -1 do
        local sg = segs[k]
        if sg.kind == 'leg' and not sg.partial and sg['end'] and sg['end'] > sg.start and sg.ammo0 and sg.ammo1 then last_leg = sg; break end
      end
    end
    local function leg_rate(name)
      if not last_leg then return nil end
      local m = (last_leg['end'] - last_leg.start) / 3600
      local a, b = last_leg.ammo0[name] or {made=0, used=0}, last_leg.ammo1[name] or {made=0, used=0}
      return math.max(0, b.made - a.made) / m, math.max(0, b.used - a.used) / m, string.format('over the last leg %s->%s, %s', last_leg.from or '?', last_leg.to or '?', mins(m))
    end
    local function project(name, stock, made, used, unit, from, unknown)
      local row = {name=name, stock=round(stock, 0), made_per_min=round(made, 1), used_per_min=round(used, 1), rate_from=from}
      unit = unit or ''
      if unknown then
        row.flight_rate = 'unknown'
        row.line = string.format('%s: %s%s now; flight use unknown: %s (at the stop, last 10 min: made %g/min, used %g/min)', name, row.stock, unit, from, row.made_per_min, row.used_per_min)
        rows[#rows+1] = row
        return
      end
      local cap = made > 0 and unit == '' and ceiling(name) or nil
      if cap then row.ingredient_limited = cap end
      local more = cap and cap.more or math.huge
      local function at(t) return stock + math.min(made * t, more) - used * t end
      if total_min then row.at_end = round(at(total_min), 0) end
      if used > 0 then
        -- when the stock reaches 0: before the ingredients run out, or after (then at the use rate alone)
        local t1 = made > 0 and more / made or 0
        local net = made - used
        local lasts
        if net < 0 and stock / -net <= t1 then lasts = stock / -net
        elseif more < math.huge or made == 0 then local s1 = at(t1); lasts = t1 + math.max(0, s1) / used end
        if lasts then
          row.lasts_min = round(lasts, 1)
          local t = 0
          for _, l in ipairs(legs) do
            t = t + (l.minutes or 0)
            if l.minutes and t >= row.lasts_min then row.runs_out_on = l.from .. '->' .. l.to; break end
          end
        end
      end
      row.line = string.format('%s: %s%s now, made %g/min, used %g/min (%s)%s%s%s', name, row.stock, unit, row.made_per_min, row.used_per_min, from,
        cap and string.format('; ingredient-limited: the ingredients aboard make at most %d more (%s %d aboard, %g a craft%s)', cap.more, cap.item, cap.have, cap.per_craft,
          cap.ingredient_made_per_min > 0 and string.format('; %s made %g/min aboard', cap.item, cap.ingredient_made_per_min) or '') or '',
        row.lasts_min and string.format('; lasts %s at that rate%s', mins(row.lasts_min), row.runs_out_on and ' (runs out on ' .. row.runs_out_on .. ')'
          or (total_min and row.lasts_min >= total_min and ' (past the route\'s end)' or '')) or '',
        row.at_end and string.format('; at the route\'s end about %d%s', math.max(0, row.at_end), unit) or '')
      rows[#rows+1] = row
    end
    local ammo = {}
    for name, item in pairs(prototypes.item) do if item.type == 'ammo' or item.type == 'repair-tool' then ammo[#ammo+1] = name end end
    table.sort(ammo)
    for _, name in ipairs(ammo) do
      local made, used = rate(items_stats, name, 'input'), rate(items_stats, name, 'output')
      if (held[name] or 0) > 0 or made > 0 or used > 0 then
        if flying then project(name, held[name] or 0, made, used, nil, 'last 10 min, flying')
        else
          local lm, lu, from = nil, nil, nil
          if prototypes.item[name].type == 'ammo' then lm, lu, from = leg_rate(name) end
          if lm then project(name, held[name] or 0, lm, lu, nil, from)
          else project(name, held[name] or 0, made, used, nil, 'stopped, and no finished leg on record for it', true) end
        end
      end
    end
    local fluids = {['thruster-fuel']=true, ['thruster-oxidizer']=true}
    local fstock = fluid_stock(pl, fluids)
    for _, name in ipairs({'thruster-fuel', 'thruster-oxidizer'}) do
      if try(function() return prototypes.fluid[name] end) then
        local made, used = rate(fluid_stats, name, 'input'), rate(fluid_stats, name, 'output')
        if (fstock[name] or 0) > 0 or made > 0 or used > 0 then
          if flying then project(name, fstock[name] or 0, made, used, ' units', 'last 10 min, flying')
          else project(name, fstock[name] or 0, made, used, ' units', 'stopped; the thrusters burn only in flight', true) end
        end
      end
    end
    -- Hub space: free slots now.
    local slots = hub and #hub or 0
    local free = hub and try(function() return hub.count_empty_stacks() end) or 0
    -- Power: what the platform's network makes and draws now (a pole on it), and the solar power at each stop.
    local power
    local pole = try(function() return pl.surface.find_entities_filtered{type='electric-pole', force=pl.force, limit=1}[1] end)
    local st = pole and try(function() return pole.electric_network_statistics end)
    if st and P.five_seconds then
      local function sum(cat, counts)
        local n = 0
        for name in pairs(counts or {}) do n = n + (try(function() return st.get_flow_count{name=name, category=cat, precision_index=P.five_seconds} end) or 0) end
        return n * 60 / 1000
      end
      power = string.format('makes %d kW, draws %d kW now', math.floor(sum('output', st.output_counts) + 0.5), math.floor(sum('input', st.input_counts) + 0.5))
    end
    local solar = {}
    local seen = {}
    for _, l in ipairs(legs) do
      for _, n in ipairs({l.from, l.to}) do
        if n and not seen[n] then
          seen[n] = true
          local sp = try(function() return prototypes.space_location[n].solar_power_in_space end)
          if sp then solar[#solar+1] = string.format('%s %d%%', n, math.floor(sp + 0.5)) end
        end
      end
    end
    local legs_text = {}
    for _, l in ipairs(legs) do
      legs_text[#legs_text+1] = string.format('%s->%s %s km, %s%s', l.from, l.to, l.km and tostring(l.km) or '?', l.minutes and mins(l.minutes) or 'time unknown',
        l.now and ' (the rest of the leg it flies)' or l.none and ' (no space connection between them)' or '')
    end
    return {platform=pl.name, route=route_by, legs=legs, total_km=round(total_km, 0), total_minutes=total_min and round(total_min, 1) or nil,
      speed_km_per_min=v and round(v, 1) or nil, speed_from=v_by or 'unknown: stopped, and no finished leg on record (times unknown)',
      resources=rows, hub_slots=string.format('%d of %d free', free, slots), power=power, solar_power=#solar > 0 and table.concat(solar, ', ') or nil,
      lines={'route: ' .. (#legs_text > 0 and table.concat(legs_text, '; ') or 'no legs') .. (total_min and '; in all ' .. mins(total_min) or ''),
        'hub: ' .. string.format('%d of %d slots free', free, slots) .. (power and '; power ' .. power or '') .. (#solar > 0 and '; solar power ' .. table.concat(solar, ', ') or '')},
      note='rates: flying, the platform\'s production statistics over the last 10 minutes; stopped, the last finished leg\'s for ammunition (rate_from), else the flight rate is unknown and nothing is projected; a rate that changes on the way (fights near a planet, thrust) changes the projection'}
  end
  M.schema = {platform_endurance = {platform='platform name', route='optional list of space locations to fly through in order (default: its schedule from the current stop round to it again)',
    returns='legs [{from, to, km, minutes}], total_km, total_minutes, speed_km_per_min and speed_from (now while flying, else the last finished leg\'s average), resources [{name, stock, made_per_min, used_per_min, rate_from, flight_rate (unknown: stopped with no flight rate on record; nothing projected), ingredient_limited {more, item, have, per_craft, ingredient_made_per_min} (made from ingredients aboard: at most more), lasts_min, runs_out_on, at_end, line}] for each ammunition and repair pack aboard or used, thruster-fuel and thruster-oxidizer, hub_slots, power, solar_power at the stops, lines; read only'}}
  return M
end
