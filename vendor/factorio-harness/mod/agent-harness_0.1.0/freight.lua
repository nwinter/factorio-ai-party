-- freight: what a space platform carried, stop by stop and leg by leg (Luna,
-- shift12 12:47: of 995 agricultural science packs Sunward took from Gleba,
-- 200 spoiled on the way and 200 more at Nauvis, 595 went down; she put that
-- together from separate reads), and where a platform is, one rule for the
-- platforms row and the platform_arrived wait.
-- Once a game second (M.tick) each platform's hub (its main inventory and its
-- trash, which goes down at the next stop) is counted by item. A stop is the
-- time the platform is at a space location and not on its path; a leg is the
-- time it flies a space connection. Per stop: what the planet's landing pads
-- asked of what the hub held on arrival (expected down: the pads' requests less
-- what they hold, at most what the hub held), what the hub requests from that
-- planet (expected up: its minimum less what it held), what left the hub and
-- what came aboard (net over the stop), what spoiled aboard, and the rockets
-- launched to it with their cargo (on_rocket_launch_ordered). Spoiled: a
-- spoilable item's fall matched, in the same second, to the rise of what it
-- spoils into. The last KEEP segments are kept per platform.
-- Cargo pods (Astra, 21:20: left the hub is not delivered; she reconciled late pods at five stops): while a platform is
-- at a stop, the cargo pods leaving its hub (pods.lua's look at its surface once a second; without pods.lua, a look of
-- our own) are each followed (its surface, place and cargo) while it exists, as drops.lua follows a drop's pod. Gone after reaching the planet's surface: received by
-- the landing pad it was sent to, or landed as a cargo pod container where none was; gone before leaving the
-- platform: said so. A stop then says how many pods went down with what, what each pad received, and the pods still
-- in flight (their unit numbers and cargo).
local qflow = require('qflow')   -- (d24 batch152 PX1) statistics read at every quality
return function(api)
  local M = {}
  -- a signal's name, with @quality when not normal (d22 batch87 AW1: an uncommon signal read as the normal one)
  local function sigtext(s) local q = s.quality; if q and type(q) ~= 'string' then q = q.name end; return q and q ~= 'normal' and s.name .. '@' .. q or s.name end
  M.KEEP, M.SHOW, M.ITEMS, M.RECEIPTS = 8, 6, 6, 16
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  -- (d22 batch110 BT1) a property read or a method call under pcall with no closure made: try(function() return o.k end)
  -- made one (and an upvalue) at every read in the background jobs. pget(o, k): o.k, nil when o is nil or the read
  -- fails; pcall_method(o, k, ...): pcall of o.k(...), false when o.k is not there.
  local function get(o, k) return o[k] end
  local function pget(o, k) if o == nil then return nil end local ok, v = pcall(get, o, k); if ok then return v end end
  local function pcall_method(o, k, ...)
    if o == nil then return false end
    local ok, f = pcall(get, o, k)
    if not (ok and f) then return false end
    return pcall(f, ...)
  end
  local function len(x) return #x end
  local function same(a, b) return a == b end
  local function secs(ticks)
    local s = math.max(0, math.floor(ticks / 60 + 0.5))
    if s >= 60 then return string.format('%dm%02ds', math.floor(s / 60), s % 60) end
    return s .. 's'
  end
  M.secs = secs
  local POD_TICKS, POD_PENDING, POD_AFTER = 60, 64, 600
  local function xy(pos) return {x=math.floor(pos.x * 10 + 0.5) / 10, y=math.floor(pos.y * 10 + 0.5) / 10} end

  -- Where a platform is ------------------------------------------------------
  local function on_path(pl)
    local s = defines.space_platform_state and defines.space_platform_state.on_the_path
    return s ~= nil and pget(pl, 'state') == s
  end
  -- (BT1) a space connection's ends and length by its name (a prototype's facts; c.from and c.to made two prototype
  -- objects at each read, every second for each platform in flight)
  local CONN_ENDS = {}
  local function conn_ends(c)
    local name = pget(c, 'name')
    local k = type(name) == 'string' and CONN_ENDS[name]
    if k then return k[1], k[2], k[3] end
    local from, to = pget(pget(c, 'from'), 'name') or '?', pget(pget(c, 'to'), 'name') or '?'
    local length = pget(c, 'length') or 0
    if type(name) == 'string' then CONN_ENDS[name] = {from, to, length} end
    return from, to, length
  end
  -- (d23 batch131 CN1, Astra #2088) The end a platform flies to: the schedule's stop when it is one of the two ends;
  -- else, the stop beyond the connection, the end with the shorter way on to it (the km left to that end plus the
  -- shortest way from it: Asterion's guard set Aquilo mid edge->shattered-planet and it turned back to the edge, while
  -- the leg read on to the Shattered Planet with 4M km left and a fuel alarm); else the way `distance` moved since the
  -- last read (not paused: a paused platform drifts back); else the end it did not come from (last visited).
  local MOVED = {}  -- platform index -> {conn, d}: the last distance read
  local function heading_back(pl, c, from, to, length, d)
    local sch = pget(pl, 'schedule')
    local records = sch and sch.records
    local rec = records and records[sch.current or 1]
    local stop = rec and rec.station
    local idx, cname = pget(pl, 'index'), pget(c, 'name')
    local m = idx and MOVED[idx]
    local moved
    if m and m.conn == cname and m.d ~= d and not pget(pl, 'paused') then moved = d < m.d end
    if idx and not (m and m.conn == cname and m.d == d) then MOVED[idx] = {conn=cname, d=d} end
    if stop == from or stop == to then return stop == from end
    if stop and M.path then
      local pf, pt = M.path(from, stop), M.path(to, stop)
      if pf and pt then return d * length + pf.km < (1 - d) * length + pt.km end
      if pf or pt then return pf ~= nil end
    end
    if moved ~= nil then return moved end
    return pget(pget(pl, 'last_visited_space_location'), 'name') == to
  end
  -- The leg flown now, in the way it is flown: {from, to, flown (share of the
  -- leg behind it), left_km, eta_ticks, length}. A connection is measured from
  -- its own `from` end whichever way it is flown (pl.distance); the end headed
  -- for is heading_back's.
  function M.leg(pl)
    local c = pget(pl, 'space_connection')
    if not c then return nil end
    local from, to, length = conn_ends(c)
    local d = pget(pl, 'distance') or 0
    local back = heading_back(pl, c, from, to, length, d)
    local flown = back and 1 - d or d
    local left = (1 - flown) * length
    local speed = pget(pl, 'speed')
    -- Speeding up (well under its cruise): the rest at cruise speed (A4).
    local cruise = M.cruise and M.cruise(pl)
    local at_cruise = cruise and type(speed) == 'number' and speed < cruise * 0.9
    local v = at_cruise and cruise or speed
    -- (d20 batch54 N5, Sol #1390) a leg under way at its own measured speed once it has one, the cruise only while it
    -- speeds up (engine.lua leg_speed); speed_from says which
    local speed_from
    if api.leg_speed and type(speed) == 'number' then
      local segs = M.segments and M.segments(pl) or {}
      local sg = segs[#segs]
      local since = sg and sg.kind == 'leg' and not sg['end'] and sg.start and game.tick - sg.start or nil
      local s, by, own = api.leg_speed(pl, since, cruise, cruise and string.format('its cruise on the legs before, %.0f km/s', cruise * 60))
      if s then v, at_cruise, speed_from = s, not own, by end
    end
    -- turned_back: it left the end it flies to now (a turn back mid-connection, its from never reached)
    local heading = back and from or to
    local turned = pget(pget(pl, 'last_visited_space_location'), 'name') == heading or nil
    return {from=back and to or from, to=heading, flown=flown, length=length, left_km=left, turned_back=turned,
      eta_ticks=type(v) == 'number' and v > 0 and left / v or nil, back=back, speed_from=speed_from,
      eta_from=at_cruise and string.format('about: it speeds up (%.0f km/s now), the rest at its cruise of %.0f km/s', speed * 60, cruise * 60) or nil}
  end
  -- {at (a space location, when there), stopped (there and not on its path),
  -- leg (M.leg while flying), text}. The platforms row and platform_arrived
  -- both read this, so a wait is met exactly when the row says the platform is
  -- stopped there.
  -- departed (d19 batch48 2): the last departure a platform_schedule call caused, {from, tick, by} (space.lua), for
  -- wait_until platform_left begun just after it
  local function where_row(pl)
    local loc = pget(pget(pl, 'space_location'), 'name')
    if loc then
      if on_path(pl) then return {at=loc, stopped=false, text='at ' .. loc .. ', on its path (not stopped)'} end
      return {at=loc, stopped=true, text='at ' .. loc}
    end
    local l = M.leg(pl)
    if l and l.turned_back then
      return {leg=l, text=string.format('flying back to %s, %d km left (turned back on %s->%s)', l.to, math.floor(l.left_km + 0.5), l.to, l.from)}
    end
    if l then return {leg=l, text=string.format('flying %s->%s %d%%', l.from, l.to, math.floor(l.flown * 100 + 0.5))} end
    return {text='nowhere'}
  end
  function M.where(pl)
    local w = where_row(pl)
    local st
    if api.state then local ok, v = pcall(api.state); if ok then st = v end end
    w.departed = st and st.schedule_departures and st.schedule_departures[pl.name] or nil
    return w
  end

  -- Counting -----------------------------------------------------------------
  local function store()
    local st = api.state()
    st.freight = st.freight or {}
    return st.freight
  end
  local function add_contents(out, list)
    for k, v in pairs(list or {}) do
      local name = type(v) == 'table' and v.name or k
      if type(name) == 'table' then name = name.name end
      local n = type(v) == 'table' and v.count or v
      if type(name) == 'string' and type(n) == 'number' and n > 0 then out[name] = (out[name] or 0) + n end
    end
    return out
  end
  -- (d24 batch167 QJ1, Sol #2224: a watch's pod of 2 legendary thrusters counted as none) the same list by
  -- "name@quality" (normal: "name@normal"), for a pod's or rocket's cargo beside cargo by name (every quality together)
  local function add_contents_q(out, list)
    for _, v in pairs(list or {}) do
      if type(v) == 'table' and type(v.name) == 'string' and type(v.count) == 'number' and v.count > 0 then
        local q = type(v.quality) == 'table' and v.quality.name or v.quality or 'normal'
        local key = v.name .. '@' .. tostring(q)
        out[key] = (out[key] or 0) + v.count
      end
    end
    return out
  end
  -- The hub's items, its main inventory and its trash, by name (every quality together); by_quality (d22 batch91 BA1):
  -- by "name@quality" instead.
  -- (d22 batch110 BT1: freight.tick made 502 KB a second on a copy of world n, most of it each hub's get_contents, a
  -- table for every kind of item, every second for every platform; shipment.tick read it twice more) Per platform, kept
  -- while its hub is the same entity: the hub's two inventories, each inventory's get_item_count and the kinds of item
  -- (name and quality) its last full read found. A read counts those kinds one by one (get_item_count({name, quality}):
  -- a number, no table) and takes them while they add up to the inventory's total (get_item_count(): every item of every
  -- quality); then no other kind is in it and the counts are get_contents' own. Else (a new kind came in) it reads
  -- get_contents again. An inventory whose full read and counts disagree once is always read in full. A kind gone to 0
  -- stays among those counted (an item that comes and goes does not force a full read each time), up to HUB_KINDS
  -- kinds; an inventory holding more is read in full (a count is a call scanning the inventory: about as much time as
  -- get_contents makes for one kind, without its table). The platform's item production statistics and their two
  -- counting methods are kept with it (ammo_counts). Module state: found again after a load.
  M.HUB_KINDS = 64
  local HUB_INVS = {'hub_main', 'hub_trash'}
  local plats = {}  -- platform index -> {hub, invs = {[1]=slot, [2]=slot}, stats, made, used}
  local QID = {name='', quality='normal'}
  local SCRATCH = {}
  local function plat(pl)
    local hub = pget(pl, 'hub')
    if not (hub and hub.valid) then return nil, hub end
    local idx = pget(pl, 'index')
    if idx == nil then return nil, hub end
    local c = plats[idx]
    if c then
      local ok, is = pcall(same, c.hub, hub)
      if not (ok and is) then c = nil end
    end
    if not c then c = {hub=hub, invs={}}; plats[idx] = c end
    return c, hub
  end
  -- an inventory's slot: {inv, count (its get_item_count), names, quals, keys (name@quality), bad}; nil with none
  local function inv_slot(c, hub, k)
    local slot = c and c.invs[k]
    if slot and pget(slot.inv, 'valid') ~= false then return slot end
    local id = defines.inventory[HUB_INVS[k]]
    local ok, inv = false, nil
    if id then ok, inv = pcall_method(hub, 'get_inventory', id) end
    if not (ok and inv) then return nil end
    local count = pget(inv, 'get_item_count')
    slot = {inv=inv, count=type(count) == 'function' and count or nil}
    -- kept only with its own counting method (a test's table hub hands out new inventories)
    if c and slot.count then c.invs[k] = slot end
    return slot
  end
  -- The kinds' counts into SCRATCH; true when they add up to the inventory's total.
  local function slot_known(slot)
    local names, quals, count = slot.names, slot.quals, slot.count
    if not names or slot.bad or not count or #names > M.HUB_KINDS then return false end
    local ok, total = pcall(count)
    if not ok or type(total) ~= 'number' then return false end
    local sum = 0
    for i = 1, #names do
      QID.name, QID.quality = names[i], quals[i]
      local ok2, n = pcall(count, QID)
      if not ok2 or type(n) ~= 'number' then return false end
      SCRATCH[i] = n
      sum = sum + n
    end
    return sum == total
  end
  -- After a full read: its kinds (then the kinds counted before that it lacks now, at 0, up to HUB_KINDS), checked
  -- against get_item_count (each kind and the total) before they are used.
  local function slot_learn(slot, list)
    if slot.bad or not slot.count then return end
    local names, quals, keys = {}, {}, {}
    local had = {}
    for _, v in pairs(list or {}) do
      local q = type(v) == 'table' and v.quality
      if q == nil or q == false then q = 'normal' end
      if type(v) ~= 'table' or type(v.name) ~= 'string' or type(q) ~= 'string' or type(v.count) ~= 'number' then slot.bad = true; slot.names = nil; return end
      if v.count > 0 then
        local key = v.name .. '@' .. q
        names[#names+1], quals[#quals+1], keys[#keys+1] = v.name, q, key
        had[key] = v.count
      end
    end
    if #names > M.HUB_KINDS then slot.names = nil; return end
    local old_names, old_quals = slot.names, slot.quals
    for i, key in ipairs(old_names and slot.keys or {}) do
      if #names >= M.HUB_KINDS then break end
      if not had[key] then names[#names+1], quals[#quals+1], keys[#keys+1] = old_names[i], old_quals[i], key; had[key] = 0 end
    end
    slot.names, slot.quals, slot.keys = names, quals, keys
    if not slot_known(slot) then slot.bad = true; slot.names = nil; return end
    -- each kind as the full read counted it (0 for those it did not list)
    for i = 1, #names do
      if SCRATCH[i] ~= had[keys[i]] then slot.bad = true; slot.names = nil; return end
    end
  end
  local function hub_counts_into(pl, by_quality, out)
    local c, hub = plat(pl)
    if not (hub and hub.valid) then return nil end
    for k = 1, #HUB_INVS do
      local slot = inv_slot(c, hub, k)
      if slot and slot_known(slot) then
        local names, keys = slot.names, slot.keys
        for i = 1, #names do
          local n = SCRATCH[i]
          if n > 0 then
            local key = by_quality and keys[i] or names[i]
            out[key] = (out[key] or 0) + n
          end
        end
      elseif slot then
        local inv = slot.inv
        local ok, list = pcall_method(inv, 'get_contents')
        if not ok then list = nil end
        if by_quality then
          for _, v in pairs(list or {}) do
            local q = type(v) == 'table' and (type(v.quality) == 'string' and v.quality or type(v.quality) == 'table' and v.quality.name) or 'normal'
            if type(v) == 'table' and type(v.name) == 'string' and (v.count or 0) > 0 then
              local key = v.name .. '@' .. q
              out[key] = (out[key] or 0) + v.count
            end
          end
        else add_contents(out, list) end
        if c then slot_learn(slot, list) end
      end
    end
    return out
  end
  function M.hub_counts(pl, by_quality)
    return hub_counts_into(pl, by_quality, {})
  end
  -- Ammunition and repair packs aboard by place (Sol, Astra 06:21-09:37: Tern's endurance read 42 rockets in the hub
  -- and turrets while 344 more sat on about 310 belt tiles): the hub's main inventory, the turrets' ammo slots, belts
  -- (each transport line; an underground's buried part is on the input's lines 3 and 4, and an output's line equal to
  -- its input's is counted once), inserter hands, and the machines' outputs. want: item name -> true (default every
  -- ammo and repair-tool item). Belts past MAX_BELTS are left out and said (capped).
  M.MAX_BELTS = 8000
  local WANT
  local function want_default()
    if not WANT then
      WANT = {}
      for name, item in pairs(prototypes.item) do if item.type == 'ammo' or item.type == 'repair-tool' then WANT[name] = true end end
    end
    return WANT
  end
  local BELTS = {'transport-belt', 'underground-belt', 'splitter', 'loader', 'loader-1x1', 'linked-belt'}
  -- (d22 batch96 BF1) Each platform's belts and inserter hands, read in the background for the platforms read lately
  -- (stock_places): {wanted (tick), done {tick, belts, hands, belt_entities, capped}, job}. One job at a time: every
  -- BELT_STEP ticks one band of the platform's chunks (walk.lua, one chunk a band), each belt's lines (an underground
  -- exit's buried lines are its entrance's: once) and each inserter's hand.
  M.BELT_EVERY, M.BELT_KEEP, M.BELT_STEP, M.BELT_BAND, M.BELT_BANDS = 3600, 36000, 3, 100, 8
  local function belt_store()
    local s = api.state()
    s.platform_belts = s.platform_belts or {}
    return s.platform_belts
  end
  local walker
  local function walk() walker = walker or api.walk or require('walk'){state=api.state}; return walker end
  local READ_TYPES = {'transport-belt', 'underground-belt', 'splitter', 'loader', 'loader-1x1', 'lane-splitter', 'linked-belt', 'inserter',
    'ammo-turret', 'thruster', 'storage-tank'}
  -- (d22 batch110 BT1: 53.5 KB a step on a copy of world n, every 3 ticks) the platform read now and its surface, kept
  -- between steps while it is valid (module state: found again after a load); the band's filter, one table; each
  -- transport belt prototype's line count (get_max_transport_line_index, a fact of the prototype) by its name, and an
  -- underground's by its side too
  local belt_pl, belt_s
  local BAND_FILTER = {type=READ_TYPES}
  local BELT_LINES = {}
  -- One belt's items into `into`: each line's (an underground exit's buried lines 3 and 4 when they are its entrance's:
  -- once), an empty line passed over (#line: its item count, no table made)
  local function belt_items(e, t, into)
    local name = e.name
    local side = t == 'underground-belt' and pget(e, 'belt_to_ground_type') or nil
    local by = BELT_LINES[side or '']
    if not by then by = {}; BELT_LINES[side or ''] = by end
    local lines = type(name) == 'string' and by[name]
    if not lines then
      local ok, n = pcall_method(e, 'get_max_transport_line_index')
      lines = ok and n or 0
      if type(name) == 'string' and ok and type(n) == 'number' then by[name] = n end
    end
    local gtl = lines > 0 and pget(e, 'get_transport_line')
    local partner
    for i = 1, gtl and lines or 0 do
      local ok, line = pcall(gtl, i)
      if ok and line then
        local okn, n = pcall(len, line)
        if not (okn and n == 0) then
          local dup = false
          if i > 2 and side == 'output' then
            if partner == nil then
              local nb = pget(e, 'neighbours')
              partner = nb and nb.valid and nb or false
            end
            if partner then
              local okp, pline = pcall_method(partner, 'get_transport_line', i)
              local oke, is = false, nil
              if okp then oke, is = pcall_method(line, 'line_equals', pline) end
              dup = oke and is
            end
          end
          if not dup then
            local okc, list = pcall_method(line, 'get_contents')
            for _, r in ipairs(okc and list or {}) do into[r.name] = (into[r.name] or 0) + r.count end
          end
        end
      end
    end
  end
  function M.belt_tick(tick)
    if tick % M.BELT_STEP ~= 0 then return end
    local bt = belt_store()
    local active = bt.active
    local rec = active and bt[active]
    local pl, s
    if rec and rec.job then
      if belt_pl and belt_pl.valid and belt_pl.index == active and belt_s and belt_s.valid then pl, s = belt_pl, belt_s
      else
        for _, f in pairs(game.forces) do
          for _, p in pairs(pget(f, 'platforms') or {}) do if p.index == active then pl = p end end
        end
        s = pl and pl.valid and pl.surface or nil
        belt_pl, belt_s = pl, s
      end
    end
    if not (pl and pl.valid and s) then
      bt.active = nil
      belt_pl, belt_s = nil, nil
      if rec then rec.job = nil end
      -- the next: a platform read within BELT_KEEP whose read is oldest and older than BELT_EVERY (none such among
      -- the reads kept: no platform looked at)
      local any = false
      for idx, r in pairs(bt) do
        if type(idx) == 'number' and type(r) == 'table' and r.wanted and tick - r.wanted <= M.BELT_KEEP
          and (r.done and tick - r.done.tick or math.huge) >= M.BELT_EVERY then any = true; break end
      end
      if not any then return end
      local best, best_age
      for _, f in pairs(game.forces) do
        for _, p in pairs(pget(f, 'platforms') or {}) do
          local r = bt[p.index]
          if r and r.wanted and tick - r.wanted <= M.BELT_KEEP then
            local age = r.done and tick - r.done.tick or math.huge
            if age >= M.BELT_EVERY and (not best or age > best_age) and p.valid and p.surface then best, best_age = p, age end
          end
        end
      end
      if not best then return end
      -- the walk's box: the platform's chunks (walk.lua's start grows it by 4 chunks round each, mostly empty space)
      local box
      local bs = best.surface
      for c in bs.get_chunks() do
        if not box then box = {left=c.x, right=c.x, top=c.y, bottom=c.y}
        else box.left, box.right = math.min(box.left, c.x), math.max(box.right, c.x); box.top, box.bottom = math.min(box.top, c.y), math.max(box.bottom, c.y) end
      end
      if not box then bt[best.index].done = {tick=tick, belts={}, hands={}, belt_entities=0}; return end
      bt[best.index].job = {start=tick, walk={surface=bs.index, box=box, x=box.left, y=box.top, rows=1, band_rows=1, cols=1, max=1},
        belts={}, hands={}, n=0, turrets={}, tanks={}}
      bt.active = best.index
      belt_pl, belt_s = best, bs
      return
    end
    local job = rec.job
    -- what the bands found waits in job.queue; a step reads at most BELT_BAND of it (a chunk may hold 600 belts), and
    -- with it empty finds bands (one chunk each, at most BELT_BANDS: empty space goes quickly) until it holds some
    -- (BT1: the first band holding some is the queue itself, not copied; the step reads it in place)
    local queue = job.queue or {}
    job.queue, job.qi = queue, job.qi or 1
    if job.qi > #queue then
      queue = nil
      BAND_FILTER.force = pl.force
      for _ = 1, M.BELT_BANDS do
        local band = walk().band(job.walk, s, BAND_FILTER)
        if not band then job.walked = true; break end
        queue = band
        if #band > 0 then break end
      end
      BAND_FILTER.force = nil
      queue = queue or {}
      job.queue, job.qi = queue, 1
      if job.walked and #queue == 0 then
        rec.done = {tick=job.start, belts=job.belts, hands=job.hands, belt_entities=job.n, capped=job.capped, turrets=job.turrets, tanks=job.tanks}
        rec.job, bt.active = nil, nil
        return
      end
    end
    local first, last = job.qi, math.min(#queue, job.qi + M.BELT_BAND - 1)
    job.qi = last + 1
    for i = first, last do
      local e = queue[i]
      if e.valid then
        -- (the platforms read's ammo and fuel: the turrets, thrusters and tanks the walk met, entity references)
        local t = e.type
        if t == 'ammo-turret' then job.turrets[#job.turrets+1] = e
        elseif t == 'thruster' or t == 'storage-tank' then job.tanks[#job.tanks+1] = e
        elseif t == 'inserter' then
          local h = pget(e, 'held_stack')
          if h and pget(h, 'valid_for_read') then job.hands[h.name] = (job.hands[h.name] or 0) + h.count end
        elseif job.n < M.MAX_BELTS then
          job.n = job.n + 1
          belt_items(e, t, job.belts)
        else job.capped = M.MAX_BELTS end
      end
    end
  end
  -- (BF1) A platform's turrets, and its thrusters and tanks, as its last background read listed them (valid ones),
  -- {turrets, tanks, tick}; nil before one, and nil when a count finds more of them aboard now (one built since: the
  -- listed ones still there are among those counted, so as many means the same ones). The platform counts as read
  -- lately (its read is kept fresh).
  function M.platform_lists(pl)
    if not pl.index then return nil end
    local bt = belt_store()
    local rec = bt[pl.index] or {}
    bt[pl.index] = rec
    rec.wanted = game and game.tick or 0
    local d = rec.done
    if not (d and d.turrets) then return nil end
    local function valid(list) local out = {} for _, e in ipairs(list) do if e.valid then out[#out+1] = e end end return out end
    local out = {turrets=valid(d.turrets), tanks=valid(d.tanks or {}), tick=d.tick}
    local n = try(function() return pl.surface.count_entities_filtered{type={'ammo-turret', 'thruster', 'storage-tank'}, force=pl.force} end)
    if n ~= #out.turrets + #out.tanks then return nil end
    return out
  end
  function M.stock_places(pl, want)
    want = want or want_default()
    local s, f = pl.surface, pl.force
    local out = {hub={}, turrets={}, belts={}, hands={}, machines={}, belt_entities=0}
    local function put(place, name, n)
      if want[name] and n and n > 0 then out[place][name] = (out[place][name] or 0) + n end
    end
    local function contents(place, inv)
      for _, r in ipairs(inv and try(function() return inv.get_contents() end) or {}) do put(place, r.name, r.count) end
    end
    local hub = try(function() return pl.hub end)
    if hub and hub.valid and defines.inventory.hub_main then contents('hub', try(function() return hub.get_inventory(defines.inventory.hub_main) end)) end
    -- (d22 batch96 BF1: on a copy of world n, Asterion's 6,651 belts took 24 ms to find and 44 ms to read, in each
    -- platform, platform_endurance and preflight read) belts and inserter hands from the platform's last background
    -- read (M.belt_tick: a band of its chunks every few ticks, each platform read lately refreshed every BELT_EVERY),
    -- as_of its tick; turrets and machines found and read now. With none yet: the census pass's (as_of its start),
    -- else all read now.
    local bt = belt_store()
    local rec = pl.index and bt[pl.index] or {}
    if pl.index then bt[pl.index] = rec end
    rec.wanted = game and game.tick or 0
    local idx = not rec.done and api.census_where and try(function() return api.census_where(f, s) end)
    local from = rec.done or idx
    if from then
      for name, n in pairs(from.belts or {}) do put('belts', name, n) end
      for name, n in pairs(from.hands or {}) do put('hands', name, n) end
      if rec.done then out.as_of, out.from_belt_read, out.belt_entities = rec.done.tick, true, rec.done.belt_entities
      else out.as_of, out.from_census, out.belt_entities = idx.as_of, true, nil end
      out.capped = rec.done and rec.done.capped or nil
      for _, e in ipairs(try(function() return s.find_entities_filtered{type='ammo-turret', force=f} end) or {}) do
        contents('turrets', try(function() return e.get_inventory(defines.inventory.turret_ammo) end))
      end
      for _, e in ipairs(try(function() return s.find_entities_filtered{type={'assembling-machine', 'furnace'}, force=f} end) or {}) do
        contents('machines', try(function() return e.get_output_inventory() end))
      end
      out.total = {}
      for _, place in ipairs({'hub', 'turrets', 'belts', 'hands', 'machines'}) do
        for name, n in pairs(out[place]) do out.total[name] = (out.total[name] or 0) + n end
      end
      return out
    end
    for _, e in ipairs(try(function() return s.find_entities_filtered{type='ammo-turret', force=f} end) or {}) do
      contents('turrets', try(function() return e.get_inventory(defines.inventory.turret_ammo) end))
    end
    local list = try(function() return s.find_entities_filtered{type=BELTS, force=f, limit=M.MAX_BELTS + 1} end) or {}
    if #list > M.MAX_BELTS then out.capped = M.MAX_BELTS; list[#list] = nil end
    out.belt_entities = #list
    for _, e in ipairs(list) do
      local lines = try(function() return e.get_max_transport_line_index() end) or 0
      local partner = e.type == 'underground-belt' and try(function() return e.belt_to_ground_type end) == 'output'
        and try(function() local n = e.neighbours; return n and n.valid and n or nil end)
      for i = 1, lines do
        local line = try(function() return e.get_transport_line(i) end)
        local same = partner and i > 2 and try(function() return line.line_equals(partner.get_transport_line(i)) end)
        if line and not same then
          for _, r in ipairs(try(function() return line.get_contents() end) or {}) do put('belts', r.name, r.count) end
        end
      end
    end
    for _, e in ipairs(try(function() return s.find_entities_filtered{type='inserter', force=f} end) or {}) do
      local h = try(function() return e.held_stack end)
      if h and try(function() return h.valid_for_read end) then put('hands', h.name, h.count) end
    end
    for _, e in ipairs(try(function() return s.find_entities_filtered{type={'assembling-machine', 'furnace'}, force=f} end) or {}) do
      contents('machines', try(function() return e.get_output_inventory() end))
    end
    out.total = {}
    for _, place in ipairs({'hub', 'turrets', 'belts', 'hands', 'machines'}) do
      for name, n in pairs(out[place]) do out.total[name] = (out.total[name] or 0) + n end
    end
    return out
  end
  -- The places without totals, kept on a segment at its ends (the loading and the firing told apart).
  function M.places_snapshot(pl)
    local sp = try(function() return M.stock_places(pl) end)
    if not sp then return nil end
    return {hub=sp.hub, turrets=sp.turrets, belts=sp.belts, hands=sp.hands, machines=sp.machines, capped=sp.capped}
  end
  -- How one item's count changed by place between two snapshots: 'hub -300, belts +280, turrets +12' (unchanged
  -- places left out), or nil with no change or no second snapshot.
  function M.moved_text(a, b, name)
    if not (a and b) then return nil end
    local parts = {}
    for _, place in ipairs({'hub', 'turrets', 'belts', 'hands', 'machines'}) do
      local d = ((b[place] or {})[name] or 0) - ((a[place] or {})[name] or 0)
      if d ~= 0 then parts[#parts+1] = string.format('%s %+d', place, d) end
    end
    return #parts > 0 and table.concat(parts, ', ') or 'no change by place'
  end
  -- One item's places as text: 'hub 42, turrets 16, belts 344, hands 2' (places holding none left out).
  function M.places_text(sp, name)
    local parts = {}
    for _, place in ipairs({'hub', 'turrets', 'belts', 'hands', 'machines'}) do
      local n = sp[place][name] or 0
      if n > 0 then parts[#parts+1] = place .. ' ' .. n end
    end
    return #parts > 0 and table.concat(parts, ', ') or 'none aboard'
  end
  local results = {}
  function M.spoils(name) return (try(function() return prototypes.item[name].get_spoil_ticks() end) or 0) > 0 end
  -- What an item spoils into, or false (it does not spoil, or spoils into no item).
  function M.spoil_result(name)
    local r = results[name]
    if r == nil then
      r = false
      local proto = prototypes.item[name]
      if proto and M.spoils(name) then
        r = try(function() local x = proto.spoil_result; return x and (type(x) == 'string' and x or x.name) end) or false
      end
      results[name] = r
    end
    return r
  end
  local function copy(t) local out = {}; for k, v in pairs(t or {}) do out[k] = v end; return out end
  -- The planet's landing pads of the force: what they ask (active sections'
  -- minimums) and hold, by item.
  local function pads(planet, force)
    local s = try(function() return game.planets[planet].surface end) or try(function() return game.get_surface(planet) end)
    local ask, hold = {}, {}
    if not s then return ask, hold end
    -- (d19 batch44 A2: shipment {item} found each stop's pads, 10.5 ms a find on the private copy's Nauvis) the census
    -- pass's pads of ours when it has them
    local known = api.census_typed and try(function() return api.census_typed(force, s, 'cargo-landing-pad') end)
    for _, pad in ipairs(known or try(function() return s.find_entities_filtered{type='cargo-landing-pad', force=force} end) or {}) do
      local secs_ = try(function() return pad.get_logistic_sections() end)
      for i = 1, secs_ and secs_.sections_count or 0 do
        local sec = secs_.get_section(i)
        if sec and sec.active ~= false then
          for _, f in ipairs(sec.filters or {}) do
            local v = f.value
            local name = type(v) == 'table' and v.name or v
            if type(name) == 'string' and (f.min or 0) > 0 then ask[name] = (ask[name] or 0) + f.min end
          end
        end
      end
      local inv = defines.inventory.cargo_landing_pad_main and try(function() return pad.get_inventory(defines.inventory.cargo_landing_pad_main) end)
      if inv then add_contents(hold, try(function() return inv.get_contents() end)) end
    end
    return ask, hold
  end
  M.pads = pads
  -- (d24 batch137 PI1, Sol #2107: Petrel at Nauvis kept all 1980 calcite under calcite 200..inf from nauvis while the
  -- pad asked 2000, and shipment said 1776 would go down) What a hub keeps at a stop, as 2.0.77 did on a copy of world n
  -- (d24, Petrel and Petrel III at Nauvis): only its active sections importing from that planet count (sections
  -- importing from other planets kept nothing there; a slot always names a planet); their maxes add up (100..300 and
  -- 200..400 kept 700); an infinite max keeps it all, whatever the pads ask; with a finite max the hub sends down all it
  -- holds above it, to the pad, whether a pad asks or not (200..500 with no request on the pad: 1000 of 1500 went down);
  -- an item no such section names goes down as far as the pads ask (their ask less what they hold). secs: the hub's
  -- logistic sections. Returns {item={max (math.huge: none), parts={'hub section 1 keeps calcite 200..inf at nauvis'}}}.
  function M.hub_keeps_at(secs, planet)
    local out = {}
    for i = 1, secs and secs.sections_count or 0 do
      local sec = try(function() return secs.get_section(i) end)
      if sec and sec.active ~= false then
        for _, f in ipairs(try(function() return sec.filters end) or {}) do
          local v = f.value
          local name = type(v) == 'table' and v.name or v
          if type(name) == 'table' then name = name.name end
          local from = f.import_from and (type(f.import_from) == 'string' and f.import_from or pget(f.import_from, 'name'))
          if type(name) == 'string' and from == planet then
            local k = out[name] or {max=0, parts={}}
            k.max = k.max + (f.max or math.huge)
            k.parts[#k.parts+1] = string.format('hub section %d keeps %s %d..%s at %s', i, name, f.min or 0, f.max and tostring(f.max) or 'inf', planet)
            out[name] = k
          end
        end
      end
    end
    return out
  end
  -- What the hub gives up of an item it holds (held) at that stop by those rules, the pads wanting want (their ask less
  -- what they hold): the count, and the keep row ({max, parts}) or nil when no section names it.
  -- (d24 batch142 PN1) off: the stop does not unload (M.unloads), and the pads there take nothing; a finite max still
  -- sends down all above it.
  function M.hub_gives(keep, item, held, want, off)
    if off then want = 0 end
    local k = keep and keep[item]
    if not k then return math.max(0, math.min(held or 0, want or 0)), nil end
    if k.max == math.huge then return 0, k end
    return math.max(0, (held or 0) - k.max), k
  end
  -- (d24 batch142 PN1, Sol #2135, Luna #2136) a schedule stop's allow unloading: the schedule GUI's checkbox, the
  -- record's allows_unloading (LuaSchedule.set_allow_unloading). Off, as 2.0.77 did on a copy of world n (d24, Petrel
  -- II waiting at Nauvis): the landing pad asking carbon took none of the hub's 179 (on again, 83 went down in 20 s);
  -- all above a finite max still went down (49 transport belts under 0..10: 39 went down; under 0..4, 6 more); a drop's
  -- cargo pod landed in the pad.
  M.NO_UNLOAD_RULE = 'with unloading off at a stop the landing pads there take nothing from the hub; all the hub holds above a finite max of its sections for that planet still goes down, and drop still sends pods'
  -- The record of pl's schedule for planet whose unloading is off: index (that record), else the current record when it
  -- is at planet, else the first at planet from the current one on. Returns the record's index and a line, or nil when
  -- that record unloads (or no record is at planet).
  function M.no_unload(pl, planet, index)
    local sch = try(function() return pl.schedule end)
    local recs = sch and sch.records or {}
    local n, cur = #recs, sch and sch.current or 1
    if not index then
      for k = 0, n - 1 do
        local i = (cur - 1 + k) % n + 1
        if recs[i].station == planet then index = i; break end
      end
    end
    local r = index and recs[index]
    if not (r and r.station == planet and r.allows_unloading == false) then return nil end
    return index, string.format('stop %d (%s) has unloading off: its landing pads take nothing from the hub there; all above a finite max still goes down', index, planet)
  end
  -- "hub section 1 keeps calcite 200..inf at nauvis" (and the others naming it)
  function M.keep_text(k) return k and table.concat(k.parts, '; ') or nil end
  -- (d20 batch132 PD1, Sol #2093: pods of 1000 and 300 processing units came down to Gleba's pad for a section asking
  -- 300; the pad's section 1, set by the circuit network, asked processing-unit 1000..inf when they left the hub and no
  -- more when Sol read it) what the planet's landing pad of ours asked of each item in cargo when a pod left the hub, as
  -- the pad's window showed it then: each active section asking it (its index, min..max, set by the circuit network),
  -- and what the pad held. {pad {x,y}, items {name={ask, hold, parts}}}, or nil with no pad there.
  local function pad_asked(planet, force, cargo)
    local s = try(function() return game.planets[planet].surface end) or try(function() return game.get_surface(planet) end)
    local known = s and api.census_typed and try(function() return api.census_typed(force, s, 'cargo-landing-pad') end)
    local pad = known and known[1] or s and try(function() return s.find_entities_filtered{type='cargo-landing-pad', force=force, limit=1}[1] end)
    if not (pad and pget(pad, 'valid')) then return nil end
    local circuit = defines.logistic_section_type and defines.logistic_section_type.circuit_controlled
    local items = {}
    for name in pairs(cargo or {}) do items[name] = {ask=0, hold=0, parts={}} end
    local secs_ = try(function() return pad.get_logistic_sections() end)
    for i = 1, secs_ and secs_.sections_count or 0 do
      local sec = secs_.get_section(i)
      if sec and sec.active ~= false then
        local by_circuit = circuit ~= nil and pget(sec, 'type') == circuit
        for _, f in ipairs(sec.filters or {}) do
          local v = f.value
          local name = type(v) == 'table' and v.name or v
          local it = type(name) == 'string' and items[name]
          if it and (f.min or 0) > 0 then
            it.ask = it.ask + f.min
            it.parts[#it.parts+1] = string.format('section %d%s: %d..%s', i, by_circuit and ', set by the circuit network' or '', f.min, f.max and tostring(f.max) or 'inf')
          end
        end
      end
    end
    local inv = defines.inventory.cargo_landing_pad_main and try(function() return pad.get_inventory(defines.inventory.cargo_landing_pad_main) end)
    -- (QJ1) every quality: get_item_count(name) counts normal only, and cargo is by name with every quality together;
    -- a count per quality (Nauvis's pad on a copy of world n: get_contents 0.58 ms, 5 counts 6.6 us)
    for name, it in pairs(items) do
      local n = 0
      for _, q in ipairs(inv and qflow.qualities() or {}) do n = n + (try(function() return inv.get_item_count({name=name, quality=q}) end) or 0) end
      it.hold = n
    end
    -- the pad's own on-the-way count (its requester point's deliveries: the pods sent to it, this one among them once
    -- it is sent)
    local pt = try(function() return pad.get_requester_point() end)
    for _, d in ipairs(pt and try(function() return pt.targeted_items_deliver end) or {}) do
      local it = items[d.name]
      if it then it.coming = (it.coming or 0) + (d.count or 0) end
    end
    return {pad=xy(pad.position), items=items}
  end
  M.pad_asked = pad_asked
  -- The line for a pod's pad_asked: "when it left the hub the pad asked processing-unit 1300 (section 1, set by the
  -- circuit network: 1000..inf; section 12: 300..300), held 0, 1000 on the way in pods followed, counted 1300 on the
  -- way" (the last: the pad's own count).
  function M.asked_text(a)
    if not a then return nil end
    local names = {}
    for name in pairs(a.items or {}) do names[#names+1] = name end
    table.sort(names)
    local parts = {}
    for _, name in ipairs(names) do
      local it = a.items[name]
      parts[#parts+1] = string.format('%s %d%s, held %d%s%s', name, it.ask, #it.parts > 0 and ' (' .. table.concat(it.parts, '; ') .. ')' or ' (no active section asks it)',
        it.hold, (it.way or 0) > 0 and string.format(', %d on the way in pods followed', it.way) or '',
        it.coming and string.format(', counted %d on the way', it.coming) or '')
    end
    return #parts > 0 and 'when it left the hub the pad asked ' .. table.concat(parts, '; ') or nil
  end
  -- The hub's requests that import from this planet: {item={min, short, way}}; (d20 batch55 P6) less what rockets
  -- launched to the hub carry on the way (its requester point's deliveries, the hub GUI's in-transit count).
  local function hub_asks(pl, planet, counts)
    local out = {}
    local way = {}
    local pt = defines.logistic_member_index and defines.logistic_member_index.space_platform_hub_requester
      and try(function() return pl.hub.get_logistic_point(defines.logistic_member_index.space_platform_hub_requester) end)
    for _, it in ipairs(pt and try(function() return pt.targeted_items_deliver end) or {}) do way[it.name] = (way[it.name] or 0) + (it.count or 0) end
    local secs_ = try(function() return pl.hub.get_logistic_sections() end)
    for i = 1, secs_ and secs_.sections_count or 0 do
      local sec = secs_.get_section(i)
      if sec and sec.active ~= false then
        for _, f in ipairs(sec.filters or {}) do
          local v = f.value
          local name = type(v) == 'table' and v.name or v
          local from = f.import_from and (type(f.import_from) == 'string' and f.import_from or try(function() return f.import_from.name end))
          if type(name) == 'string' and from == planet and (f.min or 0) > 0 then
            local r = out[name] or {min=0}
            r.min = r.min + f.min
            r.way = way[name] and way[name] > 0 and way[name] or nil
            r.short = math.max(0, r.min - (counts[name] or 0) - (way[name] or 0))
            out[name] = r
          end
        end
      end
    end
    return out
  end
  -- Ammo (Astra, shift14 22:50: each ammo type made and used over the last leg and the reserve at arrival, reconciled
  -- by hand every flight): the platform surface's item statistics, as the game's production screen counts them, for
  -- every ammo item, taken when a stop or leg opens and when it ends. 2.0.77 on a copy of world n: over 60 s Sunward's
  -- surface counted 51 firearm magazines made and 126 used (its turrets' shots) while its hub and turrets fell by 71.
  local AMMO, AMMO_SET
  local function ammo_names()
    if not AMMO then
      AMMO, AMMO_SET = {}, {}
      for name, item in pairs(prototypes.item) do if item.type == 'ammo' then AMMO[#AMMO+1] = name; AMMO_SET[name] = true end end
      table.sort(AMMO)
    end
    return AMMO
  end
  local function stats_of(pl, kind)
    local ok, stats = pcall_method(pget(pl, 'force'), kind, pget(pl, 'surface'))
    if ok then return stats end
  end
  -- (BT1: every ammunition's two counts read through a new closure and a new method object, about 5 KB a platform a
  -- second) the platform's item statistics and their get_input_count and get_output_count, kept with its hub (plat)
  -- while valid; read anew without a hub.
  local EMPTY_Q = {}
  local function ammo_stats(pl)
    local c = plat(pl)
    local s = c and c.stats
    if s and pget(s.stats, 'valid') ~= false then return s end
    local stats = stats_of(pl, 'get_item_production_statistics')
    if not stats then return nil end
    s = {stats=stats, made=pget(stats, 'get_input_count'), used=pget(stats, 'get_output_count')}
    if c and type(s.made) == 'function' and type(s.used) == 'function' then c.stats = s end
    return s
  end
  local function count_of(fn, name)
    if not fn then return 0 end
    local ok, v = pcall(fn, name)
    return ok and v or 0
  end
  -- (d24 batch152 PX1) a count by name is normal quality's only: the qualities other than normal each ammunition was
  -- ever counted at on the platform are looked for every 600 ticks (a count only grows), kept with its hub, and read
  -- with normal's each time, summed
  local QPAIR = {}
  local function qpair(name, q)
    local k = name .. '|' .. q
    local t = QPAIR[k]
    if not t then t = {name=name, quality=q}; QPAIR[k] = t end
    return t
  end
  local function ammo_quals(pl, s)
    local c = plat(pl)
    local qa = c and c.ammo_q
    if qa and qa.tick > game.tick - 600 then return qa.by end
    local by = {}
    for _, name in ipairs(ammo_names()) do
      for _, q in ipairs(qflow.qualities()) do
        if q ~= 'normal' then
          local id = qpair(name, q)
          if count_of(s.made, id) > 0 or count_of(s.used, id) > 0 then by[name] = by[name] or {}; by[name][#by[name]+1] = id end
        end
      end
    end
    if c then c.ammo_q = {tick=game.tick, by=by} end
    return by
  end
  local function ammo_counts(pl)
    local s = ammo_stats(pl)
    if not s then return nil end
    local out = {}
    local quals = ammo_quals(pl, s)
    for _, name in ipairs(ammo_names()) do
      local made = count_of(s.made, name)
      local used = count_of(s.used, name)
      for _, id in ipairs(quals[name] or EMPTY_Q) do made, used = made + count_of(s.made, id), used + count_of(s.used, id) end
      if made > 0 or used > 0 then out[name] = {made=made, used=used} end
    end
    return out
  end
  M.ammo_counts = ammo_counts
  -- (d18 batch39 C2) thruster fuel and oxidizer made and used on the platform (its fluid statistics, totals)
  M.FLUIDS = {'thruster-fuel', 'thruster-oxidizer'}
  local function fluid_counts(pl)
    local stats = stats_of(pl, 'get_fluid_production_statistics')
    if not stats then return nil end
    local made, used = pget(stats, 'get_input_count'), pget(stats, 'get_output_count')
    local out = {}
    for _, name in ipairs(M.FLUIDS) do
      out[name] = {made=count_of(made, name), used=count_of(used, name)}
    end
    return out
  end
  local function open(rec, pl, w, counts, tick, first)
    local seg = {start=tick, first=copy(counts), spoiled={}, partial=first or nil, ammo0=ammo_counts(pl), fuel0=fluid_counts(pl), places0=M.places_snapshot(pl)}
    if w.stopped then
      seg.kind, seg.at = 'stop', w.at
      local ask, hold = pads(w.at, pl.force)
      -- (PI1) less what the hub's sections for that planet keep; a finite max sends the rest down asked or not
      local keep = M.hub_keeps_at(try(function() return pl.hub.get_logistic_sections() end), w.at)
      -- (PN1) a stop with unloading off: the pads take nothing, a finite max still sends down
      local off, off_line = M.no_unload(pl, w.at)
      local down = {}
      for name, n in pairs(counts) do
        local want = (ask[name] or 0) - (hold[name] or 0)
        local go, k = M.hub_gives(keep, name, n, want, off)
        if go > 0 or ((k or off) and want > 0) then down[name] = {expected=go, ask=ask[name] or 0, hold=hold[name] or 0, keep=M.keep_text(k)} end
      end
      seg.down = next(down) and down or nil
      seg.no_unload = off_line
      local up = hub_asks(pl, w.at, counts)
      seg.up = next(up) and up or nil
    else
      seg.kind, seg.from, seg.to = 'leg', w.leg.from, w.leg.to
      seg.visited = try(function() return pl.last_visited_space_location.name end)
      -- (d20 batch52 K4, Astra #955) where along the connection it was when the leg began, and the thrusters and hull
      -- width it flew with: the leg's speed is the distance flown over its time, and an estimate from it says when
      -- the ship has changed since
      seg.km0 = w.leg.flown and w.leg.length and w.leg.flown * w.leg.length or nil
      seg.km1 = seg.km0
      local g = M.geometry(pl)
      seg.thrusters, seg.width = g.thrusters, g.width
    end
    rec.segs[#rec.segs+1] = seg
    while #rec.segs > M.KEEP do table.remove(rec.segs, 1) end
    return seg
  end
  -- The key of what the platform does now; nil while it is at a location but
  -- on its path (arriving or leaving), or nowhere: the segment goes on.
  local function key_of(w)
    if w.stopped then return 'stop:' .. w.at end
    if w.leg then return 'leg:' .. w.leg.from .. '>' .. w.leg.to end
  end
  -- One second's change: spoilable items' falls matched to their results' rises.
  -- (BT1) The rises, and the items that fell with a result that rose, in tables emptied at each step (new ones each
  -- second for each platform made garbage). The items are matched in name order: two that spoil into one item (Gleba's
  -- into spoilage) and fell in the same second share its rise in that order, not in the order the hub's counts were
  -- listed (hub_counts' kept kinds list them in the order of their last full read).
  local RISE, FALLS = {}, {}
  local function spoil_step(seg, before, now)
    local rise = RISE
    for name in pairs(rise) do rise[name] = nil end
    for i = #FALLS, 1, -1 do FALLS[i] = nil end
    for name, n in pairs(now) do local d = n - (before[name] or 0); if d > 0 then rise[name] = d end end
    if next(rise) == nil then return end
    for name, n in pairs(before) do
      local fall = n - (now[name] or 0)
      local r = fall > 0 and M.spoil_result(name)
      if r and (rise[r] or 0) > 0 then FALLS[#FALLS+1] = name end
    end
    if #FALLS > 1 then table.sort(FALLS) end
    for _, name in ipairs(FALLS) do
      local fall = before[name] - (now[name] or 0)
      local r = M.spoil_result(name)
      if (rise[r] or 0) > 0 then
        local s = math.min(fall, rise[r])
        rise[r] = rise[r] - s
        seg.spoiled[name] = (seg.spoiled[name] or 0) + s
        seg.into = seg.into or {}
        seg.into[name] = r
      end
    end
  end
  -- Ammunition by what the platform was doing (B3, Astra 18:20: Von Braun died on a short reserve; projections mixed
  -- powered flight with drifting and with production at a stop, about 6 times): each second the change in each
  -- ammunition's made and used counts goes to the phase of that second: moving (flying, not paused, speed > 0), still
  -- (in space, paused or at speed 0) or stopped (at a location). Past PHASE_KEEP seconds in all, every sum is halved,
  -- so recent flight counts most.
  M.PHASE_KEEP = 7200
  local ZERO = {made=0, used=0}  -- (read only)
  function M.phase_step(rec, pl, w)
    -- (BT1) the counts as ammo_counts gives them, written into the last second's table (rec.ammo_prev) once each
    -- ammunition's change is added: a new table of them every second for each platform made garbage
    local s = ammo_stats(pl)
    if not s then return end
    local phase
    if w.stopped then phase = 'stopped'
    elseif w.leg then
      local paused = pget(pl, 'paused')
      local v = pget(pl, 'speed') or 0
      phase = (paused or v <= 0) and 'still' or 'moving'
    end
    local prev = rec.ammo_prev
    local ph
    if prev and phase then
      rec.phase = rec.phase or {moving={s=0, by={}}, still={s=0, by={}}, stopped={s=0, by={}}}
      ph = rec.phase[phase]
      ph.s = ph.s + 1
    end
    local now = prev or {}
    for _, name in ipairs(ammo_names()) do
      local made, used = count_of(s.made, name), count_of(s.used, name)
      if made > 0 or used > 0 then
        local p0 = prev and prev[name]
        if ph then
          local b = p0 or ZERO  -- ammo_counts leaves out an ammunition at 0 and 0
          local d = ph.by[name] or {made=0, used=0}
          d.made = d.made + math.max(0, made - b.made); d.used = d.used + math.max(0, used - b.used)
          ph.by[name] = d
        end
        if p0 then p0.made, p0.used = made, used else now[name] = {made=made, used=used} end
      else now[name] = nil end
    end
    -- (an ammunition no longer among the items: left out, as a fresh read leaves it)
    for name in pairs(now) do if not AMMO_SET[name] then now[name] = nil end end
    rec.ammo_prev = now
    if not ph then return end
    local total = rec.phase.moving.s + rec.phase.still.s + rec.phase.stopped.s
    if total > M.PHASE_KEEP then
      for _, x in pairs(rec.phase) do
        x.s = x.s / 2
        for _, d in pairs(x.by) do d.made = d.made / 2; d.used = d.used / 2 end
      end
    end
  end
  -- {moving|still|stopped = {minutes, made_per_min, used_per_min}} for an ammunition, or nil.
  function M.phase_rates(pl, name)
    local rec = store()[pl.index]
    if not (rec and rec.phase) then return nil end
    local out = {}
    for k, x in pairs(rec.phase) do
      local d = x.by[name]
      if x.s >= 30 then
        out[k] = {minutes=x.s / 60, made=d and d.made / (x.s / 60) or 0, used=d and d.used / (x.s / 60) or 0}
      end
    end
    return next(out) and out or nil
  end
  -- The platform's segments on record, oldest first (endurance.lua reads the last finished leg's time).
  function M.segments(pl) local rec = store()[pl.index]; return rec and rec.segs or {} end
  function M.track(pl, tick)
    local counts = M.hub_counts(pl)
    if not counts then return end
    local all = store()
    local rec = all[pl.index]
    if not rec then rec = {segs={}}; all[pl.index] = rec end
    rec.name = pl.name
    local w = M.where(pl)
    local key = key_of(w)
    local seg = rec.segs[#rec.segs]
    if key and key ~= rec.key then
      local was = seg and not seg['end'] and seg or nil
      if was then was['end'], was.last, was.ammo1, was.places1, was.built1, was.fuel1 = tick, copy(rec.prev or counts), ammo_counts(pl), M.places_snapshot(pl), M.built_now(pl, was), fluid_counts(pl) end
      -- (d17 batch23 A3, Sol: Swift dropped tungsten at Nauvis and left within the second; the stop and its pod's
      -- receipt were never recorded) a leg to X followed by a leg from X, the location last visited become X during the
      -- leg (a turn back in flight leaves it): a stop at X between two looks a second apart, recorded as a 0 s stop
      if was and was.kind == 'leg' and w.leg and w.leg.from == was.to and was.visited ~= was.to
        and pget(pget(pl, 'last_visited_space_location'), 'name') == was.to then
        local z = {start=tick, ['end']=tick, kind='stop', at=was.to, zero=true, first=copy(rec.prev or counts), last=copy(counts), spoiled={}}
        rec.segs[#rec.segs+1] = z
        M.event(pl, 'arrived', z.at, tick); M.event(pl, 'left', z.at, tick, w.leg.to)
      end
      -- Arrivals and departures for the team alert (Gemini, 16:50); not the first look's stop.
      if was and was.kind == 'stop' then M.event(pl, 'left', was.at, tick, w.leg and w.leg.to) end
      seg = open(rec, pl, w, counts, tick, rec.key == nil)
      if rec.key ~= nil and seg.kind == 'stop' then M.event(pl, 'arrived', seg.at, tick) end
      rec.key = key
    elseif seg and not seg['end'] and rec.prev then
      spoil_step(seg, rec.prev, counts)
    end
    -- (K4) the distance along the connection, kept each look while the leg goes on
    if seg and seg.kind == 'leg' and not seg['end'] and w.leg and w.leg.flown and w.leg.length then seg.km1 = w.leg.flown * w.leg.length end
    rec.prev, rec.tick = counts, tick
    M.phase_step(rec, pl, w)
    -- The last flying speed (the arrival estimate before a departure reads it).
    local v = w.leg and pget(pl, 'speed')
    if type(v) == 'number' and v > 0 then
      rec.speed, rec.speed_tick = v, tick
      -- Cruise: the top speed of each leg (A4, Grok 21:21: just after launch, at near-zero speed, every pack read as
      -- spoiling before the arrival); a new leg keeps the last one's top as cruise until it passes it.
      local lk = w.leg.from .. '>' .. w.leg.to
      if rec.leg_key ~= lk then
        if rec.leg_top then rec.cruise = rec.leg_top end
        rec.leg_key, rec.leg_top = lk, 0
      end
      rec.leg_top = math.max(rec.leg_top or 0, v)
    end
  end
  -- (K4) The ship as it flies: its thrusters (count) and its hull's width (the foundation's x extent, in tiles, within
  -- 128 tiles of the hub: Swift's 771 tiles read in 0.46 ms on the private copy; read when a leg begins).
  -- (d22 batch96 BF1) the hull's width from counts of foundation in columns of -128..127, 32 columns at a time and then
  -- one at a time from each side: every foundation tile read was 14.6 ms of Asterion's platform_endurance on a copy of
  -- world n (18 platforms: 107 ms read, 11.7 counted, the same widths)
  function M.geometry(pl)
    local s = try(function() return pl.surface end)
    local out = {thrusters=s and try(function() return s.count_entities_filtered{type='thruster', force=pl.force} end) or nil}
    local function has(x0, x1)
      return (try(function() return s.count_tiles_filtered{name='space-platform-foundation', area={{x0, -128}, {x1, 128}}, limit=1} end) or 0) > 0
    end
    local lo, hi
    if s then
      for x = -128, 96, 32 do
        if has(x, x + 32) then for c = x, x + 31 do if has(c, c + 1) then lo = c; break end end; break end
      end
      for x = 96, -128, -32 do
        if lo and has(x, x + 32) then for c = x + 31, x, -1 do if has(c, c + 1) then hi = c; break end end; break end
      end
    end
    if lo and hi then out.width = hi - lo + 1 end
    return out
  end
  -- The speed an estimate flies at: the higher of now and the cruise (km a tick); nil before any flight seen.
  function M.cruise(pl)
    local rec = store()[pl.index]
    local c = rec and math.max(rec.cruise or 0, rec.leg_top or 0) or 0
    return c > 0 and c or nil
  end
  -- The arrival at `location` estimated before the platform leaves its stop (Sonnet, every shift: a wait for the
  -- platform at her planet said "no estimate" until it departed): the schedule from the current stop, its wait
  -- conditions (a time condition's seconds left from when the stop began; other conditions named, not timed), each
  -- leg's length at the platform's last flying speed, and the waits of stops between. {eta_s (nil when a wait is not
  -- timed), after_waits (the untimed waits), line} or nil, why.
  local CONN
  local function connection(a, b)
    if not CONN then
      CONN = {}
      for _, c in pairs(try(function() return prototypes.space_connection end) or {}) do
        local f, t = try(function() return c.from.name end), try(function() return c.to.name end)
        local len = try(function() return c.length end)
        if f and t and len then CONN[f .. '>' .. t] = len; CONN[t .. '>' .. f] = len end
      end
    end
    return CONN[a .. '>' .. b]
  end
  -- The shortest way between two space locations through the connections (Sonnet, Astra: Fulgora->Vulcanus has no
  -- connection of its own and the platform flies through Nauvis or Gleba): {km, via (the locations between), hops
  -- [{from, to, km}], also (another way as short)}, or nil.
  function M.path(a, b)
    if a == b then return {km=0, via={}, hops={}} end
    connection(a, a)
    local adj = {}
    for k, len in pairs(CONN) do
      local f, t2 = k:match('^(.-)>(.*)$')
      adj[f] = adj[f] or {}; adj[f][#adj[f]+1] = {to=t2, km=len}
    end
    local dist, prev, done, ties = {[a]=0}, {}, {}, {}
    while true do
      local u, best
      for n, d in pairs(dist) do if not done[n] and (not best or d < best or (d == best and n < u)) then u, best = n, d end end
      if not u or u == b then break end
      done[u] = true
      for _, e in ipairs(adj[u] or {}) do
        local nd = best + e.km
        if not dist[e.to] or nd < dist[e.to] - 1e-6 then dist[e.to] = nd; prev[e.to] = u; ties[e.to] = nil
        elseif math.abs(nd - dist[e.to]) <= 1e-6 and prev[e.to] ~= u then ties[e.to] = u end
      end
    end
    if not dist[b] then return nil end
    local hops, n = {}, b
    while prev[n] do table.insert(hops, 1, {from=prev[n], to=n, km=CONN[prev[n] .. '>' .. n]}); n = prev[n] end
    local via = {}
    for i = 1, #hops - 1 do via[#via+1] = hops[i].to end
    return {km=dist[b], via=via, hops=hops, also=ties[b] and ties[b] ~= hops[#hops].from and ties[b] or nil}
  end
  local function wait_text(w)
    local t = w.type or '?'
    if w.ticks then t = t .. ' ' .. math.floor(w.ticks / 60) .. 's' end
    local cond = w.condition
    if type(cond) == 'table' and cond.first_signal then
      t = t .. ' ' .. sigtext(cond.first_signal) .. ' ' .. tostring(cond.comparator or '<') .. ' ' .. tostring(cond.constant or (cond.second_signal and sigtext(cond.second_signal)) or 0)
    end
    return t
  end
  -- A platform's ETA at a location through its schedule (Sonnet, every shift; Astra): at a stop, from that stop's
  -- waits; in flight (d15 batch5 C4), from the leg it flies (the distance left at its speed now) and then the stops
  -- after it, each stop's waits, and each stop to stop by the shortest way through the connections at its last speed.
  function M.before_departure(pl, location)
    local w = M.where(pl)
    if not w.at and not w.leg then return nil, 'not at a stop' end
    local sch = try(function() return pl.schedule end)
    local records = sch and sch.records or {}
    if #records == 0 then return nil, 'it has no schedule' end
    if try(function() return pl.paused end) then return nil, 'platform is paused' end
    local cur = sch.current or 1
    local rec = store()[pl.index]
    local speed = M.cruise(pl) or rec and rec.speed
    local seg = rec and rec.segs and rec.segs[#rec.segs]
    local started = seg and not seg['end'] and seg.kind == 'stop' and seg.start or nil
    local secs, untimed, parts = 0, {}, {}
    -- The current stop's waits: the platform leaves when they are met (an and of conditions: the longest time).
    -- A stop's waits: joined by and, the platform leaves after the longest time condition and when the others are met
    -- (named, not timed); with an or among them, at most the shortest time condition (the others may end it sooner).
    local upper = false
    -- What sends it on besides its waits (B2 departure.lua; A4, Grok 21:21: the estimate added the printed 3600 s while
    -- a queue sent the ship on once cargo landed): at such a stop the time waits are an upper bound, the queue named.
    local sent = api.departure and try(function() return api.departure(pl.name) end)
    local function waits(r, here_now)
      if sent and #sent > 0 then
        local list = {}
        for k, c in ipairs(r.wait_conditions or {}) do list[#list+1] = (k > 1 and (c.compare_type == 'or' and 'or ' or 'and ') or '') .. wait_text(c) end
        list[#list+1] = 'or sooner: ' .. sent[1]
        return 0, {'sent on by ' .. sent[1]}, list
      end
      local list, longest, shortest, other, any_or = {}, 0, nil, {}, false
      for k, c in ipairs(r.wait_conditions or {}) do
        if k > 1 and c.compare_type == 'or' then any_or = true end
        list[#list+1] = (k > 1 and (c.compare_type == 'or' and 'or ' or 'and ') or '') .. wait_text(c)
        if c.type == 'time' and c.ticks then
          local left = math.max(0, c.ticks - (here_now and started and (game.tick - started) or 0)) / 60
          longest = math.max(longest, left)
          shortest = math.min(shortest or left, left)
        else other[#other+1] = wait_text(c) end
      end
      if any_or and shortest then upper = true; return shortest, {}, list end
      return longest, other, list
    end
    local at, i, n = w.at, cur, 0
    local function fly(from, to)
      local route = M.path(from, to)
      if not route then return nil, 'no space connection or way through them ' .. from .. '->' .. to end
      if not speed then return nil, 'no flying speed seen yet for ' .. pl.name end
      local s = route.km / speed / 60
      secs = secs + s
      parts[#parts+1] = string.format('%s->%s %d km%s at %.0f km/s (its cruise): %ds', from, to, math.floor(route.km + 0.5),
        #route.via > 0 and ' via ' .. table.concat(route.via, ', ') .. (route.also and ' (as short through ' .. route.also .. ')' or '') or '',
        speed * 60, math.floor(s + 0.5))
      return true
    end
    if w.leg then
      -- In flight: the rest of this leg at its speed now, then on from its end.
      local leg = w.leg
      if not leg.eta_ticks then return nil, 'its speed is zero or unread now' end
      secs = leg.eta_ticks / 60
      speed = speed or (leg.left_km > 0 and leg.left_km / leg.eta_ticks) or nil
      parts[#parts+1] = string.format('flying %s->%s: %d km left at %s: %ds', leg.from, leg.to, math.floor(leg.left_km + 0.5),
        leg.speed_from or (leg.eta_from and 'its cruise (it speeds up now)' or 'its speed now'), math.floor(secs + 0.5))
      at = leg.to
      if leg.to == location then
        return {eta_s=math.ceil(secs), after_s=math.ceil(secs), line=string.format('ETA %ds: %s', math.ceil(secs), table.concat(parts, '; '))}
      end
      local stop = records[cur] and records[cur].station
      if stop and stop ~= at then
        local ok, why = fly(at, stop)
        if not ok then return nil, why end
        at = stop
      end
      if stop == location then
        local eta = math.ceil(secs)
        return {eta_s=eta, after_s=eta, line=string.format('ETA %ds: %s', eta, table.concat(parts, '; '))}
      end
      if stop then
        local t2, other, list = waits(records[cur], false)
        secs = secs + t2
        for _, o in ipairs(other) do untimed[#untimed+1] = stop .. ': ' .. o end
        parts[#parts+1] = string.format('stops at %s (%s)', stop, #list > 0 and table.concat(list, ' ') or 'no wait conditions')
      end
    elseif records[cur] and records[cur].station ~= w.at then
      -- Stopped somewhere off the schedule's current record: it heads for that record next.
      i = cur - 1
    else
      local t, other, list = waits(records[cur], true)
      secs = secs + t
      for _, o in ipairs(other) do untimed[#untimed+1] = w.at .. ': ' .. o end
      parts[#parts+1] = string.format('leaves %s when %s', w.at, #list > 0 and table.concat(list, ' ') or 'its schedule says (no wait conditions)')
    end
    while n < #records do
      n = n + 1
      i = i % #records + 1
      local r = records[i]
      local to = r.station
      if not to then return nil, 'schedule record ' .. i .. ' has no station' end
      if to ~= at then
        local ok, why = fly(at, to)
        if not ok then return nil, why end
        at = to
      end
      if to == location or (location == nil and to ~= w.at) then
        local eta = #untimed == 0 and math.ceil(secs) or nil
        local line = table.concat(parts, '; ')
        local how = w.leg and '' or ' before departure'
        if eta then line = string.format('ETA %s%ds%s: %s', upper and 'at most ' or '', eta, how, line)
        else line = string.format('ETA %ds after %s: %s', math.ceil(secs), table.concat(untimed, ' and '), line) end
        return {eta_s=eta, after_s=math.ceil(secs), after_waits=#untimed > 0 and untimed or nil, line=line}
      end
      local t, other, list = waits(r, false)
      secs = secs + t
      for _, o in ipairs(other) do untimed[#untimed+1] = to .. ': ' .. o end
      parts[#parts+1] = string.format('stops at %s (%s)', to, #list > 0 and table.concat(list, ' ') or 'no wait conditions')
    end
    return nil, 'its schedule does not go to ' .. tostring(location)
  end
  -- A platform's arrivals at and departures from space locations (Gemini, 16:50: a team alert when one arrives at or
  -- leaves the agent's planet), the last EVENTS: {seq, platform, force, kind arrived|left, at, to, tick}.
  local EVENTS, EVENT_TICKS = 40, 5 * 3600
  local function events()
    local st = api.state()
    st.platform_events = st.platform_events or {seq=0, list={}}
    return st.platform_events
  end
  function M.event(pl, kind, at, tick, to)
    local ev = events()
    ev.seq = ev.seq + 1
    ev.list[#ev.list+1] = {seq=ev.seq, platform=pl.name, force=try(function() return pl.force.name end), kind=kind, at=at, to=to, tick=tick}
    while #ev.list > EVENTS do table.remove(ev.list, 1) end
  end
  -- (d22 batch100 BJ1, Sol #1905) the first departure of a platform from location (any stop without one) logged at or
  -- after since: {at, to, tick}, or nil. Logged on the game second after it (M.tick), so its tick is never before it.
  function M.left_since(name, force, location, since)
    for _, e in ipairs(events().list) do
      if e.kind == 'left' and e.platform == name and e.force == force and e.tick >= since and (location == nil or e.at == location) then
        return e
      end
    end
  end
  -- The lines for agent p (h: its hint state): platforms of its force that stopped at or left its planet since it was
  -- last told (its first look: the last 5 minutes).
  function M.event_lines(p, h)
    local ev = events()
    local since = h.platform_event_seq or 0
    h.platform_event_seq = ev.seq
    local planet = try(function() return p.surface.planet.name end)
    if not planet then return nil end
    local force = try(function() return p.force.name end)
    local out = {}
    for _, e in ipairs(ev.list) do
      if e.seq > since and e.at == planet and e.force == force and game.tick - e.tick <= EVENT_TICKS then
        -- An arrival names its cargo pods still in the air toward this planet (pods.lua; Grok, shift13).
        local pods = e.kind == 'arrived' and api.pods and try(function() return api.pods.line(force, e.at, e.platform) end)
        out[#out+1] = e.kind == 'arrived'
          and string.format('platform %s stopped at %s, your planet, %s ago%s', e.platform, e.at, secs(game.tick - e.tick), pods and '; ' .. pods or '')
          or string.format('platform %s left %s, your planet, %s ago%s', e.platform, e.at, secs(game.tick - e.tick), e.to and ', flying to ' .. e.to or '')
      end
    end
    return #out > 0 and out or nil
  end
  -- Every game second (runtime tick): each platform of each force with one.
  function M.tick(tick)
    local seen = {}
    for _, f in pairs(game.forces) do
      for _, pl in pairs(pget(f, 'platforms') or {}) do
        if pl.valid then seen[pl.index] = true; pcall(M.track, pl, tick) end
      end
    end
    local all = store()
    for index in pairs(all) do if not seen[index] then all[index] = nil end end
    -- (BT1) the kept hubs and statistics of platforms gone
    for index in pairs(plats) do if not seen[index] then plats[index] = nil end end
  end
  -- Built at once from the delivery (d17 batch16 A2, Grok/Wren: rocket-turret "came aboard 0" while the hull went from
  -- 9 turrets to 14: construction robots took each turret from the hub to a ghost within the second it arrived, so
  -- the hub never rose). For each rocket cargo item that places an entity or a tile, the platform's count of it when
  -- the first rocket of the stop is ordered (built0) and at the stop's end or the read (built1); the rise counts as
  -- came aboard and is said apart. A count by name on a platform surface (hundreds of entities).
  local function placed(name)
    local item = try(function() return prototypes.item[name] end)
    local e = item and try(function() return item.place_result end)
    if e then return 'entity', e.name end
    local t = item and try(function() return item.place_as_tile_result end)
    local tile = t and try(function() return t.result end)
    if tile then return 'tile', tile.name end
  end
  function M.built_count(pl, name)
    local kind, what = placed(name)
    if not kind then return nil end
    local s = try(function() return pl.surface end)
    if not s then return nil end
    if kind == 'entity' then return try(function() return s.count_entities_filtered{name=what, force=pl.force} end) end
    return try(function() return s.count_tiles_filtered{name=what} end)
  end
  local function built_now(pl, seg)
    if not seg.built0 then return nil end
    local out = {}
    for name in pairs(seg.built0) do out[name] = M.built_count(pl, name) end
    return out
  end
  M.built_now = built_now

  -- on_rocket_launch_ordered: a rocket whose cargo pod goes to a platform's hub
  -- counts on that platform's stop.
  function M.on_launch(event)
    local pod = try(function() return event.rocket.attached_cargo_pod end)
    local d = pod and try(function() return pod.cargo_pod_destination end)
    local pl = d and ((d.station and try(function() return d.station.surface.platform end)) or d.space_platform)
    if not (pl and try(function() return pl.valid end)) then return end
    local rec = store()[pl.index]
    local inv = defines.inventory.cargo_unit and try(function() return pod.get_inventory(defines.inventory.cargo_unit) end)
    -- Rockets on their way up (Astra, 22:50): the cargo pod is kept until it is gone (incoming below).
    if rec then
      rec.incoming = rec.incoming or {}
      if #rec.incoming < 32 then
        local list = inv and try(function() return inv.get_contents() end)
        rec.incoming[#rec.incoming+1] = {pod=pod, tick=game.tick, cargo=add_contents({}, list), cargo_q=add_contents_q({}, list),
          from=try(function() return event.rocket_silo.surface.name end), up=event.harness_up,
          silo=try(function() return xy(event.rocket_silo.position) end)}
      end
    end
    local seg = rec and rec.segs[#rec.segs]
    if not seg or seg['end'] then return end
    seg.rockets = seg.rockets or {n=0, cargo={}}
    seg.rockets.n = seg.rockets.n + 1
    add_contents(seg.rockets.cargo, inv and try(function() return inv.get_contents() end))
    for name in pairs(seg.rockets.cargo) do
      if not (seg.built0 and seg.built0[name]) then
        local n = M.built_count(pl, name)
        if n then seg.built0 = seg.built0 or {}; seg.built0[name] = n end
      end
    end
  end

  -- Cargo pods from the hub ----------------------------------------------------
  -- by name (every quality together), and by name@quality (QJ1)
  local function pod_cargo(pod)
    local inv = defines.inventory.cargo_unit and try(function() return pod.get_inventory(defines.inventory.cargo_unit) end)
    local list = inv and try(function() return inv.get_contents() end)
    return add_contents({}, list), add_contents_q({}, list)
  end
  -- Where a pod is sent: {pad, position, surface} for a landing pad, else {surface}.
  local function pod_dest(pod)
    local d = try(function() return pod.cargo_pod_destination end)
    if not d then return nil end
    local st = d.station
    if st and try(function() return st.valid end) then
      return {pad=st.name, position=xy(st.position), surface=try(function() return st.surface.name end)}
    end
    local s = d.surface and try(function() return d.surface.name end)
    return s and {surface=s} or nil
  end
  local function tally(t, key, cargo, extra)
    t[key] = t[key] or {n=0, cargo={}}
    local r = t[key]
    r.n = r.n + 1
    for name, n in pairs(cargo or {}) do r.cargo[name] = (r.cargo[name] or 0) + n end
    if extra then
      r.at = r.at or {}
      local found = false
      for _, a in ipairs(r.at) do if a == extra then found = true end end
      if not found and #r.at < 4 then r.at[#r.at+1] = extra end
    end
  end
  local function seg_at(rec, start)
    for _, seg in ipairs(rec.segs) do if seg.start == start then return seg end end
  end
  -- One pod gone: what it carried, counted on its stop by where it went.
  -- (d17 batch23 A3) and a landed receipt per pod, kept apart from the stops (the last RECEIPTS): what, where, when,
  -- which pod, from which stop
  -- (d22 batch94 BD1) a pod received by a landing pad goes to api.delivered (reminders' on.delivered)
  local function receipt(rec, p, tick, kind, where, pl)
    rec.receipts = rec.receipts or {}
    table.insert(rec.receipts, {tick=tick, sent=p.tick, unit=p.unit, cargo=p.cargo, cargo_q=p.cargo_q, kind=kind, where=where, stop=p.at, stop_start=p.seg, dest=p.dest, asked=p.asked})
    while #rec.receipts > M.RECEIPTS do table.remove(rec.receipts, 1) end
    if kind == 'received' and api.delivered then
      pcall(api.delivered, {surface=p.dest and p.dest.surface or (p.last and p.last.surface), from=pl and try(function() return pl.name end), cargo=p.cargo, where=where})
    end
  end
  local function pod_done(rec, p, tick, hub_dead, pl)
    local seg = seg_at(rec, p.seg) or {}
    seg.pods = seg.pods or {}
    local here = p.last and p.last.surface
    -- (d20 batch52 K3, Sol #1323) 2.0.77 on the private copy: a cargo pod still on its platform's surface (waiting to launch, rising, or passing to the planet: its first 400 ticks or so) is removed with the platform when its hub is destroyed, and what it carried is gone; one already coming down over the planet lands as usual
    if hub_dead and (not here or here == p.from) then
      local where = 'lost: the platform\'s hub was destroyed before the pod left the platform\'s surface, which removes the pod and what it carried'
      tally(seg.pods, 'lost', p.cargo)
      receipt(rec, p, tick, 'lost', where)
      seg.pods.last_tick = tick
      return
    end
    if here and here ~= p.from then
      if p.dest and p.dest.pad then
        local where = string.format('%s (%g,%g) on %s', p.dest.pad, p.dest.position.x, p.dest.position.y, p.dest.surface or here)
        tally(seg.pods, 'received', p.cargo, where)
        receipt(rec, p, tick, 'received', where, pl)
      else
        -- The container it became, where it stands (Sonnet, shift14 22:50: a rounded spot sent a transfer a tile off);
        -- else the pod's last sighting, to a tenth of a tile.
        local pos = p.last.position
        local box = try(function()
          local best, d
          for _, e in pairs(game.surfaces[here].find_entities_filtered{name='cargo-pod-container', position=pos, radius=8}) do
            local dd = (e.position.x - pos.x) ^ 2 + (e.position.y - pos.y) ^ 2
            if e.valid and (not d or dd < d) then best, d = e, dd end
          end
          return best
        end)
        local where = box and string.format('cargo-pod-container (%g,%g) on %s', box.position.x, box.position.y, here)
          or string.format('(%.1f,%.1f) on %s (the pod\'s last sighting; no cargo pod container within 8 tiles of it)', pos.x, pos.y, here)
        tally(seg.pods, 'landed', p.cargo, where)
        receipt(rec, p, tick, 'landed', where)
      end
      seg.pods.last_tick = tick
    else
      tally(seg.pods, 'gone', p.cargo)
      receipt(rec, p, tick, 'gone', 'gone before leaving the platform')
    end
  end
  local function is_mine(pod, pl, hub)
    local origin = try(function() return pod.cargo_pod_origin end)
    if origin then return try(function() return origin == hub end) == true end
    -- No origin read: one sent off the platform counts (a rocket's pod comes down onto it).
    local d = pod_dest(pod)
    return d ~= nil and d.surface ~= nil and d.surface ~= try(function() return pl.surface.name end)
  end
  -- Rockets on their way up, settled (batch27 B2, Astra: shipment and queue_status every minute on each courier leg): a
  -- pod gone (it reached the platform) gives its launch-to-arrival time (to POD_TICKS), the last UP_TIMES kept; one
  -- followed past UP_MAX is dropped.
  local UP_TIMES, UP_MAX = 8, 3600
  function M.up_settle(rec, tick, pl)
    local keep = {}
    for _, r in ipairs(rec.incoming or {}) do
      if r.pod and pget(r.pod, 'valid') then
        if tick - r.tick < UP_MAX then keep[#keep+1] = r end
      else
        -- (BD1) a rocket's pod gone: it reached the platform's hub (api.delivered)
        if pl and api.delivered then
          local name = try(function() return pl.name end)
          pcall(api.delivered, {surface=try(function() return pl.surface.name end), platform=name, from=r.from, cargo=r.cargo,
            where=string.format('%s\'s hub (a rocket from %s)', tostring(name), tostring(r.from))})
        end
        rec.up_times = rec.up_times or {}
        rec.up_times[#rec.up_times+1] = tick - r.tick
        while #rec.up_times > UP_TIMES do table.remove(rec.up_times, 1) end
      end
    end
    rec.incoming = #keep > 0 and keep or nil
  end
  -- The middle of the recent launch-to-arrival times (ticks), and how many.
  function M.up_time(rec)
    local t = {}
    for i, v in ipairs(rec and rec.up_times or {}) do t[i] = v end
    if #t == 0 then return nil, 0 end
    table.sort(t)
    return t[math.floor((#t + 1) / 2)], #t
  end
  -- The platform's landed receipts after a tick (batch28 B1, Luna: polled silo, shipment and where_is for each pod):
  -- {tick, kind (received | landed | gone), where, cargo {item = count}, dest, stop (where the platform was)} each, oldest first.
  function M.receipts_since(pl, since)
    local out = {}
    local rec = store()[pl.index]
    for _, r in ipairs(rec and rec.receipts or {}) do
      if r.tick > since then out[#out+1] = {tick=r.tick, kind=r.kind, where=r.where, cargo=r.cargo, cargo_q=r.cargo_q, unit=r.unit, dest=r.dest, stop=r.stop} end
    end
    return out
  end
  -- (d21 batch66 AB7) The pods followed for the platform now: down, those from its hub {pod, unit, at (the stop), tick
  -- (first seen), from, dest}; up, the rockets launched to it {pod, tick (launch), from (the silo's planet), silo, up}.
  function M.followed(pl)
    local rec = store()[pl.index]
    return {down=rec and rec.pods or {}, up=rec and rec.incoming or {}}
  end
  -- (PD1) a followed pod's pad_asked, read once, the first time it is seen with cargo on its platform: the pad's
  -- requests for that cargo then, and what the other pods followed to that planet carry of it (on the way)
  local function ask_for(p, pl)
    if p.asked or not (p.at and next(p.cargo or {})) then return end
    local asked = try(function() return pad_asked(p.at, pl.force, p.cargo) end)
    if not asked then return end
    for _, q in pairs(store()) do
      for _, o in ipairs(type(q) == 'table' and q.pods or {}) do
        if o ~= p and o.at == p.at and o.pod and o.pod ~= p.pod then
          for name, it in pairs(asked.items) do it.way = (it.way or 0) + (o.cargo and o.cargo[name] or 0) end
        end
      end
    end
    p.asked = asked
  end
  function M.pod_watch(pl, tick)
    local rec = store()[pl.index]
    if not rec then return end
    pcall(M.up_settle, rec, tick, pl)
    -- The pods followed: where they are, and the ones gone.
    local keep = {}
    local hub_dead = not pget(pget(pl, 'hub'), 'valid')
    for _, p in ipairs(rec.pods or {}) do
      if pget(p.pod, 'valid') then
        local sn, pos = pget(pget(p.pod, 'surface'), 'name'), pget(p.pod, 'position')
        local where = sn ~= nil and pos ~= nil and {surface=sn, position=xy(pos)} or nil
        if where then p.last = where end
        if where and where.surface == p.from then p.cargo, p.cargo_q = pod_cargo(p.pod); ask_for(p, pl) end
        p.dest = pod_dest(p.pod) or p.dest
        keep[#keep+1] = p
      else
        p.pod = nil
        pod_done(rec, p, tick, hub_dead, pl)
      end
    end
    rec.pods = keep
    -- New pods leaving the hub while it is at a stop, or within POD_AFTER of the last stop's end (A3: a pod sent in the
    -- last second of a stop, or at a 0 s stop, is still leaving the platform after it).
    local seg
    for i = #rec.segs, 1, -1 do
      local x = rec.segs[i]
      if x.kind == 'stop' then seg = x; break end
    end
    if not (seg and (not seg['end'] or tick - seg['end'] <= POD_AFTER)) then return end
    local s, hub = pget(pl, 'surface'), pget(pl, 'hub')
    if not (s and hub) then return end
    local found
    if api.pods and api.pods.from then found = try(function() return api.pods.from(pl.force.name, pl.name) end)
    else found = try(function() return s.find_entities_filtered{type='cargo-pod'} end) end
    for _, pod in ipairs(found or {}) do
      local known = false
      for _, p in ipairs(rec.pods) do
        local ok, is = pcall(same, p.pod, pod)
        if ok and is then known = true; break end
      end
      if not known and #rec.pods < POD_PENDING and pget(pod, 'valid') and is_mine(pod, pl, hub) then
        local p = {pod=pod, unit=try(function() return pod.unit_number end), seg=seg.start, at=seg.at, tick=tick,
          from=s.name, dest=pod_dest(pod), last={surface=s.name, position=xy(pod.position)}}
        p.cargo, p.cargo_q = pod_cargo(pod)
        ask_for(p, pl)
        rec.pods[#rec.pods+1] = p
      end
    end
  end
  -- Every POD_TICKS: the platforms at a stop, or with pods still followed.
  function M.pod_tick(tick)
    if tick % POD_TICKS ~= 0 then return end
    local all = store()
    -- (BT1) no platform followed: no platform looked at
    if next(all) == nil then return end
    for _, f in pairs(game.forces) do
      for _, pl in pairs(pget(f, 'platforms') or {}) do
        local rec = pl.valid and all[pl.index]
        if rec then pcall(M.pod_watch, pl, tick) end
      end
    end
  end

  -- Reading ------------------------------------------------------------------
  local function items_text(t, limit)
    local list = {}
    for name, n in pairs(t or {}) do if n > 0 then list[#list+1] = {name=name, n=n} end end
    table.sort(list, function(x, y) return x.n > y.n or (x.n == y.n and x.name < y.name) end)
    local parts = {}
    for i = 1, math.min(limit or M.ITEMS, #list) do parts[i] = list[i].name .. '*' .. list[i].n end
    return #parts > 0 and table.concat(parts, ' ') .. (#list > (limit or M.ITEMS) and string.format(' +%d more', #list - (limit or M.ITEMS)) or '') or nil
  end
  local function when(seg, now)
    if seg.zero then return string.format('0s, %s ago; arrived and left between two looks a second apart', secs(now - seg['end'])) end
    local text = seg['end'] and string.format('%s, %s ago', secs(seg['end'] - seg.start), secs(now - seg['end']))
      or string.format('%s so far', secs(now - seg.start))
    return seg.partial and text .. '; under way when first seen' or text
  end
  -- One stop or leg in words, with its numbers: {line, kind, at|from+to, start, end, items={...}}.
  -- A stop's pods: those gone (received, landed without a pad, gone before leaving) and those still followed.
  local function pods_text(seg, flying, now)
    local d = seg.pods or {}
    local sent = {n=0, cargo={}}
    for _, k in ipairs({'received', 'landed', 'gone', 'lost'}) do
      local r = d[k]
      if r then sent.n = sent.n + r.n; for name, n in pairs(r.cargo) do sent.cargo[name] = (sent.cargo[name] or 0) + n end end
    end
    local fly = {n=0, cargo={}, units={}}
    for _, p in ipairs(flying or {}) do
      sent.n, fly.n = sent.n + 1, fly.n + 1
      for name, n in pairs(p.cargo or {}) do
        sent.cargo[name] = (sent.cargo[name] or 0) + n
        fly.cargo[name] = (fly.cargo[name] or 0) + n
      end
      if #fly.units < 8 then
        fly.units[#fly.units+1] = string.format('%s%s %s', p.unit and '#' .. p.unit or 'a pod', p.dest and p.dest.pad and ' to ' .. p.dest.pad or '',
          (p.last and p.last.surface ~= p.from) and 'descending on ' .. p.last.surface or 'leaving the platform')
          .. string.format(' (left the hub %s ago)', secs(now - p.tick))
      end
    end
    if sent.n == 0 then return nil end
    local function part(r, words)
      return string.format('%s %d (%s)%s', words, r.n, items_text(r.cargo) or 'empty', r.at and ' at ' .. table.concat(r.at, ', ') or '')
    end
    local bits = {string.format('cargo pods sent down %d (%s)', sent.n, items_text(sent.cargo) or 'empty')}
    if d.received then bits[#bits+1] = part(d.received, 'received by landing pads') end
    if d.landed then bits[#bits+1] = part(d.landed, 'landed as cargo pod containers (no landing pad)') end
    if d.gone then bits[#bits+1] = part(d.gone, 'gone before leaving the platform') end
    if d.lost then bits[#bits+1] = part(d.lost, 'lost: the hub was destroyed before they left the platform (delivered nothing)') end
    if fly.n > 0 then bits[#bits+1] = string.format('in flight %d (%s): %s', fly.n, items_text(fly.cargo) or 'empty', table.concat(fly.units, ', ')) end
    return table.concat(bits, ', '), {sent=sent.n, sent_items=sent.cargo, received=d.received and d.received.n or 0,
      received_items=d.received and d.received.cargo or nil, landed=d.landed and d.landed.n or nil, gone=d.gone and d.gone.n or nil,
      in_flight=fly.n, in_flight_items=fly.n > 0 and fly.cargo or nil, in_flight_pods=fly.n > 0 and fly.units or nil}
  end
  -- (d18 batch39 C2, Sol: a wrapper sampled every 1-2 min and dock bursts looked sustainable) platform_production {leg}:
  -- the window from the platform's last departure to now (the leg flown and the stop after it so far), and while it is
  -- stopped the last full leg alone: thruster fuel and oxidizer and each ammunition made and used, from the totals
  -- freight keeps at each segment's start and end (fuel0/fuel1, ammo0/ammo1); cargo loaded (rockets launched to it)
  -- and dropped (its cargo pods received or landed), from the segments in the window; totals and a minute.
  local function delta(a0, a1, names)
    local out = {}
    for name, v in pairs(a1 or {}) do
      local b = (a0 or {})[name] or {made=0, used=0}
      local made, used = v.made - b.made, v.used - b.used
      if made > 0 or used > 0 then out[name] = {made=math.floor(made + 0.5), used=math.floor(used + 0.5)} end
    end
    return out
  end
  local function window(rec, pl, from_i, to_i, now_end)
    local s0, s1 = rec.segs[from_i], rec.segs[to_i]
    local t0, t1 = s0.start, now_end and game.tick or s1['end']
    local mins = math.max(1 / 60, (t1 - t0) / 3600)
    if not (s0.fuel0 and s0.ammo0) then return {from=t0, to=t1, minutes=mins, no_sample='the leg began before this runtime kept fuel samples'} end
    local fuel = delta(s0.fuel0, now_end and fluid_counts(pl) or s1.fuel1)
    local ammo = delta(s0.ammo0, now_end and ammo_counts(pl) or s1.ammo1)
    -- (live 23:09, Sol: Spindle after a drop failed with "attempt to index local r (a number value)": seg.pods holds
    -- last_tick beside its tallies) dropped: the received and landed tallies only; the cargo sums are read apart, so
    -- fuel and ammunition stand when they fail (cargo_error says why)
    local loaded, dropped = {}, {}
    local ok, err = pcall(function()
      for i = from_i, to_i do
        local sg = rec.segs[i]
        for name, n in pairs(type(sg.rockets) == 'table' and type(sg.rockets.cargo) == 'table' and sg.rockets.cargo or {}) do
          if type(n) == 'number' then loaded[name] = (loaded[name] or 0) + n end
        end
        for _, key in ipairs({'received', 'landed'}) do
          local r = type(sg.pods) == 'table' and sg.pods[key]
          for name, n in pairs(type(r) == 'table' and type(r.cargo) == 'table' and r.cargo or {}) do
            if type(n) == 'number' then dropped[name] = (dropped[name] or 0) + n end
          end
        end
      end
    end)
    if not ok then loaded, dropped = {}, {} end
    return {from=t0, to=t1, minutes=mins, fuel=fuel, ammo=ammo, loaded=loaded, dropped=dropped, cargo_error=not ok and tostring(err) or nil}
  end
  local function window_line(label, w)
    if w.no_sample then return string.format('%s (%s): %s', label, secs(w.to - w.from), w.no_sample) end
    local parts = {}
    local function each(t, what)
      local names = {}
      for name in pairs(t) do names[#names+1] = name end
      table.sort(names)
      for _, name in ipairs(names) do
        local v = t[name]
        if type(v) == 'table' then
          parts[#parts+1] = string.format('%s made %d, used %d (%g/%g a minute, net %+g a minute)', name, v.made, v.used,
            math.floor(v.made / w.minutes * 10 + 0.5) / 10, math.floor(v.used / w.minutes * 10 + 0.5) / 10, math.floor((v.made - v.used) / w.minutes * 10 + 0.5) / 10)
        else
          parts[#parts+1] = string.format('%s %s %d (%g a minute)', what, name, v, math.floor(v / w.minutes * 10 + 0.5) / 10)
        end
      end
    end
    each(w.fuel); each(w.ammo); each(w.loaded, 'loaded'); each(w.dropped, 'dropped')
    if w.cargo_error then parts[#parts+1] = 'cargo not read: ' .. w.cargo_error end
    return string.format('%s (%s, ticks %d-%d): %s', label, secs(w.to - w.from), w.from, w.to, #parts > 0 and table.concat(parts, '; ') or 'no fuel, oxidizer or ammunition made or used, no cargo')
  end
  function M.leg_delta(pl)
    local rec = store()[pl.index]
    local segs = rec and rec.segs or {}
    local last_leg
    for i = #segs, 1, -1 do if segs[i].kind == 'leg' then last_leg = i; break end end
    if not last_leg then return {lines={'no leg of ' .. pl.name .. ' recorded since this runtime began (freight keeps its last ' .. M.KEEP .. ' segments)'}} end
    local out, lines = {}, {}
    out.since_departure = window(rec, pl, last_leg, #segs, true)
    local cur = segs[#segs]
    lines[#lines+1] = window_line(string.format('since it left %s', tostring(segs[last_leg].from)), out.since_departure)
    if cur.kind == 'stop' and segs[last_leg]['end'] then
      out.last_leg = window(rec, pl, last_leg, last_leg, false)
      lines[#lines+1] = window_line(string.format('the last full leg %s->%s', tostring(segs[last_leg].from), tostring(segs[last_leg].to)), out.last_leg)
    end
    out.lines = lines
    return out
  end
  function M.segment(seg, now, counts_now, flying, pl)
    local last = seg.last or counts_now or {}
    local built1 = seg.built1 or (not seg['end'] and pl and built_now(pl, seg)) or {}
    local function built(name) return seg.built0 and seg.built0[name] and built1[name] and math.max(0, built1[name] - seg.built0[name]) or 0 end
    local rows = {}
    if seg.kind == 'stop' then
      -- The items the stop is about: expected down or up, rocket cargo, spoiled.
      local names, order = {}, {}
      local function want(name) if not names[name] then names[name] = true; order[#order+1] = name end end
      for name in pairs(seg.down or {}) do want(name) end
      for name in pairs(seg.up or {}) do want(name) end
      for name in pairs(seg.rockets and seg.rockets.cargo or {}) do want(name) end
      for name in pairs(seg.spoiled) do want(name) end
      for name in pairs(seg.built0 or {}) do if built(name) > 0 then want(name) end end
      -- and any spoilable item whose count changed over the stop
      for _, t in ipairs({seg.first, last}) do
        for name in pairs(t) do if (seg.first[name] or 0) ~= (last[name] or 0) and M.spoils(name) then want(name) end end
      end
      table.sort(order)
      local parts = {}
      for _, name in ipairs(order) do
        local a, b, s, k = seg.first[name] or 0, last[name] or 0, seg.spoiled[name] or 0, built(name)
        local left, came = math.max(0, a - b - s - k), math.max(0, b - a + s + k)
        local dn, up = seg.down and seg.down[name], seg.up and seg.up[name]
        local bits = {}
        if dn then bits[#bits+1] = string.format('expected down %d (landing pads ask %d, hold %d%s)', dn.expected, dn.ask, dn.hold, dn.keep and '; ' .. dn.keep or '') end
        if up then bits[#bits+1] = string.format('expected up %d (the hub asks %d from %s%s)', up.short, up.min, seg.at, up.way and string.format(', %d on the way then', up.way) or '') end
        if left > 0 or dn then bits[#bits+1] = string.format('left the hub %d', left) end
        if came > 0 or up then bits[#bits+1] = string.format('came aboard %d', came) end
        if k > 0 then
          bits[#bits+1] = string.format('built at once %d (construction robots placed it from the hub: %d -> %d on the platform)',
            k, seg.built0[name], built1[name])
        end
        if s > 0 then bits[#bits+1] = string.format('spoiled aboard %d', s) end
        rows[#rows+1] = {item=name, held_at_arrival=a, held_at_end=b, left=left, came=came, spoiled=s, built=k > 0 and k or nil,
          expected_down=dn and dn.expected or nil, expected_up=up and up.short or nil}
        parts[#parts+1] = name .. ': ' .. table.concat(bits, ', ')
      end
      local shown = {}
      for i = 1, math.min(M.ITEMS, #parts) do shown[i] = parts[i] end
      local text = string.format('stop at %s (%s)', seg.at, when(seg, game.tick)) .. (seg.no_unload and ' [' .. seg.no_unload .. ' (at arrival)]' or '')
      if #shown > 0 then text = text .. ': ' .. table.concat(shown, '; ') .. (#parts > M.ITEMS and string.format(' (+%d more items)', #parts - M.ITEMS) or '') end
      if seg.rockets then text = text .. string.format('; rockets launched to it: %d, cargo %s', seg.rockets.n, items_text(seg.rockets.cargo) or 'none') end
      local ptext, pods = pods_text(seg, flying, now)
      if ptext then text = text .. '; ' .. ptext end
      if #shown == 0 and not seg.rockets and not ptext then text = text .. ': nothing expected down or up, no rocket, nothing spoiled' end
      return {line=text, kind='stop', at=seg.at, start=seg.start, ['end']=seg['end'], items=rows, pods=pods}
    end
    -- A leg: the spoilable items aboard at departure, what spoiled on the way.
    local parts = {}
    local names = {}
    for name, n in pairs(seg.first) do if n > 0 and M.spoils(name) then names[#names+1] = name end end
    for name in pairs(seg.spoiled) do if not seg.first[name] then names[#names+1] = name end end
    table.sort(names)
    for _, name in ipairs(names) do
      local s = seg.spoiled[name] or 0
      parts[#parts+1] = string.format('%s %d aboard at departure, %d spoiled on the way%s, %d %s', name, seg.first[name] or 0, s,
        s > 0 and seg.into and seg.into[name] and ' (into ' .. seg.into[name] .. ')' or '', last[name] or 0, seg['end'] and 'at arrival' or 'now')
      rows[#rows+1] = {item=name, aboard_at_departure=seg.first[name] or 0, spoiled=s, held_at_end=last[name] or 0}
    end
    local text = string.format('leg %s->%s (%s)', seg.from, seg.to, when(seg, game.tick))
      .. (#parts > 0 and ': ' .. table.concat(parts, '; ') or ': no spoilable item aboard')
    return {line=text, kind='leg', from=seg.from, to=seg.to, start=seg.start, ['end']=seg['end'], items=rows}
  end
  -- Our platforms headed for a planet (Sonnet: stage freight for a platform flying toward the agent): flying to it, or
  -- with it in their schedule, each with where it is, its ETA through the schedule (before_departure) and what its hub
  -- holds (main inventory, the largest stacks first).
  function M.headed(force, planet, limit)
    local rows = {}
    for _, pl in pairs(try(function() return force.platforms end) or {}) do
      if pl.valid and pl.hub and pl.hub.valid then
        local w = M.where(pl)
        local goes = w.leg and w.leg.to == planet
        if not goes and w.at ~= planet then
          for _, r in ipairs(try(function() return pl.schedule.records end) or {}) do if r.station == planet then goes = true end end
        end
        if goes and w.at ~= planet then
          local est, why = M.before_departure(pl, planet)
          local inv = try(function() return pl.hub.get_inventory(defines.inventory.hub_main) end)
          local items = {}
          for _, s in ipairs(inv and try(function() return inv.get_contents() end) or {}) do items[#items+1] = {name=s.name, count=s.count, quality=s.quality} end
          table.sort(items, function(x, y) if x.count ~= y.count then return x.count > y.count end return x.name < y.name end)
          local text = {}
          for i, s in ipairs(items) do if i > 10 then text[#text+1] = '+' .. (#items - 10) .. ' more'; break end; text[#text+1] = s.name .. '*' .. s.count end
          local eta = est and est.eta_s
          rows[#rows+1] = {platform=pl.name, where=w.text, eta_s=eta, eta=est and est.line or why, hub=#text > 0 and table.concat(text, ' ') or 'empty',
            line=string.format('%s (%s): %s; hub: %s', pl.name, w.text, est and est.line or ('no estimate: ' .. tostring(why)), #text > 0 and table.concat(text, ' ') or 'empty')}
        end
      end
    end
    table.sort(rows, function(x, y) return (x.eta_s or math.huge) < (y.eta_s or math.huge) end)
    while limit and #rows > limit do table.remove(rows) end
    return rows
  end
  -- Rockets on their way to a platform's hub (Astra, 22:50: cargo still incoming, reconciled by hand): each launch to it
  -- keeps its cargo pod until the pod is gone. 2.0.77 on a copy of world n: a pod rose over the planet about 25 s, came
  -- down onto the platform's surface at about 30 s and was gone (its cargo delivered) by 35 s.
  function M.incoming(pl)
    local rec = store()[pl.index]
    if not (rec and rec.incoming) then return nil end
    local keep, lines, all = {}, {}, {}
    local here = try(function() return pl.surface.name end)
    local up, n_up = M.up_time(rec)
    -- (the list itself is settled by pod_watch, which times each arrival)
    for _, r in ipairs(rec.incoming) do
      if r.pod and try(function() return r.pod.valid end) and game.tick - r.tick < UP_MAX then
        keep[#keep+1] = r
        local on = try(function() return r.pod.surface.name end)
        local items = {}
        for name, n in pairs(r.cargo or {}) do items[#items+1] = name .. '*' .. n; all[name] = (all[name] or 0) + n end
        table.sort(items)
        local age = game.tick - r.tick
        r.eta = up and math.max(0, up - age) or nil
        lines[#lines+1] = string.format('a rocket from %s launched %s ago (%stick %d): %s (%s)%s', tostring(r.from or '?'), secs(age), r.up and 'up #' .. r.up .. ', ' or '', r.tick,
          #items > 0 and table.concat(items, ' ') or 'empty', on == here and 'coming down onto the platform' or 'rising over ' .. tostring(on),
          up and (age < up and string.format('; arrives in about %s (the last %d arrival%s took about %s from launch)', secs(up - age), n_up, n_up == 1 and '' or 's', secs(up))
            or string.format('; past the usual %s from launch', secs(up))) or '')
      end
    end
    if #keep == 0 then return nil end
    -- rows (shipment.lua): each rocket's cargo, where it is, launched when
    local rows = {}
    for _, r in ipairs(keep) do
      local on = try(function() return r.pod.surface.name end)
      rows[#rows+1] = {cargo=r.cargo or {}, cargo_q=r.cargo_q, from=r.from, tick=r.tick, down=on == here, eta_ticks=r.eta}
    end
    local total = {}
    for name, n in pairs(all) do total[#total+1] = name .. '*' .. n end
    table.sort(total)
    return {rockets=#keep, cargo=#total > 0 and table.concat(total, ' ') or 'empty', lines=lines, rows=rows}
  end
  -- Per ammo type over the last leg (flying: this leg so far; stopped: the leg before): made and used a minute, what the
  -- hub and the turrets hold now, and while flying what is left at the arrival at that rate (or when it runs out).
  -- A leg opened before this was counted (a runtime update) reads the game's last 10 minutes instead.
  -- (d20 batch51 H1, viewer Aurora 09:36) The stock, what rockets bring and what is made on the way are platform_endurance's
  -- (ammomodel.lua): what can reach no turret is left out, said; rockets on their way up count once; made is at most what
  -- the ingredients aboard allow (Kestrel II's railgun rounds, shift45 12:05: made 145 by the rate against a cap of about
  -- 30); each row says which limit binds.
  local function per_min(n, minutes)
    local v = minutes > 0 and n / minutes or 0
    return v >= 10 and string.format('%d', math.floor(v + 0.5)) or string.format('%.1f', math.floor(v * 10 + 0.5) / 10)
  end
  function M.ammo(pl)
    local rec = store()[pl.index]
    local seg
    for i = #(rec and rec.segs or {}), 1, -1 do
      if rec.segs[i].kind == 'leg' then seg = rec.segs[i]; break end
    end
    local now = ammo_counts(pl) or {}
    -- Every place aboard (the hub's main inventory: its trash goes down at the next stop): hub, turrets, belts, inserter
    -- hands, machines' outputs (M.stock_places); every item, for the ingredients the model counts.
    local sp = M.stock_places(pl, setmetatable({}, {__index=function() return true end}))
    local AM = api.ammomodel and api.ammomodel()
    -- (the trace of what can reach a turret: its background read, so the platforms read and preflight trace nothing more)
    local model = AM and try(function() return AM.new(pl, {places=sp, background=true}) end)
    local names, seen = {}, {}
    local function want(name) if not seen[name] then seen[name] = true; names[#names+1] = name end end
    for _, name in ipairs(ammo_names()) do if (sp.total[name] or 0) > 0 then want(name) end end
    -- The window: the leg's own counts, else the game's last 10 minutes.
    local c0, c1, minutes, window
    local flying = seg and not seg['end']
    if seg and seg.ammo0 and (flying or seg.ammo1) then
      c0, c1 = seg.ammo0, flying and now or seg.ammo1
      minutes = ((flying and game.tick or seg['end']) - seg.start) / 3600
      window = string.format('%s %s->%s (%s%s)', flying and 'this leg' or 'the last leg', seg.from or '?', seg.to or '?',
        secs((flying and game.tick or seg['end']) - seg.start), flying and ' so far' or '')
    else
      minutes, window = 10, 'the last 10 min'
    end
    for name in pairs(c1 or {}) do
      local d = c1[name]; local b = (c0 or {})[name] or {made=0, used=0}
      if d.made - b.made > 0 or d.used - b.used > 0 then want(name) end
    end
    local stats = try(function() return pl.force.get_item_production_statistics(pl.surface) end)
    -- The last 1 and 5 minutes too (Astra, shift17 10:50: parked over Aquilo the line kept the finished flight's average;
    -- "leg average obscures whether orbit is sustainable"): the game's own counts for the platform surface.
    local function flow(name, category, precision)
      return stats and precision and try(function() return qflow.flow(stats, name, category, precision, true) end) or 0
    end
    local P = defines.flow_precision_index or {}
    local l = flying and M.leg(pl)
    local rows = {}
    if model then
      for name, n in pairs(model.received) do if n > 0 then want(name) end end
    end
    table.sort(names)
    -- the rates first: the model splits an ingredient two of them draw on by both
    local counts = {}
    for _, name in ipairs(names) do
      local made, used
      if c0 then
        local a, b = (c0[name] or {made=0, used=0}), (c1[name] or {made=0, used=0})
        made, used = b.made - a.made, b.used - a.used
      else
        made, used = flow(name, 'input', P.ten_minutes), flow(name, 'output', P.ten_minutes)
      end
      counts[name] = {made, used}
      if model and minutes > 0 then model.make(name, made / minutes) end
    end
    for _, name in ipairs(names) do
      local made, used = counts[name][1], counts[name][2]
      local stock = sp.total[name] or 0
      local text = string.format('%s: made %s/min, used %s/min (fired or crafted into another item; moves between places are not use) over %s; %d aboard: %s%s', name, per_min(made, minutes),
        per_min(used, minutes), window, stock, M.places_text(sp, name),
        sp.from_belt_read and sp.as_of and string.format(' (belts and inserter hands as read in the background %s ago)', secs(math.max(0, game.tick - sp.as_of)))
          or sp.from_census and sp.as_of and string.format(' (belts and inserter hands as the census pass read them %s ago)', secs(math.max(0, game.tick - sp.as_of))) or '')
      local stranded = model and model.stranded[name] or 0
      if stranded > 0 then
        stock = model.held[name] or 0
        text = text .. string.format('; %d of it can reach no turret (stranded), not counted: %d', stranded, stock)
      end
      local rec = model and model.received[name] or 0
      if rec > 0 then text = text .. string.format('; %d more on rockets on their way up, counted', rec) end
      -- Since the leg began, by place: what was loaded from the hub onto belts and into turrets is told from the firing.
      local moved = c0 and seg.places0 and M.moved_text(seg.places0, flying and sp or seg.places1, name)
      if moved then text = text .. '; since ' .. (flying and 'this leg began' or 'the last leg began') .. ': ' .. moved end
      local m1, u1 = flow(name, 'input', P.one_minute), flow(name, 'output', P.one_minute)
      local m5, u5 = flow(name, 'input', P.five_minutes), flow(name, 'output', P.five_minutes)
      if stats and P.one_minute and P.five_minutes then
        text = text .. string.format('; last 1 min: made %s/min, used %s/min; last 5 min: made %s/min, used %s/min', per_min(m1, 1), per_min(u1, 1),
          per_min(m5, 5), per_min(u5, 5))
        -- Stopped (no arrival to count to): how long the stock lasts at the last 5 minutes' rate when it falls.
        if not flying and u5 > m5 then
          text = text .. string.format('; at the last 5 min rate the %d aboard last %s', stock, secs((stock / ((u5 - m5) / 5)) * 3600))
        end
      end
      if l and l.eta_ticks and minutes > 0 then
        local eta_min = l.eta_ticks / 3600
        local mr, ur = made / minutes, used / minutes
        local left, lasts, b
        if model then
          left, lasts, b = model.left(name, mr, ur, eta_min, stock), model.lasts(name, mr, ur, stock), model.binds(name, mr, eta_min)
        else
          left = stock + (mr - ur) * eta_min
          lasts = mr < ur and stock / (ur - mr) or nil
        end
        if left < 0 and lasts then
          text = text .. string.format('; runs out in %s at that rate, before the arrival at %s in %s', secs(lasts * 3600), l.to, secs(l.eta_ticks))
        else
          text = text .. string.format('; at the arrival at %s in %s about %d at that rate', l.to, secs(l.eta_ticks), math.floor(left + 0.5))
        end
        if b then text = text .. '; ' .. b.line end
        if model and not model.feed and model.feed_why then text = text .. '; stranded ammunition not told apart yet: ' .. model.feed_why end
      end
      rows[#rows+1] = text
    end
    return #rows > 0 and rows or nil
  end
  -- (A3) The landed receipts, newest first: what, where, when, which pod, from which stop.
  function M.receipts(pl, limit)
    local rec = store()[pl.index]
    if not (rec and rec.receipts and #rec.receipts > 0) then return nil end
    local out = {}
    for i = #rec.receipts, math.max(1, #rec.receipts - (limit or 8) + 1), -1 do
      local r = rec.receipts[i]
      local asked = M.asked_text(r.asked)
      out[#out+1] = string.format('%s %s %s, %s ago (pod %s, left the hub %s ago, from the stop at %s)%s', items_text(r.cargo) or 'empty',
        r.kind == 'received' and 'received by' or r.kind == 'landed' and 'landed as' or r.kind == 'lost' and 'was' or 'was', r.where, secs(game.tick - r.tick),
        r.unit and '#' .. r.unit or '?', secs(game.tick - r.sent), tostring(r.stop), asked and '; ' .. asked or '')
    end
    return out
  end
  -- The platform's last stops and legs, newest first (at most SHOW).
  function M.read(pl)
    local rec = store()[pl.index]
    if not rec or #rec.segs == 0 then return nil end
    local out = {}
    local now = M.hub_counts(pl)
    local flying = {}
    for _, p in ipairs(rec.pods or {}) do flying[p.seg] = flying[p.seg] or {}; table.insert(flying[p.seg], p) end
    for i = #rec.segs, math.max(1, #rec.segs - M.SHOW + 1), -1 do
      out[#out+1] = M.segment(rec.segs[i], game.tick, now, flying[rec.segs[i].start], pl)
    end
    return out
  end
  -- The hub's spoilable items now (spoil.lua's rows: the first stack to spoil,
  -- its share, how many within 5 min) and, while flying, how many spoil before
  -- the arrival at the leg's end and when the first of the rest spoils.
  function M.freshness(pl)
    local hub = try(function() return pl.hub end)
    local inv = hub and hub.valid and try(function() return hub.get_inventory(defines.inventory.hub_main) end)
    if not (inv and api.spoil) then return nil end
    local l = M.leg(pl)
    local trash = defines.inventory.hub_trash and try(function() return hub.get_inventory(defines.inventory.hub_trash) end)
    local acc = api.spoil.inventory(inv, {}, nil, l and l.eta_ticks)
    if trash then api.spoil.inventory(trash, acc, nil, l and l.eta_ticks) end
    if #acc == 0 then return nil end
    local arrive = l and l.eta_ticks and game.tick + l.eta_ticks
    local before, after = {}, {}
    if arrive then
      for _, inventory in ipairs(trash and {inv, trash} or {inv}) do
        for i = 1, #inventory do
          local s = inventory[i]
          local t = api.spoil.stack_spoil(s)
          if t then
            local q = try(function() return s.quality.name end) or 'normal'
            local key = s.name .. (q ~= 'normal' and '@' .. q or '')
            if t <= arrive then before[key] = (before[key] or 0) + s.count
            elseif not after[key] or t < after[key] then after[key] = t end
          end
        end
      end
    end
    table.sort(acc, function(x, y) return x.tick < y.tick or (x.tick == y.tick and x.key < y.key) end)
    local out = {}
    for i = 1, math.min(8, #acc) do
      local r = acc[i]
      local text = api.spoil.row_text(r)
      local value = api.spoil.research_text and api.spoil.research_text(r, pl.force)
      if value then text = text .. '; ' .. value end
      if arrive then
        local b = before[r.key] or 0
        text = text .. string.format('; arrival at %s in %s: %d spoil before it, %d arrive', l.to, secs(l.eta_ticks), b, r.count - b)
          .. (after[r.key] and string.format(', the next spoils %s after arrival', secs(after[r.key] - arrive)) or '')
      end
      out[#out+1] = text
    end
    if #acc > 8 then out[#out+1] = string.format('+%d more spoilable items', #acc - 8) end
    return out
  end
  return M
end
