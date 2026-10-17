-- launchwatch (C11, Luna 15:21: Wren left Gleba before a 100-magazine pod): a launch that waits for its rocket while the
-- platform it is for leaves, or is due to leave by a time wait, the planet the silo is on. Checked on the copy of world
-- n (2.0.77): a platform with a rocket in flight to it does not leave until the pod lands (Swift, sent on at once after a
-- launch to it, stayed at Nauvis about 37 s, until the pod landed, then left with the cargo aboard; with no rocket in
-- flight it left at once), so a pod in flight never misses its platform; the risk is a rocket not launched yet. Every
-- second: each agent's waiting launch for a platform (load_silo with launch waiting for its rocket, a walking load_silo
-- holding at the silo, launch {wait_ready}); a departure while it waits, and a time wait ending within 5 minutes before
-- the rocket is ready, are told once in team.alerts to the agent waiting and to those the platform's alerts go to.
return function(api)
  local M = {}
  local SOON, KEEP, MAX = 18000, 36000, 32
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function store()
    local s = api.state()
    s.launch_watch = s.launch_watch or {seen={}, events={}, seq=0}
    return s.launch_watch
  end
  local function secs(t)
    local s = math.max(0, math.floor(t / 60 + 0.5))
    return s >= 60 and string.format('%dm%02ds', math.floor(s / 60), s % 60) or s .. 's'
  end
  -- The launches waiting now: {index, platform, silo}.
  function M.waiting()
    local out = {}
    for index, act in pairs(api.state().active or {}) do
      local plat, silo, since
      if act.kind == 'feed' and act.handler == 'load_silo' and act.await_silo and act.await_silo.launch then
        plat, silo, since = act.await_silo.platform, act.await_silo.silo, act.await_silo.since
      elseif act.kind == 'gather' and act.op == 'load_silo' and act.load and act.load.launch then
        plat, silo, since = act.load.platform, act.silo, act.started_tick
      elseif act.kind == 'wait_until' and act.then_launch and act.then_launch.platform then
        plat, since = act.then_launch.platform, act.start_tick
        local pos = act.condition and act.condition.position
        local surface = api.surface_of and api.surface_of(index)
        silo = pos and surface and try(function() return surface.find_entities_filtered{type='rocket-silo', position=pos, radius=2, limit=1}[1] end)
      end
      if type(plat) == 'string' and silo and silo.valid then out[#out+1] = {index=index, platform=plat, silo=silo, since=since or game.tick} end
    end
    return out
  end
  local function platform(force, name)
    for _, pl in pairs(try(function() return force.platforms end) or {}) do if pl.valid and pl.name == name then return pl end end
  end
  -- When a time wait at the current stop ends (every wait a time wait), from the arrival tick space.lua keeps.
  local function due(pl, here)
    local sch = try(function() return pl.schedule end)
    local rec = sch and sch.records and sch.records[sch.current or 1]
    if not (rec and rec.station == here and rec.wait_conditions and #rec.wait_conditions > 0) then return nil end
    local ticks = 0
    for _, w in ipairs(rec.wait_conditions) do
      if w.type ~= 'time' or not w.ticks then return nil end
      ticks = math.max(ticks, w.ticks)
    end
    local arrived = try(function() return api.state().platform_stops[pl.index] end)
    if not (arrived and arrived.at == here and arrived.tick) then return nil end
    return arrived.tick + ticks
  end
  local function push(st, text, index, plat)
    st.seq = st.seq + 1
    st.events[#st.events+1] = {id=st.seq, tick=game.tick, text=text, index=index, platform=plat}
    while #st.events > MAX do table.remove(st.events, 1) end
  end
  function M.tick()
    local st = store()
    local now = {}
    for _, w in ipairs(M.waiting()) do
      local pl = platform(w.silo.force, w.platform)
      local planet = try(function() return w.silo.surface.planet and w.silo.surface.planet.name end) or w.silo.surface.name
      if pl then
        local here = try(function() return pl.space_location and pl.space_location.name end)
        local key = w.index .. '|' .. w.platform
        now[key] = true
        local was = st.seen[key]
        local at = here == planet
        local rk = api.rocket and try(function() return api.rocket(w.silo) end)
        local rtext = rk and rk.rocket or 'the rocket is not ready'
        local who = api.name_of and api.name_of(w.index) or ('agent ' .. w.index)
        -- a leg from this planet begun since the launch began to wait (freight.lua's legs; a departure within the second
        -- the wait began is caught too)
        local left
        for _, sg in ipairs(api.segments and try(function() return api.segments(pl) end) or {}) do
          if sg.kind == 'leg' and sg.from == planet and sg.start and sg.start >= w.since then left = sg.start end
        end
        if left and not (was and was.left_told == left) then
          was = was or {}; was.left_told = left
          push(st, string.format('platform %s left %s while %s\'s launch to it waits at the rocket silo (%g,%g) on %s (%s): the game sends a rocket only to a platform stopped over the planet; a rocket already in flight to one holds it there until its pod lands',
            w.platform, planet, who, w.silo.position.x, w.silo.position.y, planet, rtext), w.index, w.platform)
          st.seen[key] = was
        end
        local d = at and due(pl, planet)
        if d and d > game.tick and d - game.tick <= SOON and not (was and was.due_told == d) then
          push(st, string.format('platform %s leaves %s in about %s by its schedule (a time wait), while %s\'s launch to it waits at the rocket silo (%g,%g): %s',
            w.platform, planet, secs(d - game.tick), who, w.silo.position.x, w.silo.position.y, rtext), w.index, w.platform)
          st.seen[key] = {at=at, due_told=d, left_told=was and was.left_told or nil}
        else
          st.seen[key] = {at=at, due_told=was and was.due_told or nil, left_told=was and was.left_told or nil}
        end
      end
    end
    for key in pairs(st.seen) do if not now[key] then st.seen[key] = nil end end
    for i = #st.events, 1, -1 do if game.tick - st.events[i].tick > KEEP then table.remove(st.events, i) end end
  end
  -- team.alerts: each event once to the agent waiting and to those the platform's alerts go to.
  function M.lines(p, h)
    local st = api.state().launch_watch
    if not st or #st.events == 0 then return nil end
    local last = h.launch_watch_seen or 0
    local out = {}
    for _, e in ipairs(st.events) do
      if e.id > last and (e.index == p.index or (api.hears and api.hears(p, e.platform))) then out[#out+1] = 'launch: ' .. e.text end
    end
    h.launch_watch_seen = st.seq
    return #out > 0 and out or nil
  end
  return M
end
