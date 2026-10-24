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
      enable='"ice < 300" or {signal, comparator, value|signal2}; on a logistic chest: its circuit condition (circuit_condition_enabled, circuit_condition: the GUI\'s Enable/disable). false is refused (two things): switch_off or remove_condition',
      switch_off='true: a circuit condition that never holds (signal-dot < -2147483648): the entity stops while a red or green wire connects it (the game counts a circuit condition only then); the reply\'s now says what it does',
      remove_condition='true: no circuit condition (the GUI\'s Enable/disable off): the entity runs whatever its wires read; the reply\'s now says what it does',
      set_requests='requester or buffer chest: true sets its requests from the wires (circuit_exclusive_mode_of_operation set_requests); false: none. Chests in 2.0.77: read: {contents: true} is send_contents on a requester or buffer; provider and storage chests send their contents whenever wired, with no switch; no chest has a logistic network condition. A roboport: read: {logistic_network_contents: true} is read_items_mode logistics (missing_requests: true the missing requests)',
      logistic='a condition as enable, on the logistic network (connects it); false: off. The game reads the network whose logistic area holds the entity\'s centre (circuit.logistic_reads names it and its count, or none: never met)',
      read='{switch: bool}: hand, contents, resources, speed, ammo, ... (read_X); train stop names',
      settings='{name: value}: any switch, mode, signal or condition by its readback name; inserters and loaders also filters (item names), filter_mode (whitelist|blacklist), use_filters, as configure sets them (reply filters: the line). A belt\'s read_contents_mode (with read_contents: true): pulse (each item as it enters this tile), hold (what this tile holds now), entire_belt_hold (what its belt segment holds, as the game counts it: through corners, undergrounds and tier changes, and along the main line past a side-load; a belt side-loading onto another ends its own segment, and a splitter ends one; inspect\'s circuit.belt_segment lists it with the wires\' read)',
      signals='constant combinator: [{signal, count, quality?}] (first section; [] clears). A signal anywhere in circuit_set (these, conditions, decider and arithmetic, selector, signal settings) is "name", "name@quality" ("iron-plate@uncommon"), "type:name@quality" or {type?, name, quality?}; a quality is one our force has unlocked; left out it is normal. A decider output takes quality too',
      description='an arithmetic, decider, selector or constant combinator (or its ghost): the description its GUI shows (LuaEntity.combinator_description), up to 500 bytes, newlines kept; "" or false clears it; reads show it as description; blueprints keep it',
      on='constant combinator: on/off',
      arithmetic='{first, operation (+ - * / % ^ << >> AND OR XOR), second, output}',
      decider='{first, comparator, constant|second, output, copy_input} or {conditions, outputs}: conditions rows "carbon < 150" (a row after the first begins with and / or: "and sulfur < 100"), {signal, comparator, value|signal2, compare: and|or (compare_type too), first_networks, second_networks: red|green|both}, or the game\'s own rows {first_signal, comparator, constant|second_signal, compare_type}; a row after the first must say and or or; outputs {signal, copy_input: true (the input count) | constant N, networks}; the read shows each row\'s networks and each output as copy or constant',
      selector='{operation (select|count|random|stack-size|...), its fields}',
      returns='entity, by (reach|remote view), circuit: the readback inspect shows; unwired (a warning): a setting of this call that acts on a signal (an enable condition, set filters, set stack size, set recipe, set requests, set trains limit ...) on an entity or ghost no red or green wire connects, and what the game does then (in 2.0.77 an enable condition is ignored and the entity runs; set filters, stack size, recipe and requests keep the entity\'s own)'},
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
  -- The force whose unlocked qualities a signal's quality is checked against, as the GUI's quality picker offers only
  -- those (set by circuit_set, its dry run and speaker_alert; nil: any quality the game has).
  local qforce
  local function unlocked(name)
    if not qforce then return true end
    local ok, v = pcall(function() return qforce.is_quality_unlocked(name) end)
    return not ok or v ~= false
  end
  local function qualities_text()
    local list = {}
    for name, q in pairs(prototypes.quality) do
      if not q.hidden and unlocked(name) then list[#list+1] = {q.level or 0, name} end
    end
    table.sort(list, function(x, y) return x[1] < y[1] end)
    for i, x in ipairs(list) do list[i] = x[2] end
    return table.concat(list, ', ')
  end
  -- A quality as written ("rare"); normal or nil as given.
  local function quality_of(q, what)
    if q == nil or q == 'normal' then return q end
    if type(q) ~= 'string' or not prototypes.quality[q] then
      error(what .. ': unknown quality ' .. tostring(q) .. ' (' .. qualities_text() .. ')', 0)
    end
    if not unlocked(q) then
      error(what .. ': quality ' .. q .. ' is not unlocked (unlocked: ' .. qualities_text() .. ')', 0)
    end
    return q
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
    return {type=kind, name=name, quality=quality_of(quality, what)}
  end
  -- A record's own quality ({signal, quality, count}; a decider output {signal, quality, ...}) put on its signal; one
  -- the signal says too ("name@rare", {name, quality}) must be the same.
  local function signal_q(v, q, what)
    local id = signal(v, what)
    if q ~= nil then
      q = quality_of(q, what .. '.quality')
      if id.quality ~= nil and id.quality ~= q then
        error(string.format('%s: quality %s and the signal\'s %s differ', what, q, id.quality), 0)
      end
      id.quality = q
    end
    return id
  end
  local function qname(q)
    if type(q) == 'string' then return q end
    return q and try(function() return q.name end) or 'normal'
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
  -- (d24 batch136 PH1, Sol #2104: a decider's red network 1258 carried 242 signals; inspect listed 30 and circuit_audit
  -- 24, so signal-R could not be read, nor its absence told from the cut) signals named: 1..MAX_PICKED names as
  -- conditions take them ("signal-R", "calcite", "iron-plate@rare", "recipe:NAME", {type, name, quality}), each read on
  -- a network by the game's own count (get_signal: 0 when absent, as the network's hover shows), whatever the cap.
  M.MAX_PICKED = 32
  function M.parse_signals(v, what)
    what = what or 'signals'
    if type(v) == 'string' then
      local list = {}
      for part in v:gmatch('[^|,]+') do local t = part:match('^%s*(.-)%s*$'); if t ~= '' then list[#list+1] = t end end
      v = list
    end
    if type(v) == 'table' and (v.name or v.type) then v = {v} end
    if type(v) ~= 'table' or #v < 1 or #v > M.MAX_PICKED then
      error(string.format('%s: 1..%d signal names (a list, or one string with | or ,)', what, M.MAX_PICKED), 0)
    end
    local out, seen = {}, {}
    for i, x in ipairs(v) do
      local id = signal(x, string.format('%s[%d]', what, i))
      local text = signal_text(id) or id.name
      if not seen[text] then seen[text] = true; out[#out+1] = {id=id, text=text} end
    end
    return out
  end
  -- [{name, count}] of each signal picked on a LuaCircuitNetwork, in the order asked.
  function M.picked_counts(net, picks)
    local rows = {}
    for i, pk in ipairs(picks) do rows[i] = {name=pk.text, count=try(function() return net.get_signal(pk.id) end) or 0} end
    return rows
  end
  function M.picked_text(rows)
    local parts = {}
    for i, r in ipairs(rows) do parts[i] = r.name .. ' ' .. r.count end
    return table.concat(parts, ', ')
  end
  -- wires {red, green, copper (or red_input, ... copper_left)}: each far end;
  -- networks {key: {id, signals, more, picked}}: the signals on each circuit network now (picked: the signals named).
  local function wires_of(e, picks)
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
            nets[key] = {id=try(function() return net.network_id end), signals=rows2, more=more, picked=picks and M.picked_counts(net, picks) or nil}
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
      -- networks said for every row (C1: the selectors explicit), red+green when both
      local nets = {networks_text(c.first_signal_networks) or 'red+green', c.second_signal and (networks_text(c.second_signal_networks) or 'red+green') or nil}
      text = text .. ' [reads ' .. nets[1] .. (nets[2] and ', ' .. nets[2] or '') .. ']'
      conds[i] = i > 1 and string.upper(c.compare_type or 'or') .. ' ' .. text or text
    end
    for i, o in ipairs(p.outputs or {}) do
      local name = signal_text(o.signal) or 'blank'
      local text = name .. ' = ' .. (o.copy_count_from_input ~= false and 'the input count (copy)' or ('constant ' .. tostring(o.constant or 1)))
      outs[i] = text .. ' [from ' .. (networks_text(o.networks) or 'red+green') .. ']'
    end
    return {conditions=conds, outputs=outs}
  end
  local function selector_view(p)
    if type(p) ~= 'table' then return nil end
    local out = {}
    for k, v in pairs(p) do
      if type(v) == 'table' and v.name and k:find('signal') then out[k] = signal_text(v)
      elseif k == 'quality_source_static' then out[k] = qname(v)
      elseif type(v) ~= 'table' and type(v) ~= 'userdata' then out[k] = v end
    end
    if type(p.quality_filter) == 'table' then
      out.quality_filter = (ASCII[p.quality_filter.comparator] or p.quality_filter.comparator or '=') .. ' ' .. qname(p.quality_filter.quality)
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
  -- A logistic network's count under 0 (d17 batch21 A4, Grok: "bioflux >= 0" held both Gleba makers off at -2): what
  -- the game's count is, and the way to compare what a chest holds instead.
  function M.negative_note(item, n)
    if type(n) ~= 'number' or n >= 0 then return '' end
    return string.format(' (network count %d: reserved beyond stock: deliveries have reserved %d more %s than the network holds, and a logistic condition reads %d; a wire from a provider or storage chest reads what that chest holds: circuit_gate {source: the chest} compares that)',
      n, -n, item, n)
  end
  local function logistic_reads(e, c)
    local pos = e.position
    local net = try(function() return e.force.find_logistic_network_by_position(pos, e.surface) end)
    local first = type(c) == 'table' and c.first_signal or nil
    if net then
      local text = 'network ' .. tostring(try(function() return net.network_id end) or '?') .. ' (its logistic area holds the centre)'
      if type(first) == 'table' and first.name and (first.type == nil or first.type == 'item') then
        local n = try(function() return net.get_item_count({name=first.name, quality=first.quality or 'normal'}) end)
        if type(n) == 'number' then
          text = text .. string.format(': %s %d', first.name, n) .. M.negative_note(first.name, n)
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
  -- An inserter in one line (Luna, d15: arms misrouting items): its circuit condition with each signal's value on its
  -- wires now and whether it holds, whether the inserter is off by it, where its wires go and what their networks carry,
  -- its filters and hand, and where it picks up and drops. c: M.read(e) (read here when nil).
  -- Its circuit and logistic conditions with the values now: each circuit signal's value on its wires and whether the
  -- condition holds; the logistic condition's item in the logistic network there; whether it is off by them. c: M.read(e).
  function M.condition_parts(e, c, cb)
    c = c or {}
    cb = cb or try(function() return e.get_control_behavior() end)
    local parts = {}
    local function value(sig)
      if not (type(sig) == 'table' and sig.name) then return nil end
      local n, wired = 0, false
      for _, w in ipairs({defines.wire_connector_id.circuit_red, defines.wire_connector_id.circuit_green}) do
        local net = try(function() return e.get_circuit_network(w) end)
        if net then wired = true; n = n + (try(function() return net.get_signal(sig) end) or 0) end
      end
      return wired and n or nil
    end
    if type(c.enable) == 'string' then
      local cond = cb and try(function() return cb.circuit_condition end)
      local vals = {}
      for _, k in ipairs({'first_signal', 'second_signal'}) do
        local sig = cond and cond[k]
        local v = value(sig)
        if v then vals[#vals+1] = string.format('%s %d', signal_text(sig), v) end
      end
      parts[#parts+1] = string.format('enabled when %s%s: %s now', c.enable, #vals > 0 and ' (on its wires: ' .. table.concat(vals, ', ') .. ')' or '',
        c.enable_ignored and 'ignored (no red or green wire)' or c.enable_met == true and 'true' or c.enable_met == false and 'false' or 'unknown')
    elseif c.enable == false then parts[#parts+1] = 'no circuit condition' end
    if type(c.logistic) == 'string' then
      -- (d17 batch20 B1, Luna) the item's count in the logistic network there, as the condition reads it
      local cond = cb and try(function() return cb.logistic_condition end)
      local sig = cond and cond.first_signal
      local held
      if type(sig) == 'table' and sig.name and (sig.type == nil or sig.type == 'item') then
        local net = try(function() return e.surface.find_logistic_network_by_position(e.position, e.force) end)
        held = net and try(function() return net.get_item_count(sig.name) end)
      end
      parts[#parts+1] = string.format('logistic condition %s%s: %s now', c.logistic, held and (held >= 0 and string.format(' (network holds %s %d)', sig.name, held) or M.negative_note(sig.name, held)) or '',
        c.logistic_met == true and 'true' or c.logistic_met == false and 'false' or 'unknown')
    end
    local st = try(function() return e.status end)
    if st and st == defines.entity_status.disabled_by_control_behavior then parts[#parts+1] = 'it is off by its condition'
    elseif type(c.enable) == 'string' or type(c.logistic) == 'string' then parts[#parts+1] = 'it is on' end
    return parts
  end
  function M.inserter_line(e, c)
    c = c or M.read(e) or {}
    local parts = M.condition_parts(e, c)
    -- Its wires and what each network carries now.
    for key, rows in pairs(c.wires or {}) do
      if key:sub(1, 6) ~= 'copper' then
        local ends = {}
        for i = 1, math.min(3, #rows) do local r = rows[i]; ends[i] = string.format('%s%s (%g,%g)%s', r.ghost and 'ghost of ' or '', r.entity, r.position.x, r.position.y, r.side and ' ' .. r.side or '') end
        local net = c.networks and c.networks[key]
        local sigs = {}
        for i, sg in ipairs(net and net.signals or {}) do if i <= 4 then sigs[i] = sg.name .. ' ' .. sg.count end end
        parts[#parts+1] = string.format('%s wire to %s%s%s', key, table.concat(ends, ', '), #rows > 3 and ', ...' or '',
          net and string.format('; network %s carries %s', tostring(net.id), #sigs > 0 and table.concat(sigs, ', ') .. (net.more and ', ...' or '') or 'nothing') or '')
      end
    end
    -- Filters, hand, pickup and drop.
    local fl = {}
    for k = 1, try(function() return e.filter_slot_count end) or 0 do
      local f = try(function() return e.get_filter(k) end)
      local n = type(f) == 'string' and f or type(f) == 'table' and (type(f.name) == 'string' and f.name or try(function() return f.name.name end)) or nil
      if n then fl[#fl+1] = n end
    end
    if #fl > 0 and try(function() return e.use_filters end) ~= false then
      parts[#parts+1] = (try(function() return e.inserter_filter_mode end) == 'blacklist' and 'filter not ' or 'filter ') .. table.concat(fl, ', ')
    end
    local h = try(function() return e.held_stack end)
    if h and h.valid_for_read then
      parts[#parts+1] = string.format('holding %d %s', h.count, h.name)
      -- waiting for the rest of its hand (a stack-inserter waits for a full hand; d22 batch104 BN2)
      if try(function() return e.status == defines.entity_status.waiting_for_more_items end) then
        parts[#parts] = parts[#parts] .. string.format(' of a hand of %s, waiting for more items%s', tostring(try(function() return e.inserter_target_pickup_count end) or '?'),
          e.name == 'stack-inserter' and ' (stack-inserter waits for a full hand)' or '')
      end
    end
    local function at_(x) return x and x.valid and string.format('%s (%g,%g)', x.name, x.position.x, x.position.y) end
    local pick, drop = try(function() return e.pickup_target end), try(function() return e.drop_target end)
    local dp = try(function() return e.drop_position end)
    parts[#parts+1] = string.format('picks from %s, drops %s', at_(pick) or 'nothing (the ground)',
      at_(drop) and 'into ' .. at_(drop) or (dp and string.format('onto the ground at (%g,%g)', dp.x, dp.y) or 'nowhere'))
    return string.format('%s (%g,%g): %s', e.name, e.position.x, e.position.y, table.concat(parts, '; '))
  end
  local SEG = 400
  local beltseg = require('beltseg')()
  -- set while belt_segment runs: M.read inside it starts no second one (d18 freeze)
  local in_segment = false
  function M.belt_segment(e)
    -- The segment the game counts, and what its lines hold (beltseg.lua; d22 batch118 CA2: measured on a private
    -- 2.0.77 server and on a copy of world n).
    local w = beltseg.walk(e, SEG)
    local held = beltseg.contents(w, e)
    -- What the wires read now.
    local wired = {}
    for _, wc in ipairs({defines.wire_connector_id.circuit_red, defines.wire_connector_id.circuit_green}) do
      local net = try(function() return e.get_circuit_network(wc) end)
      for _, sg in ipairs(net and try(function() return net.signals end) or {}) do
        local n = sg.signal and sg.signal.name
        local q = sg.signal and qname(sg.signal.quality)
        if n and q ~= 'normal' then n = n .. '@' .. q end
        if n then wired[n] = (wired[n] or 0) + (sg.count or 0) end
      end
    end
    local parts = {}
    for n, c in pairs(held) do parts[#parts+1] = c .. ' ' .. n end
    table.sort(parts)
    local wire_parts = {}
    for n2, c in pairs(wired) do wire_parts[#wire_parts+1] = c .. ' ' .. n2 end
    table.sort(wire_parts)
    -- Who puts those signals on the wires (batch25 A2, Astra: the graph's totals did not match the game's signal, and
    -- which belt read it was not plain): the belts on this belt's networks that read their contents (this one marked),
    -- and the other entities there that put signals on them, by kind.
    local readers, others, owners, queue, qi = {}, {}, {}, {}, 1
    for _, w in ipairs({defines.wire_connector_id.circuit_red, defines.wire_connector_id.circuit_green}) do
      local c = try(function() return e.get_wire_connector(w, false) end)
      if c then queue[#queue+1] = c end
    end
    local seenc = {}
    while qi <= #queue and qi <= 96 do
      local c = queue[qi]; qi = qi + 1
      local key = tostring(c.owner.unit_number) .. ':' .. tostring(c.wire_connector_id)
      if not seenc[key] then
        seenc[key] = true
        local o = c.owner
        if o.valid and o.type ~= 'electric-pole' and not owners[o.unit_number] then
          owners[o.unit_number] = true
          -- (d18 freeze, Kestrel II 03:39 and 03:46) the belt's own two settings, not M.read: M.read of a belt reading
          -- entire_belt_hold runs belt_segment again, and two such belts on one network called each other without end.
          local ob = o.type == 'transport-belt' and try(function() return o.get_control_behavior() end)
          if ob and try(function() return ob.read_contents end) then
            local mode = try(function() return ob.read_contents_mode end)
            mode = mode ~= nil and define_name('control_behavior.transport_belt.content_read_mode', mode) or 'pulse'
            readers[#readers+1] = string.format('%s (%g,%g)%s %s', o.name, o.position.x, o.position.y, o == e and ' (this belt)' or '', tostring(mode))
          elseif o ~= e and o.type ~= 'transport-belt' then
            local side = side_of(o, c.wire_connector_id)
            if not (COMBINATOR[etype(o)] and side == 'input') then
              local k = o.name .. (side and ' (' .. side .. ' side)' or '')
              others[k] = (others[k] or 0) + 1
            end
          end
        end
        for _, w2 in pairs(try(function() return c.connections end) or {}) do
          if w2.target and (w2.origin == nil or w2.origin == player_origin()) then queue[#queue+1] = w2.target end
        end
      end
    end
    local oparts = {}
    for k, n in pairs(others) do oparts[#oparts+1] = n .. ' ' .. k end
    table.sort(oparts)
    local read_line = string.format('belts reading their contents on those networks: %s%s',
      #readers > 0 and table.concat(readers, ', ') or 'none', #oparts > 0 and '; other entities on them: ' .. table.concat(oparts, ', ') or '')
    return string.format('What read_contents_mode entire_belt_hold reads is this belt\'s segment, as the game counts it (a segment runs through corners, '
      .. 'underground pairs and belt tier changes, and along the main line past a side-load; a belt side-loading onto another ends its own segment there, '
      .. 'and a splitter ends one): %d belt%s%s, back %s, on %s; it holds %s; the wires read %s (the game\'s own signal, anything else on those networks '
      .. 'included; a read switched on this tick shows from the next); %s',
      #w.list, #w.list == 1 and '' or 's', w.length and string.format(' (total_segment_length %g tiles)', math.floor(w.length * 100 + 0.5) / 100) or '',
      w.ends.inputs, w.ends.outputs, #parts > 0 and table.concat(parts, ', ') or 'nothing',
      #wire_parts > 0 and table.concat(wire_parts, ', ') or 'nothing', read_line), readers, oparts
  end
  -- The circuit networks an entity's red and green wires join, followed back to what drives them (D5, Astra 00:20:
  -- mixed return-belt deadlocks took dozens of inspect calls): each network (its id and signals now) with the entities
  -- on it: a combinator whose output side is on it is a source (its settings, and its input side's networks followed
  -- the same way, DEPTH levels at most), a constant combinator (its signals), anything else with circuit settings (what
  -- it reads: a chest, belt, tank, roboport, ...). At most NET_ENTS entities a network, NETS networks in all.
  local DEPTH, NET_ENTS, NETS = 3, 24, 12
  local function short_settings(c)
    if not c then return 'no circuit settings' end
    if c.arithmetic then return 'arithmetic ' .. c.arithmetic.text end
    if c.decider then return 'decider if ' .. table.concat(c.decider.conditions or {}, ' ') .. ' then ' .. table.concat(c.decider.outputs or {}, ', ') end
    if c.selector then
      local parts = {}
      for k2, v in pairs(c.selector) do parts[#parts+1] = k2 .. '=' .. tostring(v) end
      table.sort(parts)
      return 'selector ' .. table.concat(parts, ' ')
    end
    if c.signals then
      local parts = {}
      for i, sg in ipairs(c.signals) do if i <= 6 then parts[i] = sg.name .. ' ' .. sg.count end end
      return 'constant ' .. (c.on == false and '(off) ' or '') .. (#parts > 0 and table.concat(parts, ', ') or 'nothing')
    end
    local parts = {}
    for k2, v in pairs(c.settings or {}) do parts[#parts+1] = k2 .. '=' .. tostring(v) end
    table.sort(parts)
    if type(c.enable) == 'string' then parts[#parts+1] = 'enabled when ' .. c.enable .. (c.enable_met == false and ' (false now)' or c.enable_met == true and ' (true now)' or '') end
    return #parts > 0 and table.concat(parts, ', ') or 'wired, default settings'
  end
  function M.trace_from(e)
    local lines, nets_seen, count = {}, {}, 0
    local function out_rows(c)
      local parts = {}
      for i, sg in ipairs(c and c.output or {}) do if i <= 4 then parts[i] = sg.name .. ' ' .. sg.count end end
      return #parts > 0 and table.concat(parts, ', ') or 'nothing'
    end
    local function walk(conn, label, depth, indent)
      local net = try(function() return conn.owner.get_circuit_network(conn.wire_connector_id) end)
      local id = net and try(function() return net.network_id end)
      if not id or nets_seen[id] or count >= NETS then return end
      nets_seen[id] = true; count = count + 1
      local sigs, more = signal_rows(try(function() return net.signals end))
      local st = {}
      for i, sg in ipairs(sigs) do if i <= 6 then st[i] = sg.name .. ' ' .. sg.count end end
      local seen, queue, ents, n = {}, {conn}, {}, 0
      local i = 1
      while i <= #queue and n < 4 * NET_ENTS do
        local c = queue[i]; i = i + 1
        local key = tostring(c.owner.unit_number) .. ':' .. tostring(c.wire_connector_id)
        if not seen[key] then
          seen[key] = true; n = n + 1
          if c.owner ~= conn.owner or c.wire_connector_id ~= conn.wire_connector_id then ents[#ents+1] = c end
          for _, w in pairs(try(function() return c.connections end) or {}) do
            if w.target and (w.origin == nil or w.origin == player_origin()) then queue[#queue+1] = w.target end
          end
        end
      end
      lines[#lines+1] = string.format('%s%s network %s: %s%s', indent, label, tostring(id), #st > 0 and table.concat(st, ', ') or 'no signal', more and ', ...' or '')
      local listed = 0
      for _, c in ipairs(ents) do
        local o = c.owner
        if listed >= NET_ENTS then lines[#lines+1] = indent .. '  ...'; break end
        if o.valid and o ~= e and o.type ~= 'electric-pole' then
          listed = listed + 1
          local side = side_of(o, c.wire_connector_id)
          local info = try(function() return M.read(o) end)
          local text = string.format('%s  %s (%g,%g)%s: %s', indent, o.name, o.position.x, o.position.y, side and ' ' .. side .. ' side' or '', short_settings(info))
          if COMBINATOR[etype(o)] and side == 'output' then
            lines[#lines+1] = text .. '; puts out ' .. out_rows(info)
            if depth < DEPTH then
              for _, w in ipairs({defines.wire_connector_id.combinator_input_red, defines.wire_connector_id.combinator_input_green}) do
                local ic = w and try(function() return o.get_wire_connector(w, false) end)
                if ic then walk(ic, (w == defines.wire_connector_id.combinator_input_red and 'red' or 'green') .. ' input', depth + 1, indent .. '    ') end
              end
            end
          elseif COMBINATOR[etype(o)] then
            lines[#lines+1] = text .. ' (reads it)'
          else
            lines[#lines+1] = text
          end
        end
      end
    end
    for _, w in ipairs({defines.wire_connector_id.circuit_red, defines.wire_connector_id.circuit_green}) do
      local c = try(function() return e.get_wire_connector(w, false) end)
      if c then walk(c, w == defines.wire_connector_id.circuit_red and 'red' or 'green', 1, '  ') end
    end
    return lines
  end
  -- A condition as the game takes it ({first_signal, comparator, constant | second_signal}) from the forms circuit_set
  -- takes (platform_schedule's wait conditions too: d17 batch17 A5), and back as text.
  function M.condition(c, what) return condition(c, what) end
  function M.condition_text(c) return condition_text(c) end
  -- (d17 batch30 A2, Sol and viewer Foobator 05:47) a programmable speaker's alert settings, as its GUI's alert part:
  -- show_alert, show_on_map, icon (a signal), message; with its circuit condition and whether it holds now (the speaker
  -- plays, and alerts, while it holds). nil for anything else.
  -- (d19 batch49, viewer Foobator 19:39) its GUI's sound settings: volume, playback mode (local: heard near it; surface:
  -- on its surface; global: everywhere), polyphony, instrument and note (numbers from 0, as the game keeps them).
  local function speaker_sound(e, cb)
    local p = try(function() return e.parameters end)
    if type(p) ~= 'table' then return nil end
    local cp = cb and try(function() return cb.circuit_parameters end) or {}
    local insts = try(function() return e.prototype.instruments end) or {}
    local it = insts[(cp.instrument_id or 0) + 1]
    local inst = it and it.name or nil
    local note = it and it.notes and it.notes[(cp.note_id or 0) + 1] or nil
    local vol = p.playback_volume or 1
    local mode = p.playback_mode or 'local'
    local vs = p.volume_controlled_by_signal and signal_text(p.volume_signal_id) or nil
    local line
    if vol <= 0 and not p.volume_controlled_by_signal then line = 'sound: off (volume 0)'
    else
      line = string.format('sound: %s/%s at volume %s, %s%s%s%s', inst or tostring(cp.instrument_id or 0), note or tostring(cp.note_id or 0),
        vs and 'from signal ' .. vs or string.format('%d%%', math.floor(vol * 100 + 0.5)), mode, p.allow_polyphony and ', polyphony on' or '',
        cp.signal_value_is_pitch and ', the note from the signal value' or '', cp.stop_playing_sounds and ', stops playing sounds' or '')
    end
    return {volume=vol, mode=mode, polyphony=p.allow_polyphony and true or false, instrument=inst, note=note,
      instrument_id=cp.instrument_id or 0, note_id=cp.note_id or 0, volume_signal=vs, note_from_signal=cp.signal_value_is_pitch or nil, line=line}
  end
  function M.speaker_alert(e)
    local ap = try(function() return e.alert_parameters end)
    if type(ap) ~= 'table' then return nil end
    local icon = signal_text(ap.icon_signal_id)
    local msg = type(ap.alert_message) == 'string' and ap.alert_message or ''
    local cb = try(function() return e.get_control_behavior() end)
    local c = cb and try(function() return cb.circuit_condition end)
    local cond = type(c) == 'table' and condition_text(c) or nil
    local snd = speaker_sound(e, cb)
    return {show_alert=ap.show_alert and true or false, show_on_map=ap.show_on_map and true or false, icon=icon, message=msg,
      condition=cond, condition_met=type(c) == 'table' and c.fulfilled or nil, speaker_sound=snd,
      line=string.format('alert %s%s: %s%s; circuit condition %s%s', ap.show_alert and 'on' or 'off', ap.show_on_map and ' (on the map)' or '',
        msg ~= '' and '"' .. msg .. '"' or 'no message', icon and ', icon ' .. icon or '',
        cond and (cond .. (type(c) == 'table' and (c.fulfilled and ' (holds now)' or ' (does not hold now)') or '')) or 'none',
        snd and '; ' .. snd.line or '')}
  end
  local SPEAKER_KEYS = {show_alert=true, show_on_map=true, message=true, icon=true, condition=true, speaker_sound=true}
  local SOUND_KEYS = {volume=true, mode=true, polyphony=true, instrument=true, note=true}
  local SOUND_MODES = {['local']=true, surface=true, global=true}
  -- speaker_sound {volume?, mode?, polyphony?, instrument?, note?} checked against the speaker's settings now: the
  -- parameters and circuit parameters to write (nothing is written here).
  local function sound_spec(e, cb, spec)
    if type(spec) ~= 'table' then error('speaker_alert.speaker_sound is {volume? (0..1), mode? (local|surface|global), polyphony?, instrument?, note?}', 0) end
    for k in pairs(spec) do if not SOUND_KEYS[k] then error('speaker_sound takes volume, mode, polyphony, instrument and note, not ' .. tostring(k), 0) end end
    local p = try(function() return e.parameters end) or {}
    local np = {playback_volume=p.playback_volume or 1, playback_mode=p.playback_mode or 'local', allow_polyphony=p.allow_polyphony or false,
      volume_controlled_by_signal=p.volume_controlled_by_signal or false, volume_signal_id=p.volume_signal_id}
    if spec.volume ~= nil then
      if type(spec.volume) ~= 'number' or spec.volume < 0 or spec.volume > 1 then error('speaker_sound.volume is a number from 0 to 1 (the GUI\'s 0% to 100%)', 0) end
      np.playback_volume = spec.volume
    end
    if spec.mode ~= nil then
      if not SOUND_MODES[spec.mode] then error('speaker_sound.mode is local, surface or global, not ' .. tostring(spec.mode), 0) end
      np.playback_mode = spec.mode
    end
    if spec.polyphony ~= nil then
      if type(spec.polyphony) ~= 'boolean' then error('speaker_sound.polyphony must be true or false', 0) end
      np.allow_polyphony = spec.polyphony
    end
    local cp = cb and try(function() return cb.circuit_parameters end) or {}
    local ncp = {signal_value_is_pitch=cp.signal_value_is_pitch or false, stop_playing_sounds=cp.stop_playing_sounds or false,
      instrument_id=cp.instrument_id or 0, note_id=cp.note_id or 0}
    local insts = try(function() return e.prototype.instruments end) or {}
    local function pick(v, list, what)
      for i, n in ipairs(list) do if v == n or v == i - 1 then return i - 1 end end
      error(string.format('speaker_sound.%s: %s is none of this speaker\'s; it has %s (a name or its number from 0)', what, tostring(v), #list > 0 and table.concat(list, ', ') or 'none'), 0)
    end
    if spec.instrument ~= nil then
      local names = {}
      for i, it in ipairs(insts) do names[i] = it.name end
      local id = pick(spec.instrument, names, 'instrument')
      if id ~= ncp.instrument_id and spec.note == nil then ncp.note_id = 0 end
      ncp.instrument_id = id
    end
    if spec.note ~= nil then
      local it = insts[ncp.instrument_id + 1]
      ncp.note_id = pick(spec.note, it and it.notes or {}, 'note' .. (it and ' (of ' .. it.name .. ')' or ''))
    end
    return np, ncp
  end
  -- configure {speaker_alert: {show_alert?, show_on_map?, message?, icon?, condition?, speaker_sound?}}: the rest kept;
  -- icon false clears it; condition is its circuit condition (as circuit_set's enable takes it); speaker_sound its sound
  -- settings (d19 batch49). Returns the settings after and before.
  function M.set_speaker_alert(e, spec)
    local t = e.type == 'entity-ghost' and e.ghost_type or e.type
    if t ~= 'programmable-speaker' then
      error(string.format('speaker_alert is a programmable speaker\'s alert settings; %s (%g,%g) is a %s', e.type == 'entity-ghost' and e.ghost_name or e.name, e.position.x, e.position.y, t), 0)
    end
    if type(spec) ~= 'table' then error('speaker_alert is {show_alert?, show_on_map?, message?, icon?, condition?, speaker_sound?}', 0) end
    for k in pairs(spec) do if not SPEAKER_KEYS[k] then error('speaker_alert takes show_alert, show_on_map, message, icon, condition and speaker_sound, not ' .. tostring(k), 0) end end
    qforce = e.force
    local cond = spec.condition ~= nil and condition(spec.condition, 'speaker_alert.condition') or nil
    local sp, scp
    if spec.speaker_sound ~= nil then sp, scp = sound_spec(e, try(function() return e.get_control_behavior() end), spec.speaker_sound) end
    local before = M.speaker_alert(e)
    local ap = try(function() return e.alert_parameters end) or {}
    local new = {show_alert=ap.show_alert or false, show_on_map=ap.show_on_map or false, icon_signal_id=ap.icon_signal_id, alert_message=ap.alert_message or ''}
    for _, k in ipairs({'show_alert', 'show_on_map'}) do
      if spec[k] ~= nil then
        if type(spec[k]) ~= 'boolean' then error('speaker_alert.' .. k .. ' must be true or false', 0) end
        new[k] = spec[k]
      end
    end
    if spec.message ~= nil then
      if type(spec.message) ~= 'string' or #spec.message > 500 then error('speaker_alert.message is text, up to 500 characters', 0) end
      new.alert_message = spec.message
    end
    if spec.icon ~= nil then new.icon_signal_id = spec.icon ~= false and signal(spec.icon, 'speaker_alert.icon') or nil end
    local ok, err = pcall(function() e.alert_parameters = new end)
    if not ok then error('the game refused speaker_alert: ' .. tostring(err):gsub('^[^:]*:%d+: ', ''), 0) end
    if sp then
      local oks, errs = pcall(function() e.parameters = sp; e.get_or_create_control_behavior().circuit_parameters = scp end)
      if not oks then error('speaker_alert.speaker_sound: the game refused it: ' .. tostring(errs):gsub('^[^:]*:%d+: ', '') .. ' (the alert settings were set)', 0) end
    end
    if cond then
      local okc, errc = pcall(function() e.get_or_create_control_behavior().circuit_condition = cond end)
      if not okc then error('speaker_alert.condition: the game refused it: ' .. tostring(errc):gsub('^[^:]*:%d+: ', '') .. ' (the alert settings were set)', 0) end
    end
    return M.speaker_alert(e), before
  end
  -- One entity's circuit settings in a few words (circaudit.lua's network readback, d17 batch16 B3).
  function M.short(e) local c = try(function() return M.read(e) end); return short_settings(c) end
  -- The enable and logistic conditions as read shows them (enable, enable_met, logistic, logistic_met, disabled);
  -- returns the circuit and logistic condition tables when set.
  local function on_off(cb, out)
    local circuit, logistic
    if try(function() return cb.circuit_enable_disable end) then
      circuit = try(function() return cb.circuit_condition end)
      out.enable = condition_text(circuit) or 'blank'
      -- (false too: an unmet condition read as nil was dropped from the reply)
      if type(circuit) == 'table' then out.enable_met = circuit.fulfilled end
      circuit = circuit or true
    else out.enable = false end
    if try(function() return cb.connect_to_logistic_network end) then
      logistic = try(function() return cb.logistic_condition end)
      out.logistic = condition_text(logistic) or 'blank'
      if type(logistic) == 'table' then out.logistic_met = logistic.fulfilled end
      logistic = logistic or true
    else out.logistic = false end
    out.disabled = try(function() return cb.disabled end) or nil
    return circuit, logistic
  end
  -- (d17 batch22 B3) Only the conditions, without the wires and their networks' signals read walks: gates reads
  -- 256 entities a call with this (circuits.read was about 0.4 ms an entity on world n).
  function M.conditions(e, cb)
    if cb == nil then cb = try(function() return e.get_control_behavior() end) end
    if not cb then return nil end
    local out = {}
    if props_of(cb, kind_of(cb)).on_off then on_off(cb, out) end
    return out
  end
  function M.read(e, cb, picks)
    if cb == nil then cb = try(function() return e.get_control_behavior() end) end
    local wires, nets = wires_of(e, picks)
    local description = M.description(e)
    if not cb and not wires then return description and {description=description} or nil end
    local out = {wires=wires, networks=nets, description=description}
    if picks then
      -- one line: each network the entity's red and green wires join, by colour and side, with the signals named
      local keys, parts = {}, {}
      for k in pairs(nets or {}) do keys[#keys+1] = k end
      table.sort(keys)
      for _, k in ipairs(keys) do parts[#parts+1] = string.format('%s #%s: %s', k, tostring(nets[k].id), M.picked_text(nets[k].picked)) end
      out.signals_picked = #parts > 0 and table.concat(parts, '; ') or 'no red or green network: nothing to read'
    end
    if not cb then out.settings_note = 'no circuit settings changed from the game defaults'; return out end
    local kind = kind_of(cb)
    local props = props_of(cb, kind)
    if props.on_off then
      local circuit, logistic = on_off(cb, out)
      -- No red or green wire: the game ignores a circuit condition, and the entity runs (Astra 21:00: a fast
      -- inserter on Fulgora with enable EM < 0 and no wire read disabled and kept working).
      if circuit and not nets and e.type ~= 'entity-ghost' then out.enable_ignored = 'no red or green wire connects it: the game ignores this condition' end
      if logistic then out.logistic_reads = logistic_reads(e, logistic) end
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
    if kind == 'programmable_speaker' then local sa = M.speaker_alert(e); out.speaker_alert = sa and sa.line end
    -- A belt reading its entire belt (Astra, d15: the read missed a segment past an underground): the belt segment the
    -- game counts (beltseg.lua, each way up to SEG belts), what ends it each way, and what it holds against what the
    -- wires read now.
    if kind == 'transport_belt' and settings.read_contents and settings.read_contents_mode == 'entire_belt_hold' and not in_segment then
      local readers
      in_segment = true
      local ok, text, list = pcall(M.belt_segment, e)
      in_segment = false
      if not ok then error(text, 0) end
      out.belt_segment, readers = text, list
      out.belt_readers = readers and #readers > 0 and readers or nil
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
      error(string.format('%s has no circuit connection: the game gives it no circuit wires or circuit settings',
        e.type == 'entity-ghost' and 'the ghost of ' .. e.ghost_name or e.name), 0)
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
  -- The description a player writes in a combinator's GUI (d20 batch56 R4, Astra #1399 for viewer Foobator), read on
  -- 2.0.77: LuaEntity.combinator_description, on arithmetic, decider, selector and constant combinators and their ghosts
  -- (any other entity raises "Entity is not arithmetic-combinator or ..."); the game keeps the first 500 bytes of a
  -- longer one, even mid-character. A blueprint stores it as player_description; a ghost built from one has it, and
  -- the combinator the ghost becomes keeps it.
  M.DESCRIBED = {['arithmetic-combinator']=true, ['decider-combinator']=true, ['selector-combinator']=true, ['constant-combinator']=true}
  local function described_type(e) return e.type == 'entity-ghost' and try(function() return e.ghost_type end) or e.type end
  function M.description(e)
    if not M.DESCRIBED[described_type(e)] then return nil end
    local d = try(function() return e.combinator_description end)
    return d ~= '' and d or nil
  end
  -- description as configure and circuit_set take it: a string up to 500 bytes; "" or false clears it.
  function M.check_description(e, d)
    if not M.DESCRIBED[described_type(e)] then
      error(string.format('description: %s takes none; the game keeps a description on arithmetic, decider, selector and constant combinators (and their ghosts)',
        e.type == 'entity-ghost' and 'a ghost of ' .. tostring(try(function() return e.ghost_name end)) or e.name), 0)
    end
    if d == false then d = '' end
    if type(d) ~= 'string' then error('description is a string up to 500 bytes ("" or false clears it)', 0) end
    if #d > 500 then error(string.format('description is %d bytes; the game keeps at most 500 (a longer one is cut at 500, even mid-character)', #d), 0) end
    return d
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
    if M.DESCRIBED[described_type(e)] then list[#list+1] = 'description' end
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
        -- a string row may begin with and / or ("and carbon < 150")
        local joined
        if type(c) == 'string' then
          local j, rest = c:match('^%s*(%a+)%s+(.+)$')
          if j and (j:lower() == 'and' or j:lower() == 'or') then joined, c = j:lower(), rest end
        end
        local t = type(c) == 'table' and c or {}
        -- the game's own row ({first_signal, comparator, constant | second_signal, compare_type, ..._networks}) too
        -- (Sol, shift24: compare_type and was written OR; raw rows were refused)
        if type(c) == 'table' and c.first_signal ~= nil and c.signal == nil and c.first == nil then
          c = {signal=c.first_signal, comparator=c.comparator, value=c.constant, signal2=c.second_signal}
        end
        local row = condition(c, what)
        local cmp = t.compare; if cmp == nil then cmp = t.compare_type end; if cmp == nil then cmp = joined end
        if cmp ~= nil and (type(cmp) ~= 'string' or (cmp:lower() ~= 'and' and cmp:lower() ~= 'or')) then error(what .. ': compare (or compare_type) is and or or', 0) end
        if i > 1 and cmp == nil then error(what .. ': say how it joins the row before: compare "and" or "or" (the game\'s compare_type)', 0) end
        row.compare_type = cmp and cmp:lower() or 'or'
        row.first_signal_networks = networks(t.first_networks or t.first_signal_networks, what .. '.first_networks')
        row.second_signal_networks = networks(t.second_networks or t.second_signal_networks, what .. '.second_networks')
        conds[i] = row
      end
      for i, o in ipairs(x.outputs) do
        local what = 'decider.outputs ' .. i
        if type(o) == 'string' then o = {signal=o, copy_input=true} end
        if type(o) ~= 'table' then error(what .. ' is {signal, copy_input (true: the input count) | constant N, networks}', 0) end
        local copy = o.copy_input; if copy == nil then copy = o.copy_count_from_input end
        if copy == true and o.constant ~= nil then error(what .. ': copy_input (the input count) or constant, not both', 0) end
        outs[i] = {signal=signal_q(o.signal, o.quality, what .. '.signal'), copy_count_from_input=copy == true,
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
          params[k] = {quality=quality_of(v.quality, 'selector.quality_filter') or 'normal', comparator=v.comparator or '='}
        elseif k == 'quality_source_static' then
          -- the game keeps it as {name} (a bare name is dropped without an error: copy of world n, d22)
          params[k] = {name=quality_of(type(v) == 'table' and v.name or v, 'selector.quality_source_static') or 'normal'}
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
      local id = signal_q(s.signal or s.name, s.quality, 'signals ' .. i)
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
    if a.enable == false then error(M.ENABLE_FALSE, 0) end
    if a.switch_off ~= nil then error('switch_off: ' .. e.name .. ' is a chest: it has no running to stop (remove_condition: true clears its circuit condition)', 0) end
    if a.remove_condition ~= nil then
      if a.remove_condition ~= true then error('remove_condition must be true', 0) end
      b.remove_condition = nil; st.circuit_condition_enabled = false
      notes[#notes+1] = 'remove_condition: the chest\'s circuit condition is off (circuit_condition_enabled false)'
    end
    if a.enable ~= nil then
      b.enable = nil
      st.circuit_condition_enabled = true; st.circuit_condition = a.enable
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
  -- circuit_set's checks, and the steps that write what passed them (run by circuit_set; a place_ghosts dry run runs
  -- the checks alone on a stand-in of the entity: M.dry_set).
  M.NEVER = {first_signal={type='virtual', name='signal-dot'}, comparator='<', constant=-2147483648}
  M.ENABLE_FALSE = 'enable: false is two things: switch_off: true (a condition that never holds: the entity stops while a red or green wire connects it) or remove_condition: true (no condition: it runs whatever its wires read)'
  local function plan_set(e, cb, a, by)
    local kind = kind_of(cb)
    local props = props_of(cb, kind)
    local chest_notes
    a, chest_notes = chest_words(e, kind, a)
    -- A ghost by what it builds (its own name is entity-ghost): it takes the same settings (Astra 12:20).
    local ghost = e.type == 'entity-ghost'
    local steps, out = {}, {entity=ghost and try(function() return e.ghost_name end) or e.name, ghost=ghost or nil, position=e.position, by=by}
    local function step(what, fn) steps[#steps+1] = {what=what, fn=fn} end
    local function refuse(arg, text) error(string.format('%s: %s %s (its circuit settings: %s)', arg, e.name, text, settings_list(kind, props)), 0) end
    -- (batch25->26 A1, Muse twice, a reactor's feed misconfigured: enable false removed the condition, and the entity ran)
    if a.enable == false then error(M.ENABLE_FALSE, 0) end
    local n_on = (a.enable ~= nil and 1 or 0) + (a.switch_off ~= nil and 1 or 0) + (a.remove_condition ~= nil and 1 or 0)
    if n_on > 1 then error('enable, switch_off and remove_condition each set the enable condition: one at a time', 0) end
    if a.switch_off ~= nil then
      if a.switch_off ~= true then error('switch_off must be true (remove_condition: true clears the condition)', 0) end
      if not props.on_off then refuse('switch_off', 'has no enable condition') end
      step('switch_off', function() cb.circuit_enable_disable = true; cb.circuit_condition = M.NEVER end)
    end
    if a.remove_condition ~= nil then
      if a.remove_condition ~= true then error('remove_condition must be true', 0) end
      if not props.on_off then refuse('remove_condition', 'has no enable condition') end
      step('remove_condition', function() cb.circuit_enable_disable = false end)
    end
    if a.enable ~= nil then
      if not props.on_off then refuse('enable', 'has no enable condition') end
      local c = condition(a.enable, 'enable')
      step('enable', function() cb.circuit_enable_disable = true; cb.circuit_condition = c end)
    end
    if a.logistic ~= nil then
      if not props.on_off then refuse('logistic', 'has no logistic condition') end
      if a.logistic == false then step('logistic', function() cb.connect_to_logistic_network = false end)
      else
        local c = condition(a.logistic, 'logistic')
        step('logistic', function() cb.connect_to_logistic_network = true; cb.logistic_condition = c end)
      end
    end
    if a.description ~= nil then
      local d = M.check_description(e, a.description)
      out.description_before = M.description(e) or ''
      step('description', function() e.combinator_description = d end)
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
    return steps, out, chest_notes, a
  end
  -- The entity types whose control behavior kind is not the type's own name (read on a copy of world n: a ghost of
  -- each type with circuit wires, get_or_create_control_behavior; a pole has wires and no control behavior).
  local TYPE_KIND = {['ammo-turret']='turret', ['electric-turret']='turret', ['fluid-turret']='turret', ['infinity-container']='logistic_container',
    ['linked-container']='container', ['offshore-pump']='generic_on_off', ['power-switch']='generic_on_off', ['electric-pole']=false}
  -- A place_ghosts dry run (d17 batch18 A3, Sol): circuit_set's checks for an entity of that name, on a stand-in of
  -- it (no entity is read or written). Errors as circuit_set would.
  function M.dry_set(name, a, force)
    local proto = prototypes.entity[name]
    if not proto then return end
    local reach = try(function() return proto.get_max_circuit_wire_distance() end)
    local kind = TYPE_KIND[proto.type]
    if kind == nil then kind = proto.type:gsub('-', '_') end
    local id = kind and PROPS[kind] and try(function() return defines.control_behavior.type[kind] end)
    if reach == 0 or not id then
      error(string.format('%s has no circuit connection: the game gives it no circuit wires or circuit settings', name), 0)
    end
    local e = {valid=true, name=name, type=proto.type, prototype=proto, position=a.position or {x=0, y=0}}
    qforce = force
    plan_set(e, {type=id, circuit_enable_disable=false}, a, 'dry run')
  end
  function M.handlers.circuit_set(p, a)
    local e, by = target(p, a, 'target')
    local cb = behavior(e)
    local steps, out, chest_notes
    qforce = e.force
    steps, out, chest_notes, a = plan_set(e, cb, a, by)
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
    out.now = M.now_text(out, a)
    -- (AA8) what this call set that needs a signal, with no red or green wire on it now (a built entity's enable
    -- condition is said by condition_ignored already)
    if not M.has_circuit_wire(e) then
      local needs = {}
      for _, row in ipairs(M.signal_needs(out.entity, a)) do
        if out.ghost or not (out.condition_ignored and row:sub(1, 20) == 'its enable condition') then needs[#needs+1] = row end
      end
      if #needs > 0 then out.unwired = M.unwired_line(out.entity, e.position, needs, 'none on it now', out.ghost) end
    end
    return out
  end
  -- What the entity does now after switch_off or remove_condition (A1): plainly.
  function M.now_text(out, a)
    if not (a.switch_off or a.remove_condition) then return nil end
    local c = out.circuit or {}
    local soon = out.ghost and 'once built: ' or ''
    local logi = c.logistic and c.logistic_met == false and ('; its logistic condition ' .. c.logistic .. ' holds it off') or ''
    if a.remove_condition then return soon .. 'runs: no circuit condition' .. logi end
    if c.enable_ignored then
      return soon .. 'runs: no red or green wire connects it, so the game ignores the condition; it stops once a red or green wire connects it'
    end
    return soon .. 'stopped: its circuit condition signal-dot < -2147483648 never holds' .. logi
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

  -- Settings that need a signal, with no red or green wire --------------------------
  -- (d20 batch65 AA8, Astra 19:02: place_ghosts took an inserter's enable condition signal-check > 0 with no wire planned;
  -- inspect later said the game ignored it.) Read on a private copy (2.0.77), each set with no red or green wire, then
  -- wired to a constant combinator sending nothing: an inserter's enable condition was ignored and it ran (wired: it
  -- stopped); set filters kept its own filters (wired: none, it took nothing); set stack size kept its own hand size
  -- (wired: 1); an assembler's set recipe kept its recipe (wired: none); a requester's set requests kept its requests.
  local ACTS = {circuit_set_filters={'set filters', 'the game keeps its own filters'},
    circuit_set_stack_size={'set stack size', 'the game keeps its own hand size'},
    circuit_set_recipe={'set recipe', 'the game keeps its own recipe'}, set_recipe={'set recipe', 'the game keeps its own recipe'}}
  local REQUESTS = {'set requests', 'the game keeps its own requests'}
  -- Other settings that act on a signal: with no wire none reaches them.
  local READS = {set_trains_limit='set trains limit', set_priority='set priority', send_to_train='send to train', set_filter='set filter',
    set_input_side='set input side', set_output_side='set output side', set_priority_list='set priority list',
    set_ignore_unlisted_targets='ignore unlisted targets', send_to_platform='send to platform', open_gate='open gate',
    close_signal='close signal', circuit_close_signal='close signal'}
  local function on_off_type(t)
    local kind = TYPE_KIND[t]
    if kind == nil then kind = t and t:gsub('-', '_') end
    return kind and PROPS[kind] and PROPS[kind].on_off or false
  end
  -- What of spec needs a signal on entity name: spec is circuit_set's arguments, or (bp) a blueprint entity's
  -- control_behavior. Rows "its enable condition iron-plate > 0: the game ignores this condition and the inserter runs".
  function M.signal_needs(name, spec, bp)
    if type(spec) ~= 'table' then return {} end
    local proto = try(function() return prototypes.entity[name] end)
    local t = proto and proto.type
    local rows, seen = {}, {}
    local function add(label, effect)
      if not seen[label] then seen[label] = true; rows[#rows+1] = label .. ': ' .. effect end
    end
    local runs = on_off_type(t) and 'the game ignores this condition and the ' .. name .. ' runs' or 'the game ignores this condition'
    local settings = not bp and type(spec.settings) == 'table' and spec.settings or {}
    local function cond(c)
      if c == nil then return '' end
      local okc, text = pcall(function() return condition_text(bp and c or condition(c, 'enable')) end)
      return okc and text and ' ' .. text or ''
    end
    if bp then
      if spec.circuit_enabled == true or spec.circuit_condition_enabled == true then add('its enable condition' .. cond(spec.circuit_condition), runs) end
      if spec.circuit_mode_of_operation == 1 and t == 'logistic-container' then add(REQUESTS[1], REQUESTS[2]) end
    else
      if spec.enable ~= nil and spec.enable ~= false then add('its enable condition' .. cond(spec.enable), runs) end
      if spec.switch_off == true then add('its enable condition signal-dot < -2147483648 (switch_off)', runs) end
      if settings.circuit_enable_disable == true or settings.circuit_condition_enabled == true then
        add('its enable condition' .. cond(settings.circuit_condition), runs)
      end
      if spec.set_requests == true or settings.circuit_exclusive_mode_of_operation == 'set_requests' then add(REQUESTS[1], REQUESTS[2]) end
    end
    local source = bp and spec or settings
    for k, v in pairs(source) do
      if v == true and ACTS[k] then add(ACTS[k][1], ACTS[k][2])
      elseif v == true and READS[k] then add(READS[k], 'no signal reaches it') end
    end
    table.sort(rows, function(x, y)
      local ex, ey = x:sub(1, 3) == 'its', y:sub(1, 3) == 'its'
      if ex ~= ey then return ex end
      return x < y
    end)
    return rows
  end
  -- A red or green wire on e (a building or a ghost) now.
  function M.has_circuit_wire(e)
    local wires = try(function() return (wires_of(e)) end)
    for key in pairs(wires or {}) do if key:sub(1, 6) ~= 'copper' then return true end end
    return false
  end
  -- "fast-inserter (3.5,4.5): no red or green wire connects it (none in this call): its enable condition ...: the game
  -- ignores this condition and the fast-inserter runs"; ghost: what it does once built.
  function M.unwired_line(name, pos, needs, how, ghost)
    return string.format('%s (%g,%g): no red or green wire connects it (%s): %s%s', name, pos.x, pos.y, how,
      ghost and 'once built, ' or '', table.concat(needs, '; '))
  end
  -- The lines of a list, at most 4, and how many more.
  function M.unwired_text(lines)
    if #lines == 0 then return nil end
    local shown = {}
    for i = 1, math.min(4, #lines) do shown[i] = lines[i] end
    return table.concat(shown, '; ') .. (#lines > 4 and string.format('; +%d more entities', #lines - 4) or '')
  end
  -- A planned call's entries ({index?, name|item, position, direction?, circuit (circuit_set arguments) | needs (rows
  -- from a blueprint with no wire to it), wires? [{to, color, disconnect?}]}): those that set something needing a signal
  -- with no red or green wire to them in the call (from the entry, or another entry's wire whose to lies on it) and none
  -- on what stands there now (wired(name, position) -> true). Returns the warning text or nil.
  function M.unwired_plan(entries, wired, ghosts)
    local function ename(e)
      if type(e.name) == 'string' and try(function() return prototypes.entity[e.name] end) then return e.name end
      local ip = type(e.item) == 'string' and try(function() return prototypes.item[e.item] end)
      return ip and ip.place_result and ip.place_result.name or e.name or e.item
    end
    local list, targets = {}, {}
    for _, e in ipairs(type(entries) == 'table' and entries or {}) do
      if type(e) == 'table' then
        for _, w in ipairs(type(e.wires) == 'table' and e.wires or {}) do
          if type(w) == 'table' and (w.color == 'red' or w.color == 'green') and not w.disconnect then
            local to = try(function() return api.position(w.to) end)
            if to then targets[#targets+1] = to end
            e.__wired = true
          end
        end
      end
    end
    for _, e in ipairs(type(entries) == 'table' and entries or {}) do
      if type(e) == 'table' then
        local name = ename(e)
        local needs = e.needs or (e.circuit and type(name) == 'string' and M.signal_needs(name, e.circuit)) or {}
        local pos = #needs > 0 and try(function() return api.position(e.position) end)
        if pos and not e.__wired then
          local proto = try(function() return prototypes.entity[name] end)
          local half = proto and math.max(proto.tile_width or 1, proto.tile_height or 1) / 2 or 0.5
          local hit = false
          for _, to in ipairs(targets) do
            if math.abs(to.x - pos.x) <= half + 1e-6 and math.abs(to.y - pos.y) <= half + 1e-6 then hit = true; break end
          end
          if not hit and not (wired and wired(name, pos)) then
            list[#list+1] = M.unwired_line(name, pos, needs, 'none in this call, none on what stands there', ghosts)
          end
        end
        e.__wired = nil
      end
    end
    return M.unwired_text(list)
  end

  -- wire -----------------------------------------------------------------------
  local CIRCUIT = {red={input='combinator_input_red', output='combinator_output_red', plain='circuit_red'},
    green={input='combinator_input_green', output='combinator_output_green', plain='circuit_green'}}
  -- The connector id of a wire end for a wire color (nil: copper) and side, by the end's name, type, prototype and
  -- quality: the live wire's rules, which a dry run checks on planned entries too (d20 batch122, Astra #2087: a dry run
  -- took from_side on a belt, the live call refused it).
  function M.wire_end_id(key, name, t, pr, quality, color, side, default_side)
    local W = defines.wire_connector_id
    local id
    if color then
      local d = try(function() return pr.get_max_circuit_wire_distance(quality) end)
      if d == 0 then error(string.format('%s: %s takes no %s circuit wire (it has no circuit connection)', key, name, color), 0) end
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
      error(string.format('%s: %s takes no copper wire (poles and power switches do; with color red or green, a circuit wire)', key, name), 0)
    end
    return id
  end
  -- The connector of entity e for a wire color (nil: copper) and side.
  local function connector(e, key, color, side, default_side)
    local id = M.wire_end_id(key, e.name, etype(e), proto_of(e), e.quality, color, side, default_side)
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
