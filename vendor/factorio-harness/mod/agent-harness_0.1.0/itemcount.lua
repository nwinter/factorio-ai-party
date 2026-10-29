-- itemcount (d28 batch325 IC, Astra #2717: supply's Nauvis read of agricultural science stopped at the census caps,
-- 10000 of 19304 belts and 4096 of 7523 robots, so a residual of 208 could not tell the stock it left out from what
-- spoiled): one item's complete count on a surface's belts and in its robots' cargo, read in the background a page a
-- step, with each page's tick and the coverage when every page is done. supply {item, count_all: true}.
-- - Belts: the walk's bands (walk.lua: the box where the force built, a band found per step until one holds belts), each
--   belt read with get_item_count(item): on a copy of world n's newest autosave (tick 78529013) the same as its transport lines' counts with
--   an underground's buried lines once (iron plate 2005 on 3353 belts, 2540 on 1181 undergrounds), at ~0.6 us a belt
--   against ~3 us for the lines. Belts do not move: each is read once, in the band its position falls in.
-- - Robots: each logistic network's flying robots (LuaLogisticNetwork.logistic_robots and construction_robots: their
--   number is all less available, 5677 = 7523 - 1846 on n), one list a step, then their cargo, ROBOTS_A_STEP a step.
--   A robot read in one network's list is read once. A robot in no network (none lists it) is not read: coverage says
--   how many networks and robots were read.
-- Costs on world n (d28 ~17:45, read-only probes): network 243's list of 5677 robots 5.9 ms (the copy: 4747 in 2.5 ms), 1000 cargo reads
-- 1.2 ms (the copy 1.3), a one-chunk band of 356 belts 0.29 ms and their counts 0.17 ms (the copy 0.29 and 0.40). A
-- network whose list would pass ROBOT_LIST_MAX flying robots (~1 us each on n) is left out and said: never a step over
-- 10 ms. Items move between pages (a robot delivers, a belt carries on): the total is the pages' sum, each read at its
-- own tick (first_tick..last_tick), never one snapshot. Normal quality, as supply's where counts.
-- One job at a time; others wait in order (MAX_JOBS kept). A done count is kept KEEP ticks; asking again within
-- FRESH ticks returns it, later starts a new one. Read only: nothing in the game changes.
return function(api)
  local M = {}
  M.EVERY, M.BELTS_A_STEP, M.BANDS_A_STEP, M.ROBOTS_A_STEP, M.ROBOT_LIST_MAX = 5, 1500, 4, 2000, 8000
  M.KEEP, M.FRESH, M.MAX_JOBS, M.MAX_PAGES = 108000, 18000, 4, 300
  local BELTS = {'transport-belt', 'underground-belt', 'splitter', 'loader', 'loader-1x1', 'linked-belt', 'lane-splitter'}
  local walk = api.walk or require('walk'){state=api.state}
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function book()
    local s = api.state()
    s.itemcount = s.itemcount or {jobs={}, queue={}}
    return s.itemcount
  end
  local function key(force, surface, item) return force.name .. '|' .. surface.index .. '|' .. item end
  local FILTER = {type=BELTS}
  local function surface_of(job) return game.surfaces[job.surface] end
  local function force_of(job) return game.forces[job.force] end

  local function page(job, kind, read, count)
    job.pages = job.pages or {}
    if #job.pages < M.MAX_PAGES then job.pages[#job.pages+1] = {game.tick, kind, read, count}
    else job.pages_dropped = (job.pages_dropped or 0) + 1 end
    job.first_tick = job.first_tick or game.tick
    job.last_tick = game.tick
  end

  -- The networks to read, as ids, with the robots each will list (flying: all less available).
  local function networks(job, s, f)
    local out = {}
    for _, n in ipairs(try(function() return f.logistic_networks[s.name] end) or {}) do
      local log = (n.all_logistic_robots or 0) - (n.available_logistic_robots or 0)
      local con = (n.all_construction_robots or 0) - (n.available_construction_robots or 0)
      out[#out+1] = {id=n.network_id, logistic=log, construction=con}
    end
    return out
  end
  local function network_by_id(s, f, id)
    for _, n in ipairs(try(function() return f.logistic_networks[s.name] end) or {}) do
      if n.network_id == id then return n end
    end
  end

  local function finish(job)
    job.phase, job.done_tick, job.queue, job.walk = 'done', game.tick, nil, nil
    job.nets_todo = nil
  end

  -- One step of the running job: belts (bands, then reads), then robots (a network's list, then cargo).
  function M.step(job)
    local s, f = surface_of(job), force_of(job)
    if not (s and s.valid and f and f.valid) then job.phase, job.failed = 'done', 'the surface or force is gone'; job.done_tick = game.tick; return end
    local item = job.item
    if job.phase == 'belts' then
      local queue = job.queue
      if not queue or job.qi > #queue then
        queue = nil
        FILTER.force = f
        for _ = 1, M.BANDS_A_STEP do
          local band = walk.band(job.walk, s, FILTER)
          if not band then job.walked = true; break end
          job.bands = (job.bands or 0) + 1
          if #band > 0 then queue = band; break end
        end
        FILTER.force = nil
        job.queue, job.qi = queue, 1
        if not queue then
          if job.walked then
            job.phase, job.queue = 'robots', nil
            job.nets_todo = networks(job, s, f)
            job.robots.networks = #job.nets_todo
            job.chunks = job.walk and job.walk.box and (job.walk.box.right - job.walk.box.left + 1) * (job.walk.box.bottom - job.walk.box.top + 1) or nil
          end
          return
        end
      end
      local first, last = job.qi, math.min(#queue, job.qi + M.BELTS_A_STEP - 1)
      local n, read = 0, 0
      for i = first, last do
        local e = queue[i]
        if e.valid then
          read = read + 1
          local c = e.get_item_count(item)
          if c > 0 then n = n + c; job.belts.holding = job.belts.holding + 1 end
        end
      end
      job.qi = last + 1
      job.belts.read, job.belts.count = job.belts.read + read, job.belts.count + n
      page(job, 'belts', read, n)
      return
    end
    if job.phase == 'robots' then
      local queue = job.queue
      if not queue or job.qi > #queue then
        job.queue = nil
        local todo = job.nets_todo or {}
        local nx = table.remove(todo, 1)
        if not nx then finish(job); return end
        local net = network_by_id(s, f, nx.id)
        if not net then job.robots.gone = (job.robots.gone or 0) + 1; return end
        -- logistic robots, then construction robots, each its own list (and step)
        local kind = nx.logistic_done and 'construction' or 'logistic'
        local flying = kind == 'logistic' and ((net.all_logistic_robots or 0) - (net.available_logistic_robots or 0))
          or ((net.all_construction_robots or 0) - (net.available_construction_robots or 0))
        if kind == 'logistic' then nx.logistic_done = true; table.insert(todo, 1, nx) end
        if flying > M.ROBOT_LIST_MAX then
          job.robots.skipped = job.robots.skipped or {}
          job.robots.skipped[#job.robots.skipped+1] = string.format('network %d: %d flying %s robots (a list over %d is one read past the step bound)', nx.id, flying, kind, M.ROBOT_LIST_MAX)
          return
        end
        if flying <= 0 then return end
        local list = try(function() return kind == 'logistic' and net.logistic_robots or net.construction_robots end) or {}
        job.robots.listed = job.robots.listed + #list
        job.queue, job.qi = list, 1
        return
      end
      local first, last = job.qi, math.min(#queue, job.qi + M.ROBOTS_A_STEP - 1)
      local cargo = defines.inventory.robot_cargo
      local n, read = 0, 0
      for i = first, last do
        local r = queue[i]
        if r.valid then
          read = read + 1
          local inv = r.get_inventory(cargo)
          local c = inv and inv.get_item_count(item) or 0
          if c > 0 then n = n + c; job.robots.holding = job.robots.holding + 1 end
        end
      end
      job.qi = last + 1
      job.robots.read, job.robots.count = job.robots.read + read, job.robots.count + n
      page(job, 'robots', read, n)
    end
  end

  function M.tick(tick)
    if tick % M.EVERY ~= 0 then return end
    local b = book()
    local k = b.active
    local job = k and b.jobs[k]
    if not (job and (job.phase == 'belts' or job.phase == 'robots')) then  -- none running: the next waiting
      b.active = nil
      k = table.remove(b.queue, 1)
      job = k and b.jobs[k]
      if not (job and job.phase == 'waiting') then return end
      local s = surface_of(job)
      job.walk = s and walk.start(s) or nil
      if not job.walk or job.walk.whole then
        job.phase, job.failed, job.done_tick, job.walk = 'done', 'no box of where we built on this surface yet (the census walks it first): read again in a few minutes', tick, nil
        return
      end
      job.phase, job.started, b.active = 'belts', tick, k
      return
    end
    M.step(job)
  end

  local function rows(job)
    local out = {}
    for _, p in ipairs(job.pages or {}) do out[#out+1] = string.format('tick %d %s %d read %d', p[1], p[2], p[3], p[4]) end
    return out
  end
  local function result(job)
    local b, r = job.belts, job.robots
    local skipped = r.skipped and #r.skipped > 0
    local out = {item=job.item, surface=job.surface_name, count_all=job.phase == 'done' and (job.failed and 'failed' or 'done') or 'counting',
      phase=job.phase ~= 'done' and job.phase or nil, asked_tick=job.asked, started_tick=job.started, done_tick=job.done_tick,
      first_tick=job.first_tick, last_tick=job.last_tick, failed=job.failed,
      belts={count=b.count, read=b.read, holding=b.holding, bands=job.bands, chunks=job.chunks},
      robots={count=r.count, read=r.read, listed=r.listed, holding=r.holding, networks=r.networks, skipped=r.skipped}}
    if job.phase == 'done' and not job.failed then
      out.total = b.count + r.count
      out.complete = not skipped
      out.coverage = string.format('every belt of ours in the %d chunks of the box where we built on %s (%d belts read, %d hold it), and every flying robot of the %d logistic network%s there (%d read, %d carry it)%s',
        job.chunks or 0, job.surface_name, b.read, b.holding, r.networks, r.networks == 1 and '' or 's', r.read, r.holding,
        skipped and ('; not read: ' .. table.concat(r.skipped, '; ')) or '')
      out.line = string.format('%s on %s: %d on belts, %d in robots\' cargo, %d in all; pages from tick %d to %d (%s)%s',
        job.item, job.surface_name, b.count, r.count, out.total, job.first_tick or job.done_tick, job.last_tick or job.done_tick,
        out.coverage, skipped and ': incomplete' or '')
      out.pages = rows(job)
      out.pages_dropped = job.pages_dropped
    end
    out.note = 'belts and robot cargo only (supply\'s where counts the other places); normal quality; each page read at its own tick, so items that moved between pages (a robot delivering, a belt carrying on) may count twice or not at all; a robot outside every logistic network is not read. Read only'
    return out
  end

  -- supply {item, count_all: true, surface}: the last count of it there if done within FRESH ticks, the progress of a
  -- running one, or a new one queued (one at a time; read again for the result).
  function M.read(p, surface, item, a)
    assert(a.count_all == true, 'count_all is true')
    assert(prototypes.item[item], 'count_all counts an item on belts and in robots\' cargo')
    for _, k in ipairs({'near', 'radius', 'belt_positions', 'belt_tiles', 'all_stopped', 'makers', 'consumers', 'from', 'requesters', 'split', 'stock'}) do
      if a[k] ~= nil then error('count_all counts the whole surface: no ' .. k .. ' with it', 0) end
    end
    local b = book()
    local tick = game.tick
    for kk, j in pairs(b.jobs) do
      if j.phase == 'done' and tick - (j.done_tick or tick) > M.KEEP then b.jobs[kk] = nil end
    end
    local k = key(p.force, surface, item)
    local job = b.jobs[k]
    if job and (job.phase ~= 'done' or (not job.failed and tick - job.done_tick <= M.FRESH)) then
      local out = result(job)
      if job.phase ~= 'done' then
        local ahead = 0
        for i, q in ipairs(b.queue) do if q == k then ahead = i - 1 end end
        out.waiting = b.active ~= k and string.format('queued (%d ahead)', ahead + (b.active and 1 or 0)) or nil
        out.next = 'read again in a few seconds for the result'
      end
      return out
    end
    local n = 0
    for _ in pairs(b.jobs) do n = n + 1 end
    if n >= M.MAX_JOBS then
      local oldest, ok
      for kk, j in pairs(b.jobs) do
        if j.phase == 'done' and (not oldest or j.done_tick < oldest) then oldest, ok = j.done_tick, kk end
      end
      if not ok then error(string.format('count_all: %d counts are running or waiting; read again once one is done', n), 0) end
      b.jobs[ok] = nil
    end
    b.jobs[k] = {item=item, force=p.force.name, surface=surface.index, surface_name=surface.name, asked=tick, phase='waiting',
      belts={count=0, read=0, holding=0}, robots={count=0, read=0, listed=0, holding=0, networks=0}}
    b.queue[#b.queue+1] = k
    local out = result(b.jobs[k])
    out.count_all, out.next = 'started', 'counted in the background, a page every ' .. M.EVERY .. ' ticks; read again in a few seconds for the result'
    return out
  end
  return M
end
