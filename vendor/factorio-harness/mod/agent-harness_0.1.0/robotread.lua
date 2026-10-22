-- A robot as a player sees it (d20 batch70 AF4, Astra #1718: on Aquilo 4-5 robots read no_storage near (-20,-14)
-- while 31 storage chests were full, and scan's inventory and inspect over an area said every robot held nothing,
-- robots at one spot with no unit_number to tell them apart). 2.0.77 gives a logistic or construction robot its
-- cargo (defines.inventory.robot_cargo: one slot; the robot's sprite changes when it carries something) and
-- robot_order_queue; read on the private copy, Aquilo network #348: 22 of 23 robots held cryogenic science packs,
-- 18 of them with no order, 10 at one roboport's spot. The game's no_storage alert targets the robot itself. AF5
-- (operator): only what a player sees: what it carries and where it flies (its first order's target position, as
-- watching it shows); no order type, target entity, target unit number or count, which the game's GUI does not show.
-- Nothing records where a robot picked up what it holds.
return function(api)
  local M = {}
  M.ROBOT = {['logistic-robot']=true, ['construction-robot']=true}
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
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
  -- Where it flies: its first order's target position ({x, y}), or nil (no order, or the target gone).
  function M.heading(r)
    local o = (try(function() return r.robot_order_queue end) or {})[1]
    local t = o and o.target
    if not (t and try(function() return t.valid end)) then return nil end
    return {x=t.position.x, y=t.position.y}
  end
  -- holds as inspect and scan write it: "cryogenic-science-pack*3" or "empty".
  function M.holds(r)
    local c = M.cargo(r)
    return c and (c.name .. (c.quality ~= 'normal' and '@' .. c.quality or '') .. '*' .. c.count) or 'empty'
  end
  -- "flying to (x,y)" or nil
  function M.heading_text(h) return h and 'flying to ' .. at(h) or nil end
  -- The whole read: {unit_number, name, position, cargo, heading, network, line}.
  function M.row(r)
    local c = M.cargo(r)
    local h = M.heading(r)
    local net = try(function() local ln = r.logistic_network; return ln and ln.network_id end)
    local line = string.format('%s #%s at %s: %s%s', r.name, tostring(r.unit_number), at(r.position),
      c and 'carries ' .. item_text(c.name, c.quality, c.count) or 'carries nothing', h and '; ' .. M.heading_text(h) or '')
    return {unit_number=r.unit_number, name=r.name, position={x=r.position.x, y=r.position.y}, cargo=c, heading=h,
      network=net, line=line}
  end
  return M
end
