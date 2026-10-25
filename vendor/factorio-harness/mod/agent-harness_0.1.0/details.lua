-- More of what the game's entity GUI and cursor show, for inspect (details.lua):
-- inserter filters and filter mode, asteroid collector chunk filters and what
-- its arms hold, the stack an inserter holds, the entities
-- it picks up from and drops into, deconstruction and upgrade marks, and the
-- ghosts standing on the entity's footprint (a paste waiting to replace it).
-- Every read is guarded: an entity without the field skips it.
return function(api)
  local M = {}
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  function M.held_blocked(e)
    if e.type~='inserter' then return nil end
    local h=try(function() return e.held_stack end)
    local t=try(function() return e.drop_target end)
    if not (h and h.valid_for_read and t and t.valid) then return nil end
    if t.type=='transport-belt' or t.type=='underground-belt' or t.type=='splitter' then return nil end
    if e.force and e.surface and not e.surface.platform and
      try(function() return e.force.is_chunk_visible(e.surface,{math.floor(t.position.x/32),math.floor(t.position.y/32)}) end)==false then return nil end
    local q=try(function() return type(h.quality)=='string' and h.quality or h.quality.name end) or 'normal'
    if try(function() return t.can_insert{name=h.name,count=1,quality=q} end)~=false then return nil end
    local r=try(function() return t.get_recipe() end)
    return string.format('%s (%g,%g) holds %d %s@%s; %s (%g,%g) cannot accept one now%s',
      e.name,e.position.x,e.position.y,h.count,h.name,q,t.name,t.position.x,t.position.y,r and ' (recipe '..r.name..')' or '')
  end
  -- An item filter as 'name' or 'name@quality'. 2.0.77 gives inserters' and loaders' as {name, quality} strings and a
  -- storage chest's as {name=LuaItemPrototype, quality=LuaQualityPrototype} (userdata, read by their name).
  local function item_name(f)
    if type(f) == 'string' then return f end
    if type(f) ~= 'table' then return nil end
    local n = f.name
    if type(n) ~= 'string' then n = try(function() return n.name end) end
    if type(n) ~= 'string' then return nil end
    local q = f.quality
    if q ~= nil and type(q) ~= 'string' then q = try(function() return q.name end) end
    return n .. (type(q) == 'string' and q ~= 'normal' and '@' .. q or '')
  end
  M.item_name = item_name
  -- Item filters as 2.0.77's ItemFilter {name, quality?, comparator?} (d24 batch194 QAJ1, Sol #2270: "configure.filters
  -- accepts only item strings, refuses {name,quality} as unknown item table and plastic-bar@quality as unknown item").
  -- On a copy of world n, set_filter: a name alone stores quality normal, comparator "="; {name} with no quality stores
  -- no quality (every quality passes); a comparator with no quality is dropped; comparators read back as the signs
  -- ≤ ≥ ≠. Taken: "name" (normal, as the game), "name@quality", "name@<=quality" (any comparator), "name@any", or
  -- {name|item, quality?, comparator?}. Read: the same strings ("name" for normal and "=").
  local COMPARATORS = {['=']='=', ['!=']='!=', ['<']='<', ['<=']='<=', ['>']='>', ['>=']='>=', ['≠']='!=', ['≤']='<=', ['≥']='>='}
  local OPS = {'<=', '>=', '!=', '≤', '≥', '≠', '<', '>', '='}
  local function quality_names()
    local list = {}
    for name, q in pairs(prototypes.quality or {}) do if not q.hidden then list[#list+1] = {name, q.level or 0} end end
    table.sort(list, function(a, b) if a[2] ~= b[2] then return a[2] < b[2] end return a[1] < b[1] end)
    local out = {}
    for i, q in ipairs(list) do out[i] = q[1] end
    return table.concat(out, ', ')
  end
  M.FILTER_FORMS = '"name" (normal quality), "name@quality", "name@<=quality" (comparator =, !=, <, <=, >, >=), "name@any" (every quality), or {name, quality, comparator}'
  -- One filter as the game takes it (a name, or an ItemFilter table), or an error naming what is known.
  function M.parse_filter(f)
    local name, quality, comparator
    if type(f) == 'string' then
      local at = f:find('@[^@]*$')
      if not at then name = f
      else
        name = f:sub(1, at - 1)
        local rest = f:sub(at + 1)
        for _, op in ipairs(OPS) do
          if rest:sub(1, #op) == op then comparator, rest = op, rest:sub(#op + 1); break end
        end
        if rest == 'any' then
          if comparator then error('filter ' .. f .. ': any takes no comparator (every quality passes)', 0) end
          quality = false
        else quality = rest end
      end
    elseif type(f) == 'table' then
      for k in pairs(f) do
        if k ~= 'name' and k ~= 'item' and k ~= 'quality' and k ~= 'comparator' and k ~= 'index' then
          error('filter: unknown key ' .. tostring(k) .. '; a filter is ' .. M.FILTER_FORMS, 0)
        end
      end
      name, quality, comparator = f.name or f.item, f.quality, f.comparator
      if quality == nil then quality = false end
      if quality == 'any' then quality = false end
    else
      error('filter: ' .. tostring(f) .. ' is not a filter; a filter is ' .. M.FILTER_FORMS, 0)
    end
    if not (type(name) == 'string' and prototypes.item[name]) then error('unknown item ' .. tostring(name), 0) end
    if quality then
      local q = type(quality) == 'string' and (prototypes.quality or {})[quality]
      if not q or q.hidden then error('unknown quality ' .. tostring(quality) .. '; qualities: ' .. quality_names(), 0) end
    end
    if comparator ~= nil then
      if not COMPARATORS[comparator] then error('unknown comparator ' .. tostring(comparator) .. '; comparators: =, !=, <, <=, >, >=', 0) end
      if not quality then error('filter ' .. name .. ': comparator ' .. comparator .. ' goes with quality (with no quality every quality passes, and the game drops the comparator)', 0) end
    end
    if quality == nil then return name end
    if quality == false then return {name=name} end
    return {name=name, quality=quality, comparator=COMPARATORS[comparator or '=']}
  end
  -- A filter list (one filter alone is a list of one), checked: the filters as the game takes them.
  function M.filter_list(f, slots)
    if type(f) == 'string' or (type(f) == 'table' and (f.name ~= nil or f.item ~= nil)) then f = {f} end
    if not (type(f) == 'table' and #f <= slots) then error('filters requires 0..' .. slots .. ' filters: each ' .. M.FILTER_FORMS, 0) end
    local out = {}
    for i, one in ipairs(f) do out[i] = M.parse_filter(one) end
    return out
  end
  -- A filter read back: "name" (normal, "="), "name@epic", "name@<=epic", "name@any" (no quality).
  function M.filter_text(f)
    if type(f) == 'string' then return f end
    if type(f) ~= 'table' then return nil end
    local n = f.name
    if type(n) ~= 'string' then n = try(function() return n.name end) end
    if type(n) ~= 'string' then return nil end
    local q = f.quality
    if q ~= nil and type(q) ~= 'string' then q = try(function() return q.name end) end
    if type(q) ~= 'string' then return n .. '@any' end
    local c = COMPARATORS[f.comparator or '='] or f.comparator
    if c == '=' then return q == 'normal' and n or n .. '@' .. q end
    return n .. '@' .. c .. q
  end
  -- Why an inserter waits for source items (d17 batch18 A1, Grok: a heating tower's arm read waiting_for_source_items
  -- with rocket fuel in the requester beside it). On a copy of world n the game's arm kept the tower's fuel at about
  -- 5 rocket fuel and waited above that (with 10 yumako seeds in its second fuel slot, at 1 or 2); the tower ran dry
  -- when its network had no rocket fuel left to bring. The line says: what the pickup holds of the items the arm may
  -- take (a requester or buffer: what its network holds of them outside requester chests; robots on their way to take
  -- from it), and per item whether the drop target takes one now (a fuel inventory: what fills its slots) and what it
  -- holds of it (fuel: how fast it burns at full power).
  local function stack_name(f)
    if type(f) == 'string' then return f end
    if type(f) ~= 'table' then return nil end
    local n = f.name
    if type(n) ~= 'string' then n = try(function() return n.name end) end
    return type(n) == 'string' and n or nil
  end
  local function contents_text(inv)
    local parts = {}
    for _, st in ipairs(try(function() return inv.get_contents() end) or {}) do
      local n = stack_name(st)
      if n then parts[#parts+1] = n .. ' ' .. st.count end
    end
    return #parts > 0 and table.concat(parts, ', ') or 'nothing'
  end
  local function source_items(src, at)
    local got = {}
    local function add(list)
      for _, st in ipairs(list or {}) do
        local n = stack_name(st)
        if n then got[n] = (got[n] or 0) + st.count end
      end
    end
    local t = src.type
    if t == 'transport-belt' or t == 'underground-belt' or t == 'splitter' or t == 'loader' or t == 'loader-1x1' or t == 'linked-belt' then
      for k = 1, try(function() return src.get_max_transport_line_index() end) or 2 do
        add(try(function() return src.get_transport_line(k).get_contents() end))
      end
      return got, 'its lanes'
    end
    local inv = try(function() return src.get_output_inventory() end) or try(function() return src.get_inventory(defines.inventory.chest) end)
    if not inv then return nil end
    add(try(function() return inv.get_contents() end))
    return got
  end
  function M.pickup_wait(e)
    local waiting = try(function() return defines.entity_status.waiting_for_source_items end)
    if e.type ~= 'inserter' or not waiting or try(function() return e.status end) ~= waiting then return nil end
    local src, dst = try(function() return e.pickup_target end), try(function() return e.drop_target end)
    if not (src and src.valid) then return 'picks from the ground: no item lies at its pickup point' end
    local names, filtered = {}, false
    if try(function() return e.use_filters end) then
      for k = 1, try(function() return e.filter_slot_count end) or 0 do
        local n = stack_name(try(function() return e.get_filter(k) end))
        if n then names[n] = true; filtered = true end
      end
    end
    local black = filtered and try(function() return e.inserter_filter_mode end) == 'blacklist'
    local got = source_items(src)
    if not got then return string.format('%s (%g,%g) has no inventory it takes from', src.name, src.position.x, src.position.y) end
    local rows = {}
    for n, c in pairs(got) do
      if not filtered or (black and not names[n]) or (not black and names[n]) then rows[#rows+1] = {n, c} end
    end
    table.sort(rows, function(a, b) return a[2] > b[2] end)
    local parts = {}
    local here = string.format('%s (%g,%g)', src.name, src.position.x, src.position.y)
    if #rows == 0 then
      local want = {}
      for n in pairs(names) do want[#want+1] = n end
      table.sort(want)
      parts[1] = string.format('%s holds none of %s', here, filtered and (black and 'the items its filter lets through' or table.concat(want, ', ')) or 'any item')
    else
      local held = {}
      for i = 1, math.min(3, #rows) do held[i] = rows[i][1] .. ' ' .. rows[i][2] end
      parts[1] = string.format('%s holds %s%s', here, table.concat(held, ', '), #rows > 3 and ', ...' or '')
    end
    -- A requester or buffer: what its network can still bring of the items the arm takes.
    local mode = try(function() return src.prototype.logistic_mode end)
    if mode == 'requester' or mode == 'buffer' then
      local net = try(function() return src.logistic_network end)
      local want = {}
      if filtered and not black then for n in pairs(names) do want[#want+1] = n end end
      if #want == 0 then for i = 1, math.min(3, #rows) do want[i] = rows[i][1] end end
      table.sort(want)
      local nets = {}
      for i = 1, math.min(3, #want) do
        nets[i] = want[i] .. ' ' .. (net and (try(function() return net.get_item_count(want[i]) end) or 0) or 0)
      end
      if not net then parts[#parts+1] = 'it is in no logistic network'
      elseif #nets > 0 then parts[#parts+1] = string.format('its logistic network %s holds %s outside requester chests', tostring(net.network_id), table.concat(nets, ', ')) end
    end
    local robots = 0
    for _, r in ipairs(try(function() return src.surface.find_entities_filtered{type='logistic-robot', position=src.position, radius=4, limit=16} end) or {}) do
      local o = try(function() return r.robot_order_queue[1] end)
      if o and o.target == src and o.type == defines.robot_order_type.pickup then robots = robots + 1 end
    end
    if robots > 0 then parts[#parts+1] = string.format('%d logistic robot%s near it on the way to take from it', robots, robots == 1 and '' or 's') end
    if not (dst and dst.valid) then return table.concat(parts, '; ') end
    local there = string.format('%s (%g,%g)', dst.name, dst.position.x, dst.position.y)
    local fuel = try(function() return dst.get_fuel_inventory() end)
    for i = 1, math.min(2, #rows) do
      local n = rows[i][1]
      local fv = try(function() return prototypes.item[n].fuel_value end) or 0
      local takes = try(function() return dst.can_insert{name=n, count=1} end)
      if takes == false then
        if fuel and fv > 0 then
          parts[#parts+1] = string.format('%s takes no %s now: its %d fuel slots hold %s', there, n, #fuel, contents_text(fuel))
        else
          local r = try(function() return dst.get_recipe() end)
          parts[#parts+1] = string.format('%s takes no %s now%s', there, n, r and ' (recipe ' .. r.name .. ')' or '')
        end
      elseif fuel and fv > 0 then
        local use = try(function() return dst.prototype.get_max_energy_usage() end)
        parts[#parts+1] = string.format('%s takes %s; its %d fuel slots hold %s (the game\'s arms top fuel up only while it runs low)%s', there, n, #fuel,
          contents_text(fuel), use and use > 0 and string.format('; at full power it burns %.1f %s a minute', use * 3600 / fv, n) or '')
      else
        parts[#parts+1] = string.format('%s takes %s and holds %d of it (the game\'s arms fill a machine or turret only up to a limit)', there, n,
          try(function() return dst.get_item_count(n) end) or 0)
      end
    end
    return table.concat(parts, '; ')
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
      local n = M.filter_text(try(function() return e.get_filter(i) end))
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
  -- A storage chest (logistic container in storage mode) or its ghost.
  local function storage_chest(e)
    local proto = e.type == 'entity-ghost' and try(function() return e.ghost_prototype end) or try(function() return e.prototype end)
    return proto ~= nil and proto.type == 'logistic-container' and try(function() return proto.logistic_mode end) == 'storage'
  end
  M.storage_chest = storage_chest
  -- A storage chest's filter, 'name' or 'name@quality', or nil (Astra, shift13 01:58: scrap overflow filled every
  -- storage chest and a construction robot held removed modules with nowhere to go). 2.0.77 on a copy of world n:
  -- storage_filter and set_filter(1) are the same slot; a ghost keeps one set on it for the chest it becomes and reads
  -- nil, so a ghost's is read from a blueprint of it (request_filters, about 6 ms there).
  function M.storage_filter(e)
    if e.type ~= 'entity-ghost' then return item_name(try(function() return e.storage_filter end)) end
    return try(function()
      local inv = game.create_inventory(1)
      local ok, f = pcall(function()
        inv.insert{name='blueprint'}
        local bp = inv[1]
        bp.create_blueprint{surface=e.surface, force=e.force, area=e.bounding_box}
        for _, be in ipairs(bp.get_blueprint_entities() or {}) do
          if be.name == e.ghost_name and math.abs(be.position.x - e.position.x) < 0.01 and math.abs(be.position.y - e.position.y) < 0.01 then
            local sec = be.request_filters and be.request_filters.sections and be.request_filters.sections[1]
            local row = sec and sec.filters and sec.filters[1]
            return row and row.name and {name=row.name, quality=row.quality} or nil
          end
        end
      end)
      inv.destroy()
      return ok and item_name(f) or nil
    end)
  end
  -- configure {storage_filter}: an item name, {name, quality?}, or false/"none" to clear (a ghost's applies when built).
  function M.configure_storage_filter(e, v)
    local name = e.type == 'entity-ghost' and e.ghost_name or e.name
    if not storage_chest(e) then
      error(string.format('%s (%g,%g) is not a storage chest: storage_filter is a storage chest\'s filter', name, e.position.x, e.position.y), 0)
    end
    local before = M.storage_filter(e)
    local want
    if v ~= false and v ~= 'none' and v ~= '' then
      local item, quality = v, 'normal'
      if type(v) == 'table' then item, quality = v.name, v.quality or 'normal' end
      if not (type(item) == 'string' and prototypes.item[item]) then error('storage_filter: unknown item ' .. tostring(item), 0) end
      if not prototypes.quality[quality] then error('unknown quality ' .. tostring(quality), 0) end
      want = {name=item, quality=quality}
    end
    e.storage_filter = want
    local now = M.storage_filter(e)
    return {name=name, position=e.position, ghost=e.type == 'entity-ghost' or nil, storage_filter=now or 'none', storage_filter_before=before or 'none'}
  end

  -- A splitter's settings as its GUI shows them, with the belt tiles they name (Muse, shift13: a plate split could not
  -- favour the steel branch). Left and right are as seen facing the way items move. 2.0.77 on a copy of world n:
  -- output priority sends items to that output while it takes them, the other when it is full; input priority takes
  -- from that input while it has items, the other only then; with a filter, the filter's items go only to the output
  -- priority side (waiting there when it is full, which holds up the lane behind them) and the other items only to the
  -- other side; with output priority none the filter does nothing (items split evenly). Ghosts take all three.
  local STEPS = {[0]={0, -1}, [4]={1, 0}, [8]={0, 1}, [12]={-1, 0}}
  local function splitter_entity(e)
    return e.type == 'splitter' or (e.type == 'entity-ghost' and try(function() return e.ghost_type end) == 'splitter')
  end
  M.splitter_entity = splitter_entity
  -- The input and output tiles of a side ('left' or 'right'): {input={x,y}, output={x,y}}.
  local function sides(e, side)
    local d = STEPS[e.direction] or STEPS[0]
    local lx, ly = d[2], -d[1]
    if side == 'right' then lx, ly = -lx, -ly end
    local cx, cy = e.position.x + lx * 0.5, e.position.y + ly * 0.5
    return {input={x=cx - d[1], y=cy - d[2]}, output={x=cx + d[1], y=cy + d[2]}}
  end
  local function at(p) return string.format('(%g,%g)', p.x, p.y) end
  local OTHER = {left='right', right='left'}
  function M.splitter(e)
    if not splitter_entity(e) then return nil end
    local inp = try(function() return e.splitter_input_priority end) or 'none'
    local outp = try(function() return e.splitter_output_priority end) or 'none'
    local f = try(function() return e.splitter_filter end)
    local filter = item_name(f)
    if filter and f.comparator and f.comparator ~= '=' then filter = filter .. ' (quality ' .. tostring(f.comparator) .. ')' end
    local parts = {}
    if inp == 'none' then parts[#parts+1] = 'input priority: none (both inputs alike)'
    else parts[#parts+1] = string.format('input priority: %s (the %s input %s first, the other when it has none)', inp, inp, at(sides(e, inp).input)) end
    if filter and outp ~= 'none' then
      parts[#parts+1] = string.format('output priority: %s; filter: %s to the %s output %s only, other items to the %s output %s', outp, filter, outp,
        at(sides(e, outp).output), OTHER[outp], at(sides(e, OTHER[outp]).output))
    else
      if outp == 'none' then parts[#parts+1] = 'output priority: none (items split evenly)'
      else parts[#parts+1] = string.format('output priority: %s (the %s output %s first, the other when it is full)', outp, outp, at(sides(e, outp).output)) end
      if filter then parts[#parts+1] = 'filter: ' .. filter .. ' (does nothing while output priority is none)' end
    end
    return {input_priority=inp, output_priority=outp, filter=filter, line=table.concat(parts, '; ')}
  end
  local PRIORITY = {left=true, right=true, none=true}
  -- configure {input_priority?, output_priority?, filter?} on a splitter or its ghost.
  function M.configure_splitter(e, a)
    local name = e.type == 'entity-ghost' and e.ghost_name or e.name
    local where = string.format('%s (%g,%g)', name, e.position.x, e.position.y)
    for _, k in ipairs({'input_priority', 'output_priority'}) do
      if a[k] ~= nil and not PRIORITY[a[k]] then error(k .. ' is left, right or none (as seen facing the way items move)', 0) end
    end
    local filter, clear = nil, false
    if a.filter ~= nil then
      if a.filter == false or a.filter == 'none' or a.filter == '' then clear = true
      else
        local item, quality = a.filter, nil
        if type(a.filter) == 'table' then item, quality = a.filter.name, a.filter.quality end
        if not (type(item) == 'string' and prototypes.item[item]) then error('filter: unknown item ' .. tostring(item), 0) end
        if quality ~= nil and not prototypes.quality[quality] then error('unknown quality ' .. tostring(quality), 0) end
        filter = {name=item, quality=quality or 'normal'}
      end
    end
    local before = M.splitter(e)
    local outp = a.output_priority or before.output_priority
    if filter and outp == 'none' then
      error(string.format('%s: a filter sends its items to the output priority side and the other items to the other side; with output priority none it does nothing (items split evenly): set output_priority left or right in the same call', where), 0)
    end
    if a.input_priority ~= nil then e.splitter_input_priority = a.input_priority end
    if a.output_priority ~= nil then e.splitter_output_priority = a.output_priority end
    if clear then e.splitter_filter = nil elseif filter then e.splitter_filter = filter end
    local now = M.splitter(e)
    return {name=name, position=e.position, ghost=e.type == 'entity-ghost' or nil, input_priority=now.input_priority, output_priority=now.output_priority,
      filter=now.filter or 'none', line=now.line, before=before.line}
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
  -- An inserter's or loader's filters as one line (Sonnet 06:20: three inserters with stale filters blocked a line,
  -- and scan showed none): "whitelist: iron-plate, copper-plate", "blacklist: coal", "off (filters: coal)" when the
  -- filter is not in use, "set by circuit" when the circuit network sets them; nil without filter slots or filters.
  function M.filters_line(e)
    if collector(e) then return nil end
    local f = filters(e)
    if not f then return nil end
    local by_circuit = try(function()
      local cb = e.get_control_behavior()
      return cb and cb.circuit_set_filters
    end) == true
    local list = #f.filters > 0 and table.concat(f.filters, ', ') or nil
    if by_circuit then return 'set by circuit' .. (list and ' (now: ' .. list .. ')' or '') end
    local inserter = e.type == 'inserter' or (e.type == 'entity-ghost' and e.ghost_type == 'inserter')
    if inserter and f.use_filters == false then return list and 'off (filters: ' .. list .. ')' or nil end
    if not list and not (inserter and f.use_filters) then return nil end
    return (f.filter_mode or 'whitelist') .. ': ' .. (list or 'no items set')
  end
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
        -- (d24 batch157) and the free slots under it (count_empty_stacks(true, false)): nothing goes past it
        local under = bar and bar <= total and try(function() return inv.count_empty_stacks(true, false) end)
        if free and bar and bar <= total then slots = slots .. string.format(' (limited to %d%s)', bar - 1, under and string.format(', %d free under it', under) or '') end
        -- (d21 batch64 Z2, Luna #1576) the bar as configure {bar} sets it: usable slots
        if bar and bar <= total then out.bar = bar - 1 end
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
  local robots = require('robotread'){}
  local groundstack = require('groundstack')
  function M.inspect(e, out)
    pcall(M.holds, e, out)
    -- (d22 batch78 AN1, Astra #1809) items on the ground: the stack as hovering it shows (groundstack.lua)
    if e.type == 'item-entity' then
      local st = groundstack.stack(e)
      out.stack = st; out.holds = groundstack.holds(st)
    end
    -- (d20 batch70 AF4, Astra #1718) a robot: what it carries and where it flies (robotread.lua)
    if robots.ROBOT[e.type] then
      local ok, r = pcall(robots.row, e)
      if ok then out.robot = r; out.holds = robots.holds(e) end
    end
    -- A storage chest's one filter slot is its storage filter (robots store only that item in it).
    if storage_chest(e) then out.storage_filter = M.storage_filter(e) or 'none'
    else
      local f = filters(e)
      if f then out.filters = f.filters; out.filter_mode = f.filter_mode; out.use_filters = f.use_filters; out.filter_slots = f.filter_slots end
    end
    if splitter_entity(e) then out.splitter = M.splitter(e) end
    -- A collector: chunks its arms hold on the way in (output is in inventories).
    if e.type == 'asteroid-collector' then
      out.arm = try(function() return e.get_inventory(defines.inventory.asteroid_collector_arm).get_contents() end)
      out.collector_note = M.COLLECTOR_NOTE
    end
    if e.type == 'inserter' then
      local held = try(function() local s = e.held_stack; return s and s.valid_for_read and s.count .. ' ' .. s.name or nil end)
      out.held = held or 'nothing'
      out.held_blocked=M.held_blocked(e)
      out.pickup_wait=M.pickup_wait(e)
      out.hand_wait=M.hand_wait(e)
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
  -- An inserter's wait for a full hand (d22 batch104 BN2, luna #1931: "Add wait_for_full_hand boolean to configure on
  -- inserters (built and ghosts) and return its live state from inspect"). In 2.0.77 it is InserterPrototype's
  -- wait_for_full_hand, set at data stage only (Space Age's stack-inserter: true; the default, false, for the other
  -- five), and there is no runtime key for it: on a copy of world n, LuaEntity (built or ghost), its control behavior
  -- and LuaEntityPrototype each refuse wait_for_full_hand and inserter_wait_for_full_hand, the GUI's locale has no such
  -- control, and a stack inserter's blueprint entry holds its name and position only. So it is read by prototype name
  -- from 2.0.77's data (nil for an inserter not among them), and a stack inserter holds what it took until its hand is
  -- full: on the copy, 3 plates from a chest held 5 s (status waiting_for_more_items) and 1 science pack bound for a lab
  -- held 4 s with the lab empty, where a bulk inserter moved them; its hand size override (configure hand_size) is the
  -- hand it waits for: at 3 it dropped the 3.
  M.WAIT_FOR_FULL_HAND = {['burner-inserter']=false, inserter=false, ['fast-inserter']=false, ['long-handed-inserter']=false,
    ['bulk-inserter']=false, ['stack-inserter']=true}
  M.WAIT_FOR_FULL_HAND_FACT = '2.0.77 has no per-inserter wait for a full hand: it is the prototype\'s wait_for_full_hand, fixed at data stage (no GUI control, no key on a built inserter, a ghost or a blueprint); of the six inserters only stack-inserter waits'
  local function inserter_kind(e)
    return e.type == 'inserter' or (e.type == 'entity-ghost' and try(function() return e.ghost_type end) == 'inserter')
  end
  function M.wait_for_full_hand(e)
    if not inserter_kind(e) then return nil end
    local name = e.type == 'entity-ghost' and try(function() return e.ghost_name end) or e.name
    return M.WAIT_FOR_FULL_HAND[name]
  end
  -- A built inserter that holds part of its hand and waits for more (status waiting_for_more_items): one line, or nil.
  function M.hand_wait(e)
    local waiting = try(function() return defines.entity_status.waiting_for_more_items end)
    if e.type ~= 'inserter' or not waiting or try(function() return e.status end) ~= waiting then return nil end
    local h = try(function() return e.held_stack end)
    local held = h and h.valid_for_read and h.count .. ' ' .. h.name or 'nothing'
    local hand = try(function() return e.inserter_target_pickup_count end)
    local full = M.wait_for_full_hand(e)
    return string.format('holds %s of a hand of %s and waits for more items%s', held, tostring(hand or '?'),
      full and ' (stack-inserter waits for a full hand: its prototype\'s wait_for_full_hand, fixed in 2.0.77; its hand size override, configure hand_size, is the hand it waits for)' or '')
  end
  -- configure wait_for_full_hand: the same as the inserter's own is read back (unchanged); the other is refused with
  -- what the game has.
  function M.configure_wait_for_full_hand(e, want)
    local ghost = e.type == 'entity-ghost'
    local name = ghost and e.ghost_name or e.name
    if not inserter_kind(e) then
      error(string.format('wait_for_full_hand applies to inserters (built or ghost); %s is a %s', name, tostring(ghost and e.ghost_type or e.type)), 0)
    end
    if type(want) ~= 'boolean' then error('wait_for_full_hand must be true or false', 0) end
    local fixed = M.wait_for_full_hand(e)
    if fixed == nil then error(string.format('%s is not one of 2.0.77\'s inserters, whose wait for a full hand is known here; %s', name, M.WAIT_FOR_FULL_HAND_FACT), 0) end
    if want ~= fixed then
      error(string.format('%s%s (%g,%g) %s: %s. %s', ghost and 'ghost of ' or '', name, e.position.x, e.position.y,
        fixed and 'waits for a full hand' or 'does not wait for a full hand', M.WAIT_FOR_FULL_HAND_FACT,
        fixed and 'A stack inserter waits for its hand size: configure hand_size N (or a circuit set stack size) makes the hand N; a bulk-inserter does not wait'
          or 'A stack-inserter waits until its hand is full'), 0)
    end
    return {wait_for_full_hand=fixed, wait_for_full_hand_before=fixed, unchanged=true,
      line=string.format('%s%s (%g,%g): wait for a full hand %s, as its prototype has it (%s)', ghost and 'ghost of ' or '', name, e.position.x, e.position.y,
        fixed and 'on' or 'off', M.WAIT_FOR_FULL_HAND_FACT)}
  end
  return M
end
