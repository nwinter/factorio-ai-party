-- ghosttally: every ghost of a platform counted by the item and quality it takes, across ticks (d17 batch33 A1, Sol:
-- Wayfarer's 1597 entity ghosts and 3318 tile ghosts; the hub's blockers read counts at most space.GHOST_CAP of each in
-- one tick, about 4 us a ghost on world n). A tally finds the entity ghosts on one tick, the tile ghosts on the next,
-- then counts PER_TICK ghosts a tick; done, it is kept FRESH ticks. Storage only; nothing in the game changes.
return function(api)
  local M = {}
  M.PER_TICK, M.FRESH = 1000, 1800
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function store()
    local s = api.state()
    s.ghost_tally = s.ghost_tally or {jobs={}, done={}}
    return s.ghost_tally
  end
  -- The last tally of the platform when FRESH, else nil; a job is started when none runs.
  function M.get(pl)
    local st = store()
    local d = st.done[pl.index]
    if d and game.tick - d.tick <= M.FRESH then return d end
    if not st.jobs[pl.index] then st.jobs[pl.index] = {platform=pl, stage='entity-ghost', started=game.tick, need={}, order={}, counts={}, i=1} end
    return nil, d
  end
  function M.running(pl) local j = store().jobs[pl.index]; return j and j.started end
  local items_of = {}
  function M.tick()
    local st = api.state().ghost_tally
    if not st then return end
    local id, job = next(st.jobs)
    if not job then return end
    local pl = job.platform
    if not (pl and pl.valid and pl.surface) then st.jobs[id] = nil; return end
    local s = pl.surface
    if job.stage == 'entity-ghost' or job.stage == 'tile-ghost' then
      job.lists = job.lists or {}
      job.lists[#job.lists+1] = try(function() return s.find_entities_filtered{type=job.stage} end) or {}
      job.counts[job.stage] = #job.lists[#job.lists]
      job.stage = job.stage == 'entity-ghost' and 'tile-ghost' or 'count'
      job.li, job.i = 1, 1
      return
    end
    local n = 0
    while n < M.PER_TICK do
      local list = job.lists[job.li]
      if not list then break end
      local g = list[job.i]
      if not g then job.li, job.i = job.li + 1, 1
      else
        job.i = job.i + 1
        n = n + 1
        if g.valid then
          local kind = g.type
          local gname = try(function() return g.ghost_name end) or '?'
          local key = kind .. '|' .. gname
          local it = items_of[key]
          if it == nil then
            local first = try(function() return g.ghost_prototype.items_to_place_this[1] end)
            local nm = first and (type(first.name) == 'string' and first.name or first.name and first.name.name)
            it = nm and {name=nm, count=first.count or 1} or false
            items_of[key] = it
          end
          if it then
            local q = api.quality_of and api.quality_of(g) or 'normal'
            local k = it.name .. '@' .. q
            if not job.need[k] then job.need[k] = {name=it.name, quality=q, count=0}; job.order[#job.order+1] = k end
            job.need[k].count = job.need[k].count + it.count
          end
        end
      end
    end
    if not job.lists[job.li] then
      table.sort(job.order)
      st.done[id] = {tick=game.tick, started=job.started, need=job.need, order=job.order, counts=job.counts}
      st.jobs[id] = nil
    end
  end
  return M
end
