-- craftrate: a crafting machine's effective rate (Sol, 15:20: he twice miscounted an egg breeder's output, because
-- the seed egg a craft returns is exempt from productivity). Crafts per minute at the machine's crafting speed now
-- (the game's figure: its prototype at its quality with module and beacon speed), and per product the amount a craft
-- yields on average (amount or the middle of its range, times its probability), the part productivity adds (the
-- amount less what the recipe marks ignored_by_productivity, times the productivity bonus, capped at the recipe's
-- maximum), and per minute; net per minute subtracts the same item among the ingredients. Productivity: the game's
-- figure for the machine (LuaEntity.productivity_bonus) with its parts where they can be read: the machine's own base
-- effect (an electromagnetic plant's +50%), the recipe's productivity research. A recipe read gives the same at
-- crafting speed 1, or at a machine prototype's speed and base effect.
return function(api)
  local M = {}
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function r1(v) return math.floor(v * 10 + 0.5) / 10 end
  local function num(v) return string.format('%g', r1(v)) end
  local function name_of(x) return type(x) == 'table' and x.name or x end
  -- One product's average yield per craft, and the part productivity applies to.
  local function yield(p)
    local amount = p.amount or (((p.amount_min or 0) + (p.amount_max or p.amount_min or 0)) / 2)
    local base = amount * (p.probability or 1) + (p.extra_count_fraction or 0)
    local ignored = math.min(base, (p.ignored_by_productivity or 0) * (p.probability or 1))
    return base, math.max(0, base - ignored), p.ignored_by_productivity
  end
  -- The rates: {crafts_per_min, seconds_per_craft, speed, productivity, products [{name, per_craft, per_min, net_per_min,
  -- ignored_by_productivity}], ingredients [{name, per_min}], line}.
  function M.rates(recipe, speed, prod, parts)
    local energy = try(function() return recipe.energy end) or 0.5
    local max_prod = try(function() return recipe.prototype.maximum_productivity end) or try(function() return recipe.maximum_productivity end) or 3
    prod = math.min(math.max(prod or 0, 0), max_prod)
    local cpm = energy > 0 and 60 * speed / energy or 0
    local used = {}
    local ings = {}
    for _, ing in ipairs(try(function() return recipe.ingredients end) or {}) do
      local n = (ing.amount or 0) * cpm
      used[ing.name] = (used[ing.name] or 0) + n
      ings[#ings+1] = {name=ing.name, per_min=r1(n)}
    end
    local prods, words = {}, {}
    for _, p in ipairs(try(function() return recipe.products end) or {}) do
      local base, productive, ignored = yield(p)
      local per_craft = base + productive * prod
      local per_min = per_craft * cpm
      local net = per_min - (used[p.name] or 0)
      prods[#prods+1] = {name=p.name, per_craft=r1(per_craft), per_min=r1(per_min), net_per_min=used[p.name] and r1(net) or nil,
        ignored_by_productivity=ignored and ignored > 0 and ignored or nil}
      words[#words+1] = string.format('%s %s/min%s%s', p.name, num(per_min), used[p.name] and string.format(' (net %s/min: %s/min goes back in)', num(net), num(used[p.name])) or '',
        ignored and ignored > 0 and string.format(', %s a craft exempt from productivity', num(ignored)) or '')
    end
    local prod_text = string.format('productivity +%d%%', math.floor(prod * 100 + 0.5))
    if parts and #parts > 0 then prod_text = prod_text .. ' (' .. table.concat(parts, ', ') .. ')' end
    return {crafts_per_min=r1(cpm), seconds_per_craft=speed > 0 and r1(energy / speed) or nil, speed=r1(speed * 100) / 100,
      productivity=r1(prod * 100) / 100, max_productivity=max_prod, products=prods, ingredients=ings,
      line=string.format('%s crafts/min at speed %s (%ss a craft), %s: %s', num(cpm), string.format('%g', math.floor(speed * 100 + 0.5) / 100), string.format('%g', energy), prod_text, table.concat(words, '; '))}
  end
  -- A machine's base productivity (its prototype's effect receiver), and the recipe's productivity research.
  function M.base_prod(proto)
    return try(function() return proto.effect_receiver.base_effect.productivity end) or 0
  end
  function M.research_prod(force, recipe_name)
    return try(function() return force.recipes[recipe_name].productivity_bonus end) or 0
  end
  -- (d20 batch55 P7, Astra #1426: a crusher on advanced-carbonic with +40% asteroid productivity read productivity 0)
  -- 2.0.77's LuaEntity.productivity_bonus is the machine's (its base effect, modules, beacons) without the recipe's
  -- research: a crusher at +40% research read 0 while its bar filled 0.4 a craft. The game adds the two and caps the sum
  -- at the recipe's maximum_productivity (+300%: at +350% research the bar filled 3 a craft). A drill's figure has the
  -- force's mining productivity in it already. {total, machine, research, max, capped}; nil without a recipe.
  -- The same total in plain reads (uptime's samples, every second for each machine): a crafting machine's
  -- productivity_bonus and a recipe's productivity_bonus read without error.
  function M.productivity_now(e, recipe)
    local proto = recipe.prototype
    local sum = e.productivity_bonus + e.force.recipes[recipe.name].productivity_bonus
    local max = proto and proto.maximum_productivity or 3
    return sum > max and max or sum < 0 and 0 or sum
  end
  function M.productivity(e, recipe)
    if not recipe then return nil end
    local machine = try(function() return e.productivity_bonus end) or M.base_prod(e.prototype)
    local research = M.research_prod(e.force, recipe.name)
    local max = try(function() return recipe.prototype.maximum_productivity end) or 3
    local sum = machine + research
    return {total=math.min(math.max(sum, 0), max), machine=machine, research=research, max=max, capped=sum > max or nil}
  end
  -- A built crafting machine: its recipe at its speed and productivity now, as if it ran all the time.
  function M.machine(e)
    local recipe = try(function() return e.get_recipe() end)
    if not recipe then
      -- An idle furnace: the recipe it ran last (previous_recipe {name, quality}).
      local prev = try(function() return e.previous_recipe end)
      local name = prev and name_of(prev.name)
      recipe = name and try(function() return e.force.recipes[name] end)
    end
    if not recipe then return nil end
    local speed = try(function() return e.crafting_speed end) or try(function() return e.prototype.get_crafting_speed(e.quality) end) or 1
    local base = M.base_prod(e.prototype)
    local pr = M.productivity(e, recipe)
    local research = pr.research
    local parts = {}
    if base ~= 0 then parts[#parts+1] = string.format('the machine\'s own +%d%%', math.floor(base * 100 + 0.5)) end
    if research ~= 0 then parts[#parts+1] = string.format('research +%d%%', math.floor(research * 100 + 0.5)) end
    local rest = pr.machine - base
    if rest > 0.0005 then parts[#parts+1] = string.format('modules and beacons +%d%%', math.floor(rest * 100 + 0.5)) end
    if pr.capped then parts[#parts+1] = string.format('capped at the recipe\'s +%d%%', math.floor(pr.max * 100 + 0.5)) end
    local out = M.rates(recipe, speed, pr.machine + research, parts)
    out.recipe = recipe.name
    out.productivity_machine, out.productivity_research = r1(pr.machine * 100) / 100, research ~= 0 and r1(research * 100) / 100 or nil
    out.line = out.line .. ' (at full speed all the time; status, input and output decide what it makes)'
    local q = try(function() return e.effects.quality end)
    -- The quality effect is stored as 0.1 per 1% the GUI shows (2.0.77: five rare quality-module-1 read 0.8, the GUI 8%;
    -- Astra 05:43 saw "80%").
    if q and q > 0 then out.quality_chance = string.format('%g%%', math.floor(q * 100 + 0.5) / 10) end
    return out
  end
  -- A recipe read's row: at crafting speed 1, or at a machine prototype's speed (its quality normal) and base effect.
  function M.recipe(force, recipe, machine)
    local speed, base = 1, 0
    if machine then
      local proto = prototypes.entity[machine]
      assert(proto and try(function() return proto.crafting_categories end), 'machine must be a crafting machine name (assembling-machine-2, electromagnetic-plant, ...)')
      speed = try(function() return proto.get_crafting_speed() end) or try(function() return proto.crafting_speed end) or 1
      base = M.base_prod(proto)
    end
    local research = M.research_prod(force, recipe.name)
    local parts = {}
    if base ~= 0 then parts[#parts+1] = string.format('%s\'s own +%d%%', machine, math.floor(base * 100 + 0.5)) end
    if research ~= 0 then parts[#parts+1] = string.format('research +%d%%', math.floor(research * 100 + 0.5)) end
    local out = M.rates(recipe, speed, base + research, parts)
    out.machine = machine
    return out
  end
  -- An inserter's throughput: one swing per revolution of its arm, stack sized by its prototype and the force's bonuses
  -- (rates.lua's estimate; extension time and belt pickup make real inserters a little slower). Items a second.
  function M.inserter_rate(e)
    local proto, force = e.prototype, e.force
    local stack = 1 + (proto.inserter_stack_size_bonus or 0)
    if proto.uses_inserter_stack_size_bonus ~= false then
      stack = stack + ((proto.bulk and force.bulk_inserter_capacity_bonus or force.inserter_stack_size_bonus) or 0)
    end
    local override = try(function() return e.inserter_stack_size_override end) or 0
    if override > 0 then stack = math.min(stack, override) end
    return proto.get_inserter_rotation_speed(e.quality) * 60 * stack
  end
  -- feed (Sol, 19:50: a standard inserter capped green circuits at 37.5/min): the inserters dropping into a crafting
  -- machine against the items its recipe takes a minute at full speed, and those taking from it against what it
  -- makes. Only sides with inserters are read (a machine fed by a loader or by hand has none). Each side short of
  -- the recipe's rate: the inserters with their rate, the share of full speed they allow, and how many inserters
  -- like its fastest the recipe takes. Nil when nothing is short or the machine has no recipe.
  local function side(rows, need, what)
    if #rows == 0 or need <= 0 then return nil end
    local cap, best, list = 0, nil, {}
    for _, i in ipairs(rows) do
      local r = try(function() return M.inserter_rate(i) end)
      if r then
        cap = cap + r * 60
        if not best or r > best.r then best = {e=i, r=r} end
        list[#list+1] = string.format('%s (%g,%g) %s/min', i.name, i.position.x, i.position.y, num(r * 60))
      end
    end
    if not best or cap >= need * 0.99 then return nil end
    local each = best.r * 60
    return {inserters=list, per_min=r1(cap), needs_per_min=r1(need), share=r1(cap / need * 100),
      line=string.format('%s: %d %s at most %s/min (%s); %s %s/min at full speed, so it runs at most %d%% of full speed; it takes %d inserters like %s (%s/min each)',
        what, #list, #list == 1 and 'inserter carries' or 'inserters carry', num(cap), table.concat(list, ', '), what == 'input' and 'the recipe takes' or 'it makes', num(need),
        math.floor(cap / need * 100 + 0.5), math.ceil(need / each - 0.0001), best.e.name, num(each))}
  end
  function M.feed(e, into, from)
    local rate = M.machine(e)
    if not rate then return nil end
    local need, made = 0, 0
    for _, ing in ipairs(rate.ingredients) do
      if not (prototypes.fluid and prototypes.fluid[ing.name]) then need = need + ing.per_min end
    end
    for _, p in ipairs(rate.products) do
      if not (prototypes.fluid and prototypes.fluid[p.name]) then made = made + p.per_min end
    end
    local input, output = side(into or {}, need, 'input'), side(from or {}, made, 'output')
    if not input and not output then return nil end
    local lines = {}
    if input then lines[#lines+1] = input.line end
    if output then lines[#lines+1] = output.line end
    return {recipe=rate.recipe, input=input, output=output, line=string.format('%s %s (%s): %s', e.name, string.format('(%g,%g)', e.position.x, e.position.y),
      rate.recipe, table.concat(lines, '; '))}
  end
  return M
end
