-- d17 batch21 (operator 17:00: the agents' 16:50 poll). Run from the harness root: lua tests/d17_batch21.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,msg) assert(a==b,(msg or '')..' '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end

-- A2 (Astra): the platform_bom keeper adopts a minimum payload changed on its slot; tail: no more than what is to come.
do
  game={tick=0,forces={}}
  defines={inventory={hub_main=1}}
  prototypes={space_location={fulgora={}},item={crusher={}}}
  local ghosts={}
  local crusher={name='crusher',items_to_place_this={{name='crusher',count=1}}}
  for i=1,12 do ghosts[i]={type='entity-ghost',ghost_name='crusher',ghost_prototype=crusher} end
  local sections={}
  local function section(group)
    local sec={group=group,slots={},is_manual=true,filters_count=0}
    sec.set_slot=function(i,f) sec.slots[i]=f; sec.filters_count=math.max(sec.filters_count,i) end
    sec.get_slot=function(i) return sec.slots[i] end
    sec.clear_slot=function(i) sec.slots[i]=nil end
    return sec
  end
  local secs={sections_count=0}
  secs.get_section=function(i) return sections[i] end
  secs.add_section=function(g) sections[#sections+1]=section(g); secs.sections_count=#sections; return sections[#sections] end
  secs.remove_section=function(i) table.remove(sections,i); secs.sections_count=#sections end
  local held=0
  local hub={valid=true,get_logistic_sections=function() return secs end,get_inventory=function() return {get_item_count=function() return held end} end}
  local pl={valid=true,index=5,name='Kestrel',hub=hub,space_location={name='fulgora'},surface={find_entities_filtered=function() return ghosts end}}
  local force={name='player',platforms={pl}}
  pl.force=force; game.forces={player=force}
  local st={}
  local B=dofile('mod/agent-harness_0.1.0/platbom.lua'){platform=function() return pl end,state=function() return st end}
  B.read({force=force},{platform='Kestrel',request=true,min_payload={crusher=10}})
  eq(sections[1].slots[1].minimum_delivery_count,10)
  -- min_payload (or requests) sets 9 on the slot: the keeper keeps 9
  sections[1].slots[1].minimum_delivery_count=9
  B.tick(600); B.tick(1200)
  eq(sections[1].slots[1].minimum_delivery_count,9)
  local r
  -- tail: 12 asked, the hub holds 10: 2 to come, the payload 2
  held=10
  r=B.read({force=force},{platform='Kestrel',request=true,tail=true})
  eq(sections[1].slots[1].minimum_delivery_count,2)
  has(r.lines[1],'custom minimum payload 2 (tail: 2 of the 9 set, what is still to come)')
  has(r.lines[1],'(adopted from the slot, changed by requests or min_payload: 9)')
  defines,prototypes=nil,nil
end
print('d17_batch21 A2 platform_bom keeps a changed min payload: ok')

-- A3 (Grok): a walking load whose rocket launches by another hand gives what it took and did not load back to the
-- chests it took from, the latest first, as the tour's next stops; the reply says what went back and where.
do
  game={tick=1000}
  prototypes={item={['agricultural-science-pack']={weight=1000}}}
  defines={inventory={rocket_silo_rocket=1},rocket_silo_status={rocket_ready=13}}
  local silo={valid=true,name='rocket-silo',type='rocket-silo',position={x=65.5,y=14.5},unit_number=9}
  local c1={valid=true,name='passive-provider-chest',position={x=14.5,y=28.5}}
  local c2={valid=true,name='passive-provider-chest',position={x=20.5,y=28.5}}
  local held=16
  local gave={}
  local launched
  local R=dofile('mod/agent-harness_0.1.0/rocketload.lua'){last_launch=function() return launched end,
    held=function() return held end,
    give=function(_,e,item,_,n) gave[#gave+1]=e.name..'@'..e.position.x..' '..item..' '..n; held=held-n; return {transferred=n} end,
    rocket_weight=function() return '0/1000 kg' end}
  local action={silo=silo,started_tick=500,goals={{name='agricultural-science-pack',quality='normal',target=500}},rows={},trips=1,items={['agricultural-science-pack']=366},load={},
    loaded_items={['agricultural-science-pack']=350},targets={{entity=c1},{entity=silo},{entity=c1},{entity=silo}},index=2,
    sources={{entity=c1,name='agricultural-science-pack',quality='normal',n=350},{entity=c2,name='agricultural-science-pack',quality='normal',n=16}}}
  launched={tick=900,by='astra',cargo='agricultural-science-pack 350'}
  local out=R.walk_visit({},action,silo)
  eq(out.stop,nil); eq(#action.targets,3); eq(action.targets[3].entity,c2)
  -- at the chest: the 16 taken from it and not loaded go back
  R.walk_visit({},action,c2)
  eq(gave[1],'passive-provider-chest@20.5 agricultural-science-pack 16'); eq(held,0)
  local last={}
  R.walk_last(action,last)
  eq(last.returned,'agricultural-science-pack 16 to passive-provider-chest (20.5,28.5)'); eq(last.kept,nil)
  has(action.why,'what it took and did not load goes back to the chests it came from')
  defines,prototypes=nil,nil
end
print('d17_batch21 A3 a load cut by a launch gives back: ok')

-- B1 (Sonnet): pipe_gaps {line}: the pipe network through one pipe, by fluid segment, empty ones named, machines it joins.
do
  local force={name='player'}
  local function fb(seg,fluid,amount,cap,locked)
    return setmetatable({get_fluid_segment_id=function() return seg end,
      get_fluid_segment_contents=function() return fluid and {[fluid]=amount} or {} end,
      get_capacity=function() return cap end,get_locked_fluid=function() return locked end},{__len=function() return 1 end,__index=function(_,i) return nil end})
  end
  local ents={}
  local function pipe(name,typ,x,seg,fluid,amount,cap,locked)
    local e={valid=true,name=name,type=typ,position={x=x+0.5,y=0.5},force=force,unit_number=100+x,fluidbox=fb(seg,fluid,amount,cap,locked)}
    ents[x]=e; return e
  end
  for x=1,3 do pipe('pipe','pipe',x,11,'crude-oil',150,300) end
  pipe('pump','pump',4,12,'crude-oil',20,200)
  for x=5,6 do pipe('pipe','pipe',x,13,nil,0,200,'crude-oil') end
  local jack={valid=true,name='pumpjack',type='mining-drill',position={x=0.5,y=1.5},force=force,unit_number=99}
  for x=1,6 do
    ents[x].neighbours={{ents[x-1] or jack,ents[x+1]}}
  end
  local G=dofile('mod/agent-harness_0.1.0/pipegaps.lua'){position=function(v) return v end,visible=function() return true end,
    fluids=function(e) return 'crude-oil 10/100' end}
  local r=G.network({force=force},ents[2])
  eq(r.entities,6); eq(#r.segments,3)
  eq(r.segments[1].line,'segment 11 (1.5,0.5)-(3.5,0.5), 3 entities: crude-oil 150/300')
  eq(r.empty[1],'segment 13 (5.5,0.5)-(6.5,0.5), 2 entities: empty (locked to crude-oil) /200')
  eq(r.machines[1],'pumpjack (0.5,1.5): crude-oil 10/100')
  has(r.line,'the pipe network through (2.5,0.5): 6 entities in 3 segments; 1 empty')
end
print('d17_batch21 B1 pipe network: ok')

-- B2 (Sonnet): placements {resource}: wells and drill spots on a resource, each blocked one with why.
do
  defines={build_check_type={manual=1}}
  prototypes={entity={['crude-oil']={type='resource'},['iron-ore']={type='resource'}}}
  local function res(name,x,y,amount,fluid) return {valid=true,name=name,position={x=x,y=y},amount=amount,
    prototype={resource_category='basic-'..(fluid and 'fluid' or 'solid'),infinite_resource=fluid or nil,mineable_properties={products={{type=fluid and 'fluid' or 'item'}}}}} end
  local wells={res('crude-oil',10.5,10.5,300000,true),res('crude-oil',20.5,10.5,150000,true),res('crude-oil',30.5,10.5,90000,true)}
  local jack={valid=true,name='pumpjack',position={x=20.5,y=10.5}}
  local surface={find_entities_filtered=function(f)
      if f.type=='resource' then return f.name=='crude-oil' and wells or {} end
      if f.type=='mining-drill' then return (f.position.x==20.5) and {jack} or {} end
      return {} end,
    can_place_entity=function(a) return not (a.position.x==30.5) and (a.direction==0 or a.direction==4) end}
  local p={surface=surface,force={},position={x=20,y=10}}
  local D=dofile('mod/agent-harness_0.1.0/drillspots.lua'){position=function(v) return v end,integer=function(v,d) return v or d end,read_sight=function() end,
    seen=function() return true end,why=function(_,_,q) return 'placement blocked by tiles: oil-ocean-shallow (needs foundation (not researched))' end}
  local r=D.read(p,{resource='crude-oil',radius=16},{name='pumpjack',type='mining-drill',resource_categories={['basic-fluid']=true}})
  eq(r.free_count,1); eq(r.free[1].line,'crude-oil (10.5,10.5) yield 300000: fits facing north, east')
  eq(r.blocked_count,2); has(r.blocked_by,'ours already 1 (one at (20.5,10.5))'); has(r.blocked_by,'tiles: oil-ocean-shallow 1 (one at (30.5,10.5))')
  -- a drill on a 4x4 iron block: the spot with the most ore under it first, none overlapping
  local ore={}
  for x=0,3 do for y=0,3 do ore[#ore+1]=res('iron-ore',x+0.5,y+0.5,100) end end
  surface.find_entities_filtered=function(f) if f.type=='resource' then return ore end return {} end
  surface.can_place_entity=function() return true end
  r=D.read({surface=surface,force={},position={x=2,y=2}},{resource='iron-ore',radius=6},{name='electric-mining-drill',type='mining-drill',
    resource_categories={['basic-solid']=true},mining_drill_radius=2.49,tile_width=3,tile_height=3})
  eq(r.free[1].tiles,16); eq(r.free[1].amount,1600)
  for i=2,#r.free do assert(math.abs(r.free[i].position.x-r.free[1].position.x)>=3 or math.abs(r.free[i].position.y-r.free[1].position.y)>=3,'no overlap') end
  defines,prototypes=nil,nil
end
print('d17_batch21 B2 drill and well spots: ok')
