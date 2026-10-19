-- d18 batch36. Run from the harness root: lua tests/d18_batch36.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end

-- A1 (Luna and Grok, all of shift35: Gleba's science requester lacked 10 nutrients for about 36 minutes, "all 250
-- logistic bots occupied"): logistics_audit {backlog}: the oldest unfilled requests and what holds each now.
do
  game={tick=2000000}
  defines={inventory={chest=1,robot_cargo=2},robot_order_type={deliver=1,pickup=2}}
  local function chest(id,x,y,item,want,have,coming)
    local e={valid=true,name='requester-chest',type='logistic-container',unit_number=id,position={x=x,y=y},
      get_item_count=function() return have end,get_inventory=function() return {count_empty_stacks=function() return 10 end,get_contents=function() return have>0 and {{name=item,count=have}} or {} end,can_insert=function() return true end} end}
    return {owner=e,filters={{name=item,quality='normal',count=want}},targeted_items_deliver=coming or {}}
  end
  local provider={valid=true,name='passive-provider-chest',position={x=24.5,y=28.5},get_item_count=function() return 98 end}
  local pick={owner=provider,targeted_items_pickup={{name='nutrients',quality='normal',count=0}}}
  local function robot(cargo,orders)
    return {robot_order_queue=orders or {},get_inventory=function() return {[1]=cargo and {valid_for_read=true,name=cargo[1],count=cargo[2]} or {valid_for_read=false}} end}
  end
  local robots={}
  for i=1,3 do robots[#robots+1]=robot({'firearm-magazine',4}) end
  robots[#robots+1]=robot({'ice',10},{{type=1}})
  robots[#robots+1]=robot(nil,{{type=2}})
  local cellowner={valid=true,name='roboport',prototype={logistic_parameters={charging_station_count=4}}}
  local supply={nutrients=98,['advanced-circuit']=0}
  local ln={network_id=98,all_logistic_robots=5,available_logistic_robots=0,logistic_robots=robots,
    cells={{owner=cellowner,charging_robot_count=1,to_charge_robot_count=2},{owner=cellowner,charging_robot_count=0,to_charge_robot_count=0}},
    requester_points={chest(1,15.5,28.5,'nutrients',10,0),chest(2,20.5,59.5,'advanced-circuit',8,0),chest(3,8.5,40.5,'nutrients',5,5)},
    get_supply_counts=function(q) local n=supply[type(q)=='table' and q.name or q] or 0; return {['passive-provider']=n} end,
    select_pickup_point=function(t) if supply[t.name.name]>0 then return pick end end}
  -- the networks watch first saw the science chest short 36 minutes ago, the circuits 8 hours ago
  local st={networks={unfilled={['1|nutrients|normal']=2000000-36*3600,['2|advanced-circuit|normal']=2000000-480*3600}}}
  local L=dofile('mod/agent-harness_0.1.0/logaudit.lua'){state=function() return st end}
  local r=L.backlog({},{},{name='gleba'},ln)
  eq(r.requests_short,2); eq(r.robots.idle,0); eq(r.robots.cargo_no_order,3); eq(r.robots.charging_slots,8); eq(r.robots.free_charging_slots,7)
  eq(r.robots_line,'5 logistic robots: 0 idle, on orders deliver 1, pickup 1 (carrying ice 10), 3 holding cargo with no order (firearm-magazine 12); 1 charging, 2 queued to charge at its roboports, 8 charging slots (7 free)')
  -- oldest first: the circuits, none in the network
  eq(r.requests[1].item,'advanced-circuit'); eq(r.requests[1].held_by,'none of it in the network\'s providers or storage')
  local sci=r.requests[2]
  eq(sci.item,'nutrients'); eq(sci.short_s,36*60); eq(sci.provider.holds,98); eq(sci.provider.distance,9)
  eq(sci.held_by,'no idle logistic robot of 5: 3 hold cargo with no order to put it anywhere (firearm-magazine 12; logistics_audit {storage: true} reads where it could go); on orders deliver 1, pickup 1 (carrying ice 10); 2 queued to charge')
  eq(r.lines[2],'requester-chest (15.5,28.5): nutrients 10 short (has 0 of 10) for 36m00s; the provider the game picks: passive-provider-chest (24.5,28.5), 9 tiles, holds 98 (0 reserved); held by: '..sci.held_by)
  -- every unit at the provider reserved
  pick.targeted_items_pickup={{name='nutrients',quality='normal',count=98}}
  eq(L.backlog({},{},{name='gleba'},ln).requests[2].held_by,'the provider the game picks holds 98, all reserved by robots on the way')
  -- idle robots and an unreserved provider: not sent yet
  pick.targeted_items_pickup={}; ln.available_logistic_robots=2
  has(L.backlog({},{},{name='gleba'},ln).requests[2].held_by,'2 idle robots and 98 unreserved at the provider: not sent yet')
  -- a charging queue with every slot taken
  ln.cells[1].charging_robot_count=4; ln.cells[2].charging_robot_count=4
  eq(L.backlog({},{},{name='gleba'},ln).requests[2].held_by,'robots queued to charge: 2 waiting, every one of 8 charging slots taken')
  -- through read
  fails(function() L.read({force={logistic_networks={gleba={ln}}},surface={name='gleba'}},{network=98,backlog='yes'}) end,'backlog is true')
  defines,game=nil,nil
end
print('d18_batch36 A1 logistics_audit backlog: ok')

-- A2 (viewer Aurora 15:36: Swiftlet waited at a stop for carbon fiber while the silo there lacked processing units that
-- Swiftlet's hub held): a silo at the stop that lacks a rocket-part ingredient the waiting platform's hub holds.
do
  defines={inventory={assembling_machine_input=2}}
  local input={['processing-unit']=0,['low-density-structure']=40,['rocket-fuel']=12}
  local silo={valid=true,name='rocket-silo',position={x=5.5,y=10.5},rocket_parts=12,prototype={rocket_parts_required=50},
    get_recipe=function() return {ingredients={{type='item',name='processing-unit',amount=10},{type='item',name='low-density-structure',amount=10},{type='item',name='rocket-fuel',amount=10}}} end,
    get_inventory=function() return {get_item_count=function(n) return input[n] or 0 end} end}
  local hubitems={['processing-unit']=400,['carbon-fiber']=3}
  local pl={name='Swiftlet',force={},space_location={name='fulgora'},hub={valid=true,get_item_count=function(n) return hubitems[n] or 0 end},
    schedule={current=1,records={{station='fulgora',wait_conditions={{type='item_count'},{type='time',compare_type='or'}}}}}}
  local fulgora={index=4}
  game={planets={fulgora={surface=fulgora}}}
  local N=dofile('mod/agent-harness_0.1.0/launchneed.lua'){crafters=function(f,s) assert(s==fulgora); return {{valid=true,type='assembling-machine'},silo} end}
  silo.type='rocket-silo'
  local lines=N.for_platform(pl)
  eq(#lines,1)
  eq(lines[1],'Swiftlet holds 400 processing-unit; rocket-silo (5.5,10.5) on fulgora: its rocket parts lack it (holds 0, 10 a part; parts 12/50)')
  -- the silo holds enough for a part: nothing
  input['processing-unit']=10; eq(N.for_platform(pl),nil)
  -- a stop waiting on time alone: nothing read
  input['processing-unit']=0; pl.schedule.records[1].wait_conditions={{type='time'}}; eq(N.for_platform(pl),nil)
  -- flying to the stop: its station is the planet
  pl.schedule.records[1].wait_conditions={{type='all_requests_satisfied'}}; pl.space_location=nil
  eq(#N.for_platform(pl),1)
  -- the hub holds none of what it lacks: nothing
  hubitems['processing-unit']=nil; eq(N.for_platform(pl),nil)
  defines,game=nil,nil
end
print('d18_batch36 A2 a silo its own cargo would feed: ok')

-- A3 (Luna 15:58: an item-count OR time wait written without compare: "or" ran as and; viewer Aurora 16:09: Spindle's
-- waits needed repeated fixes): mixed kinds with no compare refused; any_of / all_of as the game's chain; the readback
-- grouped as the game evaluates it, naming a branch that leaves with no fuel condition another branch has.
do
  local WG=dofile('mod/agent-harness_0.1.0/waitgroups.lua')()
  fails(function() WG.mixed({{type='item_count'},{type='time',ticks=60}},'stop 1') end,
    'stop 1: its waits mix item_count and time with no compare on wait 2; the game joins a wait with no compare by and (the default), so every one must hold')
  WG.mixed({{type='item_count'},{type='item_count'}},'stop 1')  -- one kind: the default and, as before
  WG.mixed({{type='item_count'},{type='time',compare='or'}},'stop 1')
  local list,grouped=WG.flatten({any_of={{all_of={{type='item_count',condition='thruster-fuel >= 1000'},{type='item_count',condition='thruster-oxidizer >= 1000'}}},{type='time',ticks=18000}}},'stop 1')
  eq(grouped,true); eq(#list,3); eq(list[1].compare,nil); eq(list[2].compare,'and'); eq(list[3].compare,'or')
  fails(function() WG.flatten({all_of={{any_of={{type='time'}}}}},'stop 1') end,'all_of holds plain waits; the game\'s chain is ors of ands')
  -- the readback: (a and b) or c, and the branch with no fuel or oxidizer condition
  prototypes={item={}}
  local function c(n) return {first_signal={name=n},comparator='≥',constant=1000} end
  local text,notes=WG.text({{type='item_count',condition=c('thruster-fuel')},{type='item_count',condition=c('thruster-oxidizer'),compare_type='and'},{type='time',ticks=18000,compare_type='or'}},
    function(w) return w.type..(w.condition and ' '..w.condition.first_signal.name or '')..(w.ticks and ' '..math.floor(w.ticks/60)..'s' or '') end)
  eq(text,'(item_count thruster-fuel and item_count thruster-oxidizer) or time 300s')
  eq(notes[1],'branch 2, time 300s, departs with no fuel condition'); eq(notes[2],'branch 2, time 300s, departs with no oxidizer condition')
  prototypes=nil
end
do
  -- through platform_schedule (the batch31 B9 fixture)
  defines={space_platform_state={waiting_at_station=4,on_the_path=3,no_schedule=1,paused=7},inventory={hub_main=1,hub_trash=2},
    wire_connector_id={circuit_red=1,circuit_green=2}}
  prototypes={space_location={nauvis={},gleba={}},fluid={['thruster-fuel']={}},item={['firearm-magazine']={}}}
  local hubinv={get_item_count=function() return 700 end}
  local pl={valid=true,name='Spindle',index=3,state=4,space_location={name='nauvis'},force={},paused=false,
    hub={valid=true,get_circuit_network=function() return nil end,get_inventory=function() return hubinv end},
    surface={find_entities_filtered=function() return {} end}}
  local sch={}
  setmetatable(sch,{__index=function(_,k) if k=='current' then return pl.schedule and pl.schedule.current end end})
  sch.get_record_count=function() return #pl.schedule.records end
  sch.go_to_station=function(i) pl.schedule.current=i end
  pl.get_schedule=function() return sch end
  local p={name='luna',force={platforms={pl}}}
  local st={}
  local W=dofile('mod/agent-harness_0.1.0/platwait.lua'){state=function() return st end}
  game={tick=600,forces={player={platforms={pl}}}}
  local function cond(s2)
    local name,cmp,v=s2:match('^(%S+) (%S+) (%d+)$')
    return {first_signal={type=prototypes.fluid[name] and 'fluid' or 'item',name=name},comparator=cmp=='>=' and '≥' or cmp,constant=tonumber(v)}
  end
  local space=dofile('mod/agent-harness_0.1.0/space.lua'){state=function() return st end,platwait=function() return W end,
    circuit_condition=function(x) return type(x)=='string' and cond(x) or x end,
    integer=function(v,d) return v==nil and d or v end,freight={where=function() return {} end,leg=function() return nil end}}
  local ok,err=pcall(space.platform_schedule,p,{platform='Spindle',current=2,stops={{station='nauvis',wait={{type='item_count',condition='firearm-magazine >= 700'},{type='time',ticks=18000}}},{station='gleba'}}})
  assert(not ok); has(err,'stop 1: its waits mix item_count and time with no compare on wait 2')
  local r=space.platform_schedule(p,{platform='Spindle',current=2,stops={{station='nauvis',save_as='nauvis fuel or 5 min',
    wait={any_of={{type='fluid_count',condition='thruster-fuel >= 24000'},{type='time',ticks=18000}}}},{station='gleba'}}})
  local rec=pl.schedule.records[1].wait_conditions
  eq(#rec,2); eq(rec[2].compare_type,'or')
  has(r.schedule,'nauvis (fluid_count thruster-fuel >= 24000 or time 300s) [branch 2, time 300s, departs with no fuel condition]')
  has(table.concat(r.read_as,' | '),'stop 1: any_of written as the game\'s chain of 2 waits')
  has(table.concat(r.read_as,' | '),'stop 1: its waits saved as nauvis fuel or 5 min')
  -- reused by name on another stop
  r=space.platform_schedule(p,{platform='Spindle',current=2,stops={{station='nauvis'},{station='gleba',wait_from='nauvis fuel or 5 min'}}})
  eq(pl.schedule.records[2].wait_conditions[2].compare_type,'or'); has(table.concat(r.read_as,' | '),'stop 2: waits from nauvis fuel or 5 min (saved by luna)')
  ok,err=pcall(space.platform_schedule,p,{platform='Spindle',stops={{station='gleba',wait_from='nope'}}})
  assert(not ok); has(err,'stop 1: no wait list saved as nope (saved: nauvis fuel or 5 min)')
  defines,prototypes,game=nil,nil,nil
end
print('d18_batch36 A3 mixed waits, any_of/all_of, grouped readback: ok')

-- B1 (Haiku: an urgent alert every 15-30 s on Nauvis woke every wait): wake {near: N}: only an attack on ours or a loss
-- within N tiles wakes; other urgent alerts are held for the reply.
do
  game={tick=1000,forces={}}
  local st={damage={},attack_groups={},losses={},chronicle={events={}}}
  local U=dofile('mod/agent-harness_0.1.0/urgent.lua'){state=function() return st end,who=function(p) return p.name end}
  local on,r=U.option({near=40}); eq(on,true); eq(r.near,40)
  fails(function() U.option({near=500}) end,'wake near is 1..200 tiles')
  fails(function() U.option({near=40,radius=3}) end,'wake: {near: N} takes near only')
  local p={index=7,name='haiku',surface={name='nauvis'},character={valid=true,position={x=0,y=0}},force={platforms={}}}
  local base=U.base(p,{near=40})
  eq(base.near_only,40); eq(base.radius,40)
  -- an enemy group heading 20 tiles from you and a teammate's death: held, not woken
  st.attack_groups[1]={tick=1001,seq=1,target={x=20,y=0},position={x=150,y=0},size=12,surface='nauvis'}
  st.chronicle.events[1]={tick=1002,kind='death',agent='luna',surface='nauvis',position={x=10,y=0},id=5}
  game.tick=1010
  eq(U.check(p,base),nil)
  eq(#base.held,2); has(base.held[1],'enemy group of 12'); has(base.held[2],'luna died')
  -- an attack 30 tiles off: wakes
  st.damage['nauvis:0,0']={id=9,at={x=30,y=0},damage=40,hits=2,last=1011,surface='nauvis'}
  game.tick=1020
  has(U.check(p,base),'attack on our structures 30 tiles from you')
  -- one 60 tiles off: not
  local b2=U.base(p,{near=40})
  st.damage['nauvis:0,0']={id=10,at={x=60,y=0},damage=40,hits=2,last=1021,surface='nauvis'}
  game.tick=1030
  eq(U.check(p,b2),nil)
  -- without wake, the group wakes as before
  local b3=U.base(p,nil)
  st.attack_groups[2]={tick=1031,seq=2,target={x=0,y=-25},position={x=0,y=-200},size=12,surface='nauvis'}  -- (another spot: the first was told)
  game.tick=1040
  has(U.check(p,b3),'enemy group of 12')
  game=nil
end
print('d18_batch36 B1 wake near: ok')

-- B2 (Haiku: 8 hits from big spitters at (-112,240) on a rearm tour whose walk started clear): the next leg checked
-- against enemy groups and units seen now; one in reach stops the walk short, named.
do
  local player_force={name='player',players={{}},is_chunk_visible=function() return true end}
  game={tick=100,forces={player=player_force,enemy={name='enemy'}}}
  defines={command={attack=1,go_to_location=2,wander=5}}
  local spitter={valid=true,name='big-spitter',type='unit',position={x=-110,y=238},orientation=0.75,commandable={command={type=5}}}
  local surface={name='nauvis',find_entities_filtered=function(f) if f.type=='unit' then return {spitter} end return {} end}
  local A=dofile('mod/agent-harness_0.1.0/avoid.lua'){state=function() return {} end,charted=function() return true end}
  local p={surface=surface,force=player_force,position={x=-100,y=200}}
  local mode=A.mode(nil)
  local lt=A.leg_threat(p,{x=-100,y=200},{x=-120,y=280},mode)
  has(lt.line,'the leg from (-100,200) to (-120,280) passes 1 enemy unit (1 big-spitter) at (-110,238)')
  has(lt.line,'moving units (big-spitter (-110,238) wandering, facing west)')
  -- a leg 40 tiles off it: nothing
  eq(A.leg_threat(p,{x=-40,y=200},{x=-40,y=280},mode),nil)
  -- avoid_enemies false: no check
  eq(A.leg_threat(p,{x=-100,y=200},{x=-120,y=280},nil),nil)
  game,defines=nil,nil
end
do
  -- a tour: stops short before the leg, names it; unsafe_goal walks on
  game={tick=0}
  local function distance(a,b) return ((a.x-b.x)^2+(a.y-b.y)^2)^0.5 end
  local f={}
  local p={force=f,position={x=0,y=0},reach_distance=10}
  local t1={valid=true,type='ammo-turret',name='gun-turret',force=f,position={x=5,y=0}}
  local t2={valid=true,type='ammo-turret',name='gun-turret',force=f,position={x=60,y=0}}
  local threat,stopped,visits=nil,0,0
  local S=dofile('mod/agent-harness_0.1.0/stock.lua'){distance=distance,integer=function(v,d) return v or d end,
    goal_inside=function() return nil end,goal_check=function() return nil end,goal_text=function() return 'place' end,
    leg_threat=function(_,from,to) if threat and to.x==60 then return {line='the leg from (5,0) to (60,0) passes enemy group of 9'} end end,
    visit=function() visits=visits+1; return {transferred=10} end,can_reach=function() return true end,
    request_path=function(_,nav) nav.requested=true end,navigate=function() return 'arrived' end,stop_walking=function() stopped=stopped+1 end}
  p.can_reach_entity=function(e) return distance(p.position,e.position)<=10 end
  local action=S.start_tour(p,'rearm',{t1,t2},3600,{avoid_mode={}})
  threat=true
  local r
  for _=1,20 do game.tick=game.tick+1; r=S.tick(p,action); if r then break end end
  eq(r,'enemies_ahead'); eq(stopped,1)
  has(action.enemies_ahead,'the leg from (5,0) to (60,0) passes enemy group of 9; stopped at (0.0,0.0) before it, 1 of 2 stops done')
  action=S.start_tour(p,'rearm',{t2},3600,{avoid_mode={},unsafe_goal='moving'})
  for _=1,3 do game.tick=game.tick+1; r=S.tick(p,action); if r then break end end
  assert(r~='enemies_ahead','unsafe_goal walks on')
  game=nil
end
print('d18_batch36 B2 legs checked against enemies seen now: ok')
