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
  -- A collector's filter_slot_count reads 0 until a filter is set (shift06
  -- 11:57: a new collector refused configure, a paste worked), so its slots
  -- are read past the count, until get_filter fails (at most 32).
  local MAX_CHUNK_SLOTS = 32
  local function chunk_slots(e, n)
    local out = {}
    for i = 1, n do
      local ok, f = pcall(function() return e.get_filter(i) end)
      if not ok then break end
      out[i] = chunk_name(f) or false
    end
    return out
  end
  -- {filters, filter_slots} of an asteroid collector or its ghost: chunk
  -- names, and the game's filter_slot_count.
  local function chunk_filters(e)
    local slots = try(function() return e.filter_slot_count end) or 0
    local list = {}
    for _, name in ipairs(chunk_slots(e, math.max(slots, MAX_CHUNK_SLOTS))) do
      if name then list[#list+1] = name end
    end
    return {filters=list, filter_slots=slots}
  end
  -- {filters, filter_mode, use_filters} of an inserter, loader or their ghost;
  -- {filters, filter_slots} of an asteroid collector or its ghost.
  local function filters(e)
    if collector(e) then return chunk_filters(e) end
    local slots = try(function() return e.filter_slot_count end) or 0
    if slots <= 0 then return nil end
    local list = {}
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
  -- slots: chunk names in slots 1.., [] clears. filter_slot_count is not
  -- trusted (it reads 0 before the first filter): each slot is set and only
  -- the game's refusal fails it, with the slots set before put back.
  function M.configure_collector(e, a)
    assert(a.filter_mode == nil, 'asteroid collectors have no filter mode (the game has none): filters lists the chunks')
    local known = {}
    for name in pairs(prototypes.asteroid_chunk or {}) do known[#known+1] = name end
    table.sort(known)
    for _, name in ipairs(a.filters) do
      assert(type(name) == 'string' and (prototypes.asteroid_chunk or {})[name], 'unknown asteroid chunk ' .. tostring(name) .. '; chunks: ' .. table.concat(known, ', '))
    end
    local count = try(function() return e.filter_slot_count end) or 0
    local was = chunk_slots(e, math.max(count, #a.filters, 1))
    local function put(i, name) return pcall(function() e.set_filter(i, name) end) end
    for i, name in ipairs(a.filters) do
      local ok, err = put(i, name)
      if not ok then
        for j = 1, i - 1 do put(j, was[j] or nil) end
        error(string.format('the game refused %s in filter slot %d: %s%s', name, i, tostring(err):gsub('%s+', ' '),
          i > 1 and ' (slots 1..' .. (i - 1) .. ' are as they were)' or ''), 0)
      end
    end
    -- The slots after the list: cleared where they held a filter.
    for i = #a.filters + 1, #was do if was[i] then put(i, nil) end end
    local f = chunk_filters(e)
    local got, missing = {}, {}
    for _, name in ipairs(f.filters) do got[name] = (got[name] or 0) + 1 end
    for _, name in ipairs(a.filters) do
      if (got[name] or 0) > 0 then got[name] = got[name] - 1 else missing[#missing+1] = name end
    end
    return {filters=f.filters, filter_slots=f.filter_slots, not_set=#missing > 0 and missing or nil, note=M.COLLECTOR_NOTE}
  end
  M.collector = collector
  M.filters = filters  -- placewhy.lua: a pasted entity's filters against its blueprint's
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
