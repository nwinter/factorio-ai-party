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

  -- Settings a fast replace keeps, as the game's does (Sol 10:50: inserter -> fast inserter lost filters, wires and
  -- circuit settings; ~12 feeders set again by hand): read from the old entity before it is mined (settings), set
  -- on the new one (apply). apply returns the lines kept and the ones the new entity refused.
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  function M.settings(o)
    local s = {}
    -- Item filters (inserters, loaders): what details.lua reads.
    s.filters = api.filters and try(function() return api.filters(o) end)
    s.stack = try(function() return o.inserter_stack_size_override end)
    if o.type == 'splitter' then
      s.splitter = {filter=try(function() return o.splitter_filter end), input=try(function() return o.splitter_input_priority end),
        output=try(function() return o.splitter_output_priority end)}
    end
    -- Every wire on every connector: the far end's entity and connector.
    s.wires = {}
    for id, c in pairs(try(function() return o.get_wire_connectors(false) end) or {}) do
      for _, w in ipairs(try(function() return c.connections end) or {}) do
        local t = w.target
        local owner = t and try(function() return t.owner end)
        if owner and owner ~= o then
          s.wires[#s.wires+1] = {id=id, owner=owner, target=try(function() return t.wire_connector_id end), origin=w.origin}
        end
      end
    end
    s.circuit = api.circuit_snapshot and try(function() return api.circuit_snapshot(o) end)
    -- A chest's red-X limit.
    local inv = try(function() return o.get_inventory(defines.inventory.chest) end)
    local bar = inv and try(function() return inv.get_bar() end)
    if bar and bar <= #inv then s.bar = bar end
    -- Logistic request sections (requester, buffer).
    local secs = try(function() return o.get_logistic_sections() end)
    if secs then
      s.sections = {}
      for _, sec in ipairs(try(function() return secs.sections end) or {}) do
        local manual = try(function() return sec.is_manual end)
        if manual ~= false then
          s.sections[#s.sections+1] = {group=try(function() return sec.group end), active=try(function() return sec.active end),
            filters=try(function() return sec.filters end)}
        end
      end
      s.from_buffers = try(function() return o.request_from_buffers end)
    end
    return s
  end
  function M.apply(e, s)
    local kept, refused = {}, {}
    local function did(ok, line) if ok then kept[#kept+1] = line else refused[#refused+1] = line end end
    local f = s.filters
    if f and #(f.filters or {}) > 0 or (f and f.use_filters) then
      local ok = pcall(function()
        local slots = e.filter_slot_count or 0
        for i = 1, slots do e.set_filter(i, f.filters[i]) end
        if f.filter_mode and e.type == 'inserter' then e.inserter_filter_mode = f.filter_mode end
        if f.use_filters ~= nil and e.type == 'inserter' then e.use_filters = f.use_filters end
        assert(#f.filters <= slots, 'fewer filter slots')
      end)
      did(ok, string.format('filters %s%s', f.filter_mode and f.filter_mode .. ': ' or '', #f.filters > 0 and table.concat(f.filters, ', ') or 'none set'))
    end
    if s.stack and s.stack > 0 then did(pcall(function() e.inserter_stack_size_override = s.stack end), 'stack size ' .. s.stack) end
    if s.splitter then
      local ok = pcall(function()
        if s.splitter.filter then e.splitter_filter = s.splitter.filter end
        if s.splitter.input then e.splitter_input_priority = s.splitter.input end
        if s.splitter.output then e.splitter_output_priority = s.splitter.output end
      end)
      if s.splitter.filter or (s.splitter.input and s.splitter.input ~= 'none') or (s.splitter.output and s.splitter.output ~= 'none') then
        did(ok, 'splitter filter and priorities')
      end
    end
    if #s.wires > 0 then
      local n, colours = 0, {}
      for _, w in ipairs(s.wires) do
        local ok = w.owner.valid and pcall(function()
          local mine = e.get_wire_connector(w.id, true)
          local theirs = w.owner.get_wire_connector(w.target, true)
          assert(mine.connect_to(theirs, false, w.origin) ~= false)
        end)
        if ok then n = n + 1 end
      end
      did(n == #s.wires, string.format('%d of %d wires', n, #s.wires))
    end
    if s.circuit and api.circuit_restore then
      local ok_names, bad = api.circuit_restore(e, s.circuit)
      if #ok_names > 0 then kept[#kept+1] = 'circuit settings (' .. table.concat(ok_names, ', ') .. ')' end
      for _, n in ipairs(bad or {}) do refused[#refused+1] = 'circuit setting ' .. n end
    end
    if s.bar then
      local ok = pcall(function()
        local inv = e.get_inventory(defines.inventory.chest)
        inv.set_bar(math.min(s.bar, #inv + 1))
      end)
      did(ok, 'limit ' .. (s.bar - 1) .. ' slots')
    end
    if s.sections and #s.sections > 0 then
      local ok = pcall(function()
        local secs = e.get_logistic_sections()
        for _, sec in ipairs(s.sections) do
          local new = secs.add_section(sec.group ~= '' and sec.group or nil)
          if sec.filters and (sec.group == nil or sec.group == '') then new.filters = sec.filters end
          if sec.active ~= nil then new.active = sec.active end
        end
        if s.from_buffers ~= nil then e.request_from_buffers = s.from_buffers end
      end)
      did(ok, #s.sections .. ' request section' .. (#s.sections == 1 and '' or 's'))
    end
    return kept, refused
  end
  return M
end
