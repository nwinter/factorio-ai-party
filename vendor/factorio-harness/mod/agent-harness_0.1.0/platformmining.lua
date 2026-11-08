-- Factorio 2.0.77 discards some item inventories and transport-line contents during native platform mining
-- before on_space_platform_mined_entity. Move actual stacks out in pre_mined,
-- then join the engine's dynamic mining buffer for hub delivery.
-- No polling or inventory reconstruction; quality, spoilage and stack data survive.
return function(api)
  local M = {}
  local TYPES={['transport-belt']=true,['underground-belt']=true,splitter=true}
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
  local function quality(stack)
    local q=stack.quality
    return type(q)=='string' and q or q and q.name or 'normal'
  end
  -- Read-only batch preview. A script inventory models shared hub capacity with
  -- actual stack metadata, without removing or inserting any real items.
  function M.preflight(platform,entities)
    local out={safe=true,entities={},returns={},lines={},short={}}
    local function refuse(why) out.safe=false; out.reason=out.reason or why end
    if #entities>128 then refuse('platform item preflight limit is 128 entities'); return out end
    local wants,by,seen,content_by,short_by,slots={},{},{},{},{},0
    local function want(stack,row,kind,covered)
      if not stack.valid_for_read then return end
      local q=quality(stack); local key=kind..'/'..stack.name..'@'..q
      local items=content_by[row]
      if not items[key] then
        items[key]={name=stack.name,quality=q,count=0,inventory=kind}; row.contents[#row.contents+1]=items[key]
      end
      items[key].count=items[key].count+stack.count
      wants[#wants+1]=stack
      if not covered then refuse(row.entity..' has items in an uncovered '..kind) end
    end
    for _,e in ipairs(entities) do
      local row={entity=e.name,position={x=e.position.x,y=e.position.y},contents={}}
      content_by[row]={}
      out.entities[#out.entities+1]=row
      local ok,err=pcall(function()
        for i=1,e.get_max_inventory_index() do
          local inv=e.get_inventory(i)
          if inv then
            slots=slots+#inv; assert(slots<=8192,'platform item preflight limit is 8192 inventory slots')
            for j=1,#inv do want(inv[j],row,'inventory '..i,true) end
          end
        end
        if e.type=='inserter' then want(e.held_stack,row,'inserter hand',true) end
        -- A new transport-connectable type with carried items fails closed until
        -- the preservation handler covers it. Non-connectable entities throw here.
        local connected,max=pcall(e.get_max_transport_line_index)
        assert(connected or not TYPES[e.type],'cannot inspect transport lines')
        if connected then
          for i=1,max do
            local line=e.get_transport_line(i)
            local duplicate=false
            if e.type=='underground-belt' and i>2 then
              local partner=e.neighbours
              if partner and partner.valid and seen[partner.unit_number] then
                duplicate=line.line_equals(partner.get_transport_line(i))
              end
            end
            if line and line.valid and not duplicate then
              slots=slots+#line; assert(slots<=8192,'platform item preflight limit is 8192 inventory slots')
              for j=1,#line do want(line[j],row,'transport line '..i,TYPES[e.type]) end
            end
          end
        end
        if e.unit_number then seen[e.unit_number]=true end
        if e.type=='cargo-bay' then refuse('cargo-bay removal changes hub capacity; item returns cannot be guaranteed for this batch') end
        for _,pr in pairs(e.prototype.mineable_properties.products or {}) do
          if pr.type==nil or pr.type=='item' then
            local n=pr.amount or pr.amount_max
            assert(n,'unknown mining result amount')
            if n>0 then wants[#wants+1]={name=pr.name,quality=quality(e),count=n} end
          end
        end
      end)
      if not ok then row.contents_unread=true; refuse('cannot inspect all item contents of '..e.name..': '..tostring(err)) end
      if #row.contents>0 and not e.unit_number then refuse(e.name..' has no mining identity for preserving its items') end
      local text={}
      for _,v in ipairs(row.contents) do text[#text+1]=v.count..' '..v.quality..' '..v.name..' ('..v.inventory..')' end
      out.lines[#out.lines+1]=string.format('%s (%g,%g): %s',e.name,e.position.x,e.position.y,
        (#text>0 and table.concat(text,', ') or row.contents_unread and 'contents unread' or 'no held items')
          ..(row.contents_unread and #text>0 and '; further contents unread' or ''))
    end
    if #entities>0 and not M.ready() then refuse('updated platform mining event handlers missing; server restart required') end
    for _,v in ipairs(wants) do
      local q=quality(v); local key=v.name..'@'..q
      if not by[key] then by[key]={name=v.name,quality=q,count=0}; out.returns[#out.returns+1]=by[key] end
      by[key].count=by[key].count+v.count
    end
    local sim
    local ok,err=pcall(function()
      local hub=assert(platform.hub and platform.hub.valid and platform.hub.get_inventory(defines.inventory.hub_main),'platform hub inventory unavailable')
      local size=#hub
      if hub.supports_bar() then size=math.min(size,hub.get_bar()-1) end
      out.hub_slots=size
      if size>0 then
        sim=game.create_inventory(size)
        for i=1,size do
          if hub.supports_filters() and hub.get_filter(i) then
            refuse('filtered hub slots are not covered by the capacity check'); return
          end
          if hub[i].valid_for_read then assert(sim[i].set_stack(hub[i]),'cannot copy hub stack metadata') end
        end
      end
      for _,stack in ipairs(wants) do
        local moved=sim and sim.insert(stack) or 0
        if moved<stack.count then
          local q=quality(stack); local key=stack.name..'@'..q
          if not short_by[key] then
            short_by[key]={name=stack.name,quality=q,count=0}; out.short[#out.short+1]=short_by[key]
          end
          short_by[key].count=short_by[key].count+stack.count-moved
          refuse('hub cannot hold all batch returns, including mined entity items')
        end
      end
    end)
    if sim then sim.destroy() end
    if not ok then refuse('cannot guarantee hub capacity: '..tostring(err)) end
    return out
  end
  function M.on_event(event)
    local e=event.entity
    if not (e and e.valid and event.platform) then return end
    local st=state()
    if event.name==defines.events.on_space_platform_pre_mined then
      local lines,stacks,n={},{},0
      local function slots(stack)
        return math.ceil(stack.count/stack.prototype.stack_size)
      end
      if TYPES[e.type] then
        for i=1,e.get_max_transport_line_index() do
          local line=e.get_transport_line(i)
          if line and line.valid then
            lines[#lines+1]=line
            for j=1,#line do n=n+slots(line[j]) end
          end
        end
      end
      -- Inventory indexes include fuel, burnt result, input, output, modules,
      -- ammo, chests and collector storage. Empty slots are never reconstructed.
      -- Move even inventories the engine normally returns: emptying them here
      -- leaves exactly one owner, so native mining cannot duplicate the contents.
      for i=1,e.get_max_inventory_index() do
        local inventory=e.get_inventory(i)
        if inventory then
          for j=1,#inventory do
            if inventory[j].valid_for_read then stacks[#stacks+1]=inventory[j] end
          end
        end
      end
      if e.type=='inserter' and e.held_stack.valid_for_read then stacks[#stacks+1]=e.held_stack end
      for _,stack in ipairs(stacks) do n=n+slots(stack) end
      if n==0 then return end
      local inv=game.create_inventory(n)
      st.pending[e.unit_number]=inv
      local slot=1
      -- Machine slots and stacked belts can exceed the item's normal stack
      -- limit (e.g. two asteroid chunks in one crusher slot). transfer_stack
      -- then moves only part and returns false: retain each actual split stack.
      local function take(stack)
        local before=stack.count
        inv[slot].transfer_stack(stack)
        local moved=inv[slot].valid_for_read and inv[slot].count or 0
        assert(moved>0 and moved<=before,'platform mining: stack transfer failed')
        slot=slot+1
        return moved
      end
      for _,line in ipairs(lines) do
        -- Line stack references are valid only until the line changes: read
        -- each anew, from the end so the remaining indexes do not shift.
        for i=#line,1,-1 do
          local left=line[i].count
          while left>0 do left=left-take(line[i]) end
        end
      end
      for _,stack in ipairs(stacks) do
        while stack.valid_for_read do take(stack) end
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
