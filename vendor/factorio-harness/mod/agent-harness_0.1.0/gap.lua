-- ingredient_gap {position | positions | area, all?} (d17 batch21 B3, Luna: breeders held 12/30 and 24/30 nutrients
-- while status said only "missing nutrients", and all nearby stock sat in requester chests near spoilage): per crafting
-- machine, each ingredient of its recipe's next craft: needed, held in its input, how many of those spoil within 5 min
-- (what is usable is the rest), short; for a short one the places near the machine that can spare it without going
-- under their own request (where_kept: a requester or buffer only over its request, robots' reservations off), with
-- how many. As the machine's GUI and the map show them. Read only; bounded: 32 machines, 64 tiles round each.
return function(api)
  local M = {}
  local MAX, NEAR, SOON = 32, 64, 5 * 3600
  local CRAFTERS = {['assembling-machine']=true, furnace=true, ['rocket-silo']=true}
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function at(q) return string.format('(%g,%g)', q.x, q.y) end
  function M.machine(p, e)
    local r = try(function() return e.get_recipe() end) or (e.type == 'furnace' and try(function() return e.previous_recipe end))
    local rname = r and (type(r.name) == 'string' and r.name or try(function() return r.name.name end))
    local recipe = rname and prototypes.recipe[rname]
    if not recipe then return {position=e.position, name=e.name, line=string.format('%s %s: no recipe', e.name, at(e.position))}, false end
    local inv = try(function() return e.get_inventory(e.type == 'furnace' and defines.inventory.furnace_source or defines.inventory.assembling_machine_input) end)
    local rows, short, parts = {}, false, {}
    for _, ing in ipairs(recipe.ingredients or {}) do
      if ing.type == 'item' then
        local held = inv and try(function() return inv.get_item_count(ing.name) end) or 0
        local soon = 0
        local sp = api.spoil and api.spoil()
        if sp and inv then
          local acc = sp.inventory(inv, {}, 'input')
          for _, x in ipairs(acc) do if x.name == ing.name then soon = soon + math.min(x.count, x.soon or 0) end end
        end
        local usable = held - soon
        local gap = math.max(0, ing.amount - usable)
        local row = {item=ing.name, needed=ing.amount, held=held, spoil_5min=soon > 0 and soon or nil, usable=usable, short=gap > 0 and gap or nil}
        local text = string.format('%s %d/%d', ing.name, usable, ing.amount) .. (soon > 0 and string.format(' (%d held, %d of them spoil within 5 min)', held, soon) or '')
        if gap > 0 then
          short = true
          local scan = api.scan(p, ing.name, {position=e.position, radius=NEAR})
          row.donors = api.where_kept(p, ing.name, gap, scan)
          text = text .. string.format(': %d short; %s', gap, row.donors)
        end
        rows[#rows+1] = row; parts[#parts+1] = text
      else
        -- a fluid ingredient: what its box holds
        local amount = 0
        for i = 1, try(function() return #e.fluidbox end) or 0 do
          local f = try(function() return e.fluidbox[i] end)
          if f and f.name == ing.name then amount = amount + f.amount end
        end
        local gap = math.max(0, ing.amount - amount)
        if gap > 0 then short = true end
        rows[#rows+1] = {fluid=ing.name, needed=ing.amount, held=math.floor(amount * 10 + 0.5) / 10, short=gap > 0 and gap or nil}
        parts[#parts+1] = string.format('%s %g/%g (fluid)%s', ing.name, math.floor(amount * 10 + 0.5) / 10, ing.amount, gap > 0 and ' short' or '')
      end
    end
    local status = api.status and try(function() return api.status(e) end)
    return {position=e.position, name=e.name, recipe=rname, status=status, ingredients=rows,
      line=string.format('%s %s %s%s: %s', e.name, at(e.position), rname, status and ' (' .. status .. ')' or '', table.concat(parts, '; '))}, short
  end
  function M.read(p, a)
    assert(a.all == nil or type(a.all) == 'boolean', 'all must be true or false')
    local list = {}
    if a.area ~= nil then
      local lt, rb = api.position(a.area.left_top), api.position(a.area.right_bottom)
      assert(rb.x - lt.x <= 128 and rb.y - lt.y <= 128 and rb.x > lt.x and rb.y > lt.y, 'area is {left_top, right_bottom}, at most 128x128')
      for _, e in ipairs(p.surface.find_entities_filtered{area={lt, rb}, force=p.force, type={'assembling-machine', 'furnace', 'rocket-silo'}}) do
        if e.valid and api.seen(p, e.position) then list[#list+1] = e end
      end
    else
      local ps = a.positions or (a.position ~= nil and {a.position}) or nil
      assert(ps and #ps >= 1 and #ps <= MAX, 'give position, positions (1..' .. MAX .. ') or area')
      for _, q in ipairs(ps) do
        local e = api.entity(p, {position=q})
        assert(e and CRAFTERS[e.type], string.format('%s at %s is no crafting machine', e and e.name or 'nothing', at(api.position(q))))
        list[#list+1] = e
      end
    end
    table.sort(list, function(x, y) return x.position.y < y.position.y or x.position.y == y.position.y and x.position.x < y.position.x end)
    local rows, lines, nshort = {}, {}, 0
    for i = 1, math.min(#list, MAX) do
      local row, short = M.machine(p, list[i])
      if short then nshort = nshort + 1 end
      if short or a.all or a.area == nil then rows[#rows+1] = row; lines[#lines+1] = row.line end
    end
    return {machines=rows, lines=#lines > 0 and lines or {'no machine there is short of an ingredient for its next craft'}, read=math.min(#list, MAX), short=nshort,
      more=#list > MAX and string.format('%d machines there; the first %d read', #list, MAX) or nil}
  end
  M.schema = {ingredient_gap={position='{x,y} of a crafting machine (assembler, furnace, biochamber, silo ...)', positions='or 1..32 of them', area='or {left_top, right_bottom} up to 128x128: the machines there short of an ingredient (all: true: every one)', all='with area: optional true',
    returns='machines [{position, name, recipe, status, ingredients [{item | fluid, needed (one craft), held, spoil_5min, usable, short, donors}], line}]: per ingredient of the next craft, held in its input, how many of those spoil within 5 min, usable, short; for a short item the places within 64 tiles of the machine that can spare it (a requester or buffer chest only over its own request, robots\' reservations off), with how many, else the logistic networks holding it; lines; read, short. Read only'}}
  return M
end
