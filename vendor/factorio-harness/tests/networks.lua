-- Run from repository root: lua tests/networks.lua
-- The base's networks, one line each (networks.lua; operator task-selfview: Nauvis at 29 game hours ran steam
-- only, about 21 MW capacity and 10.8 MW drawn; 147 logistic robots, none idle; 0 laser turrets): electric draw over
-- 5 minutes against capacity, boilers' fuel at that draw, logistic robots and unfilled requests, turrets and ammo;
-- the network push alert groups. Fake engine.
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(text,part) assert(text and text:find(part,1,true),'missing "'..part..'" in: '..tostring(text)) end
defines={flow_precision_index={five_seconds=0,one_hour=3},entity_status={no_power=1,low_power=2,working=0},
  logistic_member_index={logistic_container=0}}
prototypes={item={coal={type='item',fuel_value=4e6},['firearm-magazine']={type='ammo'},['iron-plate']={type='item'}},
  surface_property={['solar-power']={default_value=100}}}
storage={}
local force={name='player',players={{}}}
local enemy={name='enemy',players={}}
local list={}
local function add(e) e.valid=true; e.force=e.force or force; list[#list+1]=e; return e end
local nauvis={name='nauvis',index=1,solar_power_multiplier=1,get_property=function() return 100 end}
local function matches(e,f)
  if f.force and e.force~=f.force then return false end
  if f.type then
    local types=type(f.type)=='table' and f.type or {f.type}
    local ok=false
    for _,t in ipairs(types) do if e.type==t then ok=true end end
    if not ok then return false end
  end
  return true
end
nauvis.find_entities_filtered=function(f) local out={} for _,e in ipairs(list) do if matches(e,f) then out[#out+1]=e end end return out end
game={tick=0,forces={player=force,enemy=enemy},surfaces={nauvis}}
-- Electric network 7: 10 poles; network 9: two poles and nothing else (not listed).
local flows={['steam-engine']=18e6/60,['solar-panel']=0.5e6/60}
local stats={output_counts={['steam-engine']=1,['solar-panel']=1},get_flow_count=function(t) eq(t.category,'output'); eq(t.precision_index,0); return flows[t.name] or 0 end}
for i=0,9 do add{type='electric-pole',name='medium-electric-pole',position={x=i*7,y=0},electric_network_id=7,electric_network_statistics=stats,surface=nauvis} end
for i=0,1 do add{type='electric-pole',name='small-electric-pole',position={x=300+i*5,y=0},electric_network_id=9,
  electric_network_statistics={output_counts={},get_flow_count=function() return 0 end},surface=nauvis} end
-- 24 steam engines (900 kW each) in two rows, each row on one steam segment; 10 solar panels; 2 accumulators.
local engine={get_max_power_output=function() return 900000/60 end}
for i=1,24 do
  local seg=i<=12 and 100 or 101
  add{type='generator',name='steam-engine',prototype=engine,position={x=i*3,y=20},electric_network_id=7,
    fluidbox={get_fluid_segment_id=function(k) eq(k,1); return seg end}}
end
for i=1,10 do add{type='solar-panel',name='solar-panel',prototype={get_max_energy_production=function() return 60000/60 end},position={x=i*3,y=40},electric_network_id=7,surface=nauvis} end
for i=1,2 do add{type='accumulator',name='accumulator',prototype={},position={x=i*2,y=44},electric_network_id=7,energy=2.5e6,electric_buffer_size=5e6} end
-- 10 boilers: 8 with 400 coal, 2 with 100; one more boiler (segment unknown) next to an engine; one far off.
local function boiler(x,y,seg,coal,user)
  local inv={{valid_for_read=true,count=coal,prototype={fuel_value=4e6}}}
  local fb=setmetatable({get_fluid_segment_id=function(k) eq(k,2); return seg end},{__len=function() return 2 end})
  return add{type='boiler',name='boiler',position={x=x,y=y},fluidbox=fb,last_user=user and {name=user} or nil,
    prototype={burner_prototype={effectivity=1}},burner={remaining_burning_fuel=0,inventory=inv}}
end
for i=1,8 do boiler(i*6,16,i<=4 and 100 or 101,400) end
boiler(60,16,101,100,'luna'); boiler(66,16,101,100,'luna')
boiler(4,22,nil,400); boiler(400,400,999,400)
-- 30 assemblers on network 7: 3 on low power, 1 without power; 2 stone furnaces (no network).
for i=1,30 do add{type='assembling-machine',name='assembling-machine-2',position={x=i,y=60},electric_network_id=7,status=i<=3 and 2 or (i==4 and 1 or 0)} end
for i=1,2 do add{type='furnace',name='stone-furnace',position={x=i,y=70},status=0} end
-- Logistic network 3: 4 roboports, 147 logistic robots none idle, 11 construction robots 4 idle; a chest that wants
-- 400 iron plates and holds 20 with 80 on the way; one whose request is met.
local function chest(unit,held) return {unit_number=unit,get_item_count=function(q) return held[q.name] or 0 end} end
local ln={network_id=3,all_logistic_robots=147,available_logistic_robots=0,all_construction_robots=11,available_construction_robots=4,
  cells={},requester_points={
    {owner=chest(501,{['iron-plate']=20}),filters={{name='iron-plate',quality='normal',count=400}},targeted_items_deliver={['iron-plate']=80}},
    {owner=chest(502,{['copper-cable']=200}),filters={{name='copper-cable',quality='normal',count=200}},targeted_items_deliver={}}}}
for i=1,4 do ln.cells[i]={owner={position={x=50+i,y=50}}} end
force.logistic_networks={nauvis={ln}}
for i=1,5 do add{type='entity-ghost',name='entity-ghost',position={x=55,y=55+i}} end
for i=1,2 do add{type='entity-ghost',name='entity-ghost',position={x=500,y=500}} end
nauvis.find_logistic_networks_by_construction_area=function(pos,f) eq(f,force); return pos.x<100 and {ln} or {} end
-- 6 gun turrets; 1200 magazines used in the last hour.
for i=1,6 do add{type='ammo-turret',name='gun-turret',position={x=-50,y=i*2}} end
local items={output_counts={['firearm-magazine']=1,['iron-plate']=1},get_flow_count=function(t)
  eq(t.category,'output'); eq(t.precision_index,3); eq(t.count,true); return t.name=='firearm-magazine' and 1200 or 9000 end}
force.get_item_production_statistics=function(s) eq(s,nauvis); return items end
-- An enemy pole (another force, no players) is never read.
add{type='electric-pole',name='small-electric-pole',position={x=900,y=900},electric_network_id=50,force=enemy,electric_network_statistics=stats}

local N=dofile('mod/agent-harness_0.1.0/networks.lua'){state=function() return storage end}
local function run(sec) for _=1,sec*60 do game.tick=game.tick+1; N.tick(game.tick) end end

-- 1. Five minutes of samples; the lines, numbers only.
run(300)
local lines=N.lines(force,'nauvis',8)
eq(#lines,3,table.concat(lines,' | '))
eq(lines[1],'nauvis electric #7 (10 poles near (32,0)): draw 18.5 MW avg over 5 min (now 18.5 MW) of 22.1 MW capacity (84%); '
  ..'solar 10 panels, 500 kW now, 600 kW peak; accumulators 2 at 50%; machines 30: 3 low power, 1 no power; boilers 11: fuel 14 min at this draw, 2 under 10 min')
eq(lines[2],'nauvis logistic #3 (4 roboports near (51,50)): logistic robots 147, 0 idle (none idle for 4 min); construction robots 11, 4 idle; '
  ..'requests unfilled 60+ s: 1 (iron-plate 300 missing); ghosts in its construction area: 5')
eq(lines[3],'nauvis turrets: gun-turret 6; ammo used in the last hour: firearm-magazine 1200')
-- The read: the same numbers as fields.
local r=N.read({force=force},{})
eq(#r.surfaces,1); local e=r.surfaces[1].electric[1]
eq(e.id,7); eq(e.capacity_kw,22100); eq(e.generators_kw,21600); eq(e.solar_peak_kw,600); eq(e.draw_kw.avg,18500); eq(e.draw_kw.over_s,300)
eq(e.boilers,11,'the far boiler feeds nothing listed'); eq(e.fuel_min,14); eq(e.boilers_under_10_min,2); eq(e.low,3); eq(e.none,1)
local l=r.surfaces[1].logistic[1]; eq(l.unfilled,1); eq(l.unfilled_items['iron-plate'],300); eq(l.ghosts,5); eq(l.logistic_idle,0)
eq(r.surfaces[1].turrets.by_name['gun-turret'],6); eq(r.surfaces[1].turrets.ammo_used_1h['firearm-magazine'],1200)
assert(r.note:find('sampled every 5 s',1,true))
-- At most `max` lines, the rest counted.
storage.networks.views={}
local two=N.lines(force,'nauvis',2); eq(#two,2); eq(two[2],'+2 more networks: fh call networks')

-- 2. Alert groups: boilers under 10 min now (built by luna); draw under 85%: no power_high; robots not 10 min yet.
storage.networks.views={}
local g=N.alert_groups(force)
eq(#g,1); eq(g[1].kind,'boiler_fuel'); eq(g[1].n,2); eq(g[1].by.luna,2); eq(g[1].center.x,63)
eq(g[1].line,'2 boilers under 10 min of fuel at this draw near (63,16) (electric #7, 11 boilers, 14 min for all)')
-- Draw at 90% for 2 minutes: power_high; robots none idle for 10 minutes: robots_busy.
flows['steam-engine']=19.5e6/60
run(119); storage.networks.views={}
for _,x in ipairs(N.alert_groups(force)) do assert(x.kind~='power_high','not 2 minutes yet') end
run(300); storage.networks.views={}
local by={}
for _,x in ipairs(N.alert_groups(force)) do by[x.kind]=x end
eq(by.power_high.n,90); eq(by.power_high.unit,'%')
eq(by.power_high.line,'electric #7 draw at or above 85% of capacity for 2 min: 20.0 MW of 22.1 MW now; 3 machines on low power')
eq(by.robots_busy.line,'logistic #3: no idle logistic robot for 11 min (147 robots; 1 requests unfilled 60+ s)')
-- One sample under 85% ends it.
flows['steam-engine']=10e6/60; run(5); storage.networks.views={}
for _,x in ipairs(N.alert_groups(force)) do assert(x.kind~='power_high','below 85% now') end
-- A robot idle again: robots_busy starts over.
ln.available_logistic_robots=5; run(30); storage.networks.views={}
for _,x in ipairs(N.alert_groups(force)) do assert(x.kind~='robots_busy') end
print('networks: ok')
