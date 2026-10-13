-- Run from repository root: lua tests/space.lua
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
defines={space_platform_state={waiting_for_starter_pack=0,waiting_at_station=6,paused=7},
  rocket_silo_status={building_rocket=5,rocket_ready=9},inventory={hub_main=1,rocket_silo_rocket=2},
  cargo_destination={orbit=1,station=2,surface=3,space_platform=4}}
prototypes={item={['iron-plate']={},coal={},['space-platform-starter-pack']={}},space_location={nauvis={},vulcanus={}}}
-- A manual logistic section with slots like the engine's (gaps allowed).
local function section(manual,group)
  local slots={}
  local sec={index=1,is_manual=manual,group=group or '',active=true}
  sec.filters_count=0
  local function recount() local n=0; for i in pairs(slots) do n=math.max(n,i) end; sec.filters_count=n end
  sec.get_slot=function(i) return slots[i] or {} end
  sec.set_slot=function(i,f) slots[i]=f; recount() end
  sec.clear_slot=function(i) slots[i]=nil; recount() end
  setmetatable(sec,{__index=function(_,k) if k=='filters' then local out={}; for i=1,sec.filters_count do out[i]=slots[i] or {} end; return out end end,
    __newindex=function(t,k,v) if k=='filters' then slots={}; recount() else rawset(t,k,v) end end})
  return sec
end
local function sections(list)
  return setmetatable({get_section=function(i) return list[i] end,
    add_section=function() local s=section(true); s.index=#list+1; list[#list+1]=s; return s end},
    {__index=function(_,k) if k=='sections_count' then return #list end end})
end
local char_sections=sections({})
local hub_sections=sections({section(false),section(true)})
hub_sections.get_section(2).index=2
local hub_inv={get_contents=function() return {{name='iron-plate',count=5}} end}
local platform={valid=true,name='alpha',index=1,state=7,paused=true,space_location={name='nauvis'},weight=60000,
  surface={name='platform-1'},hub={valid=true,position={x=0,y=0},get_logistic_sections=function() return hub_sections end,
    get_inventory=function() return hub_inv end},can_leave_current_location=function() return true end}
local silo_cargo={get_contents=function() return {} end}
local launched
local silo={valid=true,type='rocket-silo',position={x=20.5,y=20.5},rocket_silo_status=5,rocket_parts=10,prototype={rocket_parts_required=50},
  get_inventory=function() return silo_cargo end,launch_rocket=function(d) launched=d; return true end}
local p={index=1,force={platforms={platform},recipes={}},character={get_logistic_sections=function() return char_sections end},
  surface={planet={name='nauvis'},find_entities_filtered=function() return {silo} end}}
local space=dofile('mod/agent-harness_0.1.0/space.lua'){
  position=function(v) return v end,
  integer=function(v,d,lo,hi,name) v=v==nil and d or v; assert(type(v)=='number' and v>=lo and v<=hi,name..' out of range'); return v end,
  remote_entity=function(_,a) assert(a.position.x==20.5,'no entity of ours at that position'); return silo end,
  real=function(q) return q end,stop=function(q) q.stopped=(q.stopped or 0)+1 end}
-- Character requests: a manual section is created, slots are reused per item.
local r=space.requests(p,{set={{item='iron-plate',min=100},{item='coal',min=5,max=10}}})
eq(r.target,'character'); eq(r.sections[1].requests[1],'iron-plate 100..inf'); eq(r.sections[1].requests[2],'coal 5..10')
r=space.requests(p,{set={{item='iron-plate',min=50,max=50}}})
eq(#r.sections[1].requests,2); eq(r.sections[1].requests[1],'iron-plate=50')
r=space.requests(p,{clear={'iron-plate'}})
eq(#r.sections[1].requests,1); eq(r.sections[1].requests[1],'coal 5..10')
r=space.requests(p,{set={{item='iron-plate',min=1}}}) -- the freed slot is reused
eq(r.sections[1].requests[1],'iron-plate 1..inf')
eq(#space.requests(p,{clear_all=true}).sections[1].requests,0)
fails(function() space.requests(p,{set={{item='nope',min=1}}}) end,'unknown item: nope')
fails(function() space.requests(p,{set={{item='coal',min=5,max=2}}}) end,'max must be at least min')
-- Platform hub requests skip the game-controlled section and name the planet.
r=space.requests(p,{platform='alpha',set={{item='iron-plate',min=100,from='nauvis'}}})
eq(r.target,'platform alpha'); eq(r.sections[2].requests[1],'iron-plate 100..inf from nauvis'); eq(r.sections[1].controlled,true)
fails(function() space.requests(p,{platform='beta'}) end,'no platform named beta; platforms: alpha')
fails(function() space.requests(p,{section=1,platform='alpha',set={{item='coal',min=1}}}) end,'controlled by the game')
-- A requester chest: its requests and its "request from buffer chests" switch.
do
  local chest_sections=sections({})
  local requester={valid=true,name='requester-chest',type='logistic-container',position={x=3.5,y=3.5},request_from_buffers=false,
    get_logistic_sections=function() return chest_sections end}
  local space2=dofile('mod/agent-harness_0.1.0/space.lua'){
    position=function(v) return v end,
    integer=function(v,d,lo,hi,name) v=v==nil and d or v; assert(type(v)=='number' and v>=lo and v<=hi,name..' out of range'); return v end,
    remote_entity=function() return requester end,real=function(q) return q end,stop=function() end}
  local rq=space2.requests(p,{position={x=3.5,y=3.5},set={{item='iron-plate',min=200}},from_buffers=true})
  eq(rq.target,'requester-chest at (3.5,3.5)'); eq(rq.sections[1].requests[1],'iron-plate 200..inf')
  eq(requester.request_from_buffers,true); eq(rq.from_buffers,true)
  eq(space2.requests(p,{position={x=3.5,y=3.5}}).from_buffers,true) -- a read reports it
  fails(function() space2.requests(p,{position={x=3.5,y=3.5},from_buffers='yes'}) end,'from_buffers must be boolean')
  fails(function() space.requests(p,{platform='alpha',from_buffers=true}) end,'from_buffers is a requester chest setting')
end
-- Platform view and schedule.
local view=space.platforms(p,{})
eq(view.platforms[1].state,'paused'); eq(view.platforms[1].at,'nauvis'); eq(view.platforms[1].hub_items,'iron-plate*5')
eq(view.platforms[1].requests[1],'iron-plate 100..inf from nauvis'); eq(view.silos[1].parts,'10/50'); eq(view.silos[1].status,'building_rocket')
eq(view.platforms[1].speed,nil,'details only for one named platform')
-- One platform in full: speed, damage, chunks, thruster tanks, unbuilt ghosts.
platform.speed=0.0123; platform.damaged_tiles={{position={x=1,y=1},damage=5}}
platform.find_asteroid_chunks_filtered=function() return {{name='metallic-asteroid-chunk'},{name='metallic-asteroid-chunk'},{name='oxide-asteroid-chunk'}} end
local tank=function(fuel,ox) return setmetatable({get_capacity=function() return 1000 end},{__index=function(_,i) return ({{amount=fuel},{amount=ox}})[i] end}) end
platform.surface.find_entities_filtered=function(f) if f.type=='thruster' then return {{fluidbox=tank(800,500)},{fluidbox=tank(1000,900)}} end return {} end
platform.surface.count_entities_filtered=function() return 7 end
local one=space.platforms(p,{platform='alpha'}).platforms[1]
eq(one.speed,0.012); eq(one.damaged_tiles,1); eq(one.asteroid_chunks,'metallic-asteroid-chunk*2 oxide-asteroid-chunk*1')
eq(one.thrusters,'2, lowest tank 50%'); eq(one.unbuilt_ghosts,7)
platform.find_asteroid_chunks_filtered=function() error('no chunks API') end
eq(space.platforms(p,{platform='alpha'}).platforms[1].asteroid_chunks,nil,'a failing read is skipped')
-- Where hub items go (request #4): an inserter taking from the hub with
-- nothing to drop into, items thrown overboard, the game's item statistics for
-- the platform surface, and the hub's trash slots.
do
  local find,saved_force=platform.surface.find_entities_filtered,platform.force
  local drain={position={x=-2.5,y=3.5},pickup_target=platform.hub,drop_position={x=-2.5,y=4.7}}
  local fed={position={x=1.5,y=3.5},pickup_target=platform.hub,drop_target={name='crusher'},drop_position={x=1.5,y=4.7}}
  platform.surface.find_entities_filtered=function(f) if f.type=='inserter' then return {drain,fed} end return find(f) end
  platform.surface.get_tile=function(x,y) return {name=y==4 and x==-3 and 'empty-space' or 'space-platform-foundation'} end
  defines.flow_precision_index={ten_minutes=1}; defines.inventory.hub_trash=5
  platform.force={get_item_production_statistics=function(s)
    assert(s==platform.surface)
    return {output_counts={['firearm-magazine']=50,coal=1},input_counts={['solar-panel']=4},
      get_flow_count=function(f) assert(f.precision_index==1 and f.count==true); return ({['firearm-magazine']=20,['solar-panel']=4})[f.name] or 0 end}
  end}
  platform.ejected_items={{item={name='firearm-magazine',quality='normal'}},{item={name='firearm-magazine',quality='normal'}},{item={name='solar-panel',quality='normal'}}}
  local row=space.platforms(p,{platform='alpha'}).platforms[1]
  eq(#row.hub_inserters_without_target,1); eq(row.hub_inserters_without_target[1],'(-2.5,3.5) drops onto empty-space')
  eq(row.consumed_10min,'firearm-magazine*20'); eq(row.produced_10min,'solar-panel*4')
  eq(row.thrown_overboard,'firearm-magazine*2 solar-panel*1')
  eq(row.hub_trash,'iron-plate*5')
  local all=space.platforms(p,{}).platforms[1]
  eq(all.thrown_overboard,nil,'details only for one named platform'); eq(all.hub_trash,'iron-plate*5','every row')
  platform.surface.find_entities_filtered,platform.force,platform.ejected_items=find,saved_force,nil
  defines.flow_precision_index,defines.inventory.hub_trash=nil,nil
end
local sch=space.platform_schedule(p,{platform='alpha',stops={{station='vulcanus',wait={{type='time',ticks=600}}},{station='nauvis',wait={{type='all_requests_satisfied'}}}},paused=false})
eq(sch.schedule,'>vulcanus (time 10s) | nauvis (all_requests_satisfied)'); eq(platform.paused,false)
eq(platform.schedule.records[1].wait_conditions[1].ticks,600)
fails(function() space.platform_schedule(p,{platform='alpha',stops={{station='moon'}}}) end,'station must be a planet')
-- Launch: only a ready rocket, to a platform in orbit here or explicitly to orbit.
fails(function() space.launch(p,{position={x=20.5,y=20.5},platform='alpha'}) end,'rocket is not ready: building_rocket')
silo.rocket_silo_status=9
fails(function() space.launch(p,{position={x=20.5,y=20.5}}) end,'orbit=true')
local l=space.launch(p,{position={x=20.5,y=20.5},platform='alpha'})
-- Cargo goes to the hub as a station (a surface destination on a platform
-- makes the game refuse: shift04 07:17, Peregrine paused in orbit).
eq(l.to,'platform alpha'); eq(launched.type,2); eq(launched.station,platform.hub); eq(launched.surface,nil); eq(l.cargo,'empty')
-- A new platform waiting for its starter pack: the space_platform destination.
platform.state=0
space.launch(p,{position={x=20.5,y=20.5},platform='alpha'})
eq(launched.type,4); eq(launched.space_platform,platform)
platform.state=7
-- Over the rocket's lift (shift04 07:17: Sol's 1060 kg): refused before the
-- game is asked, naming the excess and the heaviest cargo.
do
  local launch,saved=silo.launch_rocket,silo_cargo
  local asked=0
  silo.launch_rocket=function() asked=asked+1; return false end
  local weights={['space-platform-foundation']=20000,['firearm-magazine']=10000,['gun-turret']=20000,['fast-inserter']=20000,['solar-panel']=20000,stone=50000}
  for name,w in pairs(weights) do prototypes.item[name]={weight=w} end
  prototypes.utility_constants={rocket_lift_weight=1000000}
  silo_cargo={get_contents=function() return {{name='solar-panel',count=1},{name='gun-turret',count=4},{name='space-platform-foundation',count=30},
    {name='fast-inserter',count=4},{name='firearm-magazine',count=28}} end}
  eq(space.platforms(p,{}).silos[1].weight,'1060/1000 kg')
  fails(function() space.launch(p,{position={x=20.5,y=20.5},platform='alpha'}) end,
    'launch refused, overweight by 60 kg: the rocket holds 1060 kg and lifts 1000 kg; take cargo out with transfer {position, direction=to_player, inventory=rocket_silo_rocket, item, count} (cargo: space-platform-foundation*30 at 20 kg, firearm-magazine*28 at 10 kg, fast-inserter*4 at 20 kg, gun-turret*4 at 20 kg, solar-panel*1 at 20 kg)')
  eq(asked,0)
  -- The game says no (launch_rocket false) for its own reasons: the error names what may stop it.
  silo_cargo={get_contents=function() return {{name='stone',count=20}} end}
  fails(function() space.launch(p,{position={x=20.5,y=20.5},platform='alpha'}) end,
    'the game refused the launch (launch_rocket returned false): the silo holds no rocket entity; platform alpha is paused (platform_schedule paused=false unpauses it) [silo rocket_ready/nil, cargo 1000/1000 kg, platform alpha paused at nauvis, destination station]')
  silo.rocket={valid=true}; platform.state=6
  fails(function() space.launch(p,{position={x=20.5,y=20.5},platform='alpha'}) end,
    'the game refused the launch (launch_rocket returned false) [silo rocket_ready/nil, cargo 1000/1000 kg, platform alpha waiting_at_station at nauvis, destination station]')
  eq(asked,2)
  silo.launch_rocket,silo_cargo,silo.rocket,platform.state=launch,saved,nil,7
  for name in pairs(weights) do prototypes.item[name]=nil end
  prototypes.utility_constants=nil
end
platform.space_location={name='vulcanus'}
fails(function() space.launch(p,{position={x=20.5,y=20.5},platform='alpha'}) end,'not in orbit of nauvis')
eq(space.launch(p,{position={x=20.5,y=20.5},auto_requests=true}).auto_requests,true)
-- Switching automatic requests on with cargo loaded by hand: the game moves it
-- to the silo's trash slots; the reply names it and how to take it back.
do
  defines.inventory.rocket_silo_trash=3
  local trash={get_contents=function() return {} end}
  local get_inv,saved=silo.get_inventory,silo_cargo
  silo.get_inventory=function(i) if i==3 then return trash end return silo_cargo end
  silo.use_transitional_requests=false
  silo_cargo={get_contents=function() return {{name='space-platform-foundation',count=40},{name='solar-panel',count=7}} end}
  local sw=space.launch(p,{position={x=20.5,y=20.5},auto_requests=true})
  eq(sw.auto_requests,true); eq(sw.cargo_to_trash,'space-platform-foundation*40 solar-panel*7'); eq(sw.trash,nil)
  assert(sw.note:find('moves that cargo out of the rocket into the silo\'s trash slots',1,true),sw.note)
  assert(sw.note:find('transfer {position, direction=to_player, inventory=rocket_silo_trash}',1,true),sw.note)
  -- Already on, or switching off: no note.
  eq(space.launch(p,{position={x=20.5,y=20.5},auto_requests=true}).note,nil)
  eq(space.launch(p,{position={x=20.5,y=20.5},auto_requests=false}).note,nil)
  -- The game moved it: the reply and the platforms read list the trash.
  silo_cargo=saved
  trash={get_contents=function() return {{name='space-platform-foundation',count=40},{name='inserter',count=1}} end}
  eq(space.launch(p,{position={x=20.5,y=20.5},auto_requests=true}).trash,'space-platform-foundation*40 inserter*1')
  eq(space.platforms(p,{}).silos[1].trash,'space-platform-foundation*40 inserter*1')
  silo.get_inventory,silo.use_transitional_requests,defines.inventory.rocket_silo_trash=get_inv,nil,nil
end
-- Riding needs the silo in reach and a platform; the character goes along.
platform.space_location={name='nauvis'}
p.can_reach_entity=function() return false end
fails(function() space.launch(p,{position={x=20.5,y=20.5},platform='alpha',ride=true}) end,'within reach of the silo')
p.can_reach_entity=function() return true end
fails(function() space.launch(p,{position={x=20.5,y=20.5},ride=true}) end,'ride needs platform')
-- Riding as the silo GUI allows: no other payload, nothing carried but armor and guns.
defines.inventory.character_main=10; defines.inventory.character_ammo=11
local carried={[10]=false,[11]=false}
p.character.get_inventory=function(i) return {is_empty=function() return not carried[i] end} end
carried[11]=true
fails(function() space.launch(p,{position={x=20.5,y=20.5},platform='alpha',ride=true}) end,'put down everything in character_ammo')
carried[11]=false
local saved_cargo=silo_cargo
silo_cargo={get_contents=function() return {{name='coal',count=5}} end}
fails(function() space.launch(p,{position={x=20.5,y=20.5},platform='alpha',ride=true}) end,'only payload')
silo_cargo=saved_cargo
local rode=space.launch(p,{position={x=20.5,y=20.5},platform='alpha',ride=true})
assert(rode.riding); eq(p.stopped,1)
-- A bot (no LuaPlayer behind it) rides through bots.lua: the same checks
-- first, then the rocket flies with no character and the bot boards its pod.
local bot=setmetatable({__bot='astra'},{__index=p})
local real_of=function(q) if rawget(q,'__bot') then return nil end return q end
local boarded,landed,checked
local record={name='astra'}
local bot_space=dofile('mod/agent-harness_0.1.0/space.lua'){position=function(v) return v end,integer=function(v) return v end,
  remote_entity=function() return silo end,real=real_of,stop=function(q) q.stopped=(q.stopped or 0)+1 end,
  bot=function(q) return rawget(q,'__bot') and record or nil end,
  bots={can_board=function(b) checked=b end,board=function(b,pl,pod) boarded={b=b,pl=pl,pod=pod} end,
    land=function(b) landed=b; return {landing='nauvis',at={x=1,y=2}} end}}
silo.rocket={valid=true,attached_cargo_pod={valid=true,name='cargo-pod'}}
carried[10]=true
fails(function() bot_space.launch(bot,{position={x=20.5,y=20.5},platform='alpha',ride=true}) end,'put down everything in character_main')
eq(boarded,nil,'nothing moves when the rule fails')
carried[10]=false
launched=nil
local br=bot_space.launch(bot,{position={x=20.5,y=20.5},platform='alpha',ride=true})
eq(checked,record); eq(boarded.b,record); eq(boarded.pl,platform); eq(boarded.pod,silo.rocket.attached_cargo_pod)
eq(launched.station,platform.hub,'the rocket flies to the platform'); assert(br.riding:find('aboard alpha',1,true))
eq(p.stopped,1,'boarding stops the bot in bots.lua, not here')
eq(bot_space.land(bot,{}).landing,'nauvis'); eq(landed,record)
-- Landing: only from our platform stopped at a planet.
fails(function() space.land(p,{}) end,'not on a space platform')
p.surface.platform=platform; platform.force=p.force
platform.space_location={name='nauvis',type='planet'}
p.land_on_planet=function() return true end
eq(space.land(p,{}).landing,'nauvis'); eq(p.stopped,2)
platform.space_location=nil; platform.space_connection={from={name='nauvis'},to={name='vulcanus'}}; platform.distance=0.25
fails(function() space.land(p,{}) end,'not stopped at a planet (at nauvis->vulcanus 25%)')
p.surface.platform=nil
-- Drop: hub items go down in a cargo pod to the planet below a stopped platform.
-- The hub's own stacks move (freshness kept); repeated entries add up.
defines.inventory.cargo_unit=30
local function stack(name,count,spoil)
  local st={valid_for_read=count>0,name=name,count=count,quality={name='normal'},spoil_percent=spoil or 0}
  st.clear=function() st.valid_for_read=false; st.count=0 end
  st.transfer_stack=function(o) st.name,st.count,st.quality,st.spoil_percent,st.valid_for_read=o.name,o.count,o.quality,o.spoil_percent,true; o.clear(); return true end
  return st
end
local function slots(list,n) local inv={}; for i=1,n do inv[i]=list[i] or stack(nil,0) end; return inv end
local hub_slots=slots({stack('iron-plate',3,0.25),stack('coal',5),stack('iron-plate',4,0.5)},4)
for i=1,#hub_slots do hub_inv[i]=hub_slots[i] end
hub_inv.get_item_count=function(q) local n=0; for i=1,#hub_slots do local st=hub_slots[i]; if st.valid_for_read and st.name==q.name then n=n+st.count end end; return n end
hub_inv.insert=function(st) for i=1,#hub_slots do if not hub_slots[i].valid_for_read then hub_slots[i].transfer_stack(st); return hub_slots[i].count end end; return 0 end
local vulcanus_surface={name='vulcanus',pads={}}
vulcanus_surface.find_entities_filtered=function() return vulcanus_surface.pads end
game={planets={vulcanus={surface=vulcanus_surface}}}
p.force.get_spawn_position=function() return {x=0,y=0} end
local drop_pod,inserted
local refuse=false
platform.hub.create_cargo_pod=function()
  local cargo=slots({},2)
  cargo.find_empty_stack=function() for i=1,#cargo do if not cargo[i].valid_for_read then return cargo[i],i end end end
  cargo.insert=function(def) inserted=def; local st=cargo.find_empty_stack(); if not st then return 0 end
    st.name,st.count,st.spoil_percent,st.valid_for_read=def.name,def.count,def.spoil_percent or 0,true; return def.count end
  cargo.is_empty=function() for i=1,#cargo do if cargo[i].valid_for_read then return false end end return true end
  local pod={valid=true,cargo=cargo}
  drop_pod=setmetatable({},{__index=pod,__newindex=function(_,k,v) if k=='cargo_pod_destination' and refuse then error('refused') end pod[k]=v end})
  pod.get_inventory=function(i) eq(i,30); return cargo end
  pod.destroy=function() pod.valid=false end
  return drop_pod
end
platform.space_location={name='vulcanus',type='planet'}
fails(function() space.drop(p,{platform='alpha',items={{item='iron-plate',count=5},{item='iron-plate',count=5}}}) end,'holds 7 iron-plate, not 10')
local d=space.drop(p,{platform='alpha',items={{item='iron-plate',count=3},{item='iron-plate',count=2}}})
eq(d.dropped[1],'iron-plate*5'); eq(#d.dropped,1,'repeated entries add up')
eq(drop_pod.cargo[1].count,3); eq(drop_pod.cargo[1].spoil_percent,0.25,'a whole stack moves as is')
eq(drop_pod.cargo[2].count,2); eq(inserted.spoil_percent,0.5,'part of a stack keeps its freshness')
eq(hub_inv.get_item_count{name='iron-plate'},2,'only what left the hub was sent')
eq(drop_pod.cargo_pod_destination.surface,vulcanus_surface); eq(drop_pod.cargo_pod_destination.position.x,0); eq(d.to,'vulcanus')
-- Two items in one drop, each from its own hub stack.
d=space.drop(p,{platform='alpha',items={{item='coal',count=5},{item='iron-plate',count=2}}})
eq(d.dropped[1],'coal*5'); eq(d.dropped[2],'iron-plate*2'); eq(d.not_sent,nil)
hub_inv.insert(stack('coal',4)); hub_inv.insert(stack('iron-plate',1))
d=space.drop(p,{platform='alpha',items={{item='coal',count=2},{item='iron-plate',count=1}}})
eq(d.not_sent,nil)
hub_inv.insert(stack('coal',3))
vulcanus_surface.pads={{position={x=9,y=9}}}
d=space.drop(p,{platform='alpha',items={{item='coal',count=1}},position={x=4,y=4}})
eq(d.pad.x,9); eq(drop_pod.cargo_pod_destination.position,nil,'a pad takes it')
-- A refused destination puts the items back.
local coal_before=hub_inv.get_item_count{name='coal'}
refuse=true
fails(function() space.drop(p,{platform='alpha',items={{item='coal',count=2}}}) end,'items stay in the hub')
eq(hub_inv.get_item_count{name='coal'},coal_before); eq(drop_pod.valid,false)
-- The hub cannot take them back (filled meanwhile): they stay in the pod, which is kept.
local insert=hub_inv.insert
hub_inv.insert=function() return 0 end
fails(function() space.drop(p,{platform='alpha',items={{item='coal',count=2}}}) end,'the hub took back all but coal*1 coal*1, which stay in the cargo pod on the hub')
eq(drop_pod.valid,true); eq(drop_pod.cargo[1].count+drop_pod.cargo[2].count,2)
hub_inv.insert=insert
refuse=false
platform.space_location=nil
fails(function() space.drop(p,{platform='alpha',items={{item='coal',count=1}}}) end,'not stopped at a planet')
-- Creating a platform goes through the force like the platform GUI.
p.force.create_space_platform=function(args) return {name=args.name,state=0,planet=args.planet} end
local made=space.platform_create(p,{name='beta'})
eq(made.state,'waiting_for_starter_pack'); eq(made.planet,'nauvis')
p.force.recipes['space-platform-starter-pack']={enabled=false}
fails(function() space.platform_create(p,{}) end,'not unlocked yet')
print('space: ok')
