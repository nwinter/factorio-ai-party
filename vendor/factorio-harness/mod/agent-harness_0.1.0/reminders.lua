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
-- Backup (d20 batch70 AF2, viewer Aurora: "Freight review shows 12 missed runs despite newer freight work in chat"; #107
-- went to its owner alone, so no one was told): an optional teammate told once when a recipient misses a run (a second
-- run comes while the first waits), until that recipient acknowledges; the backup (or the owner) records a result for a
-- recipient with reminder_ack {id, for, result}. Each recipient's latest result is kept (results): acknowledged when and
-- with what, by whom, or waiting since when with the runs missed.
-- (d22 batch94 BD1, viewer Aurora site:4267-4268 on #114, Astra's equipment reminder: "keep gaps open until fixed or
-- explicitly deferred"; "Could gear checks run after unlocks, deliveries and respawns?"; "live research and stock checks")
-- - An ack's state: done with a result; open with none, or with gap_items (what the recipient names as missing);
--   deferred with deferred (true or the reason). The state shows in states, latest and the recipient's pending read.
-- - gap_items: beside each, read when the reminder is read: the recipes that make it and whether they are enabled, the
--   technologies that unlock them and whether they are researched, and how many are in the logistic networks of the
--   recipient's surface (a platform: its hub) by quality, and in the recipient's inventory. Facts only; nothing refused.
-- - gear: true on an ack keeps the recipient's own armor and grid read beside the result (what they see in their armor).
-- - on {research, delivered, respawn}: runs besides the cadence, as the owner sets them: a technology researched (any,
--   named ones, or "equipment": one unlocking a recipe that makes equipment or armor), an item delivered (a cargo pod
--   received by a landing pad, or a rocket's pod reaching a platform's hub; the items named or "equipment"; on a
--   surface, default the reminder's), a recipient's own respawn (that recipient's run only). A recipient whose line
--   waits gets no second line and no missed run: the trigger is counted beside the wait.
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
  -- (BD1) the runs besides the cadence, as text
  local function on_text(job)
    local o = job.on
    if not o then return nil end
    local parts = {}
    if o.research then
      parts[#parts+1] = o.research == true and 'a technology researched' or o.research == 'equipment' and 'a technology unlocking equipment or armor researched'
        or table.concat(o.research, ', ') .. ' researched'
    end
    if o.delivered then
      local where = o.delivered.surface or job.surface
      parts[#parts+1] = string.format('%s delivered to a landing pad or a platform\'s hub%s', o.delivered.items == 'equipment' and 'equipment or armor'
        or o.delivered.items and table.concat(o.delivered.items, ', ') or 'any item', where and ' on ' .. where or '')
    end
    if o.respawn then parts[#parts+1] = 'a recipient\'s respawn (their run only)' end
    return table.concat(parts, '; ')
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
    if job.acked and job.acked[name] then
      -- (BD1) deferred, or open (no result, or gap items named), stays open until an ack with a result and no gap
      local res = job.results and job.results[name]
      if res and res.deferred then
        return 'deferred (open' .. (res.gap and ', gap: ' .. table.concat(res.gap, ', ') or '') .. ')' .. (type(res.deferred) == 'string' and ': ' .. res.deferred or '')
      end
      if res and res.gap then return 'open (gap: ' .. table.concat(res.gap, ', ') .. ')' end
      local legacy = not res and job.result_by == name and job.result_tick == job.acked[name] and job.last_result
      if not job.steps and not (res and res.result) and not legacy then return 'open (acknowledged without a result)' end
      -- (d22 batch90 AZ2) an ack is not the linked board item done: said while that item has not changed since
      local i = job.board_item and api.item and api.item(job.board_item)
      if i and i.status ~= 'done' and i.status ~= 'dropped' and (i.updated_tick or i.created_tick or 0) <= job.acked[name] then
        return string.format('acknowledged, not done: board #%d (%s) unchanged since the ack, last change %s ago', i.id or job.board_item,
          tostring(i.status), ago(game.tick - (i.updated_tick or i.created_tick or 0)))
      end
      return 'done'
    end
    return job.enabled and 'scheduled' or (job.done and 'done' or 'off')
  end
  -- (AF2) one recipient's latest: acknowledged (when, with what, by whom) or waiting since when, runs missed.
  local function latest(job, name)
    local st, pd = status_of(job, name)
    local res = job.results and job.results[name]
    local acked = job.acked and job.acked[name]
    -- a job from before results were kept: its last result when this recipient gave it
    if not res and acked and job.result_by == name and job.result_tick == acked then res = {result=job.last_result, tick=acked} end
    local r = {name=name, state=st, acked_tick=res and res.tick or acked, result=res and res.result or nil, by=res and res.by ~= name and res.by or nil}
    r.acked_ago_s = r.acked_tick and math.floor((game.tick - r.acked_tick) / 60) or nil
    if pd then
      r.waiting_since_tick, r.waiting_s, r.missed = pd.tick, math.floor((game.tick - pd.tick) / 60), pd.missed > 0 and pd.missed or nil
      r.first_missed_tick, r.backup_told_tick = pd.first_missed, pd.told_backup
      -- (BD1) why this run came (a trigger), and triggers while it waits (no second line, no missed run)
      r.run_on = pd.why
      if pd.triggers then r.triggers_while_waiting = pd.triggers; r.last_trigger = pd.trigger_last and pd.trigger_last.why end
    end
    -- (BD1) deferred, the gap named with its facts read now, the recipient's own armor read with the ack
    local extra = {}
    if res and res.deferred then r.deferred = res.deferred end
    if res and res.gap then
      r.gap = res.gap
      local ok, rows = pcall(function() return api.gap_facts and api.gap_facts(name, res.gap) end)
      if ok and rows then
        r.gap_facts = rows
        for _, x in ipairs(rows) do extra[#extra+1] = 'gap ' .. x.line end
      elseif not ok then r.gap_facts_error = tostring(rows) end
      if not (ok and rows) then extra[#extra+1] = 'gap: ' .. table.concat(res.gap, ', ') end
    end
    if res and res.gear then
      r.gear, r.gear_tick = res.gear.line, res.gear.tick
      extra[#extra+1] = string.format('their armor at the ack (tick %d): %s', res.gear.tick, res.gear.line)
    end
    local short = r.result and (#r.result > 120 and r.result:sub(1, 117) .. '...' or r.result)
    local last = r.acked_tick and string.format('last acknowledged %s ago%s%s', ago(game.tick - r.acked_tick), r.by and ' by ' .. r.by .. ' for them' or '',
      short and ': ' .. short or ' (no result given)') or 'never acknowledged'
    if pd then
      r.line = string.format('%s: waiting since tick %d (%s)%s%s%s; %s', name, pd.tick, ago(game.tick - pd.tick), pd.why and ', this run on ' .. pd.why or '',
        pd.missed > 0 and ', ' .. missed_text(pd) .. (pd.told_backup and ', backup ' .. tostring(job.backup) .. ' told' or '') or '',
        pd.triggers and string.format(', %d trigger%s since (the last: %s)', pd.triggers, pd.triggers == 1 and '' or 's', pd.trigger_last and pd.trigger_last.why or '?') or '', last)
    else r.line = string.format('%s: %s; %s', name, st, last) end
    if #extra > 0 then r.line = r.line .. '; ' .. table.concat(extra, '; ') end
    return r
  end
  local function row(job, me)
    local r = {id=job.id, name=job.name, owner=job.owner, recipients=table.concat(job.recipients, ', '), message=job.message,
      cadence=cadence(job), every_ticks=job.every, due_tick=not job.every and job.due or nil, enabled=job.enabled, wake=job.quiet and 'false: delivered with the next reply, wakes no wait' or nil,
      next_due_tick=job.enabled and job.next_due or nil, next_due_in_s=job.enabled and math.max(0, math.floor((job.next_due - game.tick) / 60)) or nil,
      last_fired_tick=job.last_fired, last_result=job.last_result, result_by=job.result_by, result_tick=job.result_tick,
      result_age_s=job.result_tick and math.floor((game.tick - job.result_tick) / 60) or nil,
      board_item=job.board_item, surface=job.surface, expires_tick=job.expires, done=(job.done and not job.enabled) or nil, serves=job.serves and Sv().view(job.serves) or nil,
      on=on_text(job), last_trigger=job.last_trigger}
    -- (B2) the evidence given with acknowledgments, newest last
    if job.evidence and #job.evidence > 0 then
      r.evidence = {}
      for k, e in ipairs(job.evidence) do r.evidence[k] = Ev().line(e) end
    end
    local states = {}
    for _, n in ipairs(targets(job)) do
      local st, pd = status_of(job, n)
      states[#states+1] = n .. ' ' .. st .. (pd and pd.missed > 0 and string.format(' (%s%s%s)', missed_text(pd),
        pd.told_owner and ', the owner told' or '', pd.told_backup and ', backup ' .. tostring(job.backup) .. ' told' or '') or '')
      if pd and pd.missed > 0 then r.missed = r.missed or {}; r.missed[n] = pd.missed end
    end
    r.states = table.concat(states, '; ')
    if me then r.yours = status_of(job, me) end
    -- (AF2) the backup, and each recipient's latest result or wait
    r.backup = job.backup
    r.latest = {}
    for _, n in ipairs(targets(job)) do r.latest[#r.latest+1] = latest(job, n) end
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
    local parts = {string.format('#%d %sby %s (%s%s, to %s): %s', job.id, job.name and job.name .. ', ' or '', job.owner, cadence(job),
      r.on and ', and on ' .. r.on or '', r.recipients, job.message)}
    if job.enabled then parts[#parts+1] = 'next in ' .. ago(job.next_due - game.tick) else parts[#parts+1] = job.done and 'done' or 'off' end
    if job.steps then parts[#parts+1] = string.format('checklist of %d steps%s', #job.steps, r.next_step and ', yours next: ' .. r.next_step or '') end
    if job.last_result then parts[#parts+1] = string.format('last result %s ago: %s', ago(game.tick - job.result_tick), job.last_result) end
    if r.evidence then parts[#parts+1] = 'evidence ' .. r.evidence[#r.evidence] end
    if job.serves and Sv().gone(job.serves) then parts[#parts+1] = Sv().line(job.serves) end
    if job.backup then parts[#parts+1] = 'backup ' .. job.backup end
    parts[#parts+1] = r.states
    local ll = {}
    for _, l in ipairs(r.latest) do ll[#ll+1] = l.line end
    parts[#parts+1] = 'latest: ' .. table.concat(ll, ' | ')
    r.line = table.concat(parts, '; ')
    return r
  end
  -- (d24 batch154, the batch149 review's bug 7) a missing id: removed by whom and when (the last GONE_KEPT), and the
  -- keep rule; or never set.
  local GONE_KEPT = 64
  local function missing(id)
    local s = store()
    local head = 'no reminder #' .. tostring(id)
    local rule = 'a reminder is kept until its owner (or the operator) removes it with reminder_remove; one that expired or ran its one due stays, switched off; reminders lists them'
    for i = #(s.gone or {}), 1, -1 do
      local x = s.gone[i]
      if x.id == id then
        return string.format('%s: "%s" (%s\'s) removed by %s %s ago (tick %d); %s', head, x.name, tostring(x.owner), tostring(x.by), ago(game.tick - x.tick), x.tick, rule)
      end
    end
    if type(id) == 'number' and (id > s.seq or id < 1) then return string.format('%s: none set with that number (the last set is #%d)', head, s.seq) end
    return string.format('%s: set and since removed, before the last %d removals kept; %s', head, GONE_KEPT, rule)
  end
  local function find(id)
    assert(type(id) == 'number' and id == math.floor(id), 'id is a reminder number (reminders lists them)')
    local job = store().jobs[id]
    if not job then error(missing(id), 0) end
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
    -- (AF2) backup: one teammate told when a recipient misses a run; false clears it
    if a.backup ~= nil then
      if a.backup == false then job.backup = nil
      else
        assert(type(a.backup) == 'string', 'backup: one teammate\'s name, or false for none')
        local w = a.backup:gsub('^@', '')
        assert(not TEAM[w:lower()], 'backup: one teammate\'s name')
        local name = api.resolve(w)
        assert(name ~= 'operator', 'backup: a teammate')
        job.backup = name
      end
      for _, pd in pairs(job.pending or {}) do pd.told_backup = nil end
    end
    if a.serves ~= nil then job.serves = a.serves ~= false and Sv().parse(a.serves, p) or nil end
    -- (BD1) on: runs besides the cadence; false clears them
    if a.on ~= nil then
      if a.on == false then job.on = nil
      else
        assert(type(a.on) == 'table', 'on: {research?, delivered?, respawn?}, or false for none')
        for k in pairs(a.on) do assert(k == 'research' or k == 'delivered' or k == 'respawn', 'on takes research, delivered and respawn, not ' .. tostring(k)) end
        local o = {}
        local r = a.on.research
        if r == true or r == 'equipment' then o.research = r
        elseif r ~= nil and r ~= false then
          if type(r) == 'string' then r = {r} end
          assert(type(r) == 'table' and #r >= 1 and #r <= 16, 'on.research: true (any), "equipment", or 1..16 technology names')
          o.research = {}
          for i, n in ipairs(r) do
            o.research[i] = one_line(n, 80, 'on.research name')
            assert(not api.technology_known or api.technology_known(o.research[i]), 'on.research: no technology ' .. o.research[i])
          end
        end
        local d = a.on.delivered
        if d ~= nil and d ~= false then
          if d == true then d = {} end
          assert(type(d) == 'table', 'on.delivered: true, or {items?, surface?}')
          for k in pairs(d) do assert(k == 'items' or k == 'surface', 'on.delivered takes items and surface, not ' .. tostring(k)) end
          local od = {}
          if d.items == 'equipment' then od.items = 'equipment'
          elseif d.items ~= nil then
            local it = type(d.items) == 'string' and {d.items} or d.items
            assert(type(it) == 'table' and #it >= 1 and #it <= 16, 'on.delivered.items: "equipment" or 1..16 item names')
            od.items = {}
            for i, n in ipairs(it) do
              od.items[i] = one_line(n, 80, 'on.delivered item')
              assert(not api.item_known or api.item_known(od.items[i]), 'on.delivered: no item ' .. od.items[i])
            end
          end
          if d.surface ~= nil then od.surface = one_line(d.surface, 40, 'on.delivered.surface') end
          o.delivered = od
        end
        if a.on.respawn ~= nil and a.on.respawn ~= false then assert(a.on.respawn == true, 'on.respawn: true or false'); o.respawn = true end
        assert(next(o), 'on: research, delivered or respawn')
        job.on = o
      end
    end
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
      -- (d24 batch177 QT1, viewer Aurora 17:20: #151, a one-time job that ran and was then edited to every 20m and
      -- enabled, kept done and the site hid it from Active) done belongs to a job that is off
      if a.enabled then job.done = nil end
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
    if job.enabled then job.done = nil end
    return {edited=job.id, reminder=row(job, api.who(p))}
  end
  function M.handlers.reminder_remove(p, a)
    local job = find(a.id)
    owner_only(p, job)
    local s = store()
    s.jobs[job.id] = nil
    s.gone = s.gone or {}
    s.gone[#s.gone+1] = {id=job.id, name=tostring(job.name or job.message or ''):sub(1, 60), owner=job.owner, by=api.who(p), tick=game.tick}
    while #s.gone > GONE_KEPT do table.remove(s.gone, 1) end
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
    -- (AF2) for: the backup (or the owner) records a result for a recipient
    local by = me
    if a['for'] ~= nil then
      assert(type(a['for']) == 'string', 'for: a recipient\'s name')
      local name = api.resolve((a['for']:gsub('^@', '')))
      assert(me == job.backup or me == job.owner or me == 'operator', 'for: only reminder #' .. job.id .. '\'s backup (' .. tostring(job.backup or 'none') .. ') or its owner records a result for a recipient')
      local listed = false
      for _, n in ipairs(targets(job)) do if n == name then listed = true end end
      assert(listed, name .. ' is not a recipient of reminder #' .. job.id)
      assert(not job.steps, 'for: a checklist is recorded by each recipient')
      me = name
    end
    local result = a.result ~= nil and one_line(a.result, MAX_RESULT, 'result') or nil
    local evidence = a.evidence ~= nil and Ev().check(a.evidence, me) or nil
    -- (BD1) deferred (true or the reason), gap_items (what is missing), gear (your own armor read kept with the ack)
    local deferred, gap, gear
    if a.deferred ~= nil and a.deferred ~= false then
      deferred = a.deferred == true or one_line(a.deferred, MAX_TEXT, 'deferred')
    end
    if a.gap_items ~= nil and a.gap_items ~= false then gap = api.check_items and api.check_items(a.gap_items) or a.gap_items end
    if a.gear ~= nil then
      assert(type(a.gear) == 'boolean', 'gear must be true or false')
      assert(not a.gear or by == me, 'gear: your own armor only (an ack for a recipient takes no gear)')
      if a.gear then
        local ok, line = pcall(function() return api.gear and api.gear(me) end)
        gear = {line=ok and line or ('the armor read failed: ' .. tostring(line)), tick=game.tick}
      end
    end
    assert(not (job.steps and (deferred or gap or gear)), 'deferred, gap_items and gear are for a reminder without steps')
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
        job.results = job.results or {}
        job.results[me] = {result=result and string.format('step %d "%s": %s', step, job.steps[step].name, result) or nil, tick=game.tick}
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
    job.results = job.results or {}
    job.results[me] = {result=result, tick=game.tick, by=by ~= me and by or nil, deferred=deferred, gap=gap, gear=gear}
    if result then job.last_result = result; job.result_by = by; job.result_tick = game.tick end
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
    local mine = latest(job, me)
    return {acknowledged=job.id, ['for']=by ~= me and me or nil, was_pending=was and true or false, missed=was and was.missed > 0 and was.missed or nil, missed_runs=missed_text(was),
      state=mine.state, gap_facts=mine.gap_facts, gear=mine.gear, note=note, reminder=row(job, by)}
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
    -- (d22 batch90 AZ3: reminders {id} refused 21 times in s55-57; the whole read it fell back to was 30-98 KB) one job
    if a.id ~= nil then
      assert(type(a.id) == 'number', 'id is a reminder number')
      local job = store().jobs[a.id]
      if not job then error(missing(a.id), 0) end
      if job.serves then pcall(Sv().check, job.serves) end
      local r = row(job, me)
      return {reminders={r}, lines={r.line}, count=1, tick=game.tick}
    end
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
      -- (BD1) and what you acknowledged that stays open: no result, gap items named, or deferred
      local open = {}
      for _, id in ipairs(ids) do
        local job = store().jobs[id]
        if not (job.pending and job.pending[me]) and job.acked and job.acked[me] then
          local st = status_of(job, me)
          if st:find('^open') or st:find('^deferred') then
            open[#open+1] = string.format('#%d %s: %s, acknowledged %s ago', id, job.name or 'review', st, ago(game.tick - job.acked[me]))
          end
        end
      end
      return {reminders=out, lines=lines, count=#out, tick=game.tick, open=#open > 0 and open or nil, note=#out == 0 and 'nothing waits for you' or nil}
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
  local function deliver(job, name, index, why)
    local text = string.format('%s (%s, %s%s): %s; reminder_ack {id: %d, result} records the result',
      job.name or 'review', job.owner, cadence(job), job.board_item and ', board #' .. job.board_item or '', job.message, job.id)
    local nx = job.steps and next_step(job, name)
    if nx then
      text = string.format('%s (%s, %s%s): %s; checklist, next %s (%d of %d done); reminder_ack {id: %d, result} records it',
        job.name or 'review', job.owner, cadence(job), job.board_item and ', board #' .. job.board_item or '', job.message, step_text(job, nx),
        steps_done(job, name), #job.steps, job.id)
    end
    if job.serves and Sv().gone(job.serves) then text = text .. '; ' .. Sv().line(job.serves) end
    if why then text = text .. '; this run on ' .. why end
    api.deliver(index, {seq='reminder', tick=game.tick, from='reminder #' .. job.id, text=text, fyi=job.quiet or nil})
  end
  -- One recipient's run: its line, and the wait for its ack.
  local function start_run(job, name, index, why)
    if job.steps then job.progress = job.progress or {}; job.progress[name] = {done={}, nudged=game.tick} end
    deliver(job, name, index, why)
    job.pending[name] = {tick=game.tick, missed=0, why=why}
    job.acked[name] = nil
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
        -- (AF2) a run missed: one line to the backup, once until that recipient acknowledges
        if job.backup and not pd.told_backup and name ~= job.backup and index[job.backup] then
          pd.told_backup = game.tick
          local res = job.results and job.results[name]
          api.deliver(index[job.backup], {seq='reminder', tick=game.tick, from='reminder #' .. job.id,
            text=string.format('%s missed a run of reminder #%d %s (%s\'s, %s; you are its backup): not acknowledged since tick %d (%s ago), %s; %s\'s last result: %s; reminder_ack {id: %d, for: "%s", result} records one for them',
              name, job.id, job.name or 'review', job.owner, cadence(job), pd.tick, ago(game.tick - pd.tick), missed_text(pd), name,
              res and res.result and string.format('%s (%s ago)', res.result, ago(game.tick - res.tick)) or (job.result_by == name and job.last_result and string.format('%s (%s ago)', job.last_result, ago(game.tick - (job.result_tick or game.tick)))) or 'none kept',
              job.id, name)})
        end
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
        start_run(job, name, index[name])
      end
    end
    job.last_fired = game.tick
    if job.every then job.next_due = next_after(job, game.tick)
    else job.enabled = false; job.done = not job.steps or nil end
  end
  -- (BD1) A trigger: what it matches on a job's on, as text for the line (nil: no match).
  local function matches(job, o, kind, info)
    if kind == 'research' and o.research then
      local name = tostring(info.name)
      if o.research == true then return name .. ' researched' end
      if o.research == 'equipment' then return info.gear and string.format('%s researched (it unlocks %s)', name, info.gear) or nil end
      local base = name:gsub('%-%d+$', '')
      for _, n in ipairs(o.research) do if n == name or n == base then return name .. ' researched' end end
    elseif kind == 'delivered' and o.delivered then
      local where = o.delivered.surface or job.surface
      if where and where ~= info.surface and where ~= info.platform then return nil end
      local hit = {}
      for item, n in pairs(info.cargo or {}) do
        local ok = o.delivered.items == nil
        if o.delivered.items == 'equipment' then ok = api.is_gear ~= nil and api.is_gear(item) == true
        elseif type(o.delivered.items) == 'table' then for _, x in ipairs(o.delivered.items) do if x == item then ok = true end end end
        if ok then hit[#hit+1] = item .. '*' .. tostring(n) end
      end
      if #hit == 0 then return nil end
      table.sort(hit)
      return string.format('%s delivered to %s', table.concat(hit, ' '), tostring(info.where or info.surface))
    elseif kind == 'respawn' and o.respawn then return tostring(info.name) .. ' respawned' end
    return nil
  end
  -- trigger(kind, info): research {name, gear (the equipment it unlocks, text)}, delivered {surface, platform?, cargo
  -- {item: count}, where}, respawn {name}. Each enabled job whose on matches: a run for its recipients (respawn: that
  -- recipient only); one whose line waits gets none, the trigger counted beside the wait. Returns the runs started.
  function M.trigger(kind, info)
    local s = api.state().reminders
    if not s then return 0 end
    local n, index = 0, nil
    for _, job in pairs(s.jobs) do
      local why = job.enabled and job.on and matches(job, job.on, kind, info or {})
      if why then
        if not index then index = {}; for _, a in ipairs(api.agents()) do index[a.name] = a.index end end
        job.pending = job.pending or {}; job.acked = job.acked or {}
        job.last_trigger = {tick=game.tick, why=why}
        for _, name in ipairs(targets(job)) do
          if index[name] and (kind ~= 'respawn' or name == info.name) then
            local pd = job.pending[name]
            if pd then pd.triggers = (pd.triggers or 0) + 1; pd.trigger_last = {tick=game.tick, why=why}
            else start_run(job, name, index[name], why); n = n + 1 end
          end
        end
      end
    end
    return n
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
      surface='optional surface name', backup='optional: one teammate told when a recipient misses a run (a second run comes while the first waits), once until that recipient acknowledges; it may record a result for them (reminder_ack {id, for, result})', serves='optional {name, position, surface?, radius?}: the machine it serves (an entity of that name of ours within 1 tile of position, on surface, default yours), or with radius 2..64 any such machine within it; checked about once a game minute and when read: serves {count, last_seen_tick, gone, gone_tick, line} in the read, and a line naming it when none is there (the job\'s line and the line it sends name one whose machine is gone)', expires_tick='optional tick it switches off', for_ticks='optional: switches off that many ticks from now', enabled='optional boolean (default true)',
      wake='optional false: its line waits for the recipient\'s next reply and wakes no sleep or wait (a routine check; urgent alerts are apart and still wake)',
      on='optional {research?: true (any) | "equipment" (a technology unlocking a recipe that makes equipment or armor) | [technology names], delivered?: true | {items?: "equipment" | [item names], surface? (a planet or platform name; default the reminder\'s surface, else any)} (a cargo pod received by a landing pad, or a rocket\'s pod reaching a platform\'s hub), respawn?: true (a recipient\'s respawn, their run only)}: runs besides the cadence; a recipient whose line waits gets no second line and no missed run (the trigger is counted beside the wait)', 
      steps='optional checklist: 1..12 steps, each a name (1..80 characters) or {name, every_ticks? (1800..: its line again that often while it is a recipient\'s next step)}; a run goes out with the next unfinished step, each recipient records steps with reminder_ack (the run is done for them when every step is recorded; a one-time job is done when every recipient\'s is)',
      returns='added (its id), reminder {id, owner, recipients, message, cadence, next_due_tick, next_due_in_s, states, line}. A reminder only sends lines: when due, each recipient gets one private line in their next reply (a tell from "reminder #N", waking a sleep as a tell does); while one has not acknowledged it, later runs fold into it (missed); at 2 runs missed its owner gets one line naming who, the last result and the reminder_edit call that changes the recipients (once until that recipient acknowledges or the recipients change). It never acts in the game; at most 12 a teammate, 48 in all'},
    reminder_edit = {id='reminder number', message='as reminder_add', every_ticks='as reminder_add (sets the anchor now)', due_tick='as reminder_add', due_in_ticks='as reminder_add', recipients='as reminder_add', name='as reminder_add; false clears it',
      board_item='as reminder_add; false clears it', surface='as reminder_add; false clears it', backup='as reminder_add; false clears it', serves='as reminder_add; false clears it', expires_tick='as reminder_add; false clears it', for_ticks='as reminder_add', enabled='boolean', wake='as reminder_add', on='as reminder_add; false clears them', steps='as reminder_add; false clears them; a change starts every recipient\'s progress again', returns='edited, reminder; its owner only'},
    reminder_remove = {id='reminder number', returns='removed, was; its owner only'},
    reminder_ack = {id='reminder number', ['for']='optional, its backup or owner: the recipient this ack and result are for (not a checklist)', result='optional 1..1000 characters: what the review found, kept whole (shown with the job and on the site)',
      evidence='optional {metric?, tick?, decision?, result?, owner?, next_check?}, as board_post evidence: kept with the reminder (the newest 5) and shown with it',
      step='a checklist: the step number this records (default: your next unfinished step)', leave='a checklist: true sets it aside (an emergency): no step lines until resume; your progress kept',
      resume='a checklist: true takes it up again at your next unfinished step (any step\'s ack does too)',
      deferred='optional: true or the reason (1..300 characters): the gap stays open, shown deferred',
      gap_items='optional 1..8 item names: what is missing; the gap stays open, and each reminder read gives beside it the recipes that make it (enabled?), the technologies that unlock them (researched?), how many are in the logistic networks of your surface by quality (a platform: its hub too) and in your inventory',
      gear='optional true: your own armor and its grid (equipment by quality, free cells, shield, battery) read now and kept with the ack; not with for',
      next_in_ticks='optional 60..: the next run that many ticks from now (that run only), with the ack', every_ticks='optional, its owner: a new cadence from now (e.g. 18000, 5 min), with the ack',
      returns='acknowledged, was_pending, missed (runs folded into the line), missed_runs (how many and the ticks of the first and last), state (done with a result; open without one or with gap_items; deferred), gap_facts, gear, note, reminder; without next_in_ticks or every_ticks the cadence stays as it is. A checklist: recorded (the step), step_name, next_step and done (N of M steps) while steps remain; acknowledged and checklist_done once every step is recorded; left and at_step with leave'},
    reminder_snooze = {id='reminder number', ticks='60..: the next run that many ticks from now (the next run only)', returns='snoozed, next_due_tick, reminder; its owner or a recipient'},
    reminders = {id='optional: one reminder number: that one only (anyone\'s)', all='optional true: the whole team\'s; default yours and those addressed to you', pending='optional true: only what waits for you now, each with its next unfinished step and how long it has waited (lines); open: what you acknowledged that stays open (no result, gap items, deferred)', returns='reminders [{id, name, owner, recipients, message, cadence, every_ticks, due_tick, enabled, next_due_tick, next_due_in_s, last_fired_tick, last_result, result_by, result_tick, result_age_s, board_item, surface, serves {count, last_seen_tick, gone, gone_tick, line}, expires_tick, on (the runs besides the cadence), last_trigger {tick, why}, states (each recipient: scheduled, pending, overdue, done (acknowledged with a result), open (no result, or gap items named), deferred, acknowledged, not done (a board item unchanged since), left at step N; runs missed, the owner told, the backup told; steps done), missed {name: runs}, backup, latest [{name, state, acked_tick, acked_ago_s, result, by (the backup or owner who recorded it for them), waiting_since_tick, waiting_s, missed, first_missed_tick, backup_told_tick, run_on (the trigger of this run), triggers_while_waiting, last_trigger, deferred, gap, gap_facts [{item, recipes [{name, enabled}], technologies [{name, researched}], surface, networks, in_networks {quality: count}, in_hub, held, line}], gear, gear_tick, line}] (each recipient\'s latest result or wait), yours, steps [{step, name, every_ticks, result, done_ago_s}] and next_step (a checklist, your progress), line}], lines, count. Read only'},
  }
  return M
end
