-- Explicit feed cleanup: spoiled recipe ingredients/products and burnt results
-- move into the character inventory before top-ups, preserving stack metadata.
return function(api)
  local M={}
  local function try(fn) local ok,v=pcall(fn); if ok then return v end end
  function M.pending(e)
    local recipe=try(function() return e.get_recipe() end)
    local inputs,outputs,waste={},{},{spoilage=true}
    for _,pair in ipairs({{recipe and recipe.ingredients,inputs},{recipe and recipe.products,outputs}}) do
      for _,r in ipairs(pair[1] or {}) do
        if r.type~='fluid' then
          pair[2][r.name]=true
          local result=try(function() return prototypes.item[r.name].spoil_result end)
          if result then waste[type(result)=='string' and result or result.name]=true end
        end
      end
    end
    local rows,seen={},{}
    for _,kind in ipairs({'assembling_machine_input','furnace_source','assembling_machine_output','furnace_result','fuel','burnt_result'}) do
      local inv=try(function() return api.inventory(e,kind) end)
      if inv and not seen[inv] then
        seen[inv]=true
        local allowed=(kind=='assembling_machine_input' or kind=='furnace_source') and inputs
          or (kind=='assembling_machine_output' or kind=='furnace_result') and outputs or {}
        for _,st in ipairs(inv.get_contents()) do
          if kind=='burnt_result' or (waste[st.name] and not allowed[st.name]) then
            local q=st.quality; if type(q)~='string' then q=q and q.name or 'normal' end
            rows[#rows+1]={inventory=kind,item=st.name,quality=q or 'normal',count=st.count}
          end
        end
      end
    end
    return rows
  end
  function M.clear(p,e)
    local rows=M.pending(e)
    for _,row in ipairs(rows) do
      local out=api.take(p,e,row.inventory,row.item,row.quality,math.min(row.count,10000))
      row.taken=out.transferred; row.left=row.count-row.taken
      row.inventory_full=out.inventory_full and true or nil
    end
    return #rows>0 and rows or nil
  end
  return M
end
