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
  -- A sleep with nothing running and nothing to wait for is cut to this (d15 H4, Nick 07:45: Sonnet asked 900 s in 90
  -- of 162 sleeps in shifts 14-16, 73% of its time asleep with its character idle); 900 s needs a queue, an action or a
  -- condition.
  local IDLE_CAP = 300
  -- A condition in words: its kind and what it names.
  local function texts_of(c)
    return c['until'] .. (c.technology and ' ' .. c.technology or c.item and ' ' .. c.item or c.platform and ' ' .. c.platform or '')
  end
  local MOVING = {walk=true, move_to=true, build_path=true, kite=true, collect=true, feed=true, rearm=true, refuel=true}
  local WAKE_LOCAL = 'optional true (fh --wake-local): wake only for what is yours: tells and mentions to you (a tell to the whole team waits for your next reply), urgent news on your surface or in your claims (another platform\'s losses wait), and an alert condition on your surface; default false'
  local WAKE_FROM = 'optional 1..16 names (teammates, or operator; fh --wake-from a,b): only a tell or mention from them ends it; the rest wait for your next reply (urgent alerts and the rest of the wakes as before)'
  local WAKE_OPERATOR = 'optional false (fh --no-operator-wake): operator tells and reminder jobs do not end it (they wait for your next reply); teammates\' tells do'
  local WAKE_VIEWERS = 'optional true (fh --wake-on-viewers): a viewer\'s @mention ends it too; without it a viewer\'s @mention waits for your next reply (team block) and wakes nothing'
  local WAKE = '{near: N} (1..200; d18 batch36 B1): only an attack on ours or buildings of ours destroyed within N tiles of you wake it (urgent); every other urgent alert is held and given with the reply (held_alerts, held_alerts_count); damage to you, tells and mentions wake as before'
  local WAKE_URGENT = 'true (default), false (fh --no-urgent) or {radius: 1..200} (fh --urgent-radius N: attacks, enemy groups, losses, in your claims too, and teammates\' deaths count only within N tiles of you; platform and power wakes as before): an urgent alert ends it (woke=urgent, urgent=the alert): our structures attacked within 40 tiles of you, an enemy group heading for a spot within 40 tiles of you, buildings destroyed by enemies in your fresh claims or within 40 tiles of you, a platform you hear about losing a building or its hub taking damage, a teammate dying on your surface, an electric network on your surface with 20+ machines half on low or no power that had power within the last 10 minutes; each wakes you once (again after 5 min if it grew)'
  M.schema = {
    wait_ticks = {ticks='1..54000 simulation ticks: the character stands idle that long (a direct timed action, outcome duration_elapsed, or told|mentioned when a tell or a teammate\'s mention ends it early, urgent when an urgent alert does (last.why names it); use --wait), or a queue step', wake_on_viewers=WAKE_VIEWERS, wake_from=WAKE_FROM, wake_local=WAKE_LOCAL, wake_on_operator=WAKE_OPERATOR, wake_on_urgent=WAKE_URGENT, wake=WAKE, wake_on_messages='boolean default true; false keeps waiting through all tells and mentions, including viewers; messages remain in the next reply', pause_queue='direct call only, boolean: true pauses your running queue for this wait; without it a direct wait while your queue runs runs as a sleep (as_sleep): the queue keeps going'},
    sleep = {seconds='1..900; with no queue running, no action running and no condition it is capped at 300 (capped: "capped at 300 s: no queue, action or condition")', condition='optional wait_until condition {until=researched|item_count|rocket_ready|rocket_parts|crafting_done|..., ...}: the sleep also ends when it holds (woke=condition, saw); researched without technology means the research running now; item_count may take positions (chests); {until=alert}: a new attack, enemy group or enemy base alert (woke=alert, alert=which); {until=alert, area={left_top,right_bottom}|near={x,y} radius=R (default 100), surface=S (default yours), min_size=N}: only one in that area (an attack\'s position, a group\'s target or gathering point, a nest) and/or by N+ enemies (an attack by N+ attackers or a group of N+; nest news has no size); {until=alert, kinds=[low_power, no_power, no_fuel, ..., starved]}: a new or grown alert group of those kinds addressed to you, or (starved) a machine in your claims newly lacking ingredients (woke=alert, alert=its text); {until=any, conditions=[...]} (or a list): 1..8 conditions, alerts among them, whichever holds first wakes it (met names it); {until=queue_done}: your queue finishing or stalling (a standing order\'s round too; woke=queue_done), at once when no queue of yours runs; {until=all, conditions=[...]}: when every one holds; silo_parts is rocket_parts',
      returns='open: one line of what is open for you (your board items, alert groups and idle or starved machines in your fresh claims, requests and tells to you unanswered; counts and up to 3 examples), also on the reply that reads the wake; capped when cut to 300 s; wait_estimates: each condition ETA in game seconds with rate basis, or no_estimate reason; idle_s: character idle seconds in this wait; wait_line: one-line summary',
      peek='boolean: the reply leaves the team block for your next reply (fh wait --until)', wake_on_viewers=WAKE_VIEWERS, wake_from=WAKE_FROM, wake_local=WAKE_LOCAL, wake_on_operator=WAKE_OPERATOR, wake_on_urgent=WAKE_URGENT, wake=WAKE,
      wake_on_messages='boolean default true; false (fh sleep/wait --wait-through-tells): no tell or mention ends it (they stay for your next reply); a tell sent with wake: true still does, each time; urgent alerts, damage, your queue finishing or stalling and the condition still end it',
      orders='optional false: no standing order starts while this sleep runs (one already running goes on; orders_pause {seconds} holds them for a set time)',wake_on_orders='boolean default false: a standing order\'s round finishing or stalling ends the sleep too (by default only your own plan\'s does; the order keeps running)',
      note='fh sleep SECONDS [--until ...]: waits while the game runs (in turns mode it advances the game); your current action and queue keep going, and the reply says first which (while_asleep). Returns early when your character takes damage or dies, a teammate\'s message mentions you (a viewer\'s @mention waits for your next reply unless wake_on_viewers), a teammate tells you something (tell), a board item of yours is assigned or changed by someone else, eggs of ours on your surface or built by you will hatch within 5 minutes (eggs), an urgent alert (urgent, see wake_on_urgent), your running queue finishes or stalls (a step fails, or a walking step has not moved you for 30 s), or the condition holds; a dead bot sleeps until it respawns. sleep_check reports woke=damaged|died|respawned|urgent|mentioned|told|board|eggs|alert|queue_done|queue_stalled|condition|elapsed'},
    sleep_check = {peek='boolean: leave mentions unread (the CLI polls with peek, then reads once)', returns='woke (nil while sleeping), personal_requests (a sleep that ends before its time: your personal requests still unfilled, each "item: hold N of M (K on the way); why"), slept_s, health/lost when damaged, urgent (the urgent alert), alert (the alert that woke an until=alert sleep), mention, tell, board, eggs, queue (what finished or stalled), saw (the condition), queue_steps (steps your queue finished during the sleep), wait_estimates (current ETA/rate basis or no_estimate for each condition), idle_s (character idle seconds in this wait), wait_line (one line)'},
  }
  local function sleeps()
    local s = api.state()
    s.sleeps = s.sleeps or {}
    return s.sleeps
  end
  local function queue_of(index,remote)
    local qs = api.state()[remote and 'remote_queues' or 'queues']
    return qs and qs[index]
  end
  local function running(q)
    return q ~= nil and not q.paused and (q.current ~= nil or #q.pending > 0 or q.loop ~= nil)
  end
  -- wake_on_urgent: true, false or {radius} (urgent.lua M.option).
  local function urgent_option(v)
    if api.urgent_option then return api.urgent_option(v) end
    assert(v == nil or type(v) == 'boolean', 'wake_on_urgent must be true or false')
    return v ~= false, nil
  end
  function M.handlers.wait_ticks(p, a)
    a = api.wake_arg and api.wake_arg(a) or a
    local ticks = api.integer(a.ticks, nil, 1, MAX_TICKS, 'ticks (1..54000)')
    assert(a.wake_on_viewers == nil or type(a.wake_on_viewers) == 'boolean', 'wake_on_viewers must be true or false')
    assert(a.wake_on_messages == nil or type(a.wake_on_messages) == 'boolean', 'wake_on_messages must be true or false')
    local urgent_on, urgent_radius = urgent_option(a.wake_on_urgent)
    api.replace(p)
    local until_tick = game.tick + ticks
    -- A tell or mention ends it early (runtime.lua tick: outcome told|mentioned); a viewer's @mention only with wake_on_viewers.
    api.state().active[p.index] = {kind='wait_ticks', until_tick=until_tick, start_tick=game.tick, wake_viewers=a.wake_on_viewers == true or nil,
      wake_messages=a.wake_on_messages, urgent=urgent_on and api.urgent_base and api.urgent_base(p, urgent_radius) or nil,
      wake_filter=api.wake_filter and api.wake_filter(a) or nil}
    local rec = api.state().active[p.index]
    if a.wake_local == true and rec and rec.urgent then rec.urgent.local_only = true end
    return {until_tick=until_tick, wake_on_messages=a.wake_on_messages, wake_on_urgent=a.wake_on_urgent}
  end
  -- What keeps going while the agent sleeps, in one line (the reply's first).
  local function body_asleep_line(p, record, seconds)
    if record.dead_until then return 'dead: you respawn at tick ' .. record.dead_until end
    local q = queue_of(p.index)
    if running(q) and q.order and not record.queue then
      return string.format('your standing order %s runs in your queue (%d steps pending); its rounds do not end this sleep (wake_on_orders: true ends it on them)',
        tostring(q.order.name), #q.pending)
    end
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
    local armed = api.armed and api.armed(p.index)
    if armed then
      return string.format('no queue and no action: your character stands idle for up to %d s, on watch: your standing orders (%s) run when a trigger holds%s', seconds, armed, held)
    end
    return string.format('no queue and no action: your character stands idle for up to %d s%s', seconds, held)
  end
  local function asleep_line(p,record,seconds)
    local line=body_asleep_line(p,record,seconds)
    local q=queue_of(p.index,true)
    if running(q) then
      line=line:gsub('^no queue and no action','no body queue or body action'):gsub('^your queue','your body queue')
      line=line..string.format('; remote queue keeps running (%s%d steps pending%s); this sleep ends when either lane finishes or stalls',
        q.current and q.current.action..' running, ' or '',#q.pending,q.loop and ', repeating' or '')
    end
    return line
  end
  -- One predicate read per poll: its observation supplies both the wake test and the estimate, even when a
  -- higher-priority event wakes us. A final non-peek reply refreshes the estimate without changing the first wake.
  local function observe_conditions(p,record,out,initial)
    local rows,saws={},{}
    record.met_condition=nil
    for _,cond in ipairs(record.conditions or (record.condition and {record.condition}) or {}) do
      local ok,met,saw,row=pcall(api.condition,p,cond,record)
      if initial then assert(ok,met) end
      if ok then
        saws[#saws+1]=saw
        if row then rows[#rows+1]=row end
        if met and not record.met_condition then record.met_condition={text=texts_of(cond),saw=saw} end
      else
        rows[#rows+1]={condition=texts_of(cond),as_of_tick=game.tick,no_estimate='condition is unavailable',
          line=texts_of(cond)..': no estimate (condition is unavailable)'}
      end
    end
    if record.wait_alert then rows[#rows+1]={condition='alert',as_of_tick=game.tick,no_estimate='event timing is not measured',
      line='alert: no estimate (event timing is not measured)'} end
    record.wait_estimates=#rows>0 and rows or nil
    if #saws==1 then out.saw=saws[1] elseif #saws>1 then out.saw=saws end
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
  -- An urgent wake is told once (urgent.lua keeps what each agent was told), so it is never repeated either (Haiku,
  -- shift17 09:20: "the next sleep repeats it").
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
    if api.wait_info then api.wait_info(out,record) end
    sleeps()[p.index] = record
    local reply={while_asleep=out.while_asleep,
      sleeping_s=0, until_tick=game.tick, ['repeat']=true, woke=woke, urgent=out.urgent, alert=out.alert, mention=out.mention, tell=out.tell, board=out.board, queue=out.queue, queue_lane=out.queue_lane, remote_queue_steps=out.remote_queue_steps}
    return api.wait_info and api.wait_info(reply,record) or reply
  end
  -- A sleep no message ends (wake_on_messages: false), for tells.lua: {kind, until_tick}, and its wake by a tell.
  function M.deaf(index, from)
    local r = sleeps()[index]
    if not (r and not r.woke and game.tick < (r.until_tick or 0)) then return nil end
    if r.wake_messages == false then return {until_tick=r.until_tick, kind='sleep'} end
    -- takes tells only from others (wake_from, wake_on_operator)
    if from and r.wake_filter and api.wakes and not api.wakes({from=from}, r.wake_filter) then return {until_tick=r.until_tick, kind='sleep', why='takes tells only from others'} end
  end
  function M.wake_deaf(index, from)
    if not M.deaf(index, from) then return false end
    sleeps()[index].told_wake = from .. ' (a tell with wake: true)'
    return true
  end
  function M.handlers.sleep(p, a)
    a = api.wake_arg and api.wake_arg(a) or a
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
    local conditions, texts, alert, plain, kinds, filter = {}, {}, nil, nil, nil, nil
    -- until queue_done (A1, Sonnet 22:50: refused as an invalid until, then about 10 polls of the silo): the sleep ends
    -- when your queue finishes or stalls (a standing order's round too); no queue running: it ends at once.
    local queue_wait
    for _, m in ipairs(members or {}) do
      assert(type(m) == 'table' and type(m['until']) == 'string', 'each condition is a wait_until condition: {until=..., ...}')
      if m['until'] == 'queue_done' then
        queue_wait = true
        texts[#texts+1] = 'queue_done'
      elseif m['until'] == 'alert' then
        alert = true
        if m.kinds ~= nil then
          local list = type(m.kinds) == 'string' and {m.kinds} or m.kinds
          assert(type(list) == 'table' and #list >= 1 and #list <= 16, 'kinds: 1..16 alert kinds (game_alerts names them: low_power, no_power, no_fuel, boiler_fuel, ...; starved: machines lacking ingredients in your claims; speaker: programmable speaker alerts)')
          kinds = kinds or {}
          for _, k in ipairs(list) do
            assert(type(k) == 'string' and k:match('^[%w_.-]+$'), 'kinds are alert kind names')
            kinds[#kinds+1] = k
          end
          assert(#kinds <= 16, 'kinds: 1..16 alert kinds')
          texts[#texts+1] = 'alert ' .. table.concat(list, ' ')
        else
          -- A filter by area and size (Haiku, 06:20: "alerts wake fh wait --until 'tell|alert' over and over, so I end up
          -- on sleep for long waits. An alert filter by area or minimum size would fix it").
          local f = api.alert_filter and api.alert_filter(m, p) or nil
          assert(not (filter and f) and not (plain and f) and not (filter and not f), 'one plain alert condition per sleep: give its area and min_size together')
          plain, filter = true, f
          texts[#texts+1] = f and 'alert ' .. api.alert_filter_text(f) or 'alert'
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
    assert(a.wake_on_messages == nil or type(a.wake_on_messages) == 'boolean', 'wake_on_messages must be true or false')
    local urgent_on, urgent_radius = urgent_option(a.wake_on_urgent)
    local c = p.character
    local record = {start_tick=game.tick, until_tick=game.tick + seconds * 60, health=c and c.valid and c.health or nil,
      conditions=condition and conditions or nil, wake_viewers=a.wake_on_viewers == true or nil,wait_alert=alert}
    if a.wake_on_messages == false then record.wake_messages = false end
    -- orders: false (d17 batch14 A2, Haiku: a standing order walked him 31 tiles during a sleep): no standing order
    -- starts while this sleep runs (one running goes on)
    assert(a.orders == nil or a.orders == false, 'orders is false: no standing order starts during this sleep')
    if a.orders == false then record.no_orders = true end
    record.wake_filter = api.wake_filter and api.wake_filter(a) or nil
    -- A dead bot sleeps until it respawns (or a mention, or time up).
    record.dead_until = api.dead_until and api.dead_until(p.index) or nil
    record.board_seq = api.board_seq and api.board_seq() or nil
    record.egg_seq = api.egg_seq and api.egg_seq() or nil
    local q = queue_of(p.index)
    -- A standing order's round is routine (Opus, shift17 12:20: about 30 sleeps a shift woke on copper-fuel rounds,
    -- queue_done): only the agent's own plan, or wake_on_orders, ends a sleep when it finishes or stalls.
    assert(a.wake_on_orders == nil or type(a.wake_on_orders) == 'boolean', 'wake_on_orders must be true or false')
    if running(q) and (not q.order or a.wake_on_orders == true or queue_wait) then record.queue = true end
    if running(q) and q.order and not record.queue then record.order = q.order.name end
    if running(queue_of(p.index,true)) then record.remote_queue=true end
    local queue_idle = queue_wait and not record.queue and not record.remote_queue
    local capped
    if not condition and not alert and not queue_wait and not record.queue and not record.order and not record.remote_queue and not record.dead_until
      and not api.state().active[p.index] and seconds > IDLE_CAP then
      seconds = IDLE_CAP
      record.until_tick = game.tick + seconds * 60
      capped = string.format('capped at %d s: no queue, action or condition', IDLE_CAP)
      record.capped = capped
    end
    if plain then
      record.alert_seq = api.state().alert_seq or 0; record.alert_filter = filter
      -- (d18 batch37 U2) the attacks known now: their repeats do not wake it (urgent.lua alert_known)
      record.alert_known = api.alert_known and api.alert_known(p) or nil
    end
    -- Urgent alerts wake every sleep unless it opts out (Nick, d15 06:17; urgent.lua).
    if urgent_on and api.urgent_base then record.urgent = api.urgent_base(p, urgent_radius) end
    -- wake_local (C1): urgent news of your surface and claims only, and a plain alert condition on your surface only
    if a.wake_local == true then
      if record.urgent then record.urgent.local_only = true end
      if plain and not record.alert_filter then record.alert_filter = {surface=p.surface.name} end
      record.wake_local = true
    end
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
    out.capped = capped
    out.until_tick = record.until_tick
    if #texts > 0 then out.condition = table.concat(texts, ' | ') end
    -- A sleep that replaces another names itself to the one it replaced (A3, Luna 22:50): its start and condition.
    record.condition_text = out.condition
    observe_conditions(p,record,out,true)
    if queue_idle and not record.met_condition then
      record.woke='queue_done'; out.already_met=true
      local why=q and q.paused and 'your queue is paused (queue_status; queue_resume)' or 'no queue of yours runs (queue_status)'
      record.out={while_asleep=record.while_asleep,slept_s=0,until_tick=record.until_tick,woke='queue_done',queue=why..': until queue_done ends at once'}
    elseif record.met_condition then
      record.woke='condition'; out.already_met=true
      record.out={while_asleep=record.while_asleep,slept_s=0,until_tick=record.until_tick,woke='condition',saw=record.met_condition.saw,
        met=#members>1 and record.met_condition.text or nil}
    end
    if api.wait_info then api.wait_info(out,record); if record.out then api.wait_info(record.out,record) end end
    sleeps()[p.index] = record
    -- What is open for the sleeper (open.lua), once here and once on the reply that reads its wake.
    if api.open_line then
      local ok, line = pcall(api.open_line, p)
      if ok then out.open = line end
    end
    -- In turns mode time only runs when asked to.
    if api.clock_mode() == 'turns' and not record.woke then api.advance(p, math.min(seconds * 60, 36000)) end
    -- Viewers' @mentions come in the next reply either way.
    local mentions = record.wake_viewers and 'a message mentioning you (a viewer\'s too)' or 'a teammate\'s message mentioning you'
    local tell = ', a tell'
    if record.wake_messages == false then mentions, tell = 'no message (tells and mentions wait for your next reply)', ', a tell sent with wake: true' end
    if record.dead_until then
      out.dead = true; out.respawns_at_tick = record.dead_until
      out.wakes_on = 'respawn, ' .. mentions .. tell .. ', a board item of yours'
    else
      out.wakes_on = 'damage, death, ' .. mentions .. tell .. ', a board item of yours' ..
        (record.queue and ', your queue finishing or stalling' or '') .. (condition and (#conditions > 1 and ', any of the conditions' or ', the condition') or '')
        .. (alert and (filter and ', a new alert ' .. api.alert_filter_text(filter) or ', a new alert') or '')
        .. (record.urgent and (', an urgent alert (attack or enemy group near you, losses in your claims, platform hits, a teammate\'s death, power collapse' .. (record.urgent.radius and string.format('; within %g tiles of you', record.urgent.radius) or '') .. ')') or '')
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
  -- A collect waiting at its machine (stock.lua start_wait): whether the machine works now (crafting, its products
  -- accumulating) and one line on it; nil for any other action.
  function M.collect_waiting(index)
    local act = (api.state().active or {})[index]
    if not (act and act.kind == 'gather' and act.wait) then return nil end
    local t = act.targets and act.targets[1]
    local e = t and t.entity
    if not (e and e.valid) then return nil end
    local crafting = pcall(function() return e.is_crafting() end) and e.is_crafting()
    local progress = (pcall(function() return e.crafting_progress end) and e.crafting_progress) or 0
    local st = defines and defines.entity_status
    local status = pcall(function() return e.status end) and e.status
    local name
    for k, v in pairs(st or {}) do if v == status then name = k end end
    local working = crafting or (st and status == st.working) or false
    return {working=working, line=string.format('collect waits at %s (%g,%g) for %s: the machine %s (status %s, craft %d%%), got %d so far',
      e.name, e.position.x, e.position.y, act.item or 'its products', working and 'works: the products come as it crafts' or 'is not crafting',
      name or tostring(status), math.floor(progress * 100 + 0.5), act.got or 0)}
  end
  local function queue_why(p, record, out, remote)
    local q = queue_of(p.index,remote)
    if not q or q.paused then
      out.queue = q and failure(q, record.start_tick) or 'paused (see queue_status)'
      return 'queue_stalled'
    end
    if not q.current and #q.pending == 0 and not q.loop then out.queue = 'finished'; return 'queue_done' end
    local c = p.character
    local step = q.current
    if step and MOVING[step.action] and c and c.valid then
      local pos, still = c.position, record.still
      -- A collect standing at its machine on purpose while the machine works (Sol 13:50: a long coolant collect woke
      -- the sleep every 30 s as queue_stalled) is no stall; a machine that stopped is one, and says so.
      local waiting = M.collect_waiting(p.index)
      if waiting and waiting.working then record.still = nil; return nil end
      if not still or still.step ~= step.id or math.abs(pos.x - still.x) + math.abs(pos.y - still.y) > 0.5 then
        record.still = {x=pos.x, y=pos.y, tick=game.tick, step=step.id}
      elseif game.tick - still.tick >= STILL_TICKS then
        out.queue = waiting and waiting.line or string.format('%s has not moved your character for %d s (at %.1f,%.1f)', step.action, math.floor((game.tick - still.tick) / 60), pos.x, pos.y)
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
    -- An urgent alert (urgent.lua): what a player drops everything for.
    if record.urgent and api.urgent and not record.dead_until then
      local line = api.urgent(p, record.urgent)
      if line then out.urgent = line; return 'urgent' end
    end
    -- wake_on_messages: false (Grok, Sonnet: woken 6-15 times an hour while waiting for a ship): no tell or mention
    -- wakes it; a tell with wake: true does, each time (tells.lua).
    if record.told_wake then out.tell = record.told_wake; return 'told' end
    local box = record.wake_messages ~= false and api.state().mentions and api.state().mentions[p.index]
    for i = #(box and box.list or {}), 1, -1 do
      local m = box.list[i]
      -- A viewer's @mention waits for the next reply, waking only a sleep that asked (wake_on_viewers).
      if m.tick >= record.start_tick and not m.fyi and (record.wake_viewers or not m.viewer) and (not api.wakes or api.wakes(m, record.wake_filter)) then
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
    local eggs = record.egg_seq and api.egg_news and api.egg_news(p, record.egg_seq, record.wake_messages == false)
    if eggs then out.eggs = eggs; return 'eggs' end
    if record.alert_seq and (api.state().alert_seq or 0) > record.alert_seq then
      -- Which alert woke it; with a filter only one that matches (the rest are skipped, the sleep goes on).
      -- With the attacks known at the start (U2), only a new or changed one; their repeats are held, said on the wake.
      local line = api.alert_line and api.alert_line(p, record.alert_seq, record.alert_filter, record.alert_known)
      if line or not (record.alert_filter or record.alert_known) then
        out.alert = line or 'a new attack, enemy group or enemy base alert (your next reply\'s team alerts)'
        return 'alert'
      end
      if record.alert_known then record.alert_seq = api.state().alert_seq or 0 end
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
    if record.met_condition then
      out.saw=record.met_condition.saw
      if #(record.conditions or {})>1 then out.met=record.met_condition.text end
      return 'condition'
    end
    if record.queue then
      local reason = queue_why(p, record, out)
      if reason then return reason end
    end
    if record.remote_queue then
      local reason=queue_why(p,record,out,true)
      if reason then out.queue_lane='remote'; return reason end
    end
    if game.tick >= record.until_tick then return 'elapsed' end
  end
  function M.handlers.sleep_check(p, a)
    local record = sleeps()[p.index]
    assert(record, 'no sleep started; call sleep {seconds} first (fh sleep SECONDS)')
    -- What kept going comes first here too: today's CLI prints only this reply.
    local out = {while_asleep=record.while_asleep, slept_s=math.floor((game.tick - record.start_tick) / 60), until_tick=record.until_tick}
    observe_conditions(p,record,out)
    out.woke = record.woke or why(p, record, out)
    -- (d18 batch36 B1) urgent alerts a wake {near} held instead of waking it
    if record.urgent and record.urgent.held then out.held_alerts = record.urgent.held; out.held_alerts_count = record.urgent.held_n end
    if out.woke and record.queue then
      local q = queue_of(p.index)
      local n = 0
      for i = #(q and q.history or {}), 1, -1 do
        if (q.history[i].finished_tick or 0) < record.start_tick then break end
        if q.history[i].ok then n = n + 1 end
      end
      out.queue_steps = n
    end
    if out.woke and record.remote_queue then
      local q=queue_of(p.index,true)
      local n=0
      for _,h in ipairs(q and q.history or {}) do
        if (h.finished_tick or 0)>=record.start_tick and h.ok then n=n+1 end
      end
      out.remote_queue_steps=n
    end
    -- The first reason sticks, so the final (non-peek) read repeats it.
    if out.woke then
      record.woke = out.woke; record.out = record.out or out
      -- (U2) the repeats of known attacks it held, whatever woke it
      if not record.out.alert_held and record.alert_known and api.alert_held then record.out.alert_held = api.alert_held(record.alert_known) end
    end
    -- The agent has read the wake: a sleep right after it repeats it (repeat_of).
    if record.out and a.peek ~= true and not record.read_tick then
      record.read_tick = game.tick
      record.out.capped = record.capped
      if api.open_line then
        local ok, line = pcall(api.open_line, p)
        if ok then record.out.open = line end
      end
      -- (d17 batch31 C2, Opus twice: a request cleared before its items arrived) a sleep that ends early: the personal
      -- requests still unfilled, each with what it holds, what is on the way and why
      if record.out.woke ~= 'elapsed' and api.personal_unfilled then
        local ok, lines = pcall(api.personal_unfilled, p)
        if ok and lines then record.out.personal_requests = lines end
      end
    end
    local reply=record.out or out
    if api.wait_info then api.wait_info(reply,record) end
    -- Which sleep this is (A3): fh sleep names it when it replaced an earlier one.
    reply.sleep_started_tick=record.start_tick
    reply.sleep_until=record.condition_text
    return reply
  end
  return M
end
