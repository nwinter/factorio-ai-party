-- Robot dispatch preview (d17 batch34 B3, Opus, 3 times this shift: a deconstruct of two ore chests 450 tiles away sent
-- about 300 robots and some were lost on the way; 20 old requesters had pulled ore 500 tiles for 20 hours): for the jobs
-- a dry run would give robots, the trips they take as the logistic network would pick them, read from the engine:
-- construct (a ghost): from the roboport nearest the ghost with robots in it, to the chest the network would take the
-- item from (select_pickup_point), to the ghost; deconstruct: from that roboport to the entity, then to where the
-- network would put what it holds (select_drop_point), one trip for the entity and one per robot load of its contents;
-- deliver (a requester's request): from the chest the network would take it from to the requester, one trip a robot
-- load. Jobs are grouped by item and 32-tile cell (one read a group). Per preview: the trips, how many robots would
-- go (the trips, at most the network's idle robots of that kind), the roboports they start from, the longest and the
-- mean trip, the trips over LONG tiles, and each leg passing within reach of a worm or spawner the map shows. Read
-- only; bounded: GROUPS groups, LEGS legs checked for enemies.
return function(api)
  local M = {}
  M.LONG, M.GROUPS, M.LEGS, M.CHUNKS = 200, 32, 16, 64
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function at(q) return string.format('(%g,%g)', math.floor(q.x * 10 + 0.5) / 10, math.floor(q.y * 10 + 0.5) / 10) end
  local function dist(a, b) return ((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2) ^ 0.5 end
  local function payload(force, kind)
    local proto = prototypes.entity[kind == 'deliver' and 'logistic-robot' or 'construction-robot']
    local base = try(function() return proto.max_payload_size end) or 1
    return math.max(1, base + (try(function() return force.worker_robots_storage_bonus end) or 0))
  end
  -- The roboport of the network nearest pos holding robots of the kind (else the nearest); the network's roboports read
  -- once a preview (cache: network id -> {{o, x, y, c (construction robots in it), l (logistic)}}).
  local function port_for(net, pos, kind, cache)
    local id = net.network_id
    local list = cache[id]
    if not list then
      list = {}
      for _, c in ipairs(try(function() return net.cells end) or {}) do
        local o = c.owner
        if o and o.valid and not try(function() return c.mobile end) then
          local q = o.position
          list[#list+1] = {o=o, x=q.x, y=q.y, c=try(function() return c.stationed_construction_robot_count end) or 0,
            l=try(function() return c.stationed_logistic_robot_count end) or 0}
        end
      end
      cache[id] = list
    end
    local best, bd, any, ad
    for _, r in ipairs(list) do
      local d = (r.x - pos.x) ^ 2 + (r.y - pos.y) ^ 2
      local n = kind == 'deliver' and r.l or r.c
      if n > 0 and (not bd or d < bd) then best, bd = r.o, d end
      if not ad or d < ad then any, ad = r.o, d end
    end
    return best or any
  end
  -- jobs: {{kind = construct | deconstruct | deliver, pos, item, count (1 for a ghost or an entity; the items asked for
  -- a delivery), contents (what an entity to deconstruct holds)}}. Returns lines (nil when no job) and the counts.
  M.MAX_CELLS = 2048
  function M.preview(s, force, jobs)
    local groups, order = {}, {}
    for _, j in ipairs(jobs) do
      if j.pos and j.item then
        local k = j.kind .. '|' .. j.item .. '|' .. math.floor(j.pos.x / 32) .. '|' .. math.floor(j.pos.y / 32)
        local g = groups[k]
        if not g then
          if #order >= M.GROUPS then break end
          g = {kind=j.kind, item=j.item, n=0, items=0, sx=0, sy=0}
          groups[k] = g; order[#order+1] = g
        end
        g.n = g.n + 1; g.items = g.items + (j.count or 1) + (j.contents or 0)
        g.sx = g.sx + j.pos.x; g.sy = g.sy + j.pos.y
      end
    end
    if #order == 0 then return nil end
    local nets, ports, legs, trips, length, longest, long_n, uncovered = {}, {}, {}, 0, 0, nil, 0, 0
    local pcache = {}
    local function add_port(o, n)
      local u = o.unit_number
      ports[u] = ports[u] or {o=o, n=0}
      ports[u].n = ports[u].n + n
    end
    local loads = {}
    for _, g in ipairs(order) do
      local pos = {x=g.sx / g.n, y=g.sy / g.n}
      local net
      if g.kind == 'deliver' then net = try(function() return force.find_logistic_network_by_position(pos, s) end)
      else net = (try(function() return s.find_logistic_networks_by_construction_area(pos, force) end) or {})[1] end
      if not net then uncovered = uncovered + g.n; g.uncovered = pos
      else
        local id = net.network_id
        -- (d18 batch38 B2, Haiku, 3 times: big pole ghosts whose network held none) what the covering network holds
        if g.kind == 'construct' then g.net_id, g.holds = id, try(function() return net.get_item_count(g.item) end) end
        nets[id] = nets[id] or {net=net, trips={construct=0, deconstruct=0, deliver=0}}
        local cap = loads[g.kind] or payload(force, g.kind)
        loads[g.kind] = cap
        local n
        if g.kind == 'construct' then n = g.n
        elseif g.kind == 'deconstruct' then n = g.n + math.ceil((g.items - g.n) / cap)
        else n = math.ceil(g.items / cap) end
        local a1, a2, b1, b2
        if g.kind == 'deliver' then
          local pk = try(function() return net.select_pickup_point{name=g.item, position=pos} end)
          local o = pk and try(function() return pk.owner end)
          if o and o.valid then
            local port = port_for(net, o.position, 'deliver', pcache)
            if port then a1, a2 = port.position, o.position; add_port(port, n) end
            b1, b2 = o.position, pos
          end
        else
          local port = port_for(net, pos, 'construct', pcache)
          if port then add_port(port, n) end
          if g.kind == 'construct' then
            local pk = try(function() return net.select_pickup_point{name=g.item, position=pos} end)
            local o = pk and try(function() return pk.owner end)
            if o and o.valid then a1, a2, b1, b2 = port and port.position or o.position, o.position, o.position, pos end
          else
            local dp = try(function() return net.select_drop_point{stack={name=g.item, count=1}} end)
            local o = dp and try(function() return dp.owner end)
            if port then a1, a2 = port.position, pos end
            if o and o.valid then b1, b2 = pos, o.position end
          end
        end
        local len = (a1 and dist(a1, a2) or 0) + (b1 and dist(b1, b2) or 0)
        if a1 or b1 then
          nets[id].trips[g.kind] = nets[id].trips[g.kind] + n
          trips = trips + n; length = length + len * n
          if not longest or len > longest.len then longest = {len=len, g=g, a1=a1, a2=a2, b1=b1, b2=b2} end
          if len > M.LONG then long_n = long_n + n end
          for _, l in ipairs({{a1, a2}, {b1, b2}}) do
            if l[1] and dist(l[1], l[2]) > 1 then legs[#legs+1] = {from=l[1], to=l[2], n=n, len=dist(l[1], l[2])} end
          end
        else
          g.no_source = true
        end
      end
    end
    local lines = {}
    if trips > 0 then
      local robots, idle = 0, 0
      for _, x in pairs(nets) do
        local ci = try(function() return x.net.available_construction_robots end) or 0
        local li = try(function() return x.net.available_logistic_robots end) or 0
        robots = robots + math.min(x.trips.construct + x.trips.deconstruct, ci) + math.min(x.trips.deliver, li)
        idle = idle + (x.trips.construct + x.trips.deconstruct > 0 and ci or 0) + (x.trips.deliver > 0 and li or 0)
      end
      local plist = {}
      for _, x in pairs(ports) do plist[#plist+1] = x end
      table.sort(plist, function(x, y) if x.n ~= y.n then return x.n > y.n end return x.o.unit_number < y.o.unit_number end)
      local pt = {}
      for i = 1, math.min(3, #plist) do pt[i] = string.format('%s %s (%d trips)', plist[i].o.name, at(plist[i].o.position), plist[i].n) end
      lines[#lines+1] = string.format('%d robot trips: about %d robots would go at once (the network\'s idle ones of that kind: %d), from %s%s; the longest trip %d tiles, the mean %d',
        trips, robots, idle, table.concat(pt, ', '), #plist > 3 and string.format(' (+%d more roboports)', #plist - 3) or '', math.floor(longest.len + 0.5), math.floor(length / trips + 0.5))
      if long_n > 0 then
        local L = longest
        lines[#lines+1] = string.format('%d trips over %d tiles; the longest, %d tiles, for %s near %s: %s', long_n, M.LONG, math.floor(L.len + 0.5), L.g.item, at({x=L.g.sx / L.g.n, y=L.g.sy / L.g.n}),
          table.concat((function()
            local parts = {}
            if L.a1 then parts[#parts+1] = at(L.a1) .. ' to ' .. at(L.a2) end
            if L.b1 then parts[#parts+1] = at(L.b1) .. ' to ' .. at(L.b2) end
            return parts
          end)(), ', then '))
      end
      -- legs passing within reach of a worm or spawner the map shows (robots fly straight): one read of the map's
      -- structures over the chunks near every leg (CHUNKS a call; the rest said unread)
      local av = api.avoid and api.avoid()
      if av then
        table.sort(legs, function(x, y) return x.len > y.len end)
        local seen, picked, chunks, have = {}, {}, {}, {}
        for _, l in ipairs(legs) do
          local k = math.floor(l.from.x / 8) .. ',' .. math.floor(l.from.y / 8) .. ',' .. math.floor(l.to.x / 8) .. ',' .. math.floor(l.to.y / 8)
          if not seen[k] and #picked < M.LEGS then
            seen[k] = true; picked[#picked+1] = l
            for _, ch in ipairs(try(function() return av.chunks_near({l.from, l.to}, 48) end) or {}) do
              if not have[ch[3]] then have[ch[3]] = true; chunks[#chunks+1] = ch end
            end
          end
        end
        local got = try(function() return av.structures(s, force, chunks, M.CHUNKS) end)
        for _, l in ipairs(got and picked or {}) do
          local hit
          for _, e in ipairs(got.list or {}) do
            local reach = av.reach(e.name, e.spawner)
            local d = av.seg_dist(l.from, l.to, e)
            if d <= reach and (not hit or d - reach < hit.d - hit.reach) then hit = {e=e, d=d, reach=reach} end
          end
          if hit then
            -- (d18 batch38 A3, Astra: a warned worm read as dead; a live scan found it) the read's age and whether its
            -- chunk is in sight now (radar or a character), so a right warning reads as one
            local e = hit.e
            local age = e.seen and math.floor((game.tick - e.seen) / 60 + 0.5)
            local sight = e.cx and try(function() return force.is_chunk_visible(s, {x=e.cx, y=e.cy}) end)
            lines[#lines+1] = string.format('the leg %s to %s (%d tiles, %d trips) passes %d tiles from %s %s (reach %d; %s%s)', at(l.from), at(l.to), math.floor(l.len + 0.5), l.n,
              math.floor(hit.d + 0.5), e.name, at(e), hit.reach, age and string.format('read %ds ago', age) or 'read now',
              sight == true and ', its chunk in sight now' or sight == false and ', its chunk charted, not in sight now' or '')
          end
        end
        if got and (got.unread or 0) > 0 then
          lines[#lines+1] = string.format('%d of the %d map chunks near the legs not read for enemies yet (a read reads %d)', got.unread, #chunks, M.CHUNKS)
        end
      end
    end
    local none = {}
    for _, g in ipairs(order) do
      if g.kind == 'construct' and g.holds == 0 then
        lines[#lines+1] = string.format('%d %s ghost%s near %s: network %d covering %s holds no %s', g.n, g.item, g.n == 1 and '' or 's',
          at({x=g.sx / g.n, y=g.sy / g.n}), g.net_id, g.n == 1 and 'it' or 'them', g.item)
      elseif g.no_source and #none < 4 then none[#none+1] = string.format('%d %s for %s', g.n, g.kind, g.item) end
    end
    if #none > 0 then lines[#lines+1] = 'no chest of the network to take from or put into for ' .. table.concat(none, ', ') end
    -- (B2, Haiku) a ghost outside every roboport's construction area: the nearest roboport and how far outside its area
    -- (the area is a square round it); cells of our networks on the surface, the first MAX_CELLS
    local cells
    for _, g in ipairs(order) do
      if g.uncovered and g.kind ~= 'deliver' then
        if not cells then
          cells = {}
          for _, n in pairs(try(function() return force.logistic_networks[s.name] end) or {}) do
            for _, c in ipairs(try(function() return n.cells end) or {}) do
              local o = c.owner
              local r = try(function() return c.construction_radius end) or 0
              if #cells < M.MAX_CELLS and o and o.valid and r > 0 and not try(function() return c.mobile end) then cells[#cells+1] = {o=o, r=r, id=n.network_id} end
            end
          end
        end
        local best, bo
        for _, c in ipairs(cells) do
          local out = math.max(math.abs(c.o.position.x - g.uncovered.x), math.abs(c.o.position.y - g.uncovered.y)) - c.r
          if not bo or out < bo then best, bo = c, out end
        end
        lines[#lines+1] = string.format('%d %s %s near %s: no roboport\'s construction area covers %s%s', g.n, g.item, g.kind == 'construct' and (g.n == 1 and 'ghost' or 'ghosts') or 'jobs',
          at(g.uncovered), g.n == 1 and 'it' or 'them',
          best and string.format('; the nearest roboport, %s %s (network %d), covers %d tiles round it, and %s %d tiles outside that', best.o.name, at(best.o.position), best.id, best.r,
            g.n == 1 and 'it is' or 'their middle is', math.ceil(bo)) or '; no roboport of ours with a construction area on this surface')
      end
    end
    if uncovered > 0 then lines[#lines+1] = string.format('%d job%s no logistic network covers', uncovered, uncovered == 1 and '' or 's') end
    return #lines > 0 and lines or nil, {trips=trips, long=long_n, longest=longest and math.floor(longest.len + 0.5) or nil}
  end
  -- The jobs of entities a deconstruction would mark: the entity's item and what it holds.
  function M.deconstruct_job(e)
    local pr = try(function() return e.prototype.mineable_properties.products end)
    local item = pr and pr[1] and pr[1].type ~= 'fluid' and pr[1].name or nil
    if not item then return nil end
    return {kind='deconstruct', pos=e.position, item=item, count=1, contents=try(function() return e.get_item_count() end) or 0}
  end
  return M
end
