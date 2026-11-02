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
  -- Shared box/wedge predicate for existing and proposed entities; preserves the radial sampling rule.
  function M.intersects(c, pos, direction, name, target_name, q, bb)
    local face = (direction or 0) / 16 * 2 * math.pi
    local half = c.arc * math.pi
    local w = c.width / 2
    local x0, y0, x1, y1 = bb.left_top.x - w - pos.x, bb.left_top.y - w - pos.y, bb.right_bottom.x + w - pos.x, bb.right_bottom.y + w - pos.y
    local same = target_name == name and math.abs(q.x - pos.x) < 1 and math.abs(q.y - pos.y) < 1
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
    return hit
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
        local hit = M.intersects(c, pos, direction, name, e.type == 'entity-ghost' and e.ghost_name or e.name, q, bb)
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
  -- Proposed footprints only: no entities, ghosts, watches or background jobs are created.
  M.PROPOSED_MAX, M.RAIL_MAX = 8, 64
  local DIRECTIONS = {}
  for d, word in pairs(COMPASS) do DIRECTIONS[word] = d end
  local COS, SIN = {[0]=1,[4]=0,[8]=-1,[12]=0}, {[0]=0,[4]=1,[8]=0,[12]=-1}
  local function finite(v) return type(v) == 'number' and v == v and math.abs(v) < math.huge end
  function M.proposed(surface, force, entries)
    assert(type(entries) == 'table' and #entries > 0 and #entries <= M.PROPOSED_MAX,
      'planned_entities: 1..8 {name, position, direction?}')
    for k in pairs(entries) do
      assert(type(k) == 'number' and k % 1 == 0 and k >= 1 and k <= #entries, 'planned_entities: a dense array')
    end
    local rows, boxes = {}, {}
    for i = 1, #entries do
      local e = entries[i]
      assert(type(e) == 'table', 'planned_entities: each entry is a table')
      local pr = type(e.name) == 'string' and prototypes.entity[e.name]
      assert(pr and pr.type ~= 'entity-ghost' and pr.type ~= 'tile-ghost', 'planned_entities: unknown or ghost prototype')
      local q = e.position
      local x, y = type(q) == 'table' and (q.x or q[1]), type(q) == 'table' and (q.y or q[2])
      assert(finite(x) and finite(y) and math.abs(x) <= 1000000 and math.abs(y) <= 1000000,
        'planned_entities: position has finite x,y within +/-1000000')
      local d = e.direction == nil and 0 or e.direction
      if type(d) == 'string' then d = DIRECTIONS[d] end
      assert(finite(d) and d % 1 == 0 and d >= 0 and d <= 15, 'planned_entities: direction is 0..15 or a compass name')
      if pr.supports_direction == false then d = 0 end
      local b = pr.collision_box
      assert(b, 'planned_entities: prototype has no collision box')
      local a = d * math.pi / 8
      local cs, sn = COS[d] or math.cos(a), SIN[d] or math.sin(a)
      local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
      for _, p in ipairs({b.left_top, {x=b.right_bottom.x,y=b.left_top.y}, b.right_bottom, {x=b.left_top.x,y=b.right_bottom.y}}) do
        local rx, ry = p.x * cs - p.y * sn + x, p.x * sn + p.y * cs + y
        x0, y0, x1, y1 = math.min(x0,rx), math.min(y0,ry), math.max(x1,rx), math.max(y1,ry)
      end
      boxes[i] = {left_top={x=x0,y=y0},right_bottom={x=x1,y=y1}}
      rows[i] = {index=i, name=e.name, position={x=x,y=y}, direction=d, railguns={}}
    end
    -- One sentinel beyond the combined limit distinguishes exactly-full from truncated.
    local built = surface.find_entities_filtered{name='railgun-turret',force=force,limit=M.RAIL_MAX+1}
    local ghosts = {}
    if #built <= M.RAIL_MAX then
      ghosts = surface.find_entities_filtered{type='entity-ghost',ghost_name='railgun-turret',force=force,limit=M.RAIL_MAX+1-#built}
    end
    local capped = #built + #ghosts > M.RAIL_MAX
    local rails = {}
    local c = assert(M.arc('railgun-turret'), 'railgun-turret has no line ammunition')
    for _, group in ipairs({built,ghosts}) do
      for _, t in ipairs(group) do
        if #rails >= M.RAIL_MAX then break end
        rails[#rails+1] = {index=#rails+1, name='railgun-turret', position=t.position, direction=t.direction,
          ghost=t.type == 'entity-ghost', unit_number=t.unit_number}
      end
    end
    -- Cheap necessary conditions before the shared corner/ray test. Each wedge edge defines a half-plane;
    -- reject only when the entire expanded box is outside one, or its nearest point is past the shot's reach.
    local edges = {}
    for j,t in ipairs(rails) do
      local face, half = t.direction * math.pi / 8, c.arc * math.pi
      edges[j] = {math.cos(face-half), math.sin(face-half), -math.cos(face+half), -math.sin(face+half)}
    end
    local hits, matched, matched_index = 0, {}, {}
    for _, row in ipairs(rows) do
      for j, t in ipairs(rails) do
        local b, w, e = boxes[row.index], c.width/2, edges[j]
        local x0, y0 = b.left_top.x-w-t.position.x, b.left_top.y-w-t.position.y
        local x1, y1 = b.right_bottom.x+w-t.position.x, b.right_bottom.y+w-t.position.y
        local nx, ny = math.max(x0,math.min(0,x1)), math.max(y0,math.min(0,y1))
        local near = nx*nx+ny*ny <= c.reach*c.reach
        local wedge = c.arc > .5 or
          ((e[1]*(e[1]>=0 and x1 or x0)+e[2]*(e[2]>=0 and y1 or y0) >= -1e-9) and
           (e[3]*(e[3]>=0 and x1 or x0)+e[4]*(e[4]>=0 and y1 or y0) >= -1e-9))
        if near and wedge and M.intersects(c,t.position,t.direction,t.name,row.name,row.position,b) then
          if not matched_index[j] then
            matched[#matched+1], matched_index[j] = t, #matched+1
            t.index = #matched
          end
          row.railguns[#row.railguns+1] = matched_index[j]
        end
      end
      row.complete, row.capped = not capped, capped
      if #row.railguns > 0 then hits = hits + 1 end
    end
    return {entities=rows, railguns=matched, railguns_checked=#rails, complete=not capped, capped=capped,
      limits={proposed_entities=M.PROPOSED_MAX,railguns=M.RAIL_MAX}, corridor=c,
      note='Geometry only: rotated collision-box envelopes and the existing box/wedge rule (17 rays at radial boundaries; same-turret and origin-containing boxes excluded). Diagonal envelopes can overstate footprints. complete means all existing built and ghost railguns tested. Proposed railguns are not sources. No ammo, target-filter, placement or damage check.',
      lines={string.format('proposed rail corridors: %d entities, %d existing railguns; %d entities intersect; complete=%s, capped=%s',#rows,#rails,hits,tostring(not capped),tostring(capped))}}
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
