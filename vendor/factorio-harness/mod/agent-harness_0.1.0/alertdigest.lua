-- alerts_digest {surface?, since?, limit?} (batch26 B1, Luna: repeated Nauvis group and attack alerts flooded status and
-- were forwarded again and again): the enemy and structure alerts the harness keeps (threat.lua's attack incidents, the
-- loss incidents, the enemy groups seen gathering with a target), one line per surface and 64-tile place, each incident
-- once, newest first. since: a tick; without it, since this agent's last digest read (its first: the last 10 minutes);
-- the reply's next_since is the tick to pass next time. status says how many places have news since the last read.
return function(api)
  local M = {}
  local CELL, FIRST, LIMIT = 64, 36000, 32
  local function round(v) return math.floor(v + 0.5) end
  local function ago(t)
    local s = math.floor((game.tick - t) / 60)
    if s >= 3600 then return string.format('%dh%02dm', math.floor(s / 3600), math.floor(s / 60) % 60) end
    if s >= 60 then return string.format('%dm%02ds', math.floor(s / 60), s % 60) end
    return s .. 's'
  end
  local function counts(t, n)
    local list = {}
    for k, v in pairs(t or {}) do list[#list+1] = {k, v} end
    table.sort(list, function(x, y) return x[2] > y[2] or (x[2] == y[2] and x[1] < y[1]) end)
    local parts = {}
    for i, v in ipairs(list) do if i <= (n or 4) then parts[i] = v[2] .. ' ' .. v[1] end end
    return table.concat(parts, ', ') .. (#list > (n or 4) and ', ...' or '')
  end
  local function reads() local s = api.state(); s.alert_digest_read = s.alert_digest_read or {}; return s.alert_digest_read end
  -- The news after since, by surface and place: {key -> {surface, cx, cy, last, attacks, losses, groups}}.
  local function gather(since, surface)
    local s = api.state()
    local cells = {}
    local function cell(surf, pos, tick)
      local cx, cy = math.floor(pos.x / CELL), math.floor(pos.y / CELL)
      local k = surf .. ':' .. cx .. ',' .. cy
      local c = cells[k]
      if not c then c = {surface=surf, cx=cx, cy=cy, last=tick, attacks={}, losses={}, groups={}}; cells[k] = c end
      if tick > c.last then c.last = tick end
      return c
    end
    for _, v in pairs(s.damage or {}) do
      local surf = v.surface or 'nauvis'
      if v.id and v.at and (v.last or 0) > since and (not surface or surf == surface) then
        table.insert(cell(surf, v.at, v.last).attacks, v)
      end
    end
    for _, i in ipairs(s.losses or {}) do
      local surf = i.surface or 'nauvis'
      local last = i.last or i.first or 0
      if i.box and not i.platform and last > since and (not surface or surf == surface) then
        table.insert(cell(surf, {x=(i.box[1] + i.box[3]) / 2, y=(i.box[2] + i.box[4]) / 2}, last).losses, i)
      end
    end
    for _, g in ipairs(s.attack_groups or {}) do
      local surf = g.surface or 'nauvis'
      if g.tick > since and (g.target or g.position) and (not surface or surf == surface) then
        table.insert(cell(surf, g.target or g.position, g.tick).groups, g)
      end
    end
    return cells
  end
  function M.count(p)
    local since = reads()[p.index] or (game.tick - FIRST)
    local n = 0
    for _ in pairs(gather(since)) do n = n + 1 end
    return n, since
  end
  function M.read(p, a)
    local since = a.since
    if since ~= nil then assert(type(since) == 'number' and since >= 0 and since == math.floor(since), 'since: a game tick (the reply\'s next_since)') end
    since = since or reads()[p.index] or math.max(0, game.tick - FIRST)
    local limit = a.limit == nil and LIMIT or a.limit
    assert(type(limit) == 'number' and limit >= 1 and limit <= 64, 'limit: 1..64 places (default 32)')
    -- (d20 batch62 X2, Sol #1529) a surface name that is no surface is refused, never read as an empty one
    if a.surface ~= nil then assert(type(a.surface) == 'string' and game.get_surface(a.surface), 'no surface named ' .. tostring(a.surface)) end
    local cells = gather(since, a.surface)
    local list = {}
    for _, c in pairs(cells) do list[#list+1] = c end
    table.sort(list, function(x, y) return x.last > y.last end)
    local lines, rows = {}, {}
    for i, c in ipairs(list) do
      if i > limit then break end
      local parts = {}
      local hits, kinds, hit, ids = 0, {}, {}, {}
      for _, v in ipairs(c.attacks) do
        hits = hits + (v.hits or 0); ids[#ids+1] = '#' .. v.id
        for k, n in pairs(v.kinds or {}) do kinds[k] = (kinds[k] or 0) + n end
        for k, n in pairs(v.entities or {}) do hit[k] = (hit[k] or 0) + n end
      end
      if #c.attacks > 0 then
        table.sort(ids)
        parts[#parts+1] = string.format('attack %s: %d hits%s on %s', table.concat(ids, ' '), hits, next(kinds) and ' by ' .. counts(kinds) or '', counts(hit))
      end
      local lost, total = {}, 0
      for _, l in ipairs(c.losses) do
        total = total + (l.total or 0)
        for k, n in pairs(l.names or {}) do lost[k] = (lost[k] or 0) + n end
      end
      if #c.losses > 0 then parts[#parts+1] = string.format('%d lost (%s)', total, counts(lost)) end
      for _, g in ipairs(c.groups) do
        parts[#parts+1] = string.format('a group of %d%s gathered at (%d,%d) heading here %s ago', g.size or 0, g.kinds and ' (' .. g.kinds .. ')' or '',
          round(g.position and g.position.x or 0), round(g.position and g.position.y or 0), ago(g.tick))
      end
      local where = string.format('%s near (%d,%d)', c.surface, c.cx * CELL + CELL / 2, c.cy * CELL + CELL / 2)
      lines[#lines+1] = string.format('%s, last %s ago: %s', where, ago(c.last), table.concat(parts, '; '))
      rows[#rows+1] = {surface=c.surface, centre={x=c.cx * CELL + CELL / 2, y=c.cy * CELL + CELL / 2}, last_tick=c.last,
        attacks=#c.attacks, lost=total, groups=#c.groups}
    end
    if a.since == nil then reads()[p.index] = game.tick end
    return {since=since, next_since=game.tick, places=#list, more=#list > limit and #list - limit or nil, lines=lines, rows=rows,
      note=#list == 0 and 'no enemy or structure alert since tick ' .. since or nil}
  end
  M.schema = {alerts_digest = {surface='optional surface name', since='optional game tick: news after it (default: since your last alerts_digest read; the first: the last 10 minutes)',
    limit='optional 1..64 places (default 32)',
    returns='lines: one per surface and 64-tile place, newest first: the attack incidents there (ids, hits, attackers, what was hit), what was lost, enemy groups seen gathering heading there; rows, places, more, since, next_since (pass it as since next time; a read without since moves your mark to now). status gives alerts_new: how many places have news since your mark. Read only; what wakes a wait is its own filters'}}
  return M
end
