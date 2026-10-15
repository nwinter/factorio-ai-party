-- powercut: an alert when the death of one of our electric poles splits its electric network, or leaves machines
-- that no other pole reaches (round2120a, Opus, shift14: "a single small pole at (78.5,-182.5) silently cut 20 drills
-- plus the uranium line twice, found only by tracing"). What a player sees: the network's power graph, the machines'
-- no-power icons, the wires on the map.
-- On the death (runtime.lua on_entity_died, the pole still there): its copper wire neighbours and the machines in its
-- supply area; every pole death is remembered a while, so the poles one raid kills next to each other are one gap,
-- and its ends are the live poles wired to any of them. CHECK ticks on (the game's networks updated, and a 5 s power window wholly after the death): the
-- neighbours' networks. Two or more: a split. Each part's power is its network's production over the last 5 s (the
-- network's statistics, as its GUI graph); a part without any is traced along copper wires (up to TRACE poles, STEP
-- a tick) and its machines counted from the traced poles' supply areas. The machines the pole alone reached have no
-- network at all. A cut nobody could act on (every part powered, or none holding a machine, and no machine left
-- alone) is no alert. One line per cut, told once to every agent in team.alerts (with whether it has joined again
-- since), and in status alerts.
return function(api)
  local M = {}
  local CHECK, TRACE, STEP, KEEP, FIRST, MAX_JOBS, MAX_CUTS, LINES, DEAD = 330, 600, 100, 36000, 18000, 16, 32, 3, 1800
  -- Entities that make power rather than use it (not counted as machines).
  local PRODUCERS = {generator=true, ['solar-panel']=true, accumulator=true, ['burner-generator']=true, ['electric-energy-interface']=true,
    ['fusion-generator']=true, ['lightning-attractor']=true, ['electric-pole']=true, ['power-switch']=true}
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function at(q) return string.format('(%g,%g)', math.floor(q.x * 10 + 0.5) / 10, math.floor(q.y * 10 + 0.5) / 10) end
  local function store()
    local s = api.state()
    s.powercut = s.powercut or {seq=0, jobs={}, cuts={}}
    return s.powercut
  end
  local function supply(pole)
    return try(function() return pole.prototype.get_supply_area_distance(pole.quality) end)
      or try(function() return pole.prototype.get_supply_area_distance() end) or try(function() return pole.prototype.supply_area_distance end) or 0
  end
  local function machine(e)
    return e.valid and not PRODUCERS[e.type] and try(function() return e.prototype.electric_energy_source_prototype end) ~= nil
  end
  local function copper(e) return try(function() return e.get_wire_connector(defines.wire_connector_id.pole_copper, false) end) end
  local function net(e) return try(function() return e.electric_network_id end) end

  -- The pole died: what it joined and what it reached (the engine's wires and networks still hold it).
  function M.on_died(e, by)
    if not (e and e.valid and e.type == 'electric-pole') then return end
    local st = store()
    local nbs = {}
    local con = copper(e)
    for _, c in ipairs(con and con.connections or {}) do
      local o = c.target and c.target.owner
      if o and o.valid and o ~= e and o.type == 'electric-pole' then nbs[#nbs+1] = {entity=o, unit=o.unit_number} end
    end
    local unit = e.unit_number
    st.dead = st.dead or {}
    for u, d in pairs(st.dead) do if game.tick - d.tick > DEAD then st.dead[u] = nil end end
    if unit then st.dead[unit] = {tick=game.tick, nbs=nbs, name=e.name, position=e.position} end
    if #st.jobs >= MAX_JOBS then return end
    local machines = {}
    local d = supply(e)
    if d > 0 then
      local q = e.position
      for _, m in ipairs(e.surface.find_entities_filtered{area={{q.x - d, q.y - d}, {q.x + d, q.y + d}}, force=e.force}) do
        if m ~= e and machine(m) then machines[#machines+1] = m end
      end
    end
    -- A pole with one wire or none splits nothing; with nothing in its area it leaves nothing alone.
    if #nbs < 2 and #machines == 0 then return end
    st.jobs[#st.jobs+1] = {tick=game.tick, name=e.name, position=e.position, surface=e.surface.name, force=e.force.name, net=net(e), by=by,
      unit=unit, neighbours=nbs, machines=machines}
  end

  -- A network's production over the last 5 s, in kW, by producer name (input is consumption in electric statistics).
  local function power(pole)
    local stats = pole.valid and try(function() return pole.electric_network_statistics end)
    if not stats then return 0, {} end
    local total, by = 0, {}
    for name in pairs(try(function() return stats.output_counts end) or {}) do
      local v = try(function() return stats.get_flow_count{name=name, category='output', precision_index=defines.flow_precision_index.five_seconds} end)
      local kw = (v or 0) * 60 / 1000
      if kw >= 0.5 then by[name] = kw; total = total + kw end
    end
    return total, by
  end
  local function grow(box, q)
    if not box.x0 then box.x0, box.y0, box.x1, box.y1 = q.x, q.y, q.x, q.y; return end
    box.x0, box.y0, box.x1, box.y1 = math.min(box.x0, q.x), math.min(box.y0, q.y), math.max(box.x1, q.x), math.max(box.y1, q.y)
  end
  -- Up to STEP poles of a part's trace: its poles along copper wires within its own network, and the machines of that
  -- network in their supply areas. True when the trace is done (or at TRACE poles).
  local function trace_step(part)
    local used = 0
    while part.head <= #part.queue and used < STEP do
      local pole = part.queue[part.head]; part.head = part.head + 1; used = used + 1
      if pole.valid then
        part.poles = part.poles + 1
        grow(part.box, pole.position)
        local d = supply(pole)
        if d > 0 then
          local q = pole.position
          for _, m in ipairs(pole.surface.find_entities_filtered{area={{q.x - d, q.y - d}, {q.x + d, q.y + d}}, force=pole.force}) do
            local u = m.valid and m.unit_number
            if u and not part.seen_m[u] and machine(m) and net(m) == part.id then
              part.seen_m[u] = true; part.machines[m.name] = (part.machines[m.name] or 0) + 1; part.total = part.total + 1
            end
          end
        end
        local con = copper(pole)
        for _, c in ipairs(con and con.connections or {}) do
          local o = c.target and c.target.owner
          local u = o and o.valid and o.type == 'electric-pole' and o.unit_number
          if u and not part.seen[u] and net(o) == part.id then part.seen[u] = true; part.queue[#part.queue+1] = o end
        end
        if part.poles >= TRACE then part.capped = true; return true end
      end
    end
    return part.head > #part.queue
  end
  local function counted(t, n)
    local list = {}
    for name, c in pairs(t or {}) do list[#list+1] = {name, c} end
    table.sort(list, function(a, b) return a[2] > b[2] or a[2] == b[2] and a[1] < b[1] end)
    local parts = {}
    for i, v in ipairs(list) do if i <= n then parts[i] = v[2] .. ' ' .. v[1] end end
    if #list > n then parts[#parts+1] = string.format('+%d more kinds', #list - n) end
    return table.concat(parts, ', ')
  end
  -- The check, CHECK ticks after the death: the parts and their power, then their traces (job.parts set).
  local function start(job)
    local orphans, obox, on, alone = {}, {}, 0, {}
    for _, m in ipairs(job.machines) do
      if m.valid and not net(m) then
        on = on + 1; orphans[m.name] = (orphans[m.name] or 0) + 1; grow(obox, m.position)
        if #alone < 8 then alone[#alone+1] = m end
      end
    end
    job.alone = alone
    -- The gap's ends: the live poles wired to this pole or to a pole that died next to it since.
    local st, ends, live, gone, queue, i = store(), {}, {}, {[job.unit or -1]=true}, {}, 1
    job.with = {}
    for _, n in ipairs(job.neighbours) do queue[#queue+1] = n end
    while i <= #queue and i <= 256 do
      local n = queue[i]; i = i + 1
      if n.entity.valid then
        if n.unit and not live[n.unit] then live[n.unit] = true; ends[#ends+1] = n.entity end
      elseif n.unit and not gone[n.unit] then
        gone[n.unit] = true
        local d = st.dead and st.dead[n.unit]
        if d then
          if #job.with < 4 then job.with[#job.with+1] = {name=d.name, position=d.position} end
          for _, m in ipairs(d.nbs) do queue[#queue+1] = m end
        end
      end
    end
    job.ends = ends
    local parts, seen = {}, {}
    for _, n in ipairs(ends) do
      local id = n.valid and net(n)
      if id and not seen[id] then
        seen[id] = true
        local kw, by = power(n)
        local u = n.unit_number
        parts[#parts+1] = {id=id, pole=n, kw=kw, by=by, cut=kw < 0.5, queue={n}, head=1, seen={[u or 0]=true}, seen_m={}, machines={}, total=0,
          poles=0, box={}}
      end
    end
    job.machines = nil
    job.orphans = on > 0 and orphans or nil; job.orphan_total = on; job.orphan_box = on > 0 and obox or nil
    job.parts = #parts >= 2 and parts or {}
    -- Each part with no power is traced; the powered ones only named.
    job.tracing = {}
    for _, part in ipairs(job.parts) do if part.cut then job.tracing[#job.tracing+1] = part end end
  end
  local function finish(job)
    local st = store()
    local cut_parts = {}
    for _, part in ipairs(job.parts) do
      part.queue, part.seen, part.seen_m, part.pole = nil, nil, nil, nil
      if part.cut and part.total > 0 then cut_parts[#cut_parts+1] = part end
    end
    if #cut_parts == 0 and (job.orphan_total or 0) == 0 then return end
    local poles = {{name=job.name, position=job.position, by=job.by}}
    for _, w in ipairs(job.with or {}) do poles[#poles+1] = w end
    -- The same cut seen from two poles of one raid: one alert, with every pole and the machines left alone.
    for _, c in ipairs(st.cuts) do
      if c.surface == job.surface and job.tick - c.tick <= 600 then
        for _, p1 in ipairs(c.parts) do
          for _, p2 in ipairs(cut_parts) do
            if p1.cut and p1.id == p2.id then
              for _, q in ipairs(poles) do
                local known = false
                for _, k in ipairs(c.poles) do if k.position.x == q.position.x and k.position.y == q.position.y then known = true end end
                if not known and #c.poles < 6 then c.poles[#c.poles+1] = q end
              end
              for name, n in pairs(job.orphans or {}) do
                c.orphans = c.orphans or {}; c.orphans[name] = (c.orphans[name] or 0) + n
              end
              if (job.orphan_total or 0) > 0 then
                c.orphan_total = (c.orphan_total or 0) + job.orphan_total
                c.orphan_box = c.orphan_box or {}
                grow(c.orphan_box, {x=job.orphan_box.x0, y=job.orphan_box.y0}); grow(c.orphan_box, {x=job.orphan_box.x1, y=job.orphan_box.y1})
                c.alone = c.alone or {}
                for _, m in ipairs(job.alone or {}) do if #c.alone < 8 then c.alone[#c.alone+1] = m end end
              end
              return
            end
          end
        end
      end
    end
    st.seq = st.seq + 1
    local ghost = false
    local surface = game.get_surface(job.surface)
    for _, g in ipairs(surface and try(function() return surface.find_entities_filtered{name='entity-ghost', position=job.position, radius=0.5} end) or {}) do
      if try(function() return g.ghost_name end) == job.name then ghost = true end
    end
    st.cuts[#st.cuts+1] = {id=st.seq, tick=job.tick, checked=game.tick, surface=job.surface, net=job.net, ghost=ghost,
      poles=poles, parts=job.parts, orphans=job.orphans, orphan_total=job.orphan_total,
      orphan_box=job.orphan_box, ends=#job.parts >= 2 and job.ends or nil, alone=job.orphan_total > 0 and job.alone or nil}
    while #st.cuts > MAX_CUTS do table.remove(st.cuts, 1) end
  end
  local function step(st, tick)
    local job = st.jobs[1]
    if not job.parts then
      if tick - job.tick < CHECK then return end
      start(job)
      job.neighbours = nil
      return
    end
    local part = job.tracing[1]
    if part then
      if trace_step(part) then table.remove(job.tracing, 1) end
      return
    end
    table.remove(st.jobs, 1)
    finish(job)
  end
  -- One stage a tick; a job that faults is dropped and counted (powercut.errors), never the tick.
  function M.tick(tick)
    local st = api.state().powercut
    if not st or #st.jobs == 0 then return end
    local ok, err = pcall(step, st, tick)
    if not ok then
      table.remove(st.jobs, 1)
      st.errors = {count=(st.errors and st.errors.count or 0) + 1, last=tostring(err), tick=tick}
    end
  end

  -- Whether the parts are one network again (the pole rebuilt, or a new wire) and the machines left alone have one.
  local function joined(c)
    local id
    for _, n in ipairs(c.ends or {}) do
      if n.valid then
        local now = net(n)
        if not now or (id and now ~= id) then return false end
        id = now
      end
    end
    for _, m in ipairs(c.alone or {}) do if m.valid and not net(m) then return false end end
    return true
  end
  local function ago(ticks)
    local s = math.floor(ticks / 60)
    if s >= 3600 then return string.format('%dh%02dm', math.floor(s / 3600), math.floor(s / 60) % 60) end
    if s >= 60 then return string.format('%dm%02ds', math.floor(s / 60), s % 60) end
    return s .. 's'
  end
  local function box_text(b)
    if not b or not b.x0 then return nil end
    if b.x1 - b.x0 < 1 and b.y1 - b.y0 < 1 then return string.format('around (%d,%d)', math.floor(b.x0), math.floor(b.y0)) end
    return string.format('(%d,%d)-(%d,%d)', math.floor(b.x0), math.floor(b.y0), math.floor(b.x1 + 0.5), math.floor(b.y1 + 0.5))
  end
  -- 'power cut #3: small-electric-pole (78.5,-182.5) destroyed by big-biter 6s ago split electric network #57 in 2:
  -- #212 has no power (31 poles, (60,-260)-(95,-185)): 20 electric-mining-drill, 6 inserter; #57 has power (5.2 MW)'.
  function M.line(c, reader)
    local first = c.poles[1]
    local head = string.format('power cut #%d%s: %s %s destroyed%s %s ago', c.id, c.surface ~= (reader or 'nauvis') and ' on ' .. c.surface or '',
      first.name, at(first.position), first.by and ' by ' .. first.by or '', ago(game.tick - c.tick))
    if #c.poles > 1 then
      local more = {}
      for i = 2, #c.poles do more[#more+1] = c.poles[i].name .. ' ' .. at(c.poles[i].position) end
      head = head .. ' (with ' .. table.concat(more, ', ') .. ')'
    end
    local parts = {}
    if #c.parts >= 2 then
      local bits = {}
      for _, part in ipairs(c.parts) do
        if part.cut then
          local where = box_text(part.box)
          bits[#bits+1] = string.format('#%d has no power (%s%d pole%s%s)%s', part.id, part.capped and 'over ' or '', part.poles, part.poles == 1 and '' or 's',
            where and ', ' .. where or '', part.total > 0 and ': ' .. counted(part.machines, 5) or ': no machines')
        else
          bits[#bits+1] = string.format('#%d has power (%s)', part.id, part.kw >= 1000 and string.format('%.1f MW', part.kw / 1000) or string.format('%d kW', math.floor(part.kw + 0.5)))
        end
      end
      parts[#parts+1] = string.format('split electric network #%s in %d: %s', tostring(c.net or '?'), #c.parts, table.concat(bits, '; '))
    end
    if (c.orphan_total or 0) > 0 then
      local where = box_text(c.orphan_box)
      parts[#parts+1] = string.format('%d machine%s no other pole reaches %s no power%s: %s', c.orphan_total, c.orphan_total == 1 and '' or 's',
        c.orphan_total == 1 and 'has' or 'have', where and ' ' .. where or '', counted(c.orphans, 5))
    end
    local now = joined(c) and 'joined again since (rebuilt or wired)' or (c.ghost and 'a ghost of the pole stands there' or 'no ghost of the pole there')
    return head .. ': ' .. table.concat(parts, '; ') .. '; ' .. now
  end
  -- team.alerts: each cut once to every agent; an agent's first reply looks back FIRST ticks.
  function M.lines(p, h)
    local st = api.state().powercut
    if not st or #st.cuts == 0 then return nil end
    local told = h.powercut_told
    local fresh = told == nil
    told = told or {}
    local out, kept = {}, {}
    for _, c in ipairs(st.cuts) do
      local age = game.tick - c.tick
      if told[c.id] then kept[c.id] = true
      elseif age <= KEEP and not (fresh and age > FIRST) then
        if #out < LINES then out[#out+1] = M.line(c, p.surface and p.surface.name); kept[c.id] = true end
      else kept[c.id] = true end
    end
    h.powercut_told = kept
    return #out > 0 and out or nil
  end
  -- status alerts: every cut after since.
  function M.since(since, reader)
    local st = api.state().powercut
    local out = {}
    for _, c in ipairs(st and st.cuts or {}) do if c.tick > since then out[#out+1] = M.line(c, reader) end end
    return #out > 0 and out or nil
  end

  -- A pole's wires, as the map draws them (scan and inspect, round2120a: Opus traced a break over 400 tiles): its
  -- copper neighbours and its red and green circuit neighbours, "name (x,y)", the first 8 of each.
  function M.wires(e)
    if not (e and e.valid) then return nil end
    local out = {}
    for key, id in pairs({copper=defines.wire_connector_id.pole_copper, red=defines.wire_connector_id.circuit_red, green=defines.wire_connector_id.circuit_green}) do
      local con = try(function() return e.get_wire_connector(id, false) end)
      local list, n = {}, 0
      for _, c in ipairs(con and try(function() return con.connections end) or {}) do
        local o = c.target and c.target.owner
        if o and o.valid and o ~= e then
          n = n + 1
          if n <= 8 then list[#list+1] = o.name .. ' ' .. at(o.position) end
        end
      end
      if n > 8 then list[#list+1] = string.format('+%d more', n - 8) end
      if n > 0 then out[key] = list end
    end
    return next(out) and out or nil
  end
  -- A scan row's short form: the copper neighbours' positions.
  function M.copper_line(e)
    local con = copper(e)
    local list = {}
    for _, c in ipairs(con and con.connections or {}) do
      local o = c.target and c.target.owner
      if o and o.valid and o ~= e then list[#list+1] = at(o.position) end
    end
    return #list > 0 and table.concat(list, ' ') or 'none'
  end
  return M
end
