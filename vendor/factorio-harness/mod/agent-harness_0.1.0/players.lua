-- Human players in the agents' world (bots and camera clients are not humans):
--   log      what each human built, removed (mined by hand, mined by robots on
--            their deconstruction order, destroyed by their character or
--            vehicle), their pending deconstruction and upgrade orders, and
--            big inventory moves between them and chests or vehicles.
--   players  the agents' read of it: who is on the map, where, what each did.
--   votes    kick, ban and trust votes on a human are votes.lua's; this
--            module finds the player and their group for it.
--   restore  cancels a player's pending orders and places ghosts of what they
--            removed: orders only, robots and agents build them with real items.
-- New players land in the guest permission group from control.lua (on_player_created).
return function(api)
  local M = {handlers={}, operator={}}
  local MAX_BUILT, MAX_REMOVED, MAX_MOVES, MAX_ORDERS = 2000, 2000, 200, 5000
  local BIG_MOVE = 50
  local MINUTE = 3600
  local GUEST = 'pog-guest'
  -- A burst of removals or orders is a chat line from `players`: BURST within
  -- BURST_TICKS, then at most one line per player and kind every QUIET_TICKS.
  local BURST, BURST_TICKS, QUIET_TICKS = 20, 5 * MINUTE, 2 * MINUTE
  -- Removals that are play, not the team's work: trees, rocks, ore, corpses, ghosts.
  local NOT_WORK = {tree=true, ['simple-entity']=true, resource=true, ['item-entity']=true, ['entity-ghost']=true,
    ['tile-ghost']=true, character=true, ['character-corpse']=true, corpse=true, ['rail-remnants']=true, cliff=true, fish=true,
    ['deconstructible-tile-proxy']=true, ['item-request-proxy']=true, ['simple-entity-with-owner']=true}
  local INVENTORIES = {container='chest', ['logistic-container']='chest', car='car_trunk', ['cargo-wagon']='cargo_wagon',
    ['spider-vehicle']='spider_trunk'}
  M.events = {}
  for _, name in ipairs{'on_built_entity', 'on_player_mined_entity', 'on_robot_mined_entity', 'on_entity_died',
    'on_marked_for_deconstruction', 'on_marked_for_upgrade', 'on_cancelled_deconstruction', 'on_cancelled_upgrade',
    'on_gui_opened', 'on_gui_closed', 'on_player_fast_transferred', 'on_player_main_inventory_changed',
    'on_player_joined_game', 'on_player_left_game'} do
    if defines.events[name] then M.events[defines.events[name]] = name end
  end

  local function store()
    local s = api.state()
    s.humans = s.humans or {by_index={}, orders={}, order_count=0, dropped_orders=0}
    return s.humans
  end
  local function human(index)
    if type(index) ~= 'number' then return nil end
    local p = game.get_player(index)
    if not (p and p.valid) or not api.is_human(p.index) then return nil end
    return p
  end
  local function record(p)
    local by = store().by_index
    local r = by[p.index]
    if not r then r = {built={}, removed={}, moves={}}; by[p.index] = r end
    r.name = p.name
    return r
  end
  -- Append, trimming to max once the list is a tenth over it.
  local function push(list, item, max)
    list[#list+1] = item
    if #list <= max + math.floor(max / 10) then return list end
    local keep = {}
    for i = #list - max + 1, #list do keep[#keep+1] = list[i] end
    return keep
  end
  local function round(v) return math.floor(v * 10 + 0.5) / 10 end
  local function at(position) return {x=round(position.x), y=round(position.y)} end
  local function key(e) return e.surface.index .. ':' .. e.position.x .. ':' .. e.position.y .. ':' .. e.name end
  local function drop(k)
    local s = store()
    if s.orders[k] then s.orders[k] = nil; s.order_count = s.order_count - 1 end
  end
  local function quality_of(e)
    local ok, q = pcall(function() return e.quality and e.quality.name end)
    return ok and q ~= 'normal' and q or nil
  end
  -- Enough to put a ghost back: name, place, facing, quality and settings.
  local function snapshot(e, how)
    local r = {tick=game.tick, name=e.name, position={x=e.position.x, y=e.position.y}, direction=e.direction,
      surface=e.surface.name, how=how, quality=quality_of(e)}
    if e.type == 'assembling-machine' then
      pcall(function() local recipe = e.get_recipe(); if recipe then r.recipe = recipe.name end end)
    elseif e.type == 'underground-belt' then
      pcall(function() r.belt_type = e.belt_to_ground_type end)
    elseif e.type == 'loader' or e.type == 'loader-1x1' then
      pcall(function() r.belt_type = e.loader_type end)
    end
    return r
  end
  local function duration(ticks)
    local sec = math.floor(ticks / 60)
    if sec >= 60 then return string.format('%dm%02ds', math.floor(sec / 60), sec % 60) end
    return sec .. 's'
  end
  -- Count toward a burst; the line names the count, the time it took and the last place.
  local function burst(p, r, kind, e)
    r.bursts = r.bursts or {}
    local b = r.bursts[kind]
    if not b or game.tick - b.start > BURST_TICKS then b = {start=game.tick, count=0, said=b and b.said}; r.bursts[kind] = b end
    b.count = b.count + 1
    if b.count < BURST or (b.said and game.tick - b.said < QUIET_TICKS) then return end
    local function num(v) v = math.floor(v * 10 + 0.5) / 10; return v == math.floor(v) and string.format('%d', v) or string.format('%.1f', v) end
    local what = kind == 'removed' and 'removed %d of the team\'s entities' or kind == 'upgrade' and 'marked %d of the team\'s entities for upgrade'
      or 'marked %d of the team\'s entities for deconstruction'
    api.notice('players', string.format('%s ' .. what .. ' in %s, the last at (%s,%s) on %s (fh players %s)', p.name, b.count,
      duration(game.tick - b.start), num(e.position.x), num(e.position.y), e.surface.name, p.name))
    b.said = game.tick
    b.start, b.count = game.tick, 0
  end
  local function removed(index, e, how)
    local p = human(index)
    if not p or not (e and e.valid) or NOT_WORK[e.type] or not e.force or e.force.name == 'enemy' or e.force.name == 'neutral' then return end
    local r = record(p)
    r.removed = push(r.removed, snapshot(e, how), MAX_REMOVED)
    burst(p, r, 'removed', e)
  end
  local function contents(inventory)
    local out = {}
    if not inventory then return out end
    for _, stack in pairs(inventory.get_contents()) do
      local name = stack.quality and stack.quality ~= 'normal' and stack.name .. '@' .. stack.quality or stack.name
      out[name] = (out[name] or 0) + stack.count
    end
    return out
  end
  local function inventory_of(e)
    local which = e and e.valid and INVENTORIES[e.type]
    if not which or not defines.inventory[which] then return nil end
    local ok, inventory = pcall(e.get_inventory, defines.inventory[which])
    return ok and inventory or nil
  end
  -- A move between a player and an entity, from the player's side: took (the
  -- player gained) and put (the player gave). Recorded from BIG_MOVE items.
  local function move(r, info, delta)
    local took, put, total = {}, {}, 0
    for name, n in pairs(delta) do
      if n > 0 then took[name] = n elseif n < 0 then put[name] = -n end
      total = total + math.abs(n)
    end
    if total < BIG_MOVE then return end
    info.took = next(took) and took or nil
    info.put = next(put) and put or nil
    info.items = total
    r.moves = push(r.moves, info, MAX_MOVES)
  end
  local function diff(after, before)
    local out = {}
    for name, n in pairs(after) do if n ~= (before[name] or 0) then out[name] = n - (before[name] or 0) end end
    for name, n in pairs(before) do if after[name] == nil then out[name] = -n end end
    return out
  end
  local function where(e) return {entity=e.name, position=at(e.position), surface=e.surface.name, tick=game.tick} end

  local on = {}
  function on.on_built_entity(event)
    local p, e = human(event.player_index), event.entity
    if not p or not (e and e.valid) then return end
    local r = record(p)
    local ghost = e.type == 'entity-ghost'
    r.built = push(r.built, {tick=game.tick, name=ghost and e.ghost_name or e.name, ghost=ghost or nil,
      position={x=e.position.x, y=e.position.y}, surface=e.surface.name}, MAX_BUILT)
  end
  function on.on_player_mined_entity(event)
    local e = event.entity
    if e and e.valid then drop(key(e) .. ':deconstruct') end
    removed(event.player_index, e, 'mined')
  end
  -- Robots carry out an order: the removal is the orderer's.
  function on.on_robot_mined_entity(event)
    local e = event.entity
    if not (e and e.valid) then return end
    local k = key(e) .. ':deconstruct'
    local o = store().orders[k]
    if not o then return end
    drop(k)
    removed(o.player, e, 'robot')
  end
  function on.on_entity_died(event)
    local cause, index = event.cause, nil
    if not (cause and cause.valid) then return end
    pcall(function()
      if cause.type == 'character' then index = cause.player and cause.player.index
      elseif cause.get_driver then
        local driver = cause.get_driver()
        -- get_driver gives a LuaPlayer or a character entity.
        if driver then index = driver.object_name == 'LuaPlayer' and driver.index or driver.player and driver.player.index end
      end
    end)
    removed(index, event.entity, 'destroyed')
  end
  local function ordered(event, kind)
    local p, e = human(event.player_index), event.entity
    if not p or not (e and e.valid) then return end
    local s = store()
    local k = key(e) .. ':' .. kind
    if not s.orders[k] then
      if s.order_count >= MAX_ORDERS then s.dropped_orders = s.dropped_orders + 1; return end
      s.order_count = s.order_count + 1
    end
    s.orders[k] = {player=p.index, kind=kind, entity=e, tick=game.tick, name=e.name, position={x=e.position.x, y=e.position.y}}
    if not NOT_WORK[e.type] then burst(p, record(p), kind, e) else record(p) end
  end
  local function cancelled(event, kind)
    local e = event.entity
    if not (e and e.valid) then return end
    drop(key(e) .. ':' .. kind)
  end
  function on.on_marked_for_deconstruction(event) ordered(event, 'deconstruct') end
  function on.on_marked_for_upgrade(event) ordered(event, 'upgrade') end
  function on.on_cancelled_deconstruction(event) cancelled(event, 'deconstruct') end
  function on.on_cancelled_upgrade(event) cancelled(event, 'upgrade') end
  -- A chest or vehicle opened by hand: its contents now, compared on close.
  function on.on_gui_opened(event)
    local p = human(event.player_index)
    local inventory = p and inventory_of(event.entity)
    if not inventory then return end
    record(p).open = {entity=event.entity, contents=contents(inventory)}
  end
  function on.on_gui_closed(event)
    local p = human(event.player_index)
    if not p then return end
    local r = record(p)
    local open = r.open
    r.open = nil
    if not (open and open.entity and open.entity.valid) then return end
    -- The chest's loss is the player's gain.
    local delta = diff(open.contents, contents(inventory_of(open.entity)))
    move(r, where(open.entity), delta)
  end
  -- Ctrl-click transfers carry no counts: pair the transfer with the change
  -- of the player's main inventory in the same tick, in either order.
  function on.on_player_fast_transferred(event)
    local p, e = human(event.player_index), event.entity
    if not p or not (e and e.valid) then return end
    local r = record(p)
    local info = where(e)
    if r.delta and r.delta.tick == game.tick then move(r, info, r.delta.change); r.delta = nil
    else r.fast = info end
  end
  function on.on_player_main_inventory_changed(event)
    local p = human(event.player_index)
    if not p then return end
    local r = record(p)
    local now = contents(p.get_main_inventory())
    local before = r.inventory
    r.inventory = now
    if not before then return end
    local change = diff(now, before)
    if r.fast and r.fast.tick == game.tick then move(r, r.fast, change); r.fast = nil
    else r.delta = {tick=game.tick, change=change} end
  end
  function on.on_player_joined_game(event)
    local p = human(event.player_index)
    if not p then return end
    record(p).joined_tick = game.tick
    local guest = p.permission_group and p.permission_group.name == GUEST
    api.notice('players', p.name .. ' joined the game' .. (guest and ' (guest group)' or ''))
  end
  function on.on_player_left_game(event)
    local p = human(event.player_index)
    if not p then return end
    record(p).left_tick = game.tick
    api.notice('players', p.name .. ' left the game')
  end
  function M.on_event(event)
    local name = M.events[event.name]
    if name and on[name] then on[name](event) end
  end

  -- Reads ----------------------------------------------------------------
  local function group(p)
    local g = p.permission_group
    if not g then return 'none' end
    if g.name == GUEST then return 'guest' end
    if g.name == 'Default' then return 'normal' end
    return g.name
  end
  local function box(list)
    local l, t, r, b
    for _, item in ipairs(list) do
      local x, y = item.position.x, item.position.y
      l = l and math.min(l, x) or x; t = t and math.min(t, y) or y
      r = r and math.max(r, x) or x; b = b and math.max(b, y) or y
    end
    if not l then return nil end
    return {left_top={x=math.floor(l), y=math.floor(t)}, right_bottom={x=math.ceil(r), y=math.ceil(b)}}
  end
  -- Counts by name, the 8 largest, the rest as one "+N more".
  local function counted(list)
    local by, names = {}, {}
    for _, item in ipairs(list) do
      if not by[item.name] then by[item.name] = 0; names[#names+1] = item.name end
      by[item.name] = by[item.name] + 1
    end
    table.sort(names, function(a, b) if by[a] ~= by[b] then return by[a] > by[b] end return a < b end)
    local out = {}
    for i, name in ipairs(names) do
      if i > 8 then out['+' .. (#names - 8) .. ' more kinds'] = #list; break end
      out[name] = by[name]
    end
    return out
  end
  local function since(list, tick)
    local out = {}
    for _, item in ipairs(list) do if item.tick >= tick then out[#out+1] = item end end
    return out
  end
  local function seconds(ticks) return math.floor(ticks / 60) end
  local function pending_orders(index)
    local out = {deconstruct={}, upgrade={}}
    local s = store()
    for k, o in pairs(s.orders) do
      local e = o.entity
      local live = e and e.valid and (o.kind == 'deconstruct' and e.to_be_deconstructed() or o.kind == 'upgrade' and e.to_be_upgraded())
      if not live then drop(k)
      elseif o.player == index then table.insert(out[o.kind], o) end
    end
    return out
  end
  local function summary(p, from)
    local r = store().by_index[p.index] or {built={}, removed={}, moves={}}
    local out = {name=p.name, online=p.connected, group=group(p)}
    if p.connected then out.position = at(p.position); out.surface = p.surface.name end
    if r.left_tick and not p.connected then out.left_s_ago = seconds(game.tick - r.left_tick) end
    local built, gone = since(r.built, from), since(r.removed, from)
    if #built > 0 then out.built = {count=#built, items=counted(built), area=box(built)} end
    if #gone > 0 then
      local how, open = {}, 0
      for _, item in ipairs(gone) do
        how[item.how] = (how[item.how] or 0) + 1
        if not item.restored then open = open + 1 end
      end
      out.removed = {count=#gone, items=counted(gone), area=box(gone), how=how, not_restored=open}
    end
    local orders = pending_orders(p.index)
    for kind, list in pairs(orders) do
      if #list > 0 then
        out.pending_orders = out.pending_orders or {}
        out.pending_orders[kind] = {count=#list, items=counted(list), area=box(list)}
      end
    end
    local moves = since(r.moves, from)
    if #moves > 0 then
      out.moves = {}
      for i = math.max(1, #moves - 4), #moves do
        local m = moves[i]
        out.moves[#out.moves+1] = {s_ago=seconds(game.tick - m.tick), entity=m.entity, position=m.position, took=m.took, put=m.put}
      end
      if #moves > 5 then out.moves_not_shown = #moves - 5 end
    end
    return out
  end
  local function minutes_arg(v, default)
    if v == nil then return default end
    assert(type(v) == 'number' and v == math.floor(v) and v >= 1 and v <= 240, 'minutes must be a whole number 1..240')
    return v
  end
  local function humans()
    local out = {}
    for _, p in pairs(game.players) do if api.is_human(p.index) then out[#out+1] = p end end
    table.sort(out, function(a, b) return a.index < b.index end)
    return out
  end
  local function find(name)
    assert(type(name) == 'string' and #name > 0, 'player must be a player name')
    local p = game.get_player(name)
    assert(p and p.valid and api.is_human(p.index), 'no human player named ' .. name .. ' (players lists them)')
    return p
  end
  M.find, M.group = find, group
  M.schema = {
    players = {minutes='optional 1..240: the window for builds, removals and moves (default 10)', player='optional name: only that player',
      returns='human players (bots and camera clients excluded) with online, group (guest|normal|...), position, and in the window: built and removed (count, items by name, area, how: mined|robot|destroyed, not_restored), pending_orders (deconstruct, upgrade), moves (big inventory moves: entity, position, took, put); votes on them (open or carried); teammates: each other agent\'s character as the map shows it {name, where, surface, position, distance (on your surface), dead, offline, line}, nearest first (transfer {to_player: NAME} hands items to one within reach)'},
    restore = {player='the human player\'s name', minutes='optional 1..240 (default 30)',
      returns='cancelled (their pending deconstruction and upgrade orders), ghosts (placed where they removed something in the window), already (still there or a ghost already), blocked (something else stands there now), items. Ghosts are orders: robots or agents build them with real items'},
  }
  function M.handlers.players(reader, a)
    local from = game.tick - minutes_arg(a.minutes, 10) * MINUTE
    local out = {}
    if a.player ~= nil then out[1] = summary(find(a.player), from)
    else for _, p in ipairs(humans()) do out[#out+1] = summary(p, from) end end
    local votes = api.votes_on and api.votes_on('player') or {}
    -- the team's characters as the map shows them (d17 batch16 B2): where.lua list
    local team = a.player == nil and api.teammates and reader and api.teammates(reader) or nil
    return {players=out, votes=#votes > 0 and votes or nil, teammates=team and #team > 0 and team or nil,
      note=#out == 0 and 'no human players have joined this map' .. (team and #team > 0 and '; teammates lists the agents\' characters' or '') or nil}
  end
  function M.handlers.restore(p, a)
    local target = find(a.player)
    local from = game.tick - minutes_arg(a.minutes, 30) * MINUTE
    local out = {cancelled=0, ghosts=0, already=0, blocked=0}
    local s = store()
    for k, o in pairs(s.orders) do
      if o.player == target.index then
        local e = o.entity
        if e and e.valid then
          if o.kind == 'deconstruct' and e.to_be_deconstructed() then e.cancel_deconstruction(e.force); out.cancelled = out.cancelled + 1
          elseif o.kind == 'upgrade' and e.to_be_upgraded() then e.cancel_upgrade(e.force); out.cancelled = out.cancelled + 1 end
        end
        drop(k)
      end
    end
    local r = s.by_index[target.index]
    local placed = {}
    for _, item in ipairs(r and r.removed or {}) do
      if item.tick >= from and not item.restored then
        local surface = game.get_surface(item.surface)
        local there = surface and (surface.find_entities_filtered{position=item.position, radius=0.25, name=item.name, limit=1}[1]
          or surface.find_entities_filtered{position=item.position, radius=0.25, ghost_name=item.name, limit=1}[1])
        if there then out.already = out.already + 1; item.restored = game.tick
        elseif surface and surface.can_place_entity{name='entity-ghost', inner_name=item.name, position=item.position,
            direction=item.direction, force=p.force, build_check_type=defines.build_check_type.manual_ghost} then
          local ghost = surface.create_entity{name='entity-ghost', inner_name=item.name, position=item.position, direction=item.direction,
            force=p.force, quality=item.quality, type=item.belt_type, expires=false}
          if ghost and item.recipe then pcall(ghost.set_recipe, item.recipe) end
          if ghost and api.ghost_placed then api.ghost_placed(p, ghost) end
          item.restored = game.tick
          out.ghosts = out.ghosts + 1
          placed[#placed+1] = item
        else out.blocked = out.blocked + 1 end
      end
    end
    out.items = #placed > 0 and counted(placed) or nil
    out.area = box(placed)
    out.note = 'ghosts are orders: robots or agents build them with real items'
    if out.cancelled + out.ghosts > 0 then
      api.notice('players', string.format('%s restored %s\'s last %d minutes: %d orders cancelled, %d ghosts placed', p.name, target.name,
        (game.tick - from) / MINUTE, out.cancelled, out.ghosts))
    end
    return out
  end

  -- Operator (RCON, `operator: true` dispatch) ------------------------------
  function M.operator.players(a)
    return M.handlers.players(nil, a)
  end
  -- trusted: the normal (Default) group; guest: the guest group. control.lua
  -- keeps trusted names out of the guest group when they first join a world.
  function M.operator.player_group(a)
    assert(a.group == 'trusted' or a.group == 'guest', 'group must be trusted or guest')
    local p = find(a.name)
    local s = api.state()
    s.trusted_names = s.trusted_names or {}
    local target = a.group == 'trusted' and game.permissions.get_group('Default') or game.permissions.get_group(GUEST)
    assert(target, 'no permission group ' .. (a.group == 'trusted' and 'Default' or GUEST) .. ' (control.lua creates the guest group)')
    target.add_player(p)
    s.trusted_names[p.name] = a.group == 'trusted' or nil
    return {name=p.name, group=group(p)}
  end
  -- Names control.lua keeps out of the guest group on their first join (a
  -- fresh save has none: start-team.sh sets the operator's own, POG_TRUSTED_PLAYERS).
  function M.operator.trust_names(a)
    assert(type(a.names) == 'table', 'names must be a list of player names')
    local s = api.state()
    s.trusted_names = s.trusted_names or {}
    for _, name in ipairs(a.names) do
      assert(type(name) == 'string' and name:match('^[%w_.%-]+$') and #name <= 60, 'not a player name: ' .. tostring(name))
      s.trusted_names[name] = true
    end
    local out = {}
    for name in pairs(s.trusted_names) do out[#out+1] = name end
    table.sort(out)
    return {trusted_names=out}
  end
  return M
end
