-- Research news and the research queue in full. A finished technology is
-- kept (name, what it unlocks) and goes to each agent once, in its reply's
-- `team` block, and to the board events; who queued each technology is kept
-- (the harness's research actions, and the game's on_research_queued for
-- players); the queue view gives each entry's progress and time to finish at
-- the lab throughput measured over the last few minutes.
return function(api)
  local M = {}
  local MAX_DONE, FIRST_LOOK, MAX_LINES, MAX_UNLOCKS = 50, 36000, 4, 8
  local SAMPLE_TICKS, MAX_SAMPLES, MAX_BY = 600, 31, 200

  local function store()
    local s = api.state()
    s.research_news = s.research_news or {seq=0, list={}}
    return s.research_news
  end
  local function ago(ticks)
    local sec = math.floor(ticks / 60)
    if sec >= 3600 then return string.format('%dh%02dm', math.floor(sec / 3600), math.floor(sec / 60) % 60) end
    if sec >= 60 then return string.format('%dm%02ds', math.floor(sec / 60), sec % 60) end
    return sec .. 's'
  end
  local function name_of(v)
    if type(v) == 'table' then return v.name end
    return v
  end
  local function signed(v)
    if v ~= math.floor(v) and math.abs(v) < 10 then return string.format('%+g%%', math.floor(v * 1000 + 0.5) / 10) end
    return string.format('%+g', v)
  end
  -- What a technology gives, in prototype names (what tools accept).
  function M.unlocks(t)
    local ok, effects = pcall(function() return t.prototype.effects end)
    local out = {}
    for _, e in ipairs(ok and effects or {}) do
      local kind = e.type
      if kind == 'unlock-recipe' then out[#out+1] = name_of(e.recipe)
      elseif kind == 'unlock-space-location' then out[#out+1] = 'travel to ' .. tostring(name_of(e.space_location))
      elseif kind == 'unlock-quality' then out[#out+1] = tostring(name_of(e.quality)) .. ' quality'
      elseif kind == 'give-item' then out[#out+1] = tostring(e.count or 1) .. ' ' .. tostring(name_of(e.item))
      elseif kind ~= 'nothing' and type(e.modifier) == 'number' then
        local scope = name_of(e.ammo_category) or name_of(e.turret_id)
        out[#out+1] = kind .. (scope and ' (' .. tostring(scope) .. ')' or '') .. ' ' .. signed(e.modifier)
      elseif kind ~= 'nothing' and e.modifier ~= nil then out[#out+1] = kind
      end
    end
    return out
  end

  -- on_research_finished. by_script covers the harness's own unlocks too.
  function M.on_finished(event)
    local t = event.research
    if not (t and t.valid) then return end
    local news = store()
    news.seq = news.seq + 1
    local unlocks = M.unlocks(t)
    local entry = {seq=news.seq, tick=event.tick or game.tick, force=t.force.name, name=t.name, unlocks=unlocks,
      by_script=event.by_script or nil, polled=event.polled or nil}
    local by = M.queued_by(t.force.name, t.name)
    entry.queued_by = by and by.by
    news.list[#news.list+1] = entry
    while #news.list > MAX_DONE do table.remove(news.list, 1) end
    local by_force = api.state().research_by and api.state().research_by[t.force.name]
    if by_force then by_force[t.name] = nil end
    if api.board_event then
      local shown = {}
      for i = 1, math.min(#unlocks, MAX_UNLOCKS) do shown[i] = unlocks[i] end
      api.board_event('research', {kind='research', title=t.name, status='done'}, 'done',
        #shown > 0 and 'unlocks: ' .. table.concat(shown, ', ') .. (#unlocks > #shown and ', +' .. (#unlocks - #shown) .. ' more' or '') or nil)
    end
  end

  -- Who queued what: the acting agent for the harness's research actions, the
  -- player for the game's own queueing. The first to queue a technology keeps it.
  function M.record(force_name, names, by)
    local s = api.state()
    s.research_by = s.research_by or {}
    local mine = s.research_by[force_name] or {}
    s.research_by[force_name] = mine
    local count = 0
    for _ in pairs(mine) do count = count + 1 end
    for _, name in ipairs(names) do
      if not mine[name] and count < MAX_BY then mine[name] = {by=by, tick=game.tick}; count = count + 1 end
    end
  end
  function M.queued_by(force_name, name)
    local mine = api.state().research_by and api.state().research_by[force_name]
    return mine and mine[name]
  end
  function M.on_queued(event)
    local t = event.research
    if not (t and t.valid and event.player_index) then return end
    local p = game.get_player(event.player_index)
    if p and p.valid then M.record(t.force.name, {t.name}, p.name) end
  end

  -- The reply's research lines for agent p: technologies its force finished
  -- since its previous reply; a first reply looks back ten minutes.
  function M.lines(p, h)
    local news = api.state().research_news
    if not news then return nil end
    local from = h.research
    h.research = news.seq
    local lines, extra, force = {}, 0, p.force and p.force.name
    for _, e in ipairs(news.list) do
      if e.force == force and (from and e.seq > from or not from and game.tick - e.tick <= FIRST_LOOK) then
        if #lines < MAX_LINES then
          local shown = {}
          for i = 1, math.min(#e.unlocks, MAX_UNLOCKS) do shown[i] = e.unlocks[i] end
          local more = #e.unlocks > #shown and ', +' .. (#e.unlocks - #shown) .. ' more' or ''
          lines[#lines+1] = string.format('research done: %s%s (%s ago)', e.name,
            #shown > 0 and ', unlocks: ' .. table.concat(shown, ', ') .. more or '', ago(game.tick - e.tick))
        else extra = extra + 1 end
      end
    end
    if extra > 0 then lines[#lines+1] = string.format('+%d more finished: research_done', extra) end
    return #lines > 0 and lines or nil
  end
  -- research_done: what finished lately, newest first.
  function M.done(p, a)
    local limit = a.limit or 10
    assert(type(limit) == 'number' and limit >= 1 and limit <= MAX_DONE, 'limit must be 1..' .. MAX_DONE)
    local news, out = store(), {}
    for k = #news.list, 1, -1 do
      local e = news.list[k]
      if e.force == p.force.name then
        out[#out+1] = {name=e.name, ago=ago(game.tick - e.tick), tick=e.tick, unlocks=e.unlocks, queued_by=e.queued_by}
        if #out >= limit then break end
      end
    end
    return {done=out}
  end

  -- Lab throughput samples per force: the current research and its progress,
  -- every 10 s. Throughput is research work (units x unit energy) per tick,
  -- summed over consecutive samples of the same technology.
  -- Whether `name` finishing was already announced at or after tick `since`.
  local function announced(force_name, name, since)
    local news = api.state().research_news
    for k = #(news and news.list or {}), 1, -1 do
      local e = news.list[k]
      if e.tick < since then return false end
      if e.force == force_name and e.name == name then return true end
    end
    return false
  end
  -- The research at the head of the queue, as last sampled: when it leaves
  -- researched (or one level up, for a levelled one) and no event announced it,
  -- it is announced here. A runtime deployed without a server restart has no
  -- on_research_finished (control.lua forwards it from the next restart on);
  -- this covers it, up to 10 s late.
  local function poll(s, force, t)
    s.research_head = s.research_head or {}
    local head = s.research_head[force.name]
    local level = t and t.level or 0
    if head and (not t or t.name ~= head.name or level ~= head.level) then
      local was = force.technologies and force.technologies[head.name]
      if was and (was.researched or (was.level or 0) > head.level) and not announced(force.name, head.name, head.since) then
        M.on_finished{research=was, tick=game.tick, polled=true}
      end
    end
    if not t then s.research_head[force.name] = nil
    elseif not (head and head.name == t.name and head.level == level) then
      s.research_head[force.name] = {name=t.name, level=level, since=game.tick}
    end
  end
  function M.sample()
    local s = api.state()
    s.research_rate = s.research_rate or {}
    for _, force in pairs(game.forces or {}) do
      local t = force.current_research
      poll(s, force, t)
      local list = s.research_rate[force.name]
      if t or list then
        list = list or {}
        s.research_rate[force.name] = list
        list[#list+1] = {tick=game.tick, name=t and t.name, progress=t and force.research_progress or 0,
          work=t and (t.research_unit_count or 0) * (t.research_unit_energy or 0) or 0}
        while #list > MAX_SAMPLES do table.remove(list, 1) end
      end
    end
  end
  -- Faults are counted (research_errors), never quarantine the runtime.
  function M.tick(tick)
    if tick % SAMPLE_TICKS ~= 0 then return end
    local ok, err = pcall(M.sample)
    if not ok then
      local s = api.state()
      s.research_errors = {count=((s.research_errors or {}).count or 0) + 1, last=tostring(err), tick=game.tick}
    end
  end

  -- Shifts (operator shift_start, at a resumed world's start). An agent's
  -- first reply of a shift carries a shift block once: the team plan's goals
  -- and its own line, what finished since its last request before the shift,
  -- and researched technologies with none of their buildings (unlocks.lua).
  function M.shift_start()
    local s = api.state()
    local old = s.shift
    s.shift = {seq=(old and old.seq or 0) + 1, tick=game.tick, prev_tick=old and old.tick}
    return s.shift
  end
  local UNLOCKS = require('unlocks')
  -- Labels of buildings a researched technology unlocks and the force has
  -- none of on any surface: {label, techs}, in the table's order.
  function M.not_built(force)
    local out, by_label, counts = {}, {}, {}
    local function count(name)
      if counts[name] == nil then
        local ok, exists = pcall(function() return prototypes.entity[name] ~= nil end)
        local n = 0
        if ok and exists then
          for _, surface in pairs(game.surfaces or {}) do
            n = n + surface.count_entities_filtered{force=force, name=name, limit=1}
            if n > 0 then break end
          end
        else n = false end
        counts[name] = n
      end
      return counts[name]
    end
    for _, row in ipairs(UNLOCKS) do
      local tech, buildings, label = row[1], row[2], row[3]
      local t = force.technologies and force.technologies[tech]
      if t and t.researched then
        local none, known = true, true
        for _, b in ipairs(buildings) do
          local n = count(b)
          if n == false then known = false elseif n > 0 then none = false end
        end
        if none and known then
          if not by_label[label] then by_label[label] = {label=label, techs={}}; out[#out+1] = by_label[label] end
          table.insert(by_label[label].techs, tech)
        end
      end
    end
    return out
  end
  -- The shift block for agent p, once per shift; last_call is the tick of its
  -- previous request (before this one), nil for an agent new to the world.
  function M.shift_block(p, last_call, plan)
    local s = api.state()
    local shift = s.shift
    if not shift then return nil end
    s.shift_seen = s.shift_seen or {}
    if s.shift_seen[p.index] == shift.seq then return nil end
    s.shift_seen[p.index] = shift.seq
    local out = {}
    if plan and plan.goals then out.plan_goals = plan.goals end
    if plan and plan.mine then out.your_plan_line = plan.mine end
    local since = last_call or shift.prev_tick or 0
    local names = {}
    for _, e in ipairs(s.research_news and s.research_news.list or {}) do
      if e.force == p.force.name and e.tick > since then names[#names+1] = e.name end
    end
    if #names > 0 then
      local shown = {}
      for i = math.max(1, #names - 11), #names do shown[#shown+1] = names[i] end
      out.research_since_your_last_shift = table.concat(shown, ', ') .. (#names > #shown and string.format(' (+%d earlier: research_done)', #names - #shown) or '')
    end
    local idle = M.not_built(p.force)
    if #idle > 0 then
      local parts = {}
      for _, x in ipairs(idle) do parts[#parts+1] = x.label .. ' (' .. table.concat(x.techs, ', ') .. ')' end
      out.researched_none_built = table.concat(parts, '; ')
    end
    out.shift = string.format('shift %d, started %s ago', shift.seq, ago(game.tick - shift.tick))
    return out
  end
  -- Work per tick over the samples kept (about 5 minutes), or nil.
  function M.rate(force_name)
    local list = api.state().research_rate and api.state().research_rate[force_name]
    if not list then return nil end
    local work, ticks = 0, 0
    for k = 2, #list do
      local a, b = list[k - 1], list[k]
      if a.name and a.name == b.name and b.progress >= a.progress then
        work = work + (b.progress - a.progress) * b.work
        ticks = ticks + (b.tick - a.tick)
      end
    end
    if ticks < SAMPLE_TICKS * 3 then return nil end
    return work / ticks, ticks
  end

  local function minutes(ticks)
    local sec = math.ceil(ticks / 60)
    if sec >= 3600 then return string.format('%dh%02dm', math.floor(sec / 3600), math.floor(sec / 60) % 60) end
    if sec >= 60 then return string.format('%dm%02ds', math.floor(sec / 60), sec % 60) end
    return sec .. 's'
  end
  -- Science packs made in the last 10 minutes on any surface, by name.
  local function packs_made(force, names)
    local made = {}
    for _, name in ipairs(names) do
      made[name] = 0
      for _, surface in pairs(game.surfaces or {}) do
        local ok, n = pcall(function()
          return force.get_item_production_statistics(surface).get_flow_count{name=name, category='input',
            precision_index=defines.flow_precision_index.ten_minutes, count=true}
        end)
        if ok and type(n) == 'number' then made[name] = made[name] + n end
      end
    end
    return made
  end
  -- The research queue in full: each entry's progress, who queued it, the
  -- packs it needs, and when it should finish at the measured throughput.
  -- An entry that needs a pack the current research does not use and nobody
  -- made in the last 10 minutes stops the clock (labs may still hold some).
  function M.queue(force, pending)
    local rate, window = M.rate(force.name)
    local entries, at, stalled = {}, 0, nil
    local queue = force.research_queue or {}
    local current = force.current_research
    local in_use, needed = {}, {}
    if current and rate and rate > 0 then
      for _, ing in ipairs(current.research_unit_ingredients or {}) do in_use[ing.name] = true end
    end
    for _, t in ipairs(queue) do
      for _, ing in ipairs(t.research_unit_ingredients or {}) do
        if not in_use[ing.name] then needed[#needed+1] = ing.name end
      end
    end
    local made = packs_made(force, needed)
    for i, t in ipairs(queue) do
      local progress = 0
      if i == 1 and current and current.name == t.name then progress = force.research_progress or 0
      else
        local ok, saved = pcall(function() return t.saved_progress end)
        if ok and type(saved) == 'number' then progress = saved end
      end
      local packs, missing = {}, {}
      for _, ing in ipairs(t.research_unit_ingredients or {}) do
        packs[#packs+1] = ing.name
        if not in_use[ing.name] and (made[ing.name] or 0) <= 0 then missing[#missing+1] = ing.name end
      end
      local by = M.queued_by(force.name, t.name)
      local entry = {name=t.name, progress=math.floor(progress * 1000 + 0.5) / 10, queued_by=by and by.by,
        packs=table.concat(packs, '+')}
      if #missing > 0 then
        entry.waits_for = table.concat(missing, '+') .. ' (none made in 10 min)'
        stalled = stalled or t.name
      end
      if rate and rate > 0 and not stalled then
        at = at + (1 - progress) * t.research_unit_count * t.research_unit_energy / rate
        entry.done_in = minutes(at)
      end
      entries[#entries+1] = entry
    end
    local out = {entries=entries}
    if rate then out.throughput = string.format('measured over the last %s', minutes(window))
    else out.throughput = 'not measured yet (needs 30 s of research progress)' end
    if stalled then out.clock_stops_at = stalled end
    for _, name in ipairs(pending or {}) do
      local by = M.queued_by(force.name, name)
      entries[#entries+1] = {name=name, queued_by=by and by.by, waiting='beyond the engine queue'}
    end
    return out
  end
  M.schema = {
    research_done = {limit='1..50 (default 10)', returns='done: technologies your force finished lately, newest first: name, ago, unlocks, queued_by'},
  }
  return M
end
