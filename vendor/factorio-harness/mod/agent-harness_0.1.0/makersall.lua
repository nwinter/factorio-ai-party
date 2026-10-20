-- makersall: supply {item, surface?, makers: "all"} (d18 batch37 A1-A3, Opus about 10 times a shift with a 16-call grid
-- script; Astra 4+: artillery makers found through bottleneck dumps; Haiku: which shell maker lacked what). Every
-- machine of ours on the surface whose recipe makes the item, from the census pass's per-recipe lists (no search),
-- nearest you first, PAGE a call (from: the next ones). Each row: where, recipe, status, and why when not working: its
-- own circuit or logistic condition with the value it reads now (A2), an input inserter off by its condition, the
-- ingredients short; its rate now (crafts at its speed and productivity, the item a minute); its inputs against what
-- one craft takes (A3); and what its output inserters drop into. Facts only; read only.
return function(api)
  local M = {}
  M.PAGE, M.NEAR = 24, 2.5
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function at(q) return string.format('(%g,%g)', q.x, q.y) end
  local function name_of(v) if type(v) == 'table' or type(v) == 'userdata' then return v.name end return v end
  local made_by = {}
  -- The recipes whose products include item (cached).
  function M.recipes_of(item)
    if made_by[item] then return made_by[item] end
    local out = {}
    for name, r in pairs(prototypes.recipe) do
      for _, pr in ipairs(try(function() return r.products end) or {}) do
        if pr.name == item then out[#out+1] = name; break end
      end
    end
    table.sort(out)
    made_by[item] = out
    return out
  end
  local function per_craft(r, item)
    local n = 0
    for _, pr in ipairs(try(function() return r.products end) or {}) do
      if pr.name == item then
        local amt = pr.amount or ((pr.amount_min or 0) + (pr.amount_max or 0)) / 2
        n = n + amt * (pr.probability or 1)
      end
    end
    return n
  end
  local function input_inv(e)
    local which = e.type == 'furnace' and defines.inventory.furnace_source or defines.inventory.assembling_machine_input
    return try(function() return e.get_inventory(which) end)
  end
  local function output_inv(e)
    local which = e.type == 'furnace' and defines.inventory.furnace_result or defines.inventory.assembling_machine_output
    return try(function() return e.get_inventory(which) end)
  end
  -- (d20 batch53 M2, Sol #1297: a breeder read 31.2 eggs a minute here, 10.4 crafts x 3, where inspect read 26: the
  -- pentapod egg a craft returns is exempt from productivity, 1 + 1 x 1.5 = 2.5 a craft) the rate is inspect's
  -- (craftrate.lua: ignored_by_productivity, the productivity cap), with net per minute when the item goes back in.
  local CR
  local function rates_of(e)
    if CR == nil then local ok, mod = pcall(require, 'craftrate'); CR = ok and mod({}) or false end
    return CR and try(function() return CR.machine(e) end) or nil
  end
  -- One machine's row.
  function M.row(e, recipe, item)
    local row = {name=e.name, position={x=e.position.x, y=e.position.y}, recipe=recipe.name}
    local status = api.status_name and api.status_name(e) or 'unknown'
    row.status = status
    -- inputs against one craft (A3)
    local inv = input_inv(e)
    local parts, short = {}, {}
    for _, ing in ipairs(try(function() return recipe.ingredients end) or {}) do
      local have
      if ing.type == 'fluid' then have = math.floor(try(function() return e.get_fluid_count(ing.name) end) or 0)
      else have = inv and try(function() return inv.get_item_count(ing.name) end) or 0 end
      parts[#parts+1] = string.format('%s %d/%g', ing.name, have, ing.amount)
      if have < ing.amount then short[#short+1] = ing.name end
    end
    row.inputs = table.concat(parts, ', ')
    row.short = #short > 0 and short or nil
    -- the output it holds
    local out = output_inv(e)
    local held = out and try(function() return out.get_item_count(item) end) or 0
    row.output_holds = held
    -- rate now: crafts a minute at its speed and productivity, while working
    local speed = try(function() return e.crafting_speed end) or 0
    local energy = try(function() return recipe.energy end) or 0
    local prod = 1 + (try(function() return e.productivity_bonus end) or 0)
    local each = per_craft(recipe, item)
    if status == 'working' and speed > 0 and energy > 0 then
      local pr
      for _, x in ipairs((rates_of(e) or {}).products or {}) do if x.name == item then pr = x end end
      if pr then
        row.per_min, row.net_per_min, row.ignored_by_productivity = pr.per_min, pr.net_per_min, pr.ignored_by_productivity
      else row.per_min = math.floor(60 / (energy / speed) * prod * each * 10 + 0.5) / 10 end
    else row.per_min = 0 end
    -- why it stops
    local why
    if status == 'disabled_by_control_behavior' then
      why = api.state_text and try(function() return api.state_text(e) end) or 'off by its circuit or logistic condition'
    end
    -- (d18 batch39 B2) a burner stopped by its own spoilage or unusable fuel: what fills its slots
    if (status == 'burnt_result_full' or status == 'fuel_unusable') and api.burnt_line then why = try(function() return api.burnt_line(e) end) or why end
    -- its inserters: those dropping into it (one off by its condition gates it) and those taking out (where they drop)
    local b = e.bounding_box
    local feeds, gated = {}, nil
    for _, ins in ipairs(try(function() return e.surface.find_entities_filtered{area={{b.left_top.x - M.NEAR, b.left_top.y - M.NEAR}, {b.right_bottom.x + M.NEAR, b.right_bottom.y + M.NEAR}}, type='inserter', force=e.force, limit=24} end) or {}) do
      if ins.valid then
        if not gated and try(function() return ins.drop_target end) == e and try(function() return ins.status end) == defines.entity_status.disabled_by_control_behavior then
          gated = string.format('input %s %s %s', ins.name, at(ins.position), api.state_text and try(function() return api.state_text(ins) end) or 'off by its condition')
        end
        if try(function() return ins.pickup_target end) == e and #feeds < 2 then
          local d = try(function() return ins.drop_target end)
          feeds[#feeds+1] = d and d.valid and string.format('%s %s (by %s %s)', d.name, at(d.position), ins.name, at(ins.position))
            or string.format('the ground or a belt at %s (by %s %s)', at(try(function() return ins.drop_position end) or ins.position), ins.name, at(ins.position))
        end
      end
    end
    if not why and gated and status ~= 'working' then why = gated end
    if not why and row.short and status ~= 'working' then why = 'short of ' .. table.concat(row.short, ', ') end
    row.why = why
    row.feeds = #feeds > 0 and feeds or nil
    row.line = string.format('%s %s %s: %s%s; %g a minute%s; inputs %s; output holds %d %s; feeds %s', e.name, at(e.position), recipe.name, (status:gsub('_', ' ')),
      why and ' (' .. why .. ')' or '', row.per_min, row.net_per_min and string.format(' (net %g: %g a minute goes back in)', row.net_per_min, row.per_min - row.net_per_min) or '', row.inputs ~= '' and row.inputs or 'none', held, item,
      #feeds > 0 and table.concat(feeds, '; ') or 'nothing (no output inserter)')
    return row
  end
  function M.read(p, item, surface, a)
    assert(prototypes.item[item], 'makers "all" is for an item')
    assert(a.makers == 'all', 'makers is "all": every machine on the surface whose recipe makes the item')
    local lists = api.census_makers and api.census_makers(surface)
    assert(lists, 'the census pass has not read ' .. surface.name .. ' yet (it reads every surface in turn); try again in a minute')
    local recipes = M.recipes_of(item)
    local all, by_status, by_recipe = {}, {}, {}
    local here = (p.surface == surface) and p.position or {x=0, y=0}
    for _, rn in ipairs(recipes) do
      for _, e in ipairs(lists.craft and lists.craft[rn] or {}) do
        if e.valid and e.force == p.force then
          local d = (e.position.x - here.x) ^ 2 + (e.position.y - here.y) ^ 2
          all[#all+1] = {e=e, d=d, rn=rn}
          local st = api.status_name and api.status_name(e) or 'unknown'
          by_status[st] = (by_status[st] or 0) + 1
          by_recipe[rn] = (by_recipe[rn] or 0) + 1
        end
      end
    end
    table.sort(all, function(x, y) if x.d ~= y.d then return x.d < y.d end return x.e.unit_number < y.e.unit_number end)
    local from = math.max(1, math.floor(tonumber(a.from) or 1))
    local rows, lines = {}, {}
    for i = from, math.min(#all, from + M.PAGE - 1) do
      local x = all[i]
      local recipe = prototypes.recipe[x.rn]
      local r = M.row(x.e, recipe, item)
      r.distance = math.floor(math.sqrt(x.d) + 0.5)
      rows[#rows+1] = r
      lines[#lines+1] = r.line
    end
    local st, rc = {}, {}
    for k, n in pairs(by_status) do st[#st+1] = n .. ' ' .. k end
    for k, n in pairs(by_recipe) do rc[#rc+1] = n .. ' ' .. k end
    table.sort(st); table.sort(rc)
    local last = from + #rows - 1
    return {item=item, surface=surface.name, makers=#all, by_status=st, by_recipe=rc, rows=rows, lines=lines,
      from=from, next_from=last < #all and last + 1 or nil,
      line=string.format('%d machines on %s make %s (%s): %s%s', #all, surface.name, item, #rc > 0 and table.concat(rc, ', ') or 'no recipe of ours',
        #st > 0 and table.concat(st, ', ') or 'none', last < #all and string.format('; %d-%d shown, nearest first; from %d for the next', from, last, last + 1) or ''),
      note='from the census pass\'s per-recipe lists (a machine built since its last pass of the surface is not in them); drills (mine) not counted'}
  end
  return M
end
