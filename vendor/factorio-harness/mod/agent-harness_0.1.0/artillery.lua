-- Artillery (Grok, d15 14:07: artillery fired at the nearest nest in range as soon as a shell went in, waking the next
-- nest): what the game gives a player. The turret's (or wagon's) automatic targeting switch (2.0's LuaEntity
-- artillery_auto_targeting, read true on world n's turret on 2.0.77) through configure {auto_targeting}; the artillery
-- targeting remote (a capsule whose action is artillery-remote, flare artillery-flare; the shortcut gives it once the
-- artillery technology is researched) through use_item at a position, as an artillery-flare there; and a read of each
-- artillery piece with the enemy spawners and worms in its range (charted chunks), nearest first. The range is the
-- cannon's (artillery-wagon-cannon: 224, minimum 32 on 2.0.77) times 1 + the force's artillery range bonus. On world n
-- a search over one turret's range took 1.4 ms (111 spawners and worms), so the read takes at most 8 pieces.
return function(api)
  local M = {}
  local TYPES = {'artillery-turret', 'artillery-wagon'}
  local INV = {['artillery-turret']='artillery_turret_ammo', ['artillery-wagon']='artillery_wagon_ammo'}
  local MAX, SHOW = 8, 3
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function r1(x) return math.floor(x * 10 + 0.5) / 10 end
  local function dist(a, b) return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2) end
  local function chunk(pos) return {x=math.floor(pos.x / 32), y=math.floor(pos.y / 32)} end
  -- The cannon's range and minimum range for an artillery piece, the force's range bonus counted.
  function M.range(e)
    local proto = try(function() return e.prototype end)
    local gun
    for _, g in pairs(proto and try(function() return proto.guns end) or {}) do gun = g; break end
    local ap = gun and try(function() return gun.attack_parameters end) or {}
    local bonus = try(function() return e.force.artillery_range_modifier end) or 0
    return (ap.range or 224) * (1 + bonus), ap.min_range or 0
  end
  local function shells(e)
    local inv = try(function() return e.get_inventory(defines.inventory[INV[e.type]]) end)
    local n, names = 0, {}
    for _, r in ipairs(inv and try(function() return inv.get_contents() end) or {}) do n = n + r.count; names[#names+1] = r.name .. '*' .. r.count end
    return n, table.concat(names, ', ')
  end
  -- Enemy spawners and worms in range of pos (charted chunks), nearest first: rows (up to SHOW) and the count.
  function M.targets(surface, force, pos, range, min_range)
    local list = {}
    for _, t in ipairs(try(function() return surface.find_entities_filtered{position=pos, radius=range, force='enemy', type={'unit-spawner', 'turret'}} end) or {}) do
      local d = dist(t.position, pos)
      if d >= min_range and (try(function() return force.is_chunk_charted(surface, chunk(t.position)) end) ~= false) then
        list[#list+1] = {name=t.name, position={x=t.position.x, y=t.position.y}, distance=r1(d)}
      end
    end
    table.sort(list, function(a, b) return a.distance < b.distance end)
    local rows = {}
    for i = 1, math.min(SHOW, #list) do rows[i] = list[i] end
    return rows, #list
  end
  function M.row(e)
    local range, min_range = M.range(e)
    local n, held = shells(e)
    local auto = try(function() return e.artillery_auto_targeting end)
    local near, count = M.targets(e.surface, e.force, e.position, range, min_range)
    local first = near[1]
    local line = string.format('%s (%g,%g): %s; automatic targeting %s; range %g (minimum %g); %d enemy spawners and worms in range%s',
      e.name, e.position.x, e.position.y, n > 0 and (n .. ' shells') or 'no shells', auto == nil and 'unknown' or (auto and 'on' or 'off'),
      r1(range), min_range, count, first and string.format(', the nearest %s (%g,%g) %g tiles away', first.name, first.position.x, first.position.y, first.distance) or '')
    return {name=e.name, position={x=e.position.x, y=e.position.y}, shells=n, held=held ~= '' and held or nil, auto_targeting=auto,
      range=r1(range), min_range=min_range, in_range=count, nearest=near, line=line}
  end
  -- artillery {position?, radius?, surface?}: our artillery pieces, nearest the centre first, at most MAX.
  function M.read(p, a)
    local surface = p.surface
    if a.surface ~= nil then
      assert(type(a.surface) == 'string', 'surface is a planet name')
      surface = game.get_surface(a.surface)
      assert(surface, 'unknown surface ' .. a.surface)
    end
    local centre = a.position and api.position(a.position) or (surface == p.surface and p.position) or {x=0, y=0}
    assert(a.radius == nil or (type(a.radius) == 'number' and a.radius > 0 and a.radius <= 4096), 'radius is 1..4096 tiles')
    local f = {type=TYPES, force=p.force}
    if a.radius then f.position, f.radius = centre, a.radius end
    local all = try(function() return surface.find_entities_filtered(f) end) or {}
    table.sort(all, function(x, y) return dist(x.position, centre) < dist(y.position, centre) end)
    local rows, lines = {}, {}
    for i = 1, math.min(MAX, #all) do
      local row = M.row(all[i])
      rows[#rows+1], lines[#lines+1] = row, row.line
    end
    return {surface=surface.name, artillery=rows, count=#all, more=#all > MAX and (#all - MAX) or nil, lines=lines,
      note=#all == 0 and 'no artillery of ours on ' .. surface.name .. (a.radius and ' within ' .. a.radius .. ' tiles' or '') or
        'with automatic targeting on, a piece with shells fires at enemy spawners and worms in its range by itself; the game does not say which it picks next'}
  end
  -- configure {position, auto_targeting}: the GUI's automatic targeting switch, read back.
  function M.configure(e, v)
    local t = e.type == 'entity-ghost' and e.ghost_type or e.type
    local name = e.type == 'entity-ghost' and e.ghost_name or e.name
    if t ~= 'artillery-turret' and t ~= 'artillery-wagon' then
      error(string.format('auto_targeting is an artillery turret\'s or wagon\'s switch; %s (%g,%g) is a %s', name, e.position.x, e.position.y, tostring(t)), 0)
    end
    if type(v) ~= 'boolean' then error('auto_targeting must be true or false', 0) end
    local before = try(function() return e.artillery_auto_targeting end)
    local ok, err = pcall(function() e.artillery_auto_targeting = v end)
    if not ok then error('the game refused automatic targeting: ' .. tostring(err), 0) end
    if e.type == 'entity-ghost' then
      return {name=name, position={x=e.position.x, y=e.position.y}, ghost=true, auto_targeting=try(function() return e.artillery_auto_targeting end), auto_targeting_before=before}
    end
    local out = M.row(e)
    out.auto_targeting_before = before
    return out
  end
  -- use_item {item: artillery-targeting-remote, position}: an artillery flare there, as the remote makes one; our
  -- pieces with shells that reach it fire at it.
  function M.remote(p, a, ca)
    assert(a.position ~= nil, 'position is required: where the artillery should fire')
    local pos = api.position(a.position)
    local held = api.held(p, a.item, a.quality or 'normal') or 0
    local tech = try(function() return p.force.technologies['artillery'].researched end)
    assert(held > 0 or tech, 'no ' .. a.item .. ' held, and the artillery technology (whose shortcut gives one) is not researched')
    assert(try(function() return p.force.is_chunk_charted(p.surface, chunk(pos)) end) ~= false,
      string.format('(%g,%g) is in a chunk our map has not charted; the remote marks charted ground', pos.x, pos.y))
    local flare = ca.flare or 'artillery-flare'
    local made
    for _, spec in ipairs({{name=flare, position=pos, force=p.force, movement={0, 0}, height=0, vertical_speed=0, frame_speed=1},
        {name=flare, position=pos, force=p.force}}) do
      made = try(function() return p.surface.create_entity(spec) end)
      if made then break end
    end
    assert(made, 'the game did not create ' .. flare .. ' at (' .. pos.x .. ',' .. pos.y .. ')')
    local reach, out_of_reach, empty = {}, 0, {}
    for _, e in ipairs(try(function() return p.surface.find_entities_filtered{type=TYPES, force=p.force} end) or {}) do
      local range, min_range = M.range(e)
      local d = dist(e.position, pos)
      if d <= range and d >= min_range then
        local n = shells(e)
        if n > 0 then reach[#reach+1] = string.format('%s (%g,%g) %g tiles, %d shells', e.name, e.position.x, e.position.y, r1(d), n)
        else empty[#empty+1] = string.format('%s (%g,%g)', e.name, e.position.x, e.position.y) end
      else out_of_reach = out_of_reach + 1 end
    end
    return {used=a.item, kind='artillery_remote', target=pos, flare=flare, by=held > 0 and 'held' or 'shortcut (artillery researched)',
      in_range=reach, in_range_no_shells=#empty > 0 and empty or nil, out_of_range=out_of_reach,
      line=string.format('flare at (%g,%g); %s', pos.x, pos.y, #reach > 0 and ('in range with shells: ' .. table.concat(reach, '; '))
        or 'no artillery of ours with shells reaches it' .. (#empty > 0 and (' (in range, no shells: ' .. table.concat(empty, ', ') .. ')') or ''))}
  end
  M.schema = {artillery = {position='optional {x,y}: the centre (default you)', radius='optional 1..4096 tiles round the centre (default the whole surface)',
    surface='optional planet name (default yours)',
    returns='artillery [{name, position, shells, held, auto_targeting, range, min_range (the cannon\'s, with the force\'s range bonus), in_range (enemy spawners and worms in its range on charted chunks), nearest (the 3 nearest: name, position, distance), line}], nearest the centre first, at most 8 (more: how many past them); count; lines; read only. Switch automatic targeting with configure {position, auto_targeting: false}; fire at one spot with use_item {item: "artillery-targeting-remote", position}'}}
  return M
end
