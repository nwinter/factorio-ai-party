-- Idle characters, for the operator's fact-only nudge (tools/idle_nudge.py in
-- the pog repo; shift05: Sonnet's character stood most of the shift between
-- 25-minute sleeps, and its discarded replies hid the team's messages).
-- `idle_report` (operator, read only) gives each agent: how long its character
-- has stood with no action and no running queue (runtime.lua idle_tick keeps
-- the `stand` start; a dead character, or a bot in a cargo pod, is not
-- standing), the action it runs, its queue, its sleep, and what waits unread:
-- chat messages, mentions and tells, board lines.
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
  -- its waits, then its next wait interrupted it). Work shorter than BRIEF
  -- does not end standing. A standing order running is work at once, its
  -- waits included (orders.lua).
  local WAITS = {wait_ticks=true, wait_until=true, sleep=true}
  local BRIEF = 20 * 60
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
  -- Once a second (runtime.lua idle_tick), for every agent that made a request.
  function M.stand_tick()
    local s = api.state()
    s.stand, s.busy = s.stand or {}, s.busy or {}
    for index in pairs(s.clocks or {}) do
      local working, order = busy(s, index)
      if not api.has_body(index) then s.stand[index], s.busy[index] = nil, nil
      elseif working then
        s.busy[index] = s.busy[index] or game.tick
        if order or game.tick - s.busy[index] >= BRIEF then s.stand[index] = nil end
      else
        s.busy[index] = nil
        if not s.stand[index] then s.stand[index] = game.tick end
      end
    end
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
      local clock = s.clocks and s.clocks[ag.index]
      local unread = api.unread(ag.index) or {}
      local c = counts[ag.name] or {}
      out[#out+1] = {name=ag.name, display_name=ag.display_name,
        standing_s=since and math.floor((game.tick - since) / 60) or 0,
        alive=api.has_body(ag.index),
        action=act and act.kind or nil, action_until_s=act and act.until_tick and math.floor((act.until_tick - game.tick) / 60) or nil,
        queue=queue_of(ag.index),
        sleeping_s=sleeping and math.floor((game.tick - sl.start_tick) / 60) or nil,
        sleep_left_s=sleeping and math.floor((sl.until_tick - game.tick) / 60) or nil,
        unread_chat=unread.unread or 0, unread_mentions=c.unread_mentions or 0, unread_tells=c.tells or 0,
        unread_board=c.unread_board or 0,
        -- Standing orders (orders.lua): {set, running, reason, paused}; a running order is a running queue, so not standing.
        orders=api.orders and api.orders(ag.index) or nil,
        last_request_s=clock and math.floor((game.tick - math.max(clock.call_tick, clock.seen_tick or 0)) / 60) or nil}
    end
    return {agents=out, tick=game.tick}
  end
  return M
end
