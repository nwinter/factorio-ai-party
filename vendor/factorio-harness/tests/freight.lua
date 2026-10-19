-- Run from repository root: lua tests/freight.lua
-- Luna, shift12 12:47: Sunward took 995 agricultural science packs from Gleba; 200 spoiled on the way, 200 more at
-- Nauvis, 595 went down. The freight read says that per stop and leg; the platforms row and platform_arrived agree.
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,part) assert(type(s)=='string' and s:find(part,1,true),tostring(s)..'\n  lacks: '..part) end
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
defines={space_platform_state={on_the_path=3,waiting_at_station=6,no_schedule=5},
  inventory={hub_main=1,hub_trash=2,cargo_landing_pad_main=3,cargo_unit=4}}
local function spoiling(ticks,into) return {get_spoil_ticks=function() return ticks end,spoil_result=into and {name=into} or nil} end
prototypes={item={['agricultural-science-pack']=spoiling(3600*60,'spoilage'),spoilage={get_spoil_ticks=function() return 0 end},
  ['iron-plate']={get_spoil_ticks=function() return 0 end},['firearm-magazine']={get_spoil_ticks=function() return 0 end}},
  space_location={nauvis={},gleba={},vulcanus={}}}
-- The hub: counts by item, main and trash.
local main,trash={},{}
local function inv(t) return {get_contents=function() local out={}; for n,c in pairs(t) do out[#out+1]={name=n,count=c,quality='normal'} end; return out end} end
local hub_sections={sections_count=1,get_section=function() return {active=true,filters={
  {value={name='iron-plate'},min=1000,import_from={name='nauvis'}},{value={name='agricultural-science-pack'},min=0,max=2000,import_from={name='gleba'}}}} end}
local hub={valid=true,get_inventory=function(id) return id==1 and inv(main) or inv(trash) end,get_logistic_sections=function() return hub_sections end}
local sunward={valid=true,index=1,name='Sunward',hub=hub,state=6,space_location={name='gleba'},schedule={records={{station='gleba'},{station='nauvis'}},current=1}}
local force={name='player',platforms={sunward}}
sunward.force=force
-- Nauvis: one landing pad asking 2000 agricultural packs, holding none.
local pad={get_logistic_sections=function() return {sections_count=1,get_section=function() return {active=true,filters={{value={name='agricultural-science-pack'},min=2000}}} end} end,
  get_inventory=function() return inv({}) end}
local finds=0
local nauvis={find_entities_filtered=function(f) finds=finds+1; assert(f.type=='cargo-landing-pad'); return {pad} end}
local gleba={find_entities_filtered=function() finds=finds+1; return {} end}
game={tick=0,forces={player=force},planets={nauvis={surface=nauvis},gleba={surface=gleba}}}
local st={}
local F=dofile('mod/agent-harness_0.1.0/freight.lua'){state=function() return st end,spoil=dofile('mod/agent-harness_0.1.0/spoil.lua'){state=function() return st end}}
local function second(n) for _=1,n or 1 do game.tick=game.tick+60; F.tick(game.tick) end end

-- 1. Where: a stop, a location while on its path, a leg in the way it is flown.
eq(F.where(sunward).text,'at gleba'); eq(F.where(sunward).stopped,true)
sunward.state=3
eq(F.where(sunward).text,'at gleba, on its path (not stopped)'); eq(F.where(sunward).stopped,false)
sunward.space_location=nil; sunward.space_connection={from={name='nauvis'},to={name='gleba'},length=15000}; sunward.distance=0.27
sunward.schedule.current=2; sunward.speed=0.05
local w=F.where(sunward)
eq(w.text,'flying gleba->nauvis 73%','the connection is nauvis->gleba; flown back, 73% of the way'); eq(w.leg.to,'nauvis')
eq(math.floor(w.leg.left_km+0.5),4050); eq(math.floor(w.leg.eta_ticks+0.5),81000)
sunward.distance=0.27; sunward.schedule.current=1
eq(F.where(sunward).text,'flying nauvis->gleba 27%','to the stop at gleba: the connection\'s own way')

-- 2. A stop at Gleba: 995 packs come aboard; a rocket from Gleba brings iron plate.
sunward.space_connection=nil; sunward.space_location={name='gleba'}; sunward.state=6
main={['firearm-magazine']=700}
second()
eq(#st.freight[1].segs,1); eq(st.freight[1].segs[1].partial,true,'under way when first seen')
main['agricultural-science-pack']=995
F.on_launch({rocket={attached_cargo_pod={cargo_pod_destination={station={surface={platform=sunward}}},
  get_inventory=function() return inv({['iron-plate']=50}) end}}})
main['iron-plate']=50
second(30)
-- 3. The leg back: one stack of 200 spoils on the way, in one second.
sunward.state=3
second()
sunward.space_location=nil; sunward.space_connection={from={name='nauvis'},to={name='gleba'},length=15000}; sunward.distance=0.9
sunward.schedule={records={{station='nauvis'}},current=1}
second(60)
main['agricultural-science-pack']=795; main.spoilage=200
second(60)
-- 4. The stop at Nauvis: the pad asks 2000; 200 more spoil there and 595 go down.
sunward.space_connection=nil; sunward.space_location={name='nauvis'}; sunward.state=6
local before=finds
second()
eq(finds,before+1,'the landing pads are found once, on arrival')
second(10)
main['agricultural-science-pack']=595; main.spoilage=400
second(10)
main['agricultural-science-pack']=nil
second(10)
eq(finds,before+1,'not again while stopped')
local fr=F.read(sunward)
eq(#fr,3)
eq(fr[1].line,'stop at nauvis (30s so far): agricultural-science-pack: expected down 795 (landing pads ask 2000, hold 0), left the hub 595, spoiled aboard 200; '
  ..'iron-plate: expected up 950 (the hub asks 1000 from nauvis), came aboard 0')
eq(fr[1].items[1].left,595); eq(fr[1].items[1].spoiled,200); eq(fr[1].items[1].expected_down,795)
eq(fr[2].line,'leg gleba->nauvis (2m00s, 30s ago): agricultural-science-pack 995 aboard at departure, 200 spoiled on the way (into spoilage), 795 at arrival')
eq(fr[3].line,'stop at gleba (32s, 2m30s ago; under way when first seen): agricultural-science-pack: came aboard 995; iron-plate: came aboard 50; '
  ..'rockets launched to it: 1, cargo iron-plate*50')
-- Arrivals and departures (Gemini, 16:50): it left gleba for nauvis and stopped at nauvis (the first look's stop is
-- no arrival); an agent on that planet is told once.
local ev=st.platform_events.list
eq(#ev,2); eq(ev[1].kind,'left'); eq(ev[1].at,'gleba'); eq(ev[1].to,'nauvis'); eq(ev[2].kind,'arrived'); eq(ev[2].at,'nauvis')
local onn,hn={surface={planet={name='nauvis'}},force=force},{}
local said=F.event_lines(onn,hn)
eq(#said,1); eq(said[1],'platform Sunward stopped at nauvis, your planet, 30s ago')
eq(F.event_lines(onn,hn),nil,'once')
eq(F.event_lines({surface={planet={name='gleba'}},force=force},{})[1],'platform Sunward left gleba, your planet, 2m30s ago, flying to nauvis')
eq(F.event_lines({surface={name='platform-1'},force=force},{}),nil,'not on a planet')
eq(F.event_lines({surface={planet={name='nauvis'}},force={name='enemy'}},{}),nil,'another force')
-- The trash counts as aboard: moved from the main inventory to the trash is no change.
main['firearm-magazine']=600; trash['firearm-magazine']=100
second()
eq(F.read(sunward)[1].line:find('firearm',1,true),nil)

-- 5. Freshness while flying: stacks that spoil before the arrival, and when the next one spoils after it.
local stacks={{valid_for_read=true,name='agricultural-science-pack',count=200,spoil_tick=game.tick+600,spoil_percent=0.9,quality={name='normal'}},
  {valid_for_read=true,name='agricultural-science-pack',count=200,spoil_tick=game.tick+9000,spoil_percent=0.5,quality={name='normal'}},
  {valid_for_read=true,name='iron-plate',count=100,quality={name='normal'}}}
hub.get_inventory=function(id)
  if id==1 then local t=inv(main); t.valid=true; for i,s in ipairs(stacks) do t[i]=s end; return setmetatable(t,{__len=function() return #stacks end}) end
  return inv(trash)
end
sunward.space_location=nil; sunward.state=3; sunward.space_connection={from={name='nauvis'},to={name='gleba'},length=15000}; sunward.distance=0.5
sunward.schedule={records={{station='gleba'}},current=1}; sunward.speed=7500/3600
local lines=F.freshness(sunward)
eq(lines[1],'agricultural-science-pack*400: the first spoils in 10s (all 400: 70% spoiled by count, 400 at 50% or more, 50-90%; that stack 90%); all within 5 min; arrival at gleba in 1m00s: 200 spoil before it, 200 arrive, the next spoils 1m30s after arrival')
eq(#lines,1,'iron plate does not spoil')
sunward.speed=0
-- Just launched at speed 0 (A4, Grok 21:21): the rest at its cruise (the last leg's top speed); none on record: no arrival.
local rec=st.freight[1]; local saved_c,saved_t=rec and rec.cruise,rec and rec.leg_top
if rec then rec.cruise,rec.leg_top=nil,nil end
eq(F.freshness(sunward)[1],'agricultural-science-pack*400: the first spoils in 10s (all 400: 70% spoiled by count, 400 at 50% or more, 50-90%; that stack 90%); all within 5 min','no speed, no cruise: no arrival')
st.freight[1]=st.freight[1] or {}
st.freight[1].cruise=7500/3600
has(F.freshness(sunward)[1],'arrival at gleba in 1m00s: 200 spoil before it, 200 arrive')
eq(F.leg(sunward).eta_from,'about: it speeds up (0 km/s now), the rest at its cruise of 125 km/s')
if rec then rec.cruise,rec.leg_top=saved_c,saved_t end

-- 6. platform_arrived reads the same rule: not met at a location while on its path.
local C=dofile('mod/agent-harness_0.1.0/conditions.lua'){position=function(v) return v end,known=function() return true end,platform_where=F.where}
local p={force=force}
sunward.space_connection=nil; sunward.space_location={name='gleba'}; sunward.state=3
local met,saw=C.check(p,{['until']='platform_arrived',platform='Sunward',location='gleba'})
eq(met,false); eq(saw,'Sunward at gleba, on its path (not stopped)')
sunward.state=6
met,saw=C.check(p,{['until']='platform_arrived',platform='Sunward',location='gleba'})
eq(met,true); eq(saw,'Sunward at gleba')
-- Departure (Gemini, 16:50; Grok 07:51: in flight it was met at once, an earlier departure counting and the location
-- left out): the next departure, met once it was seen stopped there (at any stop without a location) during the wait.
local rec_gleba,rec_nauvis,rec_any={},{},{}
met,saw=C.check(p,{['until']='platform_left',platform='Sunward',location='gleba'},nil,rec_gleba)
eq(met,false); eq(saw,'Sunward at gleba (met when it leaves)')
met,saw=C.check(p,{['until']='platform_left',platform='Sunward',location='nauvis'},nil,rec_nauvis)
eq(met,false); eq(saw,'Sunward at gleba; met when it stops at nauvis and leaves again (a departure before this wait does not count)')
eq(C.check(p,{['until']='platform_left',platform='Sunward'},nil,rec_any),false)
C.validate({['until']='platform_left',platform='Sunward',location='nauvis'})
assert(not pcall(C.validate,{['until']='platform_left'}),'needs platform')
sunward.space_location=nil; sunward.state=3; sunward.space_connection={from={name='nauvis'},to={name='gleba'},length=15000}; sunward.distance=0.25
sunward.schedule={records={{station='nauvis'}},current=1}
met,saw=C.check(p,{['until']='platform_arrived',platform='Sunward',location='nauvis'})
eq(met,false); eq(saw,'Sunward flying gleba->nauvis 75%')
met,saw=C.check(p,{['until']='platform_left',platform='Sunward',location='gleba'},nil,rec_gleba)
eq(met,true); eq(saw,'Sunward left gleba; now flying gleba->nauvis 75%')
eq(C.check(p,{['until']='platform_left',platform='Sunward'},nil,rec_any),true)
eq(C.check(p,{['until']='platform_left',platform='Sunward',location='nauvis'},nil,rec_nauvis),false,'it never stopped at nauvis in this wait')
met,saw=C.check(p,{['until']='platform_left',platform='Sunward'},nil,{})
eq(met,false,'a wait begun in flight waits for the next stop and departure')
-- 7. Cargo pods (Astra, 21:20: left the hub is not delivered): at a stop the pods leaving the hub are followed down;
-- a stop says what went down, what each landing pad received, and the pods still in flight. (Found by a look of its
-- own here; in the runtime they come from pods.lua, below.)
sunward.space_connection=nil; sunward.space_location={name='nauvis'}; sunward.state=6
second()
local plsurf={name='platform-1'}
local on_platform={}
plsurf.find_entities_filtered=function(f) eq(f.type,'cargo-pod'); local out={} for _,e in ipairs(on_platform) do out[#out+1]=e end return out end
sunward.surface=plsurf
local nauvis_s={name='nauvis'}
local padE={valid=true,name='cargo-landing-pad',position={x=10.5,y=20.5},surface=nauvis_s}
local function pod(unit,dest,items,origin)
  local e={valid=true,unit_number=unit,surface=plsurf,position={x=0,y=-2},cargo_pod_origin=origin or hub,cargo_pod_destination=dest}
  e.get_inventory=function(id) eq(id,4); return inv(items) end
  return e
end
local p1=pod(501,{station=padE},{['agricultural-science-pack']=200})
local p2=pod(502,{surface=nauvis_s},{['iron-plate']=50})
local p3=pod(503,{station=padE},{['agricultural-science-pack']=100})
local rocketpod=pod(504,{station=hub},{['iron-plate']=10},{name='rocket-silo'})
on_platform={p1,p2,rocketpod}
local function quarter(n) for _=1,n or 1 do game.tick=game.tick+60; F.pod_tick(game.tick) end end
quarter()
eq(#st.freight[1].pods,2,'the rocket\'s pod coming aboard is not one of the hub\'s')
-- They fly down; p1 lands in the pad, p2 on the ground; p3 leaves later and is still descending.
on_platform={p3,rocketpod}; p1.surface=nauvis_s; p2.surface=nauvis_s; p2.position={x=-3.4,y=7.6}
quarter()
on_platform={rocketpod}; p3.surface=nauvis_s
p1.valid=false; p2.valid=false
-- (Sonnet, shift14 22:50: the container the pod became, where it stands, not the pod's sighting rounded)
local kept_surfaces=game.surfaces
game.surfaces={nauvis={find_entities_filtered=function(f)
  eq(f.name,'cargo-pod-container'); eq(f.radius,8); return {{valid=true,position={x=-3.5,y=7.5}}} end}}
quarter()
game.surfaces=kept_surfaces
local fr7=F.read(sunward)[1]
has(fr7.line,'; cargo pods sent down 3 (agricultural-science-pack*300 iron-plate*50), received by landing pads 1 (agricultural-science-pack*200) '
  ..'at cargo-landing-pad (10.5,20.5) on nauvis, landed as cargo pod containers (no landing pad) 1 (iron-plate*50) at cargo-pod-container (-3.5,7.5) on nauvis, '
  ..'in flight 1 (agricultural-science-pack*100): #503 to cargo-landing-pad descending on nauvis (left the hub 1s ago)')
eq(fr7.pods.sent,3); eq(fr7.pods.received,1); eq(fr7.pods.in_flight,1); eq(fr7.pods.received_items['agricultural-science-pack'],200)
-- Gone from the platform without reaching the planet: said so. After the stop the last one is still followed.
local p5=pod(505,{station=padE},{['iron-plate']=5}); on_platform={p5}
quarter(); p5.valid=false; quarter()
has(F.read(sunward)[1].line,'gone before leaving the platform 1 (iron-plate*5)')
sunward.space_location=nil; sunward.state=3; sunward.space_connection={from={name='nauvis'},to={name='gleba'},length=15000}; sunward.distance=0.1
second(); p3.valid=false; quarter()
local stop7=F.read(sunward)[2]
has(stop7.line,'received by landing pads 2 (agricultural-science-pack*300)'); eq(stop7.pods.in_flight,0)
-- With pods.lua (runtime.lua passes it): the pods it follows from this platform are the ones taken.
do
  local st2={}
  local from_pods={}
  local F2=dofile('mod/agent-harness_0.1.0/freight.lua'){state=function() return st2 end,
    pods={from=function(force_name,platform) eq(force_name,'player'); eq(platform,'Sunward'); return from_pods end}}
  sunward.space_connection=nil; sunward.space_location={name='nauvis'}; sunward.state=6
  F2.tick(game.tick)
  plsurf.find_entities_filtered=function() error('pods.lua looks; freight does not') end
  local p6=pod(506,{station=padE},{['iron-plate']=7}); from_pods={p6}
  game.tick=game.tick+60; F2.pod_tick(game.tick)
  eq(#st2.freight[1].pods,1)
  has(F2.read(sunward)[1].line,'cargo pods sent down 1 (iron-plate*7)')
end
-- A platform gone: its record goes.
force.platforms={}
second()
eq(st.freight[1],nil)
-- Ammo over the last leg and rockets on their way up (Astra, shift14 22:50: reconciled by hand every flight). The
-- surface's item statistics as 2.0.77 keeps them (made: crafted; used: a turret's shots), snapshot when a leg opens.
do
  prototypes.item['firearm-magazine'].type='ammo'
  prototypes.item.rocket={type='ammo',get_spoil_ticks=function() return 0 end}
  defines.inventory.turret_ammo=9
  defines.flow_precision_index={ten_minutes=2}
  local made,used={['firearm-magazine']=1000,rocket=50},{['firearm-magazine']=900,rocket=10}
  local stats={get_input_count=function(n) return made[n] or 0 end,get_output_count=function(n) return used[n] or 0 end,
    get_flow_count=function(f) if f.category=='input' then return f.name=='firearm-magazine' and 300 or 0 end return f.name=='firearm-magazine' and 200 or 0 end}
  local tinv=inv({['firearm-magazine']=40})
  local turret={get_inventory=function(id) assert(id==9); return tinv end}
  -- On belts (Sol, Astra 06:21-09:37: Tern's 344 rockets on belts went uncounted): a belt, an underground pair whose
  -- output reports the input's buried lines as its own (counted once), and an inserter's hand.
  local function line(t2) local l={t=t2}; l.get_contents=function() return inv(l.t).get_contents() end; l.line_equals=function(o) return o==l end; return l end
  local belt_items={['firearm-magazine']=4}
  local belt={type='transport-belt',get_max_transport_line_index=function() return 2 end,get_transport_line=function(i) return i==2 and line(belt_items) or line({}) end}
  local buried=line({['firearm-magazine']=3})
  local ug_in={type='underground-belt',belt_to_ground_type='input',get_max_transport_line_index=function() return 4 end,
    get_transport_line=function(i) return i==4 and buried or line({}) end}
  local ug_out={type='underground-belt',belt_to_ground_type='output',neighbours=ug_in,valid=true,get_max_transport_line_index=function() return 4 end,
    get_transport_line=function(i) return i==4 and buried or line({}) end}
  ug_in.valid=true
  local hand={type='inserter',held_stack={valid_for_read=true,name='firearm-magazine',count=1}}
  local surf={name='platform-7',find_entities_filtered=function(f)
    if f.type=='ammo-turret' then return {turret} end
    if f.type=='inserter' then return {hand} end
    if type(f.type)=='table' and f.type[1]=='transport-belt' then return {belt,ug_in,ug_out} end
    return {} end}
  local pf={name='player'}
  pf.get_item_production_statistics=function(s) assert(s==surf); return stats end
  local pl={valid=true,index=7,name='Skylark',hub=hub,state=6,space_location={name='nauvis'},surface=surf,force=pf,schedule={records={{station='gleba'}},current=1}}
  local st2={}
  local F2=dofile('mod/agent-harness_0.1.0/freight.lua'){state=function() return st2 end}
  main,trash={['firearm-magazine']=500},{['firearm-magazine']=999}
  F2.track(pl,game.tick)
  -- Off to Gleba: the leg opens with the statistics now; 2 min later 100 made and 60 used.
  pl.state=3; pl.space_location=nil; pl.space_connection={from={name='nauvis'},to={name='gleba'},length=15000}; pl.distance=0.1; pl.speed=0.05
  game.tick=game.tick+60; F2.track(pl,game.tick)
  game.tick=game.tick+7200
  made['firearm-magazine'],used['firearm-magazine']=1100,960
  -- 50 moved from the hub onto the belt meanwhile: a move, not use.
  main['firearm-magazine']=450; belt_items['firearm-magazine']=54
  local a=F2.ammo(pl)
  eq(a[1],'firearm-magazine: made 50/min, used 30/min (fired or crafted into another item; moves between places are not use) over this leg nauvis->gleba (2m00s so far); 548 aboard: hub 450, turrets 40, belts 57, hands 1; since this leg began: hub -50, belts +50; at the arrival at gleba in 75m00s about 2048 at that rate')
  main['firearm-magazine']=500; belt_items['firearm-magazine']=4
  eq(a[2],nil,'no rocket held, made or used over the leg: not listed')
  -- Used faster than made: when it runs out, before the arrival.
  game.tick=game.tick+7200
  used['firearm-magazine']=1520
  eq(F2.ammo(pl)[1],'firearm-magazine: made 25/min, used 155/min (fired or crafted into another item; moves between places are not use) over this leg nauvis->gleba (4m00s so far); 548 aboard: hub 500, turrets 40, belts 7, hands 1; since this leg began: no change by place; runs out in 4m13s at that rate, before the arrival at gleba in 75m00s')
  -- Stopped at Gleba: the leg just flown, no arrival to come.
  pl.space_connection=nil; pl.space_location={name='gleba'}; pl.state=6
  game.tick=game.tick+60; F2.track(pl,game.tick)
  eq(F2.ammo(pl)[1],'firearm-magazine: made 25/min, used 154/min (fired or crafted into another item; moves between places are not use) over the last leg nauvis->gleba (4m01s); 548 aboard: hub 500, turrets 40, belts 7, hands 1; since the last leg began: no change by place')
  -- A leg seen first before the counts were kept (a runtime update): the game's last 10 minutes.
  for _,seg in ipairs(st2.freight[7].segs) do seg.ammo0=nil end
  eq(F2.ammo(pl)[1],'firearm-magazine: made 30/min, used 20/min (fired or crafted into another item; moves between places are not use) over the last 10 min; 548 aboard: hub 500, turrets 40, belts 7, hands 1')
  -- The last 1 and 5 minutes from the game's counts (Astra, shift17 10:50: parked, the leg average hid whether the orbit
  -- keeps up), and while stopped how long the stock lasts at the last 5 minutes' rate.
  defines.flow_precision_index={one_minute=0,five_minutes=1,ten_minutes=2}
  local counts={[0]={input=3,output=12},[1]={input=20,output=60},[2]={input=300,output=200}}
  stats.get_flow_count=function(f) if f.name~='firearm-magazine' then return 0 end return counts[f.precision_index][f.category] end
  eq(F2.ammo(pl)[1],'firearm-magazine: made 30/min, used 20/min (fired or crafted into another item; moves between places are not use) over the last 10 min; 548 aboard: hub 500, turrets 40, belts 7, hands 1; last 1 min: made 3.0/min, used 12/min; last 5 min: made 4.0/min, used 12/min; at the last 5 min rate the 548 aboard last 68m30s')
  counts[1]={input=60,output=20}  -- making more than it uses: no lasts line
  assert(not F2.ammo(pl)[1]:find('aboard last',1,true),F2.ammo(pl)[1])
  defines.flow_precision_index={ten_minutes=2}
  -- A rocket launched to its hub: on the way until its pod is gone (2.0.77: about 35 s).
  local pod={valid=true,cargo_pod_destination={station={surface={platform=pl}}},surface={name='nauvis'},
    get_inventory=function() return inv({['firearm-magazine']=20}) end}
  F2.on_launch({rocket={attached_cargo_pod=pod},rocket_silo={surface={name='nauvis'}}})
  local inc=F2.incoming(pl)
  eq(inc.rockets,1); eq(inc.cargo,'firearm-magazine*20'); eq(inc.lines[1],'a rocket from nauvis launched 0s ago (tick 26160): firearm-magazine*20 (rising over nauvis)')
  game.tick=game.tick+1800; pod.surface=surf
  eq(F2.incoming(pl).lines[1],'a rocket from nauvis launched 30s ago (tick 26160): firearm-magazine*20 (coming down onto the platform)')
  pod.valid=false
  eq(F2.incoming(pl),nil,'delivered: the pod is gone')
  -- (batch27 B2) pod_watch times the arrival: the next launch says when it arrives at that time
  F2.pod_watch(pl,game.tick)
  eq(st2.freight[7].up_times[1],1800)
  -- A pod kept past a minute (the game lost it some other way) is no longer counted.
  pod.valid=true
  F2.on_launch({rocket={attached_cargo_pod=pod},rocket_silo={surface={name='nauvis'}}})
  pod.surface={name='nauvis'}
  game.tick=game.tick+600
  eq(F2.incoming(pl).lines[1],'a rocket from nauvis launched 10s ago (tick 27960): firearm-magazine*20 (rising over nauvis); arrives in about 20s (the last 1 arrival took about 30s from launch)')
  game.tick=game.tick+2999
  eq(F2.incoming(pl).rockets,1)
  assert(F2.incoming(pl).lines[1]:find('past the usual 30s from launch',1,true))
  game.tick=game.tick+1
  eq(F2.incoming(pl),nil,'kept a minute at most')
  trash={}
end
print('freight: ok')
