-- trace {position, throughput: true} (B1, Opus 21:20: 14 drills added before learning both trunks were already full):
-- a belt line's supply against its capacity, per lane. From the belt tile: every belt feeding it, walked back (straight
-- inputs, side-loads, undergrounds), and on to the line's end (one splitter output followed). Then the mining drills
-- dropping onto those tiles: what each puts on its lane at full speed (mining speed with its speed bonus, over the
-- resource's mining time, with its productivity), how many are working now; the slowest belt's lane capacity (4 items a
-- tile at its speed); and what the last 10 tiles of the line hold per lane (4 a tile is full). Bounded: 2000 tiles back,
-- 2000 on, 256 drills.
return function(api)
  local M = {}
  local BACK, ON, DRILLS, END = 2000, 2000, 256, 10
  local BELT = {['transport-belt']=true, ['underground-belt']=true, splitter=true}
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function at(q) return string.format('(%g,%g)', q.x, q.y) end
  local function key(e) return e.unit_number end
  local function side(k) return k == 1 and 'left' or 'right' end
  -- The lane of belt b nearest a drop position.
  local function lane_at(b, pos)
    local best, bd
    for k = 1, math.min(2, try(function() return b.get_max_transport_line_index() end) or 0) do
      local line = try(function() return b.get_transport_line(k) end)
      local mid = line and try(function() return line.get_line_item_position(line.line_length / 2) end)
      if mid then
        local d = (mid.x - pos.x) ^ 2 + (mid.y - pos.y) ^ 2
        if not bd or d < bd then best, bd = k, d end
      end
    end
    return best or 1
  end
  function M.read(p, e)
    assert(e and e.valid and BELT[e.type], 'throughput reads a belt line: position on a belt, underground or splitter tile')
    local tiles, order = {}, {}
    local function add(b) if b.valid and not tiles[key(b)] then tiles[key(b)] = b; order[#order+1] = b; return true end end
    add(e)
    -- back: every input, breadth first
    local queue, i = {e}, 1
    while i <= #queue and #order < BACK do
      local b = queue[i]; i = i + 1
      local bn = try(function() return b.belt_neighbours end)
      for _, x in ipairs(bn and bn.inputs or {}) do if BELT[x.type] and add(x) then queue[#queue+1] = x end end
      if b.type == 'underground-belt' and try(function() return b.belt_to_ground_type end) == 'output' then
        local nb = try(function() return b.neighbours end)
        if nb and nb.valid and add(nb) then queue[#queue+1] = nb end
      end
    end
    local back_n = #order
    -- on: the first output each step, to the end
    local cur, last, n = e, e, 0
    while cur and n < ON do
      n = n + 1
      local bn = try(function() return cur.belt_neighbours end)
      local nxt = bn and bn.outputs and bn.outputs[1]
      if not nxt and cur.type == 'underground-belt' and try(function() return cur.belt_to_ground_type end) == 'input' then nxt = try(function() return cur.neighbours end) end
      if not (nxt and nxt.valid) or tiles[key(nxt)] and nxt ~= cur then
        if nxt and nxt.valid and tiles[key(nxt)] then break end
        last = cur; break
      end
      add(nxt); last = nxt; cur = nxt
    end
    -- the slowest belt on the line
    local slow
    for _, b in ipairs(order) do
      local s = try(function() return b.prototype.belt_speed end)
      if s and (not slow or s < slow.s) then slow = {s=s, name=b.name} end
    end
    local lane_cap = slow and slow.s * 60 * 4 * 60 or nil   -- items a minute a lane
    -- drills dropping onto the line: looked for round the tiles walked back (give a tile near the end for all of them)
    local x0, y0, x1, y1
    for j = 1, back_n do
      local b = order[j]
      local q = b.position
      x0, y0 = math.min(x0 or q.x, q.x), math.min(y0 or q.y, q.y)
      x1, y1 = math.max(x1 or q.x, q.x), math.max(y1 or q.y, q.y)
    end
    local per = {{n=0, working=0, rate=0, by={}}, {n=0, working=0, rate=0, by={}}}
    local drills = try(function() return e.surface.find_entities_filtered{area={{x0 - 5, y0 - 5}, {x1 + 5, y1 + 5}}, type='mining-drill', force=e.force, limit=4 * DRILLS} end) or {}
    -- (the tiles on toward the end are not searched: drills sit along the patch, behind the tile given)
    local counted = 0
    for _, d in ipairs(drills) do
      local t = d.valid and try(function() return d.drop_target end)
      if t and t.valid and tiles[key(t)] and counted < DRILLS then
        counted = counted + 1
        local res = try(function() return d.mining_target end)
        local time = res and try(function() return res.prototype.mineable_properties.mining_time end)
        local speed = try(function() return d.prototype.mining_speed end) or 0
        local r = time and time > 0 and speed * (1 + (try(function() return d.speed_bonus end) or 0)) / time * (1 + (try(function() return d.productivity_bonus end) or 0)) * 60 or 0
        local k = lane_at(t, try(function() return d.drop_position end) or t.position)
        local L = per[k]
        L.n = L.n + 1; L.rate = L.rate + r
        if api.status_name and api.status_name(d) == 'working' then L.working = L.working + 1 end
        local what = res and res.name or 'nothing'
        L.by[what] = (L.by[what] or 0) + 1
      end
    end
    -- the end's hold: the last END tiles walked back from the end
    local hold, held_tiles = {0, 0}, 0
    local b = last
    for _ = 1, END do
      if not (b and b.valid) then break end
      held_tiles = held_tiles + 1
      for k = 1, 2 do
        local c = try(function() return #b.get_transport_line(k).get_detailed_contents() end) or 0
        hold[k] = hold[k] + c
      end
      local bn = try(function() return b.belt_neighbours end)
      local prev
      for _, x in ipairs(bn and bn.inputs or {}) do if x.direction == b.direction then prev = x end end
      b = prev or (bn and bn.inputs and #bn.inputs == 1 and bn.inputs[1]) or nil
    end
    local lines = {string.format('%d belt tiles (%d back from %s through every belt feeding it, drills counted along those; the rest on to the end at %s); slowest %s: %s a lane',
      #order, back_n, at(e.position), at(last.position), slow and slow.name or '?', lane_cap and string.format('%d/min', math.floor(lane_cap + 0.5)) or '?')}
    local lanes = {}
    for k = 1, 2 do
      local L = per[k]
      local by = {}
      for name, c in pairs(L.by) do by[#by+1] = c .. ' on ' .. name end
      table.sort(by)
      local share = lane_cap and lane_cap > 0 and math.floor(L.rate / lane_cap * 100 + 0.5) or nil
      lanes[k] = {lane=side(k), drills=L.n, working=L.working, per_min=math.floor(L.rate + 0.5), share=share, end_hold=hold[k], end_tiles=held_tiles}
      lines[#lines+1] = string.format('%s lane: %d drill%s (%d working; %s) put up to %d/min at full speed%s; the last %d tiles hold %d of %d',
        side(k), L.n, L.n == 1 and '' or 's', L.working, #by > 0 and table.concat(by, ', ') or 'none', math.floor(L.rate + 0.5),
        share and string.format(', %d%% of the lane', share) or '', held_tiles, hold[k], held_tiles * 4)
    end
    if #order >= BACK then lines[#lines+1] = string.format('the walk back stopped at %d tiles', BACK) end
    if counted >= DRILLS then lines[#lines+1] = string.format('the first %d drills counted', DRILLS) end
    return {lines=lines, lanes=lanes, tiles=#order, lane_capacity_per_min=lane_cap and math.floor(lane_cap + 0.5) or nil, ['end']=last.position,
      note='drills at full speed with their speed and productivity bonuses; inserters putting onto the line are not counted; the last tiles at 4 items a tile are full (moving at capacity, or backed up)'}
  end
  return M
end
