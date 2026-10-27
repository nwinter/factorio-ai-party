-- requester_rate {position | area} (batch26 B2, Astra: Aquilo lithium furnaces at 9/min against 49/min because each
-- requester asked 10 over 80 tiles while 139 sat in a provider): per requester or buffer chest and item it asks, what it
-- asks and holds, what the machines its inserters feed use a minute (their recipe at their crafting speed), the stock
-- the game's robots would take it from (select_pickup_point) and how far, the robots' round trip there and back at our
-- robot speed (charging not counted), the most deliveries bring a round trip (they come for what is under the request)
-- and the minutes of use the request covers. Read only; at most CHESTS chests.
return function(api)
  local M = {}
  local CHESTS, AREA = 24, 128
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function at(q) return string.format('(%g,%g)', q.x, q.y) end
  local function r1(v) return math.floor(v * 10 + 0.5) / 10 end
  -- (d26 batch248 R3) a name, or a table or prototype (userdata)
  local function name_of(v) if v == nil or type(v) == 'string' then return v end return try(function() return v.name end) end
  -- What the chest asks: {item = min}, summed over its active sections.
  local function asks(e)
    local pt = try(function() return e.get_logistic_point(defines.logistic_member_index.logistic_container) end)
    local out = {}
    for _, f in ipairs(pt and try(function() return pt.filters end) or {}) do
      local n = name_of(f.name)
      if n and (f.count or 0) > 0 then out[n] = (out[n] or 0) + f.count end
    end
    return out
  end
  -- The machines the chest's inserters put into, and each one's use of item a minute.
  local function users(e, item)
    local b = e.bounding_box
    local list = try(function() return e.surface.find_entities_filtered{type='inserter', force=e.force,
      area={{b.left_top.x - 3, b.left_top.y - 3}, {b.right_bottom.x + 3, b.right_bottom.y + 3}}} end) or {}
    local per_min, names, seen = 0, {}, {}
    for _, i in ipairs(list) do
      local t = try(function() return i.pickup_target end) == e and try(function() return i.drop_target end)
      if t and t.valid and not seen[t.unit_number] then
        seen[t.unit_number] = true
        local recipe = try(function() return t.get_recipe() end) or try(function() return t.previous_recipe end)
        if recipe and not try(function() return recipe.ingredients end) then
          local rn = name_of(try(function() return recipe.name end))
          recipe = rn and prototypes.recipe[rn] or nil
        end
        local speed = try(function() return t.crafting_speed end)
        local per = 0
        for _, ing in ipairs(recipe and recipe.ingredients or {}) do if ing.name == item then per = per + (ing.amount or 0) end end
        if per > 0 and speed and recipe.energy and recipe.energy > 0 then
          per_min = per_min + per * 60 * speed / recipe.energy
          names[t.name] = (names[t.name] or 0) + 1
        end
      end
    end
    local parts = {}
    for n, k in pairs(names) do parts[#parts+1] = k .. ' ' .. n end
    table.sort(parts)
    return per_min, #parts > 0 and table.concat(parts, ', ') or nil
  end
  local function robot(force)
    local proto = prototypes.entity['logistic-robot']
    local speed = (try(function() return proto.speed end) or 0.05) * (1 + (try(function() return force.worker_robots_speed_modifier end) or 0))
    local cargo = (try(function() return proto.max_payload_size end) or 1) + (try(function() return force.worker_robots_storage_bonus end) or 0)
    return speed * 60, cargo
  end
  function M.read(p, a)
    local chests = {}
    if a.area ~= nil then
      local lt, rb = api.position(a.area.left_top), api.position(a.area.right_bottom)
      assert(rb.x - lt.x <= AREA and rb.y - lt.y <= AREA, 'area: at most 128x128')
      for _, e in ipairs(p.surface.find_entities_filtered{type='logistic-container', force=p.force, area={lt, rb}, limit=256}) do
        local mode = try(function() return e.prototype.logistic_mode end)
        if mode == 'requester' or mode == 'buffer' then chests[#chests+1] = e end
      end
    else
      assert(a.position, 'requester_rate: position (a requester or buffer chest) or area')
      local e = api.entity(p, {position=a.position})
      local mode = try(function() return e.prototype.logistic_mode end)
      assert(mode == 'requester' or mode == 'buffer', e.name .. ' at ' .. at(e.position) .. ' is no requester or buffer chest')
      chests[1] = e
    end
    local tps, cargo = robot(p.force)
    local rows, lines, more = {}, {}, 0
    for k, e in ipairs(chests) do
      if k > CHESTS then more = more + 1
      else
        for item, want in pairs(asks(e)) do
          local have = e.get_item_count(item)
          local use, by = users(e, item)
          local ln = try(function() return e.logistic_network end)
          local pick = ln and try(function() return ln.select_pickup_point{name=item, position=e.position} end)
          local o = pick and try(function() return pick.owner end)
          local row = {chest=e.name, position=e.position, item=item, asks=want, holds=have, use_per_min=use > 0 and r1(use) or nil, users=by}
          local parts = {string.format('%s %s %s: asks %d, holds %d', e.name, at(e.position), item, want, have)}
          parts[#parts+1] = use > 0 and string.format('used %g/min by %s', r1(use), by) or 'no machine its inserters feed uses it (or none read)'
          if o and o.valid and o ~= e then
            local d = math.sqrt((o.position.x - e.position.x) ^ 2 + (o.position.y - e.position.y) ^ 2)
            local trip = tps > 0 and 2 * d / tps or nil
            row.from = {name=o.name, position=o.position, distance=math.floor(d + 0.5), holds=o.get_item_count(item)}
            row.round_trip_s = trip and r1(trip) or nil
            parts[#parts+1] = string.format('the nearest stock robots take it from: %s %s, %d tiles, holding %d', o.name, at(o.position), row.from.distance, row.from.holds)
            if trip and trip > 0 then
              local per_min = want * 60 / trip
              row.most_per_min = r1(per_min)
              parts[#parts+1] = string.format('a robot round trip about %gs (%g tiles/s, a robot carries %d; charging not counted): deliveries come for what is under the request, at most %d a round trip, about %g/min',
                r1(trip), r1(tps), cargo, want, r1(per_min))
            end
          else
            parts[#parts+1] = ln and 'no stock of it the network\'s robots would take from now' or 'no logistic network covers it'
          end
          if use > 0 then
            row.covers_min = r1(want / use)
            parts[#parts+1] = string.format('the request covers %g min of use', row.covers_min)
          end
          rows[#rows+1] = row; lines[#lines+1] = table.concat(parts, '; ')
        end
      end
    end
    return {chests=math.min(#chests, CHESTS), more=more > 0 and more or nil, rows=rows, lines=lines,
      note='use: each fed machine\'s recipe at its crafting speed now, as if it ran all the time; a round trip is there and back in a straight line'}
  end
  -- stock {unrequested: true} (d17 batch32 B4, Opus: 2000 production science packs sat in one requester while every lab
  -- starved): per surface, the requester and buffer chests in our logistic networks (each network's requester points,
  -- no find) holding items they do not request, with counts, where, and whether its trash-unrequested switch sends them
  -- to storage. item: only that item. The most held first; at most ROWS rows.
  -- Cost on world n (08:36, read only): about 14 us a requester point (3.7 ms for 256, 10.7 ms for 768; Nauvis has 1204):
  -- POINTS a call (about 7 ms), page for the next (operator 08:48).
  local ROWS, POINTS = 32, 512
  function M.unrequested(surface, force, item, page)
    page = page or 1
    local first, last_point = (page - 1) * POINTS + 1, page * POINTS
    local rows, by_item, read, chests = {}, {}, 0, 0
    local LM = defines.logistic_mode or {}
    for _, ln in ipairs(try(function() return force.logistic_networks[surface.name] end) or {}) do
      for _, pt in ipairs(try(function() return ln.requester_points end) or {}) do
        read = read + 1
        local c = read >= first and read <= last_point and pt.owner
        if c and c.valid and c.type == 'logistic-container' and (pt.mode == nil or pt.mode == LM.requester or pt.mode == LM.buffer) then
          chests = chests + 1
          local asked = {}
          for _, f in ipairs(pt.filters or {}) do local n = name_of(f.name); if n and (f.count or 0) > 0 then asked[n] = true end end
          local inv = try(function() return c.get_inventory(defines.inventory.chest) end)
          local extra, n_all = {}, 0
          for _, st in ipairs(inv and try(function() return inv.get_contents() end) or {}) do
            if not asked[st.name] and (item == nil or st.name == item) then
              extra[#extra+1] = st.name .. (st.quality and st.quality ~= 'normal' and '@' .. st.quality or '') .. '*' .. st.count
              n_all = n_all + st.count
              by_item[st.name] = by_item[st.name] or {count=0, chests=0}
              by_item[st.name].count = by_item[st.name].count + st.count
              by_item[st.name].chests = by_item[st.name].chests + 1
            end
          end
          if n_all > 0 then
            local trash = try(function() return pt.trash_not_requested end)
            local asks = {}
            for n in pairs(asked) do asks[#asks+1] = n end
            table.sort(asks)
            rows[#rows+1] = {n=n_all, row={chest=c.name, position=c.position, network=ln.network_id, holds=table.concat(extra, ' '), count=n_all,
              trash_unrequested=trash and true or false,
              line=string.format('%s %s #%d holds %s that it does not request (it asks %s); trash unrequested %s', c.name, at(c.position), ln.network_id,
                table.concat(extra, ' '), #asks > 0 and table.concat(asks, ', ', 1, math.min(4, #asks)) .. (#asks > 4 and ', ...' or '') or 'nothing',
                trash and 'on: robots take them to storage' or 'off: they stay (requests {position, trash_unrequested: true} sends them to storage)')}}
          end
        end
      end
    end
    table.sort(rows, function(x, y) return x.n > y.n or (x.n == y.n and x.row.line < y.row.line) end)
    local items = {}
    for n, v in pairs(by_item) do items[#items+1] = {n=n, v=v} end
    table.sort(items, function(x, y) return x.v.count > y.v.count or (x.v.count == y.v.count and x.n < y.n) end)
    local parts = {}
    for i, x in ipairs(items) do if i <= 12 then parts[#parts+1] = string.format('%s %d in %d chest%s', x.n, x.v.count, x.v.chests, x.v.chests == 1 and '' or 's') end end
    local lines = {string.format('%s: %d of %d requester and buffer chests in our logistic networks hold %s they do not request%s', surface.name, #rows, chests,
      item or 'items', #parts > 0 and ': ' .. table.concat(parts, ', ') .. (#items > 12 and string.format(', +%d more items', #items - 12) or '') or '')}
    local out_rows = {}
    for i, r in ipairs(rows) do
      if i > ROWS then lines[#lines+1] = string.format('+%d more chests', #rows - ROWS); break end
      out_rows[i] = r.row; lines[#lines+1] = r.row.line
    end
    local more = read > last_point
    if page > 1 or more then lines[#lines+1] = string.format('requester points %d-%d of %d read%s', first, math.min(read, last_point), read,
      more and string.format('; stock {unrequested: true, page: %d} reads the next', page + 1) or '') end
    return {lines=lines, chests=out_rows, page=(page > 1 or more) and page or nil, next=more and page + 1 or nil, items=#items > 0 and (function() local t = {} for i, x in ipairs(items) do t[i] = {item=x.n, count=x.v.count, chests=x.v.chests} end return t end)() or nil,
      note='chests in no logistic network are not read'}
  end
  M.schema = {requester_rate = {position='a requester or buffer chest {x,y}', area='or {left_top, right_bottom} up to 128x128: its requester and buffer chests (24 at most)',surface='optional planet name: the chest or area on that planet, by remote view (as inspect)',
    returns='rows [{chest, position, item, asks, holds, use_per_min, users, from {name, position, distance, holds}, round_trip_s, most_per_min, covers_min}], lines (one a chest and item), more. Read only'}}
  return M
end
