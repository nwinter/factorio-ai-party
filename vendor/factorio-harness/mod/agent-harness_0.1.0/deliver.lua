-- deliver {position | positions, items, surface?} (backlog #653, Sol: an engineer on another planet could only place
-- ghosts there; moving network stock into machines took a body). As a blueprint's item requests do in 2.0: an item
-- request on each entity (its insert plan) for fuel into its fuel slots, or ammunition into a turret, filled by the
-- construction robots of the logistic network that covers it, from that network's stock; by remote view, in a chunk our
-- force sees now. Modules go with configure {modules}; a machine's ingredients are not requested this way (inserters
-- and requester chests bring them). Nothing moves until a robot comes: each row names the network, what it holds of the
-- items and its free construction robots.
-- (d29 batch342 HI, Opus #2748: a hull mid-refit could not prime its fusion core with cold fluoroketone, since deliver
-- refused barrels into the barrel-emptying machine) On a platform, an ingredient of a crafting machine's current recipe
-- too: an insert plan into its input slot for that ingredient, as a player gets by pasting a blueprint whose entity
-- carries that item request over the machine. On a private 2.0.77 copy of world n (Kestrel IVa's barrel-emptying
-- assembling machine 3): the blueprint keeps the plan (inventory 2, the crafter input), the paste makes the item
-- request, and the platform hub fills it from its own inventory within 10 ticks, as many as it holds, the rest staying
-- requested; a request for an item the recipe does not take is dropped by the game at once (nothing moves). Fluids are
-- not items: a barrel and an emptying recipe, or a pump from a tank, bring them.
return function(api)
  local M = {}
  -- (d25 batch208 QU1) the most a call takes, also a queue step's check (runtime.lua step_lengths)
  M.POSITIONS = 32
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function at(q) return string.format('(%g,%g)', q.x, q.y) end
  -- {name=count} from items: {name: count}, [{name, count}] or "name".
  local function items_of(v, count)
    local out = {}
    if type(v) == 'string' then out[v] = count or 1
    elseif type(v) == 'table' and #v == 0 then for k, n in pairs(v) do out[k] = n end
    elseif type(v) == 'table' then for _, r in ipairs(v) do out[r.name or r.item] = r.count or 1 end end
    for name, n in pairs(out) do
      assert(prototypes.item[name] or not (prototypes.fluid and prototypes.fluid[name]), string.format('%s is a fluid: an item request carries items only; '
        .. 'a fluid comes as its barrel (with the machine set to an emptying recipe, then deliver the barrels) or by a pump from a tank', tostring(name)))
      assert(prototypes.item[name], 'unknown item ' .. tostring(name))
      assert(type(n) == 'number' and n >= 1 and n <= 10000, 'each count is 1..10000')
    end
    assert(next(out), 'items: {item: count}, a list of {name, count}, or an item name with count')
    return out
  end
  -- (HI) On a platform: the crafting machine's input slot for an ingredient of its recipe, as (inv, index, 'ingredient',
  -- slot); nil and why for a machine there that takes it not; nil, nil off a platform or for no crafting machine.
  local function ingredient_slot(e, name)
    if e.type ~= 'assembling-machine' then return nil end
    local plat = try(function() return e.surface.platform end)
    local r = try(function() return e.get_recipe() end)
    if not plat then
      if r then return nil, string.format('%s is not fuel or ammunition: a machine\'s ingredients by item request only on a platform (its hub fills it); here inserters or a requester chest bring them', name) end
      return nil
    end
    if not r then return nil, string.format('%s has no recipe: an ingredient request needs one (the game drops a request for an item its recipe does not take)', e.name) end
    local k = 0
    for _, ing in ipairs(r.ingredients or {}) do
      if ing.type == 'item' then
        if ing.name == name then
          local inv = try(function() return e.get_inventory(defines.inventory.crafter_input) end)
          if inv then return inv, defines.inventory.crafter_input, 'ingredient', k end
        end
        k = k + 1
      end
    end
    return nil, string.format('%s is not an ingredient of %s\'s recipe %s: the game drops such a request (nothing moves)', name, e.name, r.name)
  end
  -- The inventory an item goes into on e, and its define index: fuel, or a turret's ammo; nil and why.
  local function slot_for(e, name)
    local proto = prototypes.item[name]
    -- (HI) an ingredient of a platform machine's recipe first (an ingredient that also burns is still the recipe's)
    local iinv, iidx, ikind, islot = ingredient_slot(e, name)
    if iinv then return iinv, iidx, ikind, islot end
    if iidx and proto.type ~= 'ammo' and (try(function() return proto.fuel_value end) or 0) <= 0 and proto.type ~= 'module' then return nil, iidx end
    if proto.type == 'ammo' then
      local inv = try(function() return e.get_inventory(defines.inventory.turret_ammo) end)
      if inv and (e.type == 'ammo-turret') then return inv, defines.inventory.turret_ammo, 'ammo' end
      return nil, string.format('%s is ammunition and %s takes none (a turret does)', name, e.name)
    end
    if (try(function() return proto.fuel_value end) or 0) > 0 then
      local inv = try(function() return e.get_fuel_inventory() end)
      if inv then return inv, inv.index, 'fuel' end
      return nil, string.format('%s is fuel and %s burns none', name, e.name)
    end
    if proto.type == 'module' then return nil, 'modules go with configure {position, modules: [...]} (their own item request)' end
    return nil, string.format('%s is neither fuel nor ammunition: an item request brings fuel, ammunition and modules; a machine\'s ingredients come by inserters or a requester chest', name)
  end
  -- Insert plan rows for n of name into inv (index idx): its stacks of the same item first, then empty ones.
  local function rows_for(inv, idx, name, n, only)
    local rows, left = {}, n
    local size = prototypes.item[name].stack_size
    for i = 1, #inv do
      if only and i - 1 ~= only then goto next end
      if left <= 0 then break end
      local st = inv[i]
      local room = (not st.valid_for_read) and size or (st.name == name and size - st.count or 0)
      if room > 0 then
        local k = math.min(room, left)
        rows[#rows+1] = {inventory=idx, stack=i - 1, count=k}
        left = left - k
      end
      ::next::
    end
    return rows, n - left
  end
  function M.deliver_one(p, e, items)
    local plans, asked, refused, hub_fills = {}, {}, {}, false
    for name, n in pairs(items) do
      local inv, idx, kind, only = slot_for(e, name)
      if not inv then refused[#refused+1] = idx
      else
        if kind == 'ingredient' then hub_fills = true end
        local rows, fits = rows_for(inv, idx, name, n, only)
        if fits <= 0 then refused[#refused+1] = string.format('%s: no room in its %s slots', name, kind)
        else
          plans[#plans+1] = {id={name=name, quality='normal'}, items={in_inventory=rows}}
          asked[#asked+1] = {name=name, quality='normal', count=fits}
          if fits < n then refused[#refused+1] = string.format('%s: room for %d of the %d', name, fits, n) end
        end
      end
    end
    local row = {name=e.name, position=e.position}
    if #plans > 0 then
      local proxy = try(function() return e.item_request_proxy end)
      if proxy and proxy.valid then
        local old = try(function() return proxy.insert_plan end) or {}
        for _, pl in ipairs(plans) do old[#old+1] = pl end
        proxy.insert_plan = old
      else
        proxy = e.surface.create_entity{name='item-request-proxy', position=e.position, force=e.force, target=e, modules=plans}
        assert(proxy, 'the game made no item request for ' .. e.name)
      end
      local parts = {}
      for _, w in ipairs(asked) do parts[#parts+1] = w.name .. '*' .. w.count end
      row.requested = table.concat(parts, ' ')
      local pl = try(function() return e.surface.platform end)
      if hub_fills and pl then
        -- (HI) on a platform the hub fills it from its own inventory
        local hub = try(function() return pl.hub.get_inventory(defines.inventory.hub_main) end)
        local held = {}
        for _, w in ipairs(asked) do held[#held+1] = string.format('%s %d', w.name, hub and try(function() return hub.get_item_count(w.name) end) or 0) end
        row.note = string.format('the hub of %s holds %s', pl.name, table.concat(held, ', '))
        row.pending = 'an item request the platform hub fills from its inventory (on a copy: within 10 ticks, as many as it holds; the rest stays requested until it has them)'
      else
        row.note = api.carrier and try(function() return api.carrier(e, asked) end) or nil
        row.pending = 'nothing is in it yet: an item request for robots (pending until one arrives)'
      end
    end
    row.refused = #refused > 0 and refused or nil
    return row
  end
  function M.handler(p, a)
    local items = items_of(a.items or a.item, a.count)
    local list = a.positions or (a.position and {a.position})
    assert(type(list) == 'table' and #list >= 1 and #list <= M.POSITIONS, 'position, or positions: 1..' .. M.POSITIONS .. ' {x,y}')
    assert(a.platform == nil or a.surface == nil, 'platform or surface, not both')
    local q = a.platform ~= nil and api.on_platform(p, a.platform) or a.surface ~= nil and api.on_surface(p, a.surface) or p
    local rows, n = {}, 0
    for _, pos in ipairs(list) do
      local ok, e = pcall(api.remote_entity, q, {position=pos, name=type(pos) == 'table' and pos.name or nil})
      if not ok then rows[#rows+1] = {position=pos, error=tostring(e):gsub('^[^:]*:%d+: ', '')}
      else
        assert(e.force == p.force, e.name .. ' at ' .. at(e.position) .. ' is not ours')
        local ok2, row = pcall(M.deliver_one, p, e, items)
        if ok2 then rows[#rows+1] = row; if row.requested then n = n + 1 end
        else rows[#rows+1] = {name=e.name, position=e.position, error=tostring(row):gsub('^[^:]*:%d+: ', '')} end
      end
    end
    return {requested=n, rows=rows}
  end
  M.schema = {deliver = {position='{x,y} of a burner (furnace, boiler, drill, inserter, reactor, ...) or a turret', positions='or 1..32 of them',
    items='{item: count} (or a list of {name, count}, or item with count): fuel into its fuel slots, ammunition into a turret; (d29 batch342) on a platform, an ingredient of a crafting machine\'s current recipe into its input slot (as a pasted blueprint\'s item request: the hub fills it from its inventory; the game drops a request for an item the recipe does not take). Fluids are not items: a barrel and an emptying recipe, or a pump from a tank',
    item='or one item name', count='with item', surface='optional planet name: by remote view there (a chunk our force sees now)', platform='optional platform name: the entity on that platform (by remote view)',
    returns='requested (how many took a request), rows [{name, position, requested, note (the network that covers it: what it holds of the items and its free construction robots), pending, refused (an item it takes none of, or no room), error}]. As a blueprint\'s item requests: construction robots bring it from the network\'s stock; nothing moves until one comes. Modules: configure {modules}; ingredients: inserters or a requester chest'}}
  return M
end
