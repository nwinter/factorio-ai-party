-- Stop waits the harness keeps for a platform (d17 batch31 B9; Astra 07:33: Cinder waited at Gleba over 5 min on
-- fluid_count thruster-fuel >= 22000 and thruster-oxidizer >= 22000 while its tanks held 26000 of each; Luna 07:50: on
-- Spindle the stop's fluid_count ignored 25000 in each storage tank on several departures). platform_schedule's waits
-- with harness: true (fluid_count only) are not given to the game. The stop's game record gets a circuit condition that
-- never holds (signal-dot < -2147483648) beside its other waits, so the game does not send the platform on itself;
-- every EVERY ticks this reads, while the platform waits at that stop: each harness condition against the sum of the
-- fluid in its storage tanks (as a player reads the tanks), and the stop's time and item_count waits (time from when it
-- was first seen waiting there; item_count from the hub). When all hold (the stop's waits are joined by and), it calls
-- go to station on the next stop, as platform_schedule {next: true} does, and keeps that line.
-- State: storage platform_waits[name] = {stops={[k]={station, conds}}, at, arrived, last}. Read only but for the go to
-- station call.
return function(api)
  local M = {}
  local EVERY, TANKS = 60, 64
  M.NEVER = {first_signal={type='virtual', name='signal-dot'}, comparator='<', constant=-2147483648}
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function waits() local s = api.state(); s.platform_waits = s.platform_waits or {}; return s.platform_waits end
  local CMP = {['≥']='>=', ['≤']='<=', ['≠']='!='}
  local function compare(a, cmp, b)
    cmp = CMP[cmp] or cmp
    if cmp == '<' then return a < b elseif cmp == '>' then return a > b elseif cmp == '=' then return a == b
    elseif cmp == '>=' then return a >= b elseif cmp == '<=' then return a <= b else return a ~= b end
  end
  local function cond_words(c) return string.format('%s %s %g', c.name, CMP[c.comparator] or c.comparator, c.value) end
  -- the fluid in the platform's storage tanks, summed
  function M.tanks(pl, fluid)
    local n, k = 0, 0
    for _, e in ipairs(try(function() return pl.surface.find_entities_filtered{type='storage-tank', force=pl.force, limit=TANKS} end) or {}) do
      local v = try(function() return e.get_fluid_count(fluid) end) or 0
      n = n + v; if v > 0 then k = k + 1 end
    end
    return n, k
  end
  -- set (or clear: watch nil) the harness's waits for a platform
  function M.set(pl, watch)
    local w = waits()
    w[pl.name] = watch and {stops=watch, index=pl.index} or nil
  end
  function M.get(name) return waits()[name] end
  local function is_never(c)
    return type(c) == 'table' and c.first_signal and c.first_signal.name == 'signal-dot' and c.comparator == '<' and c.constant == M.NEVER.constant
  end
  -- One stop's conditions now: all hold, and each in words.
  local function check(pl, s, arrived, tick)
    local all, words = true, {}
    for _, c in ipairs(s.conds) do
      local ok, text
      if c.kind == 'tanks' then
        local n, k = M.tanks(pl, c.name)
        ok = compare(n, c.comparator, c.value)
        text = string.format('%s: tanks hold %d (%d tank%s)', cond_words(c), math.floor(n + 0.5), k, k == 1 and '' or 's')
      elseif c.kind == 'time' then
        local left = c.ticks - (tick - arrived)
        ok = left <= 0
        text = string.format('time %ds: %s', math.floor(c.ticks / 60), ok and 'passed' or math.ceil(left / 60) .. 's left')
      elseif c.kind == 'hub' then
        local n = try(function() return pl.hub.get_inventory(defines.inventory.hub_main).get_item_count(c.name) end) or 0
        ok = compare(n, c.comparator, c.value)
        text = string.format('%s: the hub holds %d', cond_words(c), n)
      end
      all = all and ok
      words[#words+1] = text .. (ok and '' or ' (not yet)')
    end
    return all, words
  end
  function M.tick(tick)
    if tick % EVERY ~= 0 then return end
    local w = waits()
    if not next(w) then return end
    for name, watch in pairs(w) do
      local pl
      for _, f in pairs(game.forces) do
        for _, x in pairs(f.platforms or {}) do if x.valid and x.name == name then pl = x end end
      end
      if not pl then w[name] = nil
      else
        local sch = try(function() return pl.get_schedule() end)
        local cur = sch and sch.current
        local s = cur and watch.stops[cur]
        -- (d21 batch66 AB4) the game reads no_schedule while a platform waits at the current stop it was sent to there
        local waiting = try(function() return pl.state == defines.space_platform_state.waiting_at_station
          or (pl.state == defines.space_platform_state.no_schedule and not pl.paused and not pl.space_connection) end)
        local here = waiting and s and try(function() return pl.space_location.name end) == s.station
        -- the record still holds the never condition: else the schedule was changed elsewhere and the watch is dropped
        local rec = here and try(function() return pl.schedule.records[cur] end)
        local kept = false
        for _, c in ipairs(rec and rec.wait_conditions or {}) do if c.type == 'circuit' and is_never(c.condition) then kept = true end end
        if here and not kept then w[name] = nil
        elseif not here then watch.at, watch.arrived = nil, nil
        else
          if watch.at ~= cur then watch.at, watch.arrived = cur, tick end
          local all, words = check(pl, s, watch.arrived, tick)
          watch.now = string.format('waits at stop %d (%s): %s', cur, s.station, table.concat(words, '; '))
          if all and not pl.paused then
            local n = sch.get_record_count()
            local nxt = cur % n + 1
            local ok = pcall(function() sch.go_to_station(nxt) end)
            watch.last = string.format('tick %d: %s stop %d (%s) for stop %d (%s): %s', tick, ok and 'sent from' or 'go to station refused at',
              cur, s.station, nxt, try(function() return pl.schedule.records[nxt].station end) or '?', table.concat(words, '; '))
            watch.at, watch.arrived, watch.now = nil, nil, nil
          end
        end
      end
    end
  end
  -- The watch for a platform in words, or nil.
  function M.line(name)
    local watch = waits()[name]
    if not watch then return nil end
    local parts = {}
    for k, s in pairs(watch.stops) do
      local c = {}
      for _, x in ipairs(s.conds) do c[#c+1] = x.kind == 'time' and 'time ' .. math.floor(x.ticks / 60) .. 's' or (x.kind == 'tanks' and 'tanks ' or 'hub ') .. cond_words(x) end
      parts[#parts+1] = string.format('stop %d (%s): %s', k, s.station, table.concat(c, ', '))
    end
    table.sort(parts)
    return 'the harness sends it on (go to station) when these hold: ' .. table.concat(parts, ' | ')
      .. (watch.now and '; now ' .. watch.now or '') .. (watch.last and '; last: ' .. watch.last or '')
  end
  return M
end
