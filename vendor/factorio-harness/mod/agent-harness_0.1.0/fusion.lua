-- fusion: a fusion reactor read (d21 batch64 Z6, Astra #1655: a pair with 8 generators ran, power gave 400 MW
-- nameplate, and inspect on a reactor had no neighbour bonus or plasma output, so adjacency could not be told from
-- ports that only touch). Read on 2.0.77 (private copy):
--   * LuaEntity.neighbour_bonus refuses a fusion reactor ("Entity is not reactor"; it is a reactor's) and LuaFluidBox
--     has no flow read; the prototype gives neighbour_bonus 1, get_fluid_usage_per_tick(quality) 0.0667 (4 a second;
--     uncommon 1.3x, rare 1.6x, epic 1.9x, legendary 2.5x) and get_max_energy_usage 166667 J a tick (10 MW electric,
--     every quality); its burner takes fusion power cells (40 GJ);
--   * its neighbours are the prototype's neighbour_connectable: two points on each side (plasma sides and coolant
--     sides; every point pairs with either kind), a reactor whose point lies within neighbour_search_distance (0.7) of
--     one of its own facing the other way. A pair joined plasma to plasma read 2,000,000 C; a lone reactor 1,000,000
--     C; a reactor joined to another only coolant side to coolant side (no plasma between them) read 1,207,916 then
--     1,302,561 C while that one ran: the coolant side gives the bonus too; an east-facing one whose plasma side met a
--     north one's coolant side shared no fluid connection with it and both made plasma at 2,000,000 C; the same pair
--     with one 2 tiles further along (points apart) made 1,000,000 C each. Fluid connections do not tell neighbours.
--     Its plasma box (fluidbox 2) is one fluid segment with the reactors and generators it joins;
--   * each coolant unit takes 25 MJ of fuel (fusion-plasma heat capacity 25 x its default 1,000,000 C) and becomes one
--     plasma unit: a lone reactor at its most burnt 100.0 MW of fuel for 4.000 coolant a second, plasma at 1,000,000
--     C; a pair's shared plasma read 2,000,000 C; with 4 generators on a 150 MW load the pair burnt 100.0 + 20.7 MW of
--     fuel and its generators made 162.07 MW (the fuel and 41.4 MW more: each reactor's fuel times 1 + the bonus times
--     how hard its neighbour ran, 20.7% and 100%); with 8 generators both burnt 100.0 MW, 8.0 plasma a second, and
--     the generators made 392 MW on a 370 MW load plus the reactors' 20 MW (at most 400);
--   * the force's fluid production statistics counted none of the coolant or plasma (0 a second).
-- (Z7, Astra #1672: measured read over_s 30 with 31 samples while sampling lasts 10 min) measured is a rolling window
-- of the last KEEP samples (30 s); totals add up the whole stretch since sampling began: fuel burnt, seconds covered,
-- seconds burning, and gaps (seconds in which cells were put in, their burn unknown).
-- Reads sample the reactors read (and those the harness builds) every SAMPLE ticks for WATCH ticks: the fuel each
-- holds (burning plus cells) gives fuel burnt per second, measured; coolant in and plasma out follow from it at 25 MJ
-- a unit (derived), and the bonus at full from the prototype and the connected reactors (formula).
return function(api)
  local M = {}
  local SAMPLE, KEEP, WATCH, MAX_WATCH = 60, 31, 36000, 64
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function store()
    local s = api.state()
    s.fusion = s.fusion or {watch={}}
    return s.fusion
  end
  local function at(p) return string.format('(%g,%g)', p.x, p.y) end
  local function mw(w) return math.floor(w / 1e5 + 0.5) / 10 end
  -- Fuel held in J: what burns now and the cells in its slot.
  local function fuel_j(e)
    local b = try(function() return e.burner end)
    if not b then return nil end
    local j = try(function() return b.remaining_burning_fuel end) or 0
    local inv = try(function() return b.inventory end)
    for i = 1, inv and #inv or 0 do
      local st = inv[i]
      if st and st.valid_for_read then j = j + st.count * (try(function() return st.prototype.fuel_value end) or 0) end
    end
    return j
  end
  -- Energy a plasma unit carries per degree, and the plasma's base temperature (a lone reactor's).
  local function plasma()
    local f = prototypes.fluid['fusion-plasma']
    return f and f.heat_capacity or 25, f and f.default_temperature or 1e6
  end
  function M.watch(e)
    if not (e and e.valid and e.type == 'fusion-reactor' and e.unit_number) then return end
    local w = store().watch
    local row = w[e.unit_number]
    if not row then
      local n, oldest = 0, nil
      for k, r in pairs(w) do n = n + 1; if not oldest or r.until_tick < w[oldest].until_tick then oldest = k end end
      if n >= MAX_WATCH and oldest then w[oldest] = nil end
      row = {e=e, samples={}, total={since=game.tick, fuel=0, covered=0, running=0, gaps=0, gap_ticks=0, put_in=0}}
      w[e.unit_number] = row
      row.samples[1] = {tick=game.tick, fuel=fuel_j(e)}
    end
    row.total = row.total or {since=game.tick, fuel=0, covered=0, running=0, gaps=0, gap_ticks=0, put_in=0}
    row.until_tick = game.tick + WATCH
    return row
  end
  function M.tick(tick)
    if tick % SAMPLE ~= 0 then return end
    local w = store().watch
    for k, r in pairs(w) do
      if not r.e.valid or tick > r.until_tick then w[k] = nil
      else
        local last = r.samples[#r.samples]
        local now = {tick=tick, fuel=fuel_j(r.e)}
        r.samples[#r.samples+1] = now
        while #r.samples > KEEP do table.remove(r.samples, 1) end
        -- (Z7) totals over the whole stretch since sampling began: a step where the fuel held rose (cells put in) is a
        -- gap, its burn unknown; the rest is covered, and running where fuel fell
        local t = r.total
        if t and last and last.fuel and now.fuel then
          local dt = tick - last.tick
          if now.fuel > last.fuel then t.gaps, t.gap_ticks, t.put_in = t.gaps + 1, t.gap_ticks + dt, t.put_in + now.fuel - last.fuel
          else
            t.covered, t.fuel = t.covered + dt, t.fuel + last.fuel - now.fuel
            if now.fuel < last.fuel then t.running = t.running + dt end
          end
        end
      end
    end
  end
  -- A neighbour point's offset turned with the entity (direction 0..15, 4 a quarter turn clockwise).
  local function turn(p, d)
    local x, y = p.x, p.y
    for _ = 1, math.floor((d or 0) / 4) % 4 do x, y = -y, x end
    return x, y
  end
  -- An entity's neighbour points in the world: {x, y, dir, category}.
  local function points(e)
    local nc = try(function() return e.prototype.neighbour_connectable end)
    local out = {}
    for _, c in ipairs(nc and nc.connections or {}) do
      local d = nc.affected_by_direction and (e.direction or 0) or 0
      local x, y = turn(c.location.position, d)
      out[#out+1] = {x=e.position.x + x, y=e.position.y + y, dir=((c.location.direction or 0) + d) % 16, category=c.category, takes=c.neighbour_category}
    end
    return out, nc and nc.neighbour_search_distance or 0.7
  end
  local function takes(list, cat)
    for _, c in ipairs(list or {}) do if c == cat then return true end end
    return false
  end
  -- The reactors whose neighbour points meet its own (each once, with the kinds of side that meet), and the
  -- generators its plasma box joins.
  local function joined(e)
    local mine, reach = points(e)
    local reactors = {}
    for _, o in ipairs(try(function() return e.surface.find_entities_filtered{type='fusion-reactor', position=e.position, radius=8, limit=16} end) or {}) do
      if o.valid and o ~= e then
        local sides = {}
        for _, q in ipairs((points(o))) do
          for _, m in ipairs(mine) do
            if (m.dir + 8) % 16 == q.dir and math.abs(m.x - q.x) <= reach and math.abs(m.y - q.y) <= reach and takes(m.takes, q.category) and takes(q.takes, m.category) then
              sides[(m.category or ''):gsub('^fusion%-reactor%-', '') .. '-' .. (q.category or ''):gsub('^fusion%-reactor%-', '')] = true
            end
          end
        end
        if next(sides) then
          local list = {}
          for k in pairs(sides) do list[#list+1] = k end
          table.sort(list)
          reactors[#reactors+1] = {e=o, sides=table.concat(list, ', ')}
        end
      end
    end
    local gens, seen = 0, {}
    for _, c in ipairs(try(function() return e.fluidbox.get_connections(2) end) or {}) do
      local o = c.owner
      if o and o.valid and o.type == 'fusion-generator' and not seen[o.unit_number or o] then seen[o.unit_number or o] = true; gens = gens + 1 end
    end
    return reactors, gens
  end
  -- Fuel burnt a second over the samples kept; a step where the fuel held rose (a cell put in) is left out, its time too.
  local function measured(row)
    local s = row and row.samples or {}
    if #s < 2 then return nil end
    local burnt, ticks = 0, 0
    for i = 2, #s do
      if s[i].fuel and s[i-1].fuel and s[i-1].fuel >= s[i].fuel then burnt = burnt + s[i-1].fuel - s[i].fuel; ticks = ticks + s[i].tick - s[i-1].tick end
    end
    if ticks <= 0 then return nil end
    return {fuel_w=burnt / ticks * 60, secs=(s[#s].tick - s[1].tick) / 60, samples=#s}
  end
  -- One reactor: {neighbours, generators, neighbour_bonus, max, now, measured, line}.
  function M.read(e)
    if not (e and e.valid and e.type == 'fusion-reactor') then return nil end
    local row = M.watch(e)
    local proto, q = e.prototype, try(function() return e.quality end)
    local hc, t0 = plasma()
    local per = try(function() return proto.neighbour_bonus end) or 0
    local units = (try(function() return proto.get_fluid_usage_per_tick(q) end) or 0) * 60
    local fuel_max = units * hc * t0
    local reactors, gens = joined(e)
    local out = {neighbours={}, generators=gens}
    for _, r in ipairs(reactors) do out.neighbours[#out.neighbours+1] = {x=r.e.position.x, y=r.e.position.y, sides=r.sides} end
    out.max = {quality=q and q.name ~= 'normal' and q.name or nil, coolant_per_s=units, plasma_per_s=units, fuel_mw=mw(fuel_max),
      electric_mw=mw((try(function() return proto.get_max_energy_usage(q) end) or 0) * 60),
      plasma_mw_alone=mw(fuel_max), plasma_mw_with_neighbours=mw(fuel_max * (1 + per * #reactors)),
      source='prototype at its quality; plasma MW: fuel MW x (1 + neighbour_bonus x connected reactors), each running at its most (formula)'}
    out.neighbour_bonus = {per_neighbour=per, connected=#reactors, at_full=per * #reactors,
      source='prototype neighbour_bonus x the reactors whose neighbour points meet its own, plasma or coolant side (formula); the game gives no bonus read for a fusion reactor'}
    local b = try(function() return e.burner end)
    local pl = try(function() return e.fluidbox[2] end)
    local co = try(function() return e.fluidbox[1] end)
    local cells = b and try(function() return b.inventory.get_item_count() end) or 0
    out.now = {status=e.status, plasma=pl and {amount=math.floor(pl.amount * 100 + 0.5) / 100, temperature=math.floor(pl.temperature + 0.5)} or nil,
      coolant=co and {name=co.name, amount=math.floor(co.amount * 10 + 0.5) / 10} or nil,
      fuel={burning=b and try(function() return b.currently_burning.name.name end) or nil, remaining_mj=b and math.floor((try(function() return b.remaining_burning_fuel end) or 0) / 1e6 + 0.5) or nil, cells=cells},
      source='read now; the plasma box is one fluid segment with the reactors and generators it joins, so its temperature is theirs mixed'}
    if pl and pl.temperature then out.now.plasma.bonus_seen = math.floor((pl.temperature / t0 - 1) * 100 + 0.5) / 100 end
    local m = measured(row)
    if m then
      local u = m.fuel_w / (hc * t0)
      out.measured = {window=string.format('rolling: the last %d s (%d samples 1 s apart)', (KEEP - 1) * SAMPLE / 60, KEEP), over_s=math.floor(m.secs + 0.5), samples=m.samples, fuel_mw=mw(m.fuel_w), running_pct=fuel_max > 0 and math.floor(100 * m.fuel_w / fuel_max + 0.5) or nil,
        coolant_per_s=math.floor(u * 1000 + 0.5) / 1000, plasma_per_s=math.floor(u * 1000 + 0.5) / 1000,
        source=string.format('fuel_mw measured from the fuel it held, sampled every %d s; coolant and plasma a second derived from it at %g MJ a unit (one coolant unit makes one plasma unit)', SAMPLE / 60, hc * t0 / 1e6)}
      -- (formula) its bonus now: neighbour_bonus x each connected reactor's measured running share
      local share, known = 0, 0
      for _, r in ipairs(reactors) do
        local rm = measured(store().watch[r.e.unit_number])
        if rm and fuel_max > 0 then share = share + rm.fuel_w / fuel_max; known = known + 1 end
        M.watch(r.e)
      end
      if known == #reactors then
        out.measured.bonus_estimate = math.floor(per * share * 100 + 0.5) / 100
        out.measured.plasma_mw_estimate = mw(m.fuel_w * (1 + per * share))
      end
    else
      for _, r in ipairs(reactors) do M.watch(r.e) end
      out.measured = {note=string.format('sampling began at this read (every %d s, kept %d min after the last read): read again for fuel burnt, coolant and plasma a second', SAMPLE / 60, WATCH / 3600)}
    end
    -- (Z7) sampling: when it began and ends, and the totals since it began (measured)
    out.sampling = {began_tick=row.total and row.total.since, ends_tick=row.until_tick,
      note=string.format('sampled every %d s while read: kept up %d s after the last read (each read extends it); measured is a rolling %d s window, totals cover the whole stretch since sampling began', SAMPLE / 60, WATCH / 60, (KEEP - 1) * SAMPLE / 60)}
    local t = row.total
    if t and t.covered + t.gap_ticks > 0 then
      out.totals = {since_s=math.floor((game.tick - t.since) / 60 + 0.5), covered_s=math.floor(t.covered / 60 + 0.5), running_s=math.floor(t.running / 60 + 0.5),
        fuel_mj=math.floor(t.fuel / 1e6 + 0.5), fuel_mw_avg=t.covered > 0 and mw(t.fuel / t.covered * 60) or nil,
        running_pct=t.covered > 0 and fuel_max > 0 and math.floor(100 * t.fuel / t.covered * 60 / fuel_max + 0.5) or nil,
        gaps=t.gaps, gap_s=math.floor(t.gap_ticks / 60 + 0.5), put_in_mj=t.gaps > 0 and math.floor(t.put_in / 1e6 + 0.5) or nil,
        source='measured: fuel burnt over the covered seconds since sampling began; a gap is a second in which the fuel held rose (cells put in), its burn not counted; running: seconds in which it burnt fuel'}
    end
    local nb = {}
    for _, p in ipairs(out.neighbours) do nb[#nb+1] = at(p) .. ' (' .. p.sides .. ')' end
    out.line = string.format('fusion-reactor %s: %s; %d generator%s on its plasma ports; at most %g coolant and plasma a second, %.1f MW of fuel, %.1f MW of plasma alone, %.1f MW with its neighbours running (formula); %s',
      at(e.position), #nb > 0 and ('neighbour reactor' .. (#nb > 1 and 's ' or ' ') .. table.concat(nb, ', ') .. string.format(', bonus %g at full', per * #reactors)) or 'no neighbour reactor (none whose side points meet its own), bonus 0',
      gens, gens == 1 and '' or 's', units, out.max.fuel_mw, out.max.plasma_mw_alone, out.max.plasma_mw_with_neighbours,
      (out.measured.fuel_mw and string.format('measured over the last %d s (rolling): %.1f MW of fuel (%d%%), %.3f coolant and plasma a second (derived)%s', out.measured.over_s, out.measured.fuel_mw, out.measured.running_pct or 0,
        out.measured.coolant_per_s, out.measured.plasma_mw_estimate and string.format(', about %.1f MW of plasma with the bonus its neighbours give now (estimate)', out.measured.plasma_mw_estimate) or '')
        or 'no rates yet: sampling began at this read')
      .. (out.totals and string.format('; since sampling began %d s ago: %d MJ of fuel over %d s covered (%s MW average, %s%%), burning %d s, %d gap%s (%d s, cells put in)',
        out.totals.since_s, out.totals.fuel_mj, out.totals.covered_s, tostring(out.totals.fuel_mw_avg or 0), tostring(out.totals.running_pct or 0), out.totals.running_s,
        out.totals.gaps, out.totals.gaps == 1 and '' or 's', out.totals.gap_s) or '')
      .. string.format('; sampling ends %d s from now unless read again', math.max(0, math.floor((row.until_tick - game.tick) / 60))))
    return out
  end
  return M
end
