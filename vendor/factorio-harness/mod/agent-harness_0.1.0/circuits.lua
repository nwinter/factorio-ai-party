-- The circuit network, as a player works it: red and green wires between
-- entities (wire color=red|green; copper stays in runtime's wire), and the
-- settings of a machine's circuit/logistic connection GUI: an enable
-- condition, a logistic-network condition, a constant combinator's signals,
-- an arithmetic or decider combinator's parameters. Engine calls are guarded
-- so a refusal comes back as a plain error.
return function(api)
  local M = {handlers={}}
  local COMPARATORS = {['<']=true, ['>']=true, ['=']=true, ['>=']=true, ['<=']=true, ['!=']=true, ['≥']=true, ['≤']=true, ['≠']=true}
  local OPERATIONS = {['+']=true, ['-']=true, ['*']=true, ['/']=true, ['%']=true, ['^']=true, ['<<']=true, ['>>']=true, AND=true, OR=true, XOR=true}
  M.schema = {
    circuit = {position='{x,y} of the entity in reach',
      enable='a condition {signal, comparator (< > = >= <= !=), value | signal2}: the entity works only while it holds (inserters, belts, lamps, pumps, drills, power switches, train stops...); false switches the condition off',
      logistic='a condition as enable, read from the logistic network the entity sits in (connects it); false disconnects',
      signals='constant combinator: array of 0..20 {signal, count} (replaces its first section); [] clears',
      on='constant combinator: boolean on/off switch',
      arithmetic='arithmetic combinator: {first (signal), operation (+ - * / % ^ << >> AND OR XOR), second (signal) | constant, output (signal)}',
      decider='decider combinator: {first (signal), comparator, constant | second (signal), output (signal), copy_input (boolean: output the input count, else 1)}',
      returns='what the entity now holds: enable/logistic conditions, signals, parameters (read back from the game). Signals are item, fluid or virtual signal names ("iron-plate", "water", "signal-A") or {type, name}'},
  }
  -- A signal name as a SignalID: items, then fluids, then virtual signals.
  local function signal(v, what)
    if type(v) == 'table' and type(v.name) == 'string' then
      assert(v.type == nil or v.type == 'item' or v.type == 'fluid' or v.type == 'virtual', what .. ': type is item, fluid or virtual')
      return {type=v.type or 'item', name=v.name}
    end
    assert(type(v) == 'string', what .. ' must be a signal name ("iron-plate", "water", "signal-A")')
    if prototypes.item[v] then return {type='item', name=v} end
    if prototypes.fluid and prototypes.fluid[v] then return {type='fluid', name=v} end
    if prototypes.virtual_signal and prototypes.virtual_signal[v] then return {type='virtual', name=v} end
    error(what .. ': unknown signal ' .. v .. ' (an item, fluid or virtual signal such as signal-A)', 0)
  end
  local function condition(c, what)
    assert(type(c) == 'table', what .. ' is {signal, comparator, value | signal2}')
    local comparator = c.comparator or '<'
    assert(COMPARATORS[comparator], what .. ': comparator is one of < > = >= <= !=')
    local out = {first_signal=signal(c.signal, what .. '.signal'), comparator=comparator}
    if c.signal2 ~= nil then out.second_signal = signal(c.signal2, what .. '.signal2')
    else
      assert(type(c.value) == 'number', what .. ': value (a number) or signal2 is required')
      out.constant = math.floor(c.value)
    end
    return out
  end
  local function behavior(e)
    local ok, cb = pcall(e.get_or_create_control_behavior)
    assert(ok and cb, e.name .. ' has no circuit connection')
    return cb
  end
  local function guarded(what, fn)
    local ok, err = pcall(fn)
    if not ok then error(what .. ': ' .. tostring(err), 0) end
  end
  local function text(c)
    if type(c) ~= 'table' or not c.first_signal then return nil end
    local right = c.second_signal and c.second_signal.name or tostring(c.constant or 0)
    return string.format('%s %s %s', c.first_signal.name or '?', c.comparator or '<', right)
  end
  function M.handlers.circuit(p, a)
    local e = api.entity(p, a); api.friendly(p, e)
    local out = {entity=e.name, position=e.position}
    local cb = behavior(e)
    if a.enable ~= nil then
      if a.enable == false then guarded('enable', function() cb.circuit_enable_disable = false end)
      else
        local c = condition(a.enable, 'enable')
        guarded('enable', function() cb.circuit_enable_disable = true; cb.circuit_condition = c end)
      end
    end
    if a.logistic ~= nil then
      if a.logistic == false then guarded('logistic', function() cb.connect_to_logistic_network = false end)
      else
        local c = condition(a.logistic, 'logistic')
        guarded('logistic', function() cb.connect_to_logistic_network = true; cb.logistic_condition = c end)
      end
    end
    if a.signals ~= nil or a.on ~= nil then
      assert(e.type == 'constant-combinator', 'signals and on are for a constant combinator')
      if a.on ~= nil then assert(type(a.on) == 'boolean', 'on must be boolean'); guarded('on', function() cb.enabled = a.on end) end
      if a.signals ~= nil then
        assert(type(a.signals) == 'table' and #a.signals <= 20, 'signals takes 0..20 {signal, count}')
        local filters = {}
        for i, s in ipairs(a.signals) do
          assert(type(s) == 'table' and type(s.count) == 'number', 'signals ' .. i .. ' needs signal and count')
          local id = signal(s.signal, 'signals ' .. i)
          filters[i] = {value={type=id.type, name=id.name, quality='normal', comparator='='}, min=math.floor(s.count)}
        end
        guarded('signals', function()
          local section = (cb.sections_count or 0) > 0 and cb.get_section(1) or cb.add_section()
          section.filters = filters
        end)
      end
    end
    if a.arithmetic ~= nil then
      assert(e.type == 'arithmetic-combinator', 'arithmetic is for an arithmetic combinator')
      local x = a.arithmetic
      assert(type(x) == 'table' and OPERATIONS[x.operation or '*'], 'arithmetic.operation is one of + - * / % ^ << >> AND OR XOR')
      local params = {first_signal=signal(x.first, 'arithmetic.first'), operation=x.operation or '*', output_signal=signal(x.output, 'arithmetic.output')}
      if x.second ~= nil then params.second_signal = signal(x.second, 'arithmetic.second')
      else assert(type(x.constant) == 'number', 'arithmetic: constant or second is required'); params.second_constant = math.floor(x.constant) end
      guarded('arithmetic', function() cb.parameters = params end)
    end
    if a.decider ~= nil then
      assert(e.type == 'decider-combinator', 'decider is for a decider combinator')
      local x = a.decider
      local c = condition({signal=x.first, comparator=x.comparator, value=x.constant, signal2=x.second}, 'decider')
      local params = {conditions={c}, outputs={{signal=signal(x.output, 'decider.output'), copy_count_from_input=x.copy_input == true}}}
      guarded('decider', function() cb.parameters = params end)
    end
    -- Read back what the game holds now.
    pcall(function()
      if cb.circuit_enable_disable then out.enable = text(cb.circuit_condition) end
      if cb.connect_to_logistic_network then out.logistic = text(cb.logistic_condition) end
    end)
    if e.type == 'constant-combinator' then
      pcall(function()
        out.on = cb.enabled
        local section = (cb.sections_count or 0) > 0 and cb.get_section(1)
        local list = {}
        for _, f in ipairs(section and section.filters or {}) do
          if f.value and f.value.name then list[#list+1] = {signal=f.value.name, count=f.min} end
        end
        out.signals = list
      end)
    elseif e.type == 'arithmetic-combinator' or e.type == 'decider-combinator' then
      pcall(function() out.parameters = cb.parameters end)
    end
    return out
  end
  -- wire color=red|green: a circuit wire between two entities in reach, as a
  -- player drags one. Combinators have an input and an output side
  -- (from_side/to_side: input|output; default output on the source, input
  -- on the target).
  local SIDE = {red={input='combinator_input_red', output='combinator_output_red', plain='circuit_red'},
    green={input='combinator_input_green', output='combinator_output_green', plain='circuit_green'}}
  local COMBINATOR = {['arithmetic-combinator']=true, ['decider-combinator']=true, ['selector-combinator']=true}
  local function connector(p, t, key, color, side, default_side)
    assert(type(t) == 'table', key .. ' requires an entity position {x,y}')
    local e = api.entity(p, {position=t.position or t, name=t.name, unit_number=t.unit_number}); api.friendly(p, e)
    local id
    if COMBINATOR[e.type] then
      local s = side or default_side
      assert(s == 'input' or s == 'output', key .. '_side is input or output')
      id = SIDE[color][s]
    else
      assert(side == nil, key .. '_side applies to combinators only')
      id = SIDE[color].plain
    end
    local ok, c = pcall(e.get_wire_connector, defines.wire_connector_id[id], true)
    assert(ok and c, e.name .. ' takes no ' .. color .. ' circuit wire')
    return c, e
  end
  function M.wire(p, a)
    local color = a.color
    assert(color == 'red' or color == 'green', 'color is red or green (copper: leave color out)')
    local from, fe = connector(p, a.from, 'from', color, a.from_side, 'output')
    local to, te = connector(p, a.to, 'to', color, a.to_side, 'input')
    assert(from ~= to, 'from and to are the same connector')
    if a.disconnect then return {color=color, disconnected=from.disconnect_from(to)} end
    if from.is_connected_to(to) then return {color=color, connected=true, already=true} end
    assert(from.can_wire_reach(to), 'a ' .. color .. ' wire does not reach between ' .. fe.name .. ' and ' .. te.name)
    assert(from.connect_to(to, false), 'the game refused the ' .. color .. ' wire')
    return {color=color, connected=true, from=fe.name, to=te.name}
  end
  return M
end
