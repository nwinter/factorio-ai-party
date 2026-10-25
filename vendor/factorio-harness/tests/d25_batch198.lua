-- d25 batch198 QK1 (after Sol #2264): the hub keep reads by item@quality. requests' sends_down (the preview), its keep,
-- freight's pads and stop lines, shipment's down, ready and cargo conflict lines, delivery_watch with no quality.
-- 2.0.77 on a copy of world n's d25 07:26 save, Kestrel IVc stopped at Fulgora with 4 normal and 3 legendary asteroid
-- collectors (section 1 asteroid-collector 4..4 from nauvis, 23 asteroid-collector@legendary 0..3 from nauvis): section
-- 24 (asteroid-collector@rare 0..1 from fulgora) switched on, both stayed 26 s; Fulgora's pad asking 2 normal took 2
-- normal and no legendary; asking 1 legendary, it took 1 legendary and no normal. Main's preview of switching section 24
-- on said "3 down to fulgora (here) ... its requests from fulgora keep 1".
-- Run from the harness root: lua tests/d25_batch198.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
local QUALITY={normal={level=0},uncommon={level=1},rare={level=2},epic={level=3},legendary={level=5}}
local AC='asteroid-collector'
-- a pads reply by "name@quality", or by name without the flag
local function by(t,q)
  if q then return t or {} end
  local out={}
  for k,v in pairs(t or {}) do local n=k:match('^(.*)@') or k; out[n]=(out[n] or 0)+v end
  return out
end
local function slot(q,min,max,from,cmp) return {value={type='item',name=AC,quality=q,comparator=cmp or '='},min=min,max=max,import_from=from} end

-- requests on Kestrel IVc: sections 1 (normal 4..4 from nauvis), 2 (legendary 0..3 from nauvis), 3 (rare 0..1 from
-- fulgora, off); stopped at fulgora (stop 2 of nauvis, fulgora, aquilo)
local function kestrel(held,pads)
  game={tick=61470624}
  defines={space_platform_state={paused=7},rocket_silo_status={},inventory={hub_main=1,hub_trash=2},cargo_destination={}}
  prototypes={item={[AC]={}},space_location={nauvis={},fulgora={},aquilo={}},quality=QUALITY}
  local list={}
  local function section(i,active,filters)
    local slots={}
    for k,f in ipairs(filters) do slots[k]=f end
    local s={index=i,is_manual=true,group='',active=active}
    local function count() local n=0; for k in pairs(slots) do n=math.max(n,k) end; return n end
    s.get_slot=function(k) return slots[k] or {} end
    s.set_slot=function(k,f) slots[k]=f end
    s.clear_slot=function(k) slots[k]=nil end
    setmetatable(s,{__index=function(_,k)
      if k=='filters' then local out={}; for j=1,count() do out[j]=slots[j] or {} end; return out end
      if k=='filters_count' then return count() end end,
      __newindex=function(t,k,v) if k=='filters' then for j in pairs(slots) do slots[j]=nil end; for j,f in ipairs(v) do slots[j]=f end else rawset(t,k,v) end end})
    list[i]=s
  end
  section(1,true,{slot('normal',4,4,'nauvis')})
  section(2,true,{slot('legendary',0,3,'nauvis')})
  section(3,false,{slot('rare',0,1,'fulgora')})
  local secs=setmetatable({get_section=function(i) return list[i] end,add_section=function() section(#list+1,true,{}); return list[#list] end},
    {__index=function(_,k) if k=='sections_count' then return #list end end})
  local function count(x) local q=type(x)=='table' and x.quality or 'normal'; local n=type(x)=='table' and x.name or x; return n==AC and held[q] or 0 end
  local main={get_item_count=count,get_contents=function() return {} end}
  local pl={valid=true,name='Kestrel IVc',index=9,force='player',schedule={current=2,records={{station='nauvis'},{station='fulgora'},{station='aquilo'}}},
    hub={valid=true,unit_number=88,type='space-platform-hub',position={x=0,y=0},get_logistic_sections=function() return secs end,get_inventory=function() return main end,
      get_item_count=count}}
  local p={index=1,force={platforms={pl}}}
  local st={}
  local space=dofile('mod/agent-harness_0.1.0/space.lua'){state=function() return st end,
    integer=function(v,d,lo,hi,name) v=v==nil and d or v; assert(type(v)=='number' and v>=lo and v<=hi,name..' out of range'); return v end,
    keep=function() return {set_construction=function(_,on) return on end,construction=function() return nil end} end,
    freight={where=function() return {stopped=true,at='fulgora'} end,
      pads=function(planet,_,q) local x=pads[planet] or {}; return by(x.ask,q),by(x.hold,q) end}}
  return space,p,list
end

do
  -- Sol's case: switching section 24 (here 3) on keeps nothing less of the normal or legendary held; none of rare held
  local space,p=kestrel({normal=4,legendary=3},{})
  local r=space.requests(p,{platform='Kestrel IVc',section=3,active=true,dry_run=true})
  eq(r.sends_down,nil,'no line: the rare max keeps nothing of the other qualities')
  -- with 2 rare held: the one above its max, named item@quality
  space,p=kestrel({normal=4,legendary=3,rare=2},{})
  r=space.requests(p,{platform='Kestrel IVc',section=3,active=true,dry_run=true})
  eq(#r.sends_down,1)
  eq(r.sends_down[1],'asteroid-collector@rare: the hub holds 2; its requests would keep 1 at fulgora (kept none): 1 over its max 1 go to the hub\'s trash now and down to fulgora (here), asked or not; 1 stay aboard')
  has(r.sends_down_rule,'a request\'s max is for its own quality, and a landing pad\'s ask too')
  -- section 1 off with Fulgora's pad asking 2 normal and 1 legendary: 2 normal down there; the legendary's rows do not
  -- change, so no line for it
  space,p=kestrel({normal=4,legendary=3},{fulgora={ask={[AC..'@normal']=2,[AC..'@legendary']=1},hold={}}})
  r=space.requests(p,{platform='Kestrel IVc',section=1,active=false,dry_run=true})
  eq(#r.sends_down,1)
  eq(r.sends_down[1],'asteroid-collector: the hub holds 4; its requests would keep none (kept 4 at nauvis): 2 down to fulgora (here) (its landing pads ask 2, hold 0); 2 stay aboard')
  -- a quality comparator: named, not forecast
  local list
  space,p,list=kestrel({normal=4,legendary=3},{})
  list[3].set_slot(1,slot('rare',0,1,'fulgora','>='))
  r=space.requests(p,{platform='Kestrel IVc',section=3,active=true,dry_run=true})
  eq(r.sends_down[1],'asteroid-collector: a request names it with a quality comparator (asteroid-collector@>=rare): what the hub keeps of it is not forecast')
  -- keep "item@quality": section 2's legendary 0..3 made 0..1, the 3 legendary held kept by its min
  space,p,list=kestrel({normal=4,legendary=3},{})
  r=space.requests(p,{platform='Kestrel IVc',section=2,set={{item=AC,quality='legendary',min=0,max=1,from='nauvis'}},keep={AC..'@legendary'}})
  has(table.concat(r.stored,' | '),'asteroid-collector@legendary: kept at the 3 the hub holds')
  eq(list[2].get_slot(1).min,3); eq(list[2].get_slot(1).value.quality,'legendary')
  -- the normal ones, held at section 1's min 4: kept already, the legendary's mins not counted
  space,p=kestrel({normal=4,legendary=3},{})
  r=space.requests(p,{platform='Kestrel IVc',section=2,set={{item=AC,quality='legendary',min=1,max=3,from='nauvis'}},keep={AC}})
  has(table.concat(r.stored,' | '),'asteroid-collector: kept already (the hub holds 4, its requests keep 4)')
  local ok,err=pcall(space.requests,p,{platform='Kestrel IVc',section=2,set={{item=AC,quality='legendary',min=1,from='nauvis'}},keep={AC..'@mythic'}})
  assert(not ok and tostring(err):find('unknown quality: mythic',1,true),tostring(err))
  game,defines,prototypes=nil,nil,nil
end
print('d25_batch198 QK1 requests sends_down and keep by quality: ok')

-- freight: pads by quality, hub_gives with each quality's want
do
  prototypes={item={[AC]={stack_size=10}},quality=QUALITY}
  defines={inventory={cargo_landing_pad_main=4}}
  local pad={get_logistic_sections=function() return {sections_count=1,get_section=function() return {active=true,filters={slot('normal',2),slot('legendary',1)}} end} end,
    get_inventory=function() return {get_contents=function() return {{name=AC,quality='legendary',count=1}} end} end}
  game={tick=0,planets={fulgora={surface={find_entities_filtered=function() return {pad} end}}}}
  local F=dofile('mod/agent-harness_0.1.0/freight.lua'){state=function() return {} end}
  local ask,hold=F.pads('fulgora','player',true)
  eq(ask[AC..'@normal'],2); eq(ask[AC..'@legendary'],1); eq(hold[AC..'@legendary'],1)
  local a2,h2=F.pads('fulgora','player')
  eq(a2[AC],3); eq(h2[AC],1)
  local wants=F.wants(ask,hold)
  eq(wants[AC].normal,2); eq(wants[AC].legendary,0)
  local keeps=F.hub_keeps_at({sections_count=1,get_section=function() return {active=true,filters={slot('rare',0,1,'fulgora')}} end},'fulgora')
  -- 3 legendary, the pads asking 2 normal: none goes down
  eq((F.hub_gives(keeps,AC,3,{normal=2},false,{legendary=3})),0)
  eq((F.hub_gives(keeps,AC,3,{legendary=1},false,{legendary=3})),1)
  eq((F.hub_gives(keeps,AC,7,{normal=2,legendary=1},false,{normal=4,legendary=3})),3)
  -- with the rare above its max
  eq((F.hub_gives(keeps,AC,5,{normal=2},false,{normal=2,rare=3})),4)
  game,defines,prototypes=nil,nil,nil
end
print('d25_batch198 QK1 freight pads and hub_gives by quality: ok')

-- freight's stop lines: Kestrel IVc stopped at fulgora with 3 legendary; its section asks 3 normal from fulgora, the
-- pad 2 normal: expected up 3, expected down 0
do
  defines={space_platform_state={on_the_path=3,waiting_at_station=6,no_schedule=5},inventory={hub_main=1,hub_trash=2,cargo_landing_pad_main=3,cargo_unit=4}}
  prototypes={item={[AC]={get_spoil_ticks=function() return 0 end}},quality=QUALITY,space_location={fulgora={},nauvis={}}}
  local function inv(t) return {get_contents=function() local out={}; for k,c in pairs(t) do local n,q=k:match('^(.*)@(.*)$'); out[#out+1]={name=n,count=c,quality=q} end; return out end} end
  local main={[AC..'@legendary']=3}
  local hub_secs={sections_count=1,get_section=function() return {active=true,filters={slot('normal',3,nil,{name='fulgora'})}} end}
  local hub={valid=true,get_inventory=function(id) return id==1 and inv(main) or inv({}) end,get_logistic_sections=function() return hub_secs end}
  local kes={valid=true,index=9,name='Kestrel IVc',hub=hub,state=6,space_location={name='fulgora'},schedule={records={{station='nauvis'},{station='fulgora'}},current=2}}
  local force={name='player',platforms={kes}}
  kes.force=force
  local pad={get_logistic_sections=function() return {sections_count=1,get_section=function() return {active=true,filters={slot('normal',2)}} end} end,
    get_inventory=function() return inv({}) end}
  game={tick=0,forces={player=force},planets={fulgora={surface={find_entities_filtered=function() return {pad} end}},nauvis={surface={find_entities_filtered=function() return {} end}}}}
  local st={}
  local F=dofile('mod/agent-harness_0.1.0/freight.lua'){state=function() return st end,spoil=dofile('mod/agent-harness_0.1.0/spoil.lua'){state=function() return st end}}
  game.tick=60; F.tick(60)
  local seg=st.freight[9].segs[1]
  eq(seg.up[AC].short,3,'3 legendary held do not meet a request for 3 normal'); eq(seg.up[AC].min,3)
  eq(seg.down,nil,'the pad asks normal: none of the legendary goes down')
  game,defines,prototypes=nil,nil,nil
end
print('d25_batch198 QK1 freight stop lines by quality: ok')

-- shipment: cargo conflict lines, the platform's down list and the ready read by quality
do
  game={tick=0,planets={}}
  defines={inventory={hub_main=1,hub_trash=2,cargo_landing_pad_main=1},space_platform_state={waiting_at_station=4}}
  prototypes={item={[AC]={stack_size=10}},quality=QUALITY}
  local list={{active=true,filters={slot('legendary',0,1,'aquilo')}}}
  local pl={valid=true,name='Kestrel IVc',index=9,force={},state=4,space_location={name='fulgora'},paused=false,
    hub={valid=true,get_logistic_sections=function() return {sections_count=#list,get_section=function(i) return list[i] end} end},
    schedule={current=2,records={{station='nauvis'},{station='fulgora'},{station='aquilo'}}}}
  local held={[AC..'@legendary']=3}
  local pads={fulgora={ask={[AC..'@normal']=2},hold={}},aquilo={ask={[AC..'@normal']=2,[AC..'@legendary']=3},hold={}},nauvis={ask={},hold={}}}
  local FR=dofile('mod/agent-harness_0.1.0/freight.lua'){state=function() return {} end}
  local S=dofile('mod/agent-harness_0.1.0/shipment.lua'){state=function() return {} end,freight=function() return FR end,
    hub_counts=function(_,q) if q then return held end local o={}; for k,v in pairs(held) do local n=k:match('^(.*)@'); o[n]=(o[n] or 0)+v end; return o end,
    where=function() return {at='fulgora',stopped=true} end,
    pads=function(planet,_,q) return by(pads[planet].ask,q),by(pads[planet].hold,q) end}
  -- the pads at fulgora and aquilo both ask by name; by quality only aquilo's ask legendary: no conflict
  eq(S.conflicts(pl),nil,'normal asked at two stops, legendary held')
  -- 3 normal more: both ask 2 normal
  held[AC..'@normal']=3
  local c=S.conflicts(pl)
  eq(#c,1)
  eq(c[1],'cargo conflict on Kestrel IVc: the hub holds 3 asteroid-collector; stop 2 fulgora (here): its pads ask 2 (hold 0), 2 go down there, 1 left aboard; stop 3 aquilo: its pads ask 2 (hold 0), 1 go down there, 0 left aboard')
  -- legendary asked at aquilo and nauvis: aquilo's section keeps 1 of the 3
  pads.nauvis.ask[AC..'@legendary']=5
  c=S.conflicts(pl)
  eq(#c,2)
  eq(c[2],'cargo conflict on Kestrel IVc: the hub holds 3 asteroid-collector@legendary; stop 3 aquilo: its pads ask 3 (hold 0), its requests from aquilo keep 1 (hub section 1 keeps asteroid-collector@legendary 0..1 at aquilo), 2 go down there, 1 left aboard; stop 1 nauvis: its pads ask 5 (hold 0), 1 go down there, 0 left aboard')
  game,defines,prototypes=nil,nil,nil
end
print('d25_batch198 QK1 shipment cargo conflicts by quality: ok')

do
  defines={space_platform_state={waiting_at_station=4},inventory={hub_main=1,hub_trash=2,cargo_landing_pad_main=1}}
  game={tick=61470624}
  prototypes={item={[AC]={stack_size=10}},quality=QUALITY}
  local F=dofile('mod/agent-harness_0.1.0/freight.lua'){state=function() return {} end}
  local force={}
  local padinv={count_empty_stacks=function() return 10 end,get_insertable_count=function() return 100 end,get_contents=function() return {} end}
  setmetatable(padinv,{__len=function() return 80 end})
  local pad={valid=true,type='cargo-landing-pad',force=force,name='cargo-landing-pad',position={x=74,y=208},get_inventory=function() return padinv end,
    get_logistic_sections=function() return {sections_count=1,get_section=function() return {active=true,filters={slot('normal',2)}} end} end}
  local fs={index=3,name='fulgora',find_entities_filtered=function(f) if type(f.type)=='table' then return {pad} end return {} end}
  game.planets={fulgora={surface=fs}}
  local held={[AC..'@legendary']=3}
  local list={{active=true,filters={slot('legendary',0,3,'nauvis')}}}
  local pl={valid=true,name='Kestrel IVc',index=9,state=4,space_location={name='fulgora'},force=force,paused=false,
    schedule={current=2,records={{station='nauvis'},{station='fulgora'},{station='aquilo'}}},
    hub={valid=true,get_logistic_sections=function() return {sections_count=#list,get_section=function(i) return list[i] end} end}}
  local S=dofile('mod/agent-harness_0.1.0/shipment.lua'){state=function() return {} end,freight=function() return F end,
    hub_counts=function(_,q) if q then return held end local o={}; for k,v in pairs(held) do local n=k:match('^(.*)@'); o[n]=(o[n] or 0)+v end; return o end,
    where=function() return {at='fulgora',stopped=true,text='at fulgora'} end,
    request_rows=function() return {} end,gate=function() return {lines={}} end,gate_row=function() return nil end,rocket=function() return nil end}
  -- the pad asks 2 normal; the hub holds 3 legendary: none goes down
  local r=S.read({force={platforms={pl}}},{platform='Kestrel IVc',ready=true})
  eq(#r.down,0,'the pad asks normal, the hub holds legendary')
  held[AC..'@normal']=5
  r=S.read({force={platforms={pl}}},{platform='Kestrel IVc',ready=true})
  eq(r.down[1].count,2)
  game,defines,prototypes=nil,nil,nil
end
print('d25_batch198 QK1 shipment ready by quality: ok')

-- delivery_watch with no quality: Kestrel IVc stopped at aquilo (the destination) with 3 legendary, the pad asking 2
-- normal and none of it held: none goes down
do
  defines={inventory={hub_main=1,cargo_unit=3,cargo_landing_pad_main=4,chest=5}}
  prototypes={item={[AC]={stack_size=10}},quality=QUALITY}
  game={tick=61470624}
  local held={legendary=3}
  local function hubinv()
    return {get_item_count=function(x) local q=type(x)=='table' and x.quality or 'normal'; local nm=type(x)=='table' and x.name or x; return nm==AC and held[q] or 0 end,
      get_item_count_filtered=function() local c=0; for _,v in pairs(held) do c=c+v end; return c end}
  end
  local aquilo={name='aquilo',find_logistic_network_by_position=function() return {network_id=1} end}
  local pad={valid=true,name='cargo-landing-pad',type='cargo-landing-pad',position={x=-8,y=-22},surface=aquilo,unit_number=77,
    get_inventory=function() return {get_item_count=function() return 0 end,can_insert=function() return true end} end,get_item_count=function() return 0 end,
    get_logistic_sections=function() return {sections_count=1,get_section=function() return {active=true,filters={slot('normal',2)}} end} end}
  aquilo.find_entities_filtered=function(f) if f.position and f.position.x==-8 then return {pad} end return {} end
  local force={name='player',is_chunk_charted=function() return true end}
  local list={{active=true,filters={}}}
  local kes={valid=true,name='Kestrel IVc',index=9,surface={name='platform-9'},paused=false,space_location={name='aquilo'},
    schedule={current=3,records={{station='nauvis'},{station='fulgora'},{station='aquilo'}}},
    hub={valid=true,type='space-platform-hub',get_inventory=function() return hubinv() end,get_logistic_sections=function() return {sections_count=1,get_section=function() return list[1] end} end}}
  force.platforms={kes}
  game.forces={player=force}; game.planets={aquilo={surface=aquilo},fulgora={surface={name='fulgora'}},nauvis={surface={name='nauvis'}}}
  local F=dofile('mod/agent-harness_0.1.0/freight.lua'){state=function() return {} end}
  local st={}
  local W=dofile('mod/agent-harness_0.1.0/delivwatch.lua'){state=function() return st end,who=function(p) return p.name end,
    census_typed=function(_,s) return s==aquilo and {pad} or {} end,
    freight={where=function() return {} end,receipts_since=function() return {} end,followed=function() return {down={},up={}} end,spoils=function() return false end,
      hub_keeps_at=F.hub_keeps_at,hub_gives=F.hub_gives,keep_text=F.keep_text,no_unload=F.no_unload,by_item=F.by_item,
      hub_counts=function() local o={}; for q,v in pairs(held) do if v>0 then o[AC..'@'..q]=v end end; return o end}}
  local sol={name='sol',index=1,force=force,surface=aquilo}
  W.call(sol,{item=AC,count=3,to={position={x=-8,y=-22},surface='aquilo'},deadline_min=80,from='Kestrel IVc'})
  local id=st.delivwatch.list[1].id
  game.tick=game.tick+60; W.tick(game.tick-game.tick%60)
  local row=W.call(sol,{id=id}).watches[1]
  eq(row.at_destination.sends,0,'the pad asks normal: the legendary stays')
  held.normal=1
  game.tick=game.tick+60; W.tick(game.tick-game.tick%60)
  row=W.call(sol,{id=id}).watches[1]
  eq(row.at_destination.sends,1,'the one normal goes down')
  game,defines,prototypes=nil,nil,nil
end
print('d25_batch198 QK1 delivery_watch with no quality: ok')

-- QK2 (Astra #2325): stock {item: iron-plate, quality: legendary, position (-71.5,86.7), radius: 3} on Nauvis gave 3
-- ground stacks: the 32-tile cell's 3 stacks of normal iron (2.0.77 on a copy of world n's d25 07:26 save: normal iron
-- at (-71.5,86.7), (-68.5,86.7) and (-65.5,86.7); 3 legendary spilled at (-70.5,86.7) lay as 3 stacks of 1, each one
-- quality)
do
  prototypes={item={['iron-plate']={}},quality=QUALITY}
  game={tick=61487764}
  local function stack(x,y,q) return {position={x=x,y=y},stack={valid_for_read=true,name='iron-plate',count=1,quality={name=q}}} end
  local ground={stack(-71.5,86.7,'normal'),stack(-68.5,86.7,'normal'),stack(-65.5,86.7,'normal'),stack(-70.8,86.4,'legendary'),stack(-70.2,86.9,'legendary'),stack(-70.5,87.3,'legendary')}
  local finds={}
  local nauvis={name='nauvis',index=1,find_entities_filtered=function(f)
    finds[#finds+1]=f
    if f.type~='item-entity' then return {} end
    local out={}
    for _,e in ipairs(ground) do
      if not f.position or (e.position.x-f.position.x)^2+(e.position.y-f.position.y)^2<=f.radius^2 then out[#out+1]=e end
    end
    return out
  end}
  local force={is_chunk_visible=function() return true end}
  local stores=dofile('mod/agent-harness_0.1.0/stores.lua'){}
  local g=stores.on_ground(force,nauvis,'iron-plate',{quality='legendary',position={x=-71.5,y=86.7},radius=3})
  eq(g.count,3); eq(g.stacks,3)
  g=stores.on_ground(force,nauvis,'iron-plate',{quality='normal',position={x=-71.5,y=86.7},radius=3})
  eq(g.count,2,'the stack 6 tiles off is outside the radius'); eq(g.cells[1].position.x,-71.5)
  eq(stores.on_ground(force,nauvis,'iron-plate').count,6,'no opts: every quality, the whole surface, as before')
  -- stock: the ground rows of the quality asked, with it
  local stock=dofile('mod/agent-harness_0.1.0/stock.lua'){
    integer=function(v,d) return v==nil and d or v end,position=function(x) return x end,
    distance=function(a,b) return math.sqrt((a.x-b.x)^2+(a.y-b.y)^2) end,
    on_ground=function(f,s,item,o) return stores.on_ground(f,s,item,o) end}
  local p={force=force,surface=nauvis,position={x=0,y=0},get_main_inventory=function() return {get_item_count=function() return 0 end} end}
  local r=stock.view(p,{item='iron-plate',quality='legendary',position={x=-71.5,y=86.7},radius=3},{surface=nauvis})
  eq(r.on_ground,3); eq(r.places[1].quality,'legendary'); eq(r.places[1].name,'3 stacks on the ground')
  has(r.on_ground_note,'stacks of iron-plate@legendary on the ground within the radius')
  r=stock.view(p,{item='iron-plate',position={x=-71.5,y=86.7},radius=3},{surface=nauvis})
  eq(r.on_ground,2); eq(r.places[1].quality,'normal'); has(r.on_ground_note,'iron-plate (normal quality)')
  eq(finds[#finds].radius,3,'the ground found within the radius')
  game,prototypes=nil,nil
end
print('d25_batch198 QK2 stock ground rows by quality: ok')
