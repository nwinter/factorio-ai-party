-- clearobs: build and place_ghosts {clear_obstacles: true} (d18 batch36 C1, Opus, 3 times placing small cells: each tree
-- in a footprint stopped the batch). The trees and rocks in the entries' footprints are marked for deconstruction, as a
-- player's planner marks them; those in reach are mined by hand (a timed construct over them, as move_to's mine_out
-- does), the rest go to the construction robots; once every one is gone the call runs again, without clear_obstacles.
-- A watch per agent, WAIT ticks at most. With none in the way the call runs at once.
-- (d25 batch207 QT3, Sol #2351: plan 768's build steps with wait: true and clear_obstacles were marked ok at then_runs,
-- the next step ran while the clearing was pending, and the plan ended done with 4 of 132 entities built) the job and
-- its run again are the step's own: a queue step waits while they are pending (runtime busy: M.pending), and fails
-- when the job ends without the call run again (M.ended: timed out, refused, or another action running then). The run
-- again never interrupts another action: with one running (not the job's own hand mining) the call is not run.
return function(api)
  local M = {}
  M.WAIT, M.MAX = 10 * 3600, 64
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function at(q) return string.format('(%g,%g)', q.x, q.y) end
  local function rock(e)
    if e.type == 'tree' then return true end
    return e.type == 'simple-entity' and try(function() return e.prototype.count_as_rock_for_filtered_deconstruction end) == true
  end
  -- The footprints of the call's entries: {proto, pos, dir} each (tile entries and unknown names left out).
  local function footprints(action, a)
    local out = {}
    local list = action == 'build' and (type(a.builds) == 'table' and a.builds or {a}) or (type(a.entities) == 'table' and a.entities or {})
    for _, e in ipairs(list) do
      if type(e) == 'table' and e.position then
        local proto
        if action == 'build' then
          local item = prototypes.item[e.item or e.name or a.item or '']
          proto = item and item.place_result
        else
          proto = prototypes.entity[e.name or '']
        end
        if proto then
          local dir = api.direction_of and try(function() return api.direction_of(e.direction or a.direction or 0) end) or 0
          local pos = api.position(e.position)
          out[#out+1] = {proto=proto, pos=api.snap(proto, pos, dir), dir=dir}
        end
      end
    end
    return out
  end
  -- The trees and rocks standing in them, each once.
  function M.obstacles(surface, action, a)
    local seen, out = {}, {}
    for _, f in ipairs(footprints(action, a)) do
      local box = api.footprint(f.proto, f.pos, f.dir)
      for _, e in ipairs(try(function() return surface.find_entities_filtered{area=box, type={'tree', 'simple-entity'}} end) or {}) do
        if e.valid and rock(e) and not seen[e] and #out < M.MAX then seen[e] = true; out[#out+1] = e end
      end
    end
    return out
  end
  local function names(list)
    local by, order = {}, {}
    for _, e in ipairs(list) do
      if not by[e.name] then by[e.name] = {n=0, first=e.position}; order[#order+1] = e.name end
      by[e.name].n = by[e.name].n + 1
    end
    local parts = {}
    for i, n in ipairs(order) do if i <= 6 then parts[#parts+1] = string.format('%d %s (one at %s)', by[n].n, n, at(by[n].first)) end end
    return table.concat(parts, ', ') .. (#order > 6 and ', ...' or '')
  end
  -- The call with clear_obstacles: run plain when nothing stands in the way; else mark, mine what is in reach, watch.
  function M.call(p, action, a, plain)
    assert(a.clear_obstacles == true, 'clear_obstacles is true')
    local args = {}
    for k, v in pairs(a) do if k ~= 'clear_obstacles' then args[k] = v end end
    local surface = (a.surface and game.surfaces[a.surface]) or p.surface
    local obs = (a.platform == nil) and M.obstacles(surface, action, args) or {}
    if #obs == 0 then
      local out = plain(p, args)
      if type(out) == 'table' then out.cleared = 'no tree or rock in the footprints' end
      return out
    end
    local near, far = {}, {}
    for _, e in ipairs(obs) do
      pcall(function() e.order_deconstruction(p.force) end)
      local reach = p.character and surface == p.surface and try(function() return p.can_reach_entity(e) end)
      if reach then near[#near+1] = e else far[#far+1] = e end
    end
    local st = api.state()
    st.clear_jobs = st.clear_jobs or {}
    st.clear_jobs[p.index] = {action=action, args=args, ents=obs, until_tick=game.tick + M.WAIT, started=game.tick}
    local out = {cleared=string.format('%d in the footprints marked for deconstruction: %s', #obs, names(obs))}
    if #near > 0 then
      local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
      for _, e in ipairs(near) do
        local b = e.bounding_box
        x0, y0, x1, y1 = math.min(x0, b.left_top.x), math.min(y0, b.left_top.y), math.max(x1, b.right_bottom.x), math.max(y1, b.right_bottom.y)
      end
      local ok, err = pcall(api.construct, p, {area={left_top={x=math.floor(x0) - 1, y=math.floor(y0) - 1}, right_bottom={x=math.ceil(x1) + 1, y=math.ceil(y1) + 1}}})
      out.mining = ok and string.format('%d in reach mined by hand now (a timed construct over them)', #near) or ('the hand mining could not start: ' .. tostring(err))
      local act = ok and st.active and st.active[p.index]
      if act then act.clear_job = true end
    end
    if #far > 0 then out.robots = string.format('%d out of reach left to the construction robots', #far) end
    out.then_runs = string.format('%s runs again once all %d are gone (watched up to %d min)', action, #obs, math.floor(M.WAIT / 3600))
    return out
  end
  -- How a job ended for a queue step (M.ended): ok with the call's reply, or not run with why.
  local function ended(st, index, action, ok, text, result)
    st.clear_end = st.clear_end or {}
    st.clear_end[index] = {action=action, tick=game.tick, ok=ok, text=text, result=result}
  end
  -- (QT3) the job, or its run again due, of index for action: a line, else nil.
  function M.pending(index, action)
    local st = api.state()
    local j = st.clear_jobs and st.clear_jobs[index]
    if j and (not action or j.action == action) then
      local left = 0
      for _, e in ipairs(j.ents) do if e.valid then left = left + 1 end end
      return string.format('clear_obstacles: %d of %d trees and rocks in the footprints still stand (marked %ds ago); %s runs again once all are gone (until tick %d)',
        left, #j.ents, math.floor((game.tick - j.started) / 60), j.action, j.until_tick), j
    end
    for _, c in ipairs(st.then_calls or {}) do
      if c.clear and c.index == index and (not action or c.call.action == action) then
        return string.format('clear_obstacles: the trees and rocks are gone; %s runs again this tick', c.call.action), c
      end
    end
  end
  -- (QT3) a queue step interrupted while its job is pending: the job and its run again dropped (the marks stay); a line
  function M.cancel(index, action)
    local st = api.state()
    local line = M.pending(index, action)
    if not line then return nil end
    if st.clear_jobs then st.clear_jobs[index] = nil; if next(st.clear_jobs) == nil then st.clear_jobs = nil end end
    local keep = {}
    for _, c in ipairs(st.then_calls or {}) do if not (c.clear and c.index == index) then keep[#keep+1] = c end end
    st.then_calls = #keep > 0 and keep or nil
    return line
  end
  -- (QT3) how the job of index ended at or after tick since: {action, tick, ok, text, result}, else nil.
  function M.ended(index, since)
    local e = api.state().clear_end
    e = e and e[index]
    if e and e.tick >= (since or 0) then return e end
  end
  -- (QT3) the run again's reply (runtime's then_calls loop)
  function M.ran(index, action, ok, r)
    ended(api.state(), index, action, ok, ok and string.format('%s ran again after the trees and rocks were gone', action) or string.format('%s run again after the trees and rocks were gone was refused: %s', action, tostring(r)), ok and r or nil)
  end
  -- Every second: a job whose obstacles are all gone runs its call (next tick, as then_call); one past WAIT ends.
  function M.tick()
    local st = api.state()
    for index, j in pairs(st.clear_jobs or {}) do
      local left = 0
      for _, e in ipairs(j.ents) do if e.valid then left = left + 1 end end
      local last = st.last and st.last[index]
      local busy = st.active and st.active[index]
      if left == 0 and busy and not busy.clear_job then
        -- (QT3) another action runs now: the call is not run over it
        st.clear_jobs[index] = nil
        local text = string.format('the %d trees and rocks in the footprints are gone; %s not run again: your %s runs (started after the clear)', #j.ents, j.action, tostring(busy.kind))
        if last then last.cleared = text end
        ended(st, index, j.action, false, text)
      elseif left == 0 then
        st.clear_jobs[index] = nil
        st.then_calls = st.then_calls or {}
        st.then_calls[#st.then_calls+1] = {index=index, call={action=j.action, args=j.args}, clear=true, queued=j.queued}
        if last then last.cleared = string.format('the %d trees and rocks in the footprints are gone: %s runs again now', #j.ents, j.action) end
      elseif game.tick > j.until_tick then
        st.clear_jobs[index] = nil
        local text = string.format('%d of %d trees and rocks still stand after %d min: %s not run again', left, #j.ents, math.floor(M.WAIT / 3600), j.action)
        if last then last.cleared = text end
        ended(st, index, j.action, false, text)
      end
    end
    if st.clear_jobs and next(st.clear_jobs) == nil then st.clear_jobs = nil end
  end
  return M
end
