-- Where a train's way to its stop is broken (d17 batch12 B1, Opus: a train sat no_path and he walked the line to find
-- the gap): the rails followed from the train as it can drive (its front, and its back when a locomotive faces back),
-- rail by rail through every left, straight and right connection, as the rails on the map show them.
-- - The rails reach the stop's rail in the stop's direction: the rails are whole; when the engine's own path search
--   finds no path all the same, the signals on that way are named (a signal on one side of the line only lets trains
--   through in its direction).
-- - They reach it only facing the other way: the stop is on the far side for this train (no loop to turn round, or its
--   locomotives all face one way).
-- - They never reach it: the rails followed from the stop backward are read too, and the two ends nearest each other
--   are named, the gap between them, and the rail ghosts in it.
-- Read only; bounded: MAX rail ends a side.
return function(api)
  local M = {}
  M.MAX = 30000
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function at(q) return string.format('(%g,%g)', math.floor(q.x * 2 + 0.5) / 2, math.floor(q.y * 2 + 0.5) / 2) end
  local function dist(a, b) return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2) end
  local CONN
  local function conns()
    CONN = CONN or {defines.rail_connection_direction.left, defines.rail_connection_direction.straight, defines.rail_connection_direction.right}
    return CONN
  end
  local function key(e) return e.rail.unit_number .. ':' .. e.direction end
  -- Every rail end reachable from the given ends driving forward: {seen, ends (dead ends), list, parent, hit}.
  -- goal(e) true stops the search at e.
  local function search(starts, goal)
    local seen, parent, queue, dead, head = {}, {}, {}, {}, 1
    for _, e in ipairs(starts) do
      local k = key(e)
      if not seen[k] then seen[k] = e; queue[#queue+1] = e end
      if goal and goal(e) then return {seen=seen, parent=parent, hit=e, dead=dead, n=1} end
    end
    local n = 0
    while head <= #queue and n < M.MAX do
      local e = queue[head]; head = head + 1; n = n + 1
      local moved = false
      for _, c in ipairs(conns()) do
        local x = e.make_copy()
        if try(function() return x.move_forward(c) end) then
          moved = true
          local k = key(x)
          if not seen[k] then
            seen[k] = x; parent[k] = e; queue[#queue+1] = x
            if goal and goal(x) then return {seen=seen, parent=parent, hit=x, dead=dead, n=n} end
          end
        end
      end
      if not moved then dead[#dead+1] = e end
    end
    return {seen=seen, parent=parent, dead=dead, n=n, capped=n >= M.MAX}
  end
  local function flipped(e)
    local x = e.make_copy()
    x.flip_direction()
    return x
  end
  local DIR = {[0]='north', [2]='north-northeast', [4]='northeast', [6]='east-northeast', [8]='east', [10]='east-southeast', [12]='southeast',
    [14]='south-southeast'}
  local function end_text(e)
    local loc = e.location
    local d = loc and loc.direction
    local names = {[0]='north', [4]='east', [8]='south', [12]='west', [2]='north-northeast', [6]='east-southeast', [10]='south-southwest', [14]='west-northwest',
      [1]='north', [3]='east', [5]='east', [7]='south', [9]='south', [11]='west', [13]='west', [15]='north'}
    return string.format('%s %s, its end at %s facing %s', e.rail.name, at(e.rail.position), at(loc.position), names[d] or tostring(d))
  end
  -- train: a LuaTrain; stops: the train stops of the name it heads for. Returns {line, lines, ...}.
  function M.find(train, stops)
    local starts = {}
    local fe = try(function() return train.front_end end)
    if fe then starts[#starts+1] = fe end
    local backs = try(function() return #(train.locomotives.back_movers or {}) end) or 0
    local be = backs > 0 and try(function() return train.back_end end)
    if be then starts[#starts+1] = be end
    if #starts == 0 then return {line='the train stands on no rail end that can be read'} end
    local goals, wrong = {}, {}
    for _, st in ipairs(stops) do
      local r = try(function() return st.connected_rail end)
      local d = try(function() return st.connected_rail_direction end)
      if r and d then goals[r.unit_number .. ':' .. d] = st; wrong[r.unit_number] = st end
    end
    if not next(goals) then return {line='no stop of that name has a rail beside it on the side it serves (build a straight rail beside it)'} end
    local function is_goal(e) return goals[key(e)] ~= nil end
    local fwd = search(starts, is_goal)
    if fwd.hit then
      local st = goals[key(fwd.hit)]
      -- the rails along the way, for the signals on it
      local rails, k = {}, key(fwd.hit)
      while k do
        local e = fwd.seen[k]
        rails[#rails+1] = e.rail
        local pe = fwd.parent[k]
        k = pe and key(pe) or nil
      end
      local engine = try(function()
        return game.train_manager.request_train_path{train=train, goals={st}, type='path'}
      end)
      local found = engine and engine.found_path
      local out = {reaches=true, stop=st.backer_name, rails=#rails}
      if found then
        out.line = string.format('the rails are whole: %d rails from the train to %s %s, and the engine finds a path (%d tiles)',
          #rails, st.backer_name, at(st.position), math.floor((engine.total_length or 0) + 0.5))
        return out
      end
      local sigs, seenSig = {}, {}
      for _, r in ipairs(rails) do
        for _, s in ipairs(try(function() return r.surface.find_entities_filtered{position=r.position, radius=3, type={'rail-signal', 'rail-chain-signal'}} end) or {}) do
          if not seenSig[s.unit_number] and #sigs < 6 then seenSig[s.unit_number] = true; sigs[#sigs+1] = s.name .. ' ' .. at(s.position) end
        end
      end
      out.line = string.format('the rails reach %s %s (%d rails), but the engine finds no path along them: %s', st.backer_name, at(st.position), #rails,
        #sigs > 0 and ('signals on that way (a signal on one side of the line only lets trains through in its direction): ' .. table.concat(sigs, ', ')) or 'no signal on that way')
      out.signals = #sigs > 0 and sigs or nil
      return out
    end
    -- Reaching the stop's rail only facing the other way.
    for k, e in pairs(fwd.seen) do
      local st = wrong[e.rail.unit_number]
      if st then
        return {reaches=false, stop=st.backer_name, line=string.format('the rails from the train reach the rail beside %s %s, but driving the other way from the one it serves: %s',
          st.backer_name, at(st.position), backs == 0 and 'its locomotives all face its front and there is no loop to turn round on the way' or 'no loop to turn round on the way')}
      end
    end
    -- Never reaching it: the rails into each stop, followed backward from it, and the two ends nearest each other.
    local stop_starts = {}
    for gk, st in pairs(goals) do
      local r = st.connected_rail
      local e = try(function() return r.get_rail_end(st.connected_rail_direction) end)
      if e then stop_starts[#stop_starts+1] = flipped(e) end
    end
    local back = search(stop_starts, nil)
    local best
    for _, a in ipairs(fwd.dead) do
      local pa = a.location.position
      for _, b in ipairs(back.dead) do
        local pb = b.location.position
        local d = dist(pa, pb)
        if not best or d < best.d then best = {a=a, b=b, d=d} end
      end
    end
    local out = {reaches=false}
    if not best then
      out.line = string.format('the rails from the train never reach a stop of that name (%d rail ends followed%s) and no end of them was found%s',
        fwd.n, fwd.capped and ', the most read' or '', #fwd.dead == 0 and ': the line loops without one' or '')
      return out
    end
    local pa, pb = best.a.location.position, best.b.location.position
    local box = {{math.min(pa.x, pb.x) - 4, math.min(pa.y, pb.y) - 4}, {math.max(pa.x, pb.x) + 4, math.max(pa.y, pb.y) + 4}}
    local s = best.a.rail.surface
    local ghosts = try(function() return s.find_entities_filtered{area=box, type='entity-ghost', ghost_type={'straight-rail', 'curved-rail-a', 'curved-rail-b', 'half-diagonal-rail'}} end) or {}
    local gl = {}
    for i, g in ipairs(ghosts) do if i <= 4 then gl[i] = g.ghost_name .. ' ' .. at(g.position) end end
    out.train_side = end_text(best.a)
    out.stop_side = end_text(best.b)
    out.gap_tiles = math.floor(best.d + 0.5)
    out.ghosts = #gl > 0 and gl or nil
    out.line = string.format('the line is broken: the rails from the train end at %s; the rails into the stop end at %s; %d tiles between them%s',
      out.train_side, out.stop_side, out.gap_tiles,
      #ghosts > 0 and string.format('; %d rail ghost%s there to be built: %s', #ghosts, #ghosts == 1 and ' waits' or 's wait', table.concat(gl, ', ')) or '; no rail ghost there')
    return out
  end
  return M
end
