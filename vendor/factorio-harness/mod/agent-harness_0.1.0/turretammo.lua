-- Ammo requests on turret ghosts (Astra, shift10: "15+ guns repeatedly rebuilt
-- empty and destroyed while bots waste gun stock"; operator 06:20 item 10). A
-- turret ghost placed by place_ghosts, paste or blueprint_place, and the ghost
-- the game leaves where one of our turrets died, gets an insert plan (2.0 item
-- requests) for ammo into the turret's ammo slots: the construction robots that
-- build the turret bring the ammo too, from the logistic network, as they do
-- for a blueprint whose turrets request ammo. A ghost that requests ammo
-- already (a blueprint's) keeps its request.
-- Which ammo: a call's `ammo` (an item name, or {name?, count?}; false for
-- none). The default item is, of the ammo the turret takes, the one the
-- logistic network at the ghost holds most of, else the first in prototype
-- order (firearm-magazine for a gun turret); for a turret that died, the ammo
-- it held. The default count is the turret's automated_ammo_count (what
-- inserters keep in it: 10 for a gun turret), at most what its slots hold.
return function(api)
  local M = {}
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  -- Ammo item names by ammo category, in prototype order (prototypes do not change while the game runs).
  local BY_CATEGORY
  local function ammo_items(category)
    if not BY_CATEGORY then
      BY_CATEGORY = {}
      local list = {}
      for name, item in pairs(try(function() return prototypes.get_item_filtered{{filter='type', type='ammo'}} end) or {}) do
        list[#list+1] = {name=name, order=try(function() return item.order end) or '', category=try(function() return item.ammo_category.name end)}
      end
      table.sort(list, function(a, b) return a.order < b.order or (a.order == b.order and a.name < b.name) end)
      for _, x in ipairs(list) do
        if x.category then
          BY_CATEGORY[x.category] = BY_CATEGORY[x.category] or {}
          table.insert(BY_CATEGORY[x.category], x.name)
        end
      end
    end
    return BY_CATEGORY[category] or {}
  end
  local function stack_size(name) return try(function() return prototypes.item[name].stack_size end) or 1 end

  -- What a turret prototype takes: {inventory, items (ammo names), count (the default), slots}; nil for one that
  -- takes no ammo items (a flamethrower or laser turret, anything else).
  function M.takes(proto)
    local t = proto and try(function() return proto.type end)
    local inv = t == 'ammo-turret' and defines.inventory.turret_ammo or t == 'artillery-turret' and defines.inventory.artillery_turret_ammo or nil
    if not inv then return nil end
    local items = {}
    for _, category in ipairs(try(function() return proto.attack_parameters.ammo_categories end) or {}) do
      for _, name in ipairs(ammo_items(category)) do items[#items+1] = name end
    end
    if #items == 0 then return nil end
    return {inventory=inv, items=items, count=try(function() return proto.automated_ammo_count end) or 10,
      slots=math.max(1, try(function() return proto.get_inventory_size(inv) end) or 1)}
  end

  -- The ammo for a turret that takes t at pos: {name, count, network_holds (nil: no logistic network covers pos)}, or
  -- nil for what == false. what: nil (the default), an item name, or {name?, count?}; a name the turret does not
  -- take gives the default. held: the ammo a turret that died held.
  function M.choose(t, surface, force, pos, what, held)
    if what == false then return nil end
    local name, count
    if type(what) == 'string' then name = what elseif type(what) == 'table' then name, count = what.name, what.count end
    local fits = {}
    for _, n in ipairs(t.items) do fits[n] = true end
    if not fits[name] then name = nil end
    if not name and fits[held] then name = held end
    local network = try(function() return surface.find_logistic_network_by_position(pos, force) end)
    local function holds(n) return network and (try(function() return network.get_item_count(n) end) or 0) or nil end
    if not name then
      local most = 0
      for _, n in ipairs(t.items) do
        local c = holds(n) or 0
        if c > most then name, most = n, c end
      end
      name = name or t.items[1]
    end
    count = math.floor(tonumber(count) or t.count)
    count = math.max(1, math.min(count, t.slots * stack_size(name)))
    return {name=name, count=count, network_holds=holds(name)}
  end

  -- The plan for count of name: a stack per ammo slot, in order.
  local function plan(t, name, count)
    local stack, rows, left = stack_size(name), {}, count
    for i = 0, t.slots - 1 do
      if left <= 0 then break end
      local n = math.min(stack, left)
      rows[#rows+1] = {inventory=t.inventory, stack=i, count=n}
      left = left - n
    end
    return {id={name=name, quality='normal'}, items={in_inventory=rows}}
  end
  local function requests_into(plans, inv)
    for _, p in ipairs(plans or {}) do
      for _, at in ipairs(p.items and p.items.in_inventory or {}) do if at.inventory == inv then return true end end
    end
    return false
  end

  -- Puts an ammo request on a turret ghost. Returns {name, count, network_holds} it requests, or nil and why not:
  -- 'not a turret', 'kept' (it requests ammo already), 'none' (what == false), or the game's refusal.
  function M.request(ghost, what, held)
    if not (ghost and ghost.valid and try(function() return ghost.type end) == 'entity-ghost') then return nil, 'not a turret' end
    local t = M.takes(try(function() return ghost.ghost_prototype end))
    if not t then return nil, 'not a turret' end
    local plans = try(function() return ghost.insert_plan end) or {}
    if requests_into(plans, t.inventory) then return nil, 'kept' end
    local c = M.choose(t, ghost.surface, ghost.force, ghost.position, what, held)
    if not c then return nil, 'none' end
    plans[#plans+1] = plan(t, c.name, c.count)
    local ok, err = pcall(function() ghost.insert_plan = plans end)
    if not ok then return nil, tostring(err) end
    return c
  end

  -- (d17 batch33 A5, Sol 09:59: 7 railgun ghosts each asked 10 ammo by place_ghosts' default, 70 in the BOM, while an
  -- assembler aboard makes it) a turret ghost's ammo request changed or cleared in place, as a player edits a ghost's
  -- requests: its plans into the ammo slots go, the rest of its requests (modules) stay, and what (as for request:
  -- a name, {name?, count?}) takes their place; false clears them. Returns {before, after} as item*count text.
  function M.set(ghost, what)
    assert(ghost and ghost.valid and try(function() return ghost.type end) == 'entity-ghost', 'ammo with an item names a turret ghost\'s request (a built turret takes ammo by platform_rearm, deliver or transfer; ammo: false or item_requests: false removes a built entity\'s item requests)')
    local t = M.takes(try(function() return ghost.ghost_prototype end))
    assert(t, ghost.ghost_name .. ' is no turret that takes ammo items')
    local keep, before = {}, {}
    for _, pl in ipairs(try(function() return ghost.insert_plan end) or {}) do
      local ins, other, n = {}, {}, 0
      for _, at in ipairs(pl.items and pl.items.in_inventory or {}) do
        if at.inventory == t.inventory then n = n + (at.count or 1) else other[#other+1] = at end
      end
      local id = pl.id
      local name = type(id) == 'table' and (type(id.name) == 'string' and id.name or id.name and id.name.name) or id
      if n > 0 then before[#before+1] = tostring(name) .. '*' .. n end
      if #other > 0 or (pl.items and pl.items.grid) then
        keep[#keep+1] = {id=pl.id, items={in_inventory=#other > 0 and other or nil, grid=pl.items.grid}}
      end
    end
    local c = what ~= false and M.choose(t, ghost.surface, ghost.force, ghost.position, what) or nil
    if c then keep[#keep+1] = plan(t, c.name, c.count) end
    local ok, err = pcall(function() ghost.insert_plan = keep end)
    assert(ok, 'the game refused the ammo request: ' .. tostring(err))
    return {before=#before > 0 and table.concat(before, ' ') or 'none', after=c and (c.name .. '*' .. c.count) or 'none', network_holds=c and c.network_holds or nil}
  end
  -- What a call's ammo argument may be: nil, false, an ammo item name, or {name?, count?}.
  function M.check(what)
    if what == nil or what == false then return end
    local name, count = what, nil
    if type(what) == 'table' then name, count = what.name, what.count end
    assert(type(what) == 'string' or type(what) == 'table', 'ammo is an ammo item name, {name?, count?}, or false for none')
    if name ~= nil then
      local item = type(name) == 'string' and prototypes.item[name]
      assert(item and item.type == 'ammo', 'ammo: not an ammo item: ' .. tostring(name))
    end
    assert(count == nil or (type(count) == 'number' and count >= 1 and count == math.floor(count)), 'ammo count must be a whole number of at least 1')
  end

  -- The rows a call reports: one per item and count, with how many ghosts request it and what the logistic network
  -- at the first of them holds (none covering it: nil). rows: the list being built; c: what M.request returned.
  function M.add(rows, c)
    for _, r in ipairs(rows) do
      if r.item == c.name and r.count == c.count and r.default == c.default then r.ghosts = r.ghosts + 1; return end
    end
    rows[#rows+1] = {item=c.name, count=c.count, ghosts=1, network_holds=c.network_holds, default=c.default}
  end
  -- (A5) what place_ghosts added by default, and how to change it
  function M.default_note(rows)
    local parts = {}
    for _, r in ipairs(rows) do
      if r.default then parts[#parts+1] = string.format('%d turret ghost%s each request %d %s', r.ghosts, r.ghosts == 1 and '' or 's', r.count, r.item) end
    end
    if #parts == 0 then return nil end
    return 'by default ' .. table.concat(parts, ', ') .. ' (the entry\'s ammo: false for none, or {name, count}; configure {position, ammo} changes it on a ghost)'
  end

  -- One of our turrets died: its ghost (the game places one where the force rebuilds the dead) gets the request on
  -- the next tick, for the ammo it held.
  local MAX_PENDING = 64
  function M.on_died(e)
    local t = M.takes(try(function() return e.prototype end))
    if not t then return end
    local s = api.state()
    s.turret_deaths = s.turret_deaths or {}
    if #s.turret_deaths >= MAX_PENDING then return end
    local held
    local inv = try(function() return e.get_inventory(t.inventory) end)
    for _, x in ipairs(inv and try(function() return inv.get_contents() end) or {}) do held = held or x.name end
    s.turret_deaths[#s.turret_deaths+1] = {surface=e.surface.index, position={x=e.position.x, y=e.position.y}, name=e.name,
      force=e.force.name, held=held, tick=game.tick}
  end
  function M.tick(tick)
    local s = api.state()
    local list = s.turret_deaths
    if not list then return end
    local later = {}
    for _, d in ipairs(list) do
      if d.tick >= tick then later[#later+1] = d
      else
        local surface = game.get_surface(d.surface)
        local ghost = surface and try(function()
          return surface.find_entities_filtered{position=d.position, radius=0.5, type='entity-ghost', ghost_name=d.name, force=d.force, limit=1}[1]
        end)
        local st = s.turret_ammo or {requested=0, kept=0, no_ghost=0}
        s.turret_ammo = st
        if ghost then
          local c, why = M.request(ghost, nil, d.held)
          if c then
            st.requested = st.requested + 1
            st.last = {name=d.name, position=d.position, item=c.name, count=c.count, tick=tick}
          elseif why == 'kept' then st.kept = st.kept + 1 end
        else st.no_ghost = st.no_ghost + 1 end
      end
    end
    s.turret_deaths = #later > 0 and later or nil
  end
  -- (d19 batch41 A2, Sol seq 868-869: platform_rearm put 10 firearm-magazine requests on 5 railgun and 6 rocket turrets,
  -- and Sol rebuilt all 11 to clear them) a built entity's item requests: each plan as item*count, into or out of it.
  local function name_of(id)
    if type(id) ~= 'table' then return tostring(id) end
    local n = type(id.name) == 'string' and id.name or (id.name and try(function() return id.name.name end)) or '?'
    local q = type(id.quality) == 'string' and id.quality or (id.quality and try(function() return id.quality.name end))
    return n .. ((q and q ~= 'normal') and '@' .. q or '')
  end
  function M.requests(e)
    local proxy = try(function() return e.item_request_proxy end)
    if not (proxy and proxy.valid) then return nil end
    local into, out = {}, {}
    for _, key in ipairs({'insert_plan', 'removal_plan'}) do
      for _, pl in ipairs(try(function() return proxy[key] end) or {}) do
        local n = 0
        for _, at in ipairs(pl.items and pl.items.in_inventory or {}) do n = n + (at.count or 1) end
        local list = key == 'insert_plan' and into or out
        list[#list+1] = {item=name_of(pl.id), count=n, inventories=pl.items and pl.items.in_inventory}
      end
    end
    return {proxy=proxy, into=into, out=out}
  end
  local function text(list)
    local parts = {}
    for _, r in ipairs(list) do parts[#parts+1] = r.item .. '*' .. r.count end
    return table.concat(parts, ' ')
  end
  -- What of a built turret's requests into its ammo slots names ammunition it does not take: item*count text, or nil.
  function M.unusable(e)
    local t = M.takes(try(function() return e.prototype end))
    local r = t and M.requests(e)
    if not r then return nil end
    local fits, bad = {}, {}
    for _, n in ipairs(t.items) do fits[n] = true end
    for _, x in ipairs(r.into) do
      local slots = false
      for _, at in ipairs(x.inventories or {}) do if at.inventory == t.inventory then slots = true end end
      if slots and not fits[x.item] then bad[#bad+1] = x end
    end
    return #bad > 0 and text(bad) or nil
  end
  -- A built entity's item requests removed, as a player does on 2.0.77 (a private copy of world n, d19): a
  -- deconstruction planner over the entity removes its item-request-proxy at once and marks the entity, and cancelling
  -- that deconstruction unmarks it, leaving it with no request; order_deconstruction on the proxy alone does both in
  -- one step and never marks the entity. Every request on it goes (ammunition, modules, removals alike), as with the
  -- planner. Returns {into, out} as item*count text, or nil when it had none.
  function M.clear(e, force)
    local r = M.requests(e)
    if not r then return nil end
    local ok, err = pcall(function() return r.proxy.order_deconstruction(force) end)
    assert(ok and not r.proxy.valid, 'the game kept the item request: ' .. tostring(err))
    return {into=#r.into > 0 and text(r.into) or nil, out=#r.out > 0 and text(r.out) or nil}
  end
  return M
end
