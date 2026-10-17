-- move_to {stay_in_turret_coverage: true} (d17 batch12 A3, Opus: 7 deaths in two shifts on routes called safe): a route
-- kept inside our turrets' reach. Our turrets near the way (an ammo turret holding ammo, an electric turret with energy,
-- a fluid turret holding fluid) cover the cells (CELL tiles a side) whose centre lies within their attack range less
-- MARGIN; the walk goes from cell to covered cell (8 ways, a diagonal only past two covered sides), the shortest way, and
-- is walked as via points where the line between them leaves covered cells. The start and the goal must be covered; no
-- covered way between them: refused, naming where coverage from the start ends nearest the goal. Each leg is the
-- engine's path between two points in coverage (round buildings it may stray a few tiles). Bounded: 2000 turrets,
-- 90000 cells (a larger box takes 8-tile cells), 15 via points.
return function(api)
  local M = {}
  M.CELL, M.MARGIN, M.PAD, M.MAX_TURRETS, M.MAX_CELLS, M.MAX_VIA = 4, 2, 48, 2000, 90000, 15
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function at(q) return string.format('(%g,%g)', math.floor(q.x + 0.5), math.floor(q.y + 0.5)) end
  local function dist(a, b) return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2) end
  -- A turret that would shoot now: ammo held, energy, or fluid.
  local function armed(t)
    if t.type == 'ammo-turret' then
      local inv = try(function() return t.get_inventory(defines.inventory.turret_ammo) end)
      return inv ~= nil and not try(function() return inv.is_empty() end)
    elseif t.type == 'electric-turret' then
      return (try(function() return t.energy end) or 0) > 0
    end
    local fb = try(function() return t.fluidbox[1] end)
    return fb ~= nil and (fb.amount or 0) > 0
  end
  function M.route(p, from, goal)
    local s = p.surface
    local x0, y0 = math.min(from.x, goal.x) - M.PAD, math.min(from.y, goal.y) - M.PAD
    local x1, y1 = math.max(from.x, goal.x) + M.PAD, math.max(from.y, goal.y) + M.PAD
    local cell = M.CELL
    if ((x1 - x0) / cell) * ((y1 - y0) / cell) > M.MAX_CELLS then cell = 8 end
    assert(((x1 - x0) / cell) * ((y1 - y0) / cell) <= M.MAX_CELLS, 'stay_in_turret_coverage: the way is too long to plan in one call (at most about 2000 tiles a side); walk it in parts')
    local W, H = math.ceil((x1 - x0) / cell), math.ceil((y1 - y0) / cell)
    local function cx(x) return math.floor((x - x0) / cell) end
    local function cy(y) return math.floor((y - y0) / cell) end
    local function centre(i, j) return {x=x0 + (i + 0.5) * cell, y=y0 + (j + 0.5) * cell} end
    local found = s.find_entities_filtered{area={{x0 - 48, y0 - 48}, {x1 + 48, y1 + 48}}, type={'ammo-turret', 'electric-turret', 'fluid-turret'}, force=p.force, limit=M.MAX_TURRETS}
    local cov, turrets, unarmed = {}, 0, 0
    for _, t in ipairs(found) do
      local r = (try(function() return t.prototype.attack_parameters.range end) or 0) - M.MARGIN
      if r > 0 and armed(t) then
        turrets = turrets + 1
        local q = t.position
        for i = math.max(0, cx(q.x - r)), math.min(W - 1, cx(q.x + r)) do
          for j = math.max(0, cy(q.y - r)), math.min(H - 1, cy(q.y + r)) do
            local c = centre(i, j)
            if (c.x - q.x) ^ 2 + (c.y - q.y) ^ 2 <= r * r then cov[j * W + i] = true end
          end
        end
      elseif r > 0 then unarmed = unarmed + 1 end
    end
    local function covered(x, y)
      local i, j = cx(x), cy(y)
      return i >= 0 and j >= 0 and i < W and j < H and cov[j * W + i] == true
    end
    local counted = string.format('%d of our turrets that would shoot now near the way (%d more hold no ammo, energy or fluid)', turrets, unarmed)
    local si, sj, gi, gj = cx(from.x), cy(from.y), cx(goal.x), cy(goal.y)
    local function nearest_covered(q)
      local best, bd
      for k in pairs(cov) do
        local c = centre(k % W, math.floor(k / W))
        local d = dist(c, q)
        if not bd or d < bd then best, bd = c, d end
      end
      return best, bd
    end
    if not covered(from.x, from.y) then
      local c, d = nearest_covered(from)
      error(string.format('stay_in_turret_coverage: you %s are not inside our turrets\' reach (%s); the nearest covered spot: %s', at(from), counted,
        c and string.format('%s, %.0f tiles away', at(c), d) or 'none near the way'), 0)
    end
    if not covered(goal.x, goal.y) then
      local c, d = nearest_covered(goal)
      error(string.format('stay_in_turret_coverage: the goal %s is not inside our turrets\' reach (%s); the covered spot nearest it: %s', at(goal), counted,
        c and string.format('%s, %.0f tiles from it', at(c), d) or 'none near the way'), 0)
    end
    -- Breadth-first over covered cells, 8 ways (a diagonal past two covered sides), then the line walked straight
    -- where it stays in covered cells.
    local start, target = sj * W + si, gj * W + gi
    local prev, queue, head = {[start]=start}, {start}, 1
    local dirs = {{1, 0}, {-1, 0}, {0, 1}, {0, -1}, {1, 1}, {1, -1}, {-1, 1}, {-1, -1}}
    while head <= #queue and not prev[target] do
      local k = queue[head]; head = head + 1
      local i, j = k % W, math.floor(k / W)
      for _, d in ipairs(dirs) do
        local ni, nj = i + d[1], j + d[2]
        local nk = nj * W + ni
        if ni >= 0 and nj >= 0 and ni < W and nj < H and cov[nk] and not prev[nk]
          and (d[1] == 0 or d[2] == 0 or (cov[j * W + ni] and cov[nj * W + i])) then
          prev[nk] = k; queue[#queue+1] = nk
        end
      end
    end
    if not prev[target] then
      local best, bd
      for k in pairs(prev) do
        local c = centre(k % W, math.floor(k / W))
        local d = dist(c, goal)
        if not bd or d < bd then best, bd = c, d end
      end
      error(string.format('stay_in_turret_coverage: no way inside our turrets\' reach from you %s to %s (%s): the coverage you are in ends nearest the goal at %s, %.0f tiles short of it; the goal lies in another covered area',
        at(from), at(goal), counted, at(best), bd), 0)
    end
    local cells = {}
    local k = target
    while k ~= start do table.insert(cells, 1, k); k = prev[k] end
    local pts = {{x=from.x, y=from.y}}
    for _, c in ipairs(cells) do pts[#pts+1] = centre(c % W, math.floor(c / W)) end
    pts[#pts] = {x=goal.x, y=goal.y}
    local function clear(a, b)
      local n = math.max(1, math.ceil(dist(a, b) / 1))
      for t = 0, n do
        if not covered(a.x + (b.x - a.x) * t / n, a.y + (b.y - a.y) * t / n) then return false end
      end
      return true
    end
    local via, i = {}, 1
    while i < #pts do
      local j = #pts
      while j > i + 1 and not clear(pts[i], pts[j]) do j = j - 1 end
      if j < #pts then via[#via+1] = {x=math.floor(pts[j].x * 2 + 0.5) / 2, y=math.floor(pts[j].y * 2 + 0.5) / 2} end
      i = j
    end
    assert(#via <= M.MAX_VIA, string.format('stay_in_turret_coverage: the covered way turns %d times (at most %d via points); walk it in parts', #via, M.MAX_VIA))
    local length, prevq = 0, from
    for _, q in ipairs(via) do length = length + dist(prevq, q); prevq = q end
    length = length + dist(prevq, goal)
    local words = {}
    for n, q in ipairs(via) do words[n] = at(q) end
    return via, string.format('inside our turrets\' reach (attack range - %d, %d-tile cells; %s): %s%d tiles', M.MARGIN, cell, counted,
      #via > 0 and 'via ' .. table.concat(words, ', ') .. ', ' or 'straight, ', math.floor(length + 0.5))
  end
  return M
end
