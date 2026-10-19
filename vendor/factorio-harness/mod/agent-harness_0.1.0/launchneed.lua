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
  -- crafters, else the list shipment keeps (refreshed once a minute).
  function M.silos(force, s)
    local out = {}
    local list = api.crafters and try(function() return api.crafters(force, s) end)
    if list then
      for _, e in ipairs(list) do if e.valid and e.type == 'rocket-silo' and #out < M.SILOS then out[#out+1] = e end end
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
  return M
end
