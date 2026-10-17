-- Trains, as a player sets them in the train stop and locomotive GUIs: a
-- stop's name and train limit; a train's schedule (stations and wait
-- conditions) and automatic/manual mode. Rails, stops, locomotives and
-- wagons are built with build/place_ghosts like anything else.
return function(api)
  local M = {handlers={}}
  local WAITS = {time=true, inactivity=true, full=true, empty=true, item_count=true, fluid_count=true, circuit=true,
    passenger_present=true, passenger_not_present=true, fuel_item_count_all=true, fuel_item_count_any=true,
    robots_inactive=true, specific_destination_full=true, specific_destination_not_full=true}
  local ROLLING = {locomotive=true, ['cargo-wagon']=true, ['fluid-wagon']=true, ['artillery-wagon']=true}
  local TRAIN_NAMES
  M.schema = {
    train = {stops='true: every train stop of ours on the surface (Gemini, d15 21:40: no call listed them), by name: position, rail beside it, limit, trains_count and the trains heading there or stopped at it (their front carriage and state); at most 200; surface= for another one',
      surface='a surface name (default yours): with stops, its stops; with position, the train or stop there, by remote view (ours, in a chunk our force sees now)',
      position='{x,y} of a train stop, or of a locomotive or wagon of the train (in sight, or by remote view in a visible chunk)',
      train_id='a train of ours by its id instead of position, wherever it is and moving or not (train {stops: true} and every train read give id): as the game\'s trains list opens it',
      station='train stop: its station name (what schedules name)', limit='train stop: train limit 0..1000, or false to clear it',
      schedule='train: array of 0..32 {station, wait=[{type=time|inactivity|full|empty|item_count|fluid_count|circuit|passenger_present|..., ticks? (time, inactivity), compare? and|or, condition? {signal, comparator, value}}]}; [] clears',
      current='train: 1-based schedule entry to head for (default 1)',
      automatic='train: true runs the schedule, false is manual mode',
      path_to='train: a stop name: whether the rails lead there from the train as it drives, and where not (rail_break); a train in no_path gets it for the stop it heads for unasked',
      returns='stop: name, limit, trains_count, rail (the rail it is beside, or none); train: id, front {name, position, surface}, schedule (one line per stop), current, automatic, state (on_the_path, wait_station, wait_signal, arrive_signal, arrive_station, no_path, destination_full, no_schedule, manual_control, manual_control_stop), why (what it waits for: the stop and its wait conditions, the signal ahead and its state, the stops of the destination name and their limits and trains, or that no stop has that name), at_stop, heading_to {stop, position, tiles_left}, speed_kmh, carriages, cargo, fluids, fuel (per locomotive); rail_break {to, line, train_side, stop_side, gap_tiles, ghosts, signals} (no_path, or path_to): the rails followed from the train (its front, and its back with a locomotive facing back) through every connection: whole (and when the engine still finds no path, the signals on that way), reaching the stop only facing the other way, or broken: the end of the rails from the train and of those into the stop nearest each other, the tiles between and the rail ghosts there'},
  }
  local function at(pos) return string.format('(%g,%g)', math.floor(pos.x * 10 + 0.5) / 10, math.floor(pos.y * 10 + 0.5) / 10) end
  -- A schedule entry's wait conditions as the GUI lists them.
  local function wait_text(r)
    local waits = {}
    for _, w in ipairs(r and r.wait_conditions or {}) do
      local t = w.type .. (w.ticks and ' ' .. math.floor(w.ticks / 60) .. 's' or '')
      if w.condition and w.condition.first_signal then
        local c = w.condition
        t = t .. ' ' .. c.first_signal.name .. ' ' .. (c.comparator or '<') .. ' ' .. tostring(c.constant or 0)
      end
      waits[#waits+1] = (#waits > 0 and (w.compare_type or 'and') .. ' ' or '') .. t
    end
    return #waits > 0 and table.concat(waits, ' ') or 'no wait condition'
  end
  local function records_text(sch)
    local lines = {}
    for i, r in ipairs(sch and sch.records or {}) do
      lines[i] = (r.station or '?') .. ': ' .. wait_text(r)
    end
    return lines
  end
  local function stop_view(e)
    local out = {stop=e.backer_name, position=e.position}
    pcall(function() out.limit = e.trains_limit; out.trains_count = e.trains_count end)
    pcall(function()
      local r = e.connected_rail
      out.rail = r and r.name .. ' ' .. at(r.position) or 'none: no straight rail beside it on the side that serves its direction'
    end)
    return out
  end
  local STATE
  local function state_name(v)
    if not STATE then
      STATE = {}
      for k, n in pairs(defines.train_state or {}) do STATE[n] = k end
    end
    return STATE[v] or v
  end
  local SIGNAL_STATE
  local function signal_state(e)
    local ok, v = pcall(function() return e.signal_state end)
    if not ok or v == nil then return nil end
    if not SIGNAL_STATE then
      SIGNAL_STATE = {}
      for k, n in pairs(defines.signal_state or {}) do SIGNAL_STATE[n] = k end
    end
    return SIGNAL_STATE[v] or v
  end
  -- The stops named name on the train's surface: where, limit, trains.
  local function stops_named(train, name)
    local list = {}
    pcall(function()
      local surface = train.front_stock and train.front_stock.surface
      for _, st in pairs(game.train_manager.get_train_stops{station_name=name, force=train.front_stock.force, surface=surface}) do
        list[#list+1] = st
      end
    end)
    return list
  end
  -- What a train is doing and why it waits, as the locomotive GUI and the
  -- map show it.
  function M.train_view(train)
    local out = {id=train.id, automatic=not train.manual_mode}
    pcall(function() local f = train.front_stock; if f and f.valid then out.front = {name=f.name, position=f.position, surface=f.surface.name} end end)
    local sch
    pcall(function()
      sch = train.schedule
      out.schedule = records_text(sch); out.current = sch and sch.current
    end)
    local state = state_name(train.state)
    out.state = state
    pcall(function() out.speed_kmh = math.floor(math.abs(train.speed) * 60 * 3.6 + 0.5) end)
    local current = sch and sch.records and sch.records[sch.current]
    local stop = train.station
    if stop and stop.valid then out.at_stop = {stop=stop.backer_name, position=stop.position} end
    pcall(function()
      local dest = train.path_end_stop
      if dest and dest.valid then
        out.heading_to = {stop=dest.backer_name, position=dest.position}
        local path = train.path
        if path and path.valid then out.heading_to.tiles_left = math.floor(path.total_distance - path.travelled_distance + 0.5) end
      end
    end)
    local why
    if state == 'wait_station' then
      why = string.format('at stop %s%s: waits for %s', stop and stop.valid and stop.backer_name or (current and current.station or '?'),
        stop and stop.valid and ' ' .. at(stop.position) or '', wait_text(current))
    elseif state == 'wait_signal' or state == 'arrive_signal' then
      local sig = train.signal
      if sig and sig.valid then
        local st = signal_state(sig)
        why = string.format('%s %s %s%s', state == 'wait_signal' and 'stopped at' or 'braking for', sig.name, at(sig.position), st and ' (' .. st .. ')' or '')
      else
        why = state == 'wait_signal' and 'stopped at a signal' or 'braking for a signal'
      end
    elseif state == 'destination_full' or state == 'no_path' then
      local name = current and current.station
      if not name then why = 'no schedule entry to head for'
      else
        local list = stops_named(train, name)
        if #list == 0 then why = 'no train stop is named ' .. name
        else
          local parts = {}
          for i, st in ipairs(list) do
            if i > 6 then break end
            local p = at(st.position)
            pcall(function()
              local lim = st.trains_limit
              p = p .. string.format(' %d train%s', st.trains_count, st.trains_count == 1 and '' or 's')
                .. ((lim and lim < 4294967295) and string.format(', limit %d', lim) or ', no limit')
              if not st.connected_rail then p = p .. ', no rail beside it' end
            end)
            parts[#parts+1] = p
          end
          why = string.format(state == 'no_path' and 'no path to any stop named %s (%d: %s%s)' or 'every stop named %s is at its train limit (%d: %s%s)',
            name, #list, table.concat(parts, '; '), #list > 6 and ' ...' or '')
          -- A train whose locomotives all face one way drives forward only.
          pcall(function()
            if state == 'no_path' and #(train.locomotives.back_movers or {}) == 0 then
              why = why .. '; its locomotives all face its front, so it drives forward only'
            end
          end)
        end
      end
    elseif state == 'no_schedule' then why = 'no schedule'
    elseif state == 'manual_control' or state == 'manual_control_stop' then why = 'manual mode'
    elseif state == 'arrive_station' then
      why = 'braking for ' .. (out.heading_to and out.heading_to.stop or (current and current.station) or 'its stop')
    end
    -- Carriages, cargo and fuel, as the train's GUI lists them.
    local burning = false
    pcall(function()
      local locos = (train.locomotives.front_movers and #train.locomotives.front_movers or 0) + (train.locomotives.back_movers and #train.locomotives.back_movers or 0)
      out.carriages = string.format('%d locomotive%s, %d wagon%s', locos, locos == 1 and '' or 's', #train.carriages - locos, #train.carriages - locos == 1 and '' or 's')
      local fuel = {}
      for _, group in pairs({train.locomotives.front_movers or {}, train.locomotives.back_movers or {}}) do
        for _, l in ipairs(group) do
          local inv = l.get_fuel_inventory()
          local parts = {}
          for _, it in ipairs(inv and inv.get_contents() or {}) do parts[#parts+1] = it.name .. ' ' .. it.count end
          local b = l.burner
          if #parts > 0 or (b and b.remaining_burning_fuel > 0) then burning = true end
          fuel[#fuel+1] = at(l.position) .. ': ' .. (#parts > 0 and table.concat(parts, ', ') or (b and b.remaining_burning_fuel > 0 and 'burning its last fuel' or 'no fuel'))
        end
      end
      out.fuel = fuel
    end)
    -- A train on its way that stands still with no fuel anywhere.
    if not why and (state == 'on_the_path' or state == 'arrive_signal' or state == 'arrive_station') and out.speed_kmh == 0 and not burning and out.fuel then
      why = 'stands still: no fuel in its locomotives'
    end
    out.why = why
    pcall(function()
      local items = train.get_contents()
      table.sort(items, function(a, b) return a.count > b.count end)
      local parts = {}
      for i, it in ipairs(items) do if i <= 8 then parts[#parts+1] = it.name .. ' ' .. it.count end end
      out.cargo = #parts > 0 and table.concat(parts, ', ') or 'empty'
      local fl = {}
      for name, amount in pairs(train.get_fluid_contents()) do fl[#fl+1] = name .. ' ' .. math.floor(amount + 0.5) end
      if #fl > 0 then out.fluids = table.concat(fl, ', ') end
    end)
    return out
  end
  local function condition(c, what)
    if c == nil then return nil end
    assert(type(c) == 'table' and type(c.signal) == 'string', what .. '.condition is {signal, comparator, value}')
    local kind = prototypes.item[c.signal] and 'item' or (prototypes.fluid and prototypes.fluid[c.signal] and 'fluid') or 'virtual'
    return {first_signal={type=kind, name=c.signal}, comparator=c.comparator or '<', constant=math.floor(c.value or 0)}
  end
  -- train {stops: true}: every stop of ours on a surface, as the train stop list and map show them.
  local MAX_STOPS = 200
  function M.stops(p, a)
    assert(a.stops == true, 'stops must be true')
    -- helper and peek ride on any request (a subagent's call, an overlay's read; Sol 15:22: a helper's call was refused).
    for k in pairs(a) do assert(k == 'stops' or k == 'surface' or k == 'helper' or k == 'peek', 'stops takes surface only (not ' .. tostring(k) .. ')') end
    local surface = p.surface
    if a.surface ~= nil then
      assert(type(a.surface) == 'string', 'surface must be a surface name')
      surface = game.get_surface(a.surface)
      assert(surface, 'no surface ' .. a.surface)
    end
    local tm = game.train_manager
    local list = tm.get_train_stops{force=p.force, surface=surface}
    -- The trains heading to or stopped at each stop.
    local by = {}
    for _, t in ipairs(tm.get_trains{force=p.force, surface=surface}) do
      local stop = t.station
      local heading = false
      if not (stop and stop.valid) then stop = t.path_end_stop; heading = true end
      local u = stop and stop.valid and stop.unit_number
      if u then
        by[u] = by[u] or {}
        local front = t.front_stock
        local row = string.format('train %d %s%s', t.id, heading and 'heading there' or 'at it', front and front.valid and ' (front ' .. at(front.position) .. ')' or '')
        if #by[u] < 4 then by[u][#by[u]+1] = row end
      end
    end
    local rows = {}
    for _, e in ipairs(list) do
      if e.valid then rows[#rows+1] = e end
    end
    table.sort(rows, function(x, y) if x.backer_name ~= y.backer_name then return x.backer_name < y.backer_name end return x.unit_number < y.unit_number end)
    local out = {}
    for i = 1, math.min(MAX_STOPS, #rows) do
      local e = rows[i]
      local v = stop_view(e)
      v.trains = by[e.unit_number]
      v.line = string.format('%s %s: limit %s, %d train%s on the way or there%s; rail %s', v.stop, at(e.position), v.limit and v.limit < 4294967295 and tostring(v.limit) or 'none',
        v.trains_count or 0, (v.trains_count or 0) == 1 and '' or 's', v.trains and ' (' .. table.concat(v.trains, '; ') .. ')' or '', v.rail or '?')
      out[i] = v
    end
    return {surface=surface.name, count=#rows, stops=out, note=#rows > MAX_STOPS and string.format('the first %d by name', MAX_STOPS) or nil}
  end
  function M.handlers.train(p, a)
    if a.stops ~= nil then return M.stops(p, a) end
    -- surface with position (Sol 15:22: from Aquilo a train at (120,-131) was looked for on Aquilo): that surface's
    -- train or stop by remote view.
    if a.surface ~= nil and api.on_surface then p = api.on_surface(p, a.surface) end
    -- The target by position only: entity() reads `name` as an entity-name
    -- filter, which is why a stop's name is `station` (live check: name
    -- "LC-East" failed as "Unknown entity name"). In sight, else by remote
    -- view (ours, in a visible chunk), as the map opens a train's or stop's
    -- GUI.
    -- Stops and rolling stock first: a train's position is also over rails.
    -- Then anything there, so the refusal says what it is.
    if not TRAIN_NAMES then
      TRAIN_NAMES = {}
      for name, proto in pairs(prototypes and prototypes.entity or {}) do
        if ROLLING[proto.type] or proto.type == 'train-stop' then TRAIN_NAMES[#TRAIN_NAMES+1] = name end
      end
    end
    -- A read (no setting given) needs the target in sight, not in reach.
    local read = a.station == nil and a.limit == nil and a.schedule == nil and a.current == nil and a.automatic == nil
    local function lookup(names)
      local ok, e = pcall(api.entity, p, {position=a.position, name=names}, read)
      if ok then return e end
      local ok2, far = pcall(api.remote_entity, p, {position=a.position, name=names})
      if ok2 then return far end
      return nil, e
    end
    local e, err
    if a.train_id ~= nil then
      -- train_id (d17 batch18 C4, Gemini: a moving train's position is gone by the time the call reads it): the train
      -- by its id, as the game's trains list opens any of ours; the ids are in train {stops} and in each train read.
      assert(a.position == nil, 'give train_id or position, not both')
      local id = api.integer(a.train_id, nil, 1, 2^31, 'train_id')
      local t = game.train_manager and game.train_manager.get_train_by_id(id)
      local front = t and t.valid and (t.front_stock or t.carriages[1])
      assert(front and front.valid and front.force == p.force, string.format('no train of ours has id %d (train {stops: true} names the trains at or heading for each stop)', id))
      e = front
    else
      if #TRAIN_NAMES > 0 then e, err = lookup(TRAIN_NAMES) end
      if not e then
        local first = err
        e, err = lookup(nil)
        if not e then error(tostring(first or err):gsub('^[^:]*:%d+: ', ''), 0) end
      end
    end
    api.friendly(p, e)
    if e.type == 'train-stop' then
      assert(a.schedule == nil and a.automatic == nil and a.current == nil, 'schedule, current and automatic are for a train: give a locomotive or wagon position')
      if a.station ~= nil then
        assert(type(a.station) == 'string' and #a.station >= 1 and #a.station <= 100, 'station is 1..100 characters')
        e.backer_name = a.station
      end
      if a.limit ~= nil then
        if a.limit == false then pcall(function() e.trains_limit = nil end)
        else e.trains_limit = api.integer(a.limit, nil, 0, 1000, 'limit (0..1000)') end
      end
      return stop_view(e)
    end
    assert(ROLLING[e.type], e.name .. ' is neither a train stop nor part of a train')
    assert(a.station == nil and a.limit == nil, 'station and limit are for a train stop')
    local train = e.train
    assert(train and train.valid, 'no train here')
    if a.schedule ~= nil then
      assert(type(a.schedule) == 'table' and #a.schedule <= 32, 'schedule takes 0..32 {station, wait}')
      local records = {}
      for i, s in ipairs(a.schedule) do
        assert(type(s) == 'table' and type(s.station) == 'string' and #s.station > 0, 'schedule ' .. i .. ': station (a train stop name) is required')
        local waits = {}
        for j, w in ipairs(s.wait or {}) do
          assert(type(w) == 'table' and WAITS[w.type], 'schedule ' .. i .. ' wait ' .. j .. ': type is time, inactivity, full, empty, item_count, fluid_count, circuit, passenger_present, ...')
          waits[j] = {type=w.type, ticks=w.ticks and api.integer(w.ticks, nil, 1, 216000, 'wait ticks') or nil,
            compare_type=j > 1 and (w.compare or 'and') or nil, condition=condition(w.condition, 'schedule ' .. i .. ' wait ' .. j)}
        end
        records[i] = {station=s.station, wait_conditions=#waits > 0 and waits or nil}
      end
      local current = api.integer(a.current, 1, 1, math.max(1, #records), 'current')
      local ok, err = pcall(function() train.schedule = #records > 0 and {current=current, records=records} or nil end)
      if not ok then
        -- 2.0's LuaSchedule, where the table setter is not taken.
        local ok2, err2 = pcall(function()
          local sch = train.get_schedule()
          for _ = sch.get_record_count(), 1, -1 do sch.remove_record({schedule_index=1}) end
          for _, r in ipairs(records) do sch.add_record({station=r.station, wait_conditions=r.wait_conditions}) end
          if #records > 0 then sch.go_to_station(current) end
        end)
        assert(ok2, 'the game refused the schedule: ' .. tostring(err) .. ' / ' .. tostring(err2))
      end
    end
    if a.automatic ~= nil then
      assert(type(a.automatic) == 'boolean', 'automatic must be boolean')
      train.manual_mode = not a.automatic
    end
    local view = M.train_view(train)
    -- Where its way is broken (railbreak.lua; d17 batch12 B1, Opus): no_path, or asked for a stop name (path_to).
    assert(a.path_to == nil or (type(a.path_to) == 'string' and #a.path_to > 0), 'path_to is a train stop name')
    local name = a.path_to
    if not name and view.state == 'no_path' then
      pcall(function() local sch = train.schedule; local r = sch and sch.records[sch.current]; name = r and r.station end)
    end
    if name and api.railbreak then
      local list = stops_named(train, name)
      if #list == 0 then view.rail_break = {line='no train stop is named ' .. name}
      else
        local ok, rb = pcall(api.railbreak.find, train, list)
        view.rail_break = ok and rb or {line='the rails could not be read: ' .. tostring(rb)}
      end
      view.rail_break.to = name
    end
    return view
  end
  return M
end
