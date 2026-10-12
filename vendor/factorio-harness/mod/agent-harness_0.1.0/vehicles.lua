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
    -- The car's own riding state: what the driver's keys set, and the one a
    -- script character (a bot, no player) can drive by (live check 00:40).
    local function ride(acc, dir) v.riding_state = {acceleration=acc, direction=dir} end
    local d = api.distance(v.position, action.target)
    if d <= 3 then
      ride(R.acceleration.braking, R.direction.straight)
      if math.abs(v.speed or 0) < 0.01 then
        ride(R.acceleration.nothing, R.direction.straight)
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
    ride(accel, turn)
    -- No progress for 3 s: blocked (a tree, a building, water).
    if api.distance(v.position, action.last) < 0.05 then
      action.still = action.still + 1
      if action.still >= 180 then
        ride(R.acceleration.nothing, R.direction.straight)
        return 'blocked'
      end
    else action.still, action.last = 0, v.position end
    return nil
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
