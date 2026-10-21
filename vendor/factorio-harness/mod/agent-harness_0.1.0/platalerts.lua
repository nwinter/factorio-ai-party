-- Platform health alerts in the reply's team block (team.alerts), as the
-- platform GUI and the game's alerts show them: hits on the platform's
-- entities (what, how much damage, by what), gun turrets empty or low on
-- ammo, no repair packs in the hub while it takes hits, the hub's health
-- falling, hits per minute rising. Addressed to the agent who created the
-- platform, the agents who last worked on it (requests naming platform=) and
-- anyone aboard; with none of them known, to every agent.
-- Hits are counted as damage events arrive (a few table writes each); the
-- rest is read when a reply is built, at most every 10 s per platform, and
-- kept in storage so every peer computes the same lines.
return function(api)
  local M = {}
  local SCAN_TICKS, KEEP_MINUTES, WORKERS, WORKER_TICKS = 600, 10, 3, 2 * 216000
  local LOW_AMMO = 10            -- rounds in a turret's ammo slots
  local CLEAR = 2 * 3600         -- a condition told comes back as news only after this long clear (batch28 B2)
  local FEED_TICKS = 3600        -- the ammunition trace (ammofeed.lua) read again after 1 min
  local DAMAGE_GAP = 3600        -- hit lines at most once a minute per reader and platform
  local HUB_HISTORY = 30         -- hub health samples kept (one per scan)
  local SLOW_KMS = 5             -- flying under this many km/s on two scans: the thrust alert
  -- (d20 batch60 V5, Astra #1594) the fuel alert: urgent at once under LOW_FUEL_MIN of a fluid at the rates now, or
  -- from SETTLE_S into the leg when the stock's own fall over the last WINDOW_S runs it out before the leg ends; else
  -- a projected shortage is an advisory, urgent once it holds on two scans WINDOW_S apart, both from SETTLE_S into the
  -- leg, with the stock lower at the second
  local LOW_FUEL_MIN, SETTLE_S, WINDOW_S, TREND_KEEP_S = 2, 90, 60, 300
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function round(v) return math.floor(v + 0.5) end
  local function ago(ticks)
    local sec = math.floor(ticks / 60)
    if sec >= 3600 then return string.format('%dh%02dm', math.floor(sec / 3600), math.floor(sec / 60) % 60) end
    if sec >= 60 then return string.format('%dm%02ds', math.floor(sec / 60), sec % 60) end
    return sec .. 's'
  end
  -- (batch28 B2, Luna: Swiftlet's zero-fuel alert came again after a reported recovery) a lasting condition is told
  -- once; again only when its state changes (another key) or it comes back after CLEAR clear, never because a count
  -- grew or time passed. seen[name]: the key told while it holds; name_last, name_clear: the last key and when it cleared.
  local function again(seen, name, key)
    local k = seen[name]
    if k == nil then
      local cleared = seen[name .. '_clear']
      if seen[name .. '_last'] == key and cleared and game.tick - cleared < CLEAR then seen[name] = key; return false end
      seen[name], seen[name .. '_last'], seen[name .. '_clear'] = key, key, nil
      return true
    end
    if k ~= key then seen[name], seen[name .. '_last'] = key, key; return true end
    return false
  end
  local function clear(seen, name)
    if seen[name] ~= nil then seen[name] = nil; seen[name .. '_clear'] = game.tick end
  end
  local function store()
    local s = api.state()
    s.platform_alerts = s.platform_alerts or {by={}}
    return s.platform_alerts
  end
  local function rec(pl)
    local by = store().by
    local r = by[pl.index]
    if not r then r = {minutes={}, workers={}, seq=0}; by[pl.index] = r end
    r.name = pl.name
    r.surface = try(function() return pl.surface.name end) or r.surface
    return r
  end
  local function counts(t, limit)
    local list = {}
    for name, n in pairs(t) do list[#list+1] = {name=name, n=n} end
    table.sort(list, function(x, y) if x.n ~= y.n then return x.n > y.n end return x.name < y.name end)
    local parts = {}
    for i = 1, math.min(#list, limit) do parts[i] = list[i].name .. ' ' .. round(list[i].n) end
    if #list > limit then parts[#parts+1] = '+' .. (#list - limit) .. ' more' end
    return table.concat(parts, ', ')
  end

  -- on_entity_damaged: a hit on one of our entities on a platform, by
  -- anything but our own force. Returns true when the hit was a platform's
  -- (threat.lua's planet incidents leave it alone).
  function M.on_damaged(event)
    local e = event.entity
    if not (e and e.valid) then return false end
    local own = e.force
    if not own or own.name == 'enemy' or own.name == 'neutral' then return false end
    local pl = e.surface.platform
    if not pl then return false end
    if event.force == own then return true end
    local r = rec(pl)
    local m = math.floor(event.tick / 3600)
    local b = r.minutes[m]
    if not b then
      b = {hits=0, damage=0, entities={}, by={}}
      r.minutes[m] = b
      for k in pairs(r.minutes) do if k <= m - KEEP_MINUTES then r.minutes[k] = nil end end
    end
    local d = event.final_damage_amount or 0
    local cause = event.cause and event.cause.valid and event.cause.name
    -- Per minute (rates, a reader's first look) and running totals (what is
    -- new since a reader was told: the difference from its snapshot).
    r.total = r.total or {hits=0, damage=0, entities={}, by={}}
    for _, t in ipairs{b, r.total} do
      t.hits = t.hits + 1; t.damage = t.damage + d
      t.entities[e.name] = (t.entities[e.name] or 0) + d
      if cause then t.by[cause] = (t.by[cause] or 0) + 1 end
    end
    r.seq = r.seq + 1; r.last_hit = event.tick
    return e.type ~= 'character'
  end

  -- A request naming platform= (or platform_create's new platform): who
  -- worked on it last, and who created it.
  function M.note(p, action, args, result)
    if action == 'platforms' then return end
    local name = args.platform
    if action == 'platform_create' and type(result) == 'table' then name = result.name end
    if type(name) ~= 'string' then return end
    for _, pl in pairs(p.force.platforms) do
      if pl.valid and pl.name == name then
        local r, who = rec(pl), api.who(p)
        if action == 'platform_create' then r.creator = who end
        r.workers[who] = game.tick
        local list = {}
        for n, t in pairs(r.workers) do list[#list+1] = {n=n, t=t} end
        table.sort(list, function(x, y) if x.t ~= y.t then return x.t > y.t end return x.n < y.n end)
        for i = WORKERS + 1, #list do r.workers[list[i].n] = nil end
        return
      end
    end
  end

  -- Whether agent `me` (name) hears about platform pl.
  local function addressed(pl, r, me)
    local any = false
    if r.creator then any = true; if r.creator == me then return true end end
    for n, t in pairs(r.workers) do
      if game.tick - t <= WORKER_TICKS then any = true; if n == me then return true end end
    end
    for _, a in ipairs(api.agents()) do
      local b = api.bot(a.index)
      local on
      if b then
        on = b.travel and b.travel.state == 'aboard' and b.travel.platform == pl.name
      else
        local p = api.lookup(a.index)
        local s = p and p.valid and (try(function() return p.physical_surface end) or try(function() return p.surface end))
        on = s and try(function() return s.platform end) == pl
      end
      if on then any = true; if a.name == me then return true end end
    end
    return not any
  end

  -- A platform's defence as the GUI shows it: its ammo turrets (empty, low,
  -- rounds loaded), the ammo and repair packs in the hub, the hub's health.
  local function read(pl)
    local sc = {tick=game.tick, turrets=0, empty=0, low=0, rounds=0, packs=0, hub_ammo={}}
    for _, t in ipairs(try(function() return pl.surface.find_entities_filtered{type='ammo-turret', force=pl.force} end) or {}) do
      local inv = try(function() return t.get_inventory(defines.inventory.turret_ammo) end)
      local n = inv and try(function() return inv.get_item_count() end) or 0
      sc.turrets = sc.turrets + 1; sc.rounds = sc.rounds + n
      if n == 0 then sc.empty = sc.empty + 1; sc.empty_list = sc.empty_list or {}; if #sc.empty_list < 8 then sc.empty_list[#sc.empty_list+1] = t end
      elseif n < LOW_AMMO then sc.low = sc.low + 1 end
      if n < 2 * LOW_AMMO then sc.under = (sc.under or 0) + 1 end
      if sc.turret_name and sc.turret_name ~= t.name then sc.turret_name = 'turret' else sc.turret_name = t.name end
    end
    local hub = pl.hub
    if hub and hub.valid then
      sc.health = try(function() return hub.health end); sc.max = try(function() return hub.max_health end)
      local inv = try(function() return hub.get_inventory(defines.inventory.hub_main) end)
      for _, st in ipairs(inv and try(function() return inv.get_contents() end) or {}) do
        local kind = try(function() return prototypes.item[st.name].type end)
        if kind == 'repair-tool' then sc.packs = sc.packs + st.count
        elseif kind == 'ammo' then sc.hub_ammo[st.name] = (sc.hub_ammo[st.name] or 0) + st.count end
      end
    end
    return sc
  end
  -- The ammo items a turret takes (its ammo categories), of those the hub holds.
  local function takes(turret, hub_ammo)
    local cats = {}
    for _, c in ipairs(try(function() return turret.prototype.attack_parameters.ammo_categories end) or {}) do cats[c] = true end
    local out = {}
    for name, n in pairs(hub_ammo) do
      local cat = try(function() local c = prototypes.item[name].ammo_category; return type(c) == 'string' and c or c.name end)
      if cat and cats[cat] and n > 0 then out[#out+1] = name .. '*' .. n end
    end
    table.sort(out)
    return out
  end
  local function at(pos) return string.format('(%g,%g)', pos.x, pos.y) end
  -- What feeds an empty turret (Sol, Astra 00:21-00:23: Starling's rear rocket turret starved while an ammo assembler's
  -- other output arm won): each inserter dropping into it, its pickup and what that holds of the turret's ammo, and the
  -- other inserters taking from the same source; or that no inserter feeds it.
  function M.turret_feed(turret)
    local s = turret.surface
    local p0 = turret.position
    local box = {left_top={x=p0.x-5, y=p0.y-5}, right_bottom={x=p0.x+5, y=p0.y+5}}
    local parts = {}
    local cats = {}
    for _, c in ipairs(try(function() return turret.prototype.attack_parameters.ammo_categories end) or {}) do cats[c] = true end
    local function its_ammo(name)
      if try(function() return prototypes.item[name].type end) ~= 'ammo' then return false end
      local cat = try(function() local c = prototypes.item[name].ammo_category; return type(c) == 'string' and c or c.name end)
      return next(cats) == nil or (cat and cats[cat]) or false
    end
    for _, i in ipairs(try(function() return s.find_entities_filtered{type='inserter', area=box, force=turret.force} end) or {}) do
      if try(function() return i.drop_target end) == turret then
        local src = try(function() return i.pickup_target end)
        local belt = src and src.valid and (src.type == 'transport-belt' or src.type == 'underground-belt' or src.type == 'splitter')
        local held = src and src.valid and (try(function()
          local n = 0
          local lists = {}
          if belt then for k = 1, src.get_max_transport_line_index() do lists[#lists+1] = src.get_transport_line(k).get_contents() end
          else lists[1] = src.get_output_inventory().get_contents() end
          for _, list in ipairs(lists) do
            for _, st in ipairs(list) do
              if its_ammo(st.name) then n = n + st.count end
            end
          end
          return n
        end) or 0) or 0
        local text = string.format('%s %s from %s', i.name, at(i.position), src and src.valid and (src.name .. ' ' .. at(src.position) ..
          string.format(belt and ' carrying %d of its ammo' or ' holding %d of its ammo', held)) or 'nothing (no pickup target)')
        if src and src.valid then
          local sp = src.position
          local others = {}
          for _, o in ipairs(try(function() return s.find_entities_filtered{type='inserter', area={left_top={x=sp.x-4, y=sp.y-4}, right_bottom={x=sp.x+4, y=sp.y+4}}, force=turret.force} end) or {}) do
            if o ~= i and try(function() return o.pickup_target end) == src then
              local d = try(function() return o.drop_target end)
              others[#others+1] = string.format('%s %s into %s', o.name, at(o.position), d and d.valid and (d.name .. ' ' .. at(d.position)) or 'nothing')
            end
          end
          if #others > 0 then text = text .. '; taking from it too: ' .. table.concat(others, ', ', 1, math.min(3, #others)) end
        end
        parts[#parts+1] = text
      end
    end
    return #parts > 0 and 'fed by ' .. table.concat(parts, ' | ') or 'no inserter drops into it'
  end
  -- Empty turrets that take ammo the hub holds: each with where it is and what feeds it (at most 4).
  function M.empty_turrets(pl, sc)
    sc = sc or read(pl)
    local out = {}
    for _, t in ipairs(sc.empty_list or {}) do
      if t.valid and #out < 4 then
        local hub_has = takes(t, sc.hub_ammo)
        if #hub_has > 0 then
          out[#out+1] = string.format('%s %s is empty while the hub holds %s it takes: %s', t.name, at(t.position), table.concat(hub_has, ' '), M.turret_feed(t))
        end
      end
    end
    return out
  end
  -- Ammo flow: what the turrets hold against what waits in the hub.
  local function ammo_text(sc)
    local hub = counts(sc.hub_ammo, 3)
    return string.format('turrets hold %d rounds, the hub %s', sc.rounds, hub ~= '' and hub or 'no ammo')
  end
  -- The platforms read's row (space.lua): fresh, not cached.
  function M.defense(pl)
    if not pl.surface then return nil end
    local sc = read(pl)
    return {hub_health=sc.health and sc.max and string.format('%d/%d', round(sc.health), round(sc.max)) or nil,
      turrets=sc.turrets > 0 and string.format('%d %s%s: %d empty, %d low (under %d rounds)', sc.turrets, sc.turret_name,
        sc.turrets == 1 and '' or 's', sc.empty, sc.low, LOW_AMMO) or 'none',
      ammo=ammo_text(sc)}
  end
  -- For the alerts: read at most every 10 s per platform.
  local function scan(pl, r)
    local sc = r.scan
    if sc and game.tick - sc.tick < SCAN_TICKS then return sc end
    sc = read(pl)
    do
      if sc.health then
        r.hub = r.hub or {}
        r.hub[#r.hub+1] = {tick=game.tick, health=sc.health}
        while #r.hub > HUB_HISTORY do table.remove(r.hub, 1) end
      end
    end
    -- Flying slowly (operator 10:53, Astra): under SLOW_KMS on a route leg, on
    -- this scan and the one before, with what the thrusters lack (thrust.lua).
    local moving = try(function() return pl.space_connection end) and pl.state == defines.space_platform_state.on_the_path
    local speed = try(function() return pl.speed end)
    if moving and type(speed) == 'number' and speed * 60 < SLOW_KMS then
      if r.slow_since and game.tick - r.slow_since >= SCAN_TICKS then
        sc.slow = {kms=math.floor(speed * 600 + 0.5) / 10, thrust=api.thrust and try(function() return api.thrust(pl) end),
          leg=try(function() return pl.space_connection.from.name .. '->' .. pl.space_connection.to.name end)}
      end
      r.slow_since = r.slow_since or game.tick
    else r.slow_since = nil end
    -- The fuel outlook flying (batch27 B1): a fluid that runs out before the leg ends.
    if moving and api.fuel_outlook then sc.fuel = try(function() return api.fuel_outlook(pl) end) end
    -- (V5) and each scan's stock of it this leg, for the trend
    if moving and sc.fuel then M.fuel_sample(r, sc.fuel, try(function() return pl.space_connection.from.name .. '->' .. pl.space_connection.to.name end) or '?')
    else r.fuel_trend = nil end
    r.scan = sc
    return sc
  end
  -- A scan's thruster fuel and oxidizer (held, of it in storage tanks, short or not) on r.fuel_trend, kept TREND_KEEP_S
  -- and started again on a new leg. s: seconds into the leg (from the departure the engine record has, else from the
  -- first scan of it: first_seen). A new leg: another connection, another departure (a connection flown back reads
  -- the same from and to: on the copy, nauvis->vulcanus both ways), or no scan for TREND_KEEP_S.
  function M.fuel_sample(r, fuel, leg)
    local ft = r.fuel_trend
    local since = fuel.since_departure_s
    local last = ft and ft.samples[#ft.samples]
    if not ft or ft.leg ~= leg or (since and not ft.first_seen and math.abs(game.tick - since * 60 - ft.start) > 600)
      or not last or game.tick - last.tick > TREND_KEEP_S * 60 then
      ft = {leg=leg, start=since and game.tick - since * 60 or game.tick, first_seen=not since or nil, samples={}}
      r.fuel_trend = ft
    elseif ft.first_seen and fuel.since_departure_s then
      ft.start, ft.first_seen = game.tick - fuel.since_departure_s * 60, nil
      for _, x in ipairs(ft.samples) do x.s = math.floor((x.tick - ft.start) / 60 + 0.5) end
    end
    local x = {tick=game.tick, s=math.floor((game.tick - ft.start) / 60 + 0.5), held={}, tanks={}, short={}}
    for _, row in ipairs(fuel.rows or {}) do x.held[row.name], x.tanks[row.name] = row.held, row.in_tanks end
    for _, n in ipairs(fuel.short or {}) do x.short[n] = true end
    ft.samples[#ft.samples+1] = x
    while #ft.samples > 1 and game.tick - ft.samples[1].tick > TREND_KEEP_S * 60 do table.remove(ft.samples, 1) end
  end
  -- How urgent a projected shortage is: 'urgent' or 'advisory', the reason, and the stock's trend in words.
  function M.fuel_level(r, fuel)
    local ft = r.fuel_trend
    local now = ft and ft.samples[#ft.samples]
    if not now then return 'urgent', 'no stock read this leg', nil end
    local rows = {}
    for _, row in ipairs(fuel.rows or {}) do rows[row.name] = row end
    -- the latest scan at least WINDOW_S before this one, and the trend from it (else from the leg's first scan)
    local w
    for i = #ft.samples - 1, 1, -1 do
      if now.tick - ft.samples[i].tick >= WINDOW_S * 60 then w = ft.samples[i]; break end
    end
    local base = w or ft.samples[1]
    local span = math.floor((now.tick - base.tick) / 60 + 0.5)
    local trend, rising = {}, true
    for _, n in ipairs(fuel.short) do
      local h0, h1 = base.held[n] or 0, now.held[n] or 0
      if h1 <= h0 then rising = false end
      trend[#trend+1] = span > 0 and string.format('%s held %d -> %d over the last %d s (storage tanks %d -> %d)', n, h0, h1, span, base.tanks[n] or 0, now.tanks[n] or 0)
        or string.format('%s held %d (storage tanks %d), one scan so far', n, h1, now.tanks[n] or 0)
    end
    trend = table.concat(trend, '; ')
    local at = ft.first_seen and 'since first seen under way' or 'into the leg'
    local why = {}
    for _, n in ipairs(fuel.short) do
      local row = rows[n]
      if row and row.lasts_min and row.lasts_min < LOW_FUEL_MIN then
        why[#why+1] = string.format('%s lasts %s at the rates now, under %d minutes', n, string.format('%dm%02ds', math.floor(row.lasts_min), math.floor((row.lasts_min % 1) * 60)), LOW_FUEL_MIN)
      end
    end
    if #why > 0 then return 'urgent', table.concat(why, '; '), trend end
    if now.s >= SETTLE_S and w then
      for _, n in ipairs(fuel.short) do
        local h0, h1 = w.held[n] or 0, now.held[n] or 0
        local per_min = (h0 - h1) / ((now.tick - w.tick) / 3600)
        if per_min > 0 and fuel.leg_left_min and h1 / per_min < fuel.leg_left_min then
          why[#why+1] = string.format('%s held fell %d -> %d in %d s: at that fall it lasts %.1f min, the leg %.1f', n, h0, h1, span, h1 / per_min, fuel.leg_left_min)
        elseif w.s >= SETTLE_S and w.short[n] and h1 < h0 then
          why[#why+1] = string.format('%s short on the scans at +%d s and +%d s %s, held %d -> %d', n, w.s, now.s, at, h0, h1)
        end
      end
      if #why > 0 then return 'urgent', table.concat(why, '; '), trend end
    end
    if now.s < SETTLE_S then return 'advisory', string.format('%d s %s, under %d', now.s, at, SETTLE_S), trend end
    if rising and span > 0 then return 'advisory', 'the stock rose', trend end
    if not w or w.s < SETTLE_S then return 'advisory', string.format('one window from %d s %s so far', SETTLE_S, at), trend end
    return 'advisory', 'the stock did not fall between two windows', trend
  end

  local function copy(t)
    local out = {hits=t.hits, damage=t.damage, entities={}, by={}}
    for n, v in pairs(t.entities) do out.entities[n] = v end
    for n, v in pairs(t.by) do out.by[n] = v end
    return out
  end
  -- Hits since a reader's snapshot of the totals; without one, the minutes
  -- of the last 10.
  local function hits(r, snap)
    local out = {hits=0, damage=0, entities={}, by={}}
    local function add(t, sign)
      out.hits = out.hits + sign * t.hits; out.damage = out.damage + sign * t.damage
      for n, d in pairs(t.entities) do out.entities[n] = (out.entities[n] or 0) + sign * d end
      for n, c in pairs(t.by) do out.by[n] = (out.by[n] or 0) + sign * c end
    end
    if snap then add(r.total, 1); add(snap, -1)
    else for _, b in pairs(r.minutes) do add(b, 1) end end
    for _, t in ipairs{out.entities, out.by} do
      for n, v in pairs(t) do if v <= 0 then t[n] = nil end end
    end
    return out
  end
  local function minute(r, m) local b = r.minutes[m]; return b and b.hits or 0 end

  -- status alerts.platform_hits: per platform hit after `since` (whole
  -- minutes, at most the last 10): {platform, surface, hits, damage,
  -- entities, by, last_tick}, most recent first.
  function M.rows(since)
    local out = {}
    for _, r in pairs(store().by) do
      if r.last_hit and r.last_hit > since then
        local x = {hits=0, damage=0, entities={}, by={}}
        for m, b in pairs(r.minutes) do
          if m >= math.floor(since / 3600) then
            x.hits = x.hits + b.hits; x.damage = x.damage + b.damage
            for n, d in pairs(b.entities) do x.entities[n] = (x.entities[n] or 0) + d end
            for n, c in pairs(b.by) do x.by[n] = (x.by[n] or 0) + c end
          end
        end
        out[#out+1] = {platform=r.name, surface=r.surface, hits=x.hits, damage=round(x.damage), entities=counts(x.entities, 5),
          by=next(x.by) and counts(x.by, 3) or nil, last_tick=r.last_hit}
      end
    end
    table.sort(out, function(a, b) return a.last_tick > b.last_tick end)
    return #out > 0 and out or nil
  end
  -- Whether p hears about the platform named `name` (urgent.lua: hub damage and losses wake those it would tell).
  -- (d18 batch37 B3) the agents who hear about platform pl, by name and index
  function M.listeners(pl)
    local out = {}
    local r = rec(pl)
    for _, a in ipairs(api.agents()) do
      if addressed(pl, r, a.name) then out[#out+1] = {name=a.name, index=a.index} end
    end
    return out
  end
  function M.hears(p, name)
    local me = api.who(p)
    for _, pl in pairs(p.force.platforms) do
      if pl.valid and pl.name == name then return addressed(pl, rec(pl), me) end
    end
    return false
  end
  -- The lines for agent p; h is its hint state (board.lua).
  function M.lines(p, h)
    local by = store().by
    local me = api.who(p)
    local lines = {}
    h.platforms = h.platforms or {}
    for _, pl in pairs(p.force.platforms) do
      local r = pl.valid and pl.surface and by[pl.index]
      if not r and pl.valid and pl.surface then r = rec(pl) end
      if r and addressed(pl, r, me) then
        local seen = h.platforms[pl.index] or {}
        h.platforms[pl.index] = seen
        -- Every line names the platform and its surface (status alerts rows:
        -- platform, surface; ground alerts name a surface the same way).
        local name = pl.name .. ' (surface ' .. pl.surface.name .. ')'
        local sc = scan(pl, r)
        -- Hits since this reader was last told (first look: the last 10 minutes).
        if r.seq > (seen.seq or 0) and r.total and game.tick - (seen.hit_tick or -DAMAGE_GAP) >= DAMAGE_GAP then
          local x = hits(r, seen.snap)
          if x.hits > 0 then
            lines[#lines+1] = string.format('platform %s hit %d times, %d damage, last %s ago: %s%s', name, x.hits, round(x.damage),
              ago(game.tick - (r.last_hit or game.tick)), counts(x.entities, 5), next(x.by) and '; by ' .. counts(x.by, 3) or '')
          end
          seen.seq, seen.hit_tick, seen.snap = r.seq, game.tick, copy(r.total)
        end
        -- Hits per minute rising: the last full minute against the 5 before.
        local now_m = math.floor(game.tick / 3600)
        local last = minute(r, now_m - 1)
        local base = 0
        for m = now_m - 6, now_m - 2 do base = base + minute(r, m) end
        base = base / 5
        if last >= 10 and last >= 2 * base + 5 then
          if again(seen, 'rising', 'on') then
            lines[#lines+1] = string.format('platform %s: hits per minute rising, %d in the last minute, %g a minute over the 5 before', name, last, math.floor(base * 10 + 0.5) / 10)
          end
        else clear(seen, 'rising') end
        -- Turrets empty or low, with the ammo flow: what the turrets hold
        -- against what waits in the hub (Kestrel: 920 in the hub, 4 of 5 empty).
        local level = sc.empty * 1000 + sc.low
        if level > 0 then
          if again(seen, 'turrets', sc.empty >= sc.turrets and 'all empty' or sc.empty > 0 and 'empty' or 'low') then
            local feeds = sc.empty > 0 and try(function() return M.empty_turrets(pl, sc) end) or {}
            lines[#lines+1] = string.format('platform %s: %d of %d %s%s empty%s; %s%s', name, sc.empty, sc.turrets, sc.turret_name or 'turret', sc.turrets == 1 and '' or 's',
              sc.low > 0 and string.format(', %d low (under %d rounds)', sc.low, LOW_AMMO) or '', ammo_text(sc), #feeds > 0 and '; ' .. table.concat(feeds, '; ') or '')
          end
        else clear(seen, 'turrets') end
        -- Feeds running dry while the platform's total looks enough (d17 batch13 B1, Kestrel: the bow turrets ran empty
        -- while hundreds of magazines sat on a rear loop): turrets with nothing more coming (no ammo on the way to them
        -- and nothing that loads it) and under 20 rounds, while 20 or more aboard are stranded or in the hub. Read with
        -- the scan (ammofeed.lua), told once while it lasts (batch28 B2).
        -- (d17 batch23 A2: the trace cost 180 ms on Kestrel II and ran every scan) traced only while a turret holds
        -- under 2 * LOW_AMMO (none can starve otherwise), at most once a minute
        if api.ammofeed and sc.turrets > 0 and (sc.under or 0) > 0 then
          local fr = r.feed
          if not (fr and game.tick - fr.tick < FEED_TICKS) then
            -- (A2) a large platform's trace comes from the background read; while it runs, the next scan asks again
            local okt, tr = pcall(api.ammofeed.trace, pl, FEED_TICKS)
            fr = {tick=game.tick, tr=okt and tr or nil}
            if fr.tr then r.feed = fr end
          end
          local tr = fr.tr
          local starving, x0, y0, x1, y1 = {}, math.huge, math.huge, -math.huge, -math.huge
          for _, row in ipairs(tr and tr.rows or {}) do
            if row.reaches == row.own and row.own < 2 * LOW_AMMO then
              starving[#starving+1] = row
              local q = row.position
              x0, y0, x1, y1 = math.min(x0, q.x), math.min(y0, q.y), math.max(x1, q.x), math.max(y1, q.y)
            end
          end
          local spare = tr and (tr.stranded + (tr.hub_reaches and 0 or tr.hub_ammo)) or 0
          if #starving > 0 and spare >= 2 * LOW_AMMO then
            if again(seen, 'starving', 'on') then
              local first = starving[1]
              lines[#lines+1] = string.format('platform %s: %d turret%s in (%g,%g)-(%g,%g) can reach under %d rounds and nothing more comes (%s %s: %s) while %d aboard can reach no turret%s; platform_defense {platform: "%s"} traces each feed',
                name, #starving, #starving == 1 and '' or 's', x0, y0, x1, y1, 2 * LOW_AMMO, first.name, at(first.position),
                #first.stops > 0 and first.stops[1] or first.gated and first.gated[1] or 'its feed is dry', spare,
                #tr.stranded_groups > 0 and ' (on belts: ' .. table.concat(tr.stranded_groups, '; ', 1, math.min(3, #tr.stranded_groups)) .. ')' or ' (in the hub, no inserter takes it toward a turret)', pl.name)
            end
          else clear(seen, 'starving') end
        end
        -- Flying under 5 km/s: which thrusters lack which input, and the chain behind it.
        if sc.slow then
          local t = sc.slow.thrust
          local why
          if not t or t.count == 0 then why = 'it has no thrusters'
          elseif #t.lines > 0 then why = table.concat(t.lines, ' | ')
          else why = string.format('no thruster tank is under half (lowest: %s); %d thruster%s', api.thrust_lowest and api.thrust_lowest(t) or '?', t.count, t.count == 1 and '' or 's') end
          local key = (sc.slow.kms < 0 and 'back|' or 'slow|') .. (t and table.concat(t.lines, '|'):gsub('%d+%%', '') or 'none')
          if again(seen, 'slow', key) then
            lines[#lines+1] = string.format('platform %s flies at %g km/s (under %d%s) on %s: %s', name, sc.slow.kms, SLOW_KMS,
              sc.slow.kms < 0 and '; backwards along its leg' or '', sc.slow.leg or '?', why)
          end
        else clear(seen, 'slow') end
        -- Thruster fuel or oxidizer running out before the leg ends (batch27 B1, Luna).
        if sc.fuel and sc.fuel.short then
          -- (d20 batch60 V5) urgent or an advisory (fuel_level); an advisory is told once, whichever fluid it names
          local level, why, trend = M.fuel_level(r, sc.fuel)
          local key = level == 'urgent' and 'urgent|' .. table.concat(sc.fuel.short, '|') or 'advisory'
          if again(seen, 'fuel', key) then
            local pumps = {}
            local ps = api.pump_states and try(function() return api.pump_states(pl) end) or {}
            for _, n in ipairs(sc.fuel.short) do if ps[n] then pumps[#pumps+1] = n .. ' pumps ' .. ps[n].line end end
            local v = try(function() return pl.speed end)
            local state = (trend and '; stock: ' .. trend or '') .. (#pumps > 0 and '; ' .. table.concat(pumps, '; ') or '')
              .. (type(v) == 'number' and string.format('; speed now %g km/s', math.floor(v * 600 + 0.5) / 10) or '')
            -- (d20 batch54 N1) with the time since it left its stop and the engine's 60 and 180 s samples side by side
            if level == 'urgent' then
              lines[#lines+1] = string.format('platform %s: urgent: %s runs out before the leg ends (%s): %s%s%s', name, table.concat(sc.fuel.short, ' and '), why, sc.fuel.line,
                state, sc.fuel.since_line and '; ' .. sc.fuel.since_line or '')
            else
              lines[#lines+1] = string.format('platform %s: advisory: %s projected to run out before the leg ends at the last minute\'s rates (%s; urgent under %d minutes of it, '
                .. 'on a fall that runs it out, or when short on two scans %d s apart from %d s into the leg with the stock lower): %s%s%s', name, table.concat(sc.fuel.short, ' and '), why,
                LOW_FUEL_MIN, WINDOW_S, SETTLE_S, sc.fuel.line, state, sc.fuel.since_line and '; ' .. sc.fuel.since_line or '')
            end
          end
        else clear(seen, 'fuel') end
        -- No repair packs while it takes hits.
        local recent = r.last_hit and game.tick - r.last_hit <= KEEP_MINUTES * 3600
        if sc.packs == 0 and pl.hub and pl.hub.valid and (recent or (sc.health and sc.max and sc.health < sc.max)) then
          if again(seen, 'packs', 'on') then
            lines[#lines+1] = string.format('platform %s: no repair packs in the hub (the game repairs platform entities only with hub repair packs)%s', name,
              recent and ', and it was hit ' .. ago(game.tick - r.last_hit) .. ' ago' or '')
          end
        else clear(seen, 'packs') end
        -- The hub's health falling: below this reader's baseline (what it was
        -- last told, raised when the hub is repaired), else below the
        -- earliest sample of the last 5 minutes.
        if sc.health and sc.max and sc.health < sc.max then
          local base = seen.hub and {health=seen.hub, tick=seen.hub_at}
          if not base then for _, s in ipairs(r.hub or {}) do if game.tick - s.tick <= 5 * 3600 then base = s; break end end end
          if base and sc.health > base.health then seen.hub, seen.hub_at = sc.health, game.tick
          elseif base and sc.health < base.health - 0.5 and game.tick - (seen.hub_tick or -DAMAGE_GAP) >= DAMAGE_GAP then
            lines[#lines+1] = string.format('platform %s hub health %d/%d, down %d in %s', name, round(sc.health), round(sc.max),
              round(base.health - sc.health), ago(game.tick - base.tick))
            seen.hub, seen.hub_at, seen.hub_tick = sc.health, game.tick, game.tick
          end
        else seen.hub = nil end
      end
    end
    -- Platforms that stopped at or left this agent's planet (freight.lua; Gemini, 16:50).
    for _, line in ipairs(api.platform_events and api.platform_events(p, h) or {}) do lines[#lines+1] = line end
    -- Platforms gone: forget them.
    for index in pairs(h.platforms) do
      local ok = false
      for _, pl in pairs(p.force.platforms) do if pl.valid and pl.index == index then ok = true; break end end
      if not ok then h.platforms[index] = nil end
    end
    return #lines > 0 and lines or nil
  end
  return M
end
