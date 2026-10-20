-- What a standing order or a recurring reminder serves (d20 batch50 B2, viewer Aurora, shift45 06:26: "Could standing
-- orders link to the system they serve and flag when it is retired or superseded? The boiler debate showed how old
-- duties can outlive their purpose." Haiku's boilerfuel order, set at game 22h44m in shift06, a coal top-up of the
-- burners within 20 tiles of (8.5,42), was still on watch at 170h after 13422 runs, its last at tick 35975208).
-- serves {name, position, surface?, radius?}: the machine (an entity of that name of our force within 1 tile of the
-- position) or, with radius 2..64, any such machine within radius of it; surface defaults to the setter's. Checked when
-- set, then about once a game minute (orders.lua look, reminders.lua tick) and when read: one count of that name in a
-- small circle. last_seen_tick is the last check that found one; a check that finds none flags it (gone_tick).
return function()
  local M = {}
  M.EVERY = 3600
  M.MAX_RADIUS = 64
  local function num(v) return type(v) == 'number' and v == v and v ~= math.huge and v ~= -math.huge end
  function M.parse(v, p)
    if v == nil then return nil end
    assert(type(v) == 'table', 'serves is {name, position, surface?, radius?}: the machine (or machines in a radius) it serves')
    local name = v.name
    assert(type(name) == 'string' and #name > 0 and #name <= 64, 'serves.name: an entity name (boiler, gun-turret, ...)')
    if type(prototypes) == 'table' and prototypes.entity then
      local ok, proto = pcall(function() return prototypes.entity[name] end)
      assert(ok and proto, 'serves.name: no entity named ' .. name)
    end
    local q = v.position
    assert(type(q) == 'table', 'serves.position {x,y} is required')
    local x, y = q.x or q[1], q.y or q[2]
    assert(num(x) and num(y), 'serves.position must be {x,y}')
    local r = v.radius
    assert(r == nil or (num(r) and r >= 0 and r <= M.MAX_RADIUS), 'serves.radius: 0..' .. M.MAX_RADIUS .. ' tiles')
    local surface = v.surface
    if surface == nil then surface = p and p.valid and p.surface and p.surface.name end
    assert(type(surface) == 'string', 'serves.surface: a surface name (nauvis, platform-2, ...)')
    local force = p and p.force and p.force.name or 'player'
    local sv = {name=name, position={x=x, y=y}, surface=surface, radius=(r and r > 1) and r or nil, force=force, set_tick=game.tick}
    M.check(sv)
    return sv
  end
  function M.check(sv)
    local s = game.get_surface(sv.surface)
    local n = 0
    if s and (s.valid == nil or s.valid) then
      local ok, c = pcall(function()
        return s.count_entities_filtered{name=sv.name, position=sv.position, radius=sv.radius or 1, force=sv.force}
      end)
      if ok and type(c) == 'number' then n = c end
    end
    sv.checked_tick, sv.count = game.tick, n
    if n > 0 then sv.last_seen_tick, sv.gone_tick = game.tick, nil
    elseif not sv.gone_tick then sv.gone_tick = game.tick end
    return n
  end
  -- Checked again when EVERY ticks have passed since the last check.
  function M.due(sv)
    if sv and game.tick - (sv.checked_tick or 0) >= M.EVERY then M.check(sv) end
    return sv
  end
  local function ago(ticks)
    local s = math.max(0, math.floor(ticks / 60 + 0.5))
    if s >= 3600 then return string.format('%dh%02dm', math.floor(s / 3600), math.floor(s % 3600 / 60)) end
    if s >= 60 then return string.format('%dm%02ds', math.floor(s / 60), s % 60) end
    return s .. 's'
  end
  local function what(sv)
    return string.format('%s %s (%g,%g) on %s', sv.name, sv.radius and ('within ' .. sv.radius .. ' of') or 'at', sv.position.x, sv.position.y,
      sv.surface)
  end
  -- 'serves boiler within 20 of (8.5,42) on nauvis: 14 there (tick T)', or, flagged, 'serves boiler at (8.5,42) on
  -- nauvis: none there since tick G (checked tick C); last seen tick L, 2h10m ago'.
  function M.line(sv)
    if sv.count and sv.count > 0 then
      return string.format('serves %s: %d there (tick %d)', what(sv), sv.count, sv.checked_tick)
    end
    local s = game.get_surface(sv.surface)
    local seen = sv.last_seen_tick and string.format('last seen tick %d, %s ago', sv.last_seen_tick, ago(game.tick - sv.last_seen_tick))
      or string.format('not seen since it was set at tick %d', sv.set_tick or 0)
    return string.format('serves %s: none there since tick %d (checked tick %d%s); %s', what(sv), sv.gone_tick or sv.checked_tick or game.tick,
      sv.checked_tick or game.tick, s and '' or ', no such surface now', seen)
  end
  function M.view(sv)
    if not sv then return nil end
    return {name=sv.name, position=sv.position, surface=sv.surface, radius=sv.radius, count=sv.count, checked_tick=sv.checked_tick,
      last_seen_tick=sv.last_seen_tick, gone=(sv.count or 0) == 0 or nil, gone_tick=sv.gone_tick, line=M.line(sv)}
  end
  function M.gone(sv) return sv ~= nil and (sv.count or 0) == 0 end
  M.SCHEMA = 'optional {name, position, surface?, radius?}: the machine it serves (an entity of that name of ours within 1 tile of position, '
    .. 'on surface, default yours), or with radius 2..64 any such machine within it; checked about once a game minute and when read: '
    .. 'serves {count, last_seen_tick, gone, gone_tick, line} in the read, and a line naming it when none is there'
  return M
end
