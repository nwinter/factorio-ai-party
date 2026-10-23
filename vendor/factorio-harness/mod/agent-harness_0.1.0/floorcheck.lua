-- floorcheck: the hub's foundation rules (tilecheck.lua's play) over a large set of foundation tiles, across ticks
-- (d17 batch33 A1, Sol: Wayfarer's 3318 tile ghosts; the one-tick check stopped at 4096 steps and the dry run read the
-- rest as 107 unbuildable tiles). On world n a rule check costs about 25-35 us (most of it tile reads), so a fill of a
-- few thousand tiles is CHECKS a tick: the play first, then why each tile left unbuilt stays (its rule now). A check is
-- kept in storage (MAX_JOBS, the oldest dropped) and read by id: running (how many checks so far, how many queued) or
-- done (built, unbuilt with their reasons counted and the first ROWS named). Nothing in the game changes.
return function(api)
  local M = {}
  M.CHECKS, M.MAX_JOBS, M.ROWS = 150, 4, 12
  -- (d23 batch120 CC3, Astra #2019: 25 never built, 12 named) every unbuilt tile up to ALL, as column runs and groups
  M.ALL, M.RUNS, M.GROUPS = 500, 64, 12
  local TC = api.tilecheck or require('tilecheck')()
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function store()
    local s = api.state()
    s.floorcheck = s.floorcheck or {seq=0, jobs={}}
    return s.floorcheck
  end
  local function tile_text(x, y) return string.format('(%g,%g)', x + 0.5, y + 0.5) end
  -- tiles: {x, y} each (tile corners); returns the job id.
  function M.start(surface, tiles, hub, thrusters, label)
    local st = store()
    st.seq = st.seq + 1
    local ghosts = {}
    for i, t in ipairs(tiles) do ghosts[i] = {t[1], t[2], 'space-platform-foundation'} end
    st.jobs[st.seq] = {id=st.seq, surface=surface.index, label=label, n=#ghosts, ghosts=ghosts, started=game.tick,
      play=TC.play_start(ghosts, hub, thrusters), cache={}, phase='play', i=1, unbuilt={}, by={}, unbuilt_n=0}
    local ids = {}
    for id in pairs(st.jobs) do ids[#ids+1] = id end
    table.sort(ids)
    while #ids > M.MAX_JOBS do st.jobs[table.remove(ids, 1)] = nil end
    return st.seq
  end
  local function reason(r)
    if type(r) == 'string' then return r end
    if type(r) == 'table' then return 'building it would split the empty space beside it' end
    return 'held by tiles round it that stay unbuilt'
  end
  -- One job a tick (the oldest running): CHECKS rule checks.
  function M.tick()
    local st = api.state().floorcheck
    if not st then return end
    local job
    for _, j in pairs(st.jobs) do if not j.done and (not job or j.id < job.id) then job = j end end
    if not job then return end
    local s = game.surfaces[job.surface]
    if not s then job.done = game.tick; job.lost = true; return end
    if job.phase == 'play' then
      if TC.play_run(s, job.play, job.cache, M.CHECKS) then job.phase = 'why' end
      return
    end
    -- why each unbuilt one stays: its rule now, CHECKS a tick
    local rule = TC.play_rule(s, job.play, job.cache)
    local n = 0
    while job.i <= #job.ghosts and n < M.CHECKS do
      local g = job.ghosts[job.i]
      job.i = job.i + 1
      local k = TC.key(g[1], g[2])
      if not job.play.built[k] and TC.is_empty(s, g[1], g[2], job.cache) then
        n = n + 1
        local why = reason(rule(g))
        job.unbuilt_n = job.unbuilt_n + 1
        job.by[why] = (job.by[why] or 0) + 1
        if #job.unbuilt < M.ROWS then job.unbuilt[#job.unbuilt+1] = tile_text(g[1], g[2]) .. ': ' .. why end
        job.all = job.all or {}
        if #job.all < M.ALL then job.all[#job.all+1] = {g[1], g[2], why} end
      end
    end
    if job.i > #job.ghosts then
      job.done = game.tick
      job.unbuilt_tiles, job.unbuilt_tiles_more, job.groups = M.runs_text(job.all or {}), nil, M.groups(job.all or {})
      if #job.unbuilt_tiles > M.RUNS then
        job.unbuilt_tiles_more = #job.unbuilt_tiles - M.RUNS
        for k = #job.unbuilt_tiles, M.RUNS + 1, -1 do job.unbuilt_tiles[k] = nil end
      end
      job.all = nil
      local built = 0
      for _ in pairs(job.play.built) do built = built + 1 end
      job.built = built
      -- the large tables go; the counts stay
      job.ghosts, job.cache, job.play = nil, nil, {steps=job.play.steps}
    end
  end
  -- Unbuilt tiles {x, y, why} as runs down a column: '(x,y0..y1)'.
  function M.runs_text(all)
    local list = {}
    for i, c in ipairs(all) do list[i] = c end
    table.sort(list, function(a, b) if a[1] ~= b[1] then return a[1] < b[1] end return a[2] < b[2] end)
    local out, i = {}, 1
    while list[i] do
      local j = i
      while list[j+1] and list[j+1][1] == list[i][1] and list[j+1][2] == list[j][2] + 1 do j = j + 1 end
      out[#out+1] = j == i and tile_text(list[i][1], list[i][2]) or string.format('(%g,%g..%g)', list[i][1] + 0.5, list[i][2] + 0.5, list[j][2] + 0.5)
      i = j + 1
    end
    return out
  end
  -- Unbuilt tiles that touch (by a side or a corner) as groups, largest first: count, box, reasons.
  function M.groups(all)
    local at, seen, groups = {}, {}, {}
    for i, c in ipairs(all) do at[TC.key(c[1], c[2])] = i end
    for i, c in ipairs(all) do
      if not seen[i] then
        seen[i] = true
        local q, k = {i}, 1
        while q[k] do
          local a = all[q[k]]; k = k + 1
          for dx = -1, 1 do for dy = -1, 1 do
            local j = at[TC.key(a[1] + dx, a[2] + dy)]
            if j and not seen[j] then seen[j] = true; q[#q+1] = j end
          end end
        end
        local x0, y0, x1, y1, by = c[1], c[2], c[1], c[2], {}
        for _, j in ipairs(q) do
          local b = all[j]
          x0, y0, x1, y1 = math.min(x0, b[1]), math.min(y0, b[2]), math.max(x1, b[1]), math.max(y1, b[2])
          by[b[3]] = (by[b[3]] or 0) + 1
        end
        groups[#groups+1] = {n=#q, x0=x0, y0=y0, x1=x1, y1=y1, by=by}
      end
    end
    table.sort(groups, function(a, b) return a.n > b.n end)
    local lines = {}
    for i = 1, math.min(M.GROUPS, #groups) do
      local g = groups[i]
      local parts, split = {}, false
      for why, n in pairs(g.by) do parts[#parts+1] = n .. ' ' .. why; if why == reason({}) then split = true end end
      table.sort(parts)
      lines[i] = string.format('%d tile%s in %s-%s: %s%s', g.n, g.n == 1 and '' or 's', tile_text(g.x0, g.y0), tile_text(g.x1, g.y1), table.concat(parts, '; '),
        split and '; the empty space on their sides is one region now and the hub never parts it in two: they are built once every region they would part from it but one is foundation (a dry run of the same placement plans that fill: tiles.holes, tiles.hole_regions)' or '')
    end
    if #groups > M.GROUPS then lines[#lines+1] = string.format('%d more groups', #groups - M.GROUPS) end
    return lines
  end
  function M.read(id)
    local st = store()
    local job = st.jobs[id]
    if not job then
      local ids = {}
      for k in pairs(st.jobs) do ids[#ids+1] = k end
      table.sort(ids)
      error(string.format('no floor check #%s (kept: %s)', tostring(id), #ids > 0 and table.concat(ids, ', ') or 'none'), 0)
    end
    local out = {id=job.id, label=job.label, tiles=job.n, started_tick=job.started}
    if not job.done then
      local queued = job.play and job.play.work and #job.play.work or 0
      out.state = 'running'
      out.checks = job.play and job.play.steps or 0
      out.line = string.format('floor check #%d (%s): %d tiles, running: %d rule checks so far (%d a tick), %d tiles still queued%s; read again',
        job.id, tostring(job.label), job.n, out.checks, M.CHECKS, queued, job.phase == 'why' and ' (naming why the unbuilt ones stay)' or '')
      return out
    end
    -- (d17 batch33 A6, Sol 10:16: "built 2772" read as tiles already built while 660 were) would_build: the plan played
    -- through the hub's rules; floor_now: the foundation tiles built on the surface now
    local s = game.surfaces[job.surface]
    local floor_now = s and try(function() return s.count_tiles_filtered{name='space-platform-foundation'} end) or nil
    out.state = 'done'; out.done_tick = job.done; out.would_build = job.built; out.never_built = job.unbuilt_n; out.floor_now = floor_now
    out.unbuilt = #job.unbuilt > 0 and job.unbuilt or nil
    out.unbuilt_tiles = job.unbuilt_tiles and #job.unbuilt_tiles > 0 and job.unbuilt_tiles or nil
    out.unbuilt_tiles_more = job.unbuilt_tiles_more
    out.groups = job.groups and #job.groups > 0 and job.groups or nil
    local parts = {}
    for why, k in pairs(job.by) do parts[#parts+1] = k .. ' ' .. why end
    table.sort(parts)
    out.by_reason = #parts > 0 and parts or nil
    out.line = string.format('floor check #%d (%s): %d planned tiles played through the hub\'s rules in %d s: %d would be built in turn, %d never%s; the floor built now: %s tiles',
      job.id, tostring(job.label), job.n, math.floor((job.done - job.started) / 60), job.built or 0, job.unbuilt_n,
      #parts > 0 and ' (' .. table.concat(parts, '; ') .. ')' or '', floor_now and tostring(floor_now) or '?')
    return out
  end
  return M
end
