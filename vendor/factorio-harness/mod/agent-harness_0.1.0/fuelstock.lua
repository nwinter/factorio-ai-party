-- platform_supply {platform, fuel: true} (d17 batch31 B5, Sol 06:22: "a platform fuel starvation trace that follows
-- water/ice and raw asteroid belts including gaps and underground-floor dependencies; nominal production rates hid
-- missing feedstock for most of this shift"): from the thrusters back, link by link, what reaches each consumer now.
-- - thruster-fuel and thruster-oxidizer: the thrusters' fill, the pipes they join (fluid segments, with what each
--   holds and the tanks on it), and the machines whose recipe makes the fluid with an output joining those pipes;
-- - per maker, each ingredient against one craft: an item through the inserters that drop into it (their filters),
--   from a machine whose recipe makes it, the hub, a collector or a chest, or from a belt walked upstream (up to
--   BELTS tiles: what it holds of the item, the inserters dropping onto it, a start nothing feeds, an underground exit
--   with no entrance, an underground span over empty space); a fluid through the pipes its input joins, to its makers;
-- - and so on down (DEPTH levels of the lines: crushers, ice melters, collectors); an inserter moving items from one
--   belt to another goes on up that belt (ALL_BELTS tiles a trace in all, each belt walked once an item).
-- The first missing link: the first consumer short of an ingredient (below one craft held) whose way to it is broken
-- (no inserter, no maker on its pipes, a belt start or a cut underground), or, when its sources are short themselves,
-- the first missing link below them; else a source not working, or the sources working while the consumer is short.
-- Read only; bounded: MAKERS makers a fluid, FEEDERS inserters a consumer, BELTS belt tiles a walk.
return function(api)
  local M = {}
  local MAKERS, FEEDERS, BELTS, DEPTH, LINES, ALL_BELTS = 8, 4, 256, 12, 48, 1024
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function at(q) return string.format('(%g,%g)', q.x, q.y) end
  local statuses
  local function status(e)
    statuses = statuses or (function() local t = {} for k, v in pairs(defines.entity_status or {}) do t[v] = k end return t end)()
    local s = try(function() return e.status end)
    return s and statuses[s] or 'unknown'
  end
  local WORKING = {working=true, normal=true}
  local BELT = {['transport-belt']=true, ['underground-belt']=true, splitter=true, ['lane-splitter']=true}
  local function key(e) return e.unit_number or (e.name .. at(e.position)) end
  local function recipe(e) return try(function() return e.get_recipe() end) end
  local function amount(x) return x.amount or ((x.amount_min or 0) + (x.amount_max or x.amount_min or 0)) / 2 end
  local function makes(r, name)
    for _, p in ipairs(r and try(function() return r.products end) or {}) do if p.name == name then return true end end
    return false
  end
  -- A machine box's fluid: the recipe's lock, the filter, else what it holds.
  local function box_fluid(fb, i)
    local lf = try(function() return fb.get_locked_fluid(i) end)
    if lf then return type(lf) == 'string' and lf or lf.name end
    local f = try(function() return fb.get_filter(i) end)
    if f and f.name then return f.name end
    local c = fb[i]
    return c and c.name
  end
  local function box_kind(fb, i)
    local b = try(function() local x = fb.get_prototype(i); if x and x.object_name ~= 'LuaFluidBoxPrototype' then x = x[1] end; return x end)
    return b and b.production_type
  end
  -- The fluid segments a machine's boxes of that fluid and kind join (2.0.77: a machine's own boxes carry no segment;
  -- the pipes, tanks and pumps at its ports do), and the machines joined port to port with no pipe.
  local function segments(e, fluid, kind)
    local segs, direct, held, cap = {}, {}, 0, 0
    local fb = try(function() return e.fluidbox end)
    for i = 1, fb and #fb or 0 do
      local k = box_kind(fb, i)
      if box_fluid(fb, i) == fluid and (k == kind or k == 'input-output' or (kind == 'input' and k == nil)) then
        local c = fb[i]
        held = held + (c and c.name == fluid and c.amount or 0)
        cap = cap + (try(function() return fb.get_capacity(i) end) or 0)
        local own = try(function() return fb.get_fluid_segment_id(i) end)
        if own then segs[own] = true end
        for _, cn in ipairs(try(function() return fb.get_connections(i) end) or {}) do
          local id = try(function() return cn.get_fluid_segment_id(1) end)
          local o = try(function() return cn.owner end)
          if id then segs[id] = true elseif o and o.valid then direct[#direct+1] = o end
        end
      end
    end
    return segs, direct, held, cap
  end
  function M.trace(pl)
    local s, force = pl.surface, pl.force
    local machines = try(function() return s.find_entities_filtered{type={'assembling-machine', 'furnace'}, force=force, limit=512} end) or {}
    local by_drop = {}
    for _, i in ipairs(try(function() return s.find_entities_filtered{type='inserter', force=force, limit=2048} end) or {}) do
      local d = try(function() return i.drop_target end)
      if d and d.valid then local k = key(d); by_drop[k] = by_drop[k] or {}; table.insert(by_drop[k], i) end
    end
    -- the pipes, tanks and pumps of each segment: what it holds and its tanks
    local seg_info = {}
    local function seg_text(segs, fluid)
      local n, tanks, ids = 0, 0, 0
      for id in pairs(segs) do
        ids = ids + 1
        local info = seg_info[id] or {held=0, tanks=0}
        n = n + info.held; tanks = tanks + info.tanks
      end
      return n, tanks, ids
    end
    for _, t in ipairs(try(function() return s.find_entities_filtered{type={'storage-tank', 'pipe', 'pipe-to-ground', 'pump'}, force=force, limit=4096} end) or {}) do
      local fb = try(function() return t.fluidbox end)
      for i = 1, fb and #fb or 0 do
        local id = try(function() return fb.get_fluid_segment_id(i) end)
        if id then
          local info = seg_info[id]
          if not info then
            local c = try(function() return fb.get_fluid_segment_contents(i) end) or {}
            local held = 0
            for _, v in pairs(c) do held = held + v end
            info = {held=held, tanks=0, fluid=next(c)}
            seg_info[id] = info
          end
          if t.type == 'storage-tank' then info.tanks = info.tanks + 1 end
        end
      end
    end
    -- pumps (2.0.77 on world n: a pump's box carries no segment; its connections join two): each with the segments
    -- at its ends
    local pumps = {}
    for _, e in ipairs(try(function() return s.find_entities_filtered{type='pump', force=force, limit=256} end) or {}) do
      local ends = {}
      for _, cn in ipairs(try(function() return e.fluidbox.get_connections(1) end) or {}) do
        local id = try(function() return cn.get_fluid_segment_id(1) end)
        if id then ends[#ends+1] = id end
      end
      pumps[#pumps+1] = {e=e, ends=ends}
    end
    -- the segments joined to segs through pumps, and the pumps on the way
    local function through(segs)
      local passed, grew = {}, true
      while grew do
        grew = false
        for _, pm in ipairs(pumps) do
          if not passed[pm] then
            local hit = false
            for _, id in ipairs(pm.ends) do if segs[id] then hit = true end end
            if hit then
              passed[pm] = true; passed[#passed+1] = pm
              for _, id in ipairs(pm.ends) do if not segs[id] then segs[id] = true; grew = true end end
            end
          end
        end
      end
      return passed
    end
    local makers_of = {}
    local function fluid_makers(fluid, segs, direct)
      local out = {}
      for _, d in ipairs(direct) do if makes(recipe(d), fluid) then out[#out+1] = d end end
      for _, m in ipairs(machines) do
        if #out >= MAKERS then break end
        if m.valid and makes(recipe(m), fluid) then
          local ms = makers_of[key(m) .. fluid]
          if not ms then ms = segments(m, fluid, 'output'); makers_of[key(m) .. fluid] = ms end
          for id in pairs(ms) do if segs[id] then out[#out+1] = m; break end end
        end
      end
      return out
    end
    local lines, seen = {}, {}
    local first
    local function add(depth, text) if #lines < LINES then lines[#lines+1] = string.rep('  ', depth) .. text end end
    local item_link, fluid_link
    -- A machine as a source: its state, then its own ingredients (deeper). Returns whether it works and is not short,
    -- and the first missing link below it.
    local function machine_node(e, made, depth)
      local r = recipe(e)
      local st = status(e)
      local out_inv = try(function() return e.get_inventory(defines.inventory.crafter_output or defines.inventory.assembling_machine_output) end)
      local has = made and out_inv and (try(function() return out_inv.get_item_count(made) end) or 0) or 0
      local k = key(e)
      add(depth, string.format('%s %s %s: %s%s%s', e.name, at(e.position), r and r.name or 'no recipe', st, made and has > 0 and string.format(', its output holds %d %s', has, made) or '',
        seen[k] and ' (traced above)' or ''))
      if seen[k] then return WORKING[st], nil end
      seen[k] = true
      local below
      if depth < DEPTH and r then
        for _, ing in ipairs(try(function() return r.ingredients end) or {}) do
          local m
          if ing.type == 'fluid' then m = fluid_link(e, ing.name, amount(ing), depth + 1) else m = item_link(e, ing.name, amount(ing), depth + 1) end
          below = below or m
        end
      end
      if below then return false, below end
      if not WORKING[st] then return false, string.format('%s %s %s: %s', e.name, at(e.position), r and r.name or 'no recipe', st) end
      return true, nil
    end
    -- What an inserter takes from, for the item: a source line, its worth (works) and the missing link below it.
    -- a static filter (set in its GUI) that keeps the item out; filters the circuit network sets are not judged
    local function filtered_out(i, item)
      if not try(function() return i.use_filters end) then return false end
      local cb = try(function() return i.get_control_behavior() end)
      if cb and try(function() return cb.circuit_set_filters end) then return false end
      local mode = try(function() return i.inserter_filter_mode end) or 'whitelist'
      local hit = false
      for k = 1, try(function() return i.filter_slot_count end) or 0 do
        local f = try(function() return i.get_filter(k) end)
        if f and (type(f) == 'string' and f or f.name) == item then hit = true end
      end
      return (mode == 'whitelist') ~= hit
    end
    local belt_walk
    local function source(src, item, depth, breaks)
      if not (src and src.valid) then breaks[#breaks+1] = 'an inserter picks up from nothing'; return false end
      local t = src.type
      if t == 'space-platform-hub' then
        local n = try(function() return src.get_inventory(defines.inventory.hub_main).get_item_count(item) end) or 0
        add(depth, string.format('the hub holds %d %s', n, item))
        if n == 0 then
          -- the machines making it whose inserters unload into the hub
          local makers, below, one = 0, nil, {}
          for _, i in ipairs(by_drop[key(src)] or {}) do
            local m = try(function() return i.pickup_target end)
            if makers < FEEDERS and m and m.valid and not one[key(m)] and (m.type == 'assembling-machine' or m.type == 'furnace') and makes(recipe(m), item) then
              makers = makers + 1; one[key(m)] = true
              local _, b = machine_node(m, item, depth + 1)
              below = below or b
            end
          end
          if makers == 0 then breaks[#breaks+1] = string.format('the hub holds no %s and no machine making it unloads into the hub', item)
          elseif below then breaks.deeper = breaks.deeper or below
          else breaks[#breaks+1] = string.format('the hub holds no %s (%d machine%s making it unload into it)', item, makers, makers == 1 and '' or 's') end
        end
        return n > 0
      elseif t == 'asteroid-collector' then
        -- a collector holds asteroid chunks only
        if not item:find('%-asteroid%-chunk$') then return false, true end
        local n = try(function() return src.get_inventory(defines.inventory.asteroid_collector_output).get_item_count(item) end) or 0
        local st = status(src)
        add(depth, string.format('asteroid-collector %s: %s, holds %d %s', at(src.position), st, n, item))
        if n == 0 and not WORKING[st] then breaks[#breaks+1] = string.format('asteroid-collector %s: %s', at(src.position), st) end
        return n > 0 or WORKING[st]
      elseif t == 'assembling-machine' or t == 'furnace' then
        -- a machine making something else brings none of it
        if not makes(recipe(src), item) then return false, true end
        local ok, below = machine_node(src, item, depth)
        if below then breaks.deeper = breaks.deeper or below end
        return ok
      elseif t == 'container' or t == 'logistic-container' then
        local n = try(function() return src.get_item_count(item) end) or 0
        add(depth, string.format('%s %s holds %d %s', src.name, at(src.position), n, item))
        if n == 0 then breaks[#breaks+1] = string.format('%s %s holds no %s', src.name, at(src.position), item) end
        return n > 0
      end
      if BELT[t] then return belt_walk(src, item, depth, breaks) end
      add(depth, string.format('%s %s', src.name, at(src.position)))
      return false
    end
    -- A belt walked upstream from start: what it holds of the item, its feeders' sources, and where it breaks.
    local belt_seen, belt_total = {}, 0
    function belt_walk(start, item, depth, breaks)
      if belt_seen[item .. '|' .. key(start)] then add(depth, string.format('belt at %s (traced above)', at(start.position))); return false end
      local queue, walked, n, held, feeders, ok_any = {start}, {}, 0, 0, {}, false
      local starts, cuts = {}, {}
      while #queue > 0 and n < BELTS do
        local b = table.remove(queue, 1)
        local k = key(b)
        if not walked[k] and not belt_seen[item .. '|' .. k] and belt_total < ALL_BELTS then
          walked[k] = true; n = n + 1; belt_total = belt_total + 1
          belt_seen[item .. '|' .. k] = true
          for li = 1, try(function() return b.get_max_transport_line_index() end) or 0 do
            held = held + (try(function() return b.get_transport_line(li).get_item_count(item) end) or 0)
          end
          for _, i in ipairs(by_drop[k] or {}) do if not filtered_out(i, item) then feeders[#feeders+1] = i end end
          local ins = try(function() return b.belt_neighbours.inputs end) or {}
          local prev = {}
          for _, x in ipairs(ins) do prev[#prev+1] = x end
          if b.type == 'underground-belt' and try(function() return b.belt_to_ground_type end) == 'output' then
            local o = try(function() return b.neighbours end)
            if o and o.valid then
              prev[#prev+1] = o
              -- the tiles between the ends: empty space there cuts it on a platform
              local dx, dy = o.position.x - b.position.x, o.position.y - b.position.y
              local steps = math.floor(math.max(math.abs(dx), math.abs(dy)) + 0.5)
              local empty = {}
              for j = 1, steps - 1 do
                local x, y = math.floor(b.position.x + dx * j / steps), math.floor(b.position.y + dy * j / steps)
                local tl = try(function() return s.get_tile(x, y) end)
                if tl and tl.name == 'empty-space' then empty[#empty+1] = string.format('(%d,%d)', x, y) end
              end
              if #empty > 0 then cuts[#cuts+1] = string.format('%s %s to %s: its span is over empty space at %s', b.name, at(o.position), at(b.position), table.concat(empty, ' ')) end
            else
              cuts[#cuts+1] = string.format('%s exit %s has no entrance paired', b.name, at(b.position))
            end
          end
          if #prev == 0 and #(by_drop[k] or {}) == 0 then starts[#starts+1] = at(b.position) end
          for _, x in ipairs(prev) do if x.valid and BELT[x.type] then queue[#queue+1] = x end end
        end
      end
      add(depth, string.format('belt from %s upstream: %d tiles%s hold %d %s; %d inserter%s drop onto it', at(start.position), n, n >= BELTS and ' (the first ' .. BELTS .. ')' or '',
        held, item, #feeders, #feeders == 1 and '' or 's'))
      for _, c in ipairs(cuts) do add(depth + 1, c); breaks[#breaks+1] = c end
      local brings, other = 0, 0
      for _, f in ipairs(feeders) do
        if brings >= FEEDERS then break end
        local src = try(function() return f.pickup_target end)
        local before = #lines
        add(depth + 1, string.format('%s %s from:', f.name, at(f.position)))
        local ok, elsewhere = source(src, item, depth + 2, breaks)
        if elsewhere then other = other + 1; while #lines > before do table.remove(lines) end
        else brings = brings + 1; if ok then ok_any = true end end
      end
      if other > 0 then add(depth + 1, string.format('%d other inserter%s drop what machines make that is not %s', other, other == 1 and '' or 's', item)) end
      if brings == 0 and #cuts == 0 then
        breaks[#breaks+1] = #starts > 0 and string.format('the belt starts at %s and nothing drops %s onto it upstream', starts[1], item)
          or string.format('nothing drops %s onto the belt from %s upstream (%d tiles)', item, at(start.position), n)
      end
      return ok_any or held > 0
    end
    -- An item into a machine: what it holds against one craft, the inserters dropping into it and their sources.
    function item_link(e, item, need, depth)
      local inv = try(function() return e.get_inventory(defines.inventory.crafter_input or defines.inventory.assembling_machine_input) end)
      local has = inv and (try(function() return inv.get_item_count(item) end) or 0) or 0
      local short = has < need
      local feed = {}
      for _, i in ipairs(by_drop[key(e)] or {}) do if not filtered_out(i, item) then feed[#feed+1] = i end end
      add(depth, string.format('%s into %s %s: holds %d, a craft takes %g%s; %d inserter%s drop into it', item, e.name, at(e.position), has, need, short and ' (short)' or '', #feed, #feed == 1 and '' or 's'))
      local breaks, any, brings = {}, false, 0
      for _, f in ipairs(feed) do
        if brings >= FEEDERS then break end
        local src = try(function() return f.pickup_target end)
        local before = #lines
        if src and src.valid and BELT[src.type] then
          add(depth + 1, string.format('%s %s from the belt:', f.name, at(f.position)))
          brings = brings + 1
          if belt_walk(src, item, depth + 2, breaks) then any = true end
        else
          add(depth + 1, string.format('%s %s from:', f.name, at(f.position)))
          local ok, elsewhere = source(src, item, depth + 2, breaks)
          if elsewhere then while #lines > before do table.remove(lines) end
          else brings = brings + 1; if ok then any = true end end
        end
      end
      if not short then return nil end
      if brings == 0 and #feed > 0 then return string.format('no inserter into %s %s brings %s: they take from machines making something else (it holds %d, a craft takes %g)', e.name, at(e.position), item, has, need) end
      if #feed == 0 then return string.format('no inserter drops %s into %s %s (it holds %d, a craft takes %g)', item, e.name, at(e.position), has, need) end
      if breaks[1] then return string.format('%s into %s %s (holds %d, a craft takes %g): %s', item, e.name, at(e.position), has, need, breaks[1]) end
      if breaks.deeper then return breaks.deeper end
      return string.format('%s into %s %s holds %d, a craft takes %g, while its sources work%s', item, e.name, at(e.position), has, need, any and '' or ' (none holds it now)')
    end
    -- A fluid into a machine (or the thrusters): what its boxes hold, the pipes they join and the fluid's makers there.
    function fluid_link(e, fluid, need, depth, group)
      local segs, direct, held, cap = {}, {}, 0, 0
      for _, x in ipairs(group or {e}) do
        local s1, d1, h1, c1 = segments(x, fluid, 'input')
        for id in pairs(s1) do segs[id] = true end
        for _, d in ipairs(d1) do direct[#direct+1] = d end
        held, cap = held + h1, cap + c1
      end
      local short = group and held < cap / 2 or (not group and held < need)
      local passed = through(segs)
      local pn, tanks, ids = seg_text(segs, fluid)
      local mk = fluid_makers(fluid, segs, direct)
      local pm, off = {}, nil
      for _, x in ipairs(passed) do
        local st = status(x.e)
        pm[#pm+1] = string.format('%s %s %s', x.e.name, at(x.e.position), st)
        if not WORKING[st] and st ~= 'full_output' then off = off or string.format('%s %s on its pipes: %s', x.e.name, at(x.e.position), st) end
      end
      add(depth, string.format('%s into %s: %s %d%s%s; the pipes it joins (%d segment%s%s) hold %d, %d tank%s on them; %d maker%s there', fluid,
        group and string.format('%d thruster%s', #group, #group == 1 and '' or 's') or (e.name .. ' ' .. at(e.position)),
        group and 'their boxes hold' or 'holds', math.floor(held + 0.5), group and string.format(' of %d', math.floor(cap + 0.5)) or string.format(', a craft takes %g', need),
        short and ' (short)' or '', ids, ids == 1 and '' or 's', #pm > 0 and ', through ' .. table.concat(pm, ', ', 1, math.min(4, #pm)) or '',
        math.floor(pn + 0.5), tanks, tanks == 1 and '' or 's', #mk, #mk == 1 and '' or 's'))
      local deeper, all_ok = nil, #mk > 0
      for _, m in ipairs(mk) do
        local ok, below = machine_node(m, nil, depth + 1)
        if not ok then all_ok = false end
        deeper = deeper or below
      end
      if not short then return nil end
      local what = group and string.format('%s into %d thrusters (their boxes hold %d of %d)', fluid, #group, math.floor(held + 0.5), math.floor(cap + 0.5))
        or string.format('%s into %s %s (holds %d, a craft takes %g)', fluid, e.name, at(e.position), math.floor(held + 0.5), need)
      if ids == 0 and #direct == 0 then return what .. ': its input joins no pipe' end
      if off then return what .. ': ' .. off end
      if #mk == 0 then return what .. string.format(': no machine making %s joins its pipes (they hold %d)', fluid, math.floor(pn + 0.5)) end
      if deeper then return deeper end
      return what .. (all_ok and ', while its makers work' or '')
    end
    local thrusters = try(function() return s.find_entities_filtered{type='thruster', force=force, limit=64} end) or {}
    if #thrusters == 0 then return {lines={'no thrusters on ' .. pl.name}} end
    for _, fluid in ipairs({'thruster-fuel', 'thruster-oxidizer'}) do
      local m = fluid_link(thrusters[1], fluid, 0, 0, thrusters)
      first = first or m
    end
    table.insert(lines, 1, 'first missing link: ' .. (first or 'none: each consumer holds a craft of each ingredient, and the thrusters\' boxes are at least half full'))
    return {lines=lines, first_missing=first, cut=#lines >= LINES or nil}
  end
  return M
end
