-- Where our factory already holds an item: machine outputs and storage
-- chests. Hand-crafting what a nearby assembler has already made wastes the
-- character's time, so craft and construct point here, and `collect` with a
-- radius walks the stock back.
return function(api)
  local M={}
  local TYPES={'assembling-machine','furnace','agricultural-tower','container','logistic-container','cargo-landing-pad'}
  -- Gathering leaves plain chests alone unless asked: they are usually feed
  -- chests the player stocked for machines, not stock to collect.
  local NO_CHESTS={'assembling-machine','furnace','agricultural-tower','cargo-landing-pad'}
  -- An agricultural tower's harvest is its output, as an assembler's product is (Gleba).
  local CRAFTER={['assembling-machine']=true,furnace=true,['agricultural-tower']=true}
  local CHEST={container=true,['logistic-container']=true}
  local MAX_PLACES=32
  local function output_of(e)
    if CRAFTER[e.type] then
      local ok,inv=pcall(e.get_output_inventory); return ok and inv or nil
    end
    local id=e.type=='cargo-landing-pad' and defines.inventory.cargo_landing_pad_main or defines.inventory.chest
    local ok,inv=pcall(e.get_inventory,id); return ok and inv or nil
  end
  local function makes(e,item)
    if not CRAFTER[e.type] then return false end
    local ok,recipe=pcall(e.get_recipe)
    if not (ok and recipe) then return false end
    for _,product in ipairs(recipe.products or {}) do if product.name==item then return true end end
    return false
  end
  -- Every own entity within radius of centre holding the item, nearest first,
  -- plus the crafters set to make it (whether or not they hold any now).
  function M.scan(p,item,opts)
    opts=opts or {}
    local centre=opts.position or p.position
    local quality=opts.quality or 'normal'
    local places,total,groups,makers={},0,{},{}
    for _,e in pairs(p.surface.find_entities_filtered{position=centre,radius=opts.radius or 128,force=p.force,type=opts.types or TYPES}) do
      if e.valid then
        if makes(e,item) then makers[e.name]=(makers[e.name] or 0)+1 end
        local inv=output_of(e)
        local n=inv and inv.get_item_count{name=item,quality=quality} or 0
        if n>0 then
          total=total+n
          local g=groups[e.name] or {name=e.name,entities=0,count=0,chest=CHEST[e.type] or nil}
          groups[e.name]=g; g.entities=g.entities+1; g.count=g.count+n
          places[#places+1]={entity=e,name=e.name,position=e.position,count=n,distance=api.distance(centre,e.position)}
        end
      end
    end
    table.sort(places,function(x,y) return x.distance<y.distance end)
    local list={}
    for _,g in pairs(groups) do list[#list+1]=g end
    table.sort(list,function(x,y) return x.count>y.count end)
    return {item=item,total=total,groups=list,places=places,makers=next(makers) and makers or nil}
  end
  -- One line an agent cannot skim past: how much, in what, and where.
  function M.line(s,centre)
    if s.total==0 then return nil end
    local parts={}
    for i,g in ipairs(s.groups) do
      if i>3 then parts[#parts+1]='...'; break end
      parts[#parts+1]=string.format('%d in %d %s',g.count,g.entities,g.name)
    end
    local near,big=s.places[1],s.places[1]
    for _,x in ipairs(s.places) do if x.count>big.count then big=x end end
    local largest=big~=near and string.format('; largest %d in %s at (%g,%g) %d tiles away',big.count,big.name,big.position.x,big.position.y,math.floor(big.distance+0.5)) or ''
    local chests=false
    for _,g in ipairs(s.groups) do if g.chest then chests=true end end
    return string.format('%d %s held by our factory (%s); nearest %d at (%g,%g) %d tiles away%s; collect item=%s radius=%d%s gathers it',
      s.total,s.item,table.concat(parts,', '),near.count,near.position.x,near.position.y,math.floor(near.distance+0.5),largest,
      s.item,math.max(8,math.ceil(math.max(s.places[math.min(#s.places,4)].distance,big.distance))+2),chests and ' chests=true' or '')
  end
  -- Without an item: what our machines and chests hold, per item, largest
  -- first (shake2: agents asked `scope=stock` bare and got an error).
  function M.summary(p,a,radius,limit)
    local centre=a.position and api.position(a.position) or p.position
    local totals,order={},{}
    for _,e in pairs(p.surface.find_entities_filtered{position=centre,radius=radius,force=p.force,type=TYPES}) do
      local inv=e.valid and output_of(e)
      for _,s in ipairs(inv and inv.get_contents() or {}) do
        local key=s.quality and s.quality~='normal' and s.name..'@'..s.quality or s.name
        local t=totals[key]
        if not t then t={item=key,count=0,entities=0,chests=0}; totals[key]=t; order[#order+1]=t end
        t.count=t.count+s.count; t.entities=t.entities+1
        if CHEST[e.type] then t.chests=t.chests+1 end
      end
    end
    table.sort(order,function(x,y) return x.count>y.count or (x.count==y.count and x.item<y.item) end)
    local items={}
    for i=1,math.min(limit,#order) do
      local t=order[i]
      items[i]=string.format('%s %d in %d %s%s',t.item,t.count,t.entities,t.entities==1 and 'entity' or 'entities',
        t.chests>0 and string.format(' (%d chest%s)',t.chests,t.chests==1 and '' or 's') or '')
    end
    return {radius=radius,items=items,more=#order>limit and #order-limit or nil,
      note=#order>0 and 'machine outputs and chests within radius; scope=stock item=NAME lists the places and a collect line' or 'no machine output or chest within radius holds anything'}
  end
  function M.view(p,a)
    local radius=api.integer(a.radius,128,1,1024,'radius')
    if a.item==nil then return M.summary(p,a,radius,api.integer(a.limit,16,1,64,'limit')) end
    assert(type(a.item)=='string' and prototypes.item[a.item],'item must be a known item name')
    local limit=api.integer(a.limit,8,1,MAX_PLACES,'limit')
    local centre=a.position and api.position(a.position) or p.position
    local s=M.scan(p,a.item,{position=centre,radius=radius,quality=a.quality})
    local places={}
    for i=1,math.min(limit,#s.places) do
      local x=s.places[i]
      places[i]={name=x.name,position=x.position,count=x.count,distance=math.floor(x.distance+0.5)}
    end
    return {item=a.item,total=s.total,by_entity=s.groups,places=places,more=#s.places>limit and #s.places-limit or nil,
      made_by=s.makers,held=p.get_main_inventory().get_item_count{name=a.item,quality=a.quality or 'normal'},summary=M.line(s,centre)}
  end
  -- Gathering: visit stock places nearest-neighbour from the character and
  -- take the item from each until `want` is met.
  local function route(start,places,limit)
    local left,out,at={},{},start
    for i,x in ipairs(places) do left[i]=x end
    while #left>0 and #out<(limit or MAX_PLACES) do
      local best,bd=1,math.huge
      for i,x in ipairs(left) do local d=api.distance(at,x.position); if d<bd then best,bd=i,d end end
      local x=table.remove(left,best)
      out[#out+1]={entity=x.entity,position=x.position}
      at=x.position
    end
    return out
  end
  -- Another agent's claimed places stay put; returns the places kept and the skipped_claims lines.
  local function unclaimed(p,places,what)
    local skipped,kept={},{}
    for _,place in ipairs(places) do
      local c=api.claims and api.claims.other(p,place.position)
      if c then
        local key=api.claims.label(c,p)
        if not skipped[key] then skipped[key]={places=0,count=0}; skipped[#skipped+1]=key end
        skipped[key].places=skipped[key].places+1; skipped[key].count=skipped[key].count+place.count
      else kept[#kept+1]=place end
    end
    if #skipped==0 then return places,nil end
    local lines={}
    for i,key in ipairs(skipped) do
      if i<=4 then lines[i]=string.format('%d %s in %d places of %s; ask the owner',skipped[key].count,what,skipped[key].places,key) end
    end
    return kept,lines
  end
  -- Without an item (Gemini, after the courier tools): every assembler and furnace output in the radius, all items,
  -- output slots only (never inputs or fuel); count caps the total.
  local OUTPUT={['assembling-machine']='assembling_machine_output',furnace='furnace_result'}
  function M.start_all(p,a,ticks)
    assert(a.chests==nil or a.chests==false,'collect with radius and no item takes machine outputs only; name an item to take from chests')
    assert(a.quality==nil,'quality goes with item')
    for _,t in ipairs(a.types or {}) do assert(OUTPUT[t],'collect with radius and no item takes machine outputs: types may be assembling-machine and furnace') end
    local radius=api.integer(a.radius,32,1,256,'radius')
    local want=api.integer(a.count,1000000,1,1000000,'count')
    local places,total={},0
    for _,e in pairs(p.surface.find_entities_filtered{position=p.position,radius=radius,force=p.force,type=a.types or {'assembling-machine','furnace'}}) do
      local inv=e.valid and output_of(e)
      local n=0
      for _,s in ipairs(inv and inv.get_contents() or {}) do n=n+s.count end
      if n>0 then
        total=total+n
        places[#places+1]={entity=e,name=e.name,position=e.position,count=n}
      end
    end
    local skipped
    places,skipped=unclaimed(p,places,'items')
    local action={kind='gather',all=true,want=want,got=0,visited=0,items={},targets=route(p.position,places),index=1,until_tick=game.tick+ticks}
    local out={items='all',want=want<1000000 and want or nil,stock=total,places=#action.targets,skipped_claims=skipped}
    if total==0 then out.note='no assembler or furnace output in radius holds anything' end
    return action,out
  end
  function M.start(p,a,ticks)
    if a.item==nil then return M.start_all(p,a,ticks) end
    assert(type(a.item)=='string' and prototypes.item[a.item],'collect with radius requires a known item')
    local radius=api.integer(a.radius,32,1,256,'radius')
    local want=api.integer(a.count,10000,1,100000,'count')
    local chests=a.chests==true
    local s=M.scan(p,a.item,{radius=radius,quality=a.quality,types=a.types or (chests and TYPES or NO_CHESTS)})
    -- Another agent's claimed stock stays put; the result says whose it is.
    local skipped
    s.places,skipped=unclaimed(p,s.places,a.item)
    local action={kind='gather',item=a.item,quality=a.quality,want=want,got=0,visited=0,
      targets=route(p.position,s.places),index=1,until_tick=game.tick+ticks}
    local out={item=a.item,want=want,stock=s.total,places=#action.targets,skipped_claims=skipped}
    if not chests and not a.types then
      -- Say how much sits in chests that this trip leaves alone.
      local all=M.scan(p,a.item,{radius=radius,quality=a.quality})
      if all.total>s.total then out.left_in_chests=all.total-s.total; out.note='chests are skipped; pass chests=true to take from them too' end
    end
    return action,out
  end
  -- Tours: the same walk through given entities (turrets, burners), topping
  -- each up; op names the runtime's visit ('rearm' or 'refuel').
  local MAX_TOUR=128
  function M.start_tour(p,op,entities,ticks,fields)
    local places={}
    for i,e in ipairs(entities) do places[i]={entity=e,position=e.position} end
    local action={kind='gather',op=op,got=0,visited=0,want=math.huge,targets=route(p.position,places,MAX_TOUR),index=1,until_tick=game.tick+ticks}
    for k,v in pairs(fields or {}) do action[k]=v end
    return action,{op=op,item=action.item,places=#action.targets,skipped=#entities>MAX_TOUR and #entities-MAX_TOUR or nil}
  end
  local function done(action)
    if action.op then return action.visited>0 and 'topped_up' or 'nothing_to_do' end
    return action.got>0 and 'collected' or 'nothing_collected'
  end
  -- Returns an outcome when the gathering is over.
  function M.tick(p,action)
    while true do
      if action.got>=action.want then return 'collected' end
      local t=action.targets[action.index]
      if not t then return done(action) end
      if not (t.entity and t.entity.valid) then
        action.index=action.index+1; action.nav=nil
      elseif p.can_reach_entity(t.entity) then
        local ok,out
        if action.op then ok,out=pcall(api.visit,p,action,t.entity)
        else ok,out=pcall(api.take,p,t.entity,action.item,action.quality,math.min(10000,action.want-action.got),action.all and OUTPUT[t.entity.type] or nil) end
        action.index=action.index+1; action.nav=nil; action.visited=action.visited+1
        if ok then
          action.got=action.got+out.transferred
          for _,st in ipairs(action.all and out.items or {}) do
            local key=st.name..(st.quality and '@'..st.quality or '')
            action.items[key]=(action.items[key] or 0)+st.count
          end
          if out.inventory_full then return 'inventory_full' end
          if out.stop then return out.stop end
        else action.errors=(action.errors or 0)+1 end
      else
        break
      end
    end
    local t=action.targets[action.index]
    if not action.nav then
      action.nav={position=t.position,tolerance=math.max(1,(p.reach_distance or 10)-3),max_stalls=6,replans=0,stalled=0,last_position=p.position}
      api.request_path(p,action.nav)
    end
    local outcome=api.navigate(p,action.nav)
    -- Arrived yet still out of reach, or blocked: skip this place.
    if outcome then action.index=action.index+1; action.nav=nil; api.stop_walking(p) end
  end
  return M
end
