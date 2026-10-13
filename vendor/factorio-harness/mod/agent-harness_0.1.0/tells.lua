-- Tells: a short line from one agent to named teammates (or the whole team)
-- outside the game chat. It is filed in each recipient's inbox (board.lua),
-- so it shows in their next reply's team block under `tells`, wakes them from
-- sleep (woke=told) and counts for supervisors like a mention; it is never in
-- the game chat, chat reads or unread counts. The operator reads every tell
-- (`tells`), which the stream shows on its logistics ticker.
return function(api)
  local M = {handlers={}, operator={}}
  local MAX_LOG, MAX_LEN, MAX_TO = 300, 500, 8
  local TEAM = {team=true, everyone=true, all=true}
  local function store()
    local s = api.state()
    s.tells = s.tells or {seq=0, log={}}
    return s.tells
  end
  local function one_line(text)
    assert(type(text) == 'string', 'text must be a string')
    text = text:gsub('[%c]+', ' '):gsub('^%s+', ''):gsub('%s+$', '')
    assert(#text > 0, 'text is required: fh tell NAME "text" (NAME,NAME or team for several)')
    -- Cut, and the reply says so (shift01: 324 characters cut to 300 unseen).
    local cut = #text > MAX_LEN and {length=#text, kept=MAX_LEN} or nil
    if cut then text = text:sub(1, MAX_LEN) end
    return text, cut
  end
  -- `to` as names (array, or one string split on commas and spaces), any
  -- with an @, or team/everyone/all. Returns recipient names and team flag.
  local function recipients(to, me)
    local list = {}
    if type(to) == 'string' then
      for word in to:gmatch('[^,%s]+') do list[#list+1] = word end
    elseif type(to) == 'table' then
      for _, word in ipairs(to) do assert(type(word) == 'string', 'to must be names'); list[#list+1] = word end
    end
    assert(#list > 0, 'to is required: a teammate name, several (luna,sol), or team')
    local names, seen, team = {}, {}, false
    for _, word in ipairs(list) do
      local w = word:gsub('^@', '')
      if TEAM[w:lower()] then
        team = true
      else
        local name = api.resolve(w)
        assert(name ~= 'operator', 'the operator reads harness requests (fh board request), not tells')
        if name ~= me and not seen[name] then seen[name] = true; names[#names+1] = name end
      end
    end
    if team then
      names = {}
      for _, a in ipairs(api.agents()) do if a.name ~= me then names[#names+1] = a.name end end
    end
    assert(#names > 0, 'no one to tell: name a teammate other than yourself')
    assert(team or #names <= MAX_TO, 'at most ' .. MAX_TO .. ' names; use team for everyone')
    table.sort(names)
    return names, team
  end
  M.schema = {
    tell = {to='a teammate name or display name, several (array or "luna,sol"), or "team" for everyone',
      text='1..500 characters, one line (longer is cut to 500; the reply says so)',
      returns='seq and to (cut {length, kept} when the text was cut; away "sol is on Vulcanus" for recipients on another planet, platform or in a cargo pod): the line goes to each recipient\'s next reply (team: tells), wakes them if asleep (woke=told), and stays out of the game chat; viewers see it as text on the stream\'s logistics ticker, never spoken'},
    tells = {since='optional sequence number', limit='1..100, newest kept (default 30)',
      returns='tells you sent or received {seq,tick,from,away?,to,team?,text} oldest first (away: "on Vulcanus" when the sender is somewhere other than you now), and cursor'},
  }
  function M.handlers.tell(p, a)
    local me = api.who(p)
    local text, cut = one_line(a.text)
    local names, team = recipients(a.to, me)
    local s = store()
    s.seq = s.seq + 1
    local t = {seq=s.seq, tick=game.tick, player=p.index, from=me, to=names, team=team or nil, text=text}
    s.log[#s.log+1] = t
    while #s.log > MAX_LOG do table.remove(s.log, 1) end
    local index = {}
    for _, a2 in ipairs(api.agents()) do index[a2.name] = a2.index end
    for _, name in ipairs(names) do
      if index[name] then api.deliver(index[name], t) end
    end
    -- Recipients on another planet (where.lua).
    local away, where = {}, api.where_from and api.where_from(me)
    for _, name in ipairs(where and names or {}) do
      local w = where(name)
      if w then away[#away+1] = name .. ' is ' .. w end
    end
    return {seq=t.seq, to=team and 'team' or names, cut=cut, away=#away > 0 and table.concat(away, '; ') or nil,
      note='in their next reply (team: tells), waking them if asleep; not in chat'}
  end
  local function read(a, me)
    assert(a.since == nil or type(a.since) == 'number', 'since must be a number')
    local limit = a.limit or 30
    assert(type(limit) == 'number' and limit >= 1 and limit <= 100, 'limit must be 1..100')
    local s = store()
    local picked = {}
    for _, t in ipairs(s.log) do
      local mine = me == nil or t.from == me
      if not mine then for _, n in ipairs(t.to) do if n == me then mine = true; break end end end
      if mine and t.seq > (a.since or 0) then picked[#picked+1] = t end
    end
    local out = {}
    local where = me and api.where_from and api.where_from(me)
    for i = math.max(1, #picked - limit + 1), #picked do
      local t = picked[i]
      out[#out+1] = {seq=t.seq, tick=t.tick, from=t.from, away=where and where(t.from) or nil, to=t.team and 'team' or t.to, team=t.team, text=t.text}
    end
    return {tells=out, cursor=s.seq, tick=game.tick}
  end
  function M.handlers.tells(p, a) return read(a, api.who(p)) end
  -- Operator (RCON, `operator: true` dispatch): every tell, for the stream.
  function M.operator.tells(a) return read(a, nil) end

  -- Requests to the operator (the people running the harness and stream):
  -- filed here, read by the stream service (operator_requests), which keeps
  -- the inbox file and shows them on the ticker. The operator answers in the
  -- game chat as server:, where an @name reaches that agent as a mention.
  -- Rate limits count game ticks.
  local OP_GAP, OP_WINDOW, OP_MAX, OP_LOG = 60 * 60, 3600 * 60, 10, 200
  local function requests()
    local s = api.state()
    s.operator_requests = s.operator_requests or {seq=0, log={}, sent={}}
    return s.operator_requests
  end
  M.schema.operator = {text='1..500 characters, one line (longer is cut to 500; the reply says so): a request to the operator, the people running the harness and the stream: a harness bug, a tool you need, something viewers asked for that the team cannot do. The operator may answer in the game chat as server: (an @name there reaches you like a mention). Not for help with the game',
    returns='seq (cut {length, kept} when the text was cut); at most one a minute and 10 an hour'}
  function M.handlers.operator(p, a)
    local me = api.who(p)
    local text, cut = one_line(a.text)
    local r = requests()
    local mine = r.sent[me] or {}
    local keep = {}
    for _, t in ipairs(mine) do if game.tick - t < OP_WINDOW then keep[#keep+1] = t end end
    local last = keep[#keep]
    if last and game.tick - last < OP_GAP then
      error(string.format('one operator request a minute; next in %d s', math.ceil((OP_GAP - (game.tick - last)) / 60)), 0)
    end
    if #keep >= OP_MAX then
      error(string.format('%d operator requests an hour; next in %d min', OP_MAX, math.ceil((OP_WINDOW - (game.tick - keep[1])) / 3600)), 0)
    end
    keep[#keep+1] = game.tick
    r.sent[me] = keep
    r.seq = r.seq + 1
    r.log[#r.log+1] = {seq=r.seq, tick=game.tick, from=me, text=text}
    while #r.log > OP_LOG do table.remove(r.log, 1) end
    return {seq=r.seq, cut=cut, note='filed for the operator; an answer comes in the game chat as server:'}
  end
  -- Operator read: {seq, tick, from, text} after `since`, oldest first, and cursor.
  function M.operator.operator_requests(a)
    assert(a.since == nil or type(a.since) == 'number', 'since must be a number')
    local limit = a.limit or 30
    assert(type(limit) == 'number' and limit >= 1 and limit <= 100, 'limit must be 1..100')
    local r = requests()
    local picked = {}
    for _, t in ipairs(r.log) do if t.seq > (a.since or 0) then picked[#picked+1] = t end end
    local out = {}
    for i = math.max(1, #picked - limit + 1), #picked do
      local t = picked[i]
      out[#out+1] = {seq=t.seq, tick=t.tick, from=t.from, text=t.text}
    end
    return {requests=out, cursor=r.seq, tick=game.tick}
  end
  return M
end
