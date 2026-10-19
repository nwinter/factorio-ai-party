-- Bots: script-driven characters (no LuaPlayer, no client) that play by the
-- same rules as a player's character: real walking/mining/crafting time,
-- reach, inventory, no free items. Each bot gets an index above any player
-- index, so active actions, queues and clocks key them like players. Handlers
-- see a proxy exposing the LuaPlayer/LuaControl surface they use, backed by
-- the character entity (LuaControl); LuaPlayer-only parts (cursor building)
-- go through direct placement.
return function(api)
  local M = {}
  local BASE = 1000000
  local RESPAWN_TICKS = 600
  local FALLBACK_ITEMS = {['iron-plate']=8, wood=1, pistol=1, ['firearm-magazine']=10, ['burner-mining-drill']=1, ['stone-furnace']=1}
  M.BASE = BASE
  local function bots()
    local s = api.state()
    s.bots = s.bots or {by_name={}, by_index={}, next=1}
    return s.bots
  end
  function M.is_index(index) return type(index) == 'number' and index > BASE end
  function M.is(p) return type(p) == 'table' and rawget(p, '__bot') ~= nil end
  function M.record(index) return bots().by_index[index] end
  function M.named(name) return bots().by_name[name] end
  function M.index_of(name)
    assert(type(name) == 'string', 'bot must be a string')
    local b = bots().by_name[name]
    assert(b, 'no bot named ' .. name)
    return b.index
  end
  function M.list()
    local out = {}
    for _, b in pairs(bots().by_index) do out[#out+1] = b end
    table.sort(out, function(x, y) return x.index < y.index end)
    return out
  end
  local function alive(b) return b.character ~= nil and b.character.valid end
  M.alive = alive
  local function force_of(b) return game.forces[b.force or 'player'] end
  -- Where the bot is (b.surface: a planet or a platform's surface) and the
  -- planet it last stood on (b.planet), where it respawns, as a player does.
  local function surface_of(b) return game.get_surface(b.surface or 'nauvis') or game.get_surface(1) end
  local function home_of(b) return game.get_surface(b.planet or b.surface or 'nauvis') or game.get_surface(1) end
  -- Why a bot has no body to act with: dead, riding a cargo pod, or aboard.
  local function no_body(b)
    local t = b.travel
    if t and t.state == 'aboard' then
      return string.format('bot %s is aboard platform %s with no body (remote view only): %s', b.name, t.platform, M.ABOARD_NOTE)
    elseif t then
      return string.format('bot %s is riding a cargo pod (%s since tick %d); the ride ends by itself: poll status', b.name, t.state, t.since)
    end
    return 'bot ' .. b.name .. ' is dead'
  end
  local function colour(b)
    local pr = api.profile and api.profile(b.index)
    return pr and pr.rgb or {r=1, g=0.63, b=0.26}
  end
  -- What a proxy answers itself; everything else goes to the character.
  local OWN = {
    index=function(b) return b.index end,
    name=function(b) return b.name end,
    valid=function(b) return bots().by_index[b.index] == b end,
    connected=function() return true end,
    controller_type=function() return defines.controllers.character end,
    physical_controller_type=function() return defines.controllers.character end,
    cheat_mode=function() return false end,
    permission_group=function() return nil end,
    cursor_ghost=function() return nil end,
    character=function(b) return alive(b) and b.character or nil end,
    driving=function(b) return alive(b) and b.character.driving or false end,
    position=function(b) if alive(b) then return b.character.position end return b.position end,
    surface=function(b) if alive(b) then return b.character.surface end return surface_of(b) end,
    force=function(b) if alive(b) then return b.character.force end return force_of(b) end,
    chat_color=colour, color=colour,
    -- Queue changes settle the crafting snapshot around them (crafting.lua).
    begin_crafting=function(b) return function(args) return M.change_queue(b, 'begin_crafting', args) end end,
    cancel_crafting=function(b) return function(args) return M.change_queue(b, 'cancel_crafting', args) end end,
    -- Nobody looks through a bot's screen.
    create_local_flying_text=function() return function() end end,
    print=function() return function() end end,
  }
  function M.change_queue(b, method, args)
    assert(alive(b), no_body(b))
    if api.crafting then api.crafting.flush(b) end
    local result = b.character[method](args)
    if api.crafting then api.crafting.snapshot(b) end
    return result
  end
  function M.proxy(b)
    return setmetatable({__bot=b.name}, {
      __index=function(_, k)
        local own = OWN[k]
        if own then return own(b) end
        assert(alive(b), no_body(b))
        return b.character[k]
      end,
      __newindex=function(_, k, v) if alive(b) then b.character[k] = v end end})
  end
  -- A controllable bot: alive, like player() for a player.
  function M.actor(index, seated)
    local b = bots().by_index[index]
    assert(b, 'bot does not exist')
    -- Aboard a platform: a bodiless proxy on the platform's surface, for the
    -- remote-view actions check_action lets through.
    if b.travel and b.travel.state == 'aboard' then return M.proxy(b) end
    if b.travel then error(no_body(b), 0) end
    if not alive(b) then
      error(string.format('bot %s is dead; it respawns at tick %s (status reports dead_until_tick; fh sleep SECONDS waits and wakes with respawned)', b.name, tostring(b.dead_until_tick)), 0)
    end
    assert(not b.character.driving or (seated and b.character.vehicle), 'the character is in a vehicle: vehicle {exit: true} gets out (reads, chat, crafting, research and remote actions work seated)')
    return M.proxy(b)
  end
  -- The proxy for status and cleanup, dead or alive.
  function M.lookup(index)
    local b = bots().by_index[index]
    return b and M.proxy(b) or nil
  end
  local function items(kind)
    local ok, list = pcall(function()
      if remote.interfaces.freeplay and remote.interfaces.freeplay['get_' .. kind .. '_items'] then
        return remote.call('freeplay', 'get_' .. kind .. '_items')
      end
    end)
    if ok and type(list) == 'table' then return list end
    return kind == 'created' and FALLBACK_ITEMS or {}
  end
  -- A player's character keeps the chunks around it charted and visible; a
  -- character without a player does not, so do it for bots, refreshed every
  -- second (staggered by bot). Charting is asynchronous (a chunk turns visible
  -- within ~40 ticks and stays so for over 8 s), so the box reaches 48 tiles:
  -- a walking bot finds the chunks inside the 32-tile limit already visible.
  local SIGHT, SIGHT_TICKS = 48, 60
  local function look(c)
    local pos = c.position
    c.force.chart(c.surface, {{pos.x - SIGHT, pos.y - SIGHT}, {pos.x + SIGHT, pos.y + SIGHT}})
  end
  -- Each bot has its own spot on rings around the spawn point (12 per ring,
  -- 4 tiles out, then 3 tiles further per ring), so a crowd never stacks up.
  local RING, RING_SIZE, RING_STEP = 4, 12, 3
  function M.slot(origin, slot)
    local ring = math.floor((slot - 1) / RING_SIZE)
    local angle = ((slot - 1) % RING_SIZE) * 2 * math.pi / RING_SIZE + ring * math.pi / RING_SIZE
    local r = RING + ring * RING_STEP
    return {x=origin.x + r * math.cos(angle), y=origin.y + r * math.sin(angle)}
  end
  local SPACING, TRIES = 2, 36
  -- The bot's own slot, or the next one whose free spot keeps SPACING from
  -- every other living bot (obstacles such as the crash site push spots).
  local function spot_for(b, surface, origin)
    local first
    for k = 0, TRIES - 1 do
      local spot = M.slot(origin, (b.slot or 1) + k)
      local pos = surface.find_non_colliding_position('character', spot, 32, 0.5) or spot
      first = first or pos
      local clear = true
      for _, other in pairs(bots().by_index) do
        local c = other ~= b and other.character
        if c and c.valid and c.surface == surface and ((c.position.x - pos.x)^2 + (c.position.y - pos.y)^2)^0.5 < SPACING then clear = false; break end
      end
      if clear then return pos end
    end
    return first
  end
  -- A body on the bot's planet: at its spot by the spawn point, or where a
  -- landing cargo pod came down (at).
  local function spawn(b, kind, at)
    local force, surface = force_of(b), home_of(b)
    if at then pcall(function() surface.request_to_generate_chunks(at, 1); surface.force_generate_chunk_requests() end) end
    local pos = at and (surface.find_non_colliding_position('character', at, 32, 0.5) or at)
      or spot_for(b, surface, force.get_spawn_position(surface))
    local c = surface.create_entity{name='character', position=pos, force=force}
    assert(c, 'could not create the character')
    for name, count in pairs(at and {} or items(kind)) do
      if count > 0 then c.insert{name=name, count=count} end
    end
    b.character = c; b.position = c.position; b.dead_until_tick = nil
    b.surface = surface.name; b.planet = surface.name
    look(c)
    if api.on_spawn then api.on_spawn(b) end
    return c
  end
  function M.create(name)
    assert(type(name) == 'string' and #name <= 16 and name:match('^[a-z][a-z0-9_-]*$'), 'name must match [a-z][a-z0-9_-]{0,15}')
    local all = bots()
    assert(not all.by_name[name], 'a bot named ' .. name .. ' already exists')
    for _, p in pairs(game.players) do assert(p.name ~= name, 'a player is named ' .. name) end
    local b = {name=name, index=BASE+all.next, slot=all.next, force='player', surface='nauvis', planet='nauvis', created_tick=game.tick}
    spawn(b, 'created')
    all.next = all.next + 1
    all.by_name[name] = b; all.by_index[b.index] = b
    return {name=name, unit_number=b.character.unit_number, position=b.character.position, index=b.index}
  end
  -- The character dies where it stands; its corpse keeps the items.
  function M.remove(name)
    local all = bots()
    local b = all.by_name[name]
    assert(b, 'no bot named ' .. tostring(name))
    if api.stop then api.stop(b.index, 'removed') end
    local died = false
    if b.travel and b.travel.kit and b.travel.kit.valid then b.travel.kit.destroy() end
    if alive(b) then
      local c = b.character
      b.character = nil
      died = c.die() and true or false
      if c.valid then c.destroy() end
    end
    all.by_name[name] = nil; all.by_index[b.index] = nil
    return {name=name, removed=true, died=died}
  end
  -- Travel (Space Age) ---------------------------------------------------------
  -- A bot has no LuaPlayer to sit in a platform hub, so its body does not ride:
  -- boarding moves the worn armor and guns into a script inventory and removes
  -- the body, and the bot follows the rocket's own cargo pod up. Aboard, it
  -- acts by remote view, as a player in the hub does. Landing sends a real
  -- cargo pod down from the hub; the body is made again where that pod comes
  -- down, wearing the same armor and guns. Same payload and the game's own
  -- ascent and descent time as a player's trip.
  -- The calls that act by remote view (runtime.lua wraps them): on a platform with platform=NAME, on another surface
  -- (a planet, or a platform by its surface's name) with surface=NAME. Aboard they all work (Sol, 23:13: place_ghosts
  -- with surface=nauvis, and its dry run, were refused as no-body while a player aboard places ghosts on a planet by
  -- remote view); the refusal lists them from here.
  -- blueprint_save and blueprint_capture (Astra, d15 18:35: cloning platform Starling into a new platform Swift).
  -- rotate (Astra, Sol, d15 batch5 D4): ghosts and built belts and inserters by remote view.
  M.PLATFORM_ACTIONS = {'rotate', 'upgrade', 'place_ghosts', 'deconstruct', 'cancel_deconstruction', 'paste', 'blueprint_place', 'blueprint_save', 'blueprint_capture', 'grid', 'scan', 'inspect',
    'configure', 'flush', 'circuit_set', 'circuit', 'wire', 'ports', 'cargo', 'trace', 'power', 'conflicts', 'placements'}
  M.SURFACE_ACTIONS = {'blueprint_save', 'blueprint_capture', 'rates', 'rotate', 'upgrade', 'placements', 'inspect', 'circuit_set', 'circuit', 'wire', 'ores', 'launch', 'configure', 'silo', 'preflight', 'requests',
    'place_ghosts', 'scan', 'conflicts', 'deconstruct', 'cancel_deconstruction', 'trace', 'deliver', 'belt_route', 'pole_route', 'map', 'grid', 'observe'}
  M.ABOARD_NOTE = 'every read (status, scan, inspect, science, supply, networks, platforms, map, ...: of the platform, or of a planet with surface=) but inventory and craftable; '
    .. 'tell, chat, say, operator, board and votes; research; platform_schedule, platform_create, requests (platform= or position=), platform_rearm (platform=), drop (hub items down to the planet) and land; '
    .. 'by remote view with platform=NAME: ' .. table.concat(M.PLATFORM_ACTIONS, ', ') .. '; with surface=NAME (a planet): ' .. table.concat(M.SURFACE_ACTIONS, ', ')
    .. ' (requests there with position); sleep, and wait_until on platform_arrived, platform_left, researched, rocket_ready, rocket_parts or item_count at positions or a named platform hub. '
    .. 'Nothing that needs a body: walking, mining, building or crafting by hand, your inventory'
  -- A ride never ends sooner than MIN_*: should the engine replace a pod
  -- entity on its way (unverified), the ride still takes its time.
  local ASCENT_TICKS, MAX_TRAVEL_TICKS, LAUNCH_WAIT, MIN_ASCENT, MIN_DESCENT = 2400, 18000, 300, 1200, 600
  local KIT = {'character_armor', 'character_guns'}
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  -- What a rider must leave behind first (the same rule as the silo's ride
  -- button, checked in space.launch): crafting in progress and a held stack
  -- would be lost with the body.
  function M.can_board(b)
    assert(alive(b), no_body(b))
    local c = b.character
    assert((try(function() return c.crafting_queue_size end) or 0) == 0, 'finish or cancel hand crafting first: the queue would be lost with the body')
    local held = try(function() return c.cursor_stack end)
    assert(not (held and held.valid_for_read), 'put the held stack away first (only worn armor and guns travel)')
  end
  -- The platform a ride belongs to, by index (names can change or repeat).
  local function find_platform(b, t)
    for _, pl in pairs(force_of(b).platforms or {}) do
      if pl.valid and (t.platform_index and pl.index == t.platform_index or not t.platform_index and pl.name == t.platform) then return pl end
    end
  end
  -- The rider is in the rocket: armor and guns into the kit, body gone, and
  -- the bot rides the rocket's cargo pod (pod may be nil: then a fixed time).
  function M.board(b, platform, pod)
    M.can_board(b)
    local c = b.character
    local size = 0
    for _, k in ipairs(KIT) do local inv = c.get_inventory(defines.inventory[k]); size = size + (inv and #inv or 0) end
    local kit = game.create_inventory(math.max(size, 1))
    local slots, n = {}, 0
    for _, k in ipairs(KIT) do
      local inv = c.get_inventory(defines.inventory[k])
      for j = 1, inv and #inv or 0 do
        n = n + 1
        if inv[j].valid_for_read then kit[n].transfer_stack(inv[j]); slots[#slots+1] = {inv=k, slot=j, kit=n} end
      end
    end
    if api.stop then api.stop(b.index, 'boarded') end
    if api.crafting then api.crafting.forget(b) end
    b.position = c.position
    b.character = nil
    c.destroy()
    b.travel = {state='ascending', platform=platform.name, platform_index=platform.index, from=b.planet, pod=pod, since=game.tick, kit=kit, slots=slots}
    b.trips = (b.trips or 0) + 1
    b.lost = nil; b.landed = nil  -- a new ride: the last one's outcome is stale
    return b.travel
  end
  -- The hub's drop to the planet below: a cargo pod out of the hub's hatch,
  -- bound for the force's landing pad there, else where the bot last stood on
  -- that planet, else its spawn point.
  function M.land(b)
    local t = b.travel
    assert(t and t.state == 'aboard', 'bot ' .. b.name .. ' is not aboard a platform')
    local pl = find_platform(b, t)
    assert(pl and pl.hub and pl.hub.valid, 'platform ' .. t.platform .. ' has no hub')
    t.platform = pl.name
    local loc = pl.space_location
    assert(loc and loc.type == 'planet', 'platform ' .. pl.name .. ' is not stopped at a planet')
    local planet = game.planets[loc.name]
    assert(planet, 'no planet ' .. loc.name)
    local surface = planet.surface or planet.create_surface()
    local force = force_of(b)
    local pad = surface.find_entities_filtered{type='cargo-landing-pad', force=force, limit=1}[1]
    local at = pad and pad.position or (b.spots and b.spots[surface.name]) or force.get_spawn_position(surface)
    local pod = try(function() return pl.hub.create_cargo_pod() end)
    assert(pod and pod.valid, 'the hub has no free cargo hatch right now; try again shortly')
    local dest = {type=defines.cargo_destination.surface, surface=surface}
    if not pad then dest.position = at; dest.land_at_exact_position = true end
    local ok = pcall(function() pod.cargo_pod_destination = dest end)
    if not ok then dest.land_at_exact_position = nil; ok = pcall(function() pod.cargo_pod_destination = dest end) end
    if not ok then pod.destroy(); error('the game refused the cargo pod destination ' .. surface.name, 0) end
    t.state = 'descending'; t.pod = pod; t.since = game.tick; t.to = surface.name; t.at = at; t.pad = pad and true or nil
    t.launch_tick = game.tick
    return {landing=surface.name, at=at, pad=pad and pad.position or nil}
  end
  local function lost(b, tick, why)
    local t = b.travel
    if t.kit and t.kit.valid then t.kit.destroy() end
    b.travel = nil
    b.surface = b.planet
    b.dead_until_tick = tick + RESPAWN_TICKS
    b.deaths = (b.deaths or 0) + 1
    b.lost = why
    if api.stop then api.stop(b.index, 'died') end
  end
  local function arrive(b, tick)
    local t = b.travel
    local pl = find_platform(b, t)
    if not (pl and pl.surface and pl.surface.valid) then return lost(b, tick, 'platform ' .. t.platform .. ' is gone') end
    t.state = 'aboard'; t.pod = nil; t.since = tick; t.arrived = tick
    b.surface = pl.surface.name
    b.position = pl.hub and pl.hub.valid and pl.hub.position or {x=0, y=0}
  end
  -- The body where the pod came down, else by the planet's spawn point; if
  -- neither can be made the ride ends like a death (never an error in the tick).
  local function touch_down(b, tick)
    local t = b.travel
    local was = b.planet
    b.planet = t.to
    local at = t.last_surface == t.to and t.last_position or t.at
    local kit, slots = t.kit, t.slots
    local ok, c = pcall(spawn, b, 'land', at)
    if not ok then ok, c = pcall(spawn, b, 'land') end
    if not ok then b.planet = was; return lost(b, tick, 'no body could be made on ' .. t.to .. ': ' .. tostring(c)) end
    b.travel = nil
    for _, s in ipairs(slots or {}) do
      local inv = c.get_inventory(defines.inventory[s.inv])
      local stack = kit[s.kit]
      if stack.valid_for_read and not (inv and inv[s.slot].transfer_stack(stack)) then c.insert(stack); stack.clear() end
    end
    if kit and kit.valid then kit.destroy() end
    b.landed = {surface=t.to, tick=tick, position=c.position, ticks=tick - t.launch_tick}
  end
  local function follow_pod(b, pod)
    if not (pod and pod.valid) then return false end
    local t = b.travel
    t.last_position = pod.position; t.last_surface = pod.surface.name
    b.position = pod.position; b.surface = pod.surface.name
    return true
  end
  function M.travel_tick(b, tick)
    local t = b.travel
    if t.state == 'ascending' then
      if follow_pod(b, t.pod) then
        -- Delivered pods go away; one that parks on the platform has arrived too.
        local parked = t.last_surface ~= t.from and try(function() return t.pod.cargo_pod_state end) == 'parking'
        if (parked and tick - t.since >= MIN_ASCENT) or tick - t.since > MAX_TRAVEL_TICKS then arrive(b, tick) end
      elseif (t.pod ~= nil and tick - t.since >= MIN_ASCENT) or tick - t.since >= ASCENT_TICKS then
        arrive(b, tick)
      end
    elseif t.state == 'aboard' then
      local pl = find_platform(b, t)
      if not (pl and pl.surface and pl.surface.valid) then return lost(b, tick, 'platform ' .. t.platform .. ' is gone') end
      t.platform = pl.name
      if tick % 30 == 0 and pl.hub and pl.hub.valid then b.position = pl.hub.position end
    elseif t.state == 'descending' then
      local pod = t.pod
      if follow_pod(b, pod) then
        -- A pod still sitting in the hatch is pushed off once (it should leave
        -- by itself; the descent stays the game's).
        if not t.pushed and tick - t.since > LAUNCH_WAIT and t.last_surface ~= t.to and try(function() return pod.cargo_pod_state end) == 'awaiting_launch' then
          t.pushed = tick
          pcall(function() pod.force_finish_ascending() end)
        end
        local parked = t.last_surface == t.to and try(function() return pod.cargo_pod_state end) == 'parking'
        if (parked and tick - t.since >= MIN_DESCENT) or tick - t.since > MAX_TRAVEL_TICKS then touch_down(b, tick) end
      elseif tick - t.since >= MIN_DESCENT then
        touch_down(b, tick)
      end
    end
  end
  -- What carries a bot with no body: its cargo pod, else the hub of the platform
  -- it is aboard (name tags ride on it).
  function M.carrier(b)
    local t = b and b.travel
    if not t then return nil end
    if t.pod and t.pod.valid then return t.pod end
    if t.state == 'aboard' then
      local pl = find_platform(b, t)
      if pl and pl.hub and pl.hub.valid then return pl.hub end
    end
  end
  -- Aboard, the bot does what a player in the hub can: remote view.
  local ABOARD = {status=true, describe=true, platforms=true, platform_create=true, platform_schedule=true, platform_rename=true, land=true, drop=true, drops=true, game_alerts=true,
    review=true, networks=true, boilers=true, research=true, research_next=true, technologies=true, recipes=true, say=true, chat=true, confess=true, confessions=true, chronicle=true,
    profile=true, clock=true, advance=true, sleep=true, sleep_check=true, wait_ticks=true, queue_status=true, queue_cancel=true, queue_submit=true, queue_repeat=true, queue_edit=true, queue_resume=true, queue_pause=true,
    blueprint_import=true, blueprint_list=true, blueprint_export=true, blueprint_delete=true, cameras=true, profiles=true, ports=true, cargo=true}
  local ON_PLATFORM, ON_SURFACE = {}, {}
  for _, name in ipairs(M.PLATFORM_ACTIONS) do ON_PLATFORM[name] = true end
  for _, name in ipairs(M.SURFACE_ACTIONS) do ON_SURFACE[name] = true end
  local VIEWS = {platforms=true, sleep_check=true}
  -- Astra, 18:16: aboard, tell, operator, scan with platform, science and wait_until platform_arrived were refused while
  -- the refusal said grid/scan work. The team's calls work aboard, as every read does (the runtime's read-only list,
  -- api.read_only) but the two about the character's own inventory; so do waits on conditions that need no body.
  local TEAM = {tell=true, tells=true, operator=true, board=true, lessons=true, lesson_add=true, lesson_edit=true, lesson_verify=true, board_post=true, board_update=true, board_plan=true, board_events=true,
    vote=true, votes=true, lookahead=true, board_review=true, board_retire=true, platform_supply=true, platform_plan=true, shortages=true, damage_log=true, reminders=true, reminder_add=true, reminder_edit=true, reminder_remove=true, reminder_ack=true, reminder_snooze=true}
  local BODY_READS = {inventory=true, craftable=true}
  local BODYLESS_WAITS = {platform_arrived=true, platform_left=true, researched=true, rocket_ready=true, rocket_parts=true, produced=true, platform_built=true}
  function M.check_action(index, action, args)
    local b = bots().by_index[index]
    if not (b and b.travel) then return end
    if b.travel.state ~= 'aboard' then
      if action == 'status' or action == 'describe' or action == 'queue_status' or action == 'queue_cancel' then return end
      error(no_body(b), 0)
    end
    args = type(args) == 'table' and args or {}
    if ABOARD[action] or TEAM[action] then return end
    -- A dry run is checked as the call it tries (dryrun.lua).
    if action == 'dry_run' and type(args.args) == 'table' then return M.check_action(index, args.action, args.args) end
    if ON_PLATFORM[action] and args.platform ~= nil then return end
    if ON_SURFACE[action] and args.surface ~= nil then return end
    if action == 'configure' then return end
    if action == 'requests' and (args.platform ~= nil or args.position ~= nil) then return end
    -- platform_rearm (batch26 A2, Astra request967: the Kestrel II refill loop stopped every flight): item requests the
    -- hub fills, by remote view as the other platform writes.
    if action == 'platform_rearm' and args.platform ~= nil then return end
    if action == 'observe' and VIEWS[args.scope] then return end
    if api.read_only and api.read_only(action) and not BODY_READS[action] and not (action == 'observe' and BODY_READS[args.scope]) then return end
    -- wait_until on a platform, the research, a silo, or counts at positions / a named hub (no body needed).
    if action == 'wait_until' and (BODYLESS_WAITS[args['until']] or (args['until'] == 'item_count' and (args.positions ~= nil or args.position ~= nil or args.platform ~= nil))) then return end
    error(no_body(b), 0)
  end
  -- A bot's corpse (Opus, shift12 15:20: a corpse recovery call). The game leaves a character-corpse where the
  -- character died, stamped with the tick of death; for a bot it names no player (player index 65536, no unit
  -- number), so it is found the tick the death is seen: near the last spot (kept every 30 ticks; within 32 tiles, else
  -- 128 for a fast vehicle), died within the last 2 s, no player's and no other bot's, the newest, then the nearest
  -- (two bots dying the same tick). Kept newest first, up to 5; recover walks to them and takes everything (an emptied
  -- corpse goes, as a player's).
  function M.note_corpse(b, tick)
    local surface = b.surface and game.get_surface(b.surface)
    if not (surface and b.position) then return end
    local taken = {}
    for _, o in pairs(bots().by_index) do
      for _, c in ipairs(o.corpses or {}) do taken[c.surface .. '|' .. c.position.x .. ',' .. c.position.y .. '|' .. c.tick] = true end
    end
    for _, radius in ipairs{32, 128} do
      local best, bt, bd
      for _, k in pairs(surface.find_entities_filtered{type='character-corpse', position=b.position, radius=radius, limit=64}) do
        local t, who = k.character_corpse_tick_of_death, k.character_corpse_player_index
        local dx, dy = k.position.x - b.position.x, k.position.y - b.position.y
        local d = dx * dx + dy * dy
        local okp, player = pcall(function() return who and game.get_player(who) end)
        if not okp then player = nil end
        if t and t <= tick and tick - t <= 120 and not player and not taken[surface.name .. '|' .. k.position.x .. ',' .. k.position.y .. '|' .. t]
          and (not bt or t > bt or (t == bt and d < bd)) then best, bt, bd = k, t, d end
      end
      if best then
        b.corpses = b.corpses or {}
        table.insert(b.corpses, 1, {surface=surface.name, position={x=best.position.x, y=best.position.y}, tick=bt})
        while #b.corpses > 5 do table.remove(b.corpses) end
        return
      end
    end
  end
  -- A bot's corpses still there: {entity, surface, position, tick}, newest first; ones gone are forgotten.
  function M.corpses(index)
    local b = bots().by_index[index]
    if not b then return {} end
    local out, keep = {}, {}
    for _, c in ipairs(b.corpses or {}) do
      local surface = game.get_surface(c.surface)
      local found
      for _, k in pairs(surface and surface.find_entities_filtered{type='character-corpse', position=c.position, radius=0.5, limit=8} or {}) do
        if k.character_corpse_tick_of_death == c.tick then found = k end
      end
      if found then keep[#keep+1] = c; out[#out+1] = {entity=found, surface=c.surface, position=c.position, tick=c.tick} end
    end
    b.corpses = #keep > 0 and keep or nil
    return out
  end
  -- Deaths and respawns, like a player's: the normal respawn delay, then a
  -- fresh character at the spawn point with what a respawning player gets.
  -- A call timed as its own profile part while the operator profile runs (runtime M.timed); else just the call.
  local function timed(label, fn, ...)
    if api.timed then return api.timed(label, fn, ...) end
    return fn(...)
  end
  function M.tick(tick)
    for _, b in pairs(bots().by_index) do
      if b.travel then
        M.travel_tick(b, tick)
      elseif b.character and b.character.valid then
        if tick % 30 == 0 then
          local c = b.character
          b.position = c.position
          -- A planet surface remembers the bot's last spot there (landing).
          if c.surface.name ~= b.surface then b.surface = c.surface.name end
          if c.surface.planet then b.planet = c.surface.name; b.spots = b.spots or {}; b.spots[c.surface.name] = c.position end
        end
        if (tick + b.index) % SIGHT_TICKS == 0 then timed('bots.look', look, b.character) end
        if api.crafting then api.crafting.tick(b, tick) end
      elseif not b.dead_until_tick then
        b.character = nil
        b.dead_until_tick = tick + RESPAWN_TICKS
        b.deaths = (b.deaths or 0) + 1
        -- Its corpse, for recover (runtime.lua): never fatal to the tick.
        pcall(timed, 'bots.note_corpse', M.note_corpse, b, tick)
        if api.crafting then api.crafting.forget(b) end
        if api.stop then api.stop(b.index, 'died') end
      elseif tick >= b.dead_until_tick then
        timed('bots.respawn', spawn, b, 'respawn')
      end
    end
  end
  function M.status(index, out)
    local b = bots().by_index[index]
    if not b or type(out) ~= 'table' then return out end
    out.bot = true; out.name = b.name; out.dead_until_tick = b.dead_until_tick; out.deaths = b.deaths
    -- Where it is: a planet, a platform (aboard) or a cargo pod between them.
    out.surface = alive(b) and b.character.surface.name or b.surface; out.planet = b.planet
    local t = b.travel
    if t then
      out.platform = t.platform
      out.travel = {state=t.state, platform=t.platform, from=t.from, to=t.to, since_tick=t.since,
        note=t.state == 'aboard' and M.ABOARD_NOTE or 'riding a cargo pod; it arrives by itself'}
    end
    if b.landed then out.landed = b.landed end
    if b.lost then out.lost = b.lost end
    return out
  end
  -- Mining through the engine, except a character corpse: the engine's
  -- corpse pickup assumes a player and crashes the game for a playerless
  -- character. Taking a corpse moves its items to the inventory (what fits);
  -- the corpse goes once it is empty, as for a player.
  function M.mine(p, e)
    if not (M.is(p) and e.type == 'character-corpse') then return p.mine_entity(e, false) end
    local from = e.get_inventory(defines.inventory.character_corpse)
    local to = p.get_main_inventory()
    for i = 1, #from do
      local stack = from[i]
      if stack.valid_for_read then
        local moved = to.insert(stack)
        if moved >= stack.count then stack.clear() elseif moved > 0 then stack.count = stack.count - moved end
      end
    end
    if not from.is_empty() then return false end
    e.destroy()
    return true
  end
  -- The engine ignores repair_state on a character without a player, so a
  -- bot repairs by script: the held tool heals speed/2 HP per tick (a repair
  -- pack, speed 2: 60 HP/s), scaled by the target's repair speed modifier,
  -- and loses that much durability, like a player's repair.
  function M.repair(p, e)
    local tool = p.cursor_stack
    local ok, modifier = pcall(function() return e.prototype.repair_speed_modifier end)
    local heal = math.min(e.max_health - e.health, tool.prototype.speed / 2 * (ok and modifier or 1), tool.durability)
    if heal <= 0 then return end
    e.health = e.health + heal
    tool.drain_durability(heal)
  end
  -- A borrowed cursor goes back to the inventory (clear_cursor does nothing
  -- for a character without a player); what does not fit stays held.
  function M.clear_cursor(p)
    local held = p.cursor_stack
    if not (held and held.valid_for_read) then return end
    local moved = p.get_main_inventory().insert(held)
    if moved >= held.count then held.clear() elseif moved > 0 then held.count = held.count - moved end
  end
  -- Tiles without a cursor, one item per tile placed, by the game's rules
  -- (dryrun.lua hand_tile): the item's tile list and condition (landfill on
  -- water and wetland, never on lava), protected entities on the tile block
  -- it and are named, and what does not block a tile (water-cane, fish) goes
  -- with it. Sol, shift12 12:55: landfill on a Gleba tile with a water-cane
  -- kept failing with "blocked or already there"; set_tiles counts the cane,
  -- the game's tile building does not.
  function M.place_tiles(p, a, stack, pos, size)
    local result = stack.prototype.place_as_tile_result
    local tile = result.result
    local surface, inv = p.surface, p.get_main_inventory()
    local quality = a.quality or 'normal'
    local have = inv.get_item_count{name=a.item, quality=quality}
    local x0, y0 = math.floor(pos.x - (size - 1) / 2), math.floor(pos.y - (size - 1) / 2)
    -- The tile or its frozen or thawed variant (Sol, shift17 61h20: concrete laid on Aquilo reads frozen-concrete,
    -- so every tile counted as not placed and the build failed "no tile was placed" after laying the floor).
    local same = {[tile.name]=true}
    for _, k in ipairs({'frozen_variant', 'thawed_variant'}) do
      local ok, v = pcall(function() return tile[k] end)
      if ok and v then same[v.name] = true end
    end
    -- Without the dry run module: the item's own tile rules.
    local function rules(x, y)
      local here = surface.get_tile(x, y)
      if same[here.name] then return {already=true} end
      local ok = true
      if result.tile_condition then
        ok = false
        for _, t in ipairs(result.tile_condition) do if (type(t) == 'string' and t or t.name) == here.name then ok = true end end
      end
      local hit = false
      for layer in pairs(result.condition and result.condition.layers or {}) do
        if here.prototype.collision_mask.layers[layer] then hit = true end
      end
      if hit ~= (result.invert == true) then ok = false end
      return ok and {removes={}} or {why=a.item..' cannot go on '..here.name}
    end
    local function verdict(x, y) return api.hand_tile and api.hand_tile(surface, p.force, a.item, x, y) or rules(x, y) end
    -- Refusals by reason: '(68.5,45.5) (69.5,45.5): blocked by ...'.
    local reasons, by_reason, refused = {}, {}, 0
    local function refuse(x, y, why)
      local r = by_reason[why]
      if not r then r = {}; by_reason[why] = r; reasons[#reasons+1] = why end
      r[#r+1] = string.format('(%g,%g)', x + 0.5, y + 0.5)
      refused = refused + 1
    end
    local function refusals()
      local parts = {}
      for i, why in ipairs(reasons) do
        if i > 4 then parts[#parts+1] = string.format('%d more reasons', #reasons - 4); break end
        parts[#parts+1] = table.concat(by_reason[why], ' ')..': '..why
      end
      return table.concat(parts, '; ')
    end
    local tiles, hidden, removes, short = {}, {}, {}, 0
    for dx = 0, size - 1 do
      for dy = 0, size - 1 do
        local x, y = x0 + dx, y0 + dy
        local v = verdict(x, y)
        if v.already then refuse(x, y, tile.name..' is there already')
        elseif v.why then refuse(x, y, v.why)
        elseif #tiles >= have then short = short + 1
        else
          tiles[#tiles+1] = {name=tile.name, position={x, y}}
          for _, e in ipairs(v.removes or {}) do removes[#removes+1] = e end
          if tile.mineable_properties and tile.mineable_properties.minable then hidden[#hidden+1] = {pos={x, y}, name=surface.get_tile(x, y).name} end
        end
      end
    end
    if #tiles == 0 then error('no tile was placed: '..refusals(), 0) end
    -- A tile ghost of this tile is what the build fulfils, as a player's
    -- does; left in place it aborts set_tiles (2.0.77: construct never laid
    -- the landfill ghost under a pole on wetland). Put back where no tile went.
    local fulfilled = {}
    for _, t in ipairs(tiles) do
      for _, g in pairs(surface.find_entities_filtered{position={t.position[1] + 0.5, t.position[2] + 0.5}, radius=0.1, type='tile-ghost'}) do
        if g.valid and g.ghost_name == tile.name then fulfilled[#fulfilled+1] = {position=g.position, force=g.force}; g.destroy() end
      end
    end
    -- What does not block a tile goes with it (2.0.77: robots laid landfill
    -- over an unmarked water-cane and it was gone); set_tiles would refuse it.
    local removed = #removes > 0 and api.removes_text and api.removes_text(removes) or nil
    for _, e in ipairs(removes) do if e.valid then e.destroy{raise_destroy=true} end end
    surface.set_tiles(tiles, true, 'abort_on_collision', true, true)
    local placed = 0
    for _, t in ipairs(tiles) do
      local x, y = t.position[1], t.position[2]
      if same[surface.get_tile(x, y).name] then placed = placed + 1
      else
        local ok, v = pcall(verdict, x, y)
        refuse(x, y, ok and v.why or 'the game refused it there')
      end
    end
    for _, g in ipairs(fulfilled) do
      if not same[surface.get_tile(g.position.x, g.position.y).name] then
        pcall(surface.create_entity, {name='tile-ghost', inner_name=tile.name, position=g.position, force=g.force})
      end
    end
    for _, h in ipairs(hidden) do pcall(surface.set_hidden_tile, h.pos, h.name) end
    if placed == 0 then error('no tile was placed: '..refusals(), 0) end
    inv.remove{name=a.item, quality=quality, count=placed}
    local missed = refused > 0 and string.format('%d of %d tiles: %s', refused, placed + refused + short, refusals()) or nil
    if short > 0 then missed = (missed and missed..'; ' or '')..string.format('%d with no %s left', short, a.item) end
    return {consumed=placed, tile=tile.name, position={x=math.floor(pos.x)+0.5, y=math.floor(pos.y)+0.5}, not_placed=missed,
      removed=removed, removed_note=removed and M.REMOVED_NOTE or nil}
  end
  M.REMOVED_NOTE = 'water-cane and fish do not block a tile; a new tile takes them away'
  return M
end
