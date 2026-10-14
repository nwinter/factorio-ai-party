-- Requests under a paste (Astra, 01:53: "preserve or explicitly warn about hub
-- requests being cleared when pasting a blueprint over an existing platform
-- hub"). What the engine does, checked on a private 2.0.77 server: a paste
-- (the blueprint build every bot and every platform paste uses) leaves the
-- requests of an entity it lands on as they were, whether its blueprint
-- carries requests or not; and the engine's blueprint of a platform hub
-- stores its manual request sections switched off and without their import
-- planet, whatever they are on the hub (a requester chest's keeps its state).
-- So a paste snapshots the logistic sections of the entities it lands on,
-- says what they hold after, and puts them back if they changed while the
-- blueprint carried none of its own.
return function(api)
  local M = {}
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  -- Entities with logistic request sections.
  M.TYPES = {['space-platform-hub']=true, ['logistic-container']=true, ['cargo-landing-pad']=true, ['spider-vehicle']=true}
  local function copy(list)
    local out = {}
    for i, f in ipairs(list or {}) do
      local v = f.value
      out[i] = {value=v and {type=v.type, name=v.name, quality=v.quality, comparator=v.comparator} or nil, min=f.min, max=f.max,
        minimum_delivery_count=f.minimum_delivery_count,
        import_from=f.import_from and (type(f.import_from) == 'string' and f.import_from or f.import_from.name) or nil}
    end
    return out
  end
  -- {sections = {{manual, group, active, multiplier, filters}}} or nil.
  function M.snapshot(e)
    local secs = try(function() return e.get_logistic_sections() end)
    if not secs then return nil end
    local out = {sections={}}
    for i = 1, secs.sections_count do
      local s = secs.get_section(i)
      out.sections[i] = {manual=s.is_manual, group=s.group or '', active=s.active ~= false, multiplier=s.multiplier or 1,
        filters=copy(s.filters)}
    end
    return out
  end
  local function same_filters(a, b)
    if #a ~= #b then return false end
    for i = 1, #a do
      local x, y = a[i], b[i]
      local xv, yv = x.value or {}, y.value or {}
      if xv.name ~= yv.name or (xv.quality or 'normal') ~= (yv.quality or 'normal') or (x.min or 0) ~= (y.min or 0)
        or x.max ~= y.max or x.import_from ~= y.import_from then return false end
    end
    return true
  end
  function M.same(a, b)
    if not (a and b) or #a.sections ~= #b.sections then return false end
    for i, s in ipairs(a.sections) do
      local t = b.sections[i]
      if s.manual ~= t.manual or s.group ~= t.group or s.active ~= t.active or s.multiplier ~= t.multiplier or not same_filters(s.filters, t.filters) then
        return false
      end
    end
    return true
  end
  -- "2 sections, 1 off" (manual sections that hold requests or a group).
  function M.text(snap)
    local n, off = 0, 0
    for _, s in ipairs(snap and snap.sections or {}) do
      if s.manual and (#s.filters > 0 or s.group ~= '') then
        n = n + 1
        if not s.active then off = off + 1 end
      end
    end
    return string.format('%d section%s%s', n, n == 1 and '' or 's', off > 0 and ', '..off..' off' or '')
  end
  -- Put the manual sections back as they were (the game's own sections stay).
  function M.restore(e, snap)
    local secs = e.get_logistic_sections()
    for i = secs.sections_count, 1, -1 do
      if secs.get_section(i).is_manual then secs.remove_section(i) end
    end
    for _, s in ipairs(snap.sections) do
      if s.manual then
        local sec = s.group ~= '' and secs.add_section(s.group) or secs.add_section()
        if s.group == '' then sec.filters = s.filters end
        sec.active = s.active
        sec.multiplier = s.multiplier
      end
    end
  end
  -- Request sections a blueprint entity carries (with requests or a group).
  function M.bp_sections(e)
    local n = 0
    for _, s in ipairs(e.request_filters and e.request_filters.sections or {}) do
      if (s.filters and #s.filters > 0) or (s.group and s.group ~= '') then n = n + 1 end
    end
    return n
  end
  local function at(pos) return string.format('(%g,%g)', pos.x, pos.y) end
  -- Before a paste: the entities with requests that blueprint entities land
  -- on. spots: {{name, position, own (the blueprint's sections)}}.
  function M.before(surface, spots)
    local list = {}
    for _, sp in ipairs(spots) do
      if M.TYPES[try(function() return prototypes.entity[sp.name].type end) or ''] then
        local e = surface.find_entities_filtered{position=sp.position, name=sp.name, limit=1}[1]
        local snap = e and M.snapshot(e)
        if snap then list[#list+1] = {e=e, snap=snap, own=sp.own, position=e.position} end
      end
    end
    return list
  end
  -- After it: one line per entity, putting back requests a paste changed
  -- when the blueprint carried none.
  function M.after(list)
    local rows = {}
    for _, k in ipairs(list) do
      if k.e.valid then
        local now = M.snapshot(k.e)
        local head = k.e.name..' '..at(k.position)..': '
        if M.same(now, k.snap) then
          rows[#rows+1] = head..'requests kept ('..M.text(k.snap)..')'
            ..(k.own > 0 and string.format('; the blueprint\'s own requests (%d section%s) are not applied by a paste', k.own, k.own == 1 and '' or 's') or '')
        elseif k.own > 0 then
          rows[#rows+1] = head..'replaced by the blueprint\'s ('..M.text(now)..')'
        else
          local ok = pcall(M.restore, k.e, k.snap)
          rows[#rows+1] = head..(ok and 'requests kept ('..M.text(k.snap)..'; the paste had changed them and they were put back)'
            or 'requests changed by the paste ('..M.text(now)..', was '..M.text(k.snap)..')')
        end
      end
    end
    return #rows > 0 and rows or nil
  end
  -- The dry run's line for a planned entity landing on one with requests.
  function M.plan(surface, name, position, own)
    if not M.TYPES[try(function() return prototypes.entity[name].type end) or ''] then return nil end
    local e = surface.find_entities_filtered{position=position, name=name, limit=1}[1]
    local snap = e and M.snapshot(e)
    if not snap then return nil end
    return e.name..' '..at(e.position)..': its requests stay ('..M.text(snap)..')'
      ..((own or 0) > 0 and string.format('; the blueprint\'s own requests (%d section%s) are not applied by a paste', own, own == 1 and '' or 's') or '')
  end
  return M
end
