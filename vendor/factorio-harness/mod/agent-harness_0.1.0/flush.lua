-- flush: the fluid GUI's flush button (LuaFluidBox.flush). It empties the
-- fluid segment (the connected pipeline) that one of the entity's fluidboxes
-- belongs to: every fluid, or only the one named. Reach as configure: within
-- reach, else remote view (a visible chunk, or our platform with platform=).
-- (d22 batch91 BA2, Sol #1882: Meridian-V's speed governor kept ~5k of fluid past its pumps, and Sol asked for the
-- GUI's flush) Read on 2.0.77 (a copy of world n's 11:19 autosave, Meridian-V): flush(index) with no fluid named
-- removes nothing and returns {} (so flush {position} alone flushed nothing); flush(index, name) empties that fluid
-- from the segment, and a segment on the other side of a pump keeps its own (oxidizer 7205 there before and after).
-- With no fluid given each fluid the segment holds is flushed by name, as the GUI's button empties the segment.
-- dry_run: what it would remove, nothing flushed. The game's count can be more than the segment read before: Meridian-V's
-- fuel segment read 12100 (its 7 thrusters' boxes, 1000 each, among it) and the flush returned 19100; the reply gives both.
return function(api)
  local M={handlers={}}
  M.schema={flush={position='{x,y}: a pipe, tank, pump or machine of the pipeline',fluid='optional fluid name: flush only this fluid',
    index='optional fluidbox index when the entity has several holding fluid (default: the one holding fluid, or holding fluid=)',
    name='optional entity name',unit_number='optional',platform='optional platform name: on that space platform (remote view)',
    dry_run='optional true: what it would remove (held, segment), nothing flushed',
    note='the fluid GUI\'s flush: removes the fluid from the whole connected segment (pipes, tanks and machine boxes joined to it; a pump bounds it: the segment past a pump keeps its fluid), nothing else; with no fluid named, every fluid the segment holds; within reach, else remote view',
    returns='flushed {fluid: amount} (the game\'s count of what it removed), held_before and held_after {fluid: amount} (the segment read before and after), fluid, amount, index, entity, segment {id, extent {left_top,right_bottom}, size "WxH tiles", capacity, entities}, line; dry_run: would_flush {fluid: amount}, amount, segment, line'}}
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
    assert(a.dry_run==nil or type(a.dry_run)=='boolean','dry_run must be true or false')
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
    -- (BA2) what the segment holds now, of the fluid named or of every fluid: the names flushed one by one
    local before,names,held_total={},{},0
    for name,amount in pairs(held(boxes,index)) do
      if amount>0 and (a.fluid==nil or name==a.fluid) then before[name]=round(amount); names[#names+1]=name; held_total=held_total+amount end
    end
    table.sort(names)
    local where=string.format('%s (%g,%g)',e.name,e.position.x,e.position.y)
    local seg_text=string.format('the segment of %s%s',where,segment.entities and string.format(' (%d entities with fluidboxes%s)',segment.entities,segment.size and ', '..segment.size or '') or '')
    local function list(t) local w={} for _,n in ipairs(names) do if t[n] then w[#w+1]=string.format('%s %g',n,t[n]) end end return #w>0 and table.concat(w,', ') or 'nothing' end
    if a.dry_run then
      return {dry_run=true,would_flush=before,amount=round(held_total),index=index,segment=segment,entity=where,
        line=string.format('would flush %s from %s; a pump bounds it: the segment past a pump keeps its fluid; nothing flushed (dry run)',list(before),seg_text)}
    end
    local flushed,total,fluid={},0,nil
    for _,name in ipairs(names) do
      for n,amount in pairs(boxes.flush(index,name) or {}) do
        if amount>0 then flushed[n]=round((flushed[n] or 0)+amount); total=total+amount end
      end
    end
    for _,n in ipairs(names) do if flushed[n] then fluid=fluid and fluid..' '..n or n end end
    local after={}
    for name,amount in pairs(held(boxes,index)) do if amount>0 and (a.fluid==nil or name==a.fluid) then after[name]=round(amount) end end
    return {flushed=flushed,held_before=before,held_after=after,fluid=fluid,amount=round(total),index=index,segment=segment,entity=where,
      line=string.format('flushed %s from %s (the game\'s count; the segment read %s before, %s after)',list(flushed),seg_text,list(before),list(after)),
      note=total==0 and 'nothing was flushed' or nil}
  end
  return M
end
