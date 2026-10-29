-- (mt278, private) A team of human players on a multi-team map (multiteam.lua's teams): who joins it, and its freeze.
-- Off until the operator sets it up (mt_humans); nothing here runs on a map without one.
--   mt_humans {team, players={names}, budget_h=10, block_h=1, offline_min=30, warm_min=10, quiet_min=10, day_h=24, test?}
--                the team (one of mt_setup's) and its players; a roster player who joins goes into the team's force at
--                its spawn, in the permission group pog-humans (no blueprint import or library); anyone else who joins
--                stays in the player force as a spectator
--   mt_freeze {start=true, hours?} | {stop=true} | {}   the operator's start or stop; {} reads the state
-- The freeze: a block of at least block_h hours from a daily budget of budget_h (game time: a day is day_h hours of
-- ticks; the harness has no wall clock), asked for by a roster player's chat line "!freeze [HOURS]" or by itself once
-- no roster player has been online for offline_min. It starts after warm_min minutes announced to the team, and never
-- within quiet_min minutes of a hit between the team and another team (a hit during the warm-up starts the wait again).
-- While frozen: a cease-fire both ways with every other team (the earlier settings put back after), the team's
-- players in the group pog-frozen (no action but chat), and its core entities (CORE_TYPES) indestructible, set in
-- steps of at most STEP entities a tick. It ends when its hours are up (an automatic one: once a roster player is back,
-- after block_h at least), on "!unfreeze" after block_h, or when the day's budget runs out.
return function(api)
  local M = {operator={}}
  local TICKS_H, TICKS_MIN = 216000, 3600
  -- production, power and the landing pad: what a sleeping team needs to come back to
  M.CORE_TYPES = {'assembling-machine', 'furnace', 'mining-drill', 'lab', 'rocket-silo', 'agricultural-tower', 'boiler',
    'generator', 'burner-generator', 'reactor', 'heat-pipe', 'fusion-reactor', 'fusion-generator', 'solar-panel',
    'accumulator', 'electric-pole', 'lightning-attractor', 'offshore-pump', 'cargo-landing-pad', 'cargo-bay'}
  M.STEP = 2000   -- entities set destructible or not a tick (mt278: measured on the iMac copy, report-mt278.md)
  local core = {}
  for _, t in ipairs(M.CORE_TYPES) do core[t] = true end
  local GROUP, FROZEN = 'pog-humans', 'pog-frozen'
  local HUMAN_DENY = {'import_blueprint', 'import_blueprint_string', 'import_blueprints_filtered', 'import_permissions_string',
    'open_blueprint_library_gui', 'grab_blueprint_record', 'delete_blueprint_library', 'delete_blueprint_record'}
  local FROZEN_ALLOW = {write_to_console=true, toggle_show_entity_info=true, open_gui=true, close_gui=true,
    open_character_gui=true}

  local function st()
    local s = api.state()
    return s.mt and s.mt.humans
  end
  local function team_force() local h = st(); return h and game.forces[h.team] end
  local function others(h)
    local out = {}
    for _, n in ipairs((api.state().mt or {}).order or {}) do if n ~= h.team then out[#out+1] = n end end
    return out
  end
  local function group(name, setup)
    local g = game.permissions.get_group(name)
    if not g then g = game.permissions.create_group(name); setup(g) end
    return g
  end
  local function human_group()
    return group(GROUP, function(g) for _, a in ipairs(HUMAN_DENY) do g.set_allows_action(defines.input_action[a], false) end end)
  end
  local function frozen_group()
    return group(FROZEN, function(g)
      for name, id in pairs(defines.input_action) do g.set_allows_action(id, FROZEN_ALLOW[name] == true) end
    end)
  end
  local function say(h, text)
    local f = team_force()
    if f then f.print('[freeze] ' .. text) end
    h.log = h.log or {}
    h.log[#h.log+1] = {tick=game.tick, text=text}
    if #h.log > 50 then table.remove(h.log, 1) end
  end
  local function day_used(h)
    local day = math.floor(game.tick / h.day_ticks)
    if h.day ~= day then h.day, h.used = day, 0 end
    local live = h.state == 'frozen' and (game.tick - h.since) or 0
    return h.used + live
  end
  local function online(h)
    for _, p in pairs(game.connected_players) do if h.players[p.name] then return true end end
    return false
  end
  local function quiet(h) return not h.last_fight or game.tick - h.last_fight >= h.quiet_ticks end

  function M.operator.mt_humans(a)
    local s = api.state()
    assert(s.mt and s.mt.teams and s.mt.teams[a.team], 'team: one of the map teams (mt_setup) first: ' .. tostring(a.team))
    assert(type(a.players) == 'table' and #a.players >= 1 and #a.players <= 8, 'players: 1..8 names')
    local h = s.mt.humans or {}
    h.team = a.team
    h.players = {}
    for _, n in ipairs(a.players) do assert(type(n) == 'string' and n ~= '', 'a player name'); h.players[n] = true end
    h.budget_ticks = math.floor((a.budget_h or 10) * TICKS_H)
    h.block_ticks = math.floor((a.block_h or 1) * TICKS_H)
    h.offline_ticks = math.floor((a.offline_min or 30) * TICKS_MIN)
    h.warm_ticks = math.floor((a.warm_min or 10) * TICKS_MIN)
    h.quiet_ticks = math.floor((a.quiet_min or 10) * TICKS_MIN)
    h.day_ticks = math.floor((a.day_h or 24) * TICKS_H)
    -- test=true (a private copy's test): blocks shorter than an hour
    assert((h.block_ticks >= TICKS_H or a.test) and h.budget_ticks >= h.block_ticks, 'a block of 1 h or more, within the budget')
    h.state = h.state or 'off'
    h.used = h.used or 0
    h.offline_since = h.offline_since or game.tick
    s.mt.humans = h
    human_group(); frozen_group()
    local placed = {}
    for _, p in pairs(game.players) do if h.players[p.name] then placed[#placed+1] = M.place(p) end end
    return {team=h.team, players=a.players, placed=placed, budget_h=h.budget_ticks / TICKS_H, block_h=h.block_ticks / TICKS_H}
  end

  -- A roster player into the team: its force, a character at the team's spawn (none while frozen), the group.
  function M.place(p)
    local h, f = st(), team_force()
    if not (h and f and h.players[p.name]) then return nil end
    local surface = game.get_surface('nauvis')
    if p.force ~= f then
      if p.character then p.character.destroy() end
      p.force = f
    end
    if h.state ~= 'frozen' and not p.character and p.connected then
      p.set_controller{type=defines.controllers.god}
      local at = surface.find_non_colliding_position('character', f.get_spawn_position(surface), 32, 0.5) or f.get_spawn_position(surface)
      p.teleport(at, surface)
      p.create_character()
    end
    p.permission_group = h.state == 'frozen' and frozen_group() or human_group()
    return {player=p.name, force=p.force.name, character=p.character ~= nil}
  end

  -- What changes the team's core entities: a list of {entity, unit} to set, worked through STEP a tick (M.tick).
  local function queue(h, value)
    local f = team_force()
    local list = {}
    for _, surface in pairs(game.surfaces) do
      for _, e in ipairs(surface.find_entities_filtered{force=f, type=M.CORE_TYPES}) do
        if value == false and e.destructible then list[#list+1] = e
        elseif value == true then list[#list+1] = e end
      end
    end
    if value == true then
      -- back to destructible: only those the freeze set (an indestructible one of the map's own stays so)
      local set, keep = h.set or {}, {}
      for _, e in ipairs(list) do if e.valid and e.unit_number and set[e.unit_number] then keep[#keep+1] = e end end
      list = keep
    end
    h.queue = {value=value, list=list, at=1}
    return #list
  end
  local function work(h)
    local q = h.queue
    if not q then return end
    local last = math.min(#q.list, q.at + M.STEP - 1)
    h.set = h.set or {}
    for i = q.at, last do
      local e = q.list[i]
      if e.valid then
        e.destructible = q.value
        if e.unit_number then h.set[e.unit_number] = (q.value == false) or nil end
      end
    end
    q.at = last + 1
    if q.at > #q.list then h.queue = nil end
  end

  local function freeze(h)
    local f = team_force()
    h.prev = {}
    for _, o in ipairs(others(h)) do
      local of = game.forces[o]
      h.prev[o] = {mine=f.get_cease_fire(o), theirs=of.get_cease_fire(f)}
      f.set_cease_fire(o, true); of.set_cease_fire(f, true)
    end
    for _, p in pairs(game.players) do
      if h.players[p.name] and p.force == f then p.permission_group = frozen_group() end
    end
    h.state, h.since = 'frozen', game.tick
    local n = queue(h, false)
    say(h, string.format('frozen until tick %d at the latest (%d core entities set indestructible); budget left today %.1f h',
      h.until_tick, n, (h.budget_ticks - day_used(h)) / TICKS_H))
  end
  local function thaw(h, why)
    local f = team_force()
    h.used = day_used(h)
    for o, prev in pairs(h.prev or {}) do
      local of = game.forces[o]
      if of then f.set_cease_fire(o, prev.mine); of.set_cease_fire(f, prev.theirs) end
    end
    h.prev = nil
    h.state, h.since, h.until_tick, h.reason = 'off', nil, nil, nil
    for _, p in pairs(game.players) do if h.players[p.name] and p.force == f then M.place(p) end end
    local n = queue(h, true)
    say(h, 'unfrozen (' .. why .. '): ' .. n .. ' core entities destructible again')
  end

  -- A request: by a player (hours) or by itself (auto). Refused without budget for a block.
  local function request(h, by, hours)
    if h.state ~= 'off' then return 'already ' .. h.state end
    local left = h.budget_ticks - day_used(h)
    if left < h.block_ticks then return string.format('no freeze: %.1f h of today\'s budget left, a block is %.1f h', left / TICKS_H, h.block_ticks / TICKS_H) end
    local want = hours and math.floor(hours * TICKS_H) or h.block_ticks
    want = math.max(h.block_ticks, math.min(want, left))
    h.reason, h.want = by, want
    if quiet(h) then
      h.state, h.warm_until = 'warming', game.tick + h.warm_ticks
      say(h, string.format('freeze in %d minutes (%s, %.1f h)', h.warm_ticks / TICKS_MIN, by, want / TICKS_H))
    else
      h.state = 'waiting'
      say(h, string.format('freeze asked (%s): waiting until %d minutes after the last fight', by, h.quiet_ticks / TICKS_MIN))
    end
    return h.state
  end

  function M.tick(tick)
    local h = st()
    if not h then return end
    if h.queue then work(h) end
    if tick % 60 ~= 47 then return end
    local on = online(h)
    if on then h.offline_since = nil elseif not h.offline_since then h.offline_since = tick end
    if h.state == 'off' and not on and h.offline_since and tick - h.offline_since >= h.offline_ticks then
      request(h, 'auto')
    elseif h.state == 'waiting' and quiet(h) then
      h.state, h.warm_until = 'warming', tick + h.warm_ticks
      say(h, string.format('freeze in %d minutes', h.warm_ticks / TICKS_MIN))
    elseif h.state == 'warming' and tick >= h.warm_until then
      if not quiet(h) then
        h.state = 'waiting'
        say(h, 'freeze put back: a fight in the warm-up')
      else
        h.until_tick = tick + h.want
        freeze(h)
      end
    elseif h.state == 'frozen' then
      local past_min = tick - h.since >= h.block_ticks
      if day_used(h) >= h.budget_ticks then thaw(h, 'the day\'s budget is spent')
      elseif tick >= h.until_tick and (h.reason ~= 'auto' or on) then thaw(h, 'its hours are up')
      elseif h.reason == 'auto' and on and past_min then thaw(h, 'a player is back')
      elseif h.thaw_asked and past_min then h.thaw_asked = nil; thaw(h, 'asked') end
    end
  end

  function M.on_event(event)
    local h = st()
    if not h then return end
    local e = defines.events
    if event.name == e.on_player_joined_game then
      local p = game.get_player(event.player_index)
      if p and h.players[p.name] then M.place(p) end
    elseif event.name == e.on_console_chat then
      local p = event.player_index and game.get_player(event.player_index)
      if not (p and h.players[p.name]) then return end
      local msg = event.message or ''
      local hours = msg:match('^!freeze%s*([%d%.]*)%s*$')
      if hours then
        local r = request(h, p.name, tonumber(hours))
        if r ~= 'warming' and r ~= 'waiting' then say(h, r) end
      elseif msg:match('^!unfreeze%s*$') then
        if h.state == 'warming' or h.state == 'waiting' then h.state = 'off'; say(h, 'freeze called off by ' .. p.name)
        elseif h.state == 'frozen' then
          if game.tick - h.since >= h.block_ticks then h.thaw_asked = true
          else say(h, string.format('a block is %.1f h: unfreeze at tick %d or later', h.block_ticks / TICKS_H, h.since + h.block_ticks)) end
        end
      end
    elseif h.state == 'frozen' and (event.name == e.on_built_entity or event.name == e.on_robot_built_entity
        or event.name == e.script_raised_built or event.name == e.script_raised_revive) then
      local ent = event.entity
      if ent and ent.valid and ent.force.name == h.team and core[ent.type] and ent.destructible then
        ent.destructible = false
        if ent.unit_number then h.set = h.set or {}; h.set[ent.unit_number] = true end
      end
    end
  end

  -- A hit between the team and another team: the time of the last fight (no freeze within quiet_min of it).
  function M.on_damaged(event)
    local h = st()
    if not h then return end
    local by, ent = event.force, event.entity
    if not (by and ent and ent.valid) then return end
    local victim = ent.force.name
    if by.name == victim then return end
    local teams = api.state().mt.teams
    if (by.name == h.team and teams[victim]) or (victim == h.team and teams[by.name]) then h.last_fight = game.tick end
  end

  function M.operator.mt_freeze(a)
    local h = st()
    assert(h, 'no human team (mt_humans first)')
    if a.start then request(h, 'operator', a.hours) end
    if a.stop then
      if h.state == 'frozen' then thaw(h, 'operator') else h.state = 'off' end
    end
    return {team=h.team, state=h.state, since=h.since, until_tick=h.until_tick, warm_until=h.warm_until, reason=h.reason,
      used_h=day_used(h) / TICKS_H, budget_h=h.budget_ticks / TICKS_H, last_fight=h.last_fight, online=online(h),
      offline_since=h.offline_since, queue=h.queue and {value=h.queue.value, left=#h.queue.list - h.queue.at + 1} or nil,
      log=h.log}
  end
  return M
end
