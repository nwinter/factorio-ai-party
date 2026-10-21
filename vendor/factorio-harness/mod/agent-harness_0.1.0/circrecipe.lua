-- circrecipe: an assembling machine's circuit Set recipe, as 2.0.77 runs it (d21 batch64 Z1, Sol #1515: a crusher on
-- Petrel read no_recipe with Set recipe on while its green wire carried recipe:oxide-asteroid-crushing = 1, and
-- configure was refused as "recipe incompatible with machine"). Seen on a private copy with a crusher and a constant
-- combinator, each case from no recipe:
--   * a recipe signal (recipe:NAME) above 0 sets that recipe, at the signal's quality; red and green alike;
--   * several recipe signals: the lowest recipe order wins whatever the counts (metallic b-a-a before carbonic b-a-b
--     before oxide b-a-c before advanced oxide f); two qualities of one recipe: normal before rare;
--   * a recipe this machine cannot make, or one the force has not researched, is skipped; with none left, no recipe;
--   * recipe signals come before item signals; an item signal alone picks a recipe of this machine that has it as a
--     product (ice and the oxide chunk picked oxide-asteroid-crushing, calcite advanced-oxide, iron ore metallic), at
--     the item signal's quality; virtual signals are ignored; a count of 0 or below is no signal;
--   * when the wires change the recipe, the running craft finishes, then the game moves the old recipe's ingredients
--     and products to the machine's dump slots (defines.inventory.assembling_machine_dump) and the machine has no
--     recipe until they are empty (an inserter taking from it empties them, one with filters only its filter items);
--     then the new recipe goes in;
--   * a recipe set by hand (LuaEntity.set_recipe, the GUI) is ignored while Set recipe is on; with it off, set_recipe
--     works while the dump still holds items, and returns none of them.
return function(api)
  local M = {}
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function qname(q) return type(q) == 'string' and q or q and try(function() return q.name end) or 'normal' end
  local function qlevel(q) return try(function() return prototypes.quality[q].level end) or 0 end
  local function label(kind, name, q) return string.format('%s:%s%s', kind, name, q ~= 'normal' and '@' .. q or '') end
  local MAX_LISTED, MAX_ITEM_SIGNALS, MAX_INSERTERS = 8, 8, 8
  function M.set_recipe_on(e)
    local cb = try(function() return e.get_control_behavior() end)
    return cb and try(function() return cb.circuit_set_recipe end) == true
  end
  -- The signals on its red and green wires, summed as the game reads them: {key: {type, name, quality, count}}, in order.
  function M.signals(e)
    local by, order = {}, {}
    for _, w in ipairs({'circuit_red', 'circuit_green'}) do
      local net = try(function() return e.get_circuit_network(defines.wire_connector_id[w]) end)
      for _, s in ipairs(net and try(function() return net.signals end) or {}) do
        local sig = s.signal or {}
        local kind, q = sig.type or 'item', qname(sig.quality)
        local key = label(kind, sig.name, q)
        local x = by[key]
        if not x then x = {type=kind, name=sig.name, quality=q, count=0}; by[key] = x; order[#order+1] = key end
        x.count = x.count + (s.count or 0)
      end
    end
    local list = {}
    for _, key in ipairs(order) do list[#list+1] = by[key] end
    return list
  end
  -- A recipe the machine could take: the force's recipe, researched, of a category the machine crafts; else why not.
  local function usable(e, name)
    local r = try(function() return e.force.recipes[name] end)
    if not r then return nil, 'no such recipe' end
    if not r.enabled then return nil, 'not researched' end
    if not try(function() return e.prototype.crafting_categories[r.category] end) then return nil, 'not one ' .. e.name .. ' makes' end
    return r
  end
  local function before(a, b)
    local oa, ob = try(function() return a.r.prototype.order end) or '', try(function() return b.r.prototype.order end) or ''
    if oa ~= ob then return oa < ob end
    if a.r.name ~= b.r.name then return a.r.name < b.r.name end
    return qlevel(a.quality) < qlevel(b.quality)
  end
  -- What the wires give: {recipe, quality, from (the signal), skipped [{signal, why}], signals (count)}.
  function M.pick(e)
    local sigs = M.signals(e)
    local recipes, items, skipped = {}, {}, {}
    for _, s in ipairs(sigs) do
      local text = label(s.type, s.name, s.quality)
      if s.count <= 0 then skipped[#skipped+1] = {signal=text, why='count ' .. s.count .. ' (the game takes one above 0)'}
      elseif s.type == 'recipe' then
        local r, why = usable(e, s.name)
        if r then recipes[#recipes+1] = {r=r, quality=s.quality, from=text} else skipped[#skipped+1] = {signal=text, why=why} end
      elseif s.type == 'item' then items[#items+1] = s
      else skipped[#skipped+1] = {signal=text, why='not a recipe or item signal'} end
    end
    local best
    for _, c in ipairs(recipes) do if not best or before(c, best) then best = c end end
    if best then
      for _, s in ipairs(items) do skipped[#skipped+1] = {signal=label('item', s.name, s.quality), why='a recipe signal comes first'} end
    else
      for i, s in ipairs(items) do
        local text = label('item', s.name, s.quality)
        if i > MAX_ITEM_SIGNALS then skipped[#skipped+1] = {signal=text, why='not read (past the first ' .. MAX_ITEM_SIGNALS .. ' item signals)'}
        else
          local found
          local makers = try(function() return prototypes.get_recipe_filtered{{filter='has-product-item', elem_filters={{filter='name', name=s.name}}}} end) or {}
          for name in pairs(makers) do
            local r = usable(e, name)
            if r then local c = {r=r, quality=s.quality, from=text}; if not found or before(c, found) then found = c end end
          end
          if found then
            if not best or before(found, best) then best = found end
          else skipped[#skipped+1] = {signal=text, why='no recipe ' .. e.name .. ' makes has it as a product'} end
        end
      end
    end
    for _, c in ipairs(recipes) do if best and c ~= best and c.from ~= best.from then skipped[#skipped+1] = {signal=c.from, why='recipe ' .. best.r.name .. ' comes first (lower recipe order)'} end end
    return {recipe=best and best.r.name, quality=best and best.quality, from=best and best.from, skipped=skipped, signals=#sigs}
  end
  -- What its dump slots hold: {list of "name*count", items {key: {name, quality, count}}}.
  function M.dump(e)
    local inv = try(function() return e.get_inventory(defines.inventory.assembling_machine_dump) end)
    local held, items = {}, {}
    for _, it in ipairs(inv and try(function() return inv.get_contents() end) or {}) do
      local q = qname(it.quality)
      held[#held+1] = string.format('%s%s*%d', it.name, q ~= 'normal' and '@' .. q or '', it.count)
      items[#items+1] = {name=it.name, quality=q, count=it.count}
    end
    return held, items
  end
  -- The inserters taking from it (a small find round it), and which of the dump's items each takes.
  local function takers(e, items)
    local b = e.bounding_box
    local found = try(function() return e.surface.find_entities_filtered{area={{b.left_top.x - 3, b.left_top.y - 3}, {b.right_bottom.x + 3, b.right_bottom.y + 3}},
      type='inserter', force=e.force, limit=4 * MAX_INSERTERS} end) or {}
    local rows, takes_any = {}, {}
    for _, i in ipairs(found) do
      if #rows >= MAX_INSERTERS then break end
      if try(function() return i.pickup_target end) == e then
        local filters, filtered = {}, try(function() return i.use_filters end)
        if filtered then
          for k = 1, try(function() return i.filter_slot_count end) or 0 do
            local f = try(function() return i.get_filter(k) end)
            if f and f.name then filters[f.name] = true end
          end
        end
        local black = filtered and try(function() return i.inserter_filter_mode end) == 'blacklist'
        local takes = {}
        for _, it in ipairs(items) do
          local ok = not filtered or (filters[it.name] and not black) or (black and not filters[it.name])
          if ok then takes[#takes+1] = it.name; takes_any[it.name] = true end
        end
        local names = {}
        for n in pairs(filters) do names[#names+1] = n end
        table.sort(names)
        rows[#rows+1] = string.format('%s (%g,%g)%s, %s: takes %s', i.name, i.position.x, i.position.y,
          filtered and string.format(' with %s filters %s', black and 'blacklist' or 'whitelist', #names > 0 and table.concat(names, ', ') or 'none') or '',
          api.status_name and api.status_name(i) or tostring(i.status), #takes > 0 and table.concat(takes, ', ') or 'none of them')
      end
    end
    local left = {}
    for _, it in ipairs(items) do if not takes_any[it.name] then left[#left+1] = it.name end end
    return rows, left
  end
  local function skipped_text(pick)
    local parts = {}
    for i, s in ipairs(pick.skipped) do
      if i > MAX_LISTED then parts[#parts+1] = string.format('%d more', #pick.skipped - MAX_LISTED); break end
      parts[#parts+1] = s.signal .. ' (' .. s.why .. ')'
    end
    return table.concat(parts, '; ')
  end
  M.RULE = 'the game takes a recipe signal (recipe:NAME, above 0, at its quality) on red or green, the lowest recipe order among several; '
    .. 'with none, an item signal picks a recipe this machine makes that has it as a product; a recipe it cannot make or not researched is skipped'
  -- inspect's circuit_recipe for a machine with Set recipe on: {set_recipe, wires_give, from, recipe_now, dump, takers,
  -- dump_left, skipped, line}; nil with Set recipe off.
  function M.read(e)
    if not M.set_recipe_on(e) then return nil end
    local pick = M.pick(e)
    local ok, now = pcall(function() return e.get_recipe() end)
    if not ok then now = nil end
    local held, items = M.dump(e)
    local out = {set_recipe=true, wires_give=pick.recipe and pick.recipe .. (pick.quality ~= 'normal' and '@' .. pick.quality or '') or nil, from=pick.from,
      recipe_now=now and now.name or false, dump=#held > 0 and held or nil, skipped=#pick.skipped > 0 and pick.skipped or nil, rule=M.RULE}
    local parts = {}
    if pick.recipe and now and now.name == pick.recipe then
      parts[#parts+1] = string.format('Set recipe is on: its wires give %s (%s), the recipe it has', out.wires_give, pick.from)
    elseif pick.recipe then
      parts[#parts+1] = string.format('Set recipe is on: its wires give %s (%s)', out.wires_give, pick.from)
      if #held > 0 then
        local rows, left = takers(e, items)
        out.takers, out.dump_left = #rows > 0 and rows or nil, #left > 0 and left or nil
        parts[#parts+1] = string.format('%s waits until its dump slots are empty: they hold %s (the last recipe change moved the old recipe\'s items there)',
          now and 'it keeps ' .. now.name .. ' and the new recipe' or 'it has no recipe: the new one', table.concat(held, ', '))
        parts[#parts+1] = #rows > 0 and 'inserters taking from it: ' .. table.concat(rows, '; ') or 'no inserter takes from it'
        if #left > 0 then parts[#parts+1] = 'nothing here takes ' .. table.concat(left, ', ') .. ' out of it (a hand takes them from the dump slots: transfer inventory assembling_machine_dump)' end
      elseif now then
        parts[#parts+1] = string.format('it has %s until its running craft finishes', now.name)
      end
    else
      parts[#parts+1] = pick.signals == 0 and 'Set recipe is on and its wires carry no signal: it has no recipe'
        or string.format('Set recipe is on and none of the %d signal%s on its wires gives a recipe it takes: it has no recipe', pick.signals, pick.signals == 1 and '' or 's')
    end
    if #pick.skipped > 0 then parts[#parts+1] = 'not used: ' .. skipped_text(pick) end
    out.line = table.concat(parts, '; ')
    return out
  end
  -- configure's refusal while Set recipe is on, in the game's terms.
  function M.refusal(e, recipe, quality)
    local pick = M.pick(e)
    local q = quality or 'normal'
    return string.format('%s %s has Set recipe on (its circuit settings): the game sets its recipe from its red and green wires and keeps none set by hand; '
      .. 'its wires give %s now. For %s by hand: circuit_set {settings: {circuit_set_recipe: false}}, then configure recipe; or keep Set recipe on and send recipe:%s '
      .. '(quality %s, above 0) on its red or green wire (a constant combinator\'s signals, circuit_set signals), which the game puts in once its dump slots are empty (%s)',
      e.name, string.format('(%g,%g)', e.position.x, e.position.y), pick.recipe and pick.recipe .. (pick.quality ~= 'normal' and '@' .. pick.quality or '') .. ' (' .. pick.from .. ')' or 'no recipe it takes',
      recipe, recipe, q, M.RULE)
  end
  return M
end
