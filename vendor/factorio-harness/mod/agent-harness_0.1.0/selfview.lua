-- An agent's own hour of play (operator, task-selfview: shift 4, 85% of game
-- actions were item moves and walking; "each hand transfer looks cheap in its
-- turn and nothing totals it"). What a player remembers of their own play:
-- requests and queue steps by kind, the share of the character's time by
-- kind, and the hand hauls repeated most. Once per game hour in the team
-- block (team.your_hour) and on request (my_hour).
-- Time, in game seconds while the character has a body: a running action or
-- queue step counts as its kind, a wait, wait step or fh sleep as waits; a
-- stretch with none of these counts toward the kind of the agent's next
-- request (the time it took to issue it), or as 'no request' when it lasted
-- GAP or longer. Hauls: items put into an entity, grouped by item, the spot
-- the agent last took that item from (none when it did not take it from an
-- entity this hour) and the spot it went to, each within NEAR tiles.
return function(api)
  local M = {}
  local MINUTE, MINUTES = 3600, 60
  local HOUR = MINUTE * MINUTES
  local GAP = 600            -- seconds without a request: 'no request'
  local NEAR, REPEATED, TOP, MAX_HAULS = 10, 5, 3, 64
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
  local function kind_of(action)
    if KIND[action] then return KIND[action] end
    if api.talk and api.talk(action) then return 'talk' end
    if api.is_read(action) or action:match('^queue_') or action == 'my_hour' then return 'reads' end
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
      b = {t={}, n={}, q=0}
      a.m[id] = b
      for k in pairs(a.m) do if k <= id - MINUTES then a.m[k] = nil end end
    end
    return b
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
  -- Once a second (runtime.lua idle_tick).
  function M.tick()
    local s = api.state()
    for index in pairs(s.clocks or {}) do
      if api.has_body(index) then
        local a = rec(index)
        local id = minute()
        local k = now(s, index)
        if k then
          local b = bucket(a, id)
          b.t[k] = (b.t[k] or 0) + 1
        else a.gap[id] = (a.gap[id] or 0) + 1 end
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
        if src and (game.tick - src.tick > HOUR or src.s ~= surface) then src = nil end
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
    table.sort(rows, function(x, y) return x.v > y.v or (x.v == y.v and (rank[x.k] or 99) < (rank[y.k] or 99)) end)
    return rows
  end
  local function where(pos) return string.format('(%d,%d)', pos.x, pos.y) end
  -- The last hour (or since the agent's first request, if later).
  function M.report(index, here)
    local a = rec(index)
    local id = minute()
    local counts, time, queued, total_n = {}, {}, 0, 0
    for k, b in pairs(a.m) do
      if k > id - MINUTES then
        for kind, n in pairs(b.n) do counts[kind] = (counts[kind] or 0) + n; total_n = total_n + n end
        for kind, sec in pairs(b.t) do time[kind] = (time[kind] or 0) + sec end
        queued = queued + b.q
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
    local text = string.format('%s: %d action%s%s%s; time: %s%s',
      minutes >= MINUTES and 'your hour' or string.format('your last %d min', minutes),
      total_n, total_n == 1 and '' or 's', queued > 0 and string.format(' (%d of them queue steps)', queued) or '',
      #parts > 0 and ': ' .. table.concat(parts, ', ') or '',
      #time_parts > 0 and table.concat(time_parts, ', ') or 'none counted',
      #haul_parts > 0 and '; repeated hauls: ' .. table.concat(haul_parts, ', ') or '')
    return {text=text, minutes=minutes, actions=total_n, queue_steps=queued, counts=counts, time_s=time, time_pct=pct,
      hauls=#haul_rows > 0 and haul_rows or nil}
  end
  -- The team block line: once per game hour per agent, the first an hour
  -- into the shift (or after its first request, if later).
  function M.hour_line(p)
    local a = rec(p.index)
    local s = api.state()
    local base = math.max(a.since, a.shown or 0, s.shift and s.shift.tick or 0)
    if game.tick - base < HOUR then return nil end
    a.shown = game.tick
    local ok, here = pcall(function() return p.surface.name end)
    return M.report(p.index, ok and here or nil).text
  end
  M.NOTE = 'time: game seconds of your character: a running action or queue step counts as its kind, a wait, wait step '
    .. 'or fh sleep as waits; a stretch with none of these counts toward the kind of your next request, or as no request '
    .. 'when it lasted 10 min or longer. hauls: items you put into an entity by hand, grouped by item, the spot you last '
    .. 'took that item from (none: not taken from an entity this hour) and the spot it went to, each within 10 tiles; '
    .. 'listed at 5 or more'
  function M.read(p)
    local ok, here = pcall(function() return p.surface.name end)
    local r = M.report(p.index, ok and here or nil)
    r.note = M.NOTE
    return r
  end
  M.schema = {
    my_hour = {returns='text (the your_hour line), minutes (the window: 60, or since your first request), actions, queue_steps, '
      .. 'counts {kind: requests and queue steps}, time_s and time_pct {kind: seconds, share}, hauls [{item, from, to, to_name, '
      .. 'surface, times}] (5 or more), note (how time and hauls are counted). Kinds: item moves, walking, building, mining, '
      .. 'crafting, research, waits, talk, reads, other. Read only'},
  }
  return M
end
