-- Why a platform's tile ghosts stay unbuilt (tilecheck.lua), by the game's
-- foundation rules (wiki: Space platform): the foundation is one connected
-- area, holes of empty space surrounded by foundation are not allowed, and a
-- tile breaking either rule is not built. A ghost whose tile would close off
-- empty space that no ghost covers stays a ghost. Also: no foundation or ghost
-- beside it, more than 200 tiles north of the hub, or in the 82 tiles south
-- of a thruster. Run when asked (platforms, inspect), bounded:
-- at most 64 ghosts, and empty regions followed up to 512 tiles (larger ones
-- count as open space).
return function()
  local M = {}
  local LIMIT, GHOSTS = 512, 64
  local DIRS = {{1,0},{-1,0},{0,1},{0,-1}}
  local function key(x, y) return x .. ',' .. y end
  local function is_empty(s, x, y, cache)
    local k = key(x, y)
    local v = cache[k]
    if v == nil then
      local ok, name = pcall(function() return s.get_tile(x, y).name end)
      v = not ok or name == 'empty-space' or name == 'out-of-map'
      cache[k] = v
    end
    return v
  end
  -- The empty tiles reachable from (x,y) with (bx,by) filled: the list when
  -- enclosed, nil when it reaches open space (more than LIMIT tiles).
  local function enclosed(s, x, y, bx, by, cache)
    local seen, queue = {[key(x, y)]=true}, {{x, y}}
    local i = 1
    while queue[i] do
      if #queue > LIMIT then return nil end
      local c = queue[i]; i = i + 1
      for _, d in ipairs(DIRS) do
        local nx, ny = c[1] + d[1], c[2] + d[2]
        local k = key(nx, ny)
        if not seen[k] and not (nx == bx and ny == by) and is_empty(s, nx, ny, cache) then
          seen[k] = true; queue[#queue+1] = {nx, ny}
        end
      end
    end
    return queue
  end
  local function at(x, y) return string.format('(%g,%g)', x + 0.5, y + 0.5) end
  -- A ghost's quality name (normal when unreadable).
  function M.quality_of(g)
    local ok, q = pcall(function() return g.quality end)
    q = ok and q
    if type(q) == 'table' or type(q) == 'userdata' then q = q.name end
    return type(q) == 'string' and q or 'normal'
  end
  -- Lines naming each stalled tile ghost and its cause; nil when none.
  function M.stalled(pl)
    local s, hub = pl.surface, pl.hub
    local ok, ghosts = pcall(function() return s.find_entities_filtered{type='tile-ghost', limit=GHOSTS} end)
    if not ok or #ghosts == 0 then return nil end
    local okt, thrusters = pcall(function() return s.find_entities_filtered{type='thruster', limit=64} end)
    if not okt then thrusters = {} end
    local cache, ghosted = {}, {}
    for _, g in ipairs(ghosts) do ghosted[key(math.floor(g.position.x), math.floor(g.position.y))] = true end
    local out = {}
    for _, g in ipairs(ghosts) do
      local x, y = math.floor(g.position.x), math.floor(g.position.y)
      local name = g.ghost_name
      local reason
      if is_empty(s, x, y, cache) then
        local beside = false
        for _, d in ipairs(DIRS) do
          local nx, ny = x + d[1], y + d[2]
          if not is_empty(s, nx, ny, cache) or ghosted[key(nx, ny)] then beside = true end
        end
        if not beside then reason = 'no foundation or tile ghost beside it (the foundation must stay one connected area)' end
        if not reason and hub and hub.valid and y + 0.5 < hub.position.y - 200 then reason = 'more than 200 tiles north of the hub' end
        if not reason then
          for _, t in ipairs(thrusters) do
            local b = t.bounding_box
            if x + 0.5 > b.left_top.x and x + 0.5 < b.right_bottom.x and y + 0.5 > b.right_bottom.y and y + 0.5 < b.right_bottom.y + 82 then
              reason = string.format('in the 82 tiles south of the thruster at (%g,%g), where no foundation is built', t.position.x, t.position.y)
              break
            end
          end
        end
        if not reason then
          -- Each empty neighbour: would filling this tile enclose it?
          local hole, done = {}, {}
          for _, d in ipairs(DIRS) do
            local nx, ny = x + d[1], y + d[2]
            if not done[key(nx, ny)] and is_empty(s, nx, ny, cache) then
              local region = enclosed(s, nx, ny, x, y, cache)
              for _, c in ipairs(region or {}) do
                done[key(c[1], c[2])] = true
                if not ghosted[key(c[1], c[2])] then hole[#hole+1] = c end
              end
            end
          end
          if #hole > 0 then
            local parts = {}
            for i = 1, math.min(4, #hole) do parts[i] = at(hole[i][1], hole[i][2]) end
            reason = string.format('building it would enclose %d empty tile%s with no ghost: %s%s (the game builds no foundation that leaves a hole of empty space; those tiles need foundation ghosts too, or this ghost stays unbuilt)',
              #hole, #hole == 1 and '' or 's', table.concat(parts, ', '), #hole > 4 and ', ...' or '')
          end
        end
      end
      if reason then out[#out+1] = string.format('tile ghost %s %s: %s', at(x, y), tostring(name), reason) end
    end
    return #out > 0 and out or nil
  end
  return M
end
