-- Common wrong argument names, mapped to the real ones (agent-minds study
-- fix 10: 75-127 unknown arguments a shift, 70% the agent's own earlier
-- mistake). Only an argument the action does not take, whose real name the
-- call does not also give, is renamed; the reply's `corrected` shows the call
-- as it ran, so the agent can use it next time. Anything else still fails
-- with the list of valid arguments.
return function(api)
  local M = {}
  -- action -> {wrong name = real name}; counts are shift05-07 journal errors.
  local RENAME = {
    craft = {item='recipe', name='recipe'},
    move_to = {to='position', pos='position', destination='position', waypoints='via', through='via'},
    map = {center='position', centre='position'},
    scan = {names='name', entity_names='name', entity='name', types='type', range='radius', field='fields', center='position'},
    nearest = {entity='name', names='name', types='type', center='position'},
    chat = {count='limit', n='limit'},
    tells = {count='limit', n='limit'},
    build = {placements='builds', entities='builds', dryrun='dry_run', ['dry-run']='dry_run'},
    place_ghosts = {dryrun='dry_run', ['dry-run']='dry_run'},
    paste = {dryrun='dry_run', ['dry-run']='dry_run'},
    blueprint_place = {dryrun='dry_run', ['dry-run']='dry_run'},
    ports = {entity='name', machine='name', facing='direction'},
    ores = {name='resource', ore='resource', resources='resource', center='position', centre='position', min='min_amount', amount='min_amount'},
    board_post = {text='title', name='title', step='steps'},
    board_update = {steps='step'},
    recipes = {search='prefix', name='prefix', recipe='prefix', filter='prefix', item='prefix'},
    -- observe scope=craftable {item} (Gemini, shift10: 5 refusals): the recipes asked about.
    craftable = {item='recipes', recipe='recipes', name='recipes'},
    technologies = {search='prefix', name='prefix', filter='prefix', technology='prefix'},
    mine = {entity='name'},
    transfer = {target='position', amount='count', quantity='count', qty='count'},
    inspect = {target='position'},
    configure = {target='position', auto_launch='send_to_orbit_automatically', planet='surface', mode='filter_mode', filter='filters'},
    launch = {planet='surface'},
    silo = {planet='surface'},
    requests = {planet='surface'},
    rotate = {target='position'},
    -- pole_route and pipe_route call their points waypoints.
    rail_route = {waypoints='via', start='from', ['end']='to', dryrun='dry_run', ['dry-run']='dry_run'},
    train_stop = {station_name='name', target='position'},
  }
  -- A project's changes (board.lua board_update).
  local PROJECT_CHANGES = {'step', 'done', 'undone', 'remove_step', 'goal', 'handoff', 'areas'}
  -- A one-name list given where a name is taken: its name; one name given where a list is taken: a list of it.
  local SINGLE = {prefix=true}
  local LISTED = {recipes=true}
  -- Actions whose positions is a list of targets of the same move or read.
  local LISTS = {transfer=true, collect=true, feed=true, inspect=true, rearm=true, refuel=true, repair=true}
  -- transfer direction names for the same two moves.
  local DIRECTION = {from_entity='to_player', from_player='to_entity', to_chest='to_entity', from_chest='to_player',
    to_container='to_entity', from_container='to_player', to_character='to_player', from_character='to_entity',
    give='to_entity', put='to_entity', insert='to_entity', take='to_player',
    -- (Muse, 13:31: to_machine worked on a walking tour and was refused on one target; one name for every entity kind)
    to_machine='to_entity', from_machine='to_player', to_building='to_entity', from_building='to_player'}
  local function encode(v)
    local t = type(v)
    if t == 'string' then return '"' .. v:gsub('[%c"\\]', function(c) return string.format('\\u%04x', c:byte()) end) .. '"' end
    if t == 'number' or t == 'boolean' then return tostring(v) end
    if t ~= 'table' then return 'null' end
    if #v > 0 or next(v) == nil then
      local parts = {}
      for i = 1, #v do parts[i] = encode(v[i]) end
      return '[' .. table.concat(parts, ',') .. ']'
    end
    local keys = {}
    for k in pairs(v) do keys[#keys+1] = tostring(k) end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do parts[#parts+1] = encode(k) .. ':' .. encode(v[k]) end
    return '{' .. table.concat(parts, ',') .. '}'
  end
  M.encode = encode
  -- One position, {x,y} or [x,y]; a list of them.
  local function is_pos(v)
    return type(v) == 'table' and ((type(v.x) == 'number' and type(v.y) == 'number')
      or (v.x == nil and type(v[1]) == 'number' and type(v[2]) == 'number' and v[3] == nil))
  end
  local function is_list(v)
    if type(v) ~= 'table' or v.x ~= nil or #v == 0 then return false end
    for _, e in ipairs(v) do if not is_pos(e) then return false end end
    return true
  end
  local function xy(v) return {x = v.x or v[1], y = v.y or v[2]} end
  -- (action, args) -> action, args, notes (nil when nothing changed). `takes`
  -- tells whether an action takes an argument (describe's schema).
  function M.fix(action, args, takes)
    if type(args) ~= 'table' or type(action) ~= 'string' then return action, args, nil end
    local notes, silent = {}, false
    local out = {}
    for k, v in pairs(args) do out[k] = v end
    -- board with an item id and a change is an update; with a title, a post.
    -- (A read with an id shows that one item; a status filter means nothing there.)
    local changes = out.note ~= nil or out.owner ~= nil or (type(out.status) == 'string' and out.status ~= 'active')
    for _, k in ipairs(PROJECT_CHANGES) do changes = changes or out[k] ~= nil end
    if action == 'board' and out.id ~= nil and changes then
      local kept = {}
      for _, k in ipairs{'id', 'status', 'note', 'owner'} do kept[k] = out[k] end
      for _, k in ipairs(PROJECT_CHANGES) do kept[k] = out[k] end
      notes[#notes+1] = 'board with an id and a change is board_update'
      action, out = 'board_update', kept
    elseif action == 'board' and out.title ~= nil then
      notes[#notes+1] = 'board with a title is board_post'
      action = 'board_post'
      if out.text ~= nil and out.note == nil then out.note, out.text = out.text, nil end
    end
    -- transfer {to_player=true} / {to_entity=true}, from_entity / from_player, or the target given as one of them
    -- ({to_entity={x,y}}, Haiku shift09): the direction, and the position. A direction named the other way round
    -- (from_entity, to_chest ...) is its to_entity/to_player name.
    if action == 'transfer' then
      -- The same target named twice (Muse, shift11 17:18: position and to_entity, then position and to, both at the
      -- silo, 8 refusals during a rocket load): the one position, and the side it names.
      for _, d in ipairs{'to_entity', 'from_entity', 'to', 'from'} do
        local v = out[d]
        if is_pos(v) and is_pos(out.position) and xy(v).x == xy(out.position).x and xy(v).y == xy(out.position).y and out.pick == nil then
          local real = (d == 'to' or d == 'to_entity') and 'to_entity' or 'to_player'
          if out.direction == nil or out.direction == real or DIRECTION[out.direction] == real then
            out[d] = nil; out.direction = real
            notes[#notes+1] = d .. ' at the same place as position is direction="' .. real .. '"'
          end
        end
      end
      -- from {x,y} is the position (from: "nearest" is transfer's own: the nearest chest holding the item), a take
      -- from there; to as the one target, without pick (pick takes to: where what it took is given), the position and
      -- a give. A from and a to: the take is at from, and to the refusal's pick form gives at (the handler shows it).
      if out.pick == nil and out.position == nil and out.positions == nil then
        if is_pos(out.to) and not (is_pos(out.from) or is_list(out.from)) and (out.direction == nil or out.direction == 'to_entity') then
          out.position, out.to, out.direction = xy(out.to), nil, 'to_entity'
          notes[#notes+1] = 'to={x,y} without pick is position=... direction="to_entity"'
        elseif is_pos(out.from) or is_list(out.from) then
          out.position, out.from = out.from, nil
          if out.direction == nil and not is_pos(out.to) then out.direction = 'to_player' end
          notes[#notes+1] = 'from is position' .. (out.direction == 'to_player' and ' (a take: direction="to_player")' or '')
        end
      end
      if type(out.direction) == 'string' and DIRECTION[out.direction] then
        notes[#notes+1] = 'direction ' .. out.direction .. ' is ' .. DIRECTION[out.direction]
        out.direction = DIRECTION[out.direction]
      end
      -- A place to take from and one to give to (Luna, shift11: from_entity and to_entity): a move between two
      -- entities, which only pick makes; neither is taken as the target (the refusal shows the pick form).
      local two = (is_pos(out.from_entity) or is_pos(out.from)) and (is_pos(out.to_entity) or is_pos(out.to))
      for _, d in ipairs{'to_player', 'to_entity', 'from_entity', 'from_player'} do
        local v, real = out[d], DIRECTION[d] or d
        local where = is_pos(v) and 'position' or is_list(v) and 'positions' or nil
        if not (two and where) and (v == true or (where and out[where] == nil)) and (out.direction == nil or out.direction == real) then
          out[d] = nil; out.direction = real
          if where then out[where] = v end
          notes[#notes+1] = d .. (where and '={x,y}' or '=true') .. ' is direction="' .. real .. '"' .. (where and ' ' .. where .. '=...' or '')
        end
      end
    end
    -- circuit is circuit_set's old name.
    if action == 'circuit' then
      action = 'circuit_set'
      notes[#notes+1] = 'circuit is circuit_set'
    end
    -- position and positions (Muse, shift08, dozens a shift): one {x,y} as positions, a list as position, a position
    -- where only positions is taken, or both at once, run as one list. Not with radius (neither applies there).
    if LISTS[action] and out.radius == nil and takes(action, 'positions') then
      local P, L = out.position, out.positions
      if is_pos(L) then
        L = {L}; out.positions = L
        notes[#notes+1] = 'positions is a list: [{x,y}]'
      end
      if is_list(P) then
        if L == nil then
          out.positions, out.position = P, nil
          notes[#notes+1] = 'position with a list is positions'
        elseif is_list(L) then
          local all = {}
          for _, v in ipairs(P) do all[#all+1] = v end
          for _, v in ipairs(L) do all[#all+1] = v end
          out.positions, out.position = all, nil
          notes[#notes+1] = 'position and positions are one list'
        end
      elseif is_pos(P) and (is_list(L) or (L == nil and not takes(action, 'position'))) then
        local entry = P
        -- A unit_number beside one position names that entry.
        if out.unit_number ~= nil and (L ~= nil or not takes(action, 'unit_number')) and P.x ~= nil then
          entry = {}
          for k, v in pairs(P) do entry[k] = v end
          entry.unit_number, out.unit_number = out.unit_number, nil
        end
        local all = {entry}
        for _, v in ipairs(L or {}) do
          if not (xy(v).x == xy(P).x and xy(v).y == xy(P).y) then all[#all+1] = v end
        end
        out.positions, out.position = all, nil
        -- (a collect waiting at one machine takes its one position this way: nothing to correct)
        if action == 'collect' and (out.wait_ticks ~= nil or out.keep_taking ~= nil) and not L then silent = true
        else notes[#notes+1] = L and 'position and positions are one list (position first)' or 'position is positions (a list)' end
      end
    end
    -- move_to target is an entity whose reach the walk goes to ({position} or {unit_number}, with reach); a plain
    -- {x,y} target without reach is the position it always was.
    if action == 'move_to' and is_pos(out.target) and out.reach == nil and out.position == nil then
      out.position, out.target = out.target, nil
      notes[#notes+1] = 'target is position'
    end
    -- fh sends scan, nearest, map ... as observe {scope}: the view's own names.
    local view = action == 'observe' and type(out.scope) == 'string' and out.scope or action
    for wrong, right in pairs(RENAME[view] or {}) do
      if out[wrong] ~= nil and out[right] == nil and not takes(view, wrong) and takes(view, right) then
        local v = out[wrong]
        if SINGLE[right] and type(v) == 'table' and #v == 1 then v = v[1] end
        if LISTED[right] and type(v) == 'string' then v = {v} end
        out[right], out[wrong] = v, nil
        notes[#notes+1] = wrong .. ' is ' .. right
      end
    end
    if #notes == 0 then return action, silent and out or args, nil end
    table.sort(notes)
    return action, out, {notes=notes, call=action .. ' ' .. encode(out)}
  end
  return M
end
