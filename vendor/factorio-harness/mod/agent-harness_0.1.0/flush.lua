-- flush: the fluid GUI's flush button (LuaFluidBox.flush). It empties the
-- fluid segment (the connected pipeline) that one of the entity's fluidboxes
-- belongs to: every fluid, or only the one named. Reach as configure: within
-- reach, else remote view (a visible chunk, or our platform with platform=).
return function(api)
  local M={handlers={}}
  M.schema={flush={position='{x,y}: a pipe, tank, pump or machine of the pipeline',fluid='optional fluid name: flush only this fluid',
    index='optional fluidbox index when the entity has several holding fluid (default: the one holding fluid, or holding fluid=)',
    name='optional entity name',unit_number='optional',platform='optional platform name: on that space platform (remote view)',
    note='the fluid GUI\'s flush: removes the fluid from the whole connected segment (pipes, tanks, pumps and machine boxes joined to it), nothing else; within reach, else remote view',
    returns='flushed {fluid: amount}, fluid, amount, index, entity, segment {id, extent {left_top,right_bottom}, size "WxH tiles", capacity, entities}'}}
  local function try(fn) local ok,v=pcall(fn); if ok then return v end end
  local function round(v) return math.floor(v*10+0.5)/10 end
  -- What a fluidbox's segment holds (its own content when it has no segment).
  local function held(boxes,i)
    local c=try(function() return boxes.get_fluid_segment_contents(i) end)
    if c then return c end
    local f=boxes[i]
    return f and {[f.name]=f.amount} or {}
  end
  function M.handlers.flush(p,a)
    local e=api.target(p,a)
    api.friendly(p,e)
    local boxes=e.fluidbox
    local n=boxes and #boxes or 0
    assert(n>0,e.name..' has no fluidbox')
    if a.fluid~=nil then assert(type(a.fluid)=='string' and prototypes.fluid[a.fluid],'unknown fluid: '..tostring(a.fluid)) end
    local index
    if a.index~=nil then
      index=api.integer(a.index,1,1,n,'index')
    else
      -- The boxes holding fluid (or the named fluid), one per segment.
      local found,seen={},{}
      for i=1,n do
        local id=try(function() return boxes.get_fluid_segment_id(i) end) or ('box'..i)
        for name,amount in pairs(held(boxes,i)) do
          if amount>0 and (a.fluid==nil or name==a.fluid) and not seen[id] then
            seen[id]=true; found[#found+1]={index=i,fluid=name,amount=amount}
          end
        end
      end
      assert(#found>0,string.format('nothing to flush: %s at (%g,%g) holds %s',e.name,e.position.x,e.position.y,a.fluid and 'no '..a.fluid or 'no fluid'))
      if #found>1 then
        local parts={}
        for i,f in ipairs(found) do parts[i]=string.format('index %d: %s %g',f.index,f.fluid,round(f.amount)) end
        error(string.format('%s at (%g,%g) has %d fluid segments with fluid (%s): give index (or fluid)',e.name,e.position.x,e.position.y,#found,table.concat(parts,', ')),0)
      end
      index=found[1].index
    end
    -- The segment before the flush: its extent, capacity and members.
    local segment={id=try(function() return boxes.get_fluid_segment_id(index) end)}
    local box=try(function() return boxes.get_fluid_segment_extent_bounding_box(index) end)
    if box then
      segment.extent=box
      segment.size=string.format('%gx%g tiles',math.ceil(box.right_bottom.x-box.left_top.x),math.ceil(box.right_bottom.y-box.left_top.y))
    end
    segment.capacity=try(function() return round(boxes.get_capacity(index)) end)
    if box and segment.id then
      -- Count the entities with a fluidbox in this segment (capped).
      local count=0
      for _,o in ipairs(try(function() return e.surface.find_entities_filtered{area=box,force=e.force,limit=2000} end) or {}) do
        local ob=try(function() return o.fluidbox end)
        for i=1,ob and #ob or 0 do
          if try(function() return ob.get_fluid_segment_id(i) end)==segment.id then count=count+1; break end
        end
      end
      segment.entities=count
    end
    local removed=boxes.flush(index,a.fluid) or {}
    local flushed,total,fluid={},0,nil
    for name,amount in pairs(removed) do
      if amount>0 then flushed[name]=round(amount); total=total+amount; fluid=fluid and fluid..' '..name or name end
    end
    return {flushed=flushed,fluid=fluid,amount=round(total),index=index,segment=segment,
      entity=string.format('%s (%g,%g)',e.name,e.position.x,e.position.y),note=total==0 and 'nothing was flushed' or nil}
  end
  return M
end
