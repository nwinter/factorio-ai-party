-- slots: an inventory that takes no more of an item, and what fills its slots (Sol, 22:08: requester (48.5,34.5) on
-- Gleba had all 48 slots taken, 494 spoilage among them, so robots could not deliver bioflux; supply said "no idle
-- robots", and a take-and-give transfer delivered 0 and said ok). Read as a player reads the chest's GUI.
return function()
  local M = {}
  M.SPOILAGE = 'spoilage'
  local SHOW = 4
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  -- What fills an inventory, by item: {name, n, slots}, the most slots first.
  local function tally(inv, size)
    local by, order = {}, {}
    for i = 1, size do
      local s = try(function() local st = inv[i]; return st.valid_for_read and {name=st.name, count=st.count} end)
      if s then
        local r = by[s.name]
        if not r then r = {name=s.name, n=0, slots=0}; by[s.name] = r; order[#order+1] = r end
        r.n, r.slots = r.n + s.count, r.slots + 1
      end
    end
    table.sort(order, function(x, y) if x.slots ~= y.slots then return x.slots > y.slots end return x.name < y.name end)
    return order, by
  end
  local function slot_text(r) return string.format('%s %d in %d slot%s', r.name, r.n, r.slots, r.slots == 1 and '' or 's') end
  -- An inventory with every slot taken, and (item given) no room for one more of it: {slots, spoilage, spoilage_slots,
  -- text = "all 48 slots taken (spoilage 494 in 10 slots, nutrients 300 in 3 slots, +2 more items)"}; nil when it has
  -- room or cannot be read.
  function M.full(inv, item)
    if not inv then return nil end
    local size = try(function() return #inv end)
    if not size or size == 0 then return nil end
    local empty = try(function() return inv.count_empty_stacks() end)
    if empty == nil or empty > 0 then return nil end
    if item and try(function() return inv.can_insert({name=item, count=1}) end) ~= false then return nil end
    local order, by = tally(inv, size)
    local parts = {}
    for i = 1, math.min(SHOW, #order) do parts[i] = slot_text(order[i]) end
    if #order > SHOW then parts[#parts+1] = string.format('+%d more items', #order - SHOW) end
    local sp = by[M.SPOILAGE]
    local shown = false
    for i = 1, math.min(SHOW, #order) do if order[i] == sp then shown = true end end
    return {slots=size, spoilage=sp and sp.n or nil, spoilage_slots=sp and sp.slots or nil,
      text=string.format('all %d slots taken (%s)%s', size, table.concat(parts, ', '),
        sp and not shown and string.format('; %s among them', slot_text(sp)) or '')}
  end
  -- A refusal is not proof of fullness: empty recipe, fuel and module slots can reject an item.
  function M.refusal(inv, item, name, e, full)
    local order=tally(inv,#inv)
    local parts={}
    for i=1,math.min(SHOW,#order) do parts[#parts+1]=slot_text(order[i]) end
    if #order>SHOW then parts[#parts+1]='+'..(#order-SHOW)..' more items' end
    local detail=full or (#parts>0 and 'holds '..table.concat(parts,', ') or 'empty')
    local text=string.format('%s refused %s; %s',name or 'inventory',item,detail)
    if not full then text=text..'; free slots do not imply this inventory accepts that item' end
    local recipe=try(function() return e.get_recipe() end)
    if recipe then
      local ingredients={}
      for _,ing in ipairs(recipe.ingredients) do if ing.type~='fluid' then ingredients[#ingredients+1]=ing.name end end
      text=text..'; recipe '..recipe.name..' takes '..(#ingredients>0 and table.concat(ingredients,', ') or 'no item ingredients')
    end
    return text
  end
  -- The inventory an entity takes items into: a chest's, a character's main, a vehicle's trunk, a wagon's, a crafting
  -- machine's input, a lab's.
  local INV = {container='chest', ['logistic-container']='chest', ['temporary-container']='chest', character='character_main',
    car='car_trunk', ['spider-vehicle']='spider_trunk', ['cargo-wagon']='cargo_wagon', lab='lab_input',
    ['assembling-machine']='assembling_machine_input', furnace='furnace_source', ['rocket-silo']='assembling_machine_input',
    ['cargo-landing-pad']='cargo_landing_pad_main', ['space-platform-hub']='hub_main'}
  function M.inventory_of(e)
    local name = e and try(function() return INV[e.type] end)
    local id = name and defines.inventory[name]
    return id and try(function() return e.get_inventory(id) end) or nil
  end
  -- The entity's own full() for an item.
  function M.full_of(e, item) return M.full(M.inventory_of(e), item) end
  -- A crafting machine's input holding spoilage its recipe does not take: {n, slots, text}; nil otherwise.
  function M.input_spoilage(e)
    local t = try(function() return e.type end)
    if t ~= 'assembling-machine' and t ~= 'furnace' then return nil end
    local inv = M.inventory_of(e)
    local n = inv and try(function() return inv.get_item_count(M.SPOILAGE) end) or 0
    if n <= 0 then return nil end
    local recipe = try(function() return e.get_recipe() end)
    for _, ing in ipairs(recipe and try(function() return recipe.ingredients end) or {}) do
      if ing.name == M.SPOILAGE then return nil end
    end
    local size = try(function() return #inv end) or 0
    local order = tally(inv, size)
    local slots = 0
    for _, r in ipairs(order) do if r.name == M.SPOILAGE then slots = r.slots end end
    return {n=n, slots=slots, size=size,
      text=string.format('input holds spoilage %d in %d of its %d slots (its recipe does not take spoilage)', n, slots, size)}
  end
  return M
end
