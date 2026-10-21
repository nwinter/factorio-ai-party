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
  local DIRS_BY_NAME = {north=0, east=4, south=8, west=12}
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
    local function mark(t, tx, ty, v)
      local i, j = tx - gx, ty - gy
      if i >= 0 and i < gw and j >= 0 and j < gw then t[i * gw + j] = v or true end
    end
    local ghosted, ghost_names = {}, {}
    local function mark_box(bb, into, val)
      local blocked = into or blocked
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
            if (tx + 0.5 - cx) ^ 2 + (ty + 0.5 - cy) ^ 2 < rad * rad then mark(blocked, tx, ty, val) end
          end
        end
        return
      end
      local x1, x2 = span(l, r)
      local y1, y2 = span(t, b)
      for tx = x1, x2 do for ty = y1, y2 do mark(blocked, tx, ty, val) end end
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
      -- Ghosts (Astra, d15: placements suggested over ghosts): marked apart, as taken.
      for _, g in pairs(surface.find_entities_filtered{area=area, type='entity-ghost'}) do
        if g.valid then
          mark_box(g.bounding_box, ghosted, g.ghost_name or 'a ghost')
          local n = g.ghost_name
          if n and not ghost_names[n] then ghost_names[n] = true; ghost_names[#ghost_names+1] = n end
        end
      end
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
    -- Whether a ghost stands on any of the tiles (in_way loads the blocks first).
    function G.ghost_in_way(x1, y1, x2, y2)
      for tx = x1, x2 do
        local i = tx - gx
        if i >= 0 and i < gw then
          for ty = y1, y2 do
            local j = ty - gy
            if j >= 0 and j < gw and ghosted[i * gw + j] then return ghosted[i * gw + j] end
          end
        end
      end
      return false
    end
    G.ghost_names = ghost_names
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
    local info = {blocked=0, unseen=0, overlap=0, unpowered=0, ghosts=0}
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
    -- Tile ghosts in the search area, for an entity with tile rules (an asteroid collector): what they become.
    local tile_ghosts
    if #(try(function() return proto.tile_buildability_rules end) or {}) > 0 then
      for _, g in pairs(try(function() return surface.find_entities_filtered{area={left_top={x=gx, y=gy}, right_bottom={x=gx + gw, y=gy + gw}}, type='tile-ghost', limit=4096} end) or {}) do
        local tp = g.valid and prototypes.tile[g.ghost_name]
        if tp then tile_ghosts = tile_ghosts or {}; tile_ghosts[math.floor(g.position.x) .. ',' .. math.floor(g.position.y)] = {name=g.ghost_name, prototype=tp} end
      end
    end
    info.ghost_list = G.ghost_names
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
            local ghost = fits and G.ghost_in_way and G.ghost_in_way(x1, y1, x2, y2)
            if fits and seen and not seen(x, y) then fits = false; info.unseen = info.unseen + 1 end
            -- (backlog #555, Astra: (-10,29) offered for a cargo bay, the ghost stood at (-10,30)) a spot the game would
            -- move the entity off (a cargo bay keeps to a 2-tile grid) is not a spot: only those it keeps are offered
            if fits and M.GRID2[proto.type] then
              local w, h = size(proto, dir)
              if math.abs(M.grid2(x, w) - x) > 0.01 or math.abs(M.grid2(y, h) - y) > 0.01 then fits = false end
            end
            if fits then
              checks = checks + 1
              local position = {x=x, y=y}
              local ok_place = surface.can_place_entity{name=proto.name, position=position, direction=dir, force=p.force,
                  build_check_type=defines.build_check_type.manual}
              -- Tile ghosts count as the tiles they become (Sol 03:21: a collector's placement read valid with
              -- foundation ghosts in the open space it needs, and the build was refused): its tile rules judge them so.
              if ok_place and tile_ghosts and api.placewhy then
                local broken = api.placewhy.tile_rules(surface, proto, position, dir, function(tx, ty)
                  return tile_ghosts[tx .. ',' .. ty] or surface.get_tile(tx, ty)
                end)
                if broken then ok_place = false; info.tile_ghosts = (info.tile_ghosts or 0) + 1; info.tile_ghost_why = info.tile_ghost_why or broken end
              end
              -- (d18 batch39 D1) a caller's own test of the spot the game takes (placements fluids: its ports' segments)
              local extra
              if ok_place and opts.accept then
                local okk, good, more = pcall(opts.accept, position, dir)
                if not (okk and good) then ok_place = false; info.rejected = (info.rejected or 0) + 1
                  if okk and more and #(info.reject_lines or {}) < 3 then info.reject_lines = info.reject_lines or {}; table.insert(info.reject_lines, more) end
                else extra = more end
              end
              if ok_place then
                done[at] = true
                out[#out+1] = {position=position, direction=NAMES[dir], over_ghost=ghost and ghost or nil, ports=extra and extra.ports or nil, line=extra and extra.line or nil}
                if ghost then info.ghosts = info.ghosts + 1 end
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
    placements={rail_layer='optional, for rail-signal or rail-chain-signal: ground or elevated (default both): the signal spots of the rails within radius (each rail end\'s in and out signal locations, as the game snaps a signal) that the game\'s ghost check takes on that layer: placements [{position, direction, rail_layer, rail {name, position}}], checked, refused',fluids='optional 1..6 fluid names, for a machine with fluid ports: only spots whose ports touch built segments of each (a port\'s join tile holds an entity of ours connected back), and none joining a segment of another fluid than that port takes (with recipe: the recipe\'s fluids); each placement gives ports [{flow, at, wants, touches (the segment\'s fluid, or empty), segment, via}] and line; rejected counts spots the game took that failed this, mixes up to 3 of the joins refused, fluids_line when none passed',recipe='optional, with fluids: the recipe the machine will run (its ports\' fluids)',resource='optional, with a mining drill or pumpjack: a resource name (or true: any it mines): its spots on that resource within radius 1..32 (default 16): a pumpjack every well, free with the directions it fits, or taken by our drill, or blocked; a drill every tile centre whose mining area holds the ore, the most ore first, free ones none overlapping; returns free [{position, amount, tiles or directions, line}], free_count, blocked (each with the build refusal\'s why), blocked_count, blocked_by (by kind, how many, one where), line',
      surface='optional planet name: spots there by remote view (a chunk our force sees), as the map lets a player plan them',platform='optional platform name: spots on that space platform (Astra, d15 07:50: where a cargo bay fits, by the game\'s own build check, which knows the hub and bay attachment), near in platform coordinates (default its hub)',name='entity or item name (an item: the entity it places)',
      near='optional {x,y} centre (default you): in sight, or by remote view in a chunk our force sees now',position='the same as near',
      radius='optional 1..24 (default 12 for an offshore-pump, else 10; past 24 searched at 24, said in note)',limit='optional 1..50 positions (default 10; past 50: 50)',
      direction='optional compass name or 0, 4, 8, 12: only this direction (default north, east, south, west; a building that does not turn has none)',
      separate='optional true: spots that do not overlap each other, so all of them can be built (each overlaps no spot nearer in the list); overlap: positions left out for that',
      powered='optional true: only spots with a tile in the supply area of one of our built electric poles (the game connects the machine there); unpowered: positions left out for that; poles: our poles whose area reaches the search',
      returns='placements [{position, direction, network (an electric entity: the electric network #N whose pole supplies the spot, or none), pole (that pole, or the nearest pole and how far)}]: where the entity fits now, nearest first, one per position, by the game\'s manual build check (as build and dry_run: water, cliffs, entities, tiles; no reach or item check); count; checked: positions the game checked (at most 200); blocked: positions an entity or tile was in the way of (a scan before the game check); unseen: positions in chunks our force does not see now (left out); more: true when positions were left unchecked; in_the_way (nothing fits): what stands in the search square by name with the nearest one, and the tiles it cannot stand on by name; overlapping: how many pairs of the listed spots overlap each other (without separate); no_supply: how many listed spots lie in no pole\'s supply area (without powered, an entity that takes electricity)'},
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
    -- resource (d17 batch21 B2): a drill's or pumpjack's spots on that resource, each blocked one with why (drillspots.lua)
    if a.resource ~= nil and a.resource ~= false then
      assert(proto.type == 'mining-drill', 'resource goes with a mining drill or pumpjack')
      return api.drillspots(p, a, proto)
    end
    local at = a.near
    if at == nil then at = a.position end
    local pos = at ~= nil and api.position(at) or p.position
    local by
    if api.read_sight then by = api.read_sight(p, pos, 'near') else api.assert_visible(p, pos, 'position') end
    local pump = proto.type == 'offshore-pump'
    -- A radius or limit past the most is searched at the most, and said (friction3: Luna's radius 32 and Gemini's 30
    -- were refused).
    local notes = {}
    local function clamped(v, d, hi, name)
      if type(v) == 'number' and v > hi then notes[#notes+1] = string.format('%s %g is past the most, %d: searched at %d', name, v, hi, hi); return hi end
      return api.integer(v, d, 1, hi, name)
    end
    local radius = clamped(a.radius, pump and 12 or 10, 24, 'radius')
    local limit = clamped(a.limit, 10, 50, 'limit')
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
    -- (d18 batch39 D1, Opus: ~15 min in a dense oil block) fluids: only spots whose ports touch built segments of each
    -- of these fluids (a port's join tile, an entity of ours there with a connection back), none touching a segment of
    -- another fluid than that port's recipe takes (fluidjoin.lua touches, the join check of batch34 B1)
    local accept
    if a.fluids ~= nil then
      assert(type(a.fluids) == 'table' and #a.fluids >= 1 and #a.fluids <= 6, 'fluids: 1..6 fluid names its ports should touch')
      for _, f in ipairs(a.fluids) do assert(type(f) == 'string' and prototypes.fluid[f], 'unknown fluid ' .. tostring(f)) end
      assert(api.fluid_touches, 'fluids needs the fluid join reader')
      if a.recipe ~= nil then assert(type(a.recipe) == 'string' and prototypes.recipe[a.recipe], 'unknown recipe ' .. tostring(a.recipe)) end
      accept = function(position, dir)
        local ports = api.fluid_touches(p.surface, p.force, proto, position, dir, a.recipe)
        local got, parts, mix = {}, {}, nil
        for _, pt in ipairs(ports) do
          -- an empty segment holds no fluid to mix
          if pt.touches and pt.touches ~= 'empty' then got[pt.touches] = true end
          parts[#parts+1] = string.format('%s port at (%g,%g)%s: %s', pt.flow or 'its', pt.at.x, pt.at.y, pt.wants and ' (' .. pt.wants .. ')' or '',
            pt.touches and (pt.touches .. ' segment ' .. tostring(pt.segment) .. ' at ' .. pt.via) or 'nothing')
          if pt.touches and pt.touches ~= 'empty' and pt.wants and pt.touches ~= pt.wants then mix = mix or string.format('(%g,%g) %s: its %s port would join %s to its %s', position.x, position.y, NAMES[dir] or '', pt.flow or '', pt.touches, pt.wants) end
        end
        if mix then return false, mix end
        for _, f in ipairs(a.fluids) do if not got[f] then return false end end
        return true, {ports=ports, line=table.concat(parts, '; ')}
      end
    end
    local found, checked, info = M.find(p, proto, pos, radius, dirs, {limit=limit, seen=seen, separate=a.separate, powered=a.powered, accept=accept})
    local out = {name=proto.name, near=pos, radius=radius, placements=found, count=#found, checked=checked, by=by,
      blocked=info.blocked > 0 and info.blocked or nil, unseen=info.unseen > 0 and info.unseen or nil, more=info.more or nil,
      over_ghosts=info.ghosts > 0 and string.format('%d of these placements lie over a ghost (over_ghost names it): a build there replaces the ghost', info.ghosts) or nil,
      tile_ghosts=info.tile_ghosts and string.format('%d spot%s the game takes now left out: tile ghosts there break its tile rules once built (%s)', info.tile_ghosts, info.tile_ghosts == 1 and '' or 's', info.tile_ghost_why) or nil,
      separate=a.separate or nil, overlap=a.separate and info.overlap or nil,
      powered=a.powered or nil, unpowered=a.powered and info.unpowered or nil, poles=a.powered and info.poles or nil,
      note=#notes > 0 and table.concat(notes, '; ') or nil, fluids=a.fluids, recipe=a.recipe,
      rejected=info.rejected, mixes=info.reject_lines}
    -- friction3 (Gemini: 17 placements calls, 12 of them count 0, its accumulators built from overlapping spots): what is
    -- in the way when nothing fits; spots of the list that overlap each other, and those no pole supplies.
    local pad = api.one_pad and try(function() return api.one_pad(p.surface, p.force, proto) end)
    if pad then out.one_per_planet = pad end
    -- (d19 batch41 D3) spots the game takes, all failing the fluids test: said so, not "nothing fits"
    if #found == 0 and info.rejected and info.rejected > 0 then
      out.fluids_line = string.format('the game takes %d spot%s here; none has ports touching %s without joining another fluid%s', info.rejected, info.rejected == 1 and '' or 's',
        table.concat(a.fluids, ' and '), a.recipe and ' (recipe ' .. a.recipe .. ')' or '')
    elseif #found == 0 then out.in_the_way = pad or M.in_the_way(p, proto, pos, radius) end
    -- None fits: the spots that need the fewest of our entities (or trees and rocks) mined first (Astra 06:22, 4 times on
    -- Fulgora: a roboport in a full accumulator field), as a player would clear a site.
    if #found == 0 and not pad and not (info.rejected and info.rejected > 0) then
      local ok, sites = pcall(M.fewest_to_clear, p, proto, pos, radius, seen)
      if ok and sites and #sites > 0 then out.fewest_to_clear = sites end
    end
    if #found > 1 and not a.separate then
      local pairs_n = 0
      for i = 1, #found do
        local fi = found[i]
        local bi = box_of(proto, DIRS_BY_NAME[fi.direction] or 0)
        for j = i + 1, #found do
          local fj = found[j]
          local bj = box_of(proto, DIRS_BY_NAME[fj.direction] or 0)
          if fi.position.x + bi[1] < fj.position.x + bj[3] - EPS and fj.position.x + bj[1] < fi.position.x + bi[3] - EPS
            and fi.position.y + bi[2] < fj.position.y + bj[4] - EPS and fj.position.y + bj[2] < fi.position.y + bi[4] - EPS then pairs_n = pairs_n + 1 end
        end
      end
      if pairs_n > 0 then out.overlapping = string.format('%d pair%s of these spots overlap each other (each fits alone): separate=true lists spots that do not', pairs_n, pairs_n == 1 and '' or 's') end
    end
    if #found > 0 and try(function() return proto.electric_energy_source_prototype end) then
      local n = M.unpowered(p, proto, found)
      if n and n > 0 and not a.powered then out.no_supply = string.format('%d of these spots lie in no pole\'s supply area: powered=true lists spots that do', n) end
    end
    if not turns then for _, s in ipairs(found) do s.direction = nil end end
    return out
  end
  -- Built poles of ours whose supply area overlaps none of a spot's box: how many of the spots that is.
  function M.unpowered(p, proto, found)
    local x0, y0, x1, y1
    for _, f in ipairs(found) do
      x0 = math.min(x0 or f.position.x, f.position.x); y0 = math.min(y0 or f.position.y, f.position.y)
      x1 = math.max(x1 or f.position.x, f.position.x); y1 = math.max(y1 or f.position.y, f.position.y)
    end
    local poles = {}
    for _, e in pairs(p.surface.find_entities_filtered{area={left_top={x=x0 - 20, y=y0 - 20}, right_bottom={x=x1 + 20, y=y1 + 20}}, type='electric-pole', force=p.force, limit=2048}) do
      if e.valid then
        local q = try(function() return e.quality.name end)
        local d = try(function() return e.prototype.get_supply_area_distance(q or 'normal') end) or try(function() return e.prototype.supply_area_distance end) or 0
        if d > 0 then poles[#poles+1] = {x=e.position.x, y=e.position.y, d=d, name=e.name, net=try(function() return e.electric_network_id end)} end
      end
    end
    local n = 0
    for _, f in ipairs(found) do
      local b = box_of(proto, DIRS_BY_NAME[f.direction] or 0)
      local l, t, r, bt = f.position.x + b[1], f.position.y + b[2], f.position.x + b[3], f.position.y + b[4]
      local fed = false
      for _, q in ipairs(poles) do
        if l < q.x + q.d and r > q.x - q.d and t < q.y + q.d and bt > q.y - q.d then
          fed = true
          -- the network the spot would join (C10, Sol 15:21)
          f.network = q.net and ('#' .. q.net) or nil; f.pole = string.format('%s (%g,%g)', q.name, q.x, q.y)
          break
        end
      end
      if not fed then
        n = n + 1
        local best, bd
        for _, q in ipairs(poles) do
          local dd = ((q.x - f.position.x) ^ 2 + (q.y - f.position.y) ^ 2) ^ 0.5
          if not bd or dd < bd then best, bd = q, dd end
        end
        f.network = 'none'
        f.pole = best and string.format('in no supply area; the nearest pole %s (%g,%g) on #%s is %.1f tiles off', best.name, best.x, best.y, tostring(best.net), bd)
          or 'in no supply area; no pole of ours within 20 tiles'
      end
    end
    return n
  end
  -- When nothing fits: what stands in the search square, by name with the nearest one, cliffs among them, and the
  -- tiles it cannot stand on, by name (one entity and one tile read; at most 4000 each).
  -- Spots for proto (its north footprint, on the tile grid) within radius of pos whose blockers are all ours and
  -- minable, or trees and rocks, with no tile it cannot stand on: the 3 needing the fewest removed, nearest first among
  -- equals. One read of the area's entities and tiles; the spots are tried in Lua.
  -- Entities the game keeps to a 2-tile build grid (2.0.77 on a copy of world n, cargo-bay ghosts: (-10,29) -> (-10,30),
  -- (41,40) -> (42,40), (40.6,40.4) -> (40,40)): their footprint's corner on even tiles; the prototype does not tell it.
  M.GRID2 = {['cargo-bay']=true}
  function M.grid2(v, w) return math.floor((v - w / 2) / 2 + 0.5) * 2 + w / 2 end
  M.CLEAR_RADIUS = 12
  function M.fewest_to_clear(p, proto, pos, radius, seen)
    local s = p.surface
    local mask = try(function() return proto.collision_mask end)
    local layers = {}
    for layer in pairs(mask and mask.layers or {}) do layers[#layers+1] = layer end
    if #layers == 0 then return nil end
    local bx = box_of(proto, 0)
    -- (at most 12 tiles from pos: 625 spots; radius 24 with a 9x9 footprint read 93 ms in a 2.0.77 container)
    radius = math.min(radius, M.CLEAR_RADIUS)
    local reach = radius + 4
    local area = {left_top={x=pos.x - reach, y=pos.y - reach}, right_bottom={x=pos.x + reach, y=pos.y + reach}}
    local blockers = {}
    for _, e in pairs(try(function() return s.find_entities_filtered{area=area, collision_mask=layers, limit=4000} end) or {}) do
      if e.valid and not PASSABLE[e.type] then
        local bb = try(function() return e.bounding_box end)
        if bb then
          local ours = e.force == p.force and try(function() return e.minable end)
          local natural = e.type == 'tree' or (e.type == 'simple-entity' and try(function() return e.minable end))
          blockers[#blockers+1] = {e=e, l=bb.left_top.x, t=bb.left_top.y, r=bb.right_bottom.x, b=bb.right_bottom.y, ok=(ours or natural) and true or false}
        end
      end
    end
    -- Each blocker under every tile its box touches (a spot reads its own tiles only).
    local cell = {}
    for i, x in ipairs(blockers) do
      for tx = math.floor(x.l), math.ceil(x.r) - 1 do
        for ty = math.floor(x.t), math.ceil(x.b) - 1 do
          local k = tx * 65536 + ty
          local c = cell[k]
          if not c then c = {}; cell[k] = c end
          c[#c+1] = i
        end
      end
    end
    local bad_tiles = {}
    for _, tl in pairs(try(function() return s.find_tiles_filtered{area=area, collision_mask=layers, limit=8000} end) or {}) do
      bad_tiles[math.floor(tl.position.x) * 65536 + math.floor(tl.position.y)] = true
    end
    local w = try(function() return proto.tile_width end) or math.ceil(bx[3] - bx[1])
    local h = try(function() return proto.tile_height end) or math.ceil(bx[4] - bx[2])
    local ox, oy = (w % 2 == 1) and 0.5 or 0, (h % 2 == 1) and 0.5 or 0
    local sites = {}
    for dx = -radius, radius do
      for dy = -radius, radius do
        local cx, cy = math.floor(pos.x) + dx + ox, math.floor(pos.y) + dy + oy
        local on_grid = not M.GRID2[proto.type] or (math.abs(M.grid2(cx, w) - cx) < 0.01 and math.abs(M.grid2(cy, h) - cy) < 0.01)
        if on_grid and (dx * dx + dy * dy) <= radius * radius and (not seen or seen(cx, cy)) then
          local l, t, r, b = cx + bx[1], cy + bx[2], cx + bx[3], cy + bx[4]
          local okt = true
          for tx = math.floor(l), math.ceil(r) - 1 do
            for ty = math.floor(t), math.ceil(b) - 1 do if bad_tiles[tx * 65536 + ty] then okt = false end end
          end
          if okt then
            local hit, fine, done = {}, true, {}
            for tx = math.floor(l), math.ceil(r) - 1 do
              for ty = math.floor(t), math.ceil(b) - 1 do
                for _, i in ipairs(cell[tx * 65536 + ty] or {}) do
                  local x = blockers[i]
                  if not done[i] and x.l < r - EPS and l < x.r - EPS and x.t < b - EPS and t < x.b - EPS then
                    done[i] = true
                    if not x.ok then fine = false end
                    hit[#hit+1] = x.e
                  end
                end
              end
            end
            if fine and #hit > 0 then sites[#sites+1] = {x=cx, y=cy, hit=hit, d=dx * dx + dy * dy} end
          end
        end
      end
    end
    table.sort(sites, function(x, y) if #x.hit ~= #y.hit then return #x.hit < #y.hit end return x.d < y.d end)
    local out = {}
    for i = 1, math.min(3, #sites) do
      local st = sites[i]
      local by, order, at = {}, {}, {}
      for _, e in ipairs(st.hit) do
        if not by[e.name] then by[e.name] = 0; order[#order+1] = e.name end
        by[e.name] = by[e.name] + 1
        if #at < 6 then at[#at+1] = string.format('%s (%g,%g)', e.name, e.position.x, e.position.y) end
      end
      local parts = {}
      for _, n in ipairs(order) do parts[#parts+1] = n .. ' ' .. by[n] end
      out[i] = {position={x=st.x, y=st.y}, remove=#st.hit, line=string.format('(%g,%g): mine %d first (%s): %s%s', st.x, st.y, #st.hit,
        table.concat(parts, ', '), table.concat(at, ', '), #st.hit > #at and ', ...' or '')}
    end
    return out
  end
  function M.in_the_way(p, proto, pos, radius)
    local s = p.surface
    local area = {left_top={x=pos.x - radius, y=pos.y - radius}, right_bottom={x=pos.x + radius, y=pos.y + radius}}
    local mine = try(function() return proto.collision_mask end)
    local list = {}
    for layer in pairs(mine and mine.layers or {}) do list[#list+1] = layer end
    if #list == 0 then return nil end
    local by, order = {}, {}
    for _, e in pairs(try(function() return s.find_entities_filtered{area=area, collision_mask=list, limit=4000} end) or {}) do
      local ep = e.valid and not PASSABLE[e.type] and (e.position or try(function()
        local bb = e.bounding_box
        return {x=(bb.left_top.x + bb.right_bottom.x) / 2, y=(bb.left_top.y + bb.right_bottom.y) / 2}
      end))
      if ep then
        local n = e.name
        local b = by[n]
        if not b then b = {n=0}; by[n] = b; order[#order+1] = n end
        b.n = b.n + 1
        local d = (ep.x - pos.x) ^ 2 + (ep.y - pos.y) ^ 2
        if not b.d or d < b.d then b.d = d; b.at = ep end
      end
    end
    table.sort(order, function(x, y) return by[x].n > by[y].n end)
    local parts = {}
    for i = 1, math.min(6, #order) do
      local b = by[order[i]]
      parts[i] = string.format('%s %d (nearest (%g,%g))', order[i], b.n, b.at.x, b.at.y)
    end
    local tiles, tnames = {}, {}
    for _, t in pairs(try(function() return s.find_tiles_filtered{area=area, collision_mask=list, limit=4000} end) or {}) do
      if not tiles[t.name] then tiles[t.name] = 0; tnames[#tnames+1] = t.name end
      tiles[t.name] = tiles[t.name] + 1
    end
    table.sort(tnames, function(x, y) return tiles[x] > tiles[y] end)
    local tparts = {}
    for i = 1, math.min(4, #tnames) do tparts[i] = tnames[i] .. ' ' .. tiles[tnames[i]] end
    local text = {}
    if #parts > 0 then text[#text+1] = 'in the way: ' .. table.concat(parts, ', ') .. (#order > 6 and string.format(' and %d more kinds', #order - 6) or '') end
    if #tparts > 0 then text[#text+1] = string.format('tiles %s cannot stand on: %s', proto.name, table.concat(tparts, ', ')) end
    if #text == 0 then return nil end
    return string.format('nothing fits within %g tiles of (%g,%g): %s', radius, math.floor(pos.x * 10 + 0.5) / 10, math.floor(pos.y * 10 + 0.5) / 10,
      table.concat(text, '; '))
  end
  return M
end
