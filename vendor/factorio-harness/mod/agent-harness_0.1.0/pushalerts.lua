-- The game's alerts and key warnings, pushed (viewer Enginerd, shift07 15:30:
-- "The agents would be a lot more efficient if they'd react to the alerts in
-- the UI, like reacting to unpowered buildings"). Full status listed power,
-- fuel and turret warnings only when an agent pulled it, and the game's alert
-- list (construction materials, robots, repair packs, storage, trains,
-- cargo, collectors) was never read. Here, what a player's alert panel and
-- entity status icons show:
-- - entity statuses: no power (and no pole reaching it), low power, no fuel,
--   gun turrets out of ammo, flamethrower turrets dry;
-- - the game's alerts (LuaPlayer.get_alerts, read from an agent player whose
--   alerts are on; attacks, losses and empty turrets are told elsewhere);
-- - per network (networks.lua, task-selfview): draw at 85% of capacity or
--   more for 2 minutes, boilers under 10 minutes of fuel, no idle logistic
--   robot for 10 minutes.
-- Grouped by kind and 64-tile area on each surface; each group goes to the
-- agents whose board claim covers it, else who built it (last_user), else
-- the nearest agent on that surface. In the team block (team.alerts) at most
-- one digest per agent every 150 s, new or worsening groups only; the
-- game_alerts read lists them all. The scan is kept in storage for 30 s so
-- every peer computes the same lines.
return function(api)
  local M = {}
  local CELL, SCAN_TICKS, DIGEST_TICKS, MAX_LINES, MAX_SCAN = 64, 1800, 9000, 5, 20000
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local TYPES = {'assembling-machine', 'furnace', 'mining-drill', 'lab', 'inserter', 'beacon', 'radar', 'roboport',
    'pump', 'electric-turret', 'ammo-turret', 'fluid-turret', 'boiler', 'rocket-silo', 'agricultural-tower',
    'asteroid-collector', 'lamp', 'loader', 'loader-1x1', 'cargo-landing-pad', 'car', 'spider-vehicle'}
  -- Kinds and how a line says them; game alert types not listed read as their name.
  local LABEL = {no_power='no power', unconnected='not connected to power (no pole reaches them)', low_power='low power',
    no_fuel='out of fuel', no_ammo='out of ammo', flamer_dry='out of flamer oil',
    no_material_for_construction='ghosts waiting for materials (no robot can bring them)',
    not_enough_construction_robots='not enough construction robots', not_enough_repair_packs='robots out of repair packs',
    no_storage='robots have no storage for what they carry', no_roboport_storage='no roboport storage',
    train_out_of_fuel='train out of fuel', train_no_path='train has no path', unclaimed_cargo='unclaimed cargo',
    collector_path_blocked='asteroid collector path blocked', pipeline_overextended='pipeline overextended (flow stops)',
    no_platform_storage='platform hub storage full', platform_tile_building_blocked='platform tile building blocked'}
  local HINT = {no_power='fh call power', unconnected='fh call power', low_power='more power: fh call power', no_fuel='refuel',
    no_ammo='rearm', flamer_dry='fh call flamers', no_material_for_construction='craft or bring the items for the ghosts',
    not_enough_construction_robots='more construction robots in the roboports', not_enough_repair_packs='repair packs into a roboport or storage chest',
    no_storage='a storage chest in the network', train_out_of_fuel='refuel the locomotive'}
  -- Told elsewhere (attacks, losses, the turret scan).
  local SKIP = {entity_destroyed=true, entity_under_attack=true, turret_fire=true, turret_out_of_ammo=true, custom=true}
  local STATUS
  local function statuses()
    if not STATUS then
      local s = defines.entity_status or {}
      STATUS = {[s.no_power or -1]='no_power', [s.low_power or -2]='low_power', [s.no_fuel or -3]='no_fuel'}
    end
    return STATUS
  end
  local function alert_names()
    local out = {}
    for name, id in pairs(defines.alert_type or {}) do out[id] = name end
    return out
  end

  local function add(groups, kind, surface, e, pos, name, by)
    local cx, cy = math.floor(pos.x / CELL), math.floor(pos.y / CELL)
    local key = kind .. '|' .. surface .. '|' .. cx .. ',' .. cy
    local g = groups[key]
    if not g then
      g = {key=key, kind=kind, surface=surface, n=0, names={}, sx=0, sy=0, at={}, by={}}
      groups[key] = g
    end
    g.n = g.n + 1
    g.sx, g.sy = g.sx + pos.x, g.sy + pos.y
    if name then g.names[name] = (g.names[name] or 0) + 1 end
    if by then g.by[by] = (g.by[by] or 0) + 1 end
    if #g.at < 4 then g.at[#g.at+1] = {x=math.floor(pos.x * 10 + 0.5) / 10, y=math.floor(pos.y * 10 + 0.5) / 10} end
  end
  local function builder(e)
    return try(function() local u = e.last_user; return u and u.name end)
  end
  -- One read of everything: {tick, groups (array, worst first)}.
  local function scan(force)
    local groups, budget = {}, MAX_SCAN
    local st = statuses()
    for _, s in pairs(game.surfaces) do
      if not try(function() return s.platform end) then  -- platforms: platalerts.lua
        local list = try(function() return s.find_entities_filtered{force=force, type=TYPES, limit=budget} end) or {}
        budget = budget - #list
        for _, e in ipairs(list) do
          if e.valid then
            local kind = st[e.status]
            if kind == 'no_power' and not try(function() return e.electric_network_id end) then kind = 'unconnected' end
            if e.type == 'ammo-turret' then
              local inv = try(function() return e.get_inventory(defines.inventory.turret_ammo) end)
              if inv and inv.get_item_count() == 0 then kind = 'no_ammo' end
            elseif e.type == 'fluid-turret' then
              local amount = try(function() local f = e.fluidbox[1]; return f and f.amount or 0 end)
              if amount and amount < 1 then kind = 'flamer_dry' end
            end
            if kind then add(groups, kind, s.name, e, e.position, e.name, builder(e)) end
          end
        end
      end
    end
    -- The game's alert list, as an agent player's alert panel shows it.
    local reader = api.alert_reader and api.alert_reader(force)
    local raw = reader and try(function() return reader.get_alerts{} end)
    if raw then
      local names = alert_names()
      for surface_index, by_type in pairs(raw) do
        local s = game.surfaces[surface_index]
        for t, list in pairs(by_type) do
          local kind = names[t]
          if kind and not SKIP[kind] and s then
            for _, al in ipairs(list) do
              local e = al.target
              local ok = e and try(function() return e.valid end)
              local pos = ok and e.position or al.position
              if pos then
                add(groups, kind, s.name, ok and e or nil, pos, ok and e.name or (al.prototype and try(function() return al.prototype.name end)),
                  ok and builder(e) or nil)
              end
            end
          end
        end
      end
    end
    -- Cells of one kind on one surface that touch (8 neighbours) are one area:
    -- a turret line across a cell edge is one group. Its key is its first cell.
    local out, done = {}, {}
    local cells = {}
    for key, g in pairs(groups) do cells[#cells+1] = key end
    table.sort(cells)
    for _, key in ipairs(cells) do
      if not done[key] then
        local g = groups[key]
        local kind, surface, cx, cy = key:match('^(.-)|(.-)|(-?%d+),(-?%d+)$')
        local area = {key=key, kind=g.kind, surface=g.surface, n=0, names={}, sx=0, sy=0, at={}, by={}}
        local queue = {{tonumber(cx), tonumber(cy)}}
        done[key] = true
        while #queue > 0 do
          local c = table.remove(queue)
          local k = kind .. '|' .. surface .. '|' .. c[1] .. ',' .. c[2]
          local part = groups[k]
          area.n, area.sx, area.sy = area.n + part.n, area.sx + part.sx, area.sy + part.sy
          for n, v in pairs(part.names) do area.names[n] = (area.names[n] or 0) + v end
          for n, v in pairs(part.by) do area.by[n] = (area.by[n] or 0) + v end
          for _, pos in ipairs(part.at) do if #area.at < 4 then area.at[#area.at+1] = pos end end
          for dx = -1, 1 do for dy = -1, 1 do
            local nk = kind .. '|' .. surface .. '|' .. (c[1] + dx) .. ',' .. (c[2] + dy)
            if groups[nk] and not done[nk] then done[nk] = true; queue[#queue+1] = {c[1] + dx, c[2] + dy} end
          end end
        end
        area.center = {x=math.floor(area.sx / area.n + 0.5), y=math.floor(area.sy / area.n + 0.5)}
        area.sx, area.sy = nil, nil
        out[#out+1] = area
      end
    end
    -- Network groups (networks.lua): power_high, boiler_fuel, robots_busy,
    -- one per network, with their own line and level (n).
    for _, g in ipairs(api.network_groups and try(function() return api.network_groups(force) end) or {}) do out[#out+1] = g end
    table.sort(out, function(a, b) return a.n > b.n or (a.n == b.n and a.key < b.key) end)
    return out
  end
  local function current(force)
    local s = api.state()
    s.push_alerts = s.push_alerts or {}
    local c = s.push_alerts[force.name]
    if not c or game.tick - c.tick >= SCAN_TICKS then
      c = {tick=game.tick, groups=scan(force)}
      s.push_alerts[force.name] = c
    end
    return c
  end

  -- Who hears a group: the owners of active board claims over its centre,
  -- else agents who built in it, else the nearest agent on its surface.
  local ACTIVE = {open=true, claimed=true, doing=true, blocked=true}
  local function owners(g, roster)
    local out, board = {}, api.state().board
    for _, i in pairs(board and board.items or {}) do
      local a = i.area
      if i.kind == 'claim' and ACTIVE[i.status] and i.owner and a and g.center.x >= a.left_top.x and g.center.x <= a.right_bottom.x
        and g.center.y >= a.left_top.y and g.center.y <= a.right_bottom.y then out[i.owner] = 'claim' end
    end
    if next(out) then return out end
    for name in pairs(g.by) do if roster[name] then out[name] = 'built' end end
    if next(out) then return out end
    local best, d2 = nil, math.huge
    for name, a in pairs(roster) do
      local pl = a.place
      if pl and pl.key == g.surface and pl.position and not pl.dead then
        local d = (pl.position.x - g.center.x) ^ 2 + (pl.position.y - g.center.y) ^ 2
        if d < d2 then best, d2 = name, d end
      end
    end
    if best then out[best] = 'nearest' end
    return out
  end
  local function roster()
    local out = {}
    for _, a in ipairs(try(api.agents) or {}) do out[a.name] = {index=a.index, place=api.place and try(function() return api.place(a.index) end)} end
    return out
  end
  local function what(g)
    local names = {}
    for name, n in pairs(g.names) do names[#names+1] = {name=name, n=n} end
    table.sort(names, function(a, b) return a.n > b.n or (a.n == b.n and a.name < b.name) end)
    if #names == 1 then return g.n .. ' ' .. names[1].name end
    if #names == 0 then return tostring(g.n) end
    local parts = {}
    for i = 1, math.min(3, #names) do parts[i] = names[i].n .. ' ' .. names[i].name end
    return string.format('%d (%s%s)', g.n, table.concat(parts, ', '), #names > 3 and ', ...' or '')
  end
  -- plain: without the hint (the review block, selfview.lua).
  function M.text(g, here, was, plain)
    if g.line then
      return g.line .. (g.surface ~= here and ' on ' .. g.surface or '') .. (was and string.format(' (was %d%s)', was, g.unit or '') or '')
    end
    local hint = not plain and HINT[g.kind]
    return string.format('%s %s near (%d,%d)%s%s%s', what(g), LABEL[g.kind] or g.kind:gsub('_', ' '), g.center.x, g.center.y,
      g.surface ~= here and ' on ' .. g.surface or '', was and string.format(' (was %d)', was) or '', hint and '; ' .. hint or '')
  end

  -- Team block lines for p: at most one digest every DIGEST_TICKS, groups
  -- addressed to p that are new or grew since p was told.
  function M.lines(p, h)
    local mem = h.push or {told={}}
    if mem.tick and game.tick - mem.tick < DIGEST_TICKS then return {} end
    local c = current(p.force)
    local me = api.who(p)
    local here = try(function() return p.surface.name end)
    local who = roster()
    local now, lines, more = {}, {}, 0
    for _, g in ipairs(c.groups) do
      if owners(g, who)[me] then
        now[g.key] = g.n
        local told = mem.told[g.key]
        if not told or g.n > told then
          if #lines < MAX_LINES then
            lines[#lines+1] = M.text(g, here, told)
            mem.told[g.key] = g.n
          else more = more + 1 end
        elseif g.n < told then mem.told[g.key] = g.n end  -- better: a rise from here is news again
      end
    end
    for key in pairs(mem.told) do if not now[key] then mem.told[key] = nil end end  -- gone: news again if it returns
    if more > 0 then lines[#lines+1] = string.format('+%d more alert groups: fh call game_alerts', more) end
    if #lines > 0 then mem.tick = game.tick end
    h.push = (next(mem.told) or mem.tick) and mem or nil
    return lines
  end

  -- Groups now in p's own board claims (selfview.lua review), worst first, without hints.
  function M.claim_lines(p)
    local c = current(p.force)
    local me = api.who(p)
    local here = try(function() return p.surface.name end)
    local who, out = roster(), {}
    for _, g in ipairs(c.groups) do
      if owners(g, who)[me] == 'claim' then out[#out+1] = M.text(g, here, nil, true) end
    end
    return out
  end
  -- The game_alerts read: every group now, with who it goes to.
  function M.read(p, a)
    local c = current(p.force)
    local who = roster()
    local here = try(function() return p.surface.name end)
    local rows = {}
    for _, g in ipairs(c.groups) do
      if (a.surface == nil or g.surface == a.surface) and (a.kind == nil or g.kind == a.kind) then
        local to = {}
        for name, why in pairs(owners(g, who)) do to[#to+1] = name .. ' (' .. why .. ')' end
        table.sort(to)
        rows[#rows+1] = {kind=g.kind, surface=g.surface, count=g.n, center=g.center, names=g.names, at=g.at,
          line=M.text(g, here), to=#to > 0 and to or nil}
      end
    end
    return {groups=rows, scanned=string.format('%ds ago', math.floor((game.tick - c.tick) / 60)),
      note=#rows == 0 and 'no alerts or warnings' or nil}
  end
  M.schema = {
    game_alerts = {surface='optional surface name', kind='optional kind (no_power, unconnected, low_power, no_fuel, no_ammo, flamer_dry; per network: power_high (draw at 85% of capacity or more for 2 min), boiler_fuel (boilers under 10 min of fuel at the draw), robots_busy (no idle logistic robot for 10 min); on Fulgora: lightning_unconnected (lightning attractors no pole reaches), lightning_unused (attractors in a network with no accumulator and nothing drawing power in the last minute), lightning_storage_full (a network with attractors whose accumulators are at 99% or more); or a game alert type such as no_material_for_construction, not_enough_construction_robots, not_enough_repair_packs, no_storage, train_out_of_fuel, unclaimed_cargo, collector_path_blocked)',
      returns='groups worst first: {kind, surface, count, center, names, at (up to 4 positions), line, to (who the team block tells: claim, built, nearest)}; scanned (the scan is at most 30 s old). What a player\'s alert panel and status icons show; new or worsening groups also come in team.alerts (one digest per 150 s). Read only'},
  }
  return M
end
