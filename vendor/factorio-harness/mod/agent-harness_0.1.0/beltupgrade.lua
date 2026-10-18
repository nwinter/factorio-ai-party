-- belt_upgrade {position, to?, tiles?, dry_run?} (batch25 B1, Opus: straight lines placed over a curve broke a trunk):
-- the belt line through position traced both ways (each tile's own direction, an underground's entrance and exit, a
-- splitter on its centre), and each tile replaced by hand with the faster one at the same position and direction, as a
-- player's fast-replace does, by build from the character's items (its walk into reach, its checks). to: the target
-- belt (fast-, express- or turbo-transport-belt: the undergrounds and splitters of that tier go with it); without it,
-- each entity's own next upgrade (the upgrade planner's default). A tile already at the target, or with none, is left.
return function(api)
  local M = {}
  local BELT = {['transport-belt']=true, ['underground-belt']=true, splitter=true}
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function at(q) return string.format('(%g,%g)', q.x, q.y) end
  local function partner(b, kind)
    if b.type == 'underground-belt' and try(function() return b.belt_to_ground_type end) == kind then
      local nb = try(function() return b.neighbours end)
      if nb and nb.valid then return nb end
    end
  end
  local function before(b)
    local bn = try(function() return b.belt_neighbours end)
    local ins = bn and bn.inputs or {}
    for _, x in ipairs(ins) do if BELT[x.type] and x.direction == b.direction then return x end end
    if #ins == 1 and BELT[ins[1].type] then return ins[1] end
    return partner(b, 'output')
  end
  local function after(b)
    local bn = try(function() return b.belt_neighbours end)
    local out = bn and bn.outputs and bn.outputs[1]
    if out and out.valid and BELT[out.type] then return out end
    return partner(b, 'input')
  end
  function M.trace(e, max)
    local path, seen = {e}, {[e.unit_number]=true}
    local b = e
    while #path < max do
      local x = before(b)
      if not (x and x.valid) or seen[x.unit_number] then break end
      seen[x.unit_number] = true; table.insert(path, 1, x); b = x
    end
    b = e
    while #path < max do
      local x = after(b)
      if not (x and x.valid) or seen[x.unit_number] then break end
      seen[x.unit_number] = true; path[#path+1] = x; b = x
    end
    return path
  end
  local KIND = {['transport-belt']='transport-belt', ['underground-belt']='underground-belt', splitter='splitter'}
  function M.handler(p, a)
    assert(a.position, 'belt_upgrade: position on a belt, underground or splitter of the line')
    local max = a.tiles == nil and 256 or a.tiles
    assert(type(max) == 'number' and max >= 1 and max <= 512 and max == math.floor(max), 'tiles: 1..512 (default 256: the line both ways up to that many)')
    local tier
    if a.to ~= nil then
      tier = type(a.to) == 'string' and a.to:match('^(.-)transport%-belt$')
      assert(tier and prototypes.entity[a.to], 'to: a transport belt name (transport-belt, fast-transport-belt, express-transport-belt, turbo-transport-belt); its undergrounds and splitters go with it')
    end
    local e = api.entity(p, {position=a.position})
    assert(BELT[e.type], e.name .. ' at ' .. at(e.position) .. ' is not a belt, underground or splitter')
    local path = M.trace(e, max)
    local builds, rows, left, need = {}, {}, {}, {}
    for _, b in ipairs(path) do
      local target = tier and (tier .. KIND[b.type]) or try(function() return b.prototype.next_upgrade.name end)
      local proto = target and prototypes.entity[target]
      if not proto then left[#left+1] = string.format('%s %s: no upgrade', b.name, at(b.position))
      elseif target == b.name then left[#left+1] = string.format('%s %s: already %s', b.name, at(b.position), target)
      else
        local item = try(function() return proto.items_to_place_this[1].name end) or target
        local entry = {item=item, position={x=b.position.x, y=b.position.y}, direction=b.direction}
        if b.type == 'underground-belt' then entry.type = try(function() return b.belt_to_ground_type end) end
        builds[#builds+1] = entry
        need[item] = (need[item] or 0) + 1
        rows[#rows+1] = string.format('%s %s facing %s%s -> %s', b.name, at(b.position), api.compass(b.direction) or tostring(b.direction), entry.type and ' (' .. entry.type .. ')' or '', target)
      end
    end
    local items = {}
    for item, n in pairs(need) do items[#items+1] = item .. ' ' .. n end
    table.sort(items)
    local out = {tiles=#path, from=path[1].position, to=path[#path].position, upgrades=#builds, needs=#items > 0 and table.concat(items, ', ') or 'nothing',
      left=#left > 0 and left or nil, rows=rows, line=string.format('%d tiles traced from %s to %s; %d to replace (%s); %d left', #path, at(path[1].position), at(path[#path].position), #builds,
        #items > 0 and table.concat(items, ', ') or 'nothing', #left)}
    if #builds == 0 then out.note = 'nothing to replace'; return out end
    local ok, built = pcall(api.build, p, {builds=builds, all=true, dry_run=a.dry_run or nil})
    if not ok then out.error = tostring(built):gsub('^[^:]*:%d+: ', ''); return out end
    out.build = built
    out.note = a.dry_run and 'nothing replaced (dry_run): build\'s check of each entry' or 'each tile at its own position and direction, by build (its walk into reach, materials, failed entries)'
    return out
  end
  M.schema = {belt_upgrade = {position='a belt, underground or splitter tile of the line {x,y}', to='optional target belt: fast-, express- or turbo-transport-belt (undergrounds and splitters of that tier with it; default each one\'s next upgrade)',
    tiles='optional 1..512 (default 256): the line traced both ways up to that many', dry_run='optional true: build\'s check of each entry, nothing replaced',
    returns='tiles, from, to, upgrades, needs (items by name), rows (each tile: name, where, facing, an underground\'s input or output, the target), left (already at the target, or no upgrade), line; build (the build reply: placed, failed, materials). By hand from your inventory, each tile at its own position and direction, as a player\'s fast-replace'}}
  return M
end
