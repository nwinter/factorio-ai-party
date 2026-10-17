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
    local s, force, where = p.surface, p.force, 'your surface'
    if a.platform ~= nil then
      local pl = api.platform(p, a.platform)
      s, force, where = pl.surface, pl.force, 'platform ' .. pl.name
      assert(s, 'platform ' .. pl.name .. ' has no surface yet')
    end
    local list, seen = {}, {}
    local function add(e) if e.valid and not seen[key(e)] and #list < ENTITIES then seen[key(e)] = true; list[#list+1] = e end end
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
    return {where=where, entities=#list, networks=rows, lines=lines}
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
    return {platform=pl.name, lines=lines, belt_readers=#readers, double_counts=#doubles > 0 and doubles or nil, short_reads=#short > 0 and short or nil,
      collectors=#cols > 0 and cols or nil}
  end
  M.schema = {circuit_audit = {platform='platform name (with area or positions: optional, else your surface)',area='optional {left_top, right_bottom} up to 128x128: read the networks of the entities in it',positions='optional 1..64 {x, y}: read the networks of the entities there',
    returns='lines: belts reading their entire belt onto a circuit network, and each pair on one network whose whole belts share tiles (those items reach the network twice); each such reader whose belt segment (what the game reads) is shorter than the belt in line through it, across undergrounds: the belts left out of the read, upstream and downstream (short_reads [{position, segment_tiles, physical_belts, left_out [{side, from, to, belts}]}]); each asteroid collector whose filters the circuit sets: the filter it holds now and the chunk signals on its networks with their values (only a positive one sets a filter). double_counts, collectors [{position, filters, chunk_signals}]. With area or positions instead: each red and green network one of those entities is on, by id: networks [{id, color, signals (largest first, 24; signals_total), entities (those of the set on it), connected_entities (all on it)}], and a line each: its signals now and the entities of the set on it with their circuit settings. Read only'}}
  return M
end
