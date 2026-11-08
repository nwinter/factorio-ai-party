-- Factorio 2.0.77 discards transport-line contents during native platform mining
-- before on_space_platform_mined_entity. Move actual stacks out in pre_mined,
-- then hand them to the engine's dynamic mining buffer for normal hub delivery.
-- No polling or inventory reconstruction; quality, spoilage and stack data survive.
return function(api)
  local M = {}
  local TYPES={['transport-belt']=true,['underground-belt']=true,splitter=true}
  M.types=TYPES
  function M.ready()
    return script.get_event_handler(defines.events.on_space_platform_pre_mined)~=nil
      and script.get_event_handler(defines.events.on_space_platform_mined_entity)~=nil
  end
  M.events={}
  for _,name in ipairs{'on_space_platform_pre_mined','on_space_platform_mined_entity'} do
    if defines.events[name] then M.events[defines.events[name]]=true end
  end
  local function state()
    local s=api.state()
    s.platform_mining=s.platform_mining or {pending={},returns={}}
    return s.platform_mining
  end
  function M.on_event(event)
    local e=event.entity
    if not (e and e.valid and TYPES[e.type]) then return end
    local st=state()
    if event.name==defines.events.on_space_platform_pre_mined then
      local lines,n={},0
      for i=1,e.get_max_transport_line_index() do
        local line=e.get_transport_line(i)
        if line and line.valid then lines[#lines+1]=line; n=n+#line end
      end
      if n==0 then return end
      local inv=game.create_inventory(n)
      st.pending[e.unit_number]=inv
      local slot=1
      for _,line in ipairs(lines) do
        -- Taking from the end avoids shifting the remaining stack indexes.
        for i=#line,1,-1 do
          assert(inv[slot].transfer_stack(line[i]),'platform mining: stack transfer failed')
          slot=slot+1
        end
      end
    else
      local inv=st.pending[e.unit_number]
      if inv then
        for i=1,#inv do
          local stack=inv[i]
          if stack.valid_for_read then
            local count=stack.count
            local moved=event.buffer.insert(stack)
            if moved==count then stack.clear() else
              stack.count=count-moved
              error('platform mining: native mining buffer refused contents')
            end
          end
        end
        inv.destroy(); st.pending[e.unit_number]=nil
      end
      local items=event.buffer.get_contents()
      st.returns[#st.returns+1]={tick=event.tick,platform=event.platform.name,surface=e.surface.name,
        entity=e.name,position={x=e.position.x,y=e.position.y},items=items}
      while #st.returns>32 do table.remove(st.returns,1) end
    end
  end
  function M.lines(item,surface)
    local out={}
    local s=api.state().platform_mining
    for i=#(s and s.returns or {}),1,-1 do
      local r=s.returns[i]
      local match=r.entity==item
      local parts={}
      for _,v in ipairs(r.items) do
        if v.name==item then match=true end
        parts[#parts+1]=v.count..' '..v.quality..' '..v.name
      end
      if match and (not surface or surface==r.surface) then
        out[#out+1]=string.format('%s (%g,%g) on %s, tick %d: native mining return (hub; overflow on platform for pickup): %s',
          r.entity,r.position.x,r.position.y,r.platform,r.tick,table.concat(parts,', '))
        if #out==6 then break end
      end
    end
    return out
  end
  return M
end
