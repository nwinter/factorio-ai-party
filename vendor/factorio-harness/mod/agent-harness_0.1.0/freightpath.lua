-- (d23 batch123 CF3, viewer Aurora 09:47: "Could disabling a freight request or retiring a route flag any essential
-- supply left without an active delivery path, naming the missing link and owner? Please test the bioflux case.")
-- A delivery path of an item to a planet, as the game's freight runs now: a platform of ours whose hub requests it (an
-- active section, a minimum above 0) from an import planet its schedule stops at, and whose schedule also stops at the
-- planet, whose landing pad requests it (an active section, a minimum above 0). A requests call on a hub or a landing
-- pad that changes its slots or sections, a platform_schedule call and a platform_delete call read the paths before and
-- after (a platform being deleted has none); each item and planet that had a path and has none left is a line in the
-- call's reply (supply_left): the paths it had, the link each lost (the pad's request, the hub's request, a stop), who
-- set that link last before this call (the edit log: a section's or the schedule's last editor; none recorded: said
-- so), what the planet used of it in the last 10 minutes and what its pads hold. That editor, when another agent, is
-- told once. Facts only; nothing is changed back.
return function(api)
  local M = {}
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function name_of(v) return type(v) == 'string' and v or try(function() return v.name end) end
  -- What a hub asks now (its active sections, compiled by the game: no import planet): {[item]=true}.
  local function asked(pl)
    local pt = defines.logistic_member_index and try(function() return pl.hub.get_logistic_point(defines.logistic_member_index.space_platform_hub_requester) end)
    local out = {}
    for _, f in ipairs(pt and try(function() return pt.filters end) or {}) do
      if f.name and (f.count or 0) > 0 then out[f.name] = true end
    end
    return out
  end
  M.asked = asked
  -- One platform: its stops (station names, in order, once each) and its hub's asks of the focus items
  -- {[item]={[from]=true}}; its schedule and sections are read only when the hub asks one of them (6.5 ms for every
  -- section of 19 hubs on a copy of world n, 0.9 ms for their compiled requests).
  local function platform_row(pl, focus)
    local row = {name=pl.name, stops={}, at={}, asks={}, hub=try(function() return pl.hub.unit_number end)}
    local any = false
    for item in pairs(asked(pl)) do if focus[item] then any = true; break end end
    if not any then return row end
    local sch = try(function() return pl.schedule end)
    for _, r in ipairs(sch and sch.records or {}) do
      local st = r.station
      if type(st) == 'string' and not row.at[st] then row.at[st] = true; row.stops[#row.stops+1] = st end
    end
    local secs = try(function() return pl.hub.get_logistic_sections() end)
    for i = 1, secs and secs.sections_count or 0 do
      local sec = secs.get_section(i)
      if sec and sec.active ~= false then
        for _, f in ipairs(sec.filters or {}) do
          local item, from = name_of(f.value), f.import_from and name_of(f.import_from)
          if item and focus[item] and from and (f.min or 0) > 0 then
            row.asks[item] = row.asks[item] or {}
            row.asks[item][from] = true
          end
        end
      end
    end
    return row
  end
  -- The force's freight of the focus items ({[item]=true}) now: platforms by name and the planets' pads (asked and held
  -- by item, pad units).
  function M.snapshot(force, focus)
    local snap = {platforms={}, pads={}, focus=focus}
    for _, pl in pairs(force.platforms or {}) do
      if pl.valid and (try(function() return pl.scheduled_for_deletion end) or 0) == 0 and try(function() return pl.hub and pl.hub.valid end) then
        snap.platforms[pl.name] = platform_row(pl, focus)
      end
    end
    function snap.pad(planet)
      local r = snap.pads[planet]
      if r == nil then
        local ask, hold = api.pads(planet, force)
        local s = try(function() return game.planets[planet].surface end)
        local units = {}
        -- the census pass's pads when it has them (a whole-surface find took 10.5 ms on Nauvis: freight.lua pads)
        local known = s and api.census_typed and try(function() return api.census_typed(force, s, 'cargo-landing-pad') end)
        for _, pad in ipairs(known or s and try(function() return s.find_entities_filtered{type='cargo-landing-pad', force=force} end) or {}) do
          if pad.valid then units[#units+1] = pad.unit_number end
        end
        r = {ask=ask or {}, hold=hold or {}, units=units, surface=s}
        snap.pads[planet] = r
      end
      return r
    end
    -- read now, before the call changes them: every planet a platform asking a focus item stops at
    for _, row in pairs(snap.platforms) do if next(row.asks) then for _, st in ipairs(row.stops) do snap.pad(st) end end end
    return snap
  end
  -- Every path, by 'item|planet': {{item, from, platform, to}}.
  function M.paths(snap)
    local out = {}
    for _, row in pairs(snap.platforms) do
      for item, froms in pairs(row.asks) do
        for from in pairs(froms) do
          if row.at[from] then
            for _, to in ipairs(row.stops) do
              if to ~= from and (snap.pad(to).ask[item] or 0) > 0 then
                local k = item .. '|' .. to
                out[k] = out[k] or {}
                table.insert(out[k], {item=item, from=from, platform=row.name, to=to})
              end
            end
          end
        end
      end
    end
    return out
  end
  -- The link a path lost between two snapshots, and the edit-log scope whose last editor set it.
  local function broken(path, snap)
    local row = snap.platforms[path.platform]
    if not row then return string.format('%s is gone (deleted)', path.platform), nil end
    if (snap.pad(path.to).ask[path.item] or 0) == 0 then
      local u = snap.pad(path.to).units[1]
      return string.format('%s\'s landing pad no longer requests %s', path.to, path.item), u and {scope='req:' .. u}
    end
    if not (row.asks[path.item] and row.asks[path.item][path.from]) then
      return string.format('%s\'s hub no longer requests %s from %s', path.platform, path.item, path.from), row.hub and {scope='req:' .. row.hub}
    end
    if not row.at[path.from] then return string.format('%s\'s schedule no longer stops at %s', path.platform, path.from), {scope='plat:' .. path.platform, key='schedule stops'} end
    if not row.at[path.to] then return string.format('%s\'s schedule no longer stops at %s', path.platform, path.to), {scope='plat:' .. path.platform, key='schedule stops'} end
    return 'unknown', nil
  end
  local function used(force, surface, item)
    local stats = surface and try(function() return force.get_item_production_statistics(surface) end)
    return stats and try(function()
      return stats.get_flow_count{name=item, category='output', precision_index=defines.flow_precision_index.ten_minutes, count=true}
    end) or nil
  end
  -- The lines for the paths lost between before and after (snapshots of force), by the caller `by`, and the owners
  -- to tell: {lines, owed={[name]={lines}}}.
  function M.lost(force, before, after, by, tick)
    local was, now = M.paths(before), M.paths(after)
    local keys = {}
    for k in pairs(was) do if not now[k] then keys[#keys+1] = k end end
    table.sort(keys)
    local lines, owed = {}, {}
    for _, k in ipairs(keys) do
      local list = was[k]
      local item, to = list[1].item, list[1].to
      local via, links, owners, seen = {}, {}, {}, {}
      for _, path in ipairs(list) do
        via[#via+1] = string.format('%s from %s', path.platform, path.from)
        local link, log = broken(path, after)
        if not seen[link] then
          seen[link] = true
          local e = log and api.owner and api.owner(log.scope, log.key, tick)
          links[#links+1] = link .. (e and string.format(' (set last by %s at tick %d)', e.by, e.tick) or ' (no earlier editor recorded)')
          if e and e.by and e.by ~= by then owners[e.by] = true end
        end
      end
      local pad = after.pad(to)
      local n = used(force, pad.surface, item)
      local line = string.format('%s to %s: no active delivery path left; it had %s; %s%s; %s holds %d in its landing pad', item, to,
        table.concat(via, ', '), table.concat(links, '; '), n and string.format('; %s used %d in the last 10 minutes', to, n) or '', to, pad.hold[item] or 0)
      lines[#lines+1] = line
      for name in pairs(owners) do owed[name] = owed[name] or {}; table.insert(owed[name], line) end
    end
    return lines, owed
  end
  local function platform_named(force, name)
    for _, pl in pairs(force.platforms or {}) do if pl.valid and pl.name == name then return pl end end
  end
  -- Around a call: the items it can take a path from (what the hub or pad it edits asks now, or what the platform whose
  -- schedule it edits asks), and the snapshot of their freight before it; nil: it cannot change a path.
  function M.before(p, action, a)
    if a.dry_run then return nil end
    local focus
    if action == 'requests' then
      if not (a.set ~= nil or a.clear ~= nil or a.clear_all ~= nil or a.active ~= nil or a.remove ~= nil or a.keep ~= nil) then return nil end
      if a.platform ~= nil then
        local pl = platform_named(p.force, a.platform)
        focus = pl and asked(pl)
      else
        if type(a.position) ~= 'table' then return nil end
        local s = type(a.surface) == 'string' and (try(function() return game.planets[a.surface].surface end) or game.get_surface(a.surface)) or (api.surface and api.surface(p))
        local x, y = a.position.x or a.position[1], a.position.y or a.position[2]
        local pads = s and type(x) == 'number' and try(function() return s.find_entities_filtered{position={x, y}, type='cargo-landing-pad'} end)
        if not (pads and #pads > 0) then return nil end
        local ask = api.pads(s.name, p.force)
        focus = {}
        for item, n in pairs(ask or {}) do if n > 0 then focus[item] = true end end
      end
    elseif action == 'platform_schedule' or action == 'platform_delete' then
      local pl = a.platform ~= nil and platform_named(p.force, a.platform)
      focus = pl and asked(pl)
    end
    if not focus or next(focus) == nil then return nil end
    return M.snapshot(p.force, focus)
  end
  function M.after(p, action, a, out, before)
    if type(out) ~= 'table' then return end
    local by = api.who and api.who(p) or p.name
    local lines, owed = M.lost(p.force, before, M.snapshot(p.force, before.focus), by, game.tick)
    if #lines == 0 then return end
    out.supply_left = lines
    local told = {}
    for name, list in pairs(owed) do
      local index = api.index_of and api.index_of(name)
      if index and api.deliver then
        local ok = pcall(api.deliver, index, {seq='supply', tick=game.tick, from=by,
          text=string.format('%s\'s %s left supply without an active delivery path: %s', by, action, table.concat(list, ' | '))})
        if ok then told[#told+1] = name end
      end
    end
    table.sort(told)
    out.supply_left_told = #told > 0 and told or nil
  end
  return M
end
