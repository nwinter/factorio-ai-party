-- circuit_audit {platform} (d17 batch14 A7b, Sol: twice metal-starved while a collector filtered oxide despite a
-- positive metal demand; and whole-belt readers counting the same belt twice): a platform's circuit readings that
-- mislead, as the entities' settings and the networks show them now.
-- - belts reading their entire belt (read_contents_mode entire_belt_hold): each one's whole belt (followed through
--   its inputs and outputs, an underground to its pair, one each way; a splitter or side-load ends it), and two such
--   readers on the same circuit network whose whole belts share tiles: those items reach the network twice;
-- - asteroid collectors whose filters the circuit sets (set_filter): the chunk signals on their networks with their
--   values (only a positive one sets a filter), and the filter the collector holds now.
-- Read only; bounded: 256 readers, 64 collectors, SEG tiles each way of a belt.
return function(api)
  local M = {}
  local SEG, MAX_READERS = 400, 256
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function at(q) return string.format('(%g,%g)', q.x, q.y) end
  local function key(e) return e.unit_number or (e.position.x .. ',' .. e.position.y) end
  local WIRES
  local function wires() WIRES = WIRES or {defines.wire_connector_id.circuit_red, defines.wire_connector_id.circuit_green}; return WIRES end
  local function networks(e)
    local out = {}
    for i, w in ipairs(wires()) do
      local n = try(function() return e.get_circuit_network(w) end)
      if n then out[#out+1] = {id=n.network_id, color=i == 1 and 'red' or 'green', net=n} end
    end
    return out
  end
  -- The whole belt through e: {set, n, ways} (ways: each way's belts in order from e)
  local function whole(e)
    local set, n, ways = {[key(e)]=true}, 1, {inputs={}, outputs={}}
    for _, way in ipairs({'inputs', 'outputs'}) do
      local cur, steps = e, 0
      while steps < SEG do
        local bn = try(function() return cur.belt_neighbours end)
        local list = bn and bn[way] or {}
        local nxt = #list == 1 and list[1] or nil
        if not nxt and cur.type == 'underground-belt' then
          local pair = try(function() return cur.neighbours end)
          local t = try(function() return cur.belt_to_ground_type end)
          if pair and pair.valid and ((way == 'inputs' and t == 'output') or (way == 'outputs' and t == 'input')) then nxt = pair end
        end
        if not nxt or nxt.type == 'splitter' or set[key(nxt)] then break end
        set[key(nxt)] = true; n = n + 1; ways[way][#ways[way]+1] = nxt
        cur = nxt; steps = steps + 1
      end
    end
    return set, n, ways
  end
  -- What a whole-belt read leaves out (d17 batch19 B2, Astra: Swiftlet's mixed-ingredient control deadlocked; inspect
  -- showed eight tiles and the read covered fewer): the game reads the reader's belt segment, and every belt of one
  -- segment reports the same total_segment_length, the sum of their line lengths (measured on world n's Spindle: 14
  -- belts, a lane 12.83 and 14.30 tiles). Walking out from the reader along the physical belt (undergrounds to their
  -- pair, as whole), the belts from the first with another segment length on are left out: {runs, n, seg} or nil.
  local function seglen(e) return try(function() return e.get_transport_line(1).total_segment_length end) end
  local function left_out(e, ways)
    local mine = seglen(e)
    if not mine then return nil end
    local runs, n = {}, 0
    for _, way in ipairs({'outputs', 'inputs'}) do
      local list, cut = ways[way], nil
      for i, b in ipairs(list) do
        local l = seglen(b)
        if not cut and (not l or math.abs(l - mine) > 0.001) then cut = i end
      end
      if cut then
        runs[#runs+1] = {side=way == 'outputs' and 'downstream' or 'upstream', from=list[cut].position, to=list[#list].position, belts=#list - cut + 1}
        n = n + #list - cut + 1
      end
    end
    return n > 0 and {runs=runs, n=n, seg=mine} or nil
  end
  local MODE
  -- Networks across entities (d17 batch16 B3, Sol: deficit wiring took dozens of inspect calls and comparing networks
  -- by hand): for the entities in an area or at positions, each red and green network one of them is on, by id: the
  -- signals on it now (the game's counts, largest first, up to SIGNALS), and which of those entities are on it, each
  -- with its circuit settings in a few words. On your surface, or a platform's with platform. Read only; bounded:
  -- an area up to 128x128, 64 positions, 256 entities.
  local SIGNALS, ENTITIES, LISTED = 24, 256, 16
  local function box_of(v)
    local lt, rb = v.left_top or v[1], v.right_bottom or v[2]
    local function xy(q) return type(q) == 'table' and tonumber(q.x or q[1]), type(q) == 'table' and tonumber(q.y or q[2]) end
    local x0, y0 = xy(lt); local x1, y1 = xy(rb)
    assert(x0 and y0 and x1 and y1 and x1 > x0 and y1 > y0, 'area must be {left_top: {x, y}, right_bottom: {x, y}}')
    assert(x1 - x0 <= 128 and y1 - y0 <= 128, 'area is at most 128x128')
    return {{x0, y0}, {x1, y1}}
  end
  function M.networks_read(p, a)
    local s, force, where = p.surface, p.force, type(p) == 'table' and rawget(p, '__remote') and p.surface.name or 'your surface'
    if a.platform ~= nil then
      local pl = api.platform(p, a.platform)
      s, force, where = pl.surface, pl.force, 'platform ' .. pl.name
      assert(s, 'platform ' .. pl.name .. ' has no surface yet')
    end
    local list, seen = {}, {}
    local unseen = 0
    local function add(e)
      if e.valid and api.seen and not api.seen(p, e.position) then unseen = unseen + 1; return end
      if e.valid and not seen[key(e)] and #list < ENTITIES then seen[key(e)] = true; list[#list+1] = e end
    end
    if a.area ~= nil then
      for _, e in ipairs(s.find_entities_filtered{area=box_of(a.area), force=force, limit=ENTITIES * 4}) do
        if #networks(e) > 0 then add(e) end
      end
    end
    if a.positions ~= nil then
      assert(type(a.positions) == 'table' and #a.positions >= 1 and #a.positions <= 64, 'positions is a list of 1..64 {x, y}')
      for i, q in ipairs(a.positions) do
        local x, y = type(q) == 'table' and tonumber(q.x or q[1]), type(q) == 'table' and tonumber(q.y or q[2])
        assert(x and y, 'positions[' .. i .. '] needs x and y')
        for _, e in ipairs(s.find_entities_filtered{position={x, y}, force=force, limit=4}) do
          if e.type ~= 'character' and #networks(e) > 0 then add(e) end
        end
      end
    end
    local nets, order = {}, {}
    for _, e in ipairs(list) do
      for _, n in ipairs(networks(e)) do
        local k = n.color .. n.id
        local row = nets[k]
        if not row then
          row = {id=n.id, color=n.color, members={}, signals={}}
          local sigs = try(function() return n.net.signals end) or {}
          table.sort(sigs, function(x, y) return math.abs(x.count) > math.abs(y.count) end)
          for i, sg in ipairs(sigs) do
            if i <= SIGNALS and sg.signal then row.signals[#row.signals+1] = {name=sg.signal.name, quality=sg.signal.quality, count=sg.count} end
          end
          row.signals_total = #sigs
          row.connected = try(function() return n.net.connected_circuit_count end)
          nets[k] = row; order[#order+1] = row
        end
        row.members[#row.members+1] = e
      end
    end
    table.sort(order, function(x, y) if x.id ~= y.id then return x.id < y.id end return x.color < y.color end)
    local lines, rows = {}, {}
    for _, r in ipairs(order) do
      local sig = {}
      for i, sg in ipairs(r.signals) do sig[i] = sg.name .. (sg.quality and sg.quality ~= 'normal' and '@' .. sg.quality or '') .. ' ' .. sg.count end
      local on = {}
      for i, e in ipairs(r.members) do
        if i <= LISTED then
          local set = api.circuit_short and try(function() return api.circuit_short(e) end)
          on[#on+1] = e.name .. ' ' .. at(e.position) .. (set and set ~= 'wired, default settings' and ' (' .. set .. ')' or '')
        end
      end
      local members = {}
      for _, e in ipairs(r.members) do members[#members+1] = {name=e.name, position={x=e.position.x, y=e.position.y}, unit_number=e.unit_number} end
      rows[#rows+1] = {id=r.id, color=r.color, signals=r.signals, signals_total=r.signals_total, entities=members, connected_entities=r.connected}
      lines[#lines+1] = string.format('%s #%d: %s%s; of these, %d on it%s: %s%s', r.color, r.id,
        #sig > 0 and 'signals ' .. table.concat(sig, ', ') or 'no signal now', r.signals_total > #sig and string.format(' (+%d more)', r.signals_total - #sig) or '',
        #r.members, r.connected and string.format(' (%d connected in all)', r.connected) or '', table.concat(on, '; '),
        #r.members > LISTED and string.format('; +%d more', #r.members - LISTED) or '')
    end
    if #order == 0 then lines[1] = 'no entity there is on a red or green network' end
    if unseen > 0 then lines[#lines+1] = string.format('%d entit%s out of sight now (no radar coverage there): not read', unseen, unseen == 1 and 'y' or 'ies') end
    -- (D1, D2) the feeders among them the circuit sets or gates, as the platform read gives them
    local feeders = {}
    M.feeders_begin()
    for _, e in ipairs(list) do
      if (e.type == 'inserter' or e.type == 'loader' or e.type == 'loader-1x1') and #feeders < M.FEEDERS then
        local ok, line, row = pcall(M.feeder, e)
        if ok and line then feeders[#feeders+1] = row; lines[#lines+1] = line end
      end
    end
    M.feeders_end()
    return {where=where, entities=#list, out_of_sight=unseen > 0 and unseen or nil, networks=rows, lines=lines, feeder_rows=#feeders > 0 and feeders or nil}
  end
  -- Feeders the circuit gates (d18 batch38 D1 with batch37 D2; Sol 18:21, more than 10 reads: whole-belt counts took in
  -- output branches the feeders could not reach, and a filter set from a constant minus a belt reader starved the
  -- crusher feed): each inserter of ours whose filters the circuit sets, or which the circuit turns on and off, with the
  -- signals on its networks, the combinators putting out onto them (and the networks those read, FEED_DEPTH deep), and
  -- each belt reader among them: its read mode, exactly which belts its count covers (hold: its own belt; whole belt:
  -- the game's segment, as left_out reads it), what that count holds now of the items the inserter takes, the belts of
  -- it past the inserter's pickup (it cannot take what they hold), and side-loads joining inside the count. The hub's
  -- read is said apart. Bounded: FEEDERS inserters, NET_CONNS connectors a network.
  local FEEDERS, NET_CONNS, FEED_DEPTH, SOURCES = 8, 96, 3, 8
  M.FEEDERS = FEEDERS
  local BELT_BUDGET, ONE_BUDGET = 160, 400  -- belts a read walks: all feeders, one feeder (inserter)
  local READ_MODE
  local function mode_name(m)
    READ_MODE = READ_MODE or (defines.control_behavior and defines.control_behavior.transport_belt and defines.control_behavior.transport_belt.content_read_mode) or {}
    for k, v in pairs(READ_MODE) do if v == m then return k end end
    return tostring(m)
  end
  -- one read's memo (M.feeders_memo): each belt's contents, each reader's belts, each network's members
  local memo = {}
  local function lane_count(b, item)
    local k = key(b)
    local c = memo.contents and memo.contents[k]
    if not c then
      c = {}
      for i = 1, try(function() return b.get_max_transport_line_index() end) or 0 do
        for _, it in ipairs(try(function() return b.get_transport_line(i).get_contents() end) or {}) do
          local n = type(it.name) == 'string' and it.name or try(function() return it.name.name end)
          if n then c[n] = (c[n] or 0) + (it.count or 0) end
        end
      end
      if memo.contents then memo.contents[k] = c end
    end
    return c[item] or 0
  end
  -- the belts a reader's count covers, in flow order, and the reader's index in it
  -- (the walk follows the straight input at a side-load, as the game's segment does, an underground to its pair, and
  -- stops at a splitter or where the segment length changes)
  local covered_walk
  local function covered(b, mode)
    if mode ~= 'entire_belt_hold' then return {b}, 1 end
    local m = memo.cover and memo.cover[key(b)]
    if m then return m[1], m[2] end
    -- (a read walks at most BELT_BUDGET belts: about 20 us a belt on world n)
    if memo.walked and memo.walked >= (memo.budget or BELT_BUDGET) then return nil end
    local list, at_i = covered_walk(b)
    if memo.walked then memo.walked = memo.walked + #list end
    if memo.cover then memo.cover[key(b)] = {list, at_i} end
    return list, at_i
  end
  covered_walk = function(b)
    local mine = seglen(b)
    local seen = {[key(b)]=true}
    local function step(cur, way)
      local list = try(function() return cur.belt_neighbours[way] end) or {}
      local nxt
      if #list == 1 then nxt = list[1]
      elseif way == 'inputs' then
        for _, x in ipairs(list) do if x.direction ~= nil and x.direction == cur.direction then nxt = x end end
      end
      if not nxt and cur.type == 'underground-belt' then
        local pair = try(function() return cur.neighbours end)
        local t = try(function() return cur.belt_to_ground_type end)
        if pair and pair.valid and ((way == 'inputs' and t == 'output') or (way == 'outputs' and t == 'input')) then nxt = pair end
      end
      if not nxt or nxt.type == 'splitter' or seen[key(nxt)] then return nil end
      if mine and math.abs((seglen(nxt) or -1) - mine) > 0.001 then return nil end
      seen[key(nxt)] = true
      return nxt
    end
    local up, cur = {}, b
    for _ = 1, SEG do cur = step(cur, 'inputs'); if not cur then break end; up[#up+1] = cur end
    local list = {}
    for i = #up, 1, -1 do list[#list+1] = up[i] end
    list[#list+1] = b
    local at_i = #list
    cur = b
    for _ = 1, SEG do cur = step(cur, 'outputs'); if not cur then break end; list[#list+1] = cur end
    return list, at_i
  end
  local function connectors(e)
    local W = defines.wire_connector_id
    local out = {}
    for _, id in ipairs({W.circuit_red, W.circuit_green, W.combinator_input_red, W.combinator_input_green, W.combinator_output_red, W.combinator_output_green}) do
      local c = id and try(function() return e.get_wire_connector(id, false) end)
      if c then out[#out+1] = {c=c, id=id} end
    end
    return out
  end
  local function side(e, id)
    local W = defines.wire_connector_id
    if id == W.combinator_output_red or id == W.combinator_output_green then return 'output' end
    if id == W.combinator_input_red or id == W.combinator_input_green then return 'input' end
  end
  -- every entity connector on the network a connector is on (wires of players only)
  local function members(conn)
    local net = try(function() return conn.owner.get_circuit_network(conn.wire_connector_id) end)
    local id = net and try(function() return net.network_id end)
    if id and memo.members and memo.members[id] then return memo.members[id] end
    local seen, queue, out, i = {}, {conn}, {}, 1
    local origin = defines.wire_origin and defines.wire_origin.player
    while i <= #queue and #out < NET_CONNS do
      local c = queue[i]; i = i + 1
      local k = tostring(try(function() return c.owner.unit_number end)) .. ':' .. tostring(c.wire_connector_id)
      if not seen[k] then
        seen[k] = true
        out[#out+1] = c
        for _, w in pairs(try(function() return c.connections end) or {}) do
          if w.target and (w.origin == nil or w.origin == origin) then queue[#queue+1] = w.target end
        end
      end
    end
    if id and memo.members then memo.members[id] = out end
    return out
  end
  -- a memo for the feeders of one read (cleared after)
  function M.feeders_begin(budget) memo = {contents={}, cover={}, members={}, walked=0, budget=budget} end
  function M.feeders_end() memo = {} end
  -- a signal's name, with @quality when not normal (d22 batch87 AW1: an uncommon signal read as the normal one)
  local function sigtext(s) local q = s.quality; if q and type(q) ~= 'string' then q = q.name end; return q and q ~= 'normal' and s.name .. '@' .. q or s.name end
  local function net_of(c) return try(function() return c.owner.get_circuit_network(c.wire_connector_id) end) end
  local function signals_text(net, limit)
    local sigs = try(function() return net.signals end) or {}
    table.sort(sigs, function(x, y) return math.abs(x.count) > math.abs(y.count) end)
    local parts = {}
    for i, sg in ipairs(sigs) do if i <= (limit or 6) and sg.signal then parts[#parts+1] = sigtext(sg.signal) .. ' ' .. sg.count end end
    return #parts > 0 and table.concat(parts, ', ') .. (#sigs > #parts and ', ...' or '') or 'no signal'
  end
  function M.feeder(ins)
    local cb = try(function() return ins.get_control_behavior() end)
    local sets = cb and try(function() return cb.circuit_set_filters end)
    local gate = cb and try(function() return cb.circuit_enable_disable end)
    if not (sets or gate) then return nil end
    -- what it takes: its filters now and its condition's signal
    local items, names = {}, {}
    for i = 1, try(function() return ins.filter_slot_count end) or 0 do
      local f = try(function() return ins.get_filter(i) end)
      local n = f and (type(f) == 'string' and f or type(f.name) == 'string' and f.name or try(function() return f.name.name end))
      if n and not items[n] then items[n] = true; names[#names+1] = n end
    end
    local cond = gate and try(function() return cb.circuit_condition end)
    local cs = cond and cond.first_signal and cond.first_signal.name
    if cs and prototypes and prototypes.item and prototypes.item[cs] and not items[cs] then items[cs] = true; names[#names+1] = cs end
    local pick = try(function() return ins.pickup_target end)
    local fmode = sets and try(function() return ins.inserter_filter_mode end)
    local head = string.format('%s %s: %s%s; picks up from %s', ins.name, at(ins.position),
      sets and 'its filters set by the circuit (' .. tostring(fmode or 'whitelist') .. ', now ' .. (#names > 0 and table.concat(names, ', ') or 'none') .. ')' or '',
      gate and ((sets and ', ' or '') .. 'on while ' .. (api.condition_text and cond and try(function() return api.condition_text(cond) end) or 'its circuit condition holds')) or '',
      pick and pick.valid and string.format('%s %s', pick.name, at(pick.position)) or 'nothing')
    local parts, readers, seen_net = {}, {}, {}
    -- at most SOURCES combinators and SOURCES readers a feeder (circuits.short is about 0.4 ms an entity on world n: a
    -- hub network's 25 members ran 70 ms for one inserter in batch37's first version)
    local ncomb, nread = 0, 0
    local row = {name=ins.name, position={x=ins.position.x, y=ins.position.y}, filters=names, set_filters=sets or nil, gated=gate or nil,
      mode=sets and try(function() return ins.inserter_filter_mode end) or nil, pickup=pick and pick.valid and {name=pick.name, position=pick.position} or nil, readers={}}
    local function walk(conn, label, depth)
      local net = net_of(conn)
      local id = net and try(function() return net.network_id end)
      if not id or seen_net[id] then return end
      seen_net[id] = true
      parts[#parts+1] = string.format('%s #%d: %s', label, id, signals_text(net))
      for _, c in ipairs(members(conn)) do
        local o = c.owner
        if o and o.valid and o ~= ins then
          local sd = side(o, c.wire_connector_id)
          if (o.type == 'arithmetic-combinator' or o.type == 'decider-combinator' or o.type == 'selector-combinator') and sd == 'output' and depth < FEED_DEPTH and ncomb < SOURCES then
            ncomb = ncomb + 1
            local set = api.circuit_short and try(function() return api.circuit_short(o) end)
            parts[#parts+1] = string.format('  put out by %s %s%s', o.name, at(o.position), set and ' (' .. set .. ')' or '')
            local W = defines.wire_connector_id
            for _, w in ipairs({W.combinator_input_red, W.combinator_input_green}) do
              local ic = try(function() return o.get_wire_connector(w, false) end)
              if ic then walk(ic, '    its ' .. (w == W.combinator_input_red and 'red' or 'green') .. ' input', depth + 1) end
            end
          elseif o.type == 'constant-combinator' and ncomb < SOURCES then
            ncomb = ncomb + 1
            local set = api.circuit_short and try(function() return api.circuit_short(o) end)
            parts[#parts+1] = string.format('  constant-combinator %s%s', at(o.position), set and ' (' .. set .. ')' or '')
          elseif o.type == 'space-platform-hub' then
            local ocb = try(function() return o.get_control_behavior() end)
            if ocb and try(function() return ocb.read_contents end) then
              local held = {}
              for _, n in ipairs(names) do held[#held+1] = n .. ' ' .. (try(function() return o.get_item_count(n) end) or 0) end
              parts[#parts+1] = string.format('  the hub %s reads its contents onto it%s (its own signal, apart from any belt read)', at(o.position),
                #held > 0 and ': ' .. table.concat(held, ', ') or '')
            end
          elseif o.type == 'transport-belt' or o.type == 'underground-belt' or o.type == 'splitter' then
            local ocb = try(function() return o.get_control_behavior() end)
            if ocb and try(function() return ocb.read_contents end) and not readers[key(o)] and nread < SOURCES then
              readers[key(o)] = true; nread = nread + 1
              local m = mode_name(try(function() return ocb.read_contents_mode end))
              local line, r = M.reader_line(o, m, names, pick)
              parts[#parts+1] = '  ' .. line
              row.readers[#row.readers+1] = r
            end
          end
        end
      end
    end
    local W = defines.wire_connector_id
    for _, w in ipairs({W.circuit_red, W.circuit_green}) do
      local c = try(function() return ins.get_wire_connector(w, false) end)
      if c then walk(c, w == W.circuit_red and 'red' or 'green', 1) end
    end
    row.line = head .. '; ' .. table.concat(parts, '; ')
    return row.line, row
  end
  -- One belt reader: its mode, the belts its count covers, what that count holds of the items, the belts past the
  -- feeder's pickup, and side-loads joining inside the count.
  function M.reader_line(b, mode, names, pick)
    local list, at_i = covered(b, mode)
    if not list then
      return string.format('%s %s reads %s (not walked: this read walked %d belts already; circuit_audit {platform, inserter: {x, y}} reads one feeder)', b.name, at(b.position),
        mode == 'entire_belt_hold' and 'its whole belt' or mode, memo.walked or 0), {position=b.position, mode=mode, walked=false}
    end
    local r = {position={x=b.position.x, y=b.position.y}, mode=mode}
    local idx = {}
    for i, x in ipairs(list) do idx[key(x)] = i end
    local what = {}
    for _, n in ipairs(#names > 0 and names or {}) do
      local c = 0
      for _, x in ipairs(list) do c = c + lane_count(x, n) end
      what[#what+1] = n .. ' ' .. c
    end
    local text = string.format('%s %s reads %s: its count covers %d belt%s%s%s', b.name, at(b.position),
      mode == 'entire_belt_hold' and 'its whole belt' or mode == 'hold' and 'its own belt (hold)' or mode == 'pulse' and 'its own belt as pulses' or mode,
      #list, #list == 1 and '' or 's', #list > 1 and string.format(' from %s to %s (the game\'s segment, in flow order)', at(list[1].position), at(list[#list].position)) or '',
      #what > 0 and ', holding ' .. table.concat(what, ', ') .. ' now' or '')
    -- past the pickup: belts of the count downstream of the feeder's pickup belt
    local pk = pick and pick.valid and idx[key(pick)]
    if pk and pk < #list then
      local past = {}
      for _, n in ipairs(names) do
        local c = 0
        for i = pk + 1, #list do c = c + lane_count(list[i], n) end
        past[#past+1] = n .. ' ' .. c
      end
      text = text .. string.format('; %d of those belts lie past the inserter\'s pickup %s, from %s to %s: it cannot take what they hold%s', #list - pk, at(pick.position),
        at(list[pk + 1].position), at(list[#list].position), #past > 0 and ' (' .. table.concat(past, ', ') .. ' now)' or '')
    elseif pick and pick.valid and not pk then
      text = text .. string.format('; the inserter\'s pickup %s is not among them', at(pick.position))
    end
    -- side-loads into belts of the count from belts outside it
    local joins = {}
    for _, x in ipairs(list) do
      for _, inb in ipairs(try(function() return x.belt_neighbours.inputs end) or {}) do
        if not idx[key(inb)] and #joins < 3 then
          joins[#joins+1] = string.format('%s %s into %s%s', inb.name, at(inb.position), at(x.position), pk and idx[key(x)] <= pk and ' (upstream of the pickup)' or '')
        end
      end
    end
    if #joins > 0 then text = text .. '; belts joining inside the count (their items count in it): ' .. table.concat(joins, ', ') end
    r.belts, r.from, r.to = #list, list[1].position, list[#list].position
    r.holds = #what > 0 and table.concat(what, ', ') or nil
    r.past_pickup = pk and pk < #list and #list - pk or nil
    r.joins = #joins > 0 and joins or nil
    return text, r
  end
  function M.read(p, a)
    if a.area ~= nil or a.positions ~= nil then return M.networks_read(p, a) end
    local pl = api.platform(p, a.platform)
    local s = pl.surface
    assert(s, 'platform ' .. pl.name .. ' has no surface yet')
    MODE = MODE or (defines.control_behavior and defines.control_behavior.transport_belt and defines.control_behavior.transport_belt.content_read_mode.entire_belt_hold)
    local lines, readers = {}, {}
    for _, b in ipairs(s.find_entities_filtered{type={'transport-belt', 'underground-belt', 'splitter'}, force=pl.force}) do
      if #readers >= MAX_READERS then break end
      local cb = try(function() return b.get_control_behavior() end)
      if cb and try(function() return cb.read_contents end) and try(function() return cb.read_contents_mode end) == MODE then
        local nets = networks(b)
        if #nets > 0 then
          local set, n, ways = whole(b)
          readers[#readers+1] = {e=b, nets=nets, set=set, n=n, out=left_out(b, ways)}
        end
      end
    end
    local doubles = {}
    for i = 1, #readers do
      for j = i + 1, #readers do
        local x, y = readers[i], readers[j]
        local shared = 0
        for k in pairs(x.set) do if y.set[k] then shared = shared + 1 end end
        if shared > 0 then
          for _, nx in ipairs(x.nets) do
            for _, ny in ipairs(y.nets) do
              if nx.id == ny.id then
                doubles[#doubles+1] = string.format('%s %s and %s %s both read the whole belt (%d tiles shared) onto %s network #%d: those items reach it twice',
                  x.e.name, at(x.e.position), y.e.name, at(y.e.position), shared, nx.color, nx.id)
              end
            end
          end
        end
      end
    end
    local short = {}
    for _, r in ipairs(readers) do
      if r.out then
        local parts, names = {}, {}
        for _, x in ipairs(r.out.runs) do
          parts[#parts+1] = string.format('%d belt%s %s from %s to %s', x.belts, x.belts == 1 and '' or 's', x.side, at(x.from), at(x.to))
        end
        for _, nt in ipairs(r.nets) do names[#names+1] = nt.color .. ' #' .. nt.id end
        short[#short+1] = {position=r.e.position, segment_tiles=math.floor(r.out.seg * 100 + 0.5) / 100, physical_belts=r.n, left_out=r.out.runs}
        lines[#lines+1] = string.format('%s %s reads its whole belt onto %s, and the game counts only its belt segment (%g tiles, %d of the %d belts in line); left out of the read: %s; what they carry never reaches the network',
          r.e.name, at(r.e.position), table.concat(names, ' and '), math.floor(r.out.seg * 100 + 0.5) / 100, r.n - r.out.n, r.n, table.concat(parts, '; '))
      end
    end
    for i, d in ipairs(doubles) do if i <= 12 then lines[#lines+1] = d end end
    if #doubles > 12 then lines[#lines+1] = string.format('+%d more pairs', #doubles - 12) end
    lines[#lines+1] = string.format('%d belt%s read their whole belt onto a network; %d pair%s on one network share tiles', #readers, #readers == 1 and '' or 's',
      #doubles, #doubles == 1 and '' or 's')
    -- collectors whose filters the circuit sets
    local cols = {}
    for _, c in ipairs(s.find_entities_filtered{type='asteroid-collector', force=pl.force, limit=64}) do
      local cb = try(function() return c.get_control_behavior() end)
      if cb and try(function() return cb.set_filter end) then
        local now = {}
        for i = 1, try(function() return c.filter_slot_count end) or 0 do
          local f = try(function() return c.get_filter(i) end)
          local name = f and (type(f) == 'string' and f or f.name)
          if name then now[#now+1] = name end
        end
        local sig, pos = {}, {}
        for _, n in ipairs(networks(c)) do
          for _, sg in ipairs(try(function() return n.net.signals end) or {}) do
            local name = sg.signal and sg.signal.name
            if name and name:find('asteroid%-chunk$') then
              sig[#sig+1] = string.format('%s %+d (%s #%d)', name, sg.count, n.color, n.id)
              if sg.count > 0 then pos[#pos+1] = name end
            end
          end
        end
        local row = {position=c.position, filters=now, chunk_signals=sig}
        cols[#cols+1] = row
        lines[#lines+1] = string.format('asteroid-collector %s, filters set by the circuit: holds %s now; chunk signals on its networks: %s%s', at(c.position),
          #now > 0 and table.concat(now, ', ') or 'no filter', #sig > 0 and table.concat(sig, ', ') or 'none',
          #pos == 0 and ' (none positive: only a positive chunk signal sets a filter)' or '')
      end
    end
    -- the feeders the circuit gates (D1, D2)
    local feeders = {}
    M.feeders_begin(a.inserter ~= nil and ONE_BUDGET or nil)
    local ins_list
    if a.inserter ~= nil then
      local q = a.inserter
      local x, y = type(q) == 'table' and tonumber(q.x or q[1]), type(q) == 'table' and tonumber(q.y or q[2])
      assert(x and y, 'inserter is {x, y}: the feeder to read')
      ins_list = s.find_entities_filtered{type='inserter', force=pl.force, position={x, y}, radius=0.6, limit=1}
      assert(#ins_list > 0, string.format('no inserter of ours at (%g,%g) on %s', x, y, pl.name))
    end
    local feeder_rows = {}
    for _, ins in ipairs(ins_list or s.find_entities_filtered{type={'inserter', 'loader', 'loader-1x1'}, force=pl.force, limit=1024}) do
      if #feeders >= FEEDERS then break end
      local ok, line, row = pcall(M.feeder, ins)
      if ok and line then feeders[#feeders+1] = line; feeder_rows[#feeder_rows+1] = row; lines[#lines+1] = line end
    end
    if #feeders >= FEEDERS and a.inserter == nil then
      lines[#lines+1] = string.format('the first %d inserters the circuit sets are read; circuit_audit {platform, inserter: {x, y}} reads any one', FEEDERS)
    end
    M.feeders_end()
    return {platform=pl.name, lines=lines, belt_readers=#readers, double_counts=#doubles > 0 and doubles or nil, short_reads=#short > 0 and short or nil,
      collectors=#cols > 0 and cols or nil, feeders=#feeders > 0 and feeders or nil, feeder_rows=#feeder_rows > 0 and feeder_rows or nil}
  end
  M.schema = {circuit_audit = {surface='optional planet, surface or platform name (default yours): with area or positions: the networks of our entities there; one out of sight now (no radar coverage) is not read, said as out_of_sight there by remote view (d20 batch62 X4)',platform='platform name (with area or positions: optional, else your surface)',inserter='optional {x, y}, with platform: that one feeder\'s circuit read (feeders)',area='optional {left_top, right_bottom} up to 128x128: read the networks of the entities in it',positions='optional 1..64 {x, y}: read the networks of the entities there',
    returns='lines: belts reading their entire belt onto a circuit network, and each pair on one network whose whole belts share tiles (those items reach the network twice); each such reader whose belt segment (what the game reads) is shorter than the belt in line through it, across undergrounds: the belts left out of the read, upstream and downstream (short_reads [{position, segment_tiles, physical_belts, left_out [{side, from, to, belts}]}]); each asteroid collector whose filters the circuit sets: the filter it holds now and the chunk signals on its networks with their values (only a positive one sets a filter). double_counts, collectors [{position, filters, chunk_signals}]; feeders (lines) and feeder_rows [{name, position, filters, set_filters, gated, mode, pickup, readers [{position, mode, belts, from, to, holds, past_pickup, joins}], line}]: each inserter or loader whose filters the circuit sets or which it turns on and off, on the platform or among the entities of area or positions (the first 8; inserter: one): what it takes now, its pickup, the signals on its networks, the combinators putting out onto them and the networks those read (3 deep), constant combinators, the hub\'s own read apart, and each belt reader on them: its read mode, the belts its count covers (whole belt: the game\'s segment, in flow order), what it holds now of what the inserter takes, the belts of it past the inserter\'s pickup (it cannot take those) and side-loads joining inside the count (a read walks at most 160 belts, 400 for one inserter; a reader past that is named, not walked). With area or positions instead: each red and green network one of those entities is on, by id: networks [{id, color, signals (largest first, 24; signals_total), entities (those of the set on it), connected_entities (all on it)}], and a line each: its signals now and the entities of the set on it with their circuit settings. Read only'}}
  return M
end
