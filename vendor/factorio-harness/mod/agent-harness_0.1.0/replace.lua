-- A build over an entity of the same fast-replace group on the same centre
-- (a chest over a chest, an assembler over an assembler) replaces it as the
-- game's fast replace does (Sonnet and Astra 06:20: six chests drained into
-- inventories, 2500 copper stranded; a refused upgrade with a full inventory
-- had taken 1600 cable). Where every stack goes is worked out before anything
-- moves: a chest's contents into the new chest as far as it holds them, the
-- rest and the old entity's item to the character. When the character cannot
-- take that, nothing moves and nothing is built.
return function(api)
  local M = {}
  local CHESTS = {container=true, ['logistic-container']=true}
  local function qname(s)
    local q = s.quality
    if type(q) ~= 'string' then q = q and q.name end
    return q or 'normal'
  end
  local function key(name, quality) return name .. '@' .. (quality or 'normal') end
  local function split(k) return k:match('^(.*)@([^@]*)$') end
  local function label(k)
    local name, quality = split(k)
    return name .. (quality ~= 'normal' and '@' .. quality or '')
  end
  local function size_of(name)
    local it = prototypes.item[name]
    return it and it.stack_size or 1
  end
  -- Room in an inventory as an insert fills it: partly filled stacks of the
  -- item first, then empty slots (a filtered empty slot only for its item).
  local function room_of(inv, empty)
    local r = {empty=empty or 0, partial={}, filtered={}}
    if not inv then return r end
    local ok, filters = pcall(function() return inv.supports_filters() end)
    for i = 1, #inv do
      local s = inv[i]
      if s.valid_for_read then
        local k = key(s.name, qname(s))
        r.partial[k] = (r.partial[k] or 0) + math.max(0, size_of(s.name) - s.count)
      else
        local f = ok and filters and inv.get_filter(i)
        local fname = f and (type(f) == 'string' and f or f.name)
        if fname then r.filtered[fname] = (r.filtered[fname] or 0) + 1 else r.empty = r.empty + 1 end
      end
    end
    return r
  end
  -- Puts count of an item into the room; returns how many fit.
  local function fit(r, name, quality, count)
    local k, left = key(name, quality), count
    local part = math.min(r.partial[k] or 0, left)
    r.partial[k] = (r.partial[k] or 0) - part
    left = left - part
    local size = size_of(name)
    while left > 0 and ((r.filtered[name] or 0) > 0 or r.empty > 0) do
      if (r.filtered[name] or 0) > 0 then r.filtered[name] = r.filtered[name] - 1 else r.empty = r.empty - 1 end
      local put = math.min(size, left)
      left = left - put
      r.partial[k] = (r.partial[k] or 0) + size - put
    end
    return count - left
  end
  -- Every stack in the entity's inventories, in slot order, and their slots.
  local function contents(o)
    local list, slots = {}, 0
    local ok, n = pcall(function() return o.get_max_inventory_index() end)
    for i = 1, ok and n or 0 do
      local fine, inv = pcall(function() return o.get_inventory(i) end)
      if fine and inv then
        slots = slots + #inv
        for j = 1, #inv do
          local s = inv[j]
          if s.valid_for_read then list[#list+1] = {name=s.name, quality=qname(s), count=s.count} end
        end
      end
    end
    return list, slots
  end
  -- What mining the entity gives besides its contents (its item).
  local function products(o)
    local out = {}
    local ok, list = pcall(function() return o.prototype.mineable_properties.products end)
    for _, pr in ipairs(ok and list or {}) do
      if pr.type == nil or pr.type == 'item' then
        local n = pr.amount or pr.amount_max or 1
        if n > 0 then out[#out+1] = {name=pr.name, quality=qname(o), count=n} end
      end
    end
    return out
  end
  local function list_text(map)
    local keys = {}
    for k in pairs(map) do keys[#keys+1] = k end
    table.sort(keys, function(x, y) if map[x] ~= map[y] then return map[x] > map[y] end return x < y end)
    local parts = {}
    for _, k in ipairs(keys) do parts[#parts+1] = map[k] .. ' ' .. label(k) end
    return table.concat(parts, ', ')
  end
  local function add(t, k, n) if n > 0 then t[k] = (t[k] or 0) + n end end

  -- The plan for replacing o with a `proto` entity of `quality`: kept (into
  -- the new chest) and to_you (the character), per item; item (the old
  -- entity's own item); short (what the character has no room for).
  -- freed: slots the build itself empties in the character's inventory.
  function M.plan(p, o, proto, quality, freed)
    local list, slots = contents(o)
    local cap = 0
    local keep = CHESTS[o.type] and CHESTS[proto.type] or false
    if keep then
      local ok, n = pcall(function() return proto.get_inventory_size(defines.inventory.chest, quality) end)
      cap = ok and n or 0
    end
    local box = {empty=cap, partial={}, filtered={}}
    local you = room_of(p.get_main_inventory(), freed)
    local free = you.empty
    local plan = {kept={}, to_you={}, item={}, short={}, slots=slots, keep=keep, any=#list > 0}
    local need = {}
    for _, pr in ipairs(products(o)) do
      local k = key(pr.name, pr.quality)
      add(plan.item, k, pr.count)
      need[#need+1] = {k=k, name=pr.name, quality=pr.quality, count=pr.count}
    end
    for _, s in ipairs(list) do
      local k = key(s.name, s.quality)
      local n = keep and fit(box, s.name, s.quality, s.count) or 0
      add(plan.kept, k, n)
      if n < s.count then
        add(plan.to_you, k, s.count - n)
        need[#need+1] = {k=k, name=s.name, quality=s.quality, count=s.count - n}
      end
    end
    -- What the character takes; with no room, the slots it would need.
    local wide = {empty=1e9, partial={}, filtered={}}
    for k, v in pairs(you.partial) do wide.partial[k] = v end
    for k, v in pairs(you.filtered) do wide.filtered[k] = v end
    for _, s in ipairs(need) do
      local n = fit(you, s.name, s.quality, s.count)
      add(plan.short, s.k, s.count - n)
      fit(wide, s.name, s.quality, s.count)
    end
    if next(plan.short) then
      local takes = {}
      for _, s in ipairs(need) do add(takes, s.k, s.count) end
      plan.error = string.format('cannot replace %s (%g,%g): your inventory has no room for %s (%d free slots, %d needed); nothing moved',
        o.name, o.position.x, o.position.y, list_text(takes), free, 1e9 - wide.empty)
    end
    return plan
  end

  -- Moves up to limit of the stacks matching k from source into target,
  -- topping up stacks of the item first (transfer_stack keeps item data).
  local function move(source, target, k, limit)
    local moved = 0
    for i = 1, #source do
      if moved >= limit then break end
      local s = source[i]
      if s.valid_for_read and (k == nil or key(s.name, qname(s)) == k) then
        local name, quality = s.name, qname(s)
        for pass = 1, 2 do
          for j = 1, #target do
            if moved >= limit or not s.valid_for_read then break end
            local slot = target[j]
            if (pass == 1) == (slot.valid_for_read and slot.name == name and qname(slot) == quality) then
              local before = s.count
              slot.transfer_stack(s, math.min(before, limit - moved))
              moved = moved + before - (s.valid_for_read and s.count or 0)
            end
          end
        end
      end
    end
    return moved
  end

  -- Mines o into a holding inventory; nil (everything put back) when the
  -- game refuses.
  function M.take(o, plan)
    local hold = game.create_inventory(plan.slots + 8)
    local ok, mined = pcall(function() return o.mine{inventory=hold, raise_destroyed=true} end)
    if ok and mined and not o.valid then return hold end
    for i = 1, #hold do
      local s = hold[i]
      if s.valid_for_read and o.valid then
        local n = o.insert(s)
        if n >= s.count then s.clear() else s.count = s.count - n end
      end
    end
    hold.destroy()
    return nil
  end

  -- After the new entity e stands: its chest gets what the plan keeps, the
  -- character the old item and the rest; anything left (the plan's room was
  -- taken meanwhile) spills at the character's feet. Returns the reply line
  -- and the counts.
  function M.give(p, e, hold, plan)
    local inv = plan.keep and e and e.valid and e.get_inventory(defines.inventory.chest)
    local main = p.get_main_inventory()
    local kept, moved, spilled = {}, {}, {}
    -- Up to limit of item k to the character: its main inventory, then
    -- wherever the game's insert puts it.
    local function to_you(k, limit)
      local done = main and move(hold, main, k, limit) or 0
      for i = 1, #hold do
        local s = hold[i]
        if done >= limit then break end
        if s.valid_for_read and key(s.name, qname(s)) == k then
          local take = math.min(s.count, limit - done)
          local n = take == s.count and p.insert(s) or p.insert{name=s.name, count=take, quality=qname(s)}
          done = done + n
          if n >= s.count then s.clear() else s.count = s.count - n end
        end
      end
      return done
    end
    for k, n in pairs(plan.item) do to_you(k, n) end
    if inv then
      for k, n in pairs(plan.kept) do add(kept, k, move(hold, inv, k, n)) end
    end
    for i = 1, #hold do
      local s = hold[i]
      if s.valid_for_read then
        local k = key(s.name, qname(s))
        add(moved, k, to_you(k, s.count))
        if s.valid_for_read then
          add(spilled, k, s.count)
          p.surface.spill_item_stack{position=p.position, stack=s, enable_looted=true, allow_belts=false}
          s.clear()
        end
      end
    end
    hold.destroy()
    local parts = {}
    if next(kept) then parts[#parts+1] = 'kept ' .. list_text(kept) .. ' in the new ' .. e.name end
    if next(moved) then parts[#parts+1] = list_text(moved) .. ' moved to you' end
    if next(spilled) then parts[#parts+1] = list_text(spilled) .. ' spilled at your feet (no room left)' end
    local line = #parts > 0 and table.concat(parts, '; ') or (plan.any and 'none' or 'it was empty')
    return line, kept, moved, spilled
  end
  M.list_text = list_text
  return M
end
