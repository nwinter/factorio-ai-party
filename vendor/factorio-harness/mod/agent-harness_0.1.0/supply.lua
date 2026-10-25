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
local qflow = require('qflow')   -- (d24 batch152 PX1) statistics read at every quality
return function(api)
  local M = {}
  local MAX_MACHINES, MAX_LABS, MAX_CHESTS, MAX_BELTS, MAX_INSERTERS, MAX_ROBOTS, MAX_FOUND = 2048, 1024, 5000, 10000, 8192, 4096, 40000
  local MAX_SPOTS, TOP_CHESTS, TOP_UNMET, WORST = 4096, 5, 5, 3
  local CRAFTERS = {'assembling-machine', 'furnace', 'rocket-silo'}
  -- (temporary-container: a landed cargo pod's container, e.g. a stopped platform's hub trash on a planet with no
  -- landing pad: operator 09:04, Sunward's 50 processing units on Gleba)
  local CHESTS = {'container', 'logistic-container', 'temporary-container', 'cargo-landing-pad', 'space-platform-hub', 'cargo-wagon', 'car', 'spider-vehicle'}
  local BELTS = {'transport-belt', 'underground-belt', 'splitter', 'loader', 'loader-1x1', 'linked-belt'}
  local ROBOTS = {'logistic-robot', 'construction-robot'}
  local BELT = {}
  for _, t in ipairs(BELTS) do BELT[t] = true end
  -- One find for every kind: each whole-surface find sweeps all chunks (on
  -- shift08's nauvis six finds took 45 ms, one 19 ms).
  -- Miners (mining drills, pumpjacks, offshore pumps) make what the chain finds no recipe for (Grok, 04:55).
  local MINERS = {'mining-drill', 'offshore-pump'}
  -- Burners outside the crafters, for a fuel's stock in their fuel slots (heating towers are reactors).
  local BURNERS = {'boiler', 'reactor', 'burner-generator'}
  local GROUP, CAP = {}, {crafters=MAX_MACHINES, labs=MAX_LABS, chests=MAX_CHESTS, belts=MAX_BELTS, inserters=MAX_INSERTERS, robots=MAX_ROBOTS, miners=MAX_MACHINES, burners=MAX_MACHINES}
  for group, types in pairs({crafters=CRAFTERS, labs={'lab'}, chests=CHESTS, belts=BELTS, inserters={'inserter'}, robots=ROBOTS, miners=MINERS, burners=BURNERS}) do
    for _, t in ipairs(types) do GROUP[t] = group end
  end
  local MAIN = {container='chest', ['logistic-container']='chest', ['temporary-container']='chest', ['cargo-landing-pad']='cargo_landing_pad_main', ['space-platform-hub']='hub_main',
    ['cargo-wagon']='cargo_wagon', car='car_trunk', ['spider-vehicle']='spider_trunk'}
  -- Requests filled by rockets and cargo pods, not by robots.
  local ORBIT = {['cargo-landing-pad']=true, ['space-platform-hub']=true}
  local SHORT = {item_ingredient_shortage=true, no_ingredients=true, fluid_ingredient_shortage=true, no_input_fluid=true, missing_science_packs=true}
  local FULL = {full_output=true, waiting_for_space_in_destination=true, not_enough_space_in_output=true}
  local KIND_LABEL = {['active-provider']='active-provider chests', ['passive-provider']='passive-provider chests', storage='storage chests',
    buffer='buffer chests', requester='requester chests', chest='other chests', pad='landing pads', pod='landed cargo pods', hub='platform hubs', vehicle='vehicles'}
  local KIND_ORDER = {'requester', 'passive-provider', 'active-provider', 'storage', 'buffer', 'chest', 'pad', 'pod', 'hub', 'vehicle'}
  local function at(pos) return string.format('(%g,%g)', pos.x, pos.y) end
  local function try(fn, ...) local ok, v = pcall(fn, ...); if ok then return v end end
  local slots = require('slots')()
  local fullchest = require('fullchest'){slots=slots, status_name=function(e) return api.status_name and api.status_name(e) end}
  M.fullchest = fullchest
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
    if e.type == 'temporary-container' then return 'pod' end
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
  -- A recipe's product and ingredient names, read once per recipe while the mod is loaded (prototype data; operator
  -- 18:33: a scan read both lists anew, as fresh tables, for every crafter on the surface).
  local recipe_io = {}
  local function io_of(recipe)
    local name = recipe.name
    local c = name and recipe_io[name]
    if not c then
      c = {products={}, ingredients={}}
      for _, x in ipairs(recipe.products or {}) do c.products[#c.products+1] = {name=x.name} end
      for _, x in ipairs(recipe.ingredients or {}) do c.ingredients[#c.ingredients+1] = {name=x.name} end
      if name then recipe_io[name] = c end
    end
    return c
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
  local function belt_lines(e, names, single, out, qualities)
    if single then
      local n = e.get_item_count(qualities and {name=single} or single)
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
  local function belt_counts(e, names, single, out, qualities) pcall(belt_lines, e, names, single, out, qualities) end
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
  -- How much of an item robots are on their way to take from a logistic chest (its logistic point's pickup
  -- reservations; Grok, 15:20); 0 for any other entity.
  function M.reserved(e, item)
    if not (e and e.valid and e.type == 'logistic-container') then return 0 end
    local pt = try(function() return e.get_logistic_point(defines.logistic_member_index.logistic_container) end)
    local n = 0
    for _, r in ipairs(pt and try(function() return pt.targeted_items_pickup end) or {}) do
      local name = type(r.name) == 'table' and r.name.name or r.name
      if name == item then n = n + (r.count or 0) end
    end
    return n
  end
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
    -- A fresh read says so (Sol 15:22: a reused total read as current); a reused one says its age.
    if type(out) == 'table' and out.as_of == nil then out.as_of = string.format('live (tick %d)', game.tick) end
    replies[key] = {tick=game.tick, out=out}
    return out
  end
  function M.forget() replies = {} end
  -- A call timed as its own profile part while the operator profile runs (runtime M.timed); else just the call.
  local function timed(label, fn, ...)
    if api.timed then return api.timed(label, fn, ...) end
    return fn(...)
  end
  -- Its parts are profile parts supply.<part> (operator 18:33: observe/supply 106 ms, supply.scan 79 ms).
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
      T[name] = {item=name, kinds={}, chests={}, belts=0, outputs=0, inputs=0, rockets=0, labs=0, hands=0, robots=0, fuel=0, characters={}, carried=0,
        makers={}, users={}, user_of={}, maker_of={}, spots={}, belt_spots={}, rows={}, orphans={}, request_of={},
        feeders={n=0, states={}, without={}, with=0}, takers={n=0, states={}, into={}}}
    end
    local counted = {}
    local function spot(t, e, n, kind)
      if #t.spots < MAX_SPOTS then t.spots[#t.spots+1] = {position=e.position, name=e.name, n=n, kind=kind, unit=e.unit_number, e=e} end
    end
    -- A spoilable item (Space Age): its first stack to spoil or hatch, where,
    -- and how many spoil within 5 minutes (spoil.lua), read where it was found.
    local sp, spoils = api.spoil, {}
    for name in pairs(names) do spoils[name] = sp and sp.spoils(name) or nil end
    -- science asks for stock value across qualities. Reuse one compact content
    -- read per inventory to find packs before walking their spoilable stacks.
    local normal_count, content_counts = count, {}
    local function count(inv, item, entity)
      if not (opts.science_value and inv and spoils[item]) then return normal_count(inv, item) end
      -- ItemFilter with no quality counts every quality in native code. Most
      -- holders have no packs; avoid allocating their complete contents.
      if entity and try(function() return entity.get_item_count{name=item} end) == 0 then return 0 end
      local counts = content_counts[inv]
      if not counts then
        local ok, rows = pcall(function() return inv.get_contents() end)
        if not ok then return normal_count(inv, item) end
        counts = {}; content_counts[inv] = counts
        for k, row in pairs(rows) do
          local name, n = type(row) == 'table' and row.name or k, type(row) == 'table' and row.count or row
          counts[name] = (counts[name] or 0) + n
        end
      end
      return counts[item] or 0
    end
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
          -- The spread over every place (Sol, 22:25), and each chest's own (top_chests).
          if sp.merge then
            t.spread = t.spread or {}
            sp.merge(t.spread, r)
            local unit = e.unit_number
            if unit and r.min then
              t.spread_of = t.spread_of or {}
              t.spread_of[unit] = t.spread_of[unit] or {}
              sp.merge(t.spread_of[unit], r)
            end
          end
        end
      end
    end
    local any_pack = false
    for name in pairs(names) do if packs[name] or (prototypes.item[name] and try(function() return prototypes.item[name].type end) == 'tool') then any_pack = true end end
    local types = {}
    -- (d20 batch122 CE2) burners only for a fuel
    local fuels = {}
    for name in pairs(names) do if (try(function() return prototypes.item[name].fuel_value end) or 0) > 0 then fuels[name] = true end end
    for t, group in pairs(GROUP) do if (group ~= 'labs' and group ~= 'miners' or any_pack or (group == 'miners' and opts.miners)) and (group ~= 'robots' or not area) and (group ~= 'burners' or next(fuels)) then types[#types+1] = t end end
    table.sort(types)
    local found = timed('supply.find', surface.find_entities_filtered, filter{type=types, limit=MAX_FOUND})
    local lists, seen = {crafters={}, labs={}, chests={}, belts={}, inserters={}, robots={}, miners={}, burners={}}, {}
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
    timed('supply.crafters', function()
    for _, e in ipairs(crafters) do
      local recipe = recipe_of(e)
      if recipe then
        local io = io_of(recipe)
        for _, prod in ipairs(io.products) do
          local t = T[prod.name]
          if t and not t.maker_of[e.unit_number] then
            local m = {e=e, recipe=recipe, into={}, from={}}
            t.maker_of[e.unit_number] = m; t.makers[#t.makers+1] = m
          end
        end
        for _, ing in ipairs(io.ingredients) do
          local t = T[ing.name]
          if t and not t.user_of[e.unit_number] then
            local u = {e=e, recipe=recipe, has=count(input_of(e), ing.name, e), feeders={}}
            t.user_of[e.unit_number] = u; t.users[#t.users+1] = u; t.inputs = t.inputs + u.has
            if u.has > 0 then spoil_at(t, e, 'input', function(acc) sp.inventory(input_of(e), acc) end) end
          end
        end
      end
      local out = output_of(e)
      -- A silo's rocket: what it will launch (a platform's request, an export). Counted once, as silo cargo: a silo's
      -- output inventory is that rocket (Astra, 06:29: 90 counted for 45 in the rocket).
      local rocket = e.type == 'rocket-silo' and inventory(e, 'rocket_silo_rocket') or nil
      if rocket then out = nil end
      for name, t in pairs(T) do
        local n = count(out, name, e)
        if n > 0 then t.outputs = t.outputs + n; spot(t, e, n, 'output'); spoil_at(t, e, 'output', function(acc) sp.inventory(out, acc) end) end
        local r = count(rocket, name, e)
        if r > 0 then t.rockets = t.rockets + r; spoil_at(t, e, 'rocket cargo', function(acc) sp.inventory(rocket, acc) end) end
      end
    end
    end)
    -- (d20 batch122 CE2, viewer Aurora 10:13) a fuel in fuel slots: crafters' (biochambers), other burners' (heating
    -- towers, boilers), drills' and vehicles' (Gleba: 195 of 3,792 nutrients sat in biochambers' fuel slots, uncounted)
    if next(fuels) then
      timed('supply.fuel', function()
        for _, list in ipairs({crafters, lists.burners, lists.miners, lists.chests}) do
          for _, e in ipairs(list) do
            if list ~= lists.chests or e.type == 'car' or e.type == 'spider-vehicle' then
              local ok, inv = pcall(e.get_fuel_inventory)
              -- (d24 batch182 QY1) what holds or burns it now (heating towers, boilers; machines and vehicles holding it):
              -- the burners among supply's sinks. What burns is read for burners and for an entity holding a fuel.
              local cb, read = nil, false
              local function burning(holds)
                if not read and (holds or list == lists.burners) then
                  read = true
                  cb = try(function() return e.burner.currently_burning end)
                  cb = cb and (type(cb.name) == 'string' and cb.name or cb.name and cb.name.name)
                end
                return cb
              end
              if ok and inv then
                for name in pairs(fuels) do
                  local t, n = T[name], count(inv, name, e)
                  if n > 0 then t.fuel = t.fuel + n; spoil_at(t, e, 'fuel slot', function(acc) sp.inventory(inv, acc) end) end
                  if burning(n > 0) == name or n > 0 then
                    t.burners = t.burners or {}
                    local b = t.burners[e.name]
                    if not b then b = {n=0, burning=0, held=0, e=e}; t.burners[e.name] = b end
                    b.n, b.held = b.n + 1, b.held + n
                    if cb == name then b.burning = b.burning + 1 end
                  end
                end
              end
            end
          end
        end
      end)
    end
    -- Labs: what they hold; those whose research needs a pack use it.
    if any_pack then
      local labs = lists.labs
      counted.labs = #labs
      for _, e in ipairs(labs) do
        local inv = inventory(e, 'lab_input')
        for name, t in pairs(T) do
          local n = count(inv, name, e)
          t.labs = t.labs + n
          if n > 0 then spoil_at(t, e, 'lab', function(acc) sp.inventory(inv, acc) end) end
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
    timed('supply.requesters', function()
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
    end)
    -- Each network that matters: its stock of the items (the engine's free
    -- counts are net of pickups robots have reserved), reservations, robots.
    local payload = (try(function() return prototypes.entity['logistic-robot'].max_payload_size end) or 1) + (force.worker_robots_storage_bonus or 0)
    timed('supply.stock', function()
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
      -- Who reserved the providers' stock (Grok, 10:50: "all held are reserved" said nothing about by whom): a robot's
      -- order queue holds its pickup (from a provider) and then its delivery (to a requester); each such pair is that
      -- requester's reservation of the item. net.reserved_for[item] = {key: {e, n}}.
      local orders_type = defines.robot_order_type or {}
      net.reserved_for = {}
      for _, r in ipairs(try(function() return n.logistic_robots end) or {}) do
        out = out + 1
        local inv = inventory(r, 'robot_cargo')
        if inv and not try(function() return inv.is_empty() end) then carrying = carrying + 1 end
        local pick
        for _, o in ipairs(orders_type.pickup and try(function() return r.robot_order_queue end) or {}) do
          local item = o.target_item
          -- (d22 batch100 BJ2) 2.0.77: target_item.name is the item prototype (userdata), read on a copy of world n
          if type(item) == 'table' then local n = item.name; item = type(n) == 'string' and n or try(function() return n.name end) end
          if o.type == orders_type.pickup and item and T[item] then pick = {item=item, n=o.target_count or 0}
          elseif o.type == orders_type.deliver and pick and o.target and o.target.valid then
            local by = net.reserved_for[pick.item] or {}
            net.reserved_for[pick.item] = by
            local key = tostring(try(function() return o.target.unit_number end) or at(o.target.position))
            by[key] = by[key] or {e=o.target, n=0}
            by[key].n = by[key].n + pick.n
            pick = nil
          end
        end
      end
      net.robots = {all=n.all_logistic_robots or 0, idle=n.available_logistic_robots or 0, out=out, carrying=carrying,
        charging=charging, waiting=waiting, payload=payload}
      net.roboports, net.box, net.mobile = roboports, box, mobile
    end
    end)
    local by_id = {}
    for _, net in ipairs(networks) do by_id[net.id] = net end
    -- Chests: by kind; requesters' stock robots never take; requests outside
    -- every network.
    local chests = lists.chests
    counted.chests = #chests
    timed('supply.chests', function()
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
        local n = count(main, name, e) + count(trash, name, e)
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
    end)
    -- Belts.
    local belts = lists.belts
    counted.belts = #belts
    counted.belts_total = seen.belts or #belts
    timed('supply.belts', function()
    for _, e in ipairs(belts) do
      local held = {}
      belt_counts(e, names, single, held, opts.science_value and spoils[single])
      for name, n in pairs(held) do
        local t = T[name]; t.belts = t.belts + n; spot(t, e, n, 'belt'); spoil_at(t, e, 'belt', function(acc) sp.belt(e, acc) end)
        -- each belt tile holding it, for the belt lines (M.belt_lines)
        if n > 0 and #t.belt_spots < MAX_SPOTS then t.belt_spots[#t.belt_spots+1] = {e.position.x, e.position.y, n, e.direction or 0, e.type} end
      end
    end
    end)
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
        -- A maker's inserters in and out, for throughput.
        local m = drop_unit and t.maker_of[drop_unit]
        if m and m.into then m.into[#m.into+1] = e end
        m = pick_unit and t.maker_of[pick_unit]
        if m and m.from then m.from[#m.from+1] = e end
        if pick_unit and t.maker_of[pick_unit] then
          status = status or api.status_name(e) or 'unknown'
          local k = t.takers
          k.n = k.n + 1; bump(k.states, status)
          if FULL[status] then
            bump(k.into, drop and drop.name or 'ground')
            -- The chest it waits on (Astra, Luna, shift19): read for full_chests.
            if drop and drop.unit_number and (drop.type == 'container' or drop.type == 'logistic-container') then
              k.chests = k.chests or {}
              k.chests[drop.unit_number] = drop
            end
          end
        end
      end
    end
    timed('supply.inserters', function() for _, e in ipairs(inserters) do pcall(visit, e) end end)
    -- Robots carrying the items; per network what is in flight.
    local robots = lists.robots
    counted.robots = #robots
    timed('supply.robots', function()
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
    end)
    -- The team's characters.
    for _, ch in ipairs(characters) do
      if inside(ch.c.position) then
        for name, t in pairs(T) do
          local n = try(function() return ch.c.get_item_count(name) end) or 0
          if opts.science_value and spoils[name] then
            n = try(function() return ch.c.get_item_count{name=name} end) or n
          end
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
        -- Every slot taken (Sol, 22:08: 494 spoilage among a requester's 48 slots read as "no idle robots"): before
        -- any robot reason.
        local full = not row.off and slots.full_of(row.e, t.item)
        if row.off then row.why = row.off
        elseif full then row.why = 'inventory full: ' .. full.text; row.full = full
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
      -- The requesters robots will pick the reserved stock up for (their order queues), most first.
      local res = {}
      for _, v in pairs((net.reserved_for or {})[t.item] or {}) do
        if v.e.valid then res[#res+1] = {text=string.format('%s %s %d', at(v.e.position), v.e.name, v.n), n=v.n, x=v.e.position.x} end
      end
      table.sort(res, function(a, b) if a.n ~= b.n then return a.n > b.n end return a.x < b.x end)
      if #res > 0 then
        local shown = {}
        for i = 1, math.min(4, #res) do shown[i] = res[i].text end
        text = text .. '; reserved for ' .. table.concat(shown, ', ') .. (#res > 4 and string.format(' (+%d more)', #res - 4) or '')
      end
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

  -- Stock on our platforms stopped over this planet (d15 trajectory analysis: Grok's 102 calcite sat on Starling over
  -- Nauvis while the artillery ran out of shells): {total, rows [{platform, n}], line "in orbit on Starling 102"}, or nil.
  -- The hub's main inventory, as the platform GUI shows it; a platform in flight or over another planet is left out.
  function M.orbit_stock(surface, force, item)
    if not (surface and force and item) then return nil end
    local planet = try(function() return surface.planet and surface.planet.name end) or (not try(function() return surface.platform end) and surface.name or nil)
    if not planet then return nil end
    local rows, total = {}, 0
    for _, pl in pairs(try(function() return force.platforms end) or {}) do
      if try(function() return pl.valid and pl.space_location and pl.space_location.name end) == planet then
        local inv = try(function() return pl.hub and pl.hub.valid and pl.hub.get_inventory(defines.inventory.hub_main) end)
        local n = inv and try(function() return inv.get_item_count(item) end) or 0
        if n > 0 then rows[#rows+1] = {platform=pl.name, n=n}; total = total + n end
      end
    end
    if total == 0 then return nil end
    table.sort(rows, function(a, b) if a.n ~= b.n then return a.n > b.n end return a.platform < b.platform end)
    local parts = {}
    for i, r in ipairs(rows) do parts[i] = r.platform .. ' ' .. r.n end
    return {total=total, rows=rows, line='in orbit on ' .. table.concat(parts, ', ')}
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
    add('fuel slots', t.fuel or 0)
    if (t.ground or 0) > 0 then parts[#parts+1] = 'on the ground ' .. t.ground .. ' (' .. t.ground_as_of .. ')'; total = total + t.ground end
    if t.carried > 0 then parts[#parts+1] = 'characters ' .. t.carried .. ' (' .. table.concat(t.characters, ', ') .. ')'; total = total + t.carried end
    return total, parts
  end
  -- Where the item sits on belts (Muse, Grok 07:50: supply said coal 1001 on belts and nobody could find the backed-up
  -- line): the belt tiles holding it joined into lines (tiles side by side that hold it; an underground's two ends and
  -- an empty tile split a line), the lines with the most first: items, tiles, the box, the tile holding the most, and
  -- each line's ends (out: no belt of the line on the tile its items move to; in: none feeding it from behind), with
  -- what each holds. Up to `limit` lines (default 5); the rest counted.
  local DIRV = {[0]={0,-1}, [4]={1,0}, [8]={0,1}, [12]={-1,0}}
  function M.belt_lines(t, limit)
    local spots = t.belt_spots or {}
    if #spots == 0 then return nil end
    local idx, parent = {}, {}
    local function k(x, y) return math.floor(x) .. ',' .. math.floor(y) end
    for i, s_ in ipairs(spots) do idx[k(s_[1], s_[2])] = i; parent[i] = i end
    local function root(i) while parent[i] ~= i do parent[i] = parent[parent[i]]; i = parent[i] end return i end
    for i, s_ in ipairs(spots) do
      for _, d in ipairs({{1,0},{0,1}}) do
        local j = idx[k(s_[1] + d[1], s_[2] + d[2])]
        if j then local a, b = root(i), root(j); if a ~= b then parent[a] = b end end
      end
    end
    local lines, by = {}, {}
    for i, s_ in ipairs(spots) do
      local r = root(i)
      local L = by[r]
      if not L then L = {items=0, tiles=0, members={}, l=s_[1], t=s_[2], r=s_[1], b=s_[2]}; by[r] = L; lines[#lines+1] = L end
      L.items = L.items + s_[3]; L.tiles = L.tiles + 1; L.members[#L.members+1] = i
      L.l = math.min(L.l, s_[1]); L.t = math.min(L.t, s_[2]); L.r = math.max(L.r, s_[1]); L.b = math.max(L.b, s_[2])
      if not L.most or s_[3] > spots[L.most][3] then L.most = i end
    end
    table.sort(lines, function(x, y) if x.items ~= y.items then return x.items > y.items end return x.l < y.l end)
    local out = {}
    for n = 1, math.min(limit or 5, #lines) do
      local L = lines[n]
      local ends = {}
      for _, i in ipairs(L.members) do
        local s_ = spots[i]
        local d = DIRV[s_[4]]
        if d and s_[5] ~= 'splitter' then
          local ahead = idx[k(s_[1] + d[1], s_[2] + d[2])]
          local behind = idx[k(s_[1] - d[1], s_[2] - d[2])]
          if not (ahead and root(ahead) == root(i)) then ends[#ends+1] = {'out', i} end
          if not (behind and root(behind) == root(i)) and L.tiles > 1 then ends[#ends+1] = {'in', i} end
        end
      end
      table.sort(ends, function(x, y) if spots[x[2]][3] ~= spots[y[2]][3] then return spots[x[2]][3] > spots[y[2]][3] end return x[1] > y[1] end)
      local ends_text = {}
      for e_ = 1, math.min(4, #ends) do
        local s_ = spots[ends[e_][2]]
        ends_text[#ends_text+1] = string.format('%s end %s %d', ends[e_][1], at({x=s_[1], y=s_[2]}), s_[3])
      end
      if #ends > 4 then ends_text[#ends_text+1] = (#ends - 4) .. ' more ends' end
      local m = spots[L.most]
      out[#out+1] = string.format('%d on %d belt tile%s %s-%s; most %d at %s%s', L.items, L.tiles, L.tiles == 1 and '' or 's',
        at({x=L.l, y=L.t}), at({x=L.r, y=L.b}), m[3], at({x=m[1], y=m[2]}), #ends_text > 0 and '; ' .. table.concat(ends_text, ', ') or '')
    end
    local shown = #out
    if #lines > shown then
      local rest = 0
      for n = shown + 1, #lines do rest = rest + lines[n].items end
      out[#out+1] = string.format('%d more belt line%s %d', #lines - shown, #lines - shown == 1 and ' holds' or 's hold', rest)
    end
    if #spots >= MAX_SPOTS then out[#out+1] = 'belt tiles listed up to ' .. MAX_SPOTS .. '; the belts total counts every one' end
    return out
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
      else
        -- What robots have reserved there for pickup (Haiku, shift19: a passive provider's copper all reserved, read as
        -- no stock; she walked 500 tiles to mine some).
        local reserved = M.reserved(c.e, t.item)
        if reserved > 0 then text = text .. string.format(' (%d of it reserved for robots to take)', math.min(reserved, c.n)) end
        -- Its free slots (Astra, Luna, shift19: providers 48/48 slots used while supply read only their stock).
        text = text .. fullchest.free_note(c.e)
      end
      -- Its spread (Sol, 22:25): least and most spoiled stack, count-weighted.
      local s = c.e.unit_number and t.spread_of and t.spread_of[c.e.unit_number]
      local r = s and s[1]
      if r and r.count > 0 then
        local lo, hi = math.floor(r.min * 100 + 0.5), math.floor(r.max * 100 + 0.5)
        text = text .. string.format(' (spoiled %s, %d%% by count)', lo == hi and lo .. '%' or lo .. '-' .. hi .. '%', math.floor(r.wsum / r.count * 100 + 0.5))
      end
      out[i] = text
    end
    return out
  end
  -- Stock outside requester/buffer chests, net of this chest's robot pickups.
  function M.surplus_chest(t)
    local best
    for _, c in ipairs(t.chests) do
      if c.kind=='chest' or c.kind=='storage' or c.kind=='passive-provider' or c.kind=='active-provider' then
        local reserved=M.reserved(c.e,t.item)
        local free=math.max(0,c.n-reserved)
        if free>0 and (not best or free>best.free) then
          best={name=c.e.name,position={x=c.e.position.x,y=c.e.position.y},kind=c.kind,held=c.n,reserved=reserved,free=free}
        end
      end
    end
    if best then best.line=string.format('%s %s: %d held, %d reserved for robot pickups, %d unreserved; %s',
      best.name,at(best.position),best.held,best.reserved,best.free,best.kind) end
    -- None unreserved: the largest held that robots have reserved, said as reserved (Haiku, shift19).
    if not best then
      local top
      for _, c in ipairs(t.chests) do
        if (c.kind=='chest' or c.kind=='storage' or c.kind=='passive-provider' or c.kind=='active-provider') and (not top or c.n>top.n) then top=c end
      end
      if top then
        local reserved=M.reserved(top.e,t.item)
        return {name=top.e.name,position={x=top.e.position.x,y=top.e.position.y},kind=top.kind,held=top.n,reserved=reserved,free=0,
          line=string.format('%s %s: %d held, all reserved for robot pickups (%d); %s; no provider, storage or plain chest holds it unreserved',
            top.e.name,at(top.e.position),top.n,reserved,top.kind)}
      end
    end
    return best
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
    if not best then return nil end
    -- with what robots have reserved there for pickup (Grok, 15:20: three walks to a provider emptied by robots)
    local reserved = best.e and M.reserved(best.e, t.item) or 0
    return string.format('nearest %s: %s %s %d tiles%s', t.item, best.name, at(best.position), math.floor(math.sqrt(bd) + 0.5),
      reserved > 0 and string.format(' (holds %d, %d of it reserved for robots to take)', best.n or 0, reserved) or '')
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
  -- Every machine not working, grouped (E4, Opus 19:50, 3x: "list ALL not_working makers' positions grouped by cluster,
  -- not just 3 worst"): a machine within GAP tiles of a group's box joins it; each group its box, counts by name and
  -- state (missing ingredients), and every position. rows: {e, status, lacks}. At most MAX_STOPPED positions a read.
  local GAP, MAX_STOPPED = 12, 256
  function M.clusters(rows)
    local groups = {}
    table.sort(rows, function(x, y) if x.e.position.x ~= y.e.position.x then return x.e.position.x < y.e.position.x end return x.e.position.y < y.e.position.y end)
    local listed = 0
    for _, r in ipairs(rows) do
      local q = r.e.position
      local g
      for _, h in ipairs(groups) do
        if q.x >= h.x0 - GAP and q.x <= h.x1 + GAP and q.y >= h.y0 - GAP and q.y <= h.y1 + GAP then g = h; break end
      end
      if not g then g = {x0=q.x, y0=q.y, x1=q.x, y1=q.y, n=0, by={}, at={}}; groups[#groups+1] = g end
      g.x0, g.y0, g.x1, g.y1 = math.min(g.x0, q.x), math.min(g.y0, q.y), math.max(g.x1, q.x), math.max(g.y1, q.y)
      g.n = g.n + 1
      local k = r.e.name .. ' ' .. r.status .. (#r.lacks > 0 and ' (missing ' .. table.concat(r.lacks, ', ') .. ')' or '')
      g.by[k] = (g.by[k] or 0) + 1
      if listed < MAX_STOPPED then g.at[#g.at+1] = at(q); listed = listed + 1 end
    end
    table.sort(groups, function(x, y) return x.n > y.n end)
    local lines = {}
    for _, g in ipairs(groups) do
      local parts = {}
      for k, n in pairs(g.by) do parts[#parts+1] = n .. ' ' .. k end
      table.sort(parts)
      lines[#lines+1] = string.format('%d near (%g,%g)-(%g,%g): %s; at %s%s', g.n, math.floor(g.x0), math.floor(g.y0), math.ceil(g.x1), math.ceil(g.y1),
        table.concat(parts, ', '), table.concat(g.at, ' '), #g.at < g.n and ' ...' or '')
    end
    return #lines > 0 and lines or nil
  end
  -- What holds a short machine's input back before the shortage itself (d17 batch18 B1, Sol: artillery shells read
  -- tungsten-starved while the input arm was off at a stock cap of 20 with 40 tungsten in its requester): an inserter
  -- into it off by its circuit or logistic condition (the condition, what its source holds of the missing items), or a
  -- requester chest an inserter takes from that asks for less of a missing item than one craft takes.
  local function held_back(e, u, lacks)
    if #lacks == 0 or u.lab then return nil end
    local arms = {}
    for _, f in ipairs(u.feeders or {}) do arms[#arms+1] = f.e end
    for _, i in ipairs(u.into or {}) do arms[#arms+1] = i end
    local need = {}
    for _, ing in ipairs(u.recipe and u.recipe.ingredients or {}) do need[ing.name] = ing.amount end
    local seen = {}
    for _, i in ipairs(arms) do
      if i.valid and not seen[i.unit_number] then
        seen[i.unit_number] = true
        if try(function() return i.status end) == (defines.entity_status or {}).disabled_by_control_behavior then return {arm=i} end
        local src = try(function() return i.pickup_target end)
        if src and src.valid and src.type == 'logistic-container' and try(function() return src.prototype.logistic_mode end) == 'requester' then
          local secs = try(function() return src.get_logistic_sections() end)
          for _, name in ipairs(lacks) do
            local want, named = 0, false
            for k = 1, secs and secs.sections_count or 0 do
              local sec = try(function() return secs.get_section(k) end)
              if sec and sec.active ~= false then
                for _, fl in ipairs(try(function() return sec.filters end) or {}) do
                  local v = fl.value
                  if v and (type(v) == 'table' and v.name or v) == name then named = true; want = want + (fl.min or 0) * (try(function() return sec.multiplier end) or 1) end
                end
              end
            end
            if named and need[name] and want < need[name] then return {src=src, item=name, want=want, need=need[name]} end
          end
        end
      end
    end
  end
  -- Its words, for the worst only (the condition read costs a circuit read).
  local function held_text(h, lacks)
    if h.src then
      return string.format('its requester %s %s asks for %d %s, one craft takes %d; it holds %d', h.src.name, at(h.src.position), h.want, h.item, h.need,
        try(function() return h.src.get_item_count(h.item) end) or 0)
    end
    local i = h.arm
    -- (an inserter off by its condition keeps the pickup target it had; the one at its pickup position then)
    local src = try(function() return i.pickup_target end) or try(function()
      for _, c in ipairs(i.surface.find_entities_filtered{position=i.pickup_position, limit=4}) do if c ~= i and c.type ~= 'character' then return c end end
    end)
    local holds = {}
    if src and src.valid then
      for _, name in ipairs(lacks) do
        local n = try(function() return src.get_item_count(name) end) or 0
        if n > 0 then holds[#holds+1] = n .. ' ' .. name end
      end
    end
    local where = src and src.valid and string.format('%s %s holds %s', src.name, at(src.position), #holds > 0 and table.concat(holds, ', ') or 'none of ' .. table.concat(lacks, ', ')) or 'no source'
    local why = api.state_text and try(api.state_text, i) or 'off by its circuit or logistic condition'
    return string.format('input %s %s %s; its source %s', i.name, at(i.position), why, where)
  end
  -- Machines by status (missing ingredients named), recipes, and the worst
  -- with positions: no power, then missing this item, other shortages,
  -- output full, low power, anything else not working.
  function M.machines(t, list, role, scan, packs)
    if #list == 0 then return nil end
    -- by_name: the machines counted, by name (Astra, 06:19: a line naming only the worst three read as "7 AM2" with an
    -- electromagnetic plant among the makers; every crafter type counts: assemblers, furnaces, silos, and Space Age's
    -- electromagnetic plants, foundries, cryogenic plants, biochambers, crushers and recyclers, which are of those types).
    local states, short, recipes, ranked, by_name, held_n = {}, {}, {}, {}, {}, 0
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
        local held = SHORT[status] and held_back(e, u, lacks) or nil
        if held then held_n = held_n + 1 end
        -- (d18 batch37 A2, Opus: a machine off by its own condition was never among the worst, ranked last) its own gate
        -- ranks with an input arm's
        local rank = (status == 'no_power' or status == 'burnt_result_full' or status == 'fuel_unusable') and 1 or (held or status == 'disabled_by_control_behavior') and 1.5 or (SHORT[status] and lacks_it) and 2 or SHORT[status] and 3 or FULL[status] and 4 or status == 'low_power' and 5 or 6
        ranked[#ranked+1] = {u=u, e=e, status=status, lacks=lacks, rank=rank, held=held}
      end
    end
    local parts = {}
    local order = {}
    for status, n in pairs(states) do order[#order+1] = {s=status, n=n} end
    table.sort(order, function(x, y) if x.s == 'working' then return y.s ~= 'working' end if y.s == 'working' then return false end if x.n ~= y.n then return x.n > y.n end return x.s < y.s end)
    for _, o in ipairs(order) do
      local text = o.n .. ' ' .. o.s
      if SHORT[o.s] and next(short) then text = text .. ' (' .. short_list(short, 6) .. ')'; short = {} end
      -- (d17 batch22 B2, Muse) the first one's own gate, the condition and what it reads now
      if o.s == 'disabled_by_control_behavior' and api.state_text then
        for _, w in ipairs(ranked) do
          if w.status == o.s then local g = try(api.state_text, w.e); if g then text = text .. ' (' .. g .. ')' end; break end
        end
      end
      parts[#parts+1] = text
    end
    if (states.working or 0) == 0 then table.insert(parts, 1, '0 working') end
    if held_n > 0 then parts[#parts+1] = string.format('%d of the short held back by an input inserter\'s condition or a requester asking for less than one craft', held_n) end
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
      local text = at(w.e.position) .. ' ' .. w.e.name .. ' ' .. (w.held and held_text(w.held, w.lacks) .. '; so ' or '') .. w.status
      if #w.lacks > 0 then text = text .. ' (missing ' .. table.concat(w.lacks, ', ') .. ')' end
      if (w.status == 'burnt_result_full' or w.status == 'fuel_unusable') and api.burnt_line then text = text .. ' (' .. (try(api.burnt_line, w.e) or '') .. ')' end
      if w.status == 'disabled_by_control_behavior' and api.state_text then local g = try(api.state_text, w.e); if g then text = text .. ' (' .. g .. ')' end end
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
    return line, worst, ranked
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
  -- Chests with every slot used that the item's makers' output waits on, or that hold the item (Astra, Luna, shift19):
  -- slots used/total, what fills them, the machines whose output waits on it. Up to FULL_SHOW of FULL_LOOK read.
  local FULL_SHOW, FULL_LOOK = 5, 32
  function M.full_chests(t)
    local seen, list, looked = {}, {}, 0
    local function look(e)
      if looked >= FULL_LOOK or not e or not e.valid or not e.unit_number or seen[e.unit_number] then return end
      seen[e.unit_number] = true
      looked = looked + 1
      local r = try(fullchest.read, e)
      if r then list[#list+1] = r end
    end
    local units = {}
    for unit in pairs(t.takers.chests or {}) do units[#units+1] = unit end
    table.sort(units)
    for _, unit in ipairs(units) do look(t.takers.chests[unit]) end
    for _, c in ipairs(t.chests) do
      if c.kind ~= 'requester' and c.kind ~= 'buffer' and (c.e.type == 'container' or c.e.type == 'logistic-container') then look(c.e) end
    end
    if #list == 0 then return nil end
    table.sort(list, function(a, b) if #a.waiting.machines ~= #b.waiting.machines then return #a.waiting.machines > #b.waiting.machines end return a.line < b.line end)
    local out = {}
    for i = 1, math.min(FULL_SHOW, #list) do out[i] = list[i].line end
    if #list > FULL_SHOW then out[#out+1] = string.format('%d more full chests', #list - FULL_SHOW) end
    return out
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
      local fluid = prototypes.fluid and prototypes.fluid[name]
      local stats = fluid and fluids or items
      local n = stats and try(function()
        if not fluid then return qflow.flow(stats, name, category, defines.flow_precision_index.ten_minutes, true) end
        return stats.get_flow_count{name=name, category=category, precision_index=defines.flow_precision_index.ten_minutes, count=true}
      end)
      return n and math.floor(n / 10 + 0.5) or 0
    end
    local nodes, seen = {}, {}
    -- (d20 batch63 Y2, Astra #1523) a maker lacking an item its held-off feeder's source holds is held by that feeder's
    -- condition, not short of it: at most 64 such checks a chain, 3 combinator traces
    local feed_budget = {checks=64, traces=3}
    local function visit(name, depth)
      if seen[name] or #nodes >= CHAIN_NODES or depth > CHAIN_DEPTH then return end
      seen[name] = true
      local makers = by_product[name] or {}
      local node = {item=name, depth=depth, made=per_min(name, 'input'), used=per_min(name, 'output'), makers=#makers, working=0, states={}, lack={},
        miners=0, miner_names={}, miner_states={}, outputs={}, held={}, held_lines={}}
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
            for _, ing in ipairs(missing(m.e, m, nil)) do
              local h
              if api.feeders_held and feed_budget.checks > 0 then
                feed_budget.checks = feed_budget.checks - 1
                h = try(function() return api.feeders_held(m.e, ing, feed_budget) end)
              end
              if h then
                bump(node.held, ing)
                if #node.held_lines < 3 then node.held_lines[#node.held_lines+1] = string.format('%s %s lacks %s: %s', m.e.name, at(m.e.position), ing, h.line) end
              else bump(node.lack, ing) end
            end
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
      local held_n, held_items = 0, {}
      for ing, k in pairs(n.held) do held_n = math.max(held_n, k); held_items[#held_items+1] = ing end
      table.sort(held_items)
      local text
      if n.makers == 0 then text = string.format('%s: no assembler, furnace, silo, mining drill or pump makes it', n.item)
      elseif top and top_n * 2 > n.makers then text = string.format('%s: %d of %d makers lack %s', n.item, top_n, n.makers, top)
      elseif held_n * 2 > n.makers then
        -- most makers wait on feeders held off by their conditions with the items at their sources: not a shortage
        text = string.format('%s: %d of %d makers held by their feeders\' conditions (they lack %s, which the feeders\' sources hold)',
          n.item, held_n, n.makers, table.concat(held_items, ', '))
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
      if held_n > 0 and not (held_n * 2 > n.makers and not (top and top_n * 2 > n.makers)) then
        text = text .. string.format(' (%d held by their feeders\' conditions)', held_n)
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
        held_by_feeders=next(n.held) and n.held or nil, held_lines=#n.held_lines > 0 and n.held_lines or nil,
        miners=n.miners > 0 and n.miners or nil, miner_states=next(n.miner_states) and n.miner_states or nil,
        outputs=next(n.outputs) and n.outputs or nil}
    end
    -- path: the items the line walked; last: its last step (where the shortage starts).
    return {line='chain: ' .. table.concat(parts, '; '), tree=rows, cut=#nodes >= CHAIN_NODES or nil, path=path, last=parts[#parts]}
  end
  -- bottleneck {item} (Sonnet, 15:20: a purple science shortage dug down its chain by hand four times, through
  -- advanced circuits, plastic, petroleum gas, the refinery and calcite): the item's recipe tree on the surface as the
  -- science line's chain reads it (one supply scan, mining drills and pumps included), the line that follows the
  -- ingredient most of a step's makers lack down to its root, and on each step of that line up to 3 makers that are
  -- not working, with position, state and what they lack. Kept 10 s like supply.
  -- per_min (Sonnet, shift13 18:20): the rate each step needs for that many of the item a minute (ratechain.lua).
  -- fixes (Luna, 19:50): for each such maker lacking an item, the nearest chest within 64 tiles holding it (what robots
  -- have reserved there left out) and one transfer that carries about 10 crafts' worth there; at most 6 fixes.
  local FIX_RADIUS, FIX_CHESTS, FIX_MAX, FIX_CRAFTS = 64, 200, 6, 10
  local FIX_TYPES = {'container', 'logistic-container'}
  local function fix_line(surface, force, m, ing)
    local e = m.e
    local per = 1
    for _, i in ipairs(m.recipe and m.recipe.ingredients or {}) do if i.name == ing then per = i.amount end end
    if prototypes.fluid and prototypes.fluid[ing] then
      return string.format('%s %s lacks %s: a fluid, it comes by pipe', e.name, at(e.position), ing)
    end
    local best, bd, held
    for _, c in ipairs(try(function()
      return surface.find_entities_filtered{position=e.position, radius=FIX_RADIUS, type=FIX_TYPES, force=force, limit=FIX_CHESTS}
    end) or {}) do
      local n = count(inventory(c, 'chest'), ing) - M.reserved(c, ing)
      if n > 0 then
        local d = (c.position.x - e.position.x) ^ 2 + (c.position.y - e.position.y) ^ 2
        if not bd or d < bd then best, bd, held = c, d, n end
      end
    end
    if not best then
      return string.format('%s %s lacks %s: no chest within %d tiles holds it', e.name, at(e.position), ing, FIX_RADIUS)
    end
    local n = math.max(1, math.min(held, math.ceil(per * FIX_CRAFTS)))
    return string.format('%s %s lacks %s: %s %s holds %d, %d tiles away; fh call transfer --args \'{"item":"%s","pick":"first_with_stock","positions":[{"x":%g,"y":%g}],"to":{"x":%g,"y":%g},"count":%d}\'',
      e.name, at(e.position), ing, best.name, at(best.position), held, math.floor(math.sqrt(bd) + 0.5),
      ing, best.position.x, best.position.y, e.position.x, e.position.y, n)
  end
  local ratechain
  function M.bottleneck_item(p, a)
    local item = a.item
    assert(type(item) == 'string' and (prototypes.item[item] or (prototypes.fluid and prototypes.fluid[item])),
      'item must be an item or fluid name (processing-unit, plastic-bar, petroleum-gas, ...)')
    assert(a.per_min == nil or (type(a.per_min) == 'number' and a.per_min > 0 and a.per_min <= 1000000),
      'per_min must be a rate above 0 (items a minute, up to 1000000)')
    local surface = p.surface
    if a.surface ~= nil then
      assert(type(a.surface) == 'string', 'surface must be a surface name')
      surface = game.get_surface(a.surface)
      assert(surface, 'no surface ' .. a.surface)
    end
    local force = p.force
    assert(a.all_stopped == nil or type(a.all_stopped) == 'boolean', 'all_stopped is true or false')
    local key = string.format('bottleneck|%s|%s|%s|%s|%s', tostring(surface.index or surface.name), force.name, item, tostring(a.per_min), tostring(a.all_stopped))
    return M.reuse(key, function()
      local names = prototypes.item[item] and {[item]=true} or {}
      local scan = M.scan(surface, force, names, {packs=M.packs_of(force), miners=true})
      local chain = M.chain(scan, force, surface, item)
      local where, fixes, full_chests, stopped, held = {}, {}, {}, {}, {}
      local feed_budget = {traces=3}
      for _, name in ipairs(chain.path or {}) do
        local rows = {}
        if a.all_stopped then
          local all = {}
          for _, m in ipairs(scan.by_product and scan.by_product[name] or {}) do
            local state = m.e.valid and (api.status_name(m.e) or 'unknown')
            if state and state ~= 'working' then all[#all+1] = {e=m.e, status=state, lacks=(not m.miner) and missing(m.e, m, nil) or {}} end
          end
          local lines = M.clusters(all)
          if lines then stopped[#stopped+1] = name .. ': ' .. table.concat(lines, ' | ') end
        end
        for _, m in ipairs(scan.by_product and scan.by_product[name] or {}) do
          if #rows >= 3 then break end
          local state = m.e.valid and (api.status_name(m.e) or 'unknown')
          if state and state ~= 'working' then
            local lack = (not m.miner) and missing(m.e, m, nil) or {}
            local burnt = (state == 'burnt_result_full' or state == 'fuel_unusable') and api.burnt_line and try(api.burnt_line, m.e)
            -- Its input holding spoilage its recipe does not take (Sol, 22:08).
            local sp = (not m.miner) and slots.input_spoilage(m.e)
            -- Its output waiting on a chest with every slot used (Astra, Luna, shift19).
            local fc = FULL[state] and try(fullchest.of_machine, m.e)
            if fc then full_chests[#full_chests+1] = fc.line end
            -- (Y2) an item it lacks that its held-off feeder's source holds: held by that feeder's condition, no fix
            local held_txt, short = {}, {}
            for _, ing in ipairs(SHORT[state] and lack or {}) do
              local h = api.feeders_held and try(function() return api.feeders_held(m.e, ing, feed_budget) end)
              if h then
                held_txt[#held_txt+1] = ing .. ' ' .. h.line
                held[#held+1] = string.format('%s %s lacks %s: %s%s', m.e.name, at(m.e.position), ing, h.line,
                  h.set_by and '; set by ' .. table.concat(h.set_by, ' | ') or '')
              else short[#short+1] = ing end
            end
            rows[#rows+1] = string.format('%s %s %s%s%s%s%s%s', m.e.name, at(m.e.position), state, #lack > 0 and ' (lacks ' .. table.concat(lack, ', ') .. ')' or '',
              #held_txt > 0 and '; ' .. table.concat(held_txt, '; ') or '',
              burnt and ' (' .. burnt .. ')' or '', sp and '; ' .. sp.text or '',
              fc and string.format('; output into %s %s: %d/%d slots used (%s)', fc.name, at(fc.position), fc.used, fc.total, fc.fills) or '')
            for _, ing in ipairs(short) do
              if #fixes < FIX_MAX then fixes[#fixes+1] = fix_line(surface, force, m, ing) end
            end
          end
        end
        if #rows > 0 then where[#where+1] = name .. ': ' .. table.concat(rows, '; ') end
      end
      local target
      if a.per_min then
        ratechain = ratechain or require('ratechain'){}
        local made = {}
        for _, row in ipairs(chain.tree or {}) do made[row.item] = row.made_per_min end
        target = ratechain.plan(scan.by_product or {}, item, a.per_min, force, function(name) return made[name] end)
      end
      local shares = prototypes.fluid and prototypes.fluid[item] and not prototypes.item[item] and try(M.fluid_shares, surface, force, item) or nil
      return {item=item, surface=surface.name, line=chain.line, path=chain.path, root=chain.last, not_working=#where > 0 and where or nil,
        fixes=#fixes > 0 and fixes or nil, full_chests=#full_chests > 0 and full_chests or nil, steps=chain.tree, cut=chain.cut, target=target,
        held_by_feeders=#held > 0 and held or nil,
        stopped=#stopped > 0 and stopped or nil,
        shares=shares}
    end)
  end
  -- A shared fluid's users (B5, Sonnet, every shift: lubricant and heavy oil split between lines): every crafter of ours
  -- on the surface whose recipe takes it, by recipe: machines, how many work now, what they take at full speed (the
  -- recipe's amount at each machine's crafting speed) and that as a share of all the users' full-speed take, against what
  -- the surface used and made in the last 10 minutes.
  local SHARE_CRAFTERS = 4096
  function M.fluid_shares(surface, force, fluid)
    local list = try(function() return surface.find_entities_filtered{type={'assembling-machine', 'furnace'}, force=force, limit=SHARE_CRAFTERS} end) or {}
    local by, order, total, makers, make_rate = {}, {}, 0, 0, 0
    for _, e in ipairs(list) do
      local r = e.valid and try(function() return e.get_recipe() end)
      if r then
        local speed = try(function() return e.crafting_speed end) or 1
        local energy = try(function() return r.energy end) or 1
        for _, ing in ipairs(try(function() return r.ingredients end) or {}) do
          if ing.name == fluid then
            local g = by[r.name]
            if not g then g = {recipe=r.name, machines=0, working=0, per_min=0}; by[r.name] = g; order[#order+1] = g end
            g.machines = g.machines + 1
            if api.status_name and api.status_name(e) == 'working' then g.working = g.working + 1 end
            local rate = ing.amount * 60 * speed / energy
            g.per_min = g.per_min + rate; total = total + rate
          end
        end
        for _, pr in ipairs(try(function() return r.products end) or {}) do
          if pr.name == fluid then makers = makers + 1; make_rate = make_rate + (pr.amount or 0) * 60 * speed / energy end
        end
      end
    end
    if #order == 0 then return nil end
    table.sort(order, function(x, y) return x.per_min > y.per_min end)
    local stats = try(function() return force.get_fluid_production_statistics(surface) end)
    local function per(cat) return stats and (try(function() return stats.get_flow_count{name=fluid, category=cat, precision_index=defines.flow_precision_index.ten_minutes, count=true} end) or 0) / 10 or 0 end
    local lines = {string.format('%s on %s: used %d/min, made %d/min (last 10 min); %d maker%s at full speed %d/min; its users at full speed %d/min:',
      fluid, surface.name, math.floor(per('output') + 0.5), math.floor(per('input') + 0.5), makers, makers == 1 and '' or 's', math.floor(make_rate + 0.5), math.floor(total + 0.5))}
    for i, g in ipairs(order) do
      if i > 8 then lines[#lines+1] = string.format('+%d more recipes', #order - 8); break end
      lines[#lines+1] = string.format('%s: %d machine%s (%d working) take %d/min at full speed, %d%% of the users\' take',
        g.recipe, g.machines, g.machines == 1 and '' or 's', g.working, math.floor(g.per_min + 0.5), total > 0 and math.floor(g.per_min * 100 / total + 0.5) or 0)
    end
    if #list >= SHARE_CRAFTERS then lines[#lines+1] = string.format('the first %d crafters read', SHARE_CRAFTERS) end
    return lines
  end
  -- split (batch27 B4, Opus: where an ore goes now): every crafter of ours on the surface whose recipe takes the item
  -- (a furnace idle now: its previous recipe), grouped by recipe and place (within GAP tiles, as clusters), each group
  -- with how many work now, its take at full speed (the recipe's amount at each machine's crafting speed), and what its
  -- feeding inserters pick from: belts, requester or buffer chests (by logistic network), other chests, drills dropping
  -- straight in; then requester and buffer chests asking for it that feed none of those groups; against what the surface
  -- used and made in the last 10 minutes. Read only; how to change the split is the agent's.
  local SPLIT_CRAFTERS, SPLIT_GROUPS = 4096, 16
  -- A fluid (batch28 B4, Opus: where petroleum gas goes, 3 times): the same groups, each with the pipe segments its
  -- machines' input boxes of it are on (fluidbox.get_fluid_segment_id) and, per segment, the machines whose recipe
  -- makes it with their output on that segment.
  local function fluid_box_segments(e, fluid, out)
    local fb = try(function() return e.fluidbox end)
    for i = 1, fb and (try(function() return #fb end) or 0) or 0 do
      local f = try(function() return fb[i] end)
      local filter = try(function() return fb.get_filter(i) end)
      if (f and f.name == fluid) or (filter and filter.name == fluid) then
        local id = try(function() return fb.get_fluid_segment_id(i) end)
        if id then out[id] = true end
      end
    end
    return out
  end
  function M.split(surface, force, item)
    local list = try(function() return surface.find_entities_filtered{type={'assembling-machine', 'furnace'}, force=force, limit=SPLIT_CRAFTERS} end) or {}
    local fluid = prototypes.fluid and prototypes.fluid[item] and not prototypes.item[item]
    local groups, users = {}, {}
    local makers = {}
    for _, e in ipairs(list) do
      local r = e.valid and (try(function() return e.get_recipe() end) or (e.type == 'furnace' and try(function() return e.previous_recipe end)))
      if r and not try(function() return r.ingredients end) then
        local rn = type(r.name) == 'table' and r.name.name or try(function() return r.name end)
        r = rn and prototypes.recipe[rn] or nil
      end
      local amount = 0
      for _, ing in ipairs(r and try(function() return r.ingredients end) or {}) do if ing.name == item then amount = amount + (ing.amount or 0) end end
      if fluid and r then
        for _, pr in ipairs(try(function() return r.products end) or {}) do
          if pr.name == item then
            for id in pairs(fluid_box_segments(e, item, {})) do
              makers[id] = makers[id] or {}
              makers[id][e.name] = (makers[id][e.name] or 0) + 1
            end
          end
        end
      end
      if amount > 0 then
        local rate = amount * 60 * (try(function() return e.crafting_speed end) or 1) / ((try(function() return r.energy end)) or 1)
        local q = e.position
        local g
        for _, h in ipairs(groups) do
          if h.recipe == r.name and q.x >= h.x0 - GAP and q.x <= h.x1 + GAP and q.y >= h.y0 - GAP and q.y <= h.y1 + GAP then g = h; break end
        end
        if not g then g = {recipe=r.name, x0=q.x, y0=q.y, x1=q.x, y1=q.y, n=0, working=0, per_min=0, names={}, set={}, segments={}}; groups[#groups+1] = g end
        if fluid then fluid_box_segments(e, item, g.segments) end
        g.x0, g.y0, g.x1, g.y1 = math.min(g.x0, q.x), math.min(g.y0, q.y), math.max(g.x1, q.x), math.max(g.y1, q.y)
        g.n = g.n + 1; g.per_min = g.per_min + rate
        g.names[e.name] = (g.names[e.name] or 0) + 1
        if api.status_name and api.status_name(e) == 'working' then g.working = g.working + 1 end
        if e.unit_number then g.set[e.unit_number] = true; users[e.unit_number] = true end
      end
    end
    table.sort(groups, function(x, y) return x.per_min > y.per_min end)
    local total = 0
    for _, g in ipairs(groups) do total = total + g.per_min end
    -- what each group's feeding inserters pick from (a fluid: the pipe segments it draws from)
    local fed_from = {}
    for i, g in ipairs(groups) do
      if i > SPLIT_GROUPS then break end
      if fluid then
        local parts = {}
        local ids = {}
        for id in pairs(g.segments) do ids[#ids+1] = id end
        table.sort(ids)
        for _, id in ipairs(ids) do
          local by = {}
          for n, c in pairs(makers[id] or {}) do by[#by+1] = c .. ' ' .. n end
          table.sort(by)
          parts[#parts+1] = string.format('pipe segment #%s (%s)', tostring(id), #by > 0 and 'made on it by ' .. table.concat(by, ', ') or 'no machine making it is on it: tanks, pumps or a pipe in between')
        end
        g.from = #parts > 0 and table.concat(parts, '; ') or 'no input box of it read'
      else
      local src, belt_at = {}, nil
      for _, ins in ipairs(try(function() return surface.find_entities_filtered{type='inserter', force=force, area={{g.x0 - 6, g.y0 - 6}, {g.x1 + 6, g.y1 + 6}}} end) or {}) do
        local d = try(function() return ins.drop_target end)
        if d and d.valid and d.unit_number and g.set[d.unit_number] then
          local t = try(function() return ins.pickup_target end)
          local kind
          if not (t and t.valid) then kind = 'nothing to pick from'
          elseif BELT[t.type] then kind = 'belts'; belt_at = belt_at or t.position
          elseif t.type == 'logistic-container' then
            local ln = try(function() return t.logistic_network end)
            kind = string.format('%s chests%s', try(function() return t.prototype.logistic_mode end) or 'logistic', ln and ' of logistic network #' .. ln.network_id or ' (no network)')
            if t.unit_number then fed_from[t.unit_number] = true end
          elseif t.type == 'container' then kind = 'chests'
          else kind = t.name end
          src[kind] = (src[kind] or 0) + 1
        end
      end
      for _, dr in ipairs(try(function() return surface.find_entities_filtered{type='mining-drill', force=force, area={{g.x0 - 4, g.y0 - 4}, {g.x1 + 4, g.y1 + 4}}} end) or {}) do
        local d = try(function() return dr.drop_target end)
        if d and d.valid and d.unit_number and g.set[d.unit_number] then src['drills dropping straight in'] = (src['drills dropping straight in'] or 0) + 1 end
      end
      local parts = {}
      for k, n in pairs(src) do parts[#parts+1] = string.format('%s (%d %s)', k, n, k == 'drills dropping straight in' and 'drills' or 'inserters') end
      table.sort(parts)
      g.from = #parts > 0 and table.concat(parts, ', ') .. (belt_at and string.format('; a belt it takes from at %s', at(belt_at)) or '') or 'no inserter or drill feeds them'
      end
    end
    -- requester and buffer chests asking for it that feed none of the groups
    local lone, lone_ask = 0, 0
    for _, c in ipairs(not fluid and try(function() return surface.find_entities_filtered{type='logistic-container', force=force, limit=MAX_CHESTS} end) or {}) do
      local mode = try(function() return c.prototype.logistic_mode end)
      if (mode == 'requester' or mode == 'buffer') and not fed_from[c.unit_number] then
        local pt = try(function() return c.get_logistic_point(defines.logistic_member_index.logistic_container) end)
        local ask = 0
        for _, f in ipairs(pt and try(function() return pt.filters end) or {}) do
          local n = type(f.name) == 'table' and f.name.name or f.name
          if n == item then ask = ask + (f.count or 0) end
        end
        if ask > 0 then lone = lone + 1; lone_ask = lone_ask + ask end
      end
    end
    local stats = try(function() return fluid and force.get_fluid_production_statistics(surface) or force.get_item_production_statistics(surface) end)
    local function per(cat)
      return stats and (try(function()
        if not fluid then return qflow.flow(stats, item, cat, defines.flow_precision_index.ten_minutes, true) end
        return stats.get_flow_count{name=item, category=cat, precision_index=defines.flow_precision_index.ten_minutes, count=true}
      end) or 0) / 10 or 0
    end
    local lines = {string.format('%s on %s: used %d/min, made %d/min (last 10 min); %d group%s of machines take %d/min at full speed:', item, surface.name,
      math.floor(per('output') + 0.5), math.floor(per('input') + 0.5), #groups, #groups == 1 and '' or 's', math.floor(total + 0.5))}
    local rows = {}
    for i, g in ipairs(groups) do
      if i > SPLIT_GROUPS then lines[#lines+1] = string.format('+%d more groups', #groups - SPLIT_GROUPS); break end
      local names = {}
      for k, n in pairs(g.names) do names[#names+1] = n .. ' ' .. k end
      table.sort(names)
      lines[#lines+1] = string.format('%s near (%d,%d)-(%d,%d): %s (%d working) take %d/min at full speed, %d%% of the take; fed from %s',
        g.recipe, math.floor(g.x0), math.floor(g.y0), math.ceil(g.x1), math.ceil(g.y1), table.concat(names, ', '), g.working, math.floor(g.per_min + 0.5),
        total > 0 and math.floor(g.per_min * 100 / total + 0.5) or 0, g.from or '?')
      rows[#rows+1] = {recipe=g.recipe, box={x0=g.x0, y0=g.y0, x1=g.x1, y1=g.y1}, machines=g.n, working=g.working, per_min=math.floor(g.per_min * 10 + 0.5) / 10, from=g.from}
    end
    if lone > 0 then lines[#lines+1] = string.format('%d requester or buffer chest%s %s %d in all and feed%s none of these machines', lone, lone == 1 and '' or 's', lone == 1 and 'asks' or 'ask', lone_ask, lone == 1 and 's' or '') end
    if #list >= SPLIT_CRAFTERS then lines[#lines+1] = string.format('the first %d crafters read', SPLIT_CRAFTERS) end
    return {lines=lines, groups=rows, lone_requesters=lone > 0 and {chests=lone, asks=lone_ask} or nil}
  end
  -- requesters (batch30 B2, Sonnet 05:39: 12 advanced-circuit assemblers starved the low-density-structure row of plastic,
  -- whose requesters asked for none): who gets an item. Every requester or buffer chest of ours on the surface that asks
  -- for it, with its request, what it holds, what robots are bringing it now (its logistic point's targeted deliveries),
  -- the machines its inserters feed that use it (their take a minute at full speed, how many work) and whether its
  -- network's robots serve it now (bringing, met, or why not: no network, none free, no idle robot); served first, then
  -- unmet, then met. Then requester and buffer chests whose inserters feed machines that use the item while they ask for
  -- none of it, each with what they ask. Read only.
  -- Cost on world n (06:52, read only, bounded): a whole-surface find costs 2.4-5.8 ms even at limit 1-64 (crafters 8.7
  -- ms at 512), so the crafters come from the census's last pass (entity references, their recipes read now) and the
  -- chests from each logistic network's requester points (about 4 us a point); a find only when no pass has them yet.
  local REQ_ROWS, REQ_POINTS, REQ_USERS = 24, 4096, 1024
  function M.requesters(surface, force, item)
    local crafters, as_of = nil, nil
    if api.census_crafters then crafters, as_of = api.census_crafters(force, surface) end
    local found = crafters == nil
    if found then as_of = nil; crafters = try(function() return surface.find_entities_filtered{type={'assembling-machine', 'furnace'}, force=force, limit=SPLIT_CRAFTERS} end) or {} end
    -- each recipe's use of the item read once, by name (on world n a recipe's ingredients read for each of 771
    -- crafters took 3.9 ms)
    local uses, users, per_recipe = {}, {}, {}
    local function use_of(rn)
      local v = per_recipe[rn]
      if v == nil then
        local pr, amount = prototypes.recipe[rn], 0
        for _, ing in ipairs(pr and pr.ingredients or {}) do if ing.name == item then amount = amount + (ing.amount or 0) end end
        v = amount > 0 and {amount=amount, energy=pr.energy > 0 and pr.energy or 1} or false
        per_recipe[rn] = v
      end
      return v
    end
    for _, e in ipairs(crafters) do
      local r = e.valid and e.get_recipe()
      if not r and e.valid and e.type == 'furnace' then r = e.previous_recipe end
      local rn = r and r.name
      if rn and type(rn) ~= 'string' then rn = rn.name end
      local u = type(rn) == 'string' and use_of(rn)
      if u and e.unit_number then
        uses[e.unit_number] = {e=e, recipe=rn, rate=u.amount * 60 * e.crafting_speed / u.energy, working=api.status_name and api.status_name(e) == 'working' or false}
        users[#users+1] = e
      end
    end
    -- the requester and buffer chests whose inserters feed those machines: a small find round each one (its box and
    -- 2.5 tiles, a long inserter's reach; a cluster's whole box returned thousands of inserters on world n)
    local feeds = {}
    for i, m in ipairs(users) do
      if i > REQ_USERS then break end
      local bb = m.bounding_box
      for _, ins in ipairs(try(function() return surface.find_entities_filtered{type='inserter', force=force,
          area={{bb.left_top.x - 2.5, bb.left_top.y - 2.5}, {bb.right_bottom.x + 2.5, bb.right_bottom.y + 2.5}}} end) or {}) do
        local d = try(function() return ins.drop_target end)
        local u = d and d.valid and d.unit_number and uses[d.unit_number]
        local t = u and try(function() return ins.pickup_target end)
        local mode = t and t.valid and t.type == 'logistic-container' and try(function() return t.prototype.logistic_mode end)
        if (mode == 'requester' or mode == 'buffer') and t.unit_number then
          local f = feeds[t.unit_number] or {e=t, machines={}}
          feeds[t.unit_number] = f
          f.machines[d.unit_number] = u
        end
      end
    end
    -- what a chest asks of the item (and, with whole, of every item); the filters read is most of this read's cost
    local function asks_of(c, pt, whole)
      pt = pt or try(function() return c.get_logistic_point(defines.logistic_member_index.logistic_container) end)
      local all, mine = whole and {} or nil, 0
      for _, f in ipairs(pt and pt.filters or {}) do
        local n = f.name
        if type(n) == 'table' then n = n.name end
        local k = f.count or 0
        if n and k > 0 then
          if all then all[n] = (all[n] or 0) + k end
          if n == item then mine = mine + k end
        end
      end
      return mine, all, pt
    end
    local function fed_text(f)
      if not f then return 'feeds none of the machines that use it', 0 end
      local names, n, working, rate = {}, 0, 0, 0
      for _, u in pairs(f.machines) do
        n = n + 1; rate = rate + u.rate
        if u.working then working = working + 1 end
        local k = u.e.name .. ' (' .. u.recipe .. ')'
        names[k] = (names[k] or 0) + 1
      end
      local parts = {}
      for k, c in pairs(names) do parts[#parts+1] = c .. ' ' .. k end
      table.sort(parts)
      return string.format('feeds %s, %d working, taking %g/min at full speed', table.concat(parts, ', '), working, math.floor(rate * 10 + 0.5) / 10), rate
    end
    local nets, rows, unasked = {}, {}, {}
    -- the chests: every requester point of the surface's logistic networks whose owner is a requester or buffer chest,
    -- and the chests feeding the machines (one in no network among them)
    local chests, points, seen, read = {}, {}, {}, 0
    local LM = defines.logistic_mode or {}
    for _, ln in ipairs(try(function() return force.logistic_networks[surface.name] end) or {}) do
      for _, pt in ipairs(try(function() return ln.requester_points end) or {}) do
        read = read + 1
        if read > REQ_POINTS then break end
        local c = pt.owner
        if c and c.valid and c.type == 'logistic-container' and (pt.mode == nil or pt.mode == LM.requester or pt.mode == LM.buffer) and c.unit_number and not seen[c.unit_number] then
          seen[c.unit_number] = true; chests[#chests+1] = c; points[c.unit_number] = pt
        end
      end
    end
    for unit, f in pairs(feeds) do
      if not seen[unit] then
        local mode = try(function() return f.e.prototype.logistic_mode end)
        if mode == 'requester' or mode == 'buffer' then seen[unit] = true; chests[#chests+1] = f.e end
      end
    end
    for _, c in ipairs(chests) do
      do
        local f = c.unit_number and feeds[c.unit_number]
        local want, all, pt = asks_of(c, points[c.unit_number], f ~= nil)
        if want > 0 then
          local held = try(function() return c.get_item_count(item) end) or 0
          local coming = 0
          for _, t in ipairs(pt and try(function() return pt.targeted_items_deliver end) or {}) do
            if (type(t.name) == 'table' and t.name.name or t.name) == item then coming = coming + (t.count or 0) end
          end
          local ln = try(function() return c.logistic_network end)
          local net
          if ln then
            net = nets[ln.network_id]
            if not net then
              net = {id=ln.network_id, free=(try(function() return ln.get_item_count(item, 'providers') end) or 0) + (try(function() return ln.get_item_count(item, 'storage') end) or 0),
                idle=try(function() return ln.available_logistic_robots end) or 0, robots=try(function() return ln.all_logistic_robots end) or 0, chests=0}
              nets[ln.network_id] = net
            end
            net.chests = net.chests + 1
          end
          local state, rank
          if coming > 0 then state, rank = string.format('served now: robots bringing %d', coming), 1
          elseif held >= want then state, rank = 'met', 3
          elseif not ln then state, rank = 'unmet: in no logistic network', 2
          elseif net.free <= 0 then state, rank = string.format('unmet: none free in network #%d', net.id), 2
          elseif net.idle <= 0 then state, rank = string.format('unmet: no idle logistic robot in network #%d', net.id), 2
          else state, rank = string.format('unmet: network #%d holds %d free and has %d idle robots, none on the way yet', net.id, net.free, net.idle), 2 end
          local text, rate = fed_text(f)
          rows[#rows+1] = {rank=rank, rate=rate, row={chest=c.name, position=c.position, network=ln and ln.network_id or nil, asks=want, holds=held, coming=coming > 0 and coming or nil,
              use_per_min=rate > 0 and math.floor(rate * 10 + 0.5) / 10 or nil, state=state,
              line=string.format('%s %s%s: asks %d, holds %d; %s; %s', c.name, at(c.position), ln and ' #' .. ln.network_id or '', want, held, state, text)}}
        elseif f then
          local list = {}
          for n, k in pairs(all) do list[#list+1] = {n=n, k=k} end
          table.sort(list, function(x, y) return x.k > y.k or (x.k == y.k and x.n < y.n) end)
          local asks = {}
          for i = 1, math.min(3, #list) do asks[i] = list[i].n .. ' ' .. list[i].k end
          local text = fed_text(f)
          unasked[#unasked+1] = {chest=c.name, position=c.position, asks=#asks > 0 and table.concat(asks, ', ') .. (#list > 3 and ', ...' or '') or 'nothing',
            line=string.format('%s %s %s, and asks for no %s (asks %s)', c.name, at(c.position), text, item, #asks > 0 and table.concat(asks, ', ') .. (#list > 3 and ', ...' or '') or 'nothing')}
        end
      end
    end
    table.sort(rows, function(x, y) if x.rank ~= y.rank then return x.rank < y.rank end; if x.rate ~= y.rate then return x.rate > y.rate end; return x.row.line < y.row.line end)
    table.sort(unasked, function(x, y) return x.line < y.line end)
    local lines, out_rows = {}, {}
    local ids = {}
    for id in pairs(nets) do ids[#ids+1] = id end
    table.sort(ids)
    local nt = {}
    for _, id in ipairs(ids) do local n = nets[id]; nt[#nt+1] = string.format('network #%d: %d free in providers and storage, %d of %d logistic robots idle, %d chests asking', id, n.free, n.idle, n.robots, n.chests) end
    lines[1] = string.format('%s on %s: %d requester or buffer chest%s ask%s for it%s', item, surface.name, #rows, #rows == 1 and '' or 's', #rows == 1 and 's' or '', #nt > 0 and '; ' .. table.concat(nt, '; ') or '')
    for i, r in ipairs(rows) do
      if i > REQ_ROWS then lines[#lines+1] = string.format('+%d more chests asking', #rows - REQ_ROWS); break end
      lines[#lines+1] = r.row.line; out_rows[#out_rows+1] = r.row
    end
    for i, u in ipairs(unasked) do
      if i > REQ_ROWS then lines[#lines+1] = string.format('+%d more chests feeding its users without asking for it', #unasked - REQ_ROWS); break end
      lines[#lines+1] = u.line
    end
    if #users > REQ_USERS then lines[#lines+1] = string.format('the feeders of the first %d of %d machines using it read', REQ_USERS, #users) end
    if found and #crafters >= SPLIT_CRAFTERS then lines[#lines+1] = string.format('the first %d crafters read', SPLIT_CRAFTERS) end
    if read > REQ_POINTS then lines[#lines+1] = string.format('the first %d requester points read', REQ_POINTS) end
    return {lines=lines, requesters=out_rows, unasked=#unasked > 0 and unasked or nil,
      crafters_as_of=as_of and string.format('the census pass of %ds ago (a machine built since is not read)', math.floor((game.tick - as_of) / 60)) or 'found now'}
  end
  -- (d18 batch38 D2, Opus 18:23, 3 times about 20 min each: advanced circuits made and used at 216 a minute, and which
  -- machines or chests took them?) supply {item, consumers: "all"}: every machine of ours on the surface whose recipe
  -- takes the item (the census pass's crafters, no search), with its use a minute now (working: crafts a minute at its
  -- speed times the recipe's amount; productivity does not change what a craft takes) and at full speed, and every
  -- requester or buffer chest asking for it (supply requesters' rows: asks, holds, robots bringing it now, and what the
  -- machines its inserters feed take at full speed), the largest use first, CONSUMER_PAGE a call (from).
  local CONSUMER_PAGE = 24
  function M.consumers(p, surface, item, a)
    assert(a.consumers == 'all', 'consumers is "all": every machine whose recipe takes the item and every chest asking for it')
    assert(prototypes.item[item], 'consumers is for an item')
    local force = p.force
    local crafters, as_of = nil, nil
    if api.census_crafters then crafters, as_of = api.census_crafters(force, surface) end
    assert(crafters, 'the census pass has not read ' .. surface.name .. ' yet (it reads every surface in turn); try again in a minute')
    local per_recipe, rows, by_recipe, now_sum, full_sum, machines, working = {}, {}, {}, 0, 0, 0, 0
    for _, e in ipairs(crafters) do
      local r = e.valid and try(function() return e.get_recipe() end)
      if not r and e.valid and e.type == 'furnace' then r = try(function() return e.previous_recipe end) end
      local rn = r and (type(r.name) == 'string' and r.name or try(function() return r.name.name end))
      local u = rn and per_recipe[rn]
      if rn and u == nil then
        local pr, amount = prototypes.recipe[rn], 0
        for _, ing in ipairs(pr and pr.ingredients or {}) do if ing.name == item then amount = amount + (ing.amount or 0) end end
        u = amount > 0 and {amount=amount, energy=pr.energy > 0 and pr.energy or 1} or false
        per_recipe[rn] = u
      end
      if u then
        local status = api.status_name and api.status_name(e) or 'unknown'
        local full = u.amount * 60 * (try(function() return e.crafting_speed end) or 0) / u.energy
        local now = status == 'working' and full or 0
        machines = machines + 1
        if status == 'working' then working = working + 1 end
        now_sum, full_sum = now_sum + now, full_sum + full
        by_recipe[rn] = (by_recipe[rn] or 0) + 1
        rows[#rows+1] = {per_min=now, full=full, kind='machine', row={kind='machine', name=e.name, position={x=e.position.x, y=e.position.y}, recipe=rn, status=status,
          per_min=math.floor(now * 10 + 0.5) / 10, full_per_min=math.floor(full * 10 + 0.5) / 10,
          line=string.format('%s %s %s: %s; takes %g a minute now (%g at full speed)', e.name, at(e.position), rn, (status:gsub('_', ' ')),
            math.floor(now * 10 + 0.5) / 10, math.floor(full * 10 + 0.5) / 10)}}
      end
    end
    -- the chests asking for it (the requesters read, reused for the same item and surface)
    local key = string.format('requesters|%s|%s|%s', tostring(surface.index or surface.name), force.name, item)
    local req = M.reuse(key, function() return M.requesters(surface, force, item) end)
    local chests = 0
    for _, r in ipairs(req.requesters or {}) do
      chests = chests + 1
      local use = r.use_per_min or 0
      rows[#rows+1] = {per_min=use, full=use, kind='chest', row={kind='chest', name=r.chest, position=r.position, network=r.network, asks=r.asks, holds=r.holds,
        coming=r.coming, per_min=use, line=r.line}}
    end
    table.sort(rows, function(x, y)
      if x.per_min ~= y.per_min then return x.per_min > y.per_min end
      if x.full ~= y.full then return x.full > y.full end
      return x.row.line < y.row.line
    end)
    local from = math.max(1, math.floor(tonumber(a.from) or 1))
    local out_rows, lines = {}, {}
    for i = from, math.min(#rows, from + CONSUMER_PAGE - 1) do out_rows[#out_rows+1] = rows[i].row; lines[#lines+1] = rows[i].row.line end
    local rc = {}
    for k, n in pairs(by_recipe) do rc[#rc+1] = n .. ' ' .. k end
    table.sort(rc)
    local last = from + #out_rows - 1
    local head = string.format('%s on %s: %d machine%s take it (%s), %d working, %g a minute now (%g at full speed); %d requester or buffer chest%s ask for it%s',
      item, surface.name, machines, machines == 1 and '' or 's', #rc > 0 and table.concat(rc, ', ') or 'no recipe of ours', working,
      math.floor(now_sum * 10 + 0.5) / 10, math.floor(full_sum * 10 + 0.5) / 10, chests, chests == 1 and '' or 's',
      last < #rows and string.format('; %d-%d of %d shown, the largest use first; from %d for the next', from, last, #rows, last + 1) or '')
    table.insert(lines, 1, head)
    return {item=item, surface=surface.name, machines=machines, working=working, per_min=math.floor(now_sum * 10 + 0.5) / 10, full_per_min=math.floor(full_sum * 10 + 0.5) / 10,
      chests=chests, rows=out_rows, lines=lines, line=head, from=from, next_from=last < #rows and last + 1 or nil,
      note='machines from the census pass (' .. (as_of and string.format('%ds ago', math.floor((game.tick - as_of) / 60)) or 'now') .. '; one built since is not in it); a chest\'s use is what the machines its inserters feed take at full speed (robot deliveries are not kept over time); labs, rocket silos and hand crafting not counted. Read only'}
  end
  local function packs_of(force)
    local tech, packs = force.current_research, {}
    for _, ing in ipairs(tech and tech.research_unit_ingredients or {}) do packs[ing.name] = true end
    return packs
  end
  M.packs_of = packs_of
  -- throughput (Sol, 19:50: a standard inserter capped green circuits at 37.5/min): the makers' inserters in and out
  -- and the users' feeders against each machine's recipe at full speed (craftrate.feed); the first 5 short of it, of up
  -- to 64 makers and 64 users looked at.
  local FEED_MACHINES, FEED_LINES = 64, 5
  function M.throughput(t)
    local feed = M.feed or api.feed
    if not feed then return nil end
    local lines, looked, seen = {}, 0, {}
    local function check(e, into, from)
      if #lines >= FEED_LINES or seen[e.unit_number] or not e.valid then return end
      seen[e.unit_number] = true
      looked = looked + 1
      local fd = try(function() return feed(e, into, from) end)
      if fd then lines[#lines+1] = fd.line end
    end
    for k, m in ipairs(t.makers) do if k > FEED_MACHINES then break end check(m.e, m.into, m.from) end
    for k, u in ipairs(t.users) do
      if k > FEED_MACHINES then break end
      if not u.lab then
        local into = {}
        for _, f in ipairs(u.feeders) do into[#into+1] = f.e end
        check(u.e, into, nil)
      end
    end
    if #lines == 0 then return nil end
    return lines
  end
  -- For trace.lua: the same inventory reads.
  M.helpers = {inventory=inventory, count=count, input_of=input_of, output_of=output_of, recipe_of=recipe_of, kind_of=kind_of,
    main=function(e) return inventory(e, MAIN[e.type] or 'chest') end}

  -- compact (Muse 06:21: supply and science run to thousands of tokens, a dozen times a shift): the lines with the
  -- places and the minutes only. A makers, consumers, requesters or split read keeps its own lines, each machine and
  -- chest with its position (d20 batch63 Y3, Astra #1543 and Luna: consumers "all" with compact failed on chests, a
  -- count there, and makers, requesters and split came back with no lines).
  function M.compact(out)
    if type(out) ~= 'table' then return out end
    local keep = {item=out.item, surface=out.surface, compact=true, as_of=out.as_of, clock=out.clock, team=out.team, chat=out.chat}
    if out.flow == nil and type(out.lines) == 'table' then
      local lines = {}
      if type(out.line) == 'string' and out.line ~= out.lines[1] then lines[1] = out.line end
      for _, l in ipairs(out.lines) do lines[#lines+1] = tostring(l) end
      keep.lines, keep.from, keep.next_from = lines, out.from, out.next_from
      return keep
    end
    local lines = {}
    local function add(l) if l then lines[#lines+1] = tostring(l) end end
    local function first(list, n, cut)
      if type(list) ~= 'table' then return nil end
      local parts = {}
      for i, l in ipairs(list) do if i <= n then parts[#parts+1] = cut and (tostring(l):gsub(';.*$', '')) or tostring(l) end end
      return #parts > 0 and table.concat(parts, ' | ') or nil
    end
    add(out.flow); add(out.uncounted and ('uncounted: ' .. tostring(out.uncounted)) or nil); add(out.where and ('where: ' .. tostring(out.where)) or nil); add(type(out.makers) == 'string' and out.makers or nil)
    local mk = first(out.makers_worst, 3); if mk then add('makers stopped: ' .. mk) end
    local us = first(out.users_worst, 3, true); if us then add('users stopped: ' .. us) end
    local ch = first(out.chests, 3); if ch then add('chests: ' .. ch) end
    if type(out.surplus_chest) == 'table' and out.surplus_chest.line then add('surplus: ' .. (tostring(out.surplus_chest.line):gsub(';.*$', ''))) end
    keep.lines = lines
    return keep
  end

  M.schema = {supply = {consumers='"all", with an item (d18 batch38 D2): every machine of ours on the surface whose recipe takes it and every requester or buffer chest asking for it, the largest use first, 24 a call (from: next_from): a machine with recipe, status, its take a minute now (working: at its speed) and at full speed; a chest with asks, holds, coming, and what the machines its inserters feed take; machines, working, per_min, full_per_min, chests, rows, lines, next_from',makers='"all", with an item: every machine of ours on the surface whose recipe makes it, nearest you first, 24 a call (from: next_from), from the census pass\'s lists: each with position, recipe, status and why when it stops (its own circuit or logistic condition and what it reads now; an input inserter off by its condition; the ingredients short), its rate now (a minute), its inputs against one craft (name have/needed), what its output holds, and what its output inserters drop into; makers, by_status, by_recipe, rows, lines, next_from',from='with makers or consumers: the first row (next_from of the last call)',requesters='true, with an item (Sonnet: a row starved while its requesters asked for none): who gets it: every requester or buffer chest in our logistic networks on the surface asking for it (one in no network only when it feeds the machines; the machines from the census pass, crafters_as_of says when), with asks, holds, coming (robots bringing it now), the machines its inserters feed that use it (how many work, their take a minute at full speed) and state (served now, met, or unmet and why: no network, none free, no idle robot, none on the way yet); served first, then unmet, then met; per network its free stock and idle robots; then unasked: requester and buffer chests whose inserters feed machines that use it while they ask for none of it, with what they ask. lines, requesters [{chest, position, network, asks, holds, coming, use_per_min, state, line}], unasked [{chest, position, asks, line}]. Read only',split='true, with an item or a fluid (a fluid: each group fed from the pipe segments its input boxes are on, each with the machines making it there): where it goes now: every crafter of ours on the surface whose recipe takes it, grouped by recipe and place (within 12 tiles), each group with machines, how many work, its take at full speed and share of the take, and what its feeding inserters pick from (belts, requester or buffer chests by logistic network, chests, drills dropping straight in); then the requester and buffer chests asking for it that feed none of them; against the surface\'s use and make in the last 10 min: lines, groups [{recipe, box, machines, working, per_min, from}], lone_requesters. Read only',all_stopped='true: makers_stopped and users_stopped: every one not working, grouped by cluster (within 12 tiles of a group\'s box): count, box, by name and state (missing ingredients), every position (at most 256 a read)',compact='true: lines only (flow, where, makers, the stopped makers and users by position, the chests holding most), as the dozen reads a shift need; with makers, consumers, requesters or split: that read\'s lines (each machine and chest with its position), from and next_from',item='item or fluid name; fluids return 10-minute flow, connected segment stock/capacity, makers and users by status', surface='optional surface name (default yours)', near='optional {x,y}: only this area (machines, chests, belts, inserters, requesters); network totals stay whole; fluid segments touching it include their whole connected stock',
    radius='with near: 1..512 tiles (default 64); alone: that far around you, on your surface',
    returns='one read, the same for everyone: scope_line and placed (an item that places a vehicle: where counts it stored, as items; placed: our vehicles of it standing in the world on every surface, as where_is gives); flow (made/used in 10 min; an item that spoils adds that the production statistics leave spoiling out: made counts crafts with a productivity bonus\'s extra, used counts ingredients and fuel burned); uncounted (an item that spoils, whole surface only: against the last whole-surface supply of it 1-60 min before, made, used, held then and now, and what left uncounted (then + made - used - now: spoiled, or carried off the surface), a minute too); made_by_spoiling (an item others spoil into: each source, how many are held in the places read and how many spoil within 5 min; the production statistics do not count spoiling); where (the total and each place: belts, chests by kind, landing pads, platform hubs, vehicles, machine outputs, users\' inputs, silo rockets, labs, inserter hands, robots, fuel slots (machines, heating towers, boilers, vehicles: a fuel), on the ground (whole surface: the ground watch\'s last pass), characters); surplus_chest (the largest unreserved stock outside requester/buffer chests, with held and robot-pickup reservations); belt_lines (where it sits on belts: the belt tiles holding it joined into lines (side by side; an empty tile or an underground splits one), the 5 holding the most: "N on K belt tiles (x1,y1)-(x2,y2); most M at (x,y); out end (x,y) n, in end (x,y) n" (out: its items move on to no belt of the line; in: nothing of the line feeds it), then how many more lines hold how many); chests (largest 5; what a requester or buffer chest asks for; any other chest its free slots, e.g. 0/48 slots free); full_chests (chests with every slot used that the makers\' output inserters wait on or that hold the item: slots used/total, what fills them (item and count, the most slots first), the machines whose output waits on it); networks (per logistic network with a requester for it: providers, storage and buffers held, reserved and free, its requester chests\' stock, robots carrying it, due at requesters, logistic robots idle/out/carrying/charging, requesters met/on the way/unmet with reasons; then up to 5 unmet with position, have/want and reason: not in a logistic network, logistics off, off by its circuit condition, inventory full (every slot taken: what fills them, the most slots first, spoilage named; before any robot reason), no idle robots, all N held are reserved, only buffer chests hold it, none in providers or storage, below its minimum delivery, free stock and idle robots); makers, users (assemblers, furnaces, silos; labs for packs the research needs: counts by status with the missing ingredients); makers_worst, users_worst (3 with positions; a short one whose input inserter is off by its circuit or logistic condition, or whose requester asks for less than one craft, first: the condition and what its source holds; a user\'s stock, the feeder carrying it and that source\'s request, the nearest stock); feeders (inserters into users by status, what the waiting ones\' sources hold); takers (inserters out of makers); throughput (up to 5 makers or users whose inserters in, or a maker\'s out, carry less than its recipe at full speed: each inserter\'s rate, the share of full speed, how many like its fastest it takes); counted; spoil (a spoilable item: the first stack to spoil, where and when, % spoiled, how many of those read spoil within 5 min); freshness (its spread over every place read: count, least and most spoiled stack, the count-weighted spoiled %, how many under 25%, 25-50%, 50-75%, 75%+, and how many spoil within 10, 30 and 60 min; chests adds each one\'s least and most spoiled and count-weighted %); hatch instead for an item that hatches into enemies when it spoils (pentapod-egg, biter-egg): into what, the first to hatch and when; returned (a maker\'s recipe that gives or takes it with ignored_by_stats, pentapod-egg\'s own: what a craft gives, takes and gives back, what the statistics count as made and used (the returned amount on neither side: made is the net), and with one such recipe making all of it at one productivity its crafts, out, back in and net a minute from made); used_by (what used counts besides made: the recipes taking it (each craft\'s ingredient past ignored_by_stats), the burners holding or burning it (fuel burned counts as used; their number, burning now, held, rate at full power), turrets holding it (ammo), and what used leaves out: spoiling or hatching, what is carried off the surface). Read only'}}

  function M.supply(p, a)
    local item = a.item
    assert(type(item) == 'string' and (prototypes.item[item] or (prototypes.fluid and prototypes.fluid[item])), 'item must be an item or fluid name')
    local surface = p.surface
    if a.surface ~= nil then
      assert(type(a.surface) == 'string', 'surface must be a surface name')
      surface = game.get_surface(a.surface)
      assert(surface, 'no surface ' .. a.surface)
    end
    -- (d18 batch37 A1) every maker of the item on the surface, a row each (makersall.lua)
    if a.makers ~= nil then return api.makers_all(p, item, surface, a) end
    if a.consumers ~= nil then return M.consumers(p, surface, item, a) end
    if a.requesters ~= nil then
      assert(a.requesters == true, 'requesters is true')
      assert(prototypes.item[item], 'requesters is for an item: chests ask for items')
      -- about 18 ms on Nauvis of world n (06:58: 775 crafters, 1204 requester points): reused for the same item and surface
      local key = string.format('requesters|%s|%s|%s', tostring(surface.index or surface.name), p.force.name, item)
      local out = M.reuse(key, function() return M.requesters(surface, p.force, item) end)
      local copy = {}
      for k, v in pairs(out) do copy[k] = v end
      out = copy
      out.item, out.surface = item, surface.name
      out.note = 'take at full speed: each machine\'s recipe at its crafting speed; robots bringing: what the game has robots carrying to that chest now. Read only'
      return out
    end
    if a.split ~= nil then
      assert(a.split == true, 'split is true')
      local out = M.split(surface, p.force, item)
      out.item, out.surface = item, surface.name
      out.note = 'take at full speed: each machine\'s recipe at its crafting speed; used and made: the surface\'s production statistics. Read only'
      return out
    end
    local area
    if a.near ~= nil then area = {position=api.position(a.near), radius=api.integer(a.radius, 64, 1, 512, 'radius')}
    elseif a.radius ~= nil then
      -- radius alone: around you, on your surface (round1650d: Grok's supply {item, radius: 120} was refused, "radius
      -- needs near", twice in shift13; Luna too).
      assert(surface == p.surface, 'radius needs near {x,y} on another surface')
      area = {position={x=math.floor(p.position.x + 0.5), y=math.floor(p.position.y + 0.5)}, radius=api.integer(a.radius, 64, 1, 512, 'radius')}
    end
    local force = p.force
    local key = string.format('supply|%s|%s|%s|%s', tostring(surface.index or surface.name), force.name, item,
      area and string.format('%g,%g,%g', area.position.x, area.position.y, area.radius) or '')
    local out = M.reuse(key, function() return M.supply_fresh(surface, force, item, area) end)
    -- all_stopped: every maker and user not working, by cluster (E4); else those lines are left out
    assert(a.all_stopped == nil or type(a.all_stopped) == 'boolean', 'all_stopped is true or false')
    if type(out) == 'table' and not a.all_stopped and (out.makers_stopped or out.users_stopped) then
      local copy = {}
      for k, v in pairs(out) do copy[k] = v end
      copy.makers_stopped, copy.users_stopped = nil, nil
      out = copy
    end
    return out
  end
  -- The items that spoil into item (copper-bacteria into copper-ore): names, memoized.
  local spoil_src = {}
  function M.spoil_sources(item)
    if spoil_src[item] then return spoil_src[item] end
    local out = {}
    for name, proto in pairs(prototypes.item) do
      local r = try(function() return proto.spoil_result end)
      if r and r.name == item then out[#out+1] = name end
    end
    table.sort(out)
    spoil_src[item] = out
    return out
  end
  -- (d24 batch182 QY1, Astra #2044: "Does native production statistics or supply made already subtract ignored seed?
  -- Team almost double-subtracted x0.6"; "recipe-only supply consumers missed egg disposal burners ... Please expose
  -- these sinks.") Measured on a private copy of world n's shift70 save, Gleba over 66 s: six breeders at +50% made 109
  -- crafts and 54 productivity completions, 272 eggs out and 109 back in; the statistics counted 163 made (the net) and
  -- 166 used = 138 agricultural science crafts + 28 eggs a heating tower burned (fuel burned counts as used). A heating
  -- tower burns max_energy_usage / effectivity (40 MW / 2.5 = 16 MW: 192 eggs a minute at full power).
  local function mean(p) return (p.amount or (((p.amount_min or 0) + (p.amount_max or 0)) / 2)) * (p.probability or 1) + (p.extra_count_fraction or 0) end
  local function num(n) return math.floor(n * 10 + 0.5) / 10 end
  -- One recipe's terms for item: out a craft, out a productivity completion, in a craft, and each side's ignored_by_stats.
  local function terms(recipe, item)
    local x = {out=0, extra=0, ['in']=0, ignored_out=0, ignored_in=0}
    for _, p in ipairs(try(function() return recipe.products end) or {}) do
      if p.name == item then
        local a = mean(p)
        x.out, x.extra, x.ignored_out = x.out + a, x.extra + math.max(0, a - (p.ignored_by_productivity or 0)), x.ignored_out + (p.ignored_by_stats or 0)
      end
    end
    for _, i in ipairs(try(function() return recipe.ingredients end) or {}) do
      if i.name == item then x['in'], x.ignored_in = x['in'] + (i.amount or 0), x.ignored_in + (i.ignored_by_stats or 0) end
    end
    return x
  end
  local function productivity(e, recipe, force)
    local p = (try(function() return e.productivity_bonus end) or 0) + (try(function() return force.recipes[recipe.name].productivity_bonus end) or 0)
    local cap = try(function() return prototypes.recipe[recipe.name].maximum_productivity end) or 3
    return math.min(p, cap)
  end
  -- The makers whose recipe gives or takes item with ignored_by_stats: per recipe, what a craft gives, takes and gives
  -- back, and what the statistics count; with one such recipe making all of it at one productivity, its rates from made.
  function M.returned_lines(t, item, force, made10)
    local by, order = {}, {}
    for _, m in ipairs(t.makers) do
      local name = m.recipe and m.recipe.name
      local g = name and by[name]
      if name and not g then
        local x = terms(m.recipe, item)
        if x.ignored_out > 0 or x.ignored_in > 0 then g = {name=name, x=x, n=0, prods={}}; by[name] = g; order[#order+1] = name end
      end
      if g then
        g.n = g.n + 1
        local p = productivity(m.e, m.recipe, force)
        g.prods[p] = (g.prods[p] or 0) + 1
      end
    end
    if #order == 0 then return nil end
    local out = {}
    for _, name in ipairs(order) do
      local g, x = by[name], by[name].x
      local ps = {}
      for p in pairs(g.prods) do ps[#ps+1] = p end
      table.sort(ps)
      local one = #ps == 1 and ps[1] or nil
      local back = math.min(x.ignored_out, x.out, x.ignored_in, x['in'])   -- given back: ignored on both sides
      local per = math.max(0, x.out - x.ignored_out)
      local ptext = #ps == 1 and string.format('productivity +%d%%', math.floor(ps[1] * 100 + 0.5))
        or string.format('productivity +%d%% to +%d%%', math.floor(ps[1] * 100 + 0.5), math.floor(ps[#ps] * 100 + 0.5))
      local line = string.format('the recipe %s on %d machine%s (%s) gives %g %s a craft and %g a productivity completion%s; the production statistics count %g a craft and %g a productivity completion as made%s',
        name, g.n, g.n == 1 and '' or 's', ptext, num(x.out), item, num(x.extra), x['in'] > 0 and string.format(', and takes %g back in a craft', num(x['in'])) or '',
        num(per), num(x.extra), back > 0 and string.format(' and %g a craft as used: the %g it gives back is ignored_by_stats, on neither side%s', num(math.max(0, x['in'] - x.ignored_in)), num(back),
          x.ignored_in >= x['in'] and back == x.ignored_out and ', so made counts the net' or '')
          or string.format(' (%g a craft out ignored_by_stats)', num(x.ignored_out)))
      local stat = per + (one or 0) * x.extra
      if one and #order == 1 and g.n == #t.makers and stat > 0 then
        local crafts = made10 / 10 / stat
        line = line .. string.format('. From made %d in the last 10 min: about %g crafts/min, %g/min out, %g/min back in, net %g/min', made10, num(crafts),
          num(crafts * (x.out + one * x.extra)), num(crafts * x['in']), num(crafts * (x.out + one * x.extra - x['in'])))
      end
      out[#out+1] = line
    end
    return out
  end
  -- What uses item up on the surface besides the recipes, as the statistics' used counts it: fuel burned, ammo fired,
  -- packs researched with; and what used leaves out.
  function M.used_by(t, item, force, surface, area)
    local lines = {}
    local by, order = {}, {}
    for _, u in ipairs(t.users) do
      local name = u.recipe and u.recipe.name
      if name then
        if not by[name] then by[name] = {n=0, x=terms(u.recipe, item)}; order[#order+1] = name end
        by[name].n = by[name].n + 1
      end
    end
    if #order > 0 then
      local parts = {}
      for _, name in ipairs(order) do
        local g = by[name]
        parts[#parts+1] = string.format('%s x%d (%g a craft%s)', name, g.n, num(g.x['in']),
          g.x.ignored_in > 0 and string.format(', %g of it counted: %g ignored_by_stats', num(math.max(0, g.x['in'] - g.x.ignored_in)), num(g.x.ignored_in)) or '')
      end
      lines[#lines+1] = 'recipes (used counts each craft\'s ingredient past ignored_by_stats): ' .. table.concat(parts, ', ')
    end
    local fv = try(function() return prototypes.item[item].fuel_value end) or 0
    if fv > 0 then
      local parts, holders = {}, {}
      for name in pairs(t.burners or {}) do holders[#holders+1] = name end
      table.sort(holders)
      for _, name in ipairs(holders) do
        local b = t.burners[name]
        local proto = try(function() return b.e.prototype end)
        local use = proto and try(function() return proto.get_max_energy_usage() end)
        local eff = proto and try(function() return proto.burner_prototype.effectivity end) or 1
        local rate = use and eff > 0 and use / eff * 3600 / fv
        parts[#parts+1] = string.format('%s x%d (%d burning it now, %d in fuel slots%s)', name, b.n, b.burning, b.held,
          rate and string.format(', up to %g/min at full power', num(rate * b.n)) or '')
      end
      lines[#lines+1] = 'burned as fuel (counted in used; the game keeps no count per burner): ' .. (#parts > 0 and table.concat(parts, ', ')
        or 'no heating tower, boiler or burner generator here holds or burns it; a machine\'s or vehicle\'s fuel slot is in where')
    end
    if try(function() return prototypes.item[item].type end) == 'ammo' then
      local turrets = try(function() return surface.find_entities_filtered{type='ammo-turret', force=force, position=area and area.position, radius=area and area.radius, limit=4096} end) or {}
      local n, held = 0, 0
      for _, e in ipairs(turrets) do
        local c = try(function() return e.get_item_count(item) end) or 0
        if c > 0 then n, held = n + 1, held + c end
      end
      lines[#lines+1] = string.format('fired as ammo (counted in used; the game keeps no count per turret): %d of %d turrets hold %d', n, #turrets, held)
    end
    local h = api.spoil and api.spoil.hatch and api.spoil.hatch(item)
    local spoils = api.spoil and api.spoil.spoils and api.spoil.spoils(item)
    local left = {}
    if spoils then
      left[#left+1] = string.format('%s (%d of those read within 5 min)', h and 'hatching into enemies' or 'spoiling', t.spoil_soon or 0)
    end
    left[#left+1] = 'what is carried off the surface (rockets, cargo pods, vehicles, characters)'
    lines[#lines+1] = 'not counted in used: ' .. table.concat(left, '; ')
    return lines
  end
  function M.supply_fresh(surface, force, item, area)
    if prototypes.fluid and prototypes.fluid[item] then return M.fluid_supply(surface,force,item,area) end
    local packs = packs_of(force)
    -- (d17 batch15 A2, Grok ~6x: copper ore made by copper bacteria spoiling read "made 0") the items that spoil into it
    -- are read in the same pass; the production statistics do not count spoiling
    local want, sources = {[item]=true}, M.spoil_sources(item)
    for _, n in ipairs(sources) do want[n] = true end
    local scan = M.scan(surface, force, want, {area=area, packs=packs})
    local t = scan.items[item]
    local stats = try(function() return force.get_item_production_statistics(surface) end)
    local function flow(category)
      local n = stats and try(function() return qflow.flow(stats, item, category, defines.flow_precision_index.ten_minutes, true) end)
      return n and math.floor(n + 0.5) or 0
    end
    -- (d20 batch122 CE2) the whole surface: stacks on the ground as the ground watch last binned them
    if not area and api.ground_index then
      local g = try(function() return api.ground_index(force, surface, item) end)
      if g and g.count > 0 then t.ground, t.ground_as_of = g.count, string.format('the ground watch\'s pass %ds ago', math.floor((game.tick - (g.as_of or game.tick)) / 60 + 0.5)) end
    end
    local total, parts = M.where(t)
    -- (d20 batch122 CE2, viewer Aurora 10:13: Gleba's nutrients made above used while the stock fell) an item that
    -- spoils: what the statistics leave out, and from a whole-surface read what left uncounted since the last one
    -- 1-60 min before (spoilflow.lua)
    local sf = api.spoilflow
    local spoils_it = sf and sf.spoils(item)
    local measured = spoils_it and not area and sf.sample(force, surface, item, total) or nil
    local out = {item=item, surface=surface.name, area=area and (at(area.position) .. ' radius ' .. area.radius) or nil,
      flow=string.format('made %d, used %d in the last 10 min on %s%s', flow('input'), flow('output'), surface.name, spoils_it and '; ' .. sf.NOTE or ''),
      uncounted=measured and (measured.line or measured.note or 'no whole-surface supply read of it 1 to 60 min before this one to measure against; this one is kept for the next') or nil,
      where=total > 0 and (total .. ': ' .. table.concat(parts, ', ')) or ('none on ' .. surface.name .. (area and ' in this area' or '')),
      chests=#t.chests > 0 and M.top_chests(t) or nil, surplus_chest=M.surplus_chest(t), belt_lines=t.belts > 0 and M.belt_lines(t) or nil}
    -- (d24 batch164 QG1, viewer Aurora 13:15) an item that places a vehicle: where is what is stored (as items); placed
    -- (as vehicles, on every surface) beside it
    local scope, pl
    if api.scope_line then
      local oks, l, q = pcall(api.scope_line, force, item, total, area and 'in this area' or 'on ' .. surface.name)
      if oks and l then scope, pl = l, q end
    end
    if scope then out.scope_line, out.placed, out.where = scope, pl, scope .. '; stored: ' .. out.where end
    local orbit = M.orbit_stock(surface, force, item)
    if orbit then
      out.in_orbit = orbit.line .. ' (platform hubs stopped over ' .. tostring(try(function() return surface.planet.name end) or surface.name) .. '; a drop brings it down)'
      out.where = out.where .. '; ' .. orbit.line
    end
    local lines = M.network_lines(t, scan)
    if #lines > 0 then out.networks = lines end
    local mr, ur
    out.makers, out.makers_worst, mr = M.machines(t, t.makers, 'makers', scan, packs)
    out.users, out.users_worst, ur = M.machines(t, t.users, 'users', scan, packs)
    -- kept for all_stopped (returned only when asked)
    out.makers_stopped = mr and M.clusters(mr) or nil
    out.users_stopped = ur and M.clusters(ur) or nil
    if out.makers_worst and #out.makers_worst == 0 then out.makers_worst = nil end
    if out.users_worst and #out.users_worst == 0 then out.users_worst = nil end
    -- (d18 batch37 B1, Grok) users short of it: what the surface holds of it that no network's providers and storage give
    if out.users_worst and api.elsewhere then out.elsewhere = try(function() return (api.elsewhere(force, surface, item, nil, area and area.position)) end) end
    out.feeders = M.feeders(t)
    out.takers = M.takers(t)
    out.full_chests = M.full_chests(t)
    out.throughput = M.throughput(t)
    out.counted = M.counted(scan)
    -- Spoilage: the first to spoil, or for an item that hatches into enemies (pentapod-egg) the first to hatch.
    local f = t.spoil_first
    if f and api.spoil then
      local h = api.spoil.hatch(item)
      local text = string.format('the first %s in %s at %s (%s) in %s (%d%% spoiled); %d of %d within 5 min', h and 'hatches' or 'spoils',
        f.name, at(f.position), f.kind, api.spoil.secs(f.tick - game.tick), math.floor(f.percent * 100 + 0.5), t.spoil_soon or 0, t.spoil_count or 0)
      if h then out.hatch = string.format('%s hatch into enemies (%s, %s): %s', item, h.entity, api.spoil.per_text(h), text) else out.spoil = text end
    end
    -- The spread over every place read (Sol, 22:25: the oldest at 91% while hundreds were at 15-30%).
    local spread = t.spread and t.spread[1]
    if spread and api.spoil and api.spoil.spread_text then out.freshness = api.spoil.spread_text(spread) end
    local by = {}
    for _, n in ipairs(sources) do
      local st = scan.items[n]
      local held = st and M.where(st) or 0
      by[#by+1] = held > 0 and string.format('%s spoils into %s: %d held in the places read, %d of them within 5 min (about %d a minute); the production statistics do not count it',
        n, item, held, st.spoil_soon or 0, math.floor((st.spoil_soon or 0) / 5 + 0.5))
        or string.format('%s spoils into %s: none held in the places read', n, item)
    end
    if #by > 0 then out.made_by_spoiling = by end
    out.returned = M.returned_lines(t, item, force, flow('input'))
    out.used_by = M.used_by(t, item, force, surface, area)
    return out
  end
  -- The fluid GUI shows the whole connected segment. Count it once even when
  -- several pipes, tanks or machine ports in the search belong to that segment.
  function M.fluid_supply(surface,force,fluid,area)
    local cap=2048
    local found=surface.find_entities_filtered{force=force,position=area and area.position,radius=area and area.radius,
      type={'pipe','pipe-to-ground','storage-tank','pump','offshore-pump','assembling-machine','furnace','rocket-silo',
        'mining-drill','boiler','generator','fluid-wagon','thruster','fusion-reactor','fusion-generator'},limit=cap}
    local seen,visible,segments={},{},{}
    local makers,users={count=0,states={},examples={}},{count=0,states={},examples={}}
    local total,capacity,read,n=0,0,0,0
    local platform=surface.platform
    local own_platform=platform and platform.force==force
    local function in_view(pos)
      if own_platform then return true end
      local cx,cy=math.floor(pos.x/32),math.floor(pos.y/32)
      visible[cx]=visible[cx] or {}
      if visible[cx][cy]==nil then visible[cx][cy]=force.is_chunk_visible(surface,{x=cx,y=cy}) end
      return visible[cx][cy]
    end
    local function before(a,b)
      if a.amount~=b.amount then return a.amount>b.amount end
      if a.id and b.id then return a.id<b.id end
      if a.at.position.x~=b.at.position.x then return a.at.position.x<b.at.position.x end
      return a.at.position.y<b.at.position.y
    end
    local function add(role,e)
      role.count=role.count+1
      local status=api.status_name(e) or 'unknown'
      role.states[status]=(role.states[status] or 0)+1
      if #role.examples<5 then role.examples[#role.examples+1]={name=e.name,position=e.position,status=status} end
    end
    for _,e in ipairs(found) do
      local pos,kind=e.position,e.type
      if in_view(pos) then
        read=read+1
        local boxes=e.fluidbox
        for i=1,boxes and #boxes or 0 do
          local id=boxes.get_fluid_segment_id(i)
          local key=id or tostring(e.unit_number or at(pos))..':'..i
          if not seen[key] then
            seen[key]=true
            local contents=boxes.get_fluid_segment_contents(i)
            local f=not contents and boxes[i]
            local amount=contents and contents[fluid] or (f and f.name==fluid and f.amount) or 0
            if amount>0 then
              local volume=boxes.get_capacity(i)
              total=total+amount; capacity=capacity+volume
              n=n+1
              local row={id=id,amount=amount,capacity=volume,at={position=pos}}
              if #segments<8 or before(row,segments[#segments]) then
                row.at.name=e.name
                segments[#segments+1]=row
                table.sort(segments,before)
                if #segments>8 then table.remove(segments) end
              end
            end
          end
        end
        local makes,uses=false,false
        local recipe=(kind=='assembling-machine' or kind=='furnace' or kind=='rocket-silo') and recipe_of(e)
        if recipe then
          for _,v in ipairs(recipe.products or {}) do if v.type=='fluid' and v.name==fluid then makes=true end end
          for _,v in ipairs(recipe.ingredients or {}) do if v.type=='fluid' and v.name==fluid then uses=true end end
        elseif kind=='mining-drill' or kind=='offshore-pump' then
          local products,required=miner_products(e)
          for _,name in ipairs(products) do if name==fluid then makes=true end end
          uses=required==fluid
        elseif kind~='pipe' and kind~='pipe-to-ground' and kind~='pump' and kind~='storage-tank' and kind~='fluid-wagon' then
          for _,box in ipairs(try(function() return e.prototype.fluidbox_prototypes end) or {}) do
            local filter=box.filter
            if filter and filter.name==fluid then
              makes=makes or box.production_type=='output'; uses=uses or box.production_type=='input'
            end
          end
        end
        if makes then add(makers,e) end
        if uses then add(users,e) end
      end
    end
    local stats=force.get_fluid_production_statistics(surface)
    local function flow(category)
      return stats.get_flow_count{name=fluid,category=category,precision_index=defines.flow_precision_index.ten_minutes,count=true}
    end
    local made,used=flow('input'),flow('output')
    return {item=fluid,fluid=fluid,surface=surface.name,unit='fluid units',area=area,
      made_10min=made,used_10min=used,flow=string.format('made %g, used %g in the last 10 min on %s',made,used,surface.name),
      stored=total,capacity=capacity,segments_count=n,segments=segments,makers=makers,users=users,
      scope='whole connected segments containing this fluid at visible entities in the search; each segment counted once, including parts outside the search area; at most 8 largest segments shown',
      counted={found=#found,visible=read,limit=cap,limited=#found>=cap}}
  end
  return M
end
