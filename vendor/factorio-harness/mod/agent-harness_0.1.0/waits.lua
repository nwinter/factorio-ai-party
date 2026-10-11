-- Waiting without polling: wait_ticks as a direct timed action, and sleep,
-- which waits while the game runs and says why it woke (damage, death, a
-- message mentioning the agent, a tell, board news, the agent's own queue
-- finishing or stalling, an optional wait condition, or time up). Nothing
-- here runs per tick: sleep is checked when the CLI asks (sleep_check).
return function(api)
  local M = {handlers={}}
  local MAX_TICKS = 54000 -- 15 minutes
  -- A queue step that walks the character and has not moved it for this long
  -- has stalled (shake4: Muse's move job stuck pathfinding through a sleep).
  local STILL_TICKS = 1800
  local MOVING = {walk=true, move_to=true, build_path=true, kite=true, collect=true, feed=true, rearm=true, refuel=true}
  M.schema = {
    wait_ticks = {ticks='1..54000 simulation ticks: the character stands idle that long (a direct timed action, outcome duration_elapsed; use --wait), or a queue step'},
    sleep = {seconds='1..900', condition='optional wait_until condition {until=researched|item_count|crafting_done|..., ...}: the sleep also ends when it holds (woke=condition, saw); researched without technology means the research running now; item_count may take positions (chests)',
      note='fh sleep SECONDS [--until ...]: waits while the game runs (in turns mode it advances the game); your current action and queue keep going, and the reply says first which (while_asleep). Returns early when your character takes damage or dies, a message mentions you, a teammate tells you something (tell), a board item of yours is assigned or changed by someone else, your running queue finishes or stalls (a step fails, or a walking step has not moved you for 30 s), or the condition holds; a dead bot sleeps until it respawns. sleep_check reports woke=damaged|died|respawned|mentioned|told|board|queue_done|queue_stalled|condition|elapsed'},
    sleep_check = {peek='boolean: leave mentions unread (the CLI polls with peek, then reads once)', returns='woke (nil while sleeping), slept_s, health/lost when damaged, mention, tell, board, queue (what finished or stalled), saw (the condition), queue_steps (steps your queue finished during the sleep)'},
  }
  local function sleeps()
    local s = api.state()
    s.sleeps = s.sleeps or {}
    return s.sleeps
  end
  local function queue_of(index)
    local qs = api.state().queues
    return qs and qs[index]
  end
  local function running(q)
    return q ~= nil and not q.paused and (q.current ~= nil or #q.pending > 0 or q.loop ~= nil)
  end
  function M.handlers.wait_ticks(p, a)
    local ticks = api.integer(a.ticks, nil, 1, MAX_TICKS, 'ticks (1..54000)')
    api.replace(p)
    local until_tick = game.tick + ticks
    api.state().active[p.index] = {kind='wait_ticks', until_tick=until_tick}
    return {until_tick=until_tick}
  end
  -- What keeps going while the agent sleeps, in one line (the reply's first).
  local function asleep_line(p, record, seconds)
    if record.dead_until then return 'dead: you respawn at tick ' .. record.dead_until end
    local q = queue_of(p.index)
    if running(q) then
      local now = q.current and q.current.action .. ' running, ' or ''
      return string.format('your queue keeps running (%s%d steps pending%s); this sleep ends when it finishes or stalls',
        now, #q.pending, q.loop and ', repeating' or '')
    end
    local active = api.state().active[p.index]
    local held = q and q.paused and #q.pending > 0 and string.format(' (your queue is paused with %d steps pending)', #q.pending) or ''
    if active and active.until_tick then
      return string.format('your %s keeps going until tick %d, then your character stands idle%s', active.kind or 'action', active.until_tick, held)
    elseif active then
      return string.format('your %s keeps going, then your character stands idle%s', active.kind or 'action', held)
    end
    return string.format('no queue and no action: your character stands idle for up to %d s%s', seconds, held)
  end
  function M.handlers.sleep(p, a)
    local seconds = api.integer(a.seconds, nil, 1, MAX_TICKS / 60, 'seconds (1..900)')
    local condition
    if a.condition ~= nil then
      assert(type(a.condition) == 'table', 'condition is a wait_until condition: {until=..., ...}')
      condition = {}
      for k, v in pairs(a.condition) do condition[k] = v end
      if condition['until'] == 'researched' and condition.technology == nil then
        local research = p.force.current_research
        assert(research, 'no research is running; name the technology')
        condition.technology = research.name
      end
      api.validate_condition(condition)
    end
    local c = p.character
    local record = {start_tick=game.tick, until_tick=game.tick + seconds * 60, health=c and c.valid and c.health or nil, condition=condition}
    -- A dead bot sleeps until it respawns (or a mention, or time up).
    record.dead_until = api.dead_until and api.dead_until(p.index) or nil
    record.board_seq = api.board_seq and api.board_seq() or nil
    local q = queue_of(p.index)
    if running(q) then record.queue = true end
    local out = {}
    out.while_asleep = asleep_line(p, record, seconds)
    out.sleeping_s = seconds
    out.until_tick = record.until_tick
    if condition then
      local ok, met, saw = pcall(api.condition, p, condition)
      assert(ok, met)
      out.condition = condition['until'] .. (condition.technology and ' ' .. condition.technology or condition.item and ' ' .. condition.item or '')
      out.saw = saw
      -- Met already: the first check ends the sleep.
      if met then
        record.woke = 'condition'; out.already_met = true
        record.out = {slept_s=0, until_tick=record.until_tick, woke='condition', saw=saw}
      end
    end
    sleeps()[p.index] = record
    -- In turns mode time only runs when asked to.
    if api.clock_mode() == 'turns' and not record.woke then api.advance(p, math.min(seconds * 60, 36000)) end
    if record.dead_until then
      out.dead = true; out.respawns_at_tick = record.dead_until
      out.wakes_on = 'respawn, a message mentioning you, a tell, a board item of yours'
    else
      out.wakes_on = 'damage, death, a message mentioning you, a tell, a board item of yours' ..
        (record.queue and ', your queue finishing or stalling' or '') .. (condition and ', the condition' or '')
    end
    return out
  end
  -- The newest failed step of the queue since the sleep began, as text.
  local function failure(q, since)
    for i = #q.history, 1, -1 do
      local h = q.history[i]
      if (h.finished_tick or 0) < since then return nil end
      if not h.ok then
        local r = h.result or {}
        return string.format('%s failed: %s', h.action or 'step', tostring(r.reason or r.outcome or 'see queue_status'))
      end
    end
  end
  local function queue_why(p, record, out)
    local q = queue_of(p.index)
    if not q or q.paused then
      out.queue = q and failure(q, record.start_tick) or 'paused (see queue_status)'
      return 'queue_stalled'
    end
    if not q.current and #q.pending == 0 and not q.loop then out.queue = 'finished'; return 'queue_done' end
    local c = p.character
    local step = q.current
    if step and MOVING[step.action] and c and c.valid then
      local pos, still = c.position, record.still
      if not still or still.step ~= step.id or math.abs(pos.x - still.x) + math.abs(pos.y - still.y) > 0.5 then
        record.still = {x=pos.x, y=pos.y, tick=game.tick, step=step.id}
      elseif game.tick - still.tick >= STILL_TICKS then
        out.queue = string.format('%s has not moved your character for %d s (at %.1f,%.1f)', step.action, math.floor((game.tick - still.tick) / 60), pos.x, pos.y)
        return 'queue_stalled'
      end
    end
  end
  -- Why the sleeper should wake now, or nil. Mentions are read from the
  -- board's per-agent inbox (filed when a message arrives) without
  -- delivering them; the reply's team block delivers them as usual.
  local function why(p, record, out)
    local c = p.character
    if record.dead_until then
      if c and c.valid then return 'respawned' end
    elseif not (c and c.valid) then
      -- A bot riding a cargo pod or aboard a platform has no body and is not dead.
      if not (api.traveling and api.traveling(p.index)) then return 'died' end
    else
      -- Enemy hits are also kept per character (board.lua's alerts), so a hit
      -- healed again between two checks still counts, with its attacker.
      local hits = api.state().char_hits
      local hit = hits and c.unit_number and hits[c.unit_number]
      if hit and hit.last and hit.last >= record.start_tick then out.by = hit.by end
      if out.by or (record.health and c.health < record.health - 0.01) then
        out.health = math.floor(c.health)
        if record.health and c.health < record.health then out.lost = math.floor(record.health - c.health + 0.5) end
        return 'damaged'
      end
    end
    local box = api.state().mentions and api.state().mentions[p.index]
    for i = #(box and box.list or {}), 1, -1 do
      local m = box.list[i]
      if m.tick >= record.start_tick then
        if m.tell then
          out.tell = string.format('%s: %s', m.from, m.text)
          return 'told'
        end
        out.mention = string.format('%s: %s', m.from, m.text)
        return 'mentioned'
      end
    end
    -- A board item assigned to the sleeper or changed by someone else.
    local news = record.board_seq and api.board_news(p, record.board_seq)
    if news then out.board = news; return 'board' end
    if record.condition and c and c.valid then
      local ok, met, saw = pcall(api.condition, p, record.condition)
      if ok then out.saw = saw end
      if ok and met then return 'condition' end
    end
    if record.queue then
      local reason = queue_why(p, record, out)
      if reason then return reason end
    end
    if game.tick >= record.until_tick then return 'elapsed' end
  end
  function M.handlers.sleep_check(p, a)
    local record = sleeps()[p.index]
    assert(record, 'no sleep started; call sleep {seconds} first (fh sleep SECONDS)')
    local out = {slept_s=math.floor((game.tick - record.start_tick) / 60), until_tick=record.until_tick}
    out.woke = record.woke or why(p, record, out)
    if out.woke and record.queue then
      local q = queue_of(p.index)
      local n = 0
      for i = #(q and q.history or {}), 1, -1 do
        if (q.history[i].finished_tick or 0) < record.start_tick then break end
        if q.history[i].ok then n = n + 1 end
      end
      out.queue_steps = n
    end
    -- The first reason sticks, so the final (non-peek) read repeats it.
    if out.woke then record.woke = out.woke; record.out = record.out or out end
    return record.out or out
  end
  return M
end
