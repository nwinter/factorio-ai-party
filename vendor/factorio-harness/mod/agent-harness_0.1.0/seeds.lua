-- Seed loops (d17 batch32 A3, Grok twice on Gleba: the pentapod egg and copper bacteria loops died between checks; the
-- machines eat their own seed and cannot restart without it). A seed is an item a recipe both takes and makes and that
-- spoils: pentapod-egg, copper-bacteria, iron-bacteria. Every CHECK ticks one surface in turn is read: our crafters
-- whose recipe takes a seed (the census pass's list: no find), and what holds that seed there: the machines' input and
-- output, the hands of the inserters round them, their feeders' sources outside a logistic network (chests, belts),
-- and the surface's logistic networks. A seed is low when that is under one craft for each machine using it (LOW_CRAFTS
-- crafts) or when everything held spoils within SPOIL_SOON; zero when none is left. Each state change goes once to the
-- builders of those machines and of their feeding inserters, as a line that wakes them (from "seed alert"); a loop that
-- recovers is news again when it drops. Only the places read are counted: an egg on a belt no inserter of these
-- machines takes from is not seen.
return function(api)
  local M = {}
  M.SEEDS = {['pentapod-egg']=true, ['copper-bacteria']=true, ['iron-bacteria']=true}
  M.CHECK, M.LOW_CRAFTS, M.SPOIL_SOON, M.MACHINES = 600, 1, 3 * 3600, 256
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function store()
    local s = api.state()
    s.seeds = s.seeds or {next=1, states={}}
    return s.seeds
  end
  -- Which seed a recipe takes, and how many a craft: cached by recipe name.
  local takes = {}
  local function seed_of(rn)
    local v = takes[rn]
    if v == nil then
      v = false
      local r = prototypes.recipe[rn]
      for _, ing in ipairs(r and r.ingredients or {}) do
        if M.SEEDS[ing.name] then v = {seed=ing.name, amount=ing.amount or 1}; break end
      end
      takes[rn] = v
    end
    return v
  end
  local function recipe_name(e)
    local r = e.get_recipe()
    if not r and e.type == 'furnace' then r = e.previous_recipe end
    local n = r and r.name
    if n and type(n) ~= 'string' then n = n.name end
    return n
  end
  -- What an inventory holds of the seed, and the latest tick a stack of it spoils (nil: never read).
  local function add_inv(acc, inv, seed)
    if not inv then return end
    local n = try(function() return inv.get_item_count(seed) end) or 0
    if n <= 0 then return end
    acc.count = acc.count + n
    for i = 1, #inv do
      local st = inv[i]
      if st and st.valid_for_read and st.name == seed then
        local t = try(function() return st.spoil_tick end)
        if t and t > 0 then acc.last_spoil = math.max(acc.last_spoil or 0, t) else acc.forever = true end
      end
    end
  end
  -- One surface's seeds now: {seed = {count, machines = {e...}, amount, last_spoil, by = {name = true}}}.
  function M.read(force, surface)
    local crafters = api.crafters and api.crafters(force, surface)
    if not crafters then return nil end
    local out = {}
    for _, e in ipairs(crafters) do
      local rn = e.valid and recipe_name(e)
      local sd = rn and seed_of(rn)
      if sd then
        local row = out[sd.seed]
        if not row then row = {count=0, machines={}, amount=0, by={}, seen={}}; out[sd.seed] = row end
        if #row.machines < M.MACHINES then
          row.machines[#row.machines+1] = e
          row.amount = row.amount + sd.amount
          local who = try(function() return e.last_user and e.last_user.name end)
          if who then row.by[who] = true end
          add_inv(row, try(function() return e.get_inventory(defines.inventory.assembling_machine_input) end), sd.seed)
          add_inv(row, try(function() return e.get_inventory(defines.inventory.assembling_machine_output) end), sd.seed)
          local bb = e.bounding_box
          for _, ins in ipairs(try(function() return surface.find_entities_filtered{type='inserter', force=force,
              area={{bb.left_top.x - 2.5, bb.left_top.y - 2.5}, {bb.right_bottom.x + 2.5, bb.right_bottom.y + 2.5}}} end) or {}) do
            local h = try(function() return ins.held_stack end)
            if h and h.valid_for_read and h.name == sd.seed then row.count = row.count + h.count end
            if try(function() return ins.drop_target end) == e then
              local who2 = try(function() return ins.last_user and ins.last_user.name end)
              if who2 then row.by[who2] = true end
              local src = try(function() return ins.pickup_target end)
              if src and src.valid and src.unit_number and not row.seen[src.unit_number] and src ~= e then
                row.seen[src.unit_number] = true
                if src.type == 'container' or (src.type == 'logistic-container' and not try(function() return src.logistic_network end)) then
                  add_inv(row, try(function() return src.get_inventory(defines.inventory.chest) end), sd.seed)
                elseif src.type == 'transport-belt' or src.type == 'underground-belt' or src.type == 'splitter' then
                  row.count = row.count + (try(function() return src.get_item_count(sd.seed) end) or 0)
                end
              end
            end
          end
        end
      end
    end
    for seed, row in pairs(out) do
      row.seen = nil
      for _, ln in ipairs(try(function() return force.logistic_networks[surface.name] end) or {}) do
        local n = try(function() return ln.get_item_count(seed) end) or 0
        if n > 0 then row.count = row.count + n; row.in_network = (row.in_network or 0) + n end
      end
    end
    return out
  end
  local function where(list)
    local parts = {}
    for i, e in ipairs(list) do
      if i > 4 then parts[#parts+1] = string.format('+%d more', #list - 4); break end
      parts[#parts+1] = string.format('%s (%g,%g) %s', e.name, e.position.x, e.position.y, recipe_name(e) or '?')
    end
    return table.concat(parts, ', ')
  end
  -- The state and its line: 'zero', 'low' or nil.
  function M.state_of(seed, surface, row)
    local n = #row.machines
    if row.count <= 0 then
      return 'zero', string.format('seed alert: no %s left on %s in the %d machine%s that use it, their feeders\' hands and sources or the logistic networks: they cannot restart without it (%s)',
        seed, surface.name, n, n == 1 and '' or 's', where(row.machines))
    end
    local low = row.count < math.max(1, row.amount * M.LOW_CRAFTS)
    local soon = not row.forever and row.last_spoil and row.last_spoil - game.tick <= M.SPOIL_SOON
    if low or soon then
      return 'low', string.format('seed alert: %d %s left on %s for %d machine%s that use it (%s)%s%s; with none left they cannot restart',
        row.count, seed, surface.name, n, n == 1 and '' or 's', where(row.machines),
        low and string.format(', under one craft each (%d)', row.amount) or '',
        soon and string.format(', and all of it spoils within %ds', math.max(0, math.floor((row.last_spoil - game.tick) / 60))) or '')
    end
    return nil
  end
  local function surfaces()
    local list = {}
    for _, s in pairs(game.surfaces) do if try(function() return s.planet end) then list[#list+1] = s end end
    table.sort(list, function(a, b) return a.index < b.index end)
    return list
  end
  -- One surface a check, in turn; each seed's state change told once to its builders.
  function M.tick(tick)
    if tick % M.CHECK ~= 41 then return end
    local st = store()
    local list = surfaces()
    if #list == 0 then return end
    if st.next > #list then st.next = 1 end
    local surface = list[st.next]
    st.next = st.next + 1
    for _, force in pairs(game.forces) do
      if force.name == 'player' or (force.name ~= 'enemy' and force.name ~= 'neutral' and #(try(function() return force.players end) or {}) > 0) then
        local rows = M.read(force, surface) or {}
        for seed in pairs(M.SEEDS) do
          local key = force.name .. '|' .. surface.name .. '|' .. seed
          local row = rows[seed]
          local now, line
          if row then now, line = M.state_of(seed, surface, row) end
          if now ~= st.states[key] then
            st.states[key] = now
            if now and api.deliver then
              local names = {}
              for name in pairs(row.by) do names[#names+1] = name end
              table.sort(names)
              for _, name in ipairs(names) do
                local index = api.index_of and api.index_of(name)
                if index then pcall(api.deliver, index, {seq='seed', tick=game.tick, from='seed alert', text=line, wake=true}) end
              end
            end
          end
        end
      end
    end
  end
  return M
end
