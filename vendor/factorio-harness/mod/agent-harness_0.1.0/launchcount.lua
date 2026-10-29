-- launchcount (d29 batch346 LC, Astra #2754: "Asterion minimum safe cap 5 AQ launches/hour was verbal; native
-- requests/min payload 10 produced 23 pods before audit (81886081..81928832), 18 repair pods 303 packs. Count requests
-- does not cap launches; teammate correction races already loaded/in flight pods") The rockets to a platform in a
-- window or since a tick, by origin planet: launched (the pod log's rockets sent: landed, and in flight not yet landed)
-- and loaded (silos with a rocket ready whose request target is the platform: the next launches it). Facts for the
-- shipment read and the launches_at_least condition; the harness changes nothing: a cap is the agent's own guard.
return function(api)
  local M = {}
  M.WINDOW_MAX = 86400  -- seconds: a day at most
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local READY
  -- {launched, landed, in_flight, gone, loaded, total, since_tick, complete, origin, by_planet, line}; gone: a pod removed
  -- with no landing (its platform gone), counted as launched
  function M.count(force, platform, o)
    READY = READY or defines.rocket_silo_status.rocket_ready
    local since = o.since_tick or (game.tick - math.floor(o.window * 60))
    local ups, complete = api.ups(platform, since, o.origin)
    local landed, flying, gone, by = 0, 0, 0, {}
    for _, u in ipairs(ups) do
      if u.landed then landed = landed + 1 elseif u.gone then gone = gone + 1 else flying = flying + 1 end
      by[u.planet] = (by[u.planet] or 0) + 1
    end
    local pl
    for _, x in pairs(force.platforms or {}) do if x.valid and x.name == platform then pl = x end end
    local loaded, silos, unread = 0, {}, {}
    if pl then
      for _, s in pairs(game.surfaces) do
        if not try(function() return s.platform end) and (not o.origin or s.name == o.origin) then
          local list = try(function() return api.silos(force, s) end)
          if not list then unread[#unread+1] = s.name end
          for _, e in ipairs(list or {}) do
            if e.valid and e.rocket_silo_status == READY and try(function() return e.transitional_request_target == pl end) then
              loaded = loaded + 1
              silos[#silos+1] = string.format('%s (%g,%g)', s.name, e.position.x, e.position.y)
            end
          end
        end
      end
    end
    local launched = #ups
    local total = launched + loaded
    local parts = {}
    for planet, n in pairs(by) do parts[#parts+1] = planet .. ' ' .. n end
    table.sort(parts)
    local span = o.since_tick and string.format('since tick %d', since) or string.format('in the last %g s (since tick %d)', o.window, since)
    local line = string.format('rockets to %s %s%s: %d launched (%d landed, %d in flight%s%s) + %d loaded in silos aimed at it%s = %d',
      platform, span, o.origin and ' from ' .. o.origin or '', launched, landed, flying, gone > 0 and string.format(', %d gone unlanded', gone) or '',
      #parts > 0 and '; ' .. table.concat(parts, ', ') or '', loaded, #silos > 0 and ' (' .. table.concat(silos, ', ') .. ')' or '', total)
    if #unread > 0 then line = line .. '; silos not read yet on ' .. table.concat(unread, ', ') .. ' (the census\'s first pass)' end
    if not complete then line = line .. '; the pod log\'s oldest kept journey is after the window began: some may be missing (at least)' end
    if not pl then line = line .. '; no platform of ours named ' .. platform .. ' (no silo read)' end
    return {platform=platform, origin=o.origin, since_tick=since, window=o.window, launched=launched, landed=landed, in_flight=flying,
      gone=gone > 0 and gone or nil, newest_tick=ups[1] and ups[1].sent, oldest_tick=ups[#ups] and ups[#ups].sent, loaded=loaded,
      silos_unread=#unread > 0 and unread or nil, loaded_silos=#silos > 0 and silos or nil, total=total, by_planet=by, complete=complete, line=line}
  end
  function M.check_args(a)
    assert(type(a.platform) == 'string' and a.platform ~= '', 'platform: a platform name')
    assert((a.window == nil) ~= (a.since_tick == nil), 'window (seconds, 1..' .. M.WINDOW_MAX .. ') or since_tick: one of them')
    assert(a.window == nil or (type(a.window) == 'number' and a.window >= 1 and a.window <= M.WINDOW_MAX), 'window is 1..' .. M.WINDOW_MAX .. ' seconds')
    assert(a.since_tick == nil or (type(a.since_tick) == 'number' and a.since_tick >= 0), 'since_tick is a game tick')
    assert(a.origin == nil or (type(a.origin) == 'string' and prototypes.space_location[a.origin]), 'origin: a planet name')
  end
  -- shipment {launches: true, platform, window | since_tick, origin?}
  function M.read(p, a)
    M.check_args(a)
    local r = M.count(p.force, a.platform, {window=a.window, since_tick=a.since_tick, origin=a.origin})
    r.note = 'launched: the pod log\'s rockets sent to it (landed, or in flight); loaded: silos with a rocket ready whose request target is it, '
      .. 'launched next; the harness changes nothing (a cap is your own guard: wait_until or a queue guard on launches_at_least, with your steps). Read only'
    return r
  end
  return M
end
