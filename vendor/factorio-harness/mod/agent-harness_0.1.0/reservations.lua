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
    if (try(function() return inv.count_empty_stacks() end) or 0) > 0 then return true end
    return (try(function() return inv.can_insert({name=item, count=1}) end)) == true
  end
  function M.read(p, a)
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
            local held = inv and try(function() return inv.get_item_count(name) end) or 0
            local short = math.max(0, f.count - held - (coming[name] or 0))
            if short > 0 or (coming[name] or 0) > 0 then
              local full = room(e, name) == false
              rows[#rows+1] = {name=name, ask=f.count, held=held, coming=coming[name] or 0, short=short, full=full}
            end
          end
        end
        if #rows > 0 then
          local parts, short, full = {}, 0, false
          for _, r in ipairs(rows) do
            parts[#parts+1] = string.format('%s asks %d, holds %d, %d on the way%s', r.name, r.ask, r.held, r.coming, r.full and ' (no room for it: every slot taken)' or '')
            short = short + r.short; full = full or (r.full and r.coming > 0)
          end
          local free = inv and try(function() return inv.count_empty_stacks() end)
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
  M.schema = {reservations = {network='logistic network number (networks and an inspect of a roboport give it)', item='optional item name: that item only',
    surface='optional planet name: a network there',
    returns='read only: logistic_robots, idle, reserved_for_pickup; pickups (each provider or storage chest with what robots have reserved to pick up there); requesters (each requester or buffer chest short or with deliveries on the way: per item its request, what it holds, what is on the way, and no room for it when every slot is taken; free slots); robots (the robots\' orders grouped by item and target chest: how many robots, how many items, from where, and when the target has no room); flags (reservations while robots are idle, orders to a chest with no room, requesters with deliveries on the way and no room); lines'}}
  return M
end
