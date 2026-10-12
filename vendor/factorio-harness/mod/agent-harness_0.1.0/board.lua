-- Team board (shared tasks, requests, claims and notes kept in the save), its
-- event log for the stream overlay, the per-agent `team` hint block pushed on
-- replies, agents' requests for harness tools, and saved queue plans.
-- Nothing here runs per tick: hints are computed when an agent's reply is
-- built, bounded by the board size and the chat/event logs.
return function(api)
  local M = {handlers={}}
  local MAX_ITEMS, MAX_EVENTS, MAX_NOTES, MAX_PLANS, MAX_HARNESS_OPEN, MAX_PLAN_BYTES = 300, 1000, 10, 50, 10, 65536
  local TITLE, NOTE, LONG = 120, 200, 1000
  local UNOWNED_AGE, REMIND_EVERY, FIRST_ALERTS = 7200, 3600, 3600
  local MAX_BOARD_LINES, MAX_ALERT_LINES = 5, 8
  local KINDS = {task=true, request=true, claim=true, note=true, harness=true, plan=true}
  -- The team plan: one living item (kind plan) with goals and a line per agent.
  local PLAN_GOALS, PLAN_LINE, PLAN_LINES, PLAN_HISTORY = 600, 160, 24, 10
  local STATUSES = {open=true, claimed=true, doing=true, done=true, blocked=true, dropped=true}
  local ACTIVE = {open=true, claimed=true, doing=true, blocked=true}
  local OPERATOR = 'operator'

  local function store()
    local s = api.state()
    s.board = s.board or {next_id=1, count=0, items={}, seq=0, events={}}
    return s.board
  end
  local function hints(index)
    local s = api.state()
    s.team_hints = s.team_hints or {}
    s.team_hints[index] = s.team_hints[index] or {}
    return s.team_hints[index]
  end
  -- One line of text, cut to `max` bytes on a UTF-8 boundary; never fails.
  local function clip(text, max)
    text = tostring(text):gsub('[%c]+', ' ')
    if #text <= max then return text end
    local cut = max
    while cut > 0 and (text:byte(cut + 1) or 0) >= 0x80 and text:byte(cut + 1) < 0xC0 do cut = cut - 1 end
    return text:sub(1, cut)
  end
  local function required_text(value, name, max)
    assert(type(value) == 'string' and value:find('%S'), name .. ' is required (1..' .. max .. ' characters)')
    return clip(value, max)
  end
  local function optional_text(value, name, max)
    if value == nil then return nil end
    assert(type(value) == 'string', name .. ' must be a string')
    return clip(value, max)
  end
  -- The name an agent goes by on the board (bot or player name).
  local function who(p)
    local n = p.name
    if type(n) ~= 'string' or n == '' then n = 'player' .. p.index end
    return n
  end
  local function round(v) return math.floor(v + 0.5) end
  local function ago(ticks)
    local sec = math.floor(ticks / 60)
    if sec >= 3600 then return string.format('%dh%02dm', math.floor(sec / 3600), math.floor(sec / 60) % 60) end
    if sec >= 60 then return string.format('%dm%02ds', math.floor(sec / 60), sec % 60) end
    return sec .. 's'
  end

  -- Agents: every player who is not a director, and every bot.
  local function agents()
    local out = {}
    for _, p in pairs(game.players) do
      if not api.director(p.index) then out[#out+1] = {index=p.index, name=who(p)} end
    end
    for _, b in ipairs(api.bots()) do out[#out+1] = {index=b.index, name=b.name} end
    for _, a in ipairs(out) do
      local pr = api.profile(a.index)
      a.display_name = pr and pr.display_name
    end
    return out
  end
  -- A name as agents write it: exact name, display name, or a player name
  -- without its `pog-` prefix, any case. Unknown names fail with the roster.
  local function resolve(name)
    assert(type(name) == 'string', 'owner must be an agent name')
    local want = name:lower():gsub('^@', '')
    if want == OPERATOR then return OPERATOR end
    local roster = agents()
    for _, a in ipairs(roster) do if a.name:lower() == want then return a.name end end
    for _, a in ipairs(roster) do
      if (a.display_name and a.display_name:lower() == want) or a.name:lower():gsub('^pog%-', '') == want then return a.name end
    end
    local names = {}
    for _, a in ipairs(roster) do names[#names+1] = a.name end
    table.sort(names)
    error('unknown agent ' .. name .. '; agents: ' .. table.concat(names, ', '), 0)
  end

  -- extra: prev_owner (an owner who lost the item in this change) and
  -- overlaps (owner -> their claim id, for a claim posted over theirs).
  local function event(by, item, change, text, extra)
    local b = store()
    b.aged = nil
    b.seq = b.seq + 1
    b.events[#b.events+1] = {seq=b.seq, tick=game.tick, by=by, id=item.id, change=change, title=item.title,
      kind=item.kind, owner=item.owner, requested_by=item.requested_by, status=item.status, text=text,
      prev_owner=extra and extra.prev_owner, overlaps=extra and extra.overlaps}
    while #b.events > MAX_EVENTS do table.remove(b.events, 1) end
  end
  -- Over the cap, finished items go first (oldest update first), then notes,
  -- then the oldest of anything.
  local function prune()
    local b = store()
    while b.count > MAX_ITEMS do
      local victim
      for _, pass in ipairs{function(i) return i.status == 'done' or i.status == 'dropped' end,
          function(i) return i.kind == 'note' end, function(i) return i.kind ~= 'plan' end} do
        for _, i in pairs(b.items) do
          if pass(i) and (not victim or i.updated_tick < victim.updated_tick or (i.updated_tick == victim.updated_tick and i.id < victim.id)) then victim = i end
        end
        if victim then break end
      end
      b.items[victim.id] = nil
      b.count = b.count - 1
      b.aged = nil
    end
  end
  local function area_arg(a)
    if a == nil then return nil end
    assert(type(a) == 'table' and type(a.left_top) == 'table' and type(a.right_bottom) == 'table',
      'area requires {left_top={x,y}, right_bottom={x,y}}')
    local lt, rb = a.left_top, a.right_bottom
    for _, v in ipairs{lt.x, lt.y, rb.x, rb.y} do assert(type(v) == 'number' and math.abs(v) < 1000000, 'area corners need numeric x and y') end
    return {left_top={x=math.min(lt.x, rb.x), y=math.min(lt.y, rb.y)}, right_bottom={x=math.max(lt.x, rb.x), y=math.max(lt.y, rb.y)}}
  end
  local function needs_arg(v)
    if v == nil then return nil end
    if type(v) == 'string' then return clip(v, NOTE) end
    -- An object {item=count} (shake4: posts resent after that shape failed).
    if type(v) == 'table' and #v == 0 and next(v) ~= nil then
      local list = {}
      for name, count in pairs(v) do
        assert(type(name) == 'string' and type(count) == 'number', 'needs as an object maps item names to counts: {"iron-plate": 200}')
        list[#list+1] = {name=clip(name, 64), count=count}
      end
      assert(#list <= 16, 'needs takes at most 16 items')
      table.sort(list, function(x, y) return x.name < y.name end)
      return list
    end
    assert(type(v) == 'table' and #v >= 1 and #v <= 16, 'needs is text, an array of 1..16 item names or {name,count}, or {item: count}')
    local out = {}
    for _, n in ipairs(v) do
      if type(n) == 'string' then out[#out+1] = clip(n, 64)
      else
        assert(type(n) == 'table' and type(n.name) == 'string' and (n.count == nil or type(n.count) == 'number'), 'needs entries are names or {name,count}')
        out[#out+1] = {name=clip(n.name, 64), count=n.count}
      end
    end
    return out
  end
  local function tags_arg(v)
    if v == nil then return nil end
    assert(type(v) == 'table' and #v <= 8, 'tags must be an array of up to 8 short strings')
    local out = {}
    for _, t in ipairs(v) do assert(type(t) == 'string', 'tags must be strings'); out[#out+1] = clip(t, 24) end
    return out
  end
  local function overlaps(a, b)
    return a.left_top.x < b.right_bottom.x and b.left_top.x < a.right_bottom.x and a.left_top.y < b.right_bottom.y and b.left_top.y < a.right_bottom.y
  end
  local function view(i, full)
    local notes = i.notes
    if not full and #notes > 2 then notes = {notes[#notes-1], notes[#notes]} end
    return {id=i.id, kind=i.kind, title=i.title, owner=i.owner, requested_by=i.requested_by, status=i.status, area=i.area,
      needs=i.needs, tags=i.tags, problem=i.problem, proposal=i.proposal,
      notes=#notes > 0 and notes or nil, note_count=not full and #i.notes > 2 and #i.notes or nil,
      created_tick=i.created_tick, updated_tick=i.updated_tick}
  end
  local function open_unowned()
    local n, oldest = 0, nil
    for _, i in pairs(store().items) do
      if i.status == 'open' and not i.owner and (i.kind == 'task' or i.kind == 'request') then
        n = n + 1
        if not oldest or i.created_tick < oldest.created_tick then oldest = i end
      end
    end
    return n, oldest
  end

  local function post(by, a)
    local kind = a.kind
    assert(type(kind) == 'string' and KINDS[kind], 'kind must be task, request, claim or note')
    assert(kind ~= 'harness', 'ask for a harness tool with harness_request')
    assert(kind ~= 'plan', 'the team plan is one item: edit it with board_plan {goals} or {doing}')
    local item = {kind=kind, title=required_text(a.title, 'title', TITLE), requested_by=by, area=area_arg(a.area),
      needs=needs_arg(a.needs), tags=tags_arg(a.tags), notes={}, created_tick=game.tick, updated_tick=game.tick}
    -- A first note (shake4: agents carried update's note over to posts).
    if a.note ~= nil then item.notes[1] = {tick=game.tick, by=by, text=required_text(a.note, 'note', NOTE)} end
    local warnings, over = {}, nil
    if kind == 'claim' then
      assert(item.area, 'a claim needs area {left_top, right_bottom}')
      item.owner = by
    elseif kind == 'note' then
      item.owner = by
    elseif a.owner ~= nil and a.owner ~= '' then
      item.owner = resolve(a.owner)
    end
    item.status = (item.owner and kind ~= 'note') and 'claimed' or 'open'
    if kind == 'claim' then
      for _, other in pairs(store().items) do
        if other.kind == 'claim' and ACTIVE[other.status] and other.owner ~= by and overlaps(other.area, item.area) then
          warnings[#warnings+1] = string.format('overlaps claim #%d by %s: %s', other.id, other.owner, other.title)
          over = over or {}
          over[other.owner] = over[other.owner] or other.id
        end
      end
    end
    if kind == 'request' and not item.owner then
      warnings[#warnings+1] = 'no owner: shown to everyone as unowned until someone takes it'
    end
    local b = store()
    item.id = b.next_id; b.next_id = b.next_id + 1
    b.items[item.id] = item; b.count = b.count + 1
    -- The first note rides on the event, so an assigned owner reads it.
    event(by, item, 'posted', item.notes[1] and item.notes[1].text, over and {overlaps=over})
    prune()
    return {item=view(item, true), warnings=#warnings > 0 and warnings or nil}
  end

  local function update(by, a)
    assert(type(a.id) == 'number', 'id is required (a board item number)')
    local item = store().items[a.id]
    assert(item, 'no board item #' .. tostring(a.id) .. ' (pruned or never posted)')
    assert(a.status ~= nil or a.owner ~= nil or a.note ~= nil, 'give status, owner or note')
    -- Check every argument before changing anything.
    assert(a.status == nil or (type(a.status) == 'string' and STATUSES[a.status]), 'status must be open, claimed, doing, done, blocked or dropped')
    local text = a.note ~= nil and required_text(a.note, 'note', NOTE) or nil
    local boss = by == OPERATOR or by == item.owner or by == item.requested_by
    local changes, was = {}, item.owner
    assert(item.kind ~= 'plan' or (a.status == nil and a.owner == nil), 'the team plan changes with board_plan {goals} or {doing}; notes are fine')
    if a.owner ~= nil then
      assert(item.kind ~= 'claim' and item.kind ~= 'note' and item.kind ~= 'harness', 'a ' .. item.kind .. ' stays with its poster')
      if a.owner == '' or a.owner == false then
        assert(boss, 'only the owner or requester can release an item')
        if item.owner then item.owner = nil; item.status = 'open'; changes[#changes+1] = 'released' end
      else
        local owner = resolve(a.owner)
        local taking = owner == by and not item.owner and item.status == 'open'
        assert(boss or taking, string.format('#%d is %s; only its owner or requester can reassign it (anyone can take an open unowned item)',
          item.id, item.owner and 'owned by ' .. item.owner or item.status))
        if owner ~= item.owner then
          item.owner = owner
          if item.status == 'open' then item.status = 'claimed' end
          changes[#changes+1] = owner == by and 'taken' or 'assigned'
          boss = true
        end
      end
    end
    if a.status ~= nil then
      assert(boss, string.format('only the owner (%s) or requester (%s) can change the status of #%d; add a note instead',
        tostring(item.owner or 'none'), tostring(item.requested_by), item.id))
      if a.status ~= item.status then
        item.status = a.status
        if a.status ~= 'open' and not item.owner then item.owner = by end
        changes[#changes+1] = a.status
      end
    end
    if text then
      item.notes[#item.notes+1] = {tick=game.tick, by=by, text=text}
      while #item.notes > MAX_NOTES do table.remove(item.notes, 1) end
    end
    item.updated_tick = game.tick
    local extra = was and was ~= item.owner and {prev_owner=was} or nil
    for _, change in ipairs(changes) do event(by, item, change, text, extra) end
    if text and #changes == 0 then event(by, item, 'note', text) end
    return {item=view(item, true), changed=#changes > 0 and changes or nil}
  end

  local function read(by, a)
    local b = store()
    if a.id ~= nil then
      local item = b.items[a.id]
      assert(item, 'no board item #' .. tostring(a.id))
      return {item=view(item, true)}
    end
    local limit = a.limit or 30
    assert(type(limit) == 'number' and limit >= 1 and limit <= 100, 'limit must be 1..100')
    local want
    if a.status ~= nil then
      want = {}
      local list = type(a.status) == 'table' and a.status or {a.status}
      for _, s in ipairs(list) do
        assert(s == 'active' or STATUSES[s], 'status must be active, open, claimed, doing, done, blocked or dropped')
        if s == 'active' then for k in pairs(ACTIVE) do want[k] = true end else want[s] = true end
      end
    end
    assert(a.kind == nil or KINDS[a.kind], 'kind must be task, request, claim, note or harness')
    assert(a.since_tick == nil or type(a.since_tick) == 'number', 'since_tick must be a tick')
    local list = {}
    for _, i in pairs(b.items) do
      -- The plan is shown on its own (plan below), not as a row.
      if i.kind ~= 'plan' and (not want or want[i.status]) and (not a.kind or i.kind == a.kind) and (not a.since_tick or i.updated_tick > a.since_tick)
          and (a.mine ~= true or i.owner == by or i.requested_by == by) then
        list[#list+1] = i
      end
    end
    table.sort(list, function(x, y) return x.updated_tick > y.updated_tick or (x.updated_tick == y.updated_tick and x.id > y.id) end)
    local out = {}
    for n = 1, math.min(limit, #list) do out[n] = view(list[n]) end
    local unowned = open_unowned()
    local plan = (a.kind == nil or a.kind == 'plan') and a.mine ~= true and M.plan_view() or nil
    return {plan=plan, items=out, matched=#list, open_unowned=unowned, tick=game.tick}
  end

  -- The team plan: goals (anyone edits) and one line per agent ("who is on
  -- what"; anyone may write any agent's line, it shows who wrote it).
  local function plan_item()
    local b = store()
    return b.plan_id and b.items[b.plan_id]
  end
  function M.plan_view()
    local i = plan_item()
    if not i then return nil end
    local lines = {}
    for _, l in ipairs(i.lines) do
      lines[#lines+1] = l.agent .. ': ' .. l.text .. (l.by ~= l.agent and ' (set by ' .. l.by .. ')' or '')
    end
    return {id=i.id, goals=i.goals, doing=#lines > 0 and lines or nil,
      edited=i.edited_by and string.format('by %s, %s ago', i.edited_by, ago(game.tick - i.updated_tick)) or nil}
  end
  -- The plan's goals and agent `name`'s own line (the shift block), or nil.
  function M.plan_for(name)
    local i = plan_item()
    if not i then return nil end
    local mine
    for _, l in ipairs(i.lines) do if l.agent == name then mine = l.text end end
    return {goals=i.goals, mine=mine}
  end
  local function plan_edit(by, a)
    assert(a.agent == nil or a.doing ~= nil, 'agent goes with doing: board_plan {agent, doing}')
    if a.goals == nil and a.doing == nil then
      return {plan=M.plan_view() or false, note=not plan_item() and 'no team plan yet: board_plan {goals} starts it' or nil}
    end
    local goals = a.goals ~= nil and optional_text(a.goals, 'goals', PLAN_GOALS) or nil
    local clear_goals = goals ~= nil and not goals:find('%S')
    if clear_goals then goals = nil end
    local doing = a.doing ~= nil and optional_text(a.doing, 'doing', PLAN_LINE) or nil
    local agent = a.agent ~= nil and resolve(a.agent) or by
    assert(doing == nil or agent ~= OPERATOR, 'the operator has no line on the plan: board_plan {agent, doing}')
    local b = store()
    local item = plan_item()
    if not item then
      item = {id=b.next_id, kind='plan', title='Team plan', status='doing', lines={}, notes={}, created_tick=game.tick, updated_tick=game.tick}
      b.next_id = b.next_id + 1
      b.items[item.id] = item; b.count = b.count + 1
      b.plan_id = item.id
    end
    local changed = {}
    if (goals ~= nil or clear_goals) and goals ~= item.goals then
      item.history = item.history or {}
      if item.goals then
        item.history[#item.history+1] = {tick=item.updated_tick, by=item.edited_by, goals=item.goals}
        while #item.history > PLAN_HISTORY do table.remove(item.history, 1) end
      end
      item.goals = goals
      changed[#changed+1] = item.goals and 'goals: ' .. item.goals or 'goals cleared'
    end
    if doing ~= nil then
      local at
      for k, l in ipairs(item.lines) do if l.agent == agent then at = k end end
      if not doing:find('%S') then
        if at then table.remove(item.lines, at); changed[#changed+1] = agent .. ': (line removed)' end
      else
        assert(at or #item.lines < PLAN_LINES, 'the plan holds ' .. PLAN_LINES .. ' lines; clear one with board_plan {agent, doing: ""}')
        local line = {agent=agent, text=doing, by=by, tick=game.tick}
        if at then item.lines[at] = line else item.lines[#item.lines+1] = line end
        changed[#changed+1] = agent .. ': ' .. doing
      end
    end
    if #changed == 0 then return {plan=M.plan_view(), changed=false} end
    item.updated_tick, item.edited_by = game.tick, by
    -- The event names the agent whose line changed, so that agent hears of it.
    local text = clip(table.concat(changed, '; '), NOTE)
    event(by, {id=item.id, kind='plan', title=item.title, status=item.status, owner=doing ~= nil and agent or nil}, 'edited', text)
    return {plan=M.plan_view(), changed=true}
  end
  -- A board event with no item behind it (research.lua: a technology finished).
  function M.system_event(by, item, change, text)
    event(by, item, change, text)
  end

  local function events(a)
    local since = a.since_seq or 0
    assert(type(since) == 'number', 'since_seq must be a number')
    local limit = a.limit or 100
    assert(type(limit) == 'number' and limit >= 1 and limit <= 200, 'limit must be 1..200')
    local b, out = store(), {}
    for _, e in ipairs(b.events) do
      if e.seq > since then out[#out+1] = e; if #out >= limit then break end end
    end
    return {events=out, cursor=#out > 0 and out[#out].seq or math.max(since, 0), latest=b.seq, tick=game.tick}
  end

  local function harness_request(by, a)
    local mine = 0
    for _, i in pairs(store().items) do
      if i.kind == 'harness' and i.requested_by == by and ACTIVE[i.status] then mine = mine + 1 end
    end
    assert(mine < MAX_HARNESS_OPEN, 'you already have ' .. mine .. ' open harness requests; add notes to those instead')
    local b = store()
    local item = {id=b.next_id, kind='harness', title=required_text(a.title, 'title', TITLE), owner=OPERATOR, requested_by=by,
      status='open', problem=required_text(a.problem, 'problem', LONG), proposal=optional_text(a.proposal, 'proposal', LONG),
      notes={}, created_tick=game.tick, updated_tick=game.tick}
    b.next_id = b.next_id + 1
    b.items[item.id] = item; b.count = b.count + 1
    event(by, item, 'posted')
    prune()
    return {item=view(item, true), note='the operator reads harness requests; answers arrive as board notes on this item and a "server: harness" chat line'}
  end

  -- Saved plans: named queue plans per agent, run later as a queue submit.
  -- Copies go in and out, so a running queue never edits the saved plan.
  local function copy(v)
    if type(v) ~= 'table' then return v end
    local out = {}
    for k, x in pairs(v) do out[k] = copy(x) end
    return out
  end
  local function plans_of(name)
    local s = api.state()
    s.plans = s.plans or {}
    s.plans[name] = s.plans[name] or {}
    return s.plans[name]
  end
  local function plan_save(p, a)
    assert(type(a.name) == 'string' and a.name:match('^[%w_%-%.]+$') and #a.name <= 32, 'name must be 1..32 letters, digits, _ - .')
    local mine = plans_of(who(p))
    if a.delete == true then
      assert(mine[a.name], 'no saved plan ' .. a.name)
      mine[a.name] = nil
      return {deleted=a.name}
    end
    assert(type(a.steps) == 'table' and #a.steps >= 1, 'steps must be a non-empty array (same schema as queue_submit)')
    local size = api.validate_plan(a)
    assert(size <= MAX_PLAN_BYTES, 'a saved plan is limited to ' .. MAX_PLAN_BYTES .. ' bytes of arguments')
    local count = 0
    for _ in pairs(mine) do count = count + 1 end
    assert(mine[a.name] or count < MAX_PLANS, 'at most ' .. MAX_PLANS .. ' saved plans; delete one with plan_save {name, delete=true}')
    local old = mine[a.name]
    mine[a.name] = {steps=copy(a.steps), guards=copy(a.guards), note=optional_text(a.note, 'note', TITLE), saved_tick=game.tick, runs=old and old.runs or 0}
    return {name=a.name, steps=#a.steps, guards=a.guards and #a.guards or nil, bytes=size, replaced=old ~= nil or nil}
  end
  local function plan_run(p, a)
    assert(type(a.name) == 'string', 'name is required (see plans)')
    local plan = plans_of(who(p))[a.name]
    if not plan then
      local names = {}
      for name in pairs(plans_of(who(p))) do names[#names+1] = name end
      table.sort(names)
      error('no saved plan ' .. a.name .. (#names > 0 and '; saved: ' .. table.concat(names, ', ') or '; save one with plan_save'), 0)
    end
    local result = api.submit(p, {steps=copy(plan.steps), guards=copy(plan.guards), mode=a.mode, start=a.start})
    plan.runs = plan.runs + 1
    if type(result) == 'table' then result.plan = a.name end
    return result
  end
  local function plans(p, a)
    local mine = plans_of(who(p))
    if a.name ~= nil then
      local plan = mine[a.name]
      assert(plan, 'no saved plan ' .. tostring(a.name))
      return {name=a.name, steps=plan.steps, guards=plan.guards, note=plan.note, saved_tick=plan.saved_tick, runs=plan.runs}
    end
    local out = {}
    for name, plan in pairs(mine) do
      out[#out+1] = {name=name, steps=#plan.steps, note=plan.note, saved_tick=plan.saved_tick, runs=plan.runs}
    end
    table.sort(out, function(x, y) return x.name < y.name end)
    return {plans=out, max=MAX_PLANS}
  end

  M.schema = {
    board = {mine='boolean: items I own or requested', status='active|open|claimed|doing|done|blocked|dropped or an array of them',
      kind='task|request|claim|note|harness|plan', since_tick='items updated after this tick', limit='1..100 (default 30), newest first',
      id='one item in full (all notes)', returns='plan (the team plan: goals, doing lines, last edit), items, matched, open_unowned (open task/request items nobody owns)'},
    board_plan = {goals='the team goals, 1..600 characters, replace the current ones ("" clears them)',
      doing='one line of what an agent is on, 1..160 characters ("" removes the line)', agent='whose line doing sets (default you)',
      returns='the team plan: goals, doing (one line per agent, "(set by NAME)" when someone else wrote it), edited; with no arguments it only reads'},
    board_post = {kind='task|request|claim|note', title='1..120 characters (longer is cut)',
      owner='agent name or display name (task/request; a request without owner is shown to everyone until taken)',
      area='{left_top={x,y}, right_bottom={x,y}}: required for a claim (owner is you)', needs='text, array of item names/{name,count}, or {item: count}',
      tags='up to 8 short strings', note='optional first note, 1..200 characters', returns='the item; warnings for overlapping claims or an unowned request'},
    board_update = {id='item number', status='open|claimed|doing|done|blocked|dropped (owner or requester only)',
      owner='your name takes an open unowned item; another name reassigns (owner or requester only); "" releases it',
      note='1..200 characters, anyone may add (last 10 kept)'},
    board_events = {since_seq='return events after this sequence number (default 0)', limit='1..200 (default 100), oldest first',
      returns='events {seq,tick,by,id,change,title,kind,owner,requested_by,status,text} and cursor (pass it back as since_seq)'},
    harness_request = {title='1..120 characters', problem='what you tried and what went wrong (1..1000)', proposal='optional: the tool or change you want',
      returns='a board item (kind harness, owner operator); answers come as notes on it'},
    plan_save = {name='1..32 letters, digits, _ - .', steps='queue plan steps (same schema as queue_submit)', guards='optional queue guards',
      note='optional description', delete='true removes the saved plan', returns='name, steps, bytes'},
    plan_run = {name='saved plan name', mode='append|replace pending (default append)', start='default true', returns='as queue_submit'},
    plans = {name='optional: show one plan in full', returns='your saved plans (at most 50): name, steps, note, runs'},
    mention_counts = {returns='per agent: unread_mentions (not yet shown in a reply or chat read), at_mentions (@name or @everyone), oldest_tick, latest, last_request_tick (supervisors: wake idle mentioned agents)'},
  }
  -- Handlers take the acting agent's name, so the operator path can share them.
  M.handlers.board = function(p, a) return read(who(p), a) end
  M.handlers.board_post = function(p, a) return post(who(p), a) end
  M.handlers.board_update = function(p, a) return update(who(p), a) end
  M.handlers.board_events = function(_, a) return events(a) end
  M.handlers.harness_request = function(p, a) return harness_request(who(p), a) end
  M.handlers.board_plan = function(p, a) return plan_edit(who(p), a) end
  M.handlers.plan_save = plan_save
  M.handlers.plan_run = plan_run
  M.handlers.plans = plans
  -- Board reads any player may make (directors, overlays).
  M.open_reads = {board=true, board_events=true}
  -- Actions that need a living character (they drive or queue it).
  M.needs_character = {plan_run=true}
  -- The operator (RCON tools) reads and answers the board without a player.
  function M.operator(action, a)
    a = a or {}
    if action == 'board' then return read(OPERATOR, a) end
    if action == 'board_events' then return events(a) end
    if action == 'mention_counts' then return M.handlers.mention_counts() end
    if action == 'board_update' then return update(OPERATOR, a) end
    if action == 'board_post' then return post(OPERATOR, a) end
    if action == 'board_plan' then return plan_edit(OPERATOR, a) end
    error('operator requests support board, board_events, board_update, board_post, board_plan and mention_counts', 0)
  end

  -- The `team` hint block: what is new for this agent since its previous
  -- request. Each part is shown once; nil when there is nothing.
  -- Mentions are filed per agent when a message arrives, so none is lost to
  -- the chat log's rotation or to a chat read cut short by its limit. A
  -- message mentions an agent by @name, @display name, @everyone (@all,
  -- @team), or else by the plain name as a word; the sender is left out.
  local EVERYONE, MAX_PENDING = {'everyone', 'all', 'team'}, 200
  local function edge(ch) return ch == '' or not ch:find('[%w_%-]') end
  local function has_word(text, word)
    local init = 1
    while true do
      local i, j = text:find(word, init, true)
      if not i then return false end
      if edge(text:sub(i - 1, i - 1)) and edge(text:sub(j + 1, j + 1)) then return true end
      init = i + 1
    end
  end
  local function inbox(index)
    local s = api.state()
    s.mentions = s.mentions or {}
    s.mentions[index] = s.mentions[index] or {list={}, dropped=0}
    return s.mentions[index]
  end
  local function to_everyone(text)
    for _, word in ipairs(EVERYONE) do if has_word(text, '@' .. word) then return true end end
    return false
  end
  -- How text (lower case) mentions agent a: '@', '@everyone', 'name' or nil.
  local function mention_how(a, text, everyone)
    local names = {a.name:lower(), (a.name:lower():gsub('^pog%-', ''))}
    if a.display_name then names[3] = a.display_name:lower() end
    for _, n in ipairs(names) do if #n >= 2 and has_word(text, '@' .. n) then return '@' end end
    if everyone then return '@everyone' end
    for _, n in ipairs(names) do if #n >= 2 and has_word(text, n) then return 'name' end end
    return nil
  end
  M.resolve, M.agents, M.who = resolve, agents, who
  -- For chat reads (chat.lua): whether a logged message mentions this agent.
  -- A viewer's line mentions only an agent it names with @ (not @everyone).
  function M.mention_of(index, m)
    if m.player == index or m.notice then return nil end
    local text = m.text:lower()
    for _, a in ipairs(agents()) do
      if a.index == index then
        local how = mention_how(a, text, not m.viewer and to_everyone(text))
        if m.viewer and how ~= '@' then return nil end
        return how
      end
    end
    return nil
  end
  -- A viewer's line (chat.lua, relayed by the stream service) files a
  -- mention, which wakes a sleeper, only for an agent it names with @.
  function M.on_viewer(m)
    local text = m.text:lower()
    for _, a in ipairs(agents()) do
      if mention_how(a, text, false) == '@' then
        local box = inbox(a.index)
        box.list[#box.list+1] = {seq=m.seq, tick=m.tick, from=m.from, text=m.text, how='@', viewer=true}
        while #box.list > MAX_PENDING do table.remove(box.list, 1); box.dropped = box.dropped + 1 end
      end
    end
  end
  function M.on_message(m)
    local text = m.text:lower()
    local everyone = to_everyone(text)
    for _, a in ipairs(agents()) do
      if a.index ~= m.player then
        local how = mention_how(a, text, everyone)
        if how then
          local box = inbox(a.index)
          box.list[#box.list+1] = {seq=m.seq, tick=m.tick, from=m.from, text=m.text, how=how, aloud=m.aloud}
          while #box.list > MAX_PENDING do table.remove(box.list, 1); box.dropped = box.dropped + 1 end
        end
      end
    end
  end
  -- A tell (tells.lua) is filed in the same inbox, so it wakes a sleeper and
  -- counts for supervisors like a mention; chat reads never deliver it.
  function M.deliver(index, t)
    local box = inbox(index)
    box.list[#box.list+1] = {tell=t.seq, tick=t.tick, from=t.from, text=t.text, how='tell', team=t.team}
    while #box.list > MAX_PENDING do table.remove(box.list, 1); box.dropped = box.dropped + 1 end
  end
  -- A (non-peek) chat read delivers the mentions it showed.
  function M.on_read(index, messages)
    local box = api.state().mentions and api.state().mentions[index]
    if not (box and #box.list > 0 and #messages > 0) then return end
    local shown = {}
    for _, m in ipairs(messages) do shown[m.seq] = true end
    local keep = {}
    for _, m in ipairs(box.list) do if m.tell or not shown[m.seq] then keep[#keep+1] = m end end
    box.list = keep
  end
  -- Every pending mention and tell, oldest first; never cut by the other
  -- parts' caps. Tells (logistics sent to this agent) are listed apart.
  local function mentions(p)
    local box = api.state().mentions and api.state().mentions[p.index]
    if not (box and (#box.list > 0 or box.dropped > 0)) then return nil end
    local lines, tells = {}, {}
    if box.dropped > 0 then
      lines[1] = string.format('%d older mentions did not fit (%d kept); read chat', box.dropped, MAX_PENDING)
    end
    for _, m in ipairs(box.list) do
      if m.tell then
        tells[#tells+1] = string.format('%s%s, %s ago: %s', m.from, m.team and ' to team' or '', ago(game.tick - m.tick), m.text)
      else
        local tag = m.how == '@' and ' @you' or m.how == '@everyone' and ' @everyone' or ''
        lines[#lines+1] = string.format('%s%s, %s ago: %s', m.from, tag, ago(game.tick - m.tick), m.text)
      end
    end
    box.list, box.dropped = {}, 0
    return #lines > 0 and lines or nil, #tells > 0 and tells or nil
  end
  -- Operator/supervisor read: pending mentions per agent and when each agent
  -- last made a request (to wake an idle agent that was mentioned).
  local function mention_counts()
    local s, out = api.state(), {}
    for _, a in ipairs(agents()) do
      local box = s.mentions and s.mentions[a.index]
      local list = box and box.list or {}
      local direct, tells = 0, 0
      for _, m in ipairs(list) do
        if m.how ~= 'name' then direct = direct + 1 end
        if m.tell then tells = tells + 1 end
      end
      local last = list[#list]
      local clock = s.clocks and s.clocks[a.index]
      out[#out+1] = {name=a.name, display_name=a.display_name, unread_mentions=#list + (box and box.dropped or 0), at_mentions=direct,
        tells=tells > 0 and tells or nil, unread_board=M.unread_board(a),
        oldest_tick=list[1] and list[1].tick or nil, latest=last and clip(last.from .. ': ' .. last.text, 160) or nil,
        last_request_tick=clock and math.max(clock.call_tick, clock.seen_tick or 0) or nil}
    end
    return {agents=out, tick=game.tick}
  end
  M.handlers.mention_counts = function() return mention_counts() end
  M.open_reads.mention_counts = true
  -- What a board event tells agent `me`, or nil: an item assigned to them
  -- (with its first note), any change by someone else to an item they own or
  -- requested, an item taken from them, a claim posted over theirs.
  local function event_line(e, me)
    if e.by == me then return nil end
    local tail = e.text and ' - ' .. e.text or ''
    if e.kind == 'research' then return nil end  -- research.lua gives each agent its own research lines
    if e.kind == 'plan' then
      -- Everyone hears of a plan edit once; a line written for me is mine.
      return string.format('team plan edited by %s: %s (board_plan shows it)', e.by, e.text or ''), e.owner ~= me
    end
    if e.overlaps and e.overlaps[me] then
      return string.format('#%d claim by %s overlaps your claim #%d: %s', e.id, e.by, e.overlaps[me], e.title)
    elseif (e.change == 'posted' or e.change == 'assigned') and e.owner == me and e.kind ~= 'claim' and e.kind ~= 'note' then
      return string.format('#%d assigned to you by %s: %s%s', e.id, e.by, e.title, tail)
    elseif e.requested_by == me and e.change ~= 'posted' then
      return e.change == 'note' and string.format('#%d (your %s) note by %s: %s', e.id, e.kind, e.by, e.text)
        or string.format('#%d (your %s) %s by %s: %s%s', e.id, e.kind, e.change, e.by, e.title, tail)
    elseif e.owner == me and e.change ~= 'posted' then
      return e.change == 'note' and string.format('#%d (yours) note by %s: %s', e.id, e.by, e.text)
        or string.format('#%d (yours) %s by %s: %s%s', e.id, e.change, e.by, e.title, tail)
    elseif e.prev_owner == me then
      return string.format('#%d (was yours) %s by %s%s: %s%s', e.id, e.change, e.by, e.owner and ' to ' .. e.owner or '', e.title, tail)
    elseif e.change == 'posted' and not e.owner and (e.kind == 'request' or e.kind == 'task') then
      -- Everyone hears of a new unowned request once; it wakes nobody.
      return string.format('#%d new unowned %s by %s: %s%s; take it with board_update {id, owner: "%s"}', e.id, e.kind, e.by, e.title, tail, me), true
    end
  end
  -- Events after `cursor`, oldest first, by index into the event log.
  local function first_after(b, cursor)
    local first = #b.events + 1
    while first > 1 and b.events[first - 1].seq > cursor do first = first - 1 end
    return first
  end
  -- For a sleeping agent (waits.lua): the newest board line for them after
  -- event `seq` (M.seq() when the sleep began), without delivering it (the
  -- reply's team block does).
  function M.seq() return store().seq end
  function M.news(p, seq)
    local b, me = store(), who(p)
    for k = #b.events, 1, -1 do
      local e = b.events[k]
      if e.seq <= seq then return nil end
      local line, broadcast = event_line(e, me)
      if line and not broadcast then return line end
    end
  end
  -- Board lines waiting for an agent's next reply (mention_counts).
  function M.unread_board(a)
    local h = api.state().team_hints and api.state().team_hints[a.index]
    local b, n = store(), 0
    for k = first_after(b, h and h.board or 0), #b.events do
      local line, broadcast = event_line(b.events[k], a.name)
      if line and not broadcast then n = n + 1 end
    end
    return n > 0 and n or nil
  end
  local function board_lines(p, h)
    local b = store()
    local me, lines, extra = who(p), {}, 0
    local from = h.board or 0
    h.board = b.seq
    -- Lines about my items first; new unowned requests fill what is left.
    local news = {}
    for k = first_after(b, from), #b.events do
      local line, broadcast = event_line(b.events[k], me)
      if line and broadcast then news[#news+1] = line
      elseif line then
        if #lines < MAX_BOARD_LINES then lines[#lines+1] = line else extra = extra + 1 end
      end
    end
    for _, line in ipairs(news) do
      if #lines < MAX_BOARD_LINES then lines[#lines+1] = line else extra = extra + 1 end
    end
    if extra > 0 then lines[#lines+1] = string.format('+%d more: board mine=true', extra) end
    -- Unowned requests: nudge once each time another one passes 2 minutes.
    -- The scan is shared by all agents for a second (kept in storage, so
    -- every peer computes the same hints); any board change redoes it.
    local aged = b.aged
    if not aged or game.tick - aged.tick >= 60 then
      aged = {tick=game.tick, n=0, newest=-1}
      for _, i in pairs(b.items) do
        if i.status == 'open' and not i.owner and (i.kind == 'task' or i.kind == 'request') and game.tick - i.created_tick >= UNOWNED_AGE then
          aged.n = aged.n + 1
          if not aged.oldest or i.created_tick < b.items[aged.oldest].created_tick then aged.oldest = i.id end
          if i.created_tick > aged.newest then aged.newest = i.created_tick end
        end
      end
      b.aged = aged
    end
    local n, newest, oldest = aged.n, aged.newest, aged.oldest and b.items[aged.oldest]
    if n > 0 and newest > (h.unowned or -1) then
      lines[#lines+1] = string.format('%d open request%s nobody owns (oldest %s: #%d %s); take one with board_update {id, owner: "%s"}',
        n, n == 1 and '' or 's', ago(game.tick - oldest.created_tick), oldest.id, oldest.title, me)
      h.unowned = newest
    end
    return #lines > 0 and lines or nil
  end
  local function alert_lines(p, h, losses)
    -- Hits and groups are numbered (threat.lua); an agent's first reply looks
    -- back one minute.
    local s, lines = api.state(), {}
    local from = h.alert_seq
    h.alert_seq = s.alert_seq or 0
    local function fresh(x, t) if from then return (x.seq or 0) > from end return t >= game.tick - FIRST_ALERTS end
    -- My character first: the agent can act on it at once.
    -- A dead agent has no character: its last one is remembered.
    local c = p.character
    local alive = c and c.valid
    if alive then h.unit = c.unit_number end
    local hit = h.unit and s.char_hits and s.char_hits[h.unit]
    if hit and fresh(hit, hit.last) then
      lines[#lines+1] = string.format('you were hit %d times (%d damage) by %s, %s ago; %s', hit.hits, round(hit.damage), hit.by or 'enemies',
        ago(game.tick - hit.last), alive and 'health ' .. round(c.health or 0) or 'your character died')
    end
    local areas = {}
    for key, v in pairs(s.damage or {}) do
      if fresh(v, v.last) and v.damage > 0 then areas[#areas+1] = {key=key, v=v} end
    end
    table.sort(areas, function(x, y) return x.v.last > y.v.last end)
    for n, area in ipairs(areas) do
      if n > 3 then lines[#lines+1] = string.format('+%d more attacked areas: status alerts', #areas - 3); break end
      local cx, cy = area.key:match('^(-?%d+),(-?%d+)$')
      local names = {}
      for name, count in pairs(area.v.entities) do names[#names+1] = name .. ' x' .. count end
      table.sort(names)
      while #names > 5 do table.remove(names) end
      lines[#lines+1] = string.format('attack near (%d,%d)%s: %s hit %d times, %d damage, %s ago', tonumber(cx) * 32 + 16, tonumber(cy) * 32 + 16,
        area.v.by and ' by ' .. area.v.by or '', table.concat(names, ', '), area.v.hits, round(area.v.damage), ago(game.tick - area.v.last))
    end
    local groups = 0
    for k = #(s.attack_groups or {}), 1, -1 do
      local g = s.attack_groups[k]
      if not fresh(g, g.tick) or groups >= 2 then break end
      groups = groups + 1
      lines[#lines+1] = string.format('enemy group of %d gathered at (%d,%d)%s, %s ago', g.size, g.position.x, g.position.y,
        g.target and string.format(' heading for (%d,%d)', g.target.x, g.target.y) or '', ago(game.tick - g.tick))
    end
    for _, line in ipairs(losses or {}) do lines[#lines+1] = line end
    while #lines > MAX_ALERT_LINES do table.remove(lines) end
    return #lines > 0 and lines or nil
  end
  -- Who hears what on the stream: once per agent (h.stream_note holds the
  -- version shown; a new version is shown once again).
  local STREAM_NOTE, STREAM_NOTE_VERSION = 'stream: viewers hear your say --aloud lines and confessions, spoken in your voice, '
    .. 'and like hearing from you every few minutes; other chat and tells show on the stream only as text, which viewers '
    .. 'read on screen, so write them as plain sentences with spaces between words', 2
  local function reminders(p, h)
    local out = {}
    if h.stream_note ~= STREAM_NOTE_VERSION then
      h.stream_note = STREAM_NOTE_VERSION
      out[#out+1] = STREAM_NOTE
    end
    local pr = api.profile(p.index)
    if not (pr and pr.display_name and pr.glyph and pr.color) and not (h.reminded and game.tick - h.reminded < REMIND_EVERY) then
      h.reminded = game.tick
      out[#out+1] = 'profile: viewers see you by display_name, glyph and color; set them once with profile {display_name, glyph, color, motto}'
    end
    return #out > 0 and out or nil
  end
  function M.team(p, losses)
    local h = hints(p.index)
    -- Mentions go first (insertion order is the JSON order).
    local out = {}
    out.mentions, out.tells = mentions(p)
    out.board = board_lines(p, h)
    out.research = api.research_lines and api.research_lines(p, h) or nil
    out.alerts = alert_lines(p, h, losses)
    out.reminders = reminders(p, h)
    return next(out) and out or nil
  end
  -- Engine hook (from threat.on_damaged): enemy hits on a character, kept
  -- per character entity; a quiet minute starts a new incident.
  function M.on_character_hit(event)
    local s = api.state()
    s.char_hits = s.char_hits or {}
    local e = event.entity
    local hit = s.char_hits[e.unit_number]
    if not hit or event.tick - hit.last > FIRST_ALERTS then
      for k, v in pairs(s.char_hits) do
        if event.tick - v.last > FIRST_ALERTS then s.char_hits[k] = nil end
      end
      hit = {hits=0, damage=0}
      s.char_hits[e.unit_number] = hit
    end
    hit.seq = s.alert_seq
    hit.last = event.tick; hit.hits = hit.hits + 1; hit.damage = hit.damage + (event.final_damage_amount or 0)
    hit.by = event.cause and event.cause.valid and event.cause.name or hit.by
  end
  return M
end
