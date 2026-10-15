-- Run from repository root: lua tests/networks.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path  -- (walk.lua)
-- The base's networks, one line each (networks.lua; operator task-selfview: Nauvis at 29 game hours ran steam
-- only, about 21 MW capacity and 10.8 MW drawn; 147 logistic robots, none idle; 0 laser turrets): electric draw over
-- 5 minutes against capacity, boilers' fuel at that draw, logistic robots and unfilled requests, turrets and ammo;
-- the network push alert groups. Fake engine.
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(text,part) assert(text and text:find(part,1,true),'missing "'..part..'" in: '..tostring(text)) end
defines={inventory={chest=1},flow_precision_index={five_seconds=0,one_hour=3},entity_status={no_power=1,low_power=2,working=0},
  logistic_member_index={logistic_container=0}}
prototypes={item={coal={type='item',fuel_value=4e6},['firearm-magazine']={type='ammo'},['iron-plate']={type='item'}},
  surface_property={['solar-power']={default_value=100}},entity={accumulator={type='accumulator'}}}
storage={}
local force={name='player',players={{}}}
local enemy={name='enemy',players={}}
local list={}
local function add(e) e.valid=true; e.force=e.force or force; list[#list+1]=e; return e end
local nauvis={name='nauvis',index=1,solar_power_multiplier=1,get_property=function() return 100 end}
local function matches(e,f)
  if f.force and e.force~=f.force then return false end
  -- Orders (the construction backlog): marked entities, and ghosts inside the area asked.
  if f.to_be_deconstructed and not e.decon then return false end
  if f.to_be_upgraded and not e.upgrade then return false end
  if f.area and (f.type=='entity-ghost' or f.to_be_deconstructed or f.to_be_upgraded) then
    local p,a=e.position,f.area
    if not (p.x>=a[1][1] and p.x<=a[2][1] and p.y>=a[1][2] and p.y<=a[2][2]) then return false end
  end
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
-- (accumulators: output while they discharge, input while they charge; J per tick)
local flows_in={}
local stats={output_counts={['steam-engine']=1,['solar-panel']=1,accumulator=1},get_flow_count=function(t)
  eq(t.precision_index,0)
  if t.category=='input' then return flows_in[t.name] or 0 end
  eq(t.category,'output'); return flows[t.name] or 0 end}
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
chest_coal=400
local coalchest=add{type='container',name='wooden-chest',unit_number=801,position={x=40.5,y=12.5},get_inventory=function() return {get_item_count=function(n) return n=='coal' and chest_coal or 0 end} end,
  get_item_count=function(n) return n=='coal' and chest_coal or 0 end}
add{type='container',name='iron-chest',unit_number=802,position={x=80.5,y=12.5},get_inventory=function() return {get_item_count=function(n) return n=='coal' and 50 or 0 end} end}
add{type='container',name='wooden-chest',unit_number=803,position={x=41.5,y=12.5},get_inventory=function() return {get_item_count=function(n) return n=='iron-plate' and 50 or 0 end} end}
for i=1,2 do add{type='transport-belt',name='transport-belt',position={x=30.5,y=10.5+i},get_max_transport_line_index=function() return 2 end,
  get_transport_line=function() return {get_item_count=function(n) return n=='coal' and 4 or 0 end} end} end
local lb1_feeder=add{type='inserter',name='burner-inserter',position={x=60,y=14},drop_target=lb1,pickup_target=coalchest}
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
-- What it holds (Gemini, 12:20: an item overview per network), as the engine's get_contents gives it.
ln.get_contents=function() return {{name='iron-plate',quality='normal',count=4200},{name='copper-plate',quality='normal',count=3100},
  {name='coal',quality='normal',count=50}} end
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
  ..'solar 10 panels, 500 kW now, 600 kW peak; accumulators 2 at 50% (5.0 MJ of 10.0 MJ); machines 30: 3 low power, 1 no power; boilers 11: their own fuel 31 min at this draw, '
  ..'1 with fuel at their feeders, 2 under 20 min not refilled (lowest 4 min); lowest boiler (66,16): 4 min of coal; no inserter feeds it; '
  ..'feed chests: wooden-chest (41,13) 400 coal, unchanged over 5 min')
-- (lb1 holds 100 coal, 4 min, but its inserter's chest holds 400: not low; lb2 and the one by the engine have no feeder)
eq(lines[2],'nauvis logistic #3: 4 roboports (+1 personal), logistic area (0,25)-(125,75), construction area (-30,-5)-(155,105); '
  ..'logistic robots 147: 0 idle, 142 working, 3 charging, 2 waiting to charge; construction robots 11: 4 idle, 6 working, 1 charging, 0 waiting to charge; '
  ..'no idle logistic robot for 4 min; requests unfilled 60+ s: 1 (iron-plate 300 missing); construction backlog: 5 ghosts, 0 to deconstruct, 0 to upgrade; 0 waited 5+ min, oldest 4 min; '
  ..'holds iron-plate 4200, copper-plate 3100, coal 50; requesters ask iron-plate 400 (300 short), copper-cable 200')
eq(lines[3],'nauvis turrets: gun-turret 6; ammo used in the last hour: firearm-magazine 1200')
-- The read: the same numbers as fields.
local r=N.read({force=force},{})
eq(#r.surfaces,1); local e=r.surfaces[1].electric[1]
eq(e.id,7); eq(e.capacity_kw,22100); eq(e.generators_kw,21600); eq(e.solar_peak_kw,600); eq(e.draw_kw.avg,18500); eq(e.draw_kw.over_s,300)
-- (Gemini, 07:55: stored against the maximum; Haiku, 07:55: the lowest boiler named, with its fuel and feeder)
eq(e.acc_mj,5); eq(e.acc_max_mj,10)
eq(e.lowest_boiler.position.x,66); eq(e.lowest_boiler.min,4); eq(e.lowest_boiler.fuel,'coal'); eq(e.lowest_boiler.feeder,'no inserter feeds it')
eq(e.boilers,11,'the far boiler feeds nothing listed'); eq(e.fuel_min,31); eq(e.boilers_fed,1); eq(e.boilers_under_10_min,1); eq(e.boilers_under_20_min,2); eq(e.lowest_boiler_min,4); eq(e.low,3); eq(e.none,1)
-- The science line's power part (scienceline.lua): the surface's largest network, plain numbers.
local pr=N.power_row(force,'nauvis')
eq(pr.id,7); eq(pr.capacity_kw,22100); eq(pr.draw_kw,18500); eq(pr.boilers,11); eq(pr.fed,1); eq(pr.low,2); eq(math.floor(pr.low_min),4)
eq(N.power_row(force,'vulcanus'),nil)
eq(pr.feed,nil,'a feed chest not falling is not passed')
local l=r.surfaces[1].logistic[1]; eq(l.unfilled,1)
eq(l.holds[1].name,'iron-plate'); eq(l.holds[1].count,4200); eq(#l.holds,3)
eq(l.requests[1].name,'iron-plate'); eq(l.requests[1].asked,400); eq(l.requests[1].short,300); eq(l.requests[2].short,0); eq(l.unfilled_items['iron-plate'],300); eq(l.ghosts,5); eq(l.logistic_idle,0)
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

-- 2. Alert groups. A second look: three boilers burnt down (luna's two and the one by the engine), the other eight
-- kept their coal. Low: under 20 min of their own fuel with no fuel at their feeders. lb1 (20 coal, 0 min) is fed from
-- the chest with 400 coal: not low. The line names each low boiler and its feeder (or that none feeds it), and the
-- coal in chests and on belts nearby; draw under 85%: no power_high; robots not 10 min yet.
-- (No earlier look kept: here the feeders alone decide; the own-fuel drain is section 4's.)
lb1.burner.inventory[1].count=20; lb2.burner.inventory[1].count=60; nearb.burner.inventory[1].count=300
storage.networks.boiler_own={}
run(5)  -- (whole 5 s draw samples keep the 2-minute checks below aligned)
storage.networks.views={}
local g=N.alert_groups(force)
eq(#g,1); eq(g[1].kind,'boiler_fuel'); eq(g[1].n,2); eq(g[1].by.luna,1); eq(g[1].center.x,35); eq(g[1].rank,30002)
eq(g[1].now_text,'2 boilers under 20 min of their own fuel at this draw, 1 under 10, 1 under 5, lowest 2 min')
eq(g[1].line,'2 boilers under 20 min of their own fuel at this draw, 1 under 10, 1 under 5, not refilled, near (35,19) (electric #7: 11 boilers, '
  ..'1 with fuel at their feeders); boiler (66,16) 2 min: no inserter feeds it; boiler (4,22) 12 min: no inserter feeds it; '
  ..'fuel within 64 tiles: wooden-chest (41,13) coal 400, iron-chest (81,13) coal 50; belts: coal 16 on 2 tiles, nearest (31,13), (31,12)')
-- The chest empties: lb1 is low too, its feeder and the empty chest named.
chest_coal=0; run(5); storage.networks.views={}
g=N.alert_groups(force)
eq(g[1].n,3)
has(g[1].line,'boiler (60,16) 0 min: burner-inserter (60,14) from wooden-chest (41,13) holding no fuel')
-- The inserter has coal in hand: lb1 is fed again.
lb1_feeder.held_stack={valid_for_read=true,name='coal',count=1}
run(5); storage.networks.views={}
eq(N.alert_groups(force)[1].n,2)
-- The two unfed boilers refilled: no alert.
lb2.burner.inventory[1].count=1000; nearb.burner.inventory[1].count=1000; chest_coal=400; lb1_feeder.held_stack=nil
run(5); storage.networks.views={}
for _,x in ipairs(N.alert_groups(force)) do assert(x.kind~='boiler_fuel','all fed or full: no boiler alert') end
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
eq(by.requester_full,nil,'a requester with room is no requester_full')
-- Every slot of the short requester taken (Sol, 22:08: 494 spoilage among a requester's 48 slots, robots could not
-- deliver bioflux): requester_full, with what fills it.
do
  local owner=ln.requester_points[1].owner
  local slots={{'spoilage',50},{'spoilage',44},{'iron-plate',20}}
  local inv={count_empty_stacks=function() return 0 end,can_insert=function() return false end}
  for i,s in ipairs(slots) do inv[i]={valid_for_read=true,name=s[1],count=s[2]} end
  owner.type='logistic-container'; owner.name='requester-chest'; owner.valid=true; owner.position={x=48.5,y=34.5}
  owner.get_inventory=function() return inv end
  run(5); storage.networks.views={}
  by={}
  for _,x in ipairs(N.alert_groups(force)) do by[x.kind]=x end
  eq(by.requester_full.n,1); eq(by.requester_full.center.x,49)
  eq(by.requester_full.line,'requester chests with every slot taken while a request is short 60+ s: 1 in network 3 (spoilage 94 among their slots): '
    ..'requester-chest (48.5,34.5) asks iron-plate: all 3 slots taken (spoilage 94 in 2 slots, iron-plate 20 in 1 slot)')
  owner.type=nil; owner.get_inventory=nil
  run(5); storage.networks.views={}
end
-- The same groups in steps, one network a step (pushalerts' background read; operator 18:12: networks.alert_groups
-- 58-60 ms in one tick on world n).
do
  local cur,steps=N.alert_cursor(force),1
  while not N.alert_step(cur,1) do steps=steps+1 end
  local all=N.alert_groups(force)
  eq(#cur.out,#all); for i,x in ipairs(all) do eq(cur.out[i].line,x.line) end
  eq(steps,2,'two networks, two steps')
end
-- One sample under 85% ends it.
flows['steam-engine']=10e6/60; run(5); storage.networks.views={}
for _,x in ipairs(N.alert_groups(force)) do assert(x.kind~='power_high','below 85% now') end
-- A robot idle again: robots_busy starts over.
ln.available_logistic_robots=5; run(30); storage.networks.views={}
for _,x in ipairs(N.alert_groups(force)) do assert(x.kind~='robots_busy') end
-- 3. The background view (task-statuscost, 01:15 on world n: networks.alert_groups 55 ms when one call rebuilt the
-- view; operator 04:00: whole-surface finds a step burst in single game seconds): a step every few ticks, each at
-- most one find, and after a surface's first walk (one whole-surface find: no box known yet) every find is a band
-- of chunks; a reply with a view reads that and finds nothing.
do
  local find=nauvis.find_entities_filtered
  local per_tick,whole=0,0
  -- (big finds; the boilers' feeder look-ups are small finds of 4 tiles around each boiler)
  nauvis.find_entities_filtered=function(f)
    if not f.position then per_tick=per_tick+1; if not f.area then whole=whole+1 end end
    return find(f)
  end
  local function build()
    storage.networks.views={}; storage.networks.view_jobs={}
    local worst,ticks=0,0
    while not storage.networks.views.player and ticks<3600 do
      game.tick=game.tick+1; ticks=ticks+1; per_tick=0; N.tick(game.tick)
      if game.tick%300~=0 then worst=math.max(worst,per_tick) end
    end
    return worst,ticks
  end
  local worst,ticks=build()
  assert(worst<=2,'at most the view step and the pole map step a tick: '..worst)
  assert(ticks>20,'spread over ticks: '..ticks)
  local v=storage.networks.views.player
  assert(v and #v.surfaces==1 and #v.surfaces[1].electric==1,'the job made the view')
  eq(v.surfaces[1].electric[1].machines,30); eq(#v.surfaces[1].electric[1].boilers,11)
  eq(v.surfaces[1].turrets.by['gun-turret'],6)
  -- The next pass: the box is known, every find is a band.
  whole=0
  worst=build()
  eq(whole,0,'no whole-surface find once the box is known')
  v=storage.networks.views.player
  eq(v.surfaces[1].electric[1].machines,30); eq(#v.surfaces[1].electric[1].boilers,11)
  -- The logistic networks one a step (operator 18:12): their rows as the view made at once has them.
  local bg_lines={}
  for _,r in ipairs(v.surfaces[1].logistic) do bg_lines[#bg_lines+1]=r.line end
  assert(#bg_lines>0,'a logistic row')
  storage.networks.view_bg=nil; storage.networks.views={}
  nauvis.find_entities_filtered=find
  local now={}
  for _,r in ipairs(N.read({force=force},{}) and storage.networks.views.player.surfaces[1].logistic) do now[#now+1]=r.line end
  eq(#now,#bg_lines); for i,l in ipairs(bg_lines) do eq(now[i],l) end
  storage.networks.view_bg=true; storage.networks.views.player=v
  nauvis.find_entities_filtered=function(f)
    if not f.position then per_tick=per_tick+1; if not f.area then whole=whole+1 end end
    return find(f)
  end
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
      if ok and f.area then ok=e.position.x>=f.area[1][1] and e.position.x<=f.area[2][1] and e.position.y>=f.area[1][2] and e.position.y<=f.area[2][2] end
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
  eq(#boiler_groups(),0,'the first look: every boiler has fuel at its feeder')
  local line=N4.lines(force,'n2',8)[1]
  has(line,'boilers 13: their own fuel ')
  has(line,', 13 with fuel at their feeders')
  -- Haiku and Astra, 03:20: inserters keep each boiler at 2 coal (0 min of its own) while the belt is full: not low.
  for _,b in ipairs(boilers) do b.burner.inventory[1].count=2 end
  run4(30)
  eq(#boiler_groups(),0,'2 coal each on a full belt: no alert')
  -- The supply runs out: the chest and the belt empty.
  in_chest=0; coal_per_tile=0
  run4(30)
  local g=boiler_groups()
  eq(#g,1); eq(g[1].n,13)
  has(g[1].line,'13 boilers under 20 min of their own fuel at this draw, 13 under 10, 13 under 5, not refilled, near (-4,41) (electric #20: 13 boilers, 0 with fuel at their feeders)')
  has(g[1].line,'boiler (-22,41) 0 min: inserter (-22,39) from transport-belt (-13,36) (with 6 belt tiles up to it holding no fuel)')
  has(g[1].line,'inserter (2,39) from requester-chest (10,39) holding no fuel')
  has(g[1].line,'+10 more')
  -- The belt's first tile is loaded by an inserter from a requester chest holding solid fuel (the boilers burn
  -- coal; any fuel counts): the belt boilers are fed, the line names what loads the belt.
  local loader_chest=put{type='logistic-container',name='requester-chest',unit_number=3002,position={x=-23.5,y=33.5},
    get_item_count=function(n) return n=='solid-fuel' and 90 or 0 end}
  local loader=put{type='inserter',name='fast-inserter',unit_number=4100,position={x=-23.5,y=34.5},drop_target=tiles[1],pickup_target=loader_chest}
  run4(30)
  g=boiler_groups()
  eq(g[1].n,6,'the 7 belt boilers fed, the 6 chest boilers not')
  local r4=N4.read({force=force},{}).surfaces[1].electric[1]
  eq(r4.boilers_fed,7); eq(r4.boilers_under_20_min,6)
  -- An underground: the walk goes from its exit to its entrance and on up the belt.
  local ug_in=put{type='underground-belt',name='underground-belt',unit_number=2101,position={x=30,y=60},belt_to_ground_type='input'}
  local ug_out=put{type='underground-belt',name='underground-belt',unit_number=2102,position={x=36,y=60},belt_to_ground_type='output',neighbours=ug_in}
  local before=put{type='transport-belt',name='transport-belt',unit_number=2100,position={x=29,y=60}}
  for _,t in ipairs({ug_in,ug_out,before}) do
    t.get_max_transport_line_index=function() return 2 end
    t.get_transport_line=function() return {get_item_count=function(n) return t==before and n=='coal' and 3 or 0 end} end
  end
  before.belt_neighbours={inputs={},outputs={ug_in}}; ug_in.belt_neighbours={inputs={before},outputs={}}; ug_out.belt_neighbours={inputs={},outputs={}}
  local ugb={e={valid=true,type='boiler',name='boiler',position={x=37,y=63},burner={remaining_burning_fuel=0,inventory={{valid_for_read=true,name='coal',count=1}}}},j=4e6}
  put{type='inserter',name='inserter',unit_number=4200,position={x=37,y=61},drop_target=ugb.e,pickup_target=ug_out}
  N4.boiler_supply({ugb},n2,force)
  eq(ugb.fed,true); eq(ugb.feeder,'inserter (37,61) from underground-belt (36,60) (with 3 belt tiles up to it holding 6 coal)')
  -- A trickle (shift10 03:36-03:38: boiler (-15,42) from 8 to 6 min on a belt with 4 solid-fuel): fed from a belt
  -- holding fuel, but its own fuel fell by 80% or more of its burn at its share since a look 2+ min back: told.
  -- An inserter-sized swing (60 to 56 coal) is not; nor a look under 2 min back. Boiler 1 burns at its share
  -- (12 MW over 13 boilers: about 14 coal a minute) and nothing reaches it.
  in_chest=150; coal_per_tile=6
  st4.networks.boiler_own={}
  for _,b in ipairs(boilers) do b.burner.inventory[1].count=60 end
  run4(30); eq(#boiler_groups(),0,'all fed and steady')
  for i=1,13 do boilers[i].burner.inventory[1].count=i==1 and 46 or (i==2 and 56 or 60) end
  run4(60); eq(#boiler_groups(),0,'60 s since the look kept: not compared yet')
  boilers[1].burner.inventory[1].count=30
  run4(70)
  g=boiler_groups()
  eq(#g,1); eq(g[1].n,1)
  has(g[1].line,'1 boiler under 20 min of their own fuel at this draw, 1 under 10, 1 under 5, not refilled, near (-22,41)')
  has(g[1].line,'boiler (-22,41) 2 min, down from 4 min 130 s before: inserter (-22,39) from transport-belt (-13,36) (with 6 belt tiles up to it holding 36 coal)')
  -- The next look says the same (compared with the newest look 2+ min back, not with the last one).
  boilers[1].burner.inventory[1].count=23
  run4(30)
  g=boiler_groups()
  eq(#g,1); has(g[1].line,'boiler (-22,41) 1 min, down from 4 min 160 s before')
  -- A slow drain (shift10: boiler (-15,42) from 6 min at 03:38 to 3 at 03:47): boiler 3 gets a third of its burn.
  -- Under 80% over 2 min, but 25% or more over 4 min (18 coal of 55 burnt): told at 240 s. Boiler 2's 60-to-56
  -- swing is not.
  st4.networks.boiler_own={}
  for _,b in ipairs(boilers) do b.burner.inventory[1].count=60 end
  eq(#boiler_groups(),0)
  for _,c in ipairs({55,51,46}) do
    run4(60); boilers[3].burner.inventory[1].count=c
    eq(#boiler_groups(),0,'not over 4 min yet')
  end
  run4(60); boilers[3].burner.inventory[1].count=42; boilers[2].burner.inventory[1].count=56
  g=boiler_groups()
  eq(#g,1); eq(g[1].n,1)
  has(g[1].line,'boiler (-16,41) 3 min, down from 4 min 240 s before: inserter (-16,39) from transport-belt (-9,36) (with 8 belt tiles up to it holding 48 coal)')
  -- Feed chests running out (Haiku, 10:50): the requester chest feeding boilers 8-13 holds 12 coal and nothing is put
  -- into it for 5 min: a group per boiler naming the boiler, the chest, its count and the feeder. Not before 5 min of
  -- looks; not while robots bring coal to it; not when its count rose; worse under 10, then empty.
  local function feed_groups()
    st4.networks.views={}
    local out={}
    for _,x in ipairs(N4.alert_groups(force)) do if x.kind=='feed_chest_low' then out[#out+1]=x end end
    table.sort(out,function(a,b) return a.center.x<b.center.x end)
    return out
  end
  st4.networks.feed_hist={}
  for _,b in ipairs(boilers) do b.burner.inventory[1].count=60 end
  in_chest=12
  eq(#feed_groups(),0,'the first look')
  for _=1,4 do run4(60); eq(#feed_groups(),0,'under 5 min of looks') end
  run4(60)
  local fg6=feed_groups()
  eq(#fg6,6,'boilers 8-13')
  eq(fg6[1].line,'boiler (-1,41): its feed chest requester-chest (10,39) holds 12 coal, nothing put into it for 5+ min (feeder inserter (-1,39))')
  eq(fg6[1].rank,1)
  -- Robots on the way with coal: being refilled.
  requester.get_logistic_point=function() return {targeted_items_deliver={{name='coal',quality='normal',count=50}}} end
  eq(#feed_groups(),0,'robots bring coal')
  requester.get_logistic_point=nil
  run4(60); eq(#feed_groups(),6)
  -- The count rose a look ago: refilled within 5 min.
  in_chest=15; run4(60); in_chest=8; run4(60)
  eq(#feed_groups(),0,'it rose within 5 min')
  for _=1,5 do run4(60); feed_groups() end
  fg6=feed_groups()
  eq(#fg6,6); eq(fg6[1].rank,2,'under 10')
  in_chest=0; run4(60)
  fg6=feed_groups(); eq(fg6[1].rank,3,'empty'); has(fg6[1].line,'holds no fuel')
  -- Its rate (Haiku, 12:20): the net change per minute over the last 10 min of looks and the minutes left while it
  -- falls; on the network line and the networks read, the fewest minutes left first.
  st4.networks.feed_hist={}
  in_chest=200; feed_groups()
  for k=1,10 do run4(60); in_chest=200-15*k; feed_groups() end
  local row=N4.read({force=force},{}).surfaces[1].electric[1]
  local fr=row.feed_chests[1]
  eq(fr.chest,'requester-chest'); eq(fr.count,50); eq(fr.per_min,-15); eq(fr.minutes_left,3)
  eq(fr.rate,'uses 15.0/min over 10 min, 3 min left')
  has(row.line,'feed chests: requester-chest (10,39) 50 coal, uses 15.0/min over 10 min, 3 min left')
  -- status's science line gets the one with the fewest minutes left from power_row.
  local pr4=N4.power_row(force,'n2')
  eq(pr4.feed.min,3); eq(pr4.feed.line,'requester-chest (10,39) 50 coal, uses 15.0/min over 10 min, 3 min left')
  -- The boilers read names each boiler's feed chest with its rate.
  local br=N4.boilers({force=force,surface=n2},{})
  local found
  for _,g in ipairs(br.networks or br.groups or {}) do
    for _,b in ipairs(g.boilers or {}) do if b.feed_chest then found=b.feed_chest end end
  end
  assert(found,'a boiler row with its feed chest')
  eq(found.line,'requester-chest (10,39) 50 coal, uses 15.0/min over 10 min, 3 min left')
  in_chest=150
  game.surfaces=saved
end
-- Boilers that hold no fuel at all: the usual fuels are looked for, and the line says so.
local empty={valid=true,type='boiler',name='boiler',unit_number=990,position={x=200,y=200},
  burner={remaining_burning_fuel=0,inventory={{valid_for_read=false}}}}
local fg=N.fuel_group({name='nauvis'},{id=9,boilers={{e=empty,min=0}},fuel_low={{e=empty,min=0}}},force)
has(fg.line,'1 boiler under 20 min of their own fuel at this draw, 1 under 10, 1 under 5, not refilled, near (200,200) (electric #9: 1 boiler, no draw); '
  ..'boiler (200,200) 0 min: no inserter feeds it; '
  ..'fuel within 64 tiles (the boilers hold none; looked for coal, solid-fuel, wood, rocket-fuel, nuclear-fuel): iron-chest (81,13) coal 50, wooden-chest (41,13) coal 400; belts: coal 16')
has(fg.line,'boiler (200,200) 0 min: no inserter feeds it')
-- Logistic coverage (Sonnet, shift10): a chest outside every roboport's logistic area; 2.0.77: a square, edges in.
do
  local ports={}
  local cs={find_entities_filtered=function(f)
    local out={}
    for _,e in ipairs(ports) do
      local d=((e.position.x-f.position.x)^2+(e.position.y-f.position.y)^2)^0.5
      local is=f.type=='roboport' and e.type=='roboport' or f.ghost_type=='roboport' and e.type=='entity-ghost'
      if is and d<=f.radius then out[#out+1]=e end
    end
    return out
  end}
  eq(N.coverage(cs,force,{x=0,y=0}),'outside logistic coverage: no roboport of ours within 200 tiles')
  ports[1]={valid=true,type='roboport',name='roboport',position={x=120,y=160},logistic_cell={logistic_radius=25}}
  eq(N.coverage(cs,force,{x=145,y=160.5}),nil,'25 tiles off: in')
  eq(N.coverage(cs,force,{x=146.5,y=160.5}),'outside logistic coverage: nearest roboport (120,160), 1.5 tiles from its area')
  eq(N.coverage(cs,force,{x=148,y=188}),'outside logistic coverage: nearest roboport (120,160), 4.2 tiles from its area','the corner: 3 and 3')
  -- A roboport planned in the same call, or a roboport ghost, covers it.
  eq(N.coverage(cs,force,{x=146.5,y=160.5},{{x=150,y=166,r=25}}),nil)
  ports[2]={valid=true,type='entity-ghost',name='entity-ghost',position={x=160,y=160},ghost_prototype={logistic_radius=25}}
  eq(N.coverage(cs,force,{x=146.5,y=160.5}),nil)
end

-- 5. boilers (Haiku, 06:20: "lists each boiler's position, state and fuel (and its feeder), so the no_fuel one is
-- named"): every boiler, grouped by the electric network its steam feeds, the not-working first; each with its state,
-- fuel, water and steam, and its feeder with what it takes from. Luna's two are out of fuel (lb1's inserter takes from
-- the chest with 400 coal), the one by the engine has its steam output full, the far one has no water.
defines.entity_status.no_fuel, defines.entity_status.full_output, defines.entity_status.no_input_fluid = 3, 4, 5
for _, e in ipairs(list) do if e.type == 'boiler' then e.status = 0 end end
lb1.status, lb2.status, nearb.status = 3, 3, 4
local far
for _, e in ipairs(list) do if e.type == 'boiler' and e.position.x == 400 then far = e; e.status = 5 end end
lb2.fluidbox[1] = {name='water', amount=200}; lb2.fluidbox.get_capacity = function() return 200 end
lb2.fluidbox[2] = {name='steam', amount=12.4}
lb1.burner.inventory.get_contents = function() return {{name='coal', quality='normal', count=lb1.burner.inventory[1].count}} end
local you = {force=force, surface=nauvis}
local bo = N.boilers(you, {})
eq(bo.surface, 'nauvis'); eq(bo.boilers, 12); eq(bo.not_working, 4); eq(#bo.networks, 2)
local g7, gnone = bo.networks[1], bo.networks[2]
eq(g7.network, 7); eq(g7.total, 11); eq(g7.not_working, 3)
eq(g7.line, 'electric #7: 11 boilers: 1 output full, 2 no fuel, 8 working')
-- the not-working first (by position), then up to 4 working; the rest counted
eq(g7.boilers[1].position.x, 4); eq(g7.boilers[1].state, 'output full'); eq(g7.boilers[1].status, 'full_output'); eq(g7.boilers[1].working, false)
eq(g7.boilers[1].feeder, 'no inserter feeds it'); eq(g7.boilers[1].feeder_has_fuel, false); eq(g7.boilers[1].burning, 'coal')
local b1, b2 = g7.boilers[2], g7.boilers[3]
eq(b1.position.x, 60); eq(b1.state, 'no fuel'); eq(b1.fuel, 'coal*20')
eq(b1.feeder, 'burner-inserter (60,14) from wooden-chest (41,13) holding 400 coal'); eq(b1.feeder_has_fuel, true)
eq(b2.position.x, 66); eq(b2.state, 'no fuel'); eq(b2.water, 'water 200/200'); eq(b2.steam, 'steam 12/200')
eq(g7.boilers[4].state, 'working'); eq(g7.boilers[4].position.x, 6); eq(#g7.boilers, 7); eq(g7.more, 4)
eq(gnone.network, nil); eq(gnone.line, 'no electric network found: 1 boiler: 1 no water'); eq(gnone.boilers[1].state, 'no water')
eq(gnone.boilers[1].water, 'empty')
-- all working: networks by size; another surface by name
for _, e in ipairs(list) do if e.type == 'boiler' then e.status = 0 end end
bo = N.boilers(you, {surface='nauvis'})
eq(bo.not_working, 0); eq(bo.networks[1].network, 7); eq(bo.networks[1].not_working, nil); eq(#bo.networks[1].boilers, 11)
assert(not pcall(N.boilers, you, {surface='vulcanus'}))
eq(N.schema.boilers.surface, 'optional surface name (default yours)')
far.status = 5
-- 6. Accumulators running down (Gemini, shift12 15:10: Fulgora's daylight lull between storms; on a copy of world n
-- its network 301, 173 accumulators, fell 14.6 MW net in daylight and emptied in about 35 s, then charged in the
-- storm). Network 7's 2 accumulators hold 5 MJ of 10 MJ: the net flow of the last 30 s against what they hold now,
-- told under 10 min, again under 5 and 2; kept 10 min after at the worst step, so a storm between lulls is no news.
do
  local function acc_groups(n6)
    storage.networks.views={}
    local out={}
    for _,x in ipairs((n6 or N).alert_groups(force)) do if x.kind=='accumulators_draining' then out[#out+1]=x end end
    return out
  end
  flows.accumulator=5e3/60; run(30)
  eq(#acc_groups(),0,'1000 s to empty: no alert')
  storage.networks.views={}
  has(N.lines(force,'nauvis',8)[1],'accumulators 2 at 50% (5.0 MJ of 10.0 MJ), falling 5 kW net over the last 30 s: empty in about 16m40s at that rate')
  flows.accumulator=10e3/60; run(30)
  local g=acc_groups()
  eq(#g,1); eq(g[1].rank,1); eq(g[1].now_text,'8m20s from empty'); eq(g[1].key,'accumulators_draining|nauvis|7')
  eq(g[1].line,'electric #7 near (32,0): its 2 accumulators at 50% (5.0 MJ of 10.0 MJ) fall 10 kW net over the last 30 s: empty in about 8m20s at that rate')
  flows.accumulator=50e3/60; run(30)
  g=acc_groups(); eq(g[1].rank,3); eq(g[1].now_text,'1m40s from empty')
  -- Charging (a storm): kept at its worst step, said so.
  flows.accumulator=0; flows_in.accumulator=20e3/60; run(30)
  g=acc_groups()
  eq(#g,1); eq(g[1].rank,3)
  eq(g[1].line,'electric #7 near (32,0): its 2 accumulators were 1m40s from empty 30s ago (falling 50 kW net); now at 50% (5.0 MJ of 10.0 MJ), rising 20 kW net')
  -- On Fulgora the sky's timing (lightning.lua M.sky): the next storm in daylight, else dawn.
  local N6=dofile('mod/agent-harness_0.1.0/networks.lua'){state=function() return storage end,
    sky=function() return {phase='day',dusk_in_s=72,dawn_in_s=162} end}
  game.get_surface=function(name) return name=='nauvis' and nauvis or nil end
  has(acc_groups(N6)[1].line,'; Fulgora: day, no lightning; next storm (dusk) in 1m12s')
  N6=dofile('mod/agent-harness_0.1.0/networks.lua'){state=function() return storage end,
    sky=function() return {phase='full dark',dusk_in_s=110,dawn_in_s=40} end}
  has(acc_groups(N6)[1].line,'; Fulgora: storm (full dark); dawn (clear) in 40s')
  game.get_surface=nil
  -- Empty: said so, and once charging again, when it ran empty (Vulcanus #209 on the copy read "at 0% ... empty in
  -- about 0s").
  local accs={}
  for _,e in ipairs(list) do if e.type=='accumulator' then accs[#accs+1]=e; e.energy=0 end end
  flows_in.accumulator=nil; flows.accumulator=10e3/60; run(30)
  g=acc_groups()
  eq(g[1].line,'electric #7 near (32,0): its 2 accumulators are empty (0.0 MJ of 10.0 MJ; 10 kW net flowed out over the last 30 s)')
  eq(g[1].now_text,'empty')
  flows.accumulator=0; flows_in.accumulator=20e3/60; for _,e in ipairs(accs) do e.energy=1e6 end; run(30)
  eq(acc_groups()[1].line,'electric #7 near (32,0): its 2 accumulators ran empty 30s ago; now at 20% (2.0 MJ of 10.0 MJ), rising 20 kW net')
  for _,e in ipairs(accs) do e.energy=2.5e6 end
  -- Ten minutes past the last fall under 10 min: gone.
  run(601)
  eq(#acc_groups(),0)
  flows_in.accumulator=nil
end
-- 7. Accumulators read at the read (Astra, shift14 22:50: the view's sum stood still while each accumulator's inspect
-- moved; a Fulgora day took ~15 single reads): acc_mj, acc_pct and the line's part read now, whatever the view's age;
-- the 5 s samples keep what they held (a series every 15 s over 3 min); fresh: true reads the draw now too.
do
  storage.networks.views={}
  N.lines(force,'nauvis',8)
  local accs={}
  for _,e in ipairs(list) do if e.type=='accumulator' then accs[#accs+1]=e end end
  storage.networks.samples={}
  for _,e in ipairs(accs) do e.energy=4e6 end
  run(5)
  eq(N.read({force=force},{}).surfaces[1].electric[1].acc_series,nil,'one value is no series')
  for k=1,4 do
    for _,e in ipairs(accs) do e.energy=(5-k)*1e6 end
    run(15)
  end
  local r=N.read({force=force},{})
  local e=r.surfaces[1].electric[1]
  eq(e.acc_mj,2); eq(e.acc_max_mj,10); eq(e.acc_pct,20)
  has(e.line,'accumulators 2 at 20% (2.0 MJ of 10.0 MJ)')
  eq(e.acc_series,'80% 80% 60% 40% 20% (every 15 s over the last 3 min, oldest first)')
  -- Three minutes on, the oldest values drop out.
  run(150)
  eq(N.read({force=force},{}).surfaces[1].electric[1].acc_series,'40% 20% 20% 20% 20% 20% 20% 20% 20% 20% 20% 20% (every 15 s over the last 3 min, oldest first)')
  eq(e.draw_now_kw,nil,'with fresh only')
  has(r.read_now,'accumulators (acc_mj, acc_pct, the line\'s part); the rest as of the view')
  flows['steam-engine'],flows['solar-panel'],flows.accumulator=18e6/60,0.5e6/60,0
  r=N.read({force=force},{fresh=true})
  eq(r.surfaces[1].electric[1].draw_now_kw,18500)
  has(r.read_now,'draw_now_kw (the last 5 s of each network\'s statistics)')
  assert(not pcall(N.read,{force=force},{fresh='yes'}),'fresh is a boolean')
end
print('networks: ok')
