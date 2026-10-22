-- Equipment grids: the character's armor's and a vehicle's (operator 09:13,
-- a viewer via Astra: equipment worked only on the armor's grid). Read on
-- world n: a tank carries a medium-equipment-grid (6x8) and a spidertron a
-- spidertron-equipment-grid (10x6), both taking armor equipment; a car, a
-- locomotive and a wagon have none. As the vehicle's GUI allows: putting in
-- and taking out with the character in reach or seated in it; a read also
-- by remote view, in a chunk our force sees.
return function(api)
  local M = {}
  local TYPES = {'car', 'spider-vehicle', 'locomotive', 'cargo-wagon', 'fluid-wagon', 'artillery-wagon'}
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function round1(x) return math.floor(x * 10 + 0.5) / 10 end
  local function at(e) return string.format('%s (%g,%g)', e.name, round1(e.position.x), round1(e.position.y)) end
  M.at = at
  -- The vehicle a call names: its unit_number (the game finds vehicles by
  -- number) or a position on it; ours.
  function M.vehicle(p, ref)
    local v
    if type(ref) == 'number' then
      v = try(function() return game.get_entity_by_unit_number(ref) end)
      if not (v and v.valid) then error('no vehicle has unit_number ' .. tostring(ref), 0) end
    else
      local pos = api.position(type(ref) == 'table' and ref.position or ref)
      local bd
      for _, e in pairs(p.surface.find_entities_filtered{position=pos, radius=2.5, type=TYPES}) do
        if e.valid then
          local d = ((e.position.x - pos.x) ^ 2 + (e.position.y - pos.y) ^ 2) ^ 0.5
          if not bd or d < bd then v, bd = e, d end
        end
      end
      if not v then error(string.format('no vehicle at (%g,%g)', pos.x, pos.y), 0) end
    end
    if v.force ~= p.force then error(at(v) .. ' is not ours', 0) end
    return v
  end
  -- The grid a call acts on, where it is, and the vehicle: the armor's
  -- without vehicle; a vehicle's seated in it or in reach, or (read) by
  -- remote view in a chunk our force sees.
  function M.target(p, a, read)
    if a.vehicle == nil then
      local grid = p.character and p.character.grid
      if not grid then error('equipped armor has no equipment grid', 0) end
      return grid, 'armor'
    end
    local v = M.vehicle(p, a.vehicle)
    local grid = try(function() return v.grid end)
    if not grid then
      error(at(v) .. ' has no equipment grid (a tank and a spidertron have one; a car, locomotive or wagon does not)', 0)
    end
    local where = string.format('%s, unit_number %d', at(v), v.unit_number)
    local c = p.character
    if c and c.valid and c.vehicle == v then return grid, where .. ' (seated)', v end
    if try(function() return p.can_reach_entity(v) end) == true then return grid, where, v end
    if read then
      local seen = try(function() return p.force.is_chunk_visible(v.surface, {x=math.floor(v.position.x / 32), y=math.floor(v.position.y / 32)}) end)
      if seen then return grid, where .. ' (by remote view)', v end
      error(at(v) .. ' is in no chunk our force sees now (radar coverage or a character\'s sight)', 0)
    end
    error(api.out_of_reach(p, v) .. '; equipment goes in and out in reach or seated, as the vehicle\'s GUI allows', 0)
  end
  -- The armor worn, as its slot shows it: name, or name@quality (BD1).
  function M.armor(c)
    local st = try(function() local inv = c.get_inventory(defines.inventory.character_armor); return inv and inv[1] end)
    if not (st and try(function() return st.valid_for_read end)) then return nil end
    local q = try(function() return st.quality.name end)
    return q and q ~= 'normal' and st.name .. '@' .. q or st.name
  end
  -- A grid as its GUI shows it: size, the equipment by name (most first),
  -- shield and battery charge, free cells; rows: each piece where it sits.
  function M.view(grid, rows)
    local w, h = try(function() return grid.width end) or 0, try(function() return grid.height end) or 0
    local out = {grid=string.format('%dx%d', w, h)}
    local by, order, used = {}, {}, 0
    local list = {}
    for _, e in ipairs(try(function() return grid.equipment end) or {}) do
      local name = try(function() return e.name end)
      if name then
        -- (d22 batch94 BD1, viewer Aurora: "verify each agent's worn gear, grid quality and charge") counted by name
        -- and quality, as the grid's GUI shows each piece's quality
        local q = try(function() return e.quality.name end)
        q = q ~= 'normal' and q or nil
        local key = q and name .. '@' .. q or name
        if not by[key] then by[key] = {name=key, count=0}; order[#order+1] = by[key] end
        by[key].count = by[key].count + 1
        local shape = try(function() return e.shape end) or try(function() return e.prototype.shape end)
        used = used + (shape and (shape.width or 1) * (shape.height or 1) or 1)
        if rows then
          local pos = try(function() return e.position end)
          list[#list+1] = {name=name, position=pos, quality=q}
        end
      end
    end
    table.sort(order, function(x, y) return x.count > y.count or (x.count == y.count and x.name < y.name) end)
    local parts = {}
    for i, o in ipairs(order) do parts[i] = o.name .. '*' .. o.count end
    out.equipment = #parts > 0 and table.concat(parts, ' ') or 'empty'
    out.free_cells = math.max(0, w * h - used)
    local shield, max_shield = try(function() return grid.shield end), try(function() return grid.max_shield end)
    if max_shield and max_shield > 0 then out.shield = string.format('%d/%d', math.floor(shield + 0.5), math.floor(max_shield + 0.5)) end
    local stored, cap = try(function() return grid.available_in_batteries end), try(function() return grid.battery_capacity end)
    if cap and cap > 0 then out.battery_mj = string.format('%g/%g', round1(stored / 1e6), round1(cap / 1e6)) end
    if rows then out.rows = list end
    return out
  end
  return M
end
