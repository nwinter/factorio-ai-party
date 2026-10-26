-- A spidertron's route round wide water (d24 batch191 addendum, viewer Aurora site:4826: "Could batch 191 route
-- Spidertrons around wide water, validate every waypoint segment and detect no progress? Apply this to travel and
-- retreat, with a tested shore-recovery fallback."). In 2.0.77 a script's route gets no pathing: add_autopilot_destination
-- walks the straight line (copy of world n's 20:12 save: no waypoints were added; at a wide lake it stood at the shore
-- with the target kept). Its legs (layers player and rail) stand on no tile with the water_tile layer (in 2.0.77 every
-- tile they cannot stand on has it: water, deepwater, lava, ammoniacal ocean, brash ice, empty space, out of map), and
-- they stepped across a strip of deepwater 14 tiles wide; 16 stopped it.
-- - segment(surface, a, b): the straight line read tile by tile; a run of more than GAP tiles its legs cannot stand on
--   blocks it;
-- - plan(spider, targets, rec): each segment from where it stands through its targets; a blocked one gets a
--   LuaSurface.request_path with the doodad layer only (the tiles its legs cannot stand on; below) and a
--   BOX box; the path comes back thinned to points SPACING tiles apart along it (each straight leg read again, the
--   path's own points kept where one is blocked), and the route becomes the targets with those points between;
-- - shore(surface, pos, target): the tile its legs stand on nearest the target, on rings 4..24 tiles round pos.
-- (d26 batch243 SR, viewer Aurora 13:42: spidertron #27069154 stood 1 tile from water at (78,339) for 8 min while every
-- path round it came back "found no path") a path request from a start or to a goal whose box touches water finds
-- none, a goal on water none, and a start on a patch the box cannot leave (an island to the pathfinder that legs step
-- off) none; so:
-- - dry(surface, q, rmax): the nearest point within rmax tiles whose BOX box holds no water: starts and goals move there;
-- - a failed path is asked again from up to HOPS dry spots its legs can step to across water (a straight line with no
--   run of over GAP tiles), nearest the goal first; the first path that comes wins, with that spot first (island escape);
-- - a path over MAX_POINTS points is thinned again at twice the spacing (it was "no path" before).
-- - (copy of world n's 13:37 save) in 2.0.77 most entities' collision masks hold water_tile (buildings, belts, poles,
--   inserters, trees, rocks: 223 prototypes), so a path request with that layer took the base for walls: from the shore at
--   (57,337) to (601,551) it found none (29 ticks); with doodad, 570 points. The 13 tiles its legs (player, rail) stand on
--   none of are exactly the 13 with doodad (water, deepwater, lava, out-of-map, empty space ...; shallow water and mud
--   have neither), and only corpses and rail remnants carry doodad among entities: requests use doodad, and wet() the
--   legs' own layers. The pathfinder's cache kept a failure for a later request between the same spots: cache off.
-- The callers say what was done; facts only.
return function(api)
  local M = {}
  -- (d26 batch243) BOX 0.5: a 1x1 box at a tile's centre covers that tile; the 2x2 box (BOX 1) at a centre overlaps 3x3
  -- tiles, and on the islet at (75,338), where #27069154 stood, no spot had room for it (8 had for 1x1)
  M.GAP, M.SPACING, M.BOX, M.MAX_POINTS = 12, 12, 0.4, 120
  M.HOPS, M.HOP_MIN, M.DRY_START, M.DRY_GOAL, M.LAND, M.DRY_FAR = 4, 4, 8, 24, 20, 48
  local water = {}  -- tile name -> its legs cannot stand on it (player or rail layer; prototype facts: the same on every peer)
  local function dist(a, b) return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2) end
  local function at(q) return string.format('(%g,%g)', math.floor(q.x * 10 + 0.5) / 10, math.floor(q.y * 10 + 0.5) / 10) end
  M.at = at
  -- (read per tile: no pcall or closure; get_tile answers out-of-map off the generated chunks)
  local function wet(surface, x, y)
    local t = surface.get_tile(x, y)
    local name = t.name
    local w = water[name]
    if w == nil then w = (t.collides_with('player') or t.collides_with('rail')) and true or false; water[name] = w end
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
  function M.segment(surface, a, b, gap)
    gap = gap or M.GAP
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
        if run > gap then break end
        run = 0
      end
    end
    if run <= gap then return nil end
    run = math.floor(run + 0.5)
    return {at=start, run=run, tile=name, line=string.format('%s -> %s crosses %d tiles of %s from %s', at(a), at(b), run, name, at(start))}
  end
  -- The path's points SPACING tiles apart (and its end), each straight leg read again: a blocked leg keeps the path's
  -- own points between. nil when over MAX_POINTS.
  function M.thin(surface, path, spacing)
    spacing = spacing or M.SPACING
    local pts = {}
    for i, w in ipairs(path) do pts[i] = w.position end
    local keep, last, acc = {}, 1, 0
    for i = 2, #pts do
      acc = acc + dist(pts[i - 1], pts[i])
      if acc >= spacing or i == #pts then
        if M.segment(surface, pts[last], pts[i]) then
          for j = last + 1, i do keep[#keep + 1] = {x=pts[j].x, y=pts[j].y} end
        else
          keep[#keep + 1] = {x=pts[i].x, y=pts[i].y}
        end
        last, acc = i, 0
      end
    end
    if #keep > M.MAX_POINTS then
      -- (d26 batch243) a long detour: twice the spacing, up to 4 times; a blocked leg still keeps the path's own points
      if spacing < M.SPACING * 16 then return M.thin(surface, path, spacing * 2) end
      return nil
    end
    return keep
  end
  -- (d26 batch243) the BOX box round q holds no tile its legs cannot stand on
  function M.clear(surface, q)
    local b = M.BOX
    for x = math.floor(q.x - b), math.floor(q.x + b - 0.001) do
      for y = math.floor(q.y - b), math.floor(q.y + b - 0.001) do
        if wet(surface, x + 0.5, y + 0.5) then return false end
      end
    end
    return true
  end
  -- The nearest point within rmax tiles of q (q itself first, then rings 1 tile apart, 8 points per tile of radius)
  -- whose box holds no water; nil when none.
  function M.dry(surface, q, rmax)
    if M.clear(surface, q) then return {x=q.x, y=q.y} end
    for r = 1, rmax or M.DRY_GOAL do
      if r <= 16 or r % 2 == 0 then  -- every ring to 16 tiles, then every second one; 48 points at most a ring
        -- (copy: a target mid-lake read ~5300 tiles, 12.8 ms a go_to; capped, ~1400)
        local n = math.min(8 * r, 48)
        for k = 0, n - 1 do
          local a = 2 * math.pi * k / n
          local c = {x=math.floor(q.x + r * math.cos(a)) + 0.5, y=math.floor(q.y + r * math.sin(a)) + 0.5}
          if M.clear(surface, c) then return c end
        end
      end
    end
    return nil
  end
  -- (d26 batch243) a back-off spot: 3..8 tiles from pos straight away from q (back the way it came) with room for the
  -- box, else the nearest spot with room at least 3 tiles away; nil when none.
  function M.back(surface, pos, q)
    local d = dist(pos, q)
    if d > 0.01 then
      local ux, uy = (pos.x - q.x) / d, (pos.y - q.y) / d
      for k = 3, 8 do
        local c = {x=math.floor(pos.x + ux * k) + 0.5, y=math.floor(pos.y + uy * k) + 0.5}
        if M.clear(surface, c) then return c end
      end
    end
    for r = 3, 8 do
      for k = 0, 8 * r - 1 do
        local a = 2 * math.pi * k / (8 * r)
        local c = {x=math.floor(pos.x + r * math.cos(a)) + 0.5, y=math.floor(pos.y + r * math.sin(a)) + 0.5}
        if M.clear(surface, c) then return c end
      end
    end
    return nil
  end
  -- The longest run of tiles its legs cannot stand on along the straight line a -> b (0: none).
  function M.run(surface, a, b)
    local d = dist(a, b)
    local n = math.max(1, math.ceil(d))
    local run, most = 0, 0
    for k = 0, n do
      if wet(surface, a.x + (b.x - a.x) * k / n, a.y + (b.y - a.y) * k / n) then run = run + d / n; if run > most then most = run end else run = 0 end
    end
    return most
  end
  -- Dry tiles in the 5x5 round q (25: open land; an islet has few).
  local function land(surface, q)
    local n = 0
    for dx = -2, 2 do for dy = -2, 2 do if not wet(surface, q.x + dx, q.y + dy) then n = n + 1 end end end
    return n
  end
  -- Island escape: up to HOPS dry spots from `from` its legs step to across water (a straight line crossing a run of
  -- 1..GAP tiles of it: not the same land), HOP_MIN..GAP + 4 tiles away; those on open land (LAND of the 25 tiles round
  -- them dry) first, then nearest the goal. (copy: from the islet at (76,338) the 4 nearest the goal were other islets.)
  function M.hops(surface, from, goal)
    local cands = {}
    for r = M.HOP_MIN, M.GAP + 4, 2 do
      for k = 0, 23 do
        local a = k * math.pi / 12
        local c = {x=math.floor(from.x + r * math.cos(a)) + 0.5, y=math.floor(from.y + r * math.sin(a)) + 0.5}
        if M.clear(surface, c) then
          local most = M.run(surface, from, c)
          if most >= 1 and most <= M.GAP then cands[#cands + 1] = {q=c, d=dist(c, goal), open=land(surface, c) >= M.LAND} end
        end
      end
    end
    table.sort(cands, function(a, b) if a.open ~= b.open then return a.open end return a.d < b.d end)
    local out = {}
    for i = 1, math.min(M.HOPS, #cands) do out[i] = cands[i].q end
    return out
  end
  -- Water within n tiles on the line pos -> q (a shore ahead): how many tiles ahead (a number), else false.
  function M.water_ahead(surface, pos, q, n)
    local d = dist(pos, q)
    for k = 1, math.min(math.floor(d), n or M.GAP + 4) do
      if wet(surface, pos.x + (q.x - pos.x) * k / d, pos.y + (q.y - pos.y) * k / d) then return k end
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
    local id = surface.request_path{bounding_box={{-M.BOX, -M.BOX}, {M.BOX, M.BOX}}, collision_mask={layers={doodad=true}},
      start=from, goal=to, force=force, radius=3, pathfind_flags={prefer_straight_paths=true, no_break=true, cache=false}}
    st.req[id] = rec
    return id
  end
  -- Pending path requests for a spidertron's plan (a stall waits for them instead of recovering).
  function M.pending(unit)
    local st = api.state().spiderpaths
    return st and st.plans[unit] ~= nil or false
  end
  -- Each segment from the spidertron (or rec.from) through targets; the blocked ones' paths requested, from and to
  -- spots with room for the box (dry). rec: {owner, unit, by, index, from?, gap?} (owner 'route': plan's own route write
  -- when every path is in; 'kite': spiderkite.lua's; gap 0 after a stall at the water: any water on the line blocks it,
  -- its legs having failed to cross). -> lines (nil: none blocked), and the plan stored for the results.
  function M.plan(spider, targets, rec)
    local st = store()
    local surface = spider.surface
    local lines, segs, wait, starts, goals = {}, {}, {}, {}, {}
    local from = rec.from or spider.position
    local pending = 0
    st.seq = st.seq + 1
    for i, q in ipairs(targets) do
      local b = M.segment(surface, from, q, rec.gap)
      if b then
        lines[#lines + 1] = b.line
        -- (d26 batch243) a start or goal whose box touches water gets no path: the nearest spot with room for it
        starts[i] = M.dry(surface, from, M.DRY_START) or from
        goals[i] = M.dry(surface, q, M.DRY_GOAL) or q
        local ok = pcall(M.request, surface, spider.force, starts[i], goals[i], {owner=rec.owner, unit=spider.unit_number, seq=st.seq, seg=i, index=rec.index})
        if ok then pending = pending + 1; segs[i] = 'pending'; wait[i] = 1 else segs[i] = false end
      end
      from = q
    end
    if #lines == 0 then st.plans[spider.unit_number] = nil; return nil end
    local copy = {}
    for i, q in ipairs(targets) do copy[i] = {x=q.x, y=q.y} end
    st.plans[spider.unit_number] = {seq=st.seq, targets=copy, segs=segs, wait=wait, starts=starts, goals=goals, hops={}, pending=pending,
      by=rec.by, owner=rec.owner, tick=game.tick, via=rec.from and {x=rec.from.x, y=rec.from.y} or nil}
    return lines
  end
  -- A target on water ends at the dry spot nearest it (its legs stand nowhere on it). -> the point, and a note or nil.
  function M.landing(surface, q)
    if not wet(surface, q.x, q.y) then return q, nil end
    local d = M.dry(surface, q, M.DRY_FAR)
    if not d then return q, string.format('the target %s is on water with no tile its legs stand on within %d tiles: it walks toward it and stops at the shore', at(q), M.DRY_FAR) end
    return d, string.format('the target %s is on water: the route ends at %s, the nearest spot its legs stand on', at(q), at(d))
  end
  -- The route a plan gives: (its back-off spot,) each target (on water: the dry spot nearest it), with a found path's
  -- points before it.
  local function assemble(plan, surface)
    local out, notes = {}, {}
    if plan.via then out[1] = plan.via end
    for i, q in ipairs(plan.targets) do
      local seg = plan.segs[i]
      local final, landed = M.landing(surface, q)
      if landed then notes[#notes + 1] = landed end
      if type(seg) == 'table' then
        if plan.hopped and plan.hopped[i] then notes[#notes + 1] = string.format('no path from where it stands (land its box cannot leave): its legs step first to %s across the water, and the path goes on from there', at(plan.hopped[i])) end
        if plan.ghopped and plan.ghopped[i] then notes[#notes + 1] = string.format('no path onto the land of %s (its box cannot reach it): the path goes to %s, and its legs step across the water from there', at(final), at(plan.ghopped[i])) end
        for _, w in ipairs(seg) do out[#out + 1] = w end
        if #seg == 0 or dist(seg[#seg], final) > 1 then out[#out + 1] = final end
      else
        if seg == false then
          local tried = plan.hops[i] and plan.hops[i] > 0 and string.format('; asked again from %d spot%s its legs step to across the water: none either', plan.hops[i], plan.hops[i] == 1 and '' or 's') or ''
          notes[#notes + 1] = 'the pathfinder found no path round the water to ' .. at(q) .. (wet(surface, q.x, q.y) and ' (the target itself is on water)' or '') .. tried
        end
        out[#out + 1] = final
      end
    end
    return out, notes
  end
  M.assemble = assemble
  -- on_script_path_request_finished: true when the id is ours. Calls back route(rec, plan, points, notes) once a
  -- plan's last path is in (owner 'route' writes the route itself and calls back with it written). (d26 batch243) a
  -- segment with no path is asked again from up to HOPS spots its legs step to (island escape), and to up to HOPS spots
  -- it steps from onto the target's land (a target on an island); the first path wins.
  function M.on_path(event, done)
    local st = api.state().spiderpaths
    local rec = st and st.req[event.id]
    if not rec then return false end
    st.req[event.id] = nil
    local plan = st.plans[rec.unit]
    if not plan or plan.seq ~= rec.seq then return true end  -- a later plan replaced it
    local spider = game.get_entity_by_unit_number(rec.unit)
    if not (spider and spider.valid) then st.plans[rec.unit] = nil; return true end
    local i = rec.seg
    plan.wait = plan.wait or {}
    plan.wait[i] = (plan.wait[i] or 1) - 1
    plan.pending = plan.pending - 1
    if type(plan.segs[i]) ~= 'table' then
      local pts = event.path and M.thin(spider.surface, event.path)
      if pts then
        if rec.hop then
          table.insert(pts, 1, {x=rec.hop.x, y=rec.hop.y})
          plan.hopped = plan.hopped or {}
          plan.hopped[i] = rec.hop
        end
        if rec.ghop then
          plan.ghopped = plan.ghopped or {}
          plan.ghopped[i] = rec.ghop
        end
        plan.segs[i] = pts
      elseif not rec.hop and not rec.ghop and not plan.hops[i] and plan.goals and plan.goals[i] then
        -- island escape from the start's side (spots its legs step to from where it stands), and to the target's side
        -- (spots it steps from onto the target's land: a target on an island), up to HOPS each
        plan.hops[i] = 0
        local function ask(from, to, key, h)
          local r2 = {owner=rec.owner, unit=rec.unit, seq=rec.seq, seg=i, index=rec.index}
          r2[key] = h
          local ok = pcall(M.request, spider.surface, spider.force, from, to, r2)
          if ok then plan.hops[i] = plan.hops[i] + 1; plan.wait[i] = plan.wait[i] + 1; plan.pending = plan.pending + 1 end
        end
        for _, h in ipairs(M.hops(spider.surface, plan.starts[i], plan.goals[i])) do ask(h, plan.goals[i], 'hop', h) end
        for _, h in ipairs(M.hops(spider.surface, plan.goals[i], plan.starts[i])) do ask(plan.starts[i], h, 'ghop', h) end
      end
      if type(plan.segs[i]) ~= 'table' and plan.wait[i] <= 0 then plan.segs[i] = false end
    end
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
