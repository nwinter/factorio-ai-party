-- What an inserter takes from and puts into (Astra, three times in shift 9: a
-- platform bypass inserter that looked right reached no crusher). A built
-- inserter has the engine's own pickup_target and drop_target. A planned or
-- ghost inserter has none yet, so its pickup and drop points come from the
-- prototype's vectors (given facing north: pickup north of it, drop 1.2 tiles
-- south; turned clockwise with its direction, as the engine places them) and
-- the target is what stands on each point: a built entity, an entity planned
-- in the same call, or a ghost, of a kind an inserter can use.
return function(api)
  local M = {}
  -- Entity types an inserter can take from or put into (inventories, fuel,
  -- ammo, belts); anything else on the point is no target.
  M.TYPES = {}
  for _, t in ipairs({'container', 'logistic-container', 'linked-container', 'infinity-container', 'temporary-container',
      'proxy-container', 'cargo-bay', 'assembling-machine', 'furnace', 'rocket-silo', 'lab', 'boiler', 'burner-generator',
      'reactor', 'fusion-reactor', 'mining-drill', 'ammo-turret', 'artillery-turret', 'artillery-wagon', 'car',
      'spider-vehicle', 'cargo-wagon', 'locomotive', 'transport-belt', 'underground-belt', 'splitter', 'lane-splitter',
      'loader', 'loader-1x1', 'linked-belt', 'roboport', 'cargo-landing-pad', 'space-platform-hub', 'agricultural-tower',
      'asteroid-collector'}) do M.TYPES[t] = true end
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  -- cos and sin of each of the four directions an inserter takes.
  local TURN = {[0]={1, 0}, [4]={0, 1}, [8]={-1, 0}, [12]={0, -1}}
  local function xy(v) return v.x or v[1] or 0, v.y or v[2] or 0 end
  -- Pickup and drop points of an inserter prototype at pos facing dir, on
  -- the engine's grid of 1/256 tile (Astra, shift10: build replies said a
  -- long-handed inserter had no drop target where inspect a moment later
  -- showed the furnace). The prototype gives a long-handed drop of 2.2; the
  -- engine places it 2.19921875 off, and a stone furnace's box edge sits at
  -- x.30078125: on a private 2.0.77 server 8 of 96 long-handed drops into
  -- furnaces and assemblers fell outside the box at the unrounded point and
  -- inside at the engine's, where the engine targeted all 96 as these do.
  local function grid(v) return math.floor(v*256+0.5)/256 end
  function M.points(proto, pos, dir)
    local pv, dv = try(function() return proto.inserter_pickup_position end), try(function() return proto.inserter_drop_position end)
    if not (pv and dv) then return nil end
    local t = TURN[(dir or 0) % 16] or TURN[0]
    local function turn(v)
      local x, y = xy(v)
      return {x=grid(pos.x+x*t[1]-y*t[2]), y=grid(pos.y+x*t[2]+y*t[1])}
    end
    return turn(pv), turn(dv)
  end
  -- As inspect writes a target (details.lua): name (x,y).
  local function at(pos) return string.format('(%g,%g)', math.floor(pos.x*10+0.5)/10, math.floor(pos.y*10+0.5)/10) end
  local function tile_of(pos) return {x=math.floor(pos.x)+0.5, y=math.floor(pos.y)+0.5} end
  -- Passing or lying things on a point are neither a target nor in the way.
  local LOOSE = {['item-entity']=true, character=true, resource=true, ['construction-robot']=true, ['logistic-robot']=true,
    ['combat-robot']=true, ['capture-robot']=true, ['item-request-proxy']=true, corpse=true, ['character-corpse']=true,
    fire=true, sticker=true, projectile=true, ['tile-ghost']=true, ['deconstructible-tile-proxy']=true,
    ['highlight-box']=true, ['speech-bubble']=true, ['smoke-with-trigger']=true, unit=true, ['spider-unit']=true}
  -- What stands on a point for an inserter: text (name and where; 'planned'
  -- or 'ghost' before it when it is one) or nil and, when there is no
  -- target, what is there instead. A built entity comes first, then one
  -- planned in the same call (planned(pos) gives {name, position, type} of
  -- the one whose footprint covers pos), then a ghost.
  function M.at(surface, pos, planned)
    local built, ghost, other
    for _, e in pairs(surface.find_entities_filtered{position=pos}) do
      if e.valid then
        local t = e.type
        if M.TYPES[t] then built = built or e
        elseif t == 'entity-ghost' then
          if M.TYPES[e.ghost_type] then ghost = ghost or e else other = other or e end
        elseif not LOOSE[t] then other = other or e end
      end
    end
    if built then return string.format('%s %s', built.name, at(built.position)) end
    local p = planned and planned(pos)
    if p and M.TYPES[p.type] then return string.format('planned %s %s', p.name, at(p.position)) end
    if ghost then return string.format('ghost %s %s', ghost.ghost_name, at(ghost.position)) end
    local where = at(tile_of(pos))
    if other then return nil, string.format('%s at %s takes no items', other.type == 'entity-ghost' and 'ghost '..other.ghost_name or other.name, where) end
    if p then return nil, string.format('planned %s at %s takes no items', p.name, where) end
    local tile = try(function() return surface.get_tile(math.floor(pos.x), math.floor(pos.y)).name end)
    if tile == 'empty-space' then return nil, 'empty space at '..where end
    return nil, 'the ground at '..where
  end
  -- A planned or ghost inserter: {pickup, drop, missing} as text.
  function M.plan(surface, proto, pos, dir, planned)
    local pick, drop = M.points(proto, pos, dir)
    if not pick then return nil end
    local pt, pw = M.at(surface, pick, planned)
    local dt, dw = M.at(surface, drop, planned)
    local missing = {}
    if not pt then missing[#missing+1] = 'no pickup target' end
    if not dt then missing[#missing+1] = 'no drop target' end
    return {pickup=pt or 'none: '..pw, drop=dt or 'none: '..dw, missing=#missing > 0 and table.concat(missing, ', ') or nil}
  end
  -- A built inserter: the engine's targets. 'no pickup target' (it takes
  -- only what lies on the ground there), 'no drop target' (it puts its items
  -- on the ground there, or over empty space throws them away), or nil.
  -- A built inserter's targets, as entities (nil: none).
  function M.read(e)
    local pick = try(function() local t = e.pickup_target; return t and t.valid ~= false and t or nil end)
    local drop = try(function() local t = e.drop_target; return t and t.valid ~= false and t or nil end)
    return pick, drop
  end
  function M.missing(e)
    if not (e and e.valid and e.type == 'inserter') then return nil end
    local pick, drop = M.read(e)
    local missing = {}
    if not pick then missing[#missing+1] = 'no pickup target' end
    if not drop then missing[#missing+1] = 'no drop target' end
    return #missing > 0 and table.concat(missing, ', ') or nil
  end
  -- name (x,y), as the lines write a target.
  function M.name_at(t) return string.format('%s %s', t.name, at(t.position)) end
  -- An inserter ghost: the same reading from its prototype and points.
  function M.ghost(e)
    if not (e and e.valid and e.type == 'entity-ghost' and e.ghost_type == 'inserter') then return nil end
    return M.plan(e.surface, e.ghost_prototype, e.position, e.direction)
  end
  -- Inserter ghosts with a point that has no target: rows (up to max) and,
  -- past them, the count of all; nil when every one has both.
  function M.check(ghosts, max)
    local rows, n = {}, 0
    for _, g in ipairs(ghosts) do
      local t = g.valid and try(function() return M.ghost(g) end)
      if t and t.missing then
        n = n + 1
        if #rows < max then rows[#rows+1] = {name=g.ghost_name, position=g.position, missing=t.missing, pickup=t.pickup, drop=t.drop} end
      end
    end
    if n == 0 then return nil, nil end
    return rows, n > #rows and n or nil
  end
  return M
end
