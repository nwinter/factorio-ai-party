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
-- (d27 batch278 AB, Astra #2589: a dry run on Aquilo for 10 fusion generators held the output and waited for 10 in a
-- cryogenic plant whose output holds one stack of 5 and whose inserters stop feeding it at 2; the plant was also off by
-- its own logistic condition, fusion-generator < 2, which the plan never touched) Measured on 2.0.77 (a copy, a
-- cryogenic plant on fusion-generator and an assembler 2 on gears, their output held): the input inserter stopped
-- feeding at 2 and 3 held and the machines stopped at 4 and 6, what was inside crafted. So the products are no longer
-- held and waited for in the machine: the plan reads the machine's products-finished counter (its GUI's: crafts,
-- productivity bonus crafts too) when it plans and waits (produced, counter_from) for that many more crafts, the
-- products going out through the output inserter as they come. A machine's own enable conditions (its logistic
-- condition, also when no logistic network covers it, and its circuit condition when a wire is on it; an unwired one is
-- ignored) and the output inserter's are switched off for the batch and set back as they were after; the input
-- inserter's own conditions are set back after it too (without any it stays held, as before). The dry run says the
-- output's limits, the counter and where the products go (a chest: its room for them).
return function(api)
  local M = {}
  -- a logistic condition that never holds: the least 32-bit constant (circuits.lua M.NEVER's)
  local HOLD = ' < -2147483648'
  M.HOLD = HOLD
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  -- (d27 batch284 AT, Sol #2619: 100 accumulators at crafting speed 1.05, about 952 s, timed out at the made wait's 900 s)
  -- A wait times out at 54000 ticks at most. The made step is as many produced waits on the machine's counter as its
  -- crafts need, each holding what fits in one with a quarter and 30 s to spare, at most MADE_WAITS (about 2 hours);
  -- a batch past that is refused with the count that fits.
  local WAIT_MAX, MADE_WAITS = 54000, 8
  M.MADE_WAITS = MADE_WAITS
  local function at(q) return string.format('(%g,%g)', q.x, q.y) end
  local function qualities()
    local out = {}
    for q in pairs(prototypes and prototypes.quality or {}) do if q ~= 'quality-unknown' then out[#out+1] = q end end
    table.sort(out)
    return out
  end
  local function same(a, b) return a and b and a.valid and b.valid and a.unit_number == b.unit_number end
  -- A condition as circuit_set takes it back: "fusion-generator < 2", "signal-A >= signal-B", a quality as NAME@QUALITY.
  local ASCII = {['\226\137\165']='>=', ['\226\137\164']='<=', ['\226\137\160']='!='}
  local function ctext(c)
    if type(c) ~= 'table' or type(c.first_signal) ~= 'table' or not c.first_signal.name then return nil end
    local function sig(g) return g.name .. ((g.quality and g.quality ~= 'normal') and '@' .. g.quality or '') end
    local right = (type(c.second_signal) == 'table' and c.second_signal.name) and sig(c.second_signal) or tostring(c.constant or 0)
    return string.format('%s %s %s', sig(c.first_signal), ASCII[c.comparator] or c.comparator or '<', right)
  end
  M.ctext = ctext
  local function wired(e)
    for _, w in ipairs({'circuit_red', 'circuit_green'}) do
      local id = defines.wire_connector_id and defines.wire_connector_id[w]
      if id and try(function() return e.get_circuit_network(id) end) then return true end
    end
    return false
  end
  -- An entity's own enable conditions: {logistic = text | false (connected, no signal), enable = text | false, disabled}
  -- or nil. A circuit condition counts only with a wire on the entity (2.0.77 ignores an unwired one).
  local function own(e)
    local cb = try(function() return e.get_control_behavior() end)
    if not cb then return nil end
    local r = {}
    if try(function() return cb.connect_to_logistic_network end) then r.logistic = ctext(try(function() return cb.logistic_condition end)) or false end
    if try(function() return cb.circuit_enable_disable end) and wired(e) then r.enable = ctext(try(function() return cb.circuit_condition end)) or false end
    if r.logistic == nil and r.enable == nil then return nil end
    r.disabled = try(function() return cb.disabled end) == true
    return r
  end
  M.own = own
  local function own_text(r)
    local parts = {}
    if r.logistic ~= nil then parts[#parts+1] = r.logistic and string.format('logistic "%s"', r.logistic) or 'logistic condition with no signal' end
    if r.enable ~= nil then parts[#parts+1] = r.enable and string.format('circuit "%s" (wired)', r.enable) or 'circuit condition with no signal (wired)' end
    return table.concat(parts, ', ') .. (r.disabled and ', off by it now' or '')
  end
  -- circuit_set arguments that switch R off, and that set it back (nil: nothing to set back; a condition with no signal
  -- cannot be set by circuit_set, so it stays off: said).
  local function off_args(pos, r)
    local a = {position=pos}
    if r.logistic ~= nil then a.logistic = false end
    if r.enable ~= nil then a.remove_condition = true end
    return a
  end
  local function back_args(pos, r, logistic_default)
    local a, any = {position=pos}, false
    if r.logistic then a.logistic = r.logistic; any = true elseif logistic_default ~= nil then a.logistic = logistic_default; any = true end
    if r.enable then a.enable = r.enable; any = true end
    return any and a or nil
  end

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
    local had = 0
    if upgrades then
      for _, q in ipairs(qualities()) do had = had + count_in(mo, product, q) end
    else had = count_in(mo, product) end
    local other = {}
    local sets, waits, surplus, lines, targets = {}, {}, {}, {}, {}
    for _, ing in ipairs(recipe.ingredients or {}) do
      if ing.type == 'item' then
        local total = ing.amount * crafts
        local inside = count_in(mi, ing.name)
        local held = try(function() return req.get_item_count(id(ing.name)) end) or 0
        local need = total - inside - held
        targets[#targets+1] = {name=ing.name, count=math.max(need + held, held)}
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
    -- (AB) the staged waits wait in the requester: what it must hold at once has to fit its slots (under its bar), with
    -- what else it holds; else the batch is refused, the slots said.
    local rinv = try(function() return req.get_inventory(defines.inventory.chest) end)
    local refused, slot_info, slot_line
    if rinv then
      local usable = #rinv
      local bar = try(function() return rinv.get_bar() end)
      if bar and bar - 1 < usable then usable = bar - 1 end
      local function stack_of(n) return try(function() return prototypes.item[n].stack_size end) or 1 end
      local slots, mine, parts = 0, {}, {}
      for _, t in ipairs(targets) do
        local k = math.ceil(t.count / stack_of(t.name))
        slots = slots + k; mine[t.name] = true
        parts[#parts+1] = string.format('%d %s (%d slot%s)', t.count, q_of(t.name), k, k == 1 and '' or 's')
      end
      local other = 0
      for _, c in pairs(try(function() return rinv.get_contents() end) or {}) do
        if type(c) == 'table' and c.name and not (mine[c.name] and (c.quality or 'normal') == quality) then other = other + math.ceil((c.count or 0) / stack_of(c.name)) end
      end
      -- (d27 batch280 CS, Astra #2600) the slots said whether it fits or not
      slot_info = {required=slots + other, available=usable}
      slot_line = string.format('the requester %s holds %d of its %d slots%s at once (%s%s)', at(req.position), slots + other, usable,
        usable < #rinv and string.format(' (its bar at %d of %d)', usable, #rinv) or '', table.concat(parts, ', '), other > 0 and string.format(', other items %d', other) or '')
      if slots + other > usable then
        refused = string.format('the requester %s has %d slot%s%s; the batch must hold %s there at once%s: %d slots. Refused: a smaller count, or a requester with room',
          at(req.position), usable, usable == 1 and '' or 's', usable < #rinv and string.format(' (its bar at %d of %d)', usable, #rinv) or '',
          table.concat(parts, ', '), other > 0 and string.format(', and other items fill %d', other) or '', slots + other)
      end
    end
    local first = recipe.ingredients and recipe.ingredients[1] and recipe.ingredients[1].name or product
    local rpos, mpos = {x=req.position.x, y=req.position.y}, {x=m.position.x, y=m.position.y}
    local opos = {x=output.position.x, y=output.position.y}
    local steps = {}
    local ipos = {x=input.position.x, y=input.position.y}
    local trash = try(function() return req.get_requester_point().trash_not_requested end)
    -- What the machine can hold, and its counter (AB): the products are counted as crafts finished, not in its output.
    local pf = try(function() return m.products_finished end)
    assert(type(pf) == 'number', string.format('%s %s has no products-finished counter', m.name, at(m.position)))
    local stack = try(function() return prototypes.item[product].stack_size end)
    local speed = try(function() return m.crafting_speed end) or 1
    local idle_full = m.type == 'assembling-machine' and per * (1 + math.ceil(1.166 * speed / (recipe.energy or 1) - 1e-9)) or nil
    -- (AT) the counter's rate, measured on a copy (2.0.77): speed / energy x (1 + productivity) a second, crafting_speed
    -- with its modules and beacons, productivity its own (modules, an electromagnetic plant's 50%) and the force's
    -- recipe productivity (research: not in the entity's productivity_bonus)
    local prod = (try(function() return m.productivity_bonus end) or 0) + (try(function() return m.force.recipes[recipe.name].productivity_bonus end) or 0)
    local prod_max = try(function() return prototypes.recipe[recipe.name].maximum_productivity end)
    if prod_max and prod > prod_max then prod = prod_max end
    local per_tick = speed > 0 and speed * (1 + prod) / (60 * (recipe.energy or 1)) or nil
    local est_ticks = per_tick and crafts / per_tick or nil
    -- crafts one made wait holds: its estimate with a quarter and 30 s to spare within the wait's 54000 ticks
    local fits = per_tick and math.max(1, math.floor((WAIT_MAX - 1800) * per_tick / 1.25)) or crafts
    local made_at = {}
    if fits >= crafts then made_at[1] = crafts
    elseif math.ceil(crafts / fits) > MADE_WAITS then
      local most = fits * MADE_WAITS
      local why = string.format('at its crafting speed %g%s the %d crafts take about %d s: more than %d made waits of 900 s hold (%d crafts each). Refused: count %d or less (%d crafts), or batches one after another',
        speed, prod > 0 and string.format(' with productivity +%d%%', math.floor(prod * 100 + 0.5)) or '', crafts, math.floor(est_ticks / 60 + 0.5), MADE_WAITS, fits, most * per, most)
      refused = refused and (refused .. '; ' .. why) or why
      made_at[1] = crafts
    else
      for i = fits, crafts - 1, fits do made_at[#made_at+1] = i end
      made_at[#made_at+1] = crafts
    end
    -- Where the products go: the output inserter's drop target, and a chest's room for them.
    local dest = try(function() return output.drop_target end)
    local room
    if dest and (dest.type == 'container' or dest.type == 'logistic-container') then
      room = try(function() return dest.get_inventory(defines.inventory.chest).get_insertable_count(id(product)) end)
    end
    -- The machine's own conditions and the inserters' (AB): off for the batch, set back after.
    local m_own, o_own, i_own = own(m), own(output), own(input)
    if m_own then steps[#steps+1] = {action='circuit_set', args=off_args(mpos, m_own), label='machine condition off'} end
    if o_own then steps[#steps+1] = {action='circuit_set', args=off_args(opos, o_own), label='output condition off'} end
    local held_args = {position=ipos, logistic=first .. HOLD}
    if i_own and i_own.enable ~= nil then held_args.remove_condition = true end
    steps[#steps+1] = {action='circuit_set', args=held_args, label='input held'}
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
    for i, upto in ipairs(made_at) do
      steps[#steps+1] = {action='wait_until', args={['until']='produced', position=mpos, counter_from=pf, at_least=upto, timeout=WAIT_MAX},
        label=i < #made_at and string.format('made %d of %d', upto, crafts) or 'made'}
    end
    local i_back = i_own and back_args(ipos, i_own, false)
    steps[#steps+1] = i_back and {action='circuit_set', args=i_back, label='input condition back'}
      or {action='circuit_set', args={position=ipos, logistic=first .. HOLD}, label='input off'}
    local o_back = o_own and back_args(opos, o_own)
    if o_back then steps[#steps+1] = {action='circuit_set', args=o_back, label='output condition back'} end
    local m_back = m_own and back_args(mpos, m_own)
    if m_back then steps[#steps+1] = {action='circuit_set', args=m_back, label='machine condition back'} end
    if trash then steps[#steps+1] = {action='requests', args={position=rpos, trash_unrequested=true}, label='trash unrequested on again'} end
    local plan = {
      string.format('%d %s: %d craft%s of %s in %s %s (it holds %d of it now)', count, upgrades and product or q_of(product), crafts, crafts == 1 and '' or 's', recipe.name, m.name, at(m.position), had)}
    if quality ~= 'normal' then
      plan[#plan+1] = string.format('recipe quality %s: each item ingredient is asked for and waited for at %s quality', quality, quality)
    end
    if upgrades then
      plan[#plan+1] = string.format('its modules give quality: some products come out above %s', quality)
    end
    plan[#plan+1] = string.format('counted by its products-finished counter (its GUI\'s crafts, productivity bonus crafts too): %d now, the batch done at %d; the products are not held in it%s: they go out through output inserter %s%s',
      pf, pf + crafts,
      stack and string.format(' (its output holds one stack, %d %s%s)', stack, product, idle_full and string.format(', and inserters stop feeding it at %d held', idle_full) or '') or '',
      at(output.position),
      dest and string.format(' into %s %s%s', dest.name, at(dest.position), room and string.format(' (room for %d %s there now)', room, product) or '') or ' (it drops on the ground or a belt)')
    if room and room < count then
      plan[#plan+1] = string.format('%s %s has room for %d of the %d: once it is full the rest stays in the machine (inserters stop feeding it at %s held) and the batch waits until something takes from it',
        dest.name, at(dest.position), room, count, idle_full and tostring(idle_full) or 'its stack')
    end
    if #made_at > 1 then
      local marks = {}
      for i, upto in ipairs(made_at) do marks[i] = tostring(pf + upto) end
      plan[#plan+1] = string.format('at its crafting speed %g%s the %d crafts take about %d s, more than one wait holds (900 s): the made step is %d waits on its counter, met at %s, each up to 900 s',
        speed, prod > 0 and string.format(' with productivity +%d%%', math.floor(prod * 100 + 0.5)) or '', crafts, math.floor(est_ticks / 60 + 0.5), #made_at, table.concat(marks, ', '))
    end
    if refused then plan[#plan+1] = refused elseif slot_line then plan[#plan+1] = slot_line end
    if m_own then
      local nosig = m_own.logistic == false or m_own.enable == false
      plan[#plan+1] = string.format('the machine\'s own condition (%s) is switched off for the batch and %s', own_text(m_own),
        not m_back and 'stays off after (circuit_set cannot set a condition with no signal)' or nosig and 'set back after, its part with no signal left off' or 'set back after')
    end
    if o_own then
      plan[#plan+1] = string.format('output inserter %s: its own condition (%s) is switched off for the batch and set back after', at(output.position), own_text(o_own))
    end
    plan[#plan+1] = string.format('input inserter %s held (logistic "%s%s", false whatever the network count, reservations too) while the requester fills%s',
      at(input.position), first, HOLD, i_own and string.format('; its own condition (%s) is set back after the batch', own_text(i_own)) or '')
    plan[#plan+1] = string.format('requester %s cleared, then asked for exactly what is still to come', at(req.position))
    if #other > 0 then
      plan[#plan+1] = string.format('the requester %s also holds %s: the machine takes only %s quality', at(req.position), table.concat(other, ', '), quality)
    end
    if trash then
      plan[#plan+1] = string.format('requester %s has trash unrequested on: robots would take the staged ingredients back once its requests are cleared; it is switched off before the requests are cleared and on again after the batch (a plan stopped between leaves it off: requests {position, trash_unrequested: true})', at(req.position))
    end
    for _, l in ipairs(lines) do plan[#plan+1] = l end
    plan[#plan+1] = string.format('then: its requests cleared, the input on, wait for %d craft%s on its counter (%d), %s',
      crafts, crafts == 1 and '' or 's', pf + crafts, i_back and 'the input\'s own condition set back' or string.format('the input off again (logistic "%s%s")', first, HOLD))
    local out = {machine=at(m.position), recipe=recipe.name, quality=quality, product=product, other_quality=#other > 0 and other or nil, crafts=crafts, requester=at(req.position), input=at(input.position),
      output=at(output.position), plan=plan, surplus=#surplus > 0 and surplus or nil,
      counter={now=pf, done_at=pf + crafts}, output_stack=stack, feeds_until=idle_full,
      estimate_s=est_ticks and math.floor(est_ticks / 60 + 0.5) or nil, productivity=prod > 0 and prod or nil, made_waits=#made_at,
      destination=dest and string.format('%s %s', dest.name, at(dest.position)) or nil, room=room,
      machine_condition=m_own and own_text(m_own) or nil, output_condition=o_own and own_text(o_own) or nil, input_condition=i_own and own_text(i_own) or nil,
      trash_unrequested=trash ~= nil and (trash and 'on: switched off for the batch and on again after' or 'off') or nil}
    if #surplus > 0 then
      out.surplus_line = 'the requester and the machine already hold more than the batch needs: ' .. table.concat(surplus, ', ')
        .. '; the machine makes more with it before the input goes off (take it out first: transfer to_player)'
    end
    out.refused = refused
    out.slots = slot_info
    if a.dry_run then out.line = refused and 'dry run: refused, nothing would be queued: ' .. refused or 'dry run: nothing queued'; out.steps = not refused and steps or nil; return out end
    if refused then error(refused, 0) end
    out.queue = api.submit(p, {steps=steps})
    out.queued = #steps
    out.line = string.format('queued %d steps: %s%s', #steps, table.concat(plan, '; '), out.surplus_line and '; ' .. out.surplus_line or '')
    return out
  end
  M.schema = {assembler_batch = {position='the assembling machine {x,y} (its recipe set)', count='1..10000 of its product',
    requester='optional {x,y}: the requester chest that feeds it (default: the one an inserter takes from into it)',
    input='optional {x,y}: that inserter', output='optional {x,y}: the inserter that takes from the machine (default: the one round it)',
    dry_run='true: the read and the plan (steps), nothing queued',
    returns='estimate_s (the crafts at its crafting speed with modules and beacons, and its productivity with recipe research: its counter rises speed / energy x (1 + productivity) a second), made_waits (a wait holds 900 s: past that the made step is several produced waits on the counter, each up to 900 s, at most 8; a batch past those is refused with the count that fits), slots {required, available} (what the requester must hold at once, each ingredient ceil(count / stack size) slots with what else it holds, against its slots under its bar; over: refused), quality (the recipe\'s: item ingredients asked for and waited for at it), other_quality (what the requester holds of an ingredient at another quality: the machine does not take it), trash_unrequested (the requester\'s switch: on is switched off for the batch, before its requests are cleared, and on again after), counter {now, done_at} (the machine\'s products-finished counter, as its GUI shows: crafts, productivity bonus crafts too), output_stack and feeds_until (one stack of the product in its output; inserters stop feeding it at that many held), destination and room (where the output inserter puts the products; a chest\'s room for them now), machine_condition, output_condition, input_condition (their own logistic condition, and circuit condition with a wire on them: switched off for the batch and set back after), plan (the batch, each ingredient: for the crafts, held, to come), crafts, product, requester, input, output, surplus (already more than the batch needs: the machine would make more), queued, queue, line; the plan runs in your queue (queue_status): the machine\'s and the output inserter\'s own conditions off, input held, requester cleared and asked for exactly what is to come, waits for it, requests cleared, input on, waits (produced, counter_from) for the crafts on the machine\'s counter while the products go out, input off (or its own condition set back), the others\' conditions set back. The inserters need a logistic network for their logistic condition'}}
  return M
end
