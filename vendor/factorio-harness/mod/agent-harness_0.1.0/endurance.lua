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
  -- (d25 batch208 QU1) the most a call takes, also a queue step's check (runtime.lua step_lengths)
  M.ROUTE_MAX = 12
  local STARTUP_S = 60  -- (d29 batch339) a leg's first minute: what the return budget's window leaves out
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function round(x, d) if d == 0 then return math.floor(x + 0.5) end local m = 10 ^ (d or 1); return math.floor(x * m + 0.5) / m end
  local function mins(m)
    if not m then return 'unknown' end
    if m >= 60 then return string.format('%dh%02dm', math.floor(m / 60), math.floor(m % 60)) end
    return string.format('%dm%02ds', math.floor(m), math.floor((m % 1) * 60))
  end
  -- The space connection between two locations: its length (km), or nil. (d28 batch304 EC) The connections read once a
  -- session: prototypes do not change while the game runs.
  local CONN
  local function connection(a, b)
    if not CONN then
      CONN = {}
      for _, c in pairs(try(function() return prototypes.space_connection end) or {}) do
        local f, t = try(function() return c.from.name end), try(function() return c.to.name end)
        local len = try(function() return c.length end)
        if f and t and len then CONN[f .. '>' .. t] = CONN[f .. '>' .. t] or len; CONN[t .. '>' .. f] = CONN[t .. '>' .. f] or len end
      end
    end
    return CONN[a .. '>' .. b]
  end
  -- (d28 batch304 EC, Updates row endurance-cost: the plain read took 13-14 ms on world n and 17-20 ms on a copy of it,
  -- most of it a dozen finds over the platform's whole surface, about 0.3 ms a find plus 1 us an entity found, on the
  -- copy and on world n alike) The entities the plain read looks at, sorted by type: the thrusters and tanks (fluids),
  -- the turrets and machines (stock), the machines for the status count, the solar panels, the pumps (fuel makers).
  -- Found once and kept by platform in storage (only the entities, never what they hold); each call counts those types
  -- aboard and checks each kept one is still valid, and finds them again when the count differs or one is gone (one
  -- built, removed or replaced). Resolute's 1027 on world n: found and sorted 1.9 ms; counted and checked 0.6. ctx is
  -- the call's: {pl, by {type: list}, tanks (thrusters and storage tanks), machines (assembling machines and furnaces)};
  -- STATUS: the types the status count reads.
  local SCAN = {'thruster', 'storage-tank', 'pump', 'ammo-turret', 'assembling-machine', 'furnace', 'inserter', 'electric-turret',
    'asteroid-collector', 'radar', 'roboport', 'lab', 'beacon', 'solar-panel'}
  local STATUS = {['assembling-machine']=true, furnace=true, inserter=true, ['ammo-turret']=true, ['electric-turret']=true,
    ['asteroid-collector']=true, radar=true, roboport=true, lab=true, beacon=true}
  local function status_of(e) return e.status end
  local SCAN_KEY = table.concat(SCAN, ',')   -- a record of another list of types is found again
  local SCAN_KEEP = 10 * 3600   -- a platform not read for 10 minutes: its lists dropped
  local function scan(ctx)
    if ctx.by then return ctx end
    local pl = ctx.pl
    local s, f = pl.surface, pl.force
    local kept = api.state and api.state()
    if kept then kept.endurance_scan = kept.endurance_scan or {}; kept = kept.endurance_scan end
    local rec = kept and kept[pl.index]
    local ok = rec and rec.key == SCAN_KEY and rec.n == try(function() return s.count_entities_filtered{type=SCAN, force=f} end)
    for _, t in ipairs(ok and SCAN or {}) do
      for _, e in ipairs(rec.by[t]) do if not e.valid then ok = false; break end end
      if not ok then break end
    end
    if not ok then
      local by, tanks, machines, n = {}, {}, {}, 0
      for _, t in ipairs(SCAN) do by[t] = {} end
      for _, e in ipairs(try(function() return s.find_entities_filtered{type=SCAN, force=f} end) or {}) do
        local t = e.type
        local l = by[t]
        if l then
          n = n + 1
          l[#l+1] = e
          if t == 'thruster' or t == 'storage-tank' then tanks[#tanks+1] = e end
          if t == 'assembling-machine' or t == 'furnace' then machines[#machines+1] = e end
        end
      end
      rec = {key=SCAN_KEY, n=n, by=by, tanks=tanks, machines=machines}
      if kept then
        for k, x in pairs(kept) do if game.tick - x.tick > SCAN_KEEP then kept[k] = nil end end
        kept[pl.index] = rec
      end
    end
    rec.tick = game.tick
    ctx.by, ctx.tanks, ctx.machines = rec.by, rec.tanks, rec.machines
    return ctx
  end
  -- km per minute: flying now, else the last finished leg's average. (EC) Once a call: the read and its fuel outlook
  -- share it (ctx).
  local speed_of
  local function speed(pl, ctx)
    if not ctx then return speed_of(pl) end
    if not ctx.speed then ctx.speed = {speed_of(pl, ctx)} end
    return ctx.speed[1], ctx.speed[2]
  end
  function speed_of(pl, ctx)
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
      local g = try(function() return api.geometry(pl, ctx and scan(ctx).by.thruster) end) or {}
      local diff = {}
      if from_seg.thrusters and g.thrusters and g.thrusters ~= from_seg.thrusters then diff[#diff+1] = string.format('%d thrusters then, %d now', from_seg.thrusters, g.thrusters) end
      -- (d27 batch294 TQ) the same count at another quality: quality multiplies thrust
      if from_seg.thrust and g.thrust and math.abs(g.thrust - from_seg.thrust) > 0.005 then diff[#diff+1] = string.format('thrusters worth %g normal ones then, %g now (their quality)', from_seg.thrust, g.thrust) end
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
      assert(type(given) == 'table' and #given >= 1 and #given <= M.ROUTE_MAX, 'route is a list of 1..' .. M.ROUTE_MAX .. ' space locations (planet names)')
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
  -- (EC) With the call's ctx, read once a call for every fluid (the read asked it six times: its ammunition model's
  -- fluid ingredients, the fluid rows and the fuel outlook).
  local function fluid_stock(pl, names, ctx)
    local all = ctx and ctx.fluids
    if not all then
      -- (d22 batch96 BF1) the thrusters and tanks of the platform's background read when a count finds no other aboard
      -- (freight.platform_lists), else found: the fuel outlook is read by the platform alerts' scans, flight watches and
      -- this read
      local list = ctx and scan(ctx).tanks
      if not list then
        local lists = api.platform_lists and try(function() return api.platform_lists(pl) end)
        list = lists and lists.tanks or try(function() return pl.surface.find_entities_filtered{type={'thruster', 'storage-tank'}, force=pl.force} end) or {}
      end
      all = {amount={}, tanks={}, list=list}
      for _, e in ipairs(list) do
        local tank = e.type == 'storage-tank'
        for i = 1, try(function() return #e.fluidbox end) or 0 do
          local f = try(function() return e.fluidbox[i] end)
          if f then
            all.amount[f.name] = (all.amount[f.name] or 0) + f.amount
            if tank then all.tanks[f.name] = (all.tanks[f.name] or 0) + f.amount end
          end
        end
      end
      if ctx then ctx.fluids = all end
    end
    local out, tanks = {}, {}
    for name in pairs(names) do out[name], tanks[name] = all.amount[name], all.tanks[name] end
    return out, tanks, all.list
  end
  -- (d27 batch298 FW, Sol #2652: Resolute's thrusters held a level 1138 fuel and 842 oxidizer while the alert said it
  -- ran out in about a minute: its one fuel maker makes 1500 a craft, so a minute's count was 13500 or 15000 against
  -- 14400 used, and the 4800 and 4500 in the pipes before its pumps went uncounted) the machines aboard whose recipe
  -- makes thruster fuel or oxidizer, and the pumps, found again every PARTS_KEEP ticks (Resolute's 147 assembling
  -- machines: found with their recipes in 0.83 ms on the iMac copy; kept, 0.05 ms)
  local FUELS, PARTS_KEEP, LOW_MIN = {['thruster-fuel']=true, ['thruster-oxidizer']=true}, 3600, 2
  local function product_amount(p)
    local n = p.amount or ((p.amount_min or 0) + (p.amount_max or 0)) / 2
    return n * (p.probability or 1)
  end
  -- The machines that can craft a recipe making either fluid (chemical plants in 2.0.77), by the recipes' categories,
  -- and the pumps, for one find by name; nil (found by type) when the prototypes cannot say. (EC) in_scan: all of them
  -- are assembling machines, furnaces or pumps, which the call's one find holds.
  local maker_names_, in_scan_
  local function maker_names()
    if maker_names_ ~= nil then return maker_names_ or nil, in_scan_ end
    maker_names_ = try(function()
      local cats, names = {}, {}
      for name in pairs(FUELS) do
        for _, r in pairs(prototypes.get_recipe_filtered{{filter='has-product-fluid', elem_filters={{filter='name', name=name}}}}) do cats[r.category] = true end
      end
      for cat in pairs(cats) do
        for n in pairs(prototypes.get_entity_filtered{{filter='crafting-category', crafting_category=cat}}) do names[#names+1] = n end
      end
      if #names == 0 then return false end
      for n in pairs(prototypes.get_entity_filtered{{filter='type', type='pump'}}) do names[#names+1] = n end
      return names
    end) or false
    in_scan_ = maker_names_ and true or false
    for _, n in ipairs(maker_names_ or {}) do
      local t = try(function() return prototypes.entity[n].type end)
      if t ~= 'assembling-machine' and t ~= 'furnace' and t ~= 'pump' then in_scan_ = false end
    end
    return maker_names_ or nil, in_scan_
  end
  local function fuel_parts(pl, ctx)
    local all = api.state and api.state()
    if all then all.fuel_parts = all.fuel_parts or {}; all = all.fuel_parts end
    local rec = all and all[pl.index]
    local ok = rec and game.tick - rec.tick < PARTS_KEEP and game.tick >= rec.tick
    for _, m in ipairs(ok and rec.makers or {}) do
      if not (m.entity.valid and try(function() return m.entity.get_recipe().name end) == m.recipe) then ok = false; break end
    end
    for _, e in ipairs(ok and rec.pumps or {}) do if not e.valid then ok = false; break end end
    if ok then return rec end
    local s, f = pl.surface, pl.force
    rec = {tick=game.tick, makers={}, pumps={}}
    local names, in_scan = maker_names()
    local found
    if ctx and in_scan then
      -- (EC) the call's one find: its assembling machines and furnaces, then its pumps (each recipe is read below)
      local c = scan(ctx)
      found = {}
      for _, e in ipairs(c.machines) do found[#found+1] = e end
      for _, e in ipairs(c.by.pump) do found[#found+1] = e end
    end
    found = found or names and try(function() return s.find_entities_filtered{name=names, force=f} end)
    if not found then
      found = try(function() return s.find_entities_filtered{type='assembling-machine', force=f} end) or {}
      for _, e in ipairs(try(function() return s.find_entities_filtered{type='pump', force=f} end) or {}) do found[#found+1] = e end
    end
    for _, e in ipairs(found) do
      if e.type == 'pump' then rec.pumps[#rec.pumps+1] = e end
      local r = e.type ~= 'pump' and try(function() return e.get_recipe() end)
      for _, p in ipairs(r and try(function() return r.products end) or {}) do
        if p.type == 'fluid' and FUELS[p.name] then
          rec.makers[#rec.makers+1] = {entity=e, fluid=p.name, recipe=r.name, batch=product_amount(p), energy=r.energy}
        end
      end
    end
    if all then
      for k, x in pairs(all) do if game.tick - x.tick > 10 * PARTS_KEEP then all[k] = nil end end
      all[pl.index] = rec
    end
    return rec
  end
  -- Each fluid aboard: the fluid segments (pipes and storage tanks, one a run of them as the game joins them) beside
  -- the thrusters, storage tanks, pumps and makers' outputs, and the thrusters', pumps' and makers' own boxes, which no
  -- segment holds. On the iMac copy Resolute's sum changed by exactly made less used every tick for 18333 ticks of
  -- flight (the fluid statistics). {name: amount}.
  local function fuel_aboard(list, parts)
    local out, seen = {}, {}
    local function add(f) if f and FUELS[f.name] then out[f.name] = (out[f.name] or 0) + f.amount end end
    local function segment(box, i)
      local id = try(function() return box.get_fluid_segment_id(i) end)
      if not id then return false end
      if not seen[id] then
        seen[id] = true
        for name, n in pairs(try(function() return box.get_fluid_segment_contents(i) end) or {}) do
          if FUELS[name] then out[name] = (out[name] or 0) + n end
        end
      end
      return true
    end
    local function own_and_beside(e)
      local fb = e.fluidbox
      for i = 1, try(function() return #fb end) or 0 do
        local f = try(function() return fb[i] end)
        if f and FUELS[f.name] then
          add(f)
          for _, pc in ipairs(try(function() return fb.get_pipe_connections(i) end) or {}) do
            if pc.target then segment(pc.target, pc.target_fluidbox_index or 1) end
          end
        end
      end
    end
    for _, e in ipairs(list) do
      local fb = e.valid and e.fluidbox
      for i = 1, fb and try(function() return #fb end) or 0 do
        local f = try(function() return fb[i] end)
        if f and FUELS[f.name] and (not segment(fb, i) or e.type ~= 'storage-tank') then add(f) end
      end
    end
    for _, e in ipairs(parts.pumps) do if e.valid then own_and_beside(e) end end
    for _, m in ipairs(parts.makers) do if m.entity.valid then own_and_beside(m.entity) end end
    return out
  end
  -- A fluid's makers: {makers, batch (the largest), recipes, craft_s (the quickest at full speed), full_per_min (all of
  -- them crafting without a pause), step (a batch a maker: what a window's count can differ from their steady output by,
  -- each counted at the end of its craft)}.
  local function makers_of(parts, name)
    local out = {makers=0, batch=0, step=0, full_per_min=0, recipes={}, names={}}
    for _, m in ipairs(parts.makers) do
      if m.fluid == name and m.entity.valid then
        local e = m.entity
        local spd = try(function() return e.crafting_speed end) or 1
        local prod = (try(function() return e.productivity_bonus end) or 0) + (try(function() return e.force.recipes[m.recipe].productivity_bonus end) or 0)
        out.makers = out.makers + 1
        out.batch = math.max(out.batch, m.batch)
        out.step = out.step + m.batch
        out.full_per_min = out.full_per_min + m.batch * (1 + prod) * 60 * spd / m.energy
        local s = m.energy / spd
        out.craft_s = out.craft_s and math.min(out.craft_s, s) or s
        if not out.recipes[m.recipe] then out.recipes[m.recipe] = true; out.names[#out.names+1] = m.recipe end
        out.kind = out.kind == nil and e.name or out.kind == e.name and e.name or 'machine'
      end
    end
    return out.makers > 0 and out or nil
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
  -- (FW) Rates over the engine's longest sample wholly in this leg (180 s, else 60 s; else the statistics' last minute,
  -- as before): a maker counts a batch at the end of each craft, so a window's count differs from its steady output by
  -- up to a batch a maker (step); a deficit within that, while batches land, is no deficit measured, unless what is
  -- aboard lasts under LOW_MIN even so. What lasts how long is the fluid
  -- aboard: the thrusters, tanks, pipes, pumps and the makers' outputs (aboard). Made in batches: the batch, the
  -- makers, a craft's time at full speed, and the share of their full output made over the window.
  -- (EC) ctx: optional, platform_endurance's call (its one find, fluids and speed shared).
  function M.fuel_outlook(pl, ctx)
    local names = FUELS
    local stock, in_tanks, list = fluid_stock(pl, names, ctx)
    local parts_ = try(function() return pl.surface and fuel_parts(pl, ctx) end)
    local all = parts_ and fuel_aboard(list, parts_) or {}
    local stats = try(function() return pl.force.get_fluid_production_statistics(pl.surface) end)
    local P = defines.flow_precision_index or {}
    local function per_min(name, cat)
      return stats and P.one_minute and (try(function() return stats.get_flow_count{name=name, category=cat, precision_index=P.one_minute, count=true} end) or 0) or 0
    end
    local leg = api.leg and try(function() return api.leg(pl) end)
    local v, v_by
    if leg then v, v_by = speed(pl, ctx) end
    local left_min = leg and v and v > 0 and leg.left_km / v or nil
    local since = leg and M.since_departure(pl)
    local win
    for _, x in ipairs(since and since.samples or {}) do
      if x.at_stop_s == 0 and x.seconds >= 60 and (not win or x.seconds > win.seconds) then win = x end
    end
    local window_s = win and win.seconds or 60
    local rows, parts, short = {}, {}, {}
    for _, name in ipairs({'thruster-fuel', 'thruster-oxidizer'}) do
      local wf = win and win.fluids[name]
      local held, made, used = stock[name] or 0, wf and wf.made_per_min or per_min(name, 'input'), wf and wf.used_per_min or per_min(name, 'output')
      local aboard = math.max(held, all[name] or 0)
      local row = {name=name, held=math.floor(held + 0.5), in_tanks=math.floor((in_tanks[name] or 0) + 0.5), made_per_min=round(made, 0), used_per_min=round(used, 0),
        aboard=math.floor(aboard + 0.5), window_s=window_s}
      local mk = parts_ and makers_of(parts_, name)
      local step = mk and mk.step * 60 / window_s
      if mk then
        row.batch = {size=round(mk.batch, 0), makers=mk.makers, recipes=mk.names, craft_s=round(mk.craft_s, 2), full_per_min=round(mk.full_per_min, 0),
          share=mk.full_per_min > 0 and round(made / mk.full_per_min * 100, 0) or nil, step=round(mk.step, 0), step_per_min=round(step, 0)}
      end
      local net = used - made
      local text = string.format('%s %d held%s, made %d/min, used %d/min%s', name, row.held,
        row.aboard > row.held and string.format(' (%d aboard with the pipes, pumps and makers\' outputs)', row.aboard) or '',
        row.made_per_min, row.used_per_min, win and string.format(' over the last %d s', window_s) or '')
      if left_min then
        -- within the step only while batches land in the window (or a craft at full speed is over half of it), and not
        -- when what is aboard lasts under LOW_MIN even so (the copy: its fuel maker stopped, 1 left and 183/min used)
        local pulsed = mk and (made > 0 or mk.craft_s * 2 > window_s)
        if net <= 0 then text = text .. ': lasts the leg'
        elseif step and pulsed and net <= step and aboard / net >= LOW_MIN then
          row.within_step = true
          text = text .. string.format(': used over made by %d/min, within a batch a maker over %d s (%d/min): no deficit measured', round(net, 0), window_s, round(step, 0))
        else
          row.lasts_min = round(aboard / net, 1)
          if row.lasts_min < left_min then
            row.short_min = round(left_min - row.lasts_min, 1)
            short[#short+1] = name
            text = text .. string.format(': runs out in %s, %s before the leg ends', mins(row.lasts_min), mins(row.short_min))
          else text = text .. string.format(': lasts %s, the leg %s', mins(row.lasts_min), mins(left_min)) end
        end
      end
      if mk then
        local b = row.batch
        text = text .. string.format(' (made in batches of %d by %d %s%s: %s, a craft each %g s at full speed, %d/min%s)', b.size, b.makers, mk.kind,
          b.makers == 1 and '' or 's', table.concat(b.recipes, ', '), b.craft_s, b.full_per_min,
          b.share and string.format('; %d%% of that made over the last %d s', b.share, window_s) or '')
      end
      rows[#rows+1] = row; parts[#parts+1] = text
    end
    local where = leg and string.format('leg %s->%s, %d km left%s', leg.from, leg.to, math.floor(leg.left_km + 0.5),
      left_min and string.format(', about %s at %d km/min (%s)', mins(left_min), math.floor(v + 0.5), v_by == 'now' and 'its speed now' or tostring(v_by)) or ', speed unknown')
      or 'stopped' .. (try(function() return ' at ' .. pl.space_location.name end) or '') .. ': the thrusters burn only in flight'
    -- (d27 batch294 TQ, Sol #2645) apart from the use measured above: what its thrusters burn at full thrust at their
    -- own quality, the engine's figures
    local full = api.thrusters and try(function() return api.thrusters(pl, ctx and scan(ctx).by.thruster) end)
    return {line=string.format('%s: %s; %s', pl.name, where, table.concat(parts, '; ')), short=#short > 0 and short or nil, rows=rows,
      full_thrust=full and full.line or nil, full_thrust_per_min=full and full.per_min or nil, window_s=window_s,
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
  -- (EC) The ammunition and repair packs (sorted) and the asteroid chunks among the items, read once a session:
  -- prototypes do not change while the game runs (each call read every item, 0.6-0.9 ms on a copy of world n).
  local ITEMS
  local function item_lists()
    if ITEMS then return ITEMS end
    local ammo, chunks = {}, {}
    for name, item in pairs(prototypes.item) do
      if item.type == 'ammo' or item.type == 'repair-tool' then ammo[#ammo+1] = name end
      if name:find('%-asteroid%-chunk$') then chunks[#chunks+1] = name end
    end
    table.sort(ammo)
    table.sort(chunks)
    ITEMS = {ammo=ammo, chunks=chunks}
    return ITEMS
  end
  local routeammo, ammomodel_
  local function ammomodel()
    ammomodel_ = ammomodel_ or api.ammomodel or require('ammomodel'){stock_places=api.stock_places, ammofeed=api.ammofeed, incoming=api.incoming}
    return ammomodel_
  end
  -- (d24 batch183 QZ1, Sol #2055) design {width, height | tiles, mass?, speed, ammo?} and progress {from, to}.
  local function tiles_box(list)
    assert(type(list) == 'table' and #list >= 1 and #list <= 256, 'design.tiles is a list of 1..256 tiles or areas: "x0..x1,y0..y1", "x,y" or {x,y}')
    local x0, y0, x1, y1
    local function add(ax, ay, bx, by)
      x0, y0 = math.min(x0 or ax, ax), math.min(y0 or ay, ay)
      x1, y1 = math.max(x1 or bx, bx), math.max(y1 or by, by)
    end
    for _, t in ipairs(list) do
      if type(t) == 'string' then
        local a1, a2, b1, b2 = t:match('^%s*(%-?%d+)%.%.(%-?%d+)%s*,%s*(%-?%d+)%.%.(%-?%d+)%s*$')
        if a1 then add(math.min(a1, a2) + 0, math.min(b1, b2) + 0, math.max(a1, a2) + 0, math.max(b1, b2) + 0)
        else
          local x, y = t:match('^%s*(%-?[%d.]+)%s*,%s*(%-?[%d.]+)%s*$')
          assert(x, 'design.tiles: "' .. t .. '" is not "x0..x1,y0..y1" or "x,y"')
          add(math.floor(x + 0), math.floor(y + 0), math.floor(x + 0), math.floor(y + 0))
        end
      else
        local x, y = type(t) == 'table' and (t.x or t[1]), type(t) == 'table' and (t.y or t[2])
        assert(type(x) == 'number' and type(y) == 'number', 'design.tiles: each is "x0..x1,y0..y1", "x,y" or {x,y}')
        add(math.floor(x), math.floor(y), math.floor(x), math.floor(y))
      end
    end
    return x1 - x0 + 1, y1 - y0 + 1, string.format('the tiles\' box x %d..%d, y %d..%d', x0, x1, y0, y1)
  end
  local function check_progress(pr)
    if pr == nil then return nil end
    assert(type(pr) == 'table' and type(pr.from) == 'number' and type(pr.to) == 'number' and pr.from >= 0 and pr.to <= 1 and pr.from < pr.to,
      'progress is {from, to}: 0 <= from < to <= 1, the part of each leg\'s connection, the way it is flown')
    return {pr.from, pr.to}
  end
  -- (d29 batch329 PR, Astra #2727: Resolute turned back at ~29k km of solar-system-edge->shattered-planet because its
  -- railgun ammunition ran 28.63/min net in the deep phase while the 10-minute rate read 17.4; a manual budget caught
  -- it) The return budget of a turnaround: per item, how much farther out the ship can go before the way back needs the
  -- rest. items: [{name, stock, made, used (the current phase: this leg so far), made10, used10 (the last 10 min), from}];
  -- o: {v (km/min, the planning speed), flown_km (from the connection's start to here), back_km (from that start on to
  -- the stop it returns to), out_km (the planned turn, km farther out; nil: none), margin (a share kept spare), reserve
  -- (a number for every item, or {item = n})}. The net use is the worse of the two rates (both given). Going x km
  -- farther out and back to the start is 2x + flown_km, then back_km: the stock less its reserve, over 1 + margin,
  -- lasts usable / net minutes, so x = (usable / net * v - flown_km - back_km) / 2. An item made at least as fast as it
  -- is used binds nothing. Facts only: nothing is changed, no floor is lowered.
  -- (d29 batch339 RB) The statistics' window for the return budget's second rate: the last 10 minutes when they lie
  -- wholly after the leg's first STARTUP_S (the stop it left and its first minute flying), else the longest of 5 and 1
  -- minute that does, else none. leg_min: minutes since this leg began (nil: not known, the 10). -> precision index,
  -- minutes, text.
  function M.budget_window(leg_min, P)
    local clean = leg_min and leg_min - STARTUP_S / 60 or nil
    if not clean or clean >= 10 then return P.ten_minutes, 10, 'the last 10 min' end
    if clean >= 5 and P.five_minutes then return P.five_minutes, 5, 'the last 5 min (the 10 would hold the leg\'s startup)' end
    if clean >= 1 and P.one_minute then return P.one_minute, 1, 'the last 1 min (the 10 would hold the leg\'s startup)' end
    return nil, nil, 'no window after the leg\'s startup yet'
  end

  function M.return_budget(items, o)
    local out, binds = {}, nil
    for _, it in ipairs(items) do
      local np, n10 = (it.used or 0) - (it.made or 0), (it.used10 or 0) - (it.made10 or 0)
      local net = math.max(np, n10)
      if it.within_step then net = 0 end  -- (d29 batch339) a fuel deficit within a batch a maker: none measured
      local res = type(o.reserve) == 'table' and (o.reserve[it.name] or 0) or (o.reserve or 0)
      local r = {name=it.name, stock=round(it.stock, 0), reserve=res, net_phase=round(np, 2), net_10min=round(n10, 2), net_used=round(net, 2),
        phase_from=it.from, window=it.window, worse=np >= n10 and 'this phase' or (it.window or 'the last 10 min'), stock_scope=it.scope,
        within_step=it.within_step or nil}
      local usable = (it.stock - res) / (1 + (o.margin or 0))
      r.usable = round(usable, 0)
      r.usable_basis = string.format('(%d %s - %d kept) / (1 + %g margin)', round(it.stock, 0), it.scope and 'aboard' or 'stock', res, o.margin or 0)
      if res > it.stock then r.reserve_over_stock = true end
      if o.selected and not o.selected[it.name] then r.not_selected = true end
      if net > 0 and o.v and o.v > 0 then
        local x = (usable / net * o.v - o.flown_km - o.back_km) / 2
        r.out_km_max = round(x, 0)
        r.lasts_min = round(usable / net, 1)
        if o.out_km then
          r.left_at_return = round(it.stock - net * (2 * o.out_km + o.flown_km + o.back_km) / o.v, 0)
          r.spare_km = round(x - o.out_km, 0)
        end
        if not r.not_selected and (not binds or x < binds.x) then binds = {name=it.name, x=x} end
      elseif net <= 0 then r.not_used = true end
      out[#out+1] = r
    end
    local b
    for _, r in ipairs(out) do if binds and r.name == binds.name then b = r end end
    return out, b
  end

  function M.read(p, a)
    assert(type(a.platform) == 'string', 'platform is required (a platform name)')
    local design = a.design
    if design ~= nil then
      assert(type(design) == 'table', 'design is {width, height | tiles, mass?, speed, ammo?}')
      assert(type(design.speed) == 'number' and design.speed > 0 and design.speed <= 10000, 'design.speed is km/s, above 0 (as the platform GUI shows it)')
      assert(design.tiles == nil or design.width == nil, 'design: give width (and height) or tiles, not both')
      if design.tiles == nil then
        assert(type(design.width) == 'number' and design.width >= 1 and design.width <= 2000, 'design.width is tiles, 1..2000 (or give tiles)')
        assert(design.height == nil or (type(design.height) == 'number' and design.height >= 1), 'design.height is tiles')
      end
      assert(design.mass == nil or (type(design.mass) == 'number' and design.mass > 0), 'design.mass is a number above 0')
      assert(design.ammo == nil or (type(design.ammo) == 'table' and #design.ammo <= 8), 'design.ammo is a list of up to 8 ammunition names')
      for _, n in ipairs(design.ammo or {}) do assert(type(n) == 'string' and prototypes.item[n] and prototypes.item[n].type == 'ammo', 'design.ammo: ' .. tostring(n) .. ' is not an ammunition') end
    end
    local progress = check_progress(a.progress)
    local ta = a.turnaround
    if ta ~= nil then
      assert(type(ta) == 'table', 'turnaround is {km | fraction, back_to?, speed_floor?, margin?, reserve?}')
      assert(design == nil and a.route == nil and not a.forecast, 'turnaround: the route is the turn itself: no route, design or forecast with it')
      assert((ta.km == nil) ~= (ta.fraction == nil), 'turnaround: km (farther out from here) or fraction (the turn point, a share of the connection from its start): one of them')
      assert(ta.km == nil or (type(ta.km) == 'number' and ta.km >= 0 and ta.km <= 1e8), 'turnaround.km is 0..100000000 km farther out from here')
      assert(ta.fraction == nil or (type(ta.fraction) == 'number' and ta.fraction > 0 and ta.fraction <= 1), 'turnaround.fraction is above 0 up to 1')
      assert(ta.back_to == nil or (type(ta.back_to) == 'string' and prototypes.space_location[ta.back_to]), 'turnaround.back_to is a space location name')
      assert(ta.speed_floor == nil or (type(ta.speed_floor) == 'number' and ta.speed_floor > 0 and ta.speed_floor <= 10000), 'turnaround.speed_floor is km/s, above 0')
      assert(ta.margin == nil or (type(ta.margin) == 'number' and ta.margin >= 0 and ta.margin <= 2), 'turnaround.margin is 0..2 (a share kept spare; default 0.1)')
      assert(ta.reserve == nil or (type(ta.reserve) == 'number' and ta.reserve >= 0) or type(ta.reserve) == 'table', 'turnaround.reserve is a count for every item, or {item: count}')
      for k, n in pairs(type(ta.reserve) == 'table' and ta.reserve or {}) do
        assert(type(k) == 'string' and type(n) == 'number' and n >= 0, 'turnaround.reserve: {item: count}')
      end
      -- (d29 batch339 RB, Sol #2745) items: the ones that may bind (e.g. the ammunition and repair packs; the rest
      -- listed, not binding)
      assert(ta.items == nil or (type(ta.items) == 'table' and #ta.items >= 1 and #ta.items <= 32), 'turnaround.items is a list of 1..32 item or fluid names')
      for _, n in ipairs(ta.items or {}) do
        assert(type(n) == 'string' and (prototypes.item[n] or (prototypes.fluid and prototypes.fluid[n])), 'turnaround.items: unknown item or fluid ' .. tostring(n))
      end
    end
    local pl = api.platform(p, a.platform)
    assert(pl.surface, 'platform ' .. pl.name .. ' has no surface yet')
    local stops, route_by = route_of(pl, not ta and a.route or nil)
    local ctx = {pl=pl}
    local v, v_by
    if not design then v, v_by = speed(pl, ctx) end
    -- Legs: from where it is (the rest of the leg it flies), then stop to stop.
    local legs, total_km = {}, 0
    local leg_now = api.leg and api.leg(pl)
    local here = try(function() return pl.space_location.name end)
    local start = here
    local route_note
    local turn  -- (PR) the turnaround's geometry: {out_km, flown_km, length, back_km, from, to, back_to}
    if ta then
      assert(leg_now and leg_now.length, string.format('turnaround: %s flies no connection now (at %s): it reads a ship in flight', pl.name, here or 'a stop'))
      local flown_km = leg_now.length - leg_now.left_km
      local out_km = ta.km or (ta.fraction * leg_now.length - flown_km)
      -- (the messages are made only when they are raised: ta.fraction is nil with km)
      if out_km < 0 then
        error(string.format('turnaround.fraction %g is behind the ship: it has flown %d of %s->%s\'s %d km', ta.fraction, math.floor(flown_km + 0.5),
          leg_now.from, leg_now.to, math.floor(leg_now.length + 0.5)), 0)
      end
      if out_km > leg_now.left_km + 0.5 then
        error(string.format('turnaround: %d km farther is past %s (%d km left)', math.floor(out_km + 0.5), leg_now.to, math.floor(leg_now.left_km + 0.5)), 0)
      end
      local back_to = ta.back_to or leg_now.from
      turn = {out_km=out_km, flown_km=flown_km, length=leg_now.length, from=leg_now.from, to=leg_now.to, back_to=back_to, back_km=0}
      legs[#legs+1] = {from=leg_now.from, to=leg_now.to, km=round(out_km, 0), now=true, turn='out'}
      legs[#legs+1] = {from='the turn', to=leg_now.from, km=round(out_km + flown_km, 0), turn='back'}
      total_km = total_km + out_km + out_km + flown_km
      if back_to ~= leg_now.from then
        local len = connection(leg_now.from, back_to)
        local route = not len and api.path and api.path(leg_now.from, back_to)
        assert(len or route, string.format('turnaround.back_to: no way from %s to %s', leg_now.from, back_to))
        for _, h in ipairs(route and route.hops or {{from=leg_now.from, to=back_to, km=len}}) do
          legs[#legs+1] = {from=h.from, to=h.to, km=round(h.km, 0), turn='on'}
          total_km = total_km + h.km
          turn.back_km = turn.back_km + h.km
        end
      end
      route_by, stops = 'turnaround', {}
    elseif leg_now then
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
    if turn then start = nil end  -- (PR) the turn's legs are the route
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
    if design then
      -- the design: its box and speed in place of the platform's; nothing else of the platform read but its route, its
      -- turrets' ammunition and our bonuses (a light read)
      v, v_by = design.speed * 60, 'the design\'s'
    end
    local total_min = v and v > 0 and total_km / v or nil
    for _, l in ipairs(legs) do l.minutes = v and v > 0 and l.km and round(l.km / v, 1) or nil end
    if design then
      routeammo = routeammo or require('routeammo'){segments=api.segments, ammorate=api.ammorate, damages=api.ammo_damages}
      local w, h, from = design.width, design.height, 'the design\'s width'
      if design.tiles then w, h, from = tiles_box(design.tiles) end
      local m = routeammo.model(pl, legs, {width=w, width_from=from, height=h, speed=v, speed_from='the design\'s', mass=design.mass, progress=progress, ammo=design.ammo})
      return {platform=pl.name, design={width=w, height=h, speed_km_s=design.speed, mass=design.mass, from=from}, route=route_by, route_note=route_note, legs=m.legs,
        total_km=round(total_km, 0), total_minutes=total_min and round(total_min, 1) or nil, basis=m.basis, estimated=m.estimated, ammo=m.ammo, lines=m.lines,
        note='read only: nothing built, placed or imported; the route is the platform\'s (route or its schedule), the shots its turrets\' ammunition and settings and our bonuses'}
    end
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
    -- (PX1) items at every quality; fluids by name (a pair fails there). (EC) With the statistics' totals since the game
    -- began (input_counts, output_counts: every quality's), read once a call: an item never counted reads 0 with no read,
    -- one only ever counted at normal is read at normal alone (qflow's all); each was read at all 6 qualities before.
    local totals = {}
    local function flow(stats, name, cat, pi)
      if stats == fluid_stats then return stats.get_flow_count{name=name, category=cat, precision_index=pi, count=true} end
      local t = totals[cat]
      if t == nil then
        t = try(function() return cat == 'input' and stats.input_counts or stats.output_counts end) or false
        totals[cat] = t
      end
      local all = t and (t[name] or 0) or nil
      if all == 0 then return 0 end
      return qflow.flow(stats, name, cat, pi, true, all)
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
    local places = api.stock_places and try(function()
      local c = scan(ctx)
      return api.stock_places(pl, setmetatable({}, {__index=function() return true end}), {turrets=c.by['ammo-turret'], machines=c.machines, inserters=c.by.inserter})
    end)
    -- (d22 batch96 BF1: the trace of a platform of up to 400 belts ran in this call, 64 ms of Kestrel IVb's 201 belts on
    -- a copy of world n) the trace's background read, its age said, as the platforms read and preflight take it
    local model = ammomodel().new(pl, {background=true, places=places or false, rate=function(name, cat, fluid) return rate(fluid and fluid_stats or items_stats, name, cat) end,
      fluid_stock=function(names) return fluid_stock(pl, names, ctx) end, machines=scan(ctx).by['assembling-machine']})
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
    local ammo = item_lists().ammo
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
    local fstock = fluid_stock(pl, fluids, ctx)
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
    -- (PR) the turnaround's return budget: each item's stock reaching it, its net use the worse of the current phase
    -- (this leg so far, and for ammunition the moving phase) and the last 10 minutes, both given
    local return_budget, fo_now  -- (batch339) the fuel outlook read once a call: the budget's and the reply's
    if turn then
      local floor = ta.speed_floor and ta.speed_floor * 60 or nil
      local vplan = v and (floor and math.min(v, floor) or v) or nil
      local items = {}
      -- (d29 batch339 RB, Sol #2745: Resolute's fuel read 1977 held against fuel_outlook's 8703 aboard, and the
      -- 10-minute window held the stop and the departure) fuel and oxidizer as fuel_outlook counts them: everything
      -- aboard (thrusters, tanks, pipes, pumps, the makers' outputs) and its clean sample, the longest wholly in this leg
      -- (180 s, else 60 s), a deficit within a batch a maker counting as none; the 10-minute rate only when the 10
      -- minutes are wholly after the leg's first STARTUP_S (startup: the stop it left and its first minute flying,
      -- thrusters filling and belts settling), else the longest window that is (5 or 1 minute), said; none, none.
      local fo_rows = {}
      fo_now = try(function() return M.fuel_outlook(pl, ctx) end)
      for _, fr in ipairs(fo_now and fo_now.rows or {}) do fo_rows[fr.name] = fr end
      local wp, wmin, wtext = M.budget_window(open_leg and (game.tick - open_leg.start) / 3600 or nil, P)
      for _, row in ipairs(rows) do
        local fr = fo_rows[row.name]
        if fr then
          local m, u = fr.made_per_min or 0, fr.used_per_min or 0
          items[#items+1] = {name=row.name, stock=fr.aboard or fr.held or row.stock, made=m, used=u, made10=m, used10=u,
            from=string.format('fuel_outlook\'s last %d s, flying', fr.window_s or 60), window=string.format('its last %d s', fr.window_s or 60),
            scope='aboard: thrusters, tanks, pipes, pumps and the makers\' outputs (fuel_outlook; held in thrusters and tanks ' .. tostring(fr.held) .. ')',
            within_step=fr.within_step}
        elseif not row.flight_rate then
          local st = items_stats
          local m10 = wp and (try(function() return flow(st, row.name, 'input', wp) end) or 0) / wmin or 0
          local u10 = wp and (try(function() return flow(st, row.name, 'output', wp) end) or 0) / wmin or 0
          local made, used, from = row.made_per_min, row.used_per_min, row.rate_from
          local is_ammo = prototypes.item[row.name] and prototypes.item[row.name].type == 'ammo'
          local lm, lu, lfrom
          if is_ammo then lm, lu, lfrom = leg_now_rate(row.name) end  -- freight's counts are ammunition's
          if lm and lu - lm > used - made then made, used, from = lm, lu, lfrom end
          local mv = row.phases and row.phases.moving
          if mv and mv.used_per_min - mv.made_per_min > used - made then
            made, used, from = mv.made_per_min, mv.used_per_min, string.format('moving phase, %s', mins(mv.minutes))
          end
          items[#items+1] = {name=row.name, stock=row.stock, made=made, used=used, made10=m10, used10=u10, from=from, window=wtext,
            scope=is_ammo and 'reaches the turrets: hub, turrets, belts, hands, machines\' outputs (stranded apart)' or 'aboard: hub, turrets, belts, hands, machines\' outputs'}
        end
      end
      local selected
      if ta.items then selected = {}; for _, n in ipairs(ta.items) do selected[n] = true end end
      local out, binds = M.return_budget(items, {v=vplan, flown_km=turn.flown_km, back_km=turn.back_km, out_km=turn.out_km,
        margin=ta.margin or 0.1, reserve=ta.reserve, selected=selected})
      local head = string.format('turnaround: %d km farther out on %s->%s (to %d of its %d km), back %d km to %s%s; at %s km/s (%s), margin %d%%',
        math.floor(turn.out_km + 0.5), turn.from, turn.to, math.floor(turn.flown_km + turn.out_km + 0.5), math.floor(turn.length + 0.5),
        math.floor(turn.out_km + turn.flown_km + 0.5), turn.from, turn.back_km > 0 and string.format(', then %d km to %s', math.floor(turn.back_km + 0.5), turn.back_to) or '',
        vplan and string.format('%g', round(vplan / 60, 1)) or '?', floor and v and floor < v and 'the speed floor given' or (v_by or 'speed unknown'),
        math.floor((ta.margin or 0.1) * 100 + 0.5))
      local parts = {}
      for _, r in ipairs(out) do
        local tail = (r.not_selected and '; not in items: not binding' or '') .. (r.reserve_over_stock and string.format('; the %d kept is more than the %d counted', r.reserve, r.stock) or '')
        if r.within_step then
          parts[#parts+1] = string.format('%s: used over made within a batch a maker over %s: no deficit measured (%d aboard)%s', r.name, r.window or 'its window', r.stock, tail)
        elseif r.not_used and (tail ~= '' or fo_rows[r.name]) then
          parts[#parts+1] = string.format('%s: made at least as fast as used over %s (%d %s)%s', r.name, r.window or 'its window', r.stock,
            fo_rows[r.name] and string.format('aboard, %d held in thrusters and tanks', fo_rows[r.name].held or 0) or 'counted', tail)
        elseif r.out_km_max then
          parts[#parts+1] = string.format('%s: at most %d km farther out (%d %s%s; net %g/min, the worse of %s (%g/min) and %s (%g/min)%s)%s',
            r.name, r.out_km_max, r.stock, r.stock_scope and r.stock_scope:match('^aboard') and 'aboard' or 'reaching it',
            r.reserve > 0 and string.format(', %d kept', r.reserve) or '', r.net_used, r.phase_from or 'this phase', r.net_phase, r.window or 'the last 10 min', r.net_10min,
            r.spare_km and (r.spare_km >= 0 and string.format('; the planned turn fits, %d km to spare, about %d left back at %s', r.spare_km, math.max(0, r.left_at_return), turn.back_to)
              or string.format('; the planned turn is %d km too far', -r.spare_km)) or '', tail)
        end
      end
      return_budget = {out_km=round(turn.out_km, 0), flown_km=round(turn.flown_km, 0), connection_km=round(turn.length, 0), back_to=turn.back_to,
        back_km=round(turn.out_km + turn.flown_km + turn.back_km, 0), speed_km_s=vplan and round(vplan / 60, 2) or nil, margin=ta.margin or 0.1,
        items=out, binds=binds and {name=binds.name, out_km_max=binds.out_km_max, spare_km=binds.spare_km} or nil, selected=ta.items,
        startup_s=STARTUP_S, window=wtext,
        line=head .. '; ' .. (binds and string.format('%s binds first: at most %d km farther out%s', binds.name, binds.out_km_max,
          binds.spare_km and (binds.spare_km >= 0 and string.format(' (the planned turn fits, %d km to spare)', binds.spare_km) or string.format(' (the planned turn is %d km too far)', -binds.spare_km)) or '')
          or (ta.items and 'no item of items is used faster than it is made' or 'no item is used faster than it is made')) .. (#parts > 0 and '. ' .. table.concat(parts, '; ') or ''),
        note='read only: facts from the production statistics and the stock that reaches the turrets; nothing lowers a floor or changes the route'}
    end
    local slots = hub and #hub or 0
    local free = hub and try(function() return hub.count_empty_stacks(true, false) end) or 0
    -- Power: what the platform's network makes and draws now (a pole on it, else the surface's own network: PX1,
    -- Asterion has no pole), every quality (PX1), and the solar power at each stop.
    local power
    -- (EC) a platform's own network first: its pole's statistics are the surface's (Resolute and Lark on a copy of world
    -- n: the same counts), so no pole is found
    local st = try(function() return pl.surface.has_global_electric_network and pl.surface.global_electric_network_statistics end)
    if not st then
      local pole = try(function() return pl.surface.find_entities_filtered{type='electric-pole', force=pl.force, limit=1}[1] end)
      st = pole and try(function() return pole.electric_network_statistics end) or nil
    end
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
    local each = {}   -- (EC) a panel's peak once a call for each name and quality
    for _, e in ipairs(scan(ctx).by['solar-panel']) do
      panels = panels + 1
      local key = e.name .. '/' .. (try(function() return e.quality.name end) or '')
      local w = each[key]
      if not w then
        w = (try(function() return e.prototype.get_max_energy_production(e.quality) end) or try(function() return e.prototype.max_energy_production end) or 0) * 60 / 1000
        each[key] = w
      end
      peak = peak + w
    end
    -- at a stop, the location's solar power in space (the platform surface's own property read 100 at Gleba's 200%)
    local sp = here and try(function() return prototypes.space_location[here].solar_power_in_space end)
    local low, none, tlow = 0, 0, 0
    local LOW, NONE = try(function() return defines.entity_status.low_power end), try(function() return defines.entity_status.no_power end)
    -- (EC) by the call's lists of each type: the status alone, a turret's buffer only when it is on low power
    local c = scan(ctx)
    for t in pairs(STATUS) do
      local turret = t == 'ammo-turret' or t == 'electric-turret'
      for _, e in ipairs(c.by[t]) do
        local ok, stt = pcall(status_of, e)
        if ok and stt == LOW and stt ~= nil then
          -- (d24 batch160 QC1) a turret firing from a buffer (laser, railgun, tesla) on low power counted apart
          local shot = turret and (try(function() return e.electric_buffer_size end) or 0) > 0
          if shot then tlow = tlow + 1 else low = low + 1 end
        elseif ok and stt == NONE and stt ~= nil then none = none + 1 end
      end
    end
    local tlow_text = tlow > 0 and string.format('; %d turret%s firing from a buffer (laser, railgun, tesla) on low power apart (refilling after shots, or short: platform_power tells which)', tlow, tlow == 1 and '' or 's') or ''
    local solar_line = (panels > 0 and string.format('%d solar panels: %d kW at full sun%s; %d machines on low power, %d on no power now', panels, math.floor(peak + 0.5),
      sp and string.format(', about %d kW at %s\'s %d%% solar power', math.floor(peak * sp / 100 + 0.5), here, math.floor(sp + 0.5)) or ' (flying: the stops\' solar power is on the hub line)', low, none)
      or string.format('no solar panels; %d machines on low power, %d on no power now', low, none)) .. tlow_text
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
    for _, name in ipairs(item_lists().chunks) do
      local m = rate(items_stats, name, 'input')
      if m > 0 then chunks[#chunks+1] = string.format('%s %g/min', name, round(m, 1)) end
    end
    table.sort(chunks)
    -- forecast (E11, routeammo.lua): per leg, the asteroids its connection spawns, shots per asteroid of each ammunition
    -- aboard, and the use scaled from the legs flown; pessimistic {speed, dwell_s}.
    local forecast, forecast_damage, forecast_coverage, forecast_targets, forecast_model, forecast_basis
    assert(progress == nil or a.forecast, 'progress goes with forecast: true or design')
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
      local fo = {}
      for k, x in pairs(pe or {}) do fo[k] = x end
      fo.progress = progress
      forecast, forecast_damage, forecast_coverage, forecast_targets = routeammo.forecast(pl, legs, ammo, fo, model)
      -- (QZ1) what the forecast assumes, and the spawn model with the platform's own box and speed (design gives the same
      -- with another)
      local g = api.geometry and try(function() return api.geometry(pl, scan(ctx).by.thruster) end) or {}
      forecast_model = routeammo.model(pl, legs, {width=g.width, width_from='the platform\'s foundation, x extent', speed=v, speed_from=v_by, progress=progress})
      forecast_basis = routeammo.basis(fo, v_by)
    end
    local legs_text = {}
    for _, l in ipairs(legs) do
      legs_text[#legs_text+1] = string.format('%s->%s %s km, %s%s', l.from, l.to, l.km and tostring(l.km) or '?', l.minutes and mins(l.minutes) or 'time unknown',
        l.now and ' (the rest of the leg it flies)' or l.none and ' (no space connection between them)'
          or l.via_for and ' (on the way ' .. l.via_for .. (l.also and ', ' .. l.also or '') .. ')' or '')
    end
    local fo_all = fo_now or try(function() return M.fuel_outlook(pl, ctx) end)
    local outlook = fo_all and fo_all.line
    local reply = {platform=pl.name, route=route_by, route_note=route_note, ammo_feed=ammo_feed, legs=legs, return_budget=return_budget, total_km=round(total_km, 0), total_minutes=total_min and round(total_min, 1) or nil,
      speed_km_per_min=v and round(v, 1) or nil, speed_from=v_by or 'unknown: stopped, and no finished leg on record (times unknown)',
      resources=rows, hub_slots=string.format('%d of %d free', free, slots), power=power, solar_power=#solar > 0 and table.concat(solar, ', ') or nil,
      lines={'route: ' .. (#legs_text > 0 and table.concat(legs_text, '; ') or 'no legs') .. (total_min and '; in all ' .. mins(total_min) or ''),
        'hub: ' .. string.format('%d of %d slots free', free, slots) .. (power and '; power ' .. power or '') .. (#solar > 0 and '; solar power ' .. table.concat(solar, ', ') or ''),
        'asteroid chunks made (production statistics: the collectors\' catch and the crushers\' returns): ' .. (#chunks > 0 and table.concat(chunks, ', ') or 'none') .. ' (' .. (win_text or 'last 10 min') .. ')'
          .. (places and places.capped and string.format('; belts past the first %d not counted', places.capped) or ''),
        'power: ' .. solar_line .. (power and ' (the network ' .. power .. ')' or ''), 'fuel outlook: ' .. (outlook or 'unread'), ammo_feed},
      solar=solar_line, low_power=low, no_power=none, fuel_outlook=outlook, full_thrust=fo_all and fo_all.full_thrust,
      departure=#departure > 0 and departure or nil, forecast=forecast,
      forecast_damage=forecast_damage and #forecast_damage > 0 and forecast_damage or nil,
      forecast_coverage=forecast_coverage and #forecast_coverage > 0 and forecast_coverage or nil,
      forecast_targets=forecast_targets and #forecast_targets.ammo > 0 and forecast_targets or nil,
      basis=forecast_basis, forecast_model=forecast_model and {basis=forecast_model.basis, estimated=forecast_model.estimated, legs=forecast_model.legs, ammo=forecast_model.ammo, lines=forecast_model.lines} or nil,
      chunks_made=#chunks > 0 and chunks or nil,
      note='rates: flying, the platform\'s production statistics over the last 10 minutes (on a leg younger than that, the last 5 or 1 minute within the leg, and ammunition from the leg\'s own counts); stopped, the last finished leg\'s for ammunition (rate_from), else the flight rate is unknown and nothing is projected; a rate that changes on the way (fights near a planet, thrust) changes the projection'}
    if return_budget then table.insert(reply.lines, 1, return_budget.line) end
    return reply
  end
  -- (d24 batch195 hotfix) Every call reads now. batch187 kept readings in storage and read them again in the
  -- background; on world n a call answered from a kept reading took 80.7 ms against 13.7 ms read in the call
  -- (operator d24 21:18), so both are off. M.tick drops the readings batch187 left in storage, once.
  function M.tick(tick)
    local s = api.state and api.state()
    if s then s.endurance_readings = nil end
  end
  function M.handler(p, a)
    assert(a.fresh == nil or type(a.fresh) == 'boolean', 'fresh is true or false')
    return M.read(p, a)
  end
  M.schema = {platform_endurance = {turnaround='(d29 batch329, Astra #2727) {km | fraction, back_to?, speed_floor?, margin?, reserve?, items?}: (d29 batch339) items: the item or fluid names that may bind (e.g. the ammunition and repair packs), the rest listed, not binding; thruster fuel and oxidizer counted as fuel_outlook counts them (everything aboard, its clean sample of the last 180 or 60 s in the leg; a deficit within a batch a maker: none); the 10-minute rate only when it lies wholly after the leg\'s first 60 s, else the last 5 or 1 minute that does (window); each row\'s stock_scope, usable and usable_basis. a ship in flight read as a partial return: from where it is now, km farther out on the connection it flies (or to the turn point at fraction of the connection from its start), back along it to its start, and on to back_to (a space location; default that start). return_budget: per item the stock that reaches it, its net use the worse of the current phase (this leg so far; ammunition also its moving phase) and the last 10 minutes (both given, phase_from), at the planning speed (speed_floor km/s when below the speed read), with margin (a share kept spare, default 0.1) and reserve (a count for every item or {item: count}): out_km_max (how much farther out it can go before the way back needs the rest: (usable / net x speed - flown - back) / 2), lasts_min, spare_km and left_at_return for the planned turn; binds (the item that binds first); line. No route, design or forecast with it. Read only: nothing lowers a floor or changes the route',forecast='true: forecast, per leg of the route: the asteroids its space connection spawns by kind (the game\'s spawn chance, its mean over the leg; beside it, the legs flown in the last 2 hours, each over the part of its connection flown), for each ammunition aboard the shots one asteroid of each kind takes (its health against the damage after resistances and our bonuses; none hurt: under 1 a hit), and the use: the moving rate on the legs flown scaled by how much more shooting this leg\'s asteroids take, what is made meanwhile, and what is left at each arrival. An estimate from prototypes and measured rates; a shot\'s damage is platform_defense ammo_use\'s (bonuses researched, ammo quality), the "damage a shot" lines give each asteroid\'s resistance arithmetic, forecast_damage [{ammo, turret, damage_per_shot, asteroid, hp, per_hit, shots}]; the calibration: the legs flown in the last 2 hours and the one flown now, each with the part of its connection flown (from freight\'s distance along it), their asteroids the game\'s spawn chance over that part; each route leg says how much of it the legs flown cover and that the rest is the game\'s spawn definition, not measured: forecast_coverage [{leg, flown (the parts flown, joined, the way the leg flies), flights, covered (0..1)}]; (turret targets) the shots count for each ammunition only the asteroids its turrets target as built (each turret\'s priority list: with ignore unprioritised targets on, the listed ones only; off, any), and an asteroid no turret aboard targets counts for none, nor its fragments; an asteroid targeted by turrets of two ammunitions counts in full for each: forecast_targets {ammo [{ammo, turrets, settings [{turret, count, targets (names, any, or unknown)}], mixed}], asteroids [{asteroid, turrets [{turret, count, ammo}]}]}',
    design='optional {width, height | tiles, mass?, speed, ammo?}: a hull not built yet, read only (nothing built, placed or imported), on the platform\'s route with its turrets\' ammunition and settings (or ammo: up to 8 names) and our bonuses: width and height in tiles, or tiles (up to 256: "x0..x1,y0..y1", "x,y" or {x,y}) for their box; speed km/s as the GUI shows it; mass is said and not used (the speed is given; asteroids come per km). Returns design, legs [{from, to, part {f0, f1}, km, minutes, asteroids {kind: count}, total, per_600s, total_per_600s, shots {ammo: shots}}], basis (the spawn line, the count rule and its fit, distance not time, width, speed, progress, shots), estimated (what is not modelled exactly), ammo, lines; a light read: no rates, stock or production read',
    fresh='optional; every call reads now',
    progress='optional {from, to} (0..1), with forecast or design: each leg cut to that part of its connection, the way it is flown (the leg flown now: from where the ship is): its asteroids, km and minutes (a 600 s window\'s count in per_600s)',
    pessimistic='with forecast: {speed: 0.1..1 (a share of the speed read: slower, longer legs), dwell_s: 0..36000 (extra time at each stop at the stopped rate)}',
    platform='platform name', route='optional list of space locations to fly through in order (default: its schedule from the current stop round to it again)',
    returns='with forecast: basis (what the forecast assumes: legs, asteroids, use, box, speed, progress) and forecast_model (the asteroids and shots by the spawn rule with the platform\'s own width and speed, as design gives them); full_thrust (apart from the measured use: the platform\'s thrusters by quality and what they burn at full thrust, the engine\'s figures; quality multiplies a thruster\'s burn and thrust, legendary 2.5 times normal\'s 2 of each a tick); fuel_outlook (one line: thruster fuel and oxidizer held in thrusters and tanks and aboard (the pipes, pumps and makers\' outputs too), made and used a minute over the engine\'s last 180 s (else 60 s) all in the leg, else the last minute, and flying whether what is aboard lasts the rest of the leg at the speed now (a deficit within a batch a maker over that time, while batches land and what is aboard lasts 2 minutes or more, is no deficit: a maker\'s batch counts when its craft ends; the makers\' batch, count, craft time and share of their full output said); its owners get a team alert when one runs out before the leg ends, with how long since the platform left its stop and the engine\'s last 60 and 180 s side by side: each fluid used and made a minute, the thrusters\' tanks at start and end, and the seconds of each sample spent at the stop before it left); each ammunition row adds phases {moving, still, stopped: minutes, used_per_min, made_per_min} (moving: flying, not paused; still: in space, paused or at speed 0; stopped: at a location; recent hours count most) and flight (at the moving rate: what the route\'s flight and its last leg use against what is aboard and made); departure (each ammunition used on the route: what the route uses at the rates read, what is aboard and made on the way, short or to spare, and a rocket\'s lift of it); solar (the solar panels\' peak, at a stop at its solar power, and the machines on low or no power now) with low_power and no_power; flying, each resource line adds the last 60 s apart (last_minute {made, used}); legs [{from, to, km, minutes}], total_km, total_minutes, speed_km_per_min and speed_from (flying: this leg\'s own once its last 60 s are all in the leg and not rising (their mean), the last leg\'s while it speeds up and is under 90% of it, else its speed now, each said; stopped: the last finished leg\'s average; the fuel outlook, the legs\' minutes and the forecast use it), resources [{name, stock (every place aboard), by_place {hub, turrets, belts (an underground pair once), hands (inserters), machines (outputs)}, places, moved (each place\'s change since the leg the rates come from began: loading told from use), made_per_min, used_per_min, rate_from, flight_rate (unknown: stopped with no flight rate on record; nothing projected), ingredient_limited {more, item, have, per_craft, fluid, below {more, item, have}, ingredient_made_per_min, more_per_min, share, shared {product: share}, other_use_per_min} (made from ingredients aboard, two levels down, fluids in tanks and the makers counted: at most more now, growing by more_per_min at the rates the ingredients are made aboard now; an ingredient two products draw on split by their make rates, other machines\' use of it taken off first), received (on rockets launched to it and not arrived, counted once), binds (which limit sets what is made over the route: the stock, the make rate or an ingredient; flight, departure, forecast and preflight\'s ammo_rates count the same way), lasts_min, runs_out_on, at_end, line}] for each ammunition and repair pack aboard or used, thruster-fuel and thruster-oxidizer, hub_slots, power, solar_power at the stops, chunks_made (asteroid chunks made a minute: the production statistics, the collectors\' catch and the crushers\' returns), lines; read only'}}
  return M
end
