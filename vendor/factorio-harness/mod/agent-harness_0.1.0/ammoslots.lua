-- ammoslots: the character's gun and ammo slots, one per slot (Grok, shift19 00:36: a big spitter ate belts while a
-- pistol stood in gun slot 1 and 75 piercing rounds in ammo slot 2; shoot said no_compatible_ammo, equip {slot: ammo}
-- said "item is not in inventory", and inventory's ammo line had no slot numbers). In the game gun slot N fires only
-- from ammo slot N; an ammo stack fits a gun whose ammo categories hold the ammo's category.
return function()
  local M = {}
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function quality(s) local q = try(function() return s.quality end); if type(q) == 'table' or type(q) == 'userdata' then q = q.name end; return q ~= 'normal' and q or nil end
  local function stack(s)
    if not (s and try(function() return s.valid_for_read end)) then return false end
    return {name=s.name, count=s.count, quality=quality(s)}
  end
  -- {guns={[i]=stack|false}, ammo={[i]=stack|false}, n}
  function M.read(p)
    local guns = try(function() return p.get_inventory(defines.inventory.character_guns) end)
    local ammo = try(function() return p.get_inventory(defines.inventory.character_ammo) end)
    local n = math.max(guns and #guns or 0, ammo and #ammo or 0)
    local out = {guns={}, ammo={}, n=n}
    for i = 1, n do
      out.guns[i] = guns and i <= #guns and stack(guns[i]) or false
      out.ammo[i] = ammo and i <= #ammo and stack(ammo[i]) or false
    end
    return out, guns, ammo
  end
  local function name_q(s) return s.name .. (s.quality and '@' .. s.quality or '') end
  -- "1 pistol, 2 empty, 3 empty" and "1 empty, 2 piercing-rounds-magazine*75, 3 empty".
  function M.lines(r)
    local g, a = {}, {}
    for i = 1, r.n do
      g[i] = i .. ' ' .. (r.guns[i] and name_q(r.guns[i]) or 'empty')
      a[i] = i .. ' ' .. (r.ammo[i] and name_q(r.ammo[i]) .. '*' .. r.ammo[i].count or 'empty')
    end
    return table.concat(g, ', '), table.concat(a, ', ')
  end
  function M.category(name)
    local c = try(function() return prototypes.item[name].ammo_category end)
    return type(c) == 'string' and c or (c and try(function() return c.name end))
  end
  function M.fits(gun, ammo)
    local ap = try(function() return prototypes.item[gun].attack_parameters end)
    local cat = M.category(ammo)
    if not ap or not cat then return false end
    for _, c in ipairs(try(function() return ap.ammo_categories end) or {}) do if c == cat then return true end end
    return try(function() return ap.ammo_category end) == cat
  end
  -- Compatible ammo in the other ammo slots for the gun in gun slot i: "piercing-rounds-magazine*75 in ammo slot 2
  -- fits pistol (gun slot 1 fires only from ammo slot 1; ammo slot 2 is fired by gun slot 2: empty)"; nil when none.
  function M.elsewhere(r, i)
    local gun = r.guns[i]
    if not gun then return nil end
    local parts = {}
    for j = 1, r.n do
      local s = r.ammo[j]
      if j ~= i and s and M.fits(gun.name, s.name) then
        parts[#parts+1] = string.format('%s*%d in ammo slot %d fits %s (gun slot %d fires only from ammo slot %d; ammo slot %d is fired by gun slot %d: %s)',
          name_q(s), s.count, j, gun.name, i, i, j, j, r.guns[j] and name_q(r.guns[j]) or 'empty')
      end
    end
    return #parts > 0 and table.concat(parts, '; ') or nil
  end
  -- Ammo in an ammo slot that no gun beside it fires, with the gun slots whose gun it fits: one line per such slot.
  function M.idle_ammo(r)
    local out = {}
    for j = 1, r.n do
      local s = r.ammo[j]
      if s and not (r.guns[j] and M.fits(r.guns[j].name, s.name)) then
        local fits = {}
        for i = 1, r.n do if r.guns[i] and M.fits(r.guns[i].name, s.name) then fits[#fits+1] = string.format('gun slot %d %s', i, r.guns[i].name) end end
        out[#out+1] = string.format('ammo slot %d %s*%d: gun slot %d %s%s', j, name_q(s), s.count, j,
          r.guns[j] and (name_q(r.guns[j]) .. ' does not fire it') or 'is empty',
          #fits > 0 and '; it fits ' .. table.concat(fits, ', ') .. ', which fires only from its own ammo slot' or '')
      end
    end
    return #out > 0 and out or nil
  end
  -- Move an ammo stack between ammo slots (equip {slot: ammo} with the item only in the ammo slots): from the first
  -- slot holding item (other than to) into slot to, swapping what to holds. Returns {from, to, swapped} or nil, why.
  function M.move(p, item, to)
    local r, _, ammo = M.read(p)
    if not ammo then return nil, 'no ammo slots' end
    local from
    for j = 1, r.n do if j ~= to and r.ammo[j] and r.ammo[j].name == item then from = j; break end end
    if not from then return nil, 'not in another ammo slot' end
    local held = r.ammo[to]
    if not ammo[to].swap_stack(ammo[from]) then return nil, string.format('the game refused swapping ammo slots %d and %d', from, to) end
    return {from=from, to=to, swapped=held and name_q(held) .. '*' .. held.count or nil}
  end
  return M
end
