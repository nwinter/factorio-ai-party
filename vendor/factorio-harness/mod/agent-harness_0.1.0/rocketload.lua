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
    for _, k in ipairs({'to_total', 'launch', 'chests'}) do
      assert(a[k] == nil or type(a[k]) == 'boolean', k .. ' must be true or false')
    end
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
      local moved, from = 0, {}
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
        local n = api.move_stacks(source, inv, match, goal - moved)
        if n > 0 then moved = moved + n; from[#from+1] = name .. ' ' .. n end
      end
      for _, source in ipairs(api.give_sources(p, r.name)) do take(source, 'you') end
      for _, c in ipairs(chests) do take(chest_inventory(c), c.name .. ' ' .. at(c.position)) end
      local row = {item=label(r), asked=r.count, aboard_before=before, loaded=moved, aboard=before + moved,
        from=#from > 0 and table.concat(from, ', ') or nil}
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
      from='optional chest {x,y} or 1..16 of them, within reach: take from these (after your inventory); default: your inventory, then our chests within reach, nearest first (at most 16): every chest kind (chests, logistic chests, linked and infinity chests) and a cargo landing pad',
      chests='false: your inventory only',
      launch='true: launch once the rocket is ready, in the tick the cargo is loaded; needs platform (or orbit=true); refused (not launched, an error) when any count fell short; min_cargo and arrived are checked as launch checks them',
      platform='with launch: the platform in orbit to send it to', orbit='with launch: true for no platform',
      min_cargo='with launch: as launch min_cargo', arrived='with launch: as launch arrived',
      ticks='1..36000 (default 3600): how long to wait for the rocket (no rocket yet, or not ready for a launch)',
      returns='silo, loaded [{item, asked, aboard_before, loaded, aboard, from (you N, iron-chest (x,y) N), short, why (weight, slots, or what you and the chests held)}], cargo, rocket_weight, slots (used/total), chests (how many were read), complete, short; launch (the launch reply) with launch=true. No rocket yet, or launch=true before the rocket is ready: a timed action (until_tick, waiting {why, rocket}; outcome fed | failed | timed_out; last.result holds the reply). Into the rocket only what fits under its 1000 kg lift and in its cargo slots; a silo with automatic requests on is refused'},
    preflight = {position='the rocket silo {x,y} (any tile of it), in a visible chunk (remote view)', surface='optional planet name: the silo there by remote view',
      items='optional item list (as load_silo items): what it still lacks against the cargo aboard, and how much of that fits',
      platform='optional platform name: where it is, whether it has arrived here, and its requests from this planet less its hub and this rocket',
      returns='silo, rocket, rocket_ready, auto_requests, cargo {items, rows [{item, count, each_kg, kg, stacks}], kg, lift_kg, free_kg, over_kg, slots, free_slots}, '
        .. 'order [{item, want, aboard, lacks, fits, you_hold}], platform {name, where, arrived, requests [{item, min (from this planet), hub, aboard, lacks_after}], not_requested (cargo it does not request from here)}, '
        .. 'launch_now (ok, or refused: what launch would refuse now), line. Read only'},
  }
  return M
end
