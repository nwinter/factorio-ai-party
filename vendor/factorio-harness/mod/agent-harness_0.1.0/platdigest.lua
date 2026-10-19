-- platform_digest {platform} (batch24 B1, Luna: about 15 reads across platform, platform_endurance, platform_supply,
-- platform_defense, inspect and platform_plan to diagnose Kestrel II): one read per platform from those reads' own code,
-- the stopped or blocked first: route and arrival, hub slots and the chunks in it, chunks collected and where each goes,
-- crushers, thruster fuel and oxidizer makers, tanks with their trend and run-out, ammunition made and used, turrets
-- and the ammunition that reaches them or is stranded, power. A read that fails is named with its error; the rest stand.
return function(api)
  local M = {}
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function err(e)
    local t, n = tostring(e), 1
    while n > 0 do t, n = t:gsub('^[^:%s]*:%d+: ', '') end
    return t
  end
  local FLUIDS = {['thruster-fuel']=true, ['thruster-oxidizer']=true}
  local SHOW = 8
  -- The rows of a supply section: the lines after its header, up to the next header.
  local function section(lines, head, rowpat)
    local out, on = {}, false
    for _, l in ipairs(lines or {}) do
      if l:find(head) then on = true; out[#out+1] = l
      elseif on and l:find(rowpat) then out[#out+1] = l
      elseif on then break end
    end
    return out
  end
  function M.read(p, a)
    assert(type(a.platform) == 'string' and a.platform ~= '', 'platform: the platform\'s name')
    local pl = api.platform(p, a.platform)
    assert(pl.surface, 'platform ' .. pl.name .. ' has no surface yet')
    local args = {platform=pl.name}
    local errors = {}
    local function run(name)
      local ok, out = pcall(api.reads[name], p, args)
      if ok then return out end
      errors[#errors+1] = name .. ': ' .. err(out)
    end
    local plat, supply, endu, def = run('platforms'), run('platform_supply'), run('platform_endurance'), run('platform_defense')
    local row = plat and plat.platforms and plat.platforms[1] or {}
    local out = {platform=pl.name}
    local lines = {}
    -- Stopped or blocked first: the supply chain's stops, collectors no turret reaches, hull sides with gaps, power.
    local stopped = {}
    for _, s in ipairs(supply and (supply.stops or (supply.first_stop and {supply.first_stop})) or {}) do stopped[#stopped+1] = s end
    for _, c in ipairs(def and def.collectors or {}) do
      if (c.covered_by or 0) == 0 then stopped[#stopped+1] = string.format('collector (%g,%g): no turret reaches its front', c.position.x, c.position.y) end
    end
    for _, sd in ipairs(def and def.sides or {}) do
      if (sd.uncovered or 0) > 0 then stopped[#stopped+1] = string.format('%s side: %d edge tiles no turret reaches', sd.side, sd.uncovered) end
    end
    if endu and (endu.no_power or 0) > 0 then stopped[#stopped+1] = string.format('%d machines on no power', endu.no_power) end
    out.stopped = #stopped > 0 and stopped or nil
    lines[#lines+1] = #stopped == 0 and 'stopped or blocked: none of the collectors, crushers, makers, thrusters, guns, turret cover or power'
      or string.format('stopped or blocked (%d): %s%s', #stopped, table.concat(stopped, ' | ', 1, math.min(SHOW, #stopped)), #stopped > SHOW and string.format(' | +%d more', #stopped - SHOW) or '')
    -- Route and arrival.
    local route = {}
    route[#route+1] = row.state and ('state ' .. tostring(row.state)) or nil
    if row.at then route[#route+1] = 'at ' .. tostring(row.at) end
    if row.leg then route[#route+1] = string.format('leg %s, %s km left%s', row.leg, tostring(row.leg_left_km), row.eta_min and string.format(', arrives in about %g min', row.eta_min) or '') end
    if row.next_stop then route[#route+1] = 'next stop ' .. tostring(row.next_stop) end
    if row.speed_kms then route[#route+1] = string.format('speed %g km/s', row.speed_kms) end
    if row.paused then route[#route+1] = 'paused' end
    if type(row.schedule) == 'string' then route[#route+1] = 'schedule ' .. row.schedule end
    out.route = #route > 0 and table.concat(route, '; ') or nil
    lines[#lines+1] = 'route: ' .. (out.route or 'unknown')
    -- The hub: free slots, the chunks in it.
    out.hub = (row.hub_slots and ('hub slots ' .. row.hub_slots) or (endu and endu.hub_slots and 'hub slots ' .. endu.hub_slots) or 'hub slots unknown')
      .. (row.hub_chunks and '; ' .. row.hub_chunks or '; no asteroid chunks in the hub')
    lines[#lines+1] = out.hub
    -- Chunks collected and where each goes.
    out.chunks = {}
    if endu and endu.chunks_collected then out.chunks[#out.chunks+1] = 'collected: ' .. table.concat(endu.chunks_collected, ', ') end
    for _, c in ipairs(supply and supply.chunks or {}) do out.chunks[#out.chunks+1] = c end
    for _, f in ipairs(supply and supply.chunk_flags or {}) do out.chunks[#out.chunks+1] = f end
    if #out.chunks == 0 then out.chunks = nil end
    for _, c in ipairs(out.chunks or {}) do lines[#lines+1] = 'chunks: ' .. c end
    -- Crushers, propellant makers, thrusters (platform_supply's sections).
    out.crushers = section(supply and supply.lines, '^%d+ crushers?$', '^crusher ')
    out.makers = section(supply and supply.lines, '^%d+ fuel and oxidizer makers?$', '^%S+ %(')
    for _, l in ipairs(out.crushers) do lines[#lines+1] = l end
    for _, l in ipairs(out.makers) do lines[#lines+1] = l end
    for _, l in ipairs(supply and supply.lines or {}) do if l:find('^%d+ thrusters?:') then lines[#lines+1] = l; out.thrusters = l end end
    if #out.crushers == 0 then out.crushers = nil end
    if #out.makers == 0 then out.makers = nil end
    -- Tanks (thruster fuel and oxidizer) and ammunition, as platform_endurance reads them: stock, made and used, run-out.
    out.tanks, out.ammo = {}, {}
    for _, r in ipairs(endu and endu.resources or {}) do
      if FLUIDS[r.name] then out.tanks[#out.tanks+1] = r.line
      elseif try(function() return prototypes.item[r.name].type end) == 'ammo' then out.ammo[#out.ammo+1] = r.line end
    end
    -- the fuel outlook (batch27 B1): held, made and used a minute, and whether it lasts the leg
    if endu and endu.fuel_outlook then out.fuel_outlook = endu.fuel_outlook; lines[#lines+1] = 'fuel outlook: ' .. endu.fuel_outlook end
    for _, l in ipairs(out.tanks) do lines[#lines+1] = 'tank: ' .. l end
    for _, l in ipairs(out.ammo) do lines[#lines+1] = 'ammo: ' .. l end
    if #out.tanks == 0 then out.tanks = nil end
    if #out.ammo == 0 then out.ammo = nil end
    -- Turrets: how many, empty, the ammunition that reaches them and what is stranded.
    if def then
      local n, empty = #(def.turrets or {}), 0
      for _, t in ipairs(def.turrets or {}) do if t.ammo == 'no ammo' then empty = empty + 1 end end
      local f = def.feed or {}
      out.turrets = string.format('%d turrets, %d empty; ammunition that can reach a turret %s, stranded %s%s', n, empty, tostring(f.reaches or '?'), tostring(f.stranded or '?'),
        f.stranded_groups and #f.stranded_groups > 0 and ' (' .. table.concat(f.stranded_groups, '; ', 1, math.min(4, #f.stranded_groups)) .. ')' or '')
      lines[#lines+1] = 'turrets: ' .. out.turrets
    end
    if endu and endu.solar then out.power = endu.solar; lines[#lines+1] = 'power: ' .. endu.solar end
    -- (d18 batch37 D4) every agent's queued or running jobs on this platform (platjobs.lua)
    local okj, jobs = pcall(api.jobs, pl.name)
    if okj and jobs then out.jobs = jobs; for _, l in ipairs(jobs) do lines[#lines+1] = 'job: ' .. l end end
    out.lines = lines
    out.errors = #errors > 0 and errors or nil
    out.note = 'from platforms, platform_supply, platform_endurance and platform_defense; each of those reads gives the detail'
    return out
  end
  M.schema = {platform_digest = {platform='platform name',
    returns='lines: stopped or blocked first (the supply chain\'s stops: collectors, crushers, fuel and oxidizer makers, thrusters, empty guns; collectors no turret reaches; hull sides with uncovered edge tiles; machines on no power), route (state, where, leg, km left, arrival, next stop, speed, schedule), hub slots and the asteroid chunks in it, chunks collected and where each goes, fuel outlook (thruster fuel and oxidizer held, made and used a minute, whether each lasts the leg), crushers and fuel and oxidizer makers (recipe, state, in and out), thrusters, tanks (thruster fuel and oxidizer: stock, made and used, run-out), ammunition (stock by place, made and used, stranded), turrets (count, empty, ammunition that reaches them and stranded), power; job: each agent\'s queued or running job that acts on or waits on the platform (owner, lane, the step now and pending, its wait and what it saw, its drops so far); the same as fields (stopped, route, hub, chunks, crushers, makers, thrusters, tanks, ammo, turrets, power, jobs); errors (a read that failed, by name). Read only'}}
  return M
end
