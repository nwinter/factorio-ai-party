-- fuel_budget's reactors one by one (d20 batch63 Y1, Astra #1512: at tick 40275273 fuel_budget said 6 reactors with
-- empty fuel slots and 0 minutes left while all 6 worked: each burned the one uranium fuel cell its circuit lets in
-- (a decider: temperature < 800 and fuel < 1 -> S=1, the inserter enabled by S > 0), and requesters held 11 each).
-- Per reactor what its GUI and tooltip show: the temperature, the fuel burning and how much of it is left, the fuel
-- and burnt slots, its circuit reads; the inserters feeding it with their circuit or logistic condition as their GUI
-- shows it (holding fuel back or not, the combinators setting that signal), their hands and the chests they take from;
-- the logistic network's stock of its fuel. Minutes left: the heat above what the heat exchangers need (500 C in
-- 2.0.77) at the reactor's full output (its energy use with the neighbour bonus), plus the fuel burning, in the slots
-- and in reach of its feeders at its burn rate (its energy use over the fuel's value and the burner's effectivity, as
-- the existing rates). Empty slots alone are no emergency: only a reactor with no heat left and no fuel to be had.
return function(api)
  local M = {}
  -- (on the private copy: about 0.4 ms a reactor, 0.3 ms more a feeder's combinator trace)
  local MAX_DETAIL, TRACES = 12, 3
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function round(x, d) local m = 10 ^ (d or 1); return math.floor(x * m + 0.5) / m end
  local function at(pos) return string.format('(%g,%g)', pos.x, pos.y) end
  local function fuel_value(item) return try(function() return prototypes.item[item].fuel_value end) or 0 end
  local function name_of(v)
    if type(v) == 'string' then return v end
    return try(function() return v.name end) and (type(v.name) == 'string' and v.name or try(function() return v.name.name end))
  end
  -- The heat exchangers' minimum temperature (500 C in 2.0.77), read once.
  local exchanger_min
  local function floor_for(e)
    if exchanger_min == nil then
      exchanger_min = try(function() return prototypes.entity['heat-exchanger'].heat_energy_source_prototype.min_working_temperature end) or false
    end
    local near = exchanger_min and try(function()
      return e.surface.count_entities_filtered{position=e.position, radius=16, type='boiler', name='heat-exchanger', force=e.force, limit=1}
    end) or 0
    if near > 0 then return exchanger_min, 'the heat exchangers\' minimum' end
    return try(function() return e.prototype.heat_buffer_prototype.min_working_temperature end) or 15, 'the reactor\'s minimum'
  end
  -- Fuel items a burner takes, by its fuel categories (cached per prototype).
  local cats_cache = {}
  local function fuels_for(e)
    local key = e.name
    if cats_cache[key] then return cats_cache[key] end
    local cats = try(function() return e.prototype.burner_prototype.fuel_categories end) or {}
    local list = {}
    for name, it in pairs(prototypes.item) do
      local c = try(function() return it.fuel_category end)
      if c and cats[c] then list[#list+1] = name end
    end
    table.sort(list)
    cats_cache[key] = list
    return list
  end
  local function contents(inv)
    local out, n = {}, 0
    for _, row in ipairs(inv and try(function() return inv.get_contents() end) or {}) do
      local nm = name_of(row.name) or row.name
      if type(nm) == 'string' then out[nm] = (out[nm] or 0) + (row.count or 0); n = n + (row.count or 0) end
    end
    return out, n
  end
  local function list_text(t)
    local parts = {}
    for k, v in pairs(t) do parts[#parts+1] = v .. ' ' .. k end
    table.sort(parts)
    return table.concat(parts, ', ')
  end
  -- The inserters dropping into e.
  local function feeders(e)
    local b = e.bounding_box
    local area = {left_top={x=b.left_top.x-3, y=b.left_top.y-3}, right_bottom={x=b.right_bottom.x+3, y=b.right_bottom.y+3}}
    local out = {}
    for _, ins in pairs(try(function() return e.surface.find_entities_filtered{area=area, type='inserter', force=e.force, limit=32} end) or {}) do
      if ins.valid and try(function() return ins.drop_target end) == e then out[#out+1] = ins end
    end
    return out
  end
  -- One reactor. Returns its row and what the group sums.
  function M.reactor(e, budget)
    local burner = e.burner
    local q = try(function() return e.quality end)
    local usage = try(function() return e.prototype.get_max_energy_usage(q) end) or try(function() return e.prototype.max_energy_usage end) or 0
    local eff = try(function() return burner.effectivity end) or try(function() return e.prototype.burner_prototype.effectivity end) or 1
    if eff <= 0 then eff = 1 end
    local bonus = try(function() return e.neighbour_bonus end) or 0
    local fuel_per_min = usage * 3600 / eff        -- fuel energy a minute while it burns
    local heat_per_min = usage * (1 + bonus) * 3600 -- heat a minute at its full output
    local temp = try(function() return e.temperature end) or 0
    local maxt = try(function() return e.prototype.heat_buffer_prototype.max_temperature end)
    local spec = try(function() return e.prototype.heat_buffer_prototype.specific_heat end) or 0
    local floor, floor_why = floor_for(e)
    local heat_j = math.max(0, temp - floor) * spec
    local row = {name=e.name, position=e.position, temperature=round(temp, 0), max_temperature=maxt, neighbour_bonus=bonus > 0 and bonus or nil,
      status=api.status_name and try(function() return api.status_name(e) end) or nil}
    -- Burning now: the item and what is left of it (the bar under the fuel slot).
    local cb = try(function() return burner.currently_burning end)
    local item = cb and name_of(cb.name or cb)
    local left_j = try(function() return burner.remaining_burning_fuel end) or 0
    if item and left_j > 0 then
      local fv = fuel_value(item)
      row.burning = {item=item, left=fv > 0 and round(left_j / fv, 2) or nil, minutes=fuel_per_min > 0 and round(left_j / fuel_per_min, 1) or nil}
    end
    -- Fuel slots and burnt slots.
    local held, nheld = contents(try(function() return burner.inventory end))
    local slots = try(function() return #burner.inventory end) or 0
    local burnt, nburnt = contents(try(function() return burner.burnt_result_inventory end))
    local burnt_full = try(function() local inv = burner.burnt_result_inventory; return #inv > 0 and not inv.can_insert({name=next(burnt) or 'depleted-uranium-fuel-cell', count=1}) end)
    local slots_j = 0
    for it, n in pairs(held) do slots_j = slots_j + n * fuel_value(it) end
    row.fuel_slots = {slots=slots, holds=nheld > 0 and held or nil, empty=nheld == 0 or nil}
    if nburnt > 0 then row.burnt = {holds=burnt, full=burnt_full or nil} end
    -- Its circuit reads (the reactor's GUI: read fuel, read temperature with its signal).
    local rcb = try(function() return e.get_control_behavior() end)
    if rcb then
      local reads = {}
      if try(function() return rcb.read_fuel end) then reads[#reads+1] = 'its fuel' end
      if try(function() return rcb.read_temperature end) then
        local sig = try(function() return rcb.temperature_signal end)
        reads[#reads+1] = 'its temperature' .. (sig and sig.name and ' as ' .. sig.name or '')
      end
      if #reads > 0 then row.circuit_reads = table.concat(reads, ' and ') .. ' onto its wires' end
    end
    -- The fuel it takes; the feeders, their conditions, hands and the chests they take from.
    local fuels = fuels_for(e)
    local main = item or next(held)
    local feed_j, feed_n, control, from, held_back = 0, 0, {}, {}, false
    local network
    local ins_list = feeders(e)
    for i, ins in ipairs(ins_list) do
      if i > 4 then break end
      local f = {position=ins.position, name=ins.name}
      local h = try(function() return ins.held_stack end)
      if h and h.valid_for_read and fuel_value(h.name) > 0 then
        f.hand = h.count .. ' ' .. h.name; feed_n = feed_n + h.count; feed_j = feed_j + h.count * fuel_value(h.name)
        main = main or h.name
      end
      local pick = try(function() return ins.pickup_target end)
      if pick and pick.valid then
        local inv = try(function() return pick.get_output_inventory() end) or try(function() return pick.get_inventory(defines.inventory.chest) end)
        local c = {}
        for _, fu in ipairs(fuels) do
          local n = inv and try(function() return inv.get_item_count(fu) end) or 0
          if n > 0 then c[fu] = n; feed_n = feed_n + n; feed_j = feed_j + n * fuel_value(fu); main = main or fu end
        end
        f.takes_from = string.format('%s %s%s', pick.name, at(pick.position), next(c) and ' holding ' .. list_text(c) or ' holding none of its fuel')
        network = network or try(function() return pick.logistic_network end) or try(function() return e.surface.find_logistic_network_by_position(pick.position, e.force) end)
      end
      -- Its conditions as its GUI shows them, the values on its wires, whether it is off by them.
      local parts = api.condition_parts and try(function() return api.condition_parts(ins) end)
      if parts and #parts > 0 then
        f.condition = table.concat(parts, '; ')
        local st = try(function() return ins.status end)
        if st and st == defines.entity_status.disabled_by_control_behavior then
          f.holds_fuel_back = true; held_back = true
        end
        -- What sets the signal of a feeder holding fuel back (the combinators on its wires and their settings), while
        -- the budget lasts.
        if f.holds_fuel_back and api.trace and budget.traces > 0 then
          budget.traces = budget.traces - 1
          local lines = try(function() return api.trace(ins) end) or {}
          local set = {}
          for _, l in ipairs(lines) do
            if (l:find('combinator', 1, true)) and #set < 3 then set[#set+1] = (l:gsub('^%s+', '')) end
          end
          if #set > 0 then f.set_by = set end
        end
      end
      control[#control+1] = f
    end
    if #ins_list > 4 then row.feeders_more = #ins_list - 4 end
    network = network or try(function() return e.surface.find_logistic_network_by_position(e.position, e.force) end)
    local net_n = 0
    if network and main then net_n = try(function() return network.get_item_count(main) end) or 0 end
    -- Nothing burning, held or fed: the fuel it takes that the network holds most of.
    if network and not main then
      for _, fu in ipairs(fuels) do
        local n = try(function() return network.get_item_count(fu) end) or 0
        if n > net_n then main, net_n = fu, n end
      end
      main = main or fuels[1]
    end
    row.feeders = #control > 0 and control or nil
    row.feed = {in_reach=feed_n, network=main and network and string.format('the logistic network there holds %d %s', math.max(0, net_n), main) or nil}
    -- Minutes left: heat, then burning fuel, slots and feed at its burn rate.
    local heat_min = heat_per_min > 0 and heat_j / heat_per_min or 0
    local fuel_min = fuel_per_min > 0 and (left_j + slots_j + feed_j) / fuel_per_min or 0
    row.minutes_left = round(heat_min + fuel_min, 1)
    row.minutes = {heat=round(heat_min, 1), burning=fuel_per_min > 0 and round(left_j / fuel_per_min, 1) or 0,
      slots=fuel_per_min > 0 and round(slots_j / fuel_per_min, 1) or 0, feed=fuel_per_min > 0 and round(feed_j / fuel_per_min, 1) or 0,
      heat_above=string.format('%g C (%s)', floor, floor_why)}
    -- What it is doing, in words.
    local hot = heat_min >= 0.1
    local state
    if row.burning then state = nheld > 0 and 'burning, with fuel in its slots' or 'burning, its fuel slot empty'
    elseif nheld > 0 and burnt_full then state = 'stopped: its burnt result slot is full'
    elseif nheld > 0 then state = 'fuel in its slots'
    elseif hot and held_back then state = 'not burning: its feed is held back by its circuit; heat left'
    elseif hot then state = 'not burning, slot empty; heat left'
    elseif #ins_list == 0 then state = 'cold and idle: slot empty, no inserter feeds it'; row.idle = true
    elseif feed_n > 0 or net_n > 0 then state = 'cold, slot empty; fuel to be had' .. (held_back and ' (its feed held back by its circuit)' or '')
    else state = 'no heat and no fuel to be had' end
    row.state = state
    -- the emergency: fed by inserters, yet no heat left and no fuel to be had
    if not hot and not row.burning and nheld == 0 and #ins_list > 0 and feed_n == 0 and net_n <= 0 then row.emergency = true end
    row.line = string.format('%s %s: %g C; %s%s; slot %s%s; feeders hold %d%s; about %g min (heat %g, burning %g, slots %g, feed %g)',
      e.name, at(e.position), round(temp, 0), state,
      row.burning and string.format(' (%s, %g of it left)', row.burning.item, row.burning.left or 0) or '',
      nheld > 0 and list_text(held) or 'empty', row.burnt and (' (burnt: ' .. list_text(burnt) .. (burnt_full and ', full' or '') .. ')') or '',
      feed_n, main and network and string.format(', network %d', math.max(0, net_n)) or '',
      row.minutes_left, row.minutes.heat, row.minutes.burning, row.minutes.slots, row.minutes.feed)
    return row, {net_n=math.max(0, net_n), main=main, network=network}
  end
  -- The reactors of a group (at most MAX_DETAIL in detail) and the group's summary.
  function M.group(list)
    local rows, nets, budget = {}, {}, {traces=TRACES}
    local empty, burning, held_back, worst, emergencies = 0, 0, 0, nil, 0
    for _, e in ipairs(list) do
      if #rows >= MAX_DETAIL then break end
      if e.valid and try(function() return e.burner end) then
        local ok, row, x = pcall(M.reactor, e, budget)
        if ok then
          rows[#rows+1] = row
          if row.fuel_slots.empty then empty = empty + 1 end
          if row.burning then burning = burning + 1 end
          for _, f in ipairs(row.feeders or {}) do if f.holds_fuel_back then held_back = held_back + 1; break end end
          -- an idle reactor (cold, empty, no inserter feeding it) does not set the group's fewest minutes
          if not row.idle and (not worst or row.minutes_left < worst) then worst = row.minutes_left end
          if row.emergency then emergencies = emergencies + 1 end
          local key = x.network and x.main and (tostring(try(function() return x.network.network_id end)) .. '|' .. x.main)
          if key and not nets[key] then nets[key] = {item=x.main, n=x.net_n} end
        end
      end
    end
    local stock = {}
    for _, v in pairs(nets) do stock[v.item] = (stock[v.item] or 0) + v.n end
    local more = 0
    for _, e in ipairs(list) do if e.valid then more = more + 1 end end
    more = more - #rows
    return {reactors=rows, more=more > 0 and more or nil, empty_slots=empty, burning=burning, held_back=held_back, minutes_left=worst, emergencies=emergencies,
      network_stock=next(stock) and stock or nil}
  end
  return M
end
