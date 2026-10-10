-- Director cameras: a connected player whose client only exists to be
-- captured. The operator points it at a bot, a player or a position; every
-- tick its spectator view eases toward the target. Directors have no
-- character and are not agents (profiles and the turn clock ignore them).
return function(api)
  local M = {}
  local EASE, JUMP, MIN_ZOOM, MAX_ZOOM = 0.08, 200, 0.3, 2
  local function store()
    local s = api.state()
    s.cameras = s.cameras or {}
    return s.cameras
  end
  function M.director(index)
    local c = store()[index]
    return c ~= nil
  end
  local function distance(a, b) return ((a.x-b.x)^2 + (a.y-b.y)^2)^0.5 end
  -- Where a follow target is: a bot (alive or where it died) or a player.
  local function locate(name)
    local b = api.bot(name)
    if b then
      local c = b.character
      if c and c.valid then return c.position, c.surface end
      return b.position, game.get_surface(b.surface or 'nauvis')
    end
    local p = game.get_player(name)
    if p and p.valid then
      local c = p.character
      if c and c.valid then return c.position, c.surface end
      return p.position, p.surface
    end
  end
  local function director(index)
    assert(type(index) == 'number' and index == math.floor(index) and index >= 1, 'player must be a player index')
    local p = game.get_player(index)
    assert(p and p.valid, 'player does not exist')
    return p
  end
  function M.set(args)
    if type(args) == 'string' then args = helpers.json_to_table(args) end
    assert(type(args) == 'table', 'camera takes a JSON object')
    local p = director(args.player)
    local cams = store()
    if args.release == true then
      local had = cams[p.index]
      cams[p.index] = nil
      return {ok=true, player=p.index, released=had ~= nil}
    end
    assert(not (api.controlled(p.index)), 'player ' .. p.index .. ' is an attached agent, not a director')
    local cam = {zoom=1, smooth=args.smooth ~= false}
    if args.follow ~= nil then
      assert(type(args.follow) == 'string', 'follow must be a bot or player name')
      assert(locate(args.follow), 'no bot or player named ' .. args.follow)
      cam.follow = args.follow
    else
      local pos = args.position
      assert(type(pos) == 'table' and type(pos.x) == 'number' and type(pos.y) == 'number', 'follow or position {x,y} is required')
      cam.position = {x=pos.x, y=pos.y}
    end
    if args.zoom ~= nil then
      assert(type(args.zoom) == 'number' and args.zoom >= MIN_ZOOM and args.zoom <= MAX_ZOOM, 'zoom must be 0.3..2')
      cam.zoom = args.zoom
    end
    local old = cams[p.index]
    cam.view_zoom = old and old.view_zoom or nil
    -- Spectator once: the director's own character would otherwise stand in
    -- the world (and on stream) as a lifeless extra.
    if p.controller_type ~= defines.controllers.spectator then
      local c = p.character
      p.set_controller{type=defines.controllers.spectator}
      if c and c.valid then c.destroy() end
    end
    cams[p.index] = cam
    M.update(p, cam, true)
    return {ok=true, player=p.index, camera=M.describe(p.index)}
  end
  function M.describe(index)
    local c = store()[index]
    if not c then return nil end
    local pos = c.position
    if c.follow then pos = locate(c.follow) end
    return {player=index, follow=c.follow, position=pos, zoom=c.zoom, smooth=c.smooth}
  end
  function M.list()
    local out = {}
    for index in pairs(store()) do out[#out+1] = M.describe(index) end
    table.sort(out, function(a, b) return a.player < b.player end)
    return {ok=true, tick=game.tick, cameras=out}
  end
  function M.update(p, cam, now)
    local target, surface = cam.position, nil
    if cam.follow then target, surface = locate(cam.follow) end
    if not target then return end
    surface = surface or p.surface
    local here = p.position
    if surface ~= p.surface or not cam.smooth or now and not cam.view_zoom or distance(here, target) > JUMP then
      p.teleport(target, surface)
    elseif distance(here, target) > 0.02 then
      p.teleport({x=here.x + (target.x - here.x) * EASE, y=here.y + (target.y - here.y) * EASE})
    end
    local z = cam.view_zoom or cam.zoom
    if cam.smooth and math.abs(z - cam.zoom) > 0.002 then z = z + (cam.zoom - z) * EASE else z = cam.zoom end
    if z ~= cam.view_zoom then
      cam.view_zoom = z
      pcall(function() p.zoom = z end)
    end
  end
  function M.tick()
    for index, cam in pairs(store()) do
      local p = game.get_player(index)
      if not (p and p.valid) then store()[index] = nil
      elseif p.connected and p.controller_type == defines.controllers.spectator then M.update(p, cam, false) end
    end
  end
  return M
end
