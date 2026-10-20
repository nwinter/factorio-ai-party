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
  local function shots_of(kind, ammo, force, turret, cache)
    cache[kind] = cache[kind] or {}
    if cache[kind][ammo] == nil then local s = M.shots(kind, ammo, force, turret); cache[kind][ammo] = s == nil and 'unknown' or s end
    return cache[kind][ammo]
  end
  -- Shots of ammo one asteroid of a kind takes, its fragments it can hurt included: total, the kind's own (number,
  -- false or 'unknown'), and the fragments' part.
  local function tree_shots(kind, ammo, force, turret, cache)
    local own = shots_of(kind, ammo, force, turret, cache)
    local frag = 0
    for k, n in pairs(M.breakup(kind)) do
      if k ~= kind then
        local s = shots_of(k, ammo, force, turret, cache)
        if s ~= false then frag = frag + n * (s == 'unknown' and 1 or s) end
      end
    end
    return (own == false and 0 or own == 'unknown' and 1 or own) + frag, own, frag
  end
  -- Weighted shooting of a density table for one ammunition: sum of chance x shots, fragments included (unknown shots
  -- count 1, can't-hurt 0); cant: the kinds it cannot hurt (itself; their fragments may count).
  local function load_of(dens, ammo, force, turret, cache)
    local w, cant = 0, {}
    for kind, p in pairs(dens) do
      local t, own = tree_shots(kind, ammo, force, turret, cache)
      if own == false then cant[#cant+1] = kind end
      w = w + p * t
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
  -- legs: endurance's legs ({from, to, km, minutes}); rows: its ammunition rows ({name, stock, received, phases});
  -- model: endurance's ammomodel (optional: without it, made is the rate times the time).
  function M.forecast(pl, legs, rows, opts, model)
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
        lines[#lines+1] = string.format('%s->%s %d km, %s%s: asteroids (spawn chance, mean over the leg): %s', l.from, l.to, l.km or 0, mins(l.minutes),
          sp < 1 and ' (' .. mins(m) .. ' at ' .. round(sp * 100) .. '% speed)' or '', table.concat(kt, ', '))
        for _, r in ipairs(rows) do
          local turret = turret_for(pl, r.name)
          local w, cant = load_of(dens, r.name, pl.force, turret, cache)
          local shots = {}
          for j = 1, math.min(4, #kinds) do
            local _, s, frag = tree_shots(kinds[j].k, r.name, pl.force, turret, cache)
            shots[#shots+1] = string.format('%s %s%s', kinds[j].k, s == false and 'none hurt' or s == 'unknown' and '?' or tostring(s),
              frag > 0 and string.format(' + %d for its fragments', math.floor(frag + 0.5)) or '')
          end
          local mv = r.phases and r.phases.moving
          local st = r.phases and r.phases.stopped
          local text = string.format('  %s%s: shots per asteroid %s%s', r.name, turret and ' (' .. turret .. ')' or '', table.concat(shots, ', '),
            #cant > 0 and '; cannot hurt ' .. table.concat(cant, ', ') or '')
          if mv and #fl > 0 and m then
            local wf = load_of(fd, r.name, pl.force, turret, cache)
            local ratio = wf > 0 and w / wf or nil
            -- (K4) the part of this leg's shooting from kinds the legs flown met none of: the scale has no measure for it
            local unmet, unmet_kinds = 0, {}
            for k, p in pairs(dens) do
              if not fd[k] or fd[k] <= 0 then
                local t = tree_shots(k, r.name, pl.force, turret, cache)
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
    -- Which limit binds what is made on the way, each ammunition once (the trip's whole time at the moving rate).
    for _, r in ipairs(model and rows or {}) do
      local mv = r.phases and r.phases.moving
      if mv and t_cum[r.name] then
        lines[#lines+1] = string.format('  %s over the forecast (%s%s): %s', r.name, mins(t_cum[r.name]),
          (r.received or 0) > 0 and string.format(', %d on rockets on their way up counted at the start', r.received) or '', model.binds(r.name, mv.made_per_min, t_cum[r.name]).line)
      end
    end
    return lines
  end
  return M
end
