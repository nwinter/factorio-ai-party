-- Why a ghost was not placed, and how a built entity differs from the
-- blueprint that expected it (blueprints.lua paste, runtime.lua place_ghosts).
-- Astra, shift06 14:26: a 50-entity Sunward paste returned count 0 and
-- existing_entities 37 and nothing about the other 13 "on verified empty
-- floor": asteroid collectors have tile_buildability_rules (rear rows on
-- foundation, the front row and the tiles ahead empty space), and a spot that
-- breaks them is skipped by the game without a word.
-- The factory is pure so the same module can be bundled into a hot reload.
return function(api)
  local M = {}
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local NAMES = {[0]='north', [4]='east', [8]='south', [12]='west'}
  function M.direction_name(d) return NAMES[(d or 0) % 16] or tostring(d) end
  -- A blueprint offset turned with the paste: quarter turns clockwise (16-way
  -- directions, 4 a quarter), as east turns north's (0,-1) into (1,0).
  function M.rotate(x, y, dir)
    for _ = 1, math.floor(((dir or 0) % 16) / 4) do x, y = -y, x end
    return x, y
  end
  -- A prototype-relative box at a position, turned with the entity.
  function M.box_at(b, pos, dir)
    local x1, y1 = M.rotate(b.left_top.x, b.left_top.y, dir)
    local x2, y2 = M.rotate(b.right_bottom.x, b.right_bottom.y, dir)
    return {left_top={x=pos.x+math.min(x1, x2), y=pos.y+math.min(y1, y2)},
      right_bottom={x=pos.x+math.max(x1, x2), y=pos.y+math.max(y1, y2)}}
  end
  -- Factorio 2.0.77 ramps use cardinal directions and their own two-tile grid.
  -- The runtime prototype supplies the generated collision box (not the data
  -- stage's smoke box). Keep diagnostics on the same centre as create_entity.
  function M.ramp_position(pos, dir)
    dir = math.floor((dir or 0) / 4) * 4
    local east = dir == 4 or dir == 12
    local function snap(v, odd) return math.floor((v + (odd and 0 or 1)) / 2) * 2 + (odd and 1 or 0) end
    return {x=snap(pos.x, not east), y=snap(pos.y, east)}, dir
  end
  -- All physical collisions in a ramp's footprint, without a row or search
  -- limit. The engine's area query handles rotated cliff boxes; testing their
  -- unrotated bounding_box again would introduce false positives. A mark is
  -- reported, never treated as an entity having disappeared.
  function M.ramp_collisions(surface, force, proto, pos, dir)
    if proto.type ~= 'rail-ramp' then return nil end
    pos, dir = M.ramp_position(pos, dir)
    local box = M.box_at(proto.collision_box, pos, dir)
    local mask = proto.collision_mask.layers
    local ignored = {resource=true, corpse=true, ['item-entity']=true, ['entity-ghost']=true, ['tile-ghost']=true,
      ['deconstructible-tile-proxy']=true, ['highlight-box']=true}
    local entities, rows, texts = {}, {}, {}
    local nearby = surface.find_entities_filtered{area=box}
    for _, e in pairs(nearby) do
      if e.valid and not ignored[e.type] then
        local other = try(function() return e.prototype.collision_mask end)
        local hits = false
        if other and not other.colliding_with_tiles_only then
          for layer in pairs(mask) do if other.layers[layer] then hits = true; break end end
        end
        if hits then entities[#entities+1] = e end
      end
    end
    table.sort(entities, function(a, b)
      if a.position.y ~= b.position.y then return a.position.y < b.position.y end
      if a.position.x ~= b.position.x then return a.position.x < b.position.x end
      return a.name < b.name
    end)
    for _, e in ipairs(entities) do
      local marked = try(function() return e.to_be_deconstructed(force) end) == true
      rows[#rows+1] = {name=e.name, type=e.type, position={x=e.position.x, y=e.position.y}, marked_for_deconstruction=marked}
      texts[#texts+1] = string.format('%s (%g,%g)%s%s', e.name, e.position.x, e.position.y,
        marked and ' (marked for deconstruction; still present)' or '', e.type == 'cliff' and ' (cliff explosives clear it)' or '')
    end
    return entities, rows, table.concat(texts, ', '), box, nearby
  end
  local function layers(mask)
    local out = {}
    for k in pairs(mask and mask.layers or {}) do out[#out+1] = k end
    table.sort(out)
    return out
  end
  local function touches(tile_layers, mask)
    for k in pairs(mask and mask.layers or {}) do if tile_layers[k] then return true end end
    return false
  end
  -- The first of the prototype's tile buildability rules the tiles at this
  -- spot break, as text; nil when they all hold. Second value: whether the
  -- prototype has rules at all (then its tiles are judged by them).
  -- get(x, y), when given, reads the tiles instead of the surface (a dry run
  -- with planned foundation, dryrun.lua).
  function M.tile_rules(surface, proto, pos, dir, get)
    local rules = try(function() return proto.tile_buildability_rules end)
    if type(rules) ~= 'table' or #rules == 0 then return nil, false end
    for i, rule in ipairs(rules) do
      local b = M.box_at(rule.area, pos, dir)
      local x0, x1 = math.floor(b.left_top.x + 0.01), math.ceil(b.right_bottom.x - 0.01) - 1
      local y0, y1 = math.floor(b.left_top.y + 0.01), math.ceil(b.right_bottom.y - 0.01) - 1
      local bad, n, first = 0, 0, nil
      for x = x0, x1 do
        for y = y0, y1 do
          n = n + 1
          local tile = get and get(x, y) or surface.get_tile(x, y)
          local tl = try(function() return tile.prototype.collision_mask.layers end) or {}
          if (rule.required_tiles and not touches(tl, rule.required_tiles))
            or (rule.colliding_tiles and touches(tl, rule.colliding_tiles)) then
            bad = bad + 1
            first = first or string.format('%s at (%d,%d)', try(function() return tile.name end) or '?', x, y)
          end
        end
      end
      if bad > 0 then
        local need, clear = layers(rule.required_tiles), layers(rule.colliding_tiles)
        local want = {}
        if #need > 0 then want[#want+1] = 'need '..table.concat(need, '/') end
        if #clear > 0 then want[#want+1] = 'must not be '..table.concat(clear, '/') end
        return string.format('breaks its tile rule %d facing %s: tiles x %d..%d, y %d..%d %s; %d of %d do not (%s)',
          i, M.direction_name(dir), x0, x1, y0, y1, table.concat(want, ' and '), bad, n, first), true
      end
    end
    return nil, true
  end

  -- (d20 batch52 J1, Sol shift46 10:31: three thruster ghosts on Limestone-spare-unbuilt over foundation tile ghosts,
  -- refused as "blocked by tile ghost", and their dry run failed reading a tile past the chunks the platform had.)
  -- 2.0.77 on the private copy, a thruster facing north: its ghost goes over foundation tile ghosts (the plain ghost
  -- check takes it, and a blueprint holding the foundation and the thruster places both); over bare empty space the
  -- forced check takes it and lays the foundation tile ghosts under it itself; built foundation takes it. Its second
  -- rule keeps the 90 tiles behind it empty space, and the check refuses while their chunks are not generated (a plain
  -- request generates them within a few ticks, as a player's view does).
  -- The tiles an entity's tile rules judge, as the game judges a ghost: tile ghosts count as laid. {ruled, broken (the
  -- first rule broken by a tile no tile item mends, as tile_rules says it), need [{x, y, item, tile}] (empty space where
  -- a rule wants ground: the tile item that makes it so, foundation on a platform), ungenerated {count, chunks [{x, y}],
  -- x0, x1, y0, y1} (tiles not judged: past the chunks the surface has generated)}. get(x, y), when given, reads a tile
  -- ({name, layers, ungenerated_chunk}, nil when the tile is invalid: past the chunks the surface has) instead of the
  -- surface and its tile ghosts. A tile of a chunk not generated yet is judged as read (the game judged those at y 100
  -- on the copy) and counted in ungenerated, for what a refusal says.
  -- The tile item that turns this tile into one the rule takes: placeable on it (its place_as_tile condition, as the
  -- game checks it) and unlocked; foundation first on a platform (the dry run's order, dryrun.lua).
  local RANK = {['space-platform-foundation']=1, landfill=2, ['ice-platform']=3, foundation=4}
  local tile_items
  local ground_items = {}
  local function ground_item(force, rule, tile_name, tl)
    if not tile_items then
      tile_items = {}
      for name, item in pairs(prototypes.item) do
        local pt = try(function() return item.place_as_tile_result end)
        local res = pt and try(function() return pt.result end)
        if res then
          local only
          for _, t in ipairs(pt.tile_condition or {}) do only = only or {}; only[type(t) == 'string' and t or t.name] = true end
          tile_items[#tile_items+1] = {item=name, tile=res.name, layers=try(function() return res.collision_mask.layers end) or {},
            condition=pt.condition, invert=pt.invert == true, only=only}
        end
      end
      table.sort(tile_items, function(a, b)
        local ra, rb = RANK[a.item] or 9, RANK[b.item] or 9
        if ra ~= rb then return ra < rb end
        return a.item < b.item
      end)
    end
    local key = tile_name .. '|' .. table.concat(layers(rule.required_tiles), ',') .. '|' .. table.concat(layers(rule.colliding_tiles), ',')
    if ground_items[key] == nil then
      ground_items[key] = false
      for _, ti in ipairs(tile_items) do
        local on = (not ti.only or ti.only[tile_name]) and touches(tl, ti.condition) == ti.invert
        if on and (not rule.required_tiles or touches(ti.layers, rule.required_tiles)) and not (rule.colliding_tiles and touches(ti.layers, rule.colliding_tiles)) then
          ground_items[key] = ti
          break
        end
      end
    end
    local g = ground_items[key]
    if not g then return nil end
    local r = force and try(function() return force.recipes[g.item] end)
    if r and not r.enabled then return nil end
    return g
  end
  function M.rule_tiles(surface, force, proto, pos, dir, get)
    local rules = try(function() return proto.tile_buildability_rules end)
    if type(rules) ~= 'table' or #rules == 0 then return {ruled=false, need={}} end
    local boxes = {}
    for i, rule in ipairs(rules) do
      local b = M.box_at(rule.area, pos, dir)
      boxes[i] = {math.floor(b.left_top.x + 0.01), math.ceil(b.right_bottom.x - 0.01) - 1, math.floor(b.left_top.y + 0.01), math.ceil(b.right_bottom.y - 0.01) - 1}
    end
    if not get then
      -- the surface, with its tile ghosts as laid (one find over each rule's box)
      local ghosts, gen = {}, {}
      for _, b in ipairs(boxes) do
        for _, g in pairs(try(function() return surface.find_entities_filtered{area={{b[1], b[3]}, {b[2] + 1, b[4] + 1}}, type='tile-ghost'} end) or {}) do
          local tp = prototypes.tile[g.ghost_name]
          if tp then ghosts[math.floor(g.position.x) .. ',' .. math.floor(g.position.y)] = {name=g.ghost_name, layers=tp.collision_mask.layers} end
        end
      end
      get = function(x, y)
        local g = ghosts[x .. ',' .. y]
        if g then return g end
        local cx, cy = math.floor(x / 32), math.floor(y / 32)
        local ck = cx .. ',' .. cy
        if gen[ck] == nil then gen[ck] = try(function() return surface.is_chunk_generated({cx, cy}) end) ~= false end
        local t = try(function() return surface.get_tile(x, y) end)
        if not (t and t.valid ~= false) then return nil end
        -- (a chunk asked for and not generated yet reads out-of-map: not judged either)
        if not gen[ck] and t.name == 'out-of-map' then return nil end
        return {name=t.name, layers=try(function() return t.prototype.collision_mask.layers end) or {}, ungenerated_chunk=not gen[ck] or nil}
      end
    end
    local out = {ruled=true, need={}}
    local needed = {}
    for i, rule in ipairs(rules) do
      local x0, x1, y0, y1 = boxes[i][1], boxes[i][2], boxes[i][3], boxes[i][4]
      local bad, n, first = 0, 0, nil
      for x = x0, x1 do
        for y = y0, y1 do
          n = n + 1
          local t = get(x, y)
          if not t or t.ungenerated_chunk then
            local u = out.ungenerated or {count=0, chunks={}, seen={}, x0=x, x1=x, y0=y, y1=y}
            out.ungenerated = u
            u.count = u.count + 1
            u.x0, u.x1, u.y0, u.y1 = math.min(u.x0, x), math.max(u.x1, x), math.min(u.y0, y), math.max(u.y1, y)
            local ck = math.floor(x / 32) .. ',' .. math.floor(y / 32)
            if not u.seen[ck] then u.seen[ck] = true; u.chunks[#u.chunks+1] = {x=math.floor(x / 32), y=math.floor(y / 32)} end
          end
          if t then
            local tl = t.layers or {}
            if (rule.required_tiles and not touches(tl, rule.required_tiles)) or (rule.colliding_tiles and touches(tl, rule.colliding_tiles)) then
              -- empty space where the rule wants ground: the tile item that mends it (foundation)
              local g = tl.empty_space and ground_item(force, rule, t.name, tl) or nil
              if g then
                local k = x .. ',' .. y
                if not needed[k] then needed[k] = true; out.need[#out.need+1] = {x=x, y=y, item=g.item, tile=t.name, result=g.tile} end
              else
                bad = bad + 1
                first = first or string.format('%s at (%d,%d)', t.name or '?', x, y)
              end
            end
          end
        end
      end
      if bad > 0 and not out.broken then
        local need, clear = layers(rule.required_tiles), layers(rule.colliding_tiles)
        local want = {}
        if #need > 0 then want[#want+1] = 'need '..table.concat(need, '/') end
        if #clear > 0 then want[#want+1] = 'must not be '..table.concat(clear, '/') end
        out.broken = string.format('breaks its tile rule %d facing %s: tiles x %d..%d, y %d..%d %s; %d of %d do not (%s)',
          i, M.direction_name(dir), x0, x1, y0, y1, table.concat(want, ' and '), bad, n, first)
      end
    end
    if out.ungenerated then out.ungenerated.seen = nil end
    return out
  end
  -- What to say of tiles a rule could not judge, and the chunks asked for: the game refuses the entity until they are
  -- generated; a request generates them within a few ticks (no forced generation: 30 ms for 9 chunks on the copy).
  function M.ungenerated_text(surface, u, request)
    if not u then return nil end
    local asked = 0
    if request then
      for i, c in ipairs(u.chunks) do
        if i > 16 then break end
        if try(function() surface.request_to_generate_chunks({c.x * 32 + 16, c.y * 32 + 16}, 0); return true end) then asked = asked + 1 end
      end
    end
    local where = u.count == 1 and string.format('the tile (%d,%d) it needs lies in a chunk', u.x0, u.y0)
      or string.format('%d tiles its tile rules need (x %d..%d, y %d..%d) lie in %d chunk%s', u.count, u.x0, u.x1, u.y0, u.y1, #u.chunks, #u.chunks == 1 and '' or 's')
    return string.format('%s this surface has not generated yet, and the game refuses it until %s%s', where, #u.chunks == 1 and 'that chunk is' or 'they are',
      asked > 0 and string.format('; generating %s was requested now (as a player\'s view would): call again in a few seconds', asked == 1 and 'it' or asked .. ' chunks') or '')
  end

  -- A tile inside an asteroid collector's forward clearance (A5, Astra 01:50: the floor brush said only "47 tiles
  -- refused", the entity dry run "the game refuses foundation" with no why): the collector (built or a ghost) within
  -- 8 tiles whose tile rule keeps that tile empty space, as text; nil when none. (d20 batch52 J1) A thruster's exhaust
  -- too: its second rule keeps the 90 tiles behind it empty space (a thruster or its ghost within 92 tiles).
  function M.collector_ahead(surface, force, x, y)
    local list = try(function() return surface.find_entities_filtered{area={{x - 8, y - 8}, {x + 9, y + 9}}, type='asteroid-collector', force=force} end) or {}
    for _, g in ipairs(try(function() return surface.find_entities_filtered{area={{x - 8, y - 8}, {x + 9, y + 9}}, ghost_type='asteroid-collector', force=force} end) or {}) do list[#list+1] = g end
    for _, t in ipairs(try(function() return surface.find_entities_filtered{area={{x - 92, y - 92}, {x + 93, y + 93}}, type='thruster', force=force} end) or {}) do list[#list+1] = t end
    for _, g in ipairs(try(function() return surface.find_entities_filtered{area={{x - 92, y - 92}, {x + 93, y + 93}}, ghost_type='thruster', force=force} end) or {}) do list[#list+1] = g end
    for _, c in ipairs(list) do
      local ghost = c.type == 'entity-ghost'
      local proto = ghost and try(function() return c.ghost_prototype end) or try(function() return c.prototype end)
      for i, rule in ipairs(try(function() return proto.tile_buildability_rules end) or {}) do
        local need = layers(rule.required_tiles)
        local empty = false
        for _, l in ipairs(need) do if l == 'empty_space' then empty = true end end
        if empty then
          local b = M.box_at(rule.area, c.position, c.direction)
          if x + 0.5 >= b.left_top.x and x + 0.5 <= b.right_bottom.x and y + 0.5 >= b.left_top.y and y + 0.5 <= b.right_bottom.y then
            local thruster = (ghost and c.ghost_type or c.type) == 'thruster'
            return string.format('%s %s%s (%g,%g) facing %s: its tile rule %d keeps tiles x %d..%d, y %d..%d empty space (%s)',
              thruster and 'behind' or 'in front of', ghost and 'the ghost of ' or '', ghost and c.ghost_name or c.name, c.position.x, c.position.y, M.direction_name(c.direction), i,
              math.floor(b.left_top.x + 0.01), math.ceil(b.right_bottom.x - 0.01) - 1, math.floor(b.left_top.y + 0.01), math.ceil(b.right_bottom.y - 0.01) - 1,
              thruster and 'its exhaust' or 'its collection area')
          end
        end
      end
    end
  end
  -- How a built entity (or a ghost) differs from the blueprint entity at its
  -- spot: recipe, filters (inserters, loaders, asteroid collectors), modules.
  -- Returns {differs = {...}, fix = 'configure {...}'} or nil.
  local function item_of(v) return type(v) == 'table' and (v.name and (type(v.name) == 'table' and v.name.name or v.name)) or v end
  local function bp_modules(bp)
    local out, any = {}, false
    for _, it in ipairs(type(bp.items) == 'table' and bp.items or {}) do
      local name = item_of(it.id)
      local proto = name and prototypes.item[name]
      if proto and proto.type == 'module' then
        local n = 0
        for _, at in ipairs(it.items and it.items.in_inventory or {}) do n = n + (at.count or 1) end
        out[name] = (out[name] or 0) + n; any = true
      end
    end
    return any and out or nil
  end
  local function have_modules(e)
    local inv = try(function() return e.get_module_inventory() end)
    if not inv then return nil end
    local out = {}
    for _, s in ipairs(try(function() return inv.get_contents() end) or {}) do out[s.name] = (out[s.name] or 0) + s.count end
    return out
  end
  local function counts_text(t)
    local keys = {}
    for k in pairs(t) do keys[#keys+1] = k end
    table.sort(keys)
    for i, k in ipairs(keys) do keys[i] = k..'*'..t[k] end
    return #keys > 0 and table.concat(keys, ' ') or 'none'
  end
  function M.settings_diff(e, bp)
    local differs, fix, transfer = {}, {}, nil
    if bp.recipe then
      local want = item_of(bp.recipe)
      local r = try(function() local r = e.get_recipe(); return r and r.name end)
      if r ~= want then differs[#differs+1] = 'recipe '..(r or 'none')..', blueprint '..want; fix[#fix+1] = 'recipe='..want end
    end
    local wanted = {}
    for _, f in ipairs(bp.filters or bp.chunk_filter or {}) do
      -- (d24 batch194) an item filter with its quality and comparator, as the entity's read gives it
      local n = bp.filters and type(f) == 'table' and api.filter_text and api.filter_text(f) or item_of(f.name or f)
      if n then wanted[#wanted+1] = n end
    end
    if #wanted > 0 then
      local now = api.filters and (try(function() return api.filters(e) end) or {}).filters or {}
      local a, b = {}, {}
      for i, n in ipairs(wanted) do a[i] = n end
      for i, n in ipairs(now) do b[i] = n end
      table.sort(a); table.sort(b)
      if table.concat(a, ',') ~= table.concat(b, ',') then
        differs[#differs+1] = 'filters '..(#now > 0 and table.concat(now, ',') or 'none')..', blueprint '..table.concat(wanted, ',')
        fix[#fix+1] = 'filters=['..table.concat(wanted, ',')..']'
      end
    end
    local want = bp_modules(bp)
    if want then
      local has = have_modules(e)
      if has and counts_text(has) ~= counts_text(want) then
        differs[#differs+1] = 'modules '..counts_text(has)..', blueprint '..counts_text(want)
        transfer = 'transfer {position, item, direction=to_entity} for the modules'
      end
    end
    if #differs == 0 then return nil end
    local pos = e.position
    local how = {}
    if #fix > 0 then how[#how+1] = string.format('configure {position={x=%g,y=%g}, %s}', pos.x, pos.y, table.concat(fix, ', ')) end
    if transfer then how[#how+1] = transfer end
    if e.type == 'entity-ghost' then how[#how+1] = '(a ghost: once it is built)' end
    return {differs=differs, fix=table.concat(how, '; ')}
  end
  return M
end
