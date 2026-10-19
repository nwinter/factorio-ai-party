-- Fluid segments a plan joins or cuts (d17 batch34 B1, Sonnet, shift35: a pumpjack's output joined the water pipe and
-- its acid went into it; a pumpjack placed on the steam path cut the refineries' steam; pipe_gaps saw both after the
-- damage). For the plan's entries with fluid boxes (pipes, pipe-to-grounds, pumps, tanks, pumpjacks, offshore pumps,
-- machines with a fluid recipe): each box is a node; nodes joined to each other (a connection that meets one back, a
-- pipe-to-ground pairing) form a group, and each group's joins to our built fluid boxes name the segment they join
-- (get_fluid_segment_id, its contents) and the fluid each holds or is set to. A pump's input and output stay two
-- groups: its one box joins two segments (Cinder on world n: tank segment 4209, thruster 4217). A group that would
-- hold two fluids (built segments' fluids, a planned machine's recipe fluid, the resource under a planned pumpjack,
-- the tile under a planned offshore pump) is a mix. An entry on
-- the centre of a built fluid entity of ours of another name replaces it: the joins that entity has now that the new
-- one would not make are named (cut). Read only.
return function(api)
  local M = {}
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function key(x, y) return x * 4194304 + y end
  local function at(q) return string.format('(%g,%g)', q.x, q.y) end
  local function tile_text(x, y) return string.format('(%g,%g)', x + 0.5, y + 0.5) end
  local function tile_of(q) return math.floor(q.x), math.floor(q.y) end
  local STEP = {north={0,-1}, east={1,0}, south={0,1}, west={-1,0}}
  local OPP = {north='south', south='north', east='west', west='east'}
  local NAMES = {[0]='north', [4]='east', [8]='south', [12]='west'}
  -- Whether an entity prototype has fluid boxes at all (most entries of a plan do not: one read a name).
  local has_cache = {}
  function M.has_fluid(proto)
    if not proto then return false end
    local v = has_cache[proto.name]
    if v == nil then
      v = (try(function() return #proto.fluidbox_prototypes end) or 0) > 0
      has_cache[proto.name] = v
    end
    return v
  end
  -- The fluid a planned entry makes there, beside its recipe's: the resource under a pumpjack, the tile's under an
  -- offshore pump.
  local function source_fluid(s, proto, pos)
    if proto.type == 'mining-drill' then
      local r = try(function() return proto.mining_drill_radius end) or 0.5
      for _, e in ipairs(try(function() return s.find_entities_filtered{type='resource', area={{pos.x - r, pos.y - r}, {pos.x + r, pos.y + r}}, limit=4} end) or {}) do
        for _, pr in ipairs(try(function() return e.prototype.mineable_properties.products end) or {}) do
          if pr.type == 'fluid' then return pr.name, 'the resource under it' end
        end
      end
    elseif proto.type == 'offshore-pump' then
      local f = try(function() return s.get_tile(pos.x, pos.y).prototype.fluid.name end)
      if f then return f, 'the tile it pumps' end
    end
  end
  -- A built box's segment: {key, id, fluid, amount, label}.
  local function segment_of(o, box)
    local fb = try(function() return o.fluidbox end)
    if not fb then return nil end
    local f = try(function() return fb[box] end)
    local id = try(function() return fb.get_fluid_segment_id(box) end)
    local fluid = f and f.name
    if not fluid then
      local lf = try(function() return fb.get_locked_fluid(box) end)
      fluid = lf and (type(lf) == 'string' and lf or lf.name) or nil
    end
    if not fluid then local flt = try(function() return fb.get_filter(box) end); fluid = flt and flt.name or nil end
    local amount
    if id then
      local c = try(function() return fb.get_fluid_segment_contents(box) end)
      if type(c) == 'table' then amount = 0; for _, n in pairs(c) do amount = amount + n end end
    end
    if amount == nil then amount = f and f.amount or 0 end
    return {key=id and ('s' .. id) or ('b' .. tostring(o.unit_number) .. ':' .. box), id=id, fluid=fluid, amount=amount,
      label=o.name .. ' ' .. at(o.position), own=not id and o.name or nil}
  end
  local function seg_text(g)
    return string.format('%s (%s)', g.id and 'segment ' .. g.id or g.own .. '\'s box', g.fluid and string.format('%s %d', g.fluid, math.floor(g.amount + 0.5)) or 'empty, no fluid set')
  end
  -- entries: {{index, name, proto, pos, dir (0..15), recipe}}; returns lines, mix lines, cut lines (nil when none).
  function M.plan(s, force, entries)
    local nodes, by_tile, list = {}, {}, {}
    local parent = {}
    local function find(n) while parent[n] ~= n do parent[n] = parent[parent[n]]; n = parent[n] end return n end
    local function union(a, b) a, b = find(a), find(b); if a ~= b then parent[a] = b end end
    local shapes = {}
    local function rid(r) return r.copy and (r.copy .. '.' .. tostring(r.index)) or tostring(r.index) end
    for _, r in ipairs(entries) do
      if r.proto and r.pos and M.has_fluid(r.proto) and r.status ~= 'blocked' and r.status ~= 'exists' then
        local sk = r.name .. '|' .. (r.dir or 0) .. '|' .. (r.recipe or '')
        local shape = shapes[sk]
        if not shape then
          shape = {pos=r.pos, rows=try(function() return api.fluid_rows({prototype=r.proto, position=r.pos, direction=r.dir or 0}, r.recipe) end) or {}}
          shapes[sk] = shape
        end
        local dx, dy = r.pos.x - shape.pos.x, r.pos.y - shape.pos.y
        local src, why = source_fluid(s, r.proto, r.pos)
        for _, c in ipairs(shape.rows) do
          local box = c.box or 1
          -- (a pump's one box joins two segments, its input side and its output side: a node each)
          local nk = rid(r) .. ':' .. box .. (r.proto.type == 'pump' and ':' .. tostring(c.flow) or '')
          if not nodes[nk] then
            nodes[nk] = {r=r, box=box, fluids={}}
            parent[nk] = nk
            list[#list+1] = nk
          end
          local x, y = tile_of{x=c.at.x + dx, y=c.at.y + dy}
          local tx, ty = tile_of{x=c.joins.x + dx, y=c.joins.y + dy}
          local pt = {node=nk, x=x, y=y, tx=tx, ty=ty, dir=c.direction, kind=c.kind or 'normal', reach=c.underground_reach, flow=c.flow}
          nodes[nk].pts = nodes[nk].pts or {}
          table.insert(nodes[nk].pts, pt)
          local f = c.fluid ~= 'none' and c.fluid or nil
          if f then nodes[nk].fluids[f] = string.format('#%s %s\'s %s', rid(r), r.name, r.recipe and 'recipe' or 'box') end
          if src and c.flow == 'output' then nodes[nk].fluids[src] = string.format('#%s %s\'s output: %s', rid(r), r.name, why) end
          local k = key(x, y)
          by_tile[k] = by_tile[k] or {}
          table.insert(by_tile[k], pt)
        end
      end
    end
    if #list == 0 then return nil end
    -- Ours on a tile (a find each tile once), each one's connections once.
    local found, conns = {}, {}
    local function ours(x, y)
      local k = key(x, y)
      if not found[k] then
        local l = {}
        for _, o in pairs(try(function() return s.find_entities_filtered{area={{x + 0.1, y + 0.1}, {x + 0.9, y + 0.9}}, force=force} end) or {}) do
          if o.valid and o.type ~= 'entity-ghost' and o.type ~= 'character' then l[#l+1] = o end
        end
        found[k] = l
      end
      return found[k]
    end
    local function conns_of(o)
      local u = o.unit_number or o
      if not conns[u] then conns[u] = try(function() return api.fluid_connections(o) end) or {} end
      return conns[u]
    end
    local joins = {}   -- node -> {segment key -> {seg, via}}
    local function built_join(nk, seg, via)
      if not seg then return end
      joins[nk] = joins[nk] or {}
      joins[nk][seg.key] = joins[nk][seg.key] or {seg=seg, via=via}
    end
    for _, nk in ipairs(list) do
      for _, c in ipairs(nodes[nk].pts) do
        if c.kind == 'underground' then
          local d = STEP[c.dir]
          local back = OPP[c.dir]
          for n = 1, d and (c.reach or 10) or 0 do
            local x, y = c.x + d[1] * n, c.y + d[2] * n
            local hit
            for _, q in ipairs(by_tile[key(x, y)] or {}) do
              if q.node ~= nk and q.kind == 'underground' and (q.dir == back or q.dir == c.dir) then
                hit = true
                if q.dir == back then union(nk, q.node) end
              end
            end
            if not hit then
              for _, o in ipairs(ours(x, y)) do
                for _, oc in ipairs(conns_of(o)) do
                  if oc.kind == 'underground' and oc.x == x and oc.y == y and (NAMES[oc.dir] == back or NAMES[oc.dir] == c.dir) then
                    hit = true
                    if NAMES[oc.dir] == back then built_join(nk, segment_of(o, oc.box), o.name .. ' ' .. at(o.position)) end
                  end
                end
              end
            end
            if hit then break end
          end
        else
          for _, q in ipairs(by_tile[key(c.tx, c.ty)] or {}) do
            if q.node ~= nk and q.kind == 'normal' and q.tx == c.x and q.ty == c.y then union(nk, q.node) end
          end
          for _, o in ipairs(ours(c.tx, c.ty)) do
            for _, oc in ipairs(conns_of(o)) do
              if (oc.kind or 'normal') == 'normal' and oc.x == c.tx and oc.y == c.ty and oc.tx == c.x and oc.ty == c.y then
                built_join(nk, segment_of(o, oc.box), o.name .. ' ' .. at(o.position))
              end
            end
          end
        end
      end
    end
    -- Groups: their entries, the built segments joined, the fluids.
    local groups, order = {}, {}
    for _, nk in ipairs(list) do
      local root = find(nk)
      local g = groups[root]
      if not g then g = {entries={}, seen={}, segs={}, seg_order={}, fluids={}, fluid_order={}}; groups[root] = g; order[#order+1] = g end
      local r = nodes[nk].r
      if not g.seen[r] then g.seen[r] = true; g.entries[#g.entries+1] = r end
      for sk, j in pairs(joins[nk] or {}) do
        if not g.segs[sk] then g.segs[sk] = j; g.seg_order[#g.seg_order+1] = sk end
      end
      for f, what in pairs(nodes[nk].fluids) do
        if not g.fluids[f] then g.fluids[f] = what; g.fluid_order[#g.fluid_order+1] = f end
      end
    end
    local lines, mixes = {}, {}
    for _, g in ipairs(order) do
      table.sort(g.seg_order)
      for _, sk in ipairs(g.seg_order) do
        local seg = g.segs[sk].seg
        if seg.fluid and not g.fluids[seg.fluid] then
          g.fluids[seg.fluid] = string.format('%s at %s', seg.id and 'segment ' .. seg.id or seg.own .. '\'s box', g.segs[sk].via)
          g.fluid_order[#g.fluid_order+1] = seg.fluid
        end
      end
      local names = {}
      for i, r in ipairs(g.entries) do if i <= 3 then names[i] = string.format('#%s %s %s', rid(r), r.name, at(r.pos)) end end
      local who = table.concat(names, ', ') .. (#g.entries > 3 and string.format(' (+%d more)', #g.entries - 3) or '')
      if #g.seg_order > 0 then
        local parts = {}
        for _, sk in ipairs(g.seg_order) do parts[#parts+1] = seg_text(g.segs[sk].seg) .. ' at ' .. g.segs[sk].via end
        lines[#lines+1] = string.format('%s join%s %s%s', who, #g.entries == 1 and 's' or '', table.concat(parts, '; '),
          #g.seg_order > 1 and string.format(': %d segments into one', #g.seg_order) or '')
      end
      if #g.fluid_order > 1 then
        table.sort(g.fluid_order)
        local parts = {}
        for _, f in ipairs(g.fluid_order) do parts[#parts+1] = f .. ' (' .. g.fluids[f] .. ')' end
        mixes[#mixes+1] = string.format('%s would join %s', who, table.concat(parts, ' and '))
      end
    end
    -- Replaced in place: a built fluid entity of ours of another name on the entry's centre; its joins now that the
    -- entry's points do not make.
    local cuts = {}
    for _, r in ipairs(entries) do
      if r.proto and r.pos and M.has_fluid(r.proto) and r.status ~= 'blocked' and r.status ~= 'exists' and #cuts < 16 then
        for _, o in ipairs(try(function() return s.find_entities_filtered{position=r.pos, radius=0.1, force=force} end) or {}) do
          if o.valid and o.name ~= r.name and o.type ~= 'entity-ghost' and math.abs(o.position.x - r.pos.x) < 0.01 and math.abs(o.position.y - r.pos.y) < 0.01 and M.has_fluid(o.prototype) then
            local mine = {}
            for _, nk in ipairs(list) do
              if nodes[nk].r == r then for _, c in ipairs(nodes[nk].pts) do if c.kind == 'normal' then mine[key(c.tx, c.ty)] = true end end end
            end
            local lost, seg = {}, nil
            for _, oc in ipairs(conns_of(o)) do
              seg = seg or segment_of(o, oc.box)
              local t = oc.target
              if t and try(function() return t.valid end) and t ~= o and (oc.kind or 'normal') == 'normal' and not mine[key(oc.tx, oc.ty)] then
                lost[#lost+1] = t.name .. ' ' .. at(t.position)
              end
            end
            local pump = r.proto.type == 'pump' and o.prototype.type ~= 'pump'
            if #lost > 0 or pump then
              cuts[#cuts+1] = string.format('#%s %s replaces %s %s%s: %s', rid(r), r.name, o.name, at(o.position), seg and ' of ' .. seg_text(seg) or '',
                #lost > 0 and 'no longer joined to ' .. table.concat(lost, ', ') or 'a pump keeps its input and output sides as two segments')
                .. (#lost > 0 and pump and '; a pump keeps its input and output sides as two segments' or '')
            end
          end
        end
      end
    end
    return #lines > 0 and lines or nil, #mixes > 0 and mixes or nil, #cuts > 0 and cuts or nil
  end
  -- (d18 batch39 D1) what each of a would-be machine's fluid ports touches: {flow, at (the port's tile centre), wants (its
  -- recipe's or box's fluid), touches (the built segment's fluid there), segment, via}; plain ports only (an underground
  -- one is a pipe-to-ground's), one tile find a port.
  function M.touches(s, force, proto, pos, dir, recipe)
    local rows = try(function() return api.fluid_rows({prototype=proto, position=pos, direction=dir or 0}, recipe) end) or {}
    local out = {}
    for _, c in ipairs(rows) do
      if (c.kind or 'normal') == 'normal' then
        local x, y = tile_of(c.at)
        local tx, ty = tile_of(c.joins)
        local row = {flow=c.flow, box=c.box, at={x=x + 0.5, y=y + 0.5}, wants=c.fluid ~= 'none' and c.fluid or nil}
        for _, o in pairs(try(function() return s.find_entities_filtered{area={{tx + 0.1, ty + 0.1}, {tx + 0.9, ty + 0.9}}, force=force, limit=4} end) or {}) do
          if o.valid and o.type ~= 'entity-ghost' and o.type ~= 'character' and not row.touches then
            for _, oc in ipairs(try(function() return api.fluid_connections(o) end) or {}) do
              if (oc.kind or 'normal') == 'normal' and oc.x == tx and oc.y == ty and oc.tx == x and oc.ty == y then
                local seg = segment_of(o, oc.box)
                if seg then row.touches, row.segment, row.via = seg.fluid or 'empty', seg.id or seg.own, o.name .. ' ' .. at(o.position) end
                break
              end
            end
          end
        end
        out[#out+1] = row
      end
    end
    return out
  end
  -- The entries of a place_ghosts or build call (a.entities; a.builds; a.item and a.position), snapped as placed.
  function M.entries(a, kind)
    local out = {}
    local function add(i, name, pos, dir, recipe)
      local proto = name and prototypes.entity[name]
      if proto and pos and M.has_fluid(proto) then
        local d = api.direction(dir or 'north') or 0
        local q = api.position(pos)
        out[#out+1] = {index=i, name=name, proto=proto, pos=api.snap(proto, q, d), dir=d, recipe=recipe}
      end
    end
    if kind == 'place_ghosts' then
      for i, e in ipairs(type(a.entities) == 'table' and a.entities or {}) do
        if type(e) == 'table' then add(i, e.name, e.position, e.direction, e.recipe) end
      end
    else
      local function place_of(item)
        local ip = type(item) == 'string' and prototypes.item[item]
        return ip and ip.place_result and ip.place_result.name
      end
      if type(a.builds) == 'table' then
        for i, b in ipairs(a.builds) do
          if type(b) == 'table' then add(i, place_of(b.item or a.item), b.position, b.direction or a.direction, b.recipe or a.recipe) end
        end
      elseif a.item ~= nil and a.position ~= nil then
        add(1, place_of(a.item), a.position, a.direction, a.recipe)
      end
    end
    return out
  end
  -- (d17 batch35 B3, Sol: moving a melter cut a chemical plant's shared water bridge) a removal of our pipes, pipe-to-grounds,
  -- pumps and tanks: from each removed one's joined neighbours, a walk through the pipes, pipe-to-grounds and tanks left
  -- (engine connections with a target; machines, pumps and other entities end the walk) finds the parts the fluid
  -- would sit in after it. Two or more parts from one removal: a split. Per part, the machines at its edge that take the
  -- fluid from it and those that put fluid into it (a connection's flow, as the machine sees it; a pump's output side;
  -- an offshore pump), and the tanks in it. A part with takers and no source loses the fluid. WALK pipes a call (about
  -- 24 us each on world n: 144 pipes in 3.4 ms); a walk cut short is not judged.
  local WALK = 512
  local RUNS = {pipe=true, ['pipe-to-ground']=true, ['storage-tank']=true}
  local REMOVED = {pipe=true, ['pipe-to-ground']=true, ['storage-tank']=true, pump=true}
  function M.removal(force, entities)
    local gone, list = {}, {}
    for _, e in ipairs(entities) do
      if e.valid and REMOVED[e.type] and e.force == force and #list < 256 then gone[e.unit_number] = true; list[#list+1] = e end
    end
    if #list == 0 then return nil end
    -- the engine's connections only (fluidbox.get_pipe_connections: a target and flow each), read once an entity; the
    -- prototype's view (api.fluid_connections) costs about 90 us an entity on world n
    local conns = {}
    local function conns_of(o)
      local u = o.unit_number or o
      if not conns[u] then
        local out = {}
        local fb = try(function() return o.fluidbox end)
        for i = 1, fb and #fb or 0 do
          for _, c in ipairs(try(function() return fb.get_pipe_connections(i) end) or {}) do
            local t = c.target
            if t and t.object_name == 'LuaFluidBox' then t = t.owner end
            out[#out+1] = {target=t, flow=c.flow_direction}
          end
        end
        conns[u] = out
      end
      return conns[u]
    end
    local function neighbours(o)
      local out = {}
      for _, c in ipairs(conns_of(o)) do
        local t = c.target
        if t and try(function() return t.valid end) and t ~= o then out[#out+1] = t end
      end
      return out
    end
    -- the flow of o's connection that joins t, as o sees it
    local function flow_toward(o, t)
      for _, c in ipairs(conns_of(o)) do if c.target == t then return c.flow end end
    end
    local budget, lines, mixes = WALK, {}, {}
    -- removed pieces that touch form one group (a run of pipes taken out together)
    local up = {}
    local function root(u) while up[u] and up[u] ~= u do u = up[u] end return u end
    for _, r in ipairs(list) do up[r.unit_number] = up[r.unit_number] or r.unit_number end
    for _, r in ipairs(list) do
      for _, n in ipairs(neighbours(r)) do
        if gone[n.unit_number] then local a, b = root(r.unit_number), root(n.unit_number); if a ~= b then up[a] = b end end
      end
    end
    -- the parts the fluid would sit in: one walk from each removed piece's neighbours left, shared by all
    local part_of, groups, order, cut_short = {}, {}, {}, false
    local function walk(start, from)
      local part = {takers={}, sources={}, tanks=0, nodes=0, first=start.unit_number, edges={}}
      local queue, qi = {{e=start, from=from}}, 1
      while queue[qi] do
        if budget <= 0 then cut_short = true; break end
        local node, prev = queue[qi].e, queue[qi].from
        qi = qi + 1
        local u = node.unit_number
        if not part_of[u] and not gone[u] then
          budget = budget - 1
          if RUNS[node.type] then
            part_of[u] = part
            part.nodes = part.nodes + 1
            if node.type == 'storage-tank' then part.tanks = part.tanks + 1 end
            for _, n in ipairs(neighbours(node)) do if not part_of[n.unit_number] and not gone[n.unit_number] then queue[#queue+1] = {e=n, from=node} end end
          elseif node == start then
            part_of[u] = part
          end
          if not RUNS[node.type] then
            part.edges[u] = true
            -- an edge: what it does with the fluid from this part
            local fl = flow_toward(node, prev)
            local label = string.format('%s %s', node.name, at(node.position))
            if node.type == 'offshore-pump' or fl == 'output' then part.sources[#part.sources+1] = label
            else part.takers[#part.takers+1] = label end
          end
        end
      end
      return part
    end
    for _, r in ipairs(list) do
      local g = root(r.unit_number)
      if not groups[g] then groups[g] = {removed={}, parts={}, seen={}}; order[#order+1] = g end
      local G = groups[g]
      G.removed[#G.removed+1] = r
      for _, n in ipairs(neighbours(r)) do
        if not gone[n.unit_number] then
          local part = part_of[n.unit_number] or walk(n, r)
          if not G.seen[part] then G.seen[part] = true; G.parts[#G.parts+1] = part end
        end
      end
    end
    -- a machine beside the removal that another part of the group still reaches (another port of it on the line) is
    -- no part of its own
    for _, g in ipairs(order) do
      local G, kept = groups[g], {}
      for _, part in ipairs(G.parts) do
        local other = false
        if part.nodes == 0 then
          for _, q in ipairs(G.parts) do if q ~= part and q.edges[part.first] then other = true end end
        end
        if not other then kept[#kept+1] = part end
      end
      G.parts = kept
    end
    local function names(t) local o = {}; for k = 1, math.min(4, #t) do o[k] = t[k] end; return table.concat(o, ', ') .. (#t > 4 and string.format(' (+%d more)', #t - 4) or '') end
    for _, g in ipairs(order) do
      local G = groups[g]
      local r = G.removed[1]
      local f = try(function() return r.fluidbox[1] end)
      local fluid = f and f.name or (function() local lf = try(function() return r.fluidbox.get_locked_fluid(1) end); return lf and (type(lf) == 'string' and lf or lf.name) end)()
      local what = #G.removed == 1 and string.format('%s %s', r.name, at(r.position)) or string.format('%d pieces from %s %s', #G.removed, r.name, at(r.position))
      if cut_short then
        lines[#lines+1] = string.format('removing %s: the segment walk stopped after %d pipes (not judged)', what, WALK)
      elseif #G.parts >= 2 and #lines < 8 then
        local texts, starved = {}, {}
        for i, part in ipairs(G.parts) do
          texts[#texts+1] = string.format('part %d: %d pipe%s%s; takes from it: %s; puts into it: %s', i, part.nodes, part.nodes == 1 and '' or 's',
            part.tanks > 0 and string.format(' (%d tank%s)', part.tanks, part.tanks == 1 and '' or 's') or '', #part.takers > 0 and names(part.takers) or 'nothing',
            #part.sources > 0 and names(part.sources) or 'nothing')
          if #part.takers > 0 and #part.sources == 0 then starved[#starved+1] = string.format('part %d (%s)', i, names(part.takers)) end
        end
        local line = string.format('removing %s splits its %ssegment in %d: %s', what, fluid and fluid .. ' ' or '', #G.parts, table.concat(texts, '; '))
        if #starved > 0 then line = line .. '; with no source left: ' .. table.concat(starved, ', '); mixes[#mixes+1] = line end
        lines[#lines+1] = line
      end
    end
    return #lines > 0 and lines or nil, #mixes > 0 and mixes or nil
  end
  M.NOTE = 'a fluid segment holds one fluid; Sonnet, shift35: a pumpjack whose output joined a water pipe put its acid into the water segment'
  return M
end
