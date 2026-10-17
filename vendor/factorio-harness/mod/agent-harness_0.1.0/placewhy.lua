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

  -- A tile inside an asteroid collector's forward clearance (A5, Astra 01:50: the floor brush said only "47 tiles
  -- refused", the entity dry run "the game refuses foundation" with no why): the collector (built or a ghost) within
  -- 8 tiles whose tile rule keeps that tile empty space, as text; nil when none.
  function M.collector_ahead(surface, force, x, y)
    local list = try(function() return surface.find_entities_filtered{area={{x - 8, y - 8}, {x + 9, y + 9}}, type='asteroid-collector', force=force} end) or {}
    for _, g in ipairs(try(function() return surface.find_entities_filtered{area={{x - 8, y - 8}, {x + 9, y + 9}}, ghost_type='asteroid-collector', force=force} end) or {}) do list[#list+1] = g end
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
            return string.format('in front of %s%s (%g,%g) facing %s: its tile rule %d keeps tiles x %d..%d, y %d..%d empty space (its collection area)',
              ghost and 'the ghost of ' or '', ghost and c.ghost_name or c.name, c.position.x, c.position.y, M.direction_name(c.direction), i,
              math.floor(b.left_top.x + 0.01), math.ceil(b.right_bottom.x - 0.01) - 1, math.floor(b.left_top.y + 0.01), math.ceil(b.right_bottom.y - 0.01) - 1)
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
      local n = item_of(f.name or f)
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
