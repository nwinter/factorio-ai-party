-- library_areas (operator read for the live map; d21 batch68 AD2, viewer Aurora, d20 18:33 and d21 09:45: "could
-- installed blueprint areas show tested revision, required hookups and last check, with failed or unverified hookups on
-- every planet's map?"). The team library's placements the harness remembers (checks.lua: blueprint_place {name}, the
-- last PLACEMENTS of a name), newest first, one per name and spot, at most MAX_AREAS: each with the entry's facts (its
-- description's start, its retire mark, the save that was placed and whether it was saved again since), the newest
-- blueprint check over it (checks.lua: pass, fail, stale or not run), and its hookups as the world shows them now at the
-- area's edge:
-- - belts: a belt (or underground's exit or entrance) whose next tile is outside the area: fed into or fed from a
--   belt outside, or not (its line ends at the edge; no belt outside feeds it);
-- - pipes: a fluid connection of a building in the area to a tile outside it: joined to something there, or open;
-- - inserters: one reaching outside the area: what it takes from or drops into there, or nothing;
-- - power: the area's poles wired to poles outside, and its machines on no or low power now;
-- and how many of our entities stand in it built (n) and as ghosts (g).
-- Hookups are read for HOOK_PER_READ areas a read (the ones read longest ago first; one find over each area, at most
-- MAX_FIND of ours), kept with their tick (as_of), so a read costs a few areas' finds. Read only.
return function(api)
  local M = {}
  M.MAX_AREAS, M.HOOK_PER_READ, M.MAX_FIND, M.MAX_OPEN, M.MAX_SIDE = 48, 2, 1500, 4, 200
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function store()
    local s = api.state()
    s.library_areas = s.library_areas or {hooks={}}
    return s.library_areas
  end
  local DIR = {[0]={0, -1}, [4]={1, 0}, [8]={0, 1}, [12]={-1, 0}}
  local BELT = {['transport-belt']=true, ['underground-belt']=true}
  local FLUID = {pipe=true, ['pipe-to-ground']=true, pump=true, ['storage-tank']=true, ['assembling-machine']=true, furnace=true,
    boiler=true, generator=true, ['mining-drill']=true, ['offshore-pump']=true, ['fusion-reactor']=true, ['fusion-generator']=true,
    thruster=true, ['fluid-turret']=true, reactor=true, ['rocket-silo']=true, valve=true}
  local POWERED = {['assembling-machine']=true, furnace=true, inserter=true, ['mining-drill']=true, lab=true, pump=true, radar=true,
    roboport=true, beacon=true, ['electric-turret']=true, ['rocket-silo']=true, ['agricultural-tower']=true, lamp=true,
    ['asteroid-collector']=true}
  local function key_of(name, rec)
    local b = rec.box
    return string.format('%s|%d|%d,%d,%d,%d', name, rec.surface, math.floor(b.l), math.floor(b.t), math.floor(b.r), math.floor(b.b))
  end
  -- The hookups of an area now: counts and the first MAX_OPEN open ones.
  function M.hookups(surface, force, b)
    local function inside(x, y) return x > b.l and x < b.r and y > b.t and y < b.b end
    -- only what stands within m tiles of the edge can reach across it (a dense area read every belt's neighbours: 11 ms
    -- for 448 belts on the private copy)
    local function near(x, y, m) return x - b.l < m or b.r - x < m or y - b.t < m or b.b - y < m end
    local list = surface.find_entities_filtered{area={{b.l - 0.5, b.t - 0.5}, {b.r + 0.5, b.b + 0.5}}, force=force, limit=M.MAX_FIND + 1}
    if #list > M.MAX_FIND then return {capped=M.MAX_FIND, t=game.tick} end
    local h = {b={0, 0, 0, 0}, p={0, 0}, i={0, 0, 0, 0}, e={0, 0, 0, 0}, g=0, n=0, open={}, t=game.tick}
    local function open(x, y, what) if #h.open < M.MAX_OPEN then h.open[#h.open+1] = {math.floor(x * 2 + 0.5) / 2, math.floor(y * 2 + 0.5) / 2, what} end end
    local poles = {}
    for _, e in ipairs(list) do
      if e.valid and inside(e.position.x, e.position.y) then
        local t, x, y = e.type, e.position.x, e.position.y
        if t == 'entity-ghost' then h.g = h.g + 1 else h.n = h.n + 1 end
        if BELT[t] and near(x, y, 1.5) then
          local d = DIR[e.direction or 0]
          local ut = t == 'underground-belt' and try(function() return e.belt_to_ground_type end)
          if d then
            local nb = try(function() return e.belt_neighbours end) or {}
            local function outside_of(l) for _, o in ipairs(l or {}) do if o.valid and not inside(o.position.x, o.position.y) then return o end end end
            if ut ~= 'input' and not inside(x + d[1], y + d[2]) then
              if outside_of(nb.outputs) then h.b[3] = h.b[3] + 1 else h.b[4] = h.b[4] + 1; open(x, y, 'belt out: ends at the edge') end
            end
            if ut ~= 'output' and not inside(x - d[1], y - d[2]) then
              if outside_of(nb.inputs) then h.b[1] = h.b[1] + 1 else h.b[2] = h.b[2] + 1; open(x, y, 'belt in: no belt outside feeds it') end
            end
          end
        elseif t == 'inserter' and near(x, y, 3) then
          local pp, dp = try(function() return e.pickup_position end), try(function() return e.drop_position end)
          if pp and not inside(pp.x, pp.y) then
            if try(function() return e.pickup_target end) then h.i[1] = h.i[1] + 1 else h.i[2] = h.i[2] + 1; open(x, y, 'inserter in: takes from nothing outside') end
          end
          if dp and not inside(dp.x, dp.y) then
            if try(function() return e.drop_target end) then h.i[3] = h.i[3] + 1 else h.i[4] = h.i[4] + 1; open(x, y, 'inserter out: drops onto the ground outside') end
          end
        elseif t == 'electric-pole' then poles[#poles+1] = e end
        if FLUID[t] and near(x, y, t == 'pipe-to-ground' and 11 or 6) then
          local fb = e.fluidbox
          for i = 1, (try(function() return #fb end) or 0) do
            for _, pc in ipairs(try(function() return fb.get_pipe_connections(i) end) or {}) do
              local q = pc.target_position
              if q and not inside(q.x, q.y) then
                if pc.target then h.p[1] = h.p[1] + 1
                else
                  h.p[2] = h.p[2] + 1
                  local f = try(function() return fb[i] end)
                  open(x, y, 'pipe: open to the outside' .. (f and ' (holds ' .. f.name .. ')' or ''))
                end
              end
            end
          end
        end
        if POWERED[t] then
          local st = try(function() return e.status end)
          if st == defines.entity_status.no_power then h.e[3] = h.e[3] + 1 elseif st == defines.entity_status.low_power then h.e[4] = h.e[4] + 1 end
        end
      end
    end
    h.e[1] = #poles
    for _, pole in ipairs(poles) do
      local wc = try(function() return pole.get_wire_connector(defines.wire_connector_id.pole_copper, false) end)
      for _, c in ipairs(wc and try(function() return wc.connections end) or {}) do
        local o = try(function() return c.target.owner end)
        if o and o.valid and not inside(o.position.x, o.position.y) then h.e[2] = h.e[2] + 1 end
      end
    end
    return h
  end
  -- {areas = [...], placements, tick}; args.hookups: how many areas' hookups to read now (0..4, default HOOK_PER_READ).
  function M.read(args)
    args = type(args) == 'table' and args or {}
    local n_hook = args.hookups == nil and M.HOOK_PER_READ or math.max(0, math.min(4, math.floor(tonumber(args.hookups) or 0)))
    local s = api.state()
    local placements = s.checks and s.checks.placements or {}
    local lib = s.bplibrary and s.bplibrary.entries or {}
    local all, seen = {}, {}
    for name, list in pairs(placements) do
      for i = #list, 1, -1 do
        local rec = list[i]
        -- (a placement on a surface since deleted is left out: nothing stands there)
        local k = rec.box and rec.surface and game.get_surface(rec.surface) and key_of(name, rec)
        if k and not seen[k] then seen[k] = true; all[#all+1] = {name=name, rec=rec, key=k} end
      end
    end
    table.sort(all, function(x, y) if x.rec.tick ~= y.rec.tick then return x.rec.tick > y.rec.tick end return x.key < y.key end)
    local total = #all
    while #all > M.MAX_AREAS do table.remove(all) end
    local st = store()
    local keep = {}
    for _, a in ipairs(all) do keep[a.key] = st.hooks[a.key] end
    st.hooks = keep
    -- the areas read longest ago (or never) first
    local order = {}
    for _, a in ipairs(all) do order[#order+1] = a end
    table.sort(order, function(x, y)
      local tx, ty = st.hooks[x.key] and st.hooks[x.key].t or -1, st.hooks[y.key] and st.hooks[y.key].t or -1
      if tx ~= ty then return tx < ty end
      return x.key < y.key
    end)
    local force = game.forces.player
    for i = 1, math.min(n_hook, #order) do
      local a = order[i]
      local surface = game.get_surface(a.rec.surface)
      local b = a.rec.box
      if surface and b.r - b.l <= M.MAX_SIDE and b.b - b.t <= M.MAX_SIDE then
        local ok, h = pcall(M.hookups, surface, force, b)
        st.hooks[a.key] = ok and h or {error=tostring(h):sub(1, 120), t=game.tick}
      else
        st.hooks[a.key] = {gone=not surface or nil, too_big=surface and M.MAX_SIDE or nil, t=game.tick}
      end
    end
    local rows = {}
    for _, a in ipairs(all) do
      local rec, e = a.rec, lib[a.name]
      local surface = game.get_surface(rec.surface)
      local b = rec.box
      local row = {name=a.name, surface=surface and surface.name or nil, box={b.l, b.t, b.r, b.b}, tick=rec.tick, by=rec.by,
        entities=rec.count, hookups=st.hooks[a.key]}
      if e then
        row.description = e.description and (#e.description > 80 and e.description:sub(1, 77) .. '...' or e.description) or nil
        row.saved_tick = e.saved_tick
        -- the save that was placed: placements kept since d21 batch68 carry it; older ones read unknown
        row.placed_save = rec.saved_tick
        if e.retired then row.retired = {by=e.retired.by, reason=e.retired.reason and e.retired.reason:sub(1, 80), replaced_by=e.retired.replaced_by, tick=e.retired.tick} end
      else row.deleted = true end
      row.check = api.check_state and api.check_state(a.name, rec.surface, b) or nil
      rows[#rows+1] = row
    end
    return {tick=game.tick, areas=rows, placements=total, shown=#rows, hookups_read=math.min(n_hook, #order)}
  end
  M.operator = {library_areas=function(args) return M.read(args) end}
  return M
end
