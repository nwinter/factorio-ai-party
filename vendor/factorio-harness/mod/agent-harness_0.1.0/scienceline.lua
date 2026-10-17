-- One science line per agent in the team block (operator 03:22: Luna made
-- about 47 reads in 10 minutes to watch copper, power and labs). Facts only,
-- at most every PUSH_TICKS per agent and only when one of them changed:
-- - the research and labs working N of M (on the surface with the most labs);
-- - the limiting pack: the one the most labs hold none of, with made and used
--   per minute, and its chain's first short step (supply.lua chain: the line
--   follows what most makers lack down to where that stops);
-- - power on that surface's largest electric network: draw (5 min average)
--   against capacity and the headroom; its boilers, how many have fuel at
--   their feeders, and those under 20 min not refilled with the lowest
--   (networks.lua, boiler_fuel's rule).
-- Built by a background job in storage, one bounded step every few ticks
-- (operator 04:00: walk.lua, spread over the 5 minutes): each surface's labs
-- a band of chunks a step, read SLICE a step; the crafters a band a step;
-- recipes INDEX_SLICE a step; then the chain and the line. Every peer runs
-- the same job, so every peer has the same line.
return function(api)
  local M = {}
  local PUSH_TICKS, INDEX_SLICE, SLICE, MAX_LABS, MAX_CRAFTERS = 18000, 150, 100, 1024, 2048
  -- The crafters and the miners (mining drills and pumpjacks, offshore pumps: the chain's makers of ores and fluids,
  -- Grok 04:55), walked together.
  local CRAFTERS, IS_MINER = {'assembling-machine', 'furnace', 'rocket-silo', 'mining-drill', 'offshore-pump'}, {['mining-drill']=true, ['offshore-pump']=true}
  local walk = api.walk or require('walk'){state=api.state}
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function store()
    local s = api.state()
    s.science_line = s.science_line or {}
    return s.science_line
  end
  local function mw(kw) return kw >= 1000 and string.format('%.1f MW', kw / 1000) or string.format('%d kW', math.floor(kw + 0.5)) end

  local function start(f)
    local surfaces = {}
    for _, s in pairs(game.surfaces) do
      if not try(function() return s.platform end) then surfaces[#surfaces+1] = s.name end
    end
    table.sort(surfaces)
    local packs = {}
    local tech = f.current_research
    for _, ing in ipairs(tech and tech.research_unit_ingredients or {}) do packs[#packs+1] = ing.name end
    local steps = api.state().science_steps
    return {step='labs', force=f.name, tech=tech and tech.name or nil, progress=f.research_progress or 0, packs=packs,
      surfaces=surfaces, si=1, labs={}, crafters={}, idx=1, by_product={}, start=game.tick, n=0,
      every=walk.every(steps and steps[f.name], PUSH_TICKS)}
  end

  -- A whole colour stopped (Opus, 07:55): a pack the research needs whose makers on the science surface (there are
  -- some) all stand still at a build, still so at a later one PUSH_TICKS or more after the first, is a digest group
  -- science_idle naming the makers' states and its chain's first short step (the root of the stop, e.g. copper ore).
  -- Kept in storage science_idle per force and pack: since (the first build that saw it idle), the line's facts.
  local function idle_store(f)
    local s = api.state()
    s.science_idle = s.science_idle or {}
    s.science_idle[f.name] = s.science_idle[f.name] or {}
    return s.science_idle[f.name]
  end
  function M.check_idle(job, f, surface, scan)
    local was = idle_store(f)
    local now = {}
    -- Only a pack the labs lack (Astra, 12:02: automation's makers stood still with 2534 in chests and 101 in labs,
    -- while all 43 labs lacked agricultural science): a colour whose labs all hold some is not stopped for research.
    local lab = job.labs[job.surface] or {n=0, lack={}}
    for _, pack in ipairs(surface and job.packs or {}) do
      local makers = scan.by_product[pack] or {}
      local working, states, by, sx, sy = 0, {}, {}, 0, 0
      for _, m in ipairs(makers) do
        local status = api.status_name(m.e) or 'unknown'
        if status == 'working' then working = working + 1 else states[status] = (states[status] or 0) + 1 end
        local u = try(function() return m.e.last_user and m.e.last_user.name end)
        if u then by[u] = (by[u] or 0) + 1 end
        sx, sy = sx + m.e.position.x, sy + m.e.position.y
      end
      if #makers > 0 and working == 0 and (lab.lack[pack] or 0) > 0 then
        local chain = api.supply.chain(scan, f, surface, pack)
        local list = {}
        for st, n in pairs(states) do list[#list+1] = {st=st, n=n} end
        table.sort(list, function(x, y) if x.n ~= y.n then return x.n > y.n end return x.st < y.st end)
        for i, x in ipairs(list) do list[i] = x.n .. ' ' .. x.st end
        local path = chain and chain.path or {}
        now[pack] = {since=was[pack] and was[pack].since or job.start, surface=surface.name, makers=#makers, states=table.concat(list, ', '),
          root=path[#path] or pack, last=chain and chain.last or nil, path=#path > 1 and table.concat(path, ' > ') or nil,
          by=by, center={x=math.floor(sx / #makers + 0.5), y=math.floor(sy / #makers + 0.5)}, seen=job.start,
          labs_lacking=lab.lack[pack], labs=lab.n}
      end
    end
    api.state().science_idle[f.name] = now
  end
  -- The digest groups (pushalerts.lua's network groups): each colour idle for PUSH_TICKS or more.
  function M.alert_groups(f)
    local out = {}
    for pack, v in pairs((api.state().science_idle or {})[f.name] or {}) do
      if v.seen - v.since >= PUSH_TICKS then
        out[#out+1] = {key='science_idle|' .. v.surface .. '|' .. pack .. '|' .. v.root, kind='science_idle', surface=v.surface, n=1,
          names={[pack]=v.makers}, by=v.by, at={}, center=v.center,
          line=string.format('no %s maker working for %d+ min (%d makers: %s)%s%s', pack, math.floor((v.seen - v.since) / 3600), v.makers, v.states,
            v.labs and string.format('; %d of %d labs have none', v.labs_lacking or 0, v.labs) or '',
            v.last and '; first short step ' .. v.last .. (v.path and ' (' .. v.path .. ')' or '') or '')}
      end
    end
    table.sort(out, function(a, b) return a.key < b.key end)
    return out
  end

  -- What the line says, from the finished job.
  local function compose(job, f)
    local lab = job.labs[job.surface] or {n=0, working=0, lack={}}
    local parts = {}
    parts[1] = string.format('science on %s: %s; labs %d of %d working', job.surface,
      job.tech and string.format('research %s %d%%', job.tech, math.floor(job.progress * 100)) or 'no research running', lab.working, lab.n)
    -- The limiting pack: most labs without it, then the fewest made.
    local pack, chain
    for _, name in ipairs(job.packs) do
      if (lab.lack[name] or 0) > 0 and (not pack or lab.lack[name] > lab.lack[pack]) then pack = name end
    end
    local key = {job.tech or '', job.surface, lab.working, lab.n}
    local surface = game.get_surface(job.surface)
    local by_product = {}
    for item, list in pairs(job.by_product) do
      local out = {}
      for _, m in ipairs(list) do
        local recipe = m.e.valid and prototypes.recipe[m.recipe]
        if recipe then out[#out+1] = {e=m.e, recipe=recipe} end
      end
      by_product[item] = out
    end
    local scan = {crafters=job.crafters, by_product=by_product, miners=job.miners}
    M.check_idle(job, f, surface, scan)
    if pack then
      chain = surface and api.supply.chain(scan, f, surface, pack)
      local root = chain and chain.tree and chain.tree[1]
      local text = string.format('limiting %s: %d of %d labs have none', pack, lab.lack[pack], lab.n)
      if root then text = text .. string.format(', made %d/min, used %d/min', root.made_per_min, root.used_per_min) end
      parts[#parts+1] = text
      if chain and chain.last then
        local path = chain.path or {}
        parts[#parts+1] = 'first short step ' .. chain.last .. (#path > 1 and ' (' .. table.concat(path, ' > ') .. ')' or '')
      end
      key[#key+1] = pack
      key[#key+1] = chain and chain.path and chain.path[#chain.path] or ''
    elseif #job.packs > 0 and lab.n > 0 then
      parts[#parts+1] = 'every lab holds every pack'
    end
    local power = api.networks.power_row(f, job.surface)
    if power then
      local text = string.format('power electric #%d', power.id)
      if power.draw_kw and power.capacity_kw > 0 then
        -- (backlog #527) headroom against what can supply now; the dry generators' rating and low-power machines named
        local cap = power.supply_kw or power.capacity_kw
        local room = cap - power.draw_kw
        local pct = cap > 0 and math.floor(100 * room / cap + 0.5) or 0
        text = text .. string.format(': %s of %s%s, headroom %s (%d%%)', mw(power.draw_kw), mw(cap),
          (power.dry or 0) > 0 and string.format(' that can supply now (rated %s: %d generators with no steam, fuel or plasma in)', mw(power.capacity_kw), power.dry) or '',
          mw(math.max(room, 0)), pct)
        if (power.low_power or 0) > 0 then text = text .. string.format('; %d machines on low power', power.low_power) end
        key[#key+1] = math.floor(pct / 10)
      else text = text .. string.format(': %s capacity, no draw sample yet', mw(power.capacity_kw)) end
      if power.boilers > 0 then
        local b = string.format('boilers %d', power.boilers)
        if power.fed then
          b = b .. string.format(': %d with fuel at their feeders', power.fed)
          if power.low > 0 then
            local m = power.low_min or 0
            b = b .. string.format(', %d under 20 min of their own fuel and not refilled, lowest %d min', power.low, math.floor(m))
            key[#key+1] = power.low
            key[#key+1] = m < 5 and 3 or m < 10 and 2 or 1
          end
        end
        -- The feed chest running out first at its rate over 10 min (Haiku, 12:20); told again under 20, 10 and 5 min.
        if power.feed then
          b = b .. '; feed chest ' .. power.feed.line
          local m = power.feed.min
          key[#key+1] = 'feed' .. (m < 5 and 3 or m < 10 and 2 or m < 20 and 1 or 0)
        end
        text = text .. '; ' .. b
      end
      parts[#parts+1] = text
    else parts[#parts+1] = 'no electric network' end
    for i, v in ipairs(key) do key[i] = tostring(v) end
    return table.concat(parts, '; '), table.concat(key, '|')
  end

  -- One step of a force's job; true when it finished.
  local function step(job)
    local f = game.forces[job.force]
    if not f then return true end
    if job.step == 'labs' then
      -- Each surface's labs: a band a step (walk.lua), then SLICE of them a step.
      local name = job.surfaces[job.si]
      local surface = name and game.get_surface(name)
      local row = name and job.labs[name]
      if surface and not row then row = {n=0, working=0, lack={}}; job.labs[name] = row end
      if surface and job.list then
        local last = math.min(#job.list, job.at + SLICE - 1)
        for i = job.at, last do
          local e = job.list[i]
          if e.valid and row.n < MAX_LABS then
            row.n = row.n + 1
            if api.status_name(e) == 'working' then row.working = row.working + 1 end
            local inv = try(function() return e.get_inventory(defines.inventory.lab_input) end)
            for _, pack in ipairs(job.packs) do
              if (inv and try(function() return inv.get_item_count(pack) end) or 0) == 0 then row.lack[pack] = (row.lack[pack] or 0) + 1 end
            end
          end
        end
        job.at = last + 1
        if job.at > #job.list then job.list = nil end
        return
      end
      if surface then job.walk = job.walk or walk.start(surface) end
      local list = surface and walk.band(job.walk, surface, {type='lab', force=f})
      if list then job.list, job.at = list, 1; return end
      job.si, job.walk = job.si + 1, nil
      if job.si > #job.surfaces then
        for _, s in ipairs(job.surfaces) do
          local row = job.labs[s]
          if row and row.n > 0 and (not job.surface or row.n > job.labs[job.surface].n) then job.surface = s end
        end
        job.surface = job.surface or (job.labs.nauvis and 'nauvis') or job.surfaces[1]
        -- The crafters for every research: the idle-colour check (science_idle) reads each pack's makers.
        job.step = #job.packs > 0 and 'crafters' or 'finish'
      end
    elseif job.step == 'crafters' then
      -- The crafters and miners, every type in one find, a band a step.
      local surface = game.get_surface(job.surface)
      job.miners = job.miners or {}
      local list
      if surface and (#job.crafters < MAX_CRAFTERS or #job.miners < MAX_CRAFTERS) then
        job.walk = job.walk or walk.start(surface)
        list = walk.band(job.walk, surface, {type=CRAFTERS, force=f})
      end
      for _, e in ipairs(list or {}) do
        local into = IS_MINER[e.type] and job.miners or job.crafters
        if #into < MAX_CRAFTERS then into[#into+1] = e end
      end
      if not list then job.walk, job.step = nil, 'index' end
    elseif job.step == 'index' then
      local recipe_of = api.supply.helpers.recipe_of
      local last = math.min(job.idx + INDEX_SLICE - 1, #job.crafters)
      for i = job.idx, last do
        local e = job.crafters[i]
        local recipe = e.valid and recipe_of(e)
        for _, prod in ipairs(recipe and recipe.products or {}) do
          local list = job.by_product[prod.name] or {}
          job.by_product[prod.name] = list
          list[#list+1] = {e=e, recipe=recipe.name}   -- a name in storage; the prototype when the chain is built
        end
      end
      job.idx = last + 1
      if job.idx > #job.crafters then job.step = 'finish' end
    else
      local text, key = compose(job, f)
      local s = store()
      s[job.force] = {tick=game.tick, text=text, key=key}
      -- The labs' state for the research-stalled alert (research.lua): which packs how many labs hold none of.
      local lab = job.labs[job.surface] or {n=0, working=0, lack={}}
      local st = api.state()
      st.science_labs = st.science_labs or {}
      st.science_labs[job.force] = {tick=game.tick, surface=job.surface, n=lab.n, working=lab.working, lack=lab.lack, tech=job.tech}
      return true
    end
  end

  -- The harness tick: advance each running job by one step.
  function M.tick(tick)
    local s = api.state()
    local jobs = s.science_jobs
    if not jobs then return end
    for name, job in pairs(jobs) do
      -- A job an older runtime left (no start, every or n: deployed over it mid-job) fails here and is dropped like a
      -- failing step; outside the pcall it raised every tick and the job, and the line, never ended.
      local ok, done = pcall(walk.due, job, tick, PUSH_TICKS)
      if ok and done then
        job.n = job.n + 1
        ok, done = pcall(step, job)
        if ok and done then s.science_steps = s.science_steps or {}; s.science_steps[name] = job.n end
      end
      if not ok then
        s.science_line_errors = {count=((s.science_line_errors or {}).count or 0) + 1, last=tostring(done), tick=tick, step=job.step}
        store()[name] = store()[name] or {}
        store()[name].tick = tick   -- tried: the next try after PUSH_TICKS
      end
      if not ok or done then jobs[name] = nil end
    end
    if not next(jobs) then s.science_jobs = nil end
  end

  -- The line for agent p (team block), or nil: at most every PUSH_TICKS and
  -- only when its facts changed. A line older than PUSH_TICKS starts a job.
  function M.lines(p, h)
    local f = p.force
    local s = api.state()
    local c = store()[f.name]
    if (not c or game.tick - c.tick >= PUSH_TICKS) and not (s.science_jobs and s.science_jobs[f.name]) then
      s.science_jobs = s.science_jobs or {}
      s.science_jobs[f.name] = start(f)
    end
    if not (c and c.text) then return nil end
    local told = h.science
    if told and (game.tick - told.tick < PUSH_TICKS or told.key == c.key) then return nil end
    h.science = {tick=game.tick, key=c.key}
    return c.text
  end
  return M
end
