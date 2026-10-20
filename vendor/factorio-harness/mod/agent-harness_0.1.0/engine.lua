-- engine: a platform's flight over the last 60 and 180 s (Astra, 21:20: the instant speed looked settled at 38, 18
-- and 30 km/s and then rose to 55 under the same throttle; three tuning rounds went by it). Once a game second each
-- platform is sampled: its speed, the thruster fluids its surface's fluid statistics count used and made so far, what
-- its thrusters' tanks hold, and how many of its pumps work. Over a window: the speed's mean, lowest and highest and
-- its first and last; each thruster fluid used and made; the thrusters' tanks at the window's start and end; the
-- pumps' duty (the share of pump-seconds working). Kept in storage, KEEP samples a platform; the thrusters and pumps
-- are found again every minute.
-- (d20 batch54 N2, viewer Aurora: "Sampling every 60 ticks can miss a 20-tick pulse entirely") the pumps are read once
-- a second at a phase that moves STRIDE ticks each second (pump_tick), so a minute of samples meets every tick of a
-- second once and a pump working 20 ticks of every 60 reads a third of the time whatever its phase. The game keeps no
-- count of a pump's working ticks (LuaEntity has products_finished for crafting machines only).
return function(api)
  local M = {}
  local KEEP, REFRESH, WINDOWS, STRIDE = 181, 3600, {60, 180}, 7
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function store()
    local st = api.state()
    st.engine = st.engine or {}
    return st.engine
  end
  local function r1(v) return math.floor(v * 10 + 0.5) / 10 end
  local working = defines.entity_status and defines.entity_status.working
  -- The fluids the thrusters burn: their input boxes' filters (thruster-fuel, thruster-oxidizer).
  local function fluids_of(thrusters)
    local out, seen = {}, {}
    for _, t in ipairs(thrusters) do
      local fb = try(function() return t.fluidbox end)
      for i = 1, (fb and try(function() return #fb end) or 0) do
        local name = try(function() return fb.get_filter(i).name end) or try(function() return fb[i].name end)
        if name and not seen[name] then seen[name] = true; out[#out+1] = name end
      end
      if #out > 0 then break end
    end
    table.sort(out)
    return out
  end
  local function refresh(rec, pl, tick)
    local s = pl.surface
    rec.thrusters = try(function() return s.find_entities_filtered{type='thruster', force=pl.force} end) or {}
    rec.pumps = try(function() return s.find_entities_filtered{type='pump', force=pl.force} end) or {}
    local f = fluids_of(rec.thrusters)
    if #f > 0 then rec.fluids = f end
    rec.found = tick
  end
  local function all_valid(list)
    for _, e in ipairs(list or {}) do if not e.valid then return false end end
    return true
  end
  -- One sample: {tick, km/s, {used}, {made}, {in tanks}, pumps working, pumps, the pumps' phase}; the pumps' fields
  -- are filled by pump_tick later in the same second.
  function M.sample(pl, tick)
    local all = store()
    local rec = all[pl.index]
    if not rec then rec = {samples={}}; all[pl.index] = rec end
    if not rec.found or tick - rec.found >= REFRESH or not all_valid(rec.thrusters) or not all_valid(rec.pumps) then refresh(rec, pl, tick) end
    local fluids = rec.fluids or {}
    local stats = try(function() return pl.force.get_fluid_production_statistics(pl.surface) end)
    local used, made, tank = {}, {}, {}
    for i, name in ipairs(fluids) do
      used[i] = stats and try(function() return stats.get_output_count(name) end) or 0
      made[i] = stats and try(function() return stats.get_input_count(name) end) or 0
      tank[i] = 0
    end
    for _, t in ipairs(rec.thrusters) do
      local fb = t.fluidbox
      for k = 1, #fb do
        local f = fb[k]
        if f then
          for i, name in ipairs(fluids) do if f.name == name then tank[i] = tank[i] + f.amount end end
        end
      end
    end
    local speed = try(function() return pl.speed end) or 0
    local s = rec.samples
    s[#s+1] = {tick, speed * 60, used, made, tank}
    while #s > KEEP do table.remove(s, 1) end
    rec.name = pl.name
  end
  -- Every game second (runtime tick): each platform of each force.
  function M.tick(tick)
    local seen = {}
    for _, f in pairs(game.forces) do
      for _, pl in pairs(try(function() return f.platforms end) or {}) do
        if pl.valid and try(function() return pl.surface end) then seen[pl.index] = true; pcall(M.sample, pl, tick) end
      end
    end
    local all = store()
    for index in pairs(all) do if not seen[index] then all[index] = nil end end
  end
  -- Every tick: at this second's phase ((second * STRIDE) % 60), each platform's pumps into its sample of this second.
  function M.pump_tick(tick)
    local sec = math.floor(tick / 60)
    local phase = tick - sec * 60
    if phase ~= (sec * STRIDE) % 60 then return end
    for _, rec in pairs(store()) do
      local s = rec.samples and rec.samples[#rec.samples]
      if s and s[1] == sec * 60 then
        local on, n = 0, 0
        for _, e in ipairs(rec.pumps or {}) do
          if e.valid then n = n + 1; if e.status == working then on = on + 1 end end
        end
        s[6], s[7], s[8] = on, n, phase
      end
    end
  end
  -- One window: the samples within `seconds` of the last one.
  local function window(rec, seconds)
    local s = rec.samples
    local last = s[#s]
    local first, n = nil, 0
    local sum, low, high, on, pumps, ps = 0, math.huge, -math.huge, 0, 0, 0
    for i = #s, 1, -1 do
      local x = s[i]
      if last[1] - x[1] > seconds * 60 then break end
      -- the pumps: a sample a second over the window's seconds (its first sample, at the window's start, left out)
      if first and first[7] then on, pumps, ps = on + first[6], pumps + first[7], ps + 1 end
      first = x
      n = n + 1
      sum = sum + x[2]
      low, high = math.min(low, x[2]), math.max(high, x[2])
    end
    if n == 1 and last[7] then on, pumps, ps = last[6], last[7], 1 end
    local npumps = last[7] or #(rec.pumps or {})
    local span = math.floor((last[1] - first[1]) / 60 + 0.5)
    local out = {seconds=span, samples=n, speed_mean=r1(sum / n), speed_low=r1(low), speed_high=r1(high), speed_first=r1(first[2]),
      speed_last=r1(last[2]), fluids={}, pumps=npumps, pump_duty=pumps > 0 and math.floor(on / pumps * 100 + 0.5) or nil,
      pump_samples=ps}
    local parts = {}
    for i, name in ipairs(rec.fluids or {}) do
      local u = (last[3][i] or 0) - (first[3][i] or 0)
      local m = (last[4][i] or 0) - (first[4][i] or 0)
      local t0, t1 = first[5][i] or 0, last[5][i] or 0
      out.fluids[name] = {used=math.floor(u + 0.5), made=math.floor(m + 0.5), tanks_first=math.floor(t0 + 0.5), tanks_last=math.floor(t1 + 0.5)}
      parts[#parts+1] = string.format('%s used %d, made %d, thruster tanks %d -> %d', name, math.floor(u + 0.5), math.floor(m + 0.5),
        math.floor(t0 + 0.5), math.floor(t1 + 0.5))
    end
    local head = span < seconds and string.format('last %d s (sampled that long)', span) or string.format('last %d s', seconds)
    out.line = string.format('%s: speed mean %g km/s (lowest %g, highest %g; %g -> %g)', head, out.speed_mean, out.speed_low, out.speed_high,
      out.speed_first, out.speed_last)
      .. (#parts > 0 and '; ' .. table.concat(parts, '; ') or '; no thrusters')
      .. (out.pump_duty and string.format('; %d pumps working %d%% of the time (%d samples, one a second at a phase %d ticks later each second: %s)',
        out.pumps, out.pump_duty, ps, STRIDE, ps >= 60 and 'every tick of a second sampled once a minute' or string.format('%d of the 60 ticks of a second sampled', ps))
        or npumps > 0 and string.format('; %d pumps, not sampled yet', npumps) or '; no pumps')
    return out
  end
  -- The windows for a platform: {lines, windows}, nil before its first two samples.
  function M.read(pl)
    local rec = store()[pl.index]
    if not rec or #rec.samples < 2 then return nil end
    local out = {lines={}, windows={}}
    for _, w in ipairs(WINDOWS) do
      local r = window(rec, w)
      out.windows[#out.windows+1] = r
      out.lines[#out.lines+1] = r.line
      if r.seconds < w then break end
    end
    return out
  end
  return M
end
