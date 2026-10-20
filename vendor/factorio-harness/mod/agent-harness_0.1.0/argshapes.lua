-- argshapes: the arguments that are lists of records, checked field by field in the schema check every call passes
-- through (runtime check_args), queue steps too (d17 batch35 A6, Muse: requests set with {count} for {min} became
-- 0..inf and fetched nothing, a 10-minute collector stall; Sol 14:20, twice: requests set with import_from for from
-- defaulted to nauvis, and circuit_set signals as an object for an array was read as no signals). A field a record
-- does not take is refused, naming the fields it takes; an object where a list goes, or a list entry that is not a
-- record, is refused with the shape expected. The fields are those each action's own parser reads.
return function()
  local M = {}
  -- {label, fields (in order; '?' optional), hint (for a field it does not take: what it may have meant)}
  local REQUEST = {label='request', fields={'item', 'min?', 'max?', 'quality?', 'from?', 'min_payload?', 'minimum_delivery_count?'},
    hint={count='min is how much it asks for, max caps it', name='item', import_from='from', amount='min', planet='from', import='from'}}
  local SIGNAL = {label='signal', fields={'signal', 'count', 'name?'}, hint={value='count', constant='count', min='count'}}
  local DROP_ITEM = {label='drop item', fields={'item', 'count?', 'quality?'}, hint={name='item', amount='count'}}
  local CARGO_ITEM = {label='cargo item', fields={'item', 'count', 'quality?', 'name?'}, hint={amount='count'}}
  -- An entry's settings (entryset.lua: configure, requests, circuit, wires, settings) and the setting keys it sends
  -- there, named in the refusal.
  local SETTING_HINTS = {modules='configure {modules = ...}', filters='configure {filters = ...}', filter_mode='configure {filter_mode = ...}',
    use_filters='configure {use_filters = ...}', spoil_priority='configure {spoil_priority = ...}', bar='configure {bar = ...}',
    priority_targets='configure {priority_targets = ...}', circuit_condition='circuit {circuit_condition = ...}',
    logistic_condition='circuit {logistic_condition = ...}', enable='circuit {enable = ...}', read='circuit {read = ...}',
    signals='circuit {signals = ...}', decider='circuit {decider = ...}', arithmetic='circuit {arithmetic = ...}',
    request_filters='requests {set = ...}', set='requests {set = ...}'}
  local function with(t, extra) local out = {}; for k, v in pairs(t) do out[k] = v end; for k, v in pairs(extra or {}) do out[k] = v end; return out end
  local BUILD = {label='build entry', fields={'item', 'position', 'direction?', 'quality?', 'type?', 'size?', 'entity?', 'recipe?', 'name?',
    'configure?', 'requests?', 'circuit?', 'wires?', 'settings?'}, hint=with(SETTING_HINTS, {count='one entry places one'})}
  local CRAFT = {label='recipe entry', fields={'recipe', 'count?', 'force?'}, hint={name='recipe', item='recipe', amount='count'}}
  local GHOST = {label='ghost entry', fields={'name', 'position', 'direction?', 'type?', 'recipe?', 'quality?', 'ammo?', 'item?',
    'configure?', 'requests?', 'circuit?', 'wires?', 'settings?'}, hint=SETTING_HINTS}
  local TRAIN_WAIT = {label='train wait', fields={'type', 'ticks?', 'compare?', 'condition?'}, hint={seconds='ticks (60 a second)', compare_type='compare'}}
  local TRAIN_STOP = {label='train stop record', fields={'station', 'wait?'}, hint={name='station', stop='station', waits='wait'},
    nested={wait={list=TRAIN_WAIT, groups=true, example='[{"type":"time","ticks":1800}]'}}}
  local DELIVER_ITEM = {label='item', fields={'name', 'count?', 'item?'}, hint={amount='count'}}
  local STOP = {label='stop', fields={'station', 'wait?', 'save_as?', 'wait_from?'}, hint={planet='station', name='station', waits='wait', conditions='wait'}}
  -- list: the record; map: an object of name = number also taken (the form the docs give); how many entries each
  -- handler takes is its own check
  M.SHAPES = {
    requests={set={list=REQUEST, map=true, example='[{"item":"iron-plate","min":100}]'}},
    circuit_set={signals={list=SIGNAL, example='[{"signal":"iron-plate","count":5}]'}},
    drop={items={list=DROP_ITEM, example='[{"item":"iron-plate","count":50}]'}},
    load_silo={items={list=CARGO_ITEM, map=true, example='[{"item":"low-density-structure","count":50}] or {"low-density-structure": 50}'}},
    silo_stage={items={list=CARGO_ITEM, map=true, example='[{"item":"low-density-structure","count":50}] or {"low-density-structure": 50}'}},
    build={builds={list=BUILD, example='[{"item":"transport-belt","position":{"x":1,"y":2},"direction":"north"}]'}},
    craft={recipes={list=CRAFT, example='[{"recipe":"iron-gear-wheel","count":10}]'}},
    place_ghosts={entities={list=GHOST, example='[{"name":"gun-turret","position":{"x":1,"y":2}}]'}},
    platform_schedule={stops={list=STOP, example='[{"station":"nauvis","wait":[{"type":"time","ticks":1800}]}]'}},
    train={schedule={list=TRAIN_STOP, example='[{"station":"Iron pickup","wait":[{"type":"full"}]}]'}},
    deliver={items={list=DELIVER_ITEM, map=true, scalar='string', example='{"coal": 50} or [{"name":"coal","count":50}]'}},
  }
  local function names(rec)
    local out = {}
    for i, f in ipairs(rec.fields) do out[i] = f end
    return table.concat(out, ', ')
  end
  local function takes(rec, k)
    for _, f in ipairs(rec.fields) do if f == k or f == k .. '?' then return true end end
    return false
  end
  local function shape_text(s) return string.format('an array of {%s}%s', names(s.list), s.map and ' or an object {name: count}' or '') end
  local check_list
  -- One record: its fields, then any nested list in it.
  local function check_record(where, r, rec, example)
    local bad = {}
    for k in pairs(r) do if type(k) ~= 'string' or not takes(rec, k) then bad[#bad+1] = tostring(k) end end
    if #bad > 0 then
      table.sort(bad)
      local hints = {}
      for _, k in ipairs(bad) do if rec.hint and rec.hint[k] then hints[#hints+1] = 'for ' .. k .. ': ' .. rec.hint[k] end end
      error(string.format('%s: %s %s not a %s field: %s%s', where, table.concat(bad, ', '), #bad == 1 and 'is' or 'are',
        rec.label, names(rec), #hints > 0 and ' (' .. table.concat(hints, '; ') .. ')' or ''), 0)
    end
    for k, sub in pairs(rec.nested or {}) do
      if r[k] ~= nil then check_list(where .. '.' .. k, r[k], sub) end
    end
  end
  function check_list(where, v, s)
    if s.scalar and type(v) == s.scalar then return end
    -- (d18 batch36 A3) a wait list given as any_of / all_of groups: waitgroups.lua reads it
    if s.groups and type(v) == 'table' and (v.any_of ~= nil or v.all_of ~= nil) then return end
    if type(v) ~= 'table' then
      error(string.format('%s must be %s: %s (not a %s)', where, shape_text(s), s.example, type(v)), 0)
    end
    local n, count = #v, 0
    for _ in pairs(v) do count = count + 1 end
    if count > 0 and n == 0 then
      -- an object: the map form where taken, else refused
      if not s.map then
        local keys = {}
        for k in pairs(v) do keys[#keys+1] = tostring(k) end
        table.sort(keys)
        error(string.format('%s must be %s: %s; an object {%s} is not read as one', where, shape_text(s), s.example,
          table.concat(keys, ', ', 1, math.min(4, #keys)) .. (#keys > 4 and ', ...' or '')), 0)
      end
      for k, c in pairs(v) do
        if type(c) ~= 'number' then
          error(string.format('%s as an object is {name: count}: %s is %s, not a count; or %s: %s', where, tostring(k), type(c), shape_text(s), s.example), 0)
        end
      end
      return
    end
    if count ~= n then error(string.format('%s must be %s: %s (a list with gaps or named keys is not one)', where, shape_text(s), s.example), 0) end
    for i, r in ipairs(v) do
      if type(r) ~= 'table' then
        error(string.format('%s[%d] must be a %s {%s}, not a %s: %s', where, i, s.list.label, names(s.list), type(r), s.example), 0)
      end
      check_record(string.format('%s[%d]', where, i), r, s.list, s.example)
    end
  end
  -- Raises with the shape expected; returns nothing when the args fit.
  function M.check(action, args)
    local shapes = M.SHAPES[action]
    if not shapes or type(args) ~= 'table' then return end
    for arg, s in pairs(shapes) do
      if args[arg] ~= nil then check_list(action .. ' ' .. arg, args[arg], s) end
    end
  end
  return M
end
