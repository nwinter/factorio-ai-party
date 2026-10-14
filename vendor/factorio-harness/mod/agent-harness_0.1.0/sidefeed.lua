-- An underground belt entrance fed from the side (Sol, shift10: "inserter
-- side-feeding an underground input", hit twice, long nutrient starvation).
-- Checked on a private 2.0.77 server, burner inserters and belts into
-- underground pairs, 12 s each:
--   * an inserter beside an entrance puts its items on the entrance's far
--     lane only, as on a belt: the near lane gets none from it (fed from both
--     sides, both lanes fill);
--   * a belt side-loading into an entrance passes only its lane on the
--     entrance's downstream side; its other lane stops at the entrance.
-- Lanes are named by the side they run on and as the game counts them along
-- the flow (left, right). The factory is pure so the same module can be
-- bundled into a hot reload.
return function(api)
  local M = {}
  local SIDE = {[0]='north', [4]='east', [8]='south', [12]='west'}
  local STEP = {[0]={0, -1}, [4]={1, 0}, [8]={0, 1}, [12]={-1, 0}}
  local function tile(pos) return math.floor(pos.x), math.floor(pos.y) end
  local function at(pos) return string.format('(%g,%g)', math.floor(pos.x*10+0.5)/10, math.floor(pos.y*10+0.5)/10) end
  -- The lane on a side of something flowing toward dir: left or right.
  local function lane(dir, side) return side == (dir+12)%16 and 'left' or 'right' end
  -- ug: {name, position, direction (its flow), kind = input | output}.
  local function entrance_text(ug) return string.format('%s %s, an entrance flowing %s', ug.name, at(ug.position), SIDE[ug.direction%16] or '?') end
  -- An inserter at pos dropping at drop: nil unless the drop is on the entrance's tile from one of its sides.
  function M.inserter(name, pos, drop, ug)
    if ug.kind ~= 'input' or not SIDE[ug.direction%16] then return nil end
    local ux, uy = tile(ug.position)
    local dx, dy = tile(drop)
    if dx ~= ux or dy ~= uy then return nil end
    local ox, oy = pos.x-ug.position.x, pos.y-ug.position.y
    local from
    if math.abs(ox) > math.abs(oy) then from = ox > 0 and 4 or 12 else from = oy > 0 and 8 or 0 end
    local flow = ug.direction%16
    if from%8 == flow%8 then return nil end
    local far, near = (from+8)%16, from
    return string.format('%s %s drops onto %s, from its %s side: only its %s (%s) lane gets these items; its %s (%s) lane gets none from it',
      name, at(pos), entrance_text(ug), SIDE[from], SIDE[far], lane(flow, far), SIDE[near], lane(flow, near))
  end
  -- A belt at pos flowing dir: nil unless it runs into the entrance's tile from one of its sides.
  function M.belt(name, pos, dir, ug)
    if ug.kind ~= 'input' or not SIDE[ug.direction%16] then return nil end
    local s = STEP[(dir or 0)%16]
    if not s then return nil end
    local bx, by = tile(pos)
    local ux, uy = tile(ug.position)
    if bx+s[1] ~= ux or by+s[2] ~= uy then return nil end
    local flow = ug.direction%16
    if dir%8 == flow%8 then return nil end
    local pass, stop = flow, (flow+8)%16
    return string.format('%s %s side-loads %s, from its %s side: only the belt\'s %s (%s) lane goes in; its %s (%s) lane stops at the entrance',
      name, at(pos), entrance_text(ug), SIDE[(dir+8)%16], SIDE[pass], lane(dir, pass), SIDE[stop], lane(dir, stop))
  end
  -- Built entities: what feeds this one from the side, or what this one feeds (an inserter, a belt, an entrance).
  local function ug_of(e)
    local kind = api.try(function() return e.belt_to_ground_type end)
    return {name=e.name, position=e.position, direction=e.direction, kind=kind}
  end
  local function find(surface, pos, types)
    local ok, list = pcall(surface.find_entities_filtered, {position=pos, type=types, limit=1})
    return ok and list[1] or nil
  end
  function M.built(e)
    local out = {}
    if not (e and e.valid) then return out end
    local s = e.surface
    if e.type == 'inserter' then
      local drop = api.try(function() return e.drop_position end)
      local u = drop and find(s, drop, 'underground-belt')
      local line = u and M.inserter(e.name, e.position, drop, ug_of(u))
      if line then out[#out+1] = line end
    elseif e.type == 'transport-belt' then
      local st = STEP[e.direction%16]
      local u = st and find(s, {x=math.floor(e.position.x)+st[1]+0.5, y=math.floor(e.position.y)+st[2]+0.5}, 'underground-belt')
      local line = u and M.belt(e.name, e.position, e.direction, ug_of(u))
      if line then out[#out+1] = line end
    elseif e.type == 'underground-belt' then
      local ug = ug_of(e)
      if ug.kind ~= 'input' then return out end
      local x, y = e.position.x, e.position.y
      local ok, ins = pcall(s.find_entities_filtered, {area={{x-3.5, y-3.5}, {x+3.5, y+3.5}}, type='inserter', force=e.force})
      for _, i in ipairs(ok and ins or {}) do
        local drop = i.valid and api.try(function() return i.drop_position end)
        local line = drop and M.inserter(i.name, i.position, drop, ug)
        if line and #out < 8 then out[#out+1] = line end
      end
      for _, d in pairs(STEP) do
        local b = find(s, {x=x+d[1], y=y+d[2]}, 'transport-belt')
        local line = b and b.valid and M.belt(b.name, b.position, b.direction, ug)
        if line and #out < 8 then out[#out+1] = line end
      end
    end
    return out
  end
  return M
end
