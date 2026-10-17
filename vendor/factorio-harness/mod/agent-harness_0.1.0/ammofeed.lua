-- A platform's ammunition by whether it can reach a turret (d17 batch13 B1, Astra and Sol: Kestrel left with 610
-- magazines and a positive forecast while hundreds sat on a rear belt loop and the bow turrets ran empty; it lost bow
-- collectors and guns, 100+ entities). Each ammo turret is followed back as the items move:
-- - the inserters dropping into it, each with its pickup: the hub, a chest or machine, or a belt;
-- - a belt: every belt upstream of the pickup (belt inputs, an underground exit's entrance, a loop whole), the turret's
--   ammo on them, and the inserters putting items onto them, with their pickups (the hub, a chest, an assembler);
-- - what stops the way: an inserter or belt switched off by its circuit condition, an inserter whose filters leave the
--   turret's ammo out, a turret no inserter feeds, belts no inserter puts anything on (they run dry).
-- reaches: what the turret holds, its feeders' hands, the belts upstream and the sources that put onto them; stranded:
-- the turret ammo on belts no turret's way reaches, and hub stock no inserter takes toward a turret. Read only; bounded:
-- MAX_BELTS belts read per turret, 512 turrets.
return function(api)
  local M = {}
  M.MAX_BELTS, M.MAX_TURRETS, M.LOW = 4000, 512, 10
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function at(q) return string.format('(%g,%g)', q.x, q.y) end
  local BELT = {['transport-belt']=true, ['underground-belt']=true, splitter=true, ['lane-splitter']=true, ['linked-belt']=true}
  local function key(e) return e.unit_number or (e.position.x .. ',' .. e.position.y) end
  -- The ammo a turret takes: by its ammo categories.
  local function takes_fn(turret)
    local cats = {}
    for _, c in ipairs(try(function() return turret.prototype.attack_parameters.ammo_categories end) or {}) do cats[c] = true end
    local memo = {}
    return function(name)
      if memo[name] ~= nil then return memo[name] end
      local ok = false
      local proto = try(function() return prototypes.item[name] end)
      if proto and proto.type == 'ammo' then
        local cat = try(function() local c = proto.ammo_category; return type(c) == 'string' and c or c.name end)
        ok = next(cats) == nil or (cat ~= nil and cats[cat] == true)
      end
      memo[name] = ok
      return ok
    end
  end
  local function inv_count(inv, takes)
    local n, by = 0, {}
    for _, r in ipairs(inv and try(function() return inv.get_contents() end) or {}) do
      if takes(r.name) then n = n + r.count; by[r.name] = (by[r.name] or 0) + r.count end
    end
    return n, by
  end
  local function switched_off(e)
    local cb = try(function() return e.get_control_behavior() end)
    if cb and try(function() return cb.disabled end) == true then return true end
    return try(function() return e.status == defines.entity_status.disabled_by_control_behavior end) == true
  end
  -- An inserter's filters leaving every item the turret takes out: the filter text, else nil.
  local function filter_blocks(ins, takes)
    local use = try(function() return ins.use_filters end)
    if not use then return nil end
    local mode = try(function() return ins.inserter_filter_mode end) or 'whitelist'
    local names, any = {}, false
    for i = 1, try(function() return ins.filter_slot_count end) or 0 do
      local f = try(function() return ins.get_filter(i) end)
      local name = f and (type(f) == 'string' and f or f.name)
      if name then names[#names+1] = name; if takes(name) then any = true end end
    end
    if mode == 'whitelist' and not any then return 'its whitelist (' .. (#names > 0 and table.concat(names, ', ') or 'empty') .. ') leaves the turret\'s ammo out' end
    if mode == 'blacklist' and any then return 'its blacklist (' .. table.concat(names, ', ') .. ') holds the turret\'s ammo back' end
    return nil
  end
  -- Belts upstream of a belt (itself included): every belt whose items move toward it.
  local function upstream(start)
    local seen, list, queue, head = {[key(start)]=true}, {start}, {start}, 1
    while head <= #queue and #list < M.MAX_BELTS do
      local e = queue[head]; head = head + 1
      local ins = try(function() return e.belt_neighbours.inputs end) or {}
      if e.type == 'underground-belt' and try(function() return e.belt_to_ground_type end) == 'output' then
        local n = try(function() local x = e.neighbours; return x and x.valid and x or nil end)
        if n then ins[#ins+1] = n end
      end
      if e.type == 'linked-belt' then
        local n = try(function() local x = e.linked_belt_neighbour; return x and x.valid and x or nil end)
        if n then ins[#ins+1] = n end
      end
      for _, u in ipairs(ins) do
        local k = u.valid and key(u)
        if k and not seen[k] then seen[k] = true; list[#list+1] = u; queue[#queue+1] = u end
      end
    end
    return list, seen, #list >= M.MAX_BELTS
  end
  function M.trace(pl)
    local s, f = pl.surface, pl.force
    local hub = try(function() local h = pl.hub; return h and h.valid and h or nil end)
    -- every inserter by what it drops into
    local into = {}
    for _, i in ipairs(try(function() return s.find_entities_filtered{type='inserter', force=f} end) or {}) do
      local d = try(function() return i.drop_target end)
      if d and d.valid then local k = key(d); into[k] = into[k] or {}; table.insert(into[k], i) end
    end
    local rows, reached_belts, reached_src, any_hub = {}, {}, {}, false
    local hub_inv = hub and try(function() return hub.get_inventory(defines.inventory.hub_main) end)
    local belt_memo = {}
    local function belt_of(b, takes)
      local k = key(b)
      local m = belt_memo[k]
      if not m then
        m = {}
        local lines = try(function() return b.get_max_transport_line_index() end) or 0
        for i = 1, lines do
          for _, r in ipairs(try(function() return b.get_transport_line(i).get_contents() end) or {}) do m[r.name] = (m[r.name] or 0) + r.count end
        end
        belt_memo[k] = m
      end
      local n = 0
      for name, c in pairs(m) do if takes(name) then n = n + c end end
      return n
    end
    local turrets = try(function() return s.find_entities_filtered{type='ammo-turret', force=f, limit=M.MAX_TURRETS} end) or {}
    for _, t in ipairs(turrets) do
      local takes = takes_fn(t)
      local own, own_by = inv_count(try(function() return t.get_inventory(defines.inventory.turret_ammo) end), takes)
      local row = {entity=t, name=t.name, position=t.position, own=own, reaches=own, ways={}, stops={}}
      local feeders = into[key(t)] or {}
      if #feeders == 0 then row.stops[#row.stops+1] = 'no inserter feeds it' end
      for _, i in ipairs(feeders) do
        local way = string.format('%s %s', i.name, at(i.position))
        local h = try(function() return i.held_stack end)
        if h and try(function() return h.valid_for_read end) and takes(h.name) then row.reaches = row.reaches + h.count end
        local blocked = switched_off(i) and 'switched off by its circuit condition' or filter_blocks(i, takes)
        local src = try(function() local x = i.pickup_target; return x and x.valid and x or nil end)
        if blocked then row.stops[#row.stops+1] = way .. ': ' .. blocked
        elseif not src then row.stops[#row.stops+1] = way .. ': takes from nothing'
        elseif BELT[src.type] then
          local list, set, capped = upstream(src)
          local on, sources, gates = 0, {}, {}
          local live = 0
          for _, b in ipairs(list) do
            local n = belt_of(b, takes)
            on = on + n
            reached_belts[key(b)] = b
            if switched_off(b) and #gates < 3 then gates[#gates+1] = b.name .. ' ' .. at(b.position) .. ' switched off by its circuit condition' end
            for _, si in ipairs(into[key(b)] or {}) do
              local sp = try(function() local x = si.pickup_target; return x and x.valid and x or nil end)
              local off = switched_off(si) and ' (switched off)' or ''
              local held = 0
              if sp and sp.type == 'space-platform-hub' then held = inv_count(hub_inv, takes)
              elseif sp and not BELT[sp.type] then
                held = inv_count(try(function() return sp.get_output_inventory() end) or try(function() return sp.get_inventory(defines.inventory.chest) end), takes)
              end
              if sp and not BELT[sp.type] and off == '' then
                live = live + 1
                if sp.type == 'space-platform-hub' then
                  any_hub = true
                  if not row.hub_counted then row.hub_counted = true; row.reaches = row.reaches + held end
                else
                  reached_src[key(sp)] = {e=sp, n=held}
                  row.reaches = row.reaches + held
                end
              end
              if sp and not BELT[sp.type] and #sources < 4 then
                sources[#sources+1] = string.format('%s %s from %s %s (holds %d of its ammo)', si.name, at(si.position), sp.name, at(sp.position), held) .. off
              end
            end
          end
          row.reaches = row.reaches + on
          row.belts = (row.belts or 0) + #list
          local text = string.format('%s from %s %s: %d of its ammo on %d belt%s upstream%s', way, src.name, at(src.position), on, #list, #list == 1 and '' or 's',
            capped and ' (the first ' .. M.MAX_BELTS .. ')' or '')
          if #sources > 0 then text = text .. '; put on them by ' .. table.concat(sources, ', ') end
          if live == 0 then
            row.stops[#row.stops+1] = string.format('%s: %s the belts upstream of %s %s: the %d on them, then dry', way,
              #sources > 0 and 'the inserters putting items on are switched off: nothing more comes onto' or 'no inserter puts anything on',
              src.name, at(src.position), on)
          end
          if #gates > 0 then row.stops[#row.stops+1] = table.concat(gates, '; ') end
          row.ways[#row.ways+1] = text
        elseif src.type == 'space-platform-hub' then
          any_hub = true
          local held = inv_count(hub_inv, takes)
          if not row.hub_counted then row.hub_counted = true; row.reaches = row.reaches + held end
          row.ways[#row.ways+1] = string.format('%s from the hub (holds %d of its ammo)', way, held)
        else
          local held = inv_count(try(function() return src.get_output_inventory() end) or try(function() return src.get_inventory(defines.inventory.chest) end), takes)
          reached_src[key(src)] = {e=src, n=held}
          row.reaches = row.reaches + held
          row.ways[#row.ways+1] = string.format('%s from %s %s (holds %d)', way, src.name, at(src.position), held)
        end
      end
      rows[#rows+1] = row
    end
    -- the hub's ammo: reaches turrets when some way takes from it
    local hub_ammo = {}
    if hub then for _, r in ipairs(try(function() return hub.get_inventory(defines.inventory.hub_main).get_contents() end) or {}) do
      if try(function() return prototypes.item[r.name].type end) == 'ammo' then hub_ammo[r.name] = (hub_ammo[r.name] or 0) + r.count end
    end end
    local hub_total = 0
    for _, n in pairs(hub_ammo) do hub_total = hub_total + n end
    -- stranded: ammo on belts no turret's way reaches, by connected group
    local stranded, groups, stranded_by = 0, {}, {}
    local all = try(function() return s.find_entities_filtered{type={'transport-belt', 'underground-belt', 'splitter'}, force=f, limit=20000} end) or {}
    local amemo = {}
    local anyammo = function(name)
      if amemo[name] == nil then amemo[name] = try(function() return prototypes.item[name].type end) == 'ammo' end
      return amemo[name]
    end
    local loose = {}
    for _, b in ipairs(all) do
      if not reached_belts[key(b)] then
        local n = belt_of(b, anyammo)
        if n > 0 then
          loose[#loose+1] = {e=b, n=n}; stranded = stranded + n
          for name, c in pairs(belt_memo[key(b)] or {}) do if anyammo(name) then stranded_by[name] = (stranded_by[name] or 0) + c end end
        end
      end
    end
    -- group loose belts within 3 tiles of each other
    local done = {}
    for i, x in ipairs(loose) do
      if not done[i] then
        local g = {n=0, count=0, x0=math.huge, y0=math.huge, x1=-math.huge, y1=-math.huge}
        local queue = {i}; done[i] = true
        while #queue > 0 do
          local j = table.remove(queue); local y = loose[j]
          g.n = g.n + 1; g.count = g.count + y.n
          local q = y.e.position
          g.x0, g.y0, g.x1, g.y1 = math.min(g.x0, q.x), math.min(g.y0, q.y), math.max(g.x1, q.x), math.max(g.y1, q.y)
          for k, z in ipairs(loose) do
            if not done[k] and math.abs(z.e.position.x - q.x) <= 3 and math.abs(z.e.position.y - q.y) <= 3 then done[k] = true; queue[#queue+1] = k end
          end
        end
        groups[#groups+1] = g
      end
    end
    table.sort(groups, function(x, y) return x.count > y.count end)
    local belt_reach = 0
    for _, b in pairs(reached_belts) do belt_reach = belt_reach + belt_of(b, anyammo) end
    local turret_own = 0
    for _, row in ipairs(rows) do turret_own = turret_own + row.own end
    local src_total = 0
    for _, x in pairs(reached_src) do src_total = src_total + x.n end
    local reaches = turret_own + belt_reach + src_total + (any_hub and hub_total or 0)
    -- hub ammo no inserter takes toward a turret: stranded too
    local hub_stranded = {}
    if not any_hub then for name, n in pairs(hub_ammo) do hub_stranded[name] = n end end
    local glines = {}
    for i, g in ipairs(groups) do
      if i <= 6 then glines[i] = string.format('%d on %d belt%s in (%g,%g)-(%g,%g)', g.count, g.n, g.n == 1 and '' or 's', g.x0, g.y0, g.x1, g.y1) end
    end
    return {rows=rows, reaches=reaches, stranded=stranded, stranded_groups=glines, stranded_more=#groups > 6 and #groups - 6 or nil,
      hub_ammo=hub_total, hub_reaches=any_hub, turret_own=turret_own, on_belts_reached=belt_reach, in_sources=src_total,
      stranded_by=stranded_by, hub_stranded=hub_stranded}
  end
  -- The read's lines: the totals, the turrets low or empty with what reaches them and what stops it, the stranded stock.
  function M.lines(tr, all)
    local lines = {}
    lines[#lines+1] = string.format('ammunition that can reach a turret: %d (turrets %d, belts on their ways %d, sources %d%s); stranded: %d%s',
      tr.reaches, tr.turret_own, tr.on_belts_reached, tr.in_sources, tr.hub_ammo > 0 and string.format(', hub %d%s', tr.hub_ammo, tr.hub_reaches and '' or ' NOT reaching any turret: no inserter takes it toward one') or '',
      tr.stranded, #tr.stranded_groups > 0 and ' on belts no turret\'s way reaches: ' .. table.concat(tr.stranded_groups, '; ') .. (tr.stranded_more and string.format('; +%d more groups', tr.stranded_more) or '') or '')
    local shown = 0
    for _, row in ipairs(tr.rows) do
      local low = row.reaches < M.LOW or #row.stops > 0
      if all or low then
        shown = shown + 1
        if shown <= 16 then
          lines[#lines+1] = string.format('%s %s: holds %d; %d reach it%s%s', row.name, at(row.position), row.own, row.reaches,
            #row.ways > 0 and ' (' .. table.concat(row.ways, ' | ') .. ')' or '', #row.stops > 0 and '; STOPPED: ' .. table.concat(row.stops, '; ') or '')
        end
      end
    end
    if shown > 16 then lines[#lines+1] = string.format('+%d more turrets', shown - 16) end
    return lines
  end
  return M
end
