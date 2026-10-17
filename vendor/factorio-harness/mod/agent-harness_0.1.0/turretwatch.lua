-- A turret ghost's targeting kept through its build (backlog #569, Astra, shift19 00:18: Kestrel's rocket turret ghosts
-- were set to big asteroids only and the turrets the hub built read default targeting; 68 rockets went on small ones).
-- On 2.0.77 (a copy of world n) a gun turret built by a platform hub from a configured ghost kept it, by configure and by
-- place_ghosts configure, with and without an ammo request; the case was not seen again. So: what configure sets on a
-- turret ghost is remembered (2 h at most); every 2 s the built turret in its place is read, and one that reads other
-- targeting is set to what the ghost had, said once to the agent who set it (team.alerts). Nothing else is changed.
return function(api)
  local M = {}
  M.KEEP, M.MAX = 432000, 64
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function store()
    local s = api.state()
    s.turret_watch = s.turret_watch or {list={}, lines={}}
    return s.turret_watch
  end
  local function same(a, b)
    if #a ~= #b then return false end
    for i = 1, #a do if a[i] ~= b[i] then return false end end
    return true
  end
  -- After configure set a turret ghost's targeting.
  function M.watch(e, by)
    if not (e and e.valid and e.type == 'entity-ghost') then return end
    local now = api.targets(e)
    if not now then return end
    local st = store()
    local key = e.surface.index .. ':' .. e.position.x .. ',' .. e.position.y
    st.list[key] = {surface=e.surface.index, x=e.position.x, y=e.position.y, name=e.ghost_name, list=now.list, ignore=now.ignore, by=by, tick=game.tick}
    local n, oldest, ot = 0, nil, math.huge
    for k, r in pairs(st.list) do n = n + 1; if r.tick < ot then oldest, ot = k, r.tick end end
    if n > M.MAX and oldest then st.list[oldest] = nil end
  end
  function M.tick()
    local st = store()
    for key, r in pairs(st.list) do
      local s = game.surfaces[r.surface]
      local built = s and try(function() return s.find_entities_filtered{position={r.x, r.y}, name=r.name, limit=1}[1] end)
      if built and built.valid then
        st.list[key] = nil
        local now = api.targets(built)
        if now and not (same(now.list, r.list) and now.ignore == r.ignore) then
          local ok = pcall(api.configure, built, {priority_targets=r.list, ignore_unprioritised=r.ignore})
          local where = try(function() return built.surface.platform and 'platform ' .. built.surface.platform.name end) or built.surface.name
          local line = string.format('turret targeting: %s built at (%g,%g) on %s read %s; %s the ghost\'s: %s', r.name, r.x, r.y, where, now.line,
            ok and 'set to' or 'could not be set to', api.targets(built) and api.targets(built).line or '?')
          if r.by then
            st.lines[r.by] = st.lines[r.by] or {}
            table.insert(st.lines[r.by], line)
            while #st.lines[r.by] > 4 do table.remove(st.lines[r.by], 1) end
          end
        end
      else
        local ghost = s and try(function() return s.find_entities_filtered{position={r.x, r.y}, ghost_name=r.name, limit=1}[1] end)
        if not ghost or game.tick - r.tick > M.KEEP then st.list[key] = nil end
      end
    end
  end
  function M.lines(p, h)
    local st = api.state().turret_watch
    local l = st and st.lines[p.index]
    if not l or #l == 0 then return nil end
    st.lines[p.index] = nil
    return l
  end
  return M
end
