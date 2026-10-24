-- Requester and buffer chests: what the game does with what a hand puts in, and a chest one item fills (Sonnet, d15
-- shifts 19-20, hours of starvation twice: a hand-fed item over its request went back to storage with the robots, and an
-- inserter filled every slot of a requester with one item while the chest asked for others). Seen on a 2.0.77 copy of
-- world n: a requester asking iron-plate 10..20 given 100 kept 20 and moved 80 to its trash slots, and robots took 78
-- of them within seconds; copper-plate 10..inf given 100 kept all 100; coal not requested stayed. With trash
-- unrequested switched on, the coal went to the trash and copper-plate fell to its min of 10.
return function(api)
  local M = {}
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function name_of(v)
    if type(v) == 'string' then return v end
    local n = v ~= nil and try(function() return v.name end)
    if type(n) == 'string' then return n end
    n = n ~= nil and try(function() return n.name end)
    return type(n) == 'string' and n or nil
  end
  local function point_of(e)
    return try(function() return e.get_logistic_point(defines.logistic_member_index.logistic_container) end)
  end
  -- The chest's request for item: min (sum), max (nil: none), and whether any slot names it.
  function M.request(pt, item)
    local min, max, named = 0, nil, false
    for _, f in ipairs(pt and try(function() return pt.filters end) or {}) do
      if name_of(f.name) == item then
        named = true
        min = min + (f.count or 0)
        if f.max_count then max = (max or 0) + f.max_count end
      end
    end
    return min, max, named
  end
  local function main(e) return try(function() return e.get_inventory(defines.inventory.chest) end) end
  -- What the game does with item in requester or buffer chest e now (nil: nothing leaves it).
  function M.over(e, item)
    local mode = try(function() return e.prototype.logistic_mode end)
    if mode ~= 'requester' and mode ~= 'buffer' then return nil end
    local pt = point_of(e)
    if not pt then return nil end
    local inv = main(e)
    local held = inv and try(function() return inv.get_item_count(item) end) or 0
    local min, max, named = M.request(pt, item)
    local trash_unrequested = try(function() return pt.trash_not_requested end) == true
    if named and max and held > max then
      return string.format('%s: the chest holds %d, over its request max %d: the game moves the %d over it to the chest\'s trash slots, and logistic robots take them out of the chest', item, held, max, held - max)
    elseif named and trash_unrequested and not max and held > min then
      return string.format('%s: the chest holds %d, over its request %d with trash unrequested on: the game moves the %d over it to the trash slots, and logistic robots take them out of the chest', item, held, min, held - min)
    elseif not named and trash_unrequested and held > 0 then
      return string.format('%s is not requested here and trash unrequested is on: the game moves all %d to the trash slots, and logistic robots take them out of the chest', item, held)
    elseif not named and held > 0 then
      return string.format('%s is not requested here: it stays in the chest\'s slots (trash unrequested is off)', item)
    end
  end
  -- Every slot of e taken by one item while e requests others it lacks: {item, count, slots, short, fillers, line}.
  function M.one_item(e)
    local inv = main(e)
    if not inv then return nil end
    local size = try(function() return #inv end) or 0
    if size == 0 or (try(function() return inv.count_empty_stacks(true, false) end) or 1) > 0 then return nil end
    local list = try(function() return inv.get_contents() end) or {}
    if #list ~= 1 then return nil end
    local only, n = name_of(list[1].name), list[1].count or 0
    local pt = point_of(e)
    local short = {}
    for _, f in ipairs(pt and try(function() return pt.filters end) or {}) do
      local name = name_of(f.name)
      if name and name ~= only and (f.count or 0) > 0 and (try(function() return inv.get_item_count(name) end) or 0) < f.count then short[#short+1] = name end
    end
    if #short == 0 then return nil end
    -- What puts it there: inserters dropping into the chest.
    local fillers = {}
    for _, i in ipairs(try(function() return e.surface.find_entities_filtered{type='inserter', force=e.force, position=e.position, radius=3, limit=16} end) or {}) do
      if try(function() return i.drop_target end) == e and #fillers < 3 then
        local src = try(function() return i.pickup_target end)
        fillers[#fillers+1] = string.format('%s (%g,%g)%s', i.name, i.position.x, i.position.y, src and src.valid and string.format(' from %s (%g,%g)', src.name, src.position.x, src.position.y) or '')
      end
    end
    local min, max = M.request(pt, only)
    local asked = min > 0 and string.format(' (it requests %d%s)', min, max and '..' .. max or '') or ' (it does not request it)'
    return {item=only, count=n, slots=size, short=short, fillers=fillers,
      line=string.format('one item fills every slot: %s %d in all %d slots%s, so %s cannot come in%s', only, n, size, asked, table.concat(short, ', '),
        #fillers > 0 and '; put in by ' .. table.concat(fillers, '; ') or '; no inserter puts things into it')}
  end
  return M
end
