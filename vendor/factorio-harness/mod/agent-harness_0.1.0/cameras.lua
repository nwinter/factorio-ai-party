-- Director cameras: a connected player whose client only exists to be
-- captured. The operator points it at a bot, a player or a position; every
-- tick its spectator view eases toward the target. Directors have no
-- character and are not agents (profiles and the turn clock ignore them).
return function(api)
  local M = {}
  local EASE, JUMP, MIN_ZOOM, MAX_ZOOM = 0.08, 200, 0.3, 4
  -- A map camera (args.map): Factorio's own chart, as a player sees it after pressing M (map colours, markers, nests,
  -- ore): the remote controller, where any zoom under chart_mode_cutoff renders the chart instead of the world. Cheap
  -- next to a zoomed-out world render. Any later camera call (or release) makes the client a spectator again.
  local MAP_MIN_ZOOM, MAP_MAX_ZOOM, CHART_CUTOFF = 0.01, 1, 2
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
  -- Only camera clients are directors: a person the operator makes a spectator or a god to look around (d17 16:40:
  -- Nick, spectating, was taken for a camera: forced back to spectator every 5 s, his map and tooltips hidden) is not,
  -- and one recorded as a director that way is forgotten.
  local function camera_name(p)
    for _, pattern in ipairs(DIRECTOR_NAMES) do
      if (p.name or ''):match(pattern) then return true end
    end
    return false
  end
  function M.director(index)
    if store()[index] ~= nil then return true end
    local p = game.get_player(index)
    if not (p and p.valid) then return directors()[index] == true end
    if camera_name(p) then return true end
    if directors()[index] then directors()[index] = nil end
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
  -- A camera client that joined a new Space Age world sits in the intro
  -- cutscene ("Press Tab to skip cutscene" at the bottom of its picture, cam1
  -- on 2026-10-12): end it the documented way first, then make it a spectator.
  local function make_director(p)
    directors()[p.index] = true
    hide_name(p)
    if p.controller_type == defines.controllers.remote then
      pcall(function() p.exit_remote_view() end)  -- back from a map camera (else set_controller below)
    end
    if defines.controllers.cutscene and p.controller_type == defines.controllers.cutscene then
      pcall(function() p.exit_cutscene() end)
    end
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
  -- A map camera's view on its spot. Every "Base map" shot (14:24) showed the
  -- camera's last subject: the remote view opens where the spectator stands
  -- (teleported onto that subject) and may stay centred on an entity. So the
  -- spectator goes to the spot first, the view is opened there, anything it
  -- centres on is dropped, a view still elsewhere is moved, and the zoom comes
  -- last (the tick re-centres one that drifts off the spot).
  local function on_spot(p, cam, surface)
    local here = p.position
    return p.surface and surface and p.surface.name == surface.name and here and distance(here, cam.position) <= 1
  end
  local function open_map(p, cam, surface)
    if p.controller_type ~= defines.controllers.remote then
      pcall(function() p.teleport({x=cam.position.x, y=cam.position.y}, surface) end)
      p.set_controller{type=defines.controllers.remote, position={x=cam.position.x, y=cam.position.y}, surface=surface, chart_mode_cutoff=CHART_CUTOFF}
    end
    pcall(function() if p.centered_on then p.centered_on = nil end end)
    if not on_spot(p, cam, surface) then pcall(function() p.teleport({x=cam.position.x, y=cam.position.y}, surface) end) end
    pcall(function() p.zoom = cam.zoom end)
  end
  -- The map's alert markers (big yellow triangles over the base in the site's terrain frame, 2026-10-13) are the
  -- camera player's own alerts drawn on the chart: a map shot turns that player's alerts off (disable_alert, per
  -- alert type) and the next camera call, or release, turns back on the ones it turned off (state.map_alerts).
  local function alerts_off(p)
    local st = api.state()
    st.map_alerts = st.map_alerts or {}
    local off = st.map_alerts[p.index] or {}
    for name, t in pairs(defines.alert_type or {}) do
      local ok, on = pcall(function() return p.is_alert_enabled(t) end)
      if ok and on and pcall(function() p.disable_alert(t) end) then off[#off+1] = name end
    end
    st.map_alerts[p.index] = off[1] and off or nil
  end
  local function alerts_back(p)
    local st = api.state()
    local off = st.map_alerts and st.map_alerts[p.index]
    if not off then return end
    for _, name in ipairs(off) do
      local t = defines.alert_type and defines.alert_type[name]
      if t ~= nil then pcall(function() p.enable_alert(t) end) end
    end
    st.map_alerts[p.index] = nil
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
    alerts_back(p)  -- after a map shot (a map shot turns them off again below)
    if args.release == true then
      local had = cams[p.index]
      cams[p.index] = nil
      return {ok=true, player=p.index, released=had ~= nil}
    end
    assert(not (api.controlled(p.index)), 'player ' .. p.index .. ' is an attached agent, not a director')
    if args.map == true then
      local pos = args.position
      assert(type(pos) == 'table' and type(pos.x) == 'number' and type(pos.y) == 'number', 'a map camera needs position {x,y}')
      local z = args.zoom or 0.1
      assert(type(z) == 'number' and z >= MAP_MIN_ZOOM and z <= MAP_MAX_ZOOM, string.format('map zoom must be %g..%g', MAP_MIN_ZOOM, MAP_MAX_ZOOM))
      local surface = args.surface and game.get_surface(args.surface) or p.surface
      assert(surface, 'no surface named ' .. tostring(args.surface))
      make_director(p)  -- a spectator first (a character never stays behind)
      local cam = {map=true, position={x=pos.x, y=pos.y}, surface=surface.name, zoom=z, smooth=false}
      cams[p.index] = cam
      open_map(p, cam, surface)
      clean_view(p)
      alerts_off(p)
      return {ok=true, player=p.index, camera=M.describe(p.index)}
    end
    local cam = {zoom=1, smooth=args.smooth ~= false}
    if args.follow ~= nil then
      assert(type(args.follow) == 'string', 'follow must be a bot or player name')
      assert(locate(args.follow), 'no bot or player named ' .. args.follow)
      cam.follow = args.follow
    else
      local pos = args.position
      assert(type(pos) == 'table' and type(pos.x) == 'number' and type(pos.y) == 'number', 'follow or position {x,y} is required')
      cam.position = {x=pos.x, y=pos.y}
      -- A fixed view on another planet or platform (default: where the director is).
      if args.surface ~= nil then
        assert(type(args.surface) == 'string' and game.get_surface(args.surface), 'no surface named ' .. tostring(args.surface))
        cam.surface = args.surface
      end
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
    local pos, surface = c.position, c.surface and game.get_surface(c.surface)
    if c.follow then pos, surface = locate(c.follow) end
    -- Space Age: the planet or platform surface the target is on.
    local p = game.get_player(index)
    surface = surface or (p and p.valid and p.surface)
    return {player=index, follow=c.follow, position=pos, surface=surface and surface.name or nil, zoom=c.zoom, smooth=c.smooth,
      map=c.map or nil}
  end
  function M.list()
    local out = {}
    for index in pairs(store()) do out[#out+1] = M.describe(index) end
    table.sort(out, function(a, b) return a.player < b.player end)
    return {ok=true, tick=game.tick, cameras=out}
  end
  function M.update(p, cam, now)
    local target, surface = cam.position, cam.surface and game.get_surface(cam.surface)
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
      elseif p.connected and cam.map then
        -- a map camera stays in the remote controller on its spot; a reconnect drops it out: back into the chart,
        -- and a view that drifted off the spot is put back
        local s = game.get_surface(cam.surface) or p.surface
        if p.controller_type ~= defines.controllers.remote then
          make_director(p)
          pcall(open_map, p, cam, s)
        elseif not on_spot(p, cam, s) then
          pcall(open_map, p, cam, s)
        end
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
        local cam = store()[p.index]
        if M.director(p.index) and not (cam and cam.map) then make_director(p) end
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
