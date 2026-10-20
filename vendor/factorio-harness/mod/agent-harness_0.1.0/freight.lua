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
return function(api)
  local M = {}
  M.KEEP, M.SHOW, M.ITEMS, M.RECEIPTS = 8, 6, 6, 16
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
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
    return s ~= nil and try(function() return pl.state end) == s
  end
  -- The leg flown now, in the way it is flown: {from, to, flown (share of the
  -- leg behind it), left_km, eta_ticks, length}. A connection is measured from
  -- its own `from` end whichever way it is flown (pl.distance); the end headed
  -- for is the schedule's stop when it is one of the two ends, else the end the
  -- platform did not come from (last visited).
  function M.leg(pl)
    local c = try(function() return pl.space_connection end)
    if not c then return nil end
    local from, to = try(function() return c.from.name end) or '?', try(function() return c.to.name end) or '?'
    local d = try(function() return pl.distance end) or 0
    local sch = try(function() return pl.schedule end)
    local records = sch and sch.records or {}
    local rec = records[sch and sch.current or 1]
    local stop = rec and rec.station
    local last = try(function() return pl.last_visited_space_location.name end)
    local back
    if stop == from or stop == to then back = stop == from else back = last == to end
    local flown = back and 1 - d or d
    local length = try(function() return c.length end) or 0
    local left = (1 - flown) * length
    local speed = try(function() return pl.speed end)
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
    return {from=back and to or from, to=back and from or to, flown=flown, length=length, left_km=left,
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
    local loc = try(function() return pl.space_location.name end)
    if loc then
      if on_path(pl) then return {at=loc, stopped=false, text='at ' .. loc .. ', on its path (not stopped)'} end
      return {at=loc, stopped=true, text='at ' .. loc}
    end
    local l = M.leg(pl)
    if l then return {leg=l, text=string.format('flying %s->%s %d%%', l.from, l.to, math.floor(l.flown * 100 + 0.5))} end
    return {text='nowhere'}
  end
  function M.where(pl)
    local w = where_row(pl)
    local st = api.state and try(function() return api.state() end)
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
  -- The hub's items, its main inventory and its trash, by name.
  function M.hub_counts(pl)
    local hub = try(function() return pl.hub end)
    if not (hub and hub.valid) then return nil end
    local out = {}
    for _, id in ipairs({'hub_main', 'hub_trash'}) do
      local inv = defines.inventory[id] and try(function() return hub.get_inventory(defines.inventory[id]) end)
      if inv then add_contents(out, try(function() return inv.get_contents() end)) end
    end
    return out
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
  -- The hub's requests that import from this planet: {item={min, short}}.
  local function hub_asks(pl, planet, counts)
    local out = {}
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
            r.short = math.max(0, r.min - (counts[name] or 0))
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
  local AMMO
  local function ammo_names()
    if not AMMO then
      AMMO = {}
      for name, item in pairs(prototypes.item) do if item.type == 'ammo' then AMMO[#AMMO+1] = name end end
      table.sort(AMMO)
    end
    return AMMO
  end
  local function ammo_counts(pl)
    local stats = try(function() return pl.force.get_item_production_statistics(pl.surface) end)
    if not stats then return nil end
    local out = {}
    for _, name in ipairs(ammo_names()) do
      local made = try(function() return stats.get_input_count(name) end) or 0
      local used = try(function() return stats.get_output_count(name) end) or 0
      if made > 0 or used > 0 then out[name] = {made=made, used=used} end
    end
    return out
  end
  M.ammo_counts = ammo_counts
  -- (d18 batch39 C2) thruster fuel and oxidizer made and used on the platform (its fluid statistics, totals)
  M.FLUIDS = {'thruster-fuel', 'thruster-oxidizer'}
  local function fluid_counts(pl)
    local stats = try(function() return pl.force.get_fluid_production_statistics(pl.surface) end)
    if not stats then return nil end
    local out = {}
    for _, name in ipairs(M.FLUIDS) do
      out[name] = {made=try(function() return stats.get_input_count(name) end) or 0, used=try(function() return stats.get_output_count(name) end) or 0}
    end
    return out
  end
  local function open(rec, pl, w, counts, tick, first)
    local seg = {start=tick, first=copy(counts), spoiled={}, partial=first or nil, ammo0=ammo_counts(pl), fuel0=fluid_counts(pl), places0=M.places_snapshot(pl)}
    if w.stopped then
      seg.kind, seg.at = 'stop', w.at
      local ask, hold = pads(w.at, pl.force)
      local down = {}
      for name, n in pairs(counts) do
        local want = (ask[name] or 0) - (hold[name] or 0)
        if want > 0 then down[name] = {expected=math.min(n, want), ask=ask[name], hold=hold[name] or 0} end
      end
      seg.down = next(down) and down or nil
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
  local function spoil_step(seg, before, now)
    local rise = {}
    for name, n in pairs(now) do local d = n - (before[name] or 0); if d > 0 then rise[name] = d end end
    for name, n in pairs(before) do
      local fall = n - (now[name] or 0)
      local r = fall > 0 and M.spoil_result(name)
      if r and (rise[r] or 0) > 0 then
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
  function M.phase_step(rec, pl, w)
    local now = ammo_counts(pl)
    if not now then return end
    local phase
    if w.stopped then phase = 'stopped'
    elseif w.leg then
      local paused = try(function() return pl.paused end)
      local v = try(function() return pl.speed end) or 0
      phase = (paused or v <= 0) and 'still' or 'moving'
    end
    local prev = rec.ammo_prev
    rec.ammo_prev = now
    if not (prev and phase) then return end
    rec.phase = rec.phase or {moving={s=0, by={}}, still={s=0, by={}}, stopped={s=0, by={}}}
    local ph = rec.phase[phase]
    ph.s = ph.s + 1
    for name, c in pairs(now) do
      local p0 = prev[name] or {made=0, used=0}  -- ammo_counts leaves out an ammunition at 0 and 0
      local d = ph.by[name] or {made=0, used=0}
      d.made = d.made + math.max(0, c.made - p0.made); d.used = d.used + math.max(0, c.used - p0.used)
      ph.by[name] = d
    end
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
        and try(function() return pl.last_visited_space_location.name end) == was.to then
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
    local v = w.leg and try(function() return pl.speed end)
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
  function M.geometry(pl)
    local s = try(function() return pl.surface end)
    local out = {thrusters=s and try(function() return s.count_entities_filtered{type='thruster', force=pl.force} end) or nil}
    local tiles = s and try(function() return s.find_tiles_filtered{name='space-platform-foundation', area={{-128, -128}, {128, 128}}} end)
    if tiles and #tiles > 0 then
      local lo, hi = math.huge, -math.huge
      for _, t in pairs(tiles) do local x = t.position.x; if x < lo then lo = x end; if x > hi then hi = x end end
      out.width = hi - lo + 1
    end
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
      t = t .. ' ' .. tostring(cond.first_signal.name) .. ' ' .. tostring(cond.comparator or '<') .. ' ' .. tostring(cond.constant or (cond.second_signal and cond.second_signal.name) or 0)
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
      for _, pl in pairs(try(function() return f.platforms end) or {}) do
        if pl.valid then seen[pl.index] = true; pcall(M.track, pl, tick) end
      end
    end
    local all = store()
    for index in pairs(all) do if not seen[index] then all[index] = nil end end
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
        rec.incoming[#rec.incoming+1] = {pod=pod, tick=game.tick, cargo=add_contents({}, inv and try(function() return inv.get_contents() end)),
          from=try(function() return event.rocket_silo.surface.name end), up=event.harness_up}
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
  local function pod_cargo(pod)
    local inv = defines.inventory.cargo_unit and try(function() return pod.get_inventory(defines.inventory.cargo_unit) end)
    return add_contents({}, inv and try(function() return inv.get_contents() end))
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
  local function receipt(rec, p, tick, kind, where)
    rec.receipts = rec.receipts or {}
    table.insert(rec.receipts, {tick=tick, sent=p.tick, unit=p.unit, cargo=p.cargo, kind=kind, where=where, stop=p.at, stop_start=p.seg})
    while #rec.receipts > M.RECEIPTS do table.remove(rec.receipts, 1) end
  end
  local function pod_done(rec, p, tick, hub_dead)
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
        receipt(rec, p, tick, 'received', where)
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
  function M.up_settle(rec, tick)
    local keep = {}
    for _, r in ipairs(rec.incoming or {}) do
      if r.pod and try(function() return r.pod.valid end) then
        if tick - r.tick < UP_MAX then keep[#keep+1] = r end
      else
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
  -- {tick, kind (received | landed | gone), where, cargo {item = count}} each, oldest first.
  function M.receipts_since(pl, since)
    local out = {}
    local rec = store()[pl.index]
    for _, r in ipairs(rec and rec.receipts or {}) do
      if r.tick > since then out[#out+1] = {tick=r.tick, kind=r.kind, where=r.where, cargo=r.cargo} end
    end
    return out
  end
  function M.pod_watch(pl, tick)
    local rec = store()[pl.index]
    if not rec then return end
    pcall(M.up_settle, rec, tick)
    -- The pods followed: where they are, and the ones gone.
    local keep = {}
    local hub_dead = not try(function() return pl.hub.valid end)
    for _, p in ipairs(rec.pods or {}) do
      if try(function() return p.pod.valid end) then
        local where = try(function() return {surface=p.pod.surface.name, position=xy(p.pod.position)} end)
        if where then p.last = where end
        if where and where.surface == p.from then p.cargo = pod_cargo(p.pod) end
        p.dest = pod_dest(p.pod) or p.dest
        keep[#keep+1] = p
      else
        p.pod = nil
        pod_done(rec, p, tick, hub_dead)
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
    local s, hub = try(function() return pl.surface end), try(function() return pl.hub end)
    if not (s and hub) then return end
    local found
    if api.pods and api.pods.from then found = try(function() return api.pods.from(pl.force.name, pl.name) end)
    else found = try(function() return s.find_entities_filtered{type='cargo-pod'} end) end
    for _, pod in ipairs(found or {}) do
      local known = false
      for _, p in ipairs(rec.pods) do if try(function() return p.pod == pod end) then known = true; break end end
      if not known and #rec.pods < POD_PENDING and try(function() return pod.valid end) and is_mine(pod, pl, hub) then
        rec.pods[#rec.pods+1] = {pod=pod, unit=try(function() return pod.unit_number end), seg=seg.start, at=seg.at, tick=tick,
          from=s.name, cargo=pod_cargo(pod), dest=pod_dest(pod), last={surface=s.name, position=xy(pod.position)}}
      end
    end
  end
  -- Every POD_TICKS: the platforms at a stop, or with pods still followed.
  function M.pod_tick(tick)
    if tick % POD_TICKS ~= 0 then return end
    local all = store()
    for _, f in pairs(game.forces) do
      for _, pl in pairs(try(function() return f.platforms end) or {}) do
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
        if dn then bits[#bits+1] = string.format('expected down %d (landing pads ask %d, hold %d)', dn.expected, dn.ask, dn.hold) end
        if up then bits[#bits+1] = string.format('expected up %d (the hub asks %d from %s)', up.short, up.min, seg.at) end
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
      local text = string.format('stop at %s (%s)', seg.at, when(seg, game.tick))
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
      rows[#rows+1] = {cargo=r.cargo or {}, from=r.from, tick=r.tick, down=on == here, eta_ticks=r.eta}
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
      return stats and precision and try(function() return stats.get_flow_count{name=name, category=category, precision_index=precision, count=true} end) or 0
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
      local text = string.format('%s: made %s/min, used %s/min (fired or crafted into another item; moves between places are not use) over %s; %d aboard: %s', name, per_min(made, minutes),
        per_min(used, minutes), window, stock, M.places_text(sp, name))
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
      out[#out+1] = string.format('%s %s %s, %s ago (pod %s, left the hub %s ago, from the stop at %s)', items_text(r.cargo) or 'empty',
        r.kind == 'received' and 'received by' or r.kind == 'landed' and 'landed as' or r.kind == 'lost' and 'was' or 'was', r.where, secs(game.tick - r.tick),
        r.unit and '#' .. r.unit or '?', secs(game.tick - r.sent), tostring(r.stop))
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
