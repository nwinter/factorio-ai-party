-- podlog: one ledger of cargo pod journeys, both ways (d24 batch179 QV1; #1989 Astra: Gleba's native drops from
-- Kestrel IVa never showed once the alert scrolled away; #2024 Sol: receipts pruned before the audit, pod ids lost after
-- departure). Every pod sent up (a rocket) or down (from a platform's hub: what the game sends for landing pad requests
-- and hub trash, and the harness's drops) is one journey: pod unit number, platform and its stop, send tick, land tick,
-- where it landed (landing pad, hub or ground position), the items with quality, and at a landing pad the pad's free
-- slots before and after and what did not fit (the game puts it on the ground beside the pad). Kept per planet surface
-- (KEEP journeys each, oldest dropped), across departures and watch completions; shipment {ledger} reads it.
-- Work only on pod events: on_cargo_pod_started_ascending (a hub's pod leaves), on_rocket_launch_ordered (a rocket's
-- pod), on_cargo_pod_finished_descending (landed: the pad's free slots then) and on_cargo_pod_delivered_cargo (the
-- pad's free slots after). Until control.lua forwards the pod events, pods.lua's once-a-second read of the platforms at
-- a stop records hub pods (sent and gone to the second, no pad slots).
-- Facts seen on a copy of world n (2.0.77): a hub pod reads its origin (the hub) and, for a pad request, the pad as its
-- station from the start; a drop names only the surface until it nears the pad. A rocket's pod raises no
-- started_ascending. delivered_cargo comes ~80 ticks after finished_descending, the pod empty by then. A landing pad
-- takes items in its 80 main slots, then (unrequested items and amounts over a request) its 20 trash slots; with both
-- full the rest lands on the ground beside the pad as items on the ground.
return function(api)
  local M = {}
  -- (d24 batch179) a journey is about 170 bytes serialized: 1000 a planet, about 170 KB each, under 1 MB for 5 planets.
  -- A copy of world n's save sent about 7 a minute up and down at Nauvis: about 2.4 h of Nauvis, more elsewhere.
  M.KEEP, M.OPEN_MAX, M.OPEN_TICKS = 1000, 256, 36000
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function store()
    local s = api.state()
    s.podlog = s.podlog or {seq=0, by={}, open={}}
    return s.podlog
  end
  local MAIN, TRASH = 1, 2  -- defines.inventory.cargo_landing_pad_main, cargo_landing_pad_trash
  local function contents(pod)
    local inv = try(function() return pod.get_inventory(defines.inventory.cargo_unit) end)
    local out, any = {}, false
    for _, st in ipairs(inv and try(function() return inv.get_contents() end) or {}) do
      local q = type(st.quality) == 'table' and st.quality.name or st.quality
      local key = st.name .. (q and q ~= 'normal' and '@' .. q or '')
      out[key] = (out[key] or 0) + st.count
      any = true
    end
    return any and out or nil
  end
  local function find(st, open)
    local list = open and st.by[open.planet]
    for i = #(list or {}), 1, -1 do
      local r = list[i]
      if r.id == open.id then return r end
      if r.id < open.id then return nil end
    end
  end
  local function platform_of(e)
    local pl = e and try(function() return e.surface.platform end)
    return pl and pl.valid and pl or nil
  end
  local function at(pos) return string.format('(%g,%g)', math.floor(pos.x * 10 + 0.5) / 10, math.floor(pos.y * 10 + 0.5) / 10) end
  -- (d25 batch203 QP1, Sol #2331: native rockets could not be told apart by silo) a rocket's journey keeps the silo the
  -- game names: the launch event's rocket_silo, else the pod's cargo_pod_origin (a rocket-silo; on a copy of world n
  -- every launch, native ones too, raised on_rocket_launch_ordered with the silo, and the pod named it as its origin
  -- there and at on_cargo_pod_finished_ascending ~1650 ticks later). Never a silo found near the pod. silo_since: the
  -- tick this runtime began keeping silos; a rocket sent before it has silo unknown.
  local function set_silo(r, silo)
    if r.silo or not (silo and try(function() return silo.valid and silo.type == 'rocket-silo' and silo.unit_number end)) then return end
    r.silo, r.sx, r.sy = silo.unit_number, silo.position.x, silo.position.y
  end
  -- (d29 batch336 FL4, batch321: an import and launch ledger over the run; the journeys above keep the last KEEP a planet)
  -- Running totals per platform, counted once a journey's cargo is known: pods up to it (rockets) and down from its hub,
  -- with cargo by item (name@quality past normal; at most TOTAL_ITEMS names each, the rest summed as other) and the
  -- planets they came from or went to, since this runtime counted; and buckets for the windows: 10 game minutes (6
  -- kept), a game hour (10) and 10 game hours (25), each made when a pod comes in it. Bounded: at most TOTAL_PLATFORMS,
  -- the one quiet longest dropped.
  M.TOTAL_ITEMS, M.TOTAL_PLATFORMS = 48, 128
  local BUCKETS = {{size=36000, keep=6}, {size=216000, keep=10}, {size=2160000, keep=25}}
  local function add(side, items)
    side.pods = side.pods + 1
    for key, n in pairs(items) do
      if side.items[key] then side.items[key] = side.items[key] + n
      elseif side.n < M.TOTAL_ITEMS then side.items[key] = n; side.n = side.n + 1
      else side.other = side.other + n end
    end
  end
  local function new_side() return {pods=0, items={}, n=0, other=0} end
  local function count(r, planet, tick)
    if r.counted or not r.platform or not r.items then return end
    r.counted = true
    local st = store()
    st.totals = st.totals or {}
    local T = st.totals[r.platform]
    if not T then
      local n, quiet, qname = 0, nil, nil
      for name, t in pairs(st.totals) do n = n + 1; if not quiet or t.last < quiet then quiet, qname = t.last, name end end
      if n >= M.TOTAL_PLATFORMS and qname then st.totals[qname] = nil end
      T = {since=tick, last=tick, up=new_side(), down=new_side(), places={}, b={{}, {}, {}}}
      st.totals[r.platform] = T
    end
    T.last = tick
    local dir = r.up and 'up' or 'down'
    add(T[dir], r.items)
    T.places[dir .. ':' .. planet] = (T.places[dir .. ':' .. planet] or 0) + 1
    for i, spec in ipairs(BUCKETS) do
      local list = T.b[i]
      local start = tick - tick % spec.size
      local last = list[#list]
      if not (last and last.t == start) then
        last = {t=start, up=new_side(), down=new_side()}
        list[#list+1] = last
        while #list > spec.keep do table.remove(list, 1) end
      end
      add(last[dir], r.items)
    end
  end
  -- A pod leaving: its journey (once per pod; a later call adds what it knows). info: kind, by, drop, seen.
  function M.sent(pod, info, tick, silo)
    local unit = pod and pod.valid and pod.unit_number
    if not unit then return nil end
    local st = store()
    st.silo_since = st.silo_since or tick or game.tick
    local open = st.open[unit]
    local r = open and find(st, open)
    if r then
      -- the event's tick over a sampled one (pods.lua sees a pod waiting to launch, before the first pod event)
      if info and info.seen == 'event' and r.seen == 'sampled' then r.sent, r.seen = tick or game.tick, 'event' end
      for k, v in pairs(info or {}) do if r[k] == nil then r[k] = v end end
      if not r.items then r.items = contents(pod) end
      if r.up then set_silo(r, silo or try(function() return pod.cargo_pod_origin end)) end
      count(r, open.planet, r.sent or tick or game.tick)
      return r.id
    end
    local origin = try(function() return pod.cargo_pod_origin end)
    local d = try(function() return pod.cargo_pod_destination end)
    local station = d and d.station and try(function() return d.station.valid and d.station end)
    local up = origin and try(function() return origin.type == 'rocket-silo' end)
    local pl, planet, starter, orbit
    if up then
      pl = platform_of(station)
      -- (d26 batch229 SP, Sol: pod 46268167 read "vulcanus to nil, in flight" 5 min after it took Loom's pack to Aethera) a
      -- starter pack's pod goes to the platform it starts (no hub yet: no station), named by the destination
      local kind = d and try(function() return d.type end)
      local cd = defines.cargo_destination or {}
      if not pl and kind ~= nil and kind == cd.space_platform then
        pl = try(function() return d.space_platform.valid and d.space_platform end)
        starter = pl and true or nil
      elseif not pl and kind ~= nil and kind == cd.orbit then orbit = true end
      planet = try(function() return origin.surface.name end)
    else
      pl = platform_of(origin) or platform_of(pod)
      planet = station and try(function() return station.surface.name end)
        or d and try(function() return type(d.surface) == 'string' and d.surface or d.surface.name end)
    end
    if not planet then return nil end
    st.seq = st.seq + 1
    r = {id=st.seq, unit=unit, up=up or nil, platform=pl and pl.name, stop=pl and try(function() return pl.space_location.name end),
      sent=tick or game.tick, items=contents(pod), starter=starter, orbit=orbit}
    for k, v in pairs(info or {}) do r[k] = v end
    if up then set_silo(r, silo or origin) end
    count(r, planet, r.sent)
    local list = st.by[planet] or {}
    st.by[planet] = list
    list[#list+1] = r
    while #list > M.KEEP do table.remove(list, 1) end
    -- in flight: unit -> where its journey is; every 32nd send drops old ones (a pod removed with its platform)
    if r.id % 32 == 0 or not st.open_n then
      local n = 0
      for u, o in pairs(st.open) do
        if (tick or game.tick) - o.tick > M.OPEN_TICKS then st.open[u] = nil else n = n + 1 end
      end
      st.open_n = n
    end
    -- pod: checked once a second (M.sweep) until a landing closes the journey; pl: a starter pack's platform
    if st.open_n < M.OPEN_MAX then st.open[unit] = {planet=planet, id=r.id, tick=tick or game.tick, pod=pod, pl=starter and pl or nil}; st.open_n = st.open_n + 1 end
    return r.id
  end
  local function pad_state(pad, items)
    local main = try(function() return pad.get_inventory(MAIN) end)
    local trash = try(function() return pad.get_inventory(TRASH) end)
    local counts = {}
    for key in pairs(items or {}) do
      local name, q = key:match('^([^@]+)@?(.*)$')
      local id = {name=name, quality=q ~= '' and q or 'normal'}
      counts[key] = (main and try(function() return main.get_item_count(id) end) or 0) + (trash and try(function() return trash.get_item_count(id) end) or 0)
    end
    return {main=main and main.count_empty_stacks() or 0, trash=trash and trash.count_empty_stacks() or 0}, counts
  end
  -- Landed: where, and at a pad its free slots (main, trash) and its counts of the pod's items.
  local function landed(pod, tick)
    local st = store()
    local open = st.open[pod.unit_number]
    local r = find(st, open)
    if not r then return end
    r.landed = tick
    r.seen = 'event'
    if not r.items then r.items = contents(pod) end
    local d = try(function() return pod.cargo_pod_destination end)
    local station = d and d.station and try(function() return d.station.valid and d.station end)
    if station and station.type == 'cargo-landing-pad' then
      r.dest = 'landing pad ' .. at(station.position)
      local free, counts = pad_state(station, r.items)
      r.free = free
      open.pad, open.counts = station, counts
    elseif station then
      r.dest = 'hub'
    else
      r.dest = 'ground ' .. at(pod.position)
    end
  end
  -- Delivered: the pad takes the items (or the ground container appears) the tick after on_cargo_pod_delivered_cargo
  -- (the copy, 2.0.77: trash 20 free at the event, 19 the next tick), so it is read then (M.tick).
  local function delivered(pod)
    local st = store()
    local unit = pod.unit_number
    local open = st.open[unit]
    if open then st.open[unit] = nil; st.open_n = math.max(0, (st.open_n or 1) - 1) end
    local r = open and find(st, open)
    if not r then return end
    -- (d26 batch229 SP) no on_cargo_pod_finished_descending came: a starter pack's pod delivers in the tick its platform
    -- starts (its hub built; the copy, 2.0.77: ~27.5 s after launch, the pod gone the next tick)
    if not r.landed then
      r.landed, r.seen = game.tick, 'event'
      if r.starter and r.platform then r.dest = 'platform ' .. r.platform .. ' (its starter pack: the platform starts, its hub built)' end
    end
    open.tick, open.surface, open.position = game.tick, pod.surface, {x=pod.position.x, y=pod.position.y}
    st.after = st.after or {}
    st.after[unit] = open
  end
  -- At a pad: its free slots after, and what it did not take (counted only when no slot is left); on the ground: the
  -- cargo-pod-container it became. (d25 batch207 QT1) delivered: this tick, the pad (or container) holding the cargo;
  -- delivery_watch sees the pod gone on the same tick.
  local function after(st, open, tick)
    local r = find(st, open)
    if not r then return end
    r.delivered = tick
    local pad = open.pad
    if pad and pad.valid and r.items then
      local free, counts = pad_state(pad, r.items)
      r.free_after = free
      if free.main == 0 and free.trash == 0 then
        local short = 0
        for key, n in pairs(r.items) do short = short + math.max(0, n - math.max(0, (counts[key] or 0) - ((open.counts or {})[key] or 0))) end
        if short > 0 then r.ground = short end
      end
    elseif r.dest and r.dest:find('^ground') then
      local box = try(function() return open.surface.find_entities_filtered{name='cargo-pod-container', position=open.position, radius=4, limit=1}[1] end)
      if box then r.dest = 'ground ' .. at(box.position) .. ' (cargo-pod-container)' end
    end
  end
  -- (d26 batch229 SP) a journey whose pod is gone with no landing event: a starter pack's pod (its platform starts:
  -- its hub built), else gone (r.gone, the tick it was found gone; a pod sent to orbit is removed there with its cargo,
  -- the copy, 2.0.77). A journey open before this runtime kept its pod takes it from its next pod event (no lookup:
  -- game.get_entity_by_unit_number finds no cargo pod in 2.0.77), else ends as before (OPEN_TICKS).
  local function close_gone(st, unit, open, tick)
    st.open[unit] = nil; st.open_n = math.max(0, (st.open_n or 1) - 1)
    local r = find(st, open)
    if not r or r.landed then return end
    local pl = open.pl
    if r.starter and pl and try(function() return pl.valid and pl.hub and pl.hub.valid end) then
      r.landed, r.delivered, r.dest = tick, tick, 'platform ' .. pl.name .. ' (its starter pack: the platform starts, its hub built)'
    else
      r.gone = tick
      if r.starter then r.gone_state = pl and try(function() return pl.valid and M.STATES[pl.state] end) or 'its platform is gone' end
    end
  end
  M.STATES = {}
  for k, v in pairs(defines and defines.space_platform_state or {}) do M.STATES[v] = k end
  function M.sweep(tick)
    local st = api.state().podlog
    if not (st and st.open) then return end
    for unit, open in pairs(st.open) do
      local pod = open.pod
      if pod ~= nil and not pod.valid then close_gone(st, unit, open, tick) end
    end
  end
  -- The deliveries read the tick after (the runtime's tick calls it only while one waits); every SWEEP ticks while a
  -- journey is open, its pod checked (M.sweep).
  M.SWEEP = 60
  function M.tick(tick)
    local st = api.state().podlog
    local a = st and st.after or {}
    for unit, open in pairs(a) do
      if tick > open.tick then a[unit] = nil; pcall(after, st, open, tick) end
    end
    if tick % M.SWEEP == 0 then M.sweep(tick) end
  end
  M.EVENTS = {}
  local E = defines and defines.events or {}
  for _, n in ipairs({'on_cargo_pod_started_ascending', 'on_cargo_pod_finished_ascending', 'on_cargo_pod_finished_descending', 'on_cargo_pod_delivered_cargo'}) do
    if E[n] then M.EVENTS[E[n]] = n end
  end
  function M.on_event(event)
    local n = M.EVENTS[event.name]
    local pod = event.cargo_pod
    if not (n and pod and pod.valid) then return end
    local st = store()
    st.events = true
    local o = st.open[pod.unit_number]
    if o and o.pod == nil then o.pod = pod end
    -- (QT1) journeys landed before this runtime kept delivery ticks count by their land tick (landed_from)
    st.delivered_since = st.delivered_since or event.tick
    if n == 'on_cargo_pod_started_ascending' then M.sent(pod, {seen='event'}, event.tick)
    elseif n == 'on_cargo_pod_finished_ascending' then
      if not st.open[pod.unit_number] then M.sent(pod, {seen='event'}, event.tick) end
    elseif n == 'on_cargo_pod_finished_descending' then landed(pod, event.tick)
    else delivered(pod) end
  end
  -- A rocket's pod (on_rocket_launch_ordered, forwarded since d18).
  function M.on_launch(event)
    local pod = try(function() return event.rocket.attached_cargo_pod end)
    if pod then return M.sent(pod, {kind='rocket', by=event.player_index and try(function() return game.get_player(event.player_index).name end) or nil}, event.tick, event.rocket_silo) end
  end
  -- (no pod events forwarded) pods.lua's read: a hub's pod seen leaving, and gone
  function M.sampled(pod, tick)
    if store().events then return end
    return M.sent(pod, {seen='sampled'}, tick)
  end
  -- pad: the landing pad pods.lua read for it (the planet's pad, where a platform's pods land), or nil
  function M.gone(unit, tick, pad)
    local st = store()
    if st.events then return end
    local open = st.open[unit]
    local r = find(st, open)
    if open then st.open[unit] = nil; st.open_n = math.max(0, (st.open_n or 1) - 1) end
    if r and not r.landed then
      r.landed, r.delivered, r.seen = tick, tick, 'sampled'
      if pad then r.dest = 'landing pad ' .. at(pad) end
    end
  end

  -- (d28 batch320 LP) what is on the way up to a platform now: each rocket pod sent to it from a silo and not landed yet
  -- (in flight or rising), counted by item key (name or name@quality); with item, that item's count only.
  function M.on_the_way(platform, item)
    local st = store()
    local n, rockets = 0, 0
    for _, open in pairs(st.open) do
      local r = find(st, open)
      if r and r.up and r.platform == platform and not r.landed and r.items then
        local c = item and (r.items[item] or 0) or 0
        if not item then for _, v in pairs(r.items) do c = c + v end end
        if c > 0 then n, rockets = n + c, rockets + 1 end
      end
    end
    return n, rockets
  end

  -- (d25 batch201 QN3, Sol #2328) an item's counted arrivals and departures on a planet over (from, to]: what pods
  -- landed (by land tick) and what rockets' pods took up (by send tick), every quality; complete false when the log's
  -- oldest kept journey is after from (the list keeps the last KEEP).
  function M.counted(planet, item, from, to)
    local list = store().by[planet] or {}
    local prefix = item .. '@'
    local out = {landed=0, landed_pods=0, sent_up=0, sent_pods=0, complete=#list < M.KEEP or (list[1] and list[1].sent <= from) or false}
    for i = #list, 1, -1 do
      local r = list[i]
      local n = 0
      for k, v in pairs(r.items or {}) do if k == item or string.find(k, prefix, 1, true) == 1 then n = n + v end end
      if n > 0 then
        if r.up then
          if r.sent > from and r.sent <= to then out.sent_up, out.sent_pods = out.sent_up + n, out.sent_pods + 1 end
        elseif r.landed and r.landed > from and r.landed <= to then out.landed, out.landed_pods = out.landed + n, out.landed_pods + 1 end
      end
      -- sent in send order: one sent long enough before from that it landed before it ends the walk
      if r.sent < from - M.OPEN_TICKS then break end
    end
    return out
  end
  -- (d25 batch205 QR1, Sol #2337) pods sent down from a platform delivered after since, on every planet: pods, and with
  -- item how many of it (quality: that one; nil: every quality); last, the newest delivered; complete false when a
  -- planet's list is full and its oldest kept journey was sent after since (earlier ones dropped).
  -- (d25 batch207 QT1, Sol #2344: plan14's 750 magazines counted at the land tick 62193645, delivery_watch saw the pod
  -- received at 62193727) a pod counts at its delivery tick (r.delivered: the pad or container holds the cargo), about
  -- 80 ticks after it lands; landing: pods landed after since whose cargo is not delivered yet. A journey that landed
  -- before this runtime kept delivery ticks (delivered_since) counts at its land tick.
  -- (d27 batch259 PL, Astra #2484: a 700-magazine drop to the wrong planet met a wait meant for Aquilo) planet: only
  -- pods landed there count; those landed elsewhere are summed by planet in out.elsewhere ({planet: pods})
  function M.landed_from(platform, since, item, quality, only)
    local out = {pods=0, items=0, landing=0, complete=true}
    local key = item and (quality and quality ~= 'normal' and item .. '@' .. quality or item)
    local prefix = item and not quality and item .. '@' or nil
    local st = store()
    local old = st.delivered_since or math.huge
    for planet, list in pairs(st.by) do
      if #list >= M.KEEP and list[1] and list[1].sent > since then out.complete = false; out.oldest = math.min(out.oldest or list[1].sent, list[1].sent) end
      for i = #list, 1, -1 do
        local r = list[i]
        if r.sent < since - M.OPEN_TICKS then break end
        local got = r.delivered or (r.landed and r.landed < old and r.landed)
        if not r.up and r.platform == platform and r.landed and (got or r.landed) > since then
          local n = 1
          if item then
            n = 0
            for k, v in pairs(r.items or {}) do if k == key or (prefix and string.find(k, prefix, 1, true) == 1) then n = n + v end end
          end
          if n > 0 and only and planet ~= only then
            if got then out.elsewhere = out.elsewhere or {}; out.elsewhere[planet] = (out.elsewhere[planet] or 0) + 1 end
          elseif n > 0 and not got then out.landing = out.landing + 1
          elseif n > 0 then
            out.pods, out.items = out.pods + 1, out.items + (item and n or 0)
            if not out.last or got > out.last.delivered then out.last = {landed=r.landed, delivered=got, dest=r.dest, planet=planet, id=r.id} end
          end
        end
      end
    end
    return out
  end
  local function items_text(t)
    local list = {}
    for k, v in pairs(t or {}) do list[#list+1] = {k=k, v=v} end
    table.sort(list, function(x, y) return x.v > y.v or (x.v == y.v and x.k < y.k) end)
    local parts = {}
    for i, x in ipairs(list) do
      if i > 8 then parts[#parts+1] = '+' .. (#list - 8) .. ' more'; break end
      parts[#parts+1] = x.k .. '*' .. x.v
    end
    return #parts > 0 and table.concat(parts, ' ') or 'contents not read'
  end
  -- item: name@quality (that quality), or a name (any quality; prefix: name .. '@')
  local function has_item(r, item, prefix)
    local t = r.items
    if not t then return false end
    if t[item] then return true end
    if prefix then for k in pairs(t) do if string.find(k, prefix, 1, true) == 1 then return true end end end
    return false
  end
  local function ago(t)
    local sec = math.floor(t / 60)
    if sec >= 3600 then return string.format('%dh%02dm', math.floor(sec / 3600), math.floor(sec / 60) % 60) end
    if sec >= 60 then return string.format('%dm%02ds', math.floor(sec / 60), sec % 60) end
    return sec .. 's'
  end
  local function kind_text(r)
    if r.up then return 'rocket' .. (r.by and ' (launched by ' .. r.by .. ')' or '') end
    if r.kind == 'drop' then return 'drop #' .. tostring(r.drop) .. (r.by and ' by ' .. r.by or '') end
    return 'sent by the hub (landing pad requests or hub trash)'
  end
  local function slots(f) return f and string.format('main %d, trash %d', f.main, f.trash) or nil end
  -- Journeys on planet surfaces (surfaces: a set, nil for all), oldest first, filtered: up (true: up, false: down, nil:
  -- both), platform, item (a name, any quality, or name@quality), from and to (send ticks); the newest limit of them.
  -- The totals for one platform or all (most pods first): {platform, since_tick, up, down, from, to, windows}. A window
  -- adds the buckets that start inside it, so it covers its length less up to one bucket (from_tick says where it starts).
  local WINDOWS = {{'1h', 1, 216000}, {'10h', 2, 2160000}, {'50h', 3, 10800000}, {'250h', 3, 54000000}}
  local function side_text(side, max)
    local list = {}
    for key, n in pairs(side.items) do list[#list+1] = {key, n} end
    table.sort(list, function(x, y) if x[2] ~= y[2] then return x[2] > y[2] end return x[1] < y[1] end)
    local out = {}
    for i = 1, math.min(#list, max) do out[i] = list[i][1] .. '*' .. list[i][2] end
    if #list > max then out[#out+1] = string.format('+%d more names', #list - max) end
    if side.other > 0 then out[#out+1] = string.format('other %d (past %d names)', side.other, M.TOTAL_ITEMS) end
    return table.concat(out, ', ')
  end
  function M.totals(platform, now)
    now = now or game.tick
    local out = {}
    for name, T in pairs(store().totals or {}) do
      if not platform or name == platform then
        local places = {from={}, to={}}
        for k, n in pairs(T.places) do
          local dir, planet = k:match('^(%a+):(.*)$')
          local t = dir == 'up' and places.from or places.to
          t[#t+1] = planet .. ' ' .. n
        end
        table.sort(places.from); table.sort(places.to)
        local windows = {}
        for _, w in ipairs(WINDOWS) do
          local up, down, from = new_side(), new_side(), nil
          for _, b in ipairs(T.b[w[2]]) do
            if b.t >= now - w[3] then
              from = from or b.t
              up.pods = up.pods + b.up.pods; down.pods = down.pods + b.down.pods
              for _, pair in ipairs({{up, b.up}, {down, b.down}}) do
                for key, n in pairs(pair[2].items) do pair[1].items[key] = (pair[1].items[key] or 0) + n end
                pair[1].other = pair[1].other + pair[2].other
              end
            end
          end
          windows[#windows+1] = {window=w[1], from_tick=from, up_pods=up.pods, down_pods=down.pods,
            up_items=up.pods > 0 and side_text(up, 12) or nil, down_items=down.pods > 0 and side_text(down, 12) or nil}
        end
        out[#out+1] = {platform=name, since_tick=T.since, last_tick=T.last, up_pods=T.up.pods, down_pods=T.down.pods,
          up_items=T.up.pods > 0 and side_text(T.up, 24) or nil, down_items=T.down.pods > 0 and side_text(T.down, 24) or nil,
          from=#places.from > 0 and table.concat(places.from, ', ') or nil, to=#places.to > 0 and table.concat(places.to, ', ') or nil,
          windows=windows}
      end
    end
    table.sort(out, function(x, y) local a, b = x.up_pods + x.down_pods, y.up_pods + y.down_pods; if a ~= b then return a > b end return x.platform < y.platform end)
    return out
  end
  function M.read(f)
    local rows, total = {}, 0
    local planets = {}
    for planet in pairs(store().by) do if not f.surfaces or f.surfaces[planet] then planets[#planets+1] = planet end end
    table.sort(planets)
    -- every match counted; the newest limit of each planet (its list in send order) kept, then the newest limit of those
    local all = {}
    local prefix = f.item and not f.item:find('@', 1, true) and f.item .. '@' or nil
    for _, planet in ipairs(planets) do
      local list, kept = store().by[planet], 0
      for i = #list, 1, -1 do
        local r = list[i]
        if (f.up == nil or (r.up == true) == f.up) and (not f.platform or r.platform == f.platform) and (not f.item or has_item(r, f.item, prefix))
          and (not f.silo or r.silo == f.silo)
          and (not f.from or r.sent >= f.from) and (not f.to or r.sent <= f.to) then
          total = total + 1
          if kept < f.limit then kept = kept + 1; all[#all+1] = {r=r, planet=planet} end
        end
      end
    end
    table.sort(all, function(x, y) return x.r.sent < y.r.sent or (x.r.sent == y.r.sent and x.r.id < y.r.id) end)
    local since = store().silo_since
    for i = math.max(1, #all - f.limit + 1), #all do
      local r, planet = all[i].r, all[i].planet
      -- (d26 batch229 SP) up: the platform, a starter pack's platform, orbit, or not read
      local up_to = r.platform and (r.platform .. (r.starter and ' (its starter pack)' or '')) or (r.orbit and 'orbit') or 'a destination not read'
      local from, to = r.up and planet or tostring(r.platform), r.up and up_to or planet
      -- a journey delivered with no landing recorded (before batch229: a starter pack's pod) landed when delivered
      local landed = r.landed or r.delivered
      local flying = not landed and not r.gone
      local silo, silo_text
      if r.up then
        if r.silo then
          silo = {unit_number=r.silo, surface=planet, position={x=r.sx, y=r.sy}}
          silo_text = string.format('from silo %d %s', r.silo, at({x=r.sx, y=r.sy}))
        elseif since and r.sent >= since then silo, silo_text = 'not read', 'silo not read (the game named none for this pod)'
        else silo, silo_text = 'unknown', 'silo unknown (sent before the ledger kept silos)' end
      end
      rows[#rows+1] = {id=r.id, pod=r.unit, direction=r.up and 'up' or 'down', silo=silo, platform=r.platform, stop=r.stop, surface=planet,
        sent_tick=r.sent, landed_tick=landed, gone_tick=r.gone, starter_pack=r.starter, destination=r.dest, items=items_text(r.items), by=r.kind == 'drop' and r.by or nil,
        pad_free_before=slots(r.free), pad_free_after=slots(r.free_after), ground=r.ground,
        line=string.format('%s #%d, pod %d, %s ago: %s to %s%s, %s, %s%s; %s', r.up and 'up' or 'down', r.id, r.unit, ago(game.tick - r.sent), from, to,
          not r.up and r.stop and ' (at ' .. r.stop .. ')' or '', items_text(r.items), kind_text(r), silo_text and ' ' .. silo_text or '',
          flying and (game.tick - r.sent > M.OPEN_TICKS and 'no landing recorded' or 'in flight')
            or r.gone and string.format('pod gone by tick %d, %ds after it was sent, no landing recorded%s', r.gone, math.floor((r.gone - r.sent) / 60),
              r.gone_state and '; ' .. tostring(r.platform) .. ' reads ' .. r.gone_state or r.orbit and ' (a pod sent to orbit is removed there with its cargo)' or '')
            or string.format('landed %s after %ds%s', r.dest and 'in ' .. r.dest or '(where not read)', math.floor((landed - r.sent) / 60), r.seen == 'sampled' and ' (to the second)' or '')
            .. (r.free and string.format('; the pad\'s free slots %s before, %s after', slots(r.free), r.free_after and slots(r.free_after) or '?') or '')
            .. (r.ground and string.format('; %d did not fit in the pad and landed on the ground beside it', r.ground) or ''))}
    end
    return rows, total
  end
  return M
end
