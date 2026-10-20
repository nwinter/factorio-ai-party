-- reminders: an agent's reminder and review jobs (viewer Foobator's idea; the design from Astra and Sol, d15 05:16).
-- A job holds a short message, an owner, its recipients (the owner by default, named teammates, or the team), and a
-- cadence in game ticks (every_ticks, anchored at its start) or one due tick. When it is due, each recipient gets one
-- private line in their next reply, as a tell from "reminder #N" (it wakes a sleep as a tell does). While a recipient
-- has not acknowledged it (reminder_ack), further runs fold into that one line (missed), so nothing piles up and an
-- overdue job never fires every tick. ack records a result and leaves the cadence where it is; snooze moves the next
-- run only. A job never acts in the game: no character, action, queue, machine or chat. Alerts stay apart.
-- The state lives in the save, so a rollback restores jobs and ticks together; a job whose next run lies more than
-- one interval past the tick (or whose last run lies after it) is set again from the restored tick.
-- Checklists (d17 batch30 B1, Sol, Astra and viewer Foobator 05:43): steps, each named and optionally with its own
-- cadence (every_ticks: the line again while that step is a recipient's next one). A run goes out with the next
-- unfinished step; each recipient records steps with reminder_ack {id, step?, result} (the next unfinished one by
-- default), and the run is done for them when every step is recorded (a one-time job is done when every recipient is).
-- leave: true sets it aside (an emergency): no step lines while left; resume: true (or any step's ack) takes it up at
-- the next unfinished step. reminders {pending: true} is the grouped read: what waits for you, each at its next step.
return function(api)
  local M = {}
  -- (d19 batch41 B2, Sol seq 865: "a 200-character ack hides outcomes") a result up to 1000 characters, kept whole
  local MAX_JOBS, MAX_OWN, MAX_TEXT, MAX_RESULT = 48, 12, 300, 1000
  local Ev_
  local function Ev() Ev_ = Ev_ or require('evidence')(); return Ev_ end
  -- (d20 batch50 B2) what a reminder serves, flagged when none is left (serves.lua; loaded when first used)
  local Sv_
  local function Sv() Sv_ = Sv_ or require('serves')(); return Sv_ end
  local MIN_EVERY, MAX_EVERY = 3600, 7 * 24 * 216000
  local MAX_STEPS, MIN_STEP_EVERY = 12, 1800
  local CHECK = 60
  local TEAM = {team=true, all=true, everyone=true}
  local function store()
    local s = api.state()
    s.reminders = s.reminders or {seq=0, jobs={}}
    return s.reminders
  end
  local function one_line(v, max, what)
    assert(type(v) == 'string', what .. ' is text')
    local t = v:gsub('[%c]+', ' '):gsub('^%s+', ''):gsub('%s+$', '')
    assert(#t >= 1, what .. ' is empty')
    assert(#t <= max, what .. ' is at most ' .. max .. ' characters (' .. #t .. ')')
    return t
  end
  local function ticks_arg(v, lo, hi, what)
    assert(type(v) == 'number' and v == math.floor(v) and v >= lo and v <= hi, what .. ' must be ' .. lo .. '..' .. hi .. ' ticks')
    return v
  end
  local function ago(ticks)
    local s = math.max(0, math.floor(ticks / 60 + 0.5))
    if s >= 3600 then return string.format('%dh%02dm', math.floor(s / 3600), math.floor(s % 3600 / 60)) end
    if s >= 60 then return string.format('%dm%02ds', math.floor(s / 60), s % 60) end
    return s .. 's'
  end
  -- (d19 batch41 B2, Sol seq 865: reminder 97 folded runs 3-9 into one line) the runs folded, how many and when.
  local function missed_text(pd)
    if not (pd and pd.missed and pd.missed > 0) then return nil end
    if not pd.first_missed then return string.format('%d run%s missed', pd.missed, pd.missed == 1 and '' or 's') end
    if pd.missed == 1 then return string.format('1 run missed (tick %d, %s ago)', pd.first_missed, ago(game.tick - pd.first_missed)) end
    return string.format('%d runs missed (the first at tick %d, %s ago; the last at tick %d, %s ago)', pd.missed, pd.first_missed,
      ago(game.tick - pd.first_missed), pd.last_missed, ago(game.tick - pd.last_missed))
  end
  local function names_of(to, me)
    if to == nil then return {me}, false end
    local list = {}
    if type(to) == 'string' then for w in to:gmatch('[^,%s]+') do list[#list+1] = w end
    elseif type(to) == 'table' then for _, w in ipairs(to) do assert(type(w) == 'string', 'recipients are names'); list[#list+1] = w end end
    assert(#list > 0, 'recipients: names (sol, luna), "team", or none for yourself')
    local out, seen = {}, {}
    for _, w in ipairs(list) do
      w = w:gsub('^@', '')
      if TEAM[w:lower()] then return {'team'}, true end
      local name = api.resolve(w)
      assert(name ~= 'operator', 'recipients are teammates')
      if not seen[name] then seen[name] = true; out[#out+1] = name end
    end
    table.sort(out)
    assert(#out <= 9, 'at most 9 names; "team" for everyone')
    return out, false
  end
  -- The agents a job goes to now.
  local function targets(job)
    if job.recipients[1] == 'team' then
      local out = {}
      for _, a in ipairs(api.agents()) do out[#out+1] = a.name end
      return out
    end
    return job.recipients
  end
  local function cadence(job)
    if job.every then return 'every ' .. ago(job.every) end
    return 'once'
  end
  -- A checklist's progress for a recipient: {done = {[step] = {result, tick}}, left = tick?, nudged = tick?}.
  local function progress(job, name)
    job.progress = job.progress or {}
    job.progress[name] = job.progress[name] or {done={}}
    return job.progress[name]
  end
  local function next_step(job, name)
    local pr = job.progress and job.progress[name]
    for i = 1, #(job.steps or {}) do if not (pr and pr.done[i]) then return i end end
    return nil
  end
  local function steps_done(job, name)
    local pr, n = job.progress and job.progress[name], 0
    for i = 1, #(job.steps or {}) do if pr and pr.done[i] then n = n + 1 end end
    return n
  end
  local function step_text(job, i)
    local st = job.steps[i]
    return string.format('step %d of %d "%s"%s', i, #job.steps, st.name, st.every and ' (again every ' .. ago(st.every) .. ' while it is next)' or '')
  end
  -- The next run on the cadence after `tick` (anchored at job.anchor).
  local function next_after(job, tick)
    local k = math.floor((tick - job.anchor) / job.every) + 1
    return job.anchor + math.max(1, k) * job.every
  end
  local function status_of(job, name)
    local pd = job.pending and job.pending[name]
    if pd then
      local late = job.every or 36000
      local pr = job.steps and job.progress and job.progress[name]
      if pr and pr.left then return 'left at step ' .. (next_step(job, name) or '?'), pd end
      local st = game.tick - pd.tick > late and 'overdue' or 'pending'
      if job.steps then st = string.format('%s, %d of %d steps done', st, steps_done(job, name), #job.steps) end
      return st, pd
    end
    if job.acked and job.acked[name] then return 'acknowledged' end
    return job.enabled and 'scheduled' or (job.done and 'done' or 'off')
  end
  local function row(job, me)
    local r = {id=job.id, name=job.name, owner=job.owner, recipients=table.concat(job.recipients, ', '), message=job.message,
      cadence=cadence(job), every_ticks=job.every, due_tick=not job.every and job.due or nil, enabled=job.enabled, wake=job.quiet and 'false: delivered with the next reply, wakes no wait' or nil,
      next_due_tick=job.enabled and job.next_due or nil, next_due_in_s=job.enabled and math.max(0, math.floor((job.next_due - game.tick) / 60)) or nil,
      last_fired_tick=job.last_fired, last_result=job.last_result, result_by=job.result_by, result_tick=job.result_tick,
      result_age_s=job.result_tick and math.floor((game.tick - job.result_tick) / 60) or nil,
      board_item=job.board_item, surface=job.surface, expires_tick=job.expires, done=job.done or nil, serves=job.serves and Sv().view(job.serves) or nil}
    -- (B2) the evidence given with acknowledgments, newest last
    if job.evidence and #job.evidence > 0 then
      r.evidence = {}
      for k, e in ipairs(job.evidence) do r.evidence[k] = Ev().line(e) end
    end
    local states = {}
    for _, n in ipairs(targets(job)) do
      local st, pd = status_of(job, n)
      states[#states+1] = n .. ' ' .. st .. (pd and pd.missed > 0 and string.format(' (%s%s)', missed_text(pd),
        pd.told_owner and ', the owner told' or '') or '')
      if pd and pd.missed > 0 then r.missed = r.missed or {}; r.missed[n] = pd.missed end
    end
    r.states = table.concat(states, '; ')
    if me then r.yours = status_of(job, me) end
    if job.steps then
      local pr = me and job.progress and job.progress[me]
      r.steps = {}
      for i, st in ipairs(job.steps) do
        local d = pr and pr.done[i]
        r.steps[i] = {step=i, name=st.name, every_ticks=st.every, result=d and d.result or nil, done_ago_s=d and math.floor((game.tick - d.tick) / 60) or nil}
      end
      local nx = me and job.pending and job.pending[me] and next_step(job, me)
      r.next_step = nx and step_text(job, nx) or nil
    end
    local parts = {string.format('#%d %sby %s (%s, to %s): %s', job.id, job.name and job.name .. ', ' or '', job.owner, cadence(job),
      r.recipients, job.message)}
    if job.enabled then parts[#parts+1] = 'next in ' .. ago(job.next_due - game.tick) else parts[#parts+1] = job.done and 'done' or 'off' end
    if job.steps then parts[#parts+1] = string.format('checklist of %d steps%s', #job.steps, r.next_step and ', yours next: ' .. r.next_step or '') end
    if job.last_result then parts[#parts+1] = string.format('last result %s ago: %s', ago(game.tick - job.result_tick), job.last_result) end
    if r.evidence then parts[#parts+1] = 'evidence ' .. r.evidence[#r.evidence] end
    if job.serves and Sv().gone(job.serves) then parts[#parts+1] = Sv().line(job.serves) end
    parts[#parts+1] = r.states
    r.line = table.concat(parts, '; ')
    return r
  end
  local function find(id)
    assert(type(id) == 'number' and id == math.floor(id), 'id is a reminder number (reminders lists them)')
    local job = store().jobs[id]
    assert(job, 'no reminder #' .. tostring(id) .. ' (reminders lists them)')
    return job
  end
  local function owner_only(p, job)
    local me = api.who(p)
    assert(me == job.owner or me == 'operator', 'reminder #' .. job.id .. ' is ' .. job.owner .. '\'s: its owner edits, snoozes or removes it')
  end
  -- Fields shared by add and edit.
  local function apply(job, a, fresh, p)
    if a.name ~= nil then job.name = a.name ~= false and one_line(a.name, 40, 'name') or nil end
    if a.message ~= nil or fresh then job.message = one_line(a.message, MAX_TEXT, 'message') end
    if a.recipients ~= nil or fresh then
      job.recipients = names_of(a.recipients, job.owner)
      -- (D3) the owner is told again after a change of recipients
      for _, pd in pairs(job.pending or {}) do pd.told_owner = nil end
    end
    assert(not (a.every_ticks and (a.due_tick or a.due_in_ticks)), 'give every_ticks, or due_tick / due_in_ticks, not both')
    assert(not (a.due_tick and a.due_in_ticks), 'give due_tick or due_in_ticks, not both')
    if a.every_ticks ~= nil then
      job.every = ticks_arg(a.every_ticks, MIN_EVERY, MAX_EVERY, 'every_ticks'); job.due = nil
      job.anchor = game.tick; job.next_due = game.tick + job.every
    elseif a.due_tick ~= nil or a.due_in_ticks ~= nil then
      local due = a.due_tick or (game.tick + ticks_arg(a.due_in_ticks, 60, MAX_EVERY, 'due_in_ticks'))
      assert(type(due) == 'number' and due > game.tick, 'due_tick must lie after the tick now (' .. game.tick .. ')')
      job.due = math.floor(due); job.every = nil; job.anchor = nil; job.next_due = job.due
    end
    assert(job.every or job.due, 'every_ticks (a cadence, ' .. MIN_EVERY .. '.. ticks) or due_tick / due_in_ticks (once) is required')
    if a.board_item ~= nil then
      assert(a.board_item == false or (type(a.board_item) == 'number' and a.board_item == math.floor(a.board_item)), 'board_item is a board item number')
      job.board_item = a.board_item or nil
    end
    if a.surface ~= nil then job.surface = a.surface ~= false and one_line(a.surface, 40, 'surface') or nil end
    if a.serves ~= nil then job.serves = a.serves ~= false and Sv().parse(a.serves, p) or nil end
    -- steps: a checklist (B1); a change starts every recipient's progress again
    if a.steps ~= nil then
      if a.steps == false then job.steps = nil
      else
        assert(type(a.steps) == 'table' and #a.steps >= 1 and #a.steps <= MAX_STEPS, 'steps: 1..' .. MAX_STEPS .. ' steps, each a name or {name, every_ticks?}')
        local list = {}
        for i, st in ipairs(a.steps) do
          if type(st) == 'string' then st = {name=st} end
          assert(type(st) == 'table', 'step ' .. i .. ' is a name or {name, every_ticks?}')
          for k in pairs(st) do assert(k == 'name' or k == 'every_ticks', 'step ' .. i .. ' takes name and every_ticks, not ' .. tostring(k)) end
          list[i] = {name=one_line(st.name, 80, 'step ' .. i .. ' name'), every=st.every_ticks ~= nil and ticks_arg(st.every_ticks, MIN_STEP_EVERY, MAX_EVERY, 'step ' .. i .. ' every_ticks') or nil}
        end
        job.steps = list
      end
      job.progress = nil
    end
    if a.expires_tick ~= nil or a.for_ticks ~= nil then
      local e = a.expires_tick or (a.for_ticks and game.tick + ticks_arg(a.for_ticks, 60, 30 * 216000, 'for_ticks'))
      assert(e == false or (type(e) == 'number' and e > game.tick), 'expires_tick must lie after the tick now, or false for none')
      job.expires = e or nil
    end
    -- wake (d17 batch13 A1, Luna: a routine check woke long waits with no change): false delivers the line with the
    -- recipient's next reply and wakes no sleep or wait; urgent alerts are apart and unchanged.
    if a.wake ~= nil then
      assert(type(a.wake) == 'boolean', 'wake must be true or false')
      job.quiet = a.wake == false or nil
    end
    if a.enabled ~= nil then
      assert(type(a.enabled) == 'boolean', 'enabled must be true or false')
      job.enabled = a.enabled
      if a.enabled and job.every and job.next_due <= game.tick then job.next_due = next_after(job, game.tick) end
    end
  end
  M.handlers = {}
  function M.handlers.reminder_add(p, a)
    local me = api.who(p)
    local s = store()
    local n, own = 0, 0
    for _, j in pairs(s.jobs) do n = n + 1; if j.owner == me then own = own + 1 end end
    assert(n < MAX_JOBS, 'the team holds ' .. MAX_JOBS .. ' reminders: reminder_remove one first')
    assert(own < MAX_OWN, 'you hold ' .. MAX_OWN .. ' reminders: reminder_remove one first')
    local job = {owner=me, enabled=true, created=game.tick, pending={}, acked={}}
    apply(job, a, true, p)
    if a.enabled == false then job.enabled = false end
    s.seq = s.seq + 1
    job.id = s.seq
    s.jobs[job.id] = job
    return {added=job.id, reminder=row(job, me)}
  end
  function M.handlers.reminder_edit(p, a)
    local job = find(a.id)
    owner_only(p, job)
    local b = {}
    for k, v in pairs(a) do if k ~= 'id' then b[k] = v end end
    apply(job, b, false, p)
    if job.due and job.done and job.due > game.tick then job.done = nil; job.enabled = true end
    return {edited=job.id, reminder=row(job, api.who(p))}
  end
  function M.handlers.reminder_remove(p, a)
    local job = find(a.id)
    owner_only(p, job)
    store().jobs[job.id] = nil
    return {removed=job.id, was=row(job)}
  end
  function M.handlers.reminder_snooze(p, a)
    local job = find(a.id)
    local me = api.who(p)
    local mine = me == job.owner or me == 'operator'
    for _, n in ipairs(targets(job)) do if n == me then mine = true end end
    assert(mine, 'reminder #' .. job.id .. ' is not yours or addressed to you')
    local ticks = ticks_arg(a.ticks, 60, MAX_EVERY, 'ticks')
    job.next_due = game.tick + ticks; job.enabled = true; job.done = nil
    if job.pending then job.pending[me] = nil end
    return {snoozed=job.id, next_due_tick=job.next_due, note='the next run only; a cadence goes on from its anchor after it', reminder=row(job, me)}
  end
  function M.handlers.reminder_ack(p, a)
    local job = find(a.id)
    local me = api.who(p)
    local result = a.result ~= nil and one_line(a.result, MAX_RESULT, 'result') or nil
    local evidence = a.evidence ~= nil and Ev().check(a.evidence, me) or nil
    job.pending = job.pending or {}; job.acked = job.acked or {}
    local was = job.pending[me]
    if evidence then job.evidence = Ev().add(job.evidence, evidence) end
    -- A checklist (B1): a step recorded (the next unfinished one by default), leave, resume; the run is done for you
    -- when every step is recorded.
    if job.steps then
      assert(a.step == nil or (type(a.step) == 'number' and a.step == math.floor(a.step) and a.step >= 1 and a.step <= #job.steps), 'step is 1..' .. #job.steps)
      assert(not (a.leave and a.resume), 'leave or resume, not both')
      assert(a.leave == nil or type(a.leave) == 'boolean', 'leave must be true or false')
      assert(a.resume == nil or type(a.resume) == 'boolean', 'resume must be true or false')
      assert(was or a.step ~= nil, 'reminder #' .. job.id .. ' has no run waiting for you: its next run brings step 1 (reminder_ack {id, step} records a step anyway)')
      local pr = progress(job, me)
      if a.leave then
        assert(a.step == nil and result == nil, 'leave sets the checklist aside: no step or result with it')
        pr.left = game.tick
        local nx = next_step(job, me)
        return {left=job.id, at_step=nx, note=string.format('set aside at %s: no step lines until resume (reminder_ack {id: %d, resume: true}) or a step\'s ack', nx and step_text(job, nx) or 'the end', job.id), reminder=row(job, me)}
      end
      pr.left = nil
      pr.nudged = game.tick
      local step
      if not a.resume or a.step ~= nil or result ~= nil then
        step = a.step or next_step(job, me)
        assert(step, 'every step of reminder #' .. job.id .. ' is recorded')
        pr.done[step] = {result=result, tick=game.tick}
        if result then job.last_result = string.format('step %d "%s": %s', step, job.steps[step].name, result); job.result_by = me; job.result_tick = game.tick end
      end
      local nx = next_step(job, me)
      if nx then
        if not was then job.pending[me] = {tick=game.tick, missed=0} end
        return {recorded=step, step_name=step and job.steps[step].name or nil, resumed=a.resume or nil, next_step=step_text(job, nx),
          done=string.format('%d of %d steps', steps_done(job, me), #job.steps),
          note=string.format('next: %s; reminder_ack {id: %d, result} records it', step_text(job, nx), job.id), reminder=row(job, me)}
      end
      job.pending[me] = nil; job.acked[me] = game.tick
      -- a one-time checklist is done when every recipient has recorded every step
      if not job.every then
        local all = true
        for _, n in ipairs(targets(job)) do if job.pending[n] or not job.acked[n] then all = false end end
        if all then job.done = true; job.enabled = false end
      end
      return {recorded=step, step_name=step and job.steps[step].name or nil, acknowledged=job.id, done=string.format('all %d steps', #job.steps),
        checklist_done=job.done or nil, missed=was and was.missed > 0 and was.missed or nil, missed_runs=missed_text(was), reminder=row(job, me)}
    end
    assert(a.step == nil and a.leave == nil and a.resume == nil, 'step, leave and resume are for a checklist (reminder_add steps)')
    job.pending[me] = nil; job.acked[me] = game.tick
    if result then job.last_result = result; job.result_by = me; job.result_tick = game.tick end
    -- (A1) with the ack: the next run later (next_in_ticks: the next run only), or a slower cadence (every_ticks, its
    -- owner, anchored now)
    local note = 'the cadence stays as it is'
    if a.every_ticks ~= nil then
      owner_only(p, job)
      job.every = ticks_arg(a.every_ticks, MIN_EVERY, MAX_EVERY, 'every_ticks'); job.due = nil
      job.anchor = game.tick; job.next_due = game.tick + job.every
      note = 'the cadence is now ' .. cadence(job) .. ', from now'
    end
    if a.next_in_ticks ~= nil then
      job.next_due = game.tick + ticks_arg(a.next_in_ticks, 60, MAX_EVERY, 'next_in_ticks'); job.enabled = true; job.done = nil
      note = string.format('the next run in %s (that run only; the cadence goes on from its anchor after it)', ago(job.next_due - game.tick))
    end
    return {acknowledged=job.id, was_pending=was and true or false, missed=was and was.missed > 0 and was.missed or nil, missed_runs=missed_text(was),
      note=note, reminder=row(job, me)}
  end
  -- (d19 batch41 B3, Astra seq 862 and 864: reminder misses piled up while notes kept hour-old results) what is past its
  -- review time for `name`: runs addressed to them waiting past their cadence (overdue), and recipients of their own
  -- reminders overdue. Rows {age (ticks), line}.
  function M.overdue(name)
    local rows = {}
    for _, job in pairs(store().jobs) do
      local st, pd = status_of(job, name)
      if pd and st:find('^overdue') then
        rows[#rows+1] = {age=game.tick - pd.tick, line=string.format('reminder #%d %s (by %s, %s): waiting for your ack %s%s', job.id, job.name or 'review', job.owner,
          cadence(job), ago(game.tick - pd.tick), pd.missed > 0 and '; ' .. missed_text(pd) or '')}
      end
      if job.owner == name then
        for _, n in ipairs(targets(job)) do
          local st2, pd2 = status_of(job, n)
          if n ~= name and pd2 and st2:find('^overdue') then
            rows[#rows+1] = {age=game.tick - pd2.tick, line=string.format('your reminder #%d %s: %s has not acknowledged it for %s%s', job.id, job.name or 'review', n,
              ago(game.tick - pd2.tick), pd2.missed > 0 and '; ' .. missed_text(pd2) or '')}
          end
        end
      end
    end
    return rows
  end
  function M.handlers.reminders(p, a)
    local me = api.who(p)
    assert(a.all == nil or type(a.all) == 'boolean', 'all must be true or false')
    assert(a.pending == nil or type(a.pending) == 'boolean', 'pending must be true or false')
    -- pending (B1): the grouped read: what waits for you now, each at its next step
    if a.pending then
      local ids, out, lines = {}, {}, {}
      for id in pairs(store().jobs) do ids[#ids+1] = id end
      table.sort(ids)
      for _, id in ipairs(ids) do
        local job = store().jobs[id]
        local pd = job.pending and job.pending[me]
        if pd then
          local r = row(job, me)
          local nx = job.steps and next_step(job, me)
          local pr = job.steps and job.progress and job.progress[me]
          r.waiting_s = math.floor((game.tick - pd.tick) / 60)
          out[#out+1] = r
          lines[#lines+1] = string.format('#%d %s: %s%s, waiting %s%s', id, job.name or 'review', job.message,
            nx and '; next ' .. step_text(job, nx) .. string.format(' (%d of %d done)', steps_done(job, me), #job.steps) or '',
            ago(game.tick - pd.tick), pr and pr.left and string.format('; left %s ago (resume: reminder_ack {id: %d, resume: true})', ago(game.tick - pr.left), id) or '')
        end
      end
      return {reminders=out, lines=lines, count=#out, tick=game.tick, note=#out == 0 and 'nothing waits for you' or nil}
    end
    local out, lines = {}, {}
    local ids = {}
    for id in pairs(store().jobs) do ids[#ids+1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do
      local job = store().jobs[id]
      local to_me = false
      for _, n in ipairs(targets(job)) do if n == me then to_me = true end end
      if a.all or job.owner == me or to_me or me == 'operator' then
        if job.serves then pcall(Sv().check, job.serves) end
        local r = row(job, me)
        out[#out+1] = r; lines[#lines+1] = r.line
      end
    end
    return {reminders=out, lines=lines, count=#out, tick=game.tick,
      note=#out == 0 and 'no reminders: reminder_add {message, every_ticks or due_in_ticks, recipients?}' or nil}
  end
  -- Delivery: one line in the recipient's next reply, as a tell from "reminder #N" (it wakes a sleep as a tell does).
  local function deliver(job, name, index, missed)
    local text = string.format('%s (%s, %s%s): %s; reminder_ack {id: %d, result} records the result',
      job.name or 'review', job.owner, cadence(job), job.board_item and ', board #' .. job.board_item or '', job.message, job.id)
    local nx = job.steps and next_step(job, name)
    if nx then
      text = string.format('%s (%s, %s%s): %s; checklist, next %s (%d of %d done); reminder_ack {id: %d, result} records it',
        job.name or 'review', job.owner, cadence(job), job.board_item and ', board #' .. job.board_item or '', job.message, step_text(job, nx),
        steps_done(job, name), #job.steps, job.id)
    end
    if job.serves and Sv().gone(job.serves) then text = text .. '; ' .. Sv().line(job.serves) end
    api.deliver(index, {seq='reminder', tick=game.tick, from='reminder #' .. job.id, text=text, fyi=job.quiet or nil})
  end
  local function fire(job)
    local index = {}
    for _, a in ipairs(api.agents()) do index[a.name] = a.index end
    job.pending = job.pending or {}; job.acked = job.acked or {}
    for _, name in ipairs(targets(job)) do
      local pd = job.pending[name]
      if pd then
        pd.missed = pd.missed + 1
        pd.first_missed = pd.first_missed or game.tick; pd.last_missed = game.tick
        -- (d17 batch35 D3, viewer Aurora and Sol 14:07: reminder 59, a shared review, reached 10 missed runs for Grok and
        -- 16 for Sonnet before a viewer asked) two runs missed: one line to the owner, once until that recipient
        -- acknowledges or the recipients change
        if pd.missed >= 2 and not pd.told_owner and name ~= job.owner and index[job.owner] then
          pd.told_owner = game.tick
          local others = {}
          for _, r in ipairs(job.recipients) do if r ~= name then others[#others+1] = string.format('%q', r) end end
          api.deliver(index[job.owner], {seq='reminder', tick=game.tick, from='reminder #' .. job.id,
            text=string.format('%s has missed %d runs of your reminder #%d (%s, %s): not acknowledged for %ds (%s); last result: %s; reminder_edit {id: %d, recipients: [%s]} changes its recipients',
              name, pd.missed, job.id, job.name or 'review', cadence(job), math.floor((game.tick - pd.tick) / 60), missed_text(pd),
              job.last_result and string.format('%s (by %s, %ds ago)', job.last_result, tostring(job.result_by), math.floor((game.tick - (job.result_tick or game.tick)) / 60)) or 'none yet',
              job.id, table.concat(others, ', '))})
        end
      elseif index[name] then
        if job.steps then job.progress = job.progress or {}; job.progress[name] = {done={}, nudged=game.tick} end
        deliver(job, name, index[name])
        job.pending[name] = {tick=game.tick, missed=0}
        job.acked[name] = nil
      end
    end
    job.last_fired = game.tick
    if job.every then job.next_due = next_after(job, game.tick)
    else job.enabled = false; job.done = not job.steps or nil end
  end
  -- A checklist step's own cadence: its line again while it is a recipient's next step (not while left).
  local function nudge(job)
    local index
    for name, pd in pairs(job.pending or {}) do
      local pr = job.progress and job.progress[name]
      local nx = pr and not pr.left and next_step(job, name)
      local every = nx and job.steps[nx].every
      if every and game.tick - (pr.nudged or pd.tick) >= every then
        if not index then index = {}; for _, a in ipairs(api.agents()) do index[a.name] = a.index end end
        if index[name] then deliver(job, name, index[name]) end
        pr.nudged = game.tick
      end
    end
  end
  function M.tick()
    if game.tick % CHECK ~= 0 then return end
    local s = api.state().reminders
    if not s then return end
    for _, job in pairs(s.jobs) do
      -- A rollback (or a tick that went back): the next run from the restored tick.
      if job.last_fired and job.last_fired > game.tick then job.last_fired = nil end
      if job.every and job.next_due and job.next_due > game.tick + job.every then job.next_due = next_after(job, game.tick) end
      if job.enabled and job.expires and game.tick >= job.expires then job.enabled = false; job.expired = game.tick end
      if job.enabled and job.serves then pcall(Sv().due, job.serves) end
      if job.enabled and job.next_due and game.tick >= job.next_due then fire(job) end
      if job.steps and job.pending and next(job.pending) then nudge(job) end
    end
  end
  local WHEN = 'every_ticks (a cadence: ' .. MIN_EVERY .. '..' .. MAX_EVERY .. ', anchored now; 54000 is 15 min) or due_tick / due_in_ticks (once)'
  M.schema = {
    reminder_add = {message='1..300 characters: what to review (the line recipients get)', every_ticks=WHEN, due_tick='a game tick (once)', due_in_ticks='ticks from now (once)',
      recipients='optional: names (sol, luna) or "team"; default yourself', name='optional 1..40 characters', board_item='optional board item number',
      surface='optional surface name', serves='optional {name, position, surface?, radius?}: the machine it serves (an entity of that name of ours within 1 tile of position, on surface, default yours), or with radius 2..64 any such machine within it; checked about once a game minute and when read: serves {count, last_seen_tick, gone, gone_tick, line} in the read, and a line naming it when none is there (the job\'s line and the line it sends name one whose machine is gone)', expires_tick='optional tick it switches off', for_ticks='optional: switches off that many ticks from now', enabled='optional boolean (default true)',
      wake='optional false: its line waits for the recipient\'s next reply and wakes no sleep or wait (a routine check; urgent alerts are apart and still wake)',
      steps='optional checklist: 1..12 steps, each a name (1..80 characters) or {name, every_ticks? (1800..: its line again that often while it is a recipient\'s next step)}; a run goes out with the next unfinished step, each recipient records steps with reminder_ack (the run is done for them when every step is recorded; a one-time job is done when every recipient\'s is)',
      returns='added (its id), reminder {id, owner, recipients, message, cadence, next_due_tick, next_due_in_s, states, line}. A reminder only sends lines: when due, each recipient gets one private line in their next reply (a tell from "reminder #N", waking a sleep as a tell does); while one has not acknowledged it, later runs fold into it (missed); at 2 runs missed its owner gets one line naming who, the last result and the reminder_edit call that changes the recipients (once until that recipient acknowledges or the recipients change). It never acts in the game; at most 12 a teammate, 48 in all'},
    reminder_edit = {id='reminder number', message='as reminder_add', every_ticks='as reminder_add (sets the anchor now)', due_tick='as reminder_add', due_in_ticks='as reminder_add', recipients='as reminder_add', name='as reminder_add; false clears it',
      board_item='as reminder_add; false clears it', surface='as reminder_add; false clears it', serves='as reminder_add; false clears it', expires_tick='as reminder_add; false clears it', for_ticks='as reminder_add', enabled='boolean', wake='as reminder_add', steps='as reminder_add; false clears them; a change starts every recipient\'s progress again', returns='edited, reminder; its owner only'},
    reminder_remove = {id='reminder number', returns='removed, was; its owner only'},
    reminder_ack = {id='reminder number', result='optional 1..1000 characters: what the review found, kept whole (shown with the job and on the site)',
      evidence='optional {metric?, tick?, decision?, result?, owner?, next_check?}, as board_post evidence: kept with the reminder (the newest 5) and shown with it',
      step='a checklist: the step number this records (default: your next unfinished step)', leave='a checklist: true sets it aside (an emergency): no step lines until resume; your progress kept',
      resume='a checklist: true takes it up again at your next unfinished step (any step\'s ack does too)',
      next_in_ticks='optional 60..: the next run that many ticks from now (that run only), with the ack', every_ticks='optional, its owner: a new cadence from now (e.g. 18000, 5 min), with the ack',
      returns='acknowledged, was_pending, missed (runs folded into the line), missed_runs (how many and the ticks of the first and last), note, reminder; without next_in_ticks or every_ticks the cadence stays as it is. A checklist: recorded (the step), step_name, next_step and done (N of M steps) while steps remain; acknowledged and checklist_done once every step is recorded; left and at_step with leave'},
    reminder_snooze = {id='reminder number', ticks='60..: the next run that many ticks from now (the next run only)', returns='snoozed, next_due_tick, reminder; its owner or a recipient'},
    reminders = {all='optional true: the whole team\'s; default yours and those addressed to you', pending='optional true: only what waits for you now, each with its next unfinished step and how long it has waited (lines)', returns='reminders [{id, name, owner, recipients, message, cadence, every_ticks, due_tick, enabled, next_due_tick, next_due_in_s, last_fired_tick, last_result, result_by, result_tick, result_age_s, board_item, surface, serves {count, last_seen_tick, gone, gone_tick, line}, expires_tick, states (each recipient: scheduled, pending, overdue, acknowledged, left at step N; runs missed, the owner told; steps done), missed {name: runs}, yours, steps [{step, name, every_ticks, result, done_ago_s}] and next_step (a checklist, your progress), line}], lines, count. Read only'},
  }
  return M
end
