-- The game's alerts and key warnings, pushed (viewer Enginerd, shift07 15:30:
-- "The agents would be a lot more efficient if they'd react to the alerts in
-- the UI, like reacting to unpowered buildings"). Full status listed power,
-- fuel and turret warnings only when an agent pulled it, and the game's alert
-- list (construction materials, robots, repair packs, storage, trains,
-- cargo, collectors) was never read. Here, what a player's alert panel and
-- entity status icons show:
-- - entity statuses: no power (and no pole reaching it), low power, no fuel,
--   gun turrets out of ammo (rebuilt ones still empty 60 s on: named apart),
--   flamethrower turrets dry;
-- - the game's alerts (LuaPlayer.get_alerts, read from an agent player whose
--   alerts are on; attacks, losses and empty turrets are told elsewhere);
-- - per network (networks.lua, task-selfview): draw at 85% of capacity or
--   more for 2 minutes, boilers under 20 minutes of fuel (again at 10 and 5), no idle logistic
--   robot for 10 minutes.
-- Grouped by kind and 64-tile area on each surface; each group goes to the
-- agents whose board claim covers it, else who built it (last_user), else
-- the nearest agent on that surface. In the team block (team.alerts) at most
-- one digest per agent every 150 s, new or worsening groups only; the
-- game_alerts read lists them all. The scan is kept in storage for 30 s so
-- every peer computes the same lines.
return function(api)
  local M = {}
  local CELL, SCAN_TICKS, DIGEST_TICKS, MAX_LINES, MAX_SCAN = 64, 1800, 9000, 5, 20000
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local TYPES = {'assembling-machine', 'furnace', 'mining-drill', 'lab', 'inserter', 'beacon', 'radar', 'roboport',
    'pump', 'electric-turret', 'ammo-turret', 'fluid-turret', 'boiler', 'rocket-silo', 'agricultural-tower',
    'asteroid-collector', 'lamp', 'loader', 'loader-1x1', 'cargo-landing-pad', 'car', 'spider-vehicle'}
  -- Kinds and how a line says them; game alert types not listed read as their name.
  local LABEL = {no_power='no power', unconnected='not connected to power (no pole reaches them)', low_power='low power',
    no_fuel='out of fuel', no_ammo='out of ammo', flamer_dry='out of flamer oil', rebuilt_empty='rebuilt empty',
    no_material_for_construction='ghosts waiting for materials (no robot can bring them)',
    not_enough_construction_robots='not enough construction robots', not_enough_repair_packs='robots out of repair packs',
    no_storage='robots have no storage for what they carry', no_roboport_storage='no roboport storage',
    train_out_of_fuel='train out of fuel', train_no_path='train has no path', unclaimed_cargo='unclaimed cargo',
    collector_path_blocked='asteroid collector path blocked', pipeline_overextended='pipeline overextended (flow stops)',
    no_platform_storage='platform hub storage full', platform_tile_building_blocked='platform tile building blocked'}
  local HINT = {no_power='fh call power', unconnected='fh call power', low_power='more power: fh call power', no_fuel='refuel',
    no_ammo='rearm', flamer_dry='fh call flamers', no_material_for_construction='craft or bring the items for the ghosts',
    not_enough_construction_robots='more construction robots in the roboports', not_enough_repair_packs='repair packs into a roboport or storage chest',
    no_storage='a storage chest in the network', train_out_of_fuel='refuel the locomotive'}
  -- Told elsewhere (attacks, losses, the turret scan).
  local SKIP = {entity_destroyed=true, entity_under_attack=true, turret_fire=true, turret_out_of_ammo=true, custom=true}
  local STATUS
  local function statuses()
    if not STATUS then
      local s = defines.entity_status or {}
      STATUS = {[s.no_power or -1]='no_power', [s.low_power or -2]='low_power', [s.no_fuel or -3]='no_fuel'}
    end
    return STATUS
  end
  local function alert_names()
    local out = {}
    for name, id in pairs(defines.alert_type or {}) do out[id] = name end
    return out
  end

  -- detail: a line for this entity (lost sources: the inserter, what it read, what it puts into), up to MAX_DETAIL a group.
  local MAX_DETAIL = 4
  local function add(groups, kind, surface, e, pos, name, by, detail)
    local cx, cy = math.floor(pos.x / CELL), math.floor(pos.y / CELL)
    local key = kind .. '|' .. surface .. '|' .. cx .. ',' .. cy
    local g = groups[key]
    if not g then
      g = {key=key, kind=kind, surface=surface, n=0, names={}, sx=0, sy=0, at={}, by={}}
      groups[key] = g
    end
    g.n = g.n + 1
    g.sx, g.sy = g.sx + pos.x, g.sy + pos.y
    if name then g.names[name] = (g.names[name] or 0) + 1 end
    if by then g.by[by] = (g.by[by] or 0) + 1 end
    if #g.at < 4 then g.at[#g.at+1] = {x=math.floor(pos.x * 10 + 0.5) / 10, y=math.floor(pos.y * 10 + 0.5) / 10} end
    if detail then g.lost = g.lost or {}; if #g.lost < MAX_DETAIL then g.lost[#g.lost+1] = detail end end
  end
  local function builder(e)
    return try(function() local u = e.last_user; return u and u.name end)
  end
  -- Lost sources (Haiku, 04:52: "a chest gone alert when a feed chest disappears, since an inserter with no source
  -- fails silently (once this hour, a boiler went no_fuel)"). Each read remembers every inserter's targets
  -- (targets.lua; storage push_inserters, per force, by unit number). An inserter that had a pickup target and now has
  -- none, or whose drop target is gone, is in a group of kind lost_source.<fed> or lost_target.<fed>, where fed is
  -- what it puts into (or put into, when that is gone): boiler, furnace, lab, assembler, else the entity type. It
  -- stays there, with what it read and fed then, until it has a target again or is gone.
  local FED = {boiler='boiler', furnace='furnace', lab='lab', ['assembling-machine']='assembler'}
  local function at_text(pos) return string.format('(%g,%g)', math.floor(pos.x * 10 + 0.5) / 10, math.floor(pos.y * 10 + 0.5) / 10) end
  local function inserter_memory(force)
    local s = api.state()
    s.push_inserters = s.push_inserters or {}
    local mem = s.push_inserters[force.name]
    if not mem then mem = {gen=0, units={}}; s.push_inserters[force.name] = mem end
    return mem
  end
  local function watch_inserter(groups, s, e, mem)
    local unit = try(function() return e.unit_number end)
    local targets = api.targets
    if not (unit and targets) then return end
    local pick, drop = targets.read(e)
    -- The engine's target can stay empty a while after its chest is replaced (Astra, 07:26: a wooden chest upgraded to
    -- a requester; the inserter, holding cable, worked from it): what stands on the point counts as the target, and
    -- the remembered one is the current one, whichever entity that is now.
    if not pick then pick = targets.standing(s, try(function() return e.pickup_position end)) end
    if not drop then drop = targets.standing(s, try(function() return e.drop_position end)) end
    local old = mem.units[unit]
    local now = {g=mem.gen, p=pick and targets.name_at(pick) or nil, d=drop and targets.name_at(drop) or nil, dt=drop and drop.type or nil}
    if old then
      if not pick then now.lost_p = old.lost_p or old.p end
      if not drop then now.lost_d, now.ldt = old.lost_d or old.d, old.ldt or old.dt end
    end
    mem.units[unit] = now
    if not (now.lost_p or now.lost_d) then return end
    local fed = now.dt or now.ldt
    local word = FED[fed] or fed or 'nothing'
    local pos = at_text(e.position)
    local detail
    if now.lost_p then
      detail = string.format('%s %s read %s%s', e.name, pos, now.lost_p,
        now.d and ', puts into ' .. now.d or now.lost_d and ', put into ' .. now.lost_d .. ' (gone too)' or '')
    else
      detail = string.format('%s %s put into %s%s', e.name, pos, now.lost_d, now.p and ', reads ' .. now.p or '')
    end
    add(groups, (now.lost_p and 'lost_source.' or 'lost_target.') .. word, s.name, e, e.position, e.name, builder(e), detail)
  end
  -- After a whole read: forget inserters it did not see (gone, or past the read's budget).
  local function forget_unseen(mem)
    for unit, v in pairs(mem.units) do if v.g ~= mem.gen then mem.units[unit] = nil end end
  end
  -- Turrets rebuilt empty (Astra, shift10: 15+ gun turrets rebuilt by robots with no ammo and destroyed again;
  -- operator 06:20 item 10). Each read remembers every ammo turret (storage push_turrets, per force, by unit number).
  -- One first seen after a whole read was built since, and so is one that died (M.turret_died): rebuilt from its
  -- ghost it has its old unit number again (2.0). While it has had no ammo since it was first seen, for EMPTY_TICKS
  -- or more, it is in a rebuilt_empty group, named with its ammo request (instead of no_ammo). Once it holds ammo it
  -- is like any other turret.
  local EMPTY_TICKS = 3600
  local function turret_memory(force)
    local s = api.state()
    s.push_turrets = s.push_turrets or {}
    local mem = s.push_turrets[force.name]
    if not mem then mem = {gen=0, units={}}; s.push_turrets[force.name] = mem end
    return mem
  end
  -- After a whole read (complete: not cut by the read's budget, and started with this memory: a read under way at a
  -- deploy saw part of the map before it existed): forget turrets it did not see; from now on a turret not seen
  -- before was built since.
  local function turrets_read(mem, complete)
    if not complete then return end
    for unit, v in pairs(mem.units) do if v.g ~= mem.gen then mem.units[unit] = nil end end
    mem.ready = true
  end
  -- The kind for an ammo turret (empty: no ammo in it): rebuilt_empty with its detail, or no_ammo, or nil.
  local function turret_kind(e, empty, mem)
    local unit = mem and try(function() return e.unit_number end)
    local t = unit and mem.units[unit]
    if unit and not t then t = {new=mem.ready or nil}; mem.units[unit] = t end
    if t then
      t.g = mem.gen
      if not empty then t.new, t.empty = nil, nil
      elseif t.new then
        t.empty = t.empty or game.tick
        if game.tick - t.empty >= EMPTY_TICKS then
          local asks = try(function() local x = e.item_request_proxy; return x and x.item_requests end) or {}
          local parts = {}
          for _, r in ipairs(asks) do parts[#parts+1] = r.count .. ' ' .. r.name end
          return 'rebuilt_empty', string.format('%s %s %s', e.name, at_text(e.position),
            #parts > 0 and 'requests ' .. table.concat(parts, ', ') or 'no ammo request')
        end
      end
    end
    return empty and 'no_ammo' or nil
  end
  -- One read is these stages: the entities on each planet surface, the game's
  -- alert list, the network groups, then the merge. scan() runs them all at
  -- once; the background job (M.tick) walks each planet in bands (task-
  -- statuscost, 01:15 on world n: pushalerts.lines up to 150 ms when a reply
  -- ran the whole read; operator 04:00, see SLICE).
  local function entity_list(s, force, t, budget)
    return try(function() return s.find_entities_filtered{force=force, type=t, limit=budget} end) or {}
  end
  -- Entities from..to of a found list into the groups (mem: the inserter memory; tmem: the turret memory).
  local function read_list(groups, s, list, from, to, mem, tmem)
    local st = statuses()
    for i = from or 1, to or #list do
      local e = list[i]
      if e.valid and mem and e.type == 'inserter' then watch_inserter(groups, s, e, mem) end
      if e.valid then
        local kind = st[e.status]
        local detail
        if kind == 'no_power' and not try(function() return e.electric_network_id end) then kind = 'unconnected' end
        if e.type == 'ammo-turret' then
          local inv = try(function() return e.get_inventory(defines.inventory.turret_ammo) end)
          local tk, td = turret_kind(e, inv and inv.get_item_count() == 0, tmem)
          if tk then kind, detail = tk, td end
        elseif e.type == 'fluid-turret' then
          local amount = try(function() local f = e.fluidbox[1]; return f and f.amount or 0 end)
          if amount and amount < 1 then kind = 'flamer_dry' end
        end
        if kind then add(groups, kind, s.name, e, e.position, e.name, builder(e), detail) end
      end
    end
  end
  local function entities(groups, s, force, t, budget, mem, tmem)
    local list = entity_list(s, force, t, budget)
    read_list(groups, s, list, nil, nil, mem, tmem)
    return #list
  end
  -- The background job's step (operator 04:00: steps of a whole-surface find, then 1500 entities, burst to 138 ms in
  -- a game second): one band of a planet (walk.lua) or SLICE of the entities it found, one step every few ticks so
  -- a read spreads over its 30 s.
  local SLICE = 150
  local walk = api.walk or require('walk'){state=api.state}
  local function planets()
    local out = {}
    for _, s in pairs(game.surfaces) do
      if not try(function() return s.platform end) then out[#out+1] = s end  -- platforms: platalerts.lua
    end
    table.sort(out, function(a, b) return (a.index or 0) < (b.index or 0) end)
    return out
  end
  local function game_alerts(groups, force)
    -- The game's alert list, as an agent player's alert panel shows it.
    local reader = api.alert_reader and api.alert_reader(force)
    local raw = reader and try(function() return reader.get_alerts{} end)
    if raw then
      local names = alert_names()
      for surface_index, by_type in pairs(raw) do
        local s = game.surfaces[surface_index]
        for t, list in pairs(by_type) do
          local kind = names[t]
          if kind and not SKIP[kind] and s then
            for _, al in ipairs(list) do
              local e = al.target
              local ok = e and try(function() return e.valid end)
              local pos = ok and e.position or al.position
              if pos then
                add(groups, kind, s.name, ok and e or nil, pos, ok and e.name or (al.prototype and try(function() return al.prototype.name end)),
                  ok and builder(e) or nil)
              end
            end
          end
        end
      end
    end
  end
  local function merge(groups, extra)
    -- Cells of one kind on one surface that touch (8 neighbours) are one area:
    -- a turret line across a cell edge is one group. Its key is its first cell.
    local out, done = {}, {}
    local cells = {}
    for key, g in pairs(groups) do cells[#cells+1] = key end
    table.sort(cells)
    for _, key in ipairs(cells) do
      if not done[key] then
        local g = groups[key]
        local kind, surface, cx, cy = key:match('^(.-)|(.-)|(-?%d+),(-?%d+)$')
        local area = {key=key, kind=g.kind, surface=g.surface, n=0, names={}, sx=0, sy=0, at={}, by={}}
        local queue = {{tonumber(cx), tonumber(cy)}}
        done[key] = true
        while #queue > 0 do
          local c = table.remove(queue)
          local k = kind .. '|' .. surface .. '|' .. c[1] .. ',' .. c[2]
          local part = groups[k]
          area.n, area.sx, area.sy = area.n + part.n, area.sx + part.sx, area.sy + part.sy
          for n, v in pairs(part.names) do area.names[n] = (area.names[n] or 0) + v end
          for n, v in pairs(part.by) do area.by[n] = (area.by[n] or 0) + v end
          for _, pos in ipairs(part.at) do if #area.at < 4 then area.at[#area.at+1] = pos end end
          for _, d in ipairs(part.lost or {}) do area.lost = area.lost or {}; if #area.lost < MAX_DETAIL then area.lost[#area.lost+1] = d end end
          for dx = -1, 1 do for dy = -1, 1 do
            local nk = kind .. '|' .. surface .. '|' .. (c[1] + dx) .. ',' .. (c[2] + dy)
            if groups[nk] and not done[nk] then done[nk] = true; queue[#queue+1] = {c[1] + dx, c[2] + dy} end
          end end
        end
        area.center = {x=math.floor(area.sx / area.n + 0.5), y=math.floor(area.sy / area.n + 0.5)}
        area.sx, area.sy = nil, nil
        out[#out+1] = area
      end
    end
    -- Network groups (networks.lua): power_high, boiler_fuel, robots_busy,
    -- one per network, with their own line and level (n).
    for _, g in ipairs(extra or {}) do out[#out+1] = g end
    table.sort(out, function(a, b) return a.n > b.n or (a.n == b.n and a.key < b.key) end)
    return out
  end
  local function network_groups(force)
    return api.network_groups and try(function() return api.network_groups(force) end) or {}
  end
  -- One read of everything at once: groups (array, worst first).
  local function scan(force)
    local groups, budget = {}, MAX_SCAN
    local mem, tmem = inserter_memory(force), turret_memory(force)
    mem.gen, tmem.gen = mem.gen + 1, tmem.gen + 1
    for _, s in ipairs(planets()) do budget = budget - entities(groups, s, force, TYPES, budget, mem, tmem) end
    forget_unseen(mem)
    turrets_read(tmem, budget > 0)
    game_alerts(groups, force)
    return merge(groups, network_groups(force))
  end
  -- The background read, one stage per tick, its state in storage so every
  -- peer runs the same: started when the last read is SCAN_TICKS old.
  local function forces()
    local out = {}
    for _, f in pairs(game.forces or {}) do if f.players and #f.players > 0 then out[#out+1] = f end end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
  end
  function M.tick(tick)
    local s = api.state()
    s.push_alerts = s.push_alerts or {}
    s.push_jobs = s.push_jobs or {}
    s.push_bg = true
    for _, force in ipairs(forces()) do
      -- A step that fails ends its job (noted in push_errors); the last read is kept another SCAN_TICKS.
      local ok, err = pcall(M.step, s, force, tick)
      if not ok then
        s.push_jobs[force.name] = nil
        s.push_errors = {count=((s.push_errors or {}).count or 0) + 1, last=tostring(err), tick=tick}
        if s.push_alerts[force.name] then s.push_alerts[force.name].tick = tick end
      end
    end
  end
  function M.step(s, force, tick)
    do
      local job = s.push_jobs[force.name]
      local c = s.push_alerts[force.name]
      if not job and (not c or tick - c.tick >= SCAN_TICKS) then
        local stages = {}
        for _, surface in ipairs(planets()) do stages[#stages+1] = {surface=surface.name} end
        stages[#stages+1] = {step='alerts'}
        stages[#stages+1] = {step='networks'}
        stages[#stages+1] = {step='merge'}
        s.push_steps = s.push_steps or {}
        job = {start=tick, stages=stages, i=1, groups={}, budget=MAX_SCAN, steps=0,
          every=walk.every(s.push_steps[force.name], SCAN_TICKS)}
        s.push_jobs[force.name] = job
        local mem, tmem = inserter_memory(force), turret_memory(force)
        mem.gen, tmem.gen = mem.gen + 1, tmem.gen + 1
        job.tgen = tmem.gen
      elseif job and walk.due(job, tick, SCAN_TICKS) then
        job.steps = job.steps + 1
        local stage = job.stages[job.i]
        if stage.surface then
          -- A planet: a band found in one step (walk.lua), then read SLICE a step.
          local surface
          for _, x in ipairs(planets()) do if x.name == stage.surface then surface = x end end
          if not surface or job.budget <= 0 then job.i = job.i + 1; job.walk, job.list = nil, nil
          elseif not job.list then
            job.walk = job.walk or walk.start(surface)
            local list = walk.band(job.walk, surface, {force=force, type=TYPES, limit=job.budget})
            if list then job.list, job.at = list, 1; job.budget = job.budget - #list
            else job.walk = nil; job.i = job.i + 1 end
          else
            local last = math.min(#job.list, job.at + SLICE - 1)
            read_list(job.groups, surface, job.list, job.at, last, inserter_memory(force), turret_memory(force))
            job.at = last + 1
            if job.at > #job.list then job.list, job.at = nil, nil end
          end
        elseif stage.step == 'alerts' then
          job.i = job.i + 1; game_alerts(job.groups, force); forget_unseen(inserter_memory(force))
          local tmem = turret_memory(force)
          turrets_read(tmem, job.budget > 0 and job.tgen == tmem.gen)
        elseif stage.step == 'networks' then job.i = job.i + 1; job.extra = network_groups(force)
        else
          s.push_alerts[force.name] = {tick=job.start, groups=merge(job.groups, job.extra)}
          s.push_steps[force.name] = job.steps
          s.push_jobs[force.name] = nil
        end
      end
    end
  end
  -- One of our turrets died (the runtime's on_entity_died): marked built since, for when its ghost is built again.
  function M.turret_died(e)
    local s = api.state()
    local mem = s.push_turrets and s.push_turrets[e.force.name]
    local unit = mem and e.unit_number
    if unit then mem.units[unit] = {new=true, g=mem.gen} end
  end
  -- The last finished read; with the background job running it never reads
  -- in a reply, except a force's very first (and tests without the job).
  local function current(force)
    local s = api.state()
    s.push_alerts = s.push_alerts or {}
    local c = s.push_alerts[force.name]
    if c and (s.push_bg or game.tick - c.tick < SCAN_TICKS) then return c end
    c = {tick=game.tick, groups=scan(force)}
    s.push_alerts[force.name] = c
    return c
  end

  -- Who hears a group: the owners of active board claims over its centre (on its surface),
  -- else agents who built in it, else the nearest agent on its surface.
  local ACTIVE = {open=true, claimed=true, doing=true, blocked=true}
  local function owners(g, roster)
    local out, board = {}, api.state().board
    for _, i in pairs(board and board.items or {}) do
      local a = i.area
      if i.kind == 'claim' and ACTIVE[i.status] and i.owner and a and g.center.x >= a.left_top.x and g.center.x <= a.right_bottom.x
        and g.center.y >= a.left_top.y and g.center.y <= a.right_bottom.y
        and (api.claim_surface and api.claim_surface(i) or i.surface or 'nauvis') == g.surface then out[i.owner] = 'claim' end
    end
    if next(out) then return out end
    for name in pairs(g.by) do if roster[name] then out[name] = 'built' end end
    if next(out) then return out end
    local best, d2 = nil, math.huge
    for name, a in pairs(roster) do
      local pl = a.place
      if pl and pl.key == g.surface and pl.position and not pl.dead then
        local d = (pl.position.x - g.center.x) ^ 2 + (pl.position.y - g.center.y) ^ 2
        if d < d2 then best, d2 = name, d end
      end
    end
    if best then out[best] = 'nearest' end
    return out
  end
  local function roster()
    local out = {}
    for _, a in ipairs(try(api.agents) or {}) do out[a.name] = {index=a.index, place=api.place and try(function() return api.place(a.index) end)} end
    return out
  end
  local function what(g)
    local names = {}
    for name, n in pairs(g.names) do names[#names+1] = {name=name, n=n} end
    table.sort(names, function(a, b) return a.n > b.n or (a.n == b.n and a.name < b.name) end)
    if #names == 1 then return g.n .. ' ' .. names[1].name end
    if #names == 0 then return tostring(g.n) end
    local parts = {}
    for i = 1, math.min(3, #names) do parts[i] = names[i].n .. ' ' .. names[i].name end
    return string.format('%d (%s%s)', g.n, table.concat(parts, ', '), #names > 3 and ', ...' or '')
  end
  -- plain: without the hint (the review block, selfview.lua).
  -- was: the count told before, or (a group with now_text) what its now_text said then.
  function M.text(g, here, was, plain)
    if g.line then
      local before = type(was) == 'string' and ' (was ' .. was .. ')' or was and string.format(' (was %d%s)', was, g.unit or '') or ''
      return g.line .. (g.surface ~= here and ' on ' .. g.surface or '') .. before
    end
    local lost, fed = g.kind:match('^lost_(%a+)%.(.+)$')
    if lost then
      -- '2 inserters feeding boiler lost their pickup target near (60,14): burner-inserter (60,14) read wooden-chest (41,13), puts into boiler (60,16); ...'
      local one = g.n == 1
      return string.format('%d inserter%s feeding %s lost %s %s target near (%d,%d)%s%s: %s%s', g.n, one and '' or 's', fed,
        one and 'its' or 'their', lost == 'source' and 'pickup' or 'drop', g.center.x, g.center.y,
        g.surface ~= here and ' on ' .. g.surface or '', was and string.format(' (was %d)', was) or '',
        table.concat(g.lost or {}, '; '), g.n > #(g.lost or {}) and string.format('; +%d more', g.n - #(g.lost or {})) or '')
    end
    if g.kind == 'rebuilt_empty' then
      -- '2 gun-turret rebuilt empty near (61,15): no ammo since built, 60+ s: gun-turret (60,14) requests 10 firearm-magazine; ...'
      return string.format('%s rebuilt empty near (%d,%d)%s%s: no ammo since built, 60+ s: %s%s%s', what(g), g.center.x, g.center.y,
        g.surface ~= here and ' on ' .. g.surface or '', was and string.format(' (was %d)', was) or '',
        table.concat(g.lost or {}, '; '), g.n > #(g.lost or {}) and string.format('; +%d more', g.n - #(g.lost or {})) or '',
        not plain and '; rearm' or '')
    end
    local hint = not plain and HINT[g.kind]
    return string.format('%s %s near (%d,%d)%s%s%s', what(g), LABEL[g.kind] or g.kind:gsub('_', ' '), g.center.x, g.center.y,
      g.surface ~= here and ' on ' .. g.surface or '', was and string.format(' (was %d)', was) or '', hint and '; ' .. hint or '')
  end

  -- Team block lines for p: at most one digest every DIGEST_TICKS, groups
  -- addressed to p that are new or grew since p was told. A group's rank,
  -- when it has one, is what grows (boiler_fuel: the step it reached, then
  -- how many boilers); its now_text is kept to say what it was.
  function M.lines(p, h)
    local mem = h.push or {told={}}
    if mem.tick and game.tick - mem.tick < DIGEST_TICKS then return {} end
    local c = current(p.force)
    local me = api.who(p)
    local here = try(function() return p.surface.name end)
    local who = roster()
    local now, lines, more = {}, {}, 0
    for _, g in ipairs(c.groups) do
      if owners(g, who)[me] then
        local level = g.rank or g.n
        now[g.key] = level
        local told = mem.told[g.key]
        if not told or level > told then
          if #lines < MAX_LINES then
            lines[#lines+1] = M.text(g, here, told and (mem.said and mem.said[g.key] or (not g.rank and told)) or nil)
            mem.told[g.key] = level
            if g.now_text then mem.said = mem.said or {}; mem.said[g.key] = g.now_text end
          else more = more + 1 end
        elseif level < told then  -- better: a rise from here is news again
          mem.told[g.key] = level
          if g.now_text then mem.said = mem.said or {}; mem.said[g.key] = g.now_text end
        end
      end
    end
    for key in pairs(mem.told) do if not now[key] then mem.told[key] = nil end end  -- gone: news again if it returns
    for key in pairs(mem.said or {}) do if not mem.told[key] then mem.said[key] = nil end end
    if more > 0 then lines[#lines+1] = string.format('+%d more alert groups: fh call game_alerts', more) end
    if #lines > 0 then mem.tick = game.tick end
    h.push = (next(mem.told) or mem.tick) and mem or nil
    return lines
  end

  -- Groups now in p's own board claims (selfview.lua review), worst first, without hints.
  function M.claim_lines(p)
    local c = current(p.force)
    local me = api.who(p)
    local here = try(function() return p.surface.name end)
    local who, out = roster(), {}
    for _, g in ipairs(c.groups) do
      if owners(g, who)[me] == 'claim' then out[#out+1] = M.text(g, here, nil, true) end
    end
    return out
  end
  -- The game_alerts read: every group now, with who it goes to.
  function M.read(p, a)
    local c = current(p.force)
    local who = roster()
    local here = try(function() return p.surface.name end)
    local rows = {}
    for _, g in ipairs(c.groups) do
      if (a.surface == nil or g.surface == a.surface) and (a.kind == nil or g.kind == a.kind or g.kind:sub(1, #a.kind + 1) == a.kind .. '.') then
        local to = {}
        for name, why in pairs(owners(g, who)) do to[#to+1] = name .. ' (' .. why .. ')' end
        table.sort(to)
        rows[#rows+1] = {kind=g.kind, surface=g.surface, count=g.n, center=g.center, names=g.names, at=g.at, lost=g.lost,
          line=M.text(g, here), to=#to > 0 and to or nil}
      end
    end
    return {groups=rows, scanned=string.format('%ds ago', math.floor((game.tick - c.tick) / 60)),
      note=#rows == 0 and 'no alerts or warnings' or nil}
  end
  M.schema = {
    game_alerts = {surface='optional surface name', kind='optional kind (no_power, unconnected, low_power, no_fuel, no_ammo, flamer_dry; rebuilt_empty (turrets built with no ammo and still empty 60 s or more, each with its ammo request); lost_source and lost_target (inserters that had a pickup target and have none now, or whose drop target is gone; by what they feed: lost_source.boiler, .furnace, .lab, .assembler, else the entity type; each with lost: the inserter, what it read, what it puts into); per network: power_high (draw at 85% of capacity or more for 2 min), boiler_fuel (boilers under 20 min of their own fuel at the draw with no fuel in their feeders\' hands or at their sources, again at 10 and 5; the fuel in chests and on belts within 64 tiles and what feeds them), robots_busy (no idle logistic robot for 10 min); science_idle (a pack the research needs whose makers on the science surface all stood still at two science-line builds 5+ min apart, with their states and the chain\'s first short step); on Fulgora: lightning_unconnected (lightning attractors no pole reaches), lightning_unused (attractors in a network with no accumulator and nothing drawing power in the last minute), lightning_storage_full (a network with attractors whose accumulators are at 99% or more); or a game alert type such as no_material_for_construction, not_enough_construction_robots, not_enough_repair_packs, no_storage, train_out_of_fuel, unclaimed_cargo, collector_path_blocked)',
      returns='groups worst first: {kind, surface, count, center, names, at (up to 4 positions), line, to (who the team block tells: claim, built, nearest)}; scanned (the scan is at most 30 s old). What a player\'s alert panel and status icons show; new or worsening groups also come in team.alerts (one digest per 150 s). Read only'},
  }
  return M
end
