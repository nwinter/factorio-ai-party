-- Turn-based clock: in 'turns' mode the game is paused whenever no controlled
-- character has work in progress, so agent think time costs no game time.
-- Timed actions, running queues and `advance` unpause it; the tick handler
-- pauses again once they finish. Instant actions run while paused.
return function(api)
  local M = {handlers={}}
  local MAX_ADVANCE = 36000
  local function clock()
    local s = api.state()
    s.clock = s.clock or {mode='realtime'}
    return s.clock
  end
  -- Work that needs simulated time: an active timed action or combat, or a running plan.
  local function busy()
    local s = api.state()
    for _ in pairs(s.active or {}) do return true end
    for _ in pairs(s.combat or {}) do return true end
    local keys={'queues','remote_queues'}
    for name in pairs(s.platform_lanes or {}) do keys[#keys+1]='lane_queues|'..name end
    for _,key in ipairs(keys) do
      for _,q in pairs(s[key] or {}) do
        if not q.paused and (q.current or #q.pending>0 or q.loop) then return true end
      end
    end
    return false
  end
  local function crafting(p)
    return p.character and p.crafting_queue_size and p.crafting_queue_size > 0
  end
  local function report()
    local c = clock()
    return {mode=c.mode, paused=game.tick_paused, run_until=c.run_until, busy=busy()}
  end
  M.schema = {
    clock = {mode='optional realtime|turns (operator setting; in turns mode the game pauses whenever nothing is in progress)'},
    advance = {ticks='1..36000: let the game run this long (machines, crafting, research) while the character stands still',
      until_crafted='boolean: stop early once the hand-crafting queue is empty',
      note='turns mode only; realtime mode always runs. Returns until_tick; status shows clock.paused'},
  }
  function M.handlers.clock(p, a)
    if a.mode ~= nil then
      assert(a.mode == 'realtime' or a.mode == 'turns', 'mode must be realtime or turns')
      local c = clock()
      c.mode = a.mode
      c.run_until = nil
      c.until_crafted = nil
      if a.mode == 'realtime' then game.tick_paused = false end
      if a.mode == 'turns' and not busy() then game.tick_paused = true end
    end
    return report()
  end
  function M.handlers.advance(p, a)
    local c = clock()
    local ticks = a.ticks
    assert(type(ticks) == 'number' and ticks == math.floor(ticks) and ticks >= 1 and ticks <= MAX_ADVANCE, 'ticks must be 1..36000')
    c.run_until = game.tick + ticks
    c.until_crafted = a.until_crafted == true and p.index or nil
    if c.mode == 'turns' then game.tick_paused = false end
    local out = report()
    out.until_tick = c.run_until
    return out
  end
  -- After a dispatch: work just started -> let time run.
  function M.after_dispatch()
    local c = clock()
    if c.mode == 'turns' and game.tick_paused and busy() then game.tick_paused = false end
  end
  -- Every tick: pause once nothing needs time.
  function M.tick()
    local c = clock()
    if c.mode ~= 'turns' then return end
    if c.run_until then
      local done = game.tick >= c.run_until
      if not done and c.until_crafted then
        local p = (api.lookup or game.get_player)(c.until_crafted)
        done = not (p and p.valid and crafting(p))
      end
      if not done then return end
      c.run_until = nil
      c.until_crafted = nil
    end
    -- With nobody connected, leave pausing to the server's auto_pause: a
    -- tick-paused game never lets a reconnecting client finish joining.
    if #game.connected_players == 0 then return end
    if not busy() then game.tick_paused = true end
  end
  M.report = report
  return M
end
