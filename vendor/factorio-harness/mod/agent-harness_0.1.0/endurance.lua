-- platform_endurance (d15 trajectory analysis: Wayfarer was lost at Aquilo at 11:02 after its rockets, fuel and repair
-- packs ran out; nothing projected the trip before it left): for a planned route, each leg's length and time at the
-- platform's speed, and what its ammunition, repair packs, thruster fuel and oxidizer, power and hub space come to over
-- it at the rates the platform shows now. Facts the platform GUI and the production statistics give: no advice.
-- Rates: the platform surface's production statistics, last 10 minutes (made and used per minute, items and fluids);
-- stock: the hub's main inventory and the turrets (ammunition), the thrusters' and storage tanks' fluid (fuel,
-- oxidizer). Speed: the platform's now while it flies, else the average of its last finished leg (freight.lua's
-- record), else none (times unknown, said). Route: the stops given, else the schedule's from the current one round to
-- it again; a leg with no space connection between its ends is named.
local qflow = require('qflow')   -- (d24 batch152 PX1) statistics read at every quality
return function(api)
  local M = {}
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function round(x, d) if d == 0 then return math.floor(x + 0.5) end local m = 10 ^ (d or 1); return math.floor(x * m + 0.5) / m end
  local function mins(m)
    if not m then return 'unknown' end
    if m >= 60 then return string.format('%dh%02dm', math.floor(m / 60), math.floor(m % 60)) end
    return string.format('%dm%02ds', math.floor(m), math.floor((m % 1) * 60))
  end
  -- The space connection between two locations: its length (km), or nil.
  local function connection(a, b)
    for _, c in pairs(try(function() return prototypes.space_connection end) or {}) do
      local f, t = try(function() return c.from.name end), try(function() return c.to.name end)
      if (f == a and t == b) or (f == b and t == a) then return try(function() return c.length end) end
    end
  end
  -- km per minute: flying now, else the last finished leg's average.
  local function speed(pl)
    local v = try(function() return pl.speed end)
    local last, last_by
    local segs = api.segments and api.segments(pl) or {}
    -- (d20 batch52 K4, Astra #955: Kestrel II's ETA used 62500 km/min from a 1m36 turn back near the solar edge, the
    -- whole connection over a part of it flown) a leg's distance flown along its connection over its time (freight.lua
    -- km0, km1); a leg recorded before those were kept: the connection's length, when it was flown whole
    local from_seg
    for i = #segs, 1, -1 do
      local s = segs[i]
      if s.kind == 'leg' and s['end'] and s.from and s.to and s['end'] > s.start then
        local km = s.km0 and s.km1 and s.km1 - s.km0
        local m = (s['end'] - s.start) / 3600
        if km and km > 0 then
          last, last_by, from_seg = km / m, string.format('the last leg %s->%s: %d km flown in %s', s.from, s.to, math.floor(km + 0.5), mins(m)), s
          break
        elseif not km and not s.partial then
          local len = connection(s.from, s.to)
          if len then last, last_by, from_seg = len / m, string.format('the last leg %s->%s', s.from, s.to), s; break end
        end
      end
    end
    -- the ship it was measured with against the ship now: thrusters and hull width
    if from_seg and (from_seg.thrusters or from_seg.width) and api.geometry then
      local g = try(function() return api.geometry(pl) end) or {}
      local diff = {}
      if from_seg.thrusters and g.thrusters and g.thrusters ~= from_seg.thrusters then diff[#diff+1] = string.format('%d thrusters then, %d now', from_seg.thrusters, g.thrusters) end
      if from_seg.width and g.width and g.width ~= from_seg.width then diff[#diff+1] = string.format('a hull %d tiles wide then, %d now', from_seg.width, g.width) end
      if #diff > 0 then last_by = last_by .. ' (measured on another ship: ' .. table.concat(diff, ', ') .. '; times from it are from the old geometry)' end
    end
    if type(v) == 'number' and v > 0 and try(function() return pl.space_connection end) then
      -- (d20 batch54 N5, Sol #1390) this leg's own measured speed once it has one; the last leg's only while it speeds
      -- up (engine.lua leg_speed)
      if api.leg_speed then
        local sg = segs[#segs]
        local since = sg and sg.kind == 'leg' and not sg['end'] and sg.start and game.tick - sg.start or nil
        local s, by = api.leg_speed(pl, since, last and last / 3600, last_by)
        if s and s > 0 then return s * 3600, by end
      end
      -- speeding up after a departure (A4): the last leg's average when it is higher
      if last and v * 3600 < last * 0.9 then return last, last_by .. ' (it speeds up now, ' .. math.floor(v * 3600) .. ' km/min)' end
      return v * 3600, 'now'
    end
    return last, last_by
  end
  -- The route as stops: given, else the schedule from its current record round to it.
  local function route_of(pl, given)
    if given ~= nil then
      assert(type(given) == 'table' and #given >= 1 and #given <= 12, 'route is a list of 1..12 space locations (planet names)')
      for _, n in ipairs(given) do assert(type(n) == 'string' and prototypes.space_location[n], 'route: unknown space location ' .. tostring(n)) end
      return given, 'given'
    end
    local sch = try(function() return pl.schedule end)
    local recs = sch and sch.records or {}
    local out = {}
    local cur = sch and sch.current or 1
    for k = 0, #recs - 1 do
      local r = recs[(cur - 1 + k) % #recs + 1]
      if r and r.station then out[#out+1] = r.station end
    end
    if #recs > 0 then out[#out+1] = out[1] end
    return out, 'schedule'
  end
  -- What the thrusters and storage tanks hold of each fluid in names; and of it, the storage tanks' (d20 batch60 V5).
  local function fluid_stock(pl, names)
    local out, tanks = {}, {}
    -- (d22 batch96 BF1) the thrusters and tanks of the platform's background read when a count finds no other aboard
    -- (freight.platform_lists), else found: the fuel outlook is read by the platform alerts' scans, flight watches and
    -- this read
    local lists = api.platform_lists and try(function() return api.platform_lists(pl) end)
    for _, e in ipairs(lists and lists.tanks or try(function() return pl.surface.find_entities_filtered{type={'thruster', 'storage-tank'}, force=pl.force} end) or {}) do
      for i = 1, try(function() return #e.fluidbox end) or 0 do
        local f = try(function() return e.fluidbox[i] end)
        if f and names[f.name] then
          out[f.name] = (out[f.name] or 0) + f.amount
          if e.type == 'storage-tank' then tanks[f.name] = (tanks[f.name] or 0) + f.amount end
        end
      end
    end
    return out, tanks
  end
  -- (d22 batch109 BS1) thruster fuel and oxidizer held and in tanks alone, for a flight watch's rows: {name={held, in_tanks}}
  function M.fuel_held(pl)
    local stock, in_tanks = fluid_stock(pl, {['thruster-fuel']=true, ['thruster-oxidizer']=true})
    local out = {}
    for _, name in ipairs({'thruster-fuel', 'thruster-oxidizer'}) do out[name] = {held=math.floor((stock[name] or 0) + 0.5), in_tanks=math.floor((in_tanks[name] or 0) + 0.5)} end
    return out
  end
  -- The fuel outlook (batch27 B1, Luna, on each flight): thruster fuel and oxidizer held (thrusters and tanks), made and
  -- used a minute now (the platform's fluid production statistics, the last minute), and, flying, whether each lasts the
  -- rest of the leg at the speed now; stopped, the thrusters burn nothing. {line, short (fluids that run out before the
  -- leg ends), rows (each with in_tanks: the storage tanks' part of held)}.
  function M.fuel_outlook(pl)
    local names = {['thruster-fuel']=true, ['thruster-oxidizer']=true}
    local stock, in_tanks = fluid_stock(pl, names)
    local stats = try(function() return pl.force.get_fluid_production_statistics(pl.surface) end)
    local P = defines.flow_precision_index or {}
    local function per_min(name, cat)
      return stats and P.one_minute and (try(function() return stats.get_flow_count{name=name, category=cat, precision_index=P.one_minute, count=true} end) or 0) or 0
    end
    local leg = api.leg and try(function() return api.leg(pl) end)
    local v, v_by
    if leg then v, v_by = speed(pl) end
    local left_min = leg and v and v > 0 and leg.left_km / v or nil
    local rows, parts, short = {}, {}, {}
    for _, name in ipairs({'thruster-fuel', 'thruster-oxidizer'}) do
      local held, made, used = stock[name] or 0, per_min(name, 'input'), per_min(name, 'output')
      local row = {name=name, held=math.floor(held + 0.5), in_tanks=math.floor((in_tanks[name] or 0) + 0.5), made_per_min=round(made, 0), used_per_min=round(used, 0)}
      local net = used - made
      local text = string.format('%s %d held, made %d/min, used %d/min', name, row.held, row.made_per_min, row.used_per_min)
      if left_min then
        if net <= 0 then text = text .. ': lasts the leg'
        else
          row.lasts_min = round(held / net, 1)
          if row.lasts_min < left_min then
            row.short_min = round(left_min - row.lasts_min, 1)
            short[#short+1] = name
            text = text .. string.format(': runs out in %s, %s before the leg ends', mins(row.lasts_min), mins(row.short_min))
          else text = text .. string.format(': lasts %s, the leg %s', mins(row.lasts_min), mins(left_min)) end
        end
      end
      rows[#rows+1] = row; parts[#parts+1] = text
    end
    local where = leg and string.format('leg %s->%s, %d km left%s', leg.from, leg.to, math.floor(leg.left_km + 0.5),
      left_min and string.format(', about %s at %d km/min (%s)', mins(left_min), math.floor(v + 0.5), v_by == 'now' and 'its speed now' or tostring(v_by)) or ', speed unknown')
      or 'stopped' .. (try(function() return ' at ' .. pl.space_location.name end) or '') .. ': the thrusters burn only in flight'
    local since = leg and M.since_departure(pl)
    return {line=string.format('%s: %s; %s', pl.name, where, table.concat(parts, '; ')), short=#short > 0 and short or nil, rows=rows,
      leg_left_min=left_min and round(left_min, 1) or nil, since_departure_s=since and since.seconds, samples=since and since.samples,
      since_line=since and since.line}
  end
  -- How long since the platform left its stop and the engine's 60 and 180 s samples side by side (d20 batch54 N1,
  -- viewer Aurora: Kestrel II's fuel alert fired on the start of each leg and cleared by itself): per sample each
  -- thruster fluid used and made a minute and the thrusters' tanks at its start and end, and how much of the sample
  -- the platform spent at the stop before it left (it burns nothing there). {seconds, partial, samples, line} or nil.
  function M.since_departure(pl)
    local segs = api.segments and api.segments(pl) or {}
    local sg = segs[#segs]
    if not (sg and sg.kind == 'leg' and not sg['end'] and sg.start) then return nil end
    local sec = math.floor((game.tick - sg.start) / 60 + 0.5)
    local out = {seconds=sec, partial=sg.partial or nil, samples={}}
    local head = sg.partial and string.format('under way %s since first seen (the departure was before the runtime counted)', mins(sec / 60))
      or string.format('left %s %s ago', sg.from or '?', mins(sec / 60))
    local parts = {}
    local en = api.engine and try(function() return api.engine(pl) end)
    for _, w in ipairs(en and en.windows or {}) do
      local span = w.seconds or 0
      if span > 0 then
        local before = sg.partial and 0 or math.max(0, span - sec)
        local row = {seconds=span, at_stop_s=before, fluids={}}
        local fl = {}
        for _, name in ipairs({'thruster-fuel', 'thruster-oxidizer'}) do
          local f = w.fluids and w.fluids[name]
          if f then
            local used, made = round(f.used * 60 / span, 0), round(f.made * 60 / span, 0)
            row.fluids[name] = {used_per_min=used, made_per_min=made, tanks_first=f.tanks_first, tanks_last=f.tanks_last}
            fl[#fl+1] = string.format('%s used %d/min, made %d/min, thruster tanks %d -> %d', name, used, made, f.tanks_first, f.tanks_last)
          end
        end
        out.samples[#out.samples+1] = row
        parts[#parts+1] = string.format('last %d s%s: %s', span, before > 0 and string.format(' (%d s of it at the stop before it left)', before) or '',
          #fl > 0 and table.concat(fl, ', ') or 'no thrusters')
      end
    end
    out.line = head .. (#parts > 0 and '; samples ' .. table.concat(parts, ' | ') or '; no engine samples yet')
    return out
  end
  local routeammo, ammomodel_
  local function ammomodel()
    ammomodel_ = ammomodel_ or api.ammomodel or require('ammomodel'){stock_places=api.stock_places, ammofeed=api.ammofeed, incoming=api.incoming}
    return ammomodel_
  end
  function M.read(p, a)
    assert(type(a.platform) == 'string', 'platform is required (a platform name)')
    local pl = api.platform(p, a.platform)
    assert(pl.surface, 'platform ' .. pl.name .. ' has no surface yet')
    local stops, route_by = route_of(pl, a.route)
    local v, v_by = speed(pl)
    -- Legs: from where it is (the rest of the leg it flies), then stop to stop.
    local legs, total_km = {}, 0
    local leg_now = api.leg and api.leg(pl)
    local here = try(function() return pl.space_location.name end)
    local start = here
    local route_note
    if leg_now then
      -- A given route read from the leg it flies (d17 batch12 C3, Astra 2x: route [aquilo, fulgora] on the way from
      -- Aquilo to Fulgora projected another round trip): the route's from->to that is this leg starts it there; a route
      -- whose first stop is the one the ship left, going elsewhere, is refused.
      if route_by == 'given' and stops[1] ~= leg_now.to then
        local cut
        for i = 1, #stops - 1 do if stops[i] == leg_now.from and stops[i + 1] == leg_now.to then cut = i; break end end
        if cut then
          for _ = 1, cut do table.remove(stops, 1) end
          route_note = string.format('the route read from the leg it flies now (%s->%s): its stops before %s are behind the ship', leg_now.from, leg_now.to, leg_now.to)
        else
          assert(stops[1] ~= leg_now.from, string.format('route starts at %s, behind the ship: it flies %s->%s now (%d km left); give the route from %s on',
            stops[1], leg_now.from, leg_now.to, math.floor(leg_now.left_km + 0.5), leg_now.to))
        end
      end
      legs[#legs+1] = {from=leg_now.from, to=leg_now.to, km=round(leg_now.left_km, 0), now=true}
      total_km = total_km + leg_now.left_km
      start = leg_now.to
      if stops[1] == start then table.remove(stops, 1) end
    elseif here and stops[1] == here then table.remove(stops, 1) end
    local from = start
    for _, to in ipairs(stops) do
      if from and to ~= from then
        local len = connection(from, to)
        -- No connection of its own (Astra: Fulgora->Vulcanus said "no connection" though the platform flies via Nauvis):
        -- the shortest way through the connections, a leg each hop.
        local route = not len and api.path and api.path(from, to)
        if route then
          for _, h in ipairs(route.hops) do
            legs[#legs+1] = {from=h.from, to=h.to, km=round(h.km, 0), via_for=from .. '->' .. to,
              also=route.also and ('as short through ' .. route.also) or nil}
            total_km = total_km + h.km
          end
        else
          legs[#legs+1] = {from=from, to=to, km=len and round(len, 0) or nil, none=len == nil or nil}
          total_km = total_km + (len or 0)
        end
      end
      from = to
    end
    local total_min = v and v > 0 and total_km / v or nil
    for _, l in ipairs(legs) do l.minutes = v and v > 0 and l.km and round(l.km / v, 1) or nil end
    -- Rates and stock.
    local items_stats = try(function() return pl.force.get_item_production_statistics(pl.surface) end)
    local fluid_stats = try(function() return pl.force.get_fluid_production_statistics(pl.surface) end)
    local P = defines.flow_precision_index or {}
    -- Flying, the window fits inside the leg it flies (d15 blockers, seen but not fixed: soon after departure the 10
    -- minutes held the stop it left): the largest of 10, 5 and 1 minutes no longer than the leg so far; ammunition
    -- from the leg's own counts (freight.lua). A leg first seen under way counts from when it was first seen.
    local win_min, win_p, win_text = 10, P.ten_minutes, nil
    local open_leg
    if leg_now then
      local segs = api.segments and api.segments(pl) or {}
      local sg = segs[#segs]
      if sg and sg.kind == 'leg' and not sg['end'] and sg.start then open_leg = sg end
      local leg_min = open_leg and (game.tick - open_leg.start) / 3600
      if leg_min and leg_min < 10 then
        if leg_min >= 5 and P.five_minutes then win_min, win_p = 5, P.five_minutes
        elseif P.one_minute then win_min, win_p = 1, P.one_minute end
        win_text = leg_min >= 1 and string.format('last %d min, within this leg (%s so far)', win_min, mins(leg_min))
          or string.format('last 1 min, flying %s: the window holds the stop it left too', mins(leg_min))
      end
    end
    -- (PX1) items at every quality; fluids by name (a pair fails there)
    local function flow(stats, name, cat, pi)
      if stats == fluid_stats then return stats.get_flow_count{name=name, category=cat, precision_index=pi, count=true} end
      return qflow.flow(stats, name, cat, pi, true)
    end
    local function rate1(stats, name, cat) return stats and P.one_minute and (try(function() return flow(stats, name, cat, P.one_minute) end) or 0) or 0 end
    local function rate(stats, name, cat) return stats and win_p and (try(function() return flow(stats, name, cat, win_p) end) or 0) / win_min or 0 end
    local function leg_now_rate(name)
      if not (open_leg and open_leg.ammo0 and api.ammo_counts) then return nil end
      local m = (game.tick - open_leg.start) / 3600
      if m <= 0 then return nil end
      local now = try(function() return api.ammo_counts(pl) end) or {}
      local a, b = open_leg.ammo0[name] or {made=0, used=0}, now[name] or {made=0, used=0}
      return math.max(0, b.made - a.made) / m, math.max(0, b.used - a.used) / m, string.format('this leg so far, %s', mins(m))
    end
    local hub = try(function() return pl.hub.get_inventory(defines.inventory.hub_main) end)
    -- Stock in every place aboard (Sol, Astra 06:21-09:37: Tern read 42 rockets in the hub and turrets while 344 more
    -- sat on its belts): the hub, the turrets, belts (an underground pair once), inserter hands and machines' outputs,
    -- every item (an ingredient on a belt counts too). With what the machines aboard can still make from the ingredients
    -- aboard (Astra, d15 15:39: parked Aegis projected rockets 1030 + 36/min to 2650 while about 500 explosives' worth of
    -- ingredients were left; two levels down, fluids too; an ingredient two products draw on split between them, d20
    -- batch51 H1), what rockets bring, and what can reach no turret: the one model the departure, flight and forecast
    -- lines here and the ammo_rates of preflight and the platforms read use (ammomodel.lua).
    local places = api.stock_places and try(function() return api.stock_places(pl, setmetatable({}, {__index=function() return true end})) end)
    -- (d22 batch96 BF1: the trace of a platform of up to 400 belts ran in this call, 64 ms of Kestrel IVb's 201 belts on
    -- a copy of world n) the trace's background read, its age said, as the platforms read and preflight take it
    local model = ammomodel().new(pl, {background=true, places=places or false, rate=function(name, cat, fluid) return rate(fluid and fluid_stats or items_stats, name, cat) end,
      fluid_stock=function(names) return fluid_stock(pl, names) end})
    local held = model.held
    local rows = {}
    -- A rate measured where it is now: flying, the last 10 minutes; stopped, the last finished leg's (ammunition, from
    -- freight.lua's counts at its ends), else unknown (Astra, d15 15:39: parked, thruster fuel read 0 made and 0 used,
    -- which read as lasting for ever): a stop's rate is not a flight's.
    local flying = leg_now ~= nil
    local last_leg
    if not flying then
      local segs = api.segments and api.segments(pl) or {}
      for k = #segs, 1, -1 do
        local sg = segs[k]
        if sg.kind == 'leg' and not sg.partial and sg['end'] and sg['end'] > sg.start and sg.ammo0 and sg.ammo1 then last_leg = sg; break end
      end
    end
    local function leg_rate(name)
      if not last_leg then return nil end
      local m = (last_leg['end'] - last_leg.start) / 3600
      local a, b = last_leg.ammo0[name] or {made=0, used=0}, last_leg.ammo1[name] or {made=0, used=0}
      return math.max(0, b.made - a.made) / m, math.max(0, b.used - a.used) / m, string.format('over the last leg %s->%s, %s', last_leg.from or '?', last_leg.to or '?', mins(m))
    end
    -- The leg the rates come from (flying: this one; stopped: the last finished one), for what moved between places.
    local function moved(name)
      local sg = open_leg or last_leg
      if not (sg and sg.places0 and api.moved_text and places) then return nil end
      return try(function() return api.moved_text(sg.places0, open_leg and places or sg.places1, name) end)
    end
    local function project(name, stock, made, used, unit, from, unknown)
      local row = {name=name, stock=round(stock, 0), made_per_min=round(made, 1), used_per_min=round(used, 1), rate_from=from}
      if unit == nil and places and api.places_text then
        row.by_place = {}
        for _, place in ipairs({'hub', 'turrets', 'belts', 'hands', 'machines'}) do row.by_place[place] = places[place][name] or 0 end
        row.places = api.places_text(places, name)
        row.moved = moved(name)
      end
      unit = unit or ''
      if unknown then
        row.flight_rate = 'unknown'
        row.line = string.format('%s: %s%s now%s; flight use unknown: %s (at the stop, last 10 min: made %g/min, used %g/min)', name, row.stock, unit,
          row.places and ' (' .. row.places .. ')' or '', from, row.made_per_min, row.used_per_min)
        rows[#rows+1] = row
        return
      end
      local cap = made > 0 and unit == '' and model.cap(name) or nil
      -- (K5) made before, and no machine aboard has its recipe now: nothing more counted, said
      if cap and cap.none then row.no_maker = true; cap = nil end
      if cap then
        row.ingredient_limited = {more=cap.more, item=cap.item, have=cap.have, per_craft=cap.per_craft, fluid=cap.fluid, below=cap.below,
          ingredient_made_per_min=cap.ingredient_made_per_min, more_per_min=cap.more_per_min, share=cap.share, shared=cap.shared, other_use_per_min=cap.other_use_per_min}
      end
      -- on rockets launched to it and not arrived (counted once: no other platform's read and not the planet's stock)
      local rec = unit == '' and model.received[name] or 0
      if rec > 0 then row.received = rec end
      if unit == '' and (made > 0 or used > 0) then row.binds = model.binds(name, made, total_min).line end
      -- stock + received + made (capped) - used, and when it reaches 0: the model's (ammomodel.lua)
      if total_min then row.at_end = round(model.left(name, made, used, total_min, stock), 0) end
      if used > 0 then
        local lasts = model.lasts(name, made, used, stock)
        if lasts then
          row.lasts_min = round(lasts, 1)
          local t = 0
          for _, l in ipairs(legs) do
            t = t + (l.minutes or 0)
            if l.minutes and t >= row.lasts_min then row.runs_out_on = l.from .. '->' .. l.to; break end
          end
        end
      end
      row.line = string.format('%s: %s%s now%s, made %g/min, used %g/min (%s)%s%s%s%s%s', name, row.stock, unit, row.places and ' (' .. row.places .. ')' or '',
        row.made_per_min, row.used_per_min, from, row.moved and (open_leg and '; since this leg began: ' or '; over the last leg: ') .. row.moved or '',
        cap and string.format('; ingredient-limited: the ingredients aboard make at most %d more now (%s %d%s aboard%s, %g a craft%s)%s', cap.more, cap.item, cap.have,
          cap.fluid and ' units' or '',
          cap.below and string.format(' and at most %d more from its own ingredients aboard (%s %d)', cap.below.more, cap.below.item, cap.below.have) or '',
          cap.per_craft, cap.ingredient_made_per_min > 0 and string.format('; %s made %g/min aboard', cap.item, cap.ingredient_made_per_min) or '',
          cap.more_per_min > 0 and string.format(', and about %g more a minute at the rates its ingredients are made aboard now', cap.more_per_min) or '') or '',
        (row.received and string.format('; %d more on rockets on their way up, counted', row.received) or '')
          .. (row.no_maker and '; no machine aboard makes it now: the rate made was measured before' or ''),
        row.lasts_min and string.format('; lasts %s at that rate%s', mins(row.lasts_min), row.runs_out_on and ' (runs out on ' .. row.runs_out_on .. ')'
          or (total_min and row.lasts_min >= total_min and ' (past the route\'s end)' or '')) or '',
        row.at_end and string.format('; at the route\'s end about %d%s', math.max(0, row.at_end), unit) or '') .. (row.binds and '; ' .. row.binds or '')
      rows[#rows+1] = row
    end
    local ammo = {}
    for name, item in pairs(prototypes.item) do if item.type == 'ammo' or item.type == 'repair-tool' then ammo[#ammo+1] = name end end
    table.sort(ammo)
    -- Only what can reach a turret (d17 batch13 B1, Kestrel: 610 magazines aboard and a positive forecast while
    -- hundreds sat on a rear loop no turret's feed reached): the ammunition stranded on belts no turret's way reaches,
    -- or in a hub no inserter takes from toward a turret, is left out of the stock projected, and said.
    local ammo_feed
    local tr, tr_why = model.feed, model.feed_why
    local stranded_of, all_held = model.stranded, model.aboard
    -- First the rate each is read at, and its moving rate (B3), so that an ingredient two of them draw on is split by both
    -- rates before any is projected (ammomodel.lua).
    local plan, phase_of = {}, {}
    for _, name in ipairs(ammo) do
      local made, used = rate(items_stats, name, 'input'), rate(items_stats, name, 'output')
      if (held[name] or 0) > 0 or (stranded_of[name] or 0) > 0 or (model.received[name] or 0) > 0 or made > 0 or used > 0 then
        local is_ammo = prototypes.item[name].type == 'ammo'
        local x
        local lm2, lu2, from2
        if flying and win_text and is_ammo then lm2, lu2, from2 = leg_now_rate(name) end
        if lm2 then x = {lm2, lu2, from2}
        elseif flying then x = {made, used, win_text or 'last 10 min, flying'}
        else
          local lm, lu, from = nil, nil, nil
          if is_ammo then lm, lu, from = leg_rate(name) end
          if lm then x = {lm, lu, from}
          else x = {made, used, 'stopped, and no finished leg on record for it', true} end
        end
        plan[#plan+1] = {name=name, x=x}
        local ph = is_ammo and api.phase_rates and try(function() return api.phase_rates(pl, name) end)
        phase_of[name] = ph or nil
        model.make(name, math.max(x[1], ph and ph.moving and ph.moving.made or 0))
      end
    end
    for _, it in ipairs(plan) do
      local name, x = it.name, it.x
      local n_rows = #rows
      project(name, held[name] or 0, x[1], x[2], nil, x[3], x[4])
      local st = stranded_of[name]
      if st and st > 0 and #rows > n_rows then
        local row = rows[#rows]
        row.stranded, row.aboard = st, all_held[name]
        row.line = row.line .. string.format('; %d more aboard can reach no turret (stranded: %s), not counted', st,
          (tr.hub_stranded or {})[name] and 'in the hub, no inserter takes it toward a turret' or 'on belts no turret\'s way reaches: ' .. table.concat(tr.stranded_groups, '; ', 1, math.min(3, #tr.stranded_groups)))
      end
    end
    if tr then
      ammo_feed = string.format('ammunition that can reach a turret %d, stranded %d%s (platform_defense {platform} traces each turret\'s way)', tr.reaches, tr.stranded,
        tr.as_of and ', ' .. tr.as_of or '')
    elseif tr_why then ammo_feed = tr_why .. '; until then stranded ammunition is not told apart' end
    -- Flying (Astra 12:20): the last 60 s apart from the window's average, which holds the leg's stalls and stops.
    if flying and P.one_minute then
      for _, row in ipairs(rows) do
        local m1, u1 = rate1(items_stats, row.name, 'input'), rate1(items_stats, row.name, 'output')
        row.last_minute = {made=round(m1, 1), used=round(u1, 1)}
        row.line = row.line .. string.format('; last 60 s: made %g/min, used %g/min', row.last_minute.made, row.last_minute.used)
      end
    end
    -- Flight apart from drifting and stops (B3, Astra 18:20): each ammunition's rates while moving, still in space
    -- (paused or at speed 0) and stopped at a location, over the last two hours or so (freight.lua phases), and at the
    -- moving rate what the route's flight and its last leg (the return) use.
    for _, row in ipairs(rows) do
      local item = prototypes.item[row.name]
      local ph = item and item.type == 'ammo' and phase_of[row.name]
      if ph then
        local parts = {}
        for _, k in ipairs({'moving', 'still', 'stopped'}) do
          local x = ph[k]
          if x then parts[#parts+1] = string.format('%s %g/min used, %g/min made (%s)', k == 'still' and 'still in space' or k == 'stopped' and 'stopped at a location' or k,
            round(x.used, 1), round(x.made, 1), mins(x.minutes)) end
        end
        row.phases = {}
        for k, x in pairs(ph) do row.phases[k] = {minutes=round(x.minutes, 1), used_per_min=round(x.used, 1), made_per_min=round(x.made, 1)} end
        row.line = row.line .. '; by phase: ' .. table.concat(parts, ', ')
        local mv = ph.moving
        if mv and total_min and total_min > 0 then
          local last = legs[#legs]
          local back = last and last.minutes or nil
          -- made: at most what the ingredients aboard allow (ammomodel.lua, as the row's at_end; d20 batch51 H1)
          local need = mv.used * total_min
          local made = model.made(row.name, mv.made, total_min)
          local have = row.stock + (row.received or 0) + made
          local b = model.binds(row.name, mv.made, total_min)
          row.flight = string.format('at the moving rate the route\'s %s of flight uses about %d, with %d aboard%s and about %d made: %s (%s)%s', mins(total_min), math.floor(need + 0.5),
            row.stock, row.received and string.format(', %d on rockets on their way up', row.received) or '', math.floor(made + 0.5),
            need > have and string.format('%d short', math.ceil(need - have)) or string.format('%d to spare', math.floor(have - need)), b.line,
            back and string.format('; the last leg %s->%s (%s) uses about %d', last.from, last.to, mins(back), math.floor(mv.used * back + 0.5)) or '')
          row.line = row.line .. '; ' .. row.flight
        end
      end
    end
    -- The departure check (Sol 13:50: Swift left with too little ammunition, repeatedly): for each ammunition used over
    -- the route at the rates above, what it needs, what is aboard and made on the way, and a rocket's lift of it.
    local departure = {}
    local lift = try(function() return prototypes.utility_constants.rocket_lift_weight end) or 1000000
    for _, row in ipairs(rows) do
      local item = prototypes.item[row.name]
      if total_min and total_min > 0 and row.used_per_min > 0 and item and item.type == 'ammo' then
        -- made on the way: at most what the ingredients aboard allow, as the row's at_end (ammomodel.lua; d20 batch51 H1:
        -- Kestrel IVa's 828 made against a cap of about 444 in one reply, shift46 15:48)
        local need = row.used_per_min * total_min
        local made = model.made(row.name, row.made_per_min, total_min)
        local have = row.stock + (row.received or 0) + made
        local w = try(function() return item.weight end)
        local per_rocket = w and w > 0 and math.floor(lift / w) or nil
        local short = math.ceil(need - have)
        departure[#departure+1] = string.format('%s over the route (%s): uses about %d at %g/min; %d aboard%s and about %d made on the way: %s (%s)%s',
          row.name, mins(total_min), math.floor(need + 0.5), row.used_per_min, row.stock, row.received and string.format(', %d on rockets on their way up', row.received) or '',
          math.floor(made + 0.5), short > 0 and string.format('%d short', short) or string.format('%d to spare', -short), model.binds(row.name, row.made_per_min, total_min).line,
          per_rocket and string.format('; a rocket lifts %d of it%s', per_rocket, short > 0 and string.format(' (%d rocket%s for the shortfall)', math.ceil(short / per_rocket), math.ceil(short / per_rocket) == 1 and '' or 's') or '') or '')
      end
    end
    local fluids = {['thruster-fuel']=true, ['thruster-oxidizer']=true}
    local fstock = fluid_stock(pl, fluids)
    for _, name in ipairs({'thruster-fuel', 'thruster-oxidizer'}) do
      if try(function() return prototypes.fluid[name] end) then
        local made, used = rate(fluid_stats, name, 'input'), rate(fluid_stats, name, 'output')
        if (fstock[name] or 0) > 0 or made > 0 or used > 0 then
          if flying then project(name, fstock[name] or 0, made, used, ' units', win_text or 'last 10 min, flying')
          else project(name, fstock[name] or 0, made, used, ' units', 'stopped; the thrusters burn only in flight', true) end
        end
      end
    end
    -- Hub space: free slots now.
    local slots = hub and #hub or 0
    local free = hub and try(function() return hub.count_empty_stacks() end) or 0
    -- Power: what the platform's network makes and draws now (a pole on it, else the surface's own network: PX1,
    -- Asterion has no pole), every quality (PX1), and the solar power at each stop.
    local power
    local pole = try(function() return pl.surface.find_entities_filtered{type='electric-pole', force=pl.force, limit=1}[1] end)
    local st = pole and try(function() return pole.electric_network_statistics end)
      or try(function() return pl.surface.has_global_electric_network and pl.surface.global_electric_network_statistics end) or nil
    if st and P.five_seconds then
      local function sum(cat, counts)
        local n = 0
        for name, all in pairs(counts or {}) do n = n + (try(function() return qflow.flow(st, name, cat, P.five_seconds, nil, all) end) or 0) end
        return n * 60 / 1000
      end
      power = string.format('makes %d kW, draws %d kW now', math.floor(sum('output', st.output_counts) + 0.5), math.floor(sum('input', st.input_counts) + 0.5))
    end
    -- Solar capacity here against the draw (Astra 12:20): the panels' peak at this location's solar power, and the
    -- machines on low or no power now, as their status icons show.
    local panels, peak = 0, 0
    for _, e in ipairs(try(function() return pl.surface.find_entities_filtered{type='solar-panel', force=pl.force} end) or {}) do
      panels = panels + 1
      peak = peak + ((try(function() return e.prototype.get_max_energy_production(e.quality) end) or try(function() return e.prototype.max_energy_production end) or 0) * 60 / 1000)
    end
    -- at a stop, the location's solar power in space (the platform surface's own property read 100 at Gleba's 200%)
    local sp = here and try(function() return prototypes.space_location[here].solar_power_in_space end)
    local low, none = 0, 0
    local LOW, NONE = try(function() return defines.entity_status.low_power end), try(function() return defines.entity_status.no_power end)
    for _, e in ipairs(try(function() return pl.surface.find_entities_filtered{force=pl.force, type={'assembling-machine', 'furnace', 'inserter', 'ammo-turret', 'asteroid-collector', 'radar', 'roboport', 'lab', 'beacon'}} end) or {}) do
      local stt = try(function() return e.status end)
      if stt and stt == LOW then low = low + 1 elseif stt and stt == NONE then none = none + 1 end
    end
    local solar_line = panels > 0 and string.format('%d solar panels: %d kW at full sun%s; %d machines on low power, %d on no power now', panels, math.floor(peak + 0.5),
      sp and string.format(', about %d kW at %s\'s %d%% solar power', math.floor(peak * sp / 100 + 0.5), here, math.floor(sp + 0.5)) or ' (flying: the stops\' solar power is on the hub line)', low, none)
      or string.format('no solar panels; %d machines on low power, %d on no power now', low, none)
    local solar = {}
    local seen = {}
    for _, l in ipairs(legs) do
      for _, n in ipairs({l.from, l.to}) do
        if n and not seen[n] then
          seen[n] = true
          local sp = try(function() return prototypes.space_location[n].solar_power_in_space end)
          if sp then solar[#solar+1] = string.format('%s %d%%', n, math.floor(sp + 0.5)) end
        end
      end
    end
    -- Asteroid chunks made on the platform, a minute over the rates' window (the production statistics: the collectors'
    -- catch and the crushers' returns together; d24 batch143 PO1: not what the collectors caught)
    local chunks = {}
    for name in pairs(prototypes.item) do
      if name:find('%-asteroid%-chunk$') then
        local m = rate(items_stats, name, 'input')
        if m > 0 then chunks[#chunks+1] = string.format('%s %g/min', name, round(m, 1)) end
      end
    end
    table.sort(chunks)
    -- forecast (E11, routeammo.lua): per leg, the asteroids its connection spawns, shots per asteroid of each ammunition
    -- aboard, and the use scaled from the legs flown; pessimistic {speed, dwell_s}.
    local forecast, forecast_damage, forecast_coverage, forecast_targets
    if a.forecast then
      assert(a.forecast == true, 'forecast is true')
      local pe = a.pessimistic
      assert(pe == nil or type(pe) == 'table', 'pessimistic is {speed: 0.1..1, dwell_s: 0..36000}')
      if pe then
        assert(pe.speed == nil or (type(pe.speed) == 'number' and pe.speed >= 0.1 and pe.speed <= 1), 'pessimistic.speed is 0.1..1 (a share of the speed read)')
        assert(pe.dwell_s == nil or (type(pe.dwell_s) == 'number' and pe.dwell_s >= 0 and pe.dwell_s <= 36000), 'pessimistic.dwell_s is 0..36000')
      end
      routeammo = routeammo or require('routeammo'){segments=api.segments, ammorate=api.ammorate, damages=api.ammo_damages}
      local ammo = {}
      for _, row in ipairs(rows) do
        local item = prototypes.item[row.name]
        if item and item.type == 'ammo' then ammo[#ammo+1] = row end
      end
      forecast, forecast_damage, forecast_coverage, forecast_targets = routeammo.forecast(pl, legs, ammo, pe, model)
    end
    local legs_text = {}
    for _, l in ipairs(legs) do
      legs_text[#legs_text+1] = string.format('%s->%s %s km, %s%s', l.from, l.to, l.km and tostring(l.km) or '?', l.minutes and mins(l.minutes) or 'time unknown',
        l.now and ' (the rest of the leg it flies)' or l.none and ' (no space connection between them)'
          or l.via_for and ' (on the way ' .. l.via_for .. (l.also and ', ' .. l.also or '') .. ')' or '')
    end
    local outlook = try(function() return M.fuel_outlook(pl).line end)
    return {platform=pl.name, route=route_by, route_note=route_note, ammo_feed=ammo_feed, legs=legs, total_km=round(total_km, 0), total_minutes=total_min and round(total_min, 1) or nil,
      speed_km_per_min=v and round(v, 1) or nil, speed_from=v_by or 'unknown: stopped, and no finished leg on record (times unknown)',
      resources=rows, hub_slots=string.format('%d of %d free', free, slots), power=power, solar_power=#solar > 0 and table.concat(solar, ', ') or nil,
      lines={'route: ' .. (#legs_text > 0 and table.concat(legs_text, '; ') or 'no legs') .. (total_min and '; in all ' .. mins(total_min) or ''),
        'hub: ' .. string.format('%d of %d slots free', free, slots) .. (power and '; power ' .. power or '') .. (#solar > 0 and '; solar power ' .. table.concat(solar, ', ') or ''),
        'asteroid chunks made (production statistics: the collectors\' catch and the crushers\' returns): ' .. (#chunks > 0 and table.concat(chunks, ', ') or 'none') .. ' (' .. (win_text or 'last 10 min') .. ')'
          .. (places and places.capped and string.format('; belts past the first %d not counted', places.capped) or ''),
        'power: ' .. solar_line .. (power and ' (the network ' .. power .. ')' or ''), 'fuel outlook: ' .. (outlook or 'unread'), ammo_feed},
      solar=solar_line, low_power=low, no_power=none, fuel_outlook=outlook,
      departure=#departure > 0 and departure or nil, forecast=forecast,
      forecast_damage=forecast_damage and #forecast_damage > 0 and forecast_damage or nil,
      forecast_coverage=forecast_coverage and #forecast_coverage > 0 and forecast_coverage or nil,
      forecast_targets=forecast_targets and #forecast_targets.ammo > 0 and forecast_targets or nil,
      chunks_made=#chunks > 0 and chunks or nil,
      note='rates: flying, the platform\'s production statistics over the last 10 minutes (on a leg younger than that, the last 5 or 1 minute within the leg, and ammunition from the leg\'s own counts); stopped, the last finished leg\'s for ammunition (rate_from), else the flight rate is unknown and nothing is projected; a rate that changes on the way (fights near a planet, thrust) changes the projection'}
  end
  M.schema = {platform_endurance = {forecast='true: forecast, per leg of the route: the asteroids its space connection spawns by kind (the game\'s spawn chance, its mean over the leg; beside it, the legs flown in the last 2 hours, each over the part of its connection flown), for each ammunition aboard the shots one asteroid of each kind takes (its health against the damage after resistances and our bonuses; none hurt: under 1 a hit), and the use: the moving rate on the legs flown scaled by how much more shooting this leg\'s asteroids take, what is made meanwhile, and what is left at each arrival. An estimate from prototypes and measured rates; a shot\'s damage is platform_defense ammo_use\'s (bonuses researched, ammo quality), the "damage a shot" lines give each asteroid\'s resistance arithmetic, forecast_damage [{ammo, turret, damage_per_shot, asteroid, hp, per_hit, shots}]; the calibration: the legs flown in the last 2 hours and the one flown now, each with the part of its connection flown (from freight\'s distance along it), their asteroids the game\'s spawn chance over that part; each route leg says how much of it the legs flown cover and that the rest is the game\'s spawn definition, not measured: forecast_coverage [{leg, flown (the parts flown, joined, the way the leg flies), flights, covered (0..1)}]; (turret targets) the shots count for each ammunition only the asteroids its turrets target as built (each turret\'s priority list: with ignore unprioritised targets on, the listed ones only; off, any), and an asteroid no turret aboard targets counts for none, nor its fragments; an asteroid targeted by turrets of two ammunitions counts in full for each: forecast_targets {ammo [{ammo, turrets, settings [{turret, count, targets (names, any, or unknown)}], mixed}], asteroids [{asteroid, turrets [{turret, count, ammo}]}]}',
    pessimistic='with forecast: {speed: 0.1..1 (a share of the speed read: slower, longer legs), dwell_s: 0..36000 (extra time at each stop at the stopped rate)}',
    platform='platform name', route='optional list of space locations to fly through in order (default: its schedule from the current stop round to it again)',
    returns='fuel_outlook (one line: thruster fuel and oxidizer held in thrusters and tanks, made and used a minute over the last minute, and flying whether each lasts the rest of the leg at the speed now; its owners get a team alert when one runs out before the leg ends, with how long since the platform left its stop and the engine\'s last 60 and 180 s side by side: each fluid used and made a minute, the thrusters\' tanks at start and end, and the seconds of each sample spent at the stop before it left); each ammunition row adds phases {moving, still, stopped: minutes, used_per_min, made_per_min} (moving: flying, not paused; still: in space, paused or at speed 0; stopped: at a location; recent hours count most) and flight (at the moving rate: what the route\'s flight and its last leg use against what is aboard and made); departure (each ammunition used on the route: what the route uses at the rates read, what is aboard and made on the way, short or to spare, and a rocket\'s lift of it); solar (the solar panels\' peak, at a stop at its solar power, and the machines on low or no power now) with low_power and no_power; flying, each resource line adds the last 60 s apart (last_minute {made, used}); legs [{from, to, km, minutes}], total_km, total_minutes, speed_km_per_min and speed_from (flying: this leg\'s own once its last 60 s are all in the leg and not rising (their mean), the last leg\'s while it speeds up and is under 90% of it, else its speed now, each said; stopped: the last finished leg\'s average; the fuel outlook, the legs\' minutes and the forecast use it), resources [{name, stock (every place aboard), by_place {hub, turrets, belts (an underground pair once), hands (inserters), machines (outputs)}, places, moved (each place\'s change since the leg the rates come from began: loading told from use), made_per_min, used_per_min, rate_from, flight_rate (unknown: stopped with no flight rate on record; nothing projected), ingredient_limited {more, item, have, per_craft, fluid, below {more, item, have}, ingredient_made_per_min, more_per_min, share, shared {product: share}, other_use_per_min} (made from ingredients aboard, two levels down, fluids in tanks and the makers counted: at most more now, growing by more_per_min at the rates the ingredients are made aboard now; an ingredient two products draw on split by their make rates, other machines\' use of it taken off first), received (on rockets launched to it and not arrived, counted once), binds (which limit sets what is made over the route: the stock, the make rate or an ingredient; flight, departure, forecast and preflight\'s ammo_rates count the same way), lasts_min, runs_out_on, at_end, line}] for each ammunition and repair pack aboard or used, thruster-fuel and thruster-oxidizer, hub_slots, power, solar_power at the stops, chunks_made (asteroid chunks made a minute: the production statistics, the collectors\' catch and the crushers\' returns), lines; read only'}}
  return M
end
