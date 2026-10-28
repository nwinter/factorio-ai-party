-- sharedroutes: checked routes shared across agents and shifts, read again before reuse (d28 batch305 NR, Updates row
-- nav-shared-routes, viewer Aurora; the design in batch243's report, item 5). A path the pathfinder found for a
-- spidertron round water (spiderpath.lua) or for a car's or tank's turning room (vehicles.lua) is kept in harness
-- storage, so it stays in the world for every agent and for the shifts after:
-- - its points (a spidertron's as its route was thinned; a drive's corners, its legs cut to PIECE tiles), the surface,
--   the kind (spider: its legs, BOX and the doodad layer; drive: the box half-size and the vehicle's collision layers),
--   who asked for it, when (asked), and the shift;
-- - for each leg (a straight line between two points): its fingerprint, the tile under each point spiderpath.segment
--   reads on that line (one a tile, k = 0..ceil(length)), as runs of tile codes; and for a drive, its corridor counts:
--   the entities whose layers meet the vehicle's (movers left out: MOVERS) and the tiles that do, in the leg's box
--   widened by the vehicle's half-size.
-- check(route) reads each leg again. A leg is stale when:
-- - a fingerprint tile differs (said: where, what it was and what it is now);
-- - (a drive) a corridor count differs, or a chunk within the leg's box (plus MARK_MARGIN) was marked after the leg was
--   read: something built, mined or destroyed there, or a tile changed (mark; equal counts can hide one removed and
--   one built);
-- - and the whole route is stale once it was asked over MAX_AGE ticks ago.
-- The caller asks the pathfinder again for the stale legs only and splices the new path in; the rest is reused.
-- A spidertron's legs step over entities (its paths are asked with the doodad layer, which no building has), so its
-- legs are read by tiles only. Its fingerprint holds every tile segment() reads, so an unchanged fingerprint reads as
-- it did when the path was found; marks are not needed for it.
-- Storage: at most MAX_ROUTES routes (the one used or saved longest ago is evicted first), each with at most MAX_LEGS
-- legs and MAX_TILES tiles (a longer path is not kept); a new route from and to the same places (within NEAR) replaces
-- the old one. Marks are kept only on surfaces that hold a route, at most DIRTY_MAX; over that, the marks older than
-- every route's legs there are dropped, and if still over, the whole surface counts as marked at that tick.
-- Facts only; nothing in the game is changed here.
return function(api)
  local M = {}
  M.VERSION = 1
  M.MAX_ROUTES, M.MAX_LEGS, M.MAX_AGE, M.PIECE, M.NEAR = 100, 240, 432000, 16, 8
  -- a check reads about one tile per tile of route (and a drive's counts per leg): longer routes are not kept
  M.MAX_TILES = 3000
  M.DIRTY_MAX, M.MARK_MARGIN = 4096, 6
  -- Types left out of a drive's corridor counts: they move, or are gone soon (units, characters, vehicles, trains,
  -- spider legs, corpses, items on the ground, ghosts, robots, projectiles, fire)
  M.MOVERS = {'character', 'unit', 'car', 'spider-vehicle', 'spider-leg', 'spider-unit', 'segmented-unit', 'segment',
    'locomotive', 'cargo-wagon', 'fluid-wagon', 'artillery-wagon', 'infinity-cargo-wagon', 'corpse', 'character-corpse',
    'item-entity', 'entity-ghost', 'tile-ghost', 'item-request-proxy', 'combat-robot', 'construction-robot',
    'logistic-robot', 'capture-robot', 'projectile', 'fire', 'sticker', 'fish', 'cargo-pod'}
  local MOVING = {}
  for _, t in ipairs(M.MOVERS) do MOVING[t] = true end
  local floor, ceil, max, min, fmt = math.floor, math.ceil, math.max, math.min, string.format
  local unpack = table.unpack
  local function dist(a, b) return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2) end
  local function at(q) return fmt('(%g,%g)', floor(q.x * 10 + 0.5) / 10, floor(q.y * 10 + 0.5) / 10) end
  local function ago(t)
    local s = floor(t / 60)
    if s < 60 then return s .. 's' end
    if s < 3600 then return fmt('%dm%02ds', floor(s / 60), s % 60) end
    return fmt('%dh%02dm', floor(s / 3600), floor(s / 60) % 60)
  end
  M.ago, M.at = ago, at
  local function store()
    local s = api.state()
    local r = s.sharedroutes
    if not r or r.v ~= M.VERSION then
      r = {v=M.VERSION, seq=r and r.seq or 0, routes={}, count=0, codes={}, names={}, dirty={}, all={}, ndirty=0, on={}}
      s.sharedroutes = r
    end
    return r
  end
  M.store = store
  -- A chunk's key: one number (a string key costs a number-to-text each)
  local function key(cx, cy) return (cx + 32768) * 65536 + (cy + 32768) end
  local function unkey(k) return floor(k / 65536) - 32768, k % 65536 - 32768 end
  -- The leg's box: the line a -> b widened by h
  local function box(a, b, h)
    return {{min(a.x, b.x) - h, min(a.y, b.y) - h}, {max(a.x, b.x) + h, max(a.y, b.y) + h}}
  end
  -- The fingerprint of the straight line a -> b: the tile at each point segment() reads, runs of (code, count) as 3
  -- bytes each (code in two, count up to 255).
  function M.fingerprint(surface, a, b)
    local r = store()
    local codes, names = r.codes, r.names
    local n = max(1, ceil(dist(a, b)))
    local buf, last, run = {}, nil, 0
    local dx, dy = b.x - a.x, b.y - a.y
    for k = 0, n do
      local t = surface.get_tile(a.x + dx * k / n, a.y + dy * k / n)
      local name = t.valid and t.name or 'invalid'  -- (copy: off the generated map the tile is invalid)
      local c = codes[name]
      if not c then c = #names + 1; names[c] = name; codes[name] = c end
      if c == last and run < 255 then
        run = run + 1
      else
        if last then buf[#buf + 1] = floor(last / 256); buf[#buf + 1] = last % 256; buf[#buf + 1] = run end
        last, run = c, 1
      end
    end
    buf[#buf + 1] = floor(last / 256); buf[#buf + 1] = last % 256; buf[#buf + 1] = run
    return string.char(unpack(buf))
  end
  -- The first point of a -> b whose tile is not the fingerprint's: {at, was, now}, or nil.
  function M.diff(surface, a, b, fp)
    local r = store()
    local n = max(1, ceil(dist(a, b)))
    local k = 0
    for i = 1, #fp, 3 do
      local c = fp:byte(i) * 256 + fp:byte(i + 1)
      for _ = 1, fp:byte(i + 2) do
        if k > n then return nil end
        local q = {x=a.x + (b.x - a.x) * k / n, y=a.y + (b.y - a.y) * k / n}
        local t = surface.get_tile(q.x, q.y)
        local name = t.valid and t.name or 'invalid'
        if name ~= r.names[c] then return {at={x=floor(q.x) + 0.5, y=floor(q.y) + 0.5}, was=r.names[c], now=name} end
        k = k + 1
      end
    end
    return nil
  end
  -- A drive leg's corridor counts: entities whose layers meet the vehicle's (less MOVERS) and tiles that do.
  -- (the MOVERS this engine knows: an unknown type name fails the whole count; checked once a load, the same on
  -- every peer)
  local known
  local function movers(surface)
    if known then return known end
    known = {}
    for _, t in ipairs(M.MOVERS) do
      if pcall(surface.count_entities_filtered, {area={{0, 0}, {0.1, 0.1}}, type=t}) then known[#known + 1] = t end
    end
    return known
  end
  function M.corridor(surface, a, b, h, layers)
    local area = box(a, b, h)
    local all = surface.count_entities_filtered{area=area, collision_mask=layers}
    local moving = all > 0 and surface.count_entities_filtered{area=area, collision_mask=layers, type=movers(surface)} or 0
    return all - moving, surface.count_tiles_filtered{area=area, collision_mask=layers}
  end
  -- A drive's points with each leg over `piece` tiles cut into equal parts.
  function M.pieces(pts, piece)
    local out = {{x=pts[1].x, y=pts[1].y}}
    for i = 2, #pts do
      local a, b = pts[i - 1], pts[i]
      local n = max(1, ceil(dist(a, b) / piece))
      for k = 1, n do out[#out + 1] = {x=a.x + (b.x - a.x) * k / n, y=a.y + (b.y - a.y) * k / n} end
    end
    return out
  end
  -- A path's corners: a point on the straight line between its neighbours (within 0.05 tiles) is dropped.
  function M.corners(pts)
    local out = {pts[1]}
    for i = 2, #pts - 1 do
      local a, q, b = out[#out], pts[i], pts[i + 1]
      local dx, dy = b.x - a.x, b.y - a.y
      local L = math.sqrt(dx * dx + dy * dy)
      local off = L > 0 and math.abs((q.x - a.x) * dy - (q.y - a.y) * dx) / L or dist(a, q)
      if off > 0.05 then out[#out + 1] = q end
    end
    if #pts > 1 then out[#out + 1] = pts[#pts] end
    return out
  end
  local function read_leg(rec, surface, a, b)
    local leg = {fp=M.fingerprint(surface, a, b), t=game.tick}
    if rec.kind == 'drive' then leg.n, leg.nt = M.corridor(surface, a, b, rec.h, rec.layers) end
    return leg
  end
  local function length(pts)
    local n = 0
    for i = 2, #pts do n = n + dist(pts[i - 1], pts[i]) end
    return n
  end
  local function drop(r, id)
    local rec = r.routes[id]
    if not rec then return end
    r.routes[id] = nil
    r.count = r.count - 1
    r.on[rec.si] = (r.on[rec.si] or 1) - 1
    if r.on[rec.si] <= 0 then
      r.on[rec.si] = nil
      local d = r.dirty[rec.si]
      if d then for _ in pairs(d) do r.ndirty = r.ndirty - 1 end end
      r.dirty[rec.si], r.all[rec.si] = nil, nil
    end
  end
  M.drop = function(id) drop(store(), id) end
  -- Keep a found path. kind 'spider' or 'drive'; pts: {x,y} from its start to its end; meta: {by, h, layers (drive)}.
  -- A route of this kind from and to the same places (within NEAR, either way) is replaced. -> the route, or nil and
  -- why it is not kept.
  function M.save(kind, surface, pts, meta)
    if #pts < 2 then return nil, 'under 2 points' end
    local r = store()
    local list = kind == 'drive' and M.pieces(M.corners(pts), M.PIECE) or pts
    if #list - 1 > M.MAX_LEGS then return nil, fmt('%d legs, over %d', #list - 1, M.MAX_LEGS) end
    local len = length(list)
    if len > M.MAX_TILES then return nil, fmt('%d tiles, over %d', floor(len + 0.5), M.MAX_TILES) end
    local sig
    if kind == 'drive' then
      local names = {}
      for i, l in ipairs(meta.layers or {}) do names[i] = l end
      table.sort(names)
      sig = table.concat(names, ',')
    end
    local si = surface.index
    local first, last = list[1], list[#list]
    for id, old in pairs(r.routes) do
      if old.si == si and old.kind == kind and old.sig == sig and old.h == meta.h then
        local o1, on = old.pts[1], old.pts[#old.pts]
        if (dist(o1, first) <= M.NEAR and dist(on, last) <= M.NEAR) or (dist(o1, last) <= M.NEAR and dist(on, first) <= M.NEAR) then drop(r, id) end
      end
    end
    r.seq = r.seq + 1
    local rec = {id=r.seq, kind=kind, si=si, h=meta.h, layers=meta.layers, sig=sig, by=meta.by, asked=game.tick,
      checked=game.tick, used=game.tick, uses=0, shift=r.shift, pts={}, legs={}}
    for i, q in ipairs(list) do rec.pts[i] = {x=q.x, y=q.y} end
    for i = 1, #rec.pts - 1 do rec.legs[i] = read_leg(rec, surface, rec.pts[i], rec.pts[i + 1]) end
    rec.len = floor(length(rec.pts) + 0.5)
    r.routes[rec.id] = rec
    r.count = r.count + 1
    r.on[si] = (r.on[si] or 0) + 1
    while r.count > M.MAX_ROUTES do
      local oldest, ot
      for id, o in pairs(r.routes) do
        if id ~= rec.id and (not ot or o.used < ot or (o.used == ot and id < oldest)) then oldest, ot = id, o.used end
      end
      if not oldest then break end
      drop(r, oldest)
      r.evicted = (r.evicted or 0) + 1
    end
    return rec
  end
  function M.get(id) return store().routes[id] end
  -- The stored route of this kind nearest from -> to (its first point within near of from and its last within
  -- near_end of to, or the reverse): rec, reversed. opt: {h (drive: the box it needs; a route asked for a box at least
  -- that big serves), sig (drive: the layers), near, near_end, id (that route only)}. With id: rec or nil and why not.
  function M.find(kind, surface, from, to, opt)
    local r = store()
    local si = surface.index
    local near, near_end = opt.near or M.NEAR, opt.near_end or M.NEAR
    local function fits(rec)
      if rec.si ~= si or rec.kind ~= kind then return false end
      if kind == 'drive' and (rec.sig ~= opt.sig or (rec.h or 0) < (opt.h or 0) - 1e-6) then return false end
      return true
    end
    local function score(rec)
      local p1, pn = rec.pts[1], rec.pts[#rec.pts]
      local fwd = dist(from, p1) <= near and dist(to, pn) <= near_end and dist(from, p1) + dist(to, pn) or nil
      local rev = dist(from, pn) <= near and dist(to, p1) <= near_end and dist(from, pn) + dist(to, p1) or nil
      if fwd and (not rev or fwd <= rev) then return fwd, false end
      if rev then return rev, true end
      return nil
    end
    if opt.id then
      local rec = r.routes[opt.id]
      if not rec then return nil, fmt('no stored route %d (kept: %d; vehicle {routes: true} lists them)', opt.id, r.count) end
      if not fits(rec) then return nil, fmt('route %d is a %s route%s on %s: not for this one', opt.id, rec.kind == 'drive' and 'car or tank' or 'spidertron',
        rec.kind == 'drive' and fmt(' for a box %.1f tiles wide', (rec.h or 0) * 2) or '', rec.si == si and 'this surface' or 'another surface') end
      local s, rev = score(rec)
      if not s then
        return nil, fmt('route %d runs %s -> %s: it does not start within %d tiles of %s or end within %d of %s (either way)', opt.id,
          at(rec.pts[1]), at(rec.pts[#rec.pts]), near, at(from), near_end, at(to))
      end
      return rec, rev
    end
    local best, bs, brev
    for _, rec in pairs(r.routes) do
      if fits(rec) then
        local s, rev = score(rec)
        if s and (not bs or s < bs - 1e-9 or (math.abs(s - bs) <= 1e-9 and rec.id > best.id)) then best, bs, brev = rec, s, rev end
      end
    end
    return best, brev
  end
  -- The chunk within the leg's box (plus MARK_MARGIN) marked last after tick t: its key and tick, or nil.
  local function marked(d, a, b, h, t)
    if not d then return nil end
    local g = h + M.MARK_MARGIN
    local bx = box(a, b, g)
    local hit, ht
    for cx = floor(bx[1][1] / 32), floor(bx[2][1] / 32) do
      for cy = floor(bx[1][2] / 32), floor(bx[2][2] / 32) do
        local m = d[key(cx, cy)]
        if m and m > t and (not ht or m > ht) then hit, ht = key(cx, cy), m end
      end
    end
    return hit, ht
  end
  -- Read the route again. -> {old = text} (asked over MAX_AGE ago: stale in full), else {stale = {[leg] = why}, n,
  -- first, last, legs}.
  function M.check(rec, surface)
    local r = store()
    local age = game.tick - rec.asked
    rec.checked = game.tick
    if age > M.MAX_AGE then
      return {old=fmt('route %d was asked %s ago, over the %s a route is kept without asking again', rec.id, ago(age), ago(M.MAX_AGE))}
    end
    local res = {stale={}, n=0, legs=#rec.legs}
    local all = r.all[rec.si] or -1
    local d = r.dirty[rec.si]
    for i, leg in ipairs(rec.legs) do
      local a, b = rec.pts[i], rec.pts[i + 1]
      local why
      if M.fingerprint(surface, a, b) ~= leg.fp then
        local df = M.diff(surface, a, b, leg.fp)
        why = df and fmt('the tile at %s was %s, now %s', at(df.at), df.was, df.now) or 'its tiles changed'
      elseif rec.kind == 'drive' then
        local n, nt = M.corridor(surface, a, b, rec.h, rec.layers)
        if n ~= leg.n then
          why = fmt('%d entities it collides with in its corridor, %d when read', n, leg.n)
        elseif nt ~= leg.nt then
          why = fmt('%d tiles it cannot drive on in its corridor, %d when read', nt, leg.nt)
        elseif all > leg.t then
          why = fmt('more chunks on this surface were marked than are kept (at tick %d)', all)
        else
          local k, kt = marked(d, a, b, rec.h, leg.t)
          if k then
            local cx, cy = unkey(k)
            why = fmt('chunk (%d,%d) near it had something built, mined or destroyed, or a tile changed, at tick %d', cx, cy, kt)
          end
        end
      end
      if why then
        res.stale[i] = why
        res.n = res.n + 1
        res.first = res.first or i
        res.last = i
      end
    end
    return res
  end
  -- Legs i0..i1 (points i0..i1 + 1) replaced by pts (from point i0 to point i1 + 1), each new leg read now. -> the
  -- route, or nil when it grew over MAX_LEGS (then dropped).
  function M.splice(rec, surface, i0, i1, pts)
    local list = rec.kind == 'drive' and M.pieces(M.corners(pts), M.PIECE) or pts
    local np, nl = {}, {}
    for i = 1, i0 - 1 do np[#np + 1] = rec.pts[i]; nl[#nl + 1] = rec.legs[i] end
    local base = #np
    for _, q in ipairs(list) do np[#np + 1] = {x=q.x, y=q.y} end
    for i = base + 1, #np - 1 do nl[#nl + 1] = read_leg(rec, surface, np[i], np[i + 1]) end
    for i = i1 + 2, #rec.pts do np[#np + 1] = rec.pts[i] end
    for i = i1 + 1, #rec.legs do nl[#nl + 1] = rec.legs[i] end
    if #nl > M.MAX_LEGS or length(np) > M.MAX_TILES then drop(store(), rec.id); return nil end
    rec.pts, rec.legs = np, nl
    rec.len = floor(length(np) + 0.5)
    rec.respliced = (rec.respliced or 0) + 1
    return rec
  end
  -- A use: when, how many.
  function M.used(rec)
    rec.used = game.tick
    rec.uses = (rec.uses or 0) + 1
  end
  -- Its points in the order of use.
  function M.points(rec, reversed)
    local out = {}
    local n = #rec.pts
    for i = 1, n do
      local q = rec.pts[reversed and n + 1 - i or i]
      out[i] = {x=q.x, y=q.y}
    end
    return out
  end
  -- "legs 1-4, 7" (stored order).
  function M.ranges(list)
    local parts, i = {}, 1
    while i <= #list do
      local j = i
      while j < #list and list[j + 1] == list[j] + 1 do j = j + 1 end
      parts[#parts + 1] = i == j and tostring(list[i]) or list[i] .. '-' .. list[j]
      i = j + 1
    end
    return table.concat(parts, ', ')
  end
  -- Who asked for it and when: "asked by sol at tick T (3m ago, shift 89)".
  function M.origin(rec)
    return fmt('asked by %s at tick %d (%s ago%s)', tostring(rec.by or '?'), rec.asked, ago(game.tick - rec.asked), rec.shift and ', shift ' .. rec.shift or '')
  end
  -- The reply's line for a check: all reused, or which legs are asked again and why (the first two reasons).
  function M.line(rec, res, reversed)
    if res.old then return res.old .. ': asked again in full' end
    local dir = reversed and ', walked from its end' or ''
    if res.n == 0 then
      return fmt('reused route %d (checked at tick %d): %s; its %d leg%s unchanged%s', rec.id, game.tick, M.origin(rec), res.legs,
        res.legs == 1 and '' or 's', dir)
    end
    -- the stale legs and those between them are asked again as one stretch; the legs outside it are reused
    local bad, good, whys = {}, {}, {}
    for i = 1, res.legs do
      if res.stale[i] then bad[#bad + 1] = i end
      if i < res.first or i > res.last then good[#good + 1] = i end
    end
    for _, i in ipairs(bad) do
      if #whys < 2 then whys[#whys + 1] = fmt('leg %d: %s', i, res.stale[i]) end
    end
    if #bad > 2 then whys[#whys + 1] = fmt('+%d more', #bad - 2) end
    return fmt('route %d (checked at tick %d): %s; of its %d legs, %s reused, %s asked again (%s)%s', rec.id, game.tick, M.origin(rec), res.legs,
      #good > 0 and 'legs ' .. M.ranges(good) or 'none', res.first == res.last and 'leg ' .. res.first or fmt('legs %d-%d', res.first, res.last),
      table.concat(whys, '; '), dir)
  end
  -- The events that mark chunks (control.lua forwards them; robot builds and tile changes once world n runs a mod with
  -- them): an entity built, mined or destroyed (not a mover), or tiles set.
  M.events = {}
  for _, n in ipairs({'on_built_entity', 'on_robot_built_entity', 'on_player_mined_entity', 'on_robot_mined_entity', 'on_entity_died',
    'script_raised_built', 'script_raised_revive', 'script_raised_destroy', 'on_biter_base_built', 'on_player_built_tile',
    'on_robot_built_tile', 'on_player_mined_tile', 'on_robot_mined_tile', 'script_raised_set_tiles'}) do
    if defines and defines.events and defines.events[n] then M.events[defines.events[n]] = n end
  end
  local function put(r, si, x, y, tick)
    local d = r.dirty[si]
    if not d then d = {}; r.dirty[si] = d end
    local k = key(floor(x / 32), floor(y / 32))
    if d[k] == nil then r.ndirty = r.ndirty + 1 end
    d[k] = tick
  end
  -- Over DIRTY_MAX: marks older than every route's legs on their surface are dropped; still over, a surface counts
  -- as marked in full at this tick (its marks dropped).
  local function prune(r, tick)
    local need = {}
    for _, rec in pairs(r.routes) do
      for _, leg in ipairs(rec.legs) do
        local o = need[rec.si]
        if not o or leg.t < o then need[rec.si] = leg.t end
      end
    end
    for si, d in pairs(r.dirty) do
      local o = need[si]
      for k, t in pairs(d) do
        if not o or t <= o then d[k] = nil; r.ndirty = r.ndirty - 1 end
      end
    end
    if r.ndirty > M.DIRTY_MAX then
      for si in pairs(r.dirty) do r.all[si] = tick; r.dirty[si] = nil end
      r.ndirty = 0
    end
  end
  function M.mark(event)
    local r = api.state().sharedroutes
    if not r or r.count == 0 then return end
    local tick = event.tick or game.tick
    local e = event.entity or event.created_entity
    if e then
      if not e.valid or MOVING[e.type] then return end
      local si = e.surface.index
      if not r.on[si] then return end
      local p = e.position
      put(r, si, p.x, p.y, tick)
    elseif event.tiles and event.surface_index then
      local si = event.surface_index
      if not r.on[si] then return end
      for _, t in ipairs(event.tiles) do put(r, si, t.position.x, t.position.y, tick) end
    else
      return
    end
    if r.ndirty > M.DIRTY_MAX then prune(r, tick) end
  end
  -- (shift_start) the shift's number, kept with the routes asked in it.
  function M.shift_start(n)
    local r = store()
    r.shift = n
    return {routes=r.count}
  end
  -- vehicle {routes: true}: the routes kept on this surface, nearest to q first (an end within), up to LIST; a line each.
  M.LIST = 20
  function M.list(surface, q)
    local r = store()
    local rows = {}
    for _, rec in pairs(r.routes) do
      if rec.si == surface.index then
        rows[#rows + 1] = {rec=rec, d=min(dist(q, rec.pts[1]), dist(q, rec.pts[#rec.pts]))}
      end
    end
    table.sort(rows, function(x, y) if x.d ~= y.d then return x.d < y.d end return x.rec.id < y.rec.id end)
    local lines = {}
    for i = 1, min(M.LIST, #rows) do
      local rec = rows[i].rec
      lines[i] = fmt('route %d: %s, %s -> %s, %d tiles in %d legs, %s; used %d time%s%s (an end %.0f tiles from %s)', rec.id,
        rec.kind == 'drive' and fmt('car or tank (a box %.1f tiles wide)', (rec.h or 0) * 2) or 'spidertron', at(rec.pts[1]), at(rec.pts[#rec.pts]),
        rec.len or 0, #rec.legs, M.origin(rec), rec.uses or 0, rec.uses == 1 and '' or 's', rec.respliced and fmt(', %d stretch%s asked again', rec.respliced, rec.respliced == 1 and '' or 'es') or '',
        rows[i].d, at(q))
    end
    local out = M.summary()
    out.surface = surface.name
    out.on_surface = #rows
    out.routes_here = lines
    out.note = fmt('kept for every agent and later shifts; each is read again before a go_to or drive uses it (tiles, and for a car or tank what it collides with near each leg); asked over %s ago, it is asked again in full; at most %d kept, the one used longest ago dropped first', ago(M.MAX_AGE), M.MAX_ROUTES)
    return out
  end
  -- What is kept: {routes, max_routes, legs, marks, max_marks, evicted, by_kind}.
  function M.summary()
    local r = store()
    local legs, kinds = 0, {}
    for _, rec in pairs(r.routes) do legs = legs + #rec.legs; kinds[rec.kind] = (kinds[rec.kind] or 0) + 1 end
    return {routes=r.count, max_routes=M.MAX_ROUTES, legs=legs, marks=r.ndirty, max_marks=M.DIRTY_MAX, evicted=r.evicted or 0, by_kind=kinds}
  end
  return M
end
