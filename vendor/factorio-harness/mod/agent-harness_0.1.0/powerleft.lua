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
-- api.flow: qflow.lua's flow (a name over every quality); api.stats(id, surface): the network's statistics (a pole's,
-- or a platform surface's own: electric_network_statistics reads only on poles), from runtime.lua.
return function(api)
  local M = {}
  local GEN = {generator=true, ['fusion-generator']=true, ['solar-panel']=true, ['burner-generator']=true,
    ['electric-energy-interface']=true, ['lightning-attractor']=true}
  local SUN = {['solar-panel']=true, ['lightning-attractor']=true}
  local CENSUS_TYPES = {'generator', 'solar-panel', 'accumulator'}
  local OTHER_TYPES = {'fusion-generator', 'burner-generator', 'electric-energy-interface', 'lightning-attractor'}
  local ALL_TYPES = {'generator', 'fusion-generator', 'solar-panel', 'burner-generator', 'electric-energy-interface',
    'lightning-attractor', 'accumulator'}
  M.POWER = {accumulator=true}
  for t in pairs(GEN) do M.POWER[t] = true end
  M.TOP = 4
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  -- A generator's rated output in kW, by name and quality (prototype reads, cached): get_max_power_output (a steam
  -- engine: 15000 J a tick, 900 kW), else get_max_energy_production (a fusion generator: 833333 J a tick, 50 MW).
  local RATED = {}
  local function rating(e)
    local q = try(function() return e.quality.name end) or 'normal'
    local key = e.name .. '@' .. q
    if RATED[key] == nil then
      local p = e.prototype
      local j = try(function() return p.get_max_power_output(q) end)
      if not (j and j > 0) then j = try(function() return p.get_max_energy_production(q) end) end
      RATED[key] = (j or 0) * 60 / 1000
    end
    return RATED[key]
  end
  -- A platform's sunlight as a share of a panel's rating: its location's solar_power_in_space (Aquilo 60, Vulcanus
  -- 600 on a copy of world n), in flight the two ends' by its distance along the connection; nil on a planet (day and
  -- night: there a panel counts what its kind made over the last minute).
  local function space_sun(surface)
    local pl = surface.platform
    if not pl then return nil end
    local l = try(function() return pl.space_location end)
    if l then return (try(function() return l.solar_power_in_space end) or 0) / 100 end
    local c = try(function() return pl.space_connection end)
    if not c then return nil end
    local a, b, d = try(function() return c.from.solar_power_in_space end), try(function() return c.to.solar_power_in_space end), try(function() return pl.distance end)
    if not (a and b and d) then return nil end
    return (a + (b - a) * d) / 100
  end
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
  -- accumulators charging are not consumers. (2.0.77, a copy of world n: an electric network's statistics count what
  -- consumers use as input and what generators make as output.)
  local function draw(stats)
    local fpi = defines.flow_precision_index
    local kw, by, any = 0, {}, false
    for name, all in pairs(try(function() return stats.input_counts end) or {}) do
      local proto = try(function() return prototypes.entity[name] end)
      if not (proto and proto.type == 'accumulator') then
        local v = try(function() return api.flow(stats, name, 'input', fpi.one_minute, nil, all) end) or 0
        local v10 = try(function() return api.flow(stats, name, 'input', fpi.ten_minutes, nil, all) end) or 0
        if v10 > 0 then any = true end
        if v > 0 then by[#by+1] = {name, v * 60 / 1000}; kw = kw + v * 60 / 1000 end
      end
    end
    table.sort(by, function(x, y) return x[2] > y[2] end)
    return kw, by, any
  end
  -- The generator kinds that made power on the network in the last 10 minutes (its statistics' production).
  -- The generator kinds that made power on the network: kW over the last minute, and whether in the last 10 minutes.
  local function produced(stats)
    local fpi = defines.flow_precision_index
    local out = {}
    for name, all in pairs(try(function() return stats.output_counts end) or {}) do
      local proto = try(function() return prototypes.entity[name] end)
      if not (proto and proto.type == 'accumulator') then
        local v10 = try(function() return api.flow(stats, name, 'output', fpi.ten_minutes, nil, all) end) or 0
        if v10 > 0 then
          local v = try(function() return api.flow(stats, name, 'output', fpi.one_minute, nil, all) end) or 0
          out[name] = v * 60 / 1000
        end
      end
    end
    return out
  end
  -- removing: the entities the call removes or would remove (any kind; only its generators and accumulators count).
  -- dry: a dry run (they are not marked yet). Returns lines, or nil when every network it takes a generator from keeps
  -- generation at least as large as its consumers' draw over the last minute.
  function M.after(force, removing, dry)
    local nets, gone = {}, {}
    for _, e in ipairs(removing) do
      if e.valid and M.POWER[e.type] then
        local unit = e.unit_number
        if unit then gone[unit] = true end
        local id = try(function() return e.electric_network_id end)
        if id then
          local n = nets[id]
          if not n then n = {id=id, surface=e.surface, gens=0, accs=0, names={}}; nets[id] = n end
          if GEN[e.type] then n.gens = n.gens + 1; n.names[e.name] = (n.names[e.name] or 0) + 1 else n.accs = n.accs + 1 end
        end
      end
    end
    local lines = {}
    local by_surface = {}
    for id, n in pairs(nets) do
      local stats = n.gens > 0 and api.stats and try(function() return api.stats(id, n.surface) end)
      local kw, by, any = 0, {}, false
      if stats then kw, by, any = draw(stats) end
      if any then
        local key = n.surface.index
        by_surface[key] = by_surface[key] or power_entities(force, n.surface)
        -- a generator left counts when its kind made power on this network in the last 10 minutes (a fusion generator
        -- with no plasma stands and makes nothing); the others are named as staying idle. What those left make: their
        -- kind's output over the last minute, the share of it they are of that kind there.
        local made = produced(stats)
        -- What those left can give: a generator its rated output (it makes what is drawn); on a platform a solar panel
        -- its rating in that place's sunlight; on a planet a solar panel or a lightning attractor what its kind made
        -- over the last minute, the share of it they are (day, night and storms set it).
        local left, acc_j, idle, left_by, rated = 0, 0, {}, {}, {}
        local sun, solar_names = space_sun(n.surface), {}
        for _, e in ipairs(by_surface[key]) do
          if e.valid and not gone[e.unit_number] and try(function() return e.electric_network_id end) == id
            and not e.to_be_deconstructed(force) then
            if not GEN[e.type] then acc_j = acc_j + (try(function() return e.energy end) or 0)
            elseif made[e.name] then
              left = left + 1; left_by[e.name] = (left_by[e.name] or 0) + 1
              if not SUN[e.type] then rated[e.name] = (rated[e.name] or 0) + rating(e)
              elseif e.type == 'solar-panel' and sun then rated[e.name] = (rated[e.name] or 0) + rating(e) * sun; solar_names[e.name] = true end
            else idle[e.name] = (idle[e.name] or 0) + 1 end
          end
        end
        local left_kw, left_words = 0, {}
        for name, c in pairs(left_by) do
          if rated[name] then
            left_kw = left_kw + rated[name]
            left_words[#left_words+1] = string.format('%d %s %s %s', c, name, solar_names[name] and 'in this sunlight' or 'rated', kw_text(rated[name]))
          else
            local share = made[name] * c / (c + (n.names[name] or 0))
            left_kw = left_kw + share
            left_words[#left_words+1] = string.format('%d %s %s over the last minute', c, name, kw_text(share))
          end
        end
        table.sort(left_words)
        if left == 0 or left_kw < kw then
          local going = {}
          for name, c in pairs(n.names) do going[#going+1] = c .. ' ' .. name end
          table.sort(going)
          local top = {}
          for i = 1, math.min(M.TOP, #by) do top[i] = by[i][1] .. ' ' .. kw_text(by[i][2]) end
          local where = n.surface.platform and try(function() return n.surface.platform.name end) or n.surface.name
          local stay = {}
          for name, c in pairs(idle) do stay[#stay+1] = c .. ' ' .. name end
          table.sort(stay)
          local what = left == 0 and 'no generation' or string.format('generation of about %s (%s)', kw_text(left_kw), table.concat(left_words, ', '))
          local short = kw - left_kw
          lines[#lines+1] = string.format('removing these leaves electric network %d on %s with %s: %s go%s%s%s; '
            .. 'its consumers drew %s over the last minute%s; accumulators left %s%s',
            id, where, what, table.concat(going, ', '), (n.accs > 0 and string.format(' with %d accumulator%s', n.accs, n.accs == 1 and '' or 's') or ''),
            #stay > 0 and ', ' .. table.concat(stay, ', ') .. ' stay, of kinds that made no power there in the last 10 minutes' or (left == 0 and ', none other there' or ''),
            dry and '' or ' (marked: they go as robots take them)',
            kw_text(kw), #top > 0 and ' (' .. table.concat(top, ', ') .. ')' or '',
            mj_text(acc_j), (short > 0 and acc_j > 0) and string.format(', about %s at the %s short', span(acc_j / (short * 1000)), kw_text(short)) or '')
        end
      end
    end
    return #lines > 0 and lines or nil
  end
  return M
end
