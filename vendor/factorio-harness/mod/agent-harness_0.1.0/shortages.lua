-- shortages {surface?} (B6, Opus 13:51: one read of the factory's shortages, every hour): one pass over our crafters,
-- labs and requester chests on a surface, as their status icons and the logistic GUI show them, in lines:
-- - machines stopped short of an ingredient, by recipe and the ingredient each lacks (its input against one craft):
--   missing stock apart from those held back by their feeder's condition (d26 batch244, Astra #2455: two cryogenic
--   plants short of ice beside requesters holding 101 and 103 ice, their feeders off by the logistic condition
--   cryogenic-science-pack < 2000),
--   with that feeder, its condition and the signal's value now, and what its source holds (supply.held_feeders);
-- - machines with no fuel, and on low or no power, by name;
-- - labs waiting for packs;
-- - what requester chests still lack (asked, less held and on the way), by item, largest first.
-- Kept 10 s (supply.lua reuse). Read only; facts, no advice.
return function(api)
  local M = {}
  local CRAFTERS, REQUESTERS, LINES = 4096, 2048, 8
  -- the short machines whose feeders a read checks (a find and up to 8 inserters each), and the held ones it words
  -- (a circuit read each), at most 2 a group
  local HELD_CHECKS, HELD_SHOWN, HELD_GROUP = 32, 6, 2
  local function at(pos) return string.format('(%g,%g)', pos.x, pos.y) end
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function status_name(e) return api.status_name and api.status_name(e) or nil end
  local SHORT = {item_ingredient_shortage=true, fluid_ingredient_shortage=true}
  -- The ingredients a crafter lacks for one craft (items in its input, fluids in its boxes), and the items among them.
  local function lacks(e, r)
    local input = try(function() return e.get_inventory(defines.inventory.assembling_machine_input) end)
      or try(function() return e.get_inventory(defines.inventory.furnace_source) end)
    local fluids = {}
    for i = 1, try(function() return #e.fluidbox end) or 0 do
      local f = try(function() return e.fluidbox[i] end)
      if f then fluids[f.name] = (fluids[f.name] or 0) + f.amount end
    end
    local out, items = {}, {}
    for _, ing in ipairs(try(function() return r.ingredients end) or {}) do
      local have = ing.type == 'fluid' and (fluids[ing.name] or 0) or (input and try(function() return input.get_item_count(ing.name) end) or 0)
      if have < ing.amount then
        out[#out+1] = ing.name
        if ing.type ~= 'fluid' then items[#items+1] = ing.name end
      end
    end
    return out, items
  end
  local function top(map, n, fmt)
    local list = {}
    for k, v in pairs(map) do list[#list+1] = {k, v} end
    table.sort(list, function(x, y) return x[2] > y[2] or (x[2] == y[2] and x[1] < y[1]) end)
    local parts = {}
    for i, v in ipairs(list) do
      if i > n then parts[#parts+1] = string.format('+%d more', #list - n); break end
      parts[#parts+1] = fmt(v[1], v[2])
    end
    return parts, #list
  end
  function M.fresh(surface, force)
    local lines = {}
    local short, fuel, power = {}, {}, {low=0, none=0, low_by={}, none_by={}}
    local crafters = try(function() return surface.find_entities_filtered{type={'assembling-machine', 'furnace', 'mining-drill', 'boiler', 'lab'}, force=force, limit=CRAFTERS} end) or {}
    local labs_wait, labs = 0, 0
    local held, held_n, checked, unchecked = {}, {}, 0, 0
    for _, e in ipairs(crafters) do
      if e.valid then
        local st = status_name(e)
        if e.type == 'lab' then
          labs = labs + 1
          if st == 'missing_science_packs' then labs_wait = labs_wait + 1 end
        elseif st and SHORT[st] then
          local r = try(function() return e.get_recipe() end)
          if r then
            local miss, items = lacks(e, r)
            local h
            if #items > 0 and api.held_feeders then
              if checked < HELD_CHECKS then
                checked = checked + 1
                h = try(function() return api.held_feeders(e, items) end)
              else unchecked = unchecked + 1 end
            end
            for _, ing in ipairs(miss) do
              local k = r.name .. ' short of ' .. ing
              if h and h[ing] then
                held_n[k] = (held_n[k] or 0) + 1
                local g = held[k] or {}
                held[k] = g
                if #g < HELD_GROUP then g[#g+1] = {e=e, h=h[ing], item=ing, recipe=r.name} end
              else short[k] = (short[k] or 0) + 1 end
            end
          end
        elseif st == 'no_fuel' then fuel[e.name] = (fuel[e.name] or 0) + 1
        elseif st == 'low_power' then power.low = power.low + 1; power.low_by[e.name] = (power.low_by[e.name] or 0) + 1
        elseif st == 'no_power' then power.none = power.none + 1; power.none_by[e.name] = (power.none_by[e.name] or 0) + 1 end
      end
    end
    local parts, n = top(short, LINES, function(k, c) return string.format('%s (%d machine%s)', k, c, c == 1 and '' or 's') end)
    lines[#lines+1] = n > 0 and 'stopped short of an ingredient, missing stock: ' .. table.concat(parts, '; ')
      or next(held) and 'no crafter stopped short of an ingredient for missing stock' or 'no crafter stopped short of an ingredient'
    -- Held back: each group's first machines with their feeder in words, HELD_SHOWN in all.
    local rows, shown = {}, 0
    parts, n = top(held_n, LINES, function(k, c)
      local each = {}
      for _, w in ipairs(held[k]) do
        if shown >= HELD_SHOWN then break end
        shown = shown + 1
        local line = try(function() return api.held_line(w.h, w.item) end) or 'an input inserter off by its condition'
        local arm, src = w.h.arm, w.h.source
        rows[#rows+1] = {recipe=w.recipe, item=w.item, machine=w.e.name, position=w.e.position, inserter=arm.name, inserter_position=arm.position,
          source=src.name, source_position=src.position, source_holds=w.h.count, line=line}
        each[#each+1] = string.format('%s %s: %s', w.e.name, at(w.e.position), line)
      end
      return string.format('%s (%d machine%s)%s%s', k, c, c == 1 and '' or 's', #each > 0 and ': ' .. table.concat(each, ' | ') or '',
        c > #each and #each > 0 and string.format(' | %d more', c - #each) or '')
    end)
    if n > 0 then lines[#lines+1] = 'stopped short of an ingredient, held back by its feeder\'s condition (its source holds the ingredient): ' .. table.concat(parts, '; ') end
    if unchecked > 0 then lines[#lines+1] = string.format('feeders read for the first %d machines short of an item; %d more counted as missing stock without that read', HELD_CHECKS, unchecked) end
    parts, n = top(fuel, LINES, function(k, c) return c .. ' ' .. k end)
    if n > 0 then lines[#lines+1] = 'no fuel: ' .. table.concat(parts, ', ') end
    if power.low + power.none > 0 then
      local lp = top(power.low_by, 4, function(k, c) return c .. ' ' .. k end)
      local np = top(power.none_by, 4, function(k, c) return c .. ' ' .. k end)
      lines[#lines+1] = string.format('power: %d machines on low power%s, %d on no power%s', power.low, #lp > 0 and ' (' .. table.concat(lp, ', ') .. ')' or '',
        power.none, #np > 0 and ' (' .. table.concat(np, ', ') .. ')' or '')
    end
    if labs > 0 then
      local tech = try(function() return force.current_research end)
      lines[#lines+1] = string.format('labs: %d of %d wait for science packs%s', labs_wait, labs, tech and ' (research ' .. tech.name .. ')' or ' (no research running)')
    end
    -- Requester chests: asked less held and on the way, by item.
    local lack, read = {}, 0
    for _, ln in ipairs(try(function() return force.logistic_networks[surface.name] end) or {}) do
      for _, pt in ipairs(try(function() return ln.requester_points end) or {}) do
        if read >= REQUESTERS then break end
        local owner = try(function() return pt.owner end)
        if owner and owner.valid and owner.type == 'logistic-container' then
          read = read + 1
          local coming = {}
          for _, c in pairs(try(function() return pt.targeted_items_deliver end) or {}) do
            local name = type(c.name) == 'table' and c.name.name or c.name
            if name then coming[name] = (coming[name] or 0) + (c.count or 0) end
          end
          for _, f in ipairs(try(function() return pt.filters end) or {}) do
            local name = type(f.name) == 'table' and f.name.name or f.name
            if name and (f.count or 0) > 0 then
              local miss = f.count - (try(function() return owner.get_item_count(name) end) or 0) - (coming[name] or 0)
              if miss > 0 then lack[name] = (lack[name] or 0) + miss end
            end
          end
        end
      end
    end
    parts, n = top(lack, LINES, function(k, c) return k .. ' ' .. c end)
    lines[#lines+1] = n > 0 and string.format('requester chests lack (asked, less held and on the way): %s', table.concat(parts, ', ')) or 'requester chests lack nothing'
    if read >= REQUESTERS then lines[#lines+1] = string.format('the first %d requester chests read', REQUESTERS) end
    if #crafters >= CRAFTERS then lines[#lines+1] = string.format('the first %d machines read', CRAFTERS) end
    return {surface=surface.name, lines=lines, held_back=#rows > 0 and rows or nil}
  end
  function M.read(p, a)
    local surface = p.surface
    if a.surface ~= nil then
      assert(type(a.surface) == 'string', 'surface must be a planet name')
      surface = game.get_surface(a.surface)
      assert(surface, 'no surface ' .. a.surface)
    end
    local force = p.force
    return api.reuse('shortages|' .. force.name .. '|' .. surface.name, function() return M.fresh(surface, force) end)
  end
  M.schema = {shortages = {surface='optional planet name (default yours)',
    returns='lines: machines stopped short of an ingredient, by recipe and the ingredient each lacks for one craft: missing stock, and apart those held back by their feeder\'s condition (an input inserter off by its circuit or logistic condition whose source holds the ingredient, none running with it): the inserter, its condition and the signal\'s value now, its source and what that holds (held_back [{recipe, item, machine, position, inserter, inserter_position, source, source_position, source_holds, line}]; the feeders of the first 32 such machines read); machines with no fuel; machines on low or no power, by name; labs waiting for science packs (and the research); what requester chests lack (asked, less held and on the way), by item, largest first; surface, as_of (kept 10 s). Read only'}}
  return M
end
