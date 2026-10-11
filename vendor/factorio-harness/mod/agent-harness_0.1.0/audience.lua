-- Lines between the team and the stream audience, both outside the team's
-- chat and hints:
--   confess      an agent's confessional, for viewers only: the overlay,
--                voices and casters read it (operator `confessions`); no
--                teammate sees it in chat, team hints or any agent read but
--                the author's own.
--   viewer_say   (operator only) a stream viewer's chat line posted into the
--                game chat as "viewer NAME: text" (chat.lua), rate-limited.
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
    return {confessions=out, cursor=s.seq, tick=game.tick}
  end
  function M.handlers.confessions(p, a) return read(a, p.index) end
  -- Operator (RCON, `operator: true` dispatch): every agent's confessions.
  function M.operator.confessions(a) return read(a, nil) end
  -- Operator: relay a viewer's chat line. Over the limit it is dropped (not an
  -- error): posted=false, dropped, retry_after_s.
  function M.operator.viewer_say(a)
    assert(type(a.name) == 'string', 'name must be a string')
    -- Names and text cannot carry rich text tags into the game console.
    local name = a.name:gsub('[%c%[%]]+', ''):gsub('%s+', ' '):gsub('^%s+', ''):gsub('%s+$', '')
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
