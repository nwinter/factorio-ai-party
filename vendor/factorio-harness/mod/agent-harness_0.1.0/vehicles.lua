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
      drive='{x,y}: drive the car or tank you are driving to there (a timed action: outcomes arrived | blocked | timed_out; ticks 1..36000, default 3600)',
      go_to='{x,y}: a spidertron walks there by itself (the one at position, or the one you are in)',
      ticks='with drive', returns='vehicle (name, position, seat, speed) or vehicle=false when on foot'},
  }
  local function seat_of(c)
    local v = c.vehicle
    if not (v and v.valid) then return nil end
    local ok, d = pcall(v.get_driver)
    local driver = ok and d and (d == c or (d.character and d.character == c))
    return v, driver and 'driver' or 'passenger'
  end
  local function view(c)
    local v, seat = seat_of(c)
    if not v then return {vehicle=false} end
    return {vehicle={name=v.name, position=v.position, seat=seat, speed=v.speed and math.floor(v.speed * 216 + 0.5) or nil}}
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
      local e = api.entity(p, a); api.friendly(p, e)
      assert(SEATED[e.type], e.name .. ' is not a vehicle you can get into')
      local d = api.distance(c.position, e.position)
      assert(d <= ENTER_REACH, string.format('%s is %.1f tiles away; get within %d tiles to get in', e.name, d, ENTER_REACH))
      local ok, driver = pcall(e.get_driver)
      if not (ok and driver) then
        e.set_driver(c)
      elseif e.type == 'car' or e.type == 'spider-vehicle' then
        local ok2, passenger = pcall(e.get_passenger)
        assert(not (ok2 and passenger), e.name .. ' is full')
        e.set_passenger(c)
      else
        error(e.name .. ' is taken: its one seat has someone in it', 0)
      end
      assert(c.vehicle == e, 'the game did not seat the character in ' .. e.name)
      return view(c)
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
      if a.position then spider = api.entity(p, a); api.friendly(p, spider) else spider = c.vehicle end
      assert(spider and spider.valid and spider.type == 'spider-vehicle', 'go_to is for a spidertron (give its position, or ride it)')
      local ok, err = pcall(function() spider.autopilot_destination = pos end)
      if not ok then
        ok, err = pcall(function() spider.add_autopilot_destination(pos) end)
      end
      assert(ok, 'the game refused the destination: ' .. tostring(err))
      return {spidertron=spider.name, position=spider.position, go_to=pos}
    end
    if a.drive then
      local v, seat = seat_of(c)
      assert(v and v.type == 'car', 'drive is for a car or tank you are in (vehicle {position, enter: true} first)')
      assert(seat == 'driver', 'only the driver drives')
      local target = api.position(a.drive)
      local ticks = api.integer(a.ticks, 3600, 1, 36000, 'ticks')
      local action = {kind='drive', target=target, until_tick=game.tick + ticks, last=c.position, still=0}
      api.start(p, action)
      return {until_tick=action.until_tick, target=target, vehicle=v.name, distance=math.floor(api.distance(v.position, target))}
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
  function M.tick(p, action)
    local c = p.character
    local v = c and c.valid and c.vehicle
    if not (v and v.valid) then return 'interrupted' end
    local R = defines.riding
    local d = api.distance(v.position, action.target)
    if d <= 3 then
      p.riding_state = {acceleration=R.acceleration.braking, direction=R.direction.straight}
      if math.abs(v.speed or 0) < 0.01 then
        p.riding_state = {acceleration=R.acceleration.nothing, direction=R.direction.straight}
        return 'arrived'
      end
      return nil
    end
    local diff = angle_to(v.position, action.target) - (v.orientation or 0)
    if diff > 0.5 then diff = diff - 1 elseif diff < -0.5 then diff = diff + 1 end
    local turn = diff > 0.02 and R.direction.right or diff < -0.02 and R.direction.left or R.direction.straight
    -- Slow down for sharp turns and the last stretch.
    local fast = math.abs(diff) < 0.15 and d > 12
    local accel = (fast or math.abs(v.speed or 0) < 0.08) and R.acceleration.accelerating or R.acceleration.nothing
    p.riding_state = {acceleration=accel, direction=turn}
    -- No progress for 3 s: blocked (a tree, a building, water).
    if api.distance(v.position, action.last) < 0.05 then
      action.still = action.still + 1
      if action.still >= 180 then
        p.riding_state = {acceleration=R.acceleration.nothing, direction=R.direction.straight}
        return 'blocked'
      end
    else action.still, action.last = 0, v.position end
    return nil
  end
  function M.stop(p)
    local R = defines.riding
    pcall(function() p.riding_state = {acceleration=R.acceleration.nothing, direction=R.direction.straight} end)
  end
  return M
end
