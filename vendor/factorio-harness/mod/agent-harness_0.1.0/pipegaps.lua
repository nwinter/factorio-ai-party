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
  -- (d25 batch208 QU1) the most a call takes, also a queue step's check (runtime.lua step_lengths)
  M.VIA = 16
  local MAX_TILES = 512
  local function try(f) local ok, v = pcall(f); if ok then return v end end
  local function key(x, y) return x .. ',' .. y end
  local function line(a)
    local points = {api.position(a.from)}
    if a.via then
      assert(type(a.via) == 'table' and #a.via <= M.VIA, 'via takes at most ' .. M.VIA .. ' positions')
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
          -- (d18 batch39 D1) each side's fluid
          local fa, fb2 = api.pipe_fluid and try(function() return api.pipe_fluid(prev) end), api.pipe_fluid and try(function() return api.pipe_fluid(e) end)
          out.cuts[#out.cuts+1] = {between={at(tiles[prev_i]), at(t)}, fluids=fa and {fa, fb2} or nil,
            line=string.format('%s%s and %s%s do not join', label(prev), fa and ' (' .. fa .. ')' or '', label(e), fb2 and ' (' .. fb2 .. ')' or '')}
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
            local fl = api.pipe_fluid and try(function() return api.pipe_fluid(last) end)
            out.cuts[#out.cuts+1] = {between={at(tiles[i - 1]), at(t)}, line=ghost[i]
              and string.format('%s%s: a ghost of %s at %s, not built yet', label(last), fl and ' (' .. fl .. ')' or '', ghost[i].ghost_name, at(t))
              or string.format('%s%s: nothing of ours with a fluidbox at %s', label(last), fl and ' (' .. fl .. ')' or '', at(t))}
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
  -- pipe_gaps {line: {x,y}} (d17 batch21 B1, Sonnet: which segment starved the acid line, ~10 times): the pipe network
  -- through one pipe, pipe-to-ground, tank or pump of ours, followed through its fluid neighbours (pumps too: each starts
  -- a segment) in chunks our force sees now, up to NET_MAX entities. Per fluid segment (the engine's id): its fluid and
  -- amount over its capacity (the game's segment reads), its entities and box, and empty (with the fluid it is locked
  -- to); the machines it touches (not followed into), each box's fluid; flow where the game gives one. Read only.
  local NET_MAX = 1024
  local LINE = {pipe=true, ['pipe-to-ground']=true, ['storage-tank']=true, pump=true, ['infinity-pipe']=true}
  local function at(q) return string.format('(%g,%g)', q.x, q.y) end
  local function r1(v) return math.floor(v * 10 + 0.5) / 10 end
  function M.network(p, start)
    local queue, seen, n = {start}, {}, 0
    local segs, order, machines, mseen, dark = {}, {}, {}, {}, 0
    local function k(e) return e.unit_number or (e.name .. at(e.position)) end
    seen[k(start)] = true
    while #queue > 0 and n < NET_MAX do
      local e = table.remove(queue, 1)
      n = n + 1
      local fb = e.fluidbox
      for i = 1, #fb do
        local id = try(function() return fb.get_fluid_segment_id(i) end) or (k(e) .. '#' .. i)
        local g = segs[id]
        if not g then
          g = {id=id, n=0, x0=e.position.x, y0=e.position.y, x1=e.position.x, y1=e.position.y}
          segs[id] = g; order[#order+1] = g
          local contents = try(function() return fb.get_fluid_segment_contents(i) end)
          if type(contents) == 'table' then
            for name, amount in pairs(contents) do if not g.fluid or amount > g.amount then g.fluid, g.amount = name, amount end end
          end
          if not g.fluid then local f = fb[i]; if f then g.fluid, g.amount = f.name, f.amount end end
          g.capacity = try(function() return fb.get_capacity(i) end)
          g.flow = try(function() return fb.get_flow(i) end)
          if not g.fluid then g.locked = try(function() local lf = fb.get_locked_fluid(i); return type(lf) == 'string' and lf or lf and lf.name end) end
        end
        g.n = g.n + 1
        g.x0, g.y0 = math.min(g.x0, e.position.x), math.min(g.y0, e.position.y)
        g.x1, g.y1 = math.max(g.x1, e.position.x), math.max(g.y1, e.position.y)
      end
      for _, group in ipairs(try(function() return e.neighbours end) or {}) do
        for _, o in ipairs(type(group) == 'table' and group or {}) do
          if try(function() return o.valid end) and o.force == p.force and not seen[k(o)] then
            seen[k(o)] = true
            if not api.visible(p, o.position) then dark = dark + 1
            elseif LINE[o.type] then queue[#queue+1] = o
            elseif not mseen[k(o)] and #machines < 32 then
              mseen[k(o)] = true
              local heads = api.fluids and try(function() return api.fluids(o) end)
              machines[#machines+1] = string.format('%s %s%s', o.name, at(o.position), heads and ': ' .. heads or '')
            end
          end
        end
      end
    end
    local rows, empty, lines = {}, {}, {}
    for _, g in ipairs(order) do
      local row = {segment=g.id, entities=g.n, box=string.format('%s-%s', at({x=g.x0, y=g.y0}), at({x=g.x1, y=g.y1})),
        fluid=g.fluid, amount=g.amount and r1(g.amount) or nil, capacity=g.capacity and r1(g.capacity) or nil, flow=g.flow and r1(g.flow) or nil}
      local amt = g.amount and g.amount >= 0.05
      row.empty = not amt or nil
      row.line = string.format('segment %s %s, %d entit%s: %s%s', tostring(g.id), row.box, g.n, g.n == 1 and 'y' or 'ies',
        amt and string.format('%s %g/%g', g.fluid, row.amount, row.capacity or 0) or ('empty' .. (g.locked and ' (locked to ' .. g.locked .. ')' or g.fluid and ' (' .. g.fluid .. ' under 0.1)' or '') .. string.format(' /%g', row.capacity or 0)),
        g.flow and string.format(', flow %g/tick', row.flow) or '')
      rows[#rows+1] = row
      if row.empty then empty[#empty+1] = row.line end
      if #lines < 16 then lines[#lines+1] = row.line end
    end
    return {start=start.position, entities=n, segments=rows, empty=#empty > 0 and empty or nil, machines=#machines > 0 and machines or nil,
      not_in_sight=dark > 0 and string.format('%d connected entit%s in chunks our force does not see now, not followed', dark, dark == 1 and 'y' or 'ies') or nil,
      more=n >= NET_MAX and #queue > 0 and string.format('followed %d entities; the network goes on', NET_MAX) or nil,
      line=string.format('the pipe network through %s: %d entities in %d segment%s; %d empty%s', at(start.position), n, #rows, #rows == 1 and '' or 's', #empty,
        #lines > 0 and '; ' .. table.concat(lines, ' | ') or '')}
  end
  return M
end
