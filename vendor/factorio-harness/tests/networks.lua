-- Run from repository root: lua tests/networks.lua
-- The base's networks, one line each (networks.lua; operator task-selfview: Nauvis at 29 game hours ran steam
-- only, about 21 MW capacity and 10.8 MW drawn; 147 logistic robots, none idle; 0 laser turrets): electric draw over
-- 5 minutes against capacity, boilers' fuel at that draw, logistic robots and unfilled requests, turrets and ammo;
-- the network push alert groups. Fake engine.
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(text,part) assert(text and text:find(part,1,true),'missing "'..part..'" in: '..tostring(text)) end
defines={inventory={chest=1},flow_precision_index={five_seconds=0,one_hour=3},entity_status={no_power=1,low_power=2,working=0},
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
-- 10 boilers: 8 with 1000 coal, 2 with 100; one more boiler (segment unknown, 400 coal) next to an engine; one far off.
local units=0
local function boiler(x,y,seg,coal,user)
  local inv={{valid_for_read=true,name='coal',count=coal,prototype={fuel_value=4e6}}}
  local fb=setmetatable({get_fluid_segment_id=function(k) eq(k,2); return seg end},{__len=function() return 2 end})
  units=units+1
  return add{type='boiler',name='boiler',unit_number=900+units,position={x=x,y=y},fluidbox=fb,last_user=user and {name=user} or nil,
    prototype={burner_prototype={effectivity=1}},burner={remaining_burning_fuel=0,inventory=inv,currently_burning={name={name='coal'}}}}
end
for i=1,8 do boiler(i*6,16,i<=4 and 100 or 101,1000) end
local lb1=boiler(60,16,101,100,'luna'); local lb2=boiler(66,16,101,100,'luna')
local nearb=boiler(4,22,nil,400); boiler(400,400,999,400)
-- Coal nearby: a chest with 400 and an iron chest with 50, a belt of two tiles with 4 a lane; an inserter feeds one
-- low boiler from the chest; a chest of iron plates holds no fuel.
local coalchest=add{type='container',name='wooden-chest',unit_number=801,position={x=40.5,y=12.5},get_inventory=function() return {get_item_count=function(n) return n=='coal' and 400 or 0 end} end,
  get_item_count=function(n) return n=='coal' and 400 or 0 end}
add{type='container',name='iron-chest',unit_number=802,position={x=80.5,y=12.5},get_inventory=function() return {get_item_count=function(n) return n=='coal' and 50 or 0 end} end}
add{type='container',name='wooden-chest',unit_number=803,position={x=41.5,y=12.5},get_inventory=function() return {get_item_count=function(n) return n=='iron-plate' and 50 or 0 end} end}
for i=1,2 do add{type='transport-belt',name='transport-belt',position={x=30.5,y=10.5+i},get_max_transport_line_index=function() return 2 end,
  get_transport_line=function() return {get_item_count=function(n) return n=='coal' and 4 or 0 end} end} end
add{type='inserter',name='burner-inserter',position={x=60,y=14},drop_target=lb1,pickup_target=coalchest}
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
-- 4 roboports 25 tiles apart (logistic 25, construction 55), the first charging 3 logistic and 1 construction robot
-- with 2 logistic waiting; and a character's personal roboport (mobile).
local function robots(kind,n) local out={} for i=1,n do out[i]={type=kind} end return out end
for i=1,4 do
  ln.cells[i]={owner={valid=true,position={x=i*25,y=50}},logistic_radius=25,construction_radius=55,
    charging_robots=i==1 and {robots('logistic-robot',3)[1],robots('logistic-robot',3)[2],robots('logistic-robot',3)[3],{type='construction-robot'}} or {},
    to_charge_robots=i==1 and robots('logistic-robot',2) or {},charging_robot_count=i==1 and 4 or 0,to_charge_robot_count=i==1 and 2 or 0,
    stationed_logistic_robot_count=0,stationed_construction_robot_count=i==1 and 4 or 0}
end
ln.cells[5]={mobile=true,owner={valid=true,position={x=0,y=0}},logistic_radius=0,construction_radius=10,charging_robots={},to_charge_robots={}}
force.logistic_networks={nauvis={ln}}
for i=1,5 do add{type='entity-ghost',name='entity-ghost',position={x=55,y=55+i}} end
for i=1,2 do add{type='entity-ghost',name='entity-ghost',position={x=500,y=500}} end
-- Ghosts are counted once per network over its construction area's box, bounded (00:26 rule).
nauvis.count_entities_filtered=function(q)
  eq(q.force,force); eq(q.type,'entity-ghost'); assert(q.limit and q.area,'bounded, by area')
  local n=0
  for _,e in ipairs(list) do
    if e.type=='entity-ghost' and e.position.x>=q.area[1][1] and e.position.x<=q.area[2][1] and e.position.y>=q.area[1][2] and e.position.y<=q.area[2][2] then n=n+1 end
  end
  return n
end
-- 6 gun turrets; 1200 magazines used in the last hour.
for i=1,6 do add{type='ammo-turret',name='gun-turret',position={x=-50,y=i*2}} end
local items={output_counts={['firearm-magazine']=1,['iron-plate']=1},get_flow_count=function(t)
  eq(t.category,'output'); eq(t.precision_index,3); eq(t.count,true); return t.name=='firearm-magazine' and 1200 or 9000 end}
force.get_item_production_statistics=function(s) eq(s,nauvis); return items end
-- An enemy pole (another force, no players) is never read.
add{type='electric-pole',name='small-electric-pole',position={x=900,y=900},electric_network_id=50,force=enemy,electric_network_statistics=stats}

local N=dofile('mod/agent-harness_0.1.0/networks.lua'){state=function() return storage end}
local function run(sec) for _=1,sec*60 do game.tick=game.tick+1; N.tick(game.tick) end end

-- 1. Five minutes of samples; the lines, numbers only. The background job keeps a view up to 60 s old (section 3);
-- here the view is built at once from the 5 minutes of samples.
run(300)
local bg_view=storage.networks.views.player
assert(bg_view and bg_view.tick<game.tick,'the background job made a view')
storage.networks.views={}
local lines=N.lines(force,'nauvis',8)
eq(#lines,3,table.concat(lines,' | '))
eq(lines[1],'nauvis electric #7 (10 poles near (32,0)): draw 18.5 MW avg over 5 min (now 18.5 MW) of 22.1 MW capacity (84%); '
  ..'solar 10 panels, 500 kW now, 600 kW peak; accumulators 2 at 50%; machines 30: 3 low power, 1 no power; boilers 11: fuel (theirs and their feeders\' sources) 33 min at this draw')
-- (the first look: no supply known from before, so none is running down yet)
eq(lines[2],'nauvis logistic #3: 4 roboports (+1 personal), logistic area (0,25)-(125,75), construction area (-30,-5)-(155,105); '
  ..'logistic robots 147: 0 idle, 142 working, 3 charging, 2 waiting to charge; construction robots 11: 4 idle, 6 working, 1 charging, 0 waiting to charge; '
  ..'no idle logistic robot for 4 min; requests unfilled 60+ s: 1 (iron-plate 300 missing); ghosts in its construction area: 5')
eq(lines[3],'nauvis turrets: gun-turret 6; ammo used in the last hour: firearm-magazine 1200')
-- The read: the same numbers as fields.
local r=N.read({force=force},{})
eq(#r.surfaces,1); local e=r.surfaces[1].electric[1]
eq(e.id,7); eq(e.capacity_kw,22100); eq(e.generators_kw,21600); eq(e.solar_peak_kw,600); eq(e.draw_kw.avg,18500); eq(e.draw_kw.over_s,300)
eq(e.boilers,11,'the far boiler feeds nothing listed'); eq(e.fuel_min,33); eq(e.boilers_under_10_min,0); eq(e.boilers_under_20_min,0); eq(e.lowest_boiler_min,4); eq(e.low,3); eq(e.none,1)
local l=r.surfaces[1].logistic[1]; eq(l.unfilled,1); eq(l.unfilled_items['iron-plate'],300); eq(l.ghosts,5); eq(l.logistic_idle,0)
eq(l.roboports,4); eq(l.personal,1); eq(l.logistic_area.x0,0); eq(l.construction_area.x1,155)
eq(l.logistic_robots.working,142); eq(l.logistic_robots.charging,3); eq(l.construction_robots.idle,4); eq(l.construction_robots.waiting,0)
-- Inspect on a roboport: its network and its own cell; on a chest in the network; on a chest no roboport covers.
local port={type='roboport',position={x=25,y=50},logistic_cell=ln.cells[1],logistic_network=ln}
local seen=N.of_entity(port)
eq(seen.id,3); eq(seen.roboports,4); eq(seen.logistic_robots.idle,0)
eq(seen.line,'logistic #3: 4 roboports (+1 personal), logistic area (0,25)-(125,75), construction area (-30,-5)-(155,105); '
  ..'logistic robots 147: 0 idle, 142 working, 3 charging, 2 waiting to charge; construction robots 11: 4 idle, 6 working, 1 charging, 0 waiting to charge')
eq(seen.port.line,'this roboport: logistic area (0,25)-(50,75), construction area (-30,-5)-(80,105); stationed: 0 logistic, 4 construction robots; 4 charging (3 logistic, 1 construction), 2 waiting to charge (2 logistic, 0 construction)')
eq(N.of_entity({type='logistic-container',position={x=60,y=60},logistic_network=ln}).id,3)
local lone=N.of_entity({type='logistic-container',position={x=900,y=900}})
eq(lone.none,'in no logistic network: no roboport\'s logistic area covers it'); eq(lone.id,nil)
-- Cells that do not list their robots: per-kind charging is left out, the network's totals shown.
local bare={network_id=4,all_logistic_robots=10,available_logistic_robots=2,all_construction_robots=0,available_construction_robots=0,
  cells={{owner={valid=true,position={x=0,y=0}},logistic_radius=25,construction_radius=55,charging_robot_count=3,to_charge_robot_count=1}}}
local bv=N.logistic_view(bare)
eq(bv.logistic.charging,nil); eq(bv.logistic.working,8); eq(bv.charging,3)
eq(bv.text,'1 roboport, logistic area (-25,-25)-(25,25), construction area (-55,-55)-(55,55); logistic robots 10: 2 idle, 8 working; '
  ..'construction robots 0: 0 idle, 0 working; 3 robots charging, 1 waiting to charge')
eq(r.surfaces[1].turrets.by_name['gun-turret'],6); eq(r.surfaces[1].turrets.ammo_used_1h['firearm-magazine'],1200)
assert(r.note:find('sampled every 5 s',1,true))
-- At most `max` lines, the rest counted.
storage.networks.views={}
local two=N.lines(force,'nauvis',2); eq(#two,2); eq(two[2],'+2 more networks: fh call networks')

-- 2. Alert groups. A second look a second later: three boilers burnt down (luna's two and the one by the engine), the
-- other eight kept their coal. Low: under 20 min with their feeders' sources and running down. The line names each
-- low boiler, its feeder and the feeder's source (lb1's inserter takes from the chest with 400 coal: 17 min), and the
-- coal in chests and on belts nearby; draw under 85%: no power_high; robots not 10 min yet.
lb1.burner.inventory[1].count=20; lb2.burner.inventory[1].count=60; nearb.burner.inventory[1].count=300
run(5)  -- (whole 5 s draw samples keep the 2-minute checks below aligned)
storage.networks.views={}
local g=N.alert_groups(force)
eq(#g,1); eq(g[1].kind,'boiler_fuel'); eq(g[1].n,3); eq(g[1].by.luna,2); eq(g[1].center.x,43); eq(g[1].rank,30003)
eq(g[1].now_text,'3 boilers under 20 min of fuel at this draw, 1 under 10, 1 under 5, lowest 2 min')
eq(g[1].line,'3 boilers under 20 min of fuel at this draw, 1 under 10, 1 under 5 and running down near (43,18) (electric #7: 11 boilers, '
  ..'32 min for all with their feeders\' sources); boiler (66,16) 2 min: no inserter feeds it; boiler (4,22) 12 min: no inserter feeds it; '
  ..'boiler (60,16) 17 min: burner-inserter (60,14) from wooden-chest (41,13) holding 400 coal; '
  ..'fuel within 64 tiles: wooden-chest (41,13) coal 400, iron-chest (81,13) coal 50; belts: coal 16 on 2 tiles, nearest (31,13), (31,12)')
-- A third look with nothing burnt since: nothing is running down, no alert.
run(5); storage.networks.views={}
for _,x in ipairs(N.alert_groups(force)) do assert(x.kind~='boiler_fuel','steady: no boiler alert') end
-- Draw at 90% for 2 minutes: power_high; robots none idle for 10 minutes: robots_busy.
flows['steam-engine']=19.5e6/60
run(119); storage.networks.views={}
for _,x in ipairs(N.alert_groups(force)) do assert(x.kind~='power_high','not 2 minutes yet') end
run(300); storage.networks.views={}
local by={}
for _,x in ipairs(N.alert_groups(force)) do by[x.kind]=x end
eq(by.power_high.n,90); eq(by.power_high.unit,'%')
eq(by.power_high.line,'electric #7 draw at or above 85% of capacity for 2 min: 20.0 MW of 22.1 MW now; 3 machines on low power')
eq(by.robots_busy.line,'logistic #3: no idle logistic robot for 12 min (147 robots; 1 requests unfilled 60+ s)')
-- One sample under 85% ends it.
flows['steam-engine']=10e6/60; run(5); storage.networks.views={}
for _,x in ipairs(N.alert_groups(force)) do assert(x.kind~='power_high','below 85% now') end
-- A robot idle again: robots_busy starts over.
ln.available_logistic_robots=5; run(30); storage.networks.views={}
for _,x in ipairs(N.alert_groups(force)) do assert(x.kind~='robots_busy') end
-- 3. The background view (task-statuscost, 01:15 on world n: networks.alert_groups 55 ms when one call rebuilt the
-- view): one step a tick, each step at most one entity find; a reply with a view reads that and finds nothing.
do
  local find=nauvis.find_entities_filtered
  local per_tick=0
  -- (whole-surface finds; the boilers' feeder look-ups are small finds of 4 tiles around each boiler)
  nauvis.find_entities_filtered=function(f) if not f.position then per_tick=per_tick+1 end; return find(f) end
  storage.networks.views={}; storage.networks.view_jobs={}
  local worst=0
  for _=1,40 do
    game.tick=game.tick+1; per_tick=0; N.tick(game.tick)
    if game.tick%300~=0 then worst=math.max(worst,per_tick) end
  end
  assert(worst<=2,'at most the step and the ghost count a tick: '..worst)
  local v=storage.networks.views.player
  assert(v and #v.surfaces==1 and #v.surfaces[1].electric==1,'the job made the view')
  game.tick=game.tick+5000; per_tick=0
  N.lines(force,'nauvis',8); N.read({force=force},{})
  eq(per_tick,0,'a reply reads the last view')
  -- (alert_groups runs in pushalerts' background job; only its low boilers' fuel look-ups read the world, bounded)
  nauvis.find_entities_filtered=find
end
-- 4. World n at 01:53 (Haiku: the alert fired for hours, 'lowest 0 min'): 13 boilers near (-7,41) hold 4-26 coal each,
-- all working, fed by inserters from a belt and from the requester chest (9,38) with 150 coal. While that supply holds
-- steady there is no alert; when it runs down, the alert names each low boiler, its feeder and the source's count.
do
  local st4={}
  local stuff={}
  local function put(e) e.valid=true; e.force=e.force or force; stuff[#stuff+1]=e; return e end
  local n2={name='n2',index=2,solar_power_multiplier=1,get_property=function() return 100 end}
  n2.find_entities_filtered=function(f)
    local out={}
    for _,e in ipairs(stuff) do
      local ok=matches(e,f)
      if ok and f.position and f.radius then ok=(e.position.x-f.position.x)^2+(e.position.y-f.position.y)^2<=f.radius^2 end
      if ok then out[#out+1]=e end
    end
    return out
  end
  n2.find_logistic_networks_by_construction_area=function() return {} end
  n2.count_entities_filtered=function() return 0 end
  local draw={['steam-engine']=12e6/60}
  local st2={output_counts={['steam-engine']=1},get_flow_count=function(t) return draw[t.name] or 0 end}
  for i=1,3 do put{type='electric-pole',name='medium-electric-pole',position={x=-10+i*5,y=30},electric_network_id=20,electric_network_statistics=st2,surface=n2} end
  for i=1,26 do put{type='generator',name='steam-engine',prototype=engine,position={x=-20+i*2,y=46},electric_network_id=20,
    fluidbox={get_fluid_segment_id=function() return 500 end}} end
  local boilers={}
  for i=1,13 do
    local inv={{valid_for_read=true,name='coal',count=4+((i-1)*22)//12,prototype={fuel_value=4e6}}}
    local fb=setmetatable({get_fluid_segment_id=function() return 500 end},{__len=function() return 2 end})
    boilers[i]=put{type='boiler',name='boiler',unit_number=1000+i,position={x=-25+i*3,y=41},fluidbox=fb,
      prototype={burner_prototype={effectivity=1}},burner={remaining_burning_fuel=0,inventory=inv,currently_burning={name={name='coal'}}}}
  end
  -- A belt run of 20 tiles along y=36, 6 coal on each tile; the first 7 boilers take from tiles of it.
  local coal_per_tile=6
  local tiles={}
  for k=1,20 do
    local t=put{type='transport-belt',name='transport-belt',unit_number=2000+k,position={x=-25+k*2,y=36}}
    t.get_max_transport_line_index=function() return 1 end
    t.get_transport_line=function() return {get_item_count=function(n) return n=='coal' and coal_per_tile or 0 end} end
    tiles[k]=t
  end
  for k=1,20 do tiles[k].belt_neighbours={inputs=k>1 and {tiles[k-1]} or {},outputs=k<20 and {tiles[k+1]} or {}} end
  local in_chest=150
  local requester=put{type='logistic-container',name='requester-chest',unit_number=3001,position={x=9.5,y=38.5},
    get_item_count=function(n) return n=='coal' and in_chest or 0 end}
  for i=1,13 do
    local b=boilers[i]
    put{type='inserter',name='inserter',unit_number=4000+i,position={x=b.position.x,y=39},drop_target=b,pickup_target=i<=7 and tiles[i+5] or requester}
  end
  local saved=game.surfaces
  game.surfaces={n2}
  local N4=dofile('mod/agent-harness_0.1.0/networks.lua'){state=function() return st4 end}
  local function run4(sec) for _=1,sec*60 do game.tick=game.tick+1; N4.tick(game.tick) end end
  local function boiler_groups()
    st4.networks.views={}
    local out={}
    for _,x in ipairs(N4.alert_groups(force)) do if x.kind=='boiler_fuel' then out[#out+1]=x end end
    return out
  end
  run4(60)
  eq(#boiler_groups(),0,'the first look')
  run4(30)
  eq(#boiler_groups(),0,'supply steady: no alert though each boiler holds under 5 min of its own')
  local line=N4.lines(force,'n2',8)[1]
  has(line,'boilers 13: fuel (theirs and their feeders\' sources) ')
  -- The supply runs out: the chest and the belt empty, the boilers burn down to 2 coal each.
  in_chest=0; coal_per_tile=0
  for _,b in ipairs(boilers) do b.burner.inventory[1].count=2 end
  run4(30)
  local g=boiler_groups()
  eq(#g,1); eq(g[1].n,13)
  has(g[1].line,'13 boilers under 20 min of fuel at this draw, 13 under 10, 13 under 5 and running down near (-4,41)')
  has(g[1].line,'boiler (-22,41) 0 min: inserter (-22,39) from transport-belt (-13,36) (with 6 belt tiles up to it holding no coal)')
  has(g[1].line,'inserter (2,39) from requester-chest (10,39) holding no coal')
  has(g[1].line,'+10 more')
  game.surfaces=saved
end
-- Boilers that hold no fuel at all: the usual fuels are looked for, and the line says so.
local empty={valid=true,type='boiler',name='boiler',unit_number=990,position={x=200,y=200},
  burner={remaining_burning_fuel=0,inventory={{valid_for_read=false}}}}
local fg=N.fuel_group({name='nauvis'},{id=9,boilers={{e=empty,min=0}},fuel_low={{e=empty,min=0}}},force)
has(fg.line,'1 boiler under 20 min of fuel at this draw, 1 under 10, 1 under 5 and running down near (200,200) (electric #9: 1 boiler, no draw); '
  ..'boiler (200,200) 0 min: no inserter feeds it; '
  ..'fuel within 64 tiles (the boilers hold none; looked for coal, solid-fuel, wood, rocket-fuel, nuclear-fuel): iron-chest (81,13) coal 50, wooden-chest (41,13) coal 400; belts: coal 16')
has(fg.line,'boiler (200,200) 0 min: no inserter feeds it')
print('networks: ok')
