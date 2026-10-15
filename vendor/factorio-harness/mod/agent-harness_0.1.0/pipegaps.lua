-- pipe_gaps {from, to, via?}: a pipe line read along tiles, as belt_gaps reads belts (Muse, shift17 10:50: "a fluid-route
-- tracer like belt_gaps/trace-forward for pipes (pipe segment extents + cut points). I spent 15 min locating a cut crude
-- line by chaining supply/inspect segment summaries by hand"). What a player sees on the map and in the pipes' GUI: for
-- each tile of the line, the fluid entity of ours there (pipe, pipe-to-ground, tank, pump, or any with a fluidbox), and
-- whether neighbouring tiles' entities are joined by a pipe connection (the engine's: a connection whose target is the
-- other); a pipe-to-ground pair covers the tiles between its ends. Out of that:
--   segments: runs of joined tiles, each with the fluid segment the engine has there (its fluid and amount, its extent);
--   cuts: two neighbouring entities on the line that do not join, and where the line stops at a tile with nothing;
--   empty: runs of tiles with no fluid entity and no underground pair over them; ghosts on the line; and unknown: tiles
--   in chunks our force does not see now (never read).
-- Read only, bounded: at most 512 tiles, one area query a straight leg, each entity's connections read once, in sight
-- or by remote view; tiles in chunks our force does not see now are not used.
return function(api)
  local M = {}
  local MAX_TILES = 512
  local function try(f) local ok, v = pcall(f); if ok then return v end end
  local function key(x, y) return x .. ',' .. y end
  local function line(a)
    local points = {api.position(a.from)}
    if a.via then
      assert(type(a.via) == 'table' and #a.via <= 16, 'via takes at most 16 positions')
      for _, q in ipairs(a.via) do points[#points+1] = api.position(q) end
    end
    points[#points+1] = api.position(a.to)
    local tiles, seen, boxes = {}, {}, {}
    for i = 2, #points do
      local x, y = math.floor(points[i-1].x), math.floor(points[i-1].y)
      local tx, ty = math.floor(points[i].x), math.floor(points[i].y)
      boxes[#boxes+1] = {{math.min(x, tx) + 0.1, math.min(y, ty) + 0.1}, {math.max(x, tx) + 0.9, math.max(y, ty) + 0.9}}
      assert(x == tx or y == ty, 'each pipe line leg must be horizontal or vertical; via supplies corner positions')
      local dx, dy = tx > x and 1 or tx < x and -1 or 0, ty > y and 1 or ty < y and -1 or 0
      while true do
        local k = key(x, y)
        if not seen[k] then tiles[#tiles+1] = {x=x, y=y}; seen[k] = true; assert(#tiles <= MAX_TILES, 'pipe line exceeds 512 tiles') end
        if x == tx and y == ty then break end
        x, y = x + dx, y + dy
      end
    end
    return tiles, boxes
  end
  local function has_fluidbox(e)
    return (try(function() return #e.fluidbox end) or 0) > 0
  end
  local function at(t) return string.format('(%g,%g)', t.x + 0.5, t.y + 0.5) end
  local function label(e) return string.format('%s (%g,%g)', e.name, e.position.x, e.position.y) end
  -- Each entity's connections, read once a call (on a private 2.0.77 server 512 pipes' connections took about 5 ms, the
  -- one area query a leg 0.2 ms, against 10 ms for a query a tile).
  local conns_of = {}
  local function conns(e)
    local c = conns_of[e]
    if not c then c = try(function() return api.connections(e) end) or {}; conns_of[e] = c end
    return c
  end
  -- Whether a and b are joined: a pipe connection of a whose target is b (the engine's view; a ghost has none).
  local function joined(a, b)
    if a == b then return true end
    for _, c in ipairs(conns(a)) do
      if c.target and c.target == b then return true end
    end
    return false
  end
  local function runs(list)
    local out, cur = {}, nil
    for _, t in ipairs(list) do
      if cur and math.abs(t.x - cur.last.x) + math.abs(t.y - cur.last.y) == 1 then cur.last = t; cur.n = cur.n + 1
      else cur = {first=t, last=t, n=1}; out[#out+1] = cur end
    end
    local rows = {}
    for _, r in ipairs(out) do rows[#rows+1] = {from=at(r.first), to=at(r.last), tiles=r.n} end
    return rows
  end
  function M.read(p, a)
    conns_of = {}
    local tiles, boxes = line(a)
    local f, s = p.force, p.surface
    local ents, ghost, unknown = {}, {}, {}
    local index, seen_tile = {}, {}
    for i, t in ipairs(tiles) do
      index[key(t.x, t.y)] = i
      if api.visible(p, {x=t.x + 0.5, y=t.y + 0.5}) then seen_tile[i] = true else unknown[#unknown+1] = t end
    end
    -- One area query a leg; each entity marks the line's tiles under its box.
    for _, box in ipairs(boxes) do
      for _, e in ipairs(try(function() return s.find_entities_filtered{area=box, force=f, limit=2048} end) or {}) do
        local isghost = e.valid and e.type == 'entity-ghost'
        local fluid = e.valid and (isghost and (try(function() return #e.ghost_prototype.fluidbox_prototypes end) or 0) > 0 or (not isghost and has_fluidbox(e)))
        if fluid then
          local b = e.bounding_box
          for x = math.floor(b.left_top.x + 0.01), math.ceil(b.right_bottom.x - 0.01) - 1 do
            for y = math.floor(b.left_top.y + 0.01), math.ceil(b.right_bottom.y - 0.01) - 1 do
              local i = index[key(x, y)]
              if i and seen_tile[i] then
                if isghost then ghost[i] = ghost[i] or e else ents[i] = ents[i] or e end
              end
            end
          end
        end
      end
    end
    -- Underground pairs on the line: the tiles between a pipe-to-ground and the one its underground connection reaches.
    local covered = {}
    for i, e in pairs(ents) do
      if e.type == 'pipe-to-ground' then
        for _, c in ipairs(conns(e)) do
          if c.kind == 'underground' and c.target and c.target.valid then
            local tx, ty = math.floor(c.target.position.x), math.floor(c.target.position.y)
            local j = index[key(tx, ty)]
            if j then for k = math.min(i, j) + 1, math.max(i, j) - 1 do covered[k] = true end end
          end
        end
      end
    end
    local out = {surface=s.name, tiles=#tiles, segments={}, cuts={}, empty={}, ghosts={}, unknown=runs(unknown), checked_tick=game.tick}
    local empties = {}
    local seg
    local function close() if seg then out.segments[#out.segments+1] = seg; seg = nil end end
    for i, t in ipairs(tiles) do
      local e = ents[i]
      if covered[i] then
        if seg then seg.to = at(t); seg.tiles = seg.tiles + 1; seg.underground = (seg.underground or 0) + 1 end
      elseif e then
        local prev_i = i - 1
        local prev = ents[prev_i]
        local continues = seg and (covered[prev_i] or (prev and joined(prev, e)))
        if seg and not continues and prev then
          out.cuts[#out.cuts+1] = {between={at(tiles[prev_i]), at(t)}, line=string.format('%s and %s do not join', label(prev), label(e))}
        end
        if not continues then
          close()
          local sid = try(function() return e.fluidbox.get_fluid_segment_id(1) end)
          local contents = try(function() return e.fluidbox.get_fluid_segment_contents(1) end)
          local fluid, amount
          for name, n in pairs(contents or {}) do if not amount or n > amount then fluid, amount = name, n end end
          if not fluid then local fb = try(function() return e.fluidbox[1] end); fluid, amount = fb and fb.name, fb and fb.amount end
          local box = api.segment_box and api.segment_box(e, 1)
          seg = {from=at(t), to=at(t), tiles=1, first=label(e), segment_id=sid, fluid=fluid or 'empty',
            amount=amount and math.floor(amount + 0.5) or nil,
            extent=box and string.format('(%d,%d)-(%d,%d)', box[1], box[2], box[3], box[4]) or nil}
        else
          seg.to = at(t); seg.tiles = seg.tiles + 1
        end
        seg.last = label(e)
      else
        if seg then
          local last = ents[i - 1]
          if last then
            out.cuts[#out.cuts+1] = {between={at(tiles[i - 1]), at(t)}, line=ghost[i]
              and string.format('%s: a ghost of %s at %s, not built yet', label(last), ghost[i].ghost_name, at(t))
              or string.format('%s: nothing of ours with a fluidbox at %s', label(last), at(t))}
          end
        end
        close()
        if ghost[i] then out.ghosts[#out.ghosts+1] = {position=at(t), name=ghost[i].ghost_name}
        elseif api.visible(p, {x=t.x + 0.5, y=t.y + 0.5}) then empties[#empties+1] = t end
      end
    end
    close()
    out.empty = runs(empties)
    local parts = {}
    for _, g in ipairs(out.segments) do
      parts[#parts+1] = string.format('%s..%s %s%s', g.from, g.to, g.fluid, g.amount and ' ' .. g.amount or '')
    end
    out.line = string.format('%d tiles: %d segment%s (%s); %d cut%s; %d empty run%s; %d ghost%s; %d unknown run%s',
      #tiles, #out.segments, #out.segments == 1 and '' or 's', table.concat(parts, '; '), #out.cuts, #out.cuts == 1 and '' or 's',
      #out.empty, #out.empty == 1 and '' or 's', #out.ghosts, #out.ghosts == 1 and '' or 's', #out.unknown, #out.unknown == 1 and '' or 's')
    for _, g in ipairs(out.segments) do g.last = g.last ~= g.first and g.last or nil end
    return out
  end
  return M
end
