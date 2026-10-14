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
  M.ACTIONS = {place_ghosts=true, paste=true, blueprint_place=true, build=true}
  local MAX_ROWS, MAX_LISTED, HOLE_LIMIT, FLOOD_BUDGET, MAX_SPOTS = 30, 200, 1024, 20000, 8
  local MAX_INSERTERS = 64
  local DIRS = {{1,0},{-1,0},{0,1},{0,-1}}
  local NAMES = {[0]='north', [4]='east', [8]='south', [12]='west'}
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
  function M.footprint(proto, pos, dir)
    local b = proto.collision_box or {left_top={x=-0.4, y=-0.4}, right_bottom={x=0.4, y=0.4}}
    return api.placewhy.box_at(b, pos, dir or 0)
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
    if lo then
      local m = 40
      for _, g in pairs(s.find_entities_filtered{area={left_top={x=lo.x-m, y=lo.y-m}, right_bottom={x=hi.x+m, y=hi.y+m}}, type='tile-ghost', force=force, limit=4096}) do
        local proto = g.valid and prototypes.tile[g.ghost_name]
        if proto then
          local x, y = math.floor(g.position.x), math.floor(g.position.y)
          pending[key(x, y)] = {name=g.ghost_name, layers=layers(proto.collision_mask), x=x, y=y}
        end
      end
    end
    -- Planned tiles: each must go on what is there now. A build entry whose
    -- brush lays no tile at all fails (build_tile).
    local tile_rows, tiles_planned, tiles_already, tiles_refused = {}, 0, 0, 0
    local brush = {} -- build entry index -> {laid, total}
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
        if item and not M.placeable_on(item, here.name) then why = string.format('%s cannot go on %s', item, here.name) end
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
    local function need(x, y, item, why)
      local k = key(x, y)
      if needed[k] then return end
      needed[k] = {x=x, y=y, item=item, why=why}
      need_list[#need_list+1] = needed[k]
    end
    for _, e in ipairs(plan.entities or {}) do
      local proto = prototypes.entity[e.name or '']
      local rec = {index=e.index, copy=e.copy, name=e.name, dir=e.direction or 0, quality=e.quality, item=e.item, requests=e.requests}
      recs[#recs+1] = rec
      local reasons = {}
      if not proto then
        rec.status = 'blocked'; reasons[1] = 'not an entity: '..tostring(e.name)
      else
        rec.proto = proto
        rec.mask = layers(proto.collision_mask)
        rec.pos = M.snap(proto, e.position, rec.dir)
        if math.abs(rec.pos.x-e.position.x) > 0.01 or math.abs(rec.pos.y-e.position.y) > 0.01 then rec.asked = e.position end
        rec.box = M.footprint(proto, rec.pos, rec.dir)
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
                if not hit and o ~= rec and not (rail and RAILS[o.proto.type]) and collide(mask, o.mask) and overlap(o.box, rec.box) then hit = o end
              end
            end
          end
          if hit then
            reasons[#reasons+1] = string.format('collides with planned #%s %s at %s', hit.copy and (hit.copy..'.'..hit.index) or tostring(hit.index), hit.name, at(hit.pos))
          end
          -- What stands in the footprint now.
          local blockers, marked, ghosts, same, mine = {}, {}, {}, nil, false
          for _, o in pairs(s.find_entities_filtered{area=rec.box}) do
            if o.valid then
              local t = o.type
              if t == 'entity-ghost' then
                if o.ghost_name == e.name and math.abs(o.position.x-rec.pos.x) < 0.01 and math.abs(o.position.y-rec.pos.y) < 0.01 then same = same or o
                elseif overlap(o.bounding_box or rec.box, rec.box) then ghosts[#ghosts+1] = 'ghost '..o.ghost_name..' '..at(o.position) end
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
                    elseif #blockers < 4 then
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
                if collide(mask, t.layers) then
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
          if engine == true and not same then
            if #blockers > 0 then rec.note = 'replaces '..table.concat(blockers, ', ') end
          elseif #blockers > 0 then reasons[#reasons+1] = 'blocked by '..table.concat(blockers, ', ') end
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
            rec.note = string.format('stands on %d %s tile%s: needs %s first%s', #tile_need, tile_need[1].tile, #tile_need == 1 and '' or 's', table.concat(parts, ', '),
              engine == true and not manual and ' (its ghost goes there now; nothing builds it before that)' or '')
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
          if not seen[sk] and not filled[sk] and empty(sx, sy) then
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
                    elseif t.layers.empty_space then seen[nk] = fid; q[#q+1] = {nx, ny} end
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
        holes=holes > 0 and holes or nil, planned=tiles_planned > 0 and tiles_planned or nil,
        already=tiles_already > 0 and tiles_already or nil, refused=tiles_refused > 0 and tiles_refused or nil,
        refused_rows=#tile_rows > 0 and tile_rows or nil}
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
      -- planned poles and pole ghosts join what lies within reach.
      local parent = {}
      local function find(i) while parent[i] ~= i do parent[i] = parent[parent[i]]; i = parent[i] end return i end
      local function union(a, b) a, b = find(a), find(b); if a ~= b then parent[a] = b end end
      local by_network, maxreach, maxsupply = {}, 1, 0
      local poles = grid(16)
      for i, n in ipairs(nodes) do
        parent[i] = i
        if n.network then
          if by_network[n.network] then union(i, by_network[n.network]) else by_network[n.network] = i end
        end
        maxreach = math.max(maxreach, n.reach); maxsupply = math.max(maxsupply, n.supply)
        poles.add(i, n.pos)
      end
      for i, a in ipairs(nodes) do
        if a.planned or a.ghost then
          poles.near(a.pos, a.reach, function(j)
            local b = nodes[j]
            if j ~= i and dist(a.pos, b.pos) <= math.min(a.reach, b.reach)+1e-6 then union(i, j) end
          end)
        end
      end
      local live = {} -- root -> true when a built pole is in the group
      for i, n in ipairs(nodes) do if n.entity then live[find(i)] = true end end
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
        local by_live, by_island
        local b = r.box
        local half = math.max(b.right_bottom.x-b.left_top.x, b.right_bottom.y-b.left_top.y)/2
        poles.near(r.pos, maxsupply+half+1, function(i)
          local n = nodes[i]
          if covers(n, r) then
            if live[find(i)] then by_live = true else by_island = by_island or find(i) end
          end
        end)
        if not by_live and by_island and groups[by_island] and #groups[by_island].poles > 0 then
          table.insert(groups[by_island].machines, r)
        elseif not by_live then
          unpowered_count = unpowered_count + 1
          if #unpowered < 20 then
            local why
            if by_island then why = 'only pole ghosts with no wire path to a built pole cover it'
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
      local reached = {}
      for i, n in ipairs(nodes) do
        local root = find(i)
        if n.planned and live[root] then reached[root] = reached[root] or {}; table.insert(reached[root], n) end
      end
      local connected = {}
      for root, list in pairs(reached) do
        -- Per built network in the group, its pole nearest the planned ones.
        local best, order2 = {}, {}
        for _, pl in ipairs(list) do
          poles.near(pl.pos, maxreach, function(i)
            local n = nodes[i]
            if n.entity and n.network and find(i) == root then
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
          or string.format('%s reach%s the built network of %s', label(list), one and 'es' or '', r[1] or 'a built pole (through pole ghosts)')
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
        if b.laid == 0 then fail(index, 'no tile of its brush can be laid there') end
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
        if type(it) == 'table' then add(it.name, it.count or 1) else add(it, 1) end
      end
    end
    for _, n in ipairs(need_list) do add(n.item:match('^(%S+)'), 1) end
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
          local line = try(function() return api.keep.plan(s, r.name, r.pos, r.requests) end)
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
    out.summary = n > 0 and (table.concat(parts, ', ')..' (of '..n..')') or nil
    return out, recs, counts
  end
  return M
end
