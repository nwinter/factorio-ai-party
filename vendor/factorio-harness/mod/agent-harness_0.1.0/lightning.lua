-- Lightning on Fulgora (Gemini, shift09 00:20: "an alert for unconnected
-- lightning attractors on Fulgora"). A lightning rod or collector charges its
-- own buffer from a strike and feeds that into its electric network; what the
-- network cannot take stays in the buffer. Three push alert kinds, in the
-- pushalerts.lua digest and the game_alerts read:
-- - lightning_unconnected: attractors no pole reaches (no electric network);
-- - lightning_unused: attractors in a network with no accumulator and nothing
--   drawing power in the last minute (the network's own statistics);
-- - lightning_storage_full: a network with attractors whose accumulators are
--   at 99% or more of their capacity.
-- Ruin attractors (no energy source) are left out. Read with the push alert
-- scan (every 30 s at most): the attractors and accumulators on the lightning
-- planets, and one pole's network statistics per attractor network.
-- The factory is pure so the same module can be bundled into a hot reload.
return function(api)
  local M = {}
  local PLANETS = {fulgora=true}   -- the API has no lightning property; Space Age's lightning is Fulgora's
  local CELL, FULL, POLE_REACH, MAX = 64, 0.99, 10, 4000
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function at(x, y) return string.format('(%d,%d)', math.floor(x + 0.5), math.floor(y + 0.5)) end
  local function mj(j) return string.format('%g MJ', math.floor(j / 1e5 + 0.5) / 10) end
  local function group(key, kind, surface)
    return {key=key, kind=kind, surface=surface, n=0, names={}, by={}, at={}, sx=0, sy=0}
  end
  local function add(g, e)
    g.n = g.n + 1
    g.names[e.name] = (g.names[e.name] or 0) + 1
    g.sx, g.sy = g.sx + e.position.x, g.sy + e.position.y
    if #g.at < 4 then g.at[#g.at+1] = {x=e.position.x, y=e.position.y} end
    local u = try(function() return e.last_user and e.last_user.name end)
    if u then g.by[u] = (g.by[u] or 0) + 1 end
  end
  local function finish(g)
    g.center = {x=math.floor(g.sx / g.n + 0.5), y=math.floor(g.sy / g.n + 0.5)}
    g.sx, g.sy = nil, nil
    return g
  end
  local function what(g)
    local list = {}
    for name, n in pairs(g.names) do list[#list+1] = n .. ' ' .. name end
    table.sort(list)
    return table.concat(list, ', ')
  end
  -- Names drawing power from a network in the last minute, accumulators aside.
  local function drawing(pole)
    local stats = try(function() return pole.electric_network_statistics end)
    if not stats then return nil end
    local out = {}
    for name in pairs(try(function() return stats.input_counts end) or {}) do
      local proto = prototypes.entity[name]
      if not (proto and proto.type == 'accumulator') then
        local v = try(function() return stats.get_flow_count{name=name, category='input', precision_index=defines.flow_precision_index.one_minute} end)
        if v and v > 0 then out[#out+1] = name end
      end
    end
    return out
  end
  local function pole_of(e, id)
    local poles = try(function() return e.surface.find_entities_filtered{position=e.position, radius=POLE_REACH, type='electric-pole', force=e.force, limit=16} end) or {}
    for _, p in ipairs(poles) do if p.valid and try(function() return p.electric_network_id end) == id then return p end end
  end
  -- Push alert groups for one force (pushalerts.lua adds them to its scan).
  function M.alert_groups(force)
    local out = {}
    for _, s in pairs(game.surfaces) do
      local planet = try(function() return s.planet and s.planet.name end)
      if planet and PLANETS[planet] then
        local list = try(function() return s.find_entities_filtered{type={'lightning-attractor', 'accumulator'}, force=force, limit=MAX} end) or {}
        local loose, nets = {}, {}
        local function net(id)
          nets[id] = nets[id] or {id=id, attractors={}, acc=0, j=0, buf=0, stored=0, cap=0}
          return nets[id]
        end
        for _, e in ipairs(list) do
          if e.valid then
            local id = try(function() return e.electric_network_id end)
            if e.type == 'accumulator' then
              if id then
                local n = net(id)
                n.acc, n.j, n.buf = n.acc + 1, n.j + (try(function() return e.energy end) or 0), n.buf + (try(function() return e.electric_buffer_size end) or 0)
              end
            elseif (try(function() return e.electric_buffer_size end) or 0) > 0 then
              if id then
                local n = net(id)
                n.attractors[#n.attractors+1] = e
                n.stored, n.cap = n.stored + (try(function() return e.energy end) or 0), n.cap + e.electric_buffer_size
              else
                local cx, cy = math.floor(e.position.x / CELL), math.floor(e.position.y / CELL)
                local key = 'lightning_unconnected|' .. s.name .. '|' .. cx .. ',' .. cy
                loose[key] = loose[key] or group(key, 'lightning_unconnected', s.name)
                add(loose[key], e)
              end
            end
          end
        end
        local keys = {}
        for key in pairs(loose) do keys[#keys+1] = key end
        table.sort(keys)
        for _, key in ipairs(keys) do
          local g = finish(loose[key])
          g.line = string.format('%s in no electric network (no pole reaches %s) near %s: a strike charges only %s own buffer',
            what(g), g.n == 1 and 'it' or 'them', at(g.center.x, g.center.y), g.n == 1 and 'its' or 'their')
          out[#out+1] = g
        end
        local ids = {}
        for id, n in pairs(nets) do if #n.attractors > 0 then ids[#ids+1] = id end end
        table.sort(ids)
        for _, id in ipairs(ids) do
          local n = nets[id]
          local buffers = string.format('their buffers hold %s of %s', mj(n.stored), mj(n.cap))
          if n.acc == 0 then
            local pole = pole_of(n.attractors[1], id)
            local users = pole and drawing(pole)
            if users and #users == 0 then
              local g = group('lightning_unused|' .. s.name .. '|' .. id, 'lightning_unused', s.name)
              for _, e in ipairs(n.attractors) do add(g, e) end
              finish(g)
              g.line = string.format('electric #%d: %s near %s in a network with no accumulator and nothing drawing power in the last minute; %s',
                id, what(g), at(g.center.x, g.center.y), buffers)
              out[#out+1] = g
            end
          elseif n.buf > 0 and n.j >= FULL * n.buf then
            local g = group('lightning_storage_full|' .. s.name .. '|' .. id, 'lightning_storage_full', s.name)
            for _, e in ipairs(n.attractors) do add(g, e) end
            local attractors = what(g)
            finish(g)
            g.names = {accumulator=n.acc}
            g.n = n.acc
            g.line = string.format('electric #%d: its %d accumulators are full (%s of %s) with %s in the network near %s; %s',
              id, n.acc, mj(n.j), mj(n.buf), attractors, at(g.center.x, g.center.y), buffers)
            out[#out+1] = g
          end
        end
      end
    end
    return out
  end

  -- Fulgora's sky (Gemini 12:20: the lightning storm's state and the time to the next storm). The API has no storm
  -- or lightning property (LuaSurface, LuaPlanet and LuaSpaceLocationPrototype on world n, 2.0.77, 2026-10-14).
  -- Lightning strikes in the dark: one Fulgora day of samples on world n (256x256 tiles, every 4 s) saw bolts at
  -- darkness 0.06 to 0.85, in all but one sample at 0.48 and over, and none in daylight (darkness 0). So the sky is
  -- the surface's day cycle: day (no darkness) from dawn to dusk, then darkening to full dark (evening to morning)
  -- and brightening to dawn. {state (storm while dark, else clear), phase, darkness, dusk_in_s, evening_in_s,
  -- morning_in_s, dawn_in_s, day_s, bolts_near (lightning within 64 tiles of pos, when pos is given), line}.
  local NEAR = 64
  local function span(s)
    s = math.floor(s + 0.5)
    return s >= 60 and string.format('%dm%02ds', math.floor(s / 60), s % 60) or s .. 's'
  end
  function M.sky(surface, pos)
    local planet = try(function() return surface.planet and surface.planet.name end)
    if not (planet and PLANETS[planet]) then return nil end
    local d, dark, ticks = surface.daytime, surface.darkness or 0, surface.ticks_per_day
    local dusk, evening, morning, dawn = surface.dusk, surface.evening, surface.morning, surface.dawn
    local out = {state=dark > 0 and 'storm' or 'clear', darkness=math.floor(dark * 100 + 0.5) / 100, day_s=math.floor(ticks / 60 + 0.5)}
    if d >= dusk and d < evening then out.phase = 'darkening'
    elseif d >= evening and d < morning then out.phase = 'full dark'
    elseif d >= morning and d < dawn then out.phase = 'brightening'
    else out.phase = 'day' end
    if pos then
      out.bolts_near = try(function() return surface.count_entities_filtered{position=pos, radius=NEAR, type='lightning'} end)
    end
    local parts = {}
    local near = out.bolts_near and string.format('; %d lightning bolts within %d tiles of you now', out.bolts_near, NEAR) or ''
    if surface.freeze_daytime then
      parts[1] = string.format('%s sky: %s, darkness %.2f, daytime frozen%s', planet, out.phase, out.darkness, near)
    else
      local function left(t) return ((t - d) % 1) * ticks / 60 end
      out.dusk_in_s, out.evening_in_s = math.floor(left(dusk) + 0.5), math.floor(left(evening) + 0.5)
      out.morning_in_s, out.dawn_in_s = math.floor(left(morning) + 0.5), math.floor(left(dawn) + 0.5)
      if out.phase == 'day' then
        parts[1] = string.format('%s sky: day, clear (no lightning in daylight); dusk in %s, full dark in %s', planet, span(left(dusk)), span(left(evening)))
      elseif out.phase == 'darkening' then
        parts[1] = string.format('%s sky: storm, darkening (darkness %.2f; lightning in the dark, most at full dark); full dark in %s, dawn (clear) in %s',
          planet, out.darkness, span(left(evening)), span(left(dawn)))
      elseif out.phase == 'full dark' then
        parts[1] = string.format('%s sky: storm, full dark (darkness %.2f; lightning); brightening in %s, dawn (clear) in %s',
          planet, out.darkness, span(left(morning)), span(left(dawn)))
      else
        parts[1] = string.format('%s sky: storm, brightening (darkness %.2f; lightning in the dark); dawn (clear) in %s, next dusk in %s',
          planet, out.darkness, span(left(dawn)), span(left(dusk)))
      end
      parts[1] = parts[1] .. near .. string.format('; a %s day: dark from dusk to dawn, %s', span(ticks / 60), span(((dawn - dusk) % 1) * ticks / 60))
    end
    out.line = parts[1]
    return out
  end

  -- Protection (d17 territory part 4, operator 17:35). How a strike picks its target, measured on the copy of world n
  -- (2.0.77, 2026-10-17, LuaSurface.execute_lightning on empty ground on Fulgora): a strike at a point goes to a
  -- lightning attractor whose reach holds the point, reach = the planet's search_radius (Fulgora 10) + the attractor's
  -- range_elongation (lightning-rod 15, lightning-collector 25, fulgoran-ruin-attractor 20) x (1 + 0.3 x quality level),
  -- from its position, connected or not (normal rod 25.0 hit, 25.5 missed; collector 34.8 hit, 35.0 missed; uncommon
  -- rod 29.4/29.6; legendary rod 47.4/47.6; legendary collector 72.4/72.6). With none in reach it hits an entity whose
  -- center is within 10 tiles of the point (10.0 hit, 10.5 missed) for 100 electric damage, else the ground; the
  -- planet's exemption_rules types are never hit (a stone wall took none). The runtime has no range_elongation or
  -- search_radius, so they are the 2.0.77 prototypes' (space-age planet.lua, entities.lua, decoratives-fulgora.lua).
  -- A building is exposed when a strike point within 10 tiles of its center lies outside every attractor's reach,
  -- read at 25 points (the center, 8 at 5 tiles, 16 at 10). A lightning death reaches on_entity_died with no cause,
  -- the neutral force and electric damage (seen on the copy).
  local SEARCH = 10
  local ELONGATION = {['lightning-rod']=15, ['lightning-collector']=25, ['fulgoran-ruin-attractor']=20}
  local NEVER = {['rail-support']=true, ['legacy-straight-rail']=true, ['legacy-curved-rail']=true, ['straight-rail']=true,
    ['curved-rail-a']=true, ['curved-rail-b']=true, ['half-diagonal-rail']=true, ['rail-ramp']=true, ['elevated-straight-rail']=true,
    ['elevated-curved-rail-a']=true, ['elevated-curved-rail-b']=true, ['elevated-half-diagonal-rail']=true, ['rail-signal']=true,
    ['rail-chain-signal']=true, locomotive=true, ['artillery-wagon']=true, ['cargo-wagon']=true, ['fluid-wagon']=true,
    ['land-mine']=true, wall=true, tree=true, ['cargo-pod']=true,
    -- not buildings, or attractors themselves
    ['entity-ghost']=true, ['tile-ghost']=true, ['item-request-proxy']=true, ['logistic-robot']=true, ['construction-robot']=true,
    character=true, ['temporary-container']=true, ['rocket-silo-rocket']=true, car=true, ['spider-vehicle']=true,
    ['lightning-attractor']=true}
  local STRIKE_CELL, LOST_KEEP, HOUR = 32, 64, 216000
  -- Cell keys are numbers: a number made a string cost about 16 us on the copy (1962 index keys 32 ms).
  local function cell(cx, cy) return cx * 1048576 + cy end
  local POINTS = {{0, 0}}
  for i = 0, 7 do POINTS[#POINTS+1] = {5 * math.cos(i * math.pi / 4), 5 * math.sin(i * math.pi / 4)} end
  for i = 0, 15 do POINTS[#POINTS+1] = {10 * math.cos(i * math.pi / 8), 10 * math.sin(i * math.pi / 8)} end
  function M.planet(surface)
    local planet = try(function() return surface.planet and surface.planet.name end)
    return planet ~= nil and PLANETS[planet] == true
  end
  function M.reach(name, level) return SEARCH + (ELONGATION[name] or 0) * (1 + 0.3 * (level or 0)) end
  -- A cursor for the background read on a lightning planet, else nil; M.exposure_step does max buildings a step
  -- (the attractors' index and the find each a step of their own) and returns true when done.
  function M.exposure_cursor(surface, force)
    if not M.planet(surface) then return nil end
    return {surface=surface.name, force=force.name}
  end
  -- (d22 batch110 BT1: a step of the background read made 152 KB on the copy; each building's position was read twice,
  -- a new table each read, and a building in no attractor's cell made an empty table)
  local NO_ATTRACTORS = {}
  function M.exposure_step(cur, max)
    local s = game.get_surface(cur.surface)
    if not s then return true end
    if not cur.idx then
      local idx, n = {}, 0
      for _, a in ipairs(s.find_entities_filtered{type='lightning-attractor'}) do
        local r = M.reach(a.name, try(function() return a.quality.level end))
        local q = {x=a.position.x, y=a.position.y, r=r}
        local m = r + SEARCH
        n = n + 1
        for cx = math.floor((q.x - m) / STRIKE_CELL), math.floor((q.x + m) / STRIKE_CELL) do
          for cy = math.floor((q.y - m) / STRIKE_CELL), math.floor((q.y + m) / STRIKE_CELL) do
            local k = cell(cx, cy)
            local l = idx[k]; if not l then l = {}; idx[k] = l end
            l[#l+1] = q
          end
        end
      end
      cur.idx, cur.attractors = idx, n
      return false
    end
    if not cur.list then cur.list, cur.at, cur.cells, cur.checked = s.find_entities_filtered{force=cur.force}, 1, {}, 0; return false end
    local last = math.min(#cur.list, cur.at + max - 1)
    for i = cur.at, last do
      local e = cur.list[i]
      if e.valid and not NEVER[e.type] then
        cur.checked = cur.checked + 1
        local p = e.position
        local x, y = p.x, p.y
        local c = cur.idx[cell(math.floor(x / STRIKE_CELL), math.floor(y / STRIKE_CELL))] or NO_ATTRACTORS
        local safe = false
        for _, a in ipairs(c) do
          local dx, dy, d = x - a.x, y - a.y, a.r - SEARCH
          if dx * dx + dy * dy <= d * d then safe = true; break end
        end
        local open
        if not safe then
          for j, p in ipairs(POINTS) do
            local px, py, cov = x + p[1], y + p[2], false
            for _, a in ipairs(c) do
              local dx, dy = px - a.x, py - a.y
              if dx * dx + dy * dy <= a.r * a.r then cov = true; break end
            end
            if not cov then open = j == 1 and 'center' or 'edge'; break end
          end
        end
        if open then
          local key = cell(math.floor(x / 64), math.floor(y / 64))
          local g = cur.cells[key]
          if not g then g = {n=0, center=0, sx=0, sy=0, names={}}; cur.cells[key] = g end
          g.n, g.sx, g.sy = g.n + 1, g.sx + x, g.sy + y
          if open == 'center' then g.center = g.center + 1 end
          g.names[e.name] = (g.names[e.name] or 0) + 1
        end
      end
    end
    cur.at = last + 1
    if cur.at <= #cur.list then return false end
    cur.result = {attractors=cur.attractors, checked=cur.checked, cells=cur.cells}
    cur.list, cur.idx = nil, nil
    return true
  end
  -- 'lightning' when on_entity_died's event is a strike's (a lightning planet, no cause, the neutral force, electric).
  function M.struck(event)
    local e = event.entity
    if event.cause or not (event.force and event.force.name == 'neutral') then return nil end
    if not (event.damage_type and event.damage_type.name == 'electric') then return nil end
    if not (e and e.valid and M.planet(e.surface)) then return nil end
    return 'lightning'
  end
  -- A building of ours lightning killed (the losses log keeps it with cause lightning): the last LOST_KEEP a force.
  function M.lost(e)
    local st = api.state()
    st.lightning_lost = st.lightning_lost or {}
    local list = st.lightning_lost[e.force.name] or {}
    st.lightning_lost[e.force.name] = list
    list[#list+1] = {s=e.surface.name, n=e.name, x=e.position.x, y=e.position.y, t=game.tick}
    while #list > LOST_KEEP do table.remove(list, 1) end
  end
  local function ago(t)
    local m = math.floor((game.tick - t) / 3600)
    return m >= 60 and string.format('%dh%02dm ago', math.floor(m / 60), m % 60) or m .. 'm ago'
  end
  local function top(names, k)
    local list = {}
    for name, n in pairs(names) do list[#list+1] = {name=name, n=n} end
    table.sort(list, function(a, b) if a.n ~= b.n then return a.n > b.n end return a.name < b.name end)
    local out = {}
    for i = 1, math.min(k, #list) do out[i] = list[i].n .. ' ' .. list[i].name end
    return table.concat(out, ', ') .. (#list > k and ', ...' or '')
  end
  -- Status and team lines: per lightning planet, our buildings exposed by 64-tile area (the most first, up to areas),
  -- then our buildings lightning killed (in the last hour, and the last one).
  function M.exposure_lines(strike, force, areas)
    local lines, names = {}, {}
    for name in pairs(strike or {}) do names[#names+1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
      local r = strike[name]
      local cells, total, center = {}, 0, 0
      for _, g in pairs(r.cells or {}) do cells[#cells+1] = g; total, center = total + g.n, center + g.center end
      if #cells > 0 then
        table.sort(cells, function(a, b) if a.n ~= b.n then return a.n > b.n end return a.sx < b.sx end)
        local parts = {}
        for i = 1, math.min(areas, #cells) do
          local g = cells[i]
          parts[i] = string.format('%s near (%d,%d)', top(g.names, 3), math.floor(g.sx / g.n), math.floor(g.sy / g.n))
        end
        lines[#lines+1] = string.format('outside every lightning attractor\'s protection on %s (a point within %d tiles of each lies outside every attractor\'s reach, and a strike there hits what stands within %d tiles; %d attractors): %d of %d buildings of ours%s in %d area%s (64 tiles): %s%s',
          name, SEARCH, SEARCH, r.attractors or 0, total, r.checked or 0, center > 0 and string.format(' (%d with the center itself outside every reach)', center) or '',
          #cells, #cells == 1 and '' or 's', table.concat(parts, '; '), #cells > areas and string.format('; +%d more areas', #cells - areas) or '')
      end
    end
    local lost = (api.state().lightning_lost or {})[force.name] or {}
    local by = {}
    for _, row in ipairs(lost) do
      local b = by[row.s] or {n=0, hour=0, names={}}; by[row.s] = b
      b.n = b.n + 1; b.last = row; b.first = b.first or row
      if game.tick - row.t <= HOUR then b.hour = b.hour + 1; b.names[row.n] = (b.names[row.n] or 0) + 1 end
    end
    local surfaces = {}
    for name in pairs(by) do surfaces[#surfaces+1] = name end
    table.sort(surfaces)
    for _, name in ipairs(surfaces) do
      local b = by[name]
      lines[#lines+1] = string.format('lost to lightning on %s: %d in the last hour%s; the last %s (%g,%g) %s%s',
        name, b.hour, b.hour > 0 and ' (' .. top(b.names, 4) .. ')' or '', b.last.n, b.last.x, b.last.y, ago(b.last.t),
        b.n > 1 and string.format(' (%d kept, the oldest %s)', b.n, ago(b.first.t)) or '')
    end
    return lines
  end
  return M
end
