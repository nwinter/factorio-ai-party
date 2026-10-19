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
  local OPERATOR_KEEP = 3
  -- wake: true ends a recipient's wait that ignores messages (wake_on_messages: false, or wake_from without the sender)
  -- each time (Astra, d15 14:48: Sonnet sat in back-to-back 15-minute waits that no tell reached for about an hour; the
  -- once per WAKE_EVERY limit went in batch8 A4); WAKE_EVERY is the window the reply counts wakes over.
  M.WAKE_EVERY = 10 * 3600
  local function store()
    local s = api.state()
    s.tells = s.tells or {seq=0, log={}}
    return s.tells
  end
  local function one_line(text, limit)
    assert(type(text) == 'string', 'text must be a string')
    text = text:gsub('[%c]+', ' '):gsub('^%s+', ''):gsub('%s+$', '')
    assert(#text > 0, 'text is required: fh tell NAME "text" (NAME,NAME or team for several)')
    -- Cut, and the reply says so (shift01: 324 characters cut to 300 unseen).
    limit = limit or MAX_LEN
    local cut = #text > limit and {length=#text, kept=limit} or nil
    if cut then text = text:sub(1, limit) end
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
      text='1..500 bytes, one line (fh tell sends a longer one as numbered parts cut at sentence ends, all delivered together; in a queue step or plan a longer one is cut to 500 and the reply says so)',
      reply_to='optional seq (or array): the chat line or tell this answers; it closes as unanswered (a tell to the asker does too)',
      fyi='true: for their information; it waits for their next reply (marked fyi) and wakes nobody: routine updates, no answer needed',
      wake='true (fh tell --wake): also ends a recipient\'s wait that this tell would not end: a direct wait_ticks, wait_until or sleep that ignores messages (wake_on_messages: false, fh --wait-through-tells) or takes them only from others (wake_from), and an fh --wait that goes on through tells; every time (woken counts your wake tells to each in the last 10 minutes)',
      returns='seq and to (cut {length, kept} when the text was cut; away "sol is on Vulcanus" for recipients on another planet, platform or in a cargo pod; ignoring "sonnet is in a wait_until that ignores messages until tick T (about N min)" for a recipient no tell wakes now; woken and not_woken with wake): the line goes to each recipient\'s next reply (team: tells), wakes them if asleep (woke=told), and stays out of the game chat; viewers see it as text on the stream\'s logistics ticker, never spoken'},
    tells = {since='optional sequence number: the tells you sent or received after it (since=0: all of them); without it, the tells you received', limit='1..100, newest kept (default 30)',
      returns='tells {seq,tick,ago_s,from,away?,to?,team?,fyi?,text} oldest first (those listed leave the team block\'s unread tells): without since the last 30 you received, whether or not a team block showed them; with since those you sent or received (to on each). away: "on Vulcanus" when the sender is somewhere other than you now. cursor: the newest seq'},
  }
  function M.handlers.tell(p, a)
    local me = api.who(p)
    assert(a.fyi == nil or type(a.fyi) == 'boolean', 'fyi must be true or false')
    assert(a.wake == nil or type(a.wake) == 'boolean', 'wake must be true or false')
    assert(not (a.wake and a.fyi), 'wake or fyi, not both: fyi wakes nobody')
    local text, cut = one_line(a.text)
    local names, team = recipients(a.to, me)
    local s = store()
    s.seq = s.seq + 1
    local t = {seq=s.seq, tick=game.tick, player=p.index, from=me, to=names, team=team or nil, text=text, fyi=a.fyi or nil, wake=a.wake or nil}
    -- (d17 batch14 B1) reply_to: the chat line or tell this answers (owed.lua)
    if a.reply_to ~= nil and api.on_reply then pcall(api.on_reply, p.index, a.reply_to) end
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
    -- Recipients in a wait this tell does not end (it ignores messages, or takes them only from named senders): said,
    -- and with wake ended, every time (batch8 A4, Haiku 16:50: a plain tell left a teammate asleep; the replies said
    -- "ignoring", and a tell --wake woke him). How many times you woke each in the last 10 minutes is said.
    local ignoring, woken = {}, {}
    s.wakes = s.wakes or {}
    for _, name in ipairs(api.deaf and names or {}) do
      local d = index[name] and api.deaf(index[name], me)
      if d then
        local key = me .. '>' .. name
        if a.wake then
          if api.wake(index[name], me) then
            local w = s.wakes[key]
            if type(w) ~= 'table' then w = {} end
            local kept = {}
            for _, tick in ipairs(w) do if game.tick - tick < M.WAKE_EVERY then kept[#kept+1] = tick end end
            kept[#kept+1] = game.tick
            s.wakes[key] = kept
            woken[#woken+1] = #kept > 1 and string.format('%s (your %d wake tells to them in the last 10 min)', name, #kept) or name
          end
        else
          ignoring[#ignoring+1] = string.format('%s is in a %s that %s until tick %d (about %d min); tell --wake ends it', name, d.kind,
            d.why or 'ignores messages', d.until_tick, math.ceil(math.max(0, d.until_tick - game.tick) / 3600))
        end
      end
    end
    for k, w in pairs(s.wakes) do
      if type(w) ~= 'table' or #w == 0 or game.tick - w[#w] > M.WAKE_EVERY then s.wakes[k] = nil end
    end
    local not_woken = {}
    return {seq=t.seq, to=team and 'team' or names, cut=cut, away=#away > 0 and table.concat(away, '; ') or nil,
      ignoring=#ignoring > 0 and table.concat(ignoring, '; ') or nil, woken=#woken > 0 and woken or nil, not_woken=#not_woken > 0 and not_woken or nil,
      note=t.fyi and 'fyi: in their next reply (team: tells), not waking them; not in chat' or 'in their next reply (team: tells), waking them if asleep; not in chat'}
  end
  local function read(a, me)
    assert(a.since == nil or type(a.since) == 'number', 'since must be a number')
    local s = store()
    -- An agent's read without since: the last 30 tells it received, whether
    -- or not a team block showed them (Muse, shift10: two tells shown once and
    -- missed were lost, the read listing only those since the last read).
    local received = me ~= nil and a.since == nil
    local limit = a.limit or 30
    assert(type(limit) == 'number' and limit >= 1 and limit <= 100, 'limit must be 1..100')
    local picked = {}
    for _, t in ipairs(s.log) do
      local to_me = false
      for _, n in ipairs(me and t.to or {}) do if n == me then to_me = true; break end end
      local mine = me == nil or to_me or (not received and t.from == me)
      if mine and t.seq > (a.since or 0) then picked[#picked+1] = t end
    end
    local out = {}
    local where = me and api.where_from and api.where_from(me)
    for i = math.max(1, #picked - limit + 1), #picked do
      local t = picked[i]
      out[#out+1] = {seq=t.seq, tick=t.tick, ago_s=math.floor((game.tick - t.tick) / 60), from=t.from, away=where and where(t.from) or nil,
        to=not received and (t.team and 'team' or t.to) or nil, team=t.team, fyi=t.fyi, text=t.text}
    end
    return {tells=out, cursor=s.seq, tick=game.tick}
  end
  -- The tells a read lists are read: they leave the team block's unread list (board.lua; d17 batch29 C2).
  function M.handlers.tells(p, a)
    local r = read(a, api.who(p))
    if api.read_tells and #r.tells > 0 then
      local seqs = {}
      for _, t in ipairs(r.tells) do seqs[#seqs+1] = t.seq end
      api.read_tells(p.index, seqs)
    end
    return r
  end
  -- Operator (RCON, `operator: true` dispatch): every tell, for the stream.
  function M.operator.tells(a) return read(a, nil) end
  -- Operator: a tell from `operator` (tools/idle_nudge.py: facts for an agent
  -- whose character stands idle). Like a teammate's: the next reply's team
  -- tells, a wake from sleep (woke=told), never the game chat.
  function M.operator.tell(a)
    local text, cut = one_line(a.text)
    local names, team = recipients(a.to, nil)
    local s = store()
    s.seq = s.seq + 1
    local t = {seq=s.seq, tick=game.tick, from='operator', to=names, team=team or nil, text=text}
    s.log[#s.log+1] = t
    while #s.log > MAX_LOG do table.remove(s.log, 1) end
    local index = {}
    for _, a2 in ipairs(api.agents()) do index[a2.name] = a2.index end
    s.unseen = s.unseen or {}
    for _, name in ipairs(names) do
      if index[name] then
        api.deliver(index[name], t)
        local list = s.unseen[index[name]] or {}
        list[#list+1] = {seq=t.seq, tick=t.tick, text=text}
        while #list > OPERATOR_KEEP do table.remove(list, 1) end
        s.unseen[index[name]] = list
      end
    end
    return {seq=t.seq, to=team and 'team' or names, cut=cut}
  end
  -- An operator tell rides on every reply to its agent (result.operator; fh
  -- prints it as an OPERATOR: line on stderr and first on stdout) until the
  -- agent's next game action or message (agent-minds study, fix 1: of 15
  -- shift07 nudges 5 never reached the model, its replies sent to a file,
  -- /dev/null, `tail -c` or a wrapper keeping three keywords). Waits, sleeps
  -- and reads show it again; `consume` ends it after this reply.
  function M.operator_lines(index, consume)
    local s = store()
    local list = s.unseen and s.unseen[index]
    if not list or #list == 0 then return nil end
    local out = {}
    for _, u in ipairs(list) do
      out[#out+1] = {seq=u.seq, ago_s=math.floor((game.tick - u.tick) / 60), text=u.text}
    end
    if consume then s.unseen[index] = nil end
    return out
  end

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
  M.schema.operator = {text='1..2000 bytes, one line; longer is refused without filing or using a rate-limit slot: a request to the operator, the people running the harness and the stream: a harness bug, a tool you need, something viewers asked for that the team cannot do. The operator may answer in the game chat as server: (an @name there reaches you like a mention). Not for help with the game',
    returns='seq; the full normalized line is filed; at most one a minute and 10 an hour'}
  function M.handlers.operator(p, a)
    local me = api.who(p)
    local text, cut = one_line(a.text, 2000)
    assert(not cut, 'operator text exceeds 2000 bytes; no request filed and no rate-limit slot used')
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
    return {seq=r.seq, note='filed for the operator; an answer comes in the game chat as server:'}
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
