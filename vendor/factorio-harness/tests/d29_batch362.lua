-- Completed production survives reversals and station passes shorter than a
-- caller's polling interval. Run by the raw and compacted Lua test runners.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,why) assert(a==b,(why or '')..': '..tostring(a)..' ~= '..tostring(b)) end
local function fails(f) assert(not pcall(f)) end
defines={inventory={cargo_unit=1},space_platform_state={on_the_path=3}}
prototypes={item={rocket={type='ammo'},['iron-plate']={type='item'}},quality={normal={level=0},rare={level=2}}}
require('qflow').reset()
local st,reads,broken={},0,false
local values={}
local function stats(fluid)
  return {get_input_count=function(id)
    reads=reads+1; if broken then error('statistics unavailable') end
    local key=type(id)=='table' and id.name..'@'..id.quality or id
    return (values[key] or {}).made or 0
  end,get_output_count=function(id)
    reads=reads+1; if broken then error('statistics unavailable') end
    local key=type(id)=='table' and id.name..'@'..id.quality or id
    return (values[key] or {}).used or 0
  end}
end
local pl={index=7,name='Ledger',valid=true,surface={},force={get_item_production_statistics=stats,get_fluid_production_statistics=stats}}
local w={at='nauvis',stopped=true}
local L=dofile('mod/agent-harness_0.1.0/productionlegs.lua'){state=function() return st end,where=function() return w end}
local function observe(t,source) game={tick=t}; L.observe(pl,t,source or 'event',w) end
local function fly(from,to,distance,connection)
  pl.space_connection={name=connection or 'nauvis-gleba'}; pl.distance=distance
  w={leg={from=from,to=to}}
end
local function counters(m,u,fm,fu,rm,ru)
  values={['rocket@normal']={made=m,used=u},['rocket@rare']={made=rm or 0,used=ru or 0},
    ['thruster-fuel']={made=fm,used=fu},['thruster-oxidizer']={made=fm*2,used=fu*2}}
end
counters(100,20,1000,200)
observe(0)
fly('nauvis','gleba',0); observe(10)
local before=reads
for t=11,50 do observe(t,'watch') end
eq(reads,before,'unchanged flight reads no counters')
counters(113,24,1020.125,211.0625,2,1)
fly('gleba','nauvis',.6); observe(51)
local r=L.read(pl,16)
eq(#r.legs,1); local a=r.legs[1]
eq(a.from,10); eq(a.to,51); eq(a.from_location,'nauvis'); eq(a.to_location,'gleba'); eq(a.heading,'gleba')
eq(a.ended_by,'reversal'); eq(a.status,'complete'); eq(a.end_position.distance,.6)
eq(a.ammo.rocket.made,15); eq(a.ammo.rocket.used,5); eq(a.fuel['thruster-fuel'].made,20.125)
eq(a.fuel['thruster-fuel'].used,11.0625); eq(a.loaded and next(a.loaded),nil)
-- A one-tick reversal has its own counters, even before the next second's watch.
counters(114,26,1020.25,211.125,2,1)
fly('nauvis','gleba',.59); observe(52)
r=L.read(pl,1); eq(#r.legs,1); eq(r.legs[1].from,51); eq(r.legs[1].to,52)
eq(r.legs[1].heading,'nauvis'); eq(r.legs[1].ammo.rocket.made,1); eq(r.legs[1].ammo.rocket.used,2)
eq(r.legs[1].fuel['thruster-fuel'].made,.125)
-- State event at a station on the path, then departure in the same tick.
counters(120,28,1030,215,2,1)
w={at='gleba',stopped=false}; observe(53)
fly('gleba','vulcanus',0,'gleba-vulcanus'); observe(53)
r=L.read(pl,16); eq(#r.legs,3); eq(r.legs[3].ended_by,'arrival'); eq(r.legs[3].end_position.location,'gleba')
eq(r.legs[3].ammo.rocket.made,6)
-- No state event: the existing watch's observed tick, with no invented station dwell.
counters(130,30,1040,220,2,1)
fly('vulcanus','nauvis',.01,'vulcanus-nauvis'); observe(60,'watch')
r=L.read(pl,1); eq(r.legs[1].ended_by,'station_passed'); eq(r.legs[1].end_source,'watch'); eq(r.legs[1].to,60)
-- Cargo event totals belong to their interval and retain quality.
local pod={get_inventory=function() return {get_contents=function() return {{name='rocket',quality='rare',count=12}} end} end}
pod.cargo_pod_destination={station={surface={platform=pl}}}
L.on_launch{rocket={attached_cargo_pod=pod},tick=61}
pod.cargo_pod_origin={surface={platform=pl}}
L.on_pod{cargo_pod=pod,tick=62}
fly('nauvis','vulcanus',.5,'vulcanus-nauvis'); observe(63)
r=L.read(pl,1); eq(r.legs[1].loaded['rocket@rare'],12); eq(r.legs[1].dropped['rocket@rare'],12)
local nreads=reads
L.read(pl,16); L.read(pl,1); eq(reads,nreads,'reads never mutate a boundary or collect native counters')
-- Exactly 17 completed flights: retain 2..17 independently of freight's ring.
st={}; w={at='nauvis'}; observe(100)
for i=1,17 do
  fly('nauvis','gleba',0); observe(100+i*10)
  w={at='gleba'}; observe(105+i*10)
end
r=L.read(pl,16); eq(r.kept,16); eq(#r.legs,16); eq(r.legs[1].id,2); eq(r.legs[16].id,17)
fly('gleba','nauvis',0); observe(280); eq(L.read(pl,1).legs[1].id,17,'previous remains during new flight')
-- Failed boundary and counter reset are not zero/complete production.
broken=true; w={at='nauvis'}; observe(281)
r=L.read(pl,1); eq(r.legs[1].status,'incomplete'); eq(r.legs[1].ammo,nil); assert(r.legs[1].counter_status)
broken=false; fly('nauvis','gleba',0); observe(282)
counters(1,0,0,0); w={at='gleba'}; observe(283)
eq(L.read(pl,1).legs[1].status,'incomplete')
st={}; fly('gleba','nauvis',.3); observe(300); w={at='nauvis'}; observe(301)
r=L.read(pl,1); eq(r.legs[1].partial,true); eq(r.legs[1].status,'incomplete')
L.prune({}); eq(L.read(pl,1).kept,0)
-- Action integration and invalid/conflicting selectors.
local B=dofile('mod/agent-harness_0.1.0/platbom.lua'){platform=function() return pl end,legs=L.read}
eq(B.production({}, {platform='Ledger',legs=16}).limit,16)
for _,n in ipairs({0,17,1.5,'2',true}) do fails(function() B.production({}, {platform='Ledger',legs=n}) end) end
for _,k in ipairs({'leg','long','surface','item'}) do
  fails(function() B.production({}, {platform='Ledger',legs=1,[k]=true}) end)
end
-- The existing freight watch uses the same ledger even without a usable hub.
local F=dofile('mod/agent-harness_0.1.0/freight.lua'){state=function() return st end}
pl.space_location={name='nauvis'}; pl.space_connection=nil
F.track(pl,400)
pl.space_location=nil; pl.space_connection={name='nauvis-gleba',from={name='nauvis'},to={name='gleba'},length=1000}
pl.schedule={current=1,records={{station='gleba'}}}; pl.distance=.1
F.track(pl,460)
pl.schedule.records[1].station='nauvis'; pl.distance=.09; F.track(pl,520)
eq(F.productionlegs.read(pl,1).legs[1].to,520)
-- A schedule can point beyond this connection. Actual distance direction closes
-- a one-tick reversal, with no state event and no intervening one-second sample.
local P=F.productionlegs
pl.distance=.091; P.tick(521)
pl.distance=.09; P.tick(522)
local actual=P.read(pl,16).legs
eq(actual[#actual-1].to,521); eq(actual[#actual-1].heading,'nauvis')
eq(actual[#actual].from,521); eq(actual[#actual].to,522); eq(actual[#actual].heading,'gleba')
local no_reads=reads
pl.distance=.089; P.tick(523); pl.distance=.088; P.tick(524)
eq(reads,no_reads,'unchanged native direction never reads counters')
print('d29_batch362 completed production ledger: ok')
