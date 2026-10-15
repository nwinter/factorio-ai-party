-- danger {position, radius?, surface?}: what the map and the character show about a destination before a trip there
-- (Opus, shift17 10:51: "a pre-trip danger check ... the live enemy units near a destination (spitter groups, nest
-- distance) against my armor and HP"; he died twice walking to sites next to nests). Facts only, no verdict:
--   nests: the worms and spawners on charted chunks within radius of it (avoid.lua's per-chunk read, kept a minute), by
--     name, with each kind's reach (a worm's range, a spawner's units' sight) and the nearest's distance;
--   units: enemy units in chunks our force sees now within radius (what the map shows live), by name, nearest;
--   attacks, losses, groups: our structures hit (last 10 min), buildings lost (last 10 min) and enemy groups gathered
--     heading within radius (last 10 min), from what the harness keeps (threat.lua, losses);
--   deaths: our characters' deaths within radius (the chronicle, the run so far);
--   on the way: the nests within their reach of the straight line from the character to it (not the walk's path);
--   you: health, armor, the armor's shield.
-- Bounded: radius up to 128; at most 64 chunks of worms and spawners read a call (the rest named as not read); one
-- bounded unit query.
return function(api)
  local M = {}
  local MAX_R, CHUNKS, WINDOW = 128, 64, 10 * 3600
  local function try(f) local ok, v = pcall(f); if ok then return v end end
  local function dist(a, b) return ((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2) ^ 0.5 end
  local function round(v) return math.floor(v + 0.5) end
  local function at(q) return string.format('(%d,%d)', round(q.x), round(q.y)) end
  local function ago(t) local s = math.floor(t / 60); return s >= 60 and string.format('%dm%02ds', math.floor(s / 60), s % 60) or s .. 's' end
  local function counts(map)
    local list = {}
    for k, n in pairs(map) do list[#list+1] = {k=k, n=n} end
    table.sort(list, function(a, b) return a.n > b.n or (a.n == b.n and a.k < b.k) end)
    local parts = {}
    for i, x in ipairs(list) do if i <= 6 then parts[#parts+1] = x.n .. ' ' .. x.k end end
    return table.concat(parts, ', ') .. (#list > 6 and ', ...' or '')
  end
  local function hostile(force)
    local out = {}
    for _, f in pairs(game.forces) do
      if f ~= force and f.name ~= 'neutral' and not try(function() return force.get_friend(f) or force.get_cease_fire(f) end) then out[#out+1] = f.name end
    end
    return out
  end
  local function chunks_round(pos, r)
    local out = {}
    for cx = math.floor((pos.x - r) / 32), math.floor((pos.x + r) / 32) do
      for cy = math.floor((pos.y - r) / 32), math.floor((pos.y + r) / 32) do
        out[#out+1] = {cx, cy, (cx + 524288) * 1048576 + (cy + 524288)}
      end
    end
    return out
  end
  function M.read(p, a)
    local pos = api.position(a.position)
    local r = a.radius == nil and 64 or a.radius
    assert(type(r) == 'number' and r >= 8 and r <= MAX_R, 'radius is 8..128 tiles')
    local s = a.surface and api.surface(p, a.surface) or p.surface
    local f = p.force
    local c = p.character
    local here = c and c.valid and c.surface == s and {x=c.position.x, y=c.position.y} or nil
    local out = {position={x=pos.x, y=pos.y}, surface=s.name, radius=r, lines={}}
    local lines = out.lines
    out.distance = here and round(dist(here, pos)) or nil
    lines[#lines+1] = string.format('%s on %s%s', at(pos), s.name, here and string.format(', %d tiles from you', out.distance) or '')
    -- Worms and spawners round it (charted chunks).
    local near = chunks_round(pos, r)
    local got = api.avoid.structures(s, f, near, CHUNKS)
    local worms, spawners, wn, sn, wreach = {}, {}, nil, nil, {}
    for _, e in ipairs(got.list) do
      local d = dist(e, pos)
      if d <= r then
        if e.spawner then spawners[e.name] = (spawners[e.name] or 0) + 1; if not sn or d < sn.d then sn = {d=d, e=e} end
        else worms[e.name] = (worms[e.name] or 0) + 1; wreach[e.name] = api.avoid.reach(e.name); if not wn or d < wn.d then wn = {d=d, e=e} end end
      end
    end
    out.spawners = next(spawners) and spawners or nil
    out.worms = next(worms) and worms or nil
    if sn then lines[#lines+1] = string.format('spawners within %d tiles: %s; nearest %s at %s, %d tiles from it (its units see %d tiles)', r, counts(spawners),
      sn.e.name, at(sn.e), round(sn.d), api.avoid.reach(sn.e.name, true)) end
    if wn then
      local reach = {}
      for n, rr in pairs(wreach) do reach[#reach+1] = string.format('%s range %d', n, rr) end
      table.sort(reach)
      lines[#lines+1] = string.format('worms within %d tiles: %s (%s); nearest %s at %s, %d tiles from it', r, counts(worms), table.concat(reach, ', '),
        wn.e.name, at(wn.e), round(wn.d))
    end
    if not sn and not wn then lines[#lines+1] = string.format('no worm or spawner on the charted chunks within %d tiles', r) end
    if got.uncharted > 0 or got.unread > 0 then
      lines[#lines+1] = string.format('not read: %d uncharted chunk%s, %d over this call\'s %d-chunk read', got.uncharted, got.uncharted == 1 and '' or 's', got.unread, CHUNKS)
    end
    -- Enemy units seen now (visible chunks only).
    local units, un, unseen = {}, nil, 0
    local visible = {}
    for _, ch in ipairs(near) do
      if try(function() return f.is_chunk_visible(s, {x=ch[1], y=ch[2]}) end) then visible[ch[3]] = true else unseen = unseen + 1 end
    end
    if next(visible) then
      for _, e in ipairs(try(function() return s.find_entities_filtered{position=pos, radius=r, type='unit', force=hostile(f), limit=500} end) or {}) do
        local cx, cy = math.floor(e.position.x / 32), math.floor(e.position.y / 32)
        if visible[(cx + 524288) * 1048576 + (cy + 524288)] then
          units[e.name] = (units[e.name] or 0) + 1
          local d = dist(e.position, pos)
          if not un or d < un.d then un = {d=d, e=e} end
        end
      end
    end
    out.units = next(units) and units or nil
    lines[#lines+1] = un and string.format('enemy units seen now within %d tiles: %s; nearest %s %d tiles from it', r, counts(units), un.e.name, round(un.d))
      or string.format('no enemy unit seen now within %d tiles', r)
    if unseen > 0 then lines[#lines+1] = string.format('%d of the %d chunks round it are not in sight of our force now (units there are not seen)', unseen, #near) end
    -- Attacks, losses and groups lately.
    local st = api.state()
    local hits, last
    for _, v in pairs(st.damage or {}) do
      if v.at and (v.surface or 'nauvis') == s.name and game.tick - (v.last or 0) <= WINDOW and dist(v.at, pos) <= r then
        hits = (hits or 0) + 1
        if not last or v.last > last.last then last = v end
      end
    end
    if hits then lines[#lines+1] = string.format('attacks on our structures within %d tiles in the last 10 min: %d; latest %s ago at %s', r, hits, ago(game.tick - last.last), at(last.at)) end
    local lost, lostn = 0, {}
    for _, i in ipairs(st.losses or {}) do
      local b = i.box
      if b and i.surface == s.name and game.tick - (i.last or i.first or 0) <= WINDOW and dist({x=(b[1] + b[3]) / 2, y=(b[2] + b[4]) / 2}, pos) <= r then
        lost = lost + (i.total or 0)
        for n, k in pairs(i.names or {}) do lostn[n] = (lostn[n] or 0) + k end
      end
    end
    if lost > 0 then lines[#lines+1] = string.format('buildings lost within %d tiles in the last 10 min: %d (%s)', r, lost, counts(lostn)) end
    local groups = 0
    for _, g in ipairs(st.attack_groups or {}) do
      if g.target and (g.surface or 'nauvis') == s.name and game.tick - g.tick <= WINDOW and dist(g.target, pos) <= r then groups = groups + (g.size or 0) end
    end
    if groups > 0 then lines[#lines+1] = string.format('enemy groups gathered heading within %d tiles in the last 10 min: %d enemies', r, groups) end
    -- Our deaths there.
    local deaths = {}
    for _, e in ipairs(st.chronicle and st.chronicle.events or {}) do
      if e.kind == 'death' and e.surface == s.name and e.position and dist(e.position, pos) <= r then
        deaths[#deaths+1] = string.format('%s %s%s', tostring(e.agent), e.game_time or ago(game.tick - (e.tick or 0)) .. ' ago', e.by and ' (' .. e.by .. ')' or '')
      end
    end
    if #deaths > 0 then lines[#lines+1] = string.format('deaths of ours within %d tiles: %d: %s', r, #deaths, table.concat(deaths, '; ', math.max(1, #deaths - 3))) end
    -- On the straight line from you.
    if here and out.distance and out.distance > 0 then
      local path = api.avoid.chunks_near({here, pos}, 48)
      local passed = {}
      if #path <= 4 * CHUNKS then
        local onway = api.avoid.structures(s, f, path, CHUNKS)
        for _, e in ipairs(onway.list) do
          local reach = api.avoid.reach(e.name, e.spawner)
          local d = api.avoid.seg_dist(here, pos, e)
          if d <= reach and dist(e, pos) > r then passed[#passed+1] = {e=e, d=d, reach=reach} end
        end
        table.sort(passed, function(x, y) return x.d - x.reach < y.d - y.reach end)
        if #passed > 0 then
          local x = passed[1]
          lines[#lines+1] = string.format('the straight line from you passes within reach of %d worm%s or spawner%s outside that radius; closest %s at %s, %d tiles from the line (reach %d)',
            #passed, #passed == 1 and '' or 's', #passed == 1 and '' or 's', x.e.name, at(x.e), round(x.d), x.reach)
        else
          lines[#lines+1] = 'the straight line from you passes within reach of no worm or spawner on the charted chunks read'
        end
        if onway.unread > 0 then lines[#lines+1] = string.format('%d chunks along the line not read in this call', onway.unread) end
      else
        lines[#lines+1] = 'the straight line from you is too long to read in one call'
      end
    end
    -- You.
    if c and c.valid then
      local max = try(function() return c.max_health end) or try(function() return c.prototype.get_max_health() end) or try(function() return c.prototype.max_health end)
      local armor = try(function() local inv = c.get_inventory(defines.inventory.character_armor); return inv and inv[1].valid_for_read and inv[1].name end)
      local grid = try(function() return c.grid end)
      local shield = grid and try(function() return grid.shield end)
      local smax = grid and try(function() return grid.max_shield end)
      out.you = {health=round(c.health), max_health=max and round(max) or nil, armor=armor or nil, shield=shield and round(shield) or nil, max_shield=smax and round(smax) or nil}
      lines[#lines+1] = string.format('you: health %d%s, %s%s', round(c.health), max and '/' .. round(max) or '', armor and 'armor ' .. armor or 'no armor',
        smax and smax > 0 and string.format(', shield %d/%d', round(shield or 0), round(smax)) or '')
    else
      lines[#lines+1] = 'you: no character on a planet now'
    end
    out.line = table.concat(lines, '; ')
    return out
  end
  return M
end
