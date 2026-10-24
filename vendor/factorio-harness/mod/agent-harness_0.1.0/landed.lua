-- Landed cargo pods (d17 pods, Nick 15:45: "a bunch of landed cargo drop ships on Vulcanus and Aquilo have just been
-- sitting there. Do the agents see those?"; on world n at 15:47 Vulcanus held 104 cargo-pod-containers with 10,059
-- items, every one older than its landing pad, Aquilo 7 with 3,351, Fulgora 12). A pod that lands with no pad to take
-- it becomes a cargo-pod-container on the ground (ours, 20 slots) until someone empties it, as a player sees it on the
-- map and opens it by hand.
-- - Found by a slow sweep (M.tick): every STEP ticks one SLICE x SLICE square of one planet, nearest (0,0) first, out to
--   RADIUS tiles, the planets in turn; containers and landing pads found are kept (their entities). A find over all of
--   Nauvis took 23.5 ms on world n, a 512-square round its base 13 ms, so no read looks at a whole planet.
-- - pods {surface?, position?}: each kept container's contents read now, the nearest to a position, the landing pads
--   and their free slots, and how far the sweep reaches and when it last went over that planet.
-- - status (landed_pods) and the team block (once an hour an agent, M.team_lines): a line a planet with any.
return function(api)
  local M = {}
  local STEP, SLICE, RADIUS, TEAM_EVERY, SHOW = 60, 128, 1024, 216000, 6
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function store()
    local s = api.state()
    s.landed = s.landed or {reg={}, pads={}, pass={}, sweep={planet=1, slice=1}}
    return s.landed
  end
  local function title(name) return (name:gsub('^%l', string.upper)) end
  local function at(q) return string.format('(%g,%g)', q.x, q.y) end
  local function thousands(n)
    local s = tostring(math.floor(n))
    while true do local k; s, k = s:gsub('^(%d+)(%d%d%d)', '%1,%2'); if k == 0 then return s end end
  end
  local function planets()
    local out = {}
    for _, s in pairs(game.surfaces) do
      if s.valid and not try(function() return s.platform end) then out[#out+1] = s end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
  end
  -- The sweep's squares, nearest (0,0) first (their left-top corners).
  local SLICES
  local function slices()
    if SLICES then return SLICES end
    SLICES = {}
    local n = RADIUS / SLICE
    for i = -n, n - 1 do
      for j = -n, n - 1 do SLICES[#SLICES+1] = {x=i * SLICE, y=j * SLICE, d=(i + 0.5) ^ 2 + (j + 0.5) ^ 2} end
    end
    table.sort(SLICES, function(a, b) if a.d ~= b.d then return a.d < b.d end if a.y ~= b.y then return a.y < b.y end return a.x < b.x end)
    return SLICES
  end
  -- One square looked at: containers and pads of ours there kept.
  function M.look_slice(surface, force, sq)
    local st = store()
    local reg = st.reg[surface.name] or {}
    st.reg[surface.name] = reg
    local pads = st.pads[surface.name] or {}
    st.pads[surface.name] = pads
    for _, e in ipairs(try(function() return surface.find_entities_filtered{area={{sq.x, sq.y}, {sq.x + SLICE, sq.y + SLICE}},
        name={'cargo-pod-container', 'cargo-landing-pad'}, force=force} end) or {}) do
      if e.valid and e.unit_number then
        if e.name == 'cargo-landing-pad' then pads[e.unit_number] = e else reg[e.unit_number] = e end
      end
    end
  end
  function M.tick(tick)
    if tick % STEP ~= 0 then return end
    local st = store()
    local list = planets()
    if #list == 0 then return end
    local sw = st.sweep
    if sw.planet > #list then sw.planet = 1 end
    local s = list[sw.planet]
    local sq = slices()[sw.slice]
    local okf, force = pcall(function() return game.forces.player end)
    if okf and sq then M.look_slice(s, force, sq) end
    sw.slice = sw.slice + 1
    if sw.slice > #slices() then
      st.pass[s.name] = tick
      sw.slice = 1; sw.planet = sw.planet + 1
    end
  end
  -- What is kept of a planet, read now: {surface, n, total, items, at [{x, y, count, entity}], pads, pass}
  function M.now(name)
    local st = store()
    local r = {surface=name, n=0, total=0, items={}, at={}, pads={}, pass=st.pass[name]}
    for k, e in pairs(st.reg[name] or {}) do
      if not e.valid then st.reg[name][k] = nil
      else
        local inv = try(function() return e.get_inventory(defines.inventory.chest) end)
        local n = 0
        for _, c in ipairs(inv and try(function() return inv.get_contents() end) or {}) do r.items[c.name] = (r.items[c.name] or 0) + c.count; n = n + c.count end
        r.n = r.n + 1; r.total = r.total + n
        r.at[#r.at+1] = {x=e.position.x, y=e.position.y, count=n, entity=e}
      end
    end
    for k, pad in pairs(st.pads[name] or {}) do
      if not pad.valid then st.pads[name][k] = nil
      else
        local inv = try(function() return pad.get_inventory(defines.inventory.cargo_landing_pad_main) end)
        r.pads[#r.pads+1] = {position={x=pad.position.x, y=pad.position.y}, free=inv and try(function() return inv.count_empty_stacks(true, false) end), slots=inv and #inv}
      end
    end
    table.sort(r.at, function(a, b) if a.y ~= b.y then return a.y < b.y end return a.x < b.x end)
    return r
  end
  local function nearest(r, pos)
    local best, bd
    for _, q in ipairs(r.at) do
      local d = (q.x - pos.x) ^ 2 + (q.y - pos.y) ^ 2
      if not bd or d < bd then best, bd = q, d end
    end
    return best, best and math.floor(math.sqrt(bd) + 0.5)
  end
  -- "Vulcanus: 104 landed cargo pods hold 10,059 items (iron-plate 3283, ...); nearest (3.5,5.5), 7 tiles; landing pad (12,176) 80 of 80 slots free"
  function M.line(r, pos)
    if r.n == 0 then return nil end
    local list = {}
    for name, n in pairs(r.items) do list[#list+1] = {name, n} end
    table.sort(list, function(a, b) if a[2] ~= b[2] then return a[2] > b[2] end return a[1] < b[1] end)
    local parts = {}
    for i, x in ipairs(list) do if i <= SHOW then parts[#parts+1] = x[1] .. ' ' .. x[2] end end
    local near, d = nil, nil
    if pos then near, d = nearest(r, pos) end
    local pads = {}
    for _, pd in ipairs(r.pads) do pads[#pads+1] = string.format('landing pad %s %s of %s slots free', at(pd.position), tostring(pd.free), tostring(pd.slots)) end
    return string.format('%s: %d landed cargo pod%s hold %s items (%s%s)%s%s', title(r.surface), r.n, r.n == 1 and '' or 's', thousands(r.total),
      table.concat(parts, ', '), #list > SHOW and ', ...' or '',
      near and string.format('; nearest %s, %d tiles', at(near), d) or string.format('; one at %s', at(r.at[1])),
      #pads > 0 and '; ' .. table.concat(pads, '; ') or '; no landing pad')
  end
  local function coverage(r)
    return string.format('the sweep looks within %d tiles of (0,0)%s', RADIUS,
      r.pass and string.format(', last over %s %d min ago', title(r.surface), math.floor((game.tick - r.pass) / 3600)) or string.format(' and has not been over all of %s yet', title(r.surface)))
  end

  -- pods {surface?, position?}
  function M.read(p, a)
    a = a or {}
    -- (d20 batch62 X2, Sol #1529) a surface name that is no surface is refused, never read as yours
    local surface = p.surface
    if a.surface ~= nil then surface = type(a.surface) == 'string' and game.get_surface(a.surface); assert(surface, 'no surface named ' .. tostring(a.surface)) end
    assert(surface and not try(function() return surface.platform end), 'surface: a planet (nauvis, vulcanus, gleba, fulgora, aquilo)')
    local r = M.now(surface.name)
    local pos = a.position and api.position(a.position) or (surface == p.surface and p.position or nil)
    local near, d = nil, nil
    if pos then near, d = nearest(r, pos) end
    local others = {}
    for _, s in ipairs(planets()) do
      if s.name ~= surface.name then
        local o = M.now(s.name)
        if o.n > 0 then others[#others+1] = M.line(o) end
      end
    end
    local list = {}
    for i, q in ipairs(r.at) do if i <= 64 then list[i] = {position={x=q.x, y=q.y}, holds=q.count} end end
    return {surface=surface.name, containers=r.n, items=r.items, total=r.total, nearest=near and {position={x=near.x, y=near.y}, holds=near.count, distance=d} or nil,
      pads=r.pads, at=#list > 0 and list or nil, line=M.line(r, pos) or string.format('%s: no landed cargo pod found', title(surface.name)),
      coverage=coverage(r), other_planets=#others > 0 and others or nil,
      note='a cargo-pod-container is where a pod landed with no landing pad to take it; collect {pods: true} walks them and takes what they hold'}
  end
  -- Kept containers on a surface (collect {pods}), nearest to pos first: entities.
  function M.containers(surface, pos, area)
    local r = M.now(surface.name)
    local out = {}
    for _, q in ipairs(r.at) do
      local e = q.entity
      if q.count > 0 and (not area or (q.x >= area[1][1] and q.x <= area[2][1] and q.y >= area[1][2] and q.y <= area[2][2])) then out[#out+1] = e end
    end
    table.sort(out, function(x, y) return (x.position.x - pos.x) ^ 2 + (x.position.y - pos.y) ^ 2 < (y.position.x - pos.x) ^ 2 + (y.position.y - pos.y) ^ 2 end)
    return out, r
  end
  -- What status says: a line a planet with containers (nearest from you on your surface).
  function M.status_lines(p)
    local out = {}
    for _, s in ipairs(planets()) do
      local r = M.now(s.name)
      if r.n > 0 then out[#out+1] = M.line(r, s == p.surface and p.position or nil) end
    end
    return #out > 0 and out or nil
  end
  -- The team block, once an hour an agent (h: its board memory).
  function M.team_lines(p, h)
    if h.pods_told and game.tick - h.pods_told < TEAM_EVERY then return nil end
    local lines = M.status_lines(p)
    if not lines then return nil end
    h.pods_told = game.tick
    return lines
  end
  M.schema = {pods = {surface='optional planet (default yours)', position='optional {x,y}: nearest to it (default you, on your surface)',
    returns='line (Vulcanus: N landed cargo pods hold N items (by item); nearest (x,y), D tiles; landing pad (x,y) F of S slots free), containers, total, items {name=count}, nearest {position, holds, distance}, at (up to 64 {position, holds}), pads [{position, free, slots}], coverage (how far the sweep looks and when it last went over the planet), other_planets; read only. collect {pods: true} empties them'}}
  return M
end
