-- Rests between turns (d20 batch50 B1, viewer Aurora: "Could quota rests appear in team status and tell replies, with
-- a return time"): Gemini's loop sleeps between turns to pace its quota (tools/agy-quota.py, runs/RUN/AGENT/resting.json)
-- and pushes the rest here as the operator: rest {agent, until_clock, until_s, reason, ticks_per_s?}. The teammates line
-- shows "resting until 07:34 (pace)" in place of offline, and a tell to the agent says so in its reply with the
-- agent's board items whose review (evidence next_check) falls inside the rest. The rest ends with rest {agent, done:
-- true} (the loop's next turn), the agent's own next request, or the tick it was due to end.
return function(api)
  local M = {operator={}}
  local REASONS = {pace=true, quota=true}
  local function store()
    local s = api.state()
    s.rests = s.rests or {}
    return s.rests
  end
  function M.operator.rest(a)
    assert(type(a.agent) == 'string' and #a.agent > 0, 'agent is required: the resting agent\'s name')
    local ok, name = pcall(api.resolve, a.agent)
    name = ok and name or a.agent
    if a.done == true then
      local had = store()[name] ~= nil
      store()[name] = nil
      return {agent=name, ended=had}
    end
    assert(type(a.until_clock) == 'string' and a.until_clock:match('^%d%d:%d%d$'), 'until_clock must be HH:MM')
    assert(type(a.until_s) == 'number' and a.until_s > 0 and a.until_s <= 86400, 'until_s must be 1..86400 seconds')
    assert(REASONS[a.reason], 'reason must be pace or quota')
    local tps = type(a.ticks_per_s) == 'number' and a.ticks_per_s >= 1 and a.ticks_per_s <= 600 and a.ticks_per_s or 60
    local row = {reason=a.reason, until_clock=a.until_clock, since_tick=game.tick, until_tick=game.tick + math.ceil(a.until_s * tps)}
    store()[name] = row
    return {agent=name, until_clock=row.until_clock, until_tick=row.until_tick, reason=row.reason}
  end
  -- The rest `name` is in now ({reason, until_clock, since_tick, until_tick}), or nil: none pushed, past its tick, or
  -- the agent has made a request since it began.
  function M.get(name)
    local row = name and store()[name]
    if not row then return nil end
    local last = api.last_call and api.last_call(name)
    if game.tick >= row.until_tick or (last and last > row.since_tick) then
      store()[name] = nil
      return nil
    end
    return row
  end
  function M.label(row) return string.format('resting until %s (%s)', row.until_clock, row.reason) end
  -- For a tell's reply: "gemini is resting until 07:34 (pace); board items with a review in the rest: #12 Boiler
  -- check (review in 3 min)", or nil when `name` is not resting.
  function M.tell_line(name)
    local row = M.get(name)
    if not row then return nil end
    local text = name .. ' is ' .. M.label(row)
    local items = api.reviews_between and api.reviews_between(name, row.since_tick, row.until_tick) or {}
    if #items > 0 then
      local parts = {}
      for i, it in ipairs(items) do
        if i > 5 then parts[#parts+1] = string.format('%d more', #items - 5); break end
        local d = it.next_check - game.tick
        parts[#parts+1] = string.format('#%d %s (review %s)', it.id, it.title,
          d >= 0 and string.format('in %d min', math.ceil(d / 3600)) or string.format('%d min ago', math.floor(-d / 3600)))
      end
      text = text .. '; board items with a review in the rest: ' .. table.concat(parts, ', ')
    end
    return text
  end
  return M
end
