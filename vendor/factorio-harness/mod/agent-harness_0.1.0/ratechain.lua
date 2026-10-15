-- The rates a chain needs for a target (Sonnet, shift13 18:20: the rate each step needs, rebuilt by hand over about
-- 20 supply calls). bottleneck {item, per_min}: from the item down its recipe tree as bottleneck's chain reads it (the
-- makers on the surface), per step the rate it needs for per_min of the item, what it makes now (the production
-- statistics, last 10 minutes), the recipe its makers run (the one most of them run), their crafts a minute each at
-- their own speed (modules and beacons in it) and productivity (theirs plus the recipe's research), the machines that
-- rate takes against the makers there, and what those makers make at full speed. A product the recipe marks
-- ignored_by_productivity gets no productivity. Mining drills by their mining speed on the resource they mine; an
-- offshore pump by its pumping speed; a pumpjack's yield is not counted. An item needed by two steps adds up.
-- Read only; numbers only.
return function(api)
  local M = {}
  local MAX_DEPTH, MAX_VISITS = 8, 400
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function r1(v) return v and math.floor(v * 10 + 0.5) / 10 or nil end
  -- One craft's output of name: expected amount, productivity on the part not ignored.
  local function per_craft(recipe, name, prod)
    for _, p in ipairs(try(function() return recipe.products end) or {}) do
      if p.name == name then
        local amount = p.amount or (((p.amount_min or 0) + (p.amount_max or 0)) / 2)
        amount = amount * (p.probability or 1) + (p.extra_count_fraction or 0)
        local ignored = math.min(amount, p.ignored_by_productivity or 0)
        return amount + (amount - ignored) * prod
      end
    end
    return 0
  end
  local function recipe_name(r) return try(function() return r.name end) end
  -- The crafters' recipe for name (most of them), with them: {recipe, makers [entity]}.
  local function crafters(by_product, name)
    local groups, order = {}, {}
    for _, m in ipairs(by_product[name] or {}) do
      if not m.miner and m.recipe then
        local k = recipe_name(m.recipe) or '?'
        if not groups[k] then groups[k] = {recipe=m.recipe, makers={}}; order[#order+1] = k end
        local g = groups[k]
        g.makers[#g.makers+1] = m.e
      end
    end
    local best
    for _, k in ipairs(order) do if not best or #groups[k].makers > #best.makers then best = groups[k] end end
    return best
  end
  local function miners(by_product, name)
    local out = {}
    for _, m in ipairs(by_product[name] or {}) do if m.miner then out[#out+1] = m.e end end
    return out
  end
  -- A miner's output of name a minute at full speed, or nil when it is not counted (a pumpjack).
  local function miner_rate(e, name)
    if e.type == 'offshore-pump' then
      return try(function() return e.prototype.pumping_speed * 3600 end)
    end
    return try(function()
      local res = e.mining_target
      local mp = res.prototype.mineable_properties
      if res.prototype.infinite_resource then return nil end
      local amount = 0
      for _, p in ipairs(mp.products or {}) do
        if p.name == name then amount = (p.amount or (((p.amount_min or 0) + (p.amount_max or 0)) / 2)) * (p.probability or 1) end
      end
      return 60 * e.prototype.mining_speed * (1 + (e.speed_bonus or 0)) * (1 + (e.productivity_bonus or 0)) * amount / mp.mining_time
    end)
  end

  -- {per_min, steps [{item, depth, need_per_min, made_per_min, recipe, makers, machine, crafts_per_min_each,
  -- productivity_pct, per_min_each, machines_for_target, full_speed_per_min, miners, line}], line, cut}
  function M.plan(by_product, item, per_min, force, made)
    local need, order, depth_of, visits, cut = {}, {}, {}, 0, false
    local plan_of = {}
    local function visit(name, rate, depth, path)
      visits = visits + 1
      if visits > MAX_VISITS or depth > MAX_DEPTH then cut = true; return end
      if not need[name] then need[name] = 0; order[#order+1] = name; depth_of[name] = depth end
      need[name] = need[name] + rate
      if path[name] then return end   -- a loop in the recipes: counted once on the way down
      path[name] = true
      local c = plan_of[name]
      if c == nil then
        c = crafters(by_product, name) or false
        if not c then
          -- no maker on the surface: the recipe of that name, to follow its ingredients
          local r = try(function() return prototypes.recipe[name] end)
          c = r and {recipe=r, makers={}} or false
        end
        plan_of[name] = c
      end
      if c then
        local prod = 0
        for _, e in ipairs(c.makers) do prod = prod + (try(function() return e.productivity_bonus end) or 0) end
        prod = (#c.makers > 0 and prod / #c.makers or 0)
          + (try(function() return force.recipes[recipe_name(c.recipe)].productivity_bonus end) or 0)
        local out = per_craft(c.recipe, name, prod)
        if out > 0 then
          local crafts = rate / out
          for _, ing in ipairs(try(function() return c.recipe.ingredients end) or {}) do
            local amount = ing.amount or (((ing.amount_min or 0) + (ing.amount_max or 0)) / 2)
            visit(ing.name, crafts * amount, depth + 1, path)
          end
        end
      end
      path[name] = nil
    end
    visit(item, per_min, 0, {})
    local steps, parts = {}, {}
    for _, name in ipairs(order) do
      local n = need[name]
      local row = {item=name, depth=depth_of[name], need_per_min=r1(n), made_per_min=made and made(name) or nil}
      local c = plan_of[name]
      local ms = miners(by_product, name)
      local text
      if c and #c.makers > 0 then
        local speed, prod = 0, 0
        for _, e in ipairs(c.makers) do
          speed = speed + (try(function() return e.crafting_speed end) or 0)
          prod = prod + (try(function() return e.productivity_bonus end) or 0)
        end
        speed, prod = speed / #c.makers, prod / #c.makers + (try(function() return force.recipes[recipe_name(c.recipe)].productivity_bonus end) or 0)
        local energy = try(function() return c.recipe.energy end) or 0
        local crafts_each = energy > 0 and 60 * speed / energy or nil
        local each = crafts_each and crafts_each * per_craft(c.recipe, name, prod) or nil
        row.recipe, row.makers, row.machine = recipe_name(c.recipe), #c.makers, c.makers[1].name
        row.crafts_per_min_each, row.productivity_pct = r1(crafts_each), math.floor(prod * 100 + 0.5)
        row.per_min_each = r1(each)
        row.machines_for_target = each and each > 0 and r1(n / each) or nil
        row.full_speed_per_min = each and r1(each * #c.makers) or nil
        text = string.format('%s: need %g/min, made %d/min; %d %s on %s, %g/min each%s: %s for the target, %g/min at full speed',
          name, row.need_per_min, row.made_per_min or 0, #c.makers, row.machine, row.recipe, row.per_min_each or 0,
          prod > 0 and string.format(' (+%d%% productivity)', row.productivity_pct) or '',
          row.machines_for_target and tostring(row.machines_for_target) or '?', row.full_speed_per_min or 0)
      elseif #ms > 0 then
        local total, counted = 0, 0
        for _, e in ipairs(ms) do
          local rate = miner_rate(e, name)
          if rate then total = total + rate; counted = counted + 1 end
        end
        row.miners, row.machine = #ms, ms[1].name
        if counted > 0 then
          row.per_min_each = r1(total / counted)
          row.machines_for_target = r1(n / (total / counted))
          row.full_speed_per_min = r1(total)
          text = string.format('%s: need %g/min, made %d/min; %d %s, %g/min each: %s for the target, %g/min at full speed',
            name, row.need_per_min, row.made_per_min or 0, #ms, row.machine, row.per_min_each, row.machines_for_target, row.full_speed_per_min)
        else
          text = string.format('%s: need %g/min, made %d/min; %d %s (yield not counted)', name, row.need_per_min, row.made_per_min or 0, #ms, row.machine)
        end
      else
        row.makers = 0
        if c then row.recipe = recipe_name(c.recipe) end
        text = string.format('%s: need %g/min, made %d/min; no maker on the surface%s', name, row.need_per_min, row.made_per_min or 0,
          c and ' (recipe ' .. row.recipe .. ')' or '')
      end
      row.line = text
      steps[#steps+1] = row
      parts[#parts+1] = text
    end
    return {per_min=per_min, steps=steps, line=string.format('for %g %s a minute: ', per_min, item) .. table.concat(parts, '; '),
      cut=cut or nil}
  end
  return M
end
