-- ghostbreaks: the stretches of a belt line that stand only as ghosts (d20 batch53 M1, Sol #932: belt_gaps read the
-- Nauvis copper trunk as whole while (-36.5,529.5) was a transport-belt ghost; the ore stopped at (-35.5,529.5), and
-- 17 trunk belts lost to an attack stood as ghosts). A ghost carries nothing until robots or a hand build it, so each
-- run of ghost tiles along the line is a break: where, how many tiles, the items that build it, and whether a
-- roboport's construction area covers its ghosts (the network there and what it holds of each item).
return function()
  local M = {}
  M.MAX_LOOKUPS = 64
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function at(q) return string.format('(%g,%g)', q.x, q.y) end
  local items_of = {}
  function M.item(name)
    if items_of[name] == nil then
      local list = try(function() return prototypes.entity[name].items_to_place_this end)
      local first = list and list[1]
      items_of[name] = first and (type(first) == 'string' and first or first.name) or false
    end
    return items_of[name] or nil
  end
  -- seq: the line's tiles in order, each {position, ghost (true for a ghost), name}. Returns the breaks and a line.
  function M.breaks(seq, surface, force)
    local runs, cur = {}, nil
    for _, t in ipairs(seq) do
      if t.ghost then
        if not cur then cur = {tiles={}}; runs[#runs+1] = cur end
        cur.tiles[#cur.tiles+1] = t
      else cur = nil end
    end
    if #runs == 0 then return nil end
    local lookups = 0
    local rows, texts = {}, {}
    for i, r in ipairs(runs) do
      local need, names = {}, {}
      for _, t in ipairs(r.tiles) do
        local item = M.item(t.name)
        if item then
          if not need[item] then names[#names+1] = item end
          need[item] = (need[item] or 0) + 1
        end
      end
      table.sort(names)
      local parts = {}
      for _, n in ipairs(names) do parts[#parts+1] = need[n] .. ' ' .. n end
      -- robot coverage: each ghost of the run (up to the lookups left) in a construction area, the networks there
      local covered, checked, nets = 0, 0, {}
      for _, t in ipairs(r.tiles) do
        if lookups >= M.MAX_LOOKUPS then break end
        lookups = lookups + 1; checked = checked + 1
        local list = surface and try(function() return surface.find_logistic_networks_by_construction_area(t.position, force) end) or {}
        if #list > 0 then
          covered = covered + 1
          for _, n in ipairs(list) do if n.network_id and not nets[n.network_id] then nets[n.network_id] = n end end
        end
      end
      local held = {}
      local ids = {}
      for id in pairs(nets) do ids[#ids+1] = id end
      table.sort(ids)
      for _, id in ipairs(ids) do
        local n = nets[id]
        local have = {}
        for _, item in ipairs(names) do have[#have+1] = string.format('%d %s', try(function() return n.get_item_count(item) end) or 0, item) end
        local idle = try(function() return n.available_construction_robots end)
        held[#held+1] = string.format('network #%d holds %s%s', id, table.concat(have, ', '), idle and string.format(', %d construction robots idle', idle) or '')
      end
      local first, last = r.tiles[1].position, r.tiles[#r.tiles].position
      local robots = checked == 0 and 'not checked (lookups used up)'
        or covered == 0 and string.format('no roboport\'s construction area covers %s: robots do not build %s', checked == 1 and 'it' or 'them', checked == 1 and 'it' or 'them')
        or string.format('%d of %d in a construction area%s; %s', covered, checked, checked < #r.tiles and string.format(' (%d checked)', checked) or '', table.concat(held, '; '))
      local row = {from=first, to=last, tiles=#r.tiles, materials=need, robots=robots,
        line=string.format('%s%s: %d ghost tile%s carr%s nothing until built (%s); %s', at(first), #r.tiles > 1 and ' to ' .. at(last) or '', #r.tiles,
          #r.tiles == 1 and '' or 's', #r.tiles == 1 and 'ies' or 'y', table.concat(parts, ', '), robots)}
      rows[#rows+1] = row
      if i <= 8 then texts[#texts+1] = row.line end
    end
    local n = 0
    for _, r in ipairs(rows) do n = n + r.tiles end
    return rows, string.format('%d stretch%s of ghosts (%d tile%s): a break until built: %s%s', #rows, #rows == 1 and '' or 'es', n, n == 1 and '' or 's',
      table.concat(texts, ' | '), #rows > 8 and ' | ...' or '')
  end
  return M
end
