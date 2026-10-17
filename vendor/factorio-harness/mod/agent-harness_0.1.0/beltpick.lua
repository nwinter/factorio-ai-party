-- Items taken off belt lanes by hand, as a player's pickup key takes them (Grok, shift13 18:20: the iron for a green
-- circuit plant sat on a full belt at (90.5,-11.5), and pickup found "no items on the ground" three times, which
-- turned Grok's standing order off). pickup {belt: true, item or items, count, position/radius or area}: a timed
-- action that takes matching items from the lanes of our belts (transport belts, undergrounds, splitters, loaders)
-- within the character's pickup distance, about one item a tick, and walks to the nearest belt in the area that
-- carries one when none in reach does. An item keeps its spoilage. Ends when count is taken (picked_up), when the
-- inventory is full, when no belt in the area has carried one for 3 seconds (picked_up with what it took, or
-- nothing_on_belts), when a belt cannot be walked to (blocked), or at its ticks (timed_out).
return function(api)
  local M = {}
  local PICK_EVERY, PER_PICK, IDLE_TICKS, MAX_SKIPS, SAMPLE = 6, 6, 180, 8, 512
  local BELTS = {'transport-belt', 'underground-belt', 'splitter', 'loader', 'loader-1x1', 'linked-belt'}
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function at(pos) return string.format('(%g,%g)', pos.x, pos.y) end

  -- {name=true} from item or items.
  local function wanted_of(a)
    local out, list = {}, {}
    if a.item ~= nil then
      assert(type(a.item) == 'string' and prototypes.item[a.item], 'item must be an item name')
      out[a.item] = true; list[1] = a.item
    end
    if a.items ~= nil then
      assert(type(a.items) == 'table' and #a.items >= 1 and #a.items <= 16, 'items requires 1..16 item names')
      for _, n in ipairs(a.items) do
        assert(type(n) == 'string' and prototypes.item[n], 'items: unknown item ' .. tostring(n))
        if not out[n] then out[n] = true; list[#list+1] = n end
      end
    end
    assert(#list > 0, 'belt pickup needs item (or items): the items to take off the belts')
    return out, list
  end
  -- What a belt's lanes carry: {name: count} of all, and of the wanted.
  local function carried(e, wanted)
    local all, want = {}, 0
    for i = 1, try(function() return e.get_max_transport_line_index() end) or 0 do
      for _, c in ipairs(try(function() return e.get_transport_line(i).get_contents() end) or {}) do
        all[c.name] = (all[c.name] or 0) + c.count
        if wanted[c.name] then want = want + c.count end
      end
    end
    return all, want
  end
  local function belts_in(surface, force, box)
    return try(function() return surface.find_entities_filtered{area=box, type=BELTS, force=force, limit=SAMPLE} end) or {}
  end

  function M.pickup(p, a)
    local wanted, names = wanted_of(a)
    local box
    if a.area ~= nil then
      assert(a.position == nil and a.radius == nil, 'give area, or position and radius')
      local lt, rb = api.position(a.area.left_top), api.position(a.area.right_bottom)
      assert(rb.x > lt.x and rb.y > lt.y and rb.x - lt.x <= 64 and rb.y - lt.y <= 64, 'area must be nonempty and at most 64x64')
      box = {left_top=lt, right_bottom=rb}
    else
      local c = a.position and api.position(a.position) or p.position
      local r = api.integer(a.radius, 8, 1, 32, 'radius')
      box = {left_top={x=c.x - r, y=c.y - r}, right_bottom={x=c.x + r, y=c.y + r}}
    end
    -- In sight, or on the map in a chunk our force sees now (Luna, d15 09:20: belts past the 32-tile sight were refused,
    -- though the map shows them; the walk brings them into reach).
    local centre = {x=(box.left_top.x + box.right_bottom.x) / 2, y=(box.left_top.y + box.right_bottom.y) / 2}
    local seen = try(function() return p.force.is_chunk_visible(p.surface, {x=math.floor(centre.x / 32), y=math.floor(centre.y / 32)}) end)
    if not seen then api.assert_visible(p, centre, 'pickup area') end
    -- to: a chest the items go into at the end, in the same walk (Luna, d15 09:20: a belt-to-chest move).
    local to
    if a.to ~= nil then
      local pos = api.position(a.to)
      to = api.chest and api.chest(p, pos)
      assert(to, 'to: no chest of ours at ' .. at(pos))
    end
    local count = api.integer(a.count, 100, 1, 10000, 'count')
    local ticks = api.integer(a.ticks, 3600, 1, 36000, 'ticks')
    local belts = belts_in(p.surface, p.force, box)
    local on, all, tiles = 0, {}, 0
    for _, e in ipairs(belts) do
      local c, w = carried(e, wanted)
      if w > 0 then tiles = tiles + 1; on = on + w end
      for n, k in pairs(c) do all[n] = (all[n] or 0) + k end
    end
    if on == 0 then
      local parts = {}
      for n, k in pairs(all) do parts[#parts+1] = {n=n, k=k} end
      table.sort(parts, function(x, y) return x.k > y.k or (x.k == y.k and x.n < y.n) end)
      local shown = {}
      for i = 1, math.min(5, #parts) do shown[i] = parts[i].n .. '*' .. parts[i].k end
      error(string.format('no %s on our belts in (%g,%g)-(%g,%g): %s', table.concat(names, ', '),
        box.left_top.x, box.left_top.y, box.right_bottom.x, box.right_bottom.y,
        #belts == 0 and 'no belt of ours there' or ('they carry ' .. (#shown > 0 and table.concat(shown, ' ') or 'nothing'))), 0)
    end
    local ch = p.character
    local reach = ch and ch.valid and ch.prototype and ch.prototype.item_pickup_distance or 1
    assert(a.spoiled_first == nil or type(a.spoiled_first) == 'boolean', 'spoiled_first must be true or false')
    local min_spoiled = a.min_spoiled ~= nil and api.integer(a.min_spoiled, nil, 0, 100, 'min_spoiled (0..100 percent)') or nil
    local action = {kind='pickup', belt=true, area=box, items=names, count=count, reach=reach, until_tick=game.tick + ticks,
      spoiled_first=a.spoiled_first or nil, min_spoiled=min_spoiled,
      skips={}, skipped=0, taken=0, idle_since=game.tick, to=to, to_position=to and {x=to.position.x, y=to.position.y} or nil}
    api.start(p, action)
    return {until_tick=action.until_tick, area=box, belt_tiles=tiles, on_belts=on, count=count,
      to=to and string.format('%s %s: what is taken goes in there at the end, in the same walk', to.name, at(to.position)) or nil,
      rate='about one item a tick, from belts within your pickup distance (' .. reach .. ' tiles)'}
  end

  local function quality_of(q) if type(q) == 'string' then return q end; return q and try(function() return q.name end) or 'normal' end
  -- Takes up to n wanted items off a belt's lanes into the character: what the inventory takes, each kept with its
  -- spoilage. Returns the count taken, or nil and 'inventory_full'.
  -- The wanted stacks on a belt's lanes with their spoilage: {line, st, spoil (0..1)}, spoiled_first: the most spoiled
  -- first; min_spoiled: only stacks at least that spoiled (d17 batch13 D2, Grok 4x: walking to a rotten egg, the return
  -- inserter had taken it and the pickup grabbed the fresh ones instead).
  local function stacks_of(e, action)
    local wanted = {}
    for _, name in ipairs(action.items) do wanted[name] = true end
    local out = {}
    for i = 1, try(function() return e.get_max_transport_line_index() end) or 0 do
      local line = try(function() return e.get_transport_line(i) end)
      for _, d in ipairs(line and try(function() return line.get_detailed_contents() end) or {}) do
        local st = d.stack
        if st and try(function() return st.valid_for_read end) and wanted[st.name] and (not action.quality or quality_of(st.quality) == action.quality) then
          local sp = try(function() return st.spoil_percent end) or 0
          if not action.min_spoiled or sp * 100 >= action.min_spoiled then out[#out+1] = {line=line, st=st, spoil=sp} end
        end
      end
    end
    if action.spoiled_first then table.sort(out, function(x, y) return x.spoil > y.spoil end) end
    return out
  end
  M.stacks_of = stacks_of
  local function take_chosen(p, e, action, n)
    local got = 0
    for _, c in ipairs(stacks_of(e, action)) do
      if got >= n then break end
      local st = c.st
      if try(function() return st.valid_for_read end) then
        local name, q, count = st.name, quality_of(st.quality), st.count
        local k = math.min(n - got, count)
        local put = p.insert{name=name, count=k, quality=q, spoil_percent=c.spoil}
        if put == 0 then return got, 'inventory_full' end
        if put >= count then try(function() st.clear() end) else try(function() st.count = count - put end) end
        got = got + put
        action.picked = action.picked or {}
        action.picked[name] = (action.picked[name] or 0) + put
        action.picked_spoil = action.picked_spoil or {}
        if #action.picked_spoil < 16 then action.picked_spoil[#action.picked_spoil+1] = string.format('%s*%d at %d%% spoiled', name, put, math.floor(c.spoil * 100 + 0.5)) end
        if api.trash and put > 0 then action.trashed = api.trash.count(p, action.trashed, name, q, put) end
        if put < k then return got, 'inventory_full' end
      end
    end
    return got
  end
  local function take(p, e, action, n)
    if action.spoiled_first or action.min_spoiled then return take_chosen(p, e, action, n) end
    local wanted = {}
    for _, name in ipairs(action.items) do wanted[name] = true end
    local got = 0
    for i = 1, try(function() return e.get_max_transport_line_index() end) or 0 do
      local line = try(function() return e.get_transport_line(i) end)
      local detailed = line and try(function() return line.get_detailed_contents() end) or {}
      for _, d in ipairs(detailed) do
        if got >= n then return got end
        local st = d.stack
        if st and try(function() return st.valid_for_read end) and wanted[st.name] and (not action.quality or quality_of(st.quality)==action.quality) then
          local name, q = st.name, quality_of(st.quality)
          local spoil = try(function() return st.spoil_percent end)
          local k = math.min(n - got, st.count)
          local put = p.insert{name=name, count=k, quality=q, spoil_percent=spoil}
          if put == 0 then return got, 'inventory_full' end
          local off = try(function() return line.remove_item{name=name, quality=q, count=put} end) or 0
          -- the belt gave fewer than went in (it moved on): take the rest back out of the character
          if off < put then p.remove_item{name=name, quality=q, count=put - off} end
          got = got + off
          action.picked = action.picked or {}
          action.picked[name] = (action.picked[name] or 0) + off
          if spoil and off > 0 then
            action.picked_spoil = action.picked_spoil or {}
            if #action.picked_spoil < 16 then action.picked_spoil[#action.picked_spoil+1] = string.format('%s*%d at %d%% spoiled', name, off, math.floor(spoil * 100 + 0.5)) end
          end
          if api.trash and off > 0 then action.trashed = api.trash.count(p, action.trashed, name, q, off) end
          if put < k then return got, 'inventory_full' end
        end
      end
    end
    return got
  end
  local function key(pos) return string.format('%.1f,%.1f', pos.x, pos.y) end
  -- Belts in reach (their tile within the pickup distance, plus half a tile) that carry a wanted item.
  local function in_reach(p, action)
    local out = {}
    for _, e in ipairs(try(function() return p.surface.find_entities_filtered{position=p.position, radius=action.reach + 0.5, type=BELTS, force=p.force, limit=16} end) or {}) do
      local wanted = {}
      for _, name in ipairs(action.items) do wanted[name] = true end
      local _, w = carried(e, wanted)
      if w > 0 and (not action.min_spoiled or #stacks_of(e, action) > 0) then out[#out+1] = e end
    end
    -- spoiled_first: the belts holding the most spoiled stack first
    if action.spoiled_first and #out > 1 then
      local most = {}
      for _, e in ipairs(out) do local l = stacks_of(e, action); most[e] = l[1] and l[1].spoil or 0 end
      table.sort(out, function(x, y) return most[x] > most[y] end)
    end
    return out
  end
  local function nearest(p, action)
    local wanted = {}
    for _, name in ipairs(action.items) do wanted[name] = true end
    local best, bd
    for _, e in ipairs(belts_in(p.surface, p.force, action.area)) do
      if not action.skips[key(e.position)] then
        local _, w = carried(e, wanted)
        if w > 0 and (action.min_spoiled or action.spoiled_first) then
          -- (D2) the belt with the most spoiled stack, then the nearest
          local l = stacks_of(e, action)
          if #l > 0 then
            local d = api.distance(p.position, e.position) - (action.spoiled_first and l[1].spoil * 1000 or 0)
            if not bd or d < bd then best, bd = e, d end
          end
        elseif w > 0 then
          local d = api.distance(p.position, e.position)
          if not bd or d < bd then best, bd = e, d end
        end
      end
    end
    return best
  end
  -- The delivery leg of pickup {to}: walk into reach of the chest and put in what was taken.
  local function deliver(p, action, done)
    local c = action.to
    if not (c and c.valid) then action.why = 'the chest at ' .. at(action.to_position) .. ' is gone; what was taken stays with you'; return 'failed' end
    if try(function() return p.can_reach_entity(c) end) then
      if action.nav then api.stop_walking(p); action.nav = nil end
      action.delivered = action.delivered or {}
      local short = false
      for name, n in pairs(action.picked or {}) do
        local out = api.give and api.give(p, c, name, n) or {transferred=0}
        action.delivered[name] = (action.delivered[name] or 0) + (out.transferred or 0)
        if (out.transferred or 0) < n then short = true end
      end
      if short then action.why = 'the chest took less than was taken (full, or a filter); the rest stays with you' end
      return done
    end
    if not action.nav then
      action.nav = {position=c.position, tolerance=math.max(1, (p.reach_distance or 10) - 2), max_stalls=6, replans=0, stalled=0, last_position=p.position}
      api.request_path(p, action.nav)
    end
    local outcome = api.navigate(p, action.nav)
    if outcome then
      api.stop_walking(p); action.nav = nil
      if outcome ~= 'arrived' and outcome ~= 'arrived_near' and not try(function() return p.can_reach_entity(c) end) then
        action.why = 'the walk to the chest at ' .. at(c.position) .. ' ended ' .. outcome .. '; what was taken stays with you'
        return 'blocked'
      end
    end
    return nil
  end
  function M.tick(p, action, tick)
    if action.delivering then return deliver(p, action, action.delivering) end
    if action.to then
      local result = M.pick_tick(p, action, tick)
      if result == 'picked_up' or (result == 'nothing_on_belts' and action.taken > 0) or (result == 'inventory_full' and action.taken > 0) then
        action.delivering = 'transferred'
        if action.nav then api.stop_walking(p); action.nav = nil end
        return deliver(p, action, action.delivering)
      end
      return result
    end
    return M.pick_tick(p, action, tick)
  end
  function M.pick_tick(p, action, tick)
    if action.taken >= action.count then return 'picked_up' end
    local here = in_reach(p, action)
    if #here > 0 then
      if action.nav then api.stop_walking(p); action.nav = nil end
      action.target = nil
      action.idle_since = tick
      if tick < (action.next_pick or 0) then return nil end
      action.next_pick = tick + PICK_EVERY
      local left = math.min(PER_PICK, action.count - action.taken)
      for _, e in ipairs(here) do
        if left <= 0 then break end
        local got, why = take(p, e, action, left)
        action.taken = action.taken + got
        left = left - got
        if why then return why end
      end
      return action.taken >= action.count and 'picked_up' or nil
    end
    if action.target and not action.nav then
      action.skips[action.target] = true; action.skipped = action.skipped + 1; action.target = nil
      if action.skipped >= MAX_SKIPS then return 'blocked' end
    end
    if not action.nav then
      local e = nearest(p, action)
      if not e then
        -- nothing on the area's belts: wait IDLE_TICKS for more to come along
        if tick - action.idle_since >= IDLE_TICKS then return action.taken > 0 and 'picked_up' or 'nothing_on_belts' end
        return nil
      end
      action.idle_since = tick
      action.target = key(e.position)
      action.nav = {position=e.position, tolerance=math.max(0.6, action.reach), max_stalls=6, replans=0, stalled=0, last_position=p.position}
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
  M.take = take
  function M.count(e,item,quality)
    local n=0
    for i=1,try(function() return e.get_max_transport_line_index() end) or 0 do
      for _,c in ipairs(e.get_transport_line(i).get_contents()) do
        if c.name==item and quality_of(c.quality)==(quality or 'normal') then n=n+c.count end
      end
    end
    return n
  end
  M.at = at
  return M
end
