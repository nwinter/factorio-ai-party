-- The character's own settings (d20 batch59 U1, Astra #1480 for viewer Foobator): the switches a player flips in the
-- character GUI and on the shortcut bar, and the main inventory's slot filters (a player middle-clicks a slot), read
-- and written. Read on 2.0.77:
-- - personal logistics (the requests' master switch): the character requester point's enabled;
-- - the personal roboport: the character's allow_dispatching_robots;
-- - the equipment movement bonus: the armor grid's inhibit_movement_bonus (on = not inhibited);
-- - slot filters: the main inventory's set_filter / get_filter (a filtered slot takes only its item; an empty one
--   stays held for it).
-- A request counts what the main inventory, the gun, ammo and armor slots hold, and robots bring nothing that no slot
-- can take (personal.lua says so per request). An edit changes only what it names; every argument is checked before
-- anything changes, and the reply is the read after it.
return function(api)
  local M = {}
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function at(q) return string.format('(%g,%g)', math.floor(q.x * 10 + 0.5) / 10, math.floor(q.y * 10 + 0.5) / 10) end
  local function onoff(v) return v and 'on' or 'off' end
  local function name_of(v)
    if type(v) == 'string' then return v end
    local n = v ~= nil and try(function() return v.name end)
    if type(n) == 'string' then return n end
    return n ~= nil and try(function() return n.name end) or nil
  end
  local function requester(c) return try(function() return c.get_logistic_point(defines.logistic_member_index.character_requester) end) end
  local function network(n)
    if n and try(function() return n.valid end) == false then return nil end
    return n
  end
  local function grid_of(c) return try(function() return c.grid end) end
  local function equipment_of(grid, kind)
    local n, energy, max = 0, 0, 0
    for _, e in ipairs(grid and try(function() return grid.equipment end) or {}) do
      if try(function() return e.type end) == kind then
        n = n + 1
        energy = energy + (try(function() return e.energy end) or 0)
        max = max + (try(function() return e.max_energy end) or 0)
      end
    end
    return n, energy, max
  end
  local function main(c) return try(function() return c.get_main_inventory() end) end

  -- The filtered slots: {slot, item, quality, holds}, and the counts the line gives.
  local function filters(inv)
    local rows, free, filtered = {}, 0, 0
    for i = 1, inv and #inv or 0 do
      local f = try(function() return inv.get_filter(i) end)
      local st = inv[i]
      local held = try(function() return st.valid_for_read end) and st or nil
      if f then
        filtered = filtered + 1
        local q = name_of(f.quality)
        rows[#rows+1] = {slot=i, item=name_of(f.name) or name_of(f), quality=q and q ~= 'normal' and q or nil,
          holds=held and (held.name .. '*' .. held.count) or 'empty'}
      elseif not held then free = free + 1 end
    end
    return rows, free, filtered
  end
  local function filter_line(rows, free, size)
    if #rows == 0 then return string.format('no slot filtered; %d of %d slots free', free, size) end
    -- Runs of slots one after another with the same filter, all empty, read as one: "1-90 wood (empty)".
    local parts, i = {}, 1
    while i <= #rows and #parts < 12 do
      local r, j = rows[i], i
      while r.holds == 'empty' and rows[j+1] and rows[j+1].slot == rows[j].slot + 1 and rows[j+1].item == r.item
        and rows[j+1].quality == r.quality and rows[j+1].holds == 'empty' do j = j + 1 end
      parts[#parts+1] = string.format('%s %s%s (%s)', j > i and r.slot .. '-' .. rows[j].slot or tostring(r.slot), r.item, r.quality and '@' .. r.quality or '', r.holds)
      i = j + 1
    end
    return string.format('%d slot%s filtered: %s%s; %d of %d slots free (empty and unfiltered)', #rows, #rows == 1 and '' or 's',
      table.concat(parts, ', '), i <= #rows and ', ...' or '', free, size)
  end

  -- Why the game sends robots or not, from what it shows: the switches, the networks, the room in the inventory.
  local function networks(p, c, pt, inv, free)
    local out = {}
    local pos = c.position
    -- (read on 2.0.77: with personal logistics off the requester point's network reads invalid; the network where the
    -- character stands is then found by position)
    local off = pt and try(function() return pt.enabled end) == false
    local ln = pt and network(try(function() return pt.logistic_network end))
      or network(try(function() return c.surface.find_logistic_network_by_position(pos, c.force) end))
    if ln then
      out.logistic = string.format('logistic network #%s: %d logistic robots (%d idle); %s',
        tostring(try(function() return ln.network_id end) or '?'), try(function() return ln.all_logistic_robots end) or 0, try(function() return ln.available_logistic_robots end) or 0,
        off and 'its logistic area covers where you stand; your personal logistics are off, so no request of yours goes to it' or 'your requests are filled from it')
    else
      out.logistic = 'none: no roboport\'s logistic area covers ' .. at(pos) .. ', so robots bring nothing for your requests here'
    end
    local ids = {}
    for _, n in ipairs(try(function() return c.surface.find_logistic_networks_by_construction_area(pos, c.force) end) or {}) do
      local own = try(function() return n.cells[1].owner end)
      if own ~= c then
        ids[#ids+1] = string.format('#%s (%d construction robots, %d idle)', tostring(try(function() return n.network_id end) or '?'),
          try(function() return n.all_construction_robots end) or 0, try(function() return n.available_construction_robots end) or 0)
      end
    end
    out.construction = #ids > 0 and ('construction areas of roboports cover ' .. at(pos) .. ': ' .. table.concat(ids, ', '))
      or ('no roboport\'s construction area covers ' .. at(pos))
    -- The personal roboport: its switch, the robots it sends (from your main inventory), its energy, its area.
    local grid = grid_of(c)
    local n, energy, max = equipment_of(grid, 'roboport-equipment')
    local stop = {}
    if n == 0 then out.personal_roboport = 'no personal roboport in your armor' else
      local cell = try(function() return c.logistic_cell end)
      local own = cell and network(try(function() return cell.logistic_network end))
      local robots = inv and (try(function() return inv.get_item_count('construction-robot') end) or 0) or 0
      local out_now = own and try(function() return own.all_construction_robots - own.available_construction_robots end) or 0
      local on = try(function() return c.allow_dispatching_robots end)
      out.personal_roboport = string.format('%d personal roboport%s, %s: construction radius %s, %d construction robots in your inventory, %d out now; energy %d%%',
        n, n == 1 and '' or 's', onoff(on), tostring(cell and try(function() return cell.construction_radius end) or 0), robots, out_now,
        max > 0 and math.floor(energy / max * 100 + 0.5) or 0)
      if on == false then stop[#stop+1] = 'your personal roboport is switched off: it sends no robots' end
      if robots == 0 and out_now == 0 then stop[#stop+1] = 'no construction robot in your inventory: your personal roboport has none to send' end
      if max > 0 and energy <= 0 then stop[#stop+1] = 'your personal roboport has no energy' end
    end
    if pt and try(function() return pt.enabled end) == false then stop[#stop+1] = 'your personal logistics are switched off: robots bring nothing for your requests' end
    if inv and free == 0 then stop[#stop+1] = 'your main inventory has no free slot (empty and unfiltered): robots bring only what fits a stack you hold, a slot filtered to it, or your gun, ammo and armor slots' end
    out.not_dispatched = #stop > 0 and stop or nil
    local rows = api.personal and try(function() return api.personal().unfilled(p) end)
    if rows and #rows > 0 then
      local lines = {}
      for i, r in ipairs(rows) do if i <= 12 then lines[i] = r.line end end
      out.unfilled = lines
    end
    return out
  end

  function M.read(p)
    local c = p.character
    assert(c and c.valid, 'you have no character')
    local pt = requester(c)
    local inv = main(c)
    local grid = grid_of(c)
    local out = {}
    local researched = try(function() return p.force.character_logistic_requests end)
    out.personal_logistics = pt and (onoff(try(function() return pt.enabled end) ~= false)
      .. (researched == false and ' (the force has not researched personal logistics: no request is made)' or '')) or 'none: the character has no requester point'
    local rp = equipment_of(grid, 'roboport-equipment')
    out.personal_roboport = onoff(try(function() return c.allow_dispatching_robots end) ~= false) .. (rp == 0 and ' (no personal roboport in your armor)' or '')
    if grid then
      local ex = equipment_of(grid, 'movement-bonus-equipment')
      out.movement_bonus = onoff(not try(function() return grid.inhibit_movement_bonus end)) .. (ex == 0 and ' (no exoskeleton in your armor)' or '')
    else
      out.movement_bonus = 'none: your armor has no equipment grid'
    end
    local rows, free, _ = filters(inv)
    local size = inv and #inv or 0
    out.filters_line = filter_line(rows, free, size)
    if #rows > 40 then out.filters_more = #rows - 40; for k = #rows, 41, -1 do rows[k] = nil end end
    out.filters = rows
    out.networks = networks(p, c, pt, inv, free)
    return out
  end

  local SWITCHES = {personal_logistics=true, personal_roboport=true, movement_bonus=true}
  function M.handle(p, a)
    a = a or {}
    for k in pairs(SWITCHES) do assert(a[k] == nil or type(a[k]) == 'boolean', k .. ' must be true or false') end
    local c = p.character
    assert(c and c.valid, 'you have no character')
    local inv = main(c)
    local pt = requester(c)
    local grid = grid_of(c)
    -- Every argument checked before anything changes.
    if a.personal_logistics ~= nil then assert(pt, 'the character has no requester point to switch') end
    if a.movement_bonus ~= nil then assert(grid, 'movement_bonus: your armor has no equipment grid') end
    local edits = {}
    if a.filters ~= nil then
      assert(type(a.filters) == 'table' and #a.filters >= 1 and #a.filters <= 200, 'filters is a list of 1..200 {slot, item} (item false clears the slot\'s filter)')
      local seen = {}
      for i, f in ipairs(a.filters) do
        assert(type(f) == 'table', 'filters[' .. i .. '] must be {slot, item}')
        for k in pairs(f) do assert(k == 'slot' or k == 'item' or k == 'quality', 'filters[' .. i .. ']: ' .. tostring(k) .. ' is not slot, item or quality') end
        local size = inv and #inv or 0
        local slot = f.slot
        assert(type(slot) == 'number' and slot == math.floor(slot) and slot >= 1 and slot <= size,
          string.format('filters[%d].slot must be 1..%d (your main inventory\'s slots)', i, size))
        assert(not seen[slot], 'slot ' .. slot .. ' is named twice'); seen[slot] = true
        assert(f.item == false or type(f.item) == 'string', string.format('filters[%d].item must be an item name, or false to clear', i))
        local q = f.quality or 'normal'
        if f.item then
          assert(prototypes.item[f.item], 'no item named ' .. f.item)
          assert(type(q) == 'string' and prototypes.quality[q], 'no quality named ' .. tostring(q))
          -- A player filters a slot to the item it holds, or an empty slot to any item.
          local st = inv[slot]
          if st.valid_for_read then
            local sq = name_of(st.quality) or 'normal'
            assert(st.name == f.item and sq == q, string.format('slot %d holds %s*%d%s: a slot that holds an item takes a filter for that item only',
              slot, st.name, st.count, sq ~= 'normal' and '@' .. sq or ''))
          end
        else
          assert(f.quality == nil, 'filters[' .. i .. ']: quality goes with an item')
        end
        edits[#edits+1] = {slot=slot, item=f.item, quality=q}
      end
    end
    local changed = {}
    local function note(what, was, now) if was ~= now then changed[#changed+1] = what .. ' ' .. was .. ' -> ' .. now end end
    if a.personal_logistics ~= nil then
      local was = onoff(try(function() return pt.enabled end) ~= false)
      pt.enabled = a.personal_logistics
      note('personal logistics', was, onoff(pt.enabled))
      assert(pt.enabled == a.personal_logistics, 'the game kept personal logistics ' .. onoff(pt.enabled))
    end
    if a.personal_roboport ~= nil then
      local was = onoff(c.allow_dispatching_robots)
      c.allow_dispatching_robots = a.personal_roboport
      note('personal roboport', was, onoff(c.allow_dispatching_robots))
      assert(c.allow_dispatching_robots == a.personal_roboport, 'the game kept the personal roboport ' .. onoff(c.allow_dispatching_robots))
    end
    if a.movement_bonus ~= nil then
      local was = onoff(not grid.inhibit_movement_bonus)
      grid.inhibit_movement_bonus = not a.movement_bonus
      note('movement bonus', was, onoff(not grid.inhibit_movement_bonus))
      assert(grid.inhibit_movement_bonus == not a.movement_bonus, 'the game kept the movement bonus ' .. onoff(not grid.inhibit_movement_bonus))
    end
    for _, e in ipairs(edits) do
      local before = try(function() return inv.get_filter(e.slot) end)
      local was = before and ((name_of(before.name) or '?') .. ((name_of(before.quality) or 'normal') ~= 'normal' and '@' .. name_of(before.quality) or '')) or 'none'
      local ok = inv.set_filter(e.slot, e.item and {name=e.item, quality=e.quality} or nil)
      assert(ok ~= false, string.format('the game refused a filter on slot %d', e.slot))
      local after = try(function() return inv.get_filter(e.slot) end)
      local now = after and ((name_of(after.name) or '?') .. ((name_of(after.quality) or 'normal') ~= 'normal' and '@' .. name_of(after.quality) or '')) or 'none'
      note('slot ' .. e.slot .. ' filter', was, now)
    end
    local out = M.read(p)
    if next(edits) or a.personal_logistics ~= nil or a.personal_roboport ~= nil or a.movement_bonus ~= nil then
      out.changed = #changed > 0 and changed or nil
      out.unchanged = #changed == 0 and 'each setting named was already so' or nil
    end
    return out
  end
  return M
end
