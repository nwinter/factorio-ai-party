-- move_to {stay_in_turret_coverage: true} (d17 batch12 A3, Opus: 7 deaths in two shifts on routes called safe): a route
-- kept inside our turrets' reach. Our turrets near the way (an ammo turret holding ammo, an electric turret with energy,
-- a fluid turret holding fluid) cover the cells (CELL tiles a side) whose centre lies within their attack range less
-- MARGIN; the walk goes from cell to covered cell (8 ways, a diagonal only past two covered sides), the shortest way, and
-- is walked as via points where the line between them leaves covered cells. A start or goal outside coverage is walked
-- to or from the nearest covered cell, at most max_uncovered tiles (said); no covered way between them: refused, naming
-- where coverage is missing (the nearest points of the two covered areas). Each leg is the
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
  -- One plan over the box round from and goal grown by pad; ok, via, line or nil, refusal text.
  local function plan(p, from, goal, pad, max_uncovered)
    local s = p.surface
    local x0, y0 = math.min(from.x, goal.x) - pad, math.min(from.y, goal.y) - pad
    local x1, y1 = math.max(from.x, goal.x) + pad, math.max(from.y, goal.y) + pad
    local cell = M.CELL
    if ((x1 - x0) / cell) * ((y1 - y0) / cell) > M.MAX_CELLS then cell = 8 end
    if ((x1 - x0) / cell) * ((y1 - y0) / cell) > M.MAX_CELLS then
      return nil, 'stay_in_turret_coverage: the way is too long to plan in one call (at most about 2000 tiles a side); walk it in parts'
    end
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
    local function nearest_covered(q)
      local best, bd
      for k in pairs(cov) do
        local c = centre(k % W, math.floor(k / W))
        local d = dist(c, q)
        if not bd or d < bd then best, bd = k, d end
      end
      return best, bd
    end
    -- The ends: in coverage, or a stretch of at most max_uncovered tiles to the nearest covered cell (d17 batch13 C2,
    -- Opus: three calls refused for a start or goal a few tiles outside the turrets' reach, the base's middle among them).
    local start, entry_d, target, exit_d
    if covered(from.x, from.y) then start = cy(from.y) * W + cx(from.x)
    else
      start, entry_d = nearest_covered(from)
      if not start or entry_d > max_uncovered then
        return nil, string.format('stay_in_turret_coverage: you %s are %s outside our turrets\' reach (%s; at most %d uncovered tiles at each end: max_uncovered)', at(from),
          start and string.format('%.0f tiles', entry_d) or 'far', counted, max_uncovered)
      end
    end
    if covered(goal.x, goal.y) then target = cy(goal.y) * W + cx(goal.x)
    else
      target, exit_d = nearest_covered(goal)
      if not target or exit_d > max_uncovered then
        return nil, string.format('stay_in_turret_coverage: the goal %s is %s outside our turrets\' reach (%s; at most %d uncovered tiles at each end: max_uncovered)%s', at(goal),
          target and string.format('%.0f tiles', exit_d) or 'far', counted, max_uncovered, target and string.format('; the covered spot nearest it: %s', at(centre(target % W, math.floor(target / W)))) or '')
      end
    end
    -- Breadth-first over covered cells, 8 ways (a diagonal past two covered sides).
    local dirs = {{1, 0}, {-1, 0}, {0, 1}, {0, -1}, {1, 1}, {1, -1}, {-1, 1}, {-1, -1}}
    local function flood(from_k, stop_k)
      local prev, queue, head = {[from_k]=from_k}, {from_k}, 1
      while head <= #queue and not (stop_k and prev[stop_k]) do
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
      return prev
    end
    local prev = flood(start, target)
    if not prev[target] then
      -- where coverage is missing: the nearest cells of the start's covered area and the goal's
      local other = flood(target, nil)
      local a, b, bd
      local A, B = {}, {}
      for k in pairs(prev) do A[#A+1] = k end
      for k in pairs(other) do B[#B+1] = k end
      local stepA, stepB = math.max(1, math.floor(#A / 600)), math.max(1, math.floor(#B / 600))
      for ia = 1, #A, stepA do
        local ca = centre(A[ia] % W, math.floor(A[ia] / W))
        for ib = 1, #B, stepB do
          local cb = centre(B[ib] % W, math.floor(B[ib] / W))
          local d = dist(ca, cb)
          if not bd or d < bd then a, b, bd = ca, cb, d end
        end
      end
      return false, string.format('stay_in_turret_coverage: no way inside our turrets\' reach from you %s to %s (%s): coverage is missing between %s and %s, %.0f tiles apart (the covered area you are in and the one the goal is in)',
        at(from), at(goal), counted, at(a), at(b), bd)
    end
    local cells = {}
    local k = target
    while k ~= start do table.insert(cells, 1, k); k = prev[k] end
    local pts = {{x=from.x, y=from.y}}
    if entry_d then pts[#pts+1] = centre(start % W, math.floor(start / W)) end
    for _, c in ipairs(cells) do pts[#pts+1] = centre(c % W, math.floor(c / W)) end
    if exit_d then pts[#pts+1] = centre(target % W, math.floor(target / W)) end
    pts[#pts+1] = {x=goal.x, y=goal.y}
    local function clear(a, b)
      local n = math.max(1, math.ceil(dist(a, b) / 1))
      for t = 0, n do
        if not covered(a.x + (b.x - a.x) * t / n, a.y + (b.y - a.y) * t / n) then return false end
      end
      return true
    end
    -- keep the uncovered ends as their own legs: the entry and exit points stay
    local fixed = {}
    if entry_d then fixed[2] = true end
    if exit_d then fixed[#pts - 1] = true end
    local via, i = {}, 1
    while i < #pts do
      local j = #pts
      while j > i + 1 and (not clear(pts[i], pts[j]) or (function() for f in pairs(fixed) do if f > i and f < j then return true end end end)()) do j = j - 1 end
      if j < #pts then via[#via+1] = {x=math.floor(pts[j].x * 2 + 0.5) / 2, y=math.floor(pts[j].y * 2 + 0.5) / 2} end
      i = j
    end
    if #via > M.MAX_VIA then return nil, string.format('stay_in_turret_coverage: the covered way turns %d times (at most %d via points); walk it in parts', #via, M.MAX_VIA) end
    local length, prevq = 0, from
    for _, q in ipairs(via) do length = length + dist(prevq, q); prevq = q end
    length = length + dist(prevq, goal)
    local words = {}
    for n, q in ipairs(via) do words[n] = at(q) end
    local ends = {}
    if entry_d then ends[#ends+1] = string.format('the first %.0f tiles, to %s, are outside it', entry_d, at(via[1])) end
    if exit_d then ends[#ends+1] = string.format('the last %.0f tiles, from %s, are outside it', exit_d, at(via[#via])) end
    return true, via, string.format('inside our turrets\' reach (attack range - %d, %d-tile cells; %s): %s%d tiles%s', M.MARGIN, cell, counted,
      #via > 0 and 'via ' .. table.concat(words, ', ') .. ', ' or 'straight, ', math.floor(length + 0.5), #ends > 0 and '; ' .. table.concat(ends, '; ') or '')
  end
  -- The box round from and goal, PAD tiles wide, then WIDE when no covered way joins them inside it.
  M.WIDE, M.MAX_UNCOVERED = 160, 48
  function M.route(p, from, goal, max_uncovered)
    max_uncovered = max_uncovered or M.MAX_UNCOVERED
    local ok, via, line = plan(p, from, goal, M.PAD, max_uncovered)
    if ok == false then
      local ok2, via2, line2 = plan(p, from, goal, M.WIDE, max_uncovered)
      if ok2 then return via2, line2 end
      if ok2 == false then via = via2 end
    end
    if ok then return via, line end
    error(via, 0)
  end
  return M
end
