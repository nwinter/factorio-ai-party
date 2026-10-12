-- Items on the ground (item-entity): a summary by item for an area (scan and
-- observe), the watch behind status alerts (a full cargo landing pad whose
-- pods spill, large piles near our buildings), marking them for deconstruction
-- as a planner does (robots take them to storage), and picking them up over an
-- area, walking from one to the next as a player holding the pickup key.
return function(api)
  local M = {handlers={}}
  local WATCH_EVERY = 1800      -- ticks between watch passes (shared by every agent)
  local PILE_MIN = 100          -- stacks in a 64-tile cell that make a pile
  local PILE_CELL = 64
  local PAD_RADIUS = 40         -- spill counted around a full landing pad
  local SAMPLE = 5000           -- stacks read for item counts (the stack total is exact)
  local SCAN_LIMIT = 30000      -- stacks binned per surface for piles
  local MAX_MARK = 32768
  local PICK_EVERY = 6          -- one stack every 6 ticks, as pickup does
  local MAX_SKIPS = 8

  local function key_of(stack)
    local q = stack.quality and stack.quality.name
    return stack.name .. ((q and q ~= 'normal') and ' (' .. q .. ')' or '')
  end
  -- Per item: count, stacks and the box they lie in; most first. `limit`
  -- items are listed, the rest counted in more_items.
  function M.summary(list, limit)
    local by, order, stacks = {}, {}, 0
    for _, e in ipairs(list) do
      local s = e.valid and e.stack
      if s and s.valid_for_read then
        stacks = stacks + 1
        local k, pos = key_of(s), e.position
        local r = by[k]
        if not r then
          r = {name=k, count=0, stacks=0, box={left_top={x=pos.x, y=pos.y}, right_bottom={x=pos.x, y=pos.y}}}
          by[k] = r; order[#order+1] = r
        end
        r.count = r.count + s.count; r.stacks = r.stacks + 1
        local b = r.box
        b.left_top.x = math.min(b.left_top.x, pos.x); b.left_top.y = math.min(b.left_top.y, pos.y)
        b.right_bottom.x = math.max(b.right_bottom.x, pos.x); b.right_bottom.y = math.max(b.right_bottom.y, pos.y)
      end
    end
    if stacks == 0 then return nil end
    table.sort(order, function(x, y) if x.count ~= y.count then return x.count > y.count end return x.name < y.name end)
    local out = {stacks=stacks, items={}}
    for i = 1, math.min(#order, limit or 16) do out.items[i] = order[i] end
    if #order > #out.items then out.more_items = #order - #out.items end
    return out
  end
  local function short(sum, n)
    local parts = {}
    for i = 1, math.min(n, #sum.items) do parts[i] = sum.items[i].count .. ' ' .. sum.items[i].name end
    local more = #sum.items - n + (sum.more_items or 0)
    return table.concat(parts, ', ') .. (more > 0 and string.format(' (+%d more items)', more) or '')
  end
  local function xy(pos) return string.format('(%d,%d)', math.floor(pos.x), math.floor(pos.y)) end

  -- The watch: one pass per force every WATCH_EVERY ticks, on demand (status,
  -- reply hints), nothing per tick.
  local function pad_inventory(pad)
    local ok, inv = pcall(function() return pad.get_inventory(defines.inventory.cargo_landing_pad_main) end)
    return ok and inv or nil
  end
  local function ours(surface, force, area)
    for _, e in pairs(surface.find_entities_filtered{area=area, force=force, limit=8}) do
      if e.valid and e.type ~= 'character' then return true end
    end
    return false
  end
  local function scan_surface(surface, force, w)
    local total = surface.count_entities_filtered{type='item-entity'}
    if total == 0 then return end
    local near_pads = {}
    for _, pad in pairs(surface.find_entities_filtered{type='cargo-landing-pad', force=force}) do
      local inv = pad.valid and pad_inventory(pad)
      if inv and inv.count_empty_stacks() == 0 then
        local stacks = surface.count_entities_filtered{position=pad.position, radius=PAD_RADIUS, type='item-entity'}
        if stacks > 0 then
          local sum = M.summary(surface.find_entities_filtered{position=pad.position, radius=PAD_RADIUS, type='item-entity', limit=SAMPLE}, 8)
          w.pads[#w.pads+1] = {key='pad:' .. surface.name .. xy(pad.position), surface=surface.name, position=pad.position,
            slots=#inv, stacks=stacks, items=sum, sampled=stacks > SAMPLE and SAMPLE or nil}
          near_pads[#near_pads+1] = pad.position
        end
      end
    end
    if total < PILE_MIN then return end
    local cells = {}
    for _, e in pairs(surface.find_entities_filtered{type='item-entity', limit=SCAN_LIMIT}) do
      local pos = e.position
      local k = math.floor(pos.x / PILE_CELL) .. ',' .. math.floor(pos.y / PILE_CELL)
      cells[k] = (cells[k] or 0) + 1
    end
    for k, n in pairs(cells) do
      if n >= PILE_MIN then
        local cx, cy = k:match('^(-?%d+),(-?%d+)$')
        cx, cy = tonumber(cx) * PILE_CELL, tonumber(cy) * PILE_CELL
        local area = {left_top={x=cx, y=cy}, right_bottom={x=cx + PILE_CELL, y=cy + PILE_CELL}}
        local mid = {x=cx + PILE_CELL / 2, y=cy + PILE_CELL / 2}
        local by_pad = false
        for _, pp in ipairs(near_pads) do if api.distance(pp, mid) < PAD_RADIUS + PILE_CELL / 2 then by_pad = true end end
        if not by_pad and ours(surface, force, area) then
          local stacks = surface.count_entities_filtered{area=area, type='item-entity'}
          local sum = M.summary(surface.find_entities_filtered{area=area, type='item-entity', limit=SAMPLE}, 8)
          w.piles[#w.piles+1] = {key='pile:' .. surface.name .. ':' .. k, surface=surface.name, area=area, stacks=stacks, items=sum,
            sampled=stacks > SAMPLE and SAMPLE or nil}
        end
      end
    end
  end
  function M.watch(force)
    local s = api.state()
    s.ground_watch = s.ground_watch or {}
    local w = s.ground_watch[force.name]
    if w and game.tick - w.tick < WATCH_EVERY and game.tick >= w.tick then return w end
    w = {tick=game.tick, pads={}, piles={}}
    for _, surface in pairs(game.surfaces) do
      local ok, err = pcall(scan_surface, surface, force, w)
      if not ok then w.error = tostring(err) end
    end
    table.sort(w.piles, function(x, y) return x.stacks > y.stacks end)
    s.ground_watch[force.name] = w
    return w
  end
  local function pad_line(pad)
    return string.format('cargo landing pad at %s on %s is full (%d/%d slots) and pods spill: %d item stacks on the ground within %d tiles%s: %s',
      xy(pad.position), pad.surface, pad.slots, pad.slots, pad.stacks, PAD_RADIUS,
      pad.sampled and string.format(' (items counted in %d of them)', pad.sampled) or '', pad.items and short(pad.items, 5) or '?')
  end
  local function pile_line(pile)
    local lt, rb = pile.area.left_top, pile.area.right_bottom
    if pile.items then
      -- The box the stacks lie in, within the cell.
      local x1, y1, x2, y2 = math.huge, math.huge, -math.huge, -math.huge
      for _, r in ipairs(pile.items.items) do
        x1 = math.min(x1, r.box.left_top.x); y1 = math.min(y1, r.box.left_top.y)
        x2 = math.max(x2, r.box.right_bottom.x); y2 = math.max(y2, r.box.right_bottom.y)
      end
      lt, rb = {x=x1, y=y1}, {x=x2, y=y2}
    end
    return string.format('%d item stacks on the ground at %s-%s on %s, near our buildings%s: %s', pile.stacks, xy(lt), xy(rb), pile.surface,
      pile.sampled and string.format(' (items counted in %d of them)', pile.sampled) or '', pile.items and short(pile.items, 5) or '?')
  end
  -- status alerts: every spilling pad and the largest piles.
  function M.alerts(p)
    local ok, w = pcall(M.watch, p.force)
    if not ok then return nil end
    local lines = {}
    for _, pad in ipairs(w.pads) do lines[#lines+1] = pad_line(pad) end
    for i, pile in ipairs(w.piles) do
      if i > 3 then lines[#lines+1] = string.format('+%d more piles of 100+ item stacks', #w.piles - 3); break end
      lines[#lines+1] = pile_line(pile)
    end
    return #lines > 0 and lines or nil
  end
  -- Reply hints: a pad or pile once when first seen by this player, again
  -- when it has grown by half since.
  function M.unseen(p, lines)
    local ok, w = pcall(M.watch, p.force)
    if not ok then return lines end
    local s = api.state()
    s.ground_seen = s.ground_seen or {}
    local seen = s.ground_seen[p.index] or {}
    s.ground_seen[p.index] = seen
    local add = {}
    local function check(x, line)
      local was = seen[x.key]
      if not was or x.stacks >= was * 1.5 then add[#add+1] = line(x); seen[x.key] = x.stacks end
    end
    for _, pad in ipairs(w.pads) do check(pad, pad_line) end
    for i, pile in ipairs(w.piles) do if i <= 3 then check(pile, pile_line) end end
    if #add == 0 then return lines end
    lines = lines or {}
    for _, line in ipairs(add) do lines[#lines+1] = line end
    return lines
  end

  -- deconstruct items_on_ground: mark (or cancel) every item stack in the
  -- area, as a deconstruction planner over items on the ground does.
  function M.mark(p, box, cancel, out)
    local list = p.surface.find_entities_filtered{area=box, type='item-entity', limit=MAX_MARK + 1}
    local n, already, marked = 0, 0, {}
    local nets, net_seen, outside, cover = 0, {}, 0, {}
    local storages = 0
    for i, e in ipairs(list) do
      if i > MAX_MARK then out.items_truncated = true; break end
      if e.valid then
        if cancel then
          if e.to_be_deconstructed() then e.cancel_deconstruction(p.force, api.real(p)); n = n + 1 end
        elseif e.to_be_deconstructed() then already = already + 1
        elseif e.order_deconstruction(p.force, api.real(p)) then
          n = n + 1
          marked[#marked+1] = e
          -- Robots reach what lies in a roboport's construction area.
          local pos = e.position
          local ck = math.floor(pos.x / 4) .. ',' .. math.floor(pos.y / 4)
          local c = cover[ck]
          if c == nil then
            local okn, found = pcall(function() return p.surface.find_logistic_networks_by_construction_area(pos, p.force) end)
            c = okn and found or {}
            cover[ck] = c
            for _, net in ipairs(c) do
              local id = net.network_id
              if id and not net_seen[id] then
                net_seen[id] = true; nets = nets + 1
                pcall(function() storages = storages + #net.storages end)
              end
            end
          end
          if #c == 0 then outside = outside + 1 end
        end
      end
    end
    out.item_stacks = n
    if not cancel then
      out.item_stacks_already = already > 0 and already or nil
      local sum = M.summary(marked, 12)
      out.items = sum and sum.items or nil
      for _, r in ipairs(out.items or {}) do r.box = nil end
      out.robot_networks = nets
      out.storage_chests = storages
      out.outside_construction_area = outside > 0 and outside or nil
    end
    return out
  end

  -- pickup over an area: a timed action that picks up every stack in reach,
  -- then walks to the nearest one left in the area.
  function M.pickup(p, a)
    local box
    if a.area then
      assert(a.position == nil and a.radius == nil, 'give area, or position and radius')
      local lt, rb = api.position(a.area.left_top), api.position(a.area.right_bottom)
      assert(rb.x > lt.x and rb.y > lt.y and rb.x - lt.x <= 64 and rb.y - lt.y <= 64, 'area must be nonempty and at most 64x64')
      box = {left_top=lt, right_bottom=rb}
    else
      local c = a.position and api.position(a.position) or p.position
      local r = api.integer(a.radius, 8, 1, 32, 'radius')
      box = {left_top={x=c.x - r, y=c.y - r}, right_bottom={x=c.x + r, y=c.y + r}}
    end
    api.assert_visible(p, {x=(box.left_top.x + box.right_bottom.x) / 2, y=(box.left_top.y + box.right_bottom.y) / 2}, 'pickup area')
    local items
    if a.items ~= nil then
      assert(type(a.items) == 'table' and #a.items >= 1 and #a.items <= 16, 'items requires 1..16 item names')
      items = {}
      for _, name in ipairs(a.items) do assert(type(name) == 'string', 'items requires item names'); items[name] = true end
    end
    local ticks = api.integer(a.ticks, 3600, 1, 36000, 'ticks')
    local list = p.surface.find_entities_filtered{area=box, type='item-entity', limit=SAMPLE}
    local wanted = {}
    for _, e in ipairs(list) do
      if e.valid and e.stack and e.stack.valid_for_read and (not items or items[e.stack.name]) then wanted[#wanted+1] = e end
    end
    assert(#wanted > 0, string.format('no items on the ground%s in (%g,%g)-(%g,%g)', items and ' matching items' or '',
      box.left_top.x, box.left_top.y, box.right_bottom.x, box.right_bottom.y))
    local c = p.character
    local reach = c and c.valid and c.prototype and c.prototype.item_pickup_distance or 1
    local action = {kind='pickup', area=box, items=a.items, reach=reach, until_tick=game.tick + ticks, skips={}, skipped=0}
    api.start(p, action)
    local sum = M.summary(wanted, 8)
    for _, r in ipairs(sum.items) do r.box = nil end
    return {until_tick=action.until_tick, area=box, item_stacks=#list >= SAMPLE and p.surface.count_entities_filtered{area=box, type='item-entity'} or sum.stacks,
      items=sum.items, more_items=sum.more_items, rate='one stack every 6 ticks'}
  end
  local function inside(box, pos)
    return pos.x >= box.left_top.x and pos.x <= box.right_bottom.x and pos.y >= box.left_top.y and pos.y <= box.right_bottom.y
  end
  local function wanted(action, e)
    local s = e.valid and e.stack
    if not (s and s.valid_for_read) then return false end
    if action.items then
      local ok = false
      for _, name in ipairs(action.items) do if name == s.name then ok = true end end
      if not ok then return false end
    end
    return true
  end
  local function pos_key(pos) return string.format('%.2f,%.2f', pos.x, pos.y) end
  -- The nearest stack left in the area: around the character first, then
  -- the whole area.
  local function nearest(p, action)
    local best, bd
    local function consider(list)
      for _, e in ipairs(list) do
        if wanted(action, e) and inside(action.area, e.position) and not action.skips[pos_key(e.position)] then
          local d = api.distance(p.position, e.position)
          if not bd or d < bd then best, bd = e, d end
        end
      end
    end
    consider(p.surface.find_entities_filtered{position=p.position, radius=8, type='item-entity', limit=64})
    if not best then consider(p.surface.find_entities_filtered{area=action.area, type='item-entity', limit=4096}) end
    return best
  end
  function M.left(p, action)
    local n = 0
    for _, e in ipairs(p.surface.find_entities_filtered{area=action.area, type='item-entity', limit=SAMPLE}) do
      if wanted(action, e) then n = n + 1 end
    end
    return n
  end
  function M.tick(p, action, tick)
    -- In reach: pick up, one stack every PICK_EVERY ticks.
    local here
    for _, e in ipairs(p.surface.find_entities_filtered{position=p.position, radius=action.reach or 1, type='item-entity', limit=16}) do
      if wanted(action, e) then here = e; break end
    end
    if here then
      if action.nav then api.stop_walking(p); action.nav = nil end
      action.target = nil
      -- No picking_state: the engine would pick stacks up too, uncounted in
      -- last.picked (live: picked 550 of 1600 plates).
      if tick < (action.next_pick or 0) then return nil end
      action.next_pick = tick + PICK_EVERY
      local s = here.stack
      local name, count = s.name, s.count
      local got = p.insert{name=name, count=count, quality=s.quality and s.quality.name or nil}
      if got == 0 then return 'inventory_full' end
      action.picked = action.picked or {}
      action.picked[name] = (action.picked[name] or 0) + got
      if got >= count then here.destroy() else s.count = count - got end
      return nil
    end
    -- Arrived at the last target and it is still out of reach: skip it.
    if action.target and not action.nav then
      action.skips[action.target] = true; action.skipped = action.skipped + 1; action.target = nil
      if action.skipped >= MAX_SKIPS then return 'blocked' end
    end
    if not action.nav then
      local e = nearest(p, action)
      -- Nothing left but stacks it walked away from: blocked.
      if not e then return action.skipped > 0 and 'blocked' or 'picked_up' end
      action.target = pos_key(e.position)
      action.nav = {position=e.position, tolerance=math.max(0.3, (action.reach or 1) * 0.7), max_stalls=6, replans=0, stalled=0, last_position=p.position}
      api.request_path(p, action.nav)
    end
    local outcome = api.navigate(p, action.nav)
    if outcome then
      api.stop_walking(p)
      action.nav = nil
      if outcome ~= 'arrived' and outcome ~= 'arrived_near' then
        action.skips[action.target or ''] = true; action.skipped = action.skipped + 1; action.target = nil
        if action.skipped >= MAX_SKIPS then return 'blocked' end
      end
    end
    return nil
  end
  return M
end
