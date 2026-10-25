-- Vehicles, as a player uses them: get in (the driver's seat if free, else a
-- car's or spidertron's passenger seat; a locomotive or wagon of a train),
-- get out, drive a car or tank to a position (a timed action steering like a
-- player holding the keys), send a spidertron walking (autopilot, from inside
-- or out). A character in a vehicle may use reads, chat, crafting, research,
-- ghosts and other remote-view actions; actions that move or use the body
-- need it out first (runtime.lua's guard).
return function(api)
  local M = {handlers={}}
  local SEATED = {car=true, ['spider-vehicle']=true, locomotive=true, ['cargo-wagon']=true, ['fluid-wagon']=true, ['artillery-wagon']=true}
  local ENTER_REACH = 10
  M.schema = {
    vehicle = {position='{x,y} of a car, tank, spidertron, locomotive or wagon (enter within 10 tiles; go_to: a spidertron in sight); a spidertron with nothing else: a read of its route and stall; another vehicle with no enter, go_to or targeting switch: refused, naming enter: true',
      enter='true: get in (driver seat if free, else a car or spidertron passenger seat); a train you ride runs its schedule as usual',
      exit='true: get out of the vehicle you are in',
      drive='{x,y}: drive the car or tank you are driving to there (a timed action: outcomes arrived | blocked | unreachable | no_safe_route | timed_out; ticks 1..36000, default 3600; arrived: stopped within 3 tiles of the target, or at the end of the path to open ground near it (last.stopped_short); last.distance_left: tiles from where it stopped to the target, and last.arrive_rule). It follows the engine\'s path for the vehicle\'s turning room (a square as wide as its diagonal plus a tile): to the target, else to open ground within 8 then 13 tiles of it (last.stopped_short), else for its length or width only when none of our entities lies within its turning room of that path (else unreachable, naming them). It slows to stop before the path\'s end and before sharp turns, steers no more than 2 tiles past a turn, and brakes to stop 0.5 tiles before any of our entities in its way, turning on the spot only with none within its corners\' sweep (last.spared names them; units it pushes through, ours never). Neither moving nor turning for 1.5 s: it backs off 1 s (not into ours) and asks for a path again, once (last.backed_up); stuck again it ends blocked (last.why names what is in front, or the entity of ours it stopped for)',
      dry_run='with drive: true: the path the drive would take, without moving (a timed action of a few ticks: fh --wait): last.preview {path (its corners), path_length, plan, ends, short_of, touches (our entities within the vehicle\'s half-diagonal of the path: what it would touch turning there; none), nearest_ours}; outcome previewed, or unreachable as the drive would end',
      pathfind='with drive: default true; false steers straight at the target',
      reverse='with drive: optional true: back there, rear first (to back out of a crowd or off an obstacle). Units in the way (biters, pentapods) are no block: it keeps the throttle and pushes through, as a player holding the key does; last.rammed counts the units it pressed against or hit. Buildings, cliffs, rocks and water stop it',
      avoid_enemies='with drive: as move_to (default: worms\' range + 4; true: worms and spawners + 8; a margin 0..32; false: no check)',
      go_to='{x,y}, or a list of 1..16: a spidertron walks there by itself (the one at position in sight, the one you are in, or with remote: true the one vehicle names, by remote view in a chunk our force sees). mode "replace" (the default, as a click on its remote): the route becomes these targets; "append" (as a shift-click): they go at the end. Returns route (the targets queued, in order), route_line, replaced (the targets it had); a target its legs cannot reach (deep water, cliffs on the straight line) keeps it standing with the target kept: a stall (spiderroute.lua) is said in your next reply once 10 s pass with no progress, and in status spidertrons',
      mode='with go_to: "replace" (default) or "append". (d22 batch101 BK1) go_to appended before: replace is the default as a click on the remote replaces the route; a call to a spidertron with no route left does the same either way',
      clear='true: empty the spidertron\'s route (it stops where it is); with go_to the route becomes go_to',
      auto_target_without_gunner='true or false: the spidertron GUI\'s switch (it fires its own ammo at enemies in range with nobody aboard); the spidertron at position, the one you ride, or with remote: true the one vehicle names; returns targeting (both switches as they stand)',
      auto_target_with_gunner='true or false: the other switch of the spidertron GUI, as auto_target_without_gunner',
      remote='with drive: true: drive one of our cars or tanks by remote view while the character stays where it is, as 2.0 lets a player (operator 08:32: to cut character deaths). vehicle names it. Refused, as the game refuses, when it is in no chunk our force sees now (radar coverage or a character\'s sight; the refusal names the nearest coverage), when someone sits in its driver seat or another agent drives it remotely, and for a spidertron (go_to) or a train. The drive ends out_of_coverage when the vehicle leaves the chunks our force sees, and driver_seated when someone gets into its driver seat. Its guns stay silent: a vehicle\'s guns fire for a gunner seated in it or a player driving it remotely, and an agent\'s character has no player',
      vehicle='with remote: the car or tank (drive), or the spidertron (go_to, the targeting switches), by unit_number or {x,y} (any tile of it)',
      combat='with drive, seated as the gunner: true or a radius 1..36: the guns fire at the nearest enemy in range for the whole drive, as shoot auto does, and stop with it; last.shots (rounds fired), last.ammo_used, last.kills and kills_by_name (refused with remote)',
      retreat='with drive: optional {to: {x,y}, health_below: 0..1, shield_below: 0..1} (any one triggers; default health_below 0.4): when the vehicle\'s health or its grid\'s shield falls under it during the drive, the drive ends retreated and the vehicle is driven back to `to` at once (guns on when seated); false: not even the standing retreat_guard. With go_to the same for the spidertron while it has a route (else the standing retreat_guard of its sender, else of the agent riding it), read every 30 ticks: under it and lower than when sent, its route is replaced by one to `to` (as a click on its remote), then held: go_to and clear on it refused until re-armed (retreat_guard set or cleared, or a go_to with its own retreat); a sleep wakes and a direct wait ends (spidertron_retreated); the reply\'s retreat says what watches it; team.spidertron_retreated {why, from, health, shield, to, replaced, route_line, guard} in your next reply, and status spidertrons',
      ticks='with drive', returns='vehicle (name, position, seat, speed) or vehicle=false when on foot'},
  }
  local TYPES = {}
  for t in pairs(SEATED) do TYPES[#TYPES+1] = t end
  table.sort(TYPES)
  -- The vehicle at a position: only vehicles count, so the rail under a
  -- locomotive does not make the target ambiguous (live check 00:40).
  local function find_vehicle(p, a)
    local pos = api.position(a.position)
    api.assert_visible(p, pos, 'vehicle')
    local best, bd
    for _, e in pairs(p.surface.find_entities_filtered{position=pos, radius=2.5, type=TYPES}) do
      if e.valid then
        local d = api.distance(e.position, pos)
        if not bd or d < bd then best, bd = e, d end
      end
    end
    assert(best, string.format('no vehicle at (%g,%g) (car, tank, spidertron, locomotive or wagon)', pos.x, pos.y))
    api.friendly(p, best)
    return best
  end
  local function try_vehicle(p, a)
    local ok, e = pcall(find_vehicle, p, a)
    return ok and e or nil
  end
  -- Who sits in a seat, as a unit number (a player's character, or a character).
  local function unit_of(x)
    if not x then return nil end
    local ok, u = pcall(function()
      if x.object_name == 'LuaPlayer' then return x.character and x.character.unit_number end
      return x.unit_number
    end)
    return ok and u or nil
  end
  local function seat_of(c)
    local v = c.vehicle
    if not (v and v.valid) then return nil end
    local ok, d = pcall(v.get_driver)
    local driver = ok and unit_of(d) ~= nil and unit_of(d) == c.unit_number
    return v, driver and 'driver' or 'passenger'
  end
  local function view(c)
    local v, seat = seat_of(c)
    if not v then return {vehicle=false} end
    local guns = M.guns and M.guns(v) or {}
    local sel = pcall(function() return v.selected_gun_index end) and v.selected_gun_index or nil
    return {vehicle={name=v.name, position=v.position, seat=seat, speed=v.speed and math.floor(v.speed * 216 + 0.5) or nil,
      guns=#guns > 0 and M.gun_lines(guns, sel) or nil}}
  end
  M.view = view
  -- Remote driving (operator 08:32, a viewer via Astra: to cut character
  -- deaths). On a private 2.0.77 copy of world n an empty tank moved under
  -- its own riding_state, so the harness drives it as a remote driver's keys
  -- would, the character standing where it is. Its guns do not fire there:
  -- shooting_state is a character's ("Entity is not character"), and the
  -- auto-targeting parameters are a spidertron's.
  local function chunk_of(pos) return {x=math.floor(pos.x / 32), y=math.floor(pos.y / 32)} end
  local function in_view(p, v)
    local ok, r = pcall(function() return p.force.is_chunk_visible(v.surface, chunk_of(v.position)) end)
    return ok and r == true
  end
  M.in_view = in_view
  -- Who sits in a seat: an agent's or player's name, else the entity's.
  local function who(x)
    local ok, name = pcall(function()
      if x.object_name == 'LuaPlayer' then return 'player ' .. x.name end
      return api.owner and api.owner(x) and (api.owner(x) .. '\'s character') or x.name
    end)
    return ok and name or 'someone'
  end
  M.who = who
  -- The walk's reads (paths, enemies) at the vehicle: its position and surface, the rest the agent's.
  function M.at_vehicle(p, v)
    return setmetatable({}, {__index=function(_, k)
      if k == 'position' then return v.position elseif k == 'surface' then return v.surface end
      return p[k]
    end})
  end
  local NOT_REMOTE = {['spider-vehicle']='a spidertron walks by itself: vehicle {position, go_to}', locomotive='a train runs its schedule: train',
    ['cargo-wagon']='a wagon goes with its train', ['fluid-wagon']='a wagon goes with its train', ['artillery-wagon']='a wagon goes with its train'}
  -- The car or tank a remote drive takes, refused as the game refuses.
  local function remote_vehicle(p, a)
    local ref = a.vehicle
    if ref == nil then error('remote drive needs vehicle: its unit_number or {x,y}', 0) end
    local v
    if type(ref) == 'number' then
      local ok, e = pcall(function() return game.get_entity_by_unit_number(ref) end)
      v = ok and e or nil
      if not (v and v.valid and SEATED[v.type]) then error('no vehicle has unit_number ' .. tostring(ref), 0) end
    else
      local pos = api.position(ref.position or ref)
      local bd
      for _, e in pairs(p.surface.find_entities_filtered{position=pos, radius=2.5, type=TYPES}) do
        if e.valid then
          local d = api.distance(e.position, pos)
          if not bd or d < bd then v, bd = e, d end
        end
      end
      if not v then error(string.format('no vehicle at (%g,%g) (car or tank)', pos.x, pos.y), 0) end
    end
    local at = string.format('%s (%g,%g)', v.name, math.floor(v.position.x * 10 + 0.5) / 10, math.floor(v.position.y * 10 + 0.5) / 10)
    if v.type ~= 'car' then error(at .. ': remote drive is for a car or tank; ' .. (NOT_REMOTE[v.type] or 'not a car'), 0) end
    if v.force ~= p.force then error(at .. ' is not ours', 0) end
    if not in_view(p, v) then
      error(at .. ' is in no chunk our force sees now (radar coverage or a character\'s sight): remote driving needs it in view' ..
        (api.coverage_note and api.coverage_note(p, v) or ''), 0)
    end
    local okd, driver = pcall(v.get_driver)
    if okd and driver then error(string.format('%s: its driver seat holds %s', at, who(driver)), 0) end
    local other = api.remote_driver and api.remote_driver(v, p.index)
    if other then error(string.format('%s: %s drives it remotely', at, other), 0) end
    return v
  end
  M.remote_vehicle = remote_vehicle
  -- A spidertron by remote view (C5, batch6 F1): by unit_number or {x,y}, ours, in a chunk our force sees now, as the
  -- map lets a player pick it and send it or open its GUI.
  local function remote_spider(p, a)
    local ref = a.vehicle or a.position
    if ref == nil then error('remote: vehicle (the spidertron\'s unit_number or {x,y}) names it', 0) end
    local v
    if type(ref) == 'number' then
      local ok, e = pcall(function() return game.get_entity_by_unit_number(ref) end)
      v = ok and e or nil
    else
      local pos = api.position(ref.position or ref)
      local bd
      for _, e in pairs(p.surface.find_entities_filtered{position=pos, radius=2.5, type='spider-vehicle'}) do
        if e.valid then
          local d = api.distance(e.position, pos)
          if not bd or d < bd then v, bd = e, d end
        end
      end
    end
    if not (v and v.valid and v.type == 'spider-vehicle') then error('no spidertron there (vehicle: its unit_number or {x,y})', 0) end
    if v.force ~= p.force then error(v.name .. ' is not ours', 0) end
    if not in_view(p, v) then
      error(string.format('%s (%g,%g) is in no chunk our force sees now (radar coverage or a character\'s sight): remote view needs it in view', v.name,
        math.floor(v.position.x * 10 + 0.5) / 10, math.floor(v.position.y * 10 + 0.5) / 10), 0)
    end
    return v
  end
  M.remote_spider = remote_spider
  -- The spidertron GUI's two switches: auto target without gunner, auto target with gunner.
  local function targeting(spider, a)
    local cur = spider.vehicle_automatic_targeting_parameters or {}
    local new = {auto_target_without_gunner=cur.auto_target_without_gunner, auto_target_with_gunner=cur.auto_target_with_gunner}
    if a.auto_target_without_gunner ~= nil then new.auto_target_without_gunner = a.auto_target_without_gunner end
    if a.auto_target_with_gunner ~= nil then new.auto_target_with_gunner = a.auto_target_with_gunner end
    spider.vehicle_automatic_targeting_parameters = new
    local now = spider.vehicle_automatic_targeting_parameters
    return {auto_target_without_gunner=now.auto_target_without_gunner, auto_target_with_gunner=now.auto_target_with_gunner}
  end
  -- (d24 batch189 QAE1) a go_to's own retreat: nil (the standing retreat_guard), false (none) or the cfg.
  local function spider_retreat(p, a)
    if a.retreat == nil or a.go_to == nil then return nil end
    if a.retreat == false then return false end
    return api.spider_retreat(p, a)
  end
  function M.handlers.vehicle(p, a)
    local c = p.character
    assert(c and c.valid, 'a living character is required')
    -- error(..., 0), not assert: Factorio's Lua 5.2 assert puts the source line in front of the reason.
    local function refuse(ok, text) if not ok then error(text, 0) end end
    refuse(a.remote == nil or type(a.remote) == 'boolean', 'remote must be true or false')
    local switches = a.auto_target_without_gunner ~= nil or a.auto_target_with_gunner ~= nil
    for _, k in ipairs({'auto_target_without_gunner', 'auto_target_with_gunner'}) do refuse(a[k] == nil or type(a[k]) == 'boolean', k .. ' must be true or false') end
    -- (BK1) remote: true with vehicle alone: a spidertron's route and stall, by remote view (another vehicle: refused)
    local spider_read = a.remote and a.vehicle ~= nil and a.drive == nil and a.go_to == nil and a.clear == nil and not switches and a.enter == nil and a.exit == nil
    local read_e
    if spider_read then
      local ok, e = pcall(remote_spider, p, a)
      if ok then read_e = e elseif not tostring(e):find('no spidertron there', 1, true) then error(e, 0) end
    end
    refuse(not a.remote or a.drive ~= nil or a.go_to ~= nil or a.clear ~= nil or switches or read_e, 'remote goes with drive (a car or tank), go_to, clear or the targeting switches (a spidertron), or alone with vehicle (a spidertron\'s route)')
    if read_e then
      local e = read_e
      local out = {spidertron=e.name, unit_number=e.unit_number, position=e.position, speed=e.speed and math.floor(e.speed * 216 + 0.5) or nil, by='remote view'}
      for k, v in pairs(api.spider_facts(e, api.who and api.who(p) or p.name, p.index)) do out[k] = v end
      return out
    end
    refuse(a.vehicle == nil or a.remote, 'vehicle names the vehicle of a remote call (remote: true)')
    -- The targeting switches (and with go_to, the walk too): the spidertron in reach of its GUI, or by remote view.
    if switches then
      refuse(a.enter == nil and a.exit == nil and a.drive == nil, 'the targeting switches go alone or with go_to')
      local spider = a.remote and remote_spider(p, a) or (a.position and find_vehicle(p, a)) or c.vehicle
      refuse(spider and spider.valid and spider.type == 'spider-vehicle', 'the targeting switches are a spidertron\'s (give its position, remote: true with vehicle, or ride it)')
      local out = {spidertron=spider.name, position=spider.position, targeting=targeting(spider, a), by=a.remote and 'remote view' or nil}
      if a.go_to ~= nil or a.clear ~= nil then
        for k, v in pairs(api.spider_set(spider, a, api.who and api.who(p) or p.name, p.index, spider_retreat(p, a))) do out[k] = v end
        out.go_to = a.go_to
      end
      return out
    end
    local n = (a.enter and 1 or 0) + (a.exit and 1 or 0) + (a.drive and 1 or 0) + ((a.go_to or a.clear) and 1 or 0)
    assert(n <= 1, 'give one of enter, exit, drive, go_to (or clear)')
    refuse(a.mode == nil or a.go_to ~= nil, 'mode goes with go_to')
    if a.enter then
      assert(a.enter == true, 'enter must be true')
      assert(not c.vehicle, 'already in a vehicle: vehicle {exit: true} first')
      local e = find_vehicle(p, a)
      local d = api.distance(c.position, e.position)
      assert(d <= ENTER_REACH, string.format('%s is %.1f tiles away; get within %d tiles to get in', e.name, d, ENTER_REACH))
      local ok, driver = pcall(e.get_driver)
      -- Driven by remote view: its driver seat is taken, as a remote driver's is in the game.
      local remote = api.remote_driver and api.remote_driver(e, p.index)
      if remote then ok, driver = true, remote end
      local seat
      if not (ok and driver) then
        e.set_driver(c); seat = 'driver'
      elseif e.type == 'car' or e.type == 'spider-vehicle' then
        local ok2, passenger = pcall(e.get_passenger)
        assert(not (ok2 and passenger), e.name .. ' is full')
        e.set_passenger(c); seat = 'passenger'
      else
        error(e.name .. ' is taken: its one seat has someone in it', 0)
      end
      -- Read the seat back from the vehicle: the game decides, not the call.
      local okr, who = pcall(seat == 'driver' and e.get_driver or e.get_passenger)
      assert(okr and unit_of(who) == c.unit_number, string.format('the game did not seat the character in %s (its %s seat holds %s)',
        e.name, seat, who and tostring(unit_of(who) or who.name) or 'nobody'))
      local out = view(c)
      if out.vehicle then out.vehicle.seat = seat end
      return out
    end
    if a.exit then
      assert(a.exit == true, 'exit must be true')
      local v, seat = seat_of(c)
      assert(v, 'not in a vehicle')
      if seat == 'driver' then v.set_driver(nil) else v.set_passenger(nil) end
      assert(not c.vehicle, 'the game kept the character in ' .. v.name)
      return {left=v.name, position=c.position, vehicle=false}
    end
    if a.go_to ~= nil or a.clear ~= nil then
      local spider
      if a.remote then spider = remote_spider(p, a)
      elseif a.position then spider = find_vehicle(p, a) else spider = c.vehicle end
      assert(spider and spider.valid and spider.type == 'spider-vehicle', (a.go_to ~= nil and 'go_to' or 'clear') .. ' is for a spidertron (give its position, remote: true with vehicle, or ride it)')
      local out = {spidertron=spider.name, unit_number=spider.unit_number, position=spider.position, go_to=a.go_to, by=a.remote and 'remote view' or nil}
      -- (d22 batch101 BK1) replace (default), append or clear, as the remote does; the route said back. (d24 batch189
      -- QAE1) its own retreat, or false for none; else the standing retreat_guard watches it.
      for k, v in pairs(api.spider_set(spider, a, api.who and api.who(p) or p.name, p.index, spider_retreat(p, a))) do out[k] = v end
      -- A spidertron with a fuel slot and nothing to burn stands still.
      pcall(function()
        local fuel = spider.get_fuel_inventory and spider.get_fuel_inventory()
        local burning = spider.burner and spider.burner.currently_burning
        if fuel and fuel.is_empty() and not burning then
          out.note = 'it has no fuel and will not walk: transfer fuel into it (rocket-fuel, nuclear-fuel, ...)'
        end
      end)
      return out
    end
    if a.drive then
      local v, seat
      if a.remote then
        refuse(a.combat == nil or a.combat == false,
          'combat with remote: a remote drive cannot fire its guns (a vehicle\'s guns fire for a gunner seated in it or a player driving it remotely, and an agent\'s character has no player)')
        v = remote_vehicle(p, a)
      else
        v, seat = seat_of(c)
        assert(v and v.type == 'car', 'drive is for a car or tank you are in (vehicle {position, enter: true} first), or by remote view: remote=true, vehicle=unit_number or {x,y}')
        assert(seat == 'driver', 'only the driver drives')
      end
      local target = api.position(a.drive)
      local ticks = api.integer(a.ticks, 3600, 1, 36000, 'ticks')
      assert(a.pathfind == nil or type(a.pathfind) == 'boolean', 'pathfind must be true or false')
      assert(a.reverse == nil or type(a.reverse) == 'boolean', 'reverse must be true or false')
      refuse(a.dry_run == nil or type(a.dry_run) == 'boolean', 'dry_run must be true or false')
      local dry = a.dry_run == true
      local mode = api.avoid_mode(a.avoid_enemies)
      -- combat (Astra, operator 08:34: shoot runs at most 600 ticks while a drive runs a minute or more): the guns on
      -- auto for the whole drive, as shoot auto; the checks first, so a refused combat starts no drive.
      local caction, cout
      if a.combat ~= nil and a.combat ~= false and not dry then
        assert(a.combat == true or type(a.combat) == 'number', 'combat is true or a radius 1..36')
        caction, cout = M.shoot(p, {auto=true, radius=a.combat ~= true and a.combat or nil}, ticks)
      end
      local action = {kind='drive', target=target, until_tick=game.tick + (dry and math.min(ticks, 1800) or ticks), last=v.position, still=0, vehicle=v,
        reverse=a.reverse or nil, remote=a.remote or nil, dry=dry or nil}
      -- retreat (retreat.lua): checked against the vehicle's health and shield; none on a dry run.
      local back = not dry and api.retreat and api.retreat(p, a) or nil
      api.start(p, action)
      if back then api.arm_retreat(p, action, back) end
      local out = {until_tick=action.until_tick, target=target, vehicle=v.name, distance=math.floor(api.distance(v.position, target)), pathfinding=a.pathfind ~= false,
        reverse=a.reverse or nil, dry_run=dry or nil, retreat=back and api.retreat_line and api.retreat_line(back) or nil,
        note=dry and (a.pathfind ~= false and 'the path is asked for: the preview comes when it ends (last.preview; fh --wait waits for it); the vehicle does not move'
          or 'the straight line to the target: last.preview next tick (fh --wait); the vehicle does not move') or nil}
      if a.remote then
        out.remote = string.format('by remote view: %s (%g,%g), unit_number %d; your character stays at (%g,%g)', v.name,
          math.floor(v.position.x * 10 + 0.5) / 10, math.floor(v.position.y * 10 + 0.5) / 10, v.unit_number, math.floor(c.position.x * 10 + 0.5) / 10,
          math.floor(c.position.y * 10 + 0.5) / 10)
        pcall(function()
          local fuel = v.get_fuel_inventory and v.get_fuel_inventory()
          local burning = v.burner and v.burner.currently_burning
          if fuel and fuel.is_empty() and not burning then out.note = v.name .. ' has no fuel and will not move' end
        end)
      end
      if caction then
        caction.with_drive = true; caction.kills = 0; caction.vehicle_entity = v
        caction.rounds_start = M.rounds(v, caction.slot)
        api.start_combat(p, caction)
        out.combat = {gun=cout.gun, gun_slot=cout.gun_slot, radius=caction.radius, equipped=cout.equipped}
      end
      if a.pathfind ~= false then
        local nav = {position=target, tolerance=3, vehicle=true, vehicle_entity=v}
        action.nav = nav
        local foes = api.avoid_start(a.remote and M.at_vehicle(p, v) or p, nav, mode)
        out.avoid_enemies = foes and api.avoid_describe(foes.mode) or nil
        M.request(p, nav)
      end
      return out
    end
    -- (d17 batch23 C3, Muse three times: vehicle {position} read vehicle: false and seated nobody) a position, or a
    -- drive argument, with no enter, exit, drive or go_to is refused naming what it goes with; vehicle {} alone reads
    -- the seat.
    if a.position ~= nil then
      local e, pos = try_vehicle(p, a), api.position(a.position)
      -- (BK1) a spidertron alone: its route and stall (Opus, shift59 21:42: vehicle {position} to see where it was going)
      if e and e.type == 'spider-vehicle' then
        local out = {spidertron=e.name, unit_number=e.unit_number, position=e.position, speed=e.speed and math.floor(e.speed * 216 + 0.5) or nil}
        for k, v in pairs(api.spider_facts(e, api.who and api.who(p) or p.name, p.index)) do out[k] = v end
        return out
      end
      error(string.format('position names the vehicle for enter: true (get in), go_to or the targeting switches; with none of them nothing is done%s: vehicle {position: {x: %g, y: %g}, enter: true} gets in%s',
        e and ' (' .. e.name .. ' stands there)' or '', pos.x, pos.y,
        c.vehicle and ' (you are in ' .. c.vehicle.name .. ' now: vehicle {exit: true} gets out first)' or ''), 0)
    end
    for _, k in ipairs({'dry_run', 'pathfind', 'reverse', 'avoid_enemies', 'combat', 'retreat', 'ticks'}) do
      if a[k] ~= nil then error(k .. ' goes with drive: {x,y}; with no enter, exit, drive or go_to nothing is done', 0) end
    end
    return view(c)
  end
  -- One tick of a drive: steer toward the target, ease off near it, stop
  -- there. riding_state is what a player's keys set.
  local function angle_to(from, to)
    -- Factorio orientation: 0 north, 0.25 east, clockwise, 0..1.
    local o = (math.atan2 or math.atan)(to.x - from.x, -(to.y - from.y)) / (2 * math.pi)
    return o < 0 and o + 1 or o
  end
  M.angle_to = angle_to
  -- Opus (shift09 03:20): a tank driven straight at its target got stuck on
  -- cliffs and was killed. A drive follows the engine's path for the
  -- vehicle's box (cliffs, water, trees and buildings block it), as a square
  -- as wide as the vehicle's diagonal plus a tile (it turns, and steering a
  -- few tiles ahead cuts corners: on a private copy a tank caught a cliff's
  -- end on a path planned as wide as it is long), else as wide as it is
  -- long, else as wide as it is wide.
  local function halves(v)
    local ok, box = pcall(function() return v.prototype.collision_box end)
    if not (ok and box) then return 1, 0.7 end
    local lt, rb = box.left_top or box[1], box.right_bottom or box[2]
    local w = math.max(math.abs(lt.x or lt[1]), math.abs(rb.x or rb[1]))
    local l = math.max(math.abs(lt.y or lt[2]), math.abs(rb.y or rb[2]))
    return math.max(w, l), math.min(w, l)
  end
  M.halves = halves
  -- Astra (operator 12:06, shift12): a tank drive to (-265,-386), a pocket among our oil pipes, found no path for
  -- the turning box nor the length box; the width box's path ran a V past a pumpjack, the tank swung wide at the V
  -- and crushed 7 of our entities. Plans, in order: the turning box (as wide as the diagonal plus half a tile) to
  -- the target; the same box to open ground near it (within 8, then 13 tiles: the drive stops short there); the
  -- length box, then the width box, each taken only when none of our entities lies within the turning room
  -- (the half-diagonal plus MARGIN) of its path.
  local MARGIN = 0.5
  function M.plans(v)
    local long, short = halves(v)
    local turn = (long * long + short * short) ^ 0.5 + MARGIN
    return {{h=turn, r=0, what='turning room'}, {h=turn, r=4, near=true, what='turning room, near the target'},
      {h=turn, r=9, near=true, what='turning room, near the target'}, {h=long, r=0, narrow=true, what='its length'},
      {h=short, r=0, narrow=true, what='its width'}}
  end
  function M.box_halves(v)
    local out = {}
    for i, plan in ipairs(M.plans(v)) do out[i] = plan.h end
    return out
  end
  function M.request(p, nav)
    local v = nav.vehicle_entity or (p.character and p.character.vehicle)
    if not (v and v.valid) then nav.path_state = 'failed'; return end
    local plans = M.plans(v)
    local plan = plans[math.min(#plans, (nav.path_level or 0) + 1)]
    local h = plan.h
    -- A box that collides where the vehicle stands gets no path at all (2.0.77: a tank parked 1.7 tiles from our
    -- pipe-to-ground); the plan starts at the nearest spot within 5 tiles where it fits, the vehicle driving there first.
    nav.lead = M.free_start(v, h, nav.position)
    nav.path_id = v.surface.request_path{bounding_box={{-h, -h}, {h, h}}, collision_mask=v.prototype.collision_mask, start=nav.lead or v.position,
      goal=nav.position, force=p.force, radius=nav.tolerance + 1 + plan.r, entity_to_ignore=v, can_open_gates=false,
      pathfind_flags={prefer_straight_paths=true, no_break=false, cache=false}}
    api.paths()[nav.path_id] = p.index
    nav.path_state = 'pending'; nav.waypoints = nil; nav.waypoint = nil; nav.asked_tick = game.tick
  end
  -- Geometry: distances from a point or a segment to a box (l, t, r, b).
  local function pt_box(px, py, l, t, r, b)
    local dx = px < l and l - px or (px > r and px - r or 0)
    local dy = py < t and t - py or (py > b and py - b or 0)
    return (dx * dx + dy * dy) ^ 0.5
  end
  local function pt_seg(px, py, ax, ay, bx, by)
    local dx, dy = bx - ax, by - ay
    local L = dx * dx + dy * dy
    local u = L > 0 and math.max(0, math.min(1, ((px - ax) * dx + (py - ay) * dy) / L)) or 0
    local qx, qy = ax + u * dx - px, ay + u * dy - py
    return (qx * qx + qy * qy) ^ 0.5
  end
  local function seg_box(ax, ay, bx, by, l, t, r, b)
    -- The segment crosses the box (Liang-Barsky clip): 0.
    local t0, t1, dx, dy = 0, 1, bx - ax, by - ay
    local ps, qs, inside = {-dx, dx, -dy, dy}, {ax - l, r - ax, ay - t, b - ay}, true
    for i = 1, 4 do
      local pp, qq = ps[i], qs[i]
      if pp == 0 then
        if qq < 0 then inside = false; break end
      else
        local u = qq / pp
        if pp < 0 then if u > t1 then inside = false; break elseif u > t0 then t0 = u end
        else if u < t0 then inside = false; break elseif u < t1 then t1 = u end end
      end
    end
    if inside then return 0 end
    return math.min(pt_box(ax, ay, l, t, r, b), pt_box(bx, by, l, t, r, b), pt_seg(l, t, ax, ay, bx, by), pt_seg(r, t, ax, ay, bx, by),
      pt_seg(l, b, ax, ay, bx, by), pt_seg(r, b, ax, ay, bx, by))
  end
  M.seg_box = seg_box
  -- Our entities a vehicle collides with (its collision layers meet theirs), by name; ghosts, remnants and items on
  -- the ground do not stop it. Characters count only where asked (they move, so a plan ignores them).
  local PASS = {['entity-ghost']=true, ['tile-ghost']=true, corpse=true, ['character-corpse']=true, ['item-request-proxy']=true,
    ['item-entity']=true, ['logistic-robot']=true, ['construction-robot']=true, ['combat-robot']=true}
  local function collider(v)
    local mine, cache = {}, {}
    pcall(function() for layer in pairs(v.prototype.collision_mask.layers) do mine[layer] = true end end)
    return function(e)
      local name = e.name
      local hit = cache[name]
      if hit == nil then
        hit = false
        local ok = pcall(function() for layer in pairs(e.prototype.collision_mask.layers) do if mine[layer] then hit = true; break end end end)
        if not ok then hit = false end
        cache[name] = hit
      end
      return hit
    end
  end
  local function at(e) return string.format('%s (%g,%g)', e.name, math.floor(e.position.x * 2 + 0.5) / 2, math.floor(e.position.y * 2 + 0.5) / 2) end
  M.at = at
  -- Whether a square box of half-size h at pos is free of what blocks the vehicle (entities whose layers meet its
  -- own, not units or characters, and tiles).
  local function box_free(v, layers, pos, h)
    local area = {{pos.x - h, pos.y - h}, {pos.x + h, pos.y + h}}
    local ok, found = pcall(function() return v.surface.find_entities_filtered{area=area, collision_mask=layers} end)
    if not ok then return true end
    for _, e in ipairs(found) do
      if e.valid and e ~= v and e.type ~= 'character' and e.type ~= 'unit' and not PASS[e.type] then return false end
    end
    local okt, n = pcall(function() return v.surface.count_tiles_filtered{area=area, collision_mask=layers} end)
    return not (okt and n > 0)
  end
  -- Nil when the box fits where the vehicle stands; else the nearest spot within 5 tiles where it fits (toward the
  -- goal on a tie), or nil.
  function M.free_start(v, h, toward)
    local layers = {}
    pcall(function() for layer in pairs(v.prototype.collision_mask.layers) do layers[#layers + 1] = layer end end)
    if #layers == 0 or box_free(v, layers, v.position, h) then return nil end
    local px, py = v.position.x, v.position.y
    for r = 0.5, 5, 0.5 do
      local best, bd
      for k = 0, 15 do
        local a = k * math.pi / 8
        local q = {x=px + math.cos(a) * r, y=py + math.sin(a) * r}
        if box_free(v, layers, q, h) then
          local d = toward and api.distance(q, toward) or 0
          if not bd or d < bd then best, bd = q, d end
        end
      end
      if best then return best end
    end
    return nil
  end
  -- Our entities within clear of a path (a list of points), nearest first: {entity, d} with d the distance from the
  -- path's centre line to the entity's box.
  function M.path_touches(v, surface, force, points, clear, skip)
    local hits, out, best = collider(v), {}, {}
    local along = 0
    for i = 1, #points - 1 do
      local a, b = points[i], points[i + 1]
      if i > 1 then along = along + api.distance(points[i - 1], a) end
      local area = {{math.min(a.x, b.x) - clear, math.min(a.y, b.y) - clear}, {math.max(a.x, b.x) + clear, math.max(a.y, b.y) + clear}}
      local ok, found = pcall(function() return surface.find_entities_filtered{area=area, force=force} end)
      for _, e in ipairs(ok and found or {}) do
        local bb = e.valid and e ~= v and e.type ~= 'character' and not PASS[e.type] and e.force == force and hits(e) and e.bounding_box
        if bb and skip and skip(e, bb, along) then bb = nil end
        if bb then
          local d = seg_box(a.x, a.y, b.x, b.y, bb.left_top.x, bb.left_top.y, bb.right_bottom.x, bb.right_bottom.y)
          if d < clear then
            local key = e.unit_number or (e.position.x * 1048576 + e.position.y)
            local rec = best[key]
            if not rec then rec = {entity=e, d=d}; best[key] = rec; out[#out + 1] = rec elseif d < rec.d then rec.d = d end
          end
        end
      end
    end
    table.sort(out, function(x, y) return x.d < y.d end)
    return out
  end
  -- "pumpjack (-261.5,-398.5) 0.3 tiles, pipe (-262.5,-394.5) 1.1 tiles" (the first n).
  function M.touch_line(list, n)
    local parts = {}
    for i, t in ipairs(list) do
      if i > (n or 4) then parts[#parts + 1] = string.format('+%d more', #list - (n or 4)); break end
      parts[#parts + 1] = string.format('%s %.1f tiles', at(t.entity), t.d)
    end
    return table.concat(parts, ', ')
  end
  local function points_of(path, from)
    local pts = {from}
    for _, w in ipairs(path) do
      local q, last = w.position, pts[#pts]
      if math.abs(q.x - last.x) > 0.05 or math.abs(q.y - last.y) > 0.05 then pts[#pts + 1] = q end
    end
    return pts
  end
  -- A found path, unless it is a narrow one passing our entities (the next plan is asked for), the enemy check holds
  -- it, or it goes around a nest (avoid.lua).
  function M.use(p, nav, path)
    local v = nav.vehicle_entity and nav.vehicle_entity.valid and nav.vehicle_entity or (p.character and p.character.vehicle)
    local plans = v and v.valid and M.plans(v) or {}
    local plan = plans[math.min(#plans, (nav.path_level or 0) + 1)] or {}
    if nav.lead and v and v.valid then
      local whole = {{position={x=v.position.x, y=v.position.y}}}
      for _, w in ipairs(path) do whole[#whole + 1] = w end
      path = whole
    end
    if plan.narrow and v and v.valid then
      local long, short = halves(v)
      local clear = (long * long + short * short) ^ 0.5 + MARGIN
      -- What the vehicle already stands beside does not count while it drives off (its first clear + length tiles).
      local px, py = v.position.x, v.position.y
      local function beside(e, bb, along)
        return along < clear + long and pt_box(px, py, bb.left_top.x, bb.left_top.y, bb.right_bottom.x, bb.right_bottom.y) < clear + 0.01
      end
      local touches = M.path_touches(v, v.surface, p.force, points_of(path, v.position), clear, beside)
      if #touches > 0 then
        nav.narrow_touches = nav.narrow_touches or {}
        nav.narrow_touches[#nav.narrow_touches + 1] = {what=plan.what, list=touches}
        return M.next_plan(p, nav)
      end
    end
    if api.accept and not api.accept(v and v.valid and M.at_vehicle(p, v) or p, nav, path) then return end
    nav.waypoints = path; nav.waypoint = 1; nav.path_state = 'found'
    local n = 0
    for i = 2, #path do n = n + api.distance(path[i-1].position, path[i].position) end
    nav.path_length = math.floor(n + 0.5)
    nav.finish = path[#path].position
    nav.plan = plan.what
    nav.short_of = plan.near and api.distance(nav.finish, nav.position) or nil
    -- (d24 batch158, harness review bug 5: a drive from (714.5,698.5) to (734.5,698.5) on cleared ground ended arrived at
    -- x 729.2) the engine's path ends anywhere within its goal radius (tolerance + 1 + the plan's): a path to the target
    -- that ends farther than the tolerance from it goes on straight to the target (nav.extended: how far); the braking
    -- for ours and the stuck rules hold on that stretch as on the path
    local tol = nav.tolerance or 3
    local gap = not plan.near and api.distance(nav.finish, nav.position) or 0
    if gap > tol then
      path[#path + 1] = {position={x=nav.position.x, y=nav.position.y}}
      nav.finish = path[#path].position
      nav.extended = math.floor(gap * 10 + 0.5) / 10
      nav.path_length = nav.path_length + math.floor(gap + 0.5)
    end
  end
  -- The next plan, or unreachable: no path, or every narrow one passes our entities.
  function M.next_plan(p, nav)
    local v = nav.vehicle_entity or (p.character and p.character.vehicle)
    local count = v and v.valid and #M.plans(v) or 1
    if (nav.path_level or 0) < count - 1 then nav.path_level = (nav.path_level or 0) + 1; return M.request(p, nav) end
    local long, short = 0, 0
    if v and v.valid then long, short = halves(v) end
    nav.path_state = 'unreachable'
    local name = v and v.valid and v.name or 'vehicle'
    if nav.narrow_touches then
      local t = nav.narrow_touches[#nav.narrow_touches]
      nav.why = string.format('no path keeps the %s\'s turning room (%.1f tiles) to (%g,%g) or open ground within 13 tiles of it; the path for %s passes our %s',
        name, ((long * long + short * short) ^ 0.5) * 2, nav.position.x, nav.position.y, t.what, M.touch_line(t.list, 3))
    else
      nav.why = string.format('no path for the %s (%.1f by %.1f tiles) to (%g,%g)', name, short * 2, long * 2, nav.position.x, nav.position.y)
    end
  end
  -- A path result for a drive: the next plan when none, then unreachable.
  function M.on_path(p, action, event)
    local nav = action.nav
    if not nav or event.id ~= nav.path_id then return end
    if event.path then return M.use(p, nav, event.path) end
    if event.try_again_later then nav.path_state = 'busy'; return end
    return M.next_plan(p, nav)
  end
  -- The heading of a from-to step as an orientation (0 north, 0.25 east).
  local function heading(a, b)
    local o = (math.atan2 or math.atan)(b.x - a.x, -(b.y - a.y)) / (2 * math.pi)
    return o < 0 and o + 1 or o
  end
  local function turn_of(h1, h2) return math.abs((h2 - h1 + 0.5) % 1 - 0.5) end
  -- The sharpest turn of the path within `ahead` tiles past the vehicle's place on it (nav.waypoint, nav.along):
  -- the turn (orientation units, 0..0.5) and how far along the path it comes.
  function M.turn_ahead(nav, from, ahead)
    local wps = nav.waypoints
    local i = nav.waypoint or 1
    if not (wps and wps[i + 1]) then return 0, nil end
    local h0 = heading(wps[i].position, wps[i + 1].position)
    local dist, prev, best, at_d = 0, from, 0, nil
    for j = i + 1, #wps - 1 do
      local a, b = wps[j].position, wps[j + 1].position
      dist = dist + api.distance(prev, a)
      prev = a
      if dist > ahead then break end
      local t = turn_of(h0, heading(a, b))
      if t > best + 0.01 then best, at_d = t, dist end
    end
    return best, at_d
  end
  -- The point to steer at: where the vehicle is along the path (the nearest
  -- point of the next few segments), then lookahead tiles further along it,
  -- never past the path's end; around a turn of more than 15 degrees no
  -- further than 2 tiles past it, so the line to it cuts no corner into what
  -- the path went round.
  local function aim(v, nav, lookahead)
    local wps, pos = nav.waypoints, v.position
    local best, bi, bt = nil, nav.waypoint, 0
    for i = nav.waypoint, math.min(#wps - 1, nav.waypoint + 12) do
      local a, b = wps[i].position, wps[i + 1].position
      local dx, dy = b.x - a.x, b.y - a.y
      local L = dx * dx + dy * dy
      local t = L > 0 and math.max(0, math.min(1, ((pos.x - a.x) * dx + (pos.y - a.y) * dy) / L)) or 0
      local d = (a.x + t * dx - pos.x) ^ 2 + (a.y + t * dy - pos.y) ^ 2
      if not best or d < best then best, bi, bt = d, i, t end
    end
    nav.waypoint = bi
    local a, b = wps[bi].position, (wps[bi + 1] or wps[bi]).position
    local cur = {x=a.x + (b.x - a.x) * bt, y=a.y + (b.y - a.y) * bt}
    local turn, at_d = M.turn_ahead(nav, cur, lookahead)
    if turn > 0.04 and at_d then lookahead = math.min(lookahead, at_d + 2) end
    local left = lookahead
    for i = bi + 1, #wps do
      local q = wps[i].position
      local seg = api.distance(cur, q)
      if seg >= left then local t = left / seg; return {x=cur.x + (q.x - cur.x) * t, y=cur.y + (q.y - cur.y) * t}, cur end
      left = left - seg; cur = q
    end
    return wps[#wps].position, cur
  end
  -- What stands right in front of the vehicle (a cliff, trees, water, a building).
  function M.in_front(v, surface, back)
    local o = (v.orientation or 0) * 2 * math.pi
    local long = halves(v)
    local s = back and -1 or 1
    local x, y = v.position.x + math.sin(o) * (long + 1) * s, v.position.y - math.cos(o) * (long + 1) * s
    local names, have = {}, {}
    local okf, found = pcall(function() return surface.find_entities_filtered{area={{x - 1.5, y - 1.5}, {x + 1.5, y + 1.5}}, limit=12} end)
    for _, e in ipairs(okf and found or {}) do
      if e.valid and e ~= v and e.type ~= 'character' and not have[e.name] and #names < 3 then
        local ok, colliding = pcall(function() return e.prototype.collision_mask.layers.player or e.prototype.collision_mask.layers.object end)
        if ok and colliding then have[e.name] = true; names[#names+1] = string.format('%s (%g,%g)', e.name, math.floor(e.position.x * 2 + 0.5) / 2, math.floor(e.position.y * 2 + 0.5) / 2) end
      end
    end
    local ok, n = pcall(function() return surface.count_tiles_filtered{area={{x - 1.5, y - 1.5}, {x + 1.5, y + 1.5}}, collision_mask='player'} end)
    if ok and n > 0 then names[#names+1] = n .. ' water or other tiles' end
    if #names > 0 then return table.concat(names, ', ') end
    -- Nothing there: what it touches all round (a corner caught turning).
    local units, solid, tiles = M.contact(v, surface, back, true)
    for _, e in ipairs(solid) do
      if #names < 3 and not have[e.name] then have[e.name] = true; names[#names+1] = string.format('%s (%g,%g)', e.name, math.floor(e.position.x * 2 + 0.5) / 2, math.floor(e.position.y * 2 + 0.5) / 2) end
    end
    if tiles > 0 then names[#names+1] = tiles .. ' water or other tiles' end
    if #names > 0 then return 'nothing; beside it: ' .. table.concat(names, ', ') end
    return #units > 0 and (#units .. ' units') or 'nothing that collides'
  end
  -- Units are no block (Astra, shift10 04:10: a drive into an attack group
  -- ended blocked and left the tank surrounded, unable to back out): what the
  -- vehicle presses against ahead (behind when reversing), as units, as what
  -- stops it (an entity whose collision layers meet the vehicle's: buildings,
  -- cliffs, rocks, trees), and the tiles it cannot cross (water).
  local UNITS = {unit=true, ['spider-unit']=true, ['segmented-unit']=true}
  -- around: all round it (turning on the spot), else the end it drives toward.
  function M.contact(v, surface, back, around)
    local o = (v.orientation or 0) * 2 * math.pi
    local long, short = halves(v)
    local s = back and -1 or 1
    local x, y = v.position.x + math.sin(o) * (long + 0.7) * s, v.position.y - math.cos(o) * (long + 0.7) * s
    local r = short + 0.7
    if around then x, y, r = v.position.x, v.position.y, long + 0.7 end
    local area = {{x - r, y - r}, {x + r, y + r}}
    local mine = {}
    pcall(function() for layer in pairs(v.prototype.collision_mask.layers) do mine[layer] = true end end)
    local units, solid = {}, {}
    local ok, found = pcall(function() return surface.find_entities_filtered{area=area, limit=48} end)
    for _, e in ipairs(ok and found or {}) do
      if e.valid and e ~= v and e.type ~= 'character' then
        if UNITS[e.type] then units[#units+1] = e
        else
          local okm, hit = pcall(function()
            for layer in pairs(e.prototype.collision_mask.layers) do if mine[layer] then return true end end
            return false
          end)
          if okm and hit then solid[#solid+1] = e end
        end
      end
    end
    local layers = {}
    for layer in pairs(mine) do layers[#layers+1] = layer end
    local okt, n = pcall(function() return surface.count_tiles_filtered{area=area, collision_mask=layers} end)
    return units, solid, okt and n or 0
  end
  -- A unit the drive pushed against or hit (its impact damage): counted once.
  function M.rammed(action, e)
    if not (e and e.valid and UNITS[e.type]) then return end
    local k = e.unit_number
    action.rammed = action.rammed or {}
    if k and not action.rammed[k] then action.rammed[k] = true; action.rammed_n = (action.rammed_n or 0) + 1 end
  end
  -- Braking, tiles per tick per tick, read on a private copy (2.0.77): a tank 0.0016 (17 tiles from 0.236 a tick),
  -- a car 0.0055 (18 tiles from 0.45); anything else as a tank.
  local function decel(v) return v.name == 'car' and 0.0055 or 0.0016 end
  M.decel = decel
  -- The nearest of our entities in the vehicle's way over its next `reach` tiles (ahead, or behind with back), and
  -- the gap from its end to that entity's box. Our characters count (not the vehicle's own seats); ghosts, remnants
  -- and what the vehicle passes over (belts) do not.
  function M.ours_ahead(v, force, back, reach)
    local o = (v.orientation or 0) * 2 * math.pi
    local s = back and -1 or 1
    local fx, fy = math.sin(o) * s, -math.cos(o) * s
    local rx, ry = -fy, fx
    local long, short = halves(v)
    local w, far = short + 0.3, long + reach
    local px, py = v.position.x, v.position.y
    local ex, ey = px + fx * far, py + fy * far
    local area = {{math.min(px, ex) - w - 0.5, math.min(py, ey) - w - 0.5}, {math.max(px, ex) + w + 0.5, math.max(py, ey) + w + 0.5}}
    local ok, found = pcall(function() return v.surface.find_entities_filtered{area=area, force=force} end)
    local hits = collider(v)
    local best, gap
    for _, e in ipairs(ok and found or {}) do
      local t = e.valid and e ~= v and e.type
      local mine = t and not PASS[t] and e.force == force and (t == 'character' and (pcall(function() return e.vehicle ~= v end) and e.vehicle ~= v) or t ~= 'character' and hits(e))
      local bb = mine and e.bounding_box
      if bb then
        local amin, amax, bmin, bmax = math.huge, -math.huge, math.huge, -math.huge
        for _, cx in ipairs{bb.left_top.x, bb.right_bottom.x} do
          for _, cy in ipairs{bb.left_top.y, bb.right_bottom.y} do
            local dx, dy = cx - px, cy - py
            local a, b = dx * fx + dy * fy, dx * rx + dy * ry
            if a < amin then amin = a end
            if a > amax then amax = a end
            if b < bmin then bmin = b end
            if b > bmax then bmax = b end
          end
        end
        if amax > long - 0.3 and amin < far and bmin < w and bmax > -w then
          local g = math.max(0, amin - long)
          if not gap or g < gap then best, gap = e, g end
        end
      end
    end
    return best, gap
  end
  -- One of ours within the circle the vehicle's corners sweep turning on the spot (plus 0.2).
  function M.ours_around(v, force)
    local long, short = halves(v)
    local r = (long * long + short * short) ^ 0.5 + 0.2
    local px, py = v.position.x, v.position.y
    local ok, found = pcall(function() return v.surface.find_entities_filtered{area={{px - r - 1, py - r - 1}, {px + r + 1, py + r + 1}}, force=force} end)
    local hits = collider(v)
    for _, e in ipairs(ok and found or {}) do
      local bb = e.valid and e ~= v and not PASS[e.type] and e.type ~= 'character' and e.force == force and hits(e) and e.bounding_box
      if bb and pt_box(px, py, bb.left_top.x, bb.left_top.y, bb.right_bottom.x, bb.right_bottom.y) < r then return e end
    end
  end
  -- One of ours the drive braked or held for, once each: last.spared.
  local function spare(action, e)
    local key = e.unit_number or (e.position.x * 1048576 + e.position.y)
    action.spared = action.spared or {}
    if action.spared[key] then return end
    action.spared[key] = true
    action.spared_list = action.spared_list or {}
    if #action.spared_list < 6 then action.spared_list[#action.spared_list + 1] = at(e) end
  end
  -- dry_run: the path the drive would take (its corners), the plan, where it ends, and our entities near it, with
  -- those within the vehicle's half-diagonal of the path's centre line (what it would touch turning there).
  function M.preview(p, action, v)
    local nav = action.nav
    local pts = nav and nav.waypoints and points_of(nav.waypoints, v.position) or {v.position, action.target}
    local corners = {pts[1]}
    for i = 2, #pts - 1 do
      if turn_of(heading(pts[i - 1], pts[i]), heading(pts[i], pts[i + 1])) > 0.02 then corners[#corners + 1] = pts[i] end
    end
    corners[#corners + 1] = pts[#pts]
    local parts = {}
    for i, q in ipairs(corners) do
      if i > 14 then parts[#parts + 1] = string.format('+%d more', #corners - 14); break end
      parts[#parts + 1] = string.format('(%g,%g)', math.floor(q.x * 10 + 0.5) / 10, math.floor(q.y * 10 + 0.5) / 10)
    end
    local long, short = halves(v)
    local diag = (long * long + short * short) ^ 0.5
    local near = M.path_touches(v, v.surface, p.force, pts, diag + MARGIN + 1)
    local touches = {}
    for _, t in ipairs(near) do if t.d < diag then touches[#touches + 1] = t end end
    local length = nav and nav.path_length
    if not length then length = math.floor(api.distance(v.position, action.target) + 0.5) end
    action.preview = {path=table.concat(parts, ' '), path_length=length, plan=nav and nav.plan or 'straight at the target (pathfind false)',
      ends=pts[#pts], touches=#touches > 0 and M.touch_line(touches, 6) or 'none',
      nearest_ours=near[1] and string.format('%s, %.1f tiles from the path\'s centre line (the %s reaches %.1f to each side, %.1f turning)',
        at(near[1].entity), near[1].d, v.name, short, diag) or nil,
      short_of=nav and nav.short_of and string.format('ends %.1f tiles from (%g,%g): the %s\'s turning room fits no closer',
        nav.short_of, nav.position.x, nav.position.y, v.name) or nil}
  end
  function M.tick(p, action)
    local c = p.character
    local v
    if action.remote then v = action.vehicle else v = c and c.valid and c.vehicle end
    if not (v and v.valid) then
      if action.remote then action.why = 'the vehicle is gone' end
      return action.remote and 'vehicle_gone' or 'interrupted'
    end
    local R = defines.riding
    -- A remote drive needs the vehicle in view and its driver seat free (vehicles.lua remote_vehicle).
    if action.remote then
      local okd, driver = pcall(v.get_driver)
      if okd and driver then
        v.riding_state = {acceleration=R.acceleration.braking, direction=R.direction.straight}
        action.why = string.format('%s got into its driver seat at (%.1f,%.1f)', who(driver), v.position.x, v.position.y)
        return 'driver_seated'
      end
      if game.tick % 30 == 0 and not in_view(p, v) then
        v.riding_state = {acceleration=R.acceleration.braking, direction=R.direction.straight}
        action.why = string.format('%s left the chunks our force sees at (%.1f,%.1f): remote driving needs it in view', v.name, v.position.x, v.position.y)
        return 'out_of_coverage'
      end
    end
    local view_p = action.remote and M.at_vehicle(p, v) or p
    local back = action.reverse
    -- The pedal: forward, or reverse when backing there; backing off an obstacle uses the other one.
    local GAS = back and R.acceleration.reversing or R.acceleration.accelerating
    local OFF = back and R.acceleration.accelerating or R.acceleration.reversing
    -- The car's own riding state: what the driver's keys set, and the one a
    -- script character (a bot, no player) can drive by (live check 00:40).
    local function ride(acc, dir) v.riding_state = {acceleration=acc, direction=dir} end
    local nav = action.nav
    if nav then
      if nav.foes then api.avoid_tick(view_p, nav) end
      local st = nav.path_state
      if st == 'busy' then
        nav.retry_tick = nav.retry_tick or game.tick + 20
        if game.tick >= nav.retry_tick then nav.retry_tick = nil; M.request(p, nav) end
        st = 'pending'
      end
      if st == 'pending' or st == 'scanning' then
        ride(math.abs(v.speed or 0) > 0.01 and R.acceleration.braking or R.acceleration.nothing, R.direction.straight)
        action.still, action.last = 0, v.position
        return nil
      end
      if st == 'unreachable' or st == 'failed' then action.why = nav.why; ride(R.acceleration.nothing, R.direction.straight); return 'unreachable' end
      if st == 'unsafe' then ride(R.acceleration.nothing, R.direction.straight); return 'no_safe_route' end
    end
    -- dry_run: it does not move; the path once found, and what lies near it.
    if action.dry then
      ride(math.abs(v.speed or 0) > 0.01 and R.acceleration.braking or R.acceleration.nothing, R.direction.straight)
      M.preview(p, action, v)
      return 'previewed'
    end
    local dec = decel(v)
    -- Backing up off whatever stopped it, then a fresh path from there.
    if action.backing then
      if game.tick < action.backing.until_tick then
        -- Not into ours behind it, nor swinging into ours beside it.
        local sp = math.abs(v.speed or 0)
        local ours = M.ours_ahead(v, p.force, not back, sp * sp / (2 * dec) + 1)
        if ours then
          spare(action, ours); action.held_by = ours; action.held_tick = game.tick
          action.backing.until_tick = game.tick
        else
          ride(OFF, M.ours_around(v, p.force) and R.direction.straight or action.backing.turn)
          return nil
        end
      end
      action.backing = nil
      ride(R.acceleration.braking, R.direction.straight)
      action.still, action.last = 0, v.position
      nav.path_level = 0
      M.request(p, nav)
      return nil
    end
    local goal = nav and nav.position or action.target
    local d = api.distance(v.position, goal)
    -- The path's end: where a stop-short plan ends, and where any path ends (never steered past it at the target).
    local finish = nav and nav.waypoints and nav.finish
    local df = finish and api.distance(v.position, finish) or d
    -- arrived: within the tolerance (3 tiles) of the goal, or at the end of a path to open ground near it (a stop-short
    -- plan: last.stopped_short); a path to the target goes to it (nav.extended)
    if d <= (nav and nav.tolerance or 3) or (nav and nav.short_of and finish and df <= 1.5) then
      -- A corner of the way around a nest: on to the next leg without stopping.
      if nav and nav.leg and api.leg(view_p, nav) then return nil end
      ride(R.acceleration.braking, R.direction.straight)
      if math.abs(v.speed or 0) < 0.01 then
        ride(R.acceleration.nothing, R.direction.straight)
        return 'arrived'
      end
      return nil
    end
    local speed = math.abs(v.speed or 0)
    local point, here = goal, nil
    if nav and nav.waypoints then point, here = aim(v, nav, math.max(4, math.min(10, speed * 30))) end
    -- Rear first when reversing: the rear is the heading (the wheel turns the vehicle the same way in either gear).
    local diff = angle_to(v.position, point) - ((v.orientation or 0) + (back and 0.5 or 0)) % 1
    if diff > 0.5 then diff = diff - 1 elseif diff < -0.5 then diff = diff + 1 end
    local turn = diff > 0.02 and R.direction.right or diff < -0.02 and R.direction.left or R.direction.straight
    -- Slow down for sharp turns and the last stretch; turn on the spot when facing away.
    local accel
    if nav then
      local sharp = math.abs(diff)
      if sharp > 0.2 then accel = speed > 0.03 and R.acceleration.braking or R.acceleration.nothing
      elseif sharp > 0.08 then accel = speed > 0.12 and R.acceleration.braking or (speed < 0.05 and GAS or R.acceleration.nothing)
      else accel = (d > 12 or speed < 0.08) and GAS or R.acceleration.nothing end
    else
      local fast = math.abs(diff) < 0.15 and d > 12
      accel = (fast or speed < 0.08) and GAS or R.acceleration.nothing
    end
    -- Speed it can still stop from (dec): before the path's end, before a turn of more than 36 degrees (at 0.05 a
    -- tick, 0.02 past 90), and 0.5 tiles before one of ours in its way (Astra 12:06: a tank at 0.15 a tick needs 7
    -- tiles to stop; it took a V-turn at speed and ran into a pumpjack).
    local stop_d = speed * speed / (2 * dec)
    local limit
    if nav and nav.waypoints then
      limit = (2 * dec * math.max(0, df - 1)) ^ 0.5 + 0.02
      local amount, at_d = M.turn_ahead(nav, here or v.position, stop_d + 4)
      if amount > 0.1 and at_d then
        local vt = amount > 0.25 and 0.02 or 0.05
        limit = math.min(limit, (vt * vt + 2 * dec * math.max(0, at_d - 0.5)) ^ 0.5)
      end
    end
    local held = false
    local sv = v.speed or 0
    if speed > 0.005 or accel == GAS then
      local going_back = sv < -0.001 or (sv <= 0.001 and back)
      local ours, gap = M.ours_ahead(v, p.force, going_back, stop_d + 1.5)
      if ours then
        local lim = (2 * dec * math.max(0, gap - 0.5)) ^ 0.5
        if not limit or lim < limit then limit = lim end
        if gap < 0.6 or speed > lim then spare(action, ours); action.held_by = ours; action.held_tick = game.tick; held = gap < 1 end
      end
    end
    if limit then
      if speed > limit + 0.005 then accel = R.acceleration.braking
      elseif accel == GAS and limit < 0.015 then accel = R.acceleration.nothing end
    end
    -- Turning at a crawl or on the spot with ours within its corners' sweep: the wheel stays straight.
    if speed < 0.05 and turn ~= R.direction.straight then
      local ours = M.ours_around(v, p.force)
      if ours then turn = R.direction.straight; spare(action, ours); action.held_by = ours; action.held_tick = game.tick end
    end
    -- Pressing against units: the throttle stays down (ram through), never into ours.
    if action.ramming and game.tick - action.ramming < 30 and not held then accel = GAS end
    ride(accel, turn)
    local o = v.orientation or 0
    local turned = nav and math.abs((o - (action.last_o or o) + 0.5) % 1 - 0.5) > 0.003
    if api.distance(v.position, action.last) >= 0.05 or turned then
      action.still, action.last, action.last_o = 0, v.position, o
      return nil
    end
    action.still = action.still + 1
    -- Still: what it presses against, every 10 ticks. Units alone: push on.
    if action.still % 10 == 0 then
      local units, solid, tiles = M.contact(v, v.surface, back, math.abs(diff) > 0.2)
      if #units > 0 and #solid == 0 and tiles == 0 then
        action.ramming = game.tick; action.still = 0
        for _, u in ipairs(units) do M.rammed(action, u) end
        return nil
      end
    end
    if not nav then
      -- Steering straight at the target: no progress for 3 s is blocked (a tree, a building, water).
      if action.still >= 180 then
        ride(R.acceleration.nothing, R.direction.straight)
        local h = action.held_by
        if h and h.valid and game.tick - (action.held_tick or 0) <= 100 then
          action.why = string.format('stopped at (%.1f,%.1f) to spare our %s (a drive pushes only through enemy units)', v.position.x, v.position.y, at(h))
        end
        return 'blocked'
      end
      return nil
    end
    -- On a path: neither moving nor turning for 1.5 s, it backs up 1 s with the
    -- wheel turned toward the path and asks again; the second time it is blocked.
    if action.still < 90 then return nil end
    action.still = 0
    local side = back and 'behind' or 'in front'
    if not action.backed then
      action.backed = {at={x=v.position.x, y=v.position.y}, front=M.in_front(v, v.surface, back), side=side}
      action.backing = {until_tick=game.tick + 60, turn=diff > 0 and R.direction.right or R.direction.left}
      return nil
    end
    ride(R.acceleration.nothing, R.direction.straight)
    local h = action.held_by
    if h and h.valid and game.tick - (action.held_tick or 0) <= 100 then
      action.why = string.format('stopped at (%.1f,%.1f) to spare our %s (a drive pushes only through enemy units), again after backing off once from (%.1f,%.1f)',
        v.position.x, v.position.y, at(h), action.backed.at.x, action.backed.at.y)
      return 'blocked'
    end
    action.why = string.format('stuck at (%.1f,%.1f) again after backing off once from (%.1f,%.1f); %s: %s', v.position.x, v.position.y,
      action.backed.at.x, action.backed.at.y, side, M.in_front(v, v.surface, back))
    return 'blocked'
  end
  -- Vehicle guns (2.0): a car, tank or spidertron fires its selected gun
  -- (selected_gun_index) from its ammo inventory when its gunner shoots, and
  -- the turret turns toward the entity the gunner selects, as a player's
  -- cursor does (private 2.0.77 world: a seated bot's shooting_state alone
  -- fired only straight ahead; with the target selected the turret turned
  -- and the machine gun hit; shooting_enemies aims by itself). Opus and Astra
  -- (shift09 00:00): shoot refused in a tank, and a tank was lost at a nest.
  local AMMO_INV = {car='car_ammo', ['spider-vehicle']='spider_ammo'}
  -- Rounds left in a gun slot: whole magazines and the one in use.
  function M.rounds(v, slot)
    local ok, n = pcall(function()
      local inv = v.get_inventory(defines.inventory[AMMO_INV[v.type]])
      local stack = inv and inv[slot]
      if not (stack and stack.valid_for_read) then return 0 end
      local mag = prototypes.item[stack.name].magazine_size or 1
      return (stack.count - 1) * mag + (stack.ammo or mag)
    end)
    return ok and n or 0
  end
  local function category(name)
    local ok, c = pcall(function() return prototypes.item[name].ammo_category end)
    if not ok or not c then return nil end
    return type(c) == 'string' and c or c.name
  end
  M.category = category
  -- The guns of a vehicle with what each slot holds.
  function M.guns(v)
    local ok, list = pcall(function() return v.prototype.indexed_guns end)
    local okv, inv = pcall(function() return AMMO_INV[v.type] and v.get_inventory(defines.inventory[AMMO_INV[v.type]]) or nil end)
    inv = okv and inv or nil
    local out = {}
    for i, g in ipairs(ok and list or {}) do
      local ap = g.attack_parameters or {}
      local stack = inv and inv[i]
      local has = stack and stack.valid_for_read
      out[i] = {slot=i, gun=g.name, categories=ap.ammo_categories or {}, range=ap.range, ammo=has and stack.name or nil, count=has and stack.count or 0}
    end
    return out, inv
  end
  local function gun_lines(guns, selected)
    local out = {}
    for i, g in ipairs(guns) do
      out[i] = string.format('%d %s: %s (range %s)%s', i, g.gun, g.ammo and (g.count .. ' ' .. g.ammo) or 'no ammo', tostring(g.range), i == selected and ' selected' or '')
    end
    return out
  end
  M.gun_lines = gun_lines
  -- Whether the character works the guns: the driver unless driver_is_gunner
  -- is off and a passenger sits in; the passenger when it is off (vehicle GUI).
  function M.gunner(c, v)
    local _, seat = seat_of(c)
    local dg = pcall(function() return v.driver_is_gunner end) and v.driver_is_gunner
    local okp, passenger = pcall(v.get_passenger)
    if seat == 'driver' then return dg ~= false or not (okp and passenger), seat end
    return dg == false, seat
  end
  -- The slot to fire: gun_slot, a gun name, or an ammo name (the slot holding
  -- it, else the slot whose gun takes its category).
  function M.pick(guns, a)
    if a.gun_slot ~= nil then
      local n = api.integer(a.gun_slot, nil, 1, math.max(1, #guns), 'gun_slot (1..' .. #guns .. ' for this vehicle)')
      return n
    end
    if a.gun ~= nil then
      for i, g in ipairs(guns) do if g.gun == a.gun then return i end end
      local names = {}
      for i, g in ipairs(guns) do names[i] = g.gun end
      error('no gun ' .. tostring(a.gun) .. ' on this vehicle (guns: ' .. table.concat(names, ', ') .. ')', 0)
    end
    if a.ammo ~= nil then
      assert(type(a.ammo) == 'string' and prototypes.item[a.ammo], 'ammo must be an ammo item name (cannon-shell, firearm-magazine, flamethrower-ammo, rocket, ...)')
      for i, g in ipairs(guns) do if g.ammo == a.ammo then return i end end
      local cat = category(a.ammo)
      for i, g in ipairs(guns) do for _, c in ipairs(g.categories) do if c == cat then return i end end end
      error(a.ammo .. ' (' .. tostring(cat) .. ') fits none of this vehicle\'s guns', 0)
    end
    return nil
  end
  -- An empty slot (or one holding other ammo than asked for) is loaded from
  -- the character's inventory, as the vehicle GUI lets the one sitting in it.
  function M.load(p, inv, slot, gun, want)
    local stack = inv and inv[slot]
    if not stack or not gun then return nil end
    if stack.valid_for_read and (not want or stack.name == want) then return nil end
    local main = p.get_main_inventory()
    if not main then return nil end
    local cats = {}
    for _, c in ipairs(gun.categories) do cats[c] = true end
    -- From the main inventory, else the character's own ammo slots.
    local best
    local sources = {main, p.get_inventory(defines.inventory.character_ammo)}
    for i, inv in ipairs(sources) do
      for k, v in pairs(inv and inv.get_contents() or {}) do
        local name, n = type(v) == 'table' and v.name or k, type(v) == 'table' and v.count or v
        local proto = prototypes.item[name]
        if proto and proto.type == 'ammo' and cats[category(name)] and (not want or name == want) and (not best or (i == best.i and n > best.n)) then best = {name=name, n=n, i=i, inv=inv} end
      end
      if best then break end
    end
    if not best then return nil end
    local out = {}
    if stack.valid_for_read then
      local old, count = stack.name, stack.count
      local moved = main.insert{name=old, count=count, quality=stack.quality and stack.quality.name or nil}
      assert(moved == count, 'no room in your inventory for the ' .. old .. ' in gun slot ' .. slot)
      stack.clear()
      out[#out+1] = count .. ' ' .. old .. ' back to your inventory'
    end
    local src = best.inv.find_item_stack(best.name)
    local n = src and src.count or 0
    assert(src and stack.transfer_stack(src), 'the vehicle\'s ammo slot ' .. slot .. ' refused ' .. best.name)
    out[#out+1] = string.format('%d %s from your %s to gun slot %d', n - (src.valid_for_read and src.count or 0), best.name, best.i == 1 and 'inventory' or 'ammo slots', slot)
    return 'loaded ' .. table.concat(out, '; ')
  end
  -- What it aims at for position=: the entity there the gunner can select
  -- (not our own), enemies first, then nearest.
  function M.target_at(p, pos)
    local best, bd, be
    for _, e in ipairs(p.surface.find_entities_filtered{position=pos, radius=2.5, limit=64}) do
      local ok, health = pcall(function() return e.health end)
      if e.valid and ok and health and e.force ~= p.force and e.type ~= 'character' then
        local enemy = e.force.name ~= 'neutral' and not p.force.get_friend(e.force) and not p.force.get_cease_fire(e.force)
        local d = api.distance(e.position, pos)
        if not best or (enemy and not be) or (enemy == be and d < bd) then best, bd, be = e, d, enemy end
      end
    end
    return best
  end
  -- shoot while seated: the vehicle's gun; returns the combat record and the reply.
  function M.shoot(p, a, ticks)
    local c = p.character
    local v = c and c.valid and c.vehicle
    assert(v and v.valid, 'not in a vehicle')
    local guns, inv = M.guns(v)
    assert(#guns > 0 and inv, v.name .. ' has no guns')
    local gunner, seat = M.gunner(c, v)
    assert(gunner, string.format('the %s works the guns of %s (driver_is_gunner %s)', seat == 'driver' and 'passenger' or 'driver', v.name, tostring(v.driver_is_gunner)))
    -- Checks first: a refused shot changes neither the guns nor the inventory.
    local slot = M.pick(guns, a)
    if not slot then
      -- The selected gun, else the first one holding ammunition (as the game switches).
      slot = pcall(function() return v.selected_gun_index end) and v.selected_gun_index or 1
      if slot < 1 or slot > #guns then slot = 1 end
      if guns[slot].count == 0 then for i, g in ipairs(guns) do if g.count > 0 then slot = i; break end end end
    end
    local pos = a.position and api.position(a.position)
    local target
    if pos then
      api.assert_visible(p, pos, 'target')
      target = M.target_at(p, pos)
      assert(target, string.format('nothing at (%g,%g) to aim at: the turret aims at the entity the gunner selects (use auto=true for the nearest enemy)', pos.x, pos.y))
    end
    local equipped = M.load(p, inv, slot, guns[slot], a.ammo)
    guns = M.guns(v)
    local gun = guns[slot]
    assert(gun.count > 0, string.format('no ammunition for %s (gun slot %d: %s) in %s or in your inventory', gun.gun, slot, table.concat(gun.categories, '/'), v.name))
    pcall(function() v.selected_gun_index = slot end)
    local action = {until_tick=game.tick + ticks, vehicle=v.name, slot=slot, gun=gun.gun, want=a.ammo, auto=a.auto == true and not pos or nil,
      position=target and target.position or nil, target=target and target.name or nil,
      radius=api.integer(a.radius, math.min(32, math.floor(gun.range or 24)), 1, 36, 'radius'), ammo_start=gun.count, equipped=equipped}
    local out = {until_tick=action.until_tick, vehicle=v.name, seat=seat, gun=gun.gun, gun_slot=slot, range=gun.range, guns=gun_lines(guns, slot), equipped=equipped}
    if target then
      local d = api.distance(v.position, target.position)
      out.target = string.format('%s at (%g,%g), %.1f tiles from the %s', target.name, target.position.x, target.position.y, d, v.name)
      if gun.range and d > gun.range then out.out_of_range = string.format('%s reaches %s tiles; the target is %.1f away', gun.gun, tostring(gun.range), d) end
    end
    return action, out, target
  end
  -- One tick of vehicle fire: keep the slot, reload from the inventory, aim
  -- at the target (selected) or none; an outcome ends it.
  function M.combat_tick(p, action, target)
    local c = p.character
    local v = c and c.valid and c.vehicle
    if not (v and v.valid) then return 'left_vehicle' end
    if (pcall(function() return v.selected_gun_index end) and v.selected_gun_index) ~= action.slot then pcall(function() v.selected_gun_index = action.slot end) end
    local guns, inv = M.guns(v)
    local gun = guns[action.slot]
    if not gun then return 'left_vehicle' end
    if gun.count == 0 then
      local note = M.load(p, inv, action.slot, gun, action.want)
      if not note then return 'out_of_ammo' end
      action.reloads = (action.reloads or 0) + 1; action.equipped = note
      action.ammo_start = action.ammo_start + M.guns(v)[action.slot].count
      if action.rounds_start then action.rounds_start = action.rounds_start + M.rounds(v, action.slot) end
    end
    if target then
      pcall(function() p.selected = target end)
      p.shooting_state = {state=defines.shooting.shooting_selected, position=target.position}
    else
      p.shooting_state = {state=defines.shooting.not_shooting, position=p.position}
    end
  end
  -- At the end: ammunition used from the slot, and what the guns hold now.
  function M.combat_end(p, action)
    local c = p and p.valid and p.character
    local v = c and c.valid and c.vehicle
    pcall(function() p.selected = nil end)
    if not (v and v.valid) then return nil, nil end
    local guns = M.guns(v)
    local gun = guns[action.slot]
    return gun and math.max(0, action.ammo_start - gun.count) or nil, gun_lines(guns, action.slot)
  end
  -- A remote drive's vehicle, with nobody in it, brakes to a stop (on a copy of world n one let go coasted 11 tiles).
  function M.stop(p, v)
    local R = defines.riding
    pcall(function()
      local remote = v ~= nil
      v = v or p.character and p.character.vehicle
      if v and v.valid then v.riding_state = {acceleration=remote and R.acceleration.braking or R.acceleration.nothing, direction=R.direction.straight} end
    end)
  end
  return M
end
