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
        conds[#conds+1] = 'circuit condition ' .. c.enable .. (wired and first and string.format(' (%s %d on its wires)', first.name, n) or wired and '' or ' (no wire)')
      end
      if type(c.logistic) == 'string' then conds[#conds+1] = 'logistic condition ' .. c.logistic .. (c.logistic_reads and ' (' .. c.logistic_reads .. ')' or '') end
      return 'off by its ' .. (#conds > 0 and table.concat(conds, ' and ') or 'circuit or logistic condition')
    end
    local words = {no_power='no power', low_power='low power', full_output='output full', no_recipe='no recipe',
      item_ingredient_shortage='short of an item ingredient', fluid_ingredient_shortage='short of a fluid ingredient',
      no_ingredients='no ingredients', no_input_fluid='no input fluid', waiting_for_space_in_destination='waiting for space'}
    return words[st] or st:gsub('_', ' ')
  end
  local function recipe_of(e)
    local r = try(function() return e.get_recipe() end)
    if not r and e.type == 'furnace' then r = try(function() return e.previous_recipe end) end
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
      ctx.machines = try(function() return ctx.pl.surface.find_entities_filtered{type={'assembling-machine', 'furnace'}, force=ctx.pl.force} end) or {}
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

  -- The platform's thrusters: {count, inputs = {fluid -> {low thrusters, lowest share}}, lines}
  -- lines: one per input under LOW in any thruster, the chain behind it.
  function M.read(pl)
    local s = try(function() return pl.surface end)
    if not s then return nil end
    local thrusters = try(function() return s.find_entities_filtered{type='thruster', force=pl.force} end) or {}
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
