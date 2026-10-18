-- gates {surface?, area?} (d17 batch22 B3, Muse: backup boilers gated on coal > 8000 in a network holding 3609 never
-- started, found by a viewer): every circuit and logistic condition on our entities there, as their GUIs show them,
-- with what each reads now and whether it holds; a logistic condition "item > N" (or >=, =) that the network cannot
-- reach is flagged: the most it could hold is its count now and what its storage and provider chests could still take
-- of the item. Read only. area (up to 128x128): a find there now; else the surface (default yours) from the census's
-- last pass (entities with a control behavior, up to 1024 a surface), read now one by one. At most MAX_LINES lines,
-- MAX_CHESTS chests a network looked at.
return function(api)
  local M = {}
  -- PAGE and CHEST_BUDGET as timed on world n: about 50 us an entity read, 3 us a chest looked at, 2 ms to sort 1024
  local MAX_LINES, MAX_CHESTS, PAGE, CHEST_BUDGET = 64, 256, 128, 512
  local budget = CHEST_BUDGET
  local TYPES = {'inserter', 'pump', 'offshore-pump', 'assembling-machine', 'furnace', 'mining-drill', 'lamp', 'power-switch',
    'transport-belt', 'train-stop', 'rail-signal', 'rail-chain-signal', 'agricultural-tower', 'asteroid-collector', 'loader', 'loader-1x1'}
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function at(q) return string.format('(%g,%g)', q.x, q.y) end
  -- The most a network could hold of an item, up to need: its count and what its storage and provider chests could
  -- take more, looked at only when the count is under need and only until need is reached.
  local reach_cache = {}
  local function most(net, item, need)
    local k = tostring(try(function() return net.network_id end)) .. '|' .. item
    local v = reach_cache[k]
    if not v then
      v = {count=try(function() return net.get_item_count(item) end) or 0, room=0, looked=0, i=1, j=0, done=false}
      reach_cache[k] = v
    end
    v.most = v.count + v.room
    if not need or v.done or v.most >= need then return v end
    v.lists = v.lists or {try(function() return net.storages end) or {}, try(function() return net.passive_provider_points end) or {}}
    while v.i <= 2 and v.most < need and v.looked < MAX_CHESTS and budget > 0 do
      v.j = v.j + 1
      local x = v.lists[v.i][v.j]
      if not x then v.i, v.j = v.i + 1, 0
      else
        -- storages are entities (an unknown key on one is an error); provider points carry their owner
        local e = v.i == 1 and x or try(function() return x.owner end)
        local inv = e and try(function() return e.get_inventory(defines.inventory.chest) end)
        if inv then budget = budget - 1; v.looked = v.looked + 1; v.room = v.room + (try(function() return inv.get_insertable_count(item) end) or 0); v.most = v.count + v.room end
      end
    end
    v.all = v.i > 2
    v.done = v.all or v.looked >= MAX_CHESTS
    return v
  end
  local GT = {['>']=true, ['>=']=true, ['≥']=true, ['=']=true}
  function M.row(e)
    local cb = try(function() return e.get_control_behavior() end)
    if not cb then return nil end
    local c = api.circuit_read and try(function() return api.circuit_read(e, cb) end) or {}
    local parts, flag = {}, nil
    if type(c.enable) == 'string' then
      local cond = try(function() return cb.circuit_condition end)
      local v = api.wire_value and cond and cond.first_signal and try(function() return api.wire_value(e, cond.first_signal) end)
      parts[#parts+1] = string.format('circuit condition %s%s: %s now', c.enable, v and string.format(' (%s %d on its wires)', cond.first_signal.name, v) or '',
        c.enable_met == true and 'true' or c.enable_met == false and 'false' or 'unknown')
    end
    if type(c.logistic) == 'string' then
      local cond = try(function() return cb.logistic_condition end)
      local sig = cond and cond.first_signal
      local net = try(function() return e.surface.find_logistic_network_by_position(e.position, e.force) end)
      local text = string.format('logistic condition %s', c.logistic)
      if sig and sig.name and net and (sig.type == nil or sig.type == 'item') then
        local constant = cond.constant
        local need = GT[cond.comparator or ''] and type(constant) == 'number' and not cond.second_signal and ((cond.comparator == '>' and constant + 1) or constant) or nil
        local m = most(net, sig.name, need)
        text = text .. string.format(' (network %s: %s %d%s)', tostring(try(function() return net.network_id end)), sig.name, m.count,
          api.negative_note and api.negative_note(sig.name, m.count) or '')
        if need then
          if need > m.most and m.all then
            flag = 'cannot be met'
            text = text .. string.format('; it can never hold: the network holds %d and its storage and provider chests take %d more (%d looked at): at most %d',
              m.count, m.room, m.looked, m.most)
          elseif need > m.most then
            text = text .. string.format('; the network holds %d and the %d storage and provider chests looked at take %d more (the rest not looked at: %s)',
              m.count, m.looked, m.room, m.looked >= MAX_CHESTS and MAX_CHESTS .. ' a network and item' or CHEST_BUDGET .. ' a call')
          end
        end
      elseif not net then text = text .. ' (no logistic network holds its centre: never met)'; flag = 'cannot be met' end
      parts[#parts+1] = text .. string.format(': %s now', c.logistic_met == true and 'true' or c.logistic_met == false and 'false' or 'unknown')
    end
    if #parts == 0 then return nil end
    local met = not (c.enable_met == false or c.logistic_met == false)
    local st = try(function() return e.status end)
    local off = st and defines.entity_status and st == defines.entity_status.disabled_by_control_behavior
    return {name=e.name, position={x=e.position.x, y=e.position.y}, met=met, off=off or nil, flag=flag,
      line=string.format('%s %s: %s%s', e.name, at(e.position), table.concat(parts, '; '), off and '; it is off by it' or '')}
  end
  function M.read(p, a)
    reach_cache, budget = {}, CHEST_BUDGET
    local list, as_of, s = {}, nil, p.surface
    if a.area ~= nil then
      local lt, rb = api.position(a.area.left_top), api.position(a.area.right_bottom)
      assert(rb.x > lt.x and rb.y > lt.y and rb.x - lt.x <= 128 and rb.y - lt.y <= 128, 'area is {left_top, right_bottom}, at most 128x128')
      local found = s.find_entities_filtered{area={lt, rb}, force=p.force, type=TYPES, limit=4096}
      for _, e in ipairs(found) do if try(function() return e.get_control_behavior() end) then list[#list+1] = e end end
    else
      if a.surface ~= nil then s = game.get_surface(a.surface); assert(s, 'no surface ' .. tostring(a.surface)) end
      list, as_of = api.gated(p.force, s)
    end
    -- PAGE entities a call (page: N for the next), in reading order
    -- (each position read once: a comparator reading it is an engine call each compare)
    local keyed = {}
    for i, e in ipairs(list) do local q = e.position; keyed[i] = {e=e, x=q.x, y=q.y} end
    table.sort(keyed, function(a, b) return a.y < b.y or a.y == b.y and a.x < b.x end)
    for i, k in ipairs(keyed) do list[i] = k.e end
    local pages = math.max(1, math.ceil(#list / PAGE))
    local page = api.integer and api.integer(a.page, 1, 1, pages, 'page') or 1
    local rows = {}
    for i = (page - 1) * PAGE + 1, math.min(#list, page * PAGE) do
      local e = list[i]
      if e.valid then local r = try(function() return M.row(e) end); if r then rows[#rows+1] = r end end
    end
    table.sort(rows, function(x, y)
      local rx = x.flag and 0 or (not x.met) and 1 or 2
      local ry = y.flag and 0 or (not y.met) and 1 or 2
      if rx ~= ry then return rx < ry end
      if x.position.y ~= y.position.y then return x.position.y < y.position.y end
      return x.position.x < y.position.x
    end)
    local lines, never, unmet = {}, 0, 0
    for i, r in ipairs(rows) do
      if r.flag then never = never + 1 elseif not r.met then unmet = unmet + 1 end
      if i <= MAX_LINES then lines[#lines+1] = (r.flag and 'CANNOT BE MET: ' or '') .. r.line end
    end
    return {surface=s.name, gates=#rows, cannot_be_met=never, not_met=unmet, met=#rows - never - unmet, lines=lines,
      more=#rows > MAX_LINES and #rows - MAX_LINES or nil, page=pages > 1 and page or nil, pages=pages > 1 and pages or nil,
      next=page < pages and string.format('gates {page: %d} reads the next %d entities', page + 1, PAGE) or nil,
      as_of=as_of, source=a.area and 'the area, read now' or (as_of and 'the census\'s last pass, each read now' or 'no census pass yet on this surface'),
      line=string.format('%d gates on %s: %d cannot be met, %d not met now, %d met', #rows, s.name, never, unmet, #rows - never - unmet)}
  end
  M.schema = {gates={surface='optional surface name (default yours): every gate the census\'s last pass found there (entities with a control behavior, up to 1024), each read now',
    area='optional {left_top, right_bottom} up to 128x128: the gates there, read now', page='optional: 128 entities a call in reading order (pages, next)',
    returns='gates, cannot_be_met, not_met, met (counts); lines: one an entity with a circuit or logistic condition: the condition as its GUI shows it, what it reads now (a circuit signal on its wires; the logistic network\'s count), true or false now, it is off by it; "CANNOT BE MET:" first for a logistic condition item > N, >= N or = N above what the network can hold (its count and what its storage and provider chests could still take of the item; up to 256 chests a network and item, 512 a call: a look cut short says what it saw, unflagged), or one with no logistic network over it; then the ones not met now; more; as_of, source; line. Read only'}}
  return M
end
