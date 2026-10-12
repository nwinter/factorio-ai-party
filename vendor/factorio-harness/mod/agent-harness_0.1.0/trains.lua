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
  M.schema = {
    train = {position='{x,y} of a train stop, or of a locomotive or wagon of the train (in reach)',
      station='train stop: its station name (what schedules name)', limit='train stop: train limit 0..1000, or false to clear it',
      schedule='train: array of 0..32 {station, wait=[{type=time|inactivity|full|empty|item_count|fluid_count|circuit|passenger_present|..., ticks? (time, inactivity), compare? and|or, condition? {signal, comparator, value}}]}; [] clears',
      current='train: 1-based schedule entry to head for (default 1)',
      automatic='train: true runs the schedule, false is manual mode',
      returns='stop: name, limit, trains_count; train: schedule (one line per stop), current, automatic, state'},
  }
  local function stop_view(e)
    local out = {stop=e.backer_name, position=e.position}
    pcall(function() out.limit = e.trains_limit; out.trains_count = e.trains_count end)
    return out
  end
  local function records_text(sch)
    local lines = {}
    for i, r in ipairs(sch and sch.records or {}) do
      local waits = {}
      for _, w in ipairs(r.wait_conditions or {}) do
        waits[#waits+1] = w.type .. (w.ticks and ' ' .. math.floor(w.ticks / 60) .. 's' or '')
      end
      lines[i] = (r.station or '?') .. (#waits > 0 and ': ' .. table.concat(waits, ', ') or '')
    end
    return lines
  end
  local function condition(c, what)
    if c == nil then return nil end
    assert(type(c) == 'table' and type(c.signal) == 'string', what .. '.condition is {signal, comparator, value}')
    local kind = prototypes.item[c.signal] and 'item' or (prototypes.fluid and prototypes.fluid[c.signal] and 'fluid') or 'virtual'
    return {first_signal={type=kind, name=c.signal}, comparator=c.comparator or '<', constant=math.floor(c.value or 0)}
  end
  function M.handlers.train(p, a)
    -- The target by position only: entity() reads `name` as an entity-name
    -- filter, which is why a stop's name is `station` (live check: name
    -- "LC-East" failed as "Unknown entity name").
    local e = api.entity(p, {position=a.position}); api.friendly(p, e)
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
    local out = {automatic=not train.manual_mode}
    pcall(function()
      local sch = train.schedule
      out.schedule = records_text(sch); out.current = sch and sch.current
    end)
    pcall(function() out.state = api.train_state and api.train_state(train.state) or train.state end)
    return out
  end
  return M
end
