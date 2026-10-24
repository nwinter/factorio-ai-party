-- What agents are doing, drawn in the game for the director camera clients
-- only (Nick 14:40: "it would be great to visualize even more of what agents
-- are doing"; viewers asked why mining has no animation). LuaRendering with
-- players = the connected camera players (never an agent's player), every
-- object with a short time_to_live; flying text through each camera player's
-- create_local_flying_text. With no camera client connected nothing is drawn.
-- The one thing others could see: the game's own mining particles at a mined
-- target (visual only, as when a player mines).
--   mining: an arc filling over the hand-mining time, the product's icon, particles
--   hand crafting: the queue's next recipes above the head, the first with its progress
--   move_to: a faint line along the planned route to the goal
--   item moves (transfer, collect, feed, rearm, refuel): "+50 [item=iron-plate]" at the target
--   building, removing, configuring, repairing: a brief ring on the target
-- Cost: the tick does nothing between beats (every 10 ticks: mining; every
-- 30: crafting and routes), only for agents doing that, only with a camera
-- connected; brief rings and texts share a budget of 30 a second.
return function(api)
  local M = {}
  local BEAT, SLOW, BUDGET, MAX_SEGMENTS = 10, 30, 30, 24
  local WORK = {build=true, deconstruct=true, cancel_deconstruction=true, remove_ghosts=true, configure=true, rotate=true, repair=true,
    flush=true, revive_ghost=true, place_ghosts=true, paste=true, blueprint_place=true, construct=true, circuit_set=true, circuit=true}
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function store()
    local s = api.state()
    s.visuals = s.visuals or {slots={}, budget={second=-1, n=0}}
    return s.visuals
  end
  local function colour(index, alpha)
    local c = api.color(index) or {r=1, g=1, b=1}
    return {r=c.r * (alpha or 1), g=c.g * (alpha or 1), b=c.b * (alpha or 1), a=alpha or 1}
  end
  -- An agent's replaceable drawing (its mining arc, crafting queue, route).
  local function drop(index, kind)
    local slots = store().slots[index]
    local ids = slots and slots[kind]
    if not ids then return end
    for _, id in ipairs(ids) do
      local o = rendering.get_object_by_id(id)
      if o and o.valid then o.destroy() end
    end
    slots[kind] = nil
    if not next(slots) then store().slots[index] = nil end
  end
  local function slot(index, kind)
    drop(index, kind)
    local s = store()
    s.slots[index] = s.slots[index] or {}
    local ids = {}
    s.slots[index][kind] = ids
    return function(o) if o then ids[#ids+1] = o.id end end
  end
  -- Brief objects: at most BUDGET a second.
  local function spend(n)
    local b = store().budget
    local second = math.floor(game.tick / 60)
    if b.second ~= second then b.second, b.n = second, 0 end
    if b.n + n > BUDGET then return false end
    b.n = b.n + n
    return true
  end

  local function sprite_ok(path) return try(function() return helpers.is_valid_sprite_path(path) end) ~= false end
  local PARTICLE_AT = {{-0.3, -0.2}, {0.25, -0.1}, {-0.1, 0.25}, {0.3, 0.2}}
  local function mining(index, p, action, cams, tick)
    local e = action.entity
    if not (e and e.valid) then drop(index, 'mine'); return end
    local progress
    if action.done_tick and action.started then
      progress = (tick - action.started) / math.max(1, action.done_tick - action.started)
    elseif action.cycle and action.next_mine then
      progress = 1 - (action.next_mine - tick) / action.cycle
    end
    progress = math.max(0.02, math.min(1, progress or 0.5))
    local keep = slot(index, 'mine')
    local col = colour(index)
    keep(try(function() return rendering.draw_arc{color=col, min_radius=0.55, max_radius=0.75, start_angle=-math.pi / 2,
      angle=2 * math.pi * progress, target=e, surface=e.surface, players=cams, time_to_live=BEAT + 4} end))
    local product = action.products and action.products[1]
    if product and sprite_ok('item/' .. product) then
      keep(try(function() return rendering.draw_sprite{sprite='item/' .. product, target={entity=e, offset={0, -1.2}}, surface=e.surface,
        players=cams, x_scale=0.6, y_scale=0.6, time_to_live=BEAT + 4} end))
    end
    -- The game's own particles for what is mined, two every 20 ticks.
    if tick % 20 == 0 then
      local name = try(function() return e.prototype.mineable_properties.mining_particle end)
      if name then
        for k = 1, 2 do
          local d = PARTICLE_AT[(math.floor(tick / 20) * 2 + k) % 4 + 1]
          pcall(function() e.surface.create_particle{name=name, position={x=e.position.x + d[1], y=e.position.y + d[2]},
            movement={d[1] * 0.08, d[2] * 0.08}, height=0.3, vertical_speed=0.06, frame_speed=1} end)
        end
      end
    end
  end
  local function crafting(index, p, c, cams)
    local queue = try(function() return p.crafting_queue end)
    if not (queue and #queue > 0) then drop(index, 'craft'); return end
    local keep = slot(index, 'craft')
    local progress = try(function() return p.crafting_queue_progress end) or 0
    local col = colour(index)
    for i = 1, math.min(3, #queue) do
      local q = queue[i]
      local x = -0.7 + (i - 1) * 0.7
      if sprite_ok('recipe/' .. q.recipe) then
        keep(try(function() return rendering.draw_sprite{sprite='recipe/' .. q.recipe, target={entity=c, offset={x, -2.7}}, surface=c.surface,
          players=cams, x_scale=0.45, y_scale=0.45, time_to_live=SLOW + 4} end))
      end
      if (q.count or 1) > 1 then
        keep(try(function() return rendering.draw_text{text='x' .. q.count, target={entity=c, offset={x + 0.2, -2.55}}, surface=c.surface,
          players=cams, color={r=1, g=1, b=1}, scale=0.7, time_to_live=SLOW + 4} end))
      end
      if i == 1 then
        keep(try(function() return rendering.draw_arc{color=col, min_radius=0.3, max_radius=0.36, start_angle=-math.pi / 2,
          angle=2 * math.pi * math.max(0.02, math.min(1, progress)), target={entity=c, offset={x, -2.7}}, surface=c.surface,
          players=cams, time_to_live=SLOW + 4} end))
      end
    end
  end
  local function route(index, c, action, cams)
    local goal = action.position
    if not goal then drop(index, 'path'); return end
    local nav = action.nav or action
    local points = {}
    local wps = nav.waypoints
    if wps then
      for k = nav.waypoint or 1, #wps do
        local w = wps[k]
        points[#points+1] = w.position or w
        if #points >= MAX_SEGMENTS - 1 then break end
      end
    end
    points[#points+1] = goal
    local keep = slot(index, 'path')
    local col = colour(index, 0.35)
    local from = c
    for _, pt in ipairs(points) do
      keep(try(function() return rendering.draw_line{color=col, width=1.5, from=from, to={x=pt.x, y=pt.y}, surface=c.surface,
        players=cams, time_to_live=SLOW + 4, dash_length=0.5, gap_length=0.5} end))
      from = {x=pt.x, y=pt.y}
    end
    keep(try(function() return rendering.draw_circle{color=col, radius=0.4, width=1.5, filled=false, target={x=goal.x, y=goal.y},
      surface=c.surface, players=cams, time_to_live=SLOW + 4} end))
    -- Said at the goal, so the route reads apart from a highlight's line to what the agent acts on.
    keep(try(function() return rendering.draw_text{text='walking here', target={x=goal.x, y=goal.y - 0.6}, surface=c.surface,
      players=cams, color=colour(index, 0.6), scale=0.9, alignment='center', vertical_alignment='bottom', time_to_live=SLOW + 4,
      use_rich_text=false} end))
  end

  function M.tick(tick)
    if tick % BEAT ~= 0 then return end
    local cams = api.cameras()
    local s = store()
    if #cams == 0 then
      for index in pairs(s.slots) do for kind in pairs(s.slots[index] or {}) do drop(index, kind) end end
      return
    end
    local slow = tick % SLOW == 0
    for _, index in ipairs(api.agents()) do
      local p = api.lookup(index)
      local c = p and p.valid and try(function() return p.character end)
      local action = api.active(index)
      if c and c.valid then
        if action and action.kind == 'mine' then mining(index, p, action, cams, tick)
        elseif s.slots[index] and s.slots[index].mine then drop(index, 'mine') end
        if slow then
          crafting(index, p, c, cams)
          if action and action.kind == 'move_to' then route(index, c, action, cams)
          elseif s.slots[index] and s.slots[index].path then drop(index, 'path') end
        end
      elseif s.slots[index] then
        for kind in pairs(s.slots[index]) do drop(index, kind) end
      end
    end
  end

  -- Items moved by hand (transfer_one): the text the agent's own client
  -- would show, at the target, in the agent's colour.
  function M.moved(p, position, surface, text)
    local cams = api.cameras()
    if #cams == 0 or not spend(1) then return end
    local col = colour(p.index)
    for _, index in ipairs(cams) do
      local cam = game.get_player(index)
      if cam and cam.valid then
        pcall(function() cam.create_local_flying_text{text=text, position=position, surface=surface, color=col, time_to_live=120} end)
      end
    end
  end

  -- A request that builds, removes, configures or repairs: a brief ring on its target.
  function M.worked(p, action, args)
    if not WORK[action] or type(args) ~= 'table' or args.platform ~= nil or args.surface ~= nil then return end
    local pos = args.position
    if type(args.area) == 'table' and type(args.area.left_top) == 'table' and type(args.area.right_bottom) == 'table' then
      local lt, rb = args.area.left_top, args.area.right_bottom
      if type(lt.x) == 'number' and type(rb.x) == 'number' then pos = {x=(lt.x + rb.x) / 2, y=(lt.y + rb.y) / 2} end
    end
    if not (type(pos) == 'table' and type(pos.x) == 'number' and type(pos.y) == 'number') then return end
    local cams = api.cameras()
    if #cams == 0 or not spend(1) then return end
    local surface = try(function() return p.surface end)
    if not surface then return end
    pcall(function() rendering.draw_circle{color=colour(p.index), radius=1, width=2, filled=false, target={x=pos.x, y=pos.y},
      surface=surface, players=cams, time_to_live=60} end)
  end
  return M
end
