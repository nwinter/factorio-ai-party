-- launch_budget {surface, platform?, manifest?, reserve?, network?}: what the rockets our platforms' requests from a
-- planet ask for would take from the networks of its silos, against what those networks hold now (d27 batch260 LB, Sol
-- #2491: the K2 cargo staging audit pieced it together from repeated requests, platform, silo, inspect and recipe reads
-- of each ship: the exact network's stock, each ship's asks, holds and incoming pods, min payloads and rocket parts).
-- Read only; nothing made later is counted. Per request importing from the planet (sections switched on), as the game
-- fills it: unlaunched = asks (the request's min; a manifest's total) less what the hub holds (landed) less what
-- rockets launched to it carry (on the way, the hub GUI's in-transit count); a rocket carries the request's min payload,
-- else a full rocket by weight (2.0.77: a 220 gap with min payload 300 launched 300), so pods = unlaunched / payload
-- rounded up and the cargo is pods x payload. A rocket takes the silo's rocket_parts_required parts, each part one of
-- each rocket-part ingredient, and a part crafted gives 1 + productivity parts (the silo's modules and beacons with the
-- recipe's research, capped as the game caps it): ingredients per launch = parts / (1 + productivity), the
-- productivity bar carrying the fraction from rocket to rocket. Bounded: 16 silos, 64 platforms, 48 rows listed.
return function(api)
  local M = {}
  local MAX_SILOS, MAX_PLATFORMS, ROWS = 16, 64, 48
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function sname(x) if type(x) == 'string' then return x end return x and try(function() return x.name end) end
  local function at(q) return string.format('(%g,%g)', q.x, q.y) end
  local function key(name, q) return q == 'normal' and name or name .. '@' .. q end
  local function split(k)
    local name, q = k:match('^(.-)@(.+)$')
    if name then return name, q end
    return k, 'normal'
  end
  -- The silo's productivity as the game crafts its recipe: modules and beacons, with the recipe's research, capped.
  local function productivity(e)
    local recipe = try(function() return e.get_recipe() end)
    local b = (try(function() return e.productivity_bonus end) or 0)
      + (recipe and try(function() return e.force.recipes[recipe.name].productivity_bonus end) or 0)
    return math.min(b, recipe and try(function() return recipe.prototype.maximum_productivity end) or 3), recipe
  end
  -- A rocket's payload of an item: the request's min payload, else a full rocket by weight; and the full rocket.
  local function payload_of(name, mp)
    local lift = try(function() return prototypes.utility_constants.rocket_lift_weight end)
    local w = try(function() return prototypes.item[name].weight end)
    local full = lift and w and w > 0 and math.floor(lift / w) or nil
    local p = mp and mp > 0 and mp or full
    if p and full and p > full then p = full end
    return p, full
  end
  -- Where a platform is: here (in orbit of the planet), at another planet, or flying to its stop.
  local function where(pl, planet)
    local loc = try(function() return pl.space_location.name end)
    if loc == planet then return 'here', 'in orbit of ' .. planet end
    if loc then return 'elsewhere', 'at ' .. loc end
    local sch = try(function() return pl.schedule end)
    local rec = sch and sch.records and sch.records[sch.current or 1]
    local to = rec and rec.station
    if to == planet then return 'coming', 'flying to ' .. planet end
    return 'elsewhere', to and 'flying to ' .. to or 'in space'
  end
  local function whole(v, what)
    assert(type(v) == 'number' and v >= 0 and v == math.floor(v) and v < 2^31, what .. ' must be a whole number from 0')
    return v
  end
  local function item_known(name) return try(function() return prototypes.item[name] ~= nil end) end
  local function check_items(t, what)
    assert(type(t) == 'table' and next(t) ~= nil and t[1] == nil, what .. ' is {"item": count} (item@quality for one other than normal)')
    local out, n = {}, 0
    for k, v in pairs(t) do
      assert(type(k) == 'string', what .. ' keys are item names')
      local name, q = split(k)
      assert(item_known(name), what .. ': no item ' .. name)
      assert(try(function() return prototypes.quality[q] ~= nil end), what .. ': no quality ' .. q)
      n = n + 1
      out[key(name, q)] = v
    end
    assert(n <= 64, what .. ' names at most 64 items')
    return out
  end

  function M.read(p, a)
    local surface = p.surface
    if a.surface ~= nil then
      assert(type(a.surface) == 'string', 'surface is a planet name')
      surface = game.get_surface(a.surface)
      assert(surface, 'no surface ' .. a.surface)
    end
    local planet = try(function() return surface.planet.name end)
    assert(planet, surface.name .. ' is not a planet: give surface, the planet the rockets go up from')
    local force = p.force
    local cand
    if a.platform ~= nil then
      assert(type(a.platform) == 'string', 'platform is a platform name')
      for _, pl in pairs(force.platforms) do if pl.valid and pl.name == a.platform then cand = pl end end
      assert(cand, 'no platform of ours named ' .. a.platform)
    end
    local manifest = {}
    if a.manifest ~= nil then
      local m = check_items(a.manifest, 'manifest')
      for k, v in pairs(m) do
        if type(v) == 'table' then
          for f in pairs(v) do assert(f == 'count' or f == 'min_payload', 'a manifest entry is a count or {count, min_payload}') end
          manifest[k] = {count=whole(v.count, 'manifest ' .. k .. ' count'), min_payload=v.min_payload ~= nil and whole(v.min_payload, 'manifest ' .. k .. ' min_payload') or nil}
        else manifest[k] = {count=whole(v, 'manifest ' .. k)} end
      end
    end
    local reserve = {}
    if a.reserve ~= nil then
      for k, v in pairs(check_items(a.reserve, 'reserve')) do reserve[k] = whole(v, 'reserve ' .. k) end
    end
    assert(a.network == nil or type(a.network) == 'number', 'network is a logistic network id (a silo\'s, as this read names them)')

    -- The silos and their networks (the census pass's list, else one find of at most 16).
    local silos = api.census_typed and try(function() return api.census_typed(force, surface, 'rocket-silo') end)
    if not silos or #silos == 0 then silos = surface.find_entities_filtered{type='rocket-silo', force=force, limit=MAX_SILOS} end
    local nets, net_list, silo_rows, ings = {}, {}, {}, {}
    local per_launch, per_launch_min
    for _, e in ipairs(silos) do
      if e.valid and #silo_rows < MAX_SILOS then
        local ln = try(function() return surface.find_logistic_network_by_position(e.position, force) end)
        local id = ln and ln.network_id
        if a.network == nil or a.network == id then
          if ln and not nets[id] then nets[id] = {ln=ln, silos=0}; net_list[#net_list+1] = id end
          if ln then nets[id].silos = nets[id].silos + 1 end
          local prod, recipe = productivity(e)
          local req = try(function() return e.prototype.rocket_parts_required end) or 50
          local each = req / (1 + prod)
          for _, ing in ipairs(recipe and try(function() return recipe.ingredients end) or {}) do
            if ing.type == 'item' and not ings[ing.name] then ings[ing.name] = ing.amount; ings[#ings+1] = ing.name end
          end
          if not per_launch or each > per_launch then per_launch = each end
          if not per_launch_min or each < per_launch_min then per_launch_min = each end
          local built = try(function() return e.rocket_parts end) or 0
          local st = try(function() return e.rocket_silo_status end)
          local ready = st ~= nil and st == try(function() return defines.rocket_silo_status.rocket_ready end)
          local target = try(function() local t = e.transitional_request_target; return t and t.valid and t.name or nil end)
          silo_rows[#silo_rows+1] = {position=at(e.position), network=id, productivity=string.format('+%d%%', math.floor(prod * 100 + 0.5)),
            parts_per_rocket=req, ingredients_per_launch=math.floor(each * 100 + 0.5) / 100, parts_built=built, rocket_ready=ready or nil,
            filling_for=target, auto_requests=try(function() return e.use_transitional_requests end)}
        end
      end
    end
    assert(#silo_rows > 0, a.network and ('no silo of ours on ' .. planet .. ' in network ' .. a.network) or ('no rocket silo of ours on ' .. planet))
    table.sort(net_list)

    -- Each request importing from this planet that its hub lacks, by platform; the candidate's manifest items in its place.
    local rows, cand_rows, n_pl = {}, {}, 0
    local function add(list, r)
      local pay, full = payload_of((split(r.item)), r.min_payload)
      r.payload, r.full_rocket = pay, full
      r.unlaunched = math.max(0, r.asks - r.holds - r.on_the_way)
      r.pods = pay and math.ceil(r.unlaunched / pay) or nil
      r.cargo = r.pods and r.pods * pay or nil
      r.overshoot = r.cargo and r.cargo - r.unlaunched or nil
      list[#list+1] = r
    end
    local function hub_count(hub, name, q, cmp)
      return api.silo.count_q(function(id) return hub.get_item_count(id) end, name, q, cmp)
    end
    for _, pl in pairs(force.platforms) do
      local hub = pl.valid and try(function() return pl.hub end)
      if hub and hub.valid and n_pl < MAX_PLATFORMS then
        n_pl = n_pl + 1
        local state, place = where(pl, planet)
        local secs = try(function() return hub.get_logistic_sections() end)
        local coming
        local is_cand = cand and pl == cand
        for i = 1, secs and secs.sections_count or 0 do
          local sec = try(function() return secs.get_section(i) end)
          for _, f in ipairs(sec and sec.active ~= false and try(function() return sec.filters end) or {}) do
            local v = f.value
            local name = v and sname(v.name)
            if name and sname(f.import_from) == planet and (f.min or 0) > 0 then
              local q, cmp = api.silo.want(v)
              if not (is_cand and cmp == '=' and manifest[key(name, q)]) then
                local held = hub_count(hub, name, q, cmp)
                coming = coming or api.silo.on_the_way(hub)
                local way = 0
                for _, qn in ipairs(api.silo.qualities(q, cmp)) do way = way + (coming[name .. '@' .. qn] or 0) end
                if f.min > held + way then
                  add(is_cand and cand_rows or rows, {platform=pl.name, where=place, state=state, item=key(name, q), comparator=cmp ~= '=' and cmp or nil,
                    asks=f.min, holds=held, on_the_way=way, min_payload=f.minimum_delivery_count, section=i})
                end
              end
            end
          end
        end
      end
    end
    -- The manifest: totals the candidate's hub is to hold (with a platform: its hub's holding and incoming counted).
    local slots_needed, cand_hub = 0, cand and try(function() return cand.hub end)
    local coming = cand_hub and api.silo.on_the_way(cand_hub) or {}
    for k, m in pairs(manifest) do
      local name, q = split(k)
      local held = cand_hub and hub_count(cand_hub, name, q, '=') or 0
      local mp = m.min_payload
      if mp == nil and cand_hub then
        -- the platform's own request for it from this planet gives the payload
        local secs = try(function() return cand_hub.get_logistic_sections() end)
        for i = 1, secs and secs.sections_count or 0 do
          local sec = try(function() return secs.get_section(i) end)
          for _, f in ipairs(sec and sec.active ~= false and try(function() return sec.filters end) or {}) do
            local v = f.value
            if v and sname(v.name) == name and sname(f.import_from) == planet and api.silo.want(v) == q then mp = mp or f.minimum_delivery_count end
          end
        end
      end
      local r = {platform=cand and cand.name or nil, item=k, asks=m.count, holds=held, on_the_way=coming[name .. '@' .. q] or 0, min_payload=mp, manifest=true}
      add(cand_rows, r)
      local stack = try(function() return prototypes.item[name].stack_size end) or 1
      if r.cargo then slots_needed = slots_needed + math.ceil((held + r.on_the_way + r.cargo) / stack) - math.ceil((held + r.on_the_way) / stack) end
    end
    local order = {here=1, coming=2, elsewhere=3}
    table.sort(rows, function(x, y)
      if x.state ~= y.state then return order[x.state] < order[y.state] end
      if x.platform ~= y.platform then return x.platform < y.platform end
      return x.item < y.item
    end)
    table.sort(cand_rows, function(x, y) return x.item < y.item end)

    -- Totals: pods and cargo per item; ingredients for the pods' rockets at the silos' least productivity.
    local function sum(list, states)
      local t = {pods=0, cargo={}, unknown=0}
      for _, r in ipairs(list) do
        if not states or states[r.state] then
          if r.pods then t.pods = t.pods + r.pods; t.cargo[r.item] = (t.cargo[r.item] or 0) + r.cargo
          else t.unknown = t.unknown + 1 end
        end
      end
      return t
    end
    local cand_t = sum(cand_rows)
    local here_t = sum(rows, {here=true})
    local all_t = sum(rows)
    local function need(ts)
      local pods, cargo = 0, {}
      for _, t in ipairs(ts) do
        pods = pods + t.pods
        for k, n in pairs(t.cargo) do cargo[k] = (cargo[k] or 0) + n end
      end
      local items = {}
      for k, n in pairs(cargo) do items[k] = n end
      for _, ing in ipairs(ings) do items[ing] = (items[ing] or 0) + math.ceil(pods * per_launch * ings[ing] - 1e-9) end
      return pods, items, cargo
    end
    local stock_cache = {}
    local function stock(k)
      if stock_cache[k] then return stock_cache[k] end
      local name, q = split(k)
      local id = q == 'normal' and name or {name=name, quality=q}
      local n, by = 0, {}
      for _, nid in ipairs(net_list) do
        local c = math.max(0, try(function() return nets[nid].ln.get_item_count(id) end) or 0)
        n = n + c; by[#by+1] = string.format('%d: %d', nid, c)
      end
      stock_cache[k] = {n=n, by=table.concat(by, ', ')}
      return stock_cache[k]
    end
    local function budget(ts, label)
      local pods, items, cargo = need(ts)
      local list, short = {}, {}
      local keys = {}
      for k in pairs(items) do keys[#keys+1] = k end
      for k in pairs(reserve) do if not items[k] then keys[#keys+1] = k end end
      table.sort(keys)
      for _, k in ipairs(keys) do
        local s = stock(k)
        local parts = ings[k] and (items[k] - (cargo[k] or 0)) or nil
        local want = (items[k] or 0) + (reserve[k] or 0)
        local row = {item=k, cargo=cargo[k], for_rockets=parts, reserve=reserve[k], needs=want, networks_hold=s.n, short=want > s.n and want - s.n or nil}
        list[#list+1] = row
        if row.short then short[#short+1] = string.format('%s %d', k, row.short) end
      end
      return {scope=label, pods=pods, items=list, short=#short > 0 and table.concat(short, ', ') or 'none'}
    end
    local scopes = {}
    if #cand_rows > 0 then
      scopes[#scopes+1] = budget({cand_t}, 'the candidate alone')
      scopes[#scopes+1] = budget({cand_t, here_t}, 'the candidate with the asks of platforms in orbit now')
      scopes[#scopes+1] = budget({cand_t, all_t}, 'the candidate with every platform\'s asks from ' .. planet)
    else
      scopes[#scopes+1] = budget({here_t}, 'the asks of platforms in orbit now')
      scopes[#scopes+1] = budget({all_t}, 'every platform\'s asks from ' .. planet)
    end
    -- Short items: what the planet's other networks hold (not counted: robots of the silos' networks do not reach them).
    local elsewhere = {}
    for _, sc in ipairs(scopes) do
      for _, r in ipairs(sc.items) do
        if r.short and not elsewhere[r.item] then
          local name, q = split(r.item)
          local id = q == 'normal' and name or {name=name, quality=q}
          local parts = {}
          for _, o in pairs(try(function() return force.logistic_networks[surface.name] end) or {}) do
            if not nets[o.network_id] then
              local c = try(function() return o.get_item_count(id) end) or 0
              if c > 0 then parts[#parts+1] = string.format('network %d holds %d', o.network_id, c) end
            end
          end
          elsewhere[r.item] = #parts > 0 and table.concat(parts, ', ', 1, math.min(4, #parts)) or 'none'
        end
      end
    end
    for _, sc in ipairs(scopes) do
      for _, r in ipairs(sc.items) do r.networks_hold_by = stock(r.item).by; r.other_networks = r.short and elsewhere[r.item] or nil end
    end

    local function line(r)
      return string.format('%s %s%s: asks %d, holds %d, %d on the way, unlaunched %d; %s; %s', r.platform or 'manifest', r.item,
        r.comparator and ' (' .. r.comparator .. ')' or '', r.asks, r.holds, r.on_the_way, r.unlaunched,
        r.payload and string.format('payload %d (%s)', r.payload, r.min_payload and 'min payload' or 'full rocket by weight') or 'payload unknown (the item has no weight)',
        r.pods and string.format('%d pod%s, cargo %d%s', r.pods, r.pods == 1 and '' or 's', r.cargo, r.overshoot > 0 and string.format(' (%d over)', r.overshoot) or '') or 'pods unknown')
    end
    local cand_lines, comp_lines = {}, {}
    for _, r in ipairs(cand_rows) do cand_lines[#cand_lines+1] = line(r) end
    local more = 0
    for _, r in ipairs(rows) do
      if #comp_lines < ROWS then comp_lines[#comp_lines+1] = r.where .. ': ' .. line(r) else more = more + 1 end
    end
    local per = string.format('%g', math.floor(per_launch * 100 + 0.5) / 100)
    local ing_names = table.concat(ings, ', ')
    local out = {surface=surface.name, planet=planet, read_tick=game.tick,
      networks=(function()
        local t = {}
        for _, id in ipairs(net_list) do t[#t+1] = {network=id, silos=nets[id].silos} end
        return t
      end)(),
      silos=silo_rows,
      per_launch=string.format('%s of each of %s a rocket (the silos\' least productivity%s)', per, ing_names,
        per_launch_min and per_launch_min < per_launch and string.format('; the most productive takes %g', math.floor(per_launch_min * 100 + 0.5) / 100) or ''),
      candidate=#cand_lines > 0 and {platform=cand and cand.name or nil, rows=cand_lines, pods=cand_t.pods} or nil,
      competing=comp_lines, competing_more=more > 0 and more or nil,
      competing_pods={here=here_t.pods, all=all_t.pods},
      budgets=scopes,
      unknowns={'nothing made after read_tick is counted, nor what other machines and requester chests of these networks take from them meanwhile',
        'a platform not in orbit counts its asks with what its hub holds now: what it uses, makes or drops before it stops here is not known',
        'the game picks the silo and the request a rocket fills; a silo takes its ingredients from its own network',
        'parts_built (each silo\'s rocket parts made now) and ready rockets are not subtracted from the ingredients'}}
    if out.candidate and cand_hub and next(manifest) then
      out.candidate.hub_slots = string.format('the manifest\'s cargo takes %d more hub slots; the hub has %d free', slots_needed,
        try(function() return cand_hub.get_inventory(defines.inventory.hub_main).count_empty_stacks(true, false) end) or 0)
    end
    out.line = string.format('%s at tick %d: %d silo%s in network%s %s, %s a rocket; ', planet, game.tick, #silo_rows, #silo_rows == 1 and '' or 's',
      #net_list == 1 and '' or 's', table.concat(net_list, ', '), per)
      .. table.concat((function()
        local t = {}
        for _, sc in ipairs(scopes) do t[#t+1] = string.format('%s: %d pods, short %s', sc.scope, sc.pods, sc.short) end
        return t
      end)(), '; ')
    return out
  end

  M.schema = {launch_budget = {surface='optional planet the rockets go up from (default yours)',
    platform='optional platform name: the candidate; its requests from the planet (or the manifest) are counted apart from the other platforms\'',
    manifest='optional {"item": total} (item@quality for one other than normal; or {count, min_payload}): totals the candidate\'s hub is to hold, in place of its requests for those items; the payload is the platform\'s request\'s min payload for the item, else a full rocket by weight',
    reserve='optional {"item": count}: kept in the networks, added to what is needed',
    network='optional logistic network id: only the silos in that network (default every silo of ours on the planet, their networks together)',
    returns='read_tick; networks [{network, silos}]; silos [{position, network, productivity, parts_per_rocket, ingredients_per_launch, parts_built, rocket_ready, filling_for, auto_requests}]; '
      .. 'per_launch (each rocket-part ingredient a rocket takes at the silos\' least productivity: parts / (1 + productivity)); '
      .. 'candidate {platform, rows, pods, hub_slots} and competing (other platforms\' requests from the planet their hub lacks: in orbit of it, flying to it, elsewhere; at most ' .. ROWS .. ' lines, competing_more) '
      .. 'a line per request: asks (its min, or the manifest total), holds (landed in the hub), on the way (in rockets launched to it), unlaunched (asks less both), payload (min payload, else a full rocket by weight), pods (unlaunched / payload rounded up) and cargo (pods x payload; over: past unlaunched); '
      .. 'competing_pods {here, all}; budgets [{scope (the candidate alone; with the asks of platforms in orbit now; with every platform\'s asks from the planet), pods, items [{item, cargo, for_rockets (pods x per_launch, rounded up), reserve, needs, networks_hold (provider and storage chests less robots\' reservations, by exact quality, the silos\' networks together), networks_hold_by, short, other_networks (a short item: the planet\'s other networks\' stock, not counted)}], short}]; '
      .. 'unknowns (what this read does not count: production after read_tick, other consumers, route consumption, the game\'s choice of silo, built parts); line. Read only'}}
  return M
end
