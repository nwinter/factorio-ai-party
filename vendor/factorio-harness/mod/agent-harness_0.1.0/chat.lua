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
    s.chat.left = s.chat.left or {}
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
  local function append(from, text, index, aloud, viewer, notice, look, source, reply_to)
    local c = log()
    c.seq = c.seq + 1
    local m = {seq=c.seq, tick=game.tick, from=from, player=index, text=text, aloud=aloud or nil, viewer=viewer or nil, notice=notice or nil, look=look,
      source=source, reply_to=reply_to}
    c.messages[#c.messages+1] = m
    while #c.messages > MAX_LOG do table.remove(c.messages, 1) end
    -- Mentions are filed per agent as the message arrives (board.lua); a
    -- viewer files one only for an agent it names with @ (on_viewer), and a
    -- harness notice files none.
    if viewer then
      if api.on_viewer then api.on_viewer(m) end
    elseif api.on_message and not notice then api.on_message(m) end
    return c.seq
  end
  -- A harness notice (votes.lua, players.lua) in grey: unread for every
  -- agent, never a mention; the stream shows it on its ticker.
  function M.notice(from, text)
    local line = '[color=0.62,0.62,0.62]' .. from .. ': ' .. text .. '[/color]'
    if api.audience then
      for _, viewer in ipairs(api.audience()) do viewer.print(line) end
    else
      game.print(line)
    end
    return append(from, text, nil, nil, nil, true)
  end
  -- A stream viewer's line relayed by the operator (audience.lua rate-limits
  -- it): unread for every agent, from "viewer NAME", flagged viewer.
  -- Where a viewer wrote (Luna 13:54, a viewer's suggestion: one feed with clear source labels): YouTube or the site.
  local SOURCES = {youtube='YouTube', site='site'}
  M.SOURCES = SOURCES
  function M.viewer(name, text, source)
    source = SOURCES[source] or nil
    local line = '[color=0.62,0.62,0.62]viewer ' .. name .. (source and ' (' .. source .. ')' or '') .. ':[/color] ' .. text
    if api.audience then
      for _, viewer in ipairs(api.audience()) do viewer.print(line) end
    else
      game.print(line)
    end
    return append('viewer ' .. name, text, nil, nil, true, nil, nil, source)
  end
  M.schema = {
    say = {reply_to='optional seq (or array): the chat line or tell this answers; it closes as unanswered (a say naming the sender does too; a viewer\'s line only while it is their one open line). A viewer\'s line: your line is threaded under it on the stream\'s site and starts "@Name " in the game chat when it names them nowhere (the reply\'s reply_to {seq, to, addressed})',text='1..500 bytes (fh say posts a longer one as numbered parts cut at sentence ends; in a queue step or plan a longer one is cut to 500 and the reply says so): posted to the game chat as this player (people and other agents see it) and shown over your character for 8 s; @name or @everyone notifies teammates',
      aloud='optional boolean: viewers also hear the line on the stream, spoken in your own voice; without it the line shows on the stream only as text, as tells do',
      look='optional: what the stream camera might show while the line is read out, a hint the director may take: {platform: NAME} | {position: {x,y}, surface?} | {area: {left_top, right_bottom}, surface?} | {agent: NAME}'},
    chat = {since='optional sequence number: every message after it, yours included (default: your unread messages)',
      limit='1..100, newest kept (default 30)', peek='boolean: read without marking as read (overlays, spectators)',
      returns='messages {seq,tick,from,away?,text,aloud?,viewer?,source?,notice?,mention?,reply_to?,answer?} oldest first (reply_to: the viewer line a say answered with reply_to; answer: on a viewer\'s line to you, what answers it) (away: "on Vulcanus" when the sender is a teammate somewhere other than you now):the newest `limit`, plus every older one that mentions you (mention: @|@everyone|name); viewer: a stream viewer\'s line, moderated and relayed by the stream service, from "viewer NAME", not a teammate (it mentions you only with @your name); source: where the viewer wrote, YouTube or site; every line, team and viewers, in one sequence (seq); notice: a harness line (mute votes). cursor (latest seq); remaining and digest (one line: count, seq range and senders of the messages not returned; chat again for them). Only returned messages are marked read, unless peek; while a read left some unread, every reply\'s team hints carry chat_remaining'},
  }
  -- A camera hint for the stream (Nick, 14:11: "an easy optional parameter to suggest the director look at
  -- something in particular when their message is read out"): checked here, kept on the message, returned by
  -- `chat`; the stream's director decides whether to show it.
  local function xy(v)
    if type(v) == 'table' and type(v.x) == 'number' and type(v.y) == 'number' then return v.x, v.y end
    if type(v) == 'table' and type(v[1]) == 'number' and type(v[2]) == 'number' then return v[1], v[2] end
  end
  local LOOK_FORMS = 'look must be {platform: NAME} | {position: {x,y}, surface?} | {area: {left_top, right_bottom}, surface?} | {agent: NAME}'
  local function check_look(p, look)
    if look == nil then return nil end
    assert(type(look) == 'table', LOOK_FORMS)
    if look.platform ~= nil then
      assert(api.platform, 'look.platform: no space platforms here')
      return {platform=api.platform(p, look.platform).name}
    end
    if look.agent ~= nil then
      local want = string.lower(tostring(look.agent))
      local names = {}
      for _, ag in ipairs(api.agents and api.agents() or {}) do
        if string.lower(ag.name) == want or (ag.display_name and string.lower(ag.display_name) == want) then return {agent=ag.name} end
        names[#names+1] = ag.name
      end
      error('look.agent: no agent named ' .. tostring(look.agent) .. (#names > 0 and '; agents: ' .. table.concat(names, ', ') or ''), 0)
    end
    local surface = p.surface
    if look.surface ~= nil then
      surface = game.surfaces[look.surface]
      assert(surface, 'look.surface: no surface named ' .. tostring(look.surface))
    end
    local x, y, extent
    if look.position ~= nil then
      x, y = xy(look.position)
      assert(x, 'look.position must be {x,y}')
      extent = 0
    elseif look.area ~= nil then
      assert(type(look.area) == 'table', 'look.area must be {left_top, right_bottom}')
      local x0, y0 = xy(look.area.left_top)
      local x1, y1 = xy(look.area.right_bottom)
      assert(x0 and x1, 'look.area must be {left_top: {x,y}, right_bottom: {x,y}}')
      x, y, extent = (x0 + x1) / 2, (y0 + y1) / 2, math.max(math.abs(x1 - x0), math.abs(y1 - y0))
    else
      error(LOOK_FORMS, 0)
    end
    assert(p.force.is_chunk_charted(surface, {x=math.floor(x / 32), y=math.floor(y / 32)}),
      'look: (' .. math.floor(x) .. ',' .. math.floor(y) .. ') on ' .. surface.name .. ' is not charted')
    return {position={x=math.floor(x * 10 + 0.5) / 10, y=math.floor(y * 10 + 0.5) / 10}, surface=surface.name,
      extent=extent > 0 and math.floor(extent + 0.5) or nil}
  end
  -- (d20 batch50 C1) The viewer line a reply_to names (its seq, or the first of an array that is one), or nil.
  local function viewer_line(reply_to)
    local want = {}
    for _, s in ipairs(type(reply_to) == 'table' and reply_to or {reply_to}) do if type(s) == 'number' then want[#want+1] = s end end
    for _, s in ipairs(want) do
      for i = #log().messages, 1, -1 do
        local m = log().messages[i]
        if m.seq == s then if m.viewer then return m end break end
      end
    end
  end
  -- The name a viewer is answered by: "viewer NickWinter (host)" -> NickWinter.
  function M.viewer_name(from) return (tostring(from or ''):gsub('^viewer ', ''):gsub(' %(host%)$', '')) end
  local function names(text, who)
    local t, w, init = text:lower(), who:lower(), 1
    while #w > 0 do
      local i, j = t:find(w, init, true)
      if not i then return false end
      local before, after = t:sub(i - 1, i - 1), t:sub(j + 1, j + 1)
      if not before:find('[%w_]') and not after:find('[%w_]') then return true end
      init = i + 1
    end
    return false
  end
  function M.handlers.say(p, a)
    local text = a.text
    assert(type(text) == 'string' and text:match('%S'), 'text is required: fh say "your words", or for text with quotes or apostrophes fh say - <<\'EOF\' (text on the next lines, then EOF)')
    assert(a.aloud == nil or type(a.aloud) == 'boolean', 'aloud must be true or false')
    local look = check_look(p, a.look)
    text = text:gsub('[\r\n]+', ' ')
    -- (d20 batch50 C1, NickWinter 07:25: Muse's answer named no one and he read it as none) reply_to a viewer's line:
    -- the line keeps reply_to (the site threads it under that line) and, naming them nowhere, starts "@Name " in the
    -- game chat as well
    local re = a.reply_to ~= nil and viewer_line(a.reply_to) or nil
    local addressed
    if re then
      local who = M.viewer_name(re.from)
      if #who > 0 and not names(text, who) then text = '@' .. who .. ' ' .. text; addressed = who end
    end
    local cut = #text > MAX_LEN and {length=#text, kept=MAX_LEN} or nil
    if cut then text = text:sub(1, MAX_LEN) end
    local name = p.name ~= '' and p.name or ('player ' .. p.index)
    local color = p.chat_color
    local line = '[color=' .. string.format('%.2f,%.2f,%.2f', color.r, color.g, color.b) .. ']' .. name .. '[/color]: ' .. text
    -- Camera clients get no console lines (their view shows the bubbles).
    if api.audience then
      for _, viewer in ipairs(api.audience()) do viewer.print(line) end
    else
      game.print(line)
    end
    local seq = append(name, text, p.index, a.aloud == true, nil, nil, look, nil, re and re.seq)
    -- (d17 batch14 B1) reply_to: the chat line or tell this answers (owed.lua)
    if a.reply_to ~= nil and api.on_reply then pcall(api.on_reply, p.index, a.reply_to) end
    -- Your own messages count as read (is_read); others' stay unread.
    -- The speech bubble is decoration: it never fails the message.
    if api.on_say then pcall(api.on_say, p, text) end
    -- (d20 batch57 S1) without reply_to: the named viewers whose several open lines it left open
    local held = a.reply_to == nil and api.owed_held and api.owed_held(p.index, text) or nil
    return {seq=seq, cut=cut, reply_to=re and {seq=re.seq, to=M.viewer_name(re.from), addressed=addressed and '@' .. addressed .. ' put in front' or nil} or nil,
      left_open=held}
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
    -- The newest `limit` in full, and every message that mentions the reader
    -- however old (up to MAX_MENTIONS more); the rest go into one digest line.
    local MAX_MENTIONS = 100
    local extra = 0
    local where = api.where_from and api.where_from(p.index)
    for i, m in ipairs(picked) do
      local how = api.mention_of and api.mention_of(p.index, m)
      local newest = i > #picked - limit
      if newest or (how and extra < MAX_MENTIONS) then
        if not newest then extra = extra + 1 end
        out[#out+1] = {seq=m.seq, tick=m.tick, from=m.from, away=where and where(m.from) or nil, text=m.text, aloud=m.aloud, viewer=m.viewer, source=m.source, notice=m.notice, mention=how or nil, look=m.look,
          reply_to=m.reply_to,
          -- (d20 batch50 C1) a viewer's line to you: what answers it, as the unanswered line says
          answer=m.viewer and how and string.format('reply_to: %d answers it (a say naming %s does while it is their only open line)', m.seq, M.viewer_name(m.from)) or nil}
      end
    end
    if a.peek ~= true then
      mark(c, p.index, out)
      -- Mentions shown here are delivered; ones cut by limit stay pending.
      if api.on_read then api.on_read(p.index, out) end
    end
    local shown, rest, senders, order = {}, {}, {}, {}
    for _, m in ipairs(out) do shown[m.seq] = true end
    for _, m in ipairs(c.messages) do
      if not shown[m.seq] and not is_read(c, p.index, m) then
        rest[#rest+1] = m
        if not senders[m.from] then senders[m.from] = 0; order[#order+1] = m.from end
        senders[m.from] = senders[m.from] + 1
      end
    end
    local digest
    if #rest > 0 then
      table.sort(order, function(x, y) if senders[x] ~= senders[y] then return senders[x] > senders[y] end return x < y end)
      local parts = {}
      for i, from in ipairs(order) do
        if i > 6 then parts[#parts+1] = '+' .. (#order - 6) .. ' more'; break end
        parts[#parts+1] = from .. ' ' .. senders[from]
      end
      digest = string.format('%d older message%s not shown (seq %d..%d): %s; chat again for them', #rest, #rest == 1 and '' or 's',
        rest[1].seq, rest[#rest].seq, table.concat(parts, ', '))
    end
    -- A read that left unread messages is repeated in the team hints (M.left).
    if a.peek ~= true and not a.since then c.left[p.index] = #rest > 0 or nil end
    return {messages=out, cursor=c.seq, remaining=#rest > 0 and #rest or nil, digest=digest}
  end
  -- Unread messages left after this player's last chat read, until none are.
  function M.left(index)
    local c = log()
    if not c.left[index] then return nil end
    local n = 0
    for _, m in ipairs(c.messages) do if not is_read(c, index, m) then n = n + 1 end end
    if n == 0 then c.left[index] = nil; return nil end
    return n
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
    local where = api.where_from and api.where_from(index)
    local away = where and where(latest.from)
    return {unread=n, latest=latest.from .. (away and ' (' .. away .. ')' or '') .. ': ' .. latest.text, read_with='chat'}
  end
  function M.on_console_chat(event)
    local p = event.player_index and game.get_player(event.player_index)
    append(p and p.name or 'server', event.message, event.player_index)
    if p and api.on_say then pcall(api.on_say, p, event.message) end
  end
  return M
end
