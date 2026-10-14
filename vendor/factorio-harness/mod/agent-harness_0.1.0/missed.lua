-- Wakes a loop of sleeps throws away (Opus, shift12 12:20-12:26: tools/idle.py
-- ran fh sleep 300 in a loop with every reply captured and dropped; the
-- operator's 12:20 tell woke a sleep, the reply that woke it showed the tell
-- once, and the next sleep began 0.27 s later). What the replies of a sleep
-- or an fh wait showed (tells, mentions, board lines, eggs) is kept as an
-- episode until its last reply; a sleep or wait the same agent starts within
-- WINDOW ticks of that reply (no time for a model to read it) moves the
-- episode to the agent's missed list. The next reply to a request that is no
-- sleep or wait, or to a sleep started WINDOW ticks or more after the agent's
-- previous request, shows the list once (missed_while_asleep). The new sleep
-- does not wake on those items: they are older than it. Off in turns mode,
-- where game time stands still while a model reads. Pure: state through
-- api.state.
return function(api)
  local M = {}
  M.WINDOW, M.FINAL, M.MAX_LINES, M.MAX_EPISODES = 300, 120, 12, 8
  local function store()
    local s = api.state()
    s.missed = s.missed or {shown={}, list={}, polled={}, last={}}
    return s.missed
  end
  local function off() return api.clock_mode and api.clock_mode() == 'turns' end
  -- What a request is to a sleep or a wait: 'sleep' (one starts), 'check' (the sleep's checks: peek polls and its last
  -- read), 'poll' (fh wait's status poll), 'final' (a read right after fh wait's last poll: the reply that ends it),
  -- or nil (anything else).
  function M.kind(index, action, args)
    args = type(args) == 'table' and args or {}
    if action == 'sleep' then return 'sleep' end
    if action == 'sleep_check' or (action == 'observe' and args.scope == 'sleep_check') then return 'check' end
    if action == 'status' and args.peek == true and args.brief == true then return 'poll' end
    local t = store().polled[index]
    if t and game.tick - t <= M.FINAL and args.peek ~= true and (action == 'status' or action == 'observe') then return 'final' end
    return nil
  end
  -- A sleep or an fh wait begins (its request, or the wait's poll): the episode before it moves to the missed list
  -- when its last reply came less than WINDOW ticks ago.
  function M.started(index, kind)
    local st = store()
    if kind == 'poll' then st.polled[index] = game.tick end
    local ep = st.shown[index]
    st.shown[index] = nil
    if off() or not (ep and #ep.items > 0) or game.tick - ep.tick >= M.WINDOW then return end
    local list = st.list[index] or {}
    list[#list+1] = {gap=game.tick - ep.tick, kind=ep.kind, next=kind == 'sleep' and 'sleep' or 'wait', items=ep.items}
    while #list > M.MAX_EPISODES do table.remove(list, 1) end
    st.list[index] = list
  end
  -- After a non-peek reply of a sleep or wait: what it showed joins the episode, which now ends at this reply.
  -- delivered: the mentions and tells the team block delivered (board.lua delivered), result: the reply.
  function M.record(index, kind, result, delivered, again)
    if off() then return end
    local st = store()
    local ep = st.shown[index]
    if kind == 'sleep' or not ep then ep = {kind=kind == 'final' and 'wait' or 'sleep', items={}} end
    ep.tick = game.tick
    -- (missed items this reply showed again: a loop can drop them twice)
    for _, it in ipairs(again or {}) do ep.items[#ep.items+1] = it end
    for _, m in ipairs(delivered or {}) do
      ep.items[#ep.items+1] = {tell=m.tell ~= nil, tick=m.tick, from=m.from, text=m.text, how=m.how, team=m.team, fyi=m.fyi}
    end
    local team = type(result) == 'table' and result.team
    for _, line in ipairs(team and team.board or {}) do ep.items[#ep.items+1] = {board=line} end
    if type(result) == 'table' and result.woke == 'eggs' and result.eggs then ep.items[#ep.items+1] = {eggs=tostring(result.eggs)} end
    st.shown[index] = ep
  end
  -- Another request: the agent moved on, so what the last replies showed reached it.
  function M.moved_on(index) store().shown[index] = nil end
  -- Before a request is answered: what it is, and whether the agent's previous request (peek or not) came WINDOW
  -- ticks or more before it; a sleep or wait beginning moves the episode before it (started).
  function M.begin(index, action, args)
    local st = store()
    local kind = M.kind(index, action, args)
    local late = not st.last[index] or game.tick - st.last[index] >= M.WINDOW
    st.last[index] = game.tick
    if kind == 'sleep' or kind == 'poll' then M.started(index, kind) end
    return kind, late
  end
  -- After a non-peek reply's team block: a sleep's or wait's reply joins its episode, any other request ends it; the
  -- missed list goes in the reply of a request that is no sleep or wait, or of a sleep begun WINDOW ticks or more after
  -- the previous request. Returns the lines to show, or nil.
  function M.after(index, kind, late, result, delivered)
    local lines, again
    if kind == nil or (kind == 'sleep' and late) then lines, again = M.lines(index) end
    if lines and type(result) == 'table' then result.team = result.team or {}; result.team.missed_while_asleep = lines end
    if kind == 'sleep' or kind == 'check' or kind == 'final' then M.record(index, kind, result, delivered, again)
    else M.moved_on(index) end
    return lines
  end
  local function ago(t)
    local s = math.floor(t / 60)
    if s < 60 then return s .. 's' end
    if s < 3600 then return math.floor(s / 60) .. 'm' end
    return string.format('%dh%02dm', math.floor(s / 3600), math.floor(s / 60) % 60)
  end
  local function plural(n, word) return n .. ' ' .. word .. (n == 1 and '' or 's') end
  -- The team block lines for the missed list (nil when empty), once, and its items.
  function M.lines(index)
    local st = store()
    local list = st.list[index]
    if not list or #list == 0 then return nil end
    st.list[index] = nil
    local out, shown, total, items = {}, 0, 0, {}
    for _, ep in ipairs(list) do
      local n = {tell=0, mention=0, board=0, eggs=0}
      for _, it in ipairs(ep.items) do
        local k = it.board and 'board' or it.eggs and 'eggs' or it.tell and 'tell' or 'mention'
        n[k] = n[k] + 1
        items[#items+1] = it
      end
      local parts = {}
      if n.tell > 0 then parts[#parts+1] = plural(n.tell, 'tell') end
      if n.mention > 0 then parts[#parts+1] = plural(n.mention, 'mention') end
      if n.board > 0 then parts[#parts+1] = plural(n.board, 'board line') end
      if n.eggs > 0 then parts[#parts+1] = 'an eggs warning' end
      out[#out+1] = string.format('%s shown in %s reply that the next %s followed %.1f s later:', table.concat(parts, ', '),
        ep.kind == 'wait' and 'an fh wait' or 'a sleep', ep.next, ep.gap / 60)
      for _, it in ipairs(ep.items) do
        total = total + 1
        if shown < M.MAX_LINES then
          shown = shown + 1
          if it.board then out[#out+1] = 'board: ' .. it.board
          elseif it.eggs then out[#out+1] = 'eggs: ' .. it.eggs
          else
            local tag = it.tell and ((it.team and ' to team' or '') .. (it.fyi and ' (fyi)' or ''))
              or (it.how == '@' and ' @you' or it.how == '@everyone' and ' @everyone' or '')
            out[#out+1] = string.format('%s %s%s, %s ago: %s', it.tell and 'tell from' or 'mention by', tostring(it.from), tag,
              ago(game.tick - (it.tick or game.tick)), tostring(it.text))
          end
        end
      end
    end
    if total > shown then out[#out+1] = string.format('+%d more', total - shown) end
    return out, items
  end
  return M
end
