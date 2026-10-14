-- An agent's own play, reviewed (operator, task-selfview: shift 4, 85% of game
-- actions were item moves and walking; "each hand transfer looks cheap in its
-- turn and nothing totals it"; 22:13, Nick and a viewer: a periodic review and
-- a retro at shift start). What a player remembers of their own play:
-- - team.review every 2 game hours per agent (the first 2 hours into the
--   shift) and the review read: requests and queue steps by kind, the share
--   of the character's time by kind, the hand hauls repeated most, what
--   failed (by reason, top 3), alerts still open in its claims, and losses
--   near where its character was;
-- - team.shift.retro in the first reply of a shift: the previous shift for
--   the team (research done, losses, top failures, open board items).
-- Time, in game seconds while the character has a body: a running action or
-- queue step counts as its kind, a wait, wait step or fh sleep as waits; a
-- stretch with none of these counts toward the kind of the agent's next
-- request (the time it took to issue it), or as 'no request' when it lasted
-- GAP or longer. Hauls: items put into an entity, grouped by item, the spot
-- the agent last took that item from (none when it did not take it from an
-- entity in the window) and the spot it went to, each within NEAR tiles.
-- Failures: a request that failed, a queue step that failed, and a direct
-- timed action that ended other than done (no_path, timed_out, ...), keyed by
-- action and reason with the numbers taken out.
return function(api)
  local M = {}
  local MINUTE, MINUTES = 3600, 120
  local WINDOW = MINUTE * MINUTES   -- the review's window and its period: 2 game hours
  local GAP = 600                   -- seconds without a request: 'no request'
  local NEAR, REPEATED, TOP, MAX_HAULS = 10, 5, 3, 64
  local LOSS_NEAR = 64              -- tiles from where the character was
  local TEAM_BUCKET, TEAM_BUCKETS = 36000, 72   -- the team's failures: 10-minute buckets, 12 hours
  local KIND = {
    transfer='item moves', feed='item moves', refuel='item moves', rearm='item moves', collect='item moves', pickup='item moves',
    walk='walking', move_to='walking', kite='walking', drive='walking', vehicle='walking',
    build='building', build_path='building', construct='building', place_ghosts='building', belt_route='building',
    pole_route='building', pipe_route='building', wire='building', rotate='building', configure='building',
    revive_ghost='building', paste='building', blueprint_place='building', deconstruct='building',
    cancel_deconstruction='building', upgrade='building', restore='building', repair='building', circuit='building',
    mine='mining', craft='crafting', cancel_craft='crafting', research='research', research_next='research',
    wait_ticks='waits', wait_until='waits', sleep='waits'}
  -- A running action's kind (state().active), where it differs from KIND.
  local ACTIVE = {gather='item moves', shoot='other'}
  local CONTROL = {stop=true, attach=true, detach=true, sleep_check=true}
  -- How a direct timed action may end without having failed (runtime.lua finish).
  local DONE = {duration_elapsed=true, target_mined=true, repair_completed=true, arrived=true, arrived_near=true, path_built=true,
    constructed=true, nothing_to_do=true, clear=true, fed=true, collected=true, topped_up=true, completed=true, met=true, dropped=true,
    replaced=true, interrupted=true, told=true, mentioned=true, stopped=true, out_of_items=true, player_unavailable=true}
  local function kind_of(action)
    if KIND[action] then return KIND[action] end
    if api.talk and api.talk(action) then return 'talk' end
    if api.is_read(action) or action:match('^queue_') or action == 'review' then return 'reads' end
    return 'other'
  end
  M.kind_of = kind_of
  local function rec(index)
    local s = api.state()
    s.selfview = s.selfview or {}
    local a = s.selfview[index]
    if not a then
      a = {m={}, gap={}, hauls={}, takes={}, since=game.tick}
      s.selfview[index] = a
    end
    return a
  end
  local function minute() return math.floor(game.tick / MINUTE) end
  local function bucket(a, id)
    local b = a.m[id]
    if not b then
      b = {t={}, n={}, q=0, f={}}
      a.m[id] = b
      for k in pairs(a.m) do if k <= id - MINUTES then a.m[k] = nil end end
    end
    b.f = b.f or {}
    return b
  end
  local function ago(ticks)
    local sec = math.floor(ticks / 60)
    if sec >= 3600 then return string.format('%dh%02dm', math.floor(sec / 3600), math.floor(sec / 60) % 60) end
    if sec >= 60 then return string.format('%dm%02ds', math.floor(sec / 60), sec % 60) end
    return sec .. 's'
  end
  -- What the character does this second, or nil (nothing runs: the gap).
  local function now(s, index)
    local act = s.active and s.active[index]
    if act then
      if act.awaiting_craft then return act.handler == 'build' and 'building' or 'crafting' end
      if act.kind == 'feed' and act.handler == 'build' then return 'building' end
      return ACTIVE[act.kind] or KIND[act.kind] or 'other'
    end
    local q = s.queues and s.queues[index]
    if q and not q.paused then
      if q.current then return KIND[q.current.action] or 'other' end
      if q.loop and #q.pending == 0 then return 'waits' end  -- a repeating plan between cycles
    end
    if api.waiting and api.waiting(s, index) then return 'waits' end
  end
  -- Once a second (runtime.lua idle_tick); where the character is, once a minute.
  function M.tick()
    local s = api.state()
    for index in pairs(s.clocks or {}) do
      if api.has_body(index) then
        local a = rec(index)
        local id = minute()
        local k = now(s, index)
        local b = bucket(a, id)
        if k then b.t[k] = (b.t[k] or 0) + 1
        else a.gap[id] = (a.gap[id] or 0) + 1 end
        if not b.at and api.where then b.at = api.where(index) end
      end
    end
  end
  -- Every request the agent makes (runtime.lua dispatch, not peeks), and every
  -- queue step its queue starts (queued: no gap is credited, the agent made no request).
  function M.request(index, action, queued)
    if type(action) ~= 'string' or CONTROL[action] then return end
    local a = rec(index)
    local id = minute()
    local k = kind_of(action)
    if not queued then
      local total = 0
      for _, sec in pairs(a.gap) do total = total + sec end
      local to = total >= GAP and 'no request' or k
      for gid, sec in pairs(a.gap) do
        if gid > id - MINUTES then local b = bucket(a, gid); b.t[to] = (b.t[to] or 0) + sec end
      end
      a.gap = {}
    end
    local b = bucket(a, id)
    b.n[k] = (b.n[k] or 0) + 1
    if queued then b.q = b.q + 1 end
  end
  -- A failure, by action and reason with the numbers (positions, counts) taken out.
  local function reason_key(action, reason)
    local r = tostring(reason or 'failed')
    r = r:gsub('%s*%[ran as.*$', ''):gsub('%-?%d+%.?%d*', 'N'):gsub('%s+', ' ')
    r = r:match('^%s*(.-)%s*$')
    if #r > 80 then r = r:sub(1, 80) .. '...' end
    return tostring(action) .. ': ' .. r
  end
  M.reason_key = reason_key
  function M.failed(index, action, reason)
    if type(action) ~= 'string' or CONTROL[action] then return end
    local key = reason_key(action, reason)
    local b = bucket(rec(index), minute())
    b.f[key] = (b.f[key] or 0) + 1
    local s = api.state()
    s.selfview_team = s.selfview_team or {}
    local id = math.floor(game.tick / TEAM_BUCKET)
    local t = s.selfview_team[id]
    if not t then
      t = {}
      s.selfview_team[id] = t
      for k in pairs(s.selfview_team) do if k <= id - TEAM_BUCKETS then s.selfview_team[k] = nil end end
    end
    local row = t[key] or {n=0, by={}}
    t[key] = row
    row.n = row.n + 1
    local who = api.name and api.name(index) or tostring(index)
    row.by[who] = (row.by[who] or 0) + 1
  end
  -- A failed request (runtime.lua dispatch): not peeks, operators or directors.
  function M.dispatch_failed(request, err)
    if type(request) ~= 'table' or request.operator == true or type(request.player) ~= 'number' then return end
    if type(request.args) == 'table' and request.args.peek == true then return end
    if api.is_director and api.is_director(request.player) then return end
    M.failed(request.player, request.action, err)
  end
  -- A direct timed action's end (runtime.lua finish): what is not done counts.
  function M.ended(index, kind, outcome, err)
    if outcome == nil or DONE[outcome] then return end
    M.failed(index, kind, tostring(outcome) .. (type(err) == 'string' and ' (' .. err .. ')' or ''))
  end
  local function near(u, v) return u and v and (u.x - v.x) ^ 2 + (u.y - v.y) ^ 2 <= NEAR * NEAR end
  local function spot(pos) return {x=math.floor(pos.x + 0.5), y=math.floor(pos.y + 0.5)} end
  -- A hand transfer that moved items (runtime.lua transfer_one): takes are
  -- remembered per item, puts are hauls.
  function M.moved(p, direction, e, stacks)
    local a = rec(p.index)
    local surface = e.surface and e.surface.name
    local at = spot(e.position)
    local id = minute()
    for _, st in ipairs(stacks or {}) do
      if direction == 'to_player' then
        a.takes[st.name] = {x=at.x, y=at.y, s=surface, tick=game.tick}
      else
        local src = a.takes[st.name]
        if src and (game.tick - src.tick > WINDOW or src.s ~= surface) then src = nil end
        local from = src and {x=src.x, y=src.y} or nil
        local found
        for _, h in ipairs(a.hauls) do
          if h.item == st.name and h.s == surface and near(h.to, at) and ((h.from == nil and from == nil) or near(h.from, from)) then found = h; break end
        end
        if not found then
          found = {item=st.name, s=surface, from=from, to=at, name=e.name, m={}, last=game.tick}
          a.hauls[#a.hauls+1] = found
          if #a.hauls > MAX_HAULS then
            local old = 1
            for i, h in ipairs(a.hauls) do if h.last < a.hauls[old].last then old = i end end
            table.remove(a.hauls, old)
          end
        end
        found.m[id] = (found.m[id] or 0) + 1
        found.items = (found.items or 0) + st.count
        found.last = game.tick
        for k in pairs(found.m) do if k <= id - MINUTES then found.m[k] = nil end end
      end
    end
  end
  local ORDER = {'item moves', 'walking', 'building', 'mining', 'crafting', 'research', 'waits', 'talk', 'reads', 'other'}
  local function sorted(map)
    local rows = {}
    for k, v in pairs(map) do if v > 0 then rows[#rows+1] = {k=k, v=v} end end
    local rank = {}
    for i, k in ipairs(ORDER) do rank[k] = i end
    table.sort(rows, function(x, y) return x.v > y.v or (x.v == y.v and (rank[x.k] or 99) < (rank[y.k] or 99) or (x.v == y.v and rank[x.k] == rank[y.k] and x.k < y.k)) end)
    return rows
  end
  local function where(pos) return string.format('(%d,%d)', pos.x, pos.y) end
  local function top_failures(map, k, by)
    local list = {}
    local total = 0
    for key, v in pairs(map) do
      local n = type(v) == 'table' and v.n or v
      total = total + n
      list[#list+1] = {key=key, n=n, by=type(v) == 'table' and v.by or nil}
    end
    table.sort(list, function(x, y) return x.n > y.n or (x.n == y.n and x.key < y.key) end)
    local parts = {}
    for i = 1, math.min(k, #list) do
      local who = ''
      if by and list[i].by then
        local names = {}
        for name, n in pairs(list[i].by) do names[#names+1] = {name=name, n=n} end
        table.sort(names, function(x, y) return x.n > y.n or (x.n == y.n and x.name < y.name) end)
        local w = {}
        for j = 1, math.min(3, #names) do w[j] = names[j].name .. ' ' .. names[j].n end
        who = ' (' .. table.concat(w, ', ') .. ')'
      end
      parts[i] = list[i].key .. ' x' .. list[i].n .. who
    end
    return total, parts
  end
  -- The window (the last 2 hours, or since the agent's first request, if later).
  function M.report(index, here)
    local a = rec(index)
    local id = minute()
    local counts, time, fails, queued, total_n = {}, {}, {}, 0, 0
    local points = {}
    for k, b in pairs(a.m) do
      if k > id - MINUTES then
        for kind, n in pairs(b.n) do counts[kind] = (counts[kind] or 0) + n; total_n = total_n + n end
        for kind, sec in pairs(b.t) do time[kind] = (time[kind] or 0) + sec end
        for key, n in pairs(b.f or {}) do fails[key] = (fails[key] or 0) + n end
        queued = queued + b.q
        if b.at then points[#points+1] = b.at end
      end
    end
    local pending = 0
    for gid, sec in pairs(a.gap) do if gid > id - MINUTES then pending = pending + sec end end
    if pending > 0 then time[pending >= GAP and 'no request' or 'since your last request'] = pending end
    local total_s = 0
    for _, sec in pairs(time) do total_s = total_s + sec end
    local hauls = {}
    for _, h in ipairs(a.hauls) do
      local n = 0
      for k, c in pairs(h.m) do if k > id - MINUTES then n = n + c end end
      if n >= REPEATED then hauls[#hauls+1] = {h=h, n=n} end
    end
    table.sort(hauls, function(x, y) return x.n > y.n or (x.n == y.n and x.h.item < y.h.item) end)
    local minutes = math.min(MINUTES, math.max(1, math.ceil((game.tick - a.since) / MINUTE)))
    local parts, time_parts, haul_parts, haul_rows = {}, {}, {}, {}
    for _, r in ipairs(sorted(counts)) do parts[#parts+1] = r.k .. ' ' .. r.v end
    local pct = {}
    for _, r in ipairs(sorted(time)) do
      local share = total_s > 0 and math.floor(100 * r.v / total_s + 0.5) or 0
      pct[r.k] = share
      if share >= 1 then time_parts[#time_parts+1] = share .. '% ' .. r.k end
    end
    for i, x in ipairs(hauls) do
      local h = x.h
      local on = h.s and here and h.s ~= here and ' on ' .. h.s or ''
      local text = h.from and string.format('%s %s -> %s %s%s x%d', h.item, where(h.from), h.name, where(h.to), on, x.n)
        or string.format('%s -> %s %s%s x%d', h.item, h.name, where(h.to), on, x.n)
      if i <= TOP then haul_parts[#haul_parts+1] = text end
      haul_rows[#haul_rows+1] = {item=h.item, from=h.from, to=h.to, to_name=h.name, surface=h.s, times=x.n}
    end
    local failed_n, failed_parts = top_failures(fails, TOP)
    local head = minutes >= MINUTES and 'review (last 2h)' or string.format('review (last %d min)', minutes)
    local text = string.format('%s: %d action%s%s%s; time: %s', head,
      total_n, total_n == 1 and '' or 's', queued > 0 and string.format(' (%d of them queue steps)', queued) or '',
      #parts > 0 and ': ' .. table.concat(parts, ', ') or '',
      #time_parts > 0 and table.concat(time_parts, ', ') or 'none counted')
    return {text=text, minutes=minutes, actions=total_n, queue_steps=queued, counts=counts, time_s=time, time_pct=pct,
      hauls=#haul_rows > 0 and haul_rows or nil, hauls_text=#haul_parts > 0 and 'repeated hauls: ' .. table.concat(haul_parts, ', ') or nil,
      failed=failed_n, failed_text=failed_n > 0 and string.format('failed: %d (%s)', failed_n, table.concat(failed_parts, '; ')) or 'failed: none',
      points=points}
  end
  -- Losses since `since` near the points (within LOSS_NEAR tiles of an
  -- incident's box, same surface) or inside one of the areas.
  local function losses_near(since, points, areas)
    local out = {}
    for _, i in ipairs(api.losses and api.losses() or {}) do
      local last = i.last or i.first or 0
      local b = i.box
      if last > since and b then
        local hit = false
        for _, pt in ipairs(points) do
          if pt.s == i.surface then
            local dx = math.max(b[1] - pt.x, 0, pt.x - b[3])
            local dy = math.max(b[2] - pt.y, 0, pt.y - b[4])
            if dx * dx + dy * dy <= LOSS_NEAR * LOSS_NEAR then hit = true; break end
          end
        end
        for _, a in ipairs(areas) do
          if not hit and b[1] <= a.right_bottom.x and b[3] >= a.left_top.x and b[2] <= a.right_bottom.y and b[4] >= a.left_top.y then hit = true end
        end
        if hit then out[#out+1] = i end
      end
    end
    table.sort(out, function(x, y) return x.total > y.total or (x.total == y.total and (x.last or 0) > (y.last or 0)) end)
    return out
  end
  -- The review block: lines, the first headed 'review (last 2h):'.
  function M.review(p)
    local ok, here = pcall(function() return p.surface.name end)
    here = ok and here or nil
    local r = M.report(p.index, here)
    local lines = {r.text}
    if r.hauls_text then lines[#lines+1] = r.hauls_text end
    lines[#lines+1] = r.failed_text
    local me = api.name and api.name(p.index)
    local areas = me and api.claims and api.claims(me) or {}
    if #areas == 0 then lines[#lines+1] = 'open alerts in your claims: no claims'
    else
      local open = api.claim_alerts and api.claim_alerts(p) or {}
      lines[#lines+1] = #open == 0 and 'open alerts in your claims: none'
        or string.format('open alerts in your claims: %d: %s%s', #open, table.concat(open, '; ', 1, math.min(3, #open)), #open > 3 and '; ...' or '')
    end
    local lost = losses_near(game.tick - r.minutes * MINUTE, r.points, areas)
    if #lost == 0 then lines[#lines+1] = 'losses near your work: none'
    else
      local total, shown = 0, {}
      for _, i in ipairs(lost) do total = total + i.total end
      for k = 1, math.min(2, #lost) do shown[k] = api.loss_line and api.loss_line(lost[k], here) or ('#' .. tostring(lost[k].id)) end
      lines[#lines+1] = string.format('losses near your work: %d incident%s, %d destroyed: %s%s', #lost, #lost == 1 and '' or 's', total,
        table.concat(shown, '; '), #lost > 2 and '; ...' or '')
    end
    r.points = nil
    return lines, r
  end
  -- The team block's review: every 2 game hours per agent, the first 2 hours
  -- into the shift (or after its first request, if later).
  function M.review_due(p)
    local a = rec(p.index)
    local s = api.state()
    local base = math.max(a.since, a.shown or 0, s.shift and s.shift.tick or 0)
    if game.tick - base < WINDOW then return nil end
    a.shown = game.tick
    return (M.review(p))
  end
  function M.read(p)
    local lines, r = M.review(p)
    r.lines = lines
    r.note = M.NOTE
    return r
  end

  -- The previous shift for the team, in the first reply of a shift (kept per shift).
  local ACTIVE_ITEM = {open=true, claimed=true, doing=true, blocked=true}
  -- Open projects are long-lived by design: the shift block lists them apart (board.lua project_lines).
  local NOT_ITEMS = {plan=true, note=true, claim=true, project=true}
  function M.retro(p)
    local s = api.state()
    local shift = s.shift
    if not (shift and shift.prev_tick) then return nil end
    if s.retro and s.retro.seq == shift.seq and s.retro.force == p.force.name then return s.retro.lines end
    local from, to = shift.prev_tick, shift.tick
    local lines = {}
    local names = api.research_between and api.research_between(p.force, from, to) or {}
    local shown = {}
    for i = 1, math.min(10, #names) do shown[i] = names[i] end
    lines[1] = string.format('retro: previous shift (%s of game time): research done: %s%s', ago(to - from),
      #names > 0 and table.concat(shown, ', ') or 'none', #names > #shown and string.format(' (+%d more: research_done)', #names - #shown) or '')
    local lost, total, by_name = {}, 0, {}
    for _, i in ipairs(api.losses and api.losses() or {}) do
      if (i.last or i.first or 0) > from and (i.first or 0) <= to then
        lost[#lost+1] = i; total = total + i.total
        for name, n in pairs(i.names or {}) do by_name[name] = (by_name[name] or 0) + n end
      end
    end
    if #lost == 0 then lines[#lines+1] = 'losses: none'
    else
      table.sort(lost, function(x, y) return x.total > y.total end)
      local top = sorted(by_name)
      local parts = {}
      for k = 1, math.min(4, #top) do parts[k] = top[k].v .. ' ' .. top[k].k end
      lines[#lines+1] = string.format('losses: %d incident%s, %d destroyed (%s); largest: %s', #lost, #lost == 1 and '' or 's', total,
        table.concat(parts, ', '), api.loss_line and api.loss_line(lost[1]) or ('#' .. tostring(lost[1].id)))
    end
    local fails, cut = {}, false
    local first = math.floor(from / TEAM_BUCKET)
    for id, t in pairs(s.selfview_team or {}) do
      if id >= first and id * TEAM_BUCKET <= to then
        for key, row in pairs(t) do
          local f = fails[key] or {n=0, by={}}
          fails[key] = f
          f.n = f.n + row.n
          for who, n in pairs(row.by) do f.by[who] = (f.by[who] or 0) + n end
        end
      end
    end
    if to - from > TEAM_BUCKET * TEAM_BUCKETS then cut = true end
    local failed_n, failed_parts = top_failures(fails, TOP, true)
    lines[#lines+1] = failed_n > 0 and string.format('failed (team%s): %d (%s)', cut and ', the shift\'s last 12 h' or '', failed_n, table.concat(failed_parts, '; '))
      or 'failed (team): none'
    local items, kinds = {}, {}
    for _, i in pairs(api.board_items and api.board_items() or {}) do
      if type(i) == 'table' and ACTIVE_ITEM[i.status] and not NOT_ITEMS[i.kind] then
        items[#items+1] = i
        kinds[i.kind] = (kinds[i.kind] or 0) + 1
      end
    end
    if #items == 0 then lines[#lines+1] = 'open board items: none'
    else
      table.sort(items, function(x, y) return (x.created_tick or 0) < (y.created_tick or 0) or ((x.created_tick or 0) == (y.created_tick or 0) and (x.id or 0) < (y.id or 0)) end)
      local k, old = {}, {}
      for _, r in ipairs(sorted(kinds)) do k[#k+1] = r.v .. ' ' .. r.k end
      for n = 1, math.min(3, #items) do
        local i = items[n]
        local title = tostring(i.title or '')
        if #title > 50 then title = title:sub(1, 50) .. '...' end
        old[n] = string.format('#%s %s "%s" (%s, %s, %s old)', tostring(i.id), i.kind, title, i.owner or 'no owner', i.status, ago(game.tick - (i.created_tick or game.tick)))
      end
      lines[#lines+1] = string.format('open board items: %d (%s); oldest: %s', #items, table.concat(k, ', '), table.concat(old, '; '))
    end
    s.retro = {seq=shift.seq, force=p.force.name, lines=lines}
    return lines
  end
  M.NOTE = 'time: game seconds of your character: a running action or queue step counts as its kind, a wait, wait step '
    .. 'or fh sleep as waits; a stretch with none of these counts toward the kind of your next request, or as no request '
    .. 'when it lasted 10 min or longer. hauls: items you put into an entity by hand, grouped by item, the spot you last '
    .. 'took that item from (none: not taken from an entity in the window) and the spot it went to, each within 10 tiles; '
    .. 'listed at 5 or more. failed: requests that failed, queue steps that failed, direct timed actions that ended other '
    .. 'than done, by action and reason (numbers shown as N). losses near your work: incidents within 64 tiles of where '
    .. 'your character was (sampled once a minute) or in your claims'
  M.schema = {
    review = {returns='lines (the review block: review (last 2h): actions by kind and time by kind; repeated hauls; failed; '
      .. 'open alerts in your claims; losses near your work), minutes (the window: 120, or since your first request), actions, '
      .. 'queue_steps, counts {kind: requests and queue steps}, time_s and time_pct {kind: seconds, share}, hauls [{item, from, '
      .. 'to, to_name, surface, times}] (5 or more), failed, note (how each is counted). Kinds: item moves, walking, building, '
      .. 'mining, crafting, research, waits, talk, reads, other. Read only'},
  }
  return M
end
