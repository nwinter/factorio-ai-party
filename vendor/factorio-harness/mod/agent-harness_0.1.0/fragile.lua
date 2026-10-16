-- power {position, fragile: true}: the poles of one electric network whose loss alone would cut machines off from all
-- generation (Opus, d15 shifts 19-20: one small pole at (-72.5,-114.5) cut 142 poles of oil and drills; NW oil lost
-- its one link pole twice). What a player sees: the network's poles and copper wires on the map, the generators, and
-- which machines each pole's supply area covers.
-- The network of the pole nearest position, within radius: its poles by one area search, their copper wires as the
-- graph. A pole covering a generator (steam engine or turbine, solar panel, fusion or burner generator) is a source;
-- so is the network beyond the radius, when a wire leaves it (an outpost read with a radius around it counts its
-- link to the base as power). A pole whose removal leaves a group of poles with no source (a cut vertex of the graph,
-- with no source on that side) is fragile: the machines only that group and the pole itself cover are cut off.
-- Bounded: the 1000 poles nearest (wires to the rest count as power); machines counted for the 16 cuts with most poles, 200 supply-area searches; cost says what it read.
return function(api)
  local M = {}
  local MAX_POLES, MAX_FINDS, MAX_ROWS, MAX_COUNTED, CELL = 1000, 200, 8, 16, 16
  local GENERATORS = {'generator', 'solar-panel', 'burner-generator', 'fusion-generator', 'electric-energy-interface'}
  local NOT_MACHINE = {generator=true, ['solar-panel']=true, accumulator=true, ['burner-generator']=true, ['electric-energy-interface']=true,
    ['fusion-generator']=true, ['lightning-attractor']=true, ['electric-pole']=true, ['power-switch']=true}
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function at(q) return string.format('(%g,%g)', math.floor(q.x * 10 + 0.5) / 10, math.floor(q.y * 10 + 0.5) / 10) end
  local function supply(pole)
    return try(function() return pole.prototype.get_supply_area_distance(pole.quality) end)
      or try(function() return pole.prototype.get_supply_area_distance() end) or try(function() return pole.prototype.supply_area_distance end) or 0
  end
  local function box_of(e)
    local b = try(function() return e.bounding_box end)
    if b then return b.left_top.x, b.left_top.y, b.right_bottom.x, b.right_bottom.y end
    return e.position.x - 0.5, e.position.y - 0.5, e.position.x + 0.5, e.position.y + 0.5
  end
  -- The copper wire neighbours of a pole (2.0 wire connectors).
  local function wired(pole)
    local out = {}
    local c = try(function() return pole.get_wire_connector(defines.wire_connector_id.pole_copper, false) end)
    for _, w in ipairs(c and try(function() return c.connections end) or {}) do
      local o = try(function() return w.target.owner end)
      if o and o.valid and o.type == 'electric-pole' then out[#out+1] = o end
    end
    return out
  end

  function M.read(p, a)
    local pos = api.position(a.position)
    local radius = api.integer(a.radius, 96, 8, 512, 'radius')
    local surface = p.surface
    local start = surface.find_entities_filtered{type='electric-pole', force=p.force, position=pos, radius=12}
    table.sort(start, function(x, y) return (x.position.x - pos.x) ^ 2 + (x.position.y - pos.y) ^ 2 < (y.position.x - pos.x) ^ 2 + (y.position.y - pos.y) ^ 2 end)
    local first = start[1]
    assert(first, 'no electric pole of ours within 12 tiles of ' .. at(pos))
    local id = first.electric_network_id
    local area = {{pos.x - radius, pos.y - radius}, {pos.x + radius, pos.y + radius}}
    -- The MAX_POLES nearest (on a copy of world n, 1149 poles cost 80 ms in the container, about 16 ms on n): the rest
    -- count as the network beyond, as past the radius.
    local poles, index, found = {}, {}, {}
    for _, e in ipairs(surface.find_entities_filtered{type='electric-pole', force=p.force, area=area}) do
      if e.valid and e.electric_network_id == id then found[#found+1] = {e=e, d=(e.position.x - pos.x) ^ 2 + (e.position.y - pos.y) ^ 2} end
    end
    local capped = #found > MAX_POLES and #found
    if capped then table.sort(found, function(x, y) return x.d < y.d end) end
    for k = 1, math.min(MAX_POLES, #found) do local e = found[k].e; poles[k] = e; index[e.unit_number] = k end
    -- The graph: copper wires between the poles read; a wire to a pole of the network outside them goes to OUT.
    local n = #poles
    local OUT = n + 1
    local adj = {}
    for i = 1, OUT do adj[i] = {} end
    local exits = 0
    for i, e in ipairs(poles) do
      for _, o in ipairs(wired(e)) do
        local j = index[o.unit_number]
        if j then adj[i][#adj[i]+1] = j
        elseif o.electric_network_id == id then adj[i][#adj[i]+1] = OUT; adj[OUT][#adj[OUT]+1] = i; exits = exits + 1 end
      end
    end
    -- Supply areas in a grid, to find the poles covering an entity.
    local grid, reach = {}, {}
    for i, e in ipairs(poles) do
      local d = supply(e)
      reach[i] = d
      for cx = math.floor((e.position.x - d) / CELL), math.floor((e.position.x + d) / CELL) do
        for cy = math.floor((e.position.y - d) / CELL), math.floor((e.position.y + d) / CELL) do
          local k = cx .. ',' .. cy
          grid[k] = grid[k] or {}
          table.insert(grid[k], i)
        end
      end
    end
    local function covering(e)
      local x1, y1, x2, y2 = box_of(e)
      local out, seen = {}, {}
      for cx = math.floor(x1 / CELL), math.floor(x2 / CELL) do
        for cy = math.floor(y1 / CELL), math.floor(y2 / CELL) do
          for _, i in ipairs(grid[cx .. ',' .. cy] or {}) do
            local q, d = poles[i].position, reach[i]
            if not seen[i] and x2 > q.x - d and x1 < q.x + d and y2 > q.y - d and y1 < q.y + d then seen[i] = true; out[#out+1] = i end
          end
        end
      end
      return out
    end
    -- Sources: poles covering a generator of the network; OUT when a wire leaves the area.
    local gen, n_gen = {}, 0
    for _, g in ipairs(surface.find_entities_filtered{type=GENERATORS, force=p.force, area=area}) do
      if g.valid and try(function() return g.electric_network_id end) == id then
        n_gen = n_gen + 1
        for _, i in ipairs(covering(g)) do gen[i] = true end
      end
    end
    if exits > 0 then gen[OUT] = true end
    local root
    for i = 1, OUT do if gen[i] then root = i; break end end
    local out = {network=id, pole=first.name .. ' ' .. at(first.position), area=string.format('%s radius %d', at(pos), radius),
      poles=n, generators=n_gen, wires_out=exits > 0 and exits or nil}
    if capped then out.capped = string.format('%d poles of the network in the area: the %d nearest read; wires to the rest count as power, as past the radius', capped, MAX_POLES) end
    if not root then
      out.line = string.format('network %d: no generator in %d poles\' areas and no wire leaving the area: none of it has power from here', id, n)
      return out
    end
    -- Cut vertices by an iterative depth-first walk from a source: disc/low, pre-order and subtree sizes, and how
    -- many sources each subtree holds.
    local disc, low, parent, size, gens, order = {}, {}, {}, {}, {}, {}
    local t = 0
    local stack = {{v=root, i=1}}
    disc[root] = 1; low[root] = 1; t = 1; order[1] = root; size[root] = 1; gens[root] = gen[root] and 1 or 0
    local cuts = {}  -- v -> list of child roots whose subtree has no source
    while #stack > 0 do
      local top = stack[#stack]
      local v = top.v
      local w = adj[v][top.i]
      if w then
        top.i = top.i + 1
        if not disc[w] then
          t = t + 1
          disc[w] = t; low[w] = t; parent[w] = v; order[t] = w; size[w] = 1; gens[w] = gen[w] and 1 or 0
          stack[#stack+1] = {v=w, i=1}
        elseif w ~= parent[v] then
          low[v] = math.min(low[v], disc[w])
        end
      else
        stack[#stack] = nil
        local u = parent[v]
        if u then
          low[u] = math.min(low[u], low[v])
          size[u] = size[u] + size[v]
          gens[u] = gens[u] + gens[v]
          if low[v] >= disc[u] and gens[v] == 0 and u ~= OUT then
            cuts[u] = cuts[u] or {}
            table.insert(cuts[u], v)
          end
        end
      end
    end
    -- Poles no wire path joins to a source at all (already cut off now).
    local unreached = 0
    for i = 1, n do if not disc[i] then unreached = unreached + 1 end end
    -- Machines each pole covers (memoized supply-area searches) and the machines a cut leaves with no pole.
    local finds, covers = 0, {}
    local function machines_of(i)
      if covers[i] then return covers[i] end
      if finds >= MAX_FINDS then return nil end
      finds = finds + 1
      local q, d = poles[i].position, reach[i]
      local list = {}
      for _, e in ipairs(surface.find_entities_filtered{force=p.force, area={{q.x - d, q.y - d}, {q.x + d, q.y + d}}}) do
        if e.valid and not NOT_MACHINE[e.type] and try(function() return e.prototype.electric_energy_source_prototype end) ~= nil then list[#list+1] = e end
      end
      covers[i] = list
      return list
    end
    -- Each cut's poles (cheap); machines are counted for the MAX_COUNTED cutting most poles (searches are the cost: on a
    -- copy of world n, 1319 poles with a search per pole cost 314 ms in the container).
    local rows = {}
    for v, kids in pairs(cuts) do
      local set, members = {[v]=true}, {v}
      for _, c in ipairs(kids) do
        for k = disc[c], disc[c] + size[c] - 1 do local m = order[k]; if m ~= OUT and not set[m] then set[m] = true; members[#members+1] = m end end
      end
      rows[#rows+1] = {v=v, set=set, members=members, poles=#members - 1}
    end
    table.sort(rows, function(x, y) if x.poles ~= y.poles then return x.poles > y.poles end return x.v < y.v end)
    for k = 1, math.min(MAX_COUNTED, #rows) do
      local r = rows[k]
      local set, members = r.set, r.members
      local cut, names, partial = {}, {}, false
      local x1, y1, x2, y2
      for _, m in ipairs(members) do
        local list = machines_of(m)
        if not list then partial = true
        else
          for _, e in ipairs(list) do
            if e.valid and not cut[e.unit_number] then
              local kept = false
              for _, j in ipairs(covering(e)) do if not set[j] then kept = true; break end end
              if not kept then
                cut[e.unit_number] = true
                names[e.name] = (names[e.name] or 0) + 1
                local q = e.position
                x1, y1 = math.min(x1 or q.x, q.x), math.min(y1 or q.y, q.y)
                x2, y2 = math.max(x2 or q.x, q.x), math.max(y2 or q.y, q.y)
              end
            end
          end
        end
      end
      local count = 0
      for _ in pairs(cut) do count = count + 1 end
      r.machines, r.names, r.box, r.partial = count, names, x1 and {x1, y1, x2, y2}, partial
    end
    local counted = {}
    for k = 1, math.min(MAX_COUNTED, #rows) do counted[k] = rows[k] end
    table.sort(counted, function(x, y) if x.machines ~= y.machines then return x.machines > y.machines end return x.poles > y.poles end)
    local list = {}
    for k = 1, math.min(MAX_ROWS, #counted) do
      local r = counted[k]
      local e = poles[r.v]
      local kinds = {}
      for name, c in pairs(r.names) do kinds[#kinds+1] = {name=name, c=c} end
      table.sort(kinds, function(x, y) if x.c ~= y.c then return x.c > y.c end return x.name < y.name end)
      local parts = {}
      for i = 1, math.min(4, #kinds) do parts[i] = kinds[i].c .. ' ' .. kinds[i].name end
      local where = r.box and string.format(' around %s, from %s to %s,', at({x=(r.box[1] + r.box[3]) / 2, y=(r.box[2] + r.box[4]) / 2}),
        at({x=r.box[1], y=r.box[2]}), at({x=r.box[3], y=r.box[4]})) or ''
      list[k] = {name=e.name, position=e.position, poles_cut=r.poles, machines_cut=r.machines,
        line=string.format('%s %s: its loss cuts %d pole%s and %d machine%s%s%s off from all generation%s', e.name, at(e.position), r.poles,
          r.poles == 1 and '' or 's', r.machines, r.machines == 1 and '' or 's', #parts > 0 and ' (' .. table.concat(parts, ', ') .. (#kinds > 4 and ', ...' or '') .. ')' or '',
          where, r.partial and ' (machines counted in part: search cap)' or '')}
    end
    out.fragile = #list > 0 and list or nil
    out.fragile_total = #rows
    out.unreached = unreached > 0 and unreached or nil
    out.line = string.format('network %d, %d poles in the area, %d generators%s: %s%s', id, n, n_gen,
      exits > 0 and string.format(', %d wire%s leaving the area (counted as power)', exits, exits == 1 and '' or 's') or '',
      #rows == 0 and 'no single pole whose loss cuts machines off from all generation' or string.format('%d pole%s whose loss alone cuts machines off from all generation%s', #rows, #rows == 1 and '' or 's',
        #rows > MAX_ROWS and string.format(' (of the %d cutting most poles, the %d cutting most machines listed)', math.min(MAX_COUNTED, #rows), MAX_ROWS) or ''),
      unreached > 0 and string.format('; %d poles of it in the area have no wire path to a generator or the edge', unreached) or '')
    out.cost = string.format('%d poles, %d supply-area searches', n, finds)
    return out
  end
  return M
end
