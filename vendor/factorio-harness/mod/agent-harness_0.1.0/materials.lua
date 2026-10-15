-- A material snapshot before a hand build or construct starts. Counts are for
-- requested placements, before any items recovered by mining or replacements.
return function(api)
  local M={}
  local function add(by,item,quality,count,maximum)
    if not item then return end
    local key=item..'@'..quality
    local row=by[key] or {item=item,quality=quality,need=0}
    by[key]=row;row.need=row.need+count;row.maximum=row.maximum or maximum
  end
  function M.read(p,by)
    local rows={}
    for _,r in pairs(by) do
      r.held=p.get_main_inventory().get_item_count{name=r.item,quality=r.quality}
      r.queued=r.quality=='normal' and api.queued(p,r.item) or 0
      r.missing=math.max(0,r.need-r.held)
      r.missing_after_queue=math.max(0,r.missing-r.queued)
      r.hand_craftable=0
      local recipe=r.quality=='normal' and p.force.recipes and api.recipe(p,r.item)
      if recipe then
        local amount=0
        for _,pr in ipairs(recipe.products or {}) do if pr.name==r.item and (pr.probability or 1)==1 then amount=pr.amount or pr.amount_min or 0 end end
        r.hand_craftable=p.get_craftable_count(recipe.name or r.item)*amount
      end
      rows[#rows+1]=r
    end
    table.sort(rows,function(a,b) if a.item~=b.item then return a.item<b.item end return a.quality<b.quality end)
    return rows
  end
  function M.build(p,a)
    local by={}
    for _,b in ipairs(a.builds or {a}) do
      if type(b)=='table' then
        local item=b.item or a.item
        local proto=item and prototypes and prototypes.item[item]
        local n,maximum=1,nil
        if proto then
          local place=proto.place_result
          if b.entity or a.entity then place=prototypes.entity[b.entity or a.entity] or place end
          for _,it in ipairs(place and place.items_to_place_this or {}) do if it.name==item then n=it.count or 1 end end
          if proto.place_as_tile_result then
            local size=b.size or a.size or 1
            if type(size)=='number' and size>=1 and size<=4 then n=size*size;maximum=size>1 or nil end
          end
        end
        add(by,item,b.quality or a.quality or 'normal',n,maximum)
      end
    end
    return M.read(p,by)
  end
  function M.ghosts(p,box)
    local by,list={},{}
    for _,e in pairs(p.surface.find_entities_filtered{area=box,type={'entity-ghost','tile-ghost'},force=p.force,limit=1025}) do
      if e.valid and api.known(p,e) then
        list[#list+1]=e
        assert(#list<=1024,'more than 1024 ghosts; construct a smaller area')
        local choices=e.ghost_prototype.items_to_place_this or {}
        local q=e.quality and e.quality.name or 'normal'
        local chosen=choices[1]
        for _,it in ipairs(choices) do
          if p.get_main_inventory().get_item_count{name=it.name,quality=q}>=(it.count or 1) then chosen=it;break end
        end
        add(by,chosen and chosen.name or e.ghost_name,q,chosen and chosen.count or 1)
      end
    end
    return M.read(p,by),list
  end
  function M.line(rows)
    local out={}
    for _,r in ipairs(rows) do
      out[#out+1]=string.format('%s%s need %d%s, held %d, missing %d, queued %d, hand-craftable %d',r.item,
        r.quality~='normal' and '@'..r.quality or '',r.need,r.maximum and ' at most' or '',r.held,r.missing,r.queued,r.hand_craftable)
    end
    return table.concat(out,'; ')
  end
  return M
end
