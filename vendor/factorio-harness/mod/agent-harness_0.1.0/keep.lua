-- Requests under a paste (Astra, 01:53: "preserve or explicitly warn about hub
-- requests being cleared when pasting a blueprint over an existing platform
-- hub"). What the engine does, checked on private 2.0.77 servers: the
-- engine's blueprint of a platform hub stores its manual request sections
-- switched off and without their import planet, whatever they are on the hub
-- (a requester chest's keeps its state). A paste (the blueprint build every
-- bot and every platform paste uses) of Astra's Starling hub blueprint
-- (shift12 19:16, a hub with read_contents and no requests, which the engine
-- reads as one empty section) left the hub one empty manual section,
-- switched off, and switched its "Request missing construction materials"
-- off, as the blueprint's hub has it (a blueprint entity's
-- request_missing_construction_materials; absent is off; 2.0.77's LuaEntity
-- has no field for it). The game then drops its own construction section
-- (request_missing_materials_controlled: fast-inserter 19,
-- space-platform-foundation 624, crusher 3 from 72 ghosts and 624 tile
-- ghosts) and leaves it off, ghosts or not. Switched on again, by a hub
-- blueprint that has it on, the section is there empty in that tick and the
-- game fills it from the platform's ghosts the next tick (four of four
-- tries); ghosts placed in that tick join it 17-18 ticks later (three of
-- three). So a paste snapshots the logistic sections of the entities it lands
-- on, puts the manual ones back if they changed while the blueprint carried
-- none of its own, switches the construction requests back on where the
-- paste switched them off, and says what each holds after.
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
  -- The game's construction section of a hub (its Request missing construction materials is on), or nil.
  function M.construction(e)
    local t = try(function() return defines.logistic_section_type.request_missing_materials_controlled end)
    local secs = t and try(function() return e.get_logistic_sections() end)
    if not secs then return nil end
    for i = 1, secs.sections_count do
      local s = secs.get_section(i)
      if s.type == t then return s end
    end
    return nil
  end
  -- {sections = {{manual, group, active, multiplier, filters}}, construction = filters of the game's construction
  -- section (nil: none)} or nil.
  function M.snapshot(e)
    local secs = try(function() return e.get_logistic_sections() end)
    if not secs then return nil end
    local out = {sections={}}
    for i = 1, secs.sections_count do
      local s = secs.get_section(i)
      out.sections[i] = {manual=s.is_manual, group=s.group or '', active=s.active ~= false, multiplier=s.multiplier or 1,
        filters=copy(s.filters)}
    end
    local c = M.construction(e)
    out.construction = c and copy(c.filters) or nil
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
  local function manual(snap)
    local out = {}
    for _, s in ipairs(snap.sections) do if s.manual then out[#out+1] = s end end
    return out
  end
  -- The manual sections alike (the game's own follow its settings and the ghosts).
  function M.same(a, b)
    if not (a and b) then return false end
    local x, y = manual(a), manual(b)
    if #x ~= #y then return false end
    for i, s in ipairs(x) do
      local t = y[i]
      if s.group ~= t.group or s.active ~= t.active or s.multiplier ~= t.multiplier or not same_filters(s.filters, t.filters) then
        return false
      end
    end
    return true
  end
  -- "fast-inserter 19, space-platform-foundation 624, crusher 3".
  function M.items_text(filters, limit)
    local parts = {}
    for _, f in ipairs(filters or {}) do
      local v = f.value
      if v and v.name and #parts < (limit or 8) then
        parts[#parts+1] = v.name..(v.quality and v.quality ~= 'normal' and '@'..v.quality or '')..' '..(f.min or 0)
      end
    end
    if #parts == 0 then return 'none' end
    return table.concat(parts, ', ')..(#(filters or {}) > #parts and string.format(' +%d more', #filters-#parts) or '')
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
  -- Switch a hub's Request missing construction materials: 2.0.77's API has no field for it, so a one-entity hub
  -- blueprint carrying it is built over the hub (the game reads the setting from it as from any paste). That build
  -- gives the hub the blueprint's request sections too, so the manual ones are put back after. Returns whether the
  -- game's construction section is there now.
  function M.set_construction(e, on)
    local snap = M.snapshot(e)
    local inv = game.create_inventory(1)
    local ok, err = pcall(function()
      local st = inv[1]
      st.set_stack{name='blueprint'}
      st.set_blueprint_entities{{entity_number=1, name=e.name, position={x=0, y=0}, request_missing_construction_materials=on == true}}
      st.build_blueprint{surface=e.surface, force=e.force, position=e.position, build_mode=defines.build_mode.normal}
    end)
    inv.destroy()
    if not ok then error(err, 0) end
    if snap and not M.same(M.snapshot(e), snap) then M.restore(e, snap) end
    return M.construction(e) ~= nil
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
  -- on. spots: {{name, position, own (the blueprint's sections), construction (its hub has Request missing
  -- construction materials on)}}.
  function M.before(surface, spots)
    local list = {}
    for _, sp in ipairs(spots) do
      if M.TYPES[try(function() return prototypes.entity[sp.name].type end) or ''] then
        local e = surface.find_entities_filtered{position=sp.position, name=sp.name, limit=1}[1]
        local snap = e and M.snapshot(e)
        if snap then list[#list+1] = {e=e, snap=snap, own=sp.own, construction=sp.construction, position=e.position} end
      end
    end
    return list
  end
  local SWITCHED_OFF = 'the paste switched off Request missing construction materials, which this blueprint\'s hub has off'
  -- A hub's construction requests after a paste: on as before, switched back on where the paste switched them off,
  -- switched on by the blueprint, or nil (off before and after; not a hub).
  local function construction_after(k)
    local was = k.snap.construction
    if was then
      if M.construction(k.e) then return 'construction requests on' end
      local ok, on = pcall(M.set_construction, k.e, true)
      if ok and on then
        return 'construction requests kept on ('..SWITCHED_OFF..'; switched back on, the game refills them from the '
          ..'platform\'s ghosts within a second; before the paste: '..M.items_text(was)..')'
      end
      return 'construction requests off ('..SWITCHED_OFF..'; switching it back on failed'..(ok and '' or ': '..tostring(on))
        ..'; before the paste: '..M.items_text(was)..'); requests {platform, construction_requests: true} switches it on'
    elseif M.construction(k.e) then
      return 'construction requests switched on by the blueprint\'s hub (the game fills them from the platform\'s ghosts within a second)'
    end
    return nil
  end
  -- After it: one line per entity, putting back requests a paste changed
  -- when the blueprint carried none, and a hub's construction requests.
  function M.after(list)
    local rows = {}
    for _, k in ipairs(list) do
      if k.e.valid then
        -- (first: switching them back on builds over the hub, which changes its manual sections again)
        local construction = construction_after(k)
        local now = M.snapshot(k.e)
        local head = k.e.name..' '..at(k.position)..': '
        local before = #rows
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
        if construction and #rows > before then rows[#rows] = rows[#rows]..'; '..construction end
      end
    end
    return #rows > 0 and rows or nil
  end
  -- The dry run's line for a planned entity landing on one with requests. construction: the blueprint's hub has
  -- Request missing construction materials on.
  function M.plan(surface, name, position, own, construction)
    if not M.TYPES[try(function() return prototypes.entity[name].type end) or ''] then return nil end
    local e = surface.find_entities_filtered{position=position, name=name, limit=1}[1]
    local snap = e and M.snapshot(e)
    if not snap then return nil end
    local line = e.name..' '..at(e.position)..': its requests stay ('..M.text(snap)..')'
      ..((own or 0) > 0 and string.format('; the blueprint\'s own requests (%d section%s) are not applied by a paste', own, own == 1 and '' or 's') or '')
    if snap.construction and construction then line = line..'; construction requests stay on'
    elseif snap.construction then
      line = line..'; construction requests stay on (this blueprint\'s hub has Request missing construction materials off, '
        ..'which a paste switches off; the paste switches it back on): '..M.items_text(snap.construction)
    elseif construction then line = line..'; the blueprint\'s hub switches construction requests on' end
    return line
  end
  return M
end
