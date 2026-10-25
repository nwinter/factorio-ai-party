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
--   projection, and (d24 batch181 QX1) its rounds: every ammo turret's ammo slot read every SAMPLE to AMMO_MAX ticks, its rounds
--   (count - 1) * magazine_size + the top stack's ammo left; a read's change split into rounds fired and items loaded,
--   exact while the most rounds the turret can fire between two reads (its cooldown with the force's shooting speed
--   bonus) is under the magazine size (a gun turret: 7 under 10), else a load and a shot can offset each other (a
--   rocket or railgun turret: magazines of 1): the turret's hits in that interval show a shot, and a read with
--   neither told apart is counted unsure;
-- - the platform's ammunition consumed: the item production statistics' consumed count of each ammo item at every
--   quality at the start and now (turret shots count as consumed there);
-- - by name (QX1): the asteroids in view at the first read apart from those first seen later, and of those, the
--   fragments (first seen within MATCH_R tiles, plus their drift, of where an asteroid whose dying effect creates that
--   name died in the MATCH_TICKS before: by name, place and time; the game raises no event for them,
--   trigger_created_entity is false) apart from the rest (come into the view, or a fragment of a death not matched);
-- - trajectory samples of the first TRACK asteroids (up to POINTS points each, one a second).
return function(api)
  local M = {}
  -- (d25 batch208 QU1) the most a call takes, also a queue step's check (runtime.lua step_lengths)
  M.NAME_LEN = 100
  M.SAMPLE, M.AMMO, M.AMMO_MAX, M.VIEW_MARGIN = 15, 15, 60, 32
  M.MATCH_TICKS, M.MATCH_R, M.MATCH_DRIFT = 30, 3, 0.1
  -- the projection's lookups (a cell's foundation count, a tile) at most WALK_STEPS an asteroid and WALK_BUDGET a sample;
  -- CELL-tile cells with no foundation (counted once a watch) are crossed without reading their tiles
  M.MAX_ASTEROIDS, M.TRACK, M.POINTS, M.WALK_STEPS, M.WALK_BUDGET, M.CELL = 3000, 24, 16, 1200, 600, 8
  M.MAX_TURRETS, M.TURRET_ROWS, M.HIT_ROWS = 400, 64, 16
  M.PAGE, M.PAGE_MAX, M.NAMES_MAX, M.HIT_BY = 24, 100, 16, 3
  -- (d25 batch200 QM1) the watches an edit closed (mixed.lua), kept on the watch that followed: at most SEGMENTS, and
  -- their tracked asteroids together at most SEGMENT_RECORDS (the newest always kept). A done 120 s watch of 1501 tracked
  -- asteroids on a copy of world n held 12026 tables (726 KB as JSON), so the segments hold at most about one full watch.
  M.SEGMENTS, M.SEGMENT_RECORDS = 3, 3000
  -- (d25 batch200 QM2) a watch's seconds: the handler's check and a queue step's (runtime.lua step_ranges)
  M.SECONDS = {10, 1800}
  local FOUNDATION = 'space-platform-foundation'
  local TURRETS = {'ammo-turret', 'electric-turret', 'fluid-turret'}
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function r1(v) return math.floor(v * 10 + 0.5) / 10 end
  local function r3(v) return math.floor(v * 1000 + 0.5) / 1000 end
  -- (d25 batch206 QS) string.format('%g', v) for v a multiple of 0.1 (positions rounded to a tenth), by %d: %g costs
  -- about 2 us a number in the game, %d 0.3
  local function g1(v)
    local n = math.floor(v * 10 + 0.5)
    if n > -1000000 and n < 1000000 then
      if n % 10 == 0 then return string.format('%d', n / 10) end
      local a = n < 0 and -n or n
      return string.format(n < 0 and '-%d.%d' or '%d.%d', math.floor(a / 10), a % 10)
    end
    return string.format('%g', v)
  end
  local function at(x, y) return '(' .. g1(r1(x)) .. ',' .. g1(r1(y)) .. ')' end
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
  local KEYS = {}  -- (d25 batch206 QS) the class texts by approach, made once (a read made one a record and hit)
  local function key(r)
    local pj = r.prj
    if not pj then return 'unknown' end
    local a = pj.approach
    if a == 'clear' then return 'clear' end
    local t = KEYS[a]
    if not t then t = {a .. '/crosses', a .. '/misses'}; KEYS[a] = t end
    return pj.crosses and t[1] or t[2]
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
  -- (QM1) a turret's reach: its prototype's attack range times its quality's range_multiplier (on a copy of world n an
  -- uncommon gun turret hit asteroids 19.5 and 20.5 tiles off, a normal one none past 19), its prototype's minimum
  -- range, and its turn range (a share of a full turn round its facing) when under a full turn; kept by name and quality
  local RANGE = {}
  -- (d25 batch209 QV1) a turret prototype's attack range by name (the rows' base_range)
  local BASE = {}
  local function base_of(name)
    local b = BASE[name]
    if b == nil then b = try(function() return prototypes.entity[name].attack_parameters.range end) or false; BASE[name] = b end
    return b or nil
  end
  local DIR = {}
  for n, v in pairs(defines and defines.direction or {}) do DIR[v] = n end
  local function range_of(e)
    local q = try(function() return e.quality end)
    local k = e.name .. '@' .. (q and q.name or 'normal')
    local r = RANGE[k]
    if r == nil then
      local ap = try(function() return e.prototype.attack_parameters end) or {}
      local m = q and try(function() return q.range_multiplier end) or 1
      r = {range=ap.range and r1(ap.range * m), min=ap.min_range and ap.min_range > 0 and ap.min_range or nil,
        turn=ap.turn_range and ap.turn_range < 1 and r3(ap.turn_range) or nil, quality=q and q.name or 'normal'}
      RANGE[k] = r
    end
    return r
  end
  local function ammo_count(e)
    local inv = try(function() return e.get_inventory(defines.inventory.turret_ammo) end)
    return inv and try(function() return inv.get_item_count() end) or nil
  end
  -- an ammo item's magazine size, kept
  local MAG = {}
  local function mag_of(name)
    local m = MAG[name]
    if m == nil then m = try(function() return prototypes.item[name].magazine_size end) or 1; MAG[name] = m end
    return m
  end
  -- a turret's rounds by ammo item ("name@quality" -> rounds): each stack (count - 1) * magazine + its ammo left
  local function rounds_of(e, out, inv)
    inv = inv or try(function() return e.get_inventory(defines.inventory.turret_ammo) end)
    if not inv then return nil end
    for k = 1, #inv do
      local st = inv[k]
      if st.valid_for_read then
        local n = st.name
        local key = n .. '@' .. (st.quality and st.quality.name or 'normal')
        out[key] = (out[key] or 0) + (st.count - 1) * mag_of(n) + (st.ammo or 0)
      end
    end
    return out
  end
  -- the most rounds a turret fires between two reads ticks apart: shots (its cooldown with the ammo's modifier and the
  -- force's shooting speed bonus, as ammorate.lua) times rounds a shot
  local function max_rounds(job, tname, item, ticks)
    job.rate = job.rate or {}
    local k = tname .. '|' .. item
    local r = job.rate[k]
    if not r then
      local ap = try(function() return prototypes.entity[tname].attack_parameters end) or {}
      local ip = prototypes.item[item]
      local at = ip and (try(function() return ip.get_ammo_type('turret') end) or try(function() return ip.get_ammo_type() end)) or {}
      local cat = ip and try(function() return ip.ammo_category.name end)
      local f = try(function() return game.forces[job.force] end)
      local speed = cat and f and try(function() return f.get_gun_speed_modifier(cat) end) or 0
      -- instant: its hit lands on the tick it fires (bullets, railgun); a projectile's (rockets) lands later
      local a1 = type(at.action) == 'table' and (at.action[1] or at.action)
      local d1 = a1 and type(a1.action_delivery) == 'table' and (a1.action_delivery[1] or a1.action_delivery)
      r = {cd=(ap.cooldown or 60) * (type(at.cooldown_modifier) == 'number' and at.cooldown_modifier or 1) / (1 + speed),
        per=(ap.ammo_consumption_modifier or 1) * (type(at.consumption_modifier) == 'number' and at.consumption_modifier or 1),
        instant=d1 and d1.type == 'instant' or false}
      job.rate[k] = r
    end
    return math.ceil(ticks / r.cd) * r.per, r.instant
  end
  -- (QX1) what an asteroid's death creates: its dying effect's create-entity names, how many of each (offsets), kept
  local KIDS = {}
  local function kids_of(name)
    local k = KIDS[name]
    if k == nil then
      k = false
      for _, t in ipairs(try(function() return prototypes.entity[name].dying_trigger_effect end) or {}) do
        if t.type == 'create-entity' and t.entity_name then
          k = k or {}
          k[t.entity_name] = (k[t.entity_name] or 0) + math.max(1, #(t.offsets or {}))
        end
      end
      KIDS[name] = k
    end
    return k
  end
  M.kids_of = kids_of
  local function dcell(x, y) return math.floor(x / 8) * 65536 + math.floor(y / 8) end
  -- a death that makes fragments, kept MATCH_TICKS (plus a sample) by place
  local function add_death(job, name, pos, tick)
    local kids = kids_of(name)
    if not kids then return end
    job.dg, job.dl = job.dg or {}, job.dl or {}
    local d = {t=tick, x=pos.x, y=pos.y, left={}}
    for n, c in pairs(kids) do d.left[n] = c end
    local c = dcell(pos.x, pos.y)
    local l = job.dg[c]
    if not l then l = {}; job.dg[c] = l end
    l[#l+1] = d
    job.dl[#job.dl+1] = {c, d}
  end
  local function prune_deaths(job, tick)
    local dl = job.dl
    if not dl or #dl == 0 then return end
    local keep, i = tick - M.MATCH_TICKS - M.SAMPLE, 1
    while dl[i] and dl[i][2].t < keep do i = i + 1 end
    if i == 1 then return end
    for k = 1, i - 1 do
      local c, d = dl[k][1], dl[k][2]
      local l = job.dg[c]
      if l then
        for j = #l, 1, -1 do if l[j] == d then table.remove(l, j) end end
        if #l == 0 then job.dg[c] = nil end
      end
    end
    local rest = {}
    for k = i, #dl do rest[#rest+1] = dl[k] end
    job.dl = rest
  end
  -- an asteroid's cohort when first seen: first (in view at the first read), fragment (a death matched), later
  local function cohort(job, name, pos, tick)
    if not job.first_sample or tick <= job.first_sample then return 'first' end
    local dg = job.dg
    if dg then
      local cx, cy = math.floor(pos.x / 8), math.floor(pos.y / 8)
      for ox = -1, 1 do
        for oy = -1, 1 do
          for _, d in ipairs(dg[(cx + ox) * 65536 + (cy + oy)] or {}) do
            local dt = tick - d.t
            local left = d.left[name]
            if left and left > 0 and dt >= 0 and dt <= M.MATCH_TICKS + M.SAMPLE then
              local r = M.MATCH_R + M.MATCH_DRIFT * dt
              local dx, dy = pos.x - d.x, pos.y - d.y
              if dx * dx + dy * dy <= r * r then d.left[name] = left - 1; return 'fragment' end
            end
          end
        end
      end
    end
    return 'later'
  end
  local function count_cohort(job, name, c)
    job.coh = job.coh or {}
    local t = job.coh[name]
    if not t then t = {first=0, fragment=0, later=0}; job.coh[name] = t end
    t[c] = t[c] + 1
  end

  -- (d20 batch133 PE1, Sol #2094: no totals by asteroid name; untracked counted every sighting) past MAX_ASTEROIDS an
  -- asteroid is untracked: job.untr[unit] its state (1 seen, 2 hit the platform, 3 destroyed), job.useen[name] counted
  -- once an asteroid, and job.uview[name] those in view at the last sample; returns nil, its state then.
  local function untracked_of(job, e, tick)
    if not job.untr then job.untr, job.useen, job.uhit, job.udied, job.uview = {}, {}, {}, {}, {} end  -- a watch begun before
    local u = e.unit_number
    local st = job.untr[u]
    if not st then
      st = 1
      job.untr[u], job.untracked = 1, job.untracked + 1
      local n = e.name
      job.useen[n] = (job.useen[n] or 0) + 1
      count_cohort(job, n, cohort(job, n, e.position, tick))
    end
    return st
  end
  local function rec_of(job, e, tick)
    local u = e.unit_number
    local r = job.asts[u]
    if r or not u then return r end
    if job.nast >= M.MAX_ASTEROIDS then return nil, untracked_of(job, e, tick) end
    local pos = e.position
    r = {n=e.name, s0=tick, p0={x=pos.x, y=pos.y}, p={x=pos.x, y=pos.y}, t=tick}
    r.c = cohort(job, r.n, pos, tick)
    count_cohort(job, r.n, r.c)
    job.asts[u], job.nast = r, job.nast + 1
    -- (QX1) the tick the tracked set reached its cap: asteroids first seen after it are counted, not followed
    if job.nast == M.MAX_ASTEROIDS then job.cap_tick = tick end
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
    job.first_sample = job.first_sample or tick
    prune_deaths(job, tick)
    local list = timed('asteroid_watch.find', function() return try(function() return s.find_entities_filtered{area=job.view, type='asteroid'} end) or {} end)
    job.in_view = #list
    local d = {x=0, y=0, n=0}
    local uview = {}
    job.uview = uview
    for _, e in ipairs(list) do
      local r, ust = rec_of(job, e, tick)
      if ust then local n = e.name; uview[n] = (uview[n] or 0) + 1 end
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
    -- ammunition: every ammo turret each read (QX1)
    timed('asteroid_watch.ammo', M.ammo, job, tick)
  end
  -- (QX1) every ammo turret's rounds each read: a change split into rounds fired and items loaded (see the header)
  function M.ammo(job, tick)
    for i = 1, #job.tlist do
      local t = job.turrets[job.tlist[i]]
      if t and t.rk and not t.gone and tick - (t.rt or 0) >= (t.every or M.AMMO) then
        local e = t.e
        if e and e.valid then
          -- a slot unchanged since the last read (its count and the top stack's ammo) costs two reads: most turrets most reads
          local inv = t.inv
          if not inv then inv = try(function() return e.get_inventory(defines.inventory.turret_ammo) end); t.inv = inv end
          local st = inv and #inv == 1 and inv[1]
          local same = false
          if st then
            if st.valid_for_read then
              local n, a = st.count, st.ammo
              same = n == t.c1 and a == t.a1 and not t.shot
              t.c1, t.a1 = n, a
            else
              same = t.c1 == 0 and not t.shot
              t.c1, t.a1 = 0, 0
            end
          end
          local now = (not same) and rounds_of(e, {}, inv)
          if same then t.rt, t.reads = tick, t.reads + 1 end
          if now then
            local ticks = tick - (t.rt or tick)
            local keys = {}
            for k in pairs(now) do keys[k] = true end
            for k in pairs(t.rk) do keys[k] = true end
            for k in pairs(keys) do
              local r0, r1 = t.rk[k] or 0, now[k] or 0
              if r0 ~= r1 or (t.shot and ticks > 0) then
                local item = k:match('^(.-)@')
                local m = mag_of(item)
                local d = r0 - r1
                -- the fewest rounds fired that leave a whole number of items loaded
                local c = d
                if d < 0 then c = d % m; if m - c < 1e-6 then c = 0 end end
                if c < 1e-6 then c = 0 end
                local most, instant = max_rounds(job, t.name, item, ticks > 0 and ticks or M.SAMPLE)
                if c > most + 1e-6 then
                  -- more than the turret can fire between two reads: the bound does not hold (unsure)
                  t.unsure = t.unsure + 1
                elseif c + m <= most + 1e-6 then
                  -- a load could hide a shot: the turret's hits since the last read show one when its ammo hits as it
                  -- fires (instant); a rocket's hit lands after its flight, maybe in a later interval than its shot
                  if t.shot and instant and c < 1e-6 then c = m
                  else t.unsure, t.hidden = t.unsure + 1, (t.hidden or 0) + math.floor((most - c) / m + 1e-6) * m end
                end
                local loaded = (r1 - r0 + c) / m
                t.used, t.uitems = t.used + c, (t.uitems or 0) + c / m
                if c > 0 then t.uby = t.uby or {}; t.uby[k] = (t.uby[k] or 0) + c / m end
                if loaded > 1e-6 then t.loaded = t.loaded + math.floor(loaded + 0.5) end
                t.items[k] = true
              end
            end
            t.rk, t.rt, t.reads, t.shot = now, tick, t.reads + 1, nil
            -- how often to read it: the longest multiple of SAMPLE up to AMMO_MAX ticks over which it fires fewer
            -- rounds than a magazine holds (exact), or at most one shot with magazines of 1
            local item = next(now)
            item = item and item:match('^(.-)@')
            if item then
              local m, every = mag_of(item), M.AMMO
              local per = max_rounds(job, t.name, item, 1)
              for k = M.AMMO_MAX, M.AMMO, -M.AMMO do
                local most = max_rounds(job, t.name, item, k)
                if most < m - 1e-6 or (m <= 1 and most <= per + 1e-6) then every = k; break end
              end
              t.every = every
            end
          end
        else t.gone, t.e = tick, nil end
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
            t.shot = true
          end
        elseif cause and cause.valid and cause.type == 'asteroid' and e.force and e.force.name == job.force then
          local r, ust = rec_of(job, cause, event.tick)
          if ust == 1 then job.untr[cause.unit_number] = 2; local n = cause.name; job.uhit[n] = (job.uhit[n] or 0) + 1 end
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
        local r, ust = rec_of(job, e, event.tick)
        if ust == 1 then job.untr[e.unit_number] = 3; local n = e.name; job.udied[n] = (job.udied[n] or 0) + 1 end
        add_death(job, e.name, e.position, event.tick)
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
  -- (QX1) the platform's ammunition consumed since the game began, by "name@quality" (item production statistics of
  -- its surface, every ammo item at every quality: api.count_by, qflow.lua's)
  local AMMO_ITEMS
  function M.consumed(force, s)
    local stats = try(function() return force.get_item_production_statistics(s) end)
    if not (stats and api.count_by) then return nil end
    if not AMMO_ITEMS then
      AMMO_ITEMS = {}
      for n in pairs(try(function() return prototypes.get_item_filtered({{filter='type', type='ammo'}}) end) or {}) do AMMO_ITEMS[#AMMO_ITEMS+1] = n end
      table.sort(AMMO_ITEMS)
    end
    local out = {}
    for _, n in ipairs(AMMO_ITEMS) do
      local total, by = api.count_by(stats, n, 'output')
      if total and total > 0 then
        if by then for _, x in ipairs(by) do out[n .. '@' .. x.quality] = x.n end else out[n .. '@normal'] = total end
      end
    end
    return out
  end
  local CLASSES = {'front/crosses', 'front/misses', 'side/crosses', 'side/misses', 'rear/crosses', 'rear/misses', 'clear', 'unknown'}
  local function class_text(k)
    if k == 'clear' then return 'clear (its line never enters the hull\'s box)' end
    if k == 'unknown' then return 'unknown (no movement read)' end
    local a, c = k:match('^(%a+)/(%a+)$')
    return string.format('%s, %s foundation', a, c == 'crosses' and 'crosses' or 'misses')
  end
  local PASS = {}  -- (QS) the last result's pass: {job, tick, n, units (by name), names (in order)}
  function M.result(job, done, unpaged)
    local now = done and job.until_tick or game.tick
    local secs = math.max(0, now - job.start) / 60
    local function sec(t) return r1((t - job.start) / 60) end
    -- asteroids by approach and projection, and what became of them
    local by = {}
    for _, k in ipairs(CLASSES) do by[k] = {seen=0, destroyed=0, hit=0, left_view=0, in_view=0} end
    local hits = {}
    -- (PE1) totals by asteroid name: the tracked from their records, the untracked from their counts
    local names = {}
    local function nrow(n)
      local t = names[n]
      if not t then t = {name=n, seen=0, destroyed=0, hit=0, left_view=0, in_view=0, untracked=0}; names[n] = t end
      return t
    end
    -- (d25 batch206 QS) one pass over the records: each one's class for the turrets' hits below, and the units by name
    -- in this order for the page read in the same call (PASS)
    local sampled = job.sampled or 0
    local cls, units, order_n = {}, {}, {}
    for u, r in pairs(job.asts) do
      local k = key(r)
      cls[u] = k
      local b = by[k]
      b.seen = b.seen + 1
      local out = r.out
      if not out then out = r.t >= sampled and 'in_view' or 'left_view' end
      local n = r.n
      local nt = names[n]
      if not nt then nt = {name=n, seen=0, destroyed=0, hit=0, left_view=0, in_view=0, untracked=0}; names[n] = nt end
      nt.seen, nt[out] = nt.seen + 1, nt[out] + 1
      local g = units[n]
      if not g then g = {}; units[n] = g; order_n[#order_n+1] = n end
      g[#g+1] = u
      if out == 'destroyed' then
        b.destroyed = b.destroyed + 1
        b.destroyed_by = b.destroyed_by or {}
        local who = r.by_name or 'no cause given'
        b.destroyed_by[who] = (b.destroyed_by[who] or 0) + 1
      elseif out == 'hit' then b.hit = b.hit + 1
      elseif out == 'left_view' then b.left_view = b.left_view + 1 else b.in_view = b.in_view + 1 end
    end
    for n, c in pairs(job.useen or {}) do
      local nt = nrow(n)
      local died, hit, view = (job.udied or {})[n] or 0, (job.uhit or {})[n] or 0, (job.uview or {})[n] or 0
      nt.seen, nt.untracked = nt.seen + c, c
      nt.destroyed, nt.hit, nt.in_view = nt.destroyed + died, nt.hit + hit, nt.in_view + view
      nt.left_view = nt.left_view + math.max(0, c - died - hit - view)
    end
    local by_name, name_lines = {}, {}
    for n, t in pairs(names) do
      if t.untracked == 0 then t.untracked = nil end
      -- (QX1) when first seen: in view at the first read, or later (a fragment matched to a death, or the rest)
      local c = job.coh and job.coh[n]
      if c then t.in_first_sample, t.later, t.later_fragments, t.later_other = c.first, c.fragment + c.later, c.fragment, c.later end
      by_name[#by_name+1] = t
    end
    table.sort(by_name, function(a, b) if a.seen ~= b.seen then return a.seen > b.seen end return a.name < b.name end)
    for _, t in ipairs(by_name) do
      local paren = {}
      if t.untracked then paren[#paren+1] = string.format('%d untracked', t.untracked) end
      if t.later then paren[#paren+1] = string.format('%d in view at the first read, %d first seen later: %d fragments, %d other', t.in_first_sample, t.later, t.later_fragments, t.later_other) end
      name_lines[#name_lines+1] = string.format('%s: %d seen%s, %d destroyed, %d hit the platform, %d left the view, %d still in view', t.name, t.seen,
        #paren > 0 and ' (' .. table.concat(paren, '; ') .. ')' or '', t.destroyed, t.hit, t.left_view, t.in_view)
    end
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
    local rows, groups, gorder, used_by = {}, {}, {}, {}
    local fired, idle = 0, 0
    PASS.job, PASS.tick, PASS.n, PASS.units, PASS.names = job, game.tick, job.nast, units, order_n
    for _, t in pairs(job.turrets) do
      local th, td, tk = {}, {}, {}
      t.hits, t.dmg, t.kills = th, td, tk
      for u, h in pairs(t.ah) do
        local k = cls[u] or 'untracked'
        th[k] = (th[k] or 0) + h[1]
        td[k] = (td[k] or 0) + h[2]
        local kh = h[3]
        if kh > 0 then tk[k] = (tk[k] or 0) + kh end
      end
      local nh = sum(t.hits)
      local fired_any = nh > 0 or t.used > 0
      if fired_any then fired = fired + 1 else idle = idle + 1 end
      local gk = t.name .. '|' .. t.region
      local g = groups[gk]
      if not g then g = {name=t.name, region=t.region, turrets=0, hits={}, kills={}, damage=0, ammo_used=0, rounds_used=0, unsure_reads=0}; groups[gk] = g; gorder[#gorder+1] = gk end
      g.turrets = g.turrets + 1
      for k, n in pairs(t.hits) do g.hits[k] = (g.hits[k] or 0) + n end
      for k, n in pairs(t.kills) do g.kills[k] = (g.kills[k] or 0) + n end
      g.damage, g.ammo_used, g.rounds_used, g.unsure_reads = g.damage + sum(t.dmg), g.ammo_used + (t.uitems or 0), g.rounds_used + t.used, g.unsure_reads + (t.unsure or 0)
      for k, v in pairs(t.uby or {}) do used_by[k] = (used_by[k] or 0) + v end
      if fired_any then
        local items = {}
        for k in pairs(t.items or {}) do items[#items+1] = k end
        for k in pairs(t.rk or {}) do if not (t.items or {})[k] then items[#items+1] = k end end
        table.sort(items)
        rows[#rows+1] = {name=t.name, position=t.position, region=t.region, quality=t.quality, range=t.range, base_range=base_of(t.name), min_range=t.min_range, turn_range=t.turn_range, facing=t.facing, hits=t.hits, kills=t.kills, damage=r1(sum(t.dmg)),
          rounds_used=r3(t.used), ammo_used=r3(t.uitems or 0), ammo_loaded=t.loaded, rounds_start=t.r0 and r3(t.r0), rounds_end=t.rk and r3(sum(t.rk)),
          ammo=#items > 0 and table.concat(items, ', ') or nil, reads=t.reads, every=t.every, unsure_reads=t.unsure, exact=t.rk and (t.unsure or 0) == 0 or nil,
          rounds_used_most=(t.unsure or 0) > 0 and r3(t.used + (t.hidden or 0)) or nil,
          gone_s=t.gone and sec(t.gone) or nil, n=nh}
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
      g.damage, g.ammo_used, g.rounds_used = r1(g.damage), r3(g.ammo_used), r3(g.rounds_used)
      grows[#grows+1] = g
      glines[#glines+1] = string.format('%s x%d (%s of the hull): %d hits, %d kills, %g damage, %g ammo used (%g rounds%s); on asteroids clear of the hull\'s box %d hits and %d kills, on ones whose line enters it but crosses no foundation %d hits and %d kills',
        g.name, g.turrets, g.region, h, k, g.damage, g.ammo_used, g.rounds_used, g.unsure_reads > 0 and string.format(', %d reads unsure', g.unsure_reads) or ', exact', hc, kc, hm, km)
    end
    local nd, nh = 0, 0
    for _, t in ipairs(by_name) do nd, nh = nd + t.destroyed, nh + t.hit end
    -- (QX1, Sol: "3000 seen without capped warning; tracked cohort stops growing by ~577s") the cap said in the headline
    local capped = job.cap_tick and string.format('; tracked capped at %d from +%gs: the %d first seen after that are counted (unique asteroids, each once), not followed',
      M.MAX_ASTEROIDS, sec(job.cap_tick), job.untracked) or ''
    -- the platform's ammunition consumed (item production statistics), and the turrets' reads beside it
    local consumed, consumed_lines = nil, nil
    if job.stats0 then
      local f, sf = try(function() return game.forces[job.force] end), game.get_surface(job.surface)
      local now_c = f and sf and M.consumed(f, sf) or {}
      consumed, consumed_lines = {}, {}
      local keys = {}
      for k in pairs(now_c) do keys[k] = true end
      for k in pairs(used_by) do keys[k] = true end
      local list = {}
      for k in pairs(keys) do list[#list+1] = k end
      table.sort(list)
      for _, k in ipairs(list) do
        local d = (now_c[k] or 0) - (job.stats0[k] or 0)
        local u = used_by[k] or 0
        if d ~= 0 or u > 0 then
          consumed[#consumed+1] = {ammo=k, consumed=d, turrets_used=r3(u)}
          consumed_lines[#consumed_lines+1] = string.format('%s: %d consumed on %s (item production statistics), %g used by the turrets\' reads', k, d, job.platform, r3(u))
        end
      end
    end
    local line = string.format('%s %s for %gs%s: %d asteroids seen in view%s (%d in view now), %d destroyed, %d hit the platform; turrets %d fired, %d did not%s',
      done and 'watched' or 'watching', job.platform, r1(secs), done and '' or string.format(' of %ds', job.seconds), job.nast + job.untracked,
      job.untracked > 0 and string.format(', %d of them past the %d tracked', job.untracked, M.MAX_ASTEROIDS) or '', job.in_view or 0, nd, nh, fired, idle, capped)
    local out = {watching=not done or nil, done=done or nil, platform=job.platform, seconds=job.seconds, seconds_watched=r1(secs), start_tick=job.start, end_tick=done and job.until_tick or nil,
      samples=job.samples, every_ticks=M.SAMPLE, view=job.view, hull={left_top={x=job.hull.x0, y=job.hull.y0}, right_bottom={x=job.hull.x1, y=job.hull.y1}},
      drift_tiles_per_s=drift(job) and {x=r3(drift(job).x * 60), y=r3(drift(job).y * 60)} or nil,
      asteroids=job.nast + job.untracked, tracked=job.nast, tracked_cap=M.MAX_ASTEROIDS, untracked=job.untracked,
      capped=job.cap_tick and true or nil, capped_at_tick=job.cap_tick, capped_at_s=job.cap_tick and sec(job.cap_tick) or nil,
      untracked_unit='asteroids (unit numbers), each counted once however many reads saw it, first seen after the tracked set reached its cap',
      cohort_note=M.COHORT, ammo_note=M.AMMO_NOTE, platform_consumed=consumed, platform_consumed_lines=consumed_lines,
      by_name=by_name, by_name_lines=name_lines, scope=string.format('by_name counts every asteroid seen in view (%d); classes, platform_hits, the turrets\' kills by class and trajectories cover the tracked ones (the first %d seen: %d), untracked: %d (their turret hits and kills count as untracked)%s',
        job.nast + job.untracked, M.MAX_ASTEROIDS, job.nast, job.untracked, M.CHUNKS),
      classes=classes, class_lines=class_lines,
      platform_hits=#job.hits, platform_hit_lines=#hits > 0 and hits or nil,
      turret_groups=grows, turret_group_lines=glines, turrets=rows, turret_rows_more=turret_rows_more, line=line, note=M.NOTE}
    if unpaged then return out end
    return M.page(out, job, {})  -- the default page (the rarest names first) for every reader
  end
  M.COHORT = 'by_name in_first_sample: in view at the watch\'s first read; later: first seen after it, later_fragments of them first seen within '
    .. M.MATCH_R .. ' tiles (plus ' .. M.MATCH_DRIFT .. ' a tick since) of where an asteroid whose dying effect creates that name died (any death on the platform\'s surface the watch got, in the '
    .. M.MATCH_TICKS .. ' ticks before plus a read): told by name, place and time, as the game links them by no event (the dying effect\'s trigger_created_entity is false); later_other: the rest (come into the view: new ones arrive at its front edge while the platform flies; or a fragment of a death not matched)'
  M.AMMO_NOTE = 'per turret (ammo turrets): rounds_start and rounds_end exact (each stack (count - 1) * magazine size + the top magazine\'s ammo left); rounds_used and ammo_loaded from its ammo slot read every '
    .. M.AMMO .. '-' .. M.AMMO_MAX .. ' ticks (every: the longest interval over which it fires fewer rounds than a magazine holds, or one shot at most with magazines of 1), each read\'s change split into rounds fired and whole items loaded; exact (unsure_reads 0) while the most rounds the turret fires between two reads (its cooldown with the force\'s shooting speed bonus) is under its magazine size (gun turrets); '
    .. 'with a magazine of 1 (rocket, railgun) a load and a shot between two reads offset each other: with instant ammo (railgun) the turret\'s hits in that interval count the shot, else that read is unsure_reads and counts none (a rocket\'s hit lands after its flight, so its hits do not date its shots): rounds_used is then the fewest it fired, rounds_used_most the most (each unsure read hiding as many shots as fit in it); '
    .. 'ammo_used is rounds_used in items; platform_consumed: the item production statistics\' consumed count on the platform over the watch (every turret\'s shots, whole platform), beside the turrets\' ammo_used summed'
  M.CHUNKS = '; asteroid chunks are not entities: this watch does not see them, and nothing it reads is collected (platform_supply {collection: true} and its collector_tally watch read chunks and what collectors take)'
  M.NOTE = 'heading: a platform faces north; approach is where the asteroid\'s straight line enters the box round the hull\'s foundation (front the north edge, side west or east, rear south; clear: it never enters it); '
    .. 'crosses/misses: a straight-line projection from its last two sampled positions (one seen once takes the drift common to the others: assumed_drift), as wide as the asteroid, until it leaves the view: '
    .. 'whether it would cross a foundation tile if no turret fired and the platform kept its speed; a projection, not what happened; outcome is what happened (the game\'s events: destroyed and by what, hit an entity of ours, left the view, still in view); '
    .. 'turret hits are its damage events on asteroids, kills the asteroids it destroyed; rounds and ammo used: ammo_note'

  -- (d24 batch161 QD1, Astra #2212: a watch counted 1 huge-promethium destroyed and 3 big-promethium leaving the view,
  -- and its trajectories showed only the first 24 asteroids, all common) the read's trajectories: every tracked
  -- asteroid's record, a page at a time (trajectory_page, trajectory_limit), filtered by name (asteroid_names: names,
  -- or patterns with *); without a filter the rarest names first by the watch's own by_name counts. Points are kept for
  -- the first TRACK tracked (the sampling is as it was); the rest have their first and last tick and position.
  local function name_pattern(n)
    return '^' .. n:gsub('[%^%$%(%)%%%.%[%]%+%-%?]', '%%%0'):gsub('%*', '.*') .. '$'
  end
  local function asteroid_names()
    local out = {}
    local ok = pcall(function()
      for n in pairs(prototypes.get_entity_filtered({{filter='type', type='asteroid'}})) do out[#out+1] = n end
    end)
    if not ok or #out == 0 then for n in pairs(prototypes and prototypes.entity or {}) do if n:find('asteroid', 1, true) then out[#out+1] = n end end end
    table.sort(out)
    return out
  end
  function M.pick_args(a)
    local pick = {}
    assert(a.segment_start == nil or (type(a.segment_start) == 'number' and a.segment_start == math.floor(a.segment_start)), 'segment_start: a segment\'s start tick (segments lists them)')
    if a.asteroid_names ~= nil then
      local v = a.asteroid_names
      if type(v) == 'string' then v = {v} end
      assert(type(v) == 'table' and #v >= 1 and #v <= M.NAMES_MAX, 'asteroid_names: 1..' .. M.NAMES_MAX .. ' asteroid names, or patterns with * ("*promethium*")')
      local known, set = asteroid_names(), {}
      for _, n in ipairs(known) do set[n] = true end
      pick.names, pick.patterns = {}, {}
      for _, n in ipairs(v) do
        assert(type(n) == 'string' and #n >= 1 and #n <= M.NAME_LEN, 'asteroid_names: each a name or a pattern, 1..' .. M.NAME_LEN .. ' characters')
        if n:find('*', 1, true) then
          local pat, any = name_pattern(n), false
          for _, k in ipairs(known) do if k:find(pat) then any = true end end
          assert(any, 'asteroid_names: ' .. n .. ' matches no asteroid name (' .. table.concat(known, ', ') .. ')')
          pick.patterns[#pick.patterns+1] = pat
        else
          assert(set[n], 'asteroid_names: unknown asteroid ' .. n .. ' (' .. table.concat(known, ', ') .. ')')
          pick.names[n] = true
        end
        pick.text = (pick.text and pick.text .. ', ' or '') .. n
      end
    end
    if a.trajectory_page ~= nil then
      assert(type(a.trajectory_page) == 'number' and a.trajectory_page >= 1 and a.trajectory_page == math.floor(a.trajectory_page), 'trajectory_page: 1..')
      pick.page = a.trajectory_page
    end
    if a.trajectory_limit ~= nil then
      local l = a.trajectory_limit
      assert(type(l) == 'number' and l >= 1 and l <= M.PAGE_MAX and l == math.floor(l), 'trajectory_limit: 1..' .. M.PAGE_MAX)
      pick.limit = l
    end
    return pick
  end
  local function matches(pick, n)
    if not pick.names then return true end
    if pick.names[n] then return true end
    for _, pat in ipairs(pick.patterns) do if n:find(pat) then return true end end
    return false
  end
  -- The turrets that hit each asteroid of set (their damage events), the most hits first, at most HIT_BY: from the
  -- running watch's turrets, or the map a done watch kept (hit_map).
  local function hits_on(job, set)
    local out = {}
    if job.turrets then
      for _, t in pairs(job.turrets) do
        local label  -- (QS) a turret's text made once a read, when one of the set is in its hits
        for u, h in pairs(t.ah) do
          if set[u] then
            local l = out[u]
            if not l then l = {}; out[u] = l end
            label = label or t.name .. ' ' .. at(t.position.x, t.position.y)
            l[#l+1] = {turret=label, hits=h[1], damage=r1(h[2]), killed=h[3] > 0 or nil}
          end
        end
      end
    else
      for u in pairs(set) do
        local l = job.hitmap and job.hitmap[u]
        if l then
          local c = {}
          for i, h in ipairs(l) do c[i] = {turret=h[1], hits=h[2], damage=r1(h[3]), killed=h[4] or nil} end
          out[u] = c
        end
      end
    end
    for _, l in pairs(out) do
      table.sort(l, function(a, b) if a.hits ~= b.hits then return a.hits > b.hits end return a.turret < b.turret end)
      while #l > M.HIT_BY do table.remove(l) end
    end
    return out
  end
  -- a done watch keeps every tracked asteroid's record (job.asts) and, from its turrets, who hit which (job.hitmap:
  -- unit -> {{turret, hits, damage, killed}}): the turret loop the result already makes
  function M.keep(job)
    local map = {}
    for _, t in pairs(job.turrets or {}) do
      local label
      for u, h in pairs(t.ah) do
        if job.asts[u] then
          label = label or t.name .. ' ' .. at(t.position.x, t.position.y)
          local l = map[u]
          if not l then l = {}; map[u] = l end
          l[#l+1] = {label, h[1], h[2], h[3] > 0 or nil}
        end
      end
    end
    job.hitmap = map
    for _, r in pairs(job.asts) do r.queued = nil end
  end
  -- (d25 batch206 QS) the tracked records of a name in the order the pages give them: first seen, then unit. job.asts
  -- is filled as asteroids are first seen and pairs walks it in that order, so a group comes nearly sorted: only the
  -- units first seen in the same read are sorted (a full sort when the order is not so). A done watch's groups are kept
  -- (GROUPS, by watch and filter): its records no longer change.
  local GROUPS = setmetatable({}, {__mode='k'})
  local function order(job, g)
    local asts = job.asts
    local n = #g
    for i = 2, n do
      if asts[g[i - 1]].s0 > asts[g[i]].s0 then
        table.sort(g, function(a, b) local ra, rb = asts[a], asts[b]; if ra.s0 ~= rb.s0 then return ra.s0 < rb.s0 end return a < b end)
        return
      end
    end
    local i = 1
    while i <= n do
      local s0, j = asts[g[i]].s0, i
      while j < n and asts[g[j + 1]].s0 == s0 do j = j + 1 end
      if j > i then
        local run = {}
        for k = i, j do run[#run+1] = g[k] end
        table.sort(run)
        for k = i, j do g[k] = run[k - i + 1] end
      end
      i = j + 1
    end
  end
  -- out: the result (a copy); the rows come from job.asts (running, or kept when done); a watch done before they were
  -- kept has its old trajectories (old)
  function M.page(out, job, pick, old)
    local seen = {}
    for _, t in ipairs(out.by_name or {}) do seen[t.name] = t.seen end
    local per, page = pick.limit or M.PAGE, pick.page or 1
    out.trajectory_note = string.format('every tracked asteroid has a row: its first and last tick and position, its outcome, the turret that destroyed it (by), what it hit, the turrets that hit it (hit_by, the %d with most hits); points (one a second, up to %d) only for the first %d tracked: the sampling keeps no more', M.HIT_BY, M.POINTS, M.TRACK)
    if not job.asts then
      out.trajectories = old
      out.trajectory_note = 'this watch ended before every tracked asteroid\'s record was kept (d24 batch161): its trajectories are its first ' .. M.TRACK .. ' asteroids; a new watch keeps them all'
      return out
    end
    -- one pass: the picked records by name; the names rarest first; only the groups the page reaches are sorted
    local done = job.result ~= nil and job.turrets == nil
    local fkey = pick.text or ''
    local kept = done and GROUPS[job]
    local groups, names, total, sorted
    if kept and kept.key == fkey then groups, names, total, sorted = kept.groups, kept.names, kept.total, kept.sorted
    elseif not done and PASS.job == job and PASS.tick == game.tick and PASS.n == job.nast then
      -- the result's pass of this call: its units by name, in the same order
      groups, names, total, sorted = {}, {}, 0, {}
      for _, n in ipairs(PASS.names) do
        if matches(pick, n) then local g = PASS.units[n]; groups[n] = g; names[#names+1] = n; total = total + #g end
      end
      PASS.job, PASS.units, PASS.names = nil, nil, nil
    else
      groups, names, total, sorted = {}, {}, 0, {}
      local ok_name = {}
      for u, r in pairs(job.asts) do
        local n = r.n
        local ok = ok_name[n]
        if ok == nil then ok = matches(pick, n); ok_name[n] = ok end
        if ok then
          local g = groups[n]
          if not g then g = {}; groups[n] = g; names[#names+1] = n end
          g[#g+1] = u
          total = total + 1
        end
      end
      if done then GROUPS[job] = {key=fkey, groups=groups, names=names, total=total, sorted=sorted} end
    end
    table.sort(names, function(a, b) local sa, sb = seen[a] or 0, seen[b] or 0; if sa ~= sb then return sa < sb end return a < b end)
    local pages = math.max(1, math.ceil(total / per))
    local from, to = (page - 1) * per + 1, page * per
    local picked, i = {}, 0
    for _, n in ipairs(names) do
      local g = groups[n]
      if i + #g >= from and i < to then
        if not sorted[n] then order(job, g); sorted[n] = true end
        for k = math.max(1, from - i), math.min(#g, to - i) do picked[#picked+1] = g[k] end
      end
      i = i + #g
      if i >= to then break end
    end
    local set = {}
    for _, u in ipairs(picked) do set[u] = true end
    local hb = hits_on(job, set)
    local sampled = job.sampled or 0
    local function sec(t) return r1((t - job.start) / 60) end
    local rows = {}
    for _, u in ipairs(picked) do
      local r = job.asts[u]
      local pj, last = r.prj, r.out_t or r.t
      rows[#rows+1] = {name=r.n, unit=u, first_tick=r.s0, first_s=sec(r.s0), first_position={x=r1(r.p0.x), y=r1(r.p0.y)}, last_tick=last, last_s=sec(last),
        last_position={x=r1(r.p.x), y=r1(r.p.y)}, approach=pj and pj.approach or 'unknown',
        projected=pj and (pj.crosses and string.format('crosses foundation at %s in %gs', at(pj.at.x, pj.at.y), pj.eta_s) or 'crosses no foundation') or 'not projected',
        assumed_drift=pj and pj.assumed or nil, outcome=r.out or ((r.t >= sampled) and 'in_view' or 'left_view'), by=r.by, hit=r.hit and r.hit.name or nil,
        hit_at=r.hit and {x=r1(r.hit.x), y=r1(r.hit.y)} or nil, hit_by=hb[u], velocity=r.v and {x=r3(r.v.x * 60), y=r3(r.v.y * 60)} or nil, points=r.traj}
    end
    out.trajectories = rows
    out.trajectory_page = {page=page, pages=pages, per_page=per, total=total, returned=#rows, from=#rows > 0 and from or nil, to=#rows > 0 and from + #rows - 1 or nil,
      next=page < pages and page + 1 or nil, filter=pick.text,
      order='the rarest names first by this watch\'s by_name seen counts, then by name, then first seen'}
    if pick.names then
      local un, lines = {}, {}
      for _, t in ipairs(out.by_name or {}) do
        if matches(pick, t.name) and t.untracked then
          un[#un+1] = {name=t.name, untracked=t.untracked}
          lines[#lines+1] = string.format('%s: %d past the %d tracked: in by_name (seen, destroyed, hit, left the view), no record or trajectory', t.name, t.untracked, out.tracked_cap or M.MAX_ASTEROIDS)
        end
      end
      if #un > 0 then out.trajectory_untracked, out.trajectory_untracked_lines = un, lines end
      if total == 0 then
        out.trajectory_page.line = 'no tracked asteroid matches ' .. pick.text .. (#un > 0 and '' or ' in this watch (by_name lists every name seen)')
      end
    end
    return out
  end

  -- (QM1, Astra #2292: a laser destroyed mid-watch restarted it and only the summary line was left) mixed.lua closes
  -- the watch at an edit it starts again after: the old watch is done at that tick with its full result and every
  -- tracked asteroid's record (as a watch done at its end keeps them), and is kept on the new one (new.segments, the
  -- oldest first, at most SEGMENTS), read by its start tick (segment_start). Returns the closed watch's result.
  function M.close(job, new, tick, why)
    job.until_tick = math.min(job.until_tick, tick)
    job.result = M.result(job, true)
    M.keep(job)
    job.turrets, job.queue, job.tlist, job.cells, job.untr, job.dg, job.dl = nil, nil, nil, nil, nil, nil, nil
    job.closed_by = why
    local segs = job.segments or {}
    job.segments = nil
    segs[#segs+1] = job
    local dropped, held = job.segments_dropped or 0, 0
    job.segments_dropped = nil
    for _, g in ipairs(segs) do held = held + (g.nast or 0) end
    while #segs > 1 and (#segs > M.SEGMENTS or held > M.SEGMENT_RECORDS) do
      held = held - (segs[1].nast or 0)
      table.remove(segs, 1)
      dropped = dropped + 1
    end
    if new then new.segments, new.segments_dropped = segs, dropped > 0 and dropped or nil end
    job.result.segment_start = job.start
    return job.result
  end
  -- the segments a watch keeps, for its reads
  local function seg_rows(job)
    if not job.segments or #job.segments == 0 then return nil end
    local rows = {}
    for i, g in ipairs(job.segments) do
      rows[i] = {segment_start=g.start, end_tick=g.until_tick, seconds=r1((g.until_tick - g.start) / 60), closed_by=g.closed_by,
        line=g.result and g.result.line}
    end
    return rows
  end
  M.SEG_NOTE = 'segments: the watches an edit on the platform (a turret built, destroyed, mined or configured; see mixed) closed before this one began, each with its full result and records: platform_defense {platform, asteroids: true, segment_start: its start tick} reads one (trajectory_page, trajectory_limit and asteroid_names as for the watch); at most ' .. M.SEGMENTS .. ', their tracked asteroids together at most ' .. M.SEGMENT_RECORDS .. ' (the newest always kept), the oldest dropped first (segments_dropped counts them)'

  function M.tick(tick)
    local all = api.state().asteroid_watch
    if not all then return end
    for _, job in pairs(all) do
      if not job.result and tick >= job.next_tick then
        M.sample(job, tick)
        if tick >= job.until_tick or job.gone then
          job.result = M.result(job, true)
          M.keep(job)  -- (d24 batch161 QD1) the records stay for filtered reads
          job.turrets, job.queue, job.tlist, job.cells, job.untr = nil, nil, nil, nil, nil
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
      local pick = M.pick_args(a)
      local segs = seg_rows(job)
      if a.segment_start ~= nil then
        local g
        for _, x in ipairs(job.segments or {}) do if x.start == a.segment_start then g = x end end
        local have = {}
        for _, r in ipairs(segs or {}) do have[#have+1] = tostring(r.segment_start) end
        assert(g, 'segment_start: no segment of your watch starts at tick ' .. tostring(a.segment_start) .. (#have > 0 and ' (kept: ' .. table.concat(have, ', ') .. ')' or ' (it keeps none)'))
        local out = {}
        for k, v in pairs(g.result) do out[k] = v end
        out.segment = {segment_start=g.start, end_tick=g.until_tick, closed_by=g.closed_by}
        out.segments_dropped, out.segments, out.segments_note = job.segments_dropped, segs, M.SEG_NOTE
        return M.page(out, g, pick, g.result.trajectories)
      end
      if job.result then
        job.read_tick = game.tick
        local out = {}
        for k, v in pairs(job.result) do out[k] = v end
        out.segments_dropped, out.segments, out.segments_note = job.segments_dropped, segs, segs and M.SEG_NOTE or nil
        return M.page(out, job, pick, job.result.trajectories)
      end
      local out = M.result(job, false, true)
      out.segments_dropped, out.segments, out.segments_note = job.segments_dropped, segs, segs and M.SEG_NOTE or nil
      return M.page(out, job, pick)
    end
    for _, k in ipairs({'asteroid_names', 'trajectory_page', 'trajectory_limit', 'segment_start'}) do
      assert(a[k] == nil, k .. ' is for the read (platform_defense {platform, asteroids: true} without seconds)')
    end
    local seconds = a.seconds
    assert(type(seconds) == 'number' and seconds >= M.SECONDS[1] and seconds <= M.SECONDS[2] and seconds == math.floor(seconds), string.format('seconds: %d..%d', M.SECONDS[1], M.SECONDS[2]))
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
      local rk = e.type == 'ammo-turret' and rounds_of(e, {}) or nil
      local r0 = nil
      if rk then r0 = 0; for _, v in pairs(rk) do r0 = r0 + v end end
      local rg = range_of(e)
      turrets[e.unit_number] = {e=e, name=e.name, position={x=e.position.x, y=e.position.y}, region=region(hull, e.position), used=0, loaded=0, ah={},
        rk=rk, r0=r0, rt=game.tick, reads=0, unsure=0, items={}, quality=rg.quality, range=rg.range, min_range=rg.min, turn_range=rg.turn,
        facing=rg.turn and DIR[e.direction] or nil}
    end
    local replaced = store()[p.index] and not store()[p.index].result
    local stats0 = M.consumed(q.force, s)
    local job = {start=game.tick, until_tick=game.tick + seconds * 60, next_tick=game.tick, seconds=seconds, samples=0, platform=pl.name, surface=s.index,
      force=q.force.name, hull=hull, view=view, asts={}, nast=0, ntrack=0, untracked=0, untr={}, useen={}, uhit={}, udied={}, uview={}, queue={}, hits={}, turrets=turrets, tlist=tlist, cells={}, reason=reason, stats0=stats0}
    store()[p.index] = job
    return {watching=true, seconds=seconds, start_tick=job.start, platform=pl.name, turrets=n,
      hull={left_top={x=hull.x0, y=hull.y0}, right_bottom={x=hull.x1, y=hull.y1}}, view=view,
      replaced=replaced and 'your earlier watch, still running, was replaced' or nil,
      line=string.format('watching the asteroids in view of %s (foundation box (%d,%d)-(%d,%d), view %d tiles out from its chunks) and its %d turrets for %ds, a read every %d ticks: platform_defense {platform, asteroids: true} reads it so far, and in full once done',
        pl.name, hull.x0, hull.y0, hull.x1, hull.y1, M.VIEW_MARGIN, n, seconds, M.SAMPLE),
      note=M.NOTE}
  end
  M.ARGS = {asteroids='optional true: an asteroid watch on that platform instead (d22 batch82 AR1): with seconds it starts one, without it reads yours: the asteroids in view of the platform (its foundation\'s chunks, 32 tiles out) and its turrets, a read every 15 ticks; one watch an agent, a new one replaces it',
    seconds='with asteroids: 10..1800, how long to watch',
    asteroid_names='optional, reading the watch (no seconds): 1..16 asteroid names, or patterns with * ("*promethium*"): only the tracked asteroids of those names in trajectories, and the untracked ones of them counted (trajectory_untracked)',
    trajectory_page='optional, reading the watch: 1.. the page of trajectories (trajectory_page {page, pages, per_page, total, returned, from, to, next, filter, order})',
    trajectory_limit='optional, reading the watch: 1..100 trajectories a page (default 24)',
    segment_start='optional, reading the watch: the start tick of a segment (segments): that closed watch\'s full read', reason='optional text, up to 200 characters: your own reason to wait for it, shown with the watch in your sleep line, sleep_check and the operator\'s idle check',
    asteroids_returns='the start: hull (the box round its foundation), view, turrets, line; without seconds it reads it so far (watching) or done: asteroids (seen in view, every one), tracked (those followed one by one: the first tracked_cap seen), untracked (seen past the cap, each counted once), by_name [{name, seen, destroyed, hit, left_view, in_view, untracked}] (every asteroid, by name, the most seen first) and by_name_lines, scope (which totals cover which asteroids; asteroid chunks are not entities and not seen here), classes (the tracked ones) [{class (front|side|rear by where its straight line enters the hull\'s box, the platform facing north; /crosses or /misses: whether that line crosses foundation; clear: it never enters the box; unknown), seen, destroyed, hit, left_view, in_view}] and class_lines; '
      .. 'platform_hits and platform_hit_lines (what each asteroid that hit us hit, where, its damage, its approach and projection); turret_groups [{name, region (front|middle|rear third of the hull, west|east half), turrets, hits, kills (by class), damage, ammo_used}] and turret_group_lines (hits and kills on clear asteroids and on ones crossing no foundation); '
      .. 'turrets (those that fired: name, position, region, quality, range (its prototype\'s times its quality\'s range_multiplier), base_range (its prototype\'s), min_range, turn_range and facing (when under a full turn), hits, kills by class, damage, rounds_used, ammo_used (items), ammo_loaded (items), rounds_start, rounds_end, ammo (its items), reads, every (ticks between its reads), unsure_reads, exact, rounds_used_most (not exact: the most it can have fired) (ammo_note); up to 64, turret_rows_more past that); '
      .. 'platform_consumed [{ammo, consumed (the platform\'s item production statistics over the watch), turrets_used}] and platform_consumed_lines; capped, capped_at_tick, capped_at_s (the tracked set reached tracked_cap), untracked_unit; by_name rows also in_first_sample, later, later_fragments, later_other (cohort_note); trajectories (every tracked asteroid, 24 a page (trajectory_page, trajectory_limit), the rarest names first by by_name\'s seen counts, or those asteroid_names picks: name, unit (its unit number), first_tick, first_s, first_position, last_tick, last_s, last_position, approach, projected, assumed_drift, outcome (destroyed, hit, left_view, in_view), by (the turret that destroyed it), hit and hit_at (what of ours it hit), hit_by [{turret, hits, damage, killed}], velocity (tiles a second), points [[tick, x, y]] one a second for the first 24 tracked only), trajectory_page, trajectory_untracked (asteroid_names: those names\' untracked counts: no record), trajectory_note; segments [{segment_start, end_tick, seconds, closed_by, line}] (the watches an edit on the platform closed before this one began, at most 3 and 3000 tracked asteroids together, each read in full with segment_start), segments_dropped and segments_note; drift_tiles_per_s; line; note. Read only'}
  return M
end
