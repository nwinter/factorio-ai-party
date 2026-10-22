-- A robot as the game gives it (d20 batch70 AF4, Astra #1718: on Aquilo 4-5 robots read no_storage near (-20,-14)
-- while 31 storage chests were full, and scan's inventory and inspect over an area said every robot held nothing,
-- robots at one spot with no unit_number to tell them apart). 2.0.77 gives a logistic or construction robot its
-- cargo (defines.inventory.robot_cargo: one slot), robot_order_queue (each order: type, target entity, target_item
-- {name, quality}, target_count; read on the private copy, Aquilo network #348: 22 of 23 robots held cryogenic
-- science packs, 18 of them with no order, 10 at one roboport's spot) and its logistic network. The game's no_storage
-- alert targets the robot itself. Nothing records where a robot picked up what it holds.
return function(api)
  local M = {}
  M.ROBOT = {['logistic-robot']=true, ['construction-robot']=true}
  M.ORDERS = 3
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local names
  local function order_name(t)
    if not names then names = {}; for k, v in pairs(defines.robot_order_type or {}) do names[v] = k end end
    return names[t] or tostring(t)
  end
  -- a quality or item as the game gives it (a prototype, userdata) or by name
  local function qname(q) if q ~= nil and type(q) ~= 'string' then return try(function() return q.name end) end return q end
  local function at(p) return string.format('(%g,%g)', math.floor(p.x * 10 + 0.5) / 10, math.floor(p.y * 10 + 0.5) / 10) end
  -- What it carries: {name, quality, count} or nil.
  function M.cargo(r)
    local inv = try(function() return r.get_inventory(defines.inventory.robot_cargo) end)
    local s = inv and try(function() return inv[1] end)
    if not (s and try(function() return s.valid_for_read end)) then return nil end
    return {name=s.name, quality=qname(try(function() return s.quality end)) or 'normal', count=s.count}
  end
  local function item_text(name, quality, count)
    return name .. (quality and quality ~= 'normal' and '@' .. quality or '') .. (count and ' ' .. count or '')
  end
  -- Its orders, first (the one it flies now) first: [{type, item, quality, count, target, target_position,
  -- target_unit_number, line}].
  function M.orders(r)
    local out = {}
    for i, o in ipairs(try(function() return r.robot_order_queue end) or {}) do
      if i > M.ORDERS then break end
      local t = o.target
      local ok = t and try(function() return t.valid end)
      local item = o.target_item
      local row = {type=order_name(o.type), item=item and qname(item.name), quality=item and qname(item.quality) or nil,
        count=o.target_count, target=ok and t.name or nil, target_position=ok and {x=t.position.x, y=t.position.y} or nil,
        target_unit_number=ok and try(function() return t.unit_number end) or nil}
      if row.quality == 'normal' then row.quality = nil end
      row.line = row.type .. (row.item and ' ' .. item_text(row.item, row.quality, row.count) or '') ..
        (row.target and string.format(' %s %s %s%s', row.type == 'pickup' and 'from' or row.type == 'deliver' and 'to' or 'at', row.target, at(row.target_position),
          row.target_unit_number and ' #' .. row.target_unit_number or '') or (t and ' (its target gone)' or ''))
      out[#out+1] = row
    end
    return out
  end
  -- holds as inspect and scan write it: "cryogenic-science-pack*3" or "empty".
  function M.holds(r)
    local c = M.cargo(r)
    return c and (c.name .. (c.quality ~= 'normal' and '@' .. c.quality or '') .. '*' .. c.count) or 'empty'
  end
  -- The whole read: {unit_number, name, position, cargo, orders, orders_queued, network, line}.
  function M.row(r)
    local c = M.cargo(r)
    local list = M.orders(r)
    local n = #(try(function() return r.robot_order_queue end) or {})
    local net = try(function() local ln = r.logistic_network; return ln and ln.network_id end)
    local first = list[1]
    local line = string.format('%s #%s at %s: %s; %s', r.name, tostring(r.unit_number), at(r.position),
      c and 'carries ' .. item_text(c.name, c.quality, c.count) or 'carries nothing',
      first and first.line .. (n > 1 and string.format(' (%d orders queued)', n) or '') or 'no order')
    return {unit_number=r.unit_number, name=r.name, position={x=r.position.x, y=r.position.y}, cargo=c,
      orders=#list > 0 and list or nil, orders_queued=n > M.ORDERS and n or nil, network=net, line=line}
  end
  return M
end
