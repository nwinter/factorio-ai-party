-- fuel_budget (Opus, d15 06:20 and 07:50, asked twice: "fuel starvation was behind most stalls this shift and I found
-- it only by chaining bottleneck calls"): per surface, each fuel item made and used per minute (the production
-- statistics, last 10 minutes), and each group of fuel users with what it burns per minute and the minutes its own fuel
-- lasts at that rate: boilers, furnaces, burner drills, burner inserters, heating towers, burner generators (their
-- burners), and machines whose recipe takes a fuel item (plastic-bar from coal, ...) by recipe.
-- The users come from the census's last pass (entity references, census.lua); their state is read now: status, the
-- fuel inventory (an ingredient user: its input), and the burn rate a player reads in the tooltips: a burner's energy
-- use (with its consumption bonus) over the fuel's value and the burner's effectivity, for each one working now; an
-- ingredient user's crafting speed over the recipe's time, times the amount. Fuel on its way (feeding chests, belts,
-- inserter hands) is not counted. At most MAX entities are read a call; the read is kept 10 seconds.
return function(api)
  local M = {}
  local MAX, KEEP = 2048, 600
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function round(x, d) local m = 10 ^ (d or 1); return math.floor(x * m + 0.5) / m end
  local GROUP = {boiler='boilers', furnace='furnaces', ['mining-drill']='burner drills', inserter='burner inserters',
    reactor='heating towers and reactors', ['burner-generator']='burner generators', ['assembling-machine']='burner assemblers'}
  local WORKING = {}
  local function working(e)
    local st = try(function() return e.status end)
    if st == nil then return false end
    if not next(WORKING) then
      for _, k in ipairs({'working', 'low_power'}) do local v = defines.entity_status[k]; if v then WORKING[v] = true end end
    end
    return WORKING[st] == true
  end
  local function status_name(e)
    if api.status_name then return try(function() return api.status_name(e) end) or 'unknown' end
    return 'unknown'
  end
  local function fuel_value(item) return try(function() return prototypes.item[item].fuel_value end) or 0 end
  local function inv_counts(inv, only_fuel)
    local out = {}
    for _, row in ipairs(inv and try(function() return inv.get_contents() end) or {}) do
      local name = row.name
      if type(name) ~= 'string' then name = try(function() return name.name end) end
      if name and (not only_fuel or fuel_value(name) > 0) then out[name] = (out[name] or 0) + (row.count or 0) end
    end
    return out
  end
  -- What a working burner burns per minute of `item`: energy per tick * 3600 / (fuel value * effectivity).
  local function burn_per_min(e, item)
    local fv = fuel_value(item)
    if fv <= 0 then return 0 end
    local q = try(function() return e.quality end)
    local usage = try(function() return e.prototype.get_max_energy_usage(q) end) or try(function() return e.prototype.max_energy_usage end) or 0
    local bonus = try(function() return e.consumption_bonus end) or 0
    local eff = try(function() return e.prototype.burner_prototype.effectivity end) or 1
    if eff <= 0 then eff = 1 end
    return usage * math.max(0.2, 1 + bonus) * 3600 / (fv * eff)
  end
  local function recipe_of(e)
    local r = try(function() return e.get_recipe() end)
    return r and (prototypes.recipe[r.name] or r) or nil
  end
  -- One group per burner type (heating towers by name too), one per fuel-taking recipe.
  local function read_users(list)
    local groups, order, read = {}, {}, 0
    local function group(key)
      local g = groups[key]
      if not g then g = {key=key, n=0, working=0, states={}, held={}, burn={}, empty=0, reactors={}}; groups[key] = g; order[#order+1] = g end
      return g
    end
    for _, e in ipairs(list or {}) do
      if read >= MAX then break end
      if e.valid then
        read = read + 1
        local burner = try(function() return e.burner end)
        local recipe = not burner and recipe_of(e) or nil
        local key = burner and (e.type == 'reactor' and e.name ~= 'nuclear-reactor' and 'heating towers' or GROUP[e.type] or e.type)
          or (recipe and 'recipe ' .. recipe.name) or nil
        if key then
          local g = group(key)
          g.n = g.n + 1
          local on = working(e)
          if on then g.working = g.working + 1 end
          local st = status_name(e)
          g.states[st] = (g.states[st] or 0) + 1
          if burner and e.type == 'reactor' then g.reactors[#g.reactors+1] = e end
          if burner then
            local held = inv_counts(try(function() return e.get_fuel_inventory() end), true)
            local any, top, topn = false, nil, 0
            for item, n in pairs(held) do
              g.held[item] = (g.held[item] or 0) + n; any = true
              if n > topn then top, topn = item, n end
            end
            if not top then
              local cb = try(function() return burner.currently_burning end)
              top = cb and (type(cb.name) == 'string' and cb.name or try(function() return cb.name.name end) or try(function() return cb.name end))
              if type(top) ~= 'string' then top = nil end
            end
            if not any then g.empty = g.empty + 1 end
            if on and top then g.burn[top] = (g.burn[top] or 0) + burn_per_min(e, top) end
          else
            local speed = try(function() return e.crafting_speed end) or 1
            local energy = try(function() return recipe.energy end) or 1
            local input = try(function() return e.get_inventory(defines.inventory.assembling_machine_input) end)
            local held = inv_counts(input, true)
            for _, ing in ipairs(try(function() return recipe.ingredients end) or {}) do
              if (ing.type == nil or ing.type == 'item') and fuel_value(ing.name) > 0 then
                g.held[ing.name] = (g.held[ing.name] or 0) + (held[ing.name] or 0)
                if on then g.burn[ing.name] = (g.burn[ing.name] or 0) + speed / math.max(energy, 0.01) * (ing.amount or 1) * 60 end
              end
            end
          end
        end
      end
    end
    return order, read
  end
  local function states_text(g)
    local parts = {}
    for st, n in pairs(g.states) do parts[#parts+1] = {st, n} end
    table.sort(parts, function(x, y) if x[2] ~= y[2] then return x[2] > y[2] end return x[1] < y[1] end)
    local out = {}
    for i = 1, math.min(4, #parts) do out[i] = parts[i][2] .. ' ' .. parts[i][1] end
    return table.concat(out, ', ')
  end
  local function group_row(g)
    local items, seen = {}, {}
    for item in pairs(g.burn) do if not seen[item] then seen[item] = true; items[#items+1] = item end end
    for item in pairs(g.held) do if not seen[item] then seen[item] = true; items[#items+1] = item end end
    table.sort(items)
    local per, parts = {}, {}
    for _, item in ipairs(items) do
      local b, h = g.burn[item] or 0, g.held[item] or 0
      local mins = b > 0 and h / b or nil
      per[#per+1] = {item=item, burn_per_min=round(b, 1), held=h, minutes_left=mins and round(mins, 1) or nil}
      parts[#parts+1] = string.format('%s: burns about %g/min, holds %d%s', item, round(b, 1), h,
        mins and string.format(' (about %g min at that rate)', round(mins, 1)) or '')
    end
    local line = string.format('%s: %d (%s)%s%s', g.key, g.n, states_text(g), #parts > 0 and '; ' .. table.concat(parts, '; ') or '; no fuel held',
      g.empty > 0 and string.format('; %d with empty fuel slots', g.empty) or '')
    local worst
    for _, r in ipairs(per) do if r.minutes_left and (not worst or r.minutes_left < worst) then worst = r.minutes_left end end
    local row = {group=g.key, machines=g.n, working=g.working, states=states_text(g), fuel=per, empty_fuel=g.empty > 0 and g.empty or nil,
      minutes_left=worst, line=line}
    -- (d20 batch63 Y1, Astra #1512) reactors one by one: heat, the fuel burning, slots, the feed and its circuit control;
    -- the group's minutes from those, empty slots apart from no heat and no fuel to be had (fuelreactor.lua)
    if #g.reactors > 0 and api.reactors then
      local r = api.reactors.group(g.reactors)
      if #r.reactors > 0 then
        row.reactors = r.reactors
        row.reactors_more = r.more and string.format('%d more not read one by one (at most 12 a group)', r.more) or nil
        row.empty_fuel = nil
        row.empty_slots = r.empty_slots > 0 and r.empty_slots or nil
        row.minutes_left = r.minutes_left
        row.network_stock = r.network_stock
        if r.emergencies > 0 then
          row.emergency = string.format('%d reactor%s with no heat left and no fuel to be had (none burning, none in its slots, its feeders or the logistic network)',
            r.emergencies, r.emergencies == 1 and '' or 's')
        end
        local nets = {}
        for it, n in pairs(r.network_stock or {}) do nets[#nets+1] = n .. ' ' .. it end
        table.sort(nets)
        row.line = string.format('%s: %d (%s); %d burning%s%s; %s%s%s', g.key, g.n, states_text(g), r.burning,
          r.empty_slots > 0 and string.format(', %d with fuel slots empty', r.empty_slots) or '',
          r.held_back > 0 and string.format(', %d with feed held back by a circuit', r.held_back) or '',
          r.minutes_left and string.format('fewest minutes left about %g (heat, burning fuel, slots and feed)', r.minutes_left) or 'none fed by an inserter', #nets > 0 and '; logistic network holds ' .. table.concat(nets, ', ') or '',
          row.emergency and '; EMERGENCY: ' .. row.emergency or '')
        for _, f in ipairs(per) do
          f.minutes_left = nil
        end
      end
    end
    return row
  end
  local cache = {}
  function M.read(p, a)
    a = a or {}
    local surface = p.surface
    if a.surface ~= nil then
      assert(type(a.surface) == 'string', 'surface must be a surface name')
      surface = game.get_surface(a.surface)
      assert(surface, 'no surface ' .. a.surface)
    end
    -- boilers: true (D7): each boiler group's burn against the fuel in reach of it and the drills supplying it (fuelhours.lua)
    assert(a.boilers == nil or type(a.boilers) == 'boolean', 'boilers must be true or false')
    if a.boilers then
      local key = 'boilers|' .. tostring(surface.index) .. '|' .. p.force.name
      local c = cache[key]
      if c and game.tick - c.tick < KEEP and c.out then return c.out end
      M.hours = M.hours or require('fuelhours'){status_name=api.status_name, belt_line=api.belt_line}
      local out = M.hours.read(p, a, surface)
      out.surface_name = surface.name
      cache[key] = {tick=game.tick, out=out}
      return out
    end
    local key = tostring(surface.index) .. '|' .. p.force.name
    local c = cache[key]
    if c and game.tick - c.tick < KEEP and c.out then return c.out end
    local list, as_of = api.fuel_users(surface)
    local groups, read = read_users(list)
    local rows = {}
    for _, g in ipairs(groups) do rows[#rows+1] = group_row(g) end
    table.sort(rows, function(x, y)
      if (x.minutes_left or math.huge) ~= (y.minutes_left or math.huge) then return (x.minutes_left or math.huge) < (y.minutes_left or math.huge) end
      return x.group < y.group
    end)
    -- Made and used per minute of each fuel item the groups burn or hold (and coal, solid fuel by default).
    local items, seen = {}, {}
    local function add(i) if not seen[i] and prototypes.item[i] then seen[i] = true; items[#items+1] = i end end
    for _, g in ipairs(groups) do for i in pairs(g.burn) do add(i) end; for i in pairs(g.held) do add(i) end end
    add('coal'); add('solid-fuel')
    table.sort(items)
    local stats = try(function() return p.force.get_item_production_statistics(surface) end)
    local flows = {}
    for _, item in ipairs(items) do
      local function flow(cat)
        local n = stats and try(function() return stats.get_flow_count{name=item, category=cat, precision_index=defines.flow_precision_index.ten_minutes, count=true} end)
        return n and n / 10 or 0
      end
      local made, used = flow('input'), flow('output')
      local burn = 0
      for _, g in ipairs(groups) do burn = burn + (g.burn[item] or 0) end
      if made > 0 or used > 0 or burn > 0 then
        -- (d20 batch122 CE2, viewer Aurora 10:13) a fuel that spoils (nutrients, jelly, eggs): what the statistics leave out
        local spoiling = api.spoilflow and api.spoilflow.text(p.force, surface, item) or nil
        flows[#flows+1] = {item=item, made_per_min=round(made, 1), used_per_min=round(used, 1), groups_burn_per_min=round(burn, 1), spoiling=spoiling,
          line=string.format('%s: made %g/min, used %g/min (production statistics, last 10 min); the groups below burn about %g/min working as now%s',
            item, round(made, 1), round(used, 1), round(burn, 1), spoiling and ' (' .. spoiling .. ')' or '')}
      end
    end
    local out = {surface=surface.name, as_of=as_of, pending=as_of == nil or nil, items=flows, groups=rows,
      read=read, capped=(list and #list > read) and string.format('%d of %d fuel users read', read, #list) or nil,
      note='burn rates: each working machine at its energy use (a burner) or crafting speed (a fuel ingredient), as the tooltips give them; minutes_left: the fuel in the group\'s own slots at that rate; fuel in chests, on belts and in inserter hands is not counted, except for reactors and heating towers (reactors: their heat, burning fuel and the stock their feeders reach)'}
    if as_of == nil then out.pending = 'the census has not finished its first pass yet: no fuel users listed' end
    cache[key] = {tick=game.tick, out=out}
    return out
  end
  M.schema = {fuel_budget = {surface='optional surface name (default yours)',
    boilers='optional true (D7, Opus: slow brownouts seen late): the boilers in groups (within 8 tiles of each other), each with its burn a minute at full use, the fuel in their slots, in the chests and on the belt tiles feeding them (walked back), the drills dropping onto those belts and what they put on at full speed, the balance and the hours left when the burn is more: groups [{near, boilers, working, fuel, burn_per_min, held, in_chests, chests, on_belts, belt_tiles, drills, drills_working, supply_per_min, balance_per_min, hours_left}] (fewest hours first), lines, surface (each fuel made and used a minute, what the logistic networks hold); kept 10 s',
    returns='surface, as_of (the census pass the users come from; their state is read now), items [{item, made_per_min, used_per_min (production statistics, last 10 min; used counts fuel burned), groups_burn_per_min, spoiling (a fuel that spoils: the statistics leave spoiling out; what left uncounted a minute when a whole-surface supply measured it in the last 30 min), line}], groups (fewest minutes first) [{group (boilers, furnaces, burner drills, burner inserters, heating towers, burner generators, or recipe NAME for machines whose recipe takes a fuel item), machines, working, states, fuel [{item, burn_per_min (working machines at full use), held (in their fuel slots, or an ingredient user\'s input), minutes_left}], empty_fuel, minutes_left (the group\'s fewest), line}], read, capped, note; kept 10 seconds; fuel in chests, belts and hands is not counted; reactors and heating towers one by one: reactors [{temperature, burning {item, left, minutes}, fuel_slots, burnt, circuit_reads, feeders [{condition (as its GUI shows it, with the values on its wires), holds_fuel_back, set_by, hand, takes_from}], feed {in_reach, network}, state, minutes_left, minutes {heat, burning, slots, feed, heat_above}, emergency, line}], empty_slots, network_stock, emergency (fed by inserters, no heat and no fuel to be had); their minutes_left from heat, burning fuel, slots and feed'}}
  return M
end
