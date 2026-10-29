-- powerleft (d29 batch341 PW, viewer Aurora: "Asterion lost its only power before fusion was ready"). At 376h48 a
-- superforced strip paste marked Asterion's 9 solar panels and 143 accumulators with 524 other entities; its reply listed
-- them by name among the rest, and nothing said that no generation was left. Robots took them; its railguns and lasers
-- stood unpowered, and an asteroid broke a collector.
-- A removal (deconstruct and its dry run, a forced paste's marks, mine and its dry run) that takes a generator: each
-- electric network it takes one from is read for what generates there after it, leaving out what the removal takes
-- and what is already marked for deconstruction. None left, with consumers that drew power in the last 10 minutes: one
-- line, as facts: the network, the generators going, the consumers' draw over the last minute (the network's
-- statistics, as its GUI graph) with the largest, and the accumulators' charge left with how long it lasts at that draw.
-- Nothing is refused. Generators: what makes electric power (generator, fusion-generator, solar-panel,
-- burner-generator, electric-energy-interface, lightning-attractor); accumulators store it and are counted apart.
-- What is read: a platform surface's generators and accumulators by one search of the surface (a platform is small);
-- on a planet, the census pass's lists of generators, solar panels and accumulators, and one search for the kinds it
-- does not list (fusion generators and the like), only when the removal takes a generator there.
-- api.flow: qflow.lua's flow (a name over every quality), from runtime.lua.
return function(api)
  local M = {}
  local GEN = {generator=true, ['fusion-generator']=true, ['solar-panel']=true, ['burner-generator']=true,
    ['electric-energy-interface']=true, ['lightning-attractor']=true}
  local CENSUS_TYPES = {'generator', 'solar-panel', 'accumulator'}
  local OTHER_TYPES = {'fusion-generator', 'burner-generator', 'electric-energy-interface', 'lightning-attractor'}
  local ALL_TYPES = {'generator', 'fusion-generator', 'solar-panel', 'burner-generator', 'electric-energy-interface',
    'lightning-attractor', 'accumulator'}
  M.POWER = {accumulator=true}
  for t in pairs(GEN) do M.POWER[t] = true end
  M.TOP = 4
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function kw_text(kw)
    if kw >= 1000 then return string.format('%.2f MW', kw / 1000) end
    return string.format('%d kW', math.floor(kw + 0.5))
  end
  local function mj_text(j)
    local m = j / 1e6
    if m >= 100 then return string.format('%d MJ', math.floor(m + 0.5)) end
    return string.format('%.1f MJ', m)
  end
  local function span(sec)
    sec = math.max(0, math.floor(sec + 0.5))
    if sec >= 3600 then return string.format('%dh%02dm', math.floor(sec / 3600), math.floor(sec / 60) % 60) end
    return sec >= 60 and string.format('%dm%02ds', math.floor(sec / 60), sec % 60) or sec .. 's'
  end
  -- The generators and accumulators on a surface: a platform's by a search; a planet's from the census pass's lists
  -- and a search for the kinds those lists leave out.
  local function power_entities(force, surface)
    if surface.platform then return surface.find_entities_filtered{type=ALL_TYPES, force=force} end
    local listed = api.typed and api.typed(force, surface, CENSUS_TYPES)
    if type(listed) ~= 'table' then return surface.find_entities_filtered{type=ALL_TYPES, force=force} end
    local out = {}
    for _, e in ipairs(listed) do out[#out+1] = e end
    for _, e in ipairs(surface.find_entities_filtered{type=OTHER_TYPES, force=force}) do out[#out+1] = e end
    return out
  end
  -- What the network's consumers drew over the last minute (kW), the largest, and whether any drew in 10 minutes;
  -- accumulators charging are not consumers.
  local function draw(stats)
    local fpi = defines.flow_precision_index
    local kw, by, any = 0, {}, false
    for name, all in pairs(try(function() return stats.output_counts end) or {}) do
      local proto = try(function() return prototypes.entity[name] end)
      if not (proto and proto.type == 'accumulator') then
        local v = try(function() return api.flow(stats, name, 'output', fpi.one_minute, nil, all) end) or 0
        local v10 = try(function() return api.flow(stats, name, 'output', fpi.ten_minutes, nil, all) end) or 0
        if v10 > 0 then any = true end
        if v > 0 then by[#by+1] = {name, v * 60 / 1000}; kw = kw + v * 60 / 1000 end
      end
    end
    table.sort(by, function(x, y) return x[2] > y[2] end)
    return kw, by, any
  end
  -- removing: the entities the call removes or would remove (any kind; only its generators and accumulators count).
  -- dry: a dry run (they are not marked yet). Returns lines, or nil when no network it takes a generator from is left
  -- with none.
  function M.after(force, removing, dry)
    local nets, gone = {}, {}
    for _, e in ipairs(removing) do
      if e.valid and M.POWER[e.type] then
        local unit = e.unit_number
        if unit then gone[unit] = true end
        local id = try(function() return e.electric_network_id end)
        if id then
          local n = nets[id]
          if not n then n = {id=id, surface=e.surface, ref=e, gens=0, accs=0, names={}}; nets[id] = n end
          if GEN[e.type] then n.gens = n.gens + 1; n.names[e.name] = (n.names[e.name] or 0) + 1 else n.accs = n.accs + 1 end
        end
      end
    end
    local lines = {}
    local by_surface = {}
    for id, n in pairs(nets) do
      if n.gens > 0 then
        local key = n.surface.index
        by_surface[key] = by_surface[key] or power_entities(force, n.surface)
        local left, acc_j = 0, 0
        for _, e in ipairs(by_surface[key]) do
          if e.valid and not gone[e.unit_number] and try(function() return e.electric_network_id end) == id
            and not e.to_be_deconstructed(force) then
            if GEN[e.type] then left = left + 1 else acc_j = acc_j + (try(function() return e.energy end) or 0) end
          end
        end
        if left == 0 then
          local stats = try(function() return n.ref.electric_network_statistics end)
          local kw, by, any = 0, {}, false
          if stats then kw, by, any = draw(stats) end
          if any then
            local going = {}
            for name, c in pairs(n.names) do going[#going+1] = c .. ' ' .. name end
            table.sort(going)
            local top = {}
            for i = 1, math.min(M.TOP, #by) do top[i] = by[i][1] .. ' ' .. kw_text(by[i][2]) end
            local where = n.surface.platform and try(function() return n.surface.platform.name end) or n.surface.name
            lines[#lines+1] = string.format('removing these leaves electric network %d on %s with no generation: %s go%s, none other there%s; '
              .. 'its consumers drew %s over the last minute%s; accumulators left %s%s',
              id, where, table.concat(going, ', '), (n.accs > 0 and string.format(' with %d accumulator%s', n.accs, n.accs == 1 and '' or 's') or ''),
              dry and '' or ' (marked: they go as robots take them)',
              kw_text(kw), #top > 0 and ' (' .. table.concat(top, ', ') .. ')' or '',
              mj_text(acc_j), kw > 0 and (acc_j > 0 and string.format(', about %s at that draw', span(acc_j / (kw * 1000))) or '') or '')
          end
        end
      end
    end
    return #lines > 0 and lines or nil
  end
  return M
end
