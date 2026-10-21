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
-- pad; the platform stopped there with it while no landing pad there has room for it (or there is none); the platform paused, or its schedule not stopping at the planet; a requester or buffer chest consumer asking
-- none of the item; the consumer gone. The setter hears in team.alerts each blocker once, a blocker gone, the deadline
-- passed while not reached (the last confirmed stage and the blocker), and the arrival. A watch is kept KEEP ticks
-- after it ends; at most MAX open a force.
return function(api)
  local M = {}
  local EVERY, PER_PASS, KEEP, MAX, EVENTS = 60, 4, 36000, 16, 64
  M.ORDER = {'loaded', 'launched', 'departed', 'in_transit', 'arrived', 'landed', 'network', 'reached'}
  local RANK = {}
  for i, s in ipairs(M.ORDER) do RANK[s] = i end
  local CONSUMERS = {'rocket-silo', 'container', 'logistic-container', 'assembling-machine', 'furnace', 'lab', 'cargo-landing-pad',
    'space-platform-hub', 'ammo-turret', 'artillery-turret', 'reactor', 'boiler', 'burner-generator', 'cargo-wagon', 'car', 'spider-vehicle',
    'agricultural-tower', 'mining-drill', 'inserter'}
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
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
  local function push(w, text)
    local st = store()
    st.eseq = st.eseq + 1
    st.events[#st.events+1] = {id=st.eseq, to=w.setter, index=w.index, text=text}
    while #st.events > EVENTS do table.remove(st.events, 1) end
  end
  local function platform_named(force, name)
    for _, pl in pairs(try(function() return force.platforms end) or {}) do if pl.valid and pl.name == name then return pl end end
  end
  local function hub_count(pl, item)
    local inv = try(function() return pl.hub.get_inventory(defines.inventory.hub_main) end)
    return inv and (try(function() return inv.get_item_count(item) end) or 0) or 0
  end
  local function stops_at(pl, planet)
    for _, r in ipairs(try(function() return pl.schedule.records end) or {}) do if r.station == planet then return true end end
    return false
  end
  local function network_of(e)
    local net = try(function() return e.surface.find_logistic_network_by_position(e.position, e.force) end)
    return net and try(function() return net.network_id end) or nil
  end
  -- A requester or buffer chest asking none of the item: the text, else nil.
  local function asks_none(e, item)
    if e.type ~= 'logistic-container' then return nil end
    local mode = try(function() return e.prototype.logistic_mode end)
    if mode ~= 'requester' and mode ~= 'buffer' then return nil end
    local secs_ = try(function() return e.get_logistic_sections() end)
    for i = 1, secs_ and secs_.sections_count or 0 do
      local sec = secs_.get_section(i)
      if sec.active ~= false then
        for _, f in ipairs(sec.filters or {}) do
          local v = f.value
          if (type(v) == 'table' and v.name or v) == item and (f.min or 0) > 0 then return nil end
        end
      end
    end
    return string.format('the consumer, %s chest %s, asks none of %s: robots bring it nothing', mode, at(e.position), item)
  end
  local function seen(w, stage, text, tick)
    if not w.stages[stage] then
      w.stages[stage] = {tick=tick, text=text}
      if not w.last or RANK[stage] > RANK[w.last] then w.last = stage end
    end
  end
  local function block(w, key, text)
    w.now_blocks[key] = text
  end
  -- One watch read now (tick): stages seen, blockers now, its events.
  function M.check(w, tick)
    w.now_blocks = {}
    local e = w.consumer
    if not (e and e.valid) then
      block(w, 'gone', string.format('the consumer %s %s on %s is gone', w.to.name, at(w.to.position), w.to.where))
    else
      local held = try(function() return e.get_item_count(w.item) end) or 0
      w.held = held
      if held - w.base >= w.count then
        seen(w, 'reached', string.format('%s %s holds %d %s (%d when the watch was set)', w.to.name, at(w.to.position), held, w.item, w.base), tick)
      end
      local ask = asks_none(e, w.item)
      if ask then block(w, 'asks', ask) end
    end
    if w.direction == 'down' then
      local force = game.forces[w.force]
      local pl = w.carrier and platform_named(force, w.carrier)
      if not pl then
        local cands = {}
        if w.from then cands = {platform_named(force, w.from)} else for _, x in pairs(force.platforms) do cands[#cands+1] = x end end
        for _, x in ipairs(cands) do
          if x and x.valid and (w.from or stops_at(x, w.to.where)) and hub_count(x, w.item) > 0 then pl = x; w.carrier = x.name; break end
        end
      end
      if pl and pl.valid then
        local n = hub_count(pl, w.item)
        if n > 0 then seen(w, 'loaded', string.format('%s\'s hub holds %d %s', pl.name, n, w.item), tick) end
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
              if inv and try(function() return inv.can_insert({name=w.item, count=1}) end) then room = true end
              if #names < 3 then names[#names+1] = at(pad.position) end
            end
            if #pads == 0 then block(w, 'pad', string.format('no landing pad of ours on %s: a pod sent down lands on the ground', w.to.where))
            elseif not room then block(w, 'pad', string.format('no landing pad of ours on %s has room for %s (cargo-landing-pad %s): the hub sends no pod of it down', w.to.where, w.item, table.concat(names, ', '))) end
          end
        end
        if pl.paused then block(w, 'paused', string.format('%s is paused: it goes nowhere until unpaused', pl.name)) end
        if not stops_at(pl, w.to.where) then block(w, 'route', string.format('%s\'s schedule has no stop at %s', pl.name, w.to.where)) end
        -- its cargo pods with the item since the watch was set: received by a pad, or landed with no pad
        for _, r in ipairs(api.freight and try(function() return api.freight.receipts_since(pl, w.start) end) or {}) do
          local n2 = r.cargo and r.cargo[w.item]
          if n2 and n2 > 0 and r.dest and r.dest.surface == w.to.where and r.kind == 'received' then
            seen(w, 'landed', string.format('%d %s received by %s', n2, w.item, r.where), r.tick)
            w.pad = w.pad or {position=r.dest.position, name=r.dest.pad}
          elseif n2 and n2 > 0 and r.kind == 'landed' then
            seen(w, 'landed', string.format('%d %s landed with no pad: %s', n2, w.item, r.where), r.tick)
            block(w, 'nopad', string.format('a pod with %d %s landed with no pad, %s: robots do not take from it', n2, w.item, r.where))
          end
        end
      end
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
            local n = inv and (try(function() return inv.get_item_count(w.item) end) or 0) or 0
            if n > 0 then seen(w, 'loaded', string.format('rocket-silo %s on %s has %d %s in its rocket', at(silo.position), w.from, n, w.item), tick); break end
          end
          if not w.stages.launched and try(function() return pl.space_location.name end) ~= w.from then
            block(w, 'orbit', string.format('%s is not stopped at %s: a silo there launches to it only while it is', pl.name, w.from))
          end
        end
        local inc = api.freight and try(function() return api.freight.incoming(pl) end)
        for _, r in ipairs(inc and inc.rows or {}) do
          local n = r.cargo and r.cargo[w.item]
          if n and n > 0 and (not w.from or r.from == w.from) then
            seen(w, 'launched', string.format('a rocket from %s with %d %s launched to %s', tostring(r.from), n, w.item, pl.name), r.tick or tick)
            seen(w, 'in_transit', string.format('its pod %s', r.down and 'coming down onto the platform' or 'rising over ' .. tostring(r.from)), tick)
          end
        end
        local h = hub_count(pl, w.item)
        if h > (w.hub_base or 0) then seen(w, 'landed', string.format('%s\'s hub holds %d %s (%d when the watch was set)', pl.name, h, w.item, w.hub_base or 0), tick) end
        if pl.paused then block(w, 'paused', string.format('%s is paused', pl.name)) end
      end
    end
    -- events: a blocker new, a blocker gone, the arrival, the deadline
    w.blocks = w.blocks or {}
    for k, text in pairs(w.now_blocks) do
      if w.blocks[k] ~= text then push(w, string.format('delivery watch #%d (%d %s to %s %s on %s): blocked: %s', w.id, w.count, w.item, w.to.name, at(w.to.position), w.to.where, text)) end
    end
    for k, text in pairs(w.blocks) do
      if not w.now_blocks[k] then push(w, string.format('delivery watch #%d: no longer blocked: %s', w.id, text)) end
    end
    w.blocks, w.now_blocks = w.now_blocks, nil
    if w.stages.reached and w.state ~= 'reached' then
      w.state, w.ended = 'reached', tick
      push(w, string.format('delivery watch #%d: reached: %s, %s %s', w.id, w.stages.reached.text, tick <= w.deadline and 'in time,' or 'late,',
        tick <= w.deadline and secs(w.deadline - tick) .. ' before the deadline' or secs(tick - w.deadline) .. ' after the deadline'))
    elseif w.state == 'open' and tick >= w.deadline then
      w.state = 'late'
      push(w, string.format('delivery watch #%d (%d %s to %s %s on %s): deadline passed, not reached: %s', w.id, w.count, w.item, w.to.name, at(w.to.position), w.to.where, M.status(w)))
    end
  end
  -- The last confirmed stage, the consumer's count and the blockers in words.
  function M.status(w)
    local last = w.last and string.format('last confirmed stage %s (%s, %s ago)', w.last, w.stages[w.last].text, secs(game.tick - w.stages[w.last].tick)) or 'no stage seen yet'
    local b = {}
    for _, text in pairs(w.blocks or {}) do b[#b+1] = text end
    table.sort(b)
    return string.format('%s; the consumer holds %d (%d at the start)%s', last, w.held or w.base, w.base, #b > 0 and '; blocked: ' .. table.concat(b, '; ') or '')
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
    local dl = w.deadline - game.tick
    return {id=w.id, item=w.item, count=w.count, to=w.to, from=w.from, direction=w.direction, setter=w.setter, state=w.state, deadline_tick=w.deadline,
      stages=stages, last_confirmed=w.last, blockers=#b > 0 and b or nil, held=w.held or w.base, at_start=w.base, carrier=w.carrier,
      line=string.format('delivery watch #%d: %d %s to %s %s on %s, %s; deadline %s; %s; stages: %s', w.id, w.count, w.item, w.to.name, at(w.to.position), w.to.where,
        w.state, dl >= 0 and 'in ' .. secs(dl) or secs(-dl) .. ' ago', M.status(w), #parts > 0 and table.concat(parts, ', ') or 'none yet')}
  end
  -- delivery_watch: set one (item, count, to, deadline_min, from?), end one (id, clear: true), or read them (none).
  function M.call(p, a)
    local st = store()
    local who = api.who and api.who(p) or p.name
    if a.clear ~= nil or (a.id ~= nil and a.item == nil) then
      assert(type(a.id) == 'number', 'id: the watch to read or clear (delivery_watch {} lists them)')
      for i, w in ipairs(st.list) do
        if w.id == a.id then
          if a.clear == true then table.remove(st.list, i); return {cleared=a.id, line='delivery watch #' .. a.id .. ' cleared'} end
          return {watches={M.row(w)}}
        end
      end
      error('no delivery watch #' .. tostring(a.id), 0)
    end
    if a.item == nil then
      local rows, lines = {}, {}
      for _, w in ipairs(st.list) do
        if w.force == p.force.name then local r = M.row(w); rows[#rows+1] = r; lines[#lines+1] = r.line end
      end
      return {watches=rows, lines=lines, note=#rows == 0 and 'no delivery watch; set one with item, count, to {position, surface | platform}, deadline_min' or nil}
    end
    assert(type(a.item) == 'string' and prototypes.item[a.item], 'unknown item: ' .. tostring(a.item))
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
    local w = {id=st.seq, setter=who, index=p.index, force=p.force.name, item=a.item, count=a.count, from=a.from,
      to={name=best.name, position=best.position, where=where, platform=to_platform}, to_platform=to_platform,
      direction=to_platform and 'up' or 'down', consumer=best, start=game.tick, deadline=game.tick + math.floor(a.deadline_min * 3600),
      base=try(function() return best.get_item_count(a.item) end) or 0, stages={}, state='open', blocks={}}
    if to_platform then w.hub_base = hub_count(platform_named(p.force, to_platform), a.item) end
    if a.from and platform_named(p.force, a.from) then w.carrier = a.from end
    st.list[#st.list+1] = w
    pcall(M.check, w, game.tick)
    return {watch=M.row(w), line=M.row(w).line}
  end
  -- Each EVERY ticks: PER_PASS open watches in turn; ended ones dropped KEEP ticks after.
  function M.tick(tick)
    if tick % EVERY ~= 0 then return end
    local st = store()
    for i = #st.list, 1, -1 do
      local w = st.list[i]
      if (w.ended and tick - w.ended > KEEP) or (w.state == 'late' and tick - w.deadline > KEEP) then table.remove(st.list, i) end
    end
    local open = {}
    for _, w in ipairs(st.list) do if w.state == 'open' or w.state == 'late' then open[#open+1] = w end end
    if #open == 0 then return end
    for k = 1, math.min(PER_PASS, #open) do
      st.rr = st.rr % #open + 1
      local ok, err = pcall(M.check, open[st.rr], tick)
      if not ok then open[st.rr].error = tostring(err) end
    end
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
  M.schema = {delivery_watch = {item='an item name: set a watch (with count, to, deadline_min)', count='how many must reach the consumer (1..1000000)',
    to='{position {x, y}, surface (a planet; default yours) | platform (a name)}: the consumer, a silo, chest or machine of ours within 2 tiles of position, in a chunk our force has charted',
    deadline_min='minutes from now (up to 1440)', from='optional: the platform that carries it down, or the planet whose silos launch it up',
    id='with clear: true, the watch to end; alone, read that watch', clear='true, with id: end it',
    returns='set: watch, line; none: watches (yours and the team\'s) and lines. A watch row: {id, item, count, to {name, position, where}, from, direction (down: the consumer on a planet; up: aboard a platform), setter, state (open, late: past its deadline, reached), deadline_tick, stages [{stage, tick, text}] (each first seen, in order: loaded (a platform\'s hub holds it; up: a silo of from with it in its rocket), launched (up: a rocket with it launched to the platform), departed (down: that platform flying), in_transit (flying to the consumer\'s planet; up: its pod on the way), arrived (stopped there), landed (its cargo pod received by a landing pad, which, or landed with no pad; up: the hub holds more of it), network (the pad\'s logistic network and the consumer\'s), reached (the consumer holds count more than at the start)), last_confirmed, blockers (the pad\'s network not the consumer\'s or the consumer in none, a pod landed with no pad, stopped there with it while no landing pad there has room for it or there is none, the platform paused or its schedule not stopping there, up: not stopped at from, a requester or buffer chest asking none of it, the consumer gone), held, at_start, carrier, line}. Read once a second, 4 watches a pass; at most 16 open a force. The setter hears in team.alerts each blocker once, a blocker gone, the deadline passed while not reached (with the last confirmed stage and the blocker) and the arrival; a watch is kept 10 minutes after it ends'}}
  return M
end
