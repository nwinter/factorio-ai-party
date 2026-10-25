-- belt_flow {position, seconds?, platform?} (batch24 B2, Astra ~10 times on Kestrel: topology alone could not tell a
-- stationary queue from a full moving belt, nor items a minute across each merge). The belt line through position, up
-- to WALK tiles back and on (undergrounds followed, a splitter as a merge), is cut into sections at each merge (a tile
-- with another belt feeding it: a side-load, a splitter). The last tile of each section, and the last tile of each
-- belt merging in, is sampled for seconds: each lane's items by their unique_id, every few ticks (half the ticks an
-- item takes to cross a tile at that belt's speed). An item seen there and gone at a later sample has passed: items a
-- minute is how many passed over the window. A lane holding items that did not move is stopped (full: 4 or more on the
-- tile). At most POINTS tiles; one sample reads 2 lanes a tile. As a player watches the belts. The reply comes when the
-- sampling ends (the CLI waits; belt_flow {} reads the last one).
return function(api)
  local M = {}
  local WALK, POINTS, FULL = 64, 16, 4
  local BELT = {['transport-belt']=true, ['underground-belt']=true, splitter=true}
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function at(q) return string.format('(%g,%g)', q.x, q.y) end
  local function store() local s = api.state(); s.belt_flow = s.belt_flow or {}; return s.belt_flow end
  local function inputs(b) local bn = try(function() return b.belt_neighbours end); return bn and bn.inputs or {} end
  local function outputs(b) local bn = try(function() return b.belt_neighbours end); return bn and bn.outputs or {} end
  local function partner(b, kind)
    if b.type == 'underground-belt' and try(function() return b.belt_to_ground_type end) == kind then
      local nb = try(function() return b.neighbours end)
      if nb and nb.valid then return nb end
    end
  end
  -- The tile feeding b along the line: the straight input, else the only one, else an underground's entrance.
  local function before(b)
    local ins = inputs(b)
    for _, x in ipairs(ins) do if BELT[x.type] and x.direction == b.direction then return x end end
    if #ins == 1 and BELT[ins[1].type] then return ins[1] end
    return partner(b, 'output')
  end
  local function after(b)
    local out = outputs(b)[1]
    if out and out.valid and BELT[out.type] then return out end
    return partner(b, 'input')
  end
  -- The path through e in flow order, and per tile the belts merging into it (not the tile before it on the path).
  -- charted (optional): the walk goes on only where the map draws the belts (trace.lua's rule); it says where it stopped.
  function M.walk(e, charted)
    local path, seen = {e}, {[e.unit_number]=true}
    local stops = {}
    local b = e
    for _ = 1, WALK do
      local x = before(b)
      if not (x and x.valid) or seen[x.unit_number] then break end
      if charted and not charted(x.position) then stops[#stops+1] = 'back at ' .. at(x.position); break end
      seen[x.unit_number] = true; table.insert(path, 1, x); b = x
    end
    b = e
    for _ = 1, WALK do
      local x = after(b)
      if not (x and x.valid) or seen[x.unit_number] then break end
      if charted and not charted(x.position) then stops[#stops+1] = 'on at ' .. at(x.position); break end
      seen[x.unit_number] = true; path[#path+1] = x; b = x
    end
    local merges = {}
    for i, t in ipairs(path) do
      local prev = path[i - 1]
      for _, x in ipairs(inputs(t)) do
        if BELT[x.type] and x ~= prev and not (prev and x.unit_number == prev.unit_number) then
          merges[i] = merges[i] or {}; table.insert(merges[i], x)
        end
      end
    end
    return path, merges, stops
  end
  -- (d20 batch62 X4, Astra #1555: belt_flow on Nauvis from Aquilo) what remote view shows, as trace.lua reads it: our
  -- own platform whole; else items only in chunks our force sees now (radar coverage), the layout in charted ones.
  local function chunk(pos) return {x=math.floor(pos.x / 32), y=math.floor(pos.y / 32)} end
  local function viewer(force, surface)
    local pl = try(function() return surface.platform end)
    if pl and pl.force == force then return nil end
    return {visible=function(pos) return try(function() return force.is_chunk_visible(surface, chunk(pos)) end) == true end,
      charted=function(pos) return try(function() return force.is_chunk_charted(surface, chunk(pos)) end) == true end}
  end
  local function speed(b) return try(function() return b.prototype.belt_speed end) or 0.03125 end
  -- Points: each section's last tile (sections cut at merges), and each merging belt.
  local function points(path, merges)
    local pts, start = {}, 1
    local function section(i0, i1)
      if i1 < i0 then return end
      pts[#pts+1] = {entity=path[i1], kind='section', from=path[i0].position, to=path[i1].position, tiles=i1 - i0 + 1, index=i1}
    end
    for i = 2, #path do
      if merges[i] then
        section(start, i - 1)
        for _, x in ipairs(merges[i]) do pts[#pts+1] = {entity=x, kind='side', into=path[i].position, index=i, into_entity=path[i]} end
        start = i
      end
    end
    section(start, #path)
    while #pts > POINTS do table.remove(pts) end
    return pts
  end
  function M.start(p, e, seconds)
    assert(e and e.valid and BELT[e.type], 'belt_flow reads a belt line: position on a belt, underground or splitter tile')
    local view = viewer(p.force, e.surface)
    local path, merges, stops = M.walk(e, view and view.charted)
    local pts = points(path, merges)
    local fastest = 0
    for _, pt in ipairs(pts) do
      fastest = math.max(fastest, speed(pt.entity)); pt.lanes = {{}, {}}; pt.left = {{}, {}}; pt.moved = {false, false}; pt.max = {0, 0}
      -- (d17 batch35 B2) each point's lane cap (items a minute: speed x 4 items a tile x 3600), and a merge's geometry
      pt.cap = speed(pt.entity) * 4 * 3600
      pt.dir = try(function() return pt.entity.direction end) or 0
      if pt.kind == 'side' and pt.into_entity then
        pt.line_dir = try(function() return pt.into_entity.direction end) or 0
        pt.into_type = pt.into_entity.type
        pt.into_entity = nil
      end
    end
    local every = math.max(1, math.floor(0.5 / fastest))
    local job = {points=pts, start=game.tick, until_tick=game.tick + seconds * 60, every=every, next_tick=game.tick, samples=0,
      path_from=path[1].position, path_to=path[#path].position, tiles=#path, merges=0,
      force=view and p.force.name or nil, surface=view and e.surface.name or nil, surface_name=e.surface.name, walk_stops=#stops > 0 and stops or nil}
    for _ in pairs(merges) do job.merges = job.merges + 1 end
    store()[p.index] = job
    M.sample(job)
    job.next_tick = game.tick + every
    local labels = {}
    for i, pt in ipairs(pts) do labels[i] = pt.kind == 'side' and 'merging belt ' .. at(pt.entity.position) .. ' into ' .. at(pt.into) or 'section end ' .. at(pt.entity.position) end
    return {sampling=true, until_tick=job.until_tick, seconds=seconds, every_ticks=every, tiles=#path, points=labels, surface=e.surface.name,
      note=string.format('the belt line %s to %s (%d tiles, %d merges) on %s, sampled for %d s%s', at(job.path_from), at(job.path_to), #path, job.merges, e.surface.name, seconds,
        #stops > 0 and '; the line goes on uncharted (' .. table.concat(stops, ', ') .. '): not walked' or ''),
      ends=M.ENDS}
  end
  -- (d24 batch176 QS1, Astra #2248: the explosives line on Asterion ends blocked while inserters take before its end, and
  -- the line read said stopped) exact_tile: the two lanes of the belt at that tile only, by item id. 2.0.77's
  -- LuaTransportLine has no pass count, so an item seen on a lane and gone at a later sample left it: found on the lines
  -- the tile feeds (the next belt, an underground's own hidden lines, a splitter's outputs) it passed on. Sampled every
  -- quarter tile at the belt's speed, so an item is seen before it crosses the next. A lane's positions count down to its exit end (0; read on the copy: an item at 0.94 has just come on, one at 0.00
  -- goes next). An item gone further from the exit than a sample's travel was taken off this tile; one gone at
  -- the end and not on the next was taken there, or here at the end, before a sample saw it (an inserter takes an item in
  -- the tick it arrives). The inserters picking from the tile are counted from their hands, the game's own read.
  local DIRN = {[0]='north', [4]='east', [8]='south', [12]='west'}
  local function lines_of(e, from, to) local t = {}; for k = from, to do t[#t+1] = k end; return {entity=e, lines=t} end
  function M.start_tile(p, e, q, seconds)
    assert(e and e.valid and BELT[e.type], 'belt_flow reads a belt line: position on a belt, underground or splitter tile')
    local view = viewer(p.force, e.surface)
    local pt = {entity=e, kind='tile', index=1, lanes={{}, {}}, left={{}, {}}, taken={{}, {}}, after={{}, {}}, entered={0, 0}, moved={false, false}, max={0, 0}, lines={1, 2}}
    local ug = e.type == 'underground-belt' and try(function() return e.belt_to_ground_type end)
    local tile = {name=e.name, type=e.type, position=e.position, unit_number=e.unit_number, direction=DIRN[e.direction] or tostring(e.direction)}
    local nxt, nxt_text
    if e.type == 'splitter' then
      -- the half the position falls in: lines 1,2 the left half's input lanes, 3,4 the right half's (seen facing its way)
      local qx, qy = q.x or q[1] or e.position.x, q.y or q[2] or e.position.y
      local d = e.direction
      local lx, ly = (d == 0 and -1 or d == 8 and 1 or 0), (d == 4 and -1 or d == 12 and 1 or 0)
      local left = (qx - e.position.x) * lx + (qy - e.position.y) * ly > 0
      pt.lines = left and {1, 2} or {3, 4}
      tile.half = left and 'left' or 'right'
      nxt, nxt_text = lines_of(e, 5, 8), 'the splitter\'s outputs'
    elseif ug == 'input' then
      tile.underground = 'entrance'
      nxt, nxt_text = lines_of(e, 3, 4), 'its own underground lines'
    else
      if ug then tile.underground = 'exit' end
      local out = outputs(e)[1]
      if out and out.valid and BELT[out.type] then
        nxt = lines_of(out, 1, try(function() return out.get_max_transport_line_index() end) or 2)
        nxt_text = string.format('%s %s', out.name, at(out.position))
      end
    end
    pt.next, pt.next_text = nxt, nxt_text or 'nothing: the line ends here'
    -- inserters whose pickup point is on the tile (read once)
    local tx, ty = math.floor(e.type == 'splitter' and (q.x or q[1] or e.position.x) or e.position.x), math.floor(e.type == 'splitter' and (q.y or q[2] or e.position.y) or e.position.y)
    local takers, hands = {}, {}
    for _, i in ipairs(try(function() return e.surface.find_entities_filtered{area={{tx - 3, ty - 3}, {tx + 4, ty + 4}}, type='inserter'} end) or {}) do
      local pp = try(function() return i.pickup_position end)
      if pp and math.floor(pp.x) == tx and math.floor(pp.y) == ty then
        takers[#takers+1] = string.format('%s %s #%d', i.name, at(i.position), i.unit_number)
        hands[#hands+1] = {entity=i, text=takers[#takers], last=0, picked=0, items={}}
      end
    end
    local sp = speed(e)
    if nxt and nxt.entity ~= e then sp = math.max(sp, speed(nxt.entity)) end
    local every = math.max(1, math.floor(0.25 / sp))
    pt.step = speed(e) * every + 0.01
    local job = {exact=true, points={pt}, start=game.tick, until_tick=game.tick + seconds * 60, every=every, next_tick=game.tick, samples=0,
      path_from=e.position, path_to=e.position, tiles=1, merges=0, tile=tile, takers=takers, hands=hands,
      force=view and p.force.name or nil, surface=view and e.surface.name or nil, surface_name=e.surface.name}
    return job
  end
  local function find_ids(nxt, ids)
    local found = {}
    if not (nxt and nxt.entity.valid) then return found end
    for _, k in ipairs(nxt.lines) do
      for _, it in ipairs(try(function() return nxt.entity.get_transport_line(k).get_detailed_contents() end) or {}) do
        if it.unique_id and ids[it.unique_id] then found[it.unique_id] = true end
      end
    end
    return found
  end
  local function sample_tile(job)
    local pt = job.points[1]
    local e = pt.entity
    local force, surface = job.force and game.forces[job.force], job.surface and game.get_surface(job.surface)
    local view = force and surface and viewer(force, surface)
    if not e.valid then pt.gone = true; return end
    if view and not view.visible(e.position) then pt.unseen = (pt.unseen or 0) + 1; return end
    local first = job.samples == 1
    local gone, any = {{}, {}}, false
    for k = 1, 2 do
      local now = {}
      local items = try(function() return e.get_transport_line(pt.lines[k]).get_detailed_contents() end) or {}
      for _, it in ipairs(items) do
        local id = it.unique_id
        if id then
          local was = pt.lanes[k][id]
          if was and math.abs(was.pos - it.position) > 0.001 then pt.moved[k] = true end
          if not was and not first then pt.entered[k] = pt.entered[k] + 1 end
          now[id] = {pos=it.position, name=it.stack and it.stack.valid_for_read and it.stack.name or '?'}
        end
      end
      for id, was in pairs(pt.lanes[k]) do if not now[id] then gone[k][id] = was; any = true; pt.moved[k] = true end end
      pt.lanes[k] = now
      pt.max[k] = math.max(pt.max[k], #items)
      pt.count = pt.count or {0, 0}; pt.count[k] = #items
    end
    if any then
      local ids = {}
      for k = 1, 2 do for id in pairs(gone[k]) do ids[id] = true end end
      local on = find_ids(pt.next, ids)
      for k = 1, 2 do
        for id, was in pairs(gone[k]) do
          pt.left[k][id] = was.name
          if not on[id] then
            if was.pos > pt.step then pt.taken[k][id] = was.name else pt.after[k][id] = was.name end
          end
        end
      end
    end
    for _, h in ipairs(job.hands) do
      local st = h.entity.valid and try(function() return h.entity.held_stack end)
      local n = st and st.valid_for_read and st.count or 0
      if n > h.last and not first then h.picked = h.picked + n - h.last; h.items[st.name] = (h.items[st.name] or 0) + n - h.last end
      h.last = n
    end
  end
  -- One sample: each point's lanes by item id; an id seen before and gone now has passed.
  function M.sample(job)
    job.samples = job.samples + 1
    if job.exact then
      sample_tile(job)
      local pt = job.points[1]
      job.sampled, job.all_gone = game.tick, (pt.gone or (pt.unseen or 0) >= job.samples) or nil
      return
    end
    local force, surface = job.force and game.forces[job.force], job.surface and game.get_surface(job.surface)
    local view = force and surface and viewer(force, surface)
    for _, pt in ipairs(job.points) do
      local e = pt.entity
      if e.valid and view and not view.visible(e.position) then
        pt.unseen = (pt.unseen or 0) + 1
      elseif e.valid then
        for k = 1, 2 do
          local now = {}
          local items = try(function() return e.get_transport_line(k).get_detailed_contents() end) or {}
          for _, it in ipairs(items) do
            local id = it.unique_id
            if id then
              local was = pt.lanes[k][id]
              if was and math.abs(was.pos - it.position) > 0.001 then pt.moved[k] = true end
              now[id] = {pos=it.position, name=it.stack and it.stack.valid_for_read and it.stack.name or '?'}
            end
          end
          for id, was in pairs(pt.lanes[k]) do if not now[id] then pt.left[k][id] = was.name; pt.moved[k] = true end end
          pt.lanes[k] = now
          pt.max[k] = math.max(pt.max[k], #items)
          pt.count = pt.count or {0, 0}; pt.count[k] = #items
        end
      else pt.gone = true end
    end
    -- (d20 batch70 AF1) when it was last read, and whether a point is left to read (measures.lua: the idle count)
    local live = false
    for _, pt in ipairs(job.points) do if not pt.gone and (pt.unseen or 0) < job.samples then live = true; break end end
    job.sampled, job.all_gone = game.tick, not live or nil
  end
  local function lane_text(pt, k, minutes)
    local by, n = {}, 0
    for _, name in pairs(pt.left[k]) do by[name] = (by[name] or 0) + 1; n = n + 1 end
    local names = {}
    for name, c in pairs(by) do names[#names+1] = name .. ' ' .. c end
    table.sort(names)
    local rate = math.floor(n / minutes * 10 + 0.5) / 10
    local held = pt.count and pt.count[k] or 0
    -- (d18 batch38 D3, Opus: a lane read "stopped, full" was coal, read as iron ore) what stands on the tile now, by name
    local on, on_names = {}, {}
    for _, it in pairs(pt.lanes[k] or {}) do if it.name then on[it.name] = (on[it.name] or 0) + 1 end end
    for name, c in pairs(on) do on_names[#on_names+1] = {name=name, c=c} end
    table.sort(on_names, function(x, y) if x.c ~= y.c then return x.c > y.c end return x.name < y.name end)
    for i, x in ipairs(on_names) do on_names[i] = x.c .. ' ' .. x.name end
    local on_text = #on_names > 0 and table.concat(on_names, ', ') or nil
    local state
    if n > 0 then state = string.format('%g/min', rate)
    elseif held == 0 then state = 'empty'
    elseif not pt.moved[k] then state = held >= FULL and string.format('stopped, full (%s on the tile)', on_text or held) or string.format('stopped (%s on the tile)', on_text or held)
    else state = '0/min' end
    return {rate=rate, passed=n, items=#names > 0 and table.concat(names, ', ') or nil, held=held, on_tile=on_text, state=state}
  end
  local function count(t) local n = 0; for _ in pairs(t) do n = n + 1 end; return n end
  local function by_name(set, counted)
    local by, names = {}, {}
    if counted then by = set else for _, name in pairs(set) do by[name] = (by[name] or 0) + 1 end end
    for name, c in pairs(by) do names[#names+1] = name .. ' ' .. c end
    table.sort(names)
    return #names > 0 and table.concat(names, ', ') or nil
  end
  local function finish_tile(job, minutes)
    local pt = job.points[1]
    local lanes, parts = {}, {}
    for k = 1, 2 do
      local l = lane_text(pt, k, minutes)
      local taken, after = count(pt.taken[k]), count(pt.after[k])
      l.left, l.passed_on, l.taken, l.not_seen_after, l.entered, l.held_max = l.passed, l.passed - taken - after, taken, after, pt.entered[k], pt.max[k]
      l.taken_items = by_name(pt.taken[k])
      l.passed = nil
      lanes[k] = l
      parts[k] = string.format('%s lane %s%s%s, %d held', k == 1 and 'left' or 'right', l.state, l.items and ' (' .. l.items .. ')' or '',
        l.left > 0 and string.format(': %d seen on %s after, %d gone from mid-lane (taken off this tile), %d gone at the lane\'s end and not seen on it', l.passed_on, pt.next_text, l.taken, l.not_seen_after) or '', l.held)
    end
    local minutes_text = function(n) return math.floor(n / minutes * 10 + 0.5) / 10 end
    local hands, picked = {}, 0
    for _, h in ipairs(job.hands) do
      picked = picked + h.picked
      hands[#hands+1] = {inserter=h.text, picked=h.picked, rate=minutes_text(h.picked), items=by_name(h.items, true)}
    end
    local t = job.tile
    local where = string.format('tile %s %s #%d facing %s%s', at(t.position), t.name, t.unit_number, t.direction,
      t.half and ' (its ' .. t.half .. ' half\'s input lanes)' or t.underground and ' (underground ' .. t.underground .. ')' or '')
    local lines = {}
    if pt.unseen and pt.unseen >= job.samples then lines[1] = where .. ': out of sight (no radar coverage there): not sampled'
    else lines[1] = where .. ': ' .. parts[1] .. '; ' .. parts[2] end
    if pt.gone then lines[#lines+1] = 'the belt was removed while sampling' end
    if #hands > 0 then
      local hp = {}
      for i, h in ipairs(hands) do hp[i] = string.format('%s picked %d (%g/min%s)', h.inserter, h.picked, h.rate, h.items and ': ' .. h.items or '') end
      lines[#lines+1] = 'inserters picking from this tile (their hands read each sample): ' .. table.concat(hp, ', ')
    else lines[#lines+1] = 'no inserter picks from this tile' end
    pt.entity, pt.next = nil, nil
    for _, h in ipairs(job.hands) do h.entity = nil end
    return {done=true, exact_tile=true, surface=job.surface_name, seconds=math.floor((game.tick - job.start) / 6 + 0.5) / 10, samples=job.samples, every_ticks=job.every,
      tile=t, left=lanes[1], right=lanes[2], rate=lanes[1].rate + lanes[2].rate, feeds=pt.next_text, inserters=hands, picked=picked, picked_rate=minutes_text(picked),
      gone=pt.gone and 'the belt was removed while sampling' or nil,
      out_of_sight=pt.unseen and string.format('out of sight for %d of %d samples', pt.unseen, job.samples) or nil, lines=lines,
      note='this tile only, by item id (2.0.77 has no pass count on a transport line): an item seen on a lane and gone at a later sample left it (rate: items a minute that left); passed_on: seen on what the tile feeds at the next sample; taken: gone from mid-lane, so taken off this tile; not_seen_after: gone at the lane\'s end and not seen on what it feeds (taken there, or here at the end, before a sample saw it); an item that comes onto the tile and is taken in the same tick is never seen on the lane: the inserters\' picked counts (their hands) include it; entered: items that came onto the lane; a lane whose items did not move is stopped (full: 4 or more on the tile)'}
  end
  function M.finish(job)
    local minutes = math.max(1, game.tick - job.start) / 3600
    if job.exact then return finish_tile(job, minutes) end
    local rows, lines, by_index = {}, {}, {}
    for _, pt in ipairs(job.points) do
      local L, R = lane_text(pt, 1, minutes), lane_text(pt, 2, minutes)
      local row = {kind=pt.kind, position=pt.entity.valid and pt.entity.position or nil, left=L, right=R, rate=L.rate + R.rate}
      if pt.kind == 'section' then row.from, row.to, row.tiles = pt.from, pt.to, pt.tiles else row.into = pt.into end
      if pt.gone then row.gone = 'the belt was removed while sampling' end
      if pt.unseen then
        row.out_of_sight = pt.unseen >= job.samples and 'out of sight (no radar coverage there): not sampled'
          or string.format('out of sight for %d of %d samples: counted over the rest', pt.unseen, job.samples)
      end
      rows[#rows+1] = row
      local where = pt.kind == 'section' and string.format('section %s to %s (%d tiles)', at(pt.from), at(pt.to), pt.tiles)
        or string.format('belt %s merging into %s', at(row.position or pt.into), at(pt.into))
      if pt.unseen and pt.unseen >= job.samples then lines[#lines+1] = where .. ': ' .. row.out_of_sight
      else lines[#lines+1] = string.format('%s: left lane %s%s; right lane %s%s%s', where, L.state, L.items and ' (' .. L.items .. ')' or '', R.state, R.items and ' (' .. R.items .. ')' or '',
        row.out_of_sight and ' (' .. row.out_of_sight .. ')' or '') end
      by_index[pt.index] = by_index[pt.index] or {}
      table.insert(by_index[pt.index], row)
    end
    -- Across each merge: the section before it and each belt merging in, against the section from it.
    local merges = {}
    for i, pt in ipairs(job.points) do
      if pt.kind == 'section' then
        local sides, before_row = {}, nil
        for j, q in ipairs(job.points) do
          if q.kind == 'side' and q.index == pt.index - pt.tiles + 1 then sides[#sides+1] = rows[j] end
          if q.kind == 'section' and q.index == pt.index - pt.tiles then before_row = rows[j] end
        end
        if #sides > 0 then
          local parts, total = {}, 0
          if before_row then parts[#parts+1] = string.format('line %g/min', before_row.rate); total = total + before_row.rate end
          for _, s in ipairs(sides) do parts[#parts+1] = string.format('belt %s %g/min', at(s.position or s.into), s.rate); total = total + s.rate end
          merges[#merges+1] = string.format('merge at %s: %s in (%g/min), %g/min on after it', at(pt.from), table.concat(parts, ' + '), total, rows[i].rate)
        end
      end
    end
    for _, m in ipairs(merges) do lines[#lines+1] = m end
    -- (d17 batch35 B2, Sol: a saturated return side-loaded both its lanes onto one lane and blocked calcite and ice
    -- downstream; Opus: 9 copper drills blocked and no read said why) each merge's sources and the lane it fills, and
    -- the point that limits the line.
    local DIRN = {[0]='north', [4]='east', [8]='south', [12]='west'}
    local mix = {}
    for i, pt in ipairs(job.points) do
      if pt.kind == 'side' then
        local d, ld = pt.dir or 0, pt.line_dir or 0
        local text
        if pt.into_type ~= 'splitter' and (d - ld) % 8 ~= 0 then
          -- a side-load: from the line's left side when the side belt sits to the left of the line (it faces the line's right turn)
          local from_left = (ld + 4) % 16 == d
          text = string.format('side-load at %s: belt %s facing %s comes in from the line\'s %s side (the line faces %s): both its lanes go onto the line\'s %s lane',
            at(pt.into), at(pt.entity.valid and pt.entity.position or pt.into), DIRN[d] or tostring(d), from_left and 'left' or 'right', DIRN[ld] or tostring(ld), from_left and 'left' or 'right')
        else
          text = string.format('merge at %s: belt %s facing %s joins the line (facing %s) through %s: each lane onto the same lane', at(pt.into),
            at(pt.entity.valid and pt.entity.position or pt.into), DIRN[d] or tostring(d), DIRN[ld] or tostring(ld), pt.into_type == 'splitter' and 'a splitter' or 'its end')
        end
        -- the lanes after it: the section that starts at the merge tile
        for j, q in ipairs(job.points) do
          if q.kind == 'section' and q.index - q.tiles + 1 == pt.index then
            local r = rows[j]
            text = text .. string.format('; after it the left lane carries %s, the right %s', r.left.items or r.left.state, r.right.items or r.right.state)
          end
        end
        mix[#mix+1] = text
      end
    end
    for _, m in ipairs(mix) do lines[#lines+1] = m end
    -- the limit: the end backed up (the consumers take less than the line carries), a lane at its cap, or a side-load
    -- waiting while the lane it goes onto runs full (the straight line goes first)
    local limit
    local last
    for j, q in ipairs(job.points) do if q.kind == 'section' then last = j end end
    local function at_cap(r, k, cap) local l = k == 1 and r.left or r.right; return cap and cap > 0 and l.rate >= 0.9 * cap end
    local function stopped_full(l) return l.state:find('stopped, full', 1, true) ~= nil end
    for j, q in ipairs(job.points) do
      if not limit and q.kind == 'side' and (stopped_full(rows[j].left) or stopped_full(rows[j].right)) then
        for k2, q2 in ipairs(job.points) do
          if q2.kind == 'section' and q2.index - q2.tiles + 1 == q.index then
            local lane = (q.into_type ~= 'splitter' and ((q.line_dir or 0) + 4) % 16 == (q.dir or 0)) and 1 or 2
            if at_cap(rows[k2], lane, q2.cap) or at_cap(rows[k2], 1, q2.cap) or at_cap(rows[k2], 2, q2.cap) then
              local held = stopped_full(rows[j].left) and rows[j].left.on_tile or rows[j].right.on_tile
              limit = string.format('a side-load waits at %s: belt %s is stopped full%s while the line after it runs at its cap (%g/min a lane): the line\'s own items go first',
                at(q.into), at(rows[j].position or q.into), held and ' of ' .. held or '', q2.cap)
            end
          end
        end
      end
    end
    if not limit and last then
      local r = rows[last]
      if stopped_full(r.left) and stopped_full(r.right) then
        limit = string.format('the end is backed up: both lanes stopped full at %s (left %s, right %s): whatever takes from the end takes less than the line carries', at(r.to),
          r.left.on_tile or '?', r.right.on_tile or '?')
      elseif stopped_full(r.left) or stopped_full(r.right) then
        local l = stopped_full(r.left) and r.left or r.right
        limit = string.format('the end is backed up on its %s lane at %s (%s)', stopped_full(r.left) and 'left' or 'right', at(r.to), l.on_tile or '?')
      end
    end
    if not limit then
      for j, q in ipairs(job.points) do
        if not limit and q.kind == 'section' then
          for k = 1, 2 do
            if not limit and at_cap(rows[j], k, q.cap) then
              limit = string.format('the %s lane runs at its cap in section %s to %s (%g/min of %g/min): the belt carries no more on it', k == 1 and 'left' or 'right',
                at(q.from), at(q.to), (k == 1 and rows[j].left or rows[j].right).rate, q.cap)
            end
          end
        end
      end
    end
    if limit then lines[#lines+1] = 'limit: ' .. limit end
    for _, pt in ipairs(job.points) do pt.entity = nil end
    if job.walk_stops then lines[#lines+1] = 'the line goes on uncharted (' .. table.concat(job.walk_stops, ', ') .. '): not walked' end
    return {done=true, surface=job.surface_name, seconds=math.floor((game.tick - job.start) / 6 + 0.5) / 10, samples=job.samples, every_ticks=job.every, tiles=job.tiles,
      from=job.path_from, to=job.path_to, points=rows, merges=#merges > 0 and merges or nil, lane_mix=#mix > 0 and mix or nil, limit=limit, lines=lines,
      note='an item counts once it leaves the tile sampled; a lane whose items did not move over the window is stopped (full: 4 or more on the tile)'}
  end
  function M.tick(tick)
    local all = api.state().belt_flow
    if not all then return end
    for _, job in pairs(all) do
      if not job.result and tick >= job.next_tick then
        M.sample(job)
        job.next_tick = tick + job.every
        if tick >= job.until_tick then job.result = M.finish(job); job.points = nil end
      end
    end
  end
  -- (d22 batch106 BP1, Luna sent stop to end a sample) a sample is no character action: nothing ends it before until_tick
  -- (stop ends the character's action and combat and pauses the queue; a new sample, belt_flow {position}, replaces it).
  M.ENDS = 'the sample ends at until_tick: stop and your actions do not end it (a new belt_flow {position} replaces it); fh wait waits for it when nothing else runs'
  -- (d25 batch200 QM2) a new sample's seconds: the handler's check and a queue step's (runtime.lua step_ranges)
  M.SECONDS = {2, 30}
  function M.handler(p, a)
    if a.position == nil then
      -- (d20 batch62 X2, Sol #1529) the sample so far is read where it was started: platform goes with position (a new sample there)
      assert(a.platform == nil and a.surface == nil, 'surface and platform go with position (a belt there); belt_flow {} reads your sample where it began')
      local job = store()[p.index]
      assert(job, 'no belt_flow sampled yet: belt_flow {position, seconds?}')
      if job.result then job.read_tick = game.tick; return job.result end  -- its final read (measures.lua)
      return {sampling=true, until_tick=job.until_tick, seconds_left=math.max(0, math.ceil((job.until_tick - game.tick) / 60)), ends=M.ENDS}
    end
    local seconds = a.seconds == nil and 10 or a.seconds
    assert(type(seconds) == 'number' and seconds >= M.SECONDS[1] and seconds <= M.SECONDS[2] and seconds == math.floor(seconds), string.format('seconds: %d..%d (default 10)', M.SECONDS[1], M.SECONDS[2]))
    local reason = api.reason and api.reason(a.reason)  -- (d20 batch70 AF1) its own reason to wait (measures.lua)
    assert(a.platform == nil or a.surface == nil, 'give platform or surface, not both')
    local q = a.surface ~= nil and api.on_surface(p, a.surface) or a.platform ~= nil and api.on_platform(p, a.platform) or p
    local e = api.remote_entity(q, {position=a.position})
    assert(a.exact_tile == nil or type(a.exact_tile) == 'boolean', 'exact_tile: true or false')
    if a.exact_tile then
      local job = M.start_tile(p, e, a.position, seconds)
      store()[p.index] = job
      job.reason = reason
      M.sample(job)
      job.next_tick = game.tick + job.every
      local t = job.tile
      return {sampling=true, exact_tile=true, until_tick=job.until_tick, seconds=seconds, every_ticks=job.every, tile=t, feeds=job.points[1].next_text, inserters=job.takers, surface=e.surface.name,
        note=string.format('the tile %s (%s #%d facing %s%s) only, both lanes, on %s, sampled for %d s', at(t.position), t.name, t.unit_number, t.direction,
          t.half and ', its ' .. t.half .. ' half' or '', e.surface.name, seconds), ends=M.ENDS}
    end
    local out = M.start(p, e, seconds)
    store()[p.index].reason = reason
    return out
  end
  M.schema = {belt_flow = {reason='optional text, up to 200 characters: your own reason to wait for it, shown with the watch in your sleep line, sleep_check and the operator\'s idle check', position='a belt, underground or splitter tile {x,y}', seconds='optional 2..30 (default 10): how long to sample',
    platform='optional platform name (platform coordinates)',
    exact_tile='optional true: the belt at position only (no line walked): its two lanes (a splitter: the half position is in, its input lanes; an underground: the tile\'s own lanes), each lane\'s items that left the tile by item id: seen on what the tile feeds after (passed_on), gone from mid-lane (taken), or gone at the lane\'s end and not seen on what it feeds (not_seen_after); entered, held, the rate; and the inserters picking from the tile, counted from their hands. Returns tile {name, type, position, unit_number, direction, half, underground}, left, right {rate, left, passed_on, taken, not_seen_after, taken_items, entered, items, held, held_max, on_tile, state}, rate, feeds, inserters [{inserter, picked, rate, items}], picked, picked_rate, lines',
    surface='optional planet, surface or platform name (default yours): the belt there by remote view (d20 batch62 X4): the start tile in a chunk our force sees now (radar coverage); the line is walked where the map is charted, and a point out of sight is not sampled (said per point: out_of_sight)',
    returns='the belt line through position (up to 64 tiles back and 64 on; undergrounds followed; cut into sections at each merge: a side-load or a splitter), its sections\' last tiles and each belt merging in sampled for seconds by item: points [{kind (section, side), from, to, tiles, into, left, right {rate (items a minute that left the tile), passed, items (by name), held (on the tile now), state (N/min, empty, stopped (full: 4 or more on the tile), with what stands on the tile by name), on_tile}, rate}], merges (across each: the line before it and each belt merging in, against the line after it), lane_mix (each merge: a side-load from which side of the line, the lane both its lanes go onto, or a splitter or end-on join lane to lane; what each lane carries after it), limit (what limits the line: a side-load stopped full while the line after it runs at its cap, the straight line\'s items going first; the end backed up, both lanes or one stopped full; else a lane at its cap, items a minute against speed x 4 a tile x 3600), lines, samples, every_ticks. The call returns when the sampling ends; belt_flow {} reads the last result (or the seconds left). The sample ends at until_tick: stop and your actions do not end it (a new belt_flow {position} replaces it); fh wait waits for it when nothing else runs (ends says so). Read only'}}
  return M
end
