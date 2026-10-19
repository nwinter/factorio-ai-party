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
      -- (d17 batch34 A1) a ghost over a live entity of ours not marked for upgrade or deconstruction
      local under, kind
      if t and t.type == 'entity-ghost' then under, kind = M.under(t) end
      if under then
        return string.format('its target %s ghost %s stands over our live %s, not marked for %s', t.ghost_name, at(t.position), under.name, kind and 'upgrade' or 'deconstruction')
      end
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
  -- (d17 batch34 A1, Astra: ~65 medium-pole ghosts stood over live small poles while ghosts read "robots can build it";
  -- robots held poles until the small poles were marked for upgrade) A live entity of ours on an entity ghost's spot
  -- whose collision layers meet the ghost's, marked neither for upgrade nor for deconstruction: robots do not build
  -- the ghost until it is. Returns that entity and whether it is of the ghost's kind (another name of the same
  -- fast-replace group and size: the upgrade planner marks it), or nil.
  local MOVERS = {character=true, car=true, ['spider-vehicle']=true, locomotive=true, ['cargo-wagon']=true, ['fluid-wagon']=true,
    ['artillery-wagon']=true, ['entity-ghost']=true, ['tile-ghost']=true, ['item-request-proxy']=true}
  local function layers(proto) return try(function() return proto.collision_mask.layers end) or {} end
  local function box_size(b) return b and string.format('%.2fx%.2f', b.right_bottom.x - b.left_top.x, b.right_bottom.y - b.left_top.y) end
  function M.under(g)
    if not (g.valid and g.type == 'entity-ghost') then return nil end
    local gp, b = try(function() return g.ghost_prototype end), try(function() return g.bounding_box end)
    if not (gp and b) then return nil end
    -- shrunk so that what only touches its edge is left out (a pole's box is 0.3 a side)
    local dx = math.min(0.1, (b.right_bottom.x - b.left_top.x) / 4, (b.right_bottom.y - b.left_top.y) / 4)
    local box = {{b.left_top.x + dx, b.left_top.y + dx}, {b.right_bottom.x - dx, b.right_bottom.y - dx}}
    if box[2][1] <= box[1][1] or box[2][2] <= box[1][2] then return nil end
    local gl = layers(gp)
    for _, e in ipairs(try(function() return g.surface.find_entities_filtered{area=box, force=g.force, limit=8} end) or {}) do
      if e.valid and e ~= g and not MOVERS[e.type] and not e.to_be_deconstructed() and not e.to_be_upgraded() then
        local el = layers(e.prototype)
        for k in pairs(gl) do
          if el[k] then
            local g1, g2 = gp.fast_replaceable_group, e.prototype.fast_replaceable_group
            return e, g1 ~= nil and g1 == g2 and e.name ~= gp.name and box_size(gp.collision_box) == box_size(e.prototype.collision_box)
          end
        end
      end
    end
  end
  -- The ghosts M.under finds, as lines: per pair of names, how many and the call that marks what stands under them
  -- (upgrade for one of its kind, else deconstruct), over the pairs' area when it fits the call's area, else positions.
  -- list: {{ghost=, under=, kind=}}; where: ', surface: "x"' or ''.
  function M.under_lines(list, where)
    local groups, order = {}, {}
    for _, x in ipairs(list) do
      local key = x.ghost.ghost_name .. '|' .. x.under.name
      local gr = groups[key]
      if not gr then gr = {ghost=x.ghost.ghost_name, under=x.under.name, kind=x.kind, pos={}}; groups[key] = gr; order[#order+1] = gr end
      gr.pos[#gr.pos+1] = x.under.position
    end
    table.sort(order, function(x, y) if #x.pos ~= #y.pos then return #x.pos > #y.pos end return x.ghost < y.ghost end)
    local lines = {}
    for _, gr in ipairs(order) do
      local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
      for _, q in ipairs(gr.pos) do x0, y0, x1, y1 = math.min(x0, q.x), math.min(y0, q.y), math.max(x1, q.x), math.max(y1, q.y) end
      x0, y0, x1, y1 = math.floor(x0 - 1), math.floor(y0 - 1), math.ceil(x1 + 1), math.ceil(y1 + 1)
      local fits = x1 - x0 <= (gr.kind and 128 or 256) and y1 - y0 <= (gr.kind and 128 or 256)
      local target
      if fits then target = string.format('area: [[%d,%d],[%d,%d]]', x0, y0, x1, y1)
      else
        local ps = {}
        for i = 1, math.min(16, #gr.pos) do ps[i] = string.format('[%g,%g]', gr.pos[i].x, gr.pos[i].y) end
        target = 'positions: [' .. table.concat(ps, ',') .. ']'
      end
      local call = gr.kind and string.format('upgrade {%s, from: "%s", to: "%s"%s}', target, gr.under, gr.ghost, where)
        or string.format('deconstruct {%s, entity_names: ["%s"]%s}', fits and target or string.format('area: [[%g,%g],[%g,%g]]', gr.pos[1].x - 1, gr.pos[1].y - 1, gr.pos[1].x + 1, gr.pos[1].y + 1), gr.under, where)
      lines[#lines+1] = string.format('%d %s ghost%s over our live %s, not marked for %s: robots do not build %s until it is; %s marks %s%s', #gr.pos, gr.ghost,
        #gr.pos == 1 and '' or 's', gr.under, gr.kind and 'upgrade' or 'deconstruction', #gr.pos == 1 and 'it' or 'them', call,
        #gr.pos == 1 and 'it' or 'them', (not fits and #gr.pos > (gr.kind and 16 or 1)) and string.format(' (the first %d; the ghosts read lists the rest)', gr.kind and 16 or 1) or '')
    end
    return lines
  end
  local function network_for(p, a)
    local surface = p.surface
    -- (d18 batch40 A2, Astra on Wayfarer) a space platform: its hub builds, no roboport (2.0.77 on world n: Wayfarer's
    -- hub has no logistic network and its surface none)
    local pl = try(function() return surface.platform end)
    if pl and not next(try(function() return p.force.logistic_networks[surface.name] end) or {}) then
      error(string.format('platform %s (surface %s) has no roboport or construction robot: its hub builds ghosts from its own inventory; ghosts {surface: "%s"} gives what holds each (the foundation under it, the hub\'s count of its item and its requests)',
        pl.name, surface.name, surface.name), 0)
    end
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
  -- chest robots would take that item from, and whether the straight line from it to the group passes within the reach
  -- of a worm or spawner the map shows (a worm's range, a spawner's units' 40 tiles). Facts the map and the network's GUI
  -- give; robots fly straight. Bounded: 1000 ghosts, 16 groups.
  -- (d19 batch41 D2, operator d18 19:02: 24 ms on network 243 of world n; 17.7 ms there on the private copy, 299 ghosts
  -- and 491 chests) bounded: the ghosts read by squares SQUARE tiles a side of the construction area,
  -- from a square (sources_from) up to PER_CALL squares, stopping after the square that brings GHOSTS_CALL ghosts (one
  -- find over its 582x734 box was 4.6 ms; a square of 16,853 entities 3.9 ms), an entity ghost's item read once a
  -- ghost name (2.9 ms for 299 ghosts), per group the one chest the game would take it from instead of every chest
  -- (about 3 ms), and one budget of SCAN_CHUNKS map chunks read a call for the worm checks (it was 64 a line).
  local MAX_GHOSTS, MAX_GROUPS, SCAN_CHUNKS, SQUARE, PER_CALL, GHOSTS_CALL = 1000, 12, 64, 128, 4, 60
  local ghost_items = {}
  local function item_of_ghost(g)
    if g.type == 'entity-ghost' then
      local gn = try(function() return g.ghost_name end)
      if gn and ghost_items[gn] ~= nil then return ghost_items[gn] or nil, 1 end
      local it = try(function() return g.ghost_prototype.items_to_place_this[1] end)
      local name = it and (type(it.name) == 'string' and it.name or try(function() return it.name.name end))
      if gn then ghost_items[gn] = name or false end
      return name, 1
    end
    for _, r in ipairs(try(function() return g.item_requests end) or {}) do
      local n = type(r.name) == 'string' and r.name or try(function() return r.name.name end)
      if n then return n, r.count or 1 end
    end
  end
  function M.sources(p, net, page)
    local av = api.avoid and api.avoid()
    local s, f = p.surface, p.force
    local box
    local squares_of = {}
    for _, c in ipairs(try(function() return net.cells end) or {}) do
      local o = c.owner
      local r = try(function() return c.construction_radius end) or 0
      if o and o.valid and not try(function() return c.mobile end) and r > 0 then
        local x, y = o.position.x, o.position.y
        squares_of[#squares_of+1] = {x - r, y - r, x + r, y + r}
        box = box and {math.min(box[1], x - r), math.min(box[2], y - r), math.max(box[3], x + r), math.max(box[4], y + r)} or {x - r, y - r, x + r, y + r}
      end
    end
    if not box then return {'the network has no roboport with a construction area'} end
    -- the squares of the box that a construction area reaches, in reading order; this call's from `from`
    local squares = {}
    for y = box[2], box[4] - 0.001, SQUARE do
      for x = box[1], box[3] - 0.001, SQUARE do
        local q = {x, y, math.min(x + SQUARE, box[3]), math.min(y + SQUARE, box[4])}
        for _, a in ipairs(squares_of) do
          if a[1] < q[3] and a[3] > q[1] and a[2] < q[4] and a[4] > q[2] then squares[#squares+1] = q; break end
        end
      end
    end
    local from = page or 1
    assert(type(from) == 'number' and from == math.floor(from) and from >= 1 and from <= math.max(1, #squares), 'sources_from: 1..' .. math.max(1, #squares) .. ' (a square of the construction area)')
    local ghosts, last = {}, from - 1
    for k = from, math.min(#squares, from + PER_CALL - 1) do
      local q = squares[k]
      for _, g in ipairs(try(function() return s.find_entities_filtered{area={{q[1], q[2]}, {q[3], q[4]}}, type={'entity-ghost', 'item-request-proxy'}, force=f, limit=MAX_GHOSTS - #ghosts} end) or {}) do
        -- a ghost on a square's edge is read once
        local gp = g.position
        local inx = (gp.x >= q[1] or q[1] <= box[1]) and (gp.x < q[3] or q[3] >= box[3])
        local iny = (gp.y >= q[2] or q[2] <= box[2]) and (gp.y < q[4] or q[4] >= box[4])
        if inx and iny then ghosts[#ghosts+1] = g end
      end
      last = k
      if #ghosts >= GHOSTS_CALL then break end
    end
    local page_line = (from > 1 or last < #squares) and string.format('ghosts read in square%s %s of the %d squares (%d tiles a side) the construction area covers%s',
      last > from and 's' or '', last > from and from .. '-' .. last or tostring(from), #squares, SQUARE,
      last < #squares and string.format('; sources_from: %d reads on', last + 1) or '; the last of them') or nil
    local groups, order = {}, {}
    for _, g in ipairs(ghosts) do
      if g.valid and try(function() return net.find_cell_closest_to(g.position) end) then
        local item, n = item_of_ghost(g)
        if item then
          local k = item .. '|' .. math.floor(g.position.x / 32) .. '|' .. math.floor(g.position.y / 32)
          local gr = groups[k]
          if not gr then gr = {item=item, key=k, n=0, count=0, sx=0, sy=0, kind=g.type == 'entity-ghost' and 'ghost' or 'item request'}; groups[k] = gr; order[#order+1] = gr end
          gr.n = gr.n + 1; gr.count = gr.count + n; gr.sx = gr.sx + g.position.x; gr.sy = gr.sy + g.position.y
        end
      end
    end
    if #order == 0 then return {page_line and 'no ghost or item request waits there (' .. page_line .. ')' or 'no ghost or item request waits in its construction area'} end
    table.sort(order, function(x, y) return x.n > y.n end)
    -- (d18 batch38 A4, Astra: north big poles read short while robots carried them) per group, the robots in the air with
    -- an order on one of its ghosts that hold its item: in transit, said first; the shortage only of the rest
    local carried = {}
    for i, r in ipairs(try(function() return net.construction_robots end) or {}) do
      if i > 1000 then break end
      local inv = r.valid and try(function() return r.get_inventory(defines.inventory.robot_cargo) end)
      for _, o in ipairs(inv and try(function() return r.robot_order_queue end) or {}) do
        local t = o.target and try(function() return o.target.valid and o.target end)
        if t and (t.type == 'entity-ghost' or t.type == 'item-request-proxy') then
          local item = item_of_ghost(t)
          local n = item and try(function() return inv.get_item_count(item) end) or 0
          if n > 0 then
            local k = item .. '|' .. math.floor(t.position.x / 32) .. '|' .. math.floor(t.position.y / 32)
            local c = carried[k] or {robots=0, count=0}
            c.robots, c.count = c.robots + 1, c.count + n
            local d = ((r.position.x - t.position.x) ^ 2 + (r.position.y - t.position.y) ^ 2) ^ 0.5
            if not c.near or d < c.near then c.near = d end
            carried[k] = c
            break
          end
        end
      end
    end
    -- (d19 batch41 D2) per group the chest the network's robots would take its item from now (the game's pickup choice,
    -- LuaLogisticNetwork.select_pickup_point from the group's centre; about 0.1 ms an item on the private copy, where
    -- reading the network's 491 chests was about 3 ms), with the network's total, and whether the straight line from it
    -- passes within reach of a worm or spawner; one budget of SCAN_CHUNKS map chunks read a call for those lines.
    local scan_left = SCAN_CHUNKS
    local lines = {page_line}
    for gi, gr in ipairs(order) do
      if gi > MAX_GROUPS then lines[#lines+1] = string.format('+%d more groups', #order - MAX_GROUPS); break end
      local c = {x=gr.sx / gr.n, y=gr.sy / gr.n}
      local parts = {}
      local pt = try(function() return net.select_pickup_point{name=gr.item, position=c} end)
      local o = pt and try(function() return pt.owner end)
      local total = try(function() return net.get_item_count(gr.item) end) or 0
      if o and o.valid then
        local n = try(function() return o.get_item_count(gr.item) end) or 0
        local d = ((o.position.x - c.x) ^ 2 + (o.position.y - c.y) ^ 2) ^ 0.5
        local crossing
        if av then
          local path = av.chunks_near({o.position, c}, 48)
          local miss = #path <= 256 and #av.missing(s, path) or 0
          if #path > 256 then crossing = 'unread'
          elseif miss > scan_left then crossing = 'budget'
          else
            local got = av.structures(s, f, path, scan_left)
            scan_left = scan_left - miss
            for _, e in ipairs(got.list) do
              local reach = av.reach(e.name, e.spawner)
              local dd = av.seg_dist(o.position, c, e)
              if dd <= reach and (not crossing or dd - reach < crossing.d - crossing.reach) then crossing = {e=e, d=dd, reach=reach} end
            end
          end
        end
        parts[#parts+1] = string.format('robots would take it from %s %s (holds %d; the network %d), %d tiles: %s', o.name, at(o.position), n, total, math.floor(d + 0.5),
          crossing == 'unread' and 'the line is too long to read'
          or crossing == 'budget' and string.format('the line was not read in this call (%d map chunks a call are read for these lines; the next call reads on)', SCAN_CHUNKS)
          or crossing and string.format('the straight line passes %d tiles from %s %s (reach %d)', math.floor(crossing.d + 0.5), crossing.e.name, at(crossing.e), crossing.reach)
          or 'the straight line passes within reach of no worm or spawner the map shows')
      elseif total > 0 then
        parts[#parts+1] = string.format('the network counts %d and the game names no chest to take it from', total)
      end
      local cr = carried[gr.key]
      local rest = gr.n - (cr and math.min(cr.robots, gr.n) or 0)
      lines[#lines+1] = string.format('%d %s%s for %s near %s: %s%s', gr.n, gr.kind, gr.n == 1 and '' or 's', gr.item, at(c),
        cr and string.format('%d in transit in construction robots\' cargo (%d %s, the nearest %d tiles off)%s', math.min(cr.robots, gr.n), cr.count, gr.item, math.floor(cr.near + 0.5),
          rest > 0 and string.format('; for the other %d: ', rest) or '') or '',
        rest == 0 and '' or (#parts > 0 and table.concat(parts, '; ') or 'no chest in the network holds it'))
    end
    return lines
  end
  function M.read(p, a)
    local net = network_for(p, a)
    local flying = try(function() return net.construction_robots end) or {}
    local rows, held_up, cache, waits = {}, 0, {}, {}
    local blocked, blocked_seen = {}, {}
    for i, r in ipairs(flying) do
      if r.valid then
        local line, stuck, why, queue = M.row(r, net, cache)
        for _, o in ipairs(queue) do
          local t = o.target and try(function() return o.target.valid and o.target end)
          local u = t and t.type == 'entity-ghost' and try(function() return t.unit_number end)
          if u and blocked_seen[u] == nil and #blocked < 512 then
            local under, kind = M.under(t)
            blocked_seen[u] = under ~= nil
            if under then blocked[#blocked+1] = {ghost=t, under=under, kind=kind} end
          end
        end
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
      ghosts_blocked=#blocked > 0 and M.under_lines(blocked, a._where or '') or nil,
      sources=a.sources and M.sources(p, net, a.sources_from) or nil}
  end
  M.schema = {
    construction_robots = {position='optional {x,y}: the network covering it (default where you stand)',
      network='optional network id (the networks read lists them) instead of position',
      surface='optional planet name: read there by remote view',
      sources_from='with sources: the square of the construction area to read from (default 1; squares of 128 tiles a side, 4 a call, fewer once 60 ghosts are read; the first sources line names the next)',
      sources='true: sources: per group of ghosts and item requests waiting in the construction area (by item, 32-tile cells; the largest 12; read 4 squares of 128 tiles a call, sources_from), the chest the network\'s robots would take that item from now (the game\'s pickup choice): what it holds, the network\'s total, how far, and whether the straight line from it to the group passes within reach of a worm or spawner the map shows (which, how near, its reach; 64 map chunks read a call for those lines, a line past them says so)',
      returns='network, summary (construction robots: in roboports, in the air, held up; roboports; storage chests), robots: one line each for those in the air (the first 32; robots_more): position, energy %, what it holds, its orders (construct, deconstruct, upgrade, repair, deliver, pickup, explode_cliff: target and item, the first 3) and what holds it up: no charge (energy under 1%, in no roboport\'s queue), nowhere to put what it holds (no storage chest in the network has room for it), its target outside the network\'s construction area, waiting to charge at a roboport (its place in the queue), charging, outside every network\'s area; charging_queues: roboports with robots waiting to charge; ghosts_waiting: each ghost in a held-up robot\'s queue (the first 32): the robot, the order\'s place in its queue, what holds it up; ghosts_blocked: the ghosts in the orders of robots in the air that stand over a live entity of ours whose collision meets theirs, not marked for upgrade or deconstruction (robots do not build them until it is; a robot\'s line says it of its target), per ghost and entity name: how many and the upgrade call that marks them (another name of the same fast-replace group and size), else the deconstruct call. Read only'},
  }
  return M
end
