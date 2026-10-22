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
  -- (d17 batch23 A2, operator 23:47: a whole Kestrel II trace is about 25 ms, over the 20 ms a command may take on n)
  -- platforms with more than SYNC_BELTS belts are read in the background, READ_PER_TICK belts a tick, and their trace
  -- computed from those reads in one tick; a read is fresh for FRESH ticks.
  M.SYNC_BELTS, M.READ_PER_TICK, M.FRESH = 400, 256, 3600
  -- (d21 batch66 AB3) the gates a trace reads the condition of (feeders.lua), the first met
  M.MAX_GATE_READS = 16
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function at(q) return string.format('(%g,%g)', q.x, q.y) end
  local BELT = {['transport-belt']=true, ['underground-belt']=true, splitter=true, ['lane-splitter']=true, ['linked-belt']=true}
  local function key(e) return e.unit_number or (e.position.x .. ',' .. e.position.y) end
  local AMMO = {}
  local function is_ammo(name)
    local v = AMMO[name]
    if v == nil then v = try(function() return prototypes.item[name].type end) == 'ammo'; AMMO[name] = v end
    return v
  end
  -- (d17 batch23 A2) the per-belt reads as plain functions, each under one pcall
  -- a belt's inputs and outputs from one belt_neighbours read: belts, an underground's other end, a linked belt
  local function read_neighbours(e)
    local nb = e.belt_neighbours
    local ins, outs = {}, {}
    for _, u in ipairs(nb.inputs) do if u.valid then ins[#ins+1] = u end end
    for _, u in ipairs(nb.outputs or {}) do if u.valid then outs[#outs+1] = u end end
    local t = e.type
    if t == 'underground-belt' then
      local x = e.neighbours
      if x and x.valid then
        if e.belt_to_ground_type == 'output' then ins[#ins+1] = x else outs[#outs+1] = x end
      end
    elseif t == 'linked-belt' then
      local x = e.linked_belt_neighbour
      if x and x.valid then ins[#ins+1] = x end
    end
    return ins, outs
  end
  local function read_contents(e)
    local m = {}
    -- (only ammunition is kept: the trace counts nothing else)
    for i = 1, e.get_max_transport_line_index() do
      local l = e.get_transport_line(i)
      if #l > 0 then for _, r in ipairs(l.get_contents()) do if is_ammo(r.name) then m[r.name] = (m[r.name] or 0) + r.count end end end
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
  -- (d20 batch52 K6, Sol #1145: Wayfarer's bow guns looked fed at departure while their rail loop had no source, and a
  -- circuit set more positive filters than a bulk inserter's five slots) what refills a turret's way: a machine aboard
  -- whose recipe makes ammunition it takes (maker), the hub, a chest, or nothing (preload only: what is on its way now).
  local function source_kind(e, takes)
    if e.type == 'space-platform-hub' then return 'hub', 'the hub' end
    if e.type == 'assembling-machine' or e.type == 'furnace' then
      local r = try(function() return e.get_recipe() end)
      for _, pr in ipairs(r and try(function() return r.products end) or {}) do
        if takes(pr.name) then return 'maker', string.format('%s %s making %s', e.name, at(e.position), pr.name) end
      end
      return 'machine', string.format('%s %s (its recipe makes none of it)', e.name, at(e.position))
    end
    return 'chest', string.format('%s %s', e.name, at(e.position))
  end
  -- An inserter whose circuit sets its filters from more positive item signals than it has filter slots: the text.
  local function circuit_overflow(ins)
    local cb = try(function() return ins.get_control_behavior() end)
    if not (cb and try(function() return cb.circuit_set_filters end)) then return nil end
    local sig = try(function() return ins.get_signals(defines.wire_connector_id.circuit_red, defines.wire_connector_id.circuit_green) end) or {}
    local n = 0
    for _, x in ipairs(sig) do
      local t = x.signal and x.signal.type
      if (x.count or 0) > 0 and (t == nil or t == 'item') then n = n + 1 end
    end
    local slots = try(function() return ins.filter_slot_count end) or 0
    if n > slots then
      return string.format('%s %s: its circuit sets its filters from %d positive item signals, more than its %d filter slots (the rest are left out)', ins.name, at(ins.position), n, slots)
    end
  end
  -- (d21 batch66 AB3, Sol #1617: Solstice's five turrets read "preload only" while belt buffers capped near 10 held
  -- their source inserters off; every feed led to the maker aboard when the gates opened) an inserter or belt its
  -- circuit or logistic condition holds off now: its condition with the values on its wires (feeders.lua), else nil
  local function gate_text(e)
    local f = api.feeders and try(function() return api.feeders.read(e) end)
    local c = f and f.condition
    if not c then return nil end
    c = c:gsub(';? ?it is off by its condition', '')
    return c ~= '' and c or nil
  end
  -- every inserter of the force on a surface by what it drops into (key)
  local function inserters_into(s, f)
    local into = {}
    for _, i in ipairs(try(function() return s.find_entities_filtered{type='inserter', force=f} end) or {}) do
      local d = try(function() return i.drop_target end)
      if d and d.valid then local k = key(d); into[k] = into[k] or {}; table.insert(into[k], i) end
    end
    return into
  end
  local BELTS = {'transport-belt', 'underground-belt', 'splitter', 'linked-belt'}
  local function belts_of(s, f) return try(function() return s.find_entities_filtered{type=BELTS, force=f, limit=20000} end) or {} end
  -- One belt's reads into the caches: {inputs, outputs} of {e, k}, its ammunition, its switch, its place.
  local function read_belt(b, k, nbr, memo, offm, pos)
    local ok, ins, outs = pcall(read_neighbours, b)
    local c = {inputs={}, outputs={}}
    if ok then
      for _, u in ipairs(ins) do c.inputs[#c.inputs+1] = {e=u, k=u.unit_number or key(u)} end
      for _, u in ipairs(outs) do c.outputs[#c.outputs+1] = {e=u, k=u.unit_number or key(u)} end
    end
    nbr[k] = c
    if not memo[k] then local ok2, m = pcall(read_contents, b); memo[k] = ok2 and m or {} end
    local ok3, v = pcall(read_off, b)
    if ok3 then offm[k] = v else offm[k] = switched_off(b) end
    if pos then pos[k] = try(function() return b.position end) end
  end
  M.read_belt = read_belt
  -- pre (optional, the background read below): into, all, all_keys and the caches nbr, belt_memo, offm, pos already
  -- read; what is missing is read here.
  function M.trace(pl, pre)
    local s, f = pl.surface, pl.force
    local hub = try(function() local h = pl.hub; return h and h.valid and h or nil end)
    -- every inserter by what it drops into
    local into = pre and pre.into or inserters_into(s, f)
    -- (d17 batch23 A2: the trace read Kestrel II's 900-belt loop again for each of its 43 turrets, 180 ms on n) each
    -- belt's neighbours, each entity's switch and each inserter's pickup are read once per trace
    local belt_memo_of
    local nbr, offm, pickm, posm = pre and pre.nbr or {}, pre and pre.offm or {}, {}, pre and pre.pos or {}
    local function neighbours(e, k, dir)
      local c = nbr[k]
      if not c then read_belt(e, k, nbr, belt_memo_of(), offm, posm); c = nbr[k] end
      return c[dir]
    end
    local function pos(e, k)
      local q = posm[k]
      if not q then q = e.position; posm[k] = q end
      return q
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
    -- (AB3) a link gated closed now: its condition (read for the first MAX_GATE_READS), and the turrets whose way it is on
    local gatem, gate_reads, gates, gate_list = {}, 0, {}, {}
    local function gate(e, k)
      k = k or key(e)
      if gatem[k] == nil then
        local t
        if gate_reads < M.MAX_GATE_READS then gate_reads = gate_reads + 1; t = gate_text(e) end
        gatem[k] = t or 'its circuit or logistic condition holds it off'
      end
      return gatem[k]
    end
    local function note_gate(e, row, k)
      k = k or key(e)
      local g = gates[k]
      if not g then
        g = {name=e.name, position=pos(e, k), condition=gate(e, k), turrets={}, seen={}}
        gates[k] = g; gate_list[#gate_list+1] = g
      end
      if row and not g.seen[row] then g.seen[row] = true; g.turrets[#g.turrets+1] = row.position end
      return g
    end
    local amemo = {}
    local anyammo = function(name)
      if amemo[name] == nil then amemo[name] = try(function() return prototypes.item[name].type end) == 'ammo' end
      return amemo[name]
    end
    local belt_memo = pre and pre.belt_memo or {}
    belt_memo_of = function() return belt_memo end
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
              elseif not filter_blocks(si, anyammo) then
                -- (AB3) a relay gated closed now: its belts are read too, apart from the way that carries now
                n.gins = n.gins or {}; n.gins[#n.gins+1] = {si=si, k=sp.k}
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
    local function blank() return {items={}, n=0, live=0, hub=false, srcs={}, gates={}, relays={}, grelays={}, cs={}} end
    local function own_into(a, c)
      a.cs[c] = true
      for _, k in ipairs(c.keys) do
        local nd = node[k]
        belt_of(nd.e, anyammo, k)
        for name, cnt in pairs(belt_memo[k]) do if anyammo(name) then a.items[name] = (a.items[name] or 0) + cnt end end
        a.n = a.n + 1
        if off(nd.e, k) and #a.gates < 3 then a.gates[#a.gates+1] = {e=nd.e, k=k} end
        for _, g in ipairs(nd.gins or {}) do a.grelays[#a.grelays+1] = g end
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
      for _, y in ipairs(x.grelays) do a.grelays[#a.grelays+1] = y end
      for y in pairs(x.cs) do a.cs[y] = true end
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
      local row = {entity=t, name=tname, position=t.position, own=own_n, reaches=own_n, ways={}, stops={}, gated={}}
      local feeders = into[key(t)] or {}
      if #feeders == 0 then row.stops[#row.stops+1] = 'no inserter feeds it' end
      for _, i in ipairs(feeders) do
        local way = string.format('%s %s', i.name, at(i.position))
        -- (AB3) a feeder its condition holds off now: its way is traced as any other, what is on it counted behind the gate
        local blocked = filter_blocks(i, takes)
        local shut = not blocked and off(i) and gate(i) or nil
        local h = try(function() return i.held_stack end)
        if h and try(function() return h.valid_for_read end) and takes(h.name) then
          if shut then row.behind_gate = (row.behind_gate or 0) + h.count else row.reaches = row.reaches + h.count end
        end
        local ov = circuit_overflow(i)
        if ov then row.overflow = row.overflow or {}; row.overflow[#row.overflow+1] = ov end
        local src = pickup(i)
        if shut then note_gate(i, row) end
        local shut_text = shut and ' (gated closed now: ' .. shut .. ')' or ''
        if blocked then row.stops[#row.stops+1] = way .. ': ' .. blocked
        elseif not src then row.stops[#row.stops+1] = way .. ': takes from nothing'
        elseif BELT[src.e.type] then
          pending[#pending+1] = {row=row, way=way, src=src, takes=takes, slot=#row.ways + 1, ins=i, shut=shut}
          row.ways[#row.ways+1] = false
          starts[#starts+1] = src
        elseif src.e.type == 'space-platform-hub' then
          any_hub = true
          row.supply = row.supply or {}; row.supply[#row.supply+1] = {kind='hub', text='the hub', gate=shut}
          local held = inv_count(hub_inv, takes)
          if shut then
            if not row.hub_counted and not row.hub_behind then row.hub_behind = true; row.behind_gate = (row.behind_gate or 0) + held end
            row.gated[#row.gated+1] = string.format('%s gated closed now (%s): the hub\'s %d of its ammo waits behind it', way, shut, held)
          elseif not row.hub_counted then
            row.hub_counted = true; row.reaches = row.reaches + held
            if row.hub_behind then row.behind_gate = row.behind_gate - held end
          end
          row.ways[#row.ways+1] = string.format('%s from the hub (holds %d of its ammo)%s', way, held, shut_text)
        else
          local held = inv_count(try(function() return src.e.get_output_inventory() end) or try(function() return src.e.get_inventory(defines.inventory.chest) end), takes)
          local sk, st = source_kind(src.e, takes)
          row.supply = row.supply or {}; row.supply[#row.supply+1] = {kind=sk, text=st, gate=shut}
          reached_src[src.k] = {e=src.e, n=held}
          if shut then
            row.behind_gate = (row.behind_gate or 0) + held
            row.gated[#row.gated+1] = string.format('%s gated closed now (%s): %d of its ammo waits behind it in %s %s', way, shut, held, src.e.name, at(src.e.position))
          else row.reaches = row.reaches + held end
          row.ways[#row.ways+1] = string.format('%s from %s %s (holds %d)%s', way, src.e.name, at(src.e.position), held, shut_text)
        end
      end
      rows[#rows+1] = row
    end
    discover(starts)
    components()
    for _, w in ipairs(pending) do local c = comp[w.src.k]; w.order = c and c.order or math.huge end
    table.sort(pending, function(x, y) return x.order < y.order end)
    for _, n in ipairs(nodes) do reached_belts[n.k] = n.e end
    -- (d17 batch32 B5, Astra: Kestrel II read 15 railgun rounds able to reach a railgun while both railguns stood empty:
    -- the rounds sat behind magazines on a full ring) the lanes a feeder picks from at its pickup tile: a lane full of
    -- items whose front item the turret does not take holds back everything behind it. Every lane the inserter picks
    -- that way blocked: the way is blocked now ({item ahead, line naming each lane's mix}); nil otherwise.
    local function lane_ahead(ins, belt, takes)
      local blocked, parts = 0, {}
      local picked = 0
      for k = 1, 2 do
        local lane_key = k == 1 and 'pickup_from_left_lane' or 'pickup_from_right_lane'
        if try(function() return ins[lane_key] end) ~= false then
          picked = picked + 1
          local line = try(function() return belt.get_transport_line(k) end)
          local det = line and try(function() return line.get_detailed_contents() end) or {}
          local len = line and try(function() return line.line_length end) or 1
          local front, fp, mix = nil, nil, {}
          for _, d in ipairs(det) do
            local st = d.stack
            local n = st and try(function() return st.valid_for_read and st.name end)
            if n then
              mix[n] = (mix[n] or 0) + (try(function() return st.count end) or 1)
              if not fp or d.position > fp then front, fp = n, d.position end
            end
          end
          if front and #det >= math.floor(len * 4 + 0.5) and not takes(front) then
            blocked = blocked + 1
            local m = {}
            for n, c in pairs(mix) do m[#m+1] = c .. ' ' .. n end
            table.sort(m)
            parts[#parts+1] = {item=front, text=string.format('the %s lane at %s is full, %s at its front (mix: %s)', k == 1 and 'left' or 'right', at(belt.position), front, table.concat(m, ', '))}
          end
        end
      end
      if picked > 0 and blocked == picked then
        local texts = {}
        for _, x in ipairs(parts) do texts[#texts+1] = x.text end
        return {item=parts[1].item, line=table.concat(texts, '; ')}
      end
      return nil
    end
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
      local shut = w.shut
      local hub_held = 0
      local function hub_once(into_behind)
        local n = held_of({sp={e=hub, k=key(hub)}})
        if row.hub_counted or (into_behind and row.hub_behind) then return 0 end
        if into_behind then row.hub_behind = true; return n end
        row.hub_counted = true
        if row.hub_behind then row.behind_gate = row.behind_gate - n end
        return n
      end
      if a.hub then
        any_hub = true
        hub_held = hub_once(shut ~= nil)
        if not shut then row.reaches = row.reaches + hub_held end
      end
      local src_list, gates, relays, seen_src = a.srcs, a.gates, a.relays, {}
      local okb, ahead = pcall(lane_ahead, w.ins, src.e, takes)
      ahead = okb and ahead or nil
      local gain = on
      for _, x in ipairs(src_list) do
        if not x.off and x.sp.e.type ~= 'space-platform-hub' and not seen_src[x.sp.k] then
          seen_src[x.sp.k] = true
          local n = held_of(x)
          reached_src[x.sp.k] = {e=x.sp.e, n=n}
          gain = gain + n
        end
      end
      -- (AB3) what waits behind a link gated closed now: the sources putting items on these belts that their condition
      -- holds off, and the belts behind a relay held off (their ammunition and sources), each by the first gate on it
      local back = 0
      local function behind_src(x)
        if x.sp.e.type == 'space-platform-hub' then any_hub = true; back = back + hub_once(true)
        elseif not seen_src[x.sp.k] then
          seen_src[x.sp.k] = true
          local n = held_of(x)
          reached_src[x.sp.k] = {e=x.sp.e, n=n}
          back = back + n
        end
      end
      for _, x in ipairs(src_list) do if x.off then behind_src(x) end end
      local behind, bseen = {}, {}
      local function behind_of(x, g)
        for _, r in ipairs(x.grelays) do
          local c2 = comp[r.k]
          if c2 and not a.cs[c2] and not bseen[c2] then
            bseen[c2] = true
            local bw = way_of(c2)
            behind[#behind+1] = {g=g or r.si, way=bw}
            behind_of(bw, g or r.si)
          end
        end
      end
      behind_of(a)
      local behind_n, behind_srcs = 0, 0
      for _, bh in ipairs(behind) do
        for name, cnt in pairs(bh.way.items) do if takes(name) then behind_n = behind_n + cnt end end
        for _, x in ipairs(bh.way.srcs) do behind_srcs = behind_srcs + 1; behind_src(x) end
        if bh.way.hub then behind_srcs = behind_srcs + 1; any_hub = true; back = back + hub_once(true) end
      end
      back = back + behind_n
      local ahead_n = gain
      if shut then back = back + gain + hub_held; gain = 0
      elseif ahead then row.blocked = (row.blocked or 0) + gain else row.reaches = row.reaches + gain end
      if back > 0 then row.behind_gate = (row.behind_gate or 0) + back end
      row.belts = (row.belts or 0) + a.n
      -- (d17 batch23 A2, Astra: a disabled old loader was named beside the bulk inserter feeding the loop) the
      -- switched-off ones are named only when nothing else puts items on
      -- (K6) what refills this way, the ammunition on it the turret takes none of, and circuit filters past the slots
      -- (AB3) a source reached through a link gated closed now is kept, with that gate
      row.supply = row.supply or {}
      for _, x in ipairs(src_list) do
        local sk, st = source_kind(x.sp.e, takes)
        if not x.off then row.supply[#row.supply+1] = {kind=sk, text=st, gate=shut}
        else row.supply[#row.supply+1] = {kind=sk, text=st, gate=shut or gate(x.si)}; note_gate(x.si, row) end
        local ov = circuit_overflow(x.si)
        if ov then row.overflow = row.overflow or {}; row.overflow[#row.overflow+1] = ov end
      end
      if a.hub then row.supply[#row.supply+1] = {kind='hub', text='the hub', gate=shut} end
      local through = {}
      for _, bh in ipairs(behind) do
        local gt = shut or gate(bh.g)
        for _, x in ipairs(bh.way.srcs) do
          local sk, st = source_kind(x.sp.e, takes)
          row.supply[#row.supply+1] = {kind=sk, text=st, gate=gt}
        end
        if bh.way.hub then row.supply[#row.supply+1] = {kind='hub', text='the hub', gate=gt} end
        local g = note_gate(bh.g, row)
        if not through[g] and #through < 3 then
          through[g] = true
          local n = 0
          for name, cnt in pairs(bh.way.items) do if takes(name) then n = n + cnt end end
          through[#through+1] = string.format('%s %s (gated closed now: %s) from %d belt%s holding %d of its ammo', g.name, at(g.position), g.condition, bh.way.n, bh.way.n == 1 and '' or 's', n)
        end
      end
      for name, cnt in pairs(a.items) do
        if not takes(name) and is_ammo(name) then row.wrong = row.wrong or {}; row.wrong[name] = (row.wrong[name] or 0) + cnt end
      end
      local sources, off_sources, off_names = {}, {}, {}
      for _, x in ipairs(src_list) do
        local text = string.format('%s %s from %s %s (holds %d of its ammo)', x.si.name, at(x.si.position), x.sp.e.name, at(x.sp.e.position), held_of(x)) .. (x.off and ' (gated closed now: ' .. gate(x.si) .. ')' or '')
        if not x.off and #sources < 4 then sources[#sources+1] = text
        elseif x.off and #off_sources < 4 then off_sources[#off_sources+1] = text; off_names[#off_names+1] = x.si.name .. ' ' .. at(x.si.position) end
      end
      local text = string.format('%s from %s %s: %d of its ammo on %d belt%s upstream%s', way, src.e.name, at(src.e.position), on, a.n, a.n == 1 and '' or 's',
        capped and ' (of the first ' .. M.MAX_BELTS .. ' belts read)' or '')
      if #relays > 0 then text = text .. '; through ' .. table.concat(relays, ', ') end
      if #sources > 0 then text = text .. '; put on them by ' .. table.concat(sources, ', ') end
      if a.live == 0 and #off_sources > 0 then text = text .. '; put on them by ' .. table.concat(off_sources, ', ') end
      if #through > 0 then text = text .. '; behind a relay ' .. table.concat(through, ', ') end
      if shut then
        text = text .. ' (its feeder gated closed now: ' .. shut .. ')'
        row.gated[#row.gated+1] = string.format('%s gated closed now (%s): %d of its ammo waits behind it', way, shut, back)
      end
      -- (AB3) nothing carries onto these belts now: a source or relay gated closed now is the current flow, said apart
      -- from a way with no source at all (STOPPED: dry after what is on it)
      if a.live == 0 then
        if #off_sources > 0 or behind_srcs > 0 then
          for _, bh in ipairs(behind) do if #off_names < 4 then off_names[#off_names+1] = bh.g.name .. ' ' .. at(bh.g.position) end end
          row.gated[#row.gated+1] = string.format('%s: the inserters putting items on the belts upstream of %s %s are gated closed now (%s): nothing more comes onto them until one opens; %d on them now',
            way, src.e.name, at(src.e.position), table.concat(off_names, ', '), on)
        else
          row.stops[#row.stops+1] = string.format('%s: no inserter puts anything on the belts upstream of %s %s: the %d on them, then dry', way, src.e.name, at(src.e.position), on)
        end
      end
      for _, g in ipairs(gates) do
        note_gate(g.e, row, g.k)
        row.gated[#row.gated+1] = string.format('%s %s gated closed now (%s)', g.e.name, at(pos(g.e, g.k)), gate(g.e, g.k))
      end
      if ahead then
        text = text .. string.format('; blocked by %s ahead (%s)', ahead.item, ahead.line)
        row.stops[#row.stops+1] = string.format('%s: blocked by %s ahead: %s; the %d behind it do not reach the turret now', way, ahead.item, ahead.line, ahead_n)
      end
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
    local all = pre and pre.all or belts_of(s, f)
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
    local all_keys = pre and pre.all_keys
    if not all_keys then all_keys = {}; for i, b in ipairs(all) do all_keys[i] = key(b) end end
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
          loose[#loose+1] = {e=b, k=k, n=n, q=pos(b, k)}; stranded = stranded + n
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
          local q = y.q
          g.x0, g.y0, g.x1, g.y1 = math.min(g.x0, q.x), math.min(g.y0, q.y), math.max(g.x1, q.x), math.max(g.y1, q.y)
          for k, z in ipairs(loose) do
            if not done[k] and math.abs(z.q.x - q.x) <= 3 and math.abs(z.q.y - q.y) <= 3 then done[k] = true; queue[#queue+1] = k end
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
        for k, y in ipairs(g.belts) do if k <= 8 then bl[k] = string.format('%s %s %d', y.e.name, at(y.q), y.n) end end
        local box = {left_top={x=math.floor(g.x0), y=math.floor(g.y0)}, right_bottom={x=math.floor(g.x1) + 1, y=math.floor(g.y1) + 1}}
        local others = 0
        for j, b in ipairs(all) do
          local q = pos(b, all_keys[j])
          if q.x >= box.left_top.x and q.x <= box.right_bottom.x and q.y >= box.left_top.y and q.y <= box.right_bottom.y then others = others + 1 end
        end
        others = others - g.n
        recover[i] = {count=g.count, belts=bl, belts_more=g.n > 8 and g.n - 8 or nil, area=box, other_belts_in_area=others > 0 and others or nil}
      end
    end
    for _, g in ipairs(gate_list) do g.seen = nil end
    return {rows=rows, reaches=reaches, stranded=stranded, stranded_groups=glines, stranded_recover=recover, stranded_more=#groups > 6 and #groups - 6 or nil,
      hub_ammo=hub_total, hub_reaches=any_hub, turret_own=turret_own, on_belts_reached=belt_reach, in_sources=src_total,
      stranded_by=stranded_by, hub_stranded=hub_stranded, via_hub=via_hub, at_end=at_end_n, at_end_rows=end_rows, gates=gate_list}
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
  -- A turret's supply in one word: maker, hub, chest (chests only), preload (ways with nothing that refills them), none
  -- (no inserter feeds it). (AB3) A source behind a link gated closed now counts; the second value is true when every
  -- source of that kind is behind one.
  function M.supply_kind(row)
    local k, open = {}, {}
    for _, x in ipairs(row.supply or {}) do k[x.kind] = true; if not x.gate then open[x.kind] = true end end
    for _, kind in ipairs({'maker', 'hub', 'chest'}) do if k[kind] then return kind, not open[kind] end end
    for _, st in ipairs(row.stops or {}) do if st == 'no inserter feeds it' then return 'none' end end
    return 'preload'
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
          lines[#lines+1] = string.format('%s %s: holds %d; %d reach it%s%s%s%s%s', row.name, at(row.position), row.own, row.reaches,
            row.blocked and string.format(', %d more blocked by other ammunition ahead', row.blocked) or '',
            (row.behind_gate or 0) > 0 and string.format(', %d more behind a link gated closed now', row.behind_gate) or '',
            #row.ways > 0 and ' (' .. table.concat(row.ways, ' | ') .. ')' or '',
            row.gated and #row.gated > 0 and '; NOW: ' .. table.concat(row.gated, '; ') or '',
            #row.stops > 0 and '; STOPPED: ' .. table.concat(row.stops, '; ') or '')
        end
      end
    end
    if shown > 16 then lines[#lines+1] = string.format('+%d more turrets', shown - 16) end
    -- (d20 batch52 K6) what refills each turret: a maker aboard, the hub, chests only, or nothing (preload only)
    local by, makers, preload, wrong, over, seen_over = {maker=0, hub=0, chest=0, preload=0, none=0}, {}, {}, {}, {}, {}
    local shut, shut_at = {maker=0, hub=0, chest=0}, {maker={}, hub={}, chest={}}
    for _, row in ipairs(tr.rows) do
      local k, g = M.supply_kind(row)
      row.replenished = k
      row.replenished_gated = g or nil
      by[k] = by[k] + 1
      if g then shut[k] = shut[k] + 1; if #shut_at[k] < 8 then shut_at[k][#shut_at[k]+1] = at(row.position) end end
      if k == 'maker' then
        for _, x in ipairs(row.supply or {}) do if x.kind == 'maker' and not makers[x.text] then makers[x.text] = true; makers[#makers+1] = x.text end end
      elseif k == 'preload' and #preload < 12 then preload[#preload+1] = at(row.position) end
      if row.wrong and #wrong < 8 then
        local w = {}
        for name, n in pairs(row.wrong) do w[#w+1] = n .. ' ' .. name end
        table.sort(w)
        wrong[#wrong+1] = string.format('%s %s: %s on its way (it takes none of it)', row.name, at(row.position), table.concat(w, ', '))
      end
      for _, o in ipairs(row.overflow or {}) do if not seen_over[o] and #over < 6 then seen_over[o] = true; over[#over+1] = o end end
    end
    if #tr.rows > 0 then
      -- (AB3) those whose only route of that kind runs through a link gated closed now
      local function g(k)
        if shut[k] == 0 then return '' end
        return string.format(' (%d of them only through a link gated closed now: %s%s)', shut[k], table.concat(shut_at[k], ', '), shut[k] > #shut_at[k] and string.format(' +%d more', shut[k] - #shut_at[k]) or '')
      end
      lines[#lines+1] = string.format('replenishment by turret: %d from an ammunition maker aboard%s%s, %d from the hub%s, %d from chests only (what fills them is not traced)%s, %d preload only%s%s',
        by.maker, #makers > 0 and ' (' .. table.concat(makers, ', ', 1, math.min(3, #makers)) .. ')' or '', g('maker'), by.hub, g('hub'), by.chest, g('chest'), by.preload,
        #preload > 0 and ': ' .. table.concat(preload, ', ') .. (by.preload > #preload and string.format(' +%d more', by.preload - #preload) or '')
          .. ' (nothing puts more on their way: what they hold and what is on their way now is all)' or '',
        by.none > 0 and string.format(', %d with no inserter feeding it', by.none) or '')
    end
    -- (AB3) each link gated closed now on a turret's way: its condition with the values it reads, the turrets behind it
    local gl = {}
    for i, x in ipairs(tr.gates or {}) do
      if i <= 6 then
        local t = {}
        for j, q in ipairs(x.turrets) do if j <= 6 then t[j] = at(q) end end
        gl[i] = string.format('%s %s (%s) on the way of %d turret%s: %s%s', x.name, at(x.position), x.condition, #x.turrets, #x.turrets == 1 and '' or 's',
          table.concat(t, ', '), #x.turrets > 6 and string.format(' +%d more', #x.turrets - 6) or '')
      end
    end
    if #gl > 0 then
      lines[#lines+1] = 'gated closed now (a route to the turret, held off by its condition now; it carries when its condition is met): ' .. table.concat(gl, '; ')
        .. (#tr.gates > 6 and string.format('; +%d more', #tr.gates - 6) or '')
    end
    if #wrong > 0 then lines[#lines+1] = 'wrong ammunition on turrets\' ways: ' .. table.concat(wrong, '; ') end
    if #over > 0 then lines[#lines+1] = 'circuit filters past the slots: ' .. table.concat(over, '; ') end
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
  -- The background read ----------------------------------------------------------------------------------------
  local function jobs()
    local st = api.state and api.state()
    if not st then return nil end
    st.ammofeed = st.ammofeed or {jobs={}, done={}}
    return st.ammofeed
  end
  -- Begin a read of pl (one at a time per platform): the inserters and belts are found now (one tick).
  function M.start(pl)
    local J = jobs()
    if not J or J.jobs[pl.index] then return end
    local s, f = pl.surface, pl.force
    local all = belts_of(s, f)
    local keys = {}
    for i, b in ipairs(all) do keys[i] = key(b) end
    J.jobs[pl.index] = {pl=pl, name=pl.name, started=game.tick, i=1, into=inserters_into(s, f), all=all, all_keys=keys, nbr={}, belt_memo={}, offm={}, pos={}}
  end
  -- Each tick: READ_PER_TICK belts of the first job; when all are read, its trace (one tick) is kept in done.
  function M.step()
    local J = jobs()
    if not J then return end
    local index, job = next(J.jobs)
    if not index then return end
    local pl = job.pl
    if not (pl and pl.valid and pl.surface) then J.jobs[index] = nil; return end
    if job.i <= #job.all then
      local last = math.min(#job.all, job.i + M.READ_PER_TICK - 1)
      for i = job.i, last do
        local b = job.all[i]
        if b.valid then read_belt(b, job.all_keys[i], job.nbr, job.belt_memo, job.offm, job.pos) end
      end
      job.i = last + 1
      return
    end
    J.jobs[index] = nil
    -- belts gone during the read are left out
    local all, keys = {}, {}
    for i, b in ipairs(job.all) do if b.valid then all[#all+1] = b; keys[#keys+1] = job.all_keys[i] end end
    job.all, job.all_keys = all, keys
    local ok, tr = pcall(M.trace, pl, job)
    J.done[index] = {tick=game.tick, started=job.started, tr=ok and tr or nil, error=not ok and tostring(tr) or nil}
  end
  -- The trace for a reader: read at once for a platform of up to SYNC_BELTS belts; else the last background read (said
  -- with its age; a new one begins when it is older than max_age, default FRESH), or nil and why while the first runs.
  -- background: the background read for any platform (d19 batch45: the reply's platform alerts traced Swift's 138 belts and
  -- 6 turrets at once, 33 ms on the private copy).
  function M.get(pl, max_age, background)
    local J = jobs()
    local n = J and (try(function() return pl.surface.count_entities_filtered{type=BELTS, force=pl.force} end) or 0) or 0
    if not J or n <= M.SYNC_BELTS and not background then
      local tr = M.trace(pl)
      tr.read_tick, tr.read_started = game.tick, game.tick
      return tr
    end
    local d = J.done[pl.index]
    if not d or game.tick - d.tick >= (max_age or M.FRESH) then M.start(pl) end
    if d and d.tr then
      -- (d21 batch72 AH1) when the read began and ended (flightwatch.lua: a turret's feed in its empty run)
      d.tr.read_tick, d.tr.read_started = d.tick, d.started
      d.tr.as_of = string.format('read over %d ticks in the background (%d belts, %d a tick), %ds ago', d.tick - d.started, n, M.READ_PER_TICK,
        math.floor((game.tick - d.tick) / 60))
      return d.tr
    end
    local left = math.ceil(n / M.READ_PER_TICK) + 1
    return nil, string.format('the ammunition trace of %s (%d belts) is read in the background over about %d ticks (%d belts a tick, the 20 ms rule); read again in a second%s',
      pl.name, n, left, M.READ_PER_TICK, d and d.error and ' (the last read failed: ' .. d.error .. ')' or '')
  end
  -- Drop the reads of platforms gone.
  function M.forget(index) local J = jobs(); if J then J.jobs[index] = nil; J.done[index] = nil end end
  return M
end
