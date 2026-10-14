-- Valid placements near a position (shore.lua): the nearest centres and
-- directions where the game's own manual build check (can_place_entity,
-- build_check_type manual) accepts an entity. A refused offshore-pump build
-- lists them (all four directions, within 12 tiles), as does a build refused
-- by water under the footprint (the asked direction, within 6 tiles); the
-- placements read returns a list of them, as long as asked. Before the game
-- is asked, a scan of the entities and tiles around rules out the positions
-- something is in the way of (the game check costs ~15 us a position on world
-- n, an entity read ~2 us), and an offshore pump's candidates need its tile
-- rules met (its own tile on land, water in front of it).
return function(api)
  local M = {}
  local DIRS = {0, 4, 8, 12}
  local NAMES = {[0]='north', [4]='east', [8]='south', [12]='west'}
  local MAX = 3
  -- can_place_entity calls per search, at most (~15 us each on world n).
  local MAX_CHECKS = 200

  -- Footprint in tiles along x and y for a direction.
  local function size(proto, dir)
    local ok, w, h = pcall(function() return proto.tile_width, proto.tile_height end)
    if not (ok and w and h and w > 0 and h > 0) then
      local b = proto.collision_box
      w = b and math.ceil(b.right_bottom.x - b.left_top.x - 0.01) or 1
      h = b and math.ceil(b.right_bottom.y - b.left_top.y - 0.01) or 1
    end
    w, h = math.max(1, w), math.max(1, h)
    if dir == 4 or dir == 12 then w, h = h, w end
    return w, h
  end
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local EPS = 0.01
  -- The tiles whose centres lie inside lo..hi along one axis (first, last).
  local function span(lo, hi) return math.ceil(lo - 0.5 + EPS), math.floor(hi - 0.5 - EPS) end
  -- proto's collision box turned to dir: left, top, right, bottom around its
  -- centre (from the footprint when the prototype gives none).
  local function box_of(proto, dir)
    local b = try(function() return proto.collision_box end)
    local l, t, r, bt
    if b and b.left_top then
      l, t, r, bt = b.left_top.x, b.left_top.y, b.right_bottom.x, b.right_bottom.y
    else
      local w, h = size(proto, 0)
      l, t, r, bt = -w / 2 + 0.1, -h / 2 + 0.1, w / 2 - 0.1, h / 2 - 0.1
    end
    if dir == 4 then l, t, r, bt = -bt, l, -t, r
    elseif dir == 8 then l, t, r, bt = -r, -bt, -l, -t
    elseif dir == 12 then l, t, r, bt = t, -r, bt, -l end
    return {l, t, r, bt}
  end
  local function count_tiles(surface, f)
    local ok, n = pcall(function() return surface.count_tiles_filtered(f) end)
    if ok and type(n) == 'number' then return n end
    return #surface.find_tiles_filtered(f)
  end
  -- Entities that never stand in a build's way: they move, fly, burn out, or
  -- the build takes them away (ghosts, remnants, items on the ground).
  local PASSABLE = {['entity-ghost']=true, ['tile-ghost']=true, ['item-request-proxy']=true, corpse=true, ['character-corpse']=true,
    ['item-entity']=true, character=true, unit=true, ['spider-unit']=true, ['segmented-unit']=true, fish=true, resource=true,
    ['particle-source']=true, projectile=true, stream=true, fire=true, sticker=true, ['smoke-with-trigger']=true, explosion=true,
    beam=true, ['artillery-projectile']=true, ['highlight-box']=true, ['speech-bubble']=true, ['deconstructible-tile-proxy']=true,
    ['combat-robot']=true, ['construction-robot']=true, ['logistic-robot']=true, ['capture-robot']=true}
  local B = 8
  -- A prototype's tile rules (tile_buildability_rules: an offshore pump's
  -- own tile on land, water in front of it) turned to dir, kept where they
  -- ask only for water or for land: {x1, y1, x2, y2 (tiles the area overlaps,
  -- relative to the centre's tile), wets = true (all water) | false (none)}.
  -- 2.0.77, checked on world n's lakes: a pump fits only where these hold.
  local function only(t, key)
    local n = 0
    for k in pairs(t) do if k ~= key then return false end; n = n + 1 end
    return n == 1
  end
  local function tile_rules(proto, dir)
    local rules = try(function() return proto.tile_buildability_rules end)
    local out = {}
    for _, rule in ipairs(rules or {}) do
      local need = rule.required_tiles and rule.required_tiles.layers or {}
      local bar = rule.colliding_tiles and rule.colliding_tiles.layers or {}
      local wants
      if only(need, 'water_tile') and next(bar) == nil then wants = true
      elseif bar.water_tile and (next(need) == nil or only(need, 'ground_tile')) then wants = false end
      local a = rule.area
      if wants ~= nil and a and a.left_top then
        local b = box_of({collision_box=a}, dir)
        out[#out+1] = {math.floor(b[1] + 0.5 + 0.05), math.floor(b[2] + 0.5 + 0.05), math.ceil(b[3] + 0.5 - 0.05) - 1, math.ceil(b[4] + 0.5 - 0.05) - 1, wets=wants}
      end
    end
    return out
  end
  -- What stands where, read in 8x8 blocks as candidates reach them, over a
  -- square grid of gw tiles from (gx, gy). in_way(x1, y1, x2, y2): whether
  -- an entity whose collision layers meet proto's covers one of those tiles'
  -- centres, or (not a pump) one of the tiles' own layers meet proto's (water
  -- for most buildings). Two boxes that hold the same point collide, so a
  -- position this rules out is one the game check would refuse; what it
  -- cannot judge (a turned box, a prototype without layers) it leaves to that
  -- check. flag(tx, ty), by the tile's block: not a pump, all its tiles are
  -- such tiles (a lake, an oil ocean: read by a count, not tile by tile); a
  -- pump, it or a block next to it holds water and one holds land.
  -- wet(tx, ty): a water tile. Tiles outside the grid count as free and dry.
  local function grid(p, proto, gx, gy, gw, pump)
    local surface = p.surface
    local nb = math.ceil(gw / B)
    local loaded, blocked, tstate, wstate, water = {}, {}, {}, {}, {}
    local mine = try(function() return proto.collision_mask end)
    local layers = mine and mine.layers
    local list
    if layers then
      list = {}
      for layer in pairs(layers) do list[#list+1] = layer end
      table.sort(list)
      if #list == 0 then list = nil end
    end
    local scan = list and not mine.colliding_with_tiles_only
    local hits = {}
    local function collides(name)
      local ep = prototypes.entity[name]
      local m = ep and try(function() return ep.collision_mask end)
      if not (m and m.layers) then return false end
      if name == proto.name and m.not_colliding_with_itself then return false end
      for layer in pairs(m.layers) do if layers[layer] then return true end end
      return false
    end
    local function mark(t, tx, ty)
      local i, j = tx - gx, ty - gy
      if i >= 0 and i < gw and j >= 0 and j < gw then t[i * gw + j] = true end
    end
    local function mark_box(bb)
      if not (bb and bb.left_top and bb.right_bottom) then return end
      local l, t, r, b = bb.left_top.x, bb.left_top.y, bb.right_bottom.x, bb.right_bottom.y
      local o = (bb.orientation or 0) % 0.5
      if math.abs(o - 0.25) < 1e-6 then
        local cx, cy, hw, hh = (l + r) / 2, (t + b) / 2, (r - l) / 2, (b - t) / 2
        l, t, r, b = cx - hh, cy - hw, cx + hh, cy + hw
      elseif o > 1e-6 then
        -- A turned box (a diagonal rail): only the circle inside it, whichever way it turns.
        local cx, cy = (l + r) / 2, (t + b) / 2
        local rad = math.min(r - l, b - t) / 2 - EPS
        if rad <= 0 then return end
        local x1, x2 = span(cx - rad, cx + rad)
        local y1, y2 = span(cy - rad, cy + rad)
        for tx = x1, x2 do
          for ty = y1, y2 do
            if (tx + 0.5 - cx) ^ 2 + (ty + 0.5 - cy) ^ 2 < rad * rad then mark(blocked, tx, ty) end
          end
        end
        return
      end
      local x1, x2 = span(l, r)
      local y1, y2 = span(t, b)
      for tx = x1, x2 do for ty = y1, y2 do mark(blocked, tx, ty) end end
    end
    local function block_area(bi, bj)
      local x1, y1 = gx + bi * B, gy + bj * B
      local x2, y2 = math.min(x1 + B, gx + gw) - 1, math.min(y1 + B, gy + gw) - 1
      return x1, y1, x2, y2, {left_top={x=x1, y=y1}, right_bottom={x=x2 + 1, y=y2 + 1}}
    end
    -- The tiles of a block whose layers meet the filter's (any of them): 0
    -- none, 1 all, 2 some (each marked in t).
    local function tiles(t, bi, bj, filter)
      local x1, y1, x2, y2, area = block_area(bi, bj)
      local n = count_tiles(surface, {area=area, collision_mask=filter})
      if n == 0 then return 0 end
      if n >= (x2 - x1 + 1) * (y2 - y1 + 1) then
        for tx = x1, x2 do for ty = y1, y2 do mark(t, tx, ty) end end
        return 1
      end
      for _, tile in pairs(surface.find_tiles_filtered{area=area, collision_mask=filter}) do
        local q = tile.position
        mark(t, math.floor(q.x), math.floor(q.y))
      end
      return 2
    end
    local function tblock(bi, bj)
      local k = bi * nb + bj
      local s = tstate[k]
      if not s then
        s = pump and 0 or tiles(blocked, bi, bj, list or 'water_tile')
        tstate[k] = s
      end
      return s
    end
    local function wblock(bi, bj)
      if bi < 0 or bj < 0 or bi >= nb or bj >= nb then return 0 end
      local k = bi * nb + bj
      local s = wstate[k]
      if not s then s = tiles(water, bi, bj, 'water_tile'); wstate[k] = s end
      return s
    end
    local function load(bi, bj)
      local k = bi * nb + bj
      if loaded[k] then return end
      loaded[k] = true
      tblock(bi, bj)
      if not scan then return end
      local _, _, _, _, area = block_area(bi, bj)
      for _, e in pairs(surface.find_entities_filtered{area=area, collision_mask=list}) do
        local t = e.valid and e.type
        if t and not PASSABLE[t] then
          local name = e.name
          local hit = hits[name]
          if hit == nil then hit = collides(name) == true; hits[name] = hit end
          if hit then
            mark_box(e.bounding_box)
            if t:find('curved', 1, true) then mark_box(e.secondary_bounding_box) end
          end
        end
      end
    end
    local G = {water=water}
    -- A pump reads every block's water up front: then water[i * gw + j] is
    -- true for each water tile (a block all water is marked whole).
    function G.all_water()
      for bi = 0, nb - 1 do for bj = 0, nb - 1 do wblock(bi, bj) end end
    end
    function G.in_way(x1, y1, x2, y2)
      for tx = x1, x2 do
        local i = tx - gx
        if i >= 0 and i < gw then
          local bi, base = math.floor(i / B), i * gw
          for ty = y1, y2 do
            local j = ty - gy
            if j >= 0 and j < gw then
              if not loaded[bi * nb + math.floor(j / B)] then load(bi, math.floor(j / B)) end
              if blocked[base + j] then return true end
            end
          end
        end
      end
      return false
    end
    -- Per block, read once: whether its tiles all collide (not a pump), or
    -- whether it or a block next to it holds water and one holds land (a pump).
    local flags = {}
    function G.flag(tx, ty)
      local i, j = tx - gx, ty - gy
      if i < 0 or j < 0 or i >= gw or j >= gw then return false end
      local bi, bj = (i - i % B) / B, (j - j % B) / B
      local k = bi * nb + bj
      local f = flags[k]
      if f == nil then
        if pump then
          local wet, dry = false, false
          for a = bi - 1, bi + 1 do
            for b = bj - 1, bj + 1 do
              local s = wblock(a, b)
              if s ~= 0 then wet = true end
              if s ~= 1 then dry = true end
            end
          end
          f = wet and dry
        else
          f = tblock(bi, bj) == 1
        end
        flags[k] = f
      end
      return f
    end
    function G.wet(tx, ty)
      local i, j = tx - gx, ty - gy
      if i < 0 or j < 0 or i >= gw or j >= gw then return false end
      local bi, bj = (i - i % B) / B, (j - j % B) / B
      local s = wstate[bi * nb + bj] or wblock(bi, bj)
      return s == 1 or (s == 2 and water[i * gw + j] == true)
    end
    return G
  end

  -- The nearest valid placements of proto around pos: {position, direction}
  -- nearest first, one per position (the first direction that fits), at most
  -- opts.limit (default 3); how many positions the game checked; and info:
  -- blocked (positions an entity or tile is in the way of, by the scan above),
  -- unseen (positions opts.seen ruled out), more (positions left unchecked).
  -- dirs: the directions to try (the first wins a tie); a direction whose box
  -- matches an earlier one's adds nothing (a square building turns in place).
  -- opts (optional): keep(x, y) filters candidate centres before the game
  -- check; seen(x, y) likewise, counted apart; ref: sort by distance to this
  -- point instead of pos; max_checks (default 200); separate: a position
  -- whose tiles overlap a spot found before is left out (info.overlap);
  -- powered: a position none of whose tiles lies in a built pole's supply
  -- area (ours, as the game connects a machine) is left out (info.unpowered;
  -- info.poles: the poles whose area reaches the search).
  function M.find(p, proto, pos, radius, dirs, opts)
    opts = opts or {}
    local limit, budget = opts.limit or MAX, opts.max_checks or MAX_CHECKS
    local ref = opts.ref or pos
    local surface = p.surface
    local pump = proto.type == 'offshore-pump'
    local info = {blocked=0, unseen=0, overlap=0, unpowered=0}
    local boxes, rules, extent = {}, {}, 1
    for rank, dir in ipairs(dirs) do
      local b = box_of(proto, dir)
      for k = 1, rank - 1 do
        local q = boxes[k]
        if q and math.abs(q[1] - b[1]) < EPS and math.abs(q[2] - b[2]) < EPS and math.abs(q[3] - b[3]) < EPS and math.abs(q[4] - b[4]) < EPS then b = nil; break end
      end
      boxes[rank] = b or false
      if b then
        extent = math.max(extent, math.abs(b[1]), math.abs(b[2]), math.abs(b[3]), math.abs(b[4]))
        rules[rank] = tile_rules(proto, dir)
        for _, r in ipairs(rules[rank]) do extent = math.max(extent, math.abs(r[1]), math.abs(r[2]), math.abs(r[3]), math.abs(r[4])) end
      end
    end
    local margin = math.ceil(extent) + 2
    local gx, gy = math.floor(pos.x) - radius - margin, math.floor(pos.y) - radius - margin
    local gw = 2 * (radius + margin) + 1
    if pump and count_tiles(surface, {area={left_top={x=gx, y=gy}, right_bottom={x=gx + gw, y=gy + gw}}, collision_mask='water_tile', limit=1}) == 0 then
      return {}, 0, info
    end
    local G = grid(p, proto, gx, gy, gw, pump)
    local in_way, wet, flag, water = G.in_way, G.wet, G.flag, G.water
    -- Tiles of the grid by number ((tx - gx) * gw + ty - gy): any marked in x1..x2, y1..y2; mark them all.
    local function any(t, x1, y1, x2, y2)
      for tx = math.max(x1, gx), math.min(x2, gx + gw - 1) do
        local base = (tx - gx) * gw - gy
        for ty = math.max(y1, gy), math.min(y2, gy + gw - 1) do if t[base + ty] then return true end end
      end
      return false
    end
    local function mark(t, x1, y1, x2, y2)
      for tx = math.max(x1, gx), math.min(x2, gx + gw - 1) do
        local base = (tx - gx) * gw - gy
        for ty = math.max(y1, gy), math.min(y2, gy + gw - 1) do t[base + ty] = true end
      end
    end
    local taken = opts.separate and {} or nil
    -- A machine connects to a pole whose supply area (a square, supply area
    -- distance each way) overlaps its box: the tiles that square overlaps.
    local supplied
    if opts.powered then
      supplied, info.poles = {}, 0
      local far = 16
      local area = {left_top={x=gx - far, y=gy - far}, right_bottom={x=gx + gw + far, y=gy + gw + far}}
      for _, e in pairs(surface.find_entities_filtered{area=area, type='electric-pole', force=p.force, limit=2048}) do
        if e.valid then
          local q = try(function() return e.quality.name end)
          local d = try(function() return e.prototype.get_supply_area_distance(q or 'normal') end) or try(function() return e.prototype.supply_area_distance end) or 0
          local c = e.position
          local x1, x2 = math.floor(c.x - d + EPS), math.ceil(c.x + d - EPS) - 1
          local y1, y2 = math.floor(c.y - d + EPS), math.ceil(c.y + d - EPS) - 1
          if d > 0 and x2 >= gx and y2 >= gy and x1 < gx + gw and y1 < gy + gw then
            info.poles = info.poles + 1
            mark(supplied, x1, y1, x2, y2)
          end
        end
      end
    end
    -- The rules' tiles are counted from a tile centre: an odd footprint (a 1x1 pump).
    local w1, h1 = size(proto, dirs[1])
    local ruled = pump and #(rules[1] or {}) > 0 and w1 % 2 == 1 and h1 % 2 == 1
    if ruled then G.all_water() end
    -- Candidates as numbers (distance in 1/1024 tile, rank, x, y: sorting
    -- them sorts nearest first, then by rank, x and y) in rings 1/16 tile
    -- wide, a ring sorted when the search reaches it. Around pos they are made
    -- a square layer at a time, as the rings need them (a layer L lies at
    -- least L - 0.5 from pos), so a search that ends near pos makes few. A
    -- position whose first tile lies in a block all of colliding tiles counts
    -- as blocked when made; a pump's away from any shore is not made.
    local rings, last, bxs, bys, firsts = {}, -1, {}, {}, {}
    local r2 = (radius + 0.01) ^ 2
    for rank, dir in ipairs(dirs) do
      local b = boxes[rank]
      if b then
        local w, h = size(proto, dir)
        bxs[rank] = w % 2 == 1 and math.floor(pos.x) + 0.5 or math.floor(pos.x + 0.5)
        bys[rank] = h % 2 == 1 and math.floor(pos.y) + 0.5 or math.floor(pos.y + 0.5)
        firsts[rank] = {b[1] - 0.5 + EPS, b[2] - 0.5 + EPS}
      end
    end
    local function add(rank, i, j)
      local x, y = bxs[rank] + i, bys[rank] + j
      local dx, dy = x - pos.x, y - pos.y
      if dx * dx + dy * dy > r2 then return end
      -- floor(v) is v - v % 1 here and below: math.floor is a call.
      if ruled then
        -- The tile rules, read from the water array: water where it needs water, none where it needs land.
        local cx, cy = x - x % 1, y - y % 1
        local rl = rules[rank]
        for n = 1, #rl do
          local r = rl[n]
          local want = r.wets
          for tx = cx + r[1], cx + r[3] do
            local base = (tx - gx) * gw - gy
            for ty = cy + r[2], cy + r[4] do
              if (water[base + ty] == true) ~= want then return end
            end
          end
        end
      elseif pump then
        if not flag(x - x % 1, y - y % 1) then return end
      else
        local f = firsts[rank]
        local fx, fy = x + f[1], y + f[2]
        if flag(fx + (-fx) % 1, fy + (-fy) % 1) then info.blocked = info.blocked + 1; return end
      end
      local ex, ey = x - ref.x, y - ref.y
      local dv = (ex * ex + ey * ey) ^ 0.5 * 1024
      local dq = dv - dv % 1
      local k = (dq - dq % 64) / 64
      local ring = rings[k]
      if not ring then ring = {}; rings[k] = ring; if k > last then last = k end end
      ring[#ring+1] = ((dq * 8 + rank) * 128 + i + radius) * 128 + j + radius
    end
    local made = -1
    local function layer(L)
      for rank in ipairs(dirs) do
        if boxes[rank] then
          if L == 0 then add(rank, 0, 0)
          else
            for i = -L, L do add(rank, i, -L); add(rank, i, L) end
            for j = -L + 1, L - 1 do add(rank, -L, j); add(rank, L, j) end
          end
        end
      end
    end
    local around = ref.x == pos.x and ref.y == pos.y
    if not around then for L = 0, radius do layer(L) end; made = radius end
    local out, checks, done = {}, 0, {}
    local keep, seen = opts.keep, opts.seen
    local k = 0
    while true do
      if around then
        local need = math.min(radius, math.floor((k + 1) / 16 + 0.5))
        while made < need do made = made + 1; layer(made) end
      end
      if k > last and made >= radius then break end
      local ring = rings[k]
      if ring then
        if #ring > 1 then table.sort(ring) end
        for _, key in ipairs(ring) do
          local yi = math.floor(key % 128)
          local rest = math.floor(key / 128)
          local xi = rest % 128
          local rank = math.floor(rest / 128) % 8
          local x, y = bxs[rank] + xi - radius, bys[rank] + yi - radius
          local at = x * 8388608 + y * 2
          if not done[at] then
            if #out >= limit or checks >= budget then info.more = true; return out, checks, info end
            local dir, b = dirs[rank], boxes[rank]
            local fits = true
            if pump and not ruled then
              -- No tile rules to read: water and land in the footprint grown by a tile.
              local w, h = size(proto, dir)
              local x0, y0 = math.floor(x - w / 2 + 0.01) - 1, math.floor(y - h / 2 + 0.01) - 1
              local wets, drys = 0, 0
              for tx = x0, x0 + w + 1 do
                for ty = y0, y0 + h + 1 do
                  if wet(tx, ty) then wets = wets + 1 else drys = drys + 1 end
                end
              end
              fits = wets > 0 and drys > 0
            end
            if fits and keep then fits = keep(x, y) end
            local x1, y1 = math.ceil(x + b[1] - 0.5 + EPS), math.ceil(y + b[2] - 0.5 + EPS)
            local x2, y2 = math.floor(x + b[3] - 0.5 - EPS), math.floor(y + b[4] - 0.5 - EPS)
            if fits and supplied and not any(supplied, x1, y1, x2, y2) then fits = false; info.unpowered = info.unpowered + 1 end
            if fits and taken and any(taken, x1, y1, x2, y2) then fits = false; info.overlap = info.overlap + 1 end
            if fits and in_way(x1, y1, x2, y2) then
              fits = false; info.blocked = info.blocked + 1
            end
            if fits and seen and not seen(x, y) then fits = false; info.unseen = info.unseen + 1 end
            if fits then
              checks = checks + 1
              local position = {x=x, y=y}
              if surface.can_place_entity{name=proto.name, position=position, direction=dir, force=p.force,
                  build_check_type=defines.build_check_type.manual} then
                done[at] = true
                out[#out+1] = {position=position, direction=NAMES[dir]}
                if taken then mark(taken, x1, y1, x2, y2) end
              end
            end
          end
        end
        rings[k] = nil
      end
      k = k + 1
    end
    return out, checks, info
  end

  local function listed(list)
    local parts = {}
    for _, s in ipairs(list) do parts[#parts+1] = string.format('(%g,%g) %s', s.position.x, s.position.y, s.direction) end
    return table.concat(parts, ', ')
  end
  -- Turrets: a refused build (blocked, or out of reach) lists the nearest
  -- spots within the character's build reach where the game accepts one.
  local TURRETS = {['ammo-turret']=true, ['electric-turret']=true, ['fluid-turret']=true, ['artillery-turret']=true}
  local function spots(list)
    local parts = {}
    for _, s in ipairs(list) do parts[#parts+1] = string.format('(%g,%g)', s.position.x, s.position.y) end
    return table.concat(parts, ', ')
  end
  local function in_reach(p)
    local from, reach = p.position, (p.build_distance or 10) - 0.5
    return function(x, y) return ((x - from.x) ^ 2 + (y - from.y) ^ 2) ^ 0.5 <= reach end
  end
  local function turret_spots(p, proto, pos, direction, centre)
    local found = M.find(p, proto, centre or pos, 6, {direction or 0}, {keep=in_reach(p), ref=pos})
    if #found == 0 then
      return '; no spot for ' .. proto.name .. ' within your build reach' .. (centre and ' toward that position' or ' and 6 tiles of it') .. ' (game build check)'
    end
    return '; nearest spots where ' .. proto.name .. ' fits within your build reach (game build check): ' .. spots(found)
  end
  -- A build out of reach: for a turret, the valid spots within reach on the
  -- way to the asked position (searched around the reach edge toward it).
  function M.reach_hint(p, item, pos)
    local ip = prototypes.item[item]
    local proto = ip and ip.place_result
    if not (proto and TURRETS[proto.type]) then return nil end
    local from = p.position
    local d = ((pos.x - from.x) ^ 2 + (pos.y - from.y) ^ 2) ^ 0.5
    local step = math.max(0, (p.build_distance or 10) - 3)
    local centre = d > 0 and {x=from.x + (pos.x - from.x) * step / d, y=from.y + (pos.y - from.y) * step / d} or from
    return turret_spots(p, proto, pos, 0, centre) .. '; or walk closer (move_to) and build again'
  end
  -- The text a refused build appends: for an offshore pump (any refusal), an
  -- entity refused by water under its footprint (water true), or a turret.
  function M.hint(p, proto, pos, direction, water)
    local pump = proto.type == 'offshore-pump'
    if TURRETS[proto.type] and not water then return turret_spots(p, proto, pos, direction) end
    if not (pump or water) then return nil end
    if pump then
      local dirs = {direction}
      for _, d in ipairs(DIRS) do if d ~= direction then dirs[#dirs+1] = d end end
      local found = M.find(p, proto, pos, 12, dirs)
      if #found == 0 then return '; no valid offshore-pump placement within 12 tiles (game build check)' end
      return '; nearest valid ' .. proto.name .. ' placements (game build check, within 12 tiles): ' .. listed(found)
    end
    local found = M.find(p, proto, pos, 6, {direction})
    local facing = NAMES[direction] or tostring(direction)
    if #found == 0 then return '; no position within 6 tiles where ' .. proto.name .. ' fits facing ' .. facing .. ' (game build check)' end
    return '; nearest positions where ' .. proto.name .. ' fits facing ' .. facing .. ' (game build check, within 6 tiles): ' .. listed(found)
  end

  M.schema = {
    placements={name='entity or item name (an item: the entity it places)',
      near='optional {x,y} centre (default you): in sight, or by remote view in a chunk our force sees now',position='the same as near',
      radius='optional 1..24 (default 12 for an offshore-pump, else 10)',limit='optional 1..50 positions (default 10)',
      direction='optional compass name or 0, 4, 8, 12: only this direction (default north, east, south, west; a building that does not turn has none)',
      separate='optional true: spots that do not overlap each other, so all of them can be built (each overlaps no spot nearer in the list); overlap: positions left out for that',
      powered='optional true: only spots with a tile in the supply area of one of our built electric poles (the game connects the machine there); unpowered: positions left out for that; poles: our poles whose area reaches the search',
      returns='placements [{position, direction}]: where the entity fits now, nearest first, one per position, by the game\'s manual build check (as build and dry_run: water, cliffs, entities, tiles; no reach or item check); count; checked: positions the game checked (at most 200); blocked: positions an entity or tile was in the way of (a scan before the game check); unseen: positions in chunks our force does not see now (left out); more: true when positions were left unchecked'},
  }
  M.handlers = {}
  -- Gemini 10:50 (accumulators, recyclers: radius 16 found nothing in 400
  -- checks): a list of spots, as many as asked, with what was in the way.
  function M.handlers.placements(p, a)
    assert(type(a.name) == 'string', 'name is required')
    local proto = prototypes.entity[a.name]
    if not proto then
      local item = prototypes.item[a.name]
      proto = item and item.place_result
    end
    assert(proto, 'no entity or item named ' .. a.name .. ' that places an entity')
    if a.near ~= nil and a.position ~= nil then error('near and position both name the centre: give one', 0) end
    local at = a.near
    if at == nil then at = a.position end
    local pos = at ~= nil and api.position(at) or p.position
    local by
    if api.read_sight then by = api.read_sight(p, pos, 'near') else api.assert_visible(p, pos, 'position') end
    local pump = proto.type == 'offshore-pump'
    local radius = api.integer(a.radius, pump and 12 or 10, 1, 24, 'radius')
    local limit = api.integer(a.limit, 10, 1, 50, 'limit')
    local turns = try(function() return proto.supports_direction end) ~= false
    local dirs = turns and DIRS or {0}
    if a.direction ~= nil then
      local d = api.direction_of and api.direction_of(a.direction) or api.directions[a.direction]
      assert(d and NAMES[d], 'direction is north, east, south or west (or 0, 4, 8, 12)')
      dirs = {d}
    end
    -- Positions in a chunk our force does not see now are left out, as the map shows nothing live there.
    local seen
    if api.chunk_seen then
      local chunks = {}
      seen = function(x, y)
        -- A number: a string made of numbers costs ~16 us in the game's Lua.
        local k = math.floor(x / 32) * 65536 + math.floor(y / 32)
        local v = chunks[k]
        if v == nil then v = api.chunk_seen(p, {x=x, y=y}) == true; chunks[k] = v end
        return v
      end
    end
    assert(a.separate == nil or type(a.separate) == 'boolean', 'separate must be true or false')
    assert(a.powered == nil or type(a.powered) == 'boolean', 'powered must be true or false')
    local found, checked, info = M.find(p, proto, pos, radius, dirs, {limit=limit, seen=seen, separate=a.separate, powered=a.powered})
    if not turns then for _, s in ipairs(found) do s.direction = nil end end
    return {name=proto.name, near=pos, radius=radius, placements=found, count=#found, checked=checked, by=by,
      blocked=info.blocked > 0 and info.blocked or nil, unseen=info.unseen > 0 and info.unseen or nil, more=info.more or nil,
      separate=a.separate or nil, overlap=a.separate and info.overlap or nil,
      powered=a.powered or nil, unpowered=a.powered and info.unpowered or nil, poles=a.powered and info.poles or nil}
  end
  return M
end
