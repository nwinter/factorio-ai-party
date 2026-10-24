-- fullchest: a chest with every slot used, what fills its slots, and the machines whose output waits on it (Astra,
-- Luna, shift19: Gleba's nutrient, yumako and bioflux providers each had 48/48 slots used while holding about 5,000
-- spoilage, so the biochambers and towers feeding them stopped for hours). Read as the chest's GUI and the inserters'
-- status icons show it. Used by supply, bottleneck, inspect and "open for you".
return function(api)
  local M = {}
  local slots = api.slots or require('slots')()
  local CHESTS = {'container', 'logistic-container'}
  local CHEST = {container=true, ['logistic-container']=true}
  local NEAR_RADIUS, NEAR_LIMIT, NEAR_SHOW, MACHINES_SHOW = 32, 200, 3, 3
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function at(pos) return string.format('(%g,%g)', pos.x, pos.y) end
  local function status_of(e)
    if api.status_name then return try(function() return api.status_name(e) end) end
    local s = try(function() return e.status end)
    for k, v in pairs(defines.entity_status or {}) do if v == s then return k end end
  end
  local function inv_of(e) return try(function() return e.get_inventory(defines.inventory.chest) end) end
  -- {used, total, free, usable} of a chest's slots; nil when it cannot be read. (d24 batch157, Astra #2205) free: the
  -- empty slots under its bar (count_empty_stacks(true, false): nothing goes past it); usable: the slots under the bar
  -- when one is set; used: every slot holding items.
  function M.slots_of(e)
    local inv = inv_of(e)
    local total = inv and try(function() return #inv end)
    local free = inv and try(function() return inv.count_empty_stacks(true, false) end)
    local empty = inv and try(function() return inv.count_empty_stacks() end)
    if not total or not free then return nil end
    local bar = try(function() return inv.get_bar() end)
    return {used=total - (empty or free), total=total, free=free, usable=bar and bar <= total and bar - 1 or nil}
  end
  -- ", 3/48 slots free" for a supply row (", 3 of 10 usable slots free (bar; 48 slots)" under a bar).
  function M.free_note(e)
    local s = CHEST[try(function() return e.type end) or ''] and M.slots_of(e)
    if s and s.usable then return string.format(', %d of %d usable slots free (bar; %d slots)', s.free, s.usable, s.total) end
    return s and string.format(', %d/%d slots free', s.free, s.total) or ''
  end
  -- The machines whose output waits on the chest: inserters dropping into it that wait for space, and mining drills
  -- whose drop target it is. {machines={{e, status, via}}, inserters=n}.
  function M.waiting(e)
    local box = try(function() return e.bounding_box end)
    local surface = try(function() return e.surface end)
    local out = {machines={}, inserters=0}
    if not box or not surface then return out end
    local unit = e.unit_number
    local seen = {}
    local function area(r) return {{box.left_top.x - r, box.left_top.y - r}, {box.right_bottom.x + r, box.right_bottom.y + r}} end
    for _, ins in ipairs(try(function() return surface.find_entities_filtered{area=area(3), type='inserter', force=e.force} end) or {}) do
      local drop = try(function() return ins.drop_target end)
      if drop and drop.unit_number == unit and status_of(ins) == 'waiting_for_space_in_destination' then
        out.inserters = out.inserters + 1
        local src = try(function() return ins.pickup_target end)
        if src and src.unit_number and not seen[src.unit_number] then
          seen[src.unit_number] = true
          out.machines[#out.machines+1] = {e=src, status=status_of(src) or 'unknown', via=ins}
        end
      end
    end
    for _, d in ipairs(try(function() return surface.find_entities_filtered{area=area(5), type='mining-drill', force=e.force} end) or {}) do
      local drop = try(function() return d.drop_target end)
      if drop and drop.unit_number == unit and not seen[d.unit_number] then
        local st = status_of(d)
        if st == 'waiting_for_space_in_destination' or st == 'full_output' then
          seen[d.unit_number] = true
          out.machines[#out.machines+1] = {e=d, status=st}
        end
      end
    end
    return out
  end
  local function waiting_text(w)
    local parts = {}
    for i = 1, math.min(MACHINES_SHOW, #w.machines) do
      local m = w.machines[i]
      parts[i] = string.format('%s %s %s', m.e.name, at(m.e.position), m.status)
    end
    if #w.machines > MACHINES_SHOW then parts[#parts+1] = string.format('+%d more', #w.machines - MACHINES_SHOW) end
    if #parts == 0 then
      return w.inserters > 0 and string.format('%d inserter%s wait%s for space in it', w.inserters, w.inserters == 1 and '' or 's', w.inserters == 1 and 's' or '') or 'no machine waits on it'
    end
    return string.format('output waits on it: %s (%d inserter%s waiting)', table.concat(parts, ', '), w.inserters, w.inserters == 1 and '' or 's')
  end
  -- A chest with every slot used: {used, total, fills, waiting, line}; nil when a slot is free or it is no chest.
  -- line: "passive-provider-chest (10.5,4.5): 48/48 slots used (spoilage 4800 in 48 slots); output waits on it:
  -- biochamber (7.5,4.5) full_output (1 inserter waiting)".
  function M.read(e)
    if not e or not try(function() return e.valid end) or not CHEST[try(function() return e.type end) or ''] then return nil end
    local full = slots.full(inv_of(e))
    if not full then return nil end
    local w = M.waiting(e)
    local fills = full.text:match('^all %d+ slots taken %((.*)%)') or full.text
    local r = {used=full.slots, total=full.slots, fills=fills, waiting=w, name=e.name, position=e.position}
    r.line = string.format('%s %s: %d/%d slots used (%s); %s', e.name, at(e.position), full.slots, full.slots, fills, waiting_text(w))
    return r
  end
  -- The full chest a machine's output inserters wait on (bottleneck and "open for you"): the first, or nil.
  function M.of_machine(m)
    local box = try(function() return m.bounding_box end)
    local surface = try(function() return m.surface end)
    if not box or not surface then return nil end
    local unit = m.unit_number
    for _, ins in ipairs(try(function() return surface.find_entities_filtered{area={{box.left_top.x - 3, box.left_top.y - 3}, {box.right_bottom.x + 3, box.right_bottom.y + 3}}, type='inserter', force=m.force} end) or {}) do
      local src = try(function() return ins.pickup_target end)
      if src and src.unit_number == unit and status_of(ins) == 'waiting_for_space_in_destination' then
        local drop = try(function() return ins.drop_target end)
        local r = drop and M.read(drop)
        if r then return r end
      end
    end
    local drop = try(function() return m.drop_target end)
    return drop and M.read(drop) or nil
  end
  -- The nearest chests of ours with a free slot within NEAR_RADIUS tiles (inspect on a full chest): up to 3 lines
  -- "steel-chest (14.5,4.5) 30/48 slots free, 4 tiles".
  function M.nearest_free(e)
    local surface = try(function() return e.surface end)
    if not surface then return nil end
    local found = try(function() return surface.find_entities_filtered{position=e.position, radius=NEAR_RADIUS, type=CHESTS, force=e.force, limit=NEAR_LIMIT} end) or {}
    local rows = {}
    for _, c in ipairs(found) do
      if c.unit_number ~= e.unit_number then
        local s = M.slots_of(c)
        if s and s.free > 0 then
          local d = math.sqrt((c.position.x - e.position.x) ^ 2 + (c.position.y - e.position.y) ^ 2)
          rows[#rows+1] = {c=c, s=s, d=d}
        end
      end
    end
    table.sort(rows, function(a, b) if a.d ~= b.d then return a.d < b.d end return a.c.unit_number < b.c.unit_number end)
    local out = {}
    for i = 1, math.min(NEAR_SHOW, #rows) do
      local r = rows[i]
      out[i] = string.format('%s %s %d/%d slots free, %d tiles', r.c.name, at(r.c.position), r.s.free, r.s.total, math.floor(r.d + 0.5))
    end
    if #out == 0 then return {string.format('no chest of ours within %d tiles has a free slot', NEAR_RADIUS)} end
    return out
  end
  return M
end
