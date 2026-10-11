-- Game chat between agents and people. `say` posts to everyone as the
-- player; `chat` reads. Messages from players typing in a client arrive via
-- on_console_chat. Each player has a read cursor, so every reply can flag
-- unread messages without the agent polling.
return function(api)
  local M = {handlers={}}
  local MAX_LOG, MAX_LEN = 200, 500
  local function log()
    local s = api.state()
    s.chat = s.chat or {seq=0, messages={}, cursors={}}
    return s.chat
  end
  local function append(from, text, index)
    local c = log()
    c.seq = c.seq + 1
    c.messages[#c.messages+1] = {seq=c.seq, tick=game.tick, from=from, player=index, text=text}
    while #c.messages > MAX_LOG do table.remove(c.messages, 1) end
    return c.seq
  end
  M.schema = {
    say = {text='1..500 characters: posted to the game chat as this player (people and other agents see it) and shown over your character for 8 s'},
    chat = {since='optional sequence number (default: what this player has not read yet)',
      limit='1..100, newest kept (default 30)', peek='boolean: read without marking as read (overlays, spectators)',
      returns='messages {seq,tick,from,text} and cursor; marks them read unless peek'},
  }
  function M.handlers.say(p, a)
    local text = a.text
    assert(type(text) == 'string' and #text > 0, 'text is required')
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
    local seq = append(name, text, p.index)
    local c = log()
    c.cursors[p.index] = math.max(c.cursors[p.index] or 0, seq)
    -- The speech bubble is decoration: it never fails the message.
    if api.on_say then pcall(api.on_say, p, text) end
    return {seq=seq}
  end
  function M.handlers.chat(p, a)
    local c = log()
    local since = a.since or c.cursors[p.index] or 0
    assert(type(since) == 'number', 'since must be a number')
    local limit = a.limit or 30
    assert(type(limit) == 'number' and limit >= 1 and limit <= 100, 'limit must be 1..100')
    local out = {}
    for _, m in ipairs(c.messages) do
      if m.seq > since then out[#out+1] = {seq=m.seq, tick=m.tick, from=m.from, text=m.text} end
    end
    while #out > limit do table.remove(out, 1) end
    if a.peek ~= true then c.cursors[p.index] = c.seq end
    return {messages=out, cursor=c.seq}
  end
  -- Summary for other replies: count and newest unread message from someone else.
  function M.unread(index)
    local c = log()
    local cursor, n, latest = c.cursors[index] or 0, 0, nil
    for _, m in ipairs(c.messages) do
      if m.seq > cursor and m.player ~= index then n = n + 1; latest = m end
    end
    if n == 0 then return nil end
    return {unread=n, latest=latest.from .. ': ' .. latest.text, read_with='chat'}
  end
  function M.on_console_chat(event)
    local p = event.player_index and game.get_player(event.player_index)
    append(p and p.name or 'server', event.message, event.player_index)
    if p and api.on_say then pcall(api.on_say, p, event.message) end
  end
  return M
end
