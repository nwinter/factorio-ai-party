-- Rocket cargo weighed before it is staged (Sol rebuilt three kits into two
-- after working out the weights offline): each item's weight from the 2.0
-- prototypes, the total against a rocket's lift (utility constant
-- rocket_lift_weight, 1000 kg) and its cargo slots (the silo's rocket
-- inventory, 20), the fewest rockets that could carry it, and one split into
-- rockets that keeps each within both. Weights are the game's grams.
-- The factory is pure so the same module can be bundled into a hot reload.
return function(api)
  local M = {}
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  -- Grams as kilograms with one decimal.
  local function kg(g) return math.floor(g/100+0.5)/10 end
  M.kg = kg
  -- The rocket's lift (grams) and cargo slots: a silo entity's own rocket
  -- inventory when given, else the rocket silo prototype's.
  function M.limits(silo)
    local lift = try(function() return prototypes.utility_constants.rocket_lift_weight end) or 1000000
    local slots
    if silo then
      slots = try(function() return #silo.get_inventory(defines.inventory.rocket_silo_rocket) end)
    end
    if not slots or slots < 1 then
      slots = try(function() return prototypes.entity['rocket-silo'].get_inventory_size(defines.inventory.rocket_silo_rocket) end)
    end
    if not slots or slots < 1 then slots = 20 end
    return lift, slots
  end
  -- One kind per item and quality, in the list's order: stacks of different
  -- qualities take their own slots.
  local function kinds_of(list)
    local kinds, by = {}, {}
    for _, e in ipairs(list) do
      local k = e.name..'@'..(e.quality or 'normal')
      local kind = by[k]
      if not kind then
        local proto = prototypes.item[e.name]
        assert(proto, 'unknown item '..tostring(e.name))
        kind = {name=e.name, quality=e.quality ~= 'normal' and e.quality or nil, count=0,
          each=try(function() return proto.weight end) or 0, stack=proto.stack_size or 1}
        by[k] = kind; kinds[#kinds+1] = kind
      end
      kind.count = kind.count + e.count
    end
    return kinds
  end
  -- The split: kinds in the order given, each into the first container with
  -- room for some of it (weight and slots, a part stack's room counted), new
  -- containers as needed. {weight, slots, count[kind], kinds} each.
  local function split(order, lift, slots)
    local rockets = {}
    local function room(r, kind)
      local held = r.count[kind] or 0
      local by_weight = kind.each > 0 and math.floor((lift-r.weight+1e-3)/kind.each) or math.huge
      local part = held > 0 and (math.ceil(held/kind.stack)*kind.stack-held) or 0
      local by_slots = (slots-r.slots)*kind.stack+part
      return math.max(0, math.min(by_weight, by_slots))
    end
    local function put(r, kind, n)
      local held = r.count[kind] or 0
      if held == 0 then r.kinds[#r.kinds+1] = kind end
      r.slots = r.slots-math.ceil(held/kind.stack)+math.ceil((held+n)/kind.stack)
      r.count[kind] = held+n
      r.weight = r.weight+kind.each*n
    end
    for _, kind in ipairs(order) do
      local left = kind.count
      for _, r in ipairs(rockets) do
        if left == 0 then break end
        local n = math.min(left, room(r, kind))
        if n > 0 then put(r, kind, n); left = left-n end
      end
      while left > 0 do
        local r = {weight=0, slots=0, count={}, kinds={}}
        rockets[#rockets+1] = r
        local n = math.min(left, room(r, kind))
        put(r, kind, n); left = left-n
      end
    end
    return rockets
  end
  local function label(kind) return kind.name..(kind.quality and '@'..kind.quality or '') end
  -- Cargo pods from a platform hub to the planet below (space.lua drop): a
  -- pod has slots and no weight limit (the cargo-pod prototype: 10 slots in
  -- 2.0.77), so the list splits by slots alone, in the order given: the first
  -- pod takes the first items. {pods = {{items = {{name, quality, count}},
  -- slots, text}}, stacks, fewest}.
  function M.pods(list, slots)
    local kinds = kinds_of(list)
    local stacks = 0
    for _, kind in ipairs(kinds) do kind.each = 0; stacks = stacks+math.ceil(kind.count/kind.stack) end
    local out = {pods={}, stacks=stacks, fewest=math.ceil(stacks/slots)}
    for i, r in ipairs(split(kinds, math.huge, slots)) do
      local items, parts = {}, {}
      for _, kind in ipairs(r.kinds) do
        items[#items+1] = {name=kind.name, quality=kind.quality or 'normal', count=r.count[kind]}
        parts[#parts+1] = label(kind)..'*'..r.count[kind]
      end
      out.pods[i] = {items=items, slots=r.slots, text=table.concat(parts, ' ')}
    end
    return out
  end
  -- list: {{name, count, quality?}}. Returns the reply fields.
  function M.weigh(list, lift, slots)
    local kinds = kinds_of(list)
    local total, stacks = 0, 0
    local rows = {}
    for _, kind in ipairs(kinds) do
      -- As many as one rocket lifts alone: by weight, and by its slots.
      local by_weight = kind.each > 0 and math.floor((lift+1e-3)/kind.each) or math.huge
      kind.per_rocket = math.min(by_weight, slots*kind.stack)
      kind.stacks = math.ceil(kind.count/kind.stack)
      total = total + kind.each*kind.count
      stacks = stacks + kind.stacks
      rows[#rows+1] = kind
    end
    table.sort(rows, function(a, b)
      local wa, wb = a.each*a.count, b.each*b.count
      if wa ~= wb then return wa > wb end
      return a.name < b.name
    end)
    local too_heavy = {}
    for _, kind in ipairs(rows) do
      if kind.per_rocket < 1 then too_heavy[#too_heavy+1] = string.format('%s weighs %g kg, over a rocket\'s %g kg', kind.name, kg(kind.each), kg(lift)) end
    end
    -- One split: heaviest items first, each into the first rocket with room
    -- for some of it, new rockets as needed.
    local rockets = {}
    if #too_heavy == 0 then
      local order = {}
      for i, kind in ipairs(rows) do order[i] = kind end
      table.sort(order, function(a, b) if a.each ~= b.each then return a.each > b.each end return a.name < b.name end)
      rockets = split(order, lift, slots)
    end
    local fewest = math.max(math.ceil(total/lift-1e-9), math.ceil(stacks/slots))
    local out = {lift=string.format('%g kg and %d cargo slots a rocket', kg(lift), slots), total_kg=kg(total), stacks=stacks,
      fewest=fewest, rockets=#too_heavy == 0 and #rockets or nil, too_heavy=#too_heavy > 0 and too_heavy or nil}
    out.items = {}
    for i, kind in ipairs(rows) do
      out.items[i] = {name=kind.name, quality=kind.quality, count=kind.count, each_kg=kg(kind.each), kg=kg(kind.each*kind.count),
        stacks=kind.stacks, per_rocket=kind.per_rocket ~= math.huge and kind.per_rocket or nil,
        share=string.format('%g%%', math.floor(kind.each*kind.count/lift*1000+0.5)/10)}
    end
    if #rockets > 0 then
      out.split = {}
      for i, r in ipairs(rockets) do
        local parts = {}
        for _, kind in ipairs(r.kinds) do parts[#parts+1] = label(kind)..'*'..r.count[kind] end
        out.split[i] = {rocket=i, kg=kg(r.weight), slots=r.slots, items=table.concat(parts, ' ')}
      end
      out.note = #rockets > fewest
        and string.format('this split takes %d rockets; the bound from total weight and stacks is %d', #rockets, fewest)
        or nil
    end
    return out
  end
  return M
end
