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
  -- Enemy units near a piece (Grok, shift19 15:34: a turret lost to biters that came after the artillery woke a nest):
  -- the units within NEAR tiles that our force sees now, each with its distance, its attack range, how far outside
  -- that range the piece stands, and how many of our turrets reach it. At most UNITS units read and SHOW_UNITS
  -- shown, nearest first.
  local NEAR, UNITS, SHOW_UNITS, TURRETS = 64, 200, 5, 200
  local TURRET_TYPES = {'ammo-turret', 'electric-turret', 'fluid-turret'}
  local unit_range = {}
  local function attack_range(name)
    if unit_range[name] == nil then
      unit_range[name] = try(function() return prototypes.entity[name].attack_parameters.range end) or false
    end
    return unit_range[name] or nil
  end
  local turret_range = {}
  local function reach_of(t)
    local name = t.name
    if turret_range[name] == nil then
      turret_range[name] = try(function() return t.prototype.attack_parameters.range end) or try(function() return t.prototype.turret_range end) or false
    end
    return turret_range[name] or nil
  end
  function M.units_near(e)
    local surface, force = e.surface, e.force
    local found = try(function() return surface.find_entities_filtered{position=e.position, radius=NEAR, type='unit', force='enemy', limit=UNITS} end) or {}
    local list = {}
    for _, u in ipairs(found) do
      if u.valid and try(function() return force.is_chunk_visible(surface, chunk(u.position)) end) ~= false then
        list[#list+1] = {u=u, d=dist(u.position, e.position)}
      end
    end
    if #list == 0 then return nil end
    table.sort(list, function(a, b) return a.d < b.d end)
    local turrets = try(function() return surface.find_entities_filtered{position=e.position, radius=NEAR + 40, type=TURRET_TYPES, force=force, limit=TURRETS} end) or {}
    local by, order = {}, {}
    for _, x in ipairs(list) do
      if not by[x.u.name] then by[x.u.name] = 0; order[#order+1] = x.u.name end
      by[x.u.name] = by[x.u.name] + 1
    end
    local counts = {}
    for _, n in ipairs(order) do counts[#counts+1] = by[n] .. ' ' .. n end
    local rows = {}
    for i = 1, math.min(SHOW_UNITS, #list) do
      local u, d = list[i].u, list[i].d
      local range = attack_range(u.name)
      local cover = 0
      for _, t in ipairs(turrets) do
        local r = t.valid and reach_of(t)
        if r and dist(t.position, u.position) <= r then cover = cover + 1 end
      end
      rows[i] = string.format('%s (%g,%g) %g tiles away%s; %s', u.name, r1(u.position.x), r1(u.position.y), r1(d),
        range and (d <= range and string.format(', its range %g reaches the piece', range) or string.format(', its range %g (%g outside it)', range, r1(d - range))) or '',
        cover > 0 and string.format('%d turret%s of ours reach%s it', cover, cover == 1 and '' or 's', cover == 1 and 'es' or '') or 'no turret of ours reaches it')
    end
    return {count=#list, by_name=table.concat(counts, ', '), rows=rows, capped=#found >= UNITS or nil,
      line=string.format('%d enemy unit%s within %d tiles (%s)%s', #list, #list == 1 and '' or 's', NEAR, table.concat(counts, ', '), #found >= UNITS and ', the first ' .. UNITS .. ' read' or '')}
  end
  -- The inserters that drop into a piece (A6, Haiku 18:49: its count stayed at 5 after a remote shot because an
  -- inserter refilled it from a requester chest asking for 5; on world n the shot had fired and the worm was gone).
  function M.fed_by(e)
    local b = e.bounding_box
    local list = {}
    for _, i in ipairs(try(function() return e.surface.find_entities_filtered{type='inserter', force=e.force,
        area={{b.left_top.x - 3, b.left_top.y - 3}, {b.right_bottom.x + 3, b.right_bottom.y + 3}}} end) or {}) do
      if try(function() return i.drop_target end) == e then
        local src = try(function() return i.pickup_target end)
        list[#list+1] = string.format('%s (%g,%g) from %s', i.name, i.position.x, i.position.y,
          src and src.valid and string.format('%s (%g,%g)', src.name, src.position.x, src.position.y) or 'nothing')
      end
    end
    return #list > 0 and list or nil
  end
  -- Artillery shells the force used on a surface (its production statistics, as the production GUI shows): the last
  -- minute and the last 10 minutes; a fired shell counts there even when an inserter puts another in the piece.
  function M.shells_used(surface, force)
    local st = try(function() return force.get_item_production_statistics(surface) end)
    local P = defines.flow_precision_index
    local function used(pi) return st and pi and math.floor((try(function() return st.get_flow_count{name='artillery-shell', category='output', precision_index=pi, count=true} end) or 0) + 0.5) or 0 end
    local m1, m10 = used(P.one_minute), used(P.ten_minutes)
    return string.format('artillery shells used on %s: %d in the last minute, %d in the last 10 minutes (the production statistics: a shot counts even when an inserter refills the piece)', surface.name, m1, m10), m1, m10
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
    local units = try(function() return M.units_near(e) end)
    if units then line = line .. '; ' .. units.line .. ': ' .. table.concat(units.rows, '; ') end
    local fed = M.fed_by(e)
    if fed then line = line .. '; refilled by ' .. table.concat(fed, ', ') end
    return {name=e.name, position={x=e.position.x, y=e.position.y}, shells=n, held=held ~= '' and held or nil, auto_targeting=auto,
      range=r1(range), min_range=min_range, in_range=count, nearest=near, units_near=units, fed_by=fed, line=line}
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
    local used = #all > 0 and M.shells_used(surface, p.force) or nil
    return {surface=surface.name, artillery=rows, count=#all, more=#all > MAX and (#all - MAX) or nil, lines=lines, shells_used=used,
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
        local fed = n > 0 and M.fed_by(e)
        if n > 0 then reach[#reach+1] = string.format('%s (%g,%g) %g tiles, %d shells%s', e.name, e.position.x, e.position.y, r1(d), n,
          fed and ' (refilled by ' .. table.concat(fed, ', ') .. ': a shot fired leaves its count as it is; shells_used counts it)' or '')
        else empty[#empty+1] = string.format('%s (%g,%g)', e.name, e.position.x, e.position.y) end
      else out_of_reach = out_of_reach + 1 end
    end
    local used_line = M.shells_used(p.surface, p.force)
    return {used=a.item, kind='artillery_remote', target=pos, flare=flare, by=held > 0 and 'held' or 'shortcut (artillery researched)',
      shells_used=used_line .. '; read artillery again after the shot to see it counted',
      in_range=reach, in_range_no_shells=#empty > 0 and empty or nil, out_of_range=out_of_reach,
      line=string.format('flare at (%g,%g); %s', pos.x, pos.y, #reach > 0 and ('in range with shells: ' .. table.concat(reach, '; '))
        or 'no artillery of ours with shells reaches it' .. (#empty > 0 and (' (in range, no shells: ' .. table.concat(empty, ', ') .. ')') or ''))}
  end
  M.schema = {artillery = {position='optional {x,y}: the centre (default you)', radius='optional 1..4096 tiles round the centre (default the whole surface)',
    surface='optional planet name (default yours)',
    returns='artillery [{name, position, shells, held, auto_targeting, range, min_range (the cannon\'s, with the force\'s range bonus), in_range (enemy spawners and worms in its range on charted chunks), nearest (the 3 nearest: name, position, distance), units_near (enemy units within 64 tiles our force sees now: count, by_name, rows for the 5 nearest: distance, its attack range and how far outside it the piece stands, how many of our turrets reach it), line}], nearest the centre first, at most 8 (more: how many past them); count; lines; read only. Switch automatic targeting with configure {position, auto_targeting: false}; fire at one spot with use_item {item: "artillery-targeting-remote", position}'}}
  return M
end
