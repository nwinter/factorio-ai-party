-- Unanswered mentions (d17 batch14 B1, Sol for viewer Foobator: compaction or a build batch buried what agents were
-- asked; reading chat cleared it). What an agent owes an answer, kept apart from the mentions inbox a read delivers:
-- - a viewer's @mention of it, a teammate's @mention, and a teammate's mention by name or tell that asks (holds '?');
-- - closed when the agent answers: a say or tell that names the sender (@name or the name), a tell to the sender, or
--   reply_to its seq on say or tell; or chat_ack {seq} (several, or "all");
-- - every reply's unanswered line gives how many, the oldest's age, who and the call that closes it; one reminder each
--   (a wake: a sleep or a remote plan's wait ends on it) once it is REMIND old.
-- Bounded: MAX per agent (the oldest dropped first, counted).
return function(api)
  local M = {}
  M.REMIND, M.MAX = 36000, 50
  local function store()
    local s = api.state()
    s.owed = s.owed or {}
    return s.owed
  end
  local function list(index)
    local o = store()
    o[index] = o[index] or {items={}, dropped=0}
    return o[index]
  end
  local function ago(t)
    local s = math.floor(t / 60)
    if s < 60 then return s .. 's' end
    if s < 3600 then return string.format('%dm%02ds', math.floor(s / 60), s % 60) end
    return string.format('%dh%02dm', math.floor(s / 3600), math.floor(s / 60) % 60)
  end
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
  -- The sender's name as an answer would name it: a viewer's without "viewer " and the host's " (host)" tag
  -- (d17 13:40: Opus answered "@NickWinter" and the mention to "NickWinter (host)" stayed open for 10 minutes).
  local function sender(from)
    local s = tostring(from or ''):gsub('^viewer ', '')
    return (s:gsub(' %(host%)$', ''))
  end
  function M.add(index, item)
    local l = list(index)
    for _, it in ipairs(l.items) do if it.key == item.key then return end end
    item.text = #item.text > 120 and item.text:sub(1, 117) .. '...' or item.text
    l.items[#l.items+1] = item
    while #l.items > M.MAX do table.remove(l.items, 1); l.dropped = l.dropped + 1 end
  end
  local function close(index, keep_fn)
    local o = store()[index]
    if not o then return 0 end
    local keep, n = {}, 0
    for _, it in ipairs(o.items) do if keep_fn(it) then keep[#keep+1] = it else n = n + 1 end end
    o.items = keep
    return n
  end
  -- A say or a team tell by index: closes what it names the sender of.
  function M.said(index, text)
    local t = tostring(text or ''):lower()
    return close(index, function(it)
      local n = sender(it.from):lower()
      return not (#n >= 2 and (has_word(t, '@' .. n) or has_word(t, n)))
    end)
  end
  -- A tell from index to name: closes what name asked.
  function M.told(index, names)
    local set = {}
    for _, n in ipairs(type(names) == 'table' and names or {names}) do set[tostring(n):lower()] = true end
    return close(index, function(it) return not set[sender(it.from):lower()] end)
  end
  -- reply_to or chat_ack: by seq (a chat line's or a tell's), several, or "all". Also marks those tells read (board.lua
  -- unread tells; d17 batch29 C2): the second value is how many.
  function M.ack(index, seqs)
    local read = api.read_tells and api.read_tells(index, seqs) or 0
    if seqs == 'all' then return close(index, function() return false end), read end
    local set = {}
    for _, s in ipairs(type(seqs) == 'table' and seqs or {seqs}) do set[tonumber(s) or -1] = true end
    return close(index, function(it) return not set[it.seq] end), read
  end
  -- The reply's line: nil when nothing is owed.
  function M.line(index)
    local o = store()[index]
    if not (o and #o.items > 0) then return nil end
    local it = o.items[1]
    local name = sender(it.from)
    return string.format('%d unanswered (oldest %s ago: %s%s #%d: "%s"); a say or tell naming %s (or reply_to: %d) answers it, chat_ack {seq: %d} closes it%s',
      #o.items, ago(game.tick - it.tick), it.from, it.source and ' (' .. it.source .. ')' or it.tell and ' (tell)' or '', it.seq, it.text, name, it.seq, it.seq,
      o.dropped > 0 and string.format('; %d older dropped', o.dropped) or '')
  end
  -- Every 10 s: one reminder for each item REMIND old (a wake: it ends a sleep or a remote plan's wait).
  function M.tick()
    for index, o in pairs(store()) do
      local due
      for _, it in ipairs(o.items) do
        if not it.reminded and game.tick - it.tick >= M.REMIND then it.reminded = true; due = due or it end
      end
      if due and api.deliver then
        pcall(api.deliver, index, {seq='owed', tick=game.tick, from='reminder: unanswered',
          text=string.format('%s asked you %s ago and has no answer yet: "%s" (say naming them, or chat_ack {seq: %d})', due.from, ago(game.tick - due.tick), due.text, due.seq),
          wake=true})
      end
    end
  end
  M.schema = {chat_ack = {seq='a chat line\'s or tell\'s seq (as the unanswered line gives it), an array of them, or "all"',
    returns='closed (how many unanswered mentions it closed), read (unread tells it marked read), unanswered (the line, or none). A say or tell that names the sender, or reply_to its seq, closes one too; reading chat does not'}}
  M.handlers = {}
  function M.handlers.chat_ack(p, a)
    assert(a.seq == 'all' or type(a.seq) == 'number' or (type(a.seq) == 'table' and #a.seq >= 1), 'seq is a number, an array of them, or "all"')
    local closed, read = M.ack(p.index, a.seq)
    return {closed=closed, read=read > 0 and read or nil, unanswered=M.line(p.index) or 'none'}
  end
  return M
end
