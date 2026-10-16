-- The circuit network, as a player works it: circuit_set changes what an
-- entity's circuit GUI holds (enable and logistic conditions, read switches
-- and modes, the signals it sends, combinator settings); wire connects and
-- removes red, green and copper wires; read (inspect, and the replies here)
-- gives back those settings, each wire's far end and the signals on each
-- network now. Reach as in the game (2.0): the character's reach, or remote
-- view on our own entities in a visible chunk (all of our own platforms).
-- Engine calls are guarded so a refusal comes back as a plain error.
return function(api)
  local M = {handlers={}}
  local COMPARATORS = {['<']=true, ['>']=true, ['=']=true, ['>=']=true, ['<=']=true, ['!=']=true, ['≥']=true, ['≤']=true, ['≠']=true}
  local ASCII = {['≥']='>=', ['≤']='<=', ['≠']='!='}
  local OPERATIONS = {['+']=true, ['-']=true, ['*']=true, ['/']=true, ['%']=true, ['^']=true, ['<<']=true, ['>>']=true, AND=true, OR=true, XOR=true}
  local SELECTOR_OPS = {select=true, count=true, random=true, ['stack-size']=true, ['rocket-capacity']=true, ['quality-filter']=true, ['quality-transfer']=true}
  local COMBINATOR = {['arithmetic-combinator']=true, ['decider-combinator']=true, ['selector-combinator']=true}
  local MAX_SIGNALS = 30
  -- What each kind of circuit GUI holds beyond the enable and logistic
  -- conditions (on_off: it has those), by the game's names (2.0.77 control
  -- behaviors): a switch (bool), a signal, a condition, or a mode (a define).
  local PROPS = {
    accumulator={output_signal='signal', read_charge='bool'},
    agricultural_tower={on_off=true, read_contents='bool'},
    arithmetic_combinator={},
    artillery_turret={on_off=true, read_ammo='bool'},
    assembling_machine={on_off=true, circuit_read_contents='bool', circuit_read_ingredients='bool', circuit_read_recipe_finished='bool', circuit_read_working='bool', circuit_recipe_finished_signal='signal', circuit_set_recipe='bool', circuit_working_signal='signal', include_fuel='bool', include_in_crafting='bool'},
    asteroid_collector={on_off=true, include_hands='bool', read_content='bool', set_filter='bool'},
    cargo_landing_pad={circuit_exclusive_mode_of_operation='control_behavior.cargo_landing_pad.exclusive_mode'},
    constant_combinator={},
    container={read_contents='bool'},
    decider_combinator={},
    display_panel={},
    furnace={on_off=true, circuit_read_contents='bool', circuit_read_ingredients='bool', circuit_read_recipe_finished='bool', circuit_read_working='bool', circuit_recipe_finished_signal='signal', circuit_working_signal='signal', include_fuel='bool', include_in_crafting='bool'},
    generic_on_off={on_off=true},
    inserter={on_off=true, circuit_hand_read_mode='control_behavior.inserter.hand_read_mode', circuit_read_hand_contents='bool', circuit_set_filters='bool', circuit_set_stack_size='bool', circuit_stack_control_signal='signal'},
    lamp={on_off=true, blue_signal='signal', color_mode='control_behavior.lamp.color_mode', green_signal='signal', red_signal='signal', rgb_signal='signal', use_colors='bool'},
    loader={on_off=true, circuit_read_transfers='bool', circuit_set_filters='bool'},
    logistic_container={circuit_condition='condition', circuit_condition_enabled='bool', circuit_exclusive_mode_of_operation='control_behavior.logistic_container.exclusive_mode'},
    mining_drill={on_off=true, circuit_read_resources='bool', resource_read_mode='control_behavior.mining_drill.resource_read_mode'},
    programmable_speaker={circuit_condition='condition'},
    proxy_container={read_contents='bool'},
    pump={on_off=true, set_filter='bool'},
    radar={},
    rail_chain_signal={blue_signal='signal', circuit_condition='condition', close_signal='bool', green_signal='signal', orange_signal='signal', read_signal='bool', red_signal='signal'},
    rail_signal={blue_signal='signal', circuit_condition='condition', close_signal='bool', green_signal='signal', orange_signal='signal', read_signal='bool', red_signal='signal'},
    reactor={read_fuel='bool', read_temperature='bool', temperature_signal='signal'},
    roboport={available_construction_output_signal='signal', available_logistic_output_signal='signal', read_items_mode='control_behavior.roboport.read_items_mode', read_robot_stats='bool', roboport_count_output_signal='signal', total_construction_output_signal='signal', total_logistic_output_signal='signal'},
    rocket_silo={read_mode='control_behavior.rocket_silo.read_mode'},
    selector_combinator={},
    space_platform_hub={damage_taken_signal='signal', read_contents='bool', read_damage_taken='bool', read_moving_from='bool', read_moving_to='bool', read_speed='bool', send_to_platform='bool', speed_signal='signal'},
    splitter={input_left_condition='condition', input_right_condition='condition', output_left_condition='condition', output_right_condition='condition', set_filter='bool', set_input_side='bool', set_output_side='bool'},
    storage_tank={read_contents='bool'},
    train_stop={on_off=true, priority_signal='signal', read_from_train='bool', read_stopped_train='bool', read_trains_count='bool', send_to_train='bool', set_priority='bool', set_trains_limit='bool', stopped_train_signal='signal', trains_count_signal='signal', trains_limit_signal='signal'},
    transport_belt={on_off=true, read_contents='bool', read_contents_mode='control_behavior.transport_belt.content_read_mode'},
    turret={on_off=true, ignore_unlisted_targets_condition='condition', read_ammo='bool', set_ignore_unlisted_targets='bool', set_priority_list='bool'},
    wall={circuit_condition='condition', open_gate='bool', output_signal='signal', read_sensor='bool'},
  }
  -- Item filter settings of inserters and loaders: set on the entity (configure's filters), not its circuit behavior.
  local FILTER_SETTINGS = {filters='filters', filter_mode='filter_mode', mode='filter_mode', use_filters='use_filters'}
  -- read's short names from before settings (each a switch above).
  local READ_ALIASES = {inserter={hand='circuit_read_hand_contents'}, transport_belt={contents='read_contents'}, mining_drill={resources='circuit_read_resources'}}
  -- Signal kinds and the prototype tables that hold their names.
  local SIGNAL_TYPES = {item='item', fluid='fluid', virtual='virtual_signal', entity='entity', recipe='recipe',
    ['space-location']='space_location', ['asteroid-chunk']='asteroid_chunk', quality='quality'}
  local PLAIN = {'item', 'fluid', 'virtual'}

  M.schema = {
    circuit_set = {position='{x,y}: in reach, or ours in a visible chunk (remote view)',
      platform='platform name: on that platform (all of it in remote view)',
      surface='planet or surface name (remote view, visible chunks)',
      enable='"ice < 300" or {signal, comparator, value|signal2}; false: off; on a logistic chest: its circuit condition (circuit_condition_enabled, circuit_condition: the GUI\'s Enable/disable)',
      set_requests='requester or buffer chest: true sets its requests from the wires (circuit_exclusive_mode_of_operation set_requests); false: none. Chests in 2.0.77: read: {contents: true} is send_contents on a requester or buffer; provider and storage chests send their contents whenever wired, with no switch; no chest has a logistic network condition. A roboport: read: {logistic_network_contents: true} is read_items_mode logistics (missing_requests: true the missing requests)',
      logistic='a condition as enable, on the logistic network (connects it); false: off. The game reads the network whose logistic area holds the entity\'s centre (circuit.logistic_reads names it and its count, or none: never met)',
      read='{switch: bool}: hand, contents, resources, speed, ammo, ... (read_X); train stop names',
      settings='{name: value}: any switch, mode, signal or condition by its readback name; inserters and loaders also filters (item names), filter_mode (whitelist|blacklist), use_filters, as configure sets them (reply filters: the line)',
      signals='constant combinator: [{signal, count}] (first section; [] clears)', on='constant combinator: on/off',
      arithmetic='{first, operation (+ - * / % ^ << >> AND OR XOR), second, output}',
      decider='{first, comparator, constant|second, output, copy_input} or {conditions, outputs}',
      selector='{operation (select|count|random|stack-size|...), its fields}',
      returns='entity, by (reach|remote view), circuit: the readback inspect shows'},
    wire = {from='{x,y} (or {position, name, unit_number}): in reach, or by remote view ours in a visible chunk',
      to='the other end, as from',
      color='red | green: a circuit wire; leave it out for copper (poles, power switches)',
      from_side='a combinator\'s input | output (default output); a power switch\'s left | right (copper)', to_side='as from_side (default input)',
      disconnect='boolean: remove the wire instead',
      platform='platform name: both ends on that platform (all of it in remote view)',
      surface='planet or surface name: both ends there by remote view',
      returns='color, connected (already) or disconnected, by (reach|remote view), from and to {entity, position, side, wires}, network; a refusal says why'},
  }

  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function int(v, what)
    if type(v) ~= 'number' or v ~= v then error(what .. ' must be a number', 0) end
    v = math.floor(v)
    if v < -2147483648 or v > 2147483647 then error(what .. ' is out of range (32-bit)', 0) end
    return v
  end
  local function proto(kind, name)
    local list = prototypes[SIGNAL_TYPES[kind]]
    return list ~= nil and list[name] ~= nil
  end
  -- A signal as written: "iron-plate", "water", "signal-A", "recipe:NAME",
  -- "iron-plate@rare", or {type, name, quality}.
  local function signal(v, what)
    local kind, name, quality
    if type(v) == 'table' then kind, name, quality = v.type, v.name, v.quality
    elseif type(v) == 'string' then
      name = v
      local at = name:find('@', 1, true)
      if at then quality = name:sub(at + 1); name = name:sub(1, at - 1) end
      local colon = name:find(':', 1, true)
      if colon then kind = name:sub(1, colon - 1); name = name:sub(colon + 1) end
    end
    if type(name) ~= 'string' or name == '' then error(what .. ' must be a signal name ("iron-plate", "water", "signal-A") or {type, name}', 0) end
    if kind ~= nil then
      if not SIGNAL_TYPES[kind] then error(what .. ': signal type ' .. tostring(kind) .. ' is not one of item, fluid, virtual, entity, recipe, space-location, asteroid-chunk, quality', 0) end
      if not proto(kind, name) then error(what .. ': no ' .. kind .. ' signal named ' .. name, 0) end
    else
      for _, k in ipairs(PLAIN) do if proto(k, name) then kind = k; break end end
      if not kind then error(what .. ': unknown signal ' .. name .. ' (an item, fluid or virtual signal such as signal-A; others as recipe:NAME, entity:NAME)', 0) end
    end
    if quality ~= nil and quality ~= 'normal' and not (type(quality) == 'string' and prototypes.quality and prototypes.quality[quality]) then
      error(what .. ': unknown quality ' .. tostring(quality), 0)
    end
    return {type=kind, name=name, quality=quality}
  end
  -- A signal read from the game as signal() reads it back (an item's type is nil).
  local function signal_text(s)
    if type(s) ~= 'table' or type(s.name) ~= 'string' then return nil end
    local kind = s.type or 'item'
    local first
    for _, k in ipairs(PLAIN) do if proto(k, s.name) then first = k; break end end
    local text = first == kind and s.name or kind .. ':' .. s.name
    local q = s.quality
    if type(q) ~= 'string' then q = try(function() return q.name end) end
    if type(q) == 'string' and q ~= 'normal' then text = text .. '@' .. q end
    return text
  end
  -- A condition: "iron-plate < 100", "signal-A >= signal-B", or {signal,
  -- comparator, value | signal2} ({first, constant | second} as in a decider row).
  local function condition(c, what)
    if type(c) == 'string' then
      local a, op, b = c:match('^%s*(%S+)%s+(%S+)%s+(%S+)%s*$')
      if not a then error(what .. ': a condition is "signal < 100" or "signal-A >= signal-B" (spaces around the comparator) or {signal, comparator, value | signal2}', 0) end
      local n = tonumber(b)
      c = {signal=a, comparator=op, value=n, signal2=(not n) and b or nil}
    end
    if type(c) ~= 'table' then error(what .. ' is a condition: "iron-plate < 100" or {signal, comparator, value | signal2}', 0) end
    local comparator = c.comparator or '<'
    if not COMPARATORS[comparator] then error(what .. ': comparator is one of < > = >= <= !=', 0) end
    local first = c.signal; if first == nil then first = c.first end
    local out = {first_signal=signal(first, what .. '.signal'), comparator=comparator}
    local second = c.signal2; if second == nil then second = c.second end
    if second ~= nil and type(second) ~= 'number' then out.second_signal = signal(second, what .. '.signal2')
    else
      local v = c.value; if v == nil then v = c.constant end; if v == nil then v = second end
      if type(v) ~= 'number' then error(what .. ': value (a number) or signal2 is required', 0) end
      out.constant = int(v, what .. '.value')
    end
    return out
  end
  local function condition_text(c)
    if type(c) ~= 'table' or type(c.first_signal) ~= 'table' or not c.first_signal.name then return nil end
    local right = c.second_signal and c.second_signal.name and signal_text(c.second_signal) or tostring(c.constant or 0)
    return string.format('%s %s %s', signal_text(c.first_signal), ASCII[c.comparator] or c.comparator or '<', right)
  end
  -- red | green | both, or {red, green}: which input networks a combinator reads.
  local function networks(v, what)
    if v == nil then return nil end
    if v == 'red' then return {red=true, green=false} elseif v == 'green' then return {red=false, green=true}
    elseif v == 'both' then return {red=true, green=true} end
    if type(v) == 'table' and (v.red == nil or type(v.red) == 'boolean') and (v.green == nil or type(v.green) == 'boolean') then
      return {red=v.red ~= false, green=v.green ~= false}
    end
    error(what .. ' is red, green or both', 0)
  end
  local function networks_text(n)
    if type(n) ~= 'table' then return nil end
    if n.red == false and n.green ~= false then return 'green' end
    if n.green == false and n.red ~= false then return 'red' end
    if n.red == false and n.green == false then return 'none' end
  end
  local function define(path)
    local t = defines
    for part in path:gmatch('[^.]+') do t = t and t[part] end
    return t
  end
  local function define_name(path, v)
    for name, n in pairs(define(path) or {}) do if n == v then return name end end
    return v
  end
  local CB_TYPES
  local function kind_of(cb)
    if not CB_TYPES then
      CB_TYPES = {}
      for name, v in pairs((defines.control_behavior or {}).type or {}) do CB_TYPES[v] = name end
    end
    return CB_TYPES[try(function() return cb.type end) or false]
  end
  -- A kind's settings; a kind not in PROPS that has the enable switch takes enable and logistic.
  local function props_of(cb, kind)
    if PROPS[kind] then return PROPS[kind] end
    return try(function() return cb.circuit_enable_disable end) ~= nil and {on_off=true} or {}
  end
  local function names(t)
    local list = {}
    for n in pairs(t) do if n ~= 'on_off' then list[#list+1] = n end end
    table.sort(list)
    return list
  end
  -- {name, count} rows, largest first, at most MAX_SIGNALS (more: the rest).
  local function signal_rows(list)
    local rows = {}
    for _, s in ipairs(list or {}) do
      local text = s.signal and signal_text(s.signal)
      if text and s.count and s.count ~= 0 then rows[#rows+1] = {name=text, count=s.count} end
    end
    table.sort(rows, function(x, y)
      if math.abs(x.count) ~= math.abs(y.count) then return math.abs(x.count) > math.abs(y.count) end
      return x.name < y.name
    end)
    local more = #rows - MAX_SIGNALS
    for i = #rows, MAX_SIGNALS + 1, -1 do rows[i] = nil end
    return rows, more > 0 and more or nil
  end

  -- Wires --------------------------------------------------------------------
  local COLORS
  local function color_of(c)
    if not COLORS then COLORS = {}; for name, v in pairs(defines.wire_type or {}) do COLORS[v] = name end end
    return COLORS[try(function() return c.wire_type end) or false]
  end
  local function etype(e) return e.type == 'entity-ghost' and try(function() return e.ghost_type end) or e.type end
  local function proto_of(e) return e.type == 'entity-ghost' and try(function() return e.ghost_prototype end) or try(function() return e.prototype end) end
  -- Wires a player draws (radar and script wires are not drawn).
  local function player_origin() return defines.wire_origin and defines.wire_origin.player end
  -- A connector's side: a combinator's input or output, a power switch's left or right.
  local function side_of(e, id)
    local W = defines.wire_connector_id
    local t = etype(e)
    if COMBINATOR[t] then
      if id == W.combinator_output_red or id == W.combinator_output_green then return 'output' end
      return 'input'
    elseif t == 'power-switch' then
      if id == W.power_switch_left_copper then return 'left' end
      if id == W.power_switch_right_copper then return 'right' end
    end
  end
  local function far_end(t)
    local o = t.owner
    local ghost = o.type == 'entity-ghost'
    return {entity=ghost and o.ghost_name or o.name, position=o.position, side=side_of(o, t.wire_connector_id), ghost=ghost or nil}
  end
  -- A connector's far ends, as a player sees the wires (radar and script wires are not drawn).
  local function far_ends(c)
    local rows = {}
    for _, w in pairs(try(function() return c.connections end) or {}) do
      if w.target and (w.origin == nil or w.origin == player_origin()) then
        local ok, row = pcall(far_end, w.target)
        if ok then rows[#rows+1] = row end
      end
    end
    table.sort(rows, function(x, y)
      if x.position.x ~= y.position.x then return x.position.x < y.position.x end
      if x.position.y ~= y.position.y then return x.position.y < y.position.y end
      return (x.side or '') < (y.side or '')
    end)
    return rows
  end
  local function connector_key(e, id, c)
    local color = color_of(c)
    if not color then return nil end
    local side = side_of(e, id)
    return side and color .. '_' .. side or color
  end
  -- wires {red, green, copper (or red_input, ... copper_left)}: each far end;
  -- networks {key: {id, signals, more}}: the signals on each circuit network now.
  local function wires_of(e)
    local list = try(function() return e.get_wire_connectors(false) end)
    if type(list) ~= 'table' then return nil, nil end
    local wires, nets = {}, {}
    for id, c in pairs(list) do
      local key = connector_key(e, id, c)
      if key then
        local rows = far_ends(c)
        if #rows > 0 then wires[key] = rows end
        if key:sub(1, 6) ~= 'copper' then
          local net = try(function() return e.get_circuit_network(id) end)
          if net then
            local rows2, more = signal_rows(try(function() return net.signals end))
            nets[key] = {id=try(function() return net.network_id end), signals=rows2, more=more}
          end
        end
      end
    end
    return next(wires) and wires or nil, next(nets) and nets or nil
  end

  -- Read-back ----------------------------------------------------------------
  local function arithmetic_view(p)
    if type(p) ~= 'table' then return nil end
    local first = p.first_signal and p.first_signal.name and signal_text(p.first_signal) or p.first_constant or 0
    local second = p.second_signal and p.second_signal.name and signal_text(p.second_signal) or p.second_constant or 0
    local output = p.output_signal and signal_text(p.output_signal)
    return {first=first, operation=p.operation or '*', second=second, output=output,
      first_networks=networks_text(p.first_signal_networks), second_networks=networks_text(p.second_signal_networks),
      text=string.format('%s %s %s -> %s', tostring(first), p.operation or '*', tostring(second), output or 'nothing')}
  end
  local function decider_view(p)
    if type(p) ~= 'table' then return nil end
    local conds, outs = {}, {}
    for i, c in ipairs(p.conditions or {}) do
      local text = condition_text(c) or 'blank'
      local nets = {networks_text(c.first_signal_networks), networks_text(c.second_signal_networks)}
      if nets[1] or nets[2] then text = text .. ' [' .. (nets[1] or 'both') .. ',' .. (nets[2] or 'both') .. ']' end
      conds[i] = i > 1 and (c.compare_type or 'or') .. ' ' .. text or text
    end
    for i, o in ipairs(p.outputs or {}) do
      local name = signal_text(o.signal) or 'blank'
      local text = name .. ' = ' .. (o.copy_count_from_input ~= false and 'input' or tostring(o.constant or 1))
      local n = networks_text(o.networks)
      outs[i] = n and text .. ' [' .. n .. ']' or text
    end
    return {conditions=conds, outputs=outs}
  end
  local function selector_view(p)
    if type(p) ~= 'table' then return nil end
    local out = {}
    for k, v in pairs(p) do
      if type(v) == 'table' and v.name and k:find('signal') then out[k] = signal_text(v)
      elseif type(v) ~= 'table' then out[k] = v end
    end
    if type(p.quality_filter) == 'table' then
      local q = p.quality_filter.quality
      out.quality_filter = (ASCII[p.quality_filter.comparator] or p.quality_filter.comparator or '=') .. ' ' .. tostring(type(q) == 'table' and q.name or q)
    end
    return out
  end
  -- The logistic network a logistic condition reads: the game takes the one
  -- whose logistic area holds the entity's centre, so a machine partly inside
  -- an area reads none (Astra 10:27, world n: foundries at (29.5,-51.5) and
  -- (36.5,-49.5) stayed off under "iron-plate < 3000" and "steel-plate < 1500"
  -- while the inserter at (30.5,-48.5), inside roboport (44,-24)'s area, read
  -- network 8). With its count of the condition's item; with none, the nearest
  -- roboport's logistic area.
  local function logistic_reads(e, c)
    local pos = e.position
    local net = try(function() return e.force.find_logistic_network_by_position(pos, e.surface) end)
    local first = type(c) == 'table' and c.first_signal or nil
    if net then
      local text = 'network ' .. tostring(try(function() return net.network_id end) or '?') .. ' (its logistic area holds the centre)'
      if type(first) == 'table' and first.name and (first.type == nil or first.type == 'item') then
        local n = try(function() return net.get_item_count({name=first.name, quality=first.quality or 'normal'}) end)
        if type(n) == 'number' then
          text = text .. string.format(': %s %d', first.name, n) .. (n < 0 and ' (the count less what deliveries have reserved)' or '')
        end
      end
      return text
    end
    local best, bd
    local list = try(function() return e.surface.find_entities_filtered{type='roboport', force=e.force, position=pos, radius=80, limit=64} end)
    for _, r in ipairs(list or {}) do
      local lr = try(function() return r.logistic_cell.logistic_radius end)
      if type(lr) == 'number' and lr > 0 then
        local d = math.max(math.abs(pos.x - r.position.x) - lr, math.abs(pos.y - r.position.y) - lr)
        if not bd or d < bd then best, bd = r, d end
      end
    end
    local text = string.format('none: no logistic area holds its centre (%g,%g), so the condition reads no network and is not met', pos.x, pos.y)
    if best then
      local id = try(function() return best.logistic_cell.logistic_network.network_id end)
      text = text .. string.format('; the nearest, roboport (%g,%g)%s, ends %g tile%s from it', best.position.x, best.position.y,
        id and (' of network ' .. id) or '', bd, bd == 1 and '' or 's')
    end
    return text
  end
  -- What the entity's circuit GUI shows now; nil without a control behavior
  -- (cb nil: the entity's own, never created by a read) or a wire.
  local SEG = 400
  function M.belt_segment(e)
    local lines = {}
    for k = 1, 2 do lines[k] = try(function() return e.get_transport_line(k) end) end
    local held, tiles = {}, 0
    local function count(b)
      for k = 1, 2 do
        for _, c in ipairs(try(function() return b.get_transport_line(k).get_contents() end) or {}) do
          local n = type(c.name) == 'string' and c.name or try(function() return c.name.name end)
          if n then held[n] = (held[n] or 0) + c.count end
        end
      end
    end
    local function same(b)
      local l = lines[1] and try(function() return b.get_transport_line(1) end)
      return l and try(function() return l.line_equals(lines[1]) end) == true
    end
    local function where(b) return string.format('%s (%g,%g)', b.name, b.position.x, b.position.y) end
    local ends = {}
    count(e); tiles = 1
    for _, way in ipairs({'inputs', 'outputs'}) do
      local cur, steps, stop = e, 0, nil
      while steps < SEG do
        local bn = try(function() return cur.belt_neighbours end)
        local nxt
        for _, o in ipairs(bn and bn[way] or {}) do if same(o) then nxt = o end end
        if not nxt and cur.type == 'underground-belt' then
          local pair = try(function() return cur.neighbours end)
          if pair and pair.valid and same(pair) then nxt = pair end
        end
        if not nxt then
          local others = bn and bn[way] or {}
          if #others > 0 then stop = string.format('at %s, where %s %s on another line', where(cur), where(others[1]), way == 'inputs' and 'feeds it' or 'takes from it')
          elseif cur.type == 'underground-belt' then stop = string.format('at %s (an underground; past it is not this line)', where(cur))
          else stop = string.format('at %s (the belt %s there)', where(cur), way == 'inputs' and 'starts' or 'ends') end
          break
        end
        cur = nxt; steps = steps + 1; tiles = tiles + 1; count(cur)
      end
      ends[#ends+1] = (way == 'inputs' and 'back ' or 'on ') .. (stop or string.format('past %d tiles (not read further)', SEG))
    end
    -- What the wires read now.
    local wired = {}
    for _, w in ipairs({defines.wire_connector_id.circuit_red, defines.wire_connector_id.circuit_green}) do
      local net = try(function() return e.get_circuit_network(w) end)
      for _, sg in ipairs(net and try(function() return net.signals end) or {}) do
        local n = sg.signal and sg.signal.name
        if n then wired[n] = (wired[n] or 0) + (sg.count or 0) end
      end
    end
    local parts, diff = {}, {}
    for n, c in pairs(held) do
      parts[#parts+1] = c .. ' ' .. n
      if next(wired) and (wired[n] or 0) ~= c then diff[#diff+1] = string.format('%s %d on the wires', n, wired[n] or 0) end
    end
    table.sort(parts)
    return string.format('this tile\'s line runs %d tiles: %s; it holds %s%s', tiles, table.concat(ends, ', '),
      #parts > 0 and table.concat(parts, ', ') or 'nothing', #diff > 0 and ' (the wires read: ' .. table.concat(diff, ', ') .. ', which includes anything else on those networks)' or '')
  end
  function M.read(e, cb)
    if cb == nil then cb = try(function() return e.get_control_behavior() end) end
    local wires, nets = wires_of(e)
    if not cb and not wires then return nil end
    local out = {wires=wires, networks=nets}
    if not cb then out.settings_note = 'no circuit settings changed from the game defaults'; return out end
    local kind = kind_of(cb)
    local props = props_of(cb, kind)
    if props.on_off then
      local enabled = try(function() return cb.circuit_enable_disable end)
      if enabled then
        local c = try(function() return cb.circuit_condition end)
        out.enable = condition_text(c) or 'blank'
        -- (false too: an unmet condition read as nil was dropped from the reply)
        if type(c) == 'table' then out.enable_met = c.fulfilled end
        -- No red or green wire: the game ignores a circuit condition, and the entity runs (Astra 21:00: a fast
        -- inserter on Fulgora with enable EM < 0 and no wire read disabled and kept working).
        if not nets and e.type ~= 'entity-ghost' then out.enable_ignored = 'no red or green wire connects it: the game ignores this condition' end
      else out.enable = false end
      local logistic = try(function() return cb.connect_to_logistic_network end)
      if logistic then
        local c = try(function() return cb.logistic_condition end)
        out.logistic = condition_text(c) or 'blank'
        if type(c) == 'table' then out.logistic_met = c.fulfilled end
        out.logistic_reads = logistic_reads(e, c)
      else out.logistic = false end
      out.disabled = try(function() return cb.disabled end) or nil
    end
    local settings, off = {}, {}
    for _, name in ipairs(names(props)) do
      local k = props[name]
      local v = try(function() return cb[name] end)
      if k == 'bool' then if v then settings[name] = true elseif v == false then off[#off+1] = name end
      elseif k == 'signal' then settings[name] = signal_text(v)
      elseif k == 'condition' then settings[name] = condition_text(v)
      elseif v ~= nil then settings[name] = define_name(k, v) end
    end
    out.settings = next(settings) and settings or nil
    out.off = #off > 0 and off or nil
    -- A belt reading its entire belt (Astra, d15: the read missed a segment past an underground): the run of belts the
    -- engine joins into this tile's lines (each way, up to SEG tiles), what ends it each way, and what that run holds
    -- against what the wires read now.
    if kind == 'transport_belt' and settings.read_contents and settings.read_contents_mode == 'entire_belt_hold' then
      out.belt_segment = M.belt_segment(e)
    end
    if kind == 'constant_combinator' then
      out.on = try(function() return cb.enabled end)
      local list, groups, inactive = {}, {}, 0
      for _, section in ipairs(try(function() return cb.sections end) or {}) do
        local group = try(function() return section.group end)
        if type(group) == 'string' and group ~= '' then groups[#groups+1] = group end
        -- An inactive section sends nothing (its signals are not listed).
        if try(function() return section.active end) == false then inactive = inactive + 1
        else
          local filters = try(function() return section.filters end) or {}
          local slots = {}
          for i in pairs(filters) do if type(i) == 'number' then slots[#slots+1] = i end end
          table.sort(slots)
          for _, i in ipairs(slots) do
            local v = filters[i].value
            if type(v) == 'table' and v.name then
              local text = signal_text({type=v.type, name=v.name, quality=v.quality})
              if text then list[#list+1] = {name=text, count=filters[i].min or 0} end
            end
          end
        end
      end
      out.signals = list
      out.sections = try(function() return cb.sections_count end)
      out.inactive_sections = inactive > 0 and inactive or nil
      out.groups = #groups > 0 and groups or nil
    elseif kind == 'arithmetic_combinator' then out.arithmetic = arithmetic_view(try(function() return cb.parameters end))
    elseif kind == 'decider_combinator' then out.decider = decider_view(try(function() return cb.parameters end))
    elseif kind == 'selector_combinator' then out.selector = selector_view(try(function() return cb.parameters end)) end
    if COMBINATOR[etype(e)] then
      local rows, more = signal_rows(try(function() return cb.signals_last_tick end))
      out.output, out.output_more = rows, more
    end
    return out
  end

  -- Access -------------------------------------------------------------------
  local function reach(p, e)
    local ok, r = pcall(function() return p.can_reach_entity(e) end)
    return ok and r == true
  end
  local function in_view(p, pos)
    if api.own_platform(p) then return true end
    return try(function() return p.force.is_chunk_visible(p.surface, {x=math.floor(pos.x / 32), y=math.floor(pos.y / 32)}) end) == true
  end
  -- The entity at t ({x,y} or {position, name, unit_number}) as a player
  -- gets at it: in the character's reach, else by remote view: ours, in a
  -- visible chunk (anywhere on our own platform). Returns it and how.
  local function target(p, t, what)
    if type(t) ~= 'table' then error(what .. ' requires an entity position {x,y}', 0) end
    local args = {position=t.position or t, name=t.name, unit_number=t.unit_number}
    local ok, e = pcall(api.entity, p, args, true)
    if not ok then
      local ok2, far = pcall(api.remote_entity, p, args)
      if not ok2 then
        local pos = try(function() return api.position(args.position) end)
        if pos and not in_view(p, pos) then
          error(string.format("%s: (%g,%g) on %s is out of reach and not in a visible chunk (remote view needs radar coverage there)",
            what, pos.x, pos.y, tostring(try(function() return p.surface.name end))), 0)
        end
        -- Past the character's 32 tiles, what remote view found (or did not).
        local err = tostring(e)
        if err:find('outside local visible area', 1, true) then err = tostring(far) end
        error(what .. ': ' .. err:gsub('^[^:]*:%d+: ', ''), 0)
      end
      e = far
    end
    api.friendly(p, e)
    if reach(p, e) then return e, 'reach' end
    if e.force ~= p.force then error(string.format('%s: %s at (%g,%g) is out of reach, and remote view works only on our own entities', what, e.name, e.position.x, e.position.y), 0) end
    if not in_view(p, e.position) then
      error(string.format('%s: %s at (%g,%g) is out of reach and not in a visible chunk (remote view needs radar coverage there)', what, e.name, e.position.x, e.position.y), 0)
    end
    return e, 'remote view'
  end
  local function guarded(what, fn)
    local ok, err = pcall(fn)
    if not ok then error(what .. ': ' .. tostring(err):gsub('^[^:]*:%d+: ', ''), 0) end
  end

  -- circuit_set ----------------------------------------------------------------
  local function behavior(e)
    local cb = try(function() return e.get_or_create_control_behavior() end)
    if not cb then
      error(string.format('%s has no circuit connection: the game gives it no circuit wires or circuit settings', e.name), 0)
    end
    return cb
  end
  local function settings_list(kind, props)
    local list = names(props)
    if props.on_off then table.insert(list, 1, 'enable, logistic') end
    if kind == 'inserter' then list[#list+1] = 'filters, filter_mode, use_filters' elseif kind == 'loader' then list[#list+1] = 'filters' end
    if kind == 'constant_combinator' then list[#list+1] = 'signals, on' end
    if kind == 'arithmetic_combinator' or kind == 'decider_combinator' or kind == 'selector_combinator' then list[#list+1] = kind:gsub('_combinator', '') end
    return #list > 0 and table.concat(list, ', ') or 'none'
  end
  -- A fast replace keeps the old entity's circuit settings, as the game's does (Sol 10:50: ~12 feeders rebuilt by
  -- hand after inserter -> fast inserter): the control behavior's kind and every setting it holds, read before the
  -- old one goes (snapshot) and set on the new one of the same kind (restore: names kept and names refused).
  function M.snapshot(e)
    local cb = try(function() return e.get_control_behavior() end)
    if not cb then return nil end
    local kind = kind_of(cb)
    local props = props_of(cb, kind)
    local values = {}
    local function keep(name) local v = try(function() return cb[name] end); if v ~= nil then values[name] = v end end
    if props.on_off then
      for _, n in ipairs({'circuit_enable_disable', 'circuit_condition', 'connect_to_logistic_network', 'logistic_condition'}) do keep(n) end
    end
    for _, n in ipairs(names(props)) do keep(n) end
    return {kind=kind, values=values}
  end
  function M.restore(e, snap)
    if not snap or not next(snap.values) then return {}, {} end
    local cb = try(function() return e.get_or_create_control_behavior() end)
    if not cb or kind_of(cb) ~= snap.kind then return {}, {'circuit settings (another kind of control)'} end
    local kept, refused = {}, {}
    local keys = {}
    for n in pairs(snap.values) do keys[#keys+1] = n end
    table.sort(keys)
    for _, n in ipairs(keys) do
      local ok = pcall(function() cb[n] = snap.values[n] end)
      if ok then kept[#kept+1] = n else refused[#refused+1] = n end
    end
    return kept, refused
  end
  -- circuit_set's arguments for this entity (an unknown argument's reply names them).
  function M.takes(e)
    local cb = try(function() return e.get_control_behavior() or e.get_or_create_control_behavior() end)
    if not cb then return 'nothing: it has no circuit connection' end
    local kind = kind_of(cb)
    local props = props_of(cb, kind)
    local list = {}
    if props.on_off then list[#list+1] = 'enable, logistic' end
    for _, n in ipairs(names(props)) do if props[n] == 'bool' then list[#list+1] = 'read'; break end end
    list[#list+1] = 'settings (' .. settings_list(kind, props) .. ')'
    if kind == 'constant_combinator' then list[#list+1] = 'signals, on' end
    if kind == 'arithmetic_combinator' or kind == 'decider_combinator' or kind == 'selector_combinator' then list[#list+1] = (kind:gsub('_combinator', '')) end
    return table.concat(list, ', ')
  end
  local function setting(kind, props, name, v, e)
    local k = props[name]
    if not k or name == 'on_off' then
      error(string.format('settings: %s is not a circuit setting of %s (its settings: %s)', tostring(name), e.name, settings_list(kind, props)), 0)
    end
    local what = 'settings.' .. name
    if k == 'bool' then
      if type(v) ~= 'boolean' then error(what .. ' must be boolean', 0) end
      return v
    elseif k == 'signal' then
      if v == false then return nil end
      return signal(v, what)
    elseif k == 'condition' then
      if v == false then return nil end
      return condition(v, what)
    end
    local values = define(k)
    if type(v) ~= 'string' or not values or values[v] == nil then
      local opts = {}
      for n in pairs(values or {}) do opts[#opts+1] = n end
      table.sort(opts)
      error(what .. ' is one of ' .. table.concat(opts, ', '), 0)
    end
    return values[v]
  end
  local function decider_params(x)
    if type(x) ~= 'table' then error('decider is {first, comparator, constant | second, output, copy_input} or {conditions, outputs}', 0) end
    local conds, outs = {}, {}
    if x.conditions ~= nil or x.outputs ~= nil then
      if type(x.conditions) ~= 'table' or #x.conditions < 1 or type(x.outputs) ~= 'table' or #x.outputs < 1 then
        error('decider: conditions and outputs are lists of one or more', 0)
      end
      for i, c in ipairs(x.conditions) do
        local what = 'decider.conditions ' .. i
        local row = condition(c, what)
        local t = type(c) == 'table' and c or {}
        if t.compare ~= nil and t.compare ~= 'and' and t.compare ~= 'or' then error(what .. ': compare is and or or', 0) end
        row.compare_type = t.compare or 'or'
        row.first_signal_networks = networks(t.first_networks, what .. '.first_networks')
        row.second_signal_networks = networks(t.second_networks, what .. '.second_networks')
        conds[i] = row
      end
      for i, o in ipairs(x.outputs) do
        local what = 'decider.outputs ' .. i
        if type(o) == 'string' then o = {signal=o, copy_input=true} end
        if type(o) ~= 'table' then error(what .. ' is {signal, copy_input, constant, networks}', 0) end
        outs[i] = {signal=signal(o.signal, what .. '.signal'), copy_count_from_input=o.copy_input == true,
          constant=o.constant ~= nil and int(o.constant, what .. '.constant') or nil, networks=networks(o.networks, what .. '.networks')}
      end
    else
      conds[1] = condition({signal=x.first, comparator=x.comparator, value=x.constant, signal2=x.second}, 'decider')
      outs[1] = {signal=signal(x.output, 'decider.output'), copy_count_from_input=x.copy_input == true}
    end
    return {conditions=conds, outputs=outs}
  end
  local function arithmetic_params(x)
    if type(x) ~= 'table' then error('arithmetic is {first, operation, second, output}', 0) end
    local op = x.operation or '*'
    if not OPERATIONS[op] then error('arithmetic.operation is one of + - * / % ^ << >> AND OR XOR', 0) end
    local params = {operation=op, output_signal=signal(x.output, 'arithmetic.output'),
      first_signal_networks=networks(x.first_networks, 'arithmetic.first_networks'),
      second_signal_networks=networks(x.second_networks, 'arithmetic.second_networks')}
    if type(x.first) == 'number' then params.first_constant = int(x.first, 'arithmetic.first')
    else params.first_signal = signal(x.first, 'arithmetic.first') end
    local second = x.second
    if second == nil then second = x.constant end
    if second == nil then error('arithmetic: second (a signal or a number) is required', 0) end
    if type(second) == 'number' then params.second_constant = int(second, 'arithmetic.second')
    else params.second_signal = signal(second, 'arithmetic.second') end
    return params
  end
  local function selector_params(x)
    if type(x) ~= 'table' then error('selector is {operation, ...}', 0) end
    local op = x.operation or 'select'
    if not SELECTOR_OPS[op] then error('selector.operation is one of select, count, random, stack-size, rocket-capacity, quality-filter, quality-transfer', 0) end
    local params = {operation=op}
    for k, v in pairs(x) do
      if k ~= 'operation' then
        if k:find('_signal$') then params[k] = signal(v, 'selector.' .. k)
        elseif k == 'index_constant' or k == 'random_update_interval' then params[k] = int(v, 'selector.' .. k)
        elseif k == 'quality_filter' then
          if type(v) ~= 'table' then error('selector.quality_filter is {quality, comparator}', 0) end
          params[k] = {quality=v.quality, comparator=v.comparator or '='}
        else params[k] = v end
      end
    end
    return params
  end
  local function constant_filters(list)
    if type(list) ~= 'table' or #list > 20 then error('signals takes 0..20 {signal, count}', 0) end
    local filters = {}
    for i, s in ipairs(list) do
      if type(s) ~= 'table' or type(s.count) ~= 'number' then error('signals ' .. i .. ' needs signal and count', 0) end
      local id = signal(s.signal or s.name, 'signals ' .. i)
      filters[i] = {value={type=id.type, name=id.name, quality=id.quality or 'normal', comparator='='}, min=int(s.count, 'signals ' .. i .. '.count')}
    end
    return filters
  end
  -- The entity's circuit GUI, changed as a player changes it there: every
  -- argument is checked first, then the changes apply in order; the reply
  -- reads back what the game holds.
  -- Chests and roboports in the words agents use (Sol, Luna, d15 06:20: read contents on provider and requester
  -- chests and an enable condition on a requester were refused). What 2.0.77 has (LuaLogisticContainerControlBehavior):
  -- circuit_exclusive_mode_of_operation send_contents | set_requests | none, which the game lets be set only on
  -- requester and buffer chests (the GUI's Read contents / Set requests); a circuit condition with
  -- circuit_condition_enabled (the GUI's Enable/disable). Provider and storage chests send their contents whenever
  -- wired, with no switch. No chest has a logistic network condition. A roboport reads its network's items with
  -- read_items_mode logistics (or missing_requests).
  local CHEST_NO_LOGISTIC = 'no logistic network condition on any chest in 2.0.77 (a chest\'s circuit settings: read contents or set requests, requester and buffer only, and an enable condition)'
  local function chest_words(e, kind, a)
    if kind ~= 'logistic_container' and kind ~= 'roboport' then return a, nil end
    local b, notes = {}, {}
    for k, v in pairs(a) do b[k] = v end
    local st = {}
    for k, v in pairs(type(a.settings) == 'table' and a.settings or {}) do st[k] = v end
    if kind == 'roboport' then
      if type(a.read) == 'table' then
        local r = {}
        for k, v in pairs(a.read) do
          if k == 'logistic_network_contents' or k == 'items' or k == 'contents' or k == 'logistics' then
            st.read_items_mode = v and 'logistics' or 'none'
          elseif k == 'missing_requests' then st.read_items_mode = v and 'missing_requests' or 'none'
          else r[k] = v end
        end
        b.read = next(r) and r or nil
      end
      b.settings = next(st) and st or nil
      return b, nil
    end
    local proto = e.type == 'entity-ghost' and try(function() return e.ghost_prototype end) or try(function() return e.prototype end)
    local mode = try(function() return proto.logistic_mode end) or '?'
    local requests = mode == 'requester' or mode == 'buffer'
    if a.logistic ~= nil then error('logistic: ' .. e.name .. ' has ' .. CHEST_NO_LOGISTIC, 0) end
    if a.enable ~= nil then
      b.enable = nil
      if a.enable == false then st.circuit_condition_enabled = false
      else st.circuit_condition_enabled = true; st.circuit_condition = a.enable end
      notes[#notes+1] = 'enable is the chest\'s circuit condition (circuit_condition_enabled, circuit_condition: the GUI\'s Enable/disable)'
    end
    if type(a.read) == 'table' then
      local r = {}
      for k, v in pairs(a.read) do
        if k == 'contents' or k == 'read_contents' then
          if requests then st.circuit_exclusive_mode_of_operation = v and 'send_contents' or 'none'
          elseif v == true then notes[#notes+1] = e.name .. ' sends its contents to the wires whenever wired: 2.0.77 has no switch for it (Read contents and Set requests are requester and buffer settings)'
          else error('read.contents: ' .. e.name .. ' sends its contents whenever wired; 2.0.77 has no switch to stop it (only requester and buffer chests have Read contents / Set requests)', 0) end
        else r[k] = v end
      end
      b.read = next(r) and r or nil
    end
    if a.set_requests ~= nil then
      if type(a.set_requests) ~= 'boolean' then error('set_requests must be true or false', 0) end
      if not requests then error('set_requests: ' .. e.name .. ' is a ' .. mode .. ' chest; 2.0.77 lets only requester and buffer chests set requests from the wires', 0) end
      st.circuit_exclusive_mode_of_operation = a.set_requests and 'set_requests' or 'none'
      b.set_requests = nil
    end
    b.settings = next(st) and st or nil
    return b, #notes > 0 and notes or nil
  end
  function M.handlers.circuit_set(p, a)
    local e, by = target(p, a, 'target')
    local cb = behavior(e)
    local kind = kind_of(cb)
    local props = props_of(cb, kind)
    local chest_notes
    a, chest_notes = chest_words(e, kind, a)
    -- A ghost by what it builds (its own name is entity-ghost): it takes the same settings (Astra 12:20).
    local ghost = e.type == 'entity-ghost'
    local steps, out = {}, {entity=ghost and try(function() return e.ghost_name end) or e.name, ghost=ghost or nil, position=e.position, by=by}
    local function step(what, fn) steps[#steps+1] = {what=what, fn=fn} end
    local function refuse(arg, text) error(string.format('%s: %s %s (its circuit settings: %s)', arg, e.name, text, settings_list(kind, props)), 0) end
    if a.enable ~= nil then
      if not props.on_off then refuse('enable', 'has no enable condition') end
      if a.enable == false then step('enable', function() cb.circuit_enable_disable = false end)
      else
        local c = condition(a.enable, 'enable')
        step('enable', function() cb.circuit_enable_disable = true; cb.circuit_condition = c end)
      end
    end
    if a.logistic ~= nil then
      if not props.on_off then refuse('logistic', 'has no logistic condition') end
      if a.logistic == false then step('logistic', function() cb.connect_to_logistic_network = false end)
      else
        local c = condition(a.logistic, 'logistic')
        step('logistic', function() cb.connect_to_logistic_network = true; cb.logistic_condition = c end)
      end
    end
    if a.read ~= nil then
      local aliases, short = READ_ALIASES[kind] or {}, {}
      for k in pairs(aliases) do short[#short+1] = k end
      for _, n in ipairs(names(props)) do if props[n] == 'bool' then short[#short+1] = n end end
      if #short == 0 then refuse('read', 'has no read switches') end
      -- read: true names no switch (round1650d: Sol's script stopped at "read is {switch: boolean}"): the ones it has.
      if type(a.read) ~= 'table' then
        table.sort(short)
        error(string.format('read is {switch: boolean}: %s has %s, e.g. read: {"%s": true}', e.name, table.concat(short, ', '), short[1]), 0)
      end
      out.read = {}
      for k, v in pairs(a.read) do
        local prop
        for _, n in ipairs({aliases[k] or '', tostring(k), 'read_' .. tostring(k), 'circuit_read_' .. tostring(k)}) do
          if props[n] == 'bool' then prop = n; break end
        end
        if not prop then
          table.sort(short)
          error('read: ' .. tostring(k) .. ' is not a switch of ' .. e.name .. ' (' .. table.concat(short, ', ') .. ')', 0)
        end
        if type(v) ~= 'boolean' then error('read.' .. k .. ' must be boolean', 0) end
        step('read.' .. k, function() cb[prop] = v end)
        out.read[k] = v
      end
    end
    if a.settings ~= nil then
      if type(a.settings) ~= 'table' then error('settings is {name: value}', 0) end
      local keys = {}
      for k in pairs(a.settings) do keys[#keys+1] = tostring(k) end
      table.sort(keys)
      -- An inserter's or loader's item filters, as configure sets them (Sonnet 06:20).
      local filters = {}
      for _, k in ipairs(keys) do
        if FILTER_SETTINGS[k] and (kind == 'inserter' or kind == 'loader') then filters[FILTER_SETTINGS[k]] = a.settings[k]
        else
          local v = setting(kind, props, k, a.settings[k], e)
          step('settings.' .. k, function() cb[k] = v end)
        end
      end
      if next(filters) then
        step('settings.filters', function() out.filters = api.configure_filters(e, filters).line end)
      end
    end
    if a.signals ~= nil or a.on ~= nil then
      if kind ~= 'constant_combinator' then refuse(a.signals ~= nil and 'signals' or 'on', 'is no constant combinator') end
      if a.on ~= nil then
        if type(a.on) ~= 'boolean' then error('on must be boolean', 0) end
        step('on', function() cb.enabled = a.on end)
      end
      if a.signals ~= nil then
        local filters = constant_filters(a.signals)
        step('signals', function()
          local section = (cb.sections_count or 0) > 0 and cb.get_section(1) or cb.add_section()
          section.filters = filters
        end)
      end
    end
    if a.arithmetic ~= nil then
      if kind ~= 'arithmetic_combinator' then refuse('arithmetic', 'is no arithmetic combinator') end
      local params = arithmetic_params(a.arithmetic)
      step('arithmetic', function() cb.parameters = params end)
    end
    if a.decider ~= nil then
      if kind ~= 'decider_combinator' then refuse('decider', 'is no decider combinator') end
      local params = decider_params(a.decider)
      step('decider', function() cb.parameters = params end)
    end
    if a.selector ~= nil then
      if kind ~= 'selector_combinator' then refuse('selector', 'is no selector combinator') end
      local params = selector_params(a.selector)
      step('selector', function() cb.parameters = params end)
    end
    local done = {}
    for _, s in ipairs(steps) do
      local ok, err = pcall(s.fn)
      if not ok then
        error(string.format('%s: the game refused it: %s%s', s.what, tostring(err):gsub('^[^:]*:%d+: ', ''),
          #done > 0 and ' (applied before it: ' .. table.concat(done, ', ') .. ')' or ''), 0)
      end
      done[#done+1] = s.what
    end
    out.circuit = M.read(e, cb)
    out.notes = chest_notes
    M.held_off(e, cb, out, a)
    return out
  end
  -- After a write: an entity with an enable or logistic condition that is off because one is not met (friction2:
  -- Opus set "production-science-pack < 1000" on an inserter whose logistic condition "< 100" read 101, and told Astra
  -- it ran; it stayed off 10.8 min). Read on a private copy of world n: a condition's fulfilled is current the tick it
  -- is written, the behavior's disabled only the tick after; so disabled is read from the conditions, and stays_disabled
  -- names the one that is not met (the CLI puts it on the warning line).
  function M.held_off(e, cb, out, a)
    local c = out.circuit
    if out.ghost or not (c and (c.enable_met ~= nil or c.logistic_met ~= nil)) then return end
    local held = {}
    -- An enable condition with no circuit wire holds nothing (the game ignores it): said instead.
    if c.enable and c.enable_ignored then
      out.condition_ignored = string.format('%s (%g,%g): its circuit condition %s is ignored: no red or green wire connects it, and the game counts a circuit condition only with a circuit connection',
        out.entity, e.position.x, e.position.y, c.enable)
    end
    if c.enable and c.enable_met == false and not c.enable_ignored then
      local cond = try(function() return cb.circuit_condition end)
      local first = type(cond) == 'table' and cond.first_signal
      local n = first and try(function() return e.get_signal(first, defines.wire_connector_id.circuit_red, defines.wire_connector_id.circuit_green) end)
      held[#held+1] = string.format('its circuit condition %s is not met%s%s', c.enable, type(n) == 'number' and string.format(' (%s reads %d on its wires)', signal_text(first), n) or '',
        a.enable == nil and ' (not set by this call)' or '')
    end
    if c.logistic and c.logistic_met == false then
      held[#held+1] = string.format('its logistic condition %s is not met%s%s', c.logistic, c.logistic_reads and ' (' .. c.logistic_reads .. ')' or '',
        a.logistic == nil and ' (not set by this call)' or '')
    end
    c.disabled = #held > 0 or nil
    if #held > 0 then
      out.stays_disabled = string.format('%s (%g,%g): %s', out.entity, e.position.x, e.position.y, table.concat(held, '; '))
    end
  end

  -- wire -----------------------------------------------------------------------
  local CIRCUIT = {red={input='combinator_input_red', output='combinator_output_red', plain='circuit_red'},
    green={input='combinator_input_green', output='combinator_output_green', plain='circuit_green'}}
  -- The connector of entity e for a wire color (nil: copper) and side.
  local function connector(e, key, color, side, default_side)
    local W = defines.wire_connector_id
    local t = etype(e)
    local id
    if color then
      local d = try(function() return proto_of(e).get_max_circuit_wire_distance(e.quality) end)
      if d == 0 then error(string.format('%s: %s takes no %s circuit wire (it has no circuit connection)', key, e.name, color), 0) end
      if COMBINATOR[t] then
        local s = side or default_side
        if s ~= 'input' and s ~= 'output' then error(key .. '_side is input or output', 0) end
        id = W[CIRCUIT[color][s]]
      else
        if side ~= nil then error(key .. '_side applies to combinators only (and power switches for copper)', 0) end
        id = W[CIRCUIT[color].plain]
      end
    elseif t == 'electric-pole' then
      if side ~= nil then error(key .. '_side: a pole has one copper connector', 0) end
      id = W.pole_copper
    elseif t == 'power-switch' then
      if side ~= 'left' and side ~= 'right' then error(key .. '_side is left or right on a power switch', 0) end
      id = side == 'left' and W.power_switch_left_copper or W.power_switch_right_copper
    else
      error(string.format('%s: %s takes no copper wire (poles and power switches do; with color red or green, a circuit wire)', key, e.name), 0)
    end
    local ok, c = pcall(e.get_wire_connector, id, true)
    if not (ok and c) then error(string.format('%s: %s takes no %s%s', key, e.name, color and color .. ' circuit wire' or 'copper wire', side and ' on its ' .. side .. ' side' or ''), 0) end
    return c
  end
  local function end_view(e, c, id)
    return {entity=e.type == 'entity-ghost' and e.ghost_name or e.name, position=e.position, side=side_of(e, id), ghost=e.type == 'entity-ghost' or nil, wires=far_ends(c)}
  end
  local function span(fe, te, color)
    local d = math.sqrt((fe.position.x - te.position.x) ^ 2 + (fe.position.y - te.position.y) ^ 2)
    local function reach_of(e)
      return try(function()
        if color then return proto_of(e).get_max_circuit_wire_distance(e.quality) end
        return proto_of(e).get_max_wire_distance(e.quality)
      end)
    end
    local a, b = reach_of(fe), reach_of(te)
    local r = a and b and math.min(a, b) or a or b
    return string.format('%.1f tiles apart%s', d, r and string.format(', the wire reaches %g', r) or '')
  end
  -- A wire between two entities as a player drags one: red or green between
  -- circuit connections, copper (no color) between poles and power switch
  -- sides; the wire must span the distance.
  function M.wire(p, a)
    local color = a.color
    if color ~= nil and color ~= 'red' and color ~= 'green' then error('color is red or green (copper: leave color out)', 0) end
    local fe, fby = target(p, a.from, 'from')
    local te, tby = target(p, a.to, 'to')
    local from = connector(fe, 'from', color, a.from_side, 'output')
    local to = connector(te, 'to', color, a.to_side, 'input')
    local fid, tid = try(function() return from.wire_connector_id end), try(function() return to.wire_connector_id end)
    if fe == te and (fid == tid or from == to) then error(etype(fe) == 'electric-pole' and 'from and to are the same pole' or 'from and to are the same connector', 0) end
    local by = (fby == 'reach' and tby == 'reach') and 'reach' or 'remote view'
    local out = {color=color or 'copper', by=by}
    if a.disconnect then
      local gone
      guarded('disconnect', function() gone = from.disconnect_from(to) end)
      out.disconnected = gone == true
      if not color then out.split = fe.electric_network_id ~= te.electric_network_id end
    elseif from.is_connected_to(to) then
      out.connected, out.already = true, true
    else
      if not from.can_wire_reach(to) then
        error(string.format('a %s wire does not reach between %s (%g,%g) and %s (%g,%g): %s', color or 'copper', fe.name, fe.position.x, fe.position.y,
          te.name, te.position.x, te.position.y, span(fe, te, color)), 0)
      end
      local ok
      guarded('connect', function() ok = from.connect_to(to, false, player_origin()) end)
      if not ok then error('the game refused the ' .. (color or 'copper') .. ' wire' .. (color and '' or ' (a pole takes at most 5 copper wires)'), 0) end
      out.connected = true
    end
    out.from, out.to = end_view(fe, from, fid), end_view(te, to, tid)
    out.network = try(function() return color and from.network_id or fe.electric_network_id end)
    return out
  end
  return M
end
