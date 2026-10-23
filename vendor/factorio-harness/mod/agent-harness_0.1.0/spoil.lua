-- spoil: Space Age spoilage in the reads, and the items that hatch into
-- enemies when they spoil (Sol, shift10 04:59: stored pentapod eggs hatched,
-- destroyed 114 entities of his camp and killed him 4 times).
-- Read on a private 2.0.77 copy of world n:
-- - an item hatches when its spoil trigger creates an entity as an enemy:
--   pentapod-egg (15 min) into big-wriggler-pentapod-premature, one each;
--   biter-egg (30 min) into a big-biter per 25; captive-biter-spawner (30 min)
--   into a behemoth-biter;
-- - a recipe's products start at the count-weighted average spoilage of its
--   spoilable item ingredients (bioflux from 15 yumako-mash at 80% and 12 jelly
--   at 20%: 53.5% a few seconds later), unless the recipe resets freshness
--   (pentapod-egg: eggs bred from nutrients at 80% came out fresh) or always
--   makes them fresh.
-- The egg watch (M.tick): every 30 s our holders near the machines that make
-- or use an item that hatches (found every 5 min on surfaces where one was
-- made or used), near where one was found before, every character and every
-- platform hub, read SLICE entities a tick. A place whose first stack hatches
-- in under 5 minutes is told to the agents on that surface and to whoever
-- built it, once, and again under 1 minute.
return function(api)
  local M = {}
  M.WARN_TICKS, M.LAST_TICKS = 5 * 3600, 3600
  M.SWEEP_TICKS, M.ANCHOR_TICKS, M.SLICE, M.CELL, M.MAX_PLACES, M.MAX_FOUND = 1800, 18000, 120, 64, 64, 512
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function secs(ticks)
    local s = math.max(0, math.floor(ticks / 60 + 0.5))
    if s >= 60 then return string.format('%dm%02ds', math.floor(s / 60), s % 60) end
    return s .. 's'
  end
  M.secs = secs
  local function at(pos) return string.format('(%g,%g)', math.floor(pos.x * 10 + 0.5) / 10, math.floor(pos.y * 10 + 0.5) / 10) end

  -- What an item hatches into when it spoils: {entity, per (items per enemy)}, or false.
  local hatch_cache = {}
  function M.hatch(name)
    local h = hatch_cache[name]
    if h ~= nil then return h end
    h = false
    local res = try(function() return prototypes.item[name].spoil_to_trigger_result end)
    if res then
      local found
      local function walk(t, depth)
        if found or type(t) ~= 'table' or depth > 10 then return end
        if t.type == 'create-entity' and t.entity_name and t.as_enemy then found = t.entity_name; return end
        for _, v in pairs(t) do walk(v, depth + 1) end
      end
      walk(res.trigger, 0)
      if found then h = {entity=found, per=res.items_per_trigger or 1} end
    end
    hatch_cache[name] = h
    return h
  end
  -- "one each", "one per 25".
  function M.per_text(h) return h.per == 1 and 'one each' or 'one per ' .. h.per end
  -- Every item that hatches (computed once per runtime).
  local hatching
  -- Only spoilable items have their trigger read: materialising every item's
  -- spoil_to_trigger_result took 6 ms on a private 2.0.77 server (340 items).
  function M.hatching()
    if not hatching then
      hatching = {}
      for name, proto in pairs(prototypes.item) do
        if (try(function() return proto.get_spoil_ticks() end) or 0) > 0 and M.hatch(name) then hatching[#hatching+1] = name end
      end
      table.sort(hatching)
    end
    return hatching
  end
  function M.spoils(name) return (try(function() return prototypes.item[name].get_spoil_ticks() end) or 0) > 0 end
  -- A stack's spoil tick and spoiled share; nil when it does not spoil.
  local function stack_spoil(s)
    if not (s and s.valid_for_read) then return nil end
    local tick = try(function() return s.spoil_tick end)
    if not tick or tick <= 0 then return nil end
    return tick, try(function() return s.spoil_percent end) or 0
  end
  M.stack_spoil = stack_spoil
  local function pc(x) return math.floor(x * 100 + 0.5) end
  -- Per item: count, the first stack to spoil (its tick and share), and how
  -- many spoil within WARN_TICKS. acc is {[key]=row} plus the rows in order.
  -- The spread too (Sol, 22:25: a chest of 1846 agricultural packs showed the oldest at 91% while hundreds were at
  -- 15-30%): the least and most spoiled stack, the count-weighted spoiled share (wsum / count), the counts by share
  -- (under 25%, 25-50%, 50-75%, 75% and over), and how many spoil within 10, 30 and 60 minutes.
  M.WITHIN = {600 * 60, 1800 * 60, 3600 * 60}
  local function bucket(pct) return pct < 0.25 and 1 or pct < 0.5 and 2 or pct < 0.75 and 3 or 4 end
  -- Measured in 2.0.77 Space Age: a pack contributes its remaining tool
  -- durability times (1 - spoil_percent). Normal labs, before productivity
  -- and lab-specific drain bonuses. Quality is already in get_durability.
  local durability = {}
  local function pack_durability(name, quality)
    local key = name .. '@' .. (quality or 'normal')
    if durability[key] == nil then
      local proto = prototypes.item[name]
      durability[key] = proto and proto.type == 'tool' and try(function() return proto.get_durability(quality) end) or false
    end
    return durability[key] or nil
  end
  local function add_research(r, name, quality, count, pct, tick, used, eta)
    local full = pack_durability(name, quality)
    if not full or full <= 0 then return end
    local remaining = math.max(0, (count - 1) * full + math.min(full, used or full))
    local now = remaining * math.max(0, 1 - pct)
    r.research_units = (r.research_units or 0) + now
    if eta then
      local left = tick - game.tick
      local at_arrival = left > 0 and now * math.max(0, 1 - math.max(0, eta) / left) or 0
      r.research_units_at_arrival = (r.research_units_at_arrival or 0) + at_arrival
    end
  end
  function M.research_value(r, force)
    if r.research_units == nil then return nil end
    local per, tech = 1, force and force.current_research
    local technology
    for _, ing in ipairs(tech and tech.research_unit_ingredients or {}) do
      if ing.name == r.name and (ing.amount or 0) > 0 then per, technology = ing.amount, tech.name; break end
    end
    return {now=r.research_units / per, at_arrival=r.research_units_at_arrival and r.research_units_at_arrival / per,
      packs_per_unit=per, technology=technology, basis='before productivity and lab drain bonuses'}
  end
  function M.research_text(r, force)
    local v = M.research_value(r, force)
    if not v then return nil end
    return string.format('effective research units now %.2f%s (%g pack/unit%s; before lab bonuses)', v.now,
      v.at_arrival and string.format(', at arrival %.2f', v.at_arrival) or '', v.packs_per_unit,
      v.technology and ' for ' .. v.technology or '')
  end
  function M.add(acc, s, where, eta)
    local tick, pct = stack_spoil(s)
    if not tick then return end
    local q = try(function() return s.quality.name end)
    local remaining = pack_durability(s.name, q) and try(function() return s.durability end)
    M.add_count(acc, s.name, q, s.count, pct, tick, where, remaining, eta)
  end
  -- n items of a stack spoiled pct that spoils at tick (a moved part of a stack: transfer's batch).
  function M.add_count(acc, name, q, n, pct, tick, where, remaining_durability, eta)
    local key = name .. (q and q ~= 'normal' and '@' .. q or '')
    local r = acc[key]
    if not r then
      r = {key=key, name=name, count=0, soon=0, tick=tick, percent=pct, where=where, min=pct, max=pct, wsum=0, buckets={0, 0, 0, 0}, within={0, 0, 0}}
      acc[key] = r; acc[#acc+1] = r
    end
    -- A moved batch may carry count/spoil data without remaining tool durability.
    -- Only an actual stack read supplies enough information for research value.
    if remaining_durability ~= nil then add_research(r, name, q, n, pct, tick, remaining_durability, eta) end
    local s = {count=n}
    r.count = r.count + s.count
    if tick - game.tick <= M.WARN_TICKS then r.soon = r.soon + s.count end
    if tick < r.tick then r.tick, r.percent, r.where = tick, pct, where end
    r.min, r.max = math.min(r.min or pct, pct), math.max(r.max or pct, pct)
    r.wsum = (r.wsum or 0) + pct * s.count
    if r.buckets then local b = bucket(pct); r.buckets[b] = r.buckets[b] + s.count end
    for i, w in ipairs(M.WITHIN) do if r.within and tick - game.tick <= w then r.within[i] = r.within[i] + s.count end end
  end
  -- Rows of the same item merged (supply over many places).
  function M.merge(into, r)
    local x = into[r.key]
    if not x then
      x = {key=r.key, name=r.name, count=0, soon=0, tick=r.tick, percent=r.percent, where=r.where, min=r.min, max=r.max, wsum=0, buckets={0, 0, 0, 0}, within={0, 0, 0}}
      into[r.key] = x; into[#into+1] = x
    end
    x.count, x.soon, x.wsum = x.count + r.count, x.soon + r.soon, x.wsum + (r.wsum or r.percent * r.count)
    if r.tick < x.tick then x.tick, x.percent, x.where = r.tick, r.percent, r.where end
    x.min, x.max = math.min(x.min, r.min or r.percent), math.max(x.max, r.max or r.percent)
    for i = 1, 4 do x.buckets[i] = x.buckets[i] + (r.buckets and r.buckets[i] or 0) end
    for i = 1, 3 do x.within[i] = x.within[i] + (r.within and r.within[i] or 0) end
    for _, field in ipairs({'research_units', 'research_units_at_arrival'}) do
      if r[field] ~= nil then x[field] = (x[field] or 0) + r[field] end
    end
    return x
  end
  -- "agricultural-science-pack*1846: spoiled 15-91%, 27% by count; under 25% 900, 25-50% 700, 50-75% 200, 75%+ 46;
  -- spoil within 10 min 46, 30 min 120, 60 min 400"
  function M.spread_text(r)
    if not r.buckets then return M.row_text(r) end
    local b, w = r.buckets, r.within
    local range = pc(r.min) == pc(r.max) and string.format('%d%%', pc(r.min)) or string.format('%d-%d%%', pc(r.min), pc(r.max))
    return string.format('%s*%d: spoiled %s, %d%% by count; under 25%% %d, 25-50%% %d, 50-75%% %d, 75%%+ %d; spoil within 10 min %d, 30 min %d, 60 min %d',
      r.key, r.count, range, r.count > 0 and pc(r.wsum / r.count) or 0, b[1], b[2], b[3], b[4], w[1], w[2], w[3])
  end
  function M.spread(r)
    if not r.buckets then return nil end
    return {count=r.count, min=pc(r.min), max=pc(r.max), mean=r.count > 0 and pc(r.wsum / r.count) or 0,
      buckets={['0-25']=r.buckets[1], ['25-50']=r.buckets[2], ['50-75']=r.buckets[3], ['75+']=r.buckets[4]},
      within={['10min']=r.within[1], ['30min']=r.within[2], ['60min']=r.within[3]}}
  end
  function M.inventory(inv, acc, where, eta)
    if not (inv and try(function() return inv.valid end)) then return acc end
    for i = 1, #inv do M.add(acc, inv[i], where, eta) end
    return acc
  end
  -- Items on a belt's lanes (the lanes' stacks carry their spoilage).
  function M.belt(e, acc, where)
    local n = try(function() return e.get_max_transport_line_index() end) or 0
    for i = 1, n do
      local list = try(function() return e.get_transport_line(i).get_detailed_contents() end) or {}
      for _, d in ipairs(list) do M.add(acc, d.stack, where) end
    end
    return acc
  end
  -- "pentapod-egg*12: the first hatches in 3m10s into big-wriggler-pentapod-premature (78% spoiled)"; earliest first.
  -- The first stack's share, and the whole spread as transfer and inspect give it (E9, Grok 19:50: a hatch line said 91%
  -- for a belt's first egg; the eggs he picked up there read 19% as a batch: two numbers for different stacks).
  -- A4 (Grok 21:21: an alert at 86-92% read as the whole chest that stale): the count-weighted share and how many are
  -- over 50% first, then the first stack's.
  local function spread_lead(count, mean, over50, first, min, max)
    if count > 1 and min and max and min ~= max then
      return string.format('all %d: %d%% spoiled by count, %d at 50%% or more, %d-%d%%; that stack %d%%', count, mean, over50 or 0, min, max, first)
    end
    return string.format('%d%% spoiled', first)
  end
  M.spread_lead = spread_lead
  local function share_text(r)
    local first = math.floor(r.percent * 100 + 0.5)
    if r.count > 1 and r.min and r.max and r.wsum then
      return spread_lead(r.count, pc(r.wsum / r.count), r.buckets and r.buckets[3] + r.buckets[4] or nil, first, pc(r.min), pc(r.max))
    end
    return string.format('%d%% spoiled', first)
  end
  function M.row_text(r)
    local h = M.hatch(r.name)
    local soon = r.soon > 0 and (r.soon < r.count and string.format('; %d within 5 min', r.soon) or '; all within 5 min') or ''
    if h then
      return string.format('%s*%d: the first hatches in %s into %s (%s)%s', r.key, r.count, secs(r.tick - game.tick), h.entity, share_text(r), soon)
    end
    return string.format('%s*%d: the first spoils in %s (%s)%s', r.key, r.count, secs(r.tick - game.tick), share_text(r), soon)
  end
  function M.lines(acc, limit, prefix)
    local rows = {}
    for _, r in ipairs(acc) do rows[#rows+1] = r end
    table.sort(rows, function(x, y) return x.tick < y.tick or (x.tick == y.tick and x.key < y.key) end)
    local out = {}
    for i = 1, math.min(limit or 8, #rows) do out[i] = (prefix or '') .. M.row_text(rows[i]) end
    if #rows > (limit or 8) then out[#out+1] = string.format('+%d more spoilable items', #rows - (limit or 8)) end
    return out
  end
  -- The warning for items that hatch: "12 pentapod-egg hatch into enemies
  -- (big-wriggler-pentapod-premature, 1 per egg): the first in 3m10s".
  function M.warning(acc)
    local parts = {}
    for _, r in ipairs(acc) do
      local h = M.hatch(r.name)
      if h then
        parts[#parts+1] = string.format('%d %s hatch into enemies (%s, %s): the first in %s%s', r.count, r.key, h.entity, M.per_text(h),
          secs(r.tick - game.tick), r.soon > 0 and string.format(', %d within 5 min', r.soon) or '')
      end
    end
    return #parts > 0 and table.concat(parts, '; ') or nil
  end

  -- What a crafting machine's next products start at: the count-weighted
  -- average spoilage of the spoilable item ingredients in its input, unless
  -- its recipe makes them fresh. nil when no product spoils.
  function M.recipe_output(e, recipe, input)
    recipe = recipe or try(function() return e.get_recipe() end)
    if not recipe then return nil end
    local spoiling = {}
    for _, pr in ipairs(recipe.products or {}) do
      if pr.type == 'item' and M.spoils(pr.name) then spoiling[#spoiling+1] = pr.name end
    end
    if #spoiling == 0 then return nil end
    local what = table.concat(spoiling, ', ')
    -- The flags are the prototype's (a machine's get_recipe is a LuaRecipe).
    local proto = try(function() return recipe.prototype end) or recipe
    if try(function() return proto.result_is_always_fresh end) or try(function() return proto.reset_freshness_on_craft end) then
      return string.format('%s start fresh (recipe %s resets freshness)', what, recipe.name)
    end
    input = input or try(function() return e.get_inventory(defines.inventory.assembling_machine_input) end)
    local sum, n, parts, missing = 0, 0, {}, {}
    for _, ing in ipairs(recipe.ingredients or {}) do
      if ing.type == 'item' and M.spoils(ing.name) then
        local pct
        for i = 1, input and #input or 0 do
          local s = input[i]
          if s.valid_for_read and s.name == ing.name then pct = select(2, stack_spoil(s)); break end
        end
        if pct then
          sum, n = sum + ing.amount * pct, n + ing.amount
          parts[#parts+1] = string.format('%s*%d at %d%%', ing.name, ing.amount, math.floor(pct * 100 + 0.5))
        else missing[#missing+1] = ing.name end
      end
    end
    if n == 0 then
      return #missing > 0 and string.format('%s start at the count-weighted spoilage of the spoilable ingredients of recipe %s (none in the input: %s)',
        what, recipe.name, table.concat(missing, ', ')) or string.format('%s start fresh (recipe %s has no spoilable ingredient)', what, recipe.name)
    end
    return string.format('%s start about %d%% spoiled (recipe %s: the count-weighted spoilage of %s%s)', what, math.floor(sum / n * 100 + 0.5), recipe.name,
      table.concat(parts, ', '), #missing > 0 and '; not in the input: ' .. table.concat(missing, ', ') or '')
  end

  -- The egg watch ------------------------------------------------------------
  local HOLDERS = {'container', 'logistic-container', 'assembling-machine', 'furnace', 'inserter', 'transport-belt', 'underground-belt',
    'splitter', 'loader', 'loader-1x1', 'linked-belt', 'cargo-wagon', 'car', 'spider-vehicle', 'cargo-landing-pad', 'rocket-silo',
    'item-entity', 'character', 'logistic-robot', 'construction-robot'}
  local BELT = {['transport-belt']=true, ['underground-belt']=true, splitter=true, loader=true, ['loader-1x1']=true, ['linked-belt']=true}
  local INV = {container={'chest'}, ['logistic-container']={'chest'}, ['assembling-machine']={'assembling_machine_input', 'assembling_machine_output'},
    furnace={'furnace_source', 'furnace_result'}, ['cargo-wagon']={'cargo_wagon'}, car={'car_trunk'}, ['spider-vehicle']={'spider_trunk'},
    ['cargo-landing-pad']={'cargo_landing_pad_main'}, ['space-platform-hub']={'hub_main'}, ['rocket-silo']={'rocket_silo_rocket', 'assembling_machine_input'},
    character={'character_main', 'character_trash'},
    -- (d19 batch46 todo, Grok 09:22: the last pentapod eggs were in an inserter hand, then in a robot's cargo, and every
    -- read said 0 until the breeder died) a robot's cargo near the machines, as an inserter's hand
    ['logistic-robot']={'robot_cargo'}, ['construction-robot']={'robot_cargo'}}
  -- (d22 batch110 BT1: the egg watch read 120 holders a tick with a closure for each read) the reads as functions with
  -- their arguments; the item counts by one get_item_count read a holder, stopping at the first item held; a hand or
  -- a ground stack added only when its item hatches (only those are kept); no tables for a holder with nothing that hatches.
  local NO_INV, NO_ROWS = {}, {}
  local function count_method(h) return h.get_item_count end
  local function holds_any(h, names)
    local okm, count = pcall(count_method, h)
    if not okm then return false end
    for _, name in ipairs(names) do
      local ok, n = pcall(count, name)
      if ok and (n or 0) > 0 then return true end
    end
    return false
  end
  local function held_stack(e) return e.held_stack end
  local function ground_stack(e) return e.stack end
  local function inventory_named(e, inv_name) return e.get_inventory(defines.inventory[inv_name]) end
  -- the items that hatch as a set (M.hatching: spoilable, and hatching when they spoil), made once
  local hatch_set
  local function hatching_stack(s)
    if not hatch_set then hatch_set = {}; for _, n in ipairs(M.hatching()) do hatch_set[n] = true end end
    return s and s.valid_for_read and hatch_set[s.name] and s or nil
  end
  -- The hatching stacks one entity holds: {name=count}, earliest tick and its share, and how many within WARN_TICKS.
  function M.hatching_in(e, names)
    local acc
    local t = e.type
    if BELT[t] then
      if holds_any(e, names) then acc = {}; M.belt(e, acc) end
    elseif t == 'inserter' or t == 'item-entity' then
      local ok, st = pcall(t == 'inserter' and held_stack or ground_stack, e)
      st = ok and hatching_stack(st) or nil
      if st then acc = {}; M.add(acc, st) end
    else
      for _, inv_name in ipairs(INV[t] or NO_INV) do
        local ok, inv = pcall(inventory_named, e, inv_name)
        if ok and inv and holds_any(inv, names) then acc = acc or {}; M.inventory(inv, acc) end
      end
    end
    if not acc then return NO_ROWS end
    local rows = {}
    for _, r in ipairs(acc) do if M.hatch(r.name) then rows[#rows+1] = r end end
    return rows
  end
  local function watch()
    local st = api.state()
    st.eggs = st.eggs or {anchors={}, places={}, told={}, seq=0}
    return st.eggs
  end
  -- Surfaces where an item that hatches was made or used (force statistics).
  local function flowing(force, names)
    local out = {}
    for _, s in pairs(game.surfaces) do
      local stats = try(function() return force.get_item_production_statistics(s) end)
      for _, name in ipairs(names) do
        if stats and ((try(function() return stats.get_input_count(name) end) or 0) > 0 or (try(function() return stats.get_output_count(name) end) or 0) > 0) then
          out[#out+1] = s; break
        end
      end
    end
    table.sort(out, function(a, b) return (a.index or 0) < (b.index or 0) end)
    return out
  end
  local function cell_key(surface, pos) return surface .. '|' .. math.floor(pos.x / M.CELL) .. ',' .. math.floor(pos.y / M.CELL) end
  -- Every ANCHOR_TICKS: the cells around crafting machines whose recipe makes
  -- or uses an item that hatches, and which of those items flow anywhere (the
  -- sweep checks only those, and any found before). A job of its own: the
  -- surfaces where one flows, walked in bands of chunks a tick (walk.lua;
  -- operator 04:00: whole-surface finds made background jobs burst).
  local walk = api.walk or require('walk'){state=api.state}
  local function start_anchors(w, force, names, tick)
    local live, surfaces = {}, {}
    for _, s in ipairs(flowing(force, names)) do surfaces[#surfaces+1] = s.name end
    for _, s in pairs(game.surfaces) do
      local stats = try(function() return force.get_item_production_statistics(s) end)
      for _, name in ipairs(names) do
        if stats and ((try(function() return stats.get_input_count(name) end) or 0) > 0 or (try(function() return stats.get_output_count(name) end) or 0) > 0) then live[name] = true end
      end
    end
    for _, p in ipairs(w.places or {}) do live[p.item:match('^[^@]+')] = true end
    local watched = {}
    for _, name in ipairs(names) do if live[name] then watched[#watched+1] = name end end
    w.anchor_job = {start=tick, surfaces=surfaces, i=1, anchors={}, watched=watched}
  end
  local function anchor_step(w, force, names)
    local job = w.anchor_job
    local name = job.surfaces[job.i]
    if not name then
      w.anchors, w.watched, w.anchor_tick, w.anchor_job = job.anchors, job.watched, job.start, nil
      return
    end
    local s = game.surfaces[name]
    if not s then job.i = job.i + 1; job.walk = nil; return end
    job.walk = job.walk or walk.start(s)
    local list = walk.band(job.walk, s, {force=force, type={'assembling-machine', 'furnace'}})
    if not list then job.i = job.i + 1; job.walk = nil; return end
    local set = {}
    for _, n in ipairs(names) do set[n] = true end
    for _, e in ipairs(list) do
      local r = try(function() return e.get_recipe() end)
      local uses = false
      for _, part in ipairs{r and r.products or {}, r and r.ingredients or {}} do
        for _, x in ipairs(part) do if set[x.name] then uses = true end end
      end
      if uses then job.anchors[cell_key(s.name, e.position)] = {surface=s.name, x=math.floor(e.position.x / M.CELL), y=math.floor(e.position.y / M.CELL)} end
    end
  end
  -- The background sweep, a stage a tick: cells (found, then read SLICE a
  -- tick), then characters and hubs, then the merge into places.
  function M.tick(tick)
    local all = M.hatching()
    if #all == 0 then return end
    local w = watch()
    -- (BT1) between sweeps nothing to do: the force not read (the same test as below, made before it)
    if not w.anchor_job and not w.job and w.tick and tick - w.tick < M.SWEEP_TICKS then return end
    local names = w.watched or all
    local force = api.force and api.force()
    if not force then return end
    if w.anchor_job then return anchor_step(w, force, all) end
    local job = w.job
    if not job then
      if w.tick and tick - w.tick < M.SWEEP_TICKS then return end
      if not w.anchor_tick or tick - w.anchor_tick >= M.ANCHOR_TICKS then start_anchors(w, force, all, tick); return end
      if #names == 0 and #(w.places or {}) == 0 then w.tick = tick; return end
      local cells, seen = {}, {}
      for key, c in pairs(w.anchors or {}) do if not seen[key] then seen[key] = true; cells[#cells+1] = c end end
      for _, p in ipairs(w.places or {}) do
        local key = cell_key(p.surface, p.position)
        if not seen[key] then seen[key] = true; cells[#cells+1] = {surface=p.surface, x=math.floor(p.position.x / M.CELL), y=math.floor(p.position.y / M.CELL)} end
      end
      table.sort(cells, function(a, b) return a.surface < b.surface or (a.surface == b.surface and (a.x < b.x or (a.x == b.x and a.y < b.y))) end)
      w.job = {start=tick, cells=cells, i=1, found={}, done={}}
      return
    end
    if job.list then
      local last = math.min(#job.list, job.at + M.SLICE - 1)
      for k = job.at, last do
        local e = job.list[k]
        if e.valid and not job.done[e.unit_number or -k] then
          if e.unit_number then job.done[e.unit_number] = true end
          for _, r in ipairs(M.hatching_in(e, names)) do
            job.found[#job.found+1] = {surface=e.surface.name, position={x=e.position.x, y=e.position.y}, entity=e.name, item=r.key, count=r.count,
              soon=r.soon, tick=r.tick, percent=r.percent, min=r.min and pc(r.min), max=r.max and pc(r.max), mean=r.wsum and r.count > 0 and pc(r.wsum / r.count) or nil, over50=r.buckets and r.buckets[3] + r.buckets[4] or nil,
              by=try(function() return e.last_user and e.last_user.name end)}
          end
        end
      end
      job.at = last + 1
      if job.at > #job.list then job.list, job.at = nil, nil end
      return
    end
    local c = job.cells[job.i]
    if c then
      job.i = job.i + 1
      local s = game.surfaces[c.surface]
      if s then
        local x0, y0 = c.x * M.CELL - 16, c.y * M.CELL - 16
        job.list = try(function() return s.find_entities_filtered{area={{x0, y0}, {x0 + M.CELL + 32, y0 + M.CELL + 32}}, force=force, type=HOLDERS} end) or {}
        job.at = 1
        if #job.list == 0 then job.list, job.at = nil, nil end
      end
      return
    end
    -- Characters anywhere (agents carrying eggs) and platform hubs.
    local extra = {}
    for _, ch in ipairs(api.characters and api.characters() or {}) do extra[#extra+1] = ch end
    for _, pl in pairs(try(function() return force.platforms end) or {}) do
      local hub = try(function() return pl.valid and pl.hub end)
      if hub and hub.valid then extra[#extra+1] = hub end
    end
    for _, e in ipairs(extra) do
      if e.valid and not (e.unit_number and job.done[e.unit_number]) then
        for _, r in ipairs(M.hatching_in(e, names)) do
          job.found[#job.found+1] = {surface=e.surface.name, position={x=e.position.x, y=e.position.y}, entity=e.name, item=r.key, count=r.count,
            soon=r.soon, tick=r.tick, percent=r.percent, min=r.min and pc(r.min), max=r.max and pc(r.max), mean=r.wsum and r.count > 0 and pc(r.wsum / r.count) or nil, over50=r.buckets and r.buckets[3] + r.buckets[4] or nil, by=e.type == 'character' and api.character_name and api.character_name(e) or try(function() return e.last_user and e.last_user.name end)}
        end
      end
    end
    table.sort(job.found, function(a, b) return a.tick < b.tick end)
    -- One place per 64-tile cell and item: its first stack, with the count of
    -- the cell's others that hatch within 5 minutes.
    local places, by_key = {}, {}
    for _, f in ipairs(job.found) do
      local key = cell_key(f.surface, f.position) .. '|' .. f.item
      local first = by_key[key]
      if not first then
        f.key, f.others = key, 0
        by_key[key] = f
        if #places < M.MAX_PLACES then places[#places+1] = f end
      elseif f.tick - game.tick <= M.WARN_TICKS then first.others = first.others + f.count end
    end
    -- A place crossing a mark (under 5 min, then under 1 min) is news, kept
    -- on the place (its seq) until it hatches, for agents who reply later. A
    -- later first stack than the one told about (that one hatched or went) is
    -- a new batch: its marks count again.
    local told = {}
    for _, f in ipairs(places) do
      local left = f.tick - game.tick
      local mark = left <= M.LAST_TICKS and 2 or (left <= M.WARN_TICKS and 1 or 0)
      local before = (w.told or {})[f.key]
      if before and f.tick > (before.tick or 0) + 600 then before = nil end
      if mark > (before and before.mark or 0) then w.seq = (w.seq or 0) + 1; before = {mark=mark, seq=w.seq, tick=f.tick} end
      if before then told[f.key] = before; f.news = before.seq end
    end
    -- Keep old timer sites for ten minutes after their predicted expiry, as
    -- history: the eggs may have hatched there. A site whose eggs this sweep did
    -- not find again before its time (moved or used, A2) or that a check found
    -- empty before then (gone) is dropped.
    local recent,seen,again={},{},{}
    for _,f in ipairs(job.found) do again[f.surface..'|'..at(f.position)..'|'..f.item]=true end
    for _,list in ipairs({w.places or {},w.recent or {}}) do
      for _,old in ipairs(list) do
        local key=old.surface..'|'..at(old.position)
        local left=not old.gone and (old.tick<=game.tick or again[key..'|'..old.item])
        if left and old.tick>=game.tick-36000 and old.tick<=game.tick+M.WARN_TICKS and not seen[key] and #recent<64 then
          recent[#recent+1]=old;seen[key]=true
        end
      end
    end
    w.recent=recent
    -- (d17 batch23 B1, Luna and Grok: the alerts named one holder at a time while several hatched at once) every holder
    -- the sweep found, the first to hatch first (at most MAX_FOUND)
    local found = {}
    for i, f in ipairs(job.found) do if i <= M.MAX_FOUND then found[i] = f end end
    w.found, w.found_tick = found, game.tick
    w.places, w.told, w.tick, w.job = places, told, job.start, nil
  end
  -- Whether a place's holder still holds its eggs now (d17 batch18 A2, Luna: a timer stayed on a provider after Grok
  -- moved its eggs into a breeder): the entity of that name at that position (a character: the one of that name),
  -- read as the sweep reads it. A place found empty before its first stack's time is marked gone (the eggs were moved
  -- or used) and is told no more, nor kept as a site; one empty after it may have hatched, and stays as history.
  function M.still_held(place)
    local item = place.item:match('^[^@]+')
    local holder
    if place.entity == 'character' then
      for _, ch in ipairs(api.characters and api.characters() or {}) do
        if ch.valid and api.character_name and api.character_name(ch) == place.by then holder = ch end
      end
    else
      local s = game.surfaces[place.surface]
      local x, y = place.position.x, place.position.y
      for _, e in ipairs(s and try(function() return s.find_entities_filtered{area={{x - 0.05, y - 0.05}, {x + 0.05, y + 0.05}}, name=place.entity, limit=4} end) or {}) do
        if e.valid and e.name == place.entity and math.abs(e.position.x - x) < 0.01 and math.abs(e.position.y - y) < 0.01 then holder = e end
      end
    end
    local n = 0
    if holder then for _, r in ipairs(M.hatching_in(holder, {item}) or {}) do if r.name == item then n = n + r.count end end end
    if n == 0 and place.tick > game.tick then place.gone = game.tick end
    return n > 0
  end
  local function live(place)
    return not place.gone and (place.tick <= game.tick or M.still_held(place))
  end
  -- The places hatching soon an agent hears of: on its surface, or built by it.
  local function mine(p, name, place)
    local here = try(function() return p.surface.name end)
    return place.surface == here or (name and place.by == name)
  end
  function M.place_text(place, here)
    local h = M.hatch(place.item:match('^[^@]+'))
    -- the spread as transfer and inspect give it, beside the first stack's share (E9)
    local share = place.mean and spread_lead(place.count, place.mean, place.over50, math.floor(place.percent * 100 + 0.5), place.min, place.max)
      or string.format('%d%% spoiled', math.floor(place.percent * 100 + 0.5))
    return string.format('%d %s in %s at %s%s: the first hatch%s in %s (%s)%s%s', place.count, place.item, place.entity, at(place.position),
      place.surface ~= here and ' on ' .. place.surface or '', h and ' into ' .. h.entity or '', secs(place.tick - game.tick),
      share,
      place.soon > 0 and (place.soon < place.count and string.format(', %d of them within 5 min', place.soon) or ', all within 5 min') or '',
      (place.others or 0) > 0 and string.format('; %d more in other holders within 64 tiles hatch within 5 min', place.others) or '')
  end
  -- The holders of a surface due within 5 min (first stack's time), from the last sweep, and their areas (CELL tiles).
  local function due_on(w, surface)
    local list, areas, order, eggs = {}, {}, {}, 0
    for _, f in ipairs(w.found or {}) do
      if f.surface == surface and f.tick > game.tick and f.tick - game.tick <= M.WARN_TICKS then
        list[#list+1] = f
        eggs = eggs + (f.soon or 0)
        local k = cell_key(f.surface, f.position)
        local a = areas[k]
        if not a then
          local cx, cy = math.floor(f.position.x / M.CELL) * M.CELL, math.floor(f.position.y / M.CELL) * M.CELL
          a = {x0=cx, y0=cy, eggs=0, holders=0, first=f.tick}; areas[k] = a; order[#order+1] = a
        end
        a.eggs, a.holders, a.first = a.eggs + (f.soon or 0), a.holders + 1, math.min(a.first, f.tick)
      end
    end
    table.sort(order, function(x, y) return x.first < y.first end)
    return list, order, eggs
  end
  -- Lines for the team block (d17 batch23 B1): one line a surface with eggs due within 5 min (this agent's surface,
  -- or holders it built), told again only when the set of holders due there changes (h.egg_sets).
  function M.alert_lines(p, h, name)
    local w = watch()
    local here = try(function() return p.surface.name end)
    local out = {}
    local surfaces, sorder = {}, {}
    for _, place in ipairs(w.places or {}) do
      if place.tick > game.tick and place.tick - game.tick <= M.WARN_TICKS and mine(p, name, place) and not surfaces[place.surface] and live(place) then
        surfaces[place.surface] = place; sorder[#sorder+1] = place.surface
      end
    end
    h.egg_sets = h.egg_sets or {}
    for sname in pairs(h.egg_sets) do if not surfaces[sname] then h.egg_sets[sname] = nil end end
    for _, sname in ipairs(sorder) do
      local first = surfaces[sname]
      local list, areas, eggs = due_on(w, sname)
      local keys = {}
      for i, f in ipairs(list) do keys[i] = f.entity .. at(f.position) .. f.item end
      table.sort(keys)
      local sig = table.concat(keys, ';')
      if sig ~= '' and h.egg_sets[sname] ~= sig and #out < 3 then
        h.egg_sets[sname] = sig
        local cov = api.coverage and try(function() return api.coverage(first.surface, first.position) end)
        local parts = {}
        for i, a in ipairs(areas) do
          if i <= 4 then parts[i] = string.format('(%d,%d)-(%d,%d) %d in %d holder%s, the first in %s', a.x0, a.y0, a.x0 + M.CELL, a.y0 + M.CELL, a.eggs, a.holders,
            a.holders == 1 and '' or 's', secs(a.first - game.tick)) end
        end
        out[#out+1] = string.format('eggs hatching on %s: %d within 5 min in %d holder%s; the first: %s%s; by area: %s%s; eggs {surface: "%s"} lists each holder',
          sname, eggs, #list, #list == 1 and '' or 's', M.place_text(first, here), cov and ' (' .. cov .. ')' or '',
          table.concat(parts, '; '), #areas > 4 and string.format('; +%d more areas', #areas - 4) or '', sname)
      end
    end
    h.eggs_seq = w.seq or 0
    return out
  end
  -- (B1) eggs {surface?, limit?}: every holder of eggs the last sweep found on a surface, the first to hatch first.
  function M.read_eggs(p, a)
    local w = watch()
    local sname = a.surface or try(function() return p.surface.name end)
    assert(type(sname) == 'string', 'surface must be a surface name')
    -- (d20 batch62 X2, Sol #1529) a surface name that is no surface is refused, never read as an empty one
    assert(game.get_surface(sname), 'no surface named ' .. sname)
    local limit = a.limit == nil and 64 or a.limit
    assert(type(limit) == 'number' and limit >= 1 and limit <= 256, 'limit is 1..256 (holders given turret cover)')
    local rows, lines, eggs, holders = {}, {}, 0, 0
    for _, f in ipairs(w.found or {}) do
      if f.surface == sname then
        holders = holders + 1; eggs = eggs + f.count
        if #rows < limit then
          local cov = api.coverage and try(function() return api.coverage(f.surface, f.position) end)
          local h = M.hatch(f.item:match('^[^@]+'))
          local row = {holder=f.entity, position=f.position, item=f.item, count=f.count, spoiled_percent=f.mean or math.floor(f.percent * 100 + 0.5),
            first_spoiled_percent=math.floor(f.percent * 100 + 0.5), first_hatch_in_s=math.floor((f.tick - game.tick) / 60), due_5min=f.soon, into=h and h.entity or nil, cover=cov, by=f.by}
          rows[#rows+1] = row
          lines[#lines+1] = string.format('%d %s in %s at %s (%s): %d%% spoiled (the first stack %d%%), the first hatch%s %s%s; %s', f.count, f.item, f.entity, at(f.position),
            f.by or '?', row.spoiled_percent, row.first_spoiled_percent, h and ' into ' .. h.entity or '',
            f.tick > game.tick and 'in ' .. secs(f.tick - game.tick) or 'due ' .. secs(game.tick - f.tick) .. ' ago (it may have hatched)',
            (f.soon or 0) > 0 and string.format(', %d within 5 min', f.soon) or '', cov or 'turret cover not read')
        end
      end
    end
    local _, areas, due = due_on(w, sname)
    local area_rows = {}
    for i, x in ipairs(areas) do area_rows[i] = {area={left_top={x=x.x0, y=x.y0}, right_bottom={x=x.x0 + M.CELL, y=x.y0 + M.CELL}}, due_5min=x.eggs, holders=x.holders, first_in_s=math.floor((x.first - game.tick) / 60)} end
    local age = w.found_tick and math.floor((game.tick - w.found_tick) / 60)
    table.insert(lines, 1, string.format('%d eggs in %d holders on %s (the egg sweep %s); %d due within 5 min%s', eggs, holders, sname,
      age and age .. 's ago' or 'has not run yet', due, #area_rows > 0 and ' by area: ' .. (function()
        local t = {}
        for i, x in ipairs(areas) do if i <= 8 then t[i] = string.format('(%d,%d)-(%d,%d) %d', x.x0, x.y0, x.x0 + M.CELL, x.y0 + M.CELL, x.eggs) end end
        return table.concat(t, ', ') end)() or ''))
    if holders > #rows then lines[#lines+1] = string.format('+%d more holders (limit %d)', holders - #rows, limit) end
    return {surface=sname, eggs=eggs, holders=holders, due_5min=due, areas=area_rows, rows=rows, lines=lines, sweep_age_s=age,
      note='from the egg sweep (every 30 s through the cells where eggs are made or were found, characters and hubs); turret cover: turrets of ours in range with ammunition, power or fluid'}
  end
  M.schema = {eggs={surface='optional surface name (default yours)', limit='optional 1..256 holders given turret cover (default 64)',
    returns='lines: a head (eggs and holders on the surface, the sweep\'s age, the eggs due within 5 min by 64-tile area), then each holder, the first to hatch first: count, item, holder, position, who placed it, spoiled percent (mean, and the first stack), the first hatch (into what, when), how many within 5 min, the turrets of ours ready in range; rows [{holder, position, item, count, spoiled_percent, first_spoiled_percent, first_hatch_in_s, due_5min, into, cover, by}], areas [{area, due_5min, holders, first_in_s}], eggs, holders, due_5min, sweep_age_s. Read only'}}
  -- For a sleeper: news after seq that concerns this agent (waits.lua wakes it).
  -- carried_only: a sleep that takes no messages (a ship wait; E9, Grok 19:50: every egg alert woke one) hears only of
  -- eggs its own character carries; the rest reach it in the team block of its next reply.
  function M.news(p, seq, name, carried_only)
    local w = watch()
    local here = try(function() return p.surface.name end)
    for _, place in ipairs(w.places or {}) do
      if place.news and place.news > seq and place.tick > game.tick and mine(p, name, place)
        and (not carried_only or place.entity == 'character' and place.by == name) and live(place) then return 'eggs hatching: ' .. M.place_text(place, here) end
    end
  end
  local nearby=require('eggnear'){}
  function M.nearby(p)
    local w,sites=watch(),{}
    for _,list in ipairs({w.places or {},w.recent or {}}) do for _,s in ipairs(list) do if not s.gone then sites[#sites+1]=s end end end
    sites.check=live
    return nearby.read(p,sites)
  end
  function M.seq() return watch().seq or 0 end
  -- The places on a surface within r of pos whose eggs hatch, nearest first (danger, d17 batch22 B1): {position, tick, text}.
  function M.near(surface, pos, r)
    local w, out = watch(), {}
    for _, place in ipairs(w.places or {}) do
      if place.surface == surface and place.tick > game.tick and M.hatch(place.item:match('^[^@]+')) and live(place) then
        local d = ((place.position.x - pos.x)^2 + (place.position.y - pos.y)^2)^0.5
        if d <= r then out[#out+1] = {position=place.position, tick=place.tick, d=d, text=M.place_text(place, surface)} end
      end
    end
    table.sort(out, function(x, y) return x.d < y.d end)
    return out
  end
  -- The watch's last sweep, for a read: places, earliest first.
  function M.places(limit)
    local w = watch()
    local out = {}
    for i, place in ipairs(w.places or {}) do
      if i > (limit or 16) then break end
      if place.tick > game.tick and live(place) then out[#out+1] = M.place_text(place) end
    end
    return out, w.tick
  end
  return M
end
