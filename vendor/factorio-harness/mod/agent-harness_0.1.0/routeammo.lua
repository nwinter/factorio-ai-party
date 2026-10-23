-- platform_endurance {platform, route, forecast: true, pessimistic?} (E11, Astra 19:50: "cannot yet justify the Aquilo
-- leg"): per leg of the route, the asteroids its space connection spawns by kind (the game's spawn chance, its mean over
-- the leg), what one of each takes of each ammunition aboard (its health against the ammunition's damage after the
-- asteroid's resistances and our damage bonuses; none when the damage cannot hurt it), and the ammunition the leg uses:
-- the moving rate measured on the legs this platform flew lately (B3), scaled by how much more shooting this leg's
-- asteroids take than theirs; with what is made aboard meanwhile and what is left at each arrival. pessimistic {speed
-- 0.1..1 (a share of the speed read), dwell_s 0..36000 (extra time at each stop, at the stopped rate)}. An estimate from
-- prototypes and measured rates; the engine's own spawning is not simulated.
-- (d20 batch51 H1, viewer Aurora 09:36) What is made on the way is endurance's (ammomodel.lua): at most what the
-- ingredients aboard allow over the trip so far, an ingredient shared between products split by their rates; what
-- rockets on their way up bring counts at the start; each ammunition's last line says which limit binds.
return function(api)
  local M = {}
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function round(x) return math.floor(x + 0.5) end
  local function mins(m)
    if not m then return '?' end
    if m >= 60 then return string.format('%dh%02dm', math.floor(m / 60), math.floor(m % 60)) end
    return string.format('%dm%02ds', math.floor(m), math.floor((m % 1) * 60))
  end
  local function connection(a, b)
    for _, c in pairs(try(function() return prototypes.space_connection end) or {}) do
      local f, t = try(function() return c.from.name end), try(function() return c.to.name end)
      if (f == a and t == b) or (f == b and t == a) then return c end
    end
  end
  -- Mean spawn chance over the leg (0..1 of its length) of each asteroid entity it spawns.
  function M.density(a, b)
    local c = connection(a, b)
    if not c then return nil end
    local out = {}
    for _, d in ipairs(try(function() return c.asteroid_spawn_definitions end) or {}) do
      if d.type == 'entity' or d.type == nil then
        local pts = d.spawn_points or {}
        local sum = 0
        for i = 2, #pts do
          local x0, x1 = pts[i - 1].distance or 0, pts[i].distance or 0
          sum = sum + (x1 - x0) * ((pts[i - 1].probability or 0) + (pts[i].probability or 0)) / 2
        end
        local name = type(d.asteroid) == 'string' and d.asteroid or try(function() return d.asteroid.name end)
        if name and sum > 0 then out[name] = (out[name] or 0) + sum end
      end
    end
    return out
  end
  -- (d22 batch105 BO1, Astra #1927: Asterion flew the first 15% and 25% of its outer legs, and the forecast took each as
  -- the whole connection, "x1.00") the mean spawn chance of each asteroid entity over a part of the leg a->b, f0..f1
  -- (0..1, the way it is flown). The connection's spawn points are by distance from its own `from` (0..1): a leg flown
  -- the other way reads them from 1. The curve between points is linear, as M.density takes it; outside them, none.
  local function curve_mean(pts, x0, x1)
    if x1 - x0 < 1e-9 then
      for i = 2, #pts do
        local d0, d1 = pts[i - 1].distance or 0, pts[i].distance or 0
        if x0 >= d0 and x0 <= d1 and d1 > d0 then
          local p0, p1 = pts[i - 1].probability or 0, pts[i].probability or 0
          return p0 + (p1 - p0) * (x0 - d0) / (d1 - d0)
        end
      end
      return 0
    end
    local sum = 0
    for i = 2, #pts do
      local d0, d1 = pts[i - 1].distance or 0, pts[i].distance or 0
      local a, b = math.max(d0, x0), math.min(d1, x1)
      if b > a and d1 > d0 then
        local p0, p1 = pts[i - 1].probability or 0, pts[i].probability or 0
        local pa, pb = p0 + (p1 - p0) * (a - d0) / (d1 - d0), p0 + (p1 - p0) * (b - d0) / (d1 - d0)
        sum = sum + (b - a) * (pa + pb) / 2
      end
    end
    return sum / (x1 - x0)
  end
  function M.density_range(a, b, f0, f1)
    local c = connection(a, b)
    if not c then return nil end
    local x0, x1 = math.max(0, math.min(1, f0)), math.max(0, math.min(1, f1))
    if try(function() return c.from.name end) ~= a then x0, x1 = 1 - x1, 1 - x0 end
    if x1 < x0 then x0, x1 = x1, x0 end
    local out = {}
    for _, d in ipairs(try(function() return c.asteroid_spawn_definitions end) or {}) do
      if d.type == 'entity' or d.type == nil then
        local v = curve_mean(d.spawn_points or {}, x0, x1)
        local name = type(d.asteroid) == 'string' and d.asteroid or try(function() return d.asteroid.name end)
        if name and v > 0 then out[name] = (out[name] or 0) + v end
      end
    end
    return out
  end
  -- The parts of a leg as text: {{f0, f1}, ...} -> '0-15%, 0-25%'.
  local function share_pct(x) return math.floor(x * 100 + 0.5) end
  local function ranges_text(list)
    local parts = {}
    for _, r in ipairs(list) do parts[#parts+1] = string.format('%d-%d%%', share_pct(r[1]), share_pct(r[2])) end
    return table.concat(parts, ', ')
  end
  -- The parts joined where they meet or overlap, in order, and the share of 0..1 they cover together.
  local function merged(list)
    local sorted = {}
    for _, r in ipairs(list) do sorted[#sorted+1] = {math.min(r[1], r[2]), math.max(r[1], r[2])} end
    table.sort(sorted, function(x, y) return x[1] < y[1] end)
    local out = {}
    for _, r in ipairs(sorted) do
      local last = out[#out]
      if last and r[1] <= last[2] then last[2] = math.max(last[2], r[2]) else out[#out+1] = {r[1], r[2]} end
    end
    return out
  end
  local function covered(list)
    local total = 0
    for _, r in ipairs(merged(list)) do total = total + (r[2] - r[1]) end
    return total
  end
  -- The damage entries anywhere in a trigger (nested deliveries and area actions too).
  local function damages_in(t, parts, depth)
    if type(t) ~= 'table' or depth > 12 then return end
    if t.type == 'damage' and type(t.damage) == 'table' and t.damage.amount then parts[#parts+1] = {amount=t.damage.amount, type=t.damage.type}; return end
    for _, v in pairs(t) do damages_in(v, parts, depth + 1) end
  end
  M.damages_in = damages_in
  -- An ammunition's damage per shot by type, and its category; nil when none is read. (d20 batch52 K5, Sol #930:
  -- Swiftlet's rockets read "?" a big asteroid) A projectile's damage (rockets) is its prototype's attack_result, which
  -- 2.0.77 gives at runtime: rocket 200 explosion, explosive-rocket 50 explosion (read on the private copy).
  local function damage_of(ammo)
    local at = try(function() return prototypes.item[ammo].get_ammo_type() end)
    if not at then return nil end
    local parts, projectile = {}, false
    local function walk(effects)
      for _, e in ipairs(effects or {}) do
        if e.type == 'damage' and e.damage then parts[#parts+1] = {amount=e.damage.amount or 0, type=e.damage.type} end
      end
    end
    for _, act in ipairs(at.action or {}) do
      for _, del in ipairs(act.action_delivery or {}) do
        if del.type == 'projectile' or del.type == 'stream' then projectile = true end
        walk(del.target_effects)
        local pp = del.projectile and prototypes.entity[del.projectile]
        if pp then
          damages_in(try(function() return pp.attack_result end), parts, 0)
          damages_in(try(function() return pp.final_attack_result end), parts, 0)
        end
      end
    end
    if #parts == 0 then return nil, at.category, projectile end
    return parts, at.category, projectile
  end
  -- (d22 batch88 AX1, Astra #1876: rockets read 3 shots a 400 hp asteroid where platform_defense ammo_use gave 1160
  -- explosion a shot and a measured drill used 160 rockets for 160 kills) 2.0.77 keeps an ammunition's category on its
  -- item prototype (ammo_category); get_ammo_type().category reads nil there (read on a private copy of world n), so
  -- the damage bonus and the turret were never found. The ammo type's own field stays a fallback.
  local function category(ammo)
    local ip = prototypes.item[ammo]
    return ip and (try(function() return ip.ammo_category.name end) or try(function() local c = ip.ammo_category; return type(c) == 'string' and c or nil end)
      or try(function() return ip.get_ammo_type().category end))
  end
  M.category = category
  -- One shot of an ammunition as platform_defense ammo_use gives it (ammorate.row with platdefense's damage reader, when
  -- the runtime passes them): {by {type: amount}, order, base {type: amount}, qm, bonus, attack, dm, from_data, total};
  -- the ammunition's damage x its quality's multiplier x (1 + the force's damage bonus for its category) x (1 + the
  -- force's attack bonus for the turret) x the turret's damage modifier. nil when no damage is read.
  local hits = {}
  function M.hit(ammo, quality, force, turret)
    quality = quality or 'normal'
    local key = ammo .. '|' .. quality .. '|' .. tostring(turret)
    if hits[key] ~= nil then return hits[key] or nil end
    local base, order, from_data = {}, {}, {}
    if api.damages then
      local list = {}
      local ip = prototypes.item[ammo]
      local at = ip and (try(function() return ip.get_ammo_type('turret') end) or try(function() return ip.get_ammo_type() end))
      api.damages(at and at.action, list, from_data)
      for _, d in ipairs(list) do if not base[d.type] then order[#order+1] = d.type; base[d.type] = 0 end; base[d.type] = base[d.type] + d.amount end
    else
      for _, d in ipairs(damage_of(ammo) or {}) do if not base[d.type] then order[#order+1] = d.type; base[d.type] = 0 end; base[d.type] = base[d.type] + d.amount end
    end
    if #order == 0 then hits[key] = false; return nil end
    local h = {base=base, order=order, from_data=from_data[1]}
    if api.ammorate and api.damages then
      local r = api.ammorate.row(force, {turret=turret or '', quality='normal', ammo=ammo, ammo_quality=quality}, {}, api.damages)
      h.by, h.qm, h.bonus, h.attack, h.dm, h.total = r.damage, r.quality_multiplier, r.damage_bonus, r.turret_attack_bonus, r.damage_modifier or 1, r.damage_per_shot
    else
      local cat = category(ammo)
      h.qm = try(function() return prototypes.quality[quality].default_multiplier end) or 1
      h.bonus = cat and try(function() return force.get_ammo_damage_modifier(cat) end) or 0
      h.attack = turret and try(function() return force.get_turret_attack_modifier(turret) end) or 0
      h.dm = turret and try(function() return prototypes.entity[turret].attack_parameters.damage_modifier end) or 1
      h.by, h.total = {}, 0
      for _, k in ipairs(order) do h.by[k] = base[k] * h.qm * (1 + h.bonus) * (1 + h.attack) * h.dm; h.total = h.total + h.by[k] end
    end
    hits[key] = h
    return h
  end
  -- the game's rule for one damage entry against a resistance: past the flat decrease it takes the rest, else
  -- 1 / (2 + decrease - damage); then less the percent
  local function after(dmg, r)
    local dec, pct = r and r.decrease or 0, r and r.percent or 0
    return (dmg > dec and (dmg - dec) or 1 / (2 + dec - dmg)) * (1 - pct)
  end
  -- Shots of ammo one asteroid takes: a number; false when every hit does under 1 (it cannot hurt it); nil unknown.
  -- Second value: the damage a hit does to it after its resistances.
  function M.shots(kind, ammo, force, turret, quality)
    local e = prototypes.entity[kind]
    local hp = e and try(function() return e.get_max_health() end)
    local h = M.hit(ammo, quality, force, turret)
    if not (hp and h) then return nil end
    local res = try(function() return e.resistances end) or {}
    local per = 0
    for _, k in ipairs(h.order) do per = per + after(h.by[k], res[k]) end
    if per < 1 then return false, per end
    return math.ceil(hp / per), per
  end
  local function num(v)
    if v >= 100 then return string.format('%d', math.floor(v + 0.5)) end
    if v >= 10 then return string.format('%g', math.floor(v * 10 + 0.5) / 10) end
    if v >= 0.01 then return string.format('%.3g', v) end
    return string.format('%.2g', v)
  end
  local function pct(x) return string.format('%+g%%', math.floor(x * 1000 + 0.5) / 10) end
  -- The ammunition's line: "rocket (rocket-turret, normal): 1160 explosion a shot = 200 x (1 +480% rocket damage) x
  -- (1 +0% rocket-turret attack)".
  function M.hit_line(ammo, quality, force, turret)
    local h = M.hit(ammo, quality, force, turret)
    if not h then return string.format('%s: no damage read', ammo) end
    local by, base = {}, {}
    for _, k in ipairs(h.order) do by[#by+1] = num(h.by[k]) .. ' ' .. k; base[#base+1] = num(h.base[k]) .. ' ' .. k end
    return string.format('%s (%s, %s): %s a shot = %s%s x (1 %s %s damage) x (1 %s %s attack)%s%s', ammo, turret or 'no turret of ours fires it', quality or 'normal',
      table.concat(by, ' + '), table.concat(base, ' + '), h.qm ~= 1 and (' x ' .. num(h.qm) .. ' quality') or '', pct(h.bonus), tostring(category(ammo)), pct(h.attack),
      turret or 'turret', h.dm ~= 1 and (' x ' .. num(h.dm) .. ' turret') or '', h.from_data and ' (the rocket\'s damage from the base game\'s data)' or '')
  end
  -- One asteroid against it: "medium-metallic-asteroid 400 hp: explosion (1160 - 0 flat) x (1 - 30%) = 812 a hit: 1 shot".
  function M.vs_line(kind, ammo, quality, force, turret)
    local e = prototypes.entity[kind]
    local hp = e and try(function() return e.get_max_health() end)
    local h = M.hit(ammo, quality, force, turret)
    if not (hp and h) then return string.format('%s: not read', kind) end
    local res = try(function() return e.resistances end) or {}
    local parts, per = {}, 0
    for _, k in ipairs(h.order) do
      local r = res[k] or {}
      local dec, p = r.decrease or 0, r.percent or 0
      local v = after(h.by[k], r)
      per = per + v
      parts[#parts+1] = h.by[k] > dec and string.format('%s (%s - %s flat) x (1 - %s%%) = %s', k, num(h.by[k]), num(dec), num(p * 100), num(v))
        or string.format('%s %s is not over the %s flat: 1 / (2 + %s - %s) x (1 - %s%%) = %s', k, num(h.by[k]), num(dec), num(dec), num(h.by[k]), num(p * 100), num(v))
    end
    local s = per >= 1 and math.ceil(hp / per) or nil
    return string.format('%s %d hp: %s%s: %s', kind, hp, table.concat(parts, ' + '), #parts > 1 and string.format(' = %s a hit', num(per)) or ' a hit',
      s and string.format('%d shot%s', s, s == 1 and '' or 's') or 'under 1 a hit: cannot hurt it'), {asteroid=kind, hp=hp, per_hit=per, shots=s or false}
  end
  -- The turret that fires an ammunition aboard (for its attack bonus), and the quality of that ammunition in our
  -- turrets (the first holding it; normal when none does): the first of ours whose category it is.
  local function turret_for(pl, ammo)
    local cat = category(ammo)
    local name, quality
    for _, t in ipairs(try(function() return pl.surface.find_entities_filtered{type='ammo-turret', force=pl.force} end) or {}) do
      local cats = try(function() return t.prototype.attack_parameters.ammo_categories end) or {}
      for _, c in ipairs(cats) do
        if c == cat then
          name = name or t.name
          local inv = try(function() return t.get_inventory(defines.inventory.turret_ammo) end)
          for _, s in ipairs(inv and try(function() return inv.get_contents() end) or {}) do
            if s.name == ammo then quality = type(s.quality) == 'table' and s.quality.name or s.quality or 'normal'; return name, quality end
          end
        end
      end
    end
    return name, quality or 'normal'
  end
  M.turret_for = turret_for
  -- (d20 batch52 K4, Astra #955, 158h42: firearm-magazine read no use on Aquilo->edge, whose asteroids spawn big and
  -- huge, though their fragments are not) What one asteroid of a kind becomes when destroyed, by its prototype's dying
  -- trigger (2.0.77: huge into 3 big, big into 3 medium, medium into 3 small; small into chunks): {kind: count}, itself
  -- included, four levels at most.
  local trees = {}
  function M.breakup(kind)
    if trees[kind] then return trees[kind] end
    local out = {}
    local function walk(k, n, depth)
      out[k] = (out[k] or 0) + n
      if depth >= 4 then return end
      local e = prototypes.entity[k]
      for _, t in ipairs(e and try(function() return e.dying_trigger_effect end) or {}) do
        local child = t.type == 'create-entity' and t.entity_name and prototypes.entity[t.entity_name]
        if child and try(function() return child.type end) == 'asteroid' then
          walk(t.entity_name, n * #(t.offsets or {{0, 0}}) * (t.repeat_count or 1) * (t.probability or 1), depth + 1)
        end
      end
    end
    walk(kind, 1, 0)
    trees[kind] = out
    return out
  end
  local function shots_of(kind, ammo, force, turret, cache, quality)
    cache[kind] = cache[kind] or {}
    if cache[kind][ammo] == nil then local s = M.shots(kind, ammo, force, turret, quality); cache[kind][ammo] = s == nil and 'unknown' or s end
    return cache[kind][ammo]
  end
  -- Shots of ammo one asteroid of a kind takes, its fragments it can hurt included: total, the kind's own (number,
  -- false or 'unknown'), and the fragments' part.
  local function tree_shots(kind, ammo, force, turret, cache, quality)
    local own = shots_of(kind, ammo, force, turret, cache, quality)
    local frag = 0
    for k, n in pairs(M.breakup(kind)) do
      if k ~= kind then
        local s = shots_of(k, ammo, force, turret, cache, quality)
        if s ~= false then frag = frag + n * (s == 'unknown' and 1 or s) end
      end
    end
    return (own == false and 0 or own == 'unknown' and 1 or own) + frag, own, frag
  end
  -- Weighted shooting of a density table for one ammunition: sum of chance x shots, fragments included (unknown shots
  -- count 1, can't-hurt 0); cant: the kinds it cannot hurt (itself; their fragments may count).
  local function load_of(dens, ammo, force, turret, cache, quality)
    local w, cant = 0, {}
    for kind, p in pairs(dens) do
      local t, own = tree_shots(kind, ammo, force, turret, cache, quality)
      if own == false then cant[#cant+1] = kind end
      w = w + p * t
    end
    table.sort(cant)
    return w, cant
  end
  -- The legs flown lately (finished within the last 2 hours, and the leg flown now so far: the moving rate counts it),
  -- with their minutes and (BO1) the part of the connection flown, f0..f1 the way it was flown, from freight.lua's km0
  -- and km1 over the connection's length; a leg recorded before those were kept, flown whole: 0..1; unknown: nil.
  local function flown(pl)
    local out = {}
    for _, s in ipairs(api.segments and api.segments(pl) or {}) do
      if s.kind == 'leg' and s.start and s.from and s.to and (not s['end'] or game.tick - s['end'] <= 7200 * 60) then
        local stop = s['end'] or game.tick
        if stop > s.start then
          local c = connection(s.from, s.to)
          local len = c and try(function() return c.length end)
          local f0, f1
          if s.km0 and s.km1 and len and len > 0 then f0, f1 = math.max(0, math.min(1, s.km0 / len)), math.max(0, math.min(1, s.km1 / len))
          elseif s['end'] and not s.partial and not s.km0 then f0, f1 = 0, 1 end
          out[#out+1] = {from=s.from, to=s.to, minutes=(stop - s.start) / 3600, f0=f0, f1=f1, now=not s['end'] or nil}
        end
      end
    end
    return out
  end
  -- legs: endurance's legs ({from, to, km, minutes}); rows: its ammunition rows ({name, stock, received, phases});
  -- model: endurance's ammomodel (optional: without it, made is the rate times the time).
  function M.forecast(pl, legs, rows, opts, model)
    opts = opts or {}
    local sp = opts.speed or 1
    local dwell = (opts.dwell_s or 0) / 60
    local fl = flown(pl)
    local fd, fmin = {}, 0
    for _, l in ipairs(fl) do
      -- (BO1) the asteroids of the part flown, not the whole connection's
      local d = l.f0 and M.density_range(l.from, l.to, l.f0, l.f1) or M.density(l.from, l.to)
      for k, p in pairs(d or {}) do fd[k] = (fd[k] or 0) + p * l.minutes end
      fmin = fmin + l.minutes
    end
    for k, p in pairs(fd) do fd[k] = p / fmin end
    local cache, lines = {}, {}
    hits = {}  -- (AX1) the force's bonuses as they are now
    local fire = {}  -- ammunition -> {turret, quality} (turret_for, once a forecast)
    local function fire_of(ammo)
      if not fire[ammo] then local t, q = turret_for(pl, ammo); fire[ammo] = {t, q} end
      return fire[ammo][1], fire[ammo][2]
    end
    local seen_kinds, kind_list = {}, {}
    local flown_names = {}
    for _, l in ipairs(fl) do
      flown_names[#flown_names+1] = l.from .. '->' .. l.to .. (l.f0 and string.format(' %d-%d%%', share_pct(l.f0), share_pct(l.f1)) or ' (the part flown not recorded: the whole connection taken)')
        .. (l.now and ' (flying now)' or '') .. ' ' .. mins(l.minutes)
    end
    lines[#lines+1] = #fl > 0 and string.format('scaled from the legs flown in the last 2 hours (each the part of its connection flown, and minutes): %s (%s); their asteroids are the game\'s spawn chance over the part flown',
        table.concat(flown_names, ', ', 1, math.min(#flown_names, 6)), mins(fmin))
      or 'no leg flown in the last 2 hours on record: shots per asteroid only, no use estimate'
    -- (BO1) the parts of a route leg's connection the legs flown cover, the way the route leg flies it
    local coverage = {}
    local function cover(from, to)
      local parts = {}
      for _, l in ipairs(fl) do
        if l.f0 and l.from == from and l.to == to then parts[#parts+1] = {l.f0, l.f1}
        elseif l.f0 and l.from == to and l.to == from then parts[#parts+1] = {1 - l.f1, 1 - l.f0} end
      end
      return parts
    end
    lines[#lines+1] = 'fragments counted: an asteroid destroyed breaks into smaller ones by its prototype (huge into 3 big, big into 3 medium, medium into 3 small), and shots per asteroid add those of its fragments each ammunition can hurt'
    local left, t_cum, made_cum = {}, {}, {}
    for _, r in ipairs(rows) do left[r.name] = (r.stock or 0) + (r.received or 0) end
    for i, l in ipairs(legs) do
      local dens = M.density(l.from, l.to)
      local m = l.minutes and l.minutes / sp or nil
      if not dens then
        lines[#lines+1] = string.format('%s->%s: no space connection read', tostring(l.from), tostring(l.to))
      else
        local kinds = {}
        for k, p in pairs(dens) do kinds[#kinds+1] = {k=k, p=p} end
        table.sort(kinds, function(x, y) return x.p > y.p end)
        local kt = {}
        for j = 1, math.min(6, #kinds) do kt[j] = string.format('%s %.4f%s', kinds[j].k, kinds[j].p, fd[kinds[j].k] and string.format(' (flown %.4f)', fd[kinds[j].k]) or (#fl > 0 and ' (flown 0)' or '')) end
        local parts = cover(l.from, l.to)
        local share = covered(parts)
        local cov = #fl == 0 and '' or #parts == 0 and '; the legs flown include none of this connection: all of it is the game\'s spawn definition, scaled by the rate measured elsewhere'
          or share >= 0.995 and string.format('; the legs flown cover all of it (%s)', ranges_text(merged(parts)))
          or string.format('; the legs flown cover %d%% of it (%s); the other %d%% is the game\'s spawn definition, not measured', share_pct(share), ranges_text(merged(parts)), 100 - share_pct(share))
        coverage[#coverage+1] = {leg=l.from .. '->' .. l.to, flown=#parts > 0 and ranges_text(merged(parts)) or nil, flights=#parts, covered=math.floor(share * 1000 + 0.5) / 1000}
        lines[#lines+1] = string.format('%s->%s %d km, %s%s: asteroids (spawn chance, mean over the leg): %s%s', l.from, l.to, l.km or 0, mins(l.minutes),
          sp < 1 and ' (' .. mins(m) .. ' at ' .. round(sp * 100) .. '% speed)' or '', table.concat(kt, ', '), cov)
        for _, kd in ipairs(kinds) do
          for k in pairs(M.breakup(kd.k)) do if not seen_kinds[k] then seen_kinds[k] = true; kind_list[#kind_list+1] = k end end
        end
        for _, r in ipairs(rows) do
          local turret, quality = fire_of(r.name)
          local w, cant = load_of(dens, r.name, pl.force, turret, cache, quality)
          local shots = {}
          for j = 1, math.min(4, #kinds) do
            local _, s, frag = tree_shots(kinds[j].k, r.name, pl.force, turret, cache, quality)
            shots[#shots+1] = string.format('%s %s%s', kinds[j].k, s == false and 'none hurt' or s == 'unknown' and '?' or tostring(s),
              frag > 0 and string.format(' + %d for its fragments', math.floor(frag + 0.5)) or '')
          end
          local mv = r.phases and r.phases.moving
          local st = r.phases and r.phases.stopped
          local text = string.format('  %s%s: shots per asteroid %s%s', r.name, turret and ' (' .. turret .. ')' or '', table.concat(shots, ', '),
            #cant > 0 and '; cannot hurt ' .. table.concat(cant, ', ') or '')
          if mv and #fl > 0 and m then
            local wf = load_of(fd, r.name, pl.force, turret, cache, quality)
            local ratio = wf > 0 and w / wf or nil
            -- (K4) the part of this leg's shooting from kinds the legs flown met none of: the scale has no measure for it
            local unmet, unmet_kinds = 0, {}
            for k, p in pairs(dens) do
              if not fd[k] or fd[k] <= 0 then
                local t = tree_shots(k, r.name, pl.force, turret, cache, quality)
                if t > 0 then unmet = unmet + p * t; unmet_kinds[#unmet_kinds+1] = k end
              end
            end
            table.sort(unmet_kinds)
            if ratio and unmet > 0 and w > 0 then
              text = text .. string.format('; uncalibrated: %d%% of this leg\'s shooting is at kinds the legs flown met none of (%s)', math.floor(unmet / w * 100 + 0.5),
                table.concat(unmet_kinds, ', ', 1, math.min(3, #unmet_kinds)))
            end
            if ratio then
              local use = mv.used_per_min * ratio * m + (st and st.used_per_min or 0) * dwell
              local made = mv.made_per_min * m + (st and st.made_per_min or 0) * dwell
              -- at most what the ingredients aboard allow over the trip so far (ammomodel.lua)
              local t1 = (t_cum[r.name] or 0) + m + dwell
              local cap = model and model.cap(r.name)
              local before = made_cum[r.name] or 0
              local upto = before + made
              if cap and cap.at(t1) < upto then upto = math.max(before, (cap.at(t1))) end
              local bound = cap and upto < before + made
              if bound and cap.none then bound = false; text = text .. '; no machine aboard makes it now' end
              made = upto - before
              t_cum[r.name], made_cum[r.name] = t1, upto
              left[r.name] = left[r.name] - use + made
              text = text .. string.format('; uses about %d (%g/min on the legs flown x%.2f for these asteroids%s), about %d made%s; %d left at %s',
                round(use), mv.used_per_min, ratio, dwell > 0 and string.format(', + %s at the stop', mins(dwell)) or '', round(made),
                bound and string.format(' (the ingredients bind: %s)', cap.item) or '', round(left[r.name]), l.to)
            else
              text = text .. '; the legs flown spawn none it shoots: no use estimate'
            end
          end
          lines[#lines+1] = text
        end
      end
    end
    -- (AX1) The damage behind the shots: each ammunition's shot as platform_defense ammo_use gives it, and against each
    -- asteroid of the route (its fragments too) the resistance arithmetic; asteroids alike in health and resistances
    -- (the metallic, carbonic and oxide of one size) share a line.
    local damage_rows = {}
    if #kind_list > 0 and #rows > 0 then
      lines[#lines+1] = 'damage a shot (as platform_defense ammo_use gives it) and a hit on each asteroid after its resistances (the game\'s rule: past the flat decrease it takes the rest, then less the percent; not past it: 1 / (2 + decrease - damage), less the percent):'
      table.sort(kind_list, function(x, y)
        local hx = try(function() return prototypes.entity[x].get_max_health() end) or 0
        local hy = try(function() return prototypes.entity[y].get_max_health() end) or 0
        if hx ~= hy then return hx < hy end
        return x < y
      end)
      for _, r in ipairs(rows) do
        local turret, quality = fire_of(r.name)
        local h = M.hit(r.name, quality, pl.force, turret)
        lines[#lines+1] = '  ' .. M.hit_line(r.name, quality, pl.force, turret)
        local groups, order = {}, {}
        for _, k in ipairs(kind_list) do
          local line, row = M.vs_line(k, r.name, quality, pl.force, turret)
          if row then
            local key = line:gsub('^%S+', '')
            if not groups[key] then groups[key] = {kinds={}, line=line, row=row}; order[#order+1] = key end
            table.insert(groups[key].kinds, k)
            damage_rows[#damage_rows+1] = {ammo=r.name, ammo_quality=quality, turret=turret, damage=h and h.by or nil, damage_per_shot=h and h.total or nil,
              asteroid=k, hp=row.hp, per_hit=math.floor(row.per_hit * 100 + 0.5) / 100, shots=row.shots}
          end
        end
        for _, key in ipairs(order) do
          local g = groups[key]
          local names = g.kinds[1]
          if #g.kinds > 1 then
            local stems = {}
            for _, k in ipairs(g.kinds) do stems[#stems+1] = k:match('^%a+%-(.-)%-asteroid$') or k end
            local size = g.kinds[1]:match('^(%a+)%-') or ''
            names = size .. '-' .. table.concat(stems, '/') .. '-asteroid'
          end
          lines[#lines+1] = '    ' .. names .. key
        end
      end
    end
    -- Which limit binds what is made on the way, each ammunition once (the trip's whole time at the moving rate).
    for _, r in ipairs(model and rows or {}) do
      local mv = r.phases and r.phases.moving
      if mv and t_cum[r.name] then
        lines[#lines+1] = string.format('  %s over the forecast (%s%s): %s', r.name, mins(t_cum[r.name]),
          (r.received or 0) > 0 and string.format(', %d on rockets on their way up counted at the start', r.received) or '', model.binds(r.name, mv.made_per_min, t_cum[r.name]).line)
      end
    end
    return lines, damage_rows, coverage
  end
  return M
end
