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
  local REPEAT = 5 * 3600        -- a condition that lasts is told again after 5 min
  local DAMAGE_GAP = 3600        -- hit lines at most once a minute per reader and platform
  local HUB_HISTORY = 30         -- hub health samples kept (one per scan)
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function round(v) return math.floor(v + 0.5) end
  local function ago(ticks)
    local sec = math.floor(ticks / 60)
    if sec >= 3600 then return string.format('%dh%02dm', math.floor(sec / 3600), math.floor(sec / 60) % 60) end
    if sec >= 60 then return string.format('%dm%02ds', math.floor(sec / 60), sec % 60) end
    return sec .. 's'
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

  -- Turrets, the hub's repair packs and health: read at most every 10 s.
  local function scan(pl, r)
    local sc = r.scan
    if sc and game.tick - sc.tick < SCAN_TICKS then return sc end
    sc = {tick=game.tick, turrets=0, empty=0, low=0, packs=0}
    for _, t in ipairs(try(function() return pl.surface.find_entities_filtered{type='ammo-turret', force=pl.force} end) or {}) do
      local inv = try(function() return t.get_inventory(defines.inventory.turret_ammo) end)
      local n = inv and try(function() return inv.get_item_count() end) or 0
      sc.turrets = sc.turrets + 1
      if n == 0 then sc.empty = sc.empty + 1 elseif n < LOW_AMMO then sc.low = sc.low + 1 end
      sc.turret_name = sc.turret_name or t.name
    end
    local hub = pl.hub
    if hub and hub.valid then
      sc.health = try(function() return hub.health end); sc.max = try(function() return hub.max_health end)
      local inv = try(function() return hub.get_inventory(defines.inventory.hub_main) end)
      for _, st in ipairs(inv and try(function() return inv.get_contents() end) or {}) do
        if try(function() return prototypes.item[st.name].type end) == 'repair-tool' then sc.packs = sc.packs + st.count end
      end
      if sc.health then
        r.hub = r.hub or {}
        r.hub[#r.hub+1] = {tick=game.tick, health=sc.health}
        while #r.hub > HUB_HISTORY do table.remove(r.hub, 1) end
      end
    end
    r.scan = sc
    return sc
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
        local name = pl.name
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
          if last >= 1.5 * (seen.rising or 0) or game.tick - (seen.rising_tick or -REPEAT) >= REPEAT then
            lines[#lines+1] = string.format('platform %s: hits per minute rising, %d in the last minute, %g a minute over the 5 before', name, last, math.floor(base * 10 + 0.5) / 10)
            seen.rising, seen.rising_tick = last, game.tick
          end
        else seen.rising = nil end
        -- Turrets empty or low.
        local level = sc.empty * 1000 + sc.low
        if level > 0 then
          if level > (seen.turrets or 0) or game.tick - (seen.turrets_tick or -REPEAT) >= REPEAT then
            lines[#lines+1] = string.format('platform %s: %d of %d %s%s empty%s', name, sc.empty, sc.turrets, sc.turret_name or 'turret', sc.turrets == 1 and '' or 's',
              sc.low > 0 and string.format(', %d low (under %d rounds)', sc.low, LOW_AMMO) or '')
            seen.turrets, seen.turrets_tick = level, game.tick
          end
        else seen.turrets = nil end
        -- No repair packs while it takes hits.
        local recent = r.last_hit and game.tick - r.last_hit <= KEEP_MINUTES * 3600
        if sc.packs == 0 and pl.hub and pl.hub.valid and (recent or (sc.health and sc.max and sc.health < sc.max)) then
          if game.tick - (seen.packs_tick or -REPEAT) >= REPEAT then
            lines[#lines+1] = string.format('platform %s: no repair packs in the hub (the game repairs platform entities only with hub repair packs)%s', name,
              recent and ', and it was hit ' .. ago(game.tick - r.last_hit) .. ' ago' or '')
            seen.packs_tick = game.tick
          end
        else seen.packs_tick = nil end
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
