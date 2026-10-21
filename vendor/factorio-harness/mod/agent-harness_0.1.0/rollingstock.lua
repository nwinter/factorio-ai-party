-- rollingstock: a locomotive's or wagon's facing on the rail, placed and flipped (d20 batch71 AG2, Sol #1688: T37's
-- rear locomotive on Fulgora rebuilt with direction southeast faced the same way as the other, so train 40 could not
-- reverse; rotate {direction: south} said "locomotive has no direction").
-- Read on 2.0.77 (private copy, a straight north-south ground rail):
--   * rolling stock has supports_direction false and LuaEntity.direction reads 0; its facing is LuaEntity.orientation
--     (0 north, 0.25 east, 0.5 south, 0.75 west); create_entity with direction south made orientation 0.5, and with
--     orientation 0.5 the same; asked across the rail it snaps to the nearer way along it (northeast 0, east 0.5,
--     southeast 0.5, southwest 0.5, northwest 0); placed 7 tiles behind another (joint 4 + connection 3) it couples;
--   * the game's rotate (as R) flips a lone locomotive 180 degrees (0.5 to 0, and reverse back) and refuses one coupled
--     to another (returns false, nothing changes); uncoupled (disconnect_rolling_stock on the side the other stands),
--     it flips, and connect_rolling_stock on its new front couples it again: a train of 2 front movers from 1 front
--     and 1 back, its train id new;
--   * LuaTrain.locomotives gives front_movers and back_movers (a train runs backward on its back movers).
return function(api)
  local M = {}
  M.TYPES = {locomotive=true, ['cargo-wagon']=true, ['fluid-wagon']=true, ['artillery-wagon']=true, ['infinity-cargo-wagon']=true}
  local NAMES = {[0]='north', 'northnortheast', 'northeast', 'eastnortheast', 'east', 'eastsoutheast', 'southeast', 'southsoutheast',
    'south', 'southsouthwest', 'southwest', 'westsouthwest', 'west', 'westnorthwest', 'northwest', 'northnorthwest'}
  local STATES
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function at(p) return string.format('(%g,%g)', math.floor(p.x * 100 + 0.5) / 100, math.floor(p.y * 100 + 0.5) / 100) end
  function M.facing(o) return NAMES[math.floor((o or 0) * 16 + 0.5) % 16] end
  -- orientation as given (0..1): the direction (0..15) the game is asked with.
  function M.direction_of_orientation(v)
    assert(type(v) == 'number' and v >= 0 and v <= 1, 'orientation is 0..1 (0 north, 0.25 east, 0.5 south, 0.75 west)')
    return math.floor(v * 16 + 0.5) % 16
  end
  local function state_name(s)
    if not STATES then STATES = {}; for k, v in pairs(defines.train_state or {}) do STATES[v] = k end end
    return STATES[s] or tostring(s)
  end
  local function stock_at(e, rd)
    local o = try(function() return e.get_connected_rolling_stock(rd) end)
    return o and o.valid and o or nil
  end
  -- {orientation, facing, coupled {front, back}, train {id, carriages, front_locomotives, back_locomotives, state, manual}, line}
  function M.read(e)
    if not (e and e.valid and M.TYPES[e.type]) then return nil end
    local out = {orientation=math.floor(e.orientation * 10000 + 0.5) / 10000, facing=M.facing(e.orientation)}
    local f, b = stock_at(e, defines.rail_direction.front), stock_at(e, defines.rail_direction.back)
    out.coupled = {front=f and string.format('%s %s', f.name, at(f.position)) or nil, back=b and string.format('%s %s', b.name, at(b.position)) or nil}
    local t = try(function() return e.train end)
    if t then
      local l = t.locomotives or {}
      out.train = {id=t.id, carriages=#t.carriages, front_locomotives=#(l.front_movers or {}), back_locomotives=#(l.back_movers or {}), state=state_name(t.state),
        manual=t.manual_mode, speed=t.speed ~= 0 and t.speed or nil}
    end
    out.line = string.format('%s %s faces %s (orientation %g); coupled: front %s, back %s%s', e.name, at(e.position), out.facing, out.orientation,
      out.coupled.front or 'none', out.coupled.back or 'none',
      out.train and string.format('; train %d: %d carriage%s, %d locomotive%s facing its front, %d facing its back (it runs backward on those)',
        out.train.id, out.train.carriages, out.train.carriages == 1 and '' or 's', out.train.front_locomotives, out.train.front_locomotives == 1 and '' or 's',
        out.train.back_locomotives) or '')
    return out
  end
  -- The turn from orientation a to the facing of direction d: true when they point more than 90 degrees apart.
  function M.opposite(o, d)
    local diff = math.abs(((d / 16) - o + 0.5) % 1 - 0.5)
    return diff > 0.25 + 1e-6
  end
  -- Flip it 180 degrees as a player does: R on a lone one; a coupled one is uncoupled at each end first, flipped, and
  -- coupled again at both ends. Refused while its train moves.
  function M.flip(e, by_player)
    local t = try(function() return e.train end)
    assert(not (t and t.speed ~= 0), string.format('%s %s: its train moves (speed %g): the game flips rolling stock of a stopped train', e.name, at(e.position), t and t.speed or 0))
    local steps = {}
    local was = {}
    for _, rd in ipairs({defines.rail_direction.front, defines.rail_direction.back}) do
      local o = stock_at(e, rd)
      if o then
        if e.disconnect_rolling_stock(rd) then
          was[#was+1] = o
          steps[#steps+1] = string.format('uncoupled from %s %s', o.name, at(o.position))
        end
      end
    end
    local before = e.orientation
    local ok = e.rotate{by_player=by_player}
    if not ok then
      for _, rd in ipairs({defines.rail_direction.front, defines.rail_direction.back}) do try(function() return e.connect_rolling_stock(rd) end) end
      error(string.format('%s %s: the game does not flip it (its rotate, as R, refuses)%s; coupled again as it was', e.name, at(e.position),
        #steps > 0 and ' after ' .. table.concat(steps, ', ') or ''), 0)
    end
    steps[#steps+1] = string.format('flipped from %s to %s', M.facing(before), M.facing(e.orientation))
    for _, rd in ipairs({defines.rail_direction.front, defines.rail_direction.back}) do
      if try(function() return e.connect_rolling_stock(rd) end) then
        local o = stock_at(e, rd)
        steps[#steps+1] = string.format('coupled to %s %s', o and o.name or '?', o and at(o.position) or '')
      end
    end
    local lost = {}
    for _, o in ipairs(was) do
      local back = false
      for _, rd in ipairs({defines.rail_direction.front, defines.rail_direction.back}) do if stock_at(e, rd) == o then back = true end end
      if not back and o.valid then lost[#lost+1] = string.format('%s %s', o.name, at(o.position)) end
    end
    return {steps=steps, not_recoupled=#lost > 0 and lost or nil}
  end
  -- rotate on rolling stock: flip it, or with direction flip it when it faces more than 90 degrees from there.
  function M.rotate(e, target, by_player)
    local before = M.read(e)
    if target ~= nil and not M.opposite(e.orientation, target) then
      return {name=e.name, position=e.position, unchanged=string.format('%s already faces %s (orientation %g), within 90 degrees of %s', e.name, before.facing, before.orientation, NAMES[target]),
        rolling_stock=before}
    end
    local f = M.flip(e, by_player)
    local after = M.read(e)
    return {name=e.name, position=e.position, flipped=table.concat(f.steps, '; '), not_recoupled=f.not_recoupled, before=before.line, rolling_stock=after,
      note='rolling stock has no direction (the game reads 0); its facing is orientation, flipped 180 degrees as R does; the game flips one coupled to another only uncoupled, so its couplings are undone first and made again'}
  end
  -- A dry run's word on the facing: the rail under it and the two ways along it, and the one the asked direction snaps to.
  function M.snap_text(surface, pos, dir)
    local rails = try(function() return surface.find_entities_filtered{position=pos, radius=1.5, type={'straight-rail', 'half-diagonal-rail', 'curved-rail-a', 'curved-rail-b',
      'elevated-straight-rail', 'elevated-half-diagonal-rail', 'elevated-curved-rail-a', 'elevated-curved-rail-b'}, limit=4} end) or {}
    local r = rails[1]
    if not r then return 'no rail under it within 1.5 tiles' end
    local a = (r.direction % 8)
    local o1, o2 = a / 16, (a + 8) / 16
    local want = dir / 16
    local d1 = math.abs((o1 - want + 0.5) % 1 - 0.5)
    local d2 = math.abs((o2 - want + 0.5) % 1 - 0.5)
    local pick = d1 < d2 and o1 or d2 < d1 and o2 or nil
    return string.format('on %s %s, along it %s (%g) or %s (%g); asked %s: %s', r.name, at(r.position), M.facing(o1), o1, M.facing(o2), o2, NAMES[dir],
      pick and string.format('faces %s (%g)', M.facing(pick), pick) or 'across the rail: the game picks one of the two (readback says which)')
  end
  return M
end
