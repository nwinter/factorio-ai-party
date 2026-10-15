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
    use_item = {item='a capsule you hold: grenade, cluster-grenade, poison-capsule, slowdown-capsule, defender-capsule, distractor-capsule, destroyer-capsule, raw-fish, cliff-explosives, artillery-targeting-remote (held, or by the shortcut once artillery is researched; not used up: an artillery flare at position, any charted tile, and our artillery with shells that reaches it fires there; the reply lists those pieces), ...',
      position='{x,y} target for a thrown capsule: in sight, within its range (and beyond its minimum range); not for one used on yourself',
      quality='default normal',
      walk='cliff-explosives only: true walks into range first (as clear_cliffs)',
      returns='used, kind (throw|self), target, projectile, distance, range, cooldown_ticks, left (how many you still hold), healed (self). Refused: not held, not a capsule, out of range (with the range), too close, cooling down (ticks left). cliff-explosives: a timed call, as clear_cliffs with that one position'},
    clear_cliffs = {position='{x,y} a cliff (as scan lists it) or a spot whose blast reaches cliffs', positions='or 1..16 of them, cleared in order',
      walk='default true: walk into the explosives\' range of each spot first (pathfinding as move_to); false: a spot out of range ends out_of_range',
      item='default cliff-explosives', quality='default normal', ticks='1..36000 (default 7200)',
      returns='throws cliff explosives as a player does: the game\'s own capsule (range 10 tiles from the character, cooldown 30 ticks, blast radius 1.5), one per spot, each landing before the next; a timed call. Reply: until_tick, spots [{position, cliffs: the cliffs in its blast now}], range, held; refused at once when no listed spot has a cliff in its blast (the nearest cliff named). last: thrown, destroyed [{name, position}], skipped [{position, why}], left (explosives still held); outcomes cliffs_destroyed | nothing_to_do (every spot was clear already) | nothing_destroyed | out_of_items | out_of_range | timed_out; fh --wait waits for the end'},
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
    assert(ca, a.item .. ' is not a capsule (grenades, poison and slowdown capsules, combat robot capsules, raw fish, cliff explosives)')
    -- Cliff explosives (Sol 15:41: "destroy-cliffs not usable this way" at (82,38.5) on Gleba): a throw whose blast
    -- destroys cliffs, timed until it lands (clear_cliffs).
    if ca.type == 'destroy-cliffs' then
      assert(a.position ~= nil, 'position is required: the cliff to blow up (as scan lists it)')
      return M.handlers.clear_cliffs(p, {position=a.position, item=a.item, quality=a.quality, walk=a.walk == true})
    end
    -- The artillery targeting remote (Grok, d15 14:07): a flare at the position (artillery.lua).
    if ca.type == 'artillery-remote' and api.artillery_remote then return api.artillery_remote(p, a, ca) end
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
  -- ---- cliff explosives -------------------------------------------------------------------------------------------
  local function cliff_capsule(name)
    local proto = prototypes.item[name]
    assert(proto, 'unknown item ' .. name)
    local ca = proto.capsule_action
    assert(ca and ca.type == 'destroy-cliffs', name .. ' is not a cliff explosive (cliff-explosives)')
    local ap = ca.attack_parameters or {}
    local projectile = find(ap, 'projectile', 0) or name
    return {range=ap.range or 10, cooldown=math.max(1, math.floor(ap.cooldown or 30)), radius=ca.radius or 1.5, projectile=projectile}
  end
  -- The cliffs a blast at pos destroys (the capsule's radius, cliff boxes touching it: a margin of half a tile).
  local function in_blast(surface, pos, radius)
    local out = {}
    for _, e in ipairs(surface.find_entities_filtered{type='cliff', position=pos, radius=radius + 0.5, limit=16}) do
      if e.valid then out[#out+1] = e end
    end
    return out
  end
  local function cliff_rows(list)
    local out = {}
    for _, e in ipairs(list) do if e.valid then out[#out+1] = {name=e.name, position={x=e.position.x, y=e.position.y}} end end
    return out
  end
  function M.handlers.clear_cliffs(p, a)
    local item = a.item or 'cliff-explosives'
    local cap = cliff_capsule(item)
    local quality = a.quality or 'normal'
    local c = p.character
    assert(c and c.valid, 'a living character is required')
    local have = api.held(p, item, quality)
    assert(have > 0, 'no ' .. item .. ' held')
    local list
    if a.positions ~= nil then
      assert(a.position == nil, 'position or positions, not both')
      assert(type(a.positions) == 'table' and #a.positions >= 1 and #a.positions <= 16, 'positions requires 1..16 {x,y}')
      list = {}
      for _, raw in ipairs(a.positions) do list[#list+1] = api.position(raw) end
    else
      assert(a.position ~= nil, 'position or positions is required: the cliffs to blow up (as scan lists them)')
      list = {api.position(a.position)}
    end
    local spots, any = {}, false
    for _, pos in ipairs(list) do
      api.assert_visible(p, pos, 'cliff')
      local cl = in_blast(p.surface, pos, cap.radius)
      any = any or #cl > 0
      spots[#spots+1] = {position=pos, cliffs=cliff_rows(cl)}
    end
    if not any then
      local near = p.surface.find_entities_filtered{type='cliff', position=list[1], radius=32, limit=64}
      local best, bd
      for _, e in ipairs(near) do
        local d = api.distance(list[1], e.position)
        if not bd or d < bd then best, bd = e, d end
      end
      error(string.format('no cliff within the blast (radius %g) of (%g,%g)%s', cap.radius, list[1].x, list[1].y,
        best and string.format('; nearest cliff: %s at (%g,%g), %.1f tiles away', best.name, best.position.x, best.position.y, bd) or '; none within 32 tiles'), 0)
    end
    local walk = a.walk ~= false
    if not walk then
      local d = api.distance(c.position, list[1])
      if d > cap.range then
        error(string.format('out of range: (%g,%g) is %.1f tiles away; %s reaches %g tiles (walk: true walks into range first)', list[1].x, list[1].y, d, item, cap.range), 0)
      end
    end
    local ticks = api.integer(a.ticks, 7200, 1, 36000, 'ticks')
    local action = {kind='clear_cliffs', item=item, quality=quality, spots=list, i=1, walk=walk, until_tick=game.tick + ticks,
      report={thrown=0, destroyed={}, skipped={}, item=item}}
    api.start(p, action)
    return {until_tick=action.until_tick, spots=spots, range=cap.range, blast_radius=cap.radius, held=have,
      timed='until tick ' .. action.until_tick .. ': last.destroyed says which cliffs went (status, fh --wait)'}
  end
  function M.tick_cliffs(p, action, tick)
    local cap = cliff_capsule(action.item)
    local r = action.report
    local c = p.character
    if not (c and c.valid) then return 'failed' end
    r.left = api.held(p, action.item, action.quality)
    local pend = action.pending
    if pend then  -- the thrown capsule lands: which of its cliffs are gone
      if tick < pend.check_tick then return nil end
      for i, e in ipairs(pend.cliffs) do
        if not e.valid then r.destroyed[#r.destroyed+1] = pend.rows[i] end
      end
      action.pending, action.i = nil, action.i + 1
      return nil
    end
    local pos = action.spots[action.i]
    -- every spot clear already, nothing thrown: nothing_to_do (a success); thrown and nothing gone: nothing_destroyed
    if not pos then return #r.destroyed > 0 and 'cliffs_destroyed' or (r.thrown == 0 and 'nothing_to_do') or 'nothing_destroyed' end
    local cl = in_blast(p.surface, pos, cap.radius)
    if #cl == 0 then
      r.skipped[#r.skipped+1] = {position=pos, why='no cliff left in the blast'}
      action.i = action.i + 1
      return nil
    end
    if r.left <= 0 then return 'out_of_items' end
    local d = api.distance(c.position, pos)
    if d > cap.range - 0.5 then
      if not action.walk then return 'out_of_range' end
      if not action.nav then
        action.nav = {position=pos, tolerance=cap.range - 2, max_stalls=6, replans=0, stalled=0, last_position=p.position}
        api.request_path(p, action.nav)
      end
      local outcome = api.navigate(p, action.nav)
      if outcome then
        api.stop_walking(p)
        action.nav = nil
        if outcome ~= 'arrived' and outcome ~= 'arrived_near' and api.distance(c.position, pos) > cap.range - 0.5 then
          r.skipped[#r.skipped+1] = {position=pos, why='could not walk into range (' .. tostring(outcome) .. ')'}
          action.i = action.i + 1
        end
      end
      return nil
    end
    if action.nav then api.stop_walking(p); action.nav = nil end
    if tick < (ready_ticks()[p.index] or 0) then return nil end
    -- The game's own capsule: its projectile from the character, with it as the source (its blast destroys cliffs).
    local made = p.surface.create_entity{name=cap.projectile, position=c.position, target=pos, source=c, force=p.force, speed=0.3, max_range=cap.range + 2}
    if not made then
      r.skipped[#r.skipped+1] = {position=pos, why='the game did not create ' .. tostring(cap.projectile)}
      action.i = action.i + 1
      return nil
    end
    local removed = p.get_main_inventory().remove{name=action.item, count=1, quality=action.quality}
    if removed ~= 1 then return 'failed' end
    ready_ticks()[p.index] = tick + cap.cooldown
    r.thrown = r.thrown + 1
    r.left = r.left - 1
    action.pending = {cliffs=cl, rows=cliff_rows(cl), check_tick=tick + math.ceil(d / 0.3) + 15}
    return nil
  end
  return M
end
