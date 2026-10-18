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
  M.PAD = PAD
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
  local found_spot, search_spot
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
  -- The boxes the character collides with in an area: entities, then tiles,
  -- as {x0, y0, x1, y1, name, entity}.
  local function boxes_in(surface, area, ignore)
    local boxes = {}
    for _, e in ipairs(try(function() return surface.find_entities_filtered{area=area, collision_mask='player'} end) or {}) do
      if e.valid and e ~= ignore and e.type ~= 'character' then
        local b = e.bounding_box
        boxes[#boxes+1] = {b.left_top.x, b.left_top.y, b.right_bottom.x, b.right_bottom.y, e.name, e}
      end
    end
    for _, t in ipairs(try(function() return surface.find_tiles_filtered{area=area, collision_mask='player'} end) or {}) do
      boxes[#boxes+1] = {t.position.x, t.position.y, t.position.x + 1, t.position.y + 1, t.name}
    end
    return boxes
  end
  M.boxes_in = boxes_in
  local function overlaps(b, x, y, h) return x + h > b[1] and x - h < b[3] and y + h > b[2] and y - h < b[4] end
  local function hits(boxes, x, y, h)
    for _, b in ipairs(boxes) do if overlaps(b, x, y, h) then return b end end
  end
  -- Boxes by 2-tile bucket, each in every bucket its reach touches. hit(x, y, h):
  -- the first box a box of half size h (at most reach) at (x, y) overlaps; all(x, y, h): every one.
  local function grid(boxes, reach)
    local bucket = {}
    for _, b in ipairs(boxes) do
      for bx = math.floor((b[1] - reach) / 2), math.floor((b[3] + reach) / 2) do
        for by = math.floor((b[2] - reach) / 2), math.floor((b[4] + reach) / 2) do
          local k = bx * 65536 + by
          local list = bucket[k]
          if not list then list = {}; bucket[k] = list end
          list[#list+1] = b
        end
      end
    end
    local function hit(x, y, h)
      for _, b in ipairs(bucket[math.floor(x / 2) * 65536 + math.floor(y / 2)] or {}) do if overlaps(b, x, y, h) then return b end end
    end
    local function all(x, y, h)
      local out
      for _, b in ipairs(bucket[math.floor(x / 2) * 65536 + math.floor(y / 2)] or {}) do
        if overlaps(b, x, y, h) then out = out or {}; out[#out+1] = b end
      end
      return out
    end
    -- 0 when nothing overlaps, 1 when everything that does passes ok(b), nil otherwise (no table made).
    local function cost(x, y, h, ok)
      local n = 0
      for _, b in ipairs(bucket[math.floor(x / 2) * 65536 + math.floor(y / 2)] or {}) do
        if overlaps(b, x, y, h) then
          if not ok(b) then return nil end
          n = 1
        end
      end
      return n
    end
    return hit, all, cost
  end
  -- A straight line from a to b the box (half size h) sweeps without touching anything.
  local function clear_line(hit, a, b, h, step)
    local n = math.max(1, math.ceil(dist(a, b) / (step or 0.1)))
    for k = 1, n do
      local t = k / n
      if hit(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, h) then return false end
    end
    return true
  end
  local function line_area(a, b, h)
    return {{math.min(a.x, b.x) - h - 0.5, math.min(a.y, b.y) - h - 0.5}, {math.max(a.x, b.x) + h + 0.5, math.max(a.y, b.y) + h + 0.5}}
  end
  -- The nearest free tile centre, when the character gets there in a straight
  -- line; else where it stands. (Sol, shift09 03:13: squeezed under a pipe row,
  -- the nearest free centre lay past the pipes, and every path from there
  -- stalled at them.)
  function M.start_centre(p)
    local c = p.character
    local here = p.position
    local centre = try(function() return p.surface.find_non_colliding_position(c.name, here, 3, 0.5, true) end)
    if not centre or dist(centre, here) < 0.05 then return centre or here end
    local h = M.half(c)
    local boxes = boxes_in(p.surface, line_area(here, centre, h), c)
    if clear_line(function(x, y, hh) return hits(boxes, x, y, hh) end, here, centre, h) then return centre end
    return here
  end
  -- One request; its id is noted so the result finds the walk.
  local function ask(p, nav, level, mask)
    local c = p.character
    local L = M.LEVELS[level + 1]
    local start = p.position
    if L.centre then start = M.start_centre(p) end
    -- (batch26 C2, Sonnet: a recover and three move_to calls stalled 16 times in a solar and accumulator block) after
    -- stalls a replan asks for more room either side (nav.stall_pad), so the route keeps out of gaps the steering sticks in
    local h = M.half(c) + L.pad + (nav.stall_pad or 0)
    local id = p.surface.request_path{bounding_box={{-h, -h}, {h, h}}, collision_mask=mask or c.prototype.collision_mask, start=start,
      goal=nav.position, force=p.force, radius=nav.precise_corner and nav.tolerance or nav.tolerance + 1 + (nav.replans or 0) + (L.wide or 0), entity_to_ignore=c, can_open_gates=true,
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
    nav.path_state = 'pending'; nav.waypoints = nil; nav.waypoint = nil; nav.sidestep = nil; nav.asked_tick = game.tick; nav.approach = nil
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
  -- A found path, unless the enemy check holds it, goes around a nest or ends the walk (avoid.lua).
  local function use(p, nav, path, avoided)
    if api.accept and not api.accept(p, nav, path, avoided) then return end
    nav.waypoints = path; nav.waypoint = 1; nav.path_state = 'found'; nav.avoided = avoided or nil
    nav.path_length = math.floor(M.length(path) + 0.5)
    nav.found = nil
    M.extend(nav, path)
  end
  -- (d17 batch23 A5, Opus: walks to (8,545) and (0,100) timed out round a lake and two nests; the limit was set from the
  -- straight line and never grew) a walk whose limit was not given: each path found sets the limit again from what is
  -- left (this path, then a straight line from its end to the goal) as the call set it (1.5 times the walking time and
  -- 10 s), never lower, at most `cap` from the start.
  function M.extend(nav, path)
    local L = nav.limit_auto
    if not (L and path and #path > 0) then return end
    local goal = nav.via and nav.via.final or nav.position
    local left = M.length(path) + dist(path[#path].position, goal)
    if nav.via then
      local from = goal
      for i = (nav.via.index or 1), #nav.via.points do left = left + dist(nav.via.points[i], from); from = nav.via.points[i] end
    end
    local want = math.min(L.start + L.cap, game.tick + math.ceil(left / L.speed * 1.5) + 600)
    if want > (nav.until_tick or 0) then
      nav.until_tick = want
      L.extended = (L.extended or 0) + 1
      nav.limit_text = string.format('%s; set again to %d ticks from the start when a path was found (%d tiles left on it and to the goal)',
        L.text, want - L.start, math.floor(left + 0.5))
    end
  end
  -- (A5) What the straight line (through via points) crosses, sampled in 8-tile boxes every 8 tiles (at most 128
  -- boxes; longer lines are sampled sparser): water and other ground the character cannot cross, cliffs, and
  -- entities it collides with (buildings, trees, rocks). {length, water {from, to, names}, cliffs {n, at}, solid {n,
  -- at, names}, text}.
  function M.line_crossing(surface, points)
    local length = 0
    for i = 2, #points do length = length + dist(points[i-1], points[i]) end
    local step = math.max(8, length / 128)
    local out = {length=length}
    local water, cliffs, solid = nil, nil, nil
    local function look(x, y)
      x, y = math.floor(x + 0.5), math.floor(y + 0.5)
      local area = {{x - 4, y - 4}, {x + 4, y + 4}}
      local w = try(function() return surface.count_tiles_filtered{area=area, collision_mask='player'} end) or 0
      if w > 0 then
        water = water or {from={x=x, y=y}, names={}}
        water.to = {x=x, y=y}
        if #water.names < 3 then
          local t = try(function() return surface.find_tiles_filtered{area=area, collision_mask='player', limit=1}[1].name end)
          local seen = false
          for _, n in ipairs(water.names) do if n == t then seen = true end end
          if t and not seen then water.names[#water.names+1] = t end
        end
      end
      local c = try(function() return surface.count_entities_filtered{area=area, type='cliff'} end) or 0
      if c > 0 then cliffs = cliffs or {n=0, at={x=x, y=y}}; cliffs.n = cliffs.n + c end
      local e = (try(function() return surface.count_entities_filtered{area=area, collision_mask='player'} end) or 0) - c
      if e > 0 then
        if not solid then
          solid = {n=0, at={x=x, y=y}, names={}}
          for _, x2 in ipairs(try(function() return surface.find_entities_filtered{area=area, collision_mask='player', limit=8} end) or {}) do
            local n = x2.name
            local seen = false
            for _, m in ipairs(solid.names) do if m == n then seen = true end end
            if not seen and #solid.names < 3 and x2.type ~= 'cliff' and x2.type ~= 'character' then solid.names[#solid.names+1] = n end
          end
        end
        solid.n = solid.n + e
      end
    end
    for i = 2, #points do
      local a, b = points[i-1], points[i]
      local d = dist(a, b)
      local n = math.max(1, math.floor(d / step + 0.5))
      for k = (i == 2 and 0 or 1), n do look(a.x + (b.x - a.x) * k / n, a.y + (b.y - a.y) * k / n) end
    end
    out.water, out.cliffs, out.solid = water, cliffs, solid
    local bits = {}
    if water then bits[#bits+1] = string.format('ground it cannot cross (%s) from %s to %s', table.concat(water.names, ', '), at(water.from), at(water.to)) end
    if cliffs then bits[#bits+1] = string.format('%d cliff%s, the first near %s', cliffs.n, cliffs.n == 1 and '' or 's', at(cliffs.at)) end
    if solid then bits[#bits+1] = string.format('%d buildings, trees or rocks, the first near %s (%s)', solid.n, at(solid.at), table.concat(solid.names, ', ')) end
    out.text = #bits > 0 and string.format('the straight line (%d tiles) crosses %s', math.floor(length + 0.5), table.concat(bits, '; '))
      or string.format('nothing on the straight line (%d tiles): no water, cliff, building, tree or rock; the route is the straight line unless an enemy\'s reach or a belt is avoided', math.floor(length + 0.5))
    return out
  end
  M.use = function(p, nav, path, avoided) return use(p, nav, path, avoided) end
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
      if path then return use(p, nav, path, avoided) end
      if f.busy then nav.found = nil; nav.path_state = 'busy'; return end
      nav.found = nil
      return M.climb(p, nav)
    end
    if got then return use(p, nav, got) end
    if event.try_again_later then nav.path_state = 'busy'; return end
    return M.climb(p, nav)
  end
  -- The first level's second answer did not come within GRACE_TICKS: decide with what came.
  function M.grace(p, nav)
    local f = nav.found
    if not f or game.tick - (nav.asked_tick or game.tick) < GRACE_TICKS then return end
    local path, avoided = M.prefer(f.normal or nil, f.avoid or nil)
    if path then return use(p, nav, path, avoided) end
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
  -- A probe: one request from where the character stands toward the goal,
  -- ending at the first point within radius of it. kind near: where it can
  -- get to; room: a box with room to turn (padded by PAD) within build
  -- reach; gap: its own box on the quarter-tile grid within build reach.
  local function probe(p, nav, kind, radius, pad, res)
    local c = p.character
    local h = M.half(c) + (pad or 0)
    nav.probe_id = p.surface.request_path{bounding_box={{-h, -h}, {h, h}}, collision_mask=c.prototype.collision_mask, start=M.start_centre(p),
      goal=nav.position, force=p.force, radius=radius, entity_to_ignore=c, can_open_gates=true,
      pathfind_flags={prefer_straight_paths=true, no_break=res == nil, cache=false}, path_resolution_modifier=res}
    api.paths()[nav.probe_id] = p.index
    nav.probe_radius, nav.probe_kind = radius, kind
    nav.path_state = 'probing'
  end
  local function build_reach(p) return try(function() return p.build_distance end) or 10 end
  M.build_reach = build_reach
  -- A build spot's distance to the goal at most: build reach less the arrival
  -- radius and a quarter tile (on a copy of world n a walk to a spot 9.8 tiles
  -- off stopped 10.2 from the goal, out of reach).
  local function spot_reach(R) return R - 0.75 end
  -- A walk to an entity's reach (move_to target: nav.reach_r, nav.reach_box)
  -- takes its spots within that reach of the entity's box; others within
  -- build reach of the goal.
  local function spot_R(p, nav) return nav.reach_r or build_reach(p) end
  local function goal_dist(nav, q)
    local b = nav.reach_box
    if not b then return dist(q, nav.position) end
    local dx = math.max(b[1] - q.x, 0, q.x - b[3])
    local dy = math.max(b[2] - q.y, 0, q.y - b[4])
    return (dx * dx + dy * dy) ^ 0.5
  end
  M.goal_dist = goal_dist
  -- A spot the character reaches (a probe's end, or the nearest step of a
  -- closed area) within build reach of the goal (Grok, shift10 06:20: four
  -- walks failed toward a standing tile; the only tile in build reach of the
  -- new engine lay in a 0.7-tile gap). One with room to turn is named as it
  -- is; one in a gap is swapped for a spot with room joined to it within
  -- build reach, else named with what hems it in (a walk stops before a gap
  -- unless squeeze=true).
  local function classify(p, nav, pos, room)
    local c, R = p.character, spot_R(p, nav)
    local half = M.half(c)
    local s = {pos={x=pos.x, y=pos.y}, goal={x=nav.position.x, y=nav.position.y}, reach=R, label=nav.reach_label}
    if room or M.clear_at(p.surface, pos, half + PAD, c) then s.room = true
    else
      local r = M.region(p.surface, pos, half, {ignore=c, force=p.force, open_pad=PAD, window=12})
      if r and r.open and goal_dist(nav, r.open) <= spot_reach(R) then s.pos = {x=r.open.x, y=r.open.y}; s.room = true
      else
        local g = M.in_gap(p.surface, pos, half, 0.25, c)
        s.by = g and g.by or {}
        s.width = (half + PAD) * 2
      end
    end
    return s
  end
  found_spot = function(p, nav, pos, room)
    local s = classify(p, nav, pos, room)
    if not nav.reachable or goal_dist(nav, s.pos) < goal_dist(nav, nav.reachable) then nav.reachable = s.pos end
    nav.spot = s
    nav.path_state = 'unreachable'
  end
  -- No path request found one: the character's own steps (a search, a
  -- slice a tick: path_state searching), from where it stands, else from
  -- the near probe's end (walked to first: via). A spot found so is walked
  -- to with squeeze=true (its trail).
  search_spot = function(p, nav)
    local c, R = p.character, spot_R(p, nav)
    local half = M.half(c)
    local goal = {x=nav.position.x, y=nav.position.y}
    local opts = {ignore=c, force=p.force}
    local S = M.search_begin(p.surface, p.position, half, goal, spot_reach(R), opts)
    local via
    if not S and nav.reachable then
      S = M.search_begin(p.surface, nav.reachable, half, goal, spot_reach(R), opts)
      via = S and {x=nav.reachable.x, y=nav.reachable.y} or nil
    end
    if not S then
      nav.spot = {none=true, goal=goal, reach=R, label=nav.reach_label}
      nav.path_state = 'unreachable'
      return
    end
    nav.search = {S=S, mode='spot', via=via}
    nav.path_state = 'searching'
  end
  -- The search's result for the walk's build spot.
  local function searched_spot(p, nav, r, via)
    local c, R = p.character, spot_R(p, nav)
    local half = M.half(c)
    local goal = {x=nav.position.x, y=nav.position.y}
    if not r then
      nav.spot = {none=true, goal=goal, reach=R, label=nav.reach_label}
    else
      local s = {pos=r.spot, goal=goal, reach=R, label=nav.reach_label, room=r.room or nil, searched=true, via=via, width=(half + PAD) * 2}
      if not r.room then local g = M.in_gap(p.surface, r.spot, half, 0.25, c); s.by = g and g.by or {} end
      nav.spot = s
      if not nav.reachable or goal_dist(nav, s.pos) < goal_dist(nav, nav.reachable) then nav.reachable = s.pos end
    end
    nav.path_state = 'unreachable'
  end
  -- A slice of the walk's search each tick (navigate, path_state searching).
  function M.search_tick(p, nav)
    local job = nav.search
    if not job then nav.path_state = 'unreachable'; return end
    local r = M.search_run(job.S, M.SEARCH_SLICE)
    if r == nil then return end
    nav.search = nil
    if job.mode == 'squeeze' then
      if r then return M.walk_trail(p, nav, r, job.from) end
      return M.give_up_rest(p, nav)
    end
    -- Nothing from where it stands: once more from the near probe's end.
    if not r and not job.via and nav.reachable and dist(nav.reachable, p.position) > 1 then
      local S = M.search_begin(p.surface, nav.reachable, M.half(p.character), nav.position, spot_reach(spot_R(p, nav)), {ignore=p.character, force=p.force})
      if S then nav.search = {S=S, mode='spot', via={x=nav.reachable.x, y=nav.reachable.y}}; return end
    end
    return searched_spot(p, nav, r or nil, job.via)
  end
  -- After the near probe: its end when it has room within build reach, else
  -- a probe for a box with room to turn within build reach, then the
  -- character's own box on the quarter-tile grid.
  function M.spot(p, nav)
    local R, r = spot_R(p, nav), nav.reachable
    if r and goal_dist(nav, r) <= spot_reach(R) and M.clear_at(p.surface, r, M.half(p.character) + PAD, p.character) then
      return found_spot(p, nav, r, true)
    end
    return probe(p, nav, 'room', spot_reach(R) - 0.25, PAD, nil)
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
    -- Squeezed into a gap the pathfinder does not route through: walk out first.
    if M.escape(p, nav) then return end
    -- squeeze=true: where no path request leads, the character's own steps do (a search, then its trail walked).
    if nav.squeeze and not nav.squeeze_tried and M.squeeze_begin(p, nav) then return end
    return M.give_up_rest(p, nav)
  end
  -- The rest of a give-up: closed in (mapped now), or a probe where it can get to.
  function M.give_up_rest(p, nav)
    local pos = nav.position
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
      -- The way out by mining (the fewest of our entities, trees or rocks in
      -- the way) is searched next tick, around the closed area: in one tick
      -- with the flood it took 11 ms on a private copy of world n; apart, the
      -- flood 3.9 ms, the search 2.3 ms.
      nav.dig_from = {x=here.x, y=here.y}
      nav.dig_area = {region.x0 - 16, region.y0 - 16, region.x1 + 16, region.y1 + 16}
      nav.path_state = 'digging'
      return
    end
    -- Not closed in: one wide request says where it can get to.
    return probe(p, nav, 'near', math.max(4, math.min(48, dist(here, pos) * 0.75)), 0, nil)
  end
  -- What stands round the character when no path request starts from where it is (C4, Opus 18:20, 4 times in shift25:
  -- among drills and belts at (-300,-305) every walk ended "nor to anywhere within 48 tiles"; squeeze=true walked out):
  -- our mining drills, belts and the like within 2.5 tiles, by name, when the area it can reach is not closed in.
  local BOX_TYPES = {'mining-drill', 'transport-belt', 'underground-belt', 'splitter', 'inserter', 'pipe', 'pipe-to-ground', 'electric-pole', 'container', 'wall', 'furnace', 'assembling-machine'}
  function M.boxed(p, nav)
    if nav.region and nav.region.closed then return nil end
    local here = p.position
    local list = try(function() return p.surface.find_entities_filtered{area={{here.x - 2.5, here.y - 2.5}, {here.x + 2.5, here.y + 2.5}}, type=BOX_TYPES} end) or {}
    local by, order, drills_or_belts = {}, {}, false
    for _, e in ipairs(list) do
      if e.valid then
        if not by[e.name] then by[e.name] = 0; order[#order+1] = e.name end
        by[e.name] = by[e.name] + 1
        if e.type == 'mining-drill' or e.type == 'transport-belt' or e.type == 'underground-belt' or e.type == 'splitter' then drills_or_belts = true end
      end
    end
    if not drills_or_belts then return nil end
    table.sort(order, function(x, y) if by[x] ~= by[y] then return by[x] > by[y] end return x < y end)
    local parts = {}
    for i = 1, math.min(4, #order) do parts[i] = by[order[i]] .. ' ' .. order[i] end
    local ways = nav.squeeze_tried and 'pathfind=false steers straight at the goal (belts carry you)'
      or 'move_to squeeze=true walks your own steps out along the gaps; pathfind=false steers straight at the goal (belts carry you)'
    return string.format('boxed in at %s by %s within 2.5 tiles: the gaps between them are narrower than a path request starts in, but the area you can reach is not closed in: %s',
      at(here), table.concat(parts, ', '), ways)
  end
  -- Why a walk ended blocked after its stalls (batch25 A1, Haiku ~4 times: a rearm tour ended "(-76,161): blocked" after a
  -- dry run said the route was clear, a minute each): where it stopped, how far from the goal, and what stands within
  -- 2.5 tiles of it that the character collides with (by the character's collision layers), by name; enemy units
  -- within 6 tiles, which push it about.
  local char_layers
  local function blocks(e)
    if not char_layers then
      char_layers = try(function() return prototypes.entity.character.collision_mask.layers end) or {player=true}
    end
    local layers = try(function() return e.prototype.collision_mask.layers end)
    if not layers then return false end
    for k in pairs(layers) do if char_layers[k] then return true end end
    return false
  end
  local SKIP = {character=true, ['item-entity']=true, resource=true, corpse=true, ['character-corpse']=true, ['entity-ghost']=true, ['tile-ghost']=true}
  function M.stall_why(p, nav, goal)
    local here = p.position
    local list = try(function() return p.surface.find_entities_filtered{area={{here.x - 2.5, here.y - 2.5}, {here.x + 2.5, here.y + 2.5}}, limit=64} end) or {}
    local by, order = {}, {}
    for _, e in ipairs(list) do
      if e.valid and not SKIP[e.type] and e ~= p.character and blocks(e) then
        local name = e.type == 'cliff' and 'cliff' or e.name
        if not by[name] then by[name] = {n=0, first=e.position}; order[#order+1] = name end
        by[name].n = by[name].n + 1
      end
    end
    table.sort(order, function(x, y) if by[x].n ~= by[y].n then return by[x].n > by[y].n end return x < y end)
    local parts = {}
    for i = 1, math.min(5, #order) do local b = by[order[i]]; parts[i] = string.format('%d %s (first at %s)', b.n, order[i], at(b.first)) end
    local units = try(function() return p.surface.count_entities_filtered{position=here, radius=6, type='unit', force='enemy'} end) or 0
    return string.format('stalled %d times at %s, %.1f tiles from %s; within 2.5 tiles: %s%s', nav.stalls or 0, at(here), dist(here, goal), at(goal),
      #parts > 0 and table.concat(parts, ', ') or 'nothing the character collides with (units, a belt carrying it, or the tiles)',
      units > 0 and string.format('; %d enemy unit%s within 6 tiles', units, units == 1 and '' or 's') or '')
  end
  function M.probed(p, nav, event)
    nav.probe_id = nil
    local kind = nav.probe_kind or 'near'
    nav.probe_kind = nil
    local last = event.path and event.path[#event.path]
    local got = last and {x=last.position.x, y=last.position.y} or nil
    if kind == 'near' then
      nav.reachable = got
      if got then
        nav.why = string.format('no path for the character to %s on the tile, half- or quarter-tile grid', at(nav.position))
      else
        nav.why = string.format('no path request found a way for the character to %s, nor to anywhere within %d tiles of it', at(nav.position), math.floor(nav.probe_radius or 0))
        local boxed = M.boxed(p, nav)
        if boxed then nav.why = nav.why .. '; ' .. boxed end
        -- Walkable water between (oil ocean, shallow water, wetland) was ground to the requests (friction4: Gemini, shift14
        -- 23:15, took a walk into its packed island for the oil ocean being impassable; on a copy of world n move_to
        -- crossed shallow and deep oil ocean). The box from here to the goal, cut to 64 tiles round the goal.
        if api.walkable_water then
          local here, goal = p.position, nav.position
          local function near_goal(v, c) return math.max(c - 64, math.min(c + 64, v)) end
          local water = try(api.walkable_water, p.surface, {
            {near_goal(math.min(here.x, goal.x) - 8, goal.x), near_goal(math.min(here.y, goal.y) - 8, goal.y)},
            {near_goal(math.max(here.x, goal.x) + 8, goal.x), near_goal(math.max(here.y, goal.y) + 8, goal.y)}})
          if water and #water > 0 then
            nav.why = nav.why .. string.format(' (the path requests take %s as ground, as the character walks it: it was not what blocked the way)', table.concat(water, ', '))
          end
        end
      end
      return M.spot(p, nav)
    end
    if got then return found_spot(p, nav, got, kind == 'room') end
    if kind == 'room' then return probe(p, nav, 'gap', spot_reach(spot_R(p, nav)) - 0.25, 0, 2) end
    return search_spot(p, nav)
  end

  -- Where the character can get to from start (a flood over quarter-tile
  -- steps with its own box, belts walkable), within 24 tiles and 6000 steps.
  -- Closed: the steps ran out of room before the window edge or the cap;
  -- then the nearest step to goal, the area and what blocked the edge.
  -- opts: ignore (an entity), force (its gates open for the character, as
  -- for the pathfinder), skip (unit numbers left out: entities just built),
  -- extra (planned boxes {x0, y0, x1, y1, name, id}; planned lists the ids
  -- of those the flood ran into), open (tile keys "x,y" planned tiles make
  -- walkable), search (steps around start to look for a free one, default 1),
  -- open_pad (stop at the nearest step where a box padded by it fits, room
  -- to turn, with the trail there: open, trail, steps; that flood goes
  -- nearest step first, so the trail is a shortest one).
  local WINDOW, CAP, STEP = 24, 6000, 0.25
  M.WINDOW, M.STEP = WINDOW, STEP
  local function cell(i, j) return i * 65536 + j end
  local NEIGHBOURS = {{1, 0}, {-1, 0}, {0, 1}, {0, -1}}
  -- Corners of a trail joined where the box sweeps the straight line between them.
  local function smooth(points, hit, h)
    local out, i = {points[1]}, 1
    while i < #points do
      local j = math.min(#points, i + 24)
      while j > i + 1 and not clear_line(hit, points[i], points[j], h, 0.05) do j = j - 1 end
      out[#out+1] = points[j]; i = j
    end
    return out
  end
  -- What the character's box runs into in an area: our entities and others'
  -- (not characters, nor our gates with opts.force), tiles it cannot walk
  -- on, and opts.extra boxes; opts.skip (unit numbers) and opts.open (tile
  -- keys) leave some out. Returns hit(x, y, h): the first box a box of half
  -- size h (default half, at most reach) at (x, y) overlaps, as {x0, y0, x1,
  -- y1, name, id}.
  local function collision_boxes(surface, area, opts)
    local boxes = {}
    local skip, open = opts.skip, opts.open
    for _, e in ipairs(try(function() return surface.find_entities_filtered{area=area, collision_mask='player'} end) or {}) do
      if e.valid and e ~= opts.ignore and e.type ~= 'character' and not (e.type == 'gate' and opts.force and e.force == opts.force)
        and not (skip and e.unit_number and skip[e.unit_number]) then
        local b = e.bounding_box
        boxes[#boxes+1] = {b.left_top.x, b.left_top.y, b.right_bottom.x, b.right_bottom.y, e.name}
      end
    end
    for _, t in ipairs(try(function() return surface.find_tiles_filtered{area=area, collision_mask='player'} end) or {}) do
      if not (open and open[t.position.x .. ',' .. t.position.y]) then
        boxes[#boxes+1] = {t.position.x, t.position.y, t.position.x + 1, t.position.y + 1, t.name}
      end
    end
    for _, b in ipairs(opts.extra or {}) do boxes[#boxes+1] = b end
    return boxes
  end
  local function bucket_of(surface, area, reach, opts)
    local boxes=collision_boxes(surface,area,opts)
    -- Boxes by 2-tile bucket, each in every bucket its reach touches (the
    -- padded box's reach when looking for room to turn).
    local bucket = {}
    for _, b in ipairs(boxes) do
      for bx = math.floor((b[1] - reach) / 2), math.floor((b[3] + reach) / 2) do
        for by = math.floor((b[2] - reach) / 2), math.floor((b[4] + reach) / 2) do
          local k = bx * 65536 + by
          local list = bucket[k]
          if not list then list = {}; bucket[k] = list end
          list[#list+1] = b
        end
      end
    end
    return bucket
  end
  local function hitter(bucket, half)
    return function(x, y, h)
      h = h or half
      for _, b in ipairs(bucket[math.floor(x / 2) * 65536 + math.floor(y / 2)] or {}) do
        if x + h > b[1] and x - h < b[3] and y + h > b[2] and y - h < b[4] then return b end
      end
    end
  end
  local function obstacles(surface, area, reach, half, opts) return hitter(bucket_of(surface, area, reach, opts), half) end
  function M.region(surface, start, half, opts)
    opts = opts or {}
    local WINDOW = opts.window or WINDOW
    local pad = opts.open_pad
    local area = {{start.x - WINDOW, start.y - WINDOW}, {start.x + WINDOW, start.y + WINDOW}}
    local hit = obstacles(surface, area, half + (pad or 0), half, opts)
    local blockers = {}
    local si, sj = math.floor(start.x / STEP + 0.5), math.floor(start.y / STEP + 0.5)
    local found
    -- The nearest free step: rings around start, nearest first.
    for r = 0, opts.search or 1 do
      local best, bd
      for di = -r, r do
        for dj = -r, r do
          if math.max(math.abs(di), math.abs(dj)) == r and not hit((si + di) * STEP, (sj + dj) * STEP) then
            local d = di * di + dj * dj
            if not bd or d < bd then best, bd = {di, dj}, d end
          end
        end
      end
      if best then si, sj = si + best[1], sj + best[2]; found = true; break end
    end
    if not found then return {closed=true, tiles=0, x0=start.x, y0=start.y, x1=start.x, y1=start.y, by={}, nearest={x=start.x, y=start.y}, stuck=true, planned={}} end
    -- Farthest step first (a max-heap on the distance from start in steps):
    -- in the open the flood reaches the window edge after a few hundred steps
    -- instead of filling the cap (6000 steps, 25 ms on a private 2.0.77
    -- server); a closed area is flooded whole either way. Looking for room to
    -- turn it goes nearest first (a queue), each step noting where it came from.
    local seen, found = {[cell(si, sj)]=true}, 1
    local heap, hn = {{si, sj, 0}}, 1
    local queue, head = pad and {{si, sj}} or nil, 1
    local from = pad and {} or nil
    local function push(i, j)
      if queue then queue[#queue+1] = {i, j}; return end
      local d = math.max(math.abs(i - si), math.abs(j - sj))
      hn = hn + 1; heap[hn] = {i, j, d}
      local k = hn
      while k > 1 do
        local up = math.floor(k / 2)
        if heap[up][3] >= d then break end
        heap[up], heap[k] = heap[k], heap[up]; k = up
      end
    end
    local function pop()
      if queue then local c = queue[head]; head = head + 1; return c end
      local top = heap[1]
      heap[1] = heap[hn]; heap[hn] = nil; hn = hn - 1
      local k = 1
      while true do
        local l, r, m = 2 * k, 2 * k + 1, k
        if l <= hn and heap[l][3] > heap[m][3] then m = l end
        if r <= hn and heap[r][3] > heap[m][3] then m = r end
        if m == k then break end
        heap[m], heap[k] = heap[k], heap[m]; k = m
      end
      return top
    end
    local function more() if queue then return head <= #queue end return hn > 0 end
    local planned = {}
    local x0, y0, x1, y1 = si, sj, si, sj
    local goal, best, bd = opts.goal, nil, nil
    local edge, opening = false, nil
    while more() do
      local c = pop()
      local i, j = c[1], c[2]
      if pad and not hit(i * STEP, j * STEP, half + pad) then opening = c; break end
      if goal then
        local d = (i * STEP - goal.x) ^ 2 + (j * STEP - goal.y) ^ 2
        if not bd or d < bd then best, bd = c, d end
      end
      for _, o in ipairs(NEIGHBOURS) do
        local n = {i + o[1], j + o[2]}
        local k = cell(n[1], n[2])
        if not seen[k] then
          seen[k] = true
          local x, y = n[1] * STEP, n[2] * STEP
          if math.abs(x - start.x) >= WINDOW - 1 or math.abs(y - start.y) >= WINDOW - 1 then edge = true
          else
            local b = hit(x, y)
            if b then
              blockers[b[5]] = (blockers[b[5]] or 0) + 1
              if b[6] then planned[b[6]] = true end
            else
              found = found + 1
              push(n[1], n[2])
              if from then from[k] = c end
              x0, y0, x1, y1 = math.min(x0, n[1]), math.min(y0, n[2]), math.max(x1, n[1]), math.max(y1, n[2])
            end
          end
        end
      end
      -- Looking for room to turn, the window edge is no end: the steps go on to the cap.
      if (edge and not pad) or found > CAP then break end
    end
    if opening then
      local trail, c = {}, opening
      while c do trail[#trail+1] = {x=c[1] * STEP, y=c[2] * STEP}; c = from[cell(c[1], c[2])] end
      local ordered = {}
      for k = #trail, 1, -1 do ordered[#ordered+1] = trail[k] end
      return {open={x=opening[1] * STEP, y=opening[2] * STEP}, trail=smooth(ordered, hit, half + 0.01), steps=#trail - 1}
    end
    local closed = not edge and found <= CAP
    local by = {}
    for name, n in pairs(blockers) do by[#by+1] = {name=name, n=n} end
    table.sort(by, function(a, b) if a.n ~= b.n then return a.n > b.n end return a.name < b.name end)
    local names = {}
    for i = 1, math.min(6, #by) do names[i] = by[i].name end
    return {closed=closed, tiles=math.floor(found * STEP * STEP + 0.5), x0=x0 * STEP, y0=y0 * STEP, x1=x1 * STEP, y1=y1 * STEP,
      by=names, nearest=best and {x=best[1] * STEP, y=best[2] * STEP} or nil, planned=planned}
  end
  -- Where the character's own box gets to within reach of goal (Grok,
  -- shift10 06:20: the only tile in build reach of his new engine lay in a
  -- 0.7-tile gap; on a copy of world n no path request, on any grid, ended
  -- in a 0.6-tile gap between two assembling machines, nor led into one).
  -- A search over quarter-tile steps from start, nearest the goal first,
  -- inside the box around start and goal (at most 64 tiles a side) and up to
  -- SEARCH_CAP steps. Returns the first step within reach with room to turn
  -- (a box padded by PAD fits), else the first within reach, as {spot, room,
  -- trail (corners from start), steps}; nil when none is within reach.
  local SEARCH_CAP, SEARCH_MORE, SEARCH_SIDE, SEARCH_SLICE = 6000, 600, 64, 300
  M.SEARCH_SLICE = SEARCH_SLICE
  -- Step keys and their steps (quarter tiles, |j| under 2^19).
  local function skey(i, j) return i * 1048576 + j end
  local function sdecode(k) local i = math.floor((k + 524288) / 1048576); return i, k - i * 1048576 end
  -- The search's state: plain tables, kept with a walk in storage between slices.
  function M.search_begin(surface, start, half, goal, reach, opts)
    opts = opts or {}
    local x0, y0 = math.min(start.x, goal.x) - reach - 4, math.min(start.y, goal.y) - reach - 4
    local x1, y1 = math.max(start.x, goal.x) + reach + 4, math.max(start.y, goal.y) + reach + 4
    if x1 - x0 > SEARCH_SIDE or y1 - y0 > SEARCH_SIDE then return nil end
    local bucket = bucket_of(surface, {{x0, y0}, {x1, y1}}, half + PAD, opts)
    local hit = hitter(bucket, half)
    local si, sj = math.floor(start.x / STEP + 0.5), math.floor(start.y / STEP + 0.5)
    local found
    for r = 0, 2 do
      for di = -r, r do
        for dj = -r, r do
          if not found and math.max(math.abs(di), math.abs(dj)) == r and not hit((si + di) * STEP, (sj + dj) * STEP) then found = {si + di, sj + dj} end
        end
      end
      if found then break end
    end
    if not found then return nil end
    local d = (found[1] * STEP - goal.x) ^ 2 + (found[2] * STEP - goal.y) ^ 2
    return {x0=x0, y0=y0, x1=x1, y1=y1, goal={x=goal.x, y=goal.y}, R2=reach * reach, half=half, bucket=bucket,
      heap={{found[1], found[2], d}}, hn=1, seen={[skey(found[1], found[2])]=true}, from={}, pops=0, after=0}
  end
  -- Up to budget steps of S: nil while it goes on, then the result or false.
  function M.search_run(S, budget)
    local hit = hitter(S.bucket, S.half)
    local heap, goal, half = S.heap, S.goal, S.half
    local function push(i, j)
      local d = (i * STEP - goal.x) ^ 2 + (j * STEP - goal.y) ^ 2
      S.hn = S.hn + 1; heap[S.hn] = {i, j, d}
      local k = S.hn
      while k > 1 do
        local up = math.floor(k / 2)
        if heap[up][3] <= d then break end
        heap[up], heap[k] = heap[k], heap[up]; k = up
      end
    end
    local function pop()
      local top, hn = heap[1], S.hn
      heap[1] = heap[hn]; heap[hn] = nil; hn = hn - 1; S.hn = hn
      local k = 1
      while true do
        local l, r, m = 2 * k, 2 * k + 1, k
        if l <= hn and heap[l][3] < heap[m][3] then m = l end
        if r <= hn and heap[r][3] < heap[m][3] then m = r end
        if m == k then break end
        heap[m], heap[k] = heap[k], heap[m]; k = m
      end
      return top
    end
    local n = 0
    while S.hn > 0 do
      if n >= budget then return nil end
      n = n + 1
      local c = pop()
      S.pops = S.pops + 1
      local x, y = c[1] * STEP, c[2] * STEP
      if c[3] <= S.R2 then
        if not hit(x, y, half + PAD) then S.room = skey(c[1], c[2]); break end
        S.first = S.first or skey(c[1], c[2])
      end
      if S.first then S.after = S.after + 1; if S.after > SEARCH_MORE then break end end
      if S.pops > SEARCH_CAP then break end
      for _, o in ipairs(NEIGHBOURS) do
        local ni, nj = c[1] + o[1], c[2] + o[2]
        local k = skey(ni, nj)
        local nx, ny = ni * STEP, nj * STEP
        if not S.seen[k] and nx > S.x0 and nx < S.x1 and ny > S.y0 and ny < S.y1 then
          S.seen[k] = true
          if not hit(nx, ny) then S.from[k] = skey(c[1], c[2]); push(ni, nj) end
        end
      end
    end
    local best = S.room or S.first
    if not best then return false end
    local trail, k = {}, best
    while k do local i, j = sdecode(k); trail[#trail+1] = {x=i * STEP, y=j * STEP}; k = S.from[k] end
    local ordered = {}
    for i = #trail, 1, -1 do ordered[#ordered+1] = trail[i] end
    local bi, bj = sdecode(best)
    return {spot={x=bi * STEP, y=bj * STEP}, room=S.room ~= nil, trail=smooth(ordered, hit, half + 0.01), steps=S.pops}
  end
  -- The whole search at once (tests, reads): the result or nil.
  function M.reach_search(surface, start, half, goal, reach, opts)
    local S = M.search_begin(surface, start, half, goal, reach, opts)
    return S and M.search_run(S, math.huge) or nil
  end
  local function area_text(r, half)
    return string.format('the area %s-%s (about %d tiles) has no gap the character (%.1f tiles wide) fits through%s',
      at({x=r.x0, y=r.y0}), at({x=r.x1, y=r.y1}), r.tiles, half * 2, #r.by > 0 and ('; around it: ' .. table.concat(r.by, ', ')) or '')
  end
  M.area_text = area_text
  -- Whether planned boxes close the character in where it stands (Gemini,
  -- shift09: a placement trapped the character in a closed box): the area
  -- it reaches with them placed, and those that each fill the last gap out
  -- (without that one alone it gets out). planned: {{x0, y0, x1, y1, name,
  -- id, base=true}} per planned entity, and pieces {..., id, ids} that stand
  -- only while every entity in ids does (a wall stretched toward a planned
  -- neighbour); opts as region's (open: tiles the plan makes walkable). nil
  -- when it still gets out; {already=true, region} when it is closed in now.
  -- These look 16 tiles out (about 1 ms a flood on a private 2.0.77 server,
  -- against 3-5 ms at the walk's 24): no way out within that is closed in.
  local MAX_TRIES, TRAP_WINDOW = 6, 16
  function M.closes_in(surface, start, half, planned, opts)
    opts = opts or {}
    local function flood(extra, open)
      return M.region(surface, start, half, {ignore=opts.ignore, force=opts.force, extra=extra, open=open, search=opts.search, window=TRAP_WINDOW})
    end
    local after = flood(planned, opts.open)
    if not (after and after.closed) or after.stuck then return nil end
    local before = flood(nil, nil)
    if before and before.closed then
      if before.stuck then return nil end
      return {already=true, region=before}
    end
    local function without(id)
      local rest = {}
      for _, o in ipairs(planned) do
        local keep = o[6] ~= id
        for _, need in ipairs(keep and o.ids or {}) do if need == id then keep = false end end
        if keep then rest[#rest+1] = o end
      end
      return rest
    end
    local gaps, around, tries = {}, {}, 0
    for _, b in ipairs(planned) do
      if b.base and after.planned[b[6]] then
        around[#around+1] = b
        if tries < MAX_TRIES then
          tries = tries + 1
          local r = flood(without(b[6]), opts.open)
          if r and not r.closed then gaps[#gaps+1] = b end
        end
      end
    end
    return {region=after, gaps=gaps, around=around}
  end
  -- New walkable pockets beside a build plan, even when the character is
  -- elsewhere. One bounded quarter-tile grid, two floods; no per-entry
  -- engine queries. The boundary must be reached before a component is
  -- called open. Pre-existing pockets are not attributed to the plan.
  function M.pocket_window(planned)
    local l,t,r,b=math.huge,math.huge,-math.huge,-math.huge
    for _,p in ipairs(planned) do l=math.min(l,p[1]);t=math.min(t,p[2]);r=math.max(r,p[3]);b=math.max(b,p[4]) end
    -- Include existing surroundings of a single closing entry too: a small
    -- plan can seal a much larger pocket that is already mostly built.
    local w,h=math.max(24,r-l+4),math.max(24,b-t+4)
    l,t=math.floor((l+r-w)/2),math.floor((t+b-h)/2)
    r,b=l+math.ceil(w),t+math.ceil(h)
    local info={area={left_top={x=l,y=t},right_bottom={x=r,y=b}},step=STEP,max_side=32}
    if r-l>32 or b-t>32 then
      info.checked=false;info.reason='pocket check needs a window larger than 32 tiles a side'
      return info
    end
    info.checked=true
    return info
  end
  function M.pockets(surface, half, planned, opts)
    opts=opts or {}
    if #planned==0 then return {}, {checked=true} end
    local info=M.pocket_window(planned)
    if not info.checked then return {},info end
    local l,t,r,b=info.area.left_top.x,info.area.left_top.y,info.area.right_bottom.x,info.area.right_bottom.y
    local area={{l,t},{r,b}}
    local nx,ny=(r-l)/STEP+1,(b-t)/STEP+1
    local old,now,edge={},{},{}
    -- Rasterize each obstacle once. Strict bounds match overlaps(): touching
    -- a collision edge is free. Planned boxes win so boundary IDs survive.
    local function raster(cells,boxes)
      for _,box in ipairs(boxes) do
        local i0=math.max(0,math.floor((box[1]-half-l)/STEP)+1)
        local i1=math.min(nx-1,math.ceil((box[3]+half-l)/STEP)-1)
        local j0=math.max(0,math.floor((box[2]-half-t)/STEP)+1)
        local j1=math.min(ny-1,math.ceil((box[4]+half-t)/STEP)-1)
        for j=j0,j1 do for i=i0,i1 do cells[j*nx+i+1]=box end end
      end
    end
    raster(old,collision_boxes(surface,area,{ignore=opts.ignore,force=opts.force}))
    raster(now,collision_boxes(surface,area,{ignore=opts.ignore,force=opts.force,open=opts.open}))
    raster(now,planned)
    for j=0,ny-1 do for i=0,nx-1 do
      local k=j*nx+i+1
      edge[k]=i==0 or j==0 or i==nx-1 or j==ny-1
    end end
    -- Scanline flood: each open row segment queues at most one seed per
    -- adjoining segment, instead of visiting four neighbours per grid point.
    local function fill(cells,seen,queue,spans,stop_at_edge,known_open)
      local head,tail=1,#queue
      while head<=tail do
        local k=queue[head];head=head+1
        if known_open and known_open[k] then return true end
        if not cells[k] and not seen[k] then
          local row=k-(k-1)%nx
          local a,z=k,k
          while a>row and not cells[a-1] and not seen[a-1] and not (known_open and known_open[a-1]) do a=a-1 end
          while z<row+nx-1 and not cells[z+1] and not seen[z+1] and not (known_open and known_open[z+1]) do z=z+1 end
          local opened=stop_at_edge and (edge[a] or edge[z] or known_open and (known_open[a-1] or known_open[z+1]))
          local up,down=false,false
          for n=a,z do
            seen[n]=true
            local u=n-nx
            local free=u>0 and not cells[u] and not seen[u]
            if free and not up then tail=tail+1;queue[tail]=u end
            up=free
            local d=n+nx
            free=d<=nx*ny and not cells[d] and not seen[d]
            if free and not down then tail=tail+1;queue[tail]=d end
            down=free
          end
          if opened then return true end
          if spans then spans[#spans+1]={a,z} end
        end
      end
    end
    local function exterior(cells)
      local seen,queue={},{}
      for k=1,nx*ny do if edge[k] and not cells[k] then queue[#queue+1]=k end end
      fill(cells,seen,queue)
      return seen
    end
    local seen=exterior(now)
    local old_closed,old_open,out,total={},{},{},0
    for seed=1,nx*ny do if not now[seed] and not seen[seed] then
      local spans={};fill(now,seen,{seed},spans)
      local changed=false
      local function was_open(k)
        if old[k] or old_open[k] then return true end
        if old_closed[k] then return false end
        local visited={}
        local open=fill(old,visited,{k},nil,true,old_open)
        local cache=open and old_open or old_closed
        for n in pairs(visited) do cache[n]=true end
        cache[k]=true
        return open or false
      end
      local x0,y0,x1,y1=r,b,l,t
      local boundary,count={},0
      local function hit(n)
        local box=now[n]
        if box then
          if box[6] then boundary[box[6]]=true end
          if box.ids then for _,id in ipairs(box.ids) do boundary[id]=true end end
        end
      end
      for _,span in ipairs(spans) do
        local a,z=span[1],span[2]
        local y=t+math.floor((a-1)/nx)*STEP
        x0=math.min(x0,l+(a-1)%nx*STEP);x1=math.max(x1,l+(z-1)%nx*STEP)
        y0,y1=math.min(y0,y),math.max(y1,y)
        count=count+z-a+1
        hit(a-1);hit(z+1)
        for n=a,z do
          changed=changed or was_open(n)
          if now[n-nx] then hit(n-nx) end
          if now[n+nx] then hit(n+nx) end
        end
      end
      if changed and next(boundary) then
        total=total+1
        if #out<4 then
          local around={}
          for _,p in ipairs(planned) do if p.base and boundary[p[6]] then around[#around+1]=p end end
          out[#out+1]={region={x0=x0,y0=y0,x1=x1,y1=y1,tiles=math.floor(count*STEP*STEP+0.5)},around=around}
        end
      end
    end end
    info.checked=true;info.cells=nx*ny;info.pockets=total;info.more=total>#out and total-#out or nil
    return out,info
  end
  -- After a build: closed in now, and not without the entities just built;
  -- those that each fill the last gap out. nil otherwise.
  function M.closed_by(surface, start, half, built, opts)
    opts = opts or {}
    local function flood(skip) return M.region(surface, start, half, {ignore=opts.ignore, force=opts.force, skip=skip, window=TRAP_WINDOW}) end
    local now = flood(nil)
    if not (now and now.closed) or now.stuck then return nil end
    local all = {}
    for _, e in ipairs(built) do if e.valid and e.unit_number then all[e.unit_number] = true end end
    if not next(all) then return nil end
    local before = flood(all)
    if not before or before.closed then return nil end
    local gaps = {}
    for i, e in ipairs(built) do
      if i > MAX_TRIES then break end
      if e.valid and e.unit_number then
        local r = flood({[e.unit_number]=true})
        if r and not r.closed then gaps[#gaps+1] = e end
      end
    end
    return {region=now, gaps=gaps}
  end

  -- Closed in: the entities to mine for a way out (friction2: Gemini, shift12 19:51, followed seven hints one entity
  -- at a time, two poles, four accumulators and a recycler, each opening only a larger closed pocket; the search then
  -- counted quarter-tile steps, so a pole's small box looked cheapest). A search over the tiles round the closed
  -- area: a tile is free when the character's box, padded to turn, fits at its centre; stepping onto a tile costs the
  -- entities there that the tile before did not hold, by kind (DIG_WEIGHT: chests, accumulators, walls, solar panels,
  -- trees and rocks 1; belts, pipes and inserters 2; poles, machines and the rest 3); cliffs, tiles and others'
  -- entities never. It ends on a free tile at the window's edge (open ground, past every closed pocket on the way) or
  -- on the goal's tile (opts.goal), whichever costs less. opts.area {x0, y0, x1, y1}: the window (default 24 tiles
  -- round start; at most DIG_SIDE tiles a side). On a copy of world n's Fulgora island a search took 2 to 8 ms at 32
  -- tiles a side, against 1.3 to 3.3 ms for the old one, which stopped at the first pocket. Returns {mine={{name,
  -- position}}, to, cost, goal (true when it ends at the goal)}, or nil when no way out costs DIG_COST or less.
  local DIG_WEIGHT = {container=1, ['logistic-container']=1, ['linked-container']=1, accumulator=1, wall=1, gate=1,
    ['solar-panel']=1, lamp=1, tree=1, plant=1, ['simple-entity']=1, ['simple-entity-with-owner']=1,
    ['transport-belt']=2, ['underground-belt']=2, splitter=2, ['lane-splitter']=2, loader=2, ['loader-1x1']=2,
    inserter=2, pipe=2, ['pipe-to-ground']=2, pump=2}
  -- Never named to mine for a way (friction4: Gemini, shift14 23:13, was told to mine a rocket silo holding a ready
  -- rocket and 1000 science packs): a silo, a landing pad, a platform hub.
  local DIG_NEVER = {['rocket-silo']=true, ['cargo-landing-pad']=true, ['space-platform-hub']=true}
  local DIG_COST, DIG_SIDE = 16, 64
  M.DIG_WEIGHT = DIG_WEIGHT
  function M.dig(surface, start, half, opts)
    opts = opts or {}
    local w = opts.area or {start.x - WINDOW, start.y - WINDOW, start.x + WINDOW, start.y + WINDOW}
    local tx0, ty0 = math.floor(math.max(w[1], start.x - DIG_SIDE / 2)), math.floor(math.max(w[2], start.y - DIG_SIDE / 2))
    local tx1, ty1 = math.ceil(math.min(w[3], start.x + DIG_SIDE / 2)) - 1, math.ceil(math.min(w[4], start.y + DIG_SIDE / 2)) - 1
    -- goal_only (M.corridor): the window as given (the caller bounds it), and the search ends near the goal only.
    if opts.goal_only then tx0, ty0, tx1, ty1 = math.floor(w[1]), math.floor(w[2]), math.ceil(w[3]) - 1, math.ceil(w[4]) - 1 end
    local goal_only, near2 = opts.goal_only, (opts.near or 1.5) ^ 2
    local boxes = boxes_in(surface, {{tx0, ty0}, {tx1 + 1, ty1 + 1}}, opts.ignore)
    local h = half + PAD
    local force = opts.force
    -- What stands on each tile (its centre, the padded box): entities the character may mine, by index (one index, or
    -- a list of them); stop: anything else. Whether a kind is minable, and its weight, read once per name.
    local on, stop, ents, weight, kinds = {}, {}, {}, {}, {}
    for _, b in ipairs(boxes) do
      local e = b[6]
      local ei
      if e then
        local kind = kinds[b[5]]
        if kind == nil then
          local ok, t, m = pcall(function() return e.type, e.minable end)
          kind = ok and m and t ~= 'cliff' and not DIG_NEVER[t] and (DIG_WEIGHT[t] or 3) or false
          kinds[b[5]] = kind
        end
        if kind then
          local ok, ours = pcall(function() local f = e.force; return f == force or f.name == 'neutral' end)
          if ok and ours then ents[#ents+1] = e; ei = #ents; weight[ei] = kind end
        end
      end
      for tx = math.max(tx0, math.floor(b[1] - 0.5 - h) + 1), math.min(tx1, math.ceil(b[3] - 0.5 + h) - 1) do
        local base = tx * 65536
        for ty = math.max(ty0, math.floor(b[2] - 0.5 - h) + 1), math.min(ty1, math.ceil(b[4] - 0.5 + h) - 1) do
          local k = base + ty
          if ei then
            local l = on[k]
            if l == nil then on[k] = ei elseif type(l) == 'number' then on[k] = {l, ei} else l[#l+1] = ei end
          else stop[k] = true end
        end
      end
    end
    -- Tiles by number (i * 65536 + j; the four neighbours are k +- 65536 and k +- 1), the queue a list of numbers per
    -- cost: no table made per step (a table per step made this 15 to 30 ms on a copy of world n's Fulgora island).
    local sx, sy = math.floor(start.x), math.floor(start.y)
    local gk = opts.goal and cell(math.floor(opts.goal.x), math.floor(opts.goal.y)) or nil
    local sk = cell(sx, sy)
    local best, done, from, buckets = {[sk]=0}, {}, {}, {[0]={sk}}
    local target, level = nil, 0
    local DK = {65536, -65536, 1, -1}
    while level <= DIG_COST and not target do
      local list, idx = buckets[level], 1
      while list and idx <= #list do
        local k = list[idx]; idx = idx + 1
        if not done[k] and best[k] == level then
          done[k] = true
          local i = math.floor((k + 32768) / 65536)
          local j = k - i * 65536
          local here = on[k]
          if goal_only then
            if not stop[k] and (i + 0.5 - opts.goal.x) ^ 2 + (j + 0.5 - opts.goal.y) ^ 2 <= near2 then target = k; break end
          elseif level > 0 and not here and not stop[k] and (k == gk or i <= tx0 or j <= ty0 or i >= tx1 or j >= ty1) then target = k; break end
          -- (the start tile counts as stood on nothing: the character is beside what its tile holds)
          if k == sk then here = nil end
          for n = 1, 4 do
            local d = DK[n]
            local ni, nj = i, j
            if d == 65536 then ni = i + 1 elseif d == -65536 then ni = i - 1 elseif d == 1 then nj = j + 1 else nj = j - 1 end
            if ni >= tx0 and ni <= tx1 and nj >= ty0 and nj <= ty1 then
              local nk = k + d
              if not done[nk] and not stop[nk] then
                local nl = level
                local there = on[nk]
                if there then
                  if type(there) == 'number' then
                    -- one entity there: free when the tile before holds it too
                    local stood = here == there
                    if not stood and type(here) == 'table' then for _, ej in ipairs(here) do if ej == there then stood = true; break end end end
                    if not stood then nl = nl + weight[there] end
                  else
                    for _, ei in ipairs(there) do
                      local stood = here == ei
                      if not stood and type(here) == 'table' then for _, ej in ipairs(here) do if ej == ei then stood = true; break end end end
                      if not stood then nl = nl + weight[ei] end
                    end
                  end
                end
                local was = best[nk]
                if nl <= DIG_COST and (was == nil or nl < was) then
                  best[nk] = nl; from[nk] = k
                  local b = buckets[nl]; if not b then b = {}; buckets[nl] = b end
                  b[#b+1] = nk
                end
              end
            end
          end
        end
      end
      if not target then level = level + 1 end
    end
    if not target then return nil end
    -- The entities on the way, in order from the character.
    local steps, c = {}, target
    while c do steps[#steps+1] = c; c = from[c] end
    local mine, have = {}, {}
    -- (not the start tile's own: the character stands beside what it holds, and crossing it was paid on the next tile)
    for k = #steps - 1, 1, -1 do
      local l = on[steps[k]]
      for _, ei in ipairs(type(l) == 'number' and {l} or l or {}) do
        local e = ents[ei]
        if not have[ei] and e.valid then
          have[ei] = true
          mine[#mine+1] = {name=e.name, position={x=e.position.x, y=e.position.y}}
        end
      end
    end
    if #mine == 0 then return nil end
    local ti = math.floor((target + 32768) / 65536)
    return {mine=mine, to={x=ti + 0.5, y=target - ti * 65536 + 0.5}, cost=level, goal=(goal_only or target == gk) or nil}
  end
  -- Not closed in, yet no way to the goal (round1820a, Astra on Fulgora: packed accumulators, 6 failed walks in about 4
  -- game minutes; lifting 2 of them, then pathfind=false, got through): the fewest of our entities, trees or rocks to
  -- mine for a way from where the character can get to (from) to within near of the goal, as for a pocket (M.dig,
  -- ending at the goal only). The window spans both and 8 tiles round them, at most 48 a side (on a copy of world n's
  -- Fulgora island 1.4 to 2.3 ms for Gemini's accumulators, 9 ms at 41 by 46); a goal farther than that is left alone.
  -- Returns M.dig's answer with from, or nil (nothing to mine, or no way within DIG_COST).
  local CORRIDOR_SIDE = 48
  function M.corridor(p, from, goal, near)
    if not (from and goal and p.character and p.character.valid) then return nil end
    local x0, y0 = math.min(from.x, goal.x) - 8, math.min(from.y, goal.y) - 8
    local x1, y1 = math.max(from.x, goal.x) + 8, math.max(from.y, goal.y) + 8
    if x1 - x0 > CORRIDOR_SIDE or y1 - y0 > CORRIDOR_SIDE then return nil end
    local dug = M.dig(p.surface, from, M.half(p.character), {ignore=p.character, force=p.force, area={x0, y0, x1, y1}, goal=goal,
      goal_only=true, near=math.max(1.5, near or 1.5)})
    if dug then dug.from = {x=from.x, y=from.y} end
    return dug
  end

  -- The tick after a closed-in give-up: the way out by mining, then unreachable.
  function M.dig_step(p, nav)
    local from = nav.dig_from or p.position
    local dug = M.dig(p.surface, from, M.half(p.character), {ignore=p.character, force=p.force, area=nav.dig_area, goal=nav.position})
    if dug then
      nav.dig = dug
      local names = {}
      for i, e in ipairs(dug.mine) do names[i] = e.name .. ' ' .. at(e.position) end
      nav.why = (nav.why or '') .. string.format('; mining %s opens a way %s at %s', table.concat(names, ' and '),
        dug.goal and 'to the goal' or 'out to open ground', at(dug.to))
    end
    nav.dig_from, nav.dig_area = nil, nil
    -- Closed in: the nearest step of the area, when within build reach.
    local r = nav.reachable
    if r and goal_dist(nav, r) <= spot_reach(spot_R(p, nav)) then return found_spot(p, nav, r, nil) end
    nav.spot = {none=true, goal={x=nav.position.x, y=nav.position.y}, reach=spot_R(p, nav), label=nav.reach_label, closed=true}
    nav.path_state = 'unreachable'
  end
  -- Room to turn where the character stands: a box padded by PAD fits.
  function M.clear_at(surface, pos, h, ignore)
    return hits(boxes_in(surface, {{pos.x - h - 0.5, pos.y - h - 0.5}, {pos.x + h + 0.5, pos.y + h + 0.5}}, ignore), pos.x, pos.y, h) == nil
  end
  -- Squeezed in where the pathfinder found no route (Sol, shift09 03:13: in
  -- the 0.6-tile gap between two assembling machines and under a pipe row,
  -- every path request failed and the walk stalled): walk the flood's trail
  -- to the nearest spot with room to turn, then ask again. Up to three times,
  -- each wanting more room. Returns true when an escape walk starts.
  M.ESCAPE_PADS = {PAD, 0.35, 0.6}
  function M.escape(p, nav)
    local n = (nav.escapes or 0) + 1
    if n > #M.ESCAPE_PADS then return false end
    local c = p.character
    local half = M.half(c)
    local here = p.position
    if n == 1 and M.clear_at(p.surface, here, half + PAD, c) then return false end
    local r = M.region(p.surface, here, half, {ignore=c, force=p.force, open_pad=M.ESCAPE_PADS[n]})
    if not r.open or (r.steps == 0 and dist(here, r.open) < 0.05) then return false end
    nav.escapes = n
    nav.escape = {from={x=here.x, y=here.y}, to=r.open}
    nav.escape_first = nav.escape_first or nav.escape.from
    local wps = {}
    for i, q in ipairs(r.trail) do wps[i] = {position=q} end
    nav.waypoints = wps; nav.waypoint = 1; nav.reach = 0.12
    nav.path_state = 'escape'; nav.found = nil; nav.sidestep = nil; nav.stalled = 0; nav.progress_tick = nil
    return true
  end
  -- squeeze=true and no path request found a route: a search to within the
  -- arrival radius (path_state searching), then its trail walked waypoint by
  -- waypoint (path_state trail). Returns true when the search starts.
  function M.squeeze_begin(p, nav)
    nav.squeeze_tried = true
    local c = p.character
    local here = p.position
    local S = M.search_begin(p.surface, here, M.half(c), nav.position, math.max(nav.tolerance, STEP), {ignore=c, force=p.force})
    if not S then return false end
    nav.search = {S=S, mode='squeeze', from={x=here.x, y=here.y}}
    nav.path_state = 'searching'
    return true
  end
  function M.walk_trail(p, nav, r, from)
    local wps = {}
    for i, q in ipairs(r.trail) do wps[i] = {position=q} end
    nav.waypoints = wps; nav.waypoint = 1; nav.reach = 0.12
    nav.path_state = 'trail'; nav.found = nil; nav.sidestep = nil; nav.stalled = 0; nav.progress_tick = nil
    nav.squeezed = {from=from or {x=p.position.x, y=p.position.y}, to=r.spot}
  end
  -- The escape trail walked: ask for the route again from here.
  function M.escaped(p, nav)
    nav.reach = nil; nav.path_level = 0
    nav.escaped_to = nav.escape and nav.escape.to or nil
    nav.escape = nil
    M.request(p, nav)
  end

  -- A goal in a gap the pathfinder did not route into: within the arrival
  -- radius (+ a quarter tile) of it the character's own box fits somewhere,
  -- a box with room to turn (padded by PAD) nowhere. Returns the step of the
  -- gap nearest the goal and what hems it in, else nil (room there, or solid:
  -- a goal inside an entity, walked up to as before).
  function M.in_gap(surface, goal, half, tol, ignore)
    local R = tol + STEP
    local h = half + PAD
    local boxes = boxes_in(surface, {{goal.x - R - h - 0.5, goal.y - R - h - 0.5}, {goal.x + R + h + 0.5, goal.y + R + h + 0.5}}, ignore)
    if #boxes == 0 then return nil end
    local best, bd
    for i = math.floor((goal.x - R) / STEP), math.ceil((goal.x + R) / STEP) do
      for j = math.floor((goal.y - R) / STEP), math.ceil((goal.y + R) / STEP) do
        local x, y = i * STEP, j * STEP
        local d = ((x - goal.x) ^ 2 + (y - goal.y) ^ 2) ^ 0.5
        if d <= R and not hits(boxes, x, y, half) then
          if not hits(boxes, x, y, h) then return nil end
          if not bd or d < bd then best, bd = {x=x, y=y}, d end
        end
      end
    end
    if not best then return nil end
    local by, have = {}, {}
    for _, b in ipairs(boxes) do
      if overlaps(b, best.x, best.y, h + 0.25) and #by < 4 then
        local pos = b[6] and b[6].valid and b[6].position or {x=(b[1] + b[3]) / 2, y=(b[2] + b[4]) / 2}
        local text = b[5] .. ' ' .. at(pos)
        if not have[text] then have[text] = true; by[#by+1] = text end
      end
    end
    return {x=best.x, y=best.y, by=by}
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
  -- within the arrival radius of the target (or, given within, a tile within
  -- reach of a walk's target entity); else within 3 tiles of it. avoid: a tile
  -- it must not be either (runtime.lua: one under a rail).
  function M.off_belt_spot(p, target, tolerance, within, avoid)
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
              if (not bd or d < bd) and (limit == math.huge or (within and within(c)) or (not within and dist(c, target) <= limit))
                and M.free_tile(surface, c, half, p.character) and not (avoid and avoid(c)) then best, bd = c, d end
            end
          end
        end
      end
      return best
    end
    local best = scan(within and 4 or math.min(10, math.ceil(tolerance) + 1), tolerance)
    if best then return best, true end
    return scan(3, math.huge), false
  end
  return M
end
