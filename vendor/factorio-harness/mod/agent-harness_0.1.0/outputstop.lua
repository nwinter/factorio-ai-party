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
-- (d25 batch201 QN2, Astra #2315: Asterion's explosives plant held 10 explosives and no coal, its input inserter held
-- coal waiting_for_space_in_destination, and the line said it lacks coal and crafts when it arrives) an inserter puts
-- no ingredient into an assembling machine that holds that much of a product (2.0.77, a copy of world n, a fast inserter
-- from a chest into a machine with its output set beforehand, empty input: gears in an assembler 2 inserted at 2 and
-- not at 3 (3 crafts' worth), in an assembler 3 at 3 and not at 4 (4), explosives in a chemical plant at 2 and not at 4
-- (2 crafts' worth, 4); the inserter reads waiting_for_space_in_destination). The machine crafts on with what it holds.
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

  -- The inserters dropping into e that wait for space in it, with what they hold: "fast-inserter (-7.5,48.5) holding
  -- 1 coal".
  local function waiting(e)
    local b = try(function() return e.bounding_box end)
    if not b then return {} end
    local out = {}
    local wait = defines.entity_status and defines.entity_status.waiting_for_space_in_destination
    for _, ins in pairs(try(function() return e.surface.find_entities_filtered{area={{b.left_top.x - 3, b.left_top.y - 3}, {b.right_bottom.x + 3, b.right_bottom.y + 3}}, type='inserter', force=e.force} end) or {}) do
      if ins.valid and try(function() return ins.drop_target end) == e and try(function() return ins.status end) == wait then
        local h = try(function() local st = ins.held_stack; return st.valid_for_read and (st.count .. ' ' .. st.name) end)
        out[#out+1] = string.format('%s (%g,%g)%s', ins.name, ins.position.x, ins.position.y, h and ' holding ' .. h or '')
      end
    end
    return out
  end
  M.waiting = waiting
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
        row.held, row.stops_at = held, cap
        row.full = cap ~= nil and held + a > cap + 1e-6
        if cap then
          lines[#lines+1] = string.format('%s %s of %s in its output box: it stops when a craft\'s %s no longer fit (pipes joined to the box take from it as they have room)',
            p.name, fmt(math.floor(held*10+0.5)/10), fmt(cap), fmt(a))
        end
      else
        local held = out_inv and try(function() return out_inv.get_item_count(p.name) end) or 0
        local item = prototypes.item[p.name]
        local stack = item and item.stack_size or nil
        row.held, row.stops_at = held, stack
        row.full = stack ~= nil and held + a > stack
        if stack then
          lines[#lines+1] = string.format('%s %d held: it stops when a craft\'s %s no longer fit in one stack (%d) and waits with that craft finished',
            p.name, held, fmt(a), stack)
        end
      end
      row.full_output_from = e.type == 'assembling-machine' and a * crafts or nil
      if row.full then at_limit[#at_limit+1] = row end
      if row.full_output_from and row.held >= row.full_output_from - 1e-6 then soft_names[#soft_names+1] = string.format('%s %s', p.name, fmt(math.floor(row.held*10+0.5)/10)) end
      rows[#rows+1] = row
    end
    if #rows == 0 then return nil end
    local out = {products=rows, lines=lines}
    -- (QN2) an item product at its crafts' worth or more: inserters put in no ingredient (measured for items only)
    for _, r in ipairs(rows) do
      if not r.fluid and r.full_output_from and r.held >= r.full_output_from - 1e-6 and not out.refuses_ingredients then
        out.refuses_ingredients = {product=r.name, held=r.held, from=r.full_output_from,
          line=string.format('inserters put no ingredient into it while it holds %d crafts\' worth of a product or more (%s %s; below %s they do)',
            crafts, r.name, fmt(math.floor(r.held*10+0.5)/10), fmt(r.full_output_from))}
      end
    end
    if e.type == 'assembling-machine' and status_name ~= 'working' then
      local parts = {}
      for _, r in ipairs(rows) do parts[#parts+1] = r.name .. ' ' .. fmt(r.full_output_from) end
      out.idle_full_output = string.format('when it is not crafting for another reason it reads full_output, not the shortage, once it holds %d crafts\' worth of a product (%s); that output does not stop it, it crafts again when the ingredients are there, and inserters put no ingredient into it while it holds that much',
        crafts, table.concat(parts, ', '))
    end
    if status_name == 'full_output' then
      if #at_limit > 0 then
        local parts = {}
        for _, r in ipairs(at_limit) do parts[#parts+1] = string.format('%s %s of %s', r.name, fmt(math.floor(r.held*10+0.5)/10), fmt(r.stops_at)) end
        out.line = 'full_output: output at its limit, ' .. table.concat(parts, ', ') .. ': it crafts again when that is taken out'
      else
        -- The other reason: an ingredient short of a craft.
        local short = {}
        local inv = try(function() return e.get_inventory(defines.inventory[e.type == 'furnace' and 'furnace_source' or 'assembling_machine_input']) end)
        local fluids = try(function() return e.get_fluid_contents() end) or {}
        for _, ing in ipairs(proto.ingredients or {}) do
          local need = ing.amount or 1
          local have = ing.type == 'fluid' and (fluids[ing.name] or 0) or (inv and try(function() return inv.get_item_count(ing.name) end) or 0)
          if have + 1e-6 < need then short[#short+1] = string.format('%s %s (a craft takes %s)', ing.name, fmt(math.floor(have*10+0.5)/10), fmt(need)) end
        end
        local refuse = out.refuses_ingredients
        local tail = ': it crafts again when that arrives'
        if refuse then
          local w = waiting(e)
          refuse.waiting = #w > 0 and w or nil
          tail = ', and ' .. refuse.line .. (#w > 0 and '; waiting for space in it: ' .. table.concat(w, ', ') or '')
        end
        out.line = 'full_output, no output at its limit: it is not crafting and holds ' .. crafts .. ' crafts\' worth or more (' .. table.concat(soft_names, ', ') .. ')'
          .. (#short > 0 and '; it lacks ' .. table.concat(short, ', ') .. tail or '; no ingredient is short of a craft now')
      end
    end
    return out
  end
  return M
end
