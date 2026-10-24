-- power {by_cause: true, surface?} (C1, Opus 22:50: "roboports took 55 of 81 MW and I had to guess why"): each electric
-- network on the surface ranked by what draws, as the electric network GUI's consumption list shows it (by entity name,
-- the last 5 s), against what it makes; and when roboports draw, what drives robot charging: per logistic network the
-- robots flying, charging and waiting to charge, what one flying robot draws (its speed with our speed research, times
-- its energy a tile moved, plus its energy a tick), so what the flying ones draw in all, their trips (a sample: the
-- tiles from each robot through its orders, and where they go: requesters, storage, providers), and the requesters
-- with the most on its way. Read only; bounded: 16 networks, 400 robots sampled, 2000 requester points, 400 cells.
local qflow = require('qflow')   -- (d24 batch152 PX1) statistics read at every quality
return function(api)
  local M = {}
  local NETS, SAMPLE, POINTS, CELLS, TOP = 16, 400, 2000, 400, 8
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function at(q) return string.format('(%d,%d)', math.floor(q.x + 0.5), math.floor(q.y + 0.5)) end
  local function mw(kw) return kw >= 1000 and string.format('%.1f MW', kw / 1000) or string.format('%d kW', math.floor(kw + 0.5)) end
  local function dist(a, b) return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2) end
  local function name_of(v) return type(v) == 'string' and v or try(function() return v.name end) end
  -- One pole per electric network on the surface: the background map, else a bounded find.
  local function networks(surface, force)
    local out, seen = {}, {}
    for id, m in pairs(api.pole_map and api.pole_map() or {}) do
      if m.surface == surface.name and m.force == force.name and m.pole and m.pole.valid then
        out[#out+1] = {id=id, pole=m.pole, poles=m.poles, center=m.poles > 0 and {x=m.sx / m.poles, y=m.sy / m.poles} or m.pole.position}
        seen[id] = true
      end
    end
    if #out == 0 then
      for _, e in ipairs(try(function() return surface.find_entities_filtered{type='electric-pole', force=force, limit=4000} end) or {}) do
        local id = try(function() return e.electric_network_id end)
        if id and not seen[id] then seen[id] = true; out[#out+1] = {id=id, pole=e, center=e.position} end
      end
    end
    return out
  end
  -- (d24 batch152 PX1) each name over every quality, a row for each quality with any (quality: nil for normal)
  local function flows(stats, category, counts)
    local by, total = {}, 0
    for name, all in pairs(counts or {}) do
      local ok, t, qs = pcall(qflow.flow_by, stats, name, category, defines.flow_precision_index.five_seconds, nil, all)
      for _, r in ipairs(ok and (qs or {{quality='normal', n=t}}) or {}) do
        if r.n > 0 then
          local kw = r.n * 60 / 1000
          by[#by+1] = {name=name, quality=r.quality ~= 'normal' and r.quality or nil, kw=kw}; total = total + kw
        end
      end
    end
    table.sort(by, function(x, y) return x.kw > y.kw end)
    return by, total
  end
  -- What one flying robot of this kind draws: speed (tiles a tick, our research) x energy a tile, + energy a tick.
  local function robot_kw(name, force)
    local proto = prototypes.entity[name]
    if not proto then return nil end
    local speed = (try(function() return proto.speed end) or 0) * (1 + (try(function() return force.worker_robots_speed_modifier end) or 0))
    local per_move = try(function() return proto.energy_per_move end) or 0
    local per_tick = try(function() return proto.energy_per_tick end) or 0
    return (speed * 60 * per_move + per_tick * 60) / 1000, speed * 60
  end
  local KIND = {[defines.logistic_mode and defines.logistic_mode.requester or -1]='requesters', [defines.logistic_mode and defines.logistic_mode.buffer or -2]='buffers',
    [defines.logistic_mode and defines.logistic_mode.storage or -3]='storage', [defines.logistic_mode and defines.logistic_mode.passive_provider or -4]='providers',
    [defines.logistic_mode and defines.logistic_mode.active_provider or -5]='providers'}
  local function where_to(e)
    if not (e and e.valid) then return 'elsewhere' end
    if e.type == 'logistic-container' then
      local mode = try(function() return e.get_logistic_point(defines.logistic_member_index.logistic_container).mode end)
      return KIND[mode] or 'chests'
    end
    if e.type == 'character' then return 'characters' end
    if e.type == 'roboport' then return 'roboports' end
    return e.type
  end
  function M.robots(surface, force)
    local lines, rows = {}, {}
    local lk, lspeed = robot_kw('logistic-robot', force)
    local ck = robot_kw('construction-robot', force)
    for _, ln in pairs(try(function() return force.logistic_networks[surface.name] end) or {}) do
      local cells = try(function() return ln.cells end) or {}
      local all, idle = ln.all_logistic_robots or 0, ln.available_logistic_robots or 0
      local call, cidle = ln.all_construction_robots or 0, ln.available_construction_robots or 0
      -- (a network with no robot draws nothing for them)
      if #cells > 0 and #rows < NETS and all + call > 0 then
        local charging, waiting = 0, 0
        for i, c in ipairs(cells) do
          if i > CELLS then break end
          charging = charging + #(try(function() return c.charging_robots end) or {})
          waiting = waiting + #(try(function() return c.to_charge_robots end) or {})
        end
        local flying = try(function() return ln.logistic_robots end) or {}
        -- trips: a sample of the robots out of their roboports
        local n, sum, long, to = 0, 0, 0, {}
        for i, r in ipairs(flying) do
          if i > SAMPLE then break end
          local q = r.valid and try(function() return r.robot_order_queue end)
          if q and #q > 0 then
            local from, d = r.position, 0
            for _, o in ipairs(q) do
              local t = o.target
              if t and t.valid then d = d + dist(from, t.position); from = t.position end
            end
            local last = q[#q].target
            local k = where_to(last)
            to[k] = (to[k] or 0) + 1
            n, sum, long = n + 1, sum + d, math.max(long, d)
          end
        end
        local kinds = {}
        for k, c in pairs(to) do kinds[#kinds+1] = {k=k, c=c} end
        table.sort(kinds, function(x, y) return x.c > y.c end)
        local kt = {}
        for i, k in ipairs(kinds) do if i <= 4 then kt[i] = string.format('%d%% to %s', math.floor(k.c / math.max(1, n) * 100 + 0.5), k.k) end end
        -- the requesters with the most on its way
        local tops = {}
        for i, pt in ipairs(try(function() return ln.requester_points end) or {}) do
          if i > POINTS then break end
          local coming, what = 0, {}
          for _, c in ipairs(try(function() return pt.targeted_items_deliver end) or {}) do
            coming = coming + (c.count or 0)
            local nm = name_of(c.name)
            if nm then what[nm] = (what[nm] or 0) + (c.count or 0) end
          end
          local owner = coming > 0 and try(function() return pt.owner end)
          if owner and owner.valid then tops[#tops+1] = {owner=owner, coming=coming, what=what} end
        end
        table.sort(tops, function(x, y) return x.coming > y.coming end)
        local tt = {}
        for i, t in ipairs(tops) do
          if i > 3 then break end
          local w = {}
          for nm, c in pairs(t.what) do w[#w+1] = nm .. ' ' .. c end
          table.sort(w)
          tt[i] = string.format('%s %s: %d coming (%s)', t.owner.name, at(t.owner.position), t.coming, table.concat(w, ', ', 1, math.min(#w, 3)))
        end
        local busy, cbusy = #flying, math.max(0, call - cidle)
        local est = (lk or 0) * busy + (ck or 0) * cbusy
        local cell = cells[1] and cells[1].owner
        local row = {network=ln.network_id, roboports=#cells, near=cell and cell.valid and at(cell.position) or nil,
          logistic_robots=all, idle=idle, flying=busy, construction_robots=call, construction_busy=cbusy, charging=charging, waiting_to_charge=waiting,
          robot_kw=lk and math.floor(lk * 10 + 0.5) / 10 or nil, flying_kw=math.floor(est + 0.5),
          trip_mean=n > 0 and math.floor(sum / n + 0.5) or nil, trip_max=n > 0 and math.floor(long + 0.5) or nil, sampled=n, to=#kt > 0 and kt or nil,
          most_coming=#tt > 0 and tt or nil}
        rows[#rows+1] = row
        lines[#lines+1] = string.format('logistic network %d (%d roboports, near %s): %d logistic robots, %d flying, %d idle; %d construction robots, %d busy; %d charging, %d waiting to charge. A flying logistic robot draws about %s (%.2f tiles/s with our speed research); the flying ones about %s in all%s%s%s',
          row.network, row.roboports, row.near or '?', all, busy, idle, call, cbusy, charging, waiting, lk and mw(lk) or '?', lspeed or 0, mw(est),
          n > 0 and string.format('; trips (%d sampled): %d tiles on average, the longest %d, %s', n, row.trip_mean, row.trip_max, table.concat(kt, ', ')) or '',
          #tt > 0 and '; most on its way to: ' .. table.concat(tt, '; ') or '', '')
      end
    end
    return rows, lines
  end
  function M.read(p, a)
    local surface = p.surface
    if a.surface ~= nil then
      assert(type(a.surface) == 'string' and game.get_surface(a.surface), 'surface must be a surface name')
      surface = game.get_surface(a.surface)
    end
    local force = p.force
    local nets, lines, roboports = {}, {}, false
    for _, n in ipairs(networks(surface, force)) do
      local stats = try(function() return n.pole.electric_network_statistics end)
      if stats then
        local use, total = flows(stats, 'input', try(function() return stats.input_counts end))
        local _, made = flows(stats, 'output', try(function() return stats.output_counts end))
        if total > 0 or made > 0 then nets[#nets+1] = {id=n.id, poles=n.poles, center=n.center, use=use, total=total, made=made} end
      end
    end
    table.sort(nets, function(x, y) return x.total > y.total end)
    local rows = {}
    for i, n in ipairs(nets) do
      if i > NETS then break end
      local parts, top = {}, {}
      for j, u in ipairs(n.use) do
        if j <= TOP then
          parts[#parts+1] = string.format('%s%s %s (%d%%)', u.name, u.quality and ' (' .. u.quality .. ')' or '', mw(u.kw), math.floor(u.kw / math.max(n.total, 1e-9) * 100 + 0.5))
          top[#top+1] = {name=u.name, quality=u.quality, kw=math.floor(u.kw + 0.5), share=math.floor(u.kw / math.max(n.total, 1e-9) * 100 + 0.5)}
        end
        if u.name == 'roboport' then roboports = true end
      end
      rows[#rows+1] = {network=n.id, poles=n.poles, center=n.center and at(n.center) or nil, draw_kw=math.floor(n.total + 0.5), made_kw=math.floor(n.made + 0.5), by_cause=top}
      lines[#lines+1] = string.format('electric network %d%s: draws %s, made %s (last 5 s): %s%s', n.id, n.center and ' near ' .. at(n.center) or '', mw(n.total), mw(n.made),
        table.concat(parts, ', '), #n.use > TOP and string.format(', +%d more', #n.use - TOP) or '')
    end
    local out = {surface=surface.name, networks=rows, lines=#lines > 0 and lines or {'no electric network of ours with a draw on ' .. surface.name}}
    if roboports or a.robots == true then
      local robots, rl = M.robots(surface, force)
      out.robots = #robots > 0 and robots or nil
      for _, l in ipairs(rl) do lines[#lines+1] = l end
      out.note = 'roboport draw is mostly robot charging: a robot spends its energy a tile it flies and a tick it is out, and charges at a roboport (its own drain too); the flying robots\' figure is an estimate from their prototypes and our speed research'
    end
    return out
  end
  return M
end
