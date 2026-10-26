-- An inserter built to drop onto a belt (E3, Opus 19:50: copper ore put on a plate line jammed 3 branches for 20 min):
-- what it will put there (read from its pickup side: a drill's ore, a machine's recipe products, a chest's contents, a
-- belt's lanes) against what that belt carries now and what the inserters taking from it downstream take (the
-- recipes, labs and filters they feed), walking the belt up to MAX tiles (one output followed at a splitter). A line
-- when some item it puts is neither on the belt nor taken downstream; nil otherwise. At most BUDGET reads a tick.
return function(api)
  local M = {}
  local MAX, BUDGET = 120, 4
  local BELT = {['transport-belt']=true, ['underground-belt']=true, splitter=true}
  local CRAFTER = {['assembling-machine']=true, furnace=true}
  local CHEST = {container=true, ['logistic-container']=true}
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function at(q) return string.format('(%g,%g)', q.x, q.y) end
  local function names(set)
    local list = {}
    for n in pairs(set) do list[#list+1] = n end
    table.sort(list)
    return list
  end
  local function lane_items(b, into)
    for k = 1, math.min(2, try(function() return b.get_max_transport_line_index() end) or 0) do
      for _, c in ipairs(try(function() return b.get_transport_line(k).get_contents() end) or {}) do into[c.name] = true end
    end
  end
  local function recipe_of(m)
    local r = try(function() return m.get_recipe() end)
    if not r and m.type == 'furnace' then r = try(function() return m.previous_recipe end) end
    -- (d26 batch248 R3) a furnace's {name=LuaRecipePrototype (userdata), quality}: the prototype
    if type(r) == 'table' and r.name and not r.ingredients then
      local n = r.name
      if type(n) ~= 'string' then n = try(function() return n.name end) end
      r = n and try(function() return prototypes.recipe[n] end) or r
    end
    return r
  end
  -- What an inserter standing at e (built or planned there) puts down: {item=true}, and where it reads that.
  function M.puts(e)
    local pick = api.standing(e.surface, e.pickup_position)
    if not pick then return nil end
    local out = {}
    if pick.type == 'mining-drill' then
      local res = try(function() return pick.mining_target end)
      for _, pr in ipairs(res and try(function() return res.prototype.mineable_properties.products end) or {}) do
        if pr.type ~= 'fluid' then out[pr.name] = true end
      end
    elseif CRAFTER[pick.type] then
      local r = recipe_of(pick)
      for _, pr in ipairs(r and r.products or {}) do if pr.type ~= 'fluid' then out[pr.name] = true end end
    elseif CHEST[pick.type] then
      local inv = try(function() return pick.get_inventory(defines.inventory.chest) end)
      for _, c in ipairs(inv and try(function() return inv.get_contents() end) or {}) do out[c.name] = true end
    elseif BELT[pick.type] then lane_items(pick, out) end
    if not next(out) then return nil end
    return out, pick
  end
  -- The inserters taking from belt b and on downstream: what they take ('*' a chest or anything), how many, and what
  -- the walked belts carry now.
  function M.downstream(b)
    local wants, carried, takers, any, tiles = {}, {}, 0, false, 0
    local seen, e = {}, b
    while e and e.valid and tiles < MAX and not seen[e.unit_number] do
      seen[e.unit_number] = true
      tiles = tiles + 1
      lane_items(e, carried)
      local p = e.position
      for _, i in ipairs(try(function() return e.surface.find_entities_filtered{area={{p.x - 3, p.y - 3}, {p.x + 3, p.y + 3}}, type='inserter', force=e.force} end) or {}) do
        if i.valid and try(function() return i.pickup_target end) == e then
          takers = takers + 1
          local mode = try(function() return i.inserter_filter_mode end)
          local filtered = try(function() return i.use_filters end)
          if filtered and mode ~= 'blacklist' then
            for k = 1, try(function() return i.filter_slot_count end) or 0 do
              local f = try(function() return i.get_filter(k) end)
              local n = type(f) == 'table' and (type(f.name) == 'table' and f.name.name or f.name) or f
              if type(n) == 'string' then wants[n] = true end
            end
          else
            local t = try(function() return i.drop_target end)
            if t and CRAFTER[t.type] then
              local r = recipe_of(t)
              for _, ing in ipairs(r and r.ingredients or {}) do if ing.type ~= 'fluid' then wants[ing.name] = true end end
            elseif t and t.type == 'lab' then
              for _, n in ipairs(try(function() return t.prototype.lab_inputs end) or {}) do wants[n] = true end
            else any = true end
          end
        end
      end
      local bn = try(function() return e.belt_neighbours end)
      local nxt = bn and bn.outputs and bn.outputs[1]
      if not nxt and e.type == 'underground-belt' and try(function() return e.belt_to_ground_type end) == 'input' then nxt = try(function() return e.neighbours end) end
      e = nxt
    end
    return {wants=wants, carried=carried, takers=takers, any=any, tiles=tiles}
  end
  local used = {tick=-1, n=0}
  function M.check(e)
    if not (e and e.valid and e.type == 'inserter') then return nil end
    if used.tick ~= game.tick then used.tick, used.n = game.tick, 0 end
    if used.n >= BUDGET then return nil end
    local belt = api.standing(e.surface, e.drop_position)
    if not (belt and BELT[belt.type]) then return nil end
    used.n = used.n + 1
    local puts, from = M.puts(e)
    if not puts then return nil end
    local d = M.downstream(belt)
    if d.any then return nil end
    local odd = {}
    for n in pairs(puts) do if not d.wants[n] and not d.carried[n] then odd[#odd+1] = n end end
    if #odd == 0 then return nil end
    table.sort(odd)
    local wants, carried = names(d.wants), names(d.carried)
    return string.format('%s %s drops %s (from %s %s) onto %s %s; over the next %d belt tiles %s, and the belt carries %s now',
      e.name, at(e.position), table.concat(odd, ', '), from.name, at(from.position), belt.name, at(belt.position), d.tiles,
      d.takers == 0 and 'no inserter takes from it' or string.format('%d inserter%s take from it for %s', d.takers, d.takers == 1 and '' or 's',
        #wants > 0 and table.concat(wants, ', ') or 'nothing they name'),
      #carried > 0 and table.concat(carried, ', ') or 'nothing')
  end
  return M
end
