-- Where a crafting machine's output stops it, per product, in the game's terms (Sol, shift17 12:20: Aquilo science
-- read full_output at 45 packs and 135 hot fluoroketone, and at 4 packs, misdiagnosed about 5 times). Measured on
-- 2.0.77 (headless, d15-1220):
--   an item product stops the machine when a craft's amount no longer fits in one stack of its output slot (it holds
--     the finished craft until there is room): gears at 100, cable at 200, plastic at 100;
--   a fluid product when a craft's amount no longer fits in its output box (fluidbox get_capacity, which for a
--     crafting machine is the box's own: 300 on a cryogenic plant, 100 or 110 on a refinery; pipes joined to it take
--     from the box as they have room): basic oil processing stopped at 90 of 100 petroleum (45 a craft);
--   and an assembling machine that is not crafting for another reason (an ingredient short) reads full_output, not
--     the shortage, once it holds amount * (1 + ceil(1.166 * crafts per second)) of any product: 2 crafts' worth for
--     a slow recipe (cryogenic science: 2 packs or 6 hot fluoroketone), 3 for gears in an assembler 2, 6 for an
--     electromagnetic plant on circuits. It crafts again as soon as the ingredients are there; that much output does
--     not stop it (a plant holding 4 packs made 2 more when fed). A furnace with no input reads no_ingredients.
-- (d25 batch199 QL3, Sol #2298: a refinery on coal liquefaction read full_output with petroleum 33..49 of 100, full
-- false, full_output_from 20.) On a copy of world n (2.0.77, an oil refinery at speed 1): a craft starts whatever its
-- output holds; at its end the results go out only if every product fits (petroleum 90 + 10 of 100 went out, 90.5 did
-- not; heavy oil 90 + 90 of 180 went out, 90.5 did not), else the finished craft waits in the machine: status
-- full_output, crafting_progress 1. With no coal, full_output read from petroleum 20 (19: item_ingredient_shortage),
-- light oil 40, heavy oil 180, crafting_progress 0. So capacity, delivers_up_to (capacity less a craft), full (more
-- than that held) and idle_full_output_from are told apart, and blocking says which rule holds the machine.
-- Pure: the factory takes the harness's try.
return function(api)
  local M = {}
  local try = api.try or function(fn) local ok, v = pcall(fn); if ok then return v end end
  M.OVERLOAD_S = 1.166

  local function fmt(n) return n == math.floor(n) and string.format('%d', n) or string.format('%.1f', n) end
  local function amount_of(p)
    if p.amount then return p.amount end
    if p.amount_max then return p.amount_max end
    return 1
  end

  -- {lines, line, at_limit} for an assembler or furnace with a recipe (a furnace's last one), else nil.
  function M.read(e, status_name)
    local recipe = try(function() return e.get_recipe() end) or (e.type == 'furnace' and try(function() return e.previous_recipe end))
    -- A LuaRecipe (userdata) or a furnace's {name=LuaRecipePrototype, quality}.
    local name = recipe
    if name ~= nil and type(name) ~= 'string' then name = try(function() return name.name end) end
    if name ~= nil and type(name) ~= 'string' then name = try(function() return name.name end) end
    local proto = name and prototypes.recipe[name]
    if not proto then return nil end
    local energy = proto.energy or 1
    local speed = try(function() return e.crafting_speed end) or 1
    local crafts = 1 + math.ceil(M.OVERLOAD_S * speed / energy - 1e-9)
    local out_inv = try(function() return e.get_output_inventory() end)
    local fb = try(function() return e.fluidbox end)
    local rows, lines, at_limit = {}, {}, {}
    local soft_names = {}
    for _, p in ipairs(proto.products or {}) do
      local a = amount_of(p)
      local row = {name=p.name, fluid=p.type == 'fluid', per_craft=a}
      if p.type == 'fluid' then
        local held, cap = 0, nil
        for i = 1, (fb and #fb or 0) do
          local box = try(function() local b = fb.get_prototype(i); if b and b.object_name ~= 'LuaFluidBoxPrototype' then b = b[1] end; return b end)
          local flt = try(function() return fb.get_filter(i) end)
          local f = fb[i]
          if box and box.production_type == 'output' and ((flt and flt.name == p.name) or (f and f.name == p.name)) then
            held = f and f.amount or 0
            cap = try(function() return fb.get_capacity(i) end)
          end
        end
        row.held, row.capacity = held, cap
        row.delivers_up_to = cap and cap - a or nil
        row.full = cap ~= nil and held + a > cap + 1e-6
        if cap then
          lines[#lines+1] = string.format('%s %s of %s in its output box: a finished craft goes out while it holds %s or less (a craft adds %s), else waits finished in the machine (full_output); pipes joined to the box take from it as they have room',
            p.name, fmt(math.floor(held*10+0.5)/10), fmt(cap), fmt(cap - a), fmt(a))
        end
      else
        local held = out_inv and try(function() return out_inv.get_item_count(p.name) end) or 0
        local item = prototypes.item[p.name]
        local stack = item and item.stack_size or nil
        row.held, row.capacity = held, stack
        row.delivers_up_to = stack and stack - a or nil
        row.full = stack ~= nil and held + a > stack
        if stack then
          lines[#lines+1] = string.format('%s %d held: a finished craft goes out while it holds %s or less (one stack %d, a craft adds %s), else waits finished in the machine (full_output)',
            p.name, held, fmt(stack - a), stack, fmt(a))
        end
      end
      row.idle_full_output_from = e.type == 'assembling-machine' and a * crafts or nil
      if row.full then at_limit[#at_limit+1] = row end
      if row.idle_full_output_from and row.held >= row.idle_full_output_from - 1e-6 then soft_names[#soft_names+1] = string.format('%s %s', p.name, fmt(math.floor(row.held*10+0.5)/10)) end
      rows[#rows+1] = row
    end
    if #rows == 0 then return nil end
    local out = {products=rows, lines=lines}
    if e.type == 'assembling-machine' and status_name ~= 'working' then
      local parts = {}
      for _, r in ipairs(rows) do parts[#parts+1] = r.name .. ' ' .. fmt(r.idle_full_output_from) end
      out.idle_full_output = string.format('when it is not crafting for another reason it reads full_output, not the shortage, once it holds %d crafts\' worth of a product (%s); that output does not stop it, it crafts again when the ingredients are there',
        crafts, table.concat(parts, ', '))
    end
    local function limits()
      local parts = {}
      for _, r in ipairs(at_limit) do
        parts[#parts+1] = string.format('%s %s of %s (goes out at %s or less)', r.name, fmt(math.floor(r.held*10+0.5)/10), fmt(r.capacity), fmt(r.delivers_up_to))
      end
      return table.concat(parts, ', ')
    end
    -- A finished craft waiting reads crafting_progress 1; the idle rule reads 0 (no craft started).
    local progress = try(function() return e.crafting_progress end)
    if status_name == 'full_output' then
      if (progress and progress >= 0.999) or (progress == nil and #at_limit > 0) then
        out.blocking = 'output'
        out.line = #at_limit > 0 and 'full_output: a finished craft waits for room in its output, ' .. limits() .. ': it goes out when that is taken out'
          or 'full_output: a finished craft waits for room in its output (crafting_progress 100%)'
      else
        out.blocking = 'input'
        -- The other reason: an ingredient short of a craft.
        local short = {}
        local inv = try(function() return e.get_inventory(defines.inventory[e.type == 'furnace' and 'furnace_source' or 'assembling_machine_input']) end)
        local fluids = try(function() return e.get_fluid_contents() end) or {}
        for _, ing in ipairs(proto.ingredients or {}) do
          local need = ing.amount or 1
          local have = ing.type == 'fluid' and (fluids[ing.name] or 0) or (inv and try(function() return inv.get_item_count(ing.name) end) or 0)
          if have + 1e-6 < need then short[#short+1] = string.format('%s %s (a craft takes %s)', ing.name, fmt(math.floor(have*10+0.5)/10), fmt(need)) end
        end
        out.line = 'full_output, no output at its limit: it is not crafting (crafting_progress 0) and holds ' .. crafts .. ' crafts\' worth or more (' .. table.concat(soft_names, ', ') .. ')'
          .. (#short > 0 and '; it lacks ' .. table.concat(short, ', ') .. ': it crafts again when that arrives' or '; no ingredient is short of a craft now')
      end
    elseif status_name == 'working' and #at_limit > 0 then
      out.next_wait = 'this craft\'s results do not fit now, ' .. limits() .. ': at its end the craft waits finished unless that is taken out by then'
    end
    return out
  end
  return M
end
