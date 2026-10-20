-- Run from repository root: lua tests/d20_batch52.lua
-- d20 batch52 K1-K3 (Astra #1352, Sol #882 and #1323).
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,part) assert(type(s)=='string' and s:find(part,1,true),tostring(s)..' lacks '..part) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end

-- K1 (Astra #1352: "queue_submit platform:Bastion wait_until ammo_below platform/area/count1 rejected remote lane
-- whitelist"): ammo_below on a platform's guns, all of them, at positions or in an area, saw naming the lowest turret;
-- the remote lanes take it as a wait and as a guard's when.
-- K2 (Sol #882: rocket_ready surface=nauvis from Aquilo read the character's surface): rocket_ready and rocket_parts
-- read the silo on the surface named, in a chunk our force has charted.
do
  defines={inventory={turret_ammo=7},rocket_silo_status={building_rocket=1,rocket_ready=9}}
  prototypes={item={['firearm-magazine']={}},quality={normal={}}}
  local function gun(x,y,n)
    local e={valid=true,name='gun-turret',type='ammo-turret',position={x=x,y=y}}
    e.get_inventory=function() return {get_item_count=function() return n end,get_contents=function() return n>0 and {{name='firearm-magazine',count=n}} or {} end} end
    return e
  end
  local guns={gun(-10,-6,40),gun(-2,-11,3),gun(8,4,0)}
  local deck={find_entities_filtered=function(f)
    eq(f.type,'ammo-turret')
    local out={}
    for _,e in ipairs(guns) do
      local ok=true
      if f.area then
        local a,b=f.area[1] or f.area.left_top,f.area[2] or f.area.right_bottom
        local ax,ay,bx,by=a.x or a[1],a.y or a[2],b.x or b[1],b.y or b[2]
        ok=e.position.x>=ax and e.position.x<=bx and e.position.y>=ay and e.position.y<=by
      end
      if ok then out[#out+1]=e end
    end
    return out
  end}
  local bastion={valid=true,name='Bastion',surface=deck}
  local silo={valid=true,name='rocket-silo',position={x=15.5,y=59.5},rocket_parts=37,rocket_silo_status=1,prototype={rocket_parts_required=50}}
  local charted={}
  local nauvis={name='nauvis',find_entities_filtered=function(f) eq(f.type,'rocket-silo'); return {silo} end}
  local aquilo={name='aquilo',find_entities_filtered=function() return {} end}
  game={tick=100,get_surface=function(n) return ({nauvis=nauvis,aquilo=aquilo})[n] end}
  local force={name='player',platforms={bastion},is_chunk_charted=function(s,c) return charted[s.name] end}
  local sol={position={x=0,y=0},surface=aquilo,force=force}
  local C=dofile('mod/agent-harness_0.1.0/conditions.lua'){position=function(v) return v end,known=function() return true end}
  local function check(c) C.validate(c); return C.check(sol,c) end
  local met,saw=check({['until']='ammo_below',platform='Bastion',count=5})
  eq(met,true); eq(saw,'2 turrets below 5 (of 3 on Bastion; lowest gun-turret (8,4): no ammo)')
  met,saw=check({['until']='ammo_below',platform='Bastion',count=5,positions={{x=-10,y=-6}}})
  eq(met,false); eq(saw,'0 turrets below 5 (of 1 on Bastion; lowest gun-turret (-10,-6): 40 firearm-magazine)')
  met,saw=check({['until']='ammo_below',platform='Bastion',count=5,area={left_top={x=-12,y=-12},right_bottom={x=0,y=0}}})
  eq(met,true); eq(saw,'1 turrets below 5 (of 2 on Bastion; lowest gun-turret (-2,-11): 3 firearm-magazine)')
  fails(function() check({['until']='ammo_below',platform='Bastion',count=5,positions={{x=1,y=1}}}) end,'no ammo turret of ours at (1,1) on Bastion')
  fails(function() C.validate({['until']='ammo_below',platform='Bastion',count=5,radius=10}) end,'no position or radius')
  fails(function() C.validate({['until']='ammo_below',count=5,positions={{x=1,y=1}}}) end,'positions applies with platform')
  fails(function() check({['until']='ammo_below',platform='Kestrel',count=5}) end,'no platform of ours named Kestrel')
  -- K2: from Aquilo, the Nauvis silo by surface; uncharted there: refused; without surface: the character's own
  fails(function() check({['until']='rocket_parts',surface='nauvis',position={x=15.5,y=59.5},at_least=30}) end,'(15.5,59.5) on nauvis is not charted')
  charted.nauvis=true
  met,saw=check({['until']='rocket_parts',surface='nauvis',position={x=15.5,y=59.5},at_least=30})
  eq(met,true); has(saw,'rocket parts 37/50 (at least 30)')
  eq(check({['until']='rocket_ready',surface='nauvis',position={x=15.5,y=59.5}}),false)
  fails(function() check({['until']='rocket_ready',position={x=15.5,y=59.5}}) end,'no rocket silo of ours at (15.5,59.5) on aquilo')
  fails(function() C.validate({['until']='rocket_ready',surface='mars',position={x=1,y=1}}) end,'surface must be a surface name')
  -- the remote lanes: ammo_below with platform and the silo waits with surface, as steps and as guards
  local lanes=dofile('mod/agent-harness_0.1.0/queue_lanes.lua')
  local checked
  local function factory(api) checked=api.check_step; return {handlers={},schema={queue_submit={}}} end
  pcall(lanes,{scheduler={handlers={},schema={queue_submit={}}},base={player=function() end,busy=function() end},factory=factory,is_read=function() return false end})
  if checked then
    checked('wait_until',{['until']='ammo_below',platform='Bastion',count=1})
    checked('wait_until',{['until']='rocket_ready',surface='nauvis',position={x=15.5,y=59.5}})
    checked('wait_until',{['until']='all',conditions={{['until']='ammo_below',platform='Bastion',count=1},{['until']='platform_left',platform='Bastion'}}})
    fails(function() checked('wait_until',{['until']='ammo_below',count=1}) end,'ammo_below with platform')
    fails(function() checked('wait_until',{['until']='rocket_ready',position={x=15.5,y=59.5}}) end,'rocket_ready or rocket_parts with surface')
    print('d20_batch52 remote lane checks: ok')
  end
  defines,prototypes,game=nil,nil,nil
end
print('d20_batch52 K1 K2: ok')

-- K3 (Sol #1323: drop 1809, 725 foundation, read "landed" while Aquilo's pad held none before, at and 20 s after;
-- Kestrel IV's hub had died). 2.0.77 on the private copy, a hub killed at each cargo pod state: awaiting_launch,
-- ascending or surface_transition (the pod still on the platform's surface): the pod is gone 5-6 ticks later and the pad
-- gets nothing; descending (0, 1, 3, 10 and 30 ticks in) or parking: the pad gets all of it.
do
  defines={inventory={chest=1,cargo_landing_pad_main=1}}
  storage={}
  local pad_items={['space-platform-foundation']=50}
  local pad_e={valid=true,get_inventory=function() return {get_item_count=function(n) return pad_items[type(n)=='table' and n.name or n] or 0 end,
    get_contents=function() return {} end} end,get_logistic_sections=function() return {sections_count=0} end}
  local aquilo={name='aquilo',find_entities_filtered=function() return {} end}
  game={tick=1000,surfaces={aquilo=aquilo}}
  local D=dofile('mod/agent-harness_0.1.0/drops.lua'){state=function() return storage end,
    integer=function(v,d) return v==nil and d or v end,who=function(p) return p.name end,resolve=function(n) return n end}
  local sol={name='sol'}
  local function step(n) for _=1,n do game.tick=game.tick+1; D.tick(game.tick) end end
  local function drop(hub,pod)
    return D.record(sol,{pod=pod,hub=hub,platform='Kestrel IV',surface='aquilo',pad={x=0,y=0},pad_e=pad_e,sent={'space-platform-foundation*725'},
      items={{name='space-platform-foundation',quality='normal',count=725}}})
  end
  -- 1. the hub dies while the pod still rises on the platform's surface: lost
  local hub,pod={valid=true},{valid=true,surface={name='platform-4'},position={x=0,y=0}}
  local id=drop(hub,pod)
  step(30); hub.valid=false; step(6); pod.valid=false; step(60)
  local r=storage.drops.list[#storage.drops.list]
  eq(r.id,id); eq(r.state,'lost')
  has(r.note,'its platform Kestrel IV\'s hub was destroyed'); has(r.note,'before the pod left the platform\'s surface: it delivered nothing')
  local lines=D.lines(sol,{})
  has(lines[1],'drop #'..id..' from Kestrel IV to aquilo: lost:'); has(lines[1],'it held space-platform-foundation*725')
  eq(D.read(sol,{}).drops[1].state,'lost')
  -- 2. the hub dies once the pod comes down over Aquilo: it lands, and the pad gets it
  hub,pod={valid=true},{valid=true,surface={name='platform-4'},position={x=0,y=0}}
  id=drop(hub,pod)
  step(30); pod.surface={name='aquilo'}; pod.position={x=40,y=-60}; step(30); hub.valid=false; step(300)
  pad_items['space-platform-foundation']=775; pod.valid=false; step(60)
  r=storage.drops.list[#storage.drops.list]
  eq(r.id,id); eq(r.state,'landed'); eq(r.into,'cargo-landing-pad')
  -- 3. a hub that lives: landed as before (the pad's gain or not)
  hub,pod={valid=true},{valid=true,surface={name='aquilo'},position={x=1,y=1}}
  id=drop(hub,pod); step(30); pod.valid=false; step(60)
  eq(storage.drops.list[#storage.drops.list].state,'landed')
  -- 4. a pod_landed wait on a lost drop fails at once with the reason
  local C=dofile('mod/agent-harness_0.1.0/conditions.lua'){position=function(v) return v end,known=function() return true end,
    drop_record=function(n) for _,x in ipairs(storage.drops.list) do if x.id==n then return x end end end}
  local lost_id=storage.drops.list[1].id
  fails(function() C.check({force={platforms={{valid=true,name='Kestrel IV'}}}},{['until']='pod_landed',platform='Kestrel IV',drop_id=lost_id},nil,{}) end,'drop #'..lost_id..' is lost: its platform Kestrel IV\'s hub was destroyed')
  defines,game,storage=nil,nil,nil
end
print('d20_batch52 K3: ok')

-- K4 (Astra #955): the breakup tree; fragments in the forecast; a leg's speed from its distance flown, and a flag when
-- the ship has changed since. K5 (Sol #930): a rocket's damage from its projectile's attack_result; a rate made while no
-- machine aboard makes it now. Fakes as 2.0.77 gives them (the private copy).
do
  local function trigger(child, n) return {{type='create-explosion',entity_name='x'},{type='create-entity',entity_name=child,offsets=(function() local o={} for i=1,n do o[i]={0,0} end return o end)()}} end
  local bullet={category='bullet',action={{action_delivery={{type='instant',target_effects={{type='damage',damage={amount=5,type='physical'}}}}}}}}
  local rocket_ammo={category='rocket',action={{action_delivery={{type='projectile',projectile='rocket'}}}}}
  prototypes={item={['firearm-magazine']={type='ammo',get_ammo_type=function() return bullet end},rocket={type='ammo',get_ammo_type=function() return rocket_ammo end}},
    entity={['huge-metallic-asteroid']={type='asteroid',get_max_health=function() return 20000 end,resistances={physical={decrease=3000,percent=0.1}},dying_trigger_effect=trigger('big-metallic-asteroid',3)},
      ['big-metallic-asteroid']={type='asteroid',get_max_health=function() return 2000 end,resistances={physical={decrease=2000,percent=0.1}},dying_trigger_effect=trigger('medium-metallic-asteroid',3)},
      ['medium-metallic-asteroid']={type='asteroid',get_max_health=function() return 400 end,resistances={physical={decrease=0,percent=0.1}},dying_trigger_effect=trigger('small-metallic-asteroid',3)},
      ['small-metallic-asteroid']={type='asteroid',get_max_health=function() return 100 end,resistances={},dying_trigger_effect={{type='create-asteroid-chunk',asteroid_name='metallic-asteroid-chunk',offsets={{0,0},{0,0}}}}},
      rocket={type='projectile',attack_result={{action_delivery={{target_effects={{type='create-entity',entity_name='explosion'},{type='damage',damage={amount=200,type='explosion'}}}}}}}}},
    space_connection={edge={from={name='aquilo'},to={name='solar-system-edge'},length=100000,asteroid_spawn_definitions={
      {asteroid='big-metallic-asteroid',type='entity',spawn_points={{distance=0,probability=0.002},{distance=1,probability=0.002}}}}},
      ag={from={name='aquilo'},to={name='gleba'},length=30000,asteroid_spawn_definitions={
      {asteroid='medium-metallic-asteroid',type='entity',spawn_points={{distance=0,probability=0.004},{distance=1,probability=0.004}}}}}}}
  game={tick=8*3600}
  local R=dofile('mod/agent-harness_0.1.0/routeammo.lua'){segments=function() return {{kind='leg',from='aquilo',to='gleba',start=60,['end']=3660}} end}
  local t=R.breakup('huge-metallic-asteroid')
  eq(t['huge-metallic-asteroid'],1); eq(t['big-metallic-asteroid'],3); eq(t['medium-metallic-asteroid'],9); eq(t['small-metallic-asteroid'],27)
  local force={get_ammo_damage_modifier=function(c) return c=='rocket' and 2.8 or 0 end,get_turret_attack_modifier=function() return 0 end}
  eq(R.shots('big-metallic-asteroid','firearm-magazine',force),false,'magazines cannot hurt a big one')
  eq(R.shots('medium-metallic-asteroid','firearm-magazine',force),89,'400 / (5 x 0.9)')
  -- K5: 200 explosion x (1 + 2.8) against a big metallic one (explosion resistance none here): 3 rockets
  eq(R.shots('big-metallic-asteroid','rocket',force),3,'the projectile\'s 200 explosion, the force\'s +280%')
  -- the forecast over Aquilo -> edge: big ones only, none met on the legs flown (Aquilo -> Gleba, mediums)
  local surface={find_entities_filtered=function() return {} end}
  local pl={surface=surface,force=force}
  local rows={{name='firearm-magazine',stock=1000,phases={moving={used_per_min=60,made_per_min=0}}}}
  local lines=R.forecast(pl,{{from='aquilo',to='solar-system-edge',km=100000,minutes=20}},rows,{})
  local text=table.concat(lines,'\n')
  has(text,'fragments counted')
  has(text,'big-metallic-asteroid none hurt + 447 for its fragments')  -- 3 medium x 89, 9 small x 20
  has(text,'uncalibrated: 100% of this leg\'s shooting is at kinds the legs flown met none of (big-metallic-asteroid)')
  has(text,'uses about 1800 (60/min on the legs flown x1.50 for these asteroids)')
  game=nil
end
print('d20_batch52 K4 fragments, K5 rocket damage: ok')

do
  -- K4: endurance's speed from the last leg's distance flown (Kestrel II's 1m36 turn back: 600 km, not the whole
  -- connection), and the flag when its thrusters or hull width differ now
  defines={flow_precision_index={ten_minutes=2,five_seconds=0},inventory={hub_main=1,turret_ammo=1,assembling_machine_input=2}}
  prototypes={item={},fluid={},space_location={aquilo={solar_power_in_space=60},['solar-system-edge']={solar_power_in_space=10},fulgora={solar_power_in_space=120}},
    space_connection={a={from={name='aquilo'},to={name='solar-system-edge'},length=100000},b={from={name='aquilo'},to={name='fulgora'},length=30000}}}
  game={tick=100000}
  local hub=setmetatable({get_contents=function() return {} end,count_empty_stacks=function() return 5 end},{__len=function() return 10 end})
  local surface={find_entities_filtered=function() return {} end}
  local force={get_item_production_statistics=function() return {get_flow_count=function() return 0 end} end,get_fluid_production_statistics=function() return {get_flow_count=function() return 0 end} end}
  local pl={name='Kestrel II',surface=surface,force=force,hub={get_inventory=function() return hub end},space_location={name='aquilo'},speed=0,
    schedule={current=1,records={{station='aquilo'},{station='fulgora'}}}}
  -- the last leg: a turn back from the edge to Aquilo, 600 km in 1m36s
  local segs={{kind='leg',from='solar-system-edge',to='aquilo',start=94240,['end']=100000,km0=99400,km1=100000,thrusters=8,width=58}}
  local geo={thrusters=6,width=58}
  local E=dofile('mod/agent-harness_0.1.0/endurance.lua'){platform=function() return pl end,leg=function() return nil end,segments=function() return segs end,geometry=function() return geo end}
  local r=E.read({},{platform='Kestrel II',route={'aquilo','fulgora'}})
  eq(r.speed_km_per_min,375,'600 km over 1m36s, not 100000 km over it (62500)')
  has(r.speed_from,'the last leg solar-system-edge->aquilo: 600 km flown in 1m36s')
  has(r.speed_from,'(measured on another ship: 8 thrusters then, 6 now; times from it are from the old geometry)')
  eq(r.total_minutes,80,'30000 km at 375')
  geo.thrusters=8
  r=E.read({},{platform='Kestrel II',route={'aquilo','fulgora'}})
  assert(not r.speed_from:find('another ship',1,true),r.speed_from)
  -- a leg recorded before the distance was kept, flown whole: the connection's length; one first seen under way: not used
  segs={{kind='leg',from='fulgora',to='aquilo',start=10000,['end']=100000}}
  eq(E.read({},{platform='Kestrel II',route={'aquilo','fulgora'}}).speed_km_per_min,1200,'30000 km over 25 min')
  segs[1].partial=true
  eq(E.read({},{platform='Kestrel II',route={'aquilo','fulgora'}}).speed_km_per_min,nil)
  defines,prototypes,game=nil,nil,nil
end
print('d20_batch52 K4 speed and geometry: ok')

do
  -- K5: a rate measured while no machine aboard makes the item now (Swiftlet's two rocket makers removed): nothing more
  defines={flow_precision_index={ten_minutes=2},inventory={hub_main=1,turret_ammo=1,assembling_machine_input=2}}
  prototypes={item={rocket={type='ammo'}}}
  local pl={surface={find_entities_filtered=function() return {} end},force={},hub={get_inventory=function() return {get_contents=function() return {{name='rocket',count=40}} end} end}}
  local AM=dofile('mod/agent-harness_0.1.0/ammomodel.lua'){}
  local m=AM.new(pl,{places=false,rate=function() return 0 end,fluid_stock=function() return {} end})
  m.make('rocket',6)
  eq(m.made('rocket',6,30),0); eq(m.left('rocket',6,2,10),20)
  local b=m.binds('rocket',6,30); eq(b.kind,'no_maker'); has(b.line,'binds: no machine aboard makes it now (the 6/min was measured before')
  defines,prototypes=nil,nil
end
print('d20_batch52 K5 no maker: ok')

do
  -- K8 (Astra #1277): parts made are finished rockets times the parts a rocket takes plus the one building (2.0.77:
  -- products_finished counts rockets); samples kept before (rockets) are dropped
  storage={}
  game={tick=1000}
  defines={rocket_silo_status={building_rocket=1,rocket_ready=9}}
  local silo={unit_number=7,products_finished=331,rocket_parts=48,prototype={rocket_parts_required=50},status=1,rocket_silo_status=1}
  local S=dofile('mod/agent-harness_0.1.0/silo.lua'){state=function() return storage end}
  storage.silo_made={[7]={{tick=400,n=330}}}
  local made=S.sample_made(silo)
  eq(made.made,331*50+48); eq(#storage.silo_made[7],1,'the rocket-counted sample dropped')
  game.tick=1000+3600; silo.products_finished=332; silo.rocket_parts=8
  made=S.sample_made(silo)
  eq(made.made,332*50+8); eq(made.per_min,10,'a rocket finished and 8 more parts in a minute: 10 parts')
  storage,game,defines=nil,nil,nil
end
print('d20_batch52 K8 parts: ok')

-- K6 (Sol #1145: Wayfarer's bow guns looked fed at departure while their rail loop at (16.5,-18.5) had no source; a
-- circuit set more positive filters than a bulk inserter's 5 slots): what refills each turret's way, wrong ammunition on
-- it, circuit filters past the slots.
do
  defines={inventory={turret_ammo=1,hub_main=2,chest=3},entity_status={disabled_by_control_behavior=99},wire_connector_id={circuit_red=1,circuit_green=2}}
  prototypes={item={['firearm-magazine']={type='ammo',ammo_category='bullet'},rocket={type='ammo',ammo_category='rocket'},['iron-plate']={type='item'}}}
  local n=900
  local function contents(t) local out={} for name,c in pairs(t) do out[#out+1]={name=name,count=c} end return out end
  local function inv(t) return {get_contents=function() return contents(t) end} end
  local function belt(x,y,items)
    n=n+1
    local b={valid=true,unit_number=n,type='transport-belt',name='transport-belt',position={x=x,y=y},belt_neighbours={inputs={}}}
    b.get_max_transport_line_index=function() return 2 end
    b.get_transport_line=function(i) local c=i==1 and contents(items or {}) or {} return setmetatable({get_contents=function() return c end},{__len=function() local t=0 for _,r in ipairs(c) do t=t+r.count end return t end}) end
    return b
  end
  local function ins(x,y,from,to) n=n+1; return {valid=true,unit_number=n,type='inserter',name='bulk-inserter',position={x=x,y=y},pickup_target=from,drop_target=to,filter_slot_count=5} end
  local function turret(x,y)
    n=n+1
    local t={valid=true,unit_number=n,type='ammo-turret',name='gun-turret',position={x=x,y=y},prototype={attack_parameters={ammo_categories={'bullet'}}}}
    t.get_inventory=function() return inv({['firearm-magazine']=5}) end
    return t
  end
  prototypes.item['firearm-magazine'].get_ammo_type=function() return {category='bullet'} end
  prototypes.item.rocket.get_ammo_type=function() return {category='rocket'} end
  local hub={valid=true,unit_number=1,type='space-platform-hub',name='space-platform-hub',position={x=0,y=0}}
  hub.get_inventory=function() return inv({['firearm-magazine']=200}) end
  -- 1. the bow: a rail loop of two belts with 30 magazines and 4 rockets, nothing putting more on
  local bow=turret(16.5,-20)
  local r1,r2=belt(16.5,-18.5,{['firearm-magazine']=30,rocket=4}),belt(17.5,-18.5,{})
  r1.belt_neighbours.inputs={r2}; r2.belt_neighbours.inputs={r1}
  local f1=ins(16.5,-19.5,r1,bow)
  -- 2. a gun fed from a belt an assembler making magazines loads
  local mid=turret(0,-10)
  local m1=belt(0,-8.5,{['firearm-magazine']=6})
  local asm={valid=true,unit_number=50,type='assembling-machine',name='assembling-machine-2',position={x=3.5,y=-8.5},
    get_recipe=function() return {products={{name='firearm-magazine',amount=1}}} end,get_output_inventory=function() return inv({['firearm-magazine']=3}) end}
  local f2,l2=ins(0,-9.5,m1,mid),ins(1.5,-8.5,asm,m1)
  -- 3. a gun fed from the hub
  local aft=turret(0,6)
  local f3=ins(0,5,hub,aft)
  -- 4. a gun whose feeder's circuit sets filters from 7 positive item signals
  local wing=turret(-8,0)
  local w1=belt(-8,1.5,{['firearm-magazine']=2})
  local f4,l4=ins(-8,0.5,w1,wing),ins(-7,1.5,hub,w1)
  f4.get_control_behavior=function() return {circuit_set_filters=true} end
  f4.get_signals=function() local s={} for i=1,7 do s[i]={signal={name='item'..i},count=1} end s[8]={signal={name='signal-A',type='virtual'},count=3} return s end
  local inserters={f1,f2,l2,f3,f4,l4}
  local surface={find_entities_filtered=function(f)
    local t=type(f.type)=='table' and f.type[1] or f.type
    if t=='inserter' then return inserters end
    if t=='ammo-turret' then return {bow,mid,aft,wing} end
    if t=='transport-belt' then return {r1,r2,m1,w1} end
    return {}
  end}
  local F=dofile('mod/agent-harness_0.1.0/ammofeed.lua'){}
  local tr=F.trace({surface=surface,force='player',hub=hub})
  local lines=table.concat(F.lines(tr,true,'Wayfarer',false),'\n')
  has(lines,'replenishment by turret: 1 from an ammunition maker aboard (assembling-machine-2 (3.5,-8.5) making firearm-magazine), 2 from the hub, 0 from chests only (what fills them is not traced), 1 preload only: (16.5,-20) (nothing puts more on their way: what they hold and what is on their way now is all)')
  has(lines,'wrong ammunition on turrets\' ways: gun-turret (16.5,-20): 4 rocket on its way (it takes none of it)')
  has(lines,'circuit filters past the slots: bulk-inserter (-8,0.5): its circuit sets its filters from 7 positive item signals, more than its 5 filter slots (the rest are left out)')
  eq(tr.rows[1].replenished,'preload'); eq(tr.rows[2].replenished,'maker'); eq(tr.rows[3].replenished,'hub'); eq(tr.rows[4].replenished,'hub')
  defines,prototypes=nil,nil
end
print('d20_batch52 K6 replenishment: ok')

-- K9 (Astra #928: Kestrel's tile ghost at (20.5,73.5) read "nothing the foundation rules hold it back by" while it
-- stayed unbuilt): the note judged the platform's first 64 tile ghosts, not the one asked. Now that one and those near it.
do
  local function solid(x,y) return x>=-5 and x<=5 and y>=-5 and y<=5 end
  local ghosts={}
  for i=1,70 do ghosts[i]={-40+i,-40} end          -- 70 ghosts far north, listed first
  ghosts[#ghosts+1]={30,30}                         -- the one asked: no foundation round it
  local s={get_tile=function(x,y) return {name=solid(x,y) and 'space-platform-foundation' or 'empty-space'} end,
    find_entities_filtered=function(f)
      local out={}
      if f.type~='tile-ghost' then return out end
      for _,g in ipairs(ghosts) do
        local x,y=g[1]+0.5,g[2]+0.5
        local a=f.area
        if not a or (x>=a[1][1] and x<=a[2][1] and y>=a[1][2] and y<=a[2][2]) then out[#out+1]={position={x=x,y=y},ghost_name='space-platform-foundation'} end
        if f.limit and #out>=f.limit then break end
      end
      return out
    end}
  local T=dofile('mod/agent-harness_0.1.0/tilecheck.lua')()
  local pl={surface=s,hub={valid=true,position={x=0,y=0}}}
  eq(T.note(pl,{type='tile-ghost',position={x=30.5,y=30.5},ghost_name='space-platform-foundation'}),
    'waits: tile ghost (30.5,30.5) space-platform-foundation: no foundation among the 8 tiles round it')
  ghosts[#ghosts]={5,0}   -- beside the foundation, a ghost the hub builds: nothing holds it, with what was checked
  eq(T.note(pl,{type='tile-ghost',position={x=5.5,y=0.5},ghost_name='space-platform-foundation'}),
    'nothing the foundation rules hold it back by (checked with the 1 tile ghost within 16 tiles of it)')
end
print('d20_batch52 K9 tile_wait: ok')
