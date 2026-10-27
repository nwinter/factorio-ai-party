-- reservations {network, item?, surface?}: a logistic network's reservations, read only (Luna 06:20: on Gleba 23
-- nutrients were all reserved across 14 requesters, 245 short, while 44 logistic robots sat idle; the cause was chests
-- full of seeds and spoilage). Facts the logistic GUIs and the robots' orders give:
-- - what robots have reserved to pick up at each provider or storage chest (its logistic point's pickup targets);
-- - what is on its way to each requester or buffer chest (its delivery targets), with its request, what it holds and its
--   free slots;
-- - each logistic robot's order (deliver or pickup, item, count, the chest it goes to and the one it comes from);
-- flagged: a delivery whose target chest has no free slot for the item, and reservations while robots sit idle.
-- Releasing a reservation is no player action: nothing is changed.
return function(api)
  local M = {}
  local MAX_ROBOTS, LIST = 1024, 12
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function name_of(v)
    if type(v) == 'string' then return v end
    local n = v ~= nil and try(function() return v.name end)
    if type(n) == 'string' then return n end
    n = n ~= nil and try(function() return n.name end)
    return type(n) == 'string' and n or nil
  end
  local function at(e) return string.format('%s (%g,%g)', e.name, e.position.x, e.position.y) end
  local function key(e) return e.unit_number or (e.position.x .. ',' .. e.position.y) end
  local function counts(list, item)
    local out, n = {}, 0
    for _, s in ipairs(list or {}) do
      local name = name_of(s.name)
      if name and (not item or name == item) then out[name] = (out[name] or 0) + (s.count or 0); n = n + (s.count or 0) end
    end
    return out, n
  end
  local function text(t)
    local parts = {}
    for name, n in pairs(t) do parts[#parts+1] = {name, n} end
    table.sort(parts, function(a, b) return a[2] > b[2] or (a[2] == b[2] and a[1] < b[1]) end)
    for i, x in ipairs(parts) do parts[i] = x[1] .. ' ' .. x[2] end
    return table.concat(parts, ', ')
  end
  -- Whether chest e has room for item now: a free slot, or a stack of it not full.
  local function room(e, item)
    local inv = try(function() return e.get_inventory(defines.inventory.chest) end)
    if not inv then return nil end
    if (try(function() return inv.count_empty_stacks(true, false) end) or 0) > 0 then return true end
    return (try(function() return inv.can_insert({name=item, count=1}) end)) == true
  end
  -- (d25 batch217 QAB1, Sol #2390: Nauvis network #243 has 7523 logistic robots; this read and where_is read the first
  -- 1024, so the robots taking bioflux from the landing pad at (52,54) to the requester at (-269.5,486.5) could not be
  -- shown) reservations {position, from?, radius?, item?, surface?}: one chest's or landing pad's robots now.
  -- - its logistic points' own counts (the engine's): what is on the way to it, what robots have reserved to pick up
  --   there; these are totals, whatever robots the read finds;
  -- - the robots with an order to deliver there or pick up there, found among the logistic robots in the air within
  --   radius of it, and with from within radius of from and along the straight line between the two (CORRIDOR tiles
  --   either side): each one's item, count, source and destination as its orders give them (a robot that has picked
  --   up keeps no source: carrying);
  -- - found against the totals: what the read did not find is on robots outside the areas read.
  -- reservations {position, sweep: true} reads every logistic robot of the network in the air instead, a column of
  -- COLUMN tiles or BATCH robots' orders a tick; reservations {sweep: N} reads it. Read only.
  M.RADIUS, M.RADIUS_MIN, M.RADIUS_MAX, M.CORRIDOR, M.READ_MAX, M.ROWS = 64, 8, 128, 32, 1024, 24
  M.COLUMN, M.BATCH, M.MARGIN, M.KEEP = 32, 256, 64, 36000
  local ORDER
  local function order_name(t)
    if not ORDER then ORDER = {}; for k, v in pairs(defines.robot_order_type or {}) do ORDER[v] = k end end
    return ORDER[t] or tostring(t)
  end
  local function pos_of(v) return type(v) == 'table' and type(v.x or v[1]) == 'number' and type(v.y or v[2]) == 'number' and {x=v.x or v[1], y=v.y or v[2]} or nil end
  -- World-free: the call, a queue step and dry_run.
  function M.check_point(a)
    if a.position == nil and a.sweep == nil and a.from == nil and a.radius == nil then return end
    if type(a.sweep) == 'number' then
      assert(a.sweep >= 1 and a.sweep == math.floor(a.sweep), 'sweep: true starts one (with position); a number reads that sweep')
      assert(a.position == nil and a.from == nil and a.radius == nil and a.item == nil and a.network == nil and a.surface == nil, 'sweep: N reads that sweep alone: no other argument')
      return
    end
    assert(pos_of(a.position), 'position: {x, y} of a requester, buffer, provider or storage chest or a landing pad')
    assert(a.network == nil, 'position reads the network of what stands there: no network')
    assert(a.sweep == nil or a.sweep == true, 'sweep: true starts one (with position); a number reads that sweep')
    assert(a.from == nil or pos_of(a.from), 'from: {x, y}, where the items come from (a provider chest or landing pad)')
    assert(a.radius == nil or type(a.radius) == 'number' and a.radius == math.floor(a.radius) and a.radius >= M.RADIUS_MIN and a.radius <= M.RADIUS_MAX,
      string.format('radius: %d..%d tiles (default %d)', M.RADIUS_MIN, M.RADIUS_MAX, M.RADIUS))
    assert(a.sweep == nil or a.from == nil and a.radius == nil, 'sweep reads the whole network: no from or radius')
  end
  local function points(e)
    local t = try(function() return e.get_logistic_point() end)
    if t == nil then return {} end
    if type(t) ~= 'table' then return {t} end
    local out = {}
    for _, pt in pairs(t) do out[#out+1] = pt end
    return out
  end
  -- What stands at q with logistic points: the chest or pad (ours).
  local function entity_at(surface, force, q)
    local found = try(function() return surface.find_entities_filtered{area={{q.x - 0.05, q.y - 0.05}, {q.x + 0.05, q.y + 0.05}}, force=force} end) or {}
    for _, e in ipairs(found) do
      if e.type ~= 'roboport' and #points(e) > 0 then return e end
    end
  end
  local function qkey(name, q) return q and q ~= 'normal' and name .. '@' .. q or name end
  local function sums(list, item, into)
    for _, s in ipairs(list or {}) do
      local n = name_of(s.name)
      if n and (not item or n == item) then
        local k = qkey(n, name_of(s.quality))
        into[k] = (into[k] or 0) + (s.count or 0)
      end
    end
    return into
  end
  -- The engine's counts at e's logistic points in a network, and its network; a point in none (a landing pad's
  -- request from platforms in orbit) apart: no robot brings that.
  local function totals(e, item)
    local coming, reserved, ln, orbit = {}, {}, nil, {}
    for _, pt in ipairs(points(e)) do
      local n = try(function() return pt.logistic_network end)
      if n and try(function() return n.valid end) then
        ln = ln or n
        sums(try(function() return pt.targeted_items_deliver end), item, coming)
        sums(try(function() return pt.targeted_items_pickup end), item, reserved)
      else sums(try(function() return pt.targeted_items_deliver end), item, orbit) end
    end
    return coming, reserved, ln, orbit
  end
  local function where(t) return t and try(function() return t.valid end) and {name=t.name, position={x=t.position.x, y=t.position.y}} or nil end
  local function place(w) return w and string.format('%s (%g,%g)', w.name, w.position.x, w.position.y) or '?' end
  -- A robot's order at e, or nil: {here (deliver|pickup), item, count, source, destination, state}.
  local function order_at(r, e, item)
    local q = try(function() return r.robot_order_queue end)
    if not q then return nil end
    for j, o in ipairs(q) do
      if o.target and o.target == e then
        local ti = o.target_item
        local it = ti and name_of(ti.name or ti)
        if it and (not item or it == item) then
          local kind = order_name(o.type)
          local row = {item=it, quality=ti and name_of(ti.quality) or 'normal', count=o.target_count or 0, order=kind}
          if kind == 'pickup' then
            local nx = q[j + 1]
            row.here, row.destination, row.state = 'pickup', nx and where(nx.target), 'flying to pick it up here'
            row.source = where(e)
          else
            local pv = q[j - 1]
            row.here, row.destination = 'deliver', where(e)
            if pv and order_name(pv.type) == 'pickup' then row.source, row.state = where(pv.target), 'flying to pick it up at its source'
            else row.state = 'carrying it (a robot keeps no source once it has picked up)' end
          end
          return row
        end
      end
    end
  end
  -- Robots read so far into an aggregate: groups by route, the first ROWS robots, counts found by item.
  local function new_found() return {groups={}, order={}, robots={}, deliver={}, pickup={}, robots_with=0} end
  local function add(found, r, row)
    found.robots_with = found.robots_with + 1
    local k = qkey(row.item, row.quality)
    local into = row.here == 'deliver' and found.deliver or found.pickup
    into[k] = (into[k] or 0) + row.count
    local gk = table.concat({row.here, k, place(row.source), place(row.destination)}, '|')
    local g = found.groups[gk]
    if not g then
      g = {here=row.here, item=k, source=row.source, destination=row.destination, robots=0, count=0, states={}}
      found.groups[gk] = g; found.order[#found.order+1] = gk
    end
    g.robots, g.count = g.robots + 1, g.count + row.count
    g.states[row.state] = (g.states[row.state] or 0) + 1
    if #found.robots < M.ROWS then
      local rp = try(function() return r.position end)
      row.position = rp and {x=math.floor(rp.x * 10 + 0.5) / 10, y=math.floor(rp.y * 10 + 0.5) / 10}
      row.line = string.format('robot at (%g,%g): %d %s from %s to %s, %s', row.position and row.position.x or 0, row.position and row.position.y or 0,
        row.count, k, row.source and place(row.source) or 'a source not kept', place(row.destination), row.state)
      found.robots[#found.robots+1] = row
    end
  end
  local function list(t)
    local out = {}
    for k, n in pairs(t) do out[#out+1] = {item=k, count=n} end
    table.sort(out, function(x, y) return x.count > y.count or (x.count == y.count and x.item < y.item) end)
    return out
  end
  local function said(rows) local p = {} for _, x in ipairs(rows) do p[#p+1] = x.item .. ' ' .. x.count end return #p > 0 and table.concat(p, ', ') or 'none' end
  -- The reply from the totals and what was found.
  local function reply(e, item, coming, reserved, ln, found, read, how, orbit, start)
    local groups = {}
    for _, gk in ipairs(found.order) do groups[#groups+1] = found.groups[gk] end
    table.sort(groups, function(x, y) return x.robots > y.robots end)
    local routes = {}
    for i, g in ipairs(groups) do
      if i <= M.ROWS then
        local st = {}
        for s, n in pairs(g.states) do st[#st+1] = n .. ' ' .. s end
        table.sort(st)
        routes[#routes+1] = string.format('%d robot%s: %d %s from %s to %s (%s)', g.robots, g.robots == 1 and '' or 's', g.count, g.item,
          g.source and place(g.source) or 'a source not kept', place(g.destination), table.concat(st, '; '))
      end
    end
    local on_way, res, fd, fp = list(coming), list(reserved), list(found.deliver), list(found.pickup)
    -- a sweep: its counts at its start and its end; what it found is set against the larger of the two
    local counts = '(its own counts)'
    if start then
      counts = string.format('(its own counts at the sweep\'s end; at its start: on the way %s, reserved %s)', said(list(start.coming)), said(list(start.reserved)))
      local function most(a, b) local o = {} for k, n in pairs(a) do o[k] = n end for k, n in pairs(b) do o[k] = math.max(o[k] or 0, n) end return o end
      coming, reserved = most(coming, start.coming), most(reserved, start.reserved)
    end
    local function short(total, got)
      local miss = {}
      for k, n in pairs(total) do local m = n - (got[k] or 0); if m > 0 then miss[#miss+1] = k .. ' ' .. m end end
      table.sort(miss)
      return miss
    end
    local md, mp = short(coming, found.deliver), short(reserved, found.pickup)
    local all = ln and try(function() return ln.all_logistic_robots end) or 0
    local idle = ln and try(function() return ln.available_logistic_robots end) or 0
    local here = place(where(e))
    local lines = {string.format('%s, logistic #%s%s: on the way here %s, reserved for pickup here %s %s; found %s on its way and %s to be picked up on %d robot%s of %d read (%s; %d logistic robots in the network, %d in the air)',
      here, tostring(ln and try(function() return ln.network_id end) or '?'), item and ' (' .. item .. ')' or '', said(on_way), said(res), counts, said(fd), said(fp),
      found.robots_with, found.robots_with == 1 and '' or 's', read, how, all, all - idle)}
    if #md > 0 then lines[#lines+1] = 'on the way here and not found on the robots read: ' .. table.concat(md, ', ') .. ' (on robots outside what was read)' end
    if #mp > 0 then lines[#lines+1] = 'reserved for pickup here and not found on the robots read: ' .. table.concat(mp, ', ') .. ' (on robots outside what was read)' end
    local ob = list(orbit or {})
    if #ob > 0 then lines[#lines+1] = 'on the way to its point in no logistic network (a landing pad\'s request from platforms in orbit; no robot brings it): ' .. said(ob) end
    for _, l in ipairs(routes) do lines[#lines+1] = l end
    return {entity=where(e), network=ln and try(function() return ln.network_id end) or nil, item=item, on_the_way=on_way, reserved_for_pickup=res,
      at_start=start and {on_the_way=list(start.coming), reserved_for_pickup=list(start.reserved)} or nil,
      from_orbit=#ob > 0 and ob or nil, found_on_the_way=fd, found_for_pickup=fp, not_found_on_the_way=#md > 0 and md or nil, not_found_for_pickup=#mp > 0 and mp or nil,
      robots_found=found.robots_with, robots_read=read, logistic_robots=all, in_the_air=all - idle,
      routes=#routes > 0 and routes or nil, routes_more=#groups > M.ROWS and #groups - M.ROWS or nil,
      robots=#found.robots > 0 and found.robots or nil, robots_more=found.robots_with > #found.robots and found.robots_with - #found.robots or nil, lines=lines}
  end
  local function sweeps()
    local s = api.state and api.state()
    if not s then return nil end
    s.robot_sweeps = s.robot_sweeps or {seq=0, jobs={}}
    return s.robot_sweeps
  end
  -- Boxes to read: round position, round from, and the line between them.
  local function boxes(q, from, r)
    local out = {{{q.x - r, q.y - r}, {q.x + r, q.y + r}}}
    local how = string.format('within %d tiles of (%g,%g)', r, q.x, q.y)
    if from then
      out[#out+1] = {{from.x - r, from.y - r}, {from.x + r, from.y + r}}
      local dx, dy = from.x - q.x, from.y - q.y
      local len = math.sqrt(dx * dx + dy * dy)
      local step = 2 * M.CORRIDOR
      local n = math.floor(len / step)
      for i = 1, n do
        local cx, cy = q.x + dx * i * step / len, q.y + dy * i * step / len
        out[#out+1] = {{cx - M.CORRIDOR, cy - M.CORRIDOR}, {cx + M.CORRIDOR, cy + M.CORRIDOR}}
      end
      how = how .. string.format(', of (%g,%g) and %d tiles either side of the line between', from.x, from.y, M.CORRIDOR)
    end
    return out, how
  end
  function M.point(p, a)
    M.check_point(a)
    if type(a.sweep) == 'number' then return M.sweep_read(p, a.sweep) end
    assert(a.item == nil or (type(a.item) == 'string' and prototypes.item[a.item]), 'item must be an item name')
    local surface = p.surface
    if a.surface ~= nil then surface = game.get_surface(a.surface); assert(surface, 'no surface ' .. tostring(a.surface)) end
    local q = pos_of(a.position)
    local e = entity_at(surface, p.force, q)
    assert(e, string.format('no chest or landing pad of ours with logistic points at (%g,%g) on %s', q.x, q.y, surface.name))
    local coming, reserved, ln, orbit = totals(e, a.item)
    if a.sweep == true then return M.sweep_start(p, e, a.item, ln, {coming=coming, reserved=reserved}) end
    local found, seen, read, capped = new_found(), {}, 0, false
    local list_of, how = boxes(q, pos_of(a.from), a.radius or M.RADIUS)
    for _, box in ipairs(list_of) do
      if capped then break end
      -- limit: past the cap a box's robots are not read (a robot already read in a box before counts in it)
      local lim = M.READ_MAX - read + M.ROWS
      local got = try(function() return surface.find_entities_filtered{area=box, type='logistic-robot', force=p.force, limit=lim} end) or {}
      if #got >= lim then capped = true end
      for _, r in ipairs(got) do
        local u = r.unit_number
        if not seen[u] then
          if read >= M.READ_MAX then capped = true; break end  -- the cap
          seen[u] = true; read = read + 1
          local row = order_at(r, e, a.item)
          if row then add(found, r, row) end
        end
      end
    end
    local out = reply(e, a.item, coming, reserved, ln, found, read, how .. (capped and string.format(', up to %d robots: the rest there not read', M.READ_MAX) or ''), orbit)
    out.read, out.capped = how, capped or nil
    out.note = 'reservations {position, sweep: true} reads every logistic robot of the network in the air, across ticks'
    return out
  end
  -- The sweep: the network's cells' box and MARGIN round it, in columns.
  function M.sweep_start(p, e, item, ln, start)
    assert(ln, 'its logistic points are in no network: nothing to sweep')
    local st = sweeps()
    local x0, y0, x1, y1
    for _, c in ipairs(try(function() return ln.cells end) or {}) do
      local o = try(function() return c.owner end)
      local q, r = o and o.position, try(function() return c.logistic_radius end) or 0
      if q then
        x0, y0 = math.min(x0 or q.x - r, q.x - r), math.min(y0 or q.y - r, q.y - r)
        x1, y1 = math.max(x1 or q.x + r, q.x + r), math.max(y1 or q.y + r, q.y + r)
      end
    end
    assert(x0, 'its network has no roboport: nothing to sweep')
    x0, y0, x1, y1 = x0 - M.MARGIN, y0 - M.MARGIN, x1 + M.MARGIN, y1 + M.MARGIN
    st.seq = st.seq + 1
    local job = {n=st.seq, index=p.index, e=e, item=item, ln=ln, surface=e.surface.index, force=p.force.name, box={x0, y0, x1, y1},
      columns=math.ceil((x1 - x0) / M.COLUMN), col=0, pending=nil, at=0, seen={}, read=0, found=new_found(), start=game.tick, at_start=start}
    for i, j in pairs(st.jobs) do if j.index == p.index then st.jobs[i] = nil end end
    st.jobs[job.n] = job
    st.active = true
    return {sweep={n=job.n, state='running', columns=job.columns, started_tick=job.start},
      line=string.format('sweep %d: every logistic robot of logistic #%s in the air, %d columns of %d tiles from x %g to %g, a column or %d robots\' orders a tick; reservations {sweep: %d} reads it',
        job.n, tostring(ln.network_id), job.columns, M.COLUMN, x0, x1, M.BATCH, job.n)}
  end
  local function finish(job)
    local coming, reserved, orbit = {}, {}, {}
    if job.e.valid then local _; coming, reserved, _, orbit = totals(job.e, job.item) end
    local how = string.format('a sweep of %d columns over ticks %d-%d (robots move while it reads: one crossing into a column already read is not seen; one seen twice is counted once)',
      job.columns, job.start, game.tick)
    job.result = reply(job.e, job.item, coming, reserved, job.ln.valid and job.ln or nil, job.found, job.read, how, orbit, job.at_start or {coming={}, reserved={}})
    job.result.sweep = {n=job.n, state='done', columns=job.columns, started_tick=job.start, done_tick=game.tick, ticks=game.tick - job.start}
    job.done, job.pending, job.seen, job.found = game.tick, nil, nil, nil
  end
  -- One step a tick, the running sweeps in turn.
  function M.tick()
    local st = sweeps()
    if not (st and st.active) then return end
    local job, any
    for n, j in pairs(st.jobs) do
      if j.done then if game.tick - j.done > M.KEEP then st.jobs[n] = nil end
      elseif not job or (j.stepped or 0) < (job.stepped or 0) then job = j end
      if not j.done then any = true end
    end
    if not any then st.active = nil; return end
    job.stepped = game.tick
    if not (job.e.valid and job.ln.valid) then finish(job); return end
    if job.pending and job.at < #job.pending then
      local last = math.min(#job.pending, job.at + M.BATCH)
      for i = job.at + 1, last do
        local r = job.pending[i]
        if r.valid then
          local u = r.unit_number
          if not job.seen[u] then
            job.seen[u] = true; job.read = job.read + 1
            local row = order_at(r, job.e, job.item)
            if row then add(job.found, r, row) end
          end
        end
      end
      job.at = last
      return
    end
    if job.col >= job.columns then finish(job); return end
    local b = job.box
    local cx = b[1] + job.col * M.COLUMN
    job.col = job.col + 1
    job.pending = try(function() return game.surfaces[job.surface].find_entities_filtered{area={{cx, b[2]}, {cx + M.COLUMN, b[4]}}, type='logistic-robot', force=job.force} end) or {}
    job.at = 0
  end
  function M.sweep_read(p, n)
    local st = sweeps()
    local job = st and st.jobs[n]
    assert(job, string.format('no sweep %d is kept (one an agent; a done one is kept 10 min)', n))
    if job.result then return job.result end
    return {sweep={n=job.n, state='running', columns=job.columns, columns_read=job.col, robots_read=job.read, started_tick=job.start},
      line=string.format('sweep %d running: %d of %d columns, %d robots read since tick %d', job.n, job.col, job.columns, job.read, job.start)}
  end
  function M.read(p, a)
    if a.position ~= nil or a.sweep ~= nil then return M.point(p, a) end
    M.check_point(a)
    assert(type(a.network) == 'number', 'network is a logistic network number (networks and an inspect of a roboport give it)')
    assert(a.item == nil or (type(a.item) == 'string' and prototypes.item[a.item]), 'item must be an item name')
    local surface = p.surface
    if a.surface ~= nil then surface = game.get_surface(a.surface); assert(surface, 'no surface ' .. tostring(a.surface)) end
    local ln
    for _, n in ipairs(try(function() return p.force.logistic_networks[surface.name] end) or {}) do if n.network_id == a.network then ln = n end end
    assert(ln, string.format('no logistic network #%d of ours on %s', a.network, surface.name))
    local item = a.item
    -- Pickup reservations at providers and storage.
    local pickups, picked = {}, {}
    for _, kind in ipairs({'provider_points', 'storage_points'}) do
      for _, pt in ipairs(try(function() return ln[kind] end) or {}) do
        local e = pt.owner
        local t, n = counts(try(function() return pt.targeted_items_pickup end), item)
        if e and e.valid and n > 0 and not picked[key(e)] then
          picked[key(e)] = true
          pickups[#pickups+1] = {n=n, line=string.format('%s: %s reserved for pickup', at(e), text(t))}
        end
      end
    end
    table.sort(pickups, function(x, y) return x.n > y.n end)
    -- Requesters and buffers: request, held, on the way, room.
    local targets, seen = {}, {}
    for _, pt in ipairs(try(function() return ln.requester_points end) or {}) do
      local e = pt.owner
      if e and e.valid and not seen[key(e)] and e.type == 'logistic-container' then
        seen[key(e)] = true
        local coming = counts(try(function() return pt.targeted_items_deliver end), item)
        local inv = try(function() return e.get_inventory(defines.inventory.chest) end)
        local rows = {}
        for _, f in ipairs(try(function() return pt.filters end) or {}) do
          local name = name_of(f.name)
          if name and (not item or name == item) and (f.count or 0) > 0 then
            -- (d26 batch249 R10) what it holds of the quality it asks for (none named: every quality)
            local q = f.quality
            if q ~= nil and type(q) ~= 'string' then q = try(function() return q.name end) end
            local held = inv and try(function() if q then return inv.get_item_count{name=name, quality=q} end return inv.get_item_count_filtered{name=name} end) or 0
            local short = math.max(0, f.count - held - (coming[name] or 0))
            if short > 0 or (coming[name] or 0) > 0 then
              local full = room(e, name) == false
              rows[#rows+1] = {name=q and q ~= 'normal' and name .. '@' .. q or name, ask=f.count, held=held, coming=coming[name] or 0, short=short, full=full}
            end
          end
        end
        if #rows > 0 then
          local parts, short, full = {}, 0, false
          for _, r in ipairs(rows) do
            parts[#parts+1] = string.format('%s asks %d, holds %d, %d on the way%s', r.name, r.ask, r.held, r.coming, r.full and ' (no room for it: every slot taken)' or '')
            short = short + r.short; full = full or (r.full and r.coming > 0)
          end
          local free = inv and try(function() return inv.count_empty_stacks(true, false) end)
          targets[#targets+1] = {short=short, full=full, line=string.format('%s: %s; %s free slot%s', at(e), table.concat(parts, '; '),
            tostring(free or '?'), free == 1 and '' or 's')}
        end
      end
    end
    table.sort(targets, function(x, y) if x.full ~= y.full then return x.full end return x.short > y.short end)
    -- The robots' orders: what each carries or goes to pick up, from where, to where.
    local flights, robots, read = {}, try(function() return ln.logistic_robots end) or {}, 0
    local blocked = 0
    for _, r in ipairs(robots) do
      if read >= MAX_ROBOTS then break end
      read = read + 1
      for _, o in ipairs(try(function() return r.robot_order_queue end) or {}) do
        local it = o.target_item and name_of(o.target_item.name or o.target_item)
        if it and (not item or it == item) then
          local target = o.target and o.target.valid and o.target or nil
          local from = o.secondary_target and o.secondary_target.valid and o.secondary_target or nil
          local full = target and target.type == 'logistic-container' and room(target, it) == false
          if full then blocked = blocked + 1 end
          local k = (target and key(target) or '?') .. '|' .. it
          local f = flights[k]
          if not f then
            f = {n=0, robots=0, item=it, target=target, from={}, full=full}
            flights[k] = f
          end
          f.robots = f.robots + 1; f.n = f.n + (o.target_count or 0)
          if from then f.from[at(from)] = true end
        end
      end
    end
    local flist = {}
    for _, f in pairs(flights) do flist[#flist+1] = f end
    table.sort(flist, function(x, y) if x.full ~= y.full then return x.full end return x.robots > y.robots end)
    local flines = {}
    for i, f in ipairs(flist) do
      if i <= LIST then
        local froms = {}
        for k in pairs(f.from) do froms[#froms+1] = k end
        table.sort(froms)
        flines[#flines+1] = string.format('%d robot%s with %d %s for %s%s%s', f.robots, f.robots == 1 and '' or 's', f.n, f.item,
          f.target and at(f.target) or 'a target out of the network', #froms > 0 and ' from ' .. table.concat(froms, ', ', 1, math.min(3, #froms)) or '',
          f.full and ': its target has no room for it (every slot taken)' or '')
      end
    end
    local idle = try(function() return ln.available_logistic_robots end) or 0
    local total = try(function() return ln.all_logistic_robots end) or 0
    local reserved = 0
    for _, x in ipairs(pickups) do reserved = reserved + x.n end
    local flags = {}
    if reserved > 0 and idle > 0 then flags[#flags+1] = string.format('%d reserved for pickup while %d of %d logistic robots are idle', reserved, idle, total) end
    if blocked > 0 then flags[#flags+1] = string.format('%d robot order%s to a chest with no room for the item', blocked, blocked == 1 and ' goes' or 's go') end
    local nfull = 0
    for _, t in ipairs(targets) do if t.full then nfull = nfull + 1 end end
    if nfull > 0 then flags[#flags+1] = string.format('%d requester%s with deliveries on the way and no room for them', nfull, nfull == 1 and '' or 's') end
    local lines = {string.format('logistic #%d on %s%s: %d logistic robots, %d idle; %d reserved for pickup at %d place%s; %d requester%s short or with deliveries on the way; %d robot order%s read%s',
      a.network, surface.name, item and (' (' .. item .. ')') or '', total, idle, reserved, #pickups, #pickups == 1 and '' or 's', #targets, #targets == 1 and '' or 's',
      read, read == 1 and '' or 's', #robots > MAX_ROBOTS and string.format(' (the first %d robots)', MAX_ROBOTS) or '')}
    for _, f in ipairs(flags) do lines[#lines+1] = 'flag: ' .. f end
    local pl, tl = {}, {}
    for i, x in ipairs(pickups) do if i <= LIST then pl[i] = x.line end end
    for i, x in ipairs(targets) do if i <= LIST then tl[i] = x.line end end
    return {network=a.network, surface=surface.name, item=item, logistic_robots=total, idle=idle, reserved_for_pickup=reserved,
      flags=#flags > 0 and flags or nil, pickups=#pl > 0 and pl or nil, pickups_more=#pickups > LIST and #pickups - LIST or nil,
      requesters=#tl > 0 and tl or nil, requesters_more=#targets > LIST and #targets - LIST or nil,
      robots=#flines > 0 and flines or nil, robots_more=#flist > LIST and #flist - LIST or nil, lines=lines}
  end
  M.schema = {reservations = {network='logistic network number (networks and an inspect of a roboport give it); or position', item='optional item name: that item only',
    surface='optional planet name: a network there (with position: the chest or pad there)',
    position='instead of network: {x, y} of one requester, buffer, provider or storage chest or landing pad of ours: its own counts (on_the_way, reserved_for_pickup: the engine\'s, every robot) and the logistic robots in the air within radius of it with an order to deliver there or pick up there: each robot\'s item, count, source and destination (routes, robots: position, state), found against those counts (not_found_*: on robots outside what was read); up to 1024 robots read',
    from='optional with position: {x, y} where the items come from (a provider chest or landing pad): robots within radius of it and 32 tiles either side of the straight line between the two are read too',
    radius='optional with position: 8..128 tiles (default 64)',
    sweep='with position, true: read every logistic robot of its network in the air instead, across ticks (a column of 32 tiles or 256 robots\' orders a tick; Nauvis\'s network: about 40 columns): the reply gives its number; a number alone reads that sweep (running: columns read; done: the read as position gives it, with sweep {started_tick, done_tick, ticks}); one an agent, a done one kept 10 min',
    returns='read only: logistic_robots, idle, reserved_for_pickup; pickups (each provider or storage chest with what robots have reserved to pick up there); requesters (each requester or buffer chest short or with deliveries on the way: per item its request, what it holds, what is on the way, and no room for it when every slot is taken; free slots); robots (the robots\' orders grouped by item and target chest: how many robots, how many items, from where, and when the target has no room); flags (reservations while robots are idle, orders to a chest with no room, requesters with deliveries on the way and no room); lines; robots: the first 1024 logistic robots of the network in the air (position reads one chest\'s robots past that)'}}
  return M
end
