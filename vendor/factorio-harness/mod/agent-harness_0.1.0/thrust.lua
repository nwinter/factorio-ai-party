-- What a platform's thrusters lack and the chain behind it (operator 10:53,
-- Astra: a platform flying under 5 km/s showed only a tank percent): each
-- thruster input (thruster fuel, oxidizer) under half full, the pumps and
-- pipes upstream of it, the machines making that fluid and why they stop, and
-- for an ingredient they lack, the machines making that (crushers, ice
-- melting) down to the asteroid chunks in the hub. Read from the entities as
-- their GUIs show them (status, contents, circuit condition); walked through
-- the fluid boxes' pipe connections as the game joins them.
return function(api)
  local M = {}
  M.LOW = 0.5            -- a tank under half full lacks its fluid
  local MAX_BOXES = 400  -- fluid boxes walked upstream of one input
  local MAX_TEXT = 480   -- characters of one input's line
  local PASS = {pipe=true, ['pipe-to-ground']=true, ['storage-tank']=true}
  local MACHINE = {['assembling-machine']=true, furnace=true}
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local status_names = {}
  for k, v in pairs(defines.entity_status or {}) do status_names[v] = k end
  local function at(e) return string.format('(%g,%g)', e.position.x, e.position.y) end
  -- A fluid box's production type; a crafting machine's box merged by its
  -- recipe gives a list of prototypes (the first one's type).
  local function production(box, i)
    local pr = try(function() return box.get_prototype(i) end)
    if type(pr) == 'table' and pr[1] then pr = pr[1] end
    return pr and try(function() return pr.production_type end)
  end
  local function pct(x) return math.floor(x * 100 + 0.5) .. '%' end

  -- A thruster's own tanks: {fluid, amount, capacity, share} per input box.
  local function tanks(t)
    local out = {}
    local fb = t.fluidbox
    for i = 1, (try(function() return #fb end) or 0) do
      local f = try(function() return fb[i] end)
      local cap = try(function() return t.prototype.fluidbox_prototypes[i].volume end) or try(function() return fb.get_capacity(i) end) or 0
      local name = f and f.name or try(function() return fb.get_filter(i).name end) or ('input ' .. i)
      out[#out+1] = {index=i, fluid=name, amount=f and f.amount or 0, capacity=cap, share=cap > 0 and (f and f.amount or 0) / cap or 0}
    end
    return out
  end

  -- Upstream of fluid box (box, index): through pipes, underground pipes and
  -- tanks; through a pump only when it pushes toward us (then on from its input
  -- side). Returns pumps, makers (machines whose box there is an output) and
  -- tanks met, in the order reached.
  function M.upstream(box, index)
    local function key(e, i) return (try(function() return e.unit_number end) or 0) * 16 + i end
    local seen = {[key(box.owner, index)] = true}
    local queue, head = {{box=box, i=index}}, 1
    local out = {pumps={}, makers={}, tanks={}}
    while head <= #queue and head <= MAX_BOXES do
      local cur = queue[head]; head = head + 1
      for _, pc in ipairs(try(function() return cur.box.get_pipe_connections(cur.i) end) or {}) do
        local target = pc.target
        local e = target and try(function() return target.owner end)
        local j = pc.target_fluidbox_index or 1
        if e and (not cur.only_input or pc.flow_direction == 'input') and not seen[key(e, j)] then
          seen[key(e, j)] = true
          if PASS[e.type] then
            if e.type == 'storage-tank' then out.tanks[#out.tanks+1] = e end
            queue[#queue+1] = {box=target, i=j}
          elseif e.type == 'pump' then
            -- Its side facing us: output = it pushes toward us.
            local toward
            for _, back in ipairs(try(function() return target.get_pipe_connections(j) end) or {}) do
              local o = back.target and try(function() return back.target.owner end)
              if o == cur.box.owner then toward = back.flow_direction end
            end
            if toward == 'output' then
              out.pumps[#out.pumps+1] = e
              queue[#queue+1] = {box=target, i=j, only_input=true}
            end
          elseif MACHINE[e.type] then
            local kind = production(target, j)
            if kind == 'output' or kind == 'input-output' then out.makers[#out.makers+1] = {entity=e, index=j} end
          end
        end
      end
    end
    return out
  end

  -- An entity's state as its GUI shows it, in words; a circuit or logistic
  -- condition that stops it is quoted.
  local function state_text(e)
    local st = status_names[try(function() return e.status end)] or 'unknown'
    if st == 'disabled_by_control_behavior' then
      -- The conditions as its circuit GUI shows them, with the signal's value on its wires now.
      local c = api.circuit and try(function() return api.circuit(e) end) or {}
      local conds = {}
      if type(c.enable) == 'string' then
        -- Its first signal on the entity's red and green networks now, as the condition reads it.
        local cb = try(function() return e.get_control_behavior() end)
        local first = cb and try(function() return cb.circuit_condition.first_signal end)
        local n, wired = 0, false
        for _, w in ipairs({defines.wire_connector_id.circuit_red, defines.wire_connector_id.circuit_green}) do
          local net = try(function() return e.get_circuit_network(w) end)
          if net then wired = true; n = n + (first and try(function() return net.get_signal(first) end) or 0) end
        end
        -- (d28 batch306 QL) the signal with its quality, as the condition reads it
        local q = first and first.quality
        if type(q) ~= 'string' then q = q and try(function() return q.name end) end
        local label = first and (q and q ~= 'normal' and first.name .. '@' .. q or first.name)
        conds[#conds+1] = 'circuit condition ' .. c.enable .. (wired and first and string.format(' (%s %d on its wires)', label, n) or wired and '' or ' (no wire)')
      end
      if type(c.logistic) == 'string' then conds[#conds+1] = 'logistic condition ' .. c.logistic .. (c.logistic_reads and ' (' .. c.logistic_reads .. ')' or '') end
      return 'off by its ' .. (#conds > 0 and table.concat(conds, ' and ') or 'circuit or logistic condition')
    end
    local words = {no_power='no power', low_power='low power', full_output='output full', no_recipe='no recipe',
      item_ingredient_shortage='short of an item ingredient', fluid_ingredient_shortage='short of a fluid ingredient',
      no_ingredients='no ingredients', no_input_fluid='no input fluid', waiting_for_space_in_destination='waiting for space'}
    return words[st] or st:gsub('_', ' ')
  end
  M.state_text = state_text
  local function recipe_of(e)
    local r = try(function() return e.get_recipe() end)
    if not r and e.type == 'furnace' then
      -- (d26 batch248 R3) {name=prototype (userdata), quality}
      local prev = try(function() return e.previous_recipe end)
      local n = prev and prev.name
      if n and type(n) ~= 'string' then n = try(function() return n.name end) end
      r = n and try(function() return prototypes.recipe[n] end) or prev
    end
    return r
  end
  -- What a machine holds of an ingredient: its input slots, or the fluid box of it.
  local function held(e, ing)
    if ing.type == 'fluid' then
      local fb = e.fluidbox
      for i = 1, (try(function() return #fb end) or 0) do
        local f = try(function() return fb[i] end)
        local filter = try(function() return fb.get_filter(i).name end)
        local kind = production(fb, i)
        if (f and f.name == ing.name) or (kind == 'input' and filter == ing.name) then return f and f.amount or 0, i end
      end
      return 0
    end
    local inv = try(function() return e.get_inventory(defines.inventory.assembling_machine_input) end)
      or try(function() return e.get_inventory(defines.inventory.furnace_source) end)
    return inv and try(function() return inv.get_item_count(ing.name) end) or 0
  end
  local function hub_count(pl, item)
    local hub = try(function() return pl.hub end)
    local inv = hub and hub.valid and try(function() return hub.get_inventory(defines.inventory.hub_main) end)
    return inv and try(function() return inv.get_item_count(item) end) or 0
  end
  -- The machines on the platform whose recipe makes item (crushers, ...).
  local function makers_of(ctx, item)
    if not ctx.machines then
      -- (d22 batch96 BF1) the census pass's list of them (no find over the platform), else a find
      ctx.machines = api.census_typed and try(function() return api.census_typed(ctx.pl.force, ctx.pl.surface, {'assembling-machine', 'furnace'}) end)
        or try(function() return ctx.pl.surface.find_entities_filtered{type={'assembling-machine', 'furnace'}, force=ctx.pl.force} end) or {}
    end
    local out = {}
    for _, e in ipairs(ctx.machines) do
      local r = recipe_of(e)
      for _, pr in ipairs(r and try(function() return r.products end) or {}) do
        if pr.name == item then out[#out+1] = e; break end
      end
    end
    return out
  end
  -- A machine in words, and (to depth 3) why it lacks an ingredient: what it
  -- holds of each, then the machines making the one it lacks; an asteroid
  -- chunk leads to the hub's count and the collectors.
  local function explain(ctx, e, depth, parts)
    if ctx.done[e] then return end
    ctx.done[e] = true
    local r = recipe_of(e)
    local text = string.format('%s %s %s: %s', e.name, at(e), r and r.name or 'no recipe', state_text(e))
    local missing = {}
    if r and status_names[try(function() return e.status end)] ~= 'working' then
      local have = {}
      for _, ing in ipairs(try(function() return r.ingredients end) or {}) do
        local n = held(e, ing)
        have[#have+1] = string.format('%s %g', ing.name, math.floor(n * 10 + 0.5) / 10)
        if n < (ing.amount or 1) then missing[#missing+1] = ing end
      end
      if #have > 0 then text = text .. ' (holds ' .. table.concat(have, ', ') .. ')' end
    end
    parts[#parts+1] = text
    if depth >= 3 then return end
    for _, ing in ipairs(missing) do
      if ing.type == 'item' and ing.name:find('asteroid%-chunk$') then
        parts[#parts+1] = string.format('hub %s %d; %d asteroid collectors', ing.name, hub_count(ctx.pl, ing.name), ctx.collectors or 0)
      elseif ing.type == 'fluid' then
        local _, index = held(e, ing)
        local up = index and M.upstream(e.fluidbox, index) or {pumps={}, makers={}, tanks={}}
        for _, pmp in ipairs(up.pumps) do
          if status_names[try(function() return pmp.status end)] ~= 'working' then parts[#parts+1] = 'pump ' .. at(pmp) .. ': ' .. state_text(pmp) end
        end
        if #up.makers == 0 then parts[#parts+1] = 'no machine making ' .. ing.name .. ' is connected to it' end
        for _, m in ipairs(up.makers) do explain(ctx, m.entity, depth + 1, parts) end
      else
        local from = makers_of(ctx, ing.name)
        parts[#parts+1] = string.format('hub %s %d', ing.name, hub_count(ctx.pl, ing.name))
        if #from == 0 then parts[#parts+1] = 'no machine on the platform makes ' .. ing.name end
        for _, m in ipairs(from) do explain(ctx, m, depth + 1, parts) end
      end
    end
  end

  -- (d22 batch96 BF1) the platform's thrusters, found once a tick (the platforms read asked read and after_pumps for
  -- them in the same tick, each a find over the whole platform)
  local thr_found = {}
  local function found(s, force)
    local tick = game and game.tick
    local c = tick and thr_found[s.index]
    if c and c.tick == tick and c.force == force.name then
      local ok = true
      for _, t in ipairs(c.list) do if not t.valid then ok = false; break end end
      if ok then return c.list end
    end
    local list = try(function() return s.find_entities_filtered{type='thruster', force=force} end) or {}
    if tick then thr_found[s.index] = {tick=tick, force=force.name, list=list} end
    return list
  end
  -- The platform's thrusters: {count, inputs = {fluid -> {low thrusters, lowest share}}, lines}
  -- lines: one per input under LOW in any thruster, the chain behind it.
  function M.read(pl)
    local s = try(function() return pl.surface end)
    if not s then return nil end
    local thrusters = found(s, pl.force)
    local out = {count=#thrusters, lowest={}, lines={}}
    if #thrusters == 0 then return out end
    local ctx = {pl=pl, done={}}
    ctx.collectors = try(function() return s.count_entities_filtered{type='asteroid-collector', force=pl.force} end) or 0
    local by = {}  -- fluid -> {low = {thruster, share}, box of the first low one}
    for _, t in ipairs(thrusters) do
      for _, tk in ipairs(tanks(t)) do
        out.lowest[tk.fluid] = math.min(out.lowest[tk.fluid] or 1, tk.share)
        if tk.share < M.LOW then
          local b = by[tk.fluid]
          if not b then b = {low={}, fluid=tk.fluid}; by[tk.fluid] = b; by[#by+1] = b end
          b.low[#b.low+1] = {thruster=t, share=tk.share, index=tk.index}
        end
      end
    end
    for _, b in ipairs(by) do
      local parts = {}
      local list = {}
      for i = 1, math.min(3, #b.low) do list[i] = 'thruster ' .. at(b.low[i].thruster) .. ' ' .. pct(b.low[i].share) end
      parts[1] = b.fluid .. ': ' .. table.concat(list, ', ') .. (#b.low > 3 and string.format(' +%d more', #b.low - 3) or '')
      local first = b.low[1]
      local up = M.upstream(first.thruster.fluidbox, first.index)
      for _, pmp in ipairs(up.pumps) do parts[#parts+1] = 'pump ' .. at(pmp) .. ': ' .. state_text(pmp) end
      for _, tank in ipairs(up.tanks) do
        local f = try(function() return tank.fluidbox[1] end)
        parts[#parts+1] = string.format('tank %s holds %s %d', at(tank), f and f.name or b.fluid, f and math.floor(f.amount) or 0)
      end
      if #up.makers == 0 then
        parts[#parts+1] = 'no machine making ' .. b.fluid .. ' is connected to it'
      else
        for _, m in ipairs(up.makers) do explain(ctx, m.entity, 0, parts) end
      end
      local line = table.concat(parts, '; ')
      if #line > MAX_TEXT then line = line:sub(1, MAX_TEXT - 3) .. '...' end
      out.lines[#out.lines+1] = line
    end
    return out
  end
  -- How long a thruster burns on what it holds with no supply (Grok, shift17 20:40: an oxidizer pump cut at V >= 15
  -- and the leg peaked at 51 km/s). Measured on 2.0.77, its prototype's min_performance {fluid_volume 0.1, fluid_usage
  -- 0.1, effectivity 1} and max_performance {0.8, 2, 0.51} per tank of 1000: at 80% full or more it burns 2 of each
  -- fluid a tick; between 80% and 10%, linearly less (0.1 a tick at 10%); below 10%, 0.1 a tick until empty. Its thrust
  -- is the use times the effectivity (0.51 at 80%, 1 at 10%), so it falls to about a tenth. From amount a (per tank):
  -- {full_s (at 80% or more), to_10_s (until 10%), equiv_s (seconds of full thrust in all, to 10%), empty_s}.
  -- (d27 batch294 TQ, Sol #2645: Resolute's 4 legendary thrusters burned 70152 fuel a minute against the 28800 the
  -- normal rule gave) quality multiplies the burn at both ends and the thrust alike by the quality's default_multiplier
  -- (1.3, 1.6, 1.9, 2.5), the 80% and 10% points stay, and the rate follows the emptier of a thruster's two tanks.
  -- Measured on the iMac copy: 5 of each a tick per legendary thruster at full, 0.25 at the floor; 2+2+5+3.2 = 12.2 a
  -- tick for normal, normal, legendary, rare; the speed gained a tick less the drag 1.3, 1.6, 1.9 and 2.5 times
  -- normal's. mult (default 1) is that multiplier.
  M.TANK = 1000
  function M.burn(a, volume, mult)
    volume = volume or M.TANK
    mult = mult or 1
    local hi, lo = 0.8 * volume, 0.1 * volume
    local umax, umin = 2 * mult, 0.1 * mult
    local slope = (umax - umin) / (hi - lo)
    local ticks_full, ticks_mid, thrust = 0, 0, 0
    local x = a
    if x > hi then ticks_full = (x - hi) / umax; thrust = thrust + (x - hi) * 0.51; x = hi end
    if x > lo then
      -- dx/dt = -(umin + slope (x - lo)): exponential toward lo - umin/slope.
      local y0, y1 = x - lo + umin / slope, umin / slope
      ticks_mid = math.log(y0 / y1) / slope
      -- the thrust over it: the effectivity integrated over the fluid used (linear 1 at lo to 0.51 at hi)
      local function eff(v) return 1 - (v - lo) / (hi - lo) * 0.49 end
      thrust = thrust + (x - lo) * (eff(x) + eff(lo)) / 2
      x = lo
    end
    local ticks_low = x / umin
    local function s(ticks) return math.floor(ticks / 6 + 0.5) / 10 end
    return {full_s=s(ticks_full), to_10_s=s(ticks_full + ticks_mid), equiv_s=s(thrust / (umax * 0.51)), empty_s=s(ticks_full + ticks_mid + ticks_low)}
  end
  M.RULE = 'a thruster burns fuel and oxidizer alike, at a rate the emptier of its two tanks (1000 each) sets: a normal '
    .. 'thruster 2 of each a tick while that tank is 80% full or more, linearly less down to 0.1 a tick at 10%, and 0.1 a '
    .. 'tick below; quality multiplies the burn and the thrust alike (uncommon 1.3, rare 1.6, epic 1.9, legendary 2.5: a '
    .. 'legendary thruster burns 5 of each a tick at full thrust and 0.25 at the floor), at the same 80% and 10%; its '
    .. 'thrust falls with the burn to about a tenth (use x effectivity 0.51 at 80%, 1 at 10%). From full tanks with no '
    .. 'supply a normal thruster gives 1.7 s at full thrust, 20.1 s until 10%, about 10.3 s of full thrust in all (a '
    .. 'legendary one 0.7 s, 8 s, 4.1 s). With no thrust (or a tenth of it) a platform slows, then drifts backward at up '
    .. 'to 10 km/s. Measured on 2.0.77: a 170 t, 21-tile-wide test platform with 1 normal thruster went from 0 to 86 '
    .. 'km/s in 6 s on one full tank with no supply; on a copy of Resolute, 4 legendary thrusters burned 5 of each a '
    .. 'tick at full and gave 2.5 times the thrust 4 normal ones gave at the same speed'
  -- A thruster's quality: its name and the multiplier the game applies to its burn and thrust.
  local function qual(t)
    local q = try(function() return t.quality end)
    local name = q and try(function() return q.name end) or 'normal'
    local m = q and (try(function() return q.default_multiplier end) or try(function() return 1 + 0.3 * q.level end)) or 1
    return name, m
  end
  M.quality = qual
  local function g(x) return string.format('%g', math.floor(x * 100 + 0.5) / 100) end
  -- Thrusters by quality, lowest multiplier first: {{quality, count, mult}}, their multipliers summed, and the text
  -- "2 normal, 1 rare x1.6" (one quality: "legendary x2.5").
  local function groups(list)
    local by, out, sum = {}, {}, 0
    for _, t in ipairs(list) do
      local name, m = qual(t)
      if not by[name] then by[name] = {quality=name, count=0, mult=m}; out[#out+1] = by[name] end
      by[name].count = by[name].count + 1; sum = sum + m
    end
    table.sort(out, function(a, b) if a.mult ~= b.mult then return a.mult < b.mult end return a.quality < b.quality end)
    local parts = {}
    for i, x in ipairs(out) do parts[i] = (#out > 1 and x.count .. ' ' or '') .. x.quality .. (x.mult ~= 1 and ' x' .. g(x.mult) or '') end
    return out, sum, table.concat(parts, ', ')
  end
  M.groups = groups
  -- (TQ) the platform's thrusters by quality and what they burn at full thrust, as the engine runs them: {count,
  -- groups, mult_sum (thrust in normal thrusters'), per_tick (of each fluid, all of them at 80% or more), per_s, per_min,
  -- line}; nil with no thruster. (d28 batch304 EC) thrusters: optional, the ones a caller found in this call.
  function M.qualities(pl, thrusters)
    local s = try(function() return pl.surface end)
    if not s then return nil end
    local list = thrusters or found(s, pl.force)
    if #list == 0 then return nil end
    local gr, sum, text = groups(list)
    local each = {}
    for i, x in ipairs(gr) do each[i] = g(2 * x.mult) .. (#gr > 1 and ' ' .. x.quality or '') end
    local out = {count=#list, groups=gr, mult_sum=sum, per_tick=2 * sum, per_s=120 * sum, per_min=7200 * sum}
    local one = #list == 1
    out.line = string.format('%d thruster%s, %s: at full thrust (the emptier tank 80%% full or more) %s %s fuel and %s '
      .. 'oxidizer a tick%s (%s a second, %s a minute of each%s), thrust %s times one normal thruster\'s (the engine\'s figures for '
      .. '%s quality, not measured use)', #list, one and '' or 's', text, one and 'it burns' or 'they burn', g(2 * sum),
      g(2 * sum), one and '' or ' in all', g(120 * sum), g(7200 * sum), one and '' or '; ' .. table.concat(each, ', ') .. ' a tick a thruster',
      g(sum), one and 'its' or 'their')
    return out
  end
  -- What stays with the thrusters when their pumps stop: per fluid, the thrusters' own tanks and the pipes and tanks
  -- between them and the pumps that push toward them (the walk stops at a pump), and how long that burns.
  local function walk(pl)
    local s = try(function() return pl.surface end)
    if not s then return nil end
    local thrusters = found(s, pl.force)
    if #thrusters == 0 then return nil end
    local by, order = {}, {}
    for _, t in ipairs(thrusters) do
      for _, tk in ipairs(tanks(t)) do
        local b = by[tk.fluid]
        if not b then b = {fluid=tk.fluid, thrusters=0, own=0, between=0, seen={}, pumps={}, pump_seen={}, list={}}; by[tk.fluid] = b; order[#order+1] = b end
        b.thrusters = b.thrusters + 1; b.own = b.own + tk.amount; b.list[#b.list+1] = t
        local queue, head = {{box=t.fluidbox, i=tk.index}}, 1
        while head <= #queue and head <= MAX_BOXES do
          local cur = queue[head]; head = head + 1
          for _, pc in ipairs(try(function() return cur.box.get_pipe_connections(cur.i) end) or {}) do
            local target = pc.target
            local e = target and try(function() return target.owner end)
            local j = pc.target_fluidbox_index or 1
            local k = e and ((try(function() return e.unit_number end) or 0) * 16 + j)
            if e and PASS[e.type] and not b.seen[k] then
              b.seen[k] = true
              local f = try(function() return target[j] end)
              if f and f.name == tk.fluid then b.between = b.between + f.amount end
              queue[#queue+1] = {box=target, i=j}
            elseif e and e.type == 'pump' and not b.pump_seen[k] then
              b.pump_seen[k] = true; b.pumps[#b.pumps+1] = e
            end
          end
        end
      end
    end
    return order
  end
  function M.after_pumps(pl)
    local order = walk(pl)
    if not order then return nil end
    local lines, low = {}, nil
    for _, b in ipairs(order) do
      local each = (b.own + b.between) / b.thrusters
      local gr, sum, text = groups(b.list)
      -- (TQ) at the thrusters' own quality: one pool kept level by the pipes burns at their mean multiplier
      local r = M.burn(each, nil, sum / b.thrusters)
      local rates = {}
      for i, x in ipairs(gr) do rates[i] = g(2 * x.mult) .. (#gr > 1 and ' ' .. x.quality or '') end
      local pumps = {}
      for i = 1, math.min(2, #b.pumps) do pumps[i] = 'pump ' .. at(b.pumps[i]) .. ': ' .. state_text(b.pumps[i]) end
      lines[#lines+1] = string.format('%s: if its pumps stop, %d thruster%s (%s) %s %d and the pipes and tanks between them and the pumps %d (%d a thruster): '
        .. 'at full thrust %s a tick%s: about %g s of full thrust, %g s until 10%%, then %s a tick%s until empty at %g s%s%s',
        b.fluid, b.thrusters, b.thrusters == 1 and '' or 's', text, b.thrusters == 1 and 'holds' or 'hold',
        math.floor(b.own + 0.5), math.floor(b.between + 0.5), math.floor(each + 0.5), g(2 * sum),
        b.thrusters > 1 and ' in all (' .. table.concat(rates, ', ') .. ' a thruster)' or '',
        r.equiv_s, r.to_10_s, g(0.1 * sum), b.thrusters > 1 and ' in all' or '', r.empty_s,
        #gr > 1 and string.format(' (mixed qualities: one pool kept level by the pipes, at their mean x%s)', g(sum / b.thrusters)) or '',
        #pumps > 0 and '; ' .. table.concat(pumps, '; ') or '; no pump between them and the rest of the line')
      if not low or r.equiv_s < low.r.equiv_s then low = {b=b, r=r} end
    end
    if #order > 1 and low then
      lines[#lines+1] = string.format('both fluids burn alike at the rate the emptier tank sets: the thrust lasts as %s does (about %g s of full thrust, %g s until 10%%)',
        low.b.fluid, low.r.equiv_s, low.r.to_10_s)
    end
    local q = M.qualities(pl)
    return {lines=lines, rule=(q and q.line .. '; ' or '') .. M.RULE, thrusters=q}
  end
  -- (d20 batch60 V5, Astra #1594: Kestrel II's pumps feed the thrusters only under 40 km/s) the pumps pushing toward
  -- the thrusters, per fluid, as their GUIs show them: {fluid: {pumps, working, line}}; line groups them by state
  -- ("2 of 4 working; 2 off by its circuit condition signal-V < 40 (signal-V 46 on its wires)"); nil with no thruster.
  function M.pump_states(pl)
    local order = walk(pl)
    if not order then return nil end
    local out = {}
    for _, b in ipairs(order) do
      local by, keys, working = {}, {}, 0
      for _, e in ipairs(b.pumps) do
        local text = status_names[try(function() return e.status end)] == 'working' and 'working' or state_text(e)
        if text == 'working' then working = working + 1 end
        if not by[text] then by[text] = 0; keys[#keys+1] = text end
        by[text] = by[text] + 1
      end
      local parts = {}
      for _, k in ipairs(keys) do
        if k == 'working' then table.insert(parts, 1, string.format('%d of %d working', by[k], #b.pumps))
        else parts[#parts+1] = string.format('%d %s', by[k], k) end
      end
      if working == 0 and #b.pumps > 0 then table.insert(parts, 1, string.format('0 of %d working', #b.pumps)) end
      out[b.fluid] = {pumps=#b.pumps, working=working,
        line=#b.pumps > 0 and table.concat(parts, '; ') or 'no pump between the thrusters and the rest of the line'}
    end
    return out
  end
  -- The thrusters' tanks in one phrase: "thruster-fuel 99%, thruster-oxidizer 18%" (the lowest of each).
  function M.lowest_text(r)
    local names = {}
    for name in pairs(r.lowest) do names[#names+1] = name end
    table.sort(names)
    for i, name in ipairs(names) do names[i] = name .. ' ' .. pct(r.lowest[name]) end
    return table.concat(names, ', ')
  end
  return M
end
