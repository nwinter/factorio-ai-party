-- A bounded schematic of an owned platform, with no character/inventory read.
return function(api)
  local M = {}
  local function int(n, default, low, high, label)
    n = n == nil and default or n
    assert(type(n) == 'number' and n % 1 == 0 and n >= low and n <= high, label .. ' must be ' .. low .. '..' .. high)
    return n
  end
  function M.read(p, a)
    assert(a.surface == nil, 'give platform or surface, not both')
    local pl = api.platform(p, a.platform)
    local s = pl.surface
    assert(s and s.valid ~= false, 'platform has no surface')
    local pos = a.position or (pl.hub and pl.hub.position) or {x=0,y=0}
    assert(type(pos) == 'table' and type(pos.x) == 'number' and type(pos.y) == 'number'
      and pos.x == pos.x and pos.y == pos.y and math.abs(pos.x) < 1e6 and math.abs(pos.y) < 1e6, 'position requires finite x,y')
    local radius = int(a.radius, 24, 1, 32, 'radius')
    local limit = int(a.limit, 512, 1, 512, 'limit')
    local x, y = math.floor(pos.x), math.floor(pos.y)
    local area = {{x-radius,y-radius},{x+radius+1,y+radius+1}}
    local out = {platform=pl.name, surface=s.name, position={x=pos.x,y=pos.y}, radius=radius,
      entities={}, tile_runs={}, tile_count=0, truncated=false, tiles_truncated=false}
    local found = s.find_entities_filtered{area=area, force=p.force, limit=limit+1}
    for i, e in ipairs(found) do
      if i > limit then out.truncated=true; break end
      if e.valid then
        out.entities[#out.entities+1] = {name=e.type == 'entity-ghost' and e.ghost_name or e.name,
          type=e.type, ghost=e.type == 'entity-ghost' or nil, position=e.position, direction=e.direction,
          box=e.bounding_box}
      end
    end
    if a.tiles ~= false then
      -- Empty space is the background. Runs of foundation keep large platforms
      -- from spending most of the call serializing thousands of repeated tile rows.
      local rows = {}
      for _, tile in ipairs(s.find_tiles_filtered{area=area, name='space-platform-foundation', limit=4226}) do
        local pos = tile.position
        rows[pos.y] = rows[pos.y] or {}
        rows[pos.y][#rows[pos.y]+1] = pos.x
        out.tile_count = out.tile_count + 1
      end
      for y = area[1][2], area[2][2]-1 do
        local xs = rows[y] or {}
        table.sort(xs)
        local run
        for _, x in ipairs(xs) do
          if run and x == run.x+run.count then run.count=run.count+1
          else run={x=x,y=y,count=1,name='space-platform-foundation'};out.tile_runs[#out.tile_runs+1]=run end
        end
      end
    end
    return out
  end
  return M
end
