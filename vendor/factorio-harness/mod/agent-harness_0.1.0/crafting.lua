-- Hand crafting by bots. The engine finishes a playerless character's crafts
-- (items land in its inventory) but, unlike a player's, records nothing: no
-- item production statistics and no craft-item research triggers. So each
-- bot's crafting queue is compared with a snapshot every few ticks; what left
-- the queue was crafted (intermediate entries included). Every queue change
-- the harness makes (begin/cancel) settles the snapshot before and after, so
-- only completions show up as differences.
return function(api)
  local M = {}
  local CHECK_TICKS = 10
  local function store()
    local s = api.state()
    s.bot_crafting = s.bot_crafting or {queues={}, triggers={}}
    return s.bot_crafting
  end
  -- A name, whether the engine gives a string or a prototype object.
  local function name_of(x) return type(x) == 'string' and x or x.name end
  -- Crafts left per recipe, over every queue entry.
  local function totals(c)
    local out = {}
    for _, entry in ipairs(c.crafting_queue or {}) do
      local recipe = name_of(entry.recipe)
      out[recipe] = (out[recipe] or 0) + entry.count
    end
    return out
  end
  local function alive(b) return b.character ~= nil and b.character.valid end
  -- craft-item technologies by item name; built from prototypes, so the same
  -- on every peer.
  local by_item
  local function trigger_techs(item)
    if not by_item then
      by_item = {}
      for name, tech in pairs(prototypes.technology) do
        local t = tech.research_trigger
        if t and t.type == 'craft-item' then
          local it = name_of(t.item)
          by_item[it] = by_item[it] or {}
          table.insert(by_item[it], {name=name, count=t.count or 1})
        end
      end
    end
    return by_item[item] or {}
  end
  local function available(tech)
    if tech.researched or not tech.enabled then return false end
    for _, pre in pairs(tech.prerequisites) do
      if not pre.researched then return false end
    end
    return true
  end
  -- A crafted item advances the force's craft-item triggers on it, counted
  -- while the technology is available (prerequisites researched), like the game.
  function M.crafted(force, item, count)
    local progress = store().triggers
    progress[force.name] = progress[force.name] or {}
    local mine = progress[force.name]
    for _, t in ipairs(trigger_techs(item)) do
      local tech = force.technologies[t.name]
      if tech and available(tech) then
        mine[t.name] = (mine[t.name] or 0) + count
        if mine[t.name] >= t.count then
          mine[t.name] = nil
          tech.researched = true
        end
      end
    end
  end
  local function amount(product)
    local n = product.amount or ((product.amount_min or 0) + (product.amount_max or 0)) / 2
    return n * (product.probability or 1)
  end
  -- Completed crafts of one recipe: products in, ingredients out of the
  -- force's item statistics, as for a player's hand crafting.
  function M.record(c, recipe_name, crafts)
    local recipe = prototypes.recipe[recipe_name]
    if not recipe then return end
    local force = c.force
    local stats = force.get_item_production_statistics(c.surface)
    for _, product in ipairs(recipe.products or {}) do
      if product.type == 'item' then
        local n = math.floor(amount(product) * crafts + 0.5)
        if n > 0 then
          stats.on_flow(product.name, n)
          M.crafted(force, product.name, n)
        end
      end
    end
    for _, ingredient in ipairs(recipe.ingredients or {}) do
      if ingredient.type == 'item' then stats.on_flow(ingredient.name, -ingredient.amount * crafts) end
    end
  end
  function M.snapshot(b)
    store().queues[b.index] = alive(b) and totals(b.character) or nil
  end
  -- Count what left the queue since the snapshot, then take a new one.
  function M.flush(b)
    local queues = store().queues
    if not alive(b) then queues[b.index] = nil; return end
    local before, now = queues[b.index], totals(b.character)
    if before then
      for recipe, n in pairs(before) do
        local done = n - (now[recipe] or 0)
        if done > 0 then M.record(b.character, recipe, done) end
      end
    end
    queues[b.index] = now
  end
  -- A dead bot's queue died with it: nothing was crafted.
  function M.forget(b) store().queues[b.index] = nil end
  function M.tick(b, tick)
    if (tick + b.index) % CHECK_TICKS ~= 0 or not alive(b) then return end
    local before = store().queues[b.index]
    if (b.character.crafting_queue_size or 0) == 0 and not (before and next(before)) then return end
    M.flush(b)
  end
  return M
end
