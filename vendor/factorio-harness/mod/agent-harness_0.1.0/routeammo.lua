-- platform_endurance {platform, route, forecast: true, pessimistic?} (E11, Astra 19:50: "cannot yet justify the Aquilo
-- leg"): per leg of the route, the asteroids its space connection spawns by kind (the game's spawn chance, its mean over
-- the leg), what one of each takes of each ammunition aboard (its health against the ammunition's damage after the
-- asteroid's resistances and our damage bonuses; none when the damage cannot hurt it), and the ammunition the leg uses:
-- the moving rate measured on the legs this platform flew lately (B3), scaled by how much more shooting this leg's
-- asteroids take than theirs; with what is made aboard meanwhile and what is left at each arrival. pessimistic {speed
-- 0.1..1 (a share of the speed read), dwell_s 0..36000 (extra time at each stop, at the stopped rate)}. An estimate from
-- prototypes and measured rates; the engine's own spawning is not simulated.
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
  -- An ammunition's damage per shot by type, and its category; nil when the damage is in a projectile (rockets).
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
      end
    end
    if #parts == 0 then return nil, at.category, projectile end
    return parts, at.category, projectile
  end
  -- Shots of ammo one asteroid takes: a number; false when every hit does under 1 (it cannot hurt it); nil unknown.
  function M.shots(kind, ammo, force, turret)
    local e = prototypes.entity[kind]
    local hp = e and try(function() return e.get_max_health() end)
    local parts, cat = damage_of(ammo)
    if not (hp and parts) then return nil end
    local bonus = 1 + (try(function() return force.get_ammo_damage_modifier(cat) end) or 0)
    if turret then bonus = bonus * (1 + (try(function() return force.get_turret_attack_modifier(turret) end) or 0)) end
    local res = try(function() return e.resistances end) or {}
    local per = 0
    for _, d in ipairs(parts) do
      local dmg = d.amount * bonus
      local r = res[d.type] or {}
      local dec, pct = r.decrease or 0, r.percent or 0
      -- the game's rule: past the flat decrease it takes the rest, else 1 / (2 + decrease - damage); then the percent
      local after = dmg > dec and (dmg - dec) or 1 / (2 + dec - dmg)
      per = per + after * (1 - pct)
    end
    if per < 1 then return false end
    return math.ceil(hp / per)
  end
  -- The turret that fires an ammunition aboard (for its attack bonus): the first of ours whose category it is.
  local function turret_for(pl, ammo)
    local cat = try(function() return prototypes.item[ammo].get_ammo_type().category end)
    for _, t in ipairs(try(function() return pl.surface.find_entities_filtered{type='ammo-turret', force=pl.force, limit=64} end) or {}) do
      local cats = try(function() return t.prototype.attack_parameters.ammo_categories end) or {}
      for _, c in ipairs(cats) do if c == cat then return t.name end end
    end
  end
  -- Weighted shooting of a density table for one ammunition: sum of chance x shots (unknown shots count 1, can't-hurt 0).
  local function load_of(dens, ammo, force, turret, cache)
    local w, cant = 0, {}
    for kind, p in pairs(dens) do
      cache[kind] = cache[kind] or {}
      if cache[kind][ammo] == nil then local s = M.shots(kind, ammo, force, turret); cache[kind][ammo] = s == nil and 'unknown' or s end
      local s = cache[kind][ammo]
      if s == false then cant[#cant+1] = kind else w = w + p * (s == 'unknown' and 1 or s) end
    end
    table.sort(cant)
    return w, cant
  end
  -- The legs flown lately (finished, within the last 2 hours), with their minutes.
  local function flown(pl)
    local out = {}
    for _, s in ipairs(api.segments and api.segments(pl) or {}) do
      if s.kind == 'leg' and s['end'] and s.start and s.from and s.to and game.tick - s['end'] <= 7200 * 60 then
        out[#out+1] = {from=s.from, to=s.to, minutes=(s['end'] - s.start) / 3600}
      end
    end
    return out
  end
  -- legs: endurance's legs ({from, to, km, minutes}); rows: its ammunition rows ({name, stock, phases}).
  function M.forecast(pl, legs, rows, opts)
    opts = opts or {}
    local sp = opts.speed or 1
    local dwell = (opts.dwell_s or 0) / 60
    local fl = flown(pl)
    local fd, fmin = {}, 0
    for _, l in ipairs(fl) do
      local d = M.density(l.from, l.to)
      for k, p in pairs(d or {}) do fd[k] = (fd[k] or 0) + p * l.minutes end
      fmin = fmin + l.minutes
    end
    for k, p in pairs(fd) do fd[k] = p / fmin end
    local cache, lines = {}, {}
    local flown_names = {}
    for _, l in ipairs(fl) do flown_names[#flown_names+1] = l.from .. '->' .. l.to end
    lines[#lines+1] = #fl > 0 and string.format('scaled from the legs flown in the last 2 hours: %s (%s)', table.concat(flown_names, ', ', 1, math.min(#flown_names, 6)), mins(fmin))
      or 'no leg flown in the last 2 hours on record: shots per asteroid only, no use estimate'
    local left = {}
    for _, r in ipairs(rows) do left[r.name] = r.stock or 0 end
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
        lines[#lines+1] = string.format('%s->%s %d km, %s%s: asteroids (spawn chance, mean over the leg): %s', l.from, l.to, l.km or 0, mins(l.minutes),
          sp < 1 and ' (' .. mins(m) .. ' at ' .. round(sp * 100) .. '% speed)' or '', table.concat(kt, ', '))
        for _, r in ipairs(rows) do
          local turret = turret_for(pl, r.name)
          local w, cant = load_of(dens, r.name, pl.force, turret, cache)
          local shots = {}
          for j = 1, math.min(4, #kinds) do
            local s = cache[kinds[j].k] and cache[kinds[j].k][r.name]
            shots[#shots+1] = string.format('%s %s', kinds[j].k, s == false and 'none hurt' or s == 'unknown' and '?' or tostring(s))
          end
          local mv = r.phases and r.phases.moving
          local st = r.phases and r.phases.stopped
          local text = string.format('  %s%s: shots per asteroid %s%s', r.name, turret and ' (' .. turret .. ')' or '', table.concat(shots, ', '),
            #cant > 0 and '; cannot hurt ' .. table.concat(cant, ', ') or '')
          if mv and #fl > 0 and m then
            local wf = load_of(fd, r.name, pl.force, turret, cache)
            local ratio = wf > 0 and w / wf or nil
            if ratio then
              local use = mv.used_per_min * ratio * m + (st and st.used_per_min or 0) * dwell
              local made = mv.made_per_min * m + (st and st.made_per_min or 0) * dwell
              left[r.name] = left[r.name] - use + made
              text = text .. string.format('; uses about %d (%g/min on the legs flown x%.2f for these asteroids%s), about %d made; %d left at %s',
                round(use), mv.used_per_min, ratio, dwell > 0 and string.format(', + %s at the stop', mins(dwell)) or '', round(made), round(left[r.name]), l.to)
            else
              text = text .. '; the legs flown spawn none it shoots: no use estimate'
            end
          end
          lines[#lines+1] = text
        end
      end
    end
    return lines
  end
  return M
end
