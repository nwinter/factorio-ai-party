-- dependency {item, surface?} (backlog #818, Sol and Astra for viewer Foobator: recipe inputs were known, but whether
-- a chain runs on a planet - throughput, other users, freight on the way, rocket weights - was put together by hand).
-- One read joining what supply, stock and freight read apart, for an item and each ingredient of its recipe (the one
-- most of its makers run there, else the recipe of its name), on one surface:
-- - the rate: made and used a minute there (the production statistics, last 10 min; spoiling is not counted there);
-- - the stock: the planet's total (as stock {item, surface} counts it), and minutes of use it covers;
-- - freight on the way: cargo pods coming down to it, and our platforms carrying it with a stop there whose landing
--   pads ask for it;
-- - a rocket's load of it by weight;
-- - for the item, what one craft takes of each ingredient, and per ingredient the rate the item's making takes now.
-- The first ingredient not satisfied is named (none there and none made or coming: missing; used faster than made with
-- under 10 minutes of stock: short). "feasible": every ingredient is there, made or coming; "sustained": none is used
-- faster than it is made. Read only; facts only.
return function(api)
  local M = {}
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function r1(v) return math.floor(v * 10 + 0.5) / 10 end
  local function recipe_for(surface, force, item)
    local r = api.recipe_of and api.recipe_of(surface, force, item)
    if r then return r end
    local own = try(function() return force.recipes[item] end)
    if own and own.enabled then return own end
    -- an enabled recipe of the force that makes it (carbon: carbonic asteroid crushing), the fewest products first
    local best, bn
    for name, rp in pairs(try(function() return prototypes.get_recipe_filtered{{filter='has-product-item', elem_filters={{filter='name', name=item}}}} end) or {}) do
      local fr = try(function() return force.recipes[name] end)
      local n = #(try(function() return rp.products end) or {})
      if fr and fr.enabled and (not bn or n < bn) then best, bn = fr, n end
    end
    return best or own or try(function() return prototypes.recipe[item] end)
  end
  local function per_craft(recipe, name)
    for _, p in ipairs(try(function() return recipe.products end) or {}) do
      if p.name == name then
        local amount = p.amount or (((p.amount_min or 0) + (p.amount_max or 0)) / 2)
        return amount * (p.probability or 1) + (p.extra_count_fraction or 0)
      end
    end
    return 0
  end
  local function coming(force, surface, item)
    local pods, aboard = 0, {}
    for _, r in ipairs(api.in_flight and try(function() return api.in_flight(force.name, surface.name) end) or {}) do
      for k, n in pairs(r.items or {}) do if k == item or k:match('^([^@]+)') == item then pods = pods + n end end
    end
    local planet = try(function() return surface.planet.name end)
    for _, pl in pairs(try(function() return force.platforms end) or {}) do
      local inv = pl.valid and pl.hub and pl.hub.valid and try(function() return pl.hub.get_inventory(defines.inventory.hub_main) end)
      local n = inv and try(function() return inv.get_item_count(item) end) or 0
      if n > 0 and planet then
        local stops = false
        for _, rec in ipairs(try(function() return pl.schedule.records end) or {}) do if rec.station == planet then stops = true end end
        local ask = stops and api.pads and select(1, api.pads(planet, force)) or {}
        if stops and (ask[item] or 0) > 0 then aboard[#aboard+1] = string.format('%s holds %d (its pads ask %d)', pl.name, n, ask[item]) end
      end
    end
    return pods, aboard
  end
  local function row_of(force, surface, item)
    local stats = try(function() return force.get_item_production_statistics(surface) end)
    local function flow(cat)
      local n = stats and try(function() return stats.get_flow_count{name=item, category=cat, precision_index=defines.flow_precision_index.ten_minutes, count=true} end) or 0
      return n / 10
    end
    local made, used = flow('input'), flow('output')
    local stock = api.total and api.total(force, surface, item) or 0
    local pods, aboard = coming(force, surface, item)
    local w = try(function() return prototypes.item[item].weight end) or 0
    local lift = try(function() return prototypes.utility_constants.rocket_lift_weight end) or 1000000
    local per_rocket = w > 0 and math.floor(lift / w) or nil
    local minutes = used > made and stock / math.max(0.1, used - made) or nil
    return {item=item, made_per_min=r1(made), used_per_min=r1(used), stock=stock, minutes_left=minutes and r1(minutes) or nil,
      coming_in_pods=pods > 0 and pods or nil, aboard=#aboard > 0 and aboard or nil, per_rocket=per_rocket}
  end
  local function line_of(r)
    return string.format('%s: made %g/min, used %g/min, stock %d%s%s%s%s', r.item, r.made_per_min, r.used_per_min, r.stock,
      r.minutes_left and string.format(' (%g min at the net use)', r.minutes_left) or '',
      r.coming_in_pods and string.format('; %d coming down in cargo pods', r.coming_in_pods) or '',
      r.aboard and '; aboard for here: ' .. table.concat(r.aboard, ', ') or '',
      r.per_rocket and string.format('; %d to a rocket by weight', r.per_rocket) or '')
  end
  function M.read(p, a)
    assert(type(a.item) == 'string' and prototypes.item[a.item], 'item is an item name')
    -- (d20 batch62 X2, Sol #1529) a surface name that is no surface is refused, never read as yours
    local surface = p.surface
    if a.surface ~= nil then surface = type(a.surface) == 'string' and game.get_surface(a.surface); assert(surface, 'no surface named ' .. tostring(a.surface)) end
    local f = p.force
    local recipe = recipe_for(surface, f, a.item)
    local top = row_of(f, surface, a.item)
    local lines, rows = {line_of(top)}, {}
    local feasible, sustained, first = true, true, nil
    if recipe then
      local out = per_craft(recipe, a.item)
      local crafts = out > 0 and top.made_per_min / out or 0
      lines[1] = lines[1] .. string.format('; recipe %s: %g per craft', recipe.name, out)
      for _, ing in ipairs(try(function() return recipe.ingredients end) or {}) do
        if ing.type ~= 'fluid' then
          local amount = (ing.amount or 0) - per_craft(recipe, ing.name)
          local r = row_of(f, surface, ing.name)
          r.per_craft, r.for_this_per_min = r1(amount), r1(crafts * amount)
          local has = r.stock > 0 or r.made_per_min > 0 or r.coming_in_pods or r.aboard
          if not has then r.state = 'missing'; feasible = false
          elseif r.used_per_min > r.made_per_min and (r.minutes_left or 0) < 10 then r.state = 'short'
          else r.state = 'ok' end
          if r.used_per_min > r.made_per_min then sustained = false end
          if r.state ~= 'ok' and not first then first = r end
          rows[#rows+1] = r
          lines[#lines+1] = string.format('%s (%g a craft; %g/min of it for the %g/min made now) [%s]', line_of(r), r.per_craft, r.for_this_per_min, top.made_per_min, r.state)
        else
          lines[#lines+1] = string.format('%s (fluid, %g a craft): see supply {item: "%s"}', ing.name, ing.amount or 0, ing.name)
        end
      end
    else lines[#lines+1] = 'no recipe makes it here (a resource, a spoil result or a byproduct): supply and stock read it' end
    lines[#lines+1] = string.format('feasible: %s; sustained: %s%s', feasible and 'yes (every ingredient there, made or coming)' or 'no',
      sustained and 'yes (none used faster than made)' or 'no', first and string.format('; first unsatisfied: %s (%s)', first.item, first.state) or '')
    return {item=a.item, surface=surface.name, recipe=recipe and recipe.name or nil, item_row=top, ingredients=rows, feasible=feasible, sustained=sustained,
      first_unsatisfied=first and first.item or nil, lines=lines}
  end
  M.schema = {dependency = {item='item name', surface='optional surface (default yours)',
    returns='lines: the item and each solid ingredient of its recipe (the one most of its makers there run, else the recipe of its name): made and used a minute there (production statistics, 10 min), the planet stock and minutes it covers at the net use, cargo pods coming down with it, our platforms carrying it to a stop there whose pads ask it, how many a rocket lifts by weight; per ingredient what a craft takes (net of what it gives back) and what the making now takes a minute, and missing | short | ok; feasible (every ingredient there, made or coming), sustained (none used faster than made) and the first unsatisfied. Read only'}}
  return M
end
