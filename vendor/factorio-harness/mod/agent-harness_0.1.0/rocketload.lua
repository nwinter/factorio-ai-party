-- A silo's rocket cargo in one call each (shift12 15:20): load_silo loads an
-- item list into the rocket from what the agent holds and from chests within
-- reach (or given chests), and with launch=true launches it in the same tick
-- once the rocket is ready, waiting for that as a timed action (Sonnet: about
-- 40 transfer and launch round trips a shift); preflight reads what the rocket
-- would carry: its cargo against the 1000 kg lift and its slots, what an item
-- list still lacks, and a platform's requests from this planet less what its
-- hub holds and what this rocket carries (Gemini); launch's guard checks
-- min_cargo and arrived at the tick it launches, and a queue dry run counts the
-- silo cargo the plan's steps would leave before each launch step (Luna: a
-- rocket_ready wait ran before an agricultural science top-up, and the queued
-- launch went with the old cargo).
-- Everything here is what the silo GUI, the chests' GUIs and the platform GUI
-- show a player standing there. The factory is pure so the same module can be
-- bundled into a hot reload.
return function(api)
  local M = {}
  local MAX_ITEMS, MAX_CHESTS, MAX_FROM = 20, 16, 16
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function at(pos) return string.format('(%g,%g)', pos.x, pos.y) end
  local function kg(g) return math.floor(g / 100 + 0.5) / 10 end
  local function label(r) return r.name .. (r.quality and r.quality ~= 'normal' and '@' .. r.quality or '') end
  local function key(name, quality) return name .. '@' .. (quality or 'normal') end
  local function weight(name) return try(function() return prototypes.item[name].weight end) or 0 end
  local function stack_size(name) return try(function() return prototypes.item[name].stack_size end) or 1 end
  -- An item stack's quality is a LuaQualityPrototype (userdata in the game, not a table: Gemini 18:21, load_silo matched
  -- no stack while it read only a table's name); a contents row's is its name.
  local function quality_of(s)
    local q = s.quality
    if q == nil then return 'normal' end
    if type(q) == 'string' then return q end
    return try(function() return q.name end) or 'normal'
  end

  -- An item list: {name: count} or [{item (or name), count, quality?}]; repeated entries add up.
  function M.items(v, what)
    what = what or 'items'
    local shape = what .. ' is {"item-name": count} or [{"item": "item-name", "count": N, "quality": "normal"}]'
    assert(type(v) == 'table', shape)
    local out, by = {}, {}
    local function add(name, count, quality)
      assert(type(name) == 'string' and prototypes.item[name], what .. ': unknown item ' .. tostring(name))
      quality = quality or 'normal'
      assert(type(quality) == 'string', what .. ': quality is a quality name')
      assert(type(count) == 'number' and count == math.floor(count) and count >= 1 and count <= 100000,
        what .. ': ' .. name .. ' count must be 1..100000')
      local k = key(name, quality)
      if by[k] then by[k].count = by[k].count + count
      else by[k] = {name=name, quality=quality, count=count}; out[#out+1] = by[k] end
    end
    if #v > 0 then
      for i, r in ipairs(v) do
        assert(type(r) == 'table', what .. '[' .. i .. ']: ' .. shape)
        add(r.item or r.name, r.count, r.quality)
      end
    else
      local names = {}
      for k in pairs(v) do names[#names+1] = k end
      table.sort(names, function(x, y) return tostring(x) < tostring(y) end)
      for _, k in ipairs(names) do add(k, v[k]) end
    end
    assert(#out >= 1 and #out <= MAX_ITEMS, what .. ' needs 1..' .. MAX_ITEMS .. ' items')
    return out
  end

  -- The rocket's cargo -------------------------------------------------------------
  function M.rocket_inventory(silo)
    return defines.inventory.rocket_silo_rocket and try(function() return silo.get_inventory(defines.inventory.rocket_silo_rocket) end)
  end
  local function aboard(inv, r) return inv and try(function() return inv.get_item_count{name=r.name, quality=r.quality or 'normal'} end) or 0 end
  local function contents(inv)
    local out = {}
    for _, s in ipairs(inv and try(function() return inv.get_contents() end) or {}) do
      out[#out+1] = {name=s.name, count=s.count, quality=quality_of(s)}
    end
    return out
  end
  local function used_slots(inv)
    local n = 0
    for i = 1, inv and #inv or 0 do if inv[i].valid_for_read then n = n + 1 end end
    return n
  end
  local function list_text(list, limit)
    local sorted = {}
    for i, r in ipairs(list) do sorted[i] = r end
    table.sort(sorted, function(x, y) if x.count ~= y.count then return x.count > y.count end return label(x) < label(y) end)
    local parts = {}
    for i = 1, math.min(#sorted, limit or 12) do parts[i] = label(sorted[i]) .. '*' .. sorted[i].count end
    if #sorted > (limit or 12) then parts[#parts+1] = string.format('+%d more', #sorted - (limit or 12)) end
    return #parts > 0 and table.concat(parts, ' ') or 'empty'
  end
  local function grams(list)
    local g = 0
    for _, r in ipairs(list) do g = g + weight(r.name) * r.count end
    return g
  end
  local function ready(silo)
    return try(function() return silo.rocket_silo_status == defines.rocket_silo_status.rocket_ready end) == true
  end
  local function planet_of(silo) return try(function() return silo.surface.planet.name end) or try(function() return silo.surface.name end) end
  local function where(pl)
    local w = api.where and try(function() return api.where(pl) end)
    if w then return w end
    local loc = try(function() return pl.space_location.name end)
    return {at=loc, stopped=loc ~= nil, text=loc and 'at ' .. loc or 'not at a stop'}
  end

  -- min_cargo against counts (count(r) gives what is aboard): ok, lines, lacks.
  function M.min_check(list, count)
    local lines, lacks = {}, {}
    for _, r in ipairs(list) do
      local n = count(r)
      lines[#lines+1] = string.format('%s %d aboard (at least %d)', label(r), n, r.count)
      if n < r.count then lacks[#lacks+1] = string.format('%s %d of %d (%d short)', label(r), n, r.count, r.count - n) end
    end
    return #lacks == 0, lines, lacks
  end

  -- Launch's guard: min_cargo and arrived, read in the tick the launch goes (a queue step's launch runs whole in
  -- its tick). Raises the refusal; returns the checked lines.
  function M.guard(p, a, silo)
    local checked = {}
    if a.min_cargo ~= nil then
      local list = M.items(a.min_cargo, 'min_cargo')
      local inv = M.rocket_inventory(silo)
      local ok, lines, lacks = M.min_check(list, function(r) return aboard(inv, r) end)
      if not ok then
        error(string.format('launch refused at tick %d, nothing launched: min_cargo not met: %s; the rocket holds %s',
          game.tick, table.concat(lacks, ', '), list_text(contents(inv))), 0)
      end
      checked[#checked+1] = 'min_cargo: ' .. table.concat(lines, ', ')
    end
    if a.arrived ~= nil then
      assert(a.arrived == true, 'arrived must be true')
      assert(a.platform ~= nil, 'arrived goes with platform=<name>')
      local pl = api.platform(p, a.platform)
      local here = planet_of(silo)
      local w = where(pl)
      if not (w.stopped and w.at == here) then
        error(string.format('launch refused at tick %d, nothing launched: platform %s has not arrived at %s (%s)', game.tick, pl.name, tostring(here), w.text), 0)
      end
      checked[#checked+1] = string.format('arrived: platform %s stopped at %s', pl.name, here)
    end
    if #checked == 0 then return nil end
    return {tick=game.tick, lines=checked}
  end

  -- Chests -------------------------------------------------------------------------
  -- Every chest kind: chests, logistic chests (requester, buffer, provider, storage), linked and infinity chests, and
  -- a cargo landing pad.
  local CHEST_TYPES = {'container', 'logistic-container', 'linked-container', 'infinity-container', 'cargo-landing-pad'}
  local function chest_inventory(c)
    return try(function() return c.get_inventory(defines.inventory.chest) end)
      or (defines.inventory.cargo_landing_pad_main and try(function() return c.get_inventory(defines.inventory.cargo_landing_pad_main) end))
  end
  -- Our chests within reach of the character, nearest first (reach to the box, as the engine measures it: a landing
  -- pad's centre is 4 tiles inside its edge).
  function M.chests_in_reach(p, skip)
    local found = try(function()
      return p.surface.find_entities_filtered{position=p.position, radius=(p.reach_distance or 10) + 8, type=CHEST_TYPES, force=p.force, limit=64}
    end) or {}
    local out = {}
    for _, c in ipairs(found) do
      if c.valid and c ~= skip and try(function() return p.can_reach_entity(c) end) and chest_inventory(c) then out[#out+1] = c end
    end
    local pos = p.position
    table.sort(out, function(x, y)
      local dx = (x.position.x - pos.x) ^ 2 + (x.position.y - pos.y) ^ 2
      local dy = (y.position.x - pos.x) ^ 2 + (y.position.y - pos.y) ^ 2
      if dx ~= dy then return dx < dy end
      return x.position.x < y.position.x
    end)
    while #out > MAX_CHESTS do out[#out] = nil end
    return out
  end
  -- from: one {x,y} or a list of them.
  local function from_list(v)
    assert(type(v) == 'table', 'from is a chest position {x,y} or a list of 1..' .. MAX_FROM .. ' of them')
    if v.x ~= nil or type(v[1]) == 'number' then return {v} end
    assert(#v >= 1 and #v <= MAX_FROM, 'from is a chest position {x,y} or a list of 1..' .. MAX_FROM .. ' of them')
    return v
  end

  -- load_silo ----------------------------------------------------------------------
  local LAUNCH_ARGS = {platform=true, orbit=true, min_cargo=true, arrived=true}
  function M.check(a)
    M.items(a.items, 'items')
    for _, k in ipairs({'to_total', 'launch', 'chests', 'walk'}) do
      assert(a[k] == nil or type(a[k]) == 'boolean', k .. ' must be true or false')
    end
    if a.walk == true then
      assert(a.from ~= nil, 'walk goes with from: the chests to take from ({x,y} or a list), on this surface, in sight or on the map')
      assert(a.chests == nil, 'walk takes from the chests in from (chests does not go with it)')
    end
    for _, k in ipairs({'avoid_enemies', 'unsafe_goal'}) do assert(a[k] == nil or a.walk == true, k .. ' goes with walk=true') end
    if a.launch then
      assert(a.platform ~= nil or a.orbit == true, 'launch needs platform=<name> (or orbit=true)')
    else
      for k in pairs(LAUNCH_ARGS) do assert(a[k] == nil, k .. ' goes with launch=true') end
    end
    if a.from ~= nil then from_list(a.from) end
    if a.min_cargo ~= nil then M.items(a.min_cargo, 'min_cargo') end
  end
  -- Returns the reply, or {wait=...} when the rocket is not there (or not ready for a launch) yet.
  function M.load(p, a)
    M.check(a)
    local silo = api.reach_entity(p, a.position)
    assert(silo.type == 'rocket-silo', silo.name .. ' at ' .. at(silo.position) .. ' is not a rocket silo')
    if try(function() return silo.use_transitional_requests end) then
      error('the silo at ' .. at(silo.position) .. ' has automatic requests on: the game fills its rocket for the platforms\' requests and takes no cargo by hand; launch {position, auto_requests=false} turns them off', 0)
    end
    local list = M.items(a.items, 'items')
    local inv = M.rocket_inventory(silo)
    local rk = api.rocket and try(function() return api.rocket(silo) end)
    if not inv or (a.launch and not ready(silo)) then
      return {wait=true, why=not inv and 'no rocket to load yet' or 'the rocket is not ready to launch yet', rocket=rk and rk.rocket or nil}
    end
    -- The chests: those given, else ours in reach.
    local chests = {}
    if a.from ~= nil then
      for _, pos in ipairs(from_list(a.from)) do
        local c = api.reach_entity(p, pos)
        assert(c.force == p.force, 'from: ' .. c.name .. ' at ' .. at(c.position) .. ' is not ours')
        assert(chest_inventory(c), 'from: ' .. c.name .. ' at ' .. at(c.position) .. ' has no chest inventory')
        chests[#chests+1] = c
      end
    elseif a.chests ~= false then
      chests = M.chests_in_reach(p, silo)
    end
    local rows, short, moved_all = {}, {}, {}
    for _, r in ipairs(list) do
      local before = aboard(inv, r)
      local want = a.to_total and math.max(0, r.count - before) or r.count
      local room = api.rocket_room(silo, r.name)
      local goal = math.min(want, room)
      local moved, from, fresh = 0, {}, nil
      local function match(s) return s.name == r.name and quality_of(s) == r.quality end
      -- what each source held of it before the move, for a shortfall's why
      local function count(source) return source and try(function() return source.get_item_count{name=r.name, quality=r.quality} end) or 0 end
      local you = 0
      for _, source in ipairs(api.give_sources(p, r.name)) do you = you + count(source) end
      local held = {string.format('you held %d', you)}
      for k, c in ipairs(chests) do
        if k <= 4 then held[#held+1] = string.format('%s %s held %d', c.name, at(c.position), count(chest_inventory(c))) end
      end
      if #chests > 4 then held[#held+1] = string.format('%d more chests', #chests - 4) end
      if #chests == 0 then held[#held+1] = a.chests == false and 'chests not read (chests=false)' or 'no chest of ours in reach' end
      local function take(source, name)
        if moved >= goal or not source then return end
        local n, _, fr = api.move_stacks(source, inv, match, goal - moved)
        if n > 0 then moved = moved + n; from[#from+1] = name .. ' ' .. n end
        if fr and api.merge_fresh then fresh = api.merge_fresh(fresh or {}, fr) end
      end
      for _, source in ipairs(api.give_sources(p, r.name)) do take(source, 'you') end
      for _, c in ipairs(chests) do take(chest_inventory(c), c.name .. ' ' .. at(c.position)) end
      local row = {item=label(r), asked=r.count, aboard_before=before, loaded=moved, aboard=before + moved,
        from=#from > 0 and table.concat(from, ', ') or nil}
      -- The loaded batch's spoilage (Sol, 22:25): its spread, and for a science pack the research units it covers.
      if fresh and api.fresh_lines then
        local ok, lines = pcall(api.fresh_lines, p, fresh)
        if ok and lines[1] then row.freshness = lines[1] end
      end
      if moved < want then
        row.short = want - moved
        if room < want and moved >= room then
          row.why = string.format('weight: %d fit under the lift (%g kg each; the rocket holds %s)', room, kg(weight(r.name)), api.rocket_weight(silo))
        elseif not try(function() return inv.can_insert{name=r.name, quality=r.quality} end) then
          row.why = string.format('the rocket\'s cargo slots are full (%d of %d)', used_slots(inv), #inv)
        else
          row.why = table.concat(held, '; ')
        end
        short[#short+1] = string.format('%s %d short (%s)', row.item, row.short, row.why)
      end
      rows[#rows+1] = row
      if moved > 0 then moved_all[#moved_all+1] = {name=r.name, quality=r.quality, count=moved} end
    end
    if #moved_all > 0 and api.moved then pcall(api.moved, p, silo, moved_all) end
    local out = {silo=string.format('%s at %s', silo.name, at(silo.position)), loaded=rows,
      cargo=list_text(contents(inv)), rocket_weight=api.rocket_weight(silo), slots=used_slots(inv) .. '/' .. #inv,
      chests=#chests > 0 and #chests or nil, complete=#short == 0, short=#short > 0 and short or nil}
    if a.launch then
      if #short > 0 then
        error(string.format('not launched: %s; what was loaded stays in the rocket (it holds %s, %s)',
          table.concat(short, '; '), out.cargo, out.rocket_weight), 0)
      end
      local ok, launched = pcall(api.launch, p, {position=silo.position, platform=a.platform, orbit=a.orbit, min_cargo=a.min_cargo, arrived=a.arrived})
      if not ok then
        error(string.format('loaded, then the launch was refused: %s; the cargo stays in the rocket (it holds %s, %s)',
          api.reason and api.reason(launched) or tostring(launched), out.cargo, out.rocket_weight), 0)
      end
      out.launch = launched
    end
    return out
  end
  -- Ready to rerun a waiting load_silo: the rocket is there (and ready, for a launch), or the silo is gone.
  function M.ready(p, action)
    local w = action.await_silo
    local silo = w and try(function() return api.reach_entity(p, w.position) end)
    if not (silo and silo.valid and silo.type == 'rocket-silo') then return true end
    if not M.rocket_inventory(silo) then return false end
    return not w.launch or ready(silo)
  end

  -- load_silo {walk: true, from} ------------------------------------------------------
  -- Luna, shift14 21:20: 930 agricultural science packs from a provider 64 tiles from the silo took four walks and
  -- several calls. One timed call (a tour, op load_silo) walks between the chests in from and the silo as a player
  -- carries a load: at each chest it takes what the rocket still needs less what you hold, at the silo it loads what
  -- you hold of the list; another trip while the rocket still needs some, a chest in from still holds it and the trip
  -- loaded any. The chests anywhere on the silo's surface, in sight or on the map; taken from in reach, as by hand.
  local MAX_TRIPS = 20
  local function dist(a, b) return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2) end
  local function held_of(p, r)
    local n = 0
    for _, source in ipairs(api.give_sources(p, r.name)) do
      n = n + (try(function() return source.get_item_count{name=r.name, quality=r.quality} end) or 0)
    end
    return n
  end
  -- Each goal still short in the rocket: {goal, need (to load), held (you), take (from the chests: no more than fits
  -- under the rocket's lift now, less what you hold)}.
  local function needs(p, action)
    local inv = M.rocket_inventory(action.silo)
    local out = {}
    for _, g in ipairs(action.goals) do
      local need = math.max(0, g.target - aboard(inv, g))
      if need > 0 then
        local h = held_of(p, g)
        local room = inv and try(function() return api.rocket_room(action.silo, g.name) end) or need
        out[#out+1] = {goal=g, need=need, held=h, take=math.max(0, math.min(need, room) - h)}
      end
    end
    return out
  end
  -- The chests holding what the next trip takes, nearest first from `from` (each one from the one before).
  local function trip(p, action, from, rows)
    local left, todo = {}, false
    for _, c in ipairs(action.chests) do
      if c.valid then
        for _, n in ipairs(rows) do
          if n.take > 0 and (try(function() return chest_inventory(c).get_item_count{name=n.goal.name, quality=n.goal.quality} end) or 0) > 0 then
            left[#left+1] = c; todo = true; break
          end
        end
      end
    end
    local out, at_ = {}, from
    while #left > 0 do
      local best, bi = nil, nil
      for i, c in ipairs(left) do if not best or dist(at_, c.position) < dist(at_, best.position) then best, bi = c, i end end
      out[#out+1] = best; at_ = best.position; table.remove(left, bi)
    end
    return out, todo
  end
  local function need_text(rows)
    local parts = {}
    for _, n in ipairs(rows) do parts[#parts+1] = string.format('%s %d (you hold %d)', label(n.goal), n.need, n.held) end
    return table.concat(parts, ', ')
  end
  local function chests_text(action, rows)
    local parts = {}
    for i, c in ipairs(action.chests) do
      if i > 4 then parts[#parts+1] = string.format('%d more', #action.chests - 4); break end
      local held = {}
      for _, n in ipairs(rows) do
        held[#held+1] = string.format('%d %s', try(function() return chest_inventory(c).get_item_count{name=n.goal.name, quality=n.goal.quality} end) or 0, label(n.goal))
      end
      parts[#parts+1] = string.format('%s %s holds %s', c.name, at(c.position), table.concat(held, ', '))
    end
    return table.concat(parts, '; ')
  end
  -- Before walking: the silo, the chests and the goals. Returns nil when the silo and every chest are in reach (the
  -- load as without walk), else {entities (the first trip, the silo last), fields (the tour's), reply}.
  function M.walk_start(p, a)
    M.check(a)
    local silo = api.sight_entity(p, a.position)
    assert(silo.type == 'rocket-silo', silo.name .. ' at ' .. at(silo.position) .. ' is not a rocket silo')
    if try(function() return silo.use_transitional_requests end) then
      error('the silo at ' .. at(silo.position) .. ' has automatic requests on: the game fills its rocket for the platforms\' requests and takes no cargo by hand; launch {position, auto_requests=false} turns them off', 0)
    end
    local chests, far = {}, try(function() return p.can_reach_entity(silo) end) ~= true
    for _, pos in ipairs(from_list(a.from)) do
      local c = api.sight_entity(p, pos)
      assert(c.force == p.force, 'from: ' .. c.name .. ' at ' .. at(c.position) .. ' is not ours')
      assert(chest_inventory(c), 'from: ' .. c.name .. ' at ' .. at(c.position) .. ' has no chest inventory')
      assert(c.surface == silo.surface, 'from: ' .. c.name .. ' at ' .. at(c.position) .. ' is not on the silo\'s surface')
      chests[#chests+1] = c
      if try(function() return p.can_reach_entity(c) end) ~= true then far = true end
    end
    if not far then return nil end
    local inv = M.rocket_inventory(silo)
    local goals = {}
    for _, r in ipairs(M.items(a.items, 'items')) do
      local before = aboard(inv, r)
      goals[#goals+1] = {name=r.name, quality=r.quality, count=r.count, before=before, target=a.to_total and r.count or before + r.count}
    end
    local load = {}
    for k, v in pairs(a) do load[k] = v end
    load.walk = nil; load.ticks = nil; load.from = nil; load.avoid_enemies = nil; load.unsafe_goal = nil
    local action = {silo=silo, chests=chests, goals=goals}
    local rows = needs(p, action)
    if #rows == 0 then
      error(string.format('nothing to load: the rocket holds the list already (%s); nothing walked', list_text(contents(inv))), 0)
    end
    local first, todo = trip(p, action, p.position, rows)
    local taking, held_any = false, false
    for _, n in ipairs(rows) do
      if n.take > 0 then taking = true end
      if n.held > 0 then held_any = true end
    end
    if not taking and not held_any then
      error(string.format('nothing walked: the rocket still needs %s and none of it fits under its lift (it holds %s)', need_text(rows), api.rocket_weight(silo)), 0)
    end
    if taking and not todo and not held_any then
      error(string.format('nothing walked: the rocket still needs %s and the chests in from hold none of it (%s)', need_text(rows), chests_text(action, rows)), 0)
    end
    local entities = {}
    for i, c in ipairs(first) do entities[i] = c end
    entities[#entities+1] = silo
    local fields = {ordered=true, load=load, silo=silo, chests=chests, goals=goals, trips=1, taken=0, loaded=0, rows={}, items={},
      avoid_enemies=a.avoid_enemies, unsafe_goal=a.unsafe_goal}
    local rk = api.rocket and try(function() return api.rocket(silo) end)
    local reply = {op='load_silo', walk=true, silo=string.format('%s at %s', silo.name, at(silo.position)), needs=need_text(rows),
      chests=chests_text(action, rows), trip=#first .. ' chest' .. (#first == 1 and '' or 's') .. ', then the silo', rocket=rk and rk.rocket or nil,
      note=a.launch and 'launch: at the last silo stop, when the rocket is ready then' or nil}
    return {entities=entities, fields=fields, reply=reply}
  end
  -- One stop of the tour: a chest (take) or the silo (load, then another trip, the end, or the launch).
  -- Returns {transferred, stop} as the tour's visits do.
  function M.walk_visit(p, action, e)
    local rows = needs(p, action)
    if e ~= action.silo then
      local n, full, notes = 0, false, {}
      for _, r in ipairs(rows) do
        if r.take > 0 then
          local out = api.take(p, e, r.goal.name, r.goal.quality, r.take)
          n = n + (out.transferred or 0)
          if out.transferred and out.transferred > 0 then
            local k = label(r.goal)
            action.items[k] = (action.items[k] or 0) + out.transferred
          end
          if out.inventory_full then full = true end
          if out.left_at_max then notes[#notes+1] = out.left_at_max end
        end
      end
      action.taken = action.taken + n
      action.rows[#action.rows+1] = {position=e.position, name=e.name, trip=action.trips, taken=n, full=full or nil,
        note=#notes > 0 and table.concat(notes, '; ') or nil}
      return {transferred=n}
    end
    local inv = M.rocket_inventory(e)
    local rk = api.rocket and try(function() return api.rocket(e) end)
    if not inv then
      action.final = 'no_rocket'
      action.why = string.format('no rocket to load at the silo (%s); what you took stays with you: %s', rk and rk.rocket_now or 'none', need_text(rows))
      action.rows[#action.rows+1] = {position=e.position, name=e.name, trip=action.trips, loaded=0, why='no rocket to load yet'}
      return {transferred=0, stop='no_rocket'}
    end
    local list = {}
    for _, r in ipairs(rows) do
      if r.held > 0 then list[#list+1] = {item=r.goal.name, quality=r.goal.quality, count=math.min(r.need, r.held)} end
    end
    local n, full_rocket = 0, nil
    if #list > 0 then
      local out = M.load(p, {position=e.position, items=list, chests=false})
      for _, row in ipairs(out.loaded or {}) do
        n = n + (row.loaded or 0)
        if row.why and (row.why:find('^weight') or row.why:find('cargo slots are full', 1, true)) then full_rocket = row.why end
      end
      action.cargo = out.cargo; action.rocket_weight = out.rocket_weight
    end
    action.loaded = action.loaded + n
    action.rows[#action.rows+1] = {position=e.position, name=e.name, trip=action.trips, loaded=n, cargo=action.cargo}
    rows = needs(p, action)
    if #rows == 0 then
      if not action.load.launch then action.final = 'loaded'; return {transferred=n, stop='loaded'} end
      if not ready(e) then
        action.final = 'loaded'
        action.why = string.format('loaded, not launched: %s (load_silo {launch: true} without walk waits for it)', rk and rk.rocket_now or 'the rocket is not ready')
        return {transferred=n, stop='loaded'}
      end
      local a = action.load
      local ok, launched = pcall(api.launch, p, {position=e.position, platform=a.platform, orbit=a.orbit, min_cargo=a.min_cargo, arrived=a.arrived})
      if ok then action.final = 'launched'; action.launch = launched; return {transferred=n, stop='launched'} end
      action.final = 'loaded'
      action.why = string.format('loaded, then the launch was refused: %s; the cargo stays in the rocket', api.reason and api.reason(launched) or tostring(launched))
      return {transferred=n, stop='loaded'}
    end
    local function short(why)
      action.final = 'short'
      action.why = string.format('the rocket still needs %s: %s', need_text(rows), why)
      return {transferred=n, stop='short'}
    end
    if full_rocket then return short(full_rocket) end
    local taking, held_any = false, false
    for _, r in ipairs(rows) do
      if r.take > 0 then taking = true end
      if r.held > 0 then held_any = true end
    end
    if not taking and not held_any then return short('none of it fits under the rocket\'s lift (it holds ' .. api.rocket_weight(e) .. ')') end
    if n == 0 then return short('this trip loaded none (' .. chests_text(action, rows) .. ')') end
    if action.trips >= MAX_TRIPS then return short(MAX_TRIPS .. ' trips made') end
    local next_trip, todo = trip(p, action, e.position, rows)
    if taking and not todo then return short('the chests in from hold no more of it (' .. chests_text(action, rows) .. ')') end
    action.trips = action.trips + 1
    for _, c in ipairs(next_trip) do action.targets[#action.targets+1] = {entity=c, position=c.position} end
    action.targets[#action.targets+1] = {entity=e, position=e.position}
    return {transferred=n}
  end
  -- The tour's end on last: trips, taken, loaded, the stops, the cargo, the launch, and why it ended short.
  function M.walk_last(action, last)
    last.given = nil; last.items = nil
    last.trips = action.trips; last.taken = action.taken; last.loaded = action.loaded; last.stops = action.rows
    last.cargo = action.cargo; last.rocket_weight = action.rocket_weight; last.launch = action.launch
    last.taken_items = next(action.items) and action.items or nil
    last.why = last.why or action.why
  end

  -- preflight ---------------------------------------------------------------------
  -- The hub's requests that import from this planet, by item.
  local function hub_requests(pl, planet)
    local out, order = {}, {}
    local secs = try(function() return pl.hub.get_logistic_sections() end)
    for i = 1, secs and secs.sections_count or 0 do
      local sec = secs.get_section(i)
      if sec and sec.active ~= false then
        for _, f in ipairs(sec.filters or {}) do
          local v = f.value
          local name = type(v) == 'table' and v.name or v
          local quality = type(v) == 'table' and v.quality or 'normal'
          local from = f.import_from and (type(f.import_from) == 'string' and f.import_from or try(function() return f.import_from.name end))
          if type(name) == 'string' and from == planet and (f.min or 0) > 0 then
            local k = key(name, quality)
            if not out[k] then out[k] = {name=name, quality=quality, min=0}; order[#order+1] = out[k] end
            out[k].min = out[k].min + f.min
          end
        end
      end
    end
    return order
  end
  function M.preflight(p, a)
    local silo = api.remote_entity(p, {position=a.position, name=a.name, unit_number=a.unit_number})
    assert(silo.type == 'rocket-silo', silo.name .. ' at ' .. at(silo.position) .. ' is not a rocket silo')
    local here = planet_of(silo)
    local inv = M.rocket_inventory(silo)
    local lift, slots = api.cargo.limits(silo)
    local held = contents(inv)
    local g = grams(held)
    local used = used_slots(inv)
    local rk = api.rocket and try(function() return api.rocket(silo) end)
    local out = {silo=string.format('%s at %s on %s', silo.name, at(silo.position), tostring(here)), rocket=rk and rk.rocket or nil,
      rocket_ready=ready(silo), auto_requests=try(function() return silo.use_transitional_requests end) and true or false}
    local rows = {}
    for _, r in ipairs(held) do
      rows[#rows+1] = {item=label(r), count=r.count, each_kg=kg(weight(r.name)), kg=kg(weight(r.name) * r.count),
        stacks=math.ceil(r.count / stack_size(r.name))}
    end
    table.sort(rows, function(x, y) if x.kg ~= y.kg then return x.kg > y.kg end return x.item < y.item end)
    out.cargo = {items=inv and list_text(held) or 'no rocket to load yet', rows=#rows > 0 and rows or nil, kg=kg(g), lift_kg=kg(lift),
      free_kg=kg(math.max(0, lift - g)), over_kg=g > lift and kg(g - lift) or nil, slots=used .. '/' .. slots, free_slots=math.max(0, slots - used)}
    local words = {string.format('%s: cargo %s, %g/%g kg, %d/%d slots', out.silo, out.cargo.items, kg(g), kg(lift), used, slots)}
    -- How many more of an item the rocket takes: by weight, and by slots (a part stack's room counted).
    local function fits(r)
      local each = weight(r.name)
      local by_weight = each > 0 and math.floor((lift - g + 1e-3) / each) or math.huge
      local n = aboard(inv, r)
      local st = stack_size(r.name)
      local part = n > 0 and (math.ceil(n / st) * st - n) or 0
      return math.max(0, math.min(by_weight, math.max(0, slots - used) * st + part))
    end
    -- An item list: what it still lacks against what is aboard, and how much of that fits.
    if a.items ~= nil then
      local list = M.items(a.items, 'items')
      local order, lacking = {}, {}
      for _, r in ipairs(list) do
        local n = aboard(inv, r)
        local lacks = math.max(0, r.count - n)
        local row = {item=label(r), want=r.count, aboard=n, lacks=lacks > 0 and lacks or nil,
          you_hold=try(function() return p.get_main_inventory().get_item_count{name=r.name, quality=r.quality} end) or 0}
        if lacks > 0 then
          row.fits = math.min(lacks, fits(r))
          lacking[#lacking+1] = string.format('%s %d (%d fit)', row.item, lacks, row.fits)
        end
        order[#order+1] = row
      end
      out.order = order
      words[#words+1] = #lacking > 0 and 'the list lacks ' .. table.concat(lacking, ', ') or 'the list is aboard'
    end
    -- A platform: where it is, and its requests from this planet less its hub and this rocket.
    if a.platform ~= nil then
      local pl = api.platform(p, a.platform)
      local w = where(pl)
      local plat = {name=pl.name, where=w.text, arrived=w.stopped == true and w.at == here}
      local hub = api.hub_counts and try(function() return api.hub_counts(pl) end) or {}
      local asks, lacking, asked = {}, {}, {}
      for _, r in ipairs(hub_requests(pl, here)) do
        asked[r.name] = true
        local n = aboard(inv, r)
        local h = hub[r.name] or 0
        local row = {item=label(r), min=r.min, hub=h, aboard=n, lacks_after=math.max(0, r.min - h - n)}
        if row.lacks_after == 0 then row.lacks_after = nil else lacking[#lacking+1] = string.format('%s %d', row.item, row.lacks_after) end
        asks[#asks+1] = row
      end
      plat.requests = #asks > 0 and asks or nil
      local extra = {}
      for _, r in ipairs(held) do if not asked[r.name] then extra[#extra+1] = label(r) .. '*' .. r.count end end
      plat.not_requested = #extra > 0 and table.concat(extra, ' ') or nil
      out.platform = plat
      words[#words+1] = string.format('platform %s %s%s', pl.name, w.text, plat.arrived and '' or ' (not stopped at ' .. tostring(here) .. ')')
      if #asks == 0 then words[#words+1] = 'it requests nothing from ' .. tostring(here)
      else words[#words+1] = #lacking > 0 and 'after this rocket its requests from ' .. tostring(here) .. ' lack ' .. table.concat(lacking, ', ') or 'this rocket covers its requests from ' .. tostring(here) end
    end
    -- What launch would refuse now.
    local refuse = {}
    if not out.rocket_ready then refuse[#refuse+1] = rk and rk.rocket_now or 'the rocket is not ready' end
    if g > lift then refuse[#refuse+1] = string.format('overweight by %g kg', kg(g - lift)) end
    if inv and #held == 0 then refuse[#refuse+1] = 'empty (allow_empty=true launches it so)' end
    if out.platform and not out.platform.arrived then refuse[#refuse+1] = 'platform ' .. out.platform.name .. ' is not stopped at ' .. tostring(here) end
    out.launch_now = #refuse > 0 and 'refused: ' .. table.concat(refuse, '; ') or 'ok'
    words[#words+1] = 'launch now: ' .. out.launch_now
    out.line = table.concat(words, '; ')
    return out
  end

  -- A queue dry run's cargo ---------------------------------------------------------
  -- The steps that move items by other means than transfer, load_silo and launch: their moves are not counted.
  local MOVERS = {collect=true, feed=true, pickup=true, craft=true, mine=true, build=true, construct=true, rearm=true, refuel=true,
    drop=true, gather=true, build_path=true, repair=true, cancel_craft=true, deconstruct=true}
  local DIRECTIONS = {to_entity='to_entity', from_player='to_entity', give='to_entity', put='to_entity', insert='to_entity',
    to_chest='to_entity', to_container='to_entity', to_player='to_player', from_entity='to_player', take='to_player',
    from_chest='to_player', from_container='to_player'}
  function M.simulate(p, steps)
    local held = {}
    local function add(t, k, n) t[k] = math.max(0, (t[k] or 0) + n); if t[k] == 0 then t[k] = nil end end
    for _, source in ipairs(api.give_sources(p)) do
      for _, s in ipairs(contents(source)) do add(held, key(s.name, s.quality), s.count) end
    end
    local ents, notes, launches = {}, {}, {}
    -- An entity at a position, read as the map shows it (remote view), counted once and then simulated.
    local function ent(pos)
      local ok, e = pcall(api.remote_entity, p, {position=pos})
      if not (ok and e and e.valid) then return nil, ok and 'no entity' or (api.reason and api.reason(e) or tostring(e)) end
      local id = e.unit_number or at(e.position)
      if ents[id] then return ents[id] end
      local x = {e=e, label=e.name .. ' ' .. at(e.position)}
      if e.type == 'rocket-silo' then
        x.silo = true
        x.cargo, x.parts = {}, {}
        for _, s in ipairs(contents(M.rocket_inventory(e))) do add(x.cargo, key(s.name, s.quality), s.count) end
        local pin = defines.inventory.crafter_input or defines.inventory.assembling_machine_input
        for _, s in ipairs(contents(pin and try(function() return e.get_inventory(pin) end))) do add(x.parts, key(s.name, s.quality), s.count) end
        x.ingredients = {}
        for _, n in ipairs(api.ingredients and (try(function() return api.ingredients(e) end) or {}) or {}) do x.ingredients[n] = true end
        x.lift = api.cargo.limits(e)
      else
        x.inv = {}
        local inv = chest_inventory(e) or try(function() return e.get_output_inventory() end)
        for _, s in ipairs(contents(inv)) do add(x.inv, key(s.name, s.quality), s.count) end
      end
      ents[id] = x
      return x
    end
    local function cargo_list(x)
      local list = {}
      for k, n in pairs(x.cargo) do
        local name, quality = k:match('^(.*)@([^@]*)$')
        list[#list+1] = {name=name, quality=quality, count=n}
      end
      return list
    end
    local function room(x, name)
      local each = weight(name)
      if each <= 0 then return math.huge end
      return math.max(0, math.floor((x.lift - grams(cargo_list(x)) + 1e-3) / each))
    end
    local function where_list(x, inventory, item, direction)
      if not x.silo then return x.inv end
      local named = inventory and (api.inventory_name and api.inventory_name(x.e, inventory) or inventory)
      if named == 'rocket_silo_rocket' then return x.cargo, true end
      if named then return x.parts end
      if direction == 'to_entity' then
        if item and x.ingredients[item] then return x.parts end
        return x.cargo, true
      end
      return (item and x.cargo[key(item)] and x.cargo) or x.parts, (item and x.cargo[key(item)]) and true or nil
    end
    local function step_note(i, st, text) notes[#notes+1] = string.format('step %d (%s%s): %s', i, st.action, st.label and ' ' .. st.label or '', text) end
    local function launch(i, st, x, a)
      local list = cargo_list(x)
      local row = {step=i, label=st.label, silo=x.label, cargo=list_text(list), kg=string.format('%g/%g kg', kg(grams(list)), kg(x.lift))}
      local refuse = {}
      if a.min_cargo ~= nil then
        local ok, mins = pcall(M.items, a.min_cargo, 'min_cargo')
        if ok then
          local met, lines, lacks = M.min_check(mins, function(r) return x.cargo[key(r.name, r.quality)] or 0 end)
          row.min_cargo = lines
          if not met then refuse[#refuse+1] = 'min_cargo not met: ' .. table.concat(lacks, ', ') end
        end
      end
      if grams(list) > x.lift then refuse[#refuse+1] = string.format('overweight by %g kg', kg(grams(list) - x.lift)) end
      if #list == 0 and a.allow_empty ~= true and not a.ride then refuse[#refuse+1] = 'empty (allow_empty=true launches it so)' end
      if a.platform ~= nil then
        local ok, pl = pcall(api.platform, p, a.platform)
        if ok then row.platform_now = pl.name .. ' ' .. where(pl).text end
      end
      row.would_refuse = #refuse > 0 and refuse or nil
      launches[#launches+1] = row
      if #refuse == 0 then x.cargo = {} end
    end
    for i, st in ipairs(steps) do
      local a = type(st.args) == 'table' and st.args or {}
      if st.action == 'transfer' then
        local direction = DIRECTIONS[a.direction] or (a.direction == nil and (a.item and held[key(a.item, a.quality)] and 'to_entity' or 'to_player')) or nil
        local targets = a.positions or (a.position and {a.position}) or {}
        local total = type(a.total) == 'number' and a.total or math.huge
        if not direction or #targets == 0 then step_note(i, st, 'not counted (its direction or target is not given in a form counted here)') end
        for _, pos in ipairs(direction and targets or {}) do
          local x, why = ent(pos)
          if not x then step_note(i, st, 'not counted at ' .. tostring(pos.x or pos[1]) .. ',' .. tostring(pos.y or pos[2]) .. ': ' .. tostring(why))
          else
            local t, cargo = where_list(x, a.inventory, a.item, direction)
            if a.item and a.direction == nil and not held[key(a.item, a.quality)] and not t[key(a.item, a.quality)] then
              step_note(i, st, string.format('no direction, and neither you nor %s hold %s by then: transfer refuses it', x.label, a.item))
            elseif a.item then
              local k = key(a.item, a.quality)
              local source = direction == 'to_entity' and held or t
              local n = math.min(type(a.count) == 'number' and a.count or (direction == 'to_entity' and 1 or 10000), source[k] or 0, total)
              if type(a.keep) == 'number' then n = math.min(n, math.max(0, (source[k] or 0) - a.keep)) end
              if type(a.up_to) == 'number' and direction == 'to_entity' then n = math.min(n, math.max(0, a.up_to - (t[k] or 0))) end
              if cargo and direction == 'to_entity' then n = math.min(n, room(x, a.item)) end
              n = math.max(0, n)
              total = total - n
              if direction == 'to_entity' then add(held, k, -n); add(t, k, n) else add(t, k, -n); add(held, k, n) end
            elseif direction == 'to_player' then
              for k, n in pairs(t) do add(held, k, n) end
              for k in pairs(t) do t[k] = nil end
            end
          end
        end
      elseif st.action == 'load_silo' then
        local x, why
        if a.position then x, why = ent(a.position) end
        local ok, list = pcall(M.items, a.items, 'items')
        if not (x and x.silo and ok) then step_note(i, st, 'not counted: ' .. tostring(not ok and list or why or 'no silo at its position'))
        else
          -- Its chests: those given, else ours in reach from where you stand now.
          local chests = {}
          if a.from ~= nil then
            local okf, list_ = pcall(from_list, a.from)
            for _, pos in ipairs(okf and list_ or {}) do local c = ent(pos); if c and c.inv then chests[#chests+1] = c end end
          elseif a.chests ~= false then
            for _, c in ipairs(M.chests_in_reach(p, x.e)) do local cx = ent(c.position); if cx and cx.inv then chests[#chests+1] = cx end end
            step_note(i, st, 'chests in reach counted from where you stand now')
          end
          local complete = true
          for _, r in ipairs(list) do
            local k = key(r.name, r.quality)
            local want = a.to_total and math.max(0, r.count - (x.cargo[k] or 0)) or r.count
            local goal = math.min(want, room(x, r.name))
            local moved = math.min(goal, held[k] or 0)
            add(held, k, -moved)
            for _, c in ipairs(chests) do
              local n = math.min(goal - moved, c.inv[k] or 0)
              if n > 0 then add(c.inv, k, -n); moved = moved + n end
            end
            add(x.cargo, k, moved)
            if moved < want then complete = false end
          end
          if a.launch then
            if complete then launch(i, st, x, a)
            else launches[#launches+1] = {step=i, label=st.label, silo=x.label, cargo=list_text(cargo_list(x)), would_refuse={'load_silo short of its list: not launched'}} end
          end
        end
      elseif st.action == 'launch' then
        local x, why
        if a.position then x, why = ent(a.position) end
        if not (x and x.silo) then step_note(i, st, 'not counted: ' .. tostring(why or 'no silo at its position'))
        elseif a.platform ~= nil or a.orbit ~= nil then launch(i, st, x, a) end
      elseif MOVERS[st.action] then
        step_note(i, st, 'the items it moves are not counted')
      end
    end
    local silos = {}
    for _, x in pairs(ents) do if x.silo then silos[#silos+1] = x.label .. ': ' .. list_text(cargo_list(x)) end end
    table.sort(silos)
    return {launches=#launches > 0 and launches or nil, silos_after=#silos > 0 and silos or nil, notes=#notes > 0 and notes or nil,
      counted='from what you, the chests and the silos hold now, step by step: transfer, load_silo and launch; waits move nothing'}
  end

  M.schema = {
    load_silo = {position='the rocket silo {x,y} (any tile of it), within reach',
      items='the cargo to load: {"item-name": count} or [{"item", "count", "quality"}], 1..20 items',
      to_total='true: each count is what the rocket should hold in all (only the rest is loaded); default: each count is loaded on top of what it holds',
      from='optional chest {x,y} or 1..16 of them, within reach: take from these (after your inventory); default: your inventory, then our chests within reach, nearest first (at most 16): every chest kind (chests, logistic chests, linked and infinity chests) and a cargo landing pad. With walk: anywhere on the silo\'s surface, in sight or on the map',
      chests='false: your inventory only',
      walk='true, with from: one timed call that walks between the chests in from and the silo, as many trips as it takes (at most 20): at each chest it takes what the rocket still needs less what you hold (up to your request max), at the silo it loads what you hold of the list; another trip while the rocket still needs some, a chest in from holds it and the trip loaded any. With launch: launched at the last silo stop when the rocket is ready then; otherwise it ends loaded, not launched, naming the rocket\'s state. The silo and every chest in reach: the load at once, as without walk. Nothing in the chests and nothing held of what the rocket needs: refused, nothing walked. Outcomes loaded | launched | short (last.why: weight, slots, the chests empty, a trip that loaded none) | no_rocket (none at the silo when you got there: what you took stays with you) | unreached | timed_out; last: trips, taken, taken_items, loaded, stops [{position, name, trip, taken | loaded, full, note}], cargo, rocket_weight, launch',
      avoid_enemies='with walk: as move_to\'s; each leg goes round the worms, spawners and attacks the map shows, and a stop inside one is left out',
      unsafe_goal='with walk: true walks to such a stop anyway',
      launch='true: launch once the rocket is ready, in the tick the cargo is loaded; needs platform (or orbit=true); refused (not launched, an error) when any count fell short; min_cargo and arrived are checked as launch checks them',
      platform='with launch: the platform in orbit to send it to', orbit='with launch: true for no platform',
      min_cargo='with launch: as launch min_cargo', arrived='with launch: as launch arrived',
      ticks='1..36000 (default 3600): how long to wait for the rocket (no rocket yet, or not ready for a launch); with walk, the whole tour (default 18000)',
      returns='silo, loaded [{item, asked, aboard_before, loaded, aboard, from (you N, iron-chest (x,y) N), freshness (a spoilable item: the loaded batch\'s spread and, for a pack the running research takes, the research units it covers), short, why (weight, slots, or what you and the chests held)}], cargo, rocket_weight, slots (used/total), chests (how many were read), complete, short; launch (the launch reply) with launch=true. No rocket yet, or launch=true before the rocket is ready: a timed action (until_tick, waiting {why, rocket}; outcome fed | failed | timed_out; last.result holds the reply). Into the rocket only what fits under its 1000 kg lift and in its cargo slots; a silo with automatic requests on is refused'},
    preflight = {position='the rocket silo {x,y} (any tile of it), in a visible chunk (remote view)', surface='optional planet name: the silo there by remote view',
      items='optional item list (as load_silo items): what it still lacks against the cargo aboard, and how much of that fits',
      platform='optional platform name: where it is, whether it has arrived here, and its requests from this planet less its hub and this rocket',
      returns='silo, rocket, rocket_ready, auto_requests, cargo {items, rows [{item, count, each_kg, kg, stacks}], kg, lift_kg, free_kg, over_kg, slots, free_slots}, '
        .. 'order [{item, want, aboard, lacks, fits, you_hold}], platform {name, where, arrived, requests [{item, min (from this planet), hub, aboard, lacks_after}], not_requested (cargo it does not request from here)}, '
        .. 'launch_now (ok, or refused: what launch would refuse now), line. Read only'},
  }
  return M
end
