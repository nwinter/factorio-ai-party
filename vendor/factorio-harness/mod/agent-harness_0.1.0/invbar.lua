-- invbar: configure {bar}, an inventory's red-X limit as its GUI sets it (d21 batch64 Z2, Luna #1576: she wanted an
-- assembling machine's output capped at 50 electric furnaces and 500 foundation, and configure had no argument for it).
-- Read on 2.0.77 (private copy):
--   * a chest's, logistic chest's, cargo wagon's and cargo landing pad's inventory has a bar (LuaInventory.supports_bar
--     true); set_bar(n) leaves slots 1..n-1 usable, #inv+1 is none; items in slots past it stay there and nothing more
--     goes in (an iron chest with plates in 5 slots, bar at 2 usable slots: 10 copper plates inserted 0);
--   * a crafting machine's input and output and a furnace's result have none (supports_bar false; set_bar errors "Given
--     inventory does not have a bar."), and its GUI has no output limit: an assembler's output is one slot, and it
--     stops crafting when a craft's products no longer fit in one stack there (outputstop.lua; copper cable stopped
--     at 200 with 47 plates left), so with nothing taking from it a machine holds at most a stack;
--   * an assembling machine takes a logistic condition (circuit_set logistic): one in a logistic network read
--     disabled_by_control_behavior under "iron-gear-wheel < 50" while the network held 223, and worked under "< 300";
--     the network's count leaves out what sits in machines' output slots.
return function(api)
  local M = {}
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local INVS = {'chest', 'cargo_wagon', 'cargo_landing_pad_main', 'hub_main', 'car_trunk', 'spider_trunk'}
  local CRAFTERS = {['assembling-machine']=true, furnace=true, ['rocket-silo']=true}
  local MAX_INSERTERS = 8
  local function where(e) return string.format('%s (%g,%g)', e.name, e.position.x, e.position.y) end
  -- The entity's inventory with a bar, or nil.
  function M.inventory(e)
    for _, n in ipairs(INVS) do
      local d = defines.inventory[n]
      local inv = d and try(function() return e.get_inventory(d) end)
      if inv and try(function() return inv.supports_bar() end) then return inv end
    end
  end
  -- Usable slots under the bar, or nil for none.
  function M.usable(inv)
    local b = try(function() return inv.get_bar() end)
    if b and b <= #inv then return b - 1 end
  end
  local function used_slots(inv, from)
    local n = 0
    for i = from or 1, #inv do if inv[i].valid_for_read then n = n + 1 end end
    return n
  end
  -- The inserters taking from a machine, each with what it drops into and that one's bar.
  local function takers(e)
    local b = e.bounding_box
    local found = try(function() return e.surface.find_entities_filtered{area={{b.left_top.x - 3, b.left_top.y - 3}, {b.right_bottom.x + 3, b.right_bottom.y + 3}},
      type='inserter', force=e.force, limit=4 * MAX_INSERTERS} end) or {}
    local rows = {}
    for _, i in ipairs(found) do
      if #rows >= MAX_INSERTERS then break end
      if try(function() return i.pickup_target end) == e then
        local d = try(function() return i.drop_target end)
        local into = 'nothing (the ground or a belt)'
        if d then
          local inv = M.inventory(d)
          local u = inv and M.usable(inv)
          into = where(d) .. (inv and string.format(' (%s of %d slots usable)', u and tostring(u) or 'all', #inv) or ' (no bar)')
        end
        rows[#rows+1] = string.format('%s (%g,%g) into %s', i.name, i.position.x, i.position.y, into)
      end
    end
    return rows
  end
  -- The game's reason an entity takes no bar, and on a crafting machine what the game has instead.
  function M.refusal(e)
    if e.type == 'entity-ghost' then
      return string.format('bar: ghost of %s (%g,%g) holds no items: the bar is set on the built chest, cargo wagon or landing pad', e.ghost_name, e.position.x, e.position.y)
    end
    if not CRAFTERS[e.type] then
      return string.format('bar: %s has no inventory with a bar in 2.0.77 (the red X is a chest\'s, logistic chest\'s, cargo wagon\'s or cargo landing pad\'s)', where(e))
    end
    local recipe = try(function() return e.get_recipe() end)
    if not recipe then
      local prev = try(function() return e.previous_recipe end)
      local n = prev and (type(prev.name) == 'table' and prev.name.name or prev.name)
      recipe = n and try(function() return e.force.recipes[n] end)
    end
    local stacks, item = {}, nil
    for _, p in ipairs(recipe and try(function() return recipe.products end) or {}) do
      local proto = p.type == 'item' and prototypes.item[p.name]
      if proto then
        item = item or p.name
        stacks[#stacks+1] = string.format('%s: at most %d, a stack', p.name, proto.stack_size)
      end
    end
    local out_inv = try(function() return e.get_output_inventory() end)
    local slots = out_inv and #out_inv or 1
    local net = try(function() return e.surface.find_logistic_network_by_position(e.position, e.force) end)
    local net_text = net and string.format('logistic network %d, where it stands,', net.network_id) or 'the logistic network where it stands (none covers it now)'
    local rows = takers(e)
    return string.format('bar: %s has none: in 2.0.77 a crafting machine\'s input and output have no bar (the game: "Given inventory does not have a bar.") and its GUI has no output limit; '
      .. 'its output is %d slot%s, and it stops crafting when a craft\'s products no longer fit in one stack there, so with nothing taking from it it holds at most a stack%s. What the game has: the bar of the chest its output inserters drop into '
      .. '(configure {position: the chest, bar: N}: N usable slots of a stack each); its own logistic condition (circuit_set {position: {x=%g,y=%g}, logistic: "%s < N"}: '
      .. 'it stops while %s holds N or more, what sits in machines\' output slots not counted); an output inserter\'s enable or logistic condition (circuit_set on the inserter). '
      .. 'Its output inserters: %s',
      where(e), slots, slots == 1 and '' or 's', #stacks > 0 and ' (' .. table.concat(stacks, ', ') .. ')' or '', e.position.x, e.position.y, item or 'ITEM', net_text,
      #rows > 0 and table.concat(rows, '; ') or 'none')
  end
  -- configure {bar}: usable slots 0..#inv, or false (or "none") for none; read back after.
  function M.set(e, v)
    local inv = e.type ~= 'entity-ghost' and M.inventory(e)
    if not inv then error(M.refusal(e), 0) end
    local total = #inv
    local want
    if v == false or v == 'none' then want = total + 1
    else want = api.integer(v, nil, 0, total, string.format('bar (usable slots 0..%d, or false for none)', total)) + 1 end
    local before = M.usable(inv)
    inv.set_bar(want)
    local after = M.usable(inv)
    local used = used_slots(inv)
    local past = after and used_slots(inv, after + 1) or 0
    local text = function(u) return u and string.format('%d usable', u) or 'none' end
    return {name=e.name, position=e.position, bar=after or 'none', bar_before=before or 'none', slots=total, slots_used=used, slots_past_bar=past > 0 and past or nil,
      line=string.format('%s: bar %s of %d slots (was %s); %d slot%s hold items%s', where(e), text(after), total, text(before), used, used == 1 and '' or 's',
        past > 0 and string.format(', %d past the bar: they keep their items, and new items go only into the slots under it', past) or '')}
  end
  return M
end
