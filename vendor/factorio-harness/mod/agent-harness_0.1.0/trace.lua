-- trace: how items move between machines, in one read. Shift09 00:20, Grok:
-- "the wall assembler was short of bricks that sat in the chest next to the
-- one its long inserter reads"; Luna: a science routing diagnostic took many
-- supply/inspect calls; Astra (00:30): an hour lost to mixed ore and chunks
-- backing up on Sunward. Three reads, on a planet or a platform (platform=):
-- trace {position}: per ingredient a machine or lab lacks (all: every one),
--   the inserters feeding it (status, filter, held), each one's pickup target
--   (a chest, a machine's output, a belt tile with its lanes) and how much of
--   the ingredient is there, and the nearest container within 10 tiles that
--   holds it and that no inserter reads.
-- trace {position, forward}: its output inserters and the belts they load,
--   followed lane by lane (undergrounds, splitters, side-loads) to where they
--   end (a chest, the hub, another machine, a belt end), with what each lane
--   carries and where it stops: a full lane whose front item nobody on it
--   takes, an inserter holding an item it cannot drop, a full target.
-- trace {position, forward} on a belt tile: that belt's lanes followed the
--   same way from there (Opus, 06:26: ore fed into a plate bus, 20 minutes of
--   cleanup).
-- Every walk names where other items join a lane it follows: the belt it
--   joins (side-loaded onto) carrying items it did not carry, a belt
--   side-loading other items onto it, a splitter's other input, an inserter
--   putting other items onto it.
-- trace {item}: the same walk from every machine making the item to the labs,
--   machines and chests that take it (on through a chest's own inserters),
--   and for each lab short of it the route that reaches it or the nearest
--   route tile. Bounded per read: 3000 belt tiles, 6 inserter hops, 24
--   routes, 48 makers, 1024 labs (cost says what it walked).
return function(api)
  local M = {}
  local H = api.supply.helpers
  local inventory, count, input_of, output_of, recipe_of, main = H.inventory, H.count, H.input_of, H.output_of, H.recipe_of, H.main
  local MAX_TILES, MAX_HOPS, MAX_ROUTES, MAX_MAKERS, MAX_INSERTERS, MAX_LABS, MAX_SHORT = 3000, 6, 24, 48, 8192, 1024, 10
  local NEAR, REACH = 10, 3
  local BELT = {['transport-belt']=true, ['underground-belt']=true, splitter=true, loader=true, ['loader-1x1']=true, ['linked-belt']=true, ['lane-splitter']=true}
  local CRAFTER = {['assembling-machine']=true, furnace=true, ['rocket-silo']=true}
  local CONTAINERS = {'container', 'logistic-container', 'cargo-landing-pad', 'space-platform-hub', 'cargo-wagon', 'car', 'spider-vehicle'}
  local CONTAINER = {}
  for _, t in ipairs(CONTAINERS) do CONTAINER[t] = true end
  local FULL = {waiting_for_space_in_destination=true, full_output=true, not_enough_space_in_output=true}

  local function try(fn, ...) local ok, v = pcall(fn, ...); if ok then return v end end
  -- Items a resource gives when mined (ores, stone, coal, scrap): only those have drills among their makers. Read from
  -- the resource prototypes once (on a copy of world n the drill search cost 6 ms a call, for any item).
  local MINED
  function M.mined(item)
    if not MINED then
      MINED = {}
      local list = try(function() return prototypes.get_entity_filtered{{filter='type', type='resource'}} end) or {}
      for _, r in pairs(list) do
        local mp = try(function() return r.mineable_properties end)
        for _, prod in ipairs(mp and mp.products or {}) do if prod.name then MINED[prod.name] = true end end
      end
    end
    return MINED[item] == true
  end
  local function at(pos) return string.format('(%g,%g)', pos.x, pos.y) end
  local function place(e) return e.name .. ' ' .. at(e.position) end
  local function side(i) return i % 2 == 1 and 'left' or 'right' end
  local function status(e) return api.status_name(e) or 'unknown' end
  local function dist2(a, b) return (a.x - b.x) ^ 2 + (a.y - b.y) ^ 2 end
  local function radius_of(e)
    local b = try(function() return e.bounding_box end)
    if not b then return 1 end
    return math.max(b.right_bottom.x - b.left_top.x, b.right_bottom.y - b.left_top.y) / 2
  end
  local function targets(i) return i.pickup_target, i.drop_target end
  -- What remote view shows: our own platform whole, else visible chunks (radar coverage), cached per chunk.
  local function sight(p, surface)
    local pl = try(function() return surface.platform end)
    if pl and pl.force == p.force then return function() return true end, function() return true end end
    local cache, charted = {}, {}
    -- Charted chunks out of sight: the map draws the buildings there as last seen, not what they hold now.
    return function(pos)
      if p.position and not (type(p)=='table' and rawget(p,'__remote')) and dist2(p.position,pos)<=32^2 then return true end
      local cx, cy = math.floor(pos.x / 32), math.floor(pos.y / 32)
      local key = cx .. ',' .. cy
      local v = cache[key]
      if v == nil then v = try(function() return p.force.is_chunk_visible(surface, {x=cx, y=cy}) end) == true; cache[key] = v end
      return v
    end, function(pos)
      local cx, cy = math.floor(pos.x / 32), math.floor(pos.y / 32)
      local key = cx .. ',' .. cy
      local v = charted[key]
      if v == nil then v = try(function() return p.force.is_chunk_charted(surface, {x=cx, y=cy}) end) == true; charted[key] = v end
      return v
    end
  end
  -- The target of a machine trace: in sight of the character, else by remote view (ours, in a visible chunk).
  local function target(p, a)
    local ok, e = pcall(api.entity, p, a, true)
    if ok then return e end
    local ok2, far = pcall(api.remote_entity, p, a)
    if ok2 then return far end
    error(tostring(e):gsub('^[^:]*:%d+: ', ''), 0)
  end
  -- Inserters in an area, indexed by what they pick up from and drop into.
  local function index(surface, force, area)
    local idx = {by_pick={}, by_drop={}, n=0}
    for _, i in ipairs(surface.find_entities_filtered{type='inserter', force=force, position=area.position, radius=area.radius, limit=MAX_INSERTERS}) do
      local ok, pick, drop = pcall(targets, i)
      if ok then
        idx.n = idx.n + 1
        local row = {e=i, pick=pick, drop=drop}
        local k = pick and pick.unit_number
        if k then idx.by_pick[k] = idx.by_pick[k] or {}; table.insert(idx.by_pick[k], row) end
        k = drop and drop.unit_number
        if k then idx.by_drop[k] = idx.by_drop[k] or {}; table.insert(idx.by_drop[k], row) end
      end
    end
    return idx
  end
  -- The inserters around an entity, read once per 32-tile cell (a walk crosses few cells).
  local function cells(surface, force)
    local cache, n = {}, 0
    local function of(e)
      local cx, cy = math.floor(e.position.x / 32), math.floor(e.position.y / 32)
      local key = cx .. ',' .. cy
      local c = cache[key]
      if not c then
        c = index(surface, force, {position={x=cx * 32 + 16, y=cy * 32 + 16}, radius=26})
        cache[key] = c
        n = n + 1
      end
      return c
    end
    return of, function() return n end
  end
  local function filters_of(i)
    local n = try(function() return i.filter_slot_count end) or 0
    if n == 0 or try(function() return i.use_filters end) == false then return nil end
    local list = {}
    for k = 1, n do
      local f = try(function() return i.get_filter(k) end)
      local name = type(f) == 'string' and f or type(f) == 'table' and f.name or nil
      if type(name) == 'table' then name = name.name end
      if type(name) == 'string' then list[#list+1] = name end
    end
    if #list == 0 then return nil end
    return {mode=try(function() return i.inserter_filter_mode end) or 'whitelist', items=list}
  end
  local function filter_text(fl) return fl and (fl.mode == 'blacklist' and 'not ' or '') .. table.concat(fl.items, ', ') or nil end
  local function allows(fl, item)
    if not fl then return true end
    local listed = false
    for _, n in ipairs(fl.items) do if n == item then listed = true end end
    if fl.mode == 'blacklist' then return not listed end
    return listed
  end
  -- Where an inserter with no drop target puts things: the ground, or overboard on a platform.
  local function nowhere(i)
    local d = try(function() return i.drop_position end)
    local tile = d and try(function() return i.surface.get_tile(math.floor(d.x), math.floor(d.y)).name end)
    if tile == 'empty-space' then return 'overboard (empty space at ' .. at(d) .. ')' end
    return 'onto the ground' .. (d and ' at ' .. at(d) or '')
  end
  local function hand(i)
    local s = try(function() return i.held_stack end)
    if s and s.valid_for_read then return s.name, s.count end
  end
  -- Which lanes of a belt an inserter may pick from (2.0: per-lane pickup switches).
  local function picks_lane(i, lane)
    local key = side(lane) == 'left' and 'pickup_from_left_lane' or 'pickup_from_right_lane'
    return try(function() return i[key] end) ~= false
  end
  -- A belt tile's items per lane side: {left={name=n}, right={...}}.
  local function lanes_of(e)
    local out = {left={}, right={}}
    for k = 1, try(function() return e.get_max_transport_line_index() end) or 0 do
      for _, c in ipairs(try(function() return e.get_transport_line(k).get_contents() end) or {}) do
        local s = out[side(k)]
        s[c.name] = (s[c.name] or 0) + c.count
      end
    end
    return out
  end
  local function lane_text(m)
    local list = {}
    for n, c in pairs(m) do list[#list+1] = {n=n, c=c} end
    if #list == 0 then return 'empty' end
    table.sort(list, function(x, y) if x.c ~= y.c then return x.c > y.c end return x.n < y.n end)
    local parts = {}
    for k = 1, math.min(3, #list) do parts[k] = list[k].c .. ' ' .. list[k].n end
    return table.concat(parts, ', ') .. (#list > 3 and ', ...' or '')
  end
  -- How much of an item an inserter's pickup target holds there.
  local function holds(e, item)
    if not (e and e.valid) then return 0 end
    if BELT[e.type] then return try(function() return e.get_item_count(item) end) or 0 end
    if e.type == 'lab' then return count(inventory(e, 'lab_input'), item) end
    if CRAFTER[e.type] then return count(output_of(e), item) end
    return count(main(e), item)
  end
  local function source_text(row, item)
    local src = row.pick
    if not (src and src.valid) then
      local pos = try(function() return row.e.pickup_position end)
      return 'nothing at its pickup ' .. (pos and at(pos) or 'tile'), 0
    end
    local n = item and holds(src, item) or 0
    if BELT[src.type] then
      local l = lanes_of(src)
      local function lane(s, k) return s .. ' lane ' .. (item and (l[s][item] or 0) .. ' ' .. item or lane_text(l[s])) .. (picks_lane(row.e, k) and '' or ' (not picked)') end
      return string.format('%s (%s, %s)', place(src), lane('left', 1), lane('right', 2)), n
    end
    local inv = CRAFTER[src.type] and output_of(src) or src.type == 'lab' and inventory(src, 'lab_input') or main(src)
    local what
    if item then what = tostring(n)
    else
      local m = {}
      for _, c in ipairs(inv and try(function() return inv.get_contents() end) or {}) do m[c.name] = (m[c.name] or 0) + c.count end
      what = next(m) and lane_text(m) or 'nothing'
    end
    if CRAFTER[src.type] then return place(src) .. "'s output holding " .. what, n end
    return place(src) .. ' holding ' .. what, n
  end
  local function packs(p)
    local out = {}
    for name in pairs(api.supply.packs_of(p.force)) do out[name] = true end
    return out
  end
  -- Whether an inserter's drop target takes an item: a machine its recipe's ingredients, a lab the packs, else anything.
  local function accepts(t, item, pk)
    if not (t and t.valid) then return true end
    if t.type == 'lab' then return pk[item] == true or try(function() return prototypes.item[item].type end) == 'tool' end
    if CRAFTER[t.type] then
      local r = recipe_of(t)
      for _, ing in ipairs(r and r.ingredients or {}) do if ing.name == item then return true end end
      return false
    end
    return true
  end
  local function container_full(t, item)
    local inv = main(t)
    if not inv then return nil end
    if item then return try(function() return not inv.can_insert({name=item, count=1}) end) end
    return try(function() return inv.is_full() end)
  end
  -- What a requester or buffer chest asks for of an item (nil: not such a chest).
  local function request_of(t, item)
    local mode = t.type == 'logistic-container' and try(function() return t.prototype.logistic_mode end)
    if mode ~= 'requester' and mode ~= 'buffer' then return nil end
    local n = 0
    local secs = try(function() return t.get_logistic_sections() end)
    for k = 1, secs and secs.sections_count or 0 do
      local sec = try(function() return secs.get_section(k) end)
      for _, f in ipairs(sec and sec.active ~= false and try(function() return sec.filters end) or {}) do
        local v = f.value
        local name = type(v) == 'table' and (type(v.name) == 'table' and v.name.name or v.name) or v
        if name == item then n = n + (f.min or 0) end
      end
    end
    return n
  end
  -- A requester chest that asks for none of the item.
  local function no_request(t, item)
    if t.type ~= 'logistic-container' or try(function() return t.prototype.logistic_mode end) ~= 'requester' then return false end
    local secs = try(function() return t.get_logistic_sections() end)
    for k = 1, secs and secs.sections_count or 0 do
      local sec = try(function() return secs.get_section(k) end)
      for _, f in ipairs(sec and try(function() return sec.filters end) or {}) do
        local v = f.value
        local name = type(v) == 'table' and (type(v.name) == 'table' and v.name.name or v.name) or v
        if name == item and (f.min or 0) > 0 and sec.active ~= false then return false end
      end
    end
    return true
  end

  -- trace {position}: what a machine or lab lacks and where each feeder reads.
  local function wants(e, p)
    local list = {}
    if e.type == 'lab' then
      local inv = inventory(e, 'lab_input')
      for name in pairs(packs(p)) do list[#list+1] = {item=name, amount=1, has=count(inv, name)} end
      table.sort(list, function(x, y) return x.item < y.item end)
      return list, 'research ' .. tostring(try(function() return p.force.current_research.name end) or 'none')
    end
    local recipe = recipe_of(e)
    if not recipe then return nil end
    local inv = input_of(e)
    for _, ing in ipairs(recipe.ingredients or {}) do
      if ing.type == 'fluid' then
        list[#list+1] = {item=ing.name, amount=ing.amount, fluid=true, has=math.floor(try(function() return e.get_fluid_count(ing.name) end) or 0)}
      else
        list[#list+1] = {item=ing.name, amount=ing.amount, has=count(inv, ing.name)}
      end
    end
    return list, 'recipe ' .. recipe.name
  end
  function M.back(p, a)
    local e = target(p, a)
    local list, what = wants(e, p)
    assert(list, string.format('%s at %s has no recipe or research to trace (forward=true follows its output)', e.name, at(e.position)))
    local r = radius_of(e)
    local idx = index(p.surface, p.force, {position=e.position, radius=r + NEAR + REACH})
    local feeders = idx.by_drop[e.unit_number] or {}
    local lacking = {}
    for _, w in ipairs(list) do if a.all or w.has < w.amount then lacking[#lacking+1] = w end end
    local out = {entity=e.name, position=e.position, status=status(e), crafting=what, feeders={}, ingredients={}}
    for k, row in ipairs(feeders) do
      local i = row.e
      local name, n = hand(i)
      local text = source_text(row, nil)
      out.feeders[k] = {inserter=i.name, position=i.position, status=status(i), filter=filter_text(filters_of(i)),
        held=name and (n .. ' ' .. name) or nil, held_blocked=api.held_blocked and api.held_blocked(i), from=text}
    end
    if #lacking == 0 then out.note = 'it holds every ingredient for its next craft (all=true lists them all)' end
    -- Containers near it that hold an ingredient and that no inserter reads.
    local boxes = p.surface.find_entities_filtered{type=CONTAINERS, force=p.force, position=e.position, radius=r + NEAR}
    for _, w in ipairs(lacking) do
      local row = {item=w.item, has=w.has, needs=w.amount}
      local parts = {string.format('%s: has %d of %d', w.item, w.has, w.amount)}
      if w.fluid then
        parts[1] = parts[1] .. ' (a fluid: by pipe)'
      else
        local any = false
        for _, f in ipairs(feeders) do
          if allows(filters_of(f.e), w.item) then
            any = true
            local text = source_text(f, w.item)
            local want = f.pick and f.pick.valid and request_of(f.pick, w.item)
            if want then text = text .. (want > 0 and ', requesting ' .. want or ', with no request for it') end
            local name, n = hand(f.e)
            parts[#parts+1] = string.format('%s %s %s takes from %s%s', f.e.name, at(f.e.position), status(f.e), text,
              name and string.format(', holding %d %s', n, name) or '')
          end
        end
        if not any then parts[#parts+1] = #feeders == 0 and 'no inserter feeds it' or 'no inserter feeding it lets it through its filter' end
        local best, bd
        for _, b in ipairs(boxes) do
          local n = count(main(b), w.item)
          if n > 0 and not idx.by_pick[b.unit_number] then
            local d = dist2(b.position, e.position)
            if not bd or d < bd then best, bd, row.unread = b, d, {entity=b.name, position=b.position, holds=n} end
          end
        end
        if best then parts[#parts+1] = string.format('%d in %s, read by nothing', row.unread.holds, place(best)) end
      end
      row.text = table.concat(parts, '; ')
      out.ingredients[#out.ingredients+1] = row
    end
    -- throughput (Sol, 19:50): the inserters into and out of it against its recipe at full speed (craftrate.feed).
    if CRAFTER[e.type] and api.feed then
      local into, from = {}, {}
      for _, row in ipairs(feeders) do into[#into+1] = row.e end
      for _, row in ipairs(idx.by_pick[e.unit_number] or {}) do from[#from+1] = row.e end
      local fd = try(function() return api.feed(e, into, from) end)
      if fd then out.throughput = fd.line end
    end
    out.cost = string.format('%d inserters, %d containers looked at', idx.n, #boxes)
    return out
  end

  -- The walk -----------------------------------------------------------------------------------------------
  -- The lane of belt b an inserter (or a drill) drops onto: the one whose middle is nearest its drop position.
  local function drop_lane(b, i)
    local d = try(function() return i.drop_position end) or b.position
    local best, bd
    for k = 1, try(function() return b.get_max_transport_line_index() end) or 0 do
      local line = try(function() return b.get_transport_line(k) end)
      local pos = line and try(function() return line.get_line_item_position(line.line_length / 2) end)
      if pos then
        local dd = dist2(pos, d)
        if not bd or dd < bd then best, bd = k, dd end
      end
    end
    return best or 1
  end
  -- Where lane k of belt e goes next: the same internal line on a neighbour, else the lines it feeds (onto: a
  -- side-load or a splitter's output, where a belt run ends).
  local function next_lanes(e, k)
    local line = try(function() return e.get_transport_line(k) end)
    if not line then return {} end
    local cands = {}
    local bn = try(function() return e.belt_neighbours end)
    for _, n in ipairs(bn and bn.outputs or {}) do cands[#cands+1] = n end
    if e.type == 'underground-belt' and try(function() return e.belt_to_ground_type end) == 'input' then
      local nb = try(function() return e.neighbours end)
      if nb and nb.valid then cands[#cands+1] = nb end
    end
    for _, n in ipairs(cands) do
      for j = 1, try(function() return n.get_max_transport_line_index() end) or 0 do
        if try(function() return n.get_transport_line(j).line_equals(line) end) then return {{e=n, k=j}} end
      end
    end
    local out = {}
    for _, o in ipairs(try(function() return line.output_lines end) or {}) do
      local owner = o.owner
      if owner and owner.valid then
        for j = 1, try(function() return owner.get_max_transport_line_index() end) or 0 do
          if owner.get_transport_line(j) == o then out[#out+1] = {e=owner, k=j, onto=true}; break end
        end
      end
    end
    return out
  end
  local function splitter_filter(sp)
    local f = try(function() return sp.splitter_filter end)
    if not f then return nil end
    local name = type(f) == 'table' and f.name or f
    if type(name) == 'table' then name = name.name end
    return type(name) == 'string' and name or nil
  end
  -- Which side of splitter sp an output lane is on (16-way directions: 0 north, 4 east; left of north is west).
  local function splitter_side(sp, e)
    local a = (try(function() return sp.direction end) or 0) / 16 * 2 * math.pi
    local fx, fy = math.sin(a), -math.cos(a)
    local v = (e.position.x - sp.position.x) * fy + (e.position.y - sp.position.y) * -fx
    return v > 0 and 'left' or 'right'
  end
  local function lane_full(e, k)
    local line = try(function() return e.get_transport_line(k) end)
    if not line then return false end
    local stacks = #(try(function() return line.get_detailed_contents() end) or {})
    return stacks >= math.floor((line.line_length or 1) * 4 + 0.5)
  end
  local function front_item(e, k)
    local best, bp
    for _, s in ipairs(try(function() return e.get_transport_line(k).get_detailed_contents() end) or {}) do
      local name = s.stack and s.stack.valid_for_read and s.stack.name
      if name and (not bp or s.position > bp) then best, bp = name, s.position end
    end
    return best
  end
  -- Where other items join a route's lane k at belt e, come from last (Opus, 06:26: ore side-loaded into a plate
  -- bus). An input of e other than last is: a belt side-loading onto e (perpendicular, onto lane k: the lane nearest
  -- it), the other input of a splitter, or, when the route came onto e from the side, the belt it joined (e's own
  -- straight input). Each is named once a route, with the items it brings that the route did not carry up to here.
  -- Items move, so what an input brings is read on it and up to UPSTREAM belts behind it; a belt the route joined
  -- also by what its lane carries after the join, up to the next merge. An inserter putting things onto the lane
  -- is named too, with what it holds, else what its pickup target holds.
  local MAX_MERGES, UPSTREAM = 6, 16
  local function lane_near(e, pos)
    local best, bd
    for j = 1, math.min(2, try(function() return e.get_max_transport_line_index() end) or 0) do
      local line = try(function() return e.get_transport_line(j) end)
      local mid = line and try(function() return line.get_line_item_position(line.line_length / 2) end)
      if mid then
        local d = dist2(mid, pos)
        if not bd or d < bd then best, bd = j, d end
      end
    end
    return best
  end
  local function items_on(e, only)
    local m = {}
    for j = 1, math.min(2, try(function() return e.get_max_transport_line_index() end) or 0) do
      if not only or only == j then
        for _, c in ipairs(try(function() return e.get_transport_line(j).get_contents() end) or {}) do m[c.name] = (m[c.name] or 0) + c.count end
      end
    end
    return m
  end
  -- Items on lane only (or both) of b and up to UPSTREAM belts behind it: its straight input, or its one input on a curve.
  local function upstream_items(b, only)
    local m, e, n = {}, b, 0
    while e and e.valid and n < UPSTREAM do
      for name, c in pairs(items_on(e, only)) do m[name] = (m[name] or 0) + c end
      n = n + 1
      local bn = try(function() return e.belt_neighbours end)
      local ins, nxt = bn and bn.inputs or {}, nil
      for _, x in ipairs(ins) do if x.direction == e.direction then nxt = x end end
      if not nxt and #ins == 1 and e.type == 'transport-belt' then nxt = ins[1] end
      e = nxt
    end
    return m
  end
  local function names(m, without)
    local list = {}
    for n, c in pairs(m) do if not (without and without[n]) then list[#list+1] = {n=n, c=c} end end
    table.sort(list, function(x, y) if x.c ~= y.c then return x.c > y.c end return x.n < y.n end)
    local out = {}
    for i = 1, math.min(3, #list) do out[i] = list[i].n end
    return table.concat(out, ', ') .. (#list > 3 and ', ...' or ''), #list
  end
  local function merges_at(route, e, k, last)
    local bn = try(function() return e.belt_neighbours end)
    for _, b in ipairs(bn and bn.inputs or {}) do
      if b ~= last and b.valid and not route.merged[b.unit_number] and #route.merges < MAX_MERGES then
        local kind
        if e.type == 'splitter' then kind = 'splitter'
        elseif e.type == 'transport-belt' or e.type == 'underground-belt' then
          if b.direction == e.direction then
            if last and last.direction ~= e.direction and try(function() return e.belt_shape end) ~= 'left'
              and try(function() return e.belt_shape end) ~= 'right' then kind = 'joined' end
          elseif e.type == 'underground-belt' or try(function() return e.belt_shape end) == 'straight' then
            if lane_near(e, b.position) == k then kind = 'side' end
          end
        end
        if kind == 'joined' then
          -- Named when the route ends (join_done): what the joined lane brings, behind the join and after it.
          route.merged[b.unit_number] = true
          route.join_open = nil
          local mine = {}
          for n in pairs(route.mine) do mine[n] = true end
          local others = {}
          for n, c in pairs(upstream_items(b, k)) do if not mine[n] then others[n] = (others[n] or 0) + c end end
          route.merges[#route.merges+1] = false
          route.join_open = {at=#route.merges, e=e, k=k, mine=mine, others=others}
        elseif kind then
          route.join_open = nil
          local m = upstream_items(b)
          local theirs, nt = names(m, route.mine)
          if nt > 0 then
            route.merged[b.unit_number] = true
            local ours, no = names(route.mine)
            local was = no > 0 and ours or 'nothing up to here'
            if kind == 'side' then
              route.merges[#route.merges+1] = string.format('%s side-loads %s onto %s %s lane, which carried %s', place(b), theirs, place(e), side(k), was)
            else
              route.merges[#route.merges+1] = string.format('%s also takes %s carrying %s; this lane carried %s', place(e), place(b), theirs, was)
            end
          end
        end
      end
    end
  end
  -- Inserters dropping onto lane k of belt e: each named once a route when what it puts there (its hand, else what
  -- its pickup target holds) is not what the lane carried up to here (a lane that carried nothing yet names none:
  -- the start of a machine's output lane is its own inserter).
  local function droppers_at(route, e, k, idx)
    for _, row in ipairs(idx.by_drop[e.unit_number] or {}) do
      local i = row.e
      if i.valid and not route.merged[i.unit_number] and #route.merges < MAX_MERGES and drop_lane(e, i) == k then
        local m = {}
        local name, n = hand(i)
        local src = row.pick
        if name then m[name] = n
        elseif src and src.valid then
          if BELT[src.type] then m = items_on(src)
          else
            local inv = CRAFTER[src.type] and output_of(src) or src.type ~= 'lab' and main(src) or nil
            for _, c in ipairs(inv and try(function() return inv.get_contents() end) or {}) do m[c.name] = (m[c.name] or 0) + c.count end
          end
        end
        local theirs, nt = names(m, route.mine)
        if nt > 0 and next(route.mine) then
          route.merged[i.unit_number] = true
          route.join_open = nil
          route.merges[#route.merges+1] = string.format('%s %s puts %s onto %s %s lane%s, which carried %s', i.name, at(i.position), theirs, place(e),
            side(k), (not name and src and src.valid) and ' (from ' .. place(src) .. ')' or '', (names(route.mine)))
        end
      end
    end
  end
  -- The join message, once the route has walked the joined lane (or the next merge closed it); none when the joined
  -- lane brought nothing the route did not carry.
  local function join_done(route)
    for i = #route.merges, 1, -1 do
      local m = route.merges[i]
      if m == false then
        local j = route.joins and route.joins[i]
        local theirs, nt = j and names(j.others) or '', j and select(2, names(j.others)) or 0
        if nt > 0 then
          local list = {}
          for n in pairs(j.mine) do list[n] = 1 end
          local ours, no = names(list)
          route.merges[i] = no > 0 and string.format('joins %s carrying %s on the %s lane: your %s mixes in', place(j.e), theirs, side(j.k), ours)
            or string.format('joins %s carrying %s on the %s lane (this lane carried nothing up to here)', place(j.e), theirs, side(j.k))
        else table.remove(route.merges, i) end
      end
    end
  end
  -- Walks the routes from the starts ({e (belt), k (lane), from, hops}); with item, only the inserters that
  -- can take it count, a splitter filter picks the side, and chests reached are passed on (reached).
  local function walk(starts, idx_of, p, item, budget, pk)
    local routes, queue, visited = budget.routes, {}, budget.visited
    local seen = budget.seen
    for _, s in ipairs(starts) do queue[#queue+1] = s end
    while #queue > 0 and #routes < MAX_ROUTES do
      local s = table.remove(queue, 1)
      local n = #routes + 1
      local route = {n=n, from=s.from, path={}, carries={}, takers={}, takes={}, any_taker=false, seen={}, tiles={}, mine={}, merges={}, merged={}}
      routes[n] = route
      local e, k = s.e, s.k
      local run, run_from, run_side, run_name, last, onto
      -- Out of sight on charted ground (Grok 12:20: three hops down the south copper line, each trace stopped at the
      -- radar edge): the walk goes on by the layout the map draws (belts, inserters, buildings as last seen), with
      -- no contents or states there, and stops where the layout ends or the map is uncharted.
      local dark
      local function close(pos)
        if run then
          route.path[#route.path+1] = run == 1 and string.format('%s %s %s lane', run_name, at(run_from), run_side)
            or string.format('%s %s to %s %s lane (%d tiles)', run_name, at(run_from), at(pos), run_side, run)
          run = nil
        end
      end
      while true do
        if budget.tiles >= MAX_TILES then close(last and last.position or e.position); route.stop = 'walk capped at ' .. MAX_TILES .. ' belt tiles'; break end
        if seen and not seen(e.position) then
          close(last and last.position or e.position)
          route.dark=true
          route.stop='out of sight at '..at(e.position)..'; current route unknown'
          if api.memory_trace then route.remembered=api.memory_trace(p,{position=e.position}) end
          break
        end
        if api.observe then api.observe(e,p) end
        local key = tostring(e.unit_number) .. ':' .. k
        if visited[key] then
          close(last and last.position or e.position)
          route.stop = string.format('joins route %d at %s %s lane', visited[key], place(e), side(k))
          break
        end
        visited[key] = n
        budget.tiles = budget.tiles + 1
        if #route.tiles < 400 then route.tiles[#route.tiles+1] = e end
        if last and last ~= e and not dark then
          merges_at(route, e, k, last)
          if route.join_open then route.joins = route.joins or {}; route.joins[route.join_open.at] = route.join_open end
        end
        if last and not dark then droppers_at(route, e, k, idx_of(e)) end
        for _, c in ipairs(not dark and try(function() return e.get_transport_line(k).get_contents() end) or {}) do
          route.carries[c.name] = (route.carries[c.name] or 0) + c.count
          route.mine[c.name] = (route.mine[c.name] or 0) + c.count
          local j = route.join_open
          if j and not j.mine[c.name] then j.others[c.name] = (j.others[c.name] or 0) + c.count end
        end
        if run and run_name == e.name and run_side == side(k) and e.type == 'transport-belt' and not (onto and last and last.direction ~= e.direction) then run = run + 1
        else
          close(last and last.position or e.position)
          if e.type == 'transport-belt' then run, run_from, run_side, run_name = 1, e.position, side(k), e.name
          elseif not (last and last == e) then
            local f = e.type == 'splitter' and not dark and splitter_filter(e)
            route.path[#route.path+1] = string.format('%s %s %s lane%s', e.name, at(e.position), side(k),
              f and string.format(' (filter %s to the %s)', f, try(function() return e.splitter_output_priority end) or '?') or '')
          end
        end
        -- Inserters picking up from this tile: from this lane, or the item's other lane (wrong lane).
        for _, row in ipairs(idx_of(e).by_pick[e.unit_number] or {}) do
          local i = row.e
          if not route.seen[i.unit_number] then
            route.seen[i.unit_number] = true
            local fl = filters_of(i)
            local t = row.drop
            local this_lane = picks_lane(i, k)
            if dark then fl = nil end
            if not item or allows(fl, item) then
              local name, cnt, st, text
              if dark then text = string.format('%s %s (out of sight)', i.name, at(i.position))
              else
                name, cnt = hand(i)
                st = status(i)
                text = string.format('%s %s %s%s', i.name, at(i.position), st, fl and ' filter ' .. filter_text(fl) or '')
              end
              if name then text = text .. string.format(', holding %d %s', cnt, name) end
              local blocked=not dark and api.held_blocked and api.held_blocked(i)
              if blocked then text=text..'; '..blocked end
              if not this_lane then text = text .. ', picks only the ' .. (side(k) == 'left' and 'right' or 'left') .. ' lane'
              else
                route.any_taker = true
                if fl and fl.mode ~= 'blacklist' then
                  for _, it in ipairs(fl.items) do if accepts(t, it, pk) then route.takes[it] = true end end
                elseif t and t.valid and (t.type == 'lab' or CRAFTER[t.type]) then
                  if t.type == 'lab' then for it in pairs(pk) do route.takes[it] = true end
                  else for _, ing in ipairs((recipe_of(t) or {}).ingredients or {}) do route.takes[ing.name] = true end end
                else route.takes['*'] = true end
              end
              if not (t and t.valid) then
                text = text .. ' -> ' .. nowhere(i)
              elseif BELT[t.type] then
                text = text .. ' -> ' .. place(t)
                if this_lane and (s.hops or 0) < MAX_HOPS then
                  queue[#queue+1] = {e=t, k=drop_lane(t, i), from=string.format('%s %s onto %s', i.name, at(i.position), place(t)), hops=(s.hops or 0) + 1}
                end
              else
                local full = not dark and CONTAINER[t.type] and container_full(t, item)
                text = text .. ' -> ' .. place(t) .. (full and ' (full)' or '')
                if item and CONTAINER[t.type] and no_request(t, item) then text = text .. ' (a requester chest with no request for ' .. item .. ')' end
                if item and this_lane then
                  if t.type == 'lab' or CRAFTER[t.type] then
                    if accepts(t, item, pk) then budget.reached[#budget.reached+1] = {e=t, by=i, route=n}
                    else text = text .. ' (which does not use ' .. item .. ')' end
                  elseif CONTAINER[t.type] then budget.boxes[#budget.boxes+1] = {e=t, route=n, hops=s.hops or 0} end
                end
              end
              if st and FULL[st] and name then text = text .. ' (holding what it cannot drop)' end
              route.takers[#route.takers+1] = text
            end
          end
        end
        local nexts = next_lanes(e, k)
        last = e
        if e.type == 'splitter' and #nexts > 1 then
          local f, prio = splitter_filter(e), try(function() return e.splitter_output_priority end)
          if item and f and (prio == 'left' or prio == 'right') then
            local keep = {}
            for _, x in ipairs(nexts) do if (f == item) == (splitter_side(e, x.e) == prio) then keep[#keep+1] = x end end
            if #keep > 0 then nexts = keep end
          end
        end
        if #nexts == 0 and dark then
          -- The layout ends out of sight: the first gap, the tile it would output into.
          close(e.position)
          local d = try(function() return e.direction end) or 0
          local step = ({[0]={0,-1}, [4]={1,0}, [8]={0,1}, [12]={-1,0}})[d] or {0,0}
          route.stop = string.format('the layout ends at %s, out of sight: nothing on the map at %s after it (layout as last seen, contents unknown)',
            place(e), at({x=e.position.x+step[1], y=e.position.y+step[2]}))
          break
        end
        if #nexts == 0 then
          close(e.position)
          local l = lanes_of(e)
          local parts, full = {}, {}
          for _, sd in ipairs({'left', 'right'}) do
            full[sd]=lane_full(e,sd=='left' and 1 or 2)
            parts[#parts+1] = sd .. ' lane ' .. lane_text(l[sd]) .. (full[sd] and ' (full)' or '')
          end
          if api.end_seen then api.end_seen(p.force,e.surface,e.position,{left_full=full.left,right_full=full.right,
            left_empty=next(l.left)==nil,right_empty=next(l.right)==nil}) end
          route.stop = 'belt ends at ' .. place(e) .. ': ' .. table.concat(parts, ', ')
          if lane_full(e, k) then route.front = front_item(e, k) end
          break
        end
        for x = 2, #nexts do queue[#queue+1] = {e=nexts[x].e, k=nexts[x].k, from='branch at ' .. place(e) .. ' ' .. side(k) .. ' lane', hops=s.hops} end
        e, k, onto = nexts[1].e, nexts[1].k, nexts[1].onto
      end
      route.end_at = last
      join_done(route)
    end
    budget.queued = #queue
  end
  local function route_view(route)
    local carries = {}
    for name, c in pairs(route.carries) do carries[#carries+1] = {n=name, c=c} end
    table.sort(carries, function(x, y) if x.c ~= y.c then return x.c > y.c end return x.n < y.n end)
    local parts = {}
    for k = 1, math.min(6, #carries) do parts[k] = carries[k].c .. ' ' .. carries[k].n end
    local nobody = {}
    if not route.takes['*'] then
      for _, c in ipairs(carries) do if not route.takes[c.n] then nobody[#nobody+1] = c.n end end
    end
    local stop = route.stop or 'its lanes end at the inserters listed'
    if route.front then
      stop = stop .. string.format('; the front of the lane is %s', route.front)
      if route.any_taker and not route.takes['*'] and not route.takes[route.front] then stop = stop .. ', which no inserter on this route takes' end
    end
    return {route=route.n, from=route.from, path=table.concat(route.path, ' -> '), remembered=route.remembered, carries=#parts > 0 and table.concat(parts, ', ') or 'nothing now',
      merges=#route.merges > 0 and route.merges or nil, takers=#route.takers > 0 and route.takers or nil, stop=stop,
      nobody_takes=route.any_taker and #nobody > 0 and table.concat(nobody, ', ') or nil}
  end
  local function new_budget(seen, charted) return {tiles=0, visited={}, routes={}, reached={}, boxes={}, queued=0, seen=seen, charted=charted} end

  -- The merges of all routes, once each.
  local function all_merges(routes)
    local out, seen = {}, {}
    for _, r in ipairs(routes) do
      for _, m in ipairs(r.merges or {}) do if not seen[m] then seen[m] = true; out[#out+1] = m end end
    end
    return #out > 0 and out or nil
  end
  -- audit=true (beltaudit.lua; Opus 18:20): where the walked lanes lose capacity.
  local audit_mod
  local function audit_of(budget)
    audit_mod = audit_mod or require('beltaudit'){try=try, place=place, at=at, side=side, lanes_of=lanes_of, lane_text=lane_text, lane_near=lane_near, lane_full=lane_full}
    return audit_mod.audit(budget.routes, budget.seen, 24)
  end
  M.audit_of = audit_of
  -- trace {position, forward} on a belt tile: its lanes from there (those carrying something now, else both).
  local function from_belt(p, e, a)
    local idx_of, areas = cells(p.surface, p.force)
    local l = lanes_of(e)
    local out = {belt=e.name, position=e.position, lanes=string.format('left lane %s, right lane %s', lane_text(l.left), lane_text(l.right))}
    local starts = {}
    for k = 1, 2 do
      if next(l[side(k)]) then starts[#starts+1] = {e=e, k=k, from=place(e) .. ' ' .. side(k) .. ' lane', hops=0} end
    end
    if #starts == 0 then
      for k = 1, 2 do starts[#starts+1] = {e=e, k=k, from=place(e) .. ' ' .. side(k) .. ' lane', hops=0} end
    end
    local budget = new_budget(sight(p, p.surface))
    walk(starts, idx_of, p, nil, budget, packs(p))
    out.routes = {}
    for n, route in ipairs(budget.routes) do out.routes[n] = route_view(route) end
    out.merges = all_merges(out.routes)
    if a and a.audit then out.audit = audit_of(budget) end
    out.cost = string.format('%d belt tiles, %d routes, %d inserter areas%s', budget.tiles, #budget.routes, areas(),
      budget.queued > 0 and string.format(' (%d more routes not walked: cap %d)', budget.queued, MAX_ROUTES) or '')
    return out
  end

  -- trace {position, forward}: from a machine's output to where its items end up.
  function M.forward(p, a)
    local e = target(p, a)
    if BELT[e.type] then return from_belt(p, e, a) end
    local idx_of, areas = cells(p.surface, p.force)
    local here = index(p.surface, p.force, {position=e.position, radius=radius_of(e) + REACH})
    local out = {entity=e.name, position=e.position, status=status(e), takers={}}
    local outinv = CRAFTER[e.type] and output_of(e) or e.type == 'asteroid-collector' and inventory(e, 'asteroid_collector_output') or main(e)
    local held = {}
    for _, c in ipairs(outinv and try(function() return outinv.get_contents() end) or {}) do held[#held+1] = c.count .. ' ' .. c.name end
    out.output = #held > 0 and table.concat(held, ', ') or 'empty'
    local starts, ends = {}, {}
    local own = try(function() return e.drop_target end)
    if own and own.valid and BELT[own.type] then starts[#starts+1] = {e=own, k=drop_lane(own, e), from=place(e) .. ' onto ' .. place(own), hops=0} end
    for _, row in ipairs(here.by_pick[e.unit_number] or {}) do
      local i, t = row.e, row.drop
      local name, n = hand(i)
      local st = status(i)
      local blocked=api.held_blocked and api.held_blocked(i)
      local fl = filters_of(i)
      local text = string.format('%s %s %s%s%s', i.name, at(i.position), st, fl and ' filter ' .. filter_text(fl) or '',
        name and string.format(', holding %d %s', n, name) or '')
      if not (t and t.valid) then text = text .. ' -> ' .. nowhere(i)
      elseif BELT[t.type] then
        local k = drop_lane(t, i)
        text = text .. ' -> ' .. place(t) .. ' ' .. side(k) .. ' lane'
        starts[#starts+1] = {e=t, k=k, from=string.format('%s %s onto %s', i.name, at(i.position), place(t)), hops=0}
      else
        local full = CONTAINER[t.type] and container_full(t, name)
        -- (Luna 00:20: the jelly maker's output: which inserter, the exact chest and its free slots)
        local inv = CONTAINER[t.type] and try(function() return t.get_inventory(defines.inventory.chest) end)
        local free = inv and try(function() return inv.count_empty_stacks() end)
        text = text .. ' -> ' .. place(t) .. (full and ' (full)' or '') .. (free and string.format(' (%d of %d slots free)', free, #inv) or '')
        ends[#ends+1] = place(t)
      end
      if FULL[st] and name then text = text .. ' (holding what it cannot drop)' end
      if blocked then text=text..'; '..blocked end
      out.takers[#out.takers+1] = text
    end
    if #out.takers == 0 then out.takers = nil; if #starts == 0 then out.note = 'no inserter takes from it' end end
    local budget = new_budget(sight(p, p.surface))
    walk(starts, idx_of, p, nil, budget, packs(p))
    out.routes = {}
    for n, route in ipairs(budget.routes) do out.routes[n] = route_view(route) end
    if #out.routes == 0 then out.routes = nil end
    out.merges = out.routes and all_merges(out.routes) or nil
    if a.audit then out.audit = audit_of(budget) end
    out.cost = string.format('%d belt tiles, %d routes, %d inserter areas%s', budget.tiles, #budget.routes, areas() + 1,
      budget.queued > 0 and string.format(' (%d more routes not walked: cap %d)', budget.queued, MAX_ROUTES) or '')
    return out
  end

  -- (d17 batch23 C4, Muse: item + position + forward tried in turn, each refused tersely) an argument refusal names the
  -- shapes trace takes, one a mode (fh help trace gives a call for each: runtime.lua M.EXAMPLES).
  local SHAPES = 'trace takes {position} (a machine or lab, back to what it lacks; all: true for every ingredient) | '
    .. '{position, forward: true} (its output, or a belt tile on; audit: true) | {position, upstream: true} (item: one ingredient) | '
    .. '{position, circuit: true} | {position, throughput: true} (a belt tile) | {item} (every route of an item; near: {x,y}, radius, surface)'
  M.SHAPES = SHAPES
  local function need(ok, text) if not ok then error(text .. '; ' .. SHAPES, 0) end end
  -- trace {item}: every route from the machines making it to the labs, machines and chests taking it.
  function M.items(p, a)
    local item = a.item
    need(type(item) == 'string' and prototypes.item[item], 'item must be an item name (chemical-science-pack, iron-gear-wheel, ...)')
    local surface = p.surface
    if a.surface ~= nil then
      assert(type(a.surface) == 'string', 'surface must be a surface name')
      surface = game.get_surface(a.surface)
      assert(surface, 'no surface ' .. a.surface)
    end
    local force = p.force
    local pk = packs(p)
    local seen, charted = sight(p, surface)
    local idx_of, areas = cells(surface, force)
    -- near {x,y} (+ radius): makers and labs in that area only (a whole-surface read is the costly part).
    local area
    if a.near ~= nil then area = {position=api.position(a.near), radius=api.integer(a.radius, 64, 1, 512, 'radius')}
    else need(a.radius == nil, 'radius goes with near {x,y}') end
    local function find(f)
      f.force = force
      if area then f.position, f.radius = area.position, area.radius end
      return surface.find_entities_filtered(f)
    end
    -- Makers: crafters whose recipe makes it, nearest to you first; and mining drills on a resource that gives it (an
    -- ore, stone, coal, scrap: friction3, Grok 23:29: trace {item: copper-ore} read "nothing on nauvis makes copper-ore",
    -- and it followed the ore belts by hand for 8 min): what a drill drops onto is where its routes start.
    local makers, states, drills = {}, {}, {}
    for _, e in ipairs(find{type={'assembling-machine', 'furnace', 'rocket-silo'}, limit=4096}) do
      local r = seen(e.position) and recipe_of(e)
      for _, prod in ipairs(r and r.products or {}) do if prod.name == item then makers[#makers+1] = e; break end end
    end
    if M.mined(item) then
      for _, e in ipairs(find{type='mining-drill', limit=4096}) do
        if seen(e.position) then
          local res = try(function() return e.mining_target end)
          local mp = res and try(function() return res.prototype.mineable_properties end)
          for _, prod in ipairs(mp and mp.products or {}) do
            if prod.name == item then makers[#makers+1] = e; drills[e] = true; break end
          end
        end
      end
    end
    local origin = area and area.position or surface == p.surface and p.position or {x=0, y=0}
    table.sort(makers, function(x, y) return dist2(x.position, origin) < dist2(y.position, origin) end)
    local total_makers = #makers
    for k = MAX_MAKERS + 1, #makers do makers[k] = nil end
    local out = {item=item, surface=surface.name, area=area and (at(area.position) .. ' radius ' .. area.radius) or nil}
    local starts, notes = {}, {}
    local budget = new_budget(seen, charted)
    for _, m in ipairs(makers) do
      local st = status(m)
      states[st] = (states[st] or 0) + 1
      local taken = false
      if drills[m] then
        -- A drill drops straight onto a belt, into a chest or a machine (no inserter takes from it).
        local t = try(function() return m.drop_target end)
        taken = true
        if t and t.valid and BELT[t.type] then
          starts[#starts+1] = {e=t, k=drop_lane(t, m), from=string.format('%s %s drops onto %s', m.name, at(m.position), place(t)), hops=0}
        elseif t and t.valid then
          notes[#notes+1] = string.format('%s %s drops into %s%s', m.name, at(m.position), place(t), CONTAINER[t.type] and container_full(t, item) and ' (full)' or '')
          if CONTAINER[t.type] then budget.boxes[#budget.boxes+1] = {e=t, route=0, hops=0} end
        else
          local dp = try(function() return m.drop_position end)
          notes[#notes+1] = string.format('%s %s %s: drops onto nothing%s', m.name, at(m.position), st, dp and ' at ' .. at(dp) or '')
        end
      end
      for _, row in ipairs(idx_of(m).by_pick[m.unit_number] or {}) do
        local i, t = row.e, row.drop
        if allows(filters_of(i), item) then
          taken = true
          if t and t.valid and BELT[t.type] then
            starts[#starts+1] = {e=t, k=drop_lane(t, i), from=string.format('%s %s -> %s %s onto %s', m.name, at(m.position), i.name, at(i.position), place(t)), hops=0}
          elseif t and t.valid then
            if t.type == 'lab' or CRAFTER[t.type] then
              notes[#notes+1] = string.format('%s %s -> %s %s -> %s%s', m.name, at(m.position), i.name, at(i.position), place(t),
                accepts(t, item, pk) and '' or ' (which does not use ' .. item .. ')')
            else
              local mode = t.type == 'logistic-container' and try(function() return t.prototype.logistic_mode end)
              notes[#notes+1] = string.format('%s %s -> %s %s -> %s%s%s', m.name, at(m.position), i.name, at(i.position), place(t),
                container_full(t, item) and ' (full)' or '',
                (mode == 'passive-provider' or mode == 'active-provider' or mode == 'storage') and ' (a logistic chest: robots carry it on)' or '')
              if CONTAINER[t.type] then budget.boxes[#budget.boxes+1] = {e=t, route=0, hops=0} end
            end
          end
        end
      end
      if not taken then notes[#notes+1] = string.format('%s %s %s: no inserter takes %s from it', m.name, at(m.position), st, item) end
    end
    local n_drills = 0
    for _ in pairs(drills) do n_drills = n_drills + 1 end
    local parts = {}
    for st, n in pairs(states) do parts[#parts+1] = n .. ' ' .. st end
    table.sort(parts)
    out.makers = total_makers == 0 and ('nothing on ' .. surface.name .. ' makes ' .. item) or
      string.format('%d making it%s%s: %s', total_makers, n_drills > 0 and string.format(' (%d mining drill%s)', n_drills, n_drills == 1 and '' or 's') or '',
        total_makers > MAX_MAKERS and ' (the nearest ' .. MAX_MAKERS .. ' traced)' or '', table.concat(parts, ', '))
    walk(starts, idx_of, p, item, budget, pk)
    -- On through chests: their own inserters take it further (each chest once).
    local done = {}
    local hop = 0
    while #budget.boxes > 0 and hop < MAX_HOPS and #budget.routes < MAX_ROUTES do
      hop = hop + 1
      local boxes = budget.boxes
      budget.boxes = {}
      local more = {}
      for _, b in ipairs(boxes) do
        local c = b.e
        if c.valid and not done[c.unit_number] then
          done[c.unit_number] = true
          for _, row in ipairs(idx_of(c).by_pick[c.unit_number] or {}) do
            local i, t = row.e, row.drop
            if allows(filters_of(i), item) and t and t.valid then
              if BELT[t.type] then more[#more+1] = {e=t, k=drop_lane(t, i), from=string.format('%s %s -> %s %s onto %s%s', c.name, at(c.position), i.name, at(i.position), place(t),
                b.route > 0 and string.format(' (after route %d)', b.route) or ''), hops=b.hops + 1}
              elseif (t.type == 'lab' or CRAFTER[t.type]) and accepts(t, item, pk) then budget.reached[#budget.reached+1] = {e=t, by=i, route=b.route, via=c}
              elseif CONTAINER[t.type] then budget.boxes[#budget.boxes+1] = {e=t, route=b.route, hops=b.hops + 1} end
            end
          end
        end
      end
      walk(more, idx_of, p, item, budget, pk)
    end
    out.routes = {}
    for n, route in ipairs(budget.routes) do out.routes[n] = route_view(route) end
    if #out.routes == 0 then out.routes = nil end
    if #notes > 0 then out.direct = notes end
    -- What the routes reach.
    local reached, list = {}, {}
    for _, r in ipairs(budget.reached) do
      local key = r.e.unit_number
      if key and not reached[key] then
        reached[key] = r
        if #list < 20 then
          list[#list+1] = string.format('%s by %s %s (%s)', place(r.e), r.by.name, at(r.by.position),
            r.route > 0 and 'route ' .. r.route .. (r.via and ', via ' .. place(r.via) or '') or 'from ' .. place(r.via) .. ', which a maker fills')
        end
      end
    end
    out.reaches = #list > 0 and list or nil
    -- Labs short of it (a pack the research needs, none in the lab).
    if pk[item] then
      local rows, n_short, n_labs = {}, 0, 0
      for _, lab in ipairs(find{type='lab', limit=MAX_LABS}) do
        if seen(lab.position) then n_labs = n_labs + 1 end
        if seen(lab.position) and count(inventory(lab, 'lab_input'), item) == 0 then
          n_short = n_short + 1
          if #rows < MAX_SHORT then
            local r = reached[lab.unit_number]
            if r then
              local route = r.route > 0 and budget.routes[r.route]
              rows[#rows+1] = string.format('%s: reached by %s (%s)', place(lab), r.route > 0 and 'route ' .. r.route or 'a maker\'s chest',
                route and route_view(route).stop or 'see reaches')
            else
              -- Its own inserters: what each reads and what that holds or asks for.
              local parts = {}
              for _, row in ipairs(idx_of(lab).by_drop[lab.unit_number] or {}) do
                local i, src = row.e, row.pick
                local text = string.format('%s %s %s takes from %s', i.name, at(i.position), status(i), source_text(row, item))
                local want = src and src.valid and request_of(src, item)
                if want then text = text .. (want > 0 and ', requesting ' .. want or ', with no request for it') end
                parts[#parts+1] = text
              end
              local best, bd, br
              for _, route in ipairs(budget.routes) do
                for _, t in ipairs(route.tiles) do
                  if t.valid then
                    local d = dist2(t.position, lab.position)
                    if not bd or d < bd then best, bd, br = t, d, route.n end
                  end
                end
              end
              rows[#rows+1] = place(lab) .. ': no route from a maker reaches it' ..
                (#parts > 0 and '; ' .. table.concat(parts, '; ') or '; no inserter feeds it') ..
                (best and string.format('; nearest route tile %s on route %d, %d tiles', place(best), br, math.floor(math.sqrt(bd) + 0.5)) or '')
            end
          end
        end
      end
      out.labs_short = n_short > 0 and string.format('%d of %d labs hold none of it', n_short, n_labs) or 'every lab holds some'
      out.labs = #rows > 0 and rows or nil
    end
    out.cost = string.format('%d makers, %d belt tiles, %d routes, %d inserter areas%s', #makers, budget.tiles, #budget.routes, areas(),
      budget.queued > 0 and string.format(' (%d more routes not walked: cap %d)', budget.queued, MAX_ROUTES) or '')
    return out
  end

  -- The helpers upstream.lua walks with (trace {position, upstream}).
  M.h = {try=try, at=at, place=place, side=side, status=status, BELT=BELT, CRAFTER=CRAFTER, CONTAINER=CONTAINER, target=target,
    index=index, cells=cells, sight=sight, packs=packs, wants=wants, filters_of=filters_of, filter_text=filter_text, allows=allows,
    hand=hand, picks_lane=picks_lane, lanes_of=lanes_of, lane_text=lane_text, items_on=items_on, upstream_items=upstream_items,
    lane_near=lane_near, drop_lane=drop_lane, lane_full=lane_full, front_item=front_item, accepts=accepts, splitter_filter=splitter_filter,
    splitter_side=splitter_side, radius_of=radius_of, recipe_of=recipe_of, output_of=output_of, input_of=input_of, main=main,
    inventory=inventory, count=count}
  local upstream
  local beltrate
  function M.trace(p, a)
    if a.upstream ~= nil then
      need(type(a.upstream) == 'boolean', 'upstream must be true or false')
      need(a.forward == nil, 'upstream and forward go one way each: give one')
      need(a.near == nil and a.radius == nil, 'near and radius go with item alone')
    end
    if a.upstream then
      need(a.position ~= nil, 'upstream takes position (a machine, lab, thruster, hub, chest or belt tile); item= picks one ingredient')
      upstream = upstream or require('upstream')(api, M.h)
      return upstream.trace(p, a)
    end
    if a.item ~= nil then
      need(a.position == nil and a.forward == nil and a.all == nil, a.position ~= nil and 'item with position goes with upstream: true (that one ingredient back from the machine); item alone traces the item\'s routes' or 'item traces the item\'s routes alone: forward and all go with position')
      return M.items(p, a)
    end
    need(a.near == nil and a.radius == nil, 'near and radius go with item')
    need(a.position ~= nil, 'position or item is missing')
    -- circuit (D5, Astra 00:20: return-belt deadlocks took dozens of inspect calls): the machine's state, each inserter
    -- feeding it (or taking from it) with its enable condition, its value now, filters and hand, and the circuit
    -- networks on its wires followed back through combinators to what drives them (circuits.lua trace_from).
    if a.circuit ~= nil then
      need(a.circuit == true, 'circuit is true')
      need(a.forward == nil and a.item == nil and a.upstream == nil and a.throughput == nil, 'circuit takes position (a machine, chest or inserter) alone')
      local e = target(p, a)
      local C = api.circuits and api.circuits()
      assert(C, 'circuit reads need the circuits module')
      local lines = {string.format('%s (%g,%g): %s', e.name, e.position.x, e.position.y, api.status_name and api.status_name(e) or 'status unknown')}
      local list = {}
      if e.type == 'inserter' then list = {e}
      else
        local b = e.bounding_box
        for _, ins in ipairs(e.surface.find_entities_filtered{area={{b.left_top.x - 3, b.left_top.y - 3}, {b.right_bottom.x + 3, b.right_bottom.y + 3}}, type='inserter', force=e.force}) do
          if ins.valid and (try(function() return ins.drop_target end) == e or try(function() return ins.pickup_target end) == e) then list[#list+1] = ins end
        end
      end
      local wired = 0
      for i, ins in ipairs(list) do
        if i > 16 then lines[#lines+1] = string.format('+%d more inserters', #list - 16); break end
        local into = try(function() return ins.drop_target end) == e
        lines[#lines+1] = (e.type == 'inserter' and '' or (into and 'feeds it: ' or 'takes from it: ')) .. (try(function() return C.inserter_line(ins) end) or ins.name)
        local t = try(function() return C.trace_from(ins) end) or {}
        if #t > 0 then wired = wired + 1 end
        for _, l in ipairs(t) do lines[#lines+1] = l end
      end
      if #list == 0 then lines[#lines+1] = 'no inserter puts into it or takes from it' end
      if #list > 0 and wired == 0 then lines[#lines+1] = 'none of these inserters has a red or green wire: no circuit holds them' end
      return {entity=e.name, position=e.position, lines=lines, inserters=#list, wired=wired}
    end
    -- throughput (beltrate.lua; B1, Opus 21:20): a belt line's supply against its capacity, per lane.
    if a.throughput ~= nil then
      need(a.throughput == true, 'throughput is true')
      need(a.position ~= nil and a.forward == nil and a.item == nil and a.upstream == nil, 'throughput takes position (a belt tile) alone')
      beltrate = beltrate or require('beltrate'){status_name=api.status_name}
      return beltrate.read(p, target(p, a))
    end
    need(a.audit == nil or type(a.audit) == 'boolean', 'audit is true or false')
    need(not a.audit or a.forward, 'audit goes with forward (the belts walked from a machine\'s output or a belt tile)')
    if a.forward then
      need(a.all == nil, 'all goes with a backward trace (no forward)')
      return M.forward(p, a)
    end
    -- A start with nothing to trace back (a drill, a belt, a chest; friction3, Grok 23:02: a drill start was refused,
    -- naming forward=true): its output, forward, said so.
    local e = target(p, a)
    if (e.type == 'mining-drill' or BELT[e.type] or CONTAINER[e.type]) and a.all == nil and not wants(e, p) then
      local out = M.forward(p, a)
      out.note = (out.note and out.note .. '; ' or '') .. string.format('%s has no recipe to trace back: traced forward (its output)', e.name)
      return out
    end
    -- A maker stopped by its full output (Luna 00:20: trace upstream showed only the input side): where its output goes.
    if FULL[status(e)] and a.all == nil then
      local out = M.back(p, a)
      local ok, f = pcall(M.forward, p, a)
      if ok and f then
        out.downstream = f.takers or {f.note or 'nothing takes its output'}
        out.downstream_note = string.format('%s stopped with its output full (%s): what takes from it and where that goes (trace forward=true for the belt routes)', e.name, f.output or '?')
      end
      return out
    end
    return M.back(p, a)
  end

  M.schema = {trace = {memory='without coverage: recorded trace with observation tick and age, or remembered belt layout (up to 512 tiles; stops at unknown routing); current state unknown; a visible trace stops at fog and attaches recorded layout',position='{x,y} of a machine or lab in sight (platform= for one on a platform); with forward also a belt tile',
    all='boolean: every ingredient, not only those it lacks for its next craft',
    forward='boolean: follow its output instead: the inserters taking from it and the belts they load, lane by lane, to where they end; on a belt tile, that belt\'s lanes from there (those carrying something now, else both); every walk names where other items join its lanes (merges)',
    throughput='true, with position on a belt tile: the line through it (every belt feeding it back, on to its end): per lane the mining drills dropping onto it (how many, working, on what) and what they put on at full speed against the slowest belt\'s lane capacity, and what the last 10 tiles hold; lines, lanes, tiles, lane_capacity_per_min, end',
    audit='boolean, with forward: where the walked lanes lose capacity: a belt side-loading both its carried lanes onto one lane, a curve made a side-load by an empty stub behind the turn tile (both lanes onto one), a route ending at missing tiles with the run going on within 4 tiles ahead (what it carries; a ghost waiting there), or against a belt facing another way; returns audit (lines; one line saying none were found)',
    circuit='true, with position (a machine, chest or inserter): its state, each inserter feeding it or taking from it (enable condition and its value now, filters, hand, pickup and drop), and the red and green networks on each one\'s wires followed back through combinators (3 levels) to what drives them: each network\'s signals, the combinators putting out onto it (settings, output) and their input networks, constant combinators, entities reading into it (lines)',
    upstream='boolean, with position: from the target back along what feeds it to the first place each ingredient it lacks (all: every one; item: that one) stops or goes elsewhere: a feeder whose filter does not let it through or that is off by its circuit condition (the condition, the signal on its wires), each lane a feeder picks walked back through undergrounds, splitters and side-loads (the lane at the feeder: full, front item, a jammed mixed lane; the first tile back holding it; inserters taking it elsewhere on the way, with status, filter and what each holds; a splitter filter sending it to the other output; where it comes onto the lane; the first tile where another item joins), a chest it reads and what fills it, and a machine making it that is not working, traced the same way one level down. A thruster: each fluid by pipe to the machines making it, each traced so (back through crushers to the collectors). A hub, chest or belt tile: every lane feeding it',
    item='with upstream: the one ingredient or item to follow. Alone: an item instead of position: the routes from every machine making it (and every mining drill on a resource that gives it, from where it drops) to the labs, machines and chests taking it',
    surface='optional surface name for position or item (default yours); exclusive with platform',
    near='with item: optional {x,y}: makers and labs in this area only (cheaper than the whole surface)', radius='with near: 1..512 tiles (default 64)',
    platform='optional platform name: trace on that platform (platform coordinates, hub at 0,0)',
    returns='position: a maker stopped by its full output adds downstream (the inserters taking from it, each with its destination; a chest with its free slots) and downstream_note; per ingredient it lacks (has/needs) each feeding inserter (status, filter, held), its pickup target (a chest, a machine\'s output, a belt tile with each lane) and what that holds, and the nearest container within 10 tiles holding it that no inserter reads; feeders; throughput (a crafting machine whose inserters in or out carry less than its recipe at full speed: each inserter\'s rate, the share of full speed, and how many like its fastest it takes). forward: takers (a belt tile: belt, lanes); merges (every route\'s, once); routes [{from, path (belt runs, undergrounds, splitters with filters, as flown), carries, merges (where other items join the lane: the belt it joins carrying them, a belt side-loading them onto it, a splitter\'s other input, an inserter putting them onto it; each with what the lane carried up to there), takers (status, filter, held, into), stop (belt end with each lane and full, the front item, joins another route, the cap), nobody_takes}]. item: makers, routes, direct, reaches, labs_short and labs (each short lab: the route reaching it, else its own inserters and what they read, and the nearest route tile). cost'},
  }
  return M
end
