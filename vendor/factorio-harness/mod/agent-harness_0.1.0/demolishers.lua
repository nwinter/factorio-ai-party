-- demolishers {surface?, near?} (backlog #283, Sol: scan and nearest found no head after a fight; whether the tungsten
-- site was clear or the head patrolled under fog could not be told). Read only, as the map shows: each demolisher
-- territory with a charted chunk (its border on the map), the nearest of its charted chunks to you (or near), and each
-- demolisher in it our force sees now: its name and health, where its head is and its whole body (C5); one out of sight is not named nor
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
  -- A demolisher's whole body as a player sees it (d17 batch18 C5, viewer Foobator 13:38: the read gave the head only):
  -- every segment in a chunk our force sees now; the line through them simplified (points no more than SIMPLIFY tiles
  -- off it, at most MAX_POINTS), its length, the tiles under the segments' boxes (their box), and which way the head
  -- moves and how fast.
  local SIMPLIFY, MAX_POINTS = 1.5, 16
  local COMPASS = {'north', 'northeast', 'east', 'southeast', 'south', 'southwest', 'west', 'northwest'}
  local function simplify(pts, lo, hi, keep)
    if hi <= lo + 1 then return end
    local a, b = pts[lo], pts[hi]
    local dx, dy = b.x - a.x, b.y - a.y
    local len2 = dx * dx + dy * dy
    local far, fi = 0, nil
    for i = lo + 1, hi - 1 do
      local q = pts[i]
      local t = len2 > 0 and math.max(0, math.min(1, ((q.x - a.x) * dx + (q.y - a.y) * dy) / len2)) or 0
      local d = math.sqrt((q.x - a.x - t * dx) ^ 2 + (q.y - a.y - t * dy) ^ 2)
      if d > far then far, fi = d, i end
    end
    if fi and far > SIMPLIFY then keep[fi] = true; simplify(pts, lo, fi, keep); simplify(pts, fi, hi, keep) end
  end
  function M.body(u, surface, f)
    local pts, seen, tiles, box = {}, 0, {}, nil
    local n = 0
    for _, seg in ipairs(try(function() return u.segments end) or {}) do
      local q = try(function() return seg.position end)
      if q then
        n = n + 1
        if f.is_chunk_visible(surface, {x=math.floor(q.x / 32), y=math.floor(q.y / 32)}) then
          seen = seen + 1
          pts[#pts+1] = {x=q.x, y=q.y}
          local cb = try(function() return seg.prototype.collision_box end)
          local r = cb and math.max(-cb.left_top.x, -cb.left_top.y, cb.right_bottom.x, cb.right_bottom.y) or 1
          for x = math.floor(q.x - r), math.floor(q.x + r - 0.001) do
            for y = math.floor(q.y - r), math.floor(q.y + r - 0.001) do tiles[x .. ',' .. y] = true end
          end
          box = box or {x0=q.x, y0=q.y, x1=q.x, y1=q.y}
          box.x0, box.y0, box.x1, box.y1 = math.min(box.x0, q.x - r), math.min(box.y0, q.y - r), math.max(box.x1, q.x + r), math.max(box.y1, q.y + r)
        end
      end
    end
    if seen == 0 then return nil end
    local length = 0
    for i = 2, #pts do length = length + math.sqrt((pts[i].x - pts[i-1].x) ^ 2 + (pts[i].y - pts[i-1].y) ^ 2) end
    local keep = {[1]=true, [#pts]=true}
    simplify(pts, 1, #pts, keep)
    local line = {}
    for i = 1, #pts do if keep[i] and #line < MAX_POINTS then line[#line+1] = {x=math.floor(pts[i].x * 10 + 0.5) / 10, y=math.floor(pts[i].y * 10 + 0.5) / 10} end end
    local ntiles = 0
    for _ in pairs(tiles) do ntiles = ntiles + 1 end
    local head = try(function() return u.segments[1] end)
    local o = head and try(function() return head.orientation end)
    local speed = try(function() return u.speed end) or 0
    return {segments=n, segments_seen=seen, line=line, length=math.floor(length + 0.5), tiles=ntiles,
      box={left_top={x=math.floor(box.x0), y=math.floor(box.y0)}, right_bottom={x=math.ceil(box.x1), y=math.ceil(box.y1)}},
      heading=o and COMPASS[(math.floor(o * 8 + 0.5) % 8) + 1], speed_kmh=math.floor(speed * 60 * 3.6 + 0.5)}
  end
  local function body_text(b)
    local pts = {}
    for i, q in ipairs(b.line) do pts[i] = at(q) end
    return string.format('body %d tiles long over %d tiles (%d of its %d segments in sight), box %s-%s, along %s; head moving %s at %d km/h',
      b.length, b.tiles, b.segments_seen, b.segments, at(b.box.left_top), at(b.box.right_bottom), table.concat(pts, ' '),
      b.heading or '?', b.speed_kmh)
  end
  M.body_text = body_text
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
          local head_seen = q and f.is_chunk_visible(surface, {x=math.floor(q.x / 32), y=math.floor(q.y / 32)})
          -- in sight: any of its segments (a player sees the body without the head)
          local body = try(function() return M.body(u, surface, f) end)
          local visible = q and (head_seen or body ~= nil)
          local where = head_seen and q or (body and body.line[1])
          if visible and id then seen[id] = {x=where.x, y=where.y, tick=game.tick, health=try(function() return u.health end)} end
          local s = id and seen[id]
          -- (only what a player sees: a demolisher out of sight is not named, nor told apart from none; one seen
          -- before is remembered where it was)
          if visible then
            units[#units+1] = {name=name, unit_number=id, visible=true, head=head_seen and {x=q.x, y=q.y} or nil, health=try(function() return u.health end),
              max_health=try(function() return u.max_health end), body=body,
              line=string.format('%s: %s, health %d/%d, seen now%s', name, head_seen and 'head at ' .. at(q) or 'head out of sight', math.floor(try(function() return u.health end) or 0),
                math.floor(try(function() return u.max_health end) or 0), body and '; ' .. body_text(body) or '')}
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
    returns='lines: each demolisher territory the map draws (a charted chunk), nearest first: its charted chunks and the nearest one, and each demolisher in sight in it: name, head position and health while our force sees its chunk now; one seen before and out of sight now: where a read last saw it and how long ago; else no demolisher in sight now (one out of sight is not told apart from none, as on the map); territories with no charted chunk counted. territories [{nearest, distance, charted_chunks, units [{name, visible, head, health, body {segments, segments_seen, line (the body\'s line, simplified: points within 1.5 tiles of it, at most 16), length, tiles (under its segments), box, heading (the head\'s), speed_kmh}}]}]; a demolisher with any segment in sight is in sight (its head may not be). Read only'}}
  return M
end
