-- What a planned build would have to take away (Sonnet, shift14 21:20: the rich sulfuric acid wells on Vulcanus lay
-- under pipes, poles and tanks; a pumpjack dry run named at most four blockers each and nothing of what taking them
-- away would cut). conflicts {name, position, direction?}: the entity at its snapped position and its footprint; every
-- entity whose collision meets it there (ours built, our ghosts, trees and rocks, cliffs, another force's); the resource
-- under it; for our fluid entities among them, the fluid segment each is in and whether taking them away splits it
-- (what stands on each side); for our poles among them, the copper wires that go, whether the poles left split into
-- groups (the poles and machines on a side cut off, and whether a power source is among them), the machines no pole's
-- supply area covers after, and whether one covers the new entity. A read: nothing changes.
-- The factory is pure so the same module can be bundled into a hot reload.
return function(api)
  local M = {}
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function at(pos) return string.format('(%g,%g)', pos.x, pos.y) end
  local function label(e) return (e.type == 'entity-ghost' and e.ghost_name .. ' ghost' or e.name) .. ' ' .. at(e.position) end
  local function layers(mask) return mask and mask.layers or {} end
  local function collide(a, b) for k in pairs(a) do if b[k] then return true end end return false end
  local SKIP = {character=true, resource=true, corpse=true, ['item-entity']=true, ['item-request-proxy']=true, ['tile-ghost']=true,
    ['deconstructible-tile-proxy']=true, particle=true, ['highlight-box']=true, ['flying-text']=true, smoke=true, explosion=true}
  local OBSTACLE = {tree=true, plant=true, ['simple-entity']=true}
  local PIPE = {pipe=true, ['pipe-to-ground']=true}
  local SOURCE = {generator=true, ['solar-panel']=true, accumulator=true, ['burner-generator']=true, ['electric-energy-interface']=true,
    ['fusion-generator']=true, ['lightning-attractor']=true}
  local FLUID_STEPS, POLE_STEPS, LISTED = 3000, 6000, 4
  -- Counts by name, 'pumpjack*2 storage-tank*1', largest first.
  local function counted(list)
    local by, order = {}, {}
    for _, name in ipairs(list) do if not by[name] then by[name] = 0; order[#order+1] = name end; by[name] = by[name] + 1 end
    table.sort(order, function(a, b) if by[a] ~= by[b] then return by[a] > by[b] end return a < b end)
    local parts = {}
    for _, name in ipairs(order) do parts[#parts+1] = name .. '*' .. by[name] end
    return table.concat(parts, ' ')
  end
  local function key(e) return e.unit_number or (e.name .. at(e.position)) end

  -- Fluid boxes by segment. 2.0.77 on a copy of world n: a pipe's, tank's or pump's box carries its fluid segment's id;
  -- a machine's boxes carry none (a machine joins segments at its ports and passes nothing through). The entities a
  -- box in segment seg joins (built ones; a ghost is not in the fluid system yet).
  local function seg_of(fb, i) return try(function() return fb.get_fluid_segment_id(i) end) end
  local function in_segment(seg)
    return function(e)
      local out = {}
      local fb = try(function() return e.fluidbox end)
      for i = 1, fb and #fb or 0 do
        if seg_of(fb, i) == seg then
          for _, c in ipairs(try(function() return fb.get_connections(i) end) or {}) do
            local o = try(function() return c.owner end)
            if o and o.valid and o.type ~= 'entity-ghost' then out[#out+1] = o end
          end
        end
      end
      return out
    end
  end
  -- The poles a pole's copper wires join.
  local function wired(pole)
    local out = {}
    local con = try(function() return pole.get_wire_connector(defines.wire_connector_id.pole_copper, false) end)
    for _, c in ipairs(con and try(function() return con.connections end) or {}) do
      local o = try(function() return c.target.owner end)
      if o and o.valid and o.type == 'electric-pole' then out[#out+1] = o end
    end
    return out
  end
  -- Groups of an undirected graph (neighbours) once the removed are gone, from several starts: a breadth-first walk
  -- from each, one node of each walk in turn; walks that meet become one group. A walk that ends without meeting
  -- another is a group of its own; once at most one walk goes on, the rest is decided. claim(g, node) counts a node as
  -- its group takes it. is_end(node): a node a walk lists (claim) and goes no further from, and which joins nothing (a
  -- machine at a segment's port: walks that both reach it stay apart). Returns the groups {starts, nodes (the first 512),
  -- size, done (walked to its end)} and the steps taken (at most budget).
  local function groups(starts, neighbours, removed, budget, claim, is_end, tail)
    local owner, list = {}, {}
    local function root(g) while g.merged do g = g.merged end return g end
    local function take(g, o)
      g.size = g.size + 1
      if #g.nodes < 512 then g.nodes[#g.nodes+1] = o end
      if claim then claim(g, o) end
    end
    for _, s in ipairs(starts) do
      local k = key(s)
      if owner[k] then
        local g = root(owner[k]); g.starts[#g.starts+1] = s
      else
        local g = {starts={s}, queue={s}, head=1, nodes={}, size=0}
        take(g, s)
        owner[k] = g; list[#list+1] = g
      end
    end
    local steps = 0
    local decided
    while steps < budget do
      local roots, live = 0, 0
      for _, g in ipairs(list) do
        if not g.merged then roots = roots + 1; if g.head <= #g.queue then live = live + 1 end end
      end
      if roots <= 1 or live == 0 then break end
      -- One walk left among several groups: the split is decided; that walk goes on for tail steps more, to finish
      -- a small side.
      if live == 1 then
        decided = decided or steps
        if steps - decided >= (tail or 0) then break end
      end
      for _, g0 in ipairs(list) do
        if not g0.merged and g0.head <= #g0.queue and steps < budget then
          local node = g0.queue[g0.head]; g0.head = g0.head + 1
          steps = steps + 1
          for _, o in ipairs(neighbours(node)) do
            local k = key(o)
            if removed[k] then
            elseif is_end and is_end(o) then
              local g = root(g0)
              g.ends = g.ends or {}
              if not g.ends[k] then g.ends[k] = true; if claim then claim(g, o) end end
            else
              local g = root(g0)
              local other = owner[k] and root(owner[k])
              if not other then
                owner[k] = g; g.queue[#g.queue+1] = o; take(g, o)
              elseif other ~= g then
                -- Two walks met: one group from now on.
                for _, st in ipairs(other.starts) do g.starts[#g.starts+1] = st end
                for i = other.head, #other.queue do g.queue[#g.queue+1] = other.queue[i] end
                for _, n in ipairs(other.nodes) do if #g.nodes < 512 then g.nodes[#g.nodes+1] = n end end
                g.size = g.size + other.size
                g.pipes = (g.pipes or 0) + (other.pipes or 0)
                for _, m in ipairs(other.machines or {}) do g.machines = g.machines or {}; if #g.machines < 8 then g.machines[#g.machines+1] = m end end
                for ek in pairs(other.ends or {}) do
                  g.ends = g.ends or {}
                  if g.ends[ek] then g.nmachines = (g.nmachines or 0) - 1 else g.ends[ek] = true end
                end
                g.nmachines = (g.nmachines or 0) + (other.nmachines or 0)
                other.merged = g
              end
            end
          end
        end
      end
    end
    local out = {}
    for _, g in ipairs(list) do
      if not g.merged then out[#out+1] = {starts=g.starts, nodes=g.nodes, size=g.size, done=g.head > #g.queue, pipes=g.pipes or 0,
        machines=g.machines or {}, nmachines=g.nmachines or 0} end
    end
    return out, steps
  end
  local function fluid_claim(g, o)
    if PIPE[o.type] then g.pipes = (g.pipes or 0) + 1
    else
      g.nmachines = (g.nmachines or 0) + 1
      g.machines = g.machines or {}
      if #g.machines < 8 then g.machines[#g.machines+1] = label(o) end
    end
  end

  -- The fluid side: per segment of the removed pipes, tanks and pumps, what joins them and whether taking them away
  -- splits it (each side's machines and pipes); a removed machine: the segments its ports join.
  local function fluid_lines(removed_list, removed)
    local segments, order, lines = {}, {}, {}
    for _, e in ipairs(removed_list) do
      local fb = try(function() return e.fluidbox end)
      local ports = {}
      for i = 1, fb and #fb or 0 do
        local seg = seg_of(fb, i)
        local f = try(function() return fb[i] end)
        if seg then
          local sg = segments[seg]
          if not sg then sg = {members={}, fluid=nil, amount=0}; segments[seg] = sg; order[#order+1] = seg end
          if f and f.name then sg.fluid = f.name; sg.amount = sg.amount + (f.amount or 0) end
          local seen = false
          for _, m in ipairs(sg.members) do if m == e then seen = true end end
          if not seen then sg.members[#sg.members+1] = e end
        else
          for _, c in ipairs(try(function() return fb.get_connections(i) end) or {}) do
            local o = try(function() return c.owner end)
            if o and o.valid and o.type ~= 'entity-ghost' and not removed[key(o)] then
              ports[#ports+1] = label(o) .. (f and f.name and ' (' .. f.name .. ')' or '')
            end
          end
        end
      end
      if #ports > 0 then
        lines[#lines+1] = string.format('%s is a machine (its fluid boxes are no part of a segment): its ports join %s; taking it away splits no segment',
          label(e), table.concat(ports, ', ', 1, math.min(LISTED, #ports)) .. (#ports > LISTED and string.format(' +%d more', #ports - LISTED) or ''))
      end
    end
    for _, seg in ipairs(order) do
      local sg = segments[seg]
      local next_of = in_segment(seg)
      local function member(o)
        local fb = try(function() return o.fluidbox end)
        for i = 1, fb and #fb or 0 do if seg_of(fb, i) == seg then return true end end
        return false
      end
      -- Starts: the members left beside the removed ones. An end there (a machine, a pump) stays joined only through
      -- another member its ports join; one with none is cut off on its own.
      local starts, seen, alone = {}, {}, {}
      local function start(o)
        local k = key(o)
        if not removed[k] and not seen[k] then seen[k] = true; starts[#starts+1] = o end
      end
      for _, m in ipairs(sg.members) do
        for _, o in ipairs(next_of(m)) do
          if not removed[key(o)] then
            if member(o) then start(o)
            else
              local via
              local fb = try(function() return o.fluidbox end)
              for j = 1, fb and #fb or 0 do
                for _, c in ipairs(try(function() return fb.get_connections(j) end) or {}) do
                  local q = try(function() return c.owner end)
                  if q and q.valid and not removed[key(q)] and q.type ~= 'entity-ghost' and member(q) then via = via or q end
                end
              end
              if via then start(via)
              elseif not seen[key(o)] then seen[key(o)] = true; alone[#alone+1] = o end
            end
          end
        end
      end
      -- (an end cut off counts as a side of its own)
      local ends_cut = #alone
      local names = {}
      for _, m in ipairs(sg.members) do names[#names+1] = label(m) end
      local head = string.format('%s (%s%s)', table.concat(names, ', ', 1, math.min(LISTED, #names)) .. (#names > LISTED and string.format(' +%d more', #names - LISTED) or ''),
        sg.fluid and sg.fluid .. ' segment' or 'an empty segment', sg.fluid and string.format(', %g in these', math.floor(sg.amount + 0.5)) or '')
      local gs = #starts > 0 and groups(starts, next_of, removed, FLUID_STEPS, fluid_claim, function(o) return not member(o) end, 300) or {}
      for _, o in ipairs(alone) do gs[#gs+1] = {done=true, pipes=0, machines={label(o)}, nmachines=1} end
      if #gs == 0 then lines[#lines+1] = head .. ': nothing else joins them'
      elseif #starts + ends_cut == 1 then lines[#lines+1] = head .. ': one entity joins them, ' .. (starts[1] and label(starts[1]) or label(alone[1])) .. ': nothing splits'
      else
        if #gs == 1 then lines[#lines+1] = head .. string.format(': the %d entities joining them stay joined through other pipes', #starts)
        else
          local sides = {}
          for _, g in ipairs(gs) do
            local m = g.machines
            local more = g.nmachines - math.min(LISTED, #m)
            sides[#sides+1] = string.format('[%s; %s%d pipe%s%s]', #m > 0 and table.concat(m, ', ', 1, math.min(LISTED, #m)) .. (more > 0 and string.format(' +%d more', more) or '') or 'no machine',
              g.done and '' or 'at least ', g.pipes, g.pipes == 1 and '' or 's', g.done and '' or ' (not walked to its end)')
          end
          lines[#lines+1] = head .. string.format(': taking them away splits it into %d: %s', #gs, table.concat(sides, ' and '))
        end
      end
    end
    return lines
  end

  -- Machines with an electric energy source inside a box.
  local function machines_in(surface, force, box)
    local out = {}
    for _, o in pairs(try(function() return surface.find_entities_filtered{area=box, force=force} end) or {}) do
      if o.valid and o.type ~= 'electric-pole' and o.type ~= 'entity-ghost' and try(function() return o.prototype.electric_energy_source_prototype end) then out[#out+1] = o end
    end
    return out
  end
  local function supply_box(pole)
    local d = try(function() return pole.prototype.get_supply_area_distance(pole.quality) end) or try(function() return pole.prototype.get_supply_area_distance() end) or 0
    return {left_top={x=pole.position.x - d, y=pole.position.y - d}, right_bottom={x=pole.position.x + d, y=pole.position.y + d}}, d
  end
  local function meets(a, b)
    return a.left_top.x < b.right_bottom.x and a.right_bottom.x > b.left_top.x and a.left_top.y < b.right_bottom.y and a.right_bottom.y > b.left_top.y
  end
  -- A pole not removed whose supply area meets box, or nil.
  local function covering(surface, force, box, removed)
    local c = {x=(box.left_top.x + box.right_bottom.x) / 2, y=(box.left_top.y + box.right_bottom.y) / 2}
    for _, pole in pairs(try(function() return surface.find_entities_filtered{type='electric-pole', force=force, position=c, radius=40} end) or {}) do
      if pole.valid and not removed[key(pole)] then
        local sb = supply_box(pole)
        if meets(sb, box) then return pole end
      end
    end
    return nil
  end

  function M.read(p, a, target)
    local surface, force = p.surface, p.force
    local proto, pos, dir, box = target.proto, target.pos, target.dir, target.box
    local mask = layers(try(function() return proto.collision_mask end))
    local out = {name=proto.name, position=pos, direction=dir ~= 0 and api.compass and api.compass[dir] or nil, footprint=box}
    -- What stands in the way.
    local remove, ours, poles, kinds = {}, {}, {}, {}
    local removed = {}
    for _, o in pairs(surface.find_entities_filtered{area=box}) do
      if o.valid and not SKIP[o.type] then
        local om = o.type == 'entity-ghost' and try(function() return o.ghost_prototype.collision_mask end) or try(function() return o.prototype.collision_mask end)
        if collide(mask, layers(om)) then
          local row = {name=o.type == 'entity-ghost' and o.ghost_name or o.name, position={x=o.position.x, y=o.position.y}}
          local neutral = o.force == nil or o.force.name == 'neutral'
          if o.type == 'entity-ghost' then row.kind = 'ghost'
          elseif o.type == 'cliff' then row.kind = 'cliff'; row.note = 'cliff explosives clear it (a character cannot mine one)'
          elseif OBSTACLE[o.type] and neutral then row.kind = 'tree or rock'
          elseif o.force == force then
            row.kind = 'ours'; ours[#ours+1] = o; removed[key(o)] = true
            if o.type == 'electric-pole' then poles[#poles+1] = o end
          else row.kind = 'force ' .. tostring(try(function() return o.force.name end)) end
          remove[#remove+1] = row
          kinds[#kinds+1] = row.kind
        end
      end
    end
    table.sort(remove, function(x, y)
      if (x.kind == 'ours') ~= (y.kind == 'ours') then return x.kind == 'ours' end
      if x.position.y ~= y.position.y then return x.position.y < y.position.y end
      return x.position.x < y.position.x
    end)
    out.remove = remove
    -- The resource under it (a mining drill's mining area; a pumpjack's is its centre tile).
    local radius = try(function() return proto.mining_drill_radius end)
    local rbox = radius and {left_top={x=pos.x - radius, y=pos.y - radius}, right_bottom={x=pos.x + radius, y=pos.y + radius}} or box
    local res = {}
    for _, r in pairs(try(function() return surface.find_entities_filtered{area=rbox, type='resource'} end) or {}) do
      if #res < 4 then
        local normal = try(function() return r.prototype.normal_resource_amount end)
        local infinite = try(function() return r.prototype.infinite_resource end)
        res[#res+1] = string.format('%s %s: %s', r.name, at(r.position), infinite and normal and normal > 0 and string.format('%d%% yield', math.floor(r.amount / normal * 100 + 0.5)) or tostring(r.amount))
      end
    end
    out.resource = #res > 0 and table.concat(res, '; ') or nil
    -- Fluid segments of our fluid entities in the way.
    local fluids = {}
    for _, o in ipairs(ours) do if (try(function() return #o.fluidbox end) or 0) > 0 then fluids[#fluids+1] = o end end
    if #fluids > 0 then out.fluid = fluid_lines(fluids, removed) end
    -- Poles in the way: the wires that go, whether the poles left split, and supply.
    if #poles > 0 then
      local lines, starts, seen = {}, {}, {}
      for _, pole in ipairs(poles) do
        local to = {}
        for _, o in ipairs(wired(pole)) do
          if not removed[key(o)] then
            to[#to+1] = label(o)
            if not seen[key(o)] then seen[key(o)] = true; starts[#starts+1] = o end
          end
        end
        lines[#lines+1] = string.format('%s (network %s): %s', label(pole), tostring(try(function() return pole.electric_network_id end)),
          #to > 0 and 'its wires to ' .. table.concat(to, ', ') .. ' go' or 'no wire to a pole left')
      end
      if #starts >= 2 then
        local gs = groups(starts, wired, removed, POLE_STEPS, nil, nil, 64)
        if #gs == 1 then lines[#lines+1] = string.format('the %d poles it joined stay joined through other wires', #starts)
        else
          for _, g in ipairs(gs) do
            if g.done then
              -- A group walked to its end: its poles, the machines in their supply areas, and any power source there.
              local found, srcs, mseen = {}, 0, {}
              for _, pole in ipairs(g.nodes) do
                for _, m in ipairs(machines_in(surface, force, (supply_box(pole)))) do
                  if not mseen[key(m)] then
                    mseen[key(m)] = true
                    if SOURCE[m.type] then srcs = srcs + 1 end
                    found[#found+1] = m.name
                  end
                end
              end
              local examples = {}
              for i = 1, math.min(2, #g.nodes) do examples[i] = label(g.nodes[i]) end
              lines[#lines+1] = string.format('cut off: %d pole%s (%s) with %d machine%s in their supply areas (%s); %s', g.size, g.size == 1 and '' or 's',
                table.concat(examples, ', '), #found, #found == 1 and '' or 's', #found > 0 and counted(found) or 'none',
                srcs > 0 and srcs .. ' of them make or store power' or 'no generator, solar panel or accumulator among them')
            else
              lines[#lines+1] = string.format('the rest: from %s on (at least %d poles; not walked to its end)', label(g.starts[1]), g.size)
            end
          end
        end
      end
      out.power = lines
      -- Machines in the removed poles' supply areas that no other pole's supply area covers.
      local left, lseen = {}, {}
      for _, pole in ipairs(poles) do
        for _, m in ipairs(machines_in(surface, force, (supply_box(pole)))) do
          if not removed[key(m)] and not lseen[key(m)] then
            lseen[key(m)] = true
            if not covering(surface, force, m.bounding_box, removed) then left[#left+1] = label(m) end
          end
        end
      end
      out.unpowered_after = #left > 0 and left or nil
    end
    -- Whether a pole's supply area covers the new entity once these are gone (an electric one).
    if try(function() return proto.electric_energy_source_prototype end) then
      local pole = covering(surface, force, box, removed)
      out.supplied_by = pole and label(pole) or (#poles > 0 and 'no pole\'s supply area reaches it once these are gone' or 'no pole\'s supply area reaches it')
    end
    -- The tiles it cannot stand on (d17 batch20 A5, Gemini: "nothing stands in its way" over Fulgora's shallow oil ocean,
    -- then the build failed for foundation): per tile kind, how many of its footprint, and the tile item laid on them
    -- that makes them buildable, said when it is not researched (dryrun.tile_fixes, as the build refusal reads it); a
    -- tile ghost of that item already there counts as laid. An entity with tile rules (an asteroid collector): the
    -- broken rule.
    local rule = api.tile_rules and try(function() return api.tile_rules(surface, proto, pos, dir) end)
    local fixes = not rule and api.tile_fixes and try(function() return api.tile_fixes(surface, force, proto, pos, dir) end)
    local tiles
    if rule then tiles = {{rule=rule}}; out.tiles_line = 'its tiles do not take it: ' .. rule
    elseif fixes and #fixes > 0 then
      local by, order = {}, {}
      for _, f in ipairs(fixes) do
        local r = by[f.tile]
        if not r then r = {tile=f.tile, count=0}; by[f.tile] = r; order[#order+1] = r end
        r.count = r.count + 1
        if f.item then r.needs = f.item
        elseif f.locked then r.needs = f.locked:gsub(' %(not researched%)', ''); r.researched = false end
      end
      local parts = {}
      for _, r in ipairs(order) do
        if r.needs and r.researched == nil then r.researched = true end
        parts[#parts+1] = string.format('%s %d (%s)', r.tile, r.count, r.needs and (r.needs .. ' laid on it makes it buildable' .. (r.researched and '' or '; ' .. r.needs .. ' is not researched'))
          or 'no tile item makes it buildable')
      end
      tiles = order
      out.tiles_line = string.format('%s cannot stand on %d tile%s of its footprint: %s', proto.name, #fixes, #fixes == 1 and '' or 's', table.concat(parts, ', '))
    end
    out.tiles = tiles
    local n = #remove
    out.line = (n == 0 and 'nothing stands in its way' or string.format('%d in the way: %s', n, counted(kinds)))
      .. (out.tiles_line and '; ' .. out.tiles_line or '')
    return out
  end
  return M
end
