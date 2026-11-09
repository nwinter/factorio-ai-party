-- Current maker input and the nearby arms/loaders pointing at it, beside nominal recipe capacity.
return function(api)
  local M = {}
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  function M.read(e, recipe)
    local out = {status=api.status_name(e), ingredients={}, missing={}}
    local inv = try(function() return e.get_inventory(defines.inventory.crafter_input) end)
      or try(function() return e.get_inventory(e.type == 'furnace' and defines.inventory.furnace_source or defines.inventory.assembling_machine_input) end)
    local quality = try(function() local _, q=e.get_recipe(); return q and q.name end) or 'normal'
    for _, ing in ipairs(recipe.ingredients or {}) do
      local n
      if ing.type == 'fluid' then n = try(function() return e.get_fluid_count(ing.name) end)
      elseif inv then n = try(function() return inv.get_item_count{name=ing.name,quality=quality} end) end
      out.ingredients[#out.ingredients+1] = {name=ing.name, type=ing.type or 'item', quality=ing.type ~= 'fluid' and quality or nil, held=n}
      if n == 0 then out.missing[#out.missing+1] = ing.name end
    end
    local b = try(function() return e.bounding_box end)
    if b then
      local function on(q) return q and q.x>=b.left_top.x and q.x<=b.right_bottom.x and q.y>=b.left_top.y and q.y<=b.right_bottom.y end
      local near = e.surface.find_entities_filtered{area={{b.left_top.x-3,b.left_top.y-3},{b.right_bottom.x+3,b.right_bottom.y+3}},type={'inserter','loader','loader-1x1'},force=e.force,limit=257}
      out.input_inserters, out.output_inserters, out.input_loaders, out.output_loaders = 0,0,0,0
      out.arms_capped = #near>256 or nil
      for k, arm in ipairs(near) do
        if k>256 then break end
        if arm.type == 'inserter' then
          if arm.drop_target == e or not arm.drop_target and on(arm.drop_position) then out.input_inserters=out.input_inserters+1 end
          if arm.pickup_target == e or not arm.pickup_target and on(arm.pickup_position) then out.output_inserters=out.output_inserters+1 end
        elseif arm.loader_container == e then
          if arm.loader_type == 'input' then out.input_loaders=out.input_loaders+1 else out.output_loaders=out.output_loaders+1 end
        end
      end
    end
    local parts = {out.status or 'status unknown'}
    if out.input_inserters then
      parts[#parts+1] = out.input_inserters+out.input_loaders == 0 and 'no input inserter or loader' or string.format('input inserters %d, loaders %d',out.input_inserters,out.input_loaders)
      parts[#parts+1] = out.output_inserters+out.output_loaders == 0 and 'no output inserter or loader' or string.format('output inserters %d, loaders %d',out.output_inserters,out.output_loaders)
    end
    if #out.missing>0 then parts[#parts+1]='input holds none of: '..table.concat(out.missing,', ') end
    if out.arms_capped then parts[#parts+1]='nearby arms read capped at 256' end
    out.line = table.concat(parts,'; ')
    return out
  end
  return M
end
