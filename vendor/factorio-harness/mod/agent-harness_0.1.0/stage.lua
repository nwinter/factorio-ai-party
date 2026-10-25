-- silo_stage {position, items, from, launch?, platform?, to_total?, auto_requests?, dry_run?} (d17 batch19 C1, Haiku 5-8
-- times per 30 min on Swiftlet's mixed loads: each packet gathered from several chests, its short intermediates
-- (combinators, pipes) crafted by hand, then loaded, call by call). It reads the silo and the chests now and submits one
-- plan to your queue, each step as you would call it:
-- - transfer {position, direction: to_player, items, walk: true, up_to: true} at each chest in from holding some of what
--   the rocket still needs (after what you carry), in the order given; also the ingredients the crafts below need that
--   you do not carry, taken where the chests hold them;
-- - craft {recipes, force: true} for each item of the list still missing that you can craft by hand (its intermediates
--   crafted along by the game's hand queue), and wait_until crafting_done;
-- - load_silo {position, items, walk: true, launch?, platform?, to_total?, auto_requests?}.
-- What none of that covers is said (missing) and still queued: load_silo loads what you hold. dry_run: the read and the
-- plan, nothing queued. A take that finds less runs short and the plan goes on (on_short skip).
return function(api)
  local M = {}
  -- (d25 batch208 QU1) the most a call takes, also a queue step's check (runtime.lua step_lengths)
  M.FROM_MAX = 16
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function at(q) return string.format('(%g,%g)', q.x, q.y) end
  local function list_text(map)
    local parts = {}
    for name, n in pairs(map) do parts[#parts+1] = name .. ' ' .. n end
    table.sort(parts)
    return table.concat(parts, ', ')
  end
  -- {name=count} from load_silo's items ({"name": n} or [{item, count}])
  local function items_of(items)
    assert(type(items) == 'table', 'items: {"item-name": count} or [{"item", "count"}], 1..20 items')
    local out, n = {}, 0
    for k, v in pairs(items) do
      local name, count
      if type(k) == 'string' then name, count = k, v else name, count = v.item or v.name, v.count end
      assert(type(name) == 'string' and prototypes.item[name], 'items: unknown item ' .. tostring(name))
      assert(type(count) == 'number' and count >= 1 and count == math.floor(count), 'items: ' .. name .. ' count must be a whole number 1..')
      out[name] = (out[name] or 0) + count; n = n + 1
    end
    assert(n >= 1 and n <= 20, 'items: 1..20 items')
    return out
  end

  -- What you carry first, then takes at each chest in the order given, then hand crafts for what none holds (their
  -- ingredients from what you carry, else the chests; intermediates the game's hand queue crafts along, 3 levels deep).
  -- want: {item = count still to get}; returns {takes per chest, steps (transfer walks, craft, wait), plan, crafts,
  -- missing, raw_short, short}. rebuild (lostlog.lua) gathers this way too.
  function M.gather(p, want, chests)
    local inv = p.get_main_inventory()
    local held, still = {}, {}
    local function carry(name) if held[name] == nil then held[name] = inv and inv.get_item_count(name) or 0 end; return held[name] end
    for name, need in pairs(want) do
      local use = math.min(carry(name), math.max(0, need))
      held[name] = held[name] - use
      if need - use > 0 then still[name] = need - use end
    end
    local stock, takes = {}, {}
    for i, e in ipairs(chests) do
      stock[i], takes[i] = {}, {}
    end
    local function chest_has(i, name)
      if stock[i][name] == nil then
        stock[i][name] = try(function() return chests[i].get_inventory(defines.inventory.chest).get_item_count(name) end)
          or try(function() return chests[i].get_item_count(name) end) or 0
      end
      return stock[i][name]
    end
    local function take(name, n)
      for i in ipairs(chests) do
        if n <= 0 then break end
        local got = math.min(chest_has(i, name), n)
        if got > 0 then
          takes[i][name] = (takes[i][name] or 0) + got; stock[i][name] = stock[i][name] - got; n = n - got
        end
      end
      return n
    end
    for name, n in pairs(still) do still[name] = take(name, n); if still[name] <= 0 then still[name] = nil end end
    local crafts, craft_list, missing, raw_short = {}, {}, {}, {}
    local function expand(recipe, times, depth)
      for _, ing in ipairs(recipe.ingredients or {}) do
        if ing.type == 'item' then
          local n = ing.amount * times
          local use = math.min(carry(ing.name), n)
          held[ing.name] = held[ing.name] - use; n = n - use
          if n > 0 then n = take(ing.name, n) end
          local sub = n > 0 and depth < 3 and api.hand_recipe(p, ing.name)
          local made = 0
          for _, pr in ipairs(sub and sub.products or {}) do if pr.name == ing.name then made = pr.amount or pr.amount_max or 1 end end
          if made > 0 then expand(sub, math.ceil(n / made), depth + 1)
          elseif n > 0 then raw_short[ing.name] = (raw_short[ing.name] or 0) + n end
        end
      end
    end
    for name, n in pairs(still) do
      local r = api.hand_recipe(p, name)
      local made = 0
      for _, pr in ipairs(r and r.products or {}) do if pr.name == name then made = pr.amount or pr.amount_max or 1 end end
      if made > 0 then
        local times = math.ceil(n / made)
        crafts[r.name] = (crafts[r.name] or 0) + times
        expand(r, times, 1)
      else missing[name] = n end
    end
    for recipe, n in pairs(crafts) do craft_list[#craft_list+1] = {recipe=recipe, count=n} end
    table.sort(craft_list, function(x, y) return x.recipe < y.recipe end)
    local steps, plan = {}, {}
    for i, e in ipairs(chests) do
      if next(takes[i]) then
        steps[#steps+1] = {action='transfer', args={position={x=e.position.x, y=e.position.y}, direction='to_player', items=takes[i], walk=true, up_to=true},
          on_short='skip', label='take at ' .. at(e.position)}
        plan[#plan+1] = string.format('take %s from %s %s', list_text(takes[i]), e.name, at(e.position))
      end
    end
    if #craft_list > 0 then
      steps[#steps+1] = {action='craft', args={recipes=craft_list, force=true}, label='craft'}
      steps[#steps+1] = {action='wait_until', args={['until']='crafting_done', timeout=18000}, label='crafted'}
      local parts = {}
      for _, c in ipairs(craft_list) do parts[#parts+1] = c.recipe .. ' x' .. c.count end
      plan[#plan+1] = 'craft by hand ' .. table.concat(parts, ', ') .. ', then wait until the hand queue is done'
    end
    local short = {}
    if next(missing) then short[#short+1] = 'not in those chests, not hand-craftable: ' .. list_text(missing) end
    if next(raw_short) then short[#short+1] = 'ingredients for the crafts in neither your inventory nor those chests: ' .. list_text(raw_short) end
    return {takes=takes, steps=steps, plan=plan, crafts=#craft_list > 0 and craft_list or nil, missing=next(missing) and missing or nil,
      raw_short=next(raw_short) and raw_short or nil, short=#short > 0 and table.concat(short, '; ') or nil}
  end

  function M.run(p, a)
    assert(a.dry_run == nil or type(a.dry_run) == 'boolean', 'dry_run must be true or false')
    local silo = api.entity(p, api.position(a.position))
    assert(silo and silo.type == 'rocket-silo', 'position: a rocket silo of ours (any tile of it)')
    local want = items_of(a.items)
    local froms = a.from
    assert(type(froms) == 'table' and (froms.x or froms[1]), 'from: a chest {x,y} or 1..16 of them')
    if froms.x then froms = {froms} end
    assert(#froms >= 1 and #froms <= M.FROM_MAX, 'from: 1..' .. M.FROM_MAX .. ' chests')
    local chests = {}
    for i, q in ipairs(froms) do
      local pos = api.position(q)
      local e = api.entity(p, pos)
      assert(e, string.format('from[%d] %s: no chest of ours in sight or on the map there', i, at(pos)))
      chests[i] = e
    end
    -- What the rocket still needs (to_total: less what its cargo holds); gather takes what you carry off that.
    local rocket = try(function() return silo.get_inventory(defines.inventory.rocket_silo_rocket) end)
    local need = {}
    for name, n in pairs(want) do
      need[name] = n - (a.to_total and rocket and (try(function() return rocket.get_item_count(name) end) or 0) or 0)
    end
    local g = M.gather(p, need, chests)
    local steps, plan = g.steps, g.plan
    local load = {position={x=silo.position.x, y=silo.position.y}, items=a.items, walk=true, launch=a.launch, platform=a.platform,
      to_total=a.to_total, auto_requests=a.auto_requests}
    steps[#steps+1] = {action='load_silo', args=load, label='load'}
    plan[#plan+1] = string.format('load_silo at %s: %s%s', at(silo.position), list_text(want), a.launch and ', then launch' or '')
    local out = {silo=at(silo.position), plan=plan, crafts=g.crafts, missing=g.missing, raw_short=g.raw_short, short=g.short}
    if a.dry_run then out.line = 'dry run: nothing queued'; out.steps = steps; return out end
    local q = api.submit(p, {steps=steps})
    out.queued = #steps
    out.queue = q
    out.line = string.format('queued %d step%s: %s%s', #steps, #steps == 1 and '' or 's', table.concat(plan, '; '), out.short and '; ' .. out.short or '')
    return out
  end
  M.schema = {silo_stage = {position='the rocket silo {x,y}', items='the cargo, as load_silo takes it: {"item-name": count} or [{"item", "count"}], 1..20 items',
    from='a chest {x,y} or 1..16 of them (anywhere in sight or on the map): where to take what you do not carry, in this order',
    launch='optional, as load_silo\'s', platform='optional, as load_silo\'s', to_total='optional, as load_silo\'s', auto_requests='optional, as load_silo\'s',
    dry_run='true: the read and the plan (steps), nothing queued',
    returns='plan (a line a step: the takes at each chest, the hand crafts, the load), crafts [{recipe, count}], missing (in no chest given and not hand-craftable), raw_short (ingredients for the crafts in neither your inventory nor the chests), short, queued, queue, line; the plan runs in your queue (queue_status): transfer walks per chest (on_short skip), craft and wait_until crafting_done, load_silo walk'}}
  return M
end
