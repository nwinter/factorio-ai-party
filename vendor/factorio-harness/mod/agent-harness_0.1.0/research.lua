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
  local snapshot  -- the researched set per force (shift section below)

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
    local lines, extra, force = {}, 0, p.force and p.force.name
    -- A stalled queue head (stall_check), first: each alert once per agent; a first reply looks back ten minutes.
    local al = api.state().research_alerts
    if al then
      local seen = h.research_alert
      h.research_alert = al.seq
      for _, e in ipairs(al.list) do
        if e.force == force and (seen and e.seq > seen or not seen and game.tick - e.tick <= FIRST_LOOK) then
          lines[#lines+1] = e.text
        end
      end
    end
    local news = api.state().research_news
    if not news then return #lines > 0 and lines or nil end
    local from = h.research
    h.research = news.seq
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
    if not s.research_snaps then snapshot(s, game.tick) end  -- a base from the runtime's first sample
    s.research_rate = s.research_rate or {}
    for _, force in pairs(game.forces or {}) do
      local t = force.current_research
      poll(s, force, t)
      if force.research_queue and (#force.research_queue > 0 or t) then M.stall_check(s, force) end
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
  -- What a force has researched, read from force.technologies (no event needed).
  local function researched(force)
    local set = {}
    for name, t in pairs(force.technologies or {}) do if t.researched then set[name] = true end end
    return set
  end
  -- Snapshots of the researched set at each shift start (and on first use),
  -- per force, so "finished since your last shift" needs no research events.
  local MAX_SNAPS = 6
  snapshot = function(s, tick)
    s.research_snaps = s.research_snaps or {}
    for _, force in pairs(game.forces or {}) do
      if force.technologies then
        local list = s.research_snaps[force.name] or {}
        s.research_snaps[force.name] = list
        list[#list+1] = {tick=tick, set=researched(force)}
        while #list > MAX_SNAPS do table.remove(list, 1) end
      end
    end
  end
  -- n: the shift's number in the world, as tools/start-team.sh counts it from the resumed-from chain (the stream hosts'
  -- count); without it, one more than this save's last. seq numbers the starts for the once-per-shift check.
  function M.shift_start(n)
    local s = api.state()
    local old = s.shift
    n = tonumber(n)
    if not (n and n >= 1 and n == math.floor(n)) then n = (old and (old.number or old.seq) or 0) + 1 end
    s.shift = {seq=(old and old.seq or 0) + 1, number=n, tick=game.tick, prev_tick=old and old.tick}
    snapshot(s, game.tick)
    return s.shift
  end
  -- Technologies finished after tick `since`: the research news (exact, with
  -- ticks) and the difference from the newest snapshot at or before `since`
  -- (what the news missed: events before control.lua forwarded them, or a
  -- runtime that was not running).
  local function finished_since(s, force, since)
    local names, listed = {}, {}
    local told = {}
    for _, e in ipairs(s.research_news and s.research_news.list or {}) do
      if e.force == force.name then
        if e.tick > since then
          if not listed[e.name] then names[#names+1] = e.name; listed[e.name] = true end
        else told[e.name] = true end
      end
    end
    local base
    for _, snap in ipairs(s.research_snaps and s.research_snaps[force.name] or {}) do
      if snap.tick <= since then base = snap end
    end
    if base then
      local extra = {}
      for name in pairs(researched(force)) do
        if not base.set[name] and not listed[name] and not told[name] then extra[#extra+1] = name end
      end
      table.sort(extra)
      for _, name in ipairs(extra) do names[#names+1] = name end
    end
    return names
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
    local names = finished_since(s, p.force, since)
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
    out.shift = string.format('shift %d, started %s ago', shift.number or shift.seq, ago(game.tick - shift.tick))
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
  -- Whether technology `name` needs `target` somewhere among its prerequisites.
  local function requires(force, name, target)
    local seen, todo = {}, {name}
    while #todo > 0 do
      local t = force.technologies[table.remove(todo)]
      for pre_name, pre in pairs(t and t.prerequisites or {}) do
        local n = type(pre_name) == 'string' and pre_name or pre.name
        if n == target then return true end
        if not seen[n] then seen[n] = true; todo[#todo+1] = n end
      end
    end
    return false
  end
  local function position(list, name)
    for i, n in ipairs(list) do if n == name then return i end end
    return nil
  end
  -- research {remove}: the queue without these names and, as the research GUI
  -- does, without queued technologies that need one of them (shift 5, 07:01:
  -- Grok's "cancel" was an unknown argument while mining-productivity-3 waited
  -- on production packs nobody made). Progress stays with the technology.
  function M.without(force, list, drop)
    local names = type(drop) == 'table' and drop or {drop}
    assert(#names >= 1 and #names <= 64, 'remove takes a technology name or an array of 1..64 names')
    local gone = {}
    for _, n in ipairs(names) do
      assert(type(n) == 'string', 'remove takes technology names')
      assert(position(list, n), n .. ' is not in the research queue (research with no arguments lists it)')
      gone[n] = true
    end
    local keep, also = {}, {}
    for _, n in ipairs(list) do
      if not gone[n] then
        local needs = false
        for g in pairs(gone) do if requires(force, n, g) then needs = true; break end end
        if needs then also[#also+1] = n else keep[#keep+1] = n end
      end
    end
    return keep, {removed=names, also=#also > 0 and also or nil}
  end
  -- research {move, to}: the queue with `name` at position `to`, as dragging it
  -- in the research GUI; never ahead of what it needs or behind what needs it.
  function M.moved(force, list, name, to)
    assert(type(name) == 'string', 'move takes a technology name')
    local at = position(list, name)
    assert(at, name .. ' is not in the research queue (research with no arguments lists it)')
    assert(type(to) == 'number' and to == math.floor(to) and to >= 1 and to <= #list, 'to must be 1..' .. #list .. ' (the queue length)')
    table.remove(list, at)
    table.insert(list, to, name)
    for i, n in ipairs(list) do
      if i < to and requires(force, n, name) then
        error(string.format('%s needs %s: move it to %d or earlier, or move %s too', n, name, i, n), 0)
      elseif i > to and requires(force, name, n) then
        error(string.format('%s needs %s first: move it behind %s (to %d or later), or move %s too', name, n, n, i, n), 0)
      end
    end
    return list
  end

  -- research_options: the open technologies (prerequisites done, not a trigger
  -- technology) grouped by whether the factory made every pack they need in the
  -- last 10 minutes (the science study: "researchable with what we make" took
  -- many calls, and 10 red/green/blue technologies were never queued).
  function M.options(force, a)
    local queued, open, wanted = {}, {}, {}
    for i, t in ipairs(force.research_queue or {}) do queued[t.name] = i end
    for _, t in pairs(force.technologies or {}) do
      local trigger = false
      pcall(function() trigger = t.prototype.research_trigger ~= nil end)
      if t.enabled and not t.researched and not trigger then
        local ready = true
        for _, pre in pairs(t.prerequisites or {}) do if not pre.researched then ready = false; break end end
        if ready then
          open[#open+1] = t
          for _, ing in ipairs(t.research_unit_ingredients or {}) do wanted[ing.name] = true end
        end
      end
    end
    local packs = {}
    for n in pairs(wanted) do packs[#packs+1] = n end
    table.sort(packs)
    local made = packs_made(force, packs)
    local now_list, by_missing = {}, {}
    for _, t in ipairs(open) do
      local need, lack = {}, {}
      for _, ing in ipairs(t.research_unit_ingredients or {}) do
        need[#need+1] = ing.name
        if (made[ing.name] or 0) <= 0 then lack[#lack+1] = ing.name end
      end
      local e = {name=t.name, units=t.research_unit_count, packs=table.concat(need, '+'), queued=queued[t.name]}
      if #lack == 0 then now_list[#now_list+1] = e
      else
        local key = table.concat(lack, '+')
        by_missing[key] = by_missing[key] or {}
        table.insert(by_missing[key], e)
      end
    end
    local function order(x, y) return (x.units or 0) < (y.units or 0) or (x.units or 0) == (y.units or 0) and x.name < y.name end
    table.sort(now_list, order)
    local missing = {}
    for key, list in pairs(by_missing) do
      table.sort(list, order)
      missing[#missing+1] = {packs_not_made=key, count=#list, technologies=list}
    end
    table.sort(missing, function(x, y) return x.count > y.count or x.count == y.count and x.packs_not_made < y.packs_not_made end)
    local made_out = {}
    for _, n in ipairs(packs) do made_out[n] = math.floor(made[n] or 0) end
    return {researchable_now=now_list, waiting_for_packs=missing, made_last_10_min=made_out,
      note='researchable_now: every pack made in the last 10 minutes (labs or chests may also hold some); queued gives the queue position'}
  end

  -- A stalled queue head, said to every agent in its team research lines: the
  -- technology at the head has waited STALL_TICKS on a pack nobody made in the
  -- last 10 minutes, with no progress; once per STALL_REPEAT per force (shift
  -- 4-5: status said "waits for production-science-pack" 66 times in 108 minutes,
  -- in a field nobody read).
  local STALL_TICKS, STALL_REPEAT, MAX_ALERTS = 36000, 108000, 20
  function M.stall_check(s, force)
    s.research_stall = s.research_stall or {}
    local st = s.research_stall[force.name]
    local head = (force.research_queue or {})[1] or force.current_research
    local lack = {}
    if head then
      local names = {}
      for _, ing in ipairs(head.research_unit_ingredients or {}) do names[#names+1] = ing.name end
      local made = packs_made(force, names)
      for _, n in ipairs(names) do if (made[n] or 0) <= 0 then lack[#lack+1] = n end end
    end
    local progress = head and force.current_research and force.current_research.name == head.name and force.research_progress or 0
    if #lack == 0 then
      if st then s.research_stall[force.name] = {last=st.last} end
      return nil
    end
    if not (st and st.name == head.name) or progress > (st.progress or 0) + 0.0005 then
      s.research_stall[force.name] = {name=head.name, since=game.tick, progress=progress, last=st and st.last}
      return nil
    end
    if game.tick - st.since < STALL_TICKS or (st.last and game.tick - st.last < STALL_REPEAT) then return nil end
    st.last = game.tick
    s.research_alerts = s.research_alerts or {seq=0, list={}}
    local al = s.research_alerts
    al.seq = al.seq + 1
    local text = string.format('research stalled: %s heads the queue and has waited %s for %s, which nobody made in the last 10 minutes, with no progress; the labs idle on it. research {remove=%q} or {move=%q, to=N} reorders; research_options lists what the factory can research now',
      head.name, ago(game.tick - st.since), table.concat(lack, ', '), head.name, head.name)
    al.list[#al.list+1] = {seq=al.seq, tick=game.tick, force=force.name, name=head.name, text=text}
    while #al.list > MAX_ALERTS do table.remove(al.list, 1) end
    return text
  end

  M.schema = {
    research_done = {limit='1..50 (default 10)', returns='done: technologies your force finished lately, newest first: name, ago, unlocks, queued_by'},
    research_options = {returns='researchable_now: open technologies (prerequisites done, not trigger technologies) whose every pack the factory made in the last 10 minutes {name, units, packs, queued (queue position)}, fewest units first; waiting_for_packs: the rest grouped by packs_not_made {packs_not_made, count, technologies}; made_last_10_min per pack. Read only'},
  }
  return M
end
