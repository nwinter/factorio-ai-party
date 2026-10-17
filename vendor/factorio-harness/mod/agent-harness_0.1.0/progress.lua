-- Progress on owned board items, from the game (d17 batch15 Group C, Sol 07:53 and Astra 07:53: tasks sat unchanged
-- while their owners did other things, and nothing showed it). Facts only; nothing reassigns.
-- A check of each owned active item (a task, request or project with an owner) every CHECK game ticks (10 min),
-- one due item a call: what the game shows changed since the last check (our entities in the item's area, or else in
-- its owner's active claims; the planet totals of the items it needs; shipment lines of platforms it names; its own
-- board edits and notes), the age of its last board change, and the owner's repeated failed and no-effect actions
-- since then. An item with none of that is unchanged; unchanged across 2 checks: stalled, unless its owner is in a
-- wait (a sleep, wait step, wait_until) or has a queue running: waiting.
-- - board_progress: those facts per item, with the 20-minute rule for a stalled one (anyone may take it once its owner
--   has made no request for 20 min) and how long since the owner's last request;
-- - board_critical: blocked items ranked by how many open items wait on them (blocked_by and parent, through chains),
--   those the team plan names (#id) first, with what each waits on; and the agents standing or waiting now;
-- - every check, one line in the owner's next reply (team.alerts): progress seen, and the item's next action or blocker
--   as last written (its last note, a project's next step), or that none is written.
return function(api)
  local M = {}
  M.CHECK, M.STALL, M.MAX_LINES = 36000, 2, 30
  local OWNED = {task=true, request=true, project=true}
  local LIVE = {claimed=true, doing=true, blocked=true, open=true}
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  -- what moves through an area without being built there
  local MOVING = {'logistic-robot', 'construction-robot', 'character', 'car', 'spider-vehicle', 'locomotive', 'cargo-wagon', 'fluid-wagon',
    'artillery-wagon', 'item-request-proxy', 'cargo-pod', 'combat-robot'}
  local function ago(t)
    local s = math.floor(t / 60)
    if s < 60 then return s .. 's' end
    if s < 3600 then return string.format('%dm%02ds', math.floor(s / 60), s % 60) end
    return string.format('%dh%02dm', math.floor(s / 3600), math.floor(s / 60) % 60)
  end
  local function store()
    local s = api.state()
    s.progress = s.progress or {items={}, lines={}, rr=0}
    return s.progress
  end
  local function focus_store() local st = store(); st.focus = st.focus or {}; return st.focus end
  local function step_of(i, step)
    if type(step) == 'number' and i.steps then
      for _, s in ipairs(i.steps) do if s.n == step then return s end end
    end
  end
  local function owned(i) return OWNED[i.kind] and LIVE[i.status] and i.owner and i.owner ~= 'operator' end
  -- The areas the game is read in: the item's own, else its owner's active claims (at most 4).
  local function areas(i)
    local out = {}
    if i.area then out[1] = {area=i.area, surface=i.surface or api.owner_surface(i.owner), what='its area'} end
    for _, a in ipairs(i.areas or {}) do if #out < 4 then out[#out+1] = {area=a, surface=api.owner_surface(i.owner), what='its areas'} end end
    if #out == 0 then
      for _, c in pairs(api.items()) do
        if c.kind == 'claim' and c.owner == i.owner and LIVE[c.status] and c.area and #out < 4 then
          out[#out+1] = {area=c.area, surface=api.claim_surface(c), what='claim #' .. c.id}
        end
      end
    end
    return out
  end
  local function built(list)
    local n = 0
    for _, a in ipairs(list) do
      local s = a.surface and game.get_surface(a.surface)
      local lt, rb = a.area.left_top, a.area.right_bottom
      if s and (rb.x - lt.x) * (rb.y - lt.y) <= 512 * 512 then
        n = n + (try(function() return s.count_entities_filtered{area={{lt.x, lt.y}, {rb.x, rb.y}}, force=api.force(), type=MOVING, invert=true} end) or 0)
      end
    end
    return n
  end
  -- The needs with item names: {name, count (nil: any)}, at most 3.
  local function need_names(i)
    local out = {}
    if type(i.needs) == 'table' then
      for _, n in ipairs(i.needs) do
        local name = type(n) == 'table' and n.name or n
        if type(name) == 'string' and prototypes.item[name] and #out < 3 then out[#out+1] = {name=name, count=type(n) == 'table' and n.count or nil} end
      end
    end
    return out
  end
  -- The planets the item names in its title (else its owner's), for need totals and platform names.
  local function words(i)
    local t = ((i.title or '') .. ' ' .. (try(function() return table.concat(i.tags or {}, ' ') end) or '')):lower()
    return t
  end
  local function evidence(i)
    local ar = areas(i)
    local e = {built=built(ar), where=ar[1] and ar[1].what or nil, needs={}, notes=#(i.notes or {}), updated=i.updated_tick or i.created_tick or 0}
    local surface = api.owner_surface(i.owner) or 'nauvis'
    for _, n in ipairs(need_names(i)) do e.needs[n.name] = api.total(surface, n.name) or 0; e.need_count = e.need_count or {}; e.need_count[n.name] = n.count or 1 end
    e.need_surface = surface
    e.ship = api.shipment_seq and api.shipment_seq() or 0
    return e
  end
  local function shipment_since(i, seq)
    local out = {}
    local t = words(i)
    for _, ev in ipairs(api.shipment_events and api.shipment_events() or {}) do
      if ev.id > seq and t:find(ev.platform:lower(), 1, true) and #out < 3 then out[#out+1] = ev.text end
    end
    return out
  end
  -- What changed between two evidences, as words, and whether any did.
  local function changes(i, was, now)
    local parts = {}
    if now.built ~= was.built then parts[#parts+1] = string.format('%+d of our entities in %s (%d now)', now.built - was.built, now.where or 'its area', now.built) end
    -- a need resolved: its total on the owner's planet reached the count it names (any, for a name alone)
    for name, n in pairs(now.needs) do
      local b, want = was.needs[name], (now.need_count or {})[name] or 1
      if b and b < want and n >= want then parts[#parts+1] = string.format('%s on %s reached %d (it needs %d; %d at the check before)', name, now.need_surface, n, want, b) end
    end
    for _, t in ipairs(shipment_since(i, was.ship or 0)) do parts[#parts+1] = t end
    if now.updated > was.updated or now.notes > was.notes then parts[#parts+1] = 'its board entry changed' end
    return parts
  end
  local function owner_facts(i, since)
    local parts = {}
    local _, index = api.since_request(i.owner)
    if index then
      for k, f in ipairs(api.repeated and api.repeated(index, since) or {}) do
        if k <= 2 then parts[#parts+1] = string.format('%s failed %d times', f.key, f.n) end
      end
      local c = api.counted and api.counted(index, math.min(120, math.max(1, math.ceil((game.tick - since) / 3600))))
      if c and (c.no_effect or 0) >= 2 then parts[#parts+1] = string.format('%d actions with no effect', c.no_effect) end
    end
    return parts, index
  end
  local function next_text(i)
    if i.kind == 'project' and i.steps then
      for _, st in ipairs(i.steps) do if not st.done_by then return string.format('next step %d: %s', st.n or 0, tostring(st.text)) end end
    end
    for k = #(i.notes or {}), 1, -1 do
      local n = i.notes[k]
      if n.by == i.owner then return string.format('last note by %s, %s ago: %s', n.by, ago(game.tick - n.tick), n.text) end
    end
    return nil
  end
  -- One check of item i now: the record's state and the line for its owner.
  function M.check(i)
    local st = store()
    local r = st.items[i.id]
    local now = evidence(i)
    if not r then
      st.items[i.id] = {tick=game.tick, ev=now, unchanged=0, state='first check'}
      return
    end
    local parts = changes(i, r.ev, now)
    local of, index = owner_facts(i, r.tick)
    local waiting = index and api.waiting and api.waiting(index)
    local state
    if #parts > 0 then r.unchanged = 0; state = 'progress'
    elseif waiting then state = 'waiting (' .. waiting .. ')'
    else r.unchanged = r.unchanged + 1; state = r.unchanged >= M.STALL and string.format('stalled: unchanged across %d checks', r.unchanged) or 'unchanged since the last check' end
    r.state, r.parts, r.owner_facts, r.prev_tick, r.tick, r.ev = state, parts, of, r.tick, game.tick, now
    -- the owner's focus on this item: a focused step not done counts across checks (board_focus)
    local f = focus_store()[i.owner]
    if f and f.id == i.id then
      local s = step_of(i, f.step)
      if s and s.done_by then f.unchanged = 0 elseif s or (f.step and #parts == 0) then f.unchanged = (f.unchanged or 0) + 1 else f.unchanged = 0 end
      if f.unchanged >= M.STALL then r.focus_flag = string.format('the focused %s shows no completion across %d checks', s and 'step ' .. s.n or 'step', f.unchanged) else r.focus_flag = nil end
    end
    -- the owner's line
    local nt = next_text(i)
    local line = string.format('board #%d %s (%s): %s%s; %s', i.id, i.title, i.status, #parts > 0 and 'progress seen: ' .. table.concat(parts, '; ') or state,
      #of > 0 and '; yours since then: ' .. table.concat(of, ', ') or '',
      nt or string.format('no next action or blocker written on it (board_update {id: %d, note} writes one)', i.id))
    st.lines[i.owner] = st.lines[i.owner] or {}
    local l = st.lines[i.owner]
    l[#l+1] = line .. (r.focus_flag and '; ' .. r.focus_flag or '')
    while #l > 3 do table.remove(l, 1) end
  end
  -- Every 2 s: one item due for a check (a check read 6-9 ms on the copy of world n).
  function M.tick()
    local st = store()
    local due = {}
    for id, i in pairs(api.items()) do
      if owned(i) then
        local r = st.items[id]
        if not r or game.tick - r.tick >= M.CHECK then due[#due+1] = i end
      elseif st.items[id] then st.items[id] = nil end
    end
    table.sort(due, function(x, y) return ((st.items[x.id] or {}).tick or 0) < ((st.items[y.id] or {}).tick or 0) or x.id < y.id end)
    if due[1] then local ok, err = pcall(M.check, due[1]); if not ok then M.last_error = err end end
  end
  -- The owner's lines (team.alerts), once.
  function M.lines(p, h)
    local me = api.who(p)
    local st = api.state().progress
    local l = st and st.lines[me]
    if not l or #l == 0 then return nil end
    st.lines[me] = nil
    return l
  end
  local function rule(i)
    local since = api.since_request(i.owner)
    local q = i.kind == 'project' and api.PROJECT_QUIET or api.QUIET
    return string.format('anyone may take it once %s has made no request for %d min (%s)', i.owner, q / 3600,
      since and 'last request ' .. ago(since) .. ' ago' or 'no request seen')
  end
  function M.read(p, a)
    local st = store()
    local rows, lines = {}, {}
    local list = {}
    for _, i in pairs(api.items()) do if owned(i) and (a.owner == nil or i.owner == a.owner) and (a.id == nil or i.id == a.id) then list[#list+1] = i end end
    -- the game read again for what changed since the last check only for one owner's items or one item (the whole
    -- board's 59 items read again was 388 ms on the copy of world n); the stored checks otherwise
    local live_read = a.owner ~= nil or a.id ~= nil
    table.sort(list, function(x, y) return x.id < y.id end)
    -- stalled first, then the longest unchanged board entry; at most MAX_LINES lines (rows: all)
    table.sort(list, function(x, y)
      local sx, sy = (st.items[x.id] or {}).unchanged or 0, (st.items[y.id] or {}).unchanged or 0
      if (sx >= M.STALL) ~= (sy >= M.STALL) then return sx >= M.STALL end
      return (x.updated_tick or 0) < (y.updated_tick or 0)
    end)
    for k, i in ipairs(list) do
      local r = st.items[i.id]
      local live = r and live_read and changes(i, r.ev, evidence(i)) or {}
      local of = r and (live_read and owner_facts(i, r.tick) or r.owner_facts) or {}
      local state = r and r.state or 'not checked yet'
      local stalled = r and r.unchanged >= M.STALL and #live == 0
      local text = string.format('#%d %s %s (%s, owner %s): last board change %s ago; %s%s%s%s; %s', i.id, i.kind, i.title, i.status, i.owner,
        ago(game.tick - (i.updated_tick or i.created_tick or 0)),
        r and string.format('checked %s ago: %s', ago(game.tick - r.tick), state) or 'first check within 10 min',
        r and r.parts and #r.parts > 0 and ' (' .. table.concat(r.parts, '; ') .. ')' or '',
        #live > 0 and '; since that check: ' .. table.concat(live, '; ') or '',
        #of > 0 and '; the owner since then: ' .. table.concat(of, ', ') or '',
        (stalled and rule(i) or (next_text(i) or 'no next action or blocker written')) .. (r and r.focus_flag and '; ' .. r.focus_flag or ''))
      if k <= M.MAX_LINES then lines[#lines+1] = text elseif k == M.MAX_LINES + 1 then lines[#lines+1] = string.format('+%d more (rows lists all; owner narrows it)', #list - M.MAX_LINES) end
      rows[#rows+1] = {id=i.id, kind=i.kind, title=i.title, status=i.status, owner=i.owner, state=state, stalled=stalled or nil,
        last_change_s=math.floor((game.tick - (i.updated_tick or i.created_tick or 0)) / 60), unchanged_checks=r and r.unchanged or nil}
    end
    return {lines=#lines > 0 and lines or {'no owned open item'}, rows=rows,
      note='a check every 10 game minutes: our entities in the item\'s area (else its owner\'s claims), the totals of what it needs, shipment lines of platforms it names, its board edits; unchanged across 2 checks: stalled, unless its owner waits (sleep, wait step, queue running)'}
  end
  -- Blocked items ranked: those the plan names first, then by how many open items wait on them through chains.
  function M.critical(p, a)
    local items = api.items()
    local waits_on = {}
    for id, i in pairs(items) do
      if LIVE[i.status] then
        for _, b in ipairs(i.blocked_by or {}) do waits_on[b] = waits_on[b] or {}; table.insert(waits_on[b], id) end
        if i.parent then waits_on[i.id] = waits_on[i.id] or {}; table.insert(waits_on[i.id], i.parent) end
      end
    end
    local function downstream(id)
      local seen, q, n = {[id]=true}, {id}, 0
      while #q > 0 do
        local x = table.remove(q, 1)
        for _, y in ipairs(waits_on[x] or {}) do if not seen[y] then seen[y] = true; n = n + 1; q[#q+1] = y end end
      end
      return n
    end
    local plan = api.plan_item and api.plan_item()
    local ptext = ''
    if plan then
      ptext = tostring(plan.goals or '')
      for _, l in ipairs(plan.lines or {}) do ptext = ptext .. ' ' .. tostring(l.text) end
    end
    local list = {}
    for id, i in pairs(items) do
      local open_blockers = {}
      for _, b in ipairs(i.blocked_by or {}) do
        local bi = items[b]
        if bi and LIVE[bi.status] then open_blockers[#open_blockers+1] = bi end
      end
      if LIVE[i.status] and i.kind ~= 'claim' and i.kind ~= 'note' and (i.status == 'blocked' or #open_blockers > 0) then
        local named = ptext:find('#' .. id .. '%f[%D]') ~= nil
        list[#list+1] = {i=i, named=named, n=downstream(id), blockers=open_blockers}
      end
    end
    table.sort(list, function(x, y)
      if x.named ~= y.named then return x.named end
      if x.n ~= y.n then return x.n > y.n end
      return x.i.id < y.i.id
    end)
    local lines = {}
    for k, x in ipairs(list) do
      if k > 16 then lines[#lines+1] = string.format('+%d more blocked', #list - 16); break end
      local bl = {}
      for _, b in ipairs(x.blockers) do
        bl[#bl+1] = string.format('#%d %s (%s%s, last change %s ago)', b.id, b.title, b.status, b.owner and ', owner ' .. b.owner or ', no owner', ago(game.tick - (b.updated_tick or b.created_tick or 0)))
      end
      lines[#lines+1] = string.format('#%d %s (%s, owner %s)%s: %d open item%s wait on it; %s', x.i.id, x.i.title, x.i.status, tostring(x.i.owner or 'none'),
        x.named and ', named in the team plan' or '', x.n, x.n == 1 and '' or 's', #bl > 0 and 'waits on ' .. table.concat(bl, '; ') or 'marked blocked: ' .. (next_text(x.i) or 'no blocker written'))
    end
    -- agents standing or waiting now
    local agents = {}
    for _, ag in ipairs(api.agents()) do
      local w = api.waiting and api.waiting(ag.index)
      local stand = api.standing and api.standing(ag.index)
      if w or (stand and stand >= 3600) then
        local own = {}
        for _, i in pairs(items) do if owned(i) and i.owner == ag.name and #own < 3 then own[#own+1] = '#' .. i.id end end
        agents[#agents+1] = string.format('%s: %s%s', ag.name, w and 'waiting (' .. w .. ')' or 'standing ' .. ago(stand), #own > 0 and '; owns ' .. table.concat(own, ', ') or '; owns nothing open')
      end
    end
    table.sort(agents)
    return {blocked=#lines > 0 and lines or {'no blocked item'}, agents_idle_or_waiting=#agents > 0 and agents or nil,
      note='ranked: named in the team plan (#id in its goals or lines) first, then by the open items waiting on it through blocked_by and parent chains'}
  end
  -- board_focus (Sol 09:37 for viewer Foobator): an agent's current item and step, its blocker and its next
  -- verification, in one call; status and its team block show it in one line; teammates read each other's. Nothing is
  -- assigned. A focused project step with no completion (done) across 2 checks is flagged in board_progress.
  function M.focus_line(name)
    local f = focus_store()[name]
    if not f then return nil end
    local i = api.items()[f.id]
    local s = i and step_of(i, f.step)
    local step = s and string.format('step %d %s%s', s.n, tostring(s.text), s.done_by and ' (done)' or '') or (f.step and 'step ' .. tostring(f.step) or nil)
    return string.format('%s focus (set %s ago): #%d %s%s%s%s%s', name, ago(game.tick - f.tick), f.id, i and i.title or '(item gone)',
      step and '; ' .. step or '', f.blocker and '; blocker: ' .. f.blocker or '', f.verify and '; next verification: ' .. f.verify or '',
      (f.unchanged or 0) >= M.STALL and string.format('; the focused step shows no completion across %d checks', f.unchanged) or '')
  end
  function M.focus(p, a)
    local me = api.who(p)
    if a.id == nil then
      -- a read: one agent's, or every agent's
      local lines = {}
      for _, ag in ipairs(api.agents()) do
        if a.agent == nil or ag.name == a.agent then local l = M.focus_line(ag.name); if l then lines[#lines+1] = l end end
      end
      return {focus=#lines > 0 and lines or {'no focus set'}}
    end
    assert(type(a.id) == 'number' and api.items()[a.id], 'id is a board item number')
    local i = api.items()[a.id]
    assert(i.kind ~= 'lesson' and i.kind ~= 'claim' and i.kind ~= 'note', 'focus is on a task, request or project (and its step)')
    assert(a.step == nil or type(a.step) == 'number' or (type(a.step) == 'string' and #a.step <= 160), 'step is a project step number, or text (160)')
    if type(a.step) == 'number' then assert(step_of(i, a.step), 'no step ' .. a.step .. ' on #' .. a.id) end
    for _, f in ipairs({'blocker', 'verify'}) do assert(a[f] == nil or (type(a[f]) == 'string' and #a[f] <= 200), f .. ' is text, at most 200 characters') end
    focus_store()[me] = {id=a.id, step=a.step, blocker=a.blocker, verify=a.verify, tick=game.tick, unchanged=0}
    return {focus=M.focus_line(me)}
  end
  M.schema = {
    board_focus = {id='a board item number (task, request or project): your current one; without id: a read of the focus lines (agent: only theirs)',
      step='a project step number, or text', blocker='optional text: what blocks it', verify='optional text: your next verification',
      agent='with a read: that teammate', returns='focus: the line (status and your team block show it; teammates read it with board_focus {agent}); a focused project step not done across 2 checks reads so here and in board_progress'},
    board_progress = {owner='optional agent name: only their items (and what changed since each one\'s last check, read now)',id='optional item number: only that item, read now as with owner',
      returns='lines: each owned open task, request and project: the age of its last board change; the last check (every 10 game minutes): progress seen (our entities in its area, else in its owner\'s claims; the totals of the items it needs on its owner\'s planet; shipment lines of platforms its title names; its board edits), waiting (its owner in a sleep, wait step or running queue), unchanged, or stalled (unchanged across 2 checks) with the 20-minute rule (anyone may take it once its owner has made no request for 20 min, the owner\'s last request); what changed since that check; the owner\'s repeated failures and no-effect actions since; its next action or blocker as last written. rows'},
    board_critical = {returns='blocked: each blocked item (status blocked, or an open item in its blocked_by), those the team plan names (#id) first, then by how many open items wait on it through blocked_by and parent chains, with what it waits on (status, owner, last change); agents_idle_or_waiting: agents standing a minute or more or in a wait, with what they own'},
  }
  return M
end
