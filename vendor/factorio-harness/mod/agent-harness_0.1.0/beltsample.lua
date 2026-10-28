-- belt_flow {position, seconds?, platform?} (batch24 B2, Astra ~10 times on Kestrel: topology alone could not tell a
-- stationary queue from a full moving belt, nor items a minute across each merge). The belt line through position, up
-- to WALK tiles back and on (undergrounds followed, a splitter as a merge), is cut into sections at each merge (a tile
-- with another belt feeding it: a side-load, a splitter). The last tile of each section, and the last tile of each
-- belt merging in, is sampled for seconds: each lane's items by their unique_id, every few ticks (half the ticks an
-- item takes to cross a tile at that belt's speed; d25 batch210 QW1: where an inserter picks from a sampled tile, at
-- most the ticks between two items on a lane and the inserter's half swing). An item seen there and gone at a later
-- sample has passed: items a minute is how many passed over the window. Where inserters pick from a sampled tile their
-- hands are read each sample, and the point's rate is passed on + picked. A lane holding items that did not move is stopped (full: 4 or more on the
-- tile). At most POINTS tiles; one sample reads 2 lanes a tile. As a player watches the belts. The reply comes when the
-- sampling ends (the CLI waits; belt_flow {} reads the last one).
-- (d27 batch269 BS, Sol #2570: 4 big mining drills put 1267 ore a minute on a line belt_flow read as 634/min) a lane
-- entry is a stack: read on a copy (2.0.77), get_detailed_contents gives one entry a stack, its unique_id and
-- stack.count; a big mining drill (drops_full_belt_stacks) and a stack inserter put stacks of 1 + the force's
-- belt_stack_size_bonus on a belt (stack-inserter research +1: 2), other drills and inserters one item; an inserter
-- takes items, part of a stack too (the stack keeps its id, its count falls). Every count here is items (a stack counts
-- its count); stacks a minute beside them; a lane tile holds 4 stacks (full) and moves speed x 4 x 3600 stacks a minute.
return function(api)
  local M = {}
  local WALK, POINTS, FULL = 64, 16, 4
  -- (d27 batch269 BS) items left a lane: set[id] = name as before, and counts[id] = its items when not 1 (no table an
  -- item: the sampler's cost stays); a sample begun before this has no counts: one item an id
  local function add_left(set, counts, id, name, n)
    local total = (set[id] and (counts[id] or 1) or 0) + n
    set[id] = set[id] or name
    if total ~= 1 then counts[id] = total else counts[id] = nil end
  end
  local function lazy(pt, key) local t = pt[key]; if not t then t = {{}, {}}; pt[key] = t end; return t end
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
  -- (d25 batch210 QW1, Sol #2368: a line read at a bulk inserter's pickup tile gave 277/min where it took 746) the
  -- inserters whose pickup point is on tile (tx,ty), read once, and each one's half swing in ticks (0.5 turn at its
  -- quality's rotation speed): from its last pickup to its drop the hand holds what it picked for at least that long.
  -- Read on a copy (2.0.77): items come every 8 ticks a lane on a transport belt, 4 fast, 2 or 3 express, 2 turbo; a
  -- bulk inserter at a lane's end took items 1-3 ticks after they came on (yellow) or in the tick they came (turbo:
  -- 202 of 396 never on the tile at any tick), so a lane read misses them at any interval and the hands count them.
  local function takers_at(surface, tx, ty)
    local hands, texts = {}, {}
    for _, i in ipairs(try(function() return surface.find_entities_filtered{area={{tx - 3, ty - 3}, {tx + 4, ty + 4}}, type='inserter'} end) or {}) do
      local pp = try(function() return i.pickup_position end)
      if pp and math.floor(pp.x) == tx and math.floor(pp.y) == ty then
        local rot = try(function() return i.prototype.get_inserter_rotation_speed(i.quality) end) or 0.04
        texts[#texts+1] = string.format('%s %s #%d', i.name, at(i.position), i.unit_number)
        hands[#hands+1] = {entity=i, text=texts[#texts], last=0, picked=0, items={}, swing=math.max(1, math.floor(0.5 / rot))}
      end
    end
    return hands, texts
  end
  local function read_hands(hands, first)
    for _, h in ipairs(hands) do
      local st = h.entity.valid and try(function() return h.entity.held_stack end)
      local n = st and st.valid_for_read and st.count or 0
      if n > h.last and not first then h.picked = h.picked + n - h.last; h.items[st.name] = (h.items[st.name] or 0) + n - h.last end
      h.last = n
    end
  end
  local function lines_of(e, from, to) local t = {}; for k = from, to do t[#t+1] = k end; return {entity=e, lines=t} end
  -- What a belt's lanes 1,2 feed: a splitter's outputs, an underground entrance's own hidden lines, else the next belt.
  local function feeds(e)
    if e.type == 'splitter' then return lines_of(e, 5, 8), 'the splitter\'s outputs' end
    if e.type == 'underground-belt' and try(function() return e.belt_to_ground_type end) == 'input' then return lines_of(e, 3, 4), 'its own underground lines' end
    local out = outputs(e)[1]
    if out and out.valid and BELT[out.type] then
      return lines_of(out, 1, try(function() return out.get_max_transport_line_index() end) or 2), string.format('%s %s', out.name, at(out.position))
    end
  end
  -- The tile a point's lanes 1,2 run on: a splitter's left half (facing its way), else the belt's own tile.
  local function tile_of(e)
    if e.type == 'splitter' then
      local d = e.direction
      return math.floor(e.position.x + 0.5 * (d == 0 and -1 or d == 8 and 1 or 0)), math.floor(e.position.y + 0.5 * (d == 4 and -1 or d == 12 and 1 or 0))
    end
    return math.floor(e.position.x), math.floor(e.position.y)
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
  -- (d27 batch269 BS) one lane of a point read now: each entry by id {pos, name, n}; entered, part-stacks taken (their
  -- count fell on the tile: left; with part_taken also taken) and stacks gone (left whole: whole counts them) recorded;
  -- the ids gone go into gone {id: record}, made when one goes; returns gone.
  local function read_lane(pt, k, items, first, gone, part_taken, part_counts)
    local now, held, stacks = {}, 0, 0
    pt.stacks = pt.stacks or {0, 0}; pt.stack_max = pt.stack_max or {1, 1}
    local left_n = lazy(pt, 'left_n')[k]
    if not pt.whole then pt.whole = {0, 0}; for j = 1, 2 do for _ in pairs(pt.left[j]) do pt.whole[j] = pt.whole[j] + 1 end end end
    for _, it in ipairs(items) do
      local id = it.unique_id
      if id then
        local st = it.stack
        local ok = st and st.valid_for_read
        local c = ok and st.count or 1
        held, stacks = held + c, stacks + 1
        if c > pt.stack_max[k] then pt.stack_max[k] = c end
        local was = pt.lanes[k][id]
        if was and math.abs(was.pos - it.position) > 0.001 then pt.moved[k] = true end
        if not was and not first and pt.entered then pt.entered[k] = pt.entered[k] + c end
        if was and c < (was.n or 1) then
          add_left(pt.left[k], left_n, id, was.name, (was.n or 1) - c); pt.moved[k] = true
          if part_taken then add_left(part_taken, part_counts, id, was.name, (was.n or 1) - c) end
        end
        -- an id keeps its item: its name read once (the count each sample, for part-stacks taken)
        now[id] = {pos=it.position, name=was and was.name or ok and st.name or '?', n=c}
      end
    end
    for id, was in pairs(pt.lanes[k]) do
      if not now[id] then
        add_left(pt.left[k], left_n, id, was.name, was.n or 1); pt.whole[k] = pt.whole[k] + 1; pt.moved[k] = true
        gone = gone or {}; gone[id] = was
      end
    end
    pt.lanes[k] = now
    pt.max[k] = math.max(pt.max[k], held)
    pt.count = pt.count or {0, 0}; pt.count[k] = held; pt.stacks[k] = stacks
    return gone
  end
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
    local fastest, swing = 0, math.huge
    for _, pt in ipairs(pts) do
      fastest = math.max(fastest, speed(pt.entity)); pt.lanes = {{}, {}}; pt.left = {{}, {}}; pt.moved = {false, false}; pt.max = {0, 0}; pt.entered = {0, 0}
      -- (d25 batch210 QW1) the inserters picking from the point's tile, and what it feeds (to tell passed on from taken)
      local tx, ty = tile_of(pt.entity)
      pt.hands = takers_at(pt.entity.surface, tx, ty)
      for _, h in ipairs(pt.hands) do swing = math.min(swing, h.swing) end
      if #pt.hands > 0 then pt.next, pt.next_text = feeds(pt.entity); pt.next_text = pt.next_text or 'nothing: the line ends here'; pt.passed_on = 0 end
      -- (d17 batch35 B2) each point's lane cap (items a minute: speed x 4 items a tile x 3600), and a merge's geometry
      pt.cap = speed(pt.entity) * 4 * 3600
      pt.dir = try(function() return pt.entity.direction end) or 0
      if pt.kind == 'side' and pt.into_entity then
        pt.line_dir = try(function() return pt.into_entity.direction end) or 0
        pt.into_type = pt.into_entity.type
        pt.into_entity = nil
      end
    end
    local every = math.max(1, swing < math.huge and math.min(math.floor(0.25 / fastest), swing) or math.floor(0.5 / fastest))
    local job = {points=pts, start=game.tick, until_tick=game.tick + seconds * 60, every=every, next_tick=game.tick, samples=0,
      path_from=path[1].position, path_to=path[#path].position, tiles=#path, merges=0,
      force=view and p.force.name or nil, surface=view and e.surface.name or nil, surface_name=e.surface.name, walk_stops=#stops > 0 and stops or nil}
    for _ in pairs(merges) do job.merges = job.merges + 1 end
    job.stack_size = M.stack_size(p.force)
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
  -- (d27 batch269 BS) the stacks a stack inserter or a big mining drill puts on a belt: 1 + the force's bonus
  function M.stack_size(force) return 1 + (try(function() return force.belt_stack_size_bonus end) or 0) end
  -- what a reply says of stacks: the belt stack size, and the lanes that carried stacks over the sample
  local function stacking(job, lanes)
    local n = job.stack_size or 1
    local most, where = 1, {}
    for _, x in ipairs(lanes) do if x.lane.stack_max then most = math.max(most, x.lane.stack_max); where[#where+1] = x.where end end
    local text = string.format('belt stack size %d (1 + the force\'s belt stack bonus %d): a stack inserter or a big mining drill puts stacks of up to %d on a belt, other inserters and drills one item; a lane tile holds 4 stacks', n, n - 1, n)
    if #where > 0 then text = text .. string.format('; stacks of up to %d seen on %d of %d lanes sampled (lanes): every count here is items (a stack counts its items), stacks_rate stacks', most, #where, #lanes) end
    return {belt_stack_size=n, largest=most, lanes=#where > 0 and where or nil, line=text}
  end
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
    elseif ug then tile.underground = ug == 'input' and 'entrance' or 'exit' end
    nxt, nxt_text = feeds(e)
    pt.next, pt.next_text = nxt, nxt_text or 'nothing: the line ends here'
    -- inserters whose pickup point is on the tile (read once)
    local tx, ty = math.floor(e.type == 'splitter' and (q.x or q[1] or e.position.x) or e.position.x), math.floor(e.type == 'splitter' and (q.y or q[2] or e.position.y) or e.position.y)
    local hands, takers = takers_at(e.surface, tx, ty)
    local sp = speed(e)
    if nxt and nxt.entity ~= e then sp = math.max(sp, speed(nxt.entity)) end
    local every = math.floor(0.25 / sp)
    for _, h in ipairs(hands) do every = math.min(every, h.swing) end
    every = math.max(1, every)
    pt.step = speed(e) * every + 0.01
    local job = {exact=true, points={pt}, start=game.tick, until_tick=game.tick + seconds * 60, every=every, next_tick=game.tick, samples=0,
      path_from=e.position, path_to=e.position, tiles=1, merges=0, tile=tile, takers=takers, hands=hands,
      force=view and p.force.name or nil, surface=view and e.surface.name or nil, surface_name=e.surface.name, stack_size=M.stack_size(p.force)}
    return job
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
      local items = try(function() return e.get_transport_line(pt.lines[k]).get_detailed_contents() end) or {}
      -- (d27 batch269 BS) part of a stack taken off the tile (its count fell) is taken
      local taken_n = lazy(pt, 'taken_n')[k]
      gone[k] = read_lane(pt, k, items, first, nil, pt.taken[k], taken_n) or {}
      if next(gone[k]) then any = true end
    end
    if any then
      local ids = {}
      for k = 1, 2 do for id in pairs(gone[k]) do ids[id] = true end end
      local on = find_ids(pt.next, ids)
      for k = 1, 2 do
        for id, was in pairs(gone[k]) do
          if not on[id] then
            if was.pos > pt.step then add_left(pt.taken[k], lazy(pt, 'taken_n')[k], id, was.name, was.n or 1)
            else add_left(pt.after[k], lazy(pt, 'after_n')[k], id, was.name, was.n or 1) end
          end
        end
      end
    end
    read_hands(job.hands, first)
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
        -- (d25 batch210 QW1) entered: new on a lane after the first sample; where inserters pick, an item gone is
        -- looked for on what the tile feeds (passed on), and the hands are read (a sample begun before this has neither)
        local first, gone = job.samples == 1, nil
        for k = 1, 2 do
          local items = try(function() return e.get_transport_line(k).get_detailed_contents() end) or {}
          gone = read_lane(pt, k, items, first, gone)
        end
        -- (d27 batch269 BS) passed on: the items of each stack seen next
        if gone and pt.next then for id in pairs(find_ids(pt.next, gone)) do pt.passed_on = pt.passed_on + (gone[id].n or 1) end end
        if pt.hands then read_hands(pt.hands, first) end
      else pt.gone = true end
    end
    -- (d20 batch70 AF1) when it was last read, and whether a point is left to read (measures.lua: the idle count)
    local live = false
    for _, pt in ipairs(job.points) do if not pt.gone and (pt.unseen or 0) < job.samples then live = true; break end end
    job.sampled, job.all_gone = game.tick, not live or nil
  end
  -- (d27 batch269 BS) a lane's counts in items (a stack counts its count); stacks: the stacks that left whole
  local function lane_text(pt, k, minutes)
    local by, n, stacks = {}, 0, 0
    local counts = pt.left_n and pt.left_n[k] or {}
    for id, name in pairs(pt.left[k]) do
      local c = counts[id] or 1
      by[name] = (by[name] or 0) + c; n = n + c; stacks = stacks + 1
    end
    if pt.whole then stacks = pt.whole[k] end
    local names = {}
    for name, c in pairs(by) do names[#names+1] = name .. ' ' .. c end
    table.sort(names)
    local rate = math.floor(n / minutes * 10 + 0.5) / 10
    local stacks_rate = math.floor(stacks / minutes * 10 + 0.5) / 10
    local held = pt.count and pt.count[k] or 0
    local held_stacks = pt.stacks and pt.stacks[k] or held
    local most = pt.stack_max and pt.stack_max[k] or 1
    -- (d18 batch38 D3, Opus: a lane read "stopped, full" was coal, read as iron ore) what stands on the tile now, by name
    local on, on_names = {}, {}
    for _, it in pairs(pt.lanes[k] or {}) do if it.name then on[it.name] = (on[it.name] or 0) + (it.n or 1) end end
    for name, c in pairs(on) do on_names[#on_names+1] = {name=name, c=c} end
    table.sort(on_names, function(x, y) if x.c ~= y.c then return x.c > y.c end return x.name < y.name end)
    for i, x in ipairs(on_names) do on_names[i] = x.c .. ' ' .. x.name end
    local on_text = #on_names > 0 and table.concat(on_names, ', ') or nil
    if on_text and most > 1 then on_text = string.format('%s in %d stack%s', on_text, held_stacks, held_stacks == 1 and '' or 's') end
    local state
    if n > 0 then state = most > 1 and string.format('%g items/min (%g stacks/min, up to %d a stack)', rate, stacks_rate, most) or string.format('%g items/min', rate)
    elseif held == 0 then state = 'empty'
    elseif not pt.moved[k] then state = held_stacks >= FULL and string.format('stopped, full (%s on the tile)', on_text or held) or string.format('stopped (%s on the tile)', on_text or held)
    else state = '0 items/min' end
    return {rate=rate, passed=n, stacks_rate=stacks_rate, stacks=stacks, stack_max=most > 1 and most or nil, items=#names > 0 and table.concat(names, ', ') or nil,
      held=held, held_stacks=most > 1 and held_stacks or nil, on_tile=on_text, state=state}
  end
  local function count(t, counts) local n = 0; for id in pairs(t) do n = n + (counts and counts[id] or 1) end; return n end
  local function by_name(set, counted, counts)
    local by, names = {}, {}
    if counted then by = set else for id, name in pairs(set) do by[name] = (by[name] or 0) + (counts and counts[id] or 1) end end
    for name, c in pairs(by) do names[#names+1] = name .. ' ' .. c end
    table.sort(names)
    return #names > 0 and table.concat(names, ', ') or nil
  end
  local function finish_tile(job, minutes)
    local pt = job.points[1]
    local lanes, parts = {}, {}
    for k = 1, 2 do
      local l = lane_text(pt, k, minutes)
      local taken, after = count(pt.taken[k], pt.taken_n and pt.taken_n[k]), count(pt.after[k], pt.after_n and pt.after_n[k])
      l.left, l.passed_on, l.taken, l.not_seen_after, l.entered, l.held_max = l.passed, l.passed - taken - after, taken, after, pt.entered[k], pt.max[k]
      l.taken_items = by_name(pt.taken[k], false, pt.taken_n and pt.taken_n[k])
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
    -- (d25 batch210 QW1) through the tile: passed on + picked where inserters pick from it, else every item that left
    local through = #hands > 0 and lanes[1].passed_on + lanes[2].passed_on + picked or lanes[1].left + lanes[2].left
    local t = job.tile
    local where = string.format('tile %s %s #%d facing %s%s', at(t.position), t.name, t.unit_number, t.direction,
      t.half and ' (its ' .. t.half .. ' half\'s input lanes)' or t.underground and ' (underground ' .. t.underground .. ')' or '')
    local lines = {}
    if pt.unseen and pt.unseen >= job.samples then lines[1] = where .. ': out of sight (no radar coverage there): not sampled'
    else lines[1] = where .. ': ' .. parts[1] .. '; ' .. parts[2] end
    if pt.gone then lines[#lines+1] = 'the belt was removed while sampling' end
    local st = stacking(job, {{lane=lanes[1], where='the left lane'}, {lane=lanes[2], where='the right lane'}})
    if st.lanes then lines[#lines+1] = st.line end
    if #hands > 0 then
      local hp = {}
      for i, h in ipairs(hands) do hp[i] = string.format('%s picked %d (%g items/min%s)', h.inserter, h.picked, h.rate, h.items and ': ' .. h.items or '') end
      lines[#lines+1] = 'inserters picking from this tile (their hands read each sample): ' .. table.concat(hp, ', ')
    else lines[#lines+1] = 'no inserter picks from this tile' end
    if #hands > 0 then lines[#lines+1] = string.format('through the tile: %g items/min (%d seen next on %s + %d picked)', minutes_text(through), lanes[1].passed_on + lanes[2].passed_on, pt.next_text, picked) end
    pt.entity, pt.next = nil, nil
    for _, h in ipairs(job.hands) do h.entity = nil end
    return {done=true, exact_tile=true, surface=job.surface_name, seconds=math.floor((game.tick - job.start) / 6 + 0.5) / 10, samples=job.samples, every_ticks=job.every,
      tile=t, left=lanes[1], right=lanes[2], rate=lanes[1].rate + lanes[2].rate, stacks_rate=lanes[1].stacks_rate + lanes[2].stacks_rate, stacking=st, feeds=pt.next_text, inserters=hands, picked=picked, picked_rate=minutes_text(picked),
      through=through, through_rate=minutes_text(through),
      gone=pt.gone and 'the belt was removed while sampling' or nil,
      out_of_sight=pt.unseen and string.format('out of sight for %d of %d samples', pt.unseen, job.samples) or nil, lines=lines,
      note='this tile only, by item id (2.0.77 has no pass count on a transport line): an item seen on a lane and gone at a later sample left it (rate: items a minute that left; a stack on the belt is one id and counts its items, stacks_rate the stacks; part of a stack taken off the tile counts as taken); passed_on: seen on what the tile feeds at the next sample; taken: gone from mid-lane, so taken off this tile; not_seen_after: gone at the lane\'s end and not seen on what it feeds (taken there, or here at the end, before a sample saw it); entered: items that came onto the lane; a lane whose items did not move is stopped (full: 4 stacks on the tile); through: passed_on + picked where inserters pick from the tile, else left; every_ticks: at most the ticks between two items on a lane (8 transport belt, 4 fast, 2 express and turbo) and the half swing of an inserter picking from the tile; ' .. M.MISSES}
  end
  function M.finish(job)
    local minutes = math.max(1, game.tick - job.start) / 3600
    if job.exact then return finish_tile(job, minutes) end
    local rows, lines, by_index = {}, {}, {}
    local per_min = function(n) return math.floor(n / minutes * 10 + 0.5) / 10 end
    for _, pt in ipairs(job.points) do
      local L, R = lane_text(pt, 1, minutes), lane_text(pt, 2, minutes)
      if pt.entered then L.entered, R.entered = pt.entered[1], pt.entered[2] end
      local row = {kind=pt.kind, position=pt.entity.valid and pt.entity.position or nil, left=L, right=R, rate=L.rate + R.rate}
      if pt.kind == 'section' then row.from, row.to, row.tiles = pt.from, pt.to, pt.tiles else row.into = pt.into end
      -- (d27 batch269 BS) a lane's cap: stacks a minute, and items in stacks of the belt stack size
      if pt.cap then row.lane_cap = {stacks=pt.cap, items=pt.cap * (job.stack_size or 1)} end
      -- (d25 batch210 QW1) inserters picking from the tile: their hands' count, and the point's rate passed on + picked
      local takers
      if pt.hands and #pt.hands > 0 then
        local hands, picked, hp = {}, 0, {}
        for i, h in ipairs(pt.hands) do
          picked = picked + h.picked
          hands[i] = {inserter=h.text, picked=h.picked, rate=per_min(h.picked), items=by_name(h.items, true)}
          hp[i] = string.format('%s picked %d (%g items/min)', h.text, h.picked, hands[i].rate)
          h.entity = nil
        end
        row.inserters, row.picked, row.passed_on, row.lanes_rate = hands, picked, pt.passed_on, row.rate
        row.rate = per_min(pt.passed_on + picked)
        takers = string.format('; %g items/min through it: %d seen next on %s + %d picked by the inserters picking from it (%s)', row.rate, pt.passed_on, pt.next_text, picked, table.concat(hp, ', '))
      end
      if pt.gone then row.gone = 'the belt was removed while sampling' end
      if pt.unseen then
        row.out_of_sight = pt.unseen >= job.samples and 'out of sight (no radar coverage there): not sampled'
          or string.format('out of sight for %d of %d samples: counted over the rest', pt.unseen, job.samples)
      end
      rows[#rows+1] = row
      local where = pt.kind == 'section' and string.format('section %s to %s (%d tiles)', at(pt.from), at(pt.to), pt.tiles)
        or string.format('belt %s merging into %s', at(row.position or pt.into), at(pt.into))
      if pt.unseen and pt.unseen >= job.samples then lines[#lines+1] = where .. ': ' .. row.out_of_sight
      else lines[#lines+1] = string.format('%s: left lane %s%s; right lane %s%s%s%s', where, L.state, L.items and ' (' .. L.items .. ')' or '', R.state, R.items and ' (' .. R.items .. ')' or '',
        row.out_of_sight and ' (' .. row.out_of_sight .. ')' or '', takers or '') end
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
          if before_row then parts[#parts+1] = string.format('line %g items/min', before_row.rate); total = total + before_row.rate end
          for _, s in ipairs(sides) do parts[#parts+1] = string.format('belt %s %g items/min', at(s.position or s.into), s.rate); total = total + s.rate end
          merges[#merges+1] = string.format('merge at %s: %s in (%g items/min), %g items/min on after it', at(pt.from), table.concat(parts, ' + '), total, rows[i].rate)
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
    -- (d27 batch269 BS) a lane's cap is in stacks: 4 a tile however many items each holds
    local function at_cap(r, k, cap) local l = k == 1 and r.left or r.right; return cap and cap > 0 and (l.stacks_rate or l.rate) >= 0.9 * cap end
    local function stopped_full(l) return l.state:find('stopped, full', 1, true) ~= nil end
    for j, q in ipairs(job.points) do
      if not limit and q.kind == 'side' and (stopped_full(rows[j].left) or stopped_full(rows[j].right)) then
        for k2, q2 in ipairs(job.points) do
          if q2.kind == 'section' and q2.index - q2.tiles + 1 == q.index then
            local lane = (q.into_type ~= 'splitter' and ((q.line_dir or 0) + 4) % 16 == (q.dir or 0)) and 1 or 2
            if at_cap(rows[k2], lane, q2.cap) or at_cap(rows[k2], 1, q2.cap) or at_cap(rows[k2], 2, q2.cap) then
              local held = stopped_full(rows[j].left) and rows[j].left.on_tile or rows[j].right.on_tile
              limit = string.format('a side-load waits at %s: belt %s is stopped full%s while the line after it runs at its cap (%g stacks/min a lane): the line\'s own items go first',
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
              local l = k == 1 and rows[j].left or rows[j].right
              limit = string.format('the %s lane runs at its cap in section %s to %s (%s): the belt carries no more on it', k == 1 and 'left' or 'right',
                at(q.from), at(q.to), l.stack_max and string.format('%g stacks/min of %g, %g items/min in stacks of up to %d', l.stacks_rate, q.cap, l.rate, l.stack_max)
                  or string.format('%g items/min of %g/min', l.rate, q.cap))
            end
          end
        end
      end
    end
    if limit then lines[#lines+1] = 'limit: ' .. limit end
    local seen = {}
    for j, r in ipairs(rows) do
      local where = job.points[j].kind == 'section' and 'section end ' .. at(job.points[j].to) or 'belt ' .. at(r.position or job.points[j].into)
      seen[#seen+1] = {lane=r.left, where=where .. ' left lane'}; seen[#seen+1] = {lane=r.right, where=where .. ' right lane'}
    end
    local st = stacking(job, seen)
    if st.lanes then lines[#lines+1] = st.line end
    for _, pt in ipairs(job.points) do pt.entity, pt.next = nil, nil end
    if job.walk_stops then lines[#lines+1] = 'the line goes on uncharted (' .. table.concat(job.walk_stops, ', ') .. '): not walked' end
    return {done=true, surface=job.surface_name, seconds=math.floor((game.tick - job.start) / 6 + 0.5) / 10, samples=job.samples, every_ticks=job.every, tiles=job.tiles,
      from=job.path_from, to=job.path_to, points=rows, merges=#merges > 0 and merges or nil, lane_mix=#mix > 0 and mix or nil, limit=limit, stacking=st, lines=lines,
      note='an item counts once it leaves the tile sampled; every count and rate is items (a stack on the belt is one id and counts its items; stacks_rate: the stacks a minute; part of a stack taken off the tile counts as left); a lane whose items did not move over the window is stopped (full: 4 stacks on the tile); a lane\'s cap is in stacks (lane_cap: speed x 4 a tile x 3600 stacks a minute, items in stacks of the belt stack size); every_ticks: half the ticks an item takes to cross a tile on the fastest belt sampled (an item that crosses a sampled tile is seen there), and where an inserter picks from a sampled tile at most the ticks between two items on a lane (8 transport belt, 4 fast, 2 express and turbo) and its half swing; ' .. M.MISSES}
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
  -- (d25 batch210 QW1) what each count can miss, in every result's note
  M.MISSES = 'a lane\'s rate (left) misses an item taken off the tile before a sample sees it there (an inserter can take one in the tick it comes on: at the end of a turbo belt, 202 of 396 picks were never on the tile at any tick); '
    .. 'picked (the hands of the inserters whose pickup point is on the tile, read each sample) counts those, and misses what anything else takes (a character, a loader); '
    .. 'passed_on (gone from the tile and seen next on what it feeds) misses an item taken there before a sample sees it; entered misses what is taken before a sample sees it; '
    .. 'a point with inserters picking from it has rate passed_on + picked'
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
    exact_tile='optional true: the belt at position only (no line walked): its two lanes (a splitter: the half position is in, its input lanes; an underground: the tile\'s own lanes), each lane\'s items that left the tile by item id: seen on what the tile feeds after (passed_on), gone from mid-lane (taken), or gone at the lane\'s end and not seen on what it feeds (not_seen_after); entered, held, the rate; and the inserters picking from the tile, counted from their hands. Returns tile {name, type, position, unit_number, direction, half, underground}, left, right {rate, stacks_rate, left, stacks, passed_on, taken, not_seen_after, taken_items, entered, items, held, held_stacks, held_max, stack_max, on_tile, state} (items: a stack on the belt counts its items; an inserter can take part of a stack, which stays with fewer: taken), rate, stacks_rate, stacking {belt_stack_size, largest, lanes, line}, feeds, inserters [{inserter, picked, rate, items}], picked, picked_rate, through, through_rate (passed_on + picked where inserters pick from the tile, else left), lines',
    surface='optional planet, surface or platform name (default yours): the belt there by remote view (d20 batch62 X4): the start tile in a chunk our force sees now (radar coverage); the line is walked where the map is charted, and a point out of sight is not sampled (said per point: out_of_sight)',
    returns='the belt line through position (up to 64 tiles back and 64 on; undergrounds followed; cut into sections at each merge: a side-load or a splitter), its sections\' last tiles and each belt merging in sampled for seconds by item: points [{kind (section, side), from, to, tiles, into, left, right {rate (items a minute that left the tile: a stack on the belt counts its items), stacks_rate (stacks a minute), passed, stacks, entered, items (by name), held (items on the tile now), held_stacks, stack_max (the largest stack seen, when over 1), state (N items/min, with stacks/min where stacks were seen, empty, stopped (full: 4 stacks on the tile), with what stands on the tile by name), on_tile}, rate, lane_cap (sections: {stacks, items}: a lane moves speed x 4 x 3600 stacks a minute, items at the belt stack size), and where inserters pick from the tile: inserters [{inserter, picked, rate, items}] (counted from their hands each sample), picked, passed_on (seen next on what it feeds), lanes_rate (left + right), rate then passed_on + picked a minute}], merges (across each: the line before it and each belt merging in, against the line after it), lane_mix (each merge: a side-load from which side of the line, the lane both its lanes go onto, or a splitter or end-on join lane to lane; what each lane carries after it), limit (what limits the line: a side-load stopped full while the line after it runs at its cap, the straight line\'s items going first; the end backed up, both lanes or one stopped full; else a lane at its cap, stacks a minute against speed x 4 a tile x 3600), stacking {belt_stack_size (1 + the force\'s belt stack bonus: a stack inserter or a big mining drill puts stacks of that size on a belt, other inserters and drills one item), largest, lanes (where stacks were seen), line}, lines, samples, every_ticks (half the ticks an item takes to cross a tile; where an inserter picks from a sampled tile at most the ticks between two items and its half swing), note (what each count can miss). The call returns when the sampling ends; belt_flow {} reads the last result (or the seconds left). The sample ends at until_tick: stop and your actions do not end it (a new belt_flow {position} replaces it); fh wait waits for it when nothing else runs (ends says so). Read only'}}
  return M
end
