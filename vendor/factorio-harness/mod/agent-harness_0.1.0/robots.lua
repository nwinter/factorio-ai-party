-- construction_robots (Astra, shift13: Fulgora's only construction robot stalled 3 times holding removed modules
-- with no storage slot for them; finding out why took about 15 minutes): the construction robots of one logistic
-- network, each in the air with where it is, its charge, what it carries, its orders and targets, and what holds it
-- up, read from the engine as a player reads robots by hovering them and the network's GUI. Read only.
-- On a copy of world n (2.0.77): LuaLogisticNetwork.construction_robots lists the robots in the air (those in
-- roboports are counts only); robot_order_queue gives {type (defines.robot_order_type), target, target_item,
-- target_count}; a robot holding items with no order and no drop point (select_drop_point nil) has nowhere to put
-- them and hovers; a construction robot's max energy is 3 MJ.
return function(api)
  local M = {}
  local MAX_ROWS = 32
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function at(pos) return string.format('(%g,%g)', math.floor(pos.x * 10 + 0.5) / 10, math.floor(pos.y * 10 + 0.5) / 10) end
  local ORDER = {}
  for name, v in pairs(defines.robot_order_type or {}) do ORDER[v] = name end
  local function stacks(inv)
    local out = {}
    for _, st in ipairs(inv and try(function() return inv.get_contents() end) or {}) do
      local q = type(st.quality) == 'table' and st.quality.name or st.quality
      out[#out+1] = {name=st.name, quality=q, count=st.count, text=st.name .. (q and q ~= 'normal' and '@' .. q or '') .. '*' .. st.count}
    end
    return out
  end
  -- One order in words: "construct assembling-machine-2 at (12.5,3.5)", "deconstruct ... (removing it)", with the item.
  local function order_text(o)
    local kind = ORDER[o.type] or tostring(o.type)
    local t = o.target and try(function() return o.target.valid and o.target end)
    local name = t and (t.type == 'entity-ghost' and t.ghost_name .. ' ghost' or t.name)
    -- target_item.name is an item prototype on 2.0.77 (a pickup's {name, quality}), a string elsewhere.
    local item = o.target_item and try(function()
      local i = o.target_item
      local n = type(i.name) == 'string' and i.name or i.name.name
      return n .. (o.target_count and o.target_count > 1 and '*' .. o.target_count or '')
    end)
    local parts = {kind}
    if name then parts[#parts+1] = name .. ' at ' .. at(t.position) end
    if item then parts[#parts+1] = '(item ' .. item .. ')' end
    return table.concat(parts, ' '), t
  end
  local function cell_of(net, pos) return try(function() return net.find_cell_closest_to(pos) end) end
  local function member(list, e)
    for i, x in ipairs(list or {}) do if x == e then return i end end
  end
  -- What holds robot r up, or nil: no room for what it carries, its target outside the construction area, a charging
  -- queue, no network.
  -- A roboport's charging and waiting robots, read once per read (cache: owner unit -> lists).
  local function queues(cell, cache)
    local key = try(function() return cell.owner.unit_number end) or cell
    local q = cache and cache[key]
    if not q then
      q = {charging=try(function() return cell.charging_robots end) or {}, waiting=try(function() return cell.to_charge_robots end) or {}}
      if cache then cache[key] = q end
    end
    return q.charging, q.waiting
  end
  local function blocker(r, net, cargo, orders, cache, pct)
    if not net then return 'outside every logistic network\'s area' end
    local cell = cell_of(net, r.position)
    if cell then
      local charging, waiting = queues(cell, cache)
      local owner = try(function() return cell.owner.name .. ' ' .. at(cell.owner.position) end) or 'its roboport'
      if member(charging, r) then return 'charging at ' .. owner end
      local k = member(waiting, r)
      if k then return string.format('waiting to charge at %s: %d of %d in its queue (%d charging now)', owner, k, #waiting, #(charging or {})) end
    end
    if #orders == 0 and #cargo > 0 then
      local nowhere = {}
      for _, st in ipairs(cargo) do
        local dp = try(function() return net.select_drop_point{stack={name=st.name, count=st.count, quality=st.quality}} end)
        if not dp then nowhere[#nowhere+1] = st.text end
      end
      if #nowhere > 0 then
        local storages = try(function() return #net.storages end) or 0
        return string.format('nowhere to put %s: no storage chest in network %d has room for it (%d storage chest%s in it)',
          table.concat(nowhere, ' '), net.network_id, storages, storages == 1 and '' or 's')
      end
    end
    -- (d17 batch18 B3) no charge left, in no roboport's queue
    if pct and pct < 1 then return 'no charge (energy 0%)' end
    for _, o in ipairs(orders) do
      local t = o.target and try(function() return o.target.valid and o.target end)
      if t then
        local c = cell_of(net, t.position)
        if c and try(function() return c.is_in_construction_range(t.position) end) == false then
          return string.format('its target %s %s is outside the network\'s construction area', t.type == 'entity-ghost' and t.ghost_name or t.name, at(t.position))
        end
      end
    end
  end
  -- One robot's line: "construction-robot (-121.5,436): energy 82%; holds wood*4; no order; nowhere to put wood*4: ...".
  function M.row(r, net, cache)
    local energy = try(function() return r.energy end) or 0
    local max = try(function() return r.prototype.get_max_energy and r.prototype.get_max_energy() end) or try(function() return r.prototype.max_energy end) or 3000000
    local cargo = stacks(try(function() return r.get_inventory(defines.inventory.robot_cargo) end))
    local queue = try(function() return r.robot_order_queue end) or {}
    local pct = energy * 100 / math.max(1, max)
    local parts = {string.format('energy %d%%', math.floor(pct + 0.5))}
    local held = {}
    for i, st in ipairs(cargo) do held[i] = st.text end
    parts[#parts+1] = #held > 0 and 'holds ' .. table.concat(held, ' ') or 'holds nothing'
    if #queue == 0 then parts[#parts+1] = 'no order'
    else
      local list = {}
      for i = 1, math.min(3, #queue) do list[i] = (order_text(queue[i])) end
      parts[#parts+1] = 'order' .. (#queue > 1 and 's' or '') .. ': ' .. table.concat(list, '; then ') .. (#queue > 3 and string.format(' (+%d more)', #queue - 3) or '')
    end
    local why = blocker(r, net, cargo, queue, cache, pct)
    if why then parts[#parts+1] = why end
    return string.format('%s %s: %s', r.name, at(r.position), table.concat(parts, '; ')), why ~= nil, why, queue
  end
  local function network_for(p, a)
    local surface = p.surface
    if a.network ~= nil then
      assert(type(a.network) == 'number', 'network is a network id (the networks read lists them)')
      for _, net in pairs(try(function() return p.force.logistic_networks[surface.name] end) or {}) do
        if net.valid and net.network_id == a.network then return net end
      end
      error(string.format('no logistic network %d of ours on %s', a.network, surface.name), 0)
    end
    local pos = a.position and api.position(a.position) or p.position
    local net = try(function() return p.force.find_logistic_network_by_position(pos, surface) end)
    if net then return net end
    -- The nearest network's roboport: what the refusal names.
    local best, bd
    for _, n in pairs(try(function() return p.force.logistic_networks[surface.name] end) or {}) do
      for _, c in ipairs(n.valid and n.cells or {}) do
        local o = c.owner
        local d = o and o.valid and ((o.position.x - pos.x) ^ 2 + (o.position.y - pos.y) ^ 2) ^ 0.5
        if d and (not bd or d < bd) then best, bd = {net=n, owner=o}, d end
      end
    end
    error(string.format('no logistic network of ours covers %s on %s%s', at(pos), surface.name,
      best and string.format('; the nearest: network %d, %s %s, %.0f tiles away', best.net.network_id, best.owner.name, at(best.owner.position), bd) or ''), 0)
  end
  -- sources (E5, Sol 19:50: about 13 construction robots lost on a uranium line, the storage chests across worms): per
  -- group of pending ghosts and item requests in the network's construction area (by item and 32-tile cell), the
  -- network's chests holding that item, nearest first (3), and whether the straight line from each to the group passes
  -- within the reach of a worm or spawner the map shows (a worm's range, a spawner's units' 40 tiles). Facts the map and
  -- the network's GUI give; robots fly straight. Bounded: 1000 ghosts, 16 groups, 512 chests read.
  local MAX_GHOSTS, MAX_GROUPS, MAX_CHESTS = 1000, 16, 512
  local function item_of_ghost(g)
    if g.type == 'entity-ghost' then
      local it = try(function() return g.ghost_prototype.items_to_place_this[1] end)
      return it and (type(it.name) == 'string' and it.name or try(function() return it.name.name end)), 1
    end
    for _, r in ipairs(try(function() return g.item_requests end) or {}) do
      local n = type(r.name) == 'string' and r.name or try(function() return r.name.name end)
      if n then return n, r.count or 1 end
    end
  end
  function M.sources(p, net)
    local av = api.avoid and api.avoid()
    local s, f = p.surface, p.force
    local box
    for _, c in ipairs(try(function() return net.cells end) or {}) do
      local o = c.owner
      local r = try(function() return c.construction_radius end) or 0
      if o and o.valid and not try(function() return c.mobile end) and r > 0 then
        local x, y = o.position.x, o.position.y
        box = box and {math.min(box[1], x - r), math.min(box[2], y - r), math.max(box[3], x + r), math.max(box[4], y + r)} or {x - r, y - r, x + r, y + r}
      end
    end
    if not box then return {'the network has no roboport with a construction area'} end
    local ghosts = try(function() return s.find_entities_filtered{area={{box[1], box[2]}, {box[3], box[4]}}, type={'entity-ghost', 'item-request-proxy'}, force=f, limit=MAX_GHOSTS} end) or {}
    local groups, order = {}, {}
    for _, g in ipairs(ghosts) do
      if g.valid and try(function() return net.find_cell_closest_to(g.position) end) then
        local item, n = item_of_ghost(g)
        if item then
          local k = item .. '|' .. math.floor(g.position.x / 32) .. '|' .. math.floor(g.position.y / 32)
          local gr = groups[k]
          if not gr then gr = {item=item, n=0, count=0, sx=0, sy=0, kind=g.type == 'entity-ghost' and 'ghost' or 'item request'}; groups[k] = gr; order[#order+1] = gr end
          gr.n = gr.n + 1; gr.count = gr.count + n; gr.sx = gr.sx + g.position.x; gr.sy = gr.sy + g.position.y
        end
      end
    end
    if #order == 0 then return {'no ghost or item request waits in its construction area'} end
    table.sort(order, function(x, y) return x.n > y.n end)
    local chests = {}
    for _, list in ipairs({try(function() return net.storages end) or {}, try(function() return net.providers end) or {}}) do
      for i, e in ipairs(list) do
        if #chests >= MAX_CHESTS then break end
        if e.valid and (e.type == 'logistic-container' or e.type == 'container') then chests[#chests+1] = e end
      end
    end
    local holders = {}
    local lines = {}
    for gi, gr in ipairs(order) do
      if gi > MAX_GROUPS then lines[#lines+1] = string.format('+%d more groups', #order - MAX_GROUPS); break end
      local c = {x=gr.sx / gr.n, y=gr.sy / gr.n}
      if not holders[gr.item] then
        local h, seen = {}, {}
        for _, e in ipairs(chests) do
          local n = not seen[e.unit_number] and try(function() return e.get_item_count(gr.item) end) or 0
          seen[e.unit_number] = true
          if n > 0 then h[#h+1] = {e=e, n=n} end
        end
        holders[gr.item] = h
      end
      local near = {}
      for _, h in ipairs(holders[gr.item]) do near[#near+1] = {e=h.e, n=h.n, d=((h.e.position.x - c.x) ^ 2 + (h.e.position.y - c.y) ^ 2) ^ 0.5} end
      table.sort(near, function(x, y) return x.d < y.d end)
      local parts = {}
      for i = 1, math.min(3, #near) do
        local h = near[i]
        local crossing
        if av then
          local path = av.chunks_near({h.e.position, c}, 48)
          if #path <= 256 then
            local got = av.structures(s, f, path, 64)
            for _, e in ipairs(got.list) do
              local reach = av.reach(e.name, e.spawner)
              local d = av.seg_dist(h.e.position, c, e)
              if d <= reach and (not crossing or d - reach < crossing.d - crossing.reach) then crossing = {e=e, d=d, reach=reach} end
            end
          else crossing = 'unread' end
        end
        parts[#parts+1] = string.format('%s %s holds %d, %d tiles: %s', h.e.name, at(h.e.position), h.n, math.floor(h.d + 0.5),
          crossing == 'unread' and 'the line is too long to read' or crossing and string.format('the straight line passes %d tiles from %s %s (reach %d)',
            math.floor(crossing.d + 0.5), crossing.e.name, at(crossing.e), crossing.reach) or 'the straight line passes within reach of no worm or spawner the map shows')
      end
      lines[#lines+1] = string.format('%d %s%s for %s near %s: %s', gr.n, gr.kind, gr.n == 1 and '' or 's', gr.item, at(c),
        #parts > 0 and table.concat(parts, '; ') or 'no chest in the network holds it')
    end
    return lines
  end
  function M.read(p, a)
    local net = network_for(p, a)
    local flying = try(function() return net.construction_robots end) or {}
    local rows, held_up, cache, waits = {}, 0, {}, {}
    for i, r in ipairs(flying) do
      if r.valid then
        local line, stuck, why, queue = M.row(r, net, cache)
        if stuck then
          held_up = held_up + 1
          -- (d17 batch18 B3, Astra) the ghosts in a held-up robot's queue wait on it
          for k, o in ipairs(queue) do
            local t = o.target and try(function() return o.target.valid and o.target end)
            if t and (t.type == 'entity-ghost' or t.type == 'tile-ghost') and #waits < MAX_ROWS then
              waits[#waits+1] = string.format('%s ghost %s waits on %s %s (its order %d of %d): %s', t.ghost_name, at(t.position), r.name, at(r.position), k, #queue, why)
            end
          end
        end
        if #rows < MAX_ROWS then rows[#rows+1] = line end
      end
    end
    local all = try(function() return net.all_construction_robots end) or 0
    local idle = try(function() return net.available_construction_robots end) or 0
    local cells = try(function() return net.cells end) or {}
    local queues = {}
    for _, c in ipairs(cells) do
      local waiting = try(function() return c.to_charge_robot_count end) or 0
      local charging = try(function() return c.charging_robot_count end) or 0
      if waiting > 0 and c.owner and c.owner.valid then
        queues[#queues+1] = string.format('%s %s: %d waiting, %d charging', c.owner.name, at(c.owner.position), waiting, charging)
      end
    end
    local storages = try(function() return #net.storages end) or 0
    return {network=net.network_id,
      summary=string.format('network %d: %d construction robot%s (%d in roboports, %d in the air%s); %d roboport%s; %d storage chest%s',
        net.network_id, all, all == 1 and '' or 's', idle, #flying, held_up > 0 and string.format(', %d held up', held_up) or '',
        #cells, #cells == 1 and '' or 's', storages, storages == 1 and '' or 's'),
      robots=#rows > 0 and rows or nil, robots_more=#flying > #rows and #flying - #rows or nil,
      charging_queues=#queues > 0 and queues or nil, ghosts_waiting=#waits > 0 and waits or nil,
      sources=a.sources and M.sources(p, net) or nil}
  end
  M.schema = {
    construction_robots = {position='optional {x,y}: the network covering it (default where you stand)',
      network='optional network id (the networks read lists them) instead of position',
      surface='optional planet name: read there by remote view',
      sources='true: sources: per group of ghosts and item requests waiting in the construction area (by item, 32-tile cells; the largest 16), the network\'s chests holding that item, nearest first (3): what each holds, how far, and whether the straight line from it to the group passes within reach of a worm or spawner the map shows (which, how near, its reach)',
      returns='network, summary (construction robots: in roboports, in the air, held up; roboports; storage chests), robots: one line each for those in the air (the first 32; robots_more): position, energy %, what it holds, its orders (construct, deconstruct, upgrade, repair, deliver, pickup, explode_cliff: target and item, the first 3) and what holds it up: no charge (energy under 1%, in no roboport\'s queue), nowhere to put what it holds (no storage chest in the network has room for it), its target outside the network\'s construction area, waiting to charge at a roboport (its place in the queue), charging, outside every network\'s area; charging_queues: roboports with robots waiting to charge; ghosts_waiting: each ghost in a held-up robot\'s queue (the first 32): the robot, the order\'s place in its queue, what holds it up. Read only'},
  }
  return M
end
