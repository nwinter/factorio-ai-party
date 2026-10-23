-- The belts a belt reading its entire belt (read_contents_mode entire_belt_hold) counts, as the game counts them (d22
-- batch118 CA2, viewer Aurora site:4407: inspect and circuit_audit gave two rules). Measured on a private 2.0.77 server
-- with readers on one controlled layout: a reader's signal is the sum of every belt of its segment, and every belt of
-- one segment reports the same total_segment_length. A segment runs through corners, underground pairs and belt tier
-- changes, and along the main line past a side-load both ways (the straight input upstream); a belt side-loading onto
-- another is the end of its own segment, and a splitter ends one. A 300-belt straight belt was one segment, read whole.
-- What the read sums is each lane's transport lines of that segment (on Asterion, a copy of world n: 55 on belt lanes,
-- 42 under undergrounds (an entrance's lines 3 and 4; an exit's are one-tile lines of their own) and 2 in the output
-- lines of the splitter it starts from: the wire read 99).
-- inspect (circuits.lua) and circuit_audit (circaudit.lua) both walk it here.
return function()
  local M = {}
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function key(e) return e.unit_number or (e.position.x .. ',' .. e.position.y) end
  M.key = key
  function M.length(b) return try(function() return b.get_transport_line(1).total_segment_length end) end
  local function where(b) return string.format('%s (%g,%g)', b.name, b.position.x, b.position.y) end
  -- The next belt from cur along way ('inputs' upstream, 'outputs' downstream) on the physical belt: the one input, or
  -- the straight one of several (a side-load joins there); the one output; an underground's pair. nil and why not.
  local function step(cur, way)
    local list = try(function() return cur.belt_neighbours[way] end) or {}
    local nxt
    if #list == 1 then nxt = list[1]
    elseif way == 'inputs' then
      for _, x in ipairs(list) do if x.direction ~= nil and x.direction == cur.direction then nxt = x end end
    end
    if not nxt and cur.type == 'underground-belt' then
      local pair = try(function() return cur.neighbours end)
      local t = try(function() return cur.belt_to_ground_type end)
      if pair and pair.valid and ((way == 'inputs' and t == 'output') or (way == 'outputs' and t == 'input')) then nxt = pair end
    end
    if nxt then return nxt end
    if #list > 1 then return nil, string.format('at %s (%d belts %s it, none straight on)', where(cur), #list, way == 'inputs' and 'feed' or 'take from') end
    return nil, string.format('at %s (the belt %s there)', where(cur), way == 'inputs' and 'starts' or 'ends')
  end
  -- From b both ways: {list (the segment's belts in flow order), at (b's index), ends {inputs=, outputs=} (where the
  -- segment ends each way, in words), length (b's total_segment_length), past {inputs=, outputs=} (the belt or
  -- splitter beyond each end, if any)}. physical: the walk goes on along the belt in line past the segment's ends, in
  -- one pass, and phys {list, at, ends} gives it. At most limit belts each way.
  function M.walk(b, limit, physical)
    local mine = M.length(b)
    local seen = {[key(b)]=true}
    local out = {ends={}, past={}, length=mine}
    local sides, cuts, pends = {}, {}, {}
    for _, way in ipairs({'inputs', 'outputs'}) do
      local cur, run, stop, cut = b, {}, nil, nil
      while true do
        if #run >= limit then stop = string.format('past %d belts (not read further)', limit); break end
        local nxt, why = step(cur, way)
        if not nxt then stop = why; break end
        if nxt.type == 'splitter' then stop = string.format('at %s (a splitter)', where(nxt)); if not cut then out.past[way] = nxt end; break end
        if seen[key(nxt)] then stop = 'round a loop'; break end
        if not cut and mine and math.abs((M.length(nxt) or -1) - mine) > 0.001 then
          cut = #run
          out.ends[way] = string.format('at %s; %s %s it is another segment', where(cur), where(nxt), way == 'outputs' and 'past' or 'before')
          out.past[way] = nxt
          if not physical then break end
        end
        seen[key(nxt)] = true
        run[#run+1] = nxt
        cur = nxt
      end
      if not cut then cut = #run; out.ends[way] = stop end
      sides[way], cuts[way], pends[way] = run, cut, stop
    end
    local function list_of(nin, nout)
      local list = {}
      for i = nin, 1, -1 do list[#list+1] = sides.inputs[i] end
      list[#list+1] = b
      local at = #list
      for i = 1, nout do list[#list+1] = sides.outputs[i] end
      return list, at
    end
    out.list, out.at = list_of(cuts.inputs, cuts.outputs)
    if physical then
      local list, at = list_of(#sides.inputs, #sides.outputs)
      out.phys = {list=list, at=at, ends=pends}
    end
    return out
  end
  -- A splitter's lines on the side a belt joins it (measured on two splitters, north- and south-facing: lines 1-2 its
  -- left input, 3-4 its right input, 5-6 its left output, 7-8 its right output, left and right as it faces); into:
  -- the belt feeds it, else it feeds the belt.
  local RIGHT = {[0]={1, 0}, [4]={0, 1}, [8]={-1, 0}, [12]={0, -1}}
  local function splitter_lines(sp, b, into)
    local r = RIGHT[sp.direction] or RIGHT[0]
    local right = (b.position.x - sp.position.x) * r[1] + (b.position.y - sp.position.y) * r[2] > 0
    local first = (into and 1 or 5) + (right and 2 or 0)
    return {[first]=true, [first + 1]=true}
  end
  -- What a walk's segment holds, by item (quality other than normal as name@quality): every transport line of its
  -- belts, and of the splitters at its ends the lines on its side, whose total_segment_length is that of the reader's
  -- lane (odd lines lane 1, even lane 2); without lengths (none read), each belt's lanes and an underground entrance's
  -- buried lines.
  function M.contents(w, b)
    local lane = {}
    for k = 1, 2 do lane[k] = try(function() return b.get_transport_line(k).total_segment_length end) end
    local held = {}
    local function add(e, only)
      local n = try(function() return e.get_max_transport_line_index() end) or 2
      for k = 1, n do
        local l = (not only or only[k]) and try(function() return e.get_transport_line(k) end)
        local mine = lane[2 - k % 2]
        local ok
        if mine then
          local len = l and try(function() return l.total_segment_length end)
          ok = len and math.abs(len - mine) < 0.001
        else
          ok = l and e.type ~= 'splitter' and (k <= 2 or try(function() return e.belt_to_ground_type end) == 'input')
        end
        for _, c in ipairs(ok and try(function() return l.get_contents() end) or {}) do
          local name = type(c.name) == 'string' and c.name or try(function() return c.name.name end)
          local q = c.quality
          if type(q) ~= 'string' then q = q and q.name or 'normal' end
          if name and q ~= 'normal' then name = name .. '@' .. q end
          if name then held[name] = (held[name] or 0) + c.count end
        end
      end
    end
    for _, e in ipairs(w.list) do add(e) end
    -- (a loop through one splitter starts and ends at it: its lines on both sides, once)
    local ends, order = {}, {}
    for _, way in ipairs({'inputs', 'outputs'}) do
      local e = w.past[way]
      if e and e.valid ~= false and e.type == 'splitter' then
        local by = way == 'outputs' and w.list[#w.list] or w.list[1]
        local ok, only = pcall(splitter_lines, e, by, way == 'outputs')
        local k = key(e)
        if not ends[k] then ends[k] = {e=e, only={}}; order[#order+1] = k end
        if ok and ends[k].only then for i in pairs(only) do ends[k].only[i] = true end else ends[k].only = nil end
      end
    end
    for _, k in ipairs(order) do add(ends[k].e, ends[k].only) end
    return held
  end
  return M
end
