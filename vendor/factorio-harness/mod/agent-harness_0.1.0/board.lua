-- Team board (shared tasks, requests, claims, notes and projects kept in the
-- save), its event log for the stream overlay, the per-agent `team` hint block
-- pushed on replies, agents' requests for harness tools, and saved queue plans.
-- Nothing here runs per tick: hints are computed when an agent's reply is
-- built, bounded by the board size and the chat/event logs.
return function(api)
  local M = {handlers={}}
  local MAX_ITEMS, MAX_EVENTS, MAX_NOTES, MAX_PLANS, MAX_HARNESS_OPEN, MAX_PLAN_BYTES = 300, 1000, 10, 50, 10, 65536
  local TITLE, NOTE, LONG = 120, 200, 1000
  local UNOWNED_AGE, REMIND_EVERY, FIRST_ALERTS = 7200, 3600, 3600
  local MAX_BOARD_LINES, MAX_ALERT_LINES, REPEAT_ATTACK = 5, 8, 7200
  local KINDS = {task=true, request=true, claim=true, note=true, harness=true, plan=true, project=true}
  -- The team plan: one living item (kind plan) with goals and a line per agent.
  local PLAN_GOALS, PLAN_LINE, PLAN_LINES, PLAN_HISTORY = 600, 160, 24, 10
  local STATUSES = {open=true, claimed=true, doing=true, done=true, blocked=true, dropped=true}
  local ACTIVE = {open=true, claimed=true, doing=true, blocked=true}
  local OPERATOR = 'operator'
  -- A task or request whose owner has made no request of their own for QUIET
  -- can be taken by anyone (shift07: #284 power held "doing" for two shifts).
  local QUIET = 20 * 3600
  local MAX_ALLOW = 8
  -- Projects (operator 00:50): long jobs that outlive an agent's context and
  -- its shift (a rail line, a nuclear plant, a robot mall). A goal, steps
  -- anyone adds and marks done (who did each), areas, notes, and a handoff
  -- text. The owner edits the goal, handoff and areas; anyone may when the
  -- project has no owner or its owner has made no request for 30 min, and
  -- may then take it. Open projects are never pruned.
  local PROJECT_QUIET, MAX_PROJECTS, MAX_STEPS, STEP, MAX_AREAS, MAX_PROJECT_NOTES, MAX_PROJECT_LINES = 30 * 3600, 30, 40, 160, 8, 20, 8
  local PROJECT_ARGS = {'step', 'done', 'undone', 'remove_step', 'goal', 'handoff', 'areas', 'take_step', 'release_step', 'open_steps'}
  -- Links between items (Foobator, d15 06:38 and 08:17; joonazan 08:20): blocked_by (items this one waits for) and
  -- parent (the project this one serves), on tasks, requests and projects; fields agents may use, not required.
  local LINK_KINDS, MAX_LINKS, COMPACT_OVER = {task=true, request=true, project=true}, 8, 1200
  -- Step changes by others reach a project's owner as news: they wake nobody.
  local STEP_CHANGES = {step_added=true, step_done=true, step_undone=true, step_removed=true}

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
  -- Ticks since agent `name`'s own last request (a peek is not one; nil: none
  -- yet), and its index (nil: not an agent here).
  local function since_request(name)
    for _, a in ipairs(agents()) do
      if a.name == name then
        local c = api.state().clocks and api.state().clocks[a.index]
        return c and game.tick - c.call_tick or nil, a.index
      end
    end
  end
  -- An agent as teammates see it: 'asleep 12m', 'last request 3m00s ago',
  -- 'no request yet'; nil for the operator or a name that is no agent.
  function M.owner_state(name)
    if name == OPERATOR then return nil end
    local since, index = since_request(name)
    if not index then return nil end
    local sl = api.state().sleeps and api.state().sleeps[index]
    if sl and sl.until_tick and sl.until_tick > game.tick and sl.start_tick then return 'asleep ' .. ago(game.tick - sl.start_tick) end
    return since and 'last request ' .. ago(since) .. ' ago' or 'no request yet'
  end
  local function quiet(name, ticks)
    if name == OPERATOR then return false end
    local since = since_request(name)
    return not since or since >= (ticks or QUIET)
  end
  -- `allow` on a claim: names (array, or one string split on commas and
  -- spaces) or everyone/team/all; empty clears it.
  local function allow_arg(v)
    if v == nil then return nil end
    local list = {}
    if type(v) == 'string' then for word in v:gmatch('[^,%s]+') do list[#list+1] = word end
    else
      assert(type(v) == 'table', 'allow is agent names (array or "luna,sol"), or "everyone"; [] or "" clears it')
      for _, word in ipairs(v) do assert(type(word) == 'string', 'allow takes agent names'); list[#list+1] = word end
    end
    local out, seen = {}, {}
    for _, word in ipairs(list) do
      local w = word:lower():gsub('^@', '')
      local name = (w == 'everyone' or w == 'team' or w == 'all') and 'everyone' or resolve(word)
      if not seen[name] then seen[name] = true; out[#out+1] = name end
    end
    assert(#out <= MAX_ALLOW, 'allow takes at most ' .. MAX_ALLOW .. ' names; use "everyone"')
    if seen.everyone then out = {'everyone'} end
    table.sort(out)
    return out
  end

  -- A project's steps are {n, text, by, tick, done_by?, done_tick?}; a step
  -- keeps its number n when another is removed.
  local function step_counts(i)
    local done = 0
    for _, s in ipairs(i.steps) do if s.done_by then done = done + 1 end end
    return done, #i.steps
  end
  local function progress(i)
    local done, total = step_counts(i)
    return total > 0 and string.format('%d of %d step%s', done, total, total == 1 and '' or 's') or 'no steps yet'
  end
  local function step_text(s)
    local tail = (s.owner and ' (' .. s.owner .. ')' or '') .. (s.parallel and ' (parallel)' or '')
    if not s.done_by then return string.format('[ ] %d. %s%s', s.n, s.text, tail) end
    return string.format('[x] %d. %s (done by %s, %s ago)', s.n, s.text, s.done_by, ago(game.tick - s.done_tick))
  end
  -- extra: prev_owner (an owner who lost the item in this change) and
  -- overlaps (owner -> their claim id, for a claim posted over theirs). A
  -- project's events carry its progress (steps_done of steps_total).
  local function event(by, item, change, text, extra)
    local b = store()
    b.aged = nil
    b.seq = b.seq + 1
    local done, total
    if item.kind == 'project' and item.steps then done, total = step_counts(item) end
    b.events[#b.events+1] = {seq=b.seq, tick=game.tick, by=by, id=item.id, change=change, title=item.title,
      kind=item.kind, owner=item.owner, requested_by=item.requested_by, status=item.status, text=text,
      prev_owner=extra and extra.prev_owner, overlaps=extra and extra.overlaps,
      progress=total and progress(item) or nil, steps_done=done, steps_total=total}
    while #b.events > MAX_EVENTS do table.remove(b.events, 1) end
  end
  -- Over the cap, finished items go first (oldest update first), then notes,
  -- then the oldest of anything but open projects (at most MAX_PROJECTS).
  local function prune()
    local b = store()
    while b.count > MAX_ITEMS do
      local victim
      for _, pass in ipairs{function(i) return i.status == 'done' or i.status == 'dropped' end,
          function(i) return i.kind == 'note' end, function(i) return i.kind ~= 'plan' and not (i.kind == 'project' and ACTIVE[i.status]) end,
          function(i) return i.kind ~= 'plan' end} do
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
  -- Claims with no activity by their owner for claims.EXPIRE close (dropped,
  -- a harness note, an `expired` event for the stream and board_events). A
  -- claim going stale or closing is told to its owner in one batched line
  -- (claims_digest), never a line per claim. Run before board reads, writes
  -- and each reply's team block, at most once a second.
  local DIGEST = 3 * 3600
  local function claim_news(owner)
    local b = store()
    b.claim_news = b.claim_news or {}
    b.claim_news[owner] = b.claim_news[owner] or {closed={}, stale={}}
    return b.claim_news[owner]
  end
  local function expire()
    local b = store()
    if b.expire_tick and game.tick - b.expire_tick < 60 then return end
    b.expire_tick = game.tick
    local ids = {}
    for id, i in pairs(b.items) do
      if i.kind == 'claim' and ACTIVE[i.status] then ids[#ids+1] = id end
    end
    table.sort(ids)
    for _, id in ipairs(ids) do
      local i = b.items[id]
      local last = api.claims.activity(i)
      local idle = game.tick - last
      local told = i.owner and i.owner ~= OPERATOR
      if idle >= api.claims.EXPIRE then
        local text = 'closed by the harness: no activity by its owner for ' .. ago(idle)
        i.status, i.updated_tick = 'dropped', game.tick
        i.notes[#i.notes+1] = {tick=game.tick, by='harness', text=text}
        while #i.notes > MAX_NOTES do table.remove(i.notes, 1) end
        event('harness', i, 'expired', text)
        if told then local n = claim_news(i.owner); n.closed[#n.closed+1] = {id=i.id, title=i.title} end
      elseif idle >= api.claims.STALE and i.stale_told ~= last then
        -- Once per stretch without activity: work on it again and a later stale mark is told again.
        i.stale_told = last
        if told then local n = claim_news(i.owner); n.stale[#n.stale+1] = i.id end
      end
    end
  end
  -- The owner's one line for claims that went stale or closed since the last
  -- one, at most every DIGEST; stale ones the owner has since worked on (or
  -- that closed) are left out.
  local function claims_digest(me, h)
    local b = store()
    local n = b.claim_news and b.claim_news[me]
    if not n or (h.claims_told and game.tick - h.claims_told < DIGEST) then return nil end
    local function names(list)
      local out = {}
      for k, x in ipairs(list) do
        if k > 6 then out[#out+1] = '+' .. (#list - 6) .. ' more'; break end
        out[#out+1] = '#' .. x.id .. ' ' .. x.title
      end
      return table.concat(out, ', ')
    end
    local stale = {}
    for _, id in ipairs(n.stale) do
      local i = b.items[id]
      if i and i.kind == 'claim' and ACTIVE[i.status] and api.claims.stale(i) then stale[#stale+1] = {id=i.id, title=i.title} end
    end
    b.claim_news[me] = nil
    if #n.closed == 0 and #stale == 0 then return nil end
    h.claims_told = game.tick
    local parts = {}
    if #n.closed > 0 then parts[#parts+1] = 'closed after 2h without your activity: ' .. names(n.closed) end
    if #stale > 0 then
      parts[#parts+1] = 'stale after 30 min without your activity (labelled stale, and teammates\' stock sweeps include its chests; work in it or update it to keep it fresh, or it closes 2h after your last activity): ' .. names(stale)
    end
    return 'your claims: ' .. table.concat(parts, '; ')
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
  -- What an item asks for, as one line: 'iron-plate*200, steel-plate'; 'none'.
  local function needs_text(v)
    if v == nil then return 'none' end
    if type(v) == 'string' then return "'" .. v .. "'" end
    local parts = {}
    for _, n in ipairs(v) do parts[#parts+1] = type(n) == 'table' and (n.name .. (n.count and '*' .. n.count or '')) or tostring(n) end
    return #parts > 0 and table.concat(parts, ', ') or 'none'
  end
  local function tags_arg(v)
    if v == nil then return nil end
    assert(type(v) == 'table' and #v <= 8, 'tags must be an array of up to 8 short strings')
    local out = {}
    for _, t in ipairs(v) do assert(type(t) == 'string', 'tags must be strings'); out[#out+1] = clip(t, 24) end
    return out
  end
  -- A project's areas: `area` (one) and/or `areas` (an array; [] clears).
  local function areas_arg(list, one)
    local out = {}
    if one ~= nil then out[1] = area_arg(one) end
    if type(list) == 'table' and list.left_top then list = {list} end
    if list ~= nil then
      assert(type(list) == 'table' and (#list > 0 or next(list) == nil), 'areas is an array of {left_top={x,y}, right_bottom={x,y}} ([] clears them)')
      for _, a in ipairs(list) do out[#out+1] = area_arg(a) end
    end
    assert(#out <= MAX_AREAS, 'a project takes at most ' .. MAX_AREAS .. ' areas')
    return out
  end
  -- Step texts: one text or an array of them.
  -- A step is a text, or {text, owner?, parallel?} (Foobator, d15 08:17): its own owner, and parallel: no order between
  -- it and the steps next to it that are parallel too.
  local function steps_arg(v, name)
    if type(v) == 'string' or (type(v) == 'table' and v.text ~= nil) then v = {v} end
    assert(type(v) == 'table' and #v >= 1, name .. ' is a text or an array of texts (or {text, owner?, parallel?}), each 1..' .. STEP .. ' characters')
    local out = {}
    for _, t in ipairs(v) do
      if type(t) == 'table' then
        assert(t.parallel == nil or type(t.parallel) == 'boolean', name .. ': parallel must be true or false')
        out[#out+1] = {text=required_text(t.text, name, STEP), owner=t.owner ~= nil and t.owner ~= '' and resolve(t.owner) or nil, parallel=t.parallel or nil}
      else out[#out+1] = {text=required_text(t, name, STEP)} end
    end
    return out
  end
  local function add_steps(item, texts, by)
    local added = {}
    for _, st in ipairs(texts) do
      local text = st.text
      item.steps[#item.steps+1] = {n=item.next_step, text=text, by=by, tick=game.tick, owner=st.owner, parallel=st.parallel}
      added[#added+1] = item.next_step .. '. ' .. text .. (st.owner and ' (' .. st.owner .. ')' or '') .. (st.parallel and ' (parallel)' or '')
      item.next_step = item.next_step + 1
    end
    return added
  end
  local function links_arg(v, self)
    if v == false or v == '' then return {} end
    if type(v) == 'number' then v = {v} end
    assert(type(v) == 'table' and #v <= MAX_LINKS, 'blocked_by takes item numbers: a number or an array of up to ' .. MAX_LINKS .. ' ([] clears)')
    local out, seen = {}, {}
    for _, id in ipairs(v) do
      assert(type(id) == 'number' and store().items[id], 'blocked_by: no board item #' .. tostring(id))
      assert(id ~= self, 'blocked_by: an item does not wait for itself')
      if not seen[id] then seen[id] = true; out[#out+1] = id end
    end
    return out
  end
  local function parent_arg(v, self)
    if v == false or v == '' or v == 0 then return false end
    local it = type(v) == 'number' and store().items[v]
    assert(it and it.kind == 'project', 'parent is a project\'s item number (false clears it)')
    assert(v ~= self, 'parent: a project is not its own parent')
    return v
  end
  -- Steps of project `item` by number: a number or an array of them.
  local function step_numbers(v, name, item)
    if type(v) == 'number' then v = {v} end
    assert(type(v) == 'table' and #v >= 1, name .. ' takes step numbers: a number or an array of them'
      .. (name == 'done' and ' (status "done" finishes the project)' or ''))
    local out, have = {}, {}
    for _, s in ipairs(item.steps) do have[#have+1] = s.n end
    for _, n in ipairs(v) do
      local found
      for _, s in ipairs(item.steps) do if s.n == n then found = s end end
      assert(found, string.format('project #%d has no step %s; its steps: %s', item.id, tostring(n),
        #have > 0 and table.concat(have, ', ') or 'none yet (add some with step)'))
      out[#out+1] = found
    end
    return out
  end
  local function overlaps(a, b)
    return a.left_top.x < b.right_bottom.x and b.left_top.x < a.right_bottom.x and a.left_top.y < b.right_bottom.y and b.left_top.y < a.right_bottom.y
  end
  -- A claim's surface argument: a surface name in this game (nauvis, gleba, platform-1, ...).
  local function surface_arg(v)
    assert(type(v) == 'string' and game.get_surface(v) ~= nil, 'surface must be a surface name (nauvis, vulcanus, gleba, fulgora, aquilo, or a platform\'s surface such as platform-1)')
    return game.get_surface(v).name
  end
  -- For reader `by`: a function owner -> 'on Vulcanus' when that agent is
  -- somewhere other than the reader (where.lua); nil for the operator.
  local function where_for(by)
    return by ~= OPERATOR and api.where_from and api.where_from(by) or nil
  end
  local function edited(by, tick) return by and string.format('by %s, %s ago', by, ago(game.tick - tick)) or nil end
  -- Title and needs changes, oldest first, with how long ago (board_update).
  local function history(i)
    if not i.edits or #i.edits == 0 then return nil end
    local out = {}
    for k, e in ipairs(i.edits) do out[k] = string.format('%s (%s ago)', e.text, ago(game.tick - e.tick)) end
    return out
  end
  -- A project as read: progress, the goal, its steps ([x] done, by whom and
  -- when; [ ] not yet), areas and the handoff. A list row has the first 3
  -- steps not done (next_steps) and the goal and handoff cut to 160.
  local function project_view(i, full)
    local notes = i.notes
    if not full and #notes > 2 then notes = {notes[#notes-1], notes[#notes]} end
    local steps = {}
    for _, s in ipairs(i.steps) do
      if full then steps[#steps+1] = step_text(s)
      elseif not s.done_by and #steps < 3 then steps[#steps+1] = step_text(s) end
    end
    local function cut(text) return text and not full and clip(text, 160) or text end
    return {id=i.id, kind=i.kind, title=i.title, owner=i.owner, owner_state=ACTIVE[i.status] and i.owner and M.owner_state(i.owner) or nil,
      requested_by=i.requested_by, status=i.status, progress=progress(i),
      goal=cut(i.goal), goal_edited=full and i.goal and edited(i.goal_by, i.goal_tick) or nil,
      steps=full and #steps > 0 and steps or nil, next_steps=not full and #steps > 0 and steps or nil,
      areas=#i.areas > 0 and i.areas or nil,
      handoff=cut(i.handoff), handoff_edited=i.handoff and edited(i.handoff_by, i.handoff_tick) or nil,
      needs=i.needs, tags=i.tags, notes=#notes > 0 and notes or nil, note_count=not full and #i.notes > 2 and #i.notes or nil,
      blocked_by=i.blocked_by, parent=i.parent, open_steps=i.open_steps,
      history=full and history(i) or nil, created_tick=i.created_tick, updated_tick=i.updated_tick}
  end
  -- What blocks an item: each blocked_by link with its title and state, and what blocks that in turn (2 deep), as
  -- "#497 Starling retrofit (claimed, 1 of 4) <- #510 steel for LDS (open)"; links to closed items are left out.
  local function chain(i, depth, seen)
    seen = seen or {[i.id]=true}
    local parts = {}
    for _, id in ipairs(i.blocked_by or {}) do
      local o = store().items[id]
      if o and ACTIVE[o.status] and not seen[id] then
        seen[id] = true
        local text = string.format('#%d %s (%s%s)', id, clip(o.title, 40), o.status, o.kind == 'project' and o.steps and ', ' .. progress(o) or '')
        if depth > 1 and o.blocked_by then
          local deeper = chain(o, depth - 1, seen)
          if #deeper > 0 then text = text .. ' <- ' .. table.concat(deeper, ', ') end
        end
        parts[#parts+1] = text
      end
    end
    return parts
  end
  -- The compact line (Foobator, d15 06:37: projects too large for the smaller models): goal (the title), owner, the
  -- next steps not done (parallel ones together, each step's own owner), what blocks it and its parent.
  local function project_compact(i)
    local parts = {string.format('#%d %s [%s] %s', i.id, clip(i.title, 60), i.owner or 'no owner',
      (function() local d, t = step_counts(i); return d .. '/' .. t end)())}
    local nexts = {}
    for _, st in ipairs(i.steps) do
      if not st.done_by then
        if #nexts == 0 or (st.parallel and nexts[#nexts].parallel) then
          nexts[#nexts+1] = {text=string.format('%d. %s%s', st.n, clip(st.text, 60), st.owner and ' @' .. st.owner or ''), parallel=st.parallel}
        else break end
        if #nexts >= 3 then break end
      end
    end
    if #nexts > 0 then
      local t = {}
      for k, x in ipairs(nexts) do t[k] = x.text end
      parts[#parts+1] = 'next ' .. table.concat(t, ' | ')
    end
    local c = chain(i, 2)
    if #c > 0 then parts[#parts+1] = 'blocked by ' .. table.concat(c, ', ')
    elseif i.status == 'blocked' then parts[#parts+1] = 'blocked' end
    local par = i.parent and store().items[i.parent]
    if par then parts[#parts+1] = string.format('part of #%d %s', par.id, clip(par.title, 40)) end
    if i.open_steps then parts[#parts+1] = 'steps open to all' end
    return table.concat(parts, '; ')
  end
  -- One line per open project (the shift block, board reads): progress, its
  -- owner and that agent's last request, the first step not done, and the
  -- handoff cut to 140.
  local function project_line(i)
    local st = i.owner and M.owner_state(i.owner)
    local parts = {string.format('#%d %s%s: %s', i.id, i.title, i.status == 'blocked' and ' (blocked)' or '', progress(i)),
      i.owner and 'owner ' .. i.owner .. (st and ' (' .. st .. ')' or '') or 'no owner'}
    for _, s in ipairs(i.steps) do
      if not s.done_by then parts[#parts+1] = string.format('next %d. %s', s.n, clip(s.text, 80)); break end
    end
    if i.handoff then parts[#parts+1] = 'handoff: ' .. clip(i.handoff, 140) end
    return table.concat(parts, '; ')
  end
  local function open_projects()
    local list = {}
    for _, i in pairs(store().items) do if i.kind == 'project' and ACTIVE[i.status] then list[#list+1] = i end end
    return list
  end
  -- Open projects as lines, those agent `me` owns first, then the newest;
  -- nil when there is none.
  -- form: 'compact', 'full', or nil: full while all its lines take at most COMPACT_OVER bytes, else compact.
  function M.project_lines(me, max, form)
    max = max or MAX_PROJECT_LINES
    local list = open_projects()
    table.sort(list, function(x, y)
      if (x.owner == me) ~= (y.owner == me) then return x.owner == me end
      return x.updated_tick > y.updated_tick or (x.updated_tick == y.updated_tick and x.id > y.id)
    end)
    local function lines(make)
      local out = {}
      for k, i in ipairs(list) do
        if k > max then out[#out+1] = string.format('+%d more: board {kind: "project"}', #list - max); break end
        out[k] = make(i)
      end
      return out
    end
    local out = lines(form == 'compact' and project_compact or project_line)
    local chosen = form or 'full'
    if form == nil then
      local n = 0
      for _, l in ipairs(out) do n = n + #l + 3 end
      if n > COMPACT_OVER then out = lines(project_compact); chosen = 'compact' end
    end
    return #out > 0 and out or nil, #out > 0 and chosen or nil
  end
  -- Steps of open projects that nobody owns and the agent may take (Foobator, d15 08:17; joonazan 08:16): of projects
  -- with open_steps, or with no owner; the first `max`.
  function M.open_steps(me, max)
    local out = {}
    for _, i in ipairs(open_projects()) do
      if (i.open_steps or not i.owner) and i.owner ~= me then
        for _, st in ipairs(i.steps or {}) do
          if not st.done_by and not st.owner then
            out[#out+1] = string.format('#%d step %d: %s (%s; take it with board_update {id: %d, take_step: %d})', i.id, st.n, clip(st.text, 60),
              i.owner and 'owner ' .. i.owner or 'no owner', i.id, st.n)
            if #out >= (max or 5) then return out end
          end
        end
      end
    end
    return #out > 0 and out or nil
  end
  local function view(i, full, where)
    if i.kind == 'project' then return project_view(i, full) end
    local notes = i.notes
    if not full and #notes > 2 then notes = {notes[#notes-1], notes[#notes]} end
    local claim = i.kind == 'claim' and ACTIVE[i.status]
    return {id=i.id, kind=i.kind, title=i.title, owner=i.owner, owner_away=i.kind == 'claim' and where and where(i.owner) or nil,
      -- An open claim: when its owner last worked on it, stale (stock sweeps include it), who it allows.
      owner_active=claim and ago(game.tick - api.claims.activity(i)) .. ' ago' or nil, stale=claim and api.claims.stale(i) or nil,
      allow=i.kind == 'claim' and i.allow or nil,
      requested_by=i.requested_by, status=i.status, area=i.area, surface=i.kind == 'claim' and api.claims.surface_of(i) or nil,
      needs=i.needs, tags=i.tags, problem=i.problem, proposal=i.proposal, blocked_by=i.blocked_by, parent=i.parent,
      notes=#notes > 0 and notes or nil, note_count=not full and #i.notes > 2 and #i.notes or nil,
      history=full and history(i) or nil, created_tick=i.created_tick, updated_tick=i.updated_tick}
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

  -- p: the poster (nil for the operator), whose surface a claim is on unless `surface` names one.
  local function post(by, a, p)
    local kind = a.kind
    assert(type(kind) == 'string' and KINDS[kind], 'kind must be task, request, claim, note or project')
    assert(kind ~= 'harness', 'ask for a harness tool with harness_request')
    assert(kind ~= 'plan', 'the team plan is one item: edit it with board_plan {goals} or {doing}')
    assert(a.allow == nil or kind == 'claim', 'allow is for a claim: the agents (names or \"everyone\") its labels name as allowed, whose own stock sweeps include its chests while it is fresh')
    assert(a.surface == nil or kind == 'claim', 'surface is for a claim (the surface its area is on)')
    assert(kind == 'project' or (a.goal == nil and a.steps == nil and a.areas == nil and a.handoff == nil),
      'goal, steps, areas and handoff are for kind project')
    assert(kind == 'project' or a.open_steps == nil, 'open_steps is for kind project')
    assert((a.blocked_by == nil and a.parent == nil) or LINK_KINDS[kind], 'blocked_by and parent are for a task, request or project')
    assert(a.open_steps == nil or type(a.open_steps) == 'boolean', 'open_steps must be true or false')
    expire()
    local item = {kind=kind, title=required_text(a.title, 'title', TITLE), requested_by=by, area=area_arg(a.area),
      needs=needs_arg(a.needs), tags=tags_arg(a.tags), notes={}, created_tick=game.tick, updated_tick=game.tick}
    if kind == 'claim' then
      item.active_tick = game.tick
      local allow = allow_arg(a.allow)
      item.allow = allow and #allow > 0 and allow or nil
      local here = p and pcall(function() return p.surface.name end) and p.surface.name or nil
      item.surface = a.surface ~= nil and surface_arg(a.surface) or here or 'nauvis'
    elseif kind == 'project' then
      assert(#open_projects() < MAX_PROJECTS, string.format('the board holds at most %d open projects; one closes with status done or dropped', MAX_PROJECTS))
      item.areas = areas_arg(a.areas, a.area)
      item.area = nil
      local goal = optional_text(a.goal, 'goal', PLAN_GOALS)
      if goal and goal:find('%S') then item.goal, item.goal_by, item.goal_tick = goal, by, game.tick end
      local texts = a.steps ~= nil and steps_arg(a.steps, 'steps') or {}
      assert(#texts <= MAX_STEPS, 'a project holds at most ' .. MAX_STEPS .. ' steps')
      item.steps, item.next_step = {}, 1
      add_steps(item, texts, by)
      local handoff = optional_text(a.handoff, 'handoff', LONG)
      if handoff and handoff:find('%S') then item.handoff, item.handoff_by, item.handoff_tick = handoff, by, game.tick end
      item.open_steps = a.open_steps or nil
    end
    if a.blocked_by ~= nil then local l = links_arg(a.blocked_by); item.blocked_by = #l > 0 and l or nil end
    if a.parent ~= nil then item.parent = parent_arg(a.parent) or nil end
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
      local where = where_for(by)
      for _, other in pairs(store().items) do
        if other.kind == 'claim' and ACTIVE[other.status] and other.owner ~= by and api.claims.surface_of(other) == item.surface
            and overlaps(other.area, item.area) then
          local away = where and where(other.owner)
          warnings[#warnings+1] = string.format('overlaps claim #%d by %s%s: %s (%s)', other.id, other.owner, away and ' (' .. away .. ')' or '', other.title,
            api.claims.state_text(other, {name=by}))
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
    local project = item.kind == 'project'
    local given = a.status ~= nil or a.owner ~= nil or a.note ~= nil or a.allow ~= nil or a.title ~= nil or a.needs ~= nil or a.surface ~= nil
      or a.blocked_by ~= nil or a.parent ~= nil
    assert((a.blocked_by == nil and a.parent == nil) or LINK_KINDS[item.kind], 'blocked_by and parent are for a task, request or project')
    local links = a.blocked_by ~= nil and links_arg(a.blocked_by, item.id) or nil
    local parent = a.parent ~= nil and parent_arg(a.parent, item.id) or nil
    for _, k in ipairs(PROJECT_ARGS) do
      assert(project or a[k] == nil, k .. ' is for a project (#' .. item.id .. ' is a ' .. item.kind .. ')'
        .. (k == 'done' and '; status "done" finishes an item' or ''))
      given = given or a[k] ~= nil
    end
    assert(given, 'give status, owner, note, allow, title, needs or (a claim) surface' .. (project and '; for a project also step, done, undone, remove_step, goal, handoff or areas' or ''))
    expire()
    -- Check every argument before changing anything.
    assert(a.status == nil or (type(a.status) == 'string' and STATUSES[a.status]), 'status must be open, claimed, doing, done, blocked or dropped')
    local text = a.note ~= nil and required_text(a.note, 'note', NOTE) or nil
    local boss = by == OPERATOR or by == item.owner or by == item.requested_by
    local changes, was = {}, item.owner
    assert(item.kind ~= 'plan' or (a.status == nil and a.owner == nil), 'the team plan changes with board_plan {goals} or {doing}; notes are fine')
    -- Title and needs (Astra, shift10: a request's ask could not be corrected
    -- after posting): its poster, owner or the operator; anyone once the one
    -- responsible (the owner, else the poster) has made no request for 20 min
    -- (a project's for 30; a project with no owner: anyone, as its goal).
    local edit = {}
    if a.title ~= nil or a.needs ~= nil then
      assert(item.kind ~= 'plan', 'the team plan changes with board_plan {goals} or {doing}')
      local ticks = project and PROJECT_QUIET or QUIET
      local lead = item.owner or item.requested_by
      local ok = by == OPERATOR or by == item.owner or by == item.requested_by or (project and not item.owner) or quiet(lead, ticks)
      if not ok then
        local st = M.owner_state(lead)
        error(string.format('only its poster (%s), its owner (%s) or the operator changes the title and needs of #%d, or anyone once %s has made no request for %d min (%s)',
          tostring(item.requested_by), tostring(item.owner or 'none'), item.id, lead, ticks / 3600, st or 'quiet'), 0)
      end
      if a.title ~= nil then edit.title = required_text(a.title, 'title', TITLE) end
      if a.needs ~= nil then
        if a.needs == '' or a.needs == false or (type(a.needs) == 'table' and next(a.needs) == nil) then edit.needs = false
        else edit.needs = needs_arg(a.needs) end
      end
    end
    local allow
    if a.allow ~= nil then
      assert(item.kind == 'claim', 'allow is for a claim: the agents (names or \"everyone\") its labels name as allowed, whose own stock sweeps include its chests while it is fresh')
      assert(boss, string.format('only the owner (%s) can change who claim #%d allows', tostring(item.owner), item.id))
      allow = allow_arg(a.allow)
    end
    local surface
    if a.surface ~= nil then
      assert(item.kind == 'claim', 'surface is for a claim (the surface its area is on)')
      assert(by == OPERATOR or by == item.owner, string.format('only the owner (%s) can change the surface of claim #%d', tostring(item.owner), item.id))
      surface = surface_arg(a.surface)
    end
    -- A project: anyone adds steps and marks them done or undone; its owner
    -- (anyone when it has none, or its owner has made no request for 30 min)
    -- edits the goal, handoff and areas; a step goes with its owner's or its
    -- adder's word.
    local pj = {}
    if project then
      local lead = by == OPERATOR or by == item.owner or not item.owner or quiet(item.owner, PROJECT_QUIET)
      local function owner_only(what)
        if lead then return end
        local st = M.owner_state(item.owner)
        error(string.format('%s until its owner has made no request for 30 min; #%d is owned by %s (%s)', what, item.id, item.owner, st or 'quiet'), 0)
      end
      if a.step ~= nil then pj.add = steps_arg(a.step, 'step') end
      if a.done ~= nil then pj.done = step_numbers(a.done, 'done', item) end
      if a.undone ~= nil then pj.undone = step_numbers(a.undone, 'undone', item) end
      if a.remove_step ~= nil then
        pj.remove = step_numbers(a.remove_step, 'remove_step', item)
        for _, s in ipairs(pj.remove) do
          if s.by ~= by then owner_only(string.format('step %d of #%d was added by %s: only %s or the owner removes it', s.n, item.id, s.by, s.by)) end
        end
      end
      assert(#item.steps + (pj.add and #pj.add or 0) - (pj.remove and #pj.remove or 0) <= MAX_STEPS,
        string.format('a project holds at most %d steps; #%d has %d', MAX_STEPS, item.id, #item.steps))
      if a.goal ~= nil or a.handoff ~= nil or a.areas ~= nil then owner_only('only the owner edits the goal, handoff and areas of #' .. item.id) end
      if a.goal ~= nil then pj.goal = optional_text(a.goal, 'goal', PLAN_GOALS) end
      -- take_step / release_step (Foobator, d15 08:17): a step's own owner. Yours to take when you lead the project,
      -- added the step, or the project has open_steps (its owner's choice); release: the step's owner or a lead.
      if a.open_steps ~= nil then
        assert(type(a.open_steps) == 'boolean', 'open_steps must be true or false')
        owner_only('only the owner opens or closes the steps of #' .. item.id)
        pj.open_steps = a.open_steps
      end
      if a.take_step ~= nil then
        pj.take = step_numbers(a.take_step, 'take_step', item)
        for _, st in ipairs(pj.take) do
          if not (lead or st.by == by or item.open_steps or pj.open_steps) then
            error(string.format('step %d of #%d is %s\'s project\'s: its owner opens the steps to all with open_steps: true, or gives you one with step {text, owner}', st.n, item.id, item.owner), 0)
          end
          assert(not st.owner or st.owner == by or lead, string.format('step %d of #%d is taken by %s', st.n, item.id, tostring(st.owner)))
        end
      end
      if a.release_step ~= nil then
        pj.release = step_numbers(a.release_step, 'release_step', item)
        for _, st in ipairs(pj.release) do
          assert(st.owner == by or lead, string.format('step %d of #%d is %s\'s to release (or a lead\'s)', st.n, item.id, tostring(st.owner or 'nobody')))
        end
      end
      if a.handoff ~= nil then pj.handoff = optional_text(a.handoff, 'handoff', LONG) end
      if a.areas ~= nil then pj.areas = areas_arg(a.areas) end
    end
    if a.owner ~= nil then
      assert(item.kind ~= 'claim' and item.kind ~= 'note' and item.kind ~= 'harness', 'a ' .. item.kind .. ' stays with its poster'
        .. (item.kind == 'claim' and '; a claim goes stale after 30 min and closes by itself after 2h without its owner\'s activity' or ''))
      if a.owner == '' or a.owner == false then
        assert(boss, 'only the owner or requester can release an item')
        if item.owner then item.owner = nil; item.status = 'open'; changes[#changes+1] = 'released' end
      else
        local owner = resolve(a.owner)
        local taking = owner == by and not item.owner and item.status == 'open'
        -- An owner quiet for 20 min (a project's for 30) loses an active item to whoever takes it.
        local from_quiet = owner == by and item.owner and item.owner ~= by and ACTIVE[item.status] and quiet(item.owner, project and PROJECT_QUIET or nil)
        if not (boss or taking or from_quiet) then
          local st = item.owner and M.owner_state(item.owner)
          error(string.format('#%d is %s%s; only its owner or requester can reassign it (anyone can take an open unowned item, or one whose owner has made no request for %d min)',
            item.id, item.owner and 'owned by ' .. item.owner or item.status, st and ' (' .. st .. ')' or '', (project and PROJECT_QUIET or QUIET) / 3600), 0)
        end
        if owner ~= item.owner then
          if from_quiet then
            local st = M.owner_state(item.owner)
            text = text or clip('taken from ' .. item.owner .. ' (' .. (st or 'quiet') .. ')', NOTE)
          end
          item.owner = owner
          if item.status == 'open' then item.status = 'claimed' end
          changes[#changes+1] = owner == by and 'taken' or 'assigned'
          boss = true
        end
      end
    end
    if allow then
      item.allow = #allow > 0 and allow or nil
      changes[#changes+1] = 'allow'
      text = text or (item.allow and 'allows ' .. table.concat(item.allow, ', ') or 'allows nobody')
    end
    if surface then
      item.surface = surface
      changes[#changes+1] = 'surface'
      text = text or ('on ' .. surface)
    end
    -- The claim's owner working on it keeps it fresh (claims.lua).
    if item.kind == 'claim' and by == item.owner then api.claims.touch(item) end
    if a.status ~= nil then
      assert(boss, string.format('only the owner (%s) or requester (%s) can change the status of #%d; add a note instead',
        tostring(item.owner or 'none'), tostring(item.requested_by), item.id))
      if a.status ~= item.status then
        item.status = a.status
        if a.status ~= 'open' and not item.owner then item.owner = by end
        changes[#changes+1] = a.status
      end
    end
    -- A project's own changes, each an event with what changed and the progress.
    local done_changes, gone = {}, {}
    local function changed(change, what) done_changes[#done_changes+1] = {change=change, text=clip(what, NOTE)} end
    if pj.remove then
      local names = {}
      for _, s in ipairs(pj.remove) do gone[s] = true; names[#names+1] = s.n .. '. ' .. s.text end
      local keep = {}
      for _, s in ipairs(item.steps) do if not gone[s] then keep[#keep+1] = s end end
      item.steps = keep
      changed('step_removed', table.concat(names, '; '))
    end
    if pj.add then changed('step_added', table.concat(add_steps(item, pj.add, by), '; ')) end
    for _, mark in ipairs{{list=pj.done, done=true, change='step_done'}, {list=pj.undone, done=false, change='step_undone'}} do
      local names = {}
      for _, s in ipairs(mark.list or {}) do
        if not gone[s] and (s.done_by ~= nil) ~= mark.done then
          if mark.done then s.done_by, s.done_tick = by, game.tick else s.done_by, s.done_tick = nil, nil end
          names[#names+1] = s.n .. '. ' .. s.text
        end
      end
      if #names > 0 then changed(mark.change, table.concat(names, '; ')) end
    end
    if a.goal ~= nil and (pj.goal:find('%S') and pj.goal or nil) ~= item.goal then
      item.goal = pj.goal:find('%S') and pj.goal or nil
      item.goal_by, item.goal_tick = item.goal and by, item.goal and game.tick
      changed('goal', item.goal or 'goal cleared')
    end
    if a.handoff ~= nil and (pj.handoff:find('%S') and pj.handoff or nil) ~= item.handoff then
      item.handoff = pj.handoff:find('%S') and pj.handoff or nil
      item.handoff_by, item.handoff_tick = item.handoff and by, item.handoff and game.tick
      changed('handoff', item.handoff or 'handoff cleared')
    end
    if pj.take then
      local names = {}
      for _, st in ipairs(pj.take) do if st.owner ~= by then st.owner = by; names[#names+1] = st.n .. '. ' .. st.text end end
      if #names > 0 then changed('step_taken', by .. ': ' .. table.concat(names, '; ')) end
    end
    if pj.release then
      local names = {}
      for _, st in ipairs(pj.release) do if st.owner then st.owner = nil; names[#names+1] = st.n .. '. ' .. st.text end end
      if #names > 0 then changed('step_released', table.concat(names, '; ')) end
    end
    if pj.open_steps ~= nil and (item.open_steps == true) ~= pj.open_steps then
      item.open_steps = pj.open_steps or nil
      changed('open_steps', pj.open_steps and 'steps open to all' or 'steps closed')
    end
    if links then
      item.blocked_by = #links > 0 and links or nil
      local ids = {}
      for _, id in ipairs(links) do ids[#ids+1] = '#' .. id end
      changed('blocked_by', #ids > 0 and 'blocked by ' .. table.concat(ids, ', ') or 'blocked_by cleared')
    end
    if parent ~= nil then
      item.parent = parent or nil
      changed('parent', parent and 'part of #' .. parent or 'parent cleared')
    end
    if pj.areas then
      item.areas = pj.areas
      changed('areas', #pj.areas > 0 and #pj.areas .. ' area' .. (#pj.areas == 1 and '' or 's') or 'areas cleared')
    end
    -- Title and needs: the change in the item's history and an event each.
    local function remember(line)
      item.edits = item.edits or {}
      item.edits[#item.edits+1] = {tick=game.tick, by=by, text=clip(line, LONG)}
      while #item.edits > MAX_NOTES do table.remove(item.edits, 1) end
    end
    if edit.title and edit.title ~= item.title then
      local old = item.title
      item.title = edit.title
      remember(string.format("title changed by %s: '%s' -> '%s'", by, old, edit.title))
      changed('title_changed', 'was: ' .. old)
    end
    if edit.needs ~= nil then
      local old, new = needs_text(item.needs), needs_text(edit.needs or nil)
      if old ~= new then
        item.needs = edit.needs or nil
        remember(string.format('needs changed by %s: %s -> %s', by, old, new))
        changed('needs_changed', new .. ' (was ' .. old .. ')')
      end
    end
    if text then
      item.notes[#item.notes+1] = {tick=game.tick, by=by, text=text}
      while #item.notes > (project and MAX_PROJECT_NOTES or MAX_NOTES) do table.remove(item.notes, 1) end
    end
    item.updated_tick = game.tick
    local extra = was and was ~= item.owner and {prev_owner=was} or nil
    for _, change in ipairs(changes) do event(by, item, change, text, extra) end
    for _, c in ipairs(done_changes) do event(by, item, c.change, c.text); changes[#changes+1] = c.change end
    if text and #changes == #done_changes then event(by, item, 'note', text) end
    return {item=view(item, true, where_for(by)), changed=#changes > 0 and changes or nil}
  end

  -- About how many bytes a value takes as JSON (brief listings stay near 3 KB).
  local BRIEF_BYTES = 3000
  local function size(v)
    local t = type(v)
    if t == 'string' then return #v + 3 end
    if t ~= 'table' then return 6 end
    local n = 2
    for k, x in pairs(v) do n = n + size(k) + size(x) + 1 end
    return n
  end
  local function read(by, a)
    expire()
    local b = store()
    if a.id ~= nil then
      local item = b.items[a.id]
      assert(item, 'no board item #' .. tostring(a.id))
      return {item=view(item, true, where_for(by))}
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
    assert(a.kind == nil or KINDS[a.kind], 'kind must be task, request, claim, note, project, harness or plan')
    assert(a.since_tick == nil or type(a.since_tick) == 'number', 'since_tick must be a tick')
    assert(a.plan_ticks == nil or type(a.plan_ticks) == 'boolean', 'plan_ticks must be true or false')
    -- An agent's plain listing (no filter, no limit): about 3 KB, newest
    -- first, each item with its last note; the plan's goals and the reader's
    -- own line, and a line per open project (agent-minds study: the median
    -- board read was 18 KB, and Codex drops the middle of long output).
    -- full=true, a limit or a filter list them as before.
    local brief = by ~= OPERATOR and a.full ~= true and a.limit == nil and a.kind == nil and a.mine == nil and a.status == nil and a.since_tick == nil
    local list, finished = {}, 0
    for _, i in pairs(b.items) do
      -- The plain listing holds active items only (Foobator, d15 09:46: done and dropped ones filled it); the finished
      -- ones are counted.
      if brief and i.kind ~= 'plan' and not ACTIVE[i.status] then finished = finished + 1
      -- The plan is shown on its own (plan below), not as a row; so are open projects in the plain listing.
      elseif i.kind ~= 'plan' and not (brief and i.kind == 'project' and ACTIVE[i.status])
          and (not want or want[i.status]) and (not a.kind or i.kind == a.kind) and (not a.since_tick or i.updated_tick > a.since_tick)
          and (a.mine ~= true or i.owner == by or i.requested_by == by) then
        list[#list+1] = i
      end
    end
    table.sort(list, function(x, y) return x.updated_tick > y.updated_tick or (x.updated_tick == y.updated_tick and x.id > y.id) end)
    local out, where = {}, where_for(by)
    local unowned = open_unowned()
    local plan = (a.kind == nil or a.kind == 'plan') and a.mine ~= true and M.plan_view(a.plan_ticks == true) or nil
    if brief then
      local used = 0
      if plan then
        local doing = {}
        for i, l in ipairs(plan.doing or {}) do doing[i] = clip(l, 100) end
        plan = {id=plan.id, goals=plan.goals, doing=#doing > 0 and doing or nil, edited=plan.edited,
          more='board_plan shows the plan in full'}
        used = size(plan)
      end
      assert(a.projects == nil or a.projects == 'compact' or a.projects == 'full', 'projects must be compact or full')
      local projects, form = M.project_lines(by, nil, a.projects)
      if projects then used = used + size(projects) end
      local steps_open = M.open_steps(by)
      if steps_open then used = used + size(steps_open) end
      for n = 1, math.min(limit, #list) do
        local row = view(list[n], false, where)
        if row.notes and #row.notes > 1 then row.note_count = row.note_count or #list[n].notes; row.notes = {row.notes[#row.notes]} end
        row.created_tick = nil
        local s = size(row)
        if n > 1 and used + s > BRIEF_BYTES then break end
        out[n] = row; used = used + s
      end
      local more = #list - #out
      return {plan=plan, projects=projects, projects_form=form and (form == 'compact' and 'compact (board {projects: "full"} for the full lines)' or 'full') or nil,
        open_steps=steps_open, items=out, matched=#list, open_unowned=unowned, tick=game.tick,
        finished_left_out=finished > 0 and string.format('%d finished (done or dropped) left out: board {"status": "done"} (or "dropped", or {"full": true}) lists them', finished) or nil,
        more=more > 0 and string.format('%d more: board {full=true}, or narrow with kind, mine, status, since_tick; {id} shows one item in full', more) or nil}
    end
    for n = 1, math.min(limit, #list) do out[n] = view(list[n], false, where) end
    return {plan=plan, items=out, matched=#list, open_unowned=unowned, tick=game.tick}
  end

  -- The team plan: goals (anyone edits) and one line per agent ("who is on
  -- what"; anyone may write any agent's line, it shows who wrote it).
  local function plan_item()
    local b = store()
    return b.plan_id and b.items[b.plan_id]
  end
  -- ticks (the board read's plan_ticks; the pog site's Team plan, viewer Alex 22:12): also each line as {agent, text,
  -- by, tick} (the tick it was set), goals_tick (when the goals were last set; none for goals set before 2026-10-14
  -- 22:30) and updated_tick (the plan's last edit).
  function M.plan_view(ticks)
    local i = plan_item()
    if not i then return nil end
    local lines, rows = {}, {}
    for _, l in ipairs(i.lines) do
      lines[#lines+1] = l.agent .. ': ' .. l.text .. (l.by ~= l.agent and ' (set by ' .. l.by .. ')' or '')
      rows[#rows+1] = {agent=l.agent, text=l.text, by=l.by, tick=l.tick}
    end
    return {id=i.id, goals=i.goals, doing=#lines > 0 and lines or nil,
      edited=i.edited_by and string.format('by %s, %s ago', i.edited_by, ago(game.tick - i.updated_tick)) or nil,
      lines=ticks and rows or nil, goals_tick=ticks and i.goals and i.goals_tick or nil, updated_tick=ticks and i.updated_tick or nil}
  end
  -- The plan's goals, agent `name`'s own line and the open projects (the
  -- shift block), or nil.
  function M.plan_for(name)
    local i = plan_item()
    local projects = M.project_lines(name)
    if not i and not projects then return nil end
    local mine
    for _, l in ipairs(i and i.lines or {}) do if l.agent == name then mine = l.text end end
    return {goals=i and i.goals, mine=mine, projects=projects}
  end
  -- The look-ahead block (lookahead.lua): agent `name`'s plan line with the tick it was set, the goals, and the
  -- items it owns that are open, newest first.
  function M.lookahead_view(name)
    local i = plan_item()
    local mine
    for _, l in ipairs(i and i.lines or {}) do if l.agent == name then mine = l end end
    local open = {}
    for _, x in pairs(store().items) do
      if x.owner == name and ACTIVE[x.status] and x.kind ~= 'plan' then open[#open+1] = x end
    end
    table.sort(open, function(x, y) return x.updated_tick > y.updated_tick or (x.updated_tick == y.updated_tick and x.id > y.id) end)
    local items = {}
    for k, x in ipairs(open) do
      if k > 6 then items[#items+1] = string.format('+%d more', #open - 6); break end
      items[#items+1] = string.format('#%d %s (%s %s)', x.id, clip(x.title or '', 60), x.kind, x.status)
    end
    return {line=mine and mine.text, line_tick=mine and mine.tick, line_by=mine and mine.by ~= name and mine.by or nil,
      goals=i and i.goals, items=items}
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
      item.goals_tick = goals and game.tick or nil
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
    board = {full='boolean: the plain listing in full (by default it is about 3 KB: the newest items with their last note, the plan\'s goals and your line, and more: how many were left out)',
      mine='boolean: items I own or requested', status='active|open|claimed|doing|done|blocked|dropped or an array of them',
      kind='task|request|claim|note|project|harness|plan', since_tick='items updated after this tick', limit='1..100 (default 30), newest first',
      id='one item in full (all notes; a project with all its steps)',
      plan_ticks='boolean: the plan also as lines [{agent, text, by, tick}] (the tick each line was set), goals_tick and updated_tick',
      projects='compact | full: the open projects\' lines in the plain listing; default full while they take at most 1200 bytes, else compact (projects_form says which): "#476 Aquilo landing [sol] 2/5; next 3. Ride the rocket | 4. Drop the kit @luna; blocked by #497 Starling retrofit (claimed, 1 of 4); part of #400 Aquilo; steps open to all". The listing also has open_steps: steps of projects with open_steps or no owner that nobody owns, and how to take one',
      returns='the plain read (no filter, no limit) lists active items only (open, claimed, doing, blocked) and says how many finished ones it left out (finished_left_out); plan (the team plan: goals, doing lines, last edit), projects (the plain listing: one line per open project, yours first: progress, owner, next step, handoff; the rows leave them out), items, matched, open_unowned (open task/request items nobody owns); a project row has progress ("3 of 7 steps"), goal, next_steps, areas, handoff and owner_state (its owner\'s last request); a claim whose owner is now somewhere other than you has owner_away ("on Vulcanus"); an open claim has owner_active (when its owner last posted, updated it, or made a request standing in it or acting on a position in it), stale=true after 30 min of that (labelled stale; teammates\' stock sweeps include its chests) and allow (agents its labels name as allowed; their stock sweeps include it while it is fresh); the harness enforces no other rule on a claim (who may remove or rebuild what is the team\'s own); after 2 h with no such activity the harness closes it (dropped)'},
    board_plan = {goals='the team goals, 1..600 characters, replace the current ones ("" clears them)',
      doing='one line of what an agent is on, 1..160 characters ("" removes the line)', agent='whose line doing sets (default you)',
      returns='the team plan: goals, doing (one line per agent, "(set by NAME)" when someone else wrote it), edited; with no arguments it only reads'},
    board_post = {kind='task|request|claim|note|project', title='1..120 characters (longer is cut)',
      owner='agent name or display name (task/request/project; a request without owner is shown to everyone until taken; a project may have none)',
      area='{left_top={x,y}, right_bottom={x,y}}: required for a claim (owner is you)', needs='text, array of item names/{name,count}, or {item: count}',
      surface='claim only: the surface its area is on (default yours; nauvis, gleba, platform-1, ...); positions on other surfaces are never in it',
      tags='up to 8 short strings', note='optional first note, 1..200 characters',
      allow='claim only: agents its labels name as allowed, whose stock sweeps include its chests while it is fresh (array or "luna,sol"), or "everyone"; the harness enforces nothing else',
      goal='project only: what it is for, 1..600 characters', steps='project only: its checklist, an array of texts (1..160 characters each, at most 40), or of {text, owner? (that step\'s own owner), parallel? (true: no order between it and the parallel steps next to it)}',
      blocked_by='task, request or project: item numbers it waits for (1..8); the compact project line shows them and what blocks those', parent='task, request or project: the project it serves (a long-term goal such as "Aquilo landing")',
      open_steps='project only: true lets anyone take an unowned step (board_update take_step)',
      areas='project only: up to 8 areas {left_top, right_bottom} (area takes one)', handoff='project only: where it stands for whoever goes on with it, 1..1000 characters',
      returns='the item; warnings for overlapping claims (with where the owner is when not with you: claim #128 by sol (on Vulcanus), its age, owner activity and state, stale) or an unowned request'},
    board_update = {id='item number', status='open|claimed|doing|done|blocked|dropped (owner or requester only)',
      owner='your name takes an open unowned item, or an active task/request whose owner has made no request for 20 min (a project: 30 min); another name reassigns (owner or requester only); "" releases it',
      note='1..200 characters, anyone may add (last 10 kept; 20 on a project)',
      allow='claim owner only: agents its labels name as allowed, whose stock sweeps include its chests while it is fresh (names or "everyone"; [] or "" clears it)',
      surface='claim owner only: the surface its area is on',
      step='project: add steps, a text or an array of texts or {text, owner?, parallel?} (anyone)', done='project: mark steps done by number, a number or an array (anyone; done_by is you)',
      undone='project: mark steps not done (anyone)', remove_step='project: remove steps by number (the agent who added one, or the owner)',
      goal='project: replace the goal ("" clears it)', handoff='project: replace the handoff text, 1..1000 characters ("" clears it)',
      areas='project: replace its areas (array; [] clears them)',
      take_step='project: take steps by number for yourself (you lead it, added the step, or it has open_steps)', release_step='project: give up a step\'s owner (that owner or a lead)',
      open_steps='project owner: true lets anyone take an unowned step, false stops it',
      blocked_by='task, request or project: replace the items it waits for (numbers; [] clears)', parent='task, request or project: the project it serves (false clears)',
      title='replace the title, 1..120 characters (its poster, owner or the operator; anyone once the owner, or the poster of an unowned item, has made no request for 20 min, 30 on a project; a project with no owner: anyone)',
      needs='replace what it asks for: text, an array of item names or {name,count}, or {item: count} ("" or [] clears it); who may: as title',
      returns='the item in full and changed; on a project the goal, handoff and areas are its owner\'s to edit, and anyone\'s when it has no owner or its owner has made no request for 30 min (who may then also take it with owner); a title or needs change is kept in the item\'s history ("title changed by astra: \'old\' -> \'new\'", last 10) and told to its owner and poster'},
    board_events = {since_seq='return events after this sequence number (default 0)', limit='1..200 (default 100), oldest first',
      returns='events {seq,tick,by,id,change,title,kind,owner,requested_by,status,text; a project\'s also progress, steps_done, steps_total} and cursor (pass it back as since_seq)'},
    harness_request = {title='1..120 characters', problem='what you tried and what went wrong (1..1000)', proposal='optional: the tool or change you want',
      returns='a board item (kind harness, owner operator); answers come as notes on it'},
    plan_save = {name='1..32 letters, digits, _ - .', steps='queue plan steps (same schema as queue_submit)', guards='optional queue guards',
      note='optional description', delete='true removes the saved plan', returns='name, steps, bytes'},
    plan_run = {name='saved plan name', mode='append|replace pending (default append)', start='default true', returns='as queue_submit'},
    plans = {name='optional: show one plan in full', returns='your saved plans (at most 50): name, steps, note, runs'},
    mention_counts = {returns='per agent: unread_mentions (not yet shown in a reply or chat read), at_mentions (@name or @everyone), oldest_tick, latest, fyi (fyi tells waiting, left out of the other counts: no reason to wake), last_request_tick (supervisors: wake idle mentioned agents)'},
  }
  -- Handlers take the acting agent's name, so the operator path can share them.
  M.handlers.board = function(p, a) return read(who(p), a) end
  M.handlers.board_post = function(p, a) return post(who(p), a, p) end
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
  -- mention only for an agent it names with @; it wakes a sleeper only one
  -- that asked (inbox_tick viewers).
  function M.on_viewer(m)
    local text = m.text:lower()
    for _, a in ipairs(agents()) do
      if mention_how(a, text, false) == '@' then
        local box = inbox(a.index)
        box.list[#box.list+1] = {seq=m.seq, tick=m.tick, from=m.from, text=m.text, how='@', viewer=true, source=m.source}
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
    -- An fyi tell (tells.lua) waits for the next reply: it wakes nobody (waits.lua) and supervisors don't count it.
    box.list[#box.list+1] = {tell=t.seq, tick=t.tick, from=t.from, text=t.text, how='tell', team=t.team, fyi=t.fyi}
    while #box.list > MAX_PENDING do table.remove(box.list, 1); box.dropped = box.dropped + 1 end
  end
  -- The tick of the newest undelivered mention or tell (nil when none), for
  -- waits that end when one arrives; then told|mentioned and who sent it. An
  -- fyi tell (eng/minds-claims, tell --fyi) wakes nobody, so it ends no wait.
  -- A viewer's @mention (on_viewer) waits for the next reply too and wakes nobody unless asked (viewers: the call's
  -- wake_on_viewers, fh --wake-on-viewers; Sonnet and Opus, shift12 13:50: viewers' @mentions ended a sleep, a wait
  -- and a move_to --wait every minute or so).
  function M.inbox_tick(index, viewers)
    local box = api.state().mentions and api.state().mentions[index]
    for i = #(box and box.list or {}), 1, -1 do
      local m = box.list[i]
      if not m.fyi and (viewers or not m.viewer) then return m.tick, m.tell and 'told' or 'mentioned', m.from end
    end
    return nil
  end
  -- The newest viewer's @mention waiting for the next reply (an fh --wait with --wake-on-viewers ends on it).
  function M.viewer_tick(index)
    local box = api.state().mentions and api.state().mentions[index]
    for i = #(box and box.list or {}), 1, -1 do
      local m = box.list[i]
      if m.viewer then return m.tick, 'mentioned', m.from end
    end
    return nil
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
  -- What the last team block delivered per agent (mentions and tells as filed), read once by the dispatch for a
  -- sleep's replies (missed.lua); never kept past the request that built it.
  local delivered = {}
  function M.delivered(index)
    local d = delivered[index]
    delivered[index] = nil
    return d
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
    -- A sender on another planet says where (where.lua).
    local where = #box.list > 0 and api.where_from and api.where_from(who(p))
    local function from(m)
      if m.source then return m.from .. ' (' .. m.source .. ')' end  -- a viewer: where they wrote, YouTube or site
      local w = where and where(m.from)
      return w and m.from .. ' (' .. w .. ')' or m.from
    end
    for _, m in ipairs(box.list) do
      if m.tell then
        tells[#tells+1] = string.format('%s%s%s, %s ago: %s', from(m), m.team and ' to team' or '', m.fyi and ' (fyi)' or '', ago(game.tick - m.tick), m.text)
      else
        local tag = m.how == '@' and ' @you' or m.how == '@everyone' and ' @everyone' or ''
        lines[#lines+1] = string.format('%s%s, %s ago: %s', from(m), tag, ago(game.tick - m.tick), m.text)
      end
    end
    delivered[p.index] = box.list
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
      -- fyi tells wait for the next reply and are no reason to wake anyone: counted apart.
      local direct, tells, fyi, first, last = 0, 0, 0, nil, nil
      for _, m in ipairs(list) do
        if m.fyi then fyi = fyi + 1
        else
          if m.how ~= 'name' then direct = direct + 1 end
          if m.tell then tells = tells + 1 end
          first, last = first or m, m
        end
      end
      local clock = s.clocks and s.clocks[a.index]
      out[#out+1] = {name=a.name, display_name=a.display_name, unread_mentions=#list - fyi + (box and box.dropped or 0), at_mentions=direct,
        tells=tells > 0 and tells or nil, fyi=fyi > 0 and fyi or nil, unread_board=M.unread_board(a),
        oldest_tick=first and first.tick or nil, latest=last and clip(last.from .. ': ' .. last.text, 160) or nil,
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
    if e.change == 'expired' then return nil end  -- told in the owner's batched claims line (claims_digest)
    if e.kind == 'plan' then
      -- Everyone hears of a plan edit once; a line written for me is mine.
      return string.format('team plan edited by %s: %s (board_plan shows it)', e.by, e.text or ''), e.owner ~= me
    end
    -- A project's change says what changed and its progress after it; a step change by
    -- someone else is news for its owner and requester: it wakes nobody.
    local change, step = e.change:gsub('_', ' '), STEP_CHANGES[e.change] or nil
    if e.progress and e.change ~= 'note' then tail = tail .. ' (' .. e.progress .. ')' end
    if e.overlaps and e.overlaps[me] then
      return string.format('#%d claim by %s overlaps your claim #%d: %s', e.id, e.by, e.overlaps[me], e.title)
    elseif (e.change == 'posted' or e.change == 'assigned') and e.owner == me and e.kind ~= 'claim' and e.kind ~= 'note' then
      return string.format('#%d %sassigned to you by %s: %s%s', e.id, e.kind == 'project' and 'project ' or '', e.by, e.title, tail)
    elseif e.requested_by == me and e.change ~= 'posted' then
      return e.change == 'note' and string.format('#%d (your %s) note by %s: %s', e.id, e.kind, e.by, e.text)
        or string.format('#%d (your %s) %s by %s: %s%s', e.id, e.kind, change, e.by, e.title, tail), step
    elseif e.owner == me and e.change ~= 'posted' then
      return e.change == 'note' and string.format('#%d (yours) note by %s: %s', e.id, e.by, e.text)
        or string.format('#%d (yours) %s by %s: %s%s', e.id, change, e.by, e.title, tail), step
    elseif e.prev_owner == me then
      return string.format('#%d (was yours) %s by %s%s: %s%s', e.id, change, e.by, e.owner and ' to ' .. e.owner or '', e.title, tail)
    elseif e.change == 'posted' and e.kind == 'project' then
      -- Everyone hears of a new project once; it wakes nobody.
      return string.format('#%d new project by %s: %s (%s; %s)%s', e.id, e.by, e.title, e.owner and 'owner ' .. e.owner or 'no owner',
        e.progress or 'no steps yet', e.text and ' - ' .. e.text or ''), true
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
    expire()
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
    local digest = claims_digest(me, h)
    if digest then lines[#lines+1] = digest end
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
    -- Eggs of ours on this agent's surface or built by it that hatch within 5 minutes (spoil.lua).
    if api.hatch_lines then
      local ok, list = pcall(api.hatch_lines, p, h)
      for _, line in ipairs(ok and list or {}) do lines[#lines+1] = line end
    end
    -- One line per incident (threat.attack_line). An incident this agent was
    -- told about comes again, as "continues" with its totals, only after
    -- REPEAT_ATTACK; h.attacks holds what each agent was shown (id -> tick).
    local areas, told, shown = {}, h.attacks or {}, {}
    for key, v in pairs(s.damage or {}) do
      if v.id then shown[v.id] = told[v.id] end
      local new
      if v.id and told[v.id] then new = v.last > told[v.id] and game.tick - told[v.id] >= REPEAT_ATTACK
      else new = fresh(v, v.last) end
      -- An area kept from before a hot deploy has no id or point until its next hit.
      if new and v.damage > 0 and v.id and v.at then areas[#areas+1] = {key=key, v=v} end
    end
    table.sort(areas, function(x, y) return x.v.last > y.v.last end)
    for n, area in ipairs(areas) do
      if n > 3 then lines[#lines+1] = string.format('+%d more attacked areas: status alerts', #areas - 3); break end
      lines[#lines+1] = api.attack_line(area.v, area.v.id and told[area.v.id] ~= nil, p.surface and p.surface.name)
      if area.v.id then shown[area.v.id] = game.tick end
    end
    -- Only incidents still kept are remembered.
    h.attacks = next(shown) and shown or nil
    if api.news_lines then
      for _, line in ipairs(api.news_lines(h.news_seq, game.tick - FIRST_ALERTS, p.surface and p.surface.name)) do lines[#lines+1] = line end
      h.news_seq = s.alert_seq or 0
    end
    local groups = 0
    for k = #(s.attack_groups or {}), 1, -1 do
      local g = s.attack_groups[k]
      if not fresh(g, g.tick) or groups >= 2 then break end
      groups = groups + 1
      local on = g.surface and p.surface and g.surface ~= p.surface.name and ' on ' .. g.surface or ''
      lines[#lines+1] = string.format('enemy group of %d gathered%s at (%d,%d)%s, %s ago', g.size, on, g.position.x, g.position.y,
        g.target and string.format(' heading for (%d,%d)', g.target.x, g.target.y) or '', ago(game.tick - g.tick))
    end
    for _, line in ipairs(losses or {}) do lines[#lines+1] = line end
    while #lines > MAX_ALERT_LINES do table.remove(lines) end
    -- A pole's death that cut power (powercut.lua): each cut once, at most 3 lines.
    if api.power_lines then
      local ok, list = pcall(api.power_lines, p, h)
      for _, line in ipairs(ok and list or {}) do lines[#lines+1] = line end
    end
    -- Our platforms (platalerts.lua), with their own cap of 6 lines.
    if api.platform_lines then
      local ok, list = pcall(api.platform_lines, p, h)
      for i, line in ipairs(ok and list or {}) do if i <= 6 then lines[#lines+1] = line end end
    end
    -- Drops this agent sent or was named in: still descending, or where they landed (drops.lua).
    if api.drop_lines then
      local ok, list = pcall(api.drop_lines, p, h)
      for i, line in ipairs(ok and list or {}) do if i <= 4 then lines[#lines+1] = line end end
    end
    -- The game's alerts and warnings for areas this agent claimed, built or is nearest (pushalerts.lua).
    if api.push_lines then
      local ok, list = pcall(api.push_lines, p, h)
      for _, line in ipairs(ok and list or {}) do lines[#lines+1] = line end
    end
    return #lines > 0 and lines or nil
  end
  -- Who hears what on the stream: once per agent (h.stream_note holds the
  -- version shown; a new version is shown once again).
  local STREAM_NOTE, STREAM_NOTE_VERSION = 'stream: viewers hear your say --aloud lines and confessions, spoken in your voice, '
    .. 'and like hearing from you every few minutes; other chat and tells show on the stream only as text, which viewers '
    .. 'read on screen, so write them as plain sentences with spaces between words', 2
  -- The operator channel (tells.lua `operator`): once per agent too.
  local OPERATOR_NOTE = 'operator: ./fh operator "text" files a request with the operator, the people running the harness '
    .. 'and the stream (harness bugs, tools you need, things viewers ask for that the team cannot do); answers come in the '
    .. 'game chat as server:'
  local function reminders(p, h)
    local out = {}
    if h.stream_note ~= STREAM_NOTE_VERSION then
      h.stream_note = STREAM_NOTE_VERSION
      out[#out+1] = STREAM_NOTE
    end
    if not h.operator_note then
      h.operator_note = 1
      out[#out+1] = OPERATOR_NOTE
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
    if api.watch then pcall(api.watch, p) end
    out.alerts = alert_lines(p, h, losses)
    -- Labs, the limiting pack and its first short step, power and boilers (scienceline.lua): at most every 5 min, when changed.
    if api.science_line then
      local ok, line = pcall(api.science_line, p, h)
      out.science = ok and line or nil
    end
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
