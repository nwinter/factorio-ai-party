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
  -- Storage a player opens: a chest, wagon, vehicle trunk, landing pad or hub. holds is one line as its GUI shows it
  -- (Muse: a chest's contents were only readable in JSON): the largest stacks first with counts, slots used of the
  -- total and the red-X limit; requests is a requester's or buffer's asks with what it holds of each.
  local STORES = {'chest', 'cargo_wagon', 'car_trunk', 'spider_trunk', 'cargo_landing_pad_main', 'hub_main'}
  local SHOWN = 6
  local function label(s)
    local q = s.quality
    if type(q) == 'table' then q = q.name end
    return s.name .. (type(q) == 'string' and q ~= 'normal' and '@' .. q or '')
  end
  function M.holds(e, out)
    for _, name in ipairs(STORES) do
      local list = out.inventories and out.inventories[name]
      local inv = list and try(function() return e.get_inventory(defines.inventory[name]) end)
      if inv then
        local sorted, have = {}, {}
        for i, s in ipairs(list) do sorted[i] = s; have[s.name] = (have[s.name] or 0) + s.count end
        table.sort(sorted, function(x, y) if x.count ~= y.count then return x.count > y.count end return label(x) < label(y) end)
        local parts = {}
        for i = 1, math.min(SHOWN, #sorted) do parts[i] = label(sorted[i]) .. '*' .. sorted[i].count end
        if #sorted > SHOWN then parts[#parts+1] = '+' .. (#sorted - SHOWN) .. ' more' end
        local total, free = #inv, try(function() return inv.count_empty_stacks() end)
        local bar = try(function() return inv.get_bar() end)
        local slots = free and string.format('; %d of %d slots', total - free, total) or ''
        if free and bar and bar <= total then slots = slots .. string.format(' (limited to %d)', bar - 1) end
        out.holds = (#parts > 0 and table.concat(parts, ' ') or 'empty') .. slots
        M.requests(e, out, have)
        return
      end
    end
  end
  function M.requests(e, out, have)
    local mode = try(function() return e.prototype.logistic_mode end)
    if mode ~= 'requester' and mode ~= 'buffer' then return end
    local secs = try(function() return e.get_logistic_sections() end)
    local want, order, circuit = {}, {}, false
    for i = 1, secs and secs.sections_count or 0 do
      local sec = try(function() return secs.get_section(i) end)
      if sec and sec.active ~= false then
        if sec.is_manual == false then circuit = true end
        for _, f in ipairs(try(function() return sec.filters end) or {}) do
          local v = f.value
          local item = type(v) == 'table' and v.name or v
          if type(item) == 'string' and (f.min or 0) > 0 then
            if not want[item] then want[item] = 0; order[#order+1] = item end
            want[item] = want[item] + f.min
          end
        end
      end
    end
    if #order == 0 then out.requests = 'none'; return end
    local parts = {}
    for i, item in ipairs(order) do
      if i > 8 then parts[#parts+1] = '+' .. (#order - 8) .. ' more'; break end
      parts[#parts+1] = string.format('%s %d/%d', item, have[item] or 0, want[item])
    end
    out.requests = table.concat(parts, ', ') .. (circuit and '; a section set by circuit' or '')
  end
  function M.inspect(e, out)
    pcall(M.holds, e, out)
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
