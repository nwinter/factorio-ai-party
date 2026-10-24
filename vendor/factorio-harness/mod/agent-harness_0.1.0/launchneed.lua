-- launchneed: a platform waiting on a launch its own cargo would enable (d18 batch36 A2, viewer Aurora 15:36: Swiftlet
-- waited at a stop for carbon fiber while the silo there could not finish rockets for want of processing units that
-- Swiftlet's hub held and would drop). For a platform whose stop waits on items (an item count or a request wait), at
-- the planet it is stopped at (else the stop it flies to): each rocket silo of ours there whose input holds less than
-- one rocket part's worth of an ingredient while it has parts left to make, and what of that ingredient the platform's
-- own hub holds. Facts only; read only. At most SILOS silos a planet.
return function(api)
  local M = {}
  M.SILOS = 8
  local ITEM_WAITS = {item_count=true, all_requests_satisfied=true, any_request_not_satisfied=true, any_request_zero=true}
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function at(q) return string.format('(%g,%g)', q.x, q.y) end
  -- The silo's rocket-part ingredients it holds less than one part of, with parts left to make: {item, holds, per_part}.
  function M.silo_lacks(e)
    local recipe = try(function() return e.get_recipe() end)
    if not recipe then return {}, nil end
    local parts = try(function() return e.rocket_parts end) or 0
    local required = try(function() return e.prototype.rocket_parts_required end) or 0
    if parts >= required then return {}, string.format('%d/%d', parts, required) end
    local inv = try(function() return e.get_inventory(defines.inventory.assembling_machine_input) end)
    local out = {}
    for _, ing in ipairs(try(function() return recipe.ingredients end) or {}) do
      if ing.type == 'item' then
        local have = inv and try(function() return inv.get_item_count(ing.name) end) or 0
        if have < ing.amount then out[#out+1] = {item=ing.name, holds=have, per_part=ing.amount} end
      end
    end
    return out, string.format('%d/%d', parts, required)
  end
  -- The planet the platform's stop is at and whether that stop waits on items: planet, waits_on_items, stopped.
  function M.stop_of(pl)
    local loc = try(function() return pl.space_location and pl.space_location.name end)
    local sch = try(function() return pl.schedule end)
    local rec = sch and sch.records and sch.records[sch.current or 1]
    local planet = loc or (rec and rec.station)
    local items = false
    for _, w in ipairs(rec and rec.wait_conditions or {}) do if ITEM_WAITS[w.type] then items = true end end
    return planet, items, loc ~= nil
  end
  -- The planet's silos without a search (a whole-surface find took 10.5 ms on Nauvis, world n): the census pass's
  -- silos, else the list shipment keeps (refreshed once a minute).
  function M.silos(force, s)
    local out = {}
    local list = api.silos and try(function() return api.silos(force, s) end)
    if list then
      for _, e in ipairs(list) do if e.valid and #out < M.SILOS then out[#out+1] = e end end
      return out
    end
    local c = api.state and try(function() return api.state().shipment_silos[s.index] end)
    for _, e in ipairs(c and c.list or {}) do if e.valid and #out < M.SILOS then out[#out+1] = e end end
    return out
  end
  -- Lines for one platform: "Swiftlet holds 400 processing-unit; rocket-silo (5,10) on fulgora: its rocket parts lack it
  -- (holds 0, 10 a part; parts 12/50)". silos: optional list of silo entities (else found on the planet).
  function M.for_platform(pl, silos)
    local planet, items = M.stop_of(pl)
    if not (planet and items) then return nil end
    local hub = try(function() return pl.hub end)
    if not (hub and hub.valid) then return nil end
    local s = try(function() return game.planets[planet].surface end)
    if not s then return nil end
    silos = silos or M.silos(pl.force, s)
    local lines = {}
    for _, e in ipairs(silos) do
      if e.valid then
        local lacks, parts = M.silo_lacks(e)
        for _, x in ipairs(lacks) do
          local held = try(function() return hub.get_item_count(x.item) end) or 0
          if held > 0 then
            lines[#lines+1] = string.format('%s holds %d %s; %s %s on %s: its rocket parts lack it (holds %d, %d a part; parts %s)',
              pl.name, held, x.item, e.name, at(e.position), planet, x.holds, x.per_part, parts)
          end
        end
      end
    end
    return #lines > 0 and lines or nil
  end
  -- (d18 batch37 B2, Gemini 16:53: Kestrel II waited for 500 carbon fiber at Fulgora, made nowhere there) each item_count
  -- wait of the platform's stops: what the hub holds against it, the stop's planet's stock of the item (its networks'
  -- count and what elsewhere.lua finds outside them), what that planet made of it a minute over the last 10 minutes,
  -- and at that rate when the hub's count would be reached; "0 a minute: not met at this rate" when nothing made it.
  local CMP = {['≥']='>=', ['>']='>', ['=']='='}
  -- (d23 batch121 CD2, viewer Aurora site:4404: "Anvil waited on a copper gate at the wrong stop. Could schedule checks
  -- flag unmet gates with no known supply there, including imports and onboard production?") Where the item can come
  -- from at that stop: the hub's import requests for it (only one from that planet brings it up there; Anvil's copper
  -- request named Nauvis while its Vulcanus stop waited for 5000 copper, 2 h docked, shift62), what was made aboard
  -- over the last 10 min and the machines aboard set to make it, and the other platforms that stop at that planet
  -- holding it. Facts only; the wait stays as set. sources(pl) once a call: {from = {item = {planets}}, makers = {item =
  -- n}} or nil when the hub's sections cannot be read.
  M.MAKERS = 200  -- crafting machines aboard read for their recipes
  local function sources(pl, hub)
    local secs = try(function() return hub.get_logistic_sections() end)
    if not secs then return nil end
    local from = {}
    for i = 1, secs.sections_count or 0 do
      local sec = secs.get_section(i)
      if sec and sec.active ~= false and (sec.multiplier or 1) > 0 then
        for _, f in ipairs(sec.filters or {}) do
          local v = f.value
          local name = type(v) == 'table' and v.name or v
          local planet = f.import_from and (type(f.import_from) == 'string' and f.import_from or try(function() return f.import_from.name end))
          if type(name) == 'string' and planet and (f.min or 0) > 0 then
            from[name] = from[name] or {}
            from[name][planet] = true
          end
        end
      end
    end
    local makers = {}
    local list = try(function() return pl.surface.find_entities_filtered{type={'assembling-machine', 'furnace'}, force=pl.force, limit=M.MAKERS} end) or {}
    for _, e in ipairs(list) do
      local r = try(function() return e.get_recipe() end) or try(function() return e.previous_recipe and e.previous_recipe.name end)
      for _, pr in ipairs(r and try(function() return r.products end) or {}) do
        if pr.type == 'item' and pr.name then makers[pr.name] = (makers[pr.name] or 0) + 1 end
      end
    end
    return {from=from, makers=makers}
  end
  local function planets_text(set)
    local t = {}
    for k in pairs(set or {}) do t[#t+1] = k end
    table.sort(t)
    return table.concat(t, ', ')
  end
  -- Other platforms of the force with `planet` among their stops whose hub holds `item` (they may bring it down there).
  local function others(pl, planet, item)
    local out = {}
    for _, o in pairs(try(function() return pl.force.platforms end) or {}) do
      if o ~= pl and try(function() return o.valid end) and try(function() return o.name ~= pl.name end) then
        local stops = false
        for _, r in ipairs(try(function() return o.schedule and o.schedule.records end) or {}) do if r.station == planet then stops = true end end
        local n = stops and (try(function() return o.hub and o.hub.valid and o.hub.get_item_count(item) end) or 0) or 0
        if n > 0 then out[#out+1] = string.format('%s %d', o.name, n) end
      end
      if #out >= 3 then break end
    end
    return out
  end
  function M.wait_lines(pl)
    local sch = try(function() return pl.schedule end)
    local hub = try(function() return pl.hub end)
    if not (sch and sch.records and hub and hub.valid) then return nil end
    local lines, src = {}, false
    for i, r in ipairs(sch.records) do
      for _, w in ipairs(r.wait_conditions or {}) do
        local c = w.type == 'item_count' and w.condition
        local f = c and c.first_signal and c.first_signal.name
        local cmp = c and CMP[c.comparator or '']
        if f and cmp and c.constant and prototypes.item[f] and #lines < 6 then
          local planet = r.station
          local s = planet and try(function() return game.planets[planet].surface end)
          local held = try(function() return hub.get_item_count(f) end) or 0
          local need = math.max(0, c.constant - held + (cmp == '>' and 1 or 0))
          local head = string.format('stop %d (%s) waits for %s %s %d: the hub holds %d', i, tostring(planet), f, cmp, c.constant, held)
          if cmp == '=' and held ~= c.constant then
            lines[#lines+1] = head .. (held > c.constant and string.format(': not met while it holds %d more than that', held - c.constant) or string.format(', %d short', c.constant - held))
          elseif need == 0 then lines[#lines+1] = head .. ': met now'
          elseif not s then lines[#lines+1] = head .. string.format('; %s has no surface (never visited)', tostring(planet))
          else
            local net = 0
            for _, ln in ipairs(try(function() return pl.force.logistic_networks[s.name] end) or {}) do net = net + math.max(0, try(function() return ln.get_item_count(f) end) or 0) end
            local outside = api.elsewhere and select(2, api.elsewhere(pl.force, s, f, nil, nil)) or 0
            local stats = try(function() return pl.force.get_item_production_statistics(s) end)
            local made = stats and try(function() return stats.get_flow_count{name=f, category='input', precision_index=defines.flow_precision_index.ten_minutes, count=true} end) or 0
            local per_min = math.floor(made / 10 + 0.5)
            local stock = string.format('%s holds %d (%d in its logistic networks, %d outside them) and made %d a minute over the last 10 min', planet, net + (outside or 0), net, outside or 0, per_min)
            if src == false then src = sources(pl, hub) end
            if not src then
              local eta = per_min > 0 and string.format('about %d min at this rate', math.ceil(need / per_min)) or 'not met at this rate'
              lines[#lines+1] = string.format('%s, %d short; %s: %s', head, need, stock, eta)
            else
              local asks = src.from[f]
              local here = asks and asks[planet]
              local req = here and string.format('the hub asks for it from %s', planet)
                or asks and string.format('the hub asks for it from %s only, not from %s', planets_text(asks), planet)
                or 'the hub has no request for it'
              local aboard_stats = try(function() return pl.force.get_item_production_statistics(pl.surface) end)
              local aboard = aboard_stats and try(function() return aboard_stats.get_flow_count{name=f, category='input', precision_index=defines.flow_precision_index.ten_minutes, count=true} end) or 0
              local makers = src.makers[f] or 0
              local onboard = aboard > 0 and string.format('made aboard %d a minute over the last 10 min', math.floor(aboard / 10 + 0.5))
                or 'nothing aboard made it over the last 10 min'
              onboard = onboard .. (makers > 0 and string.format(', %d machine%s aboard set to make it', makers, makers == 1 and '' or 's') or '')
              if not here and aboard == 0 and makers == 0 then
                lines[#lines+1] = string.format('%s, %d short; no known source at %s: %s, nothing aboard made it over the last 10 min and no machine aboard is set to make it (%s; it reaches the hub only by a request from %s)',
                  head, need, planet, req, stock, planet)
              else
                local by = here and others(pl, planet, f) or {}
                if here and aboard == 0 and makers == 0 and #by == 0 and per_min == 0 and net + (outside or 0) == 0 then
                  lines[#lines+1] = string.format('%s, %d short; no known source at %s: the hub asks for it from %s, which holds none and made none over the last 10 min; no other platform stopping there holds it; nothing aboard made it or is set to make it',
                    head, need, planet, planet)
                else
                  local eta = here and per_min > 0 and string.format('about %d min at %s\'s rate', math.ceil(need / per_min), planet) or nil
                  lines[#lines+1] = string.format('%s, %d short; %s; sources: %s; %s%s%s', head, need, stock, req, onboard,
                    #by > 0 and '; other platforms stopping at ' .. planet .. ' hold it: ' .. table.concat(by, ', ') or '', eta and '; ' .. eta or '')
                end
              end
            end
          end
        end
      end
    end
    return #lines > 0 and lines or nil
  end
  return M
end
