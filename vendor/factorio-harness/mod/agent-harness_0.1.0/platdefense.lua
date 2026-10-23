-- platform_defense {platform} (A4, Astra 01:50: four collectors lost last shift): a platform's turret cover.
-- - each asteroid collector's front (the middle of its collection area, its tile rule that keeps empty space): the
--   turrets whose range reaches it, each with its ammo and what feeds it (an inserter and what it takes from, robots
--   bringing ammo, or nothing: by hand); uncovered, the nearest turret and how far past its range;
-- - each side of the hull (foundation tiles with empty space beside them, by the side the space is on): how many edge
--   tiles no turret reaches, as runs (gaps), the longest first;
-- - the turrets: ammo, feed, and those empty.
-- A turret's reach is its prototype's attack range from its centre, past its minimum range. (d17 batch23 A1, Sol:
-- Swiftlet's small-asteroid cover was counted from rocket turrets that engage only big ones.) Cover is given per
-- asteroid size: in 2.0.77 every turret, asteroid and ammo prototype has the same target mask (common) and no ammo a
-- target filter, so what a turret engages is its own priority list (the turret GUI's): with ignore unprioritised
-- targets on, only the asteroids listed; off, all of them. A size is covered where, for every asteroid type of that
-- size (metallic, carbonic, oxide; promethium too when a turret here lists one), a turret that engages it reaches.
-- (d20 batch56 R5, Sol #1409: a railgun facing east read as covering a collector north of it, outside its arc) a turret
-- whose base has a direction aims only within its attack_parameters' turn_range (a share of a full turn: railgun-turret
-- 0.2, 72 degrees) centred on its facing (fireline.lua reads the same rule): it reaches a point inside that arc only.
-- Read only; bounded: 40000 foundation tiles, 256 turrets.
return function(api)
  local M = {}
  local MAX_TILES, MAX_TURRETS, GAPS = 40000, 256, 8
  local TURRETS = {'ammo-turret', 'electric-turret', 'fluid-turret'}
  local SIDES = {{0, -1, 'north'}, {1, 0, 'east'}, {0, 1, 'south'}, {-1, 0, 'west'}}
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function at(q) return string.format('(%g,%g)', math.floor(q.x * 10 + 0.5) / 10, math.floor(q.y * 10 + 0.5) / 10) end
  local function key(x, y) return (x + 32768) * 65536 + (y + 32768) end
  local function dist(a, b) return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2) end
  local SIZES = {'small', 'medium', 'big', 'huge'}
  local KINDS = {'metallic', 'carbonic', 'oxide', 'promethium'}
  -- what a turret engages: nil for every asteroid, else the set of names on its priority list
  local function engages(t)
    if try(function() return t.ignore_unprioritised_targets end) ~= true then return nil end
    local set = {}
    for i = 1, 64 do
      local v = try(function() return t.get_priority_target(i) end)
      if not v then break end
      set[v.name] = true
    end
    return set
  end
  local function rotate(x, y, dir) for _ = 1, math.floor(((dir or 0) % 16) / 4) do x, y = -y, x end return x, y end
  local COMPASS = {[0]='north', [2]='northeast', [4]='east', [6]='southeast', [8]='south', [10]='southwest', [12]='west', [14]='northwest'}
  local atan2 = math.atan2 or math.atan
  local function wrap(x)
    while x > math.pi do x = x - 2 * math.pi end
    while x < -math.pi do x = x + 2 * math.pi end
    return x
  end
  -- degrees a point lies outside a turret's arc (bearing from north, clockwise), or nil inside it or for a turret
  -- that aims all round
  local function off_arc(t, x, y)
    if not t.half then return nil end
    local dx, dy = x - t.position.x, y - t.position.y
    if dx == 0 and dy == 0 then return nil end
    local o = math.abs(wrap(atan2(dx, -dy) - t.face)) - t.half
    return o > 1e-6 and o * 180 / math.pi or nil
  end
  local function reaches(t, x, y)
    local d = math.sqrt((t.position.x - x) ^ 2 + (t.position.y - y) ^ 2)
    return d <= t.range and d >= t.min_range and not off_arc(t, x, y)
  end
  -- what a turret holds and what feeds it
  local function turret_info(s, force, t)
    local inv = try(function() return t.get_inventory(defines.inventory.turret_ammo) end)
    local held, rounds = {}, 0
    for _, c in ipairs(inv and try(function() return inv.get_contents() end) or {}) do held[#held+1] = c.name .. '*' .. c.count; rounds = rounds + c.count end
    local ammo = t.type == 'ammo-turret' and (#held > 0 and table.concat(held, ' ') or 'no ammo')
      or t.type == 'electric-turret' and 'electric' or 'fluid'
    local feed
    if t.type == 'ammo-turret' then
      local b = t.bounding_box
      for _, ins in ipairs(try(function() return s.find_entities_filtered{area={{b.left_top.x - 3, b.left_top.y - 3}, {b.right_bottom.x + 3, b.right_bottom.y + 3}}, type='inserter', force=force} end) or {}) do
        if not feed and try(function() return ins.drop_target end) == t then
          local src = try(function() return ins.pickup_target end)
          feed = string.format('%s %s from %s', ins.name, at(ins.position), src and src.valid and (src.name .. ' ' .. at(src.position)) or 'nothing')
        end
      end
      if not feed then
        local proxy = try(function() local x = t.item_request_proxy; return x and x.valid and x end)
        if proxy then feed = 'robots bringing ammo' end
      end
    end
    -- (d19 batch46, viewer Aurora 15:50) armed now: an ammo turret holding ammo, an electric turret with energy, a fluid
    -- turret with fluid; cover is read by reach and again by the armed turrets only
    local armed
    if t.type == 'ammo-turret' then armed = rounds > 0
    elseif t.type == 'electric-turret' then armed = (try(function() return t.energy end) or 0) > 0
    else armed = (try(function() local fb = t.fluidbox[1]; return fb and fb.amount end) or 0) > 0 end
    local only = engages(t)
    -- its arc (turn_range under a full turn): facing and half the arc in radians
    local turn = try(function() return t.prototype.attack_parameters.turn_range end) or 1
    local dir = try(function() return t.direction end) or 0
    local face, half, arc
    if turn < 1 then
      face, half = dir / 16 * 2 * math.pi, turn * math.pi
      arc = string.format('aims within %g degrees centred %s', math.floor(turn * 3600 + 0.5) / 10, COMPASS[dir] or (dir .. '/16 of a turn'))
    end
    local listed = {}
    for name in pairs(only or {}) do listed[#listed+1] = name end
    table.sort(listed)
    return {entity=t, name=t.name, type=t.type, position=t.position, face=face, half=half, arc=arc, facing=arc and (COMPASS[dir] or dir) or nil,
      arc_degrees=arc and math.floor(turn * 3600 + 0.5) / 10 or nil, range=try(function() return t.prototype.attack_parameters.range end) or 0,
      min_range=try(function() return t.prototype.attack_parameters.min_range end) or 0, only=only,
      engages=only and (#listed > 0 and 'only ' .. table.concat(listed, ', ') .. ' (ignores the rest)' or 'nothing (ignores every target off its empty priority list)') or 'every asteroid',
      ammo=ammo, empty=t.type == 'ammo-turret' and rounds == 0, armed=armed,
      unarmed=not armed and (t.type == 'ammo-turret' and 'no ammo' or t.type == 'electric-turret' and 'no energy' or 'no fluid') or nil, feed=feed or (t.type == 'ammo-turret' and 'nothing (by hand)' or t.type == 'electric-turret' and 'power' or 'pipe')}
  end
  -- (d21 batch72 AH2, Astra #1741) a turret ghost of ours: its prototype's range, minimum range and arc by its facing, and
  -- the priority list the ghost carries; never armed (a ghost holds no ammunition and draws no power)
  local function ghost_info(g)
    local pr = g.ghost_prototype
    local ap = try(function() return pr.attack_parameters end) or {}
    local turn = ap.turn_range or 1
    local dir = try(function() return g.direction end) or 0
    local face, half, arc
    if turn < 1 then
      face, half = dir / 16 * 2 * math.pi, turn * math.pi
      arc = string.format('aims within %g degrees centred %s', math.floor(turn * 3600 + 0.5) / 10, COMPASS[dir] or (dir .. '/16 of a turn'))
    end
    local only = engages(g)
    local listed = {}
    for name in pairs(only or {}) do listed[#listed+1] = name end
    table.sort(listed)
    local t = g.ghost_type
    return {entity=g, ghost=true, name=g.ghost_name, type=t, position=g.position, face=face, half=half, arc=arc, facing=arc and (COMPASS[dir] or dir) or nil,
      arc_degrees=arc and math.floor(turn * 3600 + 0.5) / 10 or nil, range=ap.range or 0, min_range=ap.min_range or 0, only=only,
      engages=only and (#listed > 0 and 'only ' .. table.concat(listed, ', ') .. ' (ignores the rest)' or 'nothing (ignores every target off its empty priority list)') or 'every asteroid',
      armed=false, unarmed=t == 'ammo-turret' and 'a ghost: no ammunition' or t == 'electric-turret' and 'a ghost: no power' or 'a ghost: no fluid'}
  end
  -- a collector's front: the middle of its collection area (the tile rule that keeps empty space), turned by its facing
  local function front_of(proto, pos, dir)
    for _, rule in ipairs(try(function() return proto.tile_buildability_rules end) or {}) do
      local empty = false
      for l in pairs(rule.required_tiles and rule.required_tiles.layers or {}) do if l == 'empty_space' then empty = true end end
      if empty then
        local cx, cy = (rule.area.left_top.x + rule.area.right_bottom.x) / 2, (rule.area.left_top.y + rule.area.right_bottom.y) / 2
        local rx, ry = rotate(cx, cy, dir)
        return {x=pos.x + rx, y=pos.y + ry}
      end
    end
    return pos
  end
  -- the turrets whose range reaches q (past their minimum range, within their arc); outside: those whose range alone
  -- would reach it, with how far off their arc it lies
  local function covering(turrets, q)
    local list, nearest, nd, outside = {}, nil, nil, {}
    for _, t in ipairs(turrets) do
      local d = dist(t.position, q)
      if d <= t.range and d >= t.min_range then
        local off = off_arc(t, q.x, q.y)
        if off then outside[#outside+1] = {turret=t, off=off} else list[#list+1] = t end
      end
      local over = d - t.range
      if not nd or over < nd then nearest, nd = t, over end
    end
    return list, nearest, nd, outside
  end
  local function outside_words(outside)
    local w = {}
    for i, o in ipairs(outside) do
      if i <= 3 then w[i] = string.format('%s %s %s: %.0f degrees outside it', o.turret.name, at(o.turret.position), o.turret.arc, o.off) end
    end
    return table.concat(w, '; ') .. (#outside > 3 and string.format('; +%d more', #outside - 3) or '')
  end
  -- per size: covered when every kind of that size is engaged by one of list; else the kinds none engages. Tiles
  -- reached by the same turrets share one answer (memo, per read).
  local memo = {}
  local function by_size(list, kinds)
    local ids = {}
    -- (d21 batch72 AH2) each turret's id as text made once: a number turned into text costs about 8 µs in the game's Lua,
    -- and this ran for every edge tile (200 ms on a 15,357-tile hull)
    for i, t in ipairs(list) do local k = t.sid; if not k then k = string.format('%d', t.idx); t.sid = k end; ids[i] = k end
    local k = table.concat(ids, ',')
    if memo[k] then return memo[k] end
    local out = {}
    for _, size in ipairs(SIZES) do
      local hit, n, all = {}, 0, false
      for _, t in ipairs(list) do
        if not t.only then all = true; n = n + 1
        else
          local some = false
          for _, kind in ipairs(kinds) do if t.only[size .. '-' .. kind .. '-asteroid'] then hit[kind] = true; some = true end end
          if some then n = n + 1 end
        end
      end
      local missing = {}
      if not all then for _, kind in ipairs(kinds) do if not hit[kind] then missing[#missing+1] = kind end end end
      out[size] = {covered=#missing == 0 and #list > 0, turrets=n, missing=#missing > 0 and missing or nil}
    end
    memo[k] = out
    return out
  end
  -- (d21 batch72 AH2: the old read's hull sides as a function, for the planned hull too) each side of a hull (tiles {x,y}):
  -- per size the edge tiles no turret reaches as runs; with `second` (a subset of turrets), the tiles covered by turrets
  -- but not by that subset, as `field` (unarmed_only: by turrets not armed now; ghost_only: by turret ghosts only)
  -- the turrets by GRID-tile cell: each cell lists the turrets whose range reaches into it (a tile's cover tests only
  -- its cell's), with their squared range and minimum range
  local GRID = 16
  local function reach_grid(turrets)
    local grid = {}
    for _, t in ipairs(turrets) do
      t.r2, t.m2 = t.range * t.range, t.min_range * t.min_range
      local px, py, r = t.position.x, t.position.y, t.range + 1
      for gx = math.floor((px - r) / GRID), math.floor((px + r) / GRID) do
        for gy = math.floor((py - r) / GRID), math.floor((py + r) / GRID) do
          local k = key(gx, gy)
          local l = grid[k]
          if not l then l = {}; grid[k] = l end
          l[#l+1] = t
        end
      end
    end
    return grid
  end
  local NONE = {}
  -- the turrets that reach (x, y), and of them those `keep` keeps (nil: all)
  local function reach_list(grid, x, y, keep)
    local list, sub = {}, keep and {} or nil
    for _, t in ipairs(grid[key(math.floor(x / GRID), math.floor(y / GRID))] or NONE) do
      local dx, dy = t.position.x - x, t.position.y - y
      local d2 = dx * dx + dy * dy
      if d2 <= t.r2 and d2 >= t.m2 and not off_arc(t, x, y) then
        list[#list+1] = t
        if sub and keep(t) then sub[#sub+1] = t end
      end
    end
    return list, sub
  end
  -- An edge tile's cover as a number: bit BIT[size] when no turret engaging that size reaches it, bit BIT[size] * 16 when
  -- only turrets `keep` leaves out do (not armed now; ghosts)
  local BIT = {small=1, medium=2, big=4, huge=8}
  local function edge_mask(grid, x, y, keep, kinds)
    local list, sub = reach_list(grid, x + 0.5, y + 0.5, keep)
    local bs = by_size(list, kinds)
    local ba = sub and by_size(sub, kinds) or bs
    local m = 0
    for _, size in ipairs(SIZES) do
      if not bs[size].covered then m = m + BIT[size] elseif not ba[size].covered then m = m + BIT[size] * 16 end
    end
    return m
  end
  -- tile (x, y) of the hull `set` into `sides` ({name: {edge, list {x, y, m}}}) for each side with empty space beside it,
  -- its cover read once
  local function edge_tile(set, grid, x, y, keep, kinds, sides)
    local m
    for _, d in ipairs(SIDES) do
      if not set[key(x + d[1], y + d[2])] then
        m = m or edge_mask(grid, x, y, keep, kinds)
        local sd = sides[d[3]]
        if not sd then sd = {edge=0, list={}}; sides[d[3]] = sd end
        sd.edge = sd.edge + 1
        sd.list[sd.edge] = {x=x, y=y, m=m}
      end
    end
  end
  -- the sides' rows and lines: each side's tiles sorted once along it, then split by size in that order; runs of the
  -- uncovered ones, the longest first
  local function side_lines(sides, field, words_second, lines, prefix)
    local side_rows = {}
    for _, d in ipairs(SIDES) do
      local sd = sides[d[3]]
      if sd then
        -- runs of uncovered edge tiles: along x for north/south, along y for east/west
        local along = (d[3] == 'north' or d[3] == 'south')
        table.sort(sd.list, function(u, v)
          if along then if u.y ~= v.y then return u.y < v.y end return u.x < v.x end
          if u.x ~= v.x then return u.x < v.x end return u.y < v.y end)
        local open, size_open, size_second = {}, {small={}, medium={}, big={}, huge={}}, {small={}, medium={}, big={}, huge={}}
        for _, e in ipairs(sd.list) do
          local m = e.m
          if m % 16 ~= 0 then open[#open+1] = e end
          for _, size in ipairs(SIZES) do
            local bit = BIT[size]
            if math.floor(m / bit) % 2 == 1 then local o = size_open[size]; o[#o+1] = e
            elseif math.floor(m / (bit * 16)) % 2 == 1 then local o = size_second[size]; o[#o+1] = e end
          end
        end
        local function gaps_of(list, most)
          local runs = {}
          for _, t in ipairs(list) do
            local r = runs[#runs]
            if r and math.abs((along and t.x or t.y) - (along and r.x1 or r.y1)) <= 2 and math.abs((along and t.y or t.x) - (along and r.y1 or r.x1)) <= 2 then
              r.x1, r.y1, r.n = t.x, t.y, r.n + 1
            else runs[#runs+1] = {x0=t.x, y0=t.y, x1=t.x, y1=t.y, n=1} end
          end
          table.sort(runs, function(u, v) return u.n > v.n end)
          local gaps = {}
          for i, r in ipairs(runs) do if i <= most then gaps[i] = string.format('(%d,%d)-(%d,%d) %d tile%s', r.x0, r.y0, r.x1, r.y1, r.n, r.n == 1 and '' or 's') end end
          return gaps, #runs
        end
        local gaps = gaps_of(open, GAPS)
        local per, words = {}, {}
        for _, size in ipairs(SIZES) do
          local o = size_open[size]
          local g, n = gaps_of(o, 3)
          per[size] = {uncovered=#o, gaps=g}
          words[#words+1] = #o == 0 and size .. ' all covered' or string.format('%s %d uncovered (%s%s)', size, #o, table.concat(g, '; '), n > 3 and string.format('; +%d more runs', n - 3) or '')
          local u = size_second[size]
          if #u > 0 then
            local ug, un = gaps_of(u, 3)
            per[size][field], per[size][field:gsub('_only$', '') .. '_gaps'] = #u, ug
            words[#words] = words[#words] .. string.format(', %d %s (%s%s)', #u, words_second, table.concat(ug, '; '), un > 3 and string.format('; +%d more runs', un - 3) or '')
          end
        end
        side_rows[#side_rows+1] = {side=d[3], edge_tiles=sd.edge, uncovered=#open, gaps=gaps, by_size=per}
        lines[#lines+1] = string.format('%s%s side: %d edge tiles, %d where a size is not covered; %s', prefix or '', d[3], sd.edge, #open, table.concat(words, '; '))
      end
    end
    return side_rows
  end
  local plan_store
  local function hull_sides(tiles, turrets, keep, kinds, field, words_second, lines, prefix)
    local set = {}
    for _, t in ipairs(tiles) do set[key(t.x, t.y)] = true end
    local grid = reach_grid(turrets)
    local sides = {}
    for _, t in ipairs(tiles) do edge_tile(set, grid, t.x, t.y, keep, kinds, sides) end
    return side_lines(sides, field, words_second, lines, prefix)
  end
  local function size_words(bs)
    local w = {}
    for _, size in ipairs(SIZES) do
      local r = bs[size]
      w[#w+1] = r.covered and string.format('%s %d', size, r.turrets) or r.turrets == 0 and size .. ' none'
        or string.format('%s %d, none for %s', size, r.turrets, table.concat(r.missing, '/'))
    end
    return table.concat(w, ', ')
  end
  -- (d17 batch35 B6, viewer Aurora 14:48: guns can read as covering big asteroids) damage apart from reach: for the
  -- route asked (or the schedule's next leg), each asteroid that spawns on that connection, its health and resistances
  -- (the prototypes, as the tooltips give them), and per turret and the ammo it holds now its damage a second against it
  -- after them (the force's ammo damage, turret attack and gun speed bonuses counted), against its listed damage; the
  -- engaging turrets together and the time to kill one. Read on world n (2.0.77): big-metallic-asteroid 2000 hp,
  -- physical 2000 flat and 10%, explosion 10%; firearm-magazine 5 physical, piercing 8, uranium 24, railgun-ammo 10000;
  -- gun-turret every 6 ticks, rocket-turret 120, railgun-turret 170. A projectile's damage (rockets) is not in the
  -- runtime's prototypes: the base game's data (PROJECTILE). Under LITTLE % of its listed damage reads little damage.
  M.LITTLE = 10
  local PROJECTILE = {rocket={{amount=200, type='explosion'}}, ['explosive-rocket']={{amount=300, type='explosion'}}}
  local function damages(action, out, from_data)
    if type(action) ~= 'table' then return end
    if action.type == 'damage' and type(action.damage) == 'table' and action.damage.amount then out[#out+1] = {amount=action.damage.amount, type=action.damage.type} end
    if type(action.projectile) == 'string' then
      -- (d20 batch52 K5) the projectile's own attack_result, as 2.0.77 gives it at runtime; the base game's numbers only
      -- when none is read
      local n0 = #out
      local pp = prototypes.entity[action.projectile]
      local function walk(t, depth)
        if type(t) ~= 'table' or depth > 12 then return end
        if t.type == 'damage' and type(t.damage) == 'table' and t.damage.amount then out[#out+1] = {amount=t.damage.amount, type=t.damage.type}; return end
        for _, v in pairs(t) do walk(v, depth + 1) end
      end
      if pp then walk(try(function() return pp.attack_result end), 0); walk(try(function() return pp.final_attack_result end), 0) end
      if #out == n0 and PROJECTILE[action.projectile] then
        for _, d in ipairs(PROJECTILE[action.projectile]) do out[#out+1] = d end
        from_data[1] = true
      end
    end
    for _, v in pairs(action) do if type(v) == 'table' then damages(v, out, from_data) end end
  end
  M.damages = damages  -- (d22 batch88 AX1) endurance's forecast reads a shot's damage the same way (routeammo.lua)
  local function after(amount, res)
    local d, pct = res and res.decrease or 0, res and res.percent or 0
    local v = amount > d and amount - d or 1 / (2 + d - amount)
    return v * (1 - pct)
  end
  local function connection(pl, a)
    local from, to
    if type(a.route) == 'string' and prototypes.space_connection and prototypes.space_connection[a.route] then return prototypes.space_connection[a.route] end
    if type(a.route) == 'string' then
      from, to = a.route:match('^([%w%-_]+)%s*%->%s*([%w%-_]+)$')
      if not from then from, to = a.route:match('^([%w_]+)%-([%w_]+)$') end
      assert(from, 'route is "FROM->TO" (planet names) or a space connection name')
    else
      from = try(function() return pl.space_location.name end)
      local sch = try(function() return pl.schedule end)
      local rec = sch and sch.records and sch.records[sch.current]
      to = rec and rec.station
      if not from then
        local c = try(function() return pl.space_connection end)
        if c then return c end
      end
    end
    if not (from and to) then return nil end
    for _, c in pairs(prototypes.space_connection or {}) do
      local f, t = try(function() return c.from.name end), try(function() return c.to.name end)
      if (f == from and t == to) or (f == to and t == from) then return c end
    end
  end
  function M.damage(force, turrets, conn)
    local lines, rows = {}, {}
    local seen = {}
    for _, def in ipairs(try(function() return conn.asteroid_spawn_definitions end) or {}) do
      local name = def.type == 'entity' and (type(def.asteroid) == 'string' and def.asteroid or try(function() return def.asteroid.name end))
      local proto = name and not seen[name] and prototypes.entity[name]
      if proto then
        seen[name] = true
        local hp = try(function() return proto.get_max_health() end) or 0
        local res = try(function() return proto.resistances end) or {}
        local groups, order, total, best_pct = {}, {}, 0, 0
        for _, t in ipairs(turrets) do
          if t.entity.valid and (t.only == nil or t.only[name]) and t.entity.type == 'ammo-turret' then
            local inv = try(function() return t.entity.get_inventory(defines.inventory.turret_ammo) end)
            local st = inv and inv[1] and inv[1].valid_for_read and inv[1]
            local key = t.name .. '|' .. (st and st.name or '')
            local g = groups[key]
            if not g then
              g = {turret=t.name, ammo=st and st.name, n=0}
              if st then
                local ap = prototypes.item[st.name]
                local cat = try(function() return ap.ammo_category.name end)
                local list, from_data = {}, {}
                damages(try(function() return ap.get_ammo_type().action end), list, from_data)
                local mult = (1 + (try(function() return force.get_ammo_damage_modifier(cat) end) or 0)) * (1 + (try(function() return force.get_turret_attack_modifier(t.name) end) or 0))
                local cd = try(function() return t.entity.prototype.attack_parameters.cooldown end) or 60
                local rate = 60 / cd * (1 + (try(function() return force.get_gun_speed_modifier(cat) end) or 0))
                local listed, real = 0, 0
                for _, d in ipairs(list) do listed = listed + d.amount * mult; real = real + after(d.amount * mult, res[d.type]) end
                g.listed, g.dps, g.from_data = listed * rate, real * rate, from_data[1]
                g.pct = listed > 0 and real / listed * 100 or 0
              end
              groups[key] = g; order[#order+1] = g
            end
            g.n = g.n + 1
            if g.dps then total = total + g.dps; best_pct = math.max(best_pct, g.pct) end
          end
        end
        local rtext = {}
        for _, k in ipairs({'physical', 'explosion', 'laser', 'electric', 'fire'}) do
          local r = res[k]
          if r and ((r.decrease or 0) > 0 or (r.percent or 0) > 0) then rtext[#rtext+1] = string.format('%s %g/%d%%', k, r.decrease or 0, math.floor((r.percent or 0) * 100 + 0.5)) end
        end
        local parts = {}
        for _, g in ipairs(order) do
          parts[#parts+1] = g.ammo and string.format('%d %s with %s: %s/s each (%s%% of its listed %s/s)%s', g.n, g.turret, g.ammo, M.num(g.dps), M.num(g.pct), M.num(g.listed),
            g.from_data and ' (the rocket\'s damage from the base game\'s data)' or '') or string.format('%d %s with no ammo', g.n, g.turret)
        end
        local verdict = #parts == 0 and 'no turret of ours engages it'
          or total <= 0 and 'engaged, no damage (no ammo)'
          or best_pct < M.LITTLE and string.format('reached, little damage: %s/s together, one in %s s', M.num(total), M.num(hp / total))
          or string.format('%s/s together, one in %s s', M.num(total), M.num(hp / total))
        rows[#rows+1] = {asteroid=name, hp=hp, dps=total, kill_s=total > 0 and hp / total or nil, little=best_pct < M.LITTLE or nil}
        lines[#lines+1] = string.format('%s (%d hp; resists %s): %s%s', name, hp, #rtext > 0 and table.concat(rtext, ', ') or 'nothing', #parts > 0 and table.concat(parts, '; ') .. ': ' or '', verdict)
      end
    end
    return lines, rows
  end
  -- (d21 batch72 AH2, Astra #1741: Asterion's 15,357-tile hull staged as ghosts, and reviews drew railgun circles) the
  -- planned defense: our turret ghosts with the built turrets, on the hull with our foundation tile ghosts, each turret
  -- by its prototype's range, minimum range and arc by its facing and the priority list it carries; cover per asteroid
  -- size as the built read gives it, and apart from it what only ghosts cover. Ghosts hold no ammunition and draw no
  -- power: planned cover is reach alone.
  M.PLANNED_NOTE = 'planned cover is reach alone: a ghost holds no ammunition and draws no power, so it fires at nothing until it is built, fed and powered (ammo turrets: ammunition; laser turrets: power; fluid turrets: fluid)'
  function M.planned(pl, s, force, turrets, kinds, lines)
    local ghosts, by_name = {}, {}
    for _, g in ipairs(s.find_entities_filtered{type='entity-ghost', ghost_type=TURRETS, force=force, limit=MAX_TURRETS}) do
      if g.valid then
        local info = ghost_info(g)
        info.idx = #turrets + #ghosts + 1
        ghosts[#ghosts+1] = info
        by_name[info.name] = (by_name[info.name] or 0) + 1
      end
    end
    local all = {}
    for _, t in ipairs(turrets) do all[#all+1] = t end
    for _, g in ipairs(ghosts) do all[#all+1] = g end
    -- the planned hull's sides: the last background read of this platform kept PLAN_KEEP ticks, else one begun now
    local P = plan_store()
    local done, job = P.done[pl.index], P.jobs[pl.index]
    if done and game.tick - done.start > M.PLAN_KEEP then done = nil end
    if not done and not job then M.plan_start(pl, all, kinds) end
    local names = {}
    for n, c in pairs(by_name) do names[#names+1] = n .. ' ' .. c end
    table.sort(names)
    lines[#lines+1] = string.format('planned: %d built turret%s and %d turret ghost%s%s; %s',
      #turrets, #turrets == 1 and '' or 's', #ghosts, #ghosts == 1 and '' or 's', #names > 0 and ' (' .. table.concat(names, ', ') .. ')' or '', M.PLANNED_NOTE)
    -- the ghosts with an arc, one line each (up to 16), and the rest by name, range and what they engage
    local arcs, plain, grows = 0, {}, {}
    for i, g in ipairs(ghosts) do
      if g.arc and arcs < 16 then
        arcs = arcs + 1
        lines[#lines+1] = string.format('planned: %s ghost %s %s, range %g%s, engages %s', g.name, at(g.position), g.arc, g.range,
          g.min_range > 0 and string.format(', not within %g', g.min_range) or '', g.engages)
      elseif not g.arc then
        local k = string.format('%s ghosts: range %g%s, aim all round, engage %s', g.name, g.range, g.min_range > 0 and string.format(', not within %g', g.min_range) or '', g.engages)
        plain[k] = (plain[k] or 0) + 1
      end
      if g.arc and #grows < 16 then grows[#grows+1] = {name=g.name, position=g.position, facing=g.facing, arc_degrees=g.arc_degrees, range=g.range, min_range=g.min_range > 0 and g.min_range or nil, engages=g.engages, unarmed=g.unarmed} end
    end
    local pk = {}
    for k, n in pairs(plain) do pk[#pk+1] = n .. ' ' .. k end
    table.sort(pk)
    for _, k in ipairs(pk) do lines[#lines+1] = 'planned: ' .. k end
    -- the collectors built and planned, against every turret built and planned, and the built turrets alone: one line
    -- by size (how many none reaches, how many only ghosts reach), then up to 8 collectors a size leaves uncovered
    local collectors, open_by, ghost_by, open_list, nopen = {}, {}, {}, {}, 0
    local function collector(pos, front, ghost, cname)
      local list, nearest, nd, outside = covering(all, front)
      local built = {}
      for _, t in ipairs(list) do if not t.ghost then built[#built+1] = t end end
      local bs, bb = by_size(list, kinds), by_size(built, kinds)
      local open, ghost_only = {}, {}
      for _, size in ipairs(SIZES) do
        if not bs[size].covered then open[#open+1] = size; open_by[size] = (open_by[size] or 0) + 1
        elseif not bb[size].covered then ghost_only[#ghost_only+1] = size; ghost_by[size] = (ghost_by[size] or 0) + 1 end
      end
      local row = {position=pos, ghost=ghost or nil, covered_by=#list, ghosts=#list - #built, uncovered=#open > 0 and open or nil, ghost_only=#ghost_only > 0 and ghost_only or nil}
      if #outside > 0 then
        row.outside_arc = {}
        for i, o in ipairs(outside) do if i <= 4 then row.outside_arc[i] = {name=o.turret.name, ghost=o.turret.ghost or nil, position=o.turret.position, off_degrees=math.floor(o.off + 0.5)} end end
      end
      collectors[#collectors+1] = row
      if #open > 0 then nopen = nopen + 1 end
      if #open > 0 and #open_list < 8 then
        open_list[#open_list+1] = string.format('%s%s %s (front %s): %s%s', cname, ghost and ' ghost' or '', at(pos), at(front),
          #list > 0 and string.format('%d reach it (%d ghosts), none for %s', #list, #list - #built, table.concat(open, '/'))
            or (nearest and string.format('NO built or planned turret reaches it (nearest %s%s %s, %.0f tiles past its range %g)', nearest.name, nearest.ghost and ' ghost' or '', at(nearest.position), nd, nearest.range) or 'NO turret built or planned'),
          #outside > 0 and '; in range but outside the arc, not counted: ' .. outside_words(outside) or '')
      end
    end
    for _, c in ipairs(s.find_entities_filtered{type='asteroid-collector', force=force}) do collector(c.position, front_of(c.prototype, c.position, c.direction), false, c.name) end
    for _, g in ipairs(s.find_entities_filtered{type='entity-ghost', ghost_type='asteroid-collector', force=force}) do
      collector(g.position, front_of(g.ghost_prototype, g.position, g.direction), true, g.ghost_name)
    end
    if #collectors > 0 then
      local w = {}
      for _, size in ipairs(SIZES) do
        w[#w+1] = string.format('%s: %d uncovered, %d covered only by ghosts', size, open_by[size] or 0, ghost_by[size] or 0)
      end
      lines[#lines+1] = string.format('planned: %d collector%s (built and ghosts) by size: %s%s', #collectors, #collectors == 1 and '' or 's', table.concat(w, '; '),
        #open_list > 0 and '; uncovered: ' .. table.concat(open_list, '; ') .. (nopen > #open_list and string.format(' (+%d more: collectors rows)', nopen - #open_list) or '') or '')
    end
    local out = {note=M.PLANNED_NOTE, built_turrets=#turrets, turret_ghosts=#ghosts, ghosts_by_name=by_name, capped=#ghosts >= MAX_TURRETS or nil,
      ghosts=grows, collectors=collectors}
    if done then
      out.sides, out.sides_as_of, out.foundation_tiles, out.foundation_ghosts, out.sides_capped = done.sides, done.start, done.built, done.ghosts, done.capped
      lines[#lines+1] = string.format('planned: the hull read at tick %d (%ds ago): %d foundation tiles and %d foundation tile ghosts%s, with the turrets and ghosts standing then',
        done.start, math.floor((game.tick - done.start) / 60), done.built, done.ghosts, done.capped and string.format(' (capped at %d)', MAX_TILES) or '')
      for _, l in ipairs(done.lines) do lines[#lines+1] = l end
    else
      local j = P.jobs[pl.index]
      out.sides_pending = string.format('the planned hull is being read in the background since tick %d (%d tiles so far, about %d tiles a second: a 15,000-tile hull takes about 20 s); call again then for its sides',
        j.start, #j.keys, M.PLAN_WORK * 60)
      lines[#lines+1] = 'planned: ' .. out.sides_pending
    end
    return out
  end
  -- (AH2) The planned hull's sides in the background: a synchronous read of Asterion's 15,357 tiles took 120 ms on the
  -- private copy (12,197 tile ghosts' positions alone 13 ms). A job per platform, in storage: the chunks from the hub's
  -- out to each neighbour of a chunk with foundation or a tile ghost (a hull part a whole empty chunk away from the rest
  -- is not read), one chunk a tick; then PLAN_EDGES tiles a tick into the sides with each edge tile's cover; then the
  -- lines. Kept PLAN_KEEP ticks; at most PLAN_JOBS at once, one at a time, paced by work: PLAN_WORK units a tick (a tile
  -- found or checked one, an edge tile sorted into the lines 4, a chunk's finds 32), kept up to PLAN_CAP; unpaced, three
  -- jobs (Asterion, Kestrel II, Prospect) put up to 66 ms into one second.
  M.PLAN_KEEP, M.PLAN_EDGES, M.PLAN_JOBS, M.PLAN_WORK, M.PLAN_CAP = 1800, 500, 4, 60, 120
  plan_store = function()
    local st = api.state()
    st.platplan = st.platplan or {jobs={}, done={}}
    return st.platplan
  end
  function M.plan_start(pl, all, kinds)
    local P = plan_store()
    local n = 0
    for _ in pairs(P.jobs) do n = n + 1 end
    if n >= M.PLAN_JOBS then return end
    local tl, ghosts = {}, false
    for i, t in ipairs(all) do
      if t.ghost then ghosts = true end
      tl[i] = {position={x=t.position.x, y=t.position.y}, face=t.face, half=t.half, range=t.range, min_range=t.min_range, only=t.only, ghost=t.ghost, idx=i}
    end
    local seen = {}
    local queue = {{0, 0}, {-1, -1}, {-1, 0}, {0, -1}}
    for _, c in ipairs(queue) do seen[key(c[1], c[2])] = true end
    P.jobs[pl.index] = {force=pl.force.name, start=game.tick, stage='chunks', turrets=tl, kinds=kinds, ghosts=ghosts or nil, queue=queue, qi=1, seen=seen,
      set={}, keys={}, built=0, tile_ghosts=0, ei=1, sides={}}
  end
  local function plan_step(index, job)
    local f = game.forces[job.force or 'player']
    local pl = f and f.platforms[index]
    local s = pl and pl.valid and pl.surface
    local P = plan_store()
    if not s then P.jobs[index] = nil; return end
    job.credit = math.min(M.PLAN_CAP, (job.credit or 0) + M.PLAN_WORK * math.max(0, game.tick - (job.paced or game.tick - 1)))
    job.paced = game.tick
    if job.credit <= 0 then return end
    if job.stage == 'chunks' then
      local c = job.queue[job.qi]
      if not c or #job.keys >= MAX_TILES then job.stage = 'edges'; return end
      job.qi = job.qi + 1
      local area = {{c[1] * 32, c[2] * 32}, {c[1] * 32 + 32, c[2] * 32 + 32}}
      local found = 0
      for _, t in ipairs(s.find_tiles_filtered{area=area, name='space-platform-foundation'}) do
        local q = t.position
        local k = key(q.x, q.y)
        if not job.set[k] and #job.keys < MAX_TILES then job.set[k] = true; job.keys[#job.keys+1] = k; job.built = job.built + 1 end
        found = found + 1
      end
      -- a tile ghost over empty space: on a platform only foundation goes there
      for _, t in ipairs(s.find_tiles_filtered{area=area, has_tile_ghost=true, force=pl.force}) do
        local q = t.position
        local k = key(q.x, q.y)
        if not job.set[k] and #job.keys < MAX_TILES then job.set[k] = true; job.keys[#job.keys+1] = k; job.tile_ghosts = job.tile_ghosts + 1 end
        found = found + 1
      end
      job.credit = job.credit - 32 - found
      if found > 0 then
        for dx = -1, 1 do for dy = -1, 1 do
          local k = key(c[1] + dx, c[2] + dy)
          if not job.seen[k] then job.seen[k] = true; job.queue[#job.queue+1] = {c[1] + dx, c[2] + dy} end
        end end
      end
    elseif job.stage == 'edges' then
      memo = {}
      local grid = reach_grid(job.turrets)
      local keep = job.ghosts and function(t) return not t.ghost end or nil
      local last = math.min(#job.keys, job.ei + M.PLAN_EDGES - 1)
      for i = job.ei, last do
        local k = job.keys[i]
        edge_tile(job.set, grid, math.floor(k / 65536) - 32768, k % 65536 - 32768, keep, job.kinds, job.sides)
      end
      job.credit = job.credit - (last - job.ei + 1)
      job.ei = last + 1
      if job.ei > #job.keys then job.stage = 'lines' end
    else
      local lines = {}
      local edges = 0
      for _, sd in pairs(job.sides) do edges = edges + sd.edge end
      if job.credit < edges * 4 and not job.waited then job.waited = true; job.credit = job.credit - edges * 4; return end
      local rows = side_lines(job.sides, 'ghost_only', 'more covered only by turret ghosts', lines, 'planned: ')
      P.done[index] = {start=job.start, tick=game.tick, sides=rows, lines=lines, built=job.built, ghosts=job.tile_ghosts, capped=#job.keys >= MAX_TILES or nil}
      P.jobs[index] = nil
    end
  end
  function M.tick(tick)
    local st = api.state and api.state()
    local P = st and st.platplan
    if not P then return end
    local index, job = next(P.jobs)
    if index then plan_step(index, job) end
    -- results kept past PLAN_KEEP are dropped (one a tick)
    local di, d = next(P.done)
    if di and tick - d.start > M.PLAN_KEEP * 4 then P.done[di] = nil end
  end
  function M.num(v) if v >= 100 then return string.format('%d', math.floor(v + 0.5)) elseif v >= 1 then return string.format('%.1f', v) else return string.format('%.3g', v) end end
  -- (#2042) Which turrets the rows show: those names and positions pick (names: 1..16 prototype names; positions:
  -- 1..64 {x, y}, a turret whose centre is within 1 tile; both: either), M.PAGE a page, page 1.. -> {all (the picked
  -- turrets' indices), shown (this page's), page_info {page, pages, per_page, total (picked), returned, turrets (all),
  -- from, to, next, filter}}. A page past the last is refused, naming how many there are. (#2071) railguns_only: of
  -- those, only the turrets whose shots are a line (fireline.lua: railgun-turret).
  M.PAGE, M.LINE_PAGE = 64, 16
  local function page_of(n, page, per, what, arg)
    local pages = math.max(1, math.ceil(n / per))
    assert(page <= pages, string.format('%s %d: the %d %s make %d page%s of %d', arg, page, n, what, pages, pages == 1 and '' or 's', per))
    local from, to = (page - 1) * per + 1, math.min(n, page * per)
    return {page=page, pages=pages, per_page=per, total=n, returned=math.max(0, to - from + 1), from=to >= from and from or 0, to=to >= from and to or 0, next=page < pages and page + 1 or nil}
  end
  M.page_of = page_of
  function M.pick(turrets, a)
    local names, pos = a.names, a.positions
    if type(names) == 'string' then names = {names} end
    assert(names == nil or (type(names) == 'table' and #names >= 1 and #names <= 16), 'names: 1..16 turret prototype names')
    assert(pos == nil or (type(pos) == 'table' and #pos >= 1 and #pos <= 64), 'positions: 1..64 {x, y}')
    assert(a.page == nil or (type(a.page) == 'number' and a.page >= 1 and a.page == math.floor(a.page)), 'page is 1, 2, ...')
    assert(a.railguns_only == nil or type(a.railguns_only) == 'boolean', 'railguns_only is true or false')
    local rails = a.railguns_only == true
    local nset, plist = {}, {}
    for _, n in ipairs(names or {}) do assert(type(n) == 'string', 'names: 1..16 turret prototype names'); nset[n] = true end
    for _, q in ipairs(pos or {}) do plist[#plist+1] = api.position(q) end
    local all = {}
    for i, t in ipairs(turrets) do
      local ok = not names and not pos
      if names and nset[t.name] then ok = true end
      if not ok and pos then
        for _, q in ipairs(plist) do if math.abs(t.position.x - q.x) <= 1 and math.abs(t.position.y - q.y) <= 1 then ok = true; break end end
      end
      if ok and rails and not (api.fireline and api.fireline.arc(t.name)) then ok = false end
      if ok then all[#all+1] = i end
    end
    local info = page_of(#all, a.page or 1, M.PAGE, 'turrets picked', 'page')
    local shown = {}
    for k = info.from, info.to do if k > 0 then shown[#shown+1] = all[k] end end
    local filter = {}
    if names then filter[#filter+1] = 'names ' .. table.concat(names, ', ') end
    if pos then filter[#filter+1] = #pos .. ' position' .. (#pos == 1 and '' or 's') end
    local ftext = #filter > 0 and table.concat(filter, ' or ') or nil
    if rails then ftext = (ftext and '(' .. ftext .. ') and ' or '') .. 'railguns only (shots a line)' end
    info.turrets, info.filter = #turrets, ftext
    return {all=all, shown=shown, page_info=info}
  end
  function M.read(p, a)
    memo = {}
    assert(a.ammo_use == nil or a.ammo_use == true or a.ammo_use == false or a.ammo_use == 'all', 'ammo_use is true, false or "all"')
    local pl = api.platform(p, a.platform)
    local s = pl.surface
    assert(s, 'platform ' .. pl.name .. ' has no surface yet')
    local force = pl.force
    local turrets = {}
    for _, t in ipairs(s.find_entities_filtered{type=TURRETS, force=force, limit=MAX_TURRETS}) do
      if t.valid then local info = turret_info(s, force, t); info.idx = #turrets + 1; turrets[#turrets+1] = info end
    end
    local kinds = {'metallic', 'carbonic', 'oxide'}
    for _, t in ipairs(turrets) do
      for name in pairs(t.only or {}) do if name:find('promethium', 1, true) and #kinds == 3 then kinds[4] = 'promethium' end end
    end
    local lines = {}
    -- collectors' fronts
    local collectors = {}
    for _, c in ipairs(s.find_entities_filtered{type='asteroid-collector', force=force}) do
      local front = front_of(c.prototype, c.position, c.direction)
      local list, nearest, nd, outside = covering(turrets, front)
      local words = {}
      for i, t in ipairs(list) do if i <= 4 then words[i] = string.format('%s %s %s, engages %s, fed by %s', t.name, at(t.position), t.ammo, t.engages, t.feed) end end
      local bs = by_size(list, kinds)
      local row = {position=c.position, front=front, covered_by=#list, by_size=bs}
      -- in range of a turret that cannot aim there: not counted, named
      local off_words = #outside > 0 and '; in range but outside the arc, not counted: ' .. outside_words(outside) or ''
      if #outside > 0 then
        row.outside_arc = {}
        for i, o in ipairs(outside) do if i <= 8 then row.outside_arc[i] = {name=o.turret.name, position=o.turret.position, facing=o.turret.facing, arc_degrees=o.turret.arc_degrees, off_degrees=math.floor(o.off + 0.5)} end end
      end
      -- armed now: the same read with the turrets holding no ammo, energy or fluid left out
      local live = {}
      for _, t in ipairs(list) do if t.armed then live[#live+1] = t end end
      local armed_words = ''
      if #live < #list then
        row.armed_by, row.by_size_armed = #live, by_size(live, kinds)
        armed_words = string.format('; armed now %d of %d (by size: %s)', #live, #list, size_words(row.by_size_armed))
      end
      collectors[#collectors+1] = row
      if #list > 0 then
        lines[#lines+1] = string.format('asteroid-collector %s, front %s: %d turret%s reach it (by size: %s)%s: %s%s%s', at(c.position), at(front), #list, #list == 1 and '' or 's',
          size_words(bs), armed_words, table.concat(words, '; '), #list > 4 and string.format('; +%d more', #list - 4) or '', off_words)
      else
        lines[#lines+1] = string.format('asteroid-collector %s, front %s: NO turret reaches it%s%s', at(c.position), at(front),
          #outside > 0 and '' or nearest and string.format(' (nearest %s %s, %.0f tiles past its range %g)', nearest.name, at(nearest.position), nd, nearest.range) or #outside > 0 and '' or ' (no turret on the platform)', off_words)
      end
    end
    -- hull edges by side
    local tiles = s.find_tiles_filtered{name='space-platform-foundation', limit=MAX_TILES}
    local xy = {}
    for i, t in ipairs(tiles) do xy[i] = t.position end
    local live_turrets, all_armed = {}, true
    for _, t in ipairs(turrets) do if t.armed then live_turrets[#live_turrets+1] = t else all_armed = false end end
    local side_rows = hull_sides(xy, turrets, not all_armed and function(t) return t.armed end or nil, kinds, 'unarmed_only', 'more covered only by turrets not armed now', lines)
    local planned = a.planned == true and M.planned(pl, s, force, turrets, kinds, lines) or nil
    local empty, hand, idle = {}, 0, {}
    for _, t in ipairs(turrets) do
      if t.empty then empty[#empty+1] = t.name .. ' ' .. at(t.position) end
      if t.feed == 'nothing (by hand)' then hand = hand + 1 end
      if not t.armed and t.type ~= 'ammo-turret' and #idle < 6 then idle[#idle+1] = string.format('%s %s (%s)', t.name, at(t.position), t.unarmed) end
    end
    lines[#lines+1] = string.format('%d turrets: %d armed now, %d empty%s, %d fed by nothing (by hand)%s', #turrets, #live_turrets, #empty,
      #empty > 0 and ' (' .. table.concat(empty, ', ', 1, math.min(6, #empty)) .. ')' or '', hand, #idle > 0 and '; not armed: ' .. table.concat(idle, ', ') or '')
    -- (d23 batch124b, Sol #2042: Asterion's 120 turrets, the rows stopped at 64, "cannot audit directed local reserves
    -- for remaining 8 rails") the turret rows and the feed's turret rows by page (M.PAGE a page; page 2, 3, ...) of the
    -- turrets that names and positions pick (all by default); the lines and the collectors', sides' and feed's summaries
    -- still read every turret. turrets_page says which.
    local pick = M.pick(turrets, a)
    local tp = pick.page_info
    if #turrets >= MAX_TURRETS then tp.capped = MAX_TURRETS end
    lines[#lines+1] = string.format('turret rows: page %d of %d, turrets %d-%d of the %d picked%s (%d turrets read%s)%s', tp.page, tp.pages, tp.from, tp.to, tp.total,
      tp.filter and ' (' .. tp.filter .. ')' or '', #turrets, tp.capped and string.format(', the find stopped at %d', MAX_TURRETS) or '',
      tp.next and string.format('; %d more on page %d..%d', tp.total - tp.to, tp.next, tp.pages) or '')
    local trows, shown = {}, {}
    for _, i in ipairs(pick.shown) do
      local t = turrets[i]
      shown[i] = true
      trows[i] = {name=t.name, position=t.position, facing=t.facing, arc_degrees=t.arc_degrees, range=t.range, min_range=t.min_range > 0 and t.min_range or nil, engages=t.engages, ammo=t.ammo, armed=t.armed, unarmed=t.unarmed, feed=t.feed}
    end
    -- (A1) the turrets that engage only part of the asteroids, one line
    local part = {}
    for _, t in ipairs(turrets) do if t.only and #part < 8 then part[#part+1] = string.format('%s %s engages %s%s', t.name, at(t.position), t.engages, t.min_range > 0 and string.format(', not within %g tiles', t.min_range) or '') end end
    if #part > 0 then lines[#lines+1] = 'by their priority lists: ' .. table.concat(part, '; ') end
    -- (d17 batch31 B3, Astra: big asteroids enabled behind Kestrel II's bow, the shots broke an ammo belt) a turret whose
    -- shots are a line (railgun): the entities of ours they cross within its arc (fireline.lua), with what it engages
    -- (d18 batch40 A1, Sol 21:21: Wayfarer lost 27 to its own bow railguns, read as asteroid losses) what turrets of
    -- ours destroyed here, per turret, from the loss incidents kept (the death event's cause and its force)
    local own = api.own_losses and try(function() return api.own_losses(pl.name) end) or {}
    local by_turret, own_rows = {}, {}
    for k, r in ipairs(own) do
      local id = r.name .. at(r)
      by_turret[id] = (by_turret[id] or 0) + r.n
      if k <= 8 then own_rows[k] = {name=r.name, position={x=r.x, y=r.y}, destroyed=r.n, loss=r.loss, ago_s=math.floor((game.tick - (r.last_tick or game.tick)) / 60)} end
    end
    if #own_rows > 0 then
      local parts = {}
      for k, r in ipairs(own_rows) do parts[k] = string.format('%s at %s: %d (loss #%d, %ds ago)', r.name, at(r.position), r.destroyed, r.loss, r.ago_s) end
      lines[#lines+1] = 'destroyed by our own turrets (the loss incidents kept, apart from asteroid hits): ' .. table.concat(parts, '; ') .. (#own > 8 and string.format('; +%d more', #own - 8) or '')
    end
    for i, t in ipairs(turrets) do
      local mine = by_turret[t.name .. at(t.position)]
      if trows[i] and mine then trows[i].destroyed_ours = mine end
    end
    -- (d23 batch124b, Sol #2071: Asterion's 23 railguns, 16 lines of fire returned; "a clear returned subset cannot
    -- establish full friendly-fire clearance") the lines of fire of the picked turrets whose shots are a line, M.LINE_PAGE
    -- a page (line_page 1, 2, ...): lines_page says which of how many, lines_of_fire holds the rows, and a turret row
    -- whose line is on another page names that page (line_page).
    assert(a.line_page == nil or (type(a.line_page) == 'number' and a.line_page >= 1 and a.line_page == math.floor(a.line_page)), 'line_page is 1, 2, ...')
    local liners = {}
    for _, i in ipairs(pick.all) do if api.fireline and api.fireline.arc(turrets[i].name) then liners[#liners+1] = i end end
    local lpage = page_of(#liners, a.line_page or 1, M.LINE_PAGE, 'turrets picked whose shots are a line', 'line_page')
    lpage.filter = pick.page_info.filter
    local fire_rows, fire_lines, clear, hitting, hit_n, cut_n, unread = {}, {}, 0, 0, 0, 0, 0
    for k, i in ipairs(liners) do
      local t = turrets[i]
      if lpage.from > 0 and k >= lpage.from and k <= lpage.to then
        local r = try(function() return api.fireline.of(t.entity) end)
        local mine = by_turret[t.name .. at(t.position)]
        local row = {name=t.name, position=t.position, facing=t.facing, engages=t.engages, destroyed_ours=mine}
        if r then
          row.line, row.hit, row.ghosts, row.cut, row.entities = r.line, r.hit, r.ghosts, r.cut, r.entities
          -- clear: none of ours hit with every entity near its arc read (a cut find is counted apart)
          if r.hit > 0 then hitting = hitting + 1; hit_n = hit_n + r.hit elseif not r.cut then clear = clear + 1 end
          if r.cut then cut_n = cut_n + 1 end
          fire_lines[#fire_lines+1] = 'line of fire: ' .. r.line .. (t.engages and '; it engages ' .. t.engages or '') .. (mine and string.format('; it destroyed %d of ours (loss incidents kept)', mine) or '')
          if trows[i] then trows[i].line_of_fire, trows[i].hits = r.line, r.hit end
        else
          row.unread = true; unread = unread + 1
          fire_lines[#fire_lines+1] = string.format('line of fire: %s %s: not read', t.name, at(t.position))
        end
        fire_rows[#fire_rows+1] = row
      elseif trows[i] then trows[i].line_page = math.ceil(k / M.LINE_PAGE) end
    end
    lpage.clear, lpage.hitting, lpage.hit, lpage.cut, lpage.unread = clear, hitting, hit_n, cut_n > 0 and cut_n or nil, unread > 0 and unread or nil
    if #liners > 0 then
      lines[#lines+1] = string.format('lines of fire: line_page %d of %d, turrets %d-%d of the %d picked whose shots are a line%s: %d hit none of ours (every entity near the arc read), %d hit %d of ours%s%s%s',
        lpage.page, lpage.pages, lpage.from, lpage.to, lpage.total, lpage.filter and ' (' .. lpage.filter .. ')' or '', clear, hitting, hit_n,
        cut_n > 0 and string.format(', %d read only part of the entities near their arc (cut)', cut_n) or '', unread > 0 and string.format(', %d not read', unread) or '',
        lpage.next and string.format('; %d more on line_page %d..%d', lpage.total - lpage.to, lpage.next, lpage.pages) or '')
    end
    for _, l in ipairs(fire_lines) do lines[#lines+1] = l end
    -- (d17 batch13 B1) each turret's way back to its ammunition: what can reach it and what is stranded
    local feed
    if api.ammofeed then
      local ok, tr, why = pcall(api.ammofeed.get or api.ammofeed.trace, pl)
      if ok and not tr then feed = {pending=why}; lines[#lines+1] = why
      elseif ok then
        local aboard = try(function() return p.character and p.character.valid and p.character.surface == s end) == true
        -- (#2042) the feed's turret rows for the turrets on this page (by position), and how many the pick holds
        local on_page, picked = {}, {}
        for _, i in ipairs(pick.all) do picked[at(turrets[i].position)] = true end
        for i in pairs(shown) do on_page[at(turrets[i].position)] = true end
        local lines_ = api.ammofeed.lines(tr, a.feed == true, pl.name, aboard)  -- (sets each row's replenished)
        local per, in_pick = {}, 0
        for _, row in ipairs(tr.rows) do
          local k = at(row.position)
          if picked[k] then in_pick = in_pick + 1 end
          if on_page[k] then
            per[#per+1] = {position=row.position, holds=row.own, reaches=row.reaches, stopped=#row.stops > 0 or nil, gated=row.gated and #row.gated > 0 or nil, behind_gate=row.behind_gate,
              -- (d20 batch52 K6) what refills each: maker | hub | chest | preload | none (ammofeed.lines sets it)
              replenished=row.replenished, replenished_gated=row.replenished_gated}
          end
        end
        feed = {reaches=tr.reaches, stranded=tr.stranded, gates=#(tr.gates or {}) > 0 and tr.gates or nil, stranded_groups=tr.stranded_groups, stranded_recover=tr.stranded_recover, hub_reaches=tr.hub_reaches,
          via_hub=tr.via_hub, at_end=tr.at_end, at_end_rows=tr.at_end_rows, turrets=per, turrets_total=in_pick, lines=lines_}
        feed.as_of = tr.as_of
        if tr.as_of then table.insert(feed.lines, 1, 'ammunition trace ' .. tr.as_of) end
        for _, l in ipairs(feed.lines) do lines[#lines+1] = l end
      else feed = {error=tostring(tr)} end
    end
    -- (d20 batch60 V1, Sol #1470) ammunition use at full fire, per turret and ammunition (ammorate.lua): the ammunition
    -- each holds, and the hub's of their categories; ammo_use "all": every ammo turret with every ammunition
    local ammo_rows
    if api.ammorate and a.ammo_use ~= false then
      local hub_rows = {}
      local inv = try(function() return pl.hub.get_inventory(defines.inventory.hub_main) end)
      for _, r in ipairs(inv and try(function() return inv.get_contents() end) or {}) do
        if try(function() return prototypes.item[r.name].type end) == 'ammo' then hub_rows[#hub_rows+1] = r end
      end
      local ok, rows, alines = pcall(api.ammorate.rows, force, turrets, hub_rows, damages, a.ammo_use == 'all')
      if ok then
        ammo_rows = rows
        if #alines > 0 then
          lines[#lines+1] = 'ammunition use at full fire (' .. api.ammorate.NOTE .. '):'
          for _, l in ipairs(alines) do lines[#lines+1] = '  ' .. l end
        end
      else ammo_rows = {{error=tostring(rows)}} end
    end
    -- (B6) damage apart from reach, for the route asked or the schedule's next leg
    local conn = connection(pl, a)
    local dlines, drows
    if conn then
      dlines, drows = M.damage(force, turrets, conn)
      if #dlines > 0 then
        lines[#lines+1] = string.format('damage on %s (the asteroids that spawn there; apart from reach and arcs: a turret with an arc hits only what lies in it, as the collectors and sides above read):', conn.name)
        for _, l in ipairs(dlines) do lines[#lines+1] = '  ' .. l end
      end
    end
    local rows_out = {}
    for _, i in ipairs(pick.shown) do rows_out[#rows_out+1] = trows[i] end
    return {platform=pl.name, lines=lines, collectors=collectors, sides=side_rows, turrets=rows_out, turrets_page=pick.page_info, lines_of_fire=fire_rows, lines_page=lpage, feed=feed, destroyed_by_ours=#own_rows > 0 and own_rows or nil,
      route=conn and conn.name or nil, damage=drows and #drows > 0 and drows or nil, ammo_use=ammo_rows and #ammo_rows > 0 and ammo_rows or nil,
      kinds=kinds, planned=planned, note='a turret reaches what lies within its attack range of its centre and past its minimum range, and a turret whose base has a direction (railgun-turret: 72 degrees) only within its arc centred on its facing (outside_arc: in range, not counted); it engages what its priority list allows (ignore unprioritised targets on: only those listed), by size: small, medium, big, huge, each covered where every kind of that size (kinds) is engaged by a turret reaching it; a collector\'s front is the middle of its collection area; the hull\'s edge tiles are foundation tiles with empty space beside them'}
  end
  M.schema = {platform_defense = {page='optional 1..: the turrets and feed.turrets rows 64 a page (turrets_page {page, pages, per_page, total (picked), returned, turrets (read), capped (the find\'s limit, when reached), from, to, next, filter}); the collectors\', sides\' and feed\'s summaries read every turret',names='optional 1..16 turret prototype names (or one): only their rows (a filter on the rows only)',positions='optional 1..64 {x, y}: only the turrets within 1 tile of them (with names: either)',railguns_only='optional true: of those, only the turrets whose shots are a line (railgun-turret)',line_page='optional 1..: the lines of fire of the picked turrets whose shots are a line, 16 a page (lines_page {page, pages, per_page, total, returned, from, to, next, filter, clear (hit none of ours), hitting, hit (entities of ours hit), cut (read only part of the entities near the arc), unread}; lines_of_fire [{name, position, facing, engages, line, hit, ghosts, cut, entities [{name, count, positions}], destroyed_ours, unread}]; a turret row whose line is on another line page: line_page)',asteroids='optional true: an asteroid watch on that platform instead (d22 batch82 AR1; asteroidwatch.lua): with seconds (10..1800) it starts one, without it reads yours',seconds='with asteroids: 10..1800, how long to watch',reason='with asteroids: optional text, up to 200 characters: your own reason to wait for it',planned='optional true: the planned defense apart from the built one (planned {note, built_turrets, turret_ghosts, ghosts_by_name, ghosts [{name, position, facing, arc_degrees, range, min_range, engages, unarmed}] (the ghosts with an arc, up to 16), collectors [{position, ghost, covered_by, ghosts, uncovered (sizes no built or planned turret reaches), ghost_only (sizes only ghosts reach), outside_arc}], sides [{side, edge_tiles, uncovered, gaps, by_size {size: {uncovered, gaps, ghost_only, ghost_gaps (covered only by turret ghosts)}}}] with sides_as_of, foundation_tiles and foundation_ghosts: the hull read in the background (a few seconds; kept 30 s; until then sides_pending), and lines beginning planned:): our turret ghosts with the built turrets, each by its prototype\'s range, minimum range and arc by its facing (railgun-turret 72 degrees) and the priority list it carries, on the hull with our foundation tile ghosts, collectors built and planned; a ghost holds no ammunition and draws no power: planned cover is reach alone',ammo_use='optional: default the ammo turrets aboard with each ammunition they hold and the hub\'s of their categories; "all": every ammo turret with every ammunition of its categories too (normal quality); false: none. ammo_use [{turret, quality, turrets, ammo, ammo_quality, where held|hub|any, category, cooldown_ticks (the turret\'s cooldown x the ammunition\'s cooldown modifier over 1 + shooting_speed_bonus), base_cooldown_ticks, shooting_speed_bonus, shots_per_min, rounds_per_shot, magazine_size, items_per_shot, items_per_min (one turret), items_per_min_all (the turrets counted), damage_per_shot, damage {type: amount} (the ammunition\'s x quality_multiplier x (1 + damage_bonus) x (1 + turret_attack_bonus), before resistances), damage_bonus, turret_attack_bonus, quality_multiplier, sources {shooting_speed, damage, turret_attack}: the technologies and levels researched, and any part not from research, line}]: at full fire, one target in reach',route='optional "FROM->TO" (planets) or a space connection name; default the schedule\'s next leg (or the connection it flies): damage per asteroid that spawns there: its health and resistances, per turret and the ammo it holds now the damage a second after them against its listed damage, together and the time to kill one; under 10% of listed: reached, little damage (damage [{asteroid, hp, dps, kill_s, little}], lines)',platform='platform name', feed='optional true: every turret\'s way to its ammunition (default: those low, under 10 that can reach them, or stopped)',
    returns='cover is per asteroid size (small, medium, big, huge): a turret engages what its priority list allows (ignore unprioritised targets on: only those listed; every turret, asteroid and ammo prototype has the same target mask) and reaches within its range and past its minimum range, a turret whose base has a direction (railgun-turret) only within its arc (turn_range, 72 degrees, centred on its facing; turrets rows: facing, arc_degrees; a collector in range of one but outside its arc: outside_arc [{name, position, facing, arc_degrees, off_degrees}], not counted) (a rocket turret: 15 tiles); a size is covered where every kind of it (kinds: metallic, carbonic, oxide, promethium when a turret lists one) is engaged by a turret reaching it. lines: each asteroid collector\'s front (the middle of its collection area) with the turrets whose range reaches it (by size: turrets engaging that size, none for the kinds no turret engages; each turret\'s ammo, what it engages, fed by: an inserter and its source, robots, or nothing: by hand), or NO turret with the nearest and how far past its range; each hull side (north, east, south, west: foundation tiles with empty space on that side) with, per size, the edge tiles no turret engaging it reaches as runs, the longest first; by their priority lists: the turrets engaging only part of the asteroids; the turrets (empty, fed by hand); then the ammunition: what can reach a turret (turrets, the belts on their ways, sources, the hub when an inserter takes from it toward one) against what is stranded (on belts no turret\'s way reaches, by group with their area), and each turret low or stopped: what it holds, what can reach it (each inserter and its way: the hub, a chest or machine, or a belt with the ammo on the belts upstream and who puts items on them) and what stops it (STOPPED: no feeder, a filter leaving its ammo out, belts nothing feeds: dry after what is on them), apart from what is held off now (NOW: an inserter or belt its circuit or logistic condition holds off, gated closed now, with its condition and the values on its wires; the route through it is traced on to its source, and what waits behind it is counted as behind a link gated closed now, not as reaching). Every turret\'s reach in one line (ammunition that can reach each turret), and per stranded group the belts holding it (most first) and the call that would recover it: pickup {belt, area} when your character stands on that surface, else deconstruct {platform, area, entity_types: the belts} (the hub takes the belts and the items on them; the other belts of ours in that area named), and whether the hub\'s ammunition reaches a turret. feed {reaches, stranded, stranded_groups, stranded_recover [{count, belts, area, other_belts_in_area}], hub_reaches, via_hub (ammo on belts running back into the hub, counted as reaching when the hub feeds a turret), at_end and at_end_rows (ammo on a belt ending just past a pickup on a turret\'s way: not stranded), turrets [{position, holds, reaches, stopped, gated (a link on its way gated closed now), behind_gate (its ammo waiting behind such a link), replenished (what refills its way, through a gated link too: maker, a machine aboard making ammunition it takes; hub; chest, chests only; preload, no route to a source; none, no inserter feeds it), replenished_gated (every source of that kind is behind a link gated closed now)}], gates [{name, position, condition, turrets}] (each link gated closed now on a turret\'s way), lines (with replenishment by turret, the links gated closed now, wrong ammunition on turrets\' ways, and inserters whose circuit sets more filters than their slots)}. collectors [{position, front, covered_by, by_size {size: {covered, turrets, missing}}, armed_by and by_size_armed (when a turret reaching it is not armed now: no ammo, energy or fluid)}], sides [{side, edge_tiles, uncovered (a size not covered), gaps, by_size {size: {uncovered, gaps, unarmed_only, unarmed_gaps (covered by reach only by turrets not armed now)}}}], turrets [{name, position, range, min_range, engages, ammo, armed, unarmed, feed, destroyed_ours}], kinds; destroyed_by_ours [{name, position, destroyed, loss, ago_s}]: what turrets of ours destroyed here, per turret (the loss incidents kept, apart from asteroid hits). Read only'}}
  return M
end
