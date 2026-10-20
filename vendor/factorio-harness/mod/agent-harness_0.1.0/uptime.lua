-- uptime {positions, seconds?} (d20 batch53 M3, Sol #1304: the surface's production and a working snapshot disagreed in
-- short supply gaps; which science machine lost time, and why, took dozens of reads). Crafting machines watched over a
-- window as a player watching them sees them: each one's status once a second (the GUI's status line), the ingredients
-- short of one craft in its input at each sample that reads short of ingredients, and the crafts it finished (each
-- craft a player sees finish; the game's products_finished count, read at the start and the end). One watch an agent,
-- up to MAX machines, sampled in the background; uptime {} reads it, so far or done. Left out (said in the reply): what
-- happens between samples (a stop shorter than a second may not be seen), the exact ticks in each status (shares are
-- of samples), and why an ingredient is short upstream.
-- (d20 batch54 N2, viewer Aurora: "Sampling every 60 ticks can miss a 20-tick pulse entirely") sample k comes at
-- start + 60 k + (7 k mod 60) ticks, a phase 7 ticks later each second, so 60 samples meet every tick of a second once
-- and a machine working 20 ticks of every 60 reads a third of the time whatever its phase; the last at the window's end.
-- (d20 batch55 P4, Sol #1393: an EM plant read 106 crafts in 161 s, 153% of its 25.8/min, while working all the time)
-- products_finished counts every completion, the productivity bar's too. The base crafts come from it with the bar:
-- base x (1 + productivity) = completions + bar at the end - bar at the start (bonus_progress, 0..1); crafts are the
-- base ones against the full-speed craft rate, completions against that rate with productivity.
return function(api)
  local M = {}
  M.MAX, M.EVERY, M.STEP = 16, 60, 7
  local function next_at(job)
    local k = job.samples
    return math.min(job.start + M.EVERY * k + (M.STEP * k) % M.EVERY, job.until_tick)
  end
  local CRAFT = {['assembling-machine']=true, furnace=true, ['rocket-silo']=true}
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function at(q) return string.format('(%g,%g)', q.x, q.y) end
  local function store() local s = api.state(); s.uptime = s.uptime or {}; return s.uptime end
  local function input_inv(e)
    local which = e.type == 'furnace' and defines.inventory.furnace_source or defines.inventory.assembling_machine_input
    return try(function() return e.get_inventory(which) end)
  end
  local function recipe_of(e)
    local r = try(function() return e.get_recipe() end)
    if not r and e.type == 'furnace' then
      local prev = try(function() return e.previous_recipe end)
      local n = prev and (type(prev.name) == 'table' and prev.name.name or prev.name)
      r = n and try(function() return e.force.recipes[n] end)
    end
    return r
  end
  local function finished(e) return try(function() return e.products_finished end) or 0 end
  local function bar(e) return try(function() return e.bonus_progress end) or 0 end
  -- Base crafts and productivity completions in `done` completions, the bar from b0 to b1 at productivity prod.
  function M.split(done, b0, b1, prod)
    local base = done
    if prod and prod > 0 then base = math.floor((done + (b1 or 0) - (b0 or 0)) / (1 + prod) + 0.5) end
    base = math.max(0, math.min(done, base))
    return base, done - base
  end
  function M.sample(job)
    job.samples = job.samples + 1
    for _, m in ipairs(job.machines) do
      local e = m.e
      if not (e and e.valid) then m.gone = m.gone or game.tick
      else
        local st = api.status_name and api.status_name(e) or 'unknown'
        m.status[st] = (m.status[st] or 0) + 1
        local r = recipe_of(e)
        local rn = r and r.name or 'none'
        -- an idle furnace reads no recipe: the last one seen is kept
        if rn ~= m.recipe and rn ~= 'none' then
          if m.recipe ~= 'none' then m.recipe_changed = m.recipe_changed or (m.recipe .. ' -> ' .. rn) end
          m.recipe = rn
          if not m.full_cpm and api.craftrate then local rt = try(function() return api.craftrate(e) end); m.full_cpm = rt and rt.crafts_per_min or nil; m.prod = m.prod or rt and rt.productivity end
        end
        if st == 'item_ingredient_shortage' or st == 'fluid_ingredient_shortage' then
          local inv = input_inv(e)
          for _, ing in ipairs(r and try(function() return r.ingredients end) or {}) do
            local have
            if ing.type == 'fluid' then have = try(function() return e.get_fluid_count(ing.name) end) or 0
            else have = inv and try(function() return inv.get_item_count(ing.name) end) or 0 end
            if have < (ing.amount or 0) then
              local s = m.short[ing.name] or {samples=0, least=have, need=ing.amount}
              s.samples = s.samples + 1
              if have < s.least then s.least = have end
              m.short[ing.name] = s
            end
          end
        end
      end
    end
  end
  function M.result(job, done)
    local secs = (game.tick - job.start) / 60
    local rows, lines = {}, {}
    for _, m in ipairs(job.machines) do
      local e = m.e
      local now = e and e.valid and finished(e) or m.last_finished
      if e and e.valid then m.last_finished, m.last_bar = now, bar(e) end
      local done = math.max(0, (now or m.finished0) - m.finished0)
      local crafts, bonus = M.split(done, m.bar0, m.last_bar, m.prod)
      local states, parts = {}, {}
      for k, n in pairs(m.status) do states[#states+1] = {k, n} end
      table.sort(states, function(x, y) return x[2] > y[2] or (x[2] == y[2] and x[1] < y[1]) end)
      local share = {}
      for _, s in ipairs(states) do
        share[s[1]] = s[2]
        parts[#parts+1] = string.format('%s %d%%', (s[1]:gsub('_', ' ')), math.floor(s[2] / math.max(1, job.samples) * 100 + 0.5))
      end
      local short = {}
      for n, s in pairs(m.short) do short[#short+1] = string.format('%s short in %d sample%s (least %g of %g a craft)', n, s.samples, s.samples == 1 and '' or 's', s.least, s.need) end
      table.sort(short)
      local function pm(n) return secs > 0 and math.floor(n / secs * 600 + 0.5) / 10 or 0 end
      local cpm, dpm = pm(crafts), pm(done)
      local prod = m.prod or 0
      local full_done = m.full_cpm and math.floor(m.full_cpm * (1 + prod) * 10 + 0.5) / 10 or nil
      local row = {name=m.name, position=m.position, recipe=m.recipe, crafts=crafts, crafts_per_min=cpm, full_speed_per_min=m.full_cpm,
        completions=done, bonus_completions=bonus, completions_per_min=dpm, full_speed_completions_per_min=prod > 0 and full_done or nil,
        productivity=prod > 0 and prod or nil, working_share=job.samples > 0 and math.floor((share.working or 0) / job.samples * 100 + 0.5) or nil,
        samples=share, short=#short > 0 and short or nil, recipe_changed=m.recipe_changed, gone=m.gone and 'removed' or nil}
      row.line = string.format('%s %s %s: %d craft%s in %ds (%g/min%s)%s; %s%s%s', m.name, at(m.position), m.recipe, crafts, crafts == 1 and '' or 's', math.floor(secs + 0.5), cpm,
        m.full_cpm and m.full_cpm > 0 and string.format(', %d%% of its %g/min at full speed', math.floor(cpm / m.full_cpm * 100 + 0.5), m.full_cpm) or '',
        prod > 0 and string.format(' and %d productivity completion%s (productivity +%d%%): %d completions, %g/min against %s/min at full speed', bonus, bonus == 1 and '' or 's',
          math.floor(prod * 100 + 0.5), done, dpm, full_done and string.format('%g', full_done) or '?') or '',
        #parts > 0 and table.concat(parts, ', ') or 'no sample yet', #short > 0 and '; ' .. table.concat(short, '; ') or '',
        m.gone and '; removed during the watch' or m.recipe_changed and '; recipe changed: ' .. m.recipe_changed or '')
      rows[#rows+1] = row
      lines[#lines+1] = row.line
    end
    return {done=done or nil, watching=not done or nil, seconds=math.floor(secs + 0.5), of_seconds=job.seconds, samples=job.samples, every_ticks=M.EVERY, phase_step_ticks=M.STEP,
      started_tick=job.start, machines=rows, lines=lines,
      left_out='status once a second at a phase 7 ticks later each second (60 samples meet every tick of a second once): a stop shorter than a second may not be seen and shares are of samples, not exact ticks; completions are the machine\'s finished count (productivity\'s included), crafts the base ones from it and its productivity bar (a craft in progress at either end is not counted); why an ingredient is short upstream is not read (supply or trace for that)'}
  end
  function M.tick(tick)
    local all = api.state().uptime
    if not all then return end
    for _, job in pairs(all) do
      if not job.result and tick >= job.next_tick then
        M.sample(job)
        job.next_tick = next_at(job)
        if tick >= job.until_tick then
          job.result = M.result(job, true)
          for _, m in ipairs(job.machines) do m.e = nil end
        end
      end
    end
  end
  function M.handler(p, a)
    if a.positions == nil and a.position == nil then
      local job = store()[p.index]
      assert(job, 'no uptime watch yet: uptime {positions, seconds?}')
      return job.result or M.result(job, false)
    end
    local list = a.positions or {a.position}
    assert(type(list) == 'table' and #list >= 1 and #list <= M.MAX, 'positions: 1..' .. M.MAX .. ' crafting machines {x,y}')
    local seconds = a.seconds == nil and 600 or a.seconds
    assert(type(seconds) == 'number' and seconds >= 10 and seconds <= 3600 and seconds == math.floor(seconds), 'seconds: 10..3600 (default 600)')
    local q = a.surface ~= nil and api.on_surface(p, a.surface) or a.platform ~= nil and api.on_platform(p, a.platform) or p
    local machines = {}
    for _, pos in ipairs(list) do
      local e = api.remote_entity(q, {position=pos})
      assert(CRAFT[e.type], string.format('%s %s is not a crafting machine (an assembler, furnace, chemical plant, biochamber, ...)', e.name, at(e.position)))
      local r = recipe_of(e)
      local rates = api.craftrate and try(function() return api.craftrate(e) end)
      machines[#machines+1] = {e=e, name=e.name, position={x=e.position.x, y=e.position.y}, recipe=r and r.name or 'none', finished0=finished(e),
        bar0=bar(e), status={}, short={}, full_cpm=rates and rates.crafts_per_min or nil, prod=rates and rates.productivity or nil}
    end
    local replaced = store()[p.index] and not store()[p.index].result
    local job = {start=game.tick, until_tick=game.tick + seconds * 60, next_tick=game.tick, seconds=seconds, samples=0, machines=machines}
    store()[p.index] = job
    M.sample(job)
    job.next_tick = next_at(job)
    local lines = {}
    for _, m in ipairs(machines) do lines[#lines+1] = string.format('%s %s %s: %d completions so far (the game\'s count, productivity\'s included)', m.name, at(m.position), m.recipe, m.finished0) end
    return {watching=true, seconds=seconds, machines=#machines, baseline=lines, replaced=replaced and 'your earlier watch, still running, was replaced' or nil,
      line=string.format('watching %d machine%s for %ds, a status sample a second at a phase 7 ticks later each second: uptime {} reads it so far, and in full once done', #machines, #machines == 1 and '' or 's', seconds)}
  end
  M.schema = {uptime = {positions='1..16 crafting machines {x,y} (an assembler, furnace, chemical plant, biochamber, ...; in sight or by remote view)', position='or one',
    seconds='optional 10..3600 (default 600): how long to watch', surface='optional planet name (by remote view)', platform='optional platform name',
    returns='a watch, one an agent (a new one replaces it): the start returns baseline (each machine\'s completions so far) and line; uptime {} reads it so far (watching) or done: per machine crafts (base crafts finished in the window), crafts_per_min against full_speed_per_min (its recipe at its speed), completions (the game\'s count: crafts and productivity completions), bonus_completions, completions_per_min against full_speed_completions_per_min (with its productivity), productivity, working_share (% of samples working), samples by status (the GUI\'s status line, once a second), short (each ingredient under one craft in its input at the samples that read short of ingredients: how many samples, the least held), recipe_changed, gone; lines; left_out (what the watch does not see). Read only'}}
  return M
end
