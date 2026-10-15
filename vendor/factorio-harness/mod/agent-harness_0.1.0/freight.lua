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
-- at a stop its surface is looked at every POD_TICKS for cargo pods leaving its hub, each followed (its surface, place
-- and cargo) while it exists, as drops.lua follows a drop's pod. Gone after reaching the planet's surface: received by
-- the landing pad it was sent to, or landed as a cargo pod container where none was; gone before leaving the
-- platform: said so. A stop then says how many pods went down with what, what each pad received, and the pods still
-- in flight (their unit numbers and cargo).
return function(api)
  local M = {}
  M.KEEP, M.SHOW, M.ITEMS = 8, 6, 6
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function secs(ticks)
    local s = math.max(0, math.floor(ticks / 60 + 0.5))
    if s >= 60 then return string.format('%dm%02ds', math.floor(s / 60), s % 60) end
    return s .. 's'
  end
  M.secs = secs
  local POD_TICKS, POD_PENDING = 15, 64
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
    return {from=back and to or from, to=back and from or to, flown=flown, length=length, left_km=left,
      eta_ticks=type(speed) == 'number' and speed > 0 and left / speed or nil, back=back}
  end
  -- {at (a space location, when there), stopped (there and not on its path),
  -- leg (M.leg while flying), text}. The platforms row and platform_arrived
  -- both read this, so a wait is met exactly when the row says the platform is
  -- stopped there.
  function M.where(pl)
    local loc = try(function() return pl.space_location.name end)
    if loc then
      if on_path(pl) then return {at=loc, stopped=false, text='at ' .. loc .. ', on its path (not stopped)'} end
      return {at=loc, stopped=true, text='at ' .. loc}
    end
    local l = M.leg(pl)
    if l then return {leg=l, text=string.format('flying %s->%s %d%%', l.from, l.to, math.floor(l.flown * 100 + 0.5))} end
    return {text='nowhere'}
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
    for _, pad in ipairs(try(function() return s.find_entities_filtered{type='cargo-landing-pad', force=force} end) or {}) do
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
  local function open(rec, pl, w, counts, tick, first)
    local seg = {start=tick, first=copy(counts), spoiled={}, partial=first or nil}
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
      if was then was['end'], was.last = tick, copy(rec.prev or counts) end
      -- Arrivals and departures for the team alert (Gemini, 16:50); not the first look's stop.
      if was and was.kind == 'stop' then M.event(pl, 'left', was.at, tick, w.leg and w.leg.to) end
      seg = open(rec, pl, w, counts, tick, rec.key == nil)
      if rec.key ~= nil and seg.kind == 'stop' then M.event(pl, 'arrived', seg.at, tick) end
      rec.key = key
    elseif seg and not seg['end'] and rec.prev then
      spoil_step(seg, rec.prev, counts)
    end
    rec.prev, rec.tick = counts, tick
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
        out[#out+1] = e.kind == 'arrived'
          and string.format('platform %s stopped at %s, your planet, %s ago', e.platform, e.at, secs(game.tick - e.tick))
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
  -- on_rocket_launch_ordered: a rocket whose cargo pod goes to a platform's hub
  -- counts on that platform's stop.
  function M.on_launch(event)
    local pod = try(function() return event.rocket.attached_cargo_pod end)
    local d = pod and try(function() return pod.cargo_pod_destination end)
    local pl = d and ((d.station and try(function() return d.station.surface.platform end)) or d.space_platform)
    if not (pl and try(function() return pl.valid end)) then return end
    local rec = store()[pl.index]
    local seg = rec and rec.segs[#rec.segs]
    if not seg or seg['end'] then return end
    local inv = defines.inventory.cargo_unit and try(function() return pod.get_inventory(defines.inventory.cargo_unit) end)
    seg.rockets = seg.rockets or {n=0, cargo={}}
    seg.rockets.n = seg.rockets.n + 1
    add_contents(seg.rockets.cargo, inv and try(function() return inv.get_contents() end))
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
  local function pod_done(rec, p, tick)
    local seg = seg_at(rec, p.seg)
    if not seg then return end
    seg.pods = seg.pods or {}
    local here = p.last and p.last.surface
    if here and here ~= p.from then
      if p.dest and p.dest.pad then
        tally(seg.pods, 'received', p.cargo, string.format('%s (%g,%g) on %s', p.dest.pad, p.dest.position.x, p.dest.position.y, p.dest.surface or here))
      else
        tally(seg.pods, 'landed', p.cargo, string.format('(%d,%d) on %s', math.floor(p.last.position.x + 0.5), math.floor(p.last.position.y + 0.5), here))
      end
      seg.pods.last_tick = tick
    else
      tally(seg.pods, 'gone', p.cargo)
    end
  end
  local function is_mine(pod, pl, hub)
    local origin = try(function() return pod.cargo_pod_origin end)
    if origin then return try(function() return origin == hub end) == true end
    -- No origin read: one sent off the platform counts (a rocket's pod comes down onto it).
    local d = pod_dest(pod)
    return d ~= nil and d.surface ~= nil and d.surface ~= try(function() return pl.surface.name end)
  end
  function M.pod_watch(pl, tick)
    local rec = store()[pl.index]
    if not rec then return end
    -- The pods followed: where they are, and the ones gone.
    local keep = {}
    for _, p in ipairs(rec.pods or {}) do
      if try(function() return p.pod.valid end) then
        local where = try(function() return {surface=p.pod.surface.name, position=xy(p.pod.position)} end)
        if where then p.last = where end
        if where and where.surface == p.from then p.cargo = pod_cargo(p.pod) end
        p.dest = pod_dest(p.pod) or p.dest
        keep[#keep+1] = p
      else
        p.pod = nil
        pod_done(rec, p, tick)
      end
    end
    rec.pods = keep
    -- New pods leaving the hub while it is at a stop.
    local seg = rec.segs[#rec.segs]
    if not (seg and seg.kind == 'stop' and not seg['end']) then return end
    local s, hub = try(function() return pl.surface end), try(function() return pl.hub end)
    if not (s and hub) then return end
    for _, pod in ipairs(try(function() return s.find_entities_filtered{type='cargo-pod'} end) or {}) do
      local known = false
      for _, p in ipairs(rec.pods) do if try(function() return p.pod == pod end) then known = true; break end end
      if not known and #rec.pods < POD_PENDING and is_mine(pod, pl, hub) then
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
    local text = seg['end'] and string.format('%s, %s ago', secs(seg['end'] - seg.start), secs(now - seg['end']))
      or string.format('%s so far', secs(now - seg.start))
    return seg.partial and text .. '; under way when first seen' or text
  end
  -- One stop or leg in words, with its numbers: {line, kind, at|from+to, start, end, items={...}}.
  -- A stop's pods: those gone (received, landed without a pad, gone before leaving) and those still followed.
  local function pods_text(seg, flying, now)
    local d = seg.pods or {}
    local sent = {n=0, cargo={}}
    for _, k in ipairs({'received', 'landed', 'gone'}) do
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
    if fly.n > 0 then bits[#bits+1] = string.format('in flight %d (%s): %s', fly.n, items_text(fly.cargo) or 'empty', table.concat(fly.units, ', ')) end
    return table.concat(bits, ', '), {sent=sent.n, sent_items=sent.cargo, received=d.received and d.received.n or 0,
      received_items=d.received and d.received.cargo or nil, landed=d.landed and d.landed.n or nil, gone=d.gone and d.gone.n or nil,
      in_flight=fly.n, in_flight_items=fly.n > 0 and fly.cargo or nil, in_flight_pods=fly.n > 0 and fly.units or nil}
  end
  function M.segment(seg, now, counts_now, flying)
    local last = seg.last or counts_now or {}
    local rows = {}
    if seg.kind == 'stop' then
      -- The items the stop is about: expected down or up, rocket cargo, spoiled.
      local names, order = {}, {}
      local function want(name) if not names[name] then names[name] = true; order[#order+1] = name end end
      for name in pairs(seg.down or {}) do want(name) end
      for name in pairs(seg.up or {}) do want(name) end
      for name in pairs(seg.rockets and seg.rockets.cargo or {}) do want(name) end
      for name in pairs(seg.spoiled) do want(name) end
      -- and any spoilable item whose count changed over the stop
      for _, t in ipairs({seg.first, last}) do
        for name in pairs(t) do if (seg.first[name] or 0) ~= (last[name] or 0) and M.spoils(name) then want(name) end end
      end
      table.sort(order)
      local parts = {}
      for _, name in ipairs(order) do
        local a, b, s = seg.first[name] or 0, last[name] or 0, seg.spoiled[name] or 0
        local left, came = math.max(0, a - b - s), math.max(0, b - a + s)
        local dn, up = seg.down and seg.down[name], seg.up and seg.up[name]
        local bits = {}
        if dn then bits[#bits+1] = string.format('expected down %d (landing pads ask %d, hold %d)', dn.expected, dn.ask, dn.hold) end
        if up then bits[#bits+1] = string.format('expected up %d (the hub asks %d from %s)', up.short, up.min, seg.at) end
        if left > 0 or dn then bits[#bits+1] = string.format('left the hub %d', left) end
        if came > 0 or up then bits[#bits+1] = string.format('came aboard %d', came) end
        if s > 0 then bits[#bits+1] = string.format('spoiled aboard %d', s) end
        rows[#rows+1] = {item=name, held_at_arrival=a, held_at_end=b, left=left, came=came, spoiled=s,
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
  -- The platform's last stops and legs, newest first (at most SHOW).
  function M.read(pl)
    local rec = store()[pl.index]
    if not rec or #rec.segs == 0 then return nil end
    local out = {}
    local now = M.hub_counts(pl)
    local flying = {}
    for _, p in ipairs(rec.pods or {}) do flying[p.seg] = flying[p.seg] or {}; table.insert(flying[p.seg], p) end
    for i = #rec.segs, math.max(1, #rec.segs - M.SHOW + 1), -1 do
      out[#out+1] = M.segment(rec.segs[i], game.tick, now, flying[rec.segs[i].start])
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
    local acc = api.spoil.inventory(inv, {})
    if #acc == 0 then return nil end
    local l = M.leg(pl)
    local arrive = l and l.eta_ticks and game.tick + l.eta_ticks
    local before, after = {}, {}
    if arrive then
      for i = 1, #inv do
        local s = inv[i]
        local t = api.spoil.stack_spoil(s)
        if t then
          if t <= arrive then before[s.name] = (before[s.name] or 0) + s.count
          elseif not after[s.name] or t < after[s.name] then after[s.name] = t end
        end
      end
    end
    table.sort(acc, function(x, y) return x.tick < y.tick or (x.tick == y.tick and x.key < y.key) end)
    local out = {}
    for i = 1, math.min(8, #acc) do
      local r = acc[i]
      local text = api.spoil.row_text(r)
      if arrive then
        local b = before[r.name] or 0
        text = text .. string.format('; arrival at %s in %s: %d spoil before it, %d arrive', l.to, secs(l.eta_ticks), b, r.count - b)
          .. (after[r.name] and string.format(', the next spoils %s after arrival', secs(after[r.name] - arrive)) or '')
      end
      out[#out+1] = text
    end
    if #acc > 8 then out[#out+1] = string.format('+%d more spoilable items', #acc - 8) end
    return out
  end
  return M
end
