-- What each agent carries, wears and builds, for the stream and the site
-- (operator 08:55, from Nick: "their combat equipment (guns/ammo), their power
-- armor loadouts (shields, lasers, radar, etc.), or their materials inventory
-- ... if they are building things (the game's little display of building
-- progress and queue)"). One operator read, `loadout {names?, top?}`, per
-- agent: guns and ammo slots with the gun selected, armor and the equipment
-- in its grid (shield and battery charge), the main inventory's largest
-- stacks and free slots, the hand-craft queue with the head's progress, the
-- build action running (done of total), health, vehicle, and whether it is
-- shooting. Cheap: the agent's own inventories only, no surface scans.
return function(api)
  local M = {operator={}}
  local TOP, QUEUE = 8, 6
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function quality(q)
    local n = type(q) == 'string' and q or (q and try(function() return q.name end))
    return n ~= 'normal' and n or nil
  end
  -- Slots in order: {name, count, quality?} or false for an empty one.
  local function slots(inv)
    local out = {}
    for i = 1, inv and (try(function() return #inv end) or 0) or 0 do
      local st = inv[i]
      if st and st.valid_for_read then out[i] = {name=st.name, count=st.count, quality=quality(st.quality)}
      else out[i] = false end
    end
    return out
  end
  local function inventory(p, id)
    return id and try(function() return p.get_inventory(id) end) or nil
  end
  local function equipment(armor_inv)
    local st = armor_inv and armor_inv[1]
    if not (st and st.valid_for_read) then return nil end
    local out = {name=st.name, quality=quality(st.quality)}
    local grid = try(function() return st.grid end)
    if grid then
      local by, order = {}, {}
      for _, e in ipairs(try(function() return grid.equipment end) or {}) do
        local name = try(function() return e.name end)
        if name then
          if not by[name] then by[name] = {name=name, type=try(function() return e.type end), count=0}; order[#order+1] = by[name] end
          by[name].count = by[name].count + 1
        end
      end
      table.sort(order, function(a, b) return a.count > b.count or (a.count == b.count and a.name < b.name) end)
      out.equipment = order
      local shield, max_shield = try(function() return grid.shield end), try(function() return grid.max_shield end)
      if max_shield and max_shield > 0 then out.shield = {now=math.floor(shield + 0.5), max=math.floor(max_shield + 0.5)} end
      local stored, cap = try(function() return grid.available_in_batteries end), try(function() return grid.battery_capacity end)
      if cap and cap > 0 then out.battery_mj = {now=math.floor(stored / 1e5 + 0.5) / 10, max=math.floor(cap / 1e5 + 0.5) / 10} end
      out.grid = {width=try(function() return grid.width end), height=try(function() return grid.height end)}
    end
    return out
  end
  local function top_items(inv, n)
    local list = {}
    for _, s in ipairs(inv and (try(function() return inv.get_contents() end) or {}) or {}) do
      list[#list+1] = {name=s.name, count=s.count, quality=quality(s.quality)}
    end
    table.sort(list, function(a, b) return a.count > b.count or (a.count == b.count and a.name < b.name) end)
    local out = {}
    for i = 1, math.min(n, #list) do out[i] = list[i] end
    return out, #list
  end
  local function crafting(p)
    local queue = try(function() return p.crafting_queue end)
    if not queue or #queue == 0 then return nil end
    local rows, items = {}, 0
    for _, e in ipairs(queue) do
      if not e.prerequisite then
        items = items + (e.count or 0)
        if #rows < QUEUE then rows[#rows+1] = {recipe=e.recipe, count=e.count} end
      end
    end
    return {queue=rows, items=items, progress=math.floor((try(function() return p.crafting_queue_progress end) or 0) * 100 + 0.5) / 100}
  end
  -- The build action running, as done of total.
  local BUILD = {build=true, build_path=true, construct=true, place_ghosts=true, paste=true, blueprint_place=true,
    belt_route=true, pipe_route=true, pole_route=true, rail_route=true, deconstruct=true}
  local function building(index)
    local a = api.active and api.active(index)
    if not (a and BUILD[a.kind]) then return nil end
    local out = {kind=a.kind}
    if a.total then out.done, out.total = (a.next_index or 1) - 1, a.total
    elseif a.remaining and a.built then out.done, out.total = a.built, a.built + a.remaining end
    if a.missing then out.missing = a.missing end
    return out
  end
  local function one(a, top)
    local p = api.lookup(a.index)
    local row = {name=a.name, display_name=a.display_name}
    if not (p and try(function() return p.valid end)) then row.alive = false; return row end
    local c = try(function() return p.character end)
    row.alive = c ~= nil and try(function() return c.valid end) or false
    if not row.alive then return row end
    row.surface = try(function() return c.surface.name end)
    row.health = {now=math.floor((try(function() return c.health end) or 0) + 0.5), max=math.floor((try(function() return c.max_health end) or 0) + 0.5)}
    local v = try(function() return c.vehicle end)
    row.vehicle = v and try(function() return v.name end) or nil
    local d = defines.inventory
    row.guns = slots(inventory(p, d.character_guns))
    row.ammo = slots(inventory(p, d.character_ammo))
    row.selected_gun = try(function() return c.selected_gun_index end)
    row.armor = equipment(inventory(p, d.character_armor))
    local main = try(function() return p.get_main_inventory() end)
    local n
    row.items, n = top_items(main, top)
    row.item_kinds = n
    local free = main and try(function() return main.count_empty_stacks() end)
    local size = main and try(function() return #main end)
    if free and size then row.slots = {free=free, total=size} end
    row.crafting = crafting(p)
    row.building = building(a.index)
    local act = api.active and api.active(a.index)
    row.shooting = act and (act.kind == 'shoot' or act.kind == 'kite') or nil
    return row
  end
  function M.operator.loadout(a)
    a = a or {}
    local top = a.top or TOP
    assert(type(top) == 'number' and top >= 1 and top <= 32, 'top must be 1..32')
    local want
    if a.names ~= nil then
      assert(type(a.names) == 'table', 'names must be a list of agent names')
      want = {}
      for _, n in ipairs(a.names) do want[n] = true end
    end
    local out = {}
    for _, ag in ipairs(api.agents()) do
      if not want or want[ag.name] then
        local ok, row = pcall(one, ag, top)
        out[#out+1] = ok and row or {name=ag.name, error=tostring(row)}
      end
    end
    return {agents=out, tick=game.tick}
  end
  return M
end
