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
  -- (d20 batch60 V4, viewer Aurora) how far a flare reaches: the automatic range (with the force's bonus) times the
  -- prototype's manual_range_modifier. On the private copy (2.0.77; 224, minimum 32, modifier 2.5) a turret with
  -- automatic targeting off fired at script flares at 299.5 and 559 tiles and not at 561 (bonus 0); a force with +30%
  -- fired at 726 and not at 730 (728); at 34 and not at 20 (the minimum holds for a flare too).
  function M.manual(e, range)
    return (range or M.range(e)) * (try(function() return e.prototype.manual_range_modifier end) or 1)
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
    local P = defines.flow_precision_index or {}
    local function used(pi) return st and pi and math.floor((try(function() return st.get_flow_count{name='artillery-shell', category='output', precision_index=pi, count=true} end) or 0) + 0.5) or 0 end
    local m1, m10 = used(P.one_minute), used(P.ten_minutes)
    return string.format('artillery shells used on %s: %d in the last minute, %d in the last 10 minutes (the production statistics: a shot counts even when an inserter refills the piece)', surface.name, m1, m10), m1, m10
  end
  function M.row(e)
    local range, min_range = M.range(e)
    local manual = M.manual(e, range)
    local n, held = shells(e)
    local auto = try(function() return e.artillery_auto_targeting end)
    local near, count = M.targets(e.surface, e.force, e.position, range, min_range)
    local first = near[1]
    local line = string.format('%s (%g,%g): %s; automatic targeting %s; range %g (minimum %g), a flare within %g; %d enemy spawners and worms in range%s',
      e.name, e.position.x, e.position.y, n > 0 and (n .. ' shells') or 'no shells', auto == nil and 'unknown' or (auto and 'on' or 'off'),
      r1(range), min_range, r1(manual), count, first and string.format(', the nearest %s (%g,%g) %g tiles away', first.name, first.position.x, first.position.y, first.distance) or '')
    local units = try(function() return M.units_near(e) end)
    if units then line = line .. '; ' .. units.line .. ': ' .. table.concat(units.rows, '; ') end
    local fed = M.fed_by(e)
    if fed then line = line .. '; refilled by ' .. table.concat(fed, ', ') end
    return {name=e.name, position={x=e.position.x, y=e.position.y}, shells=n, held=held ~= '' and held or nil, auto_targeting=auto,
      range=r1(range), min_range=min_range, manual_range=r1(manual), in_range=count, nearest=near, units_near=units, fed_by=fed, line=line}
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
    -- (d19 batch44 A2) with no radius, the census pass's artillery when it has it (a whole-surface find: about 10.5 ms
    -- on the private copy's Nauvis)
    local all = not a.radius and api.census_typed and try(function() return api.census_typed(p.force, surface, TYPES) end)
    if not all then all = try(function() return surface.find_entities_filtered(f) end) or {} end
    table.sort(all, function(x, y) return dist(x.position, centre) < dist(y.position, centre) end)
    local rows, lines = {}, {}
    for i = 1, math.min(MAX, #all) do
      local row = M.row(all[i])
      rows[#rows+1], lines[#lines+1] = row, row.line
    end
    local used = #all > 0 and M.shells_used(surface, p.force) or nil
    -- (C1) with position: what is already coming at it (an immediate re-read after a flare)
    local coming = a.position and try(function() return M.incoming(surface, p.force, centre) end)
    return {surface=surface.name, artillery=rows, count=#all, more=#all > MAX and (#all - MAX) or nil, lines=lines, shells_used=used,
      already_coming=coming and coming.line or nil,
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
  -- (d19 batch45, batch40 C1, Muse: about 6 times a second flare on a guarded spawner while shells were in the air)
  -- what is already coming at pos, as a player sees it: our flares still waiting within FLARE_NEAR (each holds shots
  -- not yet taken), artillery projectiles in the air within AIR_NEAR, and the team's flares within FLARE_NEAR in the last
  -- RECENT ticks with the watched pieces that hold fewer shells since. A projectile names no target in 2.0.77 (read on
  -- the private copy: no target or source, orientation 0 whatever its heading).
  local FLARE_NEAR, AIR_NEAR, RECENT = 32, 64, 3600
  function M.incoming(surface, force, pos)
    local flares = try(function() return surface.find_entities_filtered{name={'artillery-flare'}, position=pos, radius=FLARE_NEAR, force=force} end) or {}
    local air = try(function() return surface.find_entities_filtered{type='artillery-projectile', position=pos, radius=AIR_NEAR} end) or {}
    local recent, fired, seen = {}, {}, {}
    for _, c in ipairs(api.state and api.state().artillery_checks or {}) do
      if c.surface == surface.index and game.tick - c.tick <= RECENT and dist(c.target, pos) <= FLARE_NEAR then
        local taken = not (c.flare and try(function() return c.flare.valid end))
        recent[#recent+1] = string.format('(%g,%g) %ds ago by %s, %s', c.target.x, c.target.y, math.floor((game.tick - c.tick) / 60), tostring(c.by or '?'),
          taken and 'taken' or 'still waiting')
        for _, w in ipairs(c.pieces or {}) do
          local now = w.e.valid and shells(w.e) or nil
          local key = w.e.valid and w.e.unit_number
          if now and now < w.n and not seen[key] then seen[key] = true; fired[#fired+1] = string.format('%s (%g,%g) %d -> %d shells', w.e.name, w.e.position.x, w.e.position.y, w.n, now) end
        end
      end
    end
    local parts = {string.format('%d flare%s of ours still waiting within %d tiles', #flares, #flares == 1 and '' or 's', FLARE_NEAR),
      string.format('%d artillery projectile%s in the air within %d tiles', #air, #air == 1 and '' or 's', AIR_NEAR)}
    if #recent > 0 then parts[#parts+1] = string.format('team flares there in the last %ds: %s', RECENT / 60, table.concat(recent, '; ', 1, math.min(4, #recent))) end
    if #fired > 0 then parts[#parts+1] = 'pieces holding fewer shells since: ' .. table.concat(fired, ', ', 1, math.min(6, #fired)) end
    return {flares_waiting=#flares, in_the_air=#air, recent_flares=#recent > 0 and recent or nil, fired_since=#fired > 0 and fired or nil,
      line='already coming at (' .. pos.x .. ',' .. pos.y .. '): ' .. table.concat(parts, '; ')}
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
    -- (C1) what was already coming there, read before this flare
    local coming = try(function() return M.incoming(p.surface, p.force, pos) end)
    local made
    for _, spec in ipairs({{name=flare, position=pos, force=p.force, movement={0, 0}, height=0, vertical_speed=0, frame_speed=1},
        {name=flare, position=pos, force=p.force}}) do
      made = try(function() return p.surface.create_entity(spec) end)
      if made then break end
    end
    assert(made, 'the game did not create ' .. flare .. ' at (' .. pos.x .. ',' .. pos.y .. ')')
    -- (d18 batch37 C2, viewer Aurora 16:57) a flare is a manual target: a piece fires at it within its manual range (its
    -- prototype's manual_range_modifier times its automatic range); each piece in reach says which range holds it
    local reach, out_of_reach, empty, watch, miss = {}, 0, {}, {}, nil
    local pieces = api.census_typed and try(function() return api.census_typed(p.force, p.surface, TYPES) end)
    for _, e in ipairs(pieces or try(function() return p.surface.find_entities_filtered{type=TYPES, force=p.force} end) or {}) do
      local range, min_range = M.range(e)
      local manual = M.manual(e, range)
      local d = dist(e.position, pos)
      if d <= manual and d >= min_range then
        local n = shells(e)
        local fed = n > 0 and M.fed_by(e)
        local which = d <= range and 'in its automatic range too' or string.format('in its manual range only (%g; automatic %g)', r1(manual), r1(range))
        if n > 0 then
          reach[#reach+1] = string.format('%s (%g,%g) %g tiles, %s, %d shells%s', e.name, e.position.x, e.position.y, r1(d), which, n,
            fed and ' (refilled by ' .. table.concat(fed, ', ') .. ': a shot fired leaves its count as it is; shells_used counts it)' or '')
          if #watch < 16 then watch[#watch+1] = {e=e, n=n} end
        else empty[#empty+1] = string.format('%s (%g,%g)', e.name, e.position.x, e.position.y) end
      else
        out_of_reach = out_of_reach + 1
        -- the loaded piece nearest to reaching it, and why it does not
        local short = d < min_range and min_range - d or d - manual
        if shells(e) > 0 and (not miss or short < miss.short) then
          miss = {short=short, line=string.format('%s (%g,%g) %g tiles away, %s', e.name, e.position.x, e.position.y, r1(d),
            d < min_range and string.format('inside its minimum range %g', min_range) or string.format('past its manual range %g (automatic %g)', r1(manual), r1(range)))}
        end
      end
    end
    local used_line, m1, m10 = M.shells_used(p.surface, p.force)
    -- the shot confirmed (or not) CONFIRM ticks later, to the caller
    if api.state then
      local st = api.state()
      st.artillery_checks = st.artillery_checks or {}
      st.artillery_checks[#st.artillery_checks+1] = {index=p.index, by=api.who and try(function() return api.who(p) end) or p.name, force=p.force, flare=made, target=pos, surface=p.surface.index, tick=game.tick, pieces=watch, m10=m10}
    end
    return {used=a.item, kind='artillery_remote', target=pos, flare=flare, by=held > 0 and 'held' or 'shortcut (artillery researched)',
      shells_used=used_line .. '; read artillery again after the shot to see it counted',
      already_coming=coming and coming.line or nil,
      in_range=reach, in_range_no_shells=#empty > 0 and empty or nil, out_of_range=out_of_reach, nearest_out_of_range=miss and miss.line or nil,
      confirm=string.format('in %d s your team block says whether a shot followed: the flare taken, shells gone from these pieces, projectiles seen', M.CONFIRM / 60),
      line=string.format('flare at (%g,%g); %s', pos.x, pos.y, #reach > 0 and ('in range with shells: ' .. table.concat(reach, '; '))
        or 'no artillery of ours with shells reaches it' .. (miss and ' (the nearest: ' .. miss.line .. ')' or '') .. (#empty > 0 and (' (in range, no shells: ' .. table.concat(empty, ', ') .. ')') or ''))}
  end
  -- (C2) CONFIRM ticks after a flare: whether a shot followed, told to whoever placed it.
  M.CONFIRM = 600
  function M.tick()
    local st = api.state()
    local list = st.artillery_checks
    if not list then return end
    local keep = {}
    for _, c in ipairs(list) do
      if game.tick - c.tick < M.CONFIRM then keep[#keep+1] = c
      else
        local fired = {}
        for _, w in ipairs(c.pieces) do
          local now = w.e.valid and shells(w.e) or nil
          if now and now < w.n then fired[#fired+1] = string.format('%s (%g,%g) %d -> %d shells', w.e.name, w.e.position.x, w.e.position.y, w.n, now) end
        end
        local s = game.surfaces[c.surface]
        local flying = s and #(try(function() return s.find_entities_filtered{type='artillery-projectile', position=c.target, radius=64} end) or {}) or 0
        local taken = not (c.flare and try(function() return c.flare.valid end))
        local _, _, m10 = nil, nil, nil
        if s and c.force and c.force.valid then _, _, m10 = M.shells_used(s, c.force) end
        local line = string.format('artillery flare at (%g,%g), %d s on: %s; %s; %d projectile%s in the air within 64 tiles of it%s', c.target.x, c.target.y, math.floor(M.CONFIRM / 60),
          taken and 'the flare is gone (its shots were taken)' or 'the flare is still there (no piece has taken its shots)',
          #fired > 0 and 'shells gone from ' .. table.concat(fired, ', ') or 'no watched piece holds fewer shells (an inserter may have refilled it)',
          flying, flying == 1 and '' or 's', (m10 and c.m10 and m10 > c.m10) and string.format('; shells used on the surface in the last 10 min: %d (was %d)', m10, c.m10) or '')
        if api.deliver then pcall(api.deliver, c.index, {seq='artillery', tick=game.tick, from='artillery', text=line}) end
      end
    end
    st.artillery_checks = #keep > 0 and keep or nil
  end
  M.schema = {artillery = {position='optional {x,y}: the centre (default you)', radius='optional 1..4096 tiles round the centre (default the whole surface)',
    surface='optional planet name (default yours)',
    returns='artillery [{name, position, shells, held, auto_targeting, range, min_range (the cannon\'s, with the force\'s range bonus), manual_range (how far a flare reaches: range x the prototype\'s manual_range_modifier, 560 at no bonus; the minimum holds for it too), in_range (enemy spawners and worms in its range on charted chunks), nearest (the 3 nearest: name, position, distance), units_near (enemy units within 64 tiles our force sees now: count, by_name, rows for the 5 nearest: distance, its attack range and how far outside it the piece stands, how many of our turrets reach it), line}], nearest the centre first, at most 8 (more: how many past them); count; lines; already_coming (with position, as a flare\'s reply: our flares still waiting within 32 tiles, artillery projectiles in the air within 64 tiles, the team\'s flares there in the last 60 s and the pieces holding fewer shells since); read only. Switch automatic targeting with configure {position, auto_targeting: false}; fire at one spot with use_item {item: "artillery-targeting-remote", position}'}}
  return M
end
