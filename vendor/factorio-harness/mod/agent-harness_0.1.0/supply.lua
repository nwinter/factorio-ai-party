-- supply: where one item sits on a surface and why it does not reach the
-- machines that use it, in one read. Shift08: Sol saw 28k green circuits in
-- stock while blue circuit assemblers starved, and electric engines stranded
-- in 4 requester chests while the export waited ("recurred at least 10
-- times"); Luna saw 31+ labs without chemical packs while stock sat on belts,
-- assembler outputs and inserter hands. Read only, the same for everyone
-- wherever they stand: where the item is; per logistic network with
-- requesters for it, what its providers hold (free and reserved for
-- deliveries), what its robots carry, its robots, and each unmet requester
-- with the reason; the machines that make and use it by status (the worst 3
-- with positions); the inserters feeding the users and taking from the
-- makers. science reads its packs through the same scan (labs as the users).
-- Bounded: 2048 crafters, 1024 labs, 5000 chests, 10000 belts, 8192
-- inserters, 4096 robots (counted says when a scan stopped).
return function(api)
  local M = {}
  local MAX_MACHINES, MAX_LABS, MAX_CHESTS, MAX_BELTS, MAX_INSERTERS, MAX_ROBOTS, MAX_FOUND = 2048, 1024, 5000, 10000, 8192, 4096, 40000
  local MAX_SPOTS, TOP_CHESTS, TOP_UNMET, WORST = 4096, 5, 5, 3
  local CRAFTERS = {'assembling-machine', 'furnace', 'rocket-silo'}
  local CHESTS = {'container', 'logistic-container', 'cargo-landing-pad', 'space-platform-hub', 'cargo-wagon', 'car', 'spider-vehicle'}
  local BELTS = {'transport-belt', 'underground-belt', 'splitter', 'loader', 'loader-1x1', 'linked-belt'}
  local ROBOTS = {'logistic-robot', 'construction-robot'}
  local BELT = {}
  for _, t in ipairs(BELTS) do BELT[t] = true end
  -- One find for every kind: each whole-surface find sweeps all chunks (on
  -- shift08's nauvis six finds took 45 ms, one 19 ms).
  -- Miners (mining drills, pumpjacks, offshore pumps) make what the chain finds no recipe for (Grok, 04:55).
  local MINERS = {'mining-drill', 'offshore-pump'}
  local GROUP, CAP = {}, {crafters=MAX_MACHINES, labs=MAX_LABS, chests=MAX_CHESTS, belts=MAX_BELTS, inserters=MAX_INSERTERS, robots=MAX_ROBOTS, miners=MAX_MACHINES}
  for group, types in pairs({crafters=CRAFTERS, labs={'lab'}, chests=CHESTS, belts=BELTS, inserters={'inserter'}, robots=ROBOTS, miners=MINERS}) do
    for _, t in ipairs(types) do GROUP[t] = group end
  end
  local MAIN = {container='chest', ['logistic-container']='chest', ['cargo-landing-pad']='cargo_landing_pad_main', ['space-platform-hub']='hub_main',
    ['cargo-wagon']='cargo_wagon', car='car_trunk', ['spider-vehicle']='spider_trunk'}
  -- Requests filled by rockets and cargo pods, not by robots.
  local ORBIT = {['cargo-landing-pad']=true, ['space-platform-hub']=true}
  local SHORT = {item_ingredient_shortage=true, no_ingredients=true, fluid_ingredient_shortage=true, no_input_fluid=true, missing_science_packs=true}
  local FULL = {full_output=true, waiting_for_space_in_destination=true, not_enough_space_in_output=true}
  local KIND_LABEL = {['active-provider']='active-provider chests', ['passive-provider']='passive-provider chests', storage='storage chests',
    buffer='buffer chests', requester='requester chests', chest='other chests', pad='landing pads', hub='platform hubs', vehicle='vehicles'}
  local KIND_ORDER = {'requester', 'passive-provider', 'active-provider', 'storage', 'buffer', 'chest', 'pad', 'hub', 'vehicle'}
  local function at(pos) return string.format('(%g,%g)', pos.x, pos.y) end
  local function try(fn, ...) local ok, v = pcall(fn, ...); if ok then return v end end
  -- No closure per call: these run for every belt, chest and inserter.
  local function inventory(e, name)
    local id = defines.inventory[name]
    if not id then return nil end
    local ok, inv = pcall(e.get_inventory, id)
    return ok and inv or nil
  end
  local function count(inv, item)
    if not inv then return 0 end
    local ok, n = pcall(inv.get_item_count, item)
    return ok and n or 0
  end
  local KIND = {}
  local function kind_of(e)
    if e.type == 'container' then return 'chest' end
    if e.type == 'cargo-landing-pad' then return 'pad' end
    if e.type == 'space-platform-hub' then return 'hub' end
    if e.type ~= 'logistic-container' then return 'vehicle' end
    local kind = KIND[e.name]
    if not kind then kind = try(function() return e.prototype.logistic_mode end) or 'chest'; KIND[e.name] = kind end
    return kind
  end
  local function recipe_of(e)
    local r = try(function() return e.get_recipe() end)
    if r or e.type ~= 'furnace' then return r end
    -- An idle furnace keeps its last recipe.
    local last = try(function() return e.previous_recipe end)
    local name = last and (type(last.name) == 'string' and last.name or last.name and last.name.name)
    return name and prototypes.recipe and prototypes.recipe[name] or nil
  end
  local function input_of(e)
    if e.type == 'lab' then return inventory(e, 'lab_input') end
    return inventory(e, 'crafter_input') or inventory(e, 'assembling_machine_input') or inventory(e, 'furnace_source')
  end
  local function output_of(e)
    local ok, inv = pcall(e.get_output_inventory)
    return ok and inv or nil
  end
  -- What a belt's lines hold of the wanted items. One item: the entity's
  -- own count covers its lines (a quarter of the time of reading each line).
  local function belt_lines(e, names, single, out)
    if single then
      local n = e.get_item_count(single)
      if n > 0 then out[single] = (out[single] or 0) + n end
      return
    end
    for i = 1, e.get_max_transport_line_index() do
      for k, v in pairs(e.get_transport_line(i).get_contents()) do
        local name, n = type(v) == 'table' and v.name or k, type(v) == 'table' and v.count or v
        if names[name] then out[name] = (out[name] or 0) + n end
      end
    end
  end
  local function belt_counts(e, names, single, out) pcall(belt_lines, e, names, single, out) end
  local function short_list(map, limit, sep)
    local list = {}
    for k, n in pairs(map) do list[#list+1] = {k=k, n=n} end
    table.sort(list, function(x, y) if x.n ~= y.n then return x.n > y.n end return x.k < y.k end)
    local parts = {}
    for i = 1, math.min(#list, limit or 8) do parts[i] = list[i].n .. ' ' .. list[i].k end
    if #list > (limit or 8) then parts[#parts+1] = '...' end
    return table.concat(parts, sep or ', ')
  end
  local function bump(map, key, n) map[key] = (map[key] or 0) + (n or 1) end
  -- Why a requester or buffer chest asks for none of an item although a
  -- section names it: the section is off, or a circuit sets the requests.
  local function request_note(e, item)
    local secs = try(function() return e.get_logistic_sections() end)
    local note
    for i = 1, secs and secs.sections_count or 0 do
      local sec = try(function() return secs.get_section(i) end)
      if sec then
        if not sec.is_manual then note = note or 'requests set by circuit' end
        for _, f in ipairs(try(function() return sec.filters end) or {}) do
          local v = f.value
          if v and (type(v) == 'table' and v.name or v) == item and sec.active == false then return 'its section asking for it is off' end
        end
      end
    end
    return note
  end

  -- One pass over the surface for a set of items (name -> true). opts.area
  -- {position, radius} limits the entity scans (network totals stay whole);
  -- opts.packs (name -> true) are the packs the current research needs: labs
  -- use them.
  -- Replies reused for REUSE_TICKS (task-statuscost: one supply read was one
  -- whole-surface find, 45 ms on shift08's nauvis; science reads every pack
  -- the same way): the finished reply (plain data, no entities), keyed by
  -- what was asked, with as_of. Module state on purpose (as profile.lua): it
  -- never touches game state, and a peer without it reads anew.
  local REUSE_TICKS, replies = 600, {}
  function M.reuse(key, fn)
    for k, c in pairs(replies) do if game.tick - c.tick >= REUSE_TICKS or c.tick > game.tick then replies[k] = nil end end
    local hit = replies[key]
    if hit then
      local out = {}
      for k, v in pairs(hit.out) do out[k] = v end
      out.as_of = string.format('%ds ago (the same read within %d s is reused)', math.floor((game.tick - hit.tick) / 60), REUSE_TICKS / 60)
      return out
    end
    local out = fn()
    replies[key] = {tick=game.tick, out=out}
    return out
  end
  function M.forget() replies = {} end
  function M.scan(surface, force, names, opts)
    opts = opts or {}
    local area, packs = opts.area, opts.packs or {}
    local single
    do local n = 0; for name in pairs(names) do n = n + 1; single = name end; if n ~= 1 then single = nil end end
    local function filter(f)
      f.force = force
      if area then f.position = area.position; f.radius = area.radius end
      return f
    end
    local function inside(pos)
      return not area or (pos.x - area.position.x) ^ 2 + (pos.y - area.position.y) ^ 2 <= area.radius ^ 2
    end
    local T = {}
    for name in pairs(names) do
      T[name] = {item=name, kinds={}, chests={}, belts=0, outputs=0, inputs=0, rockets=0, labs=0, hands=0, robots=0, characters={}, carried=0,
        makers={}, users={}, user_of={}, maker_of={}, spots={}, rows={}, orphans={}, request_of={},
        feeders={n=0, states={}, without={}, with=0}, takers={n=0, states={}, into={}}}
    end
    local counted = {}
    local function spot(t, e, n, kind)
      if #t.spots < MAX_SPOTS then t.spots[#t.spots+1] = {position=e.position, name=e.name, n=n, kind=kind, unit=e.unit_number} end
    end
    -- A spoilable item (Space Age): its first stack to spoil or hatch, where,
    -- and how many spoil within 5 minutes (spoil.lua), read where it was found.
    local sp, spoils = api.spoil, {}
    for name in pairs(names) do spoils[name] = sp and sp.spoils(name) or nil end
    local function spoil_at(t, e, kind, read)
      if not spoils[t.item] then return end
      local acc = {}
      pcall(read, acc)
      for _, r in ipairs(acc) do
        if r.name == t.item then
          t.spoil_soon = (t.spoil_soon or 0) + r.soon
          t.spoil_count = (t.spoil_count or 0) + r.count
          local f = t.spoil_first
          if not f or r.tick < f.tick then t.spoil_first = {tick=r.tick, percent=r.percent, name=e.name, position=e.position, kind=kind} end
        end
      end
    end
    local any_pack = false
    for name in pairs(names) do if packs[name] or (prototypes.item[name] and try(function() return prototypes.item[name].type end) == 'tool') then any_pack = true end end
    local types = {}
    for t, group in pairs(GROUP) do if (group ~= 'labs' and group ~= 'miners' or any_pack) and (group ~= 'robots' or not area) then types[#types+1] = t end end
    table.sort(types)
    local found = surface.find_entities_filtered(filter{type=types, limit=MAX_FOUND})
    local lists, seen = {crafters={}, labs={}, chests={}, belts={}, inserters={}, robots={}, miners={}}, {}
    for _, e in ipairs(found) do
      local group = GROUP[e.type]
      local list = group and lists[group]
      if list then
        seen[group] = (seen[group] or 0) + 1
        if #list < CAP[group] then list[#list+1] = e end
      end
    end
    -- Robots fly: with an area, those of the whole surface still count in flight.
    if area then lists.robots = surface.find_entities_filtered{type=ROBOTS, force=force, limit=MAX_ROBOTS} end
    counted.found, counted.seen = #found, seen
    -- Crafters: makers and users by recipe, and what their outputs hold.
    local crafters = lists.crafters
    counted.crafters = #crafters
    for _, e in ipairs(crafters) do
      local recipe = recipe_of(e)
      if recipe then
        for _, prod in ipairs(recipe.products or {}) do
          local t = T[prod.name]
          if t and not t.maker_of[e.unit_number] then t.maker_of[e.unit_number] = true; t.makers[#t.makers+1] = {e=e, recipe=recipe} end
        end
        for _, ing in ipairs(recipe.ingredients or {}) do
          local t = T[ing.name]
          if t and not t.user_of[e.unit_number] then
            local u = {e=e, recipe=recipe, has=count(input_of(e), ing.name), feeders={}}
            t.user_of[e.unit_number] = u; t.users[#t.users+1] = u; t.inputs = t.inputs + u.has
            if u.has > 0 then spoil_at(t, e, 'input', function(acc) sp.inventory(input_of(e), acc) end) end
          end
        end
      end
      local out = output_of(e)
      -- A silo's rocket: what it will launch (a platform's request, an export).
      local rocket = e.type == 'rocket-silo' and inventory(e, 'rocket_silo_rocket') or nil
      for name, t in pairs(T) do
        local n = count(out, name)
        if n > 0 then t.outputs = t.outputs + n; spot(t, e, n, 'output'); spoil_at(t, e, 'output', function(acc) sp.inventory(out, acc) end) end
        local r = count(rocket, name)
        if r > 0 then t.rockets = t.rockets + r end
      end
    end
    -- Labs: what they hold; those whose research needs a pack use it.
    if any_pack then
      local labs = lists.labs
      counted.labs = #labs
      for _, e in ipairs(labs) do
        local inv = inventory(e, 'lab_input')
        for name, t in pairs(T) do
          local n = count(inv, name)
          t.labs = t.labs + n
          if packs[name] then
            local u = {e=e, lab=true, has=n, feeders={}}
            t.user_of[e.unit_number] = u; t.users[#t.users+1] = u
          end
        end
      end
    end
    -- Logistic networks: requesters for the items and the networks' stock.
    local nets = try(function() return force.logistic_networks[surface.name] end) or {}
    local characters = {}
    for _, ag in ipairs(api.agents and try(api.agents) or {}) do
      local c = try(function() local pl = api.lookup(ag.index); return pl and pl.character end)
      if c and c.valid and c.surface == surface then characters[#characters+1] = {name=ag.name, c=c} end
    end
    local function owner_label(e)
      if e.type == 'character' then
        for _, ch in ipairs(characters) do if ch.c == e then return 'character ' .. ch.name end end
        return 'character'
      end
      return e.name
    end
    local function holds_for_request(e, item)
      if e.type == 'logistic-container' then return count(inventory(e, 'chest'), item) end
      if e.type == 'character' then
        local n = count(try(function() return e.get_main_inventory() end), item)
        local held = try(function() return e.cursor_stack end)
        if held and held.valid_for_read and held.name == item then n = n + held.count end
        return n
      end
      return try(function() return e.get_item_count(item) end) or 0
    end
    local function from_buffers(e)
      if e.type == 'logistic-container' then return try(function() return e.request_from_buffers end) == true end
      return e.type == 'character' or e.type == 'spider-vehicle' or e.type == 'car'
    end
    local function wanted(f, item)
      return f.name == item and (f.quality == nil or f.quality == 'normal') and (f.count or 0) > 0
    end
    local networks = {}
    for _, n in ipairs(nets) do
      local net
      local function this()
        if net then return net end
        net = {n=n, id=n.network_id, stock={}}
        networks[#networks+1] = net
        return net
      end
      local held_in = {}
      for _, pt in ipairs(try(function() return n.requester_points end) or {}) do
        local owner = pt.owner
        -- What its requester chests hold: robots never take from them.
        if owner and owner.valid and owner.type == 'logistic-container' and pt.mode == defines.logistic_mode.requester then
          local chest = inventory(owner, 'chest')
          for name in pairs(T) do held_in[name] = (held_in[name] or 0) + count(chest, name) end
        end
        if owner and owner.valid and not ORBIT[owner.type] and inside(owner.position) then
          for _, f in ipairs(try(function() return pt.filters end) or {}) do
            local t = T[f.name]
            if t and wanted(f, f.name) then
              local row = {pt=pt, e=owner, label=owner_label(owner), want=f.count, min=f.minimum_delivery_count, net=this(),
                have=holds_for_request(owner, f.name), incoming=0, buffers=pt.mode ~= defines.logistic_mode.buffer and from_buffers(owner)}
              for _, d in ipairs(try(function() return pt.targeted_items_deliver end) or {}) do
                if d.name == f.name then row.incoming = row.incoming + d.count end
              end
              if pt.enabled == false then row.off = 'logistics off'
              elseif try(function() return owner.status end) == (defines.entity_status or {}).disabled_by_control_behavior then row.off = 'off by its circuit condition' end
              if owner.unit_number then t.request_of[owner.unit_number] = row end
              t.rows[#t.rows+1] = row
            end
          end
        end
      end
      -- With an area, the network covering its centre is read too.
      if area and not net and try(function() return n.find_cell_closest_to(area.position).is_in_logistic_range(area.position) end) then this() end
      if net then net.in_requesters = held_in end
    end
    -- Each network that matters: its stock of the items (the engine's free
    -- counts are net of pickups robots have reserved), reservations, robots.
    local payload = (try(function() return prototypes.entity['logistic-robot'].max_payload_size end) or 1) + (force.worker_robots_storage_bonus or 0)
    for _, net in ipairs(networks) do
      local n = net.n
      for name in pairs(T) do
        local s = try(function() return n.get_supply_counts(name) end) or {}
        net.stock[name] = {free_main=math.max(0, (s['active-provider'] or 0) + (s['passive-provider'] or 0)) + math.max(0, s.storage or 0),
          free_buffer=math.max(0, s.buffer or 0), raw={providers=(s['active-provider'] or 0) + (s['passive-provider'] or 0), storage=s.storage or 0, buffer=s.buffer or 0},
          reserved={providers=0, storage=0, buffer=0}, in_requesters=net.in_requesters[name] or 0, flight=0, due=0}
      end
      local seen = {}
      for _, list in ipairs({try(function() return n.provider_points end) or {}, try(function() return n.storage_points end) or {}}) do
        for _, pt in ipairs(list) do
          local owner = pt.owner
          local key = owner and owner.valid and (tostring(owner.unit_number) .. ':' .. tostring(pt.logistic_member_index))
          if key and not seen[key] then
            seen[key] = true
            local group = pt.mode == defines.logistic_mode.storage and 'storage' or pt.mode == defines.logistic_mode.buffer and 'buffer' or 'providers'
            for _, r in ipairs(try(function() return pt.targeted_items_pickup end) or {}) do
              local st = net.stock[r.name]
              if st then st.reserved[group] = st.reserved[group] + r.count end
            end
          end
        end
      end
      for name, st in pairs(net.stock) do
        st.held = {providers=st.raw.providers + st.reserved.providers, storage=st.raw.storage + st.reserved.storage, buffer=st.raw.buffer + st.reserved.buffer}
        st.held_main = math.max(0, st.held.providers) + math.max(0, st.held.storage)
        st.held_buffer = math.max(0, st.held.buffer)
        for _, row in ipairs(T[name].rows) do if row.net == net then st.due = st.due + row.incoming end end
      end
      local charging, waiting, roboports, mobile = 0, 0, 0, nil
      local box
      for _, c in ipairs(try(function() return n.cells end) or {}) do
        charging = charging + (c.charging_robot_count or 0); waiting = waiting + (c.to_charge_robot_count or 0)
        local o = c.owner
        if c.mobile then mobile = mobile or o
        elseif o and o.valid then
          roboports = roboports + 1
          local x, y = o.position.x, o.position.y
          box = box or {x0=x, y0=y, x1=x, y1=y}
          box.x0, box.y0, box.x1, box.y1 = math.min(box.x0, x), math.min(box.y0, y), math.max(box.x1, x), math.max(box.y1, y)
        end
      end
      local out, carrying = 0, 0
      for _, r in ipairs(try(function() return n.logistic_robots end) or {}) do
        out = out + 1
        local inv = inventory(r, 'robot_cargo')
        if inv and not try(function() return inv.is_empty() end) then carrying = carrying + 1 end
      end
      net.robots = {all=n.all_logistic_robots or 0, idle=n.available_logistic_robots or 0, out=out, carrying=carrying,
        charging=charging, waiting=waiting, payload=payload}
      net.roboports, net.box, net.mobile = roboports, box, mobile
    end
    local by_id = {}
    for _, net in ipairs(networks) do by_id[net.id] = net end
    -- Chests: by kind; requesters' stock robots never take; requests outside
    -- every network.
    local chests = lists.chests
    counted.chests = #chests
    for _, e in ipairs(chests) do
      local kind = kind_of(e)
      local main = inventory(e, MAIN[e.type] or 'chest')
      local trash = e.type == 'logistic-container' and inventory(e, 'logistic_container_trash') or nil
      local point, id, filters
      if kind == 'requester' or kind == 'buffer' then
        point = try(function() return e.get_logistic_point(defines.logistic_member_index.logistic_container) end)
        id = point and try(function() return point.logistic_network.network_id end)
        filters = point and not id and try(function() return point.filters end) or {}
      end
      for name, t in pairs(T) do
        local n = count(main, name) + count(trash, name)
        if n > 0 then
          bump(t.kinds, kind, n)
          t.chests[#t.chests+1] = {n=n, e=e, kind=kind}
          spot(t, e, n, kind)
          spoil_at(t, e, kind, function(acc) sp.inventory(main, acc); if trash then sp.inventory(trash, acc) end end)
        end
        for _, f in ipairs(filters or {}) do
          if wanted(f, name) then
            local row = {pt=point, e=e, label=e.name, want=f.count, have=count(main, name), incoming=0, off='not in a logistic network'}
            t.orphans[#t.orphans+1] = row
            if e.unit_number then t.request_of[e.unit_number] = row end
          end
        end
      end
    end
    -- Belts.
    local belts = lists.belts
    counted.belts = #belts
    counted.belts_total = seen.belts or #belts
    for _, e in ipairs(belts) do
      local held = {}
      belt_counts(e, names, single, held)
      for name, n in pairs(held) do local t = T[name]; t.belts = t.belts + n; spot(t, e, n, 'belt'); spoil_at(t, e, 'belt', function(acc) sp.belt(e, acc) end) end
    end
    -- Inserters: what their hands hold, the ones feeding users and taking
    -- from makers.
    local want_targets = false
    for _, t in pairs(T) do if #t.users > 0 or #t.makers > 0 then want_targets = true end end
    local inserters = lists.inserters
    counted.inserters = #inserters
    local function visit(e)
      local s = e.held_stack
      if s.valid_for_read and T[s.name] then
        local t = T[s.name]; t.hands = t.hands + s.count; spot(t, e, s.count, 'hand')
        spoil_at(t, e, 'inserter hand', function(acc) sp.add(acc, s) end)
      end
      if not want_targets then return end
      local drop, pick = e.drop_target, e.pickup_target
      local drop_unit, pick_unit = drop and drop.unit_number, pick and pick.unit_number
      local status
      for name, t in pairs(T) do
        local u = drop_unit and t.user_of[drop_unit]
        if u then
          status = status or api.status_name(e) or 'unknown'
          local f = t.feeders
          f.n = f.n + 1; bump(f.states, status)
          local has = 0
          if pick then
            if BELT[pick.type] then local held = {}; belt_counts(pick, names, name, held); has = held[name] or 0
            elseif pick.type == 'lab' then has = count(inventory(pick, 'lab_input'), name)
            elseif pick.type == 'assembling-machine' or pick.type == 'furnace' then has = count(output_of(pick), name)
            else has = count(inventory(pick, MAIN[pick.type] or 'chest'), name) end
          end
          if status == 'waiting_for_source_items' then
            if has > 0 then f.with = f.with + 1 else bump(f.without, pick and (pick.type == 'lab' and 'lab' or pick.name) or 'ground') end
          end
          u.feeders[#u.feeders+1] = {e=e, source=pick, has=has, status=status}
        end
        if pick_unit and t.maker_of[pick_unit] then
          status = status or api.status_name(e) or 'unknown'
          local k = t.takers
          k.n = k.n + 1; bump(k.states, status)
          if FULL[status] then bump(k.into, drop and drop.name or 'ground') end
        end
      end
    end
    for _, e in ipairs(inserters) do pcall(visit, e) end
    -- Robots carrying the items; per network what is in flight.
    local robots = lists.robots
    counted.robots = #robots
    for _, r in ipairs(robots) do
      local inv = inventory(r, 'robot_cargo')
      if inv and not try(function() return inv.is_empty() end) then
        local id
        for name, t in pairs(T) do
          local n = count(inv, name)
          if n > 0 then
            if inside(r.position) then t.robots = t.robots + n end
            id = id or try(function() return r.logistic_network.network_id end) or false
            if id and by_id[id] then by_id[id].stock[name].flight = by_id[id].stock[name].flight + n end
          end
        end
      end
    end
    -- The team's characters.
    for _, ch in ipairs(characters) do
      if inside(ch.c.position) then
        for name, t in pairs(T) do
          local n = try(function() return ch.c.get_item_count(name) end) or 0
          if n > 0 then
            t.carried = t.carried + n; t.characters[#t.characters+1] = ch.name .. ' ' .. n
            spoil_at(t, ch.c, 'carried by ' .. ch.name, function(acc) sp.inventory(ch.c.get_main_inventory(), acc) end)
          end
        end
      end
    end
    for _, t in pairs(T) do M.classify(t) end
    return {items=T, networks=networks, counted=counted, area=area, crafters=crafters, miners=lists.miners}
  end


  -- Each requester's state: met, on_the_way (incoming covers it), or unmet
  -- with the reason (from the network's stock and robots).
  function M.classify(t)
    for _, row in ipairs(t.rows) do
      local st, robots = row.net.stock[t.item], row.net.robots
      local short = row.want - row.have - row.incoming
      if row.have >= row.want then row.state = 'met'
      elseif short <= 0 then row.state = 'on_the_way'
      else
        row.state, row.short = 'unmet', short
        local free = st.free_main + (row.buffers and st.free_buffer or 0)
        local held = st.held_main + (row.buffers and st.held_buffer or 0)
        if row.off then row.why = row.off
        elseif free > 0 and robots.idle == 0 then row.why = 'no idle robots'
        elseif free > 0 and row.min and row.min > short then row.why = 'short ' .. short .. ', below its minimum delivery ' .. row.min
        elseif free > 0 then row.why = 'free stock and idle robots'
        elseif held > 0 then row.why = held == 1 and 'the 1 held is reserved for other deliveries' or 'all ' .. held .. ' held are reserved for other deliveries'
        elseif not row.buffers and st.held_buffer > 0 then row.why = 'only buffer chests hold it (this requester does not take from buffers)'
        else row.why = 'none in providers or storage' end
      end
    end
    for _, row in ipairs(t.orphans) do
      row.state = row.have >= row.want and 'met' or 'unmet'
      row.short, row.why = row.want - row.have, row.off
    end
  end

  local function row_text(row)
    local text = string.format('%s %s %d/%d', at(row.e.position), row.label, math.floor(row.have), math.floor(row.want))
    if row.incoming > 0 then text = text .. ' (+' .. row.incoming .. ' coming)' end
    if row.why then text = text .. ': ' .. row.why end
    return text
  end
  M.row_text = row_text
  -- One line per network (stock, flight, robots, requesters by state and
  -- reason) and its unmet requesters, most short first (nearest first with
  -- an area).
  function M.network_lines(t, scan)
    local lines = {}
    for _, net in ipairs(scan.networks) do
      local st, r = net.stock[t.item], net.robots
      local rows, met, way, unmet, short, why = {}, 0, 0, 0, 0, {}
      for _, row in ipairs(t.rows) do
        if row.net == net then
          if row.state == 'met' then met = met + 1 elseif row.state == 'on_the_way' then way = way + 1
          else unmet = unmet + 1; short = short + row.short; bump(why, row.why); rows[#rows+1] = row end
        end
      end
      local place = net.mobile and ('personal roboport at ' .. at(net.mobile.position))
        or net.box and string.format('%d roboports %s-%s', net.roboports, at({x=net.box.x0, y=net.box.y0}), at({x=net.box.x1, y=net.box.y1})) or 'no roboports'
      local function part(label, held, reserved)
        if held <= 0 and reserved <= 0 then return label .. ' 0' end
        return string.format('%s %d (%d reserved, %d free)', label, math.max(0, held), reserved, math.max(0, held - reserved))
      end
      local text = string.format('network %d (%s): %s, %s, %s', net.id, place, part('providers', st.held.providers, st.reserved.providers),
        part('storage', st.held.storage, st.reserved.storage), part('buffers', st.held.buffer, st.reserved.buffer))
      if st.in_requesters > 0 then text = text .. ', in its requester chests ' .. st.in_requesters end
      text = text .. string.format('; robots carry %d, %d due at requesters', st.flight, st.due)
      text = text .. string.format('; logistic robots %d: %d idle, %d out (%d carrying), %d charging, %d waiting to charge, %d items each',
        r.all, r.idle, r.out, r.carrying, r.charging, r.waiting, r.payload)
      local total = met + way + unmet
      if total > 0 then
        text = text .. string.format('; requesters %d: %d met, %d on the way, %d unmet', total, met, way, unmet)
        if unmet > 0 then text = text .. string.format(', %d items short (reasons: %s)', short, short_list(why, 8, '; ')) end
      else text = text .. '; no requester for it here' end
      lines[#lines+1] = text
      if scan.area then
        local c = scan.area.position
        table.sort(rows, function(x, y) local dx, dy = (x.e.position.x - c.x) ^ 2 + (x.e.position.y - c.y) ^ 2, (y.e.position.x - c.x) ^ 2 + (y.e.position.y - c.y) ^ 2; if dx ~= dy then return dx < dy end return x.short > y.short end)
      else
        table.sort(rows, function(x, y) if x.short ~= y.short then return x.short > y.short end if x.e.position.x ~= y.e.position.x then return x.e.position.x < y.e.position.x end return x.e.position.y < y.e.position.y end)
      end
      for i = 1, math.min(TOP_UNMET, #rows) do lines[#lines+1] = '  unmet ' .. row_text(rows[i]) end
      if #rows > TOP_UNMET then lines[#lines+1] = '  ' .. (#rows - TOP_UNMET) .. ' more unmet' end
    end
    local orphans = {}
    for _, row in ipairs(t.orphans) do if row.state == 'unmet' then orphans[#orphans+1] = row end end
    if #orphans > 0 then
      lines[#lines+1] = #orphans .. ' requesters outside every logistic network'
      for i = 1, math.min(TOP_UNMET, #orphans) do lines[#lines+1] = '  unmet ' .. row_text(orphans[i]) end
    end
    return lines
  end

  -- Where the item sits: the total and each kind of place that holds it.
  function M.where(t)
    local parts, total = {}, 0
    local function add(label, n) if n > 0 then parts[#parts+1] = label .. ' ' .. n; total = total + n end end
    add('belts', t.belts)
    for _, kind in ipairs(KIND_ORDER) do add(KIND_LABEL[kind], t.kinds[kind] or 0) end
    add('machine outputs', t.outputs)
    add('users\' inputs', t.inputs)
    add('silo rockets', t.rockets)
    add('labs', t.labs)
    add('inserter hands', t.hands)
    add('robots', t.robots)
    if t.carried > 0 then parts[#parts+1] = 'characters ' .. t.carried .. ' (' .. table.concat(t.characters, ', ') .. ')'; total = total + t.carried end
    return total, parts
  end
  -- The largest chests, with what a requester or buffer chest asks for.
  function M.top_chests(t, limit)
    table.sort(t.chests, function(x, y) if x.n ~= y.n then return x.n > y.n end return x.e.position.x < y.e.position.x end)
    local out = {}
    for i = 1, math.min(limit or TOP_CHESTS, #t.chests) do
      local c = t.chests[i]
      local text = string.format('%s %s %d', at(c.e.position), c.e.name, c.n)
      if c.kind == 'requester' or c.kind == 'buffer' then
        local row = c.e.unit_number and t.request_of[c.e.unit_number]
        local note = not row and request_note(c.e, t.item)
        text = text .. (row and (' (requests ' .. row.want .. ')') or ' (no request for it' .. (note and ': ' .. note or '') .. ')')
      end
      out[i] = text
    end
    return out
  end
  -- The nearest place holding the item to a position, other than the entity itself.
  local function nearest(t, e)
    local best, bd
    for _, s in ipairs(t.spots) do
      if s.unit ~= e.unit_number then
        local d = (s.position.x - e.position.x) ^ 2 + (s.position.y - e.position.y) ^ 2
        if not bd or d < bd then best, bd = s, d end
      end
    end
    return best and string.format('nearest %s: %s %s %d tiles', t.item, best.name, at(best.position), math.floor(math.sqrt(bd) + 0.5))
  end
  -- What a machine lacks for its next craft (a lab: the needed packs it has none of).
  local function missing(e, u, packs)
    local out = {}
    if u.lab then
      local inv = inventory(e, 'lab_input')
      for name in pairs(packs or {}) do if count(inv, name) == 0 then out[#out+1] = name end end
      table.sort(out)
      return out
    end
    local inv = input_of(e)
    for _, ing in ipairs(u.recipe.ingredients or {}) do
      if ing.type == 'fluid' then
        local n = try(function() return e.get_fluid_count(ing.name) end)
        if n and n < ing.amount then out[#out+1] = ing.name end
      elseif count(inv, ing.name) < ing.amount then out[#out+1] = ing.name end
    end
    return out
  end
  -- Machines by status (missing ingredients named), recipes, and the worst
  -- with positions: no power, then missing this item, other shortages,
  -- output full, low power, anything else not working.
  function M.machines(t, list, role, scan, packs)
    if #list == 0 then return nil end
    -- by_name: the machines counted, by name (Astra, 06:19: a line naming only the worst three read as "7 AM2" with an
    -- electromagnetic plant among the makers; every crafter type counts: assemblers, furnaces, silos, and Space Age's
    -- electromagnetic plants, foundries, cryogenic plants, biochambers, crushers and recyclers, which are of those types).
    local states, short, recipes, ranked, by_name = {}, {}, {}, {}, {}
    for _, u in ipairs(list) do
      local e = u.e
      local status = api.status_name(e) or 'unknown'
      bump(states, status)
      bump(by_name, e.name)
      bump(recipes, u.lab and 'labs' or u.recipe.name)
      if status ~= 'working' then
        local lacks = SHORT[status] and missing(e, u, packs) or {}
        for _, name in ipairs(lacks) do bump(short, 'missing ' .. name) end
        local lacks_it = false
        for _, name in ipairs(lacks) do if name == t.item then lacks_it = true end end
        local rank = status == 'no_power' and 1 or (SHORT[status] and lacks_it) and 2 or SHORT[status] and 3 or FULL[status] and 4 or status == 'low_power' and 5 or 6
        ranked[#ranked+1] = {u=u, e=e, status=status, lacks=lacks, rank=rank}
      end
    end
    local parts = {}
    local order = {}
    for status, n in pairs(states) do order[#order+1] = {s=status, n=n} end
    table.sort(order, function(x, y) if x.s == 'working' then return y.s ~= 'working' end if y.s == 'working' then return false end if x.n ~= y.n then return x.n > y.n end return x.s < y.s end)
    for _, o in ipairs(order) do
      local text = o.n .. ' ' .. o.s
      if SHORT[o.s] and next(short) then text = text .. ' (' .. short_list(short, 6) .. ')'; short = {} end
      parts[#parts+1] = text
    end
    if (states.working or 0) == 0 then table.insert(parts, 1, '0 working') end
    local line = string.format('%d %s (%s): %s', #list, role, short_list(by_name, 4), table.concat(parts, ', '))
    if role ~= 'labs' then line = line .. '; ' .. (role == 'users' and 'for ' or 'recipes ') .. short_list(recipes, 4) end
    local c = scan.area and scan.area.position
    table.sort(ranked, function(x, y)
      if x.rank ~= y.rank then return x.rank < y.rank end
      if (x.u.has or 0) ~= (y.u.has or 0) then return (x.u.has or 0) < (y.u.has or 0) end
      if c then
        local dx, dy = (x.e.position.x - c.x) ^ 2 + (x.e.position.y - c.y) ^ 2, (y.e.position.x - c.x) ^ 2 + (y.e.position.y - c.y) ^ 2
        if dx ~= dy then return dx < dy end
      end
      if x.e.position.x ~= y.e.position.x then return x.e.position.x < y.e.position.x end
      return x.e.position.y < y.e.position.y
    end)
    local worst = {}
    for i = 1, math.min(WORST, #ranked) do
      local w = ranked[i]
      local text = at(w.e.position) .. ' ' .. w.e.name .. ' ' .. w.status
      if #w.lacks > 0 then text = text .. ' (missing ' .. table.concat(w.lacks, ', ') .. ')' end
      if role ~= 'makers' then
        text = text .. '; holds ' .. (w.u.has or 0)
        -- The feeder that carries this item: its source asks for it or
        -- holds it (a waiting one first); else none of them does.
        local feeders = w.u.feeders or {}
        local fed, score
        for _, f in ipairs(feeders) do
          local src = f.source
          local v = (src and src.unit_number and t.request_of[src.unit_number] and 4 or 0) + (f.has > 0 and 2 or 0) + (f.status ~= 'working' and 1 or 0)
          if not fed or v > score then fed, score = f, v end
        end
        if not fed then text = text .. '; no inserter feeds it'
        elseif score < 2 then
          local from, note = {}, nil
          for _, f in ipairs(feeders) do
            local src = f.source
            bump(from, src and (src.type == 'lab' and 'lab' or src.name) or 'ground')
            local why = not note and src and src.type == 'logistic-container' and request_note(src, t.item)
            if why then note = string.format('%s %s: %s', src.name, at(src.position), why) end
          end
          text = text .. string.format('; none of its %d feeding inserters takes from a place holding or requesting it (%s)', #feeders, short_list(from, 4))
          if note then text = text .. '; ' .. note end
        else
          local src = fed.source
          local req = src and src.unit_number and t.request_of[src.unit_number]
          if req then text = text .. '; fed from ' .. row_text(req) .. (req.state == 'met' and ' (met)' or req.state == 'on_the_way' and ' (on the way)' or '')
          else text = text .. string.format('; fed from %s %s holding %d', src.name, at(src.position), fed.has) end
          if fed.status ~= 'working' then text = text .. ', inserter ' .. fed.status end
        end
        local near = nearest(t, w.e)
        if near then text = text .. '; ' .. near end
      end
      worst[i] = text
    end
    return line, worst
  end
  -- The inserters feeding users: by status, and what the waiting ones' sources hold.
  function M.feeders(t, noun)
    noun = noun or 'users'
    local f = t.feeders
    local without = 0
    for _, u in ipairs(t.users) do if #u.feeders == 0 then without = without + 1 end end
    if f.n == 0 then return #t.users > 0 and string.format('no inserter feeds the %d %s', #t.users, noun) or nil end
    local parts = {}
    for _, status in ipairs({'working', 'waiting_for_source_items', 'waiting_for_space_in_destination', 'disabled_by_control_behavior'}) do
      if f.states[status] then
        local text = f.states[status] .. ' ' .. status
        if status == 'waiting_for_source_items' then
          local src = {}
          if next(f.without) then src[#src+1] = 'sources with none of it: ' .. short_list(f.without, 5) end
          if f.with > 0 then src[#src+1] = f.with .. ' sources hold it' end
          if #src > 0 then text = text .. ' (' .. table.concat(src, '; ') .. ')' end
        end
        parts[#parts+1] = text
      end
    end
    local rest = {}
    for status, n in pairs(f.states) do
      if status ~= 'working' and status ~= 'waiting_for_source_items' and status ~= 'waiting_for_space_in_destination' and status ~= 'disabled_by_control_behavior' then rest[status] = n end
    end
    if next(rest) then parts[#parts+1] = short_list(rest, 4) end
    local line = string.format('%d inserters feed the %s: %s', f.n, noun, table.concat(parts, ', '))
    if without > 0 then line = line .. string.format('; %d %s have no inserter feeding them', without, noun) end
    return line
  end
  function M.takers(t)
    local k = t.takers
    if k.n == 0 then return #t.makers > 0 and string.format('no inserter takes from the %d makers', #t.makers) or nil end
    local parts = {}
    if k.states.working then parts[#parts+1] = k.states.working .. ' working' end
    local rest = {}
    for status, n in pairs(k.states) do if status ~= 'working' then rest[status] = n end end
    if next(rest) then parts[#parts+1] = short_list(rest, 4) end
    local line = string.format('%d inserters take from the makers: %s', k.n, table.concat(parts, ', '))
    if next(k.into) then line = line .. ' (output side full: into ' .. short_list(k.into, 4) .. ')' end
    return line
  end
  function M.counted(scan)
    local c = scan.counted
    local parts = {c.crafters .. ' crafters'}
    if c.labs then parts[#parts+1] = c.labs .. ' labs' end
    parts[#parts+1] = c.chests .. ' chests'
    parts[#parts+1] = c.belts .. ' of ' .. c.belts_total .. ' belts'
    parts[#parts+1] = c.inserters .. ' inserters'
    parts[#parts+1] = c.robots .. ' robots'
    parts[#parts+1] = #scan.networks .. ' logistic networks'
    local full = {}
    if c.crafters >= MAX_MACHINES then full[#full+1] = 'crafters' end
    if (c.labs or 0) >= MAX_LABS then full[#full+1] = 'labs' end
    if c.chests >= MAX_CHESTS then full[#full+1] = 'chests' end
    if c.belts >= MAX_BELTS then full[#full+1] = 'belts' end
    if c.inserters >= MAX_INSERTERS then full[#full+1] = 'inserters' end
    if c.robots >= MAX_ROBOTS then full[#full+1] = 'robots' end
    if c.found >= MAX_FOUND then full[#full+1] = MAX_FOUND .. ' entities' end
    local text = table.concat(parts, ', ')
    if #full > 0 then text = text .. ' (stopped at the cap: ' .. table.concat(full, ', ') .. ')' end
    return text
  end
  -- Per network, its requesters for the item in one line (science's reach).
  function M.network_brief(t, scan)
    local out = {}
    for _, net in ipairs(scan.networks) do
      local met, way, unmet, why = 0, 0, 0, {}
      for _, row in ipairs(t.rows) do
        if row.net == net then
          if row.state == 'met' then met = met + 1 elseif row.state == 'on_the_way' then way = way + 1 else unmet = unmet + 1; bump(why, row.why) end
        end
      end
      if met + way + unmet > 0 then
        local st, r = net.stock[t.item], net.robots
        local text = string.format('network %d: providers and storage hold %d (%d free), %d of %d logistic robots idle; its requesters for it: %d met, %d on the way, %d unmet',
          net.id, st.held_main, st.free_main, r.idle, r.all, met, way, unmet)
        if unmet > 0 then text = text .. ' (' .. short_list(why, 4, '; ') .. ')' end
        out[#out+1] = text
      end
    end
    local orphans = 0
    for _, row in ipairs(t.orphans) do if row.state == 'unmet' then orphans = orphans + 1 end end
    if orphans > 0 then out[#out+1] = orphans .. ' requesters for it outside every logistic network' end
    return out
  end
  -- science's second line per pack: where else it sits (chests by kind,
  -- inserter hands, robots), why it does not reach the labs (the inserters
  -- at its makers and at the labs, its requesters) and the worst lab.
  function M.reach(t, scan, packs)
    local parts, kinds = {}, {}
    for _, kind in ipairs(KIND_ORDER) do if (t.kinds[kind] or 0) > 0 then kinds[#kinds+1] = KIND_LABEL[kind] .. ' ' .. t.kinds[kind] end end
    if #kinds > 0 then parts[#parts+1] = 'in ' .. table.concat(kinds, ', ') end
    if t.hands > 0 then parts[#parts+1] = 'inserter hands ' .. t.hands end
    if t.robots > 0 then parts[#parts+1] = 'robots carry ' .. t.robots end
    parts[#parts+1] = M.takers(t)
    parts[#parts+1] = M.feeders(t, 'labs')
    for _, line in ipairs(M.network_brief(t, scan)) do parts[#parts+1] = line end
    local _, worst = M.machines(t, t.users, 'labs', scan, packs)
    if worst and worst[1] then parts[#parts+1] = 'worst lab ' .. worst[1] end
    return #parts > 0 and table.concat(parts, '; ') or nil
  end
  -- science's chain (Sonnet, shift09: "I spend most cycles diagnosing that by
  -- hand"): a pack's recipe tree down to what no crafter makes (ores, crude
  -- oil, water), each step with made and used per minute (the force's 10
  -- minute statistics) and its makers by state, naming what the short ones
  -- lack. The line follows the ingredient most of a step's makers lack while
  -- most of them lack one, and ends at the first step whose makers mostly do
  -- not. Built from the scan's crafters: no other find.
  local CHAIN_NODES, CHAIN_DEPTH, MINER_MEMO = 40, 10, 8192
  -- What a miner makes (Grok, 04:55: the chain said stone has no assembler; mining drills make it): a mining drill or
  -- pumpjack, its mining target's products and the fluid that resource needs (sulfuric acid for uranium); an offshore
  -- pump, the fluid it pumps. A drill whose resource ran out has no target: what it mined last is kept in storage
  -- (chain_miners, by unit number, when the harness passes its state).
  local function miner_products(e)
    local names, fluid = {}, nil
    if e.type == 'offshore-pump' then
      local name = try(function() local f = e.fluidbox[1]; return f and f.name end)
        or try(function() local f = e.fluidbox.get_filter(1); return f and f.name end)
        or try(function() return e.prototype.fluid.name end)
      if name then names[1] = name end
    else
      local res = try(function() return e.mining_target end)
      local props = res and try(function() return res.prototype.mineable_properties end)
      for _, p in ipairs(props and props.products or {}) do names[#names+1] = p.name end
      fluid = props and props.required_fluid
    end
    local st = api.state and api.state()
    local unit = st and try(function() return e.unit_number end)
    if unit then
      st.chain_miners = st.chain_miners or {n=0, by={}}
      local memo = st.chain_miners
      if #names > 0 then
        if not memo.by[unit] then memo.n = memo.n + 1 end
        if memo.n > MINER_MEMO then memo.by, memo.n = {}, 1 end
        memo.by[unit] = {names=names, fluid=fluid}
      elseif memo.by[unit] then names, fluid = memo.by[unit].names, memo.by[unit].fluid end
    end
    return names, fluid
  end
  local MINER_STATE = {working='working', waiting_for_space_in_destination='output full', full_output='output full',
    no_minable_resources='no resource left'}
  function M.chain(scan, force, surface, pack)
    local by_product = scan.by_product
    if not by_product then
      by_product = {}
      for _, e in ipairs(scan.crafters or {}) do
        if e.valid then
          local recipe = recipe_of(e)
          for _, prod in ipairs(recipe and recipe.products or {}) do
            local list = by_product[prod.name] or {}
            by_product[prod.name] = list
            list[#list+1] = {e=e, recipe=recipe}
          end
        end
      end
      scan.by_product = by_product
    end
    if scan.miners and not scan.miners_in then
      scan.miners_in = true
      for _, e in ipairs(scan.miners) do
        if e.valid then
          local names, fluid = miner_products(e)
          for _, name in ipairs(names) do
            local list = by_product[name] or {}
            by_product[name] = list
            list[#list+1] = {e=e, miner=true, fluid=fluid}
          end
        end
      end
    end
    local items = try(function() return force.get_item_production_statistics(surface) end)
    local fluids = try(function() return force.get_fluid_production_statistics(surface) end)
    local function per_min(name, category)
      local stats = prototypes.fluid and prototypes.fluid[name] and fluids or items
      local n = stats and try(function()
        return stats.get_flow_count{name=name, category=category, precision_index=defines.flow_precision_index.ten_minutes, count=true}
      end)
      return n and math.floor(n / 10 + 0.5) or 0
    end
    local nodes, seen = {}, {}
    local function visit(name, depth)
      if seen[name] or #nodes >= CHAIN_NODES or depth > CHAIN_DEPTH then return end
      seen[name] = true
      local makers = by_product[name] or {}
      local node = {item=name, depth=depth, made=per_min(name, 'input'), used=per_min(name, 'output'), makers=#makers, working=0, states={}, lack={},
        miners=0, miner_names={}, miner_states={}, outputs={}}
      nodes[#nodes+1] = node
      local children, child_seen = {}, {}
      for _, m in ipairs(makers) do
        local status = api.status_name(m.e) or 'unknown'
        if status == 'working' then node.working = node.working + 1 else bump(node.states, status) end
        if m.miner then
          -- A miner: its name, its state in words, what it puts into (a chest, a belt; nothing for a pump's pipe).
          node.miners = node.miners + 1
          bump(node.miner_names, m.e.name)
          bump(node.miner_states, MINER_STATE[status] or status)
          if m.e.type == 'mining-drill' and not (prototypes.fluid and prototypes.fluid[name]) then
            bump(node.outputs, try(function() local t = m.e.drop_target; return t and t.name end) or 'the ground')
          end
          if m.fluid then
            if status == 'missing_required_fluid' then bump(node.lack, m.fluid) end
            if not child_seen[m.fluid] then child_seen[m.fluid] = true; children[#children+1] = m.fluid end
          end
        else
          if SHORT[status] then
            for _, ing in ipairs(missing(m.e, m, nil)) do bump(node.lack, ing) end
          end
          for _, ing in ipairs(m.recipe.ingredients or {}) do
            if not child_seen[ing.name] then child_seen[ing.name] = true; children[#children+1] = ing.name end
          end
        end
      end
      node.children = children
      for _, child in ipairs(children) do visit(child, depth + 1) end
    end
    visit(pack, 0)
    local by_item = {}
    for _, n in ipairs(nodes) do by_item[n.item] = n end
    local function states_text(n)
      local parts = {}
      for s, k in pairs(n.states) do parts[#parts+1] = {s=s, k=k} end
      table.sort(parts, function(x, y) if x.k ~= y.k then return x.k > y.k end return x.s < y.s end)
      local out = {}
      for i, p in ipairs(parts) do out[i] = p.k .. ' ' .. p.s end
      return table.concat(out, ', ')
    end
    -- Counts as 'k name' text, the largest first.
    local function tally(map)
      local parts = {}
      for s, k in pairs(map) do parts[#parts+1] = {s=s, k=k} end
      table.sort(parts, function(x, y) if x.k ~= y.k then return x.k > y.k end return x.s < y.s end)
      local out = {}
      for i, p in ipairs(parts) do out[i] = p.k .. ' ' .. p.s end
      return table.concat(out, ', ')
    end
    -- One step's words: its makers and what most of them lack, then made and used.
    local function step(n)
      local top, top_n
      for ing, k in pairs(n.lack) do if not top_n or k > top_n or (k == top_n and ing < top) then top, top_n = ing, k end end
      local text
      if n.makers == 0 then text = string.format('%s: no assembler, furnace, silo, mining drill or pump makes it', n.item)
      elseif top and top_n * 2 > n.makers then text = string.format('%s: %d of %d makers lack %s', n.item, top_n, n.makers, top)
      elseif n.miners > 0 then
        -- 'stone: 8 electric-mining-drill (6 working, 2 output full) into 5 transport-belt, 3 wooden-chest'
        local out = tally(n.outputs)
        text = string.format('%s: %s (%s)%s', n.item, tally(n.miner_names), tally(n.miner_states), out ~= '' and ' into ' .. out or '')
        if n.makers > n.miners then
          text = text .. string.format('; %d other makers', n.makers - n.miners)
        end
      else
        local other = states_text(n)
        text = string.format('%s: %d of %d working%s', n.item, n.working, n.makers, other ~= '' and ' (' .. other .. ')' or '')
      end
      return text .. string.format(', made %d/min, used %d/min', n.made, n.used), top and top_n * 2 > n.makers and top or nil
    end
    local parts, at_item, walked, path = {}, pack, {}, {}
    while at_item and by_item[at_item] and not walked[at_item] do
      walked[at_item] = true
      path[#path+1] = at_item
      local text, next_item = step(by_item[at_item])
      parts[#parts+1] = text
      at_item = next_item
    end
    local rows = {}
    for _, n in ipairs(nodes) do
      rows[#rows+1] = {item=n.item, depth=n.depth, made_per_min=n.made, used_per_min=n.used, makers=n.makers, working=n.working,
        states=next(n.states) and n.states or nil, lacking=next(n.lack) and n.lack or nil,
        miners=n.miners > 0 and n.miners or nil, miner_states=next(n.miner_states) and n.miner_states or nil,
        outputs=next(n.outputs) and n.outputs or nil}
    end
    -- path: the items the line walked; last: its last step (where the shortage starts).
    return {line='chain: ' .. table.concat(parts, '; '), tree=rows, cut=#nodes >= CHAIN_NODES or nil, path=path, last=parts[#parts]}
  end
  local function packs_of(force)
    local tech, packs = force.current_research, {}
    for _, ing in ipairs(tech and tech.research_unit_ingredients or {}) do packs[ing.name] = true end
    return packs
  end
  M.packs_of = packs_of
  -- For trace.lua: the same inventory reads.
  M.helpers = {inventory=inventory, count=count, input_of=input_of, output_of=output_of, recipe_of=recipe_of, kind_of=kind_of,
    main=function(e) return inventory(e, MAIN[e.type] or 'chest') end}

  M.schema = {supply = {item='item name', surface='optional surface name (default yours)', near='optional {x,y}: only this area (machines, chests, belts, inserters, requesters); network totals stay whole',
    radius='with near: 1..512 tiles (default 64)',
    returns='one read, the same for everyone: flow (made/used in 10 min); where (the total and each place: belts, chests by kind, landing pads, platform hubs, vehicles, machine outputs, users\' inputs, silo rockets, labs, inserter hands, robots, characters); chests (largest 5; what a requester or buffer chest asks for); networks (per logistic network with a requester for it: providers, storage and buffers held, reserved and free, its requester chests\' stock, robots carrying it, due at requesters, logistic robots idle/out/carrying/charging, requesters met/on the way/unmet with reasons; then up to 5 unmet with position, have/want and reason: not in a logistic network, logistics off, off by its circuit condition, no idle robots, all N held are reserved, only buffer chests hold it, none in providers or storage, below its minimum delivery, free stock and idle robots); makers, users (assemblers, furnaces, silos; labs for packs the research needs: counts by status with the missing ingredients); makers_worst, users_worst (3 with positions; a user\'s stock, the feeder carrying it and that source\'s request, the nearest stock); feeders (inserters into users by status, what the waiting ones\' sources hold); takers (inserters out of makers); counted; spoil (a spoilable item: the first stack to spoil, where and when, % spoiled, how many of those read spoil within 5 min); hatch instead for an item that hatches into enemies when it spoils (pentapod-egg, biter-egg): into what, the first to hatch and when. Read only'}}

  function M.supply(p, a)
    local item = a.item
    assert(type(item) == 'string' and prototypes.item[item], 'item must be an item name (advanced-circuit, electronic-circuit, ...)')
    local surface = p.surface
    if a.surface ~= nil then
      assert(type(a.surface) == 'string', 'surface must be a surface name')
      surface = game.get_surface(a.surface)
      assert(surface, 'no surface ' .. a.surface)
    end
    local area
    if a.near ~= nil then area = {position=api.position(a.near), radius=api.integer(a.radius, 64, 1, 512, 'radius')}
    else assert(a.radius == nil, 'radius needs near {x,y}') end
    local force = p.force
    local key = string.format('supply|%s|%s|%s|%s', tostring(surface.index or surface.name), force.name, item,
      area and string.format('%g,%g,%g', area.position.x, area.position.y, area.radius) or '')
    return M.reuse(key, function() return M.supply_fresh(surface, force, item, area) end)
  end
  function M.supply_fresh(surface, force, item, area)
    local packs = packs_of(force)
    local scan = M.scan(surface, force, {[item]=true}, {area=area, packs=packs})
    local t = scan.items[item]
    local stats = try(function() return force.get_item_production_statistics(surface) end)
    local function flow(category)
      local n = stats and try(function() return stats.get_flow_count{name=item, category=category, precision_index=defines.flow_precision_index.ten_minutes, count=true} end)
      return n and math.floor(n + 0.5) or 0
    end
    local total, parts = M.where(t)
    local out = {item=item, surface=surface.name, area=area and (at(area.position) .. ' radius ' .. area.radius) or nil,
      flow=string.format('made %d, used %d in the last 10 min on %s', flow('input'), flow('output'), surface.name),
      where=total > 0 and (total .. ': ' .. table.concat(parts, ', ')) or ('none on ' .. surface.name .. (area and ' in this area' or '')),
      chests=#t.chests > 0 and M.top_chests(t) or nil}
    local lines = M.network_lines(t, scan)
    if #lines > 0 then out.networks = lines end
    out.makers, out.makers_worst = M.machines(t, t.makers, 'makers', scan, packs)
    out.users, out.users_worst = M.machines(t, t.users, 'users', scan, packs)
    if out.makers_worst and #out.makers_worst == 0 then out.makers_worst = nil end
    if out.users_worst and #out.users_worst == 0 then out.users_worst = nil end
    out.feeders = M.feeders(t)
    out.takers = M.takers(t)
    out.counted = M.counted(scan)
    -- Spoilage: the first to spoil, or for an item that hatches into enemies (pentapod-egg) the first to hatch.
    local f = t.spoil_first
    if f and api.spoil then
      local h = api.spoil.hatch(item)
      local text = string.format('the first %s in %s at %s (%s) in %s (%d%% spoiled); %d of %d within 5 min', h and 'hatches' or 'spoils',
        f.name, at(f.position), f.kind, api.spoil.secs(f.tick - game.tick), math.floor(f.percent * 100 + 0.5), t.spoil_soon or 0, t.spoil_count or 0)
      if h then out.hatch = string.format('%s hatch into enemies (%s, %s): %s', item, h.entity, api.spoil.per_text(h), text) else out.spoil = text end
    end
    return out
  end
  return M
end
