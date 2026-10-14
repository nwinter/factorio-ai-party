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
      if r.item == c.name and r.count == c.count then r.ghosts = r.ghosts + 1; return end
    end
    rows[#rows+1] = {item=c.name, count=c.count, ghosts=1, network_holds=c.network_holds}
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
  return M
end
