-- bottleneck {item, chain: true} (d17 batch31 A1; Sonnet: coal -> petroleum -> plastic -> LDS -> silo, Opus: crude ->
-- refinery -> petroleum -> chem plant -> plastic, each about 30 minutes by hand): the item's recipe chain on a surface
-- walked back from the item, a link per item:
-- - its makers (crafters on the recipe most of them run, other recipes making it, drills on its resource, offshore
--   pumps of the fluid), from the census pass's entity lists (census.lua: no find here), up to READ of them read now:
--   state, crafting or mining speed and productivity;
-- - made and used a minute now (the surface's production statistics, last 10 minutes);
-- - full: what its makers make a minute at full speed (the read makers' average times all of them);
-- - asked: what the link it feeds takes a minute at its full speed (that link's crafts a minute times what one craft
--   takes, net of what the same recipe gives back);
-- - stock: what the surface's logistic networks hold of it (an item).
-- limit: from the item down, while most of a link's read makers lack an input, the ingredient made below what that
-- link asks (the one made the smallest share of its ask); the link where that stops, with its numbers and its own
-- makers' states (input short, output full, no power, off by a condition, or all working with full speed below the
-- ask). Measured numbers only. On world n (06:50, 243 machines listed): 5 links, 38 makers read, 0.8 ms (READ 32).
-- At most LINKS links and DEPTH levels; read only.
return function(api)
  local M = {}
  local LINKS, DEPTH, READ = 16, 8, 24
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function r1(v) return v and math.floor(v * 10 + 0.5) / 10 or nil end
  local function is_fluid(name) return prototypes.fluid and prototypes.fluid[name] ~= nil and not prototypes.item[name] end
  local function amount_of(p) return p.amount or (((p.amount_min or 0) + (p.amount_max or 0)) / 2) end
  -- One craft's output of name: expected amount, productivity on the part not ignored.
  local function per_craft(recipe, name, prod)
    for _, p in ipairs(recipe.products or {}) do
      if p.name == name then
        local amount = amount_of(p) * (p.probability or 1) + (p.extra_count_fraction or 0)
        local ignored = math.min(amount, p.ignored_by_productivity or 0)
        return amount + (amount - ignored) * prod
      end
    end
    return 0
  end
  -- The state classes a link's reason names.
  local CLASS = {working='working', item_ingredient_shortage='input', fluid_ingredient_shortage='input', no_ingredients='input',
    missing_required_fluid='input', no_minable_resources='input', waiting_for_source_items='input',
    full_output='output', output_full='output', waiting_for_space_in_destination='output', full_burnt_result_output='output',
    burnt_result_full='output', no_power='power', low_power='power', no_fuel='power',
    disabled_by_control_behavior='gated', disabled_by_script='gated', disabled='gated', marked_for_deconstruction='gated'}
  local CLASS_TEXT = {input='lack an input', output='have their output full', power='lack power or fuel', gated='are off by a circuit or logistic condition'}

  -- A recipe's or resource's prototype fields, read once (each read of products builds a new table).
  local recipes, resources = {}, {}
  local function recipe_info(key)
    local r = recipes[key]
    if r == nil then
      local pr = try(function() return prototypes.recipe[key] end)
      r = pr and {energy=pr.energy, products=pr.products or {}, ingredients=pr.ingredients or {}} or false
      recipes[key] = r
    end
    return r or nil
  end
  local function resource_info(key)
    local r = resources[key]
    if r == nil then
      local pe = try(function() return prototypes.entity[key] end)
      local mp = pe and try(function() return pe.mineable_properties end)
      r = mp and {props=mp, infinite=pe.infinite_resource, normal=try(function() return pe.normal_resource_amount end)} or false
      resources[key] = r
    end
    return r or nil
  end
  -- The groups making name on the surface: {kind, key, recipe, list}, the most makers first.
  local function groups_of(c, name)
    local out = {}
    for key, list in pairs(c.craft) do
      local r = recipe_info(key)
      if r then
        for _, p in ipairs(r.products) do
          if p.name == name then out[#out+1] = {kind='craft', key=key, recipe=r, list=list}; break end
        end
      end
    end
    for key, list in pairs(c.mine) do
      local ri = resource_info(key)
      for _, p in ipairs(ri and ri.props.products or {}) do
        if p.name == name then out[#out+1] = {kind='mine', key=key, props=ri.props, res=ri, list=list}; break end
      end
    end
    if c.pump[name] then out[#out+1] = {kind='pump', key=name, list=c.pump[name]} end
    table.sort(out, function(x, y) if #x.list ~= #y.list then return #x.list > #y.list end return x.key < y.key end)
    return out
  end
  -- Per minute for one maker of group g at full speed: name made, crafts (or mining cycles) a minute; nil when unknown.
  local function rate_each(g, e, name, force)
    if g.kind == 'craft' then
      local speed = try(function() return e.crafting_speed end) or 0
      local energy = g.recipe.energy or 0
      if energy <= 0 then return nil end
      if g.research == nil then g.research = try(function() return force.recipes[g.key].productivity_bonus end) or 0 end
      local prod = (try(function() return e.productivity_bonus end) or 0) + g.research
      local crafts = 60 * speed / energy
      return crafts * per_craft(g.recipe, name, prod), crafts
    elseif g.kind == 'mine' then
      local mt = g.props.mining_time or 1
      local cycles = 60 * (try(function() return e.prototype.mining_speed end) or 0) * (1 + (try(function() return e.speed_bonus end) or 0)) / mt
      local amount = 0
      for _, p in ipairs(g.props.products or {}) do if p.name == name then amount = amount_of(p) * (p.probability or 1) end end
      local yield = 1
      if g.res.infinite then
        -- a pumpjack: its yield is the resource's amount over the prototype's normal amount
        local normal = g.res.normal or 0
        local left = try(function() return e.mining_target.amount end) or 0
        yield = normal > 0 and left / normal or 0
      end
      return cycles * amount * yield * (1 + (try(function() return e.productivity_bonus end) or 0)), cycles
    elseif g.kind == 'pump' then
      local sp = try(function() return e.prototype.pumping_speed end)
      return sp and sp * 3600 or nil, nil
    end
  end

  function M.read(p, a, surface)
    local item = a.item
    local force = p.force
    local c, as_of = api.makers(surface)
    if not c then
      return {item=item, surface=surface.name, chain=false,
        line='no census pass has listed the machines by recipe since the runtime started (a pass takes about 30 s); bottleneck {item} reads the chain without the rates'}
    end
    local items = try(function() return force.get_item_production_statistics(surface) end)
    local fluids = try(function() return force.get_fluid_production_statistics(surface) end)
    local function per_min(name, category)
      local stats = is_fluid(name) and fluids or items
      local n = stats and try(function()
        return stats.get_flow_count{name=name, category=category, precision_index=defines.flow_precision_index.ten_minutes, count=true}
      end)
      return n and math.floor(n / 10 + 0.5) or 0
    end
    local networks = try(function() return force.logistic_networks[surface.name] end) or {}
    local function stock(name)
      if is_fluid(name) then return nil end
      local n = 0
      for _, net in ipairs(networks) do n = n + (try(function() return net.get_item_count(name) end) or 0) end
      return n
    end
    local links, by, order, queue, read_total = {}, {}, {}, {{item=item, depth=0}}, 0
    local cut
    local qi = 1
    while qi <= #queue do
      local q = queue[qi]; qi = qi + 1
      local name = q.item
      if not by[name] then
        if #links >= LINKS then cut = true; break end
        local L = {item=name, depth=q.depth, makers=0, read=0, working=0, states={}, classes={}, full=0, children={}}
        by[name] = L; links[#links+1] = L
        L.now, L.used = per_min(name, 'input'), per_min(name, 'output')
        L.stock = stock(name)
        local gs = groups_of(c, name)
        local left = READ
        for gi, g in ipairs(gs) do
          local valid, sum, csum, n = {}, 0, 0, 0
          for _, e in ipairs(g.list) do if e.valid and e.force == force then valid[#valid+1] = e end end
          L.makers = L.makers + #valid
          -- (each recipe at least 4, so a second recipe's rate is read too)
          local take = math.min(#valid, math.max(left, 4))
          for i = 1, take do
            local e = valid[i]
            local st = api.status_name(e) or 'unknown'
            L.states[st] = (L.states[st] or 0) + 1
            local cl = CLASS[st] or 'other'
            L.classes[cl] = (L.classes[cl] or 0) + 1
            if st == 'working' then L.working = L.working + 1 end
            local each, crafts = rate_each(g, e, name, force)
            if each then sum = sum + each; n = n + 1 end
            if crafts then csum = csum + crafts end
            L.read = L.read + 1
          end
          local took = take
          left = math.max(0, left - took)
          read_total = read_total + took
          if n > 0 then L.full = L.full + sum / n * #valid end
          g.n, g.crafts = #valid, took > 0 and csum / took * #valid or 0
          if gi == 1 then
            L.machine = valid[1] and valid[1].name or nil
            L.recipe = g.kind == 'craft' and g.key or nil
            L.resource = g.kind == 'mine' and g.key or nil
          end
          L.groups = (L.groups or 0) + 1
          -- what each group takes at its full speed (asks), its main group's ingredients walked further
          local takes = {}
          if g.kind == 'craft' then
            for _, ing in ipairs(g.recipe.ingredients or {}) do
              local amt = amount_of(ing) - per_craft(g.recipe, ing.name, 0)
              if amt > 0 then takes[#takes+1] = {name=ing.name, per=amt} end
            end
          elseif g.kind == 'mine' and g.props.required_fluid then
            -- (the engine takes fluid_amount / 10 a mining cycle)
            takes[#takes+1] = {name=g.props.required_fluid, per=(g.props.fluid_amount or 0) / 10}
          end
          for _, t in ipairs(takes) do
            local ask = g.crafts * t.per
            if gi == 1 and q.depth < DEPTH then
              L.children[#L.children+1] = t.name
              queue[#queue+1] = {item=t.name, depth=q.depth + 1, parent=name}
            end
            L.asks = L.asks or {}
            L.asks[#L.asks+1] = {name=t.name, ask=ask, by=g.key}
          end
        end
      end
    end
    -- What the links it feeds ask of each.
    for _, L in ipairs(links) do
      for _, t in ipairs(L.asks or {}) do
        local C = by[t.name]
        if C and t.ask > 0 then
          C.asked = (C.asked or 0) + t.ask
          C.asked_by = C.asked_by or {}
          C.asked_by[#C.asked_by+1] = string.format('%s %g/min', t.by, r1(t.ask))
        end
      end
    end
    local function states_text(L)
      local parts = {}
      for s, k in pairs(L.states) do parts[#parts+1] = {s=s, k=k} end
      table.sort(parts, function(x, y) if x.k ~= y.k then return x.k > y.k end return x.s < y.s end)
      local out = {}
      for i, s in ipairs(parts) do out[i] = s.k .. ' ' .. s.s end
      return table.concat(out, ', ')
    end
    local function link_line(L)
      local who
      if L.makers == 0 then who = 'no assembler, furnace, silo, mining drill or offshore pump of ours makes it'
      else
        who = string.format('%d %s%s%s (%s%s)', L.makers, L.machine or 'maker', L.recipe and ' on ' .. L.recipe or (L.resource and ' on ' .. L.resource or ''),
          (L.groups or 0) > 1 and string.format(' and %d other recipe%s', L.groups - 1, L.groups == 2 and '' or 's') or '',
          L.read < L.makers and string.format('%d of them read: ', L.read) or '', states_text(L))
      end
      return string.format('%s: %s; made %d/min now (used %d/min), %g/min at full speed%s%s', L.item, who, L.now, L.used, r1(L.full) or 0,
        L.asked and string.format('; asked %g/min at full speed by %s', r1(L.asked), table.concat(L.asked_by, ', ')) or '',
        L.stock and string.format('; logistic networks hold %d', L.stock) or '')
    end
    -- The limit: down from the item, the child made the smallest share of its ask while below it.
    local at, walked = links[1], {}
    while at and not walked[at.item] do
      walked[at.item] = true
      -- down only from a link whose makers mostly lack an input (an output full or no power stops it there)
      local most, mk = nil, 0
      for cl, k in pairs(at.classes) do if k > mk or (k == mk and cl == 'input') then most, mk = cl, k end end
      if most ~= 'input' then break end
      local best, share
      for _, child in ipairs(at.children) do
        local C = by[child]
        if C and C.asked and C.asked > 0 and C.now < C.asked then
          local s = C.now / C.asked
          if not share or s < share then best, share = C, s end
        end
      end
      if not best then break end
      at = best
    end
    local limit
    if at then
      local main, mk
      for cl, k in pairs(at.classes) do if cl ~= 'other' and (not mk or k > mk or (k == mk and cl ~= 'working')) then main, mk = cl, k end end
      local why
      if at.makers == 0 then why = 'no maker of ours on the surface'
      elseif main and main ~= 'working' then why = string.format('%d of the %d read %s (%s)', mk, at.read, CLASS_TEXT[main], states_text(at))
      elseif at.asked and at.full < at.asked then why = string.format('%d of the %d read working; full speed %g/min is below the ask', at.working, at.read, r1(at.full))
      else why = string.format('%d of the %d read working (%s)', at.working, at.read, states_text(at)) end
      limit = {item=at.item, made_per_min=at.now, asked_per_min=r1(at.asked), full_per_min=r1(at.full), makers=at.makers, reason=why,
        line=string.format('limit: %s: made %d/min now%s, %g/min at full speed; %s', at.item, at.now,
          at.asked and string.format(', below the %g/min asked at full speed (%s)', r1(at.asked), table.concat(at.asked_by, ', ')) or ' (the item read)', r1(at.full) or 0, why)}
    end
    local rows, lines = {}, {}
    for _, L in ipairs(links) do
      local line = link_line(L)
      lines[#lines+1] = line
      rows[#rows+1] = {item=L.item, depth=L.depth, recipe=L.recipe, resource=L.resource, machine=L.machine, makers=L.makers, read=L.read,
        working=L.working, states=next(L.states) and L.states or nil, made_per_min=L.now, used_per_min=L.used, full_per_min=r1(L.full),
        asked_per_min=r1(L.asked), asked_by=L.asked_by, stock=L.stock, line=line}
    end
    return {item=item, surface=surface.name, chain=true, links=rows, lines=lines, limit=limit, limit_line=limit and limit.line or nil,
      read=read_total, cut=cut and string.format('the first %d links (the walk stops there)', LINKS) or nil,
      as_of=as_of and string.format('machines as the census pass that began %ds ago listed them; their state, speed and the rates read now', math.floor((game.tick - as_of) / 60)) or nil}
  end
  return M
end
