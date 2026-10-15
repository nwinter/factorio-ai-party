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
  local STARVED_TICKS = 600 -- a starved wake looks at the sleeper's claims every 10 s
  local MAX_ANY = 8         -- conditions in one until=any
  -- A condition in words: its kind and what it names.
  local function texts_of(c)
    return c['until'] .. (c.technology and ' ' .. c.technology or c.item and ' ' .. c.item or c.platform and ' ' .. c.platform or '')
  end
  local MOVING = {walk=true, move_to=true, build_path=true, kite=true, collect=true, feed=true, rearm=true, refuel=true}
  local WAKE_VIEWERS = 'optional true (fh --wake-on-viewers): a viewer\'s @mention ends it too; without it a viewer\'s @mention waits for your next reply (team block) and wakes nothing'
  M.schema = {
    wait_ticks = {ticks='1..54000 simulation ticks: the character stands idle that long (a direct timed action, outcome duration_elapsed, or told|mentioned when a tell or a teammate\'s mention ends it early; use --wait), or a queue step', wake_on_viewers=WAKE_VIEWERS, pause_queue='direct call only, boolean: true pauses your running queue for this wait; without it a direct wait refuses while your queue runs (fh sleep SECONDS waits and lets it run)'},
    sleep = {seconds='1..900', condition='optional wait_until condition {until=researched|item_count|rocket_ready|crafting_done|..., ...}: the sleep also ends when it holds (woke=condition, saw); researched without technology means the research running now; item_count may take positions (chests); {until=alert}: a new attack, enemy group or enemy base alert (woke=alert); {until=alert, kinds=[low_power, no_power, no_fuel, ..., starved]}: a new or grown alert group of those kinds addressed to you, or (starved) a machine in your claims newly lacking ingredients (woke=alert, alert=its text); {until=any, conditions=[...]} (or a list): 1..8 conditions, alerts among them, whichever holds first wakes it (met names it)',
      peek='boolean: the reply leaves the team block for your next reply (fh wait --until)', wake_on_viewers=WAKE_VIEWERS,
      note='fh sleep SECONDS [--until ...]: waits while the game runs (in turns mode it advances the game); your current action and queue keep going, and the reply says first which (while_asleep). Returns early when your character takes damage or dies, a teammate\'s message mentions you (a viewer\'s @mention waits for your next reply unless wake_on_viewers), a teammate tells you something (tell), a board item of yours is assigned or changed by someone else, eggs of ours on your surface or built by you will hatch within 5 minutes (eggs), your running queue finishes or stalls (a step fails, or a walking step has not moved you for 30 s), or the condition holds; a dead bot sleeps until it respawns. sleep_check reports woke=damaged|died|respawned|mentioned|told|board|eggs|alert|queue_done|queue_stalled|condition|elapsed'},
    sleep_check = {peek='boolean: leave mentions unread (the CLI polls with peek, then reads once)', returns='woke (nil while sleeping), slept_s, health/lost when damaged, mention, tell, board, eggs, queue (what finished or stalled), saw (the condition), queue_steps (steps your queue finished during the sleep)'},
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
    assert(a.wake_on_viewers == nil or type(a.wake_on_viewers) == 'boolean', 'wake_on_viewers must be true or false')
    api.replace(p)
    local until_tick = game.tick + ticks
    -- A tell or mention ends it early (runtime.lua tick: outcome told|mentioned); a viewer's @mention only with wake_on_viewers.
    api.state().active[p.index] = {kind='wait_ticks', until_tick=until_tick, start_tick=game.tick, wake_viewers=a.wake_on_viewers == true or nil}
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
  -- A sleep started right after a wake on an event (a shell loop of sleeps:
  -- shake5-6, Opus and Sonnet) ends at once and repeats that wake, so the
  -- loop reaches its end and the agent reads the wake. A tell or mention
  -- wakes once: the reply that woke it delivered it (agent-minds study, fix
  -- 5: Luna's 32 repeats of tells already read, 10 in 34 s at 15:33, "a
  -- harness wake-repeat issue"; each such agent moved to waits that tells
  -- could not end). Bounded: within
  -- REPEAT_TICKS of the wake, at most REPEATS times per wake, never in turns
  -- mode (game time stands still between requests there); a sleep that ran
  -- out (elapsed) or ended in death is not repeated, nor is one given a
  -- condition. It cannot spin: every repeat needs a wake, and every wake a
  -- real event. A board line wakes once too, like tells, mentions and eggs:
  -- a sleep begun too soon after the reply that showed them to read it keeps
  -- sleeping, and what that reply showed comes again in a later reply
  -- (missed.lua; Opus, shift12 12:26).
  local REPEAT_TICKS, REPEATS = 600, 3
  local REPEAT = {damaged=true, condition=true, queue_done=true, queue_stalled=true}
  local function repeat_of(p, seconds)
    local prev = sleeps()[p.index]
    local woke = prev and prev.out and prev.out.woke
    if not (woke and REPEAT[woke] and prev.read_tick and game.tick - prev.read_tick <= REPEAT_TICKS) then return nil end
    if (prev.repeats or 0) >= REPEATS or api.clock_mode() == 'turns' then return nil end
    local out = {}
    for k, v in pairs(prev.out) do out[k] = v end
    local ago = math.floor((game.tick - prev.read_tick) / 60)
    out['repeat'] = true; out.slept_s = 0
    out.while_asleep = string.format('this sleep did not start: you woke (%s) %d s ago; it ends at once and repeats that wake', woke, ago)
    local record = {start_tick=game.tick, until_tick=game.tick, woke=woke, out=out, read_tick=prev.read_tick, repeats=(prev.repeats or 0) + 1,
      while_asleep=out.while_asleep}
    sleeps()[p.index] = record
    return {while_asleep=out.while_asleep,
      sleeping_s=0, until_tick=game.tick, ['repeat']=true, woke=woke, mention=out.mention, tell=out.tell, board=out.board, queue=out.queue}
  end
  function M.handlers.sleep(p, a)
    local seconds = api.integer(a.seconds, nil, 1, MAX_TICKS / 60, 'seconds (1..900)')
    -- A sleep with its own condition says what it waits for: never a repeat.
    local again = a.condition == nil and repeat_of(p, seconds)
    if again then return again end
    -- Several conditions (Muse, 21:20: wake on whichever of two or three chests fills first; Grok: `alert|platform_arrived
    -- NAME`): {until=any, conditions=[...]} (or a list), whichever holds first wakes it.
    local members
    if a.condition ~= nil then
      assert(type(a.condition) == 'table', 'condition is a wait_until condition: {until=..., ...}')
      if a.condition['until'] == 'any' or a.condition[1] ~= nil then
        members = a.condition['until'] == 'any' and a.condition.conditions or a.condition
        assert(type(members) == 'table' and #members >= 1 and #members <= MAX_ANY,
          'until=any takes conditions: 1..' .. MAX_ANY .. ' wait_until conditions (alert among them); whichever holds first wakes it')
      else
        members = {a.condition}
      end
    end
    -- until=alert (fh wait --until alert): a new attack, enemy group or enemy base alert for the team; with kinds
    -- (Luna, 19:50: low power, starvation in a claim), a new or grown alert group of those kinds addressed to you, or
    -- starved: a machine in one of your claims that lacks ingredients and did not when the sleep began.
    local conditions, texts, alert, plain, kinds = {}, {}, nil, nil, nil
    for _, m in ipairs(members or {}) do
      assert(type(m) == 'table' and type(m['until']) == 'string', 'each condition is a wait_until condition: {until=..., ...}')
      if m['until'] == 'alert' then
        alert = true
        if m.kinds ~= nil then
          local list = type(m.kinds) == 'string' and {m.kinds} or m.kinds
          assert(type(list) == 'table' and #list >= 1 and #list <= 16, 'kinds: 1..16 alert kinds (game_alerts names them: low_power, no_power, no_fuel, boiler_fuel, ...; starved: machines lacking ingredients in your claims)')
          kinds = kinds or {}
          for _, k in ipairs(list) do
            assert(type(k) == 'string' and k:match('^[%w_.-]+$'), 'kinds are alert kind names')
            kinds[#kinds+1] = k
          end
          assert(#kinds <= 16, 'kinds: 1..16 alert kinds')
          texts[#texts+1] = 'alert ' .. table.concat(list, ' ')
        else
          plain = true
          texts[#texts+1] = 'alert'
        end
      else
        assert(m['until'] ~= 'any', 'until=any takes plain conditions, not another any')
        local condition = {}
        for k, v in pairs(m) do condition[k] = v end
        if condition['until'] == 'researched' and condition.technology == nil then
          local research = p.force.current_research
          assert(research, 'no research is running; name the technology')
          condition.technology = research.name
        end
        api.validate_condition(condition)
        conditions[#conditions+1] = condition
        texts[#texts+1] = texts_of(condition)
      end
    end
    local condition = #conditions > 0
    assert(a.wake_on_viewers == nil or type(a.wake_on_viewers) == 'boolean', 'wake_on_viewers must be true or false')
    local c = p.character
    local record = {start_tick=game.tick, until_tick=game.tick + seconds * 60, health=c and c.valid and c.health or nil,
      conditions=condition and conditions or nil, wake_viewers=a.wake_on_viewers == true or nil}
    -- A dead bot sleeps until it respawns (or a mention, or time up).
    record.dead_until = api.dead_until and api.dead_until(p.index) or nil
    record.board_seq = api.board_seq and api.board_seq() or nil
    record.egg_seq = api.egg_seq and api.egg_seq() or nil
    local q = queue_of(p.index)
    if running(q) then record.queue = true end
    if plain then record.alert_seq = api.state().alert_seq or 0 end
    if kinds then
      local starved, rest = false, {}
      for _, k in ipairs(kinds) do if k == 'starved' then starved = true else rest[#rest+1] = k end end
      record.alert_kinds = #rest > 0 and rest or nil
      -- Only the levels and unit numbers are kept (the record lives in storage).
      record.alert_base = {}
      if record.alert_kinds and api.alert_levels then
        for key, g in pairs(api.alert_levels(p, rest)) do record.alert_base[key] = g.level end
      end
      if starved and api.starved then
        record.starved_base, record.starved_next = {}, game.tick + STARVED_TICKS
        for unit in pairs(api.starved(p)) do record.starved_base[unit] = true end
      end
    end
    local out = {}
    out.while_asleep = asleep_line(p, record, seconds)
    record.while_asleep = out.while_asleep
    out.sleeping_s = seconds
    out.until_tick = record.until_tick
    if #texts > 0 then out.condition = table.concat(texts, ' | ') end
    local saws = {}
    for i, cond in ipairs(conditions) do
      local ok, met, saw = pcall(api.condition, p, cond)
      assert(ok, met)
      saws[#saws+1] = saw
      -- Met already: the first check ends the sleep.
      if met and not record.woke then
        record.woke = 'condition'; out.already_met = true
        record.out = {while_asleep=record.while_asleep, slept_s=0, until_tick=record.until_tick, woke='condition', saw=saw,
          met=#members > 1 and texts_of(cond) or nil}
      end
    end
    if #saws == 1 then out.saw = saws[1] elseif #saws > 1 then out.saw = saws end
    sleeps()[p.index] = record
    -- In turns mode time only runs when asked to.
    if api.clock_mode() == 'turns' and not record.woke then api.advance(p, math.min(seconds * 60, 36000)) end
    -- Viewers' @mentions come in the next reply either way.
    local mentions = record.wake_viewers and 'a message mentioning you (a viewer\'s too)' or 'a teammate\'s message mentioning you'
    if record.dead_until then
      out.dead = true; out.respawns_at_tick = record.dead_until
      out.wakes_on = 'respawn, ' .. mentions .. ', a tell, a board item of yours'
    else
      out.wakes_on = 'damage, death, ' .. mentions .. ', a tell, a board item of yours' ..
        (record.queue and ', your queue finishing or stalling' or '') .. (condition and (#conditions > 1 and ', any of the conditions' or ', the condition') or '')
        .. (alert and ', a new alert' or '')
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
      -- healed again between two checks still counts, with its attacker; one
      -- with none named counts too (round1950a: a spitter's acid names none,
      -- "by enemies").
      local hits = api.state().char_hits
      local hit = hits and c.unit_number and hits[c.unit_number]
      if hit and hit.last and hit.last >= record.start_tick then out.by = hit.by or 'enemies' end
      -- The health to fall from: the highest seen in this sleep (a character
      -- that began it hurt heals meanwhile; round1950a).
      if record.health and c.health > record.health then record.health = c.health end
      -- Walked away when hit (runtime.lua M.idle_hit, round1950a item 2).
      local fled = api.state().idle_fled and api.state().idle_fled[p.index]
      if fled and fled.tick >= record.start_tick then
        out.fled = string.format('hit by %s at (%.1f,%.1f): walking away to (%g,%g)', fled.by, fled.from.x, fled.from.y, fled.to.x, fled.to.y)
      end
      if out.by or (record.health and c.health < record.health - 0.01) then
        out.health = math.floor(c.health)
        if record.health and c.health < record.health then out.lost = math.floor(record.health - c.health + 0.5) end
        return 'damaged'
      end
    end
    local box = api.state().mentions and api.state().mentions[p.index]
    for i = #(box and box.list or {}), 1, -1 do
      local m = box.list[i]
      -- A viewer's @mention waits for the next reply, waking only a sleep that asked (wake_on_viewers).
      if m.tick >= record.start_tick and not m.fyi and (record.wake_viewers or not m.viewer) then
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
    -- Eggs on this surface or built by the sleeper hatch within 5 minutes (spoil.lua).
    local eggs = record.egg_seq and api.egg_news and api.egg_news(p, record.egg_seq)
    if eggs then out.eggs = eggs; return 'eggs' end
    if record.alert_seq and (api.state().alert_seq or 0) > record.alert_seq then
      out.alert = 'a new attack, enemy group or enemy base alert (your next reply\'s team alerts)'
      return 'alert'
    end
    -- Chosen kinds: a group of them new or grown since the sleep began.
    if record.alert_kinds and api.alert_levels then
      for key, g in pairs(api.alert_levels(p, record.alert_kinds)) do
        local was = record.alert_base[key]
        if not was or g.level > was then out.alert = g.text; return 'alert' end
      end
    end
    -- starved: a machine in your claims lacking ingredients that did not at the start (looked at every 10 s).
    if record.starved_base and game.tick >= record.starved_next then
      record.starved_next = game.tick + STARVED_TICKS
      for unit, line in pairs(api.starved(p)) do
        if not record.starved_base[unit] then out.alert = line; return 'alert' end
      end
    end
    -- (record.condition: a sleep begun before until=any)
    local list = record.conditions or (record.condition and {record.condition})
    if list and c and c.valid then
      local saws = {}
      for _, cond in ipairs(list) do
        local ok, met, saw = pcall(api.condition, p, cond)
        if ok then saws[#saws+1] = saw end
        if ok and met then
          out.saw = saw
          if #list > 1 then out.met = texts_of(cond) end
          return 'condition'
        end
      end
      if #saws == 1 then out.saw = saws[1] elseif #saws > 1 then out.saw = saws end
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
    -- What kept going comes first here too: today's CLI prints only this reply.
    local out = {while_asleep=record.while_asleep, slept_s=math.floor((game.tick - record.start_tick) / 60), until_tick=record.until_tick}
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
    -- The agent has read the wake: a sleep right after it repeats it (repeat_of).
    if record.out and a.peek ~= true and not record.read_tick then record.read_tick = game.tick end
    return record.out or out
  end
  return M
end
