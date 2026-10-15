-- Urgent alerts end every sleep and direct wait by default (Nick, d15 06:17: "urgent alerts could wake everyone").
-- From shifts 14-16 (runs/shiftNN journals): of 93 `fh wait --until alert` wakes (Haiku 93, Luna 13, Opus 2), 83 came
-- within 60 s, mostly a lone biter hitting a turret somewhere on the map, and after them Haiku moved to plain sleeps
-- that nothing but a tell could end (06:20: "alerts wake fh wait --until 'tell|alert' over and over"). What a player
-- would drop everything for, and so wakes a sleeper:
--   attack: our structures hit within NEAR tiles of your character (enemies close to you);
--   group: an enemy group gathering to head for a spot within GROUP_NEAR tiles of you;
--   losses: our buildings destroyed by enemies in one of your fresh claims, or within NEAR tiles of you;
--   platform: a platform you hear about (as its alerts route them) losing a building, or its hub taking damage;
--   death: a teammate's character died on your surface;
--   power: an electric network on your surface with MIN_MACHINES+ machines, half of them on low or no power.
-- Each one wakes an agent once (an attack, group, loss incident, death), and again only after REPEAT if it grew. All
-- of it is read from what the harness already keeps (threat.lua's attacked areas and groups, the loss incidents, the
-- platform hit counts, the chronicle's deaths, the networks' cached view): no scan, a few small tables a check.
-- alert(p, from, filter): which attack, group or nest news woke an `until=alert` sleep, optionally filtered by area
-- and size (Haiku, 06:20: "an alert filter by area or minimum size").
return function(api)
  local M = {}
  -- GROUP_NEAR was 64 (d15 first cut); Haiku, shift17 09:20: groups heading 52-63 tiles away that gathered 100+ tiles
  -- off woke its sleeps every few minutes ("an urgent alert about a far attack"), so a group's target counts within the
  -- same 40 tiles as an attack.
  M.NEAR, M.GROUP_NEAR, M.MIN_MACHINES, M.SHARE, M.REPEAT = 40, 40, 20, 0.5, 5 * 3600
  local KEEP = 30 * 3600
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function round(v) return math.floor(v + 0.5) end
  local function dist(a, b) return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2) end
  local function where(p)
    local surface = try(function() return p.surface.name end)
    local c = p.character
    local pos = c and try(function() return c.valid and c.position end) or nil
    return surface, pos and {x=pos.x, y=pos.y} or nil
  end
  local function told_of(index)
    local s = api.state()
    s.urgent_told = s.urgent_told or {}
    local t = s.urgent_told[index]
    if not t then t = {}; s.urgent_told[index] = t end
    return t
  end
  -- New to this agent, or grown since it was told REPEAT ago.
  local function news(told, key, level)
    local t = told[key]
    return not t or (game.tick - t.tick >= M.REPEAT and level > t.level)
  end
  local function tell(told, key, level)
    told[key] = {tick=game.tick, level=level}
    for k, t in pairs(told) do if game.tick - t.tick > KEEP then told[k] = nil end end
  end
  local function names_text(map, n)
    local list = {}
    for name, count in pairs(map or {}) do list[#list+1] = {name=name, count=count} end
    table.sort(list, function(a, b) return a.count > b.count or (a.count == b.count and a.name < b.name) end)
    local parts = {}
    for i = 1, math.min(n, #list) do parts[i] = list[i].count .. ' ' .. list[i].name end
    return table.concat(parts, ', ') .. (#list > n and ', ...' or '')
  end
  local function box_centre(b) return {x=(b[1] + b[3]) / 2, y=(b[2] + b[4]) / 2} end
  local function box_dist(b, pos)
    local dx = math.max(b[1] - pos.x, 0, pos.x - b[3])
    local dy = math.max(b[2] - pos.y, 0, pos.y - b[4])
    return math.sqrt(dx * dx + dy * dy)
  end
  local function overlaps(b, a)
    return b[1] <= a.right_bottom.x and b[3] >= a.left_top.x and b[2] <= a.right_bottom.y and b[4] >= a.left_top.y
  end
  -- p's own claims that are open and fresh (not stale), on surface.
  local function my_claim(p, surface, b)
    local board = api.state().board
    local me = api.who and api.who(p) or p.name
    for _, i in pairs(board and board.items or {}) do
      if i.kind == 'claim' and i.owner == me and i.area and (i.status == 'open' or i.status == 'claimed' or i.status == 'doing' or i.status == 'blocked')
        and not (api.claim_stale and api.claim_stale(i)) and (api.claim_surface and api.claim_surface(i) or i.surface or 'nauvis') == surface
        and overlaps(b, i.area) then return i end
    end
  end
  -- Power: the networks on each surface whose machines are half on low or no power (the cached view; nil while none).
  local function collapsed(p)
    local view = api.power_view and try(function() return api.power_view(p.force) end)
    local out = {}
    for _, s in ipairs(view and view.surfaces or {}) do
      for _, r in ipairs(s.electric or {}) do
        local bad = (r.low or 0) + (r.none or 0)
        if (r.machines or 0) >= M.MIN_MACHINES and bad >= M.SHARE * r.machines then
          out[#out+1] = {key='power|' .. s.name .. '|' .. tostring(r.id), surface=s.name, level=bad, r=r}
        end
      end
    end
    return out
  end
  -- What a sleep or wait remembers at its start: the hub damage per platform (hits before it do not wake it).
  function M.base(p)
    local base = {tick=game.tick, hub={}}
    local by = try(function() return api.state().platform_alerts.by end)
    for index, r in pairs(by or {}) do
      base.hub[index] = r.total and r.total.entities and r.total.entities['space-platform-hub'] or 0
    end
    return base
  end
  -- The urgent line that wakes p now, or nil; once returned, that event is told to p.
  function M.check(p, base)
    local s = api.state()
    local surface, pos = where(p)
    local told = told_of(p.index)
    local since = base.tick
    local me = api.who and api.who(p) or p.name
    -- Attacks on our structures near the character.
    if pos then
      for _, v in pairs(s.damage or {}) do
        if v.id and v.at and (v.damage or 0) > 0 and v.last >= since and (v.surface or 'nauvis') == surface then
          local d = dist(v.at, pos)
          local key = 'attack|' .. v.id
          if d <= M.NEAR and news(told, key, v.hits or 0) then
            tell(told, key, v.hits or 0)
            local line = api.attack_line and api.attack_line(v, false, surface) or string.format('attack at (%d,%d)', v.at.x, v.at.y)
            return string.format('attack on our structures %d tiles from you: %s', round(d), line)
          end
        end
      end
      for k = #(s.attack_groups or {}), 1, -1 do
        local g = s.attack_groups[k]
        if g.tick < since then break end
        if g.target and (g.surface or 'nauvis') == surface then
          local d = dist(g.target, pos)
          local key = 'group|' .. tostring(g.seq)
          if d <= M.GROUP_NEAR and news(told, key, g.size or 0) then
            tell(told, key, g.size or 0)
            return string.format('enemy group of %d%s gathered at (%d,%d), %d tiles from you, heading for (%d,%d), %d tiles from you',
              g.size or 0, g.kinds and ' (' .. g.kinds .. ')' or '', g.position.x, g.position.y, round(dist(g.position, pos)),
              g.target.x, g.target.y, round(d))
          end
        end
      end
    end
    -- Buildings destroyed by enemies: in a fresh claim of p's, near p, or on a platform p hears about.
    for _, i in ipairs(s.losses or {}) do
      local last = i.last or i.first or 0
      if last >= since and next(i.causes or {}) and i.box then
        local key = 'loss|' .. tostring(i.id)
        if news(told, key, i.total or 0) then
          local why
          if i.platform then
            if api.platform_hears and api.platform_hears(p, i.platform) then why = 'platform ' .. i.platform .. ' lost buildings' end
          elseif i.surface == surface then
            local claim = my_claim(p, surface, i.box)
            if claim then why = string.format('buildings destroyed in your claim #%s "%s"', tostring(claim.id), tostring(claim.title or ''))
            elseif pos and box_dist(i.box, pos) <= M.NEAR then why = string.format('buildings destroyed %d tiles from you', round(box_dist(i.box, pos))) end
          end
          if why then
            tell(told, key, i.total or 0)
            local c = box_centre(i.box)
            return string.format('%s: loss #%s at (%d,%d)%s: %d destroyed (%s) by %s', why, tostring(i.id), round(c.x), round(c.y),
              i.surface ~= surface and ' on ' .. tostring(i.surface) or '', i.total or 0, names_text(i.names, 3), names_text(i.causes, 2))
          end
        end
      end
    end
    -- A platform's hub taking damage.
    local by = try(function() return s.platform_alerts.by end)
    for index, r in pairs(by or {}) do
      local now = r.total and r.total.entities and r.total.entities['space-platform-hub'] or 0
      if now > (base.hub[index] or 0) then
        local pl = try(function() return p.force.platforms[index] end)
        if not pl then
          for _, x in pairs(try(function() return p.force.platforms end) or {}) do if try(function() return x.index end) == index then pl = x end end
        end
        local name = pl and try(function() return pl.name end)
        local lost = now - (base.hub[index] or 0)
        base.hub[index] = now
        if name and api.platform_hears and api.platform_hears(p, name) then
          local hub = try(function() return pl.hub end)
          local health = hub and try(function() return hub.valid and hub.health end)
          local max = hub and try(function() return hub.valid and hub.max_health end)
          return string.format('platform %s: its hub took %d damage%s%s', name, round(lost),
            health and max and string.format(', health %d of %d', round(health), round(max)) or '', next(r.total.by or {}) and '; hits by ' .. names_text(r.total.by, 2) or '')
        end
      end
    end
    -- A teammate died on this surface.
    local c = s.chronicle
    for k = #(c and c.events or {}), 1, -1 do
      local e = c.events[k]
      if (e.tick or 0) < since then break end
      if e.kind == 'death' and e.agent ~= me and e.surface == surface then
        local key = 'death|' .. tostring(e.id)
        if news(told, key, 1) then
          tell(told, key, 1)
          local at = e.position and string.format(' at (%d,%d)', e.position.x, e.position.y) or ''
          local d = pos and e.position and string.format(', %d tiles from you', round(dist(e.position, pos))) or ''
          return string.format('%s died%s%s%s', tostring(e.agent), at, e.by and ', killed by ' .. e.by or '', d)
        end
      end
    end
    -- Power collapse on this surface.
    for _, x in ipairs(collapsed(p)) do
      if x.surface == surface and news(told, x.key, x.level) then
        tell(told, x.key, x.level)
        local r = x.r
        local at = r.center and string.format(' near (%d,%d)', round(r.center.x), round(r.center.y)) or ''
        return string.format('power collapse: electric #%s%s has %d of %d machines on low or no power (%d low, %d none)', tostring(r.id), at,
          x.level, r.machines, r.low or 0, r.none or 0)
      end
    end
  end
  -- A direct wait_ticks or wait_until (runtime.lua's tick, every second): ends it with last.why naming the alert.
  function M.waking(p, action)
    local line = M.check(p, action.urgent)
    if line then action.told = 'urgent: ' .. line; return true end
  end
  -- until=alert: the alert that woke it (new since `from`, an alert_seq), as a line; with a filter only one that matches
  -- it: {area={left_top,right_bottom}} or {near={x,y}, radius=R} on `surface` (default the sleeper's), min_size=N
  -- (an attack by N+ attackers or a group of N+; nest news has no size and never matches a min_size).
  local function inside(f, pos)
    if not f.area then return true end
    local a = f.area
    return pos ~= nil and pos.x >= a.left_top.x and pos.x <= a.right_bottom.x and pos.y >= a.left_top.y and pos.y <= a.right_bottom.y
  end
  function M.alert(p, from, f)
    local s = api.state()
    f = f or {}
    local surface = f.surface or (f.area and try(function() return p.surface.name end)) or nil
    local function here(x) return not surface or (x or 'nauvis') == surface end
    local best, best_seq
    for _, v in pairs(s.damage or {}) do
      if v.id and v.at and (v.seq or 0) > from and (v.damage or 0) > 0 and here(v.surface) and inside(f, v.at) then
        local size = math.max(v.size or 0, v.group and v.group.size or 0)
        if (not f.min_size or size >= f.min_size) and (not best_seq or v.seq > best_seq) then
          best_seq = v.seq
          best = api.attack_line and api.attack_line(v, false, try(function() return p.surface.name end)) or string.format('attack at (%d,%d)', v.at.x, v.at.y)
        end
      end
    end
    for k = #(s.attack_groups or {}), 1, -1 do
      local g = s.attack_groups[k]
      if (g.seq or 0) <= from then break end
      if here(g.surface) and (inside(f, g.target) or inside(f, g.position)) and (not f.min_size or (g.size or 0) >= f.min_size)
        and (not best_seq or g.seq > best_seq) then
        best_seq = g.seq
        best = string.format('enemy group of %d gathered at (%d,%d)%s', g.size or 0, g.position.x, g.position.y,
          g.target and string.format(' heading for (%d,%d)', g.target.x, g.target.y) or '')
      end
    end
    if not f.min_size then
      for k = #(s.enemy_news or {}), 1, -1 do
        local n = s.enemy_news[k]
        if (n.seq or 0) <= from then break end
        if here(n.surface) and inside(f, n.position) and (not best_seq or n.seq > best_seq) then
          best_seq = n.seq
          best = string.format('%s (%g,%g), %d spawner%s', n.kind == 'pollution_reached_nest' and 'pollution reached nest' or 'nest charted',
            n.position.x, n.position.y, n.spawners or 0, n.spawners == 1 and '' or 's')
        end
      end
    end
    return best
  end
  -- An until=alert filter from the condition's fields, checked (nil without any).
  function M.filter(m, p)
    local f = {}
    if m.min_size ~= nil then
      assert(type(m.min_size) == 'number' and m.min_size >= 1 and m.min_size == math.floor(m.min_size), 'alert min_size is a whole number of enemies, 1 or more')
      f.min_size = m.min_size
    end
    local function xy(v, name)
      assert(type(v) == 'table' and type(v.x or v[1]) == 'number' and type(v.y or v[2]) == 'number', 'alert ' .. name .. ' is {x,y}')
      return {x=v.x or v[1], y=v.y or v[2]}
    end
    if m.area ~= nil then
      assert(type(m.area) == 'table' and m.area.left_top and m.area.right_bottom, 'alert area is {left_top:{x,y}, right_bottom:{x,y}}')
      local a, b = xy(m.area.left_top, 'area.left_top'), xy(m.area.right_bottom, 'area.right_bottom')
      f.area = {left_top={x=math.min(a.x, b.x), y=math.min(a.y, b.y)}, right_bottom={x=math.max(a.x, b.x), y=math.max(a.y, b.y)}}
    elseif m.near ~= nil or m.position ~= nil then
      local c = xy(m.near or m.position, 'near')
      local r = m.radius == nil and 100 or m.radius
      assert(type(r) == 'number' and r > 0 and r <= 2000, 'alert radius is 1..2000 tiles')
      f.area = {left_top={x=c.x - r, y=c.y - r}, right_bottom={x=c.x + r, y=c.y + r}}
    else
      assert(m.radius == nil, 'alert radius goes with near={x,y}')
    end
    if m.surface ~= nil then
      assert(type(m.surface) == 'string', 'alert surface is a surface name')
      f.surface = m.surface
    elseif f.area then
      f.surface = try(function() return p.surface.name end)
    end
    return next(f) and f or nil
  end
  -- The filter in words (the sleep's condition line).
  function M.filter_text(f)
    local parts = {}
    if f.area then parts[#parts+1] = string.format('in (%g,%g)-(%g,%g)%s', f.area.left_top.x, f.area.left_top.y, f.area.right_bottom.x, f.area.right_bottom.y,
      f.surface and ' on ' .. f.surface or '') end
    if f.min_size then parts[#parts+1] = 'min_size ' .. f.min_size end
    return table.concat(parts, ' ')
  end
  return M
end
