-- fuel_budget {boilers: true} (D7, Opus 00:20, about 6 times: slow brownouts seen late, the coal reconciled by hand):
-- the boilers on the surface in groups (boilers within GAP tiles of each other), and per group:
-- - what they burn a minute at full use (each working boiler's energy use over its fuel's value) and what they hold in
--   their fuel slots;
-- - what feeds them: the chests and belts their inserters take from, each belt walked back (inputs, side-loads,
--   undergrounds) up to BELT_TILES tiles a group, with the fuel on those tiles and in those chests;
-- - the mining drills dropping onto those belt tiles: how many, working, and what they put on at full speed (mining
--   speed with its bonus over the resource's mining time, with productivity);
-- - the balance (supply less burn) and, when the burn is more, the hours the fuel in reach of them lasts.
-- And the surface's fuel item made and used a minute (production statistics, last 10 minutes) and what its logistic
-- networks hold. Read only; bounded: 512 boilers, 64 inserters a group, BELT_TILES belt tiles a group, 256 drills.
return function(api)
  local M = {}
  local MAX_BOILERS, GAP, BELT_TILES, MAX_DRILLS = 512, 8, 3000, 256
  local LOW_FUEL, SOURCE = 5, 96
  local BELT = {['transport-belt']=true, ['underground-belt']=true, splitter=true}
  local CHEST = {container=true, ['logistic-container']=true}
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function at(q) return string.format('(%d,%d)', math.floor(q.x + 0.5), math.floor(q.y + 0.5)) end
  local function round(x, d) local m = 10 ^ (d or 1); return math.floor(x * m + 0.5) / m end
  local function fuel_value(name) return try(function() return prototypes.item[name].fuel_value end) or 0 end
  -- Groups of boilers within GAP tiles of each other (single link).
  local function groups(list)
    local out, seen = {}, {}
    for i, b in ipairs(list) do
      if not seen[i] then
        local g = {b}; seen[i] = true
        local k = 1
        while k <= #g do
          local m = g[k]
          for j, o in ipairs(list) do
            if not seen[j] and math.abs(o.position.x - m.position.x) <= GAP and math.abs(o.position.y - m.position.y) <= GAP then seen[j] = true; g[#g+1] = o end
          end
          k = k + 1
        end
        out[#out+1] = g
      end
    end
    return out
  end
  local function lane_count(b, item)
    local n = 0
    for k = 1, try(function() return b.get_max_transport_line_index() end) or 0 do
      n = n + (try(function() return b.get_transport_line(k).get_item_count(item) end) or 0)
    end
    return n
  end
  local function drill_rate(d)
    local res = try(function() return d.mining_target end)
    local time = res and try(function() return res.prototype.mineable_properties.mining_time end)
    local speed = try(function() return d.prototype.mining_speed end) or 0
    if not (time and time > 0) then return 0, res end
    return speed * (1 + (try(function() return d.speed_bonus end) or 0)) / time * (1 + (try(function() return d.productivity_bonus end) or 0)) * 60, res
  end
  function M.read(p, a, surface)
    local force = p.force
    local list = surface.find_entities_filtered{type='boiler', force=force, limit=MAX_BOILERS}
    local out, lines = {}, {}
    local fuels = {}
    -- groups by place, then merged where they share a feeding belt (one walk over all of them)
    local gs = groups(list)
    local parent = {}
    local function find(i) while parent[i] and parent[i] ~= i do i = parent[i] end return i end
    local function union(i, j) i, j = find(i), find(j); if i ~= j then parent[j] = i end end
    local owner, tiles_of, chests_of, feeders_of, queue = {}, {}, {}, {}, {}
    for gi, g in ipairs(gs) do
      parent[gi] = gi; tiles_of[gi], chests_of[gi], feeders_of[gi] = {}, {}, 0
      for _, b in ipairs(g) do
        local box = b.bounding_box
        for _, ins in ipairs(try(function() return surface.find_entities_filtered{area={{box.left_top.x - 3, box.left_top.y - 3}, {box.right_bottom.x + 3, box.right_bottom.y + 3}}, type='inserter', force=force} end) or {}) do
          if feeders_of[gi] < 64 and ins.valid and try(function() return ins.drop_target end) == b then
            feeders_of[gi] = feeders_of[gi] + 1
            local src = try(function() return ins.pickup_target end)
            if src and src.valid then
              if CHEST[src.type] then chests_of[gi][src.unit_number] = src
              elseif BELT[src.type] then
                local o = owner[src.unit_number]
                if o then union(o, gi) else owner[src.unit_number] = gi; queue[#queue+1] = {b=src, g=gi} end
              end
            end
          end
        end
      end
    end
    local i, walked = 1, 0
    while i <= #queue and walked < BELT_TILES do
      local it = queue[i]; i = i + 1; walked = walked + 1
      local b, gi = it.b, it.g
      tiles_of[gi][#tiles_of[gi]+1] = b
      local nexts = {}
      local bn = try(function() return b.belt_neighbours end)
      for _, x in ipairs(bn and bn.inputs or {}) do nexts[#nexts+1] = x end
      if b.type == 'underground-belt' and try(function() return b.belt_to_ground_type end) == 'output' then
        local nb = try(function() return b.neighbours end)
        if nb then nexts[#nexts+1] = nb end
      end
      for _, x in ipairs(nexts) do
        if x.valid and BELT[x.type] then
          local o = owner[x.unit_number]
          if o then union(o, gi) else owner[x.unit_number] = gi; queue[#queue+1] = {b=x, g=gi} end
        end
      end
    end
    local capped = i <= #queue
    -- drills dropping onto walked tiles: looked for chunk by chunk along them
    local drop_on = {}
    local chunks, chunk_list = {}, {}
    for _, it in ipairs(queue) do
      if owner[it.b.unit_number] and it.b.valid then
        local cx, cy = math.floor(it.b.position.x / 32), math.floor(it.b.position.y / 32)
        local k = cx .. ',' .. cy
        if not chunks[k] then chunks[k] = true; chunk_list[#chunk_list+1] = {cx, cy} end
      end
    end
    local found = 0
    for _, ch in ipairs(chunk_list) do
      local area = {{ch[1] * 32 - 3, ch[2] * 32 - 3}, {ch[1] * 32 + 35, ch[2] * 32 + 35}}
      for _, d in ipairs(try(function() return surface.find_entities_filtered{area=area, type='mining-drill', force=force} end) or {}) do
        local t = found < MAX_DRILLS and d.valid and try(function() return d.drop_target end)
        local gi = t and t.valid and owner[t.unit_number]
        if gi and not drop_on[d.unit_number] then drop_on[d.unit_number] = {d=d, g=gi}; found = found + 1 end
      end
    end
    -- merged groups
    local merged, idx = {}, {}
    for gi, g in ipairs(gs) do
      local r = find(gi)
      if not idx[r] then idx[r] = #merged + 1; merged[#merged+1] = {boilers={}, tiles={}, chests={}, feeders=0, drills={}} end
      local m = merged[idx[r]]
      for _, b in ipairs(g) do m.boilers[#m.boilers+1] = b end
      for _, t in ipairs(tiles_of[gi]) do m.tiles[#m.tiles+1] = t end
      for u, c in pairs(chests_of[gi]) do m.chests[u] = c end
      m.feeders = m.feeders + feeders_of[gi]
    end
    for _, x in pairs(drop_on) do local m = merged[idx[find(x.g)]]; m.drills[#m.drills+1] = x.d end
    for _, m in ipairs(merged) do
      local g = m.boilers
      local burn, held, working, by_fuel = 0, 0, 0, {}
      local sx, sy = 0, 0
      local main
      for _, b in ipairs(g) do
        sx, sy = sx + b.position.x, sy + b.position.y
        local burner = b.burner
        local cur = burner and try(function() return burner.currently_burning end)
        local fname = cur and (cur.name and (type(cur.name) == 'string' and cur.name or cur.name.name))
        local inv = try(function() return b.get_fuel_inventory() end)
        for _, c in ipairs(inv and try(function() return inv.get_contents() end) or {}) do
          held = held + c.count; by_fuel[c.name] = (by_fuel[c.name] or 0) + c.count; fname = fname or c.name
        end
        if fname then by_fuel[fname] = by_fuel[fname] or 0 end
        if api.status_name and api.status_name(b) == 'working' then
          working = working + 1
          local fv = fname and fuel_value(fname) or 0
          local eff = try(function() return b.prototype.burner_prototype.effectivity end) or 1
          local use = try(function() return b.prototype.get_max_energy_usage(b.quality) end) or try(function() return b.prototype.max_energy_usage end) or 0
          if fv > 0 then burn = burn + use * 60 * 60 / (fv * eff) end
        end
      end
      for f in pairs(by_fuel) do main = main or f end
      for f, n in pairs(by_fuel) do if n > (by_fuel[main] or 0) then main = f end end
      local on_belts, in_chests, nchests = 0, 0, 0
      if main then
        for _, b in ipairs(m.tiles) do if b.valid then on_belts = on_belts + lane_count(b, main) end end
        for _, c in pairs(m.chests) do nchests = nchests + 1; in_chests = in_chests + (try(function() return c.get_item_count(main) end) or 0) end
      end
      -- supply: the drills working or backed up (their output full) at full speed; the others by state
      local supply, drills, dworking, states, gone = 0, 0, 0, {}, 0
      for _, d in ipairs(m.drills) do
        local r, res = drill_rate(d)
        local gives = main and res and try(function() for _, pr in ipairs(res.prototype.mineable_properties.products) do if pr.name == main then return true end end end)
        local st = api.status_name and api.status_name(d) or 'unknown'
        if not res then gone = gone + 1; states[st] = (states[st] or 0) + 1
        elseif gives then
          drills = drills + 1
          if st == 'working' or st == 'waiting_for_space_in_destination' or st == 'full_output' then supply = supply + r else states[st] = (states[st] or 0) + 1 end
          if st == 'working' then dworking = dworking + 1 end
        end
      end
      local st_text = {}
      for k, n in pairs(states) do st_text[#st_text+1] = n .. ' ' .. k:gsub('_', ' ') end
      table.sort(st_text)
      local stock = held + on_belts + in_chests
      local balance = supply - burn
      local hours = balance < 0 and stock / (-balance) / 60 or nil
      local center = {x=sx / #g, y=sy / #g}
      local row = {near=at(center), boilers=#g, working=working, fuel=main, burn_per_min=round(burn), held=held, in_chests=in_chests, chests=nchests,
        on_belts=on_belts, belt_tiles=#m.tiles, drills=drills, drills_working=dworking, supply_per_min=round(supply), balance_per_min=round(balance),
        hours_left=hours and round(hours, 2) or nil, feeders=m.feeders}
      out[#out+1] = row
      if main then fuels[main] = true end
      row.drills_not_supplying = #st_text > 0 and table.concat(st_text, ', ') or nil
      -- (d17 batch14 A1, Haiku: about every 10 min a boiler run dry and a hunt for coal) the boilers low on fuel, each
      -- with what feeds it and whether that has power, the nearest fuel source, and one refuel call for them
      local low, positions, low_line = {}, {}, nil
      for _, b in ipairs(g) do
        local inv = try(function() return b.get_fuel_inventory() end)
        local n = inv and (try(function() return inv.get_item_count() end) or 0) or 0
        -- (a heat exchanger is a boiler with no fuel slot: left out)
        if inv and n < LOW_FUEL and #low < 16 then
          local feeds = {}
          local bb = b.bounding_box
          for _, i in ipairs(try(function() return b.surface.find_entities_filtered{area={{bb.left_top.x - 3, bb.left_top.y - 3}, {bb.right_bottom.x + 3, bb.right_bottom.y + 3}}, type='inserter', force=force} end) or {}) do
            if try(function() return i.drop_target end) == b then
              local st = api.status_name and api.status_name(i) or 'unknown'
              local power
              if try(function() return i.burner end) then
                local fi = try(function() return i.get_fuel_inventory() end)
                local f = fi and (try(function() return fi.get_item_count() end) or 0) or 0
                power = f > 0 and 'burner with ' .. f .. ' fuel' or (try(function() return i.burner.remaining_burning_fuel end) or 0) > 0 and 'burner, burning its last' or 'burner with NO fuel'
              else
                power = (st == 'no_power' or st == 'low_power') and st:gsub('_', ' ') or ((try(function() return i.electric_network_id end) and 'powered') or 'NOT connected to power')
              end
              local src = try(function() local x = i.pickup_target; return x and x.valid and x end)
              feeds[#feeds+1] = string.format('%s %s (%s) from %s', i.name, at(i.position), power, src and src.name .. ' ' .. at(src.position) or 'nothing')
            end
          end
          low[#low+1] = string.format('%s %s holds %d: %s', b.name, at(b.position), n, #feeds > 0 and table.concat(feeds, '; ') or 'no inserter feeds it')
          positions[#positions+1] = string.format('[%g,%g]', b.position.x, b.position.y)
        end
      end
      -- (no fuel seen in the group: coal, what boilers burn first)
      local want = main or (#low > 0 and 'coal') or nil
      if #low > 0 and want then
        row.low = low
        -- the nearest chest holding the fuel (logistic or plain), else the nearest belt carrying it, within SOURCE tiles
        local best, bd
        for _, c in ipairs(try(function() return g[1].surface.find_entities_filtered{position=center, radius=SOURCE, type={'container', 'logistic-container'}, force=force, limit=512} end) or {}) do
          local n = try(function() return c.get_item_count(want) end) or 0
          if n >= 10 then local d = math.sqrt((c.position.x - center.x) ^ 2 + (c.position.y - center.y) ^ 2); if not bd or d < bd then best, bd = {e=c, n=n}, d end end
        end
        if not best then
          for _, b in ipairs(try(function() return g[1].surface.find_entities_filtered{position=center, radius=math.min(SOURCE, 48), type='transport-belt', force=force, limit=400} end) or {}) do
            local n = lane_count(b, want)
            if n > 0 then local d = math.sqrt((b.position.x - center.x) ^ 2 + (b.position.y - center.y) ^ 2); if not bd or d < bd then best, bd = {e=b, n=n, belt=true}, d end end
          end
        end
        row.source = best and string.format('%s %s %s %d %s, %.0f tiles from the boilers', best.e.name, at(best.e.position), best.belt and 'carries' or 'holds', best.n, want, bd)
          or string.format('no chest holding 10 %s or belt carrying it within %d tiles', main, SOURCE)
        row.refuel = string.format('refuel {positions: [%s], fuel: "%s", count: 20%s}', table.concat(positions, ', '), want, best and not best.belt and ', from: "nearest", from_radius: ' .. math.min(128, math.ceil(bd) + 8) or '')
        low_line = string.format('  low (under %d %s): %s; fuel: %s; %s', LOW_FUEL, want, table.concat(low, ' | '), row.source, row.refuel)
      end
      lines[#lines+1] = string.format('%d boiler%s near %s (%d working) burn %s %g/min at full use; hold %d in their slots, %d in %d chest%s and %d on %d belt tile%s feeding them; %d drill%s on those belts (%d working) put up to %g/min%s: %s',
        #g, #g == 1 and '' or 's', row.near, working, main or 'no fuel', row.burn_per_min, held, in_chests, nchests, nchests == 1 and '' or 's', on_belts, #m.tiles,
        #m.tiles == 1 and '' or 's', drills + gone, drills + gone == 1 and '' or 's', dworking, row.supply_per_min,
        #st_text > 0 and ' (working or backed up; not counted: ' .. table.concat(st_text, ', ') .. ')' or '',
        hours and string.format('short %g/min, about %.1f h of fuel in reach of them (%d)', -row.balance_per_min, hours, stock)
          or (burn > 0 and string.format('the drills cover the burn (+%g/min)', row.balance_per_min) or 'nothing burning now'))
      if low_line then lines[#lines+1] = low_line end
    end
    if capped then lines[#lines+1] = string.format('the belts were walked back %d tiles in all, the cap: farther drills are not counted', BELT_TILES) end
    table.sort(out, function(x, y) return (x.hours_left or math.huge) < (y.hours_left or math.huge) end)
    local surface_lines = {}
    local stats = try(function() return force.get_item_production_statistics(surface) end)
    for f in pairs(fuels) do
      local function per(cat) return stats and try(function() return stats.get_flow_count{name=f, category=cat, precision_index=defines.flow_precision_index.ten_minutes, count=true} end) or 0 end
      local net = 0
      for _, ln in pairs(try(function() return force.logistic_networks[surface.name] end) or {}) do net = net + math.max(0, try(function() return ln.get_item_count(f) end) or 0) end
      surface_lines[#surface_lines+1] = string.format('%s on %s: made %g/min, used %g/min (last 10 min); logistic networks hold %d', f, surface.name, round(per('input') / 10), round(per('output') / 10), net)
    end
    return {groups=out, lines=lines, surface=surface_lines,
      note='burn at full use for the boilers working now (each one\'s energy use over its fuel\'s value); fuel in reach of them: their slots, the chests and the belt tiles (walked back, up to ' .. BELT_TILES .. ' in all) their inserters take from; supply: the drills dropping onto those tiles at full speed'}
  end
  return M
end
