-- Game chat between agents and people. `say` posts to everyone as the
-- player; `chat` reads. Messages from players typing in a client arrive via
-- on_console_chat. Each player has a read cursor, so every reply can flag
-- unread messages without the agent polling.
-- Reading is lossless: a message is read only once a reply returned it (or
-- the player wrote it). The cursor covers everything up to it; `read` holds
-- the returned messages above it (at most the log's 200).
return function(api)
  local M = {handlers={}}
  local MAX_LOG, MAX_LEN = 200, 500
  local function log()
    local s = api.state()
    s.chat = s.chat or {seq=0, messages={}, cursors={}}
    s.chat.read = s.chat.read or {}
    s.chat.told = s.chat.told or {}
    return s.chat
  end
  local function is_read(c, index, m)
    if m.player == index or m.seq <= (c.cursors[index] or 0) then return true end
    local set = c.read[index]
    return set ~= nil and set[m.seq] == true
  end
  -- Mark messages read and move the cursor over the read run that follows it.
  local function mark(c, index, shown)
    local set = c.read[index] or {}
    for _, m in ipairs(shown) do set[m.seq] = true end
    local cursor = c.cursors[index] or 0
    for _, m in ipairs(c.messages) do
      if m.seq > cursor then
        if is_read(c, index, m) or set[m.seq] then cursor = m.seq else break end
      end
    end
    c.cursors[index] = cursor
    local oldest = c.messages[1] and c.messages[1].seq or cursor
    for seq in pairs(set) do
      if seq <= cursor or seq < oldest then set[seq] = nil end
    end
    c.read[index] = next(set) and set or nil
  end
  local function append(from, text, index, aloud, viewer)
    local c = log()
    c.seq = c.seq + 1
    local m = {seq=c.seq, tick=game.tick, from=from, player=index, text=text, aloud=aloud or nil, viewer=viewer or nil}
    c.messages[#c.messages+1] = m
    while #c.messages > MAX_LOG do table.remove(c.messages, 1) end
    -- Mentions are filed per agent as the message arrives (board.lua); a
    -- viewer's @name is not a teammate's, so it files none.
    if api.on_message and not viewer then api.on_message(m) end
    return c.seq
  end
  -- A stream viewer's line relayed by the operator (audience.lua rate-limits
  -- it): unread for every agent, from "viewer NAME", flagged viewer.
  function M.viewer(name, text)
    local line = '[color=0.62,0.62,0.62]viewer ' .. name .. ':[/color] ' .. text
    if api.audience then
      for _, viewer in ipairs(api.audience()) do viewer.print(line) end
    else
      game.print(line)
    end
    return append('viewer ' .. name, text, nil, nil, true)
  end
  M.schema = {
    say = {text='1..500 characters: posted to the game chat as this player (people and other agents see it) and shown over your character for 8 s; @name or @everyone notifies teammates',
      aloud='optional boolean: also speak it aloud on the stream (use sparingly)'},
    chat = {since='optional sequence number: every message after it, yours included (default: your unread messages)',
      limit='1..100, newest kept (default 30)', peek='boolean: read without marking as read (overlays, spectators)',
      returns='messages {seq,tick,from,text,aloud?,viewer?} oldest first (viewer: a stream viewer\'s line the operator relayed, from "viewer NAME"; not a teammate), cursor (latest seq) and remaining (unread messages not returned: older than the newest `limit`; chat again for them). Only returned messages are marked read, unless peek'},
  }
  function M.handlers.say(p, a)
    local text = a.text
    assert(type(text) == 'string' and #text > 0, 'text is required')
    assert(a.aloud == nil or type(a.aloud) == 'boolean', 'aloud must be true or false')
    text = text:gsub('[\r\n]+', ' ')
    if #text > MAX_LEN then text = text:sub(1, MAX_LEN) end
    local name = p.name ~= '' and p.name or ('player ' .. p.index)
    local color = p.chat_color
    local line = '[color=' .. string.format('%.2f,%.2f,%.2f', color.r, color.g, color.b) .. ']' .. name .. '[/color]: ' .. text
    -- Camera clients get no console lines (their view shows the bubbles).
    if api.audience then
      for _, viewer in ipairs(api.audience()) do viewer.print(line) end
    else
      game.print(line)
    end
    local seq = append(name, text, p.index, a.aloud == true)
    -- Your own messages count as read (is_read); others' stay unread.
    -- The speech bubble is decoration: it never fails the message.
    if api.on_say then pcall(api.on_say, p, text) end
    return {seq=seq}
  end
  function M.handlers.chat(p, a)
    local c = log()
    assert(a.since == nil or type(a.since) == 'number', 'since must be a number')
    local limit = a.limit or 30
    assert(type(limit) == 'number' and limit >= 1 and limit <= 100, 'limit must be 1..100')
    local out, picked = {}, {}
    for _, m in ipairs(c.messages) do
      local wanted
      if a.since then wanted = m.seq > a.since else wanted = not is_read(c, p.index, m) end
      if wanted then picked[#picked+1] = m end
    end
    for i = math.max(1, #picked - limit + 1), #picked do
      local m = picked[i]
      out[#out+1] = {seq=m.seq, tick=m.tick, from=m.from, text=m.text, aloud=m.aloud, viewer=m.viewer}
    end
    if a.peek ~= true then
      mark(c, p.index, out)
      -- Mentions shown here are delivered; ones cut by limit stay pending.
      if api.on_read then api.on_read(p.index, out) end
    end
    local remaining = 0
    local shown = {}
    for _, m in ipairs(out) do shown[m.seq] = true end
    for _, m in ipairs(c.messages) do
      if not shown[m.seq] and not is_read(c, p.index, m) then remaining = remaining + 1 end
    end
    return {messages=out, cursor=c.seq, remaining=remaining > 0 and remaining or nil}
  end
  -- Summary for other replies: count and newest unread message from someone
  -- else. Shown when the newest unread message changed since this player was
  -- last told (always for 'always', without remembering for 'peek').
  function M.unread(index, mode)
    local c = log()
    local n, latest = 0, nil
    for _, m in ipairs(c.messages) do
      if not is_read(c, index, m) then n = n + 1; latest = m end
    end
    if n == 0 then c.told[index] = nil; return nil end
    if mode ~= 'peek' then
      if mode ~= 'always' and c.told[index] == latest.seq then return nil end
      c.told[index] = latest.seq
    end
    return {unread=n, latest=latest.from .. ': ' .. latest.text, read_with='chat'}
  end
  function M.on_console_chat(event)
    local p = event.player_index and game.get_player(event.player_index)
    append(p and p.name or 'server', event.message, event.player_index)
    if p and api.on_say then pcall(api.on_say, p, event.message) end
  end
  return M
end
