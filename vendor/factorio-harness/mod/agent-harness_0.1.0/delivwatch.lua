-- delivery_watch {item, count, to, deadline_min, from?} (d21 batch66 AB5, viewer Aurora 13:02: "Could delivery watches
-- follow cargo to a named consumer, with a deadline, last confirmed stage, blocker and recovery alert? K2's carbide
-- landed in a different network from its silo."). What the reads tracked before it: shipment (a hub request's state on
-- its way up: delivered, in flight, launched, loading, or waiting with the silo's flag; what a planet's pads ask of the
-- hub), freight (each rocket launched to a platform; each cargo pod from a hub to the pad that received it, or to the
-- ground), pods and landed (pods in the sky, containers on the ground), drops (one drop's pod to its container) and
-- freight_audit (one item's stock over planets and platforms). None followed a count of an item to the chest, silo or
-- machine that uses it, nor said where it stopped.
-- A watch: an item, a count, the consumer (an entity of ours at a position, on a planet or a platform, in a chunk our
-- force has charted) and a deadline; the source (a platform, or a planet) optional. Once a second, PER_PASS watches a
-- pass, each reads what a player sees and keeps the first tick of each stage seen:
-- - down (the consumer on a planet): loaded (a platform's hub holds the item: the source, else the first platform seen
--   with it whose schedule stops at that planet), departed (that platform flying), in_transit (flying to that planet),
--   arrived (stopped there), landed (its cargo pod with the item received by a landing pad, which one, or landed with no
--   pad), network (the pad's logistic network and the consumer's), reached (the consumer holds count more than when the
--   watch was set);
-- - up (the consumer on a platform): loaded (a silo of the source planet with the item in its rocket, by the census
--   pass's list of silos), launched and in_transit (a rocket with it launched to that platform, its pod on the way),
--   landed (the hub holds more of it than when the watch was set), reached.
-- Blockers seen: the pad's network is not the consumer's, or the consumer is in no network; a pod with it landed with no
-- pad; the platform stopped there with it while no landing pad there has room for it (or there is none); the platform paused away from the planet (stopped there paused, its hub still sends pods down: what goes down now is read), or its schedule not stopping at the planet; a requester or buffer chest consumer asking
-- none of the item; the consumer gone. The setter hears in team.alerts each blocker once, a blocker gone, the deadline
-- passed while not reached (the last confirmed stage and the blocker), and the arrival. A watch is kept KEEP ticks
-- after it ends; at most MAX open a force.
-- (d21 batch66 AB6, Aurora 16:02: "Nauvis's obsolete CF500 request diverted K2 cargo intended for Aquilo before it
-- reached the named consumer") down, while the carrier's hub holds the item: a landing pad of ours asking it on a planet
-- the platform stops at before the destination (pad, its request and count, which stop) is a blocker while it is
-- stopped there and a risk before (the setter told once each), unless the hub's own request keeps all it holds; a pod
-- of it received by a pad (or landed) on another planet is a diversion, kept with the pad's request then.
-- (d21 batch66 AB7) each pod with the item (from the carrier's hub, or a rocket launched to the platform) is followed to
-- the tick it is gone: arrivals keep its count and spoilage then, and the receiving inventory's on that tick (below).
-- (d22 batch107 BQ1, Sol #1950: watch #75, 10000 copper plate to a landing pad on Fulgora that robots empty, read late
-- with all 10 pods of 1000 received; the pad held 5602 at most) received: a running total of the pods the consumer
-- received since the watch was set (count, pods), kept apart from the last 16 arrivals; a watch whose total reaches
-- count is complete by receipt (state received), and the stock test (reached) stays its own fact.
-- (d24 batch146 PR1, Sol #2152: watch #305, 1 calcite from Needle to Nauvis's pad, ended reached when another carrier's
-- pod of 60 landed, received 0, and stopped counting while Needle's 8 pods brought 32) with from, the watch ends only
-- when its count is received from that source; the stock test stays its own field and line and never ends it. With
-- none, either test ends it (batch134), and ended_by says which. After it ends it keeps counting pods until its
-- deadline (or a clear): later pods add to received and by_platform ("reached at tick T; still counting").
return function(api)
  local M = {}
  local EVERY, PER_PASS, KEEP, MAX, EVENTS = 60, 4, 36000, 16, 64
  M.ORDER = {'loaded', 'launched', 'departed', 'in_transit', 'arrived', 'landed', 'network', 'received', 'reached'}
  local RANK = {}
  for i, s in ipairs(M.ORDER) do RANK[s] = i end
  local CONSUMERS = {'rocket-silo', 'container', 'logistic-container', 'assembling-machine', 'furnace', 'lab', 'cargo-landing-pad',
    'space-platform-hub', 'ammo-turret', 'artillery-turret', 'reactor', 'boiler', 'burner-generator', 'cargo-wagon', 'car', 'spider-vehicle',
    'agricultural-tower', 'mining-drill', 'inserter'}
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  -- (d24 batch167 QJ1, Sol #2224: watch 331, a pod of 2 legendary thrusters landed at Aquilo's pad; the landed stage said
  -- 2 while received, pods and arrivals read 0) In 2.0.77 get_item_count(name) counts normal quality only, and freight's
  -- cargo by name counts every quality together, so the pod was never followed while freight's receipt landed it. A
  -- watch's quality (quality, or item "name@quality") counts that one; with none, every quality, said in its line.
  -- Every count of the watch goes through count_q (an entity or inventory) and amount (a pod's or rocket's cargo).
  local QS
  local function qualities()
    if QS then return QS end
    local list = {}
    for name, q in pairs(try(function() return prototypes.quality end) or {}) do
      if name ~= 'quality-unknown' and not try(function() return q.hidden end) then list[#list+1] = {name=name, level=try(function() return q.level end) or 0} end
    end
    table.sort(list, function(x, y) if x.level ~= y.level then return x.level < y.level end return x.name < y.name end)
    QS = {}
    for i, x in ipairs(list) do QS[i] = x.name end
    return QS
  end
  function M.reset_qualities() QS = nil end
  local function count_q(obj, item, q)
    if not obj then return 0 end
    local qs = qualities()
    -- no quality but normal in the game: the name alone is every quality
    if not q and (#qs == 0 or (#qs == 1 and qs[1] == 'normal')) then return try(function() return obj.get_item_count(item) end) or 0 end
    if q then return try(function() return obj.get_item_count({name=item, quality=q}) end) or 0 end
    -- an inventory counts every quality in one call (a copy of world n: 0.7 us, the 5 counts 5.6 us); an entity has no
    -- filtered count
    local filtered = try(function() return obj.get_item_count_filtered end)
    local all = filtered and try(function() return filtered({name=item}) end)
    if all then return all end
    local n = 0
    for _, x in ipairs(qs) do n = n + (try(function() return obj.get_item_count({name=item, quality=x}) end) or 0) end
    return n
  end
  -- a pod's or rocket's cargo record (freight.lua: cargo by name, every quality together; cargo_q by name@quality)
  local function amount(r, item, q)
    if not q then return r.cargo and r.cargo[item] end
    if r.cargo_q then return r.cargo_q[item .. '@' .. q] or 0 end
    return nil
  end
  local function label(w) return w.quality and w.item .. '@' .. w.quality or w.item end
  local function rule(w) return w.quality and string.format('%s quality only', w.quality) or 'every quality (no quality given)' end
  -- a stack's quality name, a filter's quality name (normal when none)
  local function qname(x) return type(x) == 'table' and x.name or x or 'normal' end
  local function at(q) return string.format('(%g,%g)', q.x, q.y) end
  local function secs(t)
    local s = math.max(0, math.floor(t / 60 + 0.5))
    return s >= 60 and string.format('%dm%02ds', math.floor(s / 60), s % 60) or s .. 's'
  end
  local function store()
    local s = api.state()
    s.delivwatch = s.delivwatch or {seq=0, list={}, events={}, eseq=0, rr=0}
    return s.delivwatch
  end
  -- (d24 batch154, the batch149 review's bug 7: "no delivery watch #N" after the 10-min drop) the last GONE_KEPT watches
  -- dropped or cleared, for a read of the id: when it ended and when it was dropped, and the keep rule.
  local GONE_KEPT = 64
  local KEEP_RULE = 'a watch is kept 10 minutes after it ends (received or reached), or 10 minutes past its deadline while late; clear ends it at once'
  local function gone(w, why, tick, by)
    local st = store()
    st.gone = st.gone or {}
    st.gone[#st.gone+1] = {id=w.id, item=label(w), setter=w.setter, state=w.state, why=why, by=by,
      ended=w.ended or (w.state == 'late' and w.deadline) or nil, tick=tick}
    while #st.gone > GONE_KEPT do table.remove(st.gone, 1) end
  end
  local function missing(id)
    local st = store()
    local head = 'no delivery watch #' .. tostring(id)
    for i = #(st.gone or {}), 1, -1 do
      local x = st.gone[i]
      if x.id == id then
        local ended = x.ended and string.format('%s at tick %d (%s ago), ', x.state == 'late' and 'its deadline passed' or 'it ended ' .. tostring(x.state), x.ended, secs(game.tick - x.ended)) or ''
        return string.format('%s: #%d (%s, set by %s): %s%s at tick %d (%s ago); %s', head, x.id, tostring(x.item), tostring(x.setter), ended,
          x.why == 'cleared' and 'cleared by ' .. tostring(x.by) or 'dropped', x.tick, secs(game.tick - x.tick), KEEP_RULE)
      end
    end
    if type(id) == 'number' and (id > st.seq or id < 1) then return string.format('%s: none set with that number (the last set is #%d)', head, st.seq) end
    return string.format('%s: set and since dropped, before the last %d dropped watches kept; %s', head, GONE_KEPT, KEEP_RULE)
  end
  local function push(w, text)
    local st = store()
    st.eseq = st.eseq + 1
    st.events[#st.events+1] = {id=st.eseq, to=w.setter, index=w.index, text=text}
    while #st.events > EVENTS do table.remove(st.events, 1) end
  end
  local function platform_named(force, name)
    for _, pl in pairs(try(function() return force.platforms end) or {}) do if pl.valid and pl.name == name then return pl end end
  end
  local function hub_count(pl, item, q)
    local inv = try(function() return pl.hub.get_inventory(defines.inventory.hub_main) end)
    return inv and count_q(inv, item, q) or 0
  end
  -- (d24 batch192 QAH1) the watched quality, or with none given the hub's counts of the item by quality: a hub
  -- section's max is for its own quality (freight.lua hub_keeps_at)
  local function hub_q(F, pl, w)
    if w.quality then return w.quality end
    return F.by_item and (F.by_item(try(function() return F.hub_counts(pl, true) end)) or {})[w.item] or nil
  end
  local function stops_at(pl, planet)
    for _, r in ipairs(try(function() return pl.schedule.records end) or {}) do if r.station == planet then return true end end
    return false
  end
  local function network_of(e)
    local net = try(function() return e.surface.find_logistic_network_by_position(e.position, e.force) end)
    return net and try(function() return net.network_id end) or nil
  end
  local function same(a, b)
    return a == b or (try(function() return a.unit_number end) ~= nil and try(function() return a.unit_number end) == try(function() return b.unit_number end))
  end
  -- (BQ1) What counts as received by the consumer: a landing pad, the pods that pad received; a platform's hub, or a
  -- consumer aboard a platform, the pods its hub received; a chest, silo or machine on a planet, the pods received by
  -- a landing pad in the consumer's logistic network on the tick each landed (robots carry it on from there).
  local function recv_info(w)
    if w.recv_by then return end
    local kind = try(function() return w.consumer.type end) or w.to.name
    if kind == 'cargo-landing-pad' then
      w.recv_kind, w.recv_by = 'pad', string.format('%s %s on %s', w.to.name, at(w.to.position), w.to.where)
    elseif w.direction == 'up' then
      w.recv_kind, w.recv_by = 'hub', string.format('%s\'s hub', tostring(w.to_platform))
    else
      w.recv_kind, w.recv_by = 'network', 'landing pads in the consumer\'s logistic network'
    end
  end
  -- (d20 batch134 PF1) the platforms the received pods came from: "Solstice 365, Kestrel IVa 150"
  local function by_platform_text(w)
    local list = {}
    for name, n in pairs(w.received_by or {}) do list[#list+1] = {name, n} end
    table.sort(list, function(a, b) if a[2] ~= b[2] then return a[2] > b[2] end return a[1] < b[1] end)
    for i, x in ipairs(list) do list[i] = x[1] .. ' ' .. x[2] end
    return #list > 0 and table.concat(list, ', ') or nil
  end
  local function received_text(w)
    local from = not w.from and by_platform_text(w)
    return string.format('received %d of %d in %d pod%s by %s since the watch was set%s%s', w.received or 0, w.count, w.received_pods or 0, w.received_pods == 1 and '' or 's', w.recv_by,
      from and ' (from ' .. from .. ')' or '', w.received_tick and ', the last at tick ' .. w.received_tick or '')
  end
  -- A requester or buffer chest asking none of the item: the text, else nil.
  local function asks_none(e, item, q)
    if e.type ~= 'logistic-container' then return nil end
    local mode = try(function() return e.prototype.logistic_mode end)
    if mode ~= 'requester' and mode ~= 'buffer' then return nil end
    local secs_ = try(function() return e.get_logistic_sections() end)
    for i = 1, secs_ and secs_.sections_count or 0 do
      local sec = secs_.get_section(i)
      if sec.active ~= false then
        for _, f in ipairs(sec.filters or {}) do
          local v = f.value
          if (type(v) == 'table' and v.name or v) == item and (f.min or 0) > 0 and (not q or qname(type(v) == 'table' and v.quality) == q) then return nil end
        end
      end
    end
    return string.format('the consumer, %s chest %s, asks none of %s: robots bring it nothing', mode, at(e.position), q and item .. '@' .. q or item)
  end
  -- (AB6) A planet's landing pads of ours asking the item: {{pad, min, held}}, by their active sections as the pad shows
  -- them. 2.0.77 on the private copy: a platform paused at Fulgora with gears, cable and pipe in its hub sent pods of
  -- 20 to the pad's requests of 20 imported from nauvis, nauvis and fulgora alike, and again each time robots emptied
  -- the pad (its request counts what the pad holds): a pad request's import planet does not stop it.
  local function pad_asks(force, planet, item, q)
    local s = try(function() return game.planets[planet].surface end)
    local out = {}
    if not s then return out end
    local pads = api.census_typed and try(function() return api.census_typed(force, s, 'cargo-landing-pad') end)
      or try(function() return s.find_entities_filtered{type='cargo-landing-pad', force=force} end) or {}
    for _, pad in ipairs(pads) do
      local min, by = 0, {}
      local secs_ = try(function() return pad.get_logistic_sections() end)
      for i = 1, secs_ and secs_.sections_count or 0 do
        local sec = secs_.get_section(i)
        if sec and sec.active ~= false then
          for _, f in ipairs(sec.filters or {}) do
            local v = f.value
            local fq = qname(type(v) == 'table' and v.quality)
            if (type(v) == 'table' and v.name or v) == item and (f.min or 0) > 0 and (not q or fq == q) then min = min + f.min; by[fq] = (by[fq] or 0) + f.min end
          end
        end
      end
      if min > 0 then
        -- (d25 batch198 QK1) with no quality given, each quality's ask less what the pad holds of it: a pad's ask is
        -- for its own quality (freight.lua pads)
        local want_q
        if not q then
          want_q = {}
          for fq, m in pairs(by) do want_q[fq] = m - count_q(pad, item, fq) end
        end
        out[#out+1] = {pad=pad, min=min, held=count_q(pad, item, q), want_q=want_q}
      end
    end
    return out
  end
  -- (AB6) Where the platform stops from now until the destination's stop: {{index (its schedule record; nil when it
  -- is stopped at a planet that is not its current stop), station, now (stopped there now), off (d24 batch142 PN1: the
  -- record's unloading is off)}}.
  local function stops_before(pl, dest)
    local recs = try(function() return pl.schedule.records end) or {}
    local cur = try(function() return pl.schedule.current end) or 1
    local here = not try(function() return pl.space_connection end) and try(function() return pl.space_location.name end)
    local out = {}
    if here == dest then return out end
    if here and (not recs[cur] or recs[cur].station ~= here) then out[1] = {station=here, now=true} end
    for k = 0, #recs - 1 do
      local i = (cur - 1 + k) % #recs + 1
      local st = recs[i].station
      if st == dest then break end
      out[#out+1] = {index=i, station=st, now=(k == 0 and here == st), off=recs[i].allows_unloading == false}
    end
    return out
  end
  local function seen(w, stage, text, tick)
    if not w.stages[stage] then
      w.stages[stage] = {tick=tick, text=text}
      if not w.last or RANK[stage] > RANK[w.last] then w.last = stage end
    end
  end
  -- sig: what makes it new to the setter (default the text; a pad's count changing is not new)
  local function block(w, key, text, sig)
    w.now_blocks[key] = text
    w.now_sigs[key] = sig or text
  end
  local function risk(w, key, text, sig)
    w.now_risks[key] = text
    w.now_rsigs[key] = sig or text
  end
  -- The consumer's count now: the stock test.
  function M.held(w, held, tick)
    w.held = held
    if held - w.base >= w.count then
      seen(w, 'reached', string.format('%s %s holds %d %s (%d when the watch was set)', w.to.name, at(w.to.position), held, label(w), w.base), tick)
    end
  end
  -- (PR1) the stock test in words, apart from received
  local function stock_text(w)
    return string.format('the stock test: the consumer holds %d now (%d at the start), %s', w.held or w.base, w.base,
      w.stages.reached and string.format('seen holding %d more', w.count) or string.format('not seen holding %d more', w.count))
  end
  -- One watch read now (tick): stages seen, blockers now, its events.
  function M.check(w, tick)
    w.now_blocks, w.now_sigs, w.now_risks, w.now_rsigs = {}, {}, {}, {}
    recv_info(w)
    if w.received == nil then
      -- a watch set before the total was kept: its arrivals received by the consumer itself (a pad or hub; the last 16)
      w.received, w.received_pods = 0, 0
      for _, a in ipairs(w.arrivals or {}) do
        if w.recv_kind ~= 'network' and a.where == w.recv_by and a.tick >= w.start then
          a.received = true
          w.received, w.received_pods, w.received_tick = w.received + a.count, w.received_pods + 1, a.tick
        end
      end
      w.received_from = #(w.arrivals or {}) > 0 and 'arrivals' or nil
    end
    local e = w.consumer
    if not (e and e.valid) then
      block(w, 'gone', string.format('the consumer %s %s on %s is gone', w.to.name, at(w.to.position), w.to.where))
    else
      M.held(w, count_q(e, w.item, w.quality), tick)
      if w.from and w.stages.reached and not w.stock_told then
        w.stock_told = true
        push(w, string.format('delivery watch #%d (%d %s to %s %s on %s): %s; with from given this does not end the watch: it ends when %d is received from %s (%s)',
          w.id, w.count, label(w), w.to.name, at(w.to.position), w.to.where, stock_text(w), w.count, w.from, received_text(w)))
      end
      local ask = asks_none(e, w.item, w.quality)
      if ask then block(w, 'asks', ask) end
    end
    if w.direction == 'down' then
      local force = game.forces[w.force]
      local pl = w.carrier and platform_named(force, w.carrier)
      if not pl then
        local cands = {}
        if w.from then cands = {platform_named(force, w.from)} else for _, x in pairs(force.platforms) do cands[#cands+1] = x end end
        for _, x in ipairs(cands) do
          if x and x.valid and (w.from or stops_at(x, w.to.where)) and hub_count(x, w.item, w.quality) > 0 then pl = x; w.carrier = x.name; break end
        end
      end
      if pl and pl.valid then
        local n = hub_count(pl, w.item, w.quality)
        if n > 0 then seen(w, 'loaded', string.format('%s\'s hub holds %d %s', pl.name, n, label(w)), tick) end
        local where = api.freight and try(function() return api.freight.where(pl) end) or {}
        if try(function() return pl.space_connection end) then
          local leg = where.leg
          if w.stages.loaded then seen(w, 'departed', string.format('%s left %s', pl.name, leg and leg.from or '?'), tick) end
          if leg and leg.to == w.to.where then
            seen(w, 'in_transit', string.format('%s flying %s->%s (%d%% when first seen)', pl.name, leg.from, leg.to, math.floor((leg.flown or 0) * 100 + 0.5)), tick)
          end
        elseif try(function() return pl.space_location.name end) == w.to.where then
          seen(w, 'arrived', string.format('%s stopped at %s', pl.name, w.to.where), tick)
          -- stopped there with it aboard: a landing pad of ours there with room for it (the census pass's list of pads)
          local s = e and e.valid and e.surface or try(function() return game.planets[w.to.where].surface end)
          local pads = n > 0 and not w.stages.landed and s and api.census_typed and try(function() return api.census_typed(force, s, 'cargo-landing-pad') end)
          if pads then
            local room, names = false, {}
            for _, pad in ipairs(pads) do
              local inv = try(function() return pad.get_inventory(defines.inventory.cargo_landing_pad_main) end)
              if inv and try(function() return inv.can_insert({name=w.item, quality=w.quality, count=1}) end) then room = true end
              if #names < 3 then names[#names+1] = at(pad.position) end
            end
            if #pads == 0 then block(w, 'pad', string.format('no landing pad of ours on %s: a pod sent down lands on the ground', w.to.where))
            elseif not room then block(w, 'pad', string.format('no landing pad of ours on %s has room for %s (cargo-landing-pad %s): the hub sends no pod of it down', w.to.where, label(w), table.concat(names, ', '))) end
          end
        end
        -- (d24 batch139 PK1, Sol #2115: watch 284 said Petrel, paused while docked at Nauvis, goes nowhere until
        -- unpaused; its hub sends pods down while paused, as watch 283 saw 2000 land, and AB6's copy measured at
        -- Fulgora) paused is a blocker only away from the destination; stopped there, what goes down now is read
        local here = not try(function() return pl.space_connection end) and try(function() return pl.space_location.name end)
        w.at_destination = nil
        w.paused = pl.paused and string.format('%s is paused%s', pl.name, here and ' at ' .. here or ' in flight') or nil
        if pl.paused and here ~= w.to.where then
          block(w, 'paused', string.format('%s is paused%s: it goes nowhere until unpaused', pl.name, here and ' at ' .. here or ' in flight'))
        elseif here == w.to.where and n > 0 and api.freight and api.freight.hub_keeps_at then
          local F = api.freight
          local keeps = F.hub_keeps_at(try(function() return pl.hub.get_logistic_sections() end), w.to.where)
          local asks = pad_asks(force, w.to.where, w.item, w.quality)
          local want, parts, want_q = 0, {}, not w.quality and {} or nil
          for _, a in ipairs(asks) do
            want = want + math.max(0, a.min - a.held)
            for fq, x in pairs(a.want_q or {}) do want_q[fq] = (want_q[fq] or 0) + math.max(0, x) end
            parts[#parts+1] = string.format('the landing pad %s asks %d, holds %d', at(a.pad.position), a.min, a.held)
          end
          -- (d24 batch142 PN1) its stop there with unloading off: the pads take nothing, a finite max still sends down
          local off, off_line
          if F.no_unload then off, off_line = F.no_unload(pl, w.to.where) end
          local go, k = F.hub_gives(keeps, w.item, n, want_q or want, off, hub_q(F, pl, w))
          local why = k and k.ranged and F.keep_text(k)
            or off and (k and k.max ~= math.huge and string.format('%s; %s: all above %d goes down', off_line, F.keep_text(k), k.max) or off_line)
            or k and (k.max == math.huge and F.keep_text(k) .. ': an infinite max keeps it all'
              or string.format('%s: all above %d goes down, asked or not', F.keep_text(k), k.max))
            or #asks == 0 and string.format('no hub section keeps %s at %s and no landing pad of ours there asks it: it goes down as far as the pads ask', label(w), w.to.where)
            or string.format('no hub section keeps %s at %s: it goes down as far as the pads ask (%s)', label(w), w.to.where, table.concat(parts, '; '))
          local head = string.format('%s is stopped at %s%s with %d %s in its hub', pl.name, w.to.where,
            pl.paused and ' (paused: its hub sends pods down at the planet it is stopped at all the same)' or '', n, label(w))
          w.at_destination = {sends=go, held=n, asked=want, keep=k and F.keep_text(k) or nil,
            line=string.format('%s: its hub sends %d down now (%s)', head, go, why)}
          if go == 0 and not (k and k.ranged) then
            block(w, 'demand ' .. w.to.where, string.format('%s: none of it goes down now (%s)', head, why),
              'demand ' .. w.to.where .. ' ' .. (off and 'unloading off' or k and tostring(k.max) or (#asks == 0 and 'no pad' or 'asked')))
          end
        end
        if not stops_at(pl, w.to.where) then block(w, 'route', string.format('%s\'s schedule has no stop at %s', pl.name, w.to.where)) end
        -- (AB6, Aurora 16:02: "Nauvis's obsolete CF500 request diverted K2 cargo intended for Aquilo") a landing pad
        -- asking the item on a planet it stops at before the destination: a blocker while it is stopped there, a risk
        -- before; none when the hub's own request keeps all it holds
        -- (d24 batch137 PI1) what the hub gives up at each stop before the destination by its sections for that planet
        -- (freight.lua hub_keeps_at, hub_gives): a finite max sends down all above it there, a pad asking or not; an
        -- infinite max keeps it all
        if n > 0 and stops_at(pl, w.to.where) and api.freight and api.freight.hub_keeps_at then
          local F = api.freight
          local secs_ = try(function() return pl.hub.get_logistic_sections() end)
          local q = hub_q(F, pl, w)
          for _, stop in ipairs(stops_before(pl, w.to.where)) do
            local which = stop.index and 'stop ' .. stop.index .. ' of its schedule' or 'not a stop of its schedule'
            local keeps = F.hub_keeps_at(secs_, stop.station)
            local off = stop.off
            local asks = pad_asks(force, stop.station, w.item, w.quality)
            -- (QAH1) the rows of its quality only: a section's max is for its own quality
            local above, k = F.hub_gives(keeps, w.item, n, 0, false, q)
            if #asks == 0 and above > 0 then
              local key = 'demand ' .. stop.station .. ' max'
              local text = string.format('%s %s %s (%s) with %d %s in its hub, before %s: %s, so all above %d goes down there, a landing pad asking or not',
                pl.name, stop.now and 'is stopped at' or 'stops at', stop.station, which, n, label(w), w.to.where, F.keep_text(k), k.max)
              if stop.now then block(w, key, text, key .. ' ' .. k.max) else risk(w, key, text, key .. ' ' .. k.max) end
            end
            for _, a in ipairs(asks) do
              local go = F.hub_gives(keeps, w.item, n, a.want_q or a.min - a.held, off, q)
              if go > 0 then
                local key = 'demand ' .. stop.station .. ' ' .. at(a.pad.position)
                local kept = k and '; ' .. F.keep_text(k) or ''
                if stop.now then
                  block(w, key, string.format('%s is stopped at %s (%s) with %d %s in its hub, before %s; the landing pad %s there asks %d %s (holds %d): while it is stopped there its hub sends %d of it down to that pad%s',
                    pl.name, stop.station, which, n, label(w), w.to.where, at(a.pad.position), a.min, label(w), a.held, go, kept), key .. ' ' .. a.min)
                else
                  risk(w, key, string.format('%s stops at %s (%s) before %s; the landing pad %s there asks %d %s (holds %d): while it is stopped there its hub sends %d of it down to that pad (the hub holds %d now%s)',
                    pl.name, stop.station, which, w.to.where, at(a.pad.position), a.min, label(w), a.held, go, n, kept), key .. ' ' .. a.min)
                end
              end
            end
          end
        end
        -- (AB6) its cargo pods with the item since the watch was set received by a pad, or landed, on another planet: a
        -- diversion. (QJ1) At the destination the landed stage comes from the pods the watch followed (landed below), the
        -- same arrivals received counts, so the two always agree.
        local seen_div = {}
        for _, r in ipairs(api.freight and try(function() return api.freight.receipts_since(pl, w.start) end) or {}) do
          local n2 = amount(r, w.item, w.quality)
          local onto = r.dest and r.dest.surface or r.stop
          if n2 and n2 > 0 and onto and onto ~= w.to.where and (r.kind == 'received' or r.kind == 'landed') then
            local key = r.tick .. ' ' .. tostring(r.where)
            seen_div[key] = true
            if not (w.div_seen or {})[key] then
              local ask = ''
              for _, a in ipairs(r.dest and r.dest.position and pad_asks(force, onto, w.item, w.quality) or {}) do
                if a.pad.position.x == r.dest.position.x and a.pad.position.y == r.dest.position.y then ask = string.format(', which asks %d of it (holds %d now)', a.min, a.held) end
              end
              local d = {tick=r.tick, count=n2, planet=onto, where=r.where,
                text=string.format('%d %s %s %s%s, before %s', n2, label(w), r.kind == 'received' and 'received by' or 'landed with no pad:', r.where, ask, w.to.where)}
              w.diversions = w.diversions or {}
              w.diversions[#w.diversions+1] = d
              if #w.diversions > 8 then table.remove(w.diversions, 1) end
              w.diverted = (w.diverted or 0) + n2
              -- the running total keeps each line new to the board's repeat filter (alerts_seen: the same text once in REPEAT_SHOWN)
              push(w, string.format('delivery watch #%d (%d %s to %s %s on %s): diverted: %s; %d of it diverted since the watch was set', w.id, w.count, label(w), w.to.name, at(w.to.position), w.to.where, d.text, w.diverted))
            end
          end
        end
        w.div_seen = seen_div
      end
      if w.nopad then block(w, 'nopad', w.nopad) end
      -- the pad's network against the consumer's
      if w.pad and e and e.valid then
        local s = e.surface
        local pad = try(function() return s.find_entities_filtered{name=w.pad.name, position=w.pad.position, radius=1, limit=1}[1] end)
        if pad and pad ~= e then
          local a, b = network_of(pad), network_of(e)
          seen(w, 'network', string.format('the pad %s is in logistic network %s; the consumer in %s', at(pad.position), a and '#' .. a or 'none', b and '#' .. b or 'none'), tick)
          if not b then block(w, 'network', string.format('the consumer %s %s is in no logistic network: robots bring it nothing from the pad %s', w.to.name, at(w.to.position), at(pad.position)))
          elseif a ~= b then block(w, 'network', string.format('landed at the pad %s in logistic network %s; the consumer %s %s is in network #%d: robots of one do not carry to the other', at(pad.position), a and '#' .. a or 'none', w.to.name, at(w.to.position), b)) end
        end
      end
    else
      -- up: the consumer aboard a platform
      local pl = w.to_platform and platform_named(game.forces[w.force], w.to_platform)
      if pl and pl.valid then
        if w.from then
          local s = try(function() return game.planets[w.from].surface end)
          for _, silo in ipairs(s and api.census_typed and try(function() return api.census_typed(game.forces[w.force], s, 'rocket-silo') end) or {}) do
            local inv = try(function() return silo.get_inventory(defines.inventory.rocket_silo_rocket) end)
            local n = inv and count_q(inv, w.item, w.quality) or 0
            if n > 0 then seen(w, 'loaded', string.format('rocket-silo %s on %s has %d %s in its rocket', at(silo.position), w.from, n, label(w)), tick); break end
          end
          if not w.stages.launched and try(function() return pl.space_location.name end) ~= w.from then
            block(w, 'orbit', string.format('%s is not stopped at %s: a silo there launches to it only while it is', pl.name, w.from))
          end
        end
        local inc = api.freight and try(function() return api.freight.incoming(pl) end)
        for _, r in ipairs(inc and inc.rows or {}) do
          local n = amount(r, w.item, w.quality)
          if n and n > 0 and (not w.from or r.from == w.from) then
            seen(w, 'launched', string.format('a rocket from %s with %d %s launched to %s', tostring(r.from), n, label(w), pl.name), r.tick or tick)
            seen(w, 'in_transit', string.format('its pod %s', r.down and 'coming down onto the platform' or 'rising over ' .. tostring(r.from)), tick)
          end
        end
        -- (d25 batch207 QT4, Astra #2353: watch 472 named Asterion, paused at Aquilo, blocked while the same watch saw 25
        -- uranium magazines launched to it and the pod in transit; on a copy of world n Kestrel IVb, paused at Nauvis from
        -- 62350620, was sent 7 rockets of 25 uranium-rounds-magazine by 62359610 and its hub went 1350 -> 1525) paused is a blocker only when it keeps the platform
        -- from where the cargo comes up: not stopped at from (with no from: in flight); paused stays a fact (w.paused)
        local here = not try(function() return pl.space_connection end) and try(function() return pl.space_location.name end) or nil
        w.paused = pl.paused and string.format('%s is paused%s', pl.name, here and ' at ' .. here or ' in flight') or nil
        if pl.paused and (w.from and here ~= w.from or not w.from and not here) then
          block(w, 'paused', w.paused .. ': it goes nowhere until unpaused' .. (w.from and string.format('; a silo on %s launches to it only while it is stopped there', w.from) or ''))
        end
      elseif w.paused then w.paused = nil end
    end
    -- events: a blocker new, a blocker gone, the arrival, the deadline
    w.blocks, w.sigs, w.rsigs = w.blocks or {}, w.sigs or {}, w.rsigs or {}
    for k, text in pairs(w.now_blocks) do
      if (w.sigs[k] or w.blocks[k]) ~= w.now_sigs[k] then push(w, string.format('delivery watch #%d (%d %s to %s %s on %s): blocked: %s', w.id, w.count, label(w), w.to.name, at(w.to.position), w.to.where, text)) end
    end
    for k, text in pairs(w.blocks) do
      if not w.now_blocks[k] then push(w, string.format('delivery watch #%d: no longer blocked: %s', w.id, text)) end
    end
    for k, text in pairs(w.now_risks) do
      if w.rsigs[k] ~= w.now_rsigs[k] then push(w, string.format('delivery watch #%d (%d %s to %s %s on %s): at risk: %s', w.id, w.count, label(w), w.to.name, at(w.to.position), w.to.where, text)) end
    end
    w.blocks, w.sigs, w.risks, w.rsigs = w.now_blocks, w.now_sigs, w.now_risks, w.now_rsigs
    w.now_blocks, w.now_sigs, w.now_risks, w.now_rsigs = nil, nil, nil, nil
    if (w.received or 0) >= w.count then seen(w, 'received', received_text(w), w.received_tick or tick) end
    M.finish(w, tick)
  end
  local function when(w, tick)
    return string.format('%s %s', tick <= w.deadline and 'in time,' or 'late,', tick <= w.deadline and secs(w.deadline - tick) .. ' before the deadline' or secs(tick - w.deadline) .. ' after the deadline')
  end
  -- The watch's end or its deadline: with from, received (the total from that source); with none, reached (the stock
  -- test) or received, whichever first; late. An ended watch counts pods on until its deadline (counting).
  local function counting_text(w, tick)
    return w.counting and string.format('reached at tick %d; still counting until the deadline (%s from now): later pods add to received', w.reached_tick, secs(w.deadline - tick))
      or string.format('reached at tick %d', w.reached_tick)
  end
  local function reach(w, tick, by)
    w.ended_by, w.reached_tick = by, tick
    if tick < w.deadline then w.counting = true else w.ended = tick end
  end
  function M.finish(w, tick)
    if w.state ~= 'open' and w.state ~= 'late' then return end
    if w.stages.reached and not w.from then
      w.state = 'reached'
      reach(w, tick, 'stock')
      push(w, string.format('delivery watch #%d: reached by the stock test: %s, %s; %s; %s', w.id, w.stages.reached.text, when(w, tick), received_text(w), counting_text(w, tick)))
    elseif w.stages.received then
      local t = w.stages.received.tick
      w.state = 'received'
      reach(w, tick, 'received')
      push(w, string.format('delivery watch #%d (%d %s to %s %s on %s): %s, %s; %s; %s', w.id, w.count, label(w), w.to.name, at(w.to.position), w.to.where,
        received_text(w), when(w, t), stock_text(w), counting_text(w, tick)))
    elseif w.state == 'open' and tick >= w.deadline then
      w.state = 'late'
      push(w, string.format('delivery watch #%d (%d %s to %s %s on %s): deadline passed, %s: %s', w.id, w.count, label(w), w.to.name, at(w.to.position), w.to.where,
        w.from and 'not received from ' .. w.from or 'not reached', M.status(w)))
    end
  end
  -- A watch counting after it ended: the consumer's count, and at its deadline the count ends (the setter told the total).
  function M.count_on(w, tick)
    local e = w.consumer
    local held = e and e.valid and count_q(e, w.item, w.quality)
    if held then M.held(w, held, tick) end
    if (w.received or 0) >= w.count then seen(w, 'received', received_text(w), w.received_tick or tick) end
    if tick >= w.deadline then
      w.counting, w.ended = nil, tick
      push(w, string.format('delivery watch #%d (%d %s to %s %s on %s): the deadline ended its count: %s', w.id, w.count, label(w), w.to.name, at(w.to.position), w.to.where, received_text(w)))
    end
  end
  -- The last confirmed stage, the consumer's count and the blockers in words.
  function M.status(w)
    local last = w.last and string.format('last confirmed stage %s (%s, %s ago)', w.last, w.stages[w.last].text, secs(game.tick - w.stages[w.last].tick)) or 'no stage seen yet'
    local b = {}
    for _, text in pairs(w.blocks or {}) do b[#b+1] = text end
    table.sort(b)
    local rk = {}
    for _, text in pairs(w.risks or {}) do rk[#rk+1] = text end
    table.sort(rk)
    local dv = {}
    for _, d in ipairs(w.diversions or {}) do dv[#dv+1] = d.text end
    recv_info(w)
    local ad = w.at_destination and w.at_destination.sends > 0 and '; at the destination: ' .. w.at_destination.line or ''
    return string.format('%s; the consumer holds %d (%d at the start); %s%s%s%s%s', last, w.held or w.base, w.base, received_text(w), ad, #b > 0 and '; blocked: ' .. table.concat(b, '; ') or '',
      #rk > 0 and '; at risk: ' .. table.concat(rk, '; ') or '', #dv > 0 and string.format('; diverted %d: %s', w.diverted or 0, table.concat(dv, '; ')) or '')
  end
  function M.row(w)
    local stages = {}
    for _, s in ipairs(M.ORDER) do
      local x = w.stages[s]
      if x then stages[#stages+1] = {stage=s, tick=x.tick, text=x.text} end
    end
    local parts = {}
    for _, x in ipairs(stages) do parts[#parts+1] = string.format('%s %s ago (%s)', x.stage, secs(game.tick - x.tick), x.text) end
    local b = {}
    for _, text in pairs(w.blocks or {}) do b[#b+1] = text end
    table.sort(b)
    local rk = {}
    for _, text in pairs(w.risks or {}) do rk[#rk+1] = text end
    table.sort(rk)
    local dl = w.deadline - game.tick
    return {id=w.id, item=w.item, quality=w.quality, counts=rule(w), count=w.count, to=w.to, from=w.from, direction=w.direction, setter=w.setter, state=w.state, deadline_tick=w.deadline,
      stages=stages, last_confirmed=w.last, blockers=#b > 0 and b or nil, risks=#rk > 0 and rk or nil, at_destination=w.at_destination, paused=w.paused,
      diversions=w.diversions and #w.diversions > 0 and w.diversions or nil, diverted=w.diverted, arrivals=w.arrivals, held=w.held or w.base, at_start=w.base, carrier=w.carrier,
      carrier_guessed=(w.direction == 'down' and not w.from and w.carrier ~= nil) or nil, carrier_note=w.direction == 'down' and not w.from and w.carrier and string.format('a guess (no from given): the first platform of ours seen holding %s whose schedule stops at %s; its stages and blockers are that platform\'s; received counts the pods from any platform of ours landing here (received.by_platform)',
        label(w), w.to.where) or nil,
      stock={held=w.held or w.base, at_start=w.base, reached=w.stages.reached ~= nil, ends_watch=not w.from, line=string.format('the stock test: the consumer holds %d, %d at the start: %s%s', w.held or w.base, w.base,
        w.stages.reached and string.format('%d more reached', w.count) or string.format('%d more not reached', w.count),
        w.from and string.format('; with from given it does not end the watch (it ends when %d is received from %s)', w.count, w.from) or '')},
      ended_by=w.ended_by, reached_tick=w.reached_tick, counting=w.counting,
      received={count=w.received or 0, pods=w.received_pods or 0, last_tick=w.received_tick, by=w.recv_by, by_platform=w.received_by, from_arrivals=w.received_from and true or nil},
      line=string.format('delivery watch #%d: %d %s to %s %s on %s, %s; deadline %s%s; %s; stages: %s; counts %s', w.id, w.count, label(w), w.to.name, at(w.to.position), w.to.where,
        w.state, dl >= 0 and 'in ' .. secs(dl) or secs(-dl) .. ' ago',
        w.reached_tick and string.format('; ended by %s, %s', w.ended_by == 'stock' and 'the stock test' or 'the received total', counting_text(w, game.tick)) or '',
        M.status(w), #parts > 0 and table.concat(parts, ', ') or 'none yet', rule(w))}
  end
  -- (d24 batch184 QAA1, operator 18:03: the list of 6 watches took 24.6 ms on world n; on a copy 5-6 ms for 3, half of it
  -- the reply's JSON (15 KB of whole rows) and half the rows and their status text) the list's row: the facts to tell
  -- watches apart and see how each stands, no stage texts, received by source or arrivals; delivery_watch {id} gives the
  -- whole row, {full: true} every whole row
  local function count_of(t) local n = 0; for _ in pairs(t or {}) do n = n + 1 end; return n end
  function M.brief(w)
    local dl = w.deadline - game.tick
    local last = w.last and w.stages[w.last]
    local nb, nr = count_of(w.blocks), count_of(w.risks)
    return {id=w.id, item=w.item, quality=w.quality, counts=rule(w), count=w.count, to={name=w.to.name, position=w.to.position, where=w.to.where}, from=w.from,
      state=w.state, last_confirmed=w.last, last_s=last and math.floor((game.tick - last.tick) / 60) or nil, received=w.received or 0, held=w.held or w.base, at_start=w.base,
      blockers=nb > 0 and nb or nil, risks=nr > 0 and nr or nil, deadline_tick=w.deadline,
      line=string.format('delivery watch #%d: %d %s to %s %s on %s, %s; deadline %s; %s; received %d of %d; %s%s; %s; delivery_watch {id: %d} gives the whole row',
        w.id, w.count, label(w), w.to.name, at(w.to.position), w.to.where, w.state, dl >= 0 and 'in ' .. secs(dl) or secs(-dl) .. ' ago',
        last and string.format('last confirmed stage %s, %s ago', w.last, secs(game.tick - last.tick)) or 'no stage seen yet', w.received or 0, w.count,
        nb > 0 and string.format('%d blocker%s', nb, nb == 1 and '' or 's') or 'no blocker', nr > 0 and string.format(', %d at risk', nr) or '', rule(w), w.id)}
  end
  -- delivery_watch: set one (item, count, to, deadline_min, from?), end one (id, clear: true), or read them (none).
  function M.call(p, a)
    local st = store()
    local who = api.who and api.who(p) or p.name
    if a.clear ~= nil or (a.id ~= nil and a.item == nil) then
      assert(type(a.id) == 'number', 'id: the watch to read or clear (delivery_watch {} lists them)')
      for i, w in ipairs(st.list) do
        if w.id == a.id then
          if a.clear == true then gone(w, 'cleared', game.tick, who); table.remove(st.list, i); return {cleared=a.id, line='delivery watch #' .. a.id .. ' cleared'} end
          return {watches={M.row(w)}}
        end
      end
      error(missing(a.id), 0)
    end
    if a.item == nil then
      assert(a.full == nil or a.full == true, 'full: true gives every watch\'s whole row')
      local rows, lines = {}, {}
      for _, w in ipairs(st.list) do
        if w.force == p.force.name then local r = a.full and M.row(w) or M.brief(w); rows[#rows+1] = r; lines[#lines+1] = r.line end
      end
      return {watches=rows, lines=lines, note=#rows == 0 and 'no delivery watch; set one with item, count, to {position, surface | platform}, deadline_min'
        or not a.full and 'each watch in brief; delivery_watch {id: N} gives its whole row (stages with their texts, received by source, arrivals, diversions, the stock test, blockers and risks in words), {full: true} every whole row' or nil}
    end
    assert(type(a.item) == 'string' and prototypes.item[a.item], 'unknown item: ' .. tostring(a.item))
    assert(a.quality == nil or (type(a.quality) == 'string' and (not prototypes.quality or prototypes.quality[a.quality])),
      'quality: a quality name (normal, uncommon, rare, epic, legendary), or item as name@quality; none counts every quality')
    assert(type(a.count) == 'number' and a.count >= 1 and a.count <= 1000000 and a.count == math.floor(a.count), 'count: a whole number 1..1000000')
    assert(type(a.deadline_min) == 'number' and a.deadline_min > 0 and a.deadline_min <= 1440, 'deadline_min: minutes from now, up to 1440')
    assert(type(a.to) == 'table' and type(a.to.position) == 'table', 'to: {position {x, y}, surface (a planet) or platform (a name)}: the consumer, a silo, chest or machine of ours')
    local open = 0
    for _, w in ipairs(st.list) do if w.force == p.force.name and (w.state == 'open' or w.state == 'late') then open = open + 1 end end
    assert(open < MAX, string.format('%d delivery watches are open for the force (at most %d): clear one first', open, MAX))
    local s, to_platform
    if a.to.platform ~= nil then
      local pl = platform_named(p.force, a.to.platform)
      assert(pl, 'no platform of ours named ' .. tostring(a.to.platform))
      s, to_platform = pl.surface, pl.name
    else
      local name = a.to.surface or try(function() return p.surface.name end)
      assert(type(name) == 'string' and game.planets[name], 'to.surface: a planet name (or to.platform for a consumer aboard a platform)')
      s = game.planets[name].surface
      assert(s, name .. ' has no surface yet')
    end
    local pos = {x=tonumber(a.to.position.x or a.to.position[1]), y=tonumber(a.to.position.y or a.to.position[2])}
    assert(pos.x and pos.y, 'to.position: {x, y}')
    assert(to_platform or p.force.is_chunk_charted(s, {math.floor(pos.x / 32), math.floor(pos.y / 32)}), 'to.position is in a chunk our force has not charted')
    local best, d
    for _, e in ipairs(s.find_entities_filtered{position=pos, radius=2, force=p.force, type=CONSUMERS}) do
      local dd = (e.position.x - pos.x) ^ 2 + (e.position.y - pos.y) ^ 2
      if not d or dd < d then best, d = e, dd end
    end
    assert(best, string.format('no silo, chest or machine of ours within 2 tiles of %s on %s', at(pos), to_platform or s.name))
    if a.from ~= nil then
      assert(type(a.from) == 'string' and (platform_named(p.force, a.from) or game.planets[a.from]), 'from: a platform of ours or a planet name')
    end
    local where = to_platform or s.name
    st.seq = st.seq + 1
    local w = {id=st.seq, setter=who, index=p.index, force=p.force.name, item=a.item, quality=a.quality, count=a.count, from=a.from,
      to={name=best.name, position=best.position, where=where, platform=to_platform}, to_platform=to_platform,
      direction=to_platform and 'up' or 'down', consumer=best, start=game.tick, deadline=game.tick + math.floor(a.deadline_min * 3600),
      base=count_q(best, a.item, a.quality), stages={}, state='open', blocks={}, received=0, received_pods=0}
    recv_info(w)
    if to_platform then w.hub_base = hub_count(platform_named(p.force, to_platform), a.item, a.quality) end
    if a.from and platform_named(p.force, a.from) then w.carrier = a.from end
    st.list[#st.list+1] = w
    pcall(M.check, w, game.tick)
    return {watch=M.row(w), line=M.row(w).line}
  end
  -- (d21 batch66 AB7, Aurora 17:03: "Robots moved 300 of Petrel II's packs before its arrival-age check") Each pod with
  -- a watched item, followed to the tick it is gone. 2.0.77 on the private copy: a pod of 100 agricultural science packs
  -- last read parking over Fulgora at 45.83% spoiled; on the next tick the pod was gone and the pad held 100 at 45.83%;
  -- one tick later robots had taken 16. So a pod is read every tick while it is over its destination's surface (every
  -- POD_FAR ticks before), and the pad, hub or container it went to is read on the tick it is gone, before robots or
  -- inserters take from it.
  local PODS, POD_FAR, POD_KEEP, ARRIVALS = 32, 10, 36000, 16
  local BUCKETS = {'0-25%', '25-50%', '50-75%', '75-100%'}
  local function item_stacks(inv, item)
    local out = {}
    for i = 1, inv and #inv or 0 do
      local x = inv[i]
      if x.valid_for_read and x.name == item then
        out[#out+1] = {count=x.count, spoil=try(function() return x.spoil_percent end) or 0, quality=try(function() return x.quality.name end)}
      end
    end
    return out
  end
  -- The count and, for an item that spoils, the count by how spoiled each stack is (the GUI's spoil bar), in quarters.
  local function buckets(stacks, spoils)
    local b, n = {}, 0
    for _, x in ipairs(stacks) do
      n = n + x.count
      if spoils then
        local k = BUCKETS[math.min(4, math.floor(x.spoil * 4) + 1)]
        b[k] = (b[k] or 0) + x.count
      end
    end
    return n, spoils and b or nil
  end
  local function btext(b)
    if not b then return 'it does not spoil' end
    local parts = {}
    for _, k in ipairs(BUCKETS) do if b[k] then parts[#parts+1] = string.format('%d at %s spoiled', b[k], k) end end
    return #parts > 0 and table.concat(parts, ', ') or 'none'
  end
  local function spoils(item)
    if api.freight and api.freight.spoils then return api.freight.spoils(item) end
    return (try(function() return prototypes.item[item].get_spoil_ticks() end) or 0) > 0
  end
  local function snap(f, tick)
    local pod = f.pod
    local inv = try(function() return pod.get_inventory(defines.inventory.cargo_unit) end)
    local items = {}
    for _, item in pairs(f.watches) do items[item] = item_stacks(inv, item) end
    local d = try(function() return pod.cargo_pod_destination end)
    local station = d and d.station
    if station and try(function() return station.valid end) then
      f.station = station
      f.dest = try(function() return station.surface.name end)
    elseif d and d.space_platform then
      f.station = try(function() return d.space_platform.hub end) or f.station
      f.dest = try(function() return d.space_platform.surface.name end) or f.dest
    elseif d and d.surface then
      f.dest = try(function() return d.surface.name end) or f.dest
    end
    f.last = {tick=tick, state=try(function() return pod.cargo_pod_state end), surface=try(function() return pod.surface.name end),
      position=try(function() return {x=pod.position.x, y=pod.position.y} end), items=items}
  end
  local function follow(st, pod, unit, w, src)
    if not unit then return end
    local f = st.pods[unit]
    if not f then
      local c = 0
      for _ in pairs(st.pods) do c = c + 1 end
      if c >= PODS then return end
      f = {pod=pod, unit=unit, watches={}, src=src, first=game.tick}
      st.pods[unit] = f
    end
    if not f.watches[w.id] then f.watches[w.id] = w.item; snap(f, game.tick) end
  end
  local function pod_has(pod, item, q)
    local inv = try(function() return pod.valid and pod.get_inventory(defines.inventory.cargo_unit) end)
    return inv and count_q(inv, item, q) or 0
  end
  -- The pods to follow: down, those freight follows from the carrier's hub; up, the rockets launched to the platform.
  local function register_one(st, w)
    local force = game.forces[w.force]
    local pl = w.direction == 'down' and w.carrier and platform_named(force, w.carrier) or w.direction == 'up' and platform_named(force, w.to_platform)
    local fol = pl and api.freight and api.freight.followed and try(function() return api.freight.followed(pl) end)
    if w.direction == 'down' and not w.from then
      -- (d20 batch134 PF1, Sol #2096: watch #254 guessed Kestrel IVa, paused, while Solstice's pod of 365 landed at the
      -- pad and was not counted) no source given: the pods of every platform of ours sent down at the destination's
      -- planet with the item, and the guessed carrier's at any stop (as before: a diversion's arrival)
      for _, x in pairs(try(function() return force.platforms end) or {}) do
        local fx = x.valid and api.freight and api.freight.followed and try(function() return api.freight.followed(x) end)
        for _, p in ipairs(fx and fx.down or {}) do
          if (p.at == w.to.where or x.name == w.carrier) and pod_has(p.pod, w.item, w.quality) > 0 then follow(st, p.pod, p.unit, w, {platform=x.name, stop=p.at, sent=p.tick}) end
        end
      end
    elseif fol and w.direction == 'down' then
      for _, p in ipairs(fol.down) do
        if pod_has(p.pod, w.item, w.quality) > 0 then follow(st, p.pod, p.unit, w, {platform=pl.name, stop=p.at, sent=p.tick}) end
      end
    elseif fol then
      for _, p in ipairs(fol.up) do
        if pod_has(p.pod, w.item, w.quality) > 0 and (not w.from or p.from == w.from) then
          follow(st, p.pod, try(function() return p.pod.unit_number end), w, {rocket=true, planet=p.from, silo=p.silo, launched=p.tick, up=p.up, platform=pl.name})
        end
      end
    end
  end
  -- one watch's fault does not stop the others' (a pod gone between freight's looks once did)
  local function register(st)
    st.pods = st.pods or {}
    for _, w in ipairs(st.list) do
      if w.state == 'open' or w.state == 'late' or w.counting then
        local ok, err = pcall(register_one, st, w)
        w.pod_error = not ok and tostring(err) or nil
      end
    end
  end
  -- A followed pod gone at tick: what it held of each watch's item at its last read, and what the pad, hub or container
  -- it went to holds of it on this tick; kept on the watch and told to its setter.
  local function landed(st, f, tick)
    local last = f.last or {}
    local where, inv
    local station = f.station and f.station.valid and f.station
    if station and station.type == 'space-platform-hub' then
      inv = try(function() return station.get_inventory(defines.inventory.hub_main) end)
      where = string.format('%s\'s hub', try(function() return station.surface.platform.name end) or f.src.platform or '?')
    elseif station then
      inv = try(function() return station.get_inventory(defines.inventory.cargo_landing_pad_main) end)
      where = string.format('%s %s on %s', station.name, at(station.position), station.surface.name)
    else
      local box = last.surface and last.position and try(function()
        local best, d
        for _, e in pairs(game.surfaces[last.surface].find_entities_filtered{name='cargo-pod-container', position=last.position, radius=8}) do
          local dd = (e.position.x - last.position.x) ^ 2 + (e.position.y - last.position.y) ^ 2
          if not d or dd < d then best, d = e, dd end
        end
        return best
      end)
      inv = box and try(function() return box.get_inventory(defines.inventory.chest) end)
      where = box and string.format('cargo-pod-container %s on %s (no pad)', at(box.position), last.surface)
        or string.format('the ground near %s on %s (no pad; no cargo pod container within 8 tiles)', last.position and at(last.position) or '?', tostring(last.surface))
    end
    local src = f.src or {}
    local from = src.rocket and string.format('a rocket from %s%s, launched %s before', tostring(src.planet), src.silo and ' (rocket-silo ' .. at(src.silo) .. ')' or '', secs(tick - (src.launched or tick)))
      or string.format('%s\'s hub at %s, sent %s before', tostring(src.platform), tostring(src.stop or '?'), secs(tick - (src.sent or tick)))
    for _, w in ipairs(st.list) do
      local item = f.watches[w.id]
      if item then
        local sp = spoils(item)
        -- (QJ1) the pod's stacks by quality (every one listed); the watch counts its quality, or every quality
        local all = last.items and last.items[item] or {}
        local stacks, by_q, other = {}, {}, 0
        for _, x in ipairs(all) do
          local q = qname(x.quality)
          by_q[q] = (by_q[q] or 0) + x.count
          if not w.quality or q == w.quality then stacks[#stacks+1] = x else other = other + x.count end
        end
        local n, b = buckets(stacks, sp)
        if n > 0 then
          local dest_stacks = {}
          for _, x in ipairs(item_stacks(inv, item)) do if not w.quality or qname(x.quality) == w.quality then dest_stacks[#dest_stacks+1] = x end end
          local dn, db = buckets(dest_stacks, sp)
          local per = {}
          for i, x in ipairs(all) do per[i] = {count=x.count, quality=x.quality, spoil_percent=sp and math.floor(x.spoil * 1000 + 0.5) / 10 or nil} end
          local qparts = {}
          for _, q in ipairs(qualities()) do if by_q[q] then qparts[#qparts+1] = q .. ' ' .. by_q[q] end end
          for q, c in pairs(by_q) do local listed = false for _, x in ipairs(qualities()) do if x == q then listed = true end end if not listed then qparts[#qparts+1] = q .. ' ' .. c end end
          local a = {tick=tick, pod=f.unit, from=from, platform=src.platform, stop=src.stop, rocket=src.rocket and {planet=src.planet, silo=src.silo, launched=src.launched, up=src.up} or nil,
            where=where, count=n, by_quality=by_q, counted_quality=w.quality or 'every quality', spoil=b, stacks=per, read_tick=last.tick, dest_count=dn, dest_spoil=db}
          -- the qualities in words when the watch names one or the pod holds any but normal (by_quality always)
          local plain = not w.quality and #qparts == 1 and by_q.normal ~= nil
          a.text = string.format('pod %s from %s, received by %s at tick %d: %d %s (%s%s; the pod\'s last read, %s before); %s held %d of it on that tick (%s)',
            tostring(f.unit), from, where, tick, n, label(w),
            plain and '' or table.concat(qparts, ', ') .. (other > 0 and string.format(', %d of other qualities not counted', other) or '') .. '; ',
            btext(b), secs(tick - (last.tick or tick)), where, dn, btext(db))
          w.arrivals = w.arrivals or {}
          w.arrivals[#w.arrivals+1] = a
          if #w.arrivals > ARRIVALS then table.remove(w.arrivals, 1) end
          -- (BQ1) received by the consumer (recv_info): the running total, and the watch complete by receipt
          recv_info(w)
          local counted = false
          if station and w.received ~= nil then
            if w.recv_kind == 'pad' then counted = same(station, w.consumer)
            elseif w.recv_kind == 'hub' then counted = station.type == 'space-platform-hub' and try(function() return station.surface.platform.name end) == w.to_platform
            elseif station.type == 'cargo-landing-pad' and w.consumer and w.consumer.valid and try(function() return station.surface.name end) == w.to.where then
              local net = network_of(station)
              counted = net ~= nil and net == network_of(w.consumer)
            end
          end
          if counted then
            a.received = true
            w.received, w.received_pods, w.received_tick = w.received + n, w.received_pods + 1, tick
            -- (PF1) by the platform it came from; a pod from a platform the watch did not guess lands the stage too
            local from_pl = src.platform or (src.rocket and src.planet) or '?'
            w.received_by = w.received_by or {}
            w.received_by[from_pl] = (w.received_by[from_pl] or 0) + n
          end
          -- (QJ1) the landed stage from this arrival: the same pod, count and quality rule as received
          local dest_s = station and try(function() return station.surface.name end) or last.surface
          -- the source named only with no from given, as received's line names platforms
          local from_txt = not w.from and ' (from ' .. (src.platform or (src.rocket and src.planet) or '?') .. ')' or ''
          if w.direction == 'up' and counted then
            seen(w, 'landed', string.format('%d %s received by %s%s', n, label(w), where, from_txt), tick)
          elseif w.direction == 'down' and dest_s == w.to.where then
            if station then
              seen(w, 'landed', string.format('%d %s received by %s%s%s', n, label(w), where, from_txt,
                counted and '' or ': not counted as received (not ' .. tostring(w.recv_by) .. ')'), tick)
              w.pad = w.pad or {position={x=station.position.x, y=station.position.y}, name=station.name}
            else
              seen(w, 'landed', string.format('%d %s landed with no pad: %s%s', n, label(w), where, from_txt), tick)
              w.nopad = string.format('a pod with %d %s landed with no pad, %s: robots do not take from it', n, label(w), where)
            end
          end
          push(w, string.format('delivery watch #%d: %s%s', w.id, a.text, counted and '; ' .. received_text(w) or ''))
          if counted and w.received >= w.count and (w.state == 'open' or w.state == 'late') then
            local e = w.consumer
            local held = e and e.valid and count_q(e, item, w.quality)
            if held then M.held(w, held, tick) end
            seen(w, 'received', received_text(w), tick)
            M.finish(w, tick)
          end
        end
      end
    end
  end
  -- Every tick: the followed pods (none: nothing read).
  function M.pod_tick(tick)
    local st = api.state().delivwatch
    local pods = st and st.pods
    if not (pods and next(pods)) then return end
    for unit, f in pairs(pods) do
      if try(function() return f.pod.valid end) then
        local near = f.last and f.dest and f.last.surface == f.dest
        if near or tick - (f.last and f.last.tick or 0) >= POD_FAR then snap(f, tick) end
        if tick - f.first > POD_KEEP then pods[unit] = nil end
      else
        pods[unit] = nil
        local ok, err = pcall(landed, st, f, tick)
        if not ok then st.pod_error = tostring(err) end
      end
    end
  end
  -- Each EVERY ticks: PER_PASS open watches in turn; ended ones dropped KEEP ticks after.
  function M.tick(tick)
    if tick % EVERY ~= 0 then return end
    local st = store()
    for i = #st.list, 1, -1 do
      local w = st.list[i]
      if (w.ended and tick - w.ended > KEEP) or (w.state == 'late' and tick - w.deadline > KEEP) then gone(w, 'dropped', tick); table.remove(st.list, i) end
    end
    local open, counting = {}, false
    for _, w in ipairs(st.list) do
      if w.state == 'open' or w.state == 'late' then open[#open+1] = w
      elseif w.counting then
        counting = true
        local ok, err = pcall(M.count_on, w, tick)
        if not ok then w.error = tostring(err) end
      end
    end
    if #open == 0 and not counting then return end
    for k = 1, math.min(PER_PASS, #open) do
      st.rr = st.rr % #open + 1
      local ok, err = pcall(M.check, open[st.rr], tick)
      if not ok then open[st.rr].error = tostring(err) end
    end
    local okr, errr = pcall(register, st)
    st.register_error = not okr and tostring(errr) or nil
  end
  -- team.alerts lines for agent p: its watches' events since it last heard (h: its hint state).
  function M.lines(p, h)
    local st = api.state().delivwatch
    if not st or #st.events == 0 then return nil end
    local me = api.who and api.who(p) or p.name
    local out = {}
    for _, e in ipairs(st.events) do
      if e.id > (h.delivwatch_seen or 0) and e.to == me then out[#out+1] = e.text end
    end
    h.delivwatch_seen = st.eseq
    return #out > 0 and out or nil
  end
  M.schema = {delivery_watch = {item='an item name: set a watch (with count, to, deadline_min); or name@quality (thruster@legendary)',
    quality='optional quality name: count that quality only; none: every quality (the row\'s counts says which). Received, by_platform, arrivals, the landed stage, the stock test, the hub and silo reads all count by it; each arrival lists its pod\'s stacks by quality (by_quality)', count='how many the consumer must receive (1..1000000)',
    to='{position {x, y}, surface (a planet; default yours) | platform (a name)}: the consumer, a silo, chest or machine of ours within 2 tiles of position, in a chunk our force has charted',
    deadline_min='minutes from now (up to 1440)', from='optional: the platform that carries it down (only its pods count), or the planet whose silos launch it up; none, down: the pods of any platform of ours sent down at the consumer\'s planet count',
    id='with clear: true, the watch to end; alone, read that watch (its whole row)', clear='true, with id: end it',
    full='optional true, with nothing else: every watch\'s whole row (the list alone gives each in brief)',
    returns='set: watch, line; none: watches (yours and the team\'s) in brief and lines: {id, item, quality, counts, count, to {name, position, where}, from, state, last_confirmed, last_s, received, held, at_start, blockers (a count), risks (a count), deadline_tick, line}; id (or full: true): the whole row. A watch row: {id, item, quality, counts (the quality rule: that quality only, or every quality), count, to {name, position, where}, from, direction (down: the consumer on a planet; up: aboard a platform), setter, state (open, late: past its deadline, received: the received total reached count (with from, the only end: the pods from that source), reached: no from, and the consumer was seen holding count more than at the start first), ended_by (stock or received), reached_tick, counting (true: ended before its deadline and still counting pods until it: later pods add to received and by_platform), deadline_tick, stages [{stage, tick, text}] (each first seen, in order: loaded (a platform\'s hub holds it; up: a silo of from with it in its rocket), launched (up: a rocket with it launched to the platform), departed (down: that platform flying), in_transit (flying to the consumer\'s planet; up: its pod on the way), arrived (stopped there), landed (a pod the watch followed received by a landing pad on that planet, which, or landed with no pad; up: received by the hub; the same arrivals received counts), network (the pad\'s logistic network and the consumer\'s), received (the received total reached count), reached (the consumer holds count more than at the start)), last_confirmed, at_destination paused (a fact, blocker or not: \'NAME is paused at PLANET\' or \'in flight\'), at_destination (down, the carrier stopped at the planet of the destination with the item, paused or not: {sends (what its hub sends down now by its sections for that planet and the pads\' ask less what they hold), held, asked, keep, line}; sends 0 is a blocker naming why), blockers (stopped before the destination at a planet whose landing pad asks the item: the pad, its request and count, which stop; the pad\'s network not the consumer\'s or the consumer in none, a pod landed with no pad, stopped there with it while no landing pad there has room for it or there is none, the platform paused away from the destination (stopped there paused, its hub sends pods down all the same: at_destination) or its schedule not stopping there, up: not stopped at from, paused away from from (no from: paused in flight; a paused platform stopped at a planet still receives that planet\'s rockets), a requester or buffer chest asking none of it, the consumer gone), risks (down: a landing pad asking the item on a planet the platform stops at before the destination, while the hub holds it and its own request does not keep it all), diversions [{tick, count, planet, where, text}] (pods of it received by a pad or landed on another planet) and diverted (their sum), arrivals [{tick, pod, from, platform, stop, rocket {planet, silo, launched}, where, count, spoil {\'0-25%\'=n, ...} (for an item that spoils: the count by how spoiled each stack is), by_quality {quality=count} (every stack of the pod), counted_quality, stacks [{count, quality, spoil_percent}] (every quality; count: the watch\'s quality rule), read_tick, dest_count, dest_spoil, text}] (each pod with the item from the carrier\'s hub, or each rocket with it launched to the platform, on the tick it was gone: what it held at its last read, read every tick over its destination, and what the pad, hub or container held of it on that tick, before robots take from it; the last 16), held, at_start (the stock test: held now and at the start), received {count, pods, last_tick, by, from_arrivals} (a running total since the watch was set of the pods the consumer received: a landing pad, the pods it received; a platform\'s consumer, the pods its hub received; a chest, silo or machine on a planet, the pods received by a landing pad in its logistic network on the tick each landed, which robots carry on; only the pods the watch followed: with from, that platform\'s; with none, every platform\'s sent down at the consumer\'s planet; by_platform: the count from each platform; from_arrivals: a watch set before the total was kept, counted from its arrivals), stock {held, at_start, reached, ends_watch (false with from: the stock test never ends such a watch), line} (the stock test, apart from received), carrier (from, or with none a guess: carrier_guessed, carrier_note; its stages and blockers are that platform\'s), line}. Read once a second, 4 watches a pass; at most 16 open a force. The setter hears in team.alerts each blocker and risk once, each diversion, each pod received (with the received total), a blocker gone, the deadline passed while not reached (with the last confirmed stage, the received total and the blocker) and the end: received (the total, pods, the last pod\'s tick, and the stock test apart) or reached; a watch is kept 10 minutes after it ends'}}
  return M
end
