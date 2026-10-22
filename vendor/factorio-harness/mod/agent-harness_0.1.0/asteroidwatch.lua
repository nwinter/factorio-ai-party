-- platform_defense {platform, asteroids: true, seconds}: a bounded watch (measures kind asteroid_watch) of the asteroids round one platform and its turrets' fire (d22
-- batch82 AR1, Astra #1855: Asterion's side guns shoot asteroids passing harmlessly, and the defense read gives
-- geometric reach only). Read only. As a player on the platform sees it:
-- - the view: the chunks holding the platform's foundation, VIEW_MARGIN tiles out (as collectreach.lua's view);
-- - each asteroid in it every SAMPLE ticks: position, and its velocity from its last two positions (2.0.77's asteroid
--   entity has no movement or speed to read: it drifts in a straight line against the platform, south while the
--   platform flies, about 0.03-0.04 tiles a tick on the copy over Nauvis-Gleba);
-- - its approach by the platform's heading (a platform faces north): where its straight line enters the box round the
--   hull's foundation: front (the north edge), side (west or east), rear (south), or clear (it never enters the box);
-- - a straight-line projection: whether that line, as wide as the asteroid, crosses a foundation tile before it leaves
--   the view, with the first one and when; an asteroid seen once takes the drift common to the others (said so). A
--   projection, not a prediction: turrets fire and the platform changes speed;
-- - what happened to it, from the game's events: destroyed (on_entity_died; by which turret), hit the platform
--   (on_entity_damaged on an entity of ours with the asteroid as cause: what it hit), left the view, or still in view;
-- - each turret of ours on the platform: its hits (damage events), damage and kills on asteroids by their approach and
--   projection, and its ammunition used (its ammo slot read every AMMO ticks, a slice of the turrets each read: the
--   drops summed; a drop and a refill in the same interval offset each other);
-- - trajectory samples of the first TRACK asteroids (up to POINTS points each, one a second).
return function(api)
  local M = {}
  M.SAMPLE, M.AMMO, M.VIEW_MARGIN = 15, 60, 32
  -- the projection's lookups (a cell's foundation count, a tile) at most WALK_STEPS an asteroid and WALK_BUDGET a sample;
  -- CELL-tile cells with no foundation (counted once a watch) are crossed without reading their tiles
  M.MAX_ASTEROIDS, M.TRACK, M.POINTS, M.WALK_STEPS, M.WALK_BUDGET, M.CELL = 3000, 24, 16, 1200, 600, 8
  M.MAX_TURRETS, M.TURRET_ROWS, M.HIT_ROWS = 400, 64, 16
  local FOUNDATION = 'space-platform-foundation'
  local TURRETS = {'ammo-turret', 'electric-turret', 'fluid-turret'}
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function r1(v) return math.floor(v * 10 + 0.5) / 10 end
  local function r3(v) return math.floor(v * 1000 + 0.5) / 1000 end
  local function at(x, y) return string.format('(%g,%g)', r1(x), r1(y)) end
  local function store() local s = api.state(); s.asteroid_watch = s.asteroid_watch or {}; return s.asteroid_watch end
  -- the operator profiler's parts (profile_ticks): asteroid_watch.find, .project, .ammo
  local function timed(label, fn, ...) if api.timed then return api.timed(label, fn, ...) end return fn(...) end

  -- The hull's box: the foundation chunks' box narrowed to the first and last row and column holding foundation.
  function M.hull(s)
    local x0, y0, x1, y1
    for ch in s.get_chunks() do
      local a = ch.area
      if s.count_tiles_filtered{area=a, name=FOUNDATION, limit=1} > 0 then
        x0, y0 = math.min(x0 or a.left_top.x, a.left_top.x), math.min(y0 or a.left_top.y, a.left_top.y)
        x1, y1 = math.max(x1 or a.right_bottom.x, a.right_bottom.x), math.max(y1 or a.right_bottom.y, a.right_bottom.y)
      end
    end
    if not x0 then return nil end
    local function any(ax, ay, bx, by) return s.count_tiles_filtered{area={{ax, ay}, {bx, by}}, name=FOUNDATION, limit=1} > 0 end
    -- the smallest b in lo..hi with has(b) (has(hi) holds; has grows with b): a binary search over strips from an edge
    local function lowest(lo, hi, has)
      while lo < hi do
        local mid = math.floor((lo + hi) / 2)
        if has(mid) then hi = mid else lo = mid + 1 end
      end
      return lo
    end
    local top = lowest(y0 + 1, y1, function(b) return any(x0, y0, x1, b) end) - 1
    local bottom = y1 - lowest(1, y1 - y0, function(k) return any(x0, y1 - k, x1, y1) end)
    local left = lowest(x0 + 1, x1, function(b) return any(x0, y0, b, y1) end) - 1
    local right = x1 - lowest(1, x1 - x0, function(k) return any(x1 - k, y0, x1, y1) end)
    return {x0=left, y0=top, x1=right + 1, y1=bottom + 1}
  end

  -- Where a ray from p along v enters and leaves box b (t in ticks), and through which edge: nil when it never does.
  function M.enter(b, p, v)
    local t0, t1, edge = 0, math.huge, 'inside'
    for _, ax in ipairs({{p.x, v.x, b.x0, b.x1, 'west', 'east'}, {p.y, v.y, b.y0, b.y1, 'north', 'south'}}) do
      local q, d, lo, hi = ax[1], ax[2], ax[3], ax[4]
      if math.abs(d) < 1e-9 then
        if q < lo or q > hi then return nil end
      else
        local ta, tb = (lo - q) / d, (hi - q) / d
        local ea = d > 0 and ax[5] or ax[6]
        if ta > tb then ta, tb = tb, ta end
        if ta > t0 then t0, edge = ta, ea end
        if tb < t1 then t1 = tb end
        if t0 > t1 then return nil end
      end
    end
    return t0, t1, edge
  end
  local APPROACH = {north='front', west='side', east='side', south='rear', inside='side'}
  -- The straight-line projection: {approach, crosses, at, eta_s, steps, assumed}. cells: the watch's cache of CELL-tile
  -- cells holding foundation (true/false).
  function M.project(s, hull, view, p, v, radius, assumed, cells)
    local out = {assumed=assumed or nil}
    -- the box widened by the asteroid's radius: its edge, not its centre, meets the hull
    local t0, t1, edge = M.enter({x0=hull.x0 - radius, y0=hull.y0 - radius, x1=hull.x1 + radius, y1=hull.y1 + radius}, p, v)
    if not t0 then out.approach = 'clear'; out.crosses = false; return out end
    out.approach, out.edge = APPROACH[edge], edge
    local speed = math.sqrt(v.x * v.x + v.y * v.y)
    if speed < 1e-6 then out.crosses = false; return out end
    local step = 0.5 / speed  -- ticks per half tile
    local nx, ny = -v.y / speed, v.x / speed
    local offs = radius > 0.3 and {0, radius * 0.9, -radius * 0.9} or {0}
    local steps, t = 0, t0
    local C = M.CELL
    cells = cells or {}
    while t <= t1 and steps < M.WALK_STEPS do
      local cx, cy = p.x + v.x * t, p.y + v.y * t
      for _, o in ipairs(offs) do
        local x, y = cx + nx * o, cy + ny * o
        local tx, ty = math.floor(x), math.floor(y)
        local ck = math.floor(tx / C) * 4096 + math.floor(ty / C)
        local has = cells[ck]
        if has == nil then
          steps = steps + 1
          local bx, by = math.floor(tx / C) * C, math.floor(ty / C) * C
          has = s.count_tiles_filtered{area={{bx, by}, {bx + C, by + C}}, name=FOUNDATION, limit=1} > 0
          cells[ck] = has
        end
        local tl
        if has then steps = steps + 1; tl = s.get_tile(tx, ty) end
        if tl and tl.name == FOUNDATION then
          out.crosses, out.at, out.eta_s, out.steps = true, {x=math.floor(x) + 0.5, y=math.floor(y) + 0.5}, r1(t / 60), steps
          return out
        end
      end
      t = t + step
    end
    out.crosses, out.steps = false, steps
    if steps >= M.WALK_STEPS then out.unfinished = true end
    return out
  end
  local function key(r)
    local pj = r.prj
    if not pj then return 'unknown' end
    if pj.approach == 'clear' then return 'clear' end
    return pj.approach .. (pj.crosses and '/crosses' or '/misses')
  end
  M.key = key
  local function region(hull, pos)
    local h = hull.y1 - hull.y0
    local band = pos.y < hull.y0 + h / 3 and 'front' or pos.y > hull.y1 - h / 3 and 'rear' or 'middle'
    return band .. ' ' .. (pos.x < (hull.x0 + hull.x1) / 2 and 'west' or 'east')
  end
  local function radius_of(name)
    local b = try(function() return prototypes.entity[name].collision_box end)
    return b and math.max(math.abs(b.right_bottom.x), math.abs(b.left_top.x)) or 0.5
  end
  local function ammo_count(e)
    local inv = try(function() return e.get_inventory(defines.inventory.turret_ammo) end)
    return inv and try(function() return inv.get_item_count() end) or nil
  end

  local function rec_of(job, e, tick)
    local u = e.unit_number
    local r = job.asts[u]
    if r or not u then return r end
    if job.nast >= M.MAX_ASTEROIDS then job.untracked = job.untracked + 1; return nil end
    local pos = e.position
    r = {n=e.name, s0=tick, p0={x=pos.x, y=pos.y}, p={x=pos.x, y=pos.y}, t=tick}
    job.asts[u], job.nast = r, job.nast + 1
    if job.ntrack < M.TRACK then job.ntrack = job.ntrack + 1; r.traj = {{tick, r1(pos.x), r1(pos.y)}} end
    return r
  end
  local function drift(job)
    local d = job.drift
    if not d or d.n == 0 then return nil end
    return {x=d.x / d.n, y=d.y / d.n}
  end
  local function project_rec(job, s, r)
    local v, assumed = r.v, nil
    if not v then v = drift(job); assumed = true end
    if not v then return false end
    -- from where it was first seen: its whole path if left alone
    r.prj = M.project(s, job.hull, job.view, r.p0, v, radius_of(r.n), assumed, job.cells)
    job.walked = (job.walked or 0) + (r.prj.steps or 0)
    return true
  end

  function M.sample(job, tick)
    local s = game.get_surface(job.surface)
    if not s then job.gone = tick; return end
    job.samples, job.sampled = job.samples + 1, tick
    local list = timed('asteroid_watch.find', function() return try(function() return s.find_entities_filtered{area=job.view, type='asteroid'} end) or {} end)
    job.in_view = #list
    local d = {x=0, y=0, n=0}
    for _, e in ipairs(list) do
      local r = rec_of(job, e, tick)
      if r then
        local pos = e.position
        local dt = tick - r.t
        if dt > 0 then
          r.v = {x=(pos.x - r.p.x) / dt, y=(pos.y - r.p.y) / dt}
          d.x, d.y, d.n = d.x + r.v.x, d.y + r.v.y, d.n + 1
          if r.prj and r.prj.assumed then r.prj = nil end
        end
        r.p.x, r.p.y, r.t = pos.x, pos.y, tick
        if r.traj and #r.traj < M.POINTS and tick - r.traj[#r.traj][1] >= 60 then r.traj[#r.traj+1] = {tick, r1(pos.x), r1(pos.y)} end
        if not r.prj and r.v and not r.queued then r.queued = true; job.queue[#job.queue+1] = e.unit_number end
      end
    end
    if d.n > 0 then job.drift = d end
    -- projections, up to WALK_BUDGET lookups a sample (the rest wait for the next)
    job.walked = 0
    if job.queue[1] then
      timed('asteroid_watch.project', function()
        while job.queue[1] and job.walked < M.WALK_BUDGET do
          local u = table.remove(job.queue, 1)
          local r = job.asts[u]
          if r then r.queued = nil; if not r.prj then project_rec(job, s, r) end end
        end
      end)
    end
    -- ammunition: each turret once every AMMO ticks, a slice of them each read (AMMO / SAMPLE slices)
    timed('asteroid_watch.ammo', M.ammo, job, tick)
  end
  function M.ammo(job, tick)
    local slices = math.max(1, math.floor(M.AMMO / M.SAMPLE))
    local k = job.samples % slices
    for i = k + 1, #job.tlist, slices do
      local t = job.turrets[job.tlist[i]]
      do
        if t and not t.gone then
          local e = t.e
          if e and e.valid then
            local n = ammo_count(e)
            if n and t.ammo then
              if n < t.ammo then t.used = t.used + (t.ammo - n) elseif n > t.ammo then t.loaded = t.loaded + (n - t.ammo) end
            end
            t.ammo = n or t.ammo
          else t.gone, t.e = tick, nil end
        end
      end
    end
  end

  -- Events (runtime.on_event): an asteroid damaged or destroyed on a watched surface, and hits on our entities there.
  function M.on_damaged(event)
    local all = api.state().asteroid_watch
    if not all then return end
    local e = event.entity
    if not (e and e.valid) then return end
    local si = e.surface.index
    for _, job in pairs(all) do
      if not job.result and job.surface == si then
        local cause = event.cause
        if e.type == 'asteroid' then
          local t = cause and cause.valid and job.turrets[cause.unit_number]
          if t then
            -- by asteroid: its class is read from its projection when the result is made
            local u = e.unit_number
            local r = rec_of(job, e, event.tick)
            if r and not r.prj and not r.queued then r.queued = true; job.queue[#job.queue+1] = u end
            local h = t.ah[u]
            if not h then h = {0, 0, 0}; t.ah[u] = h end
            h[1], h[2] = h[1] + 1, h[2] + (event.final_damage_amount or 0)
          end
        elseif cause and cause.valid and cause.type == 'asteroid' and e.force and e.force.name == job.force then
          local r = rec_of(job, cause, event.tick)
          if r then
            if not r.prj and not r.queued then r.queued = true; job.queue[#job.queue+1] = cause.unit_number end
            r.out, r.out_t = 'hit', event.tick
            r.hit = r.hit or {name=e.name, x=e.position.x, y=e.position.y, damage=0}
            r.hit.damage = r.hit.damage + (event.final_damage_amount or 0)
            if not r.hit_counted then r.hit_counted = true; job.hits[#job.hits+1] = cause.unit_number end
          end
        end
      end
    end
  end
  function M.on_died(event)
    local all = api.state().asteroid_watch
    if not all then return end
    local e = event.entity
    if not (e and e.valid and e.type == 'asteroid') then return end
    local si = e.surface.index
    for _, job in pairs(all) do
      if not job.result and job.surface == si then
        local r = rec_of(job, e, event.tick)
        if r then
          if not r.prj and not r.queued then r.queued = true; job.queue[#job.queue+1] = e.unit_number end
          r.p.x, r.p.y = e.position.x, e.position.y
          local cause = event.cause
          local t = cause and cause.valid and job.turrets[cause.unit_number]
          if r.out ~= 'hit' then r.out, r.out_t = 'destroyed', event.tick end
          r.died = true
          if t then
            local u = e.unit_number
            local h = t.ah[u]
            if not h then h = {0, 0, 0}; t.ah[u] = h end
            h[3] = h[3] + 1
            r.by = t.name .. ' ' .. at(t.position.x, t.position.y)
          elseif cause and cause.valid then r.by = cause.name .. ' ' .. at(cause.position.x, cause.position.y)
          else r.by = 'no cause given' end
          r.by_name = t and t.name or cause and cause.valid and cause.name or 'no cause given'
        end
      end
    end
  end

  local function sum(t) local n = 0; for _, v in pairs(t) do n = n + v end; return n end
  local CLASSES = {'front/crosses', 'front/misses', 'side/crosses', 'side/misses', 'rear/crosses', 'rear/misses', 'clear', 'unknown'}
  local function class_text(k)
    if k == 'clear' then return 'clear (its line never enters the hull\'s box)' end
    if k == 'unknown' then return 'unknown (no movement read)' end
    local a, c = k:match('^(%a+)/(%a+)$')
    return string.format('%s, %s foundation', a, c == 'crosses' and 'crosses' or 'misses')
  end
  function M.result(job, done)
    local now = done and job.until_tick or game.tick
    local secs = math.max(0, now - job.start) / 60
    local function sec(t) return r1((t - job.start) / 60) end
    -- asteroids by approach and projection, and what became of them
    local by = {}
    for _, k in ipairs(CLASSES) do by[k] = {seen=0, destroyed=0, hit=0, left_view=0, in_view=0} end
    local hits, tracks = {}, {}
    for u, r in pairs(job.asts) do
      local k = key(r)
      local b = by[k]
      b.seen = b.seen + 1
      local out = r.out
      if not out then out = (r.t >= (job.sampled or 0)) and 'in_view' or 'left_view' end
      if out == 'destroyed' then
        b.destroyed = b.destroyed + 1
        b.destroyed_by = b.destroyed_by or {}
        local who = r.by_name or 'no cause given'
        b.destroyed_by[who] = (b.destroyed_by[who] or 0) + 1
      elseif out == 'hit' then b.hit = b.hit + 1
      elseif out == 'left_view' then b.left_view = b.left_view + 1 else b.in_view = b.in_view + 1 end
      if r.traj then
        local pj = r.prj
        tracks[#tracks+1] = {name=r.n, first_s=sec(r.s0), approach=pj and pj.approach or 'unknown', projected=pj and (pj.crosses and string.format('crosses foundation at %s in %gs', at(pj.at.x, pj.at.y), pj.eta_s) or 'crosses no foundation') or 'not projected',
          assumed_drift=pj and pj.assumed or nil, outcome=out, by=r.by, hit=r.hit and r.hit.name or nil, velocity=r.v and {x=r3(r.v.x * 60), y=r3(r.v.y * 60)} or nil,
          points=r.traj}
      end
    end
    table.sort(tracks, function(a, b) return a.first_s < b.first_s end)
    for _, u in ipairs(job.hits) do
      local r = job.asts[u]
      if r and #hits < M.HIT_ROWS then
        local pj = r.prj
        hits[#hits+1] = string.format('%s hit %s %s at +%gs for %g (approach %s; projected: %s)', r.n, r.hit.name, at(r.hit.x, r.hit.y), sec(r.out_t), r1(r.hit.damage),
          pj and pj.approach or 'unknown', pj and (pj.crosses and string.format('crosses foundation at %s', at(pj.at.x, pj.at.y)) or 'crosses no foundation') or 'none')
      end
    end
    local classes, class_lines = {}, {}
    for _, k in ipairs(CLASSES) do
      local b = by[k]
      if b.seen > 0 then
        b.class = k
        classes[#classes+1] = b
        local who = {}
        for n, c in pairs(b.destroyed_by or {}) do who[#who+1] = n .. ' ' .. c end
        table.sort(who)
        class_lines[#class_lines+1] = string.format('%s: %d seen, %d destroyed%s, %d hit the platform, %d left the view, %d still in view', class_text(k), b.seen, b.destroyed,
          #who > 0 and ' (by ' .. table.concat(who, ', ') .. ')' or '', b.hit, b.left_view, b.in_view)
      end
    end
    -- turrets: their hits, damage and kills by the asteroid's class, ammunition used
    local rows, groups, gorder = {}, {}, {}
    local fired, idle = 0, 0
    for _, t in pairs(job.turrets) do
      t.hits, t.dmg, t.kills = {}, {}, {}
      for u, h in pairs(t.ah) do
        local r = job.asts[u]
        local k = r and key(r) or 'untracked'
        t.hits[k] = (t.hits[k] or 0) + h[1]
        t.dmg[k] = (t.dmg[k] or 0) + h[2]
        if h[3] > 0 then t.kills[k] = (t.kills[k] or 0) + h[3] end
      end
      local nh = sum(t.hits)
      if nh > 0 or t.used > 0 then fired = fired + 1 else idle = idle + 1 end
      local gk = t.name .. '|' .. t.region
      local g = groups[gk]
      if not g then g = {name=t.name, region=t.region, turrets=0, hits={}, kills={}, damage=0, ammo_used=0}; groups[gk] = g; gorder[#gorder+1] = gk end
      g.turrets = g.turrets + 1
      for k, n in pairs(t.hits) do g.hits[k] = (g.hits[k] or 0) + n end
      for k, n in pairs(t.kills) do g.kills[k] = (g.kills[k] or 0) + n end
      g.damage, g.ammo_used = g.damage + sum(t.dmg), g.ammo_used + t.used
      if nh > 0 or t.used > 0 then
        rows[#rows+1] = {name=t.name, position=t.position, region=t.region, hits=t.hits, kills=t.kills, damage=r1(sum(t.dmg)), ammo_used=t.used, ammo_loaded=t.loaded, gone_s=t.gone and sec(t.gone) or nil, n=nh}
      end
    end
    table.sort(rows, function(a, b) return a.n > b.n end)
    local turret_rows_more = #rows > M.TURRET_ROWS and #rows - M.TURRET_ROWS or nil
    while #rows > M.TURRET_ROWS do table.remove(rows) end
    for _, r in ipairs(rows) do r.n = nil end
    local function split(t)
      local total, clear, miss = 0, 0, 0
      for k, n in pairs(t) do
        total = total + n
        if k == 'clear' then clear = clear + n elseif k:find('/misses', 1, true) then miss = miss + n end
      end
      return total, clear, miss
    end
    local glines, grows = {}, {}
    table.sort(gorder)
    for _, gk in ipairs(gorder) do
      local g = groups[gk]
      local h, hc, hm = split(g.hits)
      local k, kc, km = split(g.kills)
      g.damage = r1(g.damage)
      grows[#grows+1] = g
      glines[#glines+1] = string.format('%s x%d (%s of the hull): %d hits, %d kills, %g damage, %d ammo used; on asteroids clear of the hull\'s box %d hits and %d kills, on ones whose line enters it but crosses no foundation %d hits and %d kills',
        g.name, g.turrets, g.region, h, k, g.damage, g.ammo_used, hc, kc, hm, km)
    end
    local line = string.format('%s %s for %gs%s: %d asteroids seen in view (%d in view now), %d destroyed, %d hit the platform; turrets %d fired, %d did not',
      done and 'watched' or 'watching', job.platform, r1(secs), done and '' or string.format(' of %ds', job.seconds), job.nast, job.in_view or 0,
      (function() local n = 0; for _, b in pairs(by) do n = n + b.destroyed end; return n end)(), #job.hits, fired, idle)
    return {watching=not done or nil, done=done or nil, platform=job.platform, seconds=job.seconds, seconds_watched=r1(secs), start_tick=job.start, end_tick=done and job.until_tick or nil,
      samples=job.samples, every_ticks=M.SAMPLE, view=job.view, hull={left_top={x=job.hull.x0, y=job.hull.y0}, right_bottom={x=job.hull.x1, y=job.hull.y1}},
      drift_tiles_per_s=drift(job) and {x=r3(drift(job).x * 60), y=r3(drift(job).y * 60)} or nil,
      asteroids=job.nast, untracked=job.untracked > 0 and job.untracked or nil, classes=classes, class_lines=class_lines,
      platform_hits=#job.hits, platform_hit_lines=#hits > 0 and hits or nil,
      turret_groups=grows, turret_group_lines=glines, turrets=rows, turret_rows_more=turret_rows_more, trajectories=tracks, line=line, note=M.NOTE}
  end
  M.NOTE = 'heading: a platform faces north; approach is where the asteroid\'s straight line enters the box round the hull\'s foundation (front the north edge, side west or east, rear south; clear: it never enters it); '
    .. 'crosses/misses: a straight-line projection from its last two sampled positions (one seen once takes the drift common to the others: assumed_drift), as wide as the asteroid, until it leaves the view: '
    .. 'whether it would cross a foundation tile if no turret fired and the platform kept its speed; a projection, not what happened; outcome is what happened (the game\'s events: destroyed and by what, hit an entity of ours, left the view, still in view); '
    .. 'turret hits are its damage events on asteroids, kills the asteroids it destroyed; ammo used is its ammo slot\'s drops read once a second (a refill in the same second offsets a drop)'

  function M.tick(tick)
    local all = api.state().asteroid_watch
    if not all then return end
    for _, job in pairs(all) do
      if not job.result and tick >= job.next_tick then
        M.sample(job, tick)
        if tick >= job.until_tick or job.gone then
          job.result = M.result(job, true)
          job.asts, job.turrets, job.queue, job.tlist, job.cells = nil, nil, nil, nil, nil
        else
          job.next_tick = math.min(tick + M.SAMPLE, job.until_tick)
        end
      end
    end
  end

  function M.handler(p, a)
    assert(type(a.asteroids) == 'boolean', 'asteroids must be true or false')
    assert(a.platform ~= nil, 'platform_defense {platform, asteroids: true, seconds} starts the watch; without seconds it reads it')
    if a.seconds == nil then
      local job = store()[p.index]
      assert(job, 'no asteroid watch of yours yet: platform_defense {platform, asteroids: true, seconds: 10..1800} starts one')
      if job.result then job.read_tick = game.tick end
      return job.result or M.result(job, false)
    end
    local seconds = a.seconds
    assert(type(seconds) == 'number' and seconds >= 10 and seconds <= 1800 and seconds == math.floor(seconds), 'seconds: 10..1800')
    local reason = api.reason and api.reason(a.reason)
    local q = api.on_platform(p, a.platform)
    local s = q.surface
    local pl = s.platform
    local hull = M.hull(s)
    assert(hull, 'no foundation on that platform')
    local view = {left_top={x=math.floor(hull.x0 / 32) * 32 - M.VIEW_MARGIN, y=math.floor(hull.y0 / 32) * 32 - M.VIEW_MARGIN},
      right_bottom={x=math.ceil(hull.x1 / 32) * 32 + M.VIEW_MARGIN, y=math.ceil(hull.y1 / 32) * 32 + M.VIEW_MARGIN}}
    local turrets, tlist, n = {}, {}, 0
    for _, e in ipairs(s.find_entities_filtered{type=TURRETS, force=q.force, limit=M.MAX_TURRETS}) do
      n = n + 1
      tlist[n] = e.unit_number
      turrets[e.unit_number] = {e=e, name=e.name, position={x=e.position.x, y=e.position.y}, region=region(hull, e.position), ammo=ammo_count(e), used=0, loaded=0, ah={}}
    end
    local replaced = store()[p.index] and not store()[p.index].result
    local job = {start=game.tick, until_tick=game.tick + seconds * 60, next_tick=game.tick, seconds=seconds, samples=0, platform=pl.name, surface=s.index,
      force=q.force.name, hull=hull, view=view, asts={}, nast=0, ntrack=0, untracked=0, queue={}, hits={}, turrets=turrets, tlist=tlist, cells={}, reason=reason}
    store()[p.index] = job
    return {watching=true, seconds=seconds, start_tick=job.start, platform=pl.name, turrets=n,
      hull={left_top={x=hull.x0, y=hull.y0}, right_bottom={x=hull.x1, y=hull.y1}}, view=view,
      replaced=replaced and 'your earlier watch, still running, was replaced' or nil,
      line=string.format('watching the asteroids in view of %s (foundation box (%d,%d)-(%d,%d), view %d tiles out from its chunks) and its %d turrets for %ds, a read every %d ticks: platform_defense {platform, asteroids: true} reads it so far, and in full once done',
        pl.name, hull.x0, hull.y0, hull.x1, hull.y1, M.VIEW_MARGIN, n, seconds, M.SAMPLE),
      note=M.NOTE}
  end
  M.ARGS = {asteroids='optional true: an asteroid watch on that platform instead (d22 batch82 AR1): with seconds it starts one, without it reads yours: the asteroids in view of the platform (its foundation\'s chunks, 32 tiles out) and its turrets, a read every 15 ticks; one watch an agent, a new one replaces it',
    seconds='with asteroids: 10..1800, how long to watch', reason='optional text, up to 200 characters: your own reason to wait for it, shown with the watch in your sleep line, sleep_check and the operator\'s idle check',
    asteroids_returns='the start: hull (the box round its foundation), view, turrets, line; without seconds it reads it so far (watching) or done: asteroids (seen in view), classes [{class (front|side|rear by where its straight line enters the hull\'s box, the platform facing north; /crosses or /misses: whether that line crosses foundation; clear: it never enters the box; unknown), seen, destroyed, hit, left_view, in_view}] and class_lines; '
      .. 'platform_hits and platform_hit_lines (what each asteroid that hit us hit, where, its damage, its approach and projection); turret_groups [{name, region (front|middle|rear third of the hull, west|east half), turrets, hits, kills (by class), damage, ammo_used}] and turret_group_lines (hits and kills on clear asteroids and on ones crossing no foundation); '
      .. 'turrets (those that fired: name, position, region, hits, kills by class, damage, ammo_used, ammo_loaded; up to 64, turret_rows_more past that); trajectories (the first 24 asteroids: name, first_s, approach, projected, assumed_drift, outcome (destroyed, hit, left_view, in_view), by, hit, velocity (tiles a second), points [[tick, x, y]], one a second); drift_tiles_per_s; line; note. Read only'}
  return M
end
