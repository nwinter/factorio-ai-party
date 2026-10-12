-- Valid placements near a position (shore.lua): the nearest centres and
-- directions where the game's own manual build check (can_place_entity,
-- build_check_type manual) accepts an entity. A refused offshore-pump build
-- lists them (all four directions, within 12 tiles), as does a build refused
-- by water under the footprint (the asked direction, within 6 tiles); the
-- placements read returns the same list. Candidates are filtered by the
-- water tiles around them before the game is asked: a pump needs water and
-- land at its footprint, anything else no water under it.
return function(api)
  local M = {}
  local DIRS = {0, 4, 8, 12}
  local NAMES = {[0]='north', [4]='east', [8]='south', [12]='west'}
  local MAX = 3
  -- can_place_entity calls per search, at most.
  local MAX_CHECKS = 400

  -- Footprint in tiles along x and y for a direction.
  local function size(proto, dir)
    local ok, w, h = pcall(function() return proto.tile_width, proto.tile_height end)
    if not (ok and w and h and w > 0 and h > 0) then
      local b = proto.collision_box
      w = b and math.ceil(b.right_bottom.x - b.left_top.x - 0.01) or 1
      h = b and math.ceil(b.right_bottom.y - b.left_top.y - 0.01) or 1
    end
    w, h = math.max(1, w), math.max(1, h)
    if dir == 4 or dir == 12 then w, h = h, w end
    return w, h
  end
  -- Centres along one axis: tile centres for an odd size, tile edges for an even one.
  local function centres(v, n, r)
    local base = n % 2 == 1 and math.floor(v) + 0.5 or math.floor(v + 0.5)
    local out = {}
    for i = -r, r do out[#out+1] = base + i end
    return out
  end
  local function is_water(tile)
    local ok, layers = pcall(function() local m = tile.prototype.collision_mask; return m and m.layers end)
    return ok and layers and layers.water_tile and true or false
  end
  -- Water tiles in a box: set[x][y] by tile index; any: whether there is one.
  local function water_in(surface, l, t, r, b)
    local set, any = {}, false
    local tiles = surface.find_tiles_filtered{area={left_top={x=l, y=t}, right_bottom={x=r, y=b}}, collision_mask='water_tile',
      limit=(r - l + 1) * (b - t + 1)}
    for _, tile in pairs(tiles) do
      if is_water(tile) then
        local x, y = math.floor(tile.position.x), math.floor(tile.position.y)
        set[x] = set[x] or {}
        set[x][y] = true
        any = true
      end
    end
    return set, any
  end
  -- Water and land tiles in a centre's footprint, grown by `grow` tiles.
  local function tiles_at(water, c, w, h, grow)
    local x0, y0 = math.floor(c.x - w / 2 + 0.01) - grow, math.floor(c.y - h / 2 + 0.01) - grow
    local wet, dry = 0, 0
    for x = x0, x0 + w - 1 + 2 * grow do
      local col = water[x]
      for y = y0, y0 + h - 1 + 2 * grow do
        if col and col[y] then wet = wet + 1 else dry = dry + 1 end
      end
    end
    return wet, dry
  end

  -- The nearest valid placements of proto around pos: {position, direction}
  -- nearest first, at most 3; and how many positions the game checked.
  -- dirs: the directions to try (the first wins a tie).
  function M.find(p, proto, pos, radius, dirs)
    local surface = p.surface
    local pump = proto.type == 'offshore-pump'
    local water, any = water_in(surface, math.floor(pos.x) - radius - 4, math.floor(pos.y) - radius - 4,
      math.floor(pos.x) + radius + 4, math.floor(pos.y) + radius + 4)
    if pump and not any then return {}, 0 end
    local cands = {}
    for rank, dir in ipairs(dirs) do
      local w, h = size(proto, dir)
      local xs, ys = centres(pos.x, w, radius), centres(pos.y, h, radius)
      for _, x in ipairs(xs) do
        for _, y in ipairs(ys) do
          local d = ((x - pos.x) ^ 2 + (y - pos.y) ^ 2) ^ 0.5
          if d <= radius + 0.01 then
            local c = {x=x, y=y}
            local keep
            if pump then
              local wet, dry = tiles_at(water, c, w, h, 1)
              keep = wet > 0 and dry > 0
            else
              keep = tiles_at(water, c, w, h, 0) == 0
            end
            if keep then cands[#cands+1] = {position=c, dir=dir, d=d, rank=rank} end
          end
        end
      end
    end
    table.sort(cands, function(a, b)
      if math.abs(a.d - b.d) > 0.001 then return a.d < b.d end
      if a.rank ~= b.rank then return a.rank < b.rank end
      if a.position.x ~= b.position.x then return a.position.x < b.position.x end
      return a.position.y < b.position.y
    end)
    local out, checks, seen = {}, 0, {}
    for _, c in ipairs(cands) do
      if #out >= MAX or checks >= MAX_CHECKS then break end
      local key = c.position.x .. ',' .. c.position.y
      if not seen[key] then
        checks = checks + 1
        if surface.can_place_entity{name=proto.name, position=c.position, direction=c.dir, force=p.force,
            build_check_type=defines.build_check_type.manual} then
          seen[key] = true
          out[#out+1] = {position=c.position, direction=NAMES[c.dir]}
        end
      end
    end
    return out, checks
  end

  local function listed(list)
    local parts = {}
    for _, s in ipairs(list) do parts[#parts+1] = string.format('(%g,%g) %s', s.position.x, s.position.y, s.direction) end
    return table.concat(parts, ', ')
  end
  -- The text a refused build appends: for an offshore pump (any refusal) or
  -- an entity refused by water under its footprint (water true).
  function M.hint(p, proto, pos, direction, water)
    local pump = proto.type == 'offshore-pump'
    if not (pump or water) then return nil end
    if pump then
      local dirs = {direction}
      for _, d in ipairs(DIRS) do if d ~= direction then dirs[#dirs+1] = d end end
      local found = M.find(p, proto, pos, 12, dirs)
      if #found == 0 then return '; no valid offshore-pump placement within 12 tiles (game build check)' end
      return '; nearest valid ' .. proto.name .. ' placements (game build check, within 12 tiles): ' .. listed(found)
    end
    local found = M.find(p, proto, pos, 6, {direction})
    local facing = NAMES[direction] or tostring(direction)
    if #found == 0 then return '; no position within 6 tiles where ' .. proto.name .. ' fits facing ' .. facing .. ' (game build check)' end
    return '; nearest positions where ' .. proto.name .. ' fits facing ' .. facing .. ' (game build check, within 6 tiles): ' .. listed(found)
  end

  M.schema = {
    placements={name='entity or item name (an item: the entity it places)',position='optional {x,y} (default you)',
      radius='optional 1..16 (default 12 for an offshore-pump, else 6)',direction='optional compass name: only this direction (default north, east, south, west)',
      returns='placements [{position, direction}]: at most 3, nearest first, where the game\'s manual build check accepts the entity (no reach or item check); checked: positions the game checked (at most 400)'},
  }
  M.handlers = {}
  function M.handlers.placements(p, a)
    assert(type(a.name) == 'string', 'name is required')
    local proto = prototypes.entity[a.name]
    if not proto then
      local item = prototypes.item[a.name]
      proto = item and item.place_result
    end
    assert(proto, 'no entity or item named ' .. a.name .. ' that places an entity')
    local pos = a.position and api.position(a.position) or p.position
    api.assert_visible(p, pos, 'position')
    local pump = proto.type == 'offshore-pump'
    local radius = api.integer(a.radius, pump and 12 or 6, 1, 16, 'radius')
    local dirs = DIRS
    if a.direction ~= nil then
      local d = api.directions[a.direction]
      assert(d and NAMES[d], 'direction is north, east, south or west')
      dirs = {d}
    end
    local found, checked = M.find(p, proto, pos, radius, dirs)
    return {name=proto.name, position=pos, radius=radius, placements=found, checked=checked}
  end
  return M
end
