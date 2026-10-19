-- packaudit: one item across every planet and platform, in one read (Luna, 16:50: she put a pack's freight together
-- by hand from science on Gleba and supply on Nauvis). freight_audit {item}:
-- - per planet surface with any of ours: made and used in the last 10 minutes (the force's statistics there), what
--   its logistic networks hold (the game's network count) and what their requesters still lack of it (asked less
--   held and on the way), what its landing pads, labs and rocket silos' cargo hold, each silo's room for more of it
--   (the rocket's lift left by weight), labs the current research needs it in that hold none, and the first stack to
--   spoil among the pads, silos and the networks' chests read (at most CHESTS a planet);
-- - per platform: where it is (the platforms row's rule), what its hub holds (main and trash), its first stack to
--   spoil and, flying, how many spoil before the arrival, and what its hub requests of it with the import planet and
--   how much is short.
-- A finished read is kept 10 s (supply.lua reuse). A landing pad in a logistic network is in the network's count and
-- is not added again; plain chests (machine output chests) and landed pods are read (Sol 01:59: Aquilo's cryogenic
-- packs 763 + 763 + 1000, the pad twice and the output chests left out).
return function(api)
  local M = {}
  local CHESTS, LABS, SILOS, PADS, PLAIN = 400, 1024, 16, 16, 4000
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function at(pos) return string.format('(%g,%g)', math.floor(pos.x * 10 + 0.5) / 10, math.floor(pos.y * 10 + 0.5) / 10) end
  local function secs(ticks)
    local s = math.max(0, math.floor(ticks / 60 + 0.5))
    if s >= 60 then return string.format('%dm%02ds', math.floor(s / 60), s % 60) end
    return s .. 's'
  end
  local function count_in(inv, item)
    return inv and (try(function() return inv.get_item_count(item) end) or 0) or 0
  end
  -- The first stack of item to spoil among inventories: {tick, percent, where}.
  -- (d19 batch44 A2: freight_audit {item: steel-plate} took 250 ms on the private copy, every slot of every network
  -- chest read for an item that never spoils) items that spoil only, inventories that hold some only
  local spoils_of = {}
  local function spoils(item)
    local v = spoils_of[item]
    if v == nil then v = (try(function() return prototypes.item[item].get_spoil_ticks() end) or 0) > 0; spoils_of[item] = v end
    return v
  end
  local function spoil_into(first, inv, item, where)
    if not inv or not spoils(item) or count_in(inv, item) == 0 then return first end
    for i = 1, #inv do
      local s = inv[i]
      if s and s.valid_for_read and s.name == item then
        local tick, pct
        if api.spoil then tick, pct = api.spoil.stack_spoil(s) end
        -- where: a label, or the entity whose name and position make it (built only when it is the first so far)
        if tick and (not first or tick < first.tick) then
          first = {tick=tick, percent=pct or 0, where=type(where) == 'string' and where or (where.name .. ' ' .. at(where.position))}
        end
      end
    end
    return first
  end
  local function spoil_text(first)
    if not first then return nil end
    return string.format('the first spoils in %s (%d%% spoiled) at %s', secs(first.tick - game.tick), math.floor(first.percent * 100 + 0.5), first.where)
  end
  local function per_min(force, surface, item, category)
    local stats = try(function() return force.get_item_production_statistics(surface) end)
    local n = stats and try(function()
      return stats.get_flow_count{name=item, category=category, precision_index=defines.flow_precision_index.ten_minutes, count=true}
    end)
    return n and math.floor(n / 10 + 0.5) or 0
  end
  local function needed_by_research(force, item)
    for _, ing in ipairs(try(function() return force.current_research.research_unit_ingredients end) or {}) do
      if ing.name == item then return true end
    end
    return false
  end

  -- A pad's stock is in a logistic network when one of its provider points is (a pad has several points, so its
  -- logistic_network reads nil: checked on 2.0.77, Aquilo's pad in network 126).
  local function in_network(pad)
    local pts = try(function() return pad.get_logistic_point() end)
    if type(pts) ~= 'table' then return false end
    if pts.mode ~= nil then pts = {pts} end
    local requester = try(function() return defines.logistic_mode.requester end)
    for _, pt in pairs(pts) do
      local net = try(function() return pt.logistic_network end)
      if net and try(function() return net.valid end) and (requester == nil or pt.mode ~= requester) then return true end
    end
    return false
  end
  local mode_of = {}
  local function point_of(pt) return pt.owner, pt.filters end
  local function planet(force, surface, item, research)
    local row = {surface=surface.name, made_per_min=per_min(force, surface, item, 'input'), used_per_min=per_min(force, surface, item, 'output'),
      networks=0, unmet=0, requesters_short=0, pads=0, labs=0, silos=0, requesters=0}
    local first
    -- Logistic networks: their count, their requesters' shortfall, and their chests' stacks for spoil. What requester
    -- chests hold is no part of a network's count (d16 batch7, checked on the copy of world n: Nauvis's networks counted
    -- 8 iron plates while 2,100 sat in 35 requesters; Sonnet 12:20: 2,500 packs in a requester read as none): counted
    -- apart, each chest once.
    local chests = 0
    local req_seen = {}
    for _, ln in ipairs(try(function() return force.logistic_networks[surface.name] end) or {}) do
      row.networks = row.networks + math.max(0, try(function() return ln.get_item_count(item) end) or 0)
      for _, pt in ipairs(try(function() return ln.requester_points end) or {}) do
        -- (d19 batch44 A2) one pcall a point (the closures a field were about half of Nauvis's 9 ms for 513 points);
        -- a chest name's logistic mode read once; what is on its way only for a point whose filters name the item
        local okp, owner, filters = pcall(point_of, pt)
        if not okp then owner, filters = nil, nil end
        local oname = owner and owner.valid and owner.type == 'logistic-container' and owner.name
        if oname and mode_of[oname] == nil then mode_of[oname] = try(function() return owner.prototype.logistic_mode end) or false end
        if oname and not req_seen[owner.unit_number or owner] and mode_of[oname] == 'requester' then
          req_seen[owner.unit_number or owner] = true
          local okc, n = pcall(owner.get_item_count, item)
          row.requesters = row.requesters + (okc and n or 0)
        end
        local coming
        for _, f in ipairs(filters or {}) do
          local name = type(f.name) == 'table' and f.name.name or f.name
          if name == item and (f.count or 0) > 0 and owner and owner.valid and owner.type ~= 'cargo-landing-pad' then
            if not coming then
              coming = 0
              for _, c in pairs(try(function() return pt.targeted_items_deliver end) or {}) do
                if type(c) == 'table' and (c.name == item or (type(c.name) == 'table' and c.name.name == item)) then coming = coming + (c.count or 0) end
              end
            end
            local okh, have = pcall(owner.get_item_count, item)
            local short = f.count - (okh and have or 0) - coming
            if short > 0 then row.unmet = row.unmet + short; row.requesters_short = row.requesters_short + 1 end
          end
        end
      end
      -- (the chests' stacks are read for spoil only: an item that spoils)
      for _, list in ipairs(spoils(item) and {try(function() return ln.provider_points end) or {}, try(function() return ln.storage_points end) or {}} or {}) do
        for _, pt in ipairs(list) do
          if chests >= CHESTS then break end
          local owner = try(function() return pt.owner end)
          if owner and owner.valid and owner.type == 'logistic-container' then
            chests = chests + 1
            first = spoil_into(first, try(function() return owner.get_inventory(defines.inventory.chest) end), item, owner)
          end
        end
      end
    end
    row.chests_read = chests > 0 and chests or nil
    -- One find for the pads, silos, labs and plain chests (each whole-surface find sweeps every chunk).
    -- (d19 batch44 A2) the census pass's when it has them (the find was about 10.5 ms on the private copy's Nauvis)
    local kinds = {'cargo-landing-pad', 'rocket-silo', 'lab', 'container', 'temporary-container'}
    local found = api.census_typed and try(function() return api.census_typed(force, surface, kinds) end) or try(function()
      return surface.find_entities_filtered{type=kinds, force=force}
    end) or {}
    local by = {['cargo-landing-pad']={}, ['rocket-silo']={}, lab={}, container={}, ['temporary-container']={}}
    for _, e in ipairs(found) do local l = by[e.type]; if l then l[#l+1] = e end end
    -- Landing pads. A pad in a logistic network is in that network's count already: it is shown, not added again.
    row.pads_in_networks = 0
    for i, pad in ipairs(by['cargo-landing-pad']) do
      if i > PADS then break end
      local inv = try(function() return pad.get_inventory(defines.inventory.cargo_landing_pad_main) end)
      local n = count_in(inv, item)
      row.pads = row.pads + n
      if n > 0 and in_network(pad) then row.pads_in_networks = row.pads_in_networks + n end
      first = spoil_into(first, inv, item, 'cargo-landing-pad ' .. at(pad.position))
    end
    -- Plain chests (machine output chests and the like) and landed cargo pods: in no logistic network.
    row.chests, row.chests_holding = 0, 0
    local plain = 0
    for _, kind in ipairs({'container', 'temporary-container'}) do
      for _, c in ipairs(by[kind]) do
        if plain >= PLAIN then break end
        plain = plain + 1
        local inv = try(function() return c.get_inventory(defines.inventory.chest) end)
        local n = count_in(inv, item)
        if n > 0 then
          row.chests = row.chests + n; row.chests_holding = row.chests_holding + 1
          first = spoil_into(first, inv, item, c)
        end
      end
    end
    local plain_total = #by.container + #by['temporary-container']
    row.chests_unread = plain_total > plain and plain_total - plain or nil
    -- Rocket silos: their cargo of it and room for more.
    local silos = {}
    for i, silo in ipairs(by['rocket-silo']) do
      if i > SILOS then break end
      local inv = try(function() return silo.get_inventory(defines.inventory.rocket_silo_rocket) end)
      local n = count_in(inv, item)
      row.silos = row.silos + n
      first = spoil_into(first, inv, item, 'rocket-silo ' .. at(silo.position))
      local room = api.rocket_room and try(function() return api.rocket_room(silo, item) end)
      silos[#silos+1] = string.format('rocket-silo %s: %d in its rocket%s', at(silo.position), n,
        room and room ~= math.huge and string.format(', room for %d more by weight', room) or '')
    end
    row.silo_rows = #silos > 0 and silos or nil
    -- Labs: what they hold, and those with none while the research needs it.
    local labs, without = 0, 0
    for i, lab in ipairs(by.lab) do
      if i > LABS then break end
      labs = labs + 1
      local n = count_in(try(function() return lab.get_inventory(defines.inventory.lab_input) end), item)
      row.labs = row.labs + n
      if research and n == 0 then without = without + 1 end
    end
    row.labs_without = research and labs > 0 and without or nil
    row.lab_count = labs > 0 and labs or nil
    row.spoil = spoil_text(first)
    row.total = row.networks + row.requesters + row.pads - row.pads_in_networks + row.chests + row.silos + row.labs
    if row.pads_in_networks == 0 then row.pads_in_networks = nil end
    local parts = {string.format('%s: made %d/min, used %d/min', surface.name, row.made_per_min, row.used_per_min)}
    parts[#parts+1] = string.format('logistic networks %d', row.networks)
    if row.requesters > 0 then parts[#parts+1] = string.format('requester chests %d', row.requesters) end
    if row.unmet > 0 then parts[#parts+1] = string.format('their requesters lack %d (%d requester%s)', row.unmet, row.requesters_short, row.requesters_short == 1 and '' or 's') end
    if row.pads > 0 then
      parts[#parts+1] = string.format('landing pads %d', row.pads) .. (row.pads_in_networks and
        (row.pads_in_networks == row.pads and ' (in a logistic network: counted there)' or string.format(' (%d of them in a logistic network: counted there)', row.pads_in_networks)) or '')
    end
    if row.chests > 0 then parts[#parts+1] = string.format('other chests %d (%d chest%s)', row.chests, row.chests_holding, row.chests_holding == 1 and '' or 's') end
    if row.chests_unread then parts[#parts+1] = string.format('%d plain chests not read (the first %d were): the total is partial', row.chests_unread, PLAIN) end
    if #silos > 0 then parts[#parts+1] = table.concat(silos, '; ') end
    if labs > 0 then
      parts[#parts+1] = string.format('labs %d hold %d', labs, row.labs) .. (research and string.format(', %d of them none (the research needs it)', without) or '')
    end
    if row.spoil then parts[#parts+1] = row.spoil end
    row.line = table.concat(parts, '; ')
    return row
  end

  local function platform(pl, item)
    local hub = try(function() return pl.hub end)
    if not (hub and hub.valid) then return nil end
    local main = try(function() return hub.get_inventory(defines.inventory.hub_main) end)
    local trash = defines.inventory.hub_trash and try(function() return hub.get_inventory(defines.inventory.hub_trash) end)
    local row = {platform=pl.name, hub=count_in(main, item) + count_in(trash, item)}
    local w = api.where and try(function() return api.where(pl) end)
    row.where = w and w.text or nil
    local first = spoil_into(nil, main, item, 'its hub')
    row.spoil = spoil_text(first)
    -- Flying: how many spoil before the arrival.
    local leg = w and w.leg
    if leg and leg.eta_ticks and main then
      local arrive, before = game.tick + leg.eta_ticks, 0
      for i = 1, #main do
        local s = main[i]
        if s and s.valid_for_read and s.name == item then
          local tick = api.spoil and api.spoil.stack_spoil(s)
          if tick and tick <= arrive then before = before + s.count end
        end
      end
      row.spoil_before_arrival = before
      row.arrival = string.format('arrives at %s in %s: %d spoil before it', leg.to, secs(leg.eta_ticks), before)
    end
    -- Its hub's requests for it, with the import planet and what is short.
    local asks = {}
    local secs_ = try(function() return hub.get_logistic_sections() end)
    for i = 1, secs_ and secs_.sections_count or 0 do
      local sec = secs_.get_section(i)
      if sec and sec.active ~= false then
        for _, f in ipairs(sec.filters or {}) do
          local v = f.value
          local name = type(v) == 'table' and v.name or v
          if name == item and ((f.min or 0) > 0 or f.max) then
            local from = f.import_from and (type(f.import_from) == 'string' and f.import_from or try(function() return f.import_from.name end))
            local short = math.max(0, (f.min or 0) - row.hub)
            asks[#asks+1] = string.format('requests %s..%s%s, %d short', f.min or 0, f.max and tostring(f.max) or 'inf', from and ' from ' .. from or '', short)
          end
        end
      end
    end
    row.requests = #asks > 0 and asks or nil
    local parts = {string.format('platform %s%s: hub %d', pl.name, row.where and ' (' .. row.where .. ')' or '', row.hub)}
    if row.spoil then parts[#parts+1] = row.spoil end
    if row.arrival then parts[#parts+1] = row.arrival end
    for _, x in ipairs(asks) do parts[#parts+1] = x end
    row.line = table.concat(parts, '; ')
    return row
  end

  -- One planet's row (stock {item, surface}; Gemini 02:36).
  function M.planet_row(force, surface, item) return planet(force, surface, item, needed_by_research(force, item)) end
  function M.fresh(force, item)
    local research = needed_by_research(force, item)
    local planets, platforms, total = {}, {}, 0
    for _, surface in pairs(game.surfaces) do
      if not try(function() return surface.platform end) then
        local row = planet(force, surface, item, research)
        if row.total > 0 or row.made_per_min > 0 or row.used_per_min > 0 or row.unmet > 0 or row.silo_rows then
          planets[#planets+1] = row
          total = total + row.total
        end
      end
    end
    table.sort(planets, function(x, y) return x.surface < y.surface end)
    for _, pl in pairs(try(function() return force.platforms end) or {}) do
      if pl.valid then
        local row = platform(pl, item)
        if row and (row.hub > 0 or row.requests) then platforms[#platforms+1] = row; total = total + row.hub end
      end
    end
    table.sort(platforms, function(x, y) return x.platform < y.platform end)
    local lines = {}
    for _, r in ipairs(planets) do lines[#lines+1] = r.line end
    for _, r in ipairs(platforms) do lines[#lines+1] = r.line end
    return {item=item, total=total, research_needs_it=research or nil, lines=lines, planets=planets, platforms=platforms,
      note='counted once each: logistic networks (the game\'s count, landing pads in a network among them), what requester chests hold (not in a network\'s count), landing pads in no network, plain chests and landed cargo pods (machine output chests: up to '..PLAIN..' a planet), silos\' rocket cargo, labs and platform hubs; not counted: belts, inserter hands, machines\' inputs and outputs, vehicles and wagons (supply {item, surface} reads those on one planet)'}
  end
  function M.read(p, a)
    local item = a.item
    assert(type(item) == 'string' and prototypes.item[item], 'item must be an item name (agricultural-science-pack, ...)')
    local force = p.force
    return api.reuse('freight_audit|' .. force.name .. '|' .. item, function() return M.fresh(force, item) end)
  end
  M.schema = {freight_audit = {item='an item name (a science pack, ...)',
    returns='one item across every planet and platform (Luna, 16:50): lines (one per planet, then one per platform), planets [{surface, made_per_min, used_per_min (10 min), networks (what its logistic networks hold), unmet and requesters_short (what their requesters lack: asked less held and on the way), pads (landing pads), pads_in_networks (of those, in a logistic network: in networks already, not added to total), chests and chests_holding (plain chests and landed cargo pods in no network), chests_unread (past the cap: the total is partial), silos and silo_rows (each silo: its rocket cargo of it, room for more by weight), labs (held), labs_without (labs holding none while the research needs it), spoil (the first stack to spoil: when, how spoiled, where), total, line}], platforms [{platform, where, hub (main and trash), spoil, arrival (flying: how many spoil before it), requests (import planet, short), line}], total, research_needs_it, note; kept 10 s. Read only'}}
  return M
end
