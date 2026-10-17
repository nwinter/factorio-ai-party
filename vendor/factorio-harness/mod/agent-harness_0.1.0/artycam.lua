-- artillery_live (operator read for the stream; d17 artycam, viewer Foobator 12:48: "if there is only one arty shell
-- in flight and nothing else interesting has happened, can you show the impact on screen"): our artillery pieces and
-- the shells they have just fired, each with its target and when it lands, for the director to cut to the target
-- before the shell comes down.
-- - A shell leaves at 1 tile a tick (artillery-shell's starting_speed on 2.0.77, no range or direction deviation), so
--   it is up at most range / 60 s (224 tiles: 3.7 s). The stream service reads this every half second while a piece
--   is loaded with targets in range (`every`), else every 10 s.
-- - Pieces (turrets, wagons) are found once and kept; a change in the force's count of them finds them again, one
--   surface a read (a whole-surface find on world n's Nauvis took 11 ms). A shell is found within SHELL_R tiles of a
--   loaded piece (how far one flies between reads, a find of a few chunks; one over the whole range took 4.3 ms).
-- - Its target: the enemy spawner or worm on the line from the piece through the shell (within PERP tiles of it, past
--   the shell; the nearest such), from the piece's targets read every TARGET_EVERY ticks (charted chunks, as the
--   artillery read). A shell with none on its line (a flare's spot, a unit) is left out.
-- - Who: the agent who last put shells into the piece by hand (hauling.lua's moves, M.put), else the piece's
--   last_user.
return function(api)
  local M = {}
  local TYPES = {'artillery-turret', 'artillery-wagon'}
  local INV = {['artillery-turret']='artillery_turret_ammo', ['artillery-wagon']='artillery_wagon_ammo'}
  local SHELL_R, TARGET_EVERY, PERP, NEAR, MAX_PIECES, MAX_TARGETS, KEEP = 48, 3600, 2.5, 6, 16, 400, 600
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function store()
    local s = api.state()
    s.artycam = s.artycam or {pieces={}, count=-1, loaders={}, seen={}}
    return s.artycam
  end
  local function pkey(surface, pos) return surface .. '|' .. math.floor(pos.x) .. ',' .. math.floor(pos.y) end
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

  -- The pieces: a pass over the surfaces, one a read, when the count changed.
  local function pieces(st, force)
    local n = count(force)
    if n ~= st.count and not st.pass then
      local list = {}
      for _, s in pairs(game.surfaces) do list[#list+1] = s.name end
      table.sort(list)
      st.pass = {surfaces=list, i=1, found={}, count=n}
    end
    if st.pass then
      local p = st.pass
      local s = game.get_surface(p.surfaces[p.i] or '')
      if s then
        for _, e in ipairs(try(function() return s.find_entities_filtered{type=TYPES, force=force} end) or {}) do
          if #p.found < MAX_PIECES then p.found[#p.found+1] = {e=e} end
        end
      end
      p.i = p.i + 1
      if p.i > #p.surfaces then
        -- (what was learnt about a piece kept already stays)
        local old = {}
        for _, r in ipairs(st.pieces) do if r.e.valid and r.e.unit_number then old[r.e.unit_number] = r end end
        for i, r in ipairs(p.found) do p.found[i] = r.e.valid and old[r.e.unit_number] or r end
        st.pieces, st.count, st.pass = p.found, p.count, nil
      end
    end
    local keep = {}
    for _, r in ipairs(st.pieces) do if r.e.valid then keep[#keep+1] = r end end
    st.pieces = keep
    return keep
  end

  local function targets(r, e)
    local range, min_range = 224, 0
    if api.range then range, min_range = api.range(e) end
    local list = {}
    local surface, force, pos = e.surface, e.force, e.position
    for _, t in ipairs(try(function() return surface.find_entities_filtered{position=pos, radius=range, force='enemy', type={'unit-spawner', 'turret'}} end) or {}) do
      if #list >= MAX_TARGETS then break end
      local d = math.sqrt((t.position.x - pos.x) ^ 2 + (t.position.y - pos.y) ^ 2)
      if d >= min_range and try(function() return force.is_chunk_charted(surface, {x=math.floor(t.position.x / 32), y=math.floor(t.position.y / 32)}) end) ~= false then
        list[#list+1] = {name=t.name, x=t.position.x, y=t.position.y}
      end
    end
    r.targets, r.targets_tick = list, game.tick
  end

  -- The target on the line from pos through q (a shell d tiles out): {t, along, perp} or nil.
  local function on_line(list, pos, q, d)
    local ux, uy = (q.x - pos.x) / d, (q.y - pos.y) / d
    local best
    for _, t in ipairs(list) do
      local vx, vy = t.x - pos.x, t.y - pos.y
      local along = vx * ux + vy * uy
      local perp = math.abs(vx * uy - vy * ux)
      if along > d and perp <= PERP and (not best or perp < best.perp - 0.5 or perp <= best.perp + 0.5 and along < best.along) then
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

  function M.read(args)
    local st = store()
    local force = game.forces.player
    local now = game.tick
    local dt = st.last_tick and now - st.last_tick or SHELL_R
    st.last_tick = now
    local out, shells, armed, refreshed = {}, {}, 0, false
    for _, r in ipairs(pieces(st, force)) do
      local e = r.e
      local inv = try(function() return e.get_inventory(defines.inventory[INV[e.type]]) end)
      local ammo = inv and try(function() return inv.get_item_count() end) or 0
      if ammo < (r.ammo or 0) then r.fired = now end
      r.ammo = ammo
      local live = ammo > 0 or (r.fired and now - r.fired <= KEEP)
      if live and not refreshed and (not r.targets or now - r.targets_tick >= TARGET_EVERY) then
        targets(r, e); refreshed = true
      end
      local pos, sname = e.position, e.surface.name
      local loader = st.loaders[pkey(sname, pos)]
      local by = loader and loader.name or try(function() return e.last_user and e.last_user.name end)
      local row = {name=e.name, position={x=pos.x, y=pos.y}, surface=sname, shells=ammo, by=by,
        auto=try(function() return e.artillery_auto_targeting end), targets=r.targets and #r.targets or nil}
      out[#out+1] = row
      if ammo > 0 and r.targets and #r.targets > 0 then armed = armed + 1 end
      if live and r.targets and #r.targets > 0 then
        local radius = math.min(SHELL_R, dt + 8)
        for _, sh in ipairs(try(function() return e.surface.find_entities_filtered{type='artillery-projectile', position=pos, radius=radius} end) or {}) do
          local q = sh.position
          local d = math.sqrt((q.x - pos.x) ^ 2 + (q.y - pos.y) ^ 2)
          local speed = try(function() return sh.speed end)
          if not speed or speed <= 0 then speed = 1 end
          local hit = d >= 2 and on_line(r.targets, pos, q, d)
          if hit then
            local key = (e.unit_number or pkey(sname, pos)) .. '|' .. math.floor(hit.t.x) .. ',' .. math.floor(hit.t.y) .. '|' .. math.floor((now - d / speed) / 30)
            local eta = math.floor((hit.along - d) / speed + 0.5)
            shells[#shells+1] = {key=key, piece=row, surface=sname, from={x=pos.x, y=pos.y}, at={x=q.x, y=q.y},
              target={name=hit.t.name, position={x=hit.t.x, y=hit.t.y}, around=around(r.targets, hit.t)},
              distance=math.floor(hit.along + 0.5), eta_ticks=eta, lands_tick=now + eta, by=by}
          end
        end
      end
    end
    return {tick=now, pieces=out, armed=armed, shells=shells, every=armed > 0 and 0.5 or 10}
  end
  M.operator = {artillery_live=function(args) return M.read(args) end}
  return M
end
