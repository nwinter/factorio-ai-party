-- flight_watch {platform, from?, minutes?} (d21 batch72 AH1, Sol #1720: Kestrel IVc's platform read gave 1 turret empty at
-- tick 43697882 and platform_defense 370 ticks later all 11 armed; reads that far apart tell neither how long nor which
-- turret). A bounded watch on one platform, from now or from its next departure, to its next arrival or a time limit,
-- read once a second as a player watching the platform would:
-- - each ammo turret (unit_number, position): the least ammunition seen in its slots, the samples and ticks it read
--   empty, its longest run of empty samples and when that began; its feed (ammofeed.lua's trace: maker, hub, chest,
--   preload or none, how much can reach it, what stops or gates its way) at the start, from the first trace begun
--   after it first read empty, and at the end;
-- - damage taken (platalerts.lua's running totals of hits by other forces), entities lost (lostlog.lua), repair packs
--   used (the platform's item production statistics, consumed) and the hub's packs at the start and the end;
-- - thruster fuel and oxidizer held (thrusters and tanks; endurance.lua's fuel outlook) at the start and the end.
-- (d22 batch98 BH1, Astra #1900: proof that every railgun recharges under load) each sample also reads the platform's
-- accumulators together (their energy over their buffers: the least fraction, at the start, now) and each ammo turret
-- with an electric buffer (railguns): its energy (least, at the start, now) and the samples it read below one shot's
-- energy, as empty runs are kept. 2.0.77 gives no energy_per_shot on the prototype; a railgun's is its 10 MJ buffer in
-- the game's data (railgun-turret: buffer_capacity 10MJ, energy_per_shot 10MJ), so below means under its buffer. Its
-- hits, damage and kills come from on_entity_damaged and on_entity_died with it as cause (as asteroidwatch.lua reads
-- them); shots that hit are the ticks it hit something (a railgun shot hits everything on its line in one tick).
-- Kept in storage (a save keeps it) until cleared; a result read is kept KEEP_READ ticks after its first read. The
-- setter hears in team.alerts when a watch begins after a departure and when it ends.
-- (d22 batch109 BS1, Sol #1952: 8 a force kept Cinder's watch out while 18 platforms flew) a force may hold one watch
-- that counts per platform it has: armed, watching, or done with its result not read yet. A done one read no longer
-- counts (kept KEEP_READ, at most KEEP_DONE a force). Each watch reads on its own tick of the second (its phase).
-- (d22 batch116 BY1, Astra #1968: a queue's return-leg watch at the edge turnaround replaces the outbound one) a replace
-- keeps the watch it replaces readable by id: a done one as it ended, a watching one ended there (replaced by #N); it
-- no longer counts and is kept WAIT unless read (then KEEP_READ after the read). An armed one, nothing read yet, is
-- dropped.
return function(api)
  local M = {}
  M.EVERY, M.MAX_TURRETS, M.KEEP_READ, M.WAIT, M.REFIND = 60, 128, 216000, 5184000, 3600
  M.PHASE, M.KEEP_DONE = 51, 16  -- the first watch's tick of the second; done watches read kept a force
  M.SHOW = 24             -- turret rows in a read
  M.FEED_EVERY, M.FEED_SOON = 3600, 600  -- a feed trace asked once a minute a watch; 10 s after a turret begins to read empty
  -- (BS1) on a large platform the trace is asked once every FEED_TICKS_PER_BELT ticks a belt aboard if that is longer: on
  -- a copy of world n a trace cost about 0.06 ms a belt (Asterion's 6743: 79 ms to begin, 27 steps, 113 ms to end), so
  -- each watch's traces stay near 0.5 ms a second
  M.MAX_MIN, M.DEFAULT_MIN, M.EVENTS, M.FEED_TICKS_PER_BELT = 480, 120, 32, 7
  M.MAX_ACCUMULATORS, M.SHOW_POWERED = 1024, 64
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function at(q) return string.format('(%g,%g)', q.x, q.y) end
  local function secs(t)
    local s = math.max(0, math.floor(t / 60 + 0.5))
    if s >= 3600 then return string.format('%dh%02dm%02ds', math.floor(s / 3600), math.floor(s / 60) % 60, s % 60) end
    return s >= 60 and string.format('%dm%02ds', math.floor(s / 60), s % 60) or s .. 's'
  end
  local function store()
    local s = api.state()
    s.flightwatch = s.flightwatch or {seq=0, list={}, events={}, eseq=0}
    return s.flightwatch
  end
  local function push(w, text)
    local st = store()
    st.eseq = st.eseq + 1
    st.events[#st.events+1] = {id=st.eseq, to=w.setter, text=text}
    while #st.events > M.EVENTS do table.remove(st.events, 1) end
  end
  local function platform_of(w)
    local pl = w.pl
    if pl and pl.valid then return pl end
    local f = game.forces[w.force]
    pl = f and try(function() return f.platforms[w.index] end)
    if pl and pl.valid then w.pl = pl; return pl end
  end
  local function flying(pl) return try(function() return pl.state == defines.space_platform_state.on_the_path and pl.space_connection ~= nil end) or false end
  -- Where it is: its location, else the leg it flies the way it flies it (freight.lua's leg: a connection flown back
  -- reads the same from and to).
  local function where(pl)
    local loc = try(function() return pl.space_location.name end)
    if loc then return loc end
    local l = api.leg and try(function() return api.leg(pl) end)
    if l then return l.from .. '->' .. l.to end
    return try(function() return pl.space_connection.from.name .. '->' .. pl.space_connection.to.name end) or '?'
  end
  local function ammo_of(e)
    local inv = try(function() return e.get_inventory(defines.inventory.turret_ammo) end)
    if not inv then return nil end
    local n = try(function() return inv.get_item_count() end)
    if not n then return nil end
    local name
    if n > 0 then name = try(function() return inv[1].valid_for_read and inv[1].name end) or nil end
    return n, name
  end
  -- The repair tool item names (prototypes do not change while the game runs).
  local REPAIR, IS_REPAIR
  local function repair_names()
    if not REPAIR then
      REPAIR, IS_REPAIR = {}, {}
      for name, it in pairs(prototypes.item) do if it.type == 'repair-tool' then REPAIR[#REPAIR+1] = name; IS_REPAIR[name] = true end end
    end
    return REPAIR
  end
  local function repair_used(pl)
    local stats = try(function() return pl.force.get_item_production_statistics(pl.surface) end)
    if not stats then return nil end
    local n = 0
    for _, name in ipairs(repair_names()) do n = n + (try(function() return stats.get_output_count(name) end) or 0) end
    return n
  end
  local function hub_packs(pl)
    local inv = try(function() return pl.hub.get_inventory(defines.inventory.hub_main) end)
    local n = 0
    repair_names()
    for _, st in ipairs(inv and try(function() return inv.get_contents() end) or {}) do
      if IS_REPAIR[st.name] then n = n + st.count end
    end
    return n
  end
  -- (BS1) the fuel held alone (the fuel outlook's statistics, leg and speed were 12 of a 17.5 ms list of 18 watches)
  local function fuel(pl)
    if api.fuel_held then return try(function() return api.fuel_held(pl) end) or {} end
    local o = api.fuel_outlook and try(function() return api.fuel_outlook(pl) end)
    local out = {}
    for _, r in ipairs(o and o.rows or {}) do out[r.name] = {held=r.held, in_tanks=r.in_tanks} end
    return out
  end
  local function copy(t) local o = {}; for k, v in pairs(t or {}) do o[k] = v end; return o end
  local function hits(pl)
    local t = api.hits and try(function() return api.hits(pl) end)
    return {hits=t and t.hits or 0, damage=t and t.damage or 0, entities=copy(t and t.entities), by=copy(t and t.by)}
  end
  -- A turret's feed from a trace row (ammofeed.lua): {kind, gated, reaches, stop, tick}.
  local function feed_of(row, tr)
    local kind, gated = api.supply_kind(row)
    local stop = (row.stops or {})[1] or (row.gated or {})[1]
    return {kind=kind, gated=gated or nil, reaches=row.reaches, stop=stop, tick=tr.read_tick}
  end
  function M.feed_text(f)
    if not f then return 'not traced' end
    return string.format('%s%s, %d can reach it%s', f.kind, f.gated and ' (every such source gated closed)' or '', f.reaches or 0, f.stop and '; ' .. f.stop or '')
  end
  local function add_turret(w, e, tick)
    if #w.turrets >= M.MAX_TURRETS then w.capped = true; return end
    local n, name = ammo_of(e)
    local t = {e=e, unit=e.unit_number, name=e.name, position={x=e.position.x, y=e.position.y}, min=n, min_tick=tick,
      first=n, now=n, ammo=name, empty_samples=0, empty_ticks=0, runs=0, longest=0, added=tick ~= w.start and tick or nil}
    w.turrets[#w.turrets+1] = t
    w.by_unit[e.unit_number] = #w.turrets
    -- (BH1) a turret with an electric buffer (a railgun): its energy, and what it hit
    local buf = try(function() return e.electric_buffer_size end) or 0
    if buf > 0 then
      local en = try(function() return e.energy end) or 0
      t.buffer, t.emin, t.emin_tick, t.efirst, t.enow = buf, en, tick, en, en
      t.low_samples, t.low_ticks, t.low_runs, t.low_longest = 0, 0, 0, 0
      t.hits, t.shots, t.damage, t.kills = 0, 0, 0, 0
      local st = store()
      st.powered = st.powered or {}
      st.powered[e.unit_number] = true
    end
  end
  -- (BH1) the platform's accumulators, found at the start and each minute with the turrets
  local function find_accumulators(w, pl)
    local list = try(function() return pl.surface.find_entities_filtered{type='accumulator', force=pl.force, limit=M.MAX_ACCUMULATORS + 1} end) or {}
    w.acc_capped = #list > M.MAX_ACCUMULATORS or nil
    local accs, cap = {}, 0
    for i = 1, math.min(#list, M.MAX_ACCUMULATORS) do
      local e = list[i]
      local b = try(function() return e.electric_buffer_size end) or 0
      if b > 0 then accs[#accs+1] = e; cap = cap + b end
    end
    w.accs, w.acc_cap = accs, cap
  end
  local function acc_fraction(w)
    if not w.accs or #w.accs == 0 or w.acc_cap <= 0 then return nil end
    local n, cap = 0, 0
    for _, e in ipairs(w.accs) do
      if e.valid then n = n + e.energy; cap = cap + e.electric_buffer_size end
    end
    return cap > 0 and n / cap or nil
  end
  local function find_turrets(w, pl, tick)
    for _, e in ipairs(try(function() return pl.surface.find_entities_filtered{type='ammo-turret', force=pl.force} end) or {}) do
      if e.unit_number and not w.by_unit[e.unit_number] then add_turret(w, e, tick) end
    end
    find_accumulators(w, pl)
    w.acc_n = #w.accs
    w.refound = tick
  end
  -- The trace's rows into each turret's feed: at the start, after it first read empty (the first trace begun since),
  -- and the latest (the end).
  -- want: a turret began to read empty; a trace is asked 10 s after the last ask, else a minute after (or FEED_TICKS_PER_BELT
  -- ticks a belt). (BS1) A trace done since the last one taken is taken at the next sample; a platform with no ammo turret
  -- asks none.
  local function take_feed(w, pl, tick, want)
    if want then w.want = w.want or tick end
    if not api.trace or #(w.turrets or {}) == 0 then return end
    local gap = w.want and M.FEED_SOON or math.max(M.FEED_EVERY, (w.belts or 0) * M.FEED_TICKS_PER_BELT)
    local due = not w.asked or tick - w.asked >= gap
    if not due then
      local d = api.trace_done and try(function() return api.trace_done(pl) end)
      if not (d and d ~= w.feed_seen) then return end
    end
    local tr = try(function() return api.trace(pl, due and gap or math.huge) end)
    if due then w.asked = tick end
    if not (tr and tr.rows and tr.read_tick) then return end
    w.belts = tr.belts or w.belts
    if w.feed_seen == tr.read_tick then return end
    w.feed_seen = tr.read_tick
    if w.want and (tr.read_started or tr.read_tick) >= w.want then w.want = nil end
    for _, row in ipairs(tr.rows) do
      local un = try(function() return row.entity.unit_number end)
      local i = un and w.by_unit[un]
      local t = i and w.turrets[i]
      if t then
        local f = feed_of(row, tr)
        if not t.feed_start and (tr.read_started or tr.read_tick) >= w.start - M.FEED_EVERY then t.feed_start = f end
        if t.first_empty and not t.feed_empty and (tr.read_started or tr.read_tick) >= t.first_empty then t.feed_empty = f end
        t.feed_last = f
      end
    end
  end
  local function begin(w, pl, tick)
    w.state, w.start, w.until_tick = 'watching', tick, tick + w.minutes * 3600
    w.leg = where(pl)
    w.at_start, w.flew = w.leg, flying(pl)
    w.turrets, w.by_unit = {}, {}
    find_turrets(w, pl, tick)
    local f = acc_fraction(w)
    w.acc = {first=f, min=f, min_tick=tick, now=f}
    w.acc_n = #(w.accs or {})
    w.hits0, w.fuel0, w.repair0, w.packs0 = hits(pl), fuel(pl), repair_used(pl), hub_packs(pl)
    w.samples, w.last_sample = 0, tick - M.EVERY
    w.asked = nil
    take_feed(w, pl, tick, false)
  end
  local function diff(a, b, limit)
    local list = {}
    for k, v in pairs(b or {}) do
      local d = v - ((a or {})[k] or 0)
      if d > 0 then list[#list+1] = {k, d} end
    end
    table.sort(list, function(x, y) if x[2] ~= y[2] then return x[2] > y[2] end return x[1] < y[1] end)
    local out = {}
    for i = 1, math.min(limit, #list) do out[i] = string.format('%s %g', list[i][1], math.floor(list[i][2] * 10 + 0.5) / 10) end
    if #list > limit then out[#out+1] = '+' .. (#list - limit) .. ' more' end
    return out
  end
  -- What the watch holds now, from its start to tick (the end tick once done): damage, losses, repair packs, fuel.
  local function totals(w, pl, tick)
    local h0 = w.hits0
    local h1 = pl and hits(pl) or w.hits1 or h0
    local dmg = {hits=h1.hits - h0.hits, damage=math.floor((h1.damage - h0.damage) * 10 + 0.5) / 10, entities=diff(h0.entities, h1.entities, 5), by=diff(h0.by, h1.by, 5)}
    local lost, n
    if pl and api.losses then
      local rows
      rows, n = api.losses(w.force, pl.surface.name, w.start - 1)
      lost = {}
      for _, r in ipairs(rows or {}) do
        if r.t <= tick and #lost < 8 then lost[#lost+1] = string.format('%s (%g,%g) at +%s%s', r.n, r.x, r.y, secs(r.t - w.start), r.c and ' by ' .. r.c or '') end
      end
    else lost, n = w.lost or {}, w.lost_n or 0 end
    local r1 = pl and repair_used(pl) or w.repair1
    local p1 = pl and hub_packs(pl) or w.packs1
    local f1 = pl and fuel(pl) or w.fuel1
    return {damage=dmg, lost=lost, lost_n=n or 0, repair_used=w.repair0 and r1 and r1 - w.repair0 or nil, packs_start=w.packs0, packs_end=p1,
      fuel_start=w.fuel0, fuel_end=f1, h1=h1, r1=r1}
  end
  local function finish(w, pl, tick, why)
    if pl then
      take_feed(w, pl, tick, false)
      local t = totals(w, pl, tick)
      w.hits1, w.lost, w.lost_n, w.repair1, w.packs1, w.fuel1 = t.h1, t.lost, t.lost_n, t.r1, t.packs_end, t.fuel_end
    end
    w.state, w.ended, w.why = 'done', tick, why
    for _, t in ipairs(w.turrets or {}) do t.e = nil end
    w.accs, w.pl = nil, nil
    M.reindex()
    if not w.start then push(w, string.format('flight watch #%d on %s ended before it began (%s)', w.id, w.platform, why)); return end
    push(w, string.format('flight watch #%d on %s ended (%s) after %s: %s%s; flight_watch {id: %d} reads it', w.id, w.platform, why, secs(tick - w.start), M.worst(w), M.power_text(w), w.id))
  end
  -- The turrets in one phrase: how many read empty, the longest run.
  function M.worst(w)
    local empty, long, lt = 0, 0, nil
    for _, t in ipairs(w.turrets or {}) do
      if t.empty_samples > 0 then empty = empty + 1 end
      if t.longest > long then long, lt = t.longest, t end
    end
    local n = #(w.turrets or {})
    if n == 0 then return 'no ammo turret aboard' end
    if empty == 0 then return string.format('none of %d ammo turrets read empty', n) end
    return string.format('%d of %d ammo turrets read empty; the longest run %gs (%d ticks), %s %s #%d from +%s', empty, n, math.floor(long / 6 + 0.5) / 10, long, lt.name, at(lt.position), lt.unit, secs(lt.long_from - w.start))
  end
  -- (BS1) a new watch's phase: the tick of the second fewest armed or watching watches read on, from PHASE in
  -- steps of 13 ticks
  local function pick_phase(st)
    local used = {}
    for _, w in ipairs(st.list) do if w.state ~= 'done' and w.phase then used[w.phase] = (used[w.phase] or 0) + 1 end end
    local best, bn
    for k = 0, M.EVERY - 1 do
      local ph = (M.PHASE + k * 13) % M.EVERY
      local n = used[ph] or 0
      if not bn or n < bn then best, bn = ph, n end
      if n == 0 then break end
    end
    return best
  end
  -- (BH1) the units of the powered turrets watched now, for the damage events' quick test; (BS1) the phases read on
  function M.reindex()
    local st = api.state().flightwatch
    if not st then return end
    local idx, due = {}, {[M.PHASE]=true}
    for _, w in ipairs(st.list) do
      if w.state ~= 'done' then
        w.phase = w.phase or pick_phase(st)
        due[w.phase] = true
      end
      if w.state == 'watching' then
        for _, t in ipairs(w.turrets or {}) do if t.buffer and t.e then idx[t.unit] = true end end
      end
    end
    st.powered = next(idx) and idx or nil
    st.due = due
  end
  -- Whether a watch reads on this tick (the tick hook asks each tick; PHASE always, to drop read ones past KEEP_READ).
  function M.due(tick)
    local st = api.state().flightwatch
    if not st or #st.list == 0 then return false end
    if not st.due then M.reindex() end
    return st.due[tick % M.EVERY] == true
  end
  -- (BS1) the watches that count against the force's limit (one per platform): armed, watching, done and not read.
  local function counts(w) return w.state ~= 'done' or not (w.read_tick or w.replaced_by) end
  function M.limit(force)
    local n = 0
    for _ in pairs(try(function() return force.platforms end) or {}) do n = n + 1 end
    return math.max(1, n)
  end
  local function counting(st, force)
    local list = {}
    for _, w in ipairs(st.list) do if w.force == force.name and counts(w) then list[#list+1] = w end end
    return list
  end
  local function counting_text(list)
    local out = {}
    for _, w in ipairs(list) do out[#out+1] = string.format('#%d %s (%s, %s)', w.id, w.platform, w.state == 'done' and 'done, not read' or w.state, tostring(w.setter)) end
    return #out > 0 and table.concat(out, ', ') or 'none'
  end
  local function powered_turret(st, unit)
    for _, w in ipairs(st.list) do
      if w.state == 'watching' and w.by_unit then
        local i = w.by_unit[unit]
        local t = i and w.turrets[i]
        if t and t.buffer then return t end
      end
    end
  end
  -- A hit by a watched powered turret on anything not of its force: its hits, damage, and shots that hit (ticks).
  function M.on_damaged(event)
    local st = api.state().flightwatch
    local idx = st and st.powered
    if not idx then return end
    local c = event.cause
    if not (c and c.valid) then return end
    local u = c.unit_number
    if not (u and idx[u]) then return end
    local e = event.entity
    if e and e.valid and e.force == c.force then return end
    local t = powered_turret(st, u)
    if not t then return end
    t.hits, t.damage = t.hits + 1, t.damage + (event.final_damage_amount or 0)
    if t.last_hit ~= event.tick then t.last_hit, t.shots = event.tick, t.shots + 1 end
  end
  function M.on_died(event)
    local st = api.state().flightwatch
    local idx = st and st.powered
    if not idx then return end
    local c = event.cause
    if not (c and c.valid) then return end
    local u = c.unit_number
    if not (u and idx[u]) then return end
    local t = powered_turret(st, u)
    if t then t.kills = t.kills + 1 end
  end
  local function pct(f) return f and string.format('%g%%', math.floor(f * 1000 + 0.5) / 10) or '?' end
  local function mj(j) return string.format('%g MJ', math.floor((j or 0) / 1e5 + 0.5) / 10) end
  -- The accumulators and the powered turrets in one phrase (empty when the platform has neither).
  function M.power_text(w)
    local parts = {}
    local a = w.acc
    if a and a.first then
      parts[#parts+1] = string.format('accumulators (%d%s): least %s at +%s, %s at the start, %s now', w.acc_n or #(w.accs or {}), w.acc_capped and ', capped' or '',
        pct(a.min), secs((a.min_tick or w.start) - w.start), pct(a.first), pct(a.now))
    end
    local n, low, hits, shots, dmg, kills, long, lt = 0, 0, 0, 0, 0, 0, 0, nil
    for _, t in ipairs(w.turrets or {}) do
      if t.buffer then
        n = n + 1
        if t.low_samples > 0 then low = low + 1 end
        hits, shots, dmg, kills = hits + t.hits, shots + t.shots, dmg + t.damage, kills + t.kills
        if t.low_longest > long then long, lt = t.low_longest, t end
      end
    end
    if n > 0 then
      parts[#parts+1] = string.format('%d powered turrets (railguns): %s; %d hits (%d shots that hit), %g damage, %d kills', n,
        low == 0 and 'none read below a shot\'s energy (its full buffer)' or string.format('%d read below a shot\'s energy (its full buffer) in some sample, the longest run %gs (%d ticks), %s %s #%d from +%s',
          low, math.floor(long / 6 + 0.5) / 10, long, lt.name, at(lt.position), lt.unit, secs(lt.low_long_from - w.start)),
        hits, shots, math.floor(dmg + 0.5), kills)
    end
    return #parts > 0 and '; ' .. table.concat(parts, '; ') or ''
  end
  -- One sample of a watching watch.
  local function sample(w, pl, tick)
    local dt = tick - w.last_sample
    w.last_sample, w.samples = tick, w.samples + 1
    if tick - (w.refound or 0) >= M.REFIND then find_turrets(w, pl, tick) end
    local new_run = false
    for _, t in ipairs(w.turrets) do
      if t.e and t.e.valid then
        local n, name = ammo_of(t.e)
        if n then
          t.now = n
          if name then t.ammo = name end
          if not t.min or n < t.min then t.min, t.min_tick = n, tick end
          if n == 0 then
            t.empty_samples, t.empty_ticks = t.empty_samples + 1, t.empty_ticks + dt
            if not t.run_from then
              t.run_from, t.run, t.runs, t.first_empty = tick, 0, t.runs + 1, t.first_empty or tick
              new_run = new_run or not t.feed_empty
            end
            t.run = t.run + dt
            if t.run > t.longest then t.longest, t.long_from = t.run, t.run_from end
          elseif t.run_from then t.run_from, t.run = nil, nil end
        end
        if t.buffer then
          local en = t.e.energy
          t.enow = en
          if en < t.emin then t.emin, t.emin_tick = en, tick end
          if en < t.buffer then
            t.low_samples, t.low_ticks = t.low_samples + 1, t.low_ticks + dt
            if not t.low_from then t.low_from, t.low_run, t.low_runs = tick, 0, t.low_runs + 1 end
            t.low_run = t.low_run + dt
            if t.low_run > t.low_longest then t.low_longest, t.low_long_from = t.low_run, t.low_from end
          elseif t.low_from then t.low_from, t.low_run = nil, nil end
        end
      elseif t.e then t.gone, t.e = tick, nil end
    end
    local f = acc_fraction(w)
    if f and w.acc then
      w.acc.now = f
      if not w.acc.min or f < w.acc.min then w.acc.min, w.acc.min_tick = f, tick end
      w.acc.first = w.acc.first or f
    end
    take_feed(w, pl, tick, new_run)
  end
  function M.tick(tick)
    local st = api.state().flightwatch
    if not st then return end
    for i = #st.list, 1, -1 do
      local w = st.list[i]
      if w.state == 'done' and (w.read_tick and tick - w.read_tick > M.KEEP_READ or not w.read_tick and w.replaced_tick and tick - w.replaced_tick > M.WAIT) then table.remove(st.list, i) end
    end
    if not st.due then M.reindex() end
    local ph = tick % M.EVERY
    for _, w in ipairs(st.list) do
      if w.state ~= 'done' and w.phase == ph then
        local pl = platform_of(w)
        if not (pl and pl.surface) then finish(w, nil, tick, 'the platform is gone')
        elseif w.state == 'armed' then
          local f = flying(pl)
          if not f then w.seen_stopped = true
          elseif w.seen_stopped then
            begin(w, pl, tick)
            push(w, string.format('flight watch #%d on %s began: it left for %s', w.id, w.platform, w.leg))
          end
          if w.state == 'armed' and tick - w.set > M.WAIT then finish(w, nil, tick, 'no departure within 24h') end
        else
          local f = flying(pl)
          sample(w, pl, tick)
          -- started while stopped: the leg it flies once it leaves
          if f and not w.flew then w.flew = true; w.leg = where(pl) end
          if w.flew and not f and try(function() return pl.space_location end) then finish(w, pl, tick, 'arrived at ' .. where(pl))
          elseif tick >= w.until_tick then finish(w, pl, tick, 'its time limit, ' .. w.minutes .. ' min') end
        end
      end
    end
  end
  local function fuel_text(a, b)
    local parts = {}
    for _, n in ipairs({'thruster-fuel', 'thruster-oxidizer'}) do
      local x, y = a and a[n], b and b[n]
      if x or y then parts[#parts+1] = string.format('%s %s -> %s', n, x and x.held or '?', y and y.held or '?') end
    end
    return #parts > 0 and table.concat(parts, ', ') or 'no thruster fluid read'
  end
  function M.row(w, full)
    local r = {id=w.id, platform=w.platform, setter=w.setter, state=w.state, from=w.from, minutes=w.minutes, set_tick=w.set,
      start_tick=w.start, end_tick=w.ended, until_tick=w.until_tick, ended_by=w.why, leg=w.leg, at_start=w.at_start ~= w.leg and w.at_start or nil,
      replaced_by=w.replaced_by, replaced_tick=w.replaced_tick}
    if w.state == 'armed' then
      r.line = string.format('flight watch #%d on %s: waiting for its next departure (set %s ago)', w.id, w.platform, secs(game.tick - w.set))
      return r
    end
    if not w.start then
      r.line = string.format('flight watch #%d on %s: ended before it began (%s)', w.id, w.platform, tostring(w.why))
      return r
    end
    local now = w.ended or game.tick
    local pl = w.state ~= 'done' and platform_of(w) or nil
    local t = totals(w, pl, now)
    r.samples, r.seconds = w.samples, math.floor((now - w.start) / 60 + 0.5)
    r.damage, r.lost, r.lost_count, r.repair_packs_used, r.hub_repair_packs = t.damage, t.lost, t.lost_n, t.repair_used, {start=t.packs_start, ['end']=t.packs_end}
    r.fuel = {start=t.fuel_start, ['end']=t.fuel_end}
    r.turrets_capped = w.capped and M.MAX_TURRETS or nil
    -- (the read's size) the turrets that read empty, the longest run first, then the lowest on ammo: SHOW rows
    local order = {}
    for _, x in ipairs(full and w.turrets or {}) do order[#order+1] = x end
    table.sort(order, function(a, b)
      if a.longest ~= b.longest then return a.longest > b.longest end
      if (a.min or 0) ~= (b.min or 0) then return (a.min or 0) < (b.min or 0) end
      return a.unit < b.unit
    end)
    local rest, rest_least = 0, nil
    for i = M.SHOW + 1, #order do
      rest = rest + 1
      if order[i].min and (not rest_least or order[i].min < rest_least) then rest_least = order[i].min end
    end
    if rest > 0 then
      r.turrets_more = rest
      r.turrets_more_line = string.format('%d more ammo turrets, none read empty, the least ammunition among them %s', rest, tostring(rest_least))
    end
    local rows, lines = {}, {}
    for i = 1, math.min(#order, M.SHOW) do
      local x = order[i]
      local row = {unit_number=x.unit, name=x.name, position=x.position, ammo=x.ammo, least=x.min, least_tick=x.min_tick, at_start=x.first, now=x.now,
        empty_samples=x.empty_samples, empty_ticks=x.empty_ticks, empty_runs=x.runs, longest_empty_ticks=x.longest,
        longest_from_tick=x.long_from, empty_now=x.run_from and true or nil, gone_tick=x.gone, added_tick=x.added,
        feed_start=x.feed_start, feed_empty=x.feed_empty, feed_end=x.feed_last}
      rows[#rows+1] = row
      lines[#lines+1] = string.format('%s %s #%d: least %s (at +%s), %s; %s%s; feed at the start: %s%s; latest: %s', x.name, at(x.position), x.unit,
        x.min and tostring(x.min) or '?', secs((x.min_tick or w.start) - w.start), x.min and x.min > 0 and 'never empty' or
          string.format('empty in %d sample%s (%d ticks) over %d run%s, the longest %d ticks from +%s', x.empty_samples, x.empty_samples == 1 and '' or 's', x.empty_ticks, x.runs, x.runs == 1 and '' or 's', x.longest, secs((x.long_from or w.start) - w.start)),
        string.format('%s at the start, %s now', tostring(x.first), tostring(x.now)), x.gone and string.format('; gone at +%s', secs(x.gone - w.start)) or (x.added and string.format('; built at +%s', secs(x.added - w.start)) or ''),
        M.feed_text(x.feed_start), x.feed_empty and '; after it first read empty: ' .. M.feed_text(x.feed_empty) or '', M.feed_text(x.feed_last))
    end
    if full then r.turrets, r.lines = rows, lines end
    -- (BH1) the sample interval, the accumulators together, and each powered turret (railgun)
    r.sample_ticks = M.EVERY
    if w.acc and w.acc.first then
      local q = function(f) return f and math.floor(f * 10000 + 0.5) / 10000 or nil end
      r.accumulators = {count=w.acc_n, capped=w.acc_capped and M.MAX_ACCUMULATORS or nil, least_fraction=q(w.acc.min), least_tick=w.acc.min_tick,
        at_start=q(w.acc.first), now=q(w.acc.now)}
    end
    if full then
      local pw = {}
      for _, x in ipairs(w.turrets or {}) do if x.buffer then pw[#pw+1] = x end end
      table.sort(pw, function(a, b)
        if a.low_longest ~= b.low_longest then return a.low_longest > b.low_longest end
        if a.emin ~= b.emin then return a.emin < b.emin end
        return a.unit < b.unit
      end)
      local prow, plines = {}, {}
      for i = 1, math.min(#pw, M.SHOW_POWERED) do
        local x = pw[i]
        prow[#prow+1] = {unit_number=x.unit, name=x.name, position=x.position, shot_energy=x.buffer, least_energy=math.floor(x.emin), least_tick=x.emin_tick,
          energy_at_start=math.floor(x.efirst), energy_now=math.floor(x.enow), below_samples=x.low_samples, below_ticks=x.low_ticks, below_runs=x.low_runs,
          longest_below_ticks=x.low_longest, longest_below_from_tick=x.low_long_from, below_now=x.low_from and true or nil,
          hits=x.hits, shots_hit=x.shots, damage=math.floor(x.damage * 10 + 0.5) / 10, kills=x.kills, gone_tick=x.gone}
        plines[#plines+1] = string.format('%s %s #%d: energy least %s (%s of a shot) at +%s, %s at the start, %s now; %s; %d hits (%d shots that hit), %g damage, %d kills', x.name, at(x.position), x.unit,
          mj(x.emin), pct(x.emin / x.buffer), secs((x.emin_tick or w.start) - w.start), mj(x.efirst), mj(x.enow),
          x.low_samples == 0 and 'never below a shot\'s energy in a sample' or string.format('below a shot\'s energy in %d sample%s (%d ticks) over %d run%s, the longest %d ticks from +%s',
            x.low_samples, x.low_samples == 1 and '' or 's', x.low_ticks, x.low_runs, x.low_runs == 1 and '' or 's', x.low_longest, secs((x.low_long_from or w.start) - w.start)),
          x.hits, x.shots, math.floor(x.damage + 0.5), x.kills)
      end
      if #pw > 0 then r.railguns, r.railgun_lines, r.railguns_more = prow, plines, #pw > M.SHOW_POWERED and #pw - M.SHOW_POWERED or nil end
    end
    r.line = string.format('flight watch #%d on %s, %s: %s for %s (%d samples, one every %d ticks)%s; %s%s; damage taken %g in %d hit%s%s; %d lost; repair packs used %s (hub %s -> %s); %s',
      w.id, w.platform, w.leg or '?', w.state == 'done' and 'watched' or 'watching', secs(now - w.start), w.samples or 0, M.EVERY,
      w.state == 'done' and ', ended: ' .. tostring(w.why) or string.format(', until its arrival or %s more', secs(w.until_tick - now)), M.worst(w), M.power_text(w),
      t.damage.damage, t.damage.hits, t.damage.hits == 1 and '' or 's', #t.damage.entities > 0 and ' (' .. table.concat(t.damage.entities, ', ') .. ')' or '', t.lost_n,
      t.repair_used and tostring(t.repair_used) or '?', tostring(t.packs_start), tostring(t.packs_end), fuel_text(t.fuel_start, t.fuel_end))
    -- (d23 batch123 CF2) an edit aboard while it watched: the part before it, kept apart (mixed.lua)
    if w.mixed then r.mixed = api.mixed_view and api.mixed_view(w) or nil; r.line = r.line .. '; ' .. w.mixed.line end
    return r
  end
  -- (d23 batch123 CF2) an edit aboard while it watches (mixed.lua): the read so far, then its counts begun again from
  -- tick to the same end (its arrival, or the limit it had).
  function M.rebase(w, tick)
    local pl = platform_of(w)
    assert(pl and pl.valid, 'its platform is gone')
    local before = M.row(w, true)
    local until_tick = w.until_tick
    begin(w, pl, tick)
    w.until_tick = until_tick
    M.reindex()
    return before
  end
  M.NOTE = 'read once a second (sample_ticks): an empty run is the samples in a row that read 0 in the turret\'s ammo slots, each counting the ticks since the sample before, so a turret empty for under a second between two samples can be missed; '
    .. 'feed: the platform\'s ammunition trace (maker, hub, chest, preload: only what is on its way now, none: no inserter feeds it), asked at most once a minute (on a platform of over 514 belts once every 7 ticks a belt: 6743 belts, about 13 min), taken once read, and asked again 10 s after the last ask when a turret begins to read empty (feed_empty: the first trace begun after it first read empty, empty or refilled by then); none on a platform with no ammo turret; each watch reads on its own tick of the second; '
    .. 'damage: hits on our entities aboard by other forces; repair packs used: the platform\'s item production statistics, consumed; '
    .. 'accumulators: their energy over their buffers together, each sample; railguns (ammo turrets with an electric buffer): energy each sample, below a shot\'s energy meaning under its full buffer (2.0.77 gives no energy_per_shot; the game\'s data has 10 MJ a shot and a 10 MJ buffer, filled at most 10 MW), so a recharge shorter than a second between two samples can be missed; '
    .. 'hits, damage and kills from the game\'s damage and death events with the railgun as cause, shots_hit the ticks it hit something (one shot hits all on its line in one tick; a shot that hits nothing is not counted)'
  function M.call(p, a)
    local st = store()
    local who = api.who and api.who(p) or p.name
    if a.id ~= nil then
      assert(type(a.id) == 'number', 'id: a watch\'s number (flight_watch {} lists them)')
      for i, w in ipairs(st.list) do
        if w.id == a.id and w.force == p.force.name then
          if a.clear == true then table.remove(st.list, i); M.reindex(); return {cleared=a.id, line='flight watch #' .. a.id .. ' cleared'} end
          if w.state == 'done' and not w.read_tick then w.read_tick = game.tick end
          local r = M.row(w, true)
          r.note = M.NOTE
          return {watch=r, line=r.line}
        end
      end
      error('no flight watch #' .. tostring(a.id), 0)
    end
    if a.platform == nil then
      local rows, lines = {}, {}
      for _, w in ipairs(st.list) do
        if w.force == p.force.name then local r = M.row(w, false); r.counts = counts(w); rows[#rows+1] = r; lines[#lines+1] = r.line end
      end
      local lim, cl = M.limit(p.force), counting(st, p.force)
      local ids = {}
      for i, w in ipairs(cl) do ids[i] = w.id end
      return {watches=rows, lines=lines, limit=lim, counted=#cl, counting=ids,
        limit_line=string.format('%d of %d flight watches count against the force\'s limit (one per platform of the force): %s; a done watch stops counting once its result is read (flight_watch {id}) and is kept %s after', #cl, lim, counting_text(cl), secs(M.KEEP_READ)),
        note=#rows == 0 and 'no flight watch; start one with platform (and from, minutes)' or nil}
    end
    local pl = api.platform(p, a.platform)
    assert(pl.surface, 'platform ' .. pl.name .. ' has no surface yet')
    local from = a.from == nil and 'now' or a.from
    assert(from == 'now' or from == 'departure', 'from: "now" (default) or "departure" (its next departure)')
    local minutes = a.minutes == nil and M.DEFAULT_MIN or a.minutes
    assert(type(minutes) == 'number' and minutes >= 1 and minutes <= M.MAX_MIN and minutes == math.floor(minutes), 'minutes: 1..' .. M.MAX_MIN .. ' (default ' .. M.DEFAULT_MIN .. '), the longest it watches')
    local lim, cl = M.limit(p.force), counting(st, p.force)
    local rep
    for i, w in ipairs(cl) do if w.index == pl.index then rep = table.remove(cl, i); break end end
    -- a replace leaves the count as it was
    assert(rep or #cl < lim, string.format('the force has %d flight watches counting against its limit of %d (one per platform of the force): %s; end one with flight_watch {id, clear: true}, or read a done one (flight_watch {id}): read, it stops counting',
      #cl, lim, counting_text(cl)))
    local replaced, replaced_row, replaced_line
    if rep then
      assert(a.replace == true, string.format('flight watch #%d on %s is %s: read it (flight_watch {id: %d}), clear it, or give replace: true', rep.id, pl.name,
        rep.state == 'done' and 'done and not read' or rep.state, rep.id))
      replaced = rep.id
      -- (BY1) kept readable by id unless armed (nothing read yet)
      if rep.state == 'armed' then
        for i, w in ipairs(st.list) do if w == rep then table.remove(st.list, i); break end end
        replaced_line = string.format('flight watch #%d on %s was waiting for its next departure: dropped, nothing read yet', rep.id, rep.platform)
      else
        if rep.state ~= 'done' then finish(rep, platform_of(rep), game.tick, 'replaced by #' .. (st.seq + 1)) end
        rep.replaced_by, rep.replaced_tick = st.seq + 1, game.tick
        replaced_row = M.row(rep, false)
        replaced_line = string.format('flight watch #%d on %s (ended: %s) is kept: flight_watch {id: %d} reads it in full; it no longer counts against the limit; kept %s unless read, then %s after the read',
          rep.id, rep.platform, tostring(rep.why), rep.id, secs(M.WAIT), secs(M.KEEP_READ))
      end
      M.reindex()
    end
    -- done watches read or replaced: the oldest dropped past KEEP_DONE a force
    local read = {}
    for i, w in ipairs(st.list) do if w.force == p.force.name and not counts(w) then read[#read+1] = {i, w.read_tick or w.replaced_tick} end end
    table.sort(read, function(x, y) if x[2] ~= y[2] then return x[2] < y[2] end return x[1] < y[1] end)
    local drop = {}
    for k = 1, #read - M.KEEP_DONE + 1 do drop[read[k][1]] = true end
    for i = #st.list, 1, -1 do if drop[i] then table.remove(st.list, i) end end
    st.seq = st.seq + 1
    local w = {id=st.seq, platform=pl.name, index=pl.index, force=p.force.name, setter=who, set=game.tick, from=from, minutes=minutes, state='armed', pl=pl}
    w.phase = pick_phase(st)
    st.list[#st.list+1] = w
    if from == 'now' then begin(w, pl, game.tick); sample(w, pl, game.tick)
    else w.seen_stopped = not flying(pl) end
    M.reindex()
    local r = M.row(w, false)
    r.replaced = replaced
    local np = 0
    for _, t in ipairs(w.turrets or {}) do if t.buffer then np = np + 1 end end
    return {watch=r, replaced_watch=replaced_row, replaced_line=replaced_line, line=from == 'now' and string.format('flight watch #%d on %s: watching %d ammo turrets (%d railguns) and %d accumulators once a second from now until its next arrival or %d min', w.id, pl.name, #w.turrets, np, w.acc_n or 0, minutes)
      or string.format('flight watch #%d on %s: begins at its next departure%s and runs until the arrival after it or %d min', w.id, pl.name, w.seen_stopped and '' or ' (it flies now: the departure after its next stop)', minutes),
      note=M.NOTE}
  end
  -- (d22 batch99 BI5, viewer Aurora site:4333: "Asterion still shows stalled while Astra's timed flight watch is
  -- running") the setter's flight watches for its card and its projects (status {brief, work}), as measures.card rows:
  -- armed (waiting for the departure) or running, and done until its result is read; end_tick is the time limit.
  function M.card(who)
    local st = api.state().flightwatch
    if not st then return nil end
    local out = {}
    for _, w in ipairs(st.list) do
      if w.setter == who and counts(w) then
        -- its line from the record alone (M.row reads the platform: not for a poll)
        local line = w.state == 'armed' and string.format('flight watch #%d on %s: waiting for its next departure, then at most %d min', w.id, w.platform, w.minutes)
          or w.state == 'watching' and string.format('flight watch #%d on %s: watching until its next arrival or tick %d (%s more), %d samples', w.id, w.platform,
            w.until_tick, secs(w.until_tick - game.tick), w.samples or 0)
          or string.format('flight watch #%d on %s: ended (%s), its result not read yet', w.id, w.platform, tostring(w.why))
        out[#out+1] = {id='flight#' .. w.id, kind='flight_watch', scope=w.platform, state=w.state == 'watching' and 'running' or w.state,
          start_tick=w.start, end_tick=w.until_tick, minutes=w.minutes, line=line}
      end
    end
    return #out > 0 and out or nil
  end
  -- team.alerts lines for agent p: its watches' beginnings and ends since it last heard (h: its hint state).
  function M.lines(p, h)
    local st = api.state().flightwatch
    if not st or #st.events == 0 then return nil end
    local me = api.who and api.who(p) or p.name
    local out = {}
    for _, e in ipairs(st.events) do
      if e.id > (h.flightwatch_seen or 0) and e.to == me then out[#out+1] = e.text end
    end
    h.flightwatch_seen = st.eseq
    return #out > 0 and out or nil
  end
  M.schema = {flight_watch = {platform='a platform of ours: start a watch on it', from='optional "now" (default) or "departure": begin at its next departure',
    minutes='optional 1..480 (default 120): the longest it watches; it ends sooner at the platform\'s next arrival after it flew', replace='optional true: replace this platform\'s watch running or not read yet; the replaced one stays readable by id (a running one ends there, replaced by #N; an armed one is dropped) and no longer counts',
    id='alone: read that watch in full (a done one is then kept 1 h and no longer counts against the limit); with clear: true, drop it', clear='true, with id: drop it',
    returns='start: watch, line, note, and on a replace replaced_watch (its row: id, state, ended_by, end_tick, replaced_by, line) and replaced_line; {}: watches (the force\'s, each with counts: whether it counts against the limit), lines, limit, counted, counting (the ids that count), limit_line; id: watch {id, platform, setter, state (armed: waiting for the departure, watching, done), from, minutes, set_tick, start_tick, end_tick, until_tick, ended_by, replaced_by, replaced_tick, leg, samples, seconds, '
      .. 'turrets (up to 24: those that read empty, the longest run first, then the lowest on ammo; turrets_more and turrets_more_line count the rest) [{unit_number, name, position, ammo, least, least_tick, at_start, now, empty_samples, empty_ticks, empty_runs, longest_empty_ticks, longest_from_tick, empty_now, gone_tick, added_tick, feed_start, feed_empty (the first trace begun after it first read empty), feed_end: {kind (maker, hub, chest, preload, none), gated, reaches, stop, tick}}], '
      .. 'sample_ticks, accumulators {count, capped, least_fraction, least_tick, at_start, now}, railguns (ammo turrets with an electric buffer, up to 64, the longest run below a shot\'s energy first) [{unit_number, name, position, shot_energy, least_energy, least_tick, energy_at_start, energy_now, below_samples, below_ticks, below_runs, longest_below_ticks, longest_below_from_tick, below_now, hits, shots_hit, damage, kills, gone_tick}], railgun_lines, '
      .. 'damage {hits, damage, entities (damage by entity name), by (hits by cause)}, lost (up to 8), lost_count, repair_packs_used, hub_repair_packs {start, end}, fuel {start, end: {thruster-fuel, thruster-oxidizer: {held, in_tanks}}}, lines, line, note}. '
      .. 'Sampled once a second, each watch on its own tick; at most 128 ammo turrets a watch (turrets built meanwhile are added within a minute); one watch that counts per platform of the force (armed, watching, or done and not read; a start at the limit is refused, naming them); kept in the save until cleared (read done ones 1 h after the read, replaced ones not read 24 h, at most 16 of those); the setter hears in team.alerts when one begins at a departure and when one ends'}}
  return M
end
