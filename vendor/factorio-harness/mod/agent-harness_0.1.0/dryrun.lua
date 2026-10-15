-- A dry run of a layout: dry_run=true on place_ghosts, paste, blueprint_place
-- and build places nothing and reads like a check of the plan. Per entity,
-- whether the game takes it there and why not (what collides and where, tiles
-- it cannot stand on: water, lava, out of map, a platform's empty space);
-- the tiles it needs first (landfill, foundation), and on a platform the empty
-- tiles new foundation would enclose, which the game never leaves as holes;
-- power poles by wire reach and the groups the result leaves unconnected; and
-- standing spots from which the character reaches every placement.
-- Asked for by Astra (every ship refit: a gun route that looked valid needed
-- 20 more foundation tiles, found by a flood fill after its ghosts were
-- staged), Sol (a build batch failed on its last, far entry after the first
-- ones were built) and Gemini.
-- The factory is pure so the same module can be bundled into a hot reload.
return function(api)
  local M = {}
  M.ACTIONS = {place_ghosts=true, paste=true, blueprint_place=true, build=true, rail_route=true, belt_route=true}
  local MAX_ROWS, MAX_LISTED, HOLE_LIMIT, FLOOD_BUDGET, MAX_SPOTS = 30, 200, 1024, 20000, 8
  local MAX_INSERTERS = 64
  local DIRS = {{1,0},{-1,0},{0,1},{0,-1}}
  local NAMES = {[0]='north', 'northnortheast', 'northeast', 'eastnortheast', 'east', 'eastsoutheast', 'southeast', 'southsoutheast',
    'south', 'southsouthwest', 'southwest', 'westsouthwest', 'west', 'westnorthwest', 'northwest', 'northnorthwest'}
  local RAILS = {['straight-rail']=true, ['half-diagonal-rail']=true, ['curved-rail-a']=true, ['curved-rail-b']=true,
    ['legacy-straight-rail']=true, ['legacy-curved-rail']=true, ['elevated-straight-rail']=true,
    ['elevated-half-diagonal-rail']=true, ['elevated-curved-rail-a']=true, ['elevated-curved-rail-b']=true, ['rail-ramp']=true}
  -- Entities that never stop a placement: ore, remnants (a build clears
  -- them), items on the ground (a build picks them up).
  local IGNORED = {resource=true, corpse=true, ['item-entity']=true, ['entity-ghost']=true, ['tile-ghost']=true,
    ['deconstructible-tile-proxy']=true, ['highlight-box']=true, ['flying-text']=true,
    ['smoke-with-trigger']=true, ['sticker']=true, ['fire']=true, ['particle-source']=true, projectile=true}
  local OBSTACLE = {tree=true, plant=true, ['simple-entity']=true}
  local function key(x, y) return x*4194304+y end
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function layers(mask) return mask and mask.layers or {} end
  local function collide(a, b)
    for k in pairs(a) do if b[k] then return true end end
    return false
  end
  local function at(pos) return string.format('(%g,%g)', pos.x, pos.y) end
  local function tile_text(x, y) return string.format('(%g,%g)', x+0.5, y+0.5) end
  -- Inclusive tile range of a box.
  local function span(b)
    return math.floor(b.left_top.x+0.01), math.floor(b.left_top.y+0.01), math.ceil(b.right_bottom.x-0.01)-1, math.ceil(b.right_bottom.y-0.01)-1
  end
  local function overlap(a, b)
    return a.left_top.x < b.right_bottom.x-0.01 and b.left_top.x < a.right_bottom.x-0.01
      and a.left_top.y < b.right_bottom.y-0.01 and b.left_top.y < a.right_bottom.y-0.01
  end
  -- Where the engine puts an entity asked for at pos: odd sizes on tile
  -- centres, even ones on tile corners (rails keep their own grid).
  function M.snap(proto, pos, dir)
    if RAILS[proto.type] then return {x=pos.x, y=pos.y} end
    local w, h = proto.tile_width or 1, proto.tile_height or 1
    if (dir or 0) % 8 == 4 then w, h = h, w end
    local function s(v, odd) return odd and math.floor(v)+0.5 or math.floor(v+0.5) end
    return {x=s(pos.x, w % 2 == 1), y=s(pos.y, h % 2 == 1)}
  end
  -- A ground rail's footprint is a turned box (16 directions): the box
  -- around it, and the turned box itself (rails.lua) for the finer checks.
  function M.footprint(proto, pos, dir)
    local shape = RAILS[proto.type] and api.rail_box and api.rail_box(proto.name, pos, dir or 0)
    if shape then return {left_top=shape.left_top, right_bottom=shape.right_bottom}, shape end
    local b = proto.collision_box or {left_top={x=-0.4, y=-0.4}, right_bottom={x=0.4, y=0.4}}
    return api.placewhy.box_at(b, pos, dir or 0)
  end
  -- Whether two planned footprints meet. Rails cross and join other rails
  -- (the game's own check decides those); a rail and anything else meet
  -- where the turned box does.
  local function meets(a, b)
    if a.shape and b.shape then
      return a.name == b.name and math.abs(a.pos.x-b.pos.x) < 0.01 and math.abs(a.pos.y-b.pos.y) < 0.01 and a.dir % 8 == b.dir % 8
    end
    if a.shape then return api.rail_overlaps(a.shape, b.box.left_top.x, b.box.left_top.y, b.box.right_bottom.x, b.box.right_bottom.y) end
    if b.shape then return api.rail_overlaps(b.shape, a.box.left_top.x, a.box.left_top.y, a.box.right_bottom.x, a.box.right_bottom.y) end
    return overlap(a.box, b.box)
  end
  -- Compact runs of indexes: 1-4,7,9-10.
  local function runs(list)
    table.sort(list)
    local parts, i = {}, 1
    while list[i] do
      local j = i
      while list[j+1] == list[j]+1 do j = j + 1 end
      parts[#parts+1] = j > i and (list[i]..'-'..list[j]) or tostring(list[i])
      i = j + 1
    end
    return table.concat(parts, ',')
  end
  M.runs = runs
  -- The tiles a hand-placed tile item covers: the size x size brush around
  -- the position, as a build lays it (bots.lua place_tiles).
  function M.brush(pos, size)
    local x0, y0 = math.floor(pos.x-(size-1)/2), math.floor(pos.y-(size-1)/2)
    local list = {}
    for dx = 0, size-1 do for dy = 0, size-1 do list[#list+1] = {x=x0+dx+0.5, y=y0+dy+0.5} end end
    return list
  end

  -- Heat connections of an entity of proto at pos facing dir: {x, y (its tile), dir (the way it faces), tx, ty (the
  -- tile it joins)}, from the prototype's heat buffer (else its heat energy source), turned with the entity. 2.0.77 on
  -- a copy of world n: heat exchangers in the four directions and a heating tower warmed from a heat interface on the
  -- tile this predicts (818 and 604 C); one beside a side without a connection stayed at 15 C.
  local STEP = {[0]={0,-1}, [4]={1,0}, [8]={0,1}, [12]={-1,0}}
  function M.heat_points(proto, pos, dir)
    local list = try(function() return proto.heat_buffer_prototype.connections end)
      or try(function() return proto.heat_energy_source_prototype.connections end)
    local out = {}
    dir = dir or 0
    for _, c in ipairs(list or {}) do
      local rx, ry = c.position.x or c.position[1], c.position.y or c.position[2]
      if dir == 4 then rx, ry = -ry, rx elseif dir == 8 then rx, ry = -rx, -ry elseif dir == 12 then rx, ry = ry, -rx end
      local cd = ((c.direction or 0) + dir) % 16
      local x, y = math.floor(pos.x + rx), math.floor(pos.y + ry)
      if STEP[cd] then out[#out+1] = {x=x, y=y, dir=cd, tx=x+STEP[cd][1], ty=y+STEP[cd][2]} end
    end
    return out
  end
  -- What joins heat connection c of an entity (inspect): the entity of ours on the tile it faces with a heat
  -- connection back, or what stands there without one, or nothing.
  function M.heat_there(surface, force, c)
    local function back(o)
      local proto = o.type == 'entity-ghost' and o.ghost_prototype or o.prototype
      for _, h in ipairs(M.heat_points(proto, o.position, o.direction)) do
        if h.x == c.tx and h.y == c.ty and h.tx == c.x and h.ty == c.y then return true end
      end
    end
    local other
    for _, o in pairs(try(function() return surface.find_entities_filtered{area={{c.tx+0.1, c.ty+0.1}, {c.tx+0.9, c.ty+0.9}}, force=force} end) or {}) do
      if o.valid and o.type ~= 'character' then
        local label = (o.type == 'entity-ghost' and o.ghost_name..' ghost' or o.name)..' '..at(o.position)
        if back(o) then return label end
        other = other or label
      end
    end
    return other and 'faces '..other..' (no heat connection back)' or 'nothing there'
  end

  -- Tile items and the tiles each can be placed on (the game's own rule:
  -- a tile_condition list when given, then the collision condition, which
  -- invert turns into a requirement).
  local tile_items
  local function items_for_tiles()
    if tile_items then return tile_items end
    tile_items = {}
    for name, item in pairs(prototypes.item) do
      local r = try(function() return item.place_as_tile_result end)
      if r and r.result then
        local only
        for _, t in ipairs(r.tile_condition or {}) do
          only = only or {}
          only[type(t) == 'string' and t or t.name] = true
        end
        tile_items[#tile_items+1] = {item=name, result=r.result.name, layers=layers(r.result.collision_mask),
          condition=layers(r.condition), invert=r.invert == true, only=only}
      end
    end
    -- landfill, ice platform and platform foundation before the general-purpose foundation
    local rank = {['space-platform-foundation']=1, landfill=2, ['ice-platform']=3, foundation=4}
    table.sort(tile_items, function(a, b)
      local ra, rb = rank[a.item] or 9, rank[b.item] or 9
      if ra ~= rb then return ra < rb end
      return a.item < b.item
    end)
    return tile_items
  end
  local function placeable_on(ti, tile_name, tile_layers)
    if ti.only and not ti.only[tile_name] then return false end
    return collide(tile_layers, ti.condition) == ti.invert
  end
  M.placeable_on = function(item, tile_name)
    for _, ti in ipairs(items_for_tiles()) do
      if ti.item == item then
        local t = prototypes.tile[tile_name]
        return placeable_on(ti, tile_name, layers(t and t.collision_mask))
      end
    end
    return false
  end
  -- The tile item that makes this tile buildable for the entity (mask), the
  -- force's unlocked ones first; nil when none can (out of map). Kept for one
  -- check: research changes what is unlocked.
  local remedy_cache = {}
  local function remedy(force, tile_name, tile_layers, mask)
    local k = tile_name..'|'..table.concat((function() local t = {} for l in pairs(mask) do t[#t+1] = l end table.sort(t) return t end)(), '+')
    if remedy_cache[k] ~= nil then return remedy_cache[k] or nil end
    local best, locked
    for _, ti in ipairs(items_for_tiles()) do
      if placeable_on(ti, tile_name, tile_layers) and not collide(ti.layers, mask) then
        local r = force and try(function() return force.recipes[ti.item] end)
        if not r or r.enabled then best = ti.item; break end
        locked = locked or ti.item
      end
    end
    local v = best or (locked and locked..' (not researched)')
    remedy_cache[k] = v or false
    return v
  end

  -- For route planners (belt_route), per tile name in the caller's cache (one
  -- plan): whether the entity collides with that tile kind, and the unlocked
  -- tile item that makes it buildable (item; nil when none can).
  function M.tile_info(force, proto, tile_name, cache)
    local v = cache[tile_name]
    if v then return v end
    local mask = cache.mask__
    if not mask then mask = layers(try(function() return proto.collision_mask end)); cache.mask__ = mask end
    local tp = prototypes.tile[tile_name]
    local tl = tp and layers(tp.collision_mask) or {out_of_map=true}
    v = {collides=collide(mask, tl)}
    if v.collides and tp then
      local fix = remedy(force, tile_name, tl, mask)
      if fix and not fix:find(' ', 1, true) then v.item = fix end
    end
    cache[tile_name] = v
    return v
  end

  -- The tiles under an entity at pos that it cannot stand on now (its
  -- collision mask against each tile; a tile ghost already ordered there that
  -- it can stand on counts as laid), each {x, y, tile, item}: item is the
  -- tile item that makes it buildable, nil when none the force has unlocked
  -- can. nil when there are none, or when the entity has tile rules of its own
  -- (placewhy.tile_rules judges those). Sol, shift09 01:38: in 2.0.77 the
  -- forced ghost check takes a pole ghost over Gleba wetland once the force
  -- has the landfill recipe, as a player's forced placement lays landfill
  -- ghosts under it; a script ghost got none, and nothing could build it.
  function M.tile_fixes(surface, force, proto, pos, dir)
    local rules = try(function() return proto.tile_buildability_rules end)
    if type(rules) == 'table' and #rules > 0 then return nil end
    local mask = layers(try(function() return proto.collision_mask end))
    if not next(mask) then return nil end
    remedy_cache = {}
    local x0, y0, x1, y1 = span(M.footprint(proto, pos, dir))
    local out
    for x = x0, x1 do
      for y = y0, y1 do
        local t = try(function() return surface.get_tile(x, y) end)
        local name = t and try(function() return t.name end)
        local tl = name and try(function() return t.prototype.collision_mask.layers end) or {out_of_map=true}
        if collide(mask, tl) then
          local laid = false
          for _, g in pairs(surface.find_entities_filtered{position={x+0.5, y+0.5}, radius=0.1, type='tile-ghost'}) do
            local gl = try(function() return prototypes.tile[g.ghost_name].collision_mask.layers end)
            if gl and not collide(mask, gl) then laid = true end
          end
          if not laid then
            local fix = name and not tl.out_of_map and remedy(force, name, tl, mask) or nil
            out = out or {}
            out[#out+1] = {x=x+0.5, y=y+0.5, tile=name or 'out-of-map', item=fix and not fix:find(' ', 1, true) and fix or nil, locked=fix and fix:find(' ', 1, true) and fix or nil}
          end
        end
      end
    end
    return out
  end

  -- What stands in the way of a tile on tile (x, y) (Sol, shift10: a
  -- slipstack on Gleba wetland kept the landfill ghost from three belt tiles;
  -- mined, landfill and belts went in). 2.0.77 on a private copy of world n
  -- (Sol, shift12 12:55): a tile item's tile checks for entities whose mask
  -- meets its own and whose prototype is protected_from_tile_building.
  -- Gleba's slipstack, cuttlepop, hairyclubnub, iron and copper stromatolites
  -- and egg rafts have ground_tile, as landfill has, and are protected; so are
  -- trees, rocks, cliffs and buildings. Water-cane and fish have ground_tile
  -- but are not protected: the tile ghost check takes landfill over them, and
  -- robots laid it over an unmarked water-cane, which was gone. Marked for
  -- deconstruction, protected ones are passed over by the ghost check. The
  -- engine's tile ghost check decides (an edge that only touches counted on
  -- three sides of four); the protected entities on the tile are named:
  -- {entity, obstacle (a minable tree or rock), text}. nil when the engine
  -- takes the tile there (or no such tile); an empty list when it refuses
  -- with nothing in the way (its tile rules).
  local function at1(pos) return string.format('(%g,%g)', math.floor(pos.x*10+0.5)/10, math.floor(pos.y*10+0.5)/10) end
  local function protected(e) return try(function() return e.prototype.protected_from_tile_building end) ~= false end
  local function blocker(e, force)
    local neutral = e.force == nil or e.force.name == 'neutral'
    local obstacle = OBSTACLE[e.type] and e.minable and neutral or false
    local kind = e.type == 'tree' and ' tree' or e.type == 'simple-entity' and ' rock' or e.type == 'plant' and ' plant' or ''
    local marked = try(function() return e.to_be_deconstructed() end) and ', marked for deconstruction' or ''
    local text
    if obstacle then text = string.format('%s%s at %s%s: mine it first', e.name, kind, at1(e.position), marked)
    elseif e.type == 'cliff' then text = string.format('%s at %s: cliff explosives clear it', e.name, at1(e.position))
    else
      local whose = not neutral and e.force ~= force and ' of force '..e.force.name or ''
      text = string.format('%s%s at %s%s', e.name, whose, at1(e.position), marked)
    end
    return {entity=e, obstacle=obstacle, text=text}
  end
  function M.tile_blockers(surface, force, tile, x, y)
    local tp = prototypes.tile[tile or '']
    if not tp then return nil end
    local ok = try(function()
      return surface.can_place_entity{name='tile-ghost', inner_name=tile, position={x=x+0.5, y=y+0.5}, force=force,
        build_check_type=defines.build_check_type.manual_ghost}
    end)
    if ok ~= false then return nil end
    local tl = layers(tp.collision_mask)
    local out = {}
    for _, e in ipairs(try(function() return surface.find_entities_filtered{area={{x, y}, {x+1, y+1}}, limit=16} end) or {}) do
      if e.valid and not IGNORED[e.type] and e.type ~= 'character' and protected(e)
        and collide(layers(try(function() return e.prototype.collision_mask end)), tl)
        and not try(function() return e.to_be_deconstructed() end) then
        out[#out+1] = blocker(e, force)
      end
    end
    return out
  end
  -- Other tile items that go on a tile no building stands on (water, lava,
  -- empty space), for a refusal: ' (foundation can)'.
  local function others_text(force, name, hl, item)
    if not (hl.water_tile or hl.empty_space) then return '' end
    local can, locked = {}, {}
    for _, t in ipairs(items_for_tiles()) do
      if t.item ~= item and placeable_on(t, name, hl) then
        local r = force and try(function() return force.recipes[t.item] end)
        if not r or r.enabled then can[#can+1] = t.item else locked[#locked+1] = t.item end
      end
    end
    if #can > 0 then return ' ('..table.concat(can, ', ', 1, math.min(2, #can))..' can)' end
    if #locked > 0 then return ' ('..locked[1]..' can; not researched)' end
    return ' (no tile item can)'
  end
  -- A tile laid by hand on tile (x, y), item by item (bots.lua place_tiles,
  -- and a hand build's dry run). First the item's tile rules (tile_condition,
  -- condition, invert: landfill goes on water and wetland, never on lava or
  -- an oil ocean). Then what stands there, as for a ghost (tile_blockers),
  -- except that a protected entity blocks marked or not (2.0.77: set_tiles
  -- refused landfill under a marked hairyclubnub) and that the unprotected
  -- ones (water-cane, fish) go with the new tile, as under robots' tiles. A
  -- tile ghost on the tile fails the engine's check (one ghost a tile), so
  -- there the boxes decide alone. Returns {already=true}, {why, blockers} or
  -- {removes = the entities the tile takes away}.
  function M.hand_tile(surface, force, item, x, y)
    local ti
    for _, t in ipairs(items_for_tiles()) do if t.item == item then ti = t; break end end
    if not ti then return {why=tostring(item)..' places no tile'} end
    local here = try(function() return surface.get_tile(x, y) end)
    local name = here and try(function() return here.name end)
    if not name then return {why='outside the map'} end
    if name == ti.result then return {already=true} end
    local hl = try(function() return here.prototype.collision_mask.layers end) or {}
    if not placeable_on(ti, name, hl) then return {why=item..' cannot go on '..name..others_text(force, name, hl, item)} end
    local ghost = (try(function()
      return surface.count_entities_filtered{area={{x+0.1, y+0.1}, {x+0.9, y+0.9}}, type='tile-ghost', limit=1}
    end) or 0) > 0
    local engine
    if not ghost then
      engine = try(function()
        return surface.can_place_entity{name='tile-ghost', inner_name=ti.result, position={x=x+0.5, y=y+0.5}, force=force,
          build_check_type=defines.build_check_type.manual}
      end)
    end
    local boxes = engine == nil
    local blockers, removes = {}, {}
    for _, e in ipairs(try(function() return surface.find_entities_filtered{area={{x, y}, {x+1, y+1}}, limit=32} end) or {}) do
      if e.valid and not IGNORED[e.type] and e.type ~= 'character' and collide(layers(try(function() return e.prototype.collision_mask end)), ti.layers) then
        if not protected(e) then removes[#removes+1] = e
        elseif engine == false or boxes or try(function() return e.to_be_deconstructed() end) then blockers[#blockers+1] = blocker(e, force) end
      end
    end
    if engine == false or #blockers > 0 then
      return {why=#blockers > 0 and 'blocked by '..table.concat(M.blocker_texts({blockers}), ', ') or 'the game refuses '..ti.result..' there now',
        blockers=blockers}
    end
    return {removes=removes}
  end
  -- What a hand-laid tile takes away, for the reply: 'water-cane (68.8,45.9)'.
  function M.removes_text(list, limit)
    local seen, parts = {}, {}
    for _, e in ipairs(list) do
      if e.valid then
        local text = e.name..' '..at1(e.position)
        if not seen[text] then seen[text] = true; parts[#parts+1] = text end
      end
    end
    if #parts == 0 then return nil end
    limit = limit or 4
    return table.concat(parts, ', ', 1, math.min(limit, #parts))..(#parts > limit and string.format(' and %d more', #parts-limit) or '')
  end
  -- The lines for a list of tiles' blockers, each entity once.
  function M.blocker_texts(lists)
    local seen, texts = {}, {}
    for _, list in ipairs(lists) do
      for _, b in ipairs(list) do
        local k = b.entity.valid and b.entity.unit_number or b.text
        if not seen[k] then seen[k] = true; texts[#texts+1] = b.text end
      end
    end
    return texts
  end

  -- For route planners (belts, pipes: one tile each): a function (x, y) ->  -- For route planners (belts, pipes: one tile each): a function (x, y) ->
  -- whether the entity stands on that tile as it is now, or on a tile ghost
  -- ordered there; each tile kind's layers are read once. Call it only on a
  -- tile the engine's ghost check took (its chunk is generated).
  function M.stands_fn(surface, proto)
    local mask = layers(try(function() return proto.collision_mask end))
    if not next(mask) then return function() return true end end
    local kinds = {}
    return function(x, y)
      local t = surface.get_tile(x, y)
      local name = t.name
      local c = kinds[name]
      if c == nil then c = collide(mask, layers(t.prototype.collision_mask)); kinds[name] = c end
      if not c then return true end
      for _, g in pairs(surface.find_entities_filtered{position={x+0.5, y+0.5}, radius=0.1, type='tile-ghost'}) do
        local gl = try(function() return prototypes.tile[g.ghost_name].collision_mask.layers end)
        if gl and not collide(mask, gl) then return true end
      end
      return false
    end
  end
  -- What the straight line between two points crosses that the entity cannot
  -- stand on, for a route that found no way: 'the straight line ... crosses 14
  -- tiles a transport-belt cannot stand on: wetland-blue-slime (landfill makes
  -- them buildable)'; nil when it crosses none.
  function M.line_tiles(surface, force, proto, from, to)
    local mask = layers(try(function() return proto.collision_mask end))
    if not next(mask) then return nil end
    remedy_cache = {}
    local dx, dy = to.x - from.x, to.y - from.y
    local n = math.max(1, math.ceil(math.max(math.abs(dx), math.abs(dy)) * 2))
    local seen, names, fixes, count = {}, {}, {}, 0
    for i = 0, n do
      local x, y = math.floor(from.x + dx * i / n), math.floor(from.y + dy * i / n)
      local k = key(x, y)
      if not seen[k] then
        seen[k] = true
        local t = try(function() return surface.get_tile(x, y) end)
        local name = t and try(function() return t.name end)
        local tl = name and try(function() return t.prototype.collision_mask.layers end)
        if name and tl and collide(mask, tl) then
          count = count + 1
          if not names[name] then
            names[name] = true; names[#names+1] = name
            local fix = remedy(force, name, tl, mask)
            if fix and not fixes[fix] then fixes[fix] = true; fixes[#fixes+1] = fix end
          end
        end
      end
    end
    if count == 0 then return nil end
    return string.format('the straight line from (%g,%g) to (%g,%g) crosses %d tile%s a %s cannot stand on: %s%s', from.x, from.y, to.x, to.y,
      count, count == 1 and '' or 's', proto.name, table.concat(names, ', '),
      #fixes > 0 and ' ('..table.concat(fixes, ' or ')..' makes them buildable)' or ' (no tile item makes them buildable)')
  end

  -- Entities that stand on or beside a rail: the game places them only where
  -- a rail is, so a plan that lays its rails too is checked by the game later.
  local RAIL_BOUND = {['rail-signal']=true, ['rail-chain-signal']=true, ['train-stop']=true, locomotive=true,
    ['cargo-wagon']=true, ['fluid-wagon']=true, ['artillery-wagon']=true}
  -- Items in square cells, for nearness queries (poles, standing targets).
  local function grid(cell)
    local g, cells = {}, {}
    function g.add(item, pos)
      local k = key(math.floor(pos.x/cell), math.floor(pos.y/cell))
      local c = cells[k]
      if not c then c = {}; cells[k] = c end
      c[#c+1] = item
    end
    -- fn(item) for every item in the cells within r of pos (a superset).
    function g.near(pos, r, fn)
      for cx = math.floor((pos.x-r)/cell), math.floor((pos.x+r)/cell) do
        for cy = math.floor((pos.y-r)/cell), math.floor((pos.y+r)/cell) do
          for _, it in ipairs(cells[key(cx, cy)] or {}) do fn(it) end
        end
      end
    end
    return g
  end
  local function dist(a, b) return ((a.x-b.x)^2+(a.y-b.y)^2)^0.5 end
  M.MAX_ENTITIES, M.MAX_TILES = 1024, 8192

  -- Walls, gates and pipes stretch their collision box toward what they
  -- join (2.0.77: a lone wall or pipe is 0.289 from its centre on each side,
  -- joined it reaches 0.488 on that side, so joined ones leave no gap a
  -- character passes): walls join walls and gates along the gate's line,
  -- pipes join pipes, a pipe-to-ground's open side, and a built machine's
  -- fluid connection on their tile. For planned ones (recs near the
  -- character): their stretched sides, and a built neighbour's side toward
  -- them, as flood boxes {x0, y0, x1, y1, name, rec, ids = recs it needs}.
  -- Fluid connections of machines planned in the same call are not read.
  local JOINS = {wall=true, gate=true, pipe=true, ['pipe-to-ground']=true}
  local SIDES = {{1, 0, 4}, {-1, 0, 12}, {0, 1, 8}, {0, -1, 0}}
  local REACH = 0.488
  local function joins(at_type, at_dir, to_type, to_dir, side)
    local back = (side+8)%16
    if at_type == 'wall' then return to_type == 'wall' or (to_type == 'gate' and to_dir%8 == side%8) end
    if at_type == 'gate' then return side%8 == at_dir%8 and (to_type == 'wall' or to_type == 'gate') end
    if at_type == 'pipe' then return to_type == 'pipe' or (to_type == 'pipe-to-ground' and to_dir == back) end
    if at_type == 'pipe-to-ground' then return side == at_dir and (to_type == 'pipe' or (to_type == 'pipe-to-ground' and to_dir == back)) end
    return false
  end
  -- The piece of a box between its edge and REACH from its centre on a side.
  local function stretch(b, c, side)
    local l, t, r, d = b.left_top.x, b.left_top.y, b.right_bottom.x, b.right_bottom.y
    if side == 4 then return {r, t, c.x+REACH, d} elseif side == 12 then return {c.x-REACH, t, l, d}
    elseif side == 8 then return {l, d, r, c.y+REACH} else return {l, c.y-REACH, r, t} end
  end
  function M.joined_pieces(s, force, recs)
    local mine, lo, hi = {}, nil, nil
    for _, r in ipairs(recs) do
      if r.proto and JOINS[r.proto.type] and r.pos then
        mine[key(math.floor(r.pos.x), math.floor(r.pos.y))] = r
        lo = lo and {x=math.min(lo.x, r.pos.x), y=math.min(lo.y, r.pos.y)} or {x=r.pos.x, y=r.pos.y}
        hi = hi and {x=math.max(hi.x, r.pos.x), y=math.max(hi.y, r.pos.y)} or {x=r.pos.x, y=r.pos.y}
      end
    end
    local pieces = {}
    if not lo then return pieces end
    -- Built neighbours: walls, gates, pipes, and machines' fluid connections
    -- by the tile they take (the side of the machine they face).
    local built, ports = {}, {}
    local area = {left_top={x=lo.x-1.5, y=lo.y-1.5}, right_bottom={x=hi.x+1.5, y=hi.y+1.5}}
    for _, e in ipairs(try(function() return s.find_entities_filtered{area=area, force=force, limit=4096} end) or {}) do
      if e.valid and e.type ~= 'entity-ghost' then
        if JOINS[e.type] then built[key(math.floor(e.position.x), math.floor(e.position.y))] = e
        elseif (try(function() return #e.fluidbox end) or 0) > 0 then
          for i = 1, #e.fluidbox do
            for _, c in ipairs(try(function() return e.fluidbox.get_pipe_connections(i) end) or {}) do
              local tp, from = c.target_position, c.position
              if tp and from and c.connection_type ~= 'underground' then
                local tk = key(math.floor(tp.x), math.floor(tp.y))
                ports[tk] = ports[tk] or {}
                table.insert(ports[tk], {x=math.floor(from.x)-math.floor(tp.x), y=math.floor(from.y)-math.floor(tp.y)})
              end
            end
          end
        end
      end
    end
    for k, r in pairs(mine) do
      local t, dir = r.proto.type, r.dir or 0
      -- A gate opens for the character, its stretched sides too: none for it.
      if t == 'gate' then t = nil end
      local x, y = math.floor(r.pos.x), math.floor(r.pos.y)
      for _, sd in ipairs(SIDES) do
        local nk = key(x+sd[1], y+sd[2])
        local o, e = mine[nk], built[nk]
        local side = sd[3]
        local port = false
        for _, d in ipairs(t == 'pipe' and ports[k] or {}) do if d.x == sd[1] and d.y == sd[2] then port = true end end
        if not t then
          -- (a gate)
        elseif o and o ~= r and joins(t, dir, o.proto.type, o.dir or 0, side) then
          -- Both planned: this side stretches only with the other placed too.
          local b = stretch(r.box, r.pos, side)
          pieces[#pieces+1] = {b[1], b[2], b[3], b[4], r.name, r, ids={r, o}}
        elseif e and joins(t, dir, e.type, e.direction, side) then
          local b = stretch(r.box, r.pos, side)
          pieces[#pieces+1] = {b[1], b[2], b[3], b[4], r.name, r, ids={r}}
          -- The built one stretches toward it once it stands (a gate opens: none).
          if e.type ~= 'gate' then
            local eb = stretch(e.bounding_box, e.position, (side+8)%16)
            pieces[#pieces+1] = {eb[1], eb[2], eb[3], eb[4], e.name, r, ids={r}}
          end
        elseif port and not o then
          -- A built machine's fluid connection takes this tile from that side.
          local b = stretch(r.box, r.pos, side)
          pieces[#pieces+1] = {b[1], b[2], b[3], b[4], r.name, r, ids={r}}
        end
      end
    end
    return pieces
  end

  -- The check. plan: {kind = ghosts | paste | build, mode? (a paste's),
  -- entities = {{index, copy?, name, position, direction (number), quality?,
  -- item?}}, tiles = {{index?, name (tile), position, item?}}, details?,
  -- standing?}. p: the player, bot or platform proxy the real call would run
  -- as. Returns the reply, the per-entity records and the counts.
  function M.check(p, plan)
    remedy_cache = {}
    local s, force = p.surface, p.force
    local on_platform = api.own_platform(p)
    local kind, mode = plan.kind, plan.mode or 'normal'
    local manual = kind == 'build'
    -- What the real call takes in its way: place_ghosts marks trees and rocks,
    -- as a paste does in forced mode, and in superforced mode our own entities
    -- too; a normal paste and a hand build take nothing (harness docs, paste).
    local marks_obstacles = kind == 'ghosts' or (kind == 'paste' and mode ~= 'normal')
    local marks_own = kind == 'paste' and mode == 'superforced'
    local check_type = manual and defines.build_check_type.manual or defines.build_check_type.manual_ghost
    local forced = marks_obstacles or nil
    local character = try(function() return p.character end)
    -- Tiles as they will be: planned tiles, then tile ghosts already ordered,
    -- over the surface's. One engine read per tile; a tile kind's collision
    -- layers are read once.
    local planned, pending, cache, kinds = {}, {}, {}, {}
    local function surface_tile(x, y)
      local k = key(x, y)
      local c = cache[k]
      if c == nil then
        local ok, t = pcall(s.get_tile, x, y)
        local name = ok and t and t.name or 'out-of-map'
        c = kinds[name]
        if not c then
          c = {name=name, layers=ok and t and try(function() return t.prototype.collision_mask.layers end) or {out_of_map=true}}
          kinds[name] = c
        end
        cache[k] = c
      end
      return c
    end
    local function tile_at(x, y)
      local k = key(x, y)
      return planned[k] or pending[k] or surface_tile(x, y)
    end
    local out = {dry_run=true, note='nothing was placed'}
    local lo, hi
    local function grow(pos)
      lo = lo and {x=math.min(lo.x, pos.x), y=math.min(lo.y, pos.y)} or {x=pos.x, y=pos.y}
      hi = hi and {x=math.max(hi.x, pos.x), y=math.max(hi.y, pos.y)} or {x=pos.x, y=pos.y}
    end
    for _, e in ipairs(plan.entities or {}) do grow(e.position) end
    for _, t in ipairs(plan.tiles or {}) do grow(t.position) end
    -- (the box read, and whether the read stopped at its limit: past either, a tile is looked up on its own)
    local read_lo, read_hi, read_all
    if lo then
      local m = 40
      read_lo, read_hi = {x=lo.x-m, y=lo.y-m}, {x=hi.x+m, y=hi.y+m}
      local list = s.find_entities_filtered{area={left_top=read_lo, right_bottom=read_hi}, type='tile-ghost', force=force, limit=4096}
      read_all = #list < 4096
      for _, g in pairs(list) do
        local proto = g.valid and prototypes.tile[g.ghost_name]
        if proto then
          local x, y = math.floor(g.position.x), math.floor(g.position.y)
          pending[key(x, y)] = {name=g.ghost_name, layers=layers(proto.collision_mask), x=x, y=y}
        end
      end
    end
    -- A tile ghost the read above did not cover (Astra, shift12 12:41: a hole named where a tile ghost stood), looked
    -- up once.
    local looked = {}
    local function ghost_unread(x, y)
      if read_all and x >= read_lo.x and x < read_hi.x and y >= read_lo.y and y < read_hi.y then return false end
      local k = key(x, y)
      if looked[k] == nil then
        looked[k] = (try(function()
          return s.count_entities_filtered{area={{x+0.1, y+0.1}, {x+0.9, y+0.9}}, type='tile-ghost', force=force, limit=1}
        end) or 0) > 0
      end
      return looked[k]
    end
    -- Entities on the planned tiles whose collision mask meets the tile's
    -- (one query over the tiles' box): those tiles get the engine's check.
    local in_way
    local function tile_in_way(x, y)
      if not in_way then
        in_way = {}
        local tx0, ty0, tx1, ty1, masks = nil, nil, nil, nil, {}
        for _, t in ipairs(plan.tiles or {}) do
          local tx, ty = math.floor(t.position.x), math.floor(t.position.y)
          tx0, ty0 = math.min(tx0 or tx, tx), math.min(ty0 or ty, ty)
          tx1, ty1 = math.max(tx1 or tx, tx), math.max(ty1 or ty, ty)
          local tp = prototypes.tile[t.name]
          if tp and not masks[t.name] then masks[t.name] = layers(tp.collision_mask) end
        end
        if tx0 then
          for _, e in ipairs(try(function() return s.find_entities_filtered{area={{tx0, ty0}, {tx1+1, ty1+1}}, limit=8192} end) or {}) do
            local em = e.valid and not IGNORED[e.type] and e.type ~= 'character' and layers(try(function() return e.prototype.collision_mask end))
            local hits = false
            for _, m in pairs(masks) do if em and collide(em, m) then hits = true end end
            if hits then
              -- (the tiles its box meets or touches: the engine counts an edge that only touches on some sides)
              local b = e.bounding_box
              for bx = math.ceil(b.left_top.x)-1, math.floor(b.right_bottom.x) do
                for by = math.ceil(b.left_top.y)-1, math.floor(b.right_bottom.y) do in_way[key(bx, by)] = true end
              end
            end
          end
        end
      end
      return in_way[key(x, y)]
    end
    local tile_marked = {}
    -- What hand-laid tiles take away (hand_tile: water-cane, fish), named once.
    local tile_removes, removes_seen = {}, {}
    local function took(list)
      for _, e in ipairs(list or {}) do
        local k = e.valid and e.name..at1(e.position)
        if k and not removes_seen[k] then removes_seen[k] = true; tile_removes[#tile_removes+1] = e end
      end
    end
    -- Planned tiles: each must go on what is there now. A build entry whose
    -- brush lays no tile at all fails (build_tile).
    local tile_rows, tiles_planned, tiles_already, tiles_refused = {}, 0, 0, 0
    local brush = {} -- build entry index -> {laid, total, why (the first tile's refusal)}
    for _, t in ipairs(plan.tiles or {}) do
      local x, y = math.floor(t.position.x), math.floor(t.position.y)
      local proto = prototypes.tile[t.name]
      local here = surface_tile(x, y)
      local k = key(x, y)
      local why, laid
      if not proto then why = 'unknown tile '..tostring(t.name)
      elseif not on_platform and not api.charted(p, {x=x+0.5, y=y+0.5}) then why = 'outside the charted area'
      elseif here.name == t.name or (pending[k] and pending[k].name == t.name) then tiles_already = tiles_already + 1
      else
        local item = t.item or try(function() return proto.items_to_place_this[1].name end)
        if item and not M.placeable_on(item, here.name) then why = string.format('%s cannot go on %s', item, here.name)..others_text(force, here.name, here.layers, item)
        elseif manual and item and tile_in_way(x, y) then
          -- A hand build: protected entities block it, marked or not; it takes the others away.
          local v = M.hand_tile(s, force, item, x, y)
          if v.why then why = v.why else took(v.removes) end
        elseif tile_in_way(x, y) then
          -- Trees and rocks there: place_ghosts marks them first; else they block.
          local b = M.tile_blockers(s, force, t.name, x, y)
          if b then
            local all = #b > 0
            for _, one in ipairs(b) do if not one.obstacle then all = false end end
            if all and kind == 'ghosts' then
              for _, one in ipairs(b) do tile_marked[one.entity.name..' '..at1(one.entity.position)] = true end
            elseif #b > 0 then why = 'blocked by '..table.concat(M.blocker_texts({b}), ', ')
            else why = 'the game refuses it there now' end
          end
        end
      end
      if why then
        tiles_refused = tiles_refused + 1
        if #tile_rows < 10 then tile_rows[#tile_rows+1] = tile_text(x, y)..' '..t.name..': '..why end
      elseif proto and here.name ~= t.name and not planned[k] and not (pending[k] and pending[k].name == t.name) then
        tiles_planned = tiles_planned + 1; laid = true
        planned[k] = {name=t.name, layers=layers(proto.collision_mask), index=t.index, x=x, y=y}
      end
      if manual and t.index then
        local b = brush[t.index] or {laid=0, total=0}
        brush[t.index] = b
        b.total = b.total + 1
        if laid then b.laid = b.laid + 1 end
        b.why = b.why or why
      end
    end

    local has_rails = false
    for _, e in ipairs(plan.entities or {}) do
      local proto = prototypes.entity[e.name or '']
      if proto and RAILS[proto.type] then has_rails = true; break end
    end
    local recs, nproblems = {}, 0
    local occupied = {} -- tile key -> planned recs whose footprint covers it
    local needed, need_list = {}, {} -- tile key -> {x, y, item, why}
    local counts = {ok=0, after_tiles=0, after_rails=0, needs_tiles=0, blocked=0, exists=0}
    -- Cliffs under placeable entries (Sol 12:20: a belt_route dry run said 55 placeable, 6 of them over cliffs, with
    -- no cliff explosives held): a ghost over a cliff marks it, and each cliff takes one of its explosive item.
    local cliffs, over_cliffs = {}, 0
    local function need(x, y, item, why)
      local k = key(x, y)
      if needed[k] then return end
      needed[k] = {x=x, y=y, item=item, why=why}
      need_list[#need_list+1] = needed[k]
    end
    for _, e in ipairs(plan.entities or {}) do
      local proto = prototypes.entity[e.name or '']
      local rec = {index=e.index, copy=e.copy, name=e.name, dir=e.direction or 0, quality=e.quality, item=e.item, requests=e.requests, ug_type=e.ug_type,
        construction=e.construction, recipe=e.recipe}
      recs[#recs+1] = rec
      local reasons = {}
      if not proto then
        rec.status = 'blocked'; reasons[1] = 'not an entity: '..tostring(e.name)
      else
        rec.proto = proto
        rec.mask = layers(proto.collision_mask)
        rec.pos = M.snap(proto, e.position, rec.dir)
        if math.abs(rec.pos.x-e.position.x) > 0.01 or math.abs(rec.pos.y-e.position.y) > 0.01 then rec.asked = e.position end
        rec.box, rec.shape = M.footprint(proto, rec.pos, rec.dir)
        local mask = rec.mask
        local rail = RAILS[proto.type]
        local chunk = {x=math.floor(rec.pos.x/32), y=math.floor(rec.pos.y/32)}
        if not on_platform and not api.charted(p, rec.pos) then
          rec.status = 'blocked'; reasons[1] = string.format('outside the charted area (chunk %d,%d)', chunk.x, chunk.y)
        else
          local x0, y0, x1, y1 = span(rec.box)
          -- Planned entities before it in the plan (rails may cross rails).
          local hit
          for x = x0, x1 do
            for y = y0, y1 do
              for _, o in ipairs(occupied[key(x, y)] or {}) do
                if not hit and o ~= rec and collide(mask, o.mask) then
                  -- Rails cross and join rails; the same rail twice is one too many.
                  if rail and RAILS[o.proto.type] then
                    if rec.shape and o.shape and meets(o, rec) then hit = o end
                  elseif meets(o, rec) then hit = o end
                end
              end
            end
          end
          if hit then
            reasons[#reasons+1] = string.format('collides with planned #%s %s at %s', hit.copy and (hit.copy..'.'..hit.index) or tostring(hit.index), hit.name, at(hit.pos))
          end
          -- What stands in the footprint now. A rail: other rails cross or
          -- join it (the game's check decides), characters walk over it, and
          -- the rest counts where its turned box reaches.
          local blockers, marked, ghosts, same, mine = {}, {}, {}, nil, false
          -- A hand build replaces an entity of its fast-replace group only on its own centre and of its size; another
          -- of the group on these tiles refuses it (runtime.lua build_direct; Astra, shift13 16:43: a splitter at
          -- (-6.5,554) over the belt at (-6.5,554.5) read placeable, and the build refused it until the belt was mined).
          local group = manual and try(function() return proto.fast_replaceable_group end)
          local offset = {}
          local function same_size(o)
            local a, b = proto.collision_box, try(function() return o.prototype.collision_box end)
            return a and b and math.abs((a.right_bottom.x-a.left_top.x)-(b.right_bottom.x-b.left_top.x)) < 0.01
              and math.abs((a.right_bottom.y-a.left_top.y)-(b.right_bottom.y-b.left_top.y)) < 0.01
          end
          local soft = {} -- (a hand build: water-cane and fish in the way, which landfill laid there takes away)
          local under_cliffs = {}
          local shape = rec.shape
          local function here(o)
            if not shape then return true end
            local b = o.bounding_box
            if not b or (b.orientation and b.orientation ~= 0) then return true end
            return api.rail_overlaps(shape, b.left_top.x, b.left_top.y, b.right_bottom.x, b.right_bottom.y)
          end
          local function same_dir(d)
            if not shape then return true end
            return (proto.type == 'curved-rail-a' or proto.type == 'curved-rail-b') and d == rec.dir or d % 8 == rec.dir % 8
          end
          for _, o in pairs(s.find_entities_filtered{area=rec.box}) do
            if o.valid then
              local t = o.type
              if group and t ~= 'entity-ghost' and o.force == force and try(function() return o.prototype.fast_replaceable_group end) == group
                and not (math.abs(o.position.x-rec.pos.x) < 0.01 and math.abs(o.position.y-rec.pos.y) < 0.01 and same_size(o)) then
                offset[#offset+1] = o.name..' '..at(o.position)
              end
              if t == 'entity-ghost' then
                if o.ghost_name == e.name and math.abs(o.position.x-rec.pos.x) < 0.01 and math.abs(o.position.y-rec.pos.y) < 0.01 and same_dir(o.direction) then same = same or o
                elseif shape and RAILS[o.ghost_type] then -- crossing or joining
                elseif overlap(o.bounding_box or rec.box, rec.box) and here(o) then ghosts[#ghosts+1] = 'ghost '..o.ghost_name..' '..at(o.position) end
              elseif rail and RAILS[t] then
                -- Another rail crosses or joins it; the same rail there is the same.
                if o.name == e.name and math.abs(o.position.x-rec.pos.x) < 0.01 and math.abs(o.position.y-rec.pos.y) < 0.01 and same_dir(o.direction) then same = o end
              elseif shape and t == 'character' then -- a character on the track
              elseif shape and not here(o) then -- outside the turned box
              elseif t == 'character' then
                if character and o == character then mine = true
                else
                  local who = api.character_owner and api.character_owner(o)
                  blockers[#blockers+1] = string.format('%s at (%.1f,%.1f)', who and who.."'s character" or 'a character', o.position.x, o.position.y)
                end
              elseif not IGNORED[t] and not (rail and RAILS[t]) then
                local om = try(function() return o.prototype.collision_mask end)
                if collide(mask, layers(om)) then
                  if o.name == e.name and math.abs(o.position.x-rec.pos.x) < 0.01 and math.abs(o.position.y-rec.pos.y) < 0.01 then same = o
                  else
                    local neutral = o.force == nil or o.force.name == 'neutral'
                    local obstacle = OBSTACLE[t] and o.minable and neutral
                    local own = o.force == force and o.minable
                    if (obstacle and marks_obstacles) or (own and marks_own) then
                      if #marked < 4 then marked[#marked+1] = o.name..' '..at(o.position) end
                    elseif manual and not protected(o) then soft[#soft+1] = o
                    elseif #blockers < 4 or t == 'cliff' then
                      if t == 'cliff' then under_cliffs[#under_cliffs+1] = o end
                      local name = o.name
                      if t == 'cliff' then name = name..' (cliff explosives clear it)' end
                      if o.force and o.force ~= force and not neutral then name = name..' of force '..o.force.name end
                      blockers[#blockers+1] = name..' '..at(o.position)
                    end
                  end
                end
              end
            end
          end
          -- Tiles: the entity's own tile rules, else its collision mask against each tile.
          local rules = try(function() return proto.tile_buildability_rules end)
          local tile_need, tile_bad, broken = {}, {}, nil
          if type(rules) == 'table' and #rules > 0 then
            broken = api.placewhy.tile_rules(s, proto, rec.pos, rec.dir, function(x, y)
              local t = tile_at(x, y)
              return {name=t.name, prototype={collision_mask={layers=t.layers}}}
            end)
          else
            for x = x0, x1 do
              for y = y0, y1 do
                local t = tile_at(x, y)
                if collide(mask, t.layers) and (not shape or api.rail_overlaps(shape, x, y, x+1, y+1)) then
                  if t.layers.out_of_map then tile_bad[#tile_bad+1] = tile_text(x, y)..' is outside the map'
                  else
                    local fix = remedy(force, t.name, t.layers, mask)
                    if fix then tile_need[#tile_need+1] = {x=x, y=y, item=fix, tile=t.name}
                    else tile_bad[#tile_bad+1] = string.format('%s %s (no tile item makes it buildable)', tile_text(x, y), t.name) end
                  end
                end
              end
            end
          end
          -- What stands where the tiles it needs go (tile_blockers): place_ghosts
          -- marks trees and rocks there first, as the game's ghost placement does;
          -- anything else, or another call, is blocked by them. A hand build
          -- lays the tiles by hand first (hand_tile: marked or not, protected
          -- ones block; the tile takes water-cane and fish away).
          local tiles_take
          if #tile_need > 0 then
            local lists, refused = {}, {}
            for _, n in ipairs(tile_need) do
              local tile = try(function() return prototypes.item[n.item].place_as_tile_result.result.name end)
              local b
              if manual and tile then
                local v = M.hand_tile(s, force, n.item, n.x, n.y)
                if v.blockers and #v.blockers > 0 then b = v.blockers
                elseif v.why then b = {}
                else
                  for _, r in ipairs(v.removes or {}) do tiles_take = tiles_take or {}; tiles_take[#tiles_take+1] = r end
                end
              else
                b = tile and M.tile_blockers(s, force, tile, n.x, n.y)
              end
              if b then
                local all = #b > 0
                for _, one in ipairs(b) do if not one.obstacle then all = false end end
                if all and kind == 'ghosts' then
                  for _, one in ipairs(b) do
                    local text = one.entity.name..' '..at(one.entity.position)
                    local dup = false
                    for _, m in ipairs(marked) do if m == text then dup = true end end
                    if not dup and #marked < 4 then marked[#marked+1] = text end
                  end
                elseif #b > 0 then lists[#lists+1] = b
                else refused[#refused+1] = n.item..' at '..tile_text(n.x, n.y) end
              end
            end
            if #lists > 0 then
              local texts = M.blocker_texts(lists)
              reasons[#reasons+1] = 'blocked by '..table.concat(texts, ', ', 1, math.min(3, #texts))..' (where its '..tile_need[1].item..' goes)'
            end
            if #refused > 0 then reasons[#reasons+1] = 'the game refuses '..table.concat(refused, ', ', 1, math.min(3, #refused))..' there now' end
          end
          -- Water-cane and fish in its footprint on a tile it needs landfill on go with that landfill, laid first.
          if #soft > 0 then
            local needs = {}
            for _, n in ipairs(tile_need) do needs[key(n.x, n.y)] = true end
            for _, o in ipairs(soft) do
              if needs[key(math.floor(o.position.x), math.floor(o.position.y))] then
                tiles_take = tiles_take or {}; tiles_take[#tiles_take+1] = o
              elseif #blockers < 4 then blockers[#blockers+1] = o.name..' '..at(o.position) end
            end
          end
          -- The engine's own check, as the real call makes it. It decides
          -- whatever stands there now (an upgrade over a machine of the same
          -- kind, rail and pumpjack rules); the reasons above say why not.
          local engine = try(function()
            return s.can_place_entity{name=e.name, position=rec.pos, direction=rec.dir, force=force, build_check_type=check_type, forced=forced}
          end)
          rec.engine = engine
          -- Tiles laid by the plan or already ordered under it, and (a build
          -- batch) the last entry laying one.
          local covered, last_tile = false, nil
          for x = x0, x1 do
            for y = y0, y1 do
              local k = key(x, y)
              local t = planned[k] or pending[k]
              if t then covered = true end
              if planned[k] and planned[k].index and (not last_tile or planned[k].index > last_tile) then last_tile = planned[k].index end
            end
          end
          if manual and same and same.type == 'entity-ghost' then same = nil; rec.note = 'builds the ghost there' end
          -- Tiles count whatever the engine says now: on a platform it takes
          -- an entity ghost over empty space, which nothing builds until
          -- foundation is there.
          if engine == true and not same and #under_cliffs > 0 then
            over_cliffs = over_cliffs + 1
            for _, c in ipairs(under_cliffs) do
              local k = (try(function() return c.unit_number end)) or (c.position.x..','..c.position.y)
              cliffs[k] = cliffs[k] or {e=c, item=try(function() return c.prototype.cliff_explosive_prototype end) or 'cliff-explosives'}
            end
          end
          if #offset > 0 then
            reasons[#reasons+1] = string.format('blocked by %s: on these tiles, not on the same centre; a build replaces one of its kind only on its own centre and of its size: mine it first',
              table.concat(offset, ', ', 1, math.min(3, #offset)))
          elseif engine == true and not same then
            if #blockers > 0 then rec.note = 'replaces '..table.concat(blockers, ', ', 1, math.min(4, #blockers)) end
          elseif #blockers > 0 then reasons[#reasons+1] = 'blocked by '..table.concat(blockers, ', ', 1, math.min(4, #blockers)) end
          if broken then reasons[#reasons+1] = broken end
          if #tile_bad > 0 then reasons[#reasons+1] = 'tiles: '..table.concat(tile_bad, ', ', 1, math.min(4, #tile_bad)) end
          if same and #reasons == 0 then
            rec.status = 'exists'
            rec.note = (same.type == 'entity-ghost' and 'a ghost of it is already there' or 'already built there')
              ..(kind == 'paste' and ' (the paste skips it)' or '')
          elseif #reasons > 0 then rec.status = 'blocked'
          elseif #tile_need > 0 then
            local by = {}
            for _, n in ipairs(tile_need) do
              need(n.x, n.y, n.item, 'under')
              by[n.item] = (by[n.item] or 0) + 1
            end
            local parts = {}
            for item, n in pairs(by) do parts[#parts+1] = n..' '..item end
            table.sort(parts)
            rec.status = 'needs_tiles'
            -- place_ghosts lays the tile ghosts under it first (as a player's forced placement does); a paste
            -- leaves the entity ghost alone there.
            rec.note = string.format('stands on %d %s tile%s: needs %s first%s', #tile_need, tile_need[1].tile, #tile_need == 1 and '' or 's', table.concat(parts, ', '),
              engine == true and not manual and (kind == 'ghosts' and ' (place_ghosts lays those tile ghosts under it first)'
                or ' (its ghost goes there now; nothing builds it before that)') or '')
            if tiles_take then
              took(tiles_take)
              rec.note = rec.note..'; the '..tile_need[1].item..' removes '..M.removes_text(tiles_take)
            end
          elseif engine == true then rec.status = 'ok'
          elseif covered then
            rec.status = 'after_tiles'; rec.note = 'placeable once the tiles under it are laid'
            -- What the real call does first: place_ghosts places entity ghosts
            -- before tile ghosts; a build batch goes entry by entry.
            if kind == 'ghosts' then
              rec.note = rec.note..'; the game refuses its ghost on the tiles there now, and place_ghosts places entity ghosts before tile ghosts'
            elseif manual and last_tile and e.index and last_tile > e.index then
              rec.late = last_tile
              rec.note = rec.note..string.format('; entry #%d of this batch lays one of them, after this one', last_tile)
            end
          elseif #marked > 0 then rec.status = 'ok'
          elseif mine and manual then rec.status = 'ok'
          elseif RAIL_BOUND[proto.type] and has_rails then
            rec.status = 'after_rails'; rec.note = 'goes with the plan\'s rails: the game checks its rail rules once they stand'
          else
            rec.status = 'blocked'
            local text = api.placement_error and try(function() return api.placement_error(p, proto, rec.pos, rec.dir) end)
            reasons[#reasons+1] = text and (text:gsub('^placement blocked', 'the game refuses it here')) or 'the game refuses it here'
          end
          if #marked > 0 and rec.status ~= 'blocked' then
            rec.note = (rec.note and rec.note..'; ' or '')..string.format('%s marks %s for removal%s', kind == 'ghosts' and 'place_ghosts' or 'the paste',
              table.concat(marked, ', '), kind == 'ghosts' and ' (construct mines trees and rocks)' or '')
          end
          if #ghosts > 0 and rec.status ~= 'blocked' then
            rec.note = (rec.note and rec.note..'; ' or '')..'over '..table.concat(ghosts, ', ', 1, math.min(3, #ghosts))
          end
          if mine and manual and rec.status ~= 'blocked' then
            rec.note = (rec.note and rec.note..'; ' or '')..'your character stands on it: build steps aside first'
          end
          for x = x0, x1 do
            for y = y0, y1 do
              local k = key(x, y)
              occupied[k] = occupied[k] or {}
              table.insert(occupied[k], rec)
            end
          end
        end
      end
      rec.why = #reasons > 0 and table.concat(reasons, '; ') or nil
      counts[rec.status] = (counts[rec.status] or 0) + 1
      -- What the game refuses at this moment (a normal paste is all or nothing).
      if rec.status == 'blocked' or (rec.status == 'needs_tiles' and rec.engine == false) then counts.refused_now = (counts.refused_now or 0) + 1 end
    end

    -- On a platform: the empty tiles new foundation would enclose. The game
    -- builds no foundation that leaves a hole of empty space (tilecheck.lua);
    -- a region followed past HOLE_LIMIT tiles counts as open space. Tile
    -- ghosts already ordered count as foundation.
    local holes, unchecked = 0, false
    if on_platform then
      local filled, seeds = {}, {}
      for k, t in pairs(planned) do filled[k] = true; seeds[#seeds+1] = {t.x, t.y} end
      for k in pairs(pending) do filled[k] = true end
      for _, n in ipairs(need_list) do filled[key(n.x, n.y)] = true; seeds[#seeds+1] = {n.x, n.y} end
      local function empty(x, y)
        local t = surface_tile(x, y)
        return t.layers.empty_space == true and not t.layers.out_of_map
      end
      -- Each flood keeps its id on the tiles it reached: a flood that meets
      -- one that ended in open space is open too (its frontier was never
      -- followed, so the region only looks closed from here).
      local seen, budget, open_ids, fid = {}, FLOOD_BUDGET, {}, 0
      local foundation_item
      for _, n in ipairs(need_list) do foundation_item = foundation_item or n.item end
      foundation_item = foundation_item or 'space-platform-foundation'
      for _, seed in ipairs(seeds) do
        for _, d in ipairs(DIRS) do
          local sx, sy = seed[1]+d[1], seed[2]+d[2]
          local sk = key(sx, sy)
          if not seen[sk] and not filled[sk] and empty(sx, sy) and not ghost_unread(sx, sy) then
            fid = fid + 1
            seen[sk] = fid
            local q, i, open = {{sx, sy}}, 1, false
            while q[i] do
              if #q > HOLE_LIMIT then open = true; break end
              budget = budget - 1
              if budget < 0 then open = true; unchecked = true; break end
              local c = q[i]; i = i + 1
              for _, d2 in ipairs(DIRS) do
                local nx, ny = c[1]+d2[1], c[2]+d2[2]
                local nk = key(nx, ny)
                if not filled[nk] then
                  local sid = seen[nk]
                  if sid then
                    if sid ~= fid and open_ids[sid] then open = true end
                  else
                    local t = surface_tile(nx, ny)
                    if t.layers.out_of_map then open = true
                    elseif t.layers.empty_space and not ghost_unread(nx, ny) then seen[nk] = fid; q[#q+1] = {nx, ny} end
                  end
                end
              end
              if open then break end
            end
            if open then open_ids[fid] = true
            else
              for _, c in ipairs(q) do need(c[1], c[2], foundation_item, 'hole'); holes = holes + 1 end
            end
          end
        end
      end
    end

    -- Tiles needed, by item; on a platform, new foundation that touches none
    -- of the old or of the tile ghosts already ordered (the foundation must
    -- stay one connected area).
    if #need_list > 0 or tiles_planned > 0 or tiles_refused > 0 or tiles_already > 0 then
      local by = {}
      for _, n in ipairs(need_list) do by[n.item] = (by[n.item] or 0) + 1 end
      local t = {needed=next(by) and by or nil, under_entities=#need_list-holes > 0 and #need_list-holes or nil,
        marks=next(tile_marked) and (function()
          local list = {}
          for text in pairs(tile_marked) do list[#list+1] = text end
          table.sort(list)
          return 'place_ghosts marks '..table.concat(list, ', ', 1, math.min(4, #list))..(#list > 4 and string.format(' and %d more', #list-4) or '')
            ..' for removal first, where its tile ghosts go (construct mines trees and rocks)'
        end)() or nil,
        holes=holes > 0 and holes or nil, planned=tiles_planned > 0 and tiles_planned or nil,
        already=tiles_already > 0 and tiles_already or nil, refused=tiles_refused > 0 and tiles_refused or nil,
        refused_rows=#tile_rows > 0 and tile_rows or nil,
        removes=#tile_removes > 0 and 'laid by hand, the tiles remove '..M.removes_text(tile_removes, 8)
          ..' (water-cane and fish do not block a tile; a new tile takes them away)' or nil}
      if #need_list > 0 then
        table.sort(need_list, function(a, b) if a.y ~= b.y then return a.y < b.y end return a.x < b.x end)
        t.positions = {}
        for i = 1, math.min(MAX_LISTED, #need_list) do t.positions[i] = {x=need_list[i].x+0.5, y=need_list[i].y+0.5} end
        if #need_list > MAX_LISTED then t.more = #need_list-MAX_LISTED end
      end
      if holes > 0 then
        t.holes_note = string.format('%d empty tile%s would be enclosed by the new foundation; the game builds no foundation that leaves a hole, so they need foundation too (in positions)', holes, holes == 1 and '' or 's')
      end
      if unchecked then t.unchecked = 'the hole check stopped at its budget; some enclosed tiles may be missing' end
      if on_platform then
        local new, reached, queue = {}, {}, {}
        for k, c in pairs(planned) do new[k] = {c.x, c.y} end
        for k, c in pairs(pending) do new[k] = new[k] or {c.x, c.y, pending=true} end
        for _, n in ipairs(need_list) do new[key(n.x, n.y)] = {n.x, n.y} end
        for k, c0 in pairs(new) do
          local x, y = c0[1], c0[2]
          for _, d in ipairs(DIRS) do
            local nk = key(x+d[1], y+d[2])
            if not new[nk] then
              local tt = surface_tile(x+d[1], y+d[2])
              if not tt.layers.empty_space and not tt.layers.out_of_map and not reached[k] then reached[k] = true; queue[#queue+1] = {x, y} end
            end
          end
        end
        local i = 1
        while queue[i] do
          local c = queue[i]; i = i + 1
          for _, d in ipairs(DIRS) do
            local nk = key(c[1]+d[1], c[2]+d[2])
            if new[nk] and not reached[nk] then reached[nk] = true; queue[#queue+1] = {c[1]+d[1], c[2]+d[2]} end
          end
        end
        local loose = {}
        for k, c0 in pairs(new) do if not reached[k] and not c0.pending then loose[#loose+1] = c0 end end
        if #loose > 0 then
          table.sort(loose, function(a, b) if a[2] ~= b[2] then return a[2] < b[2] end return a[1] < b[1] end)
          local shown = {}
          for j = 1, math.min(6, #loose) do shown[j] = tile_text(loose[j][1], loose[j][2]) end
          t.not_connected = string.format('%d new foundation tile%s no existing foundation, even through the other new tiles: %s%s (the foundation must stay one connected area; %s unbuilt)',
            #loose, #loose == 1 and ' touches' or 's touch', table.concat(shown, ' '), #loose > 6 and ' ...' or '', #loose == 1 and 'it stays' or 'these stay')
        end
        local hub = try(function() return s.platform.hub end)
        if hub and hub.valid then
          local north = 0
          for _, c0 in pairs(new) do
            if not c0.pending and c0[2]+0.5 < hub.position.y-200 then north = north + 1 end
          end
          if north > 0 then t.too_far_north = north..' new foundation tiles are more than 200 tiles north of the hub (none is built there)' end
        end
      end
      out.tiles = t
    end

    -- Power: a pole joins another within the shorter of their two wire
    -- reaches; machines need a pole's supply area over them. Planned poles,
    -- pole ghosts already ordered and built poles within 40 tiles count.
    local planned_poles, consumers = {}, {}
    for _, r in ipairs(recs) do
      if r.proto and r.status ~= 'blocked' and r.status ~= 'exists' then
        if r.proto.type == 'electric-pole' then planned_poles[#planned_poles+1] = r
        elseif try(function() return r.proto.electric_energy_source_prototype end) then consumers[#consumers+1] = r end
      end
    end
    if (#planned_poles > 0 or #consumers > 0) and lo then
      local function reach_of(proto, quality)
        return try(function() return proto.get_max_wire_distance(quality or 'normal') end) or try(function() return proto.max_wire_distance end) or 0
      end
      local function supply_of(proto, quality)
        return try(function() return proto.get_supply_area_distance(quality or 'normal') end) or try(function() return proto.supply_area_distance end) or 0
      end
      local nodes = {}
      for _, r in ipairs(planned_poles) do
        nodes[#nodes+1] = {planned=r, pos=r.pos, reach=reach_of(r.proto, r.quality), supply=supply_of(r.proto, r.quality), name=r.name}
      end
      local margin = 40
      local area = {left_top={x=lo.x-margin, y=lo.y-margin}, right_bottom={x=hi.x+margin, y=hi.y+margin}}
      for _, o in ipairs(s.find_entities_filtered{area=area, type='electric-pole', force=force, limit=1024}) do
        if o.valid then
          local q = try(function() return o.quality.name end)
          nodes[#nodes+1] = {entity=o, pos=o.position, reach=reach_of(o.prototype, q), supply=supply_of(o.prototype, q), name=o.name,
            network=o.electric_network_id}
        end
      end
      for _, g in ipairs(s.find_entities_filtered{area=area, ghost_type='electric-pole', force=force, limit=256}) do
        if g.valid then
          local q = try(function() return g.quality.name end)
          nodes[#nodes+1] = {ghost=g, pos=g.position, reach=reach_of(g.ghost_prototype, q), supply=supply_of(g.ghost_prototype, q), name=g.ghost_name}
        end
      end
      -- Union-find over poles; built poles of one network start joined;
      -- planned poles and pole ghosts join what lies within reach. Twice:
      -- with the pole ghosts (what the plan joins once they are built) and
      -- without (what it joins now). Astra, shift10: a small pole 8.94 tiles
      -- from the nearest built pole (wire reach 7.5) read "reaches the built
      -- network" through two pole ghosts nobody had built, and the roboport it
      -- fed went no_power after its starting charge.
      local parent, parent0 = {}, {}
      local function find(i) while parent[i] ~= i do parent[i] = parent[parent[i]]; i = parent[i] end return i end
      local function find0(i) while parent0[i] ~= i do parent0[i] = parent0[parent0[i]]; i = parent0[i] end return i end
      local function union(a, b) a, b = find(a), find(b); if a ~= b then parent[a] = b end end
      local function union0(a, b) a, b = find0(a), find0(b); if a ~= b then parent0[a] = b end end
      local by_network, maxreach, maxsupply = {}, 1, 0
      local poles = grid(16)
      for i, n in ipairs(nodes) do
        parent[i] = i; parent0[i] = i
        if n.network then
          if by_network[n.network] then union(i, by_network[n.network]); union0(i, by_network[n.network]) else by_network[n.network] = i end
        end
        maxreach = math.max(maxreach, n.reach); maxsupply = math.max(maxsupply, n.supply)
        poles.add(i, n.pos)
      end
      for i, a in ipairs(nodes) do
        if a.planned or a.ghost then
          poles.near(a.pos, a.reach, function(j)
            local b = nodes[j]
            if j ~= i and dist(a.pos, b.pos) <= math.min(a.reach, b.reach)+1e-6 then
              union(i, j)
              if not a.ghost and not b.ghost then union0(i, j) end
            end
          end)
        end
      end
      local live, live0 = {}, {} -- root -> true when a built pole is in the group (with ghosts; now)
      for i, n in ipairs(nodes) do if n.entity then live[find(i)] = true; live0[find0(i)] = true end end
      local function covers(n, r)
        local b = r.box
        return b.left_top.x < n.pos.x+n.supply and b.right_bottom.x > n.pos.x-n.supply
          and b.left_top.y < n.pos.y+n.supply and b.right_bottom.y > n.pos.y-n.supply
      end
      local pw = {}
      local reach_text, seen_names = {}, {}
      for _, n in ipairs(nodes) do
        if n.planned and not seen_names[n.name] then
          seen_names[n.name] = true
          reach_text[#reach_text+1] = string.format('%s wire %g supply %g', n.name, n.reach, n.supply)
        end
      end
      if #reach_text > 0 then pw.reach = table.concat(reach_text, '; ') end
      -- Groups with planned poles and no built pole: islands.
      local groups, order = {}, {}
      for i, n in ipairs(nodes) do
        if n.planned or n.ghost then
          local root = find(i)
          if not live[root] then
            if not groups[root] then groups[root] = {poles={}, ghosts=0, machines={}}; order[#order+1] = root end
            if n.planned then table.insert(groups[root].poles, n) else groups[root].ghosts = groups[root].ghosts + 1 end
          end
        end
      end
      local unpowered, unpowered_count = {}, 0
      for _, r in ipairs(consumers) do
        local by_now, by_live, by_island
        local b = r.box
        local half = math.max(b.right_bottom.x-b.left_top.x, b.right_bottom.y-b.left_top.y)/2
        poles.near(r.pos, maxsupply+half+1, function(i)
          local n = nodes[i]
          if covers(n, r) then
            if not n.ghost and live0[find0(i)] then by_now = true
            elseif live[find(i)] then by_live = true
            else by_island = by_island or find(i) end
          end
        end)
        if by_now then
          -- powered as the plan stands
        elseif not by_live and by_island and groups[by_island] and #groups[by_island].poles > 0 then
          table.insert(groups[by_island].machines, r)
        else
          unpowered_count = unpowered_count + 1
          if #unpowered < 20 then
            local why
            if by_live then why = 'the poles over it reach a built network only through pole ghosts not built yet: no power until they stand'
            elseif by_island then why = 'only pole ghosts with no wire path to a built pole cover it'
            else
              local best, bd
              poles.near(r.pos, 48, function(i)
                local d = dist(nodes[i].pos, r.pos)
                if not bd or d < bd then best, bd = nodes[i], d end
              end)
              why = best and string.format('no pole\'s supply area reaches it; nearest pole %s%s at %s, %.1f tiles (supply %g)',
                best.name, best.planned and ' (planned)' or best.ghost and ' (ghost)' or '', at(best.pos), bd, best.supply)
                or 'no pole within 40 tiles of the layout'
            end
            unpowered[#unpowered+1] = {index=r.copy and (r.copy..'.'..r.index) or r.index, name=r.name, position=r.pos, why=why}
          end
        end
      end
      -- "planned pole #4", "planned poles #1-3", or a count across repeat copies.
      local function label(list)
        local idx, plain = {}, true
        for _, n in ipairs(list) do
          if n.planned.copy then plain = false end
          idx[#idx+1] = n.planned.index
        end
        if not plain then return #list..' planned pole'..(#list == 1 and '' or 's') end
        return 'planned pole'..(#list == 1 and '' or 's')..' #'..runs(idx)
      end
      local islands, more_islands = {}, 0
      for _, root in ipairs(order) do
        local g = groups[root]
        if #g.poles > 0 and #islands >= 10 then more_islands = more_islands + 1
        elseif #g.poles > 0 then
          local shown = {}
          for j = 1, math.min(4, #g.poles) do shown[j] = at(g.poles[j].pos) end
          -- The nearest built pole to the group's first poles, and the gap.
          local best, bd, from
          for j = 1, math.min(16, #g.poles) do
            local gp = g.poles[j]
            poles.near(gp.pos, 48, function(i)
              local n = nodes[i]
              if n.entity then
                local d = dist(gp.pos, n.pos)
                if not bd or d < bd then best, bd, from = n, d, gp end
              end
            end)
          end
          islands[#islands+1] = string.format('%s at %s%s%s%s: no wire path to a built pole; %s',
            label(g.poles), table.concat(shown, ' '), #g.poles > 4 and ' ...' or '',
            g.ghosts > 0 and string.format(' with %d pole ghost%s', g.ghosts, g.ghosts == 1 and '' or 's') or '',
            #g.machines > 0 and string.format(', powering %d planned machine%s', #g.machines, #g.machines == 1 and '' or 's') or '',
            best and string.format('nearest built pole %s at %s is %.1f tiles from %s (wire reach %g)', best.name, at(best.pos), bd, at(from.pos), math.min(best.reach, from.reach))
              or 'no built pole within 40 tiles')
        end
      end
      -- Planned poles that reach built ones: which built network, and
      -- separate networks the plan joins into one.
      local reached, via = {}, {}
      for i, n in ipairs(nodes) do
        if n.planned and live0[find0(i)] then local root = find0(i); reached[root] = reached[root] or {}; table.insert(reached[root], n)
        elseif n.planned and live[find(i)] then local root = find(i); via[root] = via[root] or {}; table.insert(via[root], n) end
      end
      local connected = {}
      for root, list in pairs(reached) do
        -- Per built network in the group, its pole nearest the planned ones.
        local best, order2 = {}, {}
        for _, pl in ipairs(list) do
          poles.near(pl.pos, maxreach, function(i)
            local n = nodes[i]
            if n.entity and n.network and find0(i) == root then
              local dd = dist(pl.pos, n.pos)
              local b = best[n.network]
              if not b then order2[#order2+1] = n.network end
              if not b or dd < b.d then best[n.network] = {d=dd, text=string.format('%s %s', n.name, at(n.pos))} end
            end
          end)
        end
        local r = {}
        for _, id in ipairs(order2) do r[#r+1] = best[id].text end
        local one = #list == 1
        connected[#connected+1] = #r > 1
          and string.format('%s join%s %d separate built networks into one: %s', label(list), one and 's' or '', #r, table.concat(r, ', ', 1, math.min(4, #r)))
          or string.format('%s reach%s the built network of %s', label(list), one and 'es' or '', r[1] or 'a built pole')
      end
      -- Planned poles that reach a built network only through pole ghosts:
      -- the ghosts on the way (nearest first) and the gap to built poles now.
      for root, list in pairs(via) do
        local gh, near_b, bd, from = {}, nil, nil, nil
        for _, pl in ipairs(list) do
          poles.near(pl.pos, 48, function(i)
            local n = nodes[i]
            if n.ghost and find(i) == root then gh[#gh+1] = {n=n, d=dist(pl.pos, n.pos)} end
            if n.entity then
              local d = dist(pl.pos, n.pos)
              if not bd or d < bd then near_b, bd, from = n, d, pl end
            end
          end)
        end
        table.sort(gh, function(a, b) return a.d < b.d end)
        local shown, seen = {}, {}
        for _, g in ipairs(gh) do
          if not seen[g.n] and #shown < 3 then seen[g.n] = true; shown[#shown+1] = g.n.name..' '..at(g.n.pos) end
        end
        local one = #list == 1
        connected[#connected+1] = string.format('%s reach%s a built network only through pole ghosts not built yet (%s): no wire path to a built pole until they stand%s',
          label(list), one and 'es' or '', table.concat(shown, ', '),
          near_b and string.format('; nearest built pole %s at %s is %.1f tiles from %s (wire reach %g)', near_b.name, at(near_b.pos), bd, at(from.pos),
            math.min(near_b.reach, from.reach)) or '')
      end
      table.sort(connected)
      if #planned_poles > 0 then pw.poles = #planned_poles end
      pw.connected = #connected > 0 and connected or nil
      pw.islands = #islands > 0 and islands or nil
      pw.more_islands = more_islands > 0 and more_islands or nil
      pw.unpowered = #unpowered > 0 and unpowered or nil
      pw.unpowered_count = unpowered_count > #unpowered and unpowered_count or nil
      if next(pw) then out.power = pw end
    end

    -- Reach: from where the character stands, then spots that reach the rest.
    local reach = not on_platform and character and try(function() return p.build_distance end)
    if reach and (manual or plan.standing) then
      local targets = {}
      for _, r in ipairs(recs) do
        if r.pos and r.status ~= 'blocked' and r.status ~= 'exists' then targets[#targets+1] = {rec=r, pos=r.pos} end
      end
      for _, t in ipairs(plan.tiles or {}) do
        if manual then targets[#targets+1] = {tile=t, pos={x=math.floor(t.position.x)+0.5, y=math.floor(t.position.y)+0.5}} end
      end
      local here = p.position
      local far = {}
      for _, t in ipairs(targets) do
        local dd = dist(here, t.pos)
        if dd > reach then
          far[#far+1] = t
          if t.rec and manual then t.rec.reach = string.format('%.1f tiles from you, reach %g', dd, reach) end
        end
      end
      local st = {reach=reach, from_here=string.format('%d of %d in reach from %s', #targets-#far, #targets, at({x=math.floor(here.x*10+0.5)/10, y=math.floor(here.y*10+0.5)/10}))}
      if #far > 0 then
        -- Greedy cover: around the first unreached placement, the free spot
        -- (off every planned footprint, not on a belt, where a character fits)
        -- that reaches the most unreached placements. Bounded: at most
        -- MAX_SPOTS spots and MAX_SPOTS + 8 placements looked at.
        local r = reach-0.5
        local cname = character.name or 'character'
        local cells = grid(8)
        for _, t in ipairs(far) do cells.add(t, t.pos) end
        local done = {}
        local function free(c)
          for x = math.floor(c.x-0.3), math.floor(c.x+0.3) do
            for y = math.floor(c.y-0.3), math.floor(c.y+0.3) do
              for _, rec in ipairs(occupied[key(x, y)] or {}) do
                local b = rec.box
                if c.x > b.left_top.x-0.3 and c.x < b.right_bottom.x+0.3 and c.y > b.left_top.y-0.3 and c.y < b.right_bottom.y+0.3 then return false end
              end
            end
          end
          local belts = try(function() return s.count_entities_filtered{area={{c.x-0.4, c.y-0.4}, {c.x+0.4, c.y+0.4}}, type={'transport-belt', 'underground-belt', 'splitter'}, limit=1} end)
          if belts and belts > 0 then return false end
          return try(function() return s.can_place_entity{name=cname, position=c, force=force} end) == true
        end
        local function count(c)
          local n = 0
          cells.near(c, r, function(t) if not done[t] and dist(c, t.pos) <= r then n = n + 1 end end)
          return n
        end
        local spots, stuck, looked, nextu = {}, {}, 0, 1
        while #spots < MAX_SPOTS and looked < MAX_SPOTS+8 do
          while far[nextu] and done[far[nextu]] do nextu = nextu + 1 end
          local u = far[nextu]
          if not u then break end
          looked = looked + 1
          local cands = {}
          for _, rad in ipairs({r-0.5, r/2, 0}) do
            for k = 0, (rad > 0 and 15 or 0) do
              local a = k*math.pi/8
              local c = {x=math.floor(u.pos.x+math.cos(a)*rad)+0.5, y=math.floor(u.pos.y+math.sin(a)*rad)+0.5}
              if dist(c, u.pos) <= r then cands[#cands+1] = {c=c, n=count(c), w=dist(c, here)} end
            end
          end
          table.sort(cands, function(a, b) if a.n ~= b.n then return a.n > b.n end return a.w < b.w end)
          local chosen
          for j = 1, math.min(#cands, 24) do
            if free(cands[j].c) then chosen = cands[j].c; break end
          end
          if not chosen then stuck[#stuck+1] = u; done[u] = true
          else
            local cover = {}
            cells.near(chosen, r, function(t) if not done[t] and dist(chosen, t.pos) <= r then done[t] = true; cover[#cover+1] = t end end)
            spots[#spots+1] = {at=chosen, cover=cover}
          end
        end
        local left = 0
        for _, t in ipairs(far) do if not done[t] then left = left + 1 end end
        -- Visit order: nearest first from where the character stands.
        local ordered, pos = {}, here
        while #spots > 0 do
          local bi, bd2
          for i, sp in ipairs(spots) do local dd = dist(pos, sp.at); if not bd2 or dd < bd2 then bi, bd2 = i, dd end end
          local sp = table.remove(spots, bi)
          ordered[#ordered+1] = sp; pos = sp.at
        end
        st.spots = {}
        for _, sp in ipairs(ordered) do
          local idx, tiles, copies = {}, 0, false
          for _, t in ipairs(sp.cover) do
            if t.rec then idx[#idx+1] = t.rec.index; copies = copies or t.rec.copy ~= nil else tiles = tiles + 1 end
          end
          local what = #idx > 0 and (copies and #idx..' entries' or '#'..runs(idx)) or ''
          st.spots[#st.spots+1] = {at=sp.at, reaches=what..(tiles > 0 and string.format('%s%d tiles', #idx > 0 and ' + ' or '', tiles) or '')}
        end
        if left > 0 then st.more = string.format('%d placements out of reach past these spots', left) end
        if #stuck > 0 then
          local idx = {}
          for _, t in ipairs(stuck) do if t.rec then idx[#idx+1] = t.rec.index end end
          st.no_spot = string.format('no free spot within reach of %s', #idx > 0 and '#'..runs(idx) or #stuck..' tiles')
        end
      end
      if #targets > 0 then out.standing = st end
    end

    -- Whether the plan closes the character in where it stands (Gemini,
    -- shift09: a placement trapped the character in a closed box): its area
    -- flooded with the character's box (pathing.lua) with the planned
    -- footprints that stop a character, and the entries that each fill the
    -- last gap out. Planned tiles a character walks on open water.
    if character and not on_platform and api.pathing then
      local here, half = p.position, api.pathing.half(character)
      local boxes, open, near = {}, nil, {}
      for _, r in ipairs(recs) do
        local b = r.box
        if b and r.mask and r.mask.player and r.status ~= 'blocked' and r.status ~= 'exists'
          and b.right_bottom.x > here.x-16 and b.left_top.x < here.x+16 and b.right_bottom.y > here.y-16 and b.left_top.y < here.y+16 then
          near[#near+1] = r
          -- Our gates open for the character (a gate's own box is no wall).
          if r.proto.type ~= 'gate' then
            boxes[#boxes+1] = {b.left_top.x, b.left_top.y, b.right_bottom.x, b.right_bottom.y, r.name, r, base=true}
          end
        end
      end
      for _, piece in ipairs(M.joined_pieces(s, force, near)) do boxes[#boxes+1] = piece end
      for _, t in pairs(planned) do
        if not t.layers.player then open = open or {}; open[t.x..','..t.y] = true end
      end
      local ok, res = false, nil
      if #boxes > 0 then
        ok, res = pcall(api.pathing.closes_in, s, here, half, boxes, {ignore=character, force=force, open=open, search=6})
      end
      if ok and res then
        local function entry(b)
          local r = b[6]
          return string.format('#%s %s %s', r.copy and (r.copy..'.'..r.index) or r.index, r.name, at(r.pos))
        end
        local where = at({x=math.floor(here.x*10+0.5)/10, y=math.floor(here.y*10+0.5)/10})
        if res.already then
          out.closed_in = string.format('the character is closed in already where it stands %s: %s', where, api.pathing.area_text(res.region, half))
        else
          local list = {}
          for _, b in ipairs(#res.gaps > 0 and res.gaps or res.around) do if #list < 6 then list[#list+1] = entry(b) end end
          local more = #res.around > #list and string.format(' (of %d planned entries around it)', #res.around) or ''
          local what = #res.gaps == 1 and 'the last gap out is where '..list[1]..' goes'
            or #res.gaps > 1 and 'without any one of '..table.concat(list, ', ')..more..' a gap out stays'
            or 'the planned entries around it are '..table.concat(list, ', ')..more
          out.closes_in = string.format('placed, these close the character in where it stands %s: %s; %s', where, what,
            api.pathing.area_text(res.region, half))
        end
      end
    end

    -- A build batch stops at its first failing entry: which one, and why.
    if manual then
      local first, why
      local function fail(index, text) if index and (not first or index < first) then first, why = index, text end end
      for _, r in ipairs(recs) do
        if r.status == 'blocked' then fail(r.index, r.why or 'blocked')
        elseif r.status == 'exists' then fail(r.index, 'target already contains this entity')
        elseif r.reach then fail(r.index, 'out of reach: '..r.reach)
        elseif r.late then fail(r.index, string.format('its tiles come from entry #%d', r.late)) end
      end
      for index, b in pairs(brush) do
        if b.laid == 0 then fail(index, 'no tile of its brush can be laid there'..(b.why and ': '..b.why or '')) end
      end
      if first then counts.fail_first, counts.fail_why = first, why end
    end

    -- Items the plan uses and what the character (on a platform: the hub) holds.
    local items, order = {}, {}
    local function add(name, n)
      if not name then return end
      if not items[name] then order[#order+1] = name end
      items[name] = (items[name] or 0) + n
    end
    for _, r in ipairs(recs) do
      if r.proto and r.status ~= 'blocked' and r.status ~= 'exists' then
        local it = r.item or try(function() return r.proto.items_to_place_this[1] end)
        -- A build names its item: the count is the prototype's for that item
        -- (a curved rail takes 3 rails).
        if type(it) == 'string' then
          for _, st in ipairs(try(function() return r.proto.items_to_place_this end) or {}) do
            if st.name == it then it = st; break end
          end
        end
        if type(it) == 'table' then add(it.name, it.count or 1) else add(it, 1) end
      end
    end
    for _, n in ipairs(need_list) do add(n.item:match('^(%S+)'), 1) end
    -- One explosive item per cliff the plan marks (cliff-explosives on every planet's cliffs).
    local ncliffs, by_item = 0, {}
    for _, c in pairs(cliffs) do ncliffs = ncliffs + 1; by_item[c.item] = (by_item[c.item] or 0) + 1; add(c.item, 1) end
    for _, t in pairs(planned) do
      local proto = prototypes.tile[t.name]
      add(t.item or try(function() return proto.items_to_place_this[1].name end), 1)
    end
    if #order > 0 then
      local inv = try(function()
        if on_platform then return s.platform.hub.get_inventory(defines.inventory.hub_main) end
        return p.get_main_inventory()
      end)
      out.items = items
      if inv then
        local missing
        for _, name in ipairs(order) do
          local have = try(function() return inv.get_item_count(name) end) or 0
          local craft = manual and api.crafting_count and try(function() return api.crafting_count(p, name) end) or 0
          if have+craft < items[name] then
            missing = missing or {}
            missing[name] = items[name]-have-craft
          end
        end
        out.missing = missing
        out.missing_from = missing and (on_platform and 'the hub' or 'your inventory'..(manual and ' and hand-craft queue' or '')) or nil
      end
      if ncliffs > 0 then
        local parts = {}
        for item, n in pairs(by_item) do
          local have = inv and try(function() return inv.get_item_count(item) end) or 0
          parts[#parts+1] = string.format('%s %d, you hold %d', item, n, have)
        end
        table.sort(parts)
        out.cliffs = string.format('%d placeable entr%s stand%s over %d cliff%s: placing marks %s, and a marked cliff goes only with one explosive (construction robots bring it): %s',
          over_cliffs, over_cliffs == 1 and 'y' or 'ies', over_cliffs == 1 and 's' or '', ncliffs, ncliffs == 1 and '' or 's',
          ncliffs == 1 and 'it' or 'them', table.concat(parts, '; '))
        -- No construction robot reaches them (Sol 15:41: a nutrient belt over cliffs on Gleba with no robots there):
        -- the cliffs to clear by hand with clear_cliffs, which throws the explosives as a player does.
        local robots, at = 0, {}
        for _, c in pairs(cliffs) do
          if c.e.valid then
            if #at < 8 then at[#at+1] = {x=c.e.position.x, y=c.e.position.y} end
            local net = try(function() return s.find_logistic_network_by_position(c.e.position, p.force) end)
            robots = robots + (net and try(function() return net.available_construction_robots end) or 0)
          end
        end
        local own = try(function() return p.character and p.character.logistic_network end)
        robots = robots + (own and try(function() return own.available_construction_robots end) or 0)
        if robots == 0 and #at > 0 then
          local list = {}
          for _, q in ipairs(at) do list[#list+1] = string.format('{"x":%g,"y":%g}', q.x, q.y) end
          out.cliffs = out.cliffs .. string.format('; no construction robots reach %s here: clear %s by hand first, clear_cliffs {"positions":[%s]} (throws the explosives from within their range, walking there)',
            ncliffs == 1 and 'it' or 'them', ncliffs == 1 and 'it' or 'them', table.concat(list, ','))
          out.cliffs_by_hand = at
        end
      end
    end

    -- Rows: every entity that is not plainly placeable (all with details).
    local rows = {}
    for _, r in ipairs(recs) do
      -- A paste lays its tiles and entities together; the other calls go in order.
      local problem = r.status == 'blocked' or r.status == 'needs_tiles' or r.reach ~= nil
        or ((r.status == 'exists' or r.status == 'after_tiles') and kind ~= 'paste')
      if problem then nproblems = nproblems + 1 end
      if (problem or plan.details) and #rows < (plan.details and 256 or MAX_ROWS) then
        local row = {index=r.copy and (r.copy..'.'..r.index) or r.index, name=r.name, position=r.pos or nil,
          direction=r.dir ~= 0 and NAMES[r.dir] or nil, status=r.status, why=r.why or r.note, reach=r.reach}
        if r.why and r.note then row.note = r.note end
        if plan.details and r.box then
          local x0, y0, x1, y1 = span(r.box)
          row.footprint = string.format('%d,%d..%d,%d', x0, y0, x1, y1)
        end
        if r.asked then row.asked = r.asked end
        rows[#rows+1] = row
      end
    end
    out.entities = #rows > 0 and rows or nil
    if nproblems > #rows and not plan.details then out.more_problems = nproblems-#rows end
    -- A paste over an entity with requests (a hub, requester chests, landing
    -- pads): its requests stay, and the blueprint's own are not applied (keep.lua).
    if kind == 'paste' and api.keep then
      local lines = {}
      for _, r in ipairs(recs) do
        if r.pos and #lines < 16 then
          local line = try(function() return api.keep.plan(s, r.name, r.pos, r.requests, r.construction) end)
          if line then lines[#lines+1] = line end
        end
      end
      out.requests_kept = #lines > 0 and lines or nil
    end
    -- Each planned inserter: what stands on its pickup and drop points (built,
    -- planned in this call, or a ghost) and whether it has a target there
    -- (targets.lua; Astra's bypass inserter that reached no crusher).
    if api.targets then
      local function planned(pos)
        for _, o in ipairs(occupied[key(math.floor(pos.x), math.floor(pos.y))] or {}) do
          local b = o.box
          if pos.x >= b.left_top.x and pos.x <= b.right_bottom.x and pos.y >= b.left_top.y and pos.y <= b.right_bottom.y then
            return {name=o.name, position=o.pos, type=o.proto.type}
          end
        end
      end
      local list, without = {}, 0
      for _, r in ipairs(recs) do
        if r.proto and r.pos and r.proto.type == 'inserter' then
          local t = try(function() return api.targets.plan(s, r.proto, r.pos, r.dir, planned) end)
          if t then
            if t.missing then without = without + 1 end
            if #list < (plan.details and 256 or MAX_INSERTERS) then
              list[#list+1] = {index=r.copy and (r.copy..'.'..r.index) or r.index, name=r.name, position=r.pos,
                direction=r.dir ~= 0 and NAMES[r.dir] or nil, pickup=t.pickup, drop=t.drop, missing=t.missing}
            end
          end
        end
      end
      out.inserters = #list > 0 and list or nil
      out.inserters_without_target = without > 0 and without or nil
    end
    local function idx(r) return r.copy and (r.copy..'.'..r.index) or r.index end
    -- Fluid and heat connections of the plan (Sol, shift13 16:50: Gleba's heat power planned by footprints, the
    -- joins unknown until it was built): for each planned boiler, heat exchanger, turbine, reactor, heating tower,
    -- pump, tank, and a machine given a fluid recipe, each connection point: the tile it joins and what is there to
    -- join: another entry of the plan or a building or ghost of ours with a connection back, something without
    -- one, or nothing. Pipes and heat pipes give only their joins to what is already built. Fluid points as the
    -- ports read gives them (ports.lua), heat points from the prototype (M.heat_points).
    local CONNECTS = {boiler=true, generator=true, reactor=true, ['heat-pipe']=true, ['heat-interface']=true, pipe=true,
      ['pipe-to-ground']=true, pump=true, ['offshore-pump']=true, ['storage-tank']=true, ['fusion-reactor']=true,
      ['fusion-generator']=true}
    local LINES = {pipe=true, ['pipe-to-ground']=true, ['heat-pipe']=true}
    local function tile_of(p0) return math.floor(p0.x), math.floor(p0.y) end
    local by_tile = {}   -- 'f'|'h' .. tile key -> {{r, c}}
    local with = {}
    -- (a flipped paste: the game turns a storage tank or a fusion machine its own way, which the plan's directions
    -- may not match)
    if plan.flipped then out.connections_note = 'not read for a flipped paste' end
    for _, r in ipairs(plan.flipped and {} or recs) do
      local t = r.proto and r.proto.type
      if t and r.pos and r.status ~= 'blocked' and r.status ~= 'exists' and (CONNECTS[t] or (r.recipe and (t == 'assembling-machine' or t == 'furnace'))) then
        local e0 = {prototype=r.proto, position=r.pos, direction=r.dir}
        local fl = {}
        for _, c in ipairs(api.fluid_rows and try(function() return api.fluid_rows(e0, r.recipe) end) or {}) do
          local x, y = tile_of(c.at)
          local tx, ty = tile_of(c.joins)
          fl[#fl+1] = {x=x, y=y, tx=tx, ty=ty, dir=c.direction, flow=c.flow, fluid=c.fluid, kind=c.kind or 'normal', reach=c.underground_reach}
        end
        local ht = M.heat_points(r.proto, r.pos, r.dir)
        if #fl > 0 or #ht > 0 then
          r.fl, r.ht = fl, ht
          with[#with+1] = r
          for _, c in ipairs(fl) do local k = 'f'..key(c.x, c.y); by_tile[k] = by_tile[k] or {}; table.insert(by_tile[k], {r=r, c=c}) end
          for _, c in ipairs(ht) do local k = 'h'..key(c.x, c.y); by_tile[k] = by_tile[k] or {}; table.insert(by_tile[k], {r=r, c=c}) end
        end
      end
    end
    if #with > 0 then
      local OPP = {north='south', south='north', east='west', west='east'}
      -- What answers connection c of planned r: (text, joined, built): a planned entry with a connection back, else
      -- an entity of ours there, else a planned entry without one.
      local function partner(r, c, kind)
        for _, q in ipairs(by_tile[kind..key(c.tx, c.ty)] or {}) do
          local d = q.c
          if q.r ~= r and d.tx == c.x and d.ty == c.y and (kind == 'h' or d.kind == 'normal') then
            return 'planned #'..tostring(idx(q.r))..' '..q.r.name, true
          end
        end
        local other
        for _, o in pairs(try(function() return s.find_entities_filtered{area={{c.tx+0.1, c.ty+0.1}, {c.tx+0.9, c.ty+0.9}}, force=force} end) or {}) do
          if o.valid and o.type ~= 'character' then
            local label = (o.type == 'entity-ghost' and o.ghost_name..' ghost' or o.name)..' '..at(o.position)
            local joined = false
            if kind == 'h' then
              local proto = o.type == 'entity-ghost' and o.ghost_prototype or o.prototype
              for _, h in ipairs(M.heat_points(proto, o.position, o.direction)) do
                if h.x == c.tx and h.y == c.ty and h.tx == c.x and h.ty == c.y then joined = true end
              end
            else
              for _, oc in ipairs(api.fluid_connections and try(function() return api.fluid_connections(o) end) or {}) do
                if (oc.kind or 'normal') == 'normal' and oc.x == c.tx and oc.y == c.ty and oc.tx == c.x and oc.ty == c.y then joined = true end
              end
            end
            if joined then return label, true, true end
            other = other or label
          end
        end
        if other then return 'faces '..other..' (no connection back)' end
        for _, q in ipairs(occupied[key(c.tx, c.ty)] or {}) do
          if q ~= r then
            return string.format('faces planned #%s %s (%s)', tostring(idx(q)), q.name, q.status == 'blocked' and 'blocked' or 'no connection back')
          end
        end
        return 'nothing there'
      end
      -- A pipe-to-ground's underground end: the nearest one facing back within its reach, planned or built.
      local function under(r, c)
        local d = STEP[({north=0, east=4, south=8, west=12})[c.dir] or 0]
        for n = 1, c.reach or 10 do
          local x, y = c.x + d[1] * n, c.y + d[2] * n
          for _, q in ipairs(by_tile['f'..key(x, y)] or {}) do
            if q.r ~= r and q.c.kind == 'underground' and q.c.dir == OPP[c.dir] then return 'underground to planned #'..tostring(idx(q.r))..' '..q.r.name..' '..tile_text(x, y) end
          end
          for _, o in pairs(try(function() return s.find_entities_filtered{area={{x+0.1, y+0.1}, {x+0.9, y+0.9}}, force=force} end) or {}) do
            for _, oc in ipairs(o.valid and api.fluid_connections and try(function() return api.fluid_connections(o) end) or {}) do
              if oc.kind == 'underground' and oc.x == x and oc.y == y then
                return 'underground to '..(o.type == 'entity-ghost' and o.ghost_name..' ghost' or o.name)..' '..at(o.position)
              end
            end
          end
        end
        return string.format('underground: no pipe-to-ground facing back within %d tiles', c.reach or 10)
      end
      local rows, open = {}, 0
      for _, r in ipairs(with) do
        local line = LINES[r.proto.type]
        local fluid, heat = {}, {}
        for _, c in ipairs(r.fl) do
          local there, joined, built
          if c.kind == 'underground' then there = under(r, c); joined = there:find('^underground to') ~= nil
          else there, joined, built = partner(r, c, 'f') end
          if not line or built or (c.kind == 'underground' and not there:find('^underground to planned')) then
            local what = (c.flow or 'fluid')..(c.fluid and c.fluid ~= 'none' and ' '..c.fluid or '')
            fluid[#fluid+1] = string.format('%s %s at %s: %s', what, c.dir or '?', tile_text(c.tx, c.ty), there)
          end
          if not line and not joined then open = open + 1 end
        end
        for _, c in ipairs(r.ht) do
          local there, joined, built = partner(r, c, 'h')
          if not line or built then heat[#heat+1] = string.format('heat %s at %s: %s', NAMES[c.dir] or '?', tile_text(c.tx, c.ty), there) end
          if not line and not joined then open = open + 1 end
        end
        if (#fluid > 0 or #heat > 0) and #rows < (plan.details and 256 or MAX_INSERTERS) then
          rows[#rows+1] = {index=idx(r), name=r.name, position=r.pos, direction=r.dir ~= 0 and NAMES[r.dir] or nil,
            fluid=#fluid > 0 and fluid or nil, heat=#heat > 0 and heat or nil}
        end
      end
      out.connections = #rows > 0 and rows or nil
      out.connections_open = open > 0 and open or nil
    end
    -- Logistic chests no roboport's logistic area covers, roboports planned in
    -- this call counting (networks.lua; Sonnet, shift10).
    if api.coverage and not on_platform then
      local ports = {}
      for _, r in ipairs(recs) do
        if r.proto and r.pos and r.proto.type == 'roboport' and r.status ~= 'blocked' then
          ports[#ports+1] = {x=r.pos.x, y=r.pos.y, r=try(function() return r.proto.logistic_radius end) or 0}
        end
      end
      local lines = {}
      for _, r in ipairs(recs) do
        if r.proto and r.pos and r.proto.type == 'logistic-container' and r.status ~= 'blocked' and r.status ~= 'exists' and #lines < 16 then
          local line = try(function() return api.coverage(s, force, r.pos, ports) end)
          if line then lines[#lines+1] = string.format('#%s %s %s: %s', idx(r), r.name, at(r.pos), line) end
        end
      end
      out.outside_logistic_coverage = #lines > 0 and lines or nil
    end
    -- Underground entrances fed from the side (sidefeed.lua; Sol, shift10): a
    -- planned inserter dropping onto one, a planned belt running into one's
    -- side, a planned entrance beside built inserters and belts. A planned
    -- underground's end: its type, else as the call places it (a build: an
    -- output when the nearest one of its kind upstream within reach is an
    -- entrance; a ghost: an entrance).
    if api.sidefeed and api.targets then
      local STEP4 = {[0]={0, -1}, [4]={1, 0}, [8]={0, 1}, [12]={-1, 0}}
      local lines, seen = {}, {}
      local function add(l) if l and not seen[l] and #lines < 8 then seen[l] = true; lines[#lines+1] = l end end
      local ugs = {}
      for _, r in ipairs(recs) do
        if r.proto and r.pos and r.proto.type == 'underground-belt' and r.status ~= 'blocked' then ugs[key(math.floor(r.pos.x), math.floor(r.pos.y))] = r end
      end
      local kinds = {}
      local function kind_of(r, depth)
        if r.ug_type == 'input' or r.ug_type == 'output' then return r.ug_type end
        if kind ~= 'build' then return 'input' end
        if kinds[r] then return kinds[r] end
        local back = STEP4[(r.dir+8)%16]
        local reach = try(function() return r.proto.max_underground_distance end) or 0
        local found = 'input'
        for k = 1, back and reach or 0 do
          local x, y = math.floor(r.pos.x)+back[1]*k, math.floor(r.pos.y)+back[2]*k
          local o = ugs[key(x, y)]
          local up
          if o and o.name == r.name and o.dir == r.dir then up = (depth or 0) < 8 and kind_of(o, (depth or 0)+1) or 'input'
          elseif not o then
            local e = try(function() return s.find_entities_filtered{position={x=x+0.5, y=y+0.5}, name=r.name, limit=1}[1] end)
            if e and e.direction == r.dir then up = try(function() return e.belt_to_ground_type end) end
          end
          if up then found = up == 'input' and 'output' or 'input'; break end
        end
        kinds[r] = found
        return found
      end
      local function ug_at(pos)
        local r = ugs[key(math.floor(pos.x), math.floor(pos.y))]
        if r then return {name=r.name, position=r.pos, direction=r.dir, kind=kind_of(r)} end
        local e = try(function() return s.find_entities_filtered{position=pos, type='underground-belt', limit=1}[1] end)
        if e then return {name=e.name, position=e.position, direction=e.direction, kind=try(function() return e.belt_to_ground_type end)} end
      end
      for _, r in ipairs(recs) do
        local t = r.proto and r.pos and r.status ~= 'blocked' and r.proto.type
        if t == 'inserter' then
          local _, drop = api.targets.points(r.proto, r.pos, r.dir)
          local ug = drop and ug_at(drop)
          local line = ug and api.sidefeed.inserter(r.name, r.pos, drop, ug)
          if line then add('#'..idx(r)..' '..line) end
        elseif t == 'transport-belt' then
          local st = STEP4[r.dir%16]
          local ug = st and ug_at({x=math.floor(r.pos.x)+st[1]+0.5, y=math.floor(r.pos.y)+st[2]+0.5})
          local line = ug and api.sidefeed.belt(r.name, r.pos, r.dir, ug)
          if line then add('#'..idx(r)..' '..line) end
        elseif t == 'underground-belt' and kind_of(r) == 'input' then
          local ug = {name=r.name, position=r.pos, direction=r.dir, kind='input'}
          local x, y = r.pos.x, r.pos.y
          for _, i in ipairs(try(function() return s.find_entities_filtered{area={{x-3.5, y-3.5}, {x+3.5, y+3.5}}, type='inserter', force=force} end) or {}) do
            local drop = try(function() return i.drop_position end)
            if drop then add(api.sidefeed.inserter(i.name, i.position, drop, ug)) end
          end
          for _, d in pairs(STEP4) do
            local b = try(function() return s.find_entities_filtered{position={x=x+d[1], y=y+d[2]}, type='transport-belt', limit=1}[1] end)
            if b then add(api.sidefeed.belt(b.name, b.position, b.direction, ug)) end
          end
        end
      end
      out.underground_side_feed = #lines > 0 and lines or nil
    end
    local n = #recs
    local parts = {}
    for _, k in ipairs({'ok', 'after_tiles', 'after_rails', 'needs_tiles', 'exists', 'blocked'}) do
      if (counts[k] or 0) > 0 then parts[#parts+1] = counts[k]..' '..({ok='placeable', after_tiles='placeable once the tiles under them are laid',
        after_rails='with the plan\'s rails', needs_tiles='need tiles first', exists='already there', blocked='blocked'})[k] end
    end
    if manual then
      local farn = 0
      for _, r in ipairs(recs) do if r.reach then farn = farn + 1 end end
      if farn > 0 then parts[#parts+1] = farn..' out of reach from here' end
    end
    out.checked = n
    out.summary = n > 0 and (table.concat(parts, ', ')..' (of '..n..')'..(over_cliffs > 0 and string.format('; %d over cliffs', over_cliffs) or '')) or nil
    return out, recs, counts
  end
  return M
end
