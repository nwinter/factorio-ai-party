-- One refuel action: use carried fuel, replenish from observed chests/belts,
-- then continue the same burner tour. All movement uses stock's enemy checks.
return function(api)
  local M={}
  local CHEST={container=true,['logistic-container']=true}
  local SOURCES={'container','logistic-container','transport-belt','underground-belt','splitter'}
  local function seen(p,e)
    return api.distance(p.position,e.position)<=32 or p.force.is_chunk_visible(p.surface,{x=math.floor(e.position.x/32),y=math.floor(e.position.y/32)})
  end
  local function key(e) return e.unit_number or (e.name..'|'..e.position.x..','..e.position.y) end
  local function stock(e,item,q)
    if CHEST[e.type] then local inv=e.get_inventory(defines.inventory.chest);return inv and inv.get_item_count{name=item,quality=q} or 0 end
    return api.belt_count(e,item,q)
  end
  local function need(action)
    local n=0
    for i=action.index,#action.targets do
      n=n+(action.targets[i].needed or 0)
    end
    return n
  end
  function M.start(p,a,fuel,count)
    assert(a.positions==nil,'from/area refuel takes area or radius, not positions')
    assert(a.walk~=false,'from/area refuel walks; walk=false is not supported')
    assert(a.area~=nil or a.radius~=nil,'from requires area or radius')
    assert(a.from==nil or a.from=='nearest' or type(a.from)=='table','from must be nearest or a chest position')
    local base={limit=1025}
    if a.area then
      assert(a.radius==nil and a.position==nil,'give area, or position and radius')
      local lt,rb=api.position(a.area.left_top or a.area[1]),api.position(a.area.right_bottom or a.area[2])
      assert(rb.x>lt.x and rb.y>lt.y and rb.x-lt.x<=256 and rb.y-lt.y<=256,'area must be nonempty and at most 256x256')
      base.area={lt,rb}
    else base.position=a.position and api.position(a.position) or p.position;base.radius=api.integer(a.radius,32,1,256,'radius') end
    local found,note=api.find_kinds(p,base,a.types)
    assert(#found<=1024,'more than 1024 entities in the refuel area; use a smaller area or types')
    local targets,hidden={},0
    for _,e in ipairs(found) do
      if e.valid and e.force==p.force then
        if not seen(p,e) then hidden=hidden+1
        else
          local inv=api.fuel_inventory(e)
          if inv and api.accepts(e,fuel) and inv.get_item_count{name=fuel,quality=a.quality or 'normal'}<count then targets[#targets+1]=e end
        end
      end
    end
    assert(#targets<=128,'more than 128 burners need fuel; use a smaller area')
    local from
    if type(a.from)=='table' then
      from=api.entity(p,{position=api.position(a.from)})
      assert(CHEST[from.type] and from.force==p.force,'from must be our chest')
    end
    local ticks=api.integer(a.ticks,36000,1,36000,'ticks')
    local action,out=api.start_tour(p,'refuel',targets,ticks,{item=fuel,quality=a.quality or 'normal',count=count,
      avoid_enemies=a.avoid_enemies,unsafe_goal=a.unsafe_goal})
    for _,t in ipairs(action.targets) do
      t.needed=math.max(0,count-api.fuel_inventory(t.entity).get_item_count{name=fuel,quality=action.quality})
    end
    action.fuel_round={from=from,nearest=a.from=='nearest',sources={},tried={},taken=0,attempts=0}
    out.from=a.from;out.types_note=note;out.entities_not_in_sight=hidden>0 and hidden or nil
    out.until_tick=action.until_tick;out.needed=need(action);out.held=api.held(p,fuel,action.quality)
    api.start(p,action)
    return out
  end
  function M.feed_visit(p,action,e)
    local out=api.give(p,e,action.item,action.quality,action.count)
    local have=api.fuel_inventory(e).get_item_count{name=action.item,quality=action.quality}
    local t=action.targets[action.index];t.needed=math.max(0,action.count-have)
    action.rows=action.rows or {}
    local row=t.row or {name=e.name,position=t.position,given=0}
    if not t.row then t.row=row;action.rows[#action.rows+1]=row end;row.given=row.given+out.transferred;row.held=have;row.missing=t.needed
    local empty=t.needed>0 and api.held(p,action.item,action.quality)==0
    if t.needed>0 and not empty then action.incomplete=true;row.why='fuel inventory did not accept the remaining count' end
    return {transferred=out.transferred,wait=empty or nil,stop=empty and 'out_of_items' or nil}
  end
  function M.source_visit(p,child,e)
    if CHEST[e.type] then return api.take(p,e,child.item,child.quality,child.want) end
    if game.tick<(child.next_pick or 0) then return {transferred=0,wait=true} end
    child.next_pick=game.tick+6
    local n,why=api.belt_take(p,e,child,math.min(6,child.want-child.got))
    return {transferred=n,inventory_full=why=='inventory_full',wait=not why and n>0 and child.got+n<child.want}
  end
  local function source(p,action)
    local r=action.fuel_round
    local list=r.from and {r.from} or r.nearest and p.surface.find_entities_filtered{position=p.position,radius=64,force=p.force,type=SOURCES,limit=257} or {}
    r.source_read_capped=#list==257 or r.source_read_capped
    local places={}
    for i=1,math.min(256,#list) do
      local e=list[i]
      if e.valid and not r.tried[key(e)] and seen(p,e) and stock(e,action.item,action.quality)>0 then places[#places+1]={entity=e,position=e.position} end
    end
    table.sort(places,function(x,y) return api.distance(p.position,x.position)<api.distance(p.position,y.position) end)
    local kept,left=api.screen(p,places,action.avoid_mode,action.unsafe_goal)
    for _,line in ipairs(left and left.lines or {}) do r.sources[#r.sources+1]={skipped=line} end
    local t=kept[1]
    if not t then return nil end
    r.tried[key(t.entity)]=true;r.attempts=r.attempts+1
    if not CHEST[t.entity.type] then t.pickup_reach=(p.character and p.character.prototype.item_pickup_distance or 1)+0.5 end
    local child={kind='gather',op='refuel_source',item=action.item,items={action.item},quality=action.quality,
      count=math.min(10000,need(action)),got=0,visited=0,targets={t},index=1,until_tick=action.until_tick,
      avoid_mode=action.avoid_mode,unsafe_goal=action.unsafe_goal}
    child.want=child.count
    r.source=child
    return child
  end
  function M.tick(p,action)
    local r=action.fuel_round
    if r.source then
      local child=r.source
      local result=api.tick(p,child)
      action.nav=child.nav
      if not result then return nil end
      local e=child.targets[1].entity
      r.sources[#r.sources+1]={name=e.valid and e.name or 'removed source',position=child.targets[1].position,taken=child.got,
        outcome=result,why=child.first_error or child.first_unreached}
      r.taken=r.taken+child.got;r.source=nil;action.nav=nil;api.stop(p)
      if child.got>0 and e.valid and stock(e,action.item,action.quality)>0 then r.tried[key(e)]=nil end
      if result=='inventory_full' and api.held(p,action.item,action.quality)==0 then return 'inventory_full' end
      return nil
    end
    if action.index>#action.targets then
      if (action.errors or 0)>0 then return 'failed' end
      if (action.unreached or 0)>0 then return 'unreached' end
      if action.incomplete then action.why='one or more fuel inventories did not accept the remaining count';return 'out_of_items' end
      return api.tick(p,action)
    end
    if api.held(p,action.item,action.quality)==0 and need(action)>0 then
      if r.attempts>=64 or not source(p,action) then
        action.why=r.attempts>=64 and 'fuel round reached 64 source attempts' or ('no eligible '..action.item..' found in the selected source'..(r.nearest and 's within 64 tiles' or '')..(r.source_read_capped and ' (source read capped at 256)' or ''))
        return 'out_of_items'
      end
      return nil
    end
    local result=api.tick(p,action)
    if result=='out_of_items' and action.index<=#action.targets then return nil end
    if result and ((action.errors or 0)>0 or (action.unreached or 0)>0 or action.incomplete) then
      if (action.errors or 0)>0 then return 'failed' end
      if (action.unreached or 0)>0 then return 'unreached' end
      action.why='one or more fuel inventories did not accept the remaining count';return 'out_of_items'
    end
    return result
  end
  return M
end
