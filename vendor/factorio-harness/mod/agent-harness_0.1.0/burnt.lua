-- A burner stopped by its full burnt-result slot (Sol, shift14 03:54: two agricultural science biochambers on Gleba
-- read working through repeated checks and made nothing; each held spoilage*200 in its burnt-result slot and spoilage
-- in its one fuel slot). 2.0.77 on a copy of world n's save from then: nutrients that spoil in a biochamber's fuel slot
-- go to its burnt-result slot (one slot, spoilage stacks to 200); with that slot full the spoilage stays in the fuel
-- slot, which a biochamber does not burn (spoilage is chemical fuel, it burns nutrients); nothing burns (energy 0) and
-- crafting stops while the status reads working: the two kept crafting progress 0.890 and 0.625 over 20 s while a
-- chamber beside them made 15 packs. Any burner whose burnt-result slots are full and that burns nothing counts (a
-- nuclear reactor's spent cells too).
-- The factory is pure so the same module can be bundled into a hot reload.
return function(api)
  local M = {}
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  M.STATE = 'burnt_result_full'
  -- 'spoilage*200 nutrients@rare*3', in slot order.
  local function contents(inv)
    local by, order = {}, {}
    for i = 1, #inv do
      local st = inv[i]
      if st.valid_for_read then
        local q = st.quality and st.quality.name or 'normal'
        local k = st.name .. (q ~= 'normal' and '@' .. q or '')
        if not by[k] then by[k] = 0; order[#order+1] = k end
        by[k] = by[k] + st.count
      end
    end
    local parts = {}
    for _, k in ipairs(order) do parts[#parts+1] = k .. '*' .. by[k] end
    return table.concat(parts, ' ')
  end
  -- Every burnt-result slot holds a full stack: (true, inventory); else false.
  local function full(b)
    local inv = b.burnt_result_inventory
    if not inv or #inv == 0 then return false end
    for i = 1, #inv do
      local st = inv[i]
      if not st.valid_for_read or st.count < st.prototype.stack_size then return false end
    end
    return true, inv
  end
  -- e's burner with its burnt-result slots full: {burnt, fuel, foreign (fuel-slot items it does not burn), burns (its
  -- fuel categories), burning (it still burns something)}, or nil.
  function M.full(e)
    local b = try(function() return e.burner end)
    if not b then return nil end
    local ok, inv = full(b)
    if not ok then return nil end
    local out = {burnt=contents(inv), burning=(b.remaining_burning_fuel or 0) > 0}
    local fuel = b.inventory
    out.fuel = fuel and contents(fuel) or ''
    local cats = try(function() return b.fuel_categories end) or {}
    local names = {}
    for c in pairs(cats) do names[#names+1] = c end
    table.sort(names)
    out.burns = table.concat(names, ', ')
    local foreign = {}
    for i = 1, fuel and #fuel or 0 do
      local st = fuel[i]
      if st.valid_for_read then
        local c = try(function() return st.prototype.fuel_category end)
        if not (c and cats[c]) then foreign[#foreign+1] = st.name end
      end
    end
    out.foreign = #foreign > 0 and table.concat(foreign, ', ') or nil
    return out
  end
  -- Stopped: its burnt-result slots full and nothing burning. The full read, or nil.
  function M.stuck(e)
    local f = M.full(e)
    if f and not f.burning then return f end
    return nil
  end
  -- One line for inspect and the supply rows: what fills the slot and what it does.
  function M.line(e, f, engine_status)
    f = f or M.full(e)
    if not f then return nil end
    local text = 'its burnt-result slot is full (' .. f.burnt .. ')'
    if f.foreign then
      text = text .. string.format('; its fuel slot holds %s, which it does not burn (it burns %s)', f.fuel, f.burns)
    elseif f.fuel ~= '' then
      text = text .. '; its fuel slot holds ' .. f.fuel
    end
    if f.burning then return text .. ': it burns nothing more once the fuel burning now runs out' end
    text = text .. ': nothing burns, it has no energy'
    if engine_status and engine_status ~= 'no_fuel' then text = text .. ' (the game\'s status reads ' .. engine_status .. ')' end
    return text
  end
  return M
end
