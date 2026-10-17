-- demolishers {surface?, near?} (backlog #283, Sol: scan and nearest found no head after a fight; whether the tungsten
-- site was clear or the head patrolled under fog could not be told). Read only, as the map shows: each demolisher
-- territory with a charted chunk (its border on the map), the nearest of its charted chunks to you (or near), and each
-- demolisher in it our force sees now: its name and health and where its head is; one out of sight is not named nor
-- told apart from none, save where a read last saw it (remembered, with how long ago). Territories with no charted
-- chunk are only counted.
return function(api)
  local M = {}
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function at(q) return string.format('(%d,%d)', math.floor(q.x + 0.5), math.floor(q.y + 0.5)) end
  local function ago(t) local m = math.floor(t / 3600); return m < 120 and m .. 'm' or math.floor(m / 60) .. 'h' end
  local function memory()
    local s = api.state()
    s.demolisher_seen = s.demolisher_seen or {}
    return s.demolisher_seen
  end
  function M.read(p, a)
    local surface = type(a.surface) == 'string' and game.get_surface(a.surface) or p.surface
    assert(surface, 'no surface ' .. tostring(a.surface))
    local f = p.force
    local here = a.near and api.position(a.near) or (surface == p.surface and p.position) or {x=0, y=0}
    local seen = memory()
    local list = try(function() return surface.get_territories() end) or {}
    local rows, lines, uncharted = {}, {}, 0
    for _, t in ipairs(list) do
      local best, bd, charted = nil, nil, 0
      for _, ch in ipairs(try(function() return t.get_chunks() end) or {}) do
        if f.is_chunk_charted(surface, ch) then
          charted = charted + 1
          local c = {x=ch.x * 32 + 16, y=ch.y * 32 + 16}
          local d = (c.x - here.x) ^ 2 + (c.y - here.y) ^ 2
          if not bd or d < bd then best, bd = c, d end
        end
      end
      if charted == 0 then uncharted = uncharted + 1
      else
        local units = {}
        for _, u in ipairs(try(function() return t.get_segmented_units() end) or {}) do
          local seg = try(function() return u.segments[1] end)
          local q = seg and try(function() return seg.position end)
          local name = try(function() return u.prototype.name end) or 'demolisher'
          local id = try(function() return u.unit_number end)
          local visible = q and f.is_chunk_visible(surface, {x=math.floor(q.x / 32), y=math.floor(q.y / 32)})
          if visible and id then seen[id] = {x=q.x, y=q.y, tick=game.tick, health=try(function() return u.health end)} end
          local s = id and seen[id]
          -- (only what a player sees: a demolisher out of sight is not named, nor told apart from none; one seen
          -- before is remembered where it was)
          if visible then
            units[#units+1] = {name=name, unit_number=id, visible=true, head={x=q.x, y=q.y}, health=try(function() return u.health end),
              max_health=try(function() return u.max_health end),
              line=string.format('%s: head at %s, health %d/%d, seen now', name, at(q), math.floor(try(function() return u.health end) or 0), math.floor(try(function() return u.max_health end) or 0))}
          elseif s then
            units[#units+1] = {name=s.name or name, last_seen={x=s.x, y=s.y, ago_s=math.floor((game.tick - s.tick) / 60)},
              line=string.format('%s last seen at %s %s ago, not in sight now', s.name or name, at(s), ago(game.tick - s.tick))}
          end
          if visible and id then seen[id].name = name end
        end
        local dist = math.floor(math.sqrt(bd) + 0.5)
        local ul = {}
        for _, u in ipairs(units) do ul[#ul+1] = u.line end
        if #ul == 0 then ul[1] = 'no demolisher in sight now' end
        rows[#rows+1] = {nearest=best, distance=dist, charted_chunks=charted, units=units,
          line=string.format('territory with %d charted chunks, nearest at %s (%d tiles): %s', charted, at(best), dist,
            table.concat(ul, '; '))}
      end
    end
    table.sort(rows, function(x, y) return x.distance < y.distance end)
    for i, r in ipairs(rows) do if i <= 12 then lines[#lines+1] = r.line end end
    if #rows > 12 then lines[#lines+1] = string.format('+%d more territories on the map', #rows - 12) end
    if uncharted > 0 then lines[#lines+1] = string.format('%d more territories in chunks not charted (not on the map)', uncharted) end
    if #list == 0 then lines[1] = 'no demolisher territories on ' .. surface.name end
    return {surface=surface.name, lines=lines, territories=rows}
  end
  M.schema = {demolishers = {surface='optional surface name (default yours; Vulcanus has them)', near='optional {x,y}: the distances from there (default you)',
    returns='lines: each demolisher territory the map draws (a charted chunk), nearest first: its charted chunks and the nearest one, and each demolisher in sight in it: name, head position and health while our force sees its chunk now; one seen before and out of sight now: where a read last saw it and how long ago; else no demolisher in sight now (one out of sight is not told apart from none, as on the map); territories with no charted chunk counted. territories [{nearest, distance, charted_chunks, units [{name, visible, head, health}]}]. Read only'}}
  return M
end
