-- routecheck: a walk's route read before walking (Haiku, shift18 22:16: a 500-tile move_to with avoid_enemies
-- {distance: 12} passed big worms whose range is 38, and she died; Luna walked into an enclosed core twice). move_to and
-- walking tours with dry_run: true. Read now, without the engine's pathfinder (its answer comes ticks later):
--   route: straight lines from you through the via points or stops to the goal, round the worms and spawners the map
--     shows as a walk plans its legs (avoid.lua detour), its length in tiles;
--   enemies: each worm and spawner within reach of that route, its closest pass (distance, where) and its range;
--   closed_in: the start or the goal in an area the character's box gets out of nowhere within 24 tiles (pathing.lua
--     region), and for a goal so closed the fewest of our entities, trees or rocks to mine for a way in (pathing.lua dig);
--   under_range (avoid_enemies {distance: N}): the worms on the route whose range is more than N (also on a live move_to).
return function(api)
  local M = {}
  local A, P = api.avoid, api.pathing
  -- Cost caps, measured on a copy of world n (d15 batch3; private 2.0.77 server, x86 emulated, where a brief status
  -- costs 13-19 ms): a cold chunk read is about 0.06 ms; avoid.lua's detour grows with the discs it is given (a
  -- 12-stop tour planned against every disc on its 2,600 tiles took 1.4 s). So: CHUNKS chunks read a call (the rest
  -- named, read by the next call: they are kept a minute), each leg planned against the nests near it only, and a leg
  -- with more than LEG_DISCS discs near it, or past PLANNED_LEGS legs, read as a straight line (named).
  local MAX_CHUNKS, SHOW, LIVE_CHUNKS, LEG_DISCS, PLANNED_LEGS, NEAR_LEG, ALL_DISCS = 128, 8, 64, 72, 16, 48, 72
  local function dist(a, b) return ((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2) ^ 0.5 end
  local function at(q) return string.format('(%g,%g)', math.floor(q.x + 0.5), math.floor(q.y + 0.5)) end
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local POCKET_STEP, POCKETS = 8, 24
  -- The nearest point of segment a-b to q.
  local function nearest_on(a, b, q)
    local dx, dy = b.x - a.x, b.y - a.y
    local l2 = dx * dx + dy * dy
    local t = l2 > 0 and math.max(0, math.min(1, ((q.x - a.x) * dx + (q.y - a.y) * dy) / l2)) or 0
    return {x=a.x + t * dx, y=a.y + t * dy}
  end
  local function closest(route, q)
    local best, bp
    for i = 1, #route - 1 do
      local n = nearest_on(route[i], route[i + 1], q)
      local d = dist(n, q)
      if not best or d < best then best, bp = d, n end
    end
    if #route == 1 then return dist(route[1], q), route[1] end
    return best, bp
  end
  -- The worms and spawners the map shows near the points: {blobs, unread}. budget: chunks read now at most.
  local function hazards(p, points, budget)
    local surface = p.surface
    local mode = {spawners=true, attacks=true, pad=0}
    local chunks = A.chunks_near(points, 48)
    local missing = A.missing(surface, chunks)
    local unread = math.max(0, #missing - budget)
    A.scan(surface, p.force, missing, budget)
    return A.blobs(surface, chunks, mode), unread
  end
  -- Each structure (worm, spawner) and area under attack within reach of the route: closest pass, range, rows sorted by
  -- how far outside its range the route passes (inside first).
  local function enemies(route, blobs)
    local rows = {}
    for _, b in ipairs(blobs) do
      for _, m in ipairs(b.members) do
        local d, q = closest(route, m)
        if m.attack then
          if d <= m.range + 16 then
            rows[#rows+1] = {d=d, q=q, range=m.range, over=d - m.range, attack=true, x=m.x, y=m.y,
              text=m.group and string.format('%s at %s, seen now (%d tiles): closest pass %.0f tiles at %s', m.name, at(m), m.range, d, at(q))
                or string.format('area under attack now round %s (%d tiles): closest pass %.0f tiles at %s', at(m), m.range, d, at(q))}
          end
        else
          local range = A.reach(m.name, m.spawner)
          if m.spawner then range = math.max(range, A.SPAWNER_REACH) end
          if d <= range + 16 then
            rows[#rows+1] = {d=d, q=q, range=range, over=d - range, name=m.name, spawner=m.spawner, x=m.x, y=m.y,
              text=string.format('%s %s %s %d: closest pass %.0f tiles at %s%s', m.name, at(m), m.spawner and 'its units come' or 'range', range, d, at(q),
                d < range and string.format(' (%.0f inside it)', range - d) or '')}
          end
        end
      end
    end
    table.sort(rows, function(a, b) if a.over ~= b.over then return a.over < b.over end return a.text < b.text end)
    return rows
  end
  -- The worms on the route whose range is more than N (avoid_enemies {distance: N}).
  local function under(rows, mode)
    if not (mode and mode.distance) then return nil end
    local out = {}
    for _, r in ipairs(rows) do
      if not r.attack and not r.spawner and r.range > mode.distance and r.d <= r.range + 16 then
        out[#out+1] = string.format('%s %s range %d is more than distance %g; the route passes %.0f tiles from it', r.name, at(r), r.range, mode.distance, r.d)
      end
    end
    if #out == 0 then return nil end
    local n = #out
    while #out > SHOW do table.remove(out) end
    if n > SHOW then out[#out+1] = (n - SHOW) .. ' more' end
    return out
  end
  -- The route as a walk plans it: straight lines through the points, round the discs (avoid.lua detour); a disc that
  -- holds a leg's start or end is not gone round (a walk goes there).
  local function plan(points, blobs, mode)
    local route, corners, no_way, straight, used = {points[1]}, 0, nil, {}, 0
    for i = 2, #points do
      local a, b = route[#route], points[i]
      local vias = {}
      if mode then
        -- the nests near this leg only
        local mblobs, discs = {}, 0
        for _, bl in ipairs(blobs) do
          if dist(nearest_on(a, b, bl), bl) <= bl.r + NEAR_LEG then mblobs[#mblobs+1] = bl; discs = discs + #bl.members end
        end
        if discs > LEG_DISCS or (i - 1 > PLANNED_LEGS and discs > 0) or (discs > 0 and used + discs > ALL_DISCS) then
          straight[#straight+1] = string.format('leg %d (%d discs near it)', i - 1, discs)
        elseif discs > 0 then
          used = used + discs
          local skip = {}
          for bi, bl in ipairs(mblobs) do
            for _, m in ipairs(bl.members) do if dist(m, a) < m.r or dist(m, b) < m.r then skip[bi] = true end end
          end
          vias = A.detour(a, b, mblobs, skip)
          if vias == nil then no_way = no_way or i - 1; vias = {} end
        end
      end
      for _, v in ipairs(vias) do
        if dist(v, b) > 0.01 then corners = corners + 1 end
        route[#route+1] = {x=v.x, y=v.y}
      end
      if #vias == 0 or dist(route[#route], b) > 0.01 then route[#route+1] = {x=b.x, y=b.y} end
    end
    return route, corners, no_way, straight
  end
  local function length(route)
    local n = 0
    for i = 2, #route do n = n + dist(route[i - 1], route[i]) end
    return n
  end
  -- Closed in at a point: {closed, text, mine?}.
  local function closed_at(p, q, goal)
    local c = p.character
    if not (c and P and P.region) then return nil end
    local half = P.half(c)
    local r = try(function() return P.region(p.surface, q, half, {ignore=c, force=p.force, search=4}) end)
    if not (r and r.closed) then return nil end
    -- No spot the character's box fits within a tile of it (deep water, a building): no flood, no dig.
    if r.stuck then
      local tile = try(function() return p.surface.get_tile(math.floor(q.x), math.floor(q.y)).name end)
      return {stuck=true, text=string.format('no spot the character stands on within a tile of %s (the tile there: %s)', at(q), tile or 'unknown')}
    end
    local out = {text=P.area_text and P.area_text(r, half) or 'closed in'}
    if goal and P.dig then
      local d = try(function() return P.dig(p.surface, q, half, {ignore=c, force=p.force}) end)
      if d and d.mine then
        local list = {}
        -- from outside in: the first met walking toward the goal first
        for k = #d.mine, 1, -1 do
          local m = d.mine[k]
          list[#list+1] = string.format('%s %s', m.name, at(m.position))
          if #list >= SHOW then break end
        end
        out.mine = list
      end
    end
    return out
  end
  -- The whole read. points: {start, via..., goal}; mode: avoid.mode(...) or nil (avoid_enemies false).
  function M.check(p, points, mode)
    local blobs, unread = hazards(p, points, MAX_CHUNKS)
    local mblobs = blobs
    if mode then mblobs = A.blobs(p.surface, A.chunks_near(points, 48), mode) end
    local route, corners, no_way, straight = plan(points, mblobs, mode)
    local rows = enemies(route, blobs)
    local out = {dry_run=true}
    local len, straight_len = length(route), length(points)
    out.route = string.format('%.0f tiles in straight lines%s%s (the engine\'s path bends round buildings, water and cliffs: longer)',
      len, #points > 2 and string.format(' through %d stops or via points', #points - 2) or '',
      corners > 0 and string.format(', %d corner%s round worms and spawners (%.0f tiles straight)', corners, corners == 1 and '' or 's', straight_len) or '')
    out.length = math.floor(len + 0.5)
    if #straight > 0 then
      out.not_planned_round = string.format('read as straight lines, not planned round the nests (over %d discs near a leg, %d in all, or past leg %d): %s',
        LEG_DISCS, ALL_DISCS, PLANNED_LEGS, table.concat(straight, ', ', 1, math.min(6, #straight)) .. (#straight > 6 and string.format(' +%d more', #straight - 6) or ''))
    end
    if no_way then out.no_way_round = string.format('leg %d: no way round the worms and spawners at these margins', no_way) end
    local list = {}
    for i = 1, math.min(SHOW, #rows) do list[i] = rows[i].text end
    if #rows > SHOW then list[#list+1] = (#rows - SHOW) .. ' more' end
    out.enemies = #list > 0 and list or nil
    out.enemies_none = #rows == 0 and 'no worm, spawner, area under attack or enemy group seen now within reach of the route' or nil
    out.under_range = under(rows, mode)
    if unread > 0 then
      out.unread_chunks = string.format('%d chunks along the route not read (%d a call; the farthest from you): their worms and spawners are not listed; the chunks read are kept a minute, so the same dry run again reads the next ones', unread, MAX_CHUNKS)
    end
    local start = closed_at(p, points[1], false)
    local goal = closed_at(p, points[#points], true)
    -- Pockets along the whole route (C7, Opus 13:51: boxed in by trees mid-route at (347,-187) and killed): each via
    -- point, and points on the straight legs every POCKET_STEP tiles (at most POCKETS), read as at the ends.
    local pockets, looked = {}, 0
    for i = 2, #route do
      local a0, b0 = route[i - 1], route[i]
      local L = dist(a0, b0)
      local steps = math.floor(L / POCKET_STEP)
      for j = 1, steps do
        if looked >= POCKETS then break end
        local q = {x=a0.x + (b0.x - a0.x) * j / (steps + 1), y=a0.y + (b0.y - a0.y) * j / (steps + 1)}
        looked = looked + 1
        local c = closed_at(p, q, false)
        if c and not c.stuck then pockets[#pockets+1] = string.format('%s on leg %d: %s', at({x=math.floor(q.x * 10 + 0.5) / 10, y=math.floor(q.y * 10 + 0.5) / 10}), i - 1, c.text) end
      end
      if i < #route and looked < POCKETS then
        looked = looked + 1
        local c = closed_at(p, b0, false)
        if c and not c.stuck then pockets[#pockets+1] = string.format('%s (a corner or via point): %s', at(b0), c.text) end
      end
    end
    if #pockets > 0 then
      out.closed_in_on_route = {}
      for i = 1, math.min(SHOW, #pockets) do out.closed_in_on_route[i] = pockets[i] end
      if #pockets > SHOW then out.closed_in_on_route[#out.closed_in_on_route+1] = (#pockets - SHOW) .. ' more' end
    end
    out.route_points_checked = looked > 0 and string.format('%d points on the route checked for pockets (every %d tiles, at most %d)', looked, POCKET_STEP, POCKETS) or nil
    if no_way and A and A.via_round then
      local v = try(function() return A.via_round(p, points[1], points[#points], mode) end)
      if v then out.via_round = v.text; out.via_point = v.via end
    end
    if start then out.closed_in_start = 'where you stand: ' .. start.text end
    if goal then
      out.closed_in_goal = 'the goal: ' .. goal.text
      out.mine_for_a_way_in = goal.mine
    end
    out.reachable = goal and goal.stuck and 'no: no spot to stand at the goal'
      or (start or goal) and 'no: closed in' .. (start and ' where you stand' or '') .. (start and goal and ' and' or '') .. (goal and ' at the goal' or '')
      or no_way and 'no way round the worms and spawners at these margins'
      or 'not closed in at either end within 24 tiles (the engine\'s path is not asked for: water or cliffs can still keep it out)'
    return out
  end
  -- A live move_to with avoid_enemies {distance: N}: the worms on its straight route whose range is more than N, from
  -- chunks read now (at most LIVE_CHUNKS).
  function M.under_live(p, points, mode)
    if not (mode and mode.distance) then return nil end
    local blobs = hazards(p, points, LIVE_CHUNKS)
    return under(enemies(points, blobs), mode)
  end
  return M
end
