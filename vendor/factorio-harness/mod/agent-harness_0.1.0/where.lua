-- Where teammates are: each agent's planet or platform (a bot riding a cargo
-- pod is in the pod), and on the reader's own surface the distance and
-- compass direction. Reads only, computed when a reply is built; nothing per
-- tick. Full status shows the line (teammates); tells, chat lines and board
-- claims say where a sender or owner on another planet is.
return function(api)
  local M = {}
  local OFFLINE = 15 * 3600  -- a bot with no request or sleep poll this long is offline
  local DIRS = {'N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW'}
  local atan2 = math.atan2 or math.atan
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function title(s) return (tostring(s):gsub('^%l', string.upper)) end
  -- Where agent `index` is: {key, text, position, dead, offline}, or nil.
  -- A player in remote view is where its body is (physical_*).
  local function place(index)
    local b = api.bot(index)
    local t = b and b.travel
    if t and t.state ~= 'aboard' then
      return {key='pod:' .. index, text='in a cargo pod' .. (t.to and ' to ' .. title(t.to) or '')}
    end
    local p = api.lookup(index)
    if not (p and p.valid) then return nil end
    local s, pos
    if not b then s = try(function() return p.physical_surface end); pos = try(function() return p.physical_position end) end
    s = s or try(function() return p.surface end)
    pos = pos or try(function() return p.position end)
    if not s then return nil end
    local pl = try(function() return s.platform end)
    local text
    if pl then text = 'on platform ' .. pl.name
    else
      local planet = try(function() return s.planet end)
      text = 'on ' .. title(planet and planet.name or s.name)
    end
    local out = {key=s.name or s.index, text=text, position=pos}
    out.dead = not (t or (p.character and p.character.valid)) or nil
    if b then
      local c = (api.state().clocks or {})[index]
      local last = c and math.max(not c.peeked and c.call_tick or 0, c.wait_tick or 0) or nil
      out.offline = not (last and game.tick - last <= OFFLINE) or nil
      -- (d20 batch50 B1) a rest between turns pushed by its loop (rests.lua): said in place of offline
      local r = api.resting and try(function() return api.resting(index) end)
      if r then out.resting, out.offline = r, nil end
    else
      out.offline = not p.connected or nil
    end
    return out
  end
  M.place = place
  local function bearing(from, to)
    local dx, dy = to.x - from.x, to.y - from.y
    local d = math.sqrt(dx * dx + dy * dy)
    if d < 1.5 then return 'beside you' end
    local k = math.floor(atan2(dx, -dy) / (math.pi / 4) + 0.5) % 8
    return string.format('%d tiles %s', math.floor(d + 0.5), DIRS[k + 1])
  end
  -- For reader `me` (an agent name): a function name -> 'on Vulcanus' when
  -- that agent is somewhere other than the reader, else nil. Memoised per
  -- reader, so a chat read of 30 lines looks each sender up once.
  function M.from(me)
    local index, mine, memo = nil, false, {}
    for _, a in ipairs(try(api.agents) or {}) do index = index or {}; index[a.name] = a.index end
    return function(name)
      if name == nil or name == me or not index or not index[name] then return nil end
      if memo[name] == nil then
        if mine == false then mine = index[me] and try(function() return place(index[me]) end) end
        local w = mine and try(function() return place(index[name]) end)
        memo[name] = (w and w.key ~= mine.key) and w.text or 0
      end
      return memo[name] ~= 0 and memo[name] or nil
    end
  end
  -- Full status: one line, agents elsewhere first (grouped by place), then
  -- those on this surface, nearest first; dead and offline marked, a rest
  -- among them ("opus 25 tiles S (resting until 07:34 (pace))"). Never fails status.
  local function line(p)
    local me = place(p.index)
    local groups, order, near = {}, {}, {}
    for _, a in ipairs(api.agents()) do
      if a.index ~= p.index and not api.human(a.index) then
        local w = place(a.index)
        if w then
          local tags = {}
          if w.dead then tags[#tags+1] = 'dead' end
          if w.offline then tags[#tags+1] = 'offline' end
          if w.resting then tags[#tags+1] = w.resting end
          local name, tag = a.display_name or a.name, #tags > 0 and ' (' .. table.concat(tags, ', ') .. ')' or ''
          if me and w.key == me.key and w.position and me.position then
            local dx, dy = w.position.x - me.position.x, w.position.y - me.position.y
            near[#near+1] = {d=dx * dx + dy * dy, text=name .. ' ' .. bearing(me.position, w.position) .. tag}
          else
            if not groups[w.text] then groups[w.text] = {}; order[#order+1] = w.text end
            local g = groups[w.text]; g[#g+1] = name .. tag
          end
        end
      end
    end
    local parts = {}
    for _, where in ipairs(order) do parts[#parts+1] = table.concat(groups[where], ', ') .. ' ' .. where end
    table.sort(near, function(x, y) return x.d < y.d end)
    for _, n in ipairs(near) do parts[#parts+1] = n.text end
    return #parts > 0 and table.concat(parts, '; ') or nil
  end
  function M.team(p) return try(function() return line(p) end) end
  -- Each teammate's character as the map shows it (d17 batch16 B2, Muse: players lists humans only, and a hand-over
  -- needed a position): name, where (planet, platform or pod), surface, position, and on your surface the distance
  -- and compass direction; dead and offline marked. Nearest on your surface first, then the rest by name.
  function M.list(p)
    local me = place(p.index)
    local rows = {}
    for _, a in ipairs(api.agents()) do
      if a.index ~= p.index and not api.human(a.index) then
        local w = try(function() return place(a.index) end)
        if w then
          local pos = w.position and {x=math.floor(w.position.x * 10 + 0.5) / 10, y=math.floor(w.position.y * 10 + 0.5) / 10}
          local here = me and w.key == me.key and pos and me.position
          local d = here and math.sqrt((pos.x - me.position.x) ^ 2 + (pos.y - me.position.y) ^ 2) or nil
          local tags = {}
          if w.dead then tags[#tags+1] = 'dead' end
          if w.offline then tags[#tags+1] = 'offline' end
          if w.resting then tags[#tags+1] = w.resting end
          local name = a.display_name or a.name
          rows[#rows+1] = {name=a.name, display_name=name ~= a.name and name or nil, where=w.text, surface=w.key, position=pos,
            distance=d and math.floor(d * 10 + 0.5) / 10 or nil, dead=w.dead, offline=w.offline, resting=w.resting,
            line=string.format('%s %s%s%s', name, w.text, pos and string.format(' at (%.1f,%.1f)', pos.x, pos.y) or '',
              (here and ', ' .. bearing(me.position, pos) or '') .. (#tags > 0 and ' (' .. table.concat(tags, ', ') .. ')' or ''))}
        end
      end
    end
    table.sort(rows, function(x, y)
      if (x.distance ~= nil) ~= (y.distance ~= nil) then return x.distance ~= nil end
      if x.distance and y.distance and x.distance ~= y.distance then return x.distance < y.distance end
      return x.name < y.name
    end)
    return rows
  end
  -- The shift start's teammates line (Nick 12:20: do agents know each other's pronouns? operator 13:05): each other
  -- agent's display name, its pronouns when it set any, and where it is when the team is on more than one planet,
  -- platform or pod: 'teammates: Astra; Gemini (she/her); Grok (they) on Vulcanus'. nil with no teammate.
  function M.shift_line(p)
    local rows, places, n = {}, {}, 0
    for _, a in ipairs(api.agents()) do
      if not api.human(a.index) then
        local w = try(function() return place(a.index) end)
        if w and not places[w.key] then places[w.key] = true; n = n + 1 end
        if a.index ~= p.index then
          local pronouns = api.pronouns and try(function() return api.pronouns(a.index) end)
          rows[#rows+1] = {name=a.display_name or a.name, pronouns=pronouns, where=w and w.text}
        end
      end
    end
    if #rows == 0 then return nil end
    table.sort(rows, function(x, y) return x.name:lower() < y.name:lower() end)
    local parts = {}
    for _, r in ipairs(rows) do
      parts[#parts+1] = r.name .. (r.pronouns and ' (' .. r.pronouns .. ')' or '') .. (n > 1 and r.where and ' ' .. r.where or '')
    end
    return 'teammates: ' .. table.concat(parts, '; ')
  end
  return M
end
