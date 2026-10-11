-- Director cameras: a connected player whose client only exists to be
-- captured. The operator points it at a bot, a player or a position; every
-- tick its spectator view eases toward the target. Directors have no
-- character and are not agents (profiles and the turn clock ignore them).
return function(api)
  local M = {}
  local EASE, JUMP, MIN_ZOOM, MAX_ZOOM = 0.08, 200, 0.3, 4
  local function store()
    local s = api.state()
    s.cameras = s.cameras or {}
    return s.cameras
  end
  -- Once a camera, always a director (release only stops following).
  local function directors()
    local s = api.state()
    s.directors = s.directors or {}
    return s.directors
  end
  -- Camera clients are named pog-cam1.. or pog-director (tools/win/start-client.ps1
  -- -PlayerName); they count as directors before their first camera call too.
  local DIRECTOR_NAMES = {'^pog%-cam%d*$', '^pog%-director%d*$'}
  function M.director(index)
    if store()[index] ~= nil or directors()[index] then return true end
    local p = game.get_player(index)
    if not (p and p.valid) then return false end
    if p.controller_type == defines.controllers.spectator then return true end
    for _, pattern in ipairs(DIRECTOR_NAMES) do
      if (p.name or ''):match(pattern) then return true end
    end
    return false
  end
  -- A clean picture: no GUI but entity info (alt-mode), as OBS captures it.
  local HIDDEN_GUI = {'show_controller_gui', 'show_minimap', 'show_research_info', 'show_side_menu', 'show_alert_gui',
    'show_quickbar', 'show_shortcut_bar', 'show_crafting_queue', 'show_tool_bar', 'show_hotkey_suggestions',
    'show_map_view_options', 'show_surface_list', 'show_entity_tooltip', 'show_rail_block_visualisation'}
  local function clean_view(p)
    local view = p.game_view_settings
    for _, key in ipairs(HIDDEN_GUI) do pcall(function() view[key] = false end) end
    pcall(function() view.show_entity_info = true end)
    pcall(function() p.game_view_settings = view end)
  end
  -- A director's name must not float over the bot it follows on stream:
  -- show_on_map=false hides its label from the other clients. Set for every
  -- connected director (also camera clients with no camera yet) on the 5 s
  -- recheck, so a client that joins or reconnects later is covered too.
  local function hide_name(p)
    pcall(function() if p.show_on_map ~= false then p.show_on_map = false end end)
  end
  -- Spectator without a character; done again if the player came back with one
  -- (a reconnect or respawn), since a director is never an agent.
  local function make_director(p)
    directors()[p.index] = true
    hide_name(p)
    if p.controller_type ~= defines.controllers.spectator then
      local c = p.character
      p.set_controller{type=defines.controllers.spectator}
      if c and c.valid then c.destroy() end
    end
    clean_view(p)
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
      assert(type(args.zoom) == 'number' and args.zoom >= MIN_ZOOM and args.zoom <= MAX_ZOOM, string.format('zoom must be %g..%g', MIN_ZOOM, MAX_ZOOM))
      cam.zoom = args.zoom
    end
    local old = cams[p.index]
    cam.view_zoom = old and old.view_zoom or nil
    -- Spectator once: the director's own character would otherwise stand in
    -- the world (and on stream) as a lifeless extra.
    make_director(p)
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
  local RECHECK_TICKS = 300
  function M.tick()
    local recheck = game.tick % RECHECK_TICKS == 0
    for index, cam in pairs(store()) do
      local p = game.get_player(index)
      if not (p and p.valid) then store()[index] = nil
      elseif p.connected then
        -- A reconnect can bring back a character or reset the view settings.
        if recheck or p.controller_type ~= defines.controllers.spectator then make_director(p) end
        M.update(p, cam, false)
      end
    end
    -- Every connected director, with a camera or not (a camera client before its
    -- first camera call, or released), is a characterless spectator with no
    -- label: a character would stand on stream with its name over its head.
    if recheck then
      for _, p in pairs(game.connected_players or {}) do
        if M.director(p.index) then make_director(p) end
      end
    end
  end
  -- Players who see the game chat: everyone connected but directors.
  function M.audience()
    local out = {}
    for _, p in pairs(game.connected_players) do
      if not M.director(p.index) then out[#out+1] = p end
    end
    return out
  end
  return M
end
