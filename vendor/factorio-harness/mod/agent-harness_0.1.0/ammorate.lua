-- Ammunition use at full fire (d20 batch60 V1, Sol #1470: an outer-ship supply design needed rounds a minute and damage
-- a shot for each weapon at the research done; platform_defense gave damage a second only). Per turret and ammunition,
-- as the turret's tooltip and the technology screen give them: a shot every cooldown ticks (the turret's, times the
-- ammunition's cooldown modifier, over 1 + the force's shooting speed bonus for the ammunition's category); rounds a
-- shot (the turret's ammo consumption modifier times the ammunition's) against the rounds a magazine holds (its
-- magazine size), so items a minute; damage a shot: the ammunition's damage times its quality's multiplier, times
-- 1 + the force's damage bonus for its category, times 1 + the force's attack bonus for that turret, times the
-- turret's damage modifier; and the technologies each bonus comes from (levels researched), with any part of it not from
-- research. Read on the private copy (2.0.77), one target kept alive in reach: gun-turret 25.0 shots/s (6 ticks over
-- 1 + 150%), rocket-turret one in 27.33 ticks (120 over 1 + 340%: 27.27), railgun-turret one in 171 (170); damage
-- 18.75 a shot from firearm-magazine against a behemoth worm (5 x 2.4 x 2.4 = 28.8, less its 10 flat), 61.9 from a
-- legendary one (x 2.5); the turret's quality changed neither its shots nor its damage (normal against legendary,
-- each turret). Electric and fluid turrets use no ammunition items and are left out.
return function(api)
  local M = {}
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local EFFECTS = {['gun-speed']=true, ['ammo-damage']=true, ['turret-attack']=true}
  -- The technologies whose effects are these bonuses, read from the prototypes once (every technology of the force
  -- read with its effects took 12.7 ms on the private copy; the ones with these effects are a few dozen).
  local index
  local function techs()
    if index then return index end
    index = {}
    for name, pt in pairs(prototypes.technology) do
      for _, e in ipairs(try(function() return pt.effects end) or {}) do
        if EFFECTS[e.type] and (e.ammo_category or e.turret_id) then
          index[name] = index[name] or {}
          table.insert(index[name], {type=e.type, key=e.ammo_category or e.turret_id, modifier=e.modifier or 0})
        end
      end
    end
    return index
  end
  -- Levels of a technology the force has researched: one with a single level 1 or 0; an infinite one (max_level past its
  -- level) from its first level to the one before the level it is on, that one too once researched.
  function M.levels(t, pt)
    local lv, max = pt.level or 1, pt.max_level or pt.level or 1
    if max > lv then return math.max(0, (t.level or lv) - lv + (t.researched and 1 or 0)) end
    return t.researched and 1 or 0
  end
  -- {['gun-speed:bullet'] = {sum, by = {base name: {levels..., mod}}}, ...} for the force.
  function M.sources(force)
    local out = {}
    for name, effs in pairs(techs()) do
      local t = try(function() return force.technologies[name] end)
      local pt = t and try(function() return t.prototype end)
      local n = pt and M.levels(t, pt) or 0
      if n > 0 then
        local base = (name:gsub('%-%d+$', ''))
        for _, e in ipairs(effs) do
          local k = e.type .. ':' .. e.key
          local s = out[k] or {sum=0, by={}}
          out[k] = s
          s.sum = s.sum + e.modifier * n
          local b = s.by[base] or {mod=0}
          s.by[base] = b
          for l = (pt.level or 1), (pt.level or 1) + n - 1 do b[#b+1] = l end
          b.mod = b.mod + e.modifier * n
        end
      end
    end
    return out
  end
  local function ranges(list)
    table.sort(list)
    local parts, i = {}, 1
    while i <= #list do
      local j = i
      while j < #list and list[j + 1] == list[j] + 1 do j = j + 1 end
      parts[#parts+1] = i == j and tostring(list[i]) or (list[i] .. '-' .. list[j])
      i = j + 1
    end
    return table.concat(parts, ',')
  end
  local function pct(x) return string.format('%+g%%', math.floor(x * 1000 + 0.5) / 10) end
  M.pct = pct
  -- The technologies a bonus comes from: "weapon-shooting-speed 1-6 (+150%)", and what is not from research.
  function M.source_text(src, k, value)
    local s = src[k]
    local parts = {}
    if s then
      local names = {}
      for n in pairs(s.by) do names[#names+1] = n end
      table.sort(names)
      for _, n in ipairs(names) do parts[#parts+1] = string.format('%s %s (%s)', n, ranges(s.by[n]), pct(s.by[n].mod)) end
    end
    local other = (value or 0) - (s and s.sum or 0)
    if math.abs(other) > 1e-6 then parts[#parts+1] = pct(other) .. ' not from research' end
    return #parts > 0 and table.concat(parts, ', ') or 'none researched'
  end
  local function num(v)
    if v >= 100 then return string.format('%d', math.floor(v + 0.5)) end
    if v >= 10 then return string.format('%g', math.floor(v * 10 + 0.5) / 10) end
    return string.format('%.3g', v)
  end
  M.num = num
  -- One turret and ammunition: g = {turret, quality, turrets, ammo, ammo_quality, where}; damages(action, out, flag)
  -- collects an ammunition's damage entries (platdefense's, its projectile's attack_result too).
  function M.row(force, g, src, damages)
    local tp = prototypes.entity[g.turret]
    local ap = tp and try(function() return tp.attack_parameters end) or {}
    local ip = prototypes.item[g.ammo]
    local cat = ip and try(function() return ip.ammo_category.name end)
    local at = ip and (try(function() return ip.get_ammo_type('turret') end) or try(function() return ip.get_ammo_type() end)) or {}
    local cdm = type(at.cooldown_modifier) == 'number' and at.cooldown_modifier or 1
    local csm = type(at.consumption_modifier) == 'number' and at.consumption_modifier or 1
    local base = (ap.cooldown or 60) * cdm
    local speed = cat and try(function() return force.get_gun_speed_modifier(cat) end) or 0
    local cd = base / (1 + speed)
    local spm = 3600 / cd
    local rounds = (ap.ammo_consumption_modifier or 1) * csm
    local mag = ip and ip.magazine_size or 1
    local per_min = spm * rounds / mag
    local qm = try(function() return prototypes.quality[g.ammo_quality or 'normal'].default_multiplier end) or 1
    local bonus = cat and try(function() return force.get_ammo_damage_modifier(cat) end) or 0
    local attack = try(function() return force.get_turret_attack_modifier(g.turret) end) or 0
    local dm = ap.damage_modifier or 1
    local parts, from_data = {}, {}
    if damages then damages(at.action, parts, from_data) end
    local by, order, listed = {}, {}, 0
    for _, d in ipairs(parts) do
      local v = d.amount * qm * (1 + bonus) * (1 + attack) * dm
      if not by[d.type] then order[#order+1] = d.type; by[d.type] = 0 end
      by[d.type] = by[d.type] + v
      listed = listed + v
    end
    local words = {}
    for _, k in ipairs(order) do words[#words+1] = num(by[k]) .. ' ' .. tostring(k) end
    local base_dmg = 0
    for _, d in ipairs(parts) do base_dmg = base_dmg + d.amount end
    local srcs = {shooting_speed=M.source_text(src, 'gun-speed:' .. tostring(cat), speed), damage=M.source_text(src, 'ammo-damage:' .. tostring(cat), bonus),
      turret_attack=M.source_text(src, 'turret-attack:' .. g.turret, attack)}
    local n = g.turrets or 1
    local row = {turret=g.turret, quality=g.quality, turrets=n, ammo=g.ammo, ammo_quality=g.ammo_quality or 'normal', where=g.where, category=cat,
      cooldown_ticks=math.floor(cd * 1000 + 0.5) / 1000, base_cooldown_ticks=base, shooting_speed_bonus=speed, shots_per_min=math.floor(spm * 10 + 0.5) / 10,
      rounds_per_shot=rounds, magazine_size=mag, items_per_shot=rounds / mag, items_per_min=math.floor(per_min * 100 + 0.5) / 100,
      items_per_min_all=math.floor(per_min * n * 100 + 0.5) / 100, damage_per_shot=math.floor(listed * 100 + 0.5) / 100, damage=by,
      damage_bonus=bonus, turret_attack_bonus=attack, quality_multiplier=qm, damage_modifier=dm ~= 1 and dm or nil, sources=srcs,
      from_data=from_data[1] or nil}
    row.line = string.format('%s (%s) x%d with %s (%s)%s: a shot every %s ticks (%s%s over 1 %s shooting speed), %s shots/min; %s round%s a shot, %d round%s an item: %s items/min each%s; %s a shot (%s base%s x (1 %s damage) x (1 %s %s attack)%s)%s; shooting speed: %s; damage: %s; %s attack: %s',
      g.turret, g.quality or 'normal', n, g.ammo, row.ammo_quality, g.where == 'hub' and ' (in the hub, not in these turrets)' or '',
      num(cd), num(ap.cooldown or 60), cdm ~= 1 and (' x ' .. num(cdm)) or '', pct(speed), num(spm), num(rounds), rounds == 1 and '' or 's', mag, mag == 1 and '' or 's',
      num(per_min), n > 1 and string.format(', %s/min for the %d', num(per_min * n), n) or '',
      #words > 0 and table.concat(words, ' + ') or 'no damage read', num(base_dmg), qm ~= 1 and (' x ' .. num(qm) .. ' quality') or '', pct(bonus), pct(attack), g.turret,
      dm ~= 1 and (' x ' .. num(dm)) or '', from_data[1] and ' (the rocket\'s damage from the base game\'s data)' or '',
      srcs.shooting_speed, srcs.damage, g.turret, srcs.turret_attack)
    return row
  end
  -- Rows for the ammo turrets given: each ammunition they hold (by turret, turret quality, ammunition, its quality) and
  -- each one of their categories in the hub (hub: {name, quality, count} rows) that none of that kind holds; all: every
  -- ammo turret prototype with every ammunition of its categories, normal quality.
  function M.rows(force, turrets, hub, damages, all)
    local src = M.sources(force)
    local groups, order, kinds = {}, {}, {}
    local function add(t, tq, ammo, aq, where)
      local k = t .. '|' .. tq .. '|' .. ammo .. '|' .. aq
      local g = groups[k]
      if not g then g = {turret=t, quality=tq, ammo=ammo, ammo_quality=aq, where=where, turrets=0}; groups[k] = g; order[#order+1] = g end
      return g
    end
    for _, t in ipairs(turrets or {}) do
      local e = type(t) == 'table' and t.entity or t
      if e.valid and e.type == 'ammo-turret' then
        local tq = try(function() return e.quality.name end) or 'normal'
        local kk = e.name .. '|' .. tq
        kinds[kk] = kinds[kk] or {turret=e.name, quality=tq, n=0}
        kinds[kk].n = kinds[kk].n + 1
        local inv = try(function() return e.get_inventory(defines.inventory.turret_ammo) end)
        local seen = {}
        for _, c in ipairs(inv and try(function() return inv.get_contents() end) or {}) do
          local aq = type(c.quality) == 'table' and c.quality.name or c.quality or 'normal'
          local g = add(e.name, tq, c.name, aq, 'held')
          if not seen[g] then seen[g] = true; g.turrets = g.turrets + 1 end
        end
      end
    end
    local kind_list = {}
    for _, k in pairs(kinds) do kind_list[#kind_list+1] = k end
    table.sort(kind_list, function(a, b) return a.turret .. a.quality < b.turret .. b.quality end)
    local bare = {}
    for _, k in ipairs(kind_list) do
      local cats = {}
      for _, c in ipairs(try(function() return prototypes.entity[k.turret].attack_parameters.ammo_categories end) or {}) do cats[c] = true end
      local any = false
      for _, g in ipairs(order) do if g.turret == k.turret and g.quality == k.quality then any = true end end
      for _, r in ipairs(hub or {}) do
        local cat = try(function() return prototypes.item[r.name].ammo_category.name end)
        local aq = type(r.quality) == 'table' and r.quality.name or r.quality or 'normal'
        if cat and cats[cat] and not groups[k.turret .. '|' .. k.quality .. '|' .. r.name .. '|' .. aq] then
          local g = add(k.turret, k.quality, r.name, aq, 'hub'); g.turrets = k.n; any = true
        end
      end
      if not any then bare[#bare+1] = string.format('%s (%s) x%d: no ammunition held or in the hub', k.turret, k.quality, k.n) end
    end
    if all then
      for name, tp in pairs(prototypes.get_entity_filtered{{filter='type', type='ammo-turret'}}) do
        local cats = {}
        for _, c in ipairs(try(function() return tp.attack_parameters.ammo_categories end) or {}) do cats[c] = true end
        for iname, ip in pairs(prototypes.get_item_filtered{{filter='type', type='ammo'}}) do
          local cat = try(function() return ip.ammo_category.name end)
          if cat and cats[cat] and not groups[name .. '|normal|' .. iname .. '|normal'] then
            local g = add(name, 'normal', iname, 'normal', 'any'); g.turrets = 1
          end
        end
      end
    end
    table.sort(order, function(a, b)
      if a.turret ~= b.turret then return a.turret < b.turret end
      if a.quality ~= b.quality then return a.quality < b.quality end
      if a.ammo ~= b.ammo then return a.ammo < b.ammo end
      return a.ammo_quality < b.ammo_quality
    end)
    local rows, lines = {}, {}
    for _, g in ipairs(order) do
      local r = M.row(force, g, src, damages)
      rows[#rows+1] = r; lines[#lines+1] = r.line
    end
    for _, l in ipairs(bare) do lines[#lines+1] = l end
    return rows, lines
  end
  M.NOTE = 'at full fire: one turret shooting while a target stays in its reach; turning to a new target, and rockets in flight at a target that dies, take more time and ammunition (the private copy: a rocket turret 2.05 shots/s against 2.2 across 16 worms, and 92 rockets for 13 kills that 78 would make by damage); the turret\'s quality changes neither (measured); ammunition quality multiplies its damage by the quality\'s multiplier (uncommon 1.3, rare 1.6, epic 1.9, legendary 2.5), not its rate; damage is before the target\'s resistances (damage on the route reads those); electric and fluid turrets use no ammunition items'
  return M
end
