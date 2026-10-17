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
  -- The whole belt through e: {set, n}
  local function whole(e)
    local set, n = {[key(e)]=true}, 1
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
        set[key(nxt)] = true; n = n + 1
        cur = nxt; steps = steps + 1
      end
    end
    return set, n
  end
  local MODE
  function M.read(p, a)
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
          local set, n = whole(b)
          readers[#readers+1] = {e=b, nets=nets, set=set, n=n}
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
    return {platform=pl.name, lines=lines, belt_readers=#readers, double_counts=#doubles > 0 and doubles or nil, collectors=#cols > 0 and cols or nil}
  end
  M.schema = {circuit_audit = {platform='platform name',
    returns='lines: belts reading their entire belt onto a circuit network, and each pair on one network whose whole belts share tiles (those items reach the network twice); each asteroid collector whose filters the circuit sets: the filter it holds now and the chunk signals on its networks with their values (only a positive one sets a filter). double_counts, collectors [{position, filters, chunk_signals}]. Read only'}}
  return M
end
