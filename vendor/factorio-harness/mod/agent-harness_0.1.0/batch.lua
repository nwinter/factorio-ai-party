-- assembler_batch {position, count, requester?, input?, output?, dry_run?} (d17 batch19 C2, Sol: three silos and eight
-- cargo bays made by hand-written plans of 14 steps, 40+ calls, two batches that overshot): a finite batch of the
-- machine's recipe, as one queue plan of the calls Sol made, each step's reply its facts:
-- - circuit_set {output inserter, logistic: "PRODUCT < 0"}: the products stay in the machine; the same on the input
--   inserter ("INGREDIENT < 0"): nothing goes in while the requester fills;
-- - requests {requester, clear_all}, then requests {requester, set}: exactly what the batch still needs of each
--   ingredient (crafts x amount, less what the machine's input and the requester hold now), min = max;
-- - wait_until item_count at the requester for each, then requests {clear_all}: nothing more comes;
-- - circuit_set {input inserter, logistic: false}: in it goes; wait_until item_count at the machine: the products
--   (what it held before plus count);
-- - circuit_set {input inserter, logistic: "INGREDIENT < 0"}: the machine gets nothing more (off); circuit_set {output
--   inserter, logistic: false}: the products go on.
-- The requester: the chest an inserter takes from to put into the machine (requester), that inserter (input), and the
-- inserter that takes from the machine (output), found round it unless given. What the requester already holds over
-- the batch's need is said (surplus): the machine would make more with it. dry_run: the read and the plan.
return function(api)
  local M = {}
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function at(q) return string.format('(%g,%g)', q.x, q.y) end
  local function same(a, b) return a and b and a.valid and b.valid and a.unit_number == b.unit_number end

  -- The inserters round the machine: those that drop into it, and those that pick from it.
  local function inserters(m)
    local b = m.bounding_box
    local ins, outs = {}, {}
    for _, i in ipairs(try(function() return m.surface.find_entities_filtered{type='inserter', force=m.force,
        area={{b.left_top.x - 3, b.left_top.y - 3}, {b.right_bottom.x + 3, b.right_bottom.y + 3}}} end) or {}) do
      if same(try(function() return i.drop_target end), m) then ins[#ins+1] = i end
      if same(try(function() return i.pickup_target end), m) then outs[#outs+1] = i end
    end
    return ins, outs
  end

  function M.run(p, a)
    assert(a.dry_run == nil or type(a.dry_run) == 'boolean', 'dry_run must be true or false')
    local m = api.entity(p, api.position(a.position))
    assert(m and (m.type == 'assembling-machine' or m.type == 'furnace'), 'position: an assembling machine of ours')
    local recipe = try(function() return m.get_recipe() end)
    assert(recipe, string.format('%s %s has no recipe: configure {recipe} first', m.name, at(m.position)))
    local count = api.integer(a.count, nil, 1, 10000, 'count')
    local product, per
    for _, pr in ipairs(recipe.products or {}) do
      if pr.type == 'item' and not product then product, per = pr.name, pr.amount or pr.amount_max or 1 end
    end
    assert(product, recipe.name .. ' makes no item')
    local crafts = math.ceil(count / per)
    -- The requester and the inserters.
    local ins, outs = inserters(m)
    local input, req
    if a.input ~= nil then input = api.entity(p, api.position(a.input)) end
    if a.requester ~= nil then req = api.entity(p, api.position(a.requester)) end
    for _, i in ipairs(ins) do
      local src = try(function() return i.pickup_target end)
      if not input and src and (not req and try(function() return src.prototype.logistic_mode end) == 'requester' or same(src, req)) then input = i; req = req or src end
    end
    assert(req and try(function() return req.prototype.logistic_mode end) == 'requester',
      string.format('no requester chest an inserter takes from into %s %s: give requester {x,y} (and input, the inserter)', m.name, at(m.position)))
    assert(input, string.format('no inserter takes from the requester %s into %s %s: give input {x,y}', at(req.position), m.name, at(m.position)))
    local output = a.output ~= nil and api.entity(p, api.position(a.output)) or outs[1]
    assert(output, string.format('no inserter takes from %s %s: give output {x,y}', m.name, at(m.position)))
    -- What the batch still needs of each ingredient.
    local mi = try(function() return m.get_inventory(defines.inventory.assembling_machine_input) end)
    local mo = try(function() return m.get_inventory(defines.inventory.assembling_machine_output) end)
    local function count_in(inv, name) return inv and (try(function() return inv.get_item_count(name) end) or 0) or 0 end
    local had = count_in(mo, product)
    local sets, waits, surplus, lines = {}, {}, {}, {}
    for _, ing in ipairs(recipe.ingredients or {}) do
      if ing.type == 'item' then
        local total = ing.amount * crafts
        local inside = count_in(mi, ing.name)
        local held = try(function() return req.get_item_count(ing.name) end) or 0
        local need = total - inside - held
        if need > 0 then
          sets[#sets+1] = {item=ing.name, min=need + held, max=need + held}
          waits[#waits+1] = {item=ing.name, at_least=need + held}
          lines[#lines+1] = string.format('%s: %d for %d craft%s, the machine holds %d, the requester %d: %d to come', ing.name, total, crafts,
            crafts == 1 and '' or 's', inside, held, need)
        else
          lines[#lines+1] = string.format('%s: %d for %d craft%s, the machine and the requester hold %d already%s', ing.name, total, crafts,
            crafts == 1 and '' or 's', inside + held, need < 0 and string.format(' (%d over)', -need) or '')
          if need < 0 then surplus[#surplus+1] = string.format('%s %d', ing.name, -need) end
        end
      end
    end
    local first = recipe.ingredients and recipe.ingredients[1] and recipe.ingredients[1].name or product
    local rpos, mpos = {x=req.position.x, y=req.position.y}, {x=m.position.x, y=m.position.y}
    local steps = {}
    local ipos = {x=input.position.x, y=input.position.y}
    steps[#steps+1] = {action='circuit_set', args={position={x=output.position.x, y=output.position.y}, logistic=product .. ' < 0'}, label='hold output'}
    steps[#steps+1] = {action='circuit_set', args={position=ipos, logistic=first .. ' < 0'}, label='input held'}
    steps[#steps+1] = {action='requests', args={position=rpos, clear_all=true}, label='clear requester'}
    if #sets > 0 then
      steps[#steps+1] = {action='requests', args={position=rpos, set=sets}, label='stage'}
      for _, w in ipairs(waits) do
        steps[#steps+1] = {action='wait_until', args={['until']='item_count', positions={rpos}, item=w.item, at_least=w.at_least, timeout=54000}, label='staged ' .. w.item}
      end
      steps[#steps+1] = {action='requests', args={position=rpos, clear_all=true}, label='staged'}
    end
    steps[#steps+1] = {action='circuit_set', args={position=ipos, logistic=false}, label='input on'}
    steps[#steps+1] = {action='wait_until', args={['until']='item_count', positions={mpos}, item=product, at_least=had + count, timeout=54000}, label='made'}
    steps[#steps+1] = {action='circuit_set', args={position=ipos, logistic=first .. ' < 0'}, label='input off'}
    steps[#steps+1] = {action='circuit_set', args={position={x=output.position.x, y=output.position.y}, logistic=false}, label='release output'}
    local plan = {
      string.format('%d %s: %d craft%s of %s in %s %s (it holds %d of it now)', count, product, crafts, crafts == 1 and '' or 's', recipe.name, m.name, at(m.position), had),
      string.format('output inserter %s held (logistic "%s < 0") until the batch is made; input inserter %s held while the requester fills', at(output.position), product, at(input.position)),
      string.format('requester %s cleared, then asked for exactly what is still to come', at(req.position))}
    for _, l in ipairs(lines) do plan[#plan+1] = l end
    plan[#plan+1] = string.format('then: its requests cleared, the input on, wait for %d %s in the machine, the input off again (logistic "%s < 0"), the output released',
      had + count, product, first)
    local out = {machine=at(m.position), recipe=recipe.name, product=product, crafts=crafts, requester=at(req.position), input=at(input.position),
      output=at(output.position), plan=plan, surplus=#surplus > 0 and surplus or nil}
    if #surplus > 0 then
      out.surplus_line = 'the requester and the machine already hold more than the batch needs: ' .. table.concat(surplus, ', ')
        .. '; the machine makes more with it before the input goes off (take it out first: transfer to_player)'
    end
    if a.dry_run then out.line = 'dry run: nothing queued'; out.steps = steps; return out end
    out.queue = api.submit(p, {steps=steps})
    out.queued = #steps
    out.line = string.format('queued %d steps: %s%s', #steps, table.concat(plan, '; '), out.surplus_line and '; ' .. out.surplus_line or '')
    return out
  end
  M.schema = {assembler_batch = {position='the assembling machine {x,y} (its recipe set)', count='1..10000 of its product',
    requester='optional {x,y}: the requester chest that feeds it (default: the one an inserter takes from into it)',
    input='optional {x,y}: that inserter', output='optional {x,y}: the inserter that takes from the machine (default: the one round it)',
    dry_run='true: the read and the plan (steps), nothing queued',
    returns='plan (the batch, each ingredient: for the crafts, held, to come), crafts, product, requester, input, output, surplus (already more than the batch needs: the machine would make more), queued, queue, line; the plan runs in your queue (queue_status): output held by its logistic condition, input held, requester cleared and asked for exactly what is to come, waits for it, requests cleared, input on, waits for the products in the machine, input off, output released. The inserters need a logistic network for their logistic condition'}}
  return M
end
