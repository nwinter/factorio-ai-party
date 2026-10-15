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
eq(lines[1],'agricultural-science-pack*400: the first spoils in 10s (90% spoiled); all within 5 min; arrival at gleba in 1m00s: 200 spoil before it, 200 arrive, the next spoils 1m30s after arrival')
eq(#lines,1,'iron plate does not spoil')
sunward.speed=0
eq(F.freshness(sunward)[1],'agricultural-science-pack*400: the first spoils in 10s (90% spoiled); all within 5 min','no speed: no arrival')

-- 6. platform_arrived reads the same rule: not met at a location while on its path.
local C=dofile('mod/agent-harness_0.1.0/conditions.lua'){position=function(v) return v end,known=function() return true end,platform_where=F.where}
local p={force=force}
sunward.space_connection=nil; sunward.space_location={name='gleba'}; sunward.state=3
local met,saw=C.check(p,{['until']='platform_arrived',platform='Sunward',location='gleba'})
eq(met,false); eq(saw,'Sunward at gleba, on its path (not stopped)')
sunward.state=6
met,saw=C.check(p,{['until']='platform_arrived',platform='Sunward',location='gleba'})
eq(met,true); eq(saw,'Sunward at gleba')
-- Departure (Gemini, 16:50): met while it is not stopped there (or at no stop).
eq(C.check(p,{['until']='platform_left',platform='Sunward',location='gleba'}),false)
eq(C.check(p,{['until']='platform_left',platform='Sunward',location='nauvis'}),true)
eq(C.check(p,{['until']='platform_left',platform='Sunward'}),false)
C.validate({['until']='platform_left',platform='Sunward',location='nauvis'})
assert(not pcall(C.validate,{['until']='platform_left'}),'needs platform')
sunward.space_location=nil; sunward.state=3; sunward.space_connection={from={name='nauvis'},to={name='gleba'},length=15000}; sunward.distance=0.25
sunward.schedule={records={{station='nauvis'}},current=1}
met,saw=C.check(p,{['until']='platform_arrived',platform='Sunward',location='nauvis'})
eq(met,false); eq(saw,'Sunward flying gleba->nauvis 75%')
met,saw=C.check(p,{['until']='platform_left',platform='Sunward'})
eq(met,true); eq(saw,'Sunward flying gleba->nauvis 75%')
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
print('freight: ok')
