-- floorcheck: the hub's foundation rules (tilecheck.lua's play) over a large set of foundation tiles, across ticks
-- (d17 batch33 A1, Sol: Wayfarer's 3318 tile ghosts; the one-tick check stopped at 4096 steps and the dry run read the
-- rest as 107 unbuildable tiles). On world n a rule check costs about 25-35 us (most of it tile reads), so a fill of a
-- few thousand tiles is CHECKS a tick: the play first, then why each tile left unbuilt stays (its rule now). A check is
-- kept in storage (MAX_JOBS, the oldest dropped) and read by id: running (how many checks so far, how many queued) or
-- done (built, unbuilt with their reasons counted and the first ROWS named). Nothing in the game changes.
return function(api)
  local M = {}
  M.CHECKS, M.MAX_JOBS, M.ROWS = 150, 4, 12
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
      end
    end
    if job.i > #job.ghosts then
      job.done = game.tick
      local built = 0
      for _ in pairs(job.play.built) do built = built + 1 end
      job.built = built
      -- the large tables go; the counts stay
      job.ghosts, job.cache, job.play = nil, nil, {steps=job.play.steps}
    end
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
    out.state = 'done'; out.done_tick = job.done; out.built = job.built; out.unbuilt_count = job.unbuilt_n
    out.unbuilt = #job.unbuilt > 0 and job.unbuilt or nil
    local parts = {}
    for why, k in pairs(job.by) do parts[#parts+1] = k .. ' ' .. why end
    table.sort(parts)
    out.by_reason = #parts > 0 and parts or nil
    out.line = string.format('floor check #%d (%s): %d tiles checked by the hub\'s rules in %d s: %d built in turn, %d never built%s',
      job.id, tostring(job.label), job.n, math.floor((job.done - job.started) / 60), job.built or 0, job.unbuilt_n,
      #parts > 0 and ' (' .. table.concat(parts, '; ') .. ')' or '')
    return out
  end
  return M
end
