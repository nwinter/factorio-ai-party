-- platform_bom {platform, pack?} (B3, Sol 22:50: "I manually reconciled this every five minutes and found 13 mixed
-- rockets replace 31 single-item launches"): a platform's remaining bill of materials in one read. Per item: what its
-- ghosts still need (entity ghosts by the item that places them, tile ghosts by the tile's item), what is built of it
-- there, what the hub holds, what is in flight to it (cargo pods headed for this platform, from any planet), what the
-- hub's requests ask, and the rest still to send. pack: true splits the rest into rockets within a rocket's lift and
-- cargo slots, heaviest items first (cargo.lua weigh: each item into the first rocket with room for some of it).
-- Module and other item requests on ghosts are not counted. Read only.
return function(api)
  local M = {}
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function item_of(proto)
    local list = proto and try(function() return proto.items_to_place_this end)
    local first = list and list[1]
    if not first then return nil end
    local name = type(first.name) == 'string' and first.name or try(function() return first.name.name end)
    return name, first.count or 1
  end
  -- Cargo pods headed for the platform, from any surface: their cargo by item, and how many pods.
  local function in_flight(pl)
    local hub = pl.hub
    local by, pods = {}, 0
    local station, platform_kind = defines.cargo_destination and defines.cargo_destination.station, defines.cargo_destination and defines.cargo_destination.space_platform
    for _, s in pairs(game.surfaces) do
      for _, pod in ipairs(try(function() return s.find_entities_filtered{type='cargo-pod'} end) or {}) do
        local d = pod.valid and try(function() return pod.cargo_pod_destination end)
        local ours = d and ((d.type == station and d.station == hub) or (d.type == platform_kind and d.space_platform == pl))
        -- (a pod leaving the platform for a planet has the planet as its destination)
        if ours then
          pods = pods + 1
          local inv = try(function() return pod.get_inventory(defines.inventory.cargo_unit) end)
          for _, c in ipairs(inv and try(function() return inv.get_contents() end) or {}) do by[c.name] = (by[c.name] or 0) + c.count end
        end
      end
    end
    return by, pods
  end
  -- What the hub's active request sections ask of each item (their min summed).
  local function asks(hub)
    local out = {}
    local secs = try(function() return hub.get_logistic_sections() end)
    for i = 1, secs and secs.sections_count or 0 do
      local sec = secs.get_section(i)
      if sec and sec.active ~= false then
        for _, f in pairs(try(function() return sec.filters end) or {}) do
          local v = f.value
          local name = v and (type(v.name) == 'string' and v.name or try(function() return v.name.name end))
          if name and (f.min or 0) > 0 then out[name] = (out[name] or 0) + f.min end
        end
      end
    end
    return out
  end
  function M.read(p, a)
    assert(a.pack == nil or type(a.pack) == 'boolean', 'pack must be true or false')
    local pl = api.platform(p, a.platform)
    local s, hub = pl.surface, pl.hub
    assert(s and hub and hub.valid, 'platform ' .. pl.name .. ' has no hub yet (waiting for its starter pack)')
    local need, ghost_names, tile_names = {}, {}, {}
    local entity_ghosts, tile_ghosts = 0, 0
    -- (the item per ghost name, read once: 4094 ghosts on Meridian)
    local known = {}
    for _, g in ipairs(s.find_entities_filtered{type={'entity-ghost', 'tile-ghost'}, force=p.force}) do
      local key = g.type .. ':' .. g.ghost_name
      local k = known[key]
      if not k then
        local proto = try(function() return g.ghost_prototype end)
        local item, n = item_of(proto)
        k = {item=item, n=n, proto=proto}; known[key] = k
      end
      local item, n, proto = k.item, k.n, k.proto
      if item then
        need[item] = (need[item] or 0) + n
        if g.type == 'tile-ghost' then tile_ghosts = tile_ghosts + 1; tile_names[item] = proto.name
        else entity_ghosts = entity_ghosts + 1; ghost_names[item] = proto.name end
      end
    end
    local inv = try(function() return hub.get_inventory(defines.inventory.hub_main) end)
    local flight, pods = in_flight(pl)
    local ask = asks(hub)
    local rows, rest, lines = {}, {}, {}
    for item, n in pairs(need) do
      local built
      if ghost_names[item] then built = try(function() return s.count_entities_filtered{name=ghost_names[item], force=p.force} end) end
      if tile_names[item] then built = try(function() return s.count_tiles_filtered{name=tile_names[item]} end) end
      local held = inv and try(function() return inv.get_item_count(item) end) or 0
      local coming = flight[item] or 0
      local left = math.max(0, n - held - coming)
      rows[#rows+1] = {item=item, ghosts_need=n, built=built, hub=held, in_flight=coming > 0 and coming or nil, remaining=left, asks=ask[item]}
      if left > 0 then rest[#rest+1] = {name=item, count=left} end
    end
    table.sort(rows, function(x, y) if x.remaining ~= y.remaining then return x.remaining > y.remaining end return x.item < y.item end)
    for _, r in ipairs(rows) do
      lines[#lines+1] = string.format('%s: ghosts need %d%s; hub holds %d%s; %s%s', r.item, r.ghosts_need, r.built and string.format(' (%d built)', r.built) or '',
        r.hub, r.in_flight and string.format(', %d in flight', r.in_flight) or '', r.remaining > 0 and string.format('%d to send', r.remaining) or 'covered',
        r.asks and string.format(' (the hub asks %d)', r.asks) or ' (the hub asks none)')
    end
    local out = {platform=pl.name, entity_ghosts=entity_ghosts, tile_ghosts=tile_ghosts, pods_in_flight=pods, items=rows,
      lines=#lines > 0 and lines or {'no ghost on ' .. pl.name .. ': nothing to build'}}
    if #rest > 0 then
      local lift, slots = api.cargo.limits(nil)
      local w = api.cargo.weigh(rest, lift, slots)
      out.remaining_kg, out.fewest_rockets = w.total_kg, w.fewest
      if a.pack then
        out.pack = {rockets=w.rockets, fewest=w.fewest, split=w.split, too_heavy=w.too_heavy, lift=w.lift, note=w.note}
      end
      lines[#lines+1] = string.format('to send: %g kg, at least %d rocket%s by weight and slots%s', w.total_kg, w.fewest, w.fewest == 1 and '' or 's',
        a.pack and w.rockets and string.format('; pack: %d rockets, each within %s', w.rockets, w.lift) or ' (pack: true splits it into rockets)')
    end
    return out
  end
  -- platform_production {platform, item?} (D4, Astra ~10 times: ammo_rates covers only the last flight, and nothing read
  -- what a platform makes in orbit): the platform's own production statistics (its surface's, as the production GUI
  -- shows them), per item and fluid made or used: totals since it was built and the rate a minute over the last 1, 10
  -- and 60 minutes, made against used; the most made first.
  local WINDOWS = {{'one_minute', 1, '1m'}, {'ten_minutes', 10, '10m'}, {'one_hour', 60, '1h'}}
  function M.production(p, a)
    local pl = api.platform(p, a.platform)
    assert(pl.surface, 'platform ' .. pl.name .. ' has no surface yet')
    assert(a.item == nil or type(a.item) == 'string', 'item is an item or fluid name')
    local rows, lines = {}, {}
    for _, kind in ipairs({'item', 'fluid'}) do
      local stats = try(function() return kind == 'item' and p.force.get_item_production_statistics(pl.surface) or p.force.get_fluid_production_statistics(pl.surface) end)
      local names = {}
      for name in pairs(stats and stats.input_counts or {}) do names[name] = true end
      for name in pairs(stats and stats.output_counts or {}) do names[name] = true end
      for name in pairs(names) do
        if a.item == nil or a.item == name then
          local r = {name=name, kind=kind, made=math.floor(stats.get_input_count(name) + 0.5), used=math.floor(stats.get_output_count(name) + 0.5)}
          for _, w in ipairs(WINDOWS) do
            local made = try(function() return stats.get_flow_count{name=name, category='input', precision_index=defines.flow_precision_index[w[1]], count=true} end) or 0
            local used = try(function() return stats.get_flow_count{name=name, category='output', precision_index=defines.flow_precision_index[w[1]], count=true} end) or 0
            r['made_per_min_' .. w[3]] = math.floor(made / w[2] * 10 + 0.5) / 10
            r['used_per_min_' .. w[3]] = math.floor(used / w[2] * 10 + 0.5) / 10
          end
          rows[#rows+1] = r
        end
      end
    end
    table.sort(rows, function(x, y) if x.made ~= y.made then return x.made > y.made end return x.name < y.name end)
    for i, r in ipairs(rows) do
      if i > 24 then lines[#lines+1] = string.format('+%d more (item: NAME reads one)', #rows - 24); break end
      lines[#lines+1] = string.format('%s: made %g/min, used %g/min (last 10 min); last 1 min %g/%g, last hour %g/%g; in all made %d, used %d',
        r.name, r.made_per_min_10m, r.used_per_min_10m, r.made_per_min_1m, r.used_per_min_1m, r.made_per_min_1h, r.used_per_min_1h, r.made, r.used)
    end
    local where = api.where and try(function() return api.where(pl) end)
    return {platform=pl.name, where=where and where.text or nil, items=rows,
      lines=#lines > 0 and lines or {'nothing made or used on ' .. pl.name .. (a.item and ' of ' .. a.item or '') .. ' in its statistics'},
      note='the platform\'s own production statistics (its surface), as the production GUI shows them; wait_until {until: produced, platform, item, at_least} waits for what it makes from now'}
  end
  M.schema = {platform_production = {platform='platform name', item='optional item or fluid name: that one only',
    returns='lines (the most made first), items [{name, kind, made, used (totals), made_per_min_1m|10m|1h, used_per_min_1m|10m|1h}], where; read only'},
    platform_bom = {platform='platform name',
    pack='optional true: the rest still to send split into rockets within a rocket\'s lift and cargo slots, heaviest items first, each into the first rocket with room (pack {rockets, fewest, split [{rocket, kg, slots, items}]}); load_silo {items, launch, platform} takes each rocket\'s list',
    returns='lines (one per item, most still to send first, then the total), items [{item, ghosts_need (what the entity and tile ghosts there need of it), built (entities or tiles of it already built there), hub (held), in_flight (in cargo pods headed for this platform), remaining (need less hub and in flight), asks (the hub\'s active requests)}], entity_ghosts, tile_ghosts, pods_in_flight, remaining_kg, fewest_rockets; module requests on ghosts are not counted. Read only'}}
  return M
end
