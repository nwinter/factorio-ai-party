-- The fog view (Nick d17 17:28: "a low-visibility fog-of-war view that shows what we usually see, so they know,
-- physically, what used to be there"). What our force last saw of its own buildings, chunk by chunk: the census
-- (census.lua) reads every building of ours in turn and readmemory.observe hands each one in a chunk our force sees
-- now to note(); a chunk out of sight keeps what was there when it was last seen. Belts are belt memory's
-- (beltgaps.lua). A building removed in sight (mined, deconstructed, destroyed while seen) is forgotten; one destroyed
-- out of sight stays remembered, and the losses log (lostlog.lua) says it was lost after it was seen.
-- area() is what an out-of-sight area read returns: remembered buildings and belts with when they were seen, the
-- ghosts of ours there now (the game's map draws our ghosts in fog) and our buildings lost there (the game's destroyed
-- alerts name each one wherever it was). The map in fog shows the last chart: buildings as shapes in map colours;
-- the memory adds what they were (names, directions) and their state when seen.
-- Bounded: MAX_CHUNKS chunks (a chunk in sight is dropped first when full: it is read live), MAX_ROWS rows a chunk.
-- The switch fog_strict (storage agent_harness.fog_strict; operator call fog_strict {on}; default off): off, the reads
-- keep reading our own buildings in fog as they stand now (runtime.lua known(): the map draws them) and fog lists beside
-- them only the remembered buildings that no longer stand there, with our ghosts and losses; on, our own buildings out of
-- sight are read from the memory alone.
return function(api)
  local M = {}
  local pair = require('numtext').pair
  local MAX_CHUNKS, MAX_ROWS = api.max_chunks or 4096, 1024
  -- Not buildings, or moving, or belts (belt memory has those).
  local SKIP = {character=true, resource=true, ['entity-ghost']=true, ['tile-ghost']=true, ['item-entity']=true,
    ['item-request-proxy']=true, corpse=true, ['character-corpse']=true, car=true, ['spider-vehicle']=true,
    locomotive=true, ['cargo-wagon']=true, ['fluid-wagon']=true, ['artillery-wagon']=true, ['construction-robot']=true,
    ['logistic-robot']=true, ['combat-robot']=true, ['capture-robot']=true, ['transport-belt']=true,
    ['underground-belt']=true, splitter=true, ['linked-belt']=true, ['temporary-container']=true, ['cargo-pod']=true,
    ['rocket-silo-rocket']=true, ['rocket-silo-rocket-shadow']=true, ['deconstructible-tile-proxy']=true,
    ['entity-ghost-proxy']=true, unit=true, ['spider-unit']=true, ['segmented-unit']=true, ['spider-leg']=true,
    ['asteroid']=true, fire=true, stream=true, projectile=true, explosion=true, smoke=true, sticker=true}
  local function store()
    local s = api.state()
    s.fog_memory = s.fog_memory or {chunks={}, order={}, n=0}
    return s.fog_memory
  end
  local function ckey(force, surface, cx, cy) return force .. '|' .. surface .. '|' .. cx .. ',' .. cy end
  local function chunk_visible(c)
    local f, s = game.forces[c.force], game.surfaces[c.surface]
    return f and s and f.is_chunk_visible(s, {x=c.x, y=c.y}) or false
  end
  local function evict(m)
    for i = 1, math.min(#m.order, 64) do
      local k = m.order[i]
      local c = m.chunks[k]
      if not c or chunk_visible(c) then
        table.remove(m.order, i)
        if c then m.chunks[k] = nil; m.n = m.n - 1 end
        return
      end
    end
    local k = table.remove(m.order, 1)
    if k and m.chunks[k] then m.chunks[k] = nil; m.n = m.n - 1 end
  end
  -- A building of ours in a chunk our force sees now (readmemory.observe checked that), with its status name.
  function M.note(e, pos, status)
    local t = e.type
    if SKIP[t] then return end
    local force = e.force
    local fname = force and force.name
    if not fname or fname == 'enemy' or fname == 'neutral' then return end
    local s = e.surface
    if not s then return end
    local cx, cy = math.floor(pos.x / 32), math.floor(pos.y / 32)
    local m = store()
    local k = ckey(fname, s.name, cx, cy)
    local c = m.chunks[k]
    if not c then
      if m.n >= MAX_CHUNKS then evict(m) end
      c = {force=fname, surface=s.name, x=cx, y=cy, rows={}, n=0}
      m.chunks[k] = c; m.order[#m.order+1] = k; m.n = m.n + 1
    end
    local rk = pos.x .. ',' .. pos.y
    if not c.rows[rk] then
      if c.n >= MAX_ROWS then return end
      c.n = c.n + 1
    end
    c.rows[rk] = e.name .. '|' .. (e.supports_direction and e.direction or 0) .. '|' .. (status or '')
    c.seen = game.tick
  end
  -- (d21 batch73 AI) note() for the census: its type and position read, its chunk (cx, cy) in sight, status a function
  -- of the entity; ctx is the census step's ({fog = {}, fog_prefix = 'force|surface|'}): each chunk's table found once
  -- a step, the row keys fast (numtext) and the texts made once, the same rows as note() writes.
  local SUPDIR, TEXT = {}, {}
  function M.note_seen(e, t, pos, cx, cy, status, ctx)
    if SKIP[t] then return end
    local ck = cx * 1048576 + cy
    local c = ctx.fog[ck]
    if not c then
      local m = store()
      local k = ctx.fog_prefix .. pair(cx, cy)
      c = m.chunks[k]
      if not c then
        if m.n >= MAX_CHUNKS then evict(m) end
        c = {force=ctx.force_name, surface=ctx.surface_name, x=cx, y=cy, rows={}, n=0}
        m.chunks[k] = c; m.order[#m.order+1] = k; m.n = m.n + 1
      end
      ctx.fog[ck] = c
    end
    local rk = pair(pos.x, pos.y)
    if not c.rows[rk] then
      if c.n >= MAX_ROWS then return end
      c.n = c.n + 1
    end
    local name = e.name
    local sd = SUPDIR[name]
    if sd == nil then sd = e.supports_direction and true or false; SUPDIR[name] = sd end
    local dir = sd and e.direction or 0
    local st = status(e) or ''
    local a = TEXT[name]
    if not a then a = {}; TEXT[name] = a end
    local b = a[dir]
    if not b then b = {}; a[dir] = b end
    local text = b[st]
    if not text then text = name .. '|' .. dir .. '|' .. st; b[st] = text end
    c.rows[rk] = text
    c.seen = game.tick
  end
  -- A building of ours gone where our force saw it go (mined, deconstructed, or destroyed in sight).
  function M.forget(e)
    if not (e and e.valid) then return end
    local pos, f, s = e.position, e.force, e.surface
    if not (f and s) then return end
    local c = store().chunks[ckey(f.name, s.name, math.floor(pos.x / 32), math.floor(pos.y / 32))]
    local rk = pos.x .. ',' .. pos.y
    if c and c.rows[rk] then c.rows[rk] = nil; c.n = c.n - 1 end
  end
  function M.strict() return api.state().fog_strict == true end
  M.operator = {fog_strict=function(a)
    assert(a.on == nil or type(a.on) == 'boolean', 'on must be true or false')
    if a.on ~= nil then api.state().fog_strict = a.on or nil end
    return {fog_strict=M.strict(), line=M.strict() and 'fog_strict on: our own buildings out of sight are read from what our force last saw there'
      or 'fog_strict off: our own buildings in fog are read as they stand now; fog lists the remembered ones no longer there, our ghosts and losses'}
  end}
  function M.stats()
    local m, rows = store(), 0
    for _, c in pairs(m.chunks) do rows = rows + c.n end
    return {chunks=m.n, rows=rows, max_chunks=MAX_CHUNKS}
  end
  local function inside(q, box) return q.x >= box[1][1] and q.x <= box[2][1] and q.y >= box[1][2] and q.y <= box[2][2] end
  local function dir_name(d) return api.direction_name and api.direction_name(d) or d end
  -- The out-of-sight part of box ({{x1,y1},{x2,y2}}) on surface s for force f: remembered buildings and belts, the
  -- ghosts there, the losses there. limit caps each list; *_count says how many there were. present ({"name@x,y"=true}:
  -- our buildings the read itself lists there, fog_strict off): remembered rows only for what no longer stands there.
  function M.area(f, s, box, limit, present)
    limit = limit or 256
    local now = game.tick
    local remembered, ghosts, lost = {}, {}, {}
    local counts = {remembered=0, ghosts=0, lost=0}
    local hidden, chunks_in, hidden_n = {}, 0, 0
    local m = store()
    for cx = math.floor(box[1][1] / 32), math.floor(box[2][1] / 32) do
      for cy = math.floor(box[1][2] / 32), math.floor(box[2][2] / 32) do
        chunks_in = chunks_in + 1
        if not f.is_chunk_visible(s, {x=cx, y=cy}) then
          hidden[cx .. ',' .. cy] = true; hidden_n = hidden_n + 1
          local c = m.chunks[ckey(f.name, s.name, cx, cy)]
          for rk, v in pairs(c and c.rows or {}) do
            local x, y = rk:match('^(.-),(.*)$')
            local q = {x=tonumber(x), y=tonumber(y)}
            local name0 = v:match('^(.-)|')
            if inside(q, box) and not (present and present[name0 .. '@' .. q.x .. ',' .. q.y]) then
              counts.remembered = counts.remembered + 1
              if #remembered < limit then
                local name, d, st = v:match('^(.-)|(.-)|(.*)$')
                remembered[#remembered+1] = {name=name, position=q, direction=dir_name(tonumber(d)), status=st ~= '' and st or nil,
                  seen_tick=c.seen, seen_s_ago=c.seen and math.floor((now - c.seen) / 60) or nil, remembered=true}
              end
            end
          end
          local belts = api.belt_chunk and api.belt_chunk(f.name, s.name, cx, cy)
          local done = {}
          for _, r in pairs(belts and belts.tiles or {}) do
            if not done[r] and not r.ghost and r.position and inside(r.position, box)
              and not (present and present[r.name .. '@' .. r.position.x .. ',' .. r.position.y]) then
              done[r] = true
              counts.remembered = counts.remembered + 1
              if #remembered < limit then
                remembered[#remembered+1] = {name=r.name, position={x=r.position.x, y=r.position.y}, direction=dir_name(r.direction),
                  seen_tick=r.tick, seen_s_ago=r.tick and math.floor((now - r.tick) / 60) or nil, remembered=true}
              end
            end
          end
        end
      end
    end
    if hidden_n > 0 then
      for _, g in ipairs(s.find_entities_filtered{area={left_top={x=box[1][1], y=box[1][2]}, right_bottom={x=box[2][1], y=box[2][2]}}, force=f,
          type={'entity-ghost', 'tile-ghost'}, limit=4000}) do
        local q = g.position
        if g.valid and (g.type == 'entity-ghost' or g.type == 'tile-ghost') and hidden[math.floor(q.x / 32) .. ',' .. math.floor(q.y / 32)] then
          counts.ghosts = counts.ghosts + 1
          if #ghosts < limit then
            ghosts[#ghosts+1] = {name=g.ghost_name, position={x=q.x, y=q.y}, tile=g.type == 'tile-ghost' or nil,
              direction=g.type == 'entity-ghost' and dir_name(g.direction) or nil}
          end
        end
      end
      for _, r in ipairs(api.lost_in and api.lost_in(f.name, s.name, box) or {}) do
        if hidden[math.floor(r.x / 32) .. ',' .. math.floor(r.y / 32)] then
          counts.lost = counts.lost + 1
          if #lost < limit then
            lost[#lost+1] = {name=r.n, position={x=r.x, y=r.y}, lost_tick=r.t, lost_s_ago=math.floor((now - r.t) / 60), cause=r.c}
          end
        end
      end
    end
    -- A remembered building lost after it was last seen: the destroyed alert told us.
    local lost_at = {}
    for _, r in ipairs(lost) do lost_at[r.name .. '@' .. r.position.x .. ',' .. r.position.y] = r end
    for _, r in ipairs(remembered) do
      local l = lost_at[r.name .. '@' .. r.position.x .. ',' .. r.position.y]
      if l and (not r.seen_tick or l.lost_tick >= r.seen_tick) then r.lost_after_seen = string.format('lost %ds ago%s', l.lost_s_ago, l.cause and ' (' .. l.cause .. ')' or '') end
    end
    local function order(list) table.sort(list, function(a, b)
      if a.position.y ~= b.position.y then return a.position.y < b.position.y end
      if a.position.x ~= b.position.x then return a.position.x < b.position.x end
      return a.name < b.name end) end
    order(remembered); order(ghosts); order(lost)
    if hidden_n == 0 then return nil end
    return {chunks_out_of_sight=hidden_n, chunks=chunks_in, remembered=remembered, remembered_count=counts.remembered,
      ghosts=ghosts, ghost_count=counts.ghosts, lost=lost, lost_count=counts.lost, only_gone=present and true or nil,
      line=string.format('%d of %d chunks here out of sight: %d buildings and belts remembered%s, %d ghosts of ours, %d of ours lost there',
        hidden_n, chunks_in, counts.remembered, present and ' that no longer stand there' or '', counts.ghosts, counts.lost),
      note=(present and 'our buildings in fog are read as they stand now (fog_strict off); remembered rows are ones our force saw there '
        .. 'that no longer stand there (seen_s_ago; status then); ' or 'out of sight: remembered rows are what our force last saw there '
        .. '(seen_s_ago; status then), not the state now; ') .. 'ghosts are ours there now (the map draws our ghosts in fog); lost are our buildings destroyed there (the game\'s '
        .. 'destroyed alerts). The map in fog shows the last chart, buildings as shapes in map colours: the memory adds '
        .. 'names, directions and status as seen. A chunk never seen since the memory began (d17) has no remembered rows.'}
  end
  return M
end
