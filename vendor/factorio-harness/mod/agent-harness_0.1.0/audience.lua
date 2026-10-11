-- Lines between the team and the stream audience, both outside the team's
-- chat and hints:
--   confess      an agent's confessional, for viewers only: the overlay,
--                voices and casters read it (operator `confessions`); no
--                teammate sees it in chat, team hints or any agent read but
--                the author's own.
--   viewer_say   (operator only) a stream viewer's chat line posted into the
--                game chat as "viewer NAME: text" (chat.lua), rate-limited;
--                refused for a muted viewer.
--   vote         an agent's vote to mute or unmute a viewer: a majority of
--                the agents active in the last 10 minutes decides, for the
--                rest of the run. Each vote and result is a chat notice
--                ("vote: ..."), which the stream shows on its ticker.
-- Rate limits count game ticks: while the game is paused they do not refill.
return function(api)
  local M = {handlers={}, operator={}}
  local MAX_LOG, MAX_LEN = 200, 300
  local CONFESS_GAP = 15 * 60
  local VIEWER_LEN, VIEWER_NAME = 200, 24
  local VIEWER_GAP, VIEWER_WINDOW, VIEWER_MAX = 20 * 60, 60 * 60, 6
  local function store()
    local s = api.state()
    s.audience = s.audience or {seq=0, confessions={}, last={}, viewers={recent={}, by_name={}}}
    s.audience.muted = s.audience.muted or {}
    s.audience.votes = s.audience.votes or {}
    return s.audience
  end
  local function one_line(text, name, max)
    assert(type(text) == 'string', name .. ' must be a string')
    text = text:gsub('[%c]+', ' '):gsub('^%s+', ''):gsub('%s+$', '')
    assert(#text > 0, name .. ' is required')
    if #text > max then text = text:sub(1, max) end
    return text
  end
  local function seconds(ticks) return math.ceil(ticks / 60) end
  M.schema = {
    confess = {text='1..300 characters: a confessional line for the stream audience only (overlay, stream voice, casters). Teammates never see it: not in chat, team hints or their reads',
      returns='seq; at most one every 15 s'},
    confessions = {since='optional sequence number', limit='1..100, newest kept (default 30)',
      returns='your own confessions {seq,tick,text} oldest first and cursor (the operator reads everyone\'s)'},
    vote = {kind='mute|unmute', viewer='the viewer\'s name as in "viewer NAME: ..." (with or without "viewer ")', reason='1..120 characters',
      returns='viewer, kind, votes (agents active in the last 10 minutes who voted so), needed (a majority of them), active, result (muted|unmuted once decided). A muted viewer\'s lines no longer reach the game for the rest of the run. Every vote and result is a "vote: ..." notice in chat and on the stream\'s ticker'},
    votes = {returns='muted viewers {viewer, tick, reason, by} and open votes {viewer, kind, voters}'},
  }
  function M.handlers.confess(p, a)
    local text = one_line(a.text, 'text', MAX_LEN)
    local s = store()
    local last = s.last[p.index]
    if last and game.tick - last < CONFESS_GAP then
      error('one confession every ' .. seconds(CONFESS_GAP) .. ' s; next in ' .. seconds(CONFESS_GAP - (game.tick - last)) .. ' s', 0)
    end
    s.last[p.index] = game.tick
    s.seq = s.seq + 1
    local log = s.confessions
    log[#log+1] = {seq=s.seq, tick=game.tick, player=p.index, from=p.name, text=text}
    while #log > MAX_LOG do table.remove(log, 1) end
    return {seq=s.seq, note='viewers hear this; teammates do not'}
  end
  local function read(a, index)
    assert(a.since == nil or type(a.since) == 'number', 'since must be a number')
    local limit = a.limit or 30
    assert(type(limit) == 'number' and limit >= 1 and limit <= 100, 'limit must be 1..100')
    local s = store()
    local picked = {}
    for _, c in ipairs(s.confessions) do
      if c.seq > (a.since or 0) and (index == nil or c.player == index) then picked[#picked+1] = c end
    end
    local out = {}
    for i = math.max(1, #picked - limit + 1), #picked do
      local c = picked[i]
      out[#out+1] = {seq=c.seq, tick=c.tick, from=index == nil and c.from or nil, text=c.text}
    end
    -- An agent's cursor is its own latest seq: the log's would count others' confessions.
    local cursor = s.seq
    if index ~= nil then
      cursor = 0
      for _, c in ipairs(s.confessions) do if c.player == index then cursor = c.seq end end
    end
    return {confessions=out, cursor=cursor, tick=game.tick}
  end
  function M.handlers.confessions(p, a) return read(a, p.index) end
  -- Operator (RCON, `operator: true` dispatch): every agent's confessions.
  function M.operator.confessions(a) return read(a, nil) end
  -- Viewer names as viewer_say stores them; votes match them case-blind.
  local function viewer_name(raw)
    assert(type(raw) == 'string', 'viewer must be a name')
    local name = raw:gsub('%b[]', ''):gsub('[%c%[%]]+', ''):gsub('%s+', ' '):gsub('^%s+', ''):gsub('%s+$', '')
    name = name:gsub('^[Vv]iewer ', '')
    assert(#name > 0, 'viewer is required: the name after "viewer " in chat')
    if #name > VIEWER_NAME then name = name:sub(1, VIEWER_NAME) end
    return name, name:lower()
  end
  -- Agents who made a request (or a waiting poll) in the last 10 minutes.
  local ACTIVE_TICKS, REASON_LEN = 36000, 120
  local function active(me)
    local clocks, out, seen = api.state().clocks or {}, {}, {}
    for _, a in ipairs(api.agents()) do
      local c = clocks[a.index]
      local last = c and math.max(c.call_tick or 0, c.seen_tick or 0)
      if a.name == me or (last and game.tick - last <= ACTIVE_TICKS) then out[#out+1] = a.name; seen[a.name] = true end
    end
    table.sort(out)
    return out, seen
  end
  local function notice(text) if api.notice then api.notice('vote', text) end end
  function M.handlers.vote(p, a)
    assert(a.kind == 'mute' or a.kind == 'unmute', 'kind must be mute or unmute')
    assert(not (api.director and api.director(p.index)), 'directors do not vote')
    local name, key = viewer_name(a.viewer)
    local reason = one_line(a.reason, 'reason', REASON_LEN)
    local me = p.name ~= '' and p.name or ('player' .. p.index)
    local s = store()
    if a.kind == 'mute' then assert(not s.muted[key], 'viewer ' .. name .. ' is already muted')
    else assert(s.muted[key], 'viewer ' .. name .. ' is not muted') end
    local id = a.kind .. ':' .. key
    local motion = s.votes[id] or {viewer=name, kind=a.kind, voters={}}
    s.votes[id] = motion
    motion.voters[me] = {tick=game.tick, reason=reason}
    -- The name as the first vote spelt it (or as it was muted).
    name = a.kind == 'unmute' and s.muted[key].viewer or motion.viewer
    local list, seen = active(me)
    local yes, by = 0, {}
    for voter in pairs(motion.voters) do if seen[voter] then yes = yes + 1; by[#by+1] = voter end end
    table.sort(by)
    local needed = math.floor(#list / 2) + 1
    local out = {viewer=name, kind=a.kind, votes=yes, needed=needed, active=#list}
    if yes >= needed then
      s.votes[id] = nil
      if a.kind == 'mute' then
        s.muted[key] = {viewer=name, tick=game.tick, reason=reason, by=by}
        out.result = 'muted'
        notice(string.format('viewer %s is muted for the rest of the run (%d of %d active agents: %s)', name, yes, #list, table.concat(by, ', ')))
      else
        s.muted[key] = nil
        out.result = 'unmuted'
        notice(string.format('viewer %s is unmuted (%d of %d active agents: %s)', name, yes, #list, table.concat(by, ', ')))
      end
    else
      notice(string.format('%s votes to %s viewer %s (%d of %d needed): %s', me, a.kind, name, yes, needed, reason))
    end
    return out
  end
  local function votes()
    local s, muted, open = store(), {}, {}
    for _, m in pairs(s.muted) do muted[#muted+1] = {viewer=m.viewer, tick=m.tick, reason=m.reason, by=m.by} end
    for _, v in pairs(s.votes) do
      local voters = {}
      for voter in pairs(v.voters) do voters[#voters+1] = voter end
      table.sort(voters)
      open[#open+1] = {viewer=v.viewer, kind=v.kind, voters=voters}
    end
    table.sort(muted, function(x, y) return x.tick < y.tick end)
    table.sort(open, function(x, y) return x.viewer < y.viewer end)
    return {muted=muted, open=open}
  end
  function M.handlers.votes() return votes() end
  function M.operator.votes() return votes() end
  -- Operator: relay a viewer's chat line. Over the limit it is dropped (not an
  -- error): posted=false, dropped, retry_after_s.
  function M.operator.viewer_say(a)
    assert(type(a.name) == 'string', 'name must be a string')
    -- Names and text cannot carry rich text tags into the game console.
    local name = a.name:gsub('%b[]', ''):gsub('[%c%[%]]+', ''):gsub('%s+', ' '):gsub('^%s+', ''):gsub('%s+$', '')
    assert(#name > 0, 'name is required')
    if #name > VIEWER_NAME then name = name:sub(1, VIEWER_NAME) end
    local text = one_line(a.text, 'text', VIEWER_LEN):gsub('%[', '('):gsub('%]', ')')
    local v = store().viewers
    local now = game.tick
    local recent = {}
    for _, t in ipairs(v.recent) do if now - t < VIEWER_WINDOW then recent[#recent+1] = t end end
    v.recent = recent
    for n, t in pairs(v.by_name) do if now - t >= VIEWER_GAP then v.by_name[n] = nil end end
    local key = name:lower()
    local muted = store().muted[key]
    if muted then return {posted=false, dropped='muted', reason=muted.reason, limit='muted by the agents\' vote for the rest of the run'} end
    if v.by_name[key] then
      return {posted=false, dropped='viewer_rate', retry_after_s=seconds(VIEWER_GAP - (now - v.by_name[key])),
        limit='one line per viewer every ' .. seconds(VIEWER_GAP) .. ' s'}
    end
    if #recent >= VIEWER_MAX then
      return {posted=false, dropped='global_rate', retry_after_s=seconds(VIEWER_WINDOW - (now - recent[1])),
        limit=VIEWER_MAX .. ' viewer lines per ' .. seconds(VIEWER_WINDOW) .. ' s'}
    end
    recent[#recent+1] = now
    v.by_name[key] = now
    local seq = api.post_viewer(name, text)
    return {posted=true, seq=seq, from='viewer ' .. name, text=text}
  end
  return M
end
