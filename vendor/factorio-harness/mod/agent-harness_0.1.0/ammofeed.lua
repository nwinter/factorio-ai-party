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
  -- (d17 batch23 A2) the per-belt reads as plain functions, each under one pcall
  local function read_neighbours(e, dir)
    local out = {}
    for _, u in ipairs(e.belt_neighbours[dir]) do if u.valid then out[#out+1] = u end end
    local t = e.type
    if t == 'underground-belt' and e.belt_to_ground_type == (dir == 'inputs' and 'output' or 'input') then
      local x = e.neighbours
      if x and x.valid then out[#out+1] = x end
    elseif t == 'linked-belt' then
      local x = e.linked_belt_neighbour
      if x and x.valid then out[#out+1] = x end
    end
    return out
  end
  local function read_contents(e)
    local m = {}
    for i = 1, e.get_max_transport_line_index() do
      local l = e.get_transport_line(i)
      if #l > 0 then for _, r in ipairs(l.get_contents()) do m[r.name] = (m[r.name] or 0) + r.count end end
    end
    return m
  end
  local function read_off(e)
    local cb = e.get_control_behavior()
    return cb ~= nil and cb.disabled == true
  end
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
  function M.trace(pl)
    local s, f = pl.surface, pl.force
    local hub = try(function() local h = pl.hub; return h and h.valid and h or nil end)
    -- every inserter by what it drops into
    local into = {}
    for _, i in ipairs(try(function() return s.find_entities_filtered{type='inserter', force=f} end) or {}) do
      local d = try(function() return i.drop_target end)
      if d and d.valid then local k = key(d); into[k] = into[k] or {}; table.insert(into[k], i) end
    end
    -- (d17 batch23 A2: the trace read Kestrel II's 900-belt loop again for each of its 43 turrets, 180 ms on n) each
    -- belt's neighbours, each entity's switch and each inserter's pickup are read once per trace
    local nbr, offm, pickm = {}, {}, {}
    local function neighbours(e, k, dir)
      local c = nbr[k]
      if not c then c = {}; nbr[k] = c end
      if c[dir] then return c[dir] end
      local list = {}
      local ok, us = pcall(read_neighbours, e, dir)
      for _, u in ipairs(ok and us or {}) do list[#list+1] = {e=u, k=u.unit_number or key(u)} end
      c[dir] = list
      return list
    end
    local function off(e, k)
      k = k or key(e)
      if offm[k] == nil then
        local ok, v = pcall(read_off, e)
        if ok then offm[k] = v else offm[k] = switched_off(e) end
      end
      return offm[k]
    end
    local function pickup(i)
      local k = key(i)
      if pickm[k] == nil then
        local x = try(function() local x = i.pickup_target; return x and x.valid and x or nil end)
        pickm[k] = x and {e=x, k=key(x)} or false
      end
      return pickm[k] or nil
    end
    local amemo = {}
    local anyammo = function(name)
      if amemo[name] == nil then amemo[name] = try(function() return prototypes.item[name].type end) == 'ammo' end
      return amemo[name]
    end
    local belt_memo = {}
    local function belt_of(b, takes, k)
      k = k or key(b)
      local m = belt_memo[k]
      if not m then
        local ok, v = pcall(read_contents, b)
        m = ok and v or {}
        belt_memo[k] = m
      end
      local n = 0
      for name, c in pairs(m) do if takes(name) then n = n + c end end
      return n
    end
    -- The belts upstream of the turrets' belts, each read once: a belt's inputs (belts, an underground's entrance, a
    -- linked belt), the inserters moving items onto it from another belt (relays and long-handed bridges, chains of
    -- them: d17 batch13, Astra and Sol: Wren's bow and Meridian's west turret read STOPPED while a relay fed them; those
    -- not switched off whose filters pass some ammunition), and those putting items on from the hub, a chest or a machine.
    local node, nodes, capped = {}, {}, false
    local function discover(starts)
      local queue, head = {}, 1
      for _, x in ipairs(starts) do queue[#queue+1] = x end
      while head <= #queue do
        local x = queue[head]; head = head + 1
        if not node[x.k] then
          if #nodes >= M.MAX_BELTS then capped = true; break end
          local n = {e=x.e, k=x.k, ins={}}
          node[x.k] = n; nodes[#nodes+1] = n
          for _, u in ipairs(neighbours(x.e, x.k, 'inputs')) do n.ins[#n.ins+1] = u.k; if not node[u.k] then queue[#queue+1] = u end end
          for _, si in ipairs(into[x.k] or {}) do
            local sp = pickup(si)
            if sp and BELT[sp.e.type] then
              if not off(si) and not filter_blocks(si, anyammo) then
                n.ins[#n.ins+1] = sp.k; n.relay = n.relay or {si=si, sp=sp.e}
                if not node[sp.k] then queue[#queue+1] = sp end
              end
            elseif sp then n.srcs = n.srcs or {}; n.srcs[#n.srcs+1] = {si=si, sp=sp, off=off(si)} end
          end
        end
      end
    end
    -- loops (belts whose items come round to each other) as one: found ancestors first (Tarjan's order)
    local comp, comps = {}, {}
    local function components()
      local stack, idx, cs_n, cs_i = {}, 0, {}, {}
      for _, root in ipairs(nodes) do
        if not root.ix then
          idx = idx + 1; root.ix = idx; root.lo = idx; stack[#stack+1] = root; root.on = true
          local top = 1; cs_n[1] = root; cs_i[1] = 0
          while top > 0 do
            local n = cs_n[top]
            local i = cs_i[top] + 1; cs_i[top] = i
            local wk = n.ins[i]
            if wk then
              local w = node[wk]
              if w then
                if not w.ix then
                  idx = idx + 1; w.ix = idx; w.lo = idx; stack[#stack+1] = w; w.on = true
                  top = top + 1; cs_n[top] = w; cs_i[top] = 0
                elseif w.on and w.ix < n.lo then n.lo = w.ix end
              end
            else
              top = top - 1
              if n.lo == n.ix then
                local c = {keys={}, order=#comps + 1}
                repeat local x = stack[#stack]; stack[#stack] = nil; x.on = nil; comp[x.k] = c; c.keys[#c.keys+1] = x.k until x == n
                comps[#comps+1] = c
              end
              if top > 0 then local pn = cs_n[top]; if n.lo < pn.lo then pn.lo = n.lo end end
            end
          end
        end
      end
    end
    -- A way back: what its belts hold (ammunition only), how many, and who puts items on them (each loader, relay and
    -- switched-off belt). Ways are found for the belts turrets take from, upstream ones first; a way walks back along
    -- its belts until one already found (whose belts all lie upstream: added whole) or a merge (found once, each belt
    -- upstream of it counted once).
    local memo = {}
    local function blank() return {items={}, n=0, live=0, hub=false, srcs={}, gates={}, relays={}} end
    local function own_into(a, c)
      for _, k in ipairs(c.keys) do
        local nd = node[k]
        belt_of(nd.e, anyammo, k)
        for name, cnt in pairs(belt_memo[k]) do if anyammo(name) then a.items[name] = (a.items[name] or 0) + cnt end end
        a.n = a.n + 1
        if off(nd.e, k) and #a.gates < 3 then a.gates[#a.gates+1] = nd.e.name .. ' ' .. at(nd.e.position) .. ' switched off by its circuit condition' end
        if nd.relay and #a.relays < 3 then a.relays[#a.relays+1] = string.format('%s %s from %s %s', nd.relay.si.name, at(nd.relay.si.position), nd.relay.sp.name, at(nd.relay.sp.position)) end
        for _, x in ipairs(nd.srcs or {}) do
          a.srcs[#a.srcs+1] = x
          if not x.off then a.live = a.live + 1; if x.sp.e.type == 'space-platform-hub' then a.hub = true end end
        end
      end
    end
    local function add(a, x)
      for name, cnt in pairs(x.items) do a.items[name] = (a.items[name] or 0) + cnt end
      a.n, a.live, a.hub = a.n + x.n, a.live + x.live, a.hub or x.hub
      for _, y in ipairs(x.srcs) do a.srcs[#a.srcs+1] = y end
      for _, y in ipairs(x.gates) do if #a.gates < 3 then a.gates[#a.gates+1] = y end end
      for _, y in ipairs(x.relays) do if #a.relays < 3 then a.relays[#a.relays+1] = y end end
    end
    local function preds_of(c)
      local out, seen = {}, nil
      for _, k in ipairs(c.keys) do
        for _, pk in ipairs(node[k].ins) do
          local pc = comp[pk]
          if pc and pc ~= c and out[1] ~= pc then
            seen = seen or {}
            if not seen[pc] then seen[pc] = true; out[#out+1] = pc end
          end
        end
      end
      return out
    end
    local function way_of(c)
      if memo[c] then return memo[c] end
      local a, cur = blank(), c
      while cur do
        if cur ~= c and memo[cur] then add(a, memo[cur]); break end
        local ps = preds_of(cur)
        if #ps > 1 then
          if cur ~= c then add(a, way_of(cur)); break end
          own_into(a, cur)
          local seen, queue, h = {[cur]=true}, {}, 1
          for _, p in ipairs(ps) do seen[p] = true; queue[#queue+1] = p end
          while h <= #queue do
            local p = queue[h]; h = h + 1
            own_into(a, p)
            for _, q in ipairs(preds_of(p)) do if not seen[q] then seen[q] = true; queue[#queue+1] = q end end
          end
          break
        end
        own_into(a, cur)
        cur = ps[1]
      end
      memo[c] = a
      return a
    end
    local rows, reached_belts, reached_src, any_hub = {}, {}, {}, false
    local hub_inv = hub and try(function() return hub.get_inventory(defines.inventory.hub_main) end)
    local turrets = try(function() return s.find_entities_filtered{type='ammo-turret', force=f, limit=M.MAX_TURRETS} end) or {}
    local pending, starts = {}, {}
    local takes_by = {}
    for _, t in ipairs(turrets) do
      local tname = t.name
      local takes = takes_by[tname] or takes_fn(t)
      takes_by[tname] = takes
      local own_n = inv_count(try(function() return t.get_inventory(defines.inventory.turret_ammo) end), takes)
      local row = {entity=t, name=tname, position=t.position, own=own_n, reaches=own_n, ways={}, stops={}}
      local feeders = into[key(t)] or {}
      if #feeders == 0 then row.stops[#row.stops+1] = 'no inserter feeds it' end
      for _, i in ipairs(feeders) do
        local way = string.format('%s %s', i.name, at(i.position))
        local h = try(function() return i.held_stack end)
        if h and try(function() return h.valid_for_read end) and takes(h.name) then row.reaches = row.reaches + h.count end
        local blocked = off(i) and 'switched off by its circuit condition' or filter_blocks(i, takes)
        local src = pickup(i)
        if blocked then row.stops[#row.stops+1] = way .. ': ' .. blocked
        elseif not src then row.stops[#row.stops+1] = way .. ': takes from nothing'
        elseif BELT[src.e.type] then
          pending[#pending+1] = {row=row, way=way, src=src, takes=takes, slot=#row.ways + 1}
          row.ways[#row.ways+1] = false
          starts[#starts+1] = src
        elseif src.e.type == 'space-platform-hub' then
          any_hub = true
          local held = inv_count(hub_inv, takes)
          if not row.hub_counted then row.hub_counted = true; row.reaches = row.reaches + held end
          row.ways[#row.ways+1] = string.format('%s from the hub (holds %d of its ammo)', way, held)
        else
          local held = inv_count(try(function() return src.e.get_output_inventory() end) or try(function() return src.e.get_inventory(defines.inventory.chest) end), takes)
          reached_src[src.k] = {e=src.e, n=held}
          row.reaches = row.reaches + held
          row.ways[#row.ways+1] = string.format('%s from %s %s (holds %d)', way, src.e.name, at(src.e.position), held)
        end
      end
      rows[#rows+1] = row
    end
    discover(starts)
    components()
    for _, w in ipairs(pending) do local c = comp[w.src.k]; w.order = c and c.order or math.huge end
    table.sort(pending, function(x, y) return x.order < y.order end)
    for _, n in ipairs(nodes) do reached_belts[n.k] = n.e end
    -- each turret's way back along its belt
    local held_memo = {}
    for _, w in ipairs(pending) do
      local row, way, src, takes = w.row, w.way, w.src, w.takes
      local c = comp[src.k]
      local a = c and way_of(c) or blank()
      local on = 0
      for name, cnt in pairs(a.items) do if takes(name) then on = on + cnt end end
      local function held_of(x)
        local hk = tostring(x.sp.k) .. '|' .. row.name
        if held_memo[hk] == nil then
          held_memo[hk] = x.sp.e.type == 'space-platform-hub' and inv_count(hub_inv, takes)
            or inv_count(try(function() return x.sp.e.get_output_inventory() end) or try(function() return x.sp.e.get_inventory(defines.inventory.chest) end), takes)
        end
        return held_memo[hk]
      end
      if a.hub then
        any_hub = true
        if not row.hub_counted then row.hub_counted = true; row.reaches = row.reaches + held_of({sp={e=hub, k=key(hub)}}) end
      end
      local src_list, gates, relays, seen_src = a.srcs, a.gates, a.relays, {}
      for _, x in ipairs(src_list) do
        if not x.off and x.sp.e.type ~= 'space-platform-hub' and not seen_src[x.sp.k] then
          seen_src[x.sp.k] = true
          local n = held_of(x)
          reached_src[x.sp.k] = {e=x.sp.e, n=n}
          row.reaches = row.reaches + n
        end
      end
      row.reaches = row.reaches + on
      row.belts = (row.belts or 0) + a.n
      -- (d17 batch23 A2, Astra: a disabled old loader was named beside the bulk inserter feeding the loop) the
      -- switched-off ones are named only when nothing else puts items on
      local sources, off_sources = {}, {}
      for _, x in ipairs(src_list) do
        local text = string.format('%s %s from %s %s (holds %d of its ammo)', x.si.name, at(x.si.position), x.sp.e.name, at(x.sp.e.position), held_of(x)) .. (x.off and ' (switched off)' or '')
        if not x.off and #sources < 4 then sources[#sources+1] = text
        elseif x.off and #off_sources < 4 then off_sources[#off_sources+1] = text end
      end
      local text = string.format('%s from %s %s: %d of its ammo on %d belt%s upstream%s', way, src.e.name, at(src.e.position), on, a.n, a.n == 1 and '' or 's',
        capped and ' (of the first ' .. M.MAX_BELTS .. ' belts read)' or '')
      if #relays > 0 then text = text .. '; through ' .. table.concat(relays, ', ') end
      if #sources > 0 then text = text .. '; put on them by ' .. table.concat(sources, ', ') end
      if a.live == 0 and #off_sources > 0 then text = text .. '; put on them by ' .. table.concat(off_sources, ', ') end
      if a.live == 0 then
        row.stops[#row.stops+1] = string.format('%s: %s the belts upstream of %s %s: the %d on them, then dry', way,
          #off_sources > 0 and 'the inserters putting items on are switched off: nothing more comes onto' or 'no inserter puts anything on',
          src.e.name, at(src.e.position), on)
      end
      if #gates > 0 then row.stops[#row.stops+1] = table.concat(gates, '; ') end
      row.ways[w.slot] = text
    end
    for _, row in ipairs(rows) do
      local ways = {}
      for _, x in ipairs(row.ways) do if x then ways[#ways+1] = x end end
      row.ways = ways
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
    -- (d17 batch23 A2, Astra: Kestrel II's return belt into the hub read stranded while the hub fed the turrets) belts
    -- whose way ends in an inserter dropping into the hub, when the hub's ammunition reaches a turret: they reach too
    local to_hub, via_hub = {}, 0
    if any_hub and hub then
      local back, before = {}, #nodes
      for _, i in ipairs(into[key(hub)] or {}) do
        local sp = pickup(i)
        if sp and BELT[sp.e.type] and not off(i) then back[#back+1] = sp end
      end
      discover(back)
      for j = before + 1, #nodes do local n = nodes[j]; to_hub[n.k] = true; via_hub = via_hub + belt_of(n.e, anyammo, n.k) end
    end
    -- (A2, Astra: a long-handed bridge's belt end read stranded) a belt that ends (no belt after it) a few belts past
    -- a belt on a turret's way: its items wait at that end, past the pickup
    local at_end, at_end_n, end_rows = {}, 0, {}
    local all_keys = {}
    for i, b in ipairs(all) do all_keys[i] = key(b) end
    for i, b in ipairs(all) do
      local k = all_keys[i]
      if not reached_belts[k] and not to_hub[k] and not at_end[k] and b.type == 'transport-belt' and belt_of(b, anyammo, k) > 0 and #neighbours(b, k, 'outputs') == 0 then
        local chain, cur, past = {{e=b, k=k}}, {e=b, k=k}, nil
        for _ = 1, 4 do
          local ins = neighbours(cur.e, cur.k, 'inputs')
          for _, u in ipairs(ins) do if reached_belts[u.k] then past = u.e end end
          if past or #ins ~= 1 or to_hub[ins[1].k] then break end
          cur = ins[1]; chain[#chain+1] = cur
        end
        if past then
          local n = 0
          for _, c in ipairs(chain) do at_end[c.k] = true; n = n + belt_of(c.e, anyammo, c.k) end
          at_end_n = at_end_n + n
          if #end_rows < 6 then
            local by
            for _, i in ipairs(try(function() return s.find_entities_filtered{type='inserter', force=f, position=past.position, radius=3, limit=16} end) or {}) do
              if not by and try(function() local x = i.pickup_target; return x and x.valid and key(x) == key(past) end) then by = i end
            end
            end_rows[#end_rows+1] = string.format('%d on %d belt%s ending at %s, past %s %s%s', n, #chain, #chain == 1 and '' or 's', at(b.position), past.name, at(past.position),
              by and string.format(' (the pickup of %s %s)', by.name, at(by.position)) or '')
          end
        end
      end
    end
    local loose = {}
    for i, b in ipairs(all) do
      local k = all_keys[i]
      if not reached_belts[k] and not to_hub[k] and not at_end[k] then
        local n = belt_of(b, anyammo, k)
        if n > 0 then
          loose[#loose+1] = {e=b, n=n}; stranded = stranded + n
          for name, c in pairs(belt_memo[k] or {}) do if anyammo(name) then stranded_by[name] = (stranded_by[name] or 0) + c end end
        end
      end
    end
    -- group loose belts within 3 tiles of each other
    local done = {}
    for i, x in ipairs(loose) do
      if not done[i] then
        local g = {n=0, count=0, x0=math.huge, y0=math.huge, x1=-math.huge, y1=-math.huge, belts={}}
        local queue = {i}; done[i] = true
        while #queue > 0 do
          local j = table.remove(queue); local y = loose[j]
          g.n = g.n + 1; g.count = g.count + y.n
          g.belts[#g.belts+1] = y
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
    for k, b in pairs(reached_belts) do belt_reach = belt_reach + belt_of(b, anyammo, k) end
    local turret_own = 0
    for _, row in ipairs(rows) do turret_own = turret_own + row.own end
    local src_total = 0
    for _, x in pairs(reached_src) do src_total = src_total + x.n end
    local reaches = turret_own + belt_reach + src_total + (any_hub and hub_total or 0) + via_hub
    -- hub ammo no inserter takes toward a turret: stranded too
    local hub_stranded = {}
    if not any_hub then for name, n in pairs(hub_ammo) do hub_stranded[name] = n end end
    local glines, recover = {}, {}
    for i, g in ipairs(groups) do
      if i <= 6 then
        glines[i] = string.format('%d on %d belt%s in (%g,%g)-(%g,%g)', g.count, g.n, g.n == 1 and '' or 's', g.x0, g.y0, g.x1, g.y1)
        -- (d17 batch14 A7a, Sol: 80 rounds recovered by deconstructing and rebuilding 20 reserve belts during an urgent
        -- empty west) the belts holding it, and what else of ours the box round them holds (a deconstruct takes that too)
        table.sort(g.belts, function(x, y) return x.n > y.n end)
        local bl = {}
        for k, y in ipairs(g.belts) do if k <= 8 then bl[k] = string.format('%s %s %d', y.e.name, at(y.e.position), y.n) end end
        local box = {left_top={x=math.floor(g.x0), y=math.floor(g.y0)}, right_bottom={x=math.floor(g.x1) + 1, y=math.floor(g.y1) + 1}}
        local others = 0
        for _, b in ipairs(all) do
          local q = b.position
          if q.x >= box.left_top.x and q.x <= box.right_bottom.x and q.y >= box.left_top.y and q.y <= box.right_bottom.y then others = others + 1 end
        end
        others = others - g.n
        recover[i] = {count=g.count, belts=bl, belts_more=g.n > 8 and g.n - 8 or nil, area=box, other_belts_in_area=others > 0 and others or nil}
      end
    end
    return {rows=rows, reaches=reaches, stranded=stranded, stranded_groups=glines, stranded_recover=recover, stranded_more=#groups > 6 and #groups - 6 or nil,
      hub_ammo=hub_total, hub_reaches=any_hub, turret_own=turret_own, on_belts_reached=belt_reach, in_sources=src_total,
      stranded_by=stranded_by, hub_stranded=hub_stranded, via_hub=via_hub, at_end=at_end_n, at_end_rows=end_rows}
  end
  -- The read's lines: the totals, the turrets low or empty with what reaches them and what stops it, the stranded stock.
  -- The call that would recover a stranded group: a belt pickup where your character stands on that surface (aboard),
  -- else a deconstruct of those belts (the hub takes them and the items on them; place them again after).
  function M.recover_line(r, platform, aboard)
    local a = string.format('{left_top: {x: %g, y: %g}, right_bottom: {x: %g, y: %g}}', r.area.left_top.x, r.area.left_top.y, r.area.right_bottom.x, r.area.right_bottom.y)
    local call = aboard and string.format('pickup {belt: true, area: %s}', a)
      or string.format('deconstruct {platform: "%s", area: %s, entity_types: ["transport-belt", "underground-belt", "splitter"]} (the hub takes the belts and the items on them; blueprint_capture the area first to place them again)', platform, a)
    return string.format('stranded %d on %s%s; recovered by %s%s', r.count, table.concat(r.belts, ', '), r.belts_more and string.format(' +%d more belts', r.belts_more) or '',
      call, r.other_belts_in_area and string.format('; that area also holds %d other belt%s of ours', r.other_belts_in_area, r.other_belts_in_area == 1 and '' or 's') or '')
  end
  function M.lines(tr, all, platform, aboard)
    local lines = {}
    lines[#lines+1] = string.format('ammunition that can reach a turret: %d (turrets %d, belts on their ways %d, sources %d%s%s); stranded: %d%s',
      tr.reaches, tr.turret_own, tr.on_belts_reached, tr.in_sources, tr.hub_ammo > 0 and string.format(', hub %d%s', tr.hub_ammo, tr.hub_reaches and '' or ' NOT reaching any turret: no inserter takes it toward one') or '',
      (tr.via_hub or 0) > 0 and string.format(', belts back into the hub %d', tr.via_hub) or '',
      tr.stranded, #tr.stranded_groups > 0 and ' on belts no turret\'s way reaches: ' .. table.concat(tr.stranded_groups, '; ') .. (tr.stranded_more and string.format('; +%d more groups', tr.stranded_more) or '') or '')
    if (tr.at_end or 0) > 0 then
      lines[#lines+1] = string.format('at belt ends past a pickup on a turret\'s way (not counted as stranded; they move on when the belt beyond is joined): %d: %s',
        tr.at_end, table.concat(tr.at_end_rows, '; '))
    end
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
    -- (d17 batch14 A7a) every turret's reach in one line
    local each = {}
    for i, row in ipairs(tr.rows) do if i <= 32 then each[i] = string.format('%s %d', at(row.position), row.reaches) end end
    if #each > 0 then
      lines[#lines+1] = 'ammunition that can reach each turret: ' .. table.concat(each, ', ') .. (#tr.rows > 32 and string.format(', +%d more', #tr.rows - 32) or '')
    end
    for _, r in ipairs(tr.stranded_recover or {}) do lines[#lines+1] = M.recover_line(r, platform, aboard) end
    if (tr.stranded_recover and #tr.stranded_recover > 0) then
      lines[#lines+1] = tr.hub_reaches and 'the hub\'s ammunition reaches a turret (an inserter takes it toward one)' or 'the hub\'s ammunition reaches NO turret: no inserter takes it toward one'
    end
    return lines
  end
  return M
end
