-- farm: Gleba farming as a player sees it (Sol, shift09 board #368: three
-- failures establishing the first farm; transfer refused the tower: "entity
-- has no transferable inventory"). An agricultural tower's seeds and output,
-- its state in words, its planting area (3x3-tile cells within its radius):
-- which cells are free with soil for which seeds, which are blocked and by
-- what, the plants growing with the time until they are grown, and what it
-- planted lately; the burner fuel a machine takes (a biochamber burns
-- nutrients, not coal). Private 2.0.77 world: can_place_entity says a yumako
-- tree fits on jellynut soil, so soil comes from each plant's tile list.
return function(api)
  local M = {}
  local MAX_PLANT_ROWS, MAX_EMPTY_ROWS = 6, 24
  -- A tower's status in words (the engine's name stays in status_name).
  local STATE = {working='working (planting or harvesting)', waiting_for_plants_to_grow='waiting for plants to grow',
    item_ingredient_shortage='no seeds in its input', no_spot_seedable_by_inputs='no free cell with soil for its seeds',
    not_enough_space_in_output='output full', no_power='no power', low_power='low power', disabled_by_control_behavior='off by its circuit condition'}
  M.STATE = STATE
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function at(pos) return string.format('(%g,%g)', math.floor(pos.x * 10 + 0.5) / 10, math.floor(pos.y * 10 + 0.5) / 10) end
  local function secs(ticks)
    local s = math.max(0, math.floor(ticks / 60 + 0.5))
    if s >= 60 then return string.format('%dm%02ds', math.floor(s / 60), s % 60) end
    return s .. 's'
  end
  -- Seeds (items that plant something) and the tiles each plant takes.
  local seeds_cache, soil_cache
  function M.seeds()
    if seeds_cache then return seeds_cache end
    seeds_cache = {}
    for name, item in pairs(prototypes.item) do
      local plant = try(function() return item.plant_result end)
      if plant then seeds_cache[name] = plant.name end
    end
    return seeds_cache
  end
  function M.soil(plant)
    soil_cache = soil_cache or {}
    if soil_cache[plant] then return soil_cache[plant] end
    local set = {}
    local list = try(function() return prototypes.entity[plant].autoplace_specification.tile_restriction end) or {}
    for _, r in ipairs(list) do
      local name = type(r) == 'table' and (r.first or r[1]) or r
      if type(name) == 'string' then set[name] = true end
    end
    soil_cache[plant] = set
    return set
  end
  local function contents(inv)
    local parts = {}
    for _, s in ipairs(inv and try(function() return inv.get_contents() end) or {}) do parts[#parts+1] = s.name .. ' ' .. s.count end
    table.sort(parts)
    return #parts > 0 and table.concat(parts, ', ') or 'empty'
  end
  -- The tower read: what inspect shows for an agricultural tower.
  function M.tower(e, opts)
    opts = opts or {}
    local surface = e.surface
    local proto = e.prototype
    local size = try(function() return proto.growth_grid_tile_size end) or 3
    local radius = try(function() return proto.agricultural_tower_radius end) or 3
    local status = opts.status_name and opts.status_name(e) or nil
    local input = try(function() return e.get_inventory(defines.inventory.agricultural_tower_input) end)
    local output = try(function() return e.get_output_inventory() end)
    local seeds = M.seeds()
    -- The seeds it holds, and every seed's plant (for soil).
    local holds = {}
    for _, s in ipairs(input and try(function() return input.get_contents() end) or {}) do if seeds[s.name] then holds[s.name] = seeds[s.name] end end
    -- Its plants, by cell.
    local plants = try(function() return e.owned_plants end) or {}
    local by_cell, rows = {}, {}
    local now = game.tick
    local growing, ready, next_grown, planted = 0, 0, nil, 0
    for _, pl in ipairs(plants) do
      if pl.valid then
        local dx = math.floor((pl.position.x - e.position.x) / size + 0.5)
        local dy = math.floor((pl.position.y - e.position.y) / size + 0.5)
        by_cell[dx .. ',' .. dy] = pl
        local grown = try(function() return pl.tick_grown end) or now
        local left = grown - now
        if left > 0 then growing = growing + 1; next_grown = next_grown and math.min(next_grown, left) or left else ready = ready + 1 end
        local total = try(function() return pl.prototype.growth_ticks end) or 0
        if grown - total >= now - 36000 then planted = planted + 1 end
        rows[#rows+1] = {left=left, text=string.format('%s %s %s', pl.name, at(pl.position), left > 0 and ('grown in ' .. secs(left)) or 'grown, waiting for harvest')}
      end
    end
    table.sort(rows, function(x, y) return x.left < y.left end)
    -- The cells: free with soil (for which seeds), blocked (by what), no soil. Each cell with soil and no plant is
    -- also a row of empty (Sol, 15:20: three yumako cells stayed empty after several farm walks): where, and why the
    -- tower does not plant it.
    local free, blocked, nosoil, plantable = {}, {}, {}, 0
    local empty = {}
    local seed_list = {}
    for name in pairs(seeds) do seed_list[#seed_list+1] = name end
    table.sort(seed_list)
    local held_names = {}
    for name in pairs(holds) do held_names[#held_names+1] = name end
    table.sort(held_names)
    local tower_state = status and (STATE[status] or status) or nil
    for dx = -radius, radius do
      for dy = -radius, radius do
        if (dx ~= 0 or dy ~= 0) and not by_cell[dx .. ',' .. dy] then
          local c = {x=e.position.x + dx * size, y=e.position.y + dy * size}
          local tile = try(function() return surface.get_tile(c.x, c.y).name end) or '?'
          local fits = {}
          for _, seed in ipairs(seed_list) do if M.soil(seeds[seed])[tile] then fits[#fits+1] = seed end end
          if #fits == 0 then nosoil[tile] = (nosoil[tile] or 0) + 1
          else
            -- The seed it would take: one the tower holds that fits, else the first that fits.
            local seed = fits[1]
            for _, s in ipairs(fits) do if holds[s] then seed = s; break end end
            local clear = try(function() return surface.can_place_entity{name=seeds[seed], position=c, force=e.force} end)
            local why
            if clear then
              for _, s in ipairs(fits) do free[s] = (free[s] or 0) + 1 end
              if holds[seed] then
                plantable = plantable + 1
                why = string.format('free, soil for %s and the tower holds it: not planted yet (tower: %s)', seed, tower_state or 'state unknown')
              else
                why = string.format('free, soil for %s; the tower holds no %s (%s)', table.concat(fits, ' or '), table.concat(fits, ' or '),
                  #held_names > 0 and 'it holds ' .. table.concat(held_names, ', ') or 'it holds no seeds')
              end
            else
              local by
              for _, o in ipairs(try(function() return surface.find_entities_filtered{area={{c.x - size / 2, c.y - size / 2}, {c.x + size / 2, c.y + size / 2}}, limit=8} end) or {}) do
                if o.valid and o ~= e and o.type ~= 'resource' then by = o; break end
              end
              blocked[by and by.name or tile] = (blocked[by and by.name or tile] or 0) + 1
              if by then
                why = string.format('soil for %s, blocked by %s %s', seed, by.name, at(by.position))
              else
                -- No entity: the tiles under the plant that are not its soil (a cell's centre tile can be soil while
                -- its neighbours are not), else the game's own refusal.
                local bad, nbad, soil = {}, 0, M.soil(seeds[seed])
                for tx = -1, 1 do
                  for ty = -1, 1 do
                    local t = try(function() return surface.get_tile(c.x + tx, c.y + ty).name end)
                    if t and not soil[t] then bad[t] = (bad[t] or 0) + 1; nbad = nbad + 1 end
                  end
                end
                local parts = {}
                for t, n in pairs(bad) do parts[#parts+1] = n .. ' ' .. t end
                table.sort(parts)
                why = nbad > 0 and string.format('soil for %s at its centre, but %d of the 9 tiles round it are not (%s): the game refuses the plant', seed,
                    nbad, table.concat(parts, ', '))
                  or string.format('soil for %s; the game refuses a plant there with no entity in the cell (tile %s)', seed, tile)
              end
            end
            empty[#empty+1] = {d=dx * dx + dy * dy, text=at(c) .. ' ' .. why}
          end
        end
      end
    end
    local function list(map)
      local out = {}
      for k, n in pairs(map) do out[#out+1] = {k=k, n=n} end
      table.sort(out, function(x, y) if x.n ~= y.n then return x.n > y.n end return x.k < y.k end)
      local parts = {}
      for i, x in ipairs(out) do parts[i] = x.n .. ' ' .. x.k end
      return table.concat(parts, ', ')
    end
    local cells = (2 * radius + 1) ^ 2 - 1
    local parts = {string.format('%d growing%s', growing, next_grown and (' (next grown in ' .. secs(next_grown) .. ')') or ''), ready .. ' grown'}
    if next(free) then parts[#parts+1] = 'free with soil for: ' .. list(free) end
    if next(blocked) then parts[#parts+1] = 'blocked: ' .. list(blocked) end
    if next(nosoil) then parts[#parts+1] = 'no soil for any seed: ' .. list(nosoil) end
    local x0, y0 = e.position.x - (radius + 0.5) * size, e.position.y - (radius + 0.5) * size
    local out = {
      state = status and (STATE[status] or status) or nil,
      seeds = contents(input), output = contents(output),
      area = string.format('%d cells of %dx%d tiles within %d cells: %s-%s', cells, size, size, radius, at({x=x0, y=y0}), at({x=x0 + (2 * radius + 1) * size, y=y0 + (2 * radius + 1) * size})),
      cells = table.concat(parts, '; '),
      plantable_now = plantable,
      planted_10min = planted,
    }
    if #empty > 0 then
      table.sort(empty, function(x, y) if x.d ~= y.d then return x.d < y.d end return x.text < y.text end)
      out.empty_cells = {}
      for i = 1, math.min(MAX_EMPTY_ROWS, #empty) do out.empty_cells[i] = empty[i].text end
      if #empty > MAX_EMPTY_ROWS then out.empty_cells[#out.empty_cells+1] = (#empty - MAX_EMPTY_ROWS) .. ' more' end
    end
    if #rows > 0 then
      out.plants = {}
      for i = 1, math.min(MAX_PLANT_ROWS, #rows) do out.plants[i] = rows[i].text end
      if #rows > MAX_PLANT_ROWS then out.plants[#out.plants+1] = (#rows - MAX_PLANT_ROWS) .. ' more' end
    end
    -- What the force made of each plant's harvest on this surface (all towers and hands).
    if opts.flow then
      local made = {}
      local seen = {}
      for _, seed in ipairs(seed_list) do
        for _, prod in ipairs(try(function() return prototypes.entity[seeds[seed]].mineable_properties.products end) or {}) do
          if prod.name and not seen[prod.name] then
            seen[prod.name] = true
            local n = opts.flow(prod.name)
            if n and n > 0 then made[#made+1] = prod.name .. ' ' .. n end
          end
        end
      end
      out.harvest_made_10min = #made > 0 and table.concat(made, ', ') .. ' on ' .. surface.name or 'none on ' .. surface.name
    end
    return out
  end
  -- The fuel a burner takes: the asked one if its category fits, else coal for
  -- chemical burners, else the carried item of a category it burns (nutrients
  -- for a biochamber).
  function M.fuel_categories(e)
    local cats = try(function() return e.burner.fuel_categories end)
    return cats or nil
  end
  function M.accepts_fuel(e, item)
    local cats = M.fuel_categories(e)
    if not cats then return true end
    local cat = try(function() return prototypes.item[item].fuel_category end)
    return cat ~= nil and cats[cat] == true
  end
  -- Fuel items by category, read once.
  local by_category
  function M.fuel_items(cat)
    if not by_category then
      by_category = {}
      for name, item in pairs(prototypes.item) do
        local c = try(function() return (item.fuel_value or 0) > 0 and item.fuel_category end)
        if c then by_category[c] = by_category[c] or {}; table.insert(by_category[c], name) end
      end
      for _, list in pairs(by_category) do table.sort(list) end
    end
    return by_category[cat] or {}
  end
  function M.default_fuel(e, held)
    local cats = M.fuel_categories(e)
    if not cats or cats.chemical then return 'coal' end
    local best, bn
    for cat in pairs(cats) do
      for _, name in ipairs(M.fuel_items(cat)) do
        local n = held and held(name) or 0
        if not best or n > bn or (n == bn and name < best) then best, bn = name, n end
      end
    end
    return best or 'coal'
  end
  -- Spoilable stacks in an inventory, stalest first: name, count, time left.
  function M.spoiling(inv, limit)
    local rows = {}
    for i = 1, inv and #inv or 0 do
      local s = inv[i]
      if s and s.valid_for_read then
        local tick = try(function() return s.spoil_tick end)
        if tick and tick > 0 then
          rows[#rows+1] = {tick=tick, text=string.format('%s*%d spoils in %s (%d%% spoiled)', s.name, s.count, secs(tick - game.tick),
            math.floor((try(function() return s.spoil_percent end) or 0) * 100 + 0.5))}
        end
      end
    end
    table.sort(rows, function(x, y) return x.tick < y.tick end)
    local out = {}
    for i = 1, math.min(limit or 8, #rows) do out[i] = rows[i].text end
    return out
  end
  return M
end
