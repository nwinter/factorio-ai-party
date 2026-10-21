-- ingredient_gap {position | positions | area, all?} (d17 batch21 B3, Luna: breeders held 12/30 and 24/30 nutrients
-- while status said only "missing nutrients", and all nearby stock sat in requester chests near spoilage): per crafting
-- machine, each ingredient of its recipe's next craft: needed, held in its input, how many of those spoil within 5 min
-- (what is usable is the rest), short; for a short one the places near the machine that can spare it without going
-- under their own request (where_kept: a requester or buffer only over its request, robots' reservations off), with
-- how many. As the machine's GUI and the map show them. Read only; bounded: 32 machines, 64 tiles round each, donors
-- for 8 short items.
return function(api)
  local M = {}
  -- (d19 batch45) PER machines a call: 32 machines' reply was 26 KB, 9 ms to encode on the private copy
  local MAX, PER, NEAR, SOON, MAX_DONORS = 32, 16, 64, 5 * 3600, 8
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
    local sp = api.spoil and api.spoil()
    local acc = sp and inv and sp.inventory(inv, {}, 'input') or {}
    for _, ing in ipairs(recipe.ingredients or {}) do
      if ing.type == 'item' then
        local held = inv and try(function() return inv.get_item_count(ing.name) end) or 0
        local soon = 0
        for _, x in ipairs(acc) do if x.name == ing.name then soon = soon + math.min(x.count, x.soon or 0) end end
        local usable = held - soon
        local gap = math.max(0, ing.amount - usable)
        local row = {item=ing.name, needed=ing.amount, held=held, spoil_5min=soon > 0 and soon or nil, usable=usable, short=gap > 0 and gap or nil}
        local text = string.format('%s %d/%d', ing.name, usable, ing.amount) .. (soon > 0 and string.format(' (%d held, %d of them spoil within 5 min)', held, soon) or '')
        if gap > 0 then
          -- donors after the machines are read (M.donors); the part waits for them
          short = true; row.short_by = gap
          text = {text=text, row=row}
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
    local m = {position=e.position, name=e.name, recipe=rname, status=status, ingredients=rows, short_of=short or nil}
    m.line = function()
      local l = {}
      for k, x in ipairs(parts) do
        l[k] = type(x) == 'table' and string.format('%s: %d short; %s', x.text, x.row.short, x.row.donors or 'donors not read') or x
      end
      return string.format('%s %s %s%s: %s', e.name, at(e.position), rname, status and ' (' .. status .. ')' or '', table.concat(l, '; '))
    end
    return m, short
  end
  -- Each short item's donors, the first MAX_DONORS short items of the call (machines in order); the holders found
  -- once in the box of those machines widened by NEAR; the ground from the ground watch's last pass, once an item.
  -- (d19 batch45: 17 machines with 21 short items were 240 ms on the private copy's Vulcanus, the ground read 10 ms an
  -- item; a 128x128 area of Nauvis with 30 was 1.9 s)
  function M.donors(p, ms)
    local todo, skipped = {}, 0
    for _, m in ipairs(ms) do
      for _, row in ipairs(m.ingredients or {}) do
        if row.short_by then
          if #todo < MAX_DONORS then todo[#todo+1] = {m=m, row=row} else skipped = skipped + 1 end
        end
      end
    end
    local near, grounds, unread = nil, {}, false
    if #todo > 0 and api.near then
      local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
      for _, t in ipairs(todo) do local q = t.m.position; x0, y0, x1, y1 = math.min(x0, q.x), math.min(y0, q.y), math.max(x1, q.x), math.max(y1, q.y) end
      local ok, v = pcall(api.near, p, {left_top={x=x0 - NEAR, y=y0 - NEAR}, right_bottom={x=x1 + NEAR, y=y1 + NEAR}}, function(item)
        if grounds[item] == nil then
          local g = api.ground_index and try(function() return api.ground_index(p.force, p.surface, item) end)
          if not g then unread = true end
          grounds[item] = g or false
        end
        return grounds[item] or nil
      end)
      near = ok and v or nil
    end
    for _, t in ipairs(todo) do
      -- (d19 batch41 A1) a donor search that fails says so on its row; the other machines still read
      local okd, donors = pcall(function() return api.where_kept(p, t.row.item, t.row.short_by, api.scan(p, t.row.item, {position=t.m.position, radius=NEAR, near=near})) end)
      t.row.donors = okd and donors or 'donors not read: ' .. tostring(donors)
    end
    for _, m in ipairs(ms) do
      for _, row in ipairs(m.ingredients or {}) do
        if row.short_by and not row.donors then row.donors = string.format('donors not read: the call searched those of its first %d short items', MAX_DONORS) end
        row.short_by = nil
      end
    end
    return skipped, unread
  end
  function M.read(p, a)
    assert(a.all == nil or type(a.all) == 'boolean', 'all must be true or false')
    assert(a.skip == nil or type(a.skip) == 'number' and a.skip >= 0 and a.skip == math.floor(a.skip), 'skip is a whole number of machines, 0 or more')
    assert(a.skip == nil or a.area ~= nil, 'skip goes with area')
    local list, left = {}, nil
    if a.area ~= nil then
      local lt, rb = api.position(a.area.left_top), api.position(a.area.right_bottom)
      assert(rb.x - lt.x <= 128 and rb.y - lt.y <= 128 and rb.x > lt.x and rb.y > lt.y, 'area is {left_top, right_bottom}, at most 128x128')
      for _, e in ipairs(p.surface.find_entities_filtered{area={lt, rb}, force=p.force, type={'assembling-machine', 'furnace', 'rocket-silo'}}) do
        if e.valid and api.seen(p, e.position) then list[#list+1] = e end
      end
    else
      local ps = a.positions or (a.position ~= nil and {a.position}) or nil
      assert(ps and #ps >= 1 and #ps <= MAX, 'give position, positions (1..' .. MAX .. ') or area')
      for k, q in ipairs(ps) do
        if k > PER then left = left or {}; left[#left+1] = q
        else
          local e = api.entity(p, {position=q})
          assert(e and CRAFTERS[e.type], string.format('%s at %s is no crafting machine', e and e.name or 'nothing', at(api.position(q))))
          list[#list+1] = e
        end
      end
    end
    -- (d19 batch45) positions read once: a sort reading them in its comparison was 1.5 ms for 204 machines
    local keyed = {}
    for i, e in ipairs(list) do local q = e.position; keyed[i] = {e=e, x=q.x, y=q.y} end
    table.sort(keyed, function(u, v) return u.y < v.y or u.y == v.y and u.x < v.x end)
    for i, k in ipairs(keyed) do list[i] = k.e end
    local from = (a.skip or 0) + 1
    local to = math.min(#list, from + PER - 1)
    local n = math.max(0, to - from + 1)
    local ms, rows, lines, nshort = {}, {}, {}, 0
    for i = from, to do
      local m, short = M.machine(p, list[i])
      if short then nshort = nshort + 1 end
      if short or a.all or a.area == nil then ms[#ms+1] = m end
    end
    local skipped, unread = M.donors(p, ms)
    for _, m in ipairs(ms) do
      if type(m.line) == 'function' then m.line = m.line() end
      -- (d19 batch45: 32 machines' rows were 20 KB, 6 ms to encode) with all, a machine short of nothing gives its line
      if a.area ~= nil and a.all and not m.short_of then m.ingredients = nil end
      m.short_of = nil
      rows[#rows+1] = m; lines[#lines+1] = m.line
    end
    local none = from > #list and #list > 0 and string.format('%d machines there; skip %d passes over them all', #list, from - 1)
      or 'no machine there is short of an ingredient for its next craft'
    return {machines=rows, lines=#lines > 0 and lines or {none}, read=n, short=nshort,
      left=left and {positions=left, note=string.format('%d positions not read (%d a call): pass them as positions', #left, PER)} or nil,
      donors_skipped=skipped > 0 and string.format('%d short items past the first %d: their donors not read in this call', skipped, MAX_DONORS) or nil,
      ground_note=unread and 'stacks on the ground not read: the ground watch has not binned them on ' .. p.surface.name .. ' yet' or nil,
      more=#list > to and string.format('%d machines there; %d-%d read (top to bottom, then left to right); skip: %d reads the next', #list, from, to, to) or nil}
  end
  M.schema = {ingredient_gap={surface='optional planet, surface or platform name (default yours): the machines at position, positions or area there, in chunks our force sees now there by remote view (d20 batch62 X4)',position='{x,y} of a crafting machine (assembler, furnace, biochamber, silo ...)', positions='or 1..32 of them (16 a call; left: the rest)', area='or {left_top, right_bottom} up to 128x128: the machines there short of an ingredient (all: true: every one), 16 a call', all='with area: optional true',
    skip='with area: optional, machines to pass over (more says how many there are)',
    returns='machines [{position, name, recipe, status, ingredients [{item | fluid, needed (one craft), held, spoil_5min, usable, short, donors}], line}]: per ingredient of the next craft, held in its input, how many of those spoil within 5 min, usable, short; for a short item the places within 64 tiles of the machine that can spare it (a requester or buffer chest only over its own request, robots\' reservations off), with how many, else the logistic networks holding it (stacks on the ground as the ground watch\'s last pass binned them, every 30 s; ground_note when not read); donors for the first 8 short items a call (donors_skipped: how many more); with area and all, a machine short of nothing has its line and no ingredients; lines; read, short; more (area: machines past this call); left (positions not read). Read only'}}
  return M
end
