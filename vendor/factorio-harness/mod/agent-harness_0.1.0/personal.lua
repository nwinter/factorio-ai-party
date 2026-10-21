-- Personal logistic requests that are not filled, and why (Haiku, d15 shifts 19-20: 10 repair packs requested at south
-- copper (-10,562) never came, in a network with no logistic robots; Muse). What a player sees: the character's logistic
-- GUI (each request, what is held, what robots bring), and the roboport network's GUI (robots, idle, its items).
-- Per request held plus on the way under its min: the first of these that holds:
-- - personal logistics are switched off (the GUI's checkbox), or the section holding it is off;
-- - no logistic network where the character stands (no roboport's logistic area);
-- - the network has no logistic robots, or none free now;
-- - the network's chests hold none of the item robots can take (all of it reserved by other robots, or none at all);
-- - otherwise: robots are on the way with some, or the network holds it and the robots have not taken it yet.
-- An alert (team.alerts) when a request sits unfilled 60 s or more in a network with 0 logistic robots: once per network
-- and item, again after 10 minutes if still so.
return function(api)
  local M = {}
  local WAIT, AGAIN, EVERY = 3600, 36000, 300
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function at(q) return string.format('(%g,%g)', math.floor(q.x * 10 + 0.5) / 10, math.floor(q.y * 10 + 0.5) / 10) end
  local function name_of(v)
    if type(v) == 'string' then return v end
    local n = v ~= nil and try(function() return v.name end)
    if type(n) == 'string' then return n end
    n = n ~= nil and try(function() return n.name end)
    return type(n) == 'string' and n or nil
  end
  local function count_in(list, name, quality)
    local n = 0
    if type(list) ~= 'table' then return 0 end
    if type(list[name]) == 'number' then return list[name] end
    for _, c in pairs(list) do
      if type(c) == 'table' and name_of(c.name) == name and (quality == nil or (name_of(c.quality) or 'normal') == quality) then n = n + (c.count or 0) end
    end
    return n
  end
  -- A logistic network object the game may hand back invalid (read on 2.0.77: a character's requester point on Gleba).
  function M.network(n)
    if n and try(function() return n.valid end) == false then return nil end
    return n
  end
  local function point_of(c)
    return try(function() return c.get_logistic_point(defines.logistic_member_index.character_requester) end)
  end

  -- Each request held plus on the way under its min: {item, quality, min, held, coming, why}.
  function M.unfilled(p)
    local c = p.character
    if not (c and c.valid) then return nil end
    local pt = point_of(c)
    if not pt then return nil end
    local rows = {}
    local filters = try(function() return pt.filters end) or {}
    local coming = try(function() return pt.targeted_items_deliver end) or {}
    local inv = try(function() return c.get_main_inventory() end) or try(function() return p.get_main_inventory() end)
    -- (d20 batch59 U1, Astra #1480: firearm-magazine and rocket read "hold 0 of 100; ... none has taken it yet" for 25
    -- minutes with 100 of each in her ammo slots) a request counts what the gun, ammo and armor slots hold too, and
    -- robots bring nothing that no slot can take (both checked on 2.0.77).
    local slots = {}
    for _, k in ipairs({'character_guns', 'character_ammo', 'character_armor'}) do
      local i = try(function() return c.get_inventory(defines.inventory[k]) end)
      if i then slots[#slots+1] = {inv=i, what=k:sub(11)} end
    end
    local ln = M.network(try(function() return pt.logistic_network end)) or M.network(try(function() return c.surface.find_logistic_network_by_position(c.position, c.force) end))
    local enabled = try(function() return pt.enabled end)
    local all = ln and (try(function() return ln.all_logistic_robots end) or 0)
    local idle = ln and (try(function() return ln.available_logistic_robots end) or 0)
    local id = ln and try(function() return ln.network_id end)
    for _, f in ipairs(filters) do
      local name, quality = name_of(f.name), name_of(f.quality) or 'normal'
      local min = f.count or f.min or 0
      if name and min > 0 then
        local held = inv and (try(function() return inv.get_item_count{name=name, quality=quality} end) or try(function() return inv.get_item_count(name) end)) or 0
        local in_slots, room = {}, inv and try(function() return inv.can_insert{name=name, quality=quality} end)
        for _, sl in ipairs(slots) do
          local n = try(function() return sl.inv.get_item_count{name=name, quality=quality} end) or 0
          if n > 0 then held = held + n; in_slots[#in_slots+1] = n .. ' in ' .. sl.what .. ' slots' end
          if room == false and try(function() return sl.inv.can_insert{name=name, quality=quality} end) then room = true end
        end
        local on_way = count_in(coming, name, quality)
        if held + on_way < min then
          local why
          if enabled == false then why = 'your personal logistics are switched off (character_settings {personal_logistics: true}, the GUI\'s switch)'
          elseif room == false and on_way == 0 then
            why = 'no slot of yours takes ' .. name .. ' (main inventory full, its free slots filtered to other items: character_settings reads them); robots bring an item only where it fits'
          elseif not ln then why = 'no logistic network where you stand ' .. at(c.position) .. ' (no roboport\'s logistic area covers it)'
          elseif all == 0 then why = string.format('logistic network %s where you stand has no logistic robots (its roboports hold none)', tostring(id))
          else
            local stock = try(function() return ln.get_item_count{name=name, quality=quality} end) or try(function() return ln.get_item_count(name) end) or 0
            if stock <= 0 then
              why = string.format('logistic network %s holds no %s robots can take (its provider, storage and buffer chests: none, or all reserved)', tostring(id), name)
            elseif idle == 0 then
              why = string.format('all %d logistic robots of network %s are busy now; it holds %d %s', all, tostring(id), stock, name)
            elseif on_way > 0 then
              why = string.format('robots are bringing %d; network %s holds %d more', on_way, tostring(id), stock)
            else
              why = string.format('network %s holds %d and has %d of %d logistic robots free; none has taken it yet', tostring(id), stock, idle, all)
            end
          end
          rows[#rows+1] = {item=name, quality=quality ~= 'normal' and quality or nil, min=min, held=held, coming=on_way > 0 and on_way or nil,
            why=why, network=id, robots=all, line=string.format('%s%s: hold %d of %d%s%s; %s', name, quality ~= 'normal' and '@' .. quality or '', held, min,
              #in_slots > 0 and ' (' .. table.concat(in_slots, ', ') .. ')' or '', on_way > 0 and string.format(' (%d on the way)', on_way) or '', why)}
        end
      end
    end
    return rows
  end

  -- status's logistics_here (Haiku: a request unfilled in a network with 0 logistic robots; the robot count in status):
  -- the logistic network where the character stands, its robots, and how many personal requests are unfilled.
  function M.here(p)
    local c = p.character
    if not (c and c.valid) then return nil end
    local ln = M.network(try(function() return c.surface.find_logistic_network_by_position(c.position, c.force) end))
    local rows = try(function() return M.unfilled(p) end) or {}
    local req = #rows > 0 and string.format('; %d personal request%s unfilled (%s)', #rows, #rows == 1 and '' or 's', rows[1].item .. (#rows > 1 and ', ...' or '')) or ''
    if not ln then return 'no logistic network where you stand ' .. at(c.position) .. req end
    local function n(f) return try(f) or 0 end
    return string.format('logistic network #%s where you stand: %d logistic robots (%d idle), %d construction robots (%d idle), %d roboports%s',
      tostring(try(function() return ln.network_id end) or '?'), n(function() return ln.all_logistic_robots end), n(function() return ln.available_logistic_robots end),
      n(function() return ln.all_construction_robots end), n(function() return ln.available_construction_robots end), n(function() return #ln.cells end), req)
  end
  -- team.alerts: a request unfilled WAIT ticks or more in a network with 0 logistic robots (checked every EVERY ticks).
  function M.lines(p, h)
    if h.personal_at and game.tick - h.personal_at < EVERY then return nil end
    h.personal_at = game.tick
    local rows = M.unfilled(p)
    if not rows then return nil end
    local seen, told = h.personal_seen or {}, h.personal_told or {}
    local now_seen, out, no_robots = {}, {}, {}
    for _, r in ipairs(rows) do
      local key = r.item .. '@' .. (r.quality or 'normal')
      now_seen[key] = seen[key] or game.tick
      if r.network and r.robots == 0 and game.tick - now_seen[key] >= WAIT then
        local k = tostring(r.network) .. '|' .. key
        if not told[k] or game.tick - told[k] >= AGAIN then
          told[k] = game.tick
          no_robots[#no_robots+1] = r
        end
      end
    end
    h.personal_seen = now_seen
    h.personal_told = told
    if #no_robots > 0 then
      local parts = {}
      for i = 1, math.min(4, #no_robots) do local r = no_robots[i]; parts[i] = string.format('%s %d of %d', r.item, r.held, r.min) end
      local c = p.character
      out[1] = string.format('your personal request%s %s %s unfilled: logistic network %s where you stand %s has no logistic robots%s',
        #no_robots == 1 and '' or 's', table.concat(parts, ', ') .. (#no_robots > 4 and ', ...' or ''), #no_robots == 1 and 'sits' or 'sit',
        tostring(no_robots[1].network), c and c.valid and at(c.position) or '', ' (a network\'s logistic robots are those in its roboports\' robot slots and in the air)')
    end
    return #out > 0 and out or nil
  end
  return M
end
