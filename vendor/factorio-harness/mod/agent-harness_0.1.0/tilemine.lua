-- Tiles mined by hand (tilemine.lua; Sol, operator 15:30: landfill under an old pole at (194,58) kept a 3x3 planting
-- cell off the yumako farm, with no robots there; deconstruct only marks tiles for robots, and construct mined
-- entities only). On 2.0.77 LuaControl.mine_tile returned false for a character without a player every time on a copy
-- of world n (on the tile, beside it, with room in the inventory), so the harness mines as a player does: within
-- reach (reach_distance, to the tile's square), the tile's mining time at the character's mining speed, the product
-- into the main inventory, the tile under it put back (its hidden tile; what was under that becomes the new hidden
-- tile). A natural tile (not minable, or nothing laid under it) and a tile anything stands on are refused, naming it.
-- Tiles are named by the game's tile coordinates: the tile's top-left corner, as grid and F4 show them.
return function(api)
  local M = {}
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function at(x, y) return string.format('(%d,%d)', x, y) end
  -- What never stands in the way of mining a tile: what moves or flies, marks, remnants and items on the ground (a
  -- character too, unless the tile put back is one it cannot stand on).
  local PASSING = {character=true, corpse=true, ['character-corpse']=true, ['item-entity']=true, ['item-request-proxy']=true,
    ['tile-ghost']=true, ['deconstructible-tile-proxy']=true, unit=true, ['spider-unit']=true, ['segmented-unit']=true,
    ['combat-robot']=true, ['construction-robot']=true, ['logistic-robot']=true, ['capture-robot']=true, projectile=true,
    ['artillery-projectile']=true, stream=true, fire=true, sticker=true, particle=true, ['particle-source']=true,
    explosion=true, ['smoke-with-trigger']=true, ['highlight-box']=true, ['speech-bubble']=true, beam=true, fish=true}
  local MAX_TILES, MAX_AREA = 256, 32
  function M.reach(p) return try(function() return p.reach_distance end) or 10 end
  -- From the character to the tile's square, as reach is measured to an entity's box.
  function M.distance(p, x, y)
    local pos = p.position
    local dx = math.max(x - pos.x, 0, pos.x - (x + 1))
    local dy = math.max(y - pos.y, 0, pos.y - (y + 1))
    return (dx * dx + dy * dy) ^ 0.5
  end
  function M.in_reach(p, x, y) return M.distance(p, x, y) <= M.reach(p) end
  -- Ticks a hand mines a tile in: its mining time at the character's mining speed (as an entity's).
  function M.ticks(p, mining_time)
    local c = p.character
    local speed = (c and c.prototype.mining_speed or 0.5) * (1 + (c and c.character_mining_speed_modifier or 0)
      + (try(function() return p.force.manual_mining_speed_modifier end) or 0))
    return math.max(1, math.ceil((mining_time or 0.5) * 60 / speed))
  end
  -- The tile at (x, y) and why a player could not mine it now (why), or what mining it gives: name, hidden (put back),
  -- double (hidden under that), products {name, count}, ticks.
  function M.check(p, x, y)
    local s = p.surface
    local t = s.get_tile(x, y)
    if not (t and t.valid) then return {x=x, y=y, why='no tile at '..at(x, y)} end
    local info = {x=x, y=y, name=t.name, hidden=t.hidden_tile, double=try(function() return t.double_hidden_tile end)}
    local mp = t.prototype.mineable_properties
    if not (mp and mp.minable) then info.why = string.format('%s at %s is not minable (a natural tile)', t.name, at(x, y)); return info end
    if not info.hidden then info.why = string.format('%s at %s has no tile laid under it to put back', t.name, at(x, y)); return info end
    -- A character stands in the way only when the tile put back is one it cannot stand on (water under landfill).
    local under = prototypes.tile[info.hidden]
    local wet = under and under.collision_mask and under.collision_mask.layers and under.collision_mask.layers.player
    for _, e in pairs(s.find_entities_filtered{area={{x, y}, {x + 1, y + 1}}}) do
      if e.valid and (not PASSING[e.type] or (wet and e.type == 'character')) then
        local b = e.bounding_box
        if b.right_bottom.x > x + 0.01 and b.left_top.x < x + 0.99 and b.right_bottom.y > y + 0.01 and b.left_top.y < y + 0.99 then
          info.why = string.format('%s at %s has %s (%g,%g) on it: mine it first', t.name, at(x, y), e.name, e.position.x, e.position.y)
          info.blocker = {name=e.name, position={x=e.position.x, y=e.position.y}}
          return info
        end
      end
    end
    local products = {}
    for _, pr in ipairs(mp.products or {}) do
      local n = pr.amount or pr.amount_max or 1
      if (pr.type == nil or pr.type == 'item') and n > 0 then products[#products+1] = {name=pr.name, count=n} end
    end
    info.products = products
    info.ticks = M.ticks(p, mp.mining_time)
    return info
  end
  -- Mines it now (its time is up): the checks again, the product into the main inventory, the tile under it put back,
  -- a deconstruction mark on it spent. Returns the row, or nil, why ('inventory_full' when the product has no room).
  function M.mine(p, x, y)
    local info = M.check(p, x, y)
    if info.why then return nil, info.why end
    local inv = p.get_main_inventory()
    for _, pr in ipairs(info.products) do
      if not (inv and inv.can_insert{name=pr.name, count=pr.count}) then return nil, 'inventory_full', pr.name end
    end
    local s = p.surface
    s.set_tiles({{name=info.hidden, position={x, y}}}, true, false, true, true)
    -- What was under the hidden tile becomes the new hidden tile (concrete over landfill over water: landfill, water under it).
    pcall(s.set_hidden_tile, {x, y}, info.double)
    pcall(s.set_double_hidden_tile, {x, y}, nil)
    for _, pr in ipairs(info.products) do inv.insert{name=pr.name, count=pr.count} end
    for _, e in pairs(s.find_entities_filtered{area={{x + 0.1, y + 0.1}, {x + 0.9, y + 0.9}}, type='deconstructible-tile-proxy'}) do
      if e.valid then e.destroy() end
    end
    return {position={x=x, y=y}, tile=info.name, restored=info.hidden, items=info.products}
  end
  -- The tiles a call names: position (one tile), positions (1..64) or area (up to 32x32: the minable tiles laid by a
  -- player there, name only that one). Returns tiles {x, y}, natural (tiles of the area left out).
  local function named(a)
    local list, natural = {}, 0
    if a.area ~= nil then
      assert(type(a.area) == 'table', 'area is {left_top, right_bottom}')
      local lt, rb = api.position(a.area.left_top or a.area[1]), api.position(a.area.right_bottom or a.area[2])
      local x0, y0, x1, y1 = math.floor(lt.x), math.floor(lt.y), math.ceil(rb.x) - 1, math.ceil(rb.y) - 1
      assert(x1 >= x0 and y1 >= y0 and x1 - x0 < MAX_AREA and y1 - y0 < MAX_AREA, 'area must be 1..'..MAX_AREA..' tiles a side')
      return {x0=x0, y0=y0, x1=x1, y1=y1}
    end
    local raw = a.positions or (a.position ~= nil and {a.position}) or nil
    assert(type(raw) == 'table' and #raw >= 1 and #raw <= 64, 'tiles: true takes position, positions (1..64) or area')
    for _, q in ipairs(raw) do
      local pos = api.position(q)
      list[#list+1] = {x=math.floor(pos.x), y=math.floor(pos.y)}
    end
    return list
  end
  -- mine {tiles: true, position | positions | area, name?, walk?, dry_run?, ticks?}: the reply, and the timed action
  -- to start (none for a dry run).
  function M.handle(p, a)
    assert(a.tiles == true, 'tiles: true mines the tiles at position, positions or area')
    assert(a.walk == nil or type(a.walk) == 'boolean', 'walk must be true or false')
    assert(a.name == nil or (type(a.name) == 'string' and prototypes.tile[a.name]), 'name is a tile name (landfill, concrete, stone-path, ...)')
    local c = p.character
    assert(c and c.valid, 'mining tiles needs your character')
    local spec = named(a)
    local targets, skipped, natural = {}, {}, 0
    local function consider(x, y, listed)
      -- (the map shows tiles on charted chunks: those only)
      if api.charted and not api.charted(p, {x=x + 0.5, y=y + 0.5}) then
        if listed then skipped[#skipped+1] = {position={x=x, y=y}, why=string.format('%s is on a chunk the map has not charted', at(x, y))} end
        return
      end
      local info = M.check(p, x, y)
      if a.name ~= nil and info.name ~= a.name then if listed then skipped[#skipped+1] = {position={x=x, y=y}, why=string.format('%s at %s is not %s', tostring(info.name), at(x, y), a.name)} end return end
      if info.why then
        if listed or info.blocker then skipped[#skipped+1] = {position={x=x, y=y}, why=info.why} else natural = natural + 1 end
        return
      end
      info.distance = M.distance(p, x, y)
      targets[#targets+1] = info
    end
    if spec.x0 then
      for x = spec.x0, spec.x1 do for y = spec.y0, spec.y1 do if #targets < MAX_TILES then consider(x, y, false) end end end
    else
      local dup = {}
      for _, t in ipairs(spec) do
        local k = t.x * 65536 + t.y
        if not dup[k] then dup[k] = true; consider(t.x, t.y, true) end
      end
    end
    local far, items, ticks = 0, {}, 0
    for _, t in ipairs(targets) do
      if t.distance > M.reach(p) then far = far + 1 end
      ticks = ticks + t.ticks
      for _, pr in ipairs(t.products) do items[pr.name] = (items[pr.name] or 0) + pr.count end
    end
    local function rows()
      local out = {}
      for i, t in ipairs(targets) do
        if i > 32 then break end
        out[i] = {position={x=t.x, y=t.y}, tile=t.name, restores=t.hidden, seconds=t.ticks / 60,
          in_reach=t.distance <= M.reach(p), distance=math.floor(t.distance * 10 + 0.5) / 10}
      end
      return out, #targets > 32 and #targets - 32 or nil
    end
    if a.dry_run then
      local list, more = rows()
      local farthest = 0
      for _, t in ipairs(targets) do if t.distance > M.reach(p) then farthest = math.max(farthest, t.distance) end end
      local range = api.autowalk and api.autowalk.RANGE or 32
      return {dry_run=true, note='nothing was mined', tiles=list, more=more, count=#targets, items=next(items) and items or nil,
        seconds=ticks / 60, out_of_reach=far > 0 and far or nil, reach=M.reach(p), skipped=#skipped > 0 and skipped or nil,
        natural=natural > 0 and natural or nil,
        walk=far > 0 and (a.walk == true and 'walk: true walks into reach of each' or a.walk == false and 'walk: false refuses those'
          or farthest <= range and string.format('the call walks into reach of those first (all within %d tiles; walk: false refuses)', range)
          or string.format('the farthest is %.1f tiles off, past the %d a call walks by default: walk: true walks there', farthest, range)) or nil}
    end
    if #targets == 0 then
      if #skipped > 0 then error(skipped[1].why..(#skipped > 1 and string.format(' (and %d more refused)', #skipped - 1) or ''), 0) end
      error(spec.x0 and string.format('no tile laid by a player in the area (%d natural tiles)', natural) or 'nothing to mine', 0)
    end
    -- Out of reach: walked into reach of each by default when every one lies within the 32 tiles a call walks
    -- (autowalk.lua), the reply saying so (walking); walk: true at any distance; walk: false refuses, as past 32 tiles.
    local walk, walking = a.walk == true, nil
    if far > 0 and a.walk ~= true then
      local t, worst
      for _, q in ipairs(targets) do
        if q.distance > M.reach(p) then t = t or q; if not worst or q.distance > worst.distance then worst = q end end
      end
      local range = api.autowalk and api.autowalk.RANGE or 32
      if a.walk == nil and not a.walked and worst.distance <= range then
        walk = true
        walking = #targets == 1 and string.format('%s at %s is %.1f tiles away (to its edge), reach %g: walking into reach first (walk: false refuses instead)',
            worst.name, at(worst.x, worst.y), worst.distance, M.reach(p))
          or string.format('%d of %d tiles are out of reach (the farthest: %s at %s, %.1f tiles to its edge, reach %g): walking into reach of each first (walk: false refuses instead)',
            far, #targets, worst.name, at(worst.x, worst.y), worst.distance, M.reach(p))
      else
        error(string.format('%s at %s is out of reach: %.1f tiles from the character at (%.1f,%.1f) to its edge, reach %g%s',
          t.name, at(t.x, t.y), t.distance, p.position.x, p.position.y, M.reach(p),
          a.walk == false and '' or string.format('; %.1f tiles is past the %d a call walks by default: %s walks there first', worst.distance, range,
            api.autowalk and api.autowalk.call_text('mine', a) or 'walk: true')), 0)
      end
    end
    -- A tile out of reach inside the enemy reach the map shows is not walked to (round1950a's check, as a tour's
    -- places), unless unsafe_goal: skipped, named.
    local mode = walk and not a.unsafe_goal and api.avoid_mode and api.avoid_mode(a.avoid_enemies) or nil
    if mode and api.goal_inside then
      local kept = {}
      for _, t in ipairs(targets) do
        local c = t.distance > M.reach(p) and try(function() return api.goal_inside(p, {x=t.x + 0.5, y=t.y + 0.5}, mode) end)
        if c then skipped[#skipped+1] = {position={x=t.x, y=t.y}, why=api.goal_text(t.name..' tile', {x=t.x, y=t.y}, c)..' (unsafe_goal: true walks there)'}
        else kept[#kept+1] = t end
      end
      if #kept == 0 then error(skipped[#skipped].why..(#skipped > 1 and string.format(' (and %d more refused)', #skipped - 1) or ''), 0) end
      targets = kept
    end
    local inv = p.get_main_inventory()
    for name, n in pairs(items) do
      assert(inv and inv.can_insert{name=name, count=n}, string.format('no room for %d %s in your inventory', n, name))
    end
    -- Nearest first from where the character stands, then each nearest the one before.
    local order, from = {}, {x=p.position.x, y=p.position.y}
    local left = {}
    for i, t in ipairs(targets) do left[i] = t end
    while #left > 0 do
      local bi, bd
      for i, t in ipairs(left) do
        local d = (t.x + 0.5 - from.x) ^ 2 + (t.y + 0.5 - from.y) ^ 2
        if not bd or d < bd then bi, bd = i, d end
      end
      local t = table.remove(left, bi)
      order[#order+1] = {x=t.x, y=t.y, name=t.name}
      from = {x=t.x + 0.5, y=t.y + 0.5}
    end
    local budget = api.integer(a.ticks, math.max(600, ticks + far * 600), 1, 36000, 'ticks')
    -- A mine action (the CLI's --wait follows it by that kind), held_before: what the character holds of the products
    -- now, so last.moved and last.inv say what it gained, as an entity's mining does.
    local held = {}
    for name in pairs(items) do held[name] = try(function() return p.get_item_count(name) end) or 0 end
    local action = {kind='mine', tiles=true, targets=order, index=1, walk=walk or nil, done={}, skipped=skipped, items={},
      held_before=held, until_tick=game.tick + budget, started=game.tick, avoid_mode=walk and api.avoid_mode and api.avoid_mode(a.avoid_enemies) or nil}
    local list, more = rows()
    return {until_tick=action.until_tick, tiles=list, more=more, count=#targets, items=items, seconds=ticks / 60,
      out_of_reach=far > 0 and far or nil, skipped=#skipped > 0 and skipped or nil, natural=natural > 0 and natural or nil, walking=walking}, action
  end
  -- One tick of the timed action: the outcome when it ends.
  function M.tick(p, action)
    while true do
      local t = action.targets[action.index]
      if not t then
        if #action.done > 0 then return 'target_mined' end
        return #action.skipped > 0 and 'failed' or 'nothing_to_do'
      end
      if action.mining then
        if game.tick < action.mining then return end
        action.mining = nil
        local row, why, item = M.mine(p, t.x, t.y)
        if row then
          action.done[#action.done+1] = row
          for _, pr in ipairs(row.items) do action.items[pr.name] = (action.items[pr.name] or 0) + pr.count end
        elseif why == 'inventory_full' then action.blocked_item = item; return 'inventory_full'
        else action.skipped[#action.skipped+1] = {position={x=t.x, y=t.y}, why=why} end
        action.index = action.index + 1
      elseif M.in_reach(p, t.x, t.y) then
        if action.nav then action.nav = nil; api.stop_walking(p) end
        local info = M.check(p, t.x, t.y)
        if info.why then
          action.skipped[#action.skipped+1] = {position={x=t.x, y=t.y}, why=info.why}
          action.index = action.index + 1
        else
          action.mining = game.tick + info.ticks
          return
        end
      elseif not action.walk then
        action.error = string.format('%s at %s is out of reach: %.1f tiles from the character to its edge, reach %g',
          t.name, at(t.x, t.y), M.distance(p, t.x, t.y), M.reach(p))
        return 'out_of_reach'
      else
        if not action.nav then
          -- (within 8.5 of its centre: mining reaches 10 to its edge, and a tile out in water needs the shore)
          action.nav = {position={x=t.x + 0.5, y=t.y + 0.5}, tolerance=math.max(1, M.reach(p) - 1.5), max_stalls=6, replans=0, stalled=0,
            last_position=p.position, avoid_mode=action.avoid_mode}
          if action.avoid_mode and api.avoid_start then api.avoid_start(p, action.nav, action.avoid_mode) end
          api.request_path(p, action.nav)
        end
        local outcome = api.navigate(p, action.nav)
        -- A leg round a nest ended: the next one starts (avoid.lua, as a tour's).
        if outcome and action.nav.foes and api.leg_done and api.leg_done(p, action.nav, outcome) then outcome = nil end
        if not outcome then return end
        action.nav = nil
        api.stop_walking(p)
        if not M.in_reach(p, t.x, t.y) then
          action.skipped[#action.skipped+1] = {position={x=t.x, y=t.y}, why=string.format('%s at %s: not reached (%s)', t.name, at(t.x, t.y), outcome)}
          action.unreached = (action.unreached or 0) + 1
          action.index = action.index + 1
        end
      end
    end
  end
  -- last when the action ends: what was mined, put back and skipped.
  function M.last(action, last)
    last.mined = #action.done
    last.tiles = #action.done > 0 and action.done or nil
    last.skipped = #action.skipped > 0 and action.skipped or nil
    last.left = #action.targets - action.index + 1 > 0 and #action.targets - action.index + 1 or nil
    last.items = next(action.items) and action.items or nil
    last.error = action.error
    if action.blocked_item then last.blocked_item = action.blocked_item end
  end
  return M
end
