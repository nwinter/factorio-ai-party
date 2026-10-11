-- Waiting without polling: wait_ticks as a direct timed action, and sleep,
-- which lets the game run while the agent is away and says why it woke
-- (damage, death, a message mentioning the agent, or time up). Nothing here
-- runs per tick: sleep is checked when the CLI asks (sleep_check).
return function(api)
  local M = {handlers={}}
  local MAX_TICKS = 54000 -- 15 minutes
  M.schema = {
    wait_ticks = {ticks='1..54000 simulation ticks: the character stands idle that long (a direct timed action, outcome duration_elapsed; use --wait), or a queue step'},
    sleep = {seconds='1..900', note='fh sleep SECONDS: the game runs (in turns mode too) while you wait; current actions and queues keep going. Returns early when your character takes damage or dies, a message mentions you, a teammate tells you something (tell), or a board item of yours is assigned or changed by someone else; a dead bot sleeps until it respawns; sleep_check reports woke=damaged|died|respawned|mentioned|told|board|elapsed'},
    sleep_check = {peek='boolean: leave mentions unread (the CLI polls with peek, then reads once)', returns='woke (nil while sleeping), slept_s, health/lost when damaged, mention when mentioned, tell when told, board when a board item changed'},
  }
  local function sleeps()
    local s = api.state()
    s.sleeps = s.sleeps or {}
    return s.sleeps
  end
  function M.handlers.wait_ticks(p, a)
    local ticks = api.integer(a.ticks, nil, 1, MAX_TICKS, 'ticks (1..54000)')
    api.replace(p)
    local until_tick = game.tick + ticks
    api.state().active[p.index] = {kind='wait_ticks', until_tick=until_tick}
    return {until_tick=until_tick}
  end
  function M.handlers.sleep(p, a)
    local seconds = api.integer(a.seconds, nil, 1, MAX_TICKS / 60, 'seconds (1..900)')
    local c = p.character
    local record = {start_tick=game.tick, until_tick=game.tick + seconds * 60, health=c and c.valid and c.health or nil}
    -- A dead bot sleeps until it respawns (or a mention, or time up).
    record.dead_until = api.dead_until and api.dead_until(p.index) or nil
    record.board_seq = api.board_seq and api.board_seq() or nil
    sleeps()[p.index] = record
    -- In turns mode time only runs when asked to.
    if api.clock_mode() == 'turns' then api.advance(p, math.min(seconds * 60, 36000)) end
    if record.dead_until then
      return {sleeping_s=seconds, until_tick=record.until_tick, dead=true, respawns_at_tick=record.dead_until, wakes_on='respawn, a message mentioning you, a tell, a board item of yours'}
    end
    return {sleeping_s=seconds, until_tick=record.until_tick, wakes_on='damage, death, a message mentioning you, a tell, a board item of yours'}
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
    if game.tick >= record.until_tick then return 'elapsed' end
  end
  function M.handlers.sleep_check(p, a)
    local record = sleeps()[p.index]
    assert(record, 'no sleep started; call sleep {seconds} first (fh sleep SECONDS)')
    local out = {slept_s=math.floor((game.tick - record.start_tick) / 60), until_tick=record.until_tick}
    out.woke = record.woke or why(p, record, out)
    -- The first reason sticks, so the final (non-peek) read repeats it.
    if out.woke then record.woke = out.woke; record.out = record.out or out end
    return record.out or out
  end
  return M
end
