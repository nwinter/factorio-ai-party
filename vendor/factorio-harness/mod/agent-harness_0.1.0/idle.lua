-- Idle characters, for the operator's fact-only nudge (tools/idle_nudge.py in
-- the pog repo; shift05: Sonnet's character stood most of the shift between
-- 25-minute sleeps, and its discarded replies hid the team's messages).
-- `idle_report` (operator, read only) gives each agent: how long its character
-- has stood with no action and no running queue (stand_tick keeps the `stand`
-- start; a dead character, or a bot in a cargo pod, is not standing), the
-- action it runs, its queue, its sleep, what waits unread (chat messages,
-- mentions and tells, board lines), and what was counted over the last 10
-- minutes (game actions, reads, messages; working, asleep, waiting, standing).
-- One definition of idle (agent-minds study, fix 2): busy() decides both the
-- clock line on every reply (runtime.lua idle_tick) and the standing the nudge
-- reports; the shift07 clock line counted a wait as activity, so Sonnet and
-- Haiku read "character idle 0s of it (0%)" after every wait for an hour.
return function(api)
  local M = {operator={}}
  local function queue_of(index)
    local q = api.state().queues and api.state().queues[index]
    if not q then return {state='none'} end
    local steps = #q.pending + (q.current and 1 or 0)
    if q.paused then return {state='paused', steps=steps} end
    if q.current or #q.pending > 0 or q.loop then return {state='running', steps=steps, loop=q.loop ~= nil or nil} end
    return {state='empty'}
  end
  -- Standing: nothing moves or works the character. A wait is not work
  -- (shift07: Sonnet's wait_ticks of 20000-30000 ticks back to back, 70
  -- minutes, never nudged), nor a queue held behind a direct wait (a plan
  -- runs after a direct command ends: Sonnet's loop3 moved ~10 ticks between
  -- its waits, then its next wait interrupted it). Standing ends on a game
  -- action that changed something (a transfer that moved items, a build, a
  -- craft, a feed that gave fuel: request below), a move that took the
  -- character to a new spot, or BRIEF of work summed over WINDOW (shift07:
  -- 0 of 227 short walks by Grok and Muse counted under the old rule of 20 s
  -- of work in one go, nor Gemini's 108 transfers).
  -- A standing order running is work at once, its waits included (orders.lua).
  local WAITS = {wait_ticks=true, wait_until=true, sleep=true}
  local BRIEF, WINDOW = 20 * 60, 2 * 3600
  local MOVES = {walk=true, move_to=true, build_path=true, kite=true, drive=true}
  local NEW_SPOT = 3                 -- tiles
  local BUCKET, BUCKETS = 3600, 10   -- the counts: one bucket a minute, the last 10
  M.WAITS = WAITS
  local function busy(s, index)
    local act = s.active and s.active[index]
    local waiting = act and WAITS[act.kind]
    if act and not waiting then return true end
    local q = s.queues and s.queues[index]
    if not q or q.paused or waiting then return false end
    if q.order then return true, true end  -- a standing order running (orders.lua), its waits included
    local step = q.current
    if step then return not WAITS[step.action] or q.loop ~= nil end  -- a repeating plan's own wait is the plan
    return q.loop ~= nil or #q.pending > 0
  end
  M.busy = busy
  -- The wait an idle character is in: a direct wait (and a queue held behind
  -- it), a queue's own one-off wait step, or an fh sleep; nil when it just stands.
  local function waiting(s, index)
    local act = s.active and s.active[index]
    if act and WAITS[act.kind] then return act.kind end
    local q = s.queues and s.queues[index]
    local step = q and not q.paused and q.current
    if step and WAITS[step.action] and not q.loop then return step.action end
    local sl = s.sleeps and s.sleeps[index]
    if sl and not sl.woke and (sl.until_tick or 0) > game.tick and sl.until_tick > sl.start_tick then return 'sleep' end
  end
  M.waiting = waiting
  local function bucket(s, index)
    s.idle_log = s.idle_log or {}
    local log = s.idle_log[index] or {}
    s.idle_log[index] = log
    local id = math.floor(game.tick / BUCKET)
    local b = log[id]
    if not b then
      b = {busy=0, waiting=0, asleep=0, stand=0, acts=0, noops=0, reads=0, talk=0, sleeps={}, waits={}}
      log[id] = b
      for k in pairs(log) do if k <= id - BUCKETS then log[k] = nil end end
    end
    return b
  end
  local function ended(index, why)
    local s = api.state()
    if s.stand then s.stand[index] = nil end
    s.stand_end = s.stand_end or {}
    s.stand_end[index] = {tick=game.tick, why=why}
  end
  -- Once a second (runtime.lua idle_tick), for every agent that made a request.
  function M.stand_tick()
    local s = api.state()
    s.stand, s.work, s.move_from = s.stand or {}, s.work or {}, s.move_from or {}
    s.busy = nil  -- the old rule's start of continuous work
    for index in pairs(s.clocks or {}) do
      if not api.has_body(index) then s.stand[index], s.work[index], s.move_from[index] = nil, nil, nil
      else
        local b = bucket(s, index)
        local work = s.work[index] or {}
        s.work[index] = work
        while work[1] and work[1] <= game.tick - WINDOW do table.remove(work, 1) end
        -- A move that took the character to a new spot ends standing when it ends.
        local act = s.active and s.active[index]
        local from, here = s.move_from[index], api.position and api.position(index)
        if act and MOVES[act.kind] then
          if not from then s.move_from[index] = here end
        elseif from then
          s.move_from[index] = nil
          if here and math.abs(here.x - from.x) + math.abs(here.y - from.y) >= NEW_SPOT then ended(index, 'moved') end
        end
        local working, order = busy(s, index)
        if working then
          b.busy = b.busy + 1
          work[#work+1] = game.tick
          if order then ended(index, 'order') elseif #work * 60 >= BRIEF then ended(index, 'worked') end
        else
          local w = waiting(s, index)
          if w == 'sleep' then b.asleep = b.asleep + 1 elseif w then b.waiting = b.waiting + 1 else b.stand = b.stand + 1 end
          if not s.stand[index] then s.stand[index] = game.tick end
        end
      end
    end
  end
  -- Requests that are neither game actions nor waits.
  local TALK = {say=true, chat=true, tell=true, tells=true, operator=true, confess=true, confessions=true, chronicle=true, vote=true, votes=true,
    clock=true, advance=true, requests=true, profile=true, flush=true, harness_request=true}
  M.TALK = TALK
  -- Requests that only start or stop the agent's own control: not counted.
  local CONTROL = {stop=true, attach=true, detach=true}
  -- A game action's reply that says it did nothing (shift07: Haiku's 35 feeds, "nothing_to_do, given 0").
  local function noop(r)
    if type(r) ~= 'table' then return false end
    if r.outcome == 'nothing_to_do' or r.outcome == 'already_there' then return true end
    for _, k in ipairs({'transferred', 'given', 'moved', 'placed', 'crafted', 'queued'}) do
      if r[k] == 0 then return true end
    end
    return false
  end
  -- Every request an agent makes (runtime.lua dispatch, not peeks): counted
  -- for the nudge; a game action that changed something ends standing at once
  -- (a timed one counts as work while it runs, and a move by where it ends).
  function M.request(index, action, args, result)
    if type(action) ~= 'string' or action == 'sleep_check' or CONTROL[action] then return end
    local s = api.state()
    local b = bucket(s, index)
    if action == 'sleep' then
      local n = type(result) == 'table' and result.sleeping_s
      if n and n > 0 then b.sleeps[n] = (b.sleeps[n] or 0) + 1 end
      return
    end
    if WAITS[action] then b.waits[action] = (b.waits[action] or 0) + 1; return end
    if TALK[action] or api.is_talk and api.is_talk(action) then b.talk = b.talk + 1; return end
    if api.is_read(action) or action:match('^queue_') then b.reads = b.reads + 1; return end
    if noop(result) then b.noops = b.noops + 1; return end
    b.acts = b.acts + 1
    if type(result) == 'table' and result.until_tick == nil then ended(index, action) end
  end
  local function clock(sec)
    if sec >= 60 then return string.format('%dm%02ds', math.floor(sec / 60), sec % 60) end
    return sec .. 's'
  end
  -- What was counted over the last `minutes` (whole minutes, this one included).
  function M.counted(index, minutes)
    minutes = math.min(minutes or BUCKETS, BUCKETS)
    local s = api.state()
    local log = s.idle_log and s.idle_log[index] or {}
    local id = math.floor(game.tick / BUCKET)
    local c = {minutes=minutes, busy_s=0, waiting_s=0, asleep_s=0, standing_s=0, actions=0, no_effect=0, reads=0, messages=0, sleeps={}, waits={}}
    for k, b in pairs(log) do
      if k > id - minutes then
        c.busy_s, c.waiting_s, c.asleep_s, c.standing_s = c.busy_s + b.busy, c.waiting_s + b.waiting, c.asleep_s + b.asleep, c.standing_s + b.stand
        c.actions, c.no_effect, c.reads, c.messages = c.actions + b.acts, c.no_effect + b.noops, c.reads + b.reads, c.messages + b.talk
        for n, k2 in pairs(b.sleeps) do c.sleeps[n] = (c.sleeps[n] or 0) + k2 end
        for w, k2 in pairs(b.waits) do c.waits[w] = (c.waits[w] or 0) + k2 end
      end
    end
    -- Queue steps finished in the window are game actions too.
    local q = s.queues and s.queues[index]
    local since, steps = (id - minutes + 1) * BUCKET, 0
    for i = #(q and q.history or {}), 1, -1 do
      local h = q.history[i]
      if (h.finished_tick or 0) < since then break end
      if h.ok then steps = steps + 1 end
    end
    c.queue_steps = steps
    local total = c.busy_s + c.waiting_s + c.asleep_s + c.standing_s
    local function pct(n) return total > 0 and math.floor(100 * n / total + 0.5) or 0 end
    local sl = {}
    for n, k in pairs(c.sleeps) do sl[#sl+1] = {n, k} end
    table.sort(sl, function(a, b2) return a[1] > b2[1] end)
    local sleeps = {}
    for _, e in ipairs(sl) do sleeps[#sleeps+1] = string.format('sleep %d x%d', e[1], e[2]) end
    local waits = {}
    for w, k in pairs(c.waits) do waits[#waits+1] = string.format('%s x%d', w, k) end
    table.sort(waits)
    c.text = string.format('last %d min: %d game action%s%s%s, %d read%s, %d message%s; working %d%%, asleep %d%%%s, waiting %d%%%s, standing %d%%',
      minutes, c.actions, c.actions == 1 and '' or 's', c.no_effect > 0 and string.format(' (and %d with no effect)', c.no_effect) or '',
      steps > 0 and string.format(', %d queue step%s done', steps, steps == 1 and '' or 's') or '',
      c.reads, c.reads == 1 and '' or 's', c.messages, c.messages == 1 and '' or 's',
      pct(c.busy_s), pct(c.asleep_s), #sleeps > 0 and ' (' .. table.concat(sleeps, ', ') .. ')' or '',
      pct(c.waiting_s), #waits > 0 and ' (' .. table.concat(waits, ', ') .. ')' or '', pct(c.standing_s))
    c.clock = clock(total)
    return c
  end
  function M.operator.idle_report(a)
    local s = api.state()
    local counts = {}
    for _, row in ipairs(api.mention_counts().agents or {}) do counts[row.name] = row end
    local out = {}
    for _, ag in ipairs(api.agents()) do
      local since = s.stand and s.stand[ag.index]
      local act = s.active and s.active[ag.index]
      local sl = s.sleeps and s.sleeps[ag.index]
      local sleeping = sl and sl.until_tick and sl.until_tick > game.tick
      local clock_ = s.clocks and s.clocks[ag.index]
      local unread = api.unread(ag.index) or {}
      local c = counts[ag.name] or {}
      local last_end = s.stand_end and s.stand_end[ag.index]
      local ok_open, open_line = false, nil
      if api.open then ok_open, open_line = pcall(api.open, ag.index, ag.name) end
      if not ok_open then open_line = nil end
      out[#out+1] = {name=ag.name, display_name=ag.display_name,
        standing_s=since and math.floor((game.tick - since) / 60) or 0,
        alive=api.has_body(ag.index),
        action=act and act.kind or nil, action_until_s=act and act.until_tick and math.floor((act.until_tick - game.tick) / 60) or nil,
        queue=queue_of(ag.index),
        sleeping_s=sleeping and math.floor((game.tick - sl.start_tick) / 60) or nil,
        sleep_left_s=sleeping and math.floor((sl.until_tick - game.tick) / 60) or nil,
        unread_chat=unread.unread or 0, unread_mentions=c.unread_mentions or 0, unread_tells=c.tells or 0,
        unread_board=c.unread_board or 0,
        last_request_s=clock_ and math.floor((game.tick - math.max(clock_.call_tick, clock_.seen_tick or 0)) / 60) or nil,
        -- Standing orders (orders.lua): {set, running, reason, paused}; a running order is a running queue, so not standing.
        orders=api.orders and api.orders(ag.index) or nil,
        counted=M.counted(ag.index, (a or {}).minutes),
        -- What is open for it (open.lua; d15 H3): the idle nudge quotes it.
        open=open_line,
        stand_ended=last_end and {s_ago=math.floor((game.tick - last_end.tick) / 60), why=last_end.why} or nil}
    end
    return {agents=out, tick=game.tick, idle='standing: no action and no running queue; a wait or sleep is standing; '
      .. 'a game action that changed something, a move to a new spot or 20 s of work in 2 minutes ends it'}
  end
  return M
end
