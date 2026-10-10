-- Bots: script-driven characters (no LuaPlayer, no client) that play by the
-- same rules as a player's character: real walking/mining/crafting time,
-- reach, inventory, no free items. Each bot gets an index above any player
-- index, so active actions, queues and clocks key them like players. Handlers
-- see a proxy exposing the LuaPlayer/LuaControl surface they use, backed by
-- the character entity (LuaControl); LuaPlayer-only parts (cursor building)
-- go through direct placement.
return function(api)
  local M = {}
  local BASE = 1000000
  local RESPAWN_TICKS = 600
  local FALLBACK_ITEMS = {['iron-plate']=8, wood=1, pistol=1, ['firearm-magazine']=10, ['burner-mining-drill']=1, ['stone-furnace']=1}
  M.BASE = BASE
  local function bots()
    local s = api.state()
    s.bots = s.bots or {by_name={}, by_index={}, next=1}
    return s.bots
  end
  function M.is_index(index) return type(index) == 'number' and index > BASE end
  function M.is(p) return type(p) == 'table' and rawget(p, '__bot') ~= nil end
  function M.record(index) return bots().by_index[index] end
  function M.named(name) return bots().by_name[name] end
  function M.index_of(name)
    assert(type(name) == 'string', 'bot must be a string')
    local b = bots().by_name[name]
    assert(b, 'no bot named ' .. name)
    return b.index
  end
  function M.list()
    local out = {}
    for _, b in pairs(bots().by_index) do out[#out+1] = b end
    table.sort(out, function(x, y) return x.index < y.index end)
    return out
  end
  local function alive(b) return b.character ~= nil and b.character.valid end
  M.alive = alive
  local function force_of(b) return game.forces[b.force or 'player'] end
  local function surface_of(b) return game.get_surface(b.surface or 'nauvis') or game.get_surface(1) end
  local function colour(b)
    local pr = api.profile and api.profile(b.index)
    return pr and pr.rgb or {r=1, g=0.63, b=0.26}
  end
  -- What a proxy answers itself; everything else goes to the character.
  local OWN = {
    index=function(b) return b.index end,
    name=function(b) return b.name end,
    valid=function(b) return bots().by_index[b.index] == b end,
    connected=function() return true end,
    controller_type=function() return defines.controllers.character end,
    physical_controller_type=function() return defines.controllers.character end,
    cheat_mode=function() return false end,
    permission_group=function() return nil end,
    cursor_ghost=function() return nil end,
    character=function(b) return alive(b) and b.character or nil end,
    driving=function(b) return alive(b) and b.character.driving or false end,
    position=function(b) if alive(b) then return b.character.position end return b.position end,
    surface=function(b) if alive(b) then return b.character.surface end return surface_of(b) end,
    force=function(b) if alive(b) then return b.character.force end return force_of(b) end,
    chat_color=colour, color=colour,
    -- Nobody looks through a bot's screen.
    create_local_flying_text=function() return function() end end,
    print=function() return function() end end,
  }
  function M.proxy(b)
    return setmetatable({__bot=b.name}, {
      __index=function(_, k)
        local own = OWN[k]
        if own then return own(b) end
        assert(alive(b), 'bot ' .. b.name .. ' is dead')
        return b.character[k]
      end,
      __newindex=function(_, k, v) if alive(b) then b.character[k] = v end end})
  end
  -- A controllable bot: alive, like player() for a player.
  function M.actor(index)
    local b = bots().by_index[index]
    assert(b, 'bot does not exist')
    if not alive(b) then
      error(string.format('bot %s is dead; it respawns at tick %s (status reports dead_until_tick)', b.name, tostring(b.dead_until_tick)), 0)
    end
    assert(not b.character.driving, 'the character is in a vehicle; vehicles are unsupported')
    return M.proxy(b)
  end
  -- The proxy for status and cleanup, dead or alive.
  function M.lookup(index)
    local b = bots().by_index[index]
    return b and M.proxy(b) or nil
  end
  local function items(kind)
    local ok, list = pcall(function()
      if remote.interfaces.freeplay and remote.interfaces.freeplay['get_' .. kind .. '_items'] then
        return remote.call('freeplay', 'get_' .. kind .. '_items')
      end
    end)
    if ok and type(list) == 'table' then return list end
    return kind == 'created' and FALLBACK_ITEMS or {}
  end
  -- A player's character keeps the chunks around it charted and visible; a
  -- character without a player does not, so do it for bots: the chunks within
  -- the 32-tile visibility limit, refreshed every second (staggered by bot).
  local SIGHT, SIGHT_TICKS = 32, 60
  local function look(c)
    local pos = c.position
    c.force.chart(c.surface, {{pos.x - SIGHT, pos.y - SIGHT}, {pos.x + SIGHT, pos.y + SIGHT}})
  end
  -- Each bot has its own spot on rings around the spawn point (12 per ring,
  -- 4 tiles out, then 3 tiles further per ring), so a crowd never stacks up.
  local RING, RING_SIZE, RING_STEP = 4, 12, 3
  function M.slot(origin, slot)
    local ring = math.floor((slot - 1) / RING_SIZE)
    local angle = ((slot - 1) % RING_SIZE) * 2 * math.pi / RING_SIZE + ring * math.pi / RING_SIZE
    local r = RING + ring * RING_STEP
    return {x=origin.x + r * math.cos(angle), y=origin.y + r * math.sin(angle)}
  end
  local function spawn(b, kind)
    local force, surface = force_of(b), surface_of(b)
    local spot = M.slot(force.get_spawn_position(surface), b.slot or 1)
    local pos = surface.find_non_colliding_position('character', spot, 32, 0.5) or spot
    local c = surface.create_entity{name='character', position=pos, force=force}
    assert(c, 'could not create the character')
    for name, count in pairs(items(kind)) do
      if count > 0 then c.insert{name=name, count=count} end
    end
    b.character = c; b.position = c.position; b.dead_until_tick = nil
    look(c)
    if api.on_spawn then api.on_spawn(b) end
    return c
  end
  function M.create(name)
    assert(type(name) == 'string' and #name <= 16 and name:match('^[a-z][a-z0-9_-]*$'), 'name must match [a-z][a-z0-9_-]{0,15}')
    local all = bots()
    assert(not all.by_name[name], 'a bot named ' .. name .. ' already exists')
    for _, p in pairs(game.players) do assert(p.name ~= name, 'a player is named ' .. name) end
    local b = {name=name, index=BASE+all.next, slot=all.next, force='player', surface='nauvis', created_tick=game.tick}
    spawn(b, 'created')
    all.next = all.next + 1
    all.by_name[name] = b; all.by_index[b.index] = b
    return {name=name, unit_number=b.character.unit_number, position=b.character.position, index=b.index}
  end
  -- The character dies where it stands; its corpse keeps the items.
  function M.remove(name)
    local all = bots()
    local b = all.by_name[name]
    assert(b, 'no bot named ' .. tostring(name))
    if api.stop then api.stop(b.index, 'removed') end
    local died = false
    if alive(b) then
      local c = b.character
      b.character = nil
      died = c.die() and true or false
      if c.valid then c.destroy() end
    end
    all.by_name[name] = nil; all.by_index[b.index] = nil
    return {name=name, removed=true, died=died}
  end
  -- Deaths and respawns, like a player's: the normal respawn delay, then a
  -- fresh character at the spawn point with what a respawning player gets.
  function M.tick(tick)
    for _, b in pairs(bots().by_index) do
      if b.character and b.character.valid then
        if tick % 30 == 0 then b.position = b.character.position end
        if (tick + b.index) % SIGHT_TICKS == 0 then look(b.character) end
      elseif not b.dead_until_tick then
        b.character = nil
        b.dead_until_tick = tick + RESPAWN_TICKS
        b.deaths = (b.deaths or 0) + 1
        if api.stop then api.stop(b.index, 'died') end
      elseif tick >= b.dead_until_tick then
        spawn(b, 'respawn')
      end
    end
  end
  function M.status(index, out)
    local b = bots().by_index[index]
    if not b or type(out) ~= 'table' then return out end
    out.bot = true; out.name = b.name; out.dead_until_tick = b.dead_until_tick; out.deaths = b.deaths
    return out
  end
  -- Mining through the engine, except a character corpse: the engine's
  -- corpse pickup assumes a player and crashes the game for a playerless
  -- character. Taking a corpse moves its items to the inventory (what fits);
  -- the corpse goes once it is empty, as for a player.
  function M.mine(p, e)
    if not (M.is(p) and e.type == 'character-corpse') then return p.mine_entity(e, false) end
    local from = e.get_inventory(defines.inventory.character_corpse)
    local to = p.get_main_inventory()
    for i = 1, #from do
      local stack = from[i]
      if stack.valid_for_read then
        local moved = to.insert(stack)
        if moved >= stack.count then stack.clear() elseif moved > 0 then stack.count = stack.count - moved end
      end
    end
    if not from.is_empty() then return false end
    e.destroy()
    return true
  end
  -- Tiles without a cursor: the item's placement condition against the tile
  -- underneath (landfill only on water), one item per tile placed.
  function M.place_tiles(p, a, stack, pos, size)
    local result = stack.prototype.place_as_tile_result
    local tile = result.result
    local blocked_by = result.condition and result.condition.layers or {}
    local surface, inv = p.surface, p.get_main_inventory()
    local quality = a.quality or 'normal'
    local have = inv.get_item_count{name=a.item, quality=quality}
    local x0, y0 = math.floor(pos.x - (size - 1) / 2), math.floor(pos.y - (size - 1) / 2)
    local tiles, hidden = {}, {}
    for dx = 0, size - 1 do
      for dy = 0, size - 1 do
        if #tiles < have then
          local here = surface.get_tile(x0 + dx, y0 + dy)
          local ok = here.name ~= tile.name
          for layer in pairs(blocked_by) do
            if ok and here.prototype.collision_mask.layers[layer] then ok = false end
          end
          if ok then
            tiles[#tiles+1] = {name=tile.name, position={x0 + dx, y0 + dy}}
            if tile.mineable_properties and tile.mineable_properties.minable then hidden[#hidden+1] = {pos={x0 + dx, y0 + dy}, name=here.name} end
          end
        end
      end
    end
    assert(#tiles > 0, 'no tile was placed (blocked or already there)')
    surface.set_tiles(tiles, true, 'abort_on_collision', true, true)
    local placed = 0
    for _, t in ipairs(tiles) do
      if surface.get_tile(t.position[1], t.position[2]).name == tile.name then placed = placed + 1 end
    end
    for _, h in ipairs(hidden) do pcall(surface.set_hidden_tile, h.pos, h.name) end
    assert(placed > 0, 'no tile was placed (blocked or already there)')
    inv.remove{name=a.item, quality=quality, count=placed}
    return {consumed=placed, tile=tile.name, position={x=math.floor(pos.x)+0.5, y=math.floor(pos.y)+0.5}}
  end
  return M
end
