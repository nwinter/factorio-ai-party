-- assembler_batch {position, count, requester?, input?, output?, dry_run?} (d17 batch19 C2, Sol: three silos and eight
-- cargo bays made by hand-written plans of 14 steps, 40+ calls, two batches that overshot): a finite batch of the
-- machine's recipe, as one queue plan of the calls Sol made, each step's reply its facts:
-- - circuit_set {output inserter, logistic: "PRODUCT < -2147483648"}: the products stay in the machine; the same on the
--   input inserter ("INGREDIENT < -2147483648"): nothing goes in while the requester fills;
-- - requests {requester, clear_all}, then requests {requester, set}: exactly what the batch still needs of each
--   ingredient (crafts x amount, less what the machine's input and the requester hold now), min = max;
-- - wait_until item_count at the requester for each, then requests {clear_all}: nothing more comes;
-- - circuit_set {input inserter, logistic: false}: in it goes; wait_until item_count at the machine: the products
--   (what it held before plus count);
-- - circuit_set {input inserter, logistic: "INGREDIENT < -2147483648"}: the machine gets nothing more (off); circuit_set
--   {output inserter, logistic: false}: the products go on.
-- (d22 batch90 AZ5, Sol board #1878: a hold of "thruster < 0" let the inserter run when deliveries had reserved more
-- thrusters than the network held: the logistic condition read -3, so three legendary thrusters left the machine) a
-- hold is "ITEM < -2147483648", the 32-bit least value: false whatever the network count, as circuit_set switch_off's
-- condition is; a negative available count is normal under reservations.
-- The requester: the chest an inserter takes from to put into the machine (requester), that inserter (input), and the
-- inserter that takes from the machine (output), found round it unless given. What the requester already holds over
-- the batch's need is said (surplus): the machine would make more with it. dry_run: the read and the plan.
-- (d20 batch53 L6, Astra #1205: an Aquilo batch's requester had trash unrequested on; once its requests were cleared
-- robots took the staged ingredients back to storage and the batch stalled with 3 supercapacitors) a requester with
-- trash unrequested on has it switched off before its requests are cleared and staged, and back on after the output
-- is released; the dry run and the plan say so.
-- (d22 batch77 AM1, Sol #1805: a rare pipe recipe staged and waited for normal iron-plate) the recipe's quality, as the
-- machine's GUI shows it: every item ingredient is counted, asked for and waited for at that quality, and the products
-- too (a count by the name alone is normal quality in 2.0); fluids have no quality. A machine whose modules give quality
-- makes some products a tier or more higher: its product wait counts every quality. What the requester holds of an
-- ingredient at another quality is said: the machine does not take it.
return function(api)
  local M = {}
  -- a logistic condition that never holds: the least 32-bit constant (circuits.lua M.NEVER's)
  local HOLD = ' < -2147483648'
  M.HOLD = HOLD
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function at(q) return string.format('(%g,%g)', q.x, q.y) end
  local function qualities()
    local out = {}
    for q in pairs(prototypes and prototypes.quality or {}) do if q ~= 'quality-unknown' then out[#out+1] = q end end
    table.sort(out)
    return out
  end
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
    local recipe, rq = nil, nil
    pcall(function() recipe, rq = m.get_recipe() end)
    local quality = rq and rq.name or 'normal'
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
    -- (the name alone is normal quality)
    local function id(name, q) q = q or quality; return q == 'normal' and name or {name=name, quality=q} end
    local function count_in(inv, name, q) return inv and (try(function() return inv.get_item_count(id(name, q)) end) or 0) or 0 end
    local function q_of(name) return quality == 'normal' and name or string.format('%s (%s)', name, quality) end
    -- Quality from modules: products above the recipe's quality, so the product counts take every quality.
    local upgrades = (try(function() return m.effects and m.effects.quality end) or 0) > 0
    local product_quality = upgrades and 'any' or quality
    local had = 0
    if upgrades then
      for _, q in ipairs(qualities()) do had = had + count_in(mo, product, q) end
    else had = count_in(mo, product) end
    local other = {}
    local sets, waits, surplus, lines = {}, {}, {}, {}
    for _, ing in ipairs(recipe.ingredients or {}) do
      if ing.type == 'item' then
        local total = ing.amount * crafts
        local inside = count_in(mi, ing.name)
        local held = try(function() return req.get_item_count(id(ing.name)) end) or 0
        local need = total - inside - held
        if need > 0 then
          sets[#sets+1] = {item=ing.name, min=need + held, max=need + held, quality=quality ~= 'normal' and quality or nil}
          waits[#waits+1] = {item=ing.name, at_least=need + held}
          lines[#lines+1] = string.format('%s: %d for %d craft%s, the machine holds %d, the requester %d: %d to come', q_of(ing.name), total, crafts,
            crafts == 1 and '' or 's', inside, held, need)
        else
          lines[#lines+1] = string.format('%s: %d for %d craft%s, the machine and the requester hold %d already%s', q_of(ing.name), total, crafts,
            crafts == 1 and '' or 's', inside + held, need < 0 and string.format(' (%d over)', -need) or '')
          if need < 0 then surplus[#surplus+1] = string.format('%s %d', q_of(ing.name), -need) end
        end
        for _, q in ipairs(qualities()) do
          if q ~= quality then
            local k = try(function() return req.get_item_count(id(ing.name, q)) end) or 0
            if k > 0 then other[#other+1] = string.format('%d %s %s', k, q, ing.name) end
          end
        end
      end
    end
    local first = recipe.ingredients and recipe.ingredients[1] and recipe.ingredients[1].name or product
    local rpos, mpos = {x=req.position.x, y=req.position.y}, {x=m.position.x, y=m.position.y}
    local steps = {}
    local ipos = {x=input.position.x, y=input.position.y}
    local trash = try(function() return req.get_requester_point().trash_not_requested end)
    steps[#steps+1] = {action='circuit_set', args={position={x=output.position.x, y=output.position.y}, logistic=product .. HOLD}, label='hold output'}
    steps[#steps+1] = {action='circuit_set', args={position=ipos, logistic=first .. HOLD}, label='input held'}
    if trash then steps[#steps+1] = {action='requests', args={position=rpos, trash_unrequested=false}, label='keep staged (trash unrequested off)'} end
    steps[#steps+1] = {action='requests', args={position=rpos, clear_all=true}, label='clear requester'}
    if #sets > 0 then
      steps[#steps+1] = {action='requests', args={position=rpos, set=sets}, label='stage'}
      for _, w in ipairs(waits) do
        steps[#steps+1] = {action='wait_until', args={['until']='item_count', positions={rpos}, item=w.item, quality=quality ~= 'normal' and quality or nil, at_least=w.at_least, timeout=54000}, label='staged ' .. q_of(w.item)}
      end
      steps[#steps+1] = {action='requests', args={position=rpos, clear_all=true}, label='staged'}
    end
    steps[#steps+1] = {action='circuit_set', args={position=ipos, logistic=false}, label='input on'}
    steps[#steps+1] = {action='wait_until', args={['until']='item_count', positions={mpos}, item=product, quality=product_quality ~= 'normal' and product_quality or nil, at_least=had + count, timeout=54000}, label='made'}
    steps[#steps+1] = {action='circuit_set', args={position=ipos, logistic=first .. HOLD}, label='input off'}
    steps[#steps+1] = {action='circuit_set', args={position={x=output.position.x, y=output.position.y}, logistic=false}, label='release output'}
    if trash then steps[#steps+1] = {action='requests', args={position=rpos, trash_unrequested=true}, label='trash unrequested on again'} end
    local plan = {
      string.format('%d %s: %d craft%s of %s in %s %s (it holds %d of it now)', count, upgrades and product or q_of(product), crafts, crafts == 1 and '' or 's', recipe.name, m.name, at(m.position), had)}
    if quality ~= 'normal' then
      plan[#plan+1] = string.format('recipe quality %s: each item ingredient is asked for and waited for at %s quality%s', quality, quality,
        upgrades and '' or ', and the products counted at it')
    end
    if upgrades then
      plan[#plan+1] = string.format('its modules give quality: some products come out above %s, so the products are counted at every quality', quality)
    end
    for _, l in ipairs{
      string.format('output inserter %s held (logistic "%s%s", false whatever the network count, reservations too) until the batch is made; input inserter %s held while the requester fills', at(output.position), product, HOLD, at(input.position)),
      string.format('requester %s cleared, then asked for exactly what is still to come', at(req.position))} do plan[#plan+1] = l end
    if #other > 0 then
      plan[#plan+1] = string.format('the requester %s also holds %s: the machine takes only %s quality', at(req.position), table.concat(other, ', '), quality)
    end
    if trash then
      plan[#plan+1] = string.format('requester %s has trash unrequested on: robots would take the staged ingredients back once its requests are cleared; it is switched off before the requests are cleared and on again after the output is released (a plan stopped between leaves it off: requests {position, trash_unrequested: true})', at(req.position))
    end
    for _, l in ipairs(lines) do plan[#plan+1] = l end
    plan[#plan+1] = string.format('then: its requests cleared, the input on, wait for %d %s in the machine, the input off again (logistic "%s%s"), the output released',
      had + count, upgrades and product .. ' (every quality)' or q_of(product), first, HOLD)
    local out = {machine=at(m.position), recipe=recipe.name, quality=quality, product=product, other_quality=#other > 0 and other or nil, crafts=crafts, requester=at(req.position), input=at(input.position),
      output=at(output.position), plan=plan, surplus=#surplus > 0 and surplus or nil,
      trash_unrequested=trash ~= nil and (trash and 'on: switched off for the batch and on again after' or 'off') or nil}
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
    returns='quality (the recipe\'s: item ingredients asked for and waited for at it, and the products counted at it; at every quality when the machine\'s modules give quality), other_quality (what the requester holds of an ingredient at another quality: the machine does not take it), trash_unrequested (the requester\'s switch: on is switched off for the batch, before its requests are cleared, and on again after the output is released), plan (the batch, each ingredient: for the crafts, held, to come), crafts, product, requester, input, output, surplus (already more than the batch needs: the machine would make more), queued, queue, line; the plan runs in your queue (queue_status): output held by its logistic condition ("PRODUCT < -2147483648": false whatever the network count, a negative one under reservations too), input held, requester cleared and asked for exactly what is to come, waits for it, requests cleared, input on, waits for the products in the machine, input off, output released. The inserters need a logistic network for their logistic condition'}}
  return M
end
