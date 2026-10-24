-- A railgun's line of fire over our own entities (d17 batch31 B3; Astra: big asteroids enabled behind Kestrel II's bow,
-- the shots broke an ammo belt; Nick 07:10: placing a railgun shows every structure of ours it would shoot in red).
-- The rule, from the 2.0.77 prototypes: a turret whose base has a direction aims within its attack_parameters'
-- turn_range (a share of a full turn: railgun-turret 0.2, 72 degrees) centred on its facing, at targets up to its range
-- (40). Its ammunition's action is a line (railgun-ammo: 50 tiles long, 1 wide, from the shot's start 3.6 tiles out,
-- projectile_creation_distance) that damages every entity it crosses, ours too. So an entity of ours with health whose
-- box such a line can cross, at any bearing of the arc, is hit when the turret fires along that bearing. Ghosts take no
-- damage: they are named apart (hit once built). Read only; at most FIND entities looked at.
return function(api)
  local M = {}
  local FIND, NAMED, MARGIN = 2048, 12, 6
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function at(q) return string.format('(%g,%g)', math.floor(q.x * 10 + 0.5) / 10, math.floor(q.y * 10 + 0.5) / 10) end
  local COMPASS = {[0]='north', [2]='northeast', [4]='east', [6]='southeast', [8]='south', [10]='southwest', [12]='west', [14]='northwest'}
  -- The longest line any ammunition of the categories takes: {range, width}, or nil when none is a line.
  local function line_of(categories)
    local best
    for name, it in pairs(try(function() return prototypes.get_item_filtered{{filter='type', type='ammo'}} end) or {}) do
      local at_ = try(function() return it.get_ammo_type() end)
      if at_ and categories[at_.category or try(function() return it.ammo_category.name end) or ''] then
        for _, act in ipairs(at_.action or {}) do
          if act.type == 'line' and (not best or (act.range or 0) > best.range) then best = {range=act.range or 0, width=act.width or 1, ammo=name} end
        end
      end
    end
    return best
  end
  local arcs = {}
  -- A turret prototype's line of fire: {arc (share of a turn), range, start, reach, width, ammo}, or false when its shots
  -- are no line or it aims all round.
  function M.arc(name)
    local c = arcs[name]
    if c ~= nil then return c or nil end
    c = false
    local pe = try(function() return prototypes.entity[name] end)
    local ap = pe and try(function() return pe.attack_parameters end)
    if ap and (ap.turn_range or 1) < 1 then
      local cats = {}
      for _, k in ipairs(ap.ammo_categories or {}) do cats[k] = true end
      local line = line_of(cats)
      if line then
        local start = ap.projectile_creation_distance or 0
        c = {arc=ap.turn_range, range=ap.range or 0, start=start, reach=start + line.range, width=line.width, ammo=line.ammo}
      end
    end
    arcs[name] = c
    return c or nil
  end
  local atan2 = math.atan2 or math.atan
  local function wrap(x)
    while x > math.pi do x = x - 2 * math.pi end
    while x < -math.pi do x = x + 2 * math.pi end
    return x
  end
  -- A box (turret at the origin) straddling the shot's start or reach: whether a ray at some bearing a0..a1 crosses it
  -- between those distances (17 bearings; the slab test per ray).
  local function crosses(x0, y0, x1, y1, a0, a1, start, reach)
    for i = 0, 16 do
      local a = a0 + (a1 - a0) * i / 16
      local ux, uy = math.sin(a), -math.cos(a)
      local t0, t1 = start, reach
      for _, sl in ipairs({{ux, x0, x1}, {uy, y0, y1}}) do
        local u, lo, hi = sl[1], sl[2], sl[3]
        if math.abs(u) < 1e-9 then
          if lo > 0 or hi < 0 then t0, t1 = 1, 0 end
        else
          local ta, tb = lo / u, hi / u
          if ta > tb then ta, tb = tb, ta end
          t0, t1 = math.max(t0, ta), math.min(t1, tb)
        end
      end
      if t0 <= t1 then return true end
    end
    return false
  end
  -- Our entities a turret of name at pos facing direction (0..15) would hit: {hits, ghosts, line, ...}, or nil when its
  -- shots are no line. skip: the turret itself (an entity); one of that name (or its ghost) within a tile of pos is it too.
  function M.hits(surface, force, name, pos, direction, skip)
    local c = M.arc(name)
    if not c then return nil end
    local face = (direction or 0) / 16 * 2 * math.pi
    local half = c.arc * math.pi
    -- the find: the arc's own box (its two edges at the reach, a compass point inside it, the turret), MARGIN wider
    local bx0, by0, bx1, by1 = 0, 0, 0, 0
    local function grow(a, r) local x, y = math.sin(a) * r, -math.cos(a) * r; bx0, by0, bx1, by1 = math.min(bx0, x), math.min(by0, y), math.max(bx1, x), math.max(by1, y) end
    grow(face - half, c.reach); grow(face + half, c.reach)
    for k = 0, 3 do if math.abs(wrap(k * math.pi / 2 - face)) <= half then grow(k * math.pi / 2, c.reach) end end
    local found = try(function()
      return surface.find_entities_filtered{area={{pos.x + bx0 - MARGIN, pos.y + by0 - MARGIN}, {pos.x + bx1 + MARGIN, pos.y + by1 + MARGIN}}, force=force, limit=FIND}
    end) or {}
    local hits, ghosts, by, gby = {}, {}, {}, {}
    for _, e in ipairs(found) do
      -- by its centre first (an entity's box is at most MARGIN from it), its box only then
      local q = e.position
      local dx, dy = q.x - pos.x, q.y - pos.y
      local d = math.sqrt(dx * dx + dy * dy)
      local near_arc = d <= MARGIN or (d - MARGIN <= c.reach and math.abs(wrap(atan2(dx, -dy) - face)) <= half + math.asin(MARGIN / d))
      if near_arc and e ~= skip and e.type ~= 'character' then
        local bb = e.bounding_box
        local w = c.width / 2
        local x0, y0, x1, y1 = bb.left_top.x - w - pos.x, bb.left_top.y - w - pos.y, bb.right_bottom.x + w - pos.x, bb.right_bottom.y + w - pos.y
        local same = (e.type == 'entity-ghost' and e.ghost_name or e.name) == name and math.abs(dx) < 1 and math.abs(dy) < 1
        -- its box (widened by half the line) against the arc: the bearings of its corners from the turret (north 0,
        -- clockwise) against the facing, and its nearest and farthest points against the shot's start and reach
        local lo, hi, far = math.huge, -math.huge, 0
        for _, k in ipairs({{x0, y0}, {x1, y0}, {x0, y1}, {x1, y1}}) do
          local off = wrap(atan2(k[1], -k[2]) - face)
          if off < lo then lo = off end
          if off > hi then hi = off end
          far = math.max(far, math.sqrt(k[1] ^ 2 + k[2] ^ 2))
        end
        local nx, ny = math.max(x0, math.min(0, x1)), math.max(y0, math.min(0, y1))
        local near = math.sqrt(nx * nx + ny * ny)
        local inside = x0 <= 0 and x1 >= 0 and y0 <= 0 and y1 >= 0
        local hit = not same and not inside and hi - lo < math.pi and hi >= -half and lo <= half and near <= c.reach and far >= c.start
        if hit and (near < c.start or far > c.reach) then hit = crosses(x0, y0, x1, y1, math.max(lo, -half) + face, math.min(hi, half) + face, c.start, c.reach) end
        if hit then
          local ghost = e.type == 'entity-ghost' or e.type == 'tile-ghost'
          local nm = ghost and e.ghost_name or e.name
          if ghost then
            if e.type == 'entity-ghost' then
              if not gby[nm] then gby[nm] = {}; ghosts[#ghosts+1] = nm end
              table.insert(gby[nm], q)
            end
          elseif e.is_entity_with_health then
            if not by[nm] then by[nm] = {}; hits[#hits+1] = nm end
            table.insert(by[nm], q)
          end
        end
      end
    end
    local function words(order, map)
      table.sort(order, function(x, y) if #map[x] ~= #map[y] then return #map[x] > #map[y] end return x < y end)
      local parts, n = {}, 0
      for _, nm in ipairs(order) do
        local list = map[nm]
        local spots = {}
        for i = 1, math.min(#list, 3) do spots[i] = at(list[i]) end
        parts[#parts+1] = string.format('%d %s %s%s', #list, nm, table.concat(spots, ' '), #list > 3 and ' ...' or '')
        n = n + #list
        if #parts >= NAMED then break end
      end
      local total = 0
      for _, nm in ipairs(order) do total = total + #map[nm] end
      return table.concat(parts, ', ') .. (#order > NAMED and ', ...' or ''), total
    end
    local hit_text, hit_n = words(hits, by)
    local ghost_text, ghost_n = words(ghosts, gby)
    local head = string.format('%s %s facing %s aims within %g degrees of its facing (%g in all) at targets up to %g tiles; its shots (%s: a line %g wide to %g tiles from its centre) hit',
      name, at(pos), COMPASS[direction or 0] or tostring(direction), math.floor(c.arc * 180 + 0.5), math.floor(c.arc * 360 + 0.5), c.range, c.ammo, c.width, c.reach)
    local line
    if hit_n == 0 and ghost_n == 0 then line = head .. ' none of ours'
    else
      line = head .. (hit_n > 0 and string.format(' %d of ours: %s', hit_n, hit_text) or ' none of ours built')
        .. (ghost_n > 0 and string.format('; %d ghosts of ours there, hit once built: %s', ghost_n, ghost_text) or '')
    end
    if #found >= FIND then line = line .. string.format(' (cut: the first %d entities near its arc read, more there not read)', FIND) end
    local rows = {}
    for _, nm in ipairs(hits) do rows[#rows+1] = {name=nm, count=#by[nm], positions=by[nm]} end
    return {line=line, hit=hit_n, ghosts=ghost_n > 0 and ghost_n or nil, entities=rows, cut=#found >= FIND or nil}
  end
  -- The same for a built turret or its ghost.
  function M.of(e)
    if not (e and e.valid) then return nil end
    local name = e.type == 'entity-ghost' and e.ghost_name or e.name
    if not M.arc(name) then return nil end
    return M.hits(e.surface, e.force, name, e.position, e.direction, e)
  end
  return M
end
