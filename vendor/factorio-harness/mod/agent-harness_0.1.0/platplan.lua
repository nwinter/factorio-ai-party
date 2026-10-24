-- platform_plan {platform}: a platform as planned, built and ghosts together (Sol 01:52: a 270-tile solar island no
-- foundation joined, and two belt crossings in the ammo loops, found by his own graph audit of exported blueprints).
-- Facts read from the surface: foundation tiles built and planned (tile ghosts) in 4-joined groups, the one with the hub
-- first, every other group an island with its size, a tile of it, how many of its tiles are ghosts and how many entity
-- ghosts stand on it; belts (transport belts, undergrounds, splitters, built and ghost) as a graph of the tile each one
-- moves its items to: closed loops (a cycle no belt leaves), belts that run head on into another (items stop), and
-- belts that feed another's side (side-loads), each with whether a ghost is in it. Read only.
return function(api)
  local M = {}
  local MAX_TILES, MAX_BELTS, LIST = 40000, 8000, 8
  -- The tiles an entity (or ghost) stands on that need foundation (d17 batch13 B3, Sol: Meridian's west asteroid
  -- collector at (-23.5,6.5) was asked for 3 floor tiles in front that the build then refuses): its box's tiles, less
  -- those a tile rule of its prototype keeps as empty space (an asteroid collector's collection area in front), the
  -- rule's area turned with the entity. {list of {x, y}, void (how many left out)}.
  local function rot(x, y, dir) for _ = 1, math.floor(((dir or 0) % 16) / 4) do x, y = -y, x end return x, y end
  function M.footprint(e)
    local ok, b = pcall(function() return e.bounding_box end)
    if not ok or not b then return {}, 0 end
    local proto = e.type == 'entity-ghost' and (pcall(function() return e.ghost_prototype end) and e.ghost_prototype) or (pcall(function() return e.prototype end) and e.prototype)
    local voids = {}
    local okr, rules = pcall(function() return proto.tile_buildability_rules end)
    for _, rule in ipairs(okr and rules or {}) do
      local empty = false
      for l in pairs(rule.required_tiles and rule.required_tiles.layers or {}) do if l == 'empty_space' then empty = true end end
      if empty and rule.area then
        local dir = e.direction
        local x1, y1 = rot(rule.area.left_top.x, rule.area.left_top.y, dir)
        local x2, y2 = rot(rule.area.right_bottom.x, rule.area.right_bottom.y, dir)
        voids[#voids+1] = {e.position.x + math.min(x1, x2), e.position.y + math.min(y1, y2), e.position.x + math.max(x1, x2), e.position.y + math.max(y1, y2)}
      end
    end
    local out, void = {}, 0
    for x = math.floor(b.left_top.x + 0.01), math.ceil(b.right_bottom.x - 0.01) - 1 do
      for y = math.floor(b.left_top.y + 0.01), math.ceil(b.right_bottom.y - 0.01) - 1 do
        local cx, cy, skip = x + 0.5, y + 0.5, false
        for _, v in ipairs(voids) do if cx > v[1] and cx < v[3] and cy > v[2] and cy < v[4] then skip = true end end
        if skip then void = void + 1 else out[#out+1] = {x=x, y=y} end
      end
    end
    return out, void
  end
  local VEC = {[0]={0,-1}, [4]={1,0}, [8]={0,1}, [12]={-1,0}}
  local BELT = {['transport-belt']=true, ['underground-belt']=true, splitter=true}
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  -- Numeric tile keys (a string key a tile cost 43 ms for 2345 tiles in the container, a number 5 ms).
  local function k(x, y) return (x + 32768) * 65536 + (y + 32768) end
  local function at(x, y) return string.format('(%g,%g)', x, y) end

  -- The foundation tile ghosts (d17 batch33 A1: a find with ghost_name='space-platform-foundation' errors on 2.0.77,
  -- "Unknown entity name": ghost_name takes entity names, and the try made it read as none): every tile ghost, kept
  -- when it is foundation.
  function M.foundation_ghosts(s)
    local out = {}
    for _, g in ipairs(try(function() return s.find_entities_filtered{type='tile-ghost', limit=MAX_TILES} end) or {}) do
      if try(function() return g.ghost_name end) == 'space-platform-foundation' then out[#out+1] = g end
    end
    return out
  end
  local function foundation(s, hub)
    local built = try(function() return s.find_tiles_filtered{name='space-platform-foundation', limit=MAX_TILES} end) or {}
    local ghosts = M.foundation_ghosts(s)
    local tiles, n = {}, 0
    for _, t in ipairs(built) do local p = t.position; tiles[k(p.x, p.y)] = {x=p.x, y=p.y}; n = n + 1 end
    for _, g in ipairs(ghosts) do
      local x, y = math.floor(g.position.x), math.floor(g.position.y)
      if not tiles[k(x, y)] then tiles[k(x, y)] = {x=x, y=y, ghost=true}; n = n + 1 end
    end
    local hx, hy = hub and math.floor(hub.position.x) or 0, hub and math.floor(hub.position.y) or 0
    local seen, groups = {}, {}
    for key, t in pairs(tiles) do
      if not seen[key] then
        local g = {size=0, ghosts=0, first=t, hub=false}
        local stack = {t}
        seen[key] = true
        while #stack > 0 do
          local c = table.remove(stack)
          g.size = g.size + 1
          if c.ghost then g.ghosts = g.ghosts + 1 end
          if c.x == hx and c.y == hy then g.hub = true end
          if c.x < g.first.x or (c.x == g.first.x and c.y < g.first.y) then g.first = c end
          for _, d in ipairs({{1,0},{-1,0},{0,1},{0,-1}}) do
            local nk = k(c.x + d[1], c.y + d[2])
            local nt = tiles[nk]
            if nt and not seen[nk] then seen[nk] = true; stack[#stack+1] = nt end
          end
        end
        groups[#groups+1] = g
      end
    end
    table.sort(groups, function(a, b) if a.hub ~= b.hub then return a.hub end return a.size > b.size end)
    return groups, n, #built >= MAX_TILES or #ghosts >= MAX_TILES
  end

  local function belts(s, force)
    local list = try(function() return s.find_entities_filtered{type={'transport-belt', 'underground-belt', 'splitter'}, force=force, limit=MAX_BELTS} end) or {}
    for _, g in ipairs(try(function() return s.find_entities_filtered{type='entity-ghost', ghost_type={'transport-belt', 'underground-belt', 'splitter'}, force=force, limit=MAX_BELTS} end) or {}) do
      list[#list+1] = g
    end
    local node = {}  -- tile -> {e, name, ghost, dir, x, y, out = {tiles}, under}
    for _, e in ipairs(list) do
      local ghost = e.type == 'entity-ghost'
      local t = ghost and e.ghost_type or e.type
      local name = ghost and e.ghost_name or e.name
      local dir = e.direction or 0
      local v = VEC[dir]
      if v and BELT[t] then
        local cx, cy = e.position.x, e.position.y
        local cells = {}
        if t == 'splitter' then
          -- two tiles side by side across its direction
          local px, py = -v[2] * 0.5, v[1] * 0.5
          cells = {{cx + px, cy + py}, {cx - px, cy - py}}
        else cells = {{cx, cy}} end
        local under = t == 'underground-belt' and (try(function() return e.belt_to_ground_type end) or (ghost and try(function() return e.ghost_prototype and nil end)))
        local partner = t == 'underground-belt' and not ghost and try(function() local n = e.neighbours; return n and n.valid and n or nil end)
        for _, c in ipairs(cells) do
          local x, y = math.floor(c[1]), math.floor(c[2])
          local n = {name=name, ghost=ghost, dir=dir, x=x, y=y, type=t, under=under}
          if t == 'underground-belt' and under == 'input' then
            n.out = partner and {k(math.floor(partner.position.x), math.floor(partner.position.y))} or {}
            n.open = not partner
          else
            n.out = {k(x + v[1], y + v[2])}
          end
          node[k(x, y)] = n
        end
      end
    end
    return node, #list
  end

  local function label(n) return (n.ghost and 'ghost of ' or '') .. n.name .. ' ' .. at(n.x + 0.5, n.y + 0.5) end

  local function audit_belts(node)
    local head, side, loops = {}, {}, {}
    local pairs_head = {}
    -- What feeds each belt: from behind (straight on), or from a side.
    local behind, sides = {}, {}
    for key, n in pairs(node) do
      for _, o in ipairs(n.out) do
        local m = node[o]
        if m and m ~= n and not (n.type == 'underground-belt' and n.under == 'input') then
          if m.dir == n.dir then behind[o] = true
          elseif (m.dir - n.dir) % 8 == 4 then sides[o] = (sides[o] or 0) + 1 end
        end
      end
    end
    for key, n in pairs(node) do
      for _, o in ipairs(n.out) do
        local m = node[o]
        if m and m ~= n and not (n.type == 'underground-belt' and n.under == 'input') then
          -- An underground output takes items from the tile behind it only; an input's mouth faces the way it flows.
          local opposite = (m.dir - n.dir) % 16 == 8
          local across = (m.dir - n.dir) % 8 == 4
          if opposite and m.type ~= 'underground-belt' then
            local a, b = key, o
            if a > b then a, b = b, a end
            if not pairs_head[a .. ':' .. b] then
              pairs_head[a .. ':' .. b] = true
              head[#head+1] = label(n) .. ' and ' .. label(m) .. ' run head on into each other'
            end
          elseif across and m.type == 'transport-belt' and (behind[o] or (sides[o] or 0) > 1) then
            -- One belt coming in from a side alone makes a curve; with a belt behind it (or both sides) it is a side-load.
            side[#side+1] = label(n) .. ' feeds the side of ' .. label(m)
          end
        end
      end
    end
    -- Closed loops: strongly connected groups of 2+ belts that no belt leaves.
    local index, low, onstack, st, count = {}, {}, {}, {}, 0
    local comps = {}
    local function strong(v)
      count = count + 1; index[v] = count; low[v] = count; st[#st+1] = v; onstack[v] = true
      for _, w in ipairs(node[v].out) do
        if node[w] then
          if not index[w] then strong(w); low[v] = math.min(low[v], low[w])
          elseif onstack[w] then low[v] = math.min(low[v], index[w]) end
        end
      end
      if low[v] == index[v] then
        local comp = {}
        repeat local w = table.remove(st); onstack[w] = nil; comp[#comp+1] = w until w == v
        if #comp > 1 then comps[#comps+1] = comp end
      end
    end
    local keys = {}
    for key in pairs(node) do keys[#keys+1] = key end
    table.sort(keys)
    for _, key in ipairs(keys) do if not index[key] and count < 20000 then pcall(strong, key) end end
    for _, comp in ipairs(comps) do
      -- Two belts facing each other are named head on, not a loop.
      local pair2 = #comp == 2 and (node[comp[1]].dir - node[comp[2]].dir) % 16 == 8
      if pair2 then goto continue end
      local set, exits, ghosts = {}, 0, 0
      for _, key in ipairs(comp) do set[key] = true end
      for _, key in ipairs(comp) do
        local n = node[key]
        if n.ghost then ghosts = ghosts + 1 end
        for _, o in ipairs(n.out) do if not set[o] then exits = exits + 1 end end
      end
      local first = node[comp[1]]
      for _, key in ipairs(comp) do local n = node[key]; if n.x < first.x or (n.x == first.x and n.y < first.y) then first = n end end
      loops[#loops+1] = {belts=#comp, ghosts=ghosts, exits=exits, first=label(first),
        line=string.format('%d belts in a loop from %s%s, %s', #comp, label(first), ghosts > 0 and string.format(' (%d of them ghosts)', ghosts) or '',
          exits == 0 and 'no belt leaves it' or string.format('%d way%s out', exits, exits == 1 and '' or 's'))}
      ::continue::
    end
    table.sort(loops, function(a, b) return a.belts > b.belts end)
    table.sort(head); table.sort(side)
    return head, side, loops
  end

  -- Tiles as rectangles of neighbouring tiles (one deconstruct call each): runs on a row, then the same run on the next rows.
  function M.rects(taken)
    table.sort(taken, function(u, v) if u.y ~= v.y then return u.y < v.y end return u.x < v.x end)
    local areas = {}
    for _, t in ipairs(taken) do
      local last = areas[#areas]
      if last and last.y == t.y and last.x1 == t.x - 1 then last.x1 = t.x
      else areas[#areas+1] = {y=t.y, x0=t.x, x1=t.x} end
    end
    local rects, open = {}, {}
    for _, r in ipairs(areas) do
      local key = r.x0 .. ':' .. r.x1
      local o = open[key]
      if o and o.y1 == r.y - 1 then o.y1 = r.y
      else o = {x0=r.x0, x1=r.x1, y0=r.y, y1=r.y}; open[key] = o; rects[#rects+1] = o end
    end
    local out = {}
    for i, r in ipairs(rects) do out[i] = {left_top={x=r.x0, y=r.y0}, right_bottom={x=r.x1 + 1, y=r.y1 + 1}} end
    return out
  end
  -- salvage (C6, Astra 13:50: Wren's salvage took about 60 deconstruct calls and a second pass): up to n built foundation
  -- tiles to take up, from the edge in, farthest from the hub first. A tile qualifies when nothing of ours stands on it
  -- (built or ghost, whole footprints), no planned tile ghost is there, no underground belt or pipe passes under it, and the
  -- foundation left stays joined round it (its remaining neighbours meet within the 8 tiles round it), so everything
  -- still on the hub's foundation stays joined to it and every planned ghost keeps its tiles. Read only.
  function M.salvage(s, force, hub, n)
    local built = try(function() return s.find_tiles_filtered{name='space-platform-foundation', limit=MAX_TILES} end) or {}
    local tile = {}
    for _, t in ipairs(built) do tile[k(t.position.x, t.position.y)] = true end
    local keep, tg = {}, {}
    for _, g in ipairs(try(function() return s.find_entities_filtered{type='tile-ghost', limit=MAX_TILES} end) or {}) do
      keep[k(math.floor(g.position.x), math.floor(g.position.y))] = true
      tg[k(math.floor(g.position.x), math.floor(g.position.y))] = true
    end
    local ents = try(function() return s.find_entities_filtered{force=force} end) or {}
    for _, e in ipairs(ents) do
      -- (d24 batch162 QE1) what stands on the floor (M.stands): a rocket or beam passing over keeps no tile
      if e.valid and M.stands(e) then
        local b = e.bounding_box
        for x = math.floor(b.left_top.x), math.ceil(b.right_bottom.x) - 1 do
          for y = math.floor(b.left_top.y), math.ceil(b.right_bottom.y) - 1 do keep[k(x, y)] = true end
        end
      end
    end
    -- every underground belt and pipe-to-ground span, built or ghost, paired as the floor plan pairs them
    local ghosts = {}
    for _, e in ipairs(ents) do if e.valid and e.type == 'entity-ghost' then ghosts[#ghosts+1] = e end end
    M.tunnels(s, force, ghosts, function(x, y) keep[k(x, y)] = true end)
    local hx, hy = hub and math.floor(hub.position.x) or 0, hub and math.floor(hub.position.y) or 0
    local RING = {{-1,-1},{0,-1},{1,-1},{1,0},{1,1},{0,1},{-1,1},{-1,0}}
    -- removing (x,y) keeps its remaining 4-neighbours joined through the ring of 8 round it
    local function local_ok(x, y)
      local on, first = {}, nil
      for i, d in ipairs(RING) do on[i] = tile[k(x + d[1], y + d[2])] == true end
      local orth = {}
      for _, i in ipairs({2, 4, 6, 8}) do if on[i] then orth[#orth+1] = i end end
      if #orth == 0 then return false end
      local seen, stack = {[orth[1]]=true}, {orth[1]}
      while #stack > 0 do
        local i = table.remove(stack)
        for _, j in ipairs({(i % 8) + 1, ((i - 2) % 8) + 1}) do
          if on[j] and not seen[j] then seen[j] = true; stack[#stack+1] = j end
        end
      end
      for _, i in ipairs(orth) do if not seen[i] then return false end end
      return true
    end
    local function edge(x, y)
      for _, d in ipairs({{1,0},{-1,0},{0,1},{0,-1}}) do if not tile[k(x + d[1], y + d[2])] then return true end end
      return false
    end
    local taken = {}
    for _ = 1, 64 do
      if #taken >= n then break end
      local cand = {}
      for key in pairs(tile) do
        if not keep[key] then
          local x, y = math.floor(key / 65536) - 32768, key % 65536 - 32768
          if edge(x, y) then cand[#cand+1] = {x=x, y=y, d=(x - hx) ^ 2 + (y - hy) ^ 2} end
        end
      end
      table.sort(cand, function(u, v) if u.d ~= v.d then return u.d > v.d end if u.y ~= v.y then return u.y < v.y end return u.x < v.x end)
      local progress = false
      for _, c in ipairs(cand) do
        if #taken >= n then break end
        local key = k(c.x, c.y)
        if tile[key] and edge(c.x, c.y) and local_ok(c.x, c.y) then
          tile[key] = nil; taken[#taken+1] = {x=c.x, y=c.y}; progress = true
        end
      end
      if not progress then break end
    end
    -- (batch27 A2, Astra: 217 tiles salvaged then needed 88 put back) a taken tile in a hole the tile ghosts would then
    -- close stays: the hub never builds the last ghost round a hole, so the hole would have to be planned again.
    local holes = M.must_fill(tile, tg, M.keep_open(s, force))
    local info = {restored=0, unfilled=0, holes_unchecked=holes == nil or nil}
    if holes and #holes > 0 then
      local back = {}
      for _, t in ipairs(holes) do back[k(t.x, t.y)] = true end
      local kept = {}
      for _, t in ipairs(taken) do
        if back[k(t.x, t.y)] then info.restored = info.restored + 1; tile[k(t.x, t.y)] = true; back[k(t.x, t.y)] = nil
        else kept[#kept+1] = t end
      end
      taken = kept
      for _ in pairs(back) do info.unfilled = info.unfilled + 1 end
    end
    -- the removals played through the hub's rule (tilecheck.lua): each goes only beside one run of empty space
    local plan = try(function()
      local list = {}
      for i, t in ipairs(taken) do list[i] = {t.x, t.y} end
      return require('tilecheck')().plan_removals(s, list, hub, {})
    end)
    if plan then
      info.go = #plan.go
      info.waiting = {}
      for i, w in ipairs(plan.waiting) do if i <= LIST then info.waiting[i] = string.format('%s: %s', at(w[1] + 0.5, w[2] + 0.5), w[3]) end end
      info.waiting_n = #plan.waiting
    end
    return taken, M.rects(taken), #built >= MAX_TILES, info
  end
  local DIRV = {[0]={0,-1}, [4]={1,0}, [8]={0,1}, [12]={-1,0}}
  -- The tiles each underground belt or pipe-to-ground pair passes under (built or ghost), on(x, y) once a tile; the
  -- floor plan asks for them and salvage keeps them (d17 batch17 A4, Sol: salvage on Meridian took 26 tiles under
  -- underground pipe spans; it kept belt spans only, from the built pair). ghosts: the surface's entity ghosts.
  -- on(x, y, entrance, exit): the pair as its last two (batch31 B4: the tile deconstruct names it).
  function M.tunnels(s, force, ghosts, on)
    local unders = {}
    for _, e in ipairs(try(function() return s.find_entities_filtered{type={'underground-belt', 'pipe-to-ground'}, force=force} end) or {}) do
      if e.valid and e.position and (e.type == 'underground-belt' or e.type == 'pipe-to-ground') then unders[#unders+1] = e end
    end
    for _, g in ipairs(ghosts) do
      local t = try(function() return g.ghost_type end)
      if t == 'underground-belt' or t == 'pipe-to-ground' then unders[#unders+1] = g end
    end
    local at_tile = {}
    for _, e in ipairs(unders) do at_tile[k(math.floor(e.position.x), math.floor(e.position.y))] = e end
    for _, e in ipairs(unders) do
      local ghost = e.type == 'entity-ghost'
      local t = ghost and e.ghost_type or e.type
      local name = ghost and e.ghost_name or e.name
      local proto = prototypes.entity[name]
      local reach = t == 'underground-belt' and (try(function() return proto.max_underground_distance end) or 5)
        or (try(function() return proto.fluidbox_prototypes[1].pipe_connections[2].max_underground_distance end) or 10)
      local input = t == 'underground-belt' and try(function() return e.belt_to_ground_type end) == 'input'
      local v = DIRV[e.direction or 0]
      -- the way the span runs: an underground belt entrance faces its travel; a pipe-to-ground's tunnel leaves the way it
      -- does not face (its open end faces back)
      local d = v and (t == 'underground-belt' and v or {-v[1], -v[2]})
      if d and (t == 'pipe-to-ground' or input) then
        local x0, y0 = math.floor(e.position.x), math.floor(e.position.y)
        -- The exit: one of its name on the line facing the same way (an underground belt's exit faces its travel as the
        -- entrance does; a pipe-to-ground's faces back at it). An underground crossing the span (another direction) is
        -- passed over (d17 batch16 A3, Astra on Wren, board #825: an east-going underground one tile into a southward
        -- span ended the walk there, so the floor under the rest of the span was never asked for; the pair, built over
        -- one empty tile, stayed unpaired and the chunk bus stopped). A same-way entrance first: no pair.
        local want_dir = t == 'underground-belt' and (e.direction or 0) or ((e.direction or 0) + 8) % 16
        for step = 1, reach + 1 do
          local o = at_tile[k(x0 + d[1] * step, y0 + d[2] * step)]
          local oname = o and (o.type == 'entity-ghost' and o.ghost_name or o.name)
          if o and oname == name and o ~= e and (o.direction or 0) == want_dir then
            local oin = t == 'underground-belt' and try(function() return o.belt_to_ground_type end) == 'input'
            if not oin then for j = 1, step - 1 do on(x0 + d[1] * j, y0 + d[2] * j, e, o) end end
            break
          end
        end
      end
    end
  end
  -- An asteroid collector's or thruster's open space stays open: the tiles within 4 of one, as a set of keys.
  function M.keep_open(s, force)
    local keep_open = {}
    for _, e in ipairs(try(function() return s.find_entities_filtered{type={'asteroid-collector', 'thruster'}, force=force} end) or {}) do
      local b = e.bounding_box
      for x = math.floor(b.left_top.x) - 4, math.ceil(b.right_bottom.x) + 3 do
        for y = math.floor(b.left_top.y) - 4, math.ceil(b.right_bottom.y) + 3 do keep_open[k(x, y)] = true end
      end
    end
    return keep_open
  end
  -- The holes a plan must fill (batch27 A2, Astra: Kestrel III's support trim left 1,041 unbuildable pocket tiles, and
  -- 217 tiles salvaged then needed 88 put back): the empty tiles that built and planned floor together enclose but open
  -- space still reaches when built floor alone counts. The hub never builds a foundation ghost that splits empty space
  -- (tilecheck.lua), so the last ghost round such a hole waits for good unless every tile of the hole holds one. A hole
  -- built floor alone encloses stays open. built, plan, keep_open: sets of tile keys. Returns {x, y} each, by row; nil
  -- when the box is too big to look at (over 250000 tiles).
  function M.must_fill(built, plan, keep_open)
    local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
    for _, set in ipairs({built, plan}) do
      for key in pairs(set) do
        local x, y = math.floor(key / 65536) - 32768, key % 65536 - 32768
        x0, y0, x1, y1 = math.min(x0, x), math.min(y0, y), math.max(x1, x), math.max(y1, y)
      end
    end
    if x0 == math.huge then return {} end
    if (x1 - x0 + 3) * (y1 - y0 + 3) > 250000 then return nil end
    local function flood(solid)
      local out, stack = {[k(x0 - 1, y0 - 1)]=true}, {{x0 - 1, y0 - 1}}
      while #stack > 0 do
        local c = table.remove(stack)
        for _, dd in ipairs({{1,0},{-1,0},{0,1},{0,-1}}) do
          local x, y = c[1] + dd[1], c[2] + dd[2]
          if x >= x0 - 1 and x <= x1 + 1 and y >= y0 - 1 and y <= y1 + 1 then
            local key = k(x, y)
            if not out[key] and not solid(key) then out[key] = true; stack[#stack+1] = {x, y} end
          end
        end
      end
      return out
    end
    local open_plan = flood(function(key) return built[key] or plan[key] end)
    local open_built = flood(function(key) return built[key] end)
    local list = {}
    for y = y0, y1 do
      for x = x0, x1 do
        local key = k(x, y)
        if not built[key] and not plan[key] and not open_plan[key] and open_built[key] and not (keep_open or {})[key] then list[#list+1] = {x=x, y=y} end
      end
    end
    return list
  end
  -- floor (B4, Astra 18:20: Kestrel needed three floor corrections; footprint-only placement missed tunnels and holes):
  -- the foundation every entity ghost needs, as a placement plan. Tiles needed: each ghost's footprint; the tiles an
  -- underground belt or pipe-to-ground pair (built or ghost; a ghost entrance paired with the first exit of its name
  -- facing the same way within its reach) passes under; the holes no foundation reaches from outside the platform's
  -- box (enclosed); and, for a needed group not joined to the hub's foundation, the shortest run of tiles that joins
  -- it. Tiles built or with a tile ghost already count as there. Read only.
  function M.floor(s, force, hub)
    local have = {}
    for _, t in ipairs(try(function() return s.find_tiles_filtered{name='space-platform-foundation', limit=MAX_TILES} end) or {}) do have[k(t.position.x, t.position.y)] = true end
    for _, g in ipairs(try(function() return s.find_entities_filtered{type='tile-ghost', limit=MAX_TILES} end) or {}) do
      have[k(math.floor(g.position.x), math.floor(g.position.y))] = true
    end
    local need, why = {}, {foot=0, tunnel=0, hole=0, link=0}
    local function want(x, y, kind) local key = k(x, y); if not have[key] and not need[key] then need[key] = {x=x, y=y, kind=kind}; why[kind] = why[kind] + 1 end end
    local ghosts = try(function() return s.find_entities_filtered{type='entity-ghost', force=force, limit=8192} end) or {}
    for _, g in ipairs(ghosts) do
      for _, t in ipairs((M.footprint(g))) do want(t.x, t.y, 'foot') end
    end
    -- Tunnels: underground belts and pipes-to-ground, built or ghost.
    M.tunnels(s, force, ghosts, function(x, y) want(x, y, 'tunnel') end)
    -- Holes: empty tiles inside the box of foundation and needed tiles that no empty tile on the box's edge reaches.
    local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
    local function grow(key)
      local x, y = math.floor(key / 65536) - 32768, key % 65536 - 32768
      x0, y0, x1, y1 = math.min(x0, x), math.min(y0, y), math.max(x1, x), math.max(y1, y)
    end
    for key in pairs(have) do grow(key) end
    for key in pairs(need) do grow(key) end
    if x0 < math.huge and (x1 - x0 + 3) * (y1 - y0 + 3) <= 250000 then
      local function solid(x, y) local key = k(x, y); return have[key] or need[key] end
      local outside, stack = {}, {{x0 - 1, y0 - 1}}
      outside[k(x0 - 1, y0 - 1)] = true
      while #stack > 0 do
        local c = table.remove(stack)
        for _, dd in ipairs({{1,0},{-1,0},{0,1},{0,-1}}) do
          local x, y = c[1] + dd[1], c[2] + dd[2]
          if x >= x0 - 1 and x <= x1 + 1 and y >= y0 - 1 and y <= y1 + 1 then
            local key = k(x, y)
            if not outside[key] and not solid(x, y) then outside[key] = true; stack[#stack+1] = {x, y} end
          end
        end
      end
      local keep_open = M.keep_open(s, force)
      for x = x0, x1 do for y = y0, y1 do if not solid(x, y) and not outside[k(x, y)] and not keep_open[k(x, y)] then want(x, y, 'hole') end end end
    end
    -- Links: a group of needed tiles not 4-joined to the hub's foundation gets the shortest straight-then-turning run to it.
    local hx, hy = hub and math.floor(hub.position.x) or 0, hub and math.floor(hub.position.y) or 0
    local function joined()
      local seen, stack = {[k(hx, hy)]=true}, {{hx, hy}}
      while #stack > 0 do
        local c = table.remove(stack)
        for _, dd in ipairs({{1,0},{-1,0},{0,1},{0,-1}}) do
          local x, y = c[1] + dd[1], c[2] + dd[2]
          local key = k(x, y)
          if not seen[key] and (have[key] or need[key]) then seen[key] = true; stack[#stack+1] = {x, y} end
        end
      end
      return seen
    end
    for _ = 1, 32 do
      local seen = joined()
      local far
      for key, t in pairs(need) do if not seen[key] then far = t; break end end
      if not far then break end
      -- the nearest joined tile, then an L of tiles to it
      local best, bd
      for key in pairs(seen) do
        local x, y = math.floor(key / 65536) - 32768, key % 65536 - 32768
        local dd = math.abs(x - far.x) + math.abs(y - far.y)
        if not bd or dd < bd then best, bd = {x=x, y=y}, dd end
      end
      if not best then break end
      local x, y = far.x, far.y
      while x ~= best.x do x = x + (best.x > x and 1 or -1); want(x, y, 'link') end
      while y ~= best.y do y = y + (best.y > y and 1 or -1); want(x, y, 'link') end
    end
    local list = {}
    for _, t in pairs(need) do list[#list+1] = t end
    table.sort(list, function(u, v) if u.y ~= v.y then return u.y < v.y end return u.x < v.x end)
    return list, why
  end
  -- (d24 batch162 QE1, Sol #2213: support true planned floor out to (29.5,-54.5), 11 tiles for one tile of a rocket in
  -- flight) whether an entity of ours stands on the floor: a ghost, or a built entity; never one passing over it (a
  -- rocket or other projectile, a laser beam, a cargo pod, a robot) or anything not selectable in game, read once a name.
  local PASSING = {projectile=true, ['artillery-projectile']=true, beam=true, ['cargo-pod']=true, stream=true, fire=true, sticker=true,
    explosion=true, ['smoke-with-trigger']=true, ['particle-source']=true, ['highlight-box']=true, ['speech-bubble']=true,
    ['logistic-robot']=true, ['construction-robot']=true, ['combat-robot']=true, ['capture-robot']=true, character=true,
    ['character-corpse']=true, corpse=true, ['item-entity']=true, ['item-request-proxy']=true, ['tile-ghost']=true,
    asteroid=true, resource=true, ['deconstructible-tile-proxy']=true}
  local selectable = {}
  function M.stands(e)
    if PASSING[e.type] then return false end
    if e.type == 'entity-ghost' then return true end
    local name = e.name
    if name == nil then return true end
    if selectable[name] == nil then
      local ok, v = pcall(function() return e.prototype.selectable_in_game end)
      selectable[name] = not (ok and v == false)
    end
    return selectable[name]
  end
  -- An entity named for a tile planned for it: {name, unit_number, position}.
  local function named_entity(e)
    if not (e and e.valid) then return nil end
    return {name=e.type == 'entity-ghost' and 'ghost ' .. e.ghost_name or e.name, unit_number=e.unit_number, position={x=e.position.x, y=e.position.y}}
  end
  -- support (batch26 C3, Sol: 1,619 foundation ghosts trimmed by hand over 32 launches after a blanket of tile ghosts):
  -- the foundation the chosen entities (built and ghost) need and nothing more: their footprints, the tiles under the
  -- underground belt and pipe-to-ground spans (built pairs and the chosen ghosts'), and for a group of those not joined
  -- to the hub's foundation the fewest tiles that join it (through tile ghosts or empty space). Holes are not filled.
  -- The foundation tile ghosts outside that are the ones it would remove; strands: the entity ghosts not chosen that
  -- stand on one of them. Read only. chosen: the chosen entities; returns a table.
  function M.support(s, force, hub, chosen)
    local built, ghost = {}, {}
    for _, t in ipairs(try(function() return s.find_tiles_filtered{name='space-platform-foundation', limit=MAX_TILES} end) or {}) do built[k(t.position.x, t.position.y)] = true end
    local tile_ghosts = M.foundation_ghosts(s)
    for _, g in ipairs(tile_ghosts) do
      local key = k(math.floor(g.position.x), math.floor(g.position.y))
      if not built[key] then ghost[key] = true end
    end
    local keep, why, is_chosen, chosen_ghosts = {}, {foot=0, tunnel=0, link=0}, {}, {}
    -- (QE1) of: the entity the tile is for (its footprint, its underground's span, the group a link joins)
    local function want(x, y, kind, of)
      local key = k(x, y)
      if not built[key] and not keep[key] then keep[key] = {x=x, y=y, kind=kind, ghost=ghost[key], of=of}; why[kind] = why[kind] + 1 end
    end
    for _, e in ipairs(chosen) do
      is_chosen[e] = true
      if e.type == 'entity-ghost' then chosen_ghosts[#chosen_ghosts+1] = e end
      for _, t in ipairs((M.footprint(e))) do want(t.x, t.y, 'foot', e) end
    end
    M.tunnels(s, force, chosen_ghosts, function(x, y, e) want(x, y, 'tunnel', e) end)
    local function solid(key) return built[key] or keep[key] end
    -- Links: from the tiles joined to the hub, the fewest tiles to the nearest needed group not joined, one group at a time.
    local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
    for _, set in ipairs({built, ghost, keep}) do
      for key in pairs(set) do
        local x, y = math.floor(key / 65536) - 32768, key % 65536 - 32768
        x0, y0, x1, y1 = math.min(x0, x), math.min(y0, y), math.max(x1, x), math.max(y1, y)
      end
    end
    local hx, hy = hub and math.floor(hub.position.x) or 0, hub and math.floor(hub.position.y) or 0
    local D4 = {{1,0},{-1,0},{0,1},{0,-1}}
    local unjoined = 0
    if x0 < math.huge and (x1 - x0 + 9) * (y1 - y0 + 9) <= 250000 then
      for _ = 1, 32 do
        local seen, queue = {[k(hx, hy)]=true}, {{hx, hy}}
        local i = 1
        while queue[i] do
          local c = queue[i]; i = i + 1
          for _, d in ipairs(D4) do
            local key = k(c[1] + d[1], c[2] + d[2])
            if not seen[key] and solid(key) then seen[key] = true; queue[#queue+1] = {c[1] + d[1], c[2] + d[2]} end
          end
        end
        local left = false
        for key in pairs(keep) do if not seen[key] then left = true; break end end
        if not left then break end
        -- breadth first over the tiles neither built nor kept, from every joined tile, to the first kept tile not joined
        local from, j, goal, reached = {}, 1, nil, nil
        local q2 = {}
        for _, c in ipairs(queue) do q2[#q2+1] = c end
        while q2[j] and not goal do
          local c = q2[j]; j = j + 1
          for _, d in ipairs(D4) do
            local x, y = c[1] + d[1], c[2] + d[2]
            local key = k(x, y)
            if x >= x0 - 4 and x <= x1 + 4 and y >= y0 - 4 and y <= y1 + 4 and not seen[key] then
              seen[key] = true
              if solid(key) then goal, reached = c, key; break end
              from[key] = c; q2[#q2+1] = {x, y}
            end
          end
        end
        if not goal then unjoined = unjoined + 1; break end
        local c = goal
        local of = reached and keep[reached] and keep[reached].of
        while c and from[k(c[1], c[2])] ~= nil do want(c[1], c[2], 'link', of); c = from[k(c[1], c[2])] end
      end
    end
    -- Holes the kept floor would enclose (A2): every tile of one is needed, or the last ghost round it never builds.
    why.hole = 0
    local keep_set = {}
    for key in pairs(keep) do keep_set[key] = true end
    local holes = M.must_fill(built, keep_set, M.keep_open(s, force))
    for _, t in ipairs(holes or {}) do want(t.x, t.y, 'hole') end
    -- The plan played through the hub's build rules (tilecheck.lua): the kept and added ghosts it never builds.
    local stalls, unchecked = {}, 0
    local tc = require('tilecheck')()
    local cache, ghosts = {}, {}
    for key in pairs(built) do cache[tc.key(math.floor(key / 65536) - 32768, key % 65536 - 32768)] = false end
    for key in pairs(ghost) do cache[tc.key(math.floor(key / 65536) - 32768, key % 65536 - 32768)] = true end
    for _, t in pairs(keep) do cache[tc.key(t.x, t.y)] = true; ghosts[#ghosts+1] = {t.x, t.y} end
    table.sort(ghosts, function(u, v) if u[2] ~= v[2] then return u[2] < v[2] end return u[1] < v[1] end)
    local thrusters = try(function() return s.find_entities_filtered{type='thruster', force=force} end) or {}
    local played = try(function() return tc.play(s, ghosts, hub, thrusters, cache, 40000) end)
    if played then
      unchecked = played.left
      for _, g in ipairs(ghosts) do
        if not played.built[tc.key(g[1], g[2])] then
          local r = played.rule(g)
          stalls[#stalls+1] = string.format('%s: %s', at(g[1] + 0.5, g[2] + 0.5), type(r) == 'string' and r
            or type(r) == 'table' and 'building it would split the empty space beside it' or 'waits on a tile beside it')
        end
      end
    end
    -- what goes: the foundation tile ghosts outside keep
    local remove, removed = {}, {}
    for key in pairs(ghost) do
      if not keep[key] then
        removed[key] = true
        remove[#remove+1] = {x=math.floor(key / 65536) - 32768, y=key % 65536 - 32768}
      end
    end
    table.sort(remove, function(u, v) if u.y ~= v.y then return u.y < v.y end return u.x < v.x end)
    local add, kept_ghosts = {}, 0
    for _, t in pairs(keep) do if t.ghost then kept_ghosts = kept_ghosts + 1 else add[#add+1] = t end end
    table.sort(add, function(u, v) if u.y ~= v.y then return u.y < v.y end return u.x < v.x end)
    local strands = {}
    if #remove > 0 then
      for _, g in ipairs(try(function() return s.find_entities_filtered{type='entity-ghost', force=force, limit=8192} end) or {}) do
        if not is_chosen[g] then
          for _, t in ipairs((M.footprint(g))) do
            if removed[k(t.x, t.y)] then strands[#strands+1] = string.format('%s %s', g.ghost_name, at(g.position.x, g.position.y)); break end
          end
        end
      end
    end
    return {remove=remove, add=add, kept_ghosts=kept_ghosts, tile_ghosts=#tile_ghosts, why=why, strands=strands, unjoined=unjoined,
      holes_unchecked=holes == nil or nil, stalls=stalls, unchecked=unchecked > 0 and unchecked or nil}
  end
  -- ready {positions?, area?, tiles?} (D2, Sol 00:20: Meridian's 779-tile core read against a capped 1000-ghost list that
  -- mixed in the hull he deferred on purpose): a chosen subset only. The entity ghosts at the positions and in the area,
  -- the tile ghosts in tiles (one area or a list): what they need of each item against what the hub holds (missing),
  -- the support under each entity ghost's footprint (built foundation, a tile ghost, or empty space with none: never
  -- built), and settings (an assembler ghost with no recipe); positions that hold a built entity or nothing are said.
  local READY_MAX, POCKET_MAX, POCKETS, PAGE_ENTRIES, LOOKS = 2000, 1024, 8, 512, 1536
  local function item_of(proto)
    local list = proto and try(function() return proto.items_to_place_this end)
    local f = list and list[1]
    if not f then return nil end
    return type(f.name) == 'string' and f.name or try(function() return f.name.name end), f.count or 1
  end
  local function areas_of(v, what)
    assert(type(v) == 'table', what .. ' is an area {left_top, right_bottom} or a list of them')
    local list = (v.left_top or v[1] and type(v[1]) == 'table' and v[1].x ~= nil) and {v} or v
    local out = {}
    for _, ar in ipairs(list) do
      local lt, rb = ar.left_top or ar[1], ar.right_bottom or ar[2]
      assert(lt and rb and lt.x < rb.x and lt.y < rb.y and rb.x - lt.x <= 256 and rb.y - lt.y <= 256, what .. ': each area nonempty, at most 256x256')
      out[#out+1] = {{lt.x, lt.y}, {rb.x, rb.y}}
    end
    assert(#out >= 1 and #out <= 16, what .. ': 1..16 areas')
    return out
  end
  function M.ready(p, pl, r)
    assert(type(r) == 'table' and (r.positions ~= nil or r.area ~= nil or r.tiles ~= nil), 'ready is {positions, area, tiles}: the ghosts at those positions, in that area, the tile ghosts in those tiles (any of them)')
    local s, force = pl.surface, pl.force
    local ghosts, seen, built_at, none_at = {}, {}, {}, {}
    local function add(g) if g.valid and g.type == 'entity-ghost' and not seen[g.unit_number] and #ghosts < READY_MAX then seen[g.unit_number] = true; ghosts[#ghosts+1] = g end end
    if r.positions ~= nil then
      assert(type(r.positions) == 'table' and #r.positions >= 1 and #r.positions <= 512, 'ready.positions takes 1..512 {x,y}')
      for _, q in ipairs(r.positions) do
        local pos = api.position and api.position(q) or q
        local here = s.find_entities_filtered{position=pos, radius=0.6, force=force}
        local got = false
        for _, e in ipairs(here) do if e.type == 'entity-ghost' then add(e); got = true end end
        if not got then
          local b
          for _, e in ipairs(here) do if e.type ~= 'tile-ghost' then b = e end end
          if b then built_at[#built_at+1] = string.format('%s %s', b.name, at(b.position.x, b.position.y)) else none_at[#none_at+1] = at(pos.x, pos.y) end
        end
      end
    end
    if r.area ~= nil then
      for _, ar in ipairs(areas_of(r.area, 'ready.area')) do
        for _, g in ipairs(s.find_entities_filtered{area=ar, type='entity-ghost', force=force, limit=READY_MAX}) do add(g) end
      end
    end
    -- tile ghosts: those in tiles, and those under the entity ghosts' footprints
    local tg, tg_n = {}, 0
    local function tile_ghosts(ar)
      for _, t in ipairs(s.find_entities_filtered{area=ar, type='tile-ghost', force=force, limit=40000}) do
        local key = k(math.floor(t.position.x), math.floor(t.position.y))
        if not tg[key] then tg[key] = t; tg_n = tg_n + 1 end
      end
    end
    local chosen_tiles = 0
    if r.tiles ~= nil then
      for _, ar in ipairs(areas_of(r.tiles, 'ready.tiles')) do
        local before = tg_n
        tile_ghosts(ar)
        chosen_tiles = chosen_tiles + (tg_n - before)
      end
    end
    local need, names = {}, {}
    if chosen_tiles > 0 then
      for _, t in pairs(tg) do
        local item, n = item_of(try(function() return t.ghost_prototype end))
        if item then need[item] = (need[item] or 0) + n end
      end
    end
    local on_floor, waiting, empty, no_recipe = 0, {}, {}, {}
    -- (d17 batch23 B4, Astra: tile_wait said no blocker while the game said a tile would split empty space; by hand,
    -- water's pipe needed one 374-tile pocket, not 41 tiles nor all 1935 ghosts) the empty space under a ghost's
    -- footprint as the hub's rules see it: the 4-neighbour region of empty tiles round it (bounded by foundation),
    -- POCKET_MAX tiles at most (past that: open space). The hub builds no tile that splits empty space, so a pocket
    -- fills only when every tile of it holds a tile ghost.
    local pockets, pocket_of, empty_cache, looks, unread = {}, {}, {}, 0, 0
    local function is_empty(x, y)
      local key = k(x, y)
      local v = empty_cache[key]
      if v == nil then
        local name = try(function() return s.get_tile(x, y).name end)
        v = name == nil or name == 'empty-space' or name == 'out-of-map'
        empty_cache[key] = v
      end
      return v
    end
    local function pocket(x, y, who)
      local key0 = k(x, y)
      if pocket_of[key0] then local pk = pocket_of[key0]; pk.for_ghosts[who] = true; return pk end
      if #pockets >= POCKETS or looks >= LOOKS then unread = unread + 1; return nil end
      local seen, queue, i, open = {[key0]=true}, {{x, y}}, 1, false
      local x0, y0, x1, y1 = x, y, x, y
      while queue[i] do
        local c = queue[i]; i = i + 1
        looks = looks + 1
        if looks > LOOKS then open = 'budget'; break end
        for _, d in ipairs({{1,0},{-1,0},{0,1},{0,-1}}) do
          local nx, ny = c[1] + d[1], c[2] + d[2]
          local nk = k(nx, ny)
          if not seen[nk] and is_empty(nx, ny) then
            seen[nk] = true
            if #queue >= POCKET_MAX then open = true; break end
            queue[#queue+1] = {nx, ny}
            x0, y0, x1, y1 = math.min(x0, nx), math.min(y0, ny), math.max(x1, nx), math.max(y1, ny)
          end
        end
        if open then break end
      end
      local pk = {tiles=#queue, open=open, x0=x0, y0=y0, x1=x1, y1=y1, for_ghosts={[who]=true}, bare={}}
      if not open then
        -- the tiles of it with no tile ghost (the ghosts in its box read once)
        local ghosted = {}
        for _, t in ipairs(try(function() return s.find_entities_filtered{area={{x0, y0}, {x1 + 1, y1 + 1}}, type='tile-ghost', force=force, limit=POCKET_MAX * 2} end) or {}) do
          ghosted[k(math.floor(t.position.x), math.floor(t.position.y))] = true
        end
        for _, c in ipairs(queue) do if not ghosted[k(c[1], c[2])] then pk.bare[#pk.bare+1] = c end end
      end
      for _, c in ipairs(queue) do pocket_of[k(c[1], c[2])] = pk end
      pockets[#pockets+1] = pk
      return pk
    end
    for _, g in ipairs(ghosts) do
      names[g.ghost_name] = (names[g.ghost_name] or 0) + 1
      local item, n = item_of(try(function() return g.ghost_prototype end))
      if item then need[item] = (need[item] or 0) + n end
      local pending, missing = false, false
      for _, ft in ipairs((M.footprint(g))) do
        local x, y = ft.x, ft.y
        do
          local name = try(function() return s.get_tile(x, y).name end)
          if name ~= 'space-platform-foundation' then
            if is_empty(x, y) then pocket(x, y, string.format('%s %s', g.ghost_name, at(g.position.x, g.position.y))) end
            local key = k(x, y)
            if not tg[key] then
              local t = s.find_entities_filtered{position={x + 0.5, y + 0.5}, radius=0.1, type='tile-ghost', force=force}[1]
              if t then tg[key] = t end
            end
            if tg[key] then pending = true else missing = true end
          end
        end
      end
      local where = string.format('%s %s', g.ghost_name, at(g.position.x, g.position.y))
      if missing then empty[#empty+1] = where elseif pending then waiting[#waiting+1] = where else on_floor = on_floor + 1 end
      if g.ghost_type == 'assembling-machine' and not try(function() return g.get_recipe() end) then no_recipe[#no_recipe+1] = where end
    end
    local inv = pl.hub and pl.hub.valid and try(function() return pl.hub.get_inventory(defines.inventory.hub_main) end)
    local rows, miss = {}, {}
    for item, n in pairs(need) do
      local held = inv and try(function() return inv.get_item_count(item) end) or 0
      rows[#rows+1] = {item=item, need=n, hub=held, missing=math.max(0, n - held)}
      if n > held then miss[#miss+1] = string.format('%s %d (hub holds %d)', item, n - held, held) end
    end
    table.sort(rows, function(x, y) if x.missing ~= y.missing then return x.missing > y.missing end return x.item < y.item end)
    table.sort(miss)
    local nm = {}
    for n, c in pairs(names) do nm[#nm+1] = c .. ' ' .. n end
    table.sort(nm)
    local function first(list) return #list > 0 and table.concat(list, ', ', 1, math.min(#list, LIST)) .. (#list > LIST and string.format(' +%d more', #list - LIST) or '') or nil end
    local lines = {string.format('the subset: %d entity ghost%s (%s), %d tile ghost%s in tiles', #ghosts, #ghosts == 1 and '' or 's', #nm > 0 and table.concat(nm, ', ') or 'none',
      chosen_tiles, chosen_tiles == 1 and '' or 's')}
    lines[#lines+1] = #miss > 0 and 'missing from the hub: ' .. table.concat(miss, ', ') or 'the hub holds every item the subset needs'
    lines[#lines+1] = string.format('support: %d on built foundation, %d waiting on tile ghosts%s, %d over empty space with no tile ghost (never built until one is placed)%s',
      on_floor, #waiting, #waiting > 0 and ' (' .. first(waiting) .. ')' or '', #empty, #empty > 0 and ': ' .. first(empty) or '')
    if #no_recipe > 0 then lines[#lines+1] = 'settings: assembler ghosts with no recipe: ' .. first(no_recipe) end
    if #built_at > 0 then lines[#lines+1] = 'positions holding a built entity, no ghost: ' .. first(built_at) end
    if #none_at > 0 then lines[#lines+1] = 'positions with nothing of ours: ' .. first(none_at) end
    if #ghosts >= READY_MAX then lines[#lines+1] = string.format('the first %d ghosts read', READY_MAX) end
    -- (B4) each pocket of empty space under the subset's ghosts
    local prow, entries = {}, {}
    for i, pk in ipairs(pockets) do
      local who = {}
      for w in pairs(pk.for_ghosts) do who[#who+1] = w end
      table.sort(who)
      local area = {left_top={x=pk.x0, y=pk.y0}, right_bottom={x=pk.x1 + 1, y=pk.y1 + 1}}
      local row = {tiles=pk.open and nil or pk.tiles, open=pk.open or nil, area=not pk.open and area or nil, without_ghost=not pk.open and #pk.bare or nil, under=who}
      if pk.open == 'budget' then
        row.line = string.format('pocket %d: the empty space under %s runs past the %d tiles this read looks at (%d read here); read it alone with ready {positions}', i, first(who), LOOKS, pk.tiles)
      elseif pk.open then
        row.line = string.format('pocket %d: the empty space under %s runs past %d tiles (open space beside the hull, or a pocket larger than that): the hub builds open space from the foundation\'s edge, a tile at a time, each with foundation among its 8 neighbours and no split',
          i, first(who), POCKET_MAX)
      else
        for _, c in ipairs(pk.bare) do if #entries < PAGE_ENTRIES then entries[#entries+1] = {name='space-platform-foundation', position={x=c[1] + 0.5, y=c[2] + 0.5}} end end
        row.line = string.format('pocket %d: %d empty tiles enclosed by foundation in (%d,%d)-(%d,%d) under %s; %s', i, pk.tiles, pk.x0, pk.y0, pk.x1 + 1, pk.y1 + 1, first(who),
          #pk.bare == 0 and 'every tile of it holds a tile ghost: the hub fills it whole'
          or string.format('%d of them hold no tile ghost, and the hub builds none of the pocket\'s tiles that would split it: place_ghosts {platform, entities: pocket_entries} stamps them', #pk.bare))
      end
      prow[i] = row
      lines[#lines+1] = row.line
    end
    if unread > 0 then lines[#lines+1] = string.format('%d more footprint tiles over empty space not read for pockets (at most %d pockets and %d tile looks a read)', unread, POCKETS, LOOKS) end
    return {platform=pl.name, pockets=#prow > 0 and prow or nil, pocket_entries=#entries > 0 and entries or nil,
      ready={ghosts=#ghosts, tile_ghosts=chosen_tiles, items=rows, on_foundation=on_floor, waiting_on_tiles=#waiting, over_empty=#empty,
      over_empty_list=#empty > 0 and empty or nil, no_recipe=#no_recipe > 0 and no_recipe or nil, built_at=#built_at > 0 and built_at or nil, nothing_at=#none_at > 0 and none_at or nil},
      lines=lines}
  end
  function M.read(p, a)
    assert(type(a.platform) == 'string', 'platform is required (a platform name)')
    local pl = api.platform(p, a.platform)
    if a.ready ~= nil then return M.ready(p, pl, a.ready) end
    -- (d24 batch165 QH1, Sol #2223) phases: ordered cancel/remove/fill played on a model of the floor (floorphases.lua)
    if a.phases ~= nil then return (api.floorphases and api.floorphases() or require('floorphases')(api)).read(pl, a.phases) end
    if a.phases_check ~= nil then
      local fp = api.floorphases and api.floorphases()
      assert(fp, 'phases_check is not available in this runtime')
      return fp.check(a.phases_check)
    end
    -- floor_check (batch33 A1): the hub's foundation rules over every foundation tile ghost of the platform, across ticks
    -- (floorcheck.lua); true starts one, a number reads it (also one a place_ghosts dry run started)
    if a.floor_check ~= nil then
      local fc = api.floorcheck and api.floorcheck()
      assert(fc, 'floor_check is not available in this runtime')
      if a.floor_check == true then
        local s = pl.surface
        local cells = {}
        for _, g in ipairs(M.foundation_ghosts(s)) do cells[#cells+1] = {math.floor(g.position.x), math.floor(g.position.y)} end
        local thr = try(function() return s.find_entities_filtered{type='thruster', limit=64} end) or {}
        local id = fc.start(s, cells, pl.hub and pl.hub.valid and pl.hub or nil, thr, string.format('%s: its %d foundation tile ghosts', pl.name, #cells))
        local out = fc.read(id)
        out.note = string.format('platform_plan {platform: "%s", floor_check: %d} reads it as it goes; at %d rule checks a tick', pl.name, id, fc.CHECKS)
        return out
      end
      assert(type(a.floor_check) == 'number', 'floor_check is true (start a check) or a check number (read it)')
      return fc.read(a.floor_check)
    end
    if a.floor ~= nil then
      assert(a.floor == true, 'floor must be true')
      local list, why = M.floor(pl.surface, pl.force, pl.hub and pl.hub.valid and pl.hub or nil)
      -- page (A7, Sol 01:50: 2,101 tiles needed and 64 entries given): place_ghosts takes 256 entries a call, so the
      -- entries go in pages of 256, the tiles in reading order (by row, then column), the same order every read.
      table.sort(list, function(u, v) if u.y ~= v.y then return u.y < v.y end return u.x < v.x end)
      local PAGE = 256
      local pages = math.max(1, math.ceil(#list / PAGE))
      local page = a.page ~= nil and (api.integer and api.integer(a.page, 1, 1, pages, 'page (1..' .. pages .. ')') or a.page) or 1
      local first = (page - 1) * PAGE + 1
      -- rows of tiles as areas, and that page as place_ghosts tile entries
      local areas, entries = {}, {}
      for i, t in ipairs(list) do
        local last = areas[#areas]
        if last and last.y == t.y and last.x1 == t.x - 1 then last.x1 = t.x else areas[#areas+1] = {y=t.y, x0=t.x, x1=t.x} end
        if i >= first and i < first + PAGE then entries[#entries+1] = {name='space-platform-foundation', position={x=t.x + 0.5, y=t.y + 0.5}} end
      end
      local rows = {}
      for i, r in ipairs(areas) do if i <= 32 then rows[#rows+1] = string.format('(%d..%d, %d)', r.x0, r.x1, r.y) end end
      -- Tile ghosts count as floor; one the hub's foundation rules hold back never becomes floor (Astra, board #825:
      -- floor at (3.5,16.5) missing under tank ghosts while the plan said none was needed). Named as platforms does.
      local held = try(function() return require('tilecheck')().stalled(pl) end)
      local held_text = held and string.format('; %d tile ghost%s counted as floor the hub does not build (foundation rules): %s',
        #held, #held == 1 and '' or 's', table.concat(held, '; ', 1, math.min(3, #held))) or ''
      return {platform=pl.name, floor_needed=#list, by={footprints=why.foot, tunnels=why.tunnel, holes=why.hole, links=why.link},
        tile_ghosts_held=held,
        rows=rows, rows_more=#areas > 32 and #areas - 32 or nil, place_ghosts_entries=#entries > 0 and entries or nil,
        page=#list > 0 and page or nil, pages=#list > 0 and pages or nil,
        next=page < pages and string.format('platform_plan {platform: "%s", floor: true, page: %d}', pl.name, page + 1) or nil,
        line=#list == 0 and 'every entity ghost stands on foundation, built or planned; no tunnel, hole or link lacks it'
          or string.format('%d foundation tiles needed: %d under ghosts\' footprints, %d under underground belt and pipe tunnels, %d enclosed holes, %d to join a group to the hub\'s floor; place_ghosts {platform, entities: place_ghosts_entries} plans the first %d',
            #list, why.foot, why.tunnel, why.hole, why.link, #entries)
          .. (pages > 1 and string.format(' (page %d of %d: entries %d to %d; page: N reads the others, each a place_ghosts call)', page, pages, first, first + #entries - 1) or '')
          .. held_text}
    end
    if a.support ~= nil then
      local sp = a.support
      assert(sp == true or type(sp) == 'table' and (sp.positions ~= nil or sp.area ~= nil or sp.names ~= nil),
        'support is true (every entity of ours, built and ghost) or {positions, area, names}: the entities chosen (any of them)')
      local s, force = pl.surface, pl.force
      local chosen, seen = {}, {}
      -- (QE1) the entities that stand on the floor (M.stands): never a rocket, beam, cargo pod or robot passing over it
      local function take(e)
        if e.valid and M.stands(e) and not seen[e] then seen[e] = true; chosen[#chosen+1] = e end
      end
      local names
      if type(sp) == 'table' and sp.names ~= nil then
        assert(type(sp.names) == 'table' and #sp.names >= 1 and #sp.names <= 32, 'support.names: 1..32 entity names')
        names = {}
        for _, n in ipairs(sp.names) do names[n] = true end
      end
      local function named(e) return not names or names[e.type == 'entity-ghost' and e.ghost_name or e.name] end
      if sp == true or sp.positions == nil and sp.area == nil then
        for _, e in ipairs(s.find_entities_filtered{force=force}) do if named(e) then take(e) end end
      end
      if type(sp) == 'table' and sp.positions ~= nil then
        assert(type(sp.positions) == 'table' and #sp.positions >= 1 and #sp.positions <= 512, 'support.positions takes 1..512 {x,y}')
        for _, q in ipairs(sp.positions) do
          local pos = api.position and api.position(q) or q
          local got = false
          for _, e in ipairs(s.find_entities_filtered{position=pos, radius=0.6, force=force}) do
            if M.stands(e) and named(e) then take(e); got = true end
          end
          assert(got, 'support.positions: nothing of ours at ' .. at(pos.x, pos.y))
        end
      end
      if type(sp) == 'table' and sp.area ~= nil then
        for _, ar in ipairs(areas_of(sp.area, 'support.area')) do
          for _, e in ipairs(s.find_entities_filtered{area=ar, force=force}) do if named(e) then take(e) end end
        end
      end
      assert(#chosen > 0, 'support: no entity of ours chosen')
      local r = M.support(s, force, pl.hub and pl.hub.valid and pl.hub or nil, chosen)
      local areas = M.rects(r.remove)
      local PAGE = 64
      local pages = math.max(1, math.ceil(#areas / PAGE))
      local page = a.page ~= nil and (api.integer and api.integer(a.page, 1, 1, pages, 'page (1..' .. pages .. ')') or a.page) or 1
      local first = (page - 1) * PAGE + 1
      local list = {}
      for i = first, math.min(#areas, first + PAGE - 1) do list[#list+1] = areas[i] end
      local entries, add_for = {}, {}
      for i, t in ipairs(r.add) do
        if i <= 256 then
          entries[#entries+1] = {name='space-platform-foundation', position={x=t.x + 0.5, y=t.y + 0.5}}
          add_for[#add_for+1] = {position={x=t.x + 0.5, y=t.y + 0.5}, kind=t.kind, entity=named_entity(t.of)}
        end
      end
      -- (QE1) by entity: the empty tiles planned for each (footprint, tunnel, link), the most first
      local by, for_entities = {}, {}
      for _, t in ipairs(r.add) do
        local e = named_entity(t.of)
        local key = e and (e.name .. '|' .. tostring(e.unit_number) .. '|' .. e.position.x .. ',' .. e.position.y) or t.kind
        local row = by[key]
        if not row then
          row = {name=e and e.name, unit_number=e and e.unit_number, position=e and e.position, tiles=0, foot=0, tunnel=0, link=0, hole=0}
          by[key] = row; for_entities[#for_entities+1] = row
        end
        row.tiles = row.tiles + 1
        row[t.kind] = (row[t.kind] or 0) + 1
      end
      table.sort(for_entities, function(u, v) if u.tiles ~= v.tiles then return u.tiles > v.tiles end return tostring(u.name) < tostring(v.name) end)
      local for_text = {}
      for i, row in ipairs(for_entities) do
        if i > 4 then for_text[#for_text+1] = string.format('+%d more', #for_entities - 4); break end
        local parts = {}
        for _, kind in ipairs({'foot', 'tunnel', 'link', 'hole'}) do
          if (row[kind] or 0) > 0 then parts[#parts+1] = string.format('%s %d', kind == 'foot' and 'footprint' or kind, row[kind]) end
        end
        for_text[#for_text+1] = string.format('%s: %d (%s)', row.name and string.format('%s #%s %s', row.name, tostring(row.unit_number), at(row.position.x, row.position.y)) or 'holes',
          row.tiles, table.concat(parts, ', '))
      end
      while #for_entities > 16 do table.remove(for_entities) end
      local strands = {}
      for i, x in ipairs(r.strands) do if i <= LIST then strands[i] = x end end
      return {platform=pl.name, chosen=#chosen,
        support={tile_ghosts=r.tile_ghosts, keep=r.kept_ghosts, remove=#r.remove, add=#r.add, footprints=r.why.foot, tunnels=r.why.tunnel, links=r.why.link,
          holes=r.why.hole, net_saved=#r.remove - #r.add, stalls=#r.stalls, unchecked=r.unchecked, holes_unchecked=r.holes_unchecked,
          strands=#r.strands, unjoined=r.unjoined > 0 and r.unjoined or nil},
        stalls=#r.stalls > 0 and {table.unpack(r.stalls, 1, math.min(LIST, #r.stalls))} or nil,
        remove_areas=#list > 0 and list or nil, page=#areas > 0 and page or nil, pages=#areas > 0 and pages or nil,
        next=page < pages and string.format('platform_plan {platform: "%s", support: (as before), page: %d}', pl.name, page + 1) or nil,
        place_ghosts_entries=#entries > 0 and entries or nil, add_for=#add_for > 0 and add_for or nil,
        for_entities=#for_entities > 0 and for_entities or nil, strands=#strands > 0 and strands or nil,
        line=string.format('%d entities chosen; of %d foundation tile ghosts %d stay (their footprints, underground belt and pipe spans, links to the hub\'s floor, and %d tiles of holes that floor would enclose: the hub never builds the last ghost round a hole) and %d would go, in %d areas (each a deconstruct {platform, area, tiles: ["space-platform-foundation"]}%s); %d empty tiles they need hold no tile ghost (place_ghosts_entries); net %d tiles of floor saved; a hole built floor alone encloses stays open; played through the hub\'s build rules, %s',
          #chosen, r.tile_ghosts, r.kept_ghosts, r.why.hole, #r.remove, #areas, pages > 1 and string.format('; page %d of %d, %d areas a page', page, pages, PAGE) or '', #r.add,
          #r.remove - #r.add, #r.stalls == 0 and 'every kept and added ghost builds' or string.format('%d never build (stalls)', #r.stalls))
          .. (r.unchecked and string.format(' (%d not played: the play looks at most 40000 tiles)', r.unchecked) or '')
          .. (r.holes_unchecked and '; holes not looked at (the box is over 250000 tiles)' or '')
          .. (#r.strands > 0 and string.format('; %d entity ghosts not chosen stand on tiles that would go: %s', #r.strands, table.concat(strands, ', ')) or '')
          .. (r.unjoined > 0 and '; a needed group no run of tiles joins to the hub within the platform\'s box' or '')
          .. (#for_text > 0 and '; the empty tiles are for (add_for, for_entities): ' .. table.concat(for_text, '; ') or '')}
    end
    if a.salvage ~= nil then
      local n = api.integer and api.integer(a.salvage, nil, 1, 2000, 'salvage') or a.salvage
      local taken, areas, capped, info = M.salvage(pl.surface, pl.force, pl.hub and pl.hub.valid and pl.hub or nil, n)
      local list = {}
      for i, t in ipairs(taken) do if i <= 64 then list[#list+1] = at(t.x + 0.5, t.y + 0.5) end end
      return {platform=pl.name, salvage=#taken, asked=n, areas=areas,
        line=string.format('%d of %d foundation tiles can come up from the edge in (nothing of ours on them, no tile ghost, no underground belt or pipe span under them or at their ends, the rest of the foundation stays joined round each)%s: %d areas (rectangles of tiles), one deconstruct {platform, area, tiles: true} each',
          #taken, n, capped and string.format(' (the first %d tiles read)', MAX_TILES) or '', #areas)
          .. (info.restored > 0 and string.format('; %d more left in place: taking them would leave a hole the tile ghosts close, which the hub never finishes', info.restored) or '')
          .. (info.unfilled > 0 and string.format('; %d empty tiles with no tile ghost sit in holes the tile ghosts close (platform_plan floor plans them)', info.unfilled) or '')
          .. (info.go and string.format('; played through the hub\'s removal rule (one tile at a time, each beside one run of empty space): %d go, net %d tiles of floor saved%s',
            info.go, info.go, info.waiting_n > 0 and string.format(', %d wait (waiting)', info.waiting_n) or '') or '')
          .. (info.holes_unchecked and '; holes not looked at (the box is over 250000 tiles)' or ''),
        restored=info.restored > 0 and info.restored or nil, holes_unfilled=info.unfilled > 0 and info.unfilled or nil,
        go=info.go, net_saved=info.go, waiting=info.waiting and #info.waiting > 0 and info.waiting or nil,
        tiles=list, tiles_more=#taken > 64 and #taken - 64 or nil}
    end
    local s, hub = pl.surface, pl.hub
    local groups, ntiles, capped = foundation(s, hub and hub.valid and hub or nil)
    local islands = {}
    for i, g in ipairs(groups) do
      if not g.hub then
        local on = try(function() return s.count_entities_filtered{type='entity-ghost', area={left_top={x=g.first.x - 64, y=g.first.y - 64}, right_bottom={x=g.first.x + 64, y=g.first.y + 64}}} end)
        islands[#islands+1] = {size=g.size, ghost_tiles=g.ghosts, tile=at(g.first.x, g.first.y),
          line=string.format('%d tiles from %s (%d of them ghosts) join no foundation with the hub', g.size, at(g.first.x, g.first.y), g.ghosts)}
      end
    end
    local node, nbelts = belts(s, pl.force)
    local head, side, loops = audit_belts(node)
    local main = groups[1] and groups[1].hub and groups[1] or nil
    local lines = {string.format('foundation: %d tiles%s; the hub\'s group %d tiles (%d ghosts); %d island%s', ntiles, capped and ' (the first ' .. MAX_TILES .. ' read)' or '',
      main and main.size or 0, main and main.ghosts or 0, #islands, #islands == 1 and '' or 's')}
    for i, x in ipairs(islands) do if i <= LIST then lines[#lines+1] = 'island: ' .. x.line end end
    lines[#lines+1] = string.format('belts: %d (built and ghosts); %d loop%s, %d head on, %d side-load%s', nbelts, #loops, #loops == 1 and '' or 's', #head, #side, #side == 1 and '' or 's')
    for i, l in ipairs(loops) do if i <= LIST then lines[#lines+1] = 'loop: ' .. l.line end end
    for i, h in ipairs(head) do if i <= LIST then lines[#lines+1] = 'head on: ' .. h end end
    for i, x in ipairs(side) do if i <= LIST then lines[#lines+1] = 'side-load: ' .. x end end
    return {platform=pl.name, foundation_tiles=ntiles, hub_group=main and main.size or nil, islands=islands, belts=nbelts, loops=loops,
      head_on=#head > 0 and head or nil, side_loads=#side > 0 and side or nil, lines=lines}
  end
  M.schema = {platform_plan = {platform='platform name',phases_check='a phases plan\'s number (a plan that took more than the call\'s rule checks): running (phase, ticks, rule_checks) or its read, as phases gives it',phases='1..16 phases, each {cancel, remove, fill: tiles ({x,y} each), an area {left_top, right_bottom}, "x0..x1,y0..y1" (tiles x0 to x1, y0 to y1) or "x,y", or a list of them; name}: applied in order to a model of the floor (its tiles, deconstruction marks and foundation tile ghosts now, read within 8 tiles of the phases\' tiles; cancel drops marks and ghosts, remove marks floor (drops a ghost), fill puts a ghost on empty space (keeps a marked tile)), each played to stability by the hub\'s rules (marks, then ghosts, in the order given, then again beside each change). Read only: phases [{phase, name, went, built, marks_waiting, ghosts_unbuilt, waiting, unbuilt ("(x,y): why", 8 each), cut ("N foundation tiles in x0..x1,y0..y1 cut off from the hub\'s floor (joined by sides); on it: ..."), cut_tiles, settled, unsettled, line}], end {removed, added, marks_waiting, ghosts_unbuilt, removed_areas, added_areas ("x0..x1,y0..y1")}, settled, rollback {fill, remove ("x0..x1,y0..y1": phases takes them back), fill_count, remove_count, played [{step (fill back, take up), went, built, marks_waiting, ghosts_unbuilt, waiting, unbuilt, settled, line}], order_checked (played to the end within the rule checks), restores (it returns to the start), line}, rule_checks, tiles, ticks (0: done in the call), line, note. A plan that takes more than about 150 rule checks and tile reads goes on across ticks (120 a tick): the reply gives phases_check (its number) and platform_plan {platform, phases_check} reads it. Bounded: 8192 tiles and 40000 rule checks a plan (the rollback\'s included)',floor_check='true: the hub\'s foundation rules played over every foundation tile ghost of the platform, across ticks (about 150 rule checks a tick; a few thousand tiles take seconds): the reply gives its number; a number reads that check (one a place_ghosts dry run started too): running (rule checks so far, tiles still queued) or done: tiles (planned), would_build (the plan played through the hub\'s rules: built in turn once their items come), never_built, by_reason, unbuilt (the first 12, with why), floor_now (foundation tiles built on the platform now), line',ready='optional {positions (1..512 {x,y}), area (an area or a list), tiles (an area or a list of areas)}: that subset only (D2): the entity ghosts at the positions and in the area, the tile ghosts in tiles; what they need of each item against the hub (lines: missing from the hub), the support under each entity ghost (on built foundation, waiting on tile ghosts, over empty space with no tile ghost: never built), settings (assembler ghosts with no recipe), and positions holding a built entity or nothing; pockets [{tiles, area, without_ghost, under, open, line}] (the empty space under each ghost\'s footprint: the 4-neighbour region bounded by foundation, up to 1024 tiles; it fills only when every tile holds a tile ghost) and pocket_entries (place_ghosts entries for its tiles without one): ready {ghosts, tile_ghosts, items [{item, need, hub, missing}], on_foundation, waiting_on_tiles, over_empty, over_empty_list, no_recipe, built_at, nothing_at}, lines',floor='true: the foundation every entity ghost needs, as a placement plan: floor_needed and by (footprints, tunnels under underground belt and pipe-to-ground pairs, holes enclosed by floor, links joining a needed group to the hub\'s floor; a tunnel runs to the next underground of its name facing the same way, one crossing it passed over), rows, tile_ghosts_held (tile ghosts counted as floor that the hub\'s foundation rules never build, each with why), place_ghosts_entries (one page of 256 tiles as place_ghosts entries, in reading order: page, pages, next), line; tiles built or with a tile ghost count as there',page='with floor: 1..pages (default 1): which 256 entries place_ghosts_entries holds; with support: which 64 remove_areas; the order is the same every read',support='true (every entity of ours, built and ghost) or {positions (1..512 {x,y}), area (an area or a list), names (1..32 entity names)}: the foundation those chosen need and nothing more, and the foundation tile ghosts that would go (C3): kept are their footprints (less the empty space a collector or thruster keeps), the tiles under underground belt and pipe-to-ground spans (built pairs and the chosen ghosts\', paired as floor pairs them) and the fewest tiles joining a needed group to the hub\'s floor, and every tile of a hole that floor would enclose (the hub never builds the last ghost round a hole; a hole built floor alone encloses stays open); the plan is played through the hub\'s build rules: stalls lists kept ghosts it never builds. support {tile_ghosts, keep, remove, add, footprints, tunnels, links, holes, net_saved (tile ghosts that go less empty tiles added), stalls, strands, unjoined}, remove_areas (rectangles of tile ghosts that would go, 64 a page: each a deconstruct {platform, area, tiles: ["space-platform-foundation"]}; page, pages, next), place_ghosts_entries (up to 256 empty tiles they need that hold no tile ghost), add_for (beside them: each one\'s {position, kind (foot, tunnel, link, hole), entity {name, unit_number, position}}), for_entities (by entity: tiles, foot, tunnel, link; the most first, 16), strands (entity ghosts not chosen standing on a tile that would go); the chosen are what stands on the floor, never a projectile, beam, cargo pod or robot passing (d24 batch162), line',salvage='optional 1..2000: a read of up to that many built foundation tiles to take up, from the edge in, farthest from the hub first, each with nothing of ours on it (built or ghost), no tile ghost, no underground belt or pipe span under it or at its ends, the foundation left joined round it, and not in a hole the tile ghosts would close (restored: how many left for that; holes_unfilled: empty tiles with no ghost in such holes), played through the hub\'s removal rule (go, net_saved, waiting: why each other waits): salvage (how many), areas (rectangles of neighbouring tiles, each a deconstruct {platform, area, tiles: true}), tiles (the first 64), line',
    returns='a platform as planned, built and ghosts together (read only): foundation_tiles (built and tile ghosts), hub_group (the 4-joined tiles with the hub), islands [{size, ghost_tiles, tile, line}] (groups no foundation joins with the hub), belts (transport belts, undergrounds and splitters, built and ghosts), loops [{belts, ghosts, exits, first, line}] (belts whose items come round again; exits 0: no belt leaves it), head_on (a belt moving its items into one facing it), side_loads (a belt feeding the side of another), lines'}}
  return M
end
