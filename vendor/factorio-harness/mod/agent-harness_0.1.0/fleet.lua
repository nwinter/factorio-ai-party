-- fleet {platform?} (d17 batch20 B4, Sol: silo, platform and queue reads took several calls on every port visit, and a
-- finished queue step was read as cargo aboard): one line a platform, from the reads that exist: where it is and the
-- current stop with its departure conditions (platform_gate), what the hub holds now (its largest stacks), the hub
-- requests by state (shipment.lua: delivered, in flight, launched, loading in a silo, waiting with the gate that holds
-- it), what is aboard for which stop's landing pads, the rockets on the way to it now, thruster fuel and its 10-minute
-- trend, and the delay: the first waiting request's gate at the stop it is at. Read only; bounded as shipment is (16
-- platforms).
return function(api)
  local M = {}
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function top(counts, n)
    local list = {}
    for name, c in pairs(counts or {}) do if c > 0 then list[#list+1] = {name, c} end end
    table.sort(list, function(a, b) return a[2] > b[2] or a[2] == b[2] and a[1] < b[1] end)
    local out = {}
    for i = 1, math.min(n, #list) do out[i] = list[i][1] .. '*' .. list[i][2] end
    return #out > 0 and table.concat(out, ' ') .. (#list > n and string.format(' +%d more', #list - n) or '') or 'nothing', #list
  end
  -- One platform's line and its parts.
  function M.platform(p, pl, cache)
    local parts = {}
    local gate = try(function() return api.gate(p, {platform=pl.name}).lines[1] end)
    parts[#parts+1] = gate or (pl.name .. ': ?')
    local counts = api.hub_counts and try(function() return api.hub_counts(pl) end) or {}
    parts[#parts+1] = 'hub holds ' .. top(counts, 6)
    local _, rows = api.shipment_platform(pl, cache)
    local by, waiting, aboard, moving = {}, {}, {}, {}
    for _, r in ipairs(rows or {}) do
      if r.direction == 'up' then
        by[r.state] = (by[r.state] or 0) + 1
        if r.state == 'waiting' then waiting[#waiting+1] = r
        elseif r.state ~= 'delivered' then moving[#moving+1] = string.format('%s %s from %s', r.state, r.item, r.planet) end
      elseif r.state ~= 'spilled' then
        aboard[r.planet] = aboard[r.planet] or {}
        table.insert(aboard[r.planet], r.item .. '*' .. r.count)
      end
    end
    local up = {}
    for _, k in ipairs({'delivered', 'in flight', 'launched', 'loading', 'waiting'}) do if by[k] then up[#up+1] = by[k] .. ' ' .. k end end
    if #up > 0 then parts[#parts+1] = 'requests: ' .. table.concat(up, ', ') .. (#moving > 0 and ' (' .. table.concat(moving, ', ', 1, math.min(4, #moving)) .. (#moving > 4 and ', ...' or '') .. ')' or '') end
    local planets = {}
    for planet in pairs(aboard) do planets[#planets+1] = planet end
    table.sort(planets)
    for _, planet in ipairs(planets) do
      table.sort(aboard[planet])
      parts[#parts+1] = 'aboard for ' .. planet .. '\'s pads: ' .. table.concat(aboard[planet], ' ')
    end
    local inc = api.incoming and try(function() return api.incoming(pl) end)
    parts[#parts+1] = inc and string.format('%d rocket%s on the way: %s', inc.rockets, inc.rockets == 1 and '' or 's', inc.cargo) or 'no rocket on the way'
    local fuel = api.fuel_text and try(function() return api.fuel_text(pl) end)
    if fuel then parts[#parts+1] = fuel end
    local off = api.requests_off and try(function() return api.requests_off(pl) end)
    if off then parts[#parts+1] = off end
    -- the delay: the first waiting request at the stop it is at, else the first waiting one
    local w = api.where and try(function() return api.where(pl) end) or {}
    local first
    for _, r in ipairs(waiting) do if w.stopped and w.at == r.planet then first = r; break end end
    first = first or waiting[1]
    if first then
      parts[#parts+1] = string.format('waits on %s %d from %s (the hub holds %d): %s%s', first.item, first.min or 0, first.planet, first.hub or 0, first.gate or '?',
        #waiting > 1 and string.format(' (+%d more waiting)', #waiting - 1) or '')
    end
    return table.concat(parts, '; ')
  end
  -- leg (batch27 B2, Astra: shipment and queue_status every minute on each courier leg, several calls to find a payload
  -- already rising): for one platform, the caller's waits that name it (the action running, and the current step of the
  -- body, remote and platform lanes), each read as the wait reads it now; and each rocket on its way to it with its
  -- arrival (from the last arrivals' launch-to-arrival times).
  local function names(c, name)
    if type(c) ~= 'table' then return false end
    if c.platform == name then return true end
    for _, m in ipairs(c.conditions or {}) do if names(m, name) then return true end end
    return false
  end
  function M.leg(p, pl)
    local lines = {}
    local s = api.state and api.state() or {}
    local waits = {}
    local act = (s.active or {})[p.index]
    if act and act.kind == 'wait_until' and names(act.condition, pl.name) then waits[#waits+1] = {where='your wait now', c=act.condition} end
    local keys = {{'queues', 'body lane'}, {'remote_queues', 'remote lane'}}
    for lane in pairs(s.platform_lanes or {}) do keys[#keys+1] = {'lane_queues|' .. lane, 'platform lane ' .. lane} end
    for _, k in ipairs(keys) do
      local q = (s[k[1]] or {})[p.index]
      local st = q and q.current
      if st and st.action == 'wait_until' and names(st.args, pl.name) then waits[#waits+1] = {where='your ' .. k[2] .. ' step', c=st.args} end
    end
    for _, w in ipairs(waits) do
      local ok, met, saw = pcall(api.condition, p, w.c)
      lines[#lines+1] = string.format('%s: %s', w.where, ok and ((met and 'met: ' or 'not yet: ') .. tostring(saw)) or ('unread: ' .. tostring(met)))
    end
    if #waits == 0 then lines[#lines+1] = 'no wait of yours names ' .. pl.name end
    local inc = api.incoming and try(function() return api.incoming(pl) end)
    for _, l in ipairs(inc and inc.lines or {}) do lines[#lines+1] = l end
    if not inc then lines[#lines+1] = 'no rocket on the way to it' end
    return lines
  end
  function M.read(p, a)
    assert(a.platform == nil or type(a.platform) == 'string', 'platform is a platform name')
    assert(a.leg == nil or type(a.leg) == 'boolean', 'leg must be true or false')
    if a.leg then
      assert(a.platform, 'leg goes with platform')
      local pl
      for _, x in pairs(p.force.platforms) do if x.valid and x.name == a.platform then pl = x end end
      if not pl then error('no platform of ours named ' .. a.platform, 0) end
      local lines = {M.platform(p, pl, {})}
      for _, l in ipairs(M.leg(p, pl)) do lines[#lines+1] = l end
      return {lines=lines, note='the fleet line (its gate, hub, requests and what holds the first waiting one), then your waits naming it read now, then each rocket on its way with its arrival; read only'}
    end
    local lines, cache, n = {}, {}, 0
    for _, pl in pairs(p.force.platforms) do
      if pl.valid and pl.hub and pl.hub.valid and (a.platform == nil or pl.name == a.platform) then
        n = n + 1
        if n > 16 then break end
        lines[#lines+1] = M.platform(p, pl, cache)
      end
    end
    if a.platform and n == 0 then error('no platform of ours named ' .. a.platform, 0) end
    table.sort(lines)
    return {lines=#lines > 0 and lines or {'no platform of ours'}, note='what the hub, its requests, silos, rockets and the schedule show now; shipment {platform} has each request\'s line; read only'}
  end
  M.schema = {fleet={platform='optional platform name (default every one of ours, at most 16)',leg='optional true, with platform: a courier leg in one read: the fleet line, then each wait of yours that names the platform (the action running and the current step of each lane), read as the wait reads it now (met or not yet, with what the hub holds), then each rocket on its way to it: from where, launched how long ago, rising or coming down, and when it arrives at the last arrivals\' launch-to-arrival time',
    returns='lines: one a platform: where it is and its current stop with each departure condition against what the hub holds (as platform_gate), hub holds (its 6 largest stacks), requests by state (delivered, in flight, launched, loading, waiting) with the ones on their way, aboard for PLANET\'s pads (what that stop\'s landing pads ask of the hub now), the rockets on the way to it now and their cargo, thruster fuel and its 10-minute trend, waits on (the first waiting request at the stop it is at, else the first: the gate that holds it); note. Read only'}}
  return M
end
