-- avoid: walks and drives that keep clear of the enemy worms and spawners the
-- map shows. Opus (shift09 03:20): "my third death was the pathfinder walking
-- me 30 tiles from a nest"; on a private copy of world n the engine's path
-- from (-110,447) to (62,40) passes 31 tiles from a biter spawner at (81,154)
-- and 41 from big worms (range 38). The engine pathfinder takes no area to
-- avoid, so a found path is checked: each worm and spawner on charted chunks
-- near it is a disc (a worm's attack range, a spawner's units' sight, plus a
-- margin), structures within 32 tiles of each other are one nest (for its
-- name and the start/goal rule), and a path through a disc becomes legs
-- around it: corners of octagons around the discs, the shortest way along
-- them (a visibility graph), each leg walked with the engine's path and
-- checked again.
-- Default (avoid_enemies not given): worms, range + 4; spawners, 40 tiles +
-- 4 (round1950a, Haiku died twice near nests: a tree 38 tiles from one, a
-- rearm tour past another); and the areas under attack now (an incident hit
-- within the last 30 s, threat.lua), 24 tiles round its first hit + 4.
-- avoid_enemies: true (or a margin in tiles): the same with + 8 (or the
-- margin). false: no check. A disc holding the start or the goal is not
-- avoided (the walk goes there): it is named.
-- Cost: the worms and spawners are read per chunk (charted chunks: what the
-- map draws) and kept a minute; at most CHUNKS_PER_TICK chunks a tick, while
-- the walk waits for its path.
return function(api)
  local M = {}
  M.WORM_PAD, M.PAD, M.TTL, M.CHUNKS_PER_TICK, M.MAX_DETOURS, M.NEST = 4, 8, 3600, 8, 4, 32
  -- round1950a: how far a spawner's units come for a character (at least), an attack's zone round its first hit, and
  -- how long after its last hit an attack counts as under way.
  -- (30 s: every enemy hit is an incident, and a lone biter shot at a wall should not keep walks off the base's edge
  -- for long; on a copy of world n one turret hit sent a walk through the base to no_safe_route)
  M.SPAWNER_REACH, M.ATTACK_R, M.ATTACK_ACTIVE = 40, 24, 1800
  M.SIDES = 8
  local function dist(a, b) return ((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2) ^ 0.5 end
  local function at(pos) return string.format('(%g,%g)', math.floor(pos.x + 0.5), math.floor(pos.y + 0.5)) end
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  -- Distance from a point to the segment a-b.
  local function seg_dist(a, b, q)
    local dx, dy = b.x - a.x, b.y - a.y
    local L = dx * dx + dy * dy
    local t = L > 0 and ((q.x - a.x) * dx + (q.y - a.y) * dy) / L or 0
    t = math.max(0, math.min(1, t))
    return ((a.x + t * dx - q.x) ^ 2 + (a.y + t * dy - q.y) ^ 2) ^ 0.5
  end
  M.seg_dist = seg_dist

  -- What avoid_enemies asks for: nil (default: worms, +4), false (nothing),
  -- true (worms and spawners, +8), a number (worms and spawners, + it).
  function M.mode(v)
    if v == false then return nil end
    if v == nil then return {spawners=true, attacks=true, pad=M.WORM_PAD} end
    if v == true then return {spawners=true, attacks=true, pad=M.PAD} end
    -- {distance: N} (Opus, d15 07:50: avoid_enemies false walked him through a nest, death 32; the default kept him off
    -- outposts): every worm and spawner the map shows is avoided by N tiles from the structure, its own reach not
    -- counted (a worm's range can be more than N); areas under attack now as by default.
    if type(v) == 'table' then
      local n = v.distance
      assert(type(n) == 'number' and n >= 4 and n <= 64 and next(v, next(v)) == nil,
        'avoid_enemies {distance: N}: N 4..64 tiles kept from every worm and spawner the map shows (their reach not counted)')
      return {spawners=true, attacks=true, pad=0, distance=n}
    end
    assert(type(v) == 'number' and v >= 0 and v <= 32, 'avoid_enemies must be true, false, a margin 0..32 tiles or {distance: N}')
    return {spawners=true, attacks=true, pad=v, strict=true}
  end
  function M.describe(mode)
    if not mode then return nil end
    if mode.distance then
      return string.format('worms and spawners (%g tiles from each; their reach not counted) and areas under attack now (%d tiles)', mode.distance, M.ATTACK_R)
    end
    if not mode.attacks then return string.format('worms (range + %g) and spawners (%d tiles + %g)', mode.pad, M.SPAWNER_REACH, mode.pad) end
    return string.format('worms (range + %g), spawners (%d tiles + %g) and areas under attack now (%d tiles + %g)', mode.pad, M.SPAWNER_REACH, mode.pad,
      M.ATTACK_R, mode.pad)
  end

  -- A worm's attack range; a spawner's reach: the farthest sight among the units it makes.
  local reach_of = {}
  function M.reach(name, spawner)
    local r = reach_of[name]
    if r then return r end
    local proto = try(function() return prototypes.entity[name] end)
    if spawner then
      r = 0
      for _, u in pairs(try(function() return proto.result_units end) or {}) do
        local up = try(function() return prototypes.entity[u.unit or u[1]] end)
        r = math.max(r, try(function() return up.vision_distance end) or 0)
      end
      if r == 0 then r = 30 end
    else
      r = try(function() return proto.turret_range or proto.attack_parameters.range end) or 30
    end
    reach_of[name] = r
    return r
  end
  -- The farthest a disc can reach: behemoth worms 48, spawners 40 (M.SPAWNER_REACH).
  local function max_reach(mode) return (mode.distance and math.max(mode.distance, 24) or 48) + mode.pad end
  -- The areas under attack now on a surface (threat.lua's incidents, hit within M.ATTACK_ACTIVE), as discs within the
  -- box {x0, y0, x1, y1} (nil: all of them): {x, y, r, range, name ('attack #ID'), attack=true, id, ago (s), size}.
  function M.attack_discs(surface, mode, box)
    local out = {}
    if not (mode and mode.attacks) then return out end
    local areas = api.state().damage or {}
    local name = surface.name
    for _, a in pairs(areas) do
      if a.id and a.at and a.last and game.tick - a.last <= M.ATTACK_ACTIVE and (a.surface == nil or a.surface == name) then
        local x, y = a.at.x, a.at.y
        local r = M.ATTACK_R + mode.pad
        if not box or (x + r >= box[1] and x - r <= box[3] and y + r >= box[2] and y - r <= box[4]) then
          out[#out+1] = {x=x, y=y, r=r, range=M.ATTACK_R, name='attack #' .. a.id, attack=true, id=a.id,
            ago=math.floor((game.tick - a.last) / 60), size=a.size}
        end
      end
    end
    -- Enemy groups on the move that our force sees now (Opus, twice: died on corridors walked safely minutes before,
    -- each time into an attack group crossing the route): each group in a chunk a player force sees now, as a disc
    -- where it is and one ahead of it toward its target (GROUP_AHEAD tiles at most); named by where it is, so a walk
    -- plans again as it moves on.
    for _, g in ipairs(api.state().live_groups or {}) do
      local grp = g.group
      local pos = grp and try(function() return grp.valid and grp.position end)
      if pos and (g.surface == nil or g.surface == name) and M.seen_now(surface, pos) then
        local n = try(function() return #grp.members end) or 0
        if n > 0 then
          local r = M.ATTACK_R + mode.pad
          local label = string.format('enemy group of %d%s', n, g.target and string.format(' heading for (%d,%d)', g.target.x, g.target.y) or '')
          local key = 'g' .. g.id .. '@' .. math.floor(pos.x / 32) .. ',' .. math.floor(pos.y / 32)
          local spots = {{x=pos.x, y=pos.y}}
          if g.target then
            local dx, dy = g.target.x - pos.x, g.target.y - pos.y
            local len = math.sqrt(dx * dx + dy * dy)
            if len > 1 then local s = math.min(len, M.GROUP_AHEAD) / len; spots[2] = {x=pos.x + dx * s, y=pos.y + dy * s} end
            -- where it heads, when near (A1, Opus 00:17: his goal was the group's target)
            if len > M.GROUP_AHEAD and len <= M.GROUP_TARGET then spots[3] = {x=g.target.x, y=g.target.y} end
          end
          for k, q in ipairs(spots) do
            if not box or (q.x + r >= box[1] and q.x - r <= box[3] and q.y + r >= box[2] and q.y - r <= box[4]) then
              out[#out+1] = {x=q.x, y=q.y, r=r, range=M.ATTACK_R, name=label .. (k == 2 and ' (ahead of it)' or k == 3 and ' (where it heads)' or ''), attack=true, group=true,
                id=key .. '#' .. k, ago=0, size=n}
            end
          end
        end
      end
    end
    -- Enemy units our force sees now near the way (d17 batch12 A2, Opus: died to big biters roaming off a nest on a
    -- route the check called safe; units outside a group were not counted): with a box, every unit in a chunk a
    -- player force sees now, in 16-tile cells, each cell a disc of ATTACK_R + the margin round its units' middle, named
    -- by how many and what; keyed by where they are, so a walk plans again as they move. Bounded: MAX_UNITS.
    if box then
      local list = try(function() return surface.find_entities_filtered{area={{box[1] - M.ATTACK_R, box[2] - M.ATTACK_R}, {box[3] + M.ATTACK_R, box[4] + M.ATTACK_R}},
        type='unit', force='enemy', limit=M.MAX_UNITS} end) or {}
      local seen, cells, order = {}, {}, {}
      for _, u in ipairs(list) do
        local q = u.valid and u.type == 'unit' and u.position
        if q then
          local ck = math.floor(q.x / 32) .. ',' .. math.floor(q.y / 32)
          if seen[ck] == nil then seen[ck] = try(function() return M.seen_now(surface, q) end) or false end
          if seen[ck] then
            local k = math.floor(q.x / 16) .. ',' .. math.floor(q.y / 16)
            local c = cells[k]
            if not c then c = {n=0, sx=0, sy=0, kinds={}, k=k}; cells[k] = c; order[#order+1] = c end
            c.n = c.n + 1; c.sx = c.sx + q.x; c.sy = c.sy + q.y
            c.kinds[u.name] = (c.kinds[u.name] or 0) + 1
          end
        end
      end
      for _, c in ipairs(order) do
        local parts = {}
        for name, n in pairs(c.kinds) do parts[#parts+1] = n .. ' ' .. name end
        table.sort(parts)
        out[#out+1] = {x=c.sx / c.n, y=c.sy / c.n, r=M.ATTACK_R + mode.pad, range=M.ATTACK_R,
          name=string.format('%d enemy unit%s (%s)', c.n, c.n == 1 and '' or 's', table.concat(parts, ', ')),
          attack=true, units=true, id='u' .. c.k, ago=0, size=c.n}
      end
      -- Demolishers near the way, head and whole body (d17 batch18 C5, viewer Foobator: the walk checks found the head
      -- only): their segment entities in a chunk our force sees now, per demolisher in DEMO_CELL-tile cells, each cell a
      -- disc of ATTACK_R + the margin round its segments' middle, widened by the farthest segment from it, so every
      -- segment keeps the margin. Only the area round the way is read.
      local segs = try(function() return surface.find_entities_filtered{area={{box[1] - M.ATTACK_R, box[2] - M.ATTACK_R}, {box[3] + M.ATTACK_R, box[4] + M.ATTACK_R}},
        type={'segmented-unit', 'segment'}, force='enemy', limit=M.MAX_SEGMENTS} end) or {}
      local dcells, dorder = {}, {}
      for _, e in ipairs(segs) do
        local q = e.valid and e.position
        if q then
          local ck = math.floor(q.x / 32) .. ',' .. math.floor(q.y / 32)
          if seen[ck] == nil then seen[ck] = try(function() return M.seen_now(surface, q) end) or false end
          if seen[ck] then
            local unit = try(function() return e.segmented_unit end)
            local uid = unit and try(function() return unit.unit_number end) or 0
            local k = uid .. '@' .. math.floor(q.x / M.DEMO_CELL) .. ',' .. math.floor(q.y / M.DEMO_CELL)
            local c = dcells[k]
            if not c then
              c = {n=0, sx=0, sy=0, pts={}, k=k, head=false, name=unit and try(function() return unit.prototype.name end) or e.name}
              dcells[k] = c; dorder[#dorder+1] = c
            end
            c.n = c.n + 1; c.sx = c.sx + q.x; c.sy = c.sy + q.y; c.pts[#c.pts+1] = q
            if e.type == 'segmented-unit' then c.head = true end
          end
        end
      end
      for _, c in ipairs(dorder) do
        local mx, my, far = c.sx / c.n, c.sy / c.n, 0
        for _, q in ipairs(c.pts) do far = math.max(far, dist({x=mx, y=my}, q)) end
        out[#out+1] = {x=mx, y=my, r=M.ATTACK_R + mode.pad + far, range=M.ATTACK_R,
          name=string.format('%s %s (%d segment%s)', c.name, c.head and 'head' or 'body', c.n, c.n == 1 and '' or 's'),
          attack=true, units=true, demolisher=true, id='d' .. c.k, ago=0, size=c.n}
      end
    end
    return out
  end
  M.GROUP_AHEAD, M.GROUP_TARGET, M.MAX_UNITS, M.UNIT_REPLANS = 48, 160, 400, 8
  M.DEMO_CELL, M.MAX_SEGMENTS = 8, 1024
  -- A point inside an enemy group's disc (where it is, ahead of it, where it heads), groups seen now.
  function M.in_group_way(surface, q)
    for _, d in ipairs(M.attack_discs(surface, {attacks=true, pad=0})) do
      if d.group and dist(d, q) < d.r then return d end
    end
    return nil
  end
  -- A chunk a player force sees now (radar or a character).
  function M.seen_now(surface, pos)
    for _, force in pairs(game.forces) do
      if force.name ~= 'enemy' and force.name ~= 'neutral' and #force.players > 0
        and try(function() return force.is_chunk_visible(surface, {x=math.floor(pos.x / 32), y=math.floor(pos.y / 32)}) end) then return true end
    end
    return false
  end

  -- Enemy groups on the move toward places just served (d17 batch18 C3, Opus: after a feed, rearm or refuel walk): each
  -- group in a chunk our force sees now whose target lies within TOWARD_NEAR tiles of a served place, or within
  -- TOWARD_FAR tiles of one and closer to it than the group is; its size, where it is, how far from the nearest such
  -- place, the compass way to its target and the target. Up to 4 lines, nearest first.
  local TOWARD_NEAR, TOWARD_FAR = 48, 256
  local COMPASS = {'east', 'southeast', 'south', 'southwest', 'west', 'northwest', 'north', 'northeast'}
  local function compass(dx, dy)
    local a = (math.atan2 or math.atan)(dy, dx)
    return COMPASS[(math.floor(a / (math.pi / 4) + 0.5) % 8) + 1]
  end
  function M.groups_toward(surface, places)
    if not surface or #places == 0 then return nil end
    local name = surface.name
    local function d(a, b) return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2) end
    local rows = {}
    for _, g in ipairs(api.state().live_groups or {}) do
      local grp = g.group
      local pos = grp and try(function() return grp.valid and grp.position end)
      local n = pos and (try(function() return #grp.members end) or 0) or 0
      if pos and n > 0 and g.target and (g.surface == nil or g.surface == name) and M.seen_now(surface, pos) then
        local best, bd
        for _, pl in ipairs(places) do
          local dt, dg = d(g.target, pl.position), d(pos, pl.position)
          if dt <= TOWARD_NEAR or (dg <= TOWARD_FAR and dt < dg) then
            if not bd or dg < bd then best, bd = pl, dg end
          end
        end
        if best then
          rows[#rows+1] = {d=bd, text=string.format('enemy group of %d%s at (%d,%d), %d tiles from %s (%g,%g), heading %s for (%d,%d), %d tiles from it',
            n, g.first_kinds and ' (' .. g.first_kinds .. ')' or '', math.floor(pos.x), math.floor(pos.y), math.floor(bd + 0.5), best.name,
            best.position.x, best.position.y, compass(g.target.x - pos.x, g.target.y - pos.y), g.target.x, g.target.y,
            math.floor(d(g.target, best.position) + 0.5))}
        end
      end
    end
    if #rows == 0 then return nil end
    table.sort(rows, function(x, y) return x.d < y.d end)
    local out = {}
    for i = 1, math.min(4, #rows) do out[i] = rows[i].text end
    if #rows > 4 then out[#out+1] = string.format('+%d more groups', #rows - 4) end
    return out
  end

  -- Hostile forces: neither ours, neutral, friends nor at cease-fire.
  local function hostile(force)
    local out = {}
    for _, f in pairs(game.forces) do
      if f ~= force and f.name ~= 'neutral' and not try(function() return force.get_friend(f) or force.get_cease_fire(f) end) then out[#out+1] = f.name end
    end
    return out
  end
  local function ckey(cx, cy) return (cx + 524288) * 1048576 + (cy + 524288) end
  local function cache(surface)
    local st = api.state()
    st.enemy_chunks = st.enemy_chunks or {}
    local c = st.enemy_chunks[surface.index]
    if not c then c = {}; st.enemy_chunks[surface.index] = c end
    return c
  end
  -- One chunk's worms and spawners: those drawn on a charted chunk.
  function M.read_chunk(surface, force, cx, cy)
    local rec = {t=game.tick}
    if not api.charted(force, surface, {x=cx, y=cy}) then rec.uncharted = true; return rec end
    local forces = hostile(force)
    if #forces == 0 then return rec end
    local named = {}
    for _, n in ipairs(forces) do named[n] = true end
    local x0, y0 = cx * 32, cy * 32
    for _, e in pairs(surface.find_entities_filtered{area={{x0, y0}, {x0 + 32, y0 + 32}}, type={'turret', 'unit-spawner'}, force=forces} or {}) do
      local pos = e.position
      if (e.type == 'turret' or e.type == 'unit-spawner') and e.force and named[e.force.name]
        and pos.x >= x0 and pos.x < x0 + 32 and pos.y >= y0 and pos.y < y0 + 32 then
        rec.list = rec.list or {}
        rec.list[#rec.list+1] = {x=pos.x, y=pos.y, name=e.name, spawner=e.type == 'unit-spawner' or nil}
      end
    end
    return rec
  end
  -- Chunks within reach of a line through the points, nearest the first point
  -- first: the line in stretches of 16 tiles (an engine path has a point every
  -- tile or two), each stretch's box widened by R.
  function M.chunks_near(points, R)
    local seen, list = {}, {}
    local function add(x0, y0, x1, y1)
      for cx = math.floor((x0 - R) / 32), math.floor((x1 + R) / 32) do
        for cy = math.floor((y0 - R) / 32), math.floor((y1 + R) / 32) do
          local k = ckey(cx, cy)
          if not seen[k] then seen[k] = true; list[#list+1] = {cx, cy, k} end
        end
      end
    end
    local x0, y0, x1, y1, run, prev
    local function take(q)
      if not x0 then x0, y0, x1, y1, run = q.x, q.y, q.x, q.y, 0
      else
        run = run + dist(prev, q)
        x0, y0, x1, y1 = math.min(x0, q.x), math.min(y0, q.y), math.max(x1, q.x), math.max(y1, q.y)
        if run >= 16 then add(x0, y0, x1, y1); x0, y0, x1, y1, run = q.x, q.y, q.x, q.y, 0 end
      end
      prev = q
    end
    for i, q in ipairs(points) do
      if prev and i > 1 then
        local a = points[i - 1]
        local n = math.floor(dist(a, q) / 16)
        for k = 1, n do take({x=a.x + (q.x - a.x) * k / (n + 1), y=a.y + (q.y - a.y) * k / (n + 1)}) end
      end
      take(q)
    end
    if x0 then add(x0, y0, x1, y1) end
    return list
  end
  -- The chunks of a list not read in the last TTL ticks.
  function M.missing(surface, chunks)
    local c = cache(surface)
    local out = {}
    for _, ch in ipairs(chunks) do
      local rec = c[ch[3]]
      if not rec or game.tick - rec.t > M.TTL then out[#out+1] = ch end
    end
    return out
  end
  -- Read up to budget chunks of a pending list; true when none is left.
  function M.scan(surface, force, pending, budget)
    local c = cache(surface)
    local n = 0
    while #pending > 0 and n < budget do
      local ch = table.remove(pending, 1)
      local rec = c[ch[3]]
      if not rec or game.tick - rec.t > M.TTL then
        c[ch[3]] = M.read_chunk(surface, force, ch[1], ch[2]); n = n + 1
      end
    end
    return #pending == 0
  end
  -- The worms and spawners of a list of chunks (danger.lua): read those not read in the last TTL, at most budget, and
  -- return {list (each {x, y, name, spawner?}), uncharted (chunks), unread (chunks over the budget)}.
  function M.structures(surface, force, chunks, budget)
    local pending = M.missing(surface, chunks)
    local over = math.max(0, #pending - budget)
    M.scan(surface, force, pending, budget)
    local c, out, uncharted = cache(surface), {}, 0
    for _, ch in ipairs(chunks) do
      local rec = c[ch[3]]
      if rec and rec.uncharted then uncharted = uncharted + 1 end
      for _, s in ipairs(rec and rec.list or {}) do out[#out+1] = s end
    end
    return {list=out, uncharted=uncharted, unread=over}
  end
  -- Old records go: at most one sweep of the cache per TTL.
  function M.prune()
    local st = api.state()
    if not st.enemy_chunks or game.tick - (st.enemy_pruned or 0) < M.TTL then return end
    st.enemy_pruned = game.tick
    for _, c in pairs(st.enemy_chunks) do
      for k, rec in pairs(c) do if game.tick - rec.t > M.TTL then c[k] = nil end end
    end
  end

  -- The discs of the read chunks, one nest (structures within NEST tiles of
  -- each other) one disc: its centre the middle of their box, its radius
  -- reaching past every member's own disc.
  -- A via point clear of the nest that blocks the straight way (C7, Muse 12:20: no_safe_route gave no detour): the
  -- first group of worms and spawners the line from a to b crosses, as the map shows them, and a point beside it on
  -- either side, outside every weapon's reach plus the margin, on charted ground; the nearer to the line's two ends.
  function M.via_round(p, a, b, mode)
    if not mode then return nil end
    local blobs = M.blobs(p.surface, M.chunks_near({a, b}, 48), mode)
    local dx, dy = b.x - a.x, b.y - a.y
    local L = (dx * dx + dy * dy) ^ 0.5
    if L < 1 then return nil end
    local ux, uy = dx / L, dy / L
    local best
    for _, bl in ipairs(blobs) do
      for _, d in ipairs(bl.members) do
        local t = (d.x - a.x) * ux + (d.y - a.y) * uy
        local off = math.abs((d.x - a.x) * uy - (d.y - a.y) * ux)
        if t > 0 and t < L and off < d.r and (not best or t < best.t) then best = {t=t, blob=bl} end
      end
    end
    if not best then return nil end
    local m = best.blob.members
    local cx, cy = 0, 0
    for _, d in ipairs(m) do cx, cy = cx + d.x, cy + d.y end
    cx, cy = cx / #m, cy / #m
    local R = 0
    for _, d in ipairs(m) do R = math.max(R, dist({x=cx, y=cy}, d) + d.r) end
    local function inside(q)
      for _, bl in ipairs(blobs) do for _, d in ipairs(bl.members) do if dist(q, d) < d.r then return d end end end
    end
    local first = m[1]
    local options = {}
    for _, side in ipairs({1, -1}) do
      for _, extra in ipairs({6, 16, 32}) do
        local q = {x=math.floor(cx - uy * side * (R + extra)) + 0.5, y=math.floor(cy + ux * side * (R + extra)) + 0.5}
        local charted = p.force.is_chunk_charted(p.surface, {x=math.floor(q.x / 32), y=math.floor(q.y / 32)})
        if charted and not inside(q) then options[#options+1] = {q=q, len=dist(a, q) + dist(q, b)}; break end
      end
    end
    table.sort(options, function(u, v) return u.len < v.len end)
    local o = options[1]
    if not o then return {text=string.format('no charted point within %d tiles beside the %d worms and spawners round (%d,%d) is clear of them', math.floor(R + 32), #m, math.floor(cx), math.floor(cy))} end
    return {via=o.q, text=string.format('via (%g,%g) passes beside the %d worms and spawners round (%d,%d) (%s first, reach %g with the margin), %.0f tiles in all: move_to {position, via: [{x: %g, y: %g}]}',
      o.q.x, o.q.y, #m, math.floor(cx), math.floor(cy), first.name or 'an attack', first.r, o.len, o.q.x, o.q.y)}
  end
  function M.blobs(surface, chunks, mode)
    local c = cache(surface)
    local discs, done = {}, {}
    for _, ch in ipairs(chunks) do
      local rec = not done[ch[3]] and c[ch[3]]
      done[ch[3]] = true
      for _, e in ipairs(rec and rec.list or {}) do
        if mode.spawners or not e.spawner then
          local range = M.reach(e.name, e.spawner)
          if e.spawner then range = math.max(range, M.SPAWNER_REACH) end
          if mode.distance then range = mode.distance end
          discs[#discs+1] = {x=e.x, y=e.y, r=range + mode.pad, range=range, name=e.name, spawner=e.spawner}
        end
      end
    end
    -- The areas under attack now near those chunks (round1950a).
    if mode.attacks and #chunks > 0 then
      local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
      for _, ch in ipairs(chunks) do
        x0, y0 = math.min(x0, ch[1] * 32), math.min(y0, ch[2] * 32)
        x1, y1 = math.max(x1, ch[1] * 32 + 32), math.max(y1, ch[2] * 32 + 32)
      end
      for _, d in ipairs(M.attack_discs(surface, mode, {x0, y0, x1, y1})) do discs[#discs+1] = d end
    end
    -- Single-link groups.
    local group, blobs = {}, {}
    for i, d in ipairs(discs) do
      if not group[i] then
        local b = {members={d}}
        blobs[#blobs+1] = b; group[i] = b
        local k = 1
        while k <= #b.members do
          local m = b.members[k]
          for j, o in ipairs(discs) do
            if not group[j] and dist(m, o) <= M.NEST then group[j] = b; b.members[#b.members+1] = o end
          end
          k = k + 1
        end
      end
    end
    for _, b in ipairs(blobs) do
      local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
      for _, m in ipairs(b.members) do x0, y0, x1, y1 = math.min(x0, m.x), math.min(y0, m.y), math.max(x1, m.x), math.max(y1, m.y) end
      b.x, b.y = (x0 + x1) / 2, (y0 + y1) / 2
      local r = 0
      for _, m in ipairs(b.members) do r = math.max(r, dist(b, m) + m.r) end
      b.r = r
    end
    return blobs
  end
  -- "3 big-worm-turret, 2 biter-spawner around (83,163)". structures: the worms and spawners alone, round their own
  -- middle (recover dry_run's nests; an area under attack beside them is said apart).
  function M.name(b, structures)
    local counts, names = {}, {}
    local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
    for _, m in ipairs(b.members) do
      if not (structures and m.attack) then
        if not counts[m.name] then names[#names+1] = m.name end
        counts[m.name] = (counts[m.name] or 0) + 1
        x0, y0, x1, y1 = math.min(x0, m.x), math.min(y0, m.y), math.max(x1, m.x), math.max(y1, m.y)
      end
    end
    if #names == 0 then return nil end
    table.sort(names)
    local parts = {}
    for i, n in ipairs(names) do parts[i] = counts[n] .. ' ' .. n end
    return table.concat(parts, ', ') .. ' around ' .. at(structures and {x=(x0 + x1) / 2, y=(y0 + y1) / 2} or b)
  end
  -- Whether the polyline passes through a member's reach (the blob is only
  -- the outline): the deepest pass (nearest to the weapon's own range) over
  -- the whole line, its blob, member and distance.
  function M.crossing(points, blobs, skip)
    local best, bb, bm, bd
    for i = 1, #points - 1 do
      local a, b = points[i], points[i + 1]
      for bi, bl in ipairs(blobs) do
        if not skip[bi] and seg_dist(a, b, bl) < bl.r then
          for _, m in ipairs(bl.members) do
            local d = seg_dist(a, b, m)
            if d < m.r and (not best or d - m.range < best) then best, bb, bm, bd = d - m.range, bi, m, d end
          end
        end
      end
    end
    return bb, bm, bd
  end

  -- The shortest way from a to b clear of every worm's and spawner's own disc
  -- (a nest's outline would hold goals that lie between its members' reach):
  -- the corners of a SIDES-gon around each disc (its sides stay outside the
  -- disc, plus a tile) that lie in no other disc, A* along straight lines clear
  -- of every disc. Blobs in skip are left out. Returns the corners to walk
  -- through (b last), {} when a-b is clear, nil when there is no way.
  local function clear(a, b, discs)
    local dx, dy = b.x-a.x, b.y-a.y
    local length = dx*dx + dy*dy
    local x0, x1, y0, y1 = math.min(a.x,b.x), math.max(a.x,b.x), math.min(a.y,b.y), math.max(a.y,b.y)
    for _, o in ipairs(discs) do
      local r = o.r - 0.01
      if o.x+r > x0 and o.x-r < x1 and o.y+r > y0 and o.y-r < y1 then
        local t = length > 0 and math.max(0,math.min(1,((o.x-a.x)*dx+(o.y-a.y)*dy)/length)) or 0
        local x, y = a.x+t*dx-o.x, a.y+t*dy-o.y
        if x*x+y*y < r*r then return false end
      end
    end
    return true
  end
  function M.detour(a, b, blobs, skip)
    local discs = {}
    for bi, bl in ipairs(blobs) do
      if not skip[bi] then for _, m in ipairs(bl.members) do discs[#discs+1] = m end end
    end
    if clear(a, b, discs) then return {} end
    local nodes = {}
    for di, o in ipairs(discs) do
      local rr = o.r / math.cos(math.pi / M.SIDES) + 1
      for k = 0, M.SIDES - 1 do
        local ang = 2 * math.pi * k / M.SIDES
        local q = {x=o.x + rr * math.cos(ang), y=o.y + rr * math.sin(ang)}
        local free = true
        for dj, w in ipairs(discs) do if dj ~= di and dist(q, w) < w.r then free = false; break end end
        if free then nodes[#nodes+1] = q end
      end
    end
    -- Octagons leave no vertices inside some real gaps. Add the throat and its
    -- two approaches, testing every new point and edge against the original discs.
    for i, o in ipairs(discs) do
      for j = i + 1, #discs do
        local w = discs[j]
        local d = dist(o, w)
        local gap = d - o.r - w.r
        if gap > 0.1 and gap < 12 then
          local ux, uy = (w.x - o.x) / d, (w.y - o.y) / d
          local x, y = o.x + ux * (o.r + gap / 2), o.y + uy * (o.r + gap / 2)
          local length = math.max(o.r, w.r) + 2
          for _, step in ipairs({-1, -0.5, 0, 0.5, 1}) do
            local q = {x=x - uy * length * step, y=y + ux * length * step}
            local free = true
            for _, other in ipairs(discs) do if dist(q, other) < other.r then free = false; break end end
            if free then nodes[#nodes+1] = q end
          end
        end
      end
    end
    nodes[#nodes+1] = b
    local goal = #nodes
    local g, came, closed, open = {[0]=0}, {}, {}, {[0]=true}
    local function pt(i) return i == 0 and a or nodes[i] end
    while true do
      local cur, best
      for i in pairs(open) do
        local f = g[i] + dist(pt(i), b)
        if not best or f < best then cur, best = i, f end
      end
      if not cur then return nil end
      if cur == goal then break end
      open[cur] = nil; closed[cur] = true
      for j = 1, #nodes do
        if not closed[j] and j ~= cur then
          local ng = g[cur] + dist(pt(cur), nodes[j])
          if (not g[j] or ng < g[j]) and clear(pt(cur), nodes[j], discs) then g[j] = ng; came[j] = cur; open[j] = true end
        end
      end
    end
    local out, i = {}, goal
    while i and i ~= 0 do table.insert(out, 1, {x=nodes[i].x, y=nodes[i].y}); i = came[i] end
    return out
  end

  -- When the padded route is blocked or takes a large detour, test the actual
  -- reaches with half a tile of clearance. Every returned engine path is still
  -- checked against actual reach, and margin crossings are recorded on last.
  function M.route(a, b, blobs, skip, strict)
    if strict then
      local route=M.detour(a,b,blobs,skip)
      if not route then return nil end
      if #route==0 then route={b} end
      local legs,prev={},a
      for _,v in ipairs(route) do
        local n=math.max(1,math.ceil(dist(prev,v)/16))
        for i=1,n do legs[#legs+1]={x=prev.x+(v.x-prev.x)*i/n,y=prev.y+(v.y-prev.y)*i/n} end
        prev=v
      end
      return legs
    end
    local full = M.detour(a,b,blobs,skip)
    local function length(vias)
      if not vias then return math.huge end
      if #vias == 0 then return dist(a,b) end
      local total, prev = 0, a
      for _, v in ipairs(vias) do total=total+dist(prev,v); prev=v end
      return total
    end
    local full_length = length(full)
    if full_length <= dist(a,b)*1.5 then return full end
    local tight = {}
    for _, bl in ipairs(blobs) do
      local copy = {members={}}
      for _, m in ipairs(bl.members) do
        copy.members[#copy.members+1] = {x=m.x,y=m.y,r=m.attack and m.r or math.min(m.r,m.range+0.5)}
      end
      tight[#tight+1]=copy
    end
    local narrow = M.detour(a,b,tight,skip)
    if narrow and length(narrow) < full_length*0.8 then
      -- The engine can bend a long, clear corridor leg through a neighbouring
      -- chunk's nest. Short local goals keep the request in the corridor.
      local legs, prev = {}, a
      for _, v in ipairs(narrow) do
        local count = math.max(1,math.ceil(dist(prev,v)/16))
        for i=1,count do legs[#legs+1]={x=prev.x+(v.x-prev.x)*i/count,y=prev.y+(v.y-prev.y)*i/count} end
        prev=v
      end
      return legs, true
    end
    return full
  end

  -- A walk's or drive's setup: mode, the final goal, and the chunks along
  -- the straight line to read while the path is asked for.
  function M.start(p, nav, mode)
    local surface = p.surface
    if not mode or surface.platform ~= nil then return nil end
    -- (d17 batch14, Opus 13:48 death: a recover tour's leg fell back to a spot within the corpse's reach, which clears
    -- the leg's fields, foes among them, and started again only when nav.avoid_mode was set, which a tour's nav was not:
    -- the reach walk went 32 tiles from a spawner and inside a big worm's range) the mode stays on the nav, so every walk
    -- started again on it plans round the nests as its first did.
    nav.avoid_mode = nav.avoid_mode or mode
    local f = {mode=mode, goal={x=nav.position.x, y=nav.position.y}, origin={x=p.position.x, y=p.position.y}, tolerance=nav.tolerance, detours=0, skips=0}
    f.pending = M.missing(surface, M.chunks_near({p.position, f.goal}, max_reach(mode)))
    -- The attacks under way now: the plan goes round those it meets; one that starts later is M.attack_ahead's.
    f.attacks_known = {}
    local box = {math.min(f.origin.x, f.goal.x), math.min(f.origin.y, f.goal.y), math.max(f.origin.x, f.goal.x), math.max(f.origin.y, f.goal.y)}
    for _, d in ipairs(M.attack_discs(surface, mode, box)) do f.attacks_known[d.id] = true end
    nav.foes = f
    return f
  end
  -- An attack that started after the walk's plan, near its way on: the straight line from here to the walk's goal
  -- passes within the zone's disc, nearer to its hit than here is: that disc, once (the walk plans again round it,
  -- going no deeper into it); else nil (round1950a: Haiku's rearm tour walked on into attack #1550 and died).
  function M.attack_ahead(p, nav)
    local f = nav.foes
    if not (f and f.mode and f.mode.attacks and f.attacks_known) then return nil end
    local here = p.position
    -- (a box from here to 96 tiles on toward the goal: the enemy units seen now on the next stretch count too)
    local len = dist(here, f.goal)
    local k = len > 96 and 96 / len or 1
    local ahead = {x=here.x + (f.goal.x - here.x) * k, y=here.y + (f.goal.y - here.y) * k}
    local box = {math.min(here.x, ahead.x), math.min(here.y, ahead.y), math.max(here.x, ahead.x), math.max(here.y, ahead.y)}
    for _, d in ipairs(M.attack_discs(p.surface, f.mode, box)) do
      if not f.attacks_known[d.id] then
        f.attacks_known[d.id] = true
        -- (units that move from cell to cell plan the walk again at most UNIT_REPLANS times)
        if seg_dist(here, f.goal, d) < math.min(d.r, dist(here, d) - 0.5) and not (d.units and (nav.unit_replans or 0) >= M.UNIT_REPLANS) then
          if d.units then nav.unit_replans = (nav.unit_replans or 0) + 1 end
          return d
        end
      end
    end
    return nil
  end
  -- Each tick while the path is asked for: read some chunks.
  function M.tick(p, nav)
    local f = nav.foes
    if not f then return end
    if f.pending and #f.pending > 0 then M.scan(p.surface, p.force, f.pending, M.CHUNKS_PER_TICK) end
    if nav.path_state == 'scanning' and #(f.pending or {}) == 0 then
      local held = f.held
      f.held = nil
      if held then api.adopt(p, nav, held.path, held.avoided) end
    end
  end
  local function blob_key(bl) return math.floor(bl.x) .. ',' .. math.floor(bl.y) end
  -- The discs as seen from here. A nest with here or the goal in a weapon's
  -- own reach is not avoided (the walk leaves it, or goes there: a goal in a
  -- reach takes unsafe_goal), and is named when that is where the walk began
  -- or goes. Here or the goal inside a margin only: that disc shrinks to just
  -- short of it, so the way on keeps out of the weapon's reach (Astra,
  -- operator 07:26: a goal in a nest's margin left the whole nest unchecked,
  -- and a big worm in it killed her on the way); such a nest is named too.
  local function member_key(m) return m.name .. '@' .. math.floor(m.x) .. ',' .. math.floor(m.y) end
  local function at_ends(f, bl)
    f.at_ends = f.at_ends or {}
    local name = M.name(bl)
    for _, t in ipairs(f.at_ends) do if t == name then return end end
    f.at_ends[#f.at_ends+1] = name
  end
  -- sub: final is a corner the plan chose, not the walk's goal (d17 batch12 A1, Opus 00:37: a corner inside a nest's
  -- reach left the whole nest out of the check, and its big worms killed him): only here leaves a nest out.
  local function fit(blobs, here, final, f, sub)
    local skip = {}
    if f.mode.strict then return skip end
    for bi, bl in ipairs(blobs) do
      for _, m in ipairs(bl.members) do
        local dh = dist(m, here)
        -- (an area under attack round here is not left out: it shrinks to just short of here below, so the way on
        -- goes no deeper into it; round1950a)
        if (dh < m.range and not m.attack) or (not sub and dist(m, final) < m.range) then
          skip[bi] = true
          if dist(m, f.origin or here) < m.r or dist(m, final) < m.r then at_ends(f, bl) end
          break
        end
      end
      if not skip[bi] then
        -- Discs grown for this walk (a path that kept bending into them), then
        -- shrunk to just short of here; the outline follows.
        local r = 0
        for _, m in ipairs(bl.members) do
          local g = f.grow and f.grow[member_key(m)]
          if g and g > m.r then m.r = g end
          local dh = dist(m, here)
          if dh < m.r then m.r = dh - 0.5 end
          local dg = dist(m, final)
          if dg < m.r then m.r = math.max(m.range, dg - 0.5); at_ends(f, bl) end
          r = math.max(r, dist(bl, m) + m.r)
        end
        bl.r = r
      end
    end
    return skip
  end
  -- The shortest way out of the worms and spawners whose reach (with the margin) holds here, when the goal lies
  -- outside them (C2, Opus 22:50: a walk begun 15 tiles from a big worm went west along it, since a nest holding the
  -- start was left out of the plan, and ended no_safe_route at 18 health; he died): of 32 directions, the nearest point
  -- outside every such disc, the one nearer the goal on a tie (2 tiles). nil when here is in none, or the goal is in one.
  function M.exit_point(here, final, blobs)
    local inside = {}
    for _, bl in ipairs(blobs) do
      for _, m in ipairs(bl.members) do
        if not m.attack and dist(m, here) < m.r then
          if dist(m, final) < m.r then return nil end
          inside[#inside+1] = m
        end
      end
    end
    if #inside == 0 then return nil end
    -- (only the discs a 160-tile ray can meet; 2-tile steps: at most 32 x 80 points)
    local discs = {}
    for _, bl in ipairs(blobs) do for _, m in ipairs(bl.members) do if not m.attack and dist(m, here) < m.r + 162 then discs[#discs+1] = m end end end
    local best, bs, bg
    for k = 0, 31 do
      local ang = 2 * math.pi * k / 32
      local ux, uy = math.cos(ang), math.sin(ang)
      for step = 2, 160, 2 do
        local q = {x=here.x + ux * step, y=here.y + uy * step}
        local clear = true
        for _, m in ipairs(discs) do if dist(q, m) < m.r + 1 then clear = false; break end end
        if clear then
          local g = dist(q, final)
          if not best or step < bs - 2 or (step <= bs + 2 and g < bg) then best, bs, bg = q, step, g end
          break
        end
      end
    end
    if not best then return nil end
    local names = {}
    for i, m in ipairs(inside) do if i <= 3 then names[i] = string.format('%s %s (%.0f tiles; %s %g)', m.name, at(m), dist(m, here), m.spawner and 'sight' or 'range', m.range) end end
    return {x=math.floor(best.x) + 0.5, y=math.floor(best.y) + 0.5}, string.format('the walk began inside the reach of %s%s: it went out the shortest way first, %d tiles to (%g,%g), then on',
      table.concat(names, ', '), #inside > 3 and string.format(' and %d more', #inside - 3) or '', bs, math.floor(best.x) + 0.5, math.floor(best.y) + 0.5)
  end
  local function passed(f, m, d)
    f.passed = f.passed or {}
    local k = m.name .. at(m)
    local old = f.passed[k]
    if not old or d < old.d then f.passed[k] = {d=d, text=string.format('%s %s: %.1f tiles (%s %g)', m.name, at(m), d, m.spawner and 'sight' or 'range', m.range)} end
  end
  -- A path found for a walk or drive: true to take it. Otherwise it waits for
  -- chunks (scanning), goes around a nest (the first leg asked for), or ends
  -- (unsafe: no way round).
  function M.accept(p, nav, path, avoided)
    local f = nav.foes
    if not f then return true end
    local surface = p.surface
    local here = {x=p.position.x, y=p.position.y}
    local pts = {here}
    for _, w in ipairs(path) do pts[#pts+1] = w.position end
    local final = nav.leg and nav.position or f.goal
    local R = max_reach(f.mode)
    local near = M.chunks_near(pts, R)
    local need = M.missing(surface, near)
    if #need > 0 then
      for _, ch in ipairs(need) do f.pending[#f.pending+1] = ch end
      f.held = {path=path, avoided=avoided}
      nav.path_state = 'scanning'; nav.found = nil
      return false
    end
    -- No worm or spawner recorded near the path: nothing to check (most walks).
    local c, any = cache(surface), false
    for _, ch in ipairs(near) do local rec = c[ch[3]]; if rec and rec.list then any = true; break end end
    -- (an area under attack now is no chunk record: round1950a)
    if not any and f.mode.attacks then any = #M.attack_discs(surface, f.mode) > 0 end
    if not any then return true end
    local blobs = M.blobs(surface, near, f.mode)
    -- Begun inside a worm's or spawner's reach (the margin with it): out the shortest way first, then on (C2).
    if not f.exit_done and not f.mode.strict and not nav.vehicle then
      f.exit_done = true
      local q, text = M.exit_point(here, final, blobs)
      if q then
        f.exit = text
        local vias = {q, {x=final.x, y=final.y}}
        if nav.leg then for _, v in ipairs(f.vias or {}) do vias[#vias+1] = v end end
        f.vias = vias
        nav.found = nil
        api.leg(p, nav)
        return false
      end
    end
    local sub = nav.leg and dist(final, f.goal) > 0.5 or false
    local skip = fit(blobs, here, final, f, sub)
    local bi, m, d = M.crossing(pts, blobs, skip)
    if not bi then
      -- Endpoint fitting can shrink a short corridor leg's margin. Still report
      -- where the accepted path passes inside the originally requested margin.
      for _, bl in ipairs(blobs) do for _, mm in ipairs(bl.members) do mm.r=mm.range+f.mode.pad end end
      local _, mm, dd = M.crossing(pts,blobs,skip)
      if mm and dd >= mm.range then passed(f,mm,dd) end
      return true
    end
    -- Through a nest's reach: plan with every read chunk near the path and near the straight way to the goal.
    local around = M.chunks_near({here, final}, R)
    for _, ch in ipairs(near) do around[#around+1] = ch end
    blobs = M.blobs(surface, around, f.mode)
    skip, bi = fit(blobs, here, final, f, sub), nil
    for bj, b in ipairs(blobs) do
      for _, mm in ipairs(b.members) do
        if mm.x == m.x and mm.y == m.y and mm.name == m.name then bi, m = bj, mm end
      end
    end
    local bl = blobs[bi] or {x=m.x, y=m.y, r=m.r, members={m}}
    if not blobs[bi] then blobs[#blobs+1] = bl end
    f.crossed = string.format('%s %s (%s %g + %g) at %.1f tiles', m.name, at(m), m.spawner and 'sight' or 'range', m.range, f.mode.pad, d)
    nav.found = nil
    -- The retry budget must not reject a path solely for crossing a margin.
    -- crossing chose the deepest pass relative to actual reach, across every disc.
    local function margin_only()
      if f.mode.strict or d < m.range then return false end
      passed(f,m,d)
      return true
    end
    if f.margin_route and margin_only() then return true end
    if f.detours >= M.MAX_DETOURS then
      if margin_only() then return true end
      nav.path_state = 'unsafe'
      f.block = {m=m, bl=bl}
      f.why = string.format('path still crosses the requested clearance of %s; %d detours tried', f.crossed, f.detours)
      return false
    end
    f.detours = f.detours + 1
    -- A repeated crossing widens only that member, preserving gaps to other discs.
    f.grow = f.grow or {}
    local key = blob_key(bl)
    if f.planned and f.planned[key] then
      local radius = math.min(m.r + 8, dist(m, here) - 0.5, dist(m, final) - 0.5)
      for _, other in ipairs(blobs) do
        for _, mm in ipairs(other.members) do
          local gap = dist(m, mm) - m.r - mm.r
          if mm ~= m and gap > 0 then radius = math.min(radius, m.r + math.max(0, gap - 0.5)) end
        end
      end
      m.r = math.max(m.r, radius); f.grow[member_key(m)] = m.r
    end
    local vias, narrow
    if nav.vehicle then vias=M.detour(here,final,blobs,skip) else vias,narrow=M.route(here,final,blobs,skip,f.mode.strict) end
    if narrow then f.margin_route=true end
    -- The straight line is clear and the engine's path bends into the reach
    -- (water or cliffs in the way): the disc it entered grows past the line,
    -- so the way round has corners that hold the path off it.
    if vias and #vias == 0 then
      local r = math.min(seg_dist(here, final, m) + 6, dist(m, here) - 1, dist(m, final) - 1)
      if r > m.r then m.r = r; f.grow[member_key(m)] = r end
      vias = M.detour(here, final, blobs, skip)
    end
    if (not vias or #vias == 0) and margin_only() then return true end
    if not vias or #vias == 0 then
      nav.path_state = 'unsafe'
      f.block = {m=m, bl=bl}
      f.why = string.format('no way to %s around %s: the path passes %s', at(final), M.name(bl), f.crossed)
      return false
    end
    f.planned = f.planned or {}
    f.avoided = f.avoided or {}
    for bj, o in ipairs(blobs) do
      if not skip[bj] and (bj == bi or not clear(here, final, {o}, {})) then
        local k = blob_key(o)
        if not f.planned[k] then f.planned[k] = true; f.avoided[#f.avoided+1] = M.name(o) end
      end
    end
    if nav.leg then for _, v in ipairs(f.vias or {}) do vias[#vias+1] = v end end
    f.vias = vias
    api.leg(p, nav)
    return false
  end
  -- Corners have only one tile of extra clearance; stopping three tiles early cuts them.
  function M.next_leg(p, nav)
    local f = nav.foes
    local v = f and f.vias and table.remove(f.vias, 1)
    if not v then return false end
    local last = #f.vias == 0
    nav.position = v
    nav.tolerance = last and f.tolerance or (nav.vehicle and 3 or 0.25)
    nav.precise_corner = not nav.vehicle and not last and (f.margin_route or (f.mode and f.mode.strict)) or nil
    nav.leg = not last or nil
    f.legs = (f.legs or 0) + 1
    return true
  end
  -- A leg ended with outcome: true when the walk goes on (the next leg asked for).
  function M.leg_done(p, nav, outcome)
    local f = nav.foes
    if not (f and nav.leg) then return false end
    if outcome == 'arrived' or outcome == 'arrived_near' then return api.leg(p, nav) end
    -- A corner it cannot get to (water, cliffs): on to the next one.
    if outcome == 'unreachable' and f.skips < 3 then f.skips = f.skips + 1; return api.leg(p, nav) end
    return false
  end
  -- The point nearest goal along the ray goal + s*(ux,uy), 0 <= s <= maxs,
  -- outside every disc, as s (just past each disc's edge); nil when none.
  local function clear_along(goal, ux, uy, discs, maxs)
    local s = 0
    for _ = 1, 64 do
      local moved = false
      local q = {x=goal.x + ux * s, y=goal.y + uy * s}
      for _, m in ipairs(discs) do
        if dist(q, m) < m.r then
          local fx, fy = goal.x - m.x, goal.y - m.y
          local b = fx * ux + fy * uy
          local disc = b * b - (fx * fx + fy * fy - m.r * m.r)
          local t = disc >= 0 and -b + disc ^ 0.5 + 0.5 or s
          if t > s then s = t; moved = true end
        end
      end
      if not moved then return s <= maxs and s or nil end
      if s > maxs then return nil end
    end
  end
  -- The nearest safe spot toward goal from `from`: on the line back to it, the
  -- point nearest goal outside every disc; else (from in a disc too) the
  -- nearest such point round goal, within 128 tiles.
  local function safe_spot(goal, from, discs)
    local dx, dy = from.x - goal.x, from.y - goal.y
    local L = (dx * dx + dy * dy) ^ 0.5
    if L > 0.5 then
      local s = clear_along(goal, dx / L, dy / L, discs, L)
      if s then return {x=goal.x + dx / L * s, y=goal.y + dy / L * s} end
    end
    local best, bs
    for k = 0, 31 do
      local ang = 2 * math.pi * k / 32
      local s = clear_along(goal, math.cos(ang), math.sin(ang), discs, 128)
      if s and (not bs or s < bs) then best, bs = {x=goal.x + math.cos(ang) * s, y=goal.y + math.sin(ang) * s}, s end
    end
    return best
  end
  -- A goal inside a weapon's own reach (a worm's range; with spawners, a
  -- spawner's units' sight) on the chunks the map draws, read now (Astra,
  -- operator 07:26: avoid_enemies true walked her to (-10,350), a goal in a
  -- nest's reach, and a big worm killed her on the way at (-25,335)). Returns
  -- nil when clear, else {m (the nearest weapon by how deep the goal lies in
  -- its reach), d, spot (the nearest safe spot toward the goal from `from`,
  -- outside every disc: reach + margin), nest}. The chunks round the spot
  -- are read too, up to three rounds, so the spot clears what lies past them.
  -- The weapons whose discs lie round point (chunks within R + the farthest reach), read now, into discs (each
  -- member once: have holds their keys).
  local function read_discs(p, mode, point, discs, have, R)
    local chunks = M.chunks_near({point}, R or max_reach(mode))
    -- Destination checks need the enemies the map shows now. The path cache can be a minute old: on the private
    -- 2.0.77 check a new worm inside a cached empty area let an autowalk start into its range. Refresh only the
    -- chunks around this destination; overlapping stops in the same tick share that read. Path scans keep TTL.
    local c = cache(p.surface)
    for _, ch in ipairs(chunks) do
      local rec = c[ch[3]]
      if not rec or rec.t ~= game.tick then c[ch[3]] = M.read_chunk(p.surface, p.force, ch[1], ch[2]) end
    end
    for _, bl in ipairs(M.blobs(p.surface, chunks, mode)) do
      for _, m in ipairs(bl.members) do
        local k = member_key(m)
        if not have[k] then have[k] = true; m.blob = bl; discs[#discs+1] = m end
      end
    end
  end
  -- Belt planning: memoize the discs around each tile chunk, not a fresh goal check per A* tile.
  -- Reads only charted chunks, shared with destination checks in this tick; no surface-wide scan.
  function M.route_guard(p, value)
    if value==nil or value==false then return nil end
    local mode=M.mode(value)
    local by_chunk={}
    local stats={chunks=0}
    local function around(x,y)
      if p.surface.platform~=nil then return {} end
      local cx,cy=math.floor(x/32),math.floor(y/32)
      local k=cx..','..cy
      local discs=by_chunk[k]
      if not discs then
        discs={}; by_chunk[k]=discs; stats.chunks=stats.chunks+1
        -- A chunk corner is less than 23 tiles from its centre.
        read_discs(p,mode,{x=cx*32+16,y=cy*32+16},discs,{},max_reach(mode)+23)
      end
      return discs
    end
    local function blocked(x,y)
      local point={x=x+0.5,y=y+0.5}
      for _,m in ipairs(around(x,y)) do
        if dist(point,m)<m.r then
          return string.format('%s %s: within %g tiles (reach %g + clearance %g)',m.name,at(m),m.r,m.range,mode.pad)
        end
      end
    end
    local function guide(a,b)
      local members,seen={},{}
      local steps=math.max(1,math.ceil(dist(a,b)/32))
      for i=0,steps do
        for _,m in ipairs(around(a.x+(b.x-a.x)*i/steps,a.y+(b.y-a.y)*i/steps)) do
          local k=member_key(m)
          if not seen[k] then
            seen[k]=true
            members[#members+1]={x=m.x,y=m.y,r=m.r}
          end
        end
      end
      -- (d17 batch14 B3) past 32, the members within NEST of each other as one disc round them all (wider, never nearer)
      if #members>32 then
        local group,merged={},{}
        for i,m in ipairs(members) do
          if not group[i] then
            local b={m}; group[i]=true
            local k=1
            while k<=#b do
              for j,o in ipairs(members) do if not group[j] and dist(b[k],o)<=M.NEST then group[j]=true; b[#b+1]=o end end
              k=k+1
            end
            local x0,y0,x1,y1=math.huge,math.huge,-math.huge,-math.huge
            for _,q in ipairs(b) do x0,y0,x1,y1=math.min(x0,q.x),math.min(y0,q.y),math.max(x1,q.x),math.max(y1,q.y) end
            local c={x=(x0+x1)/2,y=(y0+y1)/2,r=0}
            for _,q in ipairs(b) do c.r=math.max(c.r,dist(c,q)+q.r) end
            merged[#merged+1]=c
          end
        end
        members=merged
      end
      assert(#members<=32,'enemy clearance guide exceeds 32 nearby nests')
      -- Strict clearance: no move_to margin relaxation. The tile search rechecks snapped corners.
      local vias=M.detour(a,b,{{members=members}},{})
      assert(vias,'no route outside the requested enemy clearance')
      return vias
    end
    return blocked,M.describe(mode),max_reach(mode)+2,stats,guide
  end
  -- The weapon whose own reach holds goal deepest: {m, d}, nil when none.
  local function deepest(discs, goal)
    local inside
    for _, m in ipairs(discs) do
      local d = dist(m, goal)
      if d < m.range and (not inside or d - m.range < inside.d - inside.m.range) then inside = {m=m, d=d} end
    end
    return inside
  end
  -- The worms and spawners (and areas under attack, as mode counts them) whose reach + the margin comes within R tiles
  -- of point, on the chunks the map draws: [{x, y, r (reach + margin), name, range, spawner}] (d17 batch14, Opus 13:46:
  -- construct stood him 40.0 tiles from a spawner, inside its 44 with the margin, to build; spitters killed him there).
  function M.margin_discs(p, point, mode, R)
    if not mode or p.surface.platform ~= nil then return {} end
    local discs, out = {}, {}
    read_discs(p, mode, point, discs, {}, R + max_reach(mode))
    for _, m in ipairs(discs) do
      local r = (mode.distance and math.max(mode.distance, m.range) or m.range) + mode.pad
      if dist(m, point) < R + r then out[#out+1] = {x=m.x, y=m.y, r=r, name=m.name, range=m.range, spawner=m.spawner} end
    end
    return out
  end
  -- goal_check's first step alone (round2120a: a tour checks each of its stops at the call): the weapon whose own
  -- reach holds goal, {m, d, nest}, or nil; no safe spot is worked out.
  function M.inside(p, goal, mode)
    if not mode or p.surface.platform ~= nil then return nil end
    local discs = {}
    read_discs(p, mode, goal, discs, {})
    local c = deepest(discs, goal)
    return c and {m=c.m, d=c.d, nest=M.name(c.m.blob)} or nil
  end
  -- Every worm, spawner and area under attack now (as mode counts them) whose own reach comes within R tiles of
  -- point, on the chunks the map draws, read now (recover dry_run, round2120a: the danger round a corpse):
  -- {m, d (tiles from point), inside (point lies in its reach)}, the deepest first.
  function M.near(p, point, mode, R)
    if not mode or p.surface.platform ~= nil then return {} end
    local discs, out = {}, {}
    read_discs(p, mode, point, discs, {}, R + 48)
    for _, m in ipairs(discs) do
      local d = dist(m, point)
      if d - m.range <= R then out[#out+1] = {m=m, d=d, inside=d < m.range} end
    end
    table.sort(out, function(x, y) return x.d - x.m.range < y.d - y.m.range end)
    return out
  end
  function M.goal_check(p, from, goal, mode)
    if not mode or p.surface.platform ~= nil then return nil end
    local discs, have = {}, {}
    local function read(point) read_discs(p, mode, point, discs, have) end
    read(goal)
    local inside = deepest(discs, goal)
    if not inside then return nil end
    local spot
    for _ = 1, 3 do
      spot = safe_spot(goal, from, discs)
      if not spot then break end
      local n = #discs
      read(spot)
      if #discs == n then break end
      local clear = true
      for i = n + 1, #discs do if dist(spot, discs[i]) < discs[i].r then clear = false end end
      if clear then break end
    end
    return {m=inside.m, d=inside.d, spot=spot, nest=M.name(inside.m.blob)}
  end
  -- 'goal (-10,350) is inside big-worm-turret (-21,343) range 38 (13.0 tiles from it)'.
  function M.goal_text(label, goal, c)
    local m = c.m
    if m.group or m.units then
      return string.format('%s %s is within %g tiles of %s%s at %s, seen now (%.1f tiles from it)', label, at(goal), m.range, m.group and 'an ' or '', m.name, at(m), c.d)
    elseif m.attack then
      -- when it clears (C4, Haiku 23:40: nine dry runs of recover waiting for it): an area counts as under attack until
      -- ATTACK_ACTIVE ticks after its last hit
      local left = math.max(0, math.ceil(M.ATTACK_ACTIVE / 60 - (m.ago or 0)))
      return string.format('%s %s is within %g tiles of %s at %s, an area under attack now (last hit %ds ago%s) (%.1f tiles from it); it clears in about %d s (tick %d) unless hit again (an area counts as under attack %d s after its last hit)', label, at(goal),
        m.range, m.name, at(m), m.ago or 0, m.size and m.size > 0 and string.format(', %d attackers seen', m.size) or '', c.d,
        left, game.tick + left * 60, M.ATTACK_ACTIVE / 60)
    elseif m.spawner then
      return string.format('%s %s is within %g tiles of %s %s, its units\' reach (%.1f tiles from it)', label, at(goal), m.range, m.name, at(m), c.d)
    end
    return string.format('%s %s is inside %s %s range %g (%.1f tiles from it)', label, at(goal), m.name, at(m), m.range, c.d)
  end
  -- '; the nearest safe spot toward it: (-10,302), 48 tiles from the goal, outside every worm's range + 8 ...'.
  function M.spot_text(goal, c, mode)
    if not c.spot then return '; no spot within 128 tiles of it is outside every reach the map shows' end
    return string.format('; the nearest safe spot toward it: %s, %d tiles from it, outside every worm\'s range, spawner\'s %d tiles and area under attack (%d tiles), + %g, the map shows',
      at(c.spot), math.floor(dist(c.spot, goal) + 0.5), M.SPAWNER_REACH, M.ATTACK_R, mode.pad)
  end
  -- A route given up for enemies that move (d17 batch17 B3, Opus on the far-east route: walks ended no_safe_route for a
  -- roaming group, a lone big biter or an attack round where he stood, and he stood there; one such stop he died at):
  -- the disc it crosses and every disc of its group are units, groups or attacks, none a worm or spawner. Their names.
  function M.moving_only(nav)
    local b = nav.foes and nav.foes.block
    if not (b and b.m and b.m.attack) then return nil end
    for _, mm in ipairs(b.bl and b.bl.members or {}) do if not mm.attack then return nil end end
    return M.name(b.bl or {members={b.m}})
  end
  function M.step_clear(p,nav,to)
    local mode=nav.foes and nav.foes.mode or nav.avoid_mode
    if not (mode and mode.strict) or p.surface.platform then return true end
    local pts={p.position,to}
    local near=M.chunks_near(pts,max_reach(mode))
    -- A path supplies the cache; direct steering waits for the same bounded reads.
    local need=M.missing(p.surface,near)
    if #need>0 then M.scan(p.surface,p.force,need,M.CHUNKS_PER_TICK); return false end
    local _,m,d=M.crossing(pts,M.blobs(p.surface,near,mode),{})
    if m then
      nav.path_state='unsafe'
      nav.foes=nav.foes or {mode=mode,goal=nav.position,tolerance=nav.tolerance}
      nav.foes.why=string.format('next walking step crosses avoid_enemies=%g: %s %s at %.2f tiles; minimum %.2f',mode.pad,m.name,at(m),d,m.range+mode.pad)
      return false
    end
    return true
  end
  -- The facts for last: what was gone around, what lies at the start or goal.
  function M.report(last, nav)
    local f = nav.foes
    if not f then return end
    if f.avoided and #f.avoided > 0 then last.avoided_enemies = f.avoided end
    if f.at_ends and #f.at_ends > 0 then last.enemies_at_start_or_goal = f.at_ends end
    if f.passed then
      local list = {}
      for _, v in pairs(f.passed) do list[#list+1] = v.text end
      table.sort(list)
      last.passed_within_margin = list
    end
    if f.why then last.why = f.why end
    if f.exit then last.left_reach_first = f.exit end
    if nav.margin_probe then last.smaller_margins=nav.margin_probe.result or {line="smaller-margin check interrupted; no complete route verified"} end
    if nav.attack_replan then last.replanned = nav.attack_replan end
  end
  return M
end
