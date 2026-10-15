-- Settings on the entries of one place_ghosts or build call (Sol, shift13 19:50: a bio cell took about 10 configure and
-- wire round trips, and about 20 cells were built that shift; 00:23 UTC: one decider combinator built, then 4 wires,
-- 5 circuit_set and a requests call). An entry may carry:
--   configure {recipe, filters, filter_mode, use_filters, modules, ...}  as configure takes them
--   requests  {set, clear, ...}                                          as requests takes them (a chest, a pad)
--   circuit   {enable, read, settings, decider, arithmetic, signals, ...} as circuit_set takes them
--   wires     [{to {x,y}, color red|green, from_side?, to_side?}]         as wire takes them, from this entry
-- each without a position (the entry's). Hand builds set each entry immediately after placement. Ghost calls set
-- them after all placements. Wires follow the complete batch; the same platform or surface as the call. A ghost takes the settings and the
-- building it becomes keeps them. The argument names are checked before anything is placed; a setting the game
-- refuses is a row's error and leaves the placement in place.
return function(api)
  local M = {}
  local KINDS = {{'configure', 'configure'}, {'requests', 'requests'}, {'circuit', 'circuit_set'}}
  local MAX_WIRES = 16
  local WIRE_KEYS = {to=true, color=true, from_side=true, to_side=true, disconnect=true}
  local function has(e) return type(e) == 'table' and (e.configure ~= nil or e.requests ~= nil or e.circuit ~= nil or e.wires ~= nil) end
  function M.any(entries)
    for _, e in ipairs(type(entries) == 'table' and entries or {}) do if has(e) then return true end end
    return false
  end
  local function at(pos) return string.format('(%g,%g)', pos.x, pos.y) end
  -- settings, and settings keys at an entry's top level (Sol, d15 06:20: builds entries with settings {recipe, modules,
  -- circuit, requests, filters} returned success and set nothing, several refits): settings is taken as an alias,
  -- each key going where it belongs (recipe to the entry's recipe; circuit, requests, wires, configure to theirs;
  -- any other key into configure, whose argument check refuses an unknown name). A setting key at the entry's top
  -- level is refused with the corrected shape. Nothing is ignored silently.
  local SHAPE = '{item|name, position, direction?, recipe?, configure {recipe, modules, filters, filter_mode, use_filters, ...}, requests {set, ...}, circuit {enable, read, ...}, wires [{to, color}]}'
  local TOP = {modules='configure', filters='configure', filter_mode='configure', use_filters='configure', spoil_priority='configure',
    bar='configure', priority_targets='configure', circuit_condition='circuit', logistic_condition='circuit', enable='circuit',
    read='circuit', signals='circuit', decider='circuit', arithmetic='circuit', request_filters='requests', set='requests'}
  function M.normalize(entries, what)
    local moved = 0
    for i, e in ipairs(type(entries) == 'table' and entries or {}) do
      if type(e) == 'table' then
        local where = (what or 'entry') .. ' ' .. i
        for key, home in pairs(TOP) do
          if e[key] ~= nil then
            error(string.format('%s: %s is not an entry key; it goes in %s {%s = ...}: an entry is %s', where, key, home, key, SHAPE), 0)
          end
        end
        local st = e.settings
        if st ~= nil then
          assert(type(st) == 'table' and #st == 0, where .. ': settings is an object; an entry is ' .. SHAPE)
          local function into(kind, k, v)
            e[kind] = e[kind] or {}
            assert(type(e[kind]) == 'table', where .. ': ' .. kind .. ' is an object')
            assert(e[kind][k] == nil or e[kind][k] == v, where .. ': settings.' .. k .. ' conflicts with ' .. kind .. '.' .. k)
            e[kind][k] = v
          end
          for k, v in pairs(st) do
            if k == 'recipe' then
              assert(e.recipe == nil or e.recipe == v, where .. ': settings.recipe conflicts with recipe')
              e.recipe = v
            elseif k == 'circuit' or k == 'requests' or k == 'configure' then
              assert(type(v) == 'table', where .. ': settings.' .. k .. ' is an object')
              for k2, v2 in pairs(v) do into(k, k2, v2) end
            elseif k == 'wires' then
              assert(e.wires == nil, where .. ': settings.wires conflicts with wires')
              e.wires = v
            else
              into('configure', k, v)
            end
          end
          e.settings = nil
          moved = moved + 1
        end
      end
    end
    return moved
  end
  -- Before anything is placed: shapes and argument names.
  function M.check(entries, ctx)
    for i, e in ipairs(entries) do
      if has(e) then
        local where = 'entry ' .. i
        for _, k in ipairs(KINDS) do
          local v = e[k[1]]
          if v ~= nil then
            assert(type(v) == 'table' and next(v) ~= nil and #v == 0, where .. ': ' .. k[1] .. ' is an object of ' .. k[2] .. ' arguments')
            assert(v.position == nil and v.positions == nil and v.platform == nil and v.surface == nil,
              where .. ': ' .. k[1] .. ' takes the entry\'s position (and the call\'s platform or surface)')
            if k[1] == 'requests' and ctx.platform ~= nil then
              error(where .. ': requests on a platform entry: requests with platform is the hub\'s; set the hub\'s requests there', 0)
            end
            api.check(k[2], v)
          end
        end
        if e.wires ~= nil then
          assert(type(e.wires) == 'table' and #e.wires >= 1 and #e.wires <= MAX_WIRES, where .. ': wires is a list of 1..' .. MAX_WIRES .. ' {to, color, from_side?, to_side?}')
          for j, w in ipairs(e.wires) do
            local shape = where .. ' wire ' .. j .. ': {to {x,y}, color red|green, from_side?, to_side?} (from is the entry)'
            assert(type(w) == 'table' and w.to ~= nil and w.from == nil, shape)
            for key in pairs(w) do assert(WIRE_KEYS[key], shape .. '; unknown ' .. tostring(key)) end
            api.check('wire', {from=e.position, to=w.to, color=w.color, from_side=w.from_side, to_side=w.to_side, disconnect=w.disconnect})
          end
        end
      end
    end
  end
  local function with_ctx(args, pos, ctx)
    local out = {}
    for k, v in pairs(args) do out[k] = v end
    out.position = pos
    out.platform, out.surface = ctx.platform, ctx.surface
    return out
  end
  -- A dry run: what each entry would set.
  function M.plan(entries)
    local rows = {}
    for i, e in ipairs(entries) do
      if has(e) then
        local parts = {}
        for _, k in ipairs(KINDS) do
          if e[k[1]] then
            local keys = {}
            for key in pairs(e[k[1]]) do keys[#keys+1] = key end
            table.sort(keys)
            parts[#parts+1] = k[1] .. ' (' .. table.concat(keys, ', ') .. ')'
          end
        end
        if e.wires then parts[#parts+1] = #e.wires .. ' wire' .. (#e.wires > 1 and 's' or '') end
        rows[#rows+1] = {index=i, name=e.name or e.item, position=e.position, would_set=table.concat(parts, '; ')}
      end
    end
    return rows
  end
  -- After placing: the entries not skipped (failed, or still to be built) set in order, then the wires.
  -- Returns rows [{index, name, position, configure, requests, circuit, wires}] ('set' or the refusal) and a line.
  function M.apply(p, entries, ctx, skip, settings_only)
    local rows, set_n, failed = {}, 0, {}
    local by_index = {}
    for i, e in ipairs(entries) do
      if has(e) and not skip[i] then
        local pos = api.position(e.position)
        local row = {index=i, name=e.name or e.item, position=pos}
        for _, k in ipairs(KINDS) do
          if e[k[1]] then
            local ok, res = pcall(api.call, k[2], p, with_ctx(e[k[1]], pos, ctx))
            if ok then
              row[k[1]] = 'set'; set_n = set_n + 1
              if k[1] == 'configure' and type(res) == 'table' and res.line then row.configure = 'set: ' .. res.line end
            else
              row[k[1]] = api.reason(res); failed[#failed+1] = string.format('entry %d %s: %s', i, k[1], row[k[1]])
            end
          end
        end
        rows[#rows+1] = row
        by_index[i] = row
      end
    end
    for i, e in ipairs(entries) do
      if has(e) and not skip[i] and e.wires and not settings_only then
        local row = by_index[i]
        row.wires = {}
        for j, w in ipairs(e.wires) do
          local to = api.position(w.to)
          local args = {from=row.position, to=to, color=w.color, from_side=w.from_side, to_side=w.to_side, disconnect=w.disconnect,
            platform=ctx.platform, surface=ctx.surface}
          local ok, res = pcall(api.call, 'wire', p, args)
          local label = string.format('%s to %s', w.color or 'copper', at(to))
          if ok then
            local said = type(res) == 'table' and (res.connected == 'already' and 'already connected' or res.connected and 'connected'
              or res.disconnected and 'disconnected') or 'set'
            row.wires[j] = label .. ': ' .. said
            set_n = set_n + 1
          else
            row.wires[j] = label .. ': ' .. api.reason(res)
            failed[#failed+1] = string.format('entry %d wire %d: %s', i, j, api.reason(res))
          end
        end
      end
    end
    local line = string.format('settings: %d set', set_n) .. (#failed > 0 and string.format(', %d refused: %s', #failed,
      table.concat(failed, '; ', 1, math.min(4, #failed)) .. (#failed > 4 and '; ...' or '')) or '')
    return rows, line, {set=set_n,failed=failed}
  end
  -- Hand builds configure each placed entry in the same tick, before attempting
  -- the next placement. Only wires wait for their potentially later endpoints.
  function M.built(p, entry, index, batch)
    local rows,_,stats=M.apply(p,{entry},{},{},true)
    if rows[1] then
      rows[1].index=index
      batch.rows[#batch.rows+1]=rows[1]
      batch.set=batch.set+stats.set
      for _,why in ipairs(stats.failed) do batch.failed[#batch.failed+1]=why:gsub('entry 1 ', 'entry '..index..' ',1) end
      if entry.wires then batch.wires[#batch.wires+1]={entry=entry,row=rows[1]} end
    end
  end
  function M.built_result(p,batch,out,complete)
    if complete then
      for _,w in ipairs(batch.wires) do
        local e=w.entry
        local rows,_,stats=M.apply(p,{{position=e.position,wires=e.wires}},{},{})
        w.row.wires=rows[1].wires;batch.set=batch.set+stats.set
        for _,why in ipairs(stats.failed) do batch.failed[#batch.failed+1]=why:gsub('entry 1 ', 'entry '..w.row.index..' ',1) end
      end
      batch.wires={}
    end
    if #batch.rows>0 then
      out.settings=batch.rows
      out.settings_line='settings: '..batch.set..' set'..(#batch.failed>0 and ', '..#batch.failed..' refused: '..table.concat(batch.failed,'; ',1,math.min(4,#batch.failed)) or '')
      if not complete and #batch.wires>0 then out.settings_note=#batch.wires..' entries have wires pending until the batch finishes' end
    end
    return out
  end
  M.schema_text = 'configure {recipe, filters, filter_mode, modules, ...} as configure takes them; requests {set, clear, ...} '
    .. 'as requests takes them; circuit {enable, read, settings, decider, arithmetic, signals, ...} as circuit_set takes them; '
    .. 'wires [{to {x,y}, color, from_side, to_side}] as wire takes them, from this entry; each without a position: hand builds set each entry as placed; ghosts set after all placements; wires after the batch; a refusal is that row\'s and leaves the placement (settings rows, settings_line)'
  return M
end
