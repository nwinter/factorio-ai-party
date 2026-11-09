-- Completed flight production, independent of freight's shorter stop/leg ring.
-- Native counters are read only at a boundary (or the first observation). The
-- state event supplies its tick; a small position watch detects direction and
-- connection changes which raise no state event, without collecting counters.
local qflow = require('qflow')
return function(api)
  local M = {KEEP=16, CARGO_ITEMS=64}
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function store()
    local s = api.state()
    s.production_legs = s.production_legs or {}
    return s.production_legs
  end
  local ammo
  local function ammo_names()
    if not ammo then
      ammo = {}
      for name, p in pairs(prototypes.item) do if p.type == 'ammo' then ammo[#ammo+1] = name end end
      table.sort(ammo)
    end
    return ammo
  end
  local function counts(pl, fluid)
    local ok, out = pcall(function()
      local s = fluid and pl.force.get_fluid_production_statistics(pl.surface) or pl.force.get_item_production_statistics(pl.surface)
      local t = {}
      for _, name in ipairs(fluid and {'thruster-fuel', 'thruster-oxidizer'} or ammo_names()) do
        local made, used = 0, 0
        if fluid then made, used = s.get_input_count(name), s.get_output_count(name)
        else
          -- Every quality at each boundary, including one first produced since
          -- the preceding boundary (the freight phase cache is not used here).
          for _, q in ipairs(qflow.qualities()) do
            local id = {name=name, quality=q}
            made, used = made + s.get_input_count(id), used + s.get_output_count(id)
          end
        end
        t[name] = {made=made, used=used}
      end
      return t
    end)
    if ok then return out end
  end
  local function snapshot(pl) return {ammo=counts(pl, false), fuel=counts(pl, true)} end
  local function delta(a, b)
    if not (a and b) then return nil end
    local out = {}
    for name, v in pairs(b) do
      local old = a[name]
      if not old or v.made < old.made or v.used < old.used then return nil end
      -- Preserve native fluid precision, including a flight shorter than a second.
      out[name] = {made=v.made-old.made, used=v.used-old.used}
    end
    return out
  end
  local function position(pl, w)
    if w.at then return {location=w.at} end
    local c = try(function() return pl.space_connection end)
    return {connection=c and c.name, distance=try(function() return pl.distance end)}
  end
  function M.observe(pl, tick, source, w)
    if not (pl and pl.valid) then return end
    local leg = w.leg
    -- A location on the path still closes the incoming leg: a station passed
    -- without waiting must not disappear between two freight samples.
    if not (w.at or leg) then return end
    local pos = position(pl, w)
    local key = w.at and 'at:' .. w.at or 'leg:' .. tostring(pos.connection) .. ':' .. leg.from .. '>' .. leg.to
    local all = store()
    local r = all[pl.index]
    if not r then r = {completed={}, seq=0}; all[pl.index] = r end
    r.name, r.pl = pl.name, pl
    if r.key == key then return end
    local now = snapshot(pl)
    local old = r.active
    if old and old.heading then
      r.seq = r.seq + 1
      local a, f = delta(old.counts.ammo, now.ammo), delta(old.counts.fuel, now.fuel)
      local why = w.at and 'arrival' or old.position.connection == pos.connection and 'reversal' or 'station_passed'
      local row = {id=r.seq, from=old.tick, to=tick, minutes=(tick-old.tick)/3600,
        from_location=old.from_location, to_location=old.to_location, heading=old.heading,
        start_position=old.position, end_position=pos, ended_by=why,
        start_source=old.source, end_source=source, partial=old.partial,
        ammo=a, fuel=f, loaded=old.loaded, dropped=old.dropped,
        cargo_capped=old.cargo_capped, cargo_unknown=old.cargo_unknown,
        status=a and f and not old.partial and not old.cargo_capped and not old.cargo_unknown and 'complete' or 'incomplete'}
      if not a or not f then row.counter_status = 'unknown: native counters unavailable or reset' end
      r.completed[#r.completed+1] = row
      while #r.completed > M.KEEP do table.remove(r.completed, 1) end
    end
    r.active = {tick=tick, counts=now, source=source, position=pos,
      from_location=leg and leg.from, to_location=leg and leg.to, heading=leg and leg.to,
      partial=r.key == nil and leg ~= nil or nil, loaded={}, dropped={}}
    r.key = key
    r.motion_connection, r.motion_distance, r.motion_tick = pos.connection, pos.distance, tick
  end
  -- 2.0.77 raises no state event for a mid-connection reversal. Only position
  -- properties are read here. Direction is the observed change in native distance,
  -- not the next schedule station, which may lie beyond this connection.
  function M.watch_one(pl, tick)
    local r = store()[pl.index]
    local at = pl.space_location
    if at then
      if not r or r.key ~= 'at:' .. at.name then M.observe(pl, tick, 'watch', {at=at.name}) end
      r = store()[pl.index]
      if r then r.motion_connection, r.motion_distance = nil, nil end
      return
    end
    local c, d = pl.space_connection, pl.distance
    if not (c and d) then return end
    local heading, from
    if r and r.motion_tick ~= tick and r.motion_connection == c.name and r.motion_distance ~= nil and d ~= r.motion_distance then
      local back = d < r.motion_distance
      from, heading = back and c.to.name or c.from.name, back and c.from.name or c.to.name
    elseif r and r.active and r.active.heading and r.active.position.connection == c.name then
      from, heading = r.active.from_location, r.active.heading
    else
      local w = api.where(pl)
      if w.leg then from, heading = w.leg.from, w.leg.to end
    end
    if heading and (not r or not r.active or r.active.heading ~= heading or r.active.position.connection ~= c.name) then
      M.observe(pl, tick, 'watch', {leg={from=from, to=heading}})
      r = store()[pl.index]
    end
    if r then r.motion_connection, r.motion_distance, r.motion_tick = c.name, d, tick end
  end
  function M.tick(tick)
    for _, r in pairs(store()) do
      local pl = r.pl
      if pl and pl.valid then M.watch_one(pl, tick) end
    end
  end
  -- Cargo means rockets launched to the platform and hub pods sent down, at
  -- their engine event ticks. Delivery at the far end is a different ledger.
  function M.cargo(pl, pod, side, tick)
    if not (pl and pl.valid) then return end
    M.watch_one(pl, tick)
    local r = store()[pl.index]
    local a = r and r.active
    if not a then return end
    local items = try(function() return pod.get_inventory(defines.inventory.cargo_unit).get_contents() end)
    if not items then a.cargo_unknown = true; return end
    local n = 0
    for _ in pairs(a[side]) do n = n + 1 end
    for _, item in pairs(items) do
      local q = item.quality
      if type(q) ~= 'string' then q = q and q.name end
      local key = item.name .. (q and q ~= 'normal' and '@' .. q or '')
      if a[side][key] then a[side][key] = a[side][key] + item.count
      elseif n < M.CARGO_ITEMS then a[side][key] = item.count; n = n + 1
      else a.cargo_capped = true end
    end
  end
  function M.on_launch(event)
    local pod = try(function() return event.rocket.attached_cargo_pod end)
    local d = pod and try(function() return pod.cargo_pod_destination end)
    local pl = d and (try(function() return d.station.surface.platform end) or try(function() return d.space_platform end))
    M.cargo(pl, pod, 'loaded', event.tick or game.tick)
  end
  function M.on_pod(event)
    local pod = event.cargo_pod
    local pl = pod and try(function() return pod.cargo_pod_origin.surface.platform end)
    M.cargo(pl, pod, 'dropped', event.tick or game.tick)
  end
  function M.prune(seen)
    for i in pairs(store()) do if not seen[i] then store()[i] = nil end end
  end
  function M.read(pl, n)
    assert(type(n) == 'number' and n == math.floor(n) and n >= 1 and n <= M.KEEP, 'legs is an integer from 1 to 16')
    local r = store()[pl.index]
    local kept = r and r.completed or {}
    local rows, lines = {}, {}
    for i = math.max(1, #kept-n+1), #kept do
      local v = kept[i]
      rows[#rows+1] = v
      lines[#lines+1] = string.format('leg #%d %s->%s, heading %s, ticks %d-%d: %s; %s (%s to %s)',
        v.id, v.from_location, v.to_location, v.heading, v.from, v.to, v.ended_by, v.status, v.start_source, v.end_source)
      local parts = {}
      for _, field in ipairs({'ammo', 'fuel', 'loaded', 'dropped'}) do
        local names = {}
        for name in pairs(v[field] or {}) do names[#names+1] = name end
        table.sort(names)
        for _, name in ipairs(names) do
          local x = v[field][name]
          if type(x) == 'table' then
            if x.made ~= 0 or x.used ~= 0 then parts[#parts+1] = string.format('%s made %g, used %g', name, x.made, x.used) end
          else parts[#parts+1] = string.format('%s %s %g', field, name, x) end
        end
      end
      if v.counter_status then parts[#parts+1] = v.counter_status end
      if v.partial then parts[#parts+1] = 'first seen during flight' end
      if v.cargo_capped then parts[#parts+1] = 'cargo capped at 64 item/quality keys per direction' end
      if v.cargo_unknown then parts[#parts+1] = 'cargo read failed' end
      lines[#lines+1] = #parts > 0 and table.concat(parts, '; ') or 'no ammo or fuel made or used, no cargo sent in this interval'
    end
    if #lines == 0 then lines[1] = 'no completed legs recorded for ' .. pl.name end
    return {platform=pl.name, legs=rows, kept=#kept, limit=M.KEEP, lines=lines,
      note='Completed flights, oldest first; last 16 kept. from/to are ticks; locations and heading name the directed connection ends, not a claim that either end was reached (start_position/end_position give the boundary). Native ammo counters sum every quality; fuel retains native precision. Event boundaries use their tick; otherwise a position watch uses the tick it observes the location, connection or distance direction change. partial means first seen during flight. loaded counts rockets launched to it; dropped counts hub pods sent down, not deliveries; cargo keys include quality, at most 64 each. Reads do not take samples.'}
  end
  return M
end
