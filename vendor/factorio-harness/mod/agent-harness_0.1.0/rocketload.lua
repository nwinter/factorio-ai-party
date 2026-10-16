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

  local platform_view
  -- A launch to a platform that is not in orbit of the silo's planet (Sonnet, shift17 19:15: 500 packs loaded into a
  -- rocket for Kestrel, still flying, stayed in it): 'here' (it is: load and launch), 'headed' with why (its current
  -- leg or next stop is this planet: the load waits, nothing loaded), or 'away' with why (refused, nothing loaded).
  function M.platform_gate(p, a, silo)
    if not (a.launch and a.platform ~= nil) then return 'here' end
    local pl = api.platform(p, a.platform)
    local here = planet_of(silo)
    local w = where(pl)
    if w.at == here then return 'here' end
    local v = platform_view(pl, here, nil, {}, true, true)
    if v.headed_here then
      return 'headed', string.format('platform %s is %s, headed to %s%s: nothing is loaded until it is in orbit there (a launch needs it there, and the rocket would hold the cargo until then)',
        pl.name, w.text, here, v.eta_s and string.format(' (about %ds at its speed now)', v.eta_s) or '')
    end
    return 'away', string.format('platform %s is %s, not headed to %s (next stop %s): a launch needs it in orbit of %s; nothing loaded',
      pl.name, w.text, here, tostring(v.next_stop or 'none'), here)
  end
  -- How to send what is aboard (Sonnet, shift17 19:16: three calls after 1000 packs were aboard).
  function M.as_is(silo, a)
    local pos = silo.position
    if a and a.platform ~= nil then
      return string.format('launch it as it is: launch {"position":{"x":%g,"y":%g},"platform":"%s"}', pos.x, pos.y, tostring(a.platform))
    end
    return string.format('launch it as it is: launch {"position":{"x":%g,"y":%g},"platform":NAME}', pos.x, pos.y)
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
  -- fresh_first (Luna, shift14 22:50: each agricultural source chest inspected apart, stale packs going up while fresh
  -- ones sat nearby): for an item that spoils, every matching stack of every source (you, then the chests) least spoiled
  -- first, each moved whole as it is (its spoilage goes with it).
  local function spoils(name) return (try(function() return prototypes.item[name].get_spoil_ticks() end) or 0) > 0 end
  local function fresh_stacks(sources, match)
    local out = {}
    for _, src in ipairs(sources) do
      local inv = src.inv
      for i = 1, inv and #inv or 0 do
        local s = inv[i]
        if try(function() return s.valid_for_read end) and match(s) then
          out[#out+1] = {stack=s, name=src.name, pct=try(function() return s.spoil_percent end) or 0, n=#out}
        end
      end
    end
    table.sort(out, function(x, y) if x.pct ~= y.pct then return x.pct < y.pct end return x.n < y.n end)
    return out
  end
  -- "you 50, you 30" -> "you 80" (the fresh-first moves, one stack at a time), in first-taken order.
  local function merge_from(from)
    local by, order = {}, {}
    for _, f in ipairs(from) do
      local name, n = f:match('^(.*) (%d+)$')
      if name then
        if not by[name] then by[name] = 0; order[#order+1] = name end
        by[name] = by[name] + tonumber(n)
      end
    end
    local out = {}
    for _, name in ipairs(order) do out[#out+1] = name .. ' ' .. by[name] end
    return out
  end
  local LAUNCH_ARGS = {platform=true, orbit=true, min_cargo=true, arrived=true}
  function M.check(a)
    M.items(a.items, 'items')
    for _, k in ipairs({'to_total', 'launch', 'chests', 'walk', 'fresh_first', 'up_to'}) do
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
    local gate, gate_why = M.platform_gate(p, a, silo)
    if gate == 'headed' then return {wait=true, platform=true, why=gate_why, rocket=rk and rk.rocket or nil} end
    if gate == 'away' then error(gate_why .. '; the rocket holds ' .. list_text(contents(inv)), 0) end
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
      local fresh_first = a.fresh_first ~= false and spoils(r.name)
      if fresh_first then
        local srcs = {}
        for _, source in ipairs(api.give_sources(p, r.name)) do srcs[#srcs+1] = {inv=source, name='you'} end
        for _, c in ipairs(chests) do srcs[#srcs+1] = {inv=chest_inventory(c), name=c.name .. ' ' .. at(c.position)} end
        for _, f in ipairs(fresh_stacks(srcs, match)) do take({f.stack}, f.name) end
        from = merge_from(from)
      else
        for _, source in ipairs(api.give_sources(p, r.name)) do take(source, 'you') end
        for _, c in ipairs(chests) do take(chest_inventory(c), c.name .. ' ' .. at(c.position)) end
      end
      local row = {item=label(r), asked=r.count, aboard_before=before, loaded=moved, aboard=before + moved,
        from=#from > 0 and table.concat(from, ', ') or nil}
      -- The loaded batch's spoilage (Sol, 22:25): its spread, and for a pack the running research takes, its units.
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
      if fresh_first then row.order = 'fresh first' end
      rows[#rows+1] = row
      if moved > 0 then moved_all[#moved_all+1] = {name=r.name, quality=r.quality, count=moved} end
    end
    if #moved_all > 0 and api.moved then pcall(api.moved, p, silo, moved_all) end
    local out = {silo=string.format('%s at %s', silo.name, at(silo.position)), loaded=rows,
      cargo=list_text(contents(inv)), rocket_weight=api.rocket_weight(silo), slots=used_slots(inv) .. '/' .. #inv,
      chests=#chests > 0 and #chests or nil, complete=#short == 0, short=#short > 0 and short or nil}
    -- up_to (Sonnet 07:50: a launch stayed unlaunched when weight ran short, about 5 retries a shift): what fits and
    -- what you and the chests hold is loaded; a short row does not stop the launch, which goes with what is aboard of
    -- the list (none of it aboard: refused). min_cargo still guards it.
    if a.up_to and #short > 0 then
      out.up_to_short = short; out.short = nil
      local any = false
      for _, r in ipairs(list) do if aboard(inv, r) > 0 then any = true end end
      if a.launch and not any then
        error(string.format('not launched (up_to): none of the list is aboard: %s; the rocket holds %s, %s',
          table.concat(short, '; '), out.cargo, out.rocket_weight), 0)
      end
    end
    if a.launch then
      if #short > 0 and not a.up_to then
        error(string.format('not launched: %s; what was loaded stays in the rocket (it holds %s, %s); %s, or load the rest (to_total=true counts what is aboard)',
          table.concat(short, '; '), out.cargo, out.rocket_weight, M.as_is(silo, a)), 0)
      end
      local ok, launched = pcall(api.launch, p, {position=silo.position, platform=a.platform, orbit=a.orbit, min_cargo=a.min_cargo, arrived=a.arrived})
      if not ok then
        error(string.format('loaded, then the launch was refused: %s; the cargo stays in the rocket (it holds %s, %s); %s',
          api.reason and api.reason(launched) or tostring(launched), out.cargo, out.rocket_weight, M.as_is(silo, a)), 0)
      end
      out.launch = launched
    end
    return out
  end
  -- Ready to rerun a waiting load_silo: the rocket is there (and ready, for a launch), or the silo is gone.
  -- The waiting goes on while the silo makes parts (Sonnet, shift14 22:50: load_silo re-issued 3 times as its wait ran
  -- out each minute through the build): ticks is the initial idle window. Observed intervals to part increases
  -- grow it; the wait ends at give_up in all.
  M.MAX_WAIT = 216000  -- 1 game hour
  local function progress_mark(silo)
    local parts = try(function() return silo.rocket_parts end) or 0
    local st = try(function() return silo.rocket_silo_status end) or 0
    local built = M.rocket_inventory(silo) and 1 or 0
    return built * 1000000 + st * 1000 + parts
  end
  function M.wait_fields(silo, ticks)
    return {stall=ticks, idle_ticks=ticks, give_up=game.tick + math.max(ticks, M.MAX_WAIT), mark=progress_mark(silo),
      parts=try(function() return silo.rocket_parts end) or 0, part_tick=game.tick, parts_added=0, observed_ticks=0}
  end
  -- The measured cadence belongs to this wait and this silo.
  -- A burst's spacing sets the idle window; its part count sets the rate.
  -- Never shrink the window after a faster burst, or extend it just because
  -- a poll happened. A part-counter rollover adds nothing and retains the
  -- measured rate: rocket completion must not erase it from the reply.
  function M.wait_report(action)
    local w=action.await_silo
    if not w then return nil end
    local elapsed=w.observed_ticks or 0
    return {parts=w.parts, parts_added=w.parts_added or 0, observed_s=elapsed/60,
      parts_per_min=elapsed>0 and (w.parts_added or 0)*3600/elapsed or nil,
      rate_basis=elapsed>0 and 'part-count increases observed during this wait' or 'no part-count increase observed during this wait',
      last_part_ago_s=(w.parts_added or 0)>0 and w.part_tick and (game.tick-w.part_tick)/60 or nil,
      idle_window_s=(w.idle_ticks or w.stall or 3600)/60, gives_up_tick=w.give_up}
  end
  function M.ready(p, action)
    local w = action.await_silo
    local silo = w and try(function() return api.reach_entity(p, w.position) end)
    if not (silo and silo.valid and silo.type == 'rocket-silo') then return true end
    if w.stall then
      local parts=try(function() return silo.rocket_parts end) or 0
      local mark = progress_mark(silo)
      w.idle_ticks=w.idle_ticks or w.stall
      if w.parts and parts>w.parts then
        local gap=game.tick-(w.part_tick or game.tick)
        w.parts_added=(w.parts_added or 0)+parts-w.parts
        w.observed_ticks=(w.observed_ticks or 0)+gap
        w.part_tick=game.tick
        w.idle_ticks=math.max(w.idle_ticks,3*gap)
      elseif not w.parts then
        w.parts_added,w.observed_ticks,w.part_tick=0,0,game.tick
      end
      w.parts=parts
      if mark ~= w.mark then
        w.mark = mark
        action.until_tick = math.min(w.give_up, math.max(action.until_tick or 0, game.tick + w.idle_ticks))
      end
    end
    if not M.rocket_inventory(silo) then return false end
    if w.launch and not ready(silo) then return false end
    -- The platform still on its way here: the wait goes on to give_up; it left for elsewhere: the load reruns and refuses.
    if w.launch and w.platform ~= nil then
      local ok, gate = pcall(M.platform_gate, p, {launch=true, platform=w.platform}, silo)
      if ok and gate == 'headed' then
        action.until_tick = math.min(w.give_up or game.tick + 3600, math.max(action.until_tick or 0, game.tick + 1800))
        return false
      end
    end
    return true
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
    if inv and a.launch then
      local gate, gate_why = M.platform_gate(p, a, silo)
      if gate == 'away' then error(gate_why .. '; nothing walked', 0) end
    end
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
      error(string.format('nothing to load: the rocket holds the list already (%s); nothing walked; %s', list_text(contents(inv)), M.as_is(silo, a)), 0)
    end
    local first, todo = trip(p, action, p.position, rows)
    local taking, held_any = false, false
    for _, n in ipairs(rows) do
      if n.take > 0 then taking = true end
      if n.held > 0 then held_any = true end
    end
    if not taking and not held_any then
      error(string.format('nothing walked: the rocket still needs %s and none of it fits under its lift (it holds %s, %s)%s; %s',
        need_text(rows), list_text(contents(inv)), api.rocket_weight(silo),
        a.to_total and '' or ' (items adds to what is aboard; to_total=true counts what is aboard)', M.as_is(silo, a)), 0)
    end
    if taking and not todo and not held_any then
      error(string.format('nothing walked: the rocket still needs %s and the chests in from hold none of it (%s)', need_text(rows), chests_text(action, rows)), 0)
    end
    local entities = {}
    for i, c in ipairs(first) do entities[i] = c end
    entities[#entities+1] = silo
    local fields = {ordered=true, load=load, silo=silo, chests=chests, goals=goals, trips=1, taken=0, loaded=0, rows={}, items={},
      avoid_enemies=a.avoid_enemies, unsafe_goal=a.unsafe_goal, started_tick=game.tick}
    local rk = api.rocket and try(function() return api.rocket(silo) end)
    local reply = {op='load_silo', walk=true, silo=string.format('%s at %s', silo.name, at(silo.position)), needs=need_text(rows),
      chests=chests_text(action, rows), trip=#first .. ' chest' .. (#first == 1 and '' or 's') .. ', then the silo', rocket=rk and rk.rocket or nil,
      note=a.launch and 'launch: at the silo the tour waits for the rocket to be ready before it loads, then loads and launches in that tick' or nil}
    return {entities=entities, fields=fields, reply=reply}
  end
  -- One stop of the tour: a chest (take) or the silo (load, then another trip, the end, or the launch).
  -- Returns {transferred, stop} as the tour's visits do.
  -- The rocket this tour loads launched by another hand (Grok: a gather went on into the next rocket after Astra
  -- launched the 885-pack one): the tour ends there, rocket_launched, naming the launch.
  local function launched_since(action)
    local r = api.last_launch and action.started_tick and try(function() return api.last_launch(action.silo) end)
    if r and r.tick and r.tick >= action.started_tick and not action.launch then return r end
  end
  function M.walk_visit(p, action, e)
    local gone = launched_since(action)
    if gone then
      action.final = 'rocket_launched'
      action.why = string.format('the rocket this load was filling launched %d s ago%s (cargo: %s); the load ends: what you carry stays with you',
        math.floor((game.tick - gone.tick) / 60), gone.by and ' by ' .. gone.by or '', tostring(gone.cargo or 'empty'))
      action.rows[#action.rows+1] = {position=e.position, name=e.name, trip=action.trips, why=action.why}
      return {transferred=0, stop='rocket_launched'}
    end
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
    -- No rocket yet, or launch=true before it is ready (Astra 06:23: twice the walking load put cargo in a rocket not yet
    -- ready and the silo's automatic requests took it out again): the tour holds at the silo and loads nothing, as the
    -- load without walk waits (M.ready: while the silo makes parts the wait goes on, at most to give_up), checked
    -- every 30 ticks; then it loads, and launches in that tick.
    -- The platform not in orbit here yet: the tour holds at the silo as for the rocket; gone elsewhere: it ends there.
    local gate, gate_why = 'here', nil
    if inv and action.load.launch and ready(e) then
      local okg, g, why = pcall(M.platform_gate, p, action.load, e)
      if okg then gate, gate_why = g, why end
    end
    if gate == 'away' then
      action.final = 'short'; action.why = gate_why
      action.rows[#action.rows+1] = {position=e.position, name=e.name, trip=action.trips, loaded=0, why=gate_why}
      return {transferred=0, stop='short'}
    end
    if not inv or (action.load.launch and not ready(e)) or gate == 'headed' then
      local hold = action.silo_hold
      if not hold then
        hold = M.wait_fields(e, action.hold_ticks or 3600)
        hold.position = e.position; hold.launch = action.load.launch == true; hold.since = game.tick
        hold.platform = action.load.launch and action.load.platform or nil
        action.silo_hold = hold; action.hold_check = game.tick
        action.rows[#action.rows+1] = {position=e.position, name=e.name, trip=action.trips, loaded=0,
          why=not inv and 'no rocket to load yet: waiting at the silo' or gate == 'headed' and gate_why .. ': waiting at the silo'
            or 'the rocket is not ready to launch yet: waiting at the silo, nothing loaded'}
      end
      if game.tick >= (action.hold_check or 0) then
        action.hold_check = game.tick + 30
        local view = {await_silo=hold, until_tick=action.until_tick}
        local done = M.ready(p, view)
        if view.until_tick and view.until_tick > (action.until_tick or 0) then action.until_tick = view.until_tick end
        if not done then
          action.why = gate == 'headed' and ('waiting at the silo: ' .. gate_why)
            or string.format('waiting at the silo for %s (%s); nothing loaded yet', not inv and 'a rocket' or 'the rocket to be ready', rk and rk.rocket_now or 'no rocket')
          return {transferred=0, wait=true}
        end
        inv = M.rocket_inventory(e)
        rk = api.rocket and try(function() return api.rocket(e) end)
        action.why = nil
        if not inv then return {transferred=0, wait=true} end
      else
        return {transferred=0, wait=true}
      end
    elseif action.silo_hold then
      action.why = nil
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
        action.why = string.format('loaded, not launched: %s', rk and rk.rocket_now or 'the rocket is not ready')
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
      -- up_to: what is aboard goes (Sonnet 07:50), launched when launch=true; none of the list aboard is still short.
      if action.load.up_to then
        local any = false
        for _, g in ipairs(action.goals) do if aboard(inv, g) > 0 then any = true end end
        if any then
          local note = string.format('up_to: the rocket still lacks %s: %s', need_text(rows), why)
          if not action.load.launch then action.final = 'loaded'; action.why = note; return {transferred=n, stop='loaded'} end
          local a = action.load
          local ok, launched = pcall(api.launch, p, {position=e.position, platform=a.platform, orbit=a.orbit, min_cargo=a.min_cargo, arrived=a.arrived})
          if ok then action.final = 'launched'; action.launch = launched; action.why = note; return {transferred=n, stop='launched'} end
          action.final = 'loaded'
          action.why = string.format('%s; then the launch was refused: %s; the cargo stays in the rocket', note, api.reason and api.reason(launched) or tostring(launched))
          return {transferred=n, stop='loaded'}
        end
      end
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
    last.silo_wait = action.silo_hold and M.wait_report({await_silo=action.silo_hold}) or nil
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
          quality = quality or 'normal'
          local from = f.import_from and (type(f.import_from) == 'string' and f.import_from or try(function() return f.import_from.name end))
          if type(name) == 'string' and from == planet and (f.min or 0) > 0 and (sec.multiplier or 1) > 0 then
            local k = key(name, quality)
            if not out[k] then out[k] = {name=name, quality=quality, min=0}; order[#order+1] = out[k] end
            out[k].min = out[k].min + math.floor(f.min * (sec.multiplier or 1))
          end
        end
      end
    end
    return order
  end
  local function one_line(s) return (s:gsub('[%c]+', ' ')) end
  -- The next scheduled stop is a fact, not a departure time. A stopped ship has no flight ETA.
  function platform_view(pl, here, inv, held, unmet_only, route_only)
    local w = where(pl)
    local plat = {name=pl.name, where=w.text, at=w.at, arrived=w.stopped == true and w.at == here}
    local l = w.leg
    local sch = try(function() return pl.schedule end)
    local records = sch and sch.records or {}
    local current = sch and sch.current or 1
    local rec = records[current]
    local next_stop = rec and rec.station
    if not l and next_stop == w.at and #records > 1 then next_stop = records[current % #records + 1].station end
    plat.next_stop = l and l.to or next_stop
    plat.headed_here = not plat.arrived and plat.next_stop == here and
      (l ~= nil or try(function() return pl.paused end) ~= true) or false
    local timing
    if plat.arrived then
      plat.eta_s, plat.eta_to = 0, here
      timing = 'arrived'
    elseif l then
      plat.from, plat.to, plat.distance_left_km = l.from, l.to, l.left_km
      plat.connection_length_km, plat.flown_fraction = l.length, l.flown
      local speed = try(function() return pl.speed end)
      plat.speed_km_s = type(speed) == 'number' and speed * 60 or nil
      plat.eta_to = l.to
      if type(speed) == 'number' and speed > 0 and type(l.left_km) == 'number' then
        plat.eta_s = math.ceil(math.max(0, l.left_km) / speed / 60)
        plat.eta_basis = 'distance_left_km = (1 - flown_fraction) * connection_length_km; eta_s = ceil(distance_left_km / speed_km_s); speed_km_s = game speed * 60 ticks per game second; excludes waits and later legs'
        timing = string.format('ETA to %s %ds (%g km left / %g km/s, current speed)', l.to, plat.eta_s, l.left_km, plat.speed_km_s)
      else
        plat.eta_unknown = 'current speed is zero or unavailable'
        timing = 'ETA to ' .. l.to .. ' unknown: ' .. plat.eta_unknown
      end
    else
      plat.eta_unknown = 'not on a connection; departure time and flight speed are unknown'
      timing = 'ETA unknown: ' .. plat.eta_unknown .. (plat.next_stop and '; next scheduled stop ' .. plat.next_stop or '')
    end
    if not plat.arrived and plat.eta_to ~= here then
      plat.arrival_unknown = 'no timed current connection to ' .. here
      timing = timing .. '; arrival at ' .. here .. ' unknown'
    end
    if route_only then return plat end
    local hub_inv = try(function() return pl.hub.get_inventory(defines.inventory.hub_main) end)
    local hub_trash = defines.inventory.hub_trash and try(function() return pl.hub.get_inventory(defines.inventory.hub_trash) end)
    plat.freshness = api.fresh_inv and api.fresh_inv(pl.force, hub_inv, nil, l and l.eta_ticks, hub_trash) or nil
    -- Keep qualities separate, including cargo moved to the hub's trash inventory.
    local hub = {}
    for _, id in ipairs({'hub_main', 'hub_trash'}) do
      local hinv = defines.inventory[id] and try(function() return pl.hub.get_inventory(defines.inventory[id]) end)
      for _, r in ipairs(contents(hinv)) do
        local k = key(r.name, r.quality); hub[k] = (hub[k] or 0) + r.count
      end
    end
    local asks, lacking, asked = {}, {}, {}
    for _, r in ipairs(hub_requests(pl, here)) do
      local k = key(r.name, r.quality)
      asked[k] = true
      local n, h = aboard(inv, r), hub[k] or 0
      local lack = math.max(0, r.min - h)
      local row = {item=label(r), min=r.min, hub=h, aboard=n, lacks=lack > 0 and lack or nil,
        lacks_after=math.max(0, lack - n)}
      if row.lacks_after == 0 then row.lacks_after = nil end
      if not unmet_only or lack > 0 then
        asks[#asks+1] = row
        lacking[#lacking+1] = string.format('%s lacks %d (rocket %d, lacks_after %d)', row.item, lack, n, row.lacks_after or 0)
      end
    end
    plat.requests = #asks > 0 and asks or nil
    local extra = {}
    for _, r in ipairs(held) do if not asked[key(r.name, r.quality)] then extra[#extra+1] = label(r) .. '*' .. r.count end end
    plat.not_requested = #extra > 0 and table.concat(extra, ' ') or nil
    plat.line = one_line(string.format('platform %s %s; %s; requests from %s: %s', pl.name, w.text, timing, here,
      #lacking > 0 and table.concat(lacking, ', ') or (unmet_only and 'none unmet' or 'none')))
    if plat.freshness then plat.line = plat.line .. '; hub cargo: ' .. table.concat(plat.freshness, '; ') end
    return plat
  end
  local function platforms(p, a, here, inv, held, extra_cache)
    if a.platform ~= nil then
      local pl = api.platform(p, a.platform)
      local plat = platform_view(pl, here, inv, held, false)
      -- Destination diagnostics (round2250b): shared within this call when comparing several silos.
      -- Incoming cargo stays separate from lacks_after, which counts only the hub and this rocket.
      local id = pl.index or pl.name
      local extra = extra_cache[id]
      if not extra then
        extra = {}
        local inc = api.incoming and try(function() return api.incoming(pl) end)
        if inc then
          extra.incoming = inc.lines
          extra.incoming_cargo = string.format('%d rocket%s on the way: %s', inc.rockets, inc.rockets == 1 and '' or 's', inc.cargo)
        end
        extra.ammo_rates = api.ammo and try(function() return api.ammo(pl) end) or nil
        extra.hub_chunks = api.hub_chunks and try(function() return api.hub_chunks(pl) end) or nil
        -- Each empty turret taking ammo the hub holds, and what feeds it (platalerts.lua; Sol, Astra 00:21).
        local empty = api.empty_turrets and try(function() return api.empty_turrets(pl) end)
        extra.empty_turrets = empty and #empty > 0 and empty or nil
        extra_cache[id] = extra
      end
      for k, v in pairs(extra) do plat[k] = v end
      if plat.incoming_cargo then plat.line = one_line(plat.line .. '; ' .. plat.incoming_cargo) end
      if plat.empty_turrets then plat.line = one_line(plat.line .. '; ' .. table.concat(plat.empty_turrets, '; ')) end
      return {plat}
    end
    local out = {}
    for _, pl in pairs(p.force.platforms or {}) do
      if pl.valid then
        local v = platform_view(pl, here, inv, held, true, true)
        if v.arrived or v.headed_here then out[#out+1] = platform_view(pl, here, inv, held, true) end
      end
    end
    table.sort(out, function(x, y)
      if x.arrived ~= y.arrived then return x.arrived end
      if x.eta_s ~= y.eta_s then return (x.eta_s or math.huge) < (y.eta_s or math.huge) end
      return x.name < y.name
    end)
    return out
  end
  local function add_platforms(out, words, p, a, here, inv, held, extra_cache)
    local list = platforms(p, a, here, inv, held, extra_cache)
    if a.platform ~= nil then out.platform = list[1] else out.platforms = list end
    for _, pl in ipairs(list) do words[#words+1] = pl.line end
    if #list == 0 then words[#words+1] = 'no platforms stopped at or headed to ' .. here end
  end
  function M.preflight(p, a, extra_cache)
    extra_cache = extra_cache or {}
    assert(a.from == nil or a.items ~= nil, 'from requires items')
    if a.position == nil then
      -- Discovery reuses the census's existing sliced walk. A read never starts a surface scan.
      local found, as_of = api.silos(p)
      local here = try(function() return p.surface.planet.name end) or p.surface.name
      local out = {surface=p.surface.name, silos={}, silos_as_of=as_of, silos_pending=as_of == nil or nil}
      local words = {'preflight on ' .. here}
      table.sort(found, function(x, y)
        local dx = (x.position.x - p.position.x)^2 + (x.position.y - p.position.y)^2
        local dy = (y.position.x - p.position.x)^2 + (y.position.y - p.position.y)^2
        if dx ~= dy then return dx < dy end
        if x.position.x ~= y.position.x then return x.position.x < y.position.x end
        return x.position.y < y.position.y
      end)
      for _, silo in ipairs(found) do
        if silo.valid and p.force.is_chunk_visible(p.surface, {x=math.floor(silo.position.x/32), y=math.floor(silo.position.y/32)}) then
          local row = M.preflight(p, {position=silo.position, platform=a.platform, items=a.items, from=a.from}, extra_cache)
          out.silos[#out.silos+1] = row
          words[#words+1] = row.line
        end
      end
      if #out.silos == 0 then words[#words+1] = 'no visible silos in the discovery index' end
      words[#words+1] = as_of and 'silo discovery as of tick ' .. as_of or 'silo discovery pending the background census'
      if #out.silos == 0 then add_platforms(out, words, p, a, here, nil, {}, extra_cache) end
      out.line = one_line(table.concat(words, '; '))
      return out
    end
    local silo = api.remote_entity(p, {position=a.position, name=a.name, unit_number=a.unit_number})
    assert(silo.type == 'rocket-silo', silo.name .. ' at ' .. at(silo.position) .. ' is not a rocket silo')
    local here = planet_of(silo)
    local inv = M.rocket_inventory(silo)
    local lift, slots = api.cargo.limits(silo)
    local held = contents(inv)
    local g = grams(held)
    local used = used_slots(inv)
    local rk = api.rocket and try(function() return api.rocket(silo) end)
    local out = {position={x=silo.position.x, y=silo.position.y}, parts=rk and rk.parts, built_parts=rk and rk.built_parts, next_parts=rk and rk.next_parts,
      silo=string.format('%s at %s on %s', silo.name, at(silo.position), tostring(here)), rocket=rk and rk.rocket or nil,
      rocket_ready=ready(silo), auto_requests=try(function() return silo.use_transitional_requests end) and true or false}
    local rows = {}
    for _, r in ipairs(held) do
      rows[#rows+1] = {item=label(r), count=r.count, each_kg=kg(weight(r.name)), kg=kg(weight(r.name) * r.count),
        stacks=math.ceil(r.count / stack_size(r.name))}
    end
    table.sort(rows, function(x, y) if x.kg ~= y.kg then return x.kg > y.kg end return x.item < y.item end)
    out.cargo = {items=inv and list_text(held) or 'no rocket to load yet', rows=#rows > 0 and rows or nil, kg=kg(g), lift_kg=kg(lift),
      free_kg=kg(math.max(0, lift - g)), over_kg=g > lift and kg(g - lift) or nil, slots=used .. '/' .. slots, free_slots=math.max(0, slots - used)}
    local words = {string.format('%s: %s; cargo %s, %g/%g kg, %d/%d slots', out.silo, out.rocket or 'rocket state unknown', out.cargo.items, kg(g), kg(lift), used, slots)}
    out.cargo.freshness = api.fresh_inv and api.fresh_inv(p.force, inv) or nil
    if out.cargo.freshness then words[#words+1] = 'rocket cargo: ' .. table.concat(out.cargo.freshness, '; ') end
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
      local order, lacking, sources, seen = {}, {}, {}, {}
      for _, pos in ipairs(a.from and from_list(a.from) or {}) do
        local e = api.remote_entity(p, {position=pos})
        assert(e.force == p.force and e.surface == silo.surface, 'from must be our chest on the silo surface')
        local ci = chest_inventory(e)
        assert(ci, 'from: ' .. e.name .. ' has no chest inventory')
        local id = e.unit_number or at(e.position)
        if not seen[id] then
          seen[id] = true
          sources[#sources+1] = {name=e.name, position={x=e.position.x,y=e.position.y}, inv=ci, items={}}
        end
      end
      local manifest_g, manifest_slots, after_g, after_slots = 0, 0, g, used
      for _, r in ipairs(list) do
        local n = aboard(inv, r)
        local lacks = math.max(0, r.count - n)
        local row = {item=label(r), want=r.count, aboard=n, lacks=lacks > 0 and lacks or nil,
          you_hold=try(function() return p.get_main_inventory().get_item_count{name=r.name, quality=r.quality} end) or 0}
        if lacks > 0 then
          row.fits = math.min(lacks, fits(r))
          lacking[#lacking+1] = string.format('%s %d (%d fit)', row.item, lacks, row.fits)
        end
        row.kg = kg(weight(r.name) * r.count)
        row.slots = math.ceil(r.count / stack_size(r.name))
        manifest_g = manifest_g + weight(r.name) * r.count
        manifest_slots = manifest_slots + row.slots
        after_g = after_g + weight(r.name) * lacks
        after_slots = after_slots + math.ceil((n+lacks)/stack_size(r.name)) - math.ceil(n/stack_size(r.name))
        if a.from then
          row.from_held = 0
          for _, src in ipairs(sources) do
            local count = src.inv.get_item_count{name=r.name,quality=r.quality}
            src.items[row.item] = count
            row.from_held = row.from_held + count
          end
          row.from_short = math.max(0, lacks-row.from_held)
          row.short = math.max(0, lacks-row.from_held-row.you_hold)
        end
        order[#order+1] = row
      end
      for _, src in ipairs(sources) do src.inv = nil end
      out.from = a.from and sources or nil
      out.manifest = {kg=kg(manifest_g), slots=manifest_slots, lift_kg=kg(lift), cargo_slots=slots,
        after_kg=kg(after_g), after_slots=after_slots, fits=after_g<=lift and after_slots<=slots}
      words[#words+1] = string.format('manifest %g kg, %d slots; cargo after filling it %g/%g kg, %d/%d slots',
        kg(manifest_g),manifest_slots,kg(after_g),kg(lift),after_slots,slots)
      if a.from then
        local counts = {}
        for _, row in ipairs(order) do counts[#counts+1] = string.format('%s: chests hold %d, short %d (short %d after your inventory)',row.item,row.from_held,row.from_short,row.short) end
        words[#words+1] = table.concat(counts,'; ')
      end
      out.order = order
      words[#words+1] = #lacking > 0 and 'the list lacks ' .. table.concat(lacking, ', ') or 'the list is aboard'
    end
    add_platforms(out, words, p, a, here, inv, held, extra_cache)
    -- Automatic requests on (Sol 04:50): what automatic loading waits for, per request of the platforms above (silo.lua).
    if out.auto_requests and api.auto_wait then
      local okw, w = pcall(api.auto_wait, silo, p.force, held)
      if okw and w then out.auto_waits = w; words[#words+1] = 'automatic loading: ' .. w end
    end
    -- What launch would refuse now.
    local refuse = {}
    if not out.rocket_ready then refuse[#refuse+1] = rk and rk.rocket_now or 'the rocket is not ready' end
    if g > lift then refuse[#refuse+1] = string.format('overweight by %g kg', kg(g - lift)) end
    if inv and #held == 0 then refuse[#refuse+1] = 'empty (allow_empty=true launches it so)' end
    if out.platform and not out.platform.arrived then refuse[#refuse+1] = 'platform ' .. out.platform.name .. ' is not stopped at ' .. tostring(here) end
    out.launch_now = #refuse > 0 and 'refused: ' .. table.concat(refuse, '; ') or 'ok'
    words[#words+1] = 'launch now: ' .. out.launch_now
    out.line = one_line(table.concat(words, '; '))
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
          local complete, any = true, false
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
            if (x.cargo[k] or 0) > 0 then any = true end
          end
          if a.launch then
            if complete or (a.up_to and any) then launch(i, st, x, a)
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
      fresh_first='default true for an item that spoils (agricultural science, bioflux, ...): the stacks of you and the chests read, least spoiled first, each moved whole (its spoilage goes with it; the row says order: fresh first); false: you first, then the chests in order, slot by slot',
      walk='true, with from: one timed call that walks between the chests in from and the silo, as many trips as it takes (at most 20): at each chest it takes what the rocket still needs less what you hold (up to your request max), at the silo it loads what you hold of the list; another trip while the rocket still needs some, a chest in from holds it and the trip loaded any. No rocket at the silo yet, or with launch a rocket not ready: the tour waits at the silo and loads nothing until it is (as without walk: the wait goes on while the silo makes parts; status and last silo_wait), then loads and launches in that tick. The silo and every chest in reach: the load at once, as without walk. Nothing in the chests and nothing held of what the rocket needs: refused, nothing walked. Outcomes loaded | launched | short (last.why: weight, slots, the chests empty, a trip that loaded none) | unreached | timed_out (also while waiting at the silo: last.why says for what; what you took stays with you); last: trips, taken, taken_items, loaded, stops [{position, name, trip, taken | loaded, full, note}], cargo, rocket_weight, launch',
      avoid_enemies='with walk: as move_to\'s; each leg goes round the worms, spawners and attacks the map shows, and a stop inside one is left out',
      unsafe_goal='with walk: true walks to such a stop anyway',
      up_to='true: load what fits (weight, slots) and what you and the chests hold; a short row is listed in up_to_short and does not fail the call or stop a launch, which goes with what is aboard (none of the list aboard: refused); with walk the tour ends loaded (or launched) instead of short',
      launch='true: launch once the rocket is ready, in the tick the cargo is loaded; needs platform (or orbit=true); refused (not launched, an error) when any count fell short (up_to aside); min_cargo and arrived are checked as launch checks them',
      platform='with launch: the platform in orbit to send it to', orbit='with launch: true for no platform',
      min_cargo='with launch: as launch min_cargo', arrived='with launch: as launch arrived',
      ticks='1..36000 (default 3600): how long to wait for the rocket (no rocket yet, or not ready for a launch) with no new rocket part: the idle window grows to at least 3 times the longest observed interval to a part increase; the wait goes on while the silo makes parts (or the rocket moves on to ready), 1 game hour at most in all (gives_up_tick); with walk, the whole tour (default 18000)',
      returns='silo, loaded [{item, asked, aboard_before, loaded, aboard, from (you N, iron-chest (x,y) N), freshness (a spoilable item: the loaded batch\'s spread and, for a pack the running research takes, how many a unit the running research takes and its units left), short, why (weight, slots, or what you and the chests held)}], cargo, rocket_weight, slots (used/total), chests (how many were read), complete, short; launch (the launch reply) with launch=true. No rocket yet, or launch=true before the rocket is ready: a timed action (until_tick, waiting {why, rocket}; outcome fed | failed | timed_out; last.result holds the reply). Into the rocket only what fits under its 1000 kg lift and in its cargo slots; a silo with automatic requests on is refused'},
    preflight = {from='with items: one chest position or 1..16, readable in sight or remote view; per-chest stock, order.from_held, from_short (less what is aboard), short (also less you_hold); repeated chests counted once; nothing moved',position='optional rocket silo {x,y} (any tile of it), in a visible chunk (remote view); omitted: all visible silos in the background census index, nearest your coordinates first',
      surface='optional planet name (default yours); platform remains the rocket destination',
      items='optional item list (as load_silo items): what each rocket still lacks against the cargo aboard, and how much of that fits',
      platform='optional platform name: location, arrival/next stop, current-connection ETA and its calculation, requests importing from this planet less its hub and this rocket, incoming rockets, ammo per type over the last leg, and hub slots asteroid chunks take; omitted: our platforms stopped here or flying/scheduled next here (paused departures excluded), with unmet requests from here',
      returns='position, silo, rocket, rocket_ready, parts (building), built_parts (ready/rising), next_parts, auto_requests, cargo {items, freshness (spoil spread and effective research units for spoilable packs now, before lab bonuses), rows [{item, count, each_kg, kg, stacks}], kg, lift_kg, free_kg, over_kg, slots, free_slots}, '
        .. 'order [{item, want, aboard, lacks, fits, you_hold}], platform (named) or platforms (discovery) [{name, where, at, arrived, headed_here, next_stop, from, to, distance_left_km, connection_length_km, flown_fraction, speed_km_s, eta_to, eta_s (game seconds at current speed), eta_basis, eta_unknown, arrival_unknown (current leg does not end here), requests [{item, min, hub, aboard, lacks, lacks_after}], not_requested, line}], '
        .. 'With named platform: incoming (rockets launched to its hub not arrived yet), incoming_cargo, ammo_rates (per ammo type: made and used per minute over the last leg, current hub/turret stock and reserve at arrival), hub_chunks (slots asteroid chunks take); incoming cargo is separate from lacks_after. '
        .. 'launch_now (ok, or refused: what launch would refuse now), line (one line). No position: surface, silos [the same per-silo views, nearest first], silos_as_of (discovery tick; rocket/cargo read now), silos_pending (before first census); no visible silos: platform(s) still returned. Read only'},
  }
  return M
end
