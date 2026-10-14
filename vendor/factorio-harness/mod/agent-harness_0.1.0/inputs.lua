-- A crafting machine's input against its recipe (Grok, shift11: an
-- electromagnetic plant on electronic-circuit read item_ingredient_shortage
-- 12 times while it held 135 iron plates and no copper cable). When an
-- ingredient lacks what one craft takes while another is stacked, inspect
-- says so, and which inserters drop into the machine with what their sources
-- (belt, chest, a machine's output) hold of the missing one, and a filter
-- that keeps it out. Pure: the factory takes the harness's try.
return function(api)
  local M = {}
  local try = api.try or function(fn) local ok, v = pcall(fn); if ok then return v end end
  local INPUT = {['assembling-machine']='assembling_machine_input', furnace='furnace_source'}
  local BELTS = {['transport-belt']=true, ['underground-belt']=true, splitter=true, ['lane-splitter']=true, ['linked-belt']=true,
    loader=true, ['loader-1x1']=true}
  M.STACKED = 5  -- crafts' worth held of another ingredient that makes the lack an imbalance
  M.MAX_FEEDERS = 8

  local function at(e) return string.format('(%g,%g)', e.position.x, e.position.y) end

  -- How much of item name a feeder's source holds now, or nil when it holds no items.
  local function holds(src, name)
    if not (src and src.valid) then return nil end
    if BELTS[src.type] then
      local n = 0
      local lines = try(function() return src.get_max_transport_line_index() end) or 0
      for i = 1, lines do n = n+(try(function() return src.get_transport_line(i).get_item_count(name) end) or 0) end
      return n
    end
    if src.type == 'assembling-machine' or src.type == 'furnace' then
      return try(function() return src.get_output_inventory().get_item_count(name) end)
    end
    return try(function() return src.get_item_count(name) end)
  end

  -- Whether an inserter's filters let name through (nil: it has none in use).
  local function filter_blocks(ins, name)
    if not try(function() return ins.use_filters end) then return nil end
    local mode = try(function() return ins.inserter_filter_mode end) or 'whitelist'
    local listed = false
    for i = 1, try(function() return ins.filter_slot_count end) or 0 do
      local f = try(function() return ins.get_filter(i) end)
      local n = type(f) == 'table' and f.name or f
      if type(n) ~= 'string' then n = try(function() return n.name end) end
      if n == name then listed = true end
    end
    if mode == 'blacklist' then return listed end
    return not listed
  end

  local function inside(p, b)
    return p ~= nil and p.x >= b.left_top.x and p.x <= b.right_bottom.x and p.y >= b.left_top.y and p.y <= b.right_bottom.y
  end

  -- The inserters dropping into e: rows {text, holds}, the ones whose source holds name first. One without a drop
  -- target yet (built this tick) counts when its drop point is on e.
  function M.feeders(e, name)
    local b = e.bounding_box
    local area = {{b.left_top.x-3, b.left_top.y-3}, {b.right_bottom.x+3, b.right_bottom.y+3}}
    local rows = {}
    for _, ins in pairs(e.surface.find_entities_filtered{area=area, type='inserter', force=e.force}) do
      local target = ins.valid and try(function() return ins.drop_target end)
      if ins.valid and (target == e or target == nil and inside(try(function() return ins.drop_position end), b)) then
        local src = try(function() return ins.pickup_target end)
        local n = holds(src, name)
        local text = string.format('%s %s from %s', ins.name, at(ins), src and src.valid and (src.name..' '..at(src)) or 'the ground')
        local can = n or 0
        if filter_blocks(ins, name) then text, can = text..': its filter keeps '..name..' out', 0
        elseif n == nil then text = text..': holds no items'
        else text = text..string.format(': %s %d there', name, n) end
        rows[#rows+1] = {text=text, holds=can, x=ins.position.x, y=ins.position.y}
      end
    end
    table.sort(rows, function(a, b)
      if a.holds ~= b.holds then return a.holds > b.holds end
      if a.x ~= b.x then return a.x < b.x end
      return a.y < b.y
    end)
    return rows
  end

  -- {input_imbalance, feeders, feeders_count} for e, or nil when its recipe's ingredients are all there for a craft,
  -- or none of the others is stacked either (an empty machine is starved, its status says so).
  function M.check(e, status)
    local inv_name = INPUT[e.type]
    if not inv_name then return nil end
    local recipe = try(function() return e.get_recipe() end) or (e.type == 'furnace' and try(function() return e.previous_recipe end))
    recipe = type(recipe) == 'table' and recipe.name and prototypes.recipe[recipe.name] or recipe
    if not recipe then return nil end
    local inv = try(function() return e.get_inventory(defines.inventory[inv_name]) end)
    local fluids = try(function() return e.get_fluid_contents() end) or {}
    local short, stacked = {}, {}
    for _, ing in ipairs(try(function() return recipe.ingredients end) or {}) do
      local have
      if ing.type == 'fluid' then have = fluids[ing.name] or 0
      else have = inv and try(function() return inv.get_item_count(ing.name) end) or 0 end
      local need = ing.amount or 1
      if have < need then short[#short+1] = {name=ing.name, have=have, need=need, fluid=ing.type == 'fluid'}
      elseif have >= need*M.STACKED then stacked[#stacked+1] = {name=ing.name, have=have} end
    end
    if #short == 0 or #stacked == 0 then return nil end
    local parts = {}
    for _, s in ipairs(stacked) do parts[#parts+1] = string.format('%s %d', s.name, math.floor(s.have+0.5)) end
    local lacks = {}
    for _, s in ipairs(short) do
      lacks[#lacks+1] = string.format('%s %d%s', s.name, math.floor(s.have),
        s.have > 0 and string.format(' (a craft takes %g)', s.need) or '')
    end
    local first = short[1]
    local line = string.format('%s in input, %s', table.concat(parts, ', '), table.concat(lacks, ', '))
    if status and status:find('ingredient_shortage', 1, true) then line = line..': '..status..' on '..first.name
    elseif status then line = line..' (status '..status..')' end
    local out = {input_imbalance=line}
    if first.fluid then
      out.feeders = {first.name..' comes through its pipes (inspect fluid_connections)'}
      return out
    end
    local rows = M.feeders(e, first.name)
    if #rows == 0 then
      out.feeders = {'no inserter drops into it'}
    else
      local list = {}
      for i = 1, math.min(#rows, M.MAX_FEEDERS) do list[i] = rows[i].text end
      if rows[1].holds == 0 then
        table.insert(list, 1, string.format('no %s for its %d feeder%s: none at their sources, or a filter keeps it out', first.name, #rows, #rows == 1 and '' or 's'))
      end
      out.feeders = list
      out.feeders_count = #rows > M.MAX_FEEDERS and #rows or nil
    end
    return out
  end
  return M
end
