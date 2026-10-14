-- pathing: the engine pathfinder for the character's walks (move_to, and
-- the walks of construct, build_path and gather tours). Shift08: Haiku's
-- move_to "stops at the boiler row 8-12,42 and the y=39.5 belt" five times,
-- and all 81 blocked walks of the shift had failed path requests, after which
-- the controller steered blind until 15 stalls (half a minute). World n: that
-- pocket is closed for the character's 0.4-tile box (the boiler and pipe row
-- leaves 0.22-tile gaps); the old fallback planned with a 0.3-tile box, which
-- does get out, so the walk pushed at gaps the character cannot pass.
-- Requests go up a ladder: a padded box on the tile grid (and the same
-- avoiding belts, kept when its detour is short), then the character's own
-- box from the nearest free tile centre, on the half-tile grid, and on the
-- quarter-tile grid with a wider goal. When none finds a route, the walk ends
-- at once as unreachable, saying why and the nearest point the character can
-- reach: a closed-in area is mapped (what closes it in), else a wide-radius
-- request finds where it can get to. A goal in an ungenerated chunk keeps the
-- old blind steering (the pathfinder knows only generated ground).
return function(api)
  local M = {}
  local BELTS = {'transport-belt', 'underground-belt', 'splitter', 'lane-splitter', 'loader', 'loader-1x1', 'linked-belt'}
  local BASE_BELTS = {'transport-belt', 'underground-belt', 'splitter'}
  local PAD, GRACE_TICKS = 0.15, 30
  -- The ladder: box padding, grid (path_resolution_modifier: 1 half tiles,
  -- 2 quarter tiles), start from the nearest free tile centre, extra goal radius.
  M.LEVELS = {
    {pad=PAD, res=0, avoid=true},
    {pad=0, res=0, centre=true},
    {pad=0, res=1},
    {pad=0, res=2, wide=3},
  }
  local function try(fn, ...) local ok, v = pcall(fn, ...); if ok then return v end end
  local function dist(a, b) return ((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2) ^ 0.5 end
  local function at(pos) return string.format('(%g,%g)', math.floor(pos.x * 10 + 0.5) / 10, math.floor(pos.y * 10 + 0.5) / 10) end
  M.at = at
  -- Half the character's box (0.2 for the vanilla character).
  function M.half(c)
    local b = try(function() return c.prototype.collision_box end)
    if not b then return 0.2 end
    local lt, rb = b.left_top or b[1], b.right_bottom or b[2]
    local h = 0
    for _, v in ipairs({lt.x or lt[1], lt.y or lt[2], rb.x or rb[1], rb.y or rb[2]}) do h = math.max(h, math.abs(v)) end
    return h > 0 and h or 0.2
  end
  -- The character's mask with belts as obstacles: a path off belts.
  local function off_belts(mask)
    local m = {layers={}}
    for k, v in pairs(mask and mask.layers or {}) do m.layers[k] = v end
    m.layers.transport_belt = true
    if mask then m.consider_tile_transitions = mask.consider_tile_transitions; m.colliding_with_tiles_only = mask.colliding_with_tiles_only; m.not_colliding_with_itself = mask.not_colliding_with_itself end
    return m
  end
  function M.length(path)
    local n = 0
    for i = 2, #(path or {}) do n = n + dist(path[i-1].position, path[i].position) end
    return n
  end
  -- One request; its id is noted so the result finds the walk.
  local function ask(p, nav, level, mask)
    local c = p.character
    local L = M.LEVELS[level + 1]
    local start = p.position
    if L.centre then start = try(function() return p.surface.find_non_colliding_position(c.name, p.position, 3, 0.5, true) end) or p.position end
    local h = M.half(c) + L.pad
    local id = p.surface.request_path{bounding_box={{-h, -h}, {h, h}}, collision_mask=mask or c.prototype.collision_mask, start=start,
      goal=nav.position, force=p.force, radius=nav.tolerance + 1 + (nav.replans or 0) + (L.wide or 0), entity_to_ignore=c, can_open_gates=true,
      -- finer grids take more steps: let the engine spread them over ticks
      pathfind_flags={prefer_straight_paths=true, no_break=L.res == 0, cache=false}, path_resolution_modifier=L.res ~= 0 and L.res or nil}
    local paths = api.paths()
    paths[id] = p.index
    nav.asked_from = start
    return id
  end
  -- Request the path for nav's level (0 when unset). The first level asks
  -- twice: as the character walks, and avoiding belts.
  function M.request(p, nav)
    local level = nav.path_level or 0
    nav.path_id = ask(p, nav, level)
    nav.avoid_id, nav.found, nav.avoided = nil, nil, nil
    if M.LEVELS[level + 1].avoid then nav.avoid_id = ask(p, nav, level, off_belts(p.character.prototype.collision_mask)); nav.found = {} end
    nav.path_state = 'pending'; nav.waypoints = nil; nav.waypoint = nil; nav.sidestep = nil; nav.asked_tick = game.tick
  end
  -- A belt path is replaced by the off-belt one when that is at most 6 tiles
  -- or a quarter longer.
  function M.prefer(normal, avoid)
    if normal and avoid then
      local ln, la = M.length(normal), M.length(avoid)
      if la <= ln + math.max(6, ln * 0.25) then return avoid, true end
      return normal, false
    end
    if avoid then return avoid, true end
    return normal, false
  end
  local function use(nav, path, avoided)
    nav.waypoints = path; nav.waypoint = 1; nav.path_state = 'found'; nav.avoided = avoided or nil
    nav.path_length = math.floor(M.length(path) + 0.5)
    nav.found = nil
  end
  -- A path ending no nearer the goal than it started (the start already
  -- inside a wide goal radius) is no route, unless it ends near the goal.
  function M.useless(nav, path)
    local e = path[#path].position
    local d = dist(e, nav.position)
    return d > nav.tolerance + 1.5 and d > dist(nav.asked_from or path[1].position, nav.position) - 1
  end
  -- A result for one of nav's requests. The walk's own path or the
  -- off-belt one; a failure climbs the ladder; at the top it gives up.
  function M.on_finished(p, nav, event)
    if nav.probe_id == event.id then return M.probed(p, nav, event) end
    local mine = event.id == nav.path_id and 'normal' or event.id == nav.avoid_id and 'avoid' or nil
    if not mine then return end
    local got = event.path
    if got and M.useless(nav, got) then got = nil end
    if mine == 'normal' then nav.paths_failed = (nav.paths_failed or 0) + (got and 0 or 1) end
    if nav.found then
      -- Both answers of the first level, or the grace time, decide.
      nav.found[mine] = got or false
      if event.try_again_later and mine == 'normal' then nav.found.busy = true end
      if nav.found.normal == nil or nav.found.avoid == nil then return end
      local f = nav.found
      local path, avoided = M.prefer(f.normal or nil, f.avoid or nil)
      if path then return use(nav, path, avoided) end
      if f.busy then nav.found = nil; nav.path_state = 'busy'; return end
      nav.found = nil
      return M.climb(p, nav)
    end
    if got then return use(nav, got) end
    if event.try_again_later then nav.path_state = 'busy'; return end
    return M.climb(p, nav)
  end
  -- The first level's second answer did not come within GRACE_TICKS: decide with what came.
  function M.grace(p, nav)
    local f = nav.found
    if not f or game.tick - (nav.asked_tick or game.tick) < GRACE_TICKS then return end
    local path, avoided = M.prefer(f.normal or nil, f.avoid or nil)
    if path then return use(nav, path, avoided) end
    if f.normal == false then nav.found = nil; return M.climb(p, nav) end
  end
  function M.climb(p, nav)
    local level = nav.path_level or 0
    if level + 1 < #M.LEVELS then
      nav.path_level = level + 1
      return M.request(p, nav)
    end
    return M.give_up(p, nav)
  end
  -- No level found a route. Ungenerated ground: steer blind as before.
  -- Else: closed in (mapped now), or ask once with a wide radius where the
  -- character can get to near the goal; the walk then ends as unreachable.
  function M.give_up(p, nav)
    local pos = nav.position
    local chunk = {x=math.floor(pos.x / 32), y=math.floor(pos.y / 32)}
    if try(function() return p.surface.is_chunk_generated(chunk) end) == false then
      nav.path_state = 'failed'; nav.blind = 'ungenerated'; return
    end
    local here = p.position
    local region = M.region(p.surface, here, M.half(p.character), {ignore=p.character, goal=pos})
    nav.region = region
    -- The goal inside the area it can reach: the grids missed a route, so steer.
    if region and region.closed and region.nearest and dist(region.nearest, pos) <= nav.tolerance + 1 then
      nav.path_state = 'failed'; nav.blind = 'no grid found a route inside the area it can reach'; return
    end
    if region and region.closed then
      nav.reachable = region.nearest
      nav.why = string.format('closed in: the character (%.1f tiles wide) fits through no gap out of the area %s-%s (about %d tiles)%s',
        M.half(p.character) * 2, at({x=region.x0, y=region.y0}), at({x=region.x1, y=region.y1}), region.tiles,
        #region.by > 0 and ('; around it: ' .. table.concat(region.by, ', ')) or '')
      nav.path_state = 'unreachable'
      return
    end
    -- Not closed in: one wide request says where it can get to.
    local c = p.character
    local h = M.half(c)
    local start = try(function() return p.surface.find_non_colliding_position(c.name, here, 3, 0.5, true) end) or here
    local radius = math.max(4, math.min(48, dist(here, pos) * 0.75))
    nav.probe_id = p.surface.request_path{bounding_box={{-h, -h}, {h, h}}, collision_mask=c.prototype.collision_mask, start=start, goal=pos,
      force=p.force, radius=radius, entity_to_ignore=c, can_open_gates=true, pathfind_flags={prefer_straight_paths=true, no_break=true, cache=false}}
    api.paths()[nav.probe_id] = p.index
    nav.probe_radius = radius
    nav.path_state = 'probing'
  end
  function M.probed(p, nav, event)
    nav.probe_id = nil
    local last = event.path and event.path[#event.path]
    nav.reachable = last and {x=last.position.x, y=last.position.y} or nil
    if nav.reachable then
      nav.why = string.format('no path for the character to %s on the tile, half- or quarter-tile grid', at(nav.position))
    else
      nav.why = string.format('no path for the character to %s, nor to anywhere within %d tiles of it', at(nav.position), math.floor(nav.probe_radius or 0))
    end
    nav.path_state = 'unreachable'
  end

  -- Where the character can get to from start (a flood over quarter-tile
  -- steps with its own box, belts walkable), within 24 tiles and 6000 steps.
  -- Closed: the steps ran out of room before the window edge or the cap;
  -- then the nearest step to goal, the area and what blocked the edge.
  local WINDOW, CAP, STEP = 24, 6000, 0.25
  function M.region(surface, start, half, opts)
    opts = opts or {}
    local area = {{start.x - WINDOW, start.y - WINDOW}, {start.x + WINDOW, start.y + WINDOW}}
    local boxes = {}
    for _, e in ipairs(try(function() return surface.find_entities_filtered{area=area, collision_mask='player'} end) or {}) do
      if e.valid and e ~= opts.ignore and e.type ~= 'character' then
        local b = e.bounding_box
        boxes[#boxes+1] = {b.left_top.x, b.left_top.y, b.right_bottom.x, b.right_bottom.y, e.name}
      end
    end
    for _, t in ipairs(try(function() return surface.find_tiles_filtered{area=area, collision_mask='player'} end) or {}) do
      boxes[#boxes+1] = {t.position.x, t.position.y, t.position.x + 1, t.position.y + 1, t.name}
    end
    -- Boxes by 2-tile bucket, each in every bucket its reach touches.
    local bucket = {}
    local function key(x, y) return math.floor(x / 2) * 65536 + math.floor(y / 2) end
    for _, b in ipairs(boxes) do
      for bx = math.floor((b[1] - half) / 2), math.floor((b[3] + half) / 2) do
        for by = math.floor((b[2] - half) / 2), math.floor((b[4] + half) / 2) do
          local k = bx * 65536 + by
          local list = bucket[k]
          if not list then list = {}; bucket[k] = list end
          list[#list+1] = b
        end
      end
    end
    local blockers = {}
    local function hit(x, y)
      for _, b in ipairs(bucket[key(x, y)] or {}) do
        if x + half > b[1] and x - half < b[3] and y + half > b[2] and y - half < b[4] then return b end
      end
    end
    local function cell(i, j) return i * 65536 + j end
    local si, sj = math.floor(start.x / STEP + 0.5), math.floor(start.y / STEP + 0.5)
    local found
    for _, d in ipairs({{0, 0}, {1, 0}, {-1, 0}, {0, 1}, {0, -1}, {1, 1}, {-1, -1}, {1, -1}, {-1, 1}}) do
      if not hit((si + d[1]) * STEP, (sj + d[2]) * STEP) then si, sj = si + d[1], sj + d[2]; found = true; break end
    end
    if not found then return {closed=true, tiles=0, x0=start.x, y0=start.y, x1=start.x, y1=start.y, by={}, nearest={x=start.x, y=start.y}, stuck=true} end
    local seen, queue, head = {[cell(si, sj)]=true}, {{si, sj}}, 1
    local x0, y0, x1, y1 = si, sj, si, sj
    local goal, best, bd = opts.goal, nil, nil
    local edge = false
    while head <= #queue do
      local c = queue[head]; head = head + 1
      local i, j = c[1], c[2]
      if goal then
        local d = (i * STEP - goal.x) ^ 2 + (j * STEP - goal.y) ^ 2
        if not bd or d < bd then best, bd = c, d end
      end
      for _, n in ipairs({{i + 1, j}, {i - 1, j}, {i, j + 1}, {i, j - 1}}) do
        local k = cell(n[1], n[2])
        if not seen[k] then
          seen[k] = true
          local x, y = n[1] * STEP, n[2] * STEP
          if math.abs(x - start.x) >= WINDOW - 1 or math.abs(y - start.y) >= WINDOW - 1 then edge = true
          else
            local b = hit(x, y)
            if b then blockers[b[5]] = (blockers[b[5]] or 0) + 1
            else
              queue[#queue+1] = n
              x0, y0, x1, y1 = math.min(x0, n[1]), math.min(y0, n[2]), math.max(x1, n[1]), math.max(y1, n[2])
            end
          end
        end
      end
      if edge or #queue > CAP then break end
    end
    local closed = not edge and #queue <= CAP
    local by = {}
    for name, n in pairs(blockers) do by[#by+1] = {name=name, n=n} end
    table.sort(by, function(a, b) if a.n ~= b.n then return a.n > b.n end return a.name < b.name end)
    local names = {}
    for i = 1, math.min(6, #by) do names[i] = by[i].name end
    return {closed=closed, tiles=math.floor(#queue * STEP * STEP + 0.5), x0=x0 * STEP, y0=y0 * STEP, x1=x1 * STEP, y1=y1 * STEP,
      by=names, nearest=best and {x=best[1] * STEP, y=best[2] * STEP} or nil}
  end

  -- Belts under a position (the tile it is on).
  function M.belt_at(surface, pos)
    local x, y = math.floor(pos.x), math.floor(pos.y)
    local area = {{x, y}, {x + 1, y + 1}}
    local ok, list = pcall(surface.find_entities_filtered, {area=area, type=BELTS, limit=1})
    if not ok then list = try(surface.find_entities_filtered, {area=area, type=BASE_BELTS, limit=1}) end
    return list and list[1] or nil
  end
  -- A tile centre the character fits on, with no belt.
  function M.free_tile(surface, centre, half, ignore)
    local box = {{centre.x - half, centre.y - half}, {centre.x + half, centre.y + half}}
    for _, e in ipairs(try(function() return surface.find_entities_filtered{area=box, collision_mask='player'} end) or {}) do
      if e ~= ignore and e.type ~= 'character' then return false end
    end
    if (try(function() return surface.count_tiles_filtered{area=box, collision_mask='player'} end) or 0) > 0 then return false end
    return M.belt_at(surface, centre) == nil
  end
  -- Arrived on a belt: the nearest free tile without one, to the character,
  -- within the arrival radius of the target; else within 3 tiles of it.
  function M.off_belt_spot(p, target, tolerance)
    local here, half, surface = p.position, M.half(p.character), p.surface
    local cx, cy = math.floor(here.x), math.floor(here.y)
    -- Rings of tiles around the character, nearest first; a ring past the
    -- best distance found cannot hold a nearer one.
    local function scan(radius, limit)
      local best, bd
      for r = 0, radius do
        if bd and r - 1 > bd then break end
        for dx = -r, r do
          for dy = -r, r do
            if math.max(math.abs(dx), math.abs(dy)) == r then
              local c = {x=cx + dx + 0.5, y=cy + dy + 0.5}
              local d = dist(c, here)
              if (not bd or d < bd) and dist(c, target) <= limit and M.free_tile(surface, c, half, p.character) then best, bd = c, d end
            end
          end
        end
      end
      return best
    end
    local best = scan(math.min(10, math.ceil(tolerance) + 1), tolerance)
    if best then return best, true end
    return scan(3, math.huge), false
  end
  return M
end
