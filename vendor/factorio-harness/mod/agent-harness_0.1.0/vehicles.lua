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
    vehicle = {position='{x,y} of a car, tank, spidertron, locomotive or wagon (enter within 10 tiles; go_to: a spidertron in sight)',
      enter='true: get in (driver seat if free, else a car or spidertron passenger seat); a train you ride runs its schedule as usual',
      exit='true: get out of the vehicle you are in',
      drive='{x,y}: drive the car or tank you are driving to there (a timed action: outcomes arrived | blocked | unreachable | no_safe_route | timed_out; ticks 1..36000, default 3600). It follows the engine\'s path for the vehicle\'s box (a square as wide as its diagonal plus a tile, then as its length, then as its width): around cliffs, water, trees and buildings, steering at a point a few tiles ahead on the path. Neither moving nor turning for 1.5 s against something solid: it backs off 1 s with the wheel turned and asks for a path again, once (last.backed_up); stuck again it ends blocked (last.why names what is in front)',
      pathfind='with drive: default true; false steers straight at the target',
      reverse='with drive: optional true: back there, rear first (to back out of a crowd or off an obstacle). Units in the way (biters, pentapods) are no block: it keeps the throttle and pushes through, as a player holding the key does; last.rammed counts the units it pressed against or hit. Buildings, cliffs, rocks and water stop it',
      avoid_enemies='with drive: as move_to (default: worms\' range + 4; true: worms and spawners + 8; a margin 0..32; false: no check)',
      go_to='{x,y}: a spidertron walks there by itself (the one at position, or the one you are in)',
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
  function M.handlers.vehicle(p, a)
    local c = p.character
    assert(c and c.valid, 'a living character is required')
    local n = (a.enter and 1 or 0) + (a.exit and 1 or 0) + (a.drive and 1 or 0) + (a.go_to and 1 or 0)
    assert(n <= 1, 'give one of enter, exit, drive, go_to')
    if a.enter then
      assert(a.enter == true, 'enter must be true')
      assert(not c.vehicle, 'already in a vehicle: vehicle {exit: true} first')
      local e = find_vehicle(p, a)
      local d = api.distance(c.position, e.position)
      assert(d <= ENTER_REACH, string.format('%s is %.1f tiles away; get within %d tiles to get in', e.name, d, ENTER_REACH))
      local ok, driver = pcall(e.get_driver)
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
    if a.go_to then
      local pos = api.position(a.go_to)
      local spider
      if a.position then spider = find_vehicle(p, a) else spider = c.vehicle end
      assert(spider and spider.valid and spider.type == 'spider-vehicle', 'go_to is for a spidertron (give its position, or ride it)')
      local ok, err = pcall(function() spider.add_autopilot_destination(pos) end)
      if not ok then ok, err = pcall(function() spider.autopilot_destination = pos end) end
      assert(ok, 'the game refused the destination: ' .. tostring(err))
      local out = {spidertron=spider.name, position=spider.position, go_to=pos}
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
      local v, seat = seat_of(c)
      assert(v and v.type == 'car', 'drive is for a car or tank you are in (vehicle {position, enter: true} first)')
      assert(seat == 'driver', 'only the driver drives')
      local target = api.position(a.drive)
      local ticks = api.integer(a.ticks, 3600, 1, 36000, 'ticks')
      assert(a.pathfind == nil or type(a.pathfind) == 'boolean', 'pathfind must be true or false')
      assert(a.reverse == nil or type(a.reverse) == 'boolean', 'reverse must be true or false')
      local mode = api.avoid_mode(a.avoid_enemies)
      local action = {kind='drive', target=target, until_tick=game.tick + ticks, last=c.position, still=0, vehicle=v, reverse=a.reverse or nil}
      api.start(p, action)
      local out = {until_tick=action.until_tick, target=target, vehicle=v.name, distance=math.floor(api.distance(v.position, target)), pathfinding=a.pathfind ~= false,
        reverse=a.reverse or nil}
      if a.pathfind ~= false then
        local nav = {position=target, tolerance=3, vehicle=true}
        action.nav = nav
        local foes = api.avoid_start(p, nav, mode)
        out.avoid_enemies = foes and api.avoid_describe(foes.mode) or nil
        M.request(p, nav)
      end
      return out
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
  function M.box_halves(v)
    local long, short = halves(v)
    return {(long * long + short * short) ^ 0.5 + 0.5, long, short}
  end
  function M.request(p, nav)
    local v = p.character and p.character.vehicle
    if not (v and v.valid) then nav.path_state = 'failed'; return end
    local levels = M.box_halves(v)
    local h = levels[math.min(#levels, (nav.path_level or 0) + 1)]
    nav.path_id = p.surface.request_path{bounding_box={{-h, -h}, {h, h}}, collision_mask=v.prototype.collision_mask, start=v.position,
      goal=nav.position, force=p.force, radius=nav.tolerance + 1, entity_to_ignore=v, can_open_gates=false,
      pathfind_flags={prefer_straight_paths=true, no_break=false, cache=false}}
    api.paths()[nav.path_id] = p.index
    nav.path_state = 'pending'; nav.waypoints = nil; nav.waypoint = nil; nav.asked_tick = game.tick
  end
  -- A found path, unless the enemy check holds it or goes around a nest (avoid.lua).
  function M.use(p, nav, path)
    if api.accept and not api.accept(p, nav, path) then return end
    nav.waypoints = path; nav.waypoint = 1; nav.path_state = 'found'
    local n = 0
    for i = 2, #path do n = n + api.distance(path[i-1].position, path[i].position) end
    nav.path_length = math.floor(n + 0.5)
  end
  -- A path result for a drive: the narrower box next, then unreachable.
  function M.on_path(p, action, event)
    local nav = action.nav
    if not nav or event.id ~= nav.path_id then return end
    if event.path then return M.use(p, nav, event.path) end
    if event.try_again_later then nav.path_state = 'busy'; return end
    if (nav.path_level or 0) < 2 then nav.path_level = (nav.path_level or 0) + 1; return M.request(p, nav) end
    local v = p.character and p.character.vehicle
    local long, short = 0, 0
    if v and v.valid then long, short = halves(v) end
    nav.path_state = 'unreachable'
    nav.why = string.format('no path for the %s (%.1f by %.1f tiles) to (%g,%g)', v and v.valid and v.name or 'vehicle', short * 2, long * 2, nav.position.x, nav.position.y)
  end
  -- The point to steer at: where the vehicle is along the path (the nearest
  -- point of the next few segments), then lookahead tiles further along it.
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
    local cur, left = {x=a.x + (b.x - a.x) * bt, y=a.y + (b.y - a.y) * bt}, lookahead
    for i = bi + 1, #wps do
      local q = wps[i].position
      local seg = api.distance(cur, q)
      if seg >= left then local t = left / seg; return {x=cur.x + (q.x - cur.x) * t, y=cur.y + (q.y - cur.y) * t} end
      left = left - seg; cur = q
    end
    return nav.position
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
  function M.tick(p, action)
    local c = p.character
    local v = c and c.valid and c.vehicle
    if not (v and v.valid) then return 'interrupted' end
    local R = defines.riding
    local back = action.reverse
    -- The pedal: forward, or reverse when backing there; backing off an obstacle uses the other one.
    local GAS = back and R.acceleration.reversing or R.acceleration.accelerating
    local OFF = back and R.acceleration.accelerating or R.acceleration.reversing
    -- The car's own riding state: what the driver's keys set, and the one a
    -- script character (a bot, no player) can drive by (live check 00:40).
    local function ride(acc, dir) v.riding_state = {acceleration=acc, direction=dir} end
    local nav = action.nav
    if nav then
      if nav.foes then api.avoid_tick(p, nav) end
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
    -- Backing up off whatever stopped it, then a fresh path from there.
    if action.backing then
      if game.tick < action.backing.until_tick then ride(OFF, action.backing.turn); return nil end
      action.backing = nil
      ride(R.acceleration.braking, R.direction.straight)
      action.still, action.last = 0, v.position
      nav.path_level = 0
      M.request(p, nav)
      return nil
    end
    local goal = nav and nav.position or action.target
    local d = api.distance(v.position, goal)
    if d <= 3 then
      -- A corner of the way around a nest: on to the next leg without stopping.
      if nav and nav.leg and api.leg(p, nav) then return nil end
      ride(R.acceleration.braking, R.direction.straight)
      if math.abs(v.speed or 0) < 0.01 then
        ride(R.acceleration.nothing, R.direction.straight)
        return 'arrived'
      end
      return nil
    end
    local speed = math.abs(v.speed or 0)
    local point = goal
    if nav and nav.waypoints then point = aim(v, nav, math.max(4, math.min(10, speed * 30))) end
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
    -- Pressing against units: the throttle stays down (ram through).
    if action.ramming and game.tick - action.ramming < 30 then accel = GAS end
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
      local units, solid, tiles = M.contact(v, p.surface, back, math.abs(diff) > 0.2)
      if #units > 0 and #solid == 0 and tiles == 0 then
        action.ramming = game.tick; action.still = 0
        for _, u in ipairs(units) do M.rammed(action, u) end
        return nil
      end
    end
    if not nav then
      -- Steering straight at the target: no progress for 3 s is blocked (a tree, a building, water).
      if action.still >= 180 then ride(R.acceleration.nothing, R.direction.straight); return 'blocked' end
      return nil
    end
    -- On a path: neither moving nor turning for 1.5 s, it backs up 1 s with the
    -- wheel turned toward the path and asks again; the second time it is blocked.
    if action.still < 90 then return nil end
    action.still = 0
    local side = back and 'behind' or 'in front'
    if not action.backed then
      action.backed = {at={x=v.position.x, y=v.position.y}, front=M.in_front(v, p.surface, back), side=side}
      action.backing = {until_tick=game.tick + 60, turn=diff > 0 and R.direction.right or R.direction.left}
      return nil
    end
    ride(R.acceleration.nothing, R.direction.straight)
    action.why = string.format('stuck at (%.1f,%.1f) again after backing off once from (%.1f,%.1f); %s: %s', v.position.x, v.position.y,
      action.backed.at.x, action.backed.at.y, side, M.in_front(v, p.surface, back))
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
  function M.stop(p)
    local R = defines.riding
    pcall(function()
      local v = p.character and p.character.vehicle
      if v and v.valid then v.riding_state = {acceleration=R.acceleration.nothing, direction=R.direction.straight} end
    end)
  end
  return M
end
