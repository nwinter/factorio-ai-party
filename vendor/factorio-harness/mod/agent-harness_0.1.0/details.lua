-- More of what the game's entity GUI and cursor show, for inspect (details.lua):
-- inserter filters and filter mode, asteroid collector chunk filters and what
-- its arms hold, the stack an inserter holds, the entities
-- it picks up from and drops into, deconstruction and upgrade marks, and the
-- ghosts standing on the entity's footprint (a paste waiting to replace it).
-- Every read is guarded: an entity without the field skips it.
return function(api)
  local M = {}
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function item_name(f)
    if type(f) == 'string' then return f end
    if type(f) ~= 'table' then return nil end
    local n = f.name
    if type(n) == 'table' then n = n.name end
    if type(n) ~= 'string' then return nil end
    local q = f.quality
    if type(q) == 'table' then q = q.name end
    return n .. (type(q) == 'string' and q ~= 'normal' and '@' .. q or '')
  end
  local function collector(e)
    return e.type == 'asteroid-collector' or (e.type == 'entity-ghost' and try(function() return e.ghost_type end) == 'asteroid-collector')
  end
  -- An asteroid collector's filter is a chunk prototype (AsteroidChunkID).
  local function chunk_name(f)
    if type(f) == 'string' then return f end
    return f ~= nil and try(function() return f.name end) or nil
  end
  -- {filters, filter_mode, use_filters} of an inserter, loader or their ghost;
  -- {filters, filter_slots} of an asteroid collector or its ghost.
  local function filters(e)
    local slots = try(function() return e.filter_slot_count end) or 0
    if slots <= 0 then return nil end
    local list = {}
    if collector(e) then
      for i = 1, slots do list[#list+1] = chunk_name(try(function() return e.get_filter(i) end)) end
      return {filters=list, filter_slots=slots}
    end
    for i = 1, slots do
      local n = item_name(try(function() return e.get_filter(i) end))
      if n then list[#list+1] = n end
    end
    local inserter = e.type == 'inserter' or (e.type == 'entity-ghost' and e.ghost_type == 'inserter')
    local out = {filters=list}
    if inserter then
      out.filter_mode = try(function() return e.inserter_filter_mode end)
      out.use_filters = try(function() return e.use_filters end)
    end
    return out
  end
  M.COLLECTOR_NOTE = 'filters are asteroid chunk names (configure {position, filters}); the game has no whitelist/blacklist mode for collectors'
  -- configure {filters} on an asteroid collector, as its GUI's chunk filter
  -- slots: chunk names up to filter_slot_count, [] clears.
  function M.configure_collector(e, a, slots)
    assert(a.filter_mode == nil, 'asteroid collectors have no filter mode (the game has none): filters lists the chunks')
    local known = {}
    for name in pairs(prototypes.asteroid_chunk or {}) do known[#known+1] = name end
    table.sort(known)
    for _, name in ipairs(a.filters) do
      assert(type(name) == 'string' and (prototypes.asteroid_chunk or {})[name], 'unknown asteroid chunk ' .. tostring(name) .. '; chunks: ' .. table.concat(known, ', '))
    end
    for i = 1, slots do e.set_filter(i, a.filters[i]) end
    local f = filters(e)
    return {filters=f and f.filters or {}, filter_slots=slots, note=M.COLLECTOR_NOTE}
  end
  M.collector = collector
  local function where(t)
    return t and t.valid and string.format('%s (%g,%g)', t.name, t.position.x, t.position.y) or nil
  end
  function M.inspect(e, out)
    local f = filters(e)
    if f then out.filters = f.filters; out.filter_mode = f.filter_mode; out.use_filters = f.use_filters; out.filter_slots = f.filter_slots end
    -- A collector: chunks its arms hold on the way in (output is in inventories).
    if e.type == 'asteroid-collector' then
      out.arm = try(function() return e.get_inventory(defines.inventory.asteroid_collector_arm).get_contents() end)
      out.collector_note = M.COLLECTOR_NOTE
    end
    if e.type == 'inserter' then
      local held = try(function() local s = e.held_stack; return s and s.valid_for_read and s.count .. ' ' .. s.name or nil end)
      out.held = held or 'nothing'
      out.pickup_target = where(try(function() return e.pickup_target end))
      out.drop_target = where(try(function() return e.drop_target end))
      -- Nothing to drop into: the tile its items land on (on a platform,
      -- empty space means thrown overboard).
      if not out.drop_target then
        out.drop_tile = try(function() local d = e.drop_position; return e.surface.get_tile(math.floor(d.x), math.floor(d.y)).name end)
        if out.drop_tile == 'empty-space' then out.drop_note = 'drops into empty space: items it moves are thrown overboard' end
      end
    end
    out.marked_for_deconstruction = try(function() return e.to_be_deconstructed() end) or nil
    out.marked_for_upgrade = try(function() return e.to_be_upgraded() end) or nil
    -- Ghosts on the footprint: what a paste or blueprint will put here.
    if e.type ~= 'entity-ghost' then
      local ghosts = try(function() return e.surface.find_entities_filtered{area=e.bounding_box, type='entity-ghost', limit=8} end) or {}
      local rows = {}
      for _, g in ipairs(ghosts) do
        if g.valid and g ~= e then
          local row = {name=g.ghost_name, position=g.position, direction=g.direction ~= 0 and g.direction or nil}
          local gf = filters(g)
          if gf then row.filters = gf.filters; row.filter_mode = gf.filter_mode end
          rows[#rows+1] = row
        end
      end
      out.ghosts_here = #rows > 0 and rows or nil
    end
    return out
  end
  return M
end
