-- Robots lost to enemies on their routes (d17 batch21 C2, Opus: about 300 construction robots died to worms in one
-- shift before the jobs sending them were found by hand). What a player sees: robots dying where a worm or nest is, and
-- the ghosts, marks and requests they were flying to. On a robot of ours killed by an enemy (on_entity_died, the robot
-- still there): its first order (the 2.0 robot_order_queue: construct, deconstruct, repair, deliver, pickup, upgrade,
-- ...) and that order's target, with the killer and where. robot_losses {surface?, minutes?} groups them by killer;
-- cancel: true with near (a killer's position) cancels the jobs that sent them, as a player does by hand: a ghost or
-- tile ghost and an item request proxy removed, a deconstruction or upgrade mark cancelled; repairs and deliveries
-- are named (their target and requester), not cancelled. A group is a team alert (robots_lost) while new deaths come.
return function(api)
  local M = {}
  local KEEP, MAX, ALERT = 54000, 512, 18000
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function at(q) return string.format('(%g,%g)', math.floor(q.x * 10 + 0.5) / 10, math.floor(q.y * 10 + 0.5) / 10) end
  local function store() local s = api.state(); s.robot_losses = s.robot_losses or {}; return s.robot_losses end
  local order_names
  local function order_name(t)
    if not order_names then
      order_names = {}
      for k, v in pairs(try(function() return defines.robot_order_type end) or {}) do order_names[v] = k end
    end
    return order_names[t] or tostring(t)
  end
  local function target_view(t)
    if not (t and try(function() return t.valid end)) then return nil end
    local name = t.type == 'entity-ghost' and t.ghost_name .. ' ghost' or t.type == 'tile-ghost' and (try(function() return t.ghost_name end) or '?') .. ' tile ghost'
      or t.type == 'item-request-proxy' and 'item request at ' .. (try(function() return t.proxy_target.name end) or '?') or t.name
    return {name=name, type=t.type, position={x=t.position.x, y=t.position.y}, unit=t.unit_number, ref=t}
  end
  function M.note(event)
    local e, cause = event.entity, event.cause
    if not (e and e.valid and (e.type == 'construction-robot' or e.type == 'logistic-robot')) then return end
    if not (cause and cause.valid and cause.force and cause.force.name == 'enemy') then return end
    local q = try(function() return e.robot_order_queue end) or {}
    local o = q[1]
    local job = o and {order=order_name(o.type), item=o.target_item and (type(o.target_item) == 'table' and o.target_item.name or o.target_item) or nil,
      target=target_view(o.target), secondary=target_view(o.secondary_target)} or nil
    local list = store()
    list[#list+1] = {tick=event.tick, surface=e.surface.name, force=e.force.name, robot=e.name, position={x=e.position.x, y=e.position.y},
      killer={name=cause.name, position={x=cause.position.x, y=cause.position.y}, type=cause.type}, job=job}
    while #list > MAX do table.remove(list, 1) end
  end
  -- By killer, newest first: {key, killer, n, robots, jobs (by target), targets, first, last}.
  local function groups(force, surface, since)
    local by, order = {}, {}
    for _, r in ipairs(store()) do
      if r.force == force.name and (not surface or r.surface == surface) and r.tick >= since then
        local k = r.surface .. '|' .. r.killer.name .. '|' .. math.floor(r.killer.position.x / 4) .. ',' .. math.floor(r.killer.position.y / 4)
        local g = by[k]
        if not g then g = {key=k, surface=r.surface, killer=r.killer, n=0, robots={}, jobs={}, jorder={}, targets={}, first=r.tick, last=r.tick, at={}}; by[k] = g; order[#order+1] = g end
        g.n = g.n + 1; g.last = math.max(g.last, r.tick); g.first = math.min(g.first, r.tick)
        g.robots[r.robot] = (g.robots[r.robot] or 0) + 1
        if #g.at < 4 then g.at[#g.at+1] = r.position end
        local j = r.job
        local jk = j and (j.order .. ' ' .. (j.target and j.target.name or j.item or '?')) or 'no order read'
        if not g.jobs[jk] then g.jobs[jk] = {n=0, text=jk, where=j and j.target and j.target.position or nil}; g.jorder[#g.jorder+1] = jk end
        g.jobs[jk].n = g.jobs[jk].n + 1
        if j and j.target and j.target.ref then g.targets[j.target.ref.unit_number or at(j.target.position)] = {job=j, ref=j.target.ref} end
      end
    end
    table.sort(order, function(x, y) return x.last > y.last end)
    return order
  end
  local function text(g)
    local robots, jobs = {}, {}
    for name, n in pairs(g.robots) do robots[#robots+1] = n .. ' ' .. name end
    table.sort(robots)
    table.sort(g.jorder, function(x, y) return g.jobs[x].n > g.jobs[y].n end)
    for i, k in ipairs(g.jorder) do
      if i <= 4 then local j = g.jobs[k]; jobs[#jobs+1] = string.format('%d %s%s', j.n, j.text, j.where and ' at ' .. at(j.where) or '') end
    end
    local pending = 0
    for _, t in pairs(g.targets) do if try(function() return t.ref.valid end) then pending = pending + 1 end end
    return string.format('%s robots lost to %s %s on %s, the last %ds ago, sent to: %s%s; %d of those jobs stand%s',
      table.concat(robots, ', '), g.killer.name, at(g.killer.position), g.surface, math.floor((game.tick - g.last) / 60),
      table.concat(jobs, '; '), #g.jorder > 4 and '; ...' or '', pending,
      pending > 0 and string.format(' (robot_losses {cancel: true, near: {x: %g, y: %g}} cancels them)', math.floor(g.killer.position.x), math.floor(g.killer.position.y)) or '')
  end
  -- Cancels the jobs that sent the group's robots, as a player would: rows of what was done.
  local function cancel(force, g)
    local done, named = {}, {}
    for _, t in pairs(g.targets) do
      local e, j = t.ref, t.job
      if try(function() return e.valid end) then
        local what = j.target.name .. ' ' .. at(j.target.position)
        if e.type == 'entity-ghost' or e.type == 'tile-ghost' or e.type == 'item-request-proxy' then
          if try(function() e.destroy(); return true end) then done[#done+1] = 'removed ' .. what end
        elseif j.order == 'deconstruct' and try(function() return e.to_be_deconstructed() end) then
          if try(function() e.cancel_deconstruction(force); return true end) then done[#done+1] = 'deconstruction cancelled on ' .. what end
        elseif j.order == 'upgrade' and try(function() return e.to_be_upgraded() end) then
          if try(function() e.cancel_upgrade(force); return true end) then done[#done+1] = 'upgrade cancelled on ' .. what end
        else named[#named+1] = string.format('%s %s: not cancelled (a %s order)', j.order, what, j.order) end
      end
    end
    return done, named
  end
  function M.read(p, a)
    local minutes = api.integer(a.minutes, 30, 1, 900, 'minutes')
    local surface = a.surface or p.surface.name
    local list = groups(p.force, surface, game.tick - minutes * 3600)
    local out = {surface=surface, minutes=minutes, groups={}, lines={}}
    for _, g in ipairs(list) do
      out.groups[#out.groups+1] = {killer=g.killer, robots=g.n, line=text(g)}
      out.lines[#out.lines+1] = text(g)
    end
    if a.cancel ~= nil then
      assert(a.cancel == true and a.near ~= nil, 'cancel: true takes near: the killer\'s position (a group\'s worm or nest)')
      local q = api.position(a.near)
      local best, bd
      for _, g in ipairs(list) do
        local d = ((g.killer.position.x - q.x)^2 + (g.killer.position.y - q.y)^2)^0.5
        if not bd or d < bd then best, bd = g, d end
      end
      assert(best and bd <= 16, string.format('no robots lost within 16 tiles of %s in the last %d min', at(q), minutes))
      local done, named = cancel(p.force, best)
      out.cancelled = #done > 0 and done or nil
      out.not_cancelled = #named > 0 and named or nil
      out.cancel_line = string.format('%d job%s cancelled of the robots %s %s killed%s', #done, #done == 1 and '' or 's', best.killer.name, at(best.killer.position),
        #named > 0 and string.format('; %d named, not cancelled', #named) or '')
    end
    if #out.lines == 0 then out.lines = {string.format('no robot of ours lost to enemies on %s in the last %d min', surface, minutes)} end
    return out
  end
  -- Team alert groups: a killer with a death in the last ALERT ticks.
  function M.alert_groups(force)
    local out = {}
    local list = store()
    local keep = {}
    for _, r in ipairs(list) do if game.tick - r.tick <= KEEP then keep[#keep+1] = r end end
    if #keep ~= #list then local s = api.state(); s.robot_losses = keep end
    for _, g in ipairs(groups(force, nil, game.tick - ALERT)) do
      out[#out+1] = {key='robots_lost|' .. g.key, kind='robots_lost', surface=g.surface, n=g.n, names=g.robots, by={}, at=g.at,
        center={x=math.floor(g.killer.position.x), y=math.floor(g.killer.position.y)}, rank=g.last, line=text(g)}
    end
    return out
  end
  M.schema = {robot_losses={surface='optional (default yours)', minutes='1..900 (default 30): deaths in that time',
    cancel='optional true, with near: cancel the jobs that sent the robots that killer killed, as by hand: ghosts, tile ghosts and item request proxies removed, deconstruction and upgrade marks cancelled; repairs and deliveries named, not cancelled',
    near='with cancel: {x,y} near a group\'s killer (within 16 tiles)',
    returns='groups [{killer {name, position, type}, robots, line}]: our construction and logistic robots killed by enemies, by killer: how many of which, the jobs that sent them (order and target, where), how many of those jobs stand; lines; with cancel: cancelled, not_cancelled, cancel_line. A group with a death in the last 5 min is a team alert (robots_lost)'}}
  return M
end
