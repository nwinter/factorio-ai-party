-- artillery_live (operator read for the stream; d17 artycam, viewer Foobator 12:48: "if there is only one arty shell
-- in flight and nothing else interesting has happened, can you show the impact on screen"): our artillery pieces and
-- the shells they have just fired, each with its target and when it lands, for the director to cut to the target
-- before the shell comes down.
-- - A shell leaves at 1 tile a tick (artillery-shell's starting_speed on 2.0.77, no range or direction deviation), so
--   it is up at most range / 60 s (224 tiles: 3.7 s). The stream service reads this every half second while a piece
--   is loaded with targets in range (`every`), else every 10 s.
-- - Pieces (turrets, wagons) are found once and kept; a change in the force's count of them finds them again, one
--   surface a read (the census's lists where it walked the surface, else a whole-surface find: 11 ms on world n's
--   Nauvis). A shell is found within SHELL_R tiles of a loaded piece (how far one flies between reads, a find of a few
--   chunks; one over the whole range took 4.3 ms).
-- - (d26 batch224) Its heading: two sightings of it, the second in the next read. A shell starts 0.3-2.4 tiles off the
--   line from its piece's centre to its target (the muzzle's shift by orientation; measured on the private copy), so
--   one sighting near the piece points hundreds of tiles wide at 1400 tiles; the path through two sightings passed
--   its flare within 0.2 tiles. A read that leaves sightings pending asks for the next within FAST s (`every`).
-- - New shells: on a surface whose artillery shells used (item statistics, 5 us) went up since the last read, the
--   loaded pieces are searched within the distance a shell flies between reads: every one when the reads come every
--   FAST s (a team flare kept, or a sighting pending: a 20-tile find, 0.023 ms a piece on the copy), else SEARCH of
--   them in turn (38 tiles at the half-second pace: 0.07 ms). A piece seen firing is left out until its cooldown
--   (COOLDOWN ticks: the cannon's 200, less the force's shooting speed bonus) is nearly over: in a barrage each piece
--   fires every 200 ticks, so most of them are cooling down at any read. A sighting near a pending or followed shell is
--   the same shell.
-- - Its target: the team's flare on its path (within PERP), else the enemy spawner or worm on it (the nearest such)
--   on charted chunks, as the artillery read. A shell with neither (a unit) is left out. (d26 batch224) The spawners and worms come from a nest index a surface, kept by chunk: one slice of BOX x
--   BOX chunks that some loaded piece's range reaches is found a read (0.39 ms on the private copy for 64 chunks), the
--   surface again TARGET_EVERY after its last. It replaces a find over each piece's range every TARGET_EVERY (10.5 ms
--   on the copy for 627 tiles, with none found: world n's nests in reach were cleared on d26). The line is matched
--   chunk by chunk along the shell's way.
-- - Who: the agent who last put shells into the piece by hand (hauling.lua's moves, M.put), else the piece's
--   last_user.
-- - (d26 batch224 AY, viewer Aurora 05:29: "Opus's shelling is off-screen") The team's flares: artillery.lua's use_item
--   remote hands each flare to M.flare. A shell whose line passes one (waiting, or taken in the last FLARE_AFTER ticks)
--   gets the flare's spot as its target, named after the enemy spawner or worm within NEAR of it, with who flared it.
--   A flare reaches the manual range (1568 tiles on world n), past the automatic targets' list. While a flare is kept
--   (FLARE_KEEP: its 60 s life and a margin; FLARE_AFTER once taken) the read asks for the FAST pace, and loaded pieces
--   are searched with no automatic target in range. Shells go 1 tile a tick: a 1400-tile shot is up about 23 s.
-- - MAX_PIECES 64: world n had 26 artillery turrets on d26, each topped up by an inserter (its count never drops).
return function(api)
  local M = {}
  local TYPES = {'artillery-turret', 'artillery-wagon'}
  local INV = {['artillery-turret']='artillery_turret_ammo', ['artillery-wagon']='artillery_wagon_ammo'}
  local SHELL_R, TARGET_EVERY, PERP, NEAR, MAX_PIECES, KEEP = 48, 3600, 2.5, 6, 64, 600
  local FLARE_KEEP, FLARE_AFTER, MAX_FLARES = 3900, 300, 256
  local BOX, MAX_NESTS = 8, 2000
  local SEARCH, MAX_PEND, FOLLOW, FLY, FAST, FAST_R, COOLDOWN = 4, 16, 40, 1800, 0.2, 24, 200
  local ENEMY = {'unit-spawner', 'turret'}
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function store()
    local s = api.state()
    s.artycam = s.artycam or {pieces={}, count=-1, loaders={}, seen={}}
    return s.artycam
  end
  local function pkey(surface, pos) return surface .. '|' .. math.floor(pos.x) .. ',' .. math.floor(pos.y) end
  -- (numeric keys: a string key costs about 16 us on world n)
  local function ckey(cx, cy) return cx * 65536 + cy end
  local RANGES = {}  -- piece name -> {range, min_range, tick}: a prototype read costs 40-200 us
  local function range_of(e)
    local c = RANGES[e.name]
    if not c or game.tick - c[3] >= TARGET_EVERY then
      local range, min_range = 224, 0
      if api.range then range, min_range = api.range(e) end
      c = {range, min_range, game.tick}
      RANGES[e.name] = c
    end
    return c[1], c[2]
  end
  local NAMES
  local function names()
    if not NAMES then
      NAMES = {}
      for name in pairs(try(function() return prototypes.get_entity_filtered{{filter='type', type=TYPES}} end) or {}) do NAMES[#NAMES+1] = name end
    end
    return NAMES
  end
  local function count(force)
    local n = 0
    for _, name in ipairs(names()) do n = n + (try(function() return force.get_entity_count(name) end) or 0) end
    return n
  end

  -- hauling.lua: items an agent put into an entity by hand; shells into a piece make it the piece's loader.
  function M.put(who, pos, surface, stacks, entity_name)
    if entity_name ~= 'artillery-turret' and entity_name ~= 'artillery-wagon' then return end
    for _, st in ipairs(stacks or {}) do
      if st.name and st.name:find('artillery%-shell') then
        store().loaders[pkey(surface, pos)] = {name=who, tick=game.tick}
        return
      end
    end
  end

  -- artillery.lua: a flare placed by use_item {item: artillery-targeting-remote}: {by, flare (the entity), position, surface}
  function M.flare(r)
    local st = store()
    st.flares = st.flares or {}
    if #st.flares >= MAX_FLARES then table.remove(st.flares, 1) end
    st.flares[#st.flares+1] = {by=r.by, e=r.flare, x=r.position.x, y=r.position.y, surface=r.surface, tick=game.tick}
  end

  -- The flares still kept, by surface name; how many wait (valid) and how many are kept in all.
  local function flares(st, now)
    local keep, by, waiting = {}, {}, 0
    for _, f in ipairs(st.flares or {}) do
      if f.e and f.e.valid then waiting = waiting + 1 elseif not f.gone then f.gone = now end
      if now - f.tick <= FLARE_KEEP and (not f.gone or now - f.gone <= FLARE_AFTER) then
        keep[#keep+1] = f
        by[f.surface] = by[f.surface] or {}
        local l = by[f.surface]
        l[#l+1] = f
      end
    end
    st.flares = #keep > 0 and keep or nil
    return by, waiting, #keep
  end

  -- The pieces: a pass over the surfaces, one a read, when the count changed (or MAX_PIECES did: st.cap).
  local function pieces(st, force)
    local n = count(force)
    if (n ~= st.count or st.cap ~= MAX_PIECES) and not st.pass then
      local list = {}
      for _, s in pairs(game.surfaces) do list[#list+1] = s.name end
      table.sort(list)
      st.pass = {surfaces=list, i=1, found={}, count=n}
    end
    if st.pass then
      local p = st.pass
      local s = game.get_surface(p.surfaces[p.i] or '')
      if s then
        local list = api.census_typed and try(function() return api.census_typed(force, s, TYPES) end)
        for _, e in ipairs(list or try(function() return s.find_entities_filtered{type=TYPES, force=force} end) or {}) do
          if #p.found < MAX_PIECES then p.found[#p.found+1] = {e=e} end
        end
      end
      p.i = p.i + 1
      if p.i > #p.surfaces then
        -- (what was learnt about a piece kept already stays)
        local old = {}
        for _, r in ipairs(st.pieces) do if r.e.valid and r.e.unit_number then old[r.e.unit_number] = r end end
        for i, r in ipairs(p.found) do p.found[i] = r.e.valid and old[r.e.unit_number] or r end
        st.pieces, st.count, st.pass, st.cap = p.found, p.count, nil, MAX_PIECES
      end
    end
    local keep = {}
    for _, r in ipairs(st.pieces) do if r.e.valid then keep[#keep+1] = r end end
    st.pieces = keep
    return keep
  end

  -- (batch224) The nest index: a job over the boxes of BOX x BOX chunks that a live piece's range reaches, one box a
  -- read, for the first surface whose index is missing or TARGET_EVERY old; the finished index {chunks (ckey -> nests),
  -- n, tick} replaces the surface's last.
  local function index_step(st, list, now, force)
    st.nests = st.nests or {}
    local job = st.ijob
    if job and not game.get_surface(job.surface) then job = nil end
    if not job then
      -- (a surface due first: the discs are read only then)
      local due
      for _, r in ipairs(list) do
        local idx = r.live and r.range and r.sname and st.nests[r.sname]
        if r.live and r.range and r.sname and (not idx or now - idx.tick >= TARGET_EVERY) and (not due or r.sname < due) then due = r.sname end
      end
      if not due then return end
      local by, names = {}, {due}
      for _, r in ipairs(list) do
        if r.live and r.range and r.sname == due then
          local sn = r.sname
          if not by[sn] then by[sn] = {} end
          local d = by[sn]
          d[#d+1] = {x=r.e.position.x, y=r.e.position.y, r=r.range}
        end
      end
      for _, sn in ipairs(names) do
        local idx = st.nests[sn]
        if not idx or now - idx.tick >= TARGET_EVERY then
          local l, t, rr, b
          for _, d in ipairs(by[sn]) do
            l, t = math.min(l or d.x - d.r, d.x - d.r), math.min(t or d.y - d.r, d.y - d.r)
            rr, b = math.max(rr or d.x + d.r, d.x + d.r), math.max(b or d.y + d.r, d.y + d.r)
          end
          local side, boxes = 32 * BOX, {}
          for bx = math.floor(l / side), math.floor(rr / side) do
            for byy = math.floor(t / side), math.floor(b / side) do
              local x0, y0 = bx * side, byy * side
              for _, d in ipairs(by[sn]) do
                local nx, ny = math.max(x0, math.min(d.x, x0 + side)), math.max(y0, math.min(d.y, y0 + side))
                if (nx - d.x) ^ 2 + (ny - d.y) ^ 2 <= d.r * d.r then boxes[#boxes+1] = {x0, y0}; break end
              end
            end
          end
          job = {surface=sn, boxes=boxes, i=1, list={}, seen={}}
          break
        end
      end
      st.ijob = job
      if not job then return end
    end
    local b, surface = job.boxes[job.i], game.get_surface(job.surface)
    if b and surface then
      local side = 32 * BOX
      for _, e in ipairs(try(function() return surface.find_entities_filtered{area={{b[1], b[2]}, {b[1] + side, b[2] + side}}, force='enemy', type=ENEMY} end) or {}) do
        local p = e.position
        local k = math.floor(p.x * 2) * 16777216 + math.floor(p.y * 2)
        if not job.seen[k] and #job.list < MAX_NESTS and
            try(function() return force.is_chunk_charted(surface, {x=math.floor(p.x / 32), y=math.floor(p.y / 32)}) end) ~= false then
          job.seen[k] = true
          job.list[#job.list+1] = {name=e.name, x=p.x, y=p.y}
        end
      end
    end
    job.i = job.i + 1
    if job.i > #job.boxes then
      local chunks = {}
      for _, n in ipairs(job.list) do
        local k = ckey(math.floor(n.x / 32), math.floor(n.y / 32))
        if not chunks[k] then chunks[k] = {} end
        local c = chunks[k]
        c[#c+1] = n
      end
      st.nests[job.surface] = {chunks=chunks, n=#job.list, tick=now}
      st.ijob = nil
    end
  end

  -- The nest on the ray from o along (ux, uy), at most reach on: {t, along, perp} or nil; the chunks every 16 tiles along
  -- it and their neighbours (a chunk the line clips, or within PERP of it, is one of them).
  local function nest_on_ray(idx, o, ux, uy, reach)
    if not idx or idx.n == 0 then return nil end
    local best, seen, s = nil, {}, 0
    while s <= reach + 16 do
      local cx, cy = math.floor((o.x + ux * s) / 32), math.floor((o.y + uy * s) / 32)
      for ox = -1, 1 do
        for oy = -1, 1 do
          local k = ckey(cx + ox, cy + oy)
          if not seen[k] then
            seen[k] = true
            for _, t in ipairs(idx.chunks[k] or {}) do
              local vx, vy = t.x - o.x, t.y - o.y
              local along = vx * ux + vy * uy
              local perp = math.abs(vx * uy - vy * ux)
              if along > 0 and along <= reach + PERP and perp <= PERP and
                  (not best or perp < best.perp - 0.5 or perp <= best.perp + 0.5 and along < best.along) then
                best = {t=t, along=along, perp=perp}
              end
            end
          end
        end
      end
      s = s + 16
    end
    return best
  end

  -- The nests of the index within a piece's range (its `targets`).
  local function in_range(idx, r)
    local n, pos = 0, r.e.position
    local hi, lo = r.range * r.range, r.min_range * r.min_range
    for _, c in pairs(idx.chunks) do
      for _, t in ipairs(c) do
        local d2 = (t.x - pos.x) ^ 2 + (t.y - pos.y) ^ 2
        if d2 <= hi and d2 >= lo then n = n + 1 end
      end
    end
    return n
  end

  -- The team's flare on the ray from o along (ux, uy): {t, along, perp} or nil.
  local function flare_on_ray(list, o, ux, uy)
    local best
    for _, t in ipairs(list or {}) do
      local vx, vy = t.x - o.x, t.y - o.y
      local along = vx * ux + vy * uy
      local perp = math.abs(vx * uy - vy * ux)
      if along > 0 and perp <= PERP and (not best or perp < best.perp - 0.5 or perp <= best.perp + 0.5 and along < best.along) then
        best = {t=t, along=along, perp=perp}
      end
    end
    return best
  end

  -- What stands round a target: "big-spitter-nest and 2 medium-worm-turret"
  local function around(list, t)
    local by, order = {}, {}
    for _, o in ipairs(list) do
      if o ~= t and (o.x - t.x) ^ 2 + (o.y - t.y) ^ 2 <= NEAR * NEAR then
        if not by[o.name] then by[o.name] = 0; order[#order+1] = o.name end
        by[o.name] = by[o.name] + 1
      end
    end
    local parts = {}
    for _, n in ipairs(order) do parts[#parts+1] = by[n] .. ' ' .. n end
    return #parts > 0 and table.concat(parts, ', ') or nil
  end

  -- What stands round a nest of the index (its chunk and the 8 round it).
  local function around_idx(idx, t)
    local list, cx, cy = {}, math.floor(t.x / 32), math.floor(t.y / 32)
    for ox = -1, 1 do
      for oy = -1, 1 do
        for _, o in ipairs(idx.chunks[ckey(cx + ox, cy + oy)] or {}) do list[#list+1] = o end
      end
    end
    return around(list, t)
  end

  -- The enemy spawner or worm at a flare's spot (within NEAR), once a flare: {name, x, y, around} or false.
  local function nest_at(f, surface)
    if f.nest == nil then
      local list = {}
      for _, t in ipairs(try(function() return surface.find_entities_filtered{position={x=f.x, y=f.y}, radius=NEAR, force='enemy', type={'unit-spawner', 'turret'}} end) or {}) do
        list[#list+1] = {name=t.name, x=t.position.x, y=t.position.y}
      end
      local best
      for _, t in ipairs(list) do
        local d = (t.x - f.x) ^ 2 + (t.y - f.y) ^ 2
        if not best or d < best.d then best = {t=t, d=d} end
      end
      f.nest = best and {name=best.t.name, x=best.t.x, y=best.t.y, around=around(list, best.t)} or false
    end
    return f.nest
  end

  -- A piece's row: {name, position, surface, shells, by (who loaded it, else its last user), auto, targets}.
  local function row_of(st, r, e, sname, ammo)
    local pos = e.position
    local loader = st.loaders[pkey(sname, pos)]
    local by = loader and loader.name or try(function() return e.last_user and e.last_user.name end)
    return {name=e.name, position={x=pos.x, y=pos.y}, surface=sname, shells=ammo, by=by,
      auto=try(function() return e.artillery_auto_targeting end), targets=r.in_range}
  end

  -- A shell seen twice: its heading, target, piece and landing -> a shell row (nil: no target on its path).
  local function resolve(st, list, fl, p, q, now)
    local d = math.sqrt((q.x - p.x) ^ 2 + (q.y - p.y) ^ 2)
    if d < 1 then return nil end
    local ux, uy = (q.x - p.x) / d, (q.y - p.y) / d
    local speed = d / (now - p.tick)
    -- its piece: the live one on the path behind it (within PERP + 2.5 of it), the nearest; else the one searched
    local piece, back
    for _, r in ipairs(list) do
      if r.sname == p.surface and r.live then
        local pos = r.e.position
        local vx, vy = pos.x - q.x, pos.y - q.y
        local along = -(vx * ux + vy * uy)
        if along > 0 and math.abs(vx * uy - vy * ux) <= PERP + 2.5 and (not back or along < back) then piece, back = r, along end
      end
    end
    if not piece then
      for _, r in ipairs(list) do if r.e.unit_number == p.unit then piece = r end end
    end
    if not piece then return nil end
    local e = piece.e
    local pos = e.position
    back = back or math.sqrt((q.x - pos.x) ^ 2 + (q.y - pos.y) ^ 2)
    local fhit = flare_on_ray(fl[p.surface], q, ux, uy)
    local hit = not fhit and nest_on_ray(st.nests and st.nests[p.surface], q, ux, uy, math.max(0, (piece.range or 224) - back))
    local t = fhit and fhit.t or hit and hit.t
    if not t then return nil end
    local along = (fhit or hit).along
    local eta = math.floor(along / speed + 0.5)
    local launch = now - back / speed
    local row = row_of(st, piece, e, p.surface, piece.ammo)
    local key = math.floor(t.x) .. ',' .. math.floor(t.y) .. '|' .. math.floor(launch / 30)
    local out = {key=key, piece=row, surface=p.surface, from={x=pos.x, y=pos.y}, at={x=q.x, y=q.y},
      distance=math.floor(back + along + 0.5), eta_ticks=eta, lands_tick=now + eta}
    if fhit then
      local nest = nest_at(t, e.surface)
      out.target = {name=nest and nest.name or nil, position={x=t.x, y=t.y}, around=nest and nest.around or nil}
      out.flare, out.by = {by=t.by, tick=t.tick}, t.by or row.by
    else
      out.target = {name=t.name, position={x=t.x, y=t.y}, around=around_idx(st.nests[p.surface], t)}
      out.by = row.by
    end
    piece.shot = math.max(piece.shot or 0, math.floor(launch))
    st.flying = st.flying or {}
    if #st.flying >= 64 then table.remove(st.flying, 1) end
    st.flying[#st.flying+1] = {x=q.x, y=q.y, ux=ux * speed, uy=uy * speed, tick=now, until_tick=now + eta, surface=p.surface}
    return out
  end

  -- A sighting already pending or followed (the same shell seen near another piece)?
  local function known(st, sname, q, now)
    for _, p in ipairs(st.pend or {}) do
      if p.surface == sname and (q.x - p.x) ^ 2 + (q.y - p.y) ^ 2 <= ((now - p.tick) * 1.1 + 3) ^ 2 then return true end
    end
    for _, f in ipairs(st.flying or {}) do
      local k = now - f.tick
      if f.surface == sname and (q.x - f.x - f.ux * k) ^ 2 + (q.y - f.y - f.uy * k) ^ 2 <= 9 then return true end
    end
    return false
  end

  -- The pending sightings followed up (each found again where a shell from it would be now), resolved into shells.
  local function follow_up(st, list, fl, now, shells)
    if not st.pend then return end
    local keep = {}
    for _, p in ipairs(st.pend) do
      local k = now - p.tick
      local surface = game.get_surface(p.surface)
      if k == 0 and surface then
        keep[#keep+1] = p
      elseif k > 0 and k <= FOLLOW and surface then
        local best
        for _, sh in ipairs(surface.find_entities_filtered{type='artillery-projectile', position={x=p.x, y=p.y}, radius=k * 1.05 + 3}) do
          local q = sh.position
          local miss = math.abs(math.sqrt((q.x - p.x) ^ 2 + (q.y - p.y) ^ 2) - k * p.speed)
          if miss <= 2 and (not best or miss < best.miss) then best = {q=q, miss=miss} end
        end
        local row = best and resolve(st, list, fl, p, best.q, now)
        if row then shells[#shells+1] = row end
      end
    end
    st.pend = #keep > 0 and keep or nil
    if st.flying then
      local fly = {}
      for _, f in ipairs(st.flying) do if now <= f.until_tick + 60 and now - f.tick <= FLY then fly[#fly+1] = f end end
      st.flying = #fly > 0 and fly or nil
    end
  end

  -- New sightings: on a surface whose shells used rose since the last read, SEARCH of its candidate pieces in turn.
  local function discover(st, force, cands, dt, now)
    st.used, st.rr = st.used or {}, st.rr or {}
    for sname, c in pairs(cands) do
      local surface = game.get_surface(sname)
      local stats = surface and try(function() return force.get_item_production_statistics(surface) end)
      local n = stats and try(function() return stats.get_output_count('artillery-shell') end)
      local was = st.used[sname]
      st.used[sname] = n
      local fired = n and was and n - was or 0
      local i, found = st.rr[sname] or 0, 0
      local radius = math.min(SHELL_R, dt + 8)
      -- a short gap (the barrage's pace, FAST): every candidate, a small find each; else SEARCH of them in turn
      for _ = 1, (radius <= FAST_R and #c or math.min(SEARCH, #c)) do
        if found >= fired then break end
        i = i % #c + 1
        local e = c[i].e
        for _, sh in ipairs(surface.find_entities_filtered{type='artillery-projectile', position=e.position, radius=radius}) do
          local q = sh.position
          if not known(st, sname, q, now) and #(st.pend or {}) < MAX_PEND then
            local speed = try(function() return sh.speed end)
            st.pend = st.pend or {}
            st.pend[#st.pend+1] = {x=q.x, y=q.y, tick=now, surface=sname, unit=e.unit_number, speed=(speed and speed > 0) and speed or 1}
            found = found + 1
          end
        end
      end
      st.rr[sname] = i
    end
  end

  -- args.pieces: every piece's row (else their count: the stream reads this twice a second during a barrage, and the
  -- rows were most of its reply's JSON); each shell carries its piece's row.
  function M.read(args)
    local st = store()
    local force = game.forces.player
    local now = game.tick
    local dt = st.last_tick and now - st.last_tick or SHELL_R
    st.last_tick = now
    local full = type(args) == 'table' and args.pieces
    local out, shells, armed, refreshed = {}, {}, 0, false
    local fl, waiting, kept = flares(st, now)
    local list = pieces(st, force)
    local cands = {}  -- surface -> the live pieces a shell may come from (armed, or with a team flare kept there)
    local cool = COOLDOWN / (1 + (try(function() return force.get_gun_speed_modifier('artillery-shell') end) or 0)) - 20
    for _, r in ipairs(list) do
      local e = r.e
      local inv = e.get_inventory(defines.inventory[INV[e.type]])
      local ammo = inv and inv.get_item_count() or 0
      if ammo < (r.ammo or 0) then r.fired = now end
      r.ammo = ammo
      local live = ammo > 0 or (r.fired and now - r.fired <= KEEP)
      r.live = live
      if r.targets then r.targets, r.targets_tick = nil, nil end  -- (batch224: the index replaced each piece's own list)
      if not r.sname then r.sname = e.surface.name end
      local sname = r.sname
      local idx = st.nests and st.nests[sname]
      -- one piece a read: its range and the index's nests within it, after the surface's index changed
      if live and not refreshed and (not r.range or (idx and r.in_tick ~= idx.tick)) then
        r.range, r.min_range = range_of(e)
        r.in_range, r.in_tick = idx and in_range(idx, r) or nil, idx and idx.tick or nil
        refreshed = true
      end
      if full then out[#out+1] = row_of(st, r, e, sname, ammo) end
      local auto = idx and r.range and (r.in_range or 0) > 0
      if ammo > 0 and auto then armed = armed + 1 end
      -- (a piece that fired is cooling down: no shell from it until then)
      if live and (auto or fl[sname]) and not (r.shot and now - r.shot < cool) then
        local c = cands[sname]
        if not c then c = {}; cands[sname] = c end
        c[#c+1] = r
      end
    end
    follow_up(st, list, fl, now, shells, full)
    discover(st, force, cands, dt, now)
    index_step(st, list, now, force)
    return {tick=now, pieces=full and out or #list, armed=armed, shells=shells, flares_waiting=waiting, flares_kept=kept,
      pending=st.pend and #st.pend or nil, every=(kept > 0 or st.pend) and FAST or armed > 0 and 0.5 or 10}
  end
  M.operator = {artillery_live=function(args) return M.read(args) end}
  return M
end
