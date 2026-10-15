-- Production credited to the agent who built the machine (Nick 15:50: "attribute production fairly to agents who
-- make machines ... that then later produce a lot over time"; viewers Enginerd, Foobator: automation over hand work).
-- Who built it: LuaEntity.last_user is nil for the agents' builds (bots have no player; world n, 2026-10-14: every
-- machine read had none), so the harness keeps its own build log: a machine an agent builds by hand (build, and
-- construct's revives) by its unit number and its spot, a ghost an agent places (place_ghosts, the routes, paste,
-- blueprint_place) by its spot, so a robot's build of it is the planner's. Machines built before the log are
-- credited once an operator seed names them (efficiency_seed: tools/efficiency_seed.py reads the agents' journals),
-- else they are counted as built before the count. A machine rebuilt by someone else is a new unit: theirs.
-- What it made: a crafting machine (assembler, furnace, chemical plant, foundry, rocket silo, ...) by its own
-- counter, products_finished (crafts since built) times the recipe's item products, at first sight in full; a
-- mining drill and a lab have no such counter, so their output is estimated from the time they were seen working
-- (drill: its mining rate on its resource; lab: the running research's units at its speed), marked "about".
-- Read incrementally: one 128-tile block of one surface every other tick, at most PER_TICK machines a tick, so a
-- pass over a base takes seconds and never scans a surface in one tick. A read for the operator (efficiency), one
-- line for the agent's 2-hour review. Facts only.
return function(api)
  local M = {}
  local BLOCK, BLOCK_EVERY, PER_TICK = 128, 2, 48
  local START_EXTENT, PLATFORM_EXTENT, MAX_EXTENT = 8, 2, 32   -- blocks from (0,0) each way
  local MAX_KEYS, TOP_ITEMS = 40000, 5
  local TYPES = {'assembling-machine', 'furnace', 'rocket-silo', 'mining-drill', 'lab'}
  local TYPE_SET = {}
  for _, t in ipairs(TYPES) do TYPE_SET[t] = true end
  local CRAFTING = {['assembling-machine']=true, furnace=true, ['rocket-silo']=true}
  local BEFORE = 'built before the count'
  local queue, qi = {}, 1   -- the last block's machines, PER_TICK a tick (entities: not kept in storage)
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function st()
    local s = api.state()
    local e = s.efficiency
    if not e then
      e = {keys={}, nkeys=0, units={}, machines={}, agents={}, since=game.tick,
        walk={pass=1, surfaces=nil, si=1, i=0, extent={}, started=game.tick}}
      s.efficiency = e
    end
    return e
  end
  local function shift()
    local s = api.state().shift
    return s and s.seq or 0, s and s.tick or 0
  end
  local function key(surface, name, pos) return surface .. '|' .. name .. '|' .. math.floor(pos.x) .. '|' .. math.floor(pos.y) end
  local function credited_type(name)
    local p = prototypes.entity[name]
    return p and TYPE_SET[p.type] or false
  end

  -- An agent's record; its shift numbers start over when a shift starts (research.lua's shift seq).
  local function rec(name)
    local E = st()
    local a = E.agents[name]
    if not a then
      a = {items=0, crafts=0, ore=0, units=0, by_item={}, machines=0, running=0, built=0}
      E.agents[name] = a
    end
    local seq = shift()
    if a.seq ~= seq then
      a.seq = seq
      a.shift_items, a.shift_ore, a.shift_units = 0, 0, 0
      a.hand_base = api.hand_items and api.hand_items(name) or 0
    end
    return a
  end
  M.rec = rec

  -- Build log -------------------------------------------------------------------------------------------------
  local function default_extent(surface)
    local s = try(function() return game.get_surface(surface) end)
    return (s and s.platform) and PLATFORM_EXTENT or START_EXTENT
  end
  M.default_extent = default_extent
  -- A machine logged outside the square walked: the square grows to reach it (next pass).
  local function grow(surface, pos)
    local E = st()
    local b = math.max(math.abs(math.floor(pos.x / BLOCK)), math.abs(math.floor(pos.y / BLOCK))) + 1
    if b > (E.walk.extent[surface] or default_extent(surface)) then E.walk.extent[surface] = math.min(MAX_EXTENT, b) end
  end
  local function put_key(k, who, tick)
    local E = st()
    local old = E.keys[k]
    if old and old.t > tick then return end
    if not old then E.nkeys = E.nkeys + 1 end
    E.keys[k] = {a=who, t=tick}
    if E.nkeys > MAX_KEYS then
      -- the oldest half goes (the machines already seen keep their builder)
      local ts = {}
      for _, v in pairs(E.keys) do ts[#ts+1] = v.t end
      table.sort(ts)
      local cut = ts[math.floor(#ts / 2)]
      for kk, v in pairs(E.keys) do if v.t <= cut then E.keys[kk] = nil; E.nkeys = E.nkeys - 1 end end
    end
  end
  local builder
  -- A machine an agent built by hand (the entity) or a ghost it placed (planned machine). revived: built from a
  -- ghost, which stays its planner's when the log has one.
  function M.built(who, e, revived)
    if not (who and e and e.valid) then return end
    local ghost = e.type == 'entity-ghost'
    local name = ghost and e.ghost_name or e.name
    if not credited_type(name) then return end
    local surface = e.surface.name
    if revived then who = builder(e) or who end
    put_key(key(surface, name, e.position), who, game.tick)
    if not ghost and e.unit_number then
      local E = st()
      E.units[e.unit_number] = {a=who, t=game.tick}
      rec(who).built = rec(who).built + 1
    end
    grow(surface, e.position)
  end
  -- Who built it: by unit, else by spot on its surface (or a seed's spot with no surface), searched over its
  -- footprint (a seed's spot may be any tile of it).
  builder = function(e)
    local E = st()
    local u = e.unit_number and E.units[e.unit_number]
    if u then return u.a, u.t end
    local r = math.floor(math.max(1, (try(function() local b = e.prototype.collision_box; return b.right_bottom.x - b.left_top.x end) or 1)) / 2)
    local best
    for _, surface in ipairs({e.surface.name, '*'}) do
      for dx = -r, r do
        for dy = -r, r do
          local v = E.keys[key(surface, e.name, {x=e.position.x + dx, y=e.position.y + dy})]
          if v and (not best or v.t > best.t) then best = v end
        end
      end
      if best then return best.a, best.t end
    end
  end

  -- Credit ----------------------------------------------------------------------------------------------------
  local per_craft = {}
  local function products(recipe)
    local c = per_craft[recipe]
    if c == nil then
      local n, main = 0, nil
      for _, p in ipairs(try(function() return prototypes.recipe[recipe].products end) or {}) do
        if p.type == 'item' then
          local amount = p.amount or (((p.amount_min or 0) + (p.amount_max or 0)) / 2)
          n = n + amount * (p.probability or 1) + (p.extra_count_fraction or 0)
          main = main or p.name
        end
      end
      c = {n=n, main=main}
      per_craft[recipe] = c
    end
    return c
  end
  M.products = products
  local function recipe_of(e)
    local r = try(function() local x = e.get_recipe(); return x and x.name end)
    if r then return r end
    return try(function()
      local x = e.previous_recipe
      local n = x and x.name
      return type(n) == 'string' and n or (n and n.name)
    end)
  end
  local function add_item(a, item, n)
    if not item or n <= 0 then return end
    a.by_item[item] = (a.by_item[item] or 0) + n
  end
  -- n items (crafts * products) to the machine's builder; this_shift: counts toward the shift too.
  local function credit(m, crafts, recipe, this_shift)
    if crafts <= 0 or not recipe then return end
    local c = products(recipe)
    local n = crafts * c.n
    local a = rec(m.a or BEFORE)
    a.crafts = a.crafts + crafts
    a.items = a.items + n
    m.c = (m.c or 0) + n
    if this_shift then a.shift_items = a.shift_items + n end
    add_item(a, c.main, n)
  end
  -- A drill's items a second on its resource (none for a fluid), a lab's research units a second.
  local function drill_rate(e)
    return try(function()
      local res = e.mining_target
      if not res then return 0 end
      local mp = res.prototype.mineable_properties
      for _, p in ipairs(mp.products or {}) do if p.type == 'fluid' then return 0 end end
      return e.prototype.mining_speed * (1 + (e.speed_bonus or 0)) * (1 + (e.productivity_bonus or 0)) / mp.mining_time
    end) or 0
  end
  local function lab_rate(e)
    return try(function()
      local r = e.force.current_research
      if not r then return 0 end
      local speed = e.prototype.get_researching_speed() * (1 + e.force.laboratory_speed_modifier) * (1 + (e.speed_bonus or 0))
      return speed / (r.research_unit_energy / 60)
    end) or 0
  end
  local WORKING = defines.entity_status and defines.entity_status.working
  local function visit(e, tally)
    if not (e and e.valid and e.unit_number) then return end
    local E = st()
    local u, now = e.unit_number, game.tick
    local m = E.machines[u]
    local kind = CRAFTING[e.type] and 'craft' or (e.type == 'mining-drill' and 'drill' or 'lab')
    local _, shift_tick = shift()
    if not m then
      local by, t = builder(e)
      m = {a=by or false, k=kind, built=t or now, seen=now}
      E.machines[u] = m
      if kind == 'craft' then
        local pf = try(function() return e.products_finished end) or 0
        m.pf = pf
        m.r = recipe_of(e)
        -- its crafts since built, in full; the shift's share only when it was built this shift
        credit(m, pf, m.r, m.built >= shift_tick and t ~= nil)
      end
    else
      -- a builder named since (an operator seed): its credit so far moves to them
      if not m.a then
        local by = builder(e)
        if by then
          local old, new = rec(BEFORE), rec(by)
          old.items = math.max(0, old.items - (m.c or 0)); new.items = new.items + (m.c or 0)
          m.a = by
        end
      end
      if kind == 'craft' then
        local pf = try(function() return e.products_finished end) or 0
        local d = pf - (m.pf or 0)
        if d < 0 then d = pf end
        m.pf = pf
        local r = recipe_of(e) or m.r
        m.r = r
        credit(m, d, r, true)
      elseif m.w then
        -- an estimate: it was working at its last visit and is counted as working since
        local secs = (now - (m.seen or now)) / 60
        local a = rec(m.a or BEFORE)
        if kind == 'drill' then
          local n = secs * drill_rate(e)
          a.ore = a.ore + n; a.shift_ore = a.shift_ore + n
        else
          local n = secs * lab_rate(e)
          a.units = a.units + n; a.shift_units = a.shift_units + n
        end
      end
    end
    m.seen = now
    m.pass = E.walk.pass
    m.w = WORKING ~= nil and try(function() return e.status end) == WORKING
    local who = m.a or BEFORE
    local t = tally[who] or {machines=0, running=0}
    tally[who] = t
    t.machines = t.machines + 1
    if m.w then t.running = t.running + 1 end
  end

  -- The walk ----------------------------------------------------------------------------------------------------
  local tally = {}   -- this pass's machines and running, per builder (rebuilt each pass; a reload restarts it)
  -- Every planet surface and our platforms (no count over a surface: with none of ours there, it would scan it whole;
  -- an empty block costs about 0.05 ms).
  local function surfaces_now(force)
    local out = {}
    for _, s in pairs(game.surfaces) do
      local ours = s.platform and s.platform.force == force or (not s.platform and s.planet ~= nil)
      if ours then out[#out+1] = s.name end
    end
    table.sort(out)
    return out
  end
  local function end_pass(E)
    local W = E.walk
    for name in pairs(tally) do rec(name) end
    for name, a in pairs(E.agents) do
      local t = tally[name] or {machines=0, running=0}
      a.machines, a.running = t.machines, t.running
    end
    -- machines not seen this pass are gone
    for u, m in pairs(E.machines) do if (m.pass or 0) < W.pass then E.machines[u] = nil end end
    tally = {}
    W.last_pass_ticks = game.tick - W.started
    W.last_surfaces = W.surfaces
    W.pass = W.pass + 1
    W.started = game.tick
    W.surfaces, W.si, W.i = nil, 1, 0
  end
  function M.tick(tick)
    local E = st()
    local W = E.walk
    -- this block's machines, PER_TICK a tick
    if qi <= #queue then
      local last = math.min(#queue, qi + PER_TICK - 1)
      for k = qi, last do visit(queue[k], tally) end
      qi = last + 1
      return
    end
    if tick % BLOCK_EVERY ~= 0 then return end
    local force = api.force and api.force()
    if not force then return end
    if not W.surfaces then
      W.surfaces = surfaces_now(force)
      -- every agent the hand counts know is in the read, with or without machines
      for _, name in ipairs(api.agent_names and api.agent_names() or {}) do rec(name) end
    end
    local sname = W.surfaces[W.si]
    if not sname then end_pass(E); return end
    local surface = game.get_surface(sname)
    local ext = W.extent[sname] or default_extent(sname)
    W.extent[sname] = ext
    local width = 2 * ext + 1
    if not surface or W.i >= width * width then
      W.si, W.i = W.si + 1, 0
      return
    end
    local bx, by = -ext + W.i % width, -ext + math.floor(W.i / width)
    W.i = W.i + 1
    local area = {left_top={x=bx * BLOCK, y=by * BLOCK}, right_bottom={x=(bx + 1) * BLOCK, y=(by + 1) * BLOCK}}
    local found = try(function() return surface.find_entities_filtered{area=area, type=TYPES, force=force} end) or {}
    if #found > 0 and math.max(math.abs(bx), math.abs(by)) >= ext then   -- machines in the outermost ring
      W.extent[sname] = math.min(MAX_EXTENT, ext + 2)
    end
    queue, qi = found, 1
  end

  -- Reads -------------------------------------------------------------------------------------------------------
  local function top_items(a)
    local rows = {}
    for item, n in pairs(a.by_item) do rows[#rows+1] = {item=item, items=math.floor(n + 0.5)} end
    table.sort(rows, function(x, y) return x.items > y.items or (x.items == y.items and x.item < y.item) end)
    local out = {}
    for i = 1, math.min(TOP_ITEMS, #rows) do out[i] = rows[i] end
    return out
  end
  local function row(name, a)
    local hand = api.hand_items and api.hand_items(name) or nil
    local hand_shift = hand and math.max(0, hand - (a.hand_base or 0)) or nil
    local made = math.floor((a.shift_items or 0) + 0.5)
    local share = hand_shift and (made + hand_shift) > 0 and math.floor(100 * made / (made + hand_shift) + 0.5) or nil
    return {name=name, machines=a.machines, running=a.running, built_logged=a.built,
      items=math.floor(a.items + 0.5), crafts=a.crafts, items_shift=made,
      ore_about=math.floor(a.ore + 0.5), ore_shift_about=math.floor((a.shift_ore or 0) + 0.5),
      lab_units_about=math.floor(a.units + 0.5), lab_units_shift_about=math.floor((a.shift_units or 0) + 0.5),
      hand_items_shift=hand_shift, machine_share_pct=share, top_items=top_items(a)}
  end
  function M.read()
    local E = st()
    local rows, team = {}, {machines=0, running=0, items=0, items_shift=0, ore_about=0, lab_units_about=0, hand_items_shift=0}
    for _, name in ipairs(api.agent_names and api.agent_names() or {}) do rec(name) end
    for name, a in pairs(E.agents) do
      rec(name)
      local r = row(name, a)
      if name == BEFORE then r.name, r.before = BEFORE, true end
      rows[#rows+1] = r
      team.machines = team.machines + (r.machines or 0); team.running = team.running + (r.running or 0)
      team.items = team.items + r.items; team.items_shift = team.items_shift + r.items_shift
      team.ore_about = team.ore_about + r.ore_about; team.lab_units_about = team.lab_units_about + r.lab_units_about
      team.hand_items_shift = team.hand_items_shift + (r.hand_items_shift or 0)
    end
    local m = team.items_shift + team.hand_items_shift
    team.machine_share_pct = m > 0 and math.floor(100 * team.items_shift / m + 0.5) or nil
    table.sort(rows, function(x, y) return tostring(x.name) < tostring(y.name) end)
    local W = E.walk
    local seq, shift_tick = shift()
    return {tick=game.tick, since_tick=E.since, shift={seq=seq, tick=shift_tick}, team=team, agents=rows,
      walk={pass=W.pass, surfaces=W.surfaces or W.last_surfaces, last_pass_ticks=W.last_pass_ticks, extent=W.extent},
      logged={units=table_size(E.units), spots=E.nkeys, machines=table_size(E.machines)},
      errors=api.state().efficiency_errors}
  end
  -- Operator seed (tools/efficiency_seed.py): rows {by, tick, unit?, name?, surface?, x?, y?}; a later entry wins.
  function M.seed(args)
    assert(type(args) == 'table' and type(args.rows) == 'table' and #args.rows <= 2000, 'rows: 1..2000 seed rows')
    local E = st()
    local units, spots = 0, 0
    for i, r in ipairs(args.rows) do
      assert(type(r) == 'table' and type(r.by) == 'string' and type(r.tick) == 'number', 'row ' .. i .. ': by and tick')
      if r.unit then
        local old = E.units[r.unit]
        if not old or old.t <= r.tick then E.units[r.unit] = {a=r.by, t=r.tick}; units = units + 1 end
      end
      if r.name and r.x and r.y and credited_type(r.name) then
        put_key(key(r.surface or '*', r.name, {x=r.x, y=r.y}), r.by, r.tick)
        spots = spots + 1
      end
    end
    return {ok=true, tick=game.tick, units=units, spots=spots}
  end
  -- One line for the agent's 2-hour review (selfview.lua).
  function M.review_line(name)
    local E = st()
    local a = E.agents[name]
    if not a then return nil end
    rec(name)
    local r = row(name, a)
    local parts = {string.format('machines you built made %d items this shift (%d of your machines, %d running)', r.items_shift,
      r.machines or 0, r.running or 0)}
    if r.machine_share_pct then parts[#parts+1] = string.format('%d%% of your items this shift moved by machines', r.machine_share_pct) end
    return table.concat(parts, '; ')
  end
  M.operator = {efficiency=function() return M.read() end, efficiency_seed=function(a) return M.seed(a) end}
  M.BEFORE = BEFORE
  return M
end
