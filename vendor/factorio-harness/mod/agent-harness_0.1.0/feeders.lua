-- The inserters feeding a machine, as their GUIs show them (d20 batch63: Y1 fuel_budget's reactors, Y2 bottleneck,
-- Astra #1512 and #1523): each inserter dropping into it, its circuit or logistic condition with the values on its
-- wires and whether it holds the inserter off, the combinators setting that signal (while a budget lasts), its hand,
-- and the source it picks from with that source's stock of the items asked about. Astra #1523: bottleneck named ice
-- the root for two cryogenic plants whose input inserter was off by "cryogenic-science-pack < 2000" while its
-- requester held 101 ice and 100 lithium plate: the plants were capped on purpose.
return function(api)
  local M = {}
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function at(pos) return string.format('(%g,%g)', pos.x, pos.y) end
  local MAX_FEEDERS = 4
  -- The inserters dropping into e (at most 32 looked at).
  function M.of(e)
    local b = e.bounding_box
    local area = {left_top={x=b.left_top.x-3, y=b.left_top.y-3}, right_bottom={x=b.right_bottom.x+3, y=b.right_bottom.y+3}}
    local out = {}
    for _, ins in pairs(try(function() return e.surface.find_entities_filtered{area=area, type='inserter', force=e.force, limit=32} end) or {}) do
      if ins.valid and try(function() return ins.drop_target end) == e then out[#out+1] = ins end
    end
    return out
  end
  -- How many of item a source holds: a chest's or machine's output, a belt's lines.
  local function source_count(src, item)
    if src.type == 'transport-belt' or src.type == 'underground-belt' or src.type == 'splitter' then
      local n = 0
      for k = 1, try(function() return src.get_max_transport_line_index() end) or 0 do
        n = n + (try(function() return src.get_transport_line(k).get_item_count(item) end) or 0)
      end
      return n
    end
    local inv = try(function() return src.get_output_inventory() end) or try(function() return src.get_inventory(defines.inventory.chest) end)
    return inv and try(function() return inv.get_item_count(item) end) or 0
  end
  -- One inserter: {position, name, hand {item, count}, hand_wait, source {name, position, counts}, takes_from, condition,
  -- holds_back, set_by}. items: the item names whose stock at the source is read. budget.traces: combinator traces left.
  function M.read(ins, items, budget)
    local f = {position=ins.position, name=ins.name}
    local h = try(function() return ins.held_stack end)
    if h and h.valid_for_read then f.hand = {item=h.name, count=h.count} end
    -- holding part of a hand and waiting for more (a stack-inserter waits for a full hand; d22 batch104 BN2)
    f.hand_wait = api.hand_wait and try(function() return api.hand_wait(ins) end) or nil
    local pick = try(function() return ins.pickup_target end)
    if pick and pick.valid then
      local counts, parts = {}, {}
      for _, it in ipairs(items or {}) do
        local n = source_count(pick, it)
        if n > 0 then counts[it] = n; parts[#parts+1] = n .. ' ' .. it end
      end
      table.sort(parts)
      f.source = {name=pick.name, position=pick.position, counts=counts}
      f.takes_from = string.format('%s %s%s', pick.name, at(pick.position), #parts > 0 and ' holding ' .. table.concat(parts, ', ') or ' holding none of ' .. table.concat(items or {}, ', '))
    else
      -- (d27 batch292 IP) something it uses on the tile, the engine's target unset (targets.lua)
      local text, note
      if api.unset_target then text, note = api.unset_target(ins, 'pickup') end
      f.takes_from = text and string.format('%s (%s)', text, note) or 'nothing (the ground)'
    end
    local parts = api.condition_parts and try(function() return api.condition_parts(ins) end)
    if parts and #parts > 0 then
      f.condition = table.concat(parts, '; ')
      local st = try(function() return ins.status end)
      if st and st == defines.entity_status.disabled_by_control_behavior then f.holds_back = true end
      if f.holds_back and api.trace and budget and (budget.traces or 0) > 0 then
        budget.traces = budget.traces - 1
        local set = {}
        for _, l in ipairs(try(function() return api.trace(ins) end) or {}) do
          if l:find('combinator', 1, true) and #set < 3 then set[#set+1] = (l:gsub('^%s+', '')) end
        end
        if #set > 0 then f.set_by = set end
      end
    end
    return f
  end
  -- Whether e lacks item because its feeders are held off: a feeder off by its condition whose source holds the item,
  -- and no feeder running with it at its source or in its hand. Returns the held feeder's row and a line, or nil.
  function M.held(e, item, budget)
    local held, running
    for i, ins in ipairs(M.of(e)) do
      if i > MAX_FEEDERS then break end
      local f = M.read(ins, {item}, budget)
      local has = (f.source and (f.source.counts[item] or 0) > 0) or (f.hand and f.hand.item == item)
      if has then
        if f.holds_back then held = held or f else running = f end
      end
    end
    if not held or running then return nil end
    local n = held.source and held.source.counts[item] or 0
    held.line = string.format('held by its feeder\'s condition: %s %s, %s; takes from %s', held.name, at(held.position), held.condition or 'its condition',
      held.takes_from)
    held.stock = n
    return held
  end
  return M
end
