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
  -- those on this surface, nearest first. Never fails status.
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
  return M
end
