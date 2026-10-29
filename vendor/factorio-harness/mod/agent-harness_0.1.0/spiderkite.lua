-- spider_kite (d24 batch191 QAG1, viewer Aurora site:4818: "Beyond batch 189, could a bounded native Spidertron combat
-- action move/fire and react to closing threats, stalled movement or low ammo while the model waits?"): kite for a
-- spidertron the agent rides or sends by remote view. Only what a player has: the spidertron GUI's two targeting
-- switches (its guns then fire at enemies in range by themselves) and its remote (a click: the route becomes one target).
-- Every SCAN ticks it reads its health, shield and rockets, and the enemies within radius in chunks our force sees:
-- - the nearest unit nearer than min_distance: a route away from the group's centre (the units within max_distance)
--   out to the band's far side, turned off tiles its legs cannot stand on;
-- - the nearest unit within the band: it stands (its route cleared) and the guns fire;
-- - no unit within max_distance+8 and a spawner or worm beyond range: a route to range-2 tiles off it;
-- - units beyond the band only: it stands and waits for them; none left: back to position when given, else clear.
-- A long leg (back to position, toward a nest) that crosses water its legs cannot gets a path round it (spiderpath.lua).
-- A route with no progress (MOVED tiles nearer its target than it has been; a moving target: FAR tiles moved) for STALL
-- ticks with water ahead backs off along its trail and asks again for a path, up to RECOVER times (d26 batch247, as
-- go_to's); with none ahead it is turned 60 degrees once; then it ends stalled. Ends: low_health, low_shield,
-- out_of_ammo (rockets under ammo_below), stalled, clear, route_changed (its route set by another call or a player),
-- out_of_coverage (by remote view: its chunk out of our force's sight), destroyed, timed_out (ticks). Off scan ticks
-- nothing runs. Facts only.
return function(api)
  local M = {}
  M.schema = {
    spider_kite={vehicle='the spidertron by unit_number or {x,y} (any tile of it): one you ride, or by remote view one in a chunk our force sees now (radar coverage or a character\'s sight); none: the one you ride',
      position='optional {x,y}: with no enemies left it walks back there, then ends clear',
      min_distance='keep units at least this far (default 16)',max_distance='band edge (default 28; at most its guns\' range, 36)',
      range='walk to a spawner or worm until it is this near (default its guns\' range - 2: 34) when no unit is within max_distance + 8',
      radius='enemy scan 8..64 (default 40), in chunks our force sees',
      min_health='stop below this health fraction (default 0.4, or your standing retreat_guard\'s health_below)',
      min_shield='optional: stop below this grid shield fraction (default your standing retreat_guard\'s shield_below)',
      ammo_below='stop when its ammo slots hold fewer rockets (default 1)',
      retreat='optional {x,y} (or {to: {x,y}}): on low_health, low_shield or out_of_ammo its route becomes this (as go_to, its guns left on); default your standing retreat_guard\'s to; false: none',
      ticks='1..36000 (default 3600)',
      note='its guns on auto (both targeting switches, as its GUI sets them; back as they were at the end) and its legs moved by route targets as its remote clicks them, read every 10 ticks: a unit nearer than min_distance: a route away from the group (the units within max_distance) out to the band\'s far side, off tiles its legs cannot stand on; a unit within the band: it stands; a leg back to position or toward a nest that crosses water its legs cannot (over 12 tiles of it on the straight line) goes round it by a path; a route with no progress for 2 s with water ahead backs off along its trail and asks again for a path round the water (any water counting; from an islet across to land first), up to 3 times; with no water ahead it is turned 60 degrees once; then it ends stalled (last.recovery says what was tried); its go_to route is replaced at the start',
      outcomes='clear | low_health | low_shield | out_of_ammo | stalled | route_changed (another call set, appended to or cleared its route, the same target too, or a player set it or emptied it short of the kite\'s target: it yields, its route and switches left as they stand) | out_of_coverage (by remote view) | destroyed | timed_out; last reports why (in words), kills, kills_by, ammo_used, ammo_left, enemies_left, turns, spidertron (where, health, shield), retreat, targeting'},
  }
  M.SCAN, M.STALL, M.MOVED, M.FAR, M.RECOVER = 10, 120, 1, 6, 3
  local STRUCTURES = {['unit-spawner']=true, turret=true}
  local TYPES = {'unit', 'spider-unit', 'segmented-unit', 'unit-spawner', 'turret'}
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function dist(a, b) return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2) end
  local function at(q) return string.format('(%g,%g)', math.floor(q.x * 10 + 0.5) / 10, math.floor(q.y * 10 + 0.5) / 10) end
  local function pct(x) return math.floor(x * 100 + 0.5) end
  local function ammo(spider)
    local inv = try(function() return spider.get_inventory(defines.inventory.spider_ammo) end)
    return inv and inv.get_item_count() or 0
  end
  M.ammo = ammo
  -- health and shield as fractions (shield nil without a grid shield)
  local function fractions(spider)
    local sf
    local g = try(function() return spider.grid end)
    if g and g.max_shield > 0 then sf = g.shield / g.max_shield end
    return spider.health / spider.max_health, sf
  end
  -- The longest range among its guns (a spidertron's rocket launchers: 36), or nil.
  local function gun_range(spider)
    local best
    for _, gun in pairs(try(function() return spider.prototype.guns end) or {}) do
      local r = try(function() return gun.attack_parameters.range end)
      if r and (not best or r > best) then best = r end
    end
    return best
  end
  local function hostile(force)
    local out = {}
    for _, f in pairs(game.forces) do
      if f ~= force and f.name ~= 'neutral' and not force.get_friend(f) and not force.get_cease_fire(f) then out[#out + 1] = f.name end
    end
    return out
  end
  local function leg_layers(spider)
    local legs = try(function() return spider.get_spider_legs() end) or {}
    local mask = legs[1] and try(function() return legs[1].prototype.collision_mask end)
    local out = {}
    for l in pairs(mask and mask.layers or {}) do out[l] = true end
    return out
  end
  local function visible(action, surface, q)
    local f = game.forces[action.force]
    return f and f.is_chunk_visible(surface, {x=math.floor(q.x / 32), y=math.floor(q.y / 32)}) or false
  end
  -- A tile its legs can stand on (by tile name, cached on the action: prototype reads are slow).
  local function standable(spider, action, q)
    if not next(action.legs) then return true end
    local t = try(function() return spider.surface.get_tile(q.x, q.y) end)
    if not t then return true end
    local name = t.name
    local ok = action.tiles[name]
    if ok == nil then
      ok = true
      local m = try(function() return t.prototype.collision_mask end)
      for l in pairs(m and m.layers or {}) do if action.legs[l] then ok = false; break end end
      action.tiles[name] = ok
    end
    return ok
  end
  local function turn(pos, q, deg)
    local a = math.rad(deg)
    local dx, dy = q.x - pos.x, q.y - pos.y
    return {x=pos.x + dx * math.cos(a) - dy * math.sin(a), y=pos.y + dx * math.sin(a) + dy * math.cos(a)}
  end
  -- q, or the nearest turn of it (30..150 degrees either way) its legs can stand on; q when none.
  local function footing(spider, action, pos, q)
    local P = api.path
    local function fine(r)
      if not standable(spider, action, r) then return false end
      local ok, b = true, nil
      if P then ok, b = pcall(P.segment, spider.surface, pos, r) end
      return not (ok and b)
    end
    if fine(q) then return q end
    for _, deg in ipairs({30, -30, 60, -60, 90, -90, 120, -120, 150, -150}) do
      local r = turn(pos, q, deg)
      if fine(r) then return r end
    end
    return q
  end
  -- The remote's click: the route becomes q (unless it already leads within 3 tiles of q).
  local function go(spider, action, q, tick, force)
    if action.dest and not force and dist(action.dest, q) < 3 then return end
    spider.autopilot_destination = nil
    spider.add_autopilot_destination(q)
    action.writes = action.writes + 1
    if not action.dest then action.since, action.check = tick, tick end
    action.dest, action.route_pts = {x=q.x, y=q.y}, nil
    return true
  end
  -- (d24 batch191 addendum) a long leg (to position, toward a nest) that crosses water its legs cannot: a path round it
  -- requested (spiderpath.lua); M.routed writes it.
  local function round_water(spider, action)
    local P = api.path
    if not P then return nil end
    local ok, lines = pcall(P.plan, spider, {action.dest}, {owner='kite', index=action.index, claim=action.set_seq})
    if ok and lines then action.water = lines[1]; return lines[1] end
  end
  -- (d28 batch310 item 5) another call took the route since this kite's claim: it yields, its route never written back.
  -- -> the line, or nil while the route is its own.
  local function taken(action)
    if not (api.seq and action.set_seq) then return nil end
    local seq = api.seq(action.unit)
    if seq == action.set_seq then return nil end
    local s = api.set_of and api.set_of(action.unit) or {}
    return string.format('%s set its route (%s) after this spider_kite began: it yields; the new route and the targeting switches stay as they are', tostring(s.by or 'another call'), s.how or 'a call')
  end
  function M.routed(action, plan, spider, pts, notes)
    if not (action and action.kind == 'spider_kite' and action.spider == spider and action.dest) then return end
    -- a path that came after another call took the route: not written (the kite yields at its next read)
    if taken(action) or (plan.claim and plan.claim ~= action.set_seq) then return end
    -- a back-off's plan was asked toward the target it backed off from (action.base): its route goes on there
    if dist(plan.targets[1], action.dest) > 3 then
      if not (action.base and dist(plan.targets[1], action.base) <= 3) then return end
      action.dest = {x=action.base.x, y=action.base.y}
    end
    -- (d26 batch247 NV2) no path found: said with the stall (last.no_path)
    local found = false
    for _, seg in pairs(plan.segs or {}) do if type(seg) == 'table' then found = true end end
    action.no_path = not found and notes and #notes > 0 and table.concat(notes, '; ') or nil
    if api.path.write(spider, pts) then return end
    action.route_pts = pts
    action.writes = action.writes + 1
    action.routed = string.format('round the water to %s: %d points', at(action.dest), #pts)
  end
  local function on_route(action, q)
    if dist(q, action.dest) <= 0.5 then return true end
    for _, w in ipairs(action.route_pts or {}) do if dist(q, w) <= 0.5 then return true end end
    return false
  end
  local function halt(spider, action)
    if action.dest then spider.autopilot_destination = nil; action.dest = nil end
  end
  local function first(spider)
    local d = try(function() return spider.autopilot_destinations end)
    local q = d and d[1]
    return q and (q.position or q) or nil
  end
  -- The call's checks and the action. how: 'riding' or 'remote'; guard: the standing retreat_guard or nil.
  function M.plan(p, a, spider, how, guard)
    local range = gun_range(spider)
    if not range then error(spider.name .. ' has no guns', 0) end
    local num = function(v, what) if v ~= nil and type(v) ~= 'number' then error(what .. ' must be a number', 0) end return v end
    local bmin = num(a.min_distance, 'min_distance') or 16
    local bmax = num(a.max_distance, 'max_distance') or math.min(28, range - 4)
    if bmin < 4 or bmax <= bmin or bmax > range then error(string.format('need 4 <= min_distance < max_distance <= %g (its guns\' range)', range), 0) end
    local srange = num(a.range, 'range') or range - 2
    if srange < 4 or srange > range then error(string.format('range is 4..%g (its guns\' range)', range), 0) end
    local function frac(v, what) if v ~= nil and (type(v) ~= 'number' or v < 0 or v >= 1) then error(what .. ' is a fraction 0..1', 0) end return v end
    local min_health = frac(a.min_health, 'min_health') or (guard and guard.health_below) or 0.4
    local min_shield = frac(a.min_shield, 'min_shield') or (guard and guard.shield_below)
    local ammo_below = api.integer(a.ammo_below, 1, 1, 100000, 'ammo_below')
    local h, s = fractions(spider)
    if h < min_health then error(string.format('%s is at %d%% health, under min_health %d%%', spider.name, pct(h), pct(min_health)), 0) end
    if min_shield and s and s < min_shield then error(string.format('%s\'s shield is at %d%%, under min_shield %d%%', spider.name, pct(s), pct(min_shield)), 0) end
    local left = ammo(spider)
    if left < ammo_below then
      error(string.format('%s holds %d rockets in its ammo slots, under ammo_below %d: transfer rockets into it', spider.name, left, ammo_below), 0)
    end
    local back
    if a.retreat ~= false then
      local r = a.retreat
      if r ~= nil then
        if type(r) ~= 'table' then error('retreat is {x,y} or {to: {x,y}}, or false for none', 0) end
        back = api.position(r.to or r)
      elseif guard and guard.to then back = api.position(guard.to) end
    end
    return {kind='spider_kite', spider=spider, unit=spider.unit_number, how=how, force=p.force.name, forces=hostile(p.force),
      band_min=bmin, band_max=bmax, range=srange, gun_range=range, radius=api.integer(a.radius, 40, 8, 64, 'radius'),
      min_health=min_health, min_shield=min_shield, ammo_below=ammo_below, anchor=a.position and api.position(a.position),
      back=back, back_standing=a.retreat == nil and back and true or nil,
      until_tick=game.tick + api.integer(a.ticks, 3600, 1, 36000, 'ticks'),
      kills=0, kills_by={}, ammo_start=left, next_scan=game.tick, writes=0, turns=0, turned=0, legs=leg_layers(spider), tiles={}, index=p.index}
  end
  -- Its guns on: both switches (as a player sets them in its GUI); the switches before are kept for the end.
  function M.start(action)
    local spider = action.spider
    local cur = spider.vehicle_automatic_targeting_parameters or {}
    action.switches = {auto_target_with_gunner=cur.auto_target_with_gunner, auto_target_without_gunner=cur.auto_target_without_gunner}
    spider.vehicle_automatic_targeting_parameters = {auto_target_with_gunner=true, auto_target_without_gunner=true}
    local now = spider.vehicle_automatic_targeting_parameters
    return {before=action.switches, now={auto_target_with_gunner=now.auto_target_with_gunner, auto_target_without_gunner=now.auto_target_without_gunner}}
  end
  local function scan(spider, action)
    local pos = spider.position
    local found = spider.surface.find_entities_filtered{position=pos, radius=action.radius, force=action.forces, type=TYPES, limit=256}
    local seen, unit, du, st, ds, n, cx, cy = 0, nil, math.huge, nil, math.huge, 0, 0, 0
    local vis = {}
    for _, e in pairs(found) do
      if e.valid then
        local q = e.position
        local key = (math.floor(q.x / 32) + 65536) * 131072 + math.floor(q.y / 32) + 65536
        local v = vis[key]
        if v == nil then v = visible(action, spider.surface, q); vis[key] = v end
        if v then
          seen = seen + 1
          local d = dist(pos, q)
          if STRUCTURES[e.type] then
            if d < ds then ds, st = d, e end
          else
            if d < du then du, unit = d, e end
            if d <= action.band_max then n, cx, cy = n + 1, cx + q.x, cy + q.y end
          end
        end
      end
    end
    action.seen, action.du, action.ds, action.group = seen, unit and du or nil, st and ds or nil, n
    action.unit_name, action.structure_name = unit and unit.name or nil, st and st.name or nil
    return unit, du, st, ds, n > 0 and {x=cx / n, y=cy / n} or nil
  end
  local function stop_line(action, what, now, floor)
    action.why = string.format('%s %d%% fell below %s %d%%', what, pct(now), what == 'health' and 'min_health' or 'min_shield', pct(floor))
  end
  -- Every SCAN ticks (the runtime calls it when tick >= next_scan): the outcome, or nil to go on.
  function M.tick(action, tick)
    action.next_scan = tick + M.SCAN
    local spider = action.spider
    if not (spider and spider.valid) then action.why = 'the spidertron is gone (destroyed or mined)'; return 'destroyed' end
    local pos = spider.position
    if action.how == 'remote' and not visible(action, spider.surface, pos) then
      action.why = string.format('%s at %s left the chunks our force sees (radar coverage or a character\'s sight): remote view lost it', spider.name, at(pos))
      return 'out_of_coverage'
    end
    -- (d28 batch310 item 5) another call cleared, replaced (the same target too) or appended to its route: yield first, so
    -- neither a route nor a low-health retreat of this kite is written over the new one
    local took = taken(action)
    if took then action.why, action.dest, action.yielded = took, nil, true; return 'route_changed' end
    local h, s = fractions(spider)
    if h < action.min_health then stop_line(action, 'health', h, action.min_health); return 'low_health' end
    if action.min_shield and s and s < action.min_shield then stop_line(action, 'shield', s, action.min_shield); return 'low_shield' end
    local left = ammo(spider)
    if left < action.ammo_below then action.why = string.format('%d rockets left in its ammo slots, under ammo_below %d', left, action.ammo_below); return 'out_of_ammo' end
    -- its route as we left it: arrived (empty), or set by someone else
    local q = first(spider)
    if action.dest then
      -- (d28 batch310 item 5) empty: arrived only within 4 tiles of its target; else emptied by a player or a script
      if not q and dist(pos, action.dest) > 4 then
        action.why = string.format('its route was emptied by another call or a player %.0f tiles short of %s: it yields', dist(pos, action.dest), at(action.dest))
        action.dest, action.yielded = nil, true
        return 'route_changed'
      elseif not q then action.dest = nil
      elseif not on_route(action, q) then
        action.why = string.format('its route was changed by another call or a player: it leads to %s, not %s', at(q), at(action.dest))
        action.dest = nil
        return 'route_changed'
      end
    elseif q then
      action.why = string.format('its route was set by another call or a player: it leads to %s', at(q))
      return 'route_changed'
    end
    local unit, du, st, ds, centre = scan(spider, action)
    local goal
    if unit and du < action.band_min then
      local from = centre or unit.position
      local dx, dy = pos.x - from.x, pos.y - from.y
      local d = math.sqrt(dx * dx + dy * dy)
      if d < 0.5 then dx, dy, d = pos.x - unit.position.x, pos.y - unit.position.y, du end
      if d < 0.01 then dx, dy, d = 0, 1, 1 end
      local step = math.max(6, action.band_max - du)
      goal, action.mode = {x=pos.x + dx / d * step, y=pos.y + dy / d * step}, 'backing off'
    elseif unit and du <= action.band_max then
      action.mode = 'holding'
    elseif st and ds > action.range and not (unit and du < action.band_max + 8) then
      local sp = st.position
      local k = (action.range - 2) / ds
      goal, action.mode = {x=sp.x + (pos.x - sp.x) * k, y=sp.y + (pos.y - sp.y) * k}, 'approaching'
    elseif unit or st then
      action.mode = 'holding'
    elseif action.anchor and dist(pos, action.anchor) > 4 then
      goal, action.mode = action.anchor, 'to position'
    else
      action.why = string.format('no enemies left within %d tiles in chunks our force sees', action.radius)
      halt(spider, action)
      return 'clear'
    end
    if not goal then halt(spider, action); action.turns, action.turn_until, action.ref, action.from = 0, nil, nil, nil; return nil end
    -- a turned route is kept for STALL ticks, or until it makes progress
    -- (a back-off target is turned onto ground its legs stand on; position and a nest's approach are kept as given)
    if not (action.turn_until and tick < action.turn_until) then
      local new = go(spider, action, action.mode == 'backing off' and footing(spider, action, pos, goal) or goal, tick)
      if new and action.mode ~= 'backing off' then round_water(spider, action) end
    end
    -- (d26 batch247 NV2) its trail: the last 6 spots it stood with room for a path's box (where a back-off goes)
    do
      local P = api.path
      local okc, room = pcall(function() return P and P.clear and P.clear(spider.surface, pos) end)
      local q0 = {x=math.floor(pos.x) + 0.5, y=math.floor(pos.y) + 0.5}
      action.trail = action.trail or {}
      local lt = action.trail[#action.trail]
      if okc and room and not (lt and lt.x == q0.x and lt.y == q0.y) then
        action.trail[#action.trail + 1] = q0
        if #action.trail > 6 then table.remove(action.trail, 1) end
      end
    end
    -- Progress: MOVED tiles nearer its target than it has been (a turned route counts toward the target it was turned
    -- from), or, its target moved over 3 tiles (a new nearest, not a new clock), FAR tiles from where it last made
    -- progress. A body swaying on the spot never comes nearer than its nearest, so it stalls.
    local turned = action.turn_until and tick < action.turn_until
    -- (a route round water: toward its next point, as a detour first leads away from the target)
    local nxt = action.route_pts and first(spider)
    local ref = nxt or (turned and action.base) or action.dest
    local near = dist(pos, ref)
    local moved = action.from and dist(pos, action.from) >= M.FAR
    if not action.from then action.from = {x=pos.x, y=pos.y} end
    local fresh = not action.ref or dist(action.ref, ref) > 3
    if fresh then action.ref, action.best = {x=ref.x, y=ref.y}, near end
    if (not fresh and near <= action.best - M.MOVED) or (fresh and moved) then
      action.best, action.since, action.check, action.from = near, tick, tick, {x=pos.x, y=pos.y}
      action.turns, action.turn_until = 0, nil
    elseif tick - action.check >= M.STALL then
      -- (d26 batch247 NV2) no progress with water ahead: as go_to's (spiderroute.lua), it backs off to the newest spot of
      -- its trail 3 tiles or more back (else straight back from its target) and asks again for a path from there, any
      -- water on the line counting (gap 0; island hops come with spiderpath's plan), up to RECOVER times, then stalled.
      -- No water ahead: its route turned 60 degrees once (batch191), then stalled.
      action.turns = action.turns + 1
      local P = api.path
      if action.turns == 1 then action.base = action.dest end
      local okw, wa = pcall(function() return P and P.water_ahead(spider.surface, pos, action.base) end)
      local give_up = false
      if okw and wa and P.back then
        action.recs = (action.recs or 0) + 1
        if action.recs <= M.RECOVER then
          local back
          for i = #(action.trail or {}), 1, -1 do
            if dist(action.trail[i], pos) >= 3 then back = action.trail[i]; break end
          end
          if not back then
            local okb, b = pcall(P.back, spider.surface, pos, action.base)
            back = okb and b or nil
          end
          if back then
            go(spider, action, back, tick, true)
            local okp, lines = pcall(P.plan, spider, {action.base}, {owner='kite', index=action.index, from=back, gap=0})
            local did = string.format('backed off to %s and %s (recovery %d of %d)', at(back),
              okp and lines and 'asked again for a path round the water to ' .. at(action.base) .. ' from there' or 'went on from there', action.recs, M.RECOVER)
            action.tried = action.tried and action.tried .. '; ' .. did or did
          else give_up = true end
        else give_up = true end
      elseif not action.turned60 then
        action.turned60 = true
        go(spider, action, footing(spider, action, pos, turn(pos, action.base, 60)), tick, true)
        action.tried = 're-routed once (its route turned 60 degrees)'
      else give_up = true end
      if give_up then
        action.why = string.format('no progress toward %s for %d s from %s; %s%s', at(ref), math.floor((tick - action.since) / 60), at(pos), action.tried or 'nothing tried',
          action.no_path and '; ' .. action.no_path or '')
        action.stalled_at = {x=pos.x, y=pos.y}
        halt(spider, action)
        return 'stalled'
      end
      action.turned = action.turned + 1
      action.check, action.turn_until = tick, tick + M.STALL
    end
    return nil
  end
  -- What it is doing now, for status (formatted only when read).
  function M.line(action)
    local spider = action.spider
    if not (spider and spider.valid) then return nil end
    local h, s = fractions(spider)
    local parts = {string.format('%s #%d at %s (%s): %s', spider.name, action.unit, at(spider.position), action.how == 'remote' and 'remote view' or 'riding', action.mode or 'starting')}
    if action.du then parts[#parts + 1] = string.format('nearest %s %.0f tiles', action.unit_name, action.du) end
    if action.ds then parts[#parts + 1] = string.format('nearest %s %.0f tiles', action.structure_name, action.ds) end
    parts[#parts + 1] = string.format('%d enemies seen, health %d%%%s, %d rockets, %d kills', action.seen or 0, pct(h), s and string.format(', shield %d%%', pct(s)) or '', ammo(spider), action.kills)
    return table.concat(parts, '; ')
  end
  -- A death: counted when the spidertron or the character in it caused it.
  function M.died(action, cause, entity)
    local spider = action.spider
    if not (spider and spider.valid and entity and entity.valid) then return end
    if cause ~= spider and not (cause.type == 'character' and try(function() return cause.vehicle end) == spider) then return end
    if entity.force == spider.force or entity.force.name == 'neutral' then return end
    action.kills = action.kills + 1
    action.kills_by[entity.name] = (action.kills_by[entity.name] or 0) + 1
  end
  -- The end, into last: kills, ammo, why; its route cleared (or, low and with a retreat point, a route there) and its
  -- switches back as they were (left on while it walks back). spider_set: the remote's go_to (spiderroute.lua).
  function M.finish(action, outcome, last, spider_set, by)
    last.why = action.why or (outcome == 'timed_out' and 'time up' or outcome == 'replaced' and 'replaced by another action' or nil)
    last.kills = action.kills
    if next(action.kills_by) then last.kills_by = action.kills_by end
    last.enemies_left = action.seen
    last.turns = action.turned > 0 and action.turned or nil
    last.recovery, last.water, last.routed, last.no_path = action.tried, action.water, action.routed, action.no_path
    last.route_writes = action.writes
    local spider = action.spider
    if not (spider and spider.valid) then last.ammo_left = 0; return end
    local left = ammo(spider)
    last.ammo_used, last.ammo_left = math.max(0, action.ammo_start - left), left
    local h, s = fractions(spider)
    last.spidertron = string.format('%s #%d at %s, health %d%%%s', spider.name, action.unit, at(spider.position), pct(h), s and string.format(', shield %d%%', pct(s)) or '')
    last.position = spider.position
    local low = outcome == 'low_health' or outcome == 'low_shield' or outcome == 'out_of_ammo'
    if low and action.back then
      local ok, out = pcall(spider_set, spider, {go_to=action.back}, by)
      if ok then
        last.retreat = string.format('its route became %s (%s); its guns stay on%s', out.route_line, action.back_standing and 'your standing retreat_guard\'s to' or 'retreat',
          out.water and '; ' .. out.water.crossing[1] .. ': a path round the water was requested (the route change is said once in team alerts)' or '')
        return
      end
      last.retreat = 'the route to ' .. at(action.back) .. ' was refused: ' .. tostring(out)
    end
    pcall(halt, spider, action)
    if action.switches then
      -- (d28 batch310 item 5) back as they were only when they still read as this kite set them (both on) and no other
      -- call took the spidertron over; else left as they stand
      local now = try(function() return spider.vehicle_automatic_targeting_parameters end) or {}
      if action.yielded or not (now.auto_target_with_gunner and now.auto_target_without_gunner) then
        last.targeting = string.format('switches left as they stand (%s): auto target with gunner %s, without gunner %s', action.yielded and 'another call took the spidertron over' or 'set since this spider_kite began',
          tostring(now.auto_target_with_gunner), tostring(now.auto_target_without_gunner))
      else
        pcall(function() spider.vehicle_automatic_targeting_parameters = action.switches end)
        local w = action.switches
        last.targeting = string.format('switches back as they were: auto target with gunner %s, without gunner %s', tostring(w.auto_target_with_gunner), tostring(w.auto_target_without_gunner))
      end
    end
  end
  return M
end
