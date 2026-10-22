-- platform_supply {platform}: one read of a platform's supply chain (Sol, Astra 03:21-03:23: Petrel's first flight
-- starved of fuel after an exporter was repurposed and an underground side-load blocked a lane; about 20 reads by
-- hand). In the chain's order, each with what the GUI shows of it:
-- - asteroid collectors: chunks held, filters, status, the inserters taking from them and where they put the chunks,
--   and foundation ghosts in the open space in front (once built they break its tile rules);
-- - crushers: recipe, status, input and output held;
-- - fuel and oxidizer makers (thruster-fuel and thruster-oxidizer recipes): status and what they hold;
-- - thrusters: fuel and oxidizer in their tanks;
-- - each gun: rounds, and an empty one's feed (platalerts.lua turret_feed);
-- ghosts apart (by name), and the first stop in that order: a collector, crusher or maker not working, a thruster
-- short, or an empty gun. Read only.
return function(api)
  local M = {}
  local LIST = 12
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function at(pos) return string.format('(%g,%g)', pos.x, pos.y) end
  local statuses
  local function status(e)
    statuses = statuses or (function() local t = {} for k, v in pairs(defines.entity_status or {}) do t[v] = k end return t end)()
    local s = try(function() return e.status end)
    return s and statuses[s] or 'unknown'
  end
  local WORKING = {working=true, normal=true}
  local function contents_text(inv, limit)
    local list = inv and try(function() return inv.get_contents() end) or {}
    table.sort(list, function(a, b) return a.count > b.count end)
    local out = {}
    for i, s in ipairs(list) do if i > (limit or 4) then out[#out+1] = '+' .. (#list - i + 1) .. ' more'; break end; out[#out+1] = s.name .. '*' .. s.count end
    return #out > 0 and table.concat(out, ' ') or 'empty'
  end
  local function takers(s, e, force)
    local p0, b = e.position, e.bounding_box
    local area = {left_top={x=b.left_top.x - 3, y=b.left_top.y - 3}, right_bottom={x=b.right_bottom.x + 3, y=b.right_bottom.y + 3}}
    local out = {}
    for _, i in ipairs(try(function() return s.find_entities_filtered{type='inserter', area=area, force=force} end) or {}) do
      if try(function() return i.pickup_target end) == e then
        local d = try(function() return i.drop_target end)
        out[#out+1] = string.format('%s %s into %s', i.name, at(i.position), d and d.valid and (d.name .. ' ' .. at(d.position)) or 'nothing (no drop target)')
      end
    end
    return out
  end
  local function recipe_of(e) return try(function() local r = e.get_recipe(); return r and r.name end) end
  -- What an inserter lets through by its filters (the GUI's whitelist or blacklist; set by the circuit network:
  -- dynamic, not judged). Returns allow(name), a text, and whether the filter is static.
  local function filter_of(i)
    if not try(function() return i.use_filters end) then return function() return true end, nil, true end
    local mode = try(function() return i.inserter_filter_mode end) or 'whitelist'
    local set, names = {}, {}
    for k = 1, try(function() return i.filter_slot_count end) or 0 do
      local f = try(function() return i.get_filter(k) end)
      local n = f and (type(f) == 'string' and f or f.name)
      if n and not set[n] then set[n] = true; names[#names+1] = n end
    end
    local cb = try(function() return i.get_control_behavior() end)
    local dynamic = cb and try(function() return cb.circuit_set_filters end) or false
    local allow = mode == 'blacklist' and function(n) return not set[n] end or function(n) return set[n] == true end
    return allow, mode .. ': ' .. (#names > 0 and table.concat(names, ', ') or 'nothing'), not dynamic
  end
  local BELT = {['transport-belt']=true, ['underground-belt']=true, splitter=true, ['lane-splitter']=true, loader=true, ['loader-1x1']=true, ['linked-belt']=true}
  -- Each asteroid chunk type from the collectors that take it, through the inserters and belts, to the crushers whose
  -- recipe takes it and to the hub (B3, Astra on Wren 4+ times): where each goes, a static inserter filter that keeps a
  -- collected type out, and a crusher stopped with its output full while the hub it unloads into is full.
  function M.trace(s, force, hub)
    local by_pickup = {}
    for _, i in ipairs(try(function() return s.find_entities_filtered{type='inserter', force=force} end) or {}) do
      local src = try(function() return i.pickup_target end)
      if src and src.valid then
        local k = src.unit_number or src
        by_pickup[k] = by_pickup[k] or {}
        local list = by_pickup[k]; list[#list+1] = i
      end
    end
    local function takers_of(e) return by_pickup[e.unit_number or e] or {} end
    local chunks = {}
    for name in pairs(prototypes.item) do if name:find('%-asteroid%-chunk$') then chunks[#chunks+1] = name end end
    table.sort(chunks)
    local rows, flags, flagged = {}, {}, {}
    local function flag(t) if not flagged[t] then flagged[t] = true; flags[#flags+1] = t end end
    local function takes(cr, chunk)
      local r = try(function() return cr.get_recipe() end)
      for _, ing in ipairs(r and try(function() return r.ingredients end) or {}) do if ing.name == chunk then return true end end
      return false
    end
    local collectors = try(function() return s.find_entities_filtered{type='asteroid-collector', force=force} end) or {}
    for _, chunk in ipairs(chunks) do
      local from, dest, seen, belts = 0, {}, {}, 0
      local function reach(e, via)
        if not (e and e.valid) then return end
        local k = e.unit_number or e
        if seen[k] then return end
        seen[k] = true
        if e.type == 'space-platform-hub' then dest['the hub'] = true; return end
        if e.type == 'assembling-machine' or e.type == 'furnace' then
          -- an inserter puts a chunk only into a machine whose recipe takes it
          if takes(e, chunk) then
            local crusher = (try(function() return e.prototype.crafting_categories end) or {}).crushing
            dest[string.format('%s %s %s', crusher and 'crusher' or e.name, at(e.position), recipe_of(e) or '')] = true
          end
          return
        end
        if BELT[e.type] then
          belts = belts + 1
          if belts > 512 then return end
          for _, i in ipairs(takers_of(e)) do
            local allow, text, static = filter_of(i)
            local d = try(function() return i.drop_target end)
            if allow(chunk) then reach(d, i)
            elseif static and d and d.valid and (d.type == 'space-platform-hub' or ((d.type == 'assembling-machine' or d.type == 'furnace') and takes(d, chunk))) then
              -- only an inserter that would feed the chunk where it is used: the hub, or a machine whose recipe takes it
              flag(string.format('%s %s (%s) takes from the belt %s into %s %s, whose %s takes %s, and keeps it out', i.name, at(i.position), text, at(e.position),
                d.name, at(d.position), d.type == 'space-platform-hub' and 'store' or 'recipe ' .. (recipe_of(d) or ''), chunk))
            end
          end
          for _, o in ipairs(try(function() return e.belt_neighbours.outputs end) or {}) do reach(o) end
          if e.type == 'underground-belt' and try(function() return e.belt_to_ground_type end) == 'input' then reach(try(function() return e.neighbours end)) end
          return
        end
        -- a chest takes any item; a turret, a ghost or anything else takes no chunk
        if e.type == 'container' or e.type == 'logistic-container' then dest[string.format('%s %s', e.name, at(e.position))] = true end
      end
      for _, c in ipairs(collectors) do
        local fl, any = {}, false
        for k = 1, try(function() return c.filter_slot_count end) or 0 do
          local f = try(function() return c.get_filter(k) end)
          local n = f and (type(f) == 'string' and f or f.name)
          if n then any = true; fl[n] = true end
        end
        if not any or fl[chunk] then
          from = from + 1
          for _, i in ipairs(takers_of(c)) do
            local allow, text, static = filter_of(i)
            if allow(chunk) then reach(try(function() return i.drop_target end), i)
            elseif static then flag(string.format('%s %s (%s) takes from collector %s, which collects %s, and keeps it out', i.name, at(i.position), text, at(c.position), chunk)) end
          end
        end
      end
      if from > 0 then
        local list = {}
        for d in pairs(dest) do list[#list+1] = d end
        table.sort(list)
        rows[#rows+1] = string.format('%s: %d collector%s; %s%s', chunk, from, from == 1 and '' or 's',
          #list > 0 and 'goes to ' .. table.concat(list, ', ', 1, math.min(6, #list)) .. (#list > 6 and string.format(' (+%d more)', #list - 6) or '') or 'goes nowhere (no inserter path out of its collectors)',
          belts > 0 and string.format(' (over %d belt tiles)', math.min(belts, 512)) or '')
      end
    end
    -- A crusher stopped with its output full while what takes its output drops into a full hub.
    local free = hub and hub.valid and try(function() return hub.get_inventory(defines.inventory.hub_main).count_empty_stacks() end)
    for _, e in ipairs(try(function() return s.find_entities_filtered{type='assembling-machine', force=force} end) or {}) do
      if (try(function() return e.prototype.crafting_categories end) or {}).crushing and status(e) == 'full_output' then
        local into_hub = false
        for _, i in ipairs(takers_of(e)) do
          local d = try(function() return i.drop_target end)
          if d and d.valid and d.type == 'space-platform-hub' then into_hub = true end
        end
        if into_hub and free == 0 then
          flag(string.format('crusher %s %s stopped with its output full; its output inserters drop into the hub, which has no free slot', at(e.position), recipe_of(e) or ''))
        end
      end
    end
    return rows, flags
  end
  function M.read(p, a)
    assert(type(a.platform) == 'string', 'platform is required (a platform name)')
    local pl = api.platform(p, a.platform)
    -- (d22 batch78 AN2, Astra #1774) the floating chunks and the collectors' reach (collectreach.lua)
    if a.collection ~= nil then
      assert(a.collection == true, 'collection is true')
      local r = api.collectreach.read(pl)
      if a.seconds ~= nil then
        local reason = api.reason and api.reason(a.reason)
        r.replaced = api.collectreach.start(p, pl, a.seconds, reason) and 'your earlier collector_tally watch, still running, was replaced' or nil
      end
      r.tally = api.collectreach.tally(p, pl)
      r.platform = pl.name
      return r
    end
    assert(a.seconds == nil and a.reason == nil, 'seconds and reason go with collection: true')
    -- (d17 batch31 B5, Sol) the fuel feedstock trace from the thrusters back (fuelstock.lua)
    if a.fuel ~= nil then
      assert(a.fuel == true, 'fuel is true')
      local r = api.fuelstock(pl)
      r.platform = pl.name
      r.note = 'from the thrusters back: what each consumer holds against one craft, the inserters, belts and pipes on the way and their sources, as the game shows them now; read only'
      return r
    end
    local s, force = pl.surface, pl.force
    local lines, first, stops = {}, nil, {}
    local function stop(text) first = first or text; stops[#stops+1] = text end
    -- Tile ghosts on the platform, for the collectors' open space.
    local tile_ghosts = {}
    for _, g in ipairs(try(function() return s.find_entities_filtered{type='tile-ghost', limit=8192} end) or {}) do
      local tp = g.valid and prototypes.tile[g.ghost_name]
      if tp then tile_ghosts[math.floor(g.position.x) * 65536 + math.floor(g.position.y)] = {name=g.ghost_name, prototype=tp} end
    end
    local function find(t) return try(function() return s.find_entities_filtered{type=t, force=force} end) or {} end
    -- Collectors.
    local collectors = {}
    for _, c in ipairs(find('asteroid-collector')) do
      local inv = try(function() return c.get_inventory(defines.inventory.asteroid_collector_output) end)
      local filters = {}
      for i = 1, try(function() return c.filter_slot_count end) or 0 do
        local f = try(function() return c.get_filter(i) end)
        local n = f and (type(f) == 'string' and f or f.name)
        if n then filters[#filters+1] = n end
      end
      local st = status(c)
      local out = takers(s, c, force)
      local front = api.placewhy and try(function()
        return api.placewhy.tile_rules(s, c.prototype, c.position, c.direction, function(x, y) return tile_ghosts[x * 65536 + y] or s.get_tile(x, y) end)
      end)
      local row = string.format('collector %s: %s; holds %s; filters %s; %s', at(c.position), st, contents_text(inv), #filters > 0 and table.concat(filters, ', ') or 'none (takes every chunk)',
        #out > 0 and 'taken by ' .. table.concat(out, ', ') or 'no inserter takes from it')
      if front then row = row .. '; foundation ghosts in its open space: ' .. front end
      collectors[#collectors+1] = row
      if not WORKING[st] then stop(row) elseif #out == 0 then stop(row) elseif front then stop(row) end
    end
    lines[#lines+1] = #collectors > 0 and string.format('%d collector%s', #collectors, #collectors == 1 and '' or 's') or 'no asteroid collectors'
    for i, r in ipairs(collectors) do if i <= LIST then lines[#lines+1] = r end end
    -- Crushers and the fuel and oxidizer makers.
    local crushers, makers = {}, {}
    for _, e in ipairs(find('assembling-machine')) do
      local r = recipe_of(e)
      local cat = try(function() return e.prototype.crafting_categories end) or {}
      local st = status(e)
      local held = string.format('in %s, out %s', contents_text(try(function() return e.get_inventory(defines.inventory.crafter_input or defines.inventory.assembling_machine_input) end), 3),
        contents_text(try(function() return e.get_inventory(defines.inventory.crafter_output or defines.inventory.assembling_machine_output) end), 3))
      if cat.crushing then
        local row = string.format('crusher %s %s: %s; %s', at(e.position), r or 'no recipe', st, held)
        crushers[#crushers+1] = row
        if not WORKING[st] then stop(row) end
      elseif r and (r:find('thruster%-fuel') or r:find('thruster%-oxidizer')) then
        local fl = {}
        for i = 1, try(function() return #e.fluidbox end) or 0 do
          local f = try(function() return e.fluidbox[i] end)
          if f then fl[#fl+1] = string.format('%s %d', f.name, math.floor(f.amount)) end
        end
        local row = string.format('%s %s %s: %s; %s%s', e.name, at(e.position), r, st, held, #fl > 0 and '; fluids ' .. table.concat(fl, ', ') or '')
        makers[#makers+1] = row
        if not WORKING[st] then stop(row) end
      end
    end
    lines[#lines+1] = string.format('%d crusher%s', #crushers, #crushers == 1 and '' or 's')
    for i, r in ipairs(crushers) do if i <= LIST then lines[#lines+1] = r end end
    lines[#lines+1] = string.format('%d fuel and oxidizer maker%s', #makers, #makers == 1 and '' or 's')
    for i, r in ipairs(makers) do if i <= LIST then lines[#lines+1] = r end end
    -- Thrusters.
    local thr = api.thrust and try(function() return api.thrust(pl) end)
    if thr then
      lines[#lines+1] = string.format('%d thruster%s%s', thr.count or 0, (thr.count or 0) == 1 and '' or 's', #(thr.lines or {}) > 0 and ': ' .. table.concat(thr.lines, ' | ') or ': no thruster tank under half')
      if #(thr.lines or {}) > 0 then stop('thrusters: ' .. thr.lines[1]) end
    end
    -- Guns.
    local guns, empty = 0, 0
    local hub_ammo = {}
    for _, st in ipairs(pl.hub and pl.hub.valid and try(function() return pl.hub.get_inventory(defines.inventory.hub_main).get_contents() end) or {}) do
      if try(function() return prototypes.item[st.name].type end) == 'ammo' then hub_ammo[st.name] = (hub_ammo[st.name] or 0) + st.count end
    end
    local gun_rows = {}
    for _, t in ipairs(find('ammo-turret')) do
      guns = guns + 1
      local inv = try(function() return t.get_inventory(defines.inventory.turret_ammo) end)
      local n = inv and try(function() return inv.get_item_count() end) or 0
      if n == 0 then
        empty = empty + 1
        local row = string.format('%s %s empty: %s', t.name, at(t.position), api.turret_feed and try(function() return api.turret_feed(t) end) or '?')
        gun_rows[#gun_rows+1] = row
        stop(row)
      end
    end
    local hub_text = {}
    for n2, c2 in pairs(hub_ammo) do hub_text[#hub_text+1] = n2 .. '*' .. c2 end
    table.sort(hub_text)
    lines[#lines+1] = string.format('%d gun%s, %d empty; the hub holds %s', guns, guns == 1 and '' or 's', empty, #hub_text > 0 and table.concat(hub_text, ' ') or 'no ammo')
    for i, r in ipairs(gun_rows) do if i <= LIST then lines[#lines+1] = r end end
    -- Ghosts apart.
    local by = {}
    for _, g in ipairs(try(function() return s.find_entities_filtered{type='entity-ghost', limit=4096} end) or {}) do
      local n2 = try(function() return g.ghost_name end) or '?'
      by[n2] = (by[n2] or 0) + 1
    end
    local gl = {}
    for n2, c2 in pairs(by) do gl[#gl+1] = {n2, c2} end
    table.sort(gl, function(x, y) return x[2] > y[2] or (x[2] == y[2] and x[1] < y[1]) end)
    for i, v in ipairs(gl) do gl[i] = v[2] .. ' ' .. v[1] end
    local nt = 0
    for _ in pairs(tile_ghosts) do nt = nt + 1 end
    lines[#lines+1] = 'ghosts: ' .. (#gl > 0 and table.concat(gl, ', ', 1, math.min(8, #gl)) or 'no entity ghosts') .. (nt > 0 and string.format('; %d tile ghosts', nt) or '')
    table.insert(lines, 1, 'first stop: ' .. (first or 'none: every collector, crusher and maker works, no thruster is short, no gun is empty'))
    local okt, chunks, flags = pcall(M.trace, s, force, pl.hub)
    return {platform=pl.name, first_stop=first, stops=#stops > 0 and stops or nil, lines=lines, chunks=okt and #chunks > 0 and chunks or nil,
      chunk_flags=okt and flags and #flags > 0 and flags or nil, trace_error=not okt and tostring(chunks) or nil}
  end
  M.schema = {platform_supply = {platform='platform name',
    collection='optional true: the asteroid chunks floating in view of the platform (its foundation\'s chunks, 32 tiles out) and its collectors\' reach, instead: chunks_in_view, by_type, groups (by type in 16-tile cells: count, box, drift in tiles a second), nearest (12 chunks nearest a reach: name, position, drift, collector, outside: tiles beyond its reach, 0 inside), in_reach, outside_reach, collectors [{position, direction, quality, reach {from, to, radius}, status, holds, filters, in_reach, in_reach_by_type, in_reach_it_takes (of those, the ones of a type its filters take), nearest_outside, line}], collected (each chunk type in the platform\'s production statistics: total, last_1m, last_10m), tally (your collector_tally watch of this platform: so far, or done), lines, note. Reach: within collection_radius (7.5, the Space Age data) of the line from the collector\'s centre to the point collection_box_offset (5) tiles in front, as chunks taken on a copy of world n fit',
    seconds='with collection: 10..3600: start a collector_tally watch (one an agent; a new one replaces it): every 10 ticks the chunks near the collectors\' reach: one seen near the reach of a collector whose filters take its type and gone from where its drift puts it at the next read, its path within 1 tile of that reach, counts as gone_in_reach for that collector (inferred: 2.0.77 has no per-collector catch count); one gone on a platform tile (hit_hull) or away from every reach (gone_elsewhere) is not counted; and the chunks the platform collected (production statistics, exact) from the start; platform_supply {platform, collection: true} reads it: collected, collected_by_type, collectors [{position, filters, gone_in_reach, gone_in_reach_by_type, gone_s}], gone_in_reach_total, inferred_minus_collected, by_type [{name, inferred, collected, difference}], hit_hull, gone_elsewhere, line, note',
    reason='with seconds: optional text, up to 200 characters: your own reason to wait for it, shown with the watch',
    fuel='optional true: the fuel feedstock trace instead, from the thrusters back: thruster-fuel and thruster-oxidizer in the thrusters\' boxes, the pipes they join (through pumps, each with its state; what they hold, tanks) and the machines making the fluid there; per maker each ingredient against one craft, through the inserters dropping into it (static filters), from a machine making it, the hub (when it holds none: the machines making it that unload into it), a collector (chunks) or a chest, or a belt walked upstream (what it holds of the item, the inserters dropping onto it, a start nothing feeds, an underground exit with no entrance, an underground span over empty space); a fluid through its pipes to its makers; and so on down to crushers, ice melters and collectors. Returns {lines (first missing link first, then the links indented by level), first_missing, cut}. first_missing: the first consumer short of an ingredient whose way is broken, else the first missing link below its sources, else a source not working, else its sources working while it is short',
    returns='lines, in the chain\'s order: first stop (the first of these not working: a collector (not working, no inserter takes from it, or foundation ghosts in its open space), a crusher, a fuel or oxidizer maker, a thruster under half, an empty gun); collectors (status, chunks held, filters, the inserters taking from them and where they put the chunks); crushers (recipe, status, input and output); thruster-fuel and thruster-oxidizer makers (status, what they hold, fluids); thrusters; guns (an empty one with what feeds it); ghosts by name, apart. first_stop; stops (every one not working, in that order). chunks: each asteroid chunk type its collectors take, where it goes through the inserters (their filters) and belts: the crushers (one whose recipe does not take it says so), the hub. chunk_flags: a static inserter filter (whitelist or blacklist set in its GUI) that keeps a collected type out, and a crusher stopped with its output full while its output inserters drop into a hub with no free slot. Read only'}}
  return M
end
