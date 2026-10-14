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
  return M
end
