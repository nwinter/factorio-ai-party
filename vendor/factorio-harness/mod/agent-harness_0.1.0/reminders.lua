-- reminders: an agent's reminder and review jobs (viewer Foobator's idea; the design from Astra and Sol, d15 05:16).
-- A job holds a short message, an owner, its recipients (the owner by default, named teammates, or the team), and a
-- cadence in game ticks (every_ticks, anchored at its start) or one due tick. When it is due, each recipient gets one
-- private line in their next reply, as a tell from "reminder #N" (it wakes a sleep as a tell does). While a recipient
-- has not acknowledged it (reminder_ack), further runs fold into that one line (missed), so nothing piles up and an
-- overdue job never fires every tick. ack records a result and leaves the cadence where it is; snooze moves the next
-- run only. A job never acts in the game: no character, action, queue, machine or chat. Alerts stay apart.
-- The state lives in the save, so a rollback restores jobs and ticks together; a job whose next run lies more than
-- one interval past the tick (or whose last run lies after it) is set again from the restored tick.
return function(api)
  local M = {}
  local MAX_JOBS, MAX_OWN, MAX_TEXT, MAX_RESULT = 48, 12, 300, 200
  local MIN_EVERY, MAX_EVERY = 3600, 7 * 24 * 216000
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
  -- The next run on the cadence after `tick` (anchored at job.anchor).
  local function next_after(job, tick)
    local k = math.floor((tick - job.anchor) / job.every) + 1
    return job.anchor + math.max(1, k) * job.every
  end
  local function status_of(job, name)
    local pd = job.pending and job.pending[name]
    if pd then
      local late = job.every or 36000
      return game.tick - pd.tick > late and 'overdue' or 'pending', pd
    end
    if job.acked and job.acked[name] then return 'acknowledged' end
    return job.enabled and 'scheduled' or (job.done and 'done' or 'off')
  end
  local function row(job, me)
    local r = {id=job.id, name=job.name, owner=job.owner, recipients=table.concat(job.recipients, ', '), message=job.message,
      cadence=cadence(job), every_ticks=job.every, due_tick=not job.every and job.due or nil, enabled=job.enabled,
      next_due_tick=job.enabled and job.next_due or nil, next_due_in_s=job.enabled and math.max(0, math.floor((job.next_due - game.tick) / 60)) or nil,
      last_fired_tick=job.last_fired, last_result=job.last_result, result_by=job.result_by, result_tick=job.result_tick,
      result_age_s=job.result_tick and math.floor((game.tick - job.result_tick) / 60) or nil,
      board_item=job.board_item, surface=job.surface, expires_tick=job.expires, done=job.done or nil}
    local states = {}
    for _, n in ipairs(targets(job)) do
      local st, pd = status_of(job, n)
      states[#states+1] = n .. ' ' .. st .. (pd and pd.missed > 0 and string.format(' (%d run%s missed)', pd.missed, pd.missed == 1 and '' or 's') or '')
    end
    r.states = table.concat(states, '; ')
    if me then r.yours = status_of(job, me) end
    local parts = {string.format('#%d %sby %s (%s, to %s): %s', job.id, job.name and job.name .. ', ' or '', job.owner, cadence(job),
      r.recipients, job.message)}
    if job.enabled then parts[#parts+1] = 'next in ' .. ago(job.next_due - game.tick) else parts[#parts+1] = job.done and 'done' or 'off' end
    if job.last_result then parts[#parts+1] = string.format('last result %s ago: %s', ago(game.tick - job.result_tick), job.last_result) end
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
  local function apply(job, a, fresh)
    if a.name ~= nil then job.name = a.name ~= false and one_line(a.name, 40, 'name') or nil end
    if a.message ~= nil or fresh then job.message = one_line(a.message, MAX_TEXT, 'message') end
    if a.recipients ~= nil or fresh then job.recipients = names_of(a.recipients, job.owner) end
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
    if a.expires_tick ~= nil or a.for_ticks ~= nil then
      local e = a.expires_tick or (a.for_ticks and game.tick + ticks_arg(a.for_ticks, 60, 30 * 216000, 'for_ticks'))
      assert(e == false or (type(e) == 'number' and e > game.tick), 'expires_tick must lie after the tick now, or false for none')
      job.expires = e or nil
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
    apply(job, a, true)
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
    apply(job, b, false)
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
    job.pending = job.pending or {}; job.acked = job.acked or {}
    local was = job.pending[me]
    job.pending[me] = nil; job.acked[me] = game.tick
    if result then job.last_result = result; job.result_by = me; job.result_tick = game.tick end
    return {acknowledged=job.id, was_pending=was and true or false, missed=was and was.missed > 0 and was.missed or nil,
      note='the cadence stays as it is', reminder=row(job, me)}
  end
  function M.handlers.reminders(p, a)
    local me = api.who(p)
    assert(a.all == nil or type(a.all) == 'boolean', 'all must be true or false')
    local out, lines = {}, {}
    local ids = {}
    for id in pairs(store().jobs) do ids[#ids+1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do
      local job = store().jobs[id]
      local to_me = false
      for _, n in ipairs(targets(job)) do if n == me then to_me = true end end
      if a.all or job.owner == me or to_me or me == 'operator' then
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
    api.deliver(index, {seq='reminder', tick=game.tick, from='reminder #' .. job.id, text=text})
  end
  local function fire(job)
    local index = {}
    for _, a in ipairs(api.agents()) do index[a.name] = a.index end
    job.pending = job.pending or {}; job.acked = job.acked or {}
    for _, name in ipairs(targets(job)) do
      local pd = job.pending[name]
      if pd then pd.missed = pd.missed + 1
      elseif index[name] then
        deliver(job, name, index[name])
        job.pending[name] = {tick=game.tick, missed=0}
        job.acked[name] = nil
      end
    end
    job.last_fired = game.tick
    if job.every then job.next_due = next_after(job, game.tick)
    else job.enabled = false; job.done = true end
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
      if job.enabled and job.next_due and game.tick >= job.next_due then fire(job) end
    end
  end
  local WHEN = 'every_ticks (a cadence: ' .. MIN_EVERY .. '..' .. MAX_EVERY .. ', anchored now; 54000 is 15 min) or due_tick / due_in_ticks (once)'
  M.schema = {
    reminder_add = {message='1..300 characters: what to review (the line recipients get)', every_ticks=WHEN, due_tick='a game tick (once)', due_in_ticks='ticks from now (once)',
      recipients='optional: names (sol, luna) or "team"; default yourself', name='optional 1..40 characters', board_item='optional board item number',
      surface='optional surface name', expires_tick='optional tick it switches off', for_ticks='optional: switches off that many ticks from now', enabled='optional boolean (default true)',
      returns='added (its id), reminder {id, owner, recipients, message, cadence, next_due_tick, next_due_in_s, states, line}. A reminder only sends lines: when due, each recipient gets one private line in their next reply (a tell from "reminder #N", waking a sleep as a tell does); while one has not acknowledged it, later runs fold into it (missed). It never acts in the game; at most 12 a teammate, 48 in all'},
    reminder_edit = {id='reminder number', message='as reminder_add', every_ticks='as reminder_add (sets the anchor now)', due_tick='as reminder_add', due_in_ticks='as reminder_add', recipients='as reminder_add', name='as reminder_add; false clears it',
      board_item='as reminder_add; false clears it', surface='as reminder_add; false clears it', expires_tick='as reminder_add; false clears it', for_ticks='as reminder_add', enabled='boolean', returns='edited, reminder; its owner only'},
    reminder_remove = {id='reminder number', returns='removed, was; its owner only'},
    reminder_ack = {id='reminder number', result='optional 1..200 characters: what the review found (shown with the job and on the site)', returns='acknowledged, was_pending, missed (runs folded into the line), reminder; the cadence stays as it is'},
    reminder_snooze = {id='reminder number', ticks='60..: the next run that many ticks from now (the next run only)', returns='snoozed, next_due_tick, reminder; its owner or a recipient'},
    reminders = {all='optional true: the whole team\'s; default yours and those addressed to you', returns='reminders [{id, name, owner, recipients, message, cadence, every_ticks, due_tick, enabled, next_due_tick, next_due_in_s, last_fired_tick, last_result, result_by, result_tick, result_age_s, board_item, surface, expires_tick, states (each recipient: scheduled, pending, overdue, acknowledged; runs missed), yours, line}], lines, count. Read only'},
  }
  return M
end
