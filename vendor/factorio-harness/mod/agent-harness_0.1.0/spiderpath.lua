-- A spidertron's route round wide water (d24 batch191 addendum, viewer Aurora site:4826: "Could batch 191 route
-- Spidertrons around wide water, validate every waypoint segment and detect no progress? Apply this to travel and
-- retreat, with a tested shore-recovery fallback."). In 2.0.77 a script's route gets no pathing: add_autopilot_destination
-- walks the straight line (copy of world n's 20:12 save: no waypoints were added; at a wide lake it stood at the shore
-- with the target kept). Its legs (layers player and rail) stand on no tile with the water_tile layer (in 2.0.77 every
-- tile they cannot stand on has it: water, deepwater, lava, ammoniacal ocean, brash ice, empty space, out of map), and
-- they stepped across a strip of deepwater 14 tiles wide; 16 stopped it.
-- - segment(surface, a, b): the straight line read tile by tile; a run of more than GAP tiles with water_tile blocks it;
-- - plan(spider, targets, rec): each segment from where it stands through its targets; a blocked one gets a
--   LuaSurface.request_path with the water_tile layer only (so it walks over buildings and trees, as legs do) and a
--   BOX box; the path comes back thinned to points SPACING tiles apart along it (each straight leg read again, the
--   path's own points kept where one is blocked), and the route becomes the targets with those points between;
-- - shore(surface, pos, target): the tile its legs stand on nearest the target, on rings 4..24 tiles round pos.
-- The callers say what was done; facts only.
return function(api)
  local M = {}
  M.GAP, M.SPACING, M.BOX, M.MAX_POINTS = 12, 12, 1, 120
  local water = {}  -- tile name -> has water_tile (prototype facts: the same on every peer)
  local function dist(a, b) return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2) end
  local function at(q) return string.format('(%g,%g)', math.floor(q.x * 10 + 0.5) / 10, math.floor(q.y * 10 + 0.5) / 10) end
  M.at = at
  -- (read per tile: no pcall or closure; get_tile answers out-of-map off the generated chunks)
  local function wet(surface, x, y)
    local t = surface.get_tile(x, y)
    local name = t.name
    local w = water[name]
    if w == nil then w = t.collides_with('water_tile') and true or false; water[name] = w end
    return w, name
  end
  M.wet = wet
  local function store()
    local s = api.state()
    s.spiderpaths = s.spiderpaths or {req={}, plans={}, seq=0}
    return s.spiderpaths
  end
  -- The straight line a -> b: nil when its legs can walk it, else {at, run, tile, line} for the first run of more
  -- than GAP tiles they cannot stand on.
  function M.segment(surface, a, b)
    local d = dist(a, b)
    local n = math.max(1, math.ceil(d))
    local run, start, name = 0, nil, nil
    for k = 0, n do
      local x, y = a.x + (b.x - a.x) * k / n, a.y + (b.y - a.y) * k / n
      local w, tile = wet(surface, x, y)
      if w then
        if run == 0 then start, name = {x=math.floor(x) + 0.5, y=math.floor(y) + 0.5}, tile end
        run = run + d / n
      elseif run > 0 then
        if run > M.GAP then break end
        run = 0
      end
    end
    if run <= M.GAP then return nil end
    run = math.floor(run + 0.5)
    return {at=start, run=run, tile=name, line=string.format('%s -> %s crosses %d tiles of %s from %s', at(a), at(b), run, name, at(start))}
  end
  -- The path's points SPACING tiles apart (and its end), each straight leg read again: a blocked leg keeps the path's
  -- own points between. nil when over MAX_POINTS.
  function M.thin(surface, path)
    local pts = {}
    for i, w in ipairs(path) do pts[i] = w.position end
    local keep, last, acc = {}, 1, 0
    for i = 2, #pts do
      acc = acc + dist(pts[i - 1], pts[i])
      if acc >= M.SPACING or i == #pts then
        if M.segment(surface, pts[last], pts[i]) then
          for j = last + 1, i do keep[#keep + 1] = {x=pts[j].x, y=pts[j].y} end
        else
          keep[#keep + 1] = {x=pts[i].x, y=pts[i].y}
        end
        last, acc = i, 0
      end
    end
    if #keep > M.MAX_POINTS then return nil end
    return keep
  end
  -- Water within n tiles on the line pos -> q (a shore ahead).
  function M.water_ahead(surface, pos, q, n)
    local d = dist(pos, q)
    for k = 1, math.min(math.floor(d), n or M.GAP + 4) do
      if wet(surface, pos.x + (q.x - pos.x) * k / d, pos.y + (q.y - pos.y) * k / d) then return true end
    end
    return false
  end
  -- The tile its legs stand on nearest the target, on rings round pos (4..24 tiles, 16 directions); nil when none.
  function M.shore(surface, pos, target)
    local best, bd
    for r = 4, 24, 4 do
      for k = 0, 15 do
        local a = k * math.pi / 8
        local q = {x=math.floor(pos.x + r * math.cos(a)) + 0.5, y=math.floor(pos.y + r * math.sin(a)) + 0.5}
        if not wet(surface, q.x, q.y) then
          local d = dist(q, target)
          if not bd or d < bd then best, bd = q, d end
        end
      end
    end
    return best
  end
  function M.request(surface, force, from, to, rec)
    local st = store()
    local id = surface.request_path{bounding_box={{-M.BOX, -M.BOX}, {M.BOX, M.BOX}}, collision_mask={layers={water_tile=true}},
      start=from, goal=to, force=force, radius=3, pathfind_flags={prefer_straight_paths=true, no_break=true}}
    st.req[id] = rec
    return id
  end
  -- Each segment from the spidertron through targets; the blocked ones' paths requested. rec: {owner, unit, by, index}
  -- (owner 'route': plan's own route write when every path is in; 'kite': spiderkite.lua's). -> lines (nil: none
  -- blocked), and the plan stored for the results.
  function M.plan(spider, targets, rec)
    local st = store()
    local lines, segs, pending = {}, {}, 0
    local from = spider.position
    st.seq = st.seq + 1
    for i, q in ipairs(targets) do
      local b = M.segment(spider.surface, from, q)
      if b then
        lines[#lines + 1] = b.line
        -- a path from a tile with water finds none: a body over the water at a shore starts from the nearest dry tile
        local start = from
        if i == 1 and wet(spider.surface, from.x, from.y) then start = M.shore(spider.surface, from, from) or from end
        local ok = pcall(M.request, spider.surface, spider.force, start, q, {owner=rec.owner, unit=spider.unit_number, seq=st.seq, seg=i, index=rec.index})
        if ok then pending = pending + 1; segs[i] = 'pending' else segs[i] = false end
      end
      from = q
    end
    if #lines == 0 then st.plans[spider.unit_number] = nil; return nil end
    local copy = {}
    for i, q in ipairs(targets) do copy[i] = {x=q.x, y=q.y} end
    st.plans[spider.unit_number] = {seq=st.seq, targets=copy, segs=segs, pending=pending, by=rec.by, owner=rec.owner, tick=game.tick}
    return lines
  end
  -- The route a plan gives: each target, with a found path's points before it.
  local function assemble(plan, surface)
    local out, notes = {}, {}
    for i, q in ipairs(plan.targets) do
      local seg = plan.segs[i]
      if type(seg) == 'table' then
        for _, w in ipairs(seg) do out[#out + 1] = w end
        if #seg == 0 or dist(seg[#seg], q) > 1 then out[#out + 1] = q end
      else
        if seg == false then notes[#notes + 1] = 'the pathfinder found no path round the water to ' .. at(q) .. (wet(surface, q.x, q.y) and ' (the target itself is on water)' or '') end
        out[#out + 1] = q
      end
    end
    return out, notes
  end
  -- on_script_path_request_finished: true when the id is ours. Calls back route(rec, plan, points, notes) once a
  -- plan's last path is in (owner 'route' writes the route itself and calls back with it written).
  function M.on_path(event, done)
    local st = api.state().spiderpaths
    local rec = st and st.req[event.id]
    if not rec then return false end
    st.req[event.id] = nil
    local plan = st.plans[rec.unit]
    if not plan or plan.seq ~= rec.seq then return true end  -- a later plan replaced it
    local spider = game.get_entity_by_unit_number(rec.unit)
    if not (spider and spider.valid) then st.plans[rec.unit] = nil; return true end
    local pts = event.path and M.thin(spider.surface, event.path)
    plan.segs[rec.seg] = pts or false
    plan.pending = plan.pending - 1
    if plan.pending > 0 then return true end
    st.plans[rec.unit] = nil
    local route, notes = assemble(plan, spider.surface)
    done(rec, plan, spider, route, notes)
    return true
  end
  -- The route written as the remote's clicks: emptied, then each point. -> the error text, or nil.
  function M.write(spider, route)
    local ok, err = pcall(function()
      spider.autopilot_destination = nil
      for _, q in ipairs(route) do spider.add_autopilot_destination(q) end
    end)
    if not ok then return tostring(err) end
  end
  return M
end
