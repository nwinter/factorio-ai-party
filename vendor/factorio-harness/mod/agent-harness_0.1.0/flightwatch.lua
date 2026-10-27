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
-- (d24 batch151 PW1, Astra #2178: Asterion's 20 rare lasers fought and the watch read only its 23 railguns) each
-- laser turret (an electric turret whose ammo category is laser) its own category: its energy each sample (least, at the
-- start, now), the samples below one shot's energy, as the railguns' are kept, and its kills and damage dealt over the
-- watch (LuaEntity.kills and damage_dealt, turret_tally's reads: each sample's less the start's). 2.0.77 gives the
-- shot's energy as the prototype's attack_parameters.ammo_type.energy_consumption (800 kJ, a buffer of 801 kJ) and no
-- getter by quality; on a copy of world n a rare laser on Asterion fired from 801 kJ to 256.6 kJ in one tick and
-- recharged 255.6 kJ a tick (800 kJ a shot, its quality's faster recharge).
-- Kept in storage (a save keeps it) until cleared; a result read is kept KEEP_READ ticks after its first read. The
-- setter hears in team.alerts when a watch begins after a departure and when it ends.
-- (d22 batch109 BS1, Sol #1952: 8 a force kept Cinder's watch out while 18 platforms flew) a force may hold one watch
-- that counts per platform it has: armed, watching, or done with its result not read yet. A done one read no longer
-- counts (kept KEEP_READ, at most KEEP_DONE a force). Each watch reads on its own tick of the second (its phase).
-- (d22 batch116 BY1, Astra #1968: a queue's return-leg watch at the edge turnaround replaces the outbound one) a replace
-- keeps the watch it replaces readable by id: a done one as it ended, a watching one ended there (replaced by #N); it
-- no longer counts and is kept WAIT unless read (then KEEP_READ after the read). An armed one, nothing read yet, is
-- dropped.
-- (d25 batch212 QX1, Sol #2372: trial190's whole-trip uranium magazine use could not be exact from hub deltas or
-- uptime, which missed ticks at the departure and the turnaround) each window's ammunition used, from the platform's
-- item production statistics (consumed: get_output_count by quality; a turret's shots count there) read at the
-- window's own start and end ticks, as repair packs are; the watch's whole (across mixed splits), and across
-- replacements a chain from the first replaced watch's start, with what was used between two watches. A departure or
-- arrival falls between two samples: the reads at both name it (the ticks and what was used in them).
-- (d25 batch216 QAA1, Astra 20:09: Asterion's hub foundation fell 154 -> 153 -> 148 on flight 205's return with no hits,
-- losses, ghosts or foundation made or used read) each window's foundation tiles destroyed and rebuilt. Measured on a
-- copy of world n (2.0.77, Asterion flying, asteroids made by script at its front edge): an asteroid that enters the
-- foundation destroys every foundation tile under its collision box at once (a small one 2, a medium 3, a big one 5, and
-- the big one 5 more each tile it went on), takes no damage from them, and no event is raised (no tile event, no entity
-- event, damaged_tiles stays empty); the game puts a foundation tile ghost (our force, no last user) on each that tick.
-- The hub builds those ghosts from its own foundation one tile at a time, the first 63 to 168 ticks later, each raising
-- on_space_platform_built_tile (item space-platform-foundation, the ghost's quality) with the hub's count one lower; the
-- platform's item production statistics count none of it (foundation made 0, used 0). So the watch finds the
-- platform's tile ghosts (one find within the chunks that held foundation when it began, up to FLOOR_SCAN; each sample,
-- or every FLOOR_TICKS while the builds are heard): a foundation ghost new since the last find with no placer in the
-- ghost log (ghostlog.lua: an agent's or a player's) counts destroyed, one with a placer placed; one gone since is built
-- (foundation there now) or removed. The hub's builds come from that event (control.lua forwards it; M.on_built_tile):
-- its tick and quality; a build where no find saw a ghost was destroyed, or placed, and built between two finds. The
-- event's builds of every platform are kept apart for the platform read (M.floor_read: space.lua's foundation_lost).
local qflow = require('qflow')   -- (d24 batch152 PX1) statistics read at every quality
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
  M.MAX_ACCUMULATORS, M.SHOW_POWERED, M.MAX_LASERS = 1024, 64, 128
  -- (QX1) the ammunition read, and the watches a replacement chain names
  M.AMMO = {'uranium-rounds-magazine', 'firearm-magazine', 'piercing-rounds-magazine', 'rocket', 'explosive-rocket', 'railgun-ammo'}
  M.CHAIN = 8
  -- (QAA1) the tile ghosts a find reads at most (more aboard: that find reads none), the rows a window keeps,
  -- the builds a platform's record keeps
  M.FLOOR_SCAN, M.FLOOR_ROWS, M.FLOOR_KEEP = 512, 12, 8
  -- the ghosts found every FLOOR_TICKS while the platform's builds are heard (they give each rebuild's tick; the find
  -- dates a destruction and counts the open ghosts), else every sample. On a copy of world n, one find a second within
  -- Asterion's 40 hull chunks took 0.67 ms (30 finds), over its whole surface (402 chunks) 1.02 ms.
  M.FLOOR_TICKS = 300
  local FOUNDATION = 'space-platform-foundation'
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
  -- (d25 batch205 cp3, Astra at tick 62171636: a read by platform returned #1265 while #1270, read by id 1 h 7 min
  -- before, had been dropped 1 h after that read) the tick a watch first began: began (kept by begin), else for one
  -- begun before began was kept its first window (mixed parts' from_tick, a from-now watch's set tick), else its
  -- window's start; nil while armed
  function M.began(w)
    if w.began then return w.began end
    if not w.start then return nil end
    local parts = w.mixed and w.mixed.parts
    local first = parts and parts[1] and parts[1].from_tick
    if w.from == 'now' then return math.min(w.set or w.start, first or w.start) end
    return math.min(w.start, first or w.start)
  end
  -- A watch taken off the list: its platform's last DROPPED_KEEP drops kept (id, set, began, ended, why, tick), so a
  -- read by platform can name a newer watch no longer kept.
  M.DROPPED_KEEP = 4
  local function dropped(st, w, why, tick)
    st.dropped = st.dropped or {}
    local key = w.platform or tostring(w.index)
    local l = st.dropped[key] or {}
    st.dropped[key] = l
    l[#l+1] = {id=w.id, index=w.index, force=w.force, set=w.set, began=M.began(w), ended=w.ended, why=why, tick=tick or game.tick}
    while #l > M.DROPPED_KEEP do table.remove(l, 1) end
  end
  -- (d26 batch248 R8) an id no longer listed: its dropped record
  local function missing(st, id, force)
    local head = 'no flight watch #' .. tostring(id)
    for key, l in pairs(st.dropped or {}) do
      for _, d in ipairs(l) do
        if d.id == id and d.force == force then
          return string.format('%s: #%d on %s (began %s, ended %s) is no longer kept: dropped at tick %d (%s ago), %s', head, d.id, key,
            d.began and 'at tick ' .. d.began or 'never', d.ended and 'at tick ' .. d.ended or 'never', d.tick, secs(game.tick - d.tick), d.why)
        end
      end
    end
    if id > (st.seq or 0) or id < 1 then return string.format('%s: none set with that number (the last set is #%d)', head, st.seq or 0) end
    return string.format('%s: set and since dropped, before the last %d dropped on its platform kept', head, M.DROPPED_KEEP)
  end
  local function push(w, text)
    local st = store()
    st.eseq = st.eseq + 1
    st.events[#st.events+1] = {id=st.eseq, to=w.setter, text=text}
    while #st.events > M.EVENTS do table.remove(st.events, 1) end
  end
  -- (d22 batch110 BT1: on a copy of world n a watch's read a second made 76 KB of garbage, most of it the force's
  -- platforms list, closures and each turret's inventory read anew) a watch's platform kept while it is valid and still
  -- its force's platform of that index (what the force's list gives); module state, found again after a load
  local function platform_at(f, index) return f.platforms[index] end
  local function platform_of(w)
    local pl = w.pl
    if pl and pl.valid then return pl end
    local f = game.forces[w.force]
    local ok
    if f then ok, pl = pcall(platform_at, f, w.index); if not ok then pl = nil end else pl = nil end
    if pl and pl.valid then w.pl = pl; return pl end
  end
  local function flying_now(pl) return pl.state == defines.space_platform_state.on_the_path and pl.space_connection ~= nil end
  local function flying(pl) local ok, f = pcall(flying_now, pl); return ok and f or false end
  -- Where it is: its location, else the leg it flies the way it flies it (freight.lua's leg: a connection flown back
  -- reads the same from and to).
  local function where(pl)
    local loc = try(function() return pl.space_location.name end)
    if loc then return loc end
    local l = api.leg and try(function() return api.leg(pl) end)
    if l then return l.from .. '->' .. l.to end
    return try(function() return pl.space_connection.from.name .. '->' .. pl.space_connection.to.name end) or '?'
  end
  -- (BT1) a watched turret's ammo inventory, its get_item_count and its first slot, kept with the turret's row while
  -- the turret and they are valid (a method read and an inventory or stack read each make a new object); what they
  -- hold read live at each sample. Module state, read again after a load.
  local ammo_kept = setmetatable({}, {__mode='k'})
  local function ammo_inv(e)
    local inv = e.get_inventory(defines.inventory.turret_ammo)
    return inv, inv and inv.get_item_count
  end
  local function first_slot(inv) return inv[1] end
  local function slot_name(st) return st.valid_for_read and st.name end
  local function ammo_of(e, t)
    local kept = t and ammo_kept[t]
    if not (kept and kept.e == e and kept.inv.valid) then
      local ok, inv, count = pcall(ammo_inv, e)
      if not (ok and inv) then return nil end
      kept = {e=e, inv=inv, count=count}
      if t then ammo_kept[t] = kept end
    end
    local okn, n = pcall(kept.count)
    if not (okn and n) then return nil end
    local name
    if n > 0 then
      local st = kept.slot
      if not (st and st.valid) then
        local oks
        oks, st = pcall(first_slot, kept.inv)
        st = oks and st or nil
        kept.slot = st
      end
      if st then
        local okm, m = pcall(slot_name, st)
        name = okm and m or nil
      end
    end
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
    for _, name in ipairs(repair_names()) do n = n + (try(function() return qflow.count(stats, name, 'output') end) or 0) end
    return n
  end
  -- (QX1) the platform's ammunition consumed since the game began, by item and quality, at this tick: {tick, c}.
  -- get_output_count fetched once and one argument table: on a copy of world n 0.016 ms a read (6 items x 5
  -- qualities), qflow.count_by's 0.044 (it fetches the method each count)
  local PAIR = {name=nil, quality=nil}
  local function stats_of(pl) return pl.force.get_item_production_statistics(pl.surface) end
  local function ammo_read(pl)
    local ok, stats = pcall(stats_of, pl)
    if not (ok and stats) then return nil end
    local okf, f = pcall(function() return stats.get_output_count end)
    if not (okf and f) then return nil end
    local c, qs = {}, qflow.qualities()
    for _, name in ipairs(M.AMMO) do
      for _, q in ipairs(qs) do
        PAIR.name, PAIR.quality = name, q
        local okn, n = pcall(f, q == 'normal' and name or PAIR)
        n = okn and tonumber(n) or 0
        if n ~= 0 then c[name] = c[name] or {}; c[name][q] = n end
      end
    end
    return {tick=game.tick, c=c}
  end
  M.ammo_read = ammo_read
  -- What was used from read a to read b: {from_tick, to_tick, ticks, total, used {item: {quality: n}}}
  local function ammo_use(a, b)
    if not (a and b) then return nil end
    local used, total = {}, 0
    for name, qs in pairs(b.c) do
      for q, n in pairs(qs) do
        local d = n - ((a.c[name] or {})[q] or 0)
        if d ~= 0 then used[name] = used[name] or {}; used[name][q] = d; total = total + d end
      end
    end
    return {from_tick=a.tick, to_tick=b.tick, ticks=b.tick - a.tick, total=total, used=used}
  end
  M.ammo_use = ammo_use
  function M.use_text(u)
    if not u then return '?' end
    local out = {}
    for _, name in ipairs(M.AMMO) do
      local qs = u.used[name]
      if qs then
        local n, parts = 0, {}
        for _, q in ipairs(qflow.qualities()) do if qs[q] then n = n + qs[q]; parts[#parts+1] = q .. ' ' .. qs[q] end end
        out[#out+1] = string.format('%s %d%s', name, n, (#parts > 1 or not qs.normal) and ' (' .. table.concat(parts, ', ') .. ')' or '')
      end
    end
    return #out > 0 and table.concat(out, ', ') or 'none'
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
  -- (QAA1) foundation destroyed and rebuilt. A tile's key from its position (a number: no text a tile).
  local function fkey(x, y) return (math.floor(x) + 1048576) * 2097152 + (math.floor(y) + 1048576) end
  local function hub_foundation(pl)
    local inv = try(function() return pl.hub.get_inventory(defines.inventory.hub_main) end)
    local n = 0
    for _, st in ipairs(inv and try(function() return inv.get_contents() end) or {}) do
      if st.name == FOUNDATION then n = n + st.count end
    end
    return n
  end
  local function floor_row(f, tick, what, x, y, from)
    local r = f.rows[#f.rows]
    if r and r.tick == tick and r.what == what then r.count = r.count + 1; return end
    f.rows[#f.rows+1] = {tick=tick, what=what, count=1, at={x=x, y=y}, from_tick=from}
    if #f.rows > M.FLOOR_ROWS then table.remove(f.rows, 1); f.rows_more = (f.rows_more or 0) + 1 end
  end
  local function new_floor(pl)
    return {destroyed=0, rebuilt=0, between=0, before=0, placed=0, placed_built=0, removed=0, taken={}, rows={}, hub0=hub_foundation(pl)}
  end
  -- One find, no count, within the hull's chunks when known (box). On a copy of world n, Asterion's surface has 402
  -- chunks, 40 of them holding foundation; with no tile ghost, a find over the surface took 0.33 ms in a loop of 20 and
  -- added about 0.9 ms a sample in profile_ticks; within those 40 chunks 0.25 ms in a loop. Finding the chunks (one
  -- tile count each) took 4.6 ms: done once a watch, the box then widened by each build heard (foundation grows only by
  -- builds; a destroyed tile lies inside it).
  local function ghost_find(s, f, n, box)
    if box then return s.find_entities_filtered{name='tile-ghost', force=f, limit=n, area={{box[1], box[2]}, {box[3], box[4]}}} end
    return s.find_entities_filtered{name='tile-ghost', force=f, limit=n}
  end
  local function hull_box(s)
    local x0, y0, x1, y1
    for ch in s.get_chunks() do
      local a = ch.area
      if s.count_tiles_filtered{area=a, name=FOUNDATION, limit=1} > 0 then
        x0, y0 = math.min(x0 or a.left_top.x, a.left_top.x), math.min(y0 or a.left_top.y, a.left_top.y)
        x1, y1 = math.max(x1 or a.right_bottom.x, a.right_bottom.x), math.max(y1 or a.right_bottom.y, a.right_bottom.y)
      end
    end
    return x0 and {x0, y0, x1, y1} or nil
  end
  local function widen(box, x, y)
    if not box then return end
    box[1], box[2] = math.min(box[1], math.floor(x)), math.min(box[2], math.floor(y))
    box[3], box[4] = math.max(box[3], math.floor(x) + 1), math.max(box[4], math.floor(y) + 1)
  end
  local function ghost_of(g) return g.ghost_name, g.position, g.quality.name end
  -- Who placed a ghost (the ghost log; ghostlog.lua): name, 'record' or 'last_user', the record's tick, and whether the
  -- record was kept with this ghost's own unit number
  local function owner_of(g)
    if not api.ghost_owner then return nil end
    return api.ghost_owner(g)
  end
  -- The platform's foundation ghosts now: {key: {x, y, q, by, src, bt, own}}; nil past FLOOR_SCAN tile ghosts (then n:
  -- FLOOR_SCAN + 1), nil and nil when they could not be read.
  local function floor_ghosts(pl, box)
    local okf, list = pcall(ghost_find, pl.surface, pl.force, M.FLOOR_SCAN + 1, box)
    if not okf then return nil end
    if #list > M.FLOOR_SCAN then return nil, #list end
    local out = {}
    for _, g in ipairs(list) do
      local ok, name, pos, q = pcall(ghost_of, g)
      if ok and name == FOUNDATION then
        local okb, by, src, bt, own = pcall(owner_of, g)
        if okb and by then out[fkey(pos.x, pos.y)] = {x=math.floor(pos.x), y=math.floor(pos.y), q=q, by=by, src=src, bt=bt, own=own}
        else out[fkey(pos.x, pos.y)] = {x=math.floor(pos.x), y=math.floor(pos.y), q=q} end
      end
    end
    return out, #list
  end
  -- A ghost seen built (r: its seen record, or nil when no find saw it): by the event (q: its quality, heard=true) or
  -- by a find that found foundation there.
  local function floor_built(w, r, x, y, q, tick, heard, by)
    local f = w.fl
    q = q or (r and r.q) or 'normal'
    f.taken[q] = (f.taken[q] or 0) + 1
    if r and r.by or not r and by then
      if not r then f.placed = f.placed + 1 end  -- placed and built between two samples
      f.placed_built = f.placed_built + 1
      floor_row(f, tick, 'placed_built', x, y, not heard and w.fl_tick or nil)
      return
    end
    f.rebuilt = f.rebuilt + 1
    if not r then
      -- destroyed and built between two finds
      f.destroyed, f.between = f.destroyed + 1, f.between + 1
      f.first_destroyed = f.first_destroyed or tick
      f.last_destroyed = tick
      floor_row(f, tick, 'destroyed_and_rebuilt', x, y, w.fl_tick)
    else
      if r.pre then f.before = f.before + 1 end
      floor_row(f, tick, 'rebuilt', x, y, not heard and w.fl_tick or nil)
    end
  end
  -- A find (at a sample, FLOOR_TICKS apart while builds are heard): the ghosts new since the last (destroyed or placed)
  -- and those gone (built or removed).
  local function heard()
    local ok, v = pcall(function() return api.built_tile_heard and api.built_tile_heard() end)
    return ok and v or false
  end
  local function floor_sample(w, pl, tick)
    local f = w.fl
    if not f then return end
    if tick - (w.fl_tick or -M.FLOOR_TICKS) < M.FLOOR_TICKS - M.EVERY / 2 and heard() then return end
    local now, n = floor_ghosts(pl, w.fl_box)
    if not now then
      if n then f.skipped, f.skipped_tick = (f.skipped or 0) + 1, tick end
      return
    end
    local seen = w.fl_seen
    for k, g in pairs(now) do
      if not seen[k] then
        -- placed: its own record, a player's (the game's last user), or a record kept with no unit number placed since
        -- the last find; an older record is of a ghost once built there, not of this one
        local by = g.by and (g.own or g.src == 'last_user' or (g.bt or 0) > (w.fl_tick or -1)) and g.by or nil
        seen[k] = {x=g.x, y=g.y, t=tick, q=g.q, by=by}
        w.fl_n = w.fl_n + 1
        if by then
          f.placed = f.placed + 1
          floor_row(f, tick, 'placed', g.x, g.y, w.fl_tick)
        else
          f.destroyed = f.destroyed + 1
          f.first_destroyed = f.first_destroyed or tick
          f.last_destroyed = tick
          floor_row(f, tick, 'destroyed', g.x, g.y, w.fl_tick)
        end
      end
    end
    if w.fl_n > 0 then
      for k, r in pairs(seen) do
        if not now[k] then
          seen[k] = nil
          w.fl_n = w.fl_n - 1
          local tn = try(function() return pl.surface.get_tile(r.x, r.y).name end)
          if tn == FOUNDATION then
            floor_built(w, r, r.x, r.y, nil, tick, false)
            if api.ghost_forget_tile then pcall(api.ghost_forget_tile, pl.surface.name, FOUNDATION, {x=r.x + 0.5, y=r.y + 0.5}) end
          else f.removed = f.removed + 1; floor_row(f, tick, 'removed', r.x, r.y, w.fl_tick) end
        end
      end
    end
    w.fl_tick = tick
  end
  -- (QAA1) every platform's foundation built by the platform from that event, by whether a ghost was placed there
  -- (the ghost log) or not (a destroyed tile's): kept in storage from the first build or read (since).
  local function floor_log()
    local s = api.state()
    s.floorlog = s.floorlog or {since=game.tick, p={}}
    return s.floorlog
  end
  function M.on_built_tile(event)
    local pl = event.platform
    if not (pl and pl.valid) then return end
    local tile = event.tile
    if not (tile and tile.name == FOUNDATION) then return end
    local q = event.quality and (type(event.quality) == 'string' and event.quality or event.quality.name) or 'normal'
    local tick = event.tick or game.tick
    local sname = pl.surface.name
    local ws = {}
    local st = api.state().flightwatch
    for _, w in ipairs(st and st.list or {}) do
      if w.state == 'watching' and w.index == pl.index and w.fl and w.force == pl.force.name then ws[#ws+1] = w end
    end
    local L = floor_log()
    local rec = L.p[pl.index]
    if not rec or rec.name ~= pl.name then rec = {name=pl.name, since=tick, rebuilt=0, placed_built=0, taken={}, rows={}}; L.p[pl.index] = rec end
    for _, t in ipairs(event.tiles or {}) do
      local x, y = t.position.x, t.position.y
      local k = fkey(x, y)
      local rs, r = {}, nil
      for i, w in ipairs(ws) do
        local wr = w.fl_seen[k]
        if wr then w.fl_seen[k] = nil; w.fl_n = w.fl_n - 1; rs[i] = wr; r = r or wr end
      end
      -- the ghost log's record there (dropped now: the tile is built; a later ghost there is another's)
      local centre = {x=math.floor(x) + 0.5, y=math.floor(y) + 0.5}
      local ok, b, _, bt, own = pcall(function() if api.ghost_owner_at then return api.ghost_owner_at(sname, FOUNDATION, centre) end end)
      if not ok then b = nil end
      if api.ghost_forget_tile then pcall(api.ghost_forget_tile, sname, FOUNDATION, centre) end
      for i, w in ipairs(ws) do
        -- one no sample saw: placed when its record is from after the last sample, or when it lay outside the box the
        -- samples read (an expansion: no destroyed tile is there)
        local bx = w.fl_box
        local out = bx and (x < bx[1] or y < bx[2] or x >= bx[3] or y >= bx[4])
        widen(bx, x, y)
        local by = rs[i] and rs[i].by or not rs[i] and b and (out or (bt or 0) > (w.fl_tick or -1)) and b or nil
        floor_built(w, rs[i], math.floor(x), math.floor(y), q, tick, true, by)
      end
      rec.taken[q] = (rec.taken[q] or 0) + 1
      -- the platform's record: placed when the ghost log kept the record with its ghost's unit number (from this change
      -- on; a built tile's record is dropped here, so one kept is its ghost's)
      local by = r and r.by or not r and b and own and b or nil
      -- (d26 batch246 FL) a tile no one placed, rebuilt: destroyed (platform_foundation_loss)
      if not by then M.loss_rebuilt(pl, x, y, tick) end
      local what = by and 'placed_built' or 'rebuilt'
      rec[what] = rec[what] + 1
      local last = rec.rows[#rec.rows]
      if last and last.tick == tick and last.what == what then last.count = last.count + 1
      else
        rec.rows[#rec.rows+1] = {tick=tick, what=what, count=1, at={x=math.floor(x), y=math.floor(y)}}
        if #rec.rows > M.FLOOR_KEEP then table.remove(rec.rows, 1) end
      end
    end
  end
  -- (d26 batch246 FL, Astra #2461: trial 242 lost a floor tile at (-50,-60), tick 67333569, with no entity lost or hit;
  -- platform_loss and platform_hit count entities only) each platform's destroyed foundation tiles, for the
  -- platform_foundation_loss wait and guard (conditions.lua): a ring of LOSS_KEEP rows {seq, x, y, pt (the tick it
  -- was logged), seen (the tick a find first saw its ghost), after (the find before it: lost after that tick), rebuilt
  -- (the tick the hub built it again)}. Two ways in:
  -- - the hub's rebuild (on_space_platform_built_tile, always forwarded: event-driven) of a tile on a ghost no one
  --   placed: a tile lost and rebuilt between finds is still counted;
  -- - a find of the platform's foundation ghosts no one placed (loss_scan, at most once every LOSS_SCAN ticks a
  --   platform, only while such a wait or guard is checked): a tile lost and not rebuilt yet (the hub out of
  --   foundation) counts when first seen. Ghosts already there at a platform's first find are not counted (their loss
  --   tick is unknown), nor their rebuilds.
  -- Floor placed on purpose is left out: a ghost an agent placed (place_ghosts, paste, the routes; the ghost log) or a
  -- player placed (the game's last user) is placed, as flight_watch tells them; an agent's hand-laid or mined tile and
  -- robots' tile deconstruction make no ghost and no rebuild. (The game puts a ghost with no last user on a destroyed
  -- tile: memory factorio-platform-foundation-loss.)
  M.LOSS_KEEP, M.LOSS_SCAN, M.LOSS_ROWS = 256, 60, 8
  local function loss_log(pl)
    local s = api.state()
    s.floorloss = s.floorloss or {}
    local r = s.floorloss[pl.index]
    if not r or r.name ~= pl.name then r = {name=pl.name, seq=0, ring={}, seen={}}; s.floorloss[pl.index] = r end
    return r
  end
  local function loss_push(r, x, y, pt)
    r.seq = r.seq + 1
    local e = {seq=r.seq, x=x, y=y, pt=pt}
    r.ring[(r.seq - 1) % M.LOSS_KEEP + 1] = e
    return e
  end
  local function loss_row(r, seq)
    local e = r.ring[(seq - 1) % M.LOSS_KEEP + 1]
    return e and e.seq == seq and e or nil
  end
  M.loss_row = loss_row
  function M.loss_rebuilt(pl, x, y, tick)
    local r = loss_log(pl)
    local k = fkey(x, y)
    local sn = r.seen[k]
    if sn then
      r.seen[k] = nil
      local e = sn.seq and loss_row(r, sn.seq)
      if e then e.rebuilt = tick end
      return
    end
    local e = loss_push(r, math.floor(x), math.floor(y), tick)
    e.rebuilt, e.after = tick, r.read_tick
  end
  function M.loss_scan(pl, tick)
    local r = loss_log(pl)
    if r.scan_tick and tick - r.scan_tick < M.LOSS_SCAN then return r end
    local now, n = floor_ghosts(pl, nil)
    r.scan_tick = tick
    -- a find met over FLOOR_SCAN tile ghosts (a large paste) reads none: the next counts from the last one read
    if not now then r.skipped, r.skipped_n = tick, n; return r end
    local prev = r.read_tick
    r.read_tick = tick
    for k, g in pairs(now) do
      -- placed: as flight_watch tells them (its own record, a player's, or a record newer than the find before)
      local by = g.by and (g.own or g.src == 'last_user' or (g.bt or 0) > (prev or -1)) and g.by or nil
      if by then r.seen[k] = {placed=true}  -- its build later is no loss
      elseif not r.seen[k] then
        if prev == nil then r.seen[k] = {pre=true}
        else
          local e = loss_push(r, g.x, g.y, tick)
          e.seen, e.after = tick, prev
          r.seen[k] = {seq=e.seq}
        end
      end
    end
    for k in pairs(r.seen) do if not now[k] then r.seen[k] = nil end end  -- built unheard, or removed
    return r
  end
  local function taken_text(t)
    local parts, n = {}, 0
    for _, q in ipairs(qflow.qualities()) do if t[q] then n = n + t[q]; parts[#parts+1] = q .. ' ' .. t[q] end end
    return n, (#parts > 1 or (#parts == 1 and not t.normal)) and ' (' .. table.concat(parts, ', ') .. ')' or ''
  end
  -- (QAA1) the platform read's foundation_lost (space.lua): the builds heard on it since the record began, the
  -- foundation ghosts on it now with no placer (destroyed, not rebuilt yet) and with one.
  function M.floor_read(pl)
    local L = floor_log()
    local rec = L.p[pl.index]
    if rec and rec.name ~= pl.name then rec = nil end
    local now, n = floor_ghosts(pl)
    local open, placed = 0, 0
    for _, g in pairs(now or {}) do if g.by then placed = placed + 1 else open = open + 1 end end
    local h = heard()
    local taken = rec and rec.taken or {}
    local tn, tq = taken_text(taken)
    local out = {since_tick=rec and rec.since or L.since, rebuilt=rec and rec.rebuilt or 0, placed_built=rec and rec.placed_built or 0, taken=taken,
      open=now and open or nil, open_placed=now and placed or nil, tile_ghosts=not now and n or nil, rows=rec and rec.rows or nil, builds_heard=h}
    local builds = h and string.format('since tick %d the platform built %d foundation tiles on ghosts no one placed (destroyed tiles) and %d on placed ghosts, taking %d foundation from the hub%s',
      out.since_tick, out.rebuilt, out.placed_built, tn, tq)
      or 'the platform\'s own tile builds are not heard here (this server\'s control.lua forwards no on_space_platform_built_tile)'
    out.line = string.format('foundation: %s; %s', now and string.format('%d foundation ghosts no one placed (destroyed tiles not rebuilt yet) and %d placed ones aboard now', open, placed)
      or n and string.format('over %d tile ghosts aboard, none read', M.FLOOR_SCAN) or 'its tile ghosts could not be read', builds)
    return out
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
  -- (PW1) a laser turret's shot energy by prototype name (prototypes do not change while the game runs): the prototype's
  -- attack_parameters.ammo_type.energy_consumption; false for an electric turret that is not a laser
  local SHOT = {}
  local function shot_of(name)
    if SHOT[name] == nil then
      local ap = try(function() return prototypes.entity[name].attack_parameters end)
      local cats = ap and ap.ammo_categories or {}
      local laser = false
      for _, c in ipairs(cats) do if c == 'laser' then laser = true end end
      local j = laser and try(function() return ap.ammo_type.energy_consumption end)
      SHOT[name] = laser and type(j) == 'number' and j > 0 and j or false
    end
    return SHOT[name]
  end
  local function counts_of(e) return e.kills, e.damage_dealt end
  local function add_laser(w, e, tick)
    if #w.lasers >= M.MAX_LASERS then w.lasers_capped = true; return end
    local shot = shot_of(e.name)
    if not shot then return end
    local en = try(function() return e.energy end) or 0
    local ok, k, d = pcall(counts_of, e)
    k, d = ok and k or 0, ok and d or 0
    local q = try(function() return e.quality.name end)
    w.lasers[#w.lasers+1] = {e=e, unit=e.unit_number, name=e.name, quality=q ~= 'normal' and q or nil, position={x=e.position.x, y=e.position.y},
      shot=shot, buffer=try(function() return e.electric_buffer_size end), emin=en, emin_tick=tick, efirst=en, enow=en,
      low_samples=0, low_ticks=0, low_runs=0, low_longest=0, low_longest_n=0, k0=k, d0=d, k1=k, d1=d, added=tick ~= w.start and tick or nil}
    w.by_laser[e.unit_number] = #w.lasers
  end
  -- (BH1) the platform's accumulators, found at the start and each minute with the turrets
  local function buffer_of(e) return e.electric_buffer_size end
  local function find_accumulators(w, pl)
    local list = try(function() return pl.surface.find_entities_filtered{type='accumulator', force=pl.force, limit=M.MAX_ACCUMULATORS + 1} end) or {}
    w.acc_capped = #list > M.MAX_ACCUMULATORS or nil
    local accs, cap = {}, 0
    for i = 1, math.min(#list, M.MAX_ACCUMULATORS) do
      local e = list[i]
      local okb, b = pcall(buffer_of, e)  -- (BT1) no closure an accumulator
      b = okb and b or 0
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
    -- (PW1) the laser turrets; a watch begun before them has none (its read as it was)
    if w.lasers then
      for _, e in ipairs(try(function() return pl.surface.find_entities_filtered{type='electric-turret', force=pl.force} end) or {}) do
        if e.unit_number and not w.by_laser[e.unit_number] then add_laser(w, e, tick) end
      end
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
    local first = not w.began
    w.began = w.began or tick  -- (d25 batch205 cp3) the first begin: a split (M.rebase) moves w.start, never this
    -- (QX1) the window's ammunition read; the first begin's kept for the whole watch; a departure seen now falls
    -- after the last sample that read it stopped; a chain's gap from the replaced watch's end closes here
    w.ammo0 = ammo_read(pl)
    w.ammo_last = w.ammo0
    -- (QAA1) this window's foundation counts; at the first begin the foundation ghosts aboard are seen, not counted
    w.fl = new_floor(pl)
    if not w.fl_seen then
      w.fl_seen, w.fl_n = {}, 0
      local okb, box = pcall(hull_box, pl.surface)
      w.fl_box = okb and box or nil
      -- placed: its own record or a player's; an older record may be of a ghost once built there (a destroyed tile's
      -- ghost then), so those count as no one's
      for k, g in pairs(floor_ghosts(pl, w.fl_box) or {}) do
        w.fl_seen[k] = {x=g.x, y=g.y, t=tick, q=g.q, by=(g.own or g.src == 'last_user') and g.by or nil, pre=true}
        w.fl_n = w.fl_n + 1
      end
    end
    w.fl_tick = tick
    if first then
      w.ammo_began, w.began_flying = w.ammo0, flying(pl)
      if w.began_flying then w.ammo_flying = w.ammo0 end
      if w.from == 'departure' and w.ammo_stopped then w.ammo_dep = ammo_use(w.ammo_stopped, w.ammo0) end
      w.ammo_stopped = nil
      local g = w.chain and w.chain.gaps[#w.chain.gaps]
      if g and not g.to_tick then
        local u = ammo_use(g.r0, w.ammo0)
        g.r0, g.to_tick, g.total, g.used = nil, tick, u and u.total, u and u.used
      end
    end
    w.state, w.start, w.until_tick = 'watching', tick, tick + w.minutes * 3600
    w.leg = where(pl)
    w.at_start, w.flew = w.leg, flying(pl)
    w.turrets, w.by_unit, w.lasers, w.by_laser = {}, {}, {}, {}
    find_turrets(w, pl, tick)
    local f = acc_fraction(w)
    w.acc = {first=f, min=f, min_tick=tick, now=f}
    w.acc_n = #(w.accs or {})
    w.hits0, w.fuel0, w.repair0, w.packs0 = hits(pl), fuel(pl), repair_used(pl), hub_packs(pl)
    w.repair_q = true   -- (PX1) repair0 over every quality
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
    -- (QX1) this tick's sample's read when it has one
    local a1 = w.ammo1
    if pl then a1 = w.ammo_last and w.ammo_last.tick == game.tick and w.ammo_last or ammo_read(pl) end
    return {damage=dmg, lost=lost, lost_n=n or 0, repair_used=w.repair0 and w.repair_q and r1 and r1 - w.repair0 or nil, packs_start=w.packs0, packs_end=p1,
      fuel_start=w.fuel0, fuel_end=f1, h1=h1, r1=r1, a1=a1}
  end
  local function finish(w, pl, tick, why)
    if pl then
      take_feed(w, pl, tick, false)
      local t = totals(w, pl, tick)
      w.hits1, w.lost, w.lost_n, w.repair1, w.packs1, w.fuel1 = t.h1, t.lost, t.lost_n, t.r1, t.packs_end, t.fuel_end
      -- (QX1) the end's read; an arrival falls after the last sample that read it flying
      w.ammo1 = t.a1
      if why:sub(1, 7) == 'arrived' and w.ammo_flying then w.ammo_arr = ammo_use(w.ammo_flying, t.a1) end
      if w.fl then w.fl_hub1 = hub_foundation(pl) end
    else w.ammo1 = w.ammo_last end  -- (QX1) the platform gone: its last sample's read
    -- (QAA1) the ghosts open at the end kept as counts
    if w.fl_seen then
      local open, placed = 0, 0
      for _, r in pairs(w.fl_seen) do if r.by then placed = placed + 1 else open = open + 1 end end
      w.fl_open, w.fl_open_placed, w.fl_seen, w.fl_n, w.fl_box = open, placed, nil, 0, nil
    end
    w.ammo_last, w.ammo_flying = nil, nil
    w.state, w.ended, w.why = 'done', tick, why
    for _, t in ipairs(w.turrets or {}) do t.e = nil end
    for _, t in ipairs(w.lasers or {}) do t.e = nil end
    w.accs, w.pl = nil, nil
    M.reindex()
    if not w.start then push(w, string.format('flight watch #%d on %s ended before it began (%s)', w.id, w.platform, why)); return end
    push(w, string.format('flight watch #%d on %s ended (%s) after %s: %s%s%s; flight_watch {id: %d} reads it', w.id, w.platform, why, secs(tick - w.start), M.worst(w), M.power_text(w),
      w.ammo0 and '; ammunition used ' .. M.use_text(ammo_use(w.ammo0, w.ammo1)) or '', w.id))
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
    -- (PW1) the laser turrets
    local ln, llow, lk, ld, llong, llt, shot = 0, 0, 0, 0, 0, nil, nil
    for _, t in ipairs(w.lasers or {}) do
      ln, shot = ln + 1, shot or t.shot
      if t.low_samples > 0 then llow = llow + 1 end
      lk, ld = lk + (t.k1 - t.k0), ld + (t.d1 - t.d0)
      if t.low_longest > llong then llong, llt = t.low_longest, t end
    end
    if ln > 0 then
      parts[#parts+1] = string.format('%d laser turrets%s: %s; %d kills, %g damage dealt', ln, w.lasers_capped and ' (capped)' or '',
        llow == 0 and string.format('none read below a shot\'s energy (%s) in a sample', mj(shot)) or string.format('%d read below a shot\'s energy (%s) in some sample, the longest run %d sample%s (%d ticks), %s %s #%d from +%s',
          llow, mj(shot), llt.low_longest_n, llt.low_longest_n == 1 and '' or 's', llong, llt.name, at(llt.position), llt.unit, secs(llt.low_long_from - w.start)),
        lk, math.floor(ld + 0.5))
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
        local n, name = ammo_of(t.e, t)
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
    -- (PW1) each laser: its energy against one shot's, and its kills and damage dealt
    for _, t in ipairs(w.lasers or {}) do
      local e = t.e
      if e and e.valid then
        local en = e.energy
        t.enow = en
        if en < t.emin then t.emin, t.emin_tick = en, tick end
        if en < t.shot then
          t.low_samples, t.low_ticks = t.low_samples + 1, t.low_ticks + dt
          if not t.low_from then t.low_from, t.low_run, t.low_n, t.low_runs = tick, 0, 0, t.low_runs + 1 end
          t.low_run, t.low_n = t.low_run + dt, t.low_n + 1
          if t.low_run > t.low_longest then t.low_longest, t.low_longest_n, t.low_long_from = t.low_run, t.low_n, t.low_from end
        elseif t.low_from then t.low_from, t.low_run, t.low_n = nil, nil, nil end
        local ok, k, d = pcall(counts_of, e)
        if ok then t.k1, t.d1 = k, d end
      elseif e then t.gone, t.e = tick, nil end
    end
    local f = acc_fraction(w)
    if f and w.acc then
      w.acc.now = f
      if not w.acc.min or f < w.acc.min then w.acc.min, w.acc.min_tick = f, tick end
      w.acc.first = w.acc.first or f
    end
    take_feed(w, pl, tick, new_run)
    -- (QX1) each sample's ammunition read
    if w.ammo0 then w.ammo_last = ammo_read(pl) end
    floor_sample(w, pl, tick)  -- (QAA1)
  end
  function M.tick(tick)
    local st = api.state().flightwatch
    if not st then return end
    for i = #st.list, 1, -1 do
      local w = st.list[i]
      if w.state == 'done' and (w.read_tick and tick - w.read_tick > M.KEEP_READ or not w.read_tick and w.replaced_tick and tick - w.replaced_tick > M.WAIT) then
        dropped(st, w, w.read_tick and string.format('%s after its first read at tick %d', secs(M.KEEP_READ), w.read_tick)
          or string.format('%s after it was replaced at tick %d, not read', secs(M.WAIT), w.replaced_tick), tick)
        table.remove(st.list, i)
      end
    end
    if not st.due then M.reindex() end
    local ph = tick % M.EVERY
    for _, w in ipairs(st.list) do
      if w.state ~= 'done' and w.phase == ph then
        local pl = platform_of(w)
        if not (pl and pl.surface) then finish(w, nil, tick, 'the platform is gone')
        elseif w.state == 'armed' then
          local f = flying(pl)
          if not f then
            w.seen_stopped = true
            w.ammo_stopped = ammo_read(pl)  -- (QX1) the last read stopped: a departure falls after it
          elseif w.seen_stopped then
            begin(w, pl, tick)
            push(w, string.format('flight watch #%d on %s began: it left for %s', w.id, w.platform, w.leg))
          end
          if w.state == 'armed' and tick - w.set > M.WAIT then finish(w, nil, tick, 'no departure within 24h') end
        else
          local f = flying(pl)
          sample(w, pl, tick)
          if f and w.ammo_last then w.ammo_flying = w.ammo_last end  -- (QX1) the last sample that read it flying
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
  -- (QX1) a read's ammunition fields: this window's, the whole watch's after a split, the chain's after a
  -- replacement, and the boundaries the samples fall around
  local function ammo_fields(w, r, a1)
    if not w.ammo0 then return '; ammunition used ? (this watch began before ammunition was read)' end
    local win = ammo_use(w.ammo0, a1)
    r.ammunition = win
    local text = '; ammunition used ' .. M.use_text(win)
    if w.ammo_began and w.ammo_began ~= w.ammo0 then
      r.ammunition_watch = ammo_use(w.ammo_began, a1)
      text = text .. string.format(' (since the watch began at tick %d, across its splits: %s)', w.ammo_began.tick, M.use_text(r.ammunition_watch))
    end
    local b = {}
    local ch = w.chain
    if ch then
      local u = ammo_use(ch.base, a1)
      if u then
        local ids = {}
        for i, id in ipairs(ch.ids) do ids[i] = id end
        ids[#ids+1] = w.id
        u.watches, u.first, u.more = ids, ch.first, ch.more
        r.ammunition_chain = u
        text = text .. string.format('; since #%d began at tick %d (watches #%s%s): %s', ch.first, u.from_tick, table.concat(ids, ', #'), ch.more and ', ' .. ch.more .. ' more before' or '', M.use_text(u))
      end
      if ch.dep then
        local d = ch.dep
        b[#b+1] = {what='departure', watch=ch.first, from_tick=d.from_tick, to_tick=d.to_tick, ticks=d.ticks, total=d.total, used=d.used,
          line=string.format('#%d: left between tick %d (the last sample that read it stopped) and tick %d (the first that read it flying): %s used in those %d ticks, before #%d began, in no count', ch.first, d.from_tick, d.to_tick, M.use_text(d), d.ticks, ch.first)}
      end
      for _, g in ipairs(ch.gaps) do
        if g.to_tick then
          b[#b+1] = {what='between', after=g.after, before=g.before, from_tick=g.from_tick, to_tick=g.to_tick, ticks=g.to_tick - g.from_tick, total=g.total, used=g.used,
            line=string.format('between #%d\'s end at tick %d and #%d\'s start at tick %d: %s used in those %d ticks, in neither watch, counted in ammunition_chain', g.after, g.from_tick, g.before, g.to_tick,
              g.used and M.use_text(g) or '?', g.to_tick - g.from_tick)}
        end
      end
    elseif w.ammo_dep then
      local d = w.ammo_dep
      b[#b+1] = {what='departure', watch=w.id, from_tick=d.from_tick, to_tick=d.to_tick, ticks=d.ticks, total=d.total, used=d.used,
        line=string.format('left between tick %d (the last sample that read it stopped) and tick %d (the first that read it flying): %s used in those %d ticks, before this watch began, in no count', d.from_tick, d.to_tick, M.use_text(d), d.ticks)}
    elseif w.began_flying then
      b[#b+1] = {what='start', watch=w.id, tick=M.began(w), line=string.format('began at tick %d while it flew: what was used before then is in no count', M.began(w))}
    end
    if w.ammo_arr then
      local d = w.ammo_arr
      local inw = d.from_tick >= w.start
      b[#b+1] = {what='arrival', watch=w.id, from_tick=d.from_tick, to_tick=d.to_tick, ticks=d.ticks, total=d.total, used=d.used, counted=inw and 'ammunition' or 'ammunition_watch',
        line=string.format('arrived between tick %d (the last sample that read it flying) and tick %d (the sample that read it arrived, the end): %s used in those %d ticks, counted in %s', d.from_tick, d.to_tick, M.use_text(d), d.ticks,
          inw and 'ammunition' or 'ammunition_watch (this window began at tick ' .. w.start .. ')')}
    end
    if #b > 0 then r.ammunition_boundaries = b end
    return text
  end
  -- (QAA1) a read's foundation field and text: this window's counts, the ghosts open now (or at the end), the hub's
  -- foundation at the window's start and now (or its end)
  local function floor_fields(w, r, pl)
    local f = w.fl
    if not f then return '; foundation not read (this watch began before foundation was read)' end
    local open, placed = 0, 0
    if w.fl_seen then for _, x in pairs(w.fl_seen) do if x.by then placed = placed + 1 else open = open + 1 end end
    else open, placed = w.fl_open or 0, w.fl_open_placed or 0 end
    local h1 = pl and hub_foundation(pl) or w.fl_hub1
    local tn, tq = taken_text(f.taken)
    local h = heard()
    r.foundation = {destroyed=f.destroyed, rebuilt=f.rebuilt, destroyed_between_finds=f.between, rebuilt_from_before=f.before, open=open,
      placed=f.placed, placed_built=f.placed_built, open_placed=placed, removed=f.removed, taken=f.taken, taken_total=tn,
      hub_foundation={start=f.hub0, ['end']=h1}, first_destroyed_tick=f.first_destroyed, last_destroyed_tick=f.last_destroyed,
      rows=f.rows, rows_more=f.rows_more, skipped_finds=f.skipped, builds_heard=h}
    local text = string.format('; foundation: %d tiles destroyed%s, %d rebuilt by the platform%s, %d foundation taken from the hub by its tile builds%s, %d destroyed not rebuilt yet; hub foundation %s -> %s',
      f.destroyed, f.first_destroyed and string.format(' (ticks %d to %d)', f.first_destroyed, f.last_destroyed) or '', f.rebuilt,
      f.before > 0 and string.format(' (%d of ghosts aboard when the watch began)', f.before) or '', tn, tq, open, tostring(f.hub0), tostring(h1))
    if f.placed > 0 or f.placed_built > 0 or placed > 0 then text = text .. string.format(' (placed ghosts: %d appeared, %d built, %d open)', f.placed, f.placed_built, placed) end
    if f.removed > 0 then text = text .. string.format(' (%d foundation ghosts removed unbuilt)', f.removed) end
    if f.skipped then text = text .. string.format(' (%d finds met over %d tile ghosts aboard and read none of them, the last at tick %d)', f.skipped, M.FLOOR_SCAN, f.skipped_tick) end
    if not h then text = text .. ' (the platform\'s tile builds not heard: this server\'s control.lua forwards no on_space_platform_built_tile; builds read by the finds, each sample)' end
    return text
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
      -- (PW1) the laser turrets: the longest run below a shot's energy first, then the least energy
      local ls = {}
      for _, x in ipairs(w.lasers or {}) do ls[#ls+1] = x end
      table.sort(ls, function(a, b)
        if a.low_longest ~= b.low_longest then return a.low_longest > b.low_longest end
        if a.emin ~= b.emin then return a.emin < b.emin end
        return a.unit < b.unit
      end)
      local lrow, llines = {}, {}
      for i = 1, math.min(#ls, M.SHOW_POWERED) do
        local x = ls[i]
        local dk, dd = x.k1 - x.k0, math.floor((x.d1 - x.d0) * 10 + 0.5) / 10
        lrow[#lrow+1] = {unit_number=x.unit, name=x.name, quality=x.quality, position=x.position, shot_energy=x.shot, buffer=x.buffer, least_energy=math.floor(x.emin), least_tick=x.emin_tick,
          energy_at_start=math.floor(x.efirst), energy_now=math.floor(x.enow), below_samples=x.low_samples, below_ticks=x.low_ticks, below_runs=x.low_runs,
          longest_below_samples=x.low_longest_n, longest_below_ticks=x.low_longest, longest_below_from_tick=x.low_long_from, below_now=x.low_from and true or nil,
          kills=dk, damage=dd, kills_start=x.k0, kills_end=x.k1, gone_tick=x.gone, added_tick=x.added}
        llines[#llines+1] = string.format('%s%s %s #%d: energy least %s (%s of a shot) at +%s, %s at the start, %s now; %s; %d kills, %g damage dealt%s', x.quality and x.quality .. ' ' or '', x.name, at(x.position), x.unit,
          mj(x.emin), pct(x.emin / x.shot), secs((x.emin_tick or w.start) - w.start), mj(x.efirst), mj(x.enow),
          x.low_samples == 0 and 'never below a shot\'s energy in a sample' or string.format('below a shot\'s energy in %d sample%s (%d ticks) over %d run%s, the longest %d sample%s (%d ticks) from +%s',
            x.low_samples, x.low_samples == 1 and '' or 's', x.low_ticks, x.low_runs, x.low_runs == 1 and '' or 's', x.low_longest_n, x.low_longest_n == 1 and '' or 's', x.low_longest, secs((x.low_long_from or w.start) - w.start)),
          dk, dd, x.gone and string.format('; gone at +%s', secs(x.gone - w.start)) or (x.added and string.format('; built at +%s', secs(x.added - w.start)) or ''))
      end
      if #ls > 0 then r.lasers, r.laser_lines, r.lasers_more, r.lasers_capped = lrow, llines, #ls > M.SHOW_POWERED and #ls - M.SHOW_POWERED or nil, w.lasers_capped and M.MAX_LASERS or nil end
    end
    r.line = string.format('flight watch #%d on %s, %s: %s for %s (%d samples, one every %d ticks)%s; %s%s; damage taken %g in %d hit%s%s; %d lost; repair packs used %s (hub %s -> %s); %s',
      w.id, w.platform, w.leg or '?', w.state == 'done' and 'watched' or 'watching', secs(now - w.start), w.samples or 0, M.EVERY,
      w.state == 'done' and ', ended: ' .. tostring(w.why) or string.format(', until its arrival or %s more', secs(w.until_tick - now)), M.worst(w), M.power_text(w),
      t.damage.damage, t.damage.hits, t.damage.hits == 1 and '' or 's', #t.damage.entities > 0 and ' (' .. table.concat(t.damage.entities, ', ') .. ')' or '', t.lost_n,
      t.repair_used and tostring(t.repair_used) or '?', tostring(t.packs_start), tostring(t.packs_end), fuel_text(t.fuel_start, t.fuel_end))
      .. ammo_fields(w, r, t.a1) .. floor_fields(w, r, pl)
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
    .. 'hits, damage and kills from the game\'s damage and death events with the railgun as cause, shots_hit the ticks it hit something (one shot hits all on its line in one tick; a shot that hits nothing is not counted); '
    .. 'laser turrets (electric turrets of ammo category laser, up to 128): energy each sample, below a shot\'s energy meaning under the prototype\'s energy per shot (attack_parameters.ammo_type.energy_consumption, 800 kJ for laser-turret; 2.0.77 has no getter by quality: a rare laser\'s shot took 800 kJ on a copy of world n, its recharge 255.6 kJ a tick), so a laser that fires and refills between two samples (3 ticks at that rate) reads full; '
    .. 'kills and damage dealt the turret\'s own counts (its tooltip\'s Kills and Damage dealt, as turret_tally reads them), each sample\'s less the start\'s (a laser gone keeps its change up to its last sample); '
    .. 'ammunition: the platform\'s item production statistics, consumed (a turret\'s shots count there), of ' .. table.concat(M.AMMO, ', ') .. ' by quality, read at the window\'s start and end tick and at each sample; '
    .. 'a departure or arrival falls between two samples (ammunition_boundaries gives both ticks and what was used between them); '
    .. 'foundation: an asteroid that enters the foundation destroys the tiles under it with no event, and the game puts a foundation tile ghost on each at once; the hub builds them from its foundation one at a time (the item production statistics count none of it); '
    .. 'every ' .. M.FLOOR_TICKS / 60 .. ' s while the builds are heard (else each sample) the watch finds the foundation tile ghosts (up to ' .. M.FLOOR_SCAN .. ' tile ghosts, within the chunks that held foundation when the watch began, widened by each build heard): one new with no placer in the harness\'s ghost log (an agent\'s or a player\'s) counts destroyed at that find (rows: from_tick the find before), one with a placer placed; '
    .. 'rebuilt, taken and their ticks from the game\'s on_space_platform_built_tile (builds_heard), a build where no find saw a ghost counted destroyed and rebuilt between two finds (placed when outside those chunks or its record is newer than the last find)'
  -- (d25 batch205 QR2, Astra #2338: a queue could not read the watch its earlier step started without its id) read:
  -- true with platform reads that platform's latest watch, never starting or replacing one; checked with no world at
  -- submit and in dry_run (runtime.lua step_checks) as here.
  function M.check_read(a)
    if a.read == nil then return end
    assert(a.read == true, 'read: true, with platform: that platform\'s latest flight watch')
    assert(type(a.platform) == 'string' and a.platform ~= '', 'read: true takes platform (in a platform lane, the lane\'s platform)')
    assert(a.id == nil and a.clear == nil and a.from == nil and a.minutes == nil and a.replace == nil,
      'read: true takes platform only (id reads one watch by number; from, minutes and replace start one)')
  end
  -- The newest by the tick it first began (M.began; an armed one by its set tick), ties by id; older: the rest kept on
  -- it, newest first; dropped_newer: watches dropped from the list that began after it (or set after it, while armed).
  local function order(w) return M.began(w) or w.set or 0 end
  local function latest(p, a)
    local st = store()
    local ok, pl = pcall(api.platform, p, a.platform)
    local index = ok and pl and pl.index
    local mine = {}
    for _, w in ipairs(st.list) do
      if w.force == p.force.name and ((index and w.index == index) or w.platform == a.platform) then mine[#mine+1] = w end
    end
    table.sort(mine, function(x, y) local ox, oy = order(x), order(y); if ox ~= oy then return ox > oy end return x.id > y.id end)
    local found = mine[1]
    local gone = {}
    for _, d in ipairs((st.dropped or {})[a.platform] or {}) do
      if d.force == p.force.name and (not found or (d.began or d.set or 0) > order(found) or ((d.began or d.set or 0) == order(found) and d.id > found.id)) then
        gone[#gone+1] = {id=d.id, set_tick=d.set, began_tick=d.began, end_tick=d.ended, dropped_tick=d.tick, why=d.why,
          line=string.format('#%d (began %s, ended %s) is no longer kept: dropped at tick %d, %s', d.id, d.began and 'at tick ' .. d.began or 'never',
            d.ended and 'at tick ' .. d.ended or 'never', d.tick, d.why)}
      end
    end
    table.sort(gone, function(x, y) return x.id > y.id end)
    local gone_text = #gone > 0 and '; newer on ' .. a.platform .. ' and no longer kept: ' .. (function() local t = {} for i, g in ipairs(gone) do t[i] = g.line end return table.concat(t, '; ') end)() or ''
    if not found then
      return {not_found=true, platform=a.platform, dropped_newer=#gone > 0 and gone or nil,
        line=string.format('no flight watch on %s is kept (flight_watch {} lists the force\'s)', a.platform) .. gone_text}
    end
    if found.state == 'done' and not found.read_tick then found.read_tick = game.tick end
    local older = {}
    for i = 2, #mine do older[#older+1] = mine[i].id end
    local r = M.row(found, true)
    r.began_tick = M.began(found)
    r.note = M.NOTE
    return {watch=r, older=#older > 0 and older or nil, dropped_newer=#gone > 0 and gone or nil, latest_by='began_tick',
      line=r.line .. string.format('; the newest kept on %s by the tick it began (%s)', a.platform, r.began_tick and 'tick ' .. r.began_tick or 'armed, set at tick ' .. found.set)
        .. (#older > 0 and '; older kept on ' .. a.platform .. ': #' .. table.concat(older, ', #') or '') .. gone_text}
  end
  function M.call(p, a)
    local st = store()
    local who = api.who and api.who(p) or p.name
    M.check_read(a)
    if a.read == true then return latest(p, a) end
    if a.id ~= nil then
      assert(type(a.id) == 'number', 'id: a watch\'s number (flight_watch {} lists them)')
      for i, w in ipairs(st.list) do
        if w.id == a.id and w.force == p.force.name then
          if a.clear == true then dropped(st, w, 'cleared by ' .. tostring(who)); table.remove(st.list, i); M.reindex(); return {cleared=a.id, line='flight watch #' .. a.id .. ' cleared'} end
          if w.state == 'done' and not w.read_tick then w.read_tick = game.tick end
          local r = M.row(w, true)
          r.note = M.NOTE
          return {watch=r, line=r.line}
        end
      end
      error(missing(st, a.id, p.force.name), 0)
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
        for i, w in ipairs(st.list) do if w == rep then dropped(st, w, 'replaced while armed by #' .. (st.seq + 1)); table.remove(st.list, i); break end end
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
    for i = #st.list, 1, -1 do if drop[i] then dropped(st, st.list[i], 'past ' .. M.KEEP_DONE .. ' read or replaced watches kept a force'); table.remove(st.list, i) end end
    -- (QX1) a replaced watch that began (with replace: true and none counting, the platform's newest kept one done):
    -- the chain from the first one's start, and the gap from its end to this start
    local chain, chain_note
    if not (rep and rep.start) and a.replace == true then
      rep = nil
      for _, x in ipairs(st.list) do
        if x.force == p.force.name and x.index == pl.index and x.state == 'done' and x.start and (not rep or order(x) > order(rep)) then rep = x end
      end
    end
    if rep and rep.start and rep.state == 'done' then
      local rc = rep.chain
      local base = rc and rc.base or rep.ammo_began
      if base and rep.ammo1 then
        local ids, gaps, more = {}, {}, rc and rc.more or 0
        for _, id in ipairs(rc and rc.ids or {}) do ids[#ids+1] = id end
        ids[#ids+1] = rep.id
        for _, g in ipairs(rc and rc.gaps or {}) do gaps[#gaps+1] = copy(g) end
        gaps[#gaps+1] = {after=rep.id, before=st.seq + 1, from_tick=rep.ended, r0=rep.ammo1}
        while #ids > M.CHAIN do table.remove(ids, 1); more = more + 1 end
        while #gaps > M.CHAIN do table.remove(gaps, 1) end
        chain = {base=base, first=rc and rc.first or rep.id, ids=ids, more=more > 0 and more or nil, gaps=gaps, dep=rc and rc.dep or rep.ammo_dep}
      else chain_note = string.format('#%d began before ammunition was read: no ammunition chain', rep.id) end
    end
    st.seq = st.seq + 1
    local w = {id=st.seq, platform=pl.name, index=pl.index, force=p.force.name, setter=who, set=game.tick, from=from, minutes=minutes, state='armed', pl=pl, chain=chain}
    w.phase = pick_phase(st)
    st.list[#st.list+1] = w
    if from == 'now' then begin(w, pl, game.tick); sample(w, pl, game.tick)
    else w.seen_stopped = not flying(pl) end
    M.reindex()
    local r = M.row(w, false)
    r.replaced, r.ammunition_chain_note = replaced, chain_note
    local np = 0
    for _, t in ipairs(w.turrets or {}) do if t.buffer then np = np + 1 end end
    local nl = #(w.lasers or {})
    return {watch=r, replaced_watch=replaced_row, replaced_line=replaced_line, line=from == 'now' and string.format('flight watch #%d on %s: watching %d ammo turrets (%d railguns)%s and %d accumulators once a second from now until its next arrival or %d min', w.id, pl.name, #w.turrets, np,
        nl > 0 and string.format(', %d laser turrets', nl) or '', w.acc_n or 0, minutes)
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
    minutes='optional 1..480 (default 120): the longest it watches; it ends sooner at the platform\'s next arrival after it flew', replace='optional true: replace this platform\'s watch running or not read yet; the replaced one stays readable by id (a running one ends there, replaced by #N; an armed one is dropped) and no longer counts; the new one\'s ammunition_chain counts from the replaced one\'s start (none counting: the platform\'s newest kept watch done)',
    id='alone: read that watch in full (a done one is then kept 1 h and no longer counts against the limit); with clear: true, drop it', clear='true, with id: drop it',
    read='true, with platform alone (in a platform lane its platform): read that platform\'s newest kept watch by the tick it first began (watch.began_tick: a from-now watch\'s call, a from-departure one\'s departure, not moved by a mixed split; an armed one by its set tick) in full as id does (watch, older: the ids of older ones kept on it, newest first; dropped_newer: newer ones no longer kept [{id, set_tick, began_tick, end_tick, dropped_tick, why, line}]; line), or not_found and line when none is kept; never starts or replaces one; a queue step and dry_run check it',
    returns='start: watch, line, note, and on a replace replaced_watch (its row: id, state, ended_by, end_tick, replaced_by, line) and replaced_line; {}: watches (the force\'s, each with counts: whether it counts against the limit), lines, limit, counted, counting (the ids that count), limit_line; id: watch {id, platform, setter, state (armed: waiting for the departure, watching, done), from, minutes, set_tick, start_tick, end_tick, until_tick, ended_by, replaced_by, replaced_tick, leg, samples, seconds, '
      .. 'turrets (up to 24: those that read empty, the longest run first, then the lowest on ammo; turrets_more and turrets_more_line count the rest) [{unit_number, name, position, ammo, least, least_tick, at_start, now, empty_samples, empty_ticks, empty_runs, longest_empty_ticks, longest_from_tick, empty_now, gone_tick, added_tick, feed_start, feed_empty (the first trace begun after it first read empty), feed_end: {kind (maker, hub, chest, preload, none), gated, reaches, stop, tick}}], '
      .. 'sample_ticks, accumulators {count, capped, least_fraction, least_tick, at_start, now}, railguns (ammo turrets with an electric buffer, up to 64, the longest run below a shot\'s energy first) [{unit_number, name, position, shot_energy, least_energy, least_tick, energy_at_start, energy_now, below_samples, below_ticks, below_runs, longest_below_ticks, longest_below_from_tick, below_now, hits, shots_hit, damage, kills, gone_tick}], railgun_lines, '
      .. 'lasers (laser turrets, up to 64, the longest run below a shot\'s energy first) [{unit_number, name, quality, position, shot_energy, buffer, least_energy, least_tick, energy_at_start, energy_now, below_samples, below_ticks, below_runs, longest_below_samples, longest_below_ticks, longest_below_from_tick, below_now, kills, damage, kills_start, kills_end, gone_tick, added_tick}], laser_lines, lasers_more, lasers_capped, '
      .. 'damage {hits, damage, entities (damage by entity name), by (hits by cause)}, lost (up to 8), lost_count, repair_packs_used, hub_repair_packs {start, end}, fuel {start, end: {thruster-fuel, thruster-oxidizer: {held, in_tanks}}}, '
      .. 'ammunition (this window: {from_tick, to_tick, ticks, total, used {item: {quality: n}}}; each mixed.parts entry has its own and repair_packs_used), ammunition_watch (from the tick it began, after a split), ammunition_chain (after replace: true, from the first replaced watch\'s start: also watches, first), '
      .. 'ammunition_boundaries [{what (departure, arrival, between, start), from_tick, to_tick, ticks, total, used, line}], '
      .. 'foundation (this window; each mixed.parts entry has its own) {destroyed, rebuilt, destroyed_between_finds, rebuilt_from_before, open, placed, placed_built, open_placed, removed, taken {quality: n}, taken_total, hub_foundation {start, end}, first_destroyed_tick, last_destroyed_tick, rows [{tick, what, count, at, from_tick}], rows_more, skipped_finds, builds_heard}, lines, line, note}. '
      .. 'Sampled once a second, each watch on its own tick; at most 128 ammo turrets a watch (turrets built meanwhile are added within a minute); one watch that counts per platform of the force (armed, watching, or done and not read; a start at the limit is refused, naming them); kept in the save until cleared (read done ones 1 h after the read, replaced ones not read 24 h, at most 16 of those); the setter hears in team.alerts when one begins at a departure and when one ends'}}
  return M
end
