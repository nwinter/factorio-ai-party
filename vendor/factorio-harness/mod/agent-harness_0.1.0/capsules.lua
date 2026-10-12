-- Capsules (request #89): use_item throws a grenade, a poison or slowdown
-- capsule, a combat robot capsule or cliff-free throwables at a position, or
-- uses one on the character (raw fish), with the item prototype's own range,
-- minimum range and cooldown. The thrown thing is the game's own projectile
-- (or stream) from the capsule's action, created from the character with it as
-- the source, so its effects, damage and kills are the game's. One item is
-- used from the inventory. Bots have no LuaPlayer to throw from a cursor, so
-- every agent throws this one way.
return function(api)
  local M = {handlers={}}
  local SUPPORTED = {throw=true, ['use-on-self']=true}
  M.schema = {
    use_item = {item='a capsule you hold: grenade, cluster-grenade, poison-capsule, slowdown-capsule, defender-capsule, distractor-capsule, destroyer-capsule, raw-fish, ...',
      position='{x,y} target for a thrown capsule: in sight, within its range (and beyond its minimum range); not for one used on yourself',
      quality='default normal',
      returns='used, kind (throw|self), target, projectile, distance, range, cooldown_ticks, left (how many you still hold), healed (self). Refused: not held, not a capsule, out of range (with the range), too close, cooling down (ticks left)'},
  }
  local function ready_ticks()
    local s = api.state()
    s.capsule_ready = s.capsule_ready or {}
    return s.capsule_ready
  end
  -- The first value under `key` in a prototype's nested action tables.
  local function find(t, key, depth)
    if type(t) ~= 'table' or depth > 8 then return nil end
    local ok, v = pcall(function() return t[key] end)
    if ok and v ~= nil then return v end
    for _, sub in pairs(t) do
      local hit = find(sub, key, depth + 1)
      if hit ~= nil then return hit end
    end
    return nil
  end
  local function heal_of(ap)
    local function walk(t, depth)
      if type(t) ~= 'table' or depth > 8 then return nil end
      if t.type == 'damage' and type(t.damage) == 'table' and type(t.damage.amount) == 'number' and t.damage.amount < 0 then return -t.damage.amount end
      for _, sub in pairs(t) do local h = walk(sub, depth + 1); if h then return h end end
      return nil
    end
    return walk(ap, 0) or 80
  end
  function M.handlers.use_item(p, a)
    assert(type(a.item) == 'string', 'item is required: the capsule to use')
    local proto = prototypes.item[a.item]
    assert(proto, 'unknown item ' .. a.item)
    local ca = proto.capsule_action
    assert(ca, a.item .. ' is not a capsule (grenades, poison and slowdown capsules, combat robot capsules, raw fish)')
    assert(SUPPORTED[ca.type], a.item .. ' (' .. tostring(ca.type) .. ') is not usable this way; use_item throws or uses capsules on yourself')
    local quality = a.quality or 'normal'
    local c = p.character
    assert(c and c.valid, 'a living character is required')
    local have = api.held(p, a.item, quality)
    assert(have > 0, 'no ' .. a.item .. ' held')
    local ready = ready_ticks()[p.index] or 0
    if game.tick < ready then error(string.format('cooling down: %d ticks left before the next capsule', ready - game.tick), 0) end
    local ap = ca.attack_parameters or {}
    local cooldown = math.max(1, math.floor(ap.cooldown or 30))
    local out = {used=a.item, quality=a.quality, cooldown_ticks=cooldown}
    if ca.type == 'throw' then
      assert(a.position ~= nil, 'position is required: where to throw ' .. a.item)
      local pos = api.position(a.position)
      api.assert_visible(p, pos, 'target')
      local from = c.position
      local d = math.sqrt((pos.x - from.x) ^ 2 + (pos.y - from.y) ^ 2)
      local range, min_range = ap.range or 0, ap.min_range or 0
      if d > range then
        error(string.format('out of range: (%g,%g) is %.1f tiles away; %s reaches %g tiles', pos.x, pos.y, d, a.item, range), 0)
      end
      if d < min_range then
        error(string.format('too close: (%g,%g) is %.1f tiles away; %s needs at least %g tiles', pos.x, pos.y, d, a.item, min_range), 0)
      end
      local projectile = find(ap, 'projectile', 0)
      local stream = not projectile and find(ap, 'stream', 0) or nil
      if not projectile and not stream then
        local e = prototypes.entity[a.item]
        projectile = e and e.type == 'projectile' and a.item or nil
      end
      assert(projectile or stream, a.item .. ': no projectile found in its capsule action')
      local made
      if projectile then
        made = p.surface.create_entity{name=projectile, position=from, target=pos, source=c, force=p.force, speed=0.3, max_range=range + 2}
      else
        made = p.surface.create_entity{name=stream, position=from, source_position=from, target_position=pos, source=c, force=p.force}
      end
      assert(made, 'the game did not create ' .. tostring(projectile or stream))
      out.kind, out.target, out.projectile = 'throw', pos, projectile or stream
      out.distance, out.range = math.floor(d * 10 + 0.5) / 10, range
    else
      local heal = heal_of(ap)
      local before = c.health
      c.health = before + heal
      out.kind, out.healed = 'self', math.floor(c.health - before + 0.5)
    end
    local removed = p.get_main_inventory().remove{name=a.item, count=1, quality=quality}
    assert(removed == 1, 'could not take ' .. a.item .. ' from the inventory')
    ready_ticks()[p.index] = game.tick + cooldown
    out.left = have - 1
    return out
  end
  return M
end
