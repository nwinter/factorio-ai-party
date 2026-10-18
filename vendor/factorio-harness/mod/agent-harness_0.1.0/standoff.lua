-- move_to {stand_off: {target, reach}} (d17 batch20 C3, Opus: died at 111h33 when the walk to a firing spot clipped a
-- big worm's range): the spot within reach tiles of the target, outside every worm's range, spawner's reach and area
-- under attack the map shows plus the walk's margin (avoid.lua margin_discs, as move_to's own goal check counts them),
-- the one nearest the character; with none, the same at the bare reach (no margin), said so; with none at all, refused.
-- The walk there is a plain move_to to that spot, with its avoidance.
return function(api)
  local M = {}
  local function dist(a, b) return ((a.x - b.x)^2 + (a.y - b.y)^2)^0.5 end
  local function at(q) return string.format('(%g,%g)', q.x, q.y) end
  local function round(v) return math.floor(v * 10 + 0.5) / 10 end
  -- The spot nearest from within reach of target and outside every disc; nil when none. Candidates on rings round the
  -- target every tile from reach - 0.5 in, every 5 degrees, on charted chunks.
  function M.spot(p, target, reach, discs, from)
    local best, bd
    local r = reach - 0.5
    while r >= 1 do
      for deg = 0, 355, 5 do
        local t = math.rad(deg)
        local q = {x=round(target.x + r * math.cos(t)), y=round(target.y + r * math.sin(t))}
        local ok = api.charted(p, q)
        if ok then
          for _, d in ipairs(discs) do if dist(q, d) < d.r then ok = false; break end end
        end
        if ok then
          local dd = dist(q, from)
          if not bd or dd < bd then best, bd = q, dd end
        end
      end
      r = r - 1
    end
    return best
  end
  function M.move(p, a, walk)
    local s = a.stand_off
    assert(type(s) == 'table' and s.target ~= nil, 'stand_off is {target: {x,y}, reach: tiles}: the spot within reach of the target and outside every worm\'s range')
    assert(a.position == nil and a.target == nil, 'stand_off picks the position: no position or target beside it')
    local target = api.position(s.target)
    local reach = s.reach
    assert(type(reach) == 'number' and reach >= 1 and reach <= 64, 'stand_off.reach is 1..64 tiles (e.g. your weapon\'s range)')
    local mode = api.avoid.mode(a.avoid_enemies)
    local discs = mode and api.avoid.margin_discs(p, target, mode, reach) or {}
    local spot = M.spot(p, target, reach, discs, p.position)
    local bare
    if not spot and mode then
      local plain = {}
      for k, v in pairs(mode) do plain[k] = v end
      plain.pad = 0
      discs = api.avoid.margin_discs(p, target, plain, reach)
      for _, d in ipairs(discs) do d.r = d.r + 0.5 end
      spot = M.spot(p, target, reach, discs, p.position)
      bare = spot ~= nil
    end
    if not spot then
      local names = {}
      for i, d in ipairs(discs) do if i <= 4 then names[i] = string.format('%s %s reach %g', d.name, at(d), d.range) end end
      error(string.format('no spot within %g tiles of %s lies outside every reach the map shows: %s', reach, at(target), table.concat(names, '; ')), 0)
    end
    local b = {}
    for k, v in pairs(a) do if k ~= 'stand_off' then b[k] = v end end
    b.position = spot
    local out = walk(b)
    -- the nearest reach edge from the spot
    local near, nd
    for _, d in ipairs(discs) do local e = dist(spot, d) - d.range; if not nd or e < nd then near, nd = d, e end end
    local line = string.format('stands at %s, %.1f tiles from %s (reach %g), outside every worm\'s range, spawner\'s reach and area under attack the map shows%s%s',
      at(spot), dist(spot, target), at(target), reach,
      bare and ' (no spot clear of them by the walk\'s margin: at their bare reach)' or (mode and string.format(' + %g', mode.pad) or ''),
      near and string.format('; the nearest: %s %s reach %g, %.1f tiles beyond it', near.name, at(near), near.range, nd) or '')
    if type(out) == 'table' then out.stand_off = line end
    return out
  end
  return M
end
