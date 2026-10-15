-- Settings on the entries of one place_ghosts or build call (Sol, shift13 19:50: a bio cell took about 10 configure and
-- wire round trips, and about 20 cells were built that shift; 00:23 UTC: one decider combinator built, then 4 wires,
-- 5 circuit_set and a requests call). An entry may carry:
--   configure {recipe, filters, filter_mode, use_filters, modules, ...}  as configure takes them
--   requests  {set, clear, ...}                                          as requests takes them (a chest, a pad)
--   circuit   {enable, read, settings, decider, arithmetic, signals, ...} as circuit_set takes them
--   wires     [{to {x,y}, color red|green, from_side?, to_side?}]         as wire takes them, from this entry
-- each without a position (the entry's). The call places every entry first, then sets them in entry order (configure,
-- requests, circuit), then the wires; the same platform or surface as the call. A ghost takes the settings and the
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
  function M.apply(p, entries, ctx, skip)
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
      if has(e) and not skip[i] and e.wires then
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
    return rows, line
  end
  M.schema_text = 'configure {recipe, filters, filter_mode, modules, ...} as configure takes them; requests {set, clear, ...} '
    .. 'as requests takes them; circuit {enable, read, settings, decider, arithmetic, signals, ...} as circuit_set takes them; '
    .. 'wires [{to {x,y}, color, from_side, to_side}] as wire takes them, from this entry; each without a position: set after '
    .. 'every entry is placed, in entry order, then the wires; a refusal is that row\'s and leaves the placement (settings rows, settings_line)'
  return M
end
